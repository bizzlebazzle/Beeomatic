"""Run with Python + Lupa (uses the Lua 5.2 engine, not the default engine)."""
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tools'))
from lupa.lua52 import LuaRuntime

os.chdir(ROOT)
lua = LuaRuntime(unpack_returned_tuples=True)
sources = [p for p in ROOT.rglob('*.lua') if not {'.tools', 'research', 'data'} & set(p.relative_to(ROOT).parts)]
for source in sources:
    lua.execute('assert(load(...))', source.read_text(encoding='utf-8'))
print(f'Lua 5.2 syntax: {len(sources)} files', flush=True)
lua.execute((ROOT / 'tests/run.lua').read_text(encoding='utf-8'))
