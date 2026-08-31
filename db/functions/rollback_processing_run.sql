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
    v_cap uuid;             -- 首挂的资本化分录
    v_delta_id uuid;        -- PROC-COST-2:重分摊的差额分录,逐张
    v_code text;
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

    -- ════════════════════════════════════════════════════════════════════════
    -- 【解除资本化 —— 台账与分录在同一个地方一起解除】(PROC-COST-1 立,
    --   PROC-COST-2 把工序种类的判断【拿掉】)
    --
    -- 台账那一半由基函数按本单的 deleted_at 自动排除(形状免费提供的);
    -- 分录那一半必须显式冲销 —— 两半都在这里发生,所以它们永远不会各说各话。
    -- 少做任何一半:要么成本留在存货上而单已经没了(账挂在一张不存在的单上),
    -- 要么台账清了而存货虚高。
    --
    -- ★【PROC-COST-2:这里原来有一句 `IF v_sc_kind`,只管状态改变型】★
    -- 于是**转化型加工单回滚之后,它的资本化分录(借 1220 / 贷 1200 / 贷 5xxx)
    -- 原样立着** —— 产出批已经被软删,1220 上却还挂着它的成本。
    -- 那个判断本刀【拿掉】:两种工序共用同一段代码,不是照着它再写一份。
    --   * 状态改变型:冲销 借 1200 / 贷 5xxx,成本从原料批上退回费用;
    --   * 转化型:    冲销 借 1220 / 贷 1200 / 贷 5xxx —— 1220 上的产出成本
    --     被拿掉,而投料的 1200 同时被还回来,与第 3 步还原 remaining_qty 同向。
    --
    -- 【产出批软删【不再】另外入账,这两件事必须一起读】注销触发器在
    -- reversal 上下文里不写分录 —— 因为解除 1220 的是这里冲销的这张分录。
    -- 两处都做就是重复计数。
    --
    -- ★【差额分录也要冲 —— 只补首挂的话,一张被重分摊过的单仍然错】★
    -- 转化型重分摊走的是差额路径:capitalization_entry_id 仍指首挂,新的差额
    -- 分录记在 allocation_snapshot->'delta_entry_ids' 里。只冲首挂,差额留在
    -- 1220 上,而这张单看起来已经修好了 —— 那是最坏的一种半修。
    -- (状态改变型不会有差额分录:它走的是冲旧挂新,capitalization_entry_id
    --  永远指着唯一活着的那一张。这个循环对它自然空转,不需要分支。)
    --
    -- 【第四个候选:sales_records 上的 COGS 分录 —— 不需要任何处置】
    -- 第 2 步的 OUTPUT_CONSUMED 闸在任何产出动过之后就拒绝回滚,而一次销售
    -- 必然动 remaining_qty。**够不到的东西不需要修,但需要被点名**,
    -- 否则下一个读到这里的人会把这条推理重做一遍。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT code, capitalization_entry_id INTO v_code, v_cap
      FROM processing_runs WHERE id = p_run_id;

    IF v_cap IS NOT NULL
       AND (SELECT status FROM journal_entries WHERE id = v_cap) = 'posted' THEN
        PERFORM reverse_journal_entry_internal(v_cap, CURRENT_DATE,
            'Rollback ' || COALESCE(v_code, '?'));
    END IF;

    FOR v_delta_id IN
        SELECT (jsonb_array_elements_text(
                    COALESCE(pr.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)))::uuid
          FROM processing_runs pr WHERE pr.id = p_run_id
    LOOP
        IF (SELECT status FROM journal_entries WHERE id = v_delta_id) = 'posted' THEN
            PERFORM reverse_journal_entry_internal(v_delta_id, CURRENT_DATE,
                'Rollback ' || COALESCE(v_code, '?'));
        END IF;
    END LOOP;

    UPDATE processing_runs
       SET capitalization_entry_id = NULL, capitalized_cost_base = 0
     WHERE id = p_run_id;

    PERFORM set_config('evoltrya.movement_ctx', '', true);   -- 用毕即清(同 commit)
END;
$function$;