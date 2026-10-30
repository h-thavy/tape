#!/usr/bin/env python3
"""Checks the WCAG contrast of Theme.swift's colours: text 4.5:1, speaker colours and the recording dot 3:1."""
def L(h):
    c=[int(h[i:i+2],16)/255 for i in (0,2,4)]
    c=[x/12.92 if x<=0.03928 else ((x+0.055)/1.055)**2.4 for x in c]
    return 0.2126*c[0]+0.7152*c[1]+0.0722*c[2]
def cr(a,b):
    a,b=L(a),L(b); return (max(a,b)+0.05)/(min(a,b)+0.05)
checks = {
 "light text": (["0A0A0A","333333","4A4A4A","6E6E6E","137333","A04A06","C81E1E"], ["FFFFFF","FAFAFA","F2F2F2"], 4.5),
 "dark text":  (["F5F5F5","D4D4D4","B8B8B8","8F8F8F","4ADE80","FBBF24","F87171"], ["0E0E0E","141414","1B1B1B","232323"], 4.5),
 "light speakers": (["4F46E5","0F8A7E","C2610C","D02670","64748B"], ["FFFFFF","FAFAFA"], 3.0),
 "dark speakers":  (["A5B4FC","5EEAD4","FCD34D","F9A8D4","94A3B8"], ["0E0E0E","1B1B1B"], 3.0),
 "island text": (["FAFAFA","9A9A9A","8A8A8A","FF3B30"], ["000000","171717","1F1F1F"], 4.5),
 "rec dot on white": (["FF3B30"], ["FFFFFF"], 3.0),
}
failed = False
for name,(fg,bg,need) in checks.items():
    for f in fg:
        r=[cr(f,b) for b in bg]
        print(f"{name:16} #{f}: min {min(r):.2f} {'OK' if min(r)>=need else 'FAIL'}")
        failed |= min(r) < need
raise SystemExit(1 if failed else 0)
