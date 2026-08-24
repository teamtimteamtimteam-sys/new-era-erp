-- db/functions/sod_manual_posters_in.sql
-- SOD-1:问法① —— "这个期间里,谁记过手工凭证?"返回一个主语集合。
--
-- 【为什么只算 source_type='manual'】其余每一种 source_type 都是另一个受控动作的
-- 【后果】(一笔付款、一次销售、一次工资过账),各有各的门。把它们算进来等于
-- "凡引起过任何一笔分录的人都不许关账" —— 在一个财务只有一个人的公司里
-- 那不是控制,是一把锁死的门。要防的是那一笔【自由裁量的调整】,
-- 然后把期间锁上让它没人再看得见。范围写在这里,不留给读的人推断。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql.

CREATE OR REPLACE FUNCTION public.sod_manual_posters_in(p_from date, p_to date)
 RETURNS uuid[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(array_agg(DISTINCT je.created_by), '{}'::uuid[])
      FROM journal_entries je
     WHERE je.source_type = 'manual'
       AND je.created_by IS NOT NULL
       AND je.entry_date >= COALESCE(p_from, '-infinity'::date)
       AND je.entry_date <= p_to;
$function$;