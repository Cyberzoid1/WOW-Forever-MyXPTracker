# MyXPTracker

A leveling tracker for **World of Warcraft: Forever**. A small bar at the top of the screen shows your
XP per hour over the last 15 minutes, 30 minutes and hour (like a Linux load average), a pace bar that
tells you at a glance how fast you're leveling, and how long you've played at your current level.
Hover it for the details.

## Features
- **Top bar:** XP/hr over 15m / 30m / 1h, plus % of a level per hour.
- **Pace bar:** a thin color bar under it. Score 50 = your target pace (default 1 level per 6 hours of play),
  100 = twice that. Red → orange → yellow → green.
- **Level timer:** gray played-time at your current level on the right of the bar.
- **Stats panel** (hover the bar): 15m / 30m / 1h / 4h averages, session totals (XP, levels gained,
  kills, quests), time to level, kills to level, goal ETA, and a zoomable graph (15m to 2 days, realtime or
  gametime) with bars coloured by source (kills / quests / other) and a trend line.
- **Level history** (hover the level timer): your last levels with played time, real time, kills,
  quests and deaths.
- **Settings** (gear button or `/mxp config`): pace target, averaging window, which zoom levels to use,
  trend smoothing, quest-spike clipping, goal level and more.
- Lightweight: work happens once per second; old data is compacted automatically.

## Install
**WowUp:** *Get Addons* → *Install from URL* → paste
`https://github.com/Cyberzoid1/WOW-Forever-MyXPTracker` (make sure your WoW Forever client is selected).

**Manually:** download `MyXPTracker-<version>-forever.zip` from
[Releases](https://github.com/Cyberzoid1/WOW-Forever-MyXPTracker/releases) and extract it into
`World of Warcraft\_forever_\Interface\AddOns\` so you end up with `AddOns\MyXPTracker\MyXPTracker.toc`.

## Commands
| Command | |
|---|---|
| `/mxp config` | settings window |
| `/mxp goal <level>` | ETA to a target level (`/mxp goal` clears it) |
| `/mxp history` | print time per level in chat |
| `/mxp export` / `/mxp export log` | copyable CSV of level history / last 5000 XP gains |
| `/mxp pace <hours>` | score 100 = 1 level per `<hours>` |
| `/mxp smooth <bars>` | graph trend-line smoothing |
| `/mxp clip` | toggle cutting off quest-sized spikes in the graph |
| `/mxp lock` / `unlock` / `resetpos` | position |

## Your data outside the game (optional)
`tools/import_sqlite.py` copies everything the addon records into a SQLite database and writes a level
report (`reports/level_report.md` + `.csv`). Log out (or `/reload`) first, since WoW only saves addon data then.

    py tools\import_sqlite.py                 # or double-click import.bat
    py tools\import_sqlite.py --wow "D:\Games\World of Warcraft\_forever_"

Needs Python 3.9+ and nothing else. Safe to re-run: only new data is added. Run it at least weekly if you
want every individual XP gain kept, because the addon merges gains older than 7 days into 10-minute summaries.

<details>
<summary>Saved data format</summary>

`WTF/Account/<ACCOUNT>/SavedVariables/MyXPTracker.lua`, per character (`MyXPTrackerDB.chars["Name-Realm"]`):

- `logs[]` – every XP gain from the last 7 days, as text lines (400 per string):
  `t,o,xp,lvl,cur,max,src,zone,f,oa` – epoch, gametime s, xp, level, xp into level, level max,
  `k`/`q`/`o`/blank (kill/quest/other/untagged), index into `zones[]`, level fraction (only if not xp/max),
  `1` if gametime was estimated
- `rollups[]` – older gains merged into 10-minute lines:
  `t,len,o,xp,xpKill,xpQuest,xpOther,kills,quests,frac,n,lvl,zone`
- `zones[]` – zone names referenced by index
- `levels[]` – one per ding: `lvl`, `start`, `ding`, `played`, `real`, `playedExact`, `partial`,
  `sessions`, `deaths`, `kills`, `quests`, `xpKill`, `xpQuest`, `xpOther`, `zone`, `totalPlayed`
- `levelStart` – the level in progress; `sessionStart`, `online`, `lastSeen`, `goal`

Database tables: `characters`, `xp_events`, `xp_rollups`, `levels`, `imports`, and the view `v_xp_10min`.
</details>

## Development
- Addon source: `MyXPTracker/`. Copy (or symlink) it into your AddOns folder to test.
- Tests run the addon against a mocked WoW API, including two real (anonymised) SavedVariables files:

      pip install lupa
      python tests/run_sim.py
      python tests/run_sim.py --fixture tests/fixtures/savedvars_2026-11-19_lvl37_session.lua

- **Releasing:** bump `## Version` in `MyXPTracker/MyXPTracker.toc`, add a line to `CHANGELOG.md`,
  then push a tag: `git tag v0.14.0 && git push origin v0.14.0`. GitHub Actions runs the tests, builds
  `MyXPTracker-v0.14.0-forever.zip` and publishes the release that WowUp installs from.

## License
MIT
