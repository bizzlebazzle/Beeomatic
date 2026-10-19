"""Run with Python + Lupa against OpenOS-compatible Lua 5.2 and Lua 5.3."""
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tools'))
from lupa.lua52 import LuaRuntime
from lupa.lua53 import LuaRuntime as Lua53Runtime

os.chdir(ROOT)
sources = [p for p in ROOT.rglob('*.lua') if not {'.tools', 'research', 'data'} & set(p.relative_to(ROOT).parts)]
for version, runtime in [('5.2', LuaRuntime), ('5.3', Lua53Runtime)]:
    lua = runtime(unpack_returned_tuples=True)
    for source in sources:
        lua.execute('assert(load(...))', source.read_text(encoding='utf-8'))
    print(f'Lua {version} syntax: {len(sources)} files', flush=True)
    lua.execute((ROOT / 'tests/run.lua').read_text(encoding='utf-8'))
