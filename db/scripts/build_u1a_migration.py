#!/usr/bin/env python3
"""U1-A(UNBLOCK-1 的第一刀,v1.4.35):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影。
函数与视图原样从 db/functions、db/views 抽出;表上的改动(策略、列授权、种子行)在这里逐句写出,
并与 db/tables 里改过的那几处逐字同义(check_mirrors 在重建侧对照)。
跑法:python3 db/scripts/build_u1a_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-05-u1a-pay-and-personal-data.sql"

ADMIN = "321f1819-8449-48f7-9ae0-78b2c4b50f35"     # admin@swm-os.test(admin)
TIM = "634c00f9-c3a9-4444-9eed-b624cb6a2a93"       # tim@evoltrya.test(cfo,持 data.view_pay)
PHUA = "e61d99f2-2b95-4059-86f8-5aef8b5cffb5"      # phua@(cto:finance.view + hr.view,不持 view_pay / view_health)
CHOOER = "476bf8c8-c248-4352-9a75-945bf52ca390"    # chooer@(finance:持 view_pay,本迁移起持 view_health)
FUSHENG = "c8116e6c-80db-4a16-be12-24fb6ce6859d"   # fusheng@(warehouse:processing.view,不持 finance.view / hr.view)

NEW_FUNCS_FIRST = ["approval_log_readable", "approval_log_amount_visible"]
FUNCS = ["change_log_rule_visible", "change_log_mask_rules", "trail_row_visible",
         "change_log_redactable_columns", "change_log_redact_employee", "anonymise_employee",
         "account_ledger", "bank_book_balance_asof", "trial_balance_totals", "journal_close_preview",
         "journal_export_lines", "medical_claim_balance"]
NEW_VIEWS = ["journal_lines_masked", "approval_log_masked", "medical_claims_masked", "leave_requests_masked",
             "payroll_periods_masked", "payroll_requests_masked"]
REPLACED_VIEWS = ["employees_masked", "medical_claim_status", "equipment_maintenance_advice",
                  "bank_unmatched_journal_lines", "fx_rate_gaps", "fx_month_end_readiness"]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def view(name, replace):
    body = (ROOT / f"db/views/{name}.sql").read_text().rstrip("\n") + "\n"
    if replace:
        assert "CREATE VIEW public." in body or "CREATE OR REPLACE VIEW public." in body, name
        body = body.replace("CREATE VIEW public.", "CREATE OR REPLACE VIEW public.", 1)
    return "\n" + body


HEADER = """-- db/migrations/2026-10-05-u1a-pay-and-personal-data.sql
-- U1-A —— 工资与个人数据按角色收口(UNBLOCK-1 的第一刀,v1.4.35;发布那一行在 docs/handbacks/U1-A.md 的抬头)。
-- 由 db/scripts/build_u1a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-05:Step 0 的 Q1–Q13 全部照建议裁定;Q14–Q26 归 U1-B)
--   ① 工资分录(Q1–Q3):source_type = 'payroll' 的分录每一行,金额只给持 data.view_pay 的人 ——
--      journal_lines 上一条 restrictive 策略关 API;journal_lines_masked 给页面"行在、金额受限";
--      会悄悄少掉那几行的读法改成属主汇总(trial_balance_totals · journal_close_preview · journal_export_lines ·
--      bank_book_balance_asof)或属主视图(bank_unmatched_journal_lines · fx_rate_gaps · fx_month_end_readiness),account_ledger 逐行遮金额。
--   ② KPI(Q5):拿掉 kpi_entries 的本人自读策略 —— 本人只经 my_kpi_entries 读(分数在关轮之后)。
--   ③ 人事备注(Q6):employees.notes / separation_notes 从列授权拿掉,employees_masked 只给 module.hr.view(不对本人让路)。
--   ④ 健康数据(Q8):新码 data.view_health(admin · hr · cco · cfo · finance);医疗报销的事由与金额、请假的事由 · 病假单号 · 例外理由
--      只经 medical_claims_masked / leave_requests_masked / medical_claim_status 读,对本人让路;医疗额度(已用额 = 金额之和)的门
--      medical_claim_balance 从 module.hr.view 收成 data.view_health(或本人)。
--   ⑤ 工资期合计与工资申请(Q9 · Q10):五个合计、快照、合计与本位币金额要 data.view_pay(payroll_periods_masked · payroll_requests_masked);
--      审批留痕上抄着同样的数 —— approval_log 的金额两列只经 approval_log_masked 读(读规则抽成 approval_log_readable,一份定义)。
--   ⑥ 匿名化(Q11):再擦四张表上人写的字(调薪申请 · 工资行 · 请假单 · 医疗报销),金额不动;记录那一侧同一份名单。
--   ⑦ 工资单的币种(Q12):my_period_labels() 多一列 currency(返回表变了 → DROP 再 CREATE)。
--   ⑧ 设备保养建议(Q13):维修花费、机器成本与两者之比只给 module.finance.view。
--   ⑨ 审计记录(Q1 的"受限,不是 0.00"):change_log_mask_rules 多 20 行(81 → 101)、两种新规则写法(pay_journal · apr_amount);
--      trail_row_visible 不把 "amounts:" 开头的 restrictive 策略接进行判据 —— 审计记录跟屏幕走。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与名册;不写任何业务行;不动任何一张单据。
--   唯一的数据写入:permissions 一行(data.view_health)+ role_permissions 五行(admin · hr · cco · cfo · finance)
--   + document_types 三行的搜索列与名字列(Q6 · Q8:搜索不许匹配被遮的列)。
--
-- 【破窗】从这一支提交到部署之间,旧应用读新库:
--   · /finance/trial-balance · /finance/close 仍逐行拉 journal_lines —— 对 cto · gm(不持 view_pay)会少掉工资分录那几行(合计变小;
--     他们两人的试算表仍"平",因为工资分录自己借贷相等)。持 view_pay 的人不受影响。
--   · /hr/payroll · /hr/payroll/[id] 选了被收回的合计列 → 42501(页面报错)直到部署;/hr/leave/[id] select('*') 同样 42501。
--   · /finance/journal/[id] 对 cto · gm 的工资分录:行表为空(旧页面读基表);/finance/journal/export 对他们少掉那几行。
--   · /me 调 my_period_labels() 旧的四列读法照常(多一列不影响 select *;旧页面没有读 currency)。
--   · 窗口在部署那一刻闭合;部署是 Tim 在 Vercel 上看的。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权只多那五行;在途单据一张不少、一张不多;change_log 只多
--   permissions / role_permissions 那几行;七个账号一个都没被停;遮蔽名单与目录对得上(change_log_mask_gaps 零缺口);
--   并以五个真账号的身份把每一条规则读一遍(被拒或读错 = 坏了),每一张在途单据仍有一个不是它当事人的决定人。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'U1A_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code = 'data.view_health') THEN
        RAISE EXCEPTION 'U1A_PRE|data.view_health already exists';
    END IF;
    IF to_regclass('public.journal_lines_masked') IS NOT NULL THEN
        RAISE EXCEPTION 'U1A_PRE|journal_lines_masked already exists';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'kpi_entries'
                      AND policyname = 'kpi_entries select own') THEN
        RAISE EXCEPTION 'U1A_PRE|the kpi_entries self-read policy is not there to drop';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND permissive = 'RESTRICTIVE') <> 0 THEN
        RAISE EXCEPTION 'U1A_PRE|expected no restrictive policy before this migration';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 81 THEN
        RAISE EXCEPTION 'U1A_PRE|expected 81 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM roles WHERE code IN ('admin', 'hr', 'cco', 'cfo', 'finance')) <> 5 THEN
        RAISE EXCEPTION 'U1A_PRE|one of admin · hr · cco · cfo · finance is missing';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE u1a_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE u1a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE u1a_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
