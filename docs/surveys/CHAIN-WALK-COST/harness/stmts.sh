#!/bin/bash
# LOCAL ONLY: nested statement costs for one record_trail call (this DB only)
DB="host=/tmp/cwc port=55440 user=postgres dbname=$1"; SUBJ=$2; TBL=$3; CODE=$4; ROLE=${5:-cfo}
ID=$(psql "$DB" -XAt -c "select id from $TBL where code='$CODE'")
UID_=$(SEED_USERS=1 python3 -c "import walk;print(walk.USERS['$ROLE'])")
psql "$DB" -XAtq -c "create extension if not exists pg_stat_statements" -c "select pg_stat_statements_reset()" >/dev/null
psql "$DB" -XAtq >/dev/null <<SQL
BEGIN; SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"$UID_","role":"authenticated"}', true);
SELECT count(*) FROM record_trail('$SUBJ', '$ID', 20);
ROLLBACK;
SQL
psql "$DB" -XA -c "select calls, round(total_exec_time::numeric,1) ms, rows, left(regexp_replace(query,'\s+',' ','g'),170) q from pg_stat_statements where not toplevel and dbid=(select oid from pg_database where datname=current_database()) order by total_exec_time desc limit ${6:-10}"
