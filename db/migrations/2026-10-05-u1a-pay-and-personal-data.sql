-- db/migrations/2026-10-05-u1a-pay-and-personal-data.sql
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

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE u1a_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
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
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';
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

-- ── 1 · 新码 data.view_health(Q8)与它的五行授权 ──────────────────────────
-- 种子行与 db/tables/permissions.sql 逐字相同;授权按常设裁定(admin 持每一个码)+ Tim 的 Q8(hr · cco · cfo · finance)。
-- RUNTIME CONFIG 引导(db/tables/role_permissions.sql)只认得它自己那几个角色:finance 与 hr 的引导名单里加了这一码 ——
--   引导默认值【仍然正确】(意思没有变:决定 HR 申请的人看得见健康数据;admin · cco · cfo 不在引导里,只在线上)。
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('data.view_health', 'data', 'View health details', '查看健康信息', 'Medical-claim descriptions and amounts, and the reasons, certificate references and exception reasons on leave requests. Everyone still sees their own.', '医疗报销的事由与金额,以及请假单上的事由、病假单号与例外理由。每个人照旧看得见自己的。', 215);
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'data.view_health' FROM roles r WHERE r.code IN ('admin', 'hr', 'cco', 'cfo', 'finance')
ON CONFLICT DO NOTHING;

-- ── 2 · approval_log 的读规则与金额判据(新函数;镜像原样)── 策略要先有它们 ─────────────