-- 账面上的数,以属主身份读(工资分录也在内):文末以 cto 的身份经新读法读回,必须逐分相同
CREATE TEMP TABLE u1a_tb_before ON COMMIT DROP AS
SELECT l.account_id, sum(l.debit) AS debits, sum(l.credit) AS credits FROM journal_lines l GROUP BY l.account_id;
CREATE TEMP TABLE u1a_bank_before ON COMMIT DROP AS
SELECT a.code, (SELECT round(COALESCE(sum(CASE WHEN jl.debit > 0 THEN jl.amount_ccy ELSE -jl.amount_ccy END), 0), 2)
                  FROM journal_lines jl JOIN accounts ac ON ac.id = jl.account_id
                 WHERE ac.code = a.code AND jl.currency = bank_native_currency(a.code)) AS book
  FROM (VALUES ('1000'), ('1010')) a(code);
-- 文末以真账号的身份(SET ROLE authenticated)拿新读法与这两张比 —— 临时表只在这笔事务里,授给 authenticated 读,随事务消失
GRANT SELECT ON u1a_tb_before, u1a_bank_before TO authenticated;
""")

parts.append("""
-- ── 1 · 新码 data.view_health(Q8)与它的五行授权 ──────────────────────────
-- 种子行与 db/tables/permissions.sql 逐字相同;授权按常设裁定(admin 持每一个码)+ Tim 的 Q8(hr · cco · cfo · finance)。
-- RUNTIME CONFIG 引导(db/tables/role_permissions.sql)只认得它自己那几个角色:finance 与 hr 的引导名单里加了这一码 ——
--   引导默认值【仍然正确】(意思没有变:决定 HR 申请的人看得见健康数据;admin · cco · cfo 不在引导里,只在线上)。
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('data.view_health', 'data', 'View health details', '查看健康信息', 'Medical-claim descriptions and amounts, and the reasons, certificate references and exception reasons on leave requests. Everyone still sees their own.', '医疗报销的事由与金额,以及请假单上的事由、病假单号与例外理由。每个人照旧看得见自己的。', 215);
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'data.view_health' FROM roles r WHERE r.code IN ('admin', 'hr', 'cco', 'cfo', 'finance')
ON CONFLICT DO NOTHING;
""")

parts.append("\n-- ── 2 · approval_log 的读规则与金额判据(新函数;镜像原样)── 策略要先有它们 ─────────────\n")
for name in NEW_FUNCS_FIRST:
    parts.append(fn(name))

parts.append("""
-- ── 3 · 表:策略与列授权(与 db/tables 下改过的几处逐字同义)────────────────────────

