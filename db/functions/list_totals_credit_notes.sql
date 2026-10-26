-- db/functions/list_totals_credit_notes.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1–Q3):/finance/credit-notes 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】无(app/finance/credit-notes/creditNoteRows.ts 的 creditNoteCount / creditNotePage 只排序,不筛)。
-- 【量】total = Σ credit_note_lines.amount(凭证本身不存合计,是各行之和 —— 与 shapeCreditNoteRows 同一个数),
--   按表头 credit_notes.currency 分组,每个币种一行。
-- 【净额】凭证不可变、没有作废或冲销(credit_notes.sql:33),没有要抵的。
-- 【门】require_permission('module.finance.view') —— 与页面守卫 requireModule(MOD.finance)、与 credit_notes / credit_note_lines
--   的 SELECT 策略同一个码。invoker;金额不遮(只有客户名按 module.customers.view 遮),restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_credit_notes()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text,
           cn.currency::text,
           'total'::text,
           round(sum(l.amount), 2),
           false
      FROM credit_notes cn
      JOIN credit_note_lines l ON l.credit_note_id = cn.id
     GROUP BY 2
     ORDER BY 2;
END;
$function$;