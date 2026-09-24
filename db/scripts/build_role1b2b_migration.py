#!/usr/bin/env python3
"""ROLE-1 Batch 2b:从镜像拼出迁移文件。理由与 Batch 2a / PRICE-1 / CONTRACT-1 的拼装脚本同一条 ——
镜像是真源,迁移是它的一次投影;手抄两份迟早各说各话。每一条策略与触发器都从镜像里【原样抽出】,
所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_role1b2b_migration.py(在仓库根目录)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-24-role1b2b-contracts-prices-direct-sale-and-assay.sql"

NEW_CODES = ["action.contract_terms", "action.metal_prices", "action.direct_sale", "action.apply_assay"]
B2A_CODES = ["action.finance_settings", "action.customer_credit", "action.supplier_approve"]


def fn(name):
    return (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"


def mirror(table):
    return (ROOT / f"db/tables/{table}.sql").read_text()


def stmt(table, head):
    """从镜像里抽出以 head 开头、到下一个分号为止的那一句(策略与触发器里没有分号)。"""
    s = mirror(table)
    i = s.index(head)
    j = s.index(";", i)
    assert s.count(head) == 1, (table, head)
    return s[i:j + 1] + "\n"


def policy(table, name):
    return f'DROP POLICY "{name}" ON public.{table};\n' + stmt(table, f'CREATE POLICY "{name}"')


def trigger(table, name, drop=None):
    out = f"DROP TRIGGER {drop} ON public.{table};\n" if drop else ""
    return out + stmt(table, f"CREATE TRIGGER {name}\n")


HEADER = """-- db/migrations/2026-09-24-role1b2b-contracts-prices-direct-sale-and-assay.sql
-- ROLE-1 · Batch 2b —— Tim 的角色与审批矩阵(docs/role-matrix.md)第 2 批的后一半。
-- 由 db/scripts/build_role1b2b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本批做什么】(Batch 2 grilling Q12–Q15 + Batch 2b grilling Q1–Q6,Tim 全部接受)
--   ① 四个新动作码:action.contract_terms(cco)· action.metal_prices(finance)·
--      action.direct_sale(cco)· action.apply_assay(cto)。
--   ② ★ Tim 的常设裁定(2026-09-24):admin 角色持【每一个】码 —— 本刀的四个,加 Batch 2a 的三个
--      (action.finance_settings · action.customer_credit · action.supplier_approve)。幂等:
--      ON CONFLICT DO NOTHING(Tim 可能已经手工加过;Step 0 以 postgres 读基表:一个都没有)。
--      admin@ 不持 cfo 角色(那一行 revoked_at = 2026-09-23 15:00:48),本刀不碰 user_roles。
--   ③ 合同(Q12 · Q1):contracts 与七张条款表的写策略和 enforce_write_permission 从
--      module.customers.edit / module.suppliers.edit 换成 action.contract_terms。
--      link_document_to_contract 的门不变(挂单据仍归开单据的码)。
--   ④ 金属行情(Q13):metal_prices · metal_price_indices · index_market_calendar · pricing_settings
--      的写策略与触发器、upsert_metal_prices 的门,换成 action.metal_prices。定价公式仍在
--      module.pricing.edit —— 从 cto 与 finance 拿掉,只剩 cco(和 admin)。procurement / sales
--      两个无人持有的角色保留它(Q2,ROLE1B2B-UNHELD-PRICING-EDIT)。
--   ⑤ 直接销售(Q14 · Q3):record_output_sale 换成 action.direct_sale;sales_records 的
--      INSERT 与 UPDATE 两条写策略拿掉(四个写入方全是 SECURITY DEFINER);原来那支
--      enforce_write_permission('module.finance.edit') 换成 guard_sales_record_direct_write
--      (语句级,按名拒 SALE_THROUGH_FUNCTION_ONLY)。
--   ⑥ 化验(Q15 · Q4):apply_assay_result · apply_output_assay · unapply_assay_result ·
--      preview_assay_price · preview_apply_output_assay 换成 action.apply_assay;记录结果仍归
--      inbound.edit / output.edit。两扇侧门按名关:guard_assay_applied_columns
--      (ASSAY_APPLY_THROUGH_FUNCTION_ONLY)· guard_batch_metals_assay_source
--      (ASSAY_CONTENT_THROUGH_FUNCTION_ONLY)。reprice_inbound_batch 里那道嵌套的
--      inbound.edit 检查不拆(cto 持有它;登记在 Batch 4)。reprice_from_committed_terms
--      与它的预览不动(Q6,Batch 4)。
--
-- 【不做什么】审批开关与策略一个字都不碰。不动任何决定函数的门。不写任何业务行。
--
-- 【RUNTIME CONFIG 的引导默认值,照 AGENTS.md 那条规矩说清楚】
--   · role_permissions 的引导【改了】:finance 的 module.pricing.edit 换成 action.metal_prices ——
--     仍是它原来的意思(全新安装的起点)。cco / cto / cfo 仍不在引导里
--     (ROLE1-BOOTSTRAP-MISSING-ROLES),所以 contract_terms / direct_sale / apply_assay 在全新
--     安装里只有 admin 之外无人持有 —— 与 Batch 1、2a 的新码同一个处境。引导里的 admin 仍是
--     "只做系统管理";线上 admin 持全部码是 Tim 为测试做的裁定,不是全新安装的起点。
--   · permissions 是逐行比对的种子:新增四行;module.pricing.edit 与 module.output.edit 两行的
--     描述改写(不再含金属行情 / 销售),镜像同步。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;在途单据一张不少;
-- approval_log 与 journal_entries 一行没多;合同、行情、销售、化验的行数一行没变;每一个角色的码 =
-- 之前 + 本刀的授权 − 本刀的两条收回,不多不少;admin 持有每一个新码、一个旧码也没丢;每一张在途单据都还有
-- 一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;
"""

parts = [HEADER]

parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B2B_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ('action.contract_terms', 'action.metal_prices',
                                                        'action.direct_sale', 'action.apply_assay')) THEN
        RAISE EXCEPTION 'ROLE1B2B_PRE|new codes already exist';
    END IF;
    IF (SELECT count(*) FROM permissions WHERE code IN ('action.finance_settings', 'action.customer_credit',
                                                         'action.supplier_approve')) <> 3 THEN
        RAISE EXCEPTION 'ROLE1B2B_PRE|Batch 2a codes are not all present';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname IN ('trg_assay_results_applied_columns',
               'trg_inbound_batch_metals_assay_source', 'trg_output_batch_metals_assay_source',
               'trg_sales_records_direct_write')) THEN
        RAISE EXCEPTION 'ROLE1B2B_PRE|a Batch 2b trigger already exists';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE b2b_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved');
CREATE TEMP TABLE b2b_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log, (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM contracts) AS contracts, (SELECT count(*) FROM metal_prices) AS metal_prices,
       (SELECT count(*) FROM metal_price_indices) AS indices, (SELECT count(*) FROM sales_records) AS sales_records,
       (SELECT count(*) FROM assay_results) AS assays,
       (SELECT count(*) FROM assay_results WHERE applied_at IS NOT NULL) AS assays_applied;
CREATE TEMP TABLE b2b_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 目录:四个新码;两个码的描述改写 ─────────────────────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
""")
perm = (ROOT / "db/tables/permissions.sql").read_text()
rows = [l for l in perm.splitlines() if l.strip().startswith(tuple(f"('{c}'" for c in NEW_CODES))]
assert len(rows) == 4, rows
parts.append("\n".join(rows).rstrip(",;") + ";\n")
for code in ["module.pricing.edit", "module.output.edit"]:
    line = [l for l in perm.splitlines() if l.strip().startswith(f"('{code}'")]
    assert len(line) == 1
    m = re.match(r"\s*\('[^']+', '[^']+', '((?:[^']|'')*)', '((?:[^']|'')*)', '((?:[^']|'')*)', '((?:[^']|'')*)', (\d+)\),?$", line[0])
    assert m, line
    parts.append(f"UPDATE public.permissions SET description_en = '{m.group(3)}', description_zh = '{m.group(4)}'\n"
                 f" WHERE code = '{code}';\n")

