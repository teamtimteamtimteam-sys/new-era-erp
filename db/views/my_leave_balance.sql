-- db/views/my_leave_balance.sql
-- 自助:当前登录者自己的累积型假别余额。属主权限 + current_user_employee() 谓词。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.

CREATE VIEW public.my_leave_balance WITH (security_invoker = off) AS
 SELECT e.id AS employee_id,
    e.code AS employee_code,
    lt.code AS leave_type_code,
    lt.name_en,
    lt.name_zh,
    COALESCE(sum(g.days), 0::numeric) AS granted,
    COALESCE(sum(cons.net), 0::numeric) AS consumed,
    COALESCE(sum(
        CASE
            WHEN g.expires_on IS NOT NULL AND g.expires_on < CURRENT_DATE THEN g.days - COALESCE(cons.net, 0::numeric)
            ELSE 0::numeric
        END), 0::numeric) AS expired,
    COALESCE(sum(
        CASE
            WHEN g.expires_on IS NULL OR g.expires_on >= CURRENT_DATE THEN g.days - COALESCE(cons.net, 0::numeric)
            ELSE 0::numeric
        END), 0::numeric) AS available
   FROM employees e
     JOIN leave_types lt ON lt.is_accrued AND lt.is_active
     LEFT JOIN leave_grants g ON g.employee_id = e.id AND g.leave_type_code = lt.code AND g.deleted_at IS NULL
     LEFT JOIN LATERAL ( SELECT COALESCE(sum(
                CASE
                    WHEN c.entry_type = 'draw'::text THEN c.days
                    ELSE - c.days
                END), 0::numeric) + COALESCE(( SELECT sum(cf.days) AS sum
                   FROM leave_grants cf
                  WHERE cf.source_grant_id = g.id AND cf.grant_type = 'carry_forward'::text AND cf.deleted_at IS NULL), 0::numeric) AS net
           FROM leave_consumption c
          WHERE c.leave_grant_id = g.id) cons ON true
  WHERE e.id = current_user_employee() AND e.deleted_at IS NULL
  GROUP BY e.id, e.code, lt.code, lt.name_en, lt.name_zh;
