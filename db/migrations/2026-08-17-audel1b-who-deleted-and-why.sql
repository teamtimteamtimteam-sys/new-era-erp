-- AUDEL-1b:谁删的、为什么删 —— 而光加两列是不够的
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【地面:先量出"今天到底谁在软删"】
-- 全库 `deleted_at` 的写入方,逐条数过(应用侧 + 数据库函数):
--   * inbound_batches   ← app/inbound/actions.ts     直接 UPDATE
--   * output_batches    ← app/output/actions.ts      直接 UPDATE
--   * output_batches    ← rollback_processing_run    第 4 步
--   * processing_runs   ← rollback_processing_run    第 5 步
--   * stocktakes / purchase_orders / sales_orders / quotes
--                       ← **没有任何路径写它们的 deleted_at**(实测,零处)
--
-- 所以本刀的列加在【七张表】上,但门只开在有路的地方:
--   有路 → 建一扇门(函数),并把直连那条路堵死;
--   无路 → 只装守卫。**这不是"加一列没人填"**:守卫让"不填就删不掉"成立,
--   于是哪天有人给那四张表加软删路径,他必须先建那扇门 —— 纪律现在就落地,
--   而不是等到出事再说。
--
-- 【三条没有主人的历史注销,原样留白】线上 8 条 writeoff 流水里有 3 条
-- created_by 为空(−100 kg / 2026-08-12,−40 与 −60 kg / 2026-08-13)。
-- **不回填。**(FIN-26)今天补一个名字进去,得到的是一个我们猜的名字,
-- 而伪造的出处比空白更坏。空白就是空白,它自己会说"当时没人记"。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么必须有"门"这一层,而不是加两列就完事】
-- 软删今天是一次【直连 UPDATE】。加了列而不堵这条路,调用方照样可以只置
-- deleted_at、把两列留空 —— 那时这两列就成了"有时填、有时不填"的列,
-- 而一个有时不填的审计字段,比没有这一列更坏:它会被当成"这次删除没人负责"。
-- 所以守卫要求:deleted_at 从 NULL 变成非 NULL 的那一刻,
--   ① 必须带着本次事务的门标记 evoltrya.soft_delete_ctx(仓库既有机制,
--      与 evoltrya.alloc_ctx / po_amend_ctx / movement_ctx 同一套);
--   ② deleted_by 与 delete_reason 必须都已填好。
-- 两条都不满足就按名拒。
--
-- 【标记从客户端够不着】set_config 住在 pg_catalog,PostgREST 只暴露 public
-- 的函数 —— 客户端发不出任意 SQL,也就设不了这个标记。它只能由库内函数设。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. 两列:谁删的、为什么删
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.inbound_batches  ADD COLUMN deleted_by uuid, ADD COLUMN delete_reason text;
ALTER TABLE public.output_batches   ADD COLUMN deleted_by uuid, ADD COLUMN delete_reason text;
ALTER TABLE public.processing_runs  ADD COLUMN deleted_by uuid, ADD COLUMN delete_reason text;
ALTER TABLE public.stocktakes       ADD COLUMN deleted_by uuid, ADD COLUMN delete_reason text;
ALTER TABLE public.purchase_orders  ADD COLUMN deleted_by uuid, ADD COLUMN delete_reason text;
ALTER TABLE public.sales_orders     ADD COLUMN deleted_by uuid, ADD COLUMN delete_reason text;
ALTER TABLE public.quotes           ADD COLUMN deleted_by uuid, ADD COLUMN delete_reason text;

COMMENT ON COLUMN public.inbound_batches.delete_reason IS
    'AUDEL-1b:为什么注销这一批。由 soft_delete_inbound_batch() 必填写入;守卫不允许在没有它的情况下置 deleted_at。【历史行为空是真的空】—— 本刀之前的软删没有记过理由,不回填(FIN-26:伪造的出处比空白更坏)。';
COMMENT ON COLUMN public.processing_runs.delete_reason IS
    'AUDEL-1b:为什么回滚这张加工单。加工单的"删除"就是它的冲销(status=reversed + deleted_at),所以理由记在这里 —— rollback_processing_run() 必填。';

