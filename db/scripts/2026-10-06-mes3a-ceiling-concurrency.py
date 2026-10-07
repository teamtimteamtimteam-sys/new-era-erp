#!/usr/bin/env python3
"""MES-3a(MES-3a Step 0 Q7):两张【同时】进来的收货,不可能都"刚好没超"库存上限 —— 一个会话里证不了,所以用两条连接证。

receipt_ceiling_check_internal 在读存量【之前】锁住执照行与那一类的上限行(FOR UPDATE)。于是:
  A 收 0.8 t(没提交)→ B 收 0.8 t 必须【等】A → A 提交 → B 按提交后的存量判:4.8 + 0.8 > 5 → STORAGE_CEILING_EXCEEDED。
注入:把两句 FOR UPDATE 拿掉 → B 不等,两边各自看见 4 t,都判"没超",都提交 → 存量 5.6 t > 5 t。注入那一格必须【红】
(也就是:两张都进来了),否则这份证明证不了锁是承重的。

★ 只对一份【从镜像重建的一次性库】跑(它会提交布景数据)—— 绝不要对着线上跑:脚本第一件事就是拒绝任何带 supabase 的 DSN。
跑法:python3 db/scripts/2026-10-06-mes3a-ceiling-concurrency.py "<一次性重建库的 DSN>"
退出码:0 = 锁着时 B 被拒、拿掉锁时两张都进来(注入红了);1 = 别的任何结果。CONC_OWN_EXIT=<n> 是最后一行。
"""
import subprocess
import sys
import time
import uuid

DSN = sys.argv[1]
if "supabase" in DSN or "pooler" in DSN:
    sys.exit("refusing: this script commits data and must only run against a throwaway rebuild")

FN = "public.receipt_ceiling_check_internal(uuid, uuid)"


def psql(sql):
    p = subprocess.run(["psql", DSN, "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"], input=sql, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"setup failed: {p.stderr}")
    return p.stdout.strip()


U = str(uuid.uuid4())
TAG = U[:8]
SETUP = f"""
BEGIN;
UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('{U}', 'conc-{TAG}@test.local', now(), now());
WITH r AS (INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('conc-{TAG}', 'c', 'c', true) RETURNING id)
INSERT INTO role_permissions (role_id, permission_code) SELECT r.id, p.code FROM r, permissions p;
INSERT INTO user_roles (user_id, role_id) SELECT '{U}', id FROM roles WHERE code = 'conc-{TAG}';
INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES ('ZZCONC-S-{TAG}', 'conc', 'SG', 'active', 'goods_supplier');
INSERT INTO nea_waste_categories (code, name_en, name_zh) VALUES ('CONC{TAG}', 'conc', 'conc');
INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code, nea_waste_category_code)
VALUES ('ZZCONC-M-{TAG}', 'conc', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction', 'CONC{TAG}');
UPDATE company_compliance SET deleted_at = now() WHERE cert_type_code = 'gwdf' AND deleted_at IS NULL;
INSERT INTO company_compliance (cert_type_code, cert_no, status, valid_from, valid_until)
VALUES ('gwdf', 'ZZ-CONC-{TAG}', 'active', CURRENT_DATE - 30, CURRENT_DATE + 30);
INSERT INTO licence_storage_limits (licence_id, category_code, limit_tonnes)
SELECT id, 'CONC{TAG}', 5 FROM company_compliance WHERE cert_no = 'ZZ-CONC-{TAG}';
COMMIT;
"""


def receipt_sql(kg):
    return (f"SELECT set_config('request.jwt.claims', '{{\"sub\":\"{U}\",\"role\":\"authenticated\"}}', false);\n"
            "SET ROLE authenticated;\n"
            f"SELECT create_inbound_batch(p_material_id => (SELECT id FROM materials WHERE code = 'ZZCONC-M-{TAG}'),"
            f" p_supplier_id => (SELECT id FROM suppliers WHERE code = 'ZZCONC-S-{TAG}'), p_quantity => {kg}, p_unit => 'kg',"
            f" p_arrival_date => CURRENT_DATE, p_source_reason_code => 'other', p_source_reason_note => 'concurrency proof') ->> 'batch_id';\n")


