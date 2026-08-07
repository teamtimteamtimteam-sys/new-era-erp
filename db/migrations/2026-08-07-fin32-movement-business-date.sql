-- db/migrations/2026-08-07-fin32-movement-business-date.sql
-- FIN-32:补全 inventory_movements.business_date —— 完成它,不是删掉它。
--
-- 【为什么完成而不是删】Doc 3 的 Phase 2(仓储)要出入库单据、状态区分的库存、
-- 库位管理 —— 每一件都要区分"这件事在业务上发生在哪一天"与"它什么时候被记进系统"。
-- 现在删掉,将来加回来时表里已经有数据,那时补的每一个值都是猜的;
-- 现在补,代价是零 —— 还没有真实数据。
--
-- 【补之前的分布】58% 为空,而空得【很有规律】:
--   sale 0% 空、adjustment 25%、processing_* 33–45%、receipt 80%,
--   writeoff / reversal_void / reversal_restore 【100% 空】。
-- 前几类的空来自 arrival_date 本身可空(收货触发器抄的就是它);
-- 后三类是压根没写 —— 这一切两头都堵。
--
-- 【每条路径的业务日取自哪里,以及为什么】——【两类事,两个答案,不能共用一个】
--   receipt(进料)      = inbound_batches.arrival_date   ← 收货人知道的事实
--   receipt(产出批)    = output_batches.output_date
--   processing_consume  = processing_runs.process_date   ← 已有
--   processing_produce  = output_batches.output_date     ← 已有
--   sale                = 销售日(record_output_sale 的入参)← 已有
--   adjustment          = CURRENT_DATE(post_stocktake)—— 【留着,并说明】:
--                         stocktakes 表上【没有盘点日字段】(只有 started_at /
--                         posted_at 两个时间戳),所以没有更好的来源可取。
--                         这不是 FIN-10 那种"有正确值却默认成今天",是真的没有。
--                         Phase 2 做盘点单时应当补一个盘点日,那时这里跟着改。
--   writeoff            = deleted_at::date  ← 【真实物理事件】:货报废在那一天,
--                         而那一天就写在行上。读记录,不是 CURRENT_DATE 那种当场编。
--   reversal_void       = 原加工单的 process_date ← 【不是物理事件】
--   reversal_restore    = 原加工单的 process_date ← 电池处理过了就是处理过了,
--                         回滚是在更正一次【记错的加工单】。取原加工日,一错一改
--                         在同一天对消,中间那几天的库存历史不会凭空多出/少掉货。
--                         会计侧同向:reverse_journal_entry 把冲销日做成【显式入参】,
--                         从不假定;这里没有入参可传,但答案同样来自记录,不来自时钟。
--
-- 【存量空值不回填】保持 NULL,界面读作"未知"。按今天的日期给一条三个月前的
-- 流水补一个业务日,是编造一条从来没人记录过的事实 —— 同 FIN-26 的灰色"出处未知"
-- 与 FIN-27 的无副本引用。列注释里写明这一点,免得后来的人把 NULL 当成 bug 去"修"。
--
-- 【新行必填,老行放过 —— 这一条是可表达的】CHECK (...) NOT VALID:
-- 对【新插入与更新】强制,不回头校验既有行。于是"从今往后必须有"是数据库在管,
-- 而不是一句口头约定;而那 15 行历史空值原样留着。
-- (inventory_movements 由 reject_movement_mutation 挡住 UPDATE/DELETE,
--  所以老行永远不会被"更新"撞上这条约束。)
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-07-fin32-movement-business-date.sql

BEGIN;

COMMENT ON COLUMN public.inventory_movements.business_date IS
    '这件事【在业务上发生在哪一天】,与 created_at(什么时候被记进系统)是两回事。收货取 arrival_date、加工取 process_date、销售取销售日、注销取 deleted_at 那天;冲销/还原取【原加工单的 process_date】—— 回滚是在更正一次记错的加工单,不是一次物理事件,所以一错一改在同一天对消。NULL = FIN-32 之前写入的行,当时这条路径根本没写它 —— 【不回填】,界面读作"未知";按今天补一个业务日是编造一条没人记录过的事实(同 FIN-26 / FIN-27)。新行由 inventory_movements_business_date_required(NOT VALID)强制必填。';

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
CREATE OR REPLACE FUNCTION public.rollback_processing_run(p_run_id uuid)
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
                INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
                VALUES (v_input.inbound_batch_id, 'reversal_restore', v_new_remaining - COALESCE(v_old_remaining, 0), p_run_id, v_process_date, v_user_id);
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
                INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
                VALUES (v_input.output_batch_id, 'reversal_restore', v_new_remaining - COALESCE(v_old_remaining, 0), p_run_id, v_process_date, v_user_id);
            END IF;
        END IF;
    END LOOP;

    -- 4. 软删这张单生成的产出批次(void 流水 + 归零由 BEFORE UPDATE 触发器处理)
    UPDATE output_batches
    SET deleted_at = now(),
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
        updated_by = v_user_id,
        updated_at = now()
    WHERE id = p_run_id;

    PERFORM set_config('evoltrya.movement_ctx', '', true);   -- 用毕即清(同 commit)
END;
$function$
;
-- 每条路径都写了之后,新行必填 —— 老行不动(NOT VALID 的全部意义)
ALTER TABLE public.inventory_movements
    ADD CONSTRAINT inventory_movements_business_date_required
    CHECK (business_date IS NOT NULL) NOT VALID;

COMMIT;
