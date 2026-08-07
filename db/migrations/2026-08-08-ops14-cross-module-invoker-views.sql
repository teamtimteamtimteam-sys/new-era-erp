-- db/migrations/2026-08-08-ops14-cross-module-invoker-views.sql
-- OPS-14:【行级的 OPS-13】。一个 security_invoker 视图跨模块 JOIN 时,它不是在
-- 限制,而是在【说谎】。
--
-- OPS-13(colreader)问的是:invoker 视图读的【列】,调用者读得到吗?读不到就
-- 42501,响亮。本条问的是另一半:invoker 视图读的【行】,调用者读得到吗?读不到
-- 就【安静地消失】—— 内连接掉整行,外连接掉成 NULL,聚合掉成 0,而视图的派生列
-- 是从这些行算出来的。没有报错,只有一个错的答案。
--
-- 【普查先行】pg_depend(视图→基表)× pg_policy(基表的 SELECT 谓词)提取
-- module.<x>.view,不解析 SQL。全库 49 个视图:34 属主权限、14 拼 'on'、1 拼
-- 'true'(processing_metal_recovery)—— 只认 'on' 会检查 15 个里的 14 个,
-- 与 OPS-13 同一个陷阱,先踩后避。15 个 invoker 视图里 11 个跨模块。
--
-- 【线上已经错了五处,全部探针实测(回滚型)】
--   1. processing_run_allocation_status —— journal_entries/sales_records 挂 finance,
--      price_history 挂 inbound。operations(有 processing、无 finance)读到
--      safe_to_reallocate = NULL(真值 true),而 /processing/[id] 在这个布尔上分支,
--      NULL 是 falsy → 一张完全可以重跑的加工单上挂着【红色】"不能安全重跑"。
--      更要命的是第三条:price_history 是三个过期源之一,少了它 is_stale 【低报】——
--      过期的单读起来是新鲜的,这是危险的那个方向。
--   2. purchase_order_status —— PO-2026-0001 预付 admin 读 35,000.00,
--      procurement 读 0.00。付过的定金,对最该知道的那个角色显示成没付。
--   3. ap_open_items —— IN-2026-0029:admin 读 已结 30,000 / 未结 18,000;
--      procurement 读 已结 0 / 未结 48,000。付了一大半的应付,读起来一分没付。
--   4. hr_alerts —— finance_settings 挂 finance,而 system_start_not_set 那支写的是
--      NOT EXISTS(...)。RLS 让行消失 → NOT EXISTS 恒真 → 【日期明明填了
--      (2026-08-01),hr 角色却永远看见这条告警】,而且他无论如何也清不掉,
--      因为驱动它的那张表他读不到。行消失在这里制造的是【假阳性】,与 1 相反 ——
--      同一个病,两个方向。
--   5. batch_assay_status —— INNER JOIN suppliers/materials。admin 读 10 行,
--      operations 与 warehouse 读 【0 行】,而他们看得见全部 10 个进料批。
--      /inbound 用它渲染"有未执行化验"的角标,于是这两个角色永远不会被告知。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【两种修法,不可互换】
--   (a) 属主权限 + 把【读者自己模块】的谓词写进视图体,跨模块那几列以属主身份算 ——
--       当借来的列是【派生事实】(一个计数、一个布尔、一个标签)而不是金额时用它。
--   (b) 拆分:读者看不见的那一支【缺席】而不是错 —— 当借来的列是【金额】时用它。
--
-- 逐视图的判断写在各自的 CREATE 前面。
--
-- 【属主权限为什么不放宽模块边界】被它读的 <表>_masked 伴生视图本身就是属主权限 +
-- has_permission() 谓词,而 has_permission() 是 SECURITY DEFINER、按 auth.uid() 解析
-- 【调用者】的权限 —— 与谁拥有外层视图无关。所以改成属主权限之后,模块与数据类
-- 的把关【一字未动】,变的只有:RLS 基表不再逐行消失。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【主数据标签跟着单据走 —— Tim 2026-08-08 的裁定,记在这里因为它确实放宽了】
-- 六个视图(ap/ar/invoice_status/batch_assay_status/po_receivable_lines/
-- purchase_order_status)向 suppliers / customers / materials 借的【只有名字】——
-- 逐个核过:sup.legal_name、c.legal_name、m.name,加一个 join 键 id,再无其他。
--
-- 裁定:【标识交易对手的显示标签是单据的属性,不是另一个秘密】。看得见这张应付,
-- 就看得见它是欠谁的。给了金额却扣着名字,什么也没保护;而今天的行为 —— 整行掉光,
-- 10 行读成 0 行 —— 是【积极地错】。
--
-- 【配套的边界,免得这条变成通行证】只有显示【标签】跟着单据走。实质性的主数据
-- 属性 —— 银行账户、信用条款、价格档案、联系人 —— 不跟,继续待在自己的模块后面。
-- 将来哪个视图借的不止是一个名字,【报出来,不要顺手并进去】。
--
-- 被否掉的方案与理由:改 LEFT JOIN、名字留 NULL。空白的名字读起来是【数据缺失】,
-- 不是【权限答复】—— 那正是 lib/permissions.ts 存在的理由所描述的失败方式。
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 【本迁移只动视图,不动任何表、策略、授权】。11 个视图彼此无依赖(pg_depend 核过),
-- 也没有别的视图依赖它们,所以逐个 DROP + CREATE 是安全的。

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1. processing_run_allocation_status —— 修法 (a),module.processing.view
--    借来的:journal_entries.status(布尔的原料)、sales_records 计数、
--            price_history.created_at(时间戳)。没有一个是金额,而加工的人
--            【需要真答案才能干活】—— 这正是 Tim 的判断,确认。
-- ───────────────────────────────────────────────────────────────────────────
DROP VIEW public.processing_run_allocation_status;
CREATE VIEW public.processing_run_allocation_status WITH (security_invoker = off) AS
 SELECT r.id AS run_id,
    r.code,
    r.allocated_at,
    c.last_cost_change,
    r.allocated_at IS NOT NULL AND c.last_cost_change IS NOT NULL AND c.last_cost_change > r.allocated_at AS is_stale,
    COALESCE(g.cogs_posted, 0::bigint) AS cogs_posted,
    (r.capitalization_entry_id IS NULL OR je.status = 'posted') AS safe_to_reallocate
   FROM processing_runs r
     LEFT JOIN journal_entries je ON je.id = r.capitalization_entry_id
     LEFT JOIN LATERAL ( SELECT max(x.ts) AS last_cost_change
           FROM ( SELECT GREATEST(e.created_at, e.updated_at) AS ts
                    FROM processing_cost_entries e
                   WHERE e.run_id = r.id
                  UNION ALL
                  SELECT ph.created_at
                    FROM price_history ph
                    JOIN processing_inputs pi ON pi.inbound_batch_id = ph.inbound_batch_id
                   WHERE pi.run_id = r.id
                  UNION ALL
                  SELECT r2.allocated_at
                    FROM processing_inputs pi2
                    JOIN processing_outputs po2 ON po2.output_batch_id = pi2.output_batch_id
                    JOIN processing_runs r2 ON r2.id = po2.run_id
                   WHERE pi2.run_id = r.id AND r2.allocated_at IS NOT NULL) x) c ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS cogs_posted
           FROM sales_records sr
             JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = r.id
          WHERE sr.cogs_entry_id IS NOT NULL) g ON true
  WHERE r.deleted_at IS NULL AND has_permission('module.processing.view'::text);

