CREATE OR REPLACE FUNCTION public.guard_output_batch_not_promised()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_saleable boolean;
    v_qty      numeric;
    v_orders   text;
BEGIN
    -- 【只有【非可售】的指定才与承诺冲突】把一批货指回 saleable_stock
    -- (也就是【释放】这个指定)对一份承诺没有任何妨碍 —— 恰恰相反,
    -- 那正是镜像那一侧的 HINT 教操作员做的那一步。**拦它会把旁路堵死。**
    SELECT p.is_saleable_stock INTO v_saleable
      FROM public.output_batch_purposes p WHERE p.code = NEW.purpose_code;

    -- 【字典里没有这个码?不是本守卫的题】set_output_batch_purpose 的
    -- BATCH_PURPOSE_UNKNOWN 与那条外键各自管它。一个守卫只说一句话。
    IF v_saleable IS NOT FALSE THEN
        RETURN NEW;
    END IF;

    -- 【活预留 = 未释放 且 未消耗】(SO-3b 起两个条件,与 line_spoken_for 同源)。
    -- 已释放的货回到了 available,已消耗的货已经发走了 —— 两者都不再是一份
    -- 悬着的承诺,都不该拦住一次指定。
    SELECT sum(r.qty),
           string_agg(DISTINCT so.code, ', ' ORDER BY so.code)
      INTO v_qty, v_orders
      FROM public.sales_order_reservations r
      JOIN public.sales_order_lines sol ON sol.id = r.sales_order_line_id
      JOIN public.sales_orders so ON so.id = sol.sales_order_id
     WHERE r.output_batch_id = NEW.id
       AND r.released_at IS NULL
       AND r.consumed_at IS NULL;

    IF v_qty IS NULL OR v_qty <= 0 THEN
        RETURN NEW;
    END IF;

    -- ★【部分预留 → 整批拒。这是一个裁定,理由在抬头,不要"优化"成放行余量】★
    --   purpose_code 作用于【整批】,没有部分指定这种东西,也没有子批模型。
    --   在余量上放行,落到库里就是把整批(连同已许出去的那一部分)翻成非可售,
    --   而那一部分接着会被 assert_output_batch_saleable 拦在发货门外 ——
    --   **一次"部分放行"会把一句守住了的承诺变成一句毁约。**
    RAISE EXCEPTION 'BATCH_PROMISED_TO_CUSTOMER|%|%|%', NEW.code, v_qty, v_orders
      USING HINT = '这一批已经许给了客户(见上面的订单号),所以它不能被指定成下游工序的投料。'
                || '【部分预留也是整批拒】:指定是【整批】的事,没有"只指定没许出去的那部分"这种做法 —— '
                || '那会把已经许出去的货一起翻成非可售,发货那天就成了毁约。'
                || '要拿这一批去投料,先到销售订单上把预留释放掉,或者换一批。';
END;
$function$
