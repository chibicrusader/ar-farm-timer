import re,html,json,glob,os
res={}
for f in glob.glob('raw/dd/*.html'):
    id_=os.path.basename(f)[:-5]
    t=open(f).read(); i=t.find('<main'); t=t[i:] if i>0 else t
    s=re.sub(r'<script.*?</script>|<style.*?</style>','',t,flags=re.S)
    s=html.unescape(re.sub(r'<[^>]+>',' ',s)); s=re.sub(r'\s+',' ',s)
    m=re.search(r'Objects > (.*?) ID:',s); name=m.group(1).strip() if m else None
    c=re.search(r'Climate: (\w+)',s); g=re.search(r'Growth time: (.*?) (?:Items|Spawns|Placed|Contains|Images|Merchant)',s)
    # placed by: find section of item links? take all item ids in the page
    items=sorted(set(re.findall(r'/na-en/db/items/(\d+)"',t)))
    res[id_]=dict(name=name,climate=c.group(1) if c else None,growth=g.group(1) if g else None,items=items)
json.dump(res,open('raw/dd_parsed.json','w'),indent=1)
n=[k for k,v in res.items() if v['growth']]
print(len(res),len(n))
for k in sorted(n,key=int): print(k,res[k]['name'],'|',res[k]['climate'],'|',res[k]['growth'])
