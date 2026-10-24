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
GENERIC={'10704','10705','9000016','9001755','419','2249','2258','453'}
def norm(n): return re.sub(r'\b(seed|sapling|seedling|eyes?|spore|polyp|tree|plant|reef|rock|calf|kid|chick|duckling|gosling|lamb|piglet)s?\b','',n.lower()).strip()
out=[]
for o in items:
    cands=[(k,dd[k]) for k in o['doodads'] if k in dd and dd[k]['growth'] and k not in GENERIC]
    best=None
    for k,v in cands:
        if v['name'] and (v['name'].lower()==o['name'].lower() or norm(v['name'])==norm(o['name']) or norm(o['name']) in v['name'].lower()):
            best=(k,v);break
    if not best and len(cands)==1: best=cands[0]
    o['dd']=best[0] if best else None
    o['dd_name']=best[1]['name'] if best else None
    o['dd_growth']=tomin(re.sub(r'Quests.*|Placement.*','',best[1]['growth'])) if best else None
    o['dd_climate']=best[1]['climate'] if best else None
    o['cands']=[(k,v['name'],v['growth']) for k,v in cands]
json.dump(items,open('raw/items_joined.json','w'),indent=1)
for o in items:
    tm=o['mature_min']; dg=o['dd_growth']
    if o['mature_raw'] or o['dd']:
        flag='' if (tm and dg and abs(tm-dg)/dg<0.06) else '  <<<'
        print(o['id'],o['name'],'| tip',tm,'| dd',o['dd'],o['dd_name'],dg,o['dd_climate'],flag, '' if o['dd'] else o['cands'])
