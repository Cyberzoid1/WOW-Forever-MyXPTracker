"""MyXPTracker -> SQLite importer (part 2).

Reads the addon's SavedVariables file(s) and merges them into a SQLite database.
Safe to run any number of times: every row has a natural key, so re-importing the
same file adds nothing, and a newer file only adds what is new (or fills in a kill/
quest tag that was still pending last time). Then it rewrites the level report.

Run it after you log out (WoW only writes SavedVariables on logout or /reload):

    py tools\\import_sqlite.py
    py tools\\import_sqlite.py --sv "D:\\...\\SavedVariables\\MyXPTracker.lua" --db data\\myxptracker.db

No third-party packages needed (Python 3.9+).
"""
import argparse
import csv
import datetime as dt
import glob
import os
import re
import sqlite3
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# where to look for the Forever client when --wow isn't given (first match wins)
WOW_CANDIDATES = [
    os.environ.get("WOW_FOREVER_DIR", ""),
    r"C:\Program Files (x86)\World of Warcraft\_forever_",
    r"C:\Program Files\World of Warcraft\_forever_",
    r"D:\World of Warcraft\_forever_",
    r"D:\DBattleNet\World of Warcraft\_forever_",
    os.path.expanduser("~/Applications/World of Warcraft/_forever_"),
    "/Applications/World of Warcraft/_forever_",
]
DEFAULT_WOW = next((p for p in WOW_CANDIDATES if p and os.path.isdir(p)), WOW_CANDIDATES[1])
DEFAULT_DB = os.path.join(ROOT, "data", "myxptracker.db")
DEFAULT_REPORTS = os.path.join(ROOT, "reports")
SRC_CODES = {"k": "kill", "q": "quest", "o": "other"}


# --------------------------------------------------------------------------- Lua parser
class LuaParseError(Exception):
    pass


class LuaParser:
    """Just enough Lua to read SavedVariables: name = value, tables, strings, numbers, booleans."""

    NUM = re.compile(r"-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?|-?inf|nan")
    IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
    ESC = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v",
           "\\": "\\", '"': '"', "'": "'", "\n": "\n"}

    def __init__(self, text):
        self.s, self.i = text, 0

    def ws(self):
        s = self.s
        while self.i < len(s):
            c = s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif s.startswith("--", self.i):
                if s.startswith("--[[", self.i):
                    end = s.find("]]", self.i)
                    self.i = len(s) if end < 0 else end + 2
                else:
                    end = s.find("\n", self.i)
                    self.i = len(s) if end < 0 else end + 1
            else:
                break

    def file(self):
        out = {}
        while True:
            self.ws()
            if self.i >= len(self.s):
                return out
            m = self.IDENT.match(self.s, self.i)
            if not m:
                raise LuaParseError(f"expected a variable name at {self.i}")
            self.i = m.end()
            self.ws()
            self.expect("=")
            out[m.group()] = self.value()

    def expect(self, ch):
        if not self.s.startswith(ch, self.i):
            raise LuaParseError(f"expected {ch!r} at {self.i}: {self.s[self.i:self.i + 30]!r}")
        self.i += len(ch)

    def value(self):
        self.ws()
        c = self.s[self.i]
        if c == "{":
            return self.table()
        if c in "\"'":
            return self.string()
        for word, val in (("true", True), ("false", False), ("nil", None)):
            if self.s.startswith(word, self.i):
                self.i += len(word)
                return val
        m = self.NUM.match(self.s, self.i)
        if m:
            self.i = m.end()
            t = m.group()
            if re.fullmatch(r"-?\d+", t):
                return int(t)
            return float(t)
        raise LuaParseError(f"unexpected {c!r} at {self.i}")

    def string(self):
        q, s = self.s[self.i], self.s
        self.i += 1
        out = []
        while True:
            c = s[self.i]
            if c == q:
                self.i += 1
                return "".join(out)
            if c == "\\":
                n = s[self.i + 1]
                if n.isdigit():
                    m = re.match(r"\d{1,3}", s[self.i + 1:])
                    out.append(chr(int(m.group())))
                    self.i += 1 + len(m.group())
                    continue
                out.append(self.ESC.get(n, n))
                self.i += 2
                continue
            out.append(c)
            self.i += 1

    def table(self):
        self.expect("{")
        arr, d = [], {}
        while True:
            self.ws()
            if self.s.startswith("}", self.i):
                self.i += 1
                break
            if self.s.startswith("[", self.i):
                self.i += 1
                k = self.value()
                self.ws()
                self.expect("]")
                self.ws()
                self.expect("=")
                d[k] = self.value()
            else:
                m = self.IDENT.match(self.s, self.i)
                if m and self.s[m.end():].lstrip().startswith("=") and not self.s[m.end():].lstrip().startswith("=="):
                    self.i = m.end()
                    self.ws()
                    self.expect("=")
                    d[m.group()] = self.value()
                else:
                    arr.append(self.value())
            self.ws()
            if self.i < len(self.s) and self.s[self.i] in ",;":
                self.i += 1
        if not d:
            return arr
        for n, v in enumerate(arr, 1):
            d[n] = v
        # a table with only keys 1..n is a list
        if d and all(isinstance(k, int) for k in d) and sorted(d) == list(range(1, len(d) + 1)):
            return [d[k] for k in range(1, len(d) + 1)]
        return d