GRANT SELECT ON public.processing_run_allocation_status TO authenticated;

-- ───────────────────────────────────────────────────────────────────────────
-- 2. hr_alerts —— 修法 (a),module.hr.view
--    借来的:EXISTS(finance_settings.system_start_date) —— 一个关于配置的布尔。
--    谓词写在【外层】而不是逐支重复:12 支的可见性是同一个,复述 12 遍只会
--    给下一个加支的人留一个漏写的机会。
--    【放弃了什么】原先 invoker 时,employees 的 "select own row" 策略让零 HR 权限的
--    员工能读到关于自己的那几支。全库没有任何页面这么用(只有 /hr 与 /hr/training
--    读本视图,两者都在 HR 模块内),/me 与 /my-reviews 走的是 my_profile /
--    my_leave_balance / my_review_subjects。故无损失,记录在此以备回查。
-- ───────────────────────────────────────────────────────────────────────────
DROP VIEW public.hr_alerts;
CREATE VIEW public.hr_alerts WITH (security_invoker = off) AS
 SELECT a.alert_type, a.severity, a.employee_id, a.employee_code, a.employee_name,
        a.subject, a.due_date, a.days_remaining
 FROM (
 SELECT 'work_pass_expiry'::text AS alert_type,
        CASE
            WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    COALESCE(e.work_pass_type, 'Work pass'::text) AS subject,
    e.work_pass_expiry_date AS due_date,
    e.work_pass_expiry_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND e.work_pass_expiry_date IS NOT NULL AND (e.work_pass_expiry_date - CURRENT_DATE) <= 90 AND (e.work_pass_expiry_date - CURRENT_DATE) >= '-30'::integer
UNION ALL
 SELECT 'probation_ending'::text AS alert_type,
        CASE
            WHEN (e.probation_end_date - CURRENT_DATE) <= 14 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation'::text AS subject,
    e.probation_end_date AS due_date,
    e.probation_end_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND e.probation_end_date IS NOT NULL AND e.probation_end_date >= CURRENT_DATE AND (e.probation_end_date - CURRENT_DATE) <= 30 AND NOT (EXISTS ( SELECT 1
           FROM performance_reviews r
          WHERE r.employee_id = e.id AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome = 'confirm'::text))
UNION ALL
 SELECT 'probation_overdue'::text AS alert_type,
    'expired'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation ended without a decision'::text AS subject,
    e.probation_end_date AS due_date,
    e.probation_end_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND e.probation_end_date IS NOT NULL AND e.probation_end_date < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
           FROM performance_reviews r
          WHERE r.employee_id = e.id AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome IS NOT NULL))
