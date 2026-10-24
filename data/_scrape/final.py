import json,re
items={o['id']:o for o in json.load(open('raw/items_joined.json'))}
W='https://wiki.archerage.to/na-en/db/items/'
D='https://wiki.archerage.to/na-en/db/doodads/'
SF='https://na.archerage.to/forums/threads/server-features.9254/'
HALF2018='https://na.archerage.to/forums/threads/new-seeds-timers-not-halved.5310/'
P85='https://na.archerage.to/forums/threads/archerage-8-5-global-update-patch-notes.11780/'
P85RU='https://ru.archerage.to/forums/threads/patch-archerage-8-5-release-maintenance.13471/'
SKIP_NAMES={'Test','9000343','Stationary Cannon Foundation','Chess Board King','Poster','Tropical Livestock Test'}
REPLANT=set("""Turmeric Seed Bundle,Poppy Seed Bundle,Saffron Seed Bundle,Mushroom Spore Bundle,Thistle Seed Bundle,Aloe Seed Bundle,Cultivated Ginseng Seed Bundle,Potato Eyes Bundle,Cucumber Seed Bundle,Carrot Seed Bundle,Onion Seed Bundle,Clover Seed Bundle,Azalea Seed Bundle,Narcissus Seed Bundle,Rose Seed Bundle,Cotton Seed Bundle,Lily Seed Bundle,Lotus Seed Bundle,Cornflower Seed Bundle,Cactus Seed Bundle,Iris Seed Bundle,Lavender Seed Bundle,Mint Seed Bundle,Rosemary Seed Bundle,Sunflower Seed Bundle,Tomato Seed Bundle,Garlic Seed Bundle,Strawberry Seed Bundle,Pumpkin Seed Bundle,Yam Seed Bundle,Chili Pepper Seed Bundle,Barley Seed Bundle,Rice Seed Bundle,Millet Seed Bundle,Blueberry Seed Bundle,Vanilla Seed Bundle,Black Pepper Seed Bundle,Wheat Seed Bundle,Oat Seed Bundle,Rye Seed Bundle,Bean Seed Bundle,Quinoa Seed Bundle,Clubhead Spore Bundle,Rubber Tree Woodlot,Aspen Woodlot,Maple Woodlot,Bamboo Woodlot,Pine Woodlot,Pearl Oyster Bundle,Green Coral Polyp Bundle,Red Coral Polyp Bundle,White Coral Polyp Bundle,Blue Coral Polyp Bundle,Antler Coral Polyp Bundle""".replace('\n','').split(','))
REPLANT.add('Potato Eye Bundle')
HALVED2018={'Pineapple Seed','Pineapple Seed Bundle','Pansy Seed','Pansy Seed Bundle','Amaranth Seed','Amaranth Seed Bundle','Hibiscus Sapling','High Quality Hibiscus Sapling','Watermelon Seed','Watermelon Seed Bundle','Impatiens Seed','Impatiens Seed Bundle'}
SPECIAL_PAT=re.compile(r'Greenhouse|Improved|Experia|Experimental|Magic|Cornucopia|Majestic|Archeum|Territory|Twilight|Dawnleaf|Sunglow|Bunny|Girl.s Cherry|Wish Tree|Topiary|Gembloom|Unidentified|Strange Pumpkin|Yellow Yam|Magical Cacao|Special Cacao|Daru|Livestock Pen|Small Bamboo Trap|Graywisp|Beehive')
def cat(o):
    n=o['name'];d=o['desc']
    if re.search('Aquafarm|Coral|Kelp|Oyster',n+d): return 'aquafarm'
    if 'Greenhouse' in n: return 'greenhouse'
    if re.search(r'Experia|Experimental|Magic Seed|Cornucopia|Majestic|Archeum|Territory|Twilight|Dawnleaf|Sunglow|Bunny|Girl\'s Cherry|Wish Tree|Topiary|Gembloom|Unidentified|Strange Pumpkin|Yellow Yam|Magical Cacao|Special Cacao|Graywisp',n): return 'special'
    if o['cat']=='Livestock products' or re.search(r'Pen|Coop|Cage|Trap|Beehive',n): return 'livestock_pen'
    if o['cat']=='Livestock': return 'livestock'
    if 'Woodlot' in n: return 'woodlot'
    if re.search(r'Spore|Mushroom|Clubhead',n): return 'mushroom'
    if 'Bundle' in n: return 'seed_bundle'
    if o['cat']=='Saplings': return 'fruit_tree' if o.get('harvest_raw') else 'tree'
    return 'crop'
