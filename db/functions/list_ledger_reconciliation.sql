-- db/functions/list_ledger_reconciliation.sql
-- AP-RECON-1 Batch B(2026-09-24):清单与总账的常设勾稽 —— 应付清单 ↔ 2000,应收清单 ↔ 1100。
--
-- 【它问的是一个问题,而且只问这一个】此刻清单上说欠的,与总账科目上记的,差多少;
-- 那一笔差里每一分钱有没有名字。
--   · 清单 = ap_open_items / ar_open_items 的 Σ open_base —— 应付页、应收页、付款表单
--     预填的都是它。
--   · 总账 = 控制科目【全账】余额(journal_lines,不截日、不按 status 过滤 ——
--     冲销对的两条腿都在,全时段净额为 0;FRT-2027-* 那三对因此自己抵掉)。
--
-- 【允许的差只有三种,一种也不多】(Tim AP-RECON-1 Q6 / Q8–Q10;Batch B Q1–Q2)
--   1. residue    —— list_ledger_residue 里逐单据登记的已知残留(只有迁移能写;
--                    重建库上为空)。每行带理由与 known-wrong 引用。
--   2. revaluation —— 控制科目上 source_type = 'revaluation' 的分录行,【算出来】的、
--                    有名字的一行。清单按单据入账汇率计,不重估;总账重估。两者差的
--                    就是这一行,它有自己的金额,不藏在别处。
--   3. on_account —— 挂账的收付款(没有核销到任何单据上的那部分):
--                    付款币种的 amount_ccy − Σ(allocated_pay − withheld_pay),按付款汇率
--                    折本位币 —— 与 record_payment_internal 过 v_unalloc_base 的式子同式。
--                    ★ 冲销对【两边都不算】:被冲销的原件(status = 'reversed')与冲销件
--                    (被别人的 reversed_by_payment 指着)都不是挂账的钱。不排除的话,
--                    冲销件没有核销行,会整笔读成挂账 —— 线上实测会凭空多出 4,866.08。
-- 其余一律进 unexplained_base。**没有兜底桶** —— gl_control_reconciliation 抬头那一段
-- 说的是同一件事:一个永远为 0 的判词是装饰,不是检查。
--
-- 【符号约定】每一个具名项的金额都是它对"清单 − 总账"(gap_base)的贡献:
--   unexplained_base = gap_base − residue_base − revaluation_base − on_account_base。
--   总账侧统一成"正数 = 还欠着的钱"(AR = 借 − 贷,AP = 贷 − 借)。
--
-- 【与 gl_control_reconciliation 的分工】那一支按【机制】分类(起单/结算/重估)、截在
-- as-of 日,冻在管理包里的包读它的三个键 —— 它的签名与键不动(Q8),它的抬头已改正:
-- 它的"起单差异"会把缺陷一起吸进去(AP-RECON-1 §3)。本函数按【已知残留】分类,
-- 不截日,不吸任何东西。
--
-- 【两道门】module.finance.view(require_permission);清单的金额还要看得见那一侧的价格 ——
-- AP 要 data.view_purchase_prices、AR 要 data.view_prices(ROLE-1 Batch 4a 起按边分开)——
-- 进料批、销售记录与发票的价格列都是遮蔽的,没有这个码的人读到的清单是残缺的,
-- 拿它去减总账会得到一个自信的假"未解释"。所以此时两边都【按名拒】:
-- refusal = 'PRICES_RESTRICTED',数字为 NULL —— 答不上来不是对不上。
--
-- 月结页(/finance/month-end)有一步读它,每一边一个未解释数;它【不】挡 close_period
-- (Q11:挡不挡关账是以后的决定)。明细页:/finance/list-vs-ledger。
-- 行为断言:db/fixtures/213-the-list-and-the-ledger-agree-and-a-difference-has-a-name.sql
--
-- NOTE: introduced by db/migrations/2026-09-24-aprecon1b-the-list-and-the-ledger-agree.sql.
CREATE OR REPLACE FUNCTION public.list_ledger_reconciliation()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_sides     jsonb := '[]'::jsonb;
    v_side      text;
    v_acct      text;
    v_list      numeric;
    v_rows      integer;
    v_ledger    numeric;
    v_reval     numeric;
    v_onacc     numeric;
    v_onacc_rows jsonb;
    v_res       numeric;
    v_res_rows  jsonb;
    v_gap       numeric;
    v_unexp     numeric;
