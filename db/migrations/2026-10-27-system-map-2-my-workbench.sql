-- db/migrations/2026-10-27-system-map-2-my-workbench.sql
-- SYSTEM-MAP-2(v1.4.78,Tim 2026-10-26 裁定 2.4 (9)–(11) 与 2026-10-27 Q1–Q7):工作台 › 待办 —— 一份"在等谁"。
--   ① waiting_decisions() —— 在等【调用者】决定的单据,只列他此刻批得了的:建在 approval_pending_documents() ×
--      approval_deciders() / salary_change_deciders() 上(CFO 级 · 1,000 分档 · 四眼 · 自批例外一条都不另写),其余几种按
--      decision_gate_code() + self_approval_allows();已批准等付款的付款申请(Q4 c)带上引擎里的 guard_payment_sod。
--   ② waiting_mine() · waiting_for_me() · waiting_for_me_count() —— 待办页与首页的数读同一条查询(2.4 (10))。
--   ③ self_approval_allows() —— 四眼的判据从 forbid_self_approval 搬出来(一字未改),forbid_self_approval 只负责拒。
--   ④ decision_arms() · waiting_decision_reach() —— 提醒页的审批支:operations_now 按 waiting_decisions 逐行过滤;
--      批不了这一类的读者看见「受限」+ 由谁决定(Q3)。operations_arms_all 加六支(一般报销 · 采购单审批 · 加班 · 工单 /
--      配料计划放行 · 门户证书,2.4 (11) · Q4 b)。
--   ⑤ certificate_expiry_status() + supplier_certificate_status —— 证书状态一份判据(提醒两支与总览的状态列,64d-2)。
--   ⑥ purchase_order_status 末尾加 approval_status(PO-LIST-NO-APPROVAL-STATUS)。
-- 不建表、不改任何一行数据。镜像:下面每一段逐字是它标着的那个文件(视图在迁移里写成 CREATE OR REPLACE —— 列不变,
-- 镜像是重建用的首建写法)。行为:db/fixtures/295(24 种 × 七个线上角色,待办 ⇔ 决定函数)。
-- EXECUTE:apply_migration.sh 在本事务里重放 db/views/zzz_function_grants.sql(self_approval_allows 收回)。
BEGIN;

