#!/usr/bin/env python3
# db/scripts/2026-09-29-at1a-fixture236-injections.py
# AUDIT-TRAIL-1a:fixture 236 的故障注入矩阵 —— 每一格在 fixture 自己的事务里 CREATE OR REPLACE 一支函数(随 fixture 一起回滚),
#   然后断言 fixture 红在【它针对的那一臂】。对着一个【本地重建库】跑,不碰线上:
#   python3 db/scripts/2026-09-29-at1a-fixture236-injections.py            (DSN 见下面 DSN 一行,改成你的本地重建库)
#   python3 db/scripts/2026-09-29-at1a-fixture236-injections.py P3 R2     只跑点名的几格
# 2026-09-29 实测:30 格全部红在各自那一臂(ALL_TARGETED);不注入时 fixture 236 全部通过。
import subprocess, re, sys, pathlib
ROOT = pathlib.Path('.')
FIX = (ROOT / 'db/fixtures/236-a-record-shows-its-own-trail-and-nothing-else.sql').read_text()
def fn(name): return (ROOT / f'db/functions/{name}.sql').read_text()
def repl(name, old, new):
    src = fn(name)
    assert old in src, (name, old)
    return src.replace(old, new, 1)
CASES = [
  ('P11', 'approval decisions are no longer part of a purchase order', repl('trail_subject_members', "        ('purchase_order', 7, 'approval_log',", "        ('purchase_order_x', 7, 'approval_log',")),
  ('W1', 'processing rows grouped by row, not by transaction', repl('record_trail', "SELECT c.seq AS a_seq, c.occurred_at AS a_at, 'L' || c.txid AS a_g", "SELECT c.seq AS a_seq, c.occurred_at AS a_at, 'L' || CASE WHEN c.table_name LIKE 'processing%' THEN c.seq ELSE c.txid END AS a_g")),
  ('W2', 'edits to the processing record itself are dropped', repl('record_trail', 'FROM k JOIN change_log c ON c.table_name = k.t AND c.row_key = k.k' + chr(10), 'FROM k JOIN change_log c ON c.table_name = k.t AND c.row_key = k.k AND NOT (k.t = ' + chr(39) + 'processing_runs' + chr(39) + ' AND c.op = ' + chr(39) + 'UPDATE' + chr(39) + ')' + chr(10))),
  ('W3', 'cost entry history is no longer part of a processing run', repl('trail_subject_members', "        ('processing_run', 4, 'processing_cost_entry_history',", "        ('processing_run_x', 4, 'processing_cost_entry_history',")),
  ('W4', 'the two halves of an allocation split into two entries', repl('record_trail', "SELECT c.seq AS a_seq, c.occurred_at AS a_at, 'L' || c.txid AS a_g", "SELECT c.seq AS a_seq, c.occurred_at AS a_at, 'L' || c.txid || CASE WHEN c.op = 'UPDATE' AND c.table_name LIKE 'processing%' THEN c.table_name ELSE '' END AS a_g")),
  ('L2', 'edits to the role itself are dropped', repl('record_trail', 'FROM k JOIN change_log c ON c.table_name = k.t AND c.row_key = k.k' + chr(10), 'FROM k JOIN change_log c ON c.table_name = k.t AND c.row_key = k.k AND NOT (k.t = ' + chr(39) + 'roles' + chr(39) + ' AND c.op = ' + chr(39) + 'UPDATE' + chr(39) + ')' + chr(10))),
  ('P1', 'record_trail groups by row, not by transaction', repl('record_trail', "SELECT c.seq AS a_seq, c.occurred_at AS a_at, 'L' || c.txid AS a_g", "SELECT c.seq AS a_seq, c.occurred_at AS a_at, 'L' || c.seq AS a_g")),
  ('P2', 'trail_actor names people by legal name first', repl('trail_actor', "'name', COALESCE(NULLIF(v_emp ->> 'preferred_name', ''), v_emp ->> 'legal_name'));", "'name', v_emp ->> 'legal_name');")),
  ('P3', 'child edits whose image lacks the parent key are dropped', repl('record_trail', 'FROM k JOIN change_log c ON c.table_name = k.t AND c.row_key = k.k' + chr(10), 'FROM k JOIN change_log c ON c.table_name = k.t AND c.row_key = k.k AND (k.i = 1 OR c.op <> ' + chr(39) + 'UPDATE' + chr(39) + ')' + chr(10))),
  ('P8b', 'live-row child discovery switched off (caught by P8: pre-log rows exist only live)', repl('record_trail', "INTO v_found USING v_pids, m.match;", "INTO v_found USING ARRAY[]::text[], m.match;")),
  ('P4', 'no-session writes read as removed', repl('trail_actor', "RETURN jsonb_build_object('state', 'system');", "RETURN jsonb_build_object('state', 'removed');")),
  ('P5', 'a vanished account reads as unlinked', repl('trail_actor', "CASE WHEN EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_account) THEN 'unlinked' ELSE 'removed' END", "'unlinked'")),
  ('P6', 'deleted references lose their last image', repl('trail_ref_label', "AND c.op IN ('INSERT', 'DELETE')\n         ORDER BY c.seq DESC LIMIT 1;\n        IF v_img IS NULL THEN", "AND false\n         ORDER BY c.seq DESC LIMIT 1;\n        IF v_img IS NULL THEN")),
  ('P7', 'log-image child discovery switched off', repl('record_trail', "JOIN change_log c ON c.table_name = m.table_name\n                           AND (COALESCE", "JOIN change_log c ON false AND c.table_name = m.table_name\n                           AND (COALESCE")),
  ('P8', 'pre-log rows no longer skip what the log already holds', repl('record_trail', "                CONTINUE WHEN EXISTS (SELECT 1 FROM change_log c\n                                       WHERE c.table_name = v_tabs[i] AND c.row_key = v_keys[i] AND c.op = 'INSERT');\n", "")),
  ('P9', 'masking step returns images unmasked', repl('change_log_mask_row', "    IF cardinality(v_hidden) > 0 THEN", "    IF false THEN")),
  ('P10', 'every child row counts as readable', repl('trail_row_visible', "    IF NOT FOUND OR p_key IS NULL THEN\n        RETURN false;\n    END IF;", "    RETURN true;")),
  ('P12', 'live-row discovery ignores the parent', repl('record_trail', "FROM public.%I t WHERE t.%I::text = ANY ($1) AND to_jsonb(t) @> $2',", "FROM public.%I t WHERE (t.%I::text = ANY ($1) OR true) AND to_jsonb(t) @> $2',")),
  ('P13', 'paging ignores p_entries', repl('record_trail', "v_limit  integer := LEAST(GREATEST(COALESCE(p_entries, 20), 1), 500);", "v_limit  integer := 500;")),
  ('R1', 'unknown subject no longer refused', repl('record_trail', "    IF NOT FOUND THEN\n        RAISE EXCEPTION 'TRAIL_SUBJECT_UNKNOWN|%', COALESCE(p_subject, '');\n    END IF;", "    IF NOT FOUND THEN\n        RETURN;\n    END IF;")),
  ('R2', 'view code not checked', repl('record_trail', "    IF NOT has_permission(s.view_code) THEN", "    IF false THEN")),
  ('R3', 'missing root returns an empty list', repl('record_trail', "    IF v_img.image IS NULL OR NOT trail_row_visible(s.root_table, v_root, v_img.image) THEN\n        RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;", "    IF v_img.image IS NULL THEN\n        RETURN;\n    END IF;\n    IF NOT trail_row_visible(s.root_table, v_root, v_img.image) THEN\n        RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;")),
  ('W5', 'processing tables skip masking', repl('change_log_mask_row', "    FOR m IN SELECT mr.column_name AS m_col, mr.rule AS m_rule\n               FROM change_log_mask_rules() mr WHERE mr.table_name = p_table LOOP", "    FOR m IN SELECT mr.column_name AS m_col, mr.rule AS m_rule\n               FROM change_log_mask_rules() mr WHERE mr.table_name = p_table AND p_table NOT LIKE 'processing%' LOOP")),
  ('L1', 'permissions resolve to their code, not their name', repl('trail_ref_label', "        WHEN v_img ? 'name_en' THEN v_img ->> 'name_en'", "        WHEN p_table = 'permissions' THEN v_img ->> 'code'\n        WHEN v_img ? 'name_en' THEN v_img ->> 'name_en'")),
  ('L3', 'role grants have no pre-log source', repl('trail_prelog_sources', "        ('role_permissions',               'created', 'created_at',   'created_by',   NULL)", "        ('role_permissions_x',             'created', 'created_at',   'created_by',   NULL)")),
  ('R2b', 'role trail readable without action.manage_permissions', repl('trail_subjects', "('role',           'action.manage_permissions', 'roles',           'id')", "('role',           'module.purchasing.view', 'roles',           'id')")),
  ('S1', 'summary paging counts rows, not operations', repl('change_log_rows', "    IF COALESCE(p_by_entry, false) THEN\n        SELECT array_agg", "    IF false THEN\n        SELECT array_agg")),
  ('S2', 'a line no longer belongs to its purchase order', repl('trail_row_record', "            EXIT WHEN NOT FOUND OR v_hops >= 3 OR v_img ->> m.fk_column IS NULL;", "            EXIT;")),
  ('S3', 'record search finds nothing', repl('change_log_find_records', "    IF length(v_q) < 2 THEN", "    IF true THEN")),
  ('S4', 'summary reader skips the shared masking step', repl('change_log_rows', "        v_mask := change_log_mask_row(r.c_table, r.c_key, r.c_old, r.c_new);", "        v_mask := jsonb_build_object('old', r.c_old, 'new', r.c_new, 'row_restricted', false);")),
]
DSN = "host=/tmp/at1s port=55436 user=postgres dbname=scratch2"
only = sys.argv[1:]
res = []
for arm, what, sql in CASES:
    if only and arm not in only: continue
    body = FIX.replace("SET LOCAL statement_timeout = '240s';", "SET LOCAL statement_timeout = '240s';\n-- ★ INJECTION " + arm + "\n" + sql + "\n", 1)
    p = subprocess.run(['psql', DSN, '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-f', '-'], input=body, capture_output=True, text=True)
    m = re.search(r'FIXTURE 236([A-Z]\d+)', p.stderr)
    got = m.group(1) if m else ('GREEN' if p.returncode == 0 else 'ERR:' + p.stderr.strip().splitlines()[-1][:120] if p.stderr.strip() else 'ERR')
    ok = got == arm.rstrip('b')
    res.append((arm, what, p.returncode, got, ok))
    print(f"{arm:4} {'✓' if ok else '✗'} exit={p.returncode} red-in={got:5}  — {what}")
print('ALL_TARGETED' if all(r[4] for r in res) else 'SOME_MISSED')
