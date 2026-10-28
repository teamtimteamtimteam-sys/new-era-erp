#!/bin/bash
# LOCAL ONLY: nested statement costs for one document_chain_walk call (this DB only). args: db chain step key table code [role] [n]
DB="host=/tmp/cwc port=55440 user=postgres dbname=$1"; CHAIN=$2; STEP=$3; KEY=$4; TBL=$5; CODE=$6; ROLE=${7:-cfo}
ID=$(psql "$DB" -XAt -c "select id from $TBL where code='$CODE'")
SQL=$(SEED_USERS=1 python3 -c "import walk,json;c=walk.CH['$CHAIN'];print(\"SELECT count(*) FROM document_chain_walk('%s'::jsonb, %d, '$KEY', '$ID')\" % (json.dumps(c['def']).replace(\"'\",\"''\"), c['steps'].index('$STEP')))")
UID_=$(SEED_USERS=1 python3 -c "import walk;print(walk.USERS['$ROLE'])")
psql "$DB" -XAtq -c "select pg_stat_statements_reset()" >/dev/null
psql "$DB" -XAt <<SQL2 | grep -E "^[0-9]+$|Execution"
BEGIN; SELECT set_config('app.chain_walk_budget_ms', '600000', true) \g /dev/null
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"$UID_","role":"authenticated"}', true) \g /dev/null
$SQL;
ROLLBACK;
SQL2
psql "$DB" -XA -c "select calls, round(total_exec_time::numeric,1) ms, rows, left(regexp_replace(query,'\s+',' ','g'),${9:-220}) q from pg_stat_statements where not toplevel and dbid=(select oid from pg_database where datname=current_database()) order by total_exec_time desc limit ${8:-8}"
