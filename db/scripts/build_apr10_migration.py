#!/usr/bin/env python3
"""APR-10:从镜像拼出迁移文件(形状照 build_apr9_migration.py)。镜像是真源,迁移是它的一次投影 ——
函数、表、策略、触发器、视图都从镜像里【原样抽出】,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_apr10_migration.py(在仓库根目录)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql"


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.lstrip().startswith("--"):
        body = f"-- ─── {name}\n" + body
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


def stmt(path, head):
    """从镜像里抽出以 head 开头、到【语句真正的结尾】为止的那一句(跳过 -- 注释与单引号字符串)。"""
    s = mirror(path)
    assert s.count(head) == 1, (path, head)
    i = s.index(head)
    k = i
    while True:
        c = s[k]
        if s.startswith("--", k):
            k = s.index("\n", k)
        elif c == "'":
            k = s.index("'", k + 1)
            while s.startswith("''", k):
                k = s.index("'", k + 2)
        elif c == ";":
            return s[i:k + 1] + "\n"
        k += 1


HEADER = """-- db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql
-- APR-10 —— GST 申报等 CFO 批数字;采购单按品类开、按开单人或这一类的码改
-- (docs/role-matrix.md §2「GST 申报与更正 | 财务 | CFO」·§6「开采购单,按品类」「修改、取消、关闭采购单」)。
-- 由 db/scripts/build_apr10_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(APR-10 grilling Q1–Q9,Tim 2026-09-27:Q1–Q6、Q8、Q9 照建议,Q7 另裁)
--   ① GST 申报申请(Q1–Q4):gst_filing_requests。财务提(module.finance.edit),冻结那一季 F5 每一格;CFO 批
--      (二级,不分档)—— 再判锁、再算一遍,逐字相等才把那一组抄进 gst_return_boxes,期间 open → approved;
--      财务去 IRAS 报之后用 record_gst_filing 一步记下申报日与参考号(approved → filed)。file_gst_return 只会按名拒
--      GST_FILING_NEEDS_APPROVED_REQUEST。开更正件(F7)仍是一步;报 F7 走同一张申请。在等的时候把锁挪回那一季
--      按名拒(guard_gst_filing_lock,挂在 finance_settings 上)。APR-9 处置的形状:名册二级一行、blocks_disable、
--      审批关着时生下来就批准;提单人之外没人批得动 → 提交就拒。
--   ② 采购单品类(Q5 · Q6 · Q8 · Q9):purchase_orders.category(consumables / equipment_goods / office),
--      线上 11 张全部回填 equipment_goods(Step 0 量过:每一张买的都是电池原料或设备);生下来就定死;
--      资产行与电池料行只能在 equipment_goods 里。三个开单码(新码同一迁移里也授给 admin —— 常设裁定):
--      action.raise_po_consumables → warehouse · action.raise_po_equipment → cco · action.raise_po_office → finance;
--      warehouse 另拿 module.purchasing.view。module.purchasing.edit 从此不开单。
--   ③ 谁能改 / 取消 / 关闭 / 重开(Q7,Tim 另裁):开单人本人,或此刻持这张单那一类开单码的人 —— 其余按名拒
--      PO_NOT_RAISER_OR_CATEGORY_HOLDER(assert_po_manager / po_may_manage)。批准照旧。
--   ④ 提单人之外没人批得动时,开单就拒 PO_NO_OTHER_DECIDER(关掉 ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE 的采购单那一半)。
--   ⑤ 采购单四张表没有直连写:12 条写策略拿掉,guard_po_direct_write 按名拒 PO_THROUGH_FUNCTION_ONLY。
--
-- 【不做什么】不碰审批开关与策略;不碰 user_roles;不写任何业务行(回填那一列除外);不给 cto 收回任何码
-- (它仍持 module.purchasing.edit —— 只是那个码不再开单、不再改单)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权 = 之前 + 恰好裁定的那些行;在途单据一张不少、一张不多;
-- 留痕、分录、GST 期间与快照、采购单(除新列外)一行没变;申请表是空的、没有写策略;五张表没有写策略;守卫挂上;
-- 内层算子 authenticated 调不到;GST 链二级有人批;每一张在途单据都还有一个【不是它自己当事人】的决定人。
-- 断言失败 = 整笔回滚。

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
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'"""

