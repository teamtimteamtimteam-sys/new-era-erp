-- db/functions/create_blending_plan.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q19 · Q20,Tim):【建一份配料计划】—— action.wo_create(建工单的同一个码,Q19)。
--   生下来是 draft,编号 BLD-<建单那一年>-NNNN(next_blending_plan_code)。产出物料、合同、目标与批次的判据全在
--   blending_plan_write_children(与 amend_blending_plan 同一份)。
--   ★ 建单人之外没有一个真持有人持 action.wo_release,就不让它生下来(BLEND_NO_OTHER_RELEASER)—— 否则它是一张永远的草稿;
--     与 create_work_order 的 WO_NO_OTHER_RELEASER 同一句判据(real_role_grants · self_leg 按人认,跨账号;不看审批开关)。
--   返回 {plan_id, code, status}。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.create_blending_plan(p_output_material_id uuid, p_lines jsonb, p_targets jsonb DEFAULT NULL::jsonb, p_source_contract_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_code text;
BEGIN
    PERFORM require_permission('action.wo_create');
    IF NOT EXISTS (SELECT 1
                     FROM role_permissions rp
                     JOIN roles r ON r.id = rp.role_id
                    CROSS JOIN LATERAL real_role_grants(r.code) g
                    WHERE rp.permission_code = 'action.wo_release'
                      AND self_leg(v_user, NULL::uuid, g.user_id) = 'none') THEN
        RAISE EXCEPTION 'BLEND_NO_OTHER_RELEASER'
          USING HINT = '建单人永远不能放行自己的配料计划,而此刻除你之外没有人持放行的码(action.wo_release)。请管理员先把这个码给另一个人。';
    END IF;

    v_code := next_blending_plan_code(CURRENT_DATE);
    INSERT INTO blending_plans (code, status, output_material_id, source_contract_id, notes, created_by, updated_by)
    VALUES (v_code, 'draft', p_output_material_id, p_source_contract_id, NULLIF(btrim(COALESCE(p_notes, '')), ''), v_user, v_user)
    RETURNING id INTO v_id;

    PERFORM blending_plan_write_children(v_id, p_output_material_id, p_source_contract_id, p_targets, p_lines);

    RETURN jsonb_build_object('plan_id', v_id, 'code', v_code, 'status', 'draft');
END;
$function$
