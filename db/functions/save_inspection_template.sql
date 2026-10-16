-- db/functions/save_inspection_template.sql
-- MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q13 · Q20,Tim):【存一张巡检清单】—— 新建(p_template_id 为空)或改一张,连同它按顺序的
--   检查项(p_items:一个字的数组,第一个是第 1 项)。module.safety.edit。
--   判的顺序就是人下一步该改什么的顺序:代号必填(INSPECTION_TEMPLATE_CODE_REQUIRED)、只许大写字母 / 数字 / - / _
--   (INSPECTION_TEMPLATE_CODE_INVALID|<代号>)、不与别的清单重复(INSPECTION_TEMPLATE_CODE_TAKEN|<代号>)· 名字(INSPECTION_TEMPLATE_NAME_REQUIRED)·
--   片区(INSPECTION_TEMPLATE_AREA_REQUIRED)· 频率空着或 ≥ 1 天(INSPECTION_TEMPLATE_FREQUENCY_INVALID —— 空 = V18 Not yet set)·
--   至少一项(INSPECTION_TEMPLATE_ITEMS_REQUIRED)、每一项有字(INSPECTION_TEMPLATE_ITEM_BLANK|<第几项>)。
--   检查项【按位置】对齐:同一位置字没变就不碰那一行,变了就改字,多出来的加上,少了的删掉 —— 过去的巡检抄走了字,不指着这些行(Q13)。
--   返回 {template_id, code}。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
CREATE OR REPLACE FUNCTION public.save_inspection_template(p_template_id uuid, p_code text, p_name text, p_area text, p_items jsonb, p_frequency_days integer DEFAULT NULL::integer, p_is_active boolean DEFAULT true, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_id    uuid := p_template_id;
    v_code  text := upper(btrim(COALESCE(p_code, '')));
    v_n     integer;
    v_i     integer;
    v_text  text;
BEGIN
    PERFORM require_permission('module.safety.edit');

    IF v_code = '' THEN
        RAISE EXCEPTION 'INSPECTION_TEMPLATE_CODE_REQUIRED';
    END IF;
    IF v_code !~ '^[A-Z0-9][A-Z0-9_-]*$' THEN
        RAISE EXCEPTION 'INSPECTION_TEMPLATE_CODE_INVALID|%', v_code;
    END IF;
    IF EXISTS (SELECT 1 FROM inspection_templates t WHERE t.code = v_code AND t.id IS DISTINCT FROM p_template_id) THEN
        RAISE EXCEPTION 'INSPECTION_TEMPLATE_CODE_TAKEN|%', v_code;
    END IF;
    IF p_name IS NULL OR btrim(p_name) = '' THEN
        RAISE EXCEPTION 'INSPECTION_TEMPLATE_NAME_REQUIRED';
    END IF;
    IF p_area IS NULL OR btrim(p_area) = '' THEN
        RAISE EXCEPTION 'INSPECTION_TEMPLATE_AREA_REQUIRED';
    END IF;
    IF p_frequency_days IS NOT NULL AND p_frequency_days < 1 THEN
        RAISE EXCEPTION 'INSPECTION_TEMPLATE_FREQUENCY_INVALID';
    END IF;
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'INSPECTION_TEMPLATE_ITEMS_REQUIRED';
    END IF;
    v_n := jsonb_array_length(p_items);
    FOR v_i IN 1 .. v_n LOOP
        v_text := btrim(COALESCE(p_items ->> (v_i - 1), ''));
        IF v_text = '' THEN
            RAISE EXCEPTION 'INSPECTION_TEMPLATE_ITEM_BLANK|%', v_i;
        END IF;
    END LOOP;

    IF v_id IS NULL THEN
        v_id := gen_random_uuid();
        INSERT INTO inspection_templates (id, code, name, area, frequency_days, is_active, notes, created_by, updated_by)
        VALUES (v_id, v_code, btrim(p_name), btrim(p_area), p_frequency_days, COALESCE(p_is_active, true),
                NULLIF(btrim(COALESCE(p_notes, '')), ''), v_user, v_user);
    ELSE
        IF NOT EXISTS (SELECT 1 FROM inspection_templates WHERE id = v_id) THEN
            RAISE EXCEPTION 'INSPECTION_TEMPLATE_NOT_FOUND|%', v_id;
        END IF;
        UPDATE inspection_templates
           SET code = v_code, name = btrim(p_name), area = btrim(p_area), frequency_days = p_frequency_days,
               is_active = COALESCE(p_is_active, true), notes = NULLIF(btrim(COALESCE(p_notes, '')), ''), updated_by = v_user
         WHERE id = v_id
           AND (code, name, area, frequency_days, is_active, notes)
               IS DISTINCT FROM (v_code, btrim(p_name), btrim(p_area), p_frequency_days, COALESCE(p_is_active, true),
                                 NULLIF(btrim(COALESCE(p_notes, '')), ''));
    END IF;

    -- 检查项按位置对齐:字没变的那一行不碰
    FOR v_i IN 1 .. v_n LOOP
        v_text := btrim(p_items ->> (v_i - 1));
        UPDATE inspection_template_items SET item_text = v_text
         WHERE template_id = v_id AND position = v_i AND item_text IS DISTINCT FROM v_text;
        IF NOT EXISTS (SELECT 1 FROM inspection_template_items WHERE template_id = v_id AND position = v_i) THEN
            INSERT INTO inspection_template_items (template_id, position, item_text) VALUES (v_id, v_i, v_text);
        END IF;
    END LOOP;
    DELETE FROM inspection_template_items WHERE template_id = v_id AND position > v_n;

    RETURN jsonb_build_object('template_id', v_id, 'code', v_code);
END;
$function$;
