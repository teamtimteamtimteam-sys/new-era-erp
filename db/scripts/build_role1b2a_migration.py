#!/usr/bin/env python3
"""ROLE-1 Batch 2a:从镜像拼出迁移文件。理由与 PRICE-1 / CONTRACT-1 的拼装脚本同一条 ——
镜像是真源,迁移是它的一次投影;手抄两份迟早各说各话。
跑法:python3 db/scripts/build_role1b2a_migration.py(在仓库根目录)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql"


def fn(name):
    return (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"


def between(path, start, end):
    s = (ROOT / path).read_text()
    i = s.index(start)
    j = s.index(end, i)
    return s[i:j]


HEADER = """-- db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql
-- ROLE-1 · Batch 2a —— Tim 的角色与审批矩阵(docs/role-matrix.md)第 2 批的前一半。
-- 由 db/scripts/build_role1b2a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本批做什么】(Batch 2 grilling Q5–Q11 + Batch 2a grilling Q1–Q8,Tim 全部接受)
--   ① 三个新动作码,只给 cfo:action.finance_settings · action.customer_credit · action.supplier_approve。
--      ★ 不给 admin 角色(Tim)。⚠ admin@ 同时持 cfo 角色,所以 admin@ 经由 cfo 拿得到这三个码 ——
--        那是 Tim 自己在 /settings/accounts 上的决定,本刀不碰 user_roles。
--   ② 财务设置(Q10):accounts / currencies / company_profile 的写策略与 enforce_write_permission
--      从 module.finance.edit 换成 action.finance_settings;finance_settings 的写策略不换
--      (锁期仍归财务),加一支列守卫 guard_finance_settings_cfo_columns + 写入口 set_finance_settings;
--      company-assets 桶的上传 / 改 / 删改为要 action.finance_settings(读不变:PDF 要读标志)。
--   ③ 客户信用(Q11):列守卫 guard_customer_credit_write + 写入口 set_customer_credit;
--      批量导入不许带 credit_limit_base / credit_hold。
--   ④ 供应商审批(Q8–Q9 · Q2–Q4):supplier_status_moves()(唯一定义)· set_supplier_status
--      (唯一改法)· guard_supplier_direct_write(created_by 永不可改;直连不许改状态、
--      不许生出非 draft、不许伪造建档人)· approved_by / approved_at(批准时盖、回草稿时清)·
--      supplier_status_history(每一步)· approval_log 加 'supplier'(送审 / 批准 / 驳回)·
--      operations_now 加 supplier_pending_approval。不是审批引擎的链。
--   ⑤ 未批准的供应商不付款(Q5):payment_request_payee_check 只放行 approved / active 且没被删;
--      新采购单同样(Q7 / Q1):trg_purchase_orders_supplier_approved,只挂 INSERT、每一条路径都拦。
--   ⑥ 仓库建供应商(Q5):warehouse 拿到 module.suppliers.view + module.suppliers.edit。
--
-- 【不做什么】不批准任何供应商(Q6)。审批开关与策略一个字都不碰。Batch 2b(合同条款、
--   金属价格、直接销售、化验)是下一刀。
--
-- ★★【本迁移一提交,线上就有 377,673.50 的应付付不出去】★★(以 tim@ 身份读 ap_open_items 视图,
--   2026-09-24 18:31 CST)—— Acme(SUP-2026-0002)97,064.50 · Bosch(SUP-2026-0095)280,000.00 ·
--   Ever Higher(SUP-2026-0445)109.00 三家是 draft;ZZ1B-GDS 500.00 是一家已删的供应商。
--   前三家由 Choo Er 送审、Tim(tim@)批准之后恢复可付;第四家是测试残骸,记在
--   docs/known-wrong-until-cutover.md。此刻线上 0 张付款申请,所以没有一张在途申请被卡住。
--
-- 【RUNTIME CONFIG 的引导默认值,照 AGENTS.md 那条规矩说清楚】
--   · role_permissions 的引导【改了】:warehouse 加 module.suppliers.view / .edit(Q5)。
--     它说的仍是它原来的意思(全新安装的起点);cfo 仍不在引导里(ROLE1-BOOTSTRAP-MISSING-ROLES),
--     所以三个新码在全新安装里没有持有者 —— 与 Batch 1 的 action.finance_reopen 同一个处境。
--   · permissions 是逐行比对的种子,新增三行,镜像同步。
--   · finance_settings 不是种子表;本刀没有改变任何 RUNTIME CONFIG 表里某一列的【含义】。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;在途单据一张不少;
-- approval_log 一行没写;供应商状态一家没变;每一个角色的码 = 之前 + 本刀那五条授权,不多不少;
-- 每一张在途单据都还有一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;
"""

parts = [HEADER]

parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B2A_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ('action.finance_settings', 'action.customer_credit',
                                                        'action.supplier_approve')) THEN
        RAISE EXCEPTION 'ROLE1B2A_PRE|new codes already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                WHERE r.code = 'warehouse' AND rp.permission_code LIKE 'module.suppliers.%') THEN
        RAISE EXCEPTION 'ROLE1B2A_PRE|warehouse already holds a suppliers code';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'suppliers' AND column_name = 'approved_by') THEN
        RAISE EXCEPTION 'ROLE1B2A_PRE|suppliers.approved_by already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM payment_requests WHERE status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'ROLE1B2A_PRE|a payment request is in flight — Step 0 read none';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE b2a_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved');
CREATE TEMP TABLE b2a_log_before ON COMMIT DROP AS SELECT count(*) AS n FROM approval_log;
CREATE TEMP TABLE b2a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE b2a_suppliers_before ON COMMIT DROP AS
SELECT id, status::text AS status, created_by, deleted_at FROM suppliers;
CREATE TEMP TABLE b2a_credit_before ON COMMIT DROP AS
SELECT id, credit_limit_base, credit_hold FROM customers;
CREATE TEMP TABLE b2a_je_before ON COMMIT DROP AS SELECT count(*) AS n FROM journal_entries;

-- ── 1 · 目录:三个新码 ────────────────────────────────────────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
""")
perm = (ROOT / "db/tables/permissions.sql").read_text()
rows = [l for l in perm.splitlines() if l.strip().startswith(("('action.finance_settings'", "('action.customer_credit'", "('action.supplier_approve'"))]
assert len(rows) == 3, rows
parts.append("\n".join(rows) + "\n")

