import re,html,sys,subprocess
u=sys.argv[1]; f='raw/forum_'+re.sub(r'\W','_',u)[-60:]+'.html'
subprocess.run(['curl','-sL','-A','Mozilla/5.0',u,'-o',f])
t=open(f).read()
for m in re.findall(r'<article[^>]*message-body[^>]*>(.*?)</article>',t,re.S):
    print('---',re.sub(r'\s+',' ',html.unescape(re.sub(r'<[^>]+>',' ',m))).strip()[:int(sys.argv[2]) if len(sys.argv)>2 else 3000])