-- 盘点单的取消此前【什么都不记】:只把 status 改成 cancelled。补齐家族形状
-- (采购单 / 销售订单 / 工单都有 cancelled_at + cancel_reason)。
ALTER TABLE public.stocktakes
    ADD COLUMN cancelled_at timestamptz,
    ADD COLUMN cancelled_by uuid,
    ADD COLUMN cancel_reason text;

-- 采购单:cancelled_at 与 cancel_reason 早就有,缺的只是【谁】。
ALTER TABLE public.purchase_orders ADD COLUMN cancelled_by uuid;

-- 采购单历史:补上 'cancelled' —— 取消此前【不写历史行】,而另外四个族都写。
ALTER TABLE public.purchase_order_history
    DROP CONSTRAINT purchase_order_history_change_type_check;
ALTER TABLE public.purchase_order_history
    ADD CONSTRAINT purchase_order_history_change_type_check
    CHECK (change_type IN ('header_update','line_update','line_add','line_remove','cancelled'));

-- ════════════════════════════════════════════════════════════════════════════
-- 2. 守卫:置 deleted_at 必须走门,而且两列必须填好
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.guard_soft_delete_provenance()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_code text;
BEGIN
    -- 只管【从在册变成已删】那一刻。改别的列、甚至改一个已删行,都不经过这里。
    IF NEW.deleted_at IS NULL OR OLD.deleted_at IS NOT NULL THEN
        RETURN NEW;
    END IF;

    v_code := COALESCE(NEW.code, OLD.code, '?');

    -- ① 必须走门。标记由库内函数设(set_config 住在 pg_catalog,PostgREST
    --    不暴露它,客户端够不着)—— 所以这一条挡的是【直连 UPDATE】那条路。
    IF COALESCE(current_setting('evoltrya.soft_delete_ctx', true), '') <> '1' THEN
        RAISE EXCEPTION 'SOFT_DELETE_NO_DIRECT_UPDATE|%|%', TG_TABLE_NAME, v_code;
    END IF;

    -- ② 门里也不许留空。一个"有时填、有时不填"的审计字段比没有这一列更坏:
    --    它会被读成"这次删除没有人负责"。
    IF NEW.deleted_by IS NULL
       OR NEW.delete_reason IS NULL OR btrim(NEW.delete_reason) = '' THEN
        RAISE EXCEPTION 'DELETE_REASON_REQUIRED|%|%', TG_TABLE_NAME, v_code;
    END IF;

    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_inbound_batches_soft_delete_provenance
    BEFORE UPDATE ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_soft_delete_provenance();
CREATE TRIGGER trg_output_batches_soft_delete_provenance
    BEFORE UPDATE ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_soft_delete_provenance();
CREATE TRIGGER trg_processing_runs_soft_delete_provenance
    BEFORE UPDATE ON public.processing_runs
    FOR EACH ROW EXECUTE FUNCTION public.guard_soft_delete_provenance();
CREATE TRIGGER trg_stocktakes_soft_delete_provenance
    BEFORE UPDATE ON public.stocktakes
    FOR EACH ROW EXECUTE FUNCTION public.guard_soft_delete_provenance();
CREATE TRIGGER trg_purchase_orders_soft_delete_provenance
    BEFORE UPDATE ON public.purchase_orders
    FOR EACH ROW EXECUTE FUNCTION public.guard_soft_delete_provenance();
CREATE TRIGGER trg_sales_orders_soft_delete_provenance
    BEFORE UPDATE ON public.sales_orders
    FOR EACH ROW EXECUTE FUNCTION public.guard_soft_delete_provenance();
CREATE TRIGGER trg_quotes_soft_delete_provenance
    BEFORE UPDATE ON public.quotes
    FOR EACH ROW EXECUTE FUNCTION public.guard_soft_delete_provenance();

