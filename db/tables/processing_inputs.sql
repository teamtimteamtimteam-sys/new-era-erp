-- db/tables/processing_inputs.sql
-- 加工投料腿:一行 = 某次加工从某个进料批次消耗了多少。remaining_qty 的扣减由
-- commit_processing_run() 完成(本表无触发器)。ON DELETE RESTRICT:加工只能整体
-- 冲销,不允许顺手硬删投料史。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.processing_inputs (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id            uuid NOT NULL REFERENCES public.processing_runs (id) ON DELETE RESTRICT,
    inbound_batch_id  uuid REFERENCES public.inbound_batches (id),
    quantity_consumed numeric NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    -- ── FIN-25 追加(ALTER 加的列排在末尾)──────────────────────────────────
    -- 再加工投料:消耗的上游产出批。与 inbound_batch_id 恰一非空(XOR)。
    -- 估值用上游 processing_outputs.unit_cost_base,解除 1220 而非 1200。
    output_batch_id   uuid REFERENCES public.output_batches (id),
    CONSTRAINT processing_inputs_one_parent
        CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1)
);

CREATE INDEX idx_processing_inputs_output ON public.processing_inputs (output_batch_id);

COMMENT ON COLUMN public.processing_inputs.output_batch_id IS
    '再加工投料:消耗的上游产出批(FIN-25)。与 inbound_batch_id 恰一非空。估值用上游 processing_outputs.unit_cost_base,解除的是 1220 而非 1200。';

-- 自吞守卫(FIN-25):一张单不能消耗自己的产出;且【两种边】的直插一律拒 ——
-- 裸 INSERT 不扣 remaining_qty,账实即分道(进料边的这个洞早已存在)。
-- 【别因为"只有再加工用它"而删】:它守的是两侧。
CREATE OR REPLACE FUNCTION public.guard_processing_input()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_material_id uuid;
    v_may  boolean;
    v_code text;
    v_axes       boolean;
    v_batch_code text;
    v_n          integer;
    v_bad_zh     text;
    v_bad_en     text;
    v_c_zh       text;
    v_c_en       text;
    -- PROC-WIRE-1B-i
    v_op         text;
    v_op_zh      text;
