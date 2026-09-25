-- db/functions/sod_manual_posters_in.sql
-- SOD-1:问法① —— "这个期间里,谁记过手工凭证?"返回一个主语集合。
--
-- 【为什么只算 source_type='manual'】其余每一种 source_type 都是另一个受控动作的
-- 【后果】(一笔付款、一次销售、一次工资过账),各有各的门。把它们算进来等于
-- "凡引起过任何一笔分录的人都不许关账" —— 在一个财务只有一个人的公司里
-- 那不是控制,是一把锁死的门。要防的是那一笔【自由裁量的调整】,
-- 然后把期间锁上让它没人再看得见。范围写在这里,不留给读的人推断。
--
-- ★ APR-6(2026-09-25,grilling Q5):**"谁记的"从此是【提单人】,不是过账那一刻的 auth.uid()。**
--   APR-6 起一张手工凭证在 CFO 批准那一刻才过账,于是 journal_entries.created_by(列默认 auth.uid())是
--   批准的 CFO。照旧读它,规矩就会绑错人:CFO(以及与他同一个人的 admin@)从此锁不了那个月,而真正敲
--   那一笔的财务锁得了 —— 财务是提单人时,两边一起锁死,月结没人关得了。所以:
--     主语 = COALESCE(申请的 created_by, 分录的 created_by),经 journal_requests.result_journal_entry_id 接回。
--   · APR-6 之前直接过的手工凭证(没有申请)照旧读 created_by —— JE-2026-0079 仍然算 chooer@。
--   · 范围多了一类:【经冲销申请冲掉的系统分录】(冲销件抄原分录的 source_type,例如 'sale')。
--     从凭证页冲一张 sale 分录是一个人的裁量,与手敲一张凭证是同一件事,所以它的提单人也算。
--   · 批准的 CFO 【不是】记手工凭证的人 —— 他看过、批过,那是四眼的另一只眼。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql.

CREATE OR REPLACE FUNCTION public.sod_manual_posters_in(p_from date, p_to date)
 RETURNS uuid[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(array_agg(DISTINCT COALESCE(jr.created_by, je.created_by)), '{}'::uuid[])
      FROM journal_entries je
      LEFT JOIN journal_requests jr ON jr.result_journal_entry_id = je.id
     WHERE (je.source_type = 'manual' OR jr.id IS NOT NULL)
       AND COALESCE(jr.created_by, je.created_by) IS NOT NULL
       AND je.entry_date >= COALESCE(p_from, '-infinity'::date)
       AND je.entry_date <= p_to;
$function$;
