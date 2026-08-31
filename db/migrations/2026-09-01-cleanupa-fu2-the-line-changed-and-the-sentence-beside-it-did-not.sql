-- CLEANUP-A fu2(2026-09-01):**fu1 改了那一行代码,没改它旁边那句话。**
--
-- fu1 把注销触发器里的计值从 inbound_batch_landed_unit_cost 改成了 _all,
-- 而紧挨着它的注释仍然写着「经 inbound_batch_landed_unit_cost」——
-- 于是线上那支函数里留着一句**说的和做的不一样**的话。
-- 这个仓库对这个形状记过好几次账(一个写下来的事实必须是一个量过的事实),
-- 所以它值一支只改注释的迁移,而不是"下次碰到再说"。
--
-- 【本迁移不改任何行为】只有函数体内的注释文字变了;逐字对比见
-- db/functions/inventory_ledger_triggers.sql。gate 的【镜像 vs 线上】判词
-- 正是因为这一句而红 —— 它比对的是 pg_get_functiondef 的原样字节,注释也在其中。
-- **那不是判词过严,是它按设计工作:线上与仓库对同一支函数的说法必须一致。**

BEGIN;

CREATE OR REPLACE FUNCTION public.emit_batch_writeoff_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx   text := current_setting('evoltrya.movement_ctx', true);
    v_run   uuid;
    v_value numeric;
    v_acct  text;
    v_amt   numeric;
    v_bd    date;      -- FIN-32:这条流水的【业务日】
    v_resn  int;       -- SO-2:这批货上还有几条【活预留】
    v_orders text;
