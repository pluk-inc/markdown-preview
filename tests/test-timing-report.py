"""Summarise the per-test timing log that TestTiming writes.

Usage: python3 tests/test-timing-report.py <timing.tsv> [count]

Prints Markdown: the slowest tests, the slowest classes, and how the
total test time compares with the span from the first test start to the
last test end (build and process startup are not included).
"""
from collections import defaultdict
from pathlib import Path
import re
import sys

path = sys.argv[1]
count = int(sys.argv[2]) if len(sys.argv) > 2 else 25

rows = []
for line in Path(path).read_text(encoding='utf-8').splitlines():
    start, end, seconds, result, _pid, name = line.split('\t')
    match = re.match(r'-\[(\S+) (\S+)\]', name)
    test_class, test = match.groups() if match else ('?', name)
    rows.append((float(start), float(end), float(seconds), result, test_class, test))

if not rows:
    sys.exit('No timings recorded.')

first = min(r[0] for r in rows)
span = max(r[1] for r in rows) - first
total = sum(r[2] for r in rows)
failed = sum(r[3] != 'passed' for r in rows)

print('## Test timing\n')
print(f'{len(rows)} tests, {failed} failed. Test time {total:.0f} s in a {span:.0f} s span from first test start to last test end.\n')

print(f'### Slowest {count} tests\n')
print('| Seconds | Starts at | Ends at | Test |')
print('| ---: | ---: | ---: | --- |')
for start, end, seconds, result, test_class, test in sorted(rows, key=lambda r: -r[2])[:count]:
    mark = '' if result == 'passed' else ' (failed)'
    print(f'| {seconds:.1f} | {start - first:.1f} | {end - first:.1f} | {test_class}.{test}{mark} |')

by_class = defaultdict(lambda: [0.0, 0])
for row in rows:
    by_class[row[4]][0] += row[2]
    by_class[row[4]][1] += 1
print('\n### Slowest classes\n')
print('| Seconds | Tests | Class |')
print('| ---: | ---: | --- |')
for test_class, (seconds, tests) in sorted(by_class.items(), key=lambda kv: -kv[1][0])[:10]:
    print(f'| {seconds:.1f} | {tests} | {test_class} |')
