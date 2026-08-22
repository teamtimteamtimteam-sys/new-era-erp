CREATE OR REPLACE FUNCTION public.set_material_required_metals(p_material_id uuid, p_metals text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_metal text;
    v_clean text[];
BEGIN
    PERFORM require_permission('module.materials.edit');

    IF p_material_id IS NULL THEN
        RAISE EXCEPTION 'MATERIAL_REQUIRED';
    END IF;
    SELECT code INTO v_code FROM materials WHERE id = p_material_id AND deleted_at IS NULL;
    -- 【物料不存在 ≠ 物料没有要求】前者是问错了问题。合成一个"没有要求"就是把
    -- 打错的 id 显示成一个正当的答案(mustRows / restRows / ACCOUNT_NOT_FOUND 同一条)。
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'MATERIAL_NOT_FOUND|%', p_material_id;
    END IF;

    -- 【NULL 与空数组【都】是"清空要求",而它们必须走到同一个地方】
    -- 一个把 NULL 读成"什么都不做"的实现,会让"取消全部要求"这个动作静默失败。
    v_clean := COALESCE(p_metals, ARRAY[]::text[]);

    FOREACH v_metal IN ARRAY v_clean LOOP
        -- PROC-CLEANUP:【现读字典】。这里原本写死七个码 —— 那是 PROC-4 漏掉的三份之一。
        -- PROC-4 报的"残留 0"只对【约束】成立,它的 S1 没有查函数体。
        -- 后果是具体的:往 substances 加一行之后,外键放行,而这里按 METAL_INVALID 拒 ——
        -- 于是"加一种物质 = 加一行"这句承诺,在这条路上不成立。
        IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances WHERE code = v_metal) THEN
            RAISE EXCEPTION 'METAL_UNKNOWN|%', COALESCE(v_metal, '(null)');
        END IF;
    END LOOP;

    -- 【重复的金属按名拒,不是悄悄去重】传 ['cu','cu'] 的调用方对自己要什么是糊涂的,
    -- 而去重会让它以为自己说清楚了。
    IF (SELECT count(*) FROM unnest(v_clean)) <>
       (SELECT count(DISTINCT x) FROM unnest(v_clean) x) THEN
        RAISE EXCEPTION 'METAL_DUPLICATED|%', array_to_string(v_clean, ',');
    END IF;

    -- 整套替换:先删后插,同一个事务 —— 不存在"改了一半"的中间态。
    DELETE FROM material_required_metals WHERE material_id = p_material_id;
    INSERT INTO material_required_metals (material_id, metal)
    SELECT p_material_id, x FROM unnest(v_clean) x;

    RETURN jsonb_build_object(
        'material_id', p_material_id,
        'material_code', v_code,
        -- 【空集就报空集,并且说出来它是空的】调用方(ASY-P2 的界面)据此印
        -- 「无化验要求」那句话,而不是靠"数组长度是 0"自己去猜一句文案。
        'metals', COALESCE(to_jsonb(v_clean), '[]'::jsonb),
        'metal_count', COALESCE(array_length(v_clean, 1), 0),
        'has_requirement', COALESCE(array_length(v_clean, 1), 0) > 0
    );
END;
$function$;