-- db/functions/approval_log_readable.sql
-- U1-A(UNBLOCK-1 Q8 · Q10,2026-10-05):approval_log 的【读规则】,从那条策略的 CASE 里原样抽出来 ——
--   基表的 "approval_log select by permission" 与新的 approval_log_masked 视图调【同一支】函数,于是"谁看得见哪一类留痕"
--   只有一份定义(属主视图绕过 RLS,视图里必须重写一遍行谓词;重写一遍就是两份,两份必然漂开)。
-- 【逐字搬过来,一支都没改】每一支的来历注释留在 db/tables/approval_log.sql 那条策略的上方。
-- 【不是 SECURITY DEFINER】它只读 has_permission();RLS 求值要它对 authenticated 可执行。
CREATE OR REPLACE FUNCTION public.approval_log_readable(p_subject_type text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_subject_type
        WHEN 'leave_request'          THEN has_permission('module.hr.view'::text)
        WHEN 'medical_claim'          THEN has_permission('module.hr.view'::text)
        WHEN 'performance_review'     THEN has_permission('module.hr.view'::text)
        WHEN 'purchase_order'         THEN has_permission('module.purchasing.view'::text)
        WHEN 'payment'                THEN has_permission('module.finance.view'::text)
        WHEN 'expense'                THEN has_permission('module.finance.view'::text)
        WHEN 'expense_claim'          THEN has_permission('module.finance.view'::text)
        WHEN 'pricing_formula'        THEN has_permission('module.pricing.view'::text)
        WHEN 'stocktake'              THEN has_permission('module.stocktakes.view'::text)
        WHEN 'work_order'             THEN has_permission('module.processing.view'::text)
        WHEN 'payment_request'        THEN has_permission('module.finance.view'::text)
        WHEN 'supplier'               THEN has_permission('module.suppliers.view'::text)
        WHEN 'payroll_request'        THEN has_permission('module.hr.view'::text)
        WHEN 'receipt_price_request'  THEN has_permission('module.inbound.view'::text)
                                           AND has_permission('data.view_purchase_prices'::text)
        WHEN 'invoice_request'        THEN has_permission('module.finance.view'::text)
        WHEN 'shipping_release'       THEN has_permission('module.sales.view'::text)
        WHEN 'journal_request'        THEN has_permission('module.finance.view'::text)
        WHEN 'warehouse_request'      THEN has_permission('module.finance.view'::text)
        WHEN 'terms_request'          THEN has_permission('module.pricing.view'::text)
        WHEN 'salary_change_request'  THEN has_permission('module.hr.view'::text)
                                           AND has_permission('data.view_pay'::text)
        WHEN 'asset_disposal_request' THEN has_permission('module.finance.view'::text)
        WHEN 'gst_filing_request'     THEN has_permission('module.finance.view'::text)
        WHEN 'overtime_batch'         THEN (has_permission('module.hr.view'::text)
                                            OR has_permission('action.overtime_enter'::text)
                                            OR has_permission('action.overtime_approve'::text))
        ELSE false
    END;
$function$;

-- db/functions/approval_log_amount_visible.sql
-- U1-A(UNBLOCK-1 Q8 · Q10,2026-10-05):approval_log 一行上的【金额】(amount_ccy · amount_base)对当前读者看不看得见。
--   record_approval_decision 把单据的金额抄进留痕:工资申请那一行是这一期的合计(一期一个人时就是一个人的工资,Q9 · Q10),
--   医疗报销那一行是报销的金额(Q8)。单据那一侧这两样已经被遮(payroll_requests_masked · medical_claims_masked),
--   留痕这一侧不跟着遮,同一个数就从另一扇门出去了。
-- 【判据,一支对一个单据种类,与那张单据自己的遮蔽逐字同一个】
--   payroll_request → data.view_pay(payroll_requests_masked 的 gross_total / amount_base)
--   medical_claim   → data.view_health,或那一张报销单就是读者本人的(medical_claims_masked 的 amount_sgd)
--   其余种类         → true(本刀不动它们;仓库申请那一支由 approval_log_readable 只给财务,AT1B-WAREHOUSE-APPROVALS-FINANCE-ONLY)
-- 【两个读者,一份判据】approval_log_masked 的 CASE 与 change_log_rule_visible 的 apr_amount 规则都调这一支。
-- 【不是 SECURITY DEFINER】"本人的报销单"那一问读 medical_claims.employee_id(列授权里有),
--   在属主视图与 DEFINER 读法里以各自的身份跑;RLS 求不到那一行的读者本来就读不到那一行留痕。
CREATE OR REPLACE FUNCTION public.approval_log_amount_visible(p_subject_type text, p_subject_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_subject_type
        WHEN 'payroll_request' THEN has_permission('data.view_pay'::text)
        WHEN 'medical_claim'   THEN has_permission('data.view_health'::text)
                                    OR EXISTS (SELECT 1 FROM medical_claims mc
                                                WHERE mc.id = p_subject_id AND mc.employee_id = current_user_employee())
        ELSE true
    END;
$function$;

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

-- ── 4 · 遮蔽规则、记录的读法、匿名化与几支读法(镜像原样)──────────────────────────

-- db/functions/change_log_rule_visible.sql
-- HISTORY-1:一条遮蔽规则(change_log_mask_rules)对【当前读者】、就【这一行记录】成不成立。
-- 与 _masked 视图里那句 CASE WHEN 逐条同一个判据;认不出的规则按【看不见】答(关着失败)。
-- ★ U1-A(UNBLOCK-1,2026-10-05)两种新写法,各自与它那张 _masked 视图里的 CASE 同一个判据:
--   pay_journal:<码>   持码,或这一行所在分录(entry_id → journal_entries.source_type)不是 'payroll'(journal_lines_masked)。
--                       分录找不到 → 看不见(关着失败;分录不可删,所以这只在影像里根本没有 entry_id 时发生)。
--   apr_amount         approval_log_amount_visible(subject_type, subject_id) —— 视图与这里调同一支函数(approval_log_masked)。
CREATE OR REPLACE FUNCTION public.change_log_rule_visible(p_rule text, p_table text, p_key jsonb, p_old jsonb, p_new jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_part text[] := string_to_array(p_rule, ':');
    v_fid  text;
BEGIN
    IF v_part[1] = 'code' THEN
        RETURN has_permission(v_part[2]);
    ELSIF v_part[1] = 'code_or_self' THEN
        RETURN has_permission(v_part[2])
            OR COALESCE(change_log_field(p_table, p_key, p_old, p_new, v_part[3]) = current_user_employee()::text, false);
    ELSIF v_part[1] = 'pay_journal' THEN
        RETURN has_permission(v_part[2])
            OR COALESCE(change_log_field('journal_entries',
                            jsonb_build_object('id', change_log_field(p_table, p_key, p_old, p_new, 'entry_id')),
                            NULL, NULL, 'source_type') <> 'payroll', false);
    ELSIF p_rule = 'apr_amount' THEN
        RETURN COALESCE(approval_log_amount_visible(change_log_field(p_table, p_key, p_old, p_new, 'subject_type'),
                                                    change_log_field(p_table, p_key, p_old, p_new, 'subject_id')::uuid), false);
    ELSIF p_rule = 'pft:direction' THEN
        RETURN pricing_formula_terms_visible(change_log_field(p_table, p_key, p_old, p_new, 'direction'));
    ELSIF p_rule IN ('pft:formula_id', 'pft3') THEN
        v_fid := change_log_field(p_table, p_key, p_old, p_new, 'formula_id');
        IF NOT pricing_formula_terms_visible(
               change_log_field('pricing_formulas', jsonb_build_object('id', v_fid), NULL, NULL, 'direction')) THEN
            RETURN false;
        END IF;
        IF p_rule = 'pft:formula_id' THEN
            RETURN true;
        END IF;
        RETURN pricing_formula_terms_visible(COALESCE(change_log_field(p_table, p_key, p_old, p_new, 'old_direction'), 'both'))
           AND pricing_formula_terms_visible(COALESCE(change_log_field(p_table, p_key, p_old, p_new, 'new_direction'), 'both'));
    END IF;
    RETURN false;
END;
$function$;

-- db/functions/change_log_mask_rules.sql
-- HISTORY-1(Tim 的 Q10 · Q7 · Q20):change_log_rows() 的遮蔽规则 —— 【一份】名单,一列一行。
--
-- 【来源】逐条抄自每一张 <表>_masked 视图里那句 CASE WHEN … THEN <列> ELSE NULL END(以 postgres
--   读 pg_get_viewdef,2026-09-28),外加本刀新建的 purchase_order_history_masked。
--   "源屏幕怎么遮,记录就怎么遮" —— 屏幕读的就是这些视图。
-- 【规则的写法】
--   code:<码>                    持这个码才看得见
--   code_or_self:<码>:<列>       持码,或那一行的 <列> 就是读者自己的员工 id(视图里的 OR id = current_user_employee())
--   pft:direction                pricing_formula_terms_visible(这一行的 direction)
--   pft:formula_id               pricing_formula_terms_visible(这一行所属公式的 direction)
--   pft3                         pricing_formula_history_masked 那三段:公式当前方向 ∧ old_direction ∧ new_direction
--   pay_journal:<码>             持码,或这一行所在分录不是工资分录(journal_lines_masked;U1-A,UNBLOCK-1 Q1)
--   apr_amount                   approval_log_amount_visible(subject_type, subject_id)(approval_log_masked;U1-A,Q8 · Q10)
-- ★ U1-A(UNBLOCK-1,2026-10-05)加了 20 行(81 → 101):工资分录的金额(Q1)· 审批留痕上的金额(Q8 · Q10)· 人事备注(Q6)·
--   健康数据(Q8)· 工资期的合计与工资申请的快照和金额(Q9 · Q10)。每一行都抄自它那张 _masked 视图里的 CASE。
-- 【它会不会和视图漂开】会 —— 所以有一道闸:change_log_mask_gaps() 拿目录里【真的被遮的列】
--   (_masked 视图里 CASE … END AS <基表的列>)与本名单逐列对,缺一条或多一条都报;
--   gate 的 changemask 那一行在线上与重建两侧各问一次,fixture 234 里注入"删掉一条"必须变红。
CREATE OR REPLACE FUNCTION public.change_log_mask_rules()
 RETURNS TABLE(table_name text, column_name text, rule text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    VALUES
        ('approval_log'::text, 'amount_ccy'::text, 'apr_amount'::text),
        ('approval_log', 'amount_base', 'apr_amount'),
        ('company_profile', 'bank_name', 'code:data.view_banking'),
        ('company_profile', 'bank_account_name', 'code:data.view_banking'),
        ('company_profile', 'bank_account_no', 'code:data.view_banking'),
        ('company_profile', 'bank_swift', 'code:data.view_banking'),
        ('company_profile', 'bank_address', 'code:data.view_banking'),
        ('employees', 'work_email', 'code_or_self:data.view_identity:id'),
        ('employees', 'work_phone', 'code_or_self:data.view_identity:id'),
        ('employees', 'identity_no', 'code_or_self:data.view_identity:id'),
        ('employees', 'work_pass_no', 'code_or_self:data.view_identity:id'),
        ('employees', 'monthly_salary', 'code_or_self:data.view_pay:id'),
        ('employees', 'notes', 'code:module.hr.view'),
        ('employees', 'separation_notes', 'code:module.hr.view'),
        ('employment_history', 'old_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('employment_history', 'new_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('inbound_batches', 'unit_price', 'code:data.view_purchase_prices'),
        ('invoice_lines', 'unit_price', 'code:data.view_prices'),
        ('invoice_lines', 'amount_base', 'code:data.view_prices'),
        ('invoice_lines', 'amount_ccy', 'code:data.view_prices'),
        ('invoice_lines', 'tax_base', 'code:data.view_prices'),
        ('invoices', 'subtotal_base', 'code:data.view_prices'),
        ('invoices', 'tax_base', 'code:data.view_prices'),
        ('invoices', 'total_base', 'code:data.view_prices'),
        ('invoices', 'fx_rate', 'code:data.view_prices'),
        ('journal_lines', 'debit', 'pay_journal:data.view_pay'),
        ('journal_lines', 'credit', 'pay_journal:data.view_pay'),
        ('journal_lines', 'amount_ccy', 'pay_journal:data.view_pay'),
        ('leave_requests', 'reason', 'code_or_self:data.view_health:employee_id'),
        ('leave_requests', 'certificate_ref', 'code_or_self:data.view_health:employee_id'),
        ('leave_requests', 'exception_reason', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'amount_sgd', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'description', 'code_or_self:data.view_health:employee_id'),
        ('payment_term_template_lines', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('payroll_lines', 'gross_pay', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'employer_cpf', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'employee_cpf', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'other_deductions', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'net_pay', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_periods', 'gross_total', 'code:data.view_pay'),
        ('payroll_periods', 'employer_cpf_total', 'code:data.view_pay'),
        ('payroll_periods', 'employee_cpf_total', 'code:data.view_pay'),
        ('payroll_periods', 'other_deductions_total', 'code:data.view_pay'),
        ('payroll_periods', 'net_pay_total', 'code:data.view_pay'),
        ('payroll_requests', 'snapshot', 'code:data.view_pay'),
        ('payroll_requests', 'gross_total', 'code:data.view_pay'),
        ('payroll_requests', 'amount_base', 'code:data.view_pay'),
        ('performance_reviews', 'new_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('prepayment_applications', 'amount_base', 'code:data.view_purchase_prices'),
        ('prepayment_applications', 'amount_ccy', 'code:data.view_purchase_prices'),
        ('price_history', 'old_unit_price', 'code:data.view_purchase_prices'),
        ('price_history', 'new_unit_price', 'code:data.view_purchase_prices'),
        ('price_history', 'original_price', 'code:data.view_purchase_prices'),
        ('price_history', 'fx_rate', 'code:data.view_purchase_prices'),
        ('pricing_formula_history', 'old_payable_pct', 'pft3'),
        ('pricing_formula_history', 'new_payable_pct', 'pft3'),
        ('pricing_formula_history', 'old_treatment_charge_usd_per_tonne', 'pft3'),
        ('pricing_formula_history', 'new_treatment_charge_usd_per_tonne', 'pft3'),
        ('pricing_formula_history', 'old_flat_discount_pct', 'pft3'),
        ('pricing_formula_history', 'new_flat_discount_pct', 'pft3'),
        ('pricing_formula_metals', 'payable_pct', 'pft:formula_id'),
        ('pricing_formulas', 'treatment_charge_usd_per_tonne', 'pft:direction'),
        ('pricing_formulas', 'flat_discount_pct', 'pft:direction'),
        ('pricing_term_commitment_metals', 'payable_pct', 'code:data.view_purchase_prices'),
        ('pricing_term_commitments', 'treatment_charge_usd_per_tonne', 'code:data.view_purchase_prices'),
        ('pricing_term_commitments', 'flat_discount_pct', 'code:data.view_purchase_prices'),
        ('processing_cost_entries', 'amount_base', 'code:data.view_prices'),
        ('processing_cost_entry_history', 'old_amount_base', 'code:data.view_prices'),
        ('processing_cost_entry_history', 'new_amount_base', 'code:data.view_prices'),
        ('processing_outputs', 'allocated_cost_base', 'code:data.view_prices'),
        ('processing_outputs', 'unit_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'material_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'process_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'total_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'capitalized_cost_base', 'code:data.view_prices'),
        ('warehouse_requests', 'amount_base', 'code:data.view_prices'),
        ('purchase_order_history', 'old_fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_payment_term', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_payment_term', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'released_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'withheld_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'price_provenance', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'tax_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_payment_terms', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'tax_total_ccy', 'code:data.view_purchase_prices'),
        ('sales_records', 'unit_price', 'code:data.view_prices'),
        ('sales_records', 'fx_rate', 'code:data.view_prices'),
        ('sales_records', 'amount_base', 'code:data.view_prices'),
        ('sales_records', 'price_provenance', 'code:data.view_prices');
$function$;

-- db/functions/trail_row_visible.sql
-- AUDIT-TRAIL-1a(Tim 的 Q4 · Q5):【当前读者】能不能读这一行 —— 按【这一行自己那张表】的读规则,不按父记录的。
--   record_trail 是 SECURITY DEFINER(change_log 对应用角色没有任何授权),而 DEFINER 里做不了 SET ROLE,
--   所以这里把那张表的 SELECT 策略(permissive 的 SELECT 与 ALL,给 authenticated 或 public 的)用 OR 拼起来,
--   对着那一行重新求一次值。这样做是对的,因为实测(AUDIT-TRAIL-0 reader-masking.md §1.6):线上 287 条读策略
--   0 条 restrictive、0 条依赖数据库角色 —— 全部经 has_permission() / current_user_employee() 从登录的 JWT 认人。
--   restrictive 策略若将来出现,在这里用 AND 接上(已经写好)。
--   ★ U1-A(2026-10-05):第一条 restrictive 策略来了 —— journal_lines 的 "amounts: payroll journal lines need data.view_pay"。
--     名字以 "amounts:" 开头的这一类【不】接进来:它们挡的是 API 上的整行(PostgREST 做不了逐行遮列),
--     而审计记录跟【屏幕】走(<表>_masked:行在、金额受限),金额由 change_log_mask_rules 遮。别的 restrictive 照旧 AND。
--   · 表没开 RLS → 看 authenticated 有没有任何一列的 SELECT 权限;
--   · authenticated 连一列都读不了(cod_verification_failures 那种没有读策略的表)→ 看不见;
--   · 这一行已被硬删 → 对它最后一份影像求同一个值(jsonb_populate_record,别名就是表名,于是带表名限定的列引用照样解析)。
--   ☞ 已知边界(reader-masking.md §1.6 已记):策略里 EXISTS 子查询读的别的表,在 DEFINER 里不再过那张表的 RLS。
--     线上两处这种策略的子查询都自己写全了条件,所以结果相同。
-- 【属主身份】EXECUTE 已从 authenticated 收回 —— 否则它就是一支"任意一行你看不看得见"的探针。
-- AUDIT-TRAIL-1d-1(M9):trail_log_only_tables() 登记的表(auth.users)不在 public 里,它的策略这里读不到 ——
--   它的读规则是登记表里【声明的那个码】(action.manage_permissions,与 user_directory 同一个谓词)。
CREATE OR REPLACE FUNCTION public.trail_row_visible(p_table text, p_key jsonb, p_image jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rls   boolean;
    v_perm  text;
    v_restr text;
    v_where text;
    v_ok    boolean;
    v_live  boolean;
    v_code  text;
BEGIN
    SELECT l.read_code INTO v_code FROM trail_log_only_tables() l WHERE l.table_name = p_table;
    IF FOUND THEN
        RETURN p_key IS NOT NULL AND has_permission(v_code);
    END IF;
    SELECT c.relrowsecurity INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
     WHERE c.relname = p_table AND c.relkind = 'r';
    IF NOT FOUND OR p_key IS NULL THEN
        RETURN false;
    END IF;
    IF NOT has_any_column_privilege('authenticated', format('public.%I', p_table), 'SELECT') THEN
        RETURN false;
    END IF;
    IF NOT v_rls THEN
        RETURN true;
    END IF;
    SELECT string_agg('(' || p.qual || ')', ' OR ') INTO v_perm
      FROM pg_policies p
     WHERE p.schemaname = 'public' AND p.tablename = p_table AND p.permissive = 'PERMISSIVE'
       AND p.cmd IN ('SELECT', 'ALL') AND p.roles && ARRAY['authenticated', 'public']::name[]
       AND p.qual IS NOT NULL;
    IF v_perm IS NULL THEN
        RETURN false;
    END IF;
    SELECT string_agg('(' || p.qual || ')', ' AND ') INTO v_restr
      FROM pg_policies p
     WHERE p.schemaname = 'public' AND p.tablename = p_table AND p.permissive = 'RESTRICTIVE'
       AND p.cmd IN ('SELECT', 'ALL') AND p.roles && ARRAY['authenticated', 'public']::name[]
       AND p.qual IS NOT NULL
       -- U1-A:名字以 "amounts:" 开头的 restrictive 策略只是【金额】的门(经 API 藏掉整行,因为 PostgREST 做不了逐行遮列);
       --   审计记录跟屏幕走 —— 那一行在、金额受限,遮蔽由 change_log_mask_rules 给出(journal_lines 的 pay_journal)。
       AND p.policyname NOT LIKE 'amounts:%';
    v_perm := '(' || v_perm || ')' || COALESCE(' AND (' || v_restr || ')', '');

    SELECT string_agg(format('%I.%I::text = %L', p_table, k.key, k.value), ' AND ')
      INTO v_where FROM jsonb_each_text(p_key) k;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%1$I %1$I WHERE %2$s)', p_table, v_where) INTO v_live;
    IF v_live THEN
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%1$I %1$I WHERE %2$s AND (%3$s))', p_table, v_where, v_perm)
           INTO v_ok;
        RETURN COALESCE(v_ok, false);
    END IF;
    IF p_image IS NULL THEN
        RETURN false;
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM jsonb_populate_record(NULL::public.%1$I, $1) %1$I WHERE (%2$s))',
                   p_table, v_perm)
       INTO v_ok USING p_image;
    RETURN COALESCE(v_ok, false);
END;
$function$;

-- db/functions/change_log_redactable_columns.sql
-- HISTORY-1:匿名化时 change_log 里【允许被涂成 null】的列 —— 按源表。
-- 名单与 anonymise_employee 清掉的列【逐字同一份】(外加 greeting_name,Tim 的 Q9);
-- 两边任何一边加列,另一边要在同一个提交里跟上 —— fixture 234 的涂抹那一臂钉着这份对应。
-- ★ U1-A(Tim 的 UNBLOCK-1 Q11,2026-10-05):加四张表 —— 调薪申请、工资行、请假单、医疗报销上【人写的字】。
--   金额不在名单里(擦文字,留金额:金额是有法定保存期的账,而人一匿名化,它们就只属于"一位前员工")。
--   anonymise_employee 在基表上擦的正是这几列(不许为空的那几列写成 'ANONYMISED',记录里一律涂成 null);fixture 247 的 AN 臂钉着这份对应。
CREATE OR REPLACE FUNCTION public.change_log_redactable_columns(p_table text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_table
        WHEN 'employees' THEN ARRAY[
            'legal_name', 'preferred_name', 'first_name', 'last_name', 'greeting_name',
            'identity_no', 'work_email', 'work_phone', 'work_pass_no', 'work_pass_type',
            'work_pass_issue_date', 'work_pass_expiry_date', 'residency_status',
            'monthly_salary', 'notes', 'separation_notes', 'position_id', 'user_id']
        WHEN 'employment_history' THEN ARRAY['old_monthly_salary', 'new_monthly_salary', 'notes']
        -- U1-A(UNBLOCK-1 Q11):四张表上【人写的字】—— 理由、说明、备注、单号;金额一个都不在名单里(Q11:擦文字,留金额)
        WHEN 'salary_change_requests' THEN ARRAY['reason', 'decision_notes', 'withdraw_reason']
        WHEN 'payroll_lines' THEN ARRAY['notes']
        WHEN 'leave_requests' THEN ARRAY['reason', 'certificate_ref', 'decision_notes', 'exception_reason']
        WHEN 'medical_claims' THEN ARRAY['description', 'receipt_ref', 'decision_notes']
        ELSE ARRAY[]::text[]
    END;
$function$;

-- db/functions/change_log_redact_employee.sql
-- HISTORY-1(Tim 的 Q11 · Q9):匿名化时涂抹 change_log 里关于这个人的个人字段 ——
-- change_log 【唯一】能被改的那条路。
--
-- 【谁调它】只有 anonymise_employee,在它自己那两句 UPDATE【之后】、同一笔事务里。
--   ★ 顺序是承重的:anonymise_employee 那句 UPDATE employees 本身就会被 change_log_capture
--     记一行,而那一行的 old 里装着【匿名化之前的每一个个人字段】。涂抹必须在它之后跑,
--     才涂得到它(fixture 234 的涂抹那一臂专门钉这一格)。
-- 【涂什么】employees 上这个人那一行的全部记录 + employment_history 上属于他的那些行的全部记录,
--   只涂 change_log_redactable_columns() 名单上的列(改成 JSON null),盖 redacted_at。
--   别的表只按 employee_id 引用他 —— 与 anonymise_employee 的范围逐字相同,不多不少。
-- ★ U1-A(Tim 的 UNBLOCK-1 Q11,2026-10-05):范围加四张表 —— 调薪申请、工资行、请假单、医疗报销上属于他的那些行的记录,
--   只涂 change_log_redactable_columns() 给这四张表列出的【文字】列(理由、说明、备注、单号),金额不涂。
-- 【证明别的都没动】不靠本函数自证:change_log 上的守卫(guard_change_log_append_only)
--   逐行核对这一句 UPDATE 的形状,多改一个键、多动一列,整句被拒。
-- 【为什么自己也查权限】它是 SECURITY DEFINER;EXECUTE 虽已从 authenticated 收回,
--   调用方 anonymise_employee 的持码人查得过这一道,多一道不多。
CREATE OR REPLACE FUNCTION public.change_log_redact_employee(p_employee_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_hist text[];
    v_rows text[];
    v_n    integer;
BEGIN
    PERFORM require_permission('action.anonymise_employee');
    IF p_employee_id IS NULL THEN
        RAISE EXCEPTION 'PDPA_EMPLOYEE_NOT_FOUND';
    END IF;

    SELECT COALESCE(array_agg(h.id::text), ARRAY[]::text[]) INTO v_hist
      FROM employment_history h WHERE h.employee_id = p_employee_id;
    -- U1-A(UNBLOCK-1 Q11):四张表上属于他的那些行 —— 记录按行主键认(row_key ->> 'id'),表行今天都还在(这几张表不硬删属于一个人的行;
    --   真有一行被删了,它的记录也不在这一句的射程里 —— 照直说,不假装)。
    SELECT COALESCE(array_agg(x.k), ARRAY[]::text[]) INTO v_rows FROM (
        SELECT 'salary_change_requests:' || s.id::text AS k FROM salary_change_requests s WHERE s.employee_id = p_employee_id
        UNION ALL SELECT 'payroll_lines:' || l.id::text FROM payroll_lines l WHERE l.employee_id = p_employee_id
        UNION ALL SELECT 'leave_requests:' || r.id::text FROM leave_requests r WHERE r.employee_id = p_employee_id
        UNION ALL SELECT 'medical_claims:' || m.id::text FROM medical_claims m WHERE m.employee_id = p_employee_id) x;

    UPDATE change_log c
       SET old = change_log_null_keys(c.old, change_log_redactable_columns(c.table_name)),
           new = change_log_null_keys(c.new, change_log_redactable_columns(c.table_name)),
           redacted_at = clock_timestamp()
     WHERE c.redacted_at IS NULL
       AND (   (c.table_name = 'employees' AND c.row_key ->> 'id' = p_employee_id::text)
            OR (c.table_name = 'employment_history' AND c.row_key ->> 'id' = ANY (v_hist))
            OR (c.table_name IN ('salary_change_requests', 'payroll_lines', 'leave_requests', 'medical_claims')
                AND c.table_name || ':' || (c.row_key ->> 'id') = ANY (v_rows)));
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$function$;

-- db/functions/anonymise_employee.sql
-- PDPA 的"目的结束后不再保留":把一名【已离职且保留期已满】的员工就地匿名化 ——
-- 覆盖身份列,行留着。与 Doc 2 原则 7 的调和见 docs/as-built-divergences.md 第 2 条;
-- 范围、待决项与那条法律问题见 docs/pdpa.md。
--
-- 【四条按名拒绝】PDPA_RETENTION_PERIOD_NOT_SET(最要紧的一条:保留期是法律问题,
-- 这支函数不用默认值替人回答;而 2026-08-24 的裁定让它成为【今天唯一走得到】的
-- 那一条 —— 其余三条在这条裁定之下永远到不了)· PDPA_EMPLOYEE_NOT_SEPARATED
-- · PDPA_RETENTION_NOT_ELAPSED · PDPA_ALREADY_ANONYMISED。证据在 db/fixtures/126。
--
-- ★★ 【这支函数将不会被使用 —— 而这是一个决定,不是一件没做完的活】(Tim,2026-08-24)★★
-- 本函数存在、正确、有 fixture 覆盖,而在 Tim 2026-08-24 的裁定之下【将不会被使用】:
--   **员工个人数据无限期保留。没有保留期,而且不会有。**
-- 它因 hr_settings.personal_data_retention_months 为 NULL 而按名拒绝
-- (PDPA_RETENTION_PERIOD_NOT_SET),而在这条裁定之下那一列【保持 NULL】。
-- 它是一件【建好了、刻意休眠】的机制,不是没做完的活。
--
-- 【不要删掉它,不要放宽这条拒绝,不要设一个期限。】那句拒绝正是这次休眠诚实的地方 ——
-- 路是关着的,而且它说得出自己为什么关着。裁定哪天改口,把那一列设上就是全部的改动。
-- 裁定本身、它没有 settle 掉的东西(保留限制仍是 PDPA 的义务,无限期保留是公司
-- 采取的立场,不是本系统给出的豁免)、以及待决清单里它从 OPEN 变成 DECIDED 的那一行,
-- 都在 docs/pdpa.md 第二节与第五节。
--
-- 【它动两张表】employees 的身份列,与 employment_history 的薪资两列 + 备注。
-- 后者是【不可变】的表 —— 匿名化是它唯一的 UPDATE 例外,而那条例外由行的形状定义
-- (见 db/tables/employment_history.sql 里的 reject_employment_history_mutation)。
--
-- NOTE: introduced by db/migrations/2026-08-24-pdpa1-anonymise-and-subject-access.sql;
--       fixed by db/migrations/2026-08-24-pdpa1-fu-the-immutable-log-gets-one-named-exception.sql
--       (第一版在真实数据上必崩:履历不可变,而它有一句 UPDATE)。
-- ★ HISTORY-1(2026-09-28,db/migrations/2026-09-28-history1-change-log.sql):greeting_name 一并清掉;
--   末尾调 change_log_redact_employee 涂掉通用变更记录里的个人字段。
-- ★ NAME-1(2026-09-28,db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql):
--   first_name / last_name 与 preferred_name 一起清成 NULL —— 它们就是身份列。
-- ★ U1-A(Tim 的 UNBLOCK-1 Q11,2026-10-05):范围加四张表上【人写的字】(调薪申请、工资行、请假单、医疗报销),金额不动;
--   记录那一侧由 change_log_redact_employee 跟上(同一份名单:change_log_redactable_columns)。

CREATE OR REPLACE FUNCTION public.anonymise_employee(p_employee_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_months int;
    v_emp    employees%ROWTYPE;
    v_due    date;
BEGIN
    PERFORM require_permission('action.anonymise_employee');

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'PDPA_REASON_REQUIRED';
    END IF;

    -- 【没有保留期就【拒绝】,不走任何默认】默认值 = 一次法律表态。
    SELECT personal_data_retention_months INTO v_months FROM hr_settings LIMIT 1;
    IF v_months IS NULL THEN
        RAISE EXCEPTION 'PDPA_RETENTION_PERIOD_NOT_SET';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PDPA_EMPLOYEE_NOT_FOUND';
    END IF;
    IF v_emp.anonymised_at IS NOT NULL THEN
        RAISE EXCEPTION 'PDPA_ALREADY_ANONYMISED|%', v_emp.anonymised_at::date;
    END IF;
    -- 【在职的人不许匿名化】目的还没有结束 —— 那不是合规,那是把在用的数据毁掉。
    IF v_emp.separation_date IS NULL THEN
        RAISE EXCEPTION 'PDPA_EMPLOYEE_NOT_SEPARATED|%', v_emp.code;
    END IF;
    v_due := (v_emp.separation_date + make_interval(months => v_months))::date;
    IF v_due > CURRENT_DATE THEN
        RAISE EXCEPTION 'PDPA_RETENTION_NOT_ELAPSED|%|%', v_emp.code, v_due;
    END IF;

    -- 【覆盖身份列;结构性的列留着】
    -- 留下的那些(编号、雇佣类型、工种、入离职日、部门)**不指向一个人** ——
    -- 它们是让总账、历史与统计还读得懂所必需的,而原则 7 要的正是这个。
    UPDATE employees SET
        legal_name           = 'ANONYMISED ' || code,
        preferred_name       = NULL,
        first_name           = NULL,
        last_name            = NULL,
        -- HISTORY-1(Tim 的 Q9):称呼名也是名字 —— 此前漏了它。
        greeting_name        = NULL,
        identity_no          = NULL,
        work_email           = NULL,
        work_phone           = NULL,
        work_pass_no         = NULL,
        work_pass_type       = NULL,
        work_pass_issue_date = NULL,
        work_pass_expiry_date= NULL,
        residency_status     = NULL,
        monthly_salary       = NULL,
        notes                = NULL,
        separation_notes     = NULL,
        -- KPI-1:employees.job_title 已删,清的是【职位指针】。
        -- 【为什么职位也要清】职位本身是主数据、不是个人数据,但"这一行的人
        -- 曾经担任 CFO"仍然是一条关于那个人的事实 —— 匿名化要断掉的正是这种关联。
        -- **employment_history 上那一行不动**(那是不可变的履历,见 fixture 126)。
        position_id          = NULL,
        user_id              = NULL,          -- 与登录账号解绑
        anonymised_at        = now(),
        anonymised_by        = auth.uid()
    WHERE id = p_employee_id;

    -- 薪资历史也是个人数据。**其余每一张表都只按 employee_id 引用他**,
    -- 身份列一旦从这一行拿掉,那些行就不再指向一个可识别的人(化名化)。
    -- 【anonymised_at 必须一起写】—— 它是不可变守卫认得出这个形状的凭据,
    -- 也是 salary_change 行有权不说新薪资的凭据。少了它,这句 UPDATE 会被守卫
    -- 拒掉,而那正是 fixture 126 抓到的那一幕。
    UPDATE employment_history
       SET old_monthly_salary = NULL,
           new_monthly_salary = NULL,
           notes              = NULL,
           anonymised_at      = now()
     WHERE employee_id = p_employee_id
       AND anonymised_at IS NULL;

    -- ★ U1-A(Tim 的 UNBLOCK-1 Q11,2026-10-05):四张表上【人写的字】一并擦掉 —— 调薪申请的理由 · 决定说明 · 撤回理由,
    --   工资行的备注,请假单的事由 · 病假单号 · 决定说明 · 例外理由,医疗报销的事由 · 单据号 · 决定说明。
    --   【金额一个都不动】(Q11:擦文字,留金额 —— 那是有法定保存期的账;人一匿名化,它们就只属于"一位前员工")。
    --   不许为空的那几列(调薪申请的理由;被驳回那一张的决定说明;例外请假的理由)写成 'ANONYMISED' —— 与 legal_name 同一个做法;
    --   其余写成 NULL。下一句涂记录时,这几列在记录里一律涂成 null(change_log_redactable_columns)。
    UPDATE salary_change_requests
       SET reason          = 'ANONYMISED',
           decision_notes  = CASE WHEN status = 'rejected' THEN 'ANONYMISED' END,
           withdraw_reason = NULL
     WHERE employee_id = p_employee_id;
    UPDATE payroll_lines
       SET notes = NULL
     WHERE employee_id = p_employee_id AND notes IS NOT NULL;
    UPDATE leave_requests
       SET reason           = NULL,
           certificate_ref  = NULL,
           decision_notes   = NULL,
           exception_reason = CASE WHEN is_exception THEN 'ANONYMISED' END
     WHERE employee_id = p_employee_id
       AND (reason IS NOT NULL OR certificate_ref IS NOT NULL OR decision_notes IS NOT NULL OR exception_reason IS NOT NULL);
    UPDATE medical_claims
       SET description    = NULL,
           receipt_ref    = NULL,
           decision_notes = NULL
     WHERE employee_id = p_employee_id
       AND (description IS NOT NULL OR receipt_ref IS NOT NULL OR decision_notes IS NOT NULL);

    -- ★ HISTORY-1(Tim 的 Q11):通用变更记录里关于这个人的个人字段一并涂掉。
    --   【必须在上面两句之后】—— 那两句本身就被 change_log_capture 记了行,
    --   而 employees 那一行的 old 里装着匿名化之前的每一个个人字段。
    PERFORM change_log_redact_employee(p_employee_id);

    RETURN jsonb_build_object(
        'employee_code', v_emp.code, 'anonymised_at', now(),
        'retention_months', v_months, 'due_since', v_due, 'reason', p_reason);
END;
$function$;

CREATE OR REPLACE FUNCTION public.account_ledger(p_account_code text, p_from date, p_to date, p_include_year_close boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text; v_name_en text; v_name_zh text; v_type text;
    v_rows jsonb; v_total numeric;
    v_pay  boolean;
BEGIN
    -- 【权限:与两张报表同一道门】能看见那个数字的人,就能看见它背后的行 ——
    -- 反过来说,这个函数不该比它服务的报表松一格。module.finance.view 隐含
    -- 价格可见性(AGENTS.md 三条常设裁定之一:总账就是价格数据),所以这里
    -- 不再叠第二把锁。
    PERFORM require_permission('module.finance.view');
    -- ★ U1-A(Tim 的 UNBLOCK-1 Q1 · Q2,2026-10-05):工资分录那几行的金额(debit · credit · amount)只给持 data.view_pay 的人 ——
    --   与 journal_lines_masked 的 CASE、与 change_log_mask_rules 的 pay_journal 规则同一个判据。行在、行摘要在、对方科目在,
    --   金额是 null 并带 amounts_restricted = true(页面说「受限」,不说 0.00)。【合计不遮】:它是这个科目在这一期的发生额,
    --   与报表上那个数并排对账(下面那段说明);没有逐行余额,所以从合计减不出任何一行。
    v_pay := has_permission('data.view_pay');

    IF p_account_code IS NULL OR btrim(p_account_code) = '' THEN
        RAISE EXCEPTION 'ACCOUNT_CODE_REQUIRED';
    END IF;
    -- 【截止日与开关都不给默认值】p_to 空了就拒,不 COALESCE 成 CURRENT_DATE:
    -- 一个悄悄换了期间的明细表会与它要对账的那张报表对不上,而那个不一致
    -- 看起来会像报表错了。开关同理 —— 猜错它就是猜错了年结那条不对称。
    IF p_to IS NULL THEN
        RAISE EXCEPTION 'PERIOD_REQUIRED';
    END IF;
    IF p_include_year_close IS NULL THEN
        RAISE EXCEPTION 'YEAR_CLOSE_SWITCH_REQUIRED';
    END IF;

    SELECT a.code, a.name_en, a.name_zh, a.account_type
      INTO v_code, v_name_en, v_name_zh, v_type
      FROM accounts a WHERE a.code = p_account_code;
    -- 【科目不存在 ≠ 科目没有分录】前者是问错了问题,后者是一个正当的答案。
    -- 把两者合成一个空表,就是把"打错了科目号"显示成"这个月没动过" ——
    -- 与 mustRows / restRows / check-i18n 后缀解析同一条:一次失败不是一个空集。
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_FOUND|%', p_account_code;
    END IF;

    WITH act AS (
        -- 【与两张报表逐字同一段推导】三表连接、不过滤 status、符号规则,
        -- 全在 journal_activity_lines 里。两个开关由调用者给:
        -- 损益表的下钻传 (from, to, false);资产负债表的下钻传 (NULL, as_of, true)。
        -- 【这就是"合计对得上"能成立的原因,也是它唯一能成立的原因】——
        -- 见下面 total 那里关于"这个对账能查出什么"的说明。
        SELECT * FROM journal_activity_lines(p_from, p_to, p_include_year_close)
    ), mine AS (
        SELECT * FROM act WHERE act.account_code = p_account_code
    ), cp AS (
        -- 对方科目:同一张分录里【反方向】的那些行。取反方向而不是"其余所有行",
        -- 是因为一借多贷时,一条借方行的对家是那些贷方行,不是同侧的兄弟行。
        SELECT m.line_id,
               jsonb_agg(DISTINCT jsonb_build_object(
                   'code', o.account_code,
                   'name_en', o.account_name_en,
                   'name_zh', o.account_name_zh)) AS accounts
        FROM mine m
        JOIN act o ON o.entry_id = m.entry_id
                  AND o.line_id <> m.line_id
                  AND ((m.debit > 0 AND o.credit > 0) OR (m.credit > 0 AND o.debit > 0))
        GROUP BY m.line_id
    )
    SELECT
        COALESCE(jsonb_agg(jsonb_build_object(
            'line_id',      m.line_id,
            'entry_id',     m.entry_id,
            'entry_code',   m.entry_code,
            'entry_date',   m.entry_date,
            'entry_memo',   m.entry_memo,
            'line_memo',    m.line_memo,
            'entry_status', m.entry_status,
            -- 来源单据:类型 + 主键。链接由页面用既有的 resolveSourceHrefs 解析 ——
            -- 那份映射已经服务分录列表页,不在这里抄第二份。
            'source_type',  m.source_type,
            'source_id',    m.source_id,
            'debit',        CASE WHEN v_pay OR m.source_type IS DISTINCT FROM 'payroll' THEN m.debit END,
            'credit',       CASE WHEN v_pay OR m.source_type IS DISTINCT FROM 'payroll' THEN m.credit END,
            -- 【符号:共享推导那一条,不是这里第三次写的一条】
            'amount',       CASE WHEN v_pay OR m.source_type IS DISTINCT FROM 'payroll' THEN m.signed_base END,
            'amounts_restricted', NOT (v_pay OR m.source_type IS DISTINCT FROM 'payroll'),
            'counterparts', COALESCE(c.accounts, '[]'::jsonb))
            ORDER BY m.entry_date, m.entry_code, m.line_id), '[]'::jsonb),
        -- 【本函数自己的合计】页面会把它与报表上那个数字【并排】显示。
        --
        -- 【这个对账能查出什么,不能查出什么 —— 说清楚,免得它变成一句装饰】
        -- 查不出:算术错。两边共用 journal_activity_lines 的同一列,算术不可能
        --   各错各的(AGENTS.md/OPS-17:两个数只有能分开动,才算一个对账)。
        -- 查得出:【页面把参数传错了】—— 下钻带的期间与报表自己的期间不一致、
        --   年结开关传反、科目号带错。那正是一个下钻页最容易错的地方,
        --   也是这两个数唯一能分开动的方式。所以页面必须并排显示、
        --   不一致时说出来,而不是悄悄挑一个显示。
        COALESCE(round(sum(m.signed_base), 2), 0)
    INTO v_rows, v_total
    FROM mine m LEFT JOIN cp c ON c.line_id = m.line_id;

    RETURN jsonb_build_object(
        'account', jsonb_build_object(
            'code', v_code, 'name_en', v_name_en,
            'name_zh', v_name_zh, 'account_type', v_type),
        'period_from', p_from,
        'period_to', p_to,
        'include_year_close', p_include_year_close,
        'rows', v_rows,
        -- 【空是一个具名状态,不是一个错】科目存在、期间内没有分录 ——
        -- rows 为 [],line_count 为 0,total 为 0,页面据此说"本期间无分录",
        -- 而不是渲染一张空表让人猜是没数据还是没加载出来。
        'line_count', jsonb_array_length(v_rows),
        'total', v_total
    );
END;
$function$;

-- db/functions/bank_book_balance_asof.sql
-- CLEANUP-A(2026-08-31):自带 module.finance.view 判据,无权限返回 NULL 而不是 0.00。
-- 实测 finance −29,753.70 / operations 从前 0.00。判据放在最外层 CASE 而不是 WHERE ——
-- 塞进 WHERE 会让"无权限"重新变成"零行",于是又被 COALESCE(…,0) 变回 0.00。

-- ★ U1-A(Tim 的 UNBLOCK-1 Q2,2026-10-05):改成 SECURITY DEFINER。journal_lines 上那条 restrictive 策略("amounts: …")
--   让不持 data.view_pay 的财务读者(cto · gm)经 RLS 读不到工资分录的行;invoker 时,他在对账页与现金预测上看到的银行账面余额
--   会【悄悄】少掉发薪那几笔 —— 一个不报错、只是不一样的余额。属主身份绕过那条策略;判据仍是外层 CASE 那一句。
CREATE OR REPLACE FUNCTION public.bank_book_balance_asof(p_account_code text, p_as_of date)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【判据在最外层,而不是塞进 WHERE】塞进 WHERE 会让"无权限"重新变成
    -- "零行",于是又是 COALESCE(…, 0) → 0.00,原样复发。
    -- 外层 CASE 没有 ELSE:不满足判据时整支函数是 NULL,而不是一个数。
    SELECT CASE WHEN has_permission('module.finance.view'::text) THEN (
        SELECT round(COALESCE(sum(
                   CASE WHEN jl.debit > 0 THEN jl.amount_ccy ELSE -jl.amount_ccy END
               ), 0), 2)
        FROM journal_activity_lines(NULL, p_as_of, true) act
        JOIN journal_lines jl ON jl.id = act.line_id
        WHERE act.account_code = p_account_code
          AND jl.currency = bank_native_currency(p_account_code)
    ) END;
$function$;

COMMENT ON FUNCTION public.bank_book_balance_asof(p_account_code text, p_as_of date) IS
    'CLEANUP-A:某银行科目截至某日的账面原币净额。【自带 module.finance.view 判据,无权限返回 NULL 而不是 0.00】实测:finance 读者得 −29,753.70,operations 读者从前得 0.00 —— 一个不报错、只是更小的数字。NULL 在本支没有主(从前 COALESCE 兜底,产生不出 NULL),所以 NULL 可以用来表达"受限"。★ U1-A(UNBLOCK-1 Q2,2026-10-05)起是 SECURITY DEFINER:journal_lines 上那条 restrictive 策略让不持 data.view_pay 的财务读者经 RLS 读不到工资分录的行,invoker 时他的银行账面余额会悄悄少掉发薪那几笔;属主身份绕过它,每一个读者拿到同一个余额。判据仍是外层那句 module.finance.view(无权限 NULL,不是 0.00)。';

-- db/functions/trial_balance_totals.sql
-- U1-A(Tim 的 UNBLOCK-1 Q2,2026-10-05):试算平衡表的【按科目合计】—— /finance/trial-balance 从此问这里,不再经 PostgREST 把每一行拉回来自己加。
-- 【为什么必须搬】journal_lines 上那条 restrictive 策略("amounts: …")让不持 data.view_pay 的财务读者(cto · gm)经 API 读不到工资分录的行;
--   页面若照旧逐行求和,那几行会【悄悄】从合计里消失,而试算表仍然"平"(工资分录自己借贷相等)—— 一个不报错、只是小一点的数,
--   正是 AGENTS.md 那一族(xmodule:0.00 与「受限」不是一回事)。属主身份在这里绕过那条策略,于是每一个读者拿到的是同一组合计。
-- 【口径与原来逐字相同】全部行、不按 status 过滤(冲销件与原件一起数,净额才对)—— 页面原来就是 select account_id, debit, credit 全表。
-- 【门】require_permission('module.finance.view') —— 与页面守卫、与 journal_lines 的 permissive 策略同一个码;无权限按名拒,不是 0 行。
CREATE OR REPLACE FUNCTION public.trial_balance_totals()
 RETURNS TABLE(account_id uuid, debits numeric, credits numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT l.account_id, sum(l.debit), sum(l.credit)
      FROM journal_lines l
     GROUP BY l.account_id;
END;
$function$;

-- db/functions/journal_close_preview.sql
-- U1-A(Tim 的 UNBLOCK-1 Q2,2026-10-05):/finance/close 那一格"截至所选月末:几张分录 · Σ借 · Σ贷"—— 从此问这里。
-- 【为什么必须搬】原来那一句是 PostgREST 拉 journal_lines(内连 journal_entries)再在页面上加;journal_lines 上那条 restrictive 策略
--   让不持 data.view_pay 的财务读者读不到工资分录的行,于是他看到的分录数与两个合计都【悄悄变小】,而"已平"的对勾照样画出来 ——
--   那一格是关账的确认依据(页面上的注释写着:验不了就不能画勾)。属主身份绕过那条策略,每一个读者拿到同一组数。
-- 【口径与原来逐字相同】entry_date <= p_period_end 的全部行,不按 status 过滤。
-- 【门】module.finance.view,按名拒;截止日不给默认值(PERIOD_REQUIRED)。
CREATE OR REPLACE FUNCTION public.journal_close_preview(p_period_end date)
 RETURNS TABLE(entry_count bigint, debits numeric, credits numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'PERIOD_REQUIRED';
    END IF;
    RETURN QUERY
    SELECT count(DISTINCT l.entry_id), COALESCE(sum(l.debit), 0), COALESCE(sum(l.credit), 0)
      FROM journal_lines l
      JOIN journal_entries e ON e.id = l.entry_id
     WHERE e.entry_date <= p_period_end;
END;
$function$;

-- db/functions/journal_export_lines.sql
-- U1-A(Tim 的 UNBLOCK-1 Q1 · Q2,2026-10-05):总账导出(/finance/journal/export)的取数 —— journal_activity_lines 的同一组行,
--   工资分录那几行的三个金额对不持 data.view_pay 的人是 NULL,并带 amounts_restricted = true(CSV 印 "Restricted",不印 0)。
-- 【为什么不再直接调 journal_activity_lines】它是 invoker(为了可内联,三张报表在属主身份里读它);被一个登录用户直接调时,
--   journal_lines 上那条 restrictive 策略会让工资分录的行【悄悄缺席】—— 一份少了几行、而抬头的行数照样对得上的导出。
--   这里以属主身份读同一段推导(一行算术都不重写),只在出口处遮金额:行在、科目在、行摘要在,金额受限。
-- 【判据】与 journal_lines_masked 的 CASE、与 change_log_mask_rules 的 pay_journal 规则逐字同一个:
--   持 data.view_pay,或这一行所在分录的 source_type 不是 'payroll'。
-- 【门】module.finance.view,按名拒(与 journal_lines 的 permissive 读策略同一个码)。
CREATE OR REPLACE FUNCTION public.journal_export_lines(p_from date, p_to date, p_include_year_close boolean)
 RETURNS TABLE(entry_id uuid, entry_code text, entry_date date, entry_memo text, source_type text, source_id uuid, entry_status text, line_id uuid, line_memo text, account_id uuid, account_code text, account_name_en text, account_name_zh text, account_type text, debit numeric, credit numeric, signed_base numeric, amounts_restricted boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_pay boolean;
BEGIN
    PERFORM require_permission('module.finance.view');
    v_pay := has_permission('data.view_pay');
    RETURN QUERY
    SELECT a.entry_id, a.entry_code, a.entry_date, a.entry_memo, a.source_type, a.source_id, a.entry_status,
           a.line_id, a.line_memo, a.account_id, a.account_code, a.account_name_en, a.account_name_zh, a.account_type,
           CASE WHEN v_pay OR a.source_type IS DISTINCT FROM 'payroll' THEN a.debit END,
           CASE WHEN v_pay OR a.source_type IS DISTINCT FROM 'payroll' THEN a.credit END,
           CASE WHEN v_pay OR a.source_type IS DISTINCT FROM 'payroll' THEN a.signed_base END,
           NOT (v_pay OR a.source_type IS DISTINCT FROM 'payroll')
      FROM journal_activity_lines(p_from, p_to, p_include_year_close) a;
END;
$function$;

-- db/functions/medical_claim_balance.sql
-- 医疗报销额度:按当年完整服务月数折算,取整到元。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.
--
-- HR-6(2026-08-05):以 finance_settings.system_start_date 为界。
-- 额度是【推导】的、已用额是【记录】的 —— 切换前的报销不在本库,于是整份额度
-- 会重新可用,而 decide_medical_claim 就拿这个 remaining 当闸门(真的多批钱)。
-- 整年早于起始日 → 拒;起始日落在年内 → 额度按覆盖月份折算;未设 → 拒。

CREATE OR REPLACE FUNCTION public.medical_claim_balance(p_employee_id uuid, p_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    record;
    v_set    record;
    v_months integer := 12;
    v_limit  numeric;
    v_used   numeric;
    v_start  date;      -- 本库自哪天起持有完整记录
    v_from_m integer;   -- 本年度从第几个月起算(入职月 / 完整记录起始月,取较晚者)
BEGIN
    -- ★ U1-A(Tim 的 UNBLOCK-1 Q8,2026-10-05):门从 module.hr.view 收成 data.view_health —— 已用额就是这个人这一年
    --   医疗报销金额的合计,而那个金额(medical_claims.amount_sgd)从本刀起只给持 data.view_health 的人与本人。
    --   本人照旧(/me 的额度面板);决定医疗报销的人(action.decide_hr_requests:admin · cco · cfo · finance)都持这一码,
    --   所以 decide_medical_claim 里那一次调用照旧过得去。
    --   ★ COALESCE 是承重的(U1-A 量到的、本刀之前就在的缺陷):一个【没有员工档案】的账号,current_user_employee() 是 NULL,
    --     于是 "p_employee_id = NULL" 是 NULL,NOT (false OR NULL) 也是 NULL —— IF NULL 不进分支,这道门对它【从来没有关过】。
    IF NOT (has_permission('data.view_health') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|data.view_health';
    END IF;

    SELECT id, code, hire_date INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
    SELECT * INTO v_set FROM hr_settings WHERE id;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【额度是推导的,消耗是记录的 —— 全新库有前者没有后者】
    -- 年度额度由政策推导(每年 1000),已用额则来自 medical_claims 里【记录】的行。
    -- 切换上线时,切换前已报销的部分不在本库里,于是 used 偏低、remaining 偏高,
    -- 整份年度额度重新可用。而 decide_medical_claim 就是拿这个 remaining 当闸门的
    -- (CLAIM_EXCEEDS_LIMIT),所以这不是显示问题,是【真的会多批钱出去】。
    --
    -- 处置与 HR-5 的结转同一形状:
    --   * 整年都早于完整记录起始日 → 拒绝(那一年本库一无所知,给出任何余额都是编的);
    --   * 起始日落在本年度之内 → 把额度【按本库覆盖的月份】折算。
    --     理由:切换前的额度【与消耗】都在本库之外,两者一起排除是自洽的;
    --     而"整份额度 + 零消耗"不自洽。折算方向偏保守(可能少给,不会多批),
    --     少给的那部分由下面那条路补回来。
    --
    -- 【想恢复整份年度额度怎么办】把切换前的报销作为 medical_claims 行补录进来,
    -- 并把 system_start_date 前移到最早那笔真实交易 —— 那一年就【完整】了,
    -- 折算自动消失。见 docs/fresh-install-checklist.md。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT system_start_date INTO v_start FROM finance_settings LIMIT 1;
    IF v_start IS NULL THEN
        RAISE EXCEPTION 'SYSTEM_START_NOT_SET';
    END IF;
    IF make_date(p_year, 12, 31) < v_start THEN
        RAISE EXCEPTION 'CLAIM_YEAR_BEFORE_SYSTEM_START|%|%', p_year, v_start;
    END IF;

    v_from_m := 1;
    IF v_set.medical_pro_rate_for_joiners AND EXTRACT(YEAR FROM v_emp.hire_date)::integer = p_year THEN
        v_from_m := EXTRACT(MONTH FROM v_emp.hire_date)::integer;
    END IF;
    -- 完整记录的起始月【不是政策选项,是关于数据的事实】,所以不看
    -- medical_pro_rate_for_joiners 那个开关,一律生效。
    IF EXTRACT(YEAR FROM v_start)::integer = p_year THEN
        v_from_m := GREATEST(v_from_m, EXTRACT(MONTH FROM v_start)::integer);
    END IF;
    v_months := 12 - (v_from_m - 1);
    v_limit := round(v_set.medical_annual_limit_sgd * v_months / 12.0, 0);

    SELECT COALESCE(SUM(amount_sgd), 0) INTO v_used
    FROM medical_claims
    WHERE employee_id = p_employee_id AND claim_year = p_year
      AND deleted_at IS NULL AND status IN ('approved','paid');

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code, 'year', p_year,
        'annual_limit_sgd', v_set.medical_annual_limit_sgd,
        'months_of_service', v_months,
        'pro_rated_limit_sgd', v_limit,
        'record_complete_from', v_start,
        'record_incomplete_for_year', EXTRACT(YEAR FROM v_start)::integer = p_year
                                     AND EXTRACT(MONTH FROM v_start)::integer > 1,
        'claimed_sgd', v_used,
        'remaining_sgd', v_limit - v_used);
END;
$function$;

-- ── 5 · my_period_labels(Q12):返回表多一列 currency → DROP 再 CREATE(镜像原样)────────────────
DROP FUNCTION public.my_period_labels();

-- db/functions/my_period_labels.sql
-- AUDIT-TRAIL-1d-3(Tim 2026-10-04 的折入:修 Q19,docs/known-issues.md 的 AT1D1-ME-READS-HR-ONLY-PERIOD-TABLES)
--
-- 【它答什么】调用者【自己的】考勤行与工资单落在哪几个期间 —— 每一个期间只给【编号与月份】,别的一列都不给。
--   /me 的考勤表与工资单表要这两样去配"哪一个月 · 哪一张",而两张期间表的读策略都只有 module.hr.view
--   (attendance_periods.sql、payroll_periods.sql),于是一个不持它的员工(线上:warehouse 那一个账号)读到 0 行,
--   屏幕上的编号与月份印成 "—"(AT-1d-2 以 fusheng@ 的身份量过:1 行自己的考勤,0 个它的期间)。
-- 【为什么是一支属主函数,而不是一条"本人的期间"自读策略】一条策略放进来的是【整行】:工资期上有五个合计、
--   一期只有一两个人时合计就是一个人的工资(Q18 登记的那一件);考勤期间上有完成人、重开理由。Tim 的话是
--   "只给编号与月份,别的都不给" —— 列表能做到,策略做不到。
-- 【主语就是调用者】没有参数;current_user_employee() 解析的是调用者自己 —— 对 anon 是 NULL,于是 0 行。
--   只回那几个【有一行是你的】期间:没有你的行的期间、别人的期间,一个都不回。
-- 【为什么是 DEFINER】只用来越过两张期间表的读策略(它们只给 hr.view);行与列都由上面那两条收住。
-- ★ U1-A(Tim 的 UNBLOCK-1 Q12,2026-10-05):多一列 currency —— 工资单那一期自己的币种(考勤那几行是 NULL:考勤没有币种)。
--   /me 的工资单五栏按【那一期的币种】格式化(USD 的一期是可能的:upsert_payroll_period 收任何一个在册币种),
--   而不持 module.hr.view 的员工此前读不到那一期,金额印成不带币种的数字。币种是"本人看得见的那一期"的一个属性,
--   与编号、月份同一类;合计、状态、备注仍然一列都不给。返回表变了 → 迁移里 DROP 再 CREATE(CREATE OR REPLACE 改不了返回表)。
CREATE OR REPLACE FUNCTION public.my_period_labels()
 RETURNS TABLE(kind text, period_id uuid, code text, period_month date, currency text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT 'attendance'::text, ap.id, ap.code, ap.period_month, NULL::text
      FROM attendance_periods ap
     WHERE EXISTS (SELECT 1 FROM attendance_lines al
                    WHERE al.period_id = ap.id AND al.employee_id = current_user_employee())
    UNION ALL
    SELECT 'payroll'::text, pp.id, pp.code, pp.period_month, pp.currency
      FROM payroll_periods pp
     WHERE EXISTS (SELECT 1 FROM payroll_lines pl
                    WHERE pl.payroll_period_id = pp.id AND pl.employee_id = current_user_employee())
$function$;

COMMENT ON FUNCTION public.my_period_labels() IS
    'AUDIT-TRAIL-1d-3(Q19):调用者自己的考勤行与工资单所在的期间 —— 只给编号与月份(kind · period_id · code · period_month);U1-A(UNBLOCK-1 Q12)加 currency(工资单那一期的币种,考勤为 NULL),别的一列都不给。两张期间表的读策略只有 module.hr.view,而 /me 要这两样去配月份;一条自读策略会放进整行(工资期的合计在一期只有一两个人时就是一个人的工资),所以是一支属主函数,行由 current_user_employee() 收住(对 anon 是 NULL → 0 行),列由返回表收住。';

REVOKE EXECUTE ON FUNCTION public.my_period_labels() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_period_labels() TO authenticated, service_role;

-- ── 6 · 新的遮蔽伴生视图(镜像原样)────────────────────────────────────────

-- db/views/journal_lines_masked.sql
-- U1-A(Tim 的 UNBLOCK-1 Q1 · Q2 · Q3,2026-10-05):分录行的遮蔽伴生视图 —— 【工资分录的金额】要 data.view_pay。
--
-- 【遮什么】source_type = 'payroll' 的分录(过账、发薪、公积金、扣款,以及冲销件 —— 冲销照抄 source_type)的每一行:
--   debit · credit · amount_ccy 三个金额。行本身、科目、行摘要(员工编号 + 姓名,Q3)、币种、汇率照常给。
--   一个人的工资就是这几个数;一期只有一个人时,连这一期的合计也是他的工资(Q1)—— 所以遮的是【每一行】,不是"按人那几行"。
-- 【为什么另起一张视图】journal_lines 上那条 restrictive 策略("amounts: …")让不持 view_pay 的人经 API 读不到那几行;
--   页面要的是【那一行在、金额受限】,于是页面读这里(属主身份,绕过那条策略),行谓词与基表的 permissive 策略同一个码。
-- 【side 与 amounts_restricted 是派生列】金额受限时页面仍要知道这一行记在哪一边、以及"这是受限,不是零"
--   (AGENTS.md:0.00 与「受限」不是一回事)。两列都不在基表里,change_log_mask_gaps 不把它们算作遮蔽列。
-- 【判据只有一份】CASE 里那一句与 change_log_mask_rules 的 pay_journal 规则(change_log_rule_visible)逐字同一个判据:
--   持 data.view_pay,或这一行所在分录的 source_type 不是 'payroll'。

CREATE VIEW public.journal_lines_masked WITH (security_invoker = off) AS
 SELECT l.id,
    l.entry_id,
    l.account_id,
        CASE
            WHEN has_permission('data.view_pay'::text) OR e.source_type IS DISTINCT FROM 'payroll'::text THEN l.debit
            ELSE NULL::numeric
        END AS debit,
        CASE
            WHEN has_permission('data.view_pay'::text) OR e.source_type IS DISTINCT FROM 'payroll'::text THEN l.credit
            ELSE NULL::numeric
        END AS credit,
    l.currency,
        CASE
            WHEN has_permission('data.view_pay'::text) OR e.source_type IS DISTINCT FROM 'payroll'::text THEN l.amount_ccy
            ELSE NULL::numeric
        END AS amount_ccy,
    l.fx_rate,
    l.line_memo,
    l.created_at,
    l.fx_rate_date,
    l.tax_code,
        CASE
            WHEN l.debit > 0::numeric THEN 'debit'::text
            ELSE 'credit'::text
        END AS side,
    NOT (has_permission('data.view_pay'::text) OR e.source_type IS DISTINCT FROM 'payroll'::text) AS amounts_restricted
   FROM journal_lines l
     JOIN journal_entries e ON e.id = l.entry_id
  WHERE has_permission('module.finance.view'::text);

COMMENT ON VIEW public.journal_lines_masked IS
    'U1-A(UNBLOCK-1 Q1–Q3):分录行的遮蔽伴生视图。source_type = payroll 的分录每一行的 debit / credit / amount_ccy 只给持 data.view_pay 的人;行、科目、行摘要照常给。side 与 amounts_restricted 是派生列:受限时页面仍知道这一行记在哪一边,并把它说成「受限」而不是 0.00。行谓词 = journal_lines 的 permissive 读策略(module.finance.view)。';

GRANT SELECT ON public.journal_lines_masked TO authenticated;

-- db/views/approval_log_masked.sql
-- U1-A(UNBLOCK-1 Q8 · Q10,2026-10-05):审批留痕的遮蔽伴生视图。
-- 【遮什么】amount_ccy 与 amount_base —— 工资申请那一行是一期的工资合计(要 data.view_pay),医疗报销那一行是报销金额
--   (要 data.view_health,或那张报销单就是读者本人的)。其余种类原样给。判据住在 approval_log_amount_visible,
--   change_log_mask_rules 的 apr_amount 规则调的是同一支。
-- 【行谓词】approval_log_readable(subject_type) —— 与基表那条策略调同一支函数(属主视图绕过 RLS,所以这里必须再问一次)。
-- 【列】基表的每一列都在这里(colgrant:一张表有了 _masked 伴生视图,它的每一列都必须出现在视图里)。

CREATE VIEW public.approval_log_masked WITH (security_invoker = off) AS
 SELECT id,
    seq,
    subject_type,
    subject_id,
    subject_code,
    decision,
    level,
    actor_user_id,
    decided_at,
    note,
        CASE
            WHEN approval_log_amount_visible(subject_type, subject_id) THEN amount_ccy
            ELSE NULL::numeric
        END AS amount_ccy,
    currency,
    fx_rate,
        CASE
            WHEN approval_log_amount_visible(subject_type, subject_id) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    is_reconstructed,
    reconstruction_note,
    created_at,
    self_decided
   FROM approval_log
  WHERE approval_log_readable(subject_type);

COMMENT ON VIEW public.approval_log_masked IS
    'U1-A(UNBLOCK-1 Q8 · Q10):审批留痕的遮蔽伴生视图。工资申请那一行的金额要 data.view_pay,医疗报销那一行的金额要 data.view_health 或本人;判据在 approval_log_amount_visible。行谓词 approval_log_readable 与基表策略同一支函数。';

GRANT SELECT ON public.approval_log_masked TO authenticated;

-- db/views/medical_claims_masked.sql
-- U1-A(UNBLOCK-1 Q8,2026-10-05):医疗报销的遮蔽伴生视图。description(看病的事由)与 amount_sgd(金额)要 data.view_health,
--   【对本人让路】(行谓词与列遮蔽两处都带 OR employee_id = current_user_employee() —— payroll_lines_masked 同一个形状)。
-- 行谓词 = 基表的两条读策略(module.hr.view,或本人)。每一列都在这里(colgrant)。
-- 判据与 change_log_mask_rules 的 code_or_self:data.view_health:employee_id 逐字同一个。

CREATE VIEW public.medical_claims_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    employee_id,
    claim_date,
    claim_year,
        CASE
            WHEN has_permission('data.view_health'::text) OR employee_id = current_user_employee() THEN amount_sgd
            ELSE NULL::numeric
        END AS amount_sgd,
        CASE
            WHEN has_permission('data.view_health'::text) OR employee_id = current_user_employee() THEN description
            ELSE NULL::text
        END AS description,
    receipt_ref,
    status,
    decided_at,
    decided_by,
    decision_notes,
    expense_id,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    withdrawn_at
   FROM medical_claims
  WHERE has_permission('module.hr.view'::text) OR employee_id = current_user_employee();

COMMENT ON VIEW public.medical_claims_masked IS
    'U1-A(UNBLOCK-1 Q8):医疗报销的遮蔽伴生视图。description 与 amount_sgd 要 data.view_health 或本人;行谓词 = 基表的读策略(module.hr.view 或本人)。';

GRANT SELECT ON public.medical_claims_masked TO authenticated;

-- db/views/leave_requests_masked.sql
-- U1-A(UNBLOCK-1 Q8,2026-10-05):请假单的遮蔽伴生视图。reason · certificate_ref · exception_reason 是健康数据
--   (请假的事由、病假单号、例外的理由),要 data.view_health,【对本人让路】。
-- 行谓词 = 基表的两条读策略(module.hr.view,或本人)。每一列都在这里(colgrant)。
-- 判据与 change_log_mask_rules 的 code_or_self:data.view_health:employee_id 逐字同一个。

CREATE VIEW public.leave_requests_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    employee_id,
    leave_type_code,
    start_date,
    end_date,
    start_half_day,
    end_half_day,
    days,
        CASE
            WHEN has_permission('data.view_health'::text) OR employee_id = current_user_employee() THEN reason
            ELSE NULL::text
        END AS reason,
        CASE
            WHEN has_permission('data.view_health'::text) OR employee_id = current_user_employee() THEN certificate_ref
            ELSE NULL::text
        END AS certificate_ref,
    status,
    decided_at,
    decided_by,
    decision_notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    is_exception,
        CASE
            WHEN has_permission('data.view_health'::text) OR employee_id = current_user_employee() THEN exception_reason
            ELSE NULL::text
        END AS exception_reason
   FROM leave_requests
  WHERE has_permission('module.hr.view'::text) OR employee_id = current_user_employee();

COMMENT ON VIEW public.leave_requests_masked IS
    'U1-A(UNBLOCK-1 Q8):请假单的遮蔽伴生视图。reason / certificate_ref / exception_reason 要 data.view_health 或本人;行谓词 = 基表的读策略(module.hr.view 或本人)。';

GRANT SELECT ON public.leave_requests_masked TO authenticated;

-- db/views/payroll_periods_masked.sql
-- U1-A(UNBLOCK-1 Q9,2026-10-05):工资期的遮蔽伴生视图。五个合计要 data.view_pay —— 一期只有一两个人时,合计就是一个人的工资。
--   不对本人让路:一期的合计不是"他自己的",是这一期所有人的(本人在 /me 上读自己那一行工资,经 payroll_lines_masked)。
--   与财务那一侧的 payroll_period_lookup 同一个判据(Q9:一条规矩,不按人数设门槛)。
-- 行谓词 = 基表的读策略(module.hr.view)。每一列都在这里(colgrant)。判据与 change_log_mask_rules 的 code:data.view_pay 同一个。

CREATE VIEW public.payroll_periods_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    period_month,
    payment_date,
    currency,
    fx_rate,
    status,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN gross_total
            ELSE NULL::numeric
        END AS gross_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN employer_cpf_total
            ELSE NULL::numeric
        END AS employer_cpf_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN employee_cpf_total
            ELSE NULL::numeric
        END AS employee_cpf_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN other_deductions_total
            ELSE NULL::numeric
        END AS other_deductions_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN net_pay_total
            ELSE NULL::numeric
        END AS net_pay_total,
    journal_entry_id,
    source_note,
    notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    cpf_paid_at,
    cpf_journal_entry_id,
    deductions_paid_at,
    deductions_journal_entry_id
   FROM payroll_periods
  WHERE has_permission('module.hr.view'::text);

COMMENT ON VIEW public.payroll_periods_masked IS
    'U1-A(UNBLOCK-1 Q9):工资期的遮蔽伴生视图。五个合计要 data.view_pay(不按人数设门槛,不对本人让路);行谓词 = 基表的读策略(module.hr.view)。';

GRANT SELECT ON public.payroll_periods_masked TO authenticated;

-- db/views/payroll_requests_masked.sql
-- U1-A(UNBLOCK-1 Q10,2026-10-05):工资申请的遮蔽伴生视图。snapshot(逐行的员工 · 应发 · 公积金……)、gross_total 与 amount_base
--   要 data.view_pay —— 与这一期的合计同一个判据(Q9)。
-- 行谓词 = 基表的读策略(module.hr.view)。每一列都在这里(colgrant)。判据与 change_log_mask_rules 的 code:data.view_pay 同一个。

CREATE VIEW public.payroll_requests_masked WITH (security_invoker = off) AS
 SELECT id,
    payroll_period_id,
    kind,
    status,
    label,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN snapshot
            ELSE NULL::jsonb
        END AS snapshot,
    currency,
    fx_rate,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN gross_total
            ELSE NULL::numeric
        END AS gross_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    notes,
    decided_at,
    decided_by,
    decision_notes,
    withdrawn_at,
    withdrawn_by,
    executed_at,
    executed_by,
    result_journal_entry_id,
    created_at,
    created_by
   FROM payroll_requests
  WHERE has_permission('module.hr.view'::text);

COMMENT ON VIEW public.payroll_requests_masked IS
    'U1-A(UNBLOCK-1 Q10):工资申请的遮蔽伴生视图。snapshot / gross_total / amount_base 要 data.view_pay;行谓词 = 基表的读策略(module.hr.view)。';

GRANT SELECT ON public.payroll_requests_masked TO authenticated;

-- ── 7 · 改过的视图(镜像原样,CREATE OR REPLACE)───────────────────────────

-- db/views/employees_masked.sql
-- 员工档案的遮蔽伴生视图。身份/联系方式要 data.view_identity,月固定工资要 data.view_pay,
-- 两者都【对本人让路】。
-- ★ U1-A(UNBLOCK-1 Q6,2026-10-05):notes 与 separation_notes 要 module.hr.view,【不对本人让路】——
--   那是人事写给人事的话(/hr/employees/[id] 才印它们,/me 从来不印)。个人数据导出照旧交给本人(Q7,刻意的例外)。
--
-- 【年假三列都是派生的】annual_leave_days 那一列已随 HR-2c 删除。
--   annual_leave_rate_days       年度【费率】,界面必须按费率标,不是余额
--   annual_leave_accrued_days    到今天已经挣到的
--   annual_leave_available_days  扣掉已请、加上结转后真正能请的
-- 软删的行用 deleted_at 守卫(那些函数对已删除员工会报错)。
--
-- NOTE: introduced by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       annual-rate form by db/migrations/2026-08-07-hr2c-fu1-annual-rate-and-immutable-rates.sql.
--       PDPA-1 追加 anonymised_at / anonymised_by —— **排在末尾**,因为
--       CREATE OR REPLACE VIEW 只许追加,不许改动既有列的次序。两列都不遮蔽:
--       "这一行已经不再保有个人数据"这件事本身不是个人数据,而且必须看得见。

CREATE OR REPLACE VIEW public.employees_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    legal_name,
    preferred_name,
    department_id,
    -- KPI-1:employees.job_title 已删,头衔改从【职位】来。
    -- **列名保持 job_title**,是为了不惊动这张视图的下游读者 ——
    -- 它回答的仍然是同一个问题(这个人的头衔是什么),只是真源换了。
    (SELECT p.title FROM positions p WHERE p.id = employees.position_id) AS job_title,
    manager_id,
    employment_type,
    work_category,
    hire_date,
    probation_end_date,
    employment_status,
    separation_date,
    separation_type,
        CASE
            WHEN has_permission('module.hr.view'::text) THEN separation_notes
            ELSE NULL::text
        END AS separation_notes,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_email
            ELSE NULL::text
        END AS work_email,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_phone
            ELSE NULL::text
        END AS work_phone,
    residency_status,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN identity_no
            ELSE NULL::text
        END AS identity_no,
    work_pass_type,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_pass_no
            ELSE NULL::text
        END AS work_pass_no,
    work_pass_issue_date,
    work_pass_expiry_date,
    user_id,
        CASE
            WHEN has_permission('module.hr.view'::text) THEN notes
            ELSE NULL::text
        END AS notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    confirmation_date,
        CASE
            WHEN has_permission('data.view_pay'::text) OR id = current_user_employee() THEN monthly_salary
            ELSE NULL::numeric
        END AS monthly_salary,
    monthly_salary_set,
    review_exempt,
        CASE
            WHEN deleted_at IS NULL THEN annual_leave_rate_per_year(id)
            ELSE NULL::numeric
        END AS annual_leave_rate_days,
        CASE
            WHEN deleted_at IS NULL THEN accrued_annual_leave(id)
            ELSE NULL::numeric
        END AS annual_leave_accrued_days,
        CASE
            WHEN deleted_at IS NULL THEN (leave_balance_internal(id, 'annual'::text) ->> 'available'::text)::numeric
            ELSE NULL::numeric
        END AS annual_leave_available_days,
    anonymised_at,
    anonymised_by,
    -- KPI-1:新列加在【末尾】—— CREATE OR REPLACE VIEW 只允许末尾追加列。
    -- 【它必须出现在这张视图里】employees 是遮蔽表,而 colgrant 那道闸要求它的
    -- 每一列要么被列授权、要么出现在 _masked 里(WO-1a 那一课)。
    position_id,
    -- UI-1b:同 position_id —— employees 是遮蔽表,colgrant 要求每一列要么被列授权、
    -- 要么出现在这张视图里(WO-1a 那一课)。greeting_name 两样都做了:它不敏感。
    greeting_name,
    -- OVERTIME-1:同上 —— employees 是遮蔽表,新列要么被列授权、要么出现在这里;is_site_staff 两样都做了。
    is_site_staff,
    -- NAME-1:同上 —— 与 legal_name 同一个可见性,不遮蔽。
    first_name,
    last_name
   FROM employees
  WHERE has_permission('module.hr.view'::text) OR id = current_user_employee();

-- db/views/medical_claim_status.sql
-- 医疗报销一览。HR 看全部,员工看自己的。
-- settlement_state 从【已过账的付款分配】推导 —— 与 ap_open_items 用同一个信号,
-- 因为 expenses.payment_status 对"建单时未付、之后经付款流程结清"的费用不会翻转。
--
-- NOTE: updated by db/migrations/2026-08-02-hr2b-leave-exceptions-and-claims.sql.

-- AP-RECON-1(2026-09-24):「付清」对着【净额 + 进项税】的本位币判(amount_base + tax_base,
-- 过账时存下的两个数)—— 与 ap_open_items 的费用支 doc_value_base 同一个数。
--
-- CLAIM-GST-1(2026-09-24):末尾【追加】expense_tax_base —— 申报额是含税总额,税从里面拆出来;
-- 建了费用之后,详情页读 expense_amount_base(净额)与它,说得出那个总额被拆成了什么。
-- 医疗申报只收本位币,所以本位币两个数就是单据上的两个数。只追加 → CREATE OR REPLACE。

-- ★ U1-A(UNBLOCK-1 Q8,2026-10-05):金额与事由要 data.view_health,或本人 —— 与 medical_claims_masked 同一个判据。
--   报销单关联的费用金额、已付与税额是【同一个数】的另外三种说法(费用由报销单生成),一起遮;结算状态照常算、照常给
--   (它说的是"付到哪一步",不是多少钱)。⚠ 那一张费用单本身在财务那一侧照旧读得到(常设裁定 1:持 module.finance.view
--   就看得见钱)—— 登记在 docs/known-issues.md 的 U1A-MEDICAL-EXPENSE-AMOUNT-ON-FINANCE-SIDE。
CREATE OR REPLACE VIEW public.medical_claim_status WITH (security_invoker = off) AS
 SELECT mc.id AS claim_id,
    mc.code,
    mc.employee_id,
    e.code AS employee_code,
    e.legal_name,
    mc.claim_date,
    mc.claim_year,
        CASE
            WHEN has_permission('data.view_health'::text) OR mc.employee_id = current_user_employee() THEN mc.amount_sgd
            ELSE NULL::numeric
        END AS amount_sgd,
        CASE
            WHEN has_permission('data.view_health'::text) OR mc.employee_id = current_user_employee() THEN mc.description
            ELSE NULL::text
        END AS description,
    mc.receipt_ref,
    mc.status,
    mc.decided_at,
    mc.expense_id,
    mc.expense_id IS NOT NULL AS linked_to_expense,
    ex.code AS expense_code,
        CASE
            WHEN has_permission('data.view_health'::text) OR mc.employee_id = current_user_employee() THEN ex.amount_base
            ELSE NULL::numeric
        END AS expense_amount_base,
        CASE
            WHEN has_permission('data.view_health'::text) OR mc.employee_id = current_user_employee() THEN COALESCE(pay.settled_base, 0::numeric)
            ELSE NULL::numeric
        END AS settled_base,
        CASE
            WHEN mc.status <> 'approved'::text THEN mc.status
            WHEN mc.expense_id IS NULL THEN 'awaiting_payment_run'::text
            WHEN COALESCE(pay.settled_base, 0::numeric) >= (ex.amount_base + COALESCE(ex.tax_base, 0::numeric)) THEN 'paid'::text
            WHEN COALESCE(pay.settled_base, 0::numeric) > 0::numeric THEN 'part_paid'::text
            ELSE 'expense_raised'::text
        END AS settlement_state,
        CASE
            WHEN has_permission('data.view_health'::text) OR mc.employee_id = current_user_employee() THEN ex.tax_base
            ELSE NULL::numeric
        END AS expense_tax_base
   FROM medical_claims mc
     JOIN employees e ON e.id = mc.employee_id
     LEFT JOIN expenses ex ON ex.id = mc.expense_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled_base
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.expense_id = ex.id) pay ON true
  WHERE mc.deleted_at IS NULL AND (has_permission('module.hr.view'::text) OR mc.employee_id = current_user_employee());

-- db/views/equipment_maintenance_advice.sql
-- EQP-2b:每一条保养/维修记录的【资本化建议】。
--
-- 【一个数都没写死】两个阈值都现读 maintenance_settings —— 与 grn_discrepancies
-- 读 receiving_settings 同一条。fixture 76 立下的判据:在同一个事务里改配置,
-- 看结论【两个方向都】动;只调一个方向,一个"永远返回同一个答案"的实现也能过。
--
-- 【它只说话,不拦人】是否资本化 = 延长寿命或提高产能(人的判断)【并且】
-- 花费够大(这个数)。系统只答得了后一半,所以这里没有任何拒绝。
--
-- 【meets_threshold 为 NULL 的两种情形都不是"不达标"】没挂支出单(没花钱,
-- 或钱还没记),以及机器记录成本为 0(零成本卡还没拿到发票)—— 空不是零。
--
-- 【equipment_cost_base 是【记录成本】,不是取得原价】EQP-1b-iii 之后它等于
-- 未冲销成本明细之和,每资本化一次就长大一次。两者的区别在第一次资本化大修
-- 之后才开始咬人,而那时该按哪个算是一次会计决定,不是一个默认值。
--
-- NOTE: introduced by db/migrations/2026-08-21-eqp2b-maintenance-and-repair-records.sql.
--
-- ★ U1-A(Tim 的 UNBLOCK-1 Q13 · AT-1b Q14,2026-10-05):维修花了多少(work_cost_base)、机器的记录成本(equipment_cost_base)
--   与两者之比(pct_of_equipment_cost —— 知道一个就推得出另一个)只给持 module.finance.view 的人。两张基表(expenses、fixed_assets)
--   本来就只给财务;这张属主视图的门是"财务【或】加工",于是只持加工权限的人(warehouse)此前读得到这两个数。
--   meets_threshold 照常给 —— 它就是那一句建议本身,只说够不够,不说多少;门(行谓词)不动,加工的人照旧看得见每一条记录与建议。

CREATE OR REPLACE VIEW public.equipment_maintenance_advice WITH (security_invoker = off) AS
 SELECT m.id AS maintenance_id,
    m.equipment_id,
    fa.code AS equipment_code,
    m.performed_on,
    m.kind,
    m.capitalised,
    m.expense_id,
        CASE
            WHEN has_permission('module.finance.view'::text) THEN e.amount_base
            ELSE NULL::numeric
        END AS work_cost_base,
        CASE
            WHEN has_permission('module.finance.view'::text) THEN fa.cost_base
            ELSE NULL::numeric
        END AS equipment_cost_base,
    s.capitalise_pct_of_cost,
    s.capitalise_floor_base,
        CASE
            WHEN NOT has_permission('module.finance.view'::text) THEN NULL::numeric
            WHEN e.amount_base IS NULL OR fa.cost_base IS NULL OR fa.cost_base = 0::numeric THEN NULL::numeric
            ELSE round(e.amount_base / fa.cost_base * 100::numeric, 2)
        END AS pct_of_equipment_cost,
        CASE
            WHEN e.amount_base IS NULL OR fa.cost_base IS NULL OR fa.cost_base = 0::numeric THEN NULL::boolean
            ELSE (e.amount_base / fa.cost_base * 100::numeric) >= s.capitalise_pct_of_cost AND e.amount_base >= s.capitalise_floor_base
        END AS meets_threshold
   FROM equipment_maintenance m
     JOIN fixed_assets fa ON fa.id = m.equipment_id
     LEFT JOIN expenses e ON e.id = m.expense_id AND e.status = 'posted'::text
     CROSS JOIN maintenance_settings s
  WHERE has_permission('module.finance.view'::text) OR has_permission('module.processing.view'::text);

-- db/views/bank_unmatched_journal_lines.sql
-- 匹配工作台的候选清单:银行科目('1000'/'1010')上、所属分录 posted、
-- 原币 = 账户本币(bank_native_currency)、且尚未被任何报表行认领的分录行。
-- 收付款 / 已付开支 / 手工分录都会产出这样的行 —— 这正是"报表行配分录行"
-- 这一设计通用的原因。~~SECURITY INVOKER。~~
-- ★ U1-A(Tim 的 UNBLOCK-1 Q1 · Q2,2026-10-05):改成【属主权限】,门写回视图体里(module.finance.view —— 与 journal_lines /
--   journal_entries 的 permissive 读策略同一个码)。理由:journal_lines 上那条 restrictive 策略让不持 data.view_pay 的财务读者
--   读不到工资分录的行;invoker 时,发薪那几条银行贷方会【悄悄】从候选清单里消失 —— 而它们正是对账单上那几笔工资转账要配的行。
--   现在行照常在,金额(amount_ccy)按同一个判据受限(持 data.view_pay,或分录不是工资分录),amounts_restricted 说"受限,不是 0"。
--   能配(match_bank_line)要 module.finance.edit,而今天持它的角色都持 data.view_pay;这里只是让看的人看见同一张清单。
-- NOTE: introduced by db/migrations/2026-07-30-phase3-s3a-bank-reconciliation.sql.

CREATE OR REPLACE VIEW public.bank_unmatched_journal_lines
WITH (security_invoker = off) AS
 SELECT l.id AS journal_line_id,
    e.id AS entry_id,
    e.code AS entry_code,
    e.entry_date,
    e.memo,
    e.source_type,
    e.source_id,
    a.code AS account_code,
    l.currency,
        CASE
            WHEN has_permission('data.view_pay'::text) OR e.source_type IS DISTINCT FROM 'payroll'::text THEN l.amount_ccy
            ELSE NULL::numeric
        END AS amount_ccy,
        CASE
            WHEN l.debit > 0::numeric THEN 'debit'::text
            ELSE 'credit'::text
        END AS direction,
    NOT (has_permission('data.view_pay'::text) OR e.source_type IS DISTINCT FROM 'payroll'::text) AS amounts_restricted
   FROM journal_lines l
     JOIN accounts a ON a.id = l.account_id
     JOIN journal_entries e ON e.id = l.entry_id
  WHERE (a.code = ANY (ARRAY['1000'::text, '1010'::text])) AND e.status = 'posted'::text AND l.currency = bank_native_currency(a.code) AND NOT (EXISTS ( SELECT 1
           FROM bank_line_matches m
          WHERE m.journal_line_id = l.id)) AND has_permission('module.finance.view'::text);

-- db/views/fx_rate_gaps.sql
-- 【缺牌价的日子】:某一天某个外币需要牌价、而当天缺了要的那几侧,一行一个 (日期, 币种)。
-- C5 让"当天没牌价"的交易直接失败,所以这里主要顶出来的是:
-- 手工分录显式给了汇率的那些天(post_journal_entry 仍收手工汇率),
-- 以及换基准之前的旧数据。牌价是每日日课 —— 这张视图就是漏掉那天的账单。
-- ~~SECURITY INVOKER:底下 journal/fx 各自的 RLS 说了算。~~
-- ★ U1-A(Tim 的 UNBLOCK-1 Q2,2026-10-05):改成【属主权限】,过账那一支自己带门(module.finance.view —— 与 journal_lines /
--   journal_entries 的 permissive 读策略同一个码);报价那一支的两张表读策略本来就是 USING (true),所以对每一个读者结果不变。
--   理由:journal_lines 上那条 restrictive 策略让不持 data.view_pay 的财务读者读不到工资分录的行;invoker 时,一期外币发薪的日子会
--   【悄悄】从缺牌价清单里少掉。这张视图只说日期与币种,不说金额,所以属主身份不交出任何新的东西。
--
-- ════════════════════════════════════════════════════════════════════════════
-- FX-RATES-1(2026-08-27):**这张视图【看不见月末】,而那是刻意的。**
-- 它的日期只有两个来源:【过账日】与【报价日】。一个既没有过账、也没有报价的
-- 月末(例如 2026-08-31)对它是【结构性不可见】的 —— 偏偏月末重估非要那天的
-- 中间价不可。那个盲区由 `fx_month_end_readiness` 单独回答。
--
-- ★【不要把两张合并】★ 本视图的每一行都【有证据撑着】:那天确实有过账,
--   或确实有报价。而"月末"是一个【被发明出来的日期】—— 把它塞进来,
--   毁掉的正是"每一行都有证据"这个性质,而那是本视图值得被相信的全部理由。
--   两张视图,两个意思。
-- ════════════════════════════════════════════════════════════════════════════
--
-- NOTE: introduced by db/migrations/2026-08-04-fin0-sgd-base-and-fx-policy.sql.

-- METAL-3(2026-08-11):第二个日期来源 —— 【有报价、而报价币种不是本位币的那些天】。
-- 原来的来源只有【过账】,而报价日不是过账日,CNY 更是永远不会过账(它不可交易)。
-- 于是缺一条 CNY 中间价只会在有人计价时以一次拒绝现身 —— 那是错的一头:
-- 等人处理的事应当先上看板。两个来源要的价种不同(过账日三种,报价日只要 mid),
-- gap_source 列说明这一行是【为什么】要价。

-- ════════════════════════════════════════════════════════════════════════════
-- FXG-1(2026-08-17):【一行一个数,一个数一件事】—— 原来的 txn_count 已经删掉。
--
-- METAL-3 加了第二支来源,却让两支共用一列计数:过账那一支数的是【凭证】,
-- 报价那一支数的是【报价条数】,而外层 sum() 把它们加在一起。页面的文案一律念成
-- "当天 N 笔凭证"。三种谎,全部实测复现过(回滚型探针,线上真实视图输出):
--
--   纯报价日  2026-08-20 CNY {mid}                 txn_count=2  quote
--             —— 那天一笔外币凭证都没有,屏幕上却写"当天 2 笔凭证"。
--   混合日    2026-08-21 CNY {tt_buy,tt_sell,mid}  txn_count=2  posting+quote
--             —— 那个 2 是【1 笔凭证 + 1 条报价】,两种单位相加。
--
-- 线上今天恰好只有 posting 那一支的 7 行,所以这三种谎【一次都没有被看见过】——
-- 这正是它值得修的理由,不是不值得修的理由。
--
-- 【为什么拆成两列,而不是一列加一个随 gap_source 变的标签】混合日两支【都】命中,
-- 它真的有两个数;一列只能挑一个说,那是另一种撒谎。拆开之后每列单位固定,
-- 页面直接画,不做第二次推导。
--
-- 【0 是一次测量,不是占位】纯报价日的 entry_count = 0:过账那一支扫过了那一天,
-- 确实没有非本位币凭证。与「报表不报这一行 ≠ 报表报了 0」不矛盾 ——
-- 那里的 0 是把"没问过"说成"答案是零",这里是问过了、答案就是零。
--
-- 【消费者】/finance/fx 的缺口块(两个计数 + 按 gap_source 说出这是哪一种缺口)、
-- /finance/month-end 的一步(只数行数)、operations_now 的 fx_rate_gap 支
-- (只读 rate_date / currency / missing_types)。db/fixtures/81 把三种行钉住。
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW public.fx_rate_gaps WITH (security_invoker = off) AS
 SELECT d.rate_date,
    d.currency,
    m.missing_types,
    d.entry_count,
    d.quote_count,
    d.gap_source
   FROM ( SELECT u.rate_date,
            u.currency,
            sum(u.entry_count)::bigint AS entry_count,
            sum(u.quote_count)::bigint AS quote_count,
            bool_or(u.src = 'posting'::text) AS needs_settlement_types,
            array_to_string(array_agg(DISTINCT u.src ORDER BY u.src), '+'::text) AS gap_source
           FROM ( SELECT e.entry_date AS rate_date,
                    l.currency,
                    count(DISTINCT l.entry_id) AS entry_count,
                    0::bigint AS quote_count,
                    'posting'::text AS src
                   FROM journal_lines l
                     JOIN journal_entries e ON e.id = l.entry_id
                  WHERE l.currency <> (( SELECT c.code
                           FROM currencies c
                          WHERE c.is_base)) AND e.status = 'posted'::text AND has_permission('module.finance.view'::text)
                  GROUP BY e.entry_date, l.currency
                UNION ALL
                 SELECT mp.price_date AS rate_date,
                    i.quote_currency AS currency,
                    0::bigint AS entry_count,
                    count(*) AS quote_count,
                    'quote'::text AS src
                   FROM metal_prices mp
                     JOIN metal_price_indices i ON i.code = mp.price_index
                  WHERE mp.deleted_at IS NULL AND i.is_active AND i.quote_currency IS NOT NULL AND i.quote_currency <> (( SELECT c.code
                           FROM currencies c
                          WHERE c.is_base))
                  GROUP BY mp.price_date, i.quote_currency) u
          GROUP BY u.rate_date, u.currency) d
     CROSS JOIN LATERAL ( SELECT array_agg(t.t) AS missing_types
           FROM unnest(
                CASE
                    WHEN d.needs_settlement_types THEN ARRAY['tt_buy'::text, 'tt_sell'::text, 'mid'::text]
                    ELSE ARRAY['mid'::text]
                END) t(t)
          WHERE NOT (EXISTS ( SELECT 1
                   FROM fx_rate_asof(d.currency, d.rate_date, t.t) fx_rate_asof(rate, as_of)))) m
  WHERE m.missing_types IS NOT NULL;

-- db/views/fx_month_end_readiness.sql
-- FX-RATES-1:**月末重估跑不跑得起来 —— 一个月末一个币种一行。**
--
-- ★【为什么这是【另一张】视图,而不是给 fx_rate_gaps 加第三种 gap_source】★
--   **两张视图断言的是两件不同的事,而其中一件的可信度全靠它【不】做另一件:**
--     · `fx_rate_gaps`:「**发生过事情**的那一天缺牌价」——
--       它的每一行都有证据撑着(那天有过账,或那天有报价)。
--     · 本视图:「**可能什么都还没发生**的那一天【仍然】需要牌价」——
--       月末正是这样的日子:2026-08-31 上没有一笔过账、没有一条报价,
--       而月末重估**非要它的中间价不可**。
--   把"发明出来的日期"塞进 fx_rate_gaps,会毁掉【它每一行都有证据】这个性质,
--   而那正是它值得被相信的全部理由。**所以:两张视图,两个意思,不要合并。**
--   (同一段话抄在 fx_rate_gaps 的文件头上。)
--
-- 【问的是 fx_rate_asof,不是精确匹配】因为重估问的就是它:月末落在周六时,
-- 用周五的中间价是对的(FIN-19 的有界回溯),那种日子【就绪】,不该报成缺。
--
-- 【revalued 用 status='posted',而这是【对的】那一类用法】它问的是
-- "这一期已经重估过了吗" ——【单张分录还活着没有】,不是求和
-- (AGENTS.md「求和 vs 判活」那一节)。
--
-- 【范围由数据定】从第一笔外币货币性分录所在的月份起,到当月止。
-- 没有外币分录就一行都没有 —— 空集在这里是正确答案,不是失败。
-- SECURITY INVOKER。
--
-- NOTE: introduced by db/migrations/2026-08-27-fxrates1-one-write-path-history-and-month-end-readiness.sql.

-- ★ U1-A(Tim 的 UNBLOCK-1 Q2,2026-10-05):改成【属主权限】,外币行那一支自己带门(module.finance.view —— 与 journal_lines /
--   journal_entries 的 permissive 读策略同一个码)。月份只从那一支长出来,所以对一个不持它的读者照旧是 0 行;对持它的读者,
--   重估那两个 EXISTS 以属主身份读 journal_entries,与 invoker 时他自己读到的是同一组行。
--   理由:journal_lines 上那条 restrictive 策略让不持 data.view_pay 的财务读者读不到工资分录的行;invoker 时,一期外币发薪会
--   【悄悄】从"哪些月末要重估"里少掉一个币种。这张视图只说月末、币种与牌价,不说金额。
CREATE OR REPLACE VIEW public.fx_month_end_readiness
WITH (security_invoker = off) AS
 WITH b AS (
         SELECT c_1.code
           FROM currencies c_1
          WHERE c_1.is_base
        ), fx_lines AS (
         SELECT jl.currency,
            e.entry_date
           FROM journal_lines jl
             JOIN accounts a ON a.id = jl.account_id
             JOIN journal_entries e ON e.id = jl.entry_id
          WHERE a.is_monetary AND jl.currency <> (( SELECT b.code
                   FROM b)) AND has_permission('module.finance.view'::text)
        ), ccy AS (
         SELECT DISTINCT fx_lines.currency
           FROM fx_lines
        ), span AS (
         SELECT date_trunc('month'::text, min(fx_lines.entry_date)::timestamp with time zone)::date AS first_month
           FROM fx_lines
        ), months AS (
         SELECT (date_trunc('month'::text, gs.gs)::date + '1 mon'::interval - '1 day'::interval)::date AS month_end
           FROM span,
            LATERAL generate_series(span.first_month::timestamp with time zone, date_trunc('month'::text, CURRENT_DATE::timestamp with time zone)::date::timestamp with time zone, '1 mon'::interval) gs(gs)
          WHERE span.first_month IS NOT NULL
        )
 SELECT m.month_end,
    c.currency,
    ( SELECT x.rate
           FROM fx_rate_asof(c.currency, m.month_end, 'mid'::text) x(rate, as_of)) AS mid_rate,
    ( SELECT x.as_of
           FROM fx_rate_asof(c.currency, m.month_end, 'mid'::text) x(rate, as_of)) AS mid_rate_as_of,
    (( SELECT x.rate
           FROM fx_rate_asof(c.currency, m.month_end, 'mid'::text) x(rate, as_of))) IS NOT NULL AS has_mid,
    (EXISTS ( SELECT 1
           FROM journal_entries e2
          WHERE e2.source_type = 'revaluation'::text AND e2.entry_date = m.month_end AND e2.status = 'posted'::text)) AS revalued,
    (( SELECT x.rate
           FROM fx_rate_asof(c.currency, m.month_end, 'mid'::text) x(rate, as_of))) IS NULL AND NOT (EXISTS ( SELECT 1
           FROM journal_entries e3
          WHERE e3.source_type = 'revaluation'::text AND e3.entry_date = m.month_end AND e3.status = 'posted'::text)) AS blocks_close
   FROM months m
     CROSS JOIN ccy c;

-- ── 8 · 自证 ─────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.u1a_pending_decider_check(p_after boolean DEFAULT true)
 RETURNS TABLE(k text, doc text, raiser text, subject text, deciders int, decider_names text)
 LANGUAGE sql STABLE
AS $f$
WITH fs AS (SELECT approval_level1_role_code AS l1, approval_level2_role_code AS l2 FROM public.finance_settings),
real_perm AS (
    SELECT DISTINCT rp.permission_code, rg.user_id
      FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     CROSS JOIN LATERAL public.real_role_grants(r.code) rg),
people AS (SELECT DISTINCT user_id FROM real_perm),
holds AS (SELECT user_id, array_agg(permission_code) AS codes FROM real_perm GROUP BY user_id),
items AS (
    -- 报销单:分档链,直接问 approval_deciders
    SELECT 'expense_claim'::text AS k, c.code::text AS doc, c.created_by AS raiser, c.employee_id AS subj,
           d.user_id AS u
      FROM public.expense_claims c CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim',
                 public.approval_level_for((SELECT b.amount_base FROM public.expense_claim_amount_base(c.id) b)),
                 c.created_by, c.employee_id, fs.l1, fs.l2) d ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- 采购单:分档链;金额档位按更严的二级问(一级的资格 ⊇ 二级,R1)
    SELECT 'purchase_order', p.code, p.created_by, NULL,
           d.user_id
      FROM public.purchase_orders p CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('purchase_order', 'approve_purchase_order', 2::smallint,
                 p.created_by, NULL, fs.l1, fs.l2) d ON true
     WHERE p.approval_status = 'pending' AND p.deleted_at IS NULL
    UNION ALL
    -- 请假:decide_leave_request 的门(之前 module.hr.edit,之后 action.decide_hr_requests)
    --       + 余额函数要 module.hr.view(或本人)+ 四眼(R2 之后覆盖请假)
    SELECT 'leave_request', l.code, l.created_by, l.employee_id, h.user_id
      FROM public.leave_requests l CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = l.employee_id)
                       AND (public.self_leg(l.created_by, l.employee_id, h.user_id) = 'none'
                            OR (p_after AND public.self_approval_exception('leave_request', l.employee_id, h.user_id, fs.l2)))
     WHERE l.status = 'pending' AND l.deleted_at IS NULL
    UNION ALL
    SELECT 'medical_claim_submitted', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = m.employee_id)
                       AND (public.self_leg(m.created_by, m.employee_id, h.user_id) = 'none'
                            OR public.self_approval_exception('medical_claim', m.employee_id, h.user_id, fs.l2))
     WHERE m.status = 'submitted' AND m.deleted_at IS NULL
    UNION ALL
    -- 已批未付的医疗申报:pay_medical_claim 只要 module.finance.edit,没有自付检查(量过,Tim 的矩阵允许)
    SELECT 'medical_claim_approved (pay)', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m
      LEFT JOIN holds h ON 'module.finance.edit' = ANY (h.codes)
     WHERE m.status = 'approved' AND m.deleted_at IS NULL
    UNION ALL
    SELECT 'performance_review', r.id::text, r.submitted_by, r.employee_id, h.user_id
      FROM public.performance_reviews r
      LEFT JOIN holds h ON (CASE WHEN p_after THEN public.review_approval_code(r.submitted_by, r.employee_id)
                                 ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND public.self_leg(r.submitted_by, r.employee_id, h.user_id) = 'none'
     WHERE r.status = 'submitted'
    UNION ALL
    SELECT 'work_order', w.code, w.created_by, NULL, h.user_id
      FROM public.work_orders w
      -- ROLE-1 Batch 3b:下达归 action.wo_release;建单人不算(按人认)
      LEFT JOIN holds h ON 'action.wo_release' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      -- ROLE-1 Batch 3a:过账归 action.stocktake_post;开单人与录过数的每一个人都不算(按人认)
      LEFT JOIN holds h ON 'action.stocktake_post' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.stocktake_counts c
                                        WHERE c.stocktake_id = s.id
                                          AND public.self_leg(c.counted_by, NULL, h.user_id) <> 'none')
     WHERE s.status = 'open' AND s.deleted_at IS NULL
    UNION ALL
    -- ★ APR-7(grilling Q9):每一条申请链 —— 付款、工资、收货定价、贷项 / 作废、发货放行、手工凭证、仓库申请。
    --   它们在 approval_pending_documents 里带 fixed_level;决定人按 approval_deciders 问(与提交时的
    --   assert_other_decider 同一份判据),门取 approval_chain_gates 里那一行。APR-5b / APR-6 的自证只问了
    --   "这条链此刻有没有人",没有逐张问 —— 这一支补上。
    SELECT pd.subject_type, pd.code, pd.raiser_user_id, pd.subject_employee_id, d.user_id
      FROM public.approval_pending_documents() pd
      JOIN public.approval_chain_gates() g ON g.subject_type = pd.subject_type AND g.level = pd.fixed_level
     CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders(pd.subject_type, g.action_function, pd.fixed_level,
                 pd.raiser_user_id, pd.subject_employee_id, fs.l1, fs.l2) d ON true
     WHERE pd.fixed_level IS NOT NULL AND pd.subject_type NOT IN ('expense_claim', 'purchase_order')
    UNION ALL
    -- ★ APR-9:调薪申请按人路由(pay_decision_code),不在 approval_chain_gates 里 —— 问 salary_change_deciders,
    --   与 submit_salary_change_request 的"别人批得动吗"同一份判据。
    SELECT 'salary_change_request', q.label, q.created_by, q.employee_id, d.user_id
      FROM public.salary_change_requests q
      LEFT JOIN LATERAL public.salary_change_deciders(q.created_by, q.employee_id) d ON true
     WHERE q.status = 'submitted'
)
SELECT i.k, i.doc,
       (SELECT email::text FROM auth.users WHERE id = i.raiser),
       (SELECT legal_name FROM public.employees WHERE id = i.subj),
       count(DISTINCT COALESCE(public.account_person(i.u)::text, i.u::text))::int,
       string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = i.u), ' ')
  FROM items i
 GROUP BY i.k, i.doc, i.raiser, i.subj
 ORDER BY 1, 2
$f$;

CREATE TEMP TABLE u1a_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
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
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';

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
    PERFORM set_config('request.jwt.claims', '{"sub":"e61d99f2-2b95-4059-86f8-5aef8b5cffb5","role":"authenticated"}', true);
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
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM journal_lines l WHERE l.entry_id = v_je;
    SELECT count(*) INTO v_m FROM journal_lines_masked m WHERE m.entry_id = v_je AND NOT m.amounts_restricted AND m.debit IS NOT NULL;
    EXECUTE 'RESET ROLE';
    IF v_n = 0 OR v_m <> v_n THEN RAISE EXCEPTION 'U1A_PROOF|cfo: API % · masked view with amounts %', v_n, v_m; END IF;

    -- ⑤c 工资期合计 · 工资申请 · 医疗报销 · 请假单:cto 受限,finance(chooer@)看得见
    PERFORM set_config('request.jwt.claims', '{"sub":"e61d99f2-2b95-4059-86f8-5aef8b5cffb5","role":"authenticated"}', true);
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
        PERFORM set_config('request.jwt.claims', '{"sub":"e61d99f2-2b95-4059-86f8-5aef8b5cffb5","role":"authenticated"}', true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        PERFORM gross_total FROM payroll_periods LIMIT 1;
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'U1A_PROOF|cto selected payroll_periods.gross_total from the base table';
    EXCEPTION WHEN insufficient_privilege THEN
        EXECUTE 'RESET ROLE';
    END;
    PERFORM set_config('request.jwt.claims', '{"sub":"476bf8c8-c248-4352-9a75-945bf52ca390","role":"authenticated"}', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM payroll_periods_masked WHERE gross_total IS NOT NULL;
    SELECT count(*) INTO v_m FROM medical_claims_masked WHERE description IS NOT NULL;
    EXECUTE 'RESET ROLE';
    IF v_n <> (SELECT count(*) FROM payroll_periods) OR v_m <> (SELECT count(*) FROM medical_claims WHERE description IS NOT NULL) THEN
        RAISE EXCEPTION 'U1A_PROOF|finance reads pay totals % · medical text %', v_n, v_m;
    END IF;

    -- ⑤d 设备保养建议:仓库(fusheng@)读得到记录、读不到钱;cfo 读得到钱
    PERFORM set_config('request.jwt.claims', '{"sub":"c8116e6c-80db-4a16-be12-24fb6ce6859d","role":"authenticated"}', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*), count(*) FILTER (WHERE work_cost_base IS NOT NULL OR equipment_cost_base IS NOT NULL OR pct_of_equipment_cost IS NOT NULL)
      INTO v_n, v_m FROM equipment_maintenance_advice;
    EXECUTE 'RESET ROLE';
    IF v_m <> 0 THEN RAISE EXCEPTION 'U1A_PROOF|warehouse reads % costed advice row(s)', v_m; END IF;
    RAISE NOTICE 'U1A warehouse: % maintenance advice row(s), no cost on any', v_n;

    -- ⑤e 审计记录的两道判据(线上的工资分录早于变更记录 2026-09-28,所以这里问判据本身;整条记录在 fixture 247 里走):
    --     cto 那一行【不被藏】(trail_row_visible 不接 "amounts:" 策略)、金额【受限】(pay_journal 规则);cfo 两样都看得见
    SELECT l.id INTO v_mc FROM journal_lines l WHERE l.entry_id = v_je LIMIT 1;
    PERFORM set_config('request.jwt.claims', '{"sub":"e61d99f2-2b95-4059-86f8-5aef8b5cffb5","role":"authenticated"}', true);
    v_b := trail_row_visible('journal_lines', jsonb_build_object('id', v_mc), NULL)
           AND NOT change_log_rule_visible('pay_journal:data.view_pay', 'journal_lines', jsonb_build_object('id', v_mc), NULL,
                                           jsonb_build_object('entry_id', v_je));
    IF NOT v_b THEN RAISE EXCEPTION 'U1A_PROOF|cto trail: the payroll line should be visible with its amounts restricted'; END IF;
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    v_b := trail_row_visible('journal_lines', jsonb_build_object('id', v_mc), NULL)
           AND change_log_rule_visible('pay_journal:data.view_pay', 'journal_lines', jsonb_build_object('id', v_mc), NULL,
                                       jsonb_build_object('entry_id', v_je));
    IF NOT v_b THEN RAISE EXCEPTION 'U1A_PROOF|cfo trail: the payroll line and its amounts should be visible'; END IF;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑤f my_period_labels():每一个绑着员工档案的账号都调得了,只拿到自己的期间;工资单那几行带币种
    v_m := 0;
    FOR v_t, v_mc IN SELECT e.user_id::text, e.id FROM employees e WHERE e.user_id IS NOT NULL AND e.deleted_at IS NULL LOOP
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_t), true);
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
