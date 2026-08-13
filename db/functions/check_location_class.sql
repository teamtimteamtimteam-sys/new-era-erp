CREATE OR REPLACE FUNCTION public.check_location_class(p_location_id uuid, p_material_id uuid)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_loc_code   text;
    v_mat_code   text;
    v_class      text;
    v_configured boolean;
    v_warn       text[] := '{}';
BEGIN
    -- 未指定库位:什么都没被断言,什么都不查。
    IF p_location_id IS NULL THEN
        RETURN v_warn;
    END IF;

    SELECT code INTO v_loc_code
    FROM storage_locations WHERE id = p_location_id;

    SELECT code, waste_classification_code INTO v_mat_code, v_class
    FROM materials WHERE id = p_material_id;

    v_configured := EXISTS (
        SELECT 1 FROM storage_location_allowed_classes
        WHERE location_id = p_location_id);

    -- 【第一态】没有人给这个库位配过任何一类 —— 告警,绝不拒绝。
    IF NOT v_configured THEN
        v_warn := v_warn || ('IOD_CLASS_UNCONFIGURED_LOCATION|' || COALESCE(v_loc_code, '?'));
    END IF;

    -- 【第二态】没有人给这个物料分过类 —— 告警,【在已配置的库位上也是告警】。
    -- 这一支就是天真谓词撒的第二个谎所在:等值比较遇上 NULL 得 NULL,于是
    -- "没人分过类"被判成"不在允许清单里"。两者在合规上不是一回事。
    IF v_class IS NULL THEN
        v_warn := v_warn || ('IOD_MATERIAL_UNCLASSIFIED|' || COALESCE(v_mat_code, '?'));
    END IF;

    -- 【第三态,也是唯一会拒绝的一态】两个决定都在:有人配了这个库位,并且
    -- 没有把这一类放进去。这是一次可判定的、明确的人为排除,所以它【可以】拒绝。
    IF v_configured AND v_class IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM storage_location_allowed_classes
           WHERE location_id = p_location_id
             AND classification_code = v_class) THEN
        RAISE EXCEPTION 'IOD_CLASS_EXCLUDED|%|%', COALESCE(v_loc_code, '?'), v_class;
    END IF;

    RETURN v_warn;
END;
$function$

;
