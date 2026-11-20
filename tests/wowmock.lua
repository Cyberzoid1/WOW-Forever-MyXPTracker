-- Minimal stand-in for the WoW client API, enough to load and drive MyXPTracker.
-- Use with tests/run_sim.py (Python + lupa).
local M = { T = 1795060000, gt = 500, frames = {}, printed = {} }
M.xp, M.xpmax, M.lvl = 0, 71600, 36
M.name, M.realm, M.zone = "Tester", "Realm", "Stranglethorn Vale"

function time() return math.floor(M.T) end
function GetTime() return M.gt end
function date(f, t) return os.date(f, math.floor(t or M.T)) end

local function stub()
    local o = {}
    return setmetatable(o, { __index = function(_, k)
        if not k:match("^%u") then return nil end               -- only WoW-style Methods
        if k == "GetStringHeight" or k == "GetStringWidth" or k == "GetWidth" then return function() return 120 end end
        if k == "IsShown" then return function(s) return s._shown end end
        if k == "Show" then return function(s) s._shown = true end end
        if k == "Hide" then return function(s) s._shown = false end end
        if k == "SetShown" then return function(s, v) s._shown = v and true or false end end
        if k == "SetText" then return function(s, v) rawset(s, "_text", v) end end
        if k == "GetText" then return function(s) return rawget(s, "_text") or "" end end
        if k == "SetChecked" then return function(s, v) rawset(s, "_checked", v and true or false) end end
        if k == "GetChecked" then return function(s) return rawget(s, "_checked") end end
        if k == "HasFocus" then return function() return false end end
        if k == "SetScript" then return function(s, n, f) rawset(s, "_" .. n, f) end end
        if k == "GetScript" then return function(s, n) return rawget(s, "_" .. n) end end
        if k == "CreateTexture" or k == "CreateFontString" or k == "CreateLine" then return function() return stub() end end
        if k == "GetPoint" then return function() return "TOP", nil, "TOP", 0, 0 end end
        if k == "IsMouseOver" then return function() return false end end
        if k == "GetOwner" then return function() return nil end end
        return function() end
    end })
end
function CreateFrame(_, name)
    local f = stub()
    M.frames[#M.frames + 1] = f
    if name then M.frames[name] = f end
    return f
end
GameTooltip, UIParent, ChatFontNormal = stub(), stub(), {}
COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience."
function UnitXP() return M.xp end
function UnitXPMax() return M.xpmax end
function UnitLevel() return M.lvl end
function UnitName() return M.name end
function GetRealmName() return M.realm end
function UnitClass() return "Warlock", "WARLOCK" end
function GetRealZoneText() return M.zone end
SlashCmdList = {}
M.timers = {}
C_Timer = { After = function(sec, fn) M.timers[#M.timers + 1] = { at = M.gt + sec, fn = fn } end }
function M.runTimers()
    local due = {}
    for i = #M.timers, 1, -1 do
        if M.timers[i].at <= M.gt then due[#due + 1] = table.remove(M.timers, i) end
    end
    for i = #due, 1, -1 do due[i].fn() end
end
M.playedShown = 0
function ChatFrame_DisplayTimePlayed() M.playedShown = M.playedShown + 1 end
M.playedTotal, M.playedLevel = 900000, 4000
function RequestTimePlayed()
    -- the real client answers with TIME_PLAYED_MSG and the chat frame prints it
    M.fire("TIME_PLAYED_MSG", M.playedTotal, M.playedLevel)
    ChatFrame_DisplayTimePlayed()
end
function print(...)
    local t = { ... }
    for i = 1, #t do t[i] = tostring(t[i]) end
    M.printed[#M.printed + 1] = table.concat(t, " ")
    io.write("  [chat] ", table.concat(t, " "), "\n")
end

-- WoW's Lua 5.1 lets %d/%x take floats; modern Lua doesn't. Mirror WoW.
local fmt = string.format
string.format = function(s, ...)
    local a, n, i = { ... }, select("#", ...), 0
    for spec in s:gmatch("%%[%-%d%.]*([%a%%])") do
        if spec ~= "%" then
            i = i + 1
            if (spec == "d" or spec == "x") and type(a[i]) == "number" then a[i] = math.floor(a[i]) end
        end
    end
    return fmt(s, table.unpack(a, 1, n))
end

function M.load(addonPath)
    local chunk = assert(loadfile(addonPath))
    local n = #M.frames
    chunk("MyXPTracker")
    M.ev = M.frames[n + 1]
    M.fire = function(event, ...) M.ev._OnEvent(M.ev, event, ...) end
end
function M.login()
    M.fire("ADDON_LOADED", "MyXPTracker")
    M.fire("PLAYER_LOGIN")
    M.bar = M.frames.MyXPTrackerFrame
    M.panel = M.frames.MyXPTrackerPanel
end
function M.tick(sec) M.T = M.T + sec; M.gt = M.gt + sec; M.runTimers(); M.bar._OnUpdate(M.bar, sec) end
function M.gain(amount, kind)                 -- kind: "kill", "quest" or nil
    if kind == "kill" then M.fire("CHAT_MSG_COMBAT_XP_GAIN", "Mob dies, you gain " .. amount .. " experience.") end
    if kind == "quest" then M.fire("QUEST_TURNED_IN", 1, amount, 0) end
    M.xp = M.xp + amount
    if M.xp >= M.xpmax then M.xp = M.xp - M.xpmax; M.lvl = M.lvl + 1; M.fire("PLAYER_LEVEL_UP", M.lvl) end
    M.fire("PLAYER_XP_UPDATE")
end
-- Serialize like WoW's SavedVariables writer (one value per line, "-- [n]" after array items).
local function ser(v, out, indent)
    local tv = type(v)
    if tv == "string" then out[#out + 1] = string.format("%q", v):gsub("\\\n", "\\n")
    elseif tv == "number" or tv == "boolean" then out[#out + 1] = tostring(v)
    elseif tv == "table" then
        out[#out + 1] = "{\n"
        local n = #v
        for i = 1, n do ser(v[i], out, indent); out[#out + 1] = ", -- [" .. i .. "]\n" end
        for k, val in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
                out[#out + 1] = type(k) == "string" and string.format("[%q] = ", k) or ("[" .. tostring(k) .. "] = ")
                ser(val, out, indent); out[#out + 1] = ",\n"
            end
        end
        out[#out + 1] = "}"
    else out[#out + 1] = "nil" end
end
function M.serialize(name, v)
    local out = { name, " = " }
    ser(v, out, "")
    out[#out + 1] = "\n"
    return table.concat(out)
end
-- /reload: PLAYER_LOGOUT, write SavedVariables, load them into a fresh addon instance
function M.reload(addon)
    M.fire("PLAYER_LOGOUT")
    local text = M.serialize("MyXPTrackerDB", MyXPTrackerDB)
    MyXPTrackerDB = nil
    assert(load(text))()
    M.load(addon); M.login(); M.tick(1)
    return text
end

return M