-- journal_lines(Q1 · Q2):工资分录的行,只给持 data.view_pay 的人经 API 读
CREATE POLICY "amounts: payroll journal lines need data.view_pay"
    ON public.journal_lines
    AS RESTRICTIVE FOR SELECT TO authenticated
    USING (has_permission('data.view_pay'::text)
           OR NOT EXISTS (SELECT 1 FROM public.journal_entries e
                           WHERE e.id = journal_lines.entry_id AND e.source_type = 'payroll'));

-- kpi_entries(Q5):拿掉本人自读
DROP POLICY "kpi_entries select own" ON public.kpi_entries;

-- approval_log(Q8 · Q10):读规则换成同一支函数;金额两列从列授权里拿掉
DROP POLICY "approval_log select by permission" ON public.approval_log;
CREATE POLICY "approval_log select by permission"
    ON public.approval_log
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (approval_log_readable(subject_type));
REVOKE SELECT ON public.approval_log FROM authenticated, anon;
GRANT SELECT (id, seq, subject_type, subject_id, subject_code, decision, level,
              actor_user_id, decided_at, note, currency, fx_rate,
              is_reconstructed, reconstruction_note, created_at,
              self_decided)
    ON public.approval_log TO authenticated;

-- employees(Q6):人事备注从列授权里拿掉
REVOKE SELECT ON public.employees FROM authenticated, anon;
GRANT SELECT (id, code, legal_name, preferred_name, department_id, position_id, manager_id, employment_type, work_category, hire_date, probation_end_date, employment_status, separation_date, separation_type, residency_status, work_pass_type, work_pass_issue_date, work_pass_expiry_date, user_id, deleted_at, created_at, created_by, updated_at, updated_by, confirmation_date, monthly_salary_set, review_exempt, anonymised_at, anonymised_by, greeting_name, is_site_staff, first_name, last_name)
    ON public.employees TO authenticated;