BEGIN
    IF current_setting('evoltrya.movement_ctx', true) NOT LIKE 'processing:%'
       AND current_setting('evoltrya.movement_ctx', true) NOT LIKE 'reversal:%' THEN
        RAISE EXCEPTION 'PROCESSING_INPUT_DIRECT_INSERT';
    END IF;
    IF NEW.output_batch_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM processing_outputs po
        WHERE po.output_batch_id = NEW.output_batch_id AND po.run_id = NEW.run_id
    ) THEN
        RAISE EXCEPTION 'PROCESSING_INPUT_SELF_CONSUME|%', NEW.run_id;
    END IF;
    -- ── PROC-1:只有【说了可以投料】的物料进得来 ────────────────────────────
    SELECT COALESCE(ib.material_id, ob.material_id) INTO v_material_id
      FROM (SELECT 1) x
      LEFT JOIN inbound_batches ib ON ib.id = NEW.inbound_batch_id
      LEFT JOIN output_batches  ob ON ob.id = NEW.output_batch_id;
    IF v_material_id IS NOT NULL THEN
        SELECT m.may_be_processed, m.code INTO v_may, v_code
          FROM materials m WHERE m.id = v_material_id;
        IF v_may IS NOT TRUE THEN
            RAISE EXCEPTION 'MATERIAL_NOT_PROCESSABLE|%|%', v_code,
                CASE WHEN v_may IS NULL THEN 'undecided' ELSE 'false' END
              USING HINT = '这一种物料没有被声明为可投料;第二个参数说的是【没人决定过】还是【决定了不投】。';
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-3:这一【批】货现在是什么状态
    --
    -- 【只问进料批次,不问产出批次】—— **M4,仍然没修,归 1B-ii。**
    -- 理由不是"产出批不需要问",而是【问不了】:安全状态今天只有进料批有,
    -- 根本没有 output_batch_safety_states 这张表。那是 1B-ii 的第一件事。
    -- ════════════════════════════════════════════════════════════════════════
    IF NEW.inbound_batch_id IS NOT NULL THEN
        SELECT mk.has_condition_axes INTO v_axes
          FROM inbound_batches ib
          JOIN materials       m  ON m.id   = ib.material_id
          JOIN material_kinds  mk ON mk.code = m.kind_code
         WHERE ib.id = NEW.inbound_batch_id;

        IF FOUND AND v_axes IS TRUE THEN
            SELECT ib.code INTO v_batch_code
              FROM inbound_batches ib WHERE ib.id = NEW.inbound_batch_id;

            -- 【D1:缺席仍然是自己那一条拒绝】"没有人记过"→ 去把它记下来。
            -- 这一条【与工序无关】:不管跑哪道工序,没人看过的料都不许进。
            SELECT count(*) INTO v_n
              FROM inbound_batch_safety_states s
             WHERE s.inbound_batch_id = NEW.inbound_batch_id;
            IF v_n = 0 THEN
                RAISE EXCEPTION 'INPUT_SAFETY_STATE_NOT_RECORDED|%', v_batch_code
                  USING HINT = '一条安全状态都没有的意思是【没有人记过】,不是"这批货安全"。到【进料 → 打开这一批 → 到货状态】那一块把它记上。';
            END IF;

            -- ════════════════════════════════════════════════════════════════
            -- ★ PROC-WIRE-1B-i:受理由【这道工序】回答 ★
            --
            -- 【没有工序类型 → may_be_fed,今天的行为一个字不变】
            -- 【有工序类型 → 只受理明写的那些,没写的一律拒】
            --
            -- **方向只有一个:声明一道工序只会把闸收紧。** 任何放宽都必须是
            -- operation_type_safety_states 里一行明写的数据 —— 绝没有
            -- "状态改变型一律放行"那种按 kind 的旁路(那会让一块鼓包漏液的
            -- 电池进放电机,而放电机解决不了它)。
            --
            -- 【D2 合取仍然成立】一批料身上每一个状态都必须被受理;
            -- 有一条不被受理就拒,并且【一次点完】所有不被受理的。
            -- 【D4:仍然不读 is_active】—— 已经记下来的事实不因字典停用而改变。
            -- ════════════════════════════════════════════════════════════════
            SELECT pr.operation_type_code INTO v_op
              FROM processing_runs pr WHERE pr.id = NEW.run_id;

            IF v_op IS NULL THEN
                SELECT string_agg(d.name_zh, '、' ORDER BY d.sort_order)
                         FILTER (WHERE d.may_be_fed IS NOT TRUE),
                       string_agg(d.name_en, ', ' ORDER BY d.sort_order)
                         FILTER (WHERE d.may_be_fed IS NOT TRUE)
                  INTO v_bad_zh, v_bad_en
                  FROM inbound_batch_safety_states s
                  JOIN inbound_safety_states d ON d.code = s.safety_state_code
                 WHERE s.inbound_batch_id = NEW.inbound_batch_id;

                IF v_bad_zh IS NOT NULL THEN
                    RAISE EXCEPTION 'INPUT_SAFETY_STATE_NOT_FEEDABLE|%|%|%',
                        v_batch_code, v_bad_zh, v_bad_en
                      USING HINT = '这一批带着不可投料的安全状态(全部列在消息里,一次清完)。状态改了要到【进料 → 打开这一批 → 到货状态】那一块改。';
                END IF;
            ELSE
                SELECT ot.name_zh INTO v_op_zh FROM operation_types ot WHERE ot.code = v_op;

                SELECT string_agg(d.name_zh, '、' ORDER BY d.sort_order),
                       string_agg(d.name_en, ', ' ORDER BY d.sort_order)
                  INTO v_bad_zh, v_bad_en
                  FROM inbound_batch_safety_states s
                  JOIN inbound_safety_states d ON d.code = s.safety_state_code
                 WHERE s.inbound_batch_id = NEW.inbound_batch_id
                   AND NOT EXISTS (
                       SELECT 1 FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op
                          AND a.safety_state_code = s.safety_state_code);

                IF v_bad_zh IS NOT NULL THEN
                    RAISE EXCEPTION 'INPUT_SAFETY_STATE_NOT_ACCEPTED|%|%|%|%',
                        v_batch_code, COALESCE(v_op_zh, v_op), v_bad_zh, v_bad_en
                      USING HINT = '这道工序【不受理】这一批身上的某些安全状态(全部列在消息里)。这与"不可投料"是两句话:换一道受理它的工序也许就行 —— 比如没放电的料要先走【深度放电】。';
                END IF;
            END IF;

            -- 【D3:确定度【没记】仍然放行】不要"修"掉这处不对称 ——
            -- 安全状态防的是【起火】,确定度防的是【数字算错】,后者由化验回答,
            -- 不由停线回答。线上 23 批货一条确定度都没有。
            SELECT c.name_zh, c.name_en INTO v_c_zh, v_c_en
              FROM inbound_batches ib
              JOIN inbound_chemistry_certainties c ON c.code = ib.chemistry_certainty_code
             WHERE ib.id = NEW.inbound_batch_id
               AND c.may_be_fed IS NOT TRUE;
            IF FOUND THEN
                RAISE EXCEPTION 'INPUT_CHEMISTRY_NOT_FEEDABLE|%|%|%',
                    v_batch_code, v_c_zh, v_c_en
                  USING HINT = '这一批的化学体系确定度被记成了一个不可投料的值。到【进料 → 打开这一批 → 到货状态】那一块改。';
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.guard_processing_input() FROM PUBLIC, anon;

CREATE TRIGGER trg_processing_inputs_guard
    BEFORE INSERT ON public.processing_inputs
    FOR EACH ROW EXECUTE FUNCTION public.guard_processing_input();

ALTER TABLE public.processing_inputs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_inputs select by permission"
    ON public.processing_inputs
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

CREATE POLICY "processing_inputs insert by permission"
    ON public.processing_inputs
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "processing_inputs update by permission"
    ON public.processing_inputs
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "processing_inputs delete by permission"
    ON public.processing_inputs
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.processing.edit'::text));
