-- db/functions/rollback_processing_run_internal.sql
-- APR-7(2026-09-25):回滚一张加工单 —— ROLE-1 Batch 3b 的 rollback_processing_run 的函数体原样搬进来,
-- 只拿掉了码的检查、加了 p_deleted_by(grilling Q6:产出批与加工单的 deleted_by、还原流水的 created_by =
-- 提单人;不给 = 调用者本人)。冲销分录的 created_by 是调用者(批准的 CFO)。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- MES-5a-1(2026-10-08,P2;MES-5a Step 0 Q15,Tim):第 3 步只在这一炉的工序【吃料】时还原库存 —— 一炉深度放电从没扣过库存,
--   此前回滚却照样"还原":批次满着时被封顶成 0 而碰巧没事;批次之后被别的单用掉一部分时,还原对不上原始流水,
--   IOD_RESTORE_MISMATCH|<放过的量>|0,于是这一炉放电再也回滚不了。另:回滚之后照规则重判每一批投料的放电核实
--   (discharge_verify_batch —— 回滚掉的结果、拆分不再算数)。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.rollback_processing_run_internal(p_run_id uuid, p_reason text, p_deleted_by uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid := COALESCE(p_deleted_by, auth.uid());
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
    v_consumes boolean;     -- MES-5a-1(P2):这一炉的工序吃不吃料(没有工序的历史单按吃料算 —— 那正是它们当年做的事)
BEGIN
    -- ★ APR-7:本支是回滚那一步【本身】,不问码 —— EXECUTE 已从 authenticated 收回。唯一的调用者是
    --   warehouse_request_execute_internal(CFO 批准的回滚申请;deleted_by = 提单人,grilling Q6)。
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
    --    MES-5a-1(P2):只在这一炉的工序吃料时 —— 状态改变型(深度放电)提交时没扣过,回滚就没有东西可还(commit_processing_run 的 v_consumes 那一道,两边同一个判据)。
    SELECT COALESCE((SELECT k.consumes_input FROM processing_runs pr JOIN operation_types ot ON ot.code = pr.operation_type_code
                       JOIN operation_kinds k ON k.code = ot.kind_code WHERE pr.id = p_run_id), true)
      INTO v_consumes;
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.output_batch_id, pi.quantity_consumed
        FROM processing_inputs pi
        WHERE pi.run_id = p_run_id AND v_consumes
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
    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-3a(2026-10-06,MES-3a Step 0 Q2,Tim):【回滚也撤回这一炉对安全状态做过的事】。
    --   此前回滚不碰状态:一炉深度放电回滚之后,那一批还挂着"已放电并核验",而"带电未放电"已经被删 ——
    --   一批屏幕上说放过电的料可以被投进破碎机。现在:
    --     · 这一炉写上的结果状态(created_by_run_id = 本单)→ 结束,理由写明是哪一次回滚;
    --     · 这一炉结束掉的状态(ended_by_run_id = 本单)→ 重新开一条,记录时刻与记录人照抄原行(滞留时钟不因回滚重来),
    --       reopened_from_id 指回原行。那一类状态此刻已经开着(之后有人又记了一次)就不重开。
    --   进料批与产出批两张表同一套。
    -- ════════════════════════════════════════════════════════════════════════
    UPDATE inbound_batch_safety_states s
       SET ended_at = now(), ended_by = v_user_id,
           end_reason = 'undone by rollback of ' || COALESCE((SELECT pr.code FROM processing_runs pr WHERE pr.id = p_run_id), '?')
                        || ': ' || btrim(p_reason)
     WHERE s.created_by_run_id = p_run_id AND s.ended_at IS NULL;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code, created_at, created_by, reopened_from_id)
    SELECT s.inbound_batch_id, s.safety_state_code, s.created_at, s.created_by, s.id
      FROM inbound_batch_safety_states s
     WHERE s.ended_by_run_id = p_run_id
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states o
                        WHERE o.inbound_batch_id = s.inbound_batch_id AND o.safety_state_code = s.safety_state_code
                          AND o.ended_at IS NULL);
    UPDATE output_batch_safety_states s
       SET ended_at = now(), ended_by = v_user_id,
           end_reason = 'undone by rollback of ' || COALESCE((SELECT pr.code FROM processing_runs pr WHERE pr.id = p_run_id), '?')
                        || ': ' || btrim(p_reason)
     WHERE s.created_by_run_id = p_run_id AND s.ended_at IS NULL;
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code, created_at, created_by, reopened_from_id)
    SELECT s.output_batch_id, s.safety_state_code, s.created_at, s.created_by, s.id
      FROM output_batch_safety_states s
     WHERE s.ended_by_run_id = p_run_id
       AND NOT EXISTS (SELECT 1 FROM output_batch_safety_states o
                        WHERE o.output_batch_id = s.output_batch_id AND o.safety_state_code = s.safety_state_code
                          AND o.ended_at IS NULL);

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
        PERFORM reverse_journal_entry_internal(v_cap, reversal_date_for(v_cap),  -- AP-RECON-1 Batch B
            'Rollback ' || COALESCE(v_code, '?'));
    END IF;

    FOR v_delta_id IN
        SELECT (jsonb_array_elements_text(
                    COALESCE(pr.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)))::uuid
          FROM processing_runs pr WHERE pr.id = p_run_id
    LOOP
        IF (SELECT status FROM journal_entries WHERE id = v_delta_id) = 'posted' THEN
            PERFORM reverse_journal_entry_internal(v_delta_id, reversal_date_for(v_delta_id),  -- AP-RECON-1 Batch B
                'Rollback ' || COALESCE(v_code, '?'));
        END IF;
    END LOOP;

    UPDATE processing_runs
       SET capitalization_entry_id = NULL, capitalized_cost_base = 0
     WHERE id = p_run_id;

    PERFORM set_config('evoltrya.movement_ctx', '', true);   -- 用毕即清(同 commit)

    -- ── MES-5a-1(Step 0 Q6 · Q15):回滚之后,照规则重判这一炉每一批投料的放电核实 ────────────────────────
    --   回滚掉的那一炉的结果、它做的拆分都不再算数;上面那一段已经撤回了它自己写过的状态,这里让剩下的结论说了算
    --   (还有别的没回滚的放电结论时,可能重新核实;记的是那一批此刻最晚的那一炉)。一批从没有过结论的料不被碰。
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.output_batch_id FROM processing_inputs pi WHERE pi.run_id = p_run_id
    LOOP
        PERFORM discharge_verify_batch(
            CASE WHEN v_input.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END,
            COALESCE(v_input.inbound_batch_id, v_input.output_batch_id),
            (SELECT s.latest_run_id FROM discharge_batch_status_all s
              WHERE s.batch_id = COALESCE(v_input.inbound_batch_id, v_input.output_batch_id)),
            'after rollback of ' || COALESCE(v_code, '?'));
    END LOOP;

    -- ── COD-1:冲销之后,这几票货不再是"加工完"的 ────────────────────────
    -- 【已签发的证书在这里作废,而且没有替代品】—— 冲销说的是那次加工没发生。
    -- 不做这一步,供应商手里那张纸就还在说着一件系统已经不再相信的事,
    -- 而没有任何东西会提醒任何人。将来重新加工到完,那时会成立一张新的证书。
    FOR v_input IN
        SELECT DISTINCT pi.inbound_batch_id FROM processing_inputs pi
         WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL
    LOOP
        PERFORM refresh_cod_for_batch(v_input.inbound_batch_id);
    END LOOP;
END;
$function$;
