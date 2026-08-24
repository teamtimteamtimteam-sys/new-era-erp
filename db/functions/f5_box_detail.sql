-- db/functions/f5_box_detail.sql
-- GST-1:从一格【钻回】构成它的那些分录与单据。一份钻不进去的申报,
-- 在 IRAS 面前是交代不了的。
-- 【合计格与申明格钻不进去这件事要【说出来】】box4 / box8 是别的格加出来的,
-- box9 是"我们不参加" —— 对它们返回空集,等于把"问错了"answered 成"没有数据"。

CREATE OR REPLACE FUNCTION public.f5_box_detail(p_period_start date, p_period_end date, p_box text)
 RETURNS TABLE(entry_id uuid, entry_code text, entry_date date, memo text, source_type text, source_id uuid, tax_code text, amount_base numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_box IS NULL THEN RAISE EXCEPTION 'GST_BOX_REQUIRED'; END IF;
    IF p_box NOT IN ('box1','box2','box3','box5','box6','box7') THEN
        -- 【合计格与结构性零格【钻不进去】,而这要说出来,不能返回空集】
        -- box4 与 box8 是别的格加出来的,box9 是"我们不参加",box13 是收入总额。
        RAISE EXCEPTION 'GST_BOX_NOT_DRILLABLE|%', p_box;
    END IF;
    RETURN QUERY
    SELECT je.id, je.code, je.entry_date, je.memo, je.source_type, je.source_id,
           jl.tax_code,
           CASE
             WHEN p_box IN ('box1','box2','box3') THEN round(jl.credit - jl.debit, 2)
             WHEN p_box = 'box5' THEN round(jl.debit - jl.credit, 2)
             WHEN p_box = 'box6' THEN round(jl.credit - jl.debit, 2)
             ELSE round(jl.debit - jl.credit, 2)
           END
      FROM journal_lines jl
      JOIN journal_entries je ON je.id = jl.entry_id
      LEFT JOIN accounts a ON a.id = jl.account_id
     WHERE je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted'
       AND (
            (p_box = 'box1' AND jl.tax_code = 'SR')
         OR (p_box = 'box2' AND jl.tax_code = 'ZR')
         OR (p_box = 'box3' AND jl.tax_code = 'ES')
         OR (p_box = 'box5' AND jl.tax_code IN ('TX','ZP','BL'))
         OR (p_box = 'box6' AND a.code = '2100')
         OR (p_box = 'box7' AND a.code = '1400')
       )
     ORDER BY je.entry_date, je.code;
END;
$function$;