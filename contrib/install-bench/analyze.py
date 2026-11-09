#!/usr/bin/env python3
"""Per-task timing breakdown from an XCP-ng installer install-log."""
import re, sys, datetime
ts_re = re.compile(r'^\w+\s*\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] (.*)')
task_re = re.compile(r'TASK: Evaluating <(?:function|bound method) ([\w.]+)')
events = []  # (time, label)
first = None
dnf_lines = 0
for line in open(sys.argv[1], errors='replace'):
    m = ts_re.match(line)
    if not m: continue
    t = datetime.datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S')
    first = first or t
    msg = m.group(2)
    if msg.startswith('DNF:'): dnf_lines += 1
    tm = task_re.search(msg)
    if tm: events.append((t, tm.group(1)))
    elif msg.startswith('Running : dnf'): events.append((t, '  dnf ' + msg.split()[-1]))
    elif 'Running transaction' in msg and msg.startswith('DNF:'): events.append((t, '  dnf: running transaction'))
    elif 'DISPATCH: NEW PHASE' in msg: events.append((t, '== ' + msg.split(':',2)[-1].strip()))
    elif 'installation completed' in msg: events.append((t, 'END'))
    last = t
events.append((last, 'END(log)'))
print(f"log span: {(last-first).total_seconds():.0f}s, DNF output lines: {dnf_lines}")
for (t, l), (t2, _) in zip(events, events[1:]):
    d = (t2 - t).total_seconds()
    if d >= 1 or l.startswith('=='):
        print(f"{(t-first).total_seconds():6.0f}s  {d:5.0f}s  {l}")
