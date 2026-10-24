import re,html,json,os
lists={}
for f in ['raw/items_plants.html.json','raw/items_animals.html.json']:
    for c in json.load(open(f)): lists[c[0]]=c
out=[]
for id_,c in lists.items():
    t=open(f'raw/items/{id_}.html').read()
    i=t.find('<main'); t2=t[i:] if i>0 else t
    s=re.sub(r'<script.*?</script>|<style.*?</style>','',t2,flags=re.S)
    s=re.sub(r'<(br|tr|li|h\d|p|div)[^>]*>','\n',s); s=html.unescape(re.sub(r'<[^>]+>',' ',s))
    s=re.sub(r'[ \t]+',' ',s)
    m=re.search(r'Use:(.*?)(Shop price|Refund price|Skills \(|Quests \(|Items \(|NPCs \()',s,re.S)
    desc=re.sub(r'\n\s*',' | ',m.group(1).strip()) if m else ''
    dd=sorted(set(re.findall(r'href="/na-en/db/doodads/(\d+)"',t)))
    out.append(dict(id=id_,name=c[2],grade=c[3],group=c[4],cat=c[5],desc=desc,doodads=dd))
json.dump(out,open('raw/items_parsed.json','w'),indent=1)
for o in out:
    if re.search(r'Matur|Harvest|Grow|hour| h | m\b|Climate',o['desc']): print(o['id'],o['name'],'::',o['desc'][:400])