parts.append("""
-- ── 2 · suppliers:批准戳两列(Q4)────────────────────────────────────────────
ALTER TABLE public.suppliers ADD COLUMN approved_by uuid;
ALTER TABLE public.suppliers ADD COLUMN approved_at timestamptz;
""")
sup = (ROOT / "db/tables/suppliers.sql").read_text()
parts.append(sup[sup.index("COMMENT ON COLUMN public.suppliers.approved_by IS"):].rstrip("\n") + "\n")

parts.append("\n-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────\n")
for name in ["supplier_status_moves", "guard_supplier_direct_write", "log_supplier_status_change",
             "guard_supplier_status_history_append_only", "set_supplier_status",
             "record_approval_decision", "payment_request_payee_check", "guard_po_supplier_approved",
             "guard_finance_settings_cfo_columns", "set_finance_settings",
             "guard_customer_credit_write", "set_customer_credit", "master_import_forbidden_columns"]:
    body = fn(name)
    if not body.lstrip().startswith("--"):
        body = f"-- ─── {name}\n" + body
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    parts.append("\n" + body)

parts.append("\n-- ─── validate_supplier_status_transition(改体:读 supplier_status_moves();批准盖戳、回草稿清戳)\n")
parts.append(between("db/tables/suppliers.sql",
                     "CREATE OR REPLACE FUNCTION public.validate_supplier_status_transition()",
                     "CREATE TRIGGER trg_generate_supplier_code"))

parts.append("\n-- ── 4 · 供应商状态变动史(Q3)──────────────────────────────────────────────\n")
hist = (ROOT / "db/tables/supplier_status_history.sql").read_text()
parts.append(hist[hist.index("CREATE TABLE public.supplier_status_history"):].rstrip("\n") + "\n")

