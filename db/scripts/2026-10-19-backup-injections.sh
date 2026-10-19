#!/usr/bin/env bash
# MES-9b — fault injection and restore proof for db/backup.sh (Tim's ruling 1), on a throwaway LOCAL cluster (never live).
# Cells: ① clean run → BACKUP_EXIT=0, the three checks printed, then a restore into an empty database (pg_restore + every chunk via \copy +
#        setval) whose change_log matches the source row for row (md5 over every row) and in count/min/max;
#        ② chunk 1 fails once → retried, BACKUP_EXIT=0;  ③ chunk 1 fails twice → BACKUP_EXIT=1, no good-named file left;
#        ④ a row dropped from chunk 0 → the count check refuses, BACKUP_EXIT=1.
# Usage: db/scripts/2026-10-19-backup-injections.sh > log 2>&1; echo "BKINJ_OWN_EXIT=$?" >> log
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W=$(mktemp -d /tmp/bkinj.XXXX); S="$W/s"; mkdir -p "$S" "$W/out"
PORT=55441
initdb -D "$W/pg" -U postgres --no-locale --encoding=UTF8 >/dev/null 2>&1
pg_ctl -D "$W/pg" -o "-p $PORT -k $S -c listen_addresses=''" -l "$W/pg.log" start >/dev/null
trap 'pg_ctl -D "$W/pg" stop -m immediate >/dev/null 2>&1; rm -rf "$W"' EXIT
P="psql -h $S -p $PORT -U postgres -X -q -v ON_ERROR_STOP=1"
createdb -h "$S" -p "$PORT" -U postgres src
$P -d src <<'SQL'
CREATE TABLE public.change_log (seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
                                table_name text NOT NULL, old jsonb, new jsonb);
CREATE TABLE public.other (id int PRIMARY KEY, v text);
INSERT INTO public.other SELECT g, 'row ' || g FROM generate_series(1, 50) g;
INSERT INTO public.change_log (table_name, old, new)
SELECT 't' || g, CASE WHEN g % 3 = 0 THEN NULL ELSE jsonb_build_object('note', E'line one\nline two\ttab \\ back') END, jsonb_build_object('g', g)
  FROM generate_series(1, 23) g;
DELETE FROM public.change_log WHERE seq IN (7, 8);   -- a gap in seq, as live has (64,239 rows over seq 1..71,494)
SQL
run() {  # $1 = fault, $2 = label
    rm -rf "$W/out"/*
    BACKUP_HOST="$S" BACKUP_PORT="$PORT" BACKUP_USER=postgres BACKUP_DB=src BACKUP_DIR="$W/out" BACKUP_MIN_BYTES=100 CHUNK_SEQ=5 BACKUP_FAULT="$1" \
        bash "$HERE/db/backup.sh" > "$W/run.log" 2>&1
    echo "BACKUP_EXIT=$?" >> "$W/run.log"
}
pass=0; fail=0
ok() { if [ "$1" = 0 ]; then echo "✓ $2"; pass=$((pass+1)); else echo "✗ $2"; fail=$((fail+1)); fi; }
# ① clean + restore
run "" clean
grep -q '^BACKUP_EXIT=0$' "$W/run.log"; ok $? "① clean run → BACKUP_EXIT=0 ($(grep -c 'CHUNK_EXIT=0' "$W/run.log") chunk(s), $(grep '核对' "$W/run.log" | sed 's/^ *//'))"
createdb -h "$S" -p "$PORT" -U postgres dst
pg_restore -h "$S" -p "$PORT" -U postgres -d dst "$W"/out/evoltrya-backup-*.dump >/dev/null 2>&1
for f in "$W"/out/evoltrya-backup-*.change_log.*.copy; do $P -d dst -c "\\copy public.change_log FROM '$f'"; done
$P -d dst -c "SELECT setval(pg_get_serial_sequence('public.change_log', 'seq'), (SELECT max(seq) FROM public.change_log))" >/dev/null
A=$($P -At -d src -c "SELECT count(*)||'|'||min(seq)||'|'||max(seq)||'|'||md5(string_agg(to_jsonb(c)::text, '|' ORDER BY seq)) FROM public.change_log c")
B=$($P -At -d dst -c "SELECT count(*)||'|'||min(seq)||'|'||max(seq)||'|'||md5(string_agg(to_jsonb(c)::text, '|' ORDER BY seq)) FROM public.change_log c")
O=$($P -At -d dst -c "SELECT count(*) FROM public.other")
[ "$A" = "$B" ] && [ "$O" = 50 ]; ok $? "① restore: change_log $B = source $A (count|min|max|md5 of every row); other table 50 rows"
$P -d dst -c "INSERT INTO public.change_log (table_name) VALUES ('after restore')" && N=$($P -At -d dst -c "SELECT max(seq) FROM public.change_log")
[ "$N" -gt "$(echo "$A" | cut -d'|' -f3)" ]; ok $? "① restore: the sequence continues above the restored max (next seq $N)"
# ② fail once → retried
run chunk1-fail-once once
grep -q '^BACKUP_EXIT=0$' "$W/run.log" && grep -q 'chunk=001.*try 2' "$W/run.log"; ok $? "② chunk 1 fails once → retried once, BACKUP_EXIT=0"
# ③ fail twice → stop
run chunk1-fail-twice twice
grep -q '^BACKUP_EXIT=1$' "$W/run.log" && grep -q '重试一次仍失败' "$W/run.log" && ! ls "$W"/out/evoltrya-backup-*.dump "$W"/out/*.copy >/dev/null 2>&1
ok $? "③ chunk 1 fails twice → BACKUP_EXIT=1, refused by name, no good-named file left"
# ④ a row lost → the count check refuses
run drop-row drop
grep -q '^BACKUP_EXIT=1$' "$W/run.log" && grep -q '各段行数合计' "$W/run.log" && ! ls "$W"/out/evoltrya-backup-*.dump >/dev/null 2>&1
ok $? "④ a row dropped from chunk 0 → the count check refuses, BACKUP_EXIT=1, no good-named dump"
echo "BACKUP_INJECTIONS pass=$pass fail=$fail"
[ "$fail" = 0 ]
