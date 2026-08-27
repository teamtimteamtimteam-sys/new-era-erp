-- db/functions/inbound_unit_price_asof.sql
-- AGING-1(2026-08-27):一张进料批次在【某一天】的单价,从 price_history 回推。
--
-- 【为什么账龄需要它】ap_open_items 的应付额是 quantity × unit_price,而 unit_price
-- 是【今天的】。实测线上 IN-2026-0001 与 IN-2026-0003 在 2026-07-06 改过价
-- (53.00→1.48、88.00→600.00),而 2026-07-05 之前九张在开批次【全部没有价】——
-- 也就是说一份用今天的价算出来的"截至 6 月 30 日"的应付账龄,会印出五张那天
-- 根本还不是可计量应付的单据,金额还是七月才定下的价。
--
-- 【调用者只有 ap_aging_asof】它是 SECURITY DEFINER,以属主身份执行,所以本函数
-- 读 price_history 基表时不受 module.inbound.view 的 RLS 影响 —— 那正是要的:
-- 读者是财务,而 price_history_masked 的门是进料。价格本身的遮蔽由调用方按
-- data.view_prices 施加,与 inbound_batches_masked.unit_price 逐字同源。
--
-- NOTE: introduced by db/migrations/2026-08-27-aging1-as-at-a-date.sql.

CREATE OR REPLACE FUNCTION public.inbound_unit_price_asof(p_batch_id uuid, p_as_of date)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
    -- 【口径:从【今天的价】往回走,不是从历史里往前找】
    -- 两种写法都能给出答案,而它们在【同一笔事务里改了两次价】时分道扬镳:
    -- `price_history.created_at` 默认 `now()`,而 `now()` 是**事务开始时刻** ——
    -- 同一笔事务里的两行【时刻完全相同】,谁先谁后这张表根本表达不出来。
    -- 第一版写的是"取 D 之前最后一次的新价",于是它必须在两个同刻行里挑一个,
    -- 而它挑的依据是 `id DESC` —— 一个随机 uuid。**同一份数据,两次运行两个答案。**
    -- (这是写 fixture 时被抓到的:两次 reprice 落在同一笔事务里,A 臂时红时绿。
    --  线上不显形,因为界面上每次改价各自是一笔事务。)
    --
    -- 现在的写法不需要在同刻行之间排序:
    --   ① D 之后【有】改价 → 取最早那一次的【旧价】,那就是 D 当天的价;
    --      首次计价那一行的 old_unit_price 【就是空的】,于是"那天还没有价"
    --      诚实地表达成 NULL,而不是被今天的价顶上去。
    --   ② D 之后【没有】改价 → 那自 D 以来就没变过,今天的价就是 D 的价。
    --      (含"一行历史都没有"的批次:实测线上这样的在册已计价批次是 0 张。)
    --
    -- 【残余的一处含糊,说出来而不是假装没有】D 严格早于某一天,而那一天里
    -- 【同一笔事务】改了两次以上价 —— 这时"最早那一次"仍然要在同刻行里挑。
    -- 它需要一笔多次改价的事务才制造得出来,而界面走不出这种事务;真要消除它,
    -- 得给 price_history 加一列序号,那是另一刀。
    SELECT CASE
        WHEN EXISTS (SELECT 1 FROM price_history ph
                      WHERE ph.inbound_batch_id = p_batch_id
                        AND ph.created_at::date > p_as_of)
            THEN (SELECT ph.old_unit_price FROM price_history ph
                   WHERE ph.inbound_batch_id = p_batch_id
                     AND ph.created_at::date > p_as_of
                   ORDER BY ph.created_at ASC, ph.id ASC LIMIT 1)
        ELSE (SELECT ib.unit_price FROM inbound_batches ib WHERE ib.id = p_batch_id)
    END;
$function$;

COMMENT ON FUNCTION public.inbound_unit_price_asof(uuid, date) IS
    'AGING-1:一张进料批次在【某一天】的单价 —— 从【今天的价】往回走,不是从历史里往前找。D 之后有改价就取最早那一次的 old_unit_price(首次计价那一行它就是空的,于是「那天还没有价」诚实地是 NULL,而 ap_open_items 明写 unit_price IS NOT NULL,那张批次会从当天的账龄里缺席);D 之后没有改价,今天的价就是 D 的价。【为什么不写成「取 D 之前最后一次的新价」】created_at 默认 now() 而 now() 是【事务开始时刻】,同一笔事务里的两行时刻完全相同 —— 那个写法必须在同刻行之间挑一个,而它挑的依据是随机 uuid:同一份数据两次运行两个答案(写 fixture 135 时抓到的)。【残余含糊】D 早于某一天而那天有一笔事务改了两次以上价;界面走不出这种事务,真要消除得给 price_history 加序号列,那是另一刀。【注意】created_at 是录入时刻不是业务日期,改价这件事今天没有业务日。';