COUNTS = """SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(filed_on::text, '-'), ',' ORDER BY code), ''))
          FROM gst_periods) AS gst_periods,
       (SELECT count(*) FROM gst_return_boxes) AS gst_return_boxes,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || approval_status || ':' || estimated_total_ccy::text
                                       || ':' || COALESCE(updated_at::text, '-'), ',' ORDER BY code), ''))
          FROM purchase_orders) AS purchase_orders,
       (SELECT count(*) FROM purchase_order_lines) AS po_lines,
       (SELECT count(*) FROM purchase_order_payment_terms) AS po_terms,
       (SELECT count(*) FROM purchase_order_history) AS po_history,
       (SELECT locked_before FROM finance_settings) AS locked_before"""

NEW_CODES = ["action.raise_po_consumables", "action.raise_po_equipment", "action.raise_po_office"]
RULED_GRANTS = [("warehouse", "action.raise_po_consumables"), ("warehouse", "module.purchasing.view"),
                ("cco", "action.raise_po_equipment"), ("finance", "action.raise_po_office"),
                ("admin", "action.raise_po_consumables"), ("admin", "action.raise_po_equipment"),
                ("admin", "action.raise_po_office")]

INTERNALS = ["gst_filing_execute_internal(uuid)", "assert_po_manager(uuid)"]

DOORS = ["submit_gst_filing_request(uuid, text)", "decide_gst_filing_request(uuid, boolean, text)",
         "withdraw_gst_filing_request(uuid, text)", "record_gst_filing(uuid, date, text)",
         "gst_filing_requests_visible(uuid, integer)", "po_may_manage(uuid)", "po_category_raise_code(text)"]

GUARDS = ["trg_gst_filing_lock", "trg_purchase_orders_direct_write", "trg_purchase_order_lines_direct_write",
          "trg_purchase_order_payment_terms_direct_write", "trg_purchase_order_line_retentions_direct_write",
          "trg_purchase_order_lines_category"]

PO_TABLES = ["purchase_orders", "purchase_order_lines", "purchase_order_payment_terms", "purchase_order_line_retentions"]

# 新函数(先于替换的那些,因为替换的要调它们);create_purchase_order 另走 DROP + CREATE(签名多了 p_category)
NEW_FUNCTIONS = ["po_category_raise_code", "po_may_manage", "assert_po_manager", "guard_po_line_category",
                 "guard_po_direct_write", "gst_filing_execute_internal", "submit_gst_filing_request",
                 "decide_gst_filing_request", "withdraw_gst_filing_request", "record_gst_filing",
                 "gst_filing_requests_visible", "guard_gst_filing_lock"]
