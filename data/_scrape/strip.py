import re,html,sys
t=open(sys.argv[1]).read()
t=re.sub(r'<script.*?</script>|<style.*?</style>','',t,flags=re.S)
# drop nav
i=t.find('<main'); t=t[i:] if i>0 else t
t=re.sub(r'<(br|tr|li|h\d|p|div)[^>]*>','\n',t)
t=re.sub(r'<[^>]+>',' ',t); t=html.unescape(t)
t=re.sub(r'[ \t]+',' ',t); t=re.sub(r'\n\s*\n+','\n',t)
print(t)