parts.append("\n-- ── 2 · 函数(镜像原样)──────────────────────────────────────────────────────\n")
for name in ["guard_assay_applied_columns", "guard_batch_metals_assay_source", "guard_sales_record_direct_write",
             "apply_assay_result", "apply_output_assay", "unapply_assay_result",
             "preview_assay_price", "preview_apply_output_assay", "record_output_sale", "upsert_metal_prices"]:
    body = fn(name)
    if not body.lstrip().startswith("--"):
        body = f"-- ─── {name}\n" + body
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    parts.append("\n" + body)

parts.append("\n-- ── 3 · 合同与七张条款表:写权换到 action.contract_terms(Q12 · Q1)───────────\n")
parts.append(policy("contracts", "contracts insert by owner permission"))
parts.append(policy("contracts", "contracts update by owner permission"))
parts.append(trigger("contracts", "enforce_write_permission", drop="enforce_write_permission"))
for t, pname in [("contract_grade_specs", "contract grade specs write by owner permission"),
                 ("contract_insurance_obligations", "contract insurance write by owner permission"),
                 ("contract_penalty_elements", "contract penalty elements write by owner permission"),
                 ("contract_pricing_terms", "contract pricing terms write by owner permission"),
                 ("contract_refining_charges", "contract refining charges write by owner permission"),
                 ("contract_settlement_terms", "contract settlement terms write by owner permission"),
                 ("contract_volume_commitments", "contract volume write by owner permission")]:
    parts.append(policy(t, pname))
    parts.append(trigger(t, "enforce_write_permission", drop="enforce_write_permission"))

