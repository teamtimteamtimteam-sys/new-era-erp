-- db/functions/expense_claim_amount_base.sql
-- APR-3(2026-09-22):★【一张报销单值多少本位币】的【唯一】一份定义★
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它为什么必须存在】expense_claims 上【没有 fx_rate,也没有 amount_base】——
-- 只有 amount_ccy 与 currency。而 APR-3 有三个地方要同一个数:
--   ① decide_expense_claim 按金额分档(一级还是二级);
--   ② record_approval_decision 把金额【冻结】进 approval_log(那张表的 CHECK 是
--      四列全有或全无,所以它必须拿得到 fx_rate);
--   ③ approval_pending_documents 给在途单据算档次(屏幕、关闭那道闸、以及
--      APPROVALS_POLICY_WOULD_STRAND 都读它)。
-- 三处各算一遍,就是三份会漂开的判据 —— 而漂开之后,屏幕上说的档次与真正
-- 拦人的那一档可以不是同一档,那是一句关于内控的假话。
-- ════════════════════════════════════════════════════════════════════════════
--
-- ★★【取哪一天的牌价 —— spend_date,而不是 posting_date】★★
-- posting_date 是【审批人在做决定的那一刻自己填的一个入参】。拿它去分档,等于
-- 让审批人挑一个能把这张单据放进自己权限范围的日期 —— 一道由被它约束的人
-- 选定参数的闸,不是闸。spend_date 是【提交时就已经固定的事实】,它决定不了
-- 自己归谁批。☞ 代价照直说:分档用的汇率与 record_expense 过账时用的汇率
-- 【可以是两个数】(过账取 posting_date 那天的)。那是两个不同的问题:
-- 一个问"这笔承诺有多大",一个问"账上记多少" —— 不是同一个数,也不该是。
--
-- ★【取哪一种牌价 —— tt_sell,与 record_expense 逐字同源】record_expense 第 191
--   行的理由原样适用:一笔应付的外币开支是我们将来要【向银行买】的外币。
--   这里不另立一条 FX 规矩;THE FX RULE 只有一份。
--
-- ★★【它【不】抛 FX_RATE_MISSING,这是刻意的】查不到牌价时 fx_rate 与
--   amount_base 一起返回 NULL。理由:它的三个调用方里有一个是【列表】
--   (approval_pending_documents)—— 一支因为某一行没牌价就整个炸掉的列表函数,
--   会让屏幕、关闭那道闸、和策略编辑那道闸一起变成"读不到",而那读起来像
--   "没有在途单据"。☞ 要按名拒的那一个调用方(decide_expense_claim)自己去调
--   fx_rate_for(),那句 FX_RATE_MISSING 归它那一份定义所有。
--
-- 【为什么它不是 SECURITY DEFINER】它读 expense_claims 与 fx_rates,而这两张表
--   的 RLS 正是这个问题该有的答案:authenticated 直接调它,只看得见自己看得见
--   的那些单据;从三个 DEFINER 调用方里调它,以属主身份跑,看得见全部。
--   不声明 DEFINER,gate 的 B2 就与它无关,也不用在 check_mirrors 的豁免表里
--   多写一条解释。
--
-- NOTE: introduced by db/migrations/2026-09-22-apr3-the-claim-the-count-and-the-edit-that-strands.sql.

CREATE OR REPLACE FUNCTION public.expense_claim_amount_base(p_claim_id uuid)
 RETURNS TABLE(amount_ccy numeric, currency text, fx_rate numeric, amount_base numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT c.amount_ccy,
           c.currency,
           r.rate,
           CASE WHEN r.rate IS NULL THEN NULL ELSE round(c.amount_ccy * r.rate, 2) END
      FROM expense_claims c
      LEFT JOIN LATERAL fx_rate_asof(c.currency, c.spend_date, 'tt_sell') r ON true
     WHERE c.id = p_claim_id;
$function$;

COMMENT ON FUNCTION public.expense_claim_amount_base(uuid) IS
'APR-3:一张报销单值多少本位币 —— 【唯一】一份定义,三个调用方(decide_expense_claim 分档 · record_approval_decision 冻结金额 · approval_pending_documents 列在途)。expense_claims 上没有 fx_rate 也没有 amount_base,所以这个数必须算,而算三遍就是三份会漂开的判据。★ 取 spend_date 的 tt_sell:posting_date 是审批人做决定时自己填的入参,拿它分档等于让审批人挑一个把单据放进自己权限范围的日期;tt_sell 的理由与 record_expense 第 191 行逐字同源(应付外币是将来要向银行买的)。★ 查不到牌价时 fx_rate 与 amount_base 一起为 NULL、【不抛】—— 一支会炸的列表函数会让屏幕与两道闸一起读成"没有在途单据";要按名拒的 decide_expense_claim 自己去调 fx_rate_for()。';