-- ════════════════════════════════════════════════════════════════════════════
-- 3. 两扇门:批次的软删(今天唯一有路的两处)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.soft_delete_inbound_batch(
    p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_code text;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        -- 【理由必填,而且拒绝要按名】注销一批料是一次真实的物理事件
        -- (它会写一条 writeoff 流水)。没有理由的注销,事后没有人答得出为什么。
        RAISE EXCEPTION 'DELETE_REASON_REQUIRED|inbound_batches|%',
            COALESCE((SELECT code FROM inbound_batches WHERE id = p_batch_id), '?');
    END IF;

    SELECT code INTO v_code FROM inbound_batches
     WHERE id = p_batch_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;

    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE inbound_batches
       SET deleted_at = now(), deleted_by = v_user, delete_reason = btrim(p_reason),
           updated_by = v_user, updated_at = now()
     WHERE id = p_batch_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);

    RETURN jsonb_build_object('id', p_batch_id, 'code', v_code, 'deleted_by', v_user);
END;
$function$;

CREATE OR REPLACE FUNCTION public.soft_delete_output_batch(
    p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_code text;
BEGIN
    PERFORM require_permission('module.output.edit');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DELETE_REASON_REQUIRED|output_batches|%',
            COALESCE((SELECT code FROM output_batches WHERE id = p_batch_id), '?');
    END IF;

    SELECT code INTO v_code FROM output_batches
     WHERE id = p_batch_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;

    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE output_batches
       SET deleted_at = now(), deleted_by = v_user, delete_reason = btrim(p_reason),
           updated_by = v_user, updated_at = now()
     WHERE id = p_batch_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);

    RETURN jsonb_build_object('id', p_batch_id, 'code', v_code, 'deleted_by', v_user);
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 4. 注销流水带上【本次删除记下的那个人】,而不是 updated_by
-- ════════════════════════════════════════════════════════════════════════════
-- 门会把 deleted_by 与 updated_by 设成同一个人,所以今天两者相同;
-- 但语义上台账要记的是【谁注销了这批料】,那就是 deleted_by。
-- COALESCE 兜住 rollback 之外那条历史路径(以及任何将来只设 updated_by 的地方)。
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
        -- processing 回滚(reversal_void)不入账:本 cut 不记加工产出/消耗分录,
        -- void 的产出从未入过 1220,无可冲销。未计值批次只出量不入账。
        IF v_ctx IS NULL OR split_part(v_ctx, ':', 1) <> 'reversal' THEN
            IF TG_TABLE_NAME = 'inbound_batches' THEN
                v_value := OLD.unit_price;
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