UNION ALL
 SELECT 'probation_not_confirmed'::text AS alert_type,
    'expired'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation not confirmed — separation is a manual decision'::text AS subject,
    COALESCE(e.probation_end_date, r.approved_at::date) AS due_date,
    COALESCE(e.probation_end_date, r.approved_at::date) - CURRENT_DATE AS days_remaining
   FROM employees e
     JOIN performance_reviews r ON r.employee_id = e.id
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome = 'not_confirm'::text
UNION ALL
 SELECT 'salary_not_set'::text AS alert_type,
        CASE
            WHEN e.employment_status = 'notice'::text THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Monthly fixed gross not set — leave encashment cannot be computed'::text AS subject,
    NULL::date AS due_date,
    NULL::integer AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND (e.employment_status = ANY (ARRAY['probation'::text, 'active'::text, 'notice'::text])) AND NOT e.monthly_salary_set
UNION ALL
 SELECT 'review_no_reviewer'::text AS alert_type,
    'critical'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    COALESCE(c.name, 'Probation review'::text) || ' — no reviewer assigned'::text AS subject,
    c.due_date,
    c.due_date - CURRENT_DATE AS days_remaining
   FROM performance_reviews r
     JOIN employees e ON e.id = r.employee_id
     LEFT JOIN review_cycles c ON c.id = r.cycle_id
  WHERE r.reviewer_employee_id IS NULL AND (r.status <> ALL (ARRAY['approved'::text, 'acknowledged'::text, 'void'::text])) AND e.deleted_at IS NULL
UNION ALL
 SELECT 'review_cycle_overdue'::text AS alert_type,
    'critical'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    c.name AS subject,
    c.due_date,
    c.due_date - CURRENT_DATE AS days_remaining
   FROM performance_reviews r
     JOIN review_cycles c ON c.id = r.cycle_id
     JOIN employees e ON e.id = r.employee_id
  WHERE c.deleted_at IS NULL AND c.status = 'open'::text AND c.due_date < CURRENT_DATE AND (r.status = ANY (ARRAY['draft'::text, 'self_review'::text]))
