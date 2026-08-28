-- db/functions/remit_wht.sql
-- WHT-1:把一个代扣月的预提税汇给 IRAS。
--
-- ★【它与 pay_payroll_cpf 是同一个形状,而那不是巧合 —— 是同一件事】★
--   两者都是【从别人的钱里扣下来、替他交给一个法定机构】:CPF 扣自员工的薪,
--   预提税扣自非居民收款人的款。所以两者的分录逐字同形(借那笔负债 / 贷银行)、
--   都在次月到期、都不豁免期间锁,而且【告警清除的条件都是钱真的动了】。
--   两个到期日不同(CPF 次月 14 日、预提税次月 15 日),各自来自各自的法令 ——
--   **不要"顺手统一"**:一个凑整过的法定期限,是一个会让公司逾期的数字。
--
-- ★【为什么不需要"先打开一期"】★ gst_periods 要先 open_gst_period 才能申报;
--   这里没有那个动作,因为【欠多少是推导出来的】(wht_liability_by_month 从总账
--   读代扣),不需要谁先声明这个月存在。于是"没有人开这一期,于是这个月的税
--   悄悄没人管"这种失败模式,在结构上不存在。
--
-- FIN-10:日期没有 CURRENT_DATE 默认值 —— 缺了就抛具名错误。默认成今天
-- 永远撞不上 PERIOD_LOCKED,于是留空反而比填对更容易过关。

CREATE OR REPLACE FUNCTION public.remit_wht(p_period_month date, p_remitted_on date DEFAULT NULL::date, p_filed_reference text DEFAULT NULL::text, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_month   date;
    v_amount  numeric;
    v_bank    text;
    v_base    text;
    v_ref     text;
    v_seq     integer;
    v_code    text;
    v_je      jsonb;
    v_id      uuid := gen_random_uuid();
BEGIN
    -- 【SECURITY DEFINER 必须自己问调用者是谁】一支不问的 definer 函数就是一条
    -- 绕过 RLS 的路。这个形状在本仓库【上线过两次、被闸抓住两次】——
    -- 写在这里是因为下一支新函数最容易漏的就是这一行。
    PERFORM require_permission('module.finance.edit');
    -- fu1:**也要求 view,而这条依赖是说出来的、不是碰巧成立的。**
    -- 本函数从 wht_liability_by_month 读欠款,而 fu1 起那张视图按
    -- module.finance.view 把关。不写这一句,一个持 edit 而不持 view 的角色
    -- 会读到一张空视图,然后撞上 WHT_NOTHING_TO_REMIT —— 一句【说错了原因】的
    -- 拒绝:它会说"这个月没有欠款",而真相是"你看不见它"。
    -- (实测 2026-08-28:线上三个持 edit 的角色 admin/gm/finance 都持 view,
    --  所以这一句今天不改变任何人的结果 —— 它防的是下一次配角色的人。)
    PERFORM require_permission('module.finance.view');

    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'WHT_PERIOD_REQUIRED';
    END IF;
    v_month := date_trunc('month', p_period_month)::date;

    IF p_remitted_on IS NULL THEN
        RAISE EXCEPTION 'WHT_REMIT_DATE_REQUIRED|%', v_month;
    END IF;
    IF p_remitted_on < v_month THEN
        -- 还没发生的代扣汇不出去。
        RAISE EXCEPTION 'WHT_REMIT_DATE_BEFORE_PERIOD|%|%', p_remitted_on, v_month;
    END IF;

    -- 【参考号必填,而 gst_periods 那一条允许空 —— 两者不是同一件事】
    -- GST 那边"申报"与"缴款"是两个动作,回执可能晚到;这里是【一次缴款】,
    -- 而一笔说不出参考号的缴款,日后对着 IRAS 无从交代。
    v_ref := NULLIF(btrim(COALESCE(p_filed_reference, '')), '');
    IF v_ref IS NULL THEN
        RAISE EXCEPTION 'WHT_FILED_REFERENCE_REQUIRED|%', v_month
          USING HINT = '填 IRAS S45 申报的回执/参考号 —— 一笔交代不出出处的缴款,日后无从对账';
    END IF;

    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 【银行必须是本位币户,而这一条【故意】比 pay_payroll_cpf 严】
    -- IRAS 只收新元。pay_payroll_cpf 允许 1010 却把两条腿都按本位币记 ——
    -- 那意味着一笔从美元户走的钱会被记成等额新元离开,而实际离开的是美元。
    -- 那一支不在本刀范围内(不顺手改别人的函数),但这一支不复制它。
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    IF bank_native_currency(v_bank) <> v_base THEN
        RAISE EXCEPTION 'WHT_REMIT_BANK_NOT_BASE|%|%', v_bank, bank_native_currency(v_bank)
          USING HINT = 'IRAS 只收本位币 —— 从外币户汇出去要先兑换,而那笔兑换是它自己的一笔交易';
    END IF;

    -- 【欠多少从那张视图读,不在这里再算一遍】视图是唯一的实现,而它对
    -- 冲销的处理(经 journal_activity_lines)是这条链上最容易写错的一段。
    -- 在这里重算 = 第二份实现,而两份会在写下来那天一致、之后悄悄分开。
    SELECT unremitted_base INTO v_amount
    FROM wht_liability_by_month WHERE period_month = v_month;

    IF COALESCE(v_amount, 0) <= 0 THEN
        RAISE EXCEPTION 'WHT_NOTHING_TO_REMIT|%|%', v_month, COALESCE(v_amount, 0)
          USING HINT = '这个月没有未汇的代扣税 —— 也可能是已经汇过了(补汇是新的一行,不是改旧的那一行)';
    END IF;

    -- 分录走【普通过账路径】,所以期间锁照常生效 —— 与 CPF 同一条:
    -- 一笔汇款不因为它是法定义务就可以进一个已经关掉的月份。
    v_je := post_journal_entry(
        p_remitted_on,
        'Withholding tax remittance ' || to_char(v_month, 'YYYY-MM'),
        'wht_remittance', v_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2150', 'side', 'debit',
                'currency', v_base, 'amount_ccy', v_amount,
                'line_memo', 'WHT for ' || to_char(v_month, 'YYYY-MM')),
            jsonb_build_object('account_code', v_bank, 'side', 'credit',
                'currency', v_base, 'amount_ccy', v_amount,
                'line_memo', 'IRAS ' || v_ref)));

    -- 编号:同一个月可以有多笔(补汇),第二笔起带序号。
    -- 咨询锁串行化,与 EXP/JE/收付款的取号手法一致。
    PERFORM pg_advisory_xact_lock(hashtext('wht_remit_' || to_char(v_month, 'YYYY-MM'))::bigint);
    SELECT COUNT(*) + 1 INTO v_seq FROM wht_remittances WHERE period_month = v_month;
    v_code := 'WHT-' || to_char(v_month, 'YYYY-MM') ||
              CASE WHEN v_seq > 1 THEN '-' || v_seq::text ELSE '' END;

    INSERT INTO wht_remittances (id, code, period_month, remitted_on, amount_base,
                                 filed_reference, journal_entry_id, notes, created_by)
    VALUES (v_id, v_code, v_month, p_remitted_on, v_amount,
            v_ref, (v_je->>'entry_id')::uuid, p_notes, auth.uid());

    RETURN jsonb_build_object(
        'remittance_id', v_id,
        'code', v_code,
        'period_month', v_month,
        'remitted_on', p_remitted_on,
        'amount_base', v_amount,
        'currency', v_base,
        'filed_reference', v_ref,
        'journal_code', v_je->>'code');
END;
$function$
;
