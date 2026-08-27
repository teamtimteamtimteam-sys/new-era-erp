-- CHASE-1 fu2:逾期【就在承诺日当天】,不是第二天 —— Tim 2026-08-28 裁定
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这是一次【裁定】,不是一次漂移 —— 记清楚是哪一种,因为两者的处置不同】
-- ═══════════════════════════════════════════════════════════════════════════
-- CHASE-1 落地时的口径是「逾期从承诺日的【第二天】起」,理由写的是
-- 「今天到期的承诺今天还没有被辜负」。**那句话在一般意义上没错,在这门生意
-- 里是错的。**
--
-- ★【真正的理由,而它是一件关于这门生意的事实,不是一个偏好】★
--   **这里的货款通常在下午中段到账。** 于是到了承诺日当天有人去看那张单子的
--   时候,一笔还没到的款【已经是那天需要去处理的那件事】了。
--   把它推到第二天,等于让这张单子**恰恰在它最有用的那一天保持沉默** ——
--   而催收这件事的全部价值就在于"今天该打哪几个电话"。
--
-- **Tim 在这一刀上线【之前】就给过这个裁定,是我没有把它带进那一刀的说明里,
--   于是 CHASE-1 建成了较早的那个答案。** 记在这里而不是含糊带过:
--   这条边界是【被决定】改掉的,不是被谁悄悄改掉的 —— 后者才需要追查。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这一刀顺手把"同一条边界被写了两遍"消掉】
-- ═══════════════════════════════════════════════════════════════════════════
-- 清点这条边界被表达的地方时发现:它在库里被【独立算了两次】——
--   ① collection_promise_status.is_overdue(视图)
--   ② customer_collection_context 的 promises_open 里【又写了一遍同样的比较】
-- 两处今天一致,而**一条被写在两个地方的规矩,迟早会在两个地方不一致** ——
-- 这个仓库为这个形状付过四次账(化验预览、GrantRunner、重估预览、/finance/payments)。
-- 所以 ② 改成【读 ①】:一处实现,两个调用方。改边界从此只改一个 `<=`。
--
-- 【没有 schema 变更】本刀只替换一张视图的定义、一支函数的定义,以及那张视图
-- 的注释。**没有建表、没有加列、没有删任何东西、没有写一行数据。**
-- 回滚路径就是把上一版定义重放回去,两份都在 git 的 70f8b16 里。
BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1 · 边界本身:`<` → `<=`
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.collection_promise_status
WITH (security_invoker = off) AS
SELECT pr.id                       AS promise_id,
       ch.id                       AS chase_id,
       ch.code                     AS chase_code,
       ch.customer_id,
       cu.code                     AS customer_code,
       cu.legal_name               AS customer_name,
       ch.chased_on,
       ch.channel,
       pr.promised_amount_ccy,
       pr.currency,
       pr.promised_amount_base,
       pr.promised_date,
       pr.outcome,
       pr.outcome_recorded_at,
       -- ★【逾期【就在承诺日当天】—— `<=`,不是 `<`】★(Tim 2026-08-28 裁定)
       -- 【为什么是当天,而这句话必须留在这里】这门生意的货款通常在**下午中段**
       -- 到账。所以承诺日当天有人来看这张单子时,一笔还没到的款【已经是那天要
       -- 处理的那件事】。推到第二天,这张单子就恰好在它最有用的那一天保持沉默。
       -- **不要把这个 `<=` "修"回 `<`。** 它不是一个差一天的笔误,
       -- 它是一条按这门生意的现金到账时间定下来的规矩。
       -- 仍然【不设宽限期】:一个没人调的旋钮会让"逾期"在不同时候意思不同。
       (pr.outcome IS NULL AND ch.superseded_at IS NULL
        AND pr.promised_date <= CURRENT_DATE)     AS is_overdue,
       (pr.outcome IS NULL AND ch.superseded_at IS NULL) AS is_open,
       ch.superseded_at IS NOT NULL               AS chase_superseded,
       ch.superseded_reason
  FROM collection_promises pr
  JOIN collection_chases   ch ON ch.id = pr.chase_id
  JOIN customers           cu ON cu.id = ch.customer_id;

COMMENT ON VIEW public.collection_promise_status IS
    'CHASE-1：每个承诺一行 —— 它是什么、逾期了没有、它那条催收还活着没有。★【逾期就在承诺日【当天】(`<=`)】★ —— Tim 2026-08-28 裁定，fu2 改的。理由是一件关于这门生意的事实：**货款通常在下午中段到账**，所以承诺日当天有人来看这张单子时，一笔还没到的款已经是那天要处理的那件事；推到第二天，单子就恰好在它最有用的那一天保持沉默。**不要把这个 `<=` 改回 `<`** —— 它不是差一天的笔误。仍然不设宽限期：一个没人调的旋钮会让「逾期」在不同时候意思不同。【这条边界全库只有这一处】customer_collection_context 原先又算了一遍同样的比较，fu2 把它改成读这张视图 —— 一条写在两个地方的规矩迟早会在两个地方不一致。属主权限（security_invoker = off）：它横跨 finance 与 customers，invoker 会让 RLS 把读者无权的那一侧静默丢掉，而行消失在这里意味着「少了一个逾期承诺」而不是报错（OPS-14 修法 (a)）。★【它刻意只有纯 SQL，一个函数都不调】★ ① 属主权限替不了函数的 EXECUTE，而 customer_statement_data 里有 require_permission —— 放进这张要喂 operations_now 的视图会让没有 finance 权限的读者整个仪表盘报错；② 它每行要跑两次 ar_aging_asof，那是对账页的活，不上人人都开的首页。';