def as_list(v):
    if v is None:
        return []
    if isinstance(v, list):
        return v
    return [v[k] for k in sorted(k for k in v if isinstance(k, int))]


# --------------------------------------------------------------------------- read the addon data
def frac_of(xp, mx, f=None):
    if f is not None:
        return float(f)
    return xp / mx if mx else 0.0


def read_events(chr_):
    """Raw XP gains, from either save format."""
    zones = as_list(chr_.get("zones"))
    out = []
    for e in as_list(chr_.get("log")):                       # pre-0.11 format (or fallback)
        out.append(dict(t=e.get("t"), played=e.get("o"), xp=e.get("xp"), level=e.get("lvl"),
                        cur=e.get("cur"), max=e.get("max"), source=e.get("src"), zone=e.get("zone") or "",
                        frac=frac_of(e.get("xp", 0), e.get("max"), e.get("f")), est=1 if e.get("oa") else 0))
    for chunk in as_list(chr_.get("logs")):                  # 0.11+ compact lines
        for line in chunk.split("\n"):
            if not line:
                continue
            p = line.split(",")
            p += [""] * (10 - len(p))
            xp, mx = int(p[2]), int(p[5])
            zi = int(p[7] or 0)
            out.append(dict(t=int(p[0]), played=int(p[1]), xp=xp, level=int(p[3]), cur=int(p[4]), max=mx,
                            source=SRC_CODES.get(p[6]), zone=zones[zi - 1] if zi > 0 else "",
                            frac=frac_of(xp, mx, float(p[8]) if p[8] else None), est=1 if p[9] == "1" else 0))
    return out


def read_rollups(chr_):
    zones = as_list(chr_.get("zones"))
    out = []
    for r in as_list(chr_.get("rollupT")):
        out.append(dict(t=r["t"], len=r["len"], played=r.get("o"), xp=r["xp"], xp_kill=r["xpKill"],
                        xp_quest=r["xpQuest"], xp_other=r["xpOther"], kills=r["kills"], quests=r["quests"],
                        frac=r["frac"], gains=r["n"], level=r.get("lvl"), zone=r.get("zone") or ""))
    for chunk in as_list(chr_.get("rollups")):
        for line in chunk.split("\n"):
            if not line:
                continue
            p = line.split(",")
            zi = int(p[12] or 0)
            out.append(dict(t=int(p[0]), len=int(p[1]), played=int(p[2]), xp=int(p[3]), xp_kill=int(p[4]),
                            xp_quest=int(p[5]), xp_other=int(p[6]), kills=int(p[7]), quests=int(p[8]),
                            frac=float(p[9]), gains=int(p[10]), level=int(p[11]),
                            zone=zones[zi - 1] if zi > 0 else ""))
    return out


