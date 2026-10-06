-- db/migrations/2026-10-05-u1b-workflow-fixes.sql
-- U1-B —— 工作流上的几扇门与剩下的几处泄漏(UNBLOCK-1 的第二刀,v1.4.36;发布那一行在 docs/handbacks/U1-B.md 的抬头)。
-- 由 db/scripts/build_u1b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-05:Step 0 的 Q14–Q25 全部照建议裁定;U1-A close-out 另加三件)
--   ① 停机(Q15):一段记错了的停机可以【更正】(起止与原因,表上的 UPDATE 策略,变更记录留着旧值)、可以【作废】(带理由,
--      void_equipment_downtime);【永远不硬删】(guard_downtime_write 对任何人都拒 DELETE)。作废的那一段不挡重叠、不算"开着的
--      那一段"、交接单不能再引用它。
--   ② 采购单关闭 / 重开的理由(Q25):进它们自己的五列(closed_by · close_reason · reopened_at · reopened_by · reopen_reason),
--      notes 不再被改写;历史各记一行 closed / reopened,理由在 amend_reason。线上两张单 notes 里的旧后缀原样留着。
--   ③ 深度放电判断(Q20):set_po_line_deep_discharge —— 持 module.purchasing.edit、单子没被取消就能写(那个控件从 APR-10 起
--      一次都没存进去过)。
--   ④ 报销单的另一位决定人(Step 0 §3 3.6):审批开着、提单人与主角之外没人批得动时,submit_expense_claim 按名拒
--      EXPENSE_CLAIM_NO_OTHER_DECIDER|单号(assert_other_decider_for_subject —— 带主角的那一版;assert_other_decider 改成调它)。
--   ⑤ 九支请假函数的 NULL 陷阱(U1A-SELF-GATE-NULL-TRAP):"持码或本人"的门对没有员工档案的账号关上(COALESCE)。
--   ⑥ 工资分录的冲销申请(U1A-PAYROLL-REVERSAL-REQUEST-SHOWS-AMOUNT):journal_requests.amount_base 从列授权里拿掉,只经
--      journal_requests_masked 读;审批留痕的金额、变更记录(jr_amount)与提交 / 决定两支函数的返回值都走同一支
--      journal_request_amount_visible(持 data.view_pay,或冲销的不是工资分录)。
--   ⑦ 医疗报销费用单(U1A-MEDICAL-EXPENSE-AMOUNT-ON-FINANCE-SIDE,Tim 的裁定:金额给财务;健康的字跟 data.view_health 走):
--      量下来费用单自己的列与分录里没有健康的字;从它那一页的审计记录出去的是报销单的【批准 / 驳回理由】—— decision_notes
--      与审批留痕上的 note。两样都收到 data.view_health(或本人);自批报表也问这两道判据;搜索不再按那段理由找。
--   ⑧ 月结(Step 0 §3 5.1):挡住关账的加工单抽成 processing_runs_blocking_close,close_period 与月结清单读同一支。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关、名册与授权;不写、不改任何一张单据。
--   唯一的数据写入:document_types 一行的搜索列(medical_claim 不再按 decision_notes 匹配)。
--
-- 【破窗】从这一支提交到部署之间,旧应用读新库:
--   · /finance/journal 选 journal_requests.amount_base → 42501(页面报错)直到部署(线上 0 张申请,但查询照样被拒)。
--   · /hr/claims/[id] 若直读 medical_claims.decision_notes → 42501;读 medical_claims_masked 的照常(那一列受限时是 NULL)。
--   · 旧的深度放电控件、旧的停机面板照旧(前者本来就存不进去;后者不认识作废,也不需要)。
--   · 旧的关单 / 重开按钮调的是同一支函数:理由从此进新列,旧页面只是看不见它(notes 里不再有后缀)。
--   · 窗口在部署那一刻闭合;部署是 Tim 在 Vercel 上看的。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行不多一行不少;在途单据一张不少、一张不多;change_log 只多
--   document_types 那一行;七个账号一个都没被停;遮蔽名单与目录对得上(零缺口,104 条);三列真的收回了;以真账号的身份把
--   新判据读一遍;每一张在途单据仍有一个不是它当事人的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'U1B_PRE|approvals are expected ON';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 101 THEN
        RAISE EXCEPTION 'U1B_PRE|expected 101 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                  AND ((table_name = 'equipment_downtime' AND column_name = 'voided_at')
                    OR (table_name = 'purchase_orders' AND column_name = 'close_reason'))) THEN
        RAISE EXCEPTION 'U1B_PRE|the new columns already exist';
    END IF;
    IF to_regclass('public.journal_requests_masked') IS NOT NULL THEN
        RAISE EXCEPTION 'U1B_PRE|journal_requests_masked already exists';
    END IF;
    IF NOT has_column_privilege('authenticated', 'public.journal_requests', 'amount_base', 'SELECT')
       OR NOT has_column_privilege('authenticated', 'public.approval_log', 'note', 'SELECT')
       OR NOT has_column_privilege('authenticated', 'public.medical_claims', 'decision_notes', 'SELECT') THEN
        RAISE EXCEPTION 'U1B_PRE|one of the three columns is already revoked';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'purchase_order_history_change_type_check') THEN
        RAISE EXCEPTION 'U1B_PRE|purchase_order_history_change_type_check is not there to replace';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE u1b_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE u1b_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE u1b_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE u1b_po_before ON COMMIT DROP AS
SELECT id, md5(to_jsonb(p)::text) AS digest FROM purchase_orders p;
CREATE TEMP TABLE u1b_dt_before ON COMMIT DROP AS
SELECT id, md5(to_jsonb(dt)::text) AS digest FROM equipment_downtime dt;

-- ── 1 · 新函数(镜像原样)── 视图、触发器与改过的函数要先有它们 ─────────────