parts.append("""
-- ── 5 · 新触发器 ─────────────────────────────────────────────────────────────
CREATE TRIGGER trg_suppliers_direct_write
    BEFORE INSERT OR UPDATE ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION public.guard_supplier_direct_write();

CREATE TRIGGER trg_suppliers_status_history
    AFTER UPDATE OF status ON public.suppliers
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION public.log_supplier_status_change();

CREATE TRIGGER trg_customers_credit_write
    BEFORE INSERT OR UPDATE ON public.customers
    FOR EACH ROW EXECUTE FUNCTION public.guard_customer_credit_write();

CREATE TRIGGER trg_finance_settings_cfo_columns
    BEFORE INSERT OR UPDATE ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION public.guard_finance_settings_cfo_columns();

CREATE TRIGGER trg_purchase_orders_supplier_approved
    BEFORE INSERT ON public.purchase_orders
    FOR EACH ROW EXECUTE FUNCTION public.guard_po_supplier_approved();

-- ── 6 · 科目表 / 币种 / 公司资料:写权换到 action.finance_settings(Q10)──────
""")
for t in ["accounts", "currencies", "company_profile"]:
    parts.append(f"""ALTER POLICY "{t} insert by permission" ON public.{t} WITH CHECK (has_permission('action.finance_settings'::text));
ALTER POLICY "{t} update by permission" ON public.{t} USING (has_permission('action.finance_settings'::text)) WITH CHECK (has_permission('action.finance_settings'::text));
ALTER POLICY "{t} delete by permission" ON public.{t} USING (has_permission('action.finance_settings'::text));
DROP TRIGGER enforce_write_permission ON public.{t};
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.{t}
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.finance_settings');

""")

al = (ROOT / "db/tables/approval_log.sql").read_text()
check = al[al.index("subject_type        text NOT NULL CHECK (subject_type IN ("):]
check = check[check.index("CHECK (subject_type IN ("):check.index("'supplier')),") + len("'supplier'))")]
pol = al[al.index('CREATE POLICY "approval_log select by permission"'):]
pol_using = pol[pol.index("    USING ("):pol.index(");\n") + 1]
parts.append(f"""-- ── 7 · approval_log:枚举 + 读策略(加 'supplier';读的那一支漏掉就是"写得进、读不出")──
ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;
ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check
    {check};
ALTER POLICY "approval_log select by permission" ON public.approval_log
{pol_using};
""")

view = (ROOT / "db/views/operations_now.sql").read_text()
vbody = view[view.index("CREATE VIEW public.operations_now AS"):view.index(";;")]
parts.append("\n-- ── 8 · operations_now:加一支 supplier_pending_approval(Q9)──────────────\n")
parts.append(vbody.replace("CREATE VIEW public.operations_now AS", "CREATE OR REPLACE VIEW public.operations_now AS", 1) + ";\n")

parts.append("""
-- ── 9 · company-assets 桶:写要 action.finance_settings,读不变 ─────────────────
-- 桶与它的策略【不在镜像里】(AGENTS.md「存储桶与它的策略不在镜像里」),所以它们只活在迁移里;
-- 行为的证明在 db/scripts/2026-09-24-role1b2a-live-proof.sql(对着线上、整支回滚)。
-- 读【不收】:发票 / 送货单 PDF 在生成时要读公司标志,生成它们的人不一定是 CFO。
-- UPDATE 两侧都写(UI-1d 的理由:只写 USING,一行可以被改名挪出这个判据)。
DROP POLICY "authenticated upload company-assets" ON storage.objects;
DROP POLICY "authenticated update company-assets" ON storage.objects;
DROP POLICY "authenticated delete company-assets" ON storage.objects;
CREATE POLICY "finance settings upload company-assets"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'company-assets' AND public.has_permission('action.finance_settings'));
CREATE POLICY "finance settings update company-assets"
    ON storage.objects FOR UPDATE TO authenticated
    USING (bucket_id = 'company-assets' AND public.has_permission('action.finance_settings'))
    WITH CHECK (bucket_id = 'company-assets' AND public.has_permission('action.finance_settings'));
CREATE POLICY "finance settings delete company-assets"
    ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'company-assets' AND public.has_permission('action.finance_settings'));

-- ── 10 · 授权(Q10 / Q11 / Q8 / Q5)─────────────────────────────────────────────
-- cfo:三件只归 CFO 的事。★ 不给 admin 角色(Tim 的指示)。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, c FROM roles r
 CROSS JOIN unnest(ARRAY['action.finance_settings', 'action.customer_credit', 'action.supplier_approve']) c
 WHERE r.code = 'cfo';
-- warehouse:建供应商档案(矩阵 §6)—— edit 蕴含 view。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, c FROM roles r
 CROSS JOIN unnest(ARRAY['module.suppliers.view', 'module.suppliers.edit']) c
 WHERE r.code = 'warehouse';
""")

