-- db/functions/amend_blending_plan.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q19,Tim):【改一份草稿态的配料计划】—— action.wo_create(Q19:建与改同一个码)。
--   只有 draft 改得动(BLEND_PLAN_NOT_DRAFT|<编号>|<状态>)—— 放行过的计划冻住,要改就取消、重建。
--   表头(产出物料、合同、备注)就地改;目标与批次整份替换,判据与建单同一份(blending_plan_write_children)。
--   建单人不变:放行那一侧的四眼认的仍是建单人(created_by)。
--   返回 {plan_id, code, status}。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.amend_blending_plan(p_plan_id uuid, p_output_material_id uuid, p_lines jsonb, p_targets jsonb DEFAULT NULL::jsonb, p_source_contract_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_plan blending_plans%ROWTYPE;
BEGIN
    PERFORM require_permission('action.wo_create');
    SELECT * INTO v_plan FROM blending_plans WHERE id = p_plan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_FOUND|%', COALESCE(p_plan_id::text, '?');
    END IF;
    IF v_plan.status <> 'draft' THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_DRAFT|%|%', v_plan.code, v_plan.status
          USING HINT = '只有草稿改得动。放行过的计划冻住 —— 要改就取消它、重建一份。';
    END IF;

    UPDATE blending_plans
       SET output_material_id = p_output_material_id, source_contract_id = p_source_contract_id,
           notes = NULLIF(btrim(COALESCE(p_notes, '')), ''), updated_at = now(), updated_by = v_user
     WHERE id = p_plan_id;

    PERFORM blending_plan_write_children(p_plan_id, p_output_material_id, p_source_contract_id, p_targets, p_lines);

    RETURN jsonb_build_object('plan_id', p_plan_id, 'code', v_plan.code, 'status', 'draft');
END;
$function$
