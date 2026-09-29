-- ==============================================================================
-- [OP] AnimeDice Loader — проверяет игру клиента и запускает основной скрипт с GitHub.
--
-- Что делает:
--   1) смотрит game.PlaceId / game.GameId;
--   2) если это Anime Dice — скачивает твой скрипт по RAW-ссылке с GitHub
--      (с обходом кэша и несколькими запасными способами загрузки);
--   3) проверяет, что скачался валидный Lua, и запускает его;
--   4) после этого следит, чтобы скрипт жил: если сессия пропала (перезаход/
--      телепорт) — перезапускает через queue_on_teleport и сторожевой цикл.
--   5) если клиент в другой игре — просто пишет об этом и НЕ запускает ничего.
--
-- НАСТРОЙКА (единственное, что нужно менять):
--   RAW_URL — прямая ссылка вида
--   https://raw.githubusercontent.com/<логин>/<репо>/<ветка>/<файл>.luau
--   (именно raw., а не страница github.com; репозиторий должен быть публичным,
--    иначе raw отдаст 404/401)
-- ==============================================================================

local RAW_URL = "https://raw.githubusercontent.com/kalka12/AnimeDice/refs/heads/main/%5BOP%5D%20AnimeDice.luau"

-- Проверка игры: Anime Dice (place / universe). Можно добавить свои id.
local GAME_PLACE_IDS = { 113290951185459 }   -- [⚙️UPD 6] Anime Dice
local GAME_IDS       = { 10708913337 }      -- тот же юниверс

-- Поведение
local REARM_ON_TELEPORT = true   -- перезапускать после телепортов (queue_on_teleport)
local WATCHDOG = true            -- если сессия скрипта исчезла — перезапустить
local WATCHDOG_INTERVAL = 15     -- сек
local NOTIFY = true              -- уведомления StarterGui
local MIN_SOURCE_BYTES = 2000    -- защита от «пустого» ответа/заглушки

-- ==============================================================================
-- служебное
-- ==============================================================================
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local HttpService = game:GetService("HttpService")

local function notify(text, duration)
    if not NOTIFY then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", { Title = "OP Loader", Text = tostring(text), Duration = duration or 5 })
    end)
end

local function log(msg)
    print("[OP Loader] " .. tostring(msg))
end

local function inTargetGame()
    for _, id in ipairs(GAME_PLACE_IDS) do
        if game.PlaceId == id then return true, "place" end
    end
    for _, id in ipairs(GAME_IDS) do
        if game.GameId == id then return true, "universe" end
    end
    return false
end

-- несколько способов скачивания (у разных исполнителей работают разные) + таймаут на каждый
local function withTimeout(fn, seconds)
    local done, result = false, nil
    task.spawn(function()
        local ok, v = pcall(fn)
        result = ok and v or nil
        done = true
    end)
    local t = 0
    while not done and t < seconds do
        task.wait(0.25)
        t = t + 0.25
    end
    return done and result or nil
end

local function fetch(url)
    -- 1) game:HttpGet (второй аргумент false = не брать из кэша)
    local body = withTimeout(function() return game:HttpGet(url, false) end, 10)
    if type(body) == "string" and #body >= MIN_SOURCE_BYTES then return body, "HttpGet" end

    -- 2) request / http_request / syn.request (с таймаутом: у некоторых исполнителей он виснет)
    local req = (syn and syn.request) or (http and http.request) or http_request or (type(request) == "function" and request) or nil
    if req then
        local res = withTimeout(function() return req({ Url = url, Method = "GET" }) end, 10)
        if type(res) == "table" then
            local b = res.Body or res.body
            if type(b) == "string" and #b >= MIN_SOURCE_BYTES then return b, "request" end
        end
    end

    -- 3) ещё раз HttpGet, но с обходом кэша через случайный query
    local sep = string.find(url, "?", 1, true) and "&" or "?"
    local body3 = withTimeout(function() return game:HttpGet(url .. sep .. "t=" .. tostring(os.time()) .. tostring(math.random(1000, 9999))) end, 10)
    if type(body3) == "string" and #body3 >= MIN_SOURCE_BYTES then return body3, "HttpGet-cachebuster" end

    return nil, "все способы не дали код"
end

local function runMain(reason)
    if type(_G.__OP_AD_LOADER_BUSY) == "boolean" and _G.__OP_AD_LOADER_BUSY then
        log("уже загружаю, пропускаю")
        return false
    end
    _G.__OP_AD_LOADER_BUSY = true

    local body, how = fetch(RAW_URL)
    if not body then
        _G.__OP_AD_LOADER_BUSY = false
        log("не удалось скачать скрипт (" .. tostring(how) .. ") — проверь RAW_URL и что репо публичный")
        notify("Не скачал скрипт — проверь RAW_URL")
        return false
    end

    local fn, err = loadstring(body)
    if not fn then
        _G.__OP_AD_LOADER_BUSY = false
        log("скачался не Lua (ошибка компиляции): " .. tostring(err))
        notify("Ошибка компиляции скрипта")
        return false
    end

    log(string.format("запускаю скрипт (%s, %.1f КБ, %s)", tostring(how), #body / 1024, tostring(reason or "первый запуск")))
    local ok, err2 = pcall(fn)
    _G.__OP_AD_LOADER_BUSY = false
    if not ok then
        log("скрипт упал: " .. tostring(err2))
        notify("Скрипт упал — см. консоль")
        return false
    end
    log("скрипт запущен")
    return true
end

-- ==============================================================================
-- проверка игры
-- ==============================================================================
if not game:IsLoaded() then
    game.Loaded:Wait()
end

local isTarget, howMatch = inTargetGame()
if not isTarget then
    log(string.format("клиент в другой игре (place=%s, game=%s) — ничего не запускаю", tostring(game.PlaceId), tostring(game.GameId)))
    notify("Это не Anime Dice — скрипт не запущен", 4)
    return
end

log(string.format("клиент в Anime Dice (%s) — запускаю", tostring(howMatch)))

-- повторный запуск: гасим старую сессию (если есть) и запускаем заново
runMain("проверка игры")

-- ==============================================================================
-- живучесть: перезапуск после телепортов и сторожевой цикл
-- ==============================================================================
if REARM_ON_TELEPORT then
    local queueTp = queue_on_teleport or queueonteleport
        or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
    if queueTp then
        pcall(queueTp, string.format([[
            -- OP AnimeDice Loader: перезапуск после телепорта (только в Anime Dice)
            local url = %q
            local isTarget = false
            if game.PlaceId == 113290951185459 or game.GameId == 10708913337 then isTarget = true end
            if not isTarget then return end
            local ok, src = pcall(function() return game:HttpGet(url, false) end)
            if ok and type(src) == "string" and #src > 2000 then
                local fn = loadstring(src)
                if fn then pcall(fn) end
            end
        ]], RAW_URL))
        log("queue_on_teleport: перезапуск после телепорта включён")
    end
end

if WATCHDOG then
    task.spawn(function()
        while true do
            task.wait(WATCHDOG_INTERVAL)
            -- если основной скрипт всё ещё жив — ничего не делаем
            local aliveSession = _G.__OP_AD_SESSION ~= nil
            local hasApi = type(_G.TowerFarm) == "table" or type(_G.AD_Coop) == "table"
            if not (aliveSession or hasApi) then
                log("сессия скрипта пропала — перезапускаю")
                pcall(runMain, "watchdog")
            end
        end
    end)
end

log("готово")