-- ════════════════════════════════════════════════════════════════════════════
-- 5. 采购单取消并入家族(理由必填 + 谁 + 历史行)
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么这里也要 DROP】签名没变(uuid, text),但 PostgreSQL 不允许用
-- CREATE OR REPLACE 去【摘掉一个已有的参数默认值】:
--     ERROR: cannot remove parameter defaults from existing function
-- 而"理由不能再有默认值"正是这一刀要买的东西。传两个参数的调用方不受影响;
-- 只传一个的会坏 —— 见切次报告里点名的那几处。
DROP FUNCTION public.cancel_purchase_order(uuid, text);
CREATE OR REPLACE FUNCTION public.cancel_purchase_order(p_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_po      record;
    v_batches integer;
    v_applied numeric;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT id, code, status INTO v_po
    FROM purchase_orders WHERE id = p_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    -- AUDEL-1b:【理由必填】此前是 DEFAULT NULL —— 取消一张采购单可以什么都不说,
    -- 而另外四个族(发票 / 工单 / 销售订单 / 报价)全都要求理由。这是第五份复制,
    -- 不是第六种变体:形状照抄 set_sales_order_status 的那一句。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'PO_CANCEL_REASON_REQUIRED|%', v_po.code;
    END IF;

    SELECT count(*) INTO v_batches
    FROM inbound_batches WHERE purchase_order_id = p_id AND deleted_at IS NULL;
    IF v_batches > 0 THEN
        RAISE EXCEPTION 'PO_HAS_RECEIPTS|%', v_batches;
    END IF;

    SELECT COALESCE(SUM(amount_base), 0) INTO v_applied
    FROM prepayment_applications WHERE purchase_order_id = p_id;
    IF v_applied > 0 THEN
        RAISE EXCEPTION 'PO_HAS_APPLIED_PREPAYMENTS|%', v_applied;
    END IF;

    -- PUR-2:告诉 guard_po_amendable 这是一次【状态转换】,不是一次修改。
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法:显式声明,
    -- 而不是让守卫去猜调用方是谁。
    -- 【用完立刻清掉 —— 这一句是 fu2 的全部内容】set_config(..., true) 是
    -- 【事务】局部,不是语句局部。只在函数开头设一次,守卫就会在这次调用之后、
    -- 整个事务余下的时间里【一直是关着的】:跑过一次 close_purchase_order 之后,
    -- 同一事务里一条直连的 UPDATE ... SET status 就畅通无阻(实测过)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders
    SET status = 'cancelled', cancelled_at = now(), cancel_reason = btrim(p_reason),
        cancelled_by = v_user, updated_by = v_user
    WHERE id = p_id;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);

    -- AUDEL-1b:写一行历史 —— 取消此前【不写】,而另外四个族都写。
    -- change_type 'cancelled' 是本刀加进 CHECK 的;changed_by 走列默认 auth.uid()。
    INSERT INTO purchase_order_history (purchase_order_id, change_type, amend_reason, changed_by)
    VALUES (p_id, 'cancelled', btrim(p_reason), v_user);

    RETURN jsonb_build_object('purchase_order_id', p_id, 'code', v_po.code, 'status', 'cancelled');
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 6. 盘点取消:理由必填 —— 签名变了,所以是 DROP + CREATE
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么必须 DROP】加一个【必填】入参改变了签名,CREATE OR REPLACE 会造出一个
-- 重载而不是替换 —— 旧签名会原样活下去(FIN-21 那一条),而旧调用方会继续调它,
-- 于是"理由必填"这件事对他们等于没发生。预检也会因此拒绝这支迁移。
DROP FUNCTION public.cancel_stocktake(uuid);
CREATE OR REPLACE FUNCTION public.cancel_stocktake(p_stocktake_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_status  text;
    v_deleted timestamptz;
BEGIN
    PERFORM require_permission('module.stocktakes.edit');
    SELECT status, deleted_at INTO v_status, v_deleted
    FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', p_stocktake_id;
    END IF;
    IF v_status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_status;
    END IF;

    -- AUDEL-1b:【理由必填】此前这个函数一个 why 都不记 —— 只把 status 改成
    -- cancelled。一次作废掉的盘点是"我们数过、然后决定不算数"的记录,
    -- 而"为什么不算数"正是审计要问的那一句。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'STOCKTAKE_CANCEL_REASON_REQUIRED|%',
            (SELECT code FROM stocktakes WHERE id = p_stocktake_id);
    END IF;

    UPDATE stocktakes
    SET status = 'cancelled', cancelled_at = now(), cancelled_by = v_user,
        cancel_reason = btrim(p_reason), updated_by = v_user, updated_at = now()
    WHERE id = p_stocktake_id;
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 7. 加工单回滚:理由必填 —— 同样是 DROP + CREATE(签名变了)
-- ════════════════════════════════════════════════════════════════════════════
DROP FUNCTION public.rollback_processing_run(uuid);
CREATE OR REPLACE FUNCTION public.rollback_processing_run(p_run_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_run_deleted_at timestamptz;
    v_process_date date;     -- FIN-32:还原流水的业务日 = 原加工单的加工日
    v_bad_output record;
    v_input record;
    v_old_remaining numeric;
    v_new_remaining numeric;
    v_quantity numeric;
BEGIN
    PERFORM require_permission('module.processing.edit');
    -- AUDEL-1b:【理由必填】回滚一张加工单是一次很大的操作动作 —— 它软删产出批、
    -- 还原投入、写一整串冲销流水 —— 而此前它【一个 why 都不记】。
    -- 校验放在任何写之前:被拒 = 什么都没发生。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'ROLLBACK_REASON_REQUIRED|%',
            COALESCE((SELECT code FROM processing_runs WHERE id = p_run_id), '?');
    END IF;
    -- 1. 锁定加工单，校验存在且未删除
    SELECT process_date INTO v_process_date FROM processing_runs WHERE id = p_run_id;
    SELECT deleted_at INTO v_run_deleted_at
    FROM processing_runs
    WHERE id = p_run_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;

    IF v_run_deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_ALREADY_DELETED';
    END IF;

    -- 标记本次为回滚上下文,供产出批次软删触发器发出 reversal_void。
    PERFORM set_config('evoltrya.movement_ctx', 'reversal:' || p_run_id::text, true);

    -- 2. 安全检查：任何一个产出批次动过就拒绝
    SELECT ob.code, ob.state, ob.quantity, ob.remaining_qty
    INTO v_bad_output
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id
      AND ob.deleted_at IS NULL
      AND (ob.state <> '库存中' OR ob.remaining_qty <> ob.quantity)
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'OUTPUT_CONSUMED|%|%|%|%',
            v_bad_output.code, v_bad_output.state, v_bad_output.remaining_qty, v_bad_output.quantity;
    END IF;

    -- 3. 还原进料：加回 remaining_qty，重判 stage，记 reversal_restore 流水。
    --    FIN-25:产出批投料同样还原(不碰 state —— 那是销售状态)。
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.output_batch_id, pi.quantity_consumed
        FROM processing_inputs pi
        WHERE pi.run_id = p_run_id
    LOOP
        IF v_input.inbound_batch_id IS NOT NULL THEN
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM inbound_batches
            WHERE id = v_input.inbound_batch_id
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 进料批次已被删，跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE inbound_batches
            SET remaining_qty = v_new_remaining,
                stage = CASE WHEN v_new_remaining >= v_quantity THEN '待加工' ELSE '加工中' END,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.inbound_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                -- FIN-32:还原不是物理事件,是在更正一次记错的加工单 —— 业务日取
                -- 【原加工单的 process_date】,于是消耗与还原在同一天对消,
                -- 中间那几天的库存历史不会凭空少掉一批实际还在的货。
                --
                -- 【IOD-1:逐行镜像原始流水,不按规则重新分配】投料现在可能跨几个
                -- 库位桶写出多行;还原必须把货放回【它原来所在的那些桶】,而不是
                -- 按 drain 的顺序倒着来一遍 —— 那两者在一般情形下并不相等,
                -- 差额会安静地把库存挪到别的库位上。所以这里读原始的
                -- processing_consume 行,逐行取反。
                PERFORM mirror_consume_restore(p_run_id, v_input.inbound_batch_id, NULL,
                                                 v_new_remaining - COALESCE(v_old_remaining, 0),
                                                 v_process_date, v_user_id);
            END IF;
        ELSE
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM output_batches
            WHERE id = v_input.output_batch_id AND deleted_at IS NULL
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 上游产出批已被删（如其自身加工单已冲销），跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.output_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                -- FIN-32:同上 —— 产出批投料的还原(FIN-25 那条边)业务日一样取原加工日
                PERFORM mirror_consume_restore(p_run_id, NULL, v_input.output_batch_id,
                                                 v_new_remaining - COALESCE(v_old_remaining, 0),
                                                 v_process_date, v_user_id);
            END IF;
        END IF;
    END LOOP;

    -- 4. 软删这张单生成的产出批次(void 流水 + 归零由 BEFORE UPDATE 触发器处理)
    -- AUDEL-1b:软删要走门 —— 标记 + deleted_by + delete_reason,否则
    -- guard_soft_delete_provenance 会按名拒。产出批的删除理由【就是这次回滚的
    -- 理由】:它们不是被单独注销的,是被这次回滚带走的。
    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE output_batches
    SET deleted_at = now(),
        deleted_by = v_user_id,
        delete_reason = btrim(p_reason),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id IN (
        SELECT output_batch_id FROM processing_outputs WHERE run_id = p_run_id
    )
    AND deleted_at IS NULL;

    -- 5. 软删加工单本身（腿表保留作审计）
    UPDATE processing_runs
    SET status = 'reversed',
        deleted_at = now(),
        deleted_by = v_user_id,
        delete_reason = btrim(p_reason),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id = p_run_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);   -- 用毕即清(同 movement_ctx)

    PERFORM set_config('evoltrya.movement_ctx', '', true);   -- 用毕即清(同 commit)
END;
$function$;

COMMIT;
