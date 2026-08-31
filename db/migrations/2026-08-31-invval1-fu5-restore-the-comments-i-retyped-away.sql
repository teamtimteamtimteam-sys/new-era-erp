-- INV-VAL-1-fu5:把 AR/AP 两条腿的【体内注释】原样放回去
--
-- 【我在自己的抬头里写了一句假话,而 git diff 当场戳穿它】
--   主迁移的抬头写着「AR/AP 两条腿一个字未动」。那句话对【算术】是真的,
--   对【文本】是假的:CREATE OR REPLACE 时我把函数体重新打了一遍,
--   于是 AR/AP 段里那几条注释被悄悄删掉了 —— 其中包括最要紧的那一条:
--
--     「经 journal_activity_lines,所以【不】按 status 过滤 …… 这个病在本仓库
--       现身过四次,其中一次(bank_reconciliation_status)在线上错了几个月,
--       差 USD 1,585.00」
--
--   那条注释是【为什么这段代码长这样】的唯一记录。删掉它,下一个人看到的是
--   一段"忘了过滤 status"的可疑代码,而"修好"它正是那四次事故的做法。
--
-- 【判据】CREATE OR REPLACE 一支既有函数时,拿【线上的定义】改,不要凭记忆重打。
--   镜像就在 db/functions/ 里,git show HEAD:<file> 一条命令的事。
--
-- 本迁移把原始函数体逐字取回,只重新施加 INV-VAL-1 真正要加的两处:
-- variances 数组,以及末尾接上存货两条腿。

BEGIN;

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
            -- INV-VAL-1:名目也做成数组,与存货两条腿同形,好让一个循环渲染四条腿。
            -- 【既有的三个键原样保留】—— 已经冻在 management_packs 里的包读的是它们。
            'subledger_basis',           'documents',
            'refusal',                   NULL,
            'variances', jsonb_build_array(
                jsonb_build_object('code','origination','amount_base',v_ov),
                jsonb_build_object('code','settlement','amount_base',v_sv),
                jsonb_build_object('code','revaluation','amount_base', round(-v_reval_led,2))),
            'unexplained_base',          v_unexp,
            -- 【勾稽上不上,判据是【余额】,不是差额】差额不为零是正常的、
            -- 而且是有意义的(重估、挂账、cutover 前的单据都会让它不为零);
            -- 【余额】不为零才是一件没有人解释过的事。
            'reconciled',                (v_unexp = 0));
    END LOOP;

    -- INV-VAL-1:第三、第四条腿。存货的名目与 AR/AP 完全不同,所以它自己一支函数。
    v_sides := v_sides || inventory_control_reconciliation(p_as_of);

    RETURN jsonb_build_object(
        'as_of',         p_as_of,
        'base_currency', v_base,
        'sides',         v_sides);
END;
$function$;

COMMIT;
