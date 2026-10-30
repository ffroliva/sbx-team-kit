"""Per-run summed test time, the unit-test group's time, and total CPU steal, from a fleet output directory.

Usage: python host_speed_by_run.py <dir holding one sub-directory per run, each with box*/out/*.xml and cpu_samples.txt>
Steal is the 8th field of /proc/stat's cpu line, first sample to last, summed over the boxes. Read-only.
"""
import sys
import xml.etree.ElementTree as E, glob, os, re
def summed(run, pat=''):
    t=0
    for f in glob.glob(os.path.join(run,'box*','out','*.xml')):
        for c in E.parse(f).getroot().iter('testcase'):
            if pat in (c.get('classname') or ''): t+=float(c.get('time') or 0)
    return t
def started(run):
    firsts=[int(l.split()[0]) for f in glob.glob(os.path.join(run,'box*','out','cpu_samples.txt')) for l in open(f) if l.split() and l.split()[0].isdigit()][:1]
    import datetime
    return datetime.datetime.fromtimestamp(firsts[0], datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC') if firsts else 'n/a'

def steal(run):
    tot=st=0
    for f in glob.glob(os.path.join(run,'box*','out','cpu_samples.txt')):
        rows=[l.split('|')[0].split() for l in open(f) if re.match(r'^\d+ cpu ',l)]
        if len(rows)<2: continue
        a=list(map(int,rows[0][2:])); b=list(map(int,rows[-1][2:])); d=[y-x for x,y in zip(a,b)]
        tot+=sum(d); st+=d[7]
    return st,tot
base = sys.argv[1] if len(sys.argv) > 1 else '.'
for r in sorted(d for d in os.listdir(sys.argv[1] if len(sys.argv) > 1 else '.') if '-run' in d):
    s,t=steal(os.path.join(base,r))
    print('%-14s %s summed %6.0f unit %5.0f  steal %d/%d ticks (%.2f%%)'%(r,started(os.path.join(base,r)),summed(os.path.join(base,r)),summed(os.path.join(base,r),'tests.unit'),s,t,100*s/t if t else 0))
