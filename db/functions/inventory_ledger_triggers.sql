-- db/functions/inventory_ledger_triggers.sql
-- This file holds the SHARED trigger functions of the inventory ledger. The CREATE
-- TRIGGER attachments live with their tables: db/tables/inbound_batches.sql,
-- db/tables/output_batches.sql, db/tables/inventory_movements.sql.
-- (历史:批次表曾无镜像文件,挂载语句只好写在这里;2026-07-31 镜像漂移审计补齐了
-- 两张批次表的镜像后,挂载语句移了过去 —— 每张表的镜像现在完整描述它自己的触发器。)
--
-- Ledger rule: remaining_qty is a guarded cache; inventory_movements is the truth.
--   (a) emit-on-create        AFTER INSERT  on both batch tables  -> +remaining_qty in
--   (b) writeoff-on-softdelete BEFORE UPDATE on both batch tables -> -remaining_qty out, zero cache
--   (c) quantity guard        BEFORE UPDATE on both batch tables  -> quantity is immutable
--   (d) invariant             deferred constraint trigger on both batch tables + movements
--   immutability              BEFORE UPDATE OR DELETE on inventory_movements (rejects both)
--
-- Context marker: commit_processing_run / rollback_processing_run set
--   set_config('evoltrya.movement_ctx', 'processing:<run>' | 'reversal:<run>', true)
-- so the create/writeoff triggers can tag processing_produce / reversal_void with run_id.
--
-- NOTE: introduced by db/migrations/2026-07-03-phase2-cut1-inventory-ledger.sql.
-- Run AFTER inbound_batches/output_batches/inventory_movements exist. First-run script.

-- immutability: movements can never be updated or deleted (belt-and-braces on top of RLS)
CREATE OR REPLACE FUNCTION public.reject_movement_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'MOVEMENT_IMMUTABLE';
END;
$fn$;

-- (a) emit-on-create: new stock in (receipt, or processing_produce under processing ctx)
CREATE OR REPLACE FUNCTION public.emit_batch_receipt_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx text := current_setting('evoltrya.movement_ctx', true);
    v_loc text := current_setting('evoltrya.location_ctx', true);
    v_run uuid;
    v_location uuid;
BEGIN
    IF NEW.remaining_qty IS NULL OR NEW.remaining_qty <= 0 THEN
        RETURN NULL;
    END IF;

    -- 空串与未设置都当作【未指定库位】—— 表单不选就是不选,那是一个合法答案
    -- (LOC-1/STK-1 的"未指定库位"是一等状态,不是缺失)。
    IF v_loc IS NOT NULL AND btrim(v_loc) <> '' THEN
        v_location := v_loc::uuid;
    END IF;

    IF TG_TABLE_NAME = 'inbound_batches' THEN
        INSERT INTO public.inventory_movements (inbound_batch_id, movement_type, qty_delta, location_id, business_date, created_by)
        VALUES (NEW.id, 'receipt', NEW.remaining_qty, v_location, NEW.arrival_date, NEW.created_by);
    ELSE  -- output_batches
        IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'processing' THEN
            v_run := split_part(v_ctx, ':', 2)::uuid;
            -- 【加工产出一律落在"未指定库位"】—— 上架是一次转移,不是产出的副作用。
            -- 产线上刚下来的货还没被搬到任何货架上,系统不该替人假设它在哪。
            INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
            VALUES (NEW.id, 'processing_produce', NEW.remaining_qty, v_run, NEW.output_date, NEW.created_by);
        ELSE
            INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, location_id, business_date, created_by)
            VALUES (NEW.id, 'receipt', NEW.remaining_qty, v_location, NEW.output_date, NEW.created_by);
        END IF;
    END IF;

    RETURN NULL;
END;
$function$;

-- (b) writeoff-on-softdelete: stock out + zero the cache (reversal_void under reversal ctx)
-- cut 2a (2026-07-06): 注销即入账 —— 已计值批次(进料 unit_price / 产出腿 unit_cost_base)
-- 追加 借 5200 / 贷 1200|1220 分录;reversal_void 不入账(加工产出从未入过 1220)。
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
BEGIN
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
            PERFORM drain_stock(
                p_qty => OLD.remaining_qty, p_movement_type => 'writeoff',
                p_business_date => NEW.deleted_at::date, p_inbound_batch_id => OLD.id,
                p_statuses => ARRAY['available','on_hold'], p_created_by => NEW.updated_by);
        ELSE  -- output_batches
            IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'reversal' THEN
                v_run := split_part(v_ctx, ':', 2)::uuid;
                SELECT process_date INTO v_bd FROM processing_runs WHERE id = v_run;
                PERFORM drain_stock(
                    p_qty => OLD.remaining_qty, p_movement_type => 'reversal_void',
                    p_business_date => v_bd, p_output_batch_id => OLD.id,
                    p_statuses => ARRAY['available','on_hold'], p_run_id => v_run,
                    p_created_by => NEW.updated_by);
            ELSE
                PERFORM drain_stock(
                    p_qty => OLD.remaining_qty, p_movement_type => 'writeoff',
                    p_business_date => NEW.deleted_at::date, p_output_batch_id => OLD.id,
                    p_statuses => ARRAY['available','on_hold'], p_created_by => NEW.updated_by);
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

-- (c) quantity guard: quantity is immutable after creation
CREATE OR REPLACE FUNCTION public.reject_quantity_change()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'QUANTITY_IMMUTABLE|%', OLD.code;
END;
$fn$;

-- (d) invariant: remaining_qty must equal Σ movements for the affected batch(es)
CREATE OR REPLACE FUNCTION public.check_ledger_invariant()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inbound uuid;
    v_output  uuid;
    v_code    text;
    v_remaining numeric;
    v_sum     numeric;
BEGIN
    IF TG_TABLE_NAME = 'inbound_batches' THEN
        v_inbound := NEW.id;
    ELSIF TG_TABLE_NAME = 'output_batches' THEN
        v_output := NEW.id;
    ELSE  -- inventory_movements
        v_inbound := NEW.inbound_batch_id;
        v_output  := NEW.output_batch_id;
    END IF;

    IF v_inbound IS NOT NULL THEN
        SELECT code, remaining_qty INTO v_code, v_remaining FROM public.inbound_batches WHERE id = v_inbound;
        SELECT COALESCE(SUM(qty_delta), 0) INTO v_sum FROM public.inventory_movements WHERE inbound_batch_id = v_inbound;
        IF v_remaining IS DISTINCT FROM v_sum THEN
            RAISE EXCEPTION 'LEDGER_INVARIANT|%|%|%', v_code, v_remaining, v_sum;
        END IF;
    END IF;

    IF v_output IS NOT NULL THEN
        SELECT code, remaining_qty INTO v_code, v_remaining FROM public.output_batches WHERE id = v_output;
        SELECT COALESCE(SUM(qty_delta), 0) INTO v_sum FROM public.inventory_movements WHERE output_batch_id = v_output;
        IF v_remaining IS DISTINCT FROM v_sum THEN
            RAISE EXCEPTION 'LEDGER_INVARIANT|%|%|%', v_code, v_remaining, v_sum;
        END IF;
    END IF;

    RETURN NULL;
END;
$function$;

-- (trigger attachments moved to db/tables/inbound_batches.sql and
--  db/tables/output_batches.sql — see header)