-- db/functions/journal_request_amount_visible.sql
-- U1-B(2026-10-05,U1A-PAYROLL-REVERSAL-REQUEST-SHOWS-AMOUNT):一张手工凭证申请的【金额】(journal_requests.amount_base)对当前读者看不看得见。
--   发薪、公积金、扣款那几张分录的冲销走手工凭证的冲销申请,申请抄着被冲销那张分录的合计 —— 一期一个人时就是一个人的实发工资。
--   U1-A 把工资分录本身收到 data.view_pay(journal_lines_masked);本函数让【申请】跟同一条规矩走(Tim:照 data.view_pay 那条规矩遮)。
-- 【判据】持 data.view_pay,或这张申请冲销的不是一张工资分录(target_entry_id → journal_entries.source_type 不是 'payroll')。
--   与 journal_lines_masked 的 CASE 逐字同一个谓词;一张新凭证的申请(kind = 'entry',没有被冲销的分录)不是工资,照常给。
--   写成 has_permission OR EXISTS(…不是工资…),不写成 NOT EXISTS(…是工资…):读不到那一行的人(或那一行不存在)落在
--   【看不见】那一边 —— 关着失败。
-- 【四个读者,一份判据】journal_requests_masked 的 CASE · approval_log_amount_visible 的 journal_request 那一支(审批留痕与
--   change_log_rule_visible 的 apr_amount 跟着它)· change_log_rule_visible 的 jr_amount(申请自己的变更记录)·
--   提交与决定两支函数的返回值。
-- 【不是 SECURITY DEFINER】它读 journal_requests(id · target_entry_id,列授权里有)与 journal_entries(source_type),两张都按
--   module.finance.view 给 —— 与申请自己的读门同一个码,读得到申请的人就读得到这两列。
CREATE OR REPLACE FUNCTION public.journal_request_amount_visible(p_request_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT has_permission('data.view_pay'::text)
        OR EXISTS (SELECT 1
                     FROM journal_requests r
                     LEFT JOIN journal_entries e ON e.id = r.target_entry_id
                    WHERE r.id = p_request_id
                      AND e.source_type IS DISTINCT FROM 'payroll');
$function$;

-- db/functions/approval_log_note_visible.sql
-- U1-B(2026-10-05,U1A-MEDICAL-EXPENSE-AMOUNT-ON-FINANCE-SIDE 的裁定,Tim):approval_log 一行上的【说明】(note)对当前读者看不看得见。
--   Tim 的规矩:医疗报销生成的那张费用单,金额给财务(付它是正当的需要);任何【健康的字】—— 事由、诊断、理由 —— 跟 data.view_health 走。
--   一张医疗报销的批准 / 驳回说明是 HR 写下的那一段理由(为什么报、为什么不报),它与 medical_claims.decision_notes 是同一段字的两份;
--   那一份已经收到 data.view_health(或本人),这一份不跟着收,同一段字就从审批留痕那扇门出去了。
-- 【判据,一支对一个单据种类】medical_claim → data.view_health,或那一张报销单就是读者本人的(与 medical_claims_masked 逐字同一个);
--   其余种类 → true(本刀不动它们;请假单的说明是同一个形状,登记为 U1B-LEAVE-DECISION-NOTE-HEALTH-TEXT)。
-- 【三个读者,一份判据】approval_log_masked 的 CASE · change_log_rule_visible 的 apr_note · self_approved_decisions。
-- 【不是 SECURITY DEFINER】与 approval_log_amount_visible 同一条理由。
CREATE OR REPLACE FUNCTION public.approval_log_note_visible(p_subject_type text, p_subject_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_subject_type
        WHEN 'medical_claim' THEN has_permission('data.view_health'::text)
                                  OR EXISTS (SELECT 1 FROM medical_claims mc
                                              WHERE mc.id = p_subject_id AND mc.employee_id = current_user_employee())
        ELSE true
    END;
$function$;

-- db/functions/assert_other_decider_for_subject.sql
-- U1-B(2026-10-05,ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE 的报销单那一半):assert_other_decider 带上【主角】的那一版。
--
-- 【为什么要有主角】报销单的四眼不只看提单人,也看【这张单报的是谁】(decide_expense_claim 的
--   forbid_self_approval(created_by, employee_id, …))—— 一张替 tim@ 报的单,tim@ 批不了,哪怕提单的是别人。
--   assert_other_decider 一直传 NULL 当主角(它的十五个调用方都是没有主角的申请),所以问不出这一句。
-- 【一份判据】assert_other_decider 从此只是本函数的 p_subject_employee = NULL 的那一种 —— 两份判据必然漂开。
-- 【判据】审批开着时,approval_deciders(本链、本级、提单人 = auth.uid()、主角 = p_subject_employee)一个人都没有 →
--   RAISE p_refusal。审批关着时不拒。self_approval_exception 的那一条(主角本人持二级、可以批自己的报销)照样算进去,
--   因为 approval_deciders 自己就问它。
-- 【EXECUTE 从 authenticated 收回】与 assert_other_decider 同一条(见 db/views/zzz_function_grants.sql)。
--
-- NOTE: introduced by db/migrations/2026-10-05-u1b-workflow-fixes.sql.

CREATE OR REPLACE FUNCTION public.assert_other_decider_for_subject(p_subject_type text, p_action_function text, p_level smallint, p_subject_employee uuid, p_refusal text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_l1 text;
    v_l2 text;
BEGIN
    IF NOT approvals_enabled() THEN
        RETURN;
    END IF;
    SELECT approval_level1_role_code, approval_level2_role_code
      INTO v_l1, v_l2 FROM finance_settings LIMIT 1;
    IF NOT EXISTS (SELECT 1 FROM approval_deciders(p_subject_type, p_action_function, p_level,
                                                   auth.uid(), p_subject_employee, v_l1, v_l2)) THEN
        RAISE EXCEPTION '%', p_refusal;
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.assert_other_decider_for_subject(text, text, smallint, uuid, text) IS
'U1-B:assert_other_decider 带主角的那一版 —— 审批开着、approval_deciders(本链、本级、提单人 = auth.uid()、主角 = p_subject_employee)一个人都没有时 RAISE 调用方给的那一句(报销单 EXPENSE_CLAIM_NO_OTHER_DECIDER|单号)。assert_other_decider 是它主角为 NULL 的那一种。EXECUTE 已从 authenticated 收回。';

-- db/functions/processing_runs_blocking_close.sql
-- U1-B(2026-10-05,UNBLOCK-1 Step 0 §3 5.1):挡住某一个月末关账的加工单 —— 已提交、从未分摊成本、日期不晚于那个月末。
--
-- 【为什么抽出来】close_period 按这一句拒(PROCESSING_COSTS_UNALLOCATED),而月结清单此前自己数另一样东西
--   (processing_run_allocation_status 的"过期,或未分摊且有过成本改动")—— 一张从没有成本条目的已提交单,清单说"做完了",
--   关账却拒;而一张过期的单清单说"挡着",关账却放行。两份判据各说各的。现在【一份】:close_period 与月结清单调同一支。
-- 【SECURITY DEFINER + 调用者检查】月结清单的读者持 module.finance.view;processing_runs 的读策略是加工那一侧的码 ——
--   不持加工码的财务读者经基表读会【静默地少掉】那几张单(xmodule 那一族),清单于是又说"做完了"。
--   属主身份数,门是 module.finance.view(与 /finance/month-end 同一扇)。
--
-- NOTE: introduced by db/migrations/2026-10-05-u1b-workflow-fixes.sql.

CREATE OR REPLACE FUNCTION public.processing_runs_blocking_close(p_period_end date)
 RETURNS TABLE(run_count integer, run_codes text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'PERIOD_END_REQUIRED';
    END IF;
    RETURN QUERY
    SELECT count(*)::integer, string_agg(r.code, ', ' ORDER BY r.process_date, r.code)
      FROM processing_runs r
     WHERE r.deleted_at IS NULL
       AND r.status = 'committed'
       AND r.allocated_at IS NULL
       AND r.process_date <= p_period_end;
END;
$function$;

COMMENT ON FUNCTION public.processing_runs_blocking_close(date) IS
'U1-B:挡住 p_period_end 关账的加工单(已提交、从未分摊、日期不晚于月末)的张数与编号。close_period 与月结清单读同一支 —— 一份判据。属主身份数(财务读者不持加工码时基表会静默少行),门 module.finance.view。';

-- db/functions/guard_downtime_write.sql
-- U1-B(2026-10-05,UNBLOCK-1 Q15):一段停机可以【更正】、可以【作废】,永远不【硬删】。
--
-- 【三条,各自一个理由】
--   ① DELETE 一律拒(DOWNTIME_NEVER_DELETED)—— 包括属主与迁移。交接单(shift_handover_equipment_refs,NOT NULL)与
--      保养记录指着它;一段记错了的停机的去处是作废,不是消失(消失之后,"那天为什么停了"连一个"没有发生过"都说不出)。
--   ② 作废过的行冻住(DOWNTIME_VOIDED|<起始>)—— 作废之后再更正,读的人分不清哪一个版本被作废了。
--   ③ 作废的三列只经 void_equipment_downtime() 写(DOWNTIME_VOID_THROUGH_FUNCTION_ONLY)—— 由 row_security_active 判:
--      带 RLS 的调用者(每一个经 PostgREST 来的人)直连改 voided_* 被拒;属主 / SECURITY DEFINER 的路放行。
--      更正(起止与原因)照旧走表上的 UPDATE 策略(module.processing.edit),变更记录留着旧值 —— Tim 的 Q15。
-- 【两个挂法】UPDATE 挂行级(③ 要比 OLD 与 NEW);DELETE 挂【语句级】—— 这张表没有 DELETE 策略,一个 authenticated 的 DELETE
--   在 RLS 那里就匹配零行,行级触发器根本不会触发,于是它"成功地"什么都没删(ALERT-1 那一族:零行不许报告成功)。
--   语句级零行也照样触发,所以每一句 DELETE —— 不论谁、不论命中几行 —— 都按名拒。fixture 248 DT4 实测过这一格。
--
-- NOTE: introduced by db/migrations/2026-10-05-u1b-workflow-fixes.sql.

CREATE OR REPLACE FUNCTION public.guard_downtime_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'DOWNTIME_NEVER_DELETED';
    END IF;
    IF OLD.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'DOWNTIME_VOIDED|%', to_char(OLD.started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    END IF;
    IF row_security_active(TG_RELID)
       AND (NEW.voided_at IS DISTINCT FROM OLD.voided_at
            OR NEW.voided_by IS DISTINCT FROM OLD.voided_by
            OR NEW.void_reason IS DISTINCT FROM OLD.void_reason) THEN
        RAISE EXCEPTION 'DOWNTIME_VOID_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 2 · 表(与 db/tables 下改过的几处逐字同义)──────────────────────────────

-- equipment_downtime(Q15):作废三列 + 形状约束;开着的那一段不算作废的;写的闸
ALTER TABLE public.equipment_downtime
    ADD COLUMN voided_at   timestamptz,
    ADD COLUMN voided_by   uuid,
    ADD COLUMN void_reason text,
    ADD CONSTRAINT equipment_downtime_void_shape
        CHECK ((voided_at IS NULL AND voided_by IS NULL AND void_reason IS NULL)
            OR (voided_at IS NOT NULL AND void_reason IS NOT NULL AND btrim(void_reason) <> ''));
DROP INDEX public.uq_equipment_downtime_open;
CREATE UNIQUE INDEX uq_equipment_downtime_open
    ON public.equipment_downtime (equipment_id)
    WHERE ended_at IS NULL AND voided_at IS NULL;
CREATE TRIGGER trg_equipment_downtime_write
    BEFORE UPDATE ON public.equipment_downtime
    FOR EACH ROW EXECUTE FUNCTION public.guard_downtime_write();
CREATE TRIGGER trg_equipment_downtime_no_delete
    BEFORE DELETE ON public.equipment_downtime
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_downtime_write();

-- purchase_orders(Q25):关闭 / 重开的人与理由。遮蔽表 —— 加列 · 列授权 · _masked 视图在同一支迁移里(WO-1a 那一课)
ALTER TABLE public.purchase_orders
    ADD COLUMN closed_by     uuid,
    ADD COLUMN close_reason  text,
    ADD COLUMN reopened_at   timestamptz,
    ADD COLUMN reopened_by   uuid,
    ADD COLUMN reopen_reason text;
GRANT SELECT (closed_by, close_reason, reopened_at, reopened_by, reopen_reason) ON public.purchase_orders TO authenticated;

-- purchase_order_history(Q25):两种新的 change_type
ALTER TABLE public.purchase_order_history DROP CONSTRAINT purchase_order_history_change_type_check;
ALTER TABLE public.purchase_order_history ADD CONSTRAINT purchase_order_history_change_type_check
    CHECK (change_type IN ('header_update','line_update','line_add','line_remove','cancelled',
                           'payment_term_add','payment_term_update','payment_term_remove',
                           'closed','reopened'));

-- journal_requests(U1A-PAYROLL-REVERSAL-REQUEST-SHOWS-AMOUNT):amount_base 从列授权里拿掉
REVOKE SELECT ON public.journal_requests FROM authenticated;
GRANT SELECT (id, kind, status, label, entry_date, memo, lines, target_entry_id, credits_bank, decided_at, decided_by,
              decision_notes, result_journal_entry_id, withdrawn_at, withdrawn_by, withdraw_reason, created_at, created_by)
    ON public.journal_requests TO authenticated;

-- approval_log 与 medical_claims(Tim 对医疗报销费用单的裁定):说明 / 批准驳回理由从列授权里拿掉
REVOKE SELECT ON public.approval_log FROM authenticated, anon;
GRANT SELECT (id, seq, subject_type, subject_id, subject_code, decision, level,
              actor_user_id, decided_at, currency, fx_rate,
              is_reconstructed, reconstruction_note, created_at,
              self_decided)
    ON public.approval_log TO authenticated;
REVOKE SELECT ON public.medical_claims FROM authenticated, anon;
GRANT SELECT (id, code, employee_id, claim_date, claim_year, receipt_ref, status, decided_at, decided_by,
              expense_id, deleted_at, created_at, created_by, updated_at, updated_by, withdrawn_at)
    ON public.medical_claims TO authenticated;

-- document_types:搜索列不能是被遮的列(fixture 100/8 · 199F 的判据)—— 与 db/tables/document_types.sql 的种子行逐字相同
UPDATE public.document_types SET match_columns = ARRAY['receipt_ref']::text[] WHERE key = 'medical_claim';

-- ── 3 · 改过的函数(镜像原样)──────────────────────────────────────────────

-- db/functions/approval_log_amount_visible.sql
-- U1-A(UNBLOCK-1 Q8 · Q10,2026-10-05):approval_log 一行上的【金额】(amount_ccy · amount_base)对当前读者看不看得见。
--   record_approval_decision 把单据的金额抄进留痕:工资申请那一行是这一期的合计(一期一个人时就是一个人的工资,Q9 · Q10),
--   医疗报销那一行是报销的金额(Q8)。单据那一侧这两样已经被遮(payroll_requests_masked · medical_claims_masked),
--   留痕这一侧不跟着遮,同一个数就从另一扇门出去了。
-- 【判据,一支对一个单据种类,与那张单据自己的遮蔽逐字同一个】
--   payroll_request → data.view_pay(payroll_requests_masked 的 gross_total / amount_base)
--   medical_claim   → data.view_health,或那一张报销单就是读者本人的(medical_claims_masked 的 amount_sgd)
--   journal_request → journal_request_amount_visible(U1-B:工资分录的冲销申请要 data.view_pay;journal_requests_masked 的 amount_base)
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
        -- U1-B:一张工资分录的冲销申请,金额就是那张分录的合计 —— 与申请自己的遮蔽同一支判据。
        WHEN 'journal_request' THEN journal_request_amount_visible(p_subject_id)
        ELSE true
    END;
$function$;

-- db/functions/change_log_rule_visible.sql
-- HISTORY-1:一条遮蔽规则(change_log_mask_rules)对【当前读者】、就【这一行记录】成不成立。
-- 与 _masked 视图里那句 CASE WHEN 逐条同一个判据;认不出的规则按【看不见】答(关着失败)。
-- ★ U1-A(UNBLOCK-1,2026-10-05)两种新写法,各自与它那张 _masked 视图里的 CASE 同一个判据:
--   pay_journal:<码>   持码,或这一行所在分录(entry_id → journal_entries.source_type)不是 'payroll'(journal_lines_masked)。
--                       分录找不到 → 看不见(关着失败;分录不可删,所以这只在影像里根本没有 entry_id 时发生)。
--   apr_amount         approval_log_amount_visible(subject_type, subject_id) —— 视图与这里调同一支函数(approval_log_masked)。
-- ★ U1-B(2026-10-05)两种新写法,同一个道理:
--   apr_note           approval_log_note_visible(subject_type, subject_id)(approval_log_masked 的 note;医疗报销的说明是健康的字)。
--   jr_amount          journal_request_amount_visible(这一行的 id)(journal_requests_masked;工资分录的冲销申请要 data.view_pay)。
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
    ELSIF p_rule = 'apr_note' THEN
        RETURN COALESCE(approval_log_note_visible(change_log_field(p_table, p_key, p_old, p_new, 'subject_type'),
                                                  change_log_field(p_table, p_key, p_old, p_new, 'subject_id')::uuid), false);
    ELSIF p_rule = 'jr_amount' THEN
        RETURN COALESCE(journal_request_amount_visible(change_log_field(p_table, p_key, p_old, p_new, 'id')::uuid), false);
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
--   apr_note                     approval_log_note_visible(subject_type, subject_id)(approval_log_masked;U1-B)
--   jr_amount                    journal_request_amount_visible(id)(journal_requests_masked;U1-B)
-- ★ U1-B(2026-10-05)加了 3 行(101 → 104):工资分录冲销申请的金额 · 医疗报销的批准 / 驳回理由(在报销单上与在审批留痕上)。
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
        ('approval_log', 'note', 'apr_note'),
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
        ('journal_requests', 'amount_base', 'jr_amount'),
        ('leave_requests', 'reason', 'code_or_self:data.view_health:employee_id'),
        ('leave_requests', 'certificate_ref', 'code_or_self:data.view_health:employee_id'),
        ('leave_requests', 'exception_reason', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'amount_sgd', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'description', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'decision_notes', 'code_or_self:data.view_health:employee_id'),
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

-- db/functions/assert_other_decider.sql
-- ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q12):**提单人之外没人批得动,提交就拒**。
--
-- 【Step 0 量出来的】admin@ 与 tim@ 是同一个人(account_person 两个都是 4737faa9…),二级今天只有
-- tim@ 一个真持有人,而 admin 角色持每一个码(Tim 的常设裁定)—— 于是 admin@ 能提一张工资申请
-- (module.hr.edit)或一张付款 / 转账 / 预扣税申请(module.finance.edit),提单人那条腿按人认,
-- tim@ 批不了,又没有第二个人:它挂在那里,还经 blocks_disable 挡住关审批。收货定价申请在 4b 里
-- 按名拒了同一个形状(RECEIPT_PRICE_NO_OTHER_DECIDER);本函数把那几行抽成一份,给工资申请与六支
-- 付款申请的提交共用。
--
-- 【判据】审批开着时,approval_deciders(本链、本级、提单人 = auth.uid()、无主角)一个人都没有 →
-- RAISE p_refusal(调用方给出按名拒的那一句)。审批关着时不拒:申请生下来就是 approved。
-- 【为什么 RAISE 而不是返回布尔】它是一句断言,不是一个读者 —— 没有返回值的函数,
-- "不拒"与"成功"是同一个字节(void-assertion 那一条)。
-- 【EXECUTE 从 authenticated 收回】调用它的都是 SECURITY DEFINER 的提交函数;approval_deciders
-- 本身也收回了。
--
-- U1-B(2026-10-05):函数体改成调 assert_other_decider_for_subject(…, NULL, …)—— 判据只留一份。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql.

CREATE OR REPLACE FUNCTION public.assert_other_decider(p_subject_type text, p_action_function text, p_level smallint, p_refusal text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- U1-B:判据只写一份 —— 本函数是 assert_other_decider_for_subject 主角为 NULL 的那一种。
    PERFORM assert_other_decider_for_subject(p_subject_type, p_action_function, p_level, NULL, p_refusal);
END;
$function$;

COMMENT ON FUNCTION public.assert_other_decider(text, text, smallint, text) IS
'ROLE-1 Batch 3a:审批开着、approval_deciders(本链、本级、提单人 = auth.uid())一个人都没有时,RAISE 调用方给的那一句(工资申请 PAYROLL_NO_OTHER_DECIDER|工资期;付款申请一族 PAYMENT_REQUEST_NO_OTHER_DECIDER)。审批关着时不拒。EXECUTE 已从 authenticated 收回。';

CREATE OR REPLACE FUNCTION public.submit_expense_claim(p_employee_id uuid, p_spend_date date, p_amount numeric, p_currency text, p_description text, p_no_receipt_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_emp employees%ROWTYPE; v_code text; v_id uuid; v_base numeric;
BEGIN
    -- 【自助:本人,或者持财务读权限的人代录】与 submit_medical_claim 同一条谓词
    -- ★ EMP-SELF-1(Q9 · Q2):COALESCE(…, false)。没有员工档案的账号 current_user_employee() 是 NULL,
    --   于是 NOT (false OR NULL) = NULL,IF 不触发 —— 这一道门对它【从来没有关上过】。
    IF NOT COALESCE(has_permission('module.finance.view') OR p_employee_id = current_user_employee(), false) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', COALESCE(p_employee_id::text, '?');
    END IF;
    IF p_spend_date IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_SPEND_DATE_REQUIRED';
    END IF;
    IF p_spend_date > CURRENT_DATE THEN
        -- 一笔"将来才会花的钱"不是报销,那是备用金 —— 而备用金被否决了(§0)
        RAISE EXCEPTION 'EXPENSE_CLAIM_SPEND_DATE_FUTURE|%|%', p_spend_date::text, CURRENT_DATE::text;
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_AMOUNT_INVALID|%', COALESCE(p_amount::text, '?');
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies WHERE code = p_currency) THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_CURRENCY_UNKNOWN|%', COALESCE(p_currency, '?');
    END IF;
    IF p_description IS NULL OR btrim(p_description) = '' THEN
        -- 「买了什么」是审批人唯一能据以判断的东西
        RAISE EXCEPTION 'EXPENSE_CLAIM_DESCRIPTION_REQUIRED';
    END IF;

    v_code := next_expense_claim_code(p_spend_date);
    INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency,
                                description, no_receipt_reason, created_by)
    VALUES (v_code, p_employee_id, p_spend_date, p_amount, p_currency,
            btrim(p_description),
            NULLIF(btrim(COALESCE(p_no_receipt_reason, '')), ''), auth.uid())
    RETURNING id INTO v_id;

    -- ★ U1-B(ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE 的报销单那一半,与采购单 APR-10 同一个形状):
    --   审批开着时,按这张单会落到的那一级问一句"提单人与主角之外,有没有人批得动";没有 → 按名拒,整张单不落库
    --   (单号随回滚放回去)。主角要传 —— 报销单的四眼也看【报的是谁】(decide_expense_claim 的 forbid_self_approval)。
    --   【分档读同一份】expense_claim_amount_base 是 decide_expense_claim 分档用的那一支;折不出本位币(没有牌价)时
    --   不在这里另造一句拒绝 —— 那张单在决定时会被 fx_rate_for 按名拒(那句话归它),而在牌价补上之前谁都批不了它。
    IF approvals_enabled() THEN
        SELECT b.amount_base INTO v_base FROM expense_claim_amount_base(v_id) b;
        IF v_base IS NOT NULL THEN
            PERFORM assert_other_decider_for_subject('expense_claim', 'decide_expense_claim',
                                                     approval_level_for(v_base), p_employee_id,
                                                     'EXPENSE_CLAIM_NO_OTHER_DECIDER|' || v_code);
        END IF;
    END IF;

    RETURN jsonb_build_object('claim_id', v_id, 'code', v_code, 'status', 'submitted');
END;
$function$

;

-- db/functions/accrued_annual_leave_detail.sql
-- 按月累积的明细:逐月走,每个月各取各的【年额】(类别可能变、费率可能改)。
-- 累积 = Σ区间(年额 × 区间月数 / 12);实现上先把每月的年额加起来,【最后只除一次 12】——
-- 线性求和结果相同,但中间不产生 25/12 那种除不尽的小数(那正是 24.9996 的来处)。
-- 入职当月算整月;某个月要满了才计入;离职的人算到最后在职日为止。
-- 向下取到 0.5 天【只作用于总数】,不逐月作用。
--
-- NOTE: introduced by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       annual-rate form by db/migrations/2026-08-07-hr2c-fu1-annual-rate-and-immutable-rates.sql.

CREATE OR REPLACE FUNCTION public.accrued_annual_leave_detail(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp      record;
    v_year     integer := EXTRACT(YEAR FROM p_as_of)::integer;
    v_asof     date;
    v_first    date;
    v_last     date;
    v_m        date;
    v_cat      text;
    v_rate     jsonb;
    v_dpy_sum  numeric := 0;
    v_raw      numeric := 0;
    v_months   jsonb := '[]'::jsonb;
    v_sys      date;        -- HR-7:完整记录起始日(finance_settings.system_start_date)
    v_sys_used boolean;
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    -- U1-B(U1A-SELF-GATE-NULL-TRAP):没有员工档案的账号,current_user_employee() 是 NULL,
    --   NOT (false OR NULL) 是 NULL,IF NULL 不进分支 —— 门曾经是开的。COALESCE 把「未知」读成「不是本人」。
    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    SELECT id, code, hire_date, work_category, employment_status, separation_date
    INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    -- 【离职冻结】最后在职日之后不再累积
    v_asof := p_as_of;
    IF v_emp.separation_date IS NOT NULL AND v_emp.separation_date < v_asof THEN
        v_asof := v_emp.separation_date;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- HR-7:【三个日期一次 GREATEST,不做叠加扣减】
    -- 累积的起点是三件事的【交集】:这个人什么时候入职、这个假期年从哪天开始、
    -- 本库从哪天起持有完整记录。取三者之中最晚的那一个 —— 一次比较,得一个日期。
    --
    -- 【为什么必须是 GREATEST 而不是逐条扣减】HR-6 的医疗额度就是这么栽的:
    -- 先按入职月折一次、再按起始月折一次,两次都"对",合起来把 3 个月折成了
    -- 1 个月、300 折成 100。这里的实现是【日期取最大】而不是【月数打折】,
    -- 结构上就不会叠加 —— 但那正是要写下来的理由:换成"先算月数再逐项扣"的
    -- 写法,数字会安静地变小,而每一步看起来都成立。
    --
    -- 【起始日所在的那个月算进去】与 medical_claim_balance 同口径
    -- (它取 EXTRACT(MONTH FROM v_start),即含起始月)。
    --
    -- 【起始日未设置时不拒绝】HR-5 的结转与 HR-6 的医疗额度都抛
    -- SYSTEM_START_NOT_SET —— 那两个是【动作】(结转、批报销),拒了就停在那里。
    -- 本函数是【余额】:它坐在 my_profile / employees_masked 上,是员工点开
    -- /me 就会看到的那个数。因为财务的一个设置没填而告诉全体员工"你的假期余额
    -- 不可用",是把一个后台配置问题变成所有人的故障。
    -- 所以这里【退回两日期口径】并在返回值里说明,由 hr_alerts 的
    -- system_start_not_set 去催那个设置(同 holiday_calendar_missing 的处置:
    -- 缺配置是告警,不是让功能消失)。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT system_start_date INTO v_sys FROM finance_settings LIMIT 1;
    v_sys_used := v_sys IS NOT NULL;

    v_first := GREATEST(date_trunc('month', v_emp.hire_date)::date, make_date(v_year, 1, 1));
    IF v_sys_used THEN
        v_first := GREATEST(v_first, date_trunc('month', v_sys)::date);
    END IF;
    v_last  := LEAST((date_trunc('month', v_asof + 1) - interval '1 month')::date,
                     make_date(v_year, 12, 1));

    IF v_asof < make_date(v_year, 1, 1) OR v_last < v_first THEN
        RETURN jsonb_build_object(
            'employee_id', p_employee_id, 'employee_code', v_emp.code,
            'leave_year', v_year, 'as_of', p_as_of, 'effective_as_of', v_asof,
            'months', '[]'::jsonb, 'months_accrued', 0, 'raw_days', 0, 'accrued_days', 0,
            'system_start_date', v_sys, 'system_start_applied', v_sys_used,
            'frozen_at_separation', v_emp.separation_date IS NOT NULL AND v_emp.separation_date < p_as_of);
    END IF;

    v_m := v_first;
    WHILE v_m <= v_last LOOP
        v_cat  := employee_work_category_at(p_employee_id, v_m);
        v_rate := leave_accrual_rate(p_employee_id, v_cat, v_m);
        -- 【只累加年额,不在这里除】Σ区间(年额 × 月数/12) 与 (Σ每月年额)/12 是同一个数,
        -- 但后者中间不产生任何除不尽的小数 —— 25/12 那种数字永远不会出现在中间结果里。
        v_dpy_sum := v_dpy_sum + (v_rate->>'days_per_year')::numeric;
        v_months := v_months || jsonb_build_object(
            'month', to_char(v_m, 'YYYY-MM'),
            'work_category', v_cat,
            'days_per_year', (v_rate->>'days_per_year')::numeric,
            'rate_source', v_rate->>'source',
            'rate_effective_from', v_rate->>'effective_from');
        v_m := (v_m + interval '1 month')::date;
    END LOOP;

    v_raw := v_dpy_sum / 12;

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code,
        'leave_year', v_year, 'as_of', p_as_of, 'effective_as_of', v_asof,
        'first_month', to_char(v_first, 'YYYY-MM'), 'last_complete_month', to_char(v_last, 'YYYY-MM'),
        -- 起点由哪三个日期定的,以及第三个到底有没有生效 —— 看得见才查得动
        'system_start_date', v_sys, 'system_start_applied', v_sys_used,
        'months', v_months,
        'months_accrued', jsonb_array_length(v_months),
        'sum_of_annual_rates', v_dpy_sum,
        'raw_days', trim_scale(v_raw),
        -- 【向下取到 0.5 天只作用于总数】,不再逐月作用 —— 那正是 24.9996 的来处。
        'accrued_days', trim_scale(floor(v_raw * 2) / 2),
        'frozen_at_separation', v_emp.separation_date IS NOT NULL AND v_emp.separation_date < p_as_of);
END;
$function$;

-- db/functions/accrued_annual_leave.sql
-- 当年度已累积、可请的天数(向下取到 0.5 天)。明细见 accrued_annual_leave_detail。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.accrued_annual_leave(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    -- U1-B(U1A-SELF-GATE-NULL-TRAP):没有员工档案的账号,current_user_employee() 是 NULL,
    --   NOT (false OR NULL) 是 NULL,IF NULL 不进分支 —— 门曾经是开的。COALESCE 把「未知」读成「不是本人」。
    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    RETURN (SELECT (accrued_annual_leave_detail(p_employee_id, p_as_of)->>'accrued_days')::numeric);
END;
$function$
;

-- db/functions/annual_leave_available_from.sql
-- 最早哪一天累积够 p_days 天可请。按月末逐个往前推(累积在月末落账);
-- 本假期年度内攒不够则返回 NULL —— 界面据此说另一句话,而不是编一个日期出来。
--
-- 【为什么在数据库里】"什么时候够"要靠累积规则算,而累积规则只有一份实现。
-- 放到 TypeScript 里就是第二份 —— GrantRunner 那份重复的折算公式刚被删掉,不该再种一棵。
-- 错误码本身不变(INSUFFICIENT_ACCRUED_LEAVE|accrued|requested),界面拿到错误后再问一次这里。
--
-- ★ LEAVE-BAL-1(2026-09-28):比的是 'bookable'(再扣掉还在等批的),不是 'available' ——
--   它回答的是"哪天起【提交】得动",而提交扣待批(Tim Q10)。比 available 会报一个
--   【提交时照样被拒】的日期。
--
-- NOTE: introduced by db/migrations/2026-08-08-hr2c-fu2-when-enough-accrues.sql;
--       LEAVE-BAL-1 by db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql.

CREATE OR REPLACE FUNCTION public.annual_leave_available_from(p_employee_id uuid, p_days numeric, p_from date DEFAULT CURRENT_DATE)
 RETURNS date
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_from)::integer;
    v_m    date := date_trunc('month', p_from)::date;
    v_end  date;
BEGIN
    -- 【本人或 HR】—— 与 leave_balance 同一道口径。界面在 INSUFFICIENT_ACCRUED_LEAVE
    -- 之后调它,那时调用者要么是本人、要么持 module.hr.edit,两种都过得去。
    -- U1-B(U1A-SELF-GATE-NULL-TRAP):没有员工档案的账号,current_user_employee() 是 NULL,
    --   NOT (false OR NULL) 是 NULL,IF NULL 不进分支 —— 门曾经是开的。COALESCE 把「未知」读成「不是本人」。
    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    -- 逐个月末往前推:哪一个月末的可用余额够了,那天起就订得动。
    -- 累积在月末落账,所以「够了的那天」就是那个月末本身。
    WHILE v_m <= make_date(v_year, 12, 1) LOOP
        v_end := (v_m + interval '1 month' - interval '1 day')::date;
        IF v_end >= p_from
           AND (leave_balance_internal(p_employee_id, 'annual', v_end)->>'bookable')::numeric >= p_days THEN
            RETURN v_end;
        END IF;
        v_m := (v_m + interval '1 month')::date;
    END LOOP;
    -- 本假期年度内都攒不够 —— 返回 NULL,界面据此说另一句话,而不是编一个日期出来。
    RETURN NULL;
END;
$function$
;

-- db/functions/annual_leave_rate_per_year.sql
-- 当月适用的【年额】。界面上的「年假(天/年)」就是这个数 ——
-- 它是一个【费率】不是余额:上个月入职的人费率 24/年,但只能请 2 天。
--
-- NOTE: introduced by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       annual-rate form by db/migrations/2026-08-07-hr2c-fu1-annual-rate-and-immutable-rates.sql.

CREATE OR REPLACE FUNCTION public.annual_leave_rate_per_year(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    -- U1-B(U1A-SELF-GATE-NULL-TRAP):没有员工档案的账号,current_user_employee() 是 NULL,
    --   NOT (false OR NULL) 是 NULL,IF NULL 不进分支 —— 门曾经是开的。COALESCE 把「未知」读成「不是本人」。
    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    RETURN (SELECT (leave_accrual_rate(
                p_employee_id,
                employee_work_category_at(p_employee_id, date_trunc('month', p_as_of)::date),
                date_trunc('month', p_as_of)::date
            )->>'days_per_year')::numeric);
END;
$function$
;

-- db/functions/available_annual_accrual.sql
-- 当年度累积里还剩多少(不含结转)。【不查权限】—— 它是个算式,
-- 谁看得见哪一行由调用方决定(视图的谓词 / leave_balance 的检查)。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.available_annual_accrual(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    -- U1-B(U1A-SELF-GATE-NULL-TRAP):没有员工档案的账号,current_user_employee() 是 NULL,
    --   NOT (false OR NULL) 是 NULL,IF NULL 不进分支 —— 门曾经是开的。COALESCE 把「未知」读成「不是本人」。
    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    RETURN (SELECT accrued_annual_leave(p_employee_id, p_as_of)
         - consumed_from_accrual(p_employee_id, EXTRACT(YEAR FROM p_as_of)::integer));
END;
$function$
;

-- db/functions/consumed_from_accrual.sql
-- 某一年的【派生累积】里已经用掉的天数(draw − release)。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.consumed_from_accrual(p_employee_id uuid, p_leave_year integer)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    -- U1-B(U1A-SELF-GATE-NULL-TRAP):没有员工档案的账号,current_user_employee() 是 NULL,
    --   NOT (false OR NULL) 是 NULL,IF NULL 不进分支 —— 门曾经是开的。COALESCE 把「未知」读成「不是本人」。
    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    RETURN (SELECT COALESCE(SUM(CASE WHEN c.entry_type = 'draw' THEN c.days ELSE -c.days END), 0)
    FROM leave_consumption c
    JOIN leave_requests r ON r.id = c.leave_request_id
    WHERE c.accrual_year = p_leave_year AND r.employee_id = p_employee_id);
END;
$function$
;

-- db/functions/compute_leave_encashment.sql
-- 离职补偿的参考金额。日薪用 MOM 公式 12×月薪÷(52×每周工作天数)。【明确不过账】。
-- 基数取 employees.monthly_salary(月固定工资总额,HR-3b);月薪未录则 SALARY_NOT_SET。
-- 【累积停在最后在职日】不跑到今天 —— 离职之后的月份他并不在职,那些天不是他挣的。
-- 天数用与员工一整年看到的【同一个】数(已向下取到 0.5 天)。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.compute_leave_encashment(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp   record;
    v_bal   jsonb;
    v_days  numeric;
    v_basis numeric;
    v_dpw   numeric;
    v_daily numeric;
    v_asof  date;
BEGIN
    -- U1-B(U1A-SELF-GATE-NULL-TRAP):没有员工档案的账号,current_user_employee() 是 NULL,
    --   NOT (false OR NULL) 是 NULL,IF NULL 不进分支 —— 门曾经是开的。COALESCE 把「未知」读成「不是本人」。
    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    SELECT id, code, legal_name, monthly_salary, separation_date INTO v_emp
    FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    IF v_emp.monthly_salary IS NULL THEN
        RAISE EXCEPTION 'SALARY_NOT_SET|%', v_emp.code;
    END IF;

    -- 【离职的人算到最后在职日为止】。跑到今天会把离职之后的月份也算进去 ——
    -- 那些月他并没有在职,那些天不是他挣的。
    v_asof := p_as_of;
    IF v_emp.separation_date IS NOT NULL AND v_emp.separation_date < v_asof THEN
        v_asof := v_emp.separation_date;
    END IF;

    v_bal := leave_balance(p_employee_id, 'annual', v_asof);
    -- 【与员工一整年看到的是同一个数】leave_balance 已经向下取到 0.5 天(B5)
    v_days := (v_bal->>'available')::numeric;
    v_basis := v_emp.monthly_salary;

    SELECT working_days_per_week INTO v_dpw FROM hr_settings WHERE id;

    v_daily := round((12.0 * v_basis) / (52.0 * v_dpw), 2);

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code,
        'as_of', p_as_of, 'effective_as_of', v_asof,
        'frozen_at_separation', v_emp.separation_date IS NOT NULL AND v_emp.separation_date < p_as_of,
        'unused_days', v_days,
        'monthly_fixed_gross_basis', v_basis,
        'basis_source', 'employees.monthly_salary (contracted fixed gross; excludes overtime, bonus, AWS, commission)',
        'daily_rate', v_daily,
        'daily_rate_formula', format('12 x monthly fixed gross / (52 x %s working days per week)', v_dpw),
        'rounding', 'accrual floored to 0.5 day; daily rate rounded to 2 dp, then multiplied by days and rounded to 2 dp',
        'indicative_amount', round(v_daily * v_days, 2),
        'journal_posted', false,
        'note', 'Indicative only. Payment is made by the outsourced payroll provider; no journal entry is created by this system.',
        'balance_detail', v_bal);
END;
$function$
;

-- db/functions/leave_balance_internal.sql
-- 余额的算式(不查权限)。三个来源:授予行 + 当年度的派生累积(年假)+ 按年额度(其余有额度的假别)。
-- 【HR-2a 那个重复计数的坑】carried_out 扣减照旧:结转是把剩余搬走,不是复制一份。
-- 当年累积没有 expires_on,所以「先用旧的」天然把它排在结转之后,失效逻辑也碰不到它。
--
-- ★ LEAVE-BAL-1(2026-09-28,Tim Q1–Q22):
--   · 'available' 的含义【一个字没改】= 额度 − 已批(employees_masked 与三个页面照旧读它)。
--   · 新增 'pending'(同一人、同一假别、开始日在同一年、还在等批的天数)与
--     'bookable' = available − pending —— 【提交】看 bookable,【审批】看 available(Q10 Option A:
--     别人还在等的单不算,批准不可能让已批超过额度)。
--   · 'balance_checked':这个假别【有没有额度】—— 年假(is_accrued)或 default_days_per_year 不为空。
--     只有 unpaid 没有(Q1)。没有额度的假别 available/bookable 照算(= 0 或授予),但【没有人拿它拒】。
--   · 按年额度:default_days_per_year 整年给足,按【开始日】所在公历年扣已批(Q5 · Q7);
--     不按入职折算(Q6,已登记 known-issues)。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       LEAVE-BAL-1 by db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql.

CREATE OR REPLACE FUNCTION public.leave_balance_internal(p_employee_id uuid, p_leave_type_code text DEFAULT 'annual'::text, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_break   jsonb := '[]'::jsonb;
    v_granted numeric := 0;
    v_used    numeric := 0;
    v_expired numeric := 0;
    v_avail   numeric := 0;
    v_accrued numeric := 0;
    v_acc_used numeric := 0;
    v_year    integer := EXTRACT(YEAR FROM p_as_of)::integer;
    v_type    record;
    v_yearly  numeric := 0;
    v_yr_used numeric := 0;
    v_pending numeric := 0;
    v_checked boolean;
    r         record;
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    -- U1-B(U1A-SELF-GATE-NULL-TRAP):没有员工档案的账号,current_user_employee() 是 NULL,
    --   NOT (false OR NULL) 是 NULL,IF NULL 不进分支 —— 门曾经是开的。COALESCE 把「未知」读成「不是本人」。
    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    FOR r IN
        SELECT g.id, g.leave_year, g.days, g.granted_on, g.expires_on, g.grant_type,
               COALESCE((SELECT SUM(CASE WHEN c.entry_type='draw' THEN c.days ELSE -c.days END)
                         FROM leave_consumption c WHERE c.leave_grant_id = g.id), 0) AS consumed,
               -- 【已被结转走的部分】。结转是把剩余【搬到】下一年的一笔新授予里,
               -- 不是复制一份 —— 若不在这里扣掉,同样的天数会在来源授予和结转授予里
               -- 【各算一次】,余额凭空翻倍。这一条是本切最容易做错的地方之一。
               COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                         WHERE cf.source_grant_id = g.id AND cf.grant_type = 'carry_forward'
                           AND cf.deleted_at IS NULL), 0) AS carried_out
        FROM leave_grants g
        WHERE g.employee_id = p_employee_id AND g.leave_type_code = p_leave_type_code
          AND g.deleted_at IS NULL AND g.granted_on <= p_as_of
        ORDER BY g.expires_on NULLS LAST, g.granted_on
    LOOP
        v_granted := v_granted + r.days;
        v_used := v_used + r.consumed;
        IF r.carried_out > 0 AND (r.days - r.consumed - r.carried_out) <= 0 THEN
            NULL;
        ELSIF r.expires_on IS NOT NULL AND r.expires_on < p_as_of THEN
            v_expired := v_expired + (r.days - r.consumed - r.carried_out);
        ELSE
            v_avail := v_avail + (r.days - r.consumed - r.carried_out);
        END IF;
        v_break := v_break || jsonb_build_object(
            'source', 'grant',
            'grant_id', r.id, 'leave_year', r.leave_year, 'grant_type', r.grant_type,
            'days', r.days, 'consumed', r.consumed, 'carried_forward_out', r.carried_out,
            'remaining', r.days - r.consumed - r.carried_out,
            'expires_on', r.expires_on,
            'status', CASE WHEN r.carried_out > 0 AND (r.days - r.consumed - r.carried_out) <= 0
                                THEN 'carried_forward'
                           WHEN r.expires_on IS NOT NULL AND r.expires_on < p_as_of
                                THEN 'expired' ELSE 'active' END);
    END LOOP;

    -- ── 第二个来源:当年度的派生累积(只有年假) ─────────────────────────────
    -- 【它没有 expires_on】—— 于是"先用旧的"天然把它排在结转行之后,
    -- 也于是失效逻辑【碰不到它】:没有可比的日期,当年挣的天数无从作废(D4)。
    IF p_leave_type_code = 'annual' THEN
        v_accrued  := accrued_annual_leave(p_employee_id, p_as_of);
        v_acc_used := consumed_from_accrual(p_employee_id, v_year);
        v_granted := v_granted + v_accrued;
        v_used    := v_used + v_acc_used;
        v_avail   := v_avail + (v_accrued - v_acc_used);
        v_break := v_break || jsonb_build_object(
            'source', 'accrual',
            'grant_id', NULL, 'leave_year', v_year, 'grant_type', 'monthly_accrual',
            'days', v_accrued, 'consumed', v_acc_used, 'carried_forward_out', 0,
            'remaining', v_accrued - v_acc_used,
            'expires_on', NULL, 'status', 'active');
    END IF;

    -- ── 第三个来源(LEAVE-BAL-1):按年额度 —— 年假以外、default_days_per_year 不为空的假别 ──────
    -- 【不写 leave_consumption】这些假别批准时从来不记消耗行;"已用"就是开始日落在这一年的【已批】单。
    -- 跨年的单整张算在开始日那一年(Q7)—— 与年假的 accrual_year、证明规则的年份同一个口径。
    SELECT lt.is_accrued, lt.default_days_per_year INTO v_type
      FROM leave_types lt WHERE lt.code = p_leave_type_code;
    v_checked := COALESCE(v_type.is_accrued, false) OR v_type.default_days_per_year IS NOT NULL;
    IF NOT COALESCE(v_type.is_accrued, false) AND v_type.default_days_per_year IS NOT NULL THEN
        v_yearly := v_type.default_days_per_year;
        SELECT COALESCE(SUM(lr.days), 0) INTO v_yr_used
          FROM leave_requests lr
         WHERE lr.employee_id = p_employee_id AND lr.leave_type_code = p_leave_type_code
           AND lr.deleted_at IS NULL AND lr.status = 'approved'
           AND EXTRACT(YEAR FROM lr.start_date)::integer = v_year;
        v_granted := v_granted + v_yearly;
        v_used    := v_used + v_yr_used;
        v_avail   := v_avail + (v_yearly - v_yr_used);
        v_break := v_break || jsonb_build_object(
            'source', 'yearly',
            'grant_id', NULL, 'leave_year', v_year, 'grant_type', 'yearly_entitlement',
            'days', v_yearly, 'consumed', v_yr_used, 'carried_forward_out', 0,
            'remaining', v_yearly - v_yr_used,
            'expires_on', NULL, 'status', 'active');
    END IF;

    -- ── 还在等批的(LEAVE-BAL-1):只有【提交】扣它;审批不扣(Q10 Option A)──────────────
    -- 口径与已批同一个:同一人、同一假别、开始日在同一年,不论先后(Q9)。
    SELECT COALESCE(SUM(lr.days), 0) INTO v_pending
      FROM leave_requests lr
     WHERE lr.employee_id = p_employee_id AND lr.leave_type_code = p_leave_type_code
       AND lr.deleted_at IS NULL AND lr.status = 'pending'
       AND EXTRACT(YEAR FROM lr.start_date)::integer = v_year;

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'leave_type_code', p_leave_type_code, 'as_of', p_as_of,
        'granted', v_granted, 'consumed', v_used, 'expired', v_expired,
        'accrued_this_year', v_accrued, 'consumed_from_accrual', v_acc_used,
        -- 【向下取到 0.5】—— 结转与消耗本就是 0.5 的整数倍,这里是防御性的一层
        'available', trim_scale(floor(v_avail * 2) / 2),
        'pending', trim_scale(v_pending),
        'bookable', trim_scale(floor(v_avail * 2) / 2 - v_pending),
        'balance_checked', v_checked,
        'breakdown', v_break);
END;
$function$
;

-- db/functions/leave_balance.sql
-- 对外的余额查询:只比 leave_balance_internal 多做一件事 —— 查权限。
-- 【算式只有一份】属主权限的视图要复用同一套数,不能被权限检查挡住。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.leave_balance(p_employee_id uuid, p_leave_type_code text DEFAULT 'annual'::text, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- U1-B(U1A-SELF-GATE-NULL-TRAP):没有员工档案的账号,current_user_employee() 是 NULL,
    --   NOT (false OR NULL) 是 NULL,IF NULL 不进分支 —— 门曾经是开的。COALESCE 把「未知」读成「不是本人」。
    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    RETURN leave_balance_internal(p_employee_id, p_leave_type_code, p_as_of);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.guard_downtime_period()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_s timestamptz;
    v_e timestamptz;
BEGIN
    -- U1-B(Q15):作废的那一行不再是一段"发生过的停机",三条都不问它 —— 作废一段记错了的(甚至是挡着别人的)
    --   停机,不能被它自己的错挡住。作废之后它冻住(guard_downtime_write),所以这一格只在作废的那一次 UPDATE 上走到。
    IF NEW.voided_at IS NOT NULL THEN
        RETURN NEW;
    END IF;

    -- 【① 开始时间不许在未来】
    -- 简报只点名了"结束不许在未来",而同一句话对开始一样成立 ——
    -- 一段"明天开始"的停机记的是【计划】,不是发生过的事。而这正是 B 那一半的
    -- 论点:计划与事件是两回事。**若将来真要记计划中的检修窗口,那是另一列**
    -- (与 planned_in_service_date 同形),不是把它塞进这一列。
    IF NEW.started_at > now() THEN
        RAISE EXCEPTION 'DOWNTIME_START_IN_FUTURE|%',
            to_char(NEW.started_at, 'YYYY-MM-DD HH24:MI');
    END IF;

    -- 【② 结束时间不许在未来】
    -- 【留空才是"还停着"】—— 而不是填一个将来的时刻当占位。
    IF NEW.ended_at IS NOT NULL AND NEW.ended_at > now() THEN
        RAISE EXCEPTION 'DOWNTIME_END_IN_FUTURE|%',
            to_char(NEW.ended_at, 'YYYY-MM-DD HH24:MI');
    END IF;

    -- 【③ 不许与同一台机器的另一段重叠】
    -- 既有的 uq_equipment_downtime_open 只拦【第二段开口】,对"新的一段落在
    -- 一段已关闭的里面"一个字都不说 —— 而线上发生的正是后者。
    --
    -- 【区间语义:左闭右开,所以【相接允许】】未关闭的一段上界当成 'infinity',
    -- 也就是"从那一刻起一直停着" —— 于是任何落在它之后的新段都会被拦,那是对的。
    -- 【先让形状不对的那一段走它自己的路】ended_at < started_at 时,下面的
    -- tstzrange() 会抛一句【原始的】Postgres 错("range lower bound must be..."),
    -- 抢在 equipment_downtime_period_order 这条具名 CHECK 前面 ——
    -- 于是操作员看见的是机器话,而不是"结束早于开始"。
    -- **这是 fixture 108F5 抓出来的**,不是想出来的:那一臂正是钉住那条 CHECK 的。
    IF NEW.ended_at IS NOT NULL AND NEW.ended_at < NEW.started_at THEN
        RETURN NEW;                      -- 交给 CHECK 去拒,它的句子更准
    END IF;

    SELECT d.started_at, d.ended_at INTO v_s, v_e
      FROM public.equipment_downtime d
     WHERE d.equipment_id = NEW.equipment_id
       AND d.id <> NEW.id
       AND d.voided_at IS NULL            -- U1-B:作废的那一段不挡任何人
       AND tstzrange(d.started_at, COALESCE(d.ended_at, 'infinity'::timestamptz), '[)')
        && tstzrange(NEW.started_at, COALESCE(NEW.ended_at, 'infinity'::timestamptz), '[)')
     ORDER BY d.started_at
     LIMIT 1;
    IF FOUND THEN
        -- D6:把【挡路的那一段】的起止写进句子 —— 改它的人正对着一张列表。
        RAISE EXCEPTION 'DOWNTIME_OVERLAPS|%|%',
            to_char(v_s, 'YYYY-MM-DD HH24:MI'),
            COALESCE(to_char(v_e, 'YYYY-MM-DD HH24:MI'), '(还开着)');
    END IF;

    RETURN NEW;
END;
$fn$;

;

-- db/functions/void_equipment_downtime.sql
-- U1-B(2026-10-05,UNBLOCK-1 Q15):作废一段【从来没有发生过】的停机,带理由。不硬删(guard_downtime_write)。
--
-- 【谁】module.processing.edit —— 与记停机、更正停机同一个码(车间记它,车间收回它)。
-- 【什么时候不行】已经作废的(DOWNTIME_ALREADY_VOIDED);没有理由(DOWNTIME_VOID_REASON_REQUIRED —— 一段消失的停机,
--   "为什么"是读它的人唯一的线索)。开着的与关了的都可以作废:一段记错了的开口也正是最需要收回的那一种。
-- 【作废之后】这一行冻住;它不再挡重叠、不再算"开着的那一段"、交接单不能再引用它;资产页照旧列出它,标着"已作废"与理由。
--   引用过它的交接单不动(那是交接时说过的话)。
--
-- NOTE: introduced by db/migrations/2026-10-05-u1b-workflow-fixes.sql.

CREATE OR REPLACE FUNCTION public.void_equipment_downtime(p_downtime_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_d equipment_downtime%ROWTYPE;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_d FROM equipment_downtime WHERE id = p_downtime_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOWNTIME_NOT_FOUND|%', COALESCE(p_downtime_id::text, '?');
    END IF;
    IF v_d.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'DOWNTIME_ALREADY_VOIDED|%', to_char(v_d.started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DOWNTIME_VOID_REASON_REQUIRED';
    END IF;
    UPDATE equipment_downtime
       SET voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason),
           updated_by = auth.uid()
     WHERE id = p_downtime_id;
    RETURN jsonb_build_object('downtime_id', p_downtime_id, 'equipment_id', v_d.equipment_id, 'voided', true);
END;
$function$;

COMMENT ON FUNCTION public.void_equipment_downtime(uuid, text) IS
'U1-B(UNBLOCK-1 Q15):作废一段没有发生过的停机,带理由;module.processing.edit。作废之后那一行冻住、不挡重叠、不算开着、交接单不能再引用;永远不硬删(guard_downtime_write)。';

CREATE OR REPLACE FUNCTION public.submit_shift_handover(p_shift_code text, p_handover_date date, p_outgoing_employee_id uuid, p_incoming_employee_id uuid, p_notes text DEFAULT NULL::text, p_items jsonb DEFAULT NULL::jsonb, p_downtime_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_elem jsonb;
    v_bad  text;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3b grilling Q2):交接班 = action.processing_aftercare
    --   (仓库)或 module.processing.edit。拒绝点名 action.processing_aftercare。
    IF NOT has_any_permission(ARRAY['action.processing_aftercare', 'module.processing.edit']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.processing_aftercare';
    END IF;

    -- 【世界侧日期不给默认值】与 FIN-10「永不给日期默认值」同一条:
    -- 交接班发生在哪一天是一件世界里的事实,不是 now() 的一个副产品。
    IF p_handover_date IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_DATE_REQUIRED';
    END IF;
    IF p_shift_code IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_SHIFT_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shifts WHERE code = p_shift_code AND is_active) THEN
        RAISE EXCEPTION 'HANDOVER_SHIFT_UNKNOWN|%', p_shift_code
          USING HINT = '未知或已停用的班次。停用的意思是"以后别再排它",不是"把历史改掉"。';
    END IF;
    -- 【交与接【两个人都要有名有姓】】一次说不出是谁交的班,不是一次交接班。
    IF p_outgoing_employee_id IS NULL OR p_incoming_employee_id IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_PEOPLE_REQUIRED'
          USING HINT = '交班的人与接班的人都要点名 —— 一次说不出是谁交给谁的交接班,没有传递任何责任。';
    END IF;
    IF p_outgoing_employee_id = p_incoming_employee_id THEN
        RAISE EXCEPTION 'HANDOVER_SAME_PERSON'
          USING HINT = '交班人与接班人是同一个人 —— 那样的"交接"没有把任何东西传给任何人。';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM employees WHERE id = p_outgoing_employee_id AND deleted_at IS NULL)
       OR NOT EXISTS (SELECT 1 FROM employees WHERE id = p_incoming_employee_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'HANDOVER_EMPLOYEE_NOT_FOUND';
    END IF;

    -- 【条目的类型必须是字典里的】—— 加第七类内容是【加一行字典】,
    -- 而不是在这里放行一个自由字符串。
    IF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
        SELECT elem->>'item_type_code' INTO v_bad
          FROM jsonb_array_elements(p_items) elem
         WHERE NOT EXISTS (SELECT 1 FROM handover_item_types t
                            WHERE t.code = elem->>'item_type_code' AND t.is_active)
         LIMIT 1;
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'HANDOVER_ITEM_TYPE_UNKNOWN|%', v_bad;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) elem
                    WHERE btrim(COALESCE(elem->>'body','')) = '') THEN
            RAISE EXCEPTION 'HANDOVER_ITEM_BODY_REQUIRED'
              USING HINT = '一条内容为空的条目与没有这条条目是同一件事,而它会在计数里冒充"填过了"。';
        END IF;
    END IF;

    -- 【必填的那几类:字典说了算,不是代码说了算】
    SELECT t.name_zh INTO v_bad
      FROM handover_item_types t
     WHERE t.is_active AND t.is_required
       AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(COALESCE(p_items,'[]'::jsonb)) elem
            WHERE elem->>'item_type_code' = t.code
              AND btrim(COALESCE(elem->>'body','')) <> '')
     LIMIT 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'HANDOVER_REQUIRED_ITEM_MISSING|%', v_bad;
    END IF;

    INSERT INTO shift_handovers (shift_code, handover_date, outgoing_employee_id,
                                 incoming_employee_id, notes, submitted_by, created_by, updated_by)
    VALUES (p_shift_code, p_handover_date, p_outgoing_employee_id, p_incoming_employee_id,
            NULLIF(btrim(COALESCE(p_notes,'')), ''), v_user, v_user, v_user)
    RETURNING id INTO v_id;

    IF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
        INSERT INTO shift_handover_items (handover_id, item_type_code, body, sort_order, created_by)
        SELECT v_id, elem->>'item_type_code', btrim(elem->>'body'),
               COALESCE((elem->>'sort_order')::integer, ord::integer), v_user
          FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(elem, ord);
    END IF;

    -- R5:设备状态是一条【引用】。这里存 downtime_id,绝不抄一份 reason。
    IF p_downtime_ids IS NOT NULL AND array_length(p_downtime_ids, 1) > 0 THEN
        IF EXISTS (SELECT 1 FROM unnest(p_downtime_ids) d
                    WHERE NOT EXISTS (SELECT 1 FROM equipment_downtime e WHERE e.id = d)) THEN
            RAISE EXCEPTION 'HANDOVER_DOWNTIME_NOT_FOUND';
        END IF;
        -- U1-B(Q15):一段作废了的停机没有发生过,交接单不能引用它(新建交接单的勾选里本来就不列它)。
        IF EXISTS (SELECT 1 FROM unnest(p_downtime_ids) d
                     JOIN equipment_downtime e ON e.id = d
                    WHERE e.voided_at IS NOT NULL) THEN
            RAISE EXCEPTION 'HANDOVER_DOWNTIME_VOIDED';
        END IF;
        INSERT INTO shift_handover_equipment_refs (handover_id, downtime_id, created_by)
        SELECT v_id, d, v_user FROM unnest(p_downtime_ids) d
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.close_purchase_order(p_purchase_order_id uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_po        record;
    v_prepaid   numeric;
    v_applied   numeric;
    v_unapplied numeric;
    v_received  numeric;
    v_ordered   numeric;
BEGIN
    -- ★ APR-10(Tim 的 grilling Q7):开单人本人(按人认),或此刻持这张单那一类开单码的人 —— 其余按名拒
    --   PO_NOT_RAISER_OR_CATEGORY_HOLDER(assert_po_manager,一份判据;屏幕读同一份 po_may_manage)。
    --   从前的门 module.purchasing.edit 不再够。
    PERFORM assert_po_manager(p_purchase_order_id);
    SELECT id, code, status, notes INTO v_po
    FROM purchase_orders
    WHERE id = p_purchase_order_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;
    IF v_po.status = 'closed' THEN
        RAISE EXCEPTION 'PO_ALREADY_CLOSED|%', v_po.code;
    END IF;

    -- 未抵扣预付 = 已付到该单的预付(posted 收付款)− 已抵扣到批次的部分。
    -- 大于 0 时必须写说明:这是【真金白银】躺在 1300 预付款项里,而这张单永远不会
    -- 再吸收它了 —— 退款、转到别的单、核销,系统今天都还没建模,所以允许关单,
    -- 但必须留下一句写下来的解释,不许无声搁浅。
    SELECT COALESCE(SUM(pa.allocated_base), 0) INTO v_prepaid
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.purchase_order_id = p_purchase_order_id;
    SELECT COALESCE(SUM(ppa.amount_base), 0) INTO v_applied
    FROM prepayment_applications ppa
    WHERE ppa.purchase_order_id = p_purchase_order_id;
    v_unapplied := round(v_prepaid - v_applied, 2);

    IF v_unapplied > 0 AND (p_notes IS NULL OR btrim(p_notes) = '') THEN
        RAISE EXCEPTION 'CLOSE_NOTES_REQUIRED|%', v_unapplied;
    END IF;

    SELECT COALESCE(SUM(ib.quantity), 0) INTO v_received
    FROM inbound_batches ib
    WHERE ib.purchase_order_id = p_purchase_order_id AND ib.deleted_at IS NULL;
    SELECT COALESCE(SUM(pol.quantity), 0) INTO v_ordered
    FROM purchase_order_lines pol
    WHERE pol.purchase_order_id = p_purchase_order_id;

    -- PUR-2:告诉 guard_po_amendable 这是一次【状态转换】,不是一次修改。
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法:显式声明,
    -- 而不是让守卫去猜调用方是谁。
    -- 【用完立刻清掉 —— 这一句是 fu2 的全部内容】set_config(..., true) 是
    -- 【事务】局部,不是语句局部。只在函数开头设一次,守卫就会在这次调用之后、
    -- 整个事务余下的时间里【一直是关着的】:跑过一次 close_purchase_order 之后,
    -- 同一事务里一条直连的 UPDATE ... SET status 就畅通无阻(实测过)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    -- ★ U1-B(UNBLOCK-1 Q25):关单的理由进它自己的列(close_reason / closed_by),【notes 不再被改写】——
    --   从前这里把 "[YYYY-MM-DD HH:MI closed] 理由" 追加进人写的备注(还被印到发给供应商的 PDF 上),
    --   历史触发器把它记成一次没有理由的 header_update。现在 notes 一个字不动,历史另记一行 closed,理由在 amend_reason。
    UPDATE purchase_orders
    SET status = 'closed',
        closed_at = now(),
        closed_by = v_user,
        close_reason = NULLIF(btrim(COALESCE(p_notes, '')), ''),
        updated_by = v_user
    WHERE id = p_purchase_order_id;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);
    INSERT INTO purchase_order_history (purchase_order_id, change_type, amend_reason, changed_by)
    VALUES (p_purchase_order_id, 'closed', NULLIF(btrim(COALESCE(p_notes, '')), ''), v_user);


    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'status', 'closed',
        'unapplied_prepayment_usd', v_unapplied,
        'received_qty', v_received,
        'ordered_qty', v_ordered,
        'receipt_pct', CASE WHEN v_ordered = 0 THEN NULL
                            ELSE round(v_received / v_ordered * 100, 2) END
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.reopen_purchase_order(p_purchase_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_po     record;
    v_status text;
BEGIN
    -- ★ APR-10(Tim 的 grilling Q7):开单人本人(按人认),或此刻持这张单那一类开单码的人 —— 其余按名拒
    --   PO_NOT_RAISER_OR_CATEGORY_HOLDER(assert_po_manager,一份判据;屏幕读同一份 po_may_manage)。
    --   从前的门 module.purchasing.edit 不再够。
    PERFORM assert_po_manager(p_purchase_order_id);
    SELECT id, code, status INTO v_po
    FROM purchase_orders
    WHERE id = p_purchase_order_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status <> 'closed' THEN
        RAISE EXCEPTION 'PO_NOT_CLOSED|%', v_po.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 已经收过货的回到 'receiving',一车没收过的回到 'confirmed'
    SELECT CASE WHEN EXISTS (
        SELECT 1 FROM inbound_batches ib
        WHERE ib.purchase_order_id = p_purchase_order_id AND ib.deleted_at IS NULL
    ) THEN 'receiving' ELSE 'confirmed' END INTO v_status;

    -- PUR-2:告诉 guard_po_amendable 这是一次【状态转换】,不是一次修改。
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法:显式声明,
    -- 而不是让守卫去猜调用方是谁。
    -- 【用完立刻清掉 —— 这一句是 fu2 的全部内容】set_config(..., true) 是
    -- 【事务】局部,不是语句局部。只在函数开头设一次,守卫就会在这次调用之后、
    -- 整个事务余下的时间里【一直是关着的】:跑过一次 close_purchase_order 之后,
    -- 同一事务里一条直连的 UPDATE ... SET status 就畅通无阻(实测过)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    -- ★ U1-B(UNBLOCK-1 Q25):重开的理由进它自己的列(reopen_reason / reopened_at / reopened_by),【notes 不再被改写】。
    --   单子不再是关着的,所以关单那三列清掉;那一次关单的全貌留在历史(closed 那一行)与变更记录里。
    UPDATE purchase_orders
    SET status = v_status,
        closed_at = NULL,
        closed_by = NULL,
        close_reason = NULL,
        reopened_at = now(),
        reopened_by = v_user,
        reopen_reason = btrim(p_reason),
        updated_by = v_user
    WHERE id = p_purchase_order_id;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);
    INSERT INTO purchase_order_history (purchase_order_id, change_type, amend_reason, changed_by)
    VALUES (p_purchase_order_id, 'reopened', btrim(p_reason), v_user);


    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'status', v_status
    );
END;
$function$;

-- db/functions/set_po_line_deep_discharge.sql
-- U1-B(2026-10-05,UNBLOCK-1 Q20 · AT0-DEEP-DISCHARGE-DIRECT-UPDATE):给采购单的一行写下【买的时候】的深度放电判断。
--
-- 【为什么要一支函数】APR-10 起 purchase_order_lines 只经函数写(guard_po_direct_write 对每一个带 RLS 的调用者
--   按名拒 PO_THROUGH_FUNCTION_ONLY),而这个控件一直是直连 UPDATE —— 于是它从 APR-10 那天起一次都没存进去过。
-- 【谁】持 module.purchasing.edit 的人(Tim 的 Q20:它是一行上的【质量判断】,不是一项商业条款 —— 不要改单理由,
--   不问开单人 / 品类码那一道 assert_po_manager)。变更记录记下每一次。
-- 【什么时候】这张单没有被取消(PO_CANCELLED|单号);已删的单找不到(PO_LINE_NOT_FOUND)。关了的单可以 —— 判断常常是
--   收完货之后才有人回头补的。
-- 【不许回到空】NULL 的意思是"这一行早于这一条轴"(列注释),不是"不知道";不知道是 not_assessed。
--   所以空值按名拒(DEEP_DISCHARGE_JUDGEMENT_REQUIRED),字典里没有的码按名拒(DEEP_DISCHARGE_JUDGEMENT_UNKNOWN|码)。
-- 【不写 purchase_order_history】那张表只记商业字段的改动(trg_po_history_line 的五列);这一列从来不在里面 ——
--   它的历史在变更记录里,审计记录读那里。
--
-- NOTE: introduced by db/migrations/2026-10-05-u1b-workflow-fixes.sql.

CREATE OR REPLACE FUNCTION public.set_po_line_deep_discharge(p_line_id uuid, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_l record;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT l.id, l.deep_discharge_judgement_code AS old_code, po.id AS po_id, po.code, po.status
      INTO v_l
      FROM purchase_order_lines l
      JOIN purchase_orders po ON po.id = l.purchase_order_id AND po.deleted_at IS NULL
     WHERE l.id = p_line_id
       FOR UPDATE OF l;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', COALESCE(p_line_id::text, '?');
    END IF;
    IF v_l.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_l.code;
    END IF;
    IF p_code IS NULL OR btrim(p_code) = '' THEN
        RAISE EXCEPTION 'DEEP_DISCHARGE_JUDGEMENT_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM deep_discharge_judgements WHERE code = p_code AND is_active) THEN
        RAISE EXCEPTION 'DEEP_DISCHARGE_JUDGEMENT_UNKNOWN|%', p_code;
    END IF;
    UPDATE purchase_order_lines SET deep_discharge_judgement_code = p_code WHERE id = p_line_id;
    RETURN jsonb_build_object('line_id', p_line_id, 'purchase_order_id', v_l.po_id,
                              'code', p_code, 'previous', v_l.old_code);
END;
$function$;

COMMENT ON FUNCTION public.set_po_line_deep_discharge(uuid, text) IS
'U1-B(UNBLOCK-1 Q20):写一行采购明细的深度放电判断。module.purchasing.edit;单子没被取消;码必须在字典里且启用;不许回到空(NULL = 早于这一条轴)。变更记录记下每一次。';

CREATE OR REPLACE FUNCTION public.close_period(p_period_end date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_locked   date;
    v_count    integer;
    v_debits   numeric;
    v_credits  numeric;
    v_new_lock date;
    v_dep      numeric;
    v_run_n    integer;
    v_runs     text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_period_end IS NULL
       OR p_period_end <> (date_trunc('month', p_period_end) + interval '1 month - 1 day')::date THEN
        RAISE EXCEPTION 'NOT_MONTH_END|%', COALESCE(p_period_end::text, '?');
    END IF;

    SELECT locked_before INTO v_locked FROM finance_settings WHERE id FOR UPDATE;
    IF v_locked IS NOT NULL AND p_period_end < v_locked THEN
        RAISE EXCEPTION 'ALREADY_CLOSED|%', v_locked;
    END IF;

    v_dep := (preview_depreciate_fixed_assets(p_period_end)->>'total_delta')::numeric;
    IF COALESCE(v_dep, 0) > 0 THEN
        RAISE EXCEPTION 'DEPRECIATION_OUTSTANDING|%|%', p_period_end, v_dep;
    END IF;

    -- ★ INV-VAL-1 R8:第五条 —— 已提交但从未分摊成本的加工单挡住关账。
    -- 与折旧那一条同形(都是"这个月还欠着一件必须做完的事"),所以紧挨着它。
    -- U1-B:判据抽成 processing_runs_blocking_close —— 月结清单读同一支,两边从此数的是同一样东西。
    SELECT b.run_count, b.run_codes
      INTO v_run_n, v_runs
      FROM processing_runs_blocking_close(p_period_end) b;
    IF COALESCE(v_run_n, 0) > 0 THEN
        RAISE EXCEPTION 'PROCESSING_COSTS_UNALLOCATED|%|%|%', p_period_end, v_run_n, v_runs
          USING HINT = '这些加工单已提交但从未分摊成本 —— 料已经动了,而 1200 还没有被解除。'
                    || '在关账之前把它们分摊掉,或者冲销掉不该存在的那些。';
    END IF;

    SELECT COUNT(DISTINCT jl.entry_id),
           round(COALESCE(SUM(jl.debit), 0), 2),
           round(COALESCE(SUM(jl.credit), 0), 2)
    INTO v_count, v_debits, v_credits
    FROM journal_lines jl
    JOIN journal_entries je ON je.id = jl.entry_id
    WHERE je.entry_date <= p_period_end;

    IF v_debits <> v_credits THEN
        RAISE EXCEPTION 'TRIAL_BALANCE_UNBALANCED|%|%', v_debits, v_credits;
    END IF;

    v_new_lock := p_period_end + 1;

    INSERT INTO period_closes (period_end, notes, entries_count, total_debits, total_credits)
    VALUES (p_period_end, p_notes, v_count, v_debits, v_credits);

    UPDATE finance_settings
    SET locked_before = v_new_lock, updated_by = auth.uid()
    WHERE id;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'locked_before', v_new_lock,
        'entries_count', v_count,
        'total_debits', v_debits,
        'total_credits', v_credits
    );
END;
$function$
;

-- db/functions/self_approved_decisions.sql
-- APR-ROUTE-1(Tim 的 R2 · Q4):【每一次自批,一行】—— 自批报表的唯一数据来源。
--
-- 【它为什么存在】Tim 裁定二级审批角色的持有人可以决定他自己的报销单与医疗申报,
-- 而且是有意识地选了【可追溯】而不是【可防止】。可追溯要成立,就必须有一个地方
-- 让别人【看得见】每一次这样的决定 —— 一个只写进 approval_log、却没有任何屏幕
-- 读它的标记,与没有标记是同一件事(本仓库反复付账的"写得进、读不出")。
--
-- 【谁看得见】持 data.view_self_approvals 的人:admin · gm(MD,Vince)· auditor
-- (Tim 的 Q4)。★ 这一个码是【新铸的】,不借 module.finance.view / module.hr.view:
-- 后两者 finance 与 cfo 自己就持有 —— 也就是被这张表报告的那个人,
-- 用借来的码他就总是看得见自己被报告了什么,而 Tim 要的读者是另外那几位。
--
-- 【为什么是一支 DEFINER 函数,不是一张视图】approval_log 的读策略按 subject_type
-- 分门(报销 → module.finance.view,医疗 → module.hr.view)。一个持本码而不持
-- 那两个模块码的审计者,经由那张表会读到【0 行,而且不报错】—— 与"从来没人自批过"
-- 逐字相同。所以这里以属主身份读,而门只有一个:本码。
-- ★ 读者没有这个码时【RAISE】,不返回零行 —— 零行在这里有主,它的意思是
--   "没有人自批过",把拒绝也表示成零行就是把拒绝伪装成一个合法答案
--   (AGENTS.md「拒绝要用哪个值表示」)。
--
-- 【名字跟着单据走】(Standing decision 3)决定人与主角的【显示名】随行返回;
-- 别的员工属性一概不带。
--
-- ★ ROLE-1(2026-09-23):R2 扩到请假(只对 CFO),于是主角的 LATERAL 多一支 leave_requests ——
--   不加它,Tim 自批的假在报表上会有一个空白的主角。admin 不再持 data.view_self_approvals
--   (Tim 的 Q8:admin 只做系统管理),读者剩 gm 与 auditor。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1a-higher-decides-lower-and-the-flagged-self.sql.

CREATE OR REPLACE FUNCTION public.self_approved_decisions()
 RETURNS TABLE(seq bigint, decided_at timestamp with time zone, subject_type text, subject_id uuid, subject_code text, decision text, level smallint, actor_user_id uuid, actor_name text, subject_employee_id uuid, subject_name text, amount_ccy numeric, currency text, amount_base numeric, note text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('data.view_self_approvals');

    RETURN QUERY
    SELECT a.seq, a.decided_at, a.subject_type, a.subject_id, a.subject_code, a.decision,
           a.level, a.actor_user_id,
           COALESCE(ae.legal_name, au.email::text, a.actor_user_id::text) AS actor_name,
           s.employee_id,
           se.legal_name,
           -- ★ U1-B(2026-10-05):属主身份读,所以留痕那两道遮蔽要在这里再问一次 —— 自批报表的读者(gm · auditor)不一定持
           --   data.view_health,而一张自批的医疗报销,金额与说明都是健康数据(approval_log_masked 同一对判据)。
           CASE WHEN approval_log_amount_visible(a.subject_type, a.subject_id) THEN a.amount_ccy END,
           a.currency,
           CASE WHEN approval_log_amount_visible(a.subject_type, a.subject_id) THEN a.amount_base END,
           CASE WHEN approval_log_note_visible(a.subject_type, a.subject_id) THEN a.note END
      FROM approval_log a
      LEFT JOIN auth.users au ON au.id = a.actor_user_id
      LEFT JOIN employees ae ON ae.id = account_person(a.actor_user_id)
      LEFT JOIN LATERAL (
            SELECT c.employee_id FROM expense_claims c
             WHERE a.subject_type = 'expense_claim' AND c.id = a.subject_id
            UNION ALL
            SELECT m.employee_id FROM medical_claims m
             WHERE a.subject_type = 'medical_claim' AND m.id = a.subject_id
            UNION ALL
            SELECT l.employee_id FROM leave_requests l
             WHERE a.subject_type = 'leave_request' AND l.id = a.subject_id
      ) s ON true
      LEFT JOIN employees se ON se.id = s.employee_id
     WHERE a.self_decided
     ORDER BY a.seq DESC;
END;
$function$;

COMMENT ON FUNCTION public.self_approved_decisions() IS
'APR-ROUTE-1(R2 · Q4):自批报表 —— approval_log 里 self_decided 的每一行,带决定人与主角的显示名。门只有一个:data.view_self_approvals(ROLE-1 起:gm · auditor —— admin 不再持任何业务码);没有它就 RAISE,不返回零行(零行在这里的意思是"没有人自批过")。以属主身份读,因为 approval_log 的读策略按单据类型分门,一个只持本码的审计者经由那张表会静默读到零行。';

-- db/functions/journal_request_submit_internal.sql
-- APR-6(2026-09-25):提一张手工凭证 / 冲销申请 —— submit_journal_request 与 submit_journal_reversal_request
-- 都落进来的那一支。两扇门各自先问 module.finance.edit;本支不问码。
--
--   1. 日期、摘要 / 理由在写入之前就按名拒(JE_LINE_INVALID|entry_date · REVERSAL_DATE_REQUIRED ·
--      JE_MEMO_REQUIRED · JOURNAL_REVERSAL_REASON_REQUIRED)—— 否则撞上的是表上的 NOT NULL / CHECK,屏幕只能说"意外错误"。
--      【日期决定期间,所以必填、从不代填】(AGENTS.md「Dates and amounts that decide a period」)。
--   2. reversal:那张分录要在(JE_NOT_FOUND),要冲得了(已冲过 → JE_ALREADY_REVERSED),而且要落在
--      'request' 那一格 —— 有自己冲销路径的按名拒 JE_REVERSE_USE_SOURCE_PATH(journal_entry_reversal_route
--      一份判据,Q6)。同一张分录已经挂着一张在等的冲销 → JOURNAL_REQUEST_OPEN|分录|那一张(唯一索引是第二道)。
--   3. ★ 审批开着时:提单人这个【人】之外,二级还有没有人批得动(assert_other_decider,按人认)。
--      没有 → JOURNAL_REQUEST_NO_OTHER_DECIDER|label。线上是 admin@:它与 tim@ 是同一个人,而二级只有 tim@。
--   4. 落一行 submitted;参数原样冻结。
--   5. 按批准那一刻会用的同一支过账试跑(journal_request_dry_run)—— 借贷不平、科目、币种、汇率、期间锁、
--      年结、超出当月、1100 / 2000,这里按引擎的原话拒。amount_base 与 credits_bank 取试跑的结果。
--   6. 审批开着:留痕 submitted,二级。关着:当场过账(journal_request_post_internal),状态 approved,
--      留痕 auto_approved —— 没有人按过批准,留痕就不许说有人按过。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.journal_request_submit_internal(p_kind text, p_entry_date date, p_memo text, p_lines jsonb, p_target_entry_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_on    boolean := approvals_enabled();
    v_id    uuid := gen_random_uuid();
    v_je    journal_entries%ROWTYPE;
    v_route text;
    v_open  text;
    v_n     integer;
    v_label text;
    v_dry   jsonb;
    v_post  jsonb := NULL;
BEGIN
    IF p_kind = 'entry' THEN
        IF p_entry_date IS NULL THEN
            RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
        END IF;
        IF p_memo IS NULL OR btrim(p_memo) = '' THEN
            RAISE EXCEPTION 'JE_MEMO_REQUIRED';
        END IF;
        IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
            RAISE EXCEPTION 'JE_LINE_INVALID|lines';
        END IF;
    ELSIF p_kind = 'reversal' THEN
        IF p_entry_date IS NULL THEN
            RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
        END IF;
        IF p_memo IS NULL OR btrim(p_memo) = '' THEN
            RAISE EXCEPTION 'JOURNAL_REVERSAL_REASON_REQUIRED';
        END IF;
        SELECT * INTO v_je FROM journal_entries WHERE id = p_target_entry_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'JE_NOT_FOUND|%', COALESCE(p_target_entry_id::text, '?');
        END IF;
        v_route := journal_entry_reversal_route(v_je.id);
        IF v_route = 'reversed' THEN
            RAISE EXCEPTION 'JE_ALREADY_REVERSED|%', v_je.code;
        END IF;
        IF v_route = 'source_path' THEN
            RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_je.code, v_je.source_type;
        END IF;
        SELECT q.label INTO v_open FROM journal_requests q
         WHERE q.target_entry_id = v_je.id AND q.kind = 'reversal' AND q.status = 'submitted';
        IF FOUND THEN
            RAISE EXCEPTION 'JOURNAL_REQUEST_OPEN|%|%', v_je.code, v_open;
        END IF;
    ELSE
        RAISE EXCEPTION 'JOURNAL_REQUEST_KIND_UNKNOWN|%|%', '?', COALESCE(p_kind, '?');
    END IF;

    -- label 的序号:同一种类里第几张。咨询锁串行化"数一遍 + 1",与 post_journal_entry 的编号同一个手法。
    PERFORM pg_advisory_xact_lock(hashtext('journal_request_label')::bigint);
    IF p_kind = 'entry' THEN
        SELECT count(*) + 1 INTO v_n FROM journal_requests WHERE kind = 'entry';
        v_label := 'manual journal #' || v_n::text;
    ELSE
        SELECT count(*) + 1 INTO v_n FROM journal_requests WHERE kind = 'reversal' AND target_entry_id = v_je.id;
        v_label := v_je.code || ' · reversal #' || v_n::text;
    END IF;

    PERFORM assert_other_decider('journal_request', 'decide_journal_request', 2::smallint,
                                 'JOURNAL_REQUEST_NO_OTHER_DECIDER|' || v_label);

    INSERT INTO journal_requests (id, kind, status, label, entry_date, memo, lines, target_entry_id,
                                  amount_base, created_by)
    VALUES (v_id, p_kind, 'submitted', v_label, p_entry_date, btrim(p_memo),
            CASE WHEN p_kind = 'entry' THEN p_lines END,
            CASE WHEN p_kind = 'reversal' THEN v_je.id END,
            0, auth.uid());

    v_dry := journal_request_dry_run(v_id);
    UPDATE journal_requests
       SET amount_base = (v_dry->>'amount_base')::numeric,
           credits_bank = (v_dry->>'credits_bank')::boolean
     WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('journal_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        v_post := journal_request_post_internal(v_id);
        UPDATE journal_requests
           SET status = 'approved', amount_base = (v_post->>'amount_base')::numeric,
               credits_bank = (v_post->>'credits_bank')::boolean,
               result_journal_entry_id = (v_post->>'entry_id')::uuid
         WHERE id = v_id;
        PERFORM record_approval_decision('journal_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场过账,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'kind', p_kind,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        -- U1-B:返回值也是一扇读的门 —— 工资分录的冲销申请,金额只给持 data.view_pay 的人(journal_request_amount_visible)。
        'amount_base', CASE WHEN journal_request_amount_visible(v_id)
                            THEN COALESCE(v_post->'amount_base', v_dry->'amount_base') END,
        'credits_bank', COALESCE(v_post->'credits_bank', v_dry->'credits_bank'),
        'entry_id', v_post->>'entry_id',
        'journal_code', v_post->>'journal_code');
END;
$function$;

-- db/functions/decide_journal_request.sql
-- APR-6(2026-09-25):CFO 批准或驳回一张手工凭证 / 冲销申请。批准【当场过账】(grilling Q3),按提交时冻下来的
-- 那一组 —— 日期就是提单人填的那一天。
--
-- 【门】module.finance.view + data.view_prices —— 与付款、贷项申请同一对码(凭证页的门,加上看得见金额的那个码;
-- docs/approvals.md §5)。【不是】module.finance.edit:那是提单的码。cfo 两个都持(Step 0 以 postgres 读基表)。
-- 【谁能批】二级审批人,每一张、不分档,从不经按金额分档的那一支(N1 对 journal_entries 退休,Q2)。
-- 【四眼】forbid_self_approval(提单人, NULL, …)—— 一张手工凭证不是谁的"自己的单据",主角那条腿对谁都不成立;
-- 提单人那条腿按人认:admin@ 提的,tim@ 批不了(同一个人)—— 所以提交时就按名拒
-- JOURNAL_REQUEST_NO_OTHER_DECIDER,不让它挂到这里。self_approval_exception 不认本类型,R2 不适用。
--
-- 【批准之前不另查】批准就是那一次真的过账:期间在等待中被锁上(PERIOD_LOCKED)、年结(YEAR_CLOSED)、
-- 科目被停用、那张要冲的分录已经被别的路冲掉 —— 全按引擎原话拒,整笔回滚,申请仍在等;CFO 驳回,
-- 或财务撤回、换一个开着的日子再提(Q4:锁永远赢,从不因为一张在等的申请而被拒)。驳回从不检查这些:
-- 驳回一张坏掉的申请,正是出路。驳回要理由。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
--
-- 【过出来那张分录的 created_by 是批准的 CFO】(列默认 auth.uid(),而过账发生在批准这一刻)。职责分离那条
-- 规矩(sod_manual_posters_in)因此经 journal_requests.result_journal_entry_id 找回【提单人】—— Q5:
-- 批准的 CFO 不是"记手工凭证的人"。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.decide_journal_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r    journal_requests%ROWTYPE;
    v_post jsonb;
BEGIN
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM journal_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JOURNAL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'JOURNAL_REQUEST_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'journal_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'JOURNAL_REQUEST_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE journal_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('journal_request', p_request_id, 'rejected', 2::smallint,
                                         btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    v_post := journal_request_post_internal(p_request_id);

    UPDATE journal_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           amount_base = (v_post->>'amount_base')::numeric,
           credits_bank = (v_post->>'credits_bank')::boolean,
           result_journal_entry_id = (v_post->>'entry_id')::uuid
     WHERE id = p_request_id;
    PERFORM record_approval_decision('journal_request', p_request_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'kind', v_r.kind,
                              'entry_id', v_post->>'entry_id',
                              'journal_code', v_post->>'journal_code',
                              -- U1-B:返回值也是一扇读的门(journal_request_amount_visible)。
                              'amount_base', CASE WHEN journal_request_amount_visible(p_request_id)
                                                  THEN v_post->'amount_base' END);
END;
$function$;

-- ── 4 · 新的遮蔽伴生视图(镜像原样)────────────────────────────────────────

-- db/views/journal_requests_masked.sql
-- U1-B(2026-10-05,U1A-PAYROLL-REVERSAL-REQUEST-SHOWS-AMOUNT):手工凭证申请的遮蔽伴生视图。
-- 【遮什么】amount_base —— 一张工资分录(发薪 · 公积金 · 扣款)的冲销申请,金额就是那张分录的合计;要 data.view_pay。
--   判据住在 journal_request_amount_visible(与 journal_lines_masked 同一个谓词:持码,或冲销的不是工资分录)。
--   amount_restricted 说出"这一个 NULL 是受限,不是零"—— 页面照它印「受限」,不印 0.00。
-- 【行谓词】= 基表的读策略(module.finance.view)—— 属主视图绕过 RLS,所以这里必须再问一次。
-- 【列】基表的每一列都在这里(colgrant)。判据与 change_log_mask_rules 的 jr_amount 同一支函数。

CREATE VIEW public.journal_requests_masked WITH (security_invoker = off) AS
 SELECT id,
    kind,
    status,
    label,
    entry_date,
    memo,
    lines,
    target_entry_id,
        CASE
            WHEN journal_request_amount_visible(id) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    credits_bank,
    decided_at,
    decided_by,
    decision_notes,
    result_journal_entry_id,
    withdrawn_at,
    withdrawn_by,
    withdraw_reason,
    created_at,
    created_by,
    NOT journal_request_amount_visible(id) AS amount_restricted
   FROM journal_requests
  WHERE has_permission('module.finance.view'::text);

COMMENT ON VIEW public.journal_requests_masked IS
    'U1-B:手工凭证申请的遮蔽伴生视图。amount_base 要 journal_request_amount_visible(持 data.view_pay,或冲销的不是工资分录);amount_restricted 为真时页面印「受限」。行谓词 = 基表的读策略(module.finance.view)。';

GRANT SELECT ON public.journal_requests_masked TO authenticated;

-- ── 5 · 改过的视图(镜像原样,CREATE OR REPLACE)───────────────────────────

-- db/views/approval_log_masked.sql
-- U1-A(UNBLOCK-1 Q8 · Q10,2026-10-05):审批留痕的遮蔽伴生视图。
-- 【遮什么】amount_ccy 与 amount_base —— 工资申请那一行是一期的工资合计(要 data.view_pay),医疗报销那一行是报销金额
--   (要 data.view_health,或那张报销单就是读者本人的)。其余种类原样给。判据住在 approval_log_amount_visible,
--   change_log_mask_rules 的 apr_amount 规则调的是同一支。
-- ★ U1-B(2026-10-05):note 也遮 —— 医疗报销那一行的说明是健康的字(approval_log_note_visible);金额那两列多认一种:
--   工资分录的冲销申请(journal_request,approval_log_amount_visible 的新一支)。
-- 【行谓词】approval_log_readable(subject_type) —— 与基表那条策略调同一支函数(属主视图绕过 RLS,所以这里必须再问一次)。
-- 【列】基表的每一列都在这里(colgrant:一张表有了 _masked 伴生视图,它的每一列都必须出现在视图里)。

CREATE OR REPLACE VIEW public.approval_log_masked WITH (security_invoker = off) AS
 SELECT id,
    seq,
    subject_type,
    subject_id,
    subject_code,
    decision,
    level,
    actor_user_id,
    decided_at,
        CASE
            WHEN approval_log_note_visible(subject_type, subject_id) THEN note
            ELSE NULL::text
        END AS note,
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
-- ★ U1-B(2026-10-05):decision_notes(批准 / 驳回的理由)同一个判据 —— Tim:健康的字跟 data.view_health 走。
-- 行谓词 = 基表的两条读策略(module.hr.view,或本人)。每一列都在这里(colgrant)。
-- 判据与 change_log_mask_rules 的 code_or_self:data.view_health:employee_id 逐字同一个。

CREATE OR REPLACE VIEW public.medical_claims_masked WITH (security_invoker = off) AS
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
        CASE
            WHEN has_permission('data.view_health'::text) OR employee_id = current_user_employee() THEN decision_notes
            ELSE NULL::text
        END AS decision_notes,
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
    'U1-A(UNBLOCK-1 Q8):医疗报销的遮蔽伴生视图。description 与 amount_sgd(U1-B 起加上 decision_notes)要 data.view_health 或本人;行谓词 = 基表的读策略(module.hr.view 或本人)。';

GRANT SELECT ON public.medical_claims_masked TO authenticated;

-- db/views/purchase_orders_masked.sql
-- ★ ROLE-1 Batch 4a(2026-09-25,Tim 的 Q9 线):本视图是【采购那一侧】的价格 —— 遮蔽码从 data.view_prices
--   换成 data.view_purchase_prices(今天持 view_prices 的每一个角色一并拿到它,仓库只拿它)。
-- 遮蔽伴生视图:purchase_orders 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:estimated_total_ccy → data.view_prices, fx_rate → data.view_prices,
--             tax_total_ccy → data.view_prices(PO-GST-1)
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.purchasing.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.

CREATE OR REPLACE VIEW public.purchase_orders_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    supplier_id,
    order_date,
    expected_delivery_date,
    currency,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN estimated_total_ccy
            ELSE NULL::numeric
        END AS estimated_total_ccy,
    status,
    approval_status,
    approved_at,
    approved_by,
    incoterm,
    terms_text,
    notes,
    closed_at,
    cancelled_at,
    cancel_reason,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    deleted_by,
    delete_reason,
    cancelled_by,
    -- CONTRACT-1:这张单据挂在哪一份合同之下。**新列加在末尾** ——
    -- CREATE OR REPLACE VIEW 只许末尾追加,中间插一列要 DROP + 重建。
    -- 【它必须出现在这张视图里】purchase_orders 是遮蔽表,而 colgrant 那道闸要求
    -- 它的每一列要么被列授权、要么在 _masked 里(WO-1a 那一课:ADD/GRANT/_masked
    -- 三件事要在同一次迁移里做完 —— KPI-1 为漏掉后两件付过一次账)。
    -- 【条款不从这一列读】它只是导航;条款读 contract_document_terms 那份副本。
    contract_id,
    -- PO-GST-1(2026-09-03):这张单的税额合计。**是钱** —— 与 estimated_total_ccy
    -- 同一扇门。净额那一列一个字节没动,含税额在读的那一侧相加(见列注释)。
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN tax_total_ccy
            ELSE NULL::numeric
        END AS tax_total_ccy,
    -- PO-GST-1-fu2:含税额 —— **屏幕读这一列,自己不做加法**。
    -- 委托 ①d 的那条要求:屏幕与 PDF 必须读同一个来源。net 与 tax 本来就是同两列,
    -- 而 gross = net + tax 这次加法若两边各写一遍,就是第二份实现。
    -- 【不落库成第三列】导出量不存;存了就会有"净额改了而它没跟上"的错数。
    -- 遮蔽自然传导:分量为 NULL 时整个表达式就是 NULL。
        CASE WHEN has_permission('data.view_purchase_prices'::text)
             THEN estimated_total_ccy + COALESCE(tax_total_ccy, 0)
             ELSE NULL::numeric END AS gross_total_ccy,
    -- 这张单【算过税吗】—— NULL 的税额合计【不是】零税:它是"开在 PO-GST-1 之前,
    -- 或开在 GST 未注册的时候"。屏幕靠它决定说哪一句话,而不是印一个 0.00。
    (tax_total_ccy IS NOT NULL) AS carries_tax,
    -- PUR-1(2026-09-08):交货地点。**新列加在末尾** —— CREATE OR REPLACE VIEW
    -- 只许末尾追加,中间插一列要 DROP + 重建(与上面 contract_id 那一条同一课)。
    -- 【不遮蔽】它是一个地址,不是钱。
    delivery_location,
    -- APR-10(2026-09-27):品类(工厂耗材 / 设备与货物 / 办公用品)。末尾追加;【不遮蔽】它是一个分类,不是钱。
    category,
    -- U1-B(2026-10-05,Q25):关闭 / 重开的人与理由。末尾追加;【不遮蔽】。
    closed_by,
    close_reason,
    reopened_at,
    reopened_by,
    reopen_reason
   FROM purchase_orders
  WHERE has_permission('module.purchasing.view'::text);

-- ── 6 · 自证 ─────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.u1b_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE u1b_pending_after ON COMMIT DROP AS
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
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权一行不多一行不少
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM u1b_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM u1b_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'U1B_PROOF|grants moved: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'U1B_PROOF|approvals switched off'; END IF;
    IF (SELECT count(*) FROM auth.users WHERE banned_until IS NOT NULL AND banned_until > now()) <> 0 THEN
        RAISE EXCEPTION 'U1B_PROOF|an account is disabled';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 只多 document_types 那一行;采购单与停机一行没动(加的列都是 NULL)
    IF EXISTS ((SELECT b.k, b.id FROM u1b_pending_before b EXCEPT SELECT a.k, a.id FROM u1b_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM u1b_pending_after a EXCEPT SELECT b.k, b.id FROM u1b_pending_before b)) THEN
        RAISE EXCEPTION 'U1B_PROOF|a pending document changed state';
    END IF;
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM u1b_log_before) AND c.table_name NOT IN ('document_types');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'U1B_PROOF|change_log moved on %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM purchase_orders p JOIN u1b_po_before b ON b.id = p.id
     WHERE md5((to_jsonb(p) - ARRAY['closed_by', 'close_reason', 'reopened_at', 'reopened_by', 'reopen_reason'])::text) <> b.digest
        OR p.closed_by IS NOT NULL OR p.close_reason IS NOT NULL OR p.reopened_at IS NOT NULL
        OR p.reopened_by IS NOT NULL OR p.reopen_reason IS NOT NULL;
    IF v_n <> 0 OR (SELECT count(*) FROM purchase_orders) <> (SELECT count(*) FROM u1b_po_before) THEN
        RAISE EXCEPTION 'U1B_PROOF|% purchase order(s) changed', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM equipment_downtime dt JOIN u1b_dt_before b ON b.id = dt.id
     WHERE md5((to_jsonb(dt) - ARRAY['voided_at', 'voided_by', 'void_reason'])::text) <> b.digest OR dt.voided_at IS NOT NULL;
    IF v_n <> 0 OR (SELECT count(*) FROM equipment_downtime) <> (SELECT count(*) FROM u1b_dt_before) THEN
        RAISE EXCEPTION 'U1B_PROOF|% downtime row(s) changed', v_n;
    END IF;

    -- ④ 形状:遮蔽名单与目录对得上(104 条、零缺口);三列真的收回了
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN RAISE EXCEPTION 'U1B_PROOF|mask gaps: %', v_j -> 'gaps'; END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 104 THEN
        RAISE EXCEPTION 'U1B_PROOF|expected 104 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF has_column_privilege('authenticated', 'public.journal_requests', 'amount_base', 'SELECT')
       OR has_column_privilege('authenticated', 'public.approval_log', 'note', 'SELECT')
       OR has_column_privilege('authenticated', 'public.medical_claims', 'decision_notes', 'SELECT') THEN
        RAISE EXCEPTION 'U1B_PROOF|one of the three columns is still granted';
    END IF;
    IF NOT has_column_privilege('authenticated', 'public.purchase_orders', 'close_reason', 'SELECT') THEN
        RAISE EXCEPTION 'U1B_PROOF|purchase_orders.close_reason is not readable';
    END IF;

    -- ⑤ 以真账号的身份读:cto(phua@)读别人的医疗理由是 NULL;finance(chooer@)读得到;两人都读得到申请视图(线上 0 行)
    PERFORM set_config('request.jwt.claims', '{"sub":"e61d99f2-2b95-4059-86f8-5aef8b5cffb5","role":"authenticated"}', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM medical_claims_masked WHERE decision_notes IS NOT NULL AND employee_id <> current_user_employee();
    SELECT count(*) INTO v_m FROM approval_log_masked WHERE subject_type = 'medical_claim' AND note IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM medical_claims mc WHERE mc.id = subject_id AND mc.employee_id = current_user_employee());
    PERFORM count(*) FROM journal_requests_masked;
    EXECUTE 'RESET ROLE';
    IF v_n + v_m <> 0 THEN RAISE EXCEPTION 'U1B_PROOF|cto still reads medical decision text: claims % · approval rows %', v_n, v_m; END IF;
    PERFORM set_config('request.jwt.claims', '{"sub":"476bf8c8-c248-4352-9a75-945bf52ca390","role":"authenticated"}', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM medical_claims_masked WHERE decision_notes IS NOT NULL;
    PERFORM count(*) FROM journal_requests_masked;
    EXECUTE 'RESET ROLE';
    IF v_n <> (SELECT count(*) FROM medical_claims WHERE decision_notes IS NOT NULL) THEN
        RAISE EXCEPTION 'U1B_PROOF|finance reads % of % medical decision notes', v_n,
            (SELECT count(*) FROM medical_claims WHERE decision_notes IS NOT NULL);
    END IF;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.u1b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'U1B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.u1b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'U1B_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.u1b_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