def fmt(m):
    if m is None: return None
    return int(m) if m==int(m) else (round(m,2) if m<5 else round(m,1))
out=[];skipped=[];seen={}
for id_,o in items.items():
    n=o['name']
    if n in SKIP_NAMES or re.search(r'[А-я]',n): skipped.append((id_,n,'non-farm/test/untranslated'));continue
    if n.startswith('Bound '): skipped.append((id_,n,'Bound duplicate of tradeable item with identical timers'));continue
    if not (o['mature_raw'] or o['dd']) and id_ not in ('40230','28480'): continue
    tip=o['mature_min']; ddg=o['dd_growth']
    srcs=[W+id_]
    notes=[]
    if tip and ddg and abs(tip-ddg)/ddg<0.06:
        base=ddg; srcs.append(D+o['dd']); basis=f"doodad growth time ({o['dd_name']}, {D+o['dd']}); tooltip says '{o['mature_raw']}'"
    elif tip:
        base=tip; basis=f"item tooltip '{o['mature_raw']}'"
        if ddg: srcs.append(D+o['dd']); notes.append(f"DISCREPANCY: linked object '{o['dd_name']}' lists growth {fmt(ddg)} min vs tooltip {fmt(tip)} min; tooltip used.")
    elif ddg:
        base=ddg; srcs.append(D+o['dd']); basis=f"doodad growth time only ({o['dd_name']}); item tooltip has no maturity line"
    else:
        base=None; basis='no timer in DB'
    if o['mature_raw'] and 'second' in o['mature_raw'] and not ddg:
        m=re.search(r'(\d+) seconds',o['mature_raw']); base=round(int(m.group(1))/60,2); basis=f"tooltip '{o['mature_raw']}'"
    c=cat(o)
    special = c in ('special','greenhouse') or bool(SPECIAL_PAT.search(n)) or int(id_)>=8000000
    harvest=o.get('harvest_raw'); hmin=o.get('harvest_min')
    m=re.search(r'(\w+(?: eggs)?) every ([^|]*)',o['desc'])
    if m and not harvest: harvest=m.group(0); 
    if m:
        from build_tomin import tomin
        hmin=tomin(m.group(2)); harvest=m.group(0).strip()
    times=None
    mm=re.search(r'(?:harvested|logged|milked|gathered)\w*\s*(?:up to\s*)?(\d+|three) times|After harvesting (three) times|after (three) harvests',o['desc'],re.I)
    if mm: g=next(x for x in mm.groups() if x); times=3 if g=='three' else int(g)
    # harvestCycles semantics
    if times: cycles=times
    elif hmin: cycles=None  # repeating, limit unknown
    else: cycles=1
    # climate
    clim=o['climate']
    zone=re.search(r'only grows in (?:the )?([A-Z][\w ]+?)\s*\.',o['desc'])
    if zone: clim='Zone-locked: '+zone.group(1).strip()
    elif re.search(r'suitable for the climate on Auroria',o['desc']): clim='Auroria'
    elif clim in ('All','Any') or re.search(r'any climate|all climates|regardless of weather|not influenced by climate',o['desc'],re.I) or (not clim and o['dd_climate']=='All'): clim='Any'
    elif clim=='unknown': clim=None
    if not clim and o['dd_climate'] and o['dd_climate'] not in ('All',): clim=o['dd_climate']
    # wither
    wither=None
    for pat,val in [(r'Dies in one day',1440),(r'Disappears in 6 days',8640),(r'Disappears after 48 hours',2880),(r'last 24 hours before disappearing',1440)]:
        if re.search(pat,o['desc']): wither=val; notes.append(f"Explicit lifetime from tooltip: {val} min (not known whether ArcheRage halves this).")
    for w in o['wither']:
        if re.search(r'neglected|unattended|disappears\.|tree will disappear|Disappears after three|Collapsed|Diasppears|Vanishes|60 minutes',w) : notes.append('Tooltip: '+w.strip())
    eff=fmt(base/2) if base is not None else None
    effh=fmt(hmin/2) if hmin else None
    if id_=='40230':
        base=240; eff=120; wither=1440; cycles=1; clim=None; c='special'
        basis="tooltip 'Can be harvested after 4 hours'"; notes.append("Territory Sapling: Auroran territory only; 'Can be harvested after 4 hours ... Dies in one day if not harvested.' Halving unverified for this item.")
    if id_=='28480':
        base=1440; eff=720; c='livestock_pen'; clim='Any'; cycles=None; hmin=1440; effh=720; srcs.append(D+'7004')
        basis="tooltip 'Fills with Honey in 1 d' (2/3/4 d with queen bee; object 7004 lists 4 days)"
        notes.append("Beehive: honey accrues the longer it is left (1 d base; 2, 3 or 4 d with Queen Bee for more honey/Royal Jelly). Consumes lumber; destroyed if left unattended for long periods (duration not stated). Wear Beekeeper's Veil / use Smoke Bead.")
    if n in REPLANT: notes.append('ArcheRage 8.5 custom: harvest-and-replant option for this bundle.'); 
    if n in HALVED2018: notes.append('ArcheRage staff explicitly listed this item for the 50% growth-time cut (Mar 2018).')
    sub=re.search(r'Category: (\w+)',o['desc'])
    rec=dict(
        name=n, category=c, subcategory=sub.group(1) if sub else None, itemId=int(id_),
        growTimeMinutes=eff, baseGrowTimeMinutes=fmt(base) if base is not None else None,
        harvestCycles=cycles, harvestIntervalMinutes=effh, baseHarvestIntervalMinutes=fmt(hmin) if hmin else None,
        witherOrDeathMinutes=wither, climate=clim,
        notes=' '.join([f"Base (vanilla/client) time from ArcheRage DB: {basis}. growTimeMinutes = base x 0.5 per ArcheRage 2x growth rule (non-native climate, unwatered)."+ (f" Repeat harvest: '{harvest}' (interval halved likewise)." if hmin else '')]+notes),
        source=srcs+[SF]+([HALF2018] if n in HALVED2018 else [])+([P85RU] if n in REPLANT else []),
        archerageConfirmed=(not special) and base is not None,
    )
    if base is None: rec['notes']+=' Growth time unknown.'
    key=(n,rec['baseGrowTimeMinutes'],rec['baseHarvestIntervalMinutes'])
    if key in seen: skipped.append((id_,n,f'duplicate of item {seen[key]}'));continue
    seen[key]=id_
    out.append(rec)
# wild ginseng
for r in out:
    if r['name']=='Wild Ginseng Seed': r['notes']+=' Tooltip says matures in "an unknown length of time"; value is from the wild object (doodad 492, 2 days). Low confidence.'; r['archerageConfirmed']=False
    if r['name']=='Rice Seed': r['climate']='Any'
    if r['name'] in ('Cornucopia Cow',): r['notes']+=' After 9 milkings it can be butchered.'
out.sort(key=lambda r:(r['category'],r['name']))
json.dump(out,open('archerage-farm-timer/data/farm_items.json','w'),indent=2,ensure_ascii=False)
json.dump(skipped,open('raw/skipped.json','w'),indent=1)
from collections import Counter
print(len(out),Counter(r['category'] for r in out)); print('confirmed',sum(r['archerageConfirmed'] for r in out))
print('skipped',len(skipped))