# --------------------------------------------------------------------------- database
SCHEMA = """
CREATE TABLE IF NOT EXISTS characters (
    id INTEGER PRIMARY KEY,
    name_realm TEXT UNIQUE NOT NULL,
    name TEXT, realm TEXT, class TEXT,
    current_level INTEGER,          -- level in progress at the last import
    level_started INTEGER,          -- epoch when that level began (realtime)
    level_played INTEGER,           -- gametime seconds spent at that level so far
    level_partial INTEGER,          -- 1 if tracking began part-way through it
    level_sessions INTEGER, level_deaths INTEGER,
    goal INTEGER, last_seen INTEGER, updated_at INTEGER
);
CREATE TABLE IF NOT EXISTS xp_events (           -- every individual XP gain
    char_id INTEGER NOT NULL REFERENCES characters(id),
    t INTEGER NOT NULL,             -- epoch seconds (realtime)
    played INTEGER,                 -- addon gametime clock for this character, seconds
    xp INTEGER NOT NULL,
    level INTEGER, xp_into_level INTEGER, xp_level_max INTEGER,
    level_frac REAL,                -- fraction of a level this gain was worth
    source TEXT,                    -- kill / quest / other / NULL (logged before tagging)
    zone TEXT,
    played_estimated INTEGER DEFAULT 0,
    import_id INTEGER,
    PRIMARY KEY (char_id, t, xp, xp_into_level, level)
);
CREATE TABLE IF NOT EXISTS xp_rollups (          -- 10-minute summaries of gains older than 7 days
    char_id INTEGER NOT NULL REFERENCES characters(id),
    t_start INTEGER NOT NULL, seconds INTEGER, played_start INTEGER,
    xp INTEGER, xp_kill INTEGER, xp_quest INTEGER, xp_other INTEGER,
    kills INTEGER, quests INTEGER, level_frac REAL, gains INTEGER, level INTEGER, zone TEXT,
    import_id INTEGER,
    PRIMARY KEY (char_id, t_start)
);
CREATE TABLE IF NOT EXISTS levels (              -- one row per completed level
    char_id INTEGER NOT NULL REFERENCES characters(id),
    level INTEGER NOT NULL,
    started INTEGER, dinged INTEGER,
    played_seconds INTEGER,         -- gametime at the level
    real_seconds INTEGER,           -- realtime from previous ding, incl. logged-out time
    played_exact INTEGER,           -- 1 = anchored to the server's /played
    partial INTEGER,                -- 1 = tracking began mid-level (realtime and counts incomplete)
    sessions INTEGER, deaths INTEGER, kills INTEGER, quests INTEGER,
    xp_kill INTEGER, xp_quest INTEGER, xp_other INTEGER,
    total_played INTEGER, zone TEXT,
    import_id INTEGER,
    PRIMARY KEY (char_id, level)
);
CREATE TABLE IF NOT EXISTS imports (
    id INTEGER PRIMARY KEY,
    at INTEGER, source_file TEXT, file_mtime INTEGER,
    events_new INTEGER, events_tagged INTEGER, rollups_new INTEGER, levels_new INTEGER
);
-- 10-minute buckets: raw events where we have them, rollups only where we don't
CREATE VIEW IF NOT EXISTS v_xp_10min AS
WITH raw AS (
    SELECT char_id, t - t % 600 AS t_start, SUM(xp) AS xp,
           SUM(CASE WHEN source = 'kill' THEN xp ELSE 0 END) AS xp_kill,
           SUM(CASE WHEN source = 'quest' THEN xp ELSE 0 END) AS xp_quest,
           SUM(CASE WHEN source IS NULL OR source = 'other' THEN xp ELSE 0 END) AS xp_other,
           SUM(source = 'kill') AS kills, SUM(source = 'quest') AS quests,
           SUM(level_frac) AS level_frac, COUNT(*) AS gains, MAX(level) AS level
    FROM xp_events GROUP BY char_id, t - t % 600
)
SELECT char_id, t_start, xp, xp_kill, xp_quest, xp_other, kills, quests, level_frac, gains, level, 'raw' AS origin FROM raw
UNION ALL
SELECT r.char_id, r.t_start, r.xp, r.xp_kill, r.xp_quest, r.xp_other, r.kills, r.quests, r.level_frac, r.gains, r.level, 'rollup'
FROM xp_rollups r
WHERE NOT EXISTS (SELECT 1 FROM raw WHERE raw.char_id = r.char_id AND raw.t_start = r.t_start);
"""


def count(con, table):
    return con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]


