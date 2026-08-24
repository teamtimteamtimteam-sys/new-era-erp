-- db/functions/f5_return.sql
-- GST-1:F5,按 IRAS 自己的格号与措辞,**每一格从总账推导**,不接受手填。
-- 【勾稽】box6 由两条【互相独立】的路各算一遍:一条读税科目 2100,
-- 一条按标准税率供应额 × 每张分录自己那一天的法定税率重算。过账把税算错了,
-- 两者就会分开 —— fixture 128 的 F2b 臂真的把它弄分开过(95.00 vs 99.00)。
-- 【box9 标 derived=false】我们不在 MES 之类的计划里 ——
-- "没有参加"与"算出来是零"不是一回事,屏幕上也照这个区别显示。

CREATE OR REPLACE FUNCTION public.f5_return(p_period_start date, p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_box1 numeric := 0; v_box2 numeric := 0; v_box3 numeric := 0;
    v_box5 numeric := 0; v_box6 numeric := 0; v_box7 numeric := 0;
    v_box13 numeric := 0;
    v_box6_recomputed numeric := 0;
    v_base text;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_start IS NULL OR p_period_end IS NULL THEN
        RAISE EXCEPTION 'GST_PERIOD_DATES_REQUIRED';
    END IF;
    IF p_period_end < p_period_start THEN
        RAISE EXCEPTION 'GST_PERIOD_WINDOW_INVALID|%|%', p_period_start, p_period_end;
    END IF;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 【供应额】按税码分格。销项是贷方净额(收入在贷方),所以取 credit - debit。
    SELECT
      COALESCE(SUM(jl.credit - jl.debit) FILTER (WHERE jl.tax_code = 'SR'), 0),
      COALESCE(SUM(jl.credit - jl.debit) FILTER (WHERE jl.tax_code = 'ZR'), 0),
      COALESCE(SUM(jl.credit - jl.debit) FILTER (WHERE jl.tax_code = 'ES'), 0)
      INTO v_box1, v_box2, v_box3
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
     WHERE je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted';

    -- 【采购额】进项侧是借方净额。BL(不可抵)【也要报采购额】,只是税不抵 ——
    -- 那正是税码存在的理由:税率分不开"可抵"与"不可抵"。
    SELECT COALESCE(SUM(jl.debit - jl.credit) FILTER (WHERE jl.tax_code IN ('TX','ZP','BL')), 0)
      INTO v_box5
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
     WHERE je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted';

    -- 【税额】从税科目本身取 —— 这是第一条路。
    SELECT COALESCE(SUM(jl.credit - jl.debit), 0) INTO v_box6
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
      JOIN accounts a ON a.id = jl.account_id
     WHERE a.code = '2100' AND je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted';
    SELECT COALESCE(SUM(jl.debit - jl.credit), 0) INTO v_box7
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
      JOIN accounts a ON a.id = jl.account_id
     WHERE a.code = '1400' AND je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted';

    -- 【第二条路,与上面那条【互相独立】】从供应额 × 当期法定税率重算销项税。
    -- 一条读【税科目】,一条读【供应额与法令】。过账算错了税,两者就会分开 ——
    -- 这正是 OPS-17 那条"两边必须能分开才算勾稽"的要求。
    SELECT COALESCE(SUM(round((jl.credit - jl.debit) * tax_rate_for(jl.tax_code, je.entry_date) / 100.0, 2)), 0)
      INTO v_box6_recomputed
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
     WHERE je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted' AND jl.tax_code = 'SR';

    -- 【Box 13 收入】总收入,从收入类科目取。
    SELECT COALESCE(SUM(jl.credit - jl.debit), 0) INTO v_box13
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
      JOIN accounts a ON a.id = jl.account_id
     WHERE a.account_type = 'revenue' AND je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted';

    RETURN jsonb_build_object(
      'period_start', p_period_start, 'period_end', p_period_end, 'currency', v_base,
      'boxes', jsonb_build_array(
        jsonb_build_object('box','box1','label_en','Total value of standard-rated supplies','label_zh','标准税率供应总额','value', round(v_box1,2),'derived',true),
        jsonb_build_object('box','box2','label_en','Total value of zero-rated supplies','label_zh','零税率供应总额','value', round(v_box2,2),'derived',true),
        jsonb_build_object('box','box3','label_en','Total value of exempt supplies','label_zh','豁免供应总额','value', round(v_box3,2),'derived',true),
        jsonb_build_object('box','box4','label_en','Total value of (1) + (2) + (3)','label_zh','(1)+(2)+(3) 合计','value', round(v_box1+v_box2+v_box3,2),'derived',true),
        jsonb_build_object('box','box5','label_en','Total value of taxable purchases','label_zh','应税采购总额','value', round(v_box5,2),'derived',true),
        jsonb_build_object('box','box6','label_en','Output tax due','label_zh','应缴销项税','value', round(v_box6,2),'derived',true),
        jsonb_build_object('box','box7','label_en','Input tax and refunds claimed','label_zh','已抵进项税与退税','value', round(v_box7,2),'derived',true),
        jsonb_build_object('box','box8','label_en','Net GST to be paid to / claimed from IRAS','label_zh','应缴/应退 GST 净额','value', round(v_box6 - v_box7,2),'derived',true),
        -- 【Box 9 结构性为零,而这不是"算出来是零"】我们不在 MES / A3PL 之类的
        -- 计划里。说"没有参加"与说"算出来是零"不是一回事,所以它标 derived=false。
        jsonb_build_object('box','box9','label_en','Total value of goods imported under approved schemes','label_zh','按核准计划进口的货物总额','value', 0,'derived',false,
                           'note_en','Structurally zero: this company is not on MES or any approved import scheme.','note_zh','结构性为零:本公司不在 MES 或任何核准进口计划内。'),
        jsonb_build_object('box','box13','label_en','Revenue','label_zh','营业收入','value', round(v_box13,2),'derived',true)
      ),
      -- 【勾稽:两条独立的路】
      'ties', jsonb_build_object(
        'box6_from_tax_account', round(v_box6,2),
        'box6_recomputed_from_supplies', round(v_box6_recomputed,2),
        'agrees', round(v_box6,2) = round(v_box6_recomputed,2),
        'how_en','Box 6 is read from account 2100. It is independently recomputed as standard-rated supply value times the statutory rate for each entry''s own date. A posting error moves one and not the other.',
        'how_zh','Box 6 从 2100 科目读出;另一条路用标准税率供应额乘以每张分录【自己那一天】的法定税率重算。过账算错税,两者就会分开。'
      ),
      -- 【本次未接线的单据族,照直说出来】
      'coverage', jsonb_build_object(
        'wired_en','Journal lines carrying a tax_code. Documents post through post_journal_entry, so any document family whose posting stamps a tax code is included automatically.',
        'wired_zh','带 tax_code 的分录行。单据都经 post_journal_entry 过账,所以任何在过账时盖上税码的单据族都自动被纳入。'
      ));
END;
$function$;