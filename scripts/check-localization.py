#!/usr/bin/env python3
"""Validate Chinese resources and optionally check compiler-extracted UI keys."""
import collections
import json
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
resource = root / 'Compositor/zh-Hans.lproj/Localizable.strings'
strings = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(resource)]))
placeholder = re.compile(r'%(?:\d+\$)?(?:lld|llu|ld|lu|d|u|@|(?:\.\d+)?[fg])')

def arguments(value):
    return collections.Counter(placeholder.findall(value.replace('%%', '')))

assert arguments('%@ %lld 100%%') == collections.Counter(['%@', '%lld'])
for key, value in strings.items():
    assert value, f'Empty translation: {key}'
    assert arguments(key) == arguments(value), f'Changed format arguments: {key}'
assert strings['Multiply'] == '正片叠底'
assert strings['Save'] == '保存'
assert strings['New canvas'] == '新建画布'

if len(sys.argv) > 1:
    files = list(pathlib.Path(sys.argv[1]).glob('*.stringsdata'))
    assert files, 'No compiler-extracted strings found'
    keys = {item['key'] for path in files for item in json.loads(path.read_text()).get('tables', {}).get('Localizable', [])}
    # Technical units, channel letters, format names and bare numbers need no translation.
    unchanged = {'Compositor', 'sRGB', 'RGB', 'PNG', 'JPEG', 'PDF', 'ASCII', 'DPI', 'HSL', 'X', 'Y', 'W', 'H', 'R', 'G', 'B', 'C', 'M', 'K', 'L', 'a', 'b', 'EV'}
    missing = sorted(key for key in keys if key not in strings and key not in unchanged
                     and re.search('[A-Za-z]', placeholder.sub('', key)))
    assert not missing, 'Missing translations:\n' + '\n'.join(missing)
    print(f'PASS: {len(keys)} extracted keys covered')
print(f'PASS: {len(strings)} Chinese translations, format arguments preserved')