def import_file(con, path):
    text = open(path, encoding="utf-8", errors="replace").read()
    sv = LuaParser(text).file()
    db = sv.get("MyXPTrackerDB") or {}
    chars = db.get("chars") or {}
    cur = con.cursor()
    cur.execute("INSERT INTO imports (at, source_file, file_mtime) VALUES (?, ?, ?)",
                (int(time.time()), os.path.abspath(path), int(os.path.getmtime(path))))
    imp = cur.lastrowid
    before = {t: count(con, t) for t in ("xp_events", "xp_rollups", "levels")}
    untagged_before = con.execute("SELECT COUNT(*) FROM xp_events WHERE source IS NULL").fetchone()[0]
    summary = []
    for key, c in chars.items():
        name, _, realm = key.partition("-")
        ls = c.get("levelStart") or {}
        online = c.get("online") or 0
        cur.execute("""
            INSERT INTO characters (name_realm, name, realm, class, current_level, level_started, level_played,
                                    level_partial, level_sessions, level_deaths, goal, last_seen, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(name_realm) DO UPDATE SET
                class=excluded.class, current_level=excluded.current_level, level_started=excluded.level_started,
                level_played=excluded.level_played, level_partial=excluded.level_partial,
                level_sessions=excluded.level_sessions, level_deaths=excluded.level_deaths, goal=excluded.goal,
                last_seen=excluded.last_seen, updated_at=excluded.updated_at
            WHERE excluded.last_seen >= COALESCE(characters.last_seen, 0)""",
                    (key, name, realm, c.get("class"), ls.get("lvl"), ls.get("t"),
                     int(online - ls["o"]) if "o" in ls else None, 1 if ls.get("partial") and not ls.get("exact") else 0,
                     ls.get("sessions"), ls.get("deaths"), c.get("goal"), c.get("lastSeen"), int(time.time())))
        cid = cur.execute("SELECT id FROM characters WHERE name_realm = ?", (key,)).fetchone()[0]

        events = read_events(c)
        cur.executemany("""
            INSERT INTO xp_events (char_id, t, played, xp, level, xp_into_level, xp_level_max, level_frac,
                                   source, zone, played_estimated, import_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(char_id, t, xp, xp_into_level, level) DO UPDATE SET
                source = COALESCE(xp_events.source, excluded.source)""",
                        [(cid, e["t"], int(e["played"]) if e["played"] is not None else None, e["xp"], e["level"],
                          e["cur"], e["max"], e["frac"], e["source"], e["zone"], e["est"], imp) for e in events])
        rolls = read_rollups(c)
        cur.executemany("""
            INSERT OR IGNORE INTO xp_rollups (char_id, t_start, seconds, played_start, xp, xp_kill, xp_quest, xp_other,
                                              kills, quests, level_frac, gains, level, zone, import_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                        [(cid, r["t"], r["len"], r["played"], r["xp"], r["xp_kill"], r["xp_quest"], r["xp_other"],
                          r["kills"], r["quests"], r["frac"], r["gains"], r["level"], r["zone"], imp) for r in rolls])
        lv = as_list(c.get("levels"))
        cur.executemany("""
            INSERT INTO levels (char_id, level, started, dinged, played_seconds, real_seconds, played_exact, partial,
                                sessions, deaths, kills, quests, xp_kill, xp_quest, xp_other, total_played, zone, import_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(char_id, level) DO NOTHING""",
                        [(cid, l["lvl"], l.get("start"), l.get("ding"), l.get("played"), l.get("real"),
                          1 if l.get("playedExact") else 0, 1 if l.get("partial") else 0, l.get("sessions"),
                          l.get("deaths"), l.get("kills"), l.get("quests"), l.get("xpKill"), l.get("xpQuest"),
                          l.get("xpOther"), l.get("totalPlayed"), l.get("zone"), imp) for l in lv])
        summary.append(f"{key}: {len(events)} raw gains, {len(rolls)} rollups, {len(lv)} levels in file")

    new = {t: count(con, t) - before[t] for t in before}
    new_untagged = con.execute("SELECT COUNT(*) FROM xp_events WHERE import_id = ? AND source IS NULL",
                               (imp,)).fetchone()[0]
    untagged_after = con.execute("SELECT COUNT(*) FROM xp_events WHERE source IS NULL").fetchone()[0]
    tagged = untagged_before + new_untagged - untagged_after   # older rows whose tag arrived in this file
    cur.execute("UPDATE imports SET events_new=?, events_tagged=?, rollups_new=?, levels_new=? WHERE id=?",
                (new["xp_events"], max(0, tagged), new["xp_rollups"], new["levels"], imp))
    con.commit()
    return new, max(0, tagged), summary


# --------------------------------------------------------------------------- report
def hm(sec):
    if sec is None:
        return "--"
    sec = int(sec)
    h, m = sec // 3600, (sec % 3600) // 60
    if h >= 24:
        return f"{h // 24}d {h % 24}h {m:02d}m"
    return f"{h}h {m:02d}m" if h else f"{m}m"


def write_reports(con, outdir, tz):
    os.makedirs(outdir, exist_ok=True)

    def local(t, fmt="%Y-%m-%d %H:%M"):
        return dt.datetime.fromtimestamp(t, tz).strftime(fmt) if t else ""

    md = ["# MyXPTracker level report", "",
          f"_Generated {dt.datetime.now(tz).strftime('%Y-%m-%d %H:%M')} from `{os.path.basename(DEFAULT_DB)}`._", "",
          "**Played** = in-game time at that level (from `/played`). **Real** = clock time from the previous "
          "level-up, including time logged out. `*` = incomplete (tracking began part-way through the level).", ""]
    rows_csv = []
    for cid, key, klass, curlvl, lstart, lplayed, lpartial, lsess, ldeaths, goal in con.execute(
            "SELECT id, name_realm, class, current_level, level_started, level_played, level_partial, "
            "level_sessions, level_deaths, goal FROM characters ORDER BY name_realm"):
        md += [f"## {key}" + (f" ({klass.title()})" if klass else ""), ""]
        levels = con.execute("""SELECT level, started, dinged, played_seconds, real_seconds, played_exact, partial,
                                       sessions, deaths, kills, quests, xp_kill, xp_quest, xp_other, zone
                                FROM levels WHERE char_id=? ORDER BY level""", (cid,)).fetchall()
        md += ["| Level | Dinged | Played | Real | Sessions | Deaths | Kills | Quests | XP from kills / quests / other | XP/hr played | Main zone |",
               "|---:|---|---:|---:|---:|---:|---:|---:|---|---:|---|"]
        tot_played = tot_real = 0
        for (lvl, st, ding, played, real, exact, partial, sess, deaths, kills, quests, xk, xq, xo, zone) in levels:
            if kills is None and st and ding:      # level recorded before the addon kept per-level counts
                kills, quests, xk, xq, xo = con.execute("""
                    SELECT SUM(kills), SUM(quests), SUM(xp_kill), SUM(xp_quest), SUM(xp_other)
                    FROM v_xp_10min WHERE char_id = ? AND t_start >= ? - ? % 600 AND t_start < ?""",
                                                         (cid, st, st, ding)).fetchone()
            xpsum = (xk or 0) + (xq or 0) + (xo or 0)
            split = (f"{100 * (xk or 0) / xpsum:.0f}% / {100 * (xq or 0) / xpsum:.0f}% / {100 * (xo or 0) / xpsum:.0f}%"
                     if xpsum else "--")
            rate = f"{xpsum / played * 3600 / 1000:.1f}k" if played and xpsum and not partial else "--"
            md.append(f"| {lvl} | {local(ding)} | {hm(played)}{'' if exact else '*'} | {hm(real)}{'*' if partial else ''} | "
                      f"{sess or ''} | {deaths or 0} | {kills or 0} | {quests or 0} | {split} | {rate} | {zone or ''} |")
            tot_played += played or 0
            tot_real += real or 0
            rows_csv.append([key, lvl, local(st), local(ding), played, real, exact, partial, sess, deaths, kills,
                             quests, xk, xq, xo, zone])
        if curlvl:
            k = q = xk = xq = xo = 0
            if lstart:
                k, q, xk, xq, xo = [v or 0 for v in con.execute("""
                    SELECT SUM(kills), SUM(quests), SUM(xp_kill), SUM(xp_quest), SUM(xp_other)
                    FROM v_xp_10min WHERE char_id = ? AND t_start >= ? - ? % 600""", (cid, lstart, lstart)).fetchone()]
            xpsum = xk + xq + xo
            split = f"{100 * xk / xpsum:.0f}% / {100 * xq / xpsum:.0f}% / {100 * xo / xpsum:.0f}%" if xpsum else "--"
            rate = f"{xpsum / lplayed * 3600 / 1000:.1f}k" if lplayed and xpsum and not lpartial else "--"
            md.append(f"| **{curlvl}** (in progress) | started {local(lstart)} | {hm(lplayed)}{'*' if lpartial else ''} | "
                      f"{hm(time.time() - lstart) if lstart else '--'} | {lsess or ''} | {ldeaths or 0} | {k} | {q} | "
                      f"{split} | {rate} | |")
        md += ["", f"Completed levels recorded: **{len(levels)}**, total played **{hm(tot_played)}**, "
                   f"total real **{hm(tot_real)}**." + (f" Goal: level {goal}." if goal else ""), ""]

        days = con.execute("""
            SELECT date(t_start, 'unixepoch', ?) AS day, SUM(xp), SUM(level_frac), SUM(kills), SUM(quests),
                   COUNT(*) * 10, MAX(level)
            FROM v_xp_10min WHERE char_id = ? GROUP BY day ORDER BY day DESC LIMIT 14""",
                           (f"{int(dt.datetime.now(tz).utcoffset().total_seconds())} seconds", cid)).fetchall()
        if days:
            md += ["### Last 14 days", "",
                   "| Day | XP | Levels gained | Kills | Quests | Active time* | Level |",
                   "|---|---:|---:|---:|---:|---:|---:|"]
            for day, xp, fr, kills, quests, mins, lvl in days:
                md.append(f"| {day} | {xp:,} | {fr:.2f} | {kills or 0} | {quests or 0} | {hm((mins or 0) * 60)} | {lvl} |")
            md += ["", "_*Active time counts 10-minute blocks with any XP gain, so it is approximate._", ""]

    with open(os.path.join(outdir, "level_report.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(md) + "\n")
    with open(os.path.join(outdir, "level_report.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["character", "level", "started", "dinged", "played_seconds", "real_seconds", "played_exact",
                    "partial", "sessions", "deaths", "kills", "quests", "xp_kills", "xp_quests", "xp_other", "zone"])
        w.writerows(rows_csv)


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sv", nargs="*", help="SavedVariables MyXPTracker.lua file(s); default: search under --wow")
    ap.add_argument("--wow", default=DEFAULT_WOW,
                    help="WoW Forever folder that contains WTF (or set WOW_FOREVER_DIR); default: %(default)s")
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--reports", default=DEFAULT_REPORTS)
    ap.add_argument("--tz", help="IANA time zone for the report (default: this computer's)")
    args = ap.parse_args()

    files = args.sv or sorted(glob.glob(os.path.join(args.wow, "WTF", "Account", "*", "SavedVariables", "MyXPTracker.lua")))
    if not files:
        sys.exit(f"No MyXPTracker.lua found under {args.wow}\\WTF\\Account\\*\\SavedVariables (use --sv).")
    tz = None
    if args.tz:
        from zoneinfo import ZoneInfo
        tz = ZoneInfo(args.tz)
    else:
        tz = dt.datetime.now().astimezone().tzinfo

    os.makedirs(os.path.dirname(os.path.abspath(args.db)), exist_ok=True)
    con = sqlite3.connect(args.db)
    con.executescript(SCHEMA)
    for path in files:
        new, tagged, summary = import_file(con, path)
        print(f"Imported {path}")
        for line in summary:
            print("  " + line)
        print(f"  new: {new['xp_events']} XP gains, {new['xp_rollups']} rollups, {new['levels']} levels"
              + (f"; {tagged} earlier gains got their kill/quest tag" if tagged else ""))
    write_reports(con, args.reports, tz)
    totals = {t: count(con, t) for t in ("characters", "xp_events", "xp_rollups", "levels")}
    print(f"Database {args.db}: {totals['characters']} characters, {totals['xp_events']} XP gains, "
          f"{totals['xp_rollups']} rollups, {totals['levels']} levels")
    print(f"Report: {os.path.join(args.reports, 'level_report.md')} (+ level_report.csv)")
    con.close()


if __name__ == "__main__":
    main()
