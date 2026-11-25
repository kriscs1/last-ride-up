#!/usr/bin/env python3
"""Static checks for GDScript when the Godot editor isn't available.
Not a parser: it catches indentation, bracket, block-colon and some type-inference mistakes,
plus calls to static functions / classes that don't exist in the project."""
import re, sys, pathlib

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.')
files = sorted(root.rglob('*.gd'))
problems = []
classes, funcs = {}, {}
for f in files:
    src = f.read_text()
    m = re.search(r'^class_name (\w+)', src, re.M)
    cname = m.group(1) if m else None
    if cname: classes[cname] = f
    for fm in re.finditer(r'^(?:static )?func (\w+)\(', src, re.M):
        funcs.setdefault(cname, set()).add(fm.group(1))
    consts = set(re.findall(r'^const (\w+)', src, re.M)) | set(re.findall(r'^enum (\w+)', src, re.M)) | set(re.findall(r'^var (\w+)', src, re.M)) | set(re.findall(r'^signal (\w+)', src, re.M))
    funcs.setdefault(cname, set()).update(consts)

BLOCK = re.compile(r'^\s*(if|elif|else|for|while|match|func|static func|class)\b')
for f in files:
    lines = f.read_text().split('\n')
    depth = 0; in_str = None
    for i, raw in enumerate(lines, 1):
        line = raw.split('#')[0] if '"' not in raw and "'" not in raw else raw
        lead = re.match(r'^[ \t]*', raw).group(0)
        if ' ' in lead and raw.strip():
            problems.append(f'{f}:{i}: indentation uses spaces')
        code = re.sub(r'"(?:\\.|[^"\\])*"', '""', raw)
        code = re.sub(r"'(?:\\.|[^'\\])*'", "''", code)
        code = code.split('#')[0]
        opens = code.count('(') + code.count('[') + code.count('{')
        closes = code.count(')') + code.count(']') + code.count('}')
        prev_depth = depth
        depth += opens - closes
        if depth < 0:
            problems.append(f'{f}:{i}: unbalanced closing bracket'); depth = 0
        s = code.strip()
        if prev_depth == 0 and BLOCK.match(code) and not s.endswith(':') and ':' not in s and depth == 0:
            problems.append(f'{f}:{i}: block statement without colon: {s}')
        # := with a value whose type is Variant (subscript / untyped call) is a parse error in GDScript 2
        mm = re.match(r'^\s*var (\w+) := (.+)$', s)
        if mm:
            rhs = mm.group(2)
            if re.match(r'^[\w.]+\[[^\]]+\]$', rhs) or re.match(r'^\w+\[["\w]', rhs) and not rhs.startswith(('PackedVector2Array', 'Vector2', 'Color')):
                problems.append(f'{f}:{i}: ":=" from a subscript infers Variant (error): {s}')
        # Class.method references must exist
        for cm in re.finditer(r'\b(CF\w*)\.(\w+)', code):
            c, name = cm.group(1), cm.group(2)
            if c in classes and name not in funcs.get(c, set()) and name not in ('new', 'Tile'):
                problems.append(f'{f}:{i}: {c}.{name} is not defined')
            if c not in classes and c not in ('CF',):
                problems.append(f'{f}:{i}: unknown class {c}')
        for nm in re.finditer(r'\bNet\.(\w+)', code):
            netfuncs = funcs.get(None, set())
        if re.search(r'\bfunc\(.*\):.*;', code):
            problems.append(f'{f}:{i}: multi-statement one-line lambda')
    if depth != 0:
        problems.append(f'{f}: brackets unbalanced at end of file (depth {depth})')

# Net autoload method references
net_src = (root / 'scripts/net/net.gd').read_text()
net_names = set(re.findall(r'^func (\w+)', net_src, re.M)) | set(re.findall(r'^signal (\w+)', net_src, re.M)) | set(re.findall(r'^var (\w+)', net_src, re.M))
for f in files:
    for i, raw in enumerate(f.read_text().split('\n'), 1):
        for nm in re.finditer(r'\bNet\.(\w+)', raw):
            if nm.group(1) not in net_names:
                problems.append(f'{f}:{i}: Net.{nm.group(1)} is not defined')
print('\n'.join(problems) if problems else f'lint: {len(files)} files clean')
sys.exit(1 if problems else 0)
