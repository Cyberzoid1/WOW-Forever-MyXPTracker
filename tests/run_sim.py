"""Drive MyXPTracker in a mocked WoW API.

    pip install lupa
    python tests/run_sim.py                 # synthetic session from scratch
    python tests/run_sim.py --fixture tests/fixtures/savedvars_2026-11-18_stv_quests.lua
"""
import argparse, pathlib, sys, lupa

ROOT = pathlib.Path(__file__).resolve().parent.parent
ap = argparse.ArgumentParser()
ap.add_argument("--fixture", help="a SavedVariables MyXPTracker.lua to start from")
args = ap.parse_args()

lua = lupa.LuaRuntime()
lua.execute(f'package.path = "{(ROOT / "tests").as_posix()}/?.lua;" .. package.path')
lua.execute(f'M = require("wowmock")')
if args.fixture:
    lua.execute(pathlib.Path(args.fixture).read_text(encoding="utf-8"))
lua.execute((ROOT / "tests" / "sim.lua").read_text())
lua.execute(f'RUN("{(ROOT / "MyXPTracker" / "MyXPTracker.lua").as_posix()}", {"true" if args.fixture else "false"})')

if args.fixture:
    print("---- largest gain in fixture ----")
    lua2 = lupa.LuaRuntime()
    lua2.execute(f'package.path = "{(ROOT / "tests").as_posix()}/?.lua;" .. package.path')
    lua2.execute('M = require("wowmock")')
    lua2.execute(pathlib.Path(args.fixture).read_text(encoding="utf-8"))
    lua2.execute((ROOT / "tests" / "sim.lua").read_text())
    lua2.execute(f'RUN_LARGEST_GAIN("{(ROOT / "MyXPTracker" / "MyXPTracker.lua").as_posix()}")')

if args.fixture:
    print("---- session across /reload ----")
    lua3 = lupa.LuaRuntime()
    lua3.execute(f'package.path = "{(ROOT / "tests").as_posix()}/?.lua;" .. package.path')
    lua3.execute('M = require("wowmock")')
    lua3.execute(pathlib.Path(args.fixture).read_text(encoding="utf-8"))
    lua3.execute((ROOT / "tests" / "sim.lua").read_text())
    lua3.execute(f'RUN_SESSION("{(ROOT / "MyXPTracker" / "MyXPTracker.lua").as_posix()}")')

if args.fixture:
    print("---- save format + rollups ----")
    lua4 = lupa.LuaRuntime()
    lua4.execute(f'package.path = "{(ROOT / "tests").as_posix()}/?.lua;" .. package.path')
    lua4.execute('M = require("wowmock")')
    lua4.execute(pathlib.Path(args.fixture).read_text(encoding="utf-8"))
    lua4.execute((ROOT / "tests" / "sim.lua").read_text())
    lua4.execute(f'RUN_STORAGE("{(ROOT / "MyXPTracker" / "MyXPTracker.lua").as_posix()}", {pathlib.Path(args.fixture).stat().st_size})')

total = lua.globals().FAILS
if args.fixture:
    total += lua2.globals().FAILS + lua3.globals().FAILS + lua4.globals().FAILS
print("FAILED CHECKS:", total)
sys.exit(1 if total else 0)
