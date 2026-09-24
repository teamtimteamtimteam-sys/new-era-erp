#!/usr/bin/env python3
"""PAYROLL-APR-1:从镜像拼出迁移文件。理由与 ROLE-1 Batch 2a / 2b 的拼装脚本同一条 ——
镜像是真源,迁移是它的一次投影;手抄两份迟早各说各话。函数、表、策略、触发器、视图都从镜像里
【原样抽出】,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_payrollapr1_migration.py(在仓库根目录)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql"


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
    """从镜像里抽出以 head 开头、到【语句真正的结尾】为止的那一句。
    ★ 不能是"下一个分号":approval_log 那条读策略的【注释】里就有一个全角之外的半角分号,
    第一版照"下一个分号"切,切在注释中间 —— psql 把那个分号当成注释的一部分,语句于是永远没有结尾,
    后面整支迁移被吞进同一句,apply 在函数授权兜底那一步才报错(整笔回滚,线上未动)。
    所以这里逐字扫:跳过 -- 行注释与单引号字符串,只认它们之外的那个分号。"""
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


HEADER = """-- db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql
-- PAYROLL-APR-1 —— 工资过账与撤销要 CFO 批准,批之前什么都不过账(docs/role-matrix.md §5)。
-- 由 db/scripts/build_payrollapr1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(grilling Q1–Q9,Tim 2026-09-24 全部接受)
--   ① payroll_requests:过账(post)或撤销过账(reversal)的申请。财务提(module.hr.edit),
--      CFO 批每一张、不分档(require_approver_for(2)),财务执行。审批关着时生下来就是 approved。
--   ② ★ 工资期是【公司的单据】(Q1 (A)):主角那条腿对谁都不成立,提单人那条照判、按人认。
--      CFO 批一期含他自己工资行的工资,留痕的备注说出来;不标 self_decided。
--   ③ post_payroll_period / unpost_payroll_period 成了【外门】:没有这一期、这一种的已批申请就
--      按名拒(PAYROLL_NEEDS_APPROVED_REQUEST)。函数体搬进 *_internal(authenticated 调不到),
--      批准与提交各按同一支引擎试跑一遍再回滚(payroll_request_dry_run)。
--      ☞ unpost_payroll_period 的签名从 (uuid, text) 改成 (uuid):理由取申请上那一句。
--   ④ 等待期间冻住(Q4):保存拒 PAYROLL_REQUEST_OPEN;那个月的考勤不许重开;批准与执行各比一次
--      snapshot(PAYROLL_CHANGED_SINCE_REQUEST)。
--   ⑤ 三扇侧门(Q5):直连写 status / 过账列 → PAYROLL_STATUS_THROUGH_FUNCTION_ONLY;
--      已过账或在等批的期间,直连写它的行与被批的数 → PAYROLL_LINES_FROZEN;
--      reverse_journal_entry 冲工资过账分录(或它的冲销)→ JE_REVERSE_USE_SOURCE_PATH。
--   ⑥ 挂着撤销申请时,三支付款函数按名拒(Q6,PAYROLL_REVERSAL_REQUESTED)。
--   ⑦ 引擎登记(Q8):approval_chain_gates 一行(二级,module.hr.view + data.view_pay);
--      approval_pending_documents 一支(blocks_disable、fixed_level = 2、主角 NULL);
--      approval_log 的主体类型与读策略各加 payroll_request;record_approval_decision 一支
--      (金额 = gross 折本位币,N4);operations_now 一支 payroll_request_pending(data.view_pay)。
--
-- 【不做什么】不新增任何权限码(Q8),所以"新码同时授给 admin"那条常设裁定这一刀无码可授;
-- 不碰 role_permissions、user_roles、审批开关与策略;不写任何业务行。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;在途单据一张不少、一张不多;
-- approval_log、journal_entries、工资期与工资行一行没变;授权一条没变;每一张在途单据都还有一个
-- 【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

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
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')"""

parts = [HEADER]

parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.payroll_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PRE|payroll_requests already exists';
    END IF;
    IF to_regprocedure('public.unpost_payroll_period(uuid, text)') IS NULL THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PRE|unpost_payroll_period(uuid, text) is not the live signature';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname IN ('trg_payroll_periods_direct_write',
                                                        'trg_payroll_lines_direct_write')) THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PRE|a PAYROLL-APR-1 trigger already exists';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE pa1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE pa1_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log, (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM payroll_periods WHERE status = 'posted') AS periods_posted,
       (SELECT count(*) FROM payroll_periods WHERE status = 'draft') AS periods_draft,
       (SELECT count(*) FROM payroll_lines) AS lines,
       (SELECT count(*) FROM payroll_lines WHERE paid_at IS NOT NULL) AS lines_paid;
