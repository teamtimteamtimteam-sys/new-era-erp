#!/usr/bin/env python3
"""ROLE-1 Batch 4a:从镜像拼出迁移文件。理由与 Batch 2a / 2b / PAYROLL-APR-1 的拼装脚本同一条 ——
镜像是真源,迁移是它的一次投影;手抄两份迟早各说各话。函数、视图、策略都从镜像里【原样抽出】,
所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_role1b4a_migration.py(在仓库根目录)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-25-role1b4a-purchase-prices-and-who-prices-a-receipt.sql"

NEW_CODES = ["data.view_purchase_prices", "action.price_receipts"]

# 采购那一侧的视图(遮蔽码换成 data.view_purchase_prices)+ 按行遮的三张公式视图 + 按事件分的审计轨迹
VIEWS = ["purchase_orders_masked", "purchase_order_lines_masked", "purchase_order_payment_terms_masked",
         "payment_term_template_lines_masked", "purchase_order_line_retentions_masked",
         "purchase_order_retention_status", "pricing_term_commitments_masked",
         "pricing_term_commitment_metals_masked", "inbound_batches_masked", "inbound_batch_lookup",
         "price_history_masked", "prepayment_applications_masked",
         "pricing_formulas_masked", "pricing_formula_metals_masked", "pricing_formula_history_masked",
         "batch_audit_trail"]

FUNCTIONS = ["calculate_metal_price", "approve_purchase_order", "preview_reprice_inbound_batch", "ap_aging_asof",
             "approval_chain_gates", "role_can_see_amounts", "list_ledger_reconciliation", "po_document_data",
             "reprice_inbound_batch", "set_inbound_unit_price", "reprice_from_committed_terms",
             "preview_reprice_from_committed_terms", "create_inbound_batch", "reverse_journal_entry"]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.lstrip().startswith("--"):
        body = f"-- ─── {name}\n" + body
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def view(name):
    s = (ROOT / f"db/views/{name}.sql").read_text()
    head = f"CREATE VIEW public.{name} "
    assert s.count(head) == 1, name
    body = s[s.index(head):].rstrip("\n") + "\n"
    return f"\n-- ─── view {name}\n" + body.replace(head, f"CREATE OR REPLACE VIEW public.{name} ", 1)


HEADER = """-- db/migrations/2026-09-25-role1b4a-purchase-prices-and-who-prices-a-receipt.sql
-- ROLE-1 · Batch 4a —— 采购价可见性(Tim 的 Q9 线)与"看不见价格的人不能定价"(docs/role-matrix.md §8 · §13)。
-- 由 db/scripts/build_role1b4a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Batch 4 grilling Q1 · Q7 · Q9–Q12,Tim 2026-09-25 全部接受;Q13:两刀,本刀是 4a)
--   ① 两个新码:data.view_purchase_prices —— 今天持 data.view_prices 的每一个角色一并拿到它,
--      仓库只拿它;action.price_receipts —— 财务。★ 两个都一并授给 admin(Tim 的常设裁定)。
--   ② 采购那一侧的十二张遮蔽视图换码;三张定价公式视图按【行】遮(sale → view_prices,
--      purchase / both → view_purchase_prices,判据一支 pricing_formula_terms_visible);
--      batch_audit_trail 的 amount_restricted 按事件问码;ap_aging_asof · approve_purchase_order ·
--      preview_reprice_inbound_batch · calculate_metal_price(按公式方向)换码;approval_chain_gates 的
--      采购单批准两行换码;role_can_see_amounts 要两个码都有;list_ledger_reconciliation 按边问码
--      (AP → 采购码,AR 不动);po_document_data 自己按采购码置空价格(关 ROLE1-PO-DOCUMENT-DATA-PRICES)。
--      inbound_batches_masked 与 prepayment_applications_masked【一起】搬(不然 ap_open_items 会把
--      一笔被遮的预付当成 0,多报应付)。
--   ③ 收货定价归财务,而且在库里挡"看不见价格的人不能定价"(Q1 · Q4):set_inbound_unit_price ·
--      reprice_from_committed_terms 与其试算 · create_inbound_batch【带价时】要 action.price_receipts +
--      data.view_purchase_prices;引擎 reprice_inbound_batch 拆掉嵌套的 module.inbound.edit,改问
--      data.view_purchase_prices(所以应用化验也要看得见采购价)。
--   ④ 三扇侧门(Q7 (a)–(c)):price_history 的 INSERT 策略拿掉;reverse_journal_entry 按名拒 purchase
--      分录(JE_REVERSE_USE_SOURCE_PATH);reprice_inbound_batch 的 EXECUTE 从 authenticated 收回。
--
-- 【不做什么】审批开关与策略一个字都不碰;不写任何业务行;不新增审批链(收货定价审批是 Batch 4b)。
-- ★ 两刀之间(本刀上线到 4b 上线):财务定价仍一步生效、不经 CFO 批准 —— 矩阵惯常的 [LC] 过渡期。
--
-- 【RUNTIME CONFIG 的引导默认值】role_permissions 的引导【改了】:五个持 data.view_prices 的引导角色
--   (gm · finance · procurement · sales · auditor)加 data.view_purchase_prices;warehouse 加它;
--   finance 加 action.price_receipts。permissions 是逐行比对的种子:新增两行,data.view_prices 的名字与
--   描述改写(从此只说销售与成本那一侧)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;在途单据一张不少、一张不多;
-- approval_log、journal_entries、price_history、收货单一行没变;授权 = 之前 + 本刀的授权,不多不少、一条没收;
-- 持 view_prices 的角色每一个都持 view_purchase_prices;admin 持两个新码;采购单批准两级仍各有一个
-- 真的决定人;每一张在途单据都还有一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = """SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')"""

