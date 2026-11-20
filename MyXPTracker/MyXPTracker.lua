-- MyXPTracker: rolling XP/hr + level%/hr averages shown at top of screen.
-- Hover the bar for a panel with rates, time-to-level, kills, level history,
-- goal ETA and a zoomable graph (realtime or gametime) coloured by XP source.
-- Every XP gain and every level-up is saved to SavedVariables (MyXPTrackerDB).

local ADDON = ...

local WINDOWS = { { 900, "15m" }, { 1800, "30m" }, { 3600, "1h" } }
local PANEL_WINDOWS = { { 900, "15m" }, { 1800, "30m" }, { 3600, "1h" }, { 14400, "4h" } }
local SPANS = { { 900, "15m" }, { 1800, "30m" }, { 3600, "1h" }, { 14400, "4h" }, { 43200, "12h" }, { 172800, "2d" } }
local GRAPH_BARS = 30

local db
local function spanOn(i) return db.spansOn[i] ~= false end
local function stepSpan(dir)
    local i = db.spanIdx
    repeat i = i + dir until i < 1 or i > #SPANS or spanOn(i)
    if i >= 1 and i <= #SPANS then db.spanIdx = i end
end
local function fixSpan()
    if spanOn(db.spanIdx) then return end
    for d = 1, #SPANS do
        for _, i in ipairs({ db.spanIdx - d, db.spanIdx + d }) do
            if i >= 1 and i <= #SPANS and spanOn(i) then db.spanIdx = i return end
        end
    end
end
local MIN_ELAPSED = 60      -- seconds; avoids absurd rates right after the first kill
local IDLE_CAP = 300        -- when estimating gametime for old entries, gaps count as at most 5m
local HINT_WINDOW = 1.0     -- seconds allowed between an XP gain and its kill/quest message
local MAX_LOG = 50000       -- safety cap on raw entries; beyond it the oldest are rolled up
local RAW_DAYS = 7          -- keep every individual XP gain for this long ...
local ROLLUP_SEC = 600      -- ... then merge older gains into 10-minute summaries
local CHUNK_LINES = 400     -- entries per saved string

-- XP needed to go from level L to L+1 (Classic Era table). Values seen in game override these.
local CLASSIC_XP = {
    400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600,
    8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200,
    25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400,
    50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700,
    95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500,
    153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800,
}

local SRC = {
    kill  = { 0.26, 0.60, 0.28, "kills" },
    quest = { 0.82, 0.66, 0.12, "quests" },
    other = { 0.50, 0.43, 0.70, "other" },
}
local SRC_ORDER = { "kill", "other", "quest" }   -- bottom to top; quests on top so they clip first
local SPIKE_MULT = 4        -- a single gain this many times the median gain counts as a spike (quest-sized)

local PANEL_W = 300
local RECENT_COLS = { { "Level", 46 }, { "Played", 54 }, { "Real", 54 }, { "Kills", 40 }, { "Quests", 44 }, { "Deaths", 44 } }
local PLOT_LEFT, PLOT_BOTTOM, PLOT_H = 44, 18, 60
local PLOT_W = PANEL_W - PLOT_LEFT - 10
local BAR_W = PLOT_W / GRAPH_BARS

local chr, log, charKey
local rollups = {}
local rollupFirst
local lastXP, lastMax, lastLevel
local sessionStart = time()  -- replaced at login by the saved session start
local SESSION_GAP = 1800     -- logged out longer than this = a new session (a /reload is not)
local frame, text, panel, eff
local hint = { kill = 0, quest = 0 }
local lastEntry, lastEntryAt
local updatePanel
local recentCache = setmetatable({}, { __mode = "k" })   -- stats for old level records, computed once
local toggleSettings, refreshSettings

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function fmt(n)
    if n >= 1000000 then return string.format("%.2fm", n / 1000000) end
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return string.format("%d", math.floor(n + 0.5))
end

local function pct(n)
    if n < 10 then return string.format("%.1f%%", n) end
    return string.format("%d%%", math.floor(n + 0.5))
end