def on_hand():
    return psql(f"SELECT COALESCE(sum(mv.qty_delta), 0) FROM inventory_movements mv JOIN inbound_batches b ON b.id = mv.inbound_batch_id"
                f" JOIN materials m ON m.id = b.material_id WHERE m.code = 'ZZCONC-M-{TAG}';")


def race():
    """A 收 800 kg 不提交;B 收 800 kg;看 B 等没等;A 提交;回 (B 等了吗, B 的结果原文)。"""
    a = subprocess.Popen(["psql", DSN, "-X", "-q", "-At"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, bufsize=1)
    a.stdin.write("BEGIN;\n" + receipt_sql(800) + "SELECT 'A_DONE';\n")
    a.stdin.flush()
    deadline = time.time() + 30
    while time.time() < deadline:
        line = a.stdout.readline()
        if "A_DONE" in line:
            break
        if line.startswith("psql:") or "ERROR" in line:
            raise SystemExit(f"A failed: {line}")
    else:
        raise SystemExit("A never finished its receipt")
    b = subprocess.Popen(["psql", DSN, "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True)
    b.stdin.write("BEGIN;\n" + receipt_sql(800) + "COMMIT;\n")
    b.stdin.close()
    time.sleep(3)
    waited = b.poll() is None and psql(
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE '%create_inbound_batch%';") != "0"
    a.stdin.write("COMMIT;\n\\q\n")
    a.stdin.flush()
    a.wait(timeout=30)
    b.wait(timeout=60)
    out = b.stdout.read()
    return waited, b.returncode, out


bad = 0
psql(SETUP)
psql(f"BEGIN; {receipt_sql(4000)} COMMIT;")
print(f"setup: on hand {on_hand()} kg against a 5 t ceiling")

waited, rc, out = race()
print(f"locked: B waited on A = {waited}; B exit {rc}; {out.strip().splitlines()[-1] if out.strip() else ''}")
if not waited or rc == 0 or "STORAGE_CEILING_EXCEEDED" not in out or on_hand() != "4800":
    print("✗ with the lock, the second receipt should wait and then be refused (on hand stays 4800)")
    bad += 1
else:
    print(f"✓ with the lock: B waited, then STORAGE_CEILING_EXCEEDED; on hand {on_hand()} kg")

# 注入:拿掉两句 FOR UPDATE —— B 不等,两张都进来
definition = psql(f"SELECT pg_get_functiondef('{FN}'::regprocedure);")
injected = definition.replace(" WHERE cc.id = v_lic FOR UPDATE;", " WHERE cc.id = v_lic;") \
                     .replace("WHERE l.licence_id = v_lic AND l.category_code = v_cat FOR UPDATE;", "WHERE l.licence_id = v_lic AND l.category_code = v_cat;")
if injected == definition:
    print("✗ INJECTION_DID_NOT_APPLY: no FOR UPDATE found")
    bad += 1
else:
    psql(injected + ";")
    # 4.8 t 在手,上限调到 5.7 t:A 与 B 各收 0.8 t。锁着时后到的那一张看见 5.6 t + 0.8 t > 5.7 t 被拒;
    # 不锁时两边各自看见 4.8 t + 0.8 t = 5.6 t ≤ 5.7 t,都判"没超",都提交 —— 6.4 t。
    psql(f"UPDATE licence_storage_limits SET limit_tonnes = 5.7 WHERE category_code = 'CONC{TAG}';")
    waited2, rc2, out2 = race()
    print(f"unlocked (injected): B waited = {waited2}; B exit {rc2}; on hand {on_hand()} kg against 5.7 t")
    if rc2 == 0 and on_hand() == "6400":
        print("✓ injection is red: without the lock both receipts slipped under (6.4 t against a 5.7 t ceiling)")
    else:
        print("✗ the injection did not bite — the lock is not what keeps the second receipt out")
        bad += 1
    psql(definition + ";")

print(f"CONC_OWN_EXIT={1 if bad else 0}")
sys.exit(1 if bad else 0)