-- ── db/functions/self_approval_allows.sql ──
-- db/functions/self_approval_allows.sql
-- SYSTEM-MAP-2(2026-10-27):【四眼原则的判据】—— 账号 p_user 可不可以决定这一份单据(提单人 p_raiser、主角 p_subject_employee)。
--   从 forbid_self_approval 里原样搬出来,判据一字未改:self_leg 说"不是自己" → 可以;否则只有 R2 那个例外
--   (self_approval_exception:报销 · 医疗 · 请假,主角就是我,而我此刻是二级审批角色的真持有人)。
-- 两个读者,一份判据:forbid_self_approval(拒)· waiting_decisions(待办只列我批得了的)。
-- 永不返回 NULL。EXECUTE 已从 authenticated 收回(只给属主权限的调用方用)。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.self_approval_allows(p_raiser uuid, p_subject_employee uuid, p_subject_type text, p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT self_leg(p_raiser, p_subject_employee, p_user) = 'none'
        OR self_approval_exception(p_subject_type, p_subject_employee, p_user,
                                   (SELECT fs.approval_level2_role_code FROM finance_settings fs LIMIT 1));
$function$;

COMMENT ON FUNCTION public.self_approval_allows(uuid, uuid, text, uuid) IS
'SYSTEM-MAP-2:四眼原则的判据(从 forbid_self_approval 原样搬出):self_leg = none,或 R2 的自批例外成立。两个读者:forbid_self_approval(拒)与 waiting_decisions(待办只列我批得了的)。永不返回 NULL。EXECUTE 已从 authenticated 收回。';

-- ── db/functions/forbid_self_approval.sql ──
-- db/functions/forbid_self_approval.sql
-- APR-2:【四眼原则的唯一一份定义】—— 谁不许批这一份单据。
--
-- 【为什么是一支函数,而不是五处 IF】Tim 的裁定(APR-0 Q6)是"自批统一拒,
-- 在每一条【今天存在】的链和每一条【将来加进来】的链上"。一条写成五遍的规矩,
-- 第六条链一定会漏掉它 —— 而漏掉的形状是【什么都不发生】,没有任何东西变红。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【"自己"是两个人,不是一个】★★(Tim 的 Q8 裁定,2026-09-22)
-- ════════════════════════════════════════════════════════════════════════════
--   ① 提单的人(raiser)—— created_by / submitted_by。老的那条规矩只管这一个。
--   ② 单据【说的是谁】(subject)—— 请假是请假的那位员工,报销是报销的那位,
--      绩效是被评的那位。★ 这一条此前【全库都没有】,而它是真的会咬人的那一条:
--      `approve_review` 只拒 submitted_by,于是【别人提交、主角自己批准】这条路
--      一直是通的 —— 而 approve_review 会写 employees.monthly_salary 与一行
--      employment_history 调薪记录。**一个人可以批准自己的加薪。**
--      线上三个持 module.hr.edit 的人【全部】是在册员工,所以它不是理论上的。
--
-- 【两条判据的先后是确定的,而且要说出来】raiser 先判。两条同时成立时,
-- 屏幕上出现的是 |raiser —— 因为那是更早、更窄、也更好懂的那一句
-- ("你自己提的单")。不留给实现去碰运气。
--
-- 【NULL 一律不匹配,这是刻意的】p_raiser_user 为空(老数据没有 created_by)、
-- 或者调用者根本不是在册员工(current_user_employee() 为 NULL)时,
-- 这一条【放行】。理由:一个 NULL 不是一个"人",拿两个 NULL 相等去拒绝
-- 会把"我不知道"变成"就是你" —— 那正是本仓库反复付账的那个形状。
-- ★ 代价照直说:created_by 为空的历史单据,raiser 那一条对它们【不生效】。
--
-- 【为什么它 RAISE,而不是返回 boolean】AGENTS.md:一支 void 函数的"沉默"
-- 与"成功"是同一个字节,所以它的 NULL 永远有主 —— 返回值会被 COALESCE 掉,
-- 而一次被 COALESCE 掉的拒绝就是一次放行。
--
-- 【为什么它【不是】SECURITY DEFINER】它自己不读任何受 RLS 约束的东西:
-- auth.uid() 是一个 GUC,current_user_employee() 自己就是 DEFINER。
-- 不声明 DEFINER,gate 的 B2(DEFINER 且无调用者检查)就与它无关 ——
-- 少一个需要在 zzz_function_grants 里解释的对象。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★ APR-ROUTE-1(2026-09-23):一个例外,以及"自己"从此按【人】认 ★★
-- ════════════════════════════════════════════════════════════════════════════
--   ① 【唯一的例外】(Tim 的 R2 · Q3):二级审批角色的持有人可以决定【他自己的】
--      报销单与医疗申报 —— 判据住在 self_approval_exception,不住在这里。
--      那一次决定照常落留痕,并被 record_approval_decision 标成 self_decided。
--      ☞ 所以本函数多了第三个参数 p_subject_type,而它【没有默认值】:
--        下一条接进来的链必须说出自己是什么类型,才调得动这支函数 ——
--        一个默认值会让它在不知不觉中落进(或落出)例外。
--   ② 【"自己"的判据搬去了 self_leg】(R3):同一个人的另一个账号也是"自己"。
--      两条腿的先后、NULL 不匹配,与上面写的一字不差。
--   ③ 【两条腿什么时候一起被豁免】例外要求"主角就是我",所以
--      "raiser 腿成立 且 例外成立"只可能是"我提的、说的也是我"。
--      一张我替别人提的单,例外不成立,|raiser 照拒。
--   ★ 它【仍然不是】SECURITY DEFINER —— 它读的三样东西(self_leg、
--     self_approval_exception、finance_settings)在调用它的 DEFINER 决定函数里
--     以属主身份执行;fixture 203 的 P 臂钉着这一条。
--
-- NOTE: introduced by db/migrations/2026-09-22-apr2-self-approval-and-the-approver-that-nobody-is.sql.

CREATE OR REPLACE FUNCTION public.forbid_self_approval(p_raiser_user uuid, p_subject_employee uuid, p_subject_type text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- ★ SYSTEM-MAP-2(2026-10-27):判据搬进 self_approval_allows(两条腿 + R2 那个例外,一字未改),
    --   本函数只负责【拒】;待办(waiting_decisions)问的是同一支,于是"谁不许批自己的"仍只有一份定义。
    IF self_approval_allows(p_raiser_user, p_subject_employee, p_subject_type, auth.uid()) THEN
        RETURN;
    END IF;

    RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN|%', self_leg(p_raiser_user, p_subject_employee, auth.uid());
END;
$function$;

-- ── db/functions/decision_gate_code.sql ──
-- db/functions/decision_gate_code.sql
-- SYSTEM-MAP-2(2026-10-27):不走审批引擎的那几种决定,各自的【权限门】—— 待办与提醒按它问"我批得了吗"。
--   链上的(采购单 · 报销 · 十种 CFO 级申请)不在这里:它们的门住在 approval_chain_gates,人住在 approval_deciders;
--   调薪与考核按人路由(pay_decision_code / review_approval_code),也不在这里。
--   这里每一个码与那一支决定函数开头的 require_permission 逐字相同;两边不许分开 ——
--   ★ 钉住它的是 fixture 302(每一种 × 七个线上角色:列在待办上 ⇔ 那一支真的决定函数接受),不是这段注释。
--   supplier 的码取自 supplier_status_moves()(pending_review → approved 那一行),不在这里另写。
-- 未知的种类返回 NULL(has_permission(NULL) 为假 —— 不认识的门关着)。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.decision_gate_code(p_item_type text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_item_type
        WHEN 'leave_request'      THEN 'action.decide_hr_requests'   -- decide_leave_request
        WHEN 'medical_claim'      THEN 'action.decide_hr_requests'   -- decide_medical_claim
        WHEN 'overtime_batch'     THEN 'action.overtime_approve'     -- decide_overtime_batch
        WHEN 'ncr'                THEN 'action.ncr_decide'           -- decide_ncr
        WHEN 'work_order'         THEN 'action.wo_release'           -- release_work_order
        WHEN 'blending_plan'      THEN 'action.wo_release'           -- release_blending_plan
        WHEN 'capture_draft'      THEN 'action.confirm_capture'      -- confirm_capture_draft / reject_capture_draft
        WHEN 'portal_certificate' THEN 'module.suppliers.edit'       -- portal_submission_accept / portal_submission_reject
        WHEN 'payment_to_pay'     THEN 'module.finance.edit'         -- pay_payment_request
        WHEN 'supplier'           THEN (SELECT m.required_code FROM supplier_status_moves() m
                                         WHERE m.from_status = 'pending_review' AND m.to_status = 'approved')
    END;
$function$;

COMMENT ON FUNCTION public.decision_gate_code(text) IS
'SYSTEM-MAP-2:不走审批引擎的决定各自的权限门(请假 · 医疗 · 加班 · 不合格 · 工单 / 配料放行 · 采集草稿 · 门户证书 · 付款 · 供应商批准)。每个码与那一支决定函数开头的 require_permission 逐字相同,由 fixture 302 钉住(列在待办上 ⇔ 真的决定函数接受)。供应商的码取自 supplier_status_moves()。未知种类 → NULL(门关着)。';

-- ── db/functions/certificate_expiry_status.sql ──
-- db/functions/certificate_expiry_status.sql
-- SYSTEM-MAP-2(Tim 2026-10-27 SYSTEM-MAP-1 Q3 → 64d-2):一张资质证书【现在】是什么状态 —— 一份判据,三个读者:
--   提醒页 qualification_expiring(供应商证书)与 company_licence_expiring(公司执照)两支(db/views/operations_arms_all.sql)
--   与供应商证书总览的状态列(db/views/supplier_certificate_status.sql)。
--   not_tracked  证书种类的 disposition = 'ignore'(提醒从来不响)
--   no_expiry    没有有效期
--   expired      有效期 < 今天 —— 与收货闸 supplier_receiving_blocked 同一个比较(当天到期的那一天仍然有效)
--   expiring     有效期 ≤ 今天 + 那一种的 warn_lead_days
--   valid        其余
--   提醒那两支 = expired 或 expiring(与原来那句 disposition <> 'ignore' AND valid_until <= CURRENT_DATE + warn_lead_days 逐行等价)。
-- STABLE:它读 CURRENT_DATE。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.certificate_expiry_status(p_valid_until date, p_disposition text, p_warn_lead_days integer)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
        WHEN p_disposition = 'ignore' THEN 'not_tracked'
        WHEN p_valid_until IS NULL THEN 'no_expiry'
        WHEN p_valid_until < CURRENT_DATE THEN 'expired'
        WHEN p_valid_until <= CURRENT_DATE + p_warn_lead_days THEN 'expiring'
        ELSE 'valid'
    END;
$function$;

COMMENT ON FUNCTION public.certificate_expiry_status(date, text, integer) IS
'SYSTEM-MAP-2:证书现在的状态 —— not_tracked(种类 ignore)· no_expiry · expired(< 今天,与收货闸同一个比较)· expiring(≤ 今天 + warn_lead_days)· valid。三个读者:提醒页两支(供应商证书 · 公司执照)与供应商证书总览的状态列。';

-- ── db/functions/decision_arms.sql ──
-- db/functions/decision_arms.sql
-- SYSTEM-MAP-2(Tim 2026-10-27 Q3):提醒页的哪一支是一种【审批】,是哪一种(waiting_decisions 的 item_type)。
--   是审批的那几支,operations_now 只留读者此刻批得了的那几行(与待办同一支 waiting_decisions);别的支(到期、逾期、低库存……)
--   照旧按读码给全公司看(Tim 2.4 (11))。
--   第二列 parent_keyed:那一支的 item_id 是单据所在的那一页的主体(工资期 · 收货批 · 发票 · 销售单 · 员工 · GST 期),
--   不是申请本身 —— 那几支按 (parent_id, 标签) 对上 waiting_decisions 的那一行。门户证书那一支的 item_id 是那家供应商
--   (提交住在供应商档案页上),标签是证书号(没有就是种类码)。
--   ★ 不在这里:stocktake_open(Tim Q4 a,盘点留在提醒页)· ncr_open(那一支说的是"一批被扣着",一个例外,不是一次待办;
--     不合格报告的决定在待办上)· shipping_release_ready(已放行、等仓库发货,不是一个审批)。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.decision_arms()
 RETURNS TABLE(arm text, decision_type text, parent_keyed boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT v.a, v.d, v.p
      FROM (VALUES
        ('leave_pending',                   'leave_request',          false),
        ('claim_pending',                   'medical_claim',          false),
        ('review_submitted',                'performance_review',     false),
        ('capture_draft_pending',           'capture_draft',          false),
        ('payment_request_pending',         'payment_request',        false),
        ('supplier_pending_approval',       'supplier',               false),
        ('payroll_request_pending',         'payroll_request',        true),
        ('receipt_price_request_pending',   'receipt_price_request',  true),
        ('invoice_request_pending',         'invoice_request',        true),
        ('shipping_release_pending',        'shipping_release',       true),
        ('journal_request_pending',         'journal_request',        false),
        ('warehouse_request_pending',       'warehouse_request',      false),
        ('terms_request_pending',           'terms_request',          false),
        ('asset_disposal_pending',          'asset_disposal_request', false),
        ('salary_change_pending',           'salary_change_request',  true),
        ('gst_filing_pending',              'gst_filing_request',     true),
        ('expense_claim_pending',           'expense_claim',          false),
        ('purchase_order_approval_pending', 'purchase_order',         false),
        ('overtime_batch_pending',          'overtime_batch',         false),
        ('work_order_release_pending',      'work_order',             false),
        ('blending_plan_release_pending',   'blending_plan',          false),
        ('portal_certificate_pending',      'portal_certificate',     true)
      ) v(a, d, p)
$function$;

COMMENT ON FUNCTION public.decision_arms() IS
'SYSTEM-MAP-2(Tim Q3):提醒页的审批支 → waiting_decisions 的种类(两个读者:operations_now · 提醒页);parent_keyed = 那一支的 item_id 是单据所在页的主体,按 (parent_id, 标签) 对行。不在表里的支(盘点 · ncr_open · 已放行等发货 · 一切例外支)不按读者逐行过滤。';

-- ── db/functions/waiting_decisions.sql ──
-- db/functions/waiting_decisions.sql
-- SYSTEM-MAP-2(Tim 2026-10-26 裁定 2.4 (9) · 2026-10-27 Q1–Q7):★【在等【我】决定的单据】—— 一行一张,只列我此刻批得了的★
--
-- 【一份判据,三个读者】待办页(waiting_for_me)· 首页的待办数(waiting_for_me_count)· 提醒页的审批支(operations_now 按行过滤)。
--
-- 【"批得了"不在这里另写一遍】(SYSTEM-MAP-2 grilling,Tim 接受):
--   · 在途的是哪些:approval_pending_documents()(APR-3 那一份,采购单 · 报销 · 十种 CFO 级申请 · 调薪 · 加班);
--   · 链上的单据谁批得了:approval_deciders()(APR-ROUTE-1 R4:有资格的级别 ∩ 链的模块门 ∩ 不是自己或 R2 例外)——
--     CFO 级、1,000 的分档、四眼与自批例外全在那里,本函数只拿【我】去问它;
--   · 调薪:salary_change_deciders();
--   · 其余几种(请假 · 医疗 · 考核批准 · 加班 · 不合格 · 工单 / 配料放行 · 供应商批准 · 采集草稿 · 门户证书 · 付款):
--     门 = decision_gate_code() / review_approval_code(),四眼 = self_approval_allows()(与 forbid_self_approval 同一支)。
--   ★ 钉住"列在这里 ⇔ 那一支真的决定函数接受"的是 fixture 302(24 种 × 七个线上角色,逐格回滚),不是这段注释。
--
-- 【审批关着的时候】与各决定函数同形:blocks_disable 的链(决定函数按名拒 APPROVALS_NOT_ENABLED)谁都批不了 → 不列;
--   报销单不分档,只问链的门码与四眼(decide_expense_claim_items 关着时就是这么判的)。
-- 【分不了档的报销单(本位币金额 NULL)】决定函数按名拒(FX_RATE_MISSING)→ 谁都批不了 → 不列。
-- 【盘点不在这里】Tim 2026-10-27 Q4 (a):open 是"正在点",它留在提醒页。
-- 【付款(payment_to_pay)】一张已批准、等付款的付款申请 —— 不是一个决定,是在等财务付(Tim Q4 (c));门 = pay_payment_request 的码,
--   再加引擎里的 guard_payment_sod(建这家供应商的人不付它的款,SOD_PAYEE_AND_PAY)—— fixture 295 R 臂量出来的。
--
-- 列:item_type 种类 · item_id 单据 · parent_id 它住的那一页的主体(工资期 · 收货批 · 发票 · 销售单 · 资产 · GST 期 · 员工 ·
--   合同或公式 · 供应商;冲销凭证申请是它要冲的那张分录)· doc_kind 只在条款申请上说是 contract 还是 formula · code 单据号或标签 · subject 说的是谁 / 什么 ·
--   raised_by 提的人(trail_actor 的形状:读者没有 module.hr.view 时是 restricted,不是一个名字)· waiting_since 从什么时候起在等。
-- 【为什么 SECURITY DEFINER】它横跨十几个模块的表,而每一行是否列出由上面的判据按【调用者】(auth.uid())裁;
--   EXECUTE 给 authenticated(operations_now 是属主视图,它调用的函数按读者判 EXECUTE)。没有会话 → 零行。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.waiting_decisions()
 RETURNS TABLE(item_type text, item_id uuid, parent_id uuid, doc_kind text, code text, subject text, raised_by jsonb, waiting_since timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH s AS (
        SELECT fs.approvals_enabled AS appr_on, fs.approval_level1_role_code AS l1,
               fs.approval_level2_role_code AS l2, fs.approval_threshold_base AS thr
          FROM finance_settings fs LIMIT 1
    ),
    me AS (SELECT auth.uid() AS uid),
    pend AS (
        SELECT d.subject_type, d.doc_id, d.raiser_user_id, d.subject_employee_id, d.blocks_disable,
               CASE WHEN d.fixed_level IS NOT NULL THEN d.fixed_level
                    WHEN d.amount_base IS NULL OR s.thr IS NULL THEN NULL::smallint
                    ELSE approval_level_at(d.amount_base, s.thr) END AS lvl
          FROM approval_pending_documents() d CROSS JOIN s
    ),
    -- 链上的单据:approval_chain_gates 里有它的那几种(驳回那一支的门窄一格,不算"批得了")
    chain_ok AS (
        SELECT p.subject_type, p.doc_id
          FROM pend p CROSS JOIN s CROSS JOIN me
         WHERE me.uid IS NOT NULL
           AND EXISTS (SELECT 1 FROM approval_chain_gates() g WHERE g.subject_type = p.subject_type)
           AND CASE
                 WHEN s.appr_on THEN
                      p.lvl IS NOT NULL
                  AND EXISTS (SELECT 1
                                FROM approval_chain_gates() g
                               CROSS JOIN LATERAL approval_deciders(g.subject_type, g.action_function, g.level,
                                                                    p.raiser_user_id, p.subject_employee_id, s.l1, s.l2) x
                               WHERE g.subject_type = p.subject_type AND g.level = p.lvl
                                 AND g.action_function NOT LIKE 'reject\_%' AND x.user_id = me.uid)
                 WHEN p.blocks_disable THEN false
                 ELSE NOT EXISTS (SELECT 1
                                    FROM approval_chain_gates() g CROSS JOIN LATERAL unnest(g.gate_permissions) c(code)
                                   WHERE g.subject_type = p.subject_type AND g.action_function NOT LIKE 'reject\_%'
                                     AND NOT has_permission(c.code))
                      AND self_approval_allows(p.raiser_user_id, p.subject_employee_id, p.subject_type, me.uid)
               END
        UNION ALL
        SELECT p.subject_type, p.doc_id
          FROM pend p CROSS JOIN me
         WHERE p.subject_type = 'salary_change_request' AND me.uid IS NOT NULL
           AND EXISTS (SELECT 1 FROM salary_change_deciders(p.raiser_user_id, p.subject_employee_id) x WHERE x.user_id = me.uid)
        UNION ALL
        SELECT p.subject_type, p.doc_id
          FROM pend p CROSS JOIN me
         WHERE p.subject_type = 'overtime_batch' AND me.uid IS NOT NULL
           AND has_permission(decision_gate_code('overtime_batch'))
           AND self_approval_allows(p.raiser_user_id, NULL::uuid, 'overtime_batch', me.uid)
           AND NOT EXISTS (SELECT 1 FROM overtime_lines l WHERE l.batch_id = p.doc_id
                              AND NOT self_approval_allows(p.raiser_user_id, l.employee_id, 'overtime_batch', me.uid))
    ),
    ok AS MATERIALIZED (SELECT DISTINCT subject_type, doc_id FROM chain_ok)
    SELECT 'purchase_order'::text, po.id, NULL::uuid, NULL::text, po.code, sp.legal_name,
           trail_actor('prelog', po.created_by, NULL::uuid),
           COALESCE((SELECT max(l.decided_at) FROM approval_log l
                      WHERE l.subject_type = 'purchase_order' AND l.subject_id = po.id
                        AND l.decision IN ('submitted', 'approval_voided')), po.created_at)
      FROM purchase_orders po JOIN ok ON ok.subject_type = 'purchase_order' AND ok.doc_id = po.id
      LEFT JOIN suppliers sp ON sp.id = po.supplier_id
    UNION ALL
    SELECT 'expense_claim', c.id, NULL, NULL, c.code, e.legal_name,
           trail_actor('prelog', c.created_by, NULL::uuid), COALESCE(c.submitted_at, c.created_at)
      FROM expense_claims c JOIN ok ON ok.subject_type = 'expense_claim' AND ok.doc_id = c.id
      LEFT JOIN employees e ON e.id = c.employee_id
    UNION ALL
    SELECT 'payment_request', r.id, NULL, NULL, r.code, NULL,
           trail_actor('prelog', r.created_by, NULL::uuid), r.created_at
      FROM payment_requests r JOIN ok ON ok.subject_type = 'payment_request' AND ok.doc_id = r.id
    UNION ALL
    SELECT 'payroll_request', q.id, q.payroll_period_id, NULL, q.label, pp.code,
           trail_actor('prelog', q.created_by, NULL::uuid), q.created_at
      FROM payroll_requests q JOIN ok ON ok.subject_type = 'payroll_request' AND ok.doc_id = q.id
      JOIN payroll_periods pp ON pp.id = q.payroll_period_id
    UNION ALL
    SELECT 'receipt_price_request', rq.id, rq.inbound_batch_id, NULL, rq.label, ib.code,
           trail_actor('prelog', rq.created_by, NULL::uuid), rq.created_at
      FROM receipt_price_requests rq JOIN ok ON ok.subject_type = 'receipt_price_request' AND ok.doc_id = rq.id
      JOIN inbound_batches ib ON ib.id = rq.inbound_batch_id
    UNION ALL
    SELECT 'invoice_request', iq.id, iq.invoice_id, NULL, iq.label, inv.code,
           trail_actor('prelog', iq.created_by, NULL::uuid), iq.created_at
      FROM invoice_requests iq JOIN ok ON ok.subject_type = 'invoice_request' AND ok.doc_id = iq.id
      JOIN invoices inv ON inv.id = iq.invoice_id
    UNION ALL
    SELECT 'shipping_release', sr.id, sr.sales_order_id, NULL, sr.label, so.code,
           trail_actor('prelog', sr.created_by, NULL::uuid), sr.created_at
      FROM shipping_releases sr JOIN ok ON ok.subject_type = 'shipping_release' AND ok.doc_id = sr.id
      JOIN sales_orders so ON so.id = sr.sales_order_id
    UNION ALL
    SELECT 'journal_request', jq.id, jq.target_entry_id, NULL, jq.label, NULL,
           trail_actor('prelog', jq.created_by, NULL::uuid), jq.created_at
      FROM journal_requests jq JOIN ok ON ok.subject_type = 'journal_request' AND ok.doc_id = jq.id
    UNION ALL
    SELECT 'warehouse_request', wq.id, wq.inbound_batch_id, NULL, wq.label, NULL,
           trail_actor('prelog', wq.created_by, NULL::uuid), wq.created_at
      FROM warehouse_requests wq JOIN ok ON ok.subject_type = 'warehouse_request' AND ok.doc_id = wq.id
    UNION ALL
    SELECT 'terms_request', tq.id, COALESCE(tq.contract_id, tq.formula_id),
           CASE WHEN tq.contract_id IS NOT NULL THEN 'contract' WHEN tq.formula_id IS NOT NULL THEN 'formula' END,
           tq.label, NULL, trail_actor('prelog', tq.created_by, NULL::uuid), tq.created_at
      FROM terms_requests tq JOIN ok ON ok.subject_type = 'terms_request' AND ok.doc_id = tq.id
    UNION ALL
    SELECT 'asset_disposal_request', dq.id, dq.asset_id, NULL, dq.label, NULL,
           trail_actor('prelog', dq.created_by, NULL::uuid), dq.created_at
      FROM asset_disposal_requests dq JOIN ok ON ok.subject_type = 'asset_disposal_request' AND ok.doc_id = dq.id
    UNION ALL
    SELECT 'gst_filing_request', gq.id, gq.period_id, NULL, gq.label, NULL,
           trail_actor('prelog', gq.created_by, NULL::uuid), gq.created_at
      FROM gst_filing_requests gq JOIN ok ON ok.subject_type = 'gst_filing_request' AND ok.doc_id = gq.id
    UNION ALL
    SELECT 'salary_change_request', sq.id, sq.employee_id, NULL, sq.label, e.legal_name,
           trail_actor('prelog', sq.created_by, NULL::uuid), sq.created_at
      FROM salary_change_requests sq JOIN ok ON ok.subject_type = 'salary_change_request' AND ok.doc_id = sq.id
      LEFT JOIN employees e ON e.id = sq.employee_id
    UNION ALL
    SELECT 'overtime_batch', ob.id, NULL, NULL, ob.label, NULL,
           trail_actor('prelog', ob.submitted_by, NULL::uuid), COALESCE(ob.submitted_at, ob.created_at)
      FROM overtime_batches ob JOIN ok ON ok.subject_type = 'overtime_batch' AND ok.doc_id = ob.id
    UNION ALL
    -- 考核批准(approve_review):门 = review_approval_code(提交人, 员工),四眼两条腿
    SELECT 'performance_review', r.id, NULL, NULL, e.code, e.legal_name,
           trail_actor('prelog', r.submitted_by, NULL::uuid), COALESCE(r.submitted_at, r.created_at)
      FROM performance_reviews r CROSS JOIN me
      JOIN employees e ON e.id = r.employee_id
     WHERE r.status = 'submitted' AND me.uid IS NOT NULL
       AND has_permission(review_approval_code(r.submitted_by, r.employee_id))
       AND self_approval_allows(r.submitted_by, r.employee_id, 'performance_review', me.uid)
    UNION ALL
    SELECT 'leave_request', lr.id, NULL, NULL, lr.code, e.legal_name,
           trail_actor('prelog', lr.created_by, NULL::uuid), lr.created_at
      FROM leave_requests lr CROSS JOIN me
      LEFT JOIN employees e ON e.id = lr.employee_id
     WHERE lr.status = 'pending' AND lr.deleted_at IS NULL AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('leave_request'))
       AND self_approval_allows(lr.created_by, lr.employee_id, 'leave_request', me.uid)
    UNION ALL
    SELECT 'medical_claim', mc.id, NULL, NULL, mc.code, e.legal_name,
           trail_actor('prelog', mc.created_by, NULL::uuid), mc.created_at
      FROM medical_claims mc CROSS JOIN me
      LEFT JOIN employees e ON e.id = mc.employee_id
     WHERE mc.status = 'submitted' AND mc.deleted_at IS NULL AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('medical_claim'))
       AND self_approval_allows(mc.created_by, mc.employee_id, 'medical_claim', me.uid)
    UNION ALL
    SELECT 'ncr', n.id, NULL, NULL, n.code, NULL,
           trail_actor('prelog', n.opened_by, NULL::uuid), n.opened_at
      FROM nonconformance_reports n CROSS JOIN me
     WHERE n.status = 'open' AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('ncr'))
       AND self_approval_allows(n.opened_by, NULL::uuid, 'ncr', me.uid)
    UNION ALL
    SELECT 'work_order', wo.id, NULL, NULL, wo.code, NULL,
           trail_actor('prelog', wo.created_by, NULL::uuid), wo.created_at
      FROM work_orders wo CROSS JOIN me
     WHERE wo.status = 'draft' AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('work_order'))
       AND self_approval_allows(wo.created_by, NULL::uuid, 'work_order', me.uid)
    UNION ALL
    SELECT 'blending_plan', bp.id, NULL, NULL, bp.code, NULL,
           trail_actor('prelog', bp.created_by, NULL::uuid), bp.created_at
      FROM blending_plans bp CROSS JOIN me
     WHERE bp.status = 'draft' AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('blending_plan'))
       AND self_approval_allows(bp.created_by, NULL::uuid, 'blending_plan', me.uid)
    UNION ALL
    -- 供应商批准:等的起点 = 最近一次进入 pending_review 的那一刻(supplier_status_history)
    SELECT 'supplier', sp.id, NULL, NULL, sp.code, sp.legal_name,
           trail_actor('prelog', COALESCE(h.changed_by, sp.created_by), NULL::uuid), COALESCE(h.changed_at, sp.created_at)
      FROM suppliers sp CROSS JOIN me
      LEFT JOIN LATERAL (SELECT sh.changed_at, sh.changed_by FROM supplier_status_history sh
                          WHERE sh.supplier_id = sp.id AND sh.to_status = 'pending_review'
                          ORDER BY sh.changed_at DESC LIMIT 1) h ON true
     WHERE sp.status = 'pending_review' AND sp.deleted_at IS NULL AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('supplier'))
       AND self_approval_allows(sp.created_by, NULL::uuid, 'supplier', me.uid)
    UNION ALL
    SELECT 'capture_draft', cd.id, NULL, NULL, COALESCE(dv.code, cd.data_class), COALESCE(dv.name, cd.data_class),
           trail_actor('prelog', ib.entered_by, NULL::uuid), cd.created_at
      FROM capture_drafts cd CROSS JOIN me
      LEFT JOIN devices dv ON dv.id = cd.device_id
      LEFT JOIN ingest_inbox ib ON ib.id = cd.inbox_id
     WHERE cd.status = 'pending' AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('capture_draft'))
    UNION ALL
    SELECT 'portal_certificate', ps.id, ps.supplier_id, NULL, COALESCE(ps.cert_no, ps.cert_type_code), sp.legal_name,
           trail_actor('prelog', ps.user_id, NULL::uuid), COALESCE(ps.submitted_at, ps.created_at)
      FROM portal_certificate_submissions ps CROSS JOIN me
      JOIN suppliers sp ON sp.id = ps.supplier_id
     WHERE ps.status = 'submitted' AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('portal_certificate'))
    UNION ALL
    SELECT 'payment_to_pay', r.id, NULL, NULL, r.code, NULL,
           trail_actor('prelog', r.created_by, NULL::uuid), COALESCE(r.decided_at, r.created_at)
      FROM payment_requests r CROSS JOIN me
     WHERE r.status = 'approved' AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('payment_to_pay'))
       -- guard_payment_sod(引擎里照跑):付给供应商的出款,付款人不能是建这家供应商的人 —— 同一对判据
       --   (sod_supplier_creator + self_leg,assert_segregated 的那一句);冲销付款不受它管(payment_reversal_ctx)。
       AND NOT (r.kind = 'payment_out' AND r.counterparty_type = 'supplier'
                AND EXISTS (SELECT 1 FROM unnest(sod_supplier_creator(r.supplier_id)) a(first_actor)
                             WHERE self_leg(a.first_actor, NULL::uuid, me.uid) <> 'none'))
