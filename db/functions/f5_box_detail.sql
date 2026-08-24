-- db/functions/f5_box_detail.sql
-- 从一格【钻回】构成它的那些单据。一份钻不进去的申报,在 IRAS 面前是交代不了的。
--
-- 【GST-2:返回的是【单据】的形状,不再是分录的形状】销项侧现在钻回的是
--   发票与贷项凭证,它们不是分录 —— 硬塞进 entry_code 这样的列名会让一个
--   发票编号顶着"分录编号"的名字出现在人面前。列因此是单据中性的:
--   doc_kind 说这是什么('invoice' / 'credit_note' / 'journal_entry'),
--   其余四列跟着它读。贷项凭证的金额是【负数】—— 它是一笔负的供应。
--
-- 【合计格与申明格钻不进去这件事要【说出来】】box4 / box8 是别的格加出来的,
-- box9 是"我们不参加",box13 是收入总额 —— 对它们返回空集,
-- 等于把"问错了"答成"没有数据"(GST_BOX_NOT_DRILLABLE)。
CREATE OR REPLACE FUNCTION public.f5_box_detail(p_period_start date, p_period_end date, p_box text)
 RETURNS TABLE(doc_kind text, doc_id uuid, doc_code text, doc_date date, memo text, tax_code text, amount_base numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    -- 【OPS-17:这里【不能】按 journal_entries.status 过滤】冲销的做法是把原分录
    -- 标成 'reversed' 再过一张【新的】'posted' 冲销分录,所以 status='posted'
    -- 会丢掉原件、留下冲销件,把一对本该抵为 0 的分录算成 -原件。
    -- cash_flow_statement 为同一件事付过账;fixture 129 的 I 臂在这里撞到它。

    IF p_box IS NULL THEN RAISE EXCEPTION 'GST_BOX_REQUIRED'; END IF;
    IF p_box NOT IN ('box1','box2','box3','box5','box6','box7') THEN
        -- 【合计格与结构性零格【钻不进去】,而这要说出来,不能返回空集】
        -- box4 与 box8 是别的格加出来的,box9 是"我们不参加",box13 是收入总额。
        RAISE EXCEPTION 'GST_BOX_NOT_DRILLABLE|%', p_box;
    END IF;

    IF p_box IN ('box1','box2','box3','box6') THEN
        -- ── 销项侧:发票行 + 贷项凭证行(后者是负数)────────────────────────
        RETURN QUERY
        SELECT 'invoice'::text, i.id, i.code, i.issue_date,
               il.description, il.tax_code,
               CASE WHEN p_box = 'box6' THEN round(il.tax_base, 2)
                    ELSE round(il.amount_base, 2) END
          FROM invoice_lines il
          JOIN invoices i ON i.id = il.invoice_id
         WHERE i.issue_date BETWEEN p_period_start AND p_period_end
           AND i.status <> 'void'
           AND il.tax_code IS NOT NULL
           AND (   (p_box = 'box1' AND il.tax_code = 'SR')
                OR (p_box = 'box2' AND il.tax_code = 'ZR')
                OR (p_box = 'box3' AND il.tax_code = 'ES')
                OR (p_box = 'box6' AND il.tax_base <> 0))
        UNION ALL
        SELECT 'credit_note'::text, cn.id, cn.code, cn.note_date,
               'CN ' || cn.reason, cnl.tax_code,
               CASE WHEN p_box = 'box6' THEN -round(cnl.tax_base, 2)
                    ELSE -round(cnl.amount * cn.fx_rate, 2) END
          FROM credit_note_lines cnl
          JOIN credit_notes cn ON cn.id = cnl.credit_note_id
         WHERE cn.note_date BETWEEN p_period_start AND p_period_end
           AND cnl.tax_code IS NOT NULL
           AND (   (p_box = 'box1' AND cnl.tax_code = 'SR')
                OR (p_box = 'box2' AND cnl.tax_code = 'ZR')
                OR (p_box = 'box3' AND cnl.tax_code = 'ES')
                OR (p_box = 'box6' AND cnl.tax_base <> 0))
         ORDER BY 4, 3;
    ELSE
        -- ── 进项侧:仍然是分录 ──────────────────────────────────────────────
        RETURN QUERY
        SELECT 'journal_entry'::text, je.id, je.code, je.entry_date,
               COALESCE(jl.line_memo, je.memo), jl.tax_code,
               round(jl.debit - jl.credit, 2)
          FROM journal_lines jl
          JOIN journal_entries je ON je.id = jl.entry_id
          LEFT JOIN accounts a ON a.id = jl.account_id
         WHERE je.entry_date BETWEEN p_period_start AND p_period_end
           AND (   (p_box = 'box5' AND jl.tax_code IN ('TX','ZP','BL'))
                OR (p_box = 'box7' AND a.code = '1400'))
         ORDER BY je.entry_date, je.code;
    END IF;
END;
$function$
;