REPLACED_FUNCTIONS = ["file_gst_return", "guard_po_amendable", "amend_purchase_order", "cancel_purchase_order",
                      "close_purchase_order", "reopen_purchase_order", "apply_payment_term_template",
                      "record_approval_decision", "approval_pending_documents", "approval_chain_gates",
                      "approvals_readiness"]

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR10_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.gst_filing_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'APR10_PRE|gst_filing_requests already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'purchase_orders' AND column_name = 'category') THEN
        RAISE EXCEPTION 'APR10_PRE|purchase_orders.category already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code LIKE 'action.raise_po_%') THEN
        RAISE EXCEPTION 'APR10_PRE|a raise code already exists';
    END IF;
    -- GST 的决定人要持两个门码(cfo 持;Step 0 读过)
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cfo' AND rp.permission_code IN ('module.finance.view', 'data.view_prices')) <> 2 THEN
        RAISE EXCEPTION 'APR10_PRE|cfo does not hold the two codes the GST chain routes to it';
    END IF;
    -- Step 0 的读数:没有一张在途的采购单;没有一期批准过或申报过的 GST
    IF EXISTS (SELECT 1 FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'APR10_PRE|a purchase order is pending';
    END IF;
    IF EXISTS (SELECT 1 FROM gst_periods WHERE status <> 'open') OR EXISTS (SELECT 1 FROM gst_return_boxes) THEN
        RAISE EXCEPTION 'APR10_PRE|a GST period is already filed';
    END IF;
    -- 回填的依据(Q5):没有一张单带着「不该是 equipment_goods」的行 —— 这里没有办公用品与耗材的行可言,
    -- 只核对每一张都是资产行或物料行(买的是电池原料或设备)
    IF EXISTS (SELECT 1 FROM purchase_orders po
                WHERE NOT EXISTS (SELECT 1 FROM purchase_order_lines l WHERE l.purchase_order_id = po.id)) THEN
        RAISE EXCEPTION 'APR10_PRE|a purchase order without lines';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE a10_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE a10_counts_before ON COMMIT DROP AS
{COUNTS};
CREATE TEMP TABLE a10_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
""")

# ── 1 · 三个开单码 + 授权 ───────────────────────────────────────────────────────
perm = mirror("db/tables/permissions.sql")
rows = []
for code in NEW_CODES:
    i = perm.index(f"    ('{code}',")
    j = perm.index("\n", i)
    rows.append(perm[i:j].rstrip().rstrip(",").rstrip(";"))
parts.append("\n-- ── 1 · 三个开单码(镜像原样)与 module.purchasing.edit 的说明(它不再开单)──────────────\n")
parts.append("INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES\n"
             + ",\n".join(rows) + ";\n")
i = perm.index("    ('module.purchasing.edit',")
j = perm.index("\n", i)
line = perm[i:j].strip().rstrip(",")
# ('module.purchasing.edit', 'module', 'Purchasing (edit)', '采购(编辑)', '<en>', '<zh>', 51)
import re
m = re.match(r"\('module\.purchasing\.edit', 'module', '(?P<ne>[^']*)', '(?P<nz>[^']*)', '(?P<de>(?:[^']|'')*)', '(?P<dz>(?:[^']|'')*)', 51\)$", line)
assert m, line
parts.append(f"UPDATE public.permissions SET description_en = '{m['de']}', description_zh = '{m['dz']}'\n"
             f" WHERE code = 'module.purchasing.edit';\n")
parts.append("""
-- 授权(在函数之前:下面的自证要问到它们)。Tim 的 Q6;每一个新码也给 admin(常设裁定)。幂等。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, g.c FROM roles r
  JOIN (VALUES """ + ", ".join(f"('{r}', '{c}')" for r, c in RULED_GRANTS) + """) g(role_code, c)
    ON g.role_code = r.code
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

# ── 2 · GST:期间状态多一个 approved;申请表 ────────────────────────────────────
gp = mirror("db/tables/gst_periods.sql")
parts.append("\n-- ── 2 · gst_periods:状态多一个 approved(CFO 批了数字、还没去 IRAS 报)─────────────────\n")
parts.append("ALTER TABLE public.gst_periods DROP CONSTRAINT gst_periods_status_check;\n")
parts.append("ALTER TABLE public.gst_periods ADD CONSTRAINT gst_periods_status_check\n"
             "    CHECK (status IN ('open', 'approved', 'filed'));\n")
i = gp.index("    CONSTRAINT gst_periods_filed_shape CHECK (")
j = gp.index("\n    )", i) + len("\n    )")
shape = gp[i + len("    CONSTRAINT gst_periods_filed_shape "):j]
parts.append("ALTER TABLE public.gst_periods DROP CONSTRAINT gst_periods_filed_shape;\n")
parts.append("ALTER TABLE public.gst_periods ADD CONSTRAINT gst_periods_filed_shape " + shape + ";\n")

t = mirror("db/tables/gst_filing_requests.sql")
parts.append("\n-- ── 3 · gst_filing_requests(镜像原样)────────────────────────────────────────────\n")
parts.append(t[t.index("CREATE TABLE public.gst_filing_requests"):])

# ── 4 · approval_log:主体类型 + 读策略 ─────────────────────────────────────────
al = mirror("db/tables/approval_log.sql")
i = al.index("subject_type        text NOT NULL CHECK (subject_type IN (")
j = al.index("'gst_filing_request')),", i) + len("'gst_filing_request'))")
check_body = al[i + len("subject_type        text NOT NULL "):j]
parts.append("\n-- ── 4 · approval_log:主体类型加一种;读策略加同名一支 ─────────────────────────\n")
parts.append("ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;\n")
parts.append("ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check\n    "
             + check_body + ";\n")
parts.append('DROP POLICY "approval_log select by permission" ON public.approval_log;\n')
parts.append(stmt("db/tables/approval_log.sql", 'CREATE POLICY "approval_log select by permission"'))

# ── 5 · 采购单:品类列(回填)、列授权、遮蔽视图、写策略拿掉 ──────────────────────────
parts.append("""
-- ── 5 · purchase_orders.category ────────────────────────────────────────────────
-- 回填(Q5):线上 11 张全部 equipment_goods。用一个【随即删掉】的默认值一次填满 —— 不触发任何行触发器
-- (不留一行历史、不动 updated_at:回填是一次结构改动,不是一次修改)。镜像里这一列没有默认值:
-- 开单的门(create_purchase_order)永远显式写它。
ALTER TABLE public.purchase_orders ADD COLUMN category text NOT NULL DEFAULT 'equipment_goods'
    CONSTRAINT purchase_orders_category_check CHECK (category IN ('consumables', 'equipment_goods', 'office'));
ALTER TABLE public.purchase_orders ALTER COLUMN category DROP DEFAULT;
""")
parts.append(stmt("db/tables/purchase_orders.sql", "COMMENT ON COLUMN public.purchase_orders.category IS"))
parts.append("-- 列授权:品类不敏感(AGENTS.md「给遮蔽表加列:三件事一个迁移」—— ADD COLUMN · 列授权 · _masked 视图)\n")
parts.append("GRANT SELECT (category) ON public.purchase_orders TO authenticated;\n")
v = mirror("db/views/purchase_orders_masked.sql")
i = v.index("CREATE VIEW public.purchase_orders_masked WITH (security_invoker = off) AS")
j = v.index("WHERE has_permission('module.purchasing.view'::text);", i) + len("WHERE has_permission('module.purchasing.view'::text);")
parts.append(v[i:j].replace("CREATE VIEW public.purchase_orders_masked", "CREATE OR REPLACE VIEW public.purchase_orders_masked", 1) + "\n")
parts.append("\n-- 12 条写策略拿掉(guard_po_direct_write 按名拒 —— 见它的抬头)\n")
for tname in PO_TABLES:
    for cmd in ["insert", "update", "delete"]:
        parts.append(f'DROP POLICY "{tname} {cmd} by permission" ON public.{tname};\n')

# ── 6 · 函数 ─────────────────────────────────────────────────────────────────
parts.append("\n-- ── 6 · 函数(镜像原样)──────────────────────────────────────────────────────\n")
for name in NEW_FUNCTIONS + REPLACED_FUNCTIONS:
    parts.append(fn(name))
parts.append("""
-- create_purchase_order:签名多了 p_category(DEFAULT NULL —— 旧表单不送它,读到的是 PO_CATEGORY_REQUIRED,Q9)。
-- 旧签名先 DROP:CREATE OR REPLACE 换不了参数表,留着就是一个重载(FIN-21 那一类漂移)。
DROP FUNCTION public.create_purchase_order(uuid, date, date, text, numeric, text, text, text, jsonb, jsonb, text);
""")
parts.append(fn("create_purchase_order"))

# ── 7 · 守卫 ─────────────────────────────────────────────────────────────────
parts.append("\n-- ── 7 · 守卫(锁 · 四张表没有直连写 · 行品类)───────────────────────────────────\n")
parts.append(stmt("db/tables/finance_settings.sql", "CREATE TRIGGER trg_gst_filing_lock\n"))
for tname in PO_TABLES:
    parts.append(stmt(f"db/tables/{tname}.sql", f"CREATE TRIGGER trg_{tname}_direct_write\n"))
parts.append(stmt("db/tables/purchase_order_lines.sql", "CREATE TRIGGER trg_purchase_order_lines_category\n"))

# ── 8 · EXECUTE ──────────────────────────────────────────────────────────────
parts.append("\n-- ── 8 · EXECUTE:内层算子从 authenticated 收回(与 zzz_function_grants.sql 同句)────────\n")
for sig in INTERNALS:
    parts.append(f"REVOKE EXECUTE ON FUNCTION public.{sig} FROM PUBLIC, anon, authenticated;\n")
for sig in DOORS + ["create_purchase_order(uuid, date, date, text, numeric, text, text, text, jsonb, jsonb, text, text)"]:
    parts.append(f"REVOKE EXECUTE ON FUNCTION public.{sig} FROM PUBLIC, anon;\n")
    parts.append(f"GRANT EXECUTE ON FUNCTION public.{sig} TO authenticated, service_role;\n")

# ── 9 · operations_now ───────────────────────────────────────────────────────
v = mirror("db/views/operations_now.sql")
i = v.index("CREATE VIEW public.operations_now AS")
j = v.index("\n\nGRANT SELECT ON public.operations_now", i)
view = v[i:j].rstrip().rstrip(";") + ";\n"
parts.append("\n-- ── 9 · operations_now:加一支 gst_filing_pending(镜像原样)──────────────────────────\n")
parts.append(view.replace("CREATE VIEW public.operations_now AS", "CREATE OR REPLACE VIEW public.operations_now AS", 1))

# ── 10 · 自证 ────────────────────────────────────────────────────────────────
a9 = mirror("db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql")
start = a9.index("CREATE FUNCTION pg_temp.a9_pending_decider_check")
dec = a9[start:a9.index("$f$;", start) + 4].replace("a9_pending_decider_check", "a10_pending_decider_check")
parts.append("\n-- ── 10 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
internal_list = ", ".join(f"'public.{s}'" for s in INTERNALS)
guard_list = ", ".join(f"'{g}'" for g in GUARDS)
ruled = ", ".join(f"'{r}:{c}'" for r, c in RULED_GRANTS)
po_tables = ", ".join(f"'{t}'" for t in PO_TABLES)
parts.append(f"""
CREATE TEMP TABLE a10_pending_after ON COMMIT DROP AS
{PENDING}
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权 = 之前 + 恰好裁定的那几行(不收回任何一条)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT (SELECT role_code || ':' || permission_code FROM a10_grants_before
                 UNION SELECT unnest(ARRAY[{ruled}])))
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM a10_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR10_PROOF|grants differ from before + ruled: %', v_bad; END IF;
    SELECT string_agg(x, ', ') INTO v_bad FROM unnest(ARRAY[{ruled}]) x
     WHERE x NOT IN (SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id);
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR10_PROOF|ruled grants missing: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR10_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、GST 期间与快照、采购单(除新列)一行没变;申请表是空的;
    --    11 张单全部 equipment_goods
    IF EXISTS ((SELECT b.k, b.id FROM a10_pending_before b EXCEPT SELECT a.k, a.id FROM a10_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM a10_pending_after a EXCEPT SELECT b.k, b.id FROM a10_pending_before b)) THEN
        RAISE EXCEPTION 'APR10_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM a10_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM ({COUNTS}) n) THEN
        RAISE EXCEPTION 'APR10_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM a10_counts_before c), (SELECT row(n.*)::text FROM ({COUNTS}) n);
    END IF;
    IF EXISTS (SELECT 1 FROM gst_filing_requests) THEN
        RAISE EXCEPTION 'APR10_PROOF|gst_filing_requests is not empty';
    END IF;
    IF EXISTS (SELECT 1 FROM purchase_orders WHERE category IS DISTINCT FROM 'equipment_goods') THEN
        RAISE EXCEPTION 'APR10_PROOF|a purchase order was not backfilled to equipment_goods';
    END IF;
    RAISE NOTICE 'APR10 backfilled % purchase orders to equipment_goods', (SELECT count(*) FROM purchase_orders);

    -- ④ 结构:申请表与采购单四张表没有写策略;守卫挂上;内层算子 authenticated 调不到;
    --    名册里 GST 一行、只有二级;create_purchase_order 只剩一个签名
    SELECT string_agg(tablename || ':' || cmd, ', ') INTO v_bad FROM pg_policies
     WHERE schemaname = 'public' AND cmd <> 'SELECT' AND tablename IN ('gst_filing_requests', {po_tables});
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR10_PROOF|write policies left: %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ({guard_list});
    IF v_n <> {len(GUARDS)} THEN RAISE EXCEPTION 'APR10_PROOF|expected {len(GUARDS)} guard triggers, got %', v_n; END IF;
    SELECT string_agg(s, ', ') INTO v_bad FROM unnest(ARRAY[{internal_list}]) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR10_PROOF|authenticated can still execute: %', v_bad; END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'gst_filing_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'APR10_PROOF|gst_filing_request chain row';
    END IF;
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = 'create_purchase_order') <> 1 THEN
        RAISE EXCEPTION 'APR10_PROOF|create_purchase_order has more than one signature';
    END IF;

    -- ⑤ GST 链此刻有人批得了
    SELECT count(*) INTO v_n FROM approval_deciders('gst_filing_request', 'decide_gst_filing_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'APR10_PROOF|nobody can decide a GST filing'; END IF;
    RAISE NOTICE 'APR10 deciders for gst_filing_request: %', v_n;

    -- ⑥ 三类的开单码各有真持有人(admin 以外至少一个);每一类的开单人 × 每一级,提单人之外还有没有人批 —— 只报
    FOR k, v_bad IN
        SELECT c.code, string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = rg.user_id), ' ')
          FROM unnest(ARRAY{NEW_CODES}::text[]) c(code)
          JOIN role_permissions rp ON rp.permission_code = c.code
          JOIN roles ro ON ro.id = rp.role_id
          CROSS JOIN LATERAL real_role_grants(ro.code) rg
         GROUP BY c.code ORDER BY 1
    LOOP
        RAISE NOTICE 'APR10 raisers %: %', k, v_bad;
    END LOOP;

    -- ⑦ 每一张在途单据 —— 连同每一条申请链 —— 都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.a10_pending_decider_check(true) c LOOP
        RAISE NOTICE 'APR10 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.a10_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'APR10_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.a10_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.a10_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