parts.append("\n-- ── 4 · 金属行情、指数、指数交易日历、报价阈值:写权换到 action.metal_prices(Q13)──\n")
for p in ["metal_prices insert by permission", "metal_prices update by permission", "metal_prices delete by permission"]:
    parts.append(policy("metal_prices", p))
parts.append(trigger("metal_prices", "enforce_write_permission", drop="enforce_write_permission"))
parts.append(policy("metal_price_indices", "metal_price_indices write by permission"))
parts.append(trigger("metal_price_indices", "enforce_write_permission", drop="enforce_write_permission"))
parts.append(policy("index_market_calendar", "index market calendar write by pricing permission"))
parts.append(trigger("index_market_calendar", "enforce_write_permission", drop="enforce_write_permission"))
parts.append(policy("pricing_settings", "pricing_settings update by permission"))
parts.append(trigger("pricing_settings", "enforce_write_permission", drop="enforce_write_permission"))

parts.append("""
-- ── 5 · sales_records:没有直连写(Q14 · Q3)────────────────────────────────────
DROP POLICY "sales_records insert by permission" ON public.sales_records;
DROP POLICY "sales_records update by permission" ON public.sales_records;
""")
parts.append(trigger("sales_records", "trg_sales_records_direct_write", drop="enforce_write_permission"))

parts.append("\n-- ── 6 · 化验的两扇侧门(Q4)────────────────────────────────────────────────\n")
parts.append(trigger("assay_results", "trg_assay_results_applied_columns"))
parts.append(trigger("inbound_batch_metals", "trg_inbound_batch_metals_assay_source"))
parts.append(trigger("output_batch_metals", "trg_output_batch_metals_assay_source"))

