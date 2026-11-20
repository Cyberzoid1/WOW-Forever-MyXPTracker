# Changelog

## v0.13.0 – first public release
- Top bar with 15m / 30m / 1h XP/hr, % of a level per hour on the 1h figure.
- Pace bar (score 50 = target pace, default 1 level / 6h; 100 = twice that), 1h average.
- Level timer on the bar; hover it for the level history panel (played, real, kills, quests, deaths).
- Stats panel: averages, session totals (persist across /reload), time and kills to level, goal ETA.
- Graph: 15m–2d zoom, realtime or gametime, bars by source (kills / quests / other), trend line,
  quest-sized spikes clipped.
- Level records use the server's /played, so time spent before installing still counts.
- Settings window (gear button or `/mxp config`).
- Compact save format; XP gains older than 7 days are merged into 10-minute summaries.
- `tools/import_sqlite.py`: import into SQLite and write a level report.