# 在途单据的决定人检查:与 Batch 1 同一份零件,只改名字(p_after 恒 true —— 本刀不动任何决定函数的门)
b1 = (ROOT / "db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql").read_text()
dec = b1[b1.index("CREATE FUNCTION pg_temp.role1_pending_decider_check"):b1.index("$f$;", b1.index("CREATE FUNCTION pg_temp.role1_pending_decider_check")) + 4]
dec = dec.replace("role1_pending_decider_check", "b2a_pending_decider_check")
parts.append("""
-- ── 11 · 每一张在途单据,有几个【不是它自己当事人】的人决定得了它 ──────────────
-- 零件与 ROLE-1 Batch 1 的自证逐字相同(按【人】数,Tim 的两个账号只算一个);本刀没有改动
-- 任何一支决定函数的门,所以用"之后"那一组门问。付款申请此刻为 0 张(前提已断言)。
""")
parts.append(dec + "\n")

parts.append("""
CREATE TEMP TABLE b2a_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved');

-- ── 12 · 自证:同一笔事务里,失败即整笔回滚 ────────────────────────────────────
DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权 = 之前 + 这五条,不多不少
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT
         SELECT role_code || ':' || permission_code FROM b2a_grants_before)
        EXCEPT
        SELECT unnest(ARRAY['cfo:action.finance_settings', 'cfo:action.customer_credit', 'cfo:action.supplier_approve',
                            'warehouse:module.suppliers.view', 'warehouse:module.suppliers.edit'])
    ) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B2A_PROOF|unexpected grant: %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM (
        SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
        EXCEPT SELECT role_code || ':' || permission_code FROM b2a_grants_before) d;
    IF v_n <> 5 THEN RAISE EXCEPTION 'ROLE1B2A_PROOF|expected 5 new grants, got %', v_n; END IF;
    SELECT string_agg(role_code || ':' || permission_code, ', ') INTO v_bad FROM (
        SELECT role_code, permission_code FROM b2a_grants_before
        EXCEPT SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B2A_PROOF|a grant disappeared: %', v_bad; END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                WHERE r.code = 'admin' AND rp.permission_code IN
                      ('action.finance_settings', 'action.customer_credit', 'action.supplier_approve')) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|admin role received a new code';
    END IF;

    -- ② edit 蕴含 view
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code LIKE 'module.%.edit'
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id
                        AND v.permission_code = replace(rp.permission_code, '.edit', '.view'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B2A_PROOF|edit without view: %', v_bad; END IF;

    -- ③ 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|approvals switched off';
    END IF;

    -- ④ 在途单据一张不少、一张不多;留痕一行没写;分录一张没多
    IF EXISTS ((SELECT b.k, b.id FROM b2a_pending_before b EXCEPT SELECT a.k, a.id FROM b2a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM b2a_pending_after a EXCEPT SELECT b.k, b.id FROM b2a_pending_before b)) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|a pending document changed state';
    END IF;
    IF (SELECT count(*) FROM approval_log) <> (SELECT n FROM b2a_log_before) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|approval_log changed';
    END IF;
    IF (SELECT count(*) FROM journal_entries) <> (SELECT n FROM b2a_je_before) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|journal_entries changed';
    END IF;

    -- ⑤ 供应商一家没变(Q6:本迁移不批准任何一家);没有一家带着批准戳;变动史 0 行
    IF EXISTS (SELECT 1 FROM suppliers s JOIN b2a_suppliers_before b ON b.id = s.id
                WHERE s.status::text <> b.status OR s.created_by IS DISTINCT FROM b.created_by
                   OR s.deleted_at IS DISTINCT FROM b.deleted_at)
       OR (SELECT count(*) FROM suppliers) <> (SELECT count(*) FROM b2a_suppliers_before) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|a supplier changed';
    END IF;
    IF EXISTS (SELECT 1 FROM suppliers WHERE approved_by IS NOT NULL OR approved_at IS NOT NULL) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|a supplier carries an approval stamp';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_status_history) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|supplier_status_history is not empty';
    END IF;

    -- ⑥ 客户信用一格没变
    IF EXISTS (SELECT 1 FROM customers c JOIN b2a_credit_before b ON b.id = c.id
                WHERE c.credit_limit_base IS DISTINCT FROM b.credit_limit_base
                   OR c.credit_hold IS DISTINCT FROM b.credit_hold) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|a customer credit value changed';
    END IF;

    -- ⑦ 跳转图与 ROLE-1 之前触发器体里那一份逐条相同:18 步,CFO 四类 5 步
    IF (SELECT count(*) FROM supplier_status_moves()) <> 18
       OR (SELECT count(*) FROM supplier_status_moves() WHERE required_code = 'action.supplier_approve') <> 5 THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|supplier_status_moves is not the ruled map';
    END IF;

    -- ⑧ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.b2a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ROLE1B2A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.b2a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.b2a_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.b2a_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