UNION ALL
 SELECT 'cpf_due'::text AS alert_type,
        CASE
            WHEN (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date < CURRENT_DATE THEN 'expired'::text
            WHEN ((date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE) <= 3 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    NULL::uuid AS employee_id,
    p.code AS employee_code,
    'CPF'::text AS employee_name,
    'CPF contribution unpaid — due 14th of the following month, late payment attracts interest'::text AS subject,
    (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date AS due_date,
    (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE AS days_remaining
   FROM payroll_periods p
  WHERE p.deleted_at IS NULL AND p.status = 'posted'::text AND p.cpf_paid_at IS NULL AND (COALESCE(p.employer_cpf_total, 0::numeric) + COALESCE(p.employee_cpf_total, 0::numeric)) > 0::numeric AND ((date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE) <= 7
UNION ALL
 SELECT 'training_expiry'::text AS alert_type,
        CASE
            WHEN t.expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (t.expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    t.training_name AS subject,
    t.expiry_date AS due_date,
    t.expiry_date - CURRENT_DATE AS days_remaining
   FROM training_records t
     JOIN employees e ON e.id = t.employee_id
  WHERE t.deleted_at IS NULL AND e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND t.expiry_date IS NOT NULL AND (t.expiry_date - CURRENT_DATE) <= 90 AND (t.expiry_date - CURRENT_DATE) >= '-30'::integer
UNION ALL
 SELECT 'holiday_calendar_missing'::text AS alert_type,
    'expired'::text AS severity,
    NULL::uuid AS employee_id,
    ''::text AS employee_code,
    ''::text AS employee_name,
    EXTRACT(year FROM CURRENT_DATE)::text AS subject,
    CURRENT_DATE AS due_date,
    0 AS days_remaining
  WHERE NOT (EXISTS ( SELECT 1
           FROM public_holidays h
          WHERE h.is_active AND h.country = 'SG'::text AND EXTRACT(year FROM h.holiday_date) = EXTRACT(year FROM CURRENT_DATE)))
UNION ALL
 SELECT 'holiday_calendar_next_year'::text AS alert_type,
        CASE
            WHEN EXTRACT(month FROM CURRENT_DATE) = 12::numeric THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    NULL::uuid AS employee_id,
    ''::text AS employee_code,
    ''::text AS employee_name,
    (EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::text AS subject,
    make_date((EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::integer, 1, 1) AS due_date,
    make_date((EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::integer, 1, 1) - CURRENT_DATE AS days_remaining
  WHERE EXTRACT(month FROM CURRENT_DATE) >= 10::numeric AND NOT (EXISTS ( SELECT 1
           FROM public_holidays h
          WHERE h.is_active AND h.country = 'SG'::text AND EXTRACT(year FROM h.holiday_date) = (EXTRACT(year FROM CURRENT_DATE) + 1::numeric)))
UNION ALL
 SELECT 'system_start_not_set'::text AS alert_type,
    'expired'::text AS severity,
    NULL::uuid AS employee_id,
    ''::text AS employee_code,
    ''::text AS employee_name,
    ''::text AS subject,
    CURRENT_DATE AS due_date,
    0 AS days_remaining
  WHERE NOT (EXISTS ( SELECT 1
           FROM finance_settings s
          WHERE s.system_start_date IS NOT NULL))
 ) a
 WHERE has_permission('module.hr.view'::text);

-- ───────────────────────────────────────────────────────────────────────────
-- 3. processing_metal_recovery —— 修法 (a),module.processing.view
--    借来的:inbound_batch_metals / output_batch_metals 的 content_pct(重量百分比)
--    与产出批的量。是工艺数字,不是钱。少了它们 input_metal_kg 会低报,而
--    回收率【高报】—— 与 FIN-25 修掉的那个方向完全一样,只是这次的原因是 RLS。
-- ───────────────────────────────────────────────────────────────────────────
DROP VIEW public.processing_metal_recovery;
CREATE VIEW public.processing_metal_recovery WITH (security_invoker = off) AS
WITH ins AS (
    SELECT pi.run_id, m.metal,
           SUM(pi.quantity_consumed * m.content_pct / 100.0) AS input_metal_kg
    FROM public.processing_inputs pi
    JOIN LATERAL (
        SELECT ibm.metal, ibm.content_pct
        FROM public.inbound_batch_metals ibm
        WHERE ibm.inbound_batch_id = pi.inbound_batch_id
        UNION ALL
        SELECT obm.metal, obm.content_pct
        FROM public.output_batch_metals obm
        WHERE obm.output_batch_id = pi.output_batch_id
    ) m ON true
    GROUP BY pi.run_id, m.metal
),
outs AS (
    SELECT po.run_id, obm.metal,
           SUM(po.quantity_produced * obm.content_pct / 100.0) AS output_metal_kg
    FROM public.processing_outputs po
    JOIN public.output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
    GROUP BY po.run_id, obm.metal
)
SELECT r.id            AS run_id,
       r.code          AS run_code,
       r.process_date,
       COALESCE(i.metal, o.metal) AS metal,
       COALESCE(i.input_metal_kg, 0)  AS input_metal_kg,
       COALESCE(o.output_metal_kg, 0) AS output_metal_kg,
       CASE WHEN COALESCE(i.input_metal_kg, 0) = 0 THEN NULL
            ELSE round(COALESCE(o.output_metal_kg, 0) / i.input_metal_kg * 100, 2)
       END AS recovery_pct
FROM ins i
FULL JOIN outs o ON o.run_id = i.run_id AND o.metal = i.metal
JOIN public.processing_runs r ON r.id = COALESCE(i.run_id, o.run_id)
WHERE r.status = 'committed' AND r.deleted_at IS NULL
  AND has_permission('module.processing.view'::text);

GRANT SELECT ON public.processing_metal_recovery TO authenticated;

-- ───────────────────────────────────────────────────────────────────────────
-- 4. batch_lineage —— 修法 (a),module.processing.view
--    借来的:inbound_batches.code / output_batches.code —— 祖先批次的【编号】,
--    也就是标签。血缘本身是加工的概念(递归的起点是 processing_outputs),
--    所以模块就是 processing;少了两个 code,链条会变成一串 NULL,
--    而"可溯"正是立账公理。
-- ───────────────────────────────────────────────────────────────────────────
DROP VIEW public.batch_lineage;
CREATE VIEW public.batch_lineage WITH (security_invoker = off) AS
WITH RECURSIVE up AS (
    SELECT po.output_batch_id AS batch_id,
           pr.id AS via_run_id, pr.code AS via_run_code,
           pi.inbound_batch_id AS parent_inbound_id,
           pi.output_batch_id  AS parent_output_id,
           pi.quantity_consumed, 1 AS depth
    FROM public.processing_outputs po
    JOIN public.processing_runs pr ON pr.id = po.run_id AND pr.deleted_at IS NULL
    JOIN public.processing_inputs pi ON pi.run_id = pr.id
  UNION ALL
    SELECT up.batch_id, pr2.id, pr2.code,
           pi2.inbound_batch_id, pi2.output_batch_id,
           pi2.quantity_consumed, up.depth + 1
    FROM up
    JOIN public.processing_outputs po2 ON po2.output_batch_id = up.parent_output_id
    JOIN public.processing_runs pr2 ON pr2.id = po2.run_id AND pr2.deleted_at IS NULL
    JOIN public.processing_inputs pi2 ON pi2.run_id = pr2.id
    WHERE up.parent_output_id IS NOT NULL
)
SELECT up.batch_id AS output_batch_id,
       up.depth,
       up.via_run_id,
       up.via_run_code,
       CASE WHEN up.parent_inbound_id IS NOT NULL THEN 'inbound' ELSE 'output' END AS parent_kind,
       COALESCE(up.parent_inbound_id, up.parent_output_id) AS parent_batch_id,
       COALESCE(ib.code, ob.code) AS parent_code,
       up.quantity_consumed
FROM up
LEFT JOIN public.inbound_batches ib ON ib.id = up.parent_inbound_id
LEFT JOIN public.output_batches ob ON ob.id = up.parent_output_id
WHERE has_permission('module.processing.view'::text);

GRANT SELECT ON public.batch_lineage TO authenticated;

-- ───────────────────────────────────────────────────────────────────────────
-- 5. batch_assay_status —— 修法 (a),module.inbound.view
--    借来的:sup.legal_name、m.name —— 只有两个标签。见文件头的裁定。
--    今天:admin 10 行,operations / warehouse 【0 行】。
-- ───────────────────────────────────────────────────────────────────────────
DROP VIEW public.batch_assay_status;
CREATE VIEW public.batch_assay_status WITH (security_invoker = off) AS
 SELECT ib.id AS inbound_batch_id,
    ib.code AS batch_code,
    sup.legal_name AS supplier_name,
    m.name AS material_name,
    ib.quantity,
    ib.unit,
    ib.unit_price,
    ib.pricing_status,
    ib.pricing_formula_id,
    pf.code AS formula_code,
    COALESCE(a.assay_count, 0::bigint) AS assay_count,
    a.latest_assay_id,
    a.latest_assay_code,
    a.latest_assay_date,
    COALESCE(a.latest_assay_applied, false) AS latest_assay_applied,
    COALESCE(a.has_unapplied_assay, false) AS has_unapplied_assay,
    ib.purchase_order_id,
    po.code AS po_code
   FROM inbound_batches_masked ib
     JOIN suppliers sup ON sup.id = ib.supplier_id
     JOIN materials m ON m.id = ib.material_id
     LEFT JOIN pricing_formulas_masked pf ON pf.id = ib.pricing_formula_id
     LEFT JOIN purchase_orders_masked po ON po.id = ib.purchase_order_id
     LEFT JOIN LATERAL ( SELECT count(*) AS assay_count,
            bool_or(ar.applied_at IS NULL) AS has_unapplied_assay,
            (array_agg(ar.id ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_id,
            (array_agg(ar.code ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_code,
            (array_agg(ar.assay_date ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_date,
            (array_agg(ar.applied_at IS NOT NULL ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_applied
           FROM assay_results ar
          WHERE ar.inbound_batch_id = ib.id AND ar.deleted_at IS NULL) a ON true
  WHERE ib.deleted_at IS NULL AND has_permission('module.inbound.view'::text);

-- ───────────────────────────────────────────────────────────────────────────
-- 6. po_receivable_lines —— 修法 (a),module.purchasing.view
--    借来的:sup.legal_name、m.name —— 两个标签。
-- ───────────────────────────────────────────────────────────────────────────
DROP VIEW public.po_receivable_lines;
CREATE VIEW public.po_receivable_lines WITH (security_invoker = off) AS
 SELECT po.id AS po_id,
    po.code AS po_code,
    po.supplier_id,
    sup.legal_name AS supplier_name,
    po.order_date,
    pol.id AS line_id,
    pol.line_no,
    pol.material_id,
    m.name AS material_name,
    pol.quantity AS ordered_qty,
    pol.unit,
    round(COALESCE(rec.qty, 0::numeric), 4) AS received_qty,
    round(GREATEST(pol.quantity - COALESCE(rec.qty, 0::numeric), 0::numeric), 4) AS remaining_qty,
    pol.pricing_formula_id,
    pol.estimated_unit_price,
    pol.expected_assay
   FROM purchase_orders_masked po
     JOIN suppliers sup ON sup.id = po.supplier_id
     JOIN purchase_order_lines_masked pol ON pol.purchase_order_id = po.id
     JOIN materials m ON m.id = pol.material_id
     LEFT JOIN LATERAL ( SELECT sum(ib.quantity) AS qty
           FROM inbound_batches_masked ib
          WHERE ib.purchase_order_line_id = pol.id AND ib.deleted_at IS NULL) rec ON true
  WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
    AND has_permission('module.purchasing.view'::text);

-- ───────────────────────────────────────────────────────────────────────────
-- 7. ap_open_items —— 修法 (b),整表挂 module.finance.view
--    借来的是【金额】:payment_allocations / payments 的核销额。
--    为什么整表而不是把 settled/open 遮成 NULL:本视图的【存在判据】就是
--    `WHERE open_ccy > 0` —— 行在不在,取决于一个财务计算。遮成 NULL 会把
--    整张表过滤空,那不是"缺席",那是另一种谎。所以缺席的单位是【整张视图】:
--    没有财务模块就 0 行,由一条明写的谓词给出,而不是 JOIN 悄悄掉行。
--    supplier 标签跟着单据走(见文件头裁定)。
--    今天:IN-2026-0029 admin 已结 30,000 / 未结 18,000;procurement 0 / 48,000。
-- ───────────────────────────────────────────────────────────────────────────
DROP VIEW public.ap_open_items;
CREATE VIEW public.ap_open_items WITH (security_invoker = off) AS
 SELECT doc_kind,
    doc_id,
    doc_code,
    inbound_batch_id,
    supplier_id,
    supplier_name,
    doc_date,
    doc_value_base,
    settled_base,
    open_base,
    currency,
    open_ccy,
    CURRENT_DATE - doc_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - doc_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - doc_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - doc_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket
   FROM ( SELECT 'inbound'::text AS doc_kind,
            ib.id AS doc_id,
            ib.code AS doc_code,
            ib.id AS inbound_batch_id,
            ib.supplier_id,
            sup.legal_name AS supplier_name,
            COALESCE(ib.arrival_date, ib.created_at::date) AS doc_date,
            round(ib.quantity * ib.unit_price, 2) AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric), 2) AS settled_base,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_base,
            ( SELECT c.code
                   FROM currencies c
                  WHERE c.is_base) AS currency,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_ccy
           FROM inbound_batches_masked ib
             JOIN suppliers sup ON sup.id = ib.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.inbound_batch_id = ib.id) s ON true
             LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
                   FROM prepayment_applications_masked ppa
                  WHERE ppa.inbound_batch_id = ib.id) pp ON true
          WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL
        UNION ALL
         SELECT 'expense'::text AS doc_kind,
            e.id AS doc_id,
            e.code AS doc_code,
            NULL::uuid AS inbound_batch_id,
            e.supplier_id,
            sup.legal_name AS supplier_name,
            e.expense_date AS doc_date,
            e.amount_base AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric) * e.fx_rate, 2) AS settled_base,
            round((e.amount_ccy - COALESCE(s.settled, 0::numeric)) * e.fx_rate, 2) AS open_base,
            e.currency,
            round(e.amount_ccy - COALESCE(s.settled, 0::numeric), 2) AS open_ccy
           FROM expenses e
             JOIN suppliers sup ON sup.id = e.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.expense_id = e.id) s ON true
          WHERE e.payment_status = 'unpaid'::text AND e.status = 'posted'::text AND NOT (EXISTS ( SELECT 1
                   FROM expenses o
                  WHERE o.reversed_by_expense = e.id))) d
  WHERE open_ccy > 0::numeric AND has_permission('module.finance.view'::text);

-- ───────────────────────────────────────────────────────────────────────────
-- 8. ar_open_items —— 修法 (b),整表挂 module.finance.view(理由同 7:
--    存在判据 `未结 > 0` 本身就是财务计算)。customer 标签与产出批 code
--    跟着单据走。
-- ───────────────────────────────────────────────────────────────────────────
DROP VIEW public.ar_open_items;
CREATE VIEW public.ar_open_items WITH (security_invoker = off) AS
 SELECT sr.id AS sales_record_id,
    ob.code AS doc_code,
    sr.customer_id,
    c.legal_name AS customer_name,
    sr.sale_date,
    sr.amount_base,
    sr.currency,
    round(sr.quantity * sr.unit_price, 2) AS amount_ccy,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_ccy,
    round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric), 2) AS open_ccy,
    round((sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric)) * sr.fx_rate, 2) AS open_base,
    CURRENT_DATE - sr.sale_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - sr.sale_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket,
    inv.invoice_id,
    inv.invoice_code
   FROM sales_records_masked sr
     JOIN output_batches ob ON ob.id = sr.output_batch_id
     LEFT JOIN customers c ON c.id = sr.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.sales_record_id = sr.id) s ON true
     LEFT JOIN LATERAL ( SELECT i.id AS invoice_id,
            i.code AS invoice_code
           FROM invoice_lines_masked il
             JOIN invoices_masked i ON i.id = il.invoice_id
          WHERE il.sales_record_id = sr.id AND NOT il.invoice_voided
         LIMIT 1) inv ON true
  WHERE round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric), 2) > 0::numeric
    AND has_permission('module.finance.view'::text);

-- ───────────────────────────────────────────────────────────────────────────
-- 9. invoice_status —— 修法 (b),整表挂 module.finance.view(payment_state 与
--    open_base 都是从核销额推的)。customer 标签跟着单据走。
-- ───────────────────────────────────────────────────────────────────────────
DROP VIEW public.invoice_status;
CREATE VIEW public.invoice_status WITH (security_invoker = off) AS
 SELECT i.id AS invoice_id,
    i.code,
    i.customer_id,
    c.legal_name AS customer_name,
    i.issue_date,
    i.due_date,
    i.currency,
    i.total_base,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_base,
    round(i.total_base - COALESCE(s.settled, 0::numeric), 2) AS open_base,
    GREATEST(CURRENT_DATE - i.due_date, 0) AS days_overdue,
        CASE
            WHEN round(i.total_base - COALESCE(s.settled, 0::numeric), 2) <= 0::numeric THEN 'paid'::text
            WHEN COALESCE(s.settled, 0::numeric) > 0::numeric THEN 'partial'::text
            ELSE 'unpaid'::text
        END AS payment_state,
    CURRENT_DATE > i.due_date AND round(i.total_base - COALESCE(s.settled, 0::numeric), 2) > 0::numeric AS overdue
   FROM invoices_masked i
     JOIN customers c ON c.id = i.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled
           FROM invoice_lines_masked il
             JOIN payment_allocations pa ON pa.sales_record_id = il.sales_record_id
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE il.invoice_id = i.id) s ON true
  WHERE i.status <> 'void'::text AND has_permission('module.finance.view'::text);

-- ───────────────────────────────────────────────────────────────────────────
-- 10. po_prepayment_applicable —— 修法 (b),整表挂 module.finance.view。
--     本视图算的是"能抵多少",而 apply_prepayment 要 module.finance.edit ——
--     所以它本来就只服务财务这一个动作。它的模块集在目录里【看起来只有一个】
--     (采购/进料那一侧是经 <表>_masked 进来的,不是 RLS 基表),于是 OPS-14 的
--     新判据【看不见它】—— 但病是一样的:没有财务的读者会把 settled 读成 0,
--     applicable_base 因此偏大。写在这里,免得那条判据的绿被读成"到处都干净"。
-- ───────────────────────────────────────────────────────────────────────────
DROP VIEW public.po_prepayment_applicable;
CREATE VIEW public.po_prepayment_applicable WITH (security_invoker = off) AS
 SELECT ib.id AS inbound_batch_id,
    ib.code AS batch_code,
    po.id AS purchase_order_id,
    po.code AS po_code,
    po.supplier_id,
    round(round(ib.quantity * ib.unit_price, 2) - COALESCE(pay.settled, 0::numeric) - COALESCE(app_b.applied, 0::numeric), 2) AS batch_ap_open_base,
    round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2) AS po_unapplied_prepayment_base,
    GREATEST(LEAST(round(round(ib.quantity * ib.unit_price, 2) - COALESCE(pay.settled, 0::numeric) - COALESCE(app_b.applied, 0::numeric), 2), round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2)), 0::numeric) AS applicable_base
   FROM inbound_batches_masked ib
     JOIN purchase_orders_masked po ON po.id = ib.purchase_order_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.inbound_batch_id = ib.id) pay ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
           FROM prepayment_applications_masked ppa
          WHERE ppa.inbound_batch_id = ib.id) app_b ON true
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS prepaid
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.purchase_order_id = po.id) pre ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
           FROM prepayment_applications_masked ppa
          WHERE ppa.purchase_order_id = po.id) app_po ON true
  WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL
    AND GREATEST(LEAST(round(round(ib.quantity * ib.unit_price, 2) - COALESCE(pay.settled, 0::numeric) - COALESCE(app_b.applied, 0::numeric), 2), round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2)), 0::numeric) > 0::numeric
    AND has_permission('module.finance.view'::text);

-- ───────────────────────────────────────────────────────────────────────────
-- 11. purchase_order_status —— 混合:行的存在判据是【采购】的
--     (在册、未取消),只有三列预付是【财务】的金额。所以不是整表挂财务,
--     而是修法 (b) 的列形态:三列在无 module.finance.view 时【置 NULL】。
--
--     【为什么 NULL 而不是拆成第二张视图】仓库对"你不该看见的金额"已经有一条
--     成熟的表达 —— cut 2b 的遮蔽列 + lib/permissions.ts 把 null 解释成「受限」。
--     NULL 就是"缺席",而 0.00 是"错"。拆视图能达到同样效果,但会把一行 PO
--     劈成两处读,收益为零。列即是"支"。
--     supplier 标签跟着单据走。
--     今天:PO-2026-0001 预付 admin 35,000.00,procurement 0.00。
-- ───────────────────────────────────────────────────────────────────────────
DROP VIEW public.purchase_order_status;
CREATE VIEW public.purchase_order_status WITH (security_invoker = off) AS
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
        END AS receipt_pct
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

COMMIT;
