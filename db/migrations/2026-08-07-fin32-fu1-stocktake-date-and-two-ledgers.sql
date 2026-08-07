-- FIN-32-fu1(2026-08-07):把两句含糊的话换成查过的结论。
--
-- ① 盘点调整为什么用 CURRENT_DATE。FIN-32 写的是"stocktakes 没有盘点日字段,
--    没有更好的来源" —— 而它有一个 started_at,名字听起来正是盘点日。查过了:
--    started_at 是 timestamptz NOT NULL DEFAULT now(),【全代码库没有任何一处写它】
--    (没有 INSERT 列清单、没有 UPDATE、应用侧只读不写),而线上每一行的
--    started_at 与 created_at 【逐微秒相等】(3/3,最大差 0.000000 秒)。
--    它是【建单时间戳】,不是盘点日期。所以周一盘、周二过账,记的仍是周二 ——
--    而这是诚实的:系统里根本没有人告诉过它周一。结论不变,理由从"没有更好的来源"
--    换成"查过了,那个字段不是它看起来的东西"。
--
-- ② 一次更正在两个账里带两个日期。分录冲销按【显式传入的冲销日】(必须如此:
--    期间锁不许往已关闭的月份里塞东西),流水冲销按【原加工日】(FIN-32 的决定)。
--    这是两种账的性质不同,不是疏漏 —— 写在流水那个决定所在的地方,
--    因为按日期对账的人一定会撞上它。
--
-- 【本迁移只改注释与列注释,不改任何行为】—— 数字一个都不动。
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-07-fin32-fu1-stocktake-date-and-two-ledgers.sql

BEGIN;

