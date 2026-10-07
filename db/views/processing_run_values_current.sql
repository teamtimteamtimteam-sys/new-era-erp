-- db/views/processing_run_values_current.sql
-- MES-4a(2026-10-07,MES-0 Q43 · Q44;MES-4a Step 0 Q12 · Q16 · Q29,Tim):【一炉每个字段【当前】的值,与它对着配方差在哪】。
--   一行 = 一炉的一个字段的更正链末端(没有被别的行更正过的那一行;更正成"没有值"= 三列都空,也是一行 —— 撤回是看得见的)。
--   带着字段的名字、类型、单位、是不是必填;越界标记(记下那一刻的范围,out_of_range —— 照记,不拒);是不是被更正过(corrected);
--   以及这一炉用的配方那一版里这个字段的值(recipe_value)与 differs_from_recipe:配方有这个字段而当前值与它不同(撤回也算不同)→ true,
--   相同 → false,配方里没有这个字段或这一炉没用配方 → NULL(没法比,不是"没差")。
--   【一份比较,两个读者】加工单页的"参数与指标"那一块与 fixture 253 读它 —— 页面不自己比(AGENTS.md「一个预览的屏幕问数据库」)。
--   属主权限 + 加工的门(module.processing.view)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE VIEW public.processing_run_values_current WITH (security_invoker = off) AS
 SELECT v.run_id,
    v.id AS value_id,
    v.operation_type_code,
    v.field_code,
    f.name_en,
    f.name_zh,
    f.kind,
    f.value_type,
    f.unit,
    f.is_required,
    f.is_active AS field_active,
    v.value_number,
    v.value_text,
    v.value_bool,
    v.source,
    v.out_of_range,
    v.range_min_at,
    v.range_max_at,
    v.recorded_at,
    v.recorded_by,
    (v.corrects_id IS NOT NULL) AS corrected,
    v.correction_reason,
    rv.param_values -> v.field_code AS recipe_value,
        CASE
            WHEN rv.param_values IS NULL OR NOT (rv.param_values ? v.field_code) THEN NULL::boolean
            WHEN f.value_type = ANY (ARRAY['number'::text, 'count'::text]) THEN v.value_number IS DISTINCT FROM ((rv.param_values ->> v.field_code)::numeric)
            WHEN f.value_type = 'yes_no'::text THEN v.value_bool IS DISTINCT FROM ((rv.param_values ->> v.field_code)::boolean)
            ELSE v.value_text IS DISTINCT FROM (rv.param_values ->> v.field_code)
        END AS differs_from_recipe
   FROM processing_run_values v
     JOIN operation_type_fields f ON f.operation_type_code = v.operation_type_code AND f.field_code = v.field_code
     JOIN processing_runs r ON r.id = v.run_id
     LEFT JOIN process_recipe_versions rv ON rv.id = r.recipe_version_id
  WHERE NOT (EXISTS ( SELECT 1
           FROM processing_run_values x
          WHERE x.corrects_id = v.id))
    AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_run_values_current IS
    'MES-4a:一炉每个字段当前的值(更正链末端),带越界标记、是否更正过,以及它对着这一炉配方那一版的值差不差(differs_from_recipe;没法比时为 NULL)。门:module.processing.view。';

GRANT SELECT ON public.processing_run_values_current TO authenticated;
REVOKE ALL ON public.processing_run_values_current FROM anon;