parts = [HEADER]
parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B4A_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ('data.view_purchase_prices', 'action.price_receipts')) THEN
        RAISE EXCEPTION 'ROLE1B4A_PRE|new codes already exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'price_history'
                    AND policyname = 'price_history insert by permission') THEN
        RAISE EXCEPTION 'ROLE1B4A_PRE|price_history insert policy is not there to drop';
    END IF;
    IF to_regprocedure('public.pricing_formula_terms_visible(text)') IS NOT NULL THEN
        RAISE EXCEPTION 'ROLE1B4A_PRE|pricing_formula_terms_visible already exists';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE b4a_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE b4a_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log, (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM price_history) AS price_history, (SELECT count(*) FROM inbound_batches) AS receipts,
       (SELECT count(*) FROM inbound_batches WHERE unit_price IS NOT NULL) AS receipts_priced;
CREATE TEMP TABLE b4a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 目录:两个新码;data.view_prices 的名字与描述改写 ────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
""")
perm = (ROOT / "db/tables/permissions.sql").read_text()
rows = [l.strip().rstrip(",;") for l in perm.splitlines() if l.strip().startswith(tuple(f"('{c}'" for c in NEW_CODES))]
assert len(rows) == 2, rows
parts.append("    " + ",\n    ".join(rows) + ";\n")
line = [l for l in perm.splitlines() if l.strip().startswith("('data.view_prices'")]
assert len(line) == 1
m = re.match(r"\s*\('[^']+', '[^']+', '((?:[^']|'')*)', '((?:[^']|'')*)', '((?:[^']|'')*)', '((?:[^']|'')*)', (\d+)\),?$", line[0])
assert m, line
parts.append(f"UPDATE public.permissions SET name_en = '{m.group(1)}', name_zh = '{m.group(2)}',\n"
             f"       description_en = '{m.group(3)}', description_zh = '{m.group(4)}'\n"
             f" WHERE code = 'data.view_prices';\n")

parts.append("""
-- ── 2 · 授权(在函数与视图之前:下面的自证与视图都要问到它们)─────────────────
-- 今天持 data.view_prices 的每一个角色一并拿到采购码(谁都不少看一格);仓库只拿采购码。
INSERT INTO role_permissions (role_id, permission_code)
SELECT DISTINCT rp.role_id, 'data.view_purchase_prices' FROM role_permissions rp
 WHERE rp.permission_code = 'data.view_prices'
ON CONFLICT (role_id, permission_code) DO NOTHING;
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, g.c FROM roles r
  JOIN (VALUES ('warehouse', 'data.view_purchase_prices'), ('finance', 'action.price_receipts')) g(role_code, c)
    ON g.role_code = r.code
ON CONFLICT (role_id, permission_code) DO NOTHING;
-- admin:Tim 的常设裁定 —— 持每一个码,含本刀两个。幂等。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, c FROM roles r
 CROSS JOIN unnest(ARRAY['data.view_purchase_prices', 'action.price_receipts']) c
 WHERE r.code = 'admin'
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

parts.append("\n-- ── 3 · 公式条款按行遮的那一支判据(新)─────────────────────────────────────\n")
parts.append(fn("pricing_formula_terms_visible"))
parts.append("\n-- ── 4 · 视图(镜像原样;列不变,所以 CREATE OR REPLACE)──────────────────────\n")
for v in VIEWS:
    parts.append(view(v))
parts.append("\n-- ── 5 · 函数(镜像原样)──────────────────────────────────────────────────────\n")
for f in FUNCTIONS:
    parts.append(fn(f))

parts.append("""
-- ── 6 · 侧门 (a):price_history 不再接受直连插入 ──────────────────────────────
DROP POLICY "price_history insert by permission" ON public.price_history;

-- ── 7 · 侧门 (c):定价引擎只经门进来 ─────────────────────────────────────────
REVOKE EXECUTE ON FUNCTION public.reprice_inbound_batch(uuid, numeric, text, numeric, text) FROM authenticated;
""")