BEGIN
    -- AUDEL-1b:三处 drain_stock 的 p_created_by 从 NEW.updated_by 改成
    -- COALESCE(NEW.deleted_by, NEW.updated_by) —— 台账要记的是【谁注销了这批料】,
    -- 那就是 deleted_by。门会把两者设成同一个人,所以今天的值不变;
    -- COALESCE 兜住 rollback 那条路(它设的是 updated_by)与任何历史行。
    -- 【函数体其余部分逐字未动】—— 预留守卫、business_date 的两类推理、
    -- 注销入账那一段都在原处。
    -- ════════════════════════════════════════════════════════════════════════
    -- SO-2:【一批还许着人的货,不能就这么注销掉】
    -- 排空一律走 drain_stock 的 ARRAY['available','on_hold'] —— 那两个桶是
    -- 【没有外部账】的:暂扣只是一个理由字符串。committed 不同,它在
    -- sales_order_reservations 里有一行对应的事实,还挂在某张订单的某一行上。
    -- 把它排空,那一行预留会指着一批不存在的货,而订单页上什么都不会变。
    -- 【所以这里不是"把 committed 加进排空数组",而是拒绝】—— 补救写在消息里:
    -- 先释放(那一步会留下理由、会回到 available、会写进订单历史),再注销。
    -- 【一个决定,而不是一次保守】:注销是不可逆的,而释放是有主人的动作;
    -- 让系统替销售决定"这个承诺可以撤了",正是它不该做的事。
    -- 反过来说,下面 drain 的两个数组【一个字都不用改】:committed 在这里就被
    -- 挡住了,排空永远见不到它 —— 这条注释是那两个数组为什么可以原样不动的
    -- 全部理由,删掉守卫就必须同时回来改数组。
    -- ════════════════════════════════════════════════════════════════════════
    IF TG_TABLE_NAME = 'output_batches' THEN
        SELECT count(*), string_agg(DISTINCT o.code, ', ' ORDER BY o.code)
          INTO v_resn, v_orders
          FROM sales_order_reservations r
          JOIN sales_order_lines l ON l.id = r.sales_order_line_id
          JOIN sales_orders o      ON o.id = l.sales_order_id
         WHERE r.output_batch_id = OLD.id AND r.released_at IS NULL AND r.consumed_at IS NULL;
        IF v_resn > 0 THEN
            RAISE EXCEPTION 'SO_BATCH_HAS_RESERVATIONS|%|%|%', OLD.code, v_resn, v_orders;
        END IF;
    END IF;

    IF OLD.remaining_qty > 0 THEN
        -- ════════════════════════════════════════════════════════════════════
        -- FIN-32:business_date =【这件事在业务上发生在哪一天】,与它被记进系统的
        -- 时刻是两回事。两类事,两个答案,不能共用一个:
        --
        --   * 注销(writeoff)是【真实发生的物理事件】—— 货报废了。发生在有人
        --     按下注销的那天,而那天就写在行上:deleted_at。取它的日期部分,
        --     是【读记录】而不是 CURRENT_DATE 那种【当场编一个】。
        --     (触发器只在 deleted_at 由空变非空时触发,所以它必然有值。)
        --
        --   * 冲销(reversal_void)【不是物理事件】—— 电池处理过了就处理过了,
        --     回滚是在更正一次【记错的加工单】。所以它的业务日是【原加工单的
        --     process_date】,不是今天:那样一错一改在同一天对消,中间那几天的
        --     库存历史不会凭空多出一批实际并不存在的货。
        --     会计侧的先例同向:reverse_journal_entry 把冲销日做成【显式入参】,
        --     从不假定 —— 这里没有入参可传,但答案同样来自记录(run.process_date),
        --     不来自时钟。
        --
        -- 【两个账会给出两个日期,这是知情的选择,不是疏漏】(FIN-32-fu1)
        -- 同一次更正:分录侧的冲销按【显式传入的冲销日】入账(它必须如此 ——
        -- 期间锁不许往已关闭的月份里塞东西),而这里的流水按【原加工日】。
        -- 于是一次更正在两个账里带着两个日期。这是两种账的性质不同:
        --   * 分录是【价值账,带锁】—— 它记的是"这笔更正在哪个会计期发生";
        --   * 流水是【数量账,无锁】—— 它记的是"那批货实际在不在库里"。
        -- 按日期把两个账对起来的人一定会撞上这处差异,所以写在这里:
        -- 撞上时该问的是"这两个日期各自回答的是哪个问题",不是"哪个错了"。
        -- ════════════════════════════════════════════════════════════════════
        IF TG_TABLE_NAME = 'inbound_batches' THEN
            -- IOD-1:注销排空【所有】桶,两种状态都算 —— 报废一批货,不会因为其中
            -- 一部分被扣住就留在账上。这也是三个消耗方里唯一一个必须动 on_hold 的。
            -- SO-2:committed 不在数组里,因为它【到不了这里】(上面的守卫已经拒了);
            -- 进料批次本来也不可能有 committed —— 预留只指向产出批次。
            PERFORM drain_stock(
                p_qty => OLD.remaining_qty, p_movement_type => 'writeoff',
                p_business_date => NEW.deleted_at::date, p_inbound_batch_id => OLD.id,
                p_statuses => ARRAY['available','on_hold'], p_created_by => COALESCE(NEW.deleted_by, NEW.updated_by));
        ELSE  -- output_batches
            IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'reversal' THEN
                v_run := split_part(v_ctx, ':', 2)::uuid;
                SELECT process_date INTO v_bd FROM processing_runs WHERE id = v_run;
                PERFORM drain_stock(
                    p_qty => OLD.remaining_qty, p_movement_type => 'reversal_void',
                    p_business_date => v_bd, p_output_batch_id => OLD.id,
                    p_statuses => ARRAY['available','on_hold'], p_run_id => v_run,
                    p_created_by => COALESCE(NEW.deleted_by, NEW.updated_by));
            ELSE
                PERFORM drain_stock(
                    p_qty => OLD.remaining_qty, p_movement_type => 'writeoff',
                    p_business_date => NEW.deleted_at::date, p_output_batch_id => OLD.id,
                    p_statuses => ARRAY['available','on_hold'], p_created_by => COALESCE(NEW.deleted_by, NEW.updated_by));
            END IF;
        END IF;

        -- cut 2a:注销即入账(仅已计值批次,借 5200 / 贷 1200|1220)。
        -- 【PROC-COST-2:reversal_void 仍然不入账,但理由换了 —— 这两件事必须一起读】
        -- 原来的理由是「void 的产出从未入过 1220,无可冲销」。**有了分摊之后那句话
        -- 不再成立**:已分摊的产出批确实入过 1220。结论仍然成立,只是理由变了 ——
        -- 解除 1220 的是 rollback_processing_run 冲销的那张资本化分录。
        -- **两处都做就是重复计数。** 未计值批次只出量不入账。
        IF v_ctx IS NULL OR split_part(v_ctx, ':', 1) <> 'reversal' THEN
            IF TG_TABLE_NAME = 'inbound_batches' THEN
                -- ════════════════════════════════════════════════════════════
                -- PROC-COST-2 · R1:【注销解除的是全部落地成本,不是采购价】
                -- 改之前这里是 `v_value := OLD.unit_price`,于是一批落地 900 的货
                -- 注销只解除 500,**400 留在 1200 上,而那批货已经不存在了**
                -- (线上实测:docs/landed-cost-relief.md 第一节)。
                -- 【一份实现,两个调用者】post_stocktake 读的是同一支函数 ——
                -- R1 要求两者一起改,正是因为它们必须永远给出同一个答案。
                -- 【比例免费】下面 v_amt = remaining_qty × v_value,单位费率乘剩余量,
                -- 半批注销天然解除一半落地成本,不需要第二套算术。
                -- 【读的是不带判据的那一支(CLEANUP-A fu1 起:_all)】
                -- 计值不许取决于谁按的按钮 —— 一个只有 inbound.edit 的仓管按下注销时,
                -- 带判据的读取器会返回 NULL,COALESCE 成 0 就等于本缺陷静默复发。
                --
                -- ★【CLEANUP-A 一度把这句话作废掉,而 gate 抓住了】★ 主迁移给
                -- inbound_batch_landed_unit_cost 加了 R3 要的判据,于是这一行对那个
                -- 仓管【直接抛权限拒绝】——【比返回 NULL 更响,但一样是错的】:
                -- 注销这个业务动作本身失败了。fu1 把算术拆到 _all(与
                -- batch_freight_base_all 同一个后缀、同一条理由),这一行改读它。
                -- ════════════════════════════════════════════════════════════
                v_value := inbound_batch_landed_unit_cost_all(OLD.id);
                v_acct := '1200';
            ELSE
                SELECT po.unit_cost_base INTO v_value
                FROM public.processing_outputs po
                WHERE po.output_batch_id = OLD.id
                LIMIT 1;
                v_acct := '1220';
            END IF;
            IF v_value IS NOT NULL THEN
                v_amt := round(OLD.remaining_qty * v_value, 2);
                IF v_amt <> 0 THEN
                    PERFORM post_journal_entry(
                        CURRENT_DATE,
                        'Write-off ' || OLD.code,
                        'writeoff', OLD.id,
                        jsonb_build_array(
                            jsonb_build_object('account_code', '5200', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt),
                            jsonb_build_object('account_code', v_acct, 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt)));
                END IF;
            END IF;
        END IF;

        NEW.remaining_qty := 0;
    END IF;
    RETURN NEW;
END;
$function$;

COMMIT;
