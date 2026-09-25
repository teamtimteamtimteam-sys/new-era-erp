#!/usr/bin/env python3
"""APR-6:从镜像拼出迁移文件(形状照 build_apr5b_migration.py / build_apr5a_migration.py)。镜像是真源,
迁移是它的一次投影 —— 函数、表、策略、触发器、视图都从镜像里【原样抽出】,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_apr6_migration.py(在仓库根目录)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql"


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


HEADER = """-- db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql
-- APR-6 —— 手工凭证与它的冲销要 CFO 批准才过账;系统生成的分录不经这里(docs/role-matrix.md「手工凭证与冲销」· N5)。
-- 由 db/scripts/build_apr6_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(APR-6 grilling Q1–Q12,Tim 2026-09-25 全部接受)
--   ① 界线划在权限上(Q1):post_journal_entry 的 EXECUTE 从 authenticated 收回;journal_entries /
--      journal_lines 的 INSERT 写策略拿掉,直连写按名拒 JOURNAL_THROUGH_FUNCTION_ONLY(语句级守卫)。
--      线上调 post_journal_entry 的 30 支函数全是 SECURITY DEFINER(属主 postgres),照常过账 —— 月结、外币重估、
--      折旧、年结、以及每一张单据自己的函数都不经审批(N5)。
--   ② journal_requests(Q3):entry = 一张手工凭证(永远过成 'manual',source_id = 申请);reversal = 冲一张没有自己
--      冲销路径的分录。财务提(module.finance.edit),CFO 批每一张、不分档(N1 对 journal_entries 退休,Q2),
--      批准【当场过账】,按提交时冻下来的日期;rejected(要理由)· withdrawn(提单人或 module.finance.edit)。
--      提交按同一支过账试跑(PQ005)。审批关着时生下来就是 approved 并当场过账(auto_approved)。
--      提单人之外没人批得动 → JOURNAL_REQUEST_NO_OTHER_DECIDER(assert_other_decider)。
--   ③ 期间锁永远赢(Q4):锁不因为一张在等的申请而被拒;批准时的过账按引擎原话拒(PERIOD_LOCKED)。
--   ④ 职责分离(Q5):sod_manual_posters_in 认【提单人】—— COALESCE(申请.created_by, 分录.created_by)。
--   ⑤ 冲销(Q6):reverse_journal_entry 一张都不冲 —— 有自己路径的按名拒 JE_REVERSE_USE_SOURCE_PATH(加上 expense ·
--      freight · allocation · processing_cost · year_close),其余按名拒 JOURNAL_NEEDS_APPROVED_REQUEST(走冲销申请)。
--      一份判据:journal_entry_reversal_route。
--   ⑥ 控制科目(Q7):申请过出来的分录碰 1100 / 2000 → JE_MANUAL_CONTROL_ACCOUNT(重估的冲销例外);
--      贷银行科目准许,申请上标 credits_bank。
--   ⑦ 引擎登记(Q8):approval_chain_gates 一行(二级,module.finance.view + data.view_prices);
--      approval_pending_documents 一支(blocks_disable、fixed_level = 2、主角 NULL);approval_log 的主体类型与
--      读策略各加 journal_request;record_approval_decision 一支(本位币);operations_now 一支 journal_request_pending。
--
-- 【不做什么】不新增任何权限码,所以"新码同时授给 admin"那条常设裁定这一刀无码可授;
-- 不碰 role_permissions、user_roles、审批开关与策略;不写任何业务行;不改任何一支系统过账函数。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;在途单据一张不少、一张不多;approval_log、
-- journal_entries、journal_lines 一行没变;授权一条没变;申请表是空的;职责分离的读数没变;两张分录表上没有写策略、
-- 两支守卫挂上;post_journal_entry 与三支内层算子 authenticated 调不到;除 post_journal_entry 自己之外,调它的
-- 每一支函数都是 SECURITY DEFINER(否则那条系统路径会在本刀之后断掉);旧的冲销门只会拒;新链有人批得了;
-- 每一张在途单据都还有一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

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
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'"""

COUNTS = """SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT count(*) FROM journal_entries WHERE source_type = 'manual') AS manual_entries,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total"""

