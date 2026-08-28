-- db/functions/gl_control_reconciliation.sql
-- GLEXPORT-1:控制科目 ↔ 明细账的勾稽(AR = 1100,AP = 2000)。
--
-- ★【为什么这一条才是管理报表包里【唯一】一条真勾稽】★
--   `pnl_statement` 与 `balance_sheet` **都读 journal_activity_lines**,只差两个开关
--   (期间/累计、剔除/包含年结)。所以"损益对资产负债"是【一份推导的两个开关】,
--   不是两份推导 —— 拿它当勾稽,正是 OPS-17 抓到的那个病(两边一起错,旗子永远绿)。
--   AGENTS.md 自己那张表也已经把 `balance_sheet.balanced` 标成【结构性恒真】。
--
--   **这里的两边来自两套完全不同的表:**
--     · 账面侧 = 总账(journal_entries / journal_lines / accounts);
--     · 明细侧 = 单据(sales_records / invoices / inbound_batches / expenses /
--                payment_allocations / credit_notes),经 ar_aging_asof / ap_aging_asof。
--   它们【能够】分开,而且实测就是分开的 —— 见下面那段实测。
--
-- ★★【`unexplained_base` 不许被算术逼成零 —— 这是本函数最要紧的一行设计】★★
--   最容易写错的版本是给账面侧留一个"其他"兜底桶:那样各分项之和【恒等于】
--   账面余额,于是未解释差额永远是 0,而一个永远为 0 的判词是装饰,不是检查。
--   **所以分类是【穷举式声明】的,没有兜底:** 只有 origination / settlement /
--   revaluation 三类被扣掉,任何【没有被分类的来源】(manual、year_close、
--   writeoff、以及将来新增的任何 source_type)都会原样留在 unexplained 里。
--   于是它【动得开】,而且动的方向正是要紧的那个:
--   **一笔手工分录打进控制科目 —— 这恰恰是现实中把明细账与总账弄散的头号原因 ——
--   会让它当场不为零。** db/fixtures/143 的 D 臂就注入这一笔。
--
-- 【实测(2026-08-28),三个分项把差额【逐分钱】解释干净,余额 0.00】
--   AR:账面 1100 = 43,002.12,明细 = 57,443.00,差 14,440.88
--       = 起单差异 20,247.13 + 结算差异 250.00 − 重估 6,056.25
--       (起单差异里 20,350.00 是 OUT-2026-0007 —— 它在明细账里,而总账里
--        **一张分录都没有**;那是 docs/known-wrong-until-cutover.md 第 13 行
--        记着的 cutover 前测试数据。结算差异 250.00 是 RCPT-2026-0001 挂账未核销。)
--   AP:账面 2000 = 371,950.04,明细 = 429,537.62,差 57,587.58
--       = 起单差异 62,175.68 + 结算差异 0.96 − 重估 4,589.06
--       (起单差异主要是五张 cutover 前的进料批次 —— IN-2026-0001/0002/0003/0011/0012
--        在明细账里有价,而总账里没有【存活的】应付分录:0001 与 0003 的计价分录
--        被冲销后再没有按新价补过。)
--
-- 【符号约定,写出来因为它是最容易搞反的一处】
--   AR 是资产:账面余额 = Σ(借−贷);AP 是负债:账面余额 = Σ(贷−借)。
--   两侧统一成"正数 = 还欠着的钱",于是下面同一段算术两侧共用。

CREATE OR REPLACE FUNCTION public.gl_control_reconciliation(p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base      text;
    v_sides     jsonb := '[]'::jsonb;
    v_side      text;
    v_acct      text;
    v_orig_src  text[];
    v_settle_src text[];
    v_ledger    numeric;
    v_orig_led  numeric;
    v_settle_led numeric;
    v_reval_led numeric;
    v_sub       jsonb;
    v_sub_total numeric;
    v_sub_value numeric;
    v_sub_reduce numeric;
    v_diff      numeric;
    v_ov        numeric;
    v_sv        numeric;
    v_unexp     numeric;
BEGIN
    -- 【SECURITY DEFINER 必须自己问调用者是谁】一支不问的 definer 函数就是一条
    -- 绕过 RLS 的路;这个形状在本仓库上线过两次、两次都由闸抓住。
    PERFORM require_permission('module.finance.view');
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'AS_OF_REQUIRED';
    END IF;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    FOREACH v_side IN ARRAY ARRAY['ar', 'ap'] LOOP
        IF v_side = 'ar' THEN
            v_acct := '1100';
            -- 起单:销售与订单流发票把应收记上去。
            v_orig_src   := ARRAY['sale', 'invoice'];
            -- 结算:收款把它冲掉;贷项凭证也把它冲掉(「不用付了」,不是「付过了」)。
            v_settle_src := ARRAY['payment', 'credit_note'];
        ELSE
            v_acct := '2000';
            -- 起单:进料计价、费用单、运费单把应付记上去。
            v_orig_src   := ARRAY['purchase', 'expense', 'freight'];
            -- 结算:付款冲掉它;预付冲抵把 1300 挪过来抵掉它。
            v_settle_src := ARRAY['payment', 'prepayment'];
        END IF;

        -- ── 账面侧:一次权威取数,外加按来源的三类分项 ────────────────────
        -- 【经 journal_activity_lines,所以【不】按 status 过滤】冲销的做法是
        -- 原分录标 reversed + 过一张等额反向的 posted 分录;只留 posted 会丢原件
        -- 留冲销件,净额错成 −原件。这个病在本仓库现身过四次,其中一次
        -- (bank_reconciliation_status)在线上错了几个月,差 USD 1,585.00。
        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN l.debit - l.credit
                                 ELSE l.credit - l.debit END), 0)
          INTO v_ledger
          FROM journal_activity_lines(NULL, p_as_of, true) l
         WHERE l.account_code = v_acct;

        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN l.debit - l.credit
                                 ELSE l.credit - l.debit END), 0)
          INTO v_orig_led
          FROM journal_activity_lines(NULL, p_as_of, true) l
         WHERE l.account_code = v_acct AND l.source_type = ANY(v_orig_src);

        -- 结算取正:它是【把控制科目减下去】的那一侧。
        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN l.credit - l.debit
                                 ELSE l.debit - l.credit END), 0)
          INTO v_settle_led
          FROM journal_activity_lines(NULL, p_as_of, true) l
         WHERE l.account_code = v_acct AND l.source_type = ANY(v_settle_src);

        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN l.debit - l.credit
                                 ELSE l.credit - l.debit END), 0)
          INTO v_reval_led
          FROM journal_activity_lines(NULL, p_as_of, true) l
         WHERE l.account_code = v_acct AND l.source_type = 'revaluation';

        -- ── 明细侧:单据。**另一套表,这就是"两边能分开"的全部依据** ────────
        v_sub := CASE WHEN v_side = 'ar' THEN ar_aging_asof(p_as_of)
                                         ELSE ap_aging_asof(p_as_of) END;
        v_sub_total := (v_sub->>'total_open_base')::numeric;

        -- 单据面值与单据上被冲掉的部分,【从行里加出来】——
        -- 与 total_open_base 是两个数,而"行加起来等于那个数"本身就是一条断言
        -- (fixture 80 的形状)。两者不等时差额会落进 unexplained,不会被抹平。
        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN (r->>'amount_base')::numeric
                                 ELSE (r->>'doc_value_base')::numeric END), 0),
               COALESCE(SUM(CASE WHEN v_side = 'ar'
                                 THEN (r->>'settled_base')::numeric + COALESCE((r->>'credited_base')::numeric, 0)
                                 ELSE (r->>'settled_base')::numeric END), 0)
          INTO v_sub_value, v_sub_reduce
          FROM jsonb_array_elements(v_sub->'rows') r;

        -- ── 三个分项 ──────────────────────────────────────────────────────
        v_diff := round(v_sub_total - v_ledger, 2);
        --   起单差异:单据说欠了多少,总账认了多少。正 = 有单据没进总账。
        v_ov   := round(v_sub_value - v_orig_led, 2);
        --   结算差异:总账冲掉了多少,单据上被冲掉了多少。正 = 钱冲了总账没冲单据
        --   (挂账未核销的收付款正是这一种)。
        v_sv   := round(v_settle_led - v_sub_reduce, 2);
        --   ★【没有兜底桶】★ 只扣这三项;任何没有被分类的来源原样留在余额里。
        v_unexp := round(v_diff - (v_ov + v_sv - v_reval_led), 2);

        v_sides := v_sides || jsonb_build_object(
            'side',                     v_side,
            'control_account',          v_acct,
            'ledger_base',              round(v_ledger, 2),
            'subledger_base',           round(v_sub_total, 2),
            'difference_base',          v_diff,
            'origination_variance_base', v_ov,
            'settlement_variance_base',  v_sv,
            'revaluation_base',          round(v_reval_led, 2),
            'unexplained_base',          v_unexp,
            -- 【勾稽上不上,判据是【余额】,不是差额】差额不为零是正常的、
            -- 而且是有意义的(重估、挂账、cutover 前的单据都会让它不为零);
            -- 【余额】不为零才是一件没有人解释过的事。
            'reconciled',                (v_unexp = 0));
    END LOOP;

    RETURN jsonb_build_object(
        'as_of',         p_as_of,
        'base_currency', v_base,
        'sides',         v_sides);
END;
$function$
;