$function$;

COMMENT ON FUNCTION public.waiting_decisions() IS
'SYSTEM-MAP-2:在等【调用者】决定的单据,一行一张,只列他此刻批得了的。在途 = approval_pending_documents();链上的谁批得了 = approval_deciders()(CFO 级 · 1,000 分档 · 四眼 · R2 例外全在那里);调薪 = salary_change_deciders();其余几种 = decision_gate_code() / review_approval_code() + self_approval_allows()。三个读者:waiting_for_me(待办页)· waiting_for_me_count(首页)· operations_now(提醒页的审批支按行过滤)。盘点不在这里(Tim Q4 a)。已批准等付款的付款申请是 payment_to_pay(Q4 c)。fixture 302 钉住"列出 ⇔ 真的决定函数接受"。';

-- ── db/functions/waiting_mine.sql ──
-- db/functions/waiting_mine.sql
-- SYSTEM-MAP-2(Tim 2026-10-26 裁定 2.4 (9),grilling 接受):在等【我自己】动手的、不是审批的那几件 ——
--   task          我的任务:我是主人,或我是在册的参与者(task_participants,removed_at 为空);todo / in_progress,没删。
--                 ★ 不是"我看得见的任务":team 任务对每一个持 module.tasks.view 的人都看得见,那不叫"在等我"。
--                 门与任务页同一支:can_view_task()(持 module.tasks.view 且这张任务对我可见)。
--   review_write  一份考核在 draft,而我是考核人(reviewer_employee_id = 我)—— /my-reviews 那一格"在我桌上"。
--   self_review   一份考核在 self_review,而被考核的人是我 —— /me 上的自评(save_self_assessment 的门:员工 = 我)。
--   考核的第三条腿(submitted → 批准)是一个审批,住在 waiting_decisions。
-- 列与 waiting_decisions 同形,多一列 due_date(任务的到期日;别的为空)。
-- 【为什么 SECURITY DEFINER】考核表对被考核的人只放 approved 之后的行;"我"由 current_user_employee() 按调用者裁。没有会话 → 零行。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.waiting_mine()
 RETURNS TABLE(item_type text, item_id uuid, parent_id uuid, doc_kind text, code text, subject text, raised_by jsonb, waiting_since timestamp with time zone, due_date date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH me AS (SELECT current_user_employee() AS emp)
    SELECT 'task'::text, t.id, NULL::uuid, t.task_type, t.code, t.title,
           trail_actor('prelog', t.created_by, NULL::uuid), t.created_at, t.due_date
      FROM tasks t CROSS JOIN me
     WHERE me.emp IS NOT NULL AND t.deleted_at IS NULL AND t.status IN ('todo', 'in_progress')
       AND (t.owner_id = me.emp
            OR EXISTS (SELECT 1 FROM task_participants tp
                        WHERE tp.task_id = t.id AND tp.employee_id = me.emp AND tp.removed_at IS NULL))
       AND can_view_task(t.id)
    UNION ALL
    SELECT 'review_write', r.id, NULL, NULL, e.code, e.legal_name,
           trail_actor('prelog', r.created_by, NULL::uuid), r.created_at, NULL::date
      FROM performance_reviews r CROSS JOIN me
      JOIN employees e ON e.id = r.employee_id
     WHERE me.emp IS NOT NULL AND r.status = 'draft' AND r.reviewer_employee_id = me.emp
    UNION ALL
    SELECT 'self_review', r.id, NULL, NULL, e.code, rv.legal_name,
           trail_actor('prelog', r.created_by, NULL::uuid), COALESCE(r.updated_at, r.created_at), NULL::date
      FROM performance_reviews r CROSS JOIN me
      JOIN employees e ON e.id = r.employee_id
      LEFT JOIN employees rv ON rv.id = r.reviewer_employee_id
     WHERE me.emp IS NOT NULL AND r.status = 'self_review' AND r.employee_id = me.emp
$function$;

COMMENT ON FUNCTION public.waiting_mine() IS
'SYSTEM-MAP-2:在等调用者自己动手、而不是审批的事 —— 我的任务(主人或在册参与者,todo / in_progress,can_view_task)· 我是考核人的 draft 考核 · 我是被考核人的 self_review 考核。考核的批准那一条腿在 waiting_decisions。没有会话 → 零行。';

-- ── db/functions/waiting_for_me.sql ──
-- db/functions/waiting_for_me.sql
-- SYSTEM-MAP-2(Tim 2026-10-26 裁定 2.4 (9) · (10)):★【工作台 › 待办】的唯一一份数据 —— 在等【读者】动手的每一件事,一张清单★
--   decision      waiting_decisions():我批得了的每一种审批,以及已批准、等我付的付款申请
--   mine          waiting_mine():我的任务 · 我要写的考核 · 我要做的自评
--   notification  我没读过的通知(按读者自己的读策略:notifications 的 RLS 与 notification_reads 的 select own —— 本函数是
--                 SECURITY INVOKER,所以"谁看得见哪条通知"不在这里另写一遍)
-- 两个读者:/workbench(待办页)与首页那一个数(waiting_for_me_count)—— 规矩只有这一份(Tim 2.4 (10))。
-- 提醒页的审批支读的是 waiting_decisions(经 operations_now),与本函数的 decision 那一段是同一支。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.waiting_for_me()
 RETURNS TABLE(kind text, item_type text, item_id uuid, parent_id uuid, doc_kind text, code text, subject text, raised_by jsonb, waiting_since timestamp with time zone, due_date date)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT 'decision'::text, d.item_type, d.item_id, d.parent_id, d.doc_kind, d.code, d.subject, d.raised_by, d.waiting_since, NULL::date
      FROM waiting_decisions() d
    UNION ALL
    SELECT 'mine', m.item_type, m.item_id, m.parent_id, m.doc_kind, m.code, m.subject, m.raised_by, m.waiting_since, m.due_date
      FROM waiting_mine() m
    UNION ALL
    SELECT 'notification', 'notification', n.id, n.subject_id, n.subject_type, n.subject_code, n.event_type,
           jsonb_build_object('state', 'system'), n.occurred_at, NULL::date
      FROM notifications n
     WHERE auth.uid() IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM notification_reads r WHERE r.notification_id = n.id AND r.user_id = auth.uid())
$function$;

COMMENT ON FUNCTION public.waiting_for_me() IS
'SYSTEM-MAP-2:工作台 › 待办的唯一一份数据 —— 我批得了的审批与等我付的付款(waiting_decisions)· 我的任务与考核(waiting_mine)· 我没读过的通知(SECURITY INVOKER:通知按读者自己的 RLS 读)。两个读者:/workbench 与首页的待办数(waiting_for_me_count)。';

-- ── db/functions/waiting_for_me_count.sql ──
-- db/functions/waiting_for_me_count.sql
-- SYSTEM-MAP-2(Tim 2026-10-26 裁定 2.4 (10)):首页唯一新增的那个数 —— waiting_for_me() 的行数。
--   不另数一遍:首页的数与待办页的行数是同一条查询,所以它们不可能各说各话。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.waiting_for_me_count()
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT count(*)::integer FROM waiting_for_me();
$function$;

COMMENT ON FUNCTION public.waiting_for_me_count() IS
'SYSTEM-MAP-2:首页的待办数 = waiting_for_me() 的行数(同一条查询,不另数)。';

-- ── db/functions/waiting_decision_reach.sql ──
-- db/functions/waiting_decision_reach.sql
-- SYSTEM-MAP-2(Tim 2026-10-27 Q3):提醒页上一支审批支对【这个读者】是不是"批得了的那一类"。
--   批不了的那一类 → 那一支进提醒页既有的「受限」组,带一句"由谁决定"(不消失,不显示 0)。
--   批得了的那一类 → 那一支只数他此刻批得了的那几张(operations_now 按 waiting_decisions 逐行过滤)。
-- 每一种的"那一类":
--   链上的(approval_chain_gates 里有它):有某一级的资格(approval_level_eligible)且持那一级的全部门码;
--     审批关着时只问门码(决定函数那时不按级要人)。
--   调薪:salary_change_deciders(NULL, NULL) 里有我 —— 也就是"一张与 CFO 无关的调薪"我批得了;
--   考核批准:持 review_approval_code(NULL, NULL);其余:持 decision_gate_code()。
--   decided_by:cfo_level(只有二级那一行的链)· tier(按金额分档的链)· pay_code(调薪与考核:CFO,CFO 是当事人时 cco)·
--     其余是那一种的权限码(decision_gate_code)—— 提醒页「受限」那一句由谁决定,读这一列,不在页面上再写一份。
--   ★ 再加一条:我此刻在 waiting_decisions 里有这一种的一行 —— 例如 CFO 是当事人时轮到 cco 批调薪,那一支就不能是「受限」。
-- 【为什么 SECURITY DEFINER】approval_level_eligible / salary_change_deciders 读账号目录,已从 authenticated 收回;本函数只答【调用者】自己。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.waiting_decision_reach()
 RETURNS TABLE(item_type text, can_decide boolean, decided_by text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH s AS (
        SELECT fs.approvals_enabled AS appr_on, fs.approval_level1_role_code AS l1, fs.approval_level2_role_code AS l2
          FROM finance_settings fs LIMIT 1
    ),
    me AS (SELECT auth.uid() AS uid),
    mine AS MATERIALIZED (SELECT DISTINCT w.item_type FROM waiting_decisions() w),
    chain AS (
        SELECT DISTINCT g.subject_type AS t FROM approval_chain_gates() g
    ),
    typical AS (
        SELECT c.t,
               -- 由谁决定(提醒页「受限」那一句):只有二级那一行的链 → cfo_level;按金额分档的 → tier
               CASE WHEN (SELECT bool_and(g.level = 2) FROM approval_chain_gates() g WHERE g.subject_type = c.t)
                    THEN 'cfo_level' ELSE 'tier' END AS by,
               me.uid IS NOT NULL AND EXISTS (
                   SELECT 1 FROM approval_chain_gates() g
                    WHERE g.subject_type = c.t AND g.action_function NOT LIKE 'reject\_%'
                      AND (NOT s.appr_on
                           OR EXISTS (SELECT 1 FROM approval_level_eligible(g.level, s.l1, s.l2) e WHERE e.user_id = me.uid))
                      AND NOT EXISTS (SELECT 1 FROM unnest(g.gate_permissions) x(code) WHERE NOT has_permission(x.code))) AS ok
          FROM chain c CROSS JOIN s CROSS JOIN me
        UNION ALL
        SELECT 'salary_change_request', 'pay_code',
               EXISTS (SELECT 1 FROM salary_change_deciders(NULL::uuid, NULL::uuid) x CROSS JOIN me WHERE x.user_id = me.uid)
        UNION ALL
        SELECT 'performance_review', 'pay_code', has_permission(review_approval_code(NULL::uuid, NULL::uuid))
        UNION ALL
        SELECT v.t, decision_gate_code(v.t), has_permission(decision_gate_code(v.t))
          FROM (VALUES ('overtime_batch'), ('leave_request'), ('medical_claim'), ('ncr'), ('work_order'), ('blending_plan'),
                       ('supplier'), ('capture_draft'), ('portal_certificate'), ('payment_to_pay')) v(t)
    )
    SELECT t.t, COALESCE(t.ok, false) OR EXISTS (SELECT 1 FROM mine m WHERE m.item_type = t.t), t.by
      FROM typical t
$function$;

COMMENT ON FUNCTION public.waiting_decision_reach() IS
'SYSTEM-MAP-2(Tim Q3):每一种审批对调用者是不是"批得了的那一类" —— 链:某一级的资格 ∩ 那一级的门码(审批关着只问门码);调薪:salary_change_deciders(NULL,NULL);考核:review_approval_code(NULL,NULL);其余:decision_gate_code();另加"此刻 waiting_decisions 里有我这一种的一行"。提醒页据此把批不了的审批支放进「受限」组。';

-- ── db/views/operations_arms_all.sql ──
-- db/views/operations_arms_all.sql
-- ★ SYSTEM-MAP-2(2026-10-27,Tim 2.4 (11) · Q3 · Q4 b):加六支审批支 —— expense_claim_pending(一般报销)· purchase_order_approval_pending
--   (采购单审批)· overtime_batch_pending(加班)· work_order_release_pending / blending_plan_release_pending(工单 / 配料计划放行)·
--   portal_certificate_pending(供应商门户交来、等人接收的证书)。读码是那一种决定的模块门;★ 读者看见哪几行不由读码定:
--   审批支在 operations_now 里按 waiting_decisions 逐行过滤(decision_arms() 说哪几支是审批)—— 与待办同一份判据。
--   qualification_expiring 与 company_licence_expiring 两支的判据改读 certificate_expiry_status()(逐行等价;供应商证书总览的状态列读同一支)。
-- ★ MES-8b-2(2026-10-17,MES-8 Step 0 Q20,Tim):operations_now 的【全部支】,不按读者过滤 —— 基视图,不给人读(REVOKE ALL)。
--   为什么拆出来:operations_now 在最后一句按【调用者】的码逐支裁决(has_permission 解析 auth.uid()),所以一支 SECURITY DEFINER 函数
--   读 operations_now 也只拿到【调用者】看得见的那几支 —— 一块只持 data.view_floor_board 的大屏读它是零行。floor_board() 要的是
--   【数】,不是那几行:它从这一张基视图按支计数,只吐计数(不吐 subject、item_code、名字或钱)。
--   支的定义因此【只有这一份】:operations_now = 本视图 + 那一句按读者的过滤,floor_board() = 本视图 + 按支计数。
--   ★ 加一支 = 改【本文件】· lib/reminders.ts · docs/dashboard-arm-inventory.md · messages(scripts/check-reminder-arms.mjs 读本文件)。
--   下面是 operations_now.sql 原来的抬头,随支的定义一起搬过来(原样)。
--
-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行
-- ★ MES-8b-1(2026-10-17,MES-8 Step 0 Q15,Tim):加一支,门 action.compliance_pack(冻包的人 —— 提醒是给能动手的人的)。
--   compliance_pack_not_frozen —— 从 system_start_date 那个月起,每一个【已关账】(月末 < locked_before)而没有一份在册合规包的月,一行。
--     item_id 空(一个月不是一行记录);item_code = YYYY-MM;subject = 'Compliance pack';item_date = 那个月的月末。冻了就消失。
--     月结页同一件事只是一行警告(compliance_pack_month_status),【从不挡关账】(MES-0 Q48 的形状)。
-- ★ MES-8a(2026-10-16,MES-8 Step 0 Q27,Tim):加一支,门 action.supplier_review(记评审的人 —— 提醒是给能动手的人的)。
--   supplier_review_due —— 一家批准过 / 在用的进货供应商,而它最近一次没被取代的评审的日子 + V23 的评审周期 ≤ 今天(doc_kind = due,
--     item_date = 那一天到期的日子),或一次评审都没有(doc_kind = never_reviewed,item_date = 建档那一天)。
--     ★【V23 的周期空着时这一支一行都不出】(Q27 —— V18 的先例:没有数,就没有提醒;不猜一个周期)。
--     item_id = 那家供应商;item_code = 供应商代码;subject = 它的名字(标签跟着单据走)。
-- ★ MES-7b-1(2026-10-16,MES-7b Step 0 Q10 · Q11,Tim):加两支,门都是 module.safety.view,都读 incident_current_all(事故现在的值:
-- ★ MES-7b-2(2026-10-16,MES-7b Step 0 Q13 · Q14 · Q20,Tim):加两支,门都是 module.safety.view。
--   inspection_due —— 一张启用的巡检清单【有频率】(V18)而该巡了:还没巡过(doc_kind = never_run,item_date = 建清单那一天),或最近一次没被
--     更正过的巡检的日子 + 频率 ≤ 今天(doc_kind = due,item_date = 那一天到期的日子)。频率空着的清单不进来 —— 没有日子可数(V18 那一行在
--     待补的值页上)。判据住在 inspection_template_due_all(清单页读同一份)。item_id = 那张清单;item_code = 清单代号;subject = 清单名字。
--   inspection_finding_open —— 一条还没关闭的巡检发现。item_id = 那条发现;doc_kind = 它那一次巡检的 id(门牌指巡检页上那一条);
--     item_code = 巡检编号;subject = 那一项的字;item_date = 记下发现的那一天(首页数它开了几天;人选的到期日在巡检页上说)。
--     关掉它那张任务不关闭它(Q14)—— 只有记一次关闭才让它消失。
--   更正过的"要不要通报"说了算;一件更正成不用通报的事故两支都消失)。关闭【不】清掉它们 —— 法定的义务不因"关闭"而结束。
--   incident_nea_notify_due —— 一件要通报 NEA 的事故,还没有记下通报("立即":没有天数,只是挂着直到记下)。item_id = 那件事故;
--     item_code = 事故编号;subject = 种类的英文名;item_date = 事故日(新加坡日期)。
--   incident_report_due —— 一件要通报 NEA 的事故,还没有记下交了书面报告。item_date = 期限(事故日之后第 V19 个工作日);期限算不出来或
--     没有设定时退回事故日(item_date 在每一支上都不为空 —— 首页拿它算等了几天)。doc_kind 借来装期限的状态(computed · not_set ·
--     cannot_compute):只有 computed 时 item_date 才是期限 —— 门牌据此说"算不出来",不把事故日说成期限。
-- ★ MES-6b-2(2026-10-15,MES-6b Step 0 Q32 · Q38,Tim):加一支 coa_facts_changed —— 一张已签发的分析证书,而它那一批在签发之后多了一份
--   (没删的)化验、或开了一张不合格报告。证书【永远不会被自动作废】(Q32):这一格只把它摆到持 action.issue_coa 的人面前(签发与提作废申请
--   的是同一批人),由人决定要不要经 CFO 作废、重开一张。item_id = 那张证书;item_code = 证书号;subject = 批号 · 最早那一件新事的编号
--   (化验号或报告编号);item_date = 那件事的日子。证书作废之后它消失(重开的那一张从它自己的签发时刻重新算)。
-- ★ MES-6b-1(2026-10-15,MES-6b Step 0 Q6 · Q23 · Q38,Tim):加三支,门都是 module.quality.view。
--   ncr_open —— 一张开着的不合格报告(它扣着那一批)。item_id = 那张报告;item_code = 报告编号;subject = 批号;item_date = 开单日。
--   quality_hold_reserved —— 一批在质量暂扣里的产出批还挂着没释放的预留(Q23:预留照留,发不出去)。一张单 × 一批 × 扣着它的那张报告一行;
--     item_id = 那张销售单(门牌指它,释放预留在那一页);subject = 批号 · 报告编号;item_date = 最早那一笔预留的日子。
--     判据 batch_quality_hold(以读者身份调用的 INVOKER 函数)—— 所以这一支另外要 module.output.view(arm_permission_any):不合格报告与产出批的
--     读策略都认它,读者不会因为读不到而少看一行;质量那一侧之外,销售那一侧也看得见(arm_permission_widen:module.sales.view)。
--   quality_prompt_ncr —— 【提示人去开一张】(Q6:只有 V17 越限自动开):一批进料的品位违反(contract_grade_breaches —— 那张视图自己要
--     module.suppliers.view,今天每一个持质量查看码的角色都持它)、一批产出批的交叉污染抽检过了 V11 的警戒线(当前的、没被更正的那一条)、
--     一批的一个模组最新的放电结论是失败(没拆走)。一批一行;那一批上有一张开单时刻不早于那件事的不合格报告(任何状态)之后消失。
--     item_id = 那一批;doc_kind = 'inbound' / 'output'(门牌按它指 /quality/ncr/new 的那一批);subject = 那件事的出处(化验单号 · 流 · 模组号)。
-- ★ MES-6a-1(2026-10-09,MES-6a Step 0 Q15 · Q17,Tim):加三支,门都是 module.quality.view。
--   sample_retention_due —— 一份样品的留样日已经过了、还没处置(Q15)。item_id = 那份样品;subject = 批号;item_date = 留样日。
--     留样日 Not yet set 的样品不进来(没有日子可过)。
--   assay_dispute_open —— 一件开着的化验争议(它挡着进料的应用 / 定价过账与卖方结算)。item_id = 那件争议;item_code = 批号;
--     subject = 两份结果的单号。
--   assay_results_disagree —— 卖方:两方结果差得超过了合同的容差,而没有人立过争议(MES-0 Q62;assay_disagreements_all)。
--     item_id = 那一批产出批;subject = 销售单号。买方没有这一支(买方合同不带容差 —— Q17)。
-- ★ MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23;MES-5a Step 0 Q18,Tim):加两支,都读 discharge_batch_status_all,门 module.processing.view。
--   discharge_unverified —— 一批做过一炉没回滚的深度放电(verifies_by_unit 的工序),却还没有开着"已放电并核实"
--   (逐模组的结论还没凑满:没记模组数、结果没记完、有模组要再放电)。item_id = 那一批最晚的那一炉;subject = 批号。
--   discharge_quarantine_pending —— 一批里有模组最新一条结论是"失败、处置为隔离",还没拆走。item_id = 那一批最晚的那一炉(拆分从那一页上起);
--   subject = 批号。拆走、或更正了那一条,它就消失。
-- ★ MES-4b(2026-10-07,规格 §3.4;MES-0 Q52;MES-4b Step 0 Q24,Tim):加一支 contamination_check_missing —— 一个班、一条流没有抽检
--   (那一天那一班有一张 MES-4a 起记的、已提交没回滚的单产出了这条流的极片,而同一天同一班任何一张单上都没有一条当前的抽检,
--   两种都算 —— contamination_shift_status_all 的 check_state = 'missing')。门 module.processing.view;item_id = 那一格最早的那一炉
--   (fixture 47:一行提醒要指着一条真实的行),subject = 流。记一条"没抽"(带理由)也关掉它。
-- ★ MES-4a(2026-10-07,MES-0 Q48;MES-4a Step 0 Q22,Tim):加一支 processing_balance_unclosed —— 物料平衡还没结的加工单
--   (MES-4a 起记的、转化型的、已提交没回滚的、最新结平不当前的;processing_run_balance_all 的 balance_state = 'open')。
--   门 module.processing.view;点进去是那张加工单(平衡面板在上面)。只是提醒:月末那一行也只警告,不挡关账。
-- ★ ROLE-1 Batch 2a(2026-09-24,Q9):加一支 supplier_pending_approval —— 等 CFO 批的供应商
--   (action.supplier_approve;只有持这个码的人看得见,点进去由 set_supplier_status 裁)。
--   等了多久从【最后一次送审】起算(supplier_status_history),没有那一行时退回 updated_at。
-- ★ PAY-REQ-1(2026-09-23):加一支 payment_request_pending —— 等 CFO 批的付款申请
--   (module.finance.view;finance 与 cfo 都看得见,点进去由 decide_payment_request 裁谁能批)。
-- ★ PAYROLL-APR-1(2026-09-24):加一支 payroll_request_pending —— 等 CFO 批的工资过账 / 撤销申请
--   (data.view_pay:看得见工资数的人才看得见这一格;点进去由 decide_payroll_request 裁谁能批)。
--   item_id 是【工资期】的 id,不是申请的 —— 申请没有自己的页面,它住在工资期页上。
-- ★ ROLE-1 Batch 4b(2026-09-25):加一支 receipt_price_request_pending —— 等 CFO 批的收货定价申请
--   (data.view_purchase_prices,Tim 的 Q10:看得见采购价的人都看得见这一格;点进去由
--   decide_receipt_price_request 裁谁能批)。item_id 是【收货】的 id —— 申请住在收货页上。
-- ★ APR-5b(2026-09-25):加两支。shipping_release_pending —— 等 CFO 批的发货放行(module.sales.view:
--   读得到放行的人都看得见这一格;点进去由 decide_shipping_release 裁谁能批);item_id 是【订单】的 id ——
--   放行住在订单页上。shipping_release_ready —— 放行过、还有没发完的订单(action.ship_goods:仓库的信号;
--   剩余与发货队列读同一张 sales_order_line_releasable_all;点进去是 /logistics/shipping)。
-- ★ APR-6(2026-09-25):加一支 journal_request_pending —— 等 CFO 批的手工凭证 / 冲销申请
--   (module.finance.view:读得到凭证的人都看得见这一格;点进去由 decide_journal_request 裁谁能批)。
--   item_id 是【申请】的 id —— 一张手工凭证在批准之前还没有分录,申请住在凭证列表页上(/finance/journal)。
--   subject 是摘要 / 冲销理由(申请没有对手方)。
-- ★ APR-7(2026-09-25):加一支 warehouse_request_pending —— 等 CFO 批的注销 / 回滚 / 证书作废申请
--   (module.finance.view:与 decide_warehouse_request 的门同一个码;点进去由它裁谁能批)。item_id 是【申请】的 id ——
--   申请住在库存页上(/inventory#wr-<id>);subject 是提单人的理由。
-- ★ APR-8(2026-09-26):加一支 terms_request_pending —— 等 CFO 批的定价公式 / 合同生效申请
--   (module.pricing.view:公式页的门,cfo 持;点进去由 decide_terms_request 裁谁能批)。item_id 是【申请】的 id;
--   doc_kind 分开两处住址:formula → 公式列表页(/tools/pricing/formulas#tr-<id>),contract → 合同页(/contracts#tr-<id>)。
--   subject 是提单人的理由。
-- ★ APR-9(2026-09-27):加两支。asset_disposal_pending —— 等 CFO 批的固定资产处置申请(module.finance.view:与
--   decide_asset_disposal_request 的门同一个码;item_id 是【申请】的 id,住在资产页 /finance/assets#adr-<id>)。
--   salary_change_pending —— 等批的调薪申请(data.view_pay:看得见工资的人 —— 财务、CFO、cco;谁能批由
--   decide_salary_change_request 按人裁)。★ item_id 是【员工】的 id:申请住在那个人的档案页
--   (/hr/employees/<id>#salary-requests);item_code 是 label,subject 是提单人的理由。月薪数不进这张视图。
-- ★ APR-10(2026-09-27):加一支 gst_filing_pending —— 等 CFO 批的 GST 申报申请(module.finance.view:与
--   decide_gst_filing_request 的门同一个码)。★ item_id 是【期间】的 id:申请住在那一期的页面上
--   (/finance/gst/<id>#gst-filing);item_code 是 label,subject 是提单人的附言(可空)。
--
-- 【为什么是一张视图而不是九个页面各查各的】仪表盘的每一块牌子背后都是"有多少件
-- 事在等"这一类问题;九个问题九处写,就是九份会各自漂移的实现。hr_alerts 已经证明
-- 过这个形状:一个 UNION,每一种等待状态一支,页面只负责画。
--
-- 【属主权限 + 每支自带 permission 列,外层一次性把关】(OPS-14 修法 (a))。
-- 本视图横跨六个模块,invoker 会让 RLS 把读者无权模块的行【静默丢掉】—— 行消失
-- 在这里意味着"那个数少算了",而不是报错。属主权限读全量,外层
-- WHERE has_permission(a.permission) 按【调用者】逐支裁决:无权的支【整支缺席】,
-- 不是零。谓词写一次而不是九遍 —— hr_alerts 的注释说过,复述 N 遍只会给下一个
-- 加支的人留一个漏写的机会;这里每支【声明】自己的权限码,外层【执行】它。
--
-- 【缺席 ≠ 零,页面必须自己分辨】视图对无权读者不发一行,于是"没有行"有两种
-- 含义:真的零,或者你看不见。app/page.tsx 先查权限再渲染每块牌子 —— 无权显示
-- 「受限」(common.restricted),绝不显示 0。这是仪表盘最容易犯、且任何 gate 都
-- 查不出的那个错(0 与"你看不见"在屏幕上一模一样 —— moduleGuard 的老病换了件衣服)。
--
-- 【item_type 写成 'x'::text 字面量】check-i18n 的 sqlLiteralAs 解析器现读本文件,
-- dashboard.item.* 的后缀集合就是这里的支列表 —— 加一支,键检查自动跟着变宽。
--
-- 【两笔贵的读数,按界所限】(OPS-16 报告点名的两处):
--   * fx_rate_gaps 按 (日期,币种) 对每组跑 fx_rate_asof,本身不受期间约束 ——
--     这里限 rate_date >= CURRENT_DATE - 45:仪表盘答"最近有没有漏",完整历史
--     归 /finance/month-end 按月翻。谓词落在分组键上,能下推进聚合。
--   * 银行对账这支【只数报表侧的未匹配行】(bank_statement_lines,行数 = 导入量,
--     天然有界)。bank_reconciliation_status 的账簿侧 LATERAL 要扫 journal_lines
--     全表 —— 那是对账页的活,不上人人都开的首页。
--
-- 【不在此列的】批次毛利 —— 有未决的设计问题(哪些限定词随数字走、已过账 COGS
-- 还是当前成本),自成一切,谓词已录在 AGENTS.md 常设决定 2。月结的七个信号 ——
-- /finance/month-end 是它们的枢纽,首页放一个入口,不复制信号。
--
-- NOTE: introduced by db/migrations/2026-08-09-ops18-operations-now-and-the-dashboard.sql.
-- EXEC-3a(2026-08-16):再【两】支 —— work_order_overdue 与
-- work_order_variance_beyond(WO-1c 记下的两个候选)。差异那一支的两个阈值
-- 现读 processing_settings,【两个数不是一个】(投入超耗是成本问题、
-- 产出短交是收率问题,合成一个数等于说它们一样严重)。
-- 【本刀一度加了资质那两支,而它们 CMP-2 就已经在了】—— 清单文件里那行
-- "Candidate, not built" 是过时的,重复分支由 fixture 37C 与 30A 当场抓住,
-- fu1 撤掉。见 db/migrations/2026-08-16-exec3a-fu1-*.sql。
-- 【batch_margin 撤了】:一个卖出去的批次毛利偏低是一个【状态】,没有清除动作 ——
-- 看板装的是待办,毛利的家是 /margin;可处理的那一半已经是 arm 15。
--
-- EXEC-1a(2026-08-16):两支高管臂 —— metal_quote_stale(行情陈旧,阈值现读
-- pricing_settings.metal_quote_stale_days,按 price_date 不按 created_at)与
-- orders_unfulfilled(confirmed / partially_shipped 的订单)。规格见
-- docs/dashboard-arm-inventory.md;【谁要看哪一支】见 docs/exec-views-plan.md。
--
-- OPS-19(2026-08-09):补上原始定稿漏掉的四支(awaiting_assay / batch_unpriced /
-- invoice_overdue / ar_over_90 + ap_over_90),并新增 output_unsold_aging —— sales
-- 这一行唯一够得着的支(它没有 module.finance.view,当初猜的 AR 支对它同样是「受限」)。
-- assay_unapplied 的粒度同时从"一份未执行化验一行"改成"一个批次一行",与
-- awaiting_assay 同源同粒度、互斥;live 该支当时为 0,故不改变任何现有数字。
--
-- ── SUP-TYPE-1a(2026-08-18):qualification_missing 收窄到【供货的】供应商 ──
-- EXEC-3a 在 2026-08-16-exec3a-four-executive-arms.sql:349 写着:判据是"一张都没有"
-- 而不是"缺某一类",因为没有一张"谁必须持哪张证"的要求矩阵;并且明写着
-- **"有了'这家需要合规文件'的标记之后,这一支应当收窄到它"**。
-- **那个标记现在有了(suppliers.supplies_goods),这一支已经收窄,那句话到此退休。**
-- 提交信息改不了历史文件,所以退休记录写在这里 —— 沿着引用走过来的人在这里落地。
--
-- 【为什么必须收窄:实测过的永久亮灯】SUP-TYPE-0 把它走了一遍:把一个只收钱、
-- 不供货的往来户沿合法路径推到 status='active',这一支当场亮起、days_waiting 一路
-- 长下去,而它永远不会灭 —— 房东不会去办危废证。收窄之后同样的走法【不再亮】,
-- 而一个没有证书的【真供应商】仍然照亮(fixture 89 两边都钉)。
--
-- CMP-1(2026-08-09):两支资质臂。qualification_expiring 到【类型自己的 lead days】就上牌,
-- 过期后【不落牌、无 -30 天下限】—— 工作证过期 30 天人已走,证书过期两年而进场仍可能,
-- 它就还站在那儿(live 那张 2024 年就过期的 Article 18 正是证据)。续期(valid_until
-- 前移)即安静。qualification_missing 是"一张证都没有"的缺席臂(与 awaiting_assay /
-- assay_unapplied 的分立同理)。disposition='ignore' 的类型不上牌。
-- 【规格在 docs/dashboard-arm-inventory.md】每一支是什么意思、挂哪个权限码、界在
-- 哪里、以及【哪些支被考虑过又被排除、为什么】都在那里。
-- 定稿只存在于一次对话里,代价是四支 —— 所以规矩是:
-- 【加一支 = 在同一个提交里往那份清单加一行】。
--
-- MAR-1(2026-08-10):支的权限从【一个码】放宽到【一个谓词】—— permission(必须有)
-- + permission_any(任意其一,由 arm_permission_any 一处声明,SELECT 与 WHERE 共用)。
-- 起因是批次毛利跨两个模块(prices AND (finance OR processing)),而没有任何 live 角色
-- 同时持有后两者。合成一个新权限码那条路被否掉:那会是谁能看毛利的第二份定义,
-- 与 batch_margin 自己的谓词必然漂开。fixture 45 三种读者各钉一次。
-- ASY-P1(2026-08-17):awaiting_assay 那一支【换了问题】。原来问的是"这个批次一份
-- 化验都没有"(batch_assay_status.assay_count = 0),它看不见"化验做了一半",
-- 也灭不掉料已耗尽那两盏灯(线上 IN-2026-0011 / IN-2026-0153,remaining_qty = 0)。
-- 现在读 batch_required_assay_gaps:物料声明了要验哪些金属、其中至少一种还没有被
-- 一份【已应用的】化验覆盖、并且【还取得到样】。subject 从供应商名换成【缺哪几种
-- 金属】—— subject 这一列在每一支里放的都是那一支最该让人看见的事实,而能让人
-- 下一步动起来的是缺哪几种。判据与理由住在那张视图里,不在这里。
-- LINKS-1(2026-08-11):每支多带一个 item_id —— 支从"指向一张列表"变成"指向那一件事"。
-- 【item_id 指的是谁】承载【补救动作】的那张页面所对应的行。十七支里它就是等待中的
-- 那一行;两支里是它的父:bank_unmatched(行没有页面,匹配动作在对账工作台上 →
-- 对账单)与 margin_cost_not_allocated(补救是给加工单分摊成本 → 加工单)。
-- 于是同一支的几行可以共用一个 item_id,那是对的,不是重复 —— fixture 47 因此断言
-- 的是"item_id 落在这一支该落的那张表里",不是"一行一个 id",也不是互不相同。
-- 【SO-3a:应收也成了两种单据】ar_over_90 的 doc_kind 从此非空('sale' 销售记录 /
-- 'invoice' 订单流发票),item_id 相应二选一 —— 门牌各是应收单据页与发票页,
-- app/page.tsx 按 doc_kind 分支,认不出的种类不给链接(与 ap 同一条)。
-- 【doc_kind 是披露】应付账款本来就是两种单据(ap_open_items 自己就按它分支,
-- 应付列表页也一直照它画链接),这张视图先前只是没说出口。其余十八支主体只有一种,
-- 该列为 NULL。【fx_rate_gap 没有 item_id】它的主体是一条不存在的牌价行,缺的东西
-- 没有 id —— 它指向按币种过滤的列表,那是"诚实过滤的列表"那类答案,不是按码搜索。
-- 每支的门牌与"补救是否在那张页面上"这条判据,写在 docs/dashboard-arm-inventory.md。
-- NOTE: item_id / doc_kind added by
-- db/migrations/2026-08-11-links1-operations-now-item-id.sql(列集变了 → DROP + CREATE)。
-- SS-1(2026-08-13):第二十支 safety_stock_below —— 物料的可用量低于它自己的
-- 安全库存阈值。【阈值 NULL 的物料一次都不响】:NULL 是"还没有人决定要盯它",
-- 不是"阈值为零",而把不响读成"查过了没问题"正是 METAL-1 的那一课。
-- 可用量来自 material_stock_available(一处求和,暂扣不算 —— 阈值问的是"还有多少
-- 能用的货",一次暂扣若能掩盖缺货,这个告警就在最该说话的时刻哑掉)。
-- item_date 用【最后一次库存移动】退回今天:阈值告警是持续状态,没有发生日;
-- 去算"哪天跌破的"要在首页翻整段流水史,那条界不允许(credit_over_limit 同形)。

-- LOG-5a(2026-08-20):第 23–26 支 —— 物流的四支告警。全部是【臂】(算出来、
-- 会自愈),不是 notifications 的事件。末尾的 WHERE 多了一个【放宽】算子
-- arm_permission_widen():它与收窄用的 arm_permission_any() 方向相反,
-- 对除 free_time_expiring 以外的每一支都返回 NULL(fixture 102G 逐支断言)。
-- LOG-5d(2026-08-20):同一种里程碑之内,算数的是【最后被录入】的那一条
-- (recorded_at DESC, id DESC)。此前按 event_date DESC 排,于是一条把日期
-- 改【早】的更正永远排不到前面、一次都不会生效(线上 CTR-2026-0009)。
-- EQP-2c(2026-08-21):第 27–28 支 —— 保养【到期】与【将到期】,两支不是一支。
-- 列契约一字未动。规格见 docs/dashboard-arm-inventory.md;推导与它的基线
-- (那两条"低读数有两种意思"的事实)整段写在 equipment_service_status 的视图注释里。
-- 【放宽】两支都走 arm_permission_widen(processing OR finance)—— 机器卡在财务、
-- 干活的人在加工,而它们底下每一张表/视图的读者都是这两个码的 OR。
-- CMPL-1(2026-08-30)追加两支:
--   · company_licence_expiring —— **形状逐字取自 qualification_expiring**,只是把
--     supplier_compliance 换成 company_compliance(少一跳供应商)。它读的仍是
--     certificate_types 自带的 warn_lead_days 与 disposition,所以 gwc 加进字典那天
--     它的到期提醒【自动就有】。**没有另起一套到期机制。**
--   · import_permit_unverified —— 是进口货、而那张进口准证还没有人核过。
--     **它不拦任何东西**:拦的那一半由 nea_import 的 block 处置在收货上做
--     (supplier_receiving_blocked → trg_inbound_batches_po_receivable),
--     这一支说的是"这一票还欠一次人工核对"。理由见 db/tables/inbound_batches.sql 的列注。
-- MES-1(2026-10-06,MES-1 Step 0 Q16 · Q17 · Q23,Tim):第 48–49 支 ——
--   · gateway_silent:一台网关此刻在沉默 —— 它的心跳间隔给了,而最后一次听到它已经超过那个间隔(gateway_health.status = silent)。
--     一次都没听到过的("Not yet heard from")与间隔没给的("Not yet set")【不上牌】:前者是还没调试的正常状态(Q16),
--     后者是沉默无从判断(Q17)。item_id = 那台网关(/operation/devices/[id])。
--   · capture_inbox_failed:收件箱里有转换失败的行 —— 按设备合成一块(item_id = 设备,subject = 设备名 · 失败行数,
--     item_date = 最早的那一行)。不为 awaiting_transform 上牌:那是每一个还没接上转换器的类的正常状态(Q23)。
--   两支都只要 module.processing.view;规格在 docs/dashboard-arm-inventory.md。
-- MES-2(2026-10-06,MES-0 Q13;MES-2 Step 0 Q29 · Q32,Tim):第 50–52 支 ——
--   · capture_draft_pending:一张网关送来的草稿还没人确认 —— 一张一行,item_date = 落草稿那一天,所以 days_waiting 就是它的年龄
--     (草稿永不过期,MES-0 Q13)。门是 action.confirm_capture(能确认它的人才需要被催)。手工录入的草稿生下来就确认了,不上牌。
--   · instrument_calibration_due:一台【在用的】仪器(interface_status 不是 reserved,没停用)今天不在校准期内 —— 过期、没通过、
--     或从来没校过。item_date = 有效期(从来没校过的取它登记那一天)。
--   · instrument_calibration_approaching:在期内、有效期落在 V8 给的提前天数里。V8(calibration_lead_days)没给 → 这一支恒为空,
--     过期本身照样由上一支上牌(每一条记录自己的有效期是必填的)。
--   后两支读 instrument_calibration_now(属主视图,一份挑法、一句判据),门是 module.processing.view。
-- MES-3a(2026-10-06,MES-0 Q13 · Q35 · Q34;MES-3a Step 0 Q13 · Q16 · Q20,Tim):第 53–55 支 —— 三支都【只提醒,不拒】——
--   · storage_ceiling_exceeded:今天在效的执照下,一类 NEA 废物(或总量)的存量超过了给了的上限(storage_ceiling_status.status = exceeded)。
--     收货在超之前就被拒了,所以走到这里的是别的路:加工把料变成了另一类、回滚还回了料、上限被调低了。item_id = 执照,
--     item_code = 类别(总量是 *),门 module.inventory.view。
--   · safety_state_dwell:一批还在厂里的货,身上一条开着的状态待满了它的 dwell_warning_days(V3;没给的不上牌)。
--     一批 × 一条状态一行;item_date = 那条状态被记下的那一天,所以 days_waiting 就是它待了多久。doc_kind = inbound / output,
--     门逐行:进料 module.inbound.view,产出 module.output.view。
--   · quarantine_required:一批身上开着一条要隔离的状态(鼓包或漏液),却还有货放在非隔离库位(quarantine_exposure)。
--     一批 × 一个库位桶一行;doc_kind 与门同上;item_date = 那条状态被记下的那一天。
CREATE OR REPLACE VIEW public.operations_arms_all AS
 SELECT item_type,
    permission,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date
   FROM ( SELECT 'awaiting_assay'::text AS item_type,
            'module.inbound.view'::text AS permission,
            g.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            g.batch_code AS item_code,
            array_to_string(g.missing_metals, ', '::text) AS subject,
            g.arrival_date AS item_date
           FROM batch_required_assay_gaps g
          WHERE g.sampleable
        UNION ALL
         SELECT 'assay_unapplied'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.latest_assay_code AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.has_unapplied_assay
        UNION ALL
         SELECT 'batch_unpriced'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.pricing_status = 'unpriced'::text
        UNION ALL
         SELECT 'allocation_stale'::text AS item_type,
            'module.processing.view'::text AS permission,
            s.run_id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            NULL::text AS subject,
            s.last_cost_change::date AS item_date
           FROM processing_run_allocation_status s
          WHERE s.is_stale OR s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL
        UNION ALL
         SELECT 'po_awaiting_receipt'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.id AS item_id,
            NULL::text AS doc_kind,
            po.code AS item_code,
            po.status AS subject,
            po.order_date AS item_date
           FROM purchase_orders po
          WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
        UNION ALL
         SELECT 'stocktake_open'::text AS item_type,
            'module.stocktakes.view'::text AS permission,
            st.id AS item_id,
            NULL::text AS doc_kind,
            st.code AS item_code,
            NULL::text AS subject,
            st.started_at::date AS item_date
           FROM stocktakes st
          WHERE st.deleted_at IS NULL AND st.status = 'open'::text
        UNION ALL
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_1.id AS item_id,
            NULL::text AS doc_kind,
            s_1.code AS item_code,
            (ct.name_en || ' — '::text) || s_1.legal_name AS subject,
            sc.valid_until AS item_date
           FROM supplier_compliance sc
             JOIN certificate_types ct ON ct.code = sc.cert_type_code
             JOIN suppliers s_1 ON s_1.id = sc.supplier_id
          WHERE sc.deleted_at IS NULL AND s_1.deleted_at IS NULL AND (certificate_expiry_status(sc.valid_until, ct.disposition, ct.warn_lead_days) = ANY (ARRAY['expired'::text, 'expiring'::text]))
        UNION ALL
         SELECT 'qualification_missing'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_2.id AS item_id,
            NULL::text AS doc_kind,
            s_2.code AS item_code,
            s_2.legal_name AS subject,
            s_2.created_at::date AS item_date
           FROM suppliers s_2
          WHERE s_2.deleted_at IS NULL AND s_2.supplies_goods AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
                   FROM supplier_compliance sc2
                  WHERE sc2.supplier_id = s_2.id AND sc2.deleted_at IS NULL))
        UNION ALL
         SELECT 'credit_over_limit'::text AS item_type,
            'module.customers.view'::text AS permission,
            c_1.id AS item_id,
            NULL::text AS doc_kind,
            c_1.code AS item_code,
            c_1.legal_name AS subject,
            COALESCE(( SELECT min(sr.sale_date) AS min
                   FROM sales_records sr
                  WHERE sr.customer_id = c_1.id), CURRENT_DATE) AS item_date
           FROM customers c_1
          WHERE c_1.deleted_at IS NULL AND c_1.credit_limit_base IS NOT NULL AND customer_ar_exposure_visible(c_1.id) >= c_1.credit_limit_base
        UNION ALL
         SELECT 'output_unsold_aging'::text AS item_type,
            'module.output.view'::text AS permission,
            ob.id AS item_id,
            NULL::text AS doc_kind,
            ob.code AS item_code,
            ob.state AS subject,
            COALESCE(ob.output_date, ob.created_at::date) AS item_date
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0::numeric AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
        UNION ALL
         SELECT 'safety_stock_below'::text AS item_type,
            'module.inventory.view'::text AS permission,
            msa.material_id AS item_id,
            NULL::text AS doc_kind,
            msa.code AS item_code,
            (((((trim_scale(msa.available_qty)::text || ' / '::text) || trim_scale(msa.safety_stock_qty)::text) || ' '::text) || COALESCE(msa.unit, ''::text)) || ' — short '::text) || trim_scale(msa.safety_stock_qty - msa.available_qty)::text AS subject,
            COALESCE(msa.last_movement_date, CURRENT_DATE) AS item_date
           FROM material_stock_available msa
          WHERE msa.safety_stock_qty IS NOT NULL AND msa.available_qty < msa.safety_stock_qty
        UNION ALL
         SELECT 'leave_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            lr.id AS item_id,
            NULL::text AS doc_kind,
            lr.code AS item_code,
            e.legal_name AS subject,
            lr.created_at::date AS item_date
           FROM leave_requests lr
             JOIN employees e ON e.id = lr.employee_id
          WHERE lr.status = 'pending'::text AND lr.deleted_at IS NULL
        UNION ALL
         SELECT 'claim_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            mc.id AS item_id,
            NULL::text AS doc_kind,
            mc.code AS item_code,
            e.legal_name AS subject,
            mc.created_at::date AS item_date
           FROM medical_claims mc
             JOIN employees e ON e.id = mc.employee_id
          WHERE mc.status = 'submitted'::text AND mc.deleted_at IS NULL
        UNION ALL
         SELECT 'review_submitted'::text AS item_type,
            'module.hr.view'::text AS permission,
            r.id AS item_id,
            NULL::text AS doc_kind,
            e.code AS item_code,
            e.legal_name AS subject,
            COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
          WHERE r.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            i.invoice_id AS item_id,
            NULL::text AS doc_kind,
            i.code AS item_code,
            i.customer_name AS subject,
            i.due_date AS item_date
           FROM invoice_status i
          WHERE i.overdue
        UNION ALL
         SELECT 'ar_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            COALESCE(ar.sales_record_id, ar.invoice_id) AS item_id,
            ar.doc_kind,
            ar.doc_code AS item_code,
            ar.customer_name AS subject,
            ar.sale_date AS item_date
           FROM ar_open_items ar
          WHERE ar.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'ap_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ap.doc_id AS item_id,
            ap.doc_kind,
            ap.doc_code AS item_code,
            ap.supplier_name AS subject,
            ap.doc_date AS item_date
           FROM ap_open_items ap
          WHERE ap.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'fx_rate_gap'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            g.currency AS item_code,
            array_to_string(g.missing_types, ', '::text) AS subject,
            g.rate_date AS item_date
           FROM fx_rate_gaps g
          WHERE g.rate_date >= (CURRENT_DATE - 45)
        UNION ALL
         SELECT 'bank_unmatched'::text AS item_type,
            'module.finance.view'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.bank_account_code AS item_code,
            s.code AS subject,
            l.line_date AS item_date
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE l.match_status = 'unmatched'::text AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'margin_cost_not_allocated'::text AS item_type,
            'data.view_prices'::text AS permission,
            bm.run_id AS item_id,
            NULL::text AS doc_kind,
            bm.batch_code AS item_code,
            bm.material_name AS subject,
            ob.output_date AS item_date
           FROM batch_margin bm
             JOIN output_batches ob ON ob.id = bm.output_batch_id
          WHERE bm.margin_status = 'no_unit_cost'::text
        UNION ALL
         SELECT 'metal_quote_stale'::text AS item_type,
            'module.pricing.view'::text AS permission,
            mp.latest_id AS item_id,
            NULL::text AS doc_kind,
            mp.metal AS item_code,
            mp.latest_price::text AS subject,
            mp.max_date AS item_date
           FROM ( SELECT p.metal,
                    max(p.price_date) AS max_date,
                    (array_agg(p.id ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_id,
                    (array_agg(p.price_usd_per_tonne ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_price
                   FROM metal_prices p
                  WHERE p.deleted_at IS NULL
                  GROUP BY p.metal) mp
          WHERE (CURRENT_DATE - mp.max_date) > (( SELECT ps.metal_quote_stale_days
                   FROM pricing_settings ps
                 LIMIT 1))
        UNION ALL
         SELECT 'orders_unfulfilled'::text AS item_type,
            'module.sales.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            so.status AS subject,
            so.order_date AS item_date
           FROM sales_orders so
          WHERE so.deleted_at IS NULL AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
        UNION ALL
         SELECT 'work_order_overdue'::text AS item_type,
            'module.processing.view'::text AS permission,
            w.id AS item_id,
            NULL::text AS doc_kind,
            w.code AS item_code,
            w.scheduled_date::text AS subject,
            w.scheduled_date AS item_date
           FROM work_orders w
          WHERE w.status = 'released'::text AND w.scheduled_date IS NOT NULL AND w.scheduled_date < CURRENT_DATE
        UNION ALL
         SELECT 'work_order_variance_beyond'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.work_order_id AS item_id,
            NULL::text AS doc_kind,
            f.work_order_code AS item_code,
                CASE
                    WHEN f.side = 'input'::text THEN (((('input overrun · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                    ELSE (((('output shortfall · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                END AS subject,
            COALESCE(w2.scheduled_date, w2.created_at::date) AS item_date
           FROM work_order_fulfilment f
             JOIN work_orders w2 ON w2.id = f.work_order_id
          WHERE f.has_plan AND f.planned_or_expected_qty > 0::numeric AND (f.side = 'input'::text AND (w2.status = ANY (ARRAY['released'::text, 'closed'::text])) AND f.actual_qty > (f.planned_or_expected_qty * (1::numeric + (( SELECT ps.wo_input_overrun_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)) OR f.side = 'output'::text AND w2.status = 'closed'::text AND f.actual_qty < (f.planned_or_expected_qty * (1::numeric - (( SELECT ps.wo_output_shortfall_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)))
        UNION ALL
         SELECT 'free_time_expiring'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            ((((q.free_days - (CURRENT_DATE - arr.event_date))::text) || ' left of '::text) || q.free_days::text) || COALESCE(' — '::text || f.legal_name, ''::text) AS subject,
            arr.event_date AS item_date
           FROM containers c
             LEFT JOIN suppliers f ON f.id = c.forwarder_id
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'arrived'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) arr ON true
             JOIN forwarder_rate_quotes q ON q.supplier_id = c.forwarder_id AND q.lane_id = c.lane_id AND q.deleted_at IS NULL AND c.departure_date >= q.valid_from AND c.departure_date <= q.valid_to
          WHERE c.deleted_at IS NULL AND q.free_days IS NOT NULL AND (q.free_days - (CURRENT_DATE - arr.event_date)) <= 2
        UNION ALL
         SELECT 'container_no_arrival'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            dep.event_date::text AS subject,
            dep.event_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'departed'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) dep ON true
          WHERE c.deleted_at IS NULL AND (CURRENT_DATE - dep.event_date) >= 14 AND NOT (EXISTS ( SELECT 1
                   FROM container_milestones m2
                  WHERE m2.container_id = c.id AND m2.milestone = 'arrived'::text))
        UNION ALL
         SELECT 'container_eta_overdue'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            c.expected_arrival_date::text AS subject,
            c.expected_arrival_date AS item_date
           FROM containers c
          WHERE c.deleted_at IS NULL AND c.expected_arrival_date IS NOT NULL AND c.expected_arrival_date < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
                   FROM container_milestones m3
                  WHERE m3.container_id = c.id AND m3.milestone = 'arrived'::text))
        UNION ALL
         SELECT 'container_documents_late'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            p.n::text || ' pending'::text AS subject,
            c.departure_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT count(*) AS n
                   FROM container_documents d
                  WHERE d.container_id = c.id AND d.status = 'pending'::text) p ON true
          WHERE c.deleted_at IS NULL AND p.n > 0 AND (CURRENT_DATE - c.departure_date) >= 7
        UNION ALL
         SELECT 'equipment_service_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess.equipment_code AS item_code,
            (ess.service_kind || ' — '::text) || ess.equipment_description AS subject,
            ess.baseline_date AS item_date
           FROM equipment_service_status ess
          WHERE ess.monitored AND ess.disposition = 'warn'::text AND ess.equipment_status <> 'disposed'::text AND ess.is_due
        UNION ALL
         SELECT 'equipment_service_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess_1.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess_1.equipment_code AS item_code,
            (ess_1.service_kind || ' — '::text) || ess_1.equipment_description AS subject,
            ess_1.baseline_date AS item_date
           FROM equipment_service_status ess_1
          WHERE ess_1.monitored AND ess_1.disposition = 'warn'::text AND ess_1.equipment_status <> 'disposed'::text AND ess_1.is_approaching
        UNION ALL
         SELECT 'gateway_silent'::text AS item_type,
            'module.processing.view'::text AS permission,
            gh.gateway_id AS item_id,
            NULL::text AS doc_kind,
            gh.code AS item_code,
            gh.name AS subject,
            gh.last_heard_at::date AS item_date
           FROM gateway_health gh
          WHERE gh.status = 'silent'::text
        UNION ALL
         SELECT 'capture_inbox_failed'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.device_id AS item_id,
            NULL::text AS doc_kind,
            f.device_code AS item_code,
            (f.device_name || ' · '::text) || f.failed_rows::text AS subject,
            f.first_failed AS item_date
           FROM ( SELECT b.device_id,
                    d.code AS device_code,
                    d.name AS device_name,
                    count(*) AS failed_rows,
                    min(b.received_at)::date AS first_failed
                   FROM ingest_inbox b
                     JOIN devices d ON d.id = b.device_id
                  WHERE b.status = 'failed'::text
                  GROUP BY b.device_id, d.code, d.name) f
        UNION ALL
         SELECT 'capture_draft_pending'::text AS item_type,
            'action.confirm_capture'::text AS permission,
            cd.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(dv.code, cd.data_class) AS item_code,
            (COALESCE(dv.name, cd.data_class) || ' · '::text) || COALESCE((cd.proposed ->> 'weight_kg'::text) || ' kg'::text, cd.data_class) AS subject,
            cd.created_at::date AS item_date
           FROM capture_drafts cd
             LEFT JOIN devices dv ON dv.id = cd.device_id
          WHERE cd.status = 'pending'::text
        UNION ALL
         SELECT 'instrument_calibration_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ic.device_id AS item_id,
            NULL::text AS doc_kind,
            ic.code AS item_code,
            (ic.name || ' · '::text) || ic.status AS subject,
            COALESCE(ic.valid_until, ic.registered_at::date) AS item_date
           FROM instrument_calibration_now ic
          WHERE ic.in_use AND ic.status <> 'in_calibration'::text
        UNION ALL
         SELECT 'instrument_calibration_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ic.device_id AS item_id,
            NULL::text AS doc_kind,
            ic.code AS item_code,
            ic.name AS subject,
            ic.valid_until AS item_date
           FROM instrument_calibration_now ic
          WHERE ic.in_use AND ic.approaching
        UNION ALL
         SELECT 'storage_ceiling_exceeded'::text AS item_type,
            'module.inventory.view'::text AS permission,
            sc.licence_id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(sc.category_code, '*'::text) AS item_code,
            (((sc.cert_no || ' · '::text) || sc.name_en) || ' · '::text) || round(sc.on_hand_t, 3)::text || ' / '::text || sc.limit_tonnes::text || ' t'::text AS subject,
            (now() AT TIME ZONE 'Asia/Singapore'::text)::date AS item_date
           FROM storage_ceiling_status sc
          WHERE sc.status = 'exceeded'::text
        UNION ALL
         SELECT 'safety_state_dwell'::text AS item_type,
                CASE dw.batch_kind
                    WHEN 'inbound'::text THEN 'module.inbound.view'::text
                    ELSE 'module.output.view'::text
                END AS permission,
            dw.batch_id AS item_id,
            dw.batch_kind AS doc_kind,
            dw.batch_code AS item_code,
            dw.name_en AS subject,
            dw.recorded_on AS item_date
           FROM safety_state_dwell dw
          WHERE dw.dwell_status = 'past'::text AND dw.on_site
        UNION ALL
         SELECT 'quarantine_required'::text AS item_type,
                CASE qe.batch_kind
                    WHEN 'inbound'::text THEN 'module.inbound.view'::text
                    ELSE 'module.output.view'::text
                END AS permission,
            qe.batch_id AS item_id,
            qe.batch_kind AS doc_kind,
            qe.batch_code AS item_code,
            (qe.name_en || ' · '::text) || COALESCE(qe.location_code, 'unspecified'::text) AS subject,
            qe.recorded_on AS item_date
           FROM quarantine_exposure qe
        UNION ALL
         SELECT 'promise_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            ps.promise_id AS item_id,
            NULL::text AS doc_kind,
            ps.chase_code AS item_code,
            ps.customer_name AS subject,
            ps.promised_date AS item_date
           FROM collection_promise_status ps
          WHERE ps.is_overdue
        UNION ALL
         SELECT 'wht_due'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            to_char(w.period_month::timestamp without time zone, 'YYYY-MM'::text) AS item_code,
            (to_char(w.unremitted_base, 'FM999G999G990D00'::text) || ' '::text) || (( SELECT c.code
                   FROM currencies c
                  WHERE c.is_base)) AS subject,
            w.due_date AS item_date
           FROM wht_liability_by_month w
          WHERE w.unremitted_base > 0::numeric AND (w.due_date - CURRENT_DATE) <= 7
        UNION ALL
         SELECT 'company_licence_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            cc.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(cc.cert_no, ct.code) AS item_code,
            ct.name_en AS subject,
            cc.valid_until AS item_date
           FROM company_compliance cc
             JOIN certificate_types ct ON ct.code = cc.cert_type_code
          WHERE cc.deleted_at IS NULL AND (certificate_expiry_status(cc.valid_until, ct.disposition, ct.warn_lead_days) = ANY (ARRAY['expired'::text, 'expiring'::text]))
        UNION ALL
         SELECT 'import_permit_unverified'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            ib.code AS item_code,
            s.legal_name AS subject,
            ib.arrival_date AS item_date
           FROM inbound_batches ib
             JOIN suppliers s ON s.id = ib.supplier_id
          WHERE ib.deleted_at IS NULL AND ib.imported IS TRUE AND ib.import_permit_verified_at IS NULL
        UNION ALL
         SELECT 'payment_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            pr.id AS item_id,
            NULL::text AS doc_kind,
            pr.code AS item_code,
            COALESCE(s.legal_name, e.legal_name, c.legal_name) AS subject,
            pr.created_at::date AS item_date
           FROM payment_requests pr
             LEFT JOIN suppliers s ON s.id = pr.supplier_id
             LEFT JOIN employees e ON e.id = pr.employee_id
             LEFT JOIN customers c ON c.id = pr.customer_id
          WHERE pr.status = 'submitted'::text
        UNION ALL
         SELECT 'supplier_pending_approval'::text AS item_type,
            'action.supplier_approve'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            s.legal_name AS subject,
            COALESCE(( SELECT max(h.changed_at) AS max
                   FROM supplier_status_history h
                  WHERE h.supplier_id = s.id AND h.to_status = 'pending_review'::text), s.updated_at)::date AS item_date
           FROM suppliers s
          WHERE s.status = 'pending_review'::supplier_status AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'payroll_request_pending'::text AS item_type,
            'data.view_pay'::text AS permission,
            q.payroll_period_id AS item_id,
            NULL::text AS doc_kind,
            q.label AS item_code,
            pp.code AS subject,
            q.created_at::date AS item_date
           FROM payroll_requests q
             JOIN payroll_periods pp ON pp.id = q.payroll_period_id
          WHERE q.status = 'submitted'::text
        UNION ALL
         SELECT 'receipt_price_request_pending'::text AS item_type,
            'data.view_purchase_prices'::text AS permission,
            rq.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            rq.label AS item_code,
            ib.code AS subject,
            rq.created_at::date AS item_date
           FROM receipt_price_requests rq
             JOIN inbound_batches ib ON ib.id = rq.inbound_batch_id
          WHERE rq.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            iq.invoice_id AS item_id,
            NULL::text AS doc_kind,
            iq.label AS item_code,
            c.legal_name AS subject,
            iq.created_at::date AS item_date
           FROM invoice_requests iq
             JOIN invoices i ON i.id = iq.invoice_id
             JOIN customers c ON c.id = i.customer_id
          WHERE iq.status = 'submitted'::text
        UNION ALL
         SELECT 'shipping_release_pending'::text AS item_type,
            'module.sales.view'::text AS permission,
            sr.sales_order_id AS item_id,
            NULL::text AS doc_kind,
            sr.label AS item_code,
            c.legal_name AS subject,
            sr.created_at::date AS item_date
           FROM shipping_releases sr
             JOIN sales_orders so ON so.id = sr.sales_order_id
             JOIN customers c ON c.id = so.customer_id
          WHERE sr.status = 'submitted'::text
        UNION ALL
         SELECT 'journal_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            jq.id AS item_id,
            NULL::text AS doc_kind,
            jq.label AS item_code,
            jq.memo AS subject,
            jq.created_at::date AS item_date
           FROM journal_requests jq
          WHERE jq.status = 'submitted'::text
        UNION ALL
         SELECT 'warehouse_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            wq.id AS item_id,
            NULL::text AS doc_kind,
            wq.label AS item_code,
            wq.reason AS subject,
            wq.created_at::date AS item_date
           FROM warehouse_requests wq
          WHERE wq.status = 'submitted'::text
        UNION ALL
         SELECT 'terms_request_pending'::text AS item_type,
            'module.pricing.view'::text AS permission,
            tq.id AS item_id,
                CASE
                    WHEN tq.contract_id IS NOT NULL THEN 'contract'::text
                    ELSE 'formula'::text
                END AS doc_kind,
            tq.label AS item_code,
            tq.reason AS subject,
            tq.created_at::date AS item_date
           FROM terms_requests tq
          WHERE tq.status = 'submitted'::text
        UNION ALL
         SELECT 'asset_disposal_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            dq.id AS item_id,
            NULL::text AS doc_kind,
            dq.label AS item_code,
            dq.reason AS subject,
            dq.created_at::date AS item_date
           FROM asset_disposal_requests dq
          WHERE dq.status = 'submitted'::text
        UNION ALL
         SELECT 'salary_change_pending'::text AS item_type,
            'data.view_pay'::text AS permission,
            sq.employee_id AS item_id,
            NULL::text AS doc_kind,
            sq.label AS item_code,
            sq.reason AS subject,
            sq.created_at::date AS item_date
           FROM salary_change_requests sq
          WHERE sq.status = 'submitted'::text
        UNION ALL
         SELECT 'gst_filing_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            gq.period_id AS item_id,
            NULL::text AS doc_kind,
            gq.label AS item_code,
            gq.note AS subject,
            gq.created_at::date AS item_date
           FROM gst_filing_requests gq
          WHERE gq.status = 'submitted'::text
        UNION ALL
         SELECT 'processing_balance_unclosed'::text AS item_type,
            'module.processing.view'::text AS permission,
            b.run_id AS item_id,
            NULL::text AS doc_kind,
            b.run_code AS item_code,
            b.operation_type_code AS subject,
            b.process_date AS item_date
           FROM processing_run_balance_all b
          WHERE b.balance_state = 'open'::text
        UNION ALL
         SELECT 'contamination_check_missing'::text AS item_type,
            'module.processing.view'::text AS permission,
            cs.first_run_id AS item_id,
            NULL::text AS doc_kind,
            cs.first_run_code AS item_code,
            cs.stream_code AS subject,
            cs.process_date AS item_date
           FROM contamination_shift_status_all cs
          WHERE cs.check_state = 'missing'::text
        UNION ALL
         SELECT 'discharge_unverified'::text AS item_type,
            'module.processing.view'::text AS permission,
            ds.latest_run_id AS item_id,
            NULL::text AS doc_kind,
            ds.latest_run_code AS item_code,
            ds.batch_code AS subject,
            ds.latest_run_date AS item_date
           FROM discharge_batch_status_all ds
          WHERE ds.latest_run_id IS NOT NULL AND NOT ds.currently_verified
        UNION ALL
         SELECT 'discharge_quarantine_pending'::text AS item_type,
            'module.processing.view'::text AS permission,
            ds.latest_run_id AS item_id,
            NULL::text AS doc_kind,
            ds.latest_run_code AS item_code,
            ds.batch_code AS subject,
            ds.latest_run_date AS item_date
           FROM discharge_batch_status_all ds
          WHERE ds.failed_quarantine > 0 AND ds.latest_run_id IS NOT NULL
        UNION ALL
         SELECT 'shipping_release_ready'::text AS item_type,
            'action.ship_goods'::text AS permission,
            q.sales_order_id AS item_id,
            NULL::text AS doc_kind,
            q.order_code AS item_code,
            q.customer_name AS subject,
            q.released_on AS item_date
           FROM ( SELECT so.id AS sales_order_id,
                    so.code AS order_code,
                    c.legal_name AS customer_name,
                    max(r.decided_at)::date AS released_on
                   FROM shipping_releases r
                     JOIN shipping_release_lines rl ON rl.release_id = r.id
                     JOIN invoice_lines il ON il.id = rl.invoice_line_id
                     JOIN sales_orders so ON so.id = r.sales_order_id
                     JOIN customers c ON c.id = so.customer_id
                  WHERE r.status = 'approved'::text AND NOT il.invoice_voided
                    AND so.deleted_at IS NULL
                    AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
                    AND (( SELECT ra.releasable_qty
                           FROM sales_order_line_releasable_all ra
                          WHERE ra.invoice_line_id = il.id)) > COALESCE(( SELECT sum(sl.qty) AS sum
                           FROM shipment_lines sl
                          WHERE sl.sales_order_line_id = rl.sales_order_line_id), 0::numeric)
                  GROUP BY so.id, so.code, c.legal_name) q
        UNION ALL
         SELECT 'sample_retention_due'::text AS item_type,
            'module.quality.view'::text AS permission,
            sr.id AS item_id,
            NULL::text AS doc_kind,
            sr.code AS item_code,
            sr.batch_code AS subject,
            sr.retain_until AS item_date
           FROM ( SELECT s.id,
                    s.code,
                    COALESCE(ib.code, ob.code) AS batch_code,
                    s.retain_until
                   FROM samples s
                     LEFT JOIN inbound_batches ib ON ib.id = s.inbound_batch_id
                     LEFT JOIN output_batches ob ON ob.id = s.output_batch_id
                  WHERE s.retain_until IS NOT NULL AND s.retain_until < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
                           FROM sample_events e
                          WHERE e.sample_id = s.id AND e.event_kind = 'disposed'::text))) sr
        UNION ALL
         SELECT 'assay_dispute_open'::text AS item_type,
            'module.quality.view'::text AS permission,
            d.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(ib.code, ob.code) AS item_code,
            (ao.code || ' / '::text) || ac.code AS subject,
            d.created_at::date AS item_date
           FROM assay_disputes d
             LEFT JOIN inbound_batches ib ON ib.id = d.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = d.output_batch_id
             JOIN assay_results ao ON ao.id = d.our_assay_id
             JOIN assay_results ac ON ac.id = d.counterparty_assay_id
          WHERE d.status = 'open'::text
        UNION ALL
         SELECT 'assay_results_disagree'::text AS item_type,
            'module.quality.view'::text AS permission,
            ad.output_batch_id AS item_id,
            NULL::text AS doc_kind,
            ad.batch_code AS item_code,
            ad.sales_order_code AS subject,
            ad.latest_assay_date AS item_date
           FROM assay_disagreements_all ad
        UNION ALL
         SELECT 'ncr_open'::text AS item_type,
            'module.quality.view'::text AS permission,
            n.id AS item_id,
            NULL::text AS doc_kind,
            n.code AS item_code,
            COALESCE(ib.code, ob.code) AS subject,
            n.opened_at::date AS item_date
           FROM nonconformance_reports n
             LEFT JOIN inbound_batches ib ON ib.id = n.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = n.output_batch_id
          WHERE n.status = 'open'::text
        UNION ALL
         SELECT 'quality_hold_reserved'::text AS item_type,
            'module.quality.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            (h.batch_code || ' · '::text) || h.ncr_code AS subject,
            min(r.created_at)::date AS item_date
           FROM sales_order_reservations r
             JOIN sales_order_lines l ON l.id = r.sales_order_line_id
             JOIN sales_orders so ON so.id = l.sales_order_id
             CROSS JOIN LATERAL batch_quality_hold(NULL::uuid, r.output_batch_id) h(ncr_id, ncr_code, batch_code)
          WHERE r.released_at IS NULL AND r.consumed_at IS NULL AND so.deleted_at IS NULL
          GROUP BY so.id, so.code, h.batch_code, h.ncr_code
        UNION ALL
         SELECT 'coa_facts_changed'::text AS item_type,
            'action.issue_coa'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            (ob.code || ' · '::text) || f.what AS subject,
            f.found_on AS item_date
           FROM certificates_of_analysis c
             JOIN output_batches ob ON ob.id = c.output_batch_id
             CROSS JOIN LATERAL ( SELECT x.what,
                    x.found_on
                   FROM ( SELECT a.code AS what,
                            a.created_at AS found_at,
                            a.created_at::date AS found_on
                           FROM assay_results a
                          WHERE a.output_batch_id = c.output_batch_id AND a.deleted_at IS NULL AND a.created_at > c.issued_at
                        UNION ALL
                         SELECT n.code,
                            n.opened_at,
                            n.opened_at::date AS opened_at_date
                           FROM nonconformance_reports n
                          WHERE n.output_batch_id = c.output_batch_id AND n.opened_at > c.issued_at) x
                  ORDER BY x.found_at, x.what
                 LIMIT 1) f
          WHERE c.status = 'issued'::text
        UNION ALL
         SELECT 'quality_prompt_ncr'::text AS item_type,
            'module.quality.view'::text AS permission,
            q.batch_id AS item_id,
            q.batch_kind AS doc_kind,
            q.batch_code AS item_code,
            q.evidence AS subject,
            q.found_on AS item_date
           FROM ( SELECT 'inbound'::text AS batch_kind,
                    gb.inbound_batch_id AS batch_id,
                    gb.inbound_batch_code AS batch_code,
                    min(ar.code) AS evidence,
                    min(gb.assay_date) AS found_on,
                    min(ar.created_at) AS found_at
                   FROM contract_grade_breaches gb
                     JOIN assay_results ar ON ar.id = gb.assay_result_id
                  GROUP BY gb.inbound_batch_id, gb.inbound_batch_code
                UNION ALL
                 SELECT 'output'::text,
                    cc.output_batch_id,
                    ob2.code,
                    min(cc.stream_code),
                    min(cc.sampled_at)::date,
                    min(cc.recorded_at)
                   FROM contamination_checks cc
                     JOIN output_batches ob2 ON ob2.id = cc.output_batch_id AND ob2.deleted_at IS NULL
                  WHERE cc.above_warning IS TRUE AND NOT (EXISTS ( SELECT 1
                           FROM contamination_checks x
                          WHERE x.corrects_id = cc.id))
                  GROUP BY cc.output_batch_id, ob2.code
                UNION ALL
                 SELECT dm.batch_kind,
                    dm.batch_id,
                    COALESCE(ib3.code, ob3.code),
                    min(dm.module_ref),
                    min(dm.verdict_at)::date,
                    min(dm.verdict_at)
                   FROM discharge_module_current_all dm
                     LEFT JOIN inbound_batches ib3 ON ib3.id = dm.batch_id AND dm.batch_kind = 'inbound'::text
                     LEFT JOIN output_batches ob3 ON ob3.id = dm.batch_id AND dm.batch_kind = 'output'::text
                  WHERE dm.verdict = 'fail'::text AND NOT dm.split_out
                    AND COALESCE(ib3.deleted_at, ob3.deleted_at) IS NULL AND COALESCE(ib3.id, ob3.id) IS NOT NULL
                  GROUP BY dm.batch_kind, dm.batch_id, ib3.code, ob3.code) q
          WHERE NOT (EXISTS ( SELECT 1
                   FROM nonconformance_reports n2
                  WHERE (n2.inbound_batch_id = q.batch_id OR n2.output_batch_id = q.batch_id) AND n2.opened_at >= q.found_at))
        UNION ALL
         SELECT 'incident_nea_notify_due'::text AS item_type,
            'module.safety.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            k.name_en AS subject,
            c.occurred_on AS item_date
           FROM incident_current_all c
             JOIN incident_kinds k ON k.code = c.kind_code
          WHERE c.nea_reportable AND c.notified_at IS NULL
        UNION ALL
         SELECT 'incident_report_due'::text AS item_type,
            'module.safety.view'::text AS permission,
            c.id AS item_id,
            c.deadline_state AS doc_kind,
            c.code AS item_code,
            k.name_en AS subject,
            COALESCE(c.report_deadline, c.occurred_on) AS item_date
           FROM incident_current_all c
             JOIN incident_kinds k ON k.code = c.kind_code
          WHERE c.nea_reportable AND c.report_submitted_at IS NULL
        UNION ALL
         SELECT 'inspection_due'::text AS item_type,
            'module.safety.view'::text AS permission,
            t.id AS item_id,
            d.due_state AS doc_kind,
            t.code AS item_code,
            t.name AS subject,
            COALESCE(d.next_due_on, (t.created_at AT TIME ZONE 'Asia/Singapore'::text)::date) AS item_date
           FROM inspection_templates t
             JOIN inspection_template_due_all d ON d.id = t.id
          WHERE t.is_active AND d.due_state = ANY (ARRAY['due'::text, 'never_run'::text])
        UNION ALL
         SELECT 'inspection_finding_open'::text AS item_type,
            'module.safety.view'::text AS permission,
            f.id AS item_id,
            f.run_id::text AS doc_kind,
            r.code AS item_code,
            s.item_text AS subject,
            (f.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date AS item_date
           FROM inspection_findings f
             JOIN inspection_runs r ON r.id = f.run_id
             JOIN inspection_results s ON s.id = f.result_id
          WHERE NOT (EXISTS ( SELECT 1
                   FROM inspection_finding_closures c
                  WHERE c.finding_id = f.id))
        UNION ALL
         SELECT 'supplier_review_due'::text AS item_type,
            'action.supplier_review'::text AS permission,
            s.id AS item_id,
            CASE WHEN lr.recorded_at IS NULL THEN 'never_reviewed'::text ELSE 'due'::text END AS doc_kind,
            s.code AS item_code,
            s.legal_name AS subject,
            COALESCE(((lr.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date + ss.review_window_days),
                     (s.created_at AT TIME ZONE 'Asia/Singapore'::text)::date) AS item_date
           FROM suppliers s
             JOIN supplier_score_settings ss ON ss.id AND ss.review_window_days IS NOT NULL
             LEFT JOIN supplier_latest_reviews lr ON lr.supplier_id = s.id
          WHERE s.deleted_at IS NULL AND s.supplies_goods AND (s.status = ANY (ARRAY['approved'::supplier_status, 'active'::supplier_status]))
            AND (lr.recorded_at IS NULL OR ((lr.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date + ss.review_window_days) <= (now() AT TIME ZONE 'Asia/Singapore'::text)::date)
        UNION ALL
         SELECT 'expense_claim_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            e.legal_name AS subject,
            COALESCE(c.submitted_at, c.created_at)::date AS item_date
           FROM expense_claims c
             LEFT JOIN employees e ON e.id = c.employee_id
          WHERE c.status = 'submitted'::text
        UNION ALL
         SELECT 'purchase_order_approval_pending'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.id AS item_id,
            NULL::text AS doc_kind,
            po.code AS item_code,
            sp.legal_name AS subject,
            COALESCE(( SELECT max(l.decided_at) AS max
                   FROM approval_log l
                  WHERE l.subject_type = 'purchase_order'::text AND l.subject_id = po.id AND (l.decision = ANY (ARRAY['submitted'::text, 'approval_voided'::text]))), po.created_at)::date AS item_date
           FROM purchase_orders po
             LEFT JOIN suppliers sp ON sp.id = po.supplier_id
          WHERE po.approval_status = 'pending'::text AND po.deleted_at IS NULL
        UNION ALL
         SELECT 'overtime_batch_pending'::text AS item_type,
            'action.overtime_approve'::text AS permission,
            ob.id AS item_id,
            NULL::text AS doc_kind,
            ob.label AS item_code,
            NULL::text AS subject,
            COALESCE(ob.submitted_at, ob.created_at)::date AS item_date
           FROM overtime_batches ob
          WHERE ob.status = 'submitted'::text
        UNION ALL
         SELECT 'work_order_release_pending'::text AS item_type,
            'action.wo_release'::text AS permission,
            wo.id AS item_id,
            NULL::text AS doc_kind,
            wo.code AS item_code,
            NULL::text AS subject,
            wo.created_at::date AS item_date
           FROM work_orders wo
          WHERE wo.status = 'draft'::text
        UNION ALL
         SELECT 'blending_plan_release_pending'::text AS item_type,
            'action.wo_release'::text AS permission,
            bp.id AS item_id,
            NULL::text AS doc_kind,
            bp.code AS item_code,
            NULL::text AS subject,
            bp.created_at::date AS item_date
           FROM blending_plans bp
          WHERE bp.status = 'draft'::text
        UNION ALL
         SELECT 'portal_certificate_pending'::text AS item_type,
            'module.suppliers.edit'::text AS permission,
            ps.supplier_id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(ps.cert_no, ps.cert_type_code) AS item_code,
            sp.legal_name AS subject,
            COALESCE(ps.submitted_at, ps.created_at)::date AS item_date
           FROM portal_certificate_submissions ps
             JOIN suppliers sp ON sp.id = ps.supplier_id
          WHERE ps.status = 'submitted'::text
        UNION ALL
         SELECT 'compliance_pack_not_frozen'::text AS item_type,
            'action.compliance_pack'::text AS permission,
            NULL::uuid AS item_id,
            'not_frozen'::text AS doc_kind,
            to_char(m.m, 'YYYY-MM'::text) AS item_code,
            'Compliance pack'::text AS subject,
            (m.m + '1 mon -1 days'::interval)::date AS item_date
           FROM finance_settings fs
             CROSS JOIN LATERAL generate_series(date_trunc('month'::text, fs.system_start_date::timestamp without time zone), date_trunc('month'::text, fs.locked_before::timestamp without time zone), '1 mon'::interval) m(m)
          WHERE fs.system_start_date IS NOT NULL AND fs.locked_before IS NOT NULL
            AND (m.m + '1 mon'::interval)::date <= fs.locked_before
            AND NOT (EXISTS ( SELECT 1
                   FROM compliance_packs cp
                  WHERE cp.period_month = m.m::date AND cp.superseded_at IS NULL))) a;

COMMENT ON VIEW public.operations_arms_all IS
    'MES-8b-2:operations_now 的全部支,不按读者过滤。operations_now 与 floor_board() 都从这里读 —— 支的定义只有这一份。基视图,不给人读。';

REVOKE ALL ON public.operations_arms_all FROM authenticated, anon;

-- ── db/views/operations_now.sql ──
-- db/views/operations_now.sql
-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行;每一支按【读者】的码裁决。
-- ★ MES-8b-2(2026-10-17,MES-8 Step 0 Q20,Tim):支的定义搬进了 db/views/operations_arms_all.sql(连同原来的抬头,原样);
--   本视图只剩【按读者过滤】那一句与两列推导(permission_any · days_waiting)—— 列、列序与每一行都与搬之前逐字相同。
--   搬的理由:大屏的 floor_board() 要从同一份支的定义上【计数】,而读本视图的 SECURITY DEFINER 函数仍然只拿到调用者看得见的那几支
--   (has_permission 解析的是调用者)。加一支改 operations_arms_all.sql。
-- ★ SYSTEM-MAP-2(2026-10-27,Tim Q3):审批支(decision_arms() 里的那几支)【按行】过滤 —— 只留读者此刻批得了的那几张,
--   判据是 waiting_decisions()(待办页与首页的数读的同一支);别的支(例外)照旧按读码给全公司看(Tim 2.4 (11))。
--   item_id 是单据所在页主体的那几支(parent_keyed)按 (parent_id, 标签) 对行。
-- WHERE has_permission(a.permission) 按【调用者】逐支裁决:无权的支【整支缺席】,
--   arm_permission_widen 放宽、arm_permission_any 收窄(lib/modules.ts 的 allows() 同形)。
CREATE OR REPLACE VIEW public.operations_now AS
 WITH w AS MATERIALIZED (
         SELECT d.item_type, d.item_id, d.parent_id, d.code
           FROM waiting_decisions() d
        )
 SELECT item_type,
    permission,
    arm_permission_any(item_type) AS permission_any,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM operations_arms_all a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type))) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)))
    AND (NOT (EXISTS ( SELECT 1
           FROM decision_arms() t
          WHERE t.arm = a.item_type)) OR (EXISTS ( SELECT 1
           FROM decision_arms() t
             JOIN w ON w.item_type = t.decision_type
          WHERE t.arm = a.item_type AND ((NOT t.parent_keyed AND w.item_id = a.item_id) OR (t.parent_keyed AND w.parent_id = a.item_id AND w.code = a.item_code)))));

GRANT SELECT ON public.operations_now TO authenticated;

-- ── db/views/purchase_order_status.sql ──
-- db/views/purchase_order_status.sql
-- 每张【在册且未取消】的采购订单一行。
-- prepaid_base 只计 status='posted' 收付款中指向该 PO 的核销行(预付);
-- prepaid_applied_base 计 prepayment_applications(预付已冲抵到具体到货批次的部分);
-- 二者之差就是还躺在 1300 预付款项里、尚未落到任何应付上的余额。
-- received_* 只数【未软删】的关联到货批次;ordered_qty 为 0 时 receipt_pct 为 NULL
-- (没有下单量就没有"收了几成"这回事,不能拿 0 当分母)。
-- 【属主权限】(OPS-14 起)—— 见下方 note。
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql.

-- cut 2b:本视图改读遮蔽伴生视图(<表>_masked)而非基表 —— 敏感列的遮蔽
-- 因此是继承来的。【OPS-14 起本视图是属主权限,不再是 invoker】,但这一段的结论
-- 未变:遮蔽视图的把关是 has_permission() 谓词,而 has_permission() 按 auth.uid()
-- 解析【调用者】,与谁拥有外层视图无关 —— 所以模块与数据类边界一字未动。
-- 见 db/migrations/2026-08-01-perm2b-field-masking.sql.

-- OPS-14(2026-08-08):改为【属主权限】+ module.purchasing.view;三列预付【遮蔽】。
-- 行的存在判据是采购的(在册、未取消),只有三列预付是财务的金额。原先 invoker 时
-- procurement 读 PO-2026-0001 的预付为 0.00,真值 35,000.00 —— 付过的定金,对最该
-- 知道的那个角色显示成没付。
-- 【为什么置 NULL 而不是拆成第二张视图】仓库对"你不该看见的金额"已有成熟表达:
-- cut 2b 的遮蔽列 + lib/permissions.ts 把 null 解释成「受限」。NULL 是"缺席",
-- 0.00 是"错"。列即是"支";拆视图效果相同却把一行 PO 劈成两处读,收益为零。
-- supplier 标签跟着单据走。

CREATE OR REPLACE VIEW public.purchase_order_status WITH (security_invoker = off) AS
 SELECT po.id AS po_id,
    po.code,
    po.supplier_id,
    sup.legal_name AS supplier_name,
    po.order_date,
    po.expected_delivery_date,
    po.status,
    po.currency,
    po.estimated_total_ccy,
        CASE WHEN has_permission('module.finance.view'::text)
             THEN round(COALESCE(pre.prepaid, 0::numeric), 2)
             ELSE NULL::numeric END AS prepaid_base,
        CASE WHEN has_permission('module.finance.view'::text)
             THEN round(COALESCE(app.applied, 0::numeric), 2)
             ELSE NULL::numeric END AS prepaid_applied_base,
        CASE WHEN has_permission('module.finance.view'::text)
             THEN round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app.applied, 0::numeric), 2)
             ELSE NULL::numeric END AS prepaid_remaining_base,
    COALESCE(rec.batches, 0::bigint) AS received_batches,
    round(COALESCE(rec.qty, 0::numeric), 4) AS received_qty,
    round(COALESCE(ord.qty, 0::numeric), 4) AS ordered_qty,
        CASE
            WHEN COALESCE(ord.qty, 0::numeric) = 0::numeric THEN NULL::numeric
            ELSE round(COALESCE(rec.qty, 0::numeric) / ord.qty * 100::numeric, 2)
        END AS receipt_pct,
    -- ── PO-GST-1(2026-09-03):清单也要说得出净额 / 税 / 含税额 ──────────────
    -- ★【三列必须加在【末尾】,这不是风格问题】★ CREATE OR REPLACE VIEW 只允许
    --   在末尾追加列。本刀第一版把它们插在 estimated_total_ccy 后面,PostgreSQL
    --   报的是 `cannot change name of view column "prepaid_base" to "tax_total_ccy"`
    --   —— 与 purchase_orders_masked 里 contract_id 那条注释记的是同一件事。
    -- 【这三列不必再遮蔽一次】本视图 FROM 的是 purchase_orders_masked,
    --   税额与含税额在那一层已经按 data.view_prices 置空,遮蔽自然传导。
    -- 【gross 与 purchase_orders_masked 里那一次是同一个表达式,两处都不落库】
    --   导出量不存;fixture 断言两处对同一张单逐分相等。
    po.tax_total_ccy,
    po.estimated_total_ccy + COALESCE(po.tax_total_ccy, 0) AS gross_total_ccy,
    (po.tax_total_ccy IS NOT NULL) AS carries_tax,
    -- ── SYSTEM-MAP-2(2026-10-27,PO-LIST-NO-APPROVAL-STATUS):清单要看得出审批状态 ──
    --   加在【末尾】(上面那条规矩);不是金额,不遮蔽。
    po.approval_status
   FROM purchase_orders_masked po
     JOIN suppliers sup ON sup.id = po.supplier_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS prepaid
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.purchase_order_id = po.id) pre ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
           FROM prepayment_applications_masked ppa
          WHERE ppa.purchase_order_id = po.id) app ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS batches,
            sum(ib.quantity) AS qty
           FROM inbound_batches_masked ib
          WHERE ib.purchase_order_id = po.id AND ib.deleted_at IS NULL) rec ON true
     LEFT JOIN LATERAL ( SELECT sum(pol.quantity) AS qty
           FROM purchase_order_lines_masked pol
          WHERE pol.purchase_order_id = po.id) ord ON true
  WHERE po.deleted_at IS NULL AND po.status <> 'cancelled'::text
    AND has_permission('module.purchasing.view'::text);

-- ── db/views/supplier_certificate_status.sql ──
-- db/views/supplier_certificate_status.sql
-- SYSTEM-MAP-2(Tim 2026-10-27 SYSTEM-MAP-1 Q3 → 64d-2):安全 › 供应商证书总览的那一行,带【状态】。
--   一张在册证书(没删、供应商没删)一行;status = certificate_expiry_status(有效期, 种类的 disposition, 种类的 warn_lead_days)——
--   与提醒页 qualification_expiring 那一支读的是同一支判据(db/functions/certificate_expiry_status.sql),不另写一份。
-- 【属主权限 + module.suppliers.view】与 supplier_compliance 自己的读策略同一个码;供应商名字是单据的标签(跟着行走)。
-- 【只读】Supabase 的默认权限让新视图对 authenticated 可写(MES7B1-VIEW-DEFAULT-WRITE-GRANTS),所以 REVOKE ALL 再 GRANT SELECT。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE VIEW public.supplier_certificate_status WITH (security_invoker = off) AS
 SELECT sc.id,
    sc.supplier_id,
    s.code AS supplier_code,
    s.legal_name AS supplier_name,
    sc.cert_type_code,
    sc.cert_no,
    sc.issuing_body,
    sc.valid_from,
    sc.valid_until,
    certificate_expiry_status(sc.valid_until, ct.disposition, ct.warn_lead_days) AS status
   FROM supplier_compliance sc
     JOIN suppliers s ON s.id = sc.supplier_id
     JOIN certificate_types ct ON ct.code = sc.cert_type_code
  WHERE sc.deleted_at IS NULL AND s.deleted_at IS NULL AND has_permission('module.suppliers.view'::text);

COMMENT ON VIEW public.supplier_certificate_status IS
    'SYSTEM-MAP-2:供应商证书总览,每张在册证书一行,带 status(certificate_expiry_status —— 与提醒页同一支判据)。属主权限 + module.suppliers.view;只读。';

REVOKE ALL ON public.supplier_certificate_status FROM authenticated, anon;
GRANT SELECT ON public.supplier_certificate_status TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
