-- db/functions/trail_root_gate.sql
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q5 —— M12):一道【比那张表的读规则更窄】的门。
--   trail_subjects 的 root_rule 写成 'gate:<名字>':根行先过它自己那张表的读规则(与 'table' 相同),【再】过这里点名的那一道。
--   为什么要更窄:/my-reviews/[id](审核人那一页,没有模块门)上的那条记录 —— performance_reviews 的读规则在评审批准之后
--   也放【被评审的那个人】进来,于是只靠表的规则(M8),被评审的人读得到审核人在批准之前的每一次起草(Step 0 Q5)。
--   这一页的门是"你是这一份的审核人",审计记录的门必须是同一个。
-- 【闭合集合】只认下面列出的名字;认不出的名字一律 false(拒) —— 登记表里写错一个字,结果是"谁都读不了",不是"谁都读得了"。
--   reviewer:根行(performance_reviews)的 reviewer_employee_id 就是读者自己(current_user_employee() —— 主账号或附加账号)。
--   AT-1d-3 的 my_review 是它的第一个用户;本刀先建好,fixture 244 用一个临时主语证它。
-- 【属主身份】EXECUTE 已从 authenticated 收回(只有 record_trail 调它)。
CREATE OR REPLACE FUNCTION public.trail_root_gate(p_gate text, p_table text, p_image jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
        WHEN p_gate = 'reviewer' AND p_table = 'performance_reviews'
            THEN COALESCE(p_image ->> 'reviewer_employee_id' = current_user_employee()::text, false)
        ELSE false
    END;
$function$;
