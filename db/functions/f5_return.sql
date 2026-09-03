-- db/functions/f5_return.sql
-- GST-2(2026-08-25):**销项侧改从【发票】推导,进项侧仍走总账。**
-- 税点是【开票与收款孰早】,而这里实现的是开票那一半(Tim 的裁定,选项 A)。
--
-- 【逐格的来源】box1/2/3/6 ← 发票行 减 贷项凭证行(按【单据自己的日期】落期间);
--   box5/box7/box13 ← 总账;box4/box8 ← 别的格加出来的;box9 ← 结构性为零。
--   每一格在返回里【自报】它的来源(source),屏幕上照着印。
--
-- 【为什么销项侧换了、进项侧没换】销项的税点是开票日,而这套账在【销售】那一刻
--   确认收入 —— 两者跨季会分开,所以供应额必须离开总账、回到发票上;
--   进项的税点是供应商税务发票的日期,而 expense_date 记的正是那一天 ——
--   总账口径与法定口径在进项侧本来就重合,没有要修的东西。
--
-- ★【勾稽:三处说法,两条比较,两条都成立才算勾稽上】★
--   销项税这一个数有三处各自说得出来的说法:① 冻在发票行上的、
--   ② 按开票那天的法定税率当场重算的、③ 过进 2100 科目的。
--   只比两处,第三处就没有人看着。①vs② 抓税率错或数被人改过;
--   ①vs③ 抓某张票没过账、作废没冲销、或有人手工动过 2100。
--   fixture 129 的 C1 / C2 臂各自把两条弄分开过 —— 它们会响。
--
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
    v_inv1 numeric := 0; v_inv2 numeric := 0; v_inv3 numeric := 0; v_inv_tax numeric := 0;
    v_cn1  numeric := 0; v_cn2  numeric := 0; v_cn3  numeric := 0; v_cn_tax  numeric := 0;
    v_stat_inv numeric := 0; v_stat_cn numeric := 0;
    v_box6_docs    numeric := 0;   -- ① 单据
    v_box6_statute numeric := 0;   -- ② 法令
    v_box6_ledger  numeric := 0;   -- ③ 总账
    v_base text;
