-- db/functions/change_log_rule_visible.sql
-- HISTORY-1:一条遮蔽规则(change_log_mask_rules)对【当前读者】、就【这一行记录】成不成立。
-- 与 _masked 视图里那句 CASE WHEN 逐条同一个判据;认不出的规则按【看不见】答(关着失败)。
-- ★ U1-A(UNBLOCK-1,2026-10-05)两种新写法,各自与它那张 _masked 视图里的 CASE 同一个判据:
--   pay_journal:<码>   持码,或这一行所在分录(entry_id → journal_entries.source_type)不是 'payroll'(journal_lines_masked)。
--                       分录找不到 → 看不见(关着失败;分录不可删,所以这只在影像里根本没有 entry_id 时发生)。
--   apr_amount         approval_log_amount_visible(subject_type, subject_id) —— 视图与这里调同一支函数(approval_log_masked)。
-- ★ U1-B(2026-10-05)两种新写法,同一个道理:
--   apr_note           approval_log_note_visible(subject_type, subject_id)(approval_log_masked 的 note;医疗报销的说明是健康的字)。
--   jr_amount          journal_request_amount_visible(这一行的 id)(journal_requests_masked;工资分录的冲销申请要 data.view_pay)。
-- ★ MES-1(2026-10-06,Q20)一种新写法:
--   never              谁都看不见(gateway_keys_masked 里那一列恒为空)。它与"认不出的规则"答的是同一个 false,
--                       而它在这里点名写出来 —— 一条只因为认不出才成立的规则,是一份只写在注释里的契约。
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
    IF p_rule = 'never' THEN
        RETURN false;
    ELSIF v_part[1] = 'code' THEN
        RETURN has_permission(v_part[2]);
    ELSIF v_part[1] = 'code_or_self' THEN
        RETURN has_permission(v_part[2])
            OR COALESCE(change_log_field(p_table, p_key, p_old, p_new, v_part[3]) = current_user_employee()::text, false);
    ELSIF v_part[1] = 'pay_journal' THEN
        RETURN has_permission(v_part[2])
            OR COALESCE(change_log_field('journal_entries',
                            jsonb_build_object('id', change_log_field(p_table, p_key, p_old, p_new, 'entry_id')),
                            NULL, NULL, 'source_type') <> 'payroll', false);
    ELSIF p_rule = 'apr_amount' THEN
        RETURN COALESCE(approval_log_amount_visible(change_log_field(p_table, p_key, p_old, p_new, 'subject_type'),
                                                    change_log_field(p_table, p_key, p_old, p_new, 'subject_id')::uuid), false);
    ELSIF p_rule = 'apr_note' THEN
        RETURN COALESCE(approval_log_note_visible(change_log_field(p_table, p_key, p_old, p_new, 'subject_type'),
                                                  change_log_field(p_table, p_key, p_old, p_new, 'subject_id')::uuid), false);
    ELSIF p_rule = 'jr_amount' THEN
        RETURN COALESCE(journal_request_amount_visible(change_log_field(p_table, p_key, p_old, p_new, 'id')::uuid), false);
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