CREATE OR REPLACE FUNCTION public.post_stocktake(p_stocktake_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user           uuid := auth.uid();
    v_st             record;
    v_line           record;
    v_code           text;
    v_current        numeric;
    v_deleted        timestamptz;
    v_delta          numeric;
    v_lines_total    integer := 0;
    v_lines_adjusted integer := 0;
    v_total_delta    numeric := 0;
    v_value          numeric;
    v_inv_acct       text;
    v_amt            numeric;
    v_je_lines       jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('module.stocktakes.edit');
    SELECT id, code, status, deleted_at INTO v_st
    FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_st.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', p_stocktake_id;
    END IF;
    IF v_st.status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_st.status;
    END IF;

    FOR v_line IN SELECT * FROM stocktake_lines WHERE stocktake_id = p_stocktake_id
    LOOP
        v_lines_total := v_lines_total + 1;

        IF v_line.inbound_batch_id IS NOT NULL THEN
            SELECT code, remaining_qty, deleted_at, unit_price INTO v_code, v_current, v_deleted, v_value
            FROM inbound_batches WHERE id = v_line.inbound_batch_id FOR UPDATE;
            v_inv_acct := '1200';
        ELSE
            SELECT ob.code, ob.remaining_qty, ob.deleted_at, po.unit_cost_base
            INTO v_code, v_current, v_deleted, v_value
            FROM output_batches ob
            LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
            WHERE ob.id = v_line.output_batch_id
            FOR UPDATE OF ob;
            v_inv_acct := '1220';
        END IF;

        IF v_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'BATCH_DELETED|%', v_code;
        END IF;

        v_delta := v_line.counted_qty - v_current;
        IF v_delta <> 0 THEN
            IF v_line.inbound_batch_id IS NOT NULL THEN
                -- ════════════════════════════════════════════════════════════
                -- FIN-32-fu1:业务日 = 过账日(CURRENT_DATE),而这是【查过之后】
                -- 的结论,不是"没有更好的来源"那种含糊话。
                -- stocktakes 上确实有个 started_at,名字听起来像盘点日 —— 它不是:
                -- 它是 timestamptz NOT NULL DEFAULT now(),【全代码库没有任何一处
                -- 写过它】,而线上每一行的 started_at 与 created_at 【逐微秒相等】
                -- (实测 3/3,最大差 0.000000 秒)。它是建单时间戳,不是盘点日期。
                -- 所以周一盘、周二过账,这里记的仍是周二 —— 而这是【诚实的】:
                -- 系统里根本没有人告诉过它周一。
                -- 真要记录盘点当天,得先有一个【盘点日字段让人填】(Phase 2 的
                -- 盘点单),那时这里改成读它 —— 与注销读 deleted_at 同一条规矩:
                -- 日期要来自记录,而记录得先存在。
                -- ════════════════════════════════════════════════════════════
                INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.inbound_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE inbound_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.inbound_batch_id;
            ELSE
                INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.output_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE output_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.output_batch_id;
            END IF;
            v_lines_adjusted := v_lines_adjusted + 1;
            v_total_delta := v_total_delta + v_delta;

            -- cut 2a:有单值的差异行,成对累积分录行(盘盈:借库存 贷 5200;盘亏反向)。
            -- 无值(未计价进料 / 无成本产出)只调量不入账。
            IF v_value IS NOT NULL THEN
                v_amt := round(abs(v_delta) * v_value, 2);
                IF v_amt <> 0 THEN
                    IF v_delta > 0 THEN
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'debit',  'currency', 'SGD', 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', '5200',     'side', 'credit', 'currency', 'SGD', 'amount_ccy', v_amt);
                    ELSE
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', '5200',     'side', 'debit',  'currency', 'SGD', 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'credit', 'currency', 'SGD', 'amount_ccy', v_amt);
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;

    UPDATE stocktakes
    SET status = 'posted', posted_at = now(), updated_by = v_user, updated_at = now()
    WHERE id = p_stocktake_id;

    -- cut 2a:一张分录覆盖全部有值差异行(每行自成一对,天然自平)
    IF jsonb_array_length(v_je_lines) >= 2 THEN
        PERFORM post_journal_entry(
            CURRENT_DATE,
            'Stocktake ' || v_st.code,
            'stocktake', p_stocktake_id,
            v_je_lines);
    END IF;

    RETURN jsonb_build_object(
        'stocktake_id', p_stocktake_id,
        'code', v_st.code,
        'lines_total', v_lines_total,
        'lines_adjusted', v_lines_adjusted,
        'total_delta', v_total_delta
    );
END;
$function$
;
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
            INSERT INTO public.inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, created_by)
            VALUES (OLD.id, 'writeoff', -OLD.remaining_qty, NEW.deleted_at::date, NEW.updated_by);
        ELSE  -- output_batches
            IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'reversal' THEN
                v_run := split_part(v_ctx, ':', 2)::uuid;
                SELECT process_date INTO v_bd FROM processing_runs WHERE id = v_run;
                INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
                VALUES (OLD.id, 'reversal_void', -OLD.remaining_qty, v_run, v_bd, NEW.updated_by);
            ELSE
                INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, business_date, created_by)
                VALUES (OLD.id, 'writeoff', -OLD.remaining_qty, NEW.deleted_at::date, NEW.updated_by);
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
                            jsonb_build_object('account_code', '5200', 'side', 'debit',  'currency', 'SGD', 'amount_ccy', v_amt),
                            jsonb_build_object('account_code', v_acct, 'side', 'credit', 'currency', 'SGD', 'amount_ccy', v_amt)));
                END IF;
            END IF;
        END IF;

        NEW.remaining_qty := 0;
    END IF;
    RETURN NEW;
END;
$function$
;
COMMENT ON COLUMN public.inventory_movements.business_date IS
    '这件事【在业务上发生在哪一天】,与 created_at(什么时候被记进系统)是两回事。收货取 arrival_date、加工取 process_date、销售取销售日、注销取 deleted_at 那天、盘点调整取过账日(stocktakes.started_at 只是建单时间戳,与 created_at 逐微秒相等,不是盘点日 —— FIN-32-fu1 查证);冲销/还原取【原加工单的 process_date】—— 回滚是在更正一次记错的加工单,不是一次物理事件,所以一错一改在同一天对消。【注意两个账会给出两个日期】:同一次更正,分录侧按显式传入的冲销日入账(期间锁使然),本表按原加工日 —— 价值账带锁、数量账不带,各自回答不同的问题。NULL = FIN-32 之前写入的行,当时这条路径根本没写它 —— 【不回填】,界面读作"未知"。新行由 inventory_movements_business_date_required(NOT VALID)强制必填。';

COMMIT;
