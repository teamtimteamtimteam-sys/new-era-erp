CREATE OR REPLACE FUNCTION public.assert_material_form_saleable(p_material_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_form text;
    v_zh   text;
    v_en   text;
    v_mat  text;
BEGIN
    -- 【属主权限:先让这支函数【看得见】】它 JOIN materials(module.materials.view),
    -- 而 INVOKER 会让一个没有那条权限的读者查不到行 —— 于是 FOUND 为假,
    -- 法律那条拒绝**静默地不发生**。线上真角色 warehouse 就是这种读者(实测)。
    SELECT m.code INTO v_mat FROM public.materials m WHERE m.id = p_material_id;

    -- ★【受众判据:看不见就按名拒绝,绝不静默通过】★
    -- 【它必须 RAISE,不能 return】—— 一支 void 函数的"返回 NULL"就是"通过",
    -- 见迁移抬头【错 1】。这是本刀最要紧的一句话。
    IF NOT (has_permission('module.sales.edit')
         OR has_permission('module.finance.edit')
         OR has_permission('module.output.view')) THEN
        RAISE EXCEPTION 'SALE_CANNOT_ESTABLISH_SALEABILITY|%|material_form',
            COALESCE(v_mat, p_material_id::text)
          USING HINT = '你的权限看不到这一种物料的形态,所以【判断不了】这一批可不可售 —— 而一个判断不了的断言【不许】放行。这不是说这个东西不许卖。要卖它,请让管理员给你销售或财务的编辑权限,或产出批次的查看权限。';
    END IF;

    SELECT f.code, f.name_zh, f.name_en INTO v_form, v_zh, v_en
      FROM public.materials m
      JOIN public.material_forms f ON f.code = m.form_code
     WHERE m.id = p_material_id
       AND f.may_be_sold IS FALSE;

    IF FOUND THEN
        RAISE EXCEPTION 'SALE_FORM_NOT_SALEABLE|%|%|%', v_form, v_zh, v_en
          USING HINT = '这个形态在法律上不允许出售(R5)。这【不是】库存问题,也【不是】审批问题 —— 没有例外路径。';
    END IF;
END;
$function$
