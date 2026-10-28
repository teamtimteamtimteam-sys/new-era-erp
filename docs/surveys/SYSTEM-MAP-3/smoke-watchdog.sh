#!/bin/bash
# SYSTEM-MAP-3 · smoke 的看门狗(Tim 2026-10-28 10:40 的中止规则):每 60 s 量一次库那一侧
cd /Users/timchen/Documents/projects/new-era-erp
LOG=docs/surveys/SYSTEM-MAP-3/readings/smoke-watchdog.txt
DSN="host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres"
TOK=$(security find-generic-password -s "Supabase CLI" -w)
while ! grep -q "^SMOKE_EXIT=" docs/surveys/SYSTEM-MAP-3/readings/smoke.txt 2>/dev/null; do
  out=$(printf '\\timing on\nselect 1;\nselect 1;\nselect 1;\nselect 1;\nselect 1;\nexplain (analyze) select 1;\n' | psql "$DSN" -X -At 2>&1)
  times=$(echo "$out" | grep -oE "^Time: [0-9.]+" | head -5 | awk '{print $2}')
  med=$(echo "$times" | sort -n | sed -n 3p); max=$(echo "$times" | sort -n | tail -1)
  ex=$(echo "$out" | grep -oE "Execution Time: [0-9.]+" | awk '{print $3}')
  h=$(curl -s -m 40 -A curl/8.4.0 -H "Authorization: Bearer $TOK" "https://api.supabase.com/v1/projects/wvywpohbwkiinmipmuku/health?services=db&services=rest" | grep -oE '"name":"[a-z]+","healthy":(true|false)' | tr '\n' ' ')
  echo "$(date +%H:%M:%S) median=${med}ms max=${max}ms in-db=${ex}ms ${h}" >> $LOG
  awk -v m="$max" 'BEGIN{exit !(m>1500)}' && echo "$(date +%H:%M:%S) WARN single round trip ${max} ms (recorded)" >> $LOG
  if awk -v e="${ex:-999}" -v m="${med:-99999}" 'BEGIN{exit !(e>50 || m>1500)}' || ! echo "$h" | grep -q '"db","healthy":true' || ! echo "$h" | grep -q '"rest","healthy":true'; then
    echo "$(date +%H:%M:%S) ABORT smoke: median=${med} in-db=${ex} ${h}" >> $LOG
    pkill -TERM -f "scripts/smoke-routes.mjs"; exit 1
  fi
  sleep 60
done
echo "$(date +%H:%M:%S) smoke finished; watchdog done" >> $LOG