-- medical_claims(Q8):事由与金额从列授权里拿掉
REVOKE SELECT ON public.medical_claims FROM authenticated, anon;
GRANT SELECT (id, code, employee_id, claim_date, claim_year, receipt_ref, status, decided_at, decided_by, decision_notes,
              expense_id, deleted_at, created_at, created_by, updated_at, updated_by, withdrawn_at)
    ON public.medical_claims TO authenticated;

-- leave_requests(Q8):事由 · 病假单号 · 例外理由从列授权里拿掉
REVOKE SELECT ON public.leave_requests FROM authenticated, anon;
GRANT SELECT (id, code, employee_id, leave_type_code, start_date, end_date, start_half_day, end_half_day, days,
              status, decided_at, decided_by, decision_notes, deleted_at, created_at, created_by, updated_at, updated_by,
              is_exception)
    ON public.leave_requests TO authenticated;

-- payroll_periods(Q9):五个合计从列授权里拿掉
REVOKE SELECT ON public.payroll_periods FROM authenticated, anon;
GRANT SELECT (id, code, period_month, payment_date, currency, fx_rate, status, journal_entry_id, source_note, notes,
              deleted_at, created_at, created_by, updated_at, updated_by, cpf_paid_at, cpf_journal_entry_id,
              deductions_paid_at, deductions_journal_entry_id)
    ON public.payroll_periods TO authenticated;

-- document_types(Q6 · Q8):搜索列与名字列不能是被遮的列(fixture 100/8 · 199F 的判据)—— 与 db/tables/document_types.sql 的种子行逐字相同
UPDATE public.document_types SET match_columns = ARRAY['legal_name', 'preferred_name']::text[] WHERE key = 'employee';
UPDATE public.document_types SET label_column = NULL, match_columns = ARRAY['decision_notes']::text[] WHERE key = 'leave_request';
UPDATE public.document_types SET label_column = NULL, match_columns = ARRAY['receipt_ref', 'decision_notes']::text[] WHERE key = 'medical_claim';

-- payroll_requests(Q10):快照、合计与本位币金额从列授权里拿掉
REVOKE SELECT ON public.payroll_requests FROM authenticated;
GRANT SELECT (id, payroll_period_id, kind, status, label, currency, fx_rate, notes, decided_at, decided_by, decision_notes,
              withdrawn_at, withdrawn_by, executed_at, executed_by, result_journal_entry_id, created_at, created_by)
    ON public.payroll_requests TO authenticated;
""")

parts.append("\n-- ── 4 · 遮蔽规则、记录的读法、匿名化与几支读法(镜像原样)──────────────────────────\n")
for name in FUNCS:
    parts.append(fn(name))

parts.append("""
-- ── 5 · my_period_labels(Q12):返回表多一列 currency → DROP 再 CREATE(镜像原样)────────────────
DROP FUNCTION public.my_period_labels();
""")
parts.append(fn("my_period_labels"))
parts.append("""
REVOKE EXECUTE ON FUNCTION public.my_period_labels() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_period_labels() TO authenticated, service_role;
""")

parts.append("\n-- ── 6 · 新的遮蔽伴生视图(镜像原样)────────────────────────────────────────\n")
for name in NEW_VIEWS:
    parts.append(view(name, False))
parts.append("\n-- ── 7 · 改过的视图(镜像原样,CREATE OR REPLACE)───────────────────────────\n")
for name in REPLACED_VIEWS:
    parts.append(view(name, True))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "u1a_pending_decider_check")
parts.append("\n-- ── 8 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")


def as_user(uid):
    return f"""PERFORM set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true);"""


parts.append(f"""
CREATE TEMP TABLE u1a_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_m     int;
    v_x     numeric;
    v_y     numeric;
    v_b     boolean;
    v_t     text;
    v_j     jsonb;
    v_je    uuid;
    v_mc    uuid;
    k       text;
