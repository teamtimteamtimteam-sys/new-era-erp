-- db/views/inbound_batch_valuation.sql
-- INV-VAL-1(fu6 起):它只是 inbound_batch_valuation_rows() 的一层壳。
-- 【WITH (security_invoker = off) 必须写在这里】pg_get_viewdef 不吐 reloptions,
-- 照它重建镜像会把这一句悄悄丢掉(AGENTS.md 记着 PAYEE-1a 为此付过一次账);
-- 而 fu6 第一版的 CREATE OR REPLACE 没带 WITH,线上真的丢过一次,已补回。

CREATE VIEW public.inbound_batch_valuation WITH (security_invoker = off) AS
 SELECT id,
    code,
    material_id,
    supplier_id,
    unit,
    quantity,
    remaining_qty,
    arrival_date,
    stage,
    landed_unit_cost,
    landed_value_base,
    unpriced,
    aging_days,
    aging_bucket
   FROM inbound_batch_valuation_rows() inbound_batch_valuation_rows(id, code, material_id, supplier_id, unit, quantity, remaining_qty, arrival_date, stage, landed_unit_cost, landed_value_base, unpriced, aging_days, aging_bucket);

COMMENT ON VIEW public.inbound_batch_valuation IS
    'INV-VAL-1:进料批次的【唯一】估值读取器 —— 口径 inbound_batch_landed_unit_cost(采购价 + 运费 + 已资本化加工成本),与注销、盘点、gl_control_reconciliation 同一份定义。fu6 起它只是 inbound_batch_valuation_rows() 的一层壳:视图的属主权限替不了函数的 EXECUTE,而那支成本函数刻意未授权给 authenticated,所以取数必须发生在一支 SECURITY DEFINER 函数里(那才改变 current_user)。landed_* 按 data.view_prices 遮蔽成 NULL(不是 0);unpriced 不遮蔽 —— "有没有价"是事实不是价。';

GRANT SELECT ON public.inbound_batch_valuation TO authenticated;
