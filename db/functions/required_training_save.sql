-- db/functions/required_training_save.sql
-- ESG-2(Tim 2026-10-31 Q8 · Q9):新增或改一门必修培训(p_id 空 = 新增)。要 action.manage_esg(admin · cco · cfo)。
--   按名拒:REQUIRED_TRAINING_NAME_REQUIRED · REQUIRED_TRAINING_CATEGORY_INVALID · REQUIRED_TRAINING_VALIDITY_INVALID(1–240 个月之外)·
--     REQUIRED_TRAINING_APPLIES_INVALID · REQUIRED_TRAINING_POSITIONS_REQUIRED(选了「点名的岗位」却一个都没选)·
--     REQUIRED_TRAINING_POSITION_NOT_FOUND|<id> · REQUIRED_TRAINING_NAME_TAKEN|<名字>(在用的清单里同名)·
--     REQUIRED_TRAINING_NOT_FOUND · REQUIRED_TRAINING_RETIRED(停用了的改不了)。不选岗位的范围存一个空数组。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.required_training_save(p_id uuid, p_name text, p_category text, p_validity_months integer, p_applies_to text, p_position_ids uuid[] DEFAULT '{}'::uuid[], p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_pos  uuid[] := CASE WHEN p_applies_to = 'positions' THEN COALESCE(p_position_ids, '{}'::uuid[]) ELSE '{}'::uuid[] END;
    v_bad  uuid;
    v_id   uuid;
BEGIN
    PERFORM require_permission('action.manage_esg');
    IF p_name IS NULL OR btrim(p_name) = '' THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_NAME_REQUIRED';
    END IF;
    IF p_category IS NOT NULL AND p_category NOT IN ('induction','safety','compliance','cybersecurity','technical','leadership','other') THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_CATEGORY_INVALID';
    END IF;
    IF p_validity_months IS NOT NULL AND p_validity_months NOT BETWEEN 1 AND 240 THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_VALIDITY_INVALID';
    END IF;
    IF p_applies_to IS NULL OR p_applies_to NOT IN ('everyone','office','shopfloor','positions') THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_APPLIES_INVALID';
    END IF;
    IF p_applies_to = 'positions' AND cardinality(v_pos) = 0 THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_POSITIONS_REQUIRED';
    END IF;
    SELECT x INTO v_bad FROM unnest(v_pos) x WHERE NOT EXISTS (SELECT 1 FROM positions p WHERE p.id = x) LIMIT 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_POSITION_NOT_FOUND|%', v_bad;
    END IF;
    IF EXISTS (SELECT 1 FROM required_trainings t WHERE t.retired_at IS NULL AND lower(btrim(t.name)) = lower(btrim(p_name))
                AND t.id IS DISTINCT FROM p_id) THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_NAME_TAKEN|%', btrim(p_name);
    END IF;
    IF p_id IS NULL THEN
        INSERT INTO required_trainings (name, category, validity_months, applies_to, position_ids, notes, created_by, updated_by)
        VALUES (btrim(p_name), p_category, p_validity_months, p_applies_to, v_pos, NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid(), auth.uid())
        RETURNING id INTO v_id;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM required_trainings t WHERE t.id = p_id) THEN
            RAISE EXCEPTION 'REQUIRED_TRAINING_NOT_FOUND';
        END IF;
        IF EXISTS (SELECT 1 FROM required_trainings t WHERE t.id = p_id AND t.retired_at IS NOT NULL) THEN
            RAISE EXCEPTION 'REQUIRED_TRAINING_RETIRED';
        END IF;
        UPDATE required_trainings
           SET name = btrim(p_name), category = p_category, validity_months = p_validity_months, applies_to = p_applies_to,
               position_ids = v_pos, notes = NULLIF(btrim(COALESCE(p_notes, '')), ''), updated_by = auth.uid()
         WHERE id = p_id
        RETURNING id INTO v_id;
    END IF;
    RETURN jsonb_build_object('id', v_id);
END;
$function$;
