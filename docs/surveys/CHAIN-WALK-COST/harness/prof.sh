#!/bin/bash
# LOCAL ONLY: profile record_trail for a few subjects on a DB as one role
DB=$1; ROLE=$2
for subj in "inbound_batch IN-2025-0001 inbound_batches" "output_batch CPW-2025-00001 output_batches" "processing_run PROC-2025-0001 processing_runs" "payroll_period PAY-2025-0001 payroll_periods" "purchase_order PO-2025-0001 purchase_orders"; do
  set -- $subj
  ID=$(psql "host=/tmp/cwc port=55440 user=postgres dbname=$DB" -XAt -c "select id from $3 where code='$2'")
  echo "== $1 $2"
  SEED_USERS=1 python3 walk.py $DB $ROLE trail $1 $ID | python3 -c "import json,sys;d=json.load(sys.stdin);print('  ', d.get('exec_ms'),'ms', d.get('rows'),'rows', d.get('shared_hit'),'buffers', d.get('error') or '');[print('    ',f) for f in d.get('fns',[])[:6]]"
done
