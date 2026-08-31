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
        CASE
            WHEN has_permission('data.view_prices'::text) THEN inbound_batch_landed_unit_cost(id)
            ELSE NULL::numeric
        END AS landed_unit_cost,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN round(COALESCE(remaining_qty * inbound_batch_landed_unit_cost(id), 0::numeric), 2)
            ELSE NULL::numeric
        END AS landed_value_base,
    inbound_batch_landed_unit_cost(id) IS NULL AS unpriced,
    CURRENT_DATE - arrival_date AS aging_days,
    aging_bucket(CURRENT_DATE - arrival_date) AS aging_bucket
   FROM inbound_batches ib
  WHERE deleted_at IS NULL AND has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.inbound_batch_valuation IS
    'INV-VAL-1:进料批次的【唯一】估值读取器 —— 口径 inbound_batch_landed_unit_cost(采购价 + 运费 + 已资本化加工成本),与注销、盘点、gl_control_reconciliation 同一份定义。开这张视图而不是把那支函数授给 authenticated:它是 SECURITY DEFINER、直接读基表 unit_price、绕过 data.view_prices 遮蔽且自己不判权限,授出去等于把采购单价发给每一个用户(operations 与 warehouse 实测正是没有该权限的那一类)。landed_* 按 data.view_prices 遮蔽成 NULL(不是 0);unpriced 不遮蔽 —— "有没有价"是事实不是价。aging_bucket 原样带出,于是 lib/valuation.ts 的第二份 30/90 档位定义可以被删掉而不是绕开。';

GRANT SELECT ON public.inbound_batch_valuation TO authenticated;
