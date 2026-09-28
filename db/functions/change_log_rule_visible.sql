-- db/functions/change_log_rule_visible.sql
-- HISTORY-1:一条遮蔽规则(change_log_mask_rules)对【当前读者】、就【这一行记录】成不成立。
-- 与 _masked 视图里那句 CASE WHEN 逐条同一个判据;认不出的规则按【看不见】答(关着失败)。
CREATE OR REPLACE FUNCTION public.change_log_rule_visible(p_rule text, p_table text, p_key jsonb, p_old jsonb, p_new jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_part text[] := string_to_array(p_rule, ':');
    v_fid  text;
BEGIN
    IF v_part[1] = 'code' THEN
        RETURN has_permission(v_part[2]);
    ELSIF v_part[1] = 'code_or_self' THEN
        RETURN has_permission(v_part[2])
            OR COALESCE(change_log_field(p_table, p_key, p_old, p_new, v_part[3]) = current_user_employee()::text, false);
    ELSIF p_rule = 'pft:direction' THEN
        RETURN pricing_formula_terms_visible(change_log_field(p_table, p_key, p_old, p_new, 'direction'));
    ELSIF p_rule IN ('pft:formula_id', 'pft3') THEN
        v_fid := change_log_field(p_table, p_key, p_old, p_new, 'formula_id');
        IF NOT pricing_formula_terms_visible(
               change_log_field('pricing_formulas', jsonb_build_object('id', v_fid), NULL, NULL, 'direction')) THEN
            RETURN false;
        END IF;
        IF p_rule = 'pft:formula_id' THEN
            RETURN true;
        END IF;
        RETURN pricing_formula_terms_visible(COALESCE(change_log_field(p_table, p_key, p_old, p_new, 'old_direction'), 'both'))
           AND pricing_formula_terms_visible(COALESCE(change_log_field(p_table, p_key, p_old, p_new, 'new_direction'), 'both'));
    END IF;
    RETURN false;
END;
$function$;