b1 = (ROOT / "db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql").read_text()
start = b1.index("CREATE FUNCTION pg_temp.role1_pending_decider_check")
dec = b1[start:b1.index("$f$;", start) + 4].replace("role1_pending_decider_check", "b4a_pending_decider_check")
parts.append("\n-- ── 8 · 自证 ──────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE b4a_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad       text;
    v_n         int;
    v_expected  int;
    k           text;
BEGIN
    -- ① 授权 = 之前 + 本刀的授权,不多不少;一条没收
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
        EXCEPT SELECT role_code || ':' || permission_code FROM b4a_grants_before
        EXCEPT SELECT role_code || ':data.view_purchase_prices' FROM b4a_grants_before
                WHERE permission_code = 'data.view_prices'
        EXCEPT SELECT unnest(ARRAY['warehouse:data.view_purchase_prices', 'finance:action.price_receipts',
                                   'admin:data.view_purchase_prices', 'admin:action.price_receipts'])) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B4A_PROOF|unexpected grant: %', v_bad; END IF;
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        SELECT role_code || ':' || permission_code AS x FROM b4a_grants_before
        EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B4A_PROOF|a grant was removed: %', v_bad; END IF;
    SELECT count(DISTINCT role_code) + 2 INTO v_expected FROM b4a_grants_before
     WHERE permission_code = 'data.view_prices' OR role_code IN ('warehouse', 'admin');
    SELECT count(*) INTO v_n FROM role_permissions rp WHERE rp.permission_code IN ('data.view_purchase_prices',
                                                                                    'action.price_receipts');
    IF v_n <> v_expected THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|expected % new-code grants, got %', v_expected, v_n;
    END IF;

    -- ② 谁都不少看一格:持 view_prices 的每一个角色都持采购码;仓库持采购码、不持 view_prices;
    --    action.price_receipts 只在 finance 与 admin
    SELECT string_agg(r.code, ', ') INTO v_bad FROM roles r
     WHERE EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id AND rp.permission_code = 'data.view_prices')
       AND NOT EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id
                        AND rp.permission_code = 'data.view_purchase_prices');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B4A_PROOF|holds view_prices without the purchase code: %', v_bad; END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                WHERE r.code = 'warehouse' AND rp.permission_code = 'data.view_prices')
       OR NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                       WHERE r.code = 'warehouse' AND rp.permission_code = 'data.view_purchase_prices') THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|warehouse price codes are not purchase-only';
    END IF;
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.price_receipts';
    IF v_bad IS DISTINCT FROM 'admin finance' THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|price_receipts holders are %', v_bad;
    END IF;

    -- ③ 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|approvals switched off';
    END IF;

    -- ④ 在途单据一张不少、一张不多;留痕、分录、改价历史、收货单一行没变
    IF EXISTS ((SELECT b.k, b.id FROM b4a_pending_before b EXCEPT SELECT a.k, a.id FROM b4a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM b4a_pending_after a EXCEPT SELECT b.k, b.id FROM b4a_pending_before b)) THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|a pending document changed state';
    END IF;
    IF (SELECT (approval_log, journal_entries, price_history, receipts, receipts_priced) FROM b4a_counts_before)
       IS DISTINCT FROM
       (SELECT ((SELECT count(*) FROM approval_log), (SELECT count(*) FROM journal_entries),
                (SELECT count(*) FROM price_history), (SELECT count(*) FROM inbound_batches),
                (SELECT count(*) FROM inbound_batches WHERE unit_price IS NOT NULL))) THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|a business row count changed';
    END IF;

    -- ⑤ 结构:三扇侧门关上
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'price_history'
                AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|price_history still has a write policy';
    END IF;
    IF has_function_privilege('authenticated', 'public.reprice_inbound_batch(uuid, numeric, text, numeric, text)',
                              'EXECUTE') THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|authenticated can still execute reprice_inbound_batch';
    END IF;
    IF (SELECT array_agg(DISTINCT g ORDER BY g) FROM approval_chain_gates() c, unnest(c.gate_permissions) g
         WHERE c.action_function = 'approve_purchase_order')
       IS DISTINCT FROM ARRAY['data.view_purchase_prices', 'module.purchasing.view']::text[] THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|approve_purchase_order gate row';
    END IF;

    -- ⑥ 采购单批准的两级此刻都有人批得了(开着的审批不许因为换码而变成"开着却没人能批")
    FOR v_n IN 1..2 LOOP
        IF (SELECT count(*) FROM approval_deciders('purchase_order', 'approve_purchase_order', v_n::smallint,
                NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
                (SELECT approval_level2_role_code FROM finance_settings))) = 0 THEN
            RAISE EXCEPTION 'ROLE1B4A_PROOF|nobody can approve a level-% purchase order', v_n;
        END IF;
    END LOOP;

    -- ⑦ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.b4a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ROLE1B4A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.b4a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.b4a_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.b4a_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