-- ───────────────────────────────────────────────────────────────────────────
-- 2 · 把第二处比较消掉 —— 改成【读上面那张视图】
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.customer_collection_context(
    p_customer_id uuid,
    p_as_of       date DEFAULT CURRENT_DATE
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c    customers%ROWTYPE;
    v_data jsonb;
BEGIN
    PERFORM require_permission('module.finance.view');

    SELECT * INTO v_c FROM customers WHERE id = p_customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'CHASE_DATE_REQUIRED';
    END IF;
    IF p_as_of > CURRENT_DATE THEN
        -- 与 AGING_AS_OF_FUTURE / STATEMENT_PERIOD_FUTURE 同一条:
        -- 一次"发生在未来"的催收不是记录,是计划。
        RAISE EXCEPTION 'CHASE_DATE_FUTURE|%|%', p_as_of::text, CURRENT_DATE::text;
    END IF;

    -- 单日窗口:只取它 closing 那一侧。它因此天然带着 STATEMENT-1 实测出来的
    -- 那个区别 —— 已收未核销的钱不冲任何单据,所以 owed / on_account / net_due
    -- 是三个数,不是一个。
    v_data := customer_statement_data(p_customer_id, p_as_of, p_as_of);

    RETURN jsonb_build_object(
        'customer_id',      p_customer_id,
        'customer_code',    v_data->>'customer_code',
        'customer_name',    v_data->>'customer_name',
        'as_of',            p_as_of,
        'base_currency',    v_data->>'base_currency',
        'owed_base',        (v_data->>'closing_base')::numeric,
        'on_account_base',  (v_data->>'on_account_base')::numeric,
        'net_due_base',     (v_data->>'net_due_base')::numeric,
        'by_currency',      v_data->'by_currency',
        'buckets',          v_data->'buckets',
        'lines',            v_data->'lines',
        -- 【这个客户最近被催过没有】—— 命名的缺席由界面说,这里只给事实
        'last_chased_on',   (SELECT max(chased_on) FROM collection_chases
                              WHERE customer_id = p_customer_id AND superseded_at IS NULL),
        'open_promises',    (SELECT COALESCE(count(*), 0) FROM collection_promise_status ps
                              WHERE ps.customer_id = p_customer_id AND ps.is_open),
        -- ★【还没了结的承诺,每一个带上它自己的【证据】】★
        -- 证据 = 这个承诺做出【那一天之后】,这个客户身上真的核销掉了多少。
        -- 它【不】替人下判断(一笔无关的付款到账,不该把没兑现的承诺标成兑现),
        -- 它只是让按下 kept / broken 的那个人是在读数字,不是在猜。
        -- 【为什么算在这里而不在视图里】这一支要跑 customer_statement_data,
        -- 而那支函数带 require_permission —— 放进要喂 operations_now 的视图里,
        -- 会让没有 finance 权限的读者【整个仪表盘报错】。这一支只在客户页上跑,
        -- 而记结局的人就站在那一页。
        --
        -- ★【is_overdue 【读视图】,不在这里再算一遍】★(fu2)
        -- 原先这里写着 `pr.promised_date < CURRENT_DATE` —— 与视图里那一句
        -- 【同一条规矩的第二份实现】。两处当时一致,而一条写在两个地方的规矩
        -- 迟早会在两个地方不一致(本仓库为这个形状付过四次账)。
        -- 现在边界只有一处:collection_promise_status.is_overdue。
        'promises_open',    COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'promise_id',           ps.promise_id,
                       'chase_id',             ps.chase_id,
                       'chase_code',           ps.chase_code,
                       'chased_on',            ps.chased_on,
                       'promised_amount_ccy',  ps.promised_amount_ccy,
                       'currency',             ps.currency,
                       'promised_amount_base', ps.promised_amount_base,
                       'promised_date',        ps.promised_date,
                       'is_overdue',           ps.is_overdue,
                       'applied_since_base',
                           COALESCE((customer_statement_data(
                               p_customer_id, ps.chased_on, LEAST(CURRENT_DATE, p_as_of)
                           )->>'applied_base')::numeric, 0)
                   ) ORDER BY ps.promised_date)
              FROM collection_promise_status ps
             WHERE ps.customer_id = p_customer_id
               AND ps.is_open
               AND ps.chased_on <= p_as_of), '[]'::jsonb)
    );
END;
$function$;

COMMENT ON FUNCTION public.customer_collection_context(uuid, date) IS
    'CHASE-1:催收屏幕的只读上下文。★【它不算欠款,它调对账单那一支函数】★ —— customer_statement_data(客户, D, D) 的单日窗口,取 closing 那一侧。AGENTS.md 记着这个仓库为"屏幕自己把过账规则重写一遍"付过四次账;这里连"用同样的方法算"都不做。后果是同一个客户在催收屏幕上与在对账单上【不可能】出现两个数字,而且它免费继承了那个实测:已收未核销的钱不冲任何单据,所以 owed / on_account / net_due 是三个数。未来的截至日按名拒(CHASE_DATE_FUTURE)。【fu2:逾期与"还没了结"两个判断都改成读 collection_promise_status】原先这里把 `promised_date < CURRENT_DATE` 又写了一遍 —— 同一条边界的第二份实现。现在边界全库只有视图里那一处,而它是 `<=`(逾期就在承诺日当天,Tim 2026-08-28 裁定;理由:货款通常下午中段到账)。';

COMMIT;