CREATE TEMP TABLE pa1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
""")

# ── 1 · 表 ───────────────────────────────────────────────────────────────────
t = mirror("db/tables/payroll_requests.sql")
parts.append("\n-- ── 1 · payroll_requests(镜像原样)──────────────────────────────────────────\n")
parts.append(t[t.index("CREATE TABLE public.payroll_requests"):])

# ── 2 · approval_log:主体类型 + 读策略 ─────────────────────────────────────────
al = mirror("db/tables/approval_log.sql")
i = al.index("subject_type        text NOT NULL CHECK (subject_type IN (")
j = al.index("'payroll_request')),", i) + len("'payroll_request'))")
check_body = al[i + len("subject_type        text NOT NULL "):j]
parts.append("\n-- ── 2 · approval_log:主体类型加 payroll_request;读策略加同名一支 ────────────\n")
parts.append("ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;\n")
parts.append("ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check\n    "
             + check_body + ";\n")
parts.append('DROP POLICY "approval_log select by permission" ON public.approval_log;\n')
parts.append(stmt("db/tables/approval_log.sql", 'CREATE POLICY "approval_log select by permission"'))

# ── 3 · 函数 ─────────────────────────────────────────────────────────────────
parts.append("\n-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────\n")
for name in ["payroll_period_fingerprint", "payroll_period_frozen",
             "post_payroll_period_internal", "unpost_payroll_period_internal", "payroll_request_dry_run",
             "post_payroll_period"]:
    parts.append(fn(name))
parts.append("\n-- 旧签名 (uuid, text) 退场:理由取申请上那一句(见 unpost_payroll_period 抬头)\n"
             "DROP FUNCTION public.unpost_payroll_period(uuid, text);\n")
for name in ["unpost_payroll_period", "submit_payroll_request", "withdraw_payroll_request", "decide_payroll_request",
             "upsert_payroll_period", "reopen_attendance_period",
             "pay_payroll_lines", "pay_payroll_cpf", "pay_payroll_deductions", "reverse_journal_entry",
             "record_approval_decision", "approval_pending_documents", "approval_chain_gates",
             "guard_payroll_period_direct_write", "guard_payroll_line_direct_write"]:
    parts.append(fn(name))

# ── 4 · 两扇侧门的触发器 ──────────────────────────────────────────────────────
parts.append("\n-- ── 4 · 侧门(Q5):两张表各一支 BEFORE 行级守卫 ───────────────────────────────\n")
parts.append(stmt("db/tables/payroll_periods.sql", "CREATE TRIGGER trg_payroll_periods_direct_write\n"))
parts.append(stmt("db/tables/payroll_lines.sql", "CREATE TRIGGER trg_payroll_lines_direct_write\n"))

# ── 5 · operations_now ───────────────────────────────────────────────────────
v = mirror("db/views/operations_now.sql")
i = v.index("CREATE VIEW public.operations_now AS")
j = v.index("\n\nGRANT SELECT ON public.operations_now", i)
view = v[i:j].rstrip().rstrip(";") + ";\n"
parts.append("\n-- ── 5 · operations_now:加一支 payroll_request_pending(镜像原样)────────────────\n")
parts.append(view.replace("CREATE VIEW public.operations_now AS", "CREATE OR REPLACE VIEW public.operations_now AS", 1))

# ── 6 · 自证 ─────────────────────────────────────────────────────────────────
b1 = mirror("db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql")
start = b1.index("CREATE FUNCTION pg_temp.role1_pending_decider_check")
dec = b1[start:b1.index("$f$;", start) + 4].replace("role1_pending_decider_check", "pa1_pending_decider_check")
parts.append("\n-- ── 6 · 自证 ──────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE pa1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一条没变(本刀不新增、不收回任何码)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM pa1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM pa1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'PAYROLLAPR1_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、工资期与工资行一行没变;申请表是空的
    IF EXISTS ((SELECT b.k, b.id FROM pa1_pending_before b EXCEPT SELECT a.k, a.id FROM pa1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM pa1_pending_after a EXCEPT SELECT b.k, b.id FROM pa1_pending_before b)) THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT (approval_log, journal_entries, periods_posted, periods_draft, lines, lines_paid) FROM pa1_counts_before)
       IS DISTINCT FROM
       (SELECT ((SELECT count(*) FROM approval_log), (SELECT count(*) FROM journal_entries),
                (SELECT count(*) FROM payroll_periods WHERE status = 'posted'),
                (SELECT count(*) FROM payroll_periods WHERE status = 'draft'),
                (SELECT count(*) FROM payroll_lines),
                (SELECT count(*) FROM payroll_lines WHERE paid_at IS NOT NULL))) THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PROOF|a business row count changed';
    END IF;
    IF EXISTS (SELECT 1 FROM payroll_requests) THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PROOF|payroll_requests is not empty';
    END IF;

    -- ④ 结构:旧签名已退场;两支守卫挂上;链的名册一行、只有二级
    IF to_regprocedure('public.unpost_payroll_period(uuid, text)') IS NOT NULL
       OR to_regprocedure('public.unpost_payroll_period(uuid)') IS NULL THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PROOF|unpost_payroll_period signature';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE tgname IN ('trg_payroll_periods_direct_write',
                                                             'trg_payroll_lines_direct_write');
    IF v_n <> 2 THEN RAISE EXCEPTION 'PAYROLLAPR1_PROOF|expected 2 guard triggers, got %', v_n; END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'payroll_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PROOF|payroll_request chain row';
    END IF;

    -- ⑤ 二级这条新链此刻有人批得了(开着的审批不许因为一条新链而变成"开着却没人能批")
    SELECT count(*) INTO v_n FROM approval_deciders('payroll_request', 'decide_payroll_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'PAYROLLAPR1_PROOF|nobody can decide a payroll request'; END IF;

    -- ⑥ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.pa1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'PAYROLLAPR1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.pa1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.pa1_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.pa1_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