parts.append("""
-- ── 7 · 授权 ─────────────────────────────────────────────────────────────────
-- cco:合同条款与直接销售;finance:金属行情(交出 pricing.edit);cto:应用化验(交出 pricing.edit)。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, g.c FROM roles r
  JOIN (VALUES ('cco', 'action.contract_terms'), ('cco', 'action.direct_sale'),
               ('finance', 'action.metal_prices'), ('cto', 'action.apply_assay')) g(role_code, c)
    ON g.role_code = r.code;
DELETE FROM role_permissions rp USING roles r
 WHERE r.id = rp.role_id AND r.code IN ('finance', 'cto') AND rp.permission_code = 'module.pricing.edit';
-- admin:Tim 的常设裁定 —— 持每一个码,含本刀四个与 Batch 2a 三个。幂等。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, c FROM roles r
 CROSS JOIN unnest(ARRAY['action.contract_terms', 'action.metal_prices', 'action.direct_sale', 'action.apply_assay',
                         'action.finance_settings', 'action.customer_credit', 'action.supplier_approve']) c
 WHERE r.code = 'admin'
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

b1 = (ROOT / "db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql").read_text()
start = b1.index("CREATE FUNCTION pg_temp.role1_pending_decider_check")
dec = b1[start:b1.index("$f$;", start) + 4].replace("role1_pending_decider_check", "b2b_pending_decider_check")
parts.append("""
-- ── 8 · 每一张在途单据,有几个【不是它自己当事人】的人决定得了它 ──────────────
-- 零件与 ROLE-1 Batch 1 / 2a 的自证逐字相同(按【人】数,Tim 的两个账号只算一个);本刀没有改动
-- 任何一支决定函数的门,所以用"之后"那一组门问。
""")
parts.append(dec + "\n")

parts.append("""
CREATE TEMP TABLE b2b_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved');

-- ── 9 · 自证:同一笔事务里,失败即整笔回滚 ────────────────────────────────────
DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
    v_admin_2a int;
BEGIN
    -- ① 授权 = 之前 + 本刀的授权 − 两条收回,不多不少
    --    (admin 的 Batch 2a 三码是否新加,取决于 Tim 有没有手工加过:两种都接受)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT
         SELECT role_code || ':' || permission_code FROM b2b_grants_before)
        EXCEPT
        SELECT unnest(ARRAY['cco:action.contract_terms', 'cco:action.direct_sale', 'finance:action.metal_prices',
                            'cto:action.apply_assay',
                            'admin:action.contract_terms', 'admin:action.metal_prices', 'admin:action.direct_sale',
                            'admin:action.apply_assay', 'admin:action.finance_settings', 'admin:action.customer_credit',
                            'admin:action.supplier_approve'])
    ) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B2B_PROOF|unexpected grant: %', v_bad; END IF;
    SELECT count(*) INTO v_admin_2a FROM b2b_grants_before
     WHERE role_code = 'admin' AND permission_code IN ('action.finance_settings', 'action.customer_credit',
                                                       'action.supplier_approve');
    SELECT count(*) INTO v_n FROM (
        SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
        EXCEPT SELECT role_code || ':' || permission_code FROM b2b_grants_before) d;
    IF v_n <> 8 + (3 - v_admin_2a) THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|expected % new grants, got %', 8 + (3 - v_admin_2a), v_n;
    END IF;
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        SELECT role_code || ':' || permission_code AS x FROM b2b_grants_before
        EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id) d;
    IF v_bad IS DISTINCT FROM 'cto:module.pricing.edit, finance:module.pricing.edit' THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|removed grants are not exactly the two pricing.edit: %', v_bad;
    END IF;

    -- ② admin 缺的码只可能是它本来就缺的(Tim 的常设裁定:admin【保留】它的全部码,并拿到每一个
    --    新码)。试跑量到:admin 从来没有 module.tasks.view_all(读别人的个人任务;Tim 2026-09-23
    --    23:33 还回去的 45 个码里就没有它)—— 本刀不替 Tim 加它,只断言它没有再多缺一个。
    SELECT string_agg(p.code, ', ' ORDER BY p.code) INTO v_bad FROM permissions p
     WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                        WHERE r.code = 'admin' AND rp.permission_code = p.code)
       AND (p.code IN ('action.contract_terms', 'action.metal_prices', 'action.direct_sale', 'action.apply_assay',
                       'action.finance_settings', 'action.customer_credit', 'action.supplier_approve')
            OR EXISTS (SELECT 1 FROM b2b_grants_before b WHERE b.role_code = 'admin' AND b.permission_code = p.code));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B2B_PROOF|admin lacks: %', v_bad; END IF;

    -- ③ 定价公式只剩 cco 与 admin(加两个无人持有的角色,Q2)
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'module.pricing.edit';
    IF v_bad IS DISTINCT FROM 'admin cco procurement sales' THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|pricing.edit holders are %', v_bad;
    END IF;

    -- ④ edit 蕴含 view
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code LIKE 'module.%.edit'
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id
                        AND v.permission_code = replace(rp.permission_code, '.edit', '.view'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B2B_PROOF|edit without view: %', v_bad; END IF;

    -- ⑤ 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|approvals switched off';
    END IF;

    -- ⑥ 在途单据一张不少、一张不多;留痕与分录一行没多;业务行一行没变
    IF EXISTS ((SELECT b.k, b.id FROM b2b_pending_before b EXCEPT SELECT a.k, a.id FROM b2b_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM b2b_pending_after a EXCEPT SELECT b.k, b.id FROM b2b_pending_before b)) THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|a pending document changed state';
    END IF;
    IF (SELECT (approval_log, journal_entries, contracts, metal_prices, indices, sales_records, assays, assays_applied)
          FROM b2b_counts_before)
       IS DISTINCT FROM
       (SELECT ((SELECT count(*) FROM approval_log), (SELECT count(*) FROM journal_entries),
                (SELECT count(*) FROM contracts), (SELECT count(*) FROM metal_prices),
                (SELECT count(*) FROM metal_price_indices), (SELECT count(*) FROM sales_records),
                (SELECT count(*) FROM assay_results),
                (SELECT count(*) FROM assay_results WHERE applied_at IS NOT NULL))) THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|a business row count changed';
    END IF;

    -- ⑦ sales_records 不再有任何写策略
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'sales_records'
                AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|sales_records still has a write policy';
    END IF;

    -- ⑧ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.b2b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ROLE1B2B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.b2b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.b2b_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.b2b_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
