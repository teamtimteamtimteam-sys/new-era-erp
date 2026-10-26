# Read-only audit: live public.* vs two backups, row by row (COPY text lines, multiset compare).
import subprocess,re,os,sys,json,collections,hashlib
B=os.path.expanduser('~/evoltrya-backups/')
DUMPS={'B0':B+'evoltrya-backup-2026-10-23-1520.dump','B1':B+'evoltrya-backup-2026-10-26-1453.dump'}
DSN="host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres"
def parse_copy(text):
    out={};cols={};cur=None
    for line in text.split('\n'):
        if cur is None:
            m=re.match(r'COPY (\S+) \((.*)\) FROM stdin;$',line)
            if m: cur=m.group(1);cols[cur]=m.group(2);out[cur]=[]
        elif line=='\\.': cur=None
        else: out[cur].append(line)
    return out,cols
data={};cols=None
for k,p in DUMPS.items():
    t=subprocess.run(['pg_restore','-f','-','--data-only','-n','public',p],capture_output=True,text=True,check=True).stdout
    data[k],c=parse_copy(t)
    if k=='B1': cols=c
    print(k,len(data[k]),'tables',sum(len(v) for v in data[k].values()),'rows',file=sys.stderr)
# live: one read-only session, same session settings pg_dump uses
sql=["\\set ON_ERROR_STOP 1","SET DATESTYLE = ISO;","SET INTERVALSTYLE = POSTGRES;","SET extra_float_digits TO 3;","BEGIN READ ONLY;"]
for t,c in cols.items():
    sql.append(f"\\echo '@@TABLE {t}'")
    sql.append(f"COPY {t} ({c}) TO STDOUT;")
sql.append("\\echo '@@SEQ'")
sql.append("SELECT schemaname||'.'||sequencename, coalesce(last_value::text,'NULL') FROM pg_sequences WHERE schemaname='public' ORDER BY 1;")
sql.append("\\echo '@@TZ'"); sql.append("SHOW TimeZone;")
sql.append("ROLLBACK;")
open('live.sql','w').write('\n'.join(sql)+'\n')
r=subprocess.run(['psql',DSN,'-X','-q','-At','-F','|','-f','live.sql'],capture_output=True,text=True)
open('live.out','w').write(r.stdout); open('live.err','w').write(r.stderr)
print('LIVE_PSQL_EXIT',r.returncode,file=sys.stderr)
if r.returncode: print(r.stderr[:2000]);sys.exit(2)
live={};cur=None;seq={};mode=None
for line in r.stdout.split('\n'):
    if line.startswith('@@TABLE '): cur=line[8:];live[cur]=[];mode='t';continue
    if line=='@@SEQ': mode='s';continue
    if line=='@@TZ': mode='z';continue
    if mode=='t' and line!='': live[cur].append(line)
    elif mode=='s' and line: a,b=line.split('|');seq[a]=b
    elif mode=='z' and line: print('live TimeZone',line,file=sys.stderr)
json.dump({'B0':data['B0'],'B1':data['B1'],'L':live,'seq':seq,'cols':cols},open('rows.json','w'))
print('saved',file=sys.stderr)
