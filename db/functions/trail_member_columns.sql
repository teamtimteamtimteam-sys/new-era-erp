-- db/functions/trail_member_columns.sql
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q3 —— M10):一个成员【只取声明的几列】—— M6(root_columns)用在成员上。
--   (subject, ord) 对上 trail_subject_members() 里的那一行;columns 是那张表上属于这条记录的列:
--   一次改动一列都不沾 → 整条不算;沾了 → 只留这几列;"记录开始之前"那一段只拼落在这几列上的戳,不拼"建立"
--   (那一行的建立不是这条记录的事)。
--   第一个用户:账号的审计记录里那个员工 —— 账号绑在谁身上(employees.user_id)是账号的事,而那名员工别的每一次编辑
--   (地址、职位、证件……)不是。不限列,账号的审计记录就会把人事的每一次改动都搬过来(Step 0 C §A3)。
-- 【为什么另立一张表,不是 trail_subject_members 多一列】那张表的返回类型一变,每一支在 fixture 里临时改写它的
--   (fixture 237 / 241 证 M3–M7 的做法)都会因为"不能改返回类型"而起不来;一张旁表不碰任何既有的签名。
CREATE OR REPLACE FUNCTION public.trail_member_columns()
 RETURNS TABLE(subject text, ord integer, columns text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('account', 4, ARRAY['user_id'])
    ) AS c(subject, ord, columns);
$function$;
