-- INV-VAL-1-fu1:屏幕必须读【同一个口径】——(R1 / R4,STEP 3)
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么是一张视图,而不是把那支函数授给 authenticated】
--
-- /inventory 至今按 inbound_batches.unit_price 估值,而注销、盘点、勾稽三条路
-- 都按 inbound_batch_landed_unit_cost。**同一批货,两个"它值多少钱"的表达式**
-- —— 那是 INV-VAL-0 记的 M2,今天为零(运费与加工成本载体都被冲销了),
-- 而它会在【第一张不被冲销的运费单过账的那一刻】静默地不为零。
--
-- 最省事的做法是把 inbound_batch_landed_unit_cost 授给 authenticated。**不行。**
-- 那支函数是 SECURITY DEFINER,【直接读基表的 unit_price】,绕过
-- inbound_batches_masked 的 data.view_prices 遮蔽,而且它自己不做任何权限判断。
-- 授出去 = 把采购单价发给每一个 authenticated 用户,包括 operations 与
-- warehouse —— 那两个角色实测【正是】没有 data.view_prices 的那一类。
--
-- 所以本刀开一张视图,把遮蔽加回来:
--   · 属主权限(security_invoker = off)+ 体内 has_permission —— 与
--     stock_snapshot / inbound_batches_masked 同一形状(invoker 会让 RLS 丢行,
--     而聚合里丢一行等于报出一个错的余额);
--   · landed_unit_cost 按 data.view_prices 遮蔽 → 无权限者得 NULL,不是 0;
--   · **unpriced 不遮蔽** —— "这批货有没有价"不是价格本身,而它正是
--     "102,071 kg 计在量里、不计在钱里"这句话的判据,谁都该看得见。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★【库龄:第二份档位定义在这里被退休,而退休必须是【删掉】,不是【绕开】】★(R4)
--
-- 库里有两份档位定义:
--   · aging_bucket(DB,IMMUTABLE,0-30 / 31-60 / 61-90 / 90+,五个消费方,
--     AGING-1 明写它被抽出来正是因为边界写了三遍);
--   · lib/valuation.ts 的 AGING_BANDS(TS,**30 / 90**,两档半)。
-- 两份的边界【本来就不一样】:一批 75 天的货在 DB 里是 b61_90,在屏幕上是
-- "warn"(31–90 那一档)。没有人报过这个 bug,因为 TS 那份只用来上色。
--
-- 本视图把 aging_bucket 的结果【带出来】,于是 TS 侧不再需要知道任何边界 ——
-- 它只把档位映射成颜色。AGING_BANDS 因此可以真的删掉,而不是"留着但不调用"。
-- **一份留着不调用的第二定义,下一个人一定会调用它。**
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE VIEW public.inbound_batch_valuation WITH (security_invoker = off) AS
 SELECT ib.id,
    ib.code,
    ib.material_id,
    ib.supplier_id,
    ib.unit,
    ib.quantity,
    ib.remaining_qty,
    ib.arrival_date,
    ib.stage,
    -- 【价格遮蔽】没有 data.view_prices 的读者得 NULL —— 不是 0,也不是一个
    -- 少算了的合计。调用方据此渲染【具名受限】。
    CASE WHEN has_permission('data.view_prices'::text)
         THEN inbound_batch_landed_unit_cost(ib.id)
         ELSE NULL::numeric END AS landed_unit_cost,
    CASE WHEN has_permission('data.view_prices'::text)
         THEN round(COALESCE(ib.remaining_qty * inbound_batch_landed_unit_cost(ib.id), 0), 2)
         ELSE NULL::numeric END AS landed_value_base,
    -- 【不遮蔽】"有没有价"是一个事实,不是价。它是 M9 的判据。
    (inbound_batch_landed_unit_cost(ib.id) IS NULL) AS unpriced,
    (CURRENT_DATE - ib.arrival_date) AS aging_days,
    -- ★ 档位【唯一一处定义】就是 aging_bucket。屏幕不再自己划边界。
    aging_bucket((CURRENT_DATE - ib.arrival_date)::integer) AS aging_bucket
   FROM inbound_batches ib
  WHERE ib.deleted_at IS NULL
    AND has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.inbound_batch_valuation IS
    'INV-VAL-1:进料批次的【唯一】估值读取器 —— 口径 inbound_batch_landed_unit_cost(采购价 + 运费 + 已资本化加工成本),与注销、盘点、gl_control_reconciliation 同一份定义。开这张视图而不是把那支函数授给 authenticated:它是 SECURITY DEFINER、直接读基表 unit_price、绕过 data.view_prices 遮蔽且自己不判权限,授出去等于把采购单价发给每一个用户(operations 与 warehouse 实测正是没有该权限的那一类)。landed_* 按 data.view_prices 遮蔽成 NULL(不是 0);unpriced 不遮蔽 —— "有没有价"是事实不是价。aging_bucket 原样带出,于是 lib/valuation.ts 的第二份 30/90 档位定义可以被删掉而不是绕开。';

GRANT SELECT ON public.inbound_batch_valuation TO authenticated;

CREATE OR REPLACE VIEW public.output_batch_valuation WITH (security_invoker = off) AS
 SELECT ob.id,
    ob.code,
    ob.material_id,
    ob.unit,
    ob.quantity,
    ob.remaining_qty,
    ob.output_date,
    ob.state,
    CASE WHEN has_permission('data.view_prices'::text)
         THEN po.unit_cost_base ELSE NULL::numeric END AS unit_cost_base,
    -- ★【三态不许长得一样】(R6)有数 / 0.00(计过价、卖光了)/ NULL(从未分摊)
    -- NULL 与 0.00 在这里【必须】是两个值:前者是"不适用",后者是"值零"。
    CASE WHEN po.unit_cost_base IS NULL THEN NULL
         WHEN has_permission('data.view_prices'::text)
         THEN round(ob.remaining_qty * po.unit_cost_base, 2)
         ELSE NULL::numeric END AS cost_value_base,
    -- 【不遮蔽】"这一腿从来没有分摊过成本"是事实,不是钱。
    (po.unit_cost_base IS NULL) AS never_costed,
    (CURRENT_DATE - ob.output_date) AS aging_days,
    aging_bucket((CURRENT_DATE - ob.output_date)::integer) AS aging_bucket
   FROM output_batches ob
   LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
  WHERE ob.deleted_at IS NULL
    AND has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.output_batch_valuation IS
    'INV-VAL-1:产出批次的估值读取器。★三态不许长得一样(R6):有数 / 0.00(计过价、货卖光了)/ NULL(从未分摊,渲染 "—")—— cost_value_base 对从未分摊的腿返回 NULL 而不是 0,因为「不适用」不是「值零」;线上 12 张在库产出批里 10 张(3,661kg / 3,816kg)属于后者。never_costed 不遮蔽:那是事实不是钱。档位取 aging_bucket,与进料侧同一份定义。';

GRANT SELECT ON public.output_batch_valuation TO authenticated;

COMMIT;