INTERNALS = ["post_journal_entry(date, text, text, uuid, jsonb)",
             "journal_request_submit_internal(text, date, text, jsonb, uuid)",
             "journal_request_post_internal(uuid)",
             "journal_request_dry_run(uuid)"]

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR6_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.journal_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'APR6_PRE|journal_requests already exists';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public'
         AND policyname IN ('journal_entries insert by permission', 'journal_lines insert by permission')) <> 2 THEN
        RAISE EXCEPTION 'APR6_PRE|the two journal insert policies are not both there to drop';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.post_journal_entry(date, text, text, uuid, jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'APR6_PRE|post_journal_entry is expected to be executable by authenticated before this cut';
    END IF;
    -- 批的人要持两个门码:cfo 今天持 module.finance.view 与 data.view_prices
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cfo' AND rp.permission_code IN ('module.finance.view', 'data.view_prices')) <> 2 THEN
        RAISE EXCEPTION 'APR6_PRE|cfo does not hold both gate codes';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE a6_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE a6_counts_before ON COMMIT DROP AS
{COUNTS};
CREATE TEMP TABLE a6_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
-- 职责分离的读数:改写 sod_manual_posters_in 之前,全期间里"记过手工凭证的人"是谁
CREATE TEMP TABLE a6_sod_before ON COMMIT DROP AS
SELECT sod_manual_posters_in(NULL, '9999-12-31'::date) AS posters;
""")

# ── 1 · 表 ───────────────────────────────────────────────────────────────────
t = mirror("db/tables/journal_requests.sql")
parts.append("\n-- ── 1 · journal_requests(镜像原样)──────────────────────────────────────────\n")
parts.append(t[t.index("CREATE TABLE public.journal_requests"):])

# ── 2 · approval_log:主体类型 + 读策略 ─────────────────────────────────────────
al = mirror("db/tables/approval_log.sql")
i = al.index("subject_type        text NOT NULL CHECK (subject_type IN (")
j = al.index("'journal_request')),", i) + len("'journal_request'))")
check_body = al[i + len("subject_type        text NOT NULL "):j]
parts.append("\n-- ── 2 · approval_log:主体类型加 journal_request;读策略加同名一支 ──────────────\n")
parts.append("ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;\n")
parts.append("ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check\n    "
             + check_body + ";\n")
parts.append('DROP POLICY "approval_log select by permission" ON public.approval_log;\n')
parts.append(stmt("db/tables/approval_log.sql", 'CREATE POLICY "approval_log select by permission"'))

# ── 3 · 函数 ─────────────────────────────────────────────────────────────────
parts.append("\n-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────\n")
for name in ["guard_journal_direct_write", "journal_entry_reversal_route",
             "journal_request_post_internal", "journal_request_dry_run", "journal_request_submit_internal",
             "submit_journal_request", "submit_journal_reversal_request",
             "decide_journal_request", "withdraw_journal_request",
             "reverse_journal_entry", "sod_manual_posters_in",
             "record_approval_decision", "approval_pending_documents", "approval_chain_gates"]:
    parts.append(fn(name))

# ── 4 · 两张分录表:写策略拿掉,直连写按名拒 ───────────────────────────────────
parts.append("\n-- ── 4 · journal_entries / journal_lines:两条 INSERT 写策略拿掉;两支语句级守卫 ─────────\n")
parts.append('DROP POLICY "journal_entries insert by permission" ON public.journal_entries;\n')
parts.append('DROP POLICY "journal_lines insert by permission" ON public.journal_lines;\n')
parts.append(stmt("db/tables/journal_entries.sql", "CREATE TRIGGER trg_journal_entries_direct_write\n"))
parts.append(stmt("db/tables/journal_lines.sql", "CREATE TRIGGER trg_journal_lines_direct_write\n"))

# ── 5 · EXECUTE ──────────────────────────────────────────────────────────────
# apply_migration.sh 会在迁移体之后原样重放 db/views/zzz_function_grants.sql;这里先写一遍,
# 为的是让下面的自证【在同一笔事务里】看得见收回之后的样子。
parts.append("\n-- ── 5 · EXECUTE:过账核心与三支内层算子从 authenticated 收回(与 zzz_function_grants.sql 同句)──\n")
for sig in INTERNALS:
    parts.append(f"REVOKE EXECUTE ON FUNCTION public.{sig} FROM PUBLIC, anon, authenticated;\n")
for name in ["guard_journal_direct_write()", "journal_entry_reversal_route(uuid)",
             "submit_journal_request(date, text, jsonb)", "submit_journal_reversal_request(uuid, date, text)",
             "decide_journal_request(uuid, boolean, text)", "withdraw_journal_request(uuid, text)"]:
    parts.append(f"REVOKE EXECUTE ON FUNCTION public.{name} FROM PUBLIC, anon;\n")

# ── 6 · operations_now ───────────────────────────────────────────────────────
v = mirror("db/views/operations_now.sql")
i = v.index("CREATE VIEW public.operations_now AS")
j = v.index("\n\nGRANT SELECT ON public.operations_now", i)
view = v[i:j].rstrip().rstrip(";") + ";\n"
parts.append("\n-- ── 6 · operations_now:加一支 journal_request_pending(镜像原样)────────────────\n")
parts.append(view.replace("CREATE VIEW public.operations_now AS", "CREATE OR REPLACE VIEW public.operations_now AS", 1))

# ── 7 · 自证 ─────────────────────────────────────────────────────────────────
a5b = mirror("db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql")
start = a5b.index("CREATE FUNCTION pg_temp.a5b_pending_decider_check")
dec = a5b[start:a5b.index("$f$;", start) + 4].replace("a5b_pending_decider_check", "a6_pending_decider_check")
parts.append("\n-- ── 7 · 自证 ──────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
internal_list = ", ".join(f"'public.{s}'" for s in INTERNALS)
parts.append(f"""
CREATE TEMP TABLE a6_pending_after ON COMMIT DROP AS
{PENDING}
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一条没变(本刀不新增、不收回任何码)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM a6_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM a6_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR6_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR6_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;分录与留痕一行没变;申请表是空的;职责分离的读数没变
    IF EXISTS ((SELECT b.k, b.id FROM a6_pending_before b EXCEPT SELECT a.k, a.id FROM a6_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM a6_pending_after a EXCEPT SELECT b.k, b.id FROM a6_pending_before b)) THEN
        RAISE EXCEPTION 'APR6_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM a6_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM ({COUNTS}) n) THEN
        RAISE EXCEPTION 'APR6_PROOF|a journal / log count changed: % → %',
            (SELECT row(c.*)::text FROM a6_counts_before c), (SELECT row(n.*)::text FROM ({COUNTS}) n);
    END IF;
    IF EXISTS (SELECT 1 FROM journal_requests) THEN
        RAISE EXCEPTION 'APR6_PROOF|journal_requests is not empty';
    END IF;
    IF (SELECT array(SELECT unnest(posters) ORDER BY 1) FROM a6_sod_before)
       IS DISTINCT FROM array(SELECT unnest(sod_manual_posters_in(NULL, '9999-12-31'::date)) ORDER BY 1) THEN
        RAISE EXCEPTION 'APR6_PROOF|the manual-poster reading changed with no request in existence';
    END IF;

    -- ④ 结构:两张分录表上没有任何写策略;两支守卫挂上;过账核心与内层算子 authenticated 调不到;
    --    除 post_journal_entry 自己之外,调它的每一支函数都是 SECURITY DEFINER —— 一支 INVOKER 调用者会在
    --    收回之后以 42501 断掉(那就是一条被本刀弄坏的系统路径);旧的冲销门只会拒;名册一行、只有二级
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND tablename IN ('journal_entries', 'journal_lines') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'APR6_PROOF|a journal write policy is still there';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE tgname IN ('trg_journal_entries_direct_write', 'trg_journal_lines_direct_write');
    IF v_n <> 2 THEN RAISE EXCEPTION 'APR6_PROOF|expected 2 journal guard triggers, got %', v_n; END IF;
    SELECT string_agg(s, ', ') INTO v_bad FROM unnest(ARRAY[{internal_list}]) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR6_PROOF|authenticated can still execute: %', v_bad; END IF;
    SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_bad FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.prosrc ~ 'post_journal_entry\\s*\\('
       AND p.proname <> 'post_journal_entry' AND NOT p.prosecdef;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'APR6_PROOF|an INVOKER function calls post_journal_entry and would break: %', v_bad;
    END IF;
    SELECT count(*) INTO v_n FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.prosrc ~ 'post_journal_entry\\s*\\('
       AND p.proname <> 'post_journal_entry';
    RAISE NOTICE 'APR6 posting callers (all SECURITY DEFINER): %', v_n;
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.reverse_journal_entry(uuid, date, text)'::regprocedure)
       NOT LIKE '%JOURNAL_NEEDS_APPROVED_REQUEST%'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.reverse_journal_entry(uuid, date, text)'::regprocedure)
       LIKE '%reverse_journal_entry_internal%' THEN
        RAISE EXCEPTION 'APR6_PROOF|reverse_journal_entry still does the work itself';
    END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'journal_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'APR6_PROOF|journal_request chain row';
    END IF;

    -- ⑤ 二级这条新链此刻有人批得了(开着的审批不许因为一条新链而变成"开着却没人能批")
    SELECT count(*) INTO v_n FROM approval_deciders('journal_request', 'decide_journal_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'APR6_PROOF|nobody can decide a journal request'; END IF;
    RAISE NOTICE 'APR6 deciders for journal_request: %', v_n;

    -- ⑥ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.a6_pending_decider_check(true) c LOOP
        RAISE NOTICE 'APR6 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.a6_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'APR6_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.a6_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.a6_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
