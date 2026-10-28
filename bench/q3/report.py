#!/usr/bin/env python3
"""Reads bench/out/q3/results.csv, prints markdown tables (per category, per config, both threading modes)."""
import csv, statistics as st, collections, sys
rows = list(csv.DictReader(open(__import__('os').path.join(__import__('os').path.dirname(__import__('os').path.abspath(__file__)),'..','out','q3','results.csv'))))
CFG = ['o2', 'o4', 'omax', 'omaxzop']
NAME = {'o2': '-o 2 (default)', 'o4': '-o 4', 'omax': '-o max', 'omaxzop': '-o max --zopfli'}
def sel(cat, c, m, files=None):
    return [r for r in rows if r['category'] == cat and r['config'] == c and r['threads'] == m and (files is None or r['file'] in files)]
def table(cat, files=None, title=''):
    print(f'\n#### {title or cat}\n')
    print('| config | n | ok | median saved % | total out bytes | total src bytes | total saved % | MT median ms | MT total ms | ST median ms | ST total ms | lossless |')
    print('|---|---|---|---|---|---|---|---|---|---|---|---|')
    for c in CFG:
        mt, s1 = sel(cat, c, 'mt', files), sel(cat, c, 'st', files)
        if not mt: continue
        ok = [r for r in mt if r['exit'] == '0']
        sv = [100 * (1 - int(r['out_bytes']) / int(r['src_bytes'])) for r in ok]
        ob = sum(int(r['out_bytes']) for r in ok); sb = sum(int(r['src_bytes']) for r in ok)
        ms = lambda L: [int(r['ms']) for r in L]
        def agg(L):
            if not L: return ('-', '-')
            tag = '' if all(r['exit'] == '0' for r in L) else '+ (timeouts)'
            return (f'{st.median(ms(L)):.0f}', f'{sum(ms(L))}{tag}')
        ll = all(r['lossless'] == 'identical' for r in ok)
        a, b = agg(mt), agg(s1)
        print(f"| {NAME[c]} | {len(mt)} | {len(ok)} | {st.median(sv) if sv else float('nan'):.2f} | {ob} | {sb} | {100*(1-ob/sb) if sb else 0:.2f} | {a[0]} | {a[1]} | {b[0]} | {b[1]} | {'all identical' if ll else 'CHECK'} |")
zf = {r['file'] for r in rows if r['config'] == 'omaxzop'}
for cat in ['screenshot', 'alpha', 'edge16']:
    table(cat)
print('\n### Like-for-like on the zopfli subset')
for cat in ['screenshot', 'alpha']:
    table(cat, zf, f'{cat} (zopfli subset: ' + ', '.join(sorted(f for f in zf if cat[:3] in f or (cat == 'alpha' and 'alpha' in f))) + ')')
table('edge16', None, 'edge16 (edge-02, 36.8 MB)')
bad = [r for r in rows if r['exit'] != '0' or (r['lossless'] not in ('identical', 'timeout'))]
print('\nNon-clean rows:', len(bad)); [print(r) for r in bad]
