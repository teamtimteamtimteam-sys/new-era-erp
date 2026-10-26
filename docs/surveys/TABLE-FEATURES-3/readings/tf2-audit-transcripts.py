import json,re,glob,collections,os
D=os.path.expanduser('~/.claude/projects/-Users-timchen/674e2682-bb53-4048-b7bd-2783b2219632/subagents/')
ins=collections.Counter();dele=collections.Counter();upd=collections.Counter();srr=collections.Counter();live=collections.Counter()
for f in sorted(glob.glob(D+'agent-*.jsonl')):
    a=os.path.basename(f)[6:23]
    for line in open(f):
        try:o=json.loads(line)
        except:continue
        m=o.get('message',{})
        if m.get('role')!='assistant':continue
        for c in m.get('content',[]) if isinstance(m.get('content'),list) else []:
            if c.get('type')!='tool_use':continue
            s=json.dumps(c.get('input',{}))
            s=s.replace('\\n',' ')
            islive=('api.supabase.com' in s) or ('pooler' in s) or ('wvywpohbwkiinmipmuku' in s) or ('PGSERVICE' in s)
            if islive: live[a]+=1
            for t in re.findall(r'(?i)insert\s+into\s+(?:public\.)?"?(\w+)',s): ins[(a,t.lower(),islive)]+=1
            for t in re.findall(r'(?i)delete\s+from\s+(?:public\.)?"?(\w+)',s): dele[(a,t.lower(),islive)]+=1
            for t in re.findall(r'(?i)\bupdate\s+(?:public\.)?"?(\w+)"?\s+set',s): upd[(a,t.lower(),islive)]+=1
            if 'session_replication_role' in s: srr[(a,islive)]+=1
print('agents with live-looking calls:',dict(live))
for name,c in [('INSERT',ins),('DELETE',dele),('UPDATE',upd)]:
    print('==',name)
    for (a,t,l),n in sorted(c.items()): print(f'  {a} {t:40s} live={l} n={n}')
print('== srr',dict(srr))
