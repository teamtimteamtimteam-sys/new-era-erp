CREATE VIEW public.output_batch_valuation WITH (security_invoker = off) AS
 SELECT ob.id,
    ob.code,
    ob.material_id,
    ob.unit,
    ob.quantity,
    ob.remaining_qty,
    ob.output_date,
    ob.state,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN po.unit_cost_base
            ELSE NULL::numeric
        END AS unit_cost_base,
        CASE
            WHEN po.unit_cost_base IS NULL THEN NULL::numeric
            WHEN has_permission('data.view_prices'::text) THEN round(ob.remaining_qty * po.unit_cost_base, 2)
            ELSE NULL::numeric
        END AS cost_value_base,
    po.unit_cost_base IS NULL AS never_costed,
    CURRENT_DATE - ob.output_date AS aging_days,
    aging_bucket(CURRENT_DATE - ob.output_date) AS aging_bucket
   FROM output_batches ob
     LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
  WHERE ob.deleted_at IS NULL AND has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.output_batch_valuation IS
    'INV-VAL-1:产出批次的估值读取器。★三态不许长得一样(R6):有数 / 0.00(计过价、货卖光了)/ NULL(从未分摊,渲染 "—")—— cost_value_base 对从未分摊的腿返回 NULL 而不是 0,因为「不适用」不是「值零」;线上 12 张在库产出批里 10 张(3,661kg / 3,816kg)属于后者。never_costed 不遮蔽:那是事实不是钱。档位取 aging_bucket,与进料侧同一份定义。';

GRANT SELECT ON public.output_batch_valuation TO authenticated;
