import re,json
items=json.load(open('raw/items_parsed.json'))
def tomin(s):
    if not s: return None
    s=s.lower().replace('approx.','').strip()
    tot=0;found=False
    for n,u in re.findall(r'(\d+(?:\.\d+)?)\s*(d|days?|h|hours?|hr|m|min|minutes?)\b',s):
        n=float(n);found=True
        tot+= n*1440 if u.startswith('d') else n*60 if u.startswith('h') else n
    return int(round(tot)) if found else None
for o in items:
    d=o['desc']
    m=re.search(r'Matures in ([^|]*)',d); o['mature_raw']=m.group(1).strip() if m else None
    m=re.search(r'(?:Harvest|Log|Gather|Collect)\w* every ([^|]*)',d,re.I); o['harvest_raw']=m.group(1).strip() if m else None
    m=re.search(r'Climate: ([^|]*)',d); o['climate']=m.group(1).strip() if m else None
    m=re.search(r'(?:harvested|logged|gathered|collected)\w*\s*(?:up to\s*)?(\d+) times|After harvesting (\w+) times|after (\w+) harvests',d,re.I); o['times']=next((g for g in m.groups() if g),None) if m else None
    o['mature_min']=tomin(o['mature_raw']); o['harvest_min']=tomin(o['harvest_raw'])
    o['wither']=[x.strip() for x in d.split('|') if re.search(r'disappear|dies|die |wither|neglect|rot',x,re.I)]
json.dump(items,open('raw/items_extracted.json','w'),indent=1)
for o in items:
    print(o['id'],o['cat'],o['name'],'| M:',o['mature_raw'],o['mature_min'],'| H:',o['harvest_raw'],o['harvest_min'],'| C:',o['climate'],'| T:',o['times'],'| W:',o['wither'])