-- Efficiency score from the 1h average: 50 = 1 level per (2 x paceHours), 100 = 1 level per paceHours.
-- With the default paceHours = 3: 50 = 1 lvl / 6h (target), 100 = 1 lvl / 3h, 0 = no XP.
local EFF_WINDOWS = { { 900, "15m" }, { 1800, "30m" }, { 3600, "1h" }, { 14400, "4h" } }
local EFF_HEIGHT = 4                 -- pixels
local EFF_TICKS = { 25, 50, 75 }
local EFF_STOPS = {
    { 0,   0.62, 0.16, 0.16 },   -- red
    { 25,  0.78, 0.42, 0.08 },   -- orange
    { 50,  0.78, 0.66, 0.10 },   -- yellow
    { 100, 0.16, 0.62, 0.22 },   -- green
}
local function effColor(score)
    if score <= EFF_STOPS[1][1] then return EFF_STOPS[1][2], EFF_STOPS[1][3], EFF_STOPS[1][4] end
    for k = 2, #EFF_STOPS do
        local a, b = EFF_STOPS[k - 1], EFF_STOPS[k]
        if score <= b[1] then
            local t = (score - a[1]) / (b[1] - a[1])
            return a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, a[4] + (b[4] - a[4]) * t
        end
    end
    local z = EFF_STOPS[#EFF_STOPS]
    return z[2], z[3], z[4]
end

local function fmtTime(sec)
    if not sec or sec == math.huge or sec < 0 then return "--" end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm", m)
end

local function shortDur(sec)
    local v, u = sec / 60, "m"
    if sec >= 3600 and (sec % 3600 == 0 or sec >= 36000) then v, u = sec / 3600, "h" end
    if v == math.floor(v) then return string.format("%d%s", v, u) end
    return string.format("%.1f%s", v, u)
end

local function ago(sec)
    if sec <= 0 then return "now" end
    return fmtTime(sec) .. " ago"
end

local function clockIn(sec)
    return date(sec > 20 * 3600 and "%a %H:%M" or "%H:%M", time() + math.floor(sec))
end

local function eta(xp, rate)
    if not xp or rate <= 0 then return "--" end
    local sec = xp / rate * 3600
    return fmtTime(sec) .. "  |cffaaaaaa~" .. clockIn(sec) .. "|r"
end

local function hex(c)
    return string.format("%02x%02x%02x", math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
end

-- round up to 1 / 2 / 2.5 / 5 x 10^n for a tidy axis
local function niceCeil(x)
    if x <= 0 then return 0 end
    local m = 10 ^ math.floor(math.log(x) / math.log(10))
    for _, s in ipairs({ 1, 2, 2.5, 5, 10 }) do
        if s * m >= x then return s * m end
    end
    return 10 * m
end

-- fraction of a level this gain was worth
local function entryFrac(e)
    if e.f then return e.f end
    if e.max and e.max > 0 then return e.xp / e.max end
    return 0
end

local function xpNeed(level)
    return db.xpNeed[level] or CLASSIC_XP[level], db.xpNeed[level] == nil
end

-- totals over the last `window` seconds of real time
local function windowStats(window, now)
    local s = { xp = 0, frac = 0, kills = 0, killXP = 0 }
    local earliest
    for i = #log, 1, -1 do
        local e = log[i]
        if e.t < now - window then break end
        s.xp = s.xp + e.xp
        s.frac = s.frac + entryFrac(e)
        if e.src == "kill" then s.kills = s.kills + 1; s.killXP = s.killXP + e.xp end
        earliest = e.t
    end
    local start = sessionStart
    if earliest and earliest < start then start = earliest end
    local elapsed = math.max(MIN_ELAPSED, math.min(window, now - start))
    s.rate = s.xp / elapsed * 3600
    s.lvlRate = s.frac / elapsed * 3600 * 100     -- % of a level per hour
    s.killRate = s.kills / elapsed * 3600
    return s
end

local function recentKillAvg()
    local n, sum = 0, 0
    for i = #log, 1, -1 do
        local e = log[i]
        if e.src == "kill" then n = n + 1; sum = sum + e.xp; if n >= 50 then break end end
    end
    return n > 0 and sum / n or nil
end

-- XP still needed to reach `goal`; second value is true if any of it came from the default table
local function xpToReach(goal)
    if goal <= lastLevel then return 0, false end
    local total, est = lastMax - lastXP, false
    for l = lastLevel + 1, goal - 1 do
        local n, guessed = xpNeed(l)
        if not n then return nil end
        total = total + n
        est = est or guessed
    end
    return total, est
end

---------------------------------------------------------------------------
-- storage: compact save format + rollups
--
-- In memory each XP gain is a small table {t, o, xp, lvl, cur, max, src, zone, f, oa}.
-- On logout/reload the log is written as text lines (CHUNK_LINES per string), which is
-- several times smaller in SavedVariables than a table per entry:
--   raw line:    t,o,xp,lvl,cur,max,src,zone,f,oa
--                src = k/q/o/"" (kill/quest/other/untagged), zone = index into chr.zones,
--                f = level fraction (only when it isn't simply xp/max), oa = 1 if gametime estimated
--   rollup line: t,len,o,xp,xpKill,xpQuest,xpOther,kills,quests,frac,n,lvl,zone
-- Gains older than RAW_DAYS are merged into ROLLUP_SEC summaries.
---------------------------------------------------------------------------
local SRC_CODE = { kill = "k", quest = "q", other = "o" }
local CODE_SRC = { k = "kill", q = "quest", o = "other" }

local function splitCSV(line)
    local out = {}
    for f in (line .. ","):gmatch("([^,]*),") do out[#out + 1] = f end
    return out
end

local function zoneIndex(zones, zi, z)
    if not z or z == "" then return 0 end
    local i = zi[z]
    if not i then
        zones[#zones + 1] = z
        i = #zones
        zi[z] = i
    end
    return i
end

local function zoneLookup(zones)
    local zi = {}
    for i, z in ipairs(zones) do zi[z] = i end
    return zi
end

local function chunked(lines)
    local chunks, buf = {}, {}
    for _, l in ipairs(lines) do
        buf[#buf + 1] = l
        if #buf >= CHUNK_LINES then chunks[#chunks + 1] = table.concat(buf, "\n"); buf = {} end
    end
    if #buf > 0 then chunks[#chunks + 1] = table.concat(buf, "\n") end
    return chunks
end

local function encodeLog(entries, zones)
    local zi, lines = zoneLookup(zones), {}
    for _, e in ipairs(entries) do
        local f = ""
        if e.f and not (e.max and e.max > 0 and math.abs(e.f - e.xp / e.max) < 1e-9) then
            f = string.format("%.6f", e.f)
        end
        lines[#lines + 1] = string.format("%d,%d,%d,%d,%d,%d,%s,%d,%s,%s",
            e.t, math.floor(e.o or 0), e.xp, e.lvl or 0, e.cur or 0, e.max or 0,
            SRC_CODE[e.src] or "", zoneIndex(zones, zi, e.zone), f, e.oa and "1" or "")
    end
    return chunked(lines)
end

local function decodeLog(chunks, zones, out)
    for _, chunk in ipairs(chunks) do
        for line in chunk:gmatch("[^\n]+") do
            local p = splitCSV(line)
            local zi = tonumber(p[8]) or 0
            out[#out + 1] = {
                t = tonumber(p[1]), o = tonumber(p[2]), xp = tonumber(p[3]), lvl = tonumber(p[4]),
                cur = tonumber(p[5]), max = tonumber(p[6]),
                src = CODE_SRC[p[7]], zone = zi > 0 and zones[zi] or "",
                f = (p[9] and p[9] ~= "") and tonumber(p[9]) or nil,
                oa = (p[10] == "1") or nil,
            }
        end
    end
    return out
end

local function encodeRollups(list, zones)
    local zi, lines = zoneLookup(zones), {}
    for _, r in ipairs(list) do
        lines[#lines + 1] = string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d,%.5f,%d,%d,%d",
            r.t, r.len, math.floor(r.o or 0), r.xp, r.xpKill, r.xpQuest, r.xpOther, r.kills, r.quests,
            r.frac, r.n, r.lvl or 0, zoneIndex(zones, zi, r.zone))
    end
    return chunked(lines)
end

local function decodeRollups(chunks, zones)
    local out = {}
    for _, chunk in ipairs(chunks) do
        for line in chunk:gmatch("[^\n]+") do
            local p = splitCSV(line)
            local zi = tonumber(p[13]) or 0
            out[#out + 1] = {
                t = tonumber(p[1]), len = tonumber(p[2]), o = tonumber(p[3]), xp = tonumber(p[4]),
                xpKill = tonumber(p[5]), xpQuest = tonumber(p[6]), xpOther = tonumber(p[7]),
                kills = tonumber(p[8]), quests = tonumber(p[9]), frac = tonumber(p[10]), n = tonumber(p[11]),
                lvl = tonumber(p[12]), zone = zi > 0 and zones[zi] or "",
            }
        end
    end
    return out
end

-- merge the oldest `count` raw entries into 10-minute rollups
rollupFirst = function(count)
    count = math.min(count, #log)
    if count <= 0 then return 0 end
    local last = rollups[#rollups]
    for i = 1, count do
        local e = log[i]
        local t0 = e.t - e.t % ROLLUP_SEC
        if not (last and last.t == t0) then
            last = { t = t0, len = ROLLUP_SEC, o = e.o or 0, xp = 0, xpKill = 0, xpQuest = 0, xpOther = 0,
                kills = 0, quests = 0, frac = 0, n = 0, lvl = e.lvl, zone = e.zone or "" }
            rollups[#rollups + 1] = last
        end
        local src = e.src or "other"
        last.xp, last.n = last.xp + e.xp, last.n + 1
        last.frac = last.frac + (e.f or ((e.max and e.max > 0) and e.xp / e.max or 0))
        if src == "kill" then last.xpKill, last.kills = last.xpKill + e.xp, last.kills + 1
        elseif src == "quest" then last.xpQuest, last.quests = last.xpQuest + e.xp, last.quests + 1
        else last.xpOther = last.xpOther + e.xp end
        if (e.lvl or 0) > (last.lvl or 0) then last.lvl = e.lvl end
        last._z = last._z or { [last.zone] = 0 }
        if e.zone and e.zone ~= "" then last._z[e.zone] = (last._z[e.zone] or 0) + e.xp end
    end
    for i = #rollups, 1, -1 do                       -- settle each touched rollup's main zone
        local r = rollups[i]
        if not r._z then break end
        local best, bx = r.zone, -1
        for z, x in pairs(r._z) do if z ~= "" and x > bx then best, bx = z, x end end
        r.zone, r._z = best, nil
    end
    local keep = {}
    for i = count + 1, #log do keep[#keep + 1] = log[i] end
    log = keep
    return count
end

local function rollupOld(now)
    local cutoff, n = now - RAW_DAYS * 86400, 0
    while n < #log and log[n + 1].t < cutoff do n = n + 1 end
    return rollupFirst(n)
end

---------------------------------------------------------------------------
-- logging
---------------------------------------------------------------------------
local function setSrc(e, src)
    e.src = src
end

-- a kill/quest message arrived: tag the XP gain it belongs to (it may come before or after)
local function hintSource(src)
    local now = GetTime()
    if lastEntry and not lastEntry.src and now - lastEntryAt <= HINT_WINDOW then
        setSrc(lastEntry, src)
        if panel and panel:IsShown() then updatePanel() end
    else
        hint[src] = now
    end
end

local function record(gain, frac)
    if lastEntry and not lastEntry.src then lastEntry.src = "other" end
    local e = {
        t = time(),                       -- epoch seconds (real time)
        o = math.floor(chr.online or 0),  -- seconds logged in on this character (gametime)
        xp = gain,
        f = frac,                         -- fraction of a level this gain was worth
        lvl = UnitLevel("player"),
        cur = lastXP,                     -- xp into current level after gain
        max = lastMax,                    -- xp needed for this level
        zone = GetRealZoneText() or "",
    }
    local now = GetTime()
    if now - hint.quest <= HINT_WINDOW then setSrc(e, "quest"); hint.quest = 0
    elseif now - hint.kill <= HINT_WINDOW then setSrc(e, "kill"); hint.kill = 0 end
    log[#log + 1] = e
    lastEntry, lastEntryAt = e, now
    if #log > MAX_LOG then rollupFirst(#log - MAX_LOG + 1000) end
end

local function onXPUpdate()
    local cur, max, level = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
    if not lastXP then lastXP, lastMax, lastLevel = cur, max, level return end
    local gain, frac
    if level > lastLevel or cur < lastXP then          -- crossed a level boundary
        gain = (lastMax - lastXP) + cur
        frac = (lastMax > 0 and (lastMax - lastXP) / lastMax or 0) + (max > 0 and cur / max or 0)
    else
        gain = cur - lastXP
        frac = max > 0 and gain / max or 0
        if max > 0 then db.xpNeed[level] = max end     -- learn this server's XP table
    end
    lastXP, lastMax, lastLevel = cur, max, level
    if gain > 0 then record(gain, frac) end
end

-- totals for the XP logged between two real times
local function levelStats(fromT, toT)
    local st = { kills = 0, quests = 0, xpKill = 0, xpQuest = 0, xpOther = 0, xp = 0, frac = 0, zones = {} }
    for i = #log, 1, -1 do
        local e = log[i]
        if e.t < fromT then break end
        if e.t <= toT then
            local src = e.src or "other"
            st.xp, st.frac = st.xp + e.xp, st.frac + entryFrac(e)
            if src == "kill" then st.kills = st.kills + 1; st.xpKill = st.xpKill + e.xp
            elseif src == "quest" then st.quests = st.quests + 1; st.xpQuest = st.xpQuest + e.xp
            else st.xpOther = st.xpOther + e.xp end
            if e.zone and e.zone ~= "" then st.zones[e.zone] = (st.zones[e.zone] or 0) + e.xp end
        end
    end
    for i = #rollups, 1, -1 do                  -- older, rolled-up stretches of the same range
        local r = rollups[i]
        if r.t + r.len <= fromT then break end
        if r.t >= fromT and r.t <= toT then
            st.xp, st.frac = st.xp + r.xp, st.frac + r.frac
            st.kills, st.quests = st.kills + r.kills, st.quests + r.quests
            st.xpKill, st.xpQuest, st.xpOther = st.xpKill + r.xpKill, st.xpQuest + r.xpQuest, st.xpOther + r.xpOther
            if r.zone ~= "" then st.zones[r.zone] = (st.zones[r.zone] or 0) + r.xp end
        end
    end
    local top, topXP = "", 0
    for z, x in pairs(st.zones) do if x > topXP then top, topXP = z, x end end
    st.zone = top
    return st
end

local function totalPlayedNow()
    if not chr.playedBase then return nil end
    return math.floor(chr.playedBase + ((chr.online or 0) - chr.playedBaseO))
end

local function onLevelUp(newLevel)
    local now, o = time(), math.floor(chr.online or 0)
    local s = chr.levelStart
    if s and s.lvl == newLevel - 1 then
        local st = levelStats(s.t, now)
        local rec = {
            lvl = s.lvl, start = s.t, ding = now,
            real = now - s.t,                       -- realtime, including time logged out
            played = o - s.o,                       -- gametime spent at this level
            playedExact = s.exact or nil,           -- played time anchored to the server's /played
            partial = s.partial or nil,             -- tracking began mid-level: realtime and counts are incomplete
            sessions = s.sessions or 1, deaths = s.deaths or 0,
            kills = st.kills, quests = st.quests,
            xpKill = st.xpKill, xpQuest = st.xpQuest, xpOther = st.xpOther,
            zone = st.zone ~= "" and st.zone or (GetRealZoneText() or ""),
            totalPlayed = totalPlayedNow(),         -- character's total /played at the ding
        }
        chr.levels[#chr.levels + 1] = rec
        print(string.format("|cff88ccffMyXPTracker:|r level %d took %s played%s, %s real%s  |cffaaaaaa(%d kills, %d quests, %d deaths)|r",
            rec.lvl, fmtTime(rec.played), rec.playedExact and "" or "*", fmtTime(rec.real), rec.partial and "*" or "",
            rec.kills, rec.quests, rec.deaths))
    end
    chr.levelStart = { lvl = newLevel, t = now, o = o, exact = true, sessions = 1, deaths = 0 }
    if chr.goal and newLevel >= chr.goal then
        print(string.format("|cff88ccffMyXPTracker:|r goal level %d reached! Set a new one with /mxp goal or in settings.", chr.goal))
        chr.goal = nil
        if refreshSettings then refreshSettings() end
    end
end

-- /played: anchor this level's start to the server's "time played this level"
local restorePlayed
local function restorePlayedChat()
    if restorePlayed then ChatFrame_DisplayTimePlayed = restorePlayed; restorePlayed = nil end
end

local function onTimePlayed(total, thisLevel)
    local s = chr.levelStart
    if s and s.lvl == UnitLevel("player") and thisLevel then
        s.o = math.floor((chr.online or 0) - thisLevel)
        s.exact = true
    end
    if total then chr.playedBase, chr.playedBaseO = total, chr.online or 0 end
    if restorePlayed then
        if C_Timer then C_Timer.After(0.5, restorePlayedChat) else restorePlayedChat() end
    end
end

-- ask the server for /played without printing it in chat
local function requestPlayed()
    if not RequestTimePlayed then return end
    if ChatFrame_DisplayTimePlayed and not restorePlayed then
        restorePlayed = ChatFrame_DisplayTimePlayed
        ChatFrame_DisplayTimePlayed = function() end
        if C_Timer then C_Timer.After(10, restorePlayedChat) end
    end
    RequestTimePlayed()
end

-- Entries logged before gametime tracking have no `o`. Estimate it by walking
-- backwards and treating any gap between gains as at most IDLE_CAP of play.
local function backfillGameTime()
    local refO, refT = chr.online or 0, chr.lastSeen
    for i = #log, 1, -1 do
        local e = log[i]
        if e.o then
            refO, refT = e.o, e.t
        else
            refT = refT or e.t
            local gap = math.max(0, refT - e.t)
            e.o = math.floor(refO - math.min(gap, IDLE_CAP))
            e.oa = true                    -- marks an estimated gametime
            refO, refT = e.o, e.t
        end
    end
end

---------------------------------------------------------------------------
-- hover panel (rates + graph)
---------------------------------------------------------------------------
local function backdrop(f, alpha)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f:SetBackdropColor(0, 0, 0, alpha)
    end
end

local function makeButton(parent, label, w)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 18)
    b:SetText(label)
    return b
end

local function over(f)
    if not f or not f:IsShown() then return false end
    if f.IsMouseOver then return f:IsMouseOver() and true or false end
    if MouseIsOver then return MouseIsOver(f) and true or false end
    return false
end

local hideAt
local hist, timerZone, timer, updateHistory
local function showPanel()
    hideAt = nil
    if hist and hist:IsShown() then hist:Hide() end
    if panel and not panel:IsShown() then panel:Show(); updatePanel() end
end
local function showHistory()
    hideAt = nil
    if panel and panel:IsShown() then panel:Hide() end
    if hist and not hist:IsShown() then hist:Show(); updateHistory() end
end
local function scheduleHide()
    hideAt = GetTime() + 0.25
end

local function showBarTip(i)
    local d = panel.data[i]
    local hit = panel.hits[i]
    GameTooltip:SetOwner(hit, "ANCHOR_TOP")
    if db.gameTime then
        GameTooltip:AddLine(ago(d.startAge) .. " - " .. ago(d.endAge) .. "  (gametime)")
    else
        local now = time()
        local f = (d.startAge > 6 * 3600) and "%a %H:%M" or "%H:%M"
        GameTooltip:AddLine(date(f, math.floor(now - d.startAge)) .. " - " .. date("%H:%M", math.floor(now - d.endAge)) .. "  (realtime)")
    end
    if d.n == 0 then
        GameTooltip:AddLine("No XP gained", 0.6, 0.6, 0.6)
        GameTooltip:AddDoubleLine("Trend (" .. shortDur(d.trendSpan) .. " avg)", fmt(d.trend) .. " xp/hr", 1, 1, 1, 1, 1, 1)
    else
        GameTooltip:AddDoubleLine("XP gained", fmt(d.xp), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Rate", fmt(d.rate) .. " xp/hr", 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Level pace", pct(d.lvlRate) .. " lvl/hr", 1, 1, 1, 0.53, 0.8, 1)
        GameTooltip:AddDoubleLine("Trend (" .. shortDur(d.trendSpan) .. " avg)", fmt(d.trend) .. " xp/hr", 1, 1, 1, 1, 1, 1)
        for _, src in ipairs(SRC_ORDER) do
            local x = d.by[src]
            if x > 0 then
                local c = SRC[src]
                local v = fmt(x) .. " xp"
                if src == "kill" then v = string.format("%d kills, %s xp (avg %s)", d.kills, fmt(x), fmt(x / d.kills)) end
                GameTooltip:AddDoubleLine(c[4]:gsub("^%l", string.upper), v, c[1], c[2], c[3], 1, 1, 1)
            end
        end
        local lvl = (d.lvlMin == d.lvlMax) and tostring(d.lvlMin)
            or string.format("%d -> %d |cffffd100(ding!)|r", d.lvlMin, d.lvlMax)
        GameTooltip:AddDoubleLine("Level", lvl, 1, 1, 1, 1, 1, 1)
        local zones = {}
        for z = 1, math.min(3, #d.zoneList) do zones[z] = d.zoneList[z] end
        if #d.zoneList > 3 then zones[#zones + 1] = "+" .. (#d.zoneList - 3) end
        if #zones > 0 then GameTooltip:AddDoubleLine("Zone", table.concat(zones, ", "), 1, 1, 1, 1, 1, 1) end
        if db.gameTime then
            GameTooltip:AddDoubleLine("Realtime", date("%a %H:%M", d.tFirst) .. " - " .. date("%H:%M", d.tLast),
                1, 1, 1, 0.8, 0.8, 0.8)
            if d.approx then GameTooltip:AddLine("Gametime estimated for older entries", 0.6, 0.6, 0.6) end
        end
        if d.clipped then GameTooltip:AddLine("Bar cut off at top of scale (quest-sized XP)", 1, 1, 1) end
        if d.unknown then GameTooltip:AddLine("Older entries have no kill/quest tag (shown as other)", 0.6, 0.6, 0.6) end
    end
    GameTooltip:Show()
end

local function createPanel()
    panel = CreateFrame("Frame", "MyXPTrackerPanel", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetSize(PANEL_W, 300)
    panel:SetFrameStrata("DIALOG")        -- below TOOLTIP so bar tooltips draw on top
    panel:SetClampedToScreen(true)
    backdrop(panel, 0.92)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 8, -9)
    title:SetText("MyXPTracker")

    -- [-] [span] [+] [Realtime/Gametime]
    panel.mode = makeButton(panel, "Realtime", 70)
    panel.mode:SetPoint("TOPRIGHT", -6, -4)
    panel.plus = makeButton(panel, "+", 18)
    panel.plus:SetPoint("RIGHT", panel.mode, "LEFT", -4, 0)
    panel.spanText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.spanText:SetWidth(28)
    panel.spanText:SetPoint("RIGHT", panel.plus, "LEFT", -2, 0)
    panel.minus = makeButton(panel, "-", 18)
    panel.minus:SetPoint("RIGHT", panel.spanText, "LEFT", -2, 0)

    panel.minus:SetScript("OnClick", function() stepSpan(-1); updatePanel() end)
    panel.plus:SetScript("OnClick", function() stepSpan(1); updatePanel() end)

    -- gear button (same style as - / +) opens settings
    panel.gear = makeButton(panel, "", 18)
    panel.gear:SetPoint("RIGHT", panel.minus, "LEFT", -4, 0)
    local gi = panel.gear:CreateTexture(nil, "OVERLAY")
    gi:SetSize(11, 11)
    gi:SetPoint("CENTER", 0, 0)
    gi:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
    gi:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    panel.gear.icon = gi
    panel.gear:SetScript("OnClick", function() toggleSettings() end)
    panel.mode:SetScript("OnClick", function() db.gameTime = not db.gameTime; updatePanel() end)

    panel.avgLabels = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.avgLabels:SetPoint("TOPLEFT", 8, -28)
    panel.avgLabels:SetJustifyH("LEFT")
    panel.avgLabels:SetSpacing(2)
    panel.avgValues = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.avgValues:SetPoint("TOPRIGHT", -8, -28)
    panel.avgValues:SetJustifyH("RIGHT")
    panel.avgValues:SetSpacing(2)
    panel.sep = panel:CreateTexture(nil, "ARTWORK")
    panel.sep:SetColorTexture(0.5, 0.5, 0.5, 0.8)
    panel.sep:SetHeight(1)

    panel.labels = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.labels:SetJustifyH("LEFT")
    panel.labels:SetSpacing(2)
    panel.values = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.values:SetJustifyH("RIGHT")
    panel.values:SetSpacing(2)

    panel.graphTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panel.legend = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    local leg = {}
    for _, src in ipairs(SRC_ORDER) do leg[#leg + 1] = "|cff" .. hex(SRC[src]) .. SRC[src][4] .. "|r" end
    panel.legend:SetText(table.concat(leg, "  "))

    -- axes, gridlines and y labels (0, half, top)
    local yAxis = panel:CreateTexture(nil, "BORDER")
    yAxis:SetColorTexture(0.6, 0.6, 0.6, 0.8)
    yAxis:SetSize(1, PLOT_H)
    yAxis:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PLOT_LEFT - 2, PLOT_BOTTOM)
    local xAxis = panel:CreateTexture(nil, "BORDER")
    xAxis:SetColorTexture(0.6, 0.6, 0.6, 0.8)
    xAxis:SetSize(PLOT_W + 2, 1)
    xAxis:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PLOT_LEFT - 2, PLOT_BOTTOM - 1)
    panel.yLabels = {}
    for k, frac in ipairs({ 0, 0.5, 1 }) do
        if frac > 0 then
            local g = panel:CreateTexture(nil, "BORDER")
            g:SetColorTexture(1, 1, 1, 0.12)
            g:SetSize(PLOT_W, 1)
            g:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PLOT_LEFT, PLOT_BOTTOM + frac * PLOT_H)
        end
        local l = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        l:SetTextColor(0.75, 0.75, 0.75)
        l:SetJustifyH("RIGHT")
        l:SetPoint("RIGHT", panel, "BOTTOMLEFT", PLOT_LEFT - 5, PLOT_BOTTOM + frac * PLOT_H)
        panel.yLabels[k] = { label = l, frac = frac }
    end

    panel.bars, panel.hits, panel.data = {}, {}, {}
    for i = 1, GRAPH_BARS do
        panel.bars[i] = {}
        for _, src in ipairs(SRC_ORDER) do panel.bars[i][src] = panel:CreateTexture(nil, "ARTWORK") end
        panel.bars[i].empty = panel:CreateTexture(nil, "ARTWORK")
        panel.bars[i].cap = panel:CreateTexture(nil, "OVERLAY")
        panel.data[i] = {}
        local h = CreateFrame("Frame", nil, panel)
        h:SetSize(BAR_W, PLOT_H)
        h:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PLOT_LEFT + (i - 1) * BAR_W, PLOT_BOTTOM)
        h:EnableMouse(true)
        h:SetScript("OnEnter", function()
            showPanel(); panel.hoverIdx = i; updatePanel()
        end)
        h:SetScript("OnLeave", function()
            if panel.hoverIdx == i then panel.hoverIdx = nil end
            GameTooltip:Hide(); scheduleHide(); updatePanel()
        end)
        panel.hits[i] = h
    end

    -- trend line (moving average) drawn over the bars
    panel.lines, panel.dots = {}, {}
    for i = 1, GRAPH_BARS do
        local dot = panel:CreateTexture(nil, "OVERLAY")
        dot:SetColorTexture(1, 1, 1, 0.95)
        dot:SetSize(3, 3)
        panel.dots[i] = dot
        if i < GRAPH_BARS and panel.CreateLine then
            local ln = panel:CreateLine(nil, "OVERLAY")
            if ln then
                ln:SetThickness(2)
                ln:SetColorTexture(1, 1, 1, 0.85)
                panel.lines[i] = ln
            end
        end
    end

    local function xLabel(point, x)
        local l = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        l:SetTextColor(0.75, 0.75, 0.75)
        l:SetPoint(point, panel, "BOTTOMLEFT", x, 9)
        return l
    end
    panel.axisL = xLabel("LEFT", PLOT_LEFT - 2)
    panel.axisM = xLabel("CENTER", PLOT_LEFT + PLOT_W / 2)
    panel.axisR = xLabel("RIGHT", PLOT_LEFT + PLOT_W)
    panel.axisR:SetText("now")

    panel:SetScript("OnHide", function()
        panel.hoverIdx = nil
        if GameTooltip:GetOwner() and GameTooltip:GetOwner():GetParent() == panel then GameTooltip:Hide() end
    end)
end

local function drawGraph(now)
    local span, spanLabel = SPANS[db.spanIdx][1], SPANS[db.spanIdx][2]
    local bucket = span / GRAPH_BARS
    local game = db.gameTime
    local nowRef = game and (chr.online or 0) or now

    for i = 1, GRAPH_BARS do
        local d = panel.data[i]
        d.xp, d.n, d.kills, d.frac, d.approx, d.unknown, d.spike = 0, 0, 0, 0, false, false, 0
        d.by = { kill = 0, quest = 0, other = 0 }
        d.lvlMin, d.lvlMax, d.tFirst, d.tLast = nil, nil, nil, nil
        d.zones, d.zoneList = {}, {}
        d.startAge = (GRAPH_BARS - i + 1) * bucket
        d.endAge = (GRAPH_BARS - i) * bucket
    end

    local smooth = db.smooth
    local pre = {}                          -- xp in the (smooth-1) buckets before the span
    for k = 1, smooth do pre[k] = 0 end
    local inView, sizes = {}, {}
    for i = #log, 1, -1 do
        local e = log[i]
        local stamp = game and e.o or e.t
        if not stamp then break end
        local age = math.max(0, nowRef - stamp)
        if age >= span + (smooth - 1) * bucket then break end
        if age >= span then
            local k = math.floor((age - span) / bucket) + 1
            pre[k] = pre[k] + e.xp
        else
            inView[#inView + 1] = { e, GRAPH_BARS - math.floor(age / bucket) }
            sizes[#sizes + 1] = e.xp
        end
    end
    table.sort(sizes)
    local median = sizes[math.floor((#sizes + 1) / 2)] or 0

    for _, v in ipairs(inView) do
        local e, d = v[1], panel.data[v[2]]
        local src = e.src or "other"
        d.xp, d.n = d.xp + e.xp, d.n + 1
        d.by[src] = d.by[src] + e.xp
        if src == "quest" or (median > 0 and e.xp >= SPIKE_MULT * median) then
            d.spike = d.spike + e.xp            -- quest-sized gain: left out of the auto scale
        end
        d.frac = d.frac + entryFrac(e)
        if src == "kill" then d.kills = d.kills + 1 end
        if not e.src and e ~= lastEntry then d.unknown = true end
        if not d.lvlMin or e.lvl < d.lvlMin then d.lvlMin = e.lvl end
        if not d.lvlMax or e.lvl > d.lvlMax then d.lvlMax = e.lvl end
        d.tFirst = e.t                      -- walking backwards: last write = earliest
        d.tLast = d.tLast or e.t
        if e.zone and e.zone ~= "" and not d.zones[e.zone] then
            d.zones[e.zone] = true
            d.zoneList[#d.zoneList + 1] = e.zone
        end
        if e.oa then d.approx = true end
    end

    -- Scale: full = tallest bar / trend point; base = tallest bar without quest-sized spikes.
    -- With clipping on, the axis follows `base` and anything taller is cut off with a cap.
    local full, base = 0, 0
    for i = 1, GRAPH_BARS do
        local d = panel.data[i]
        d.rate = d.xp / bucket * 3600
        d.lvlRate = d.frac / bucket * 3600 * 100
        full = math.max(full, d.rate)
        base = math.max(base, (d.xp - d.spike) / bucket * 3600)
    end
    -- trailing moving average over `smooth` bars (reaching into `pre` for the first bars)
    for i = 1, GRAPH_BARS do
        local sum = 0
        for j = i - smooth + 1, i do
            if j >= 1 then sum = sum + panel.data[j].xp else sum = sum + pre[1 - j] end
        end
        local d = panel.data[i]
        d.trend = sum / (smooth * bucket) * 3600
        d.trendSpan = smooth * bucket
        full = math.max(full, d.trend)
    end
    local top = niceCeil(full)
    if db.clip and base > 0 then top = math.min(top, niceCeil(base * 1.2)) end
    for i = 1, GRAPH_BARS do panel.data[i].clipped = panel.data[i].rate > top * 1.001 end

    panel.graphTitle:SetText(string.format("XP/hr  |cffaaaaaa%s bars, |cffffffffline|r %s|r",
        shortDur(bucket), shortDur(bucket * smooth)))
    for _, y in ipairs(panel.yLabels) do
        y.label:SetText(top > 0 and fmt(top * y.frac) or (y.frac == 0 and "0" or ""))
    end
    panel.axisL:SetText("-" .. spanLabel)
    panel.axisM:SetText("-" .. shortDur(span / 2))

    local w = math.max(1, BAR_W - 1)
    for i = 1, GRAPH_BARS do
        local d, set = panel.data[i], panel.bars[i]
        local hl = (panel.hoverIdx == i) and 0.3 or 0
        local x = PLOT_LEFT + (i - 1) * BAR_W
        local y = PLOT_BOTTOM
        for _, src in ipairs(SRC_ORDER) do
            local tex = set[src]
            local amt = d.by[src]
            local room = PLOT_BOTTOM + PLOT_H - y
            if amt > 0 and top > 0 and room >= 1 then
                local h = math.min(room, math.max(1, (amt / bucket * 3600) / top * PLOT_H))
                local c = SRC[src]
                tex:ClearAllPoints()
                tex:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", x, y)
                tex:SetSize(w, h)
                tex:SetColorTexture(math.min(1, c[1] + hl), math.min(1, c[2] + hl), math.min(1, c[3] + hl), 0.95)
                tex:Show()
                y = y + h
            else
                tex:Hide()
            end
        end
        if d.clipped then
            set.cap:ClearAllPoints()
            set.cap:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", x - 1, PLOT_BOTTOM + PLOT_H - 1)
            set.cap:SetSize(w + 2, 3)
            set.cap:SetColorTexture(1, 1, 1, 0.9)
            set.cap:Show()
        else
            set.cap:Hide()
        end
        if d.xp == 0 then
            set.empty:ClearAllPoints()
            set.empty:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", x, PLOT_BOTTOM)
            set.empty:SetSize(w, hl > 0 and 3 or 1)
            set.empty:SetColorTexture(0.5, 0.5, 0.5, hl > 0 and 0.9 or 0.6)
            set.empty:Show()
        else
            set.empty:Hide()
        end
    end

    local pts = {}
    for i = 1, GRAPH_BARS do
        local x = PLOT_LEFT + (i - 0.5) * BAR_W
        local y = PLOT_BOTTOM + (top > 0 and math.min(1, panel.data[i].trend / top) * PLOT_H or 0)
        pts[i] = { x, y }
        local dot = panel.dots[i]
        dot:ClearAllPoints()
        dot:SetPoint("CENTER", panel, "BOTTOMLEFT", x, y)
        dot:SetShown(top > 0 and (panel.hoverIdx == i or not panel.lines[1]))
    end
    for i = 1, GRAPH_BARS - 1 do
        local ln = panel.lines[i]
        if ln then
            ln:SetStartPoint("BOTTOMLEFT", panel, pts[i][1], pts[i][2])
            ln:SetEndPoint("BOTTOMLEFT", panel, pts[i + 1][1], pts[i + 1][2])
            ln:SetShown(top > 0)
        end
    end
end

updatePanel = function()
    if not panel then return end
    local now = time()
    local L, V = {}, {}
    local function row(l, v) L[#L + 1] = l; V[#V + 1] = v end

    local s15, s1h
    local AL, AV = {}, {}
    for _, w in ipairs(PANEL_WINDOWS) do
        local s = windowStats(w[1], now)
        if w[1] == 900 then s15 = s elseif w[1] == 3600 then s1h = s end
        AL[#AL + 1] = w[2] .. " average"
        AV[#AV + 1] = string.format("%s xp/hr  |cff88ccff%s lvl/hr|r", fmt(s.rate), pct(s.lvlRate))
    end
    do
        local s30 = windowStats(db.effWindow, now)
        local score = s30.lvlRate * db.paceHours
        local r, g, b = effColor(score)
        local hpl = s30.lvlRate > 0 and (100 / s30.lvlRate * 3600) or nil
        row("Efficiency (" .. shortDur(db.effWindow) .. ")", string.format("|cff%02x%02x%02x%d|r  %s/lvl  |cffaaaaaa(100 = %s)|r",
            math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), math.floor(score + 0.5),
            hpl and fmtTime(hpl) or "--", shortDur(db.paceHours * 3600)))
    end
    local ss = levelStats(sessionStart, now)
    row("Session " .. fmtTime(now - sessionStart), string.format("%s xp, |cff88ccff%.1f lvl|r, %d kills, %d quests",
        fmt(ss.xp), ss.frac, ss.kills, ss.quests))

    local need = lastMax - lastXP
    row("To " .. (lastLevel + 1) .. " (1h rate)", eta(need, s1h.rate))
    row("Kills last hour", string.format("%d  |cffaaaaaa(%s/hr)|r", s1h.kills, fmt(s1h.killRate)))
    local avgKill = (s1h.kills > 0) and (s1h.killXP / s1h.kills) or recentKillAvg()
    row("Kills to level", avgKill and string.format("~%d  |cffaaaaaa(avg %s xp)|r", math.ceil(need / avgKill), fmt(avgKill)) or "--")

    local ls = chr.levelStart
    if ls and ls.lvl == lastLevel then
        row("Level " .. lastLevel .. " so far", fmtTime((chr.online or 0) - ls.o) .. " played" .. (ls.exact and "" or "*"))
    end
    if chr.goal then
        local x, est = xpToReach(chr.goal)
        local r = s1h.rate > 0 and s1h.rate or s15.rate
        if x then
            row("Goal " .. chr.goal .. (est and " (est.)" or ""), fmt(x) .. " xp, " .. eta(x, r))
        else
            row("Goal " .. chr.goal, "XP table unknown")
        end
    end

    panel.avgLabels:SetText(table.concat(AL, "\n"))
    panel.avgValues:SetText(table.concat(AV, "\n"))
    panel.labels:SetText(table.concat(L, "\n"))
    panel.values:SetText(table.concat(V, "\n"))

    -- layout: averages, 1px separator, other stats, then the graph
    local sepY = 28 + panel.avgLabels:GetStringHeight() + 4
    panel.sep:ClearAllPoints()
    panel.sep:SetPoint("TOPLEFT", 8, -sepY)
    panel.sep:SetPoint("TOPRIGHT", -8, -sepY)
    local restY = sepY + 5
    panel.labels:ClearAllPoints()
    panel.labels:SetPoint("TOPLEFT", 8, -restY)
    panel.values:ClearAllPoints()
    panel.values:SetPoint("TOPRIGHT", -8, -restY)
    local titleY = restY + panel.labels:GetStringHeight() + 10

    panel.graphTitle:ClearAllPoints()
    panel.graphTitle:SetPoint("TOPLEFT", 8, -titleY)
    panel.legend:ClearAllPoints()
    panel.legend:SetPoint("TOPRIGHT", -8, -titleY)
    panel:SetHeight(titleY + 14 + 10 + PLOT_H + PLOT_BOTTOM)

    panel.spanText:SetText(SPANS[db.spanIdx][2])
    panel.mode:SetText(db.gameTime and "Gametime" or "Realtime")
    drawGraph(now)

    if panel.hoverIdx then showBarTip(panel.hoverIdx) end
end

---------------------------------------------------------------------------
-- level history panel (hover the level timer on the bar)
---------------------------------------------------------------------------
local function createHistory()
    hist = CreateFrame("Frame", "MyXPTrackerHistory", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    hist:SetSize(PANEL_W, 120)
    hist:SetFrameStrata("DIALOG")
    hist:SetClampedToScreen(true)
    backdrop(hist, 0.92)
    hist:EnableMouse(true)
    hist:Hide()
    local title = hist:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 8, -9)
    title:SetText("Level history")
    hist.sub = hist:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hist.sub:SetPoint("TOPRIGHT", -8, -11)
    hist.cols = {}
    local x = 8
    for k, c in ipairs(RECENT_COLS) do
        local fs = hist:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetWidth(c[2])
        fs:SetJustifyH(k == 1 and "LEFT" or "RIGHT")
        fs:SetSpacing(2)
        fs:SetPoint("TOPLEFT", x, -30)
        hist.cols[k] = fs
        x = x + c[2]
    end
    hist.sep = hist:CreateTexture(nil, "ARTWORK")
    hist.sep:SetColorTexture(0.5, 0.5, 0.5, 0.8)
    hist.sep:SetHeight(1)
    hist.foot = hist:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hist.foot:SetJustifyH("LEFT")
    hist.foot:SetSpacing(2)
    hist.foot:SetWidth(PANEL_W - 16)
    hist:SetScript("OnEnter", showHistory)
    hist:SetScript("OnLeave", function() hideAt = GetTime() + 0.25 end)
end

updateHistory = function()
    if not hist then return end
    local now, n = time(), db.recentLevels
    local cols = {}
    for k, c in ipairs(RECENT_COLS) do cols[k] = { "|cffffd100" .. c[1] .. "|r" } end
    local function add(color, v)
        for k = 1, #RECENT_COLS do cols[k][#cols[k] + 1] = color and ("|cff" .. color .. v[k] .. "|r") or tostring(v[k]) end
    end
    local starred = false
    local ls = chr.levelStart
    if ls and ls.lvl == lastLevel then                         -- the level in progress
        local st = levelStats(ls.t, now)
        starred = starred or not ls.exact or ls.partial
        add("88ccff", { lastLevel .. " now",
            fmtTime((chr.online or 0) - ls.o) .. (ls.exact and "" or "*"),
            fmtTime(now - ls.t) .. (ls.partial and "*" or ""),
            st.kills, st.quests, ls.deaths or 0 })
    end
    local shown, sumP, cntP, deaths, haveDeaths = 0, 0, 0, 0, false
    for i = #chr.levels, math.max(1, #chr.levels - n + 1), -1 do
        local l = chr.levels[i]
        local k, q = l.kills, l.quests
        if k == nil then                                       -- recorded before per-level counts existed
            local st = recentCache[l]
            if not st then st = levelStats(l.start, l.ding); recentCache[l] = st end
            k, q = st.kills, st.quests
        end
        starred = starred or not l.playedExact or l.partial
        add(nil, { tostring(l.lvl), fmtTime(l.played) .. (l.playedExact and "" or "*"),
            fmtTime(l.real) .. (l.partial and "*" or ""), k, q, l.deaths or "--" })
        shown = shown + 1
        if not l.partial then sumP, cntP = sumP + l.played, cntP + 1 end
        if l.deaths then deaths, haveDeaths = deaths + l.deaths, true end
    end
    for k = 1, #RECENT_COLS do hist.cols[k]:SetText(table.concat(cols[k], "\n")) end
    hist.sub:SetText(string.format("last %d", n))

    local foot = {}
    if shown == 0 then
        foot[#foot + 1] = "|cffaaaaaaNo completed levels yet. Each level-up is recorded from now on.|r"
    else
        foot[#foot + 1] = string.format("Avg played per level: |cffffffff%s|r%s",
            cntP > 0 and fmtTime(sumP / cntP) or "--", haveDeaths and string.format("   Deaths: |cffffffff%d|r", deaths) or "")
    end
    if starred then foot[#foot + 1] = "|cffaaaaaa* tracking began part-way through the level|r" end
    local tableH = hist.cols[1]:GetStringHeight()
    hist.sep:ClearAllPoints()
    hist.sep:SetPoint("TOPLEFT", 8, -(30 + tableH + 5))
    hist.sep:SetPoint("TOPRIGHT", -8, -(30 + tableH + 5))
    hist.foot:ClearAllPoints()
    hist.foot:SetPoint("TOPLEFT", 8, -(30 + tableH + 10))
    hist.foot:SetText(table.concat(foot, "\n"))
    hist:SetHeight(30 + tableH + 10 + hist.foot:GetStringHeight() + 10)
end

---------------------------------------------------------------------------
-- export window (copy/paste CSV)
---------------------------------------------------------------------------
local exportFrame
local function showExport(title, body)
    if not exportFrame then
        local f = CreateFrame("Frame", "MyXPTrackerExport", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        f:SetSize(560, 380)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        backdrop(f, 0.95)
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.title:SetPoint("TOPLEFT", 10, -10)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 0, 0)
        local sf = CreateFrame("ScrollFrame", "MyXPTrackerExportScroll", f, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 10, -32)
        sf:SetPoint("BOTTOMRIGHT", -30, 10)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetFontObject(ChatFontNormal)
        eb:SetWidth(510)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        sf:SetScrollChild(eb)
        f.eb = eb
        exportFrame = f
    end
    exportFrame.title:SetText(title .. "  |cffaaaaaa(Ctrl+A, Ctrl+C to copy)|r")
    exportFrame.eb:SetText(body)
    exportFrame:Show()
    exportFrame.eb:SetFocus()
    exportFrame.eb:HighlightText()
end

local function csvQuote(s) return '"' .. tostring(s or ""):gsub('"', '""') .. '"' end
local function iso(t) return t and date("%Y-%m-%d %H:%M:%S", t) or "" end

local function exportLevels()
    local out = { "level,started,dinged,played_seconds,real_seconds,played_exact,realtime_partial,sessions,deaths,"
        .. "kills,quests,xp_kills,xp_quests,xp_other,total_played_seconds,zone" }
    for _, l in ipairs(chr.levels) do
        out[#out + 1] = string.format("%d,%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%s,%s",
            l.lvl, iso(l.start), iso(l.ding), l.played, l.real, l.playedExact and 1 or 0, l.partial and 1 or 0,
            l.sessions or 1, l.deaths or 0, l.kills or 0, l.quests or 0, l.xpKill or 0, l.xpQuest or 0, l.xpOther or 0,
            l.totalPlayed and tostring(l.totalPlayed) or "", csvQuote(l.zone))
    end
    showExport("Level history: " .. charKey, table.concat(out, "\n"))
end

local function exportLog()
    local out = { "time,played_seconds,xp,level_fraction,level,xp_into_level,xp_level_max,source,zone" }
    local first = math.max(1, #log - 4999)
    for i = first, #log do
        local e = log[i]
        out[#out + 1] = string.format("%s,%d,%d,%.5f,%d,%d,%d,%s,%s", iso(e.t), e.o or 0, e.xp, entryFrac(e),
            e.lvl or 0, e.cur or 0, e.max or 0, e.src or "", csvQuote(e.zone))
    end
    showExport(string.format("XP log (last %d): %s", #log - first + 1, charKey), table.concat(out, "\n"))
end

---------------------------------------------------------------------------
-- top bar
---------------------------------------------------------------------------
local function refresh()
    local now = time()
    local parts = {}
    for _, w in ipairs(WINDOWS) do
        local s = windowStats(w[1], now)
        if w[1] == 3600 then
            parts[#parts + 1] = string.format("|cffaaaaaa%s|r %s |cff88ccff%s|r", w[2], fmt(s.rate), pct(s.lvlRate))
        else
            parts[#parts + 1] = string.format("|cffaaaaaa%s|r %s", w[2], fmt(s.rate))
        end
    end
    text:SetText("XP/hr  " .. table.concat(parts, "   "))
    local tw = 0
    local ls = chr.levelStart
    if db.showTimer and ls and ls.lvl == lastLevel then
        timer:SetText(string.format("L%d  %s", lastLevel, fmtTime((chr.online or 0) - ls.o)))
        tw = timer:GetStringWidth() + 22
        timerZone:SetWidth(tw)
        timerZone:Show()
    else
        timerZone:Hide()
    end
    frame:SetWidth(math.max(220, text:GetStringWidth() + 24 + tw))
    if hist and hist:IsShown() then updateHistory() end

    eff:SetShown(db.showEff)
    local s30 = windowStats(db.effWindow, now)
    local score = s30.lvlRate * db.paceHours
    local inner = frame:GetWidth() - 6
    local r, g, b = effColor(score)
    eff.fill:SetWidth(math.max(1, inner * math.min(score, 100) / 100))
    eff.fill:SetColorTexture(r, g, b, 1)
    for _, t in ipairs(eff.ticks) do
        t.tex:ClearAllPoints()
        t.tex:SetPoint("LEFT", eff, "LEFT", math.floor(inner * t.v / 100), 0)
    end
    if panel and panel:IsShown() then updatePanel() end
end

local function setGoal(n, quiet)
    if not n or n <= lastLevel then
        chr.goal = nil
        if not quiet then print("MyXPTracker: goal cleared. Usage: /mxp goal <level>") end
        return
    end
    chr.goal = math.floor(n)
    local x, est = xpToReach(chr.goal)
    local s = windowStats(3600, time())
    print(string.format("MyXPTracker: goal level %d, %s xp to go%s, ETA %s at 1h rate",
        chr.goal, x and fmt(x) or "?", est and " (default XP table)" or "", x and eta(x, s.rate) or "--"))
end

local function applyPosition()
    frame:ClearAllPoints()
    local p = db.pos
    frame:SetPoint(p.point, UIParent, p.rel, p.x, p.y)
end

---------------------------------------------------------------------------
-- settings window
---------------------------------------------------------------------------
local settings
local sliderN = 0

local function makeCheck(parent, label, x, y, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("TOPLEFT", x, y)
    cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 1, 0)
    cb.label:SetText(label)
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false, self) end)
    return cb
end

local function makeSlider(parent, x, y, w, minV, maxV, step, onChange)
    sliderN = sliderN + 1
    local name = "MyXPTrackerSlider" .. sliderN
    local ok, sl = pcall(CreateFrame, "Slider", name, parent, "OptionsSliderTemplate")
    if not ok or not sl then
        sl = CreateFrame("Slider", name, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        sl:SetOrientation("HORIZONTAL")
        sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
        if sl.SetBackdrop then
            sl:SetBackdrop({ bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
                edgeFile = "Interface\\Buttons\\UI-SliderBar-Border", tile = true, tileSize = 8, edgeSize = 8,
                insets = { left = 3, right = 3, top = 6, bottom = 6 } })
        end
    end
    for _, suffix in ipairs({ "Low", "High", "Text" }) do
        local r = _G[name .. suffix]
        if r then r:SetText("") end
    end
    sl:SetSize(w, 16)
    sl:SetPoint("TOPLEFT", x, y)
    sl:SetMinMaxValues(minV, maxV)
    sl:SetValueStep(step)
    if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
    sl.label = sl:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sl.label:SetPoint("BOTTOMLEFT", sl, "TOPLEFT", 0, 3)
    sl:SetScript("OnValueChanged", function(self, v)
        if self.updating then return end
        onChange(math.floor(v / step + 0.5) * step, self)
    end)
    return sl
end

local function setSlider(sl, v)
    sl.updating = true
    sl:SetValue(v)
    sl.updating = false
end

local function header(parent, textStr, y)
    local h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h:SetPoint("TOPLEFT", 12, y)
    h:SetText(textStr)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.5, 0.5, 0.5, 0.6)
    line:SetHeight(1)
    line:SetPoint("LEFT", h, "RIGHT", 6, 0)
    line:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
end

local function applyAll()
    if frame then refresh() end
    if panel and panel:IsShown() then updatePanel() end
    if hist and hist:IsShown() then updateHistory() end
    refreshSettings()
end

local function createSettings()
    local S = CreateFrame("Frame", "MyXPTrackerSettings", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    settings = S
    S:SetSize(300, 500)
    S:SetPoint("CENTER")
    S:SetFrameStrata("DIALOG")
    S:SetToplevel(true)
    S:SetClampedToScreen(true)
    backdrop(S, 0.95)
    S:EnableMouse(true)
    S:SetMovable(true)
    S:RegisterForDrag("LeftButton")
    S:SetScript("OnDragStart", S.StartMoving)
    S:SetScript("OnDragStop", S.StopMovingOrSizing)
    S:Hide()
    if UISpecialFrames then table.insert(UISpecialFrames, "MyXPTrackerSettings") end   -- Esc closes

    local t = S:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", 12, -12)
    t:SetText("MyXPTracker settings")
    local close = CreateFrame("Button", nil, S, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    -- Efficiency bar ------------------------------------------------------
    header(S, "Efficiency bar", -42)
    S.showEff = makeCheck(S, "Show efficiency bar", 12, -60, function(v) db.showEff = v; applyAll() end)

    S.pace = makeSlider(S, 18, -106, 264, 2, 24, 1, function(v) db.paceHours = v / 2; applyAll() end)
    S.paceNote = S:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    S.paceNote:SetPoint("TOPLEFT", S.pace, "BOTTOMLEFT", 0, -3)

    S.effLabel = S:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    S.effLabel:SetPoint("TOPLEFT", 16, -146)
    S.effLabel:SetText("Average over:")
    S.effChecks = {}
    for k, w in ipairs(EFF_WINDOWS) do
        S.effChecks[k] = makeCheck(S, w[2], 90 + (k - 1) * 50, -140, function()
            db.effWindow = w[1]; applyAll()
        end)
    end

    -- Graph ---------------------------------------------------------------
    header(S, "Graph", -178)
    S.spanLabel = S:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    S.spanLabel:SetPoint("TOPLEFT", 16, -200)
    S.spanLabel:SetText("Zoom levels shown by - / +:")
    S.spanChecks = {}
    for i, sp in ipairs(SPANS) do
        local col, rowN = (i - 1) % 3, math.floor((i - 1) / 3)
        S.spanChecks[i] = makeCheck(S, sp[2], 16 + col * 90, -214 - rowN * 22, function(v, cb)
            if not v then
                local n = 0
                for j = 1, #SPANS do if spanOn(j) then n = n + 1 end end
                if n <= 1 then cb:SetChecked(true) return end      -- keep at least one
            end
            db.spansOn[i] = v
            fixSpan()
            applyAll()
        end)
    end

    S.smooth = makeSlider(S, 18, -284, 264, 1, 15, 1, function(v) db.smooth = v; applyAll() end)
    S.clip = makeCheck(S, "Cut off quest-sized spikes", 12, -306, function(v) db.clip = v; applyAll() end)

    -- General -------------------------------------------------------------
    header(S, "General", -338)
    S.lock = makeCheck(S, "Lock position", 12, -356, function(v) db.locked = v end)
    local reset = CreateFrame("Button", nil, S, "UIPanelButtonTemplate")
    reset:SetSize(110, 20)
    reset:SetPoint("TOPRIGHT", -14, -357)
    reset:SetText("Reset position")
    reset:SetScript("OnClick", function()
        db.pos = { point = "TOP", rel = "TOP", x = 0, y = -12 }
        applyPosition()
    end)

    local gl = S:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    gl:SetPoint("TOPLEFT", 16, -392)
    gl:SetText("Goal level:")
    S.goal = CreateFrame("EditBox", nil, S, "InputBoxTemplate")
    S.goal:SetSize(36, 20)
    S.goal:SetPoint("LEFT", gl, "RIGHT", 10, 0)
    S.goal:SetAutoFocus(false)
    S.goal:SetNumeric(true)
    S.goal:SetMaxLetters(2)
    S.goal:SetScript("OnEnterPressed", function(self)
        setGoal(tonumber(self:GetText()), true)
        self:ClearFocus()
        applyAll()
    end)
    S.goal:SetScript("OnEscapePressed", function(self) self:ClearFocus(); refreshSettings() end)
    local gh = S:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    gh:SetPoint("LEFT", S.goal, "RIGHT", 8, 0)
    gh:SetText("Enter to set, blank to clear")

    S.recent = makeSlider(S, 18, -436, 264, 1, 20, 1, function(v) db.recentLevels = v; applyAll() end)
    S.timer = makeCheck(S, "Show level timer on the bar (hover it for level history)", 12, -460,
        function(v) db.showTimer = v; applyAll() end)

    S:SetScript("OnShow", function() refreshSettings() end)
end

refreshSettings = function()
    local S = settings
    if not S or not S:IsShown() then return end
    S.showEff:SetChecked(db.showEff)
    setSlider(S.pace, db.paceHours * 2)
    S.pace.label:SetText(string.format("Target pace (score 50): 1 level per |cffffd100%s|r", shortDur(db.paceHours * 7200)))
    S.paceNote:SetText(string.format("score 100 = 1 level per %s,  25 = per %s",
        shortDur(db.paceHours * 3600), shortDur(db.paceHours * 14400)))
    for k, w in ipairs(EFF_WINDOWS) do S.effChecks[k]:SetChecked(db.effWindow == w[1]) end
    for i = 1, #SPANS do S.spanChecks[i]:SetChecked(spanOn(i)) end
    setSlider(S.smooth, db.smooth)
    S.smooth.label:SetText(string.format("Trend line averages |cffffffff%d|r bars", db.smooth))
    S.clip:SetChecked(db.clip)
    S.lock:SetChecked(db.locked and true or false)
    setSlider(S.recent, db.recentLevels)
    S.recent.label:SetText(string.format("Levels in history panel: |cffffffff%d|r", db.recentLevels))
    S.timer:SetChecked(db.showTimer)
    if not S.goal:HasFocus() then S.goal:SetText(chr.goal and tostring(chr.goal) or "") end
end

toggleSettings = function()
    if not settings then createSettings() end
    if settings:IsShown() then settings:Hide() else settings:Show() end
end

local function createFrame()
    frame = CreateFrame("Frame", "MyXPTrackerFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame:SetSize(300, 24)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    backdrop(frame, 0.6)
    text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", 12, 0)

    -- level timer: gametime at this level, small and grey; hover it for level history
    timerZone = CreateFrame("Frame", "MyXPTrackerTimer", frame)
    timerZone:SetPoint("TOPRIGHT", 0, 0)
    timerZone:SetPoint("BOTTOMRIGHT", 0, 0)
    timerZone:SetWidth(60)
    timerZone:EnableMouse(true)
    timer = timerZone:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    timer:SetTextColor(0.55, 0.55, 0.55)
    timer:SetPoint("RIGHT", -10, 0)
    local div = timerZone:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(1, 1, 1, 0.15)
    div:SetSize(1, 12)
    div:SetPoint("LEFT", 0, 0)
    timerZone:RegisterForDrag("LeftButton")
    timerZone:SetScript("OnDragStart", function() if not db.locked then frame:StartMoving() end end)
    timerZone:SetScript("OnDragStop", function() frame:GetScript("OnDragStop")(frame) end)
    timerZone:SetScript("OnEnter", showHistory)
    timerZone:SetScript("OnLeave", scheduleHide)

    -- efficiency bar: thin strip under the top display
    eff = CreateFrame("Frame", "MyXPTrackerEff", frame)
    eff:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 3, -1)
    eff:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", -3, -1)
    eff:SetHeight(EFF_HEIGHT)
    eff.bg = eff:CreateTexture(nil, "BACKGROUND")
    eff.bg:SetAllPoints()
    eff.bg:SetColorTexture(0, 0, 0, 0.6)
    eff.fill = eff:CreateTexture(nil, "ARTWORK")
    eff.fill:SetPoint("TOPLEFT")
    eff.fill:SetPoint("BOTTOMLEFT")
    eff.ticks = {}
    for k, v in ipairs(EFF_TICKS) do
        local t = eff:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(1, 1, 1, 0.55)
        t:SetSize(1, EFF_HEIGHT)
        eff.ticks[k] = { tex = t, v = v }
    end
    eff:EnableMouse(true)
    eff:RegisterForDrag("LeftButton")
    eff:SetScript("OnDragStart", function() if not db.locked then frame:StartMoving() end end)
    eff:SetScript("OnDragStop", function() frame:GetScript("OnDragStop")(frame) end)

    frame:SetScript("OnDragStart", function(self) if not db.locked then self:StartMoving() end end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, rel, x, y = self:GetPoint()
        db.pos = { point = point, rel = rel, x = x, y = y }
    end)

    local ok, err = pcall(createPanel)
    if ok then
        panel:SetPoint("TOP", eff, "BOTTOM", 0, 0)
        panel:EnableMouse(true)
        panel:SetScript("OnEnter", showPanel)
        panel:SetScript("OnLeave", scheduleHide)
        for _, b in ipairs({ panel.minus, panel.plus, panel.mode, panel.gear }) do
            b:HookScript("OnEnter", showPanel)
            b:HookScript("OnLeave", scheduleHide)
        end
    else
        panel = nil
        print("|cffff5555MyXPTracker: hover panel failed to build:|r " .. tostring(err))
    end
    local okH, errH = pcall(createHistory)
    if okH then
        hist:SetPoint("TOPRIGHT", eff, "BOTTOMRIGHT", 3, 0)
    else
        hist = nil
        print("|cffff5555MyXPTracker: history panel failed to build:|r " .. tostring(errH))
    end
    frame:SetScript("OnEnter", showPanel)
    frame:SetScript("OnLeave", scheduleHide)
    eff:SetScript("OnEnter", showPanel)
    eff:SetScript("OnLeave", scheduleHide)

    local acc, hoverAcc = 0, 0
    frame:SetScript("OnUpdate", function(_, dt)
        chr.online = (chr.online or 0) + dt       -- gametime clock
        acc = acc + dt
        hoverAcc = hoverAcc + dt
        if hoverAcc >= 0.1 then
            hoverAcc = 0
            if hideAt and GetTime() >= hideAt then
                hideAt = nil
                local onTimer = over(timerZone)
                if panel and panel:IsShown() and not ((over(frame) and not onTimer) or over(eff) or over(panel)) then
                    panel:Hide()
                end
                if hist and hist:IsShown() and not (onTimer or over(hist)) then hist:Hide() end
            end
        end
        if acc >= 1 then
            acc = 0
            chr.lastSeen = time()
            if lastEntry and not lastEntry.src and GetTime() - lastEntryAt > HINT_WINDOW then
                lastEntry.src = "other"
            end
            local ok2, err2 = pcall(refresh)
            if not ok2 and not frame.errShown then
                frame.errShown = true
                print("|cffff5555MyXPTracker error:|r " .. tostring(err2))
            end
        end
    end)
    applyPosition()
    refresh()
end

---------------------------------------------------------------------------
-- events & slash commands
---------------------------------------------------------------------------
local function saveLog()
    if not chr or not log then return end
    if lastEntry and not lastEntry.src then lastEntry.src = "other" end
    local ok = pcall(function()
        rollupOld(time())
        local logs = encodeLog(log, chr.zones)
        local rolls = encodeRollups(rollups, chr.zones)
        chr.logs, chr.rollups, chr.fmt = logs, rolls, 2
    end)
    if not ok then                                   -- never lose data: fall back to plain tables
        chr.log, chr.rollupT, chr.logs, chr.rollups = log, rollups, nil, nil
    end
end

-- small API (used by the test harness; handy for other addons too)
MyXPTracker = {
    GetLog = function() return log end,
    GetRollups = function() return rollups end,
    Save = function() saveLog() end,
}

local KILL_MARK = COMBATLOG_XPGAIN_FIRSTPERSON and COMBATLOG_XPGAIN_FIRSTPERSON:match("%%s(.-)%%d")
if not KILL_MARK or KILL_MARK == "" then KILL_MARK = " dies, you gain " end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_XP_UPDATE")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
pcall(ev.RegisterEvent, ev, "QUEST_TURNED_IN")
ev:RegisterEvent("TIME_PLAYED_MSG")
ev:RegisterEvent("PLAYER_DEAD")
ev:RegisterEvent("PLAYER_LOGOUT")
ev:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        MyXPTrackerDB = MyXPTrackerDB or {}
        db = MyXPTrackerDB
        db.chars = db.chars or {}
        db.xpNeed = db.xpNeed or {}
        db.pos = db.pos or { point = "TOP", rel = "TOP", x = 0, y = -12 }
        db.spanIdx = db.spanIdx or 4
        db.smooth = db.smooth or 5
        if not db.paceV2 then db.paceHours = 3; db.paceV2 = true end   -- default moved from 2h to 3h
        db.paceHours = db.paceHours or 3
        if db.clip == nil then db.clip = true end
        db.effWindow = db.effWindow or 3600
        if db.showEff == nil then db.showEff = true end
        db.spansOn = db.spansOn or {}
        db.recentLevels = math.max(1, db.recentLevels or 4)
        if db.showTimer == nil then db.showTimer = true end
        if db.gameTime == nil then db.gameTime = false end
    elseif event == "PLAYER_LOGIN" then
        charKey = UnitName("player") .. "-" .. GetRealmName()
        db.chars[charKey] = db.chars[charKey] or { class = select(2, UnitClass("player")) }
        chr = db.chars[charKey]
        chr.class = select(2, UnitClass("player"))
        chr.online = chr.online or 0
        chr.zones = chr.zones or {}
        if chr.log then                              -- pre-0.11 format: one table per entry
            log = chr.log
            backfillGameTime()
        else
            log = decodeLog(chr.logs or {}, chr.zones, {})
        end
        rollups = chr.rollupT or decodeRollups(chr.rollups or {}, chr.zones)
        chr.log, chr.logs, chr.rollups, chr.rollupT = nil, nil, nil, nil   -- re-written on logout
        rollupOld(time())
        local nowT = time()
        if chr.lastSeen and nowT - chr.lastSeen <= SESSION_GAP then
            if not chr.sessionStart then
                -- first run of this version mid-session: walk back through the log to the last long gap
                local start, prevT = nowT, chr.lastSeen
                for i = #log, 1, -1 do
                    local t = log[i].t
                    if prevT - t > SESSION_GAP then break end
                    start, prevT = t, t
                end
                chr.sessionStart = start
            end
        else
            chr.sessionStart = nowT
        end
        sessionStart = chr.sessionStart
        chr.levels = chr.levels or {}
        lastXP, lastMax, lastLevel = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
        if lastMax > 0 then db.xpNeed[lastLevel] = lastMax end
        if not chr.levelStart or chr.levelStart.lvl ~= lastLevel then
            chr.levelStart = { lvl = lastLevel, t = time(), o = math.floor(chr.online), partial = lastXP > 0 or nil,
                sessions = 1, deaths = 0 }
        else
            chr.levelStart.sessions = (chr.levelStart.sessions or 1) + 1
        end
        if C_Timer then C_Timer.After(3, requestPlayed) else requestPlayed() end
        local ok, err = pcall(createFrame)
        if not ok then print("|cffff5555MyXPTracker error:|r " .. tostring(err)) end
    elseif not log then
        return
    elseif event == "PLAYER_XP_UPDATE" then
        onXPUpdate()
        if frame then refresh() end
    elseif event == "PLAYER_LOGOUT" then
        saveLog()
    elseif event == "PLAYER_LEVEL_UP" then
        onLevelUp(arg1)
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        if arg1 and arg1:find(KILL_MARK, 1, true) then hintSource("kill") end
    elseif event == "TIME_PLAYED_MSG" then
        onTimePlayed(arg1, arg2)
    elseif event == "PLAYER_DEAD" then
        if chr.levelStart then chr.levelStart.deaths = (chr.levelStart.deaths or 0) + 1 end
    elseif event == "QUEST_TURNED_IN" then
        if not arg2 or arg2 > 0 then hintSource("quest") end
    end
end)

local function printHistory()
    if #chr.levels == 0 then print("MyXPTracker: no completed levels recorded yet") return end
    print("|cff88ccffMyXPTracker level history|r (" .. charKey .. ")  |cffaaaaaa* = incomplete|r")
    for i = math.max(1, #chr.levels - 14), #chr.levels do
        local l = chr.levels[i]
        print(string.format("  %d: %s%s played, %s%s real, %d sess  |cffaaaaaa%d kills, %d quests, %d deaths, %s, %s|r",
            l.lvl, fmtTime(l.played), l.playedExact and "" or "*", fmtTime(l.real), l.partial and "*" or "",
            l.sessions or 1, l.kills or 0, l.quests or 0, l.deaths or 0, l.zone or "", date("%b %d", l.ding)))
    end
end

SLASH_MYXP1 = "/mxp"
SlashCmdList["MYXP"] = function(msg)
    msg = (msg or ""):lower()
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    if cmd == "lock" then
        db.locked = true; print("MyXPTracker: locked")
    elseif cmd == "unlock" then
        db.locked = false; print("MyXPTracker: unlocked, drag to move")
    elseif cmd == "resetpos" then
        db.pos = { point = "TOP", rel = "TOP", x = 0, y = -12 }; applyPosition()
    elseif cmd == "panel" then
        if panel then showPanel() else print("MyXPTracker: panel not built") end
    elseif cmd == "goal" then
        setGoal(tonumber(rest))
    elseif cmd == "config" or cmd == "settings" or cmd == "options" then
        toggleSettings()
    elseif cmd == "pace" then
        local n = tonumber(rest)
        if n and n > 0 then
            db.paceHours = n
            print(string.format("MyXPTracker: efficiency 100 = 1 level per %s, 50 = 1 level per %s",
                shortDur(n * 3600), shortDur(n * 7200)))
            refresh()
        else
            print("MyXPTracker: /mxp pace <hours per level for 100>  (currently " .. db.paceHours .. ")")
        end
    elseif cmd == "clip" then
        db.clip = not db.clip
        print("MyXPTracker: graph clipping of quest-sized spikes " .. (db.clip and "on" or "off"))
        if panel and panel:IsShown() then updatePanel() end
    elseif cmd == "smooth" then
        local n = tonumber(rest)
        if n and n >= 1 and n <= GRAPH_BARS then
            db.smooth = math.floor(n)
            print("MyXPTracker: trend line averages " .. db.smooth .. " bars")
            if panel and panel:IsShown() then updatePanel() end
        else
            print("MyXPTracker: /mxp smooth <1-" .. GRAPH_BARS .. ">  (currently " .. db.smooth .. ")")
        end
    elseif cmd == "history" then
        printHistory()
    elseif cmd == "export" then
        if rest == "log" then exportLog() else exportLevels() end
    elseif cmd == "log" then
        print(string.format("MyXPTracker: %d log entries for %s (written to disk on /reload or logout)", #log, charKey))
    else
        print("MyXPTracker: /mxp config | goal <lvl> | pace <hrs> | smooth <bars> | clip | history | export | export log | lock | unlock | resetpos | panel | log")
    end
    refreshSettings()
end
