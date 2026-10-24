import json,re
items=json.load(open('raw/items_extracted.json'))
if False:
    pass
dd=json.load(open('raw/dd_parsed.json'))
def tomin(s):
    if not s: return None
    s=s.lower(); tot=0; f=False
    for n,u in re.findall(r'(\d+(?:\.\d+)?)\s*(days?|d|hours?|hrs?|h|minutes?|min|m|seconds?|s)\b',s):
        n=float(n); f=True
        tot+= n*1440 if u.startswith('d') else n*60 if u.startswith('h') else n/60 if u.startswith('s') else n
    return round(tot,2) if f else None