BEGIN
    PERFORM require_permission('module.finance.view');
    -- 【OPS-17:这里【不能】按 journal_entries.status 过滤】冲销的做法是把原分录
    -- 标成 'reversed' 再过一张【新的】'posted' 冲销分录,所以 status='posted'
    -- 会丢掉原件、留下冲销件,把一对本该抵为 0 的分录算成 -原件。
    -- cash_flow_statement 为同一件事付过账;fixture 129 的 I 臂在这里撞到它。

    IF p_period_start IS NULL OR p_period_end IS NULL THEN
        RAISE EXCEPTION 'GST_PERIOD_DATES_REQUIRED';
    END IF;
    IF p_period_end < p_period_start THEN
        RAISE EXCEPTION 'GST_PERIOD_WINDOW_INVALID|%|%', p_period_start, p_period_end;
    END IF;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ── 供应额与销项税:【发票】────────────────────────────────────────────
    -- 【作废的票不算】它对外已经不成立了;而它那张只过税的分录也已冲销,
    -- 所以两条勾稽都跟着一起走。
    SELECT
      COALESCE(SUM(il.amount_base) FILTER (WHERE il.tax_code = 'SR'), 0),
      COALESCE(SUM(il.amount_base) FILTER (WHERE il.tax_code = 'ZR'), 0),
      COALESCE(SUM(il.amount_base) FILTER (WHERE il.tax_code = 'ES'), 0),
      COALESCE(SUM(il.tax_base), 0)
      INTO v_inv1, v_inv2, v_inv3, v_inv_tax
      FROM invoice_lines il
      JOIN invoices i ON i.id = il.invoice_id
     WHERE i.issue_date BETWEEN p_period_start AND p_period_end
       AND i.status <> 'void';

    -- ── 贷项凭证:一笔【负的供应】,按凭证自己的单据日落期间 ────────────────
    SELECT
      COALESCE(SUM(round(cnl.amount * cn.fx_rate, 2)) FILTER (WHERE cnl.tax_code = 'SR'), 0),
      COALESCE(SUM(round(cnl.amount * cn.fx_rate, 2)) FILTER (WHERE cnl.tax_code = 'ZR'), 0),
      COALESCE(SUM(round(cnl.amount * cn.fx_rate, 2)) FILTER (WHERE cnl.tax_code = 'ES'), 0),
      COALESCE(SUM(cnl.tax_base), 0)
      INTO v_cn1, v_cn2, v_cn3, v_cn_tax
      FROM credit_note_lines cnl
      JOIN credit_notes cn ON cn.id = cnl.credit_note_id
     WHERE cn.note_date BETWEEN p_period_start AND p_period_end;

    v_box1 := v_inv1 - v_cn1;
    v_box2 := v_inv2 - v_cn2;
    v_box3 := v_inv3 - v_cn3;
    v_box6_docs := v_inv_tax - v_cn_tax;

    -- ── ② 法令:当场按【单据自己那一天】的法定税率重算,不读任何冻住的值 ──
    -- PO-GST-1:提取成 tax_amount_for(表达式逐字未变,值不可能变)。
    SELECT COALESCE(SUM(tax_amount_for(il.amount_base, tax_rate_for(il.tax_code, i.issue_date))), 0)
      INTO v_stat_inv
      FROM invoice_lines il
      JOIN invoices i ON i.id = il.invoice_id
     WHERE i.issue_date BETWEEN p_period_start AND p_period_end
       AND i.status <> 'void'
       AND il.tax_code IS NOT NULL;
    -- 【贷项凭证按【它冲的那张发票】的开票日取税率】退的是那一笔供应的税,
    -- 而那笔税是按当年的法定税率收的 —— 按凭证日重算会用今天的税率退去年的税。
    SELECT COALESCE(SUM(round(round(cnl.amount * cn.fx_rate, 2)
                              * tax_rate_for(cnl.tax_code, oi.issue_date) / 100.0, 2)), 0)
      INTO v_stat_cn
      FROM credit_note_lines cnl
      JOIN credit_notes cn ON cn.id = cnl.credit_note_id
      JOIN invoice_lines oil ON oil.id = cnl.invoice_line_id
      JOIN invoices oi ON oi.id = oil.invoice_id
     WHERE cn.note_date BETWEEN p_period_start AND p_period_end
       AND cnl.tax_code IS NOT NULL;
    v_box6_statute := v_stat_inv - v_stat_cn;

    -- ── ③ 总账:2100 科目本身 ──────────────────────────────────────────────
    SELECT COALESCE(SUM(jl.credit - jl.debit), 0) INTO v_box6_ledger
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
      JOIN accounts a ON a.id = jl.account_id
     WHERE a.code = '2100' AND je.entry_date BETWEEN p_period_start AND p_period_end;

    -- 【报出去的那一格用【单据】那一个】客户手里那张纸上印的就是它,
    -- 而 IRAS 问的是"你开出去的税是多少"。另外两条是用来验它的,不是用来替它的。
    v_box6 := v_box6_docs;

    -- ── 采购额与进项税:【总账】—— 进项侧的税点与记账时点重合 ───────────────
    -- BL(不可抵)【也要报采购额】,只是税不抵 —— 那正是税码存在的理由。
    SELECT COALESCE(SUM(jl.debit - jl.credit) FILTER (WHERE jl.tax_code IN ('TX','ZP','BL')), 0)
      INTO v_box5
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
     WHERE je.entry_date BETWEEN p_period_start AND p_period_end;

    SELECT COALESCE(SUM(jl.debit - jl.credit), 0) INTO v_box7
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
      JOIN accounts a ON a.id = jl.account_id
     WHERE a.code = '1400' AND je.entry_date BETWEEN p_period_start AND p_period_end;

    -- 【Box 13 收入】会计口径的总收入,从收入类科目取。**它与 box1 在季度边界上
    -- 本来就会不同** —— box1 是开票口径、box13 是确认口径。两个不同的问题。
    SELECT COALESCE(SUM(jl.credit - jl.debit), 0) INTO v_box13
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
      JOIN accounts a ON a.id = jl.account_id
     WHERE a.account_type = 'revenue' AND je.entry_date BETWEEN p_period_start AND p_period_end;

    RETURN jsonb_build_object(
      'period_start', p_period_start, 'period_end', p_period_end, 'currency', v_base,
      'boxes', jsonb_build_array(
        jsonb_build_object('box','box1','label_en','Total value of standard-rated supplies','label_zh','标准税率供应总额','value', round(v_box1,2),'derived',true,'source','invoices'),
        jsonb_build_object('box','box2','label_en','Total value of zero-rated supplies','label_zh','零税率供应总额','value', round(v_box2,2),'derived',true,'source','invoices'),
        jsonb_build_object('box','box3','label_en','Total value of exempt supplies','label_zh','豁免供应总额','value', round(v_box3,2),'derived',true,'source','invoices'),
        jsonb_build_object('box','box4','label_en','Total value of (1) + (2) + (3)','label_zh','(1)+(2)+(3) 合计','value', round(v_box1+v_box2+v_box3,2),'derived',true,'source','computed'),
        jsonb_build_object('box','box5','label_en','Total value of taxable purchases','label_zh','应税采购总额','value', round(v_box5,2),'derived',true,'source','ledger'),
        jsonb_build_object('box','box6','label_en','Output tax due','label_zh','应缴销项税','value', round(v_box6,2),'derived',true,'source','invoices'),
        jsonb_build_object('box','box7','label_en','Input tax and refunds claimed','label_zh','已抵进项税与退税','value', round(v_box7,2),'derived',true,'source','ledger'),
        jsonb_build_object('box','box8','label_en','Net GST to be paid to / claimed from IRAS','label_zh','应缴/应退 GST 净额','value', round(v_box6 - v_box7,2),'derived',true,'source','computed'),
        jsonb_build_object('box','box9','label_en','Total value of goods imported under approved schemes','label_zh','按核准计划进口的货物总额','value', 0,'derived',false,'source','none',
                           'note_en','Structurally zero: this company is not on MES or any approved import scheme.','note_zh','结构性为零:本公司不在 MES 或任何核准进口计划内。'),
        jsonb_build_object('box','box13','label_en','Revenue','label_zh','营业收入','value', round(v_box13,2),'derived',true,'source','ledger')
      ),
      -- 【勾稽:三处说法,两条比较 —— 两条都成立才算勾稽上】
      'ties', jsonb_build_object(
        'box6_from_documents', round(v_box6_docs,2),
        'box6_recomputed_from_statute', round(v_box6_statute,2),
        'box6_from_tax_account', round(v_box6_ledger,2),
        'agrees_documents_vs_statute', round(v_box6_docs,2) = round(v_box6_statute,2),
        'agrees_documents_vs_ledger',  round(v_box6_docs,2) = round(v_box6_ledger,2),
        'agrees', round(v_box6_docs,2) = round(v_box6_statute,2)
                  AND round(v_box6_docs,2) = round(v_box6_ledger,2),
        'how_en','Output tax is stated three times over: frozen on the invoice line, recomputed here from the statutory rate for the invoice''s own date, and posted to account 2100. Two comparisons, both must hold. Documents vs statute catches a wrong rate or a tampered figure; documents vs ledger catches an invoice that never posted, a void that never reversed, or a hand-made entry against 2100.',
        'how_zh','销项税在系统里有三处说法:冻在发票行上的、按【开票那一天】的法定税率当场重算的、以及过进 2100 科目的。两条比较都必须成立。单据对法令,抓的是税率错或数被人改过;单据对总账,抓的是某张票没过账、作废没冲销、或有人手工动过 2100。'
      ),
      'coverage', jsonb_build_object(
        'wired_en','Output side: invoices (sale and order kinds) and credit notes, by the document''s own date — Singapore''s time of supply is the earlier of invoice or payment, and the invoice half is what is implemented. Input side: journal lines carrying an input tax code, whose posting date is the supplier tax invoice date. NOT covered: a customer payment received before any invoice — refused by name (GST_UNALLOCATED_RECEIPT_UNSUPPORTED) rather than reported untaxed.',
        'wired_zh','销项侧:发票(sale 与 order 两种)与贷项凭证,按单据自己的日期落期间 —— 新加坡的供应时点是【开票与收款孰早】,这里实现的是开票那一半。进项侧:带进项税码的分录行,其过账日就是供应商税务发票的日期。**没有覆盖的**:先于任何发票收到的客户款 —— 它被按名拒绝(GST_UNALLOCATED_RECEIPT_UNSUPPORTED),而不是无声地当成没有税。'
      ));
END;
$function$
;