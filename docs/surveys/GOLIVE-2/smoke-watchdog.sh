#!/usr/bin/env bash
# GOLIVE-2 · smoke watchdog —— AGENTS.md「线上证明一次一位读者」的中止规则用在冒烟上(委托书:abort rules apply to every live step including smoke)。
#   每 ~70 s 量一次:五次 select 1 往返的中位数 > 1.5 s · 库里 select 1 的执行 > 50 ms · Management API health 不是 db/rest 都健康 → 记 ABORT,
#   向冒烟的 node 进程【本身】发 SIGTERM(它自己的清理计划照跑)。单次往返 > 1.5 s 只记不停。冒烟的进程没了,本支就收工。
# 用法:docs/surveys/GOLIVE-2/smoke-watchdog.sh <冒烟 node 的 pid> >> <日志>
PID=$1
DSN='host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
TOK=$(security find-generic-password -s "Supabase CLI" -w)
echo "$(date +%H:%M:%S) watchdog anchored to the smoke node process $PID"
while kill -0 "$PID" 2>/dev/null; do
    out=$(printf '\\timing on\nselect 1;\nselect 1;\nselect 1;\nselect 1;\nselect 1;\nexplain (analyze) select 1;\n' | psql "$DSN" -X -At 2>&1)
    times=$(echo "$out" | sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' | head -5 | sort -n)
    med=$(echo "$times" | sed -n 3p); max=$(echo "$times" | tail -1)
    exe=$(echo "$out" | sed -n 's/.*Execution Time: \([0-9.]*\) ms.*/\1/p')
    h=$(curl -s -m 40 -A curl/8.4.0 -H "Authorization: Bearer $TOK" "https://api.supabase.com/v1/projects/wvywpohbwkiinmipmuku/health?services=db&services=rest" \
        | python3 -c 'import json,sys; print(" ".join(x["name"]+"="+x["status"] for x in json.load(sys.stdin)))' 2>/dev/null || echo health=UNREADABLE)
    echo "$(date +%H:%M:%S) median=${med}ms max=${max}ms in-db=${exe}ms ${h} · node=$PID"
    why=""
    awk "BEGIN{exit !(${med:-99999} > 1500)}" && why="median of five round trips ${med} ms > 1500"
    awk "BEGIN{exit !(${exe:-99999} > 50)}" && why="select 1 inside the database ${exe} ms > 50"
    case "$h" in *db=ACTIVE_HEALTHY*rest=ACTIVE_HEALTHY*|*rest=ACTIVE_HEALTHY*db=ACTIVE_HEALTHY*) ;; *) why="health $h" ;; esac
    awk "BEGIN{exit !(${max:-0} > 1500)}" && echo "$(date +%H:%M:%S) WARN a single round trip took ${max} ms (> 1500 ms; recorded, not an abort)"
    if [ -n "$why" ]; then echo "$(date +%H:%M:%S) ABORT $why — SIGTERM to the smoke node process $PID"; kill -TERM "$PID"; exit 1; fi
    sleep 60
done
echo "$(date +%H:%M:%S) the smoke node process $PID is gone — watchdog done"