BEGIN
    -- ① 授权:只多 data.view_health 那五行
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM u1a_grants_before)
        EXCEPT SELECT unnest(ARRAY['admin:data.view_health', 'hr:data.view_health', 'cco:data.view_health',
                                   'cfo:data.view_health', 'finance:data.view_health'])) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'U1A_PROOF|unexpected new grants: %', v_bad; END IF;
    SELECT string_agg(x, ', ') INTO v_bad FROM (
        SELECT role_code || ':' || permission_code AS x FROM u1a_grants_before
        EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'U1A_PROOF|grants removed: %', v_bad; END IF;
    IF (SELECT count(*) FROM role_permissions WHERE permission_code = 'data.view_health') <> 5 THEN
        RAISE EXCEPTION 'U1A_PROOF|data.view_health should be held by exactly 5 roles';
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'U1A_PROOF|approvals switched off'; END IF;
    IF (SELECT count(*) FROM auth.users WHERE banned_until IS NOT NULL AND banned_until > now()) <> 0 THEN
        RAISE EXCEPTION 'U1A_PROOF|an account is disabled';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 只多 permissions / role_permissions 那几行
    IF EXISTS ((SELECT b.k, b.id FROM u1a_pending_before b EXCEPT SELECT a.k, a.id FROM u1a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM u1a_pending_after a EXCEPT SELECT b.k, b.id FROM u1a_pending_before b)) THEN
        RAISE EXCEPTION 'U1A_PROOF|a pending document changed state';
    END IF;
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM u1a_log_before) AND c.table_name NOT IN ('permissions', 'role_permissions', 'document_types');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'U1A_PROOF|change_log moved on %', v_bad; END IF;

    -- ④ 形状:遮蔽名单与目录对得上;101 条规则;恰好一条 restrictive 策略;kpi 自读策略不在
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN RAISE EXCEPTION 'U1A_PROOF|mask gaps: %', v_j -> 'gaps'; END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 101 THEN
        RAISE EXCEPTION 'U1A_PROOF|expected 101 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND permissive = 'RESTRICTIVE') <> 1 THEN
        RAISE EXCEPTION 'U1A_PROOF|expected exactly one restrictive policy';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'kpi_entries' AND policyname = 'kpi_entries select own') THEN
        RAISE EXCEPTION 'U1A_PROOF|the kpi_entries self-read policy survived';
    END IF;

    -- ⑤ 真的读,以真账号的身份。工资分录:线上有(PAY-2026-0001 那四张)
    SELECT e.id INTO v_je FROM journal_entries e WHERE e.source_type = 'payroll' ORDER BY e.created_at LIMIT 1;
    IF v_je IS NULL THEN RAISE EXCEPTION 'U1A_PROOF|no payroll journal on live to read'; END IF;

    -- ⑤a cto(phua@):API 上工资分录的行不在;遮蔽视图里行在、金额受限、行摘要在;合计与银行余额与属主身份读的逐分相同
    {as_user(PHUA)}
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM journal_lines l WHERE l.entry_id = v_je;
    SELECT count(*), count(*) FILTER (WHERE m.debit IS NULL AND m.credit IS NULL AND m.amount_ccy IS NULL AND m.amounts_restricted),
           count(m.line_memo) FILTER (WHERE m.line_memo IS NOT NULL)
      INTO v_m, k, v_t FROM journal_lines_masked m WHERE m.entry_id = v_je;
    SELECT count(*) INTO v_x FROM (
        (SELECT t.account_id, t.debits, t.credits FROM trial_balance_totals() t
         EXCEPT SELECT b.account_id, b.debits, b.credits FROM u1a_tb_before b)
        UNION ALL
        (SELECT b.account_id, b.debits, b.credits FROM u1a_tb_before b
         EXCEPT SELECT t.account_id, t.debits, t.credits FROM trial_balance_totals() t)) d;
    SELECT count(*) INTO v_y FROM u1a_bank_before b WHERE bank_book_balance_asof(b.code, '2999-12-31'::date) IS DISTINCT FROM b.book;
    EXECUTE 'RESET ROLE';
    IF v_n <> 0 THEN RAISE EXCEPTION 'U1A_PROOF|cto reads % payroll journal line(s) through the API', v_n; END IF;
    IF v_m = 0 OR k::int <> v_m THEN RAISE EXCEPTION 'U1A_PROOF|cto: masked view lines % · restricted %', v_m, k; END IF;
    IF v_x <> 0 THEN RAISE EXCEPTION 'U1A_PROOF|cto: trial_balance_totals differs from the owner reading on % account(s)', v_x; END IF;
    IF v_y <> 0 THEN RAISE EXCEPTION 'U1A_PROOF|cto: bank_book_balance_asof differs on % bank account(s)', v_y; END IF;
    RAISE NOTICE 'U1A cto: API payroll lines 0 · masked view % line(s) all Restricted, % with a memo · trial balance and bank book identical', v_m, v_t;

    -- ⑤b cfo(tim@):工资分录的行在,金额在
    {as_user(TIM)}
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM journal_lines l WHERE l.entry_id = v_je;
    SELECT count(*) INTO v_m FROM journal_lines_masked m WHERE m.entry_id = v_je AND NOT m.amounts_restricted AND m.debit IS NOT NULL;
    EXECUTE 'RESET ROLE';
    IF v_n = 0 OR v_m <> v_n THEN RAISE EXCEPTION 'U1A_PROOF|cfo: API % · masked view with amounts %', v_n, v_m; END IF;

    -- ⑤c 工资期合计 · 工资申请 · 医疗报销 · 请假单:cto 受限,finance(chooer@)看得见
    {as_user(PHUA)}
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM payroll_periods_masked WHERE gross_total IS NOT NULL OR net_pay_total IS NOT NULL;
    SELECT count(*) INTO v_m FROM medical_claims_masked WHERE description IS NOT NULL AND employee_id <> current_user_employee();
    SELECT count(*) INTO v_x FROM leave_requests_masked WHERE reason IS NOT NULL AND employee_id <> current_user_employee();
    SELECT count(*) INTO v_y FROM medical_claim_status WHERE description IS NOT NULL AND employee_id <> current_user_employee();
    EXECUTE 'RESET ROLE';
    IF v_n + v_m + v_x + v_y <> 0 THEN
        RAISE EXCEPTION 'U1A_PROOF|cto still reads pay totals % · medical text % · leave reasons % · claim status text %', v_n, v_m, v_x, v_y;
    END IF;
    BEGIN
        {as_user(PHUA)}
        EXECUTE 'SET LOCAL ROLE authenticated';
        PERFORM gross_total FROM payroll_periods LIMIT 1;
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'U1A_PROOF|cto selected payroll_periods.gross_total from the base table';
    EXCEPTION WHEN insufficient_privilege THEN
        EXECUTE 'RESET ROLE';
    END;
    {as_user(CHOOER)}
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM payroll_periods_masked WHERE gross_total IS NOT NULL;
    SELECT count(*) INTO v_m FROM medical_claims_masked WHERE description IS NOT NULL;
    EXECUTE 'RESET ROLE';
    IF v_n <> (SELECT count(*) FROM payroll_periods) OR v_m <> (SELECT count(*) FROM medical_claims WHERE description IS NOT NULL) THEN
        RAISE EXCEPTION 'U1A_PROOF|finance reads pay totals % · medical text %', v_n, v_m;
    END IF;

    -- ⑤d 设备保养建议:仓库(fusheng@)读得到记录、读不到钱;cfo 读得到钱
    {as_user(FUSHENG)}
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*), count(*) FILTER (WHERE work_cost_base IS NOT NULL OR equipment_cost_base IS NOT NULL OR pct_of_equipment_cost IS NOT NULL)
      INTO v_n, v_m FROM equipment_maintenance_advice;
    EXECUTE 'RESET ROLE';
    IF v_m <> 0 THEN RAISE EXCEPTION 'U1A_PROOF|warehouse reads % costed advice row(s)', v_m; END IF;
    RAISE NOTICE 'U1A warehouse: % maintenance advice row(s), no cost on any', v_n;

    -- ⑤e 审计记录的两道判据(线上的工资分录早于变更记录 2026-09-28,所以这里问判据本身;整条记录在 fixture 247 里走):
    --     cto 那一行【不被藏】(trail_row_visible 不接 "amounts:" 策略)、金额【受限】(pay_journal 规则);cfo 两样都看得见
    SELECT l.id INTO v_mc FROM journal_lines l WHERE l.entry_id = v_je LIMIT 1;
    {as_user(PHUA)}
    v_b := trail_row_visible('journal_lines', jsonb_build_object('id', v_mc), NULL)
           AND NOT change_log_rule_visible('pay_journal:data.view_pay', 'journal_lines', jsonb_build_object('id', v_mc), NULL,
                                           jsonb_build_object('entry_id', v_je));
    IF NOT v_b THEN RAISE EXCEPTION 'U1A_PROOF|cto trail: the payroll line should be visible with its amounts restricted'; END IF;
    {as_user(TIM)}
    v_b := trail_row_visible('journal_lines', jsonb_build_object('id', v_mc), NULL)
           AND change_log_rule_visible('pay_journal:data.view_pay', 'journal_lines', jsonb_build_object('id', v_mc), NULL,
                                       jsonb_build_object('entry_id', v_je));
    IF NOT v_b THEN RAISE EXCEPTION 'U1A_PROOF|cfo trail: the payroll line and its amounts should be visible'; END IF;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑤f my_period_labels():每一个绑着员工档案的账号都调得了,只拿到自己的期间;工资单那几行带币种
    v_m := 0;
    FOR v_t, v_mc IN SELECT e.user_id::text, e.id FROM employees e WHERE e.user_id IS NOT NULL AND e.deleted_at IS NULL LOOP
        PERFORM set_config('request.jwt.claims', format('{{"sub":"%s","role":"authenticated"}}', v_t), true);
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT count(*) INTO v_n FROM my_period_labels() x
             WHERE (x.kind = 'payroll' AND x.currency IS NULL)
                OR (NOT EXISTS (SELECT 1 FROM attendance_lines al WHERE al.period_id = x.period_id AND al.employee_id = v_mc)
                    AND NOT EXISTS (SELECT 1 FROM payroll_lines pl WHERE pl.payroll_period_id = x.period_id AND pl.employee_id = v_mc));
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            RAISE EXCEPTION 'U1A_PROOF|my_period_labels() refused for %: %', v_t, SQLERRM;
        END;
        IF v_n <> 0 THEN RAISE EXCEPTION 'U1A_PROOF|my_period_labels() returned % wrong row(s) for %', v_n, v_t; END IF;
        v_m := v_m + 1;
    END LOOP;
    RAISE NOTICE 'U1A my_period_labels() called as % linked account(s)', v_m;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.u1a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'U1A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.u1a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'U1A_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.u1a_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