BEGIN
    -- 【SECURITY DEFINER 必须自己问调用者是谁】
    PERFORM require_permission('module.finance.view');

    FOREACH v_side IN ARRAY ARRAY['ap', 'ar'] LOOP
        v_acct := CASE WHEN v_side = 'ap' THEN '2000' ELSE '1100' END;

        -- ★ ROLE-1 Batch 4a(grilling Q11):每一边问【它自己那一侧】的价格码 —— AP 清单的金额只经
        --   inbound_batches_masked 与 prepayment_applications_masked 遮(两张一起搬到了
        --   data.view_purchase_prices);AR 清单仍按 data.view_prices 遮。
        IF NOT has_permission(CASE WHEN v_side = 'ap' THEN 'data.view_purchase_prices'
                                   ELSE 'data.view_prices' END) THEN
            v_sides := v_sides || jsonb_build_object(
                'side', v_side, 'control_account', v_acct,
                'refusal', 'PRICES_RESTRICTED',
                'list_base', NULL, 'list_rows', NULL, 'ledger_base', NULL, 'gap_base', NULL,
                'residue', '[]'::jsonb, 'residue_base', NULL,
                'revaluation_base', NULL, 'on_account', '[]'::jsonb, 'on_account_base', NULL,
                'unexplained_base', NULL, 'agrees', NULL);
            CONTINUE;
        END IF;

        -- ── 清单 ──────────────────────────────────────────────────────────
        IF v_side = 'ap' THEN
            SELECT count(*), COALESCE(sum(open_base), 0) INTO v_rows, v_list FROM ap_open_items;
        ELSE
            SELECT count(*), COALESCE(sum(open_base), 0) INTO v_rows, v_list FROM ar_open_items;
        END IF;

        -- ── 总账:全账,不截日,不按 status 过滤 ─────────────────────────────
        SELECT COALESCE(sum(CASE WHEN v_side = 'ar' THEN jl.debit - jl.credit
                                 ELSE jl.credit - jl.debit END), 0)
          INTO v_ledger
          FROM journal_lines jl
          JOIN accounts a ON a.id = jl.account_id
         WHERE a.code = v_acct;

        -- ── 具名项 2:重估(总账侧的数;它对 gap 的贡献是它的相反数)─────────
        SELECT COALESCE(sum(CASE WHEN v_side = 'ar' THEN jl.debit - jl.credit
                                 ELSE jl.credit - jl.debit END), 0)
          INTO v_reval
          FROM journal_lines jl
          JOIN accounts a ON a.id = jl.account_id
          JOIN journal_entries je ON je.id = jl.entry_id
         WHERE a.code = v_acct AND je.source_type = 'revaluation';

        -- ── 具名项 3:挂账的收付款,冲销对两边都不算 ─────────────────────────
        SELECT COALESCE(sum(u.base), 0),
               COALESCE(jsonb_agg(jsonb_build_object('code', u.code, 'amount_base', u.base)
                                  ORDER BY u.code), '[]'::jsonb)
          INTO v_onacc, v_onacc_rows
          FROM (SELECT p.code,
                       round(round(p.amount_ccy - COALESCE(
                           (SELECT sum(pa.allocated_pay - pa.withheld_pay)
                              FROM payment_allocations pa
                             WHERE pa.payment_id = p.id), 0), 2) * p.fx_rate, 2) AS base
                  FROM payments p
                 WHERE p.direction = CASE WHEN v_side = 'ap' THEN 'out' ELSE 'in' END
                   AND p.status = 'posted'
                   AND NOT EXISTS (SELECT 1 FROM payments o WHERE o.reversed_by_payment = p.id)) u
         WHERE u.base <> 0;

        -- ── 具名项 1:登记的残留 ────────────────────────────────────────────
        SELECT COALESCE(sum(r.amount_base), 0),
               COALESCE(jsonb_agg(jsonb_build_object(
                   'doc_code', r.doc_code, 'amount_base', r.amount_base,
                   'residue_class', r.residue_class, 'reason', r.reason,
                   'known_wrong_ref', r.known_wrong_ref) ORDER BY r.doc_code), '[]'::jsonb)
          INTO v_res, v_res_rows
          FROM list_ledger_residue r
         WHERE r.side = v_side;

        v_gap   := round(v_list - v_ledger, 2);
        -- ★【没有兜底桶】★ 只扣这三项。
        v_unexp := round(v_gap - v_res - (-v_reval) - v_onacc, 2);

        v_sides := v_sides || jsonb_build_object(
            'side',             v_side,
            'control_account',  v_acct,
            'refusal',          NULL,
            'list_base',        round(v_list, 2),
            'list_rows',        v_rows,
            'ledger_base',      round(v_ledger, 2),
            'gap_base',         v_gap,
            'residue',          v_res_rows,
            'residue_base',     round(v_res, 2),
            'revaluation_base', round(-v_reval, 2),
            'on_account',       v_onacc_rows,
            'on_account_base',  round(v_onacc, 2),
            'unexplained_base', v_unexp,
            'agrees',           (v_unexp = 0));
    END LOOP;

    RETURN jsonb_build_object(
        'base_currency', base_currency_code(),
        'sides',         v_sides);
END;
$function$
;