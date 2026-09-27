#!/usr/bin/env python3
"""TERMS-EDIT-1:从镜像拼出迁移文件(形状照 build_apr10_migration.py)。镜像是真源,迁移是它的一次投影 ——
三支函数从 db/functions/ 原样抽出,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_terms_edit1_migration.py(在仓库根目录)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-27-terms-edit1-contract-terms-editor.sql"


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


HEADER = """-- db/migrations/2026-09-27-terms-edit1-contract-terms-editor.sql
-- TERMS-EDIT-1 —— 合同条款编辑器(/contracts/[id])的数据库那一半:卖方合同先填齐条款才申请得了生效;结束了的合同条款冻结。
-- 由 db/scripts/build_terms_edit1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(TERMS-EDIT-1 grilling Q3 · Q4,Tim 2026-09-27)
--   ① 新:contract_activation_missing(uuid) → text[] —— 卖方合同申请生效前还缺哪几条(结算口径一行 · 至少一条计价 ·
--      per_metal 时每个计价金属一行精炼费 · per_element 时至少一条惩罚);买方合同什么都不要求。SECURITY INVOKER ——
--      详情页以调用者身份读它画清单;提交那一支以属主身份读它。
--   ② 替换:terms_request_submit_internal —— 合同那一支在期限检查之后加一条 CONTRACT_TERMS_INCOMPLETE|编号|缺的那几条。
--   ③ 替换:contract_terms_lock_reason —— 除了 'request:<label>' 与 'active',还回 'expired' / 'terminated',
--      于是七张条款表在结束了的合同上按名拒 CONTRACT_TERMS_FROZEN|编号|expired / terminated。
--      表头那一支(guard_contract_write)只读 'request:',表头的规矩不变。
--
-- 【不做什么】不加新码(所以"新码同一迁移里授给 admin"这条常设裁定这里没有东西可授);不碰审批开关、名册、策略;
-- 不碰 user_roles / role_permissions;不写任何业务行;不改 APR-8 的任何一条规矩(新增的是提交时的一条拒绝,Tim 裁定)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;
-- 留痕、分录、合同、七张条款表、条款申请一行没变;三支函数的形状对(INVOKER / DEFINER);提交那一支读清单;
-- 每一张在途单据都还有一个【不是它自己当事人】的决定人,条款申请链二级有人批。断言失败 = 整笔回滚。

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
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted'"""

COUNTS = """SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || updated_at::text, ',' ORDER BY code), ''))
          FROM contracts) AS contracts,
       (SELECT count(*) FROM contract_grade_specs) AS grade_specs,
       (SELECT count(*) FROM contract_insurance_obligations) AS insurance,
       (SELECT count(*) FROM contract_volume_commitments) AS volume,
       (SELECT count(*) FROM contract_pricing_terms) AS pricing,
       (SELECT count(*) FROM contract_settlement_terms) AS settlement,
       (SELECT count(*) FROM contract_refining_charges) AS refining,
       (SELECT count(*) FROM contract_penalty_elements) AS penalty,
       (SELECT md5(COALESCE(string_agg(label || ':' || status, ',' ORDER BY label), '')) FROM terms_requests) AS terms_requests,
       (SELECT locked_before FROM finance_settings) AS locked_before"""

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'TE1_PRE|approvals are expected ON';
    END IF;
    IF to_regprocedure('public.contract_activation_missing(uuid)') IS NOT NULL THEN
        RAISE EXCEPTION 'TE1_PRE|contract_activation_missing already exists';
    END IF;
    IF position('CONTRACT_TERMS_INCOMPLETE' IN (SELECT prosrc FROM pg_proc WHERE oid = 'public.terms_request_submit_internal(text, uuid, jsonb, text)'::regprocedure)) > 0 THEN
        RAISE EXCEPTION 'TE1_PRE|terms_request_submit_internal already refuses incomplete contracts';
    END IF;
    -- Step 0 的读数(postgres,基表,2026-09-27 17:26):没有一张在等的条款申请
    IF EXISTS (SELECT 1 FROM terms_requests WHERE status = 'submitted') THEN
        RAISE EXCEPTION 'TE1_PRE|a terms request is waiting';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE te1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE te1_counts_before ON COMMIT DROP AS
{COUNTS};
CREATE TEMP TABLE te1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
""")

parts.append("\n-- ── 1 · 新:卖方合同申请生效前还缺什么(镜像原样)────────────────────────────\n")
parts.append(fn("contract_activation_missing"))
parts.append("\n-- ── 2 · 替换:提交那一支读清单(镜像原样)──────────────────────────────────\n")
parts.append(fn("terms_request_submit_internal"))
parts.append("\n-- ── 3 · 替换:结束了的合同条款冻结(镜像原样)────────────────────────────────\n")
parts.append(fn("contract_terms_lock_reason"))

# ── 4 · 自证 ────────────────────────────────────────────────────────────────
a10 = mirror("db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql")
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "te1_pending_decider_check")
parts.append("\n-- ── 4 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE te1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一行没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM te1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM te1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'TE1_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'TE1_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、合同、七张条款表、条款申请一行没变
    IF EXISTS ((SELECT b.k, b.id FROM te1_pending_before b EXCEPT SELECT a.k, a.id FROM te1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM te1_pending_after a EXCEPT SELECT b.k, b.id FROM te1_pending_before b)) THEN
        RAISE EXCEPTION 'TE1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM te1_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM ({COUNTS}) n) THEN
        RAISE EXCEPTION 'TE1_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM te1_counts_before c), (SELECT row(n.*)::text FROM ({COUNTS}) n);
    END IF;

    -- ④ 形状:清单是 INVOKER、authenticated 调得到;锁仍是 DEFINER;提交那一支仍然调不到、并且读清单
    IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.contract_activation_missing(uuid)'::regprocedure) THEN
        RAISE EXCEPTION 'TE1_PROOF|contract_activation_missing must be SECURITY INVOKER';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.contract_activation_missing(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'TE1_PROOF|authenticated cannot execute contract_activation_missing';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.contract_terms_lock_reason(uuid)'::regprocedure) THEN
        RAISE EXCEPTION 'TE1_PROOF|contract_terms_lock_reason must stay SECURITY DEFINER';
    END IF;
    IF has_function_privilege('authenticated', 'public.terms_request_submit_internal(text, uuid, jsonb, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'TE1_PROOF|authenticated can execute terms_request_submit_internal';
    END IF;
    IF position('contract_activation_missing(' IN (SELECT prosrc FROM pg_proc
                 WHERE oid = 'public.terms_request_submit_internal(text, uuid, jsonb, text)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'TE1_PROOF|terms_request_submit_internal does not read the checklist';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ('trg_contracts_guard_write',
        'trg_contract_grade_specs_frozen', 'trg_contract_insurance_obligations_frozen', 'trg_contract_volume_commitments_frozen',
        'trg_contract_pricing_terms_frozen', 'trg_contract_settlement_terms_frozen', 'trg_contract_refining_charges_frozen',
        'trg_contract_penalty_elements_frozen');
    IF v_n <> 8 THEN RAISE EXCEPTION 'TE1_PROOF|expected the 8 APR-8 contract guards, got %', v_n; END IF;

    -- ⑤ 条款申请链此刻有人批得了
    SELECT count(*) INTO v_n FROM approval_deciders('terms_request', 'decide_terms_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'TE1_PROOF|nobody can decide a terms request'; END IF;
    RAISE NOTICE 'TE1 deciders for terms_request: %', v_n;

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.te1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'TE1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.te1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'TE1_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.te1_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.te1_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
