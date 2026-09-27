#!/usr/bin/env python3
"""EMP-SELF-1:从镜像拼出迁移文件(形状照 build_terms_edit1_migration.py)。镜像是真源,迁移是它的一次投影 ——
九支函数从 db/functions/ 原样抽出,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_emp_self1_migration.py(在仓库根目录)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-27-emp-self1-find-see-and-withdraw-your-own.sql"


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


HEADER = """-- db/migrations/2026-09-27-emp-self1-find-see-and-withdraw-your-own.sql
-- EMP-SELF-1(余下部分)—— 员工看得见自己的请假与报销是谁决定的、为什么;撤得掉自己还在等的;没有员工档案的账号什么都动不了;
-- 外加两件折进来的:结束了的合同表头冻结、敞口报表只算生效中的合同。
-- 由 db/scripts/build_emp_self1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(EMP-SELF-1 grilling Q1–Q8,Tim 2026-09-27 全部接受)
--   ① 表:medical_claims 多一个状态 'withdrawn' 与一列 withdrawn_at(末尾),形状约束 medical_claims_withdraw_shape
--      (withdrawn ⇔ withdrawn_at 有值,与 expense_claims 同一条)。
--   ② 新:withdraw_medical_claim(uuid) —— 本人或 module.hr.edit;只撤 submitted(G3b · Q8)。
--   ③ 新:my_document_decisions() —— 属主权限,只给调用者自己的单据,决定人显示成人(Q4 · Q5)。
--   ④ 替换:五支 NULL-blind 的写 —— submit_leave_request · submit_medical_claim · submit_expense_claim ·
--      cancel_leave_request · withdraw_expense_claim 的门改成 COALESCE(…, false)(Q9 · Q2)。
--      cancel_leave_request 另加:本人那一支只撤 pending(LEAVE_OWN_CANCEL_PENDING_ONLY,Q1)。
--   ⑤ 替换:guard_contract_write —— 到期 / 终止的合同表头任何改动按名拒 CONTRACT_TERMS_FROZEN(Q7)。
--   ⑥ 替换:price_exposure_report —— 头寸只算生效中的合同,多一种具名的零 no_active_contracts(Q6)。
--
-- 【不做什么】不加新码 —— 所以"每一个新码同一迁移里授给 admin"这条常设裁定这里没有东西可授;不碰审批开关、名册、策略;
-- 不碰 user_roles / role_permissions;不写任何业务行;两张报销视图不变(Q5)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;
-- 留痕、分录、合同、三种单据一行没变;新旧函数的形状对;每一张在途单据都还有一个【不是它自己当事人】的决定人。
-- 断言失败 = 整笔回滚。

BEGIN;
"""

# 与 TERMS-EDIT-1 同一份在途单据清单(那一刀的 PENDING,逐字)
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
       (SELECT count(*) FROM contract_pricing_terms) AS pricing,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM leave_requests) AS leave,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM medical_claims) AS medical,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM expense_claims) AS expense,
       (SELECT locked_before FROM finance_settings) AS locked_before"""

HARDENED = ["submit_leave_request", "submit_medical_claim", "submit_expense_claim",
            "cancel_leave_request", "withdraw_expense_claim"]
SIGS = {
    "submit_leave_request": "public.submit_leave_request(uuid, text, date, date, boolean, boolean, text, text, boolean, numeric, text)",
    "submit_medical_claim": "public.submit_medical_claim(uuid, date, numeric, text, text)",
    "submit_expense_claim": "public.submit_expense_claim(uuid, date, numeric, text, text, text)",
    "cancel_leave_request": "public.cancel_leave_request(uuid, text)",
    "withdraw_expense_claim": "public.withdraw_expense_claim(uuid)",
}

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ES1_PRE|approvals are expected ON';
    END IF;
    IF to_regprocedure('public.withdraw_medical_claim(uuid)') IS NOT NULL
       OR to_regprocedure('public.my_document_decisions()') IS NOT NULL THEN
        RAISE EXCEPTION 'ES1_PRE|withdraw_medical_claim or my_document_decisions already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.medical_claims'::regclass
                AND attname = 'withdrawn_at' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'ES1_PRE|medical_claims.withdrawn_at already exists';
    END IF;
    IF position('no_active_contracts' IN (SELECT prosrc FROM pg_proc WHERE oid = 'public.price_exposure_report()'::regprocedure)) > 0 THEN
        RAISE EXCEPTION 'ES1_PRE|price_exposure_report already reads contract status';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE es1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE es1_counts_before ON COMMIT DROP AS
{COUNTS};
CREATE TEMP TABLE es1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
""")

parts.append("""
-- ── 1 · 表:医疗申报可以被撤回(镜像 db/tables/medical_claims.sql 同改;列加在末尾)──────────────
ALTER TABLE public.medical_claims DROP CONSTRAINT medical_claims_status_check;
ALTER TABLE public.medical_claims ADD CONSTRAINT medical_claims_status_check
    CHECK (status IN ('submitted','approved','rejected','paid','withdrawn'));
ALTER TABLE public.medical_claims ADD COLUMN withdrawn_at timestamptz;
ALTER TABLE public.medical_claims ADD CONSTRAINT medical_claims_withdraw_shape
    CHECK ((status = 'withdrawn') = (withdrawn_at IS NOT NULL));
""")

parts.append("\n-- ── 2 · 新:撤回自己的医疗申报(镜像原样)────────────────────────────────────\n")
parts.append(fn("withdraw_medical_claim"))
parts.append("\n-- ── 3 · 新:我的单据是谁决定的、为什么(镜像原样)──────────────────────────────\n")
parts.append(fn("my_document_decisions"))
parts.append("\n-- ── 4 · 替换:五支 NULL-blind 的写(镜像原样)────────────────────────────────\n")
for f in HARDENED:
    parts.append(fn(f))
parts.append("\n-- ── 5 · 替换:结束了的合同表头冻结(镜像原样)────────────────────────────────\n")
parts.append(fn("guard_contract_write"))
parts.append("\n-- ── 6 · 替换:敞口报表只算生效中的合同(镜像原样)────────────────────────────\n")
parts.append(fn("price_exposure_report"))

# ── 7 · 自证 ────────────────────────────────────────────────────────────────
te1 = mirror("db/migrations/2026-09-27-terms-edit1-contract-terms-editor.sql")
start = te1.index("CREATE FUNCTION pg_temp.te1_pending_decider_check")
dec = te1[start:te1.index("$f$;", start) + 4].replace("te1_pending_decider_check", "es1_pending_decider_check")
parts.append("\n-- ── 7 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

coalesce_checks = "\n".join(
    f"""    IF position('COALESCE(' IN (SELECT prosrc FROM pg_proc WHERE oid = '{SIGS[f]}'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'ES1_PROOF|{f} gate is not COALESCE-hardened';
    END IF;""" for f in HARDENED)

parts.append(f"""
CREATE TEMP TABLE es1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一行没变(本刀没有新码,所以也没有东西要授给 admin)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM es1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM es1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ES1_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ES1_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、合同、三种单据一行没变
    IF EXISTS ((SELECT b.k, b.id FROM es1_pending_before b EXCEPT SELECT a.k, a.id FROM es1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM es1_pending_after a EXCEPT SELECT b.k, b.id FROM es1_pending_before b)) THEN
        RAISE EXCEPTION 'ES1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM es1_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM ({COUNTS}) n) THEN
        RAISE EXCEPTION 'ES1_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM es1_counts_before c), (SELECT row(n.*)::text FROM ({COUNTS}) n);
    END IF;

    -- ④ 形状:两支新函数是 DEFINER、authenticated 调得到;五支写都带 COALESCE;本人撤假只撤 pending
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.withdraw_medical_claim(uuid)'::regprocedure)
       OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.my_document_decisions()'::regprocedure) THEN
        RAISE EXCEPTION 'ES1_PROOF|the two new functions must be SECURITY DEFINER';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.withdraw_medical_claim(uuid)'::regprocedure, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.my_document_decisions()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'ES1_PROOF|authenticated cannot execute a new function';
    END IF;
{coalesce_checks}
    IF position('LEAVE_OWN_CANCEL_PENDING_ONLY' IN (SELECT prosrc FROM pg_proc WHERE oid = 'public.cancel_leave_request(uuid, text)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'ES1_PROOF|cancel_leave_request does not limit the own arm to pending';
    END IF;
    -- 没有 JWT 的读者(本迁移自己,postgres)读 my_document_decisions():0 行 —— 没有员工档案 = 什么都不给
    SELECT count(*) INTO v_n FROM my_document_decisions();
    IF v_n <> 0 THEN RAISE EXCEPTION 'ES1_PROOF|my_document_decisions gave % row(s) to a caller with no employee record', v_n; END IF;
    -- 敞口报表:线上 0 份合同 → 状态仍是 no_contracts(这支迁移没有改变线上任何一个读者此刻看到的东西)
    IF (SELECT count(*) FROM contracts WHERE deleted_at IS NULL) = 0 THEN
        PERFORM set_config('request.jwt.claims', json_build_object('sub',
            (SELECT ur.user_id FROM user_roles ur JOIN roles r ON r.id = ur.role_id
              WHERE r.code = 'cfo' AND ur.revoked_at IS NULL LIMIT 1), 'role', 'authenticated')::text, true);
        IF (price_exposure_report()->'sell_side'->>'state') <> 'no_contracts' THEN
            RAISE EXCEPTION 'ES1_PROOF|price_exposure_report state moved with 0 contracts';
        END IF;
        PERFORM set_config('request.jwt.claims', '', true);
    END IF;
    SELECT count(*) INTO v_n FROM pg_constraint WHERE conrelid = 'public.medical_claims'::regclass
       AND conname IN ('medical_claims_status_check', 'medical_claims_withdraw_shape');
    IF v_n <> 2 THEN RAISE EXCEPTION 'ES1_PROOF|medical_claims constraints: expected 2, got %', v_n; END IF;

    -- ⑤ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.es1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ES1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.es1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ES1_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.es1_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.es1_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
