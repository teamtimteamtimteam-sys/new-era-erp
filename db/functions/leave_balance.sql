-- db/functions/leave_balance.sql
-- 派生余额 —— 从不存储。breakdown 逐笔说明"这些天从哪来、去了哪"。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.

CREATE OR REPLACE FUNCTION public.leave_balance(p_employee_id uuid, p_leave_type_code text DEFAULT 'annual'::text, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_break   jsonb := '[]'::jsonb;
    v_granted numeric := 0;
    v_used    numeric := 0;
    v_expired numeric := 0;
    v_avail   numeric := 0;
    r         record;
BEGIN
    -- 自助:自己的余额自己看得见;其余要 module.hr.view
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    FOR r IN
        SELECT g.id, g.leave_year, g.days, g.granted_on, g.expires_on, g.grant_type,
               COALESCE((SELECT SUM(CASE WHEN c.entry_type='draw' THEN c.days ELSE -c.days END)
                         FROM leave_consumption c WHERE c.leave_grant_id = g.id), 0) AS consumed,
               -- 【已被结转走的部分】。结转是把剩余【搬到】下一年的一笔新授予里,
               -- 不是复制一份 —— 若不在这里扣掉,同样的天数会在来源授予和结转授予里
               -- 【各算一次】,余额凭空翻倍。这一条是本切最容易做错的地方之一。
               COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                         WHERE cf.source_grant_id = g.id AND cf.grant_type = 'carry_forward'
                           AND cf.deleted_at IS NULL), 0) AS carried_out
        FROM leave_grants g
        WHERE g.employee_id = p_employee_id AND g.leave_type_code = p_leave_type_code
          AND g.deleted_at IS NULL AND g.granted_on <= p_as_of
        ORDER BY g.expires_on NULLS LAST, g.granted_on
    LOOP
        v_granted := v_granted + r.days;
        v_used := v_used + r.consumed;
        -- 三种去向,任何一种都要说得出来:被用掉、被结转走、过期作废。
        IF r.carried_out > 0 AND (r.days - r.consumed - r.carried_out) <= 0 THEN
            NULL;  -- 整笔剩余已结转走,既不可用也不算作废
        ELSIF r.expires_on IS NOT NULL AND r.expires_on < p_as_of THEN
            v_expired := v_expired + (r.days - r.consumed - r.carried_out);
        ELSE
            v_avail := v_avail + (r.days - r.consumed - r.carried_out);
        END IF;
        v_break := v_break || jsonb_build_object(
            'grant_id', r.id, 'leave_year', r.leave_year, 'grant_type', r.grant_type,
            'days', r.days, 'consumed', r.consumed, 'carried_forward_out', r.carried_out,
            'remaining', r.days - r.consumed - r.carried_out,
            'expires_on', r.expires_on,
            'status', CASE WHEN r.carried_out > 0 AND (r.days - r.consumed - r.carried_out) <= 0
                                THEN 'carried_forward'
                           WHEN r.expires_on IS NOT NULL AND r.expires_on < p_as_of
                                THEN 'expired' ELSE 'active' END);
    END LOOP;

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'leave_type_code', p_leave_type_code, 'as_of', p_as_of,
        'granted', v_granted, 'consumed', v_used, 'expired', v_expired, 'available', v_avail,
        'breakdown', v_break);
END;
$function$;
