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
