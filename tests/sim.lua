-- Scenario run by run_sim.py. M = wowmock, MyXPTrackerDB may be preloaded from a fixture.
FAILS = 0
local function check(cond, msg)
    if not cond then FAILS = FAILS + 1 end
    print((cond and "PASS " or "FAIL ") .. msg)
end

local function graphState()
    local p, out = M.panel, {}
    out.top = p.yLabels[3].label._text
    out.clipped, out.maxRate = 0, 0
    for i = 1, #p.data do
        local d = p.data[i]
        if d.clipped then out.clipped = out.clipped + 1 end
        if d.rate and d.rate > out.maxRate then out.maxRate = d.rate end
    end
    return out
end

local function resetView()
    MyXPTrackerDB.gameTime, MyXPTrackerDB.spansOn, MyXPTrackerDB.clip = false, {}, true
end

function RUN(addon, fromFixture)
    M.load(addon)
    if MyXPTrackerDB then resetView() end
    if fromFixture then
        local key, c = next(MyXPTrackerDB.chars)
        M.name, M.realm = key:match("^([^-]+)%-(.+)$")
        local last = c.log[#c.log]
        M.T, M.lvl, M.xp, M.xpmax = (c.lastSeen or last.t) + 60, last.lvl, last.cur, last.max
        print(string.format("fixture: %s, %d entries, level %d", key, #c.log, M.lvl))
    else
        M.xp, M.xpmax, M.lvl = 100, 31700, 24
    end
    M.login()
    check(M.panel ~= nil, "hover panel built")

    -- 30 minutes of kills with a big quest turn-in in the middle
    for i = 1, 60 do
        M.tick(30); M.gain(200, "kill")
        if i == 30 then M.gt = M.gt + 0.2; M.gain(5000, "quest") end
    end
    M.tick(2)
    SlashCmdList.MYXP("panel")
    MyXPTrackerDB.spanIdx = 2                 -- 30m view
    M.tick(1)
    local g = graphState()
    print(string.format("  30m view: axis top %s, tallest bar %.0f xp/hr, clipped bars %d", g.top, g.maxRate, g.clipped))
    check(g.clipped >= 1, "quest spike is clipped instead of setting the scale")

    SlashCmdList.MYXP("clip"); M.tick(1)
    local g2 = graphState()
    print(string.format("  clip off: axis top %s, clipped bars %d", g2.top, g2.clipped))
    check(g2.clipped == 0, "clip off shows full scale")
    SlashCmdList.MYXP("clip")

    local c = MyXPTrackerDB.chars[M.name .. "-" .. M.realm]
    local n = { kill = 0, quest = 0, other = 0, none = 0 }
    local L = MyXPTracker.GetLog()
    for _, e in ipairs(L) do n[e.src or "none"] = n[e.src or "none"] + 1 end
    print(string.format("  log: %d entries (kill %d, quest %d, other %d, untagged %d)", #L, n.kill, n.quest, n.other, n.none))
    check(n.quest >= 1, "quest turn-in tagged as quest")

    for s = 1, 5 do MyXPTrackerDB.spanIdx = s; M.tick(1) end
    MyXPTrackerDB.gameTime = true
    for s = 1, 5 do MyXPTrackerDB.spanIdx = s; M.tick(1) end
    MyXPTrackerDB.gameTime = false

    -- level-history: /played calibration at login, a death, then play to the next level
    local ls = c.levelStart
    check(ls.exact == true, "/played anchored this level's start (exact played time)")
    check(M.playedShown == 0, "/played request was not printed in chat")
    local playedBefore = (c.online - ls.o)
    print(string.format("  level %d so far: %.0fs played (server said %d at login)", ls.lvl, playedBefore, M.playedLevel))
    local deathsBefore = ls.deaths or 0
    M.fire("PLAYER_DEAD")
    local startLevel = M.lvl
    while M.lvl == startLevel do M.tick(30); M.gain(250, "kill") end
    local rec = c.levels[#c.levels]
    check(rec and rec.lvl == startLevel, "level-up recorded")
    print(string.format("  record: lvl %d, played %ds (exact %s), real %ds, sessions %d, deaths %d, kills %d, quests %d, xp k/q/o %d/%d/%d, zone %s, total %s",
        rec.lvl, rec.played, tostring(rec.playedExact), rec.real, rec.sessions, rec.deaths, rec.kills, rec.quests,
        rec.xpKill, rec.xpQuest, rec.xpOther, rec.zone, tostring(rec.totalPlayed)))
    check(rec.played >= M.playedLevel, "played time includes time before the addon was tracking")
    check(rec.deaths == deathsBefore + 1 and rec.kills > 0, "deaths and kills counted for the level")
    check(c.levelStart.lvl == startLevel + 1 and c.levelStart.exact, "next level starts exact")
    -- level timer on the bar -> level history panel; rest of the bar -> stats panel
    local tz, H = M.frames.MyXPTrackerTimer, M.frames.MyXPTrackerHistory
    M.bar._OnEnter(M.bar); M.tick(1)
    check(M.panel._shown and not H._shown, "hovering the bar shows stats")
    tz._OnEnter(tz); M.tick(1)
    check(H._shown and not M.panel._shown, "hovering the level timer swaps to level history")
    print("  level history panel:")
    local rows = {}
    for k = 1, #H.cols do
        local i = 0
        for raw in H.cols[k]._text:gmatch("[^\n]+") do
            i = i + 1
            local line = raw:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            rows[i] = (rows[i] or "") .. string.format(k == 1 and "%-10s" or "%9s", line)
        end
    end
    for _, r in ipairs(rows) do print("   " .. r) end
    print("   " .. H.foot._text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("\n", "\n   "))
    local lvlCol = H.cols[1]._text
    check(lvlCol:find((startLevel + 1) .. " now", 1, true) and lvlCol:find(tostring(startLevel), 1, true),
        "history shows the current and the completed level")
    M.bar._OnEnter(M.bar); M.tick(1)
    check(M.panel._shown and not H._shown, "back on the bar swaps to stats")
    MyXPTrackerDB.showTimer = false; M.tick(1)
    check(not tz._shown, "level timer can be turned off")
    MyXPTrackerDB.showTimer = true; M.tick(1)

    -- settings window
    SlashCmdList.MYXP("config")
    local S = M.frames.MyXPTrackerSettings
    check(S and S._shown, "settings window opens with /mxp config")
    local function click(cb) cb:SetChecked(not cb:GetChecked()); cb._OnClick(cb) end
    S.pace._OnValueChanged(S.pace, 8)
    check(MyXPTrackerDB.paceHours == 4, "target slider 8h -> score 100 = 4h  [" .. S.pace.label._text .. " | " .. S.paceNote._text .. "]")
    click(S.effChecks[2])
    check(MyXPTrackerDB.effWindow == 1800 and S.effChecks[2]._checked and not S.effChecks[3]._checked, "efficiency window radio -> 30m")
    MyXPTrackerDB.spanIdx = 1
    click(S.spanChecks[2]); click(S.spanChecks[3])            -- turn off 30m and 1h
    M.panel.plus._OnClick(M.panel.plus)
    check(MyXPTrackerDB.spanIdx == 4, "+ skips disabled zoom levels (15m -> 4h)")
    click(S.spanChecks[4])                                     -- turn off the current one
    check(MyXPTrackerDB.spanIdx ~= 4 and MyXPTrackerDB.spansOn[MyXPTrackerDB.spanIdx] ~= false, "disabling current zoom moves to an enabled one")
    for i = 1, 6 do if S.spanChecks[i]._checked then click(S.spanChecks[i]) end end
    local on = 0
    for i = 1, 6 do if S.spanChecks[i]._checked then on = on + 1 end end
    check(on == 1, "can't disable every zoom level")
    for i = 1, 6 do if not S.spanChecks[i]._checked then click(S.spanChecks[i]) end end
    S.smooth._OnValueChanged(S.smooth, 7)
    check(MyXPTrackerDB.smooth == 7, "trend slider sets smoothing")
    click(S.showEff)
    check(MyXPTrackerDB.showEff == false, "efficiency bar can be hidden")
    click(S.showEff)
    S.goal:SetText(tostring(M.lvl + 2)); S.goal._OnEnterPressed(S.goal)
    check(c.goal == M.lvl + 2, "goal set from settings")
    S.goal:SetText(""); S.goal._OnEnterPressed(S.goal)
    check(c.goal == nil, "blank goal clears it")
    SlashCmdList.MYXP("goal " .. (M.lvl + 1))
    local lv = M.lvl
    while M.lvl == lv do M.tick(30); M.gain(400, "kill") end
    check(c.goal == nil, "goal clears itself when reached")
    SlashCmdList.MYXP("config")
    check(not S._shown, "/mxp config toggles it closed")

    for _, cmd in ipairs({ "goal 40", "history", "export", "export log", "pace 3", "smooth 8" }) do SlashCmdList.MYXP(cmd) end
    check(true, "all spans, both time modes and slash commands ran without errors")
end

-- Rewind to 10 minutes after the largest XP gain in the fixture and check the graph clips it.
function RUN_LARGEST_GAIN(addon)
    M.load(addon)
    resetView()
    local key, c = next(MyXPTrackerDB.chars)
    local big
    for _, e in ipairs(c.log) do if not big or e.xp > big.xp then big = e end end
    M.T = big.t + 600
    while c.log[#c.log].t > M.T do table.remove(c.log) end
    c.lastSeen = nil
    M.name, M.realm = key:match("^([^-]+)%-(.+)$")
    M.lvl, M.xp, M.xpmax = big.lvl, big.cur, big.max
    M.login()
    SlashCmdList.MYXP("panel")
    print(string.format("replaying %d xp gain at %s", big.xp, os.date("%Y-%m-%d %H:%M", big.t)))
    for s = 2, 5 do
        MyXPTrackerDB.spanIdx = s; M.tick(1)
        local p, clipped = M.panel, 0
        for i = 1, #p.data do if p.data[i].clipped then clipped = clipped + 1 end end
        print(string.format("  %s view: axis top %s, clipped bars %d", p.spanText._text, p.yLabels[3].label._text, clipped))
        check(clipped >= 1, p.spanText._text .. " view clips the spike")
    end
end

-- Session must survive /reload, and be inferred from the log the first time.
function RUN_SESSION(addon)
    local key, c = next(MyXPTrackerDB.chars)
    M.name, M.realm = key:match("^([^-]+)%-(.+)$")
    local last = c.log[#c.log]
    M.T, M.lvl, M.xp, M.xpmax = c.lastSeen + 5, last.lvl, last.cur, last.max      -- a /reload right after the save
    c.sessionStart = nil                                                       -- as saved by the previous version
    resetView()
    M.load(addon); M.login(); SlashCmdList.MYXP("panel"); M.tick(1)
    local first
    local L = MyXPTracker.GetLog()
    for i = #L, 1, -1 do
        if i > 1 and L[i].t - L[i - 1].t > 1800 then first = L[i]; break end
    end
    first = first or L[1]
    print("  inferred session start " .. os.date("!%m-%d %H:%M UTC", c.sessionStart) .. ", expected " .. os.date("!%m-%d %H:%M UTC", first.t))
    check(c.sessionStart == first.t, "session start inferred from the log")
    print("  " .. M.panel.labels._text:match("Session[^\n]*") .. "  =  " .. M.panel.values._text:match("[^\n]*kills, [^\n]*"))
    for i = 1, 10 do M.tick(30); M.gain(500, "kill") end
    local before = M.panel.values._text:match("[^\n]*kills, [^\n]*")
    -- /reload: new addon instance, same saved table, seconds later
    M.tick(3)
    M.reload(addon); SlashCmdList.MYXP("panel"); M.tick(1)
    local after = M.panel.values._text:match("[^\n]*kills, [^\n]*")
    print("  before reload: " .. before .. "\n  after reload:  " .. after)
    check(before == after, "session totals survive /reload")
    -- log out for 2 hours (no OnUpdate while logged out): new session
    M.fire("PLAYER_LOGOUT")
    M.T = M.T + 7200; M.gt = M.gt + 7200
    M.reload(addon); SlashCmdList.MYXP("panel"); M.tick(1)
    c = MyXPTrackerDB.chars[key]                       -- reload re-created the saved table
    check(c.sessionStart >= M.T - 2, "a long logout starts a new session")
end

-- Save format: logout -> WoW-style SavedVariables text -> reload, plus 7-day rollups.
function RUN_STORAGE(addon, fixtureBytes)
    local key, c = next(MyXPTrackerDB.chars)
    M.name, M.realm = key:match("^([^-]+)%-(.+)$")
    local last = c.log[#c.log]
    M.T, M.lvl, M.xp, M.xpmax = c.lastSeen + 5, last.lvl, last.cur, last.max
    M.load(addon); M.login(); M.tick(1)
    local before = {}
    for i, e in ipairs(MyXPTracker.GetLog()) do before[i] = e end
    local xpBefore = 0
    for _, e in ipairs(before) do xpBefore = xpBefore + e.xp end

    local text = M.reload(addon)
    print(string.format("  saved file: %.1f KB (was %.1f KB in the old format, %.1fx smaller)",
        #text / 1024, fixtureBytes / 1024, fixtureBytes / #text))
    check(#text < fixtureBytes / 2.5, "compact save format is much smaller")
    local after = MyXPTracker.GetLog()
    local same = #after == #before
    for i = 1, math.min(#after, #before) do
        local a, b = after[i], before[i]
        if a.t ~= b.t or a.xp ~= b.xp or a.cur ~= b.cur or a.max ~= b.max or a.lvl ~= b.lvl or a.o ~= math.floor(b.o)
            or (a.src or "") ~= (b.src or "") or a.zone ~= b.zone
            or math.abs((a.f or a.xp / a.max) - (b.f or b.xp / b.max)) > 1e-5 then
            same = false; print("  mismatch at " .. i); break
        end
    end
    check(same, string.format("all %d entries survive save -> reload unchanged", #before))
    check(#MyXPTracker.GetRollups() == 0, "nothing rolled up while everything is under 7 days old")

    -- 8 days later: everything older than 7 days becomes 10-minute rollups
    M.T = M.T + 8 * 86400; M.gt = M.gt + 8 * 86400
    M.reload(addon)
    local R = MyXPTracker.GetRollups()
    local rx, rn, rk, rq = 0, 0, 0, 0
    for _, r in ipairs(R) do rx, rn, rk, rq = rx + r.xp, rn + r.n, rk + r.kills, rq + r.quests end
    print(string.format("  after 8 days: %d raw entries, %d rollups holding %d gains / %d xp (%d kills, %d quests)",
        #MyXPTracker.GetLog(), #R, rn, rx, rk, rq))
    check(#MyXPTracker.GetLog() == 0 and rn == #before and rx == xpBefore, "old gains rolled up with nothing lost")
    local text2 = M.reload(addon)
    check(#MyXPTracker.GetRollups() == #R, "rollups survive save -> reload")
    print(string.format("  saved file with rollups only: %.1f KB", #text2 / 1024))
end
