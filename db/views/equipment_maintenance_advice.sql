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

CREATE VIEW public.equipment_maintenance_advice WITH (security_invoker = off) AS
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
