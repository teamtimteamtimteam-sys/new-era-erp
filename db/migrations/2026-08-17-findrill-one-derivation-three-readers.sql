-- FIN-DRILL:一份推导,三个读者 —— 损益表、资产负债表、以及新的科目明细
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么先做这一步,而不是直接写第三个读者】
--
-- 损益表与资产负债表各自把同一段推导抄了一遍:
--     journal_lines → journal_entries → accounts 的三表连接,
--     【刻意不过滤 status】,
--     以及"借正还是贷正"那条按科目类别分叉的符号规则。
-- 两份抄写靠一句注释维持一致 ——「改任何一边前先读两边」。
-- 再加第三个读者,就是把那句话要求的阅读量从两份变成三份,而这个仓库
-- 已经用四次同形的事故证明过:**两份实现在写下的那天一致,之后静默漂移**
-- (AGENTS.md「预览过账的屏幕要问数据库」下面那张清单)。
--
-- 所以顺序是:先把共享的那一段拿出来放在一个地方,再让第三个读者读它。
-- 剩在调用点上的只有【两个正当的开关】,它们是真差异,不是重复:
--     ① 日期形状:期间(from..to)vs 累计(..as_of)
--     ② 年结分录:损益表【剔除】,资产负债表【包含】(FIN-23 的刻意不对称)
--
-- 【零行为改动是本次迁移的断言】三个函数拿到的数必须与迁移前逐分相同;
-- 证明方式是既有的 fixture 28 与两张表的既有断言【一个字节都不改】地重跑。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. 共享的那一段
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.journal_activity_lines(
    p_from date,
    p_to date,
    p_include_year_close boolean)
 RETURNS TABLE (
    entry_id uuid, entry_code text, entry_date date, entry_memo text,
    source_type text, source_id uuid, entry_status text,
    line_id uuid, line_memo text,
    account_id uuid, account_code text, account_name_en text, account_name_zh text,
    account_type text,
    debit numeric, credit numeric, signed_base numeric)
 LANGUAGE sql
 STABLE
AS $function$
    -- ════════════════════════════════════════════════════════════════════════
    -- 【没有 status 过滤 —— 这是本文件存在的头号理由,不是疏漏】
    --
    -- 被冲销的原分录 status='reversed',冲销分录 status='posted' 且金额等额反向。
    -- 只留 posted 会【丢掉原分录、留下冲销分录】,净额刚好错成 −原分录 ——
    -- 一张不报错、只是符号反了的报表。两个都要数,才净成零。
    --
    -- 这段警告此前是【两份】,分别抄在 pnl_statement 与 balance_sheet 的函数体里,
    -- 靠「改任何一边前先读两边」维持。它现在住在这里,而那两个函数(以及
    -- account_ledger)读的就是这一段代码本身 —— 于是"两边"不再需要被读,
    -- 因为已经没有两边了。
    --
    -- (cash_flow_statement 里那句 e.status='posted' 与此不一致 —— 见 OPS-16
    --  提交信息里的报告。它不读这个函数,那是另一件事,本次不动。)
    -- ════════════════════════════════════════════════════════════════════════
    --
    -- 【符号规则,一条】资产/成本/费用 借正;收入/负债/权益 贷正。
    -- 三个读者共用它:损益表的 amount、资产负债表的 net、科目明细的 amount
    -- 与合计,都是这一列聚合出来的。分开写三遍就是三次漂移机会。
    --
    -- 【LANGUAGE sql + STABLE + 不带 SET search_path,是为了可内联】
    -- 带 SET 子句或 SECURITY DEFINER 的函数,规划器不会内联;不内联,
    -- account_ledger 查一个科目也要先物化全库分录行再过滤。它是 invoker,
    -- 调用它的三个函数都是 SECURITY DEFINER + SET search_path,函数体解析时
    -- 用的是【调用者的】search_path,而那三个都已经把它钉死成 public, pg_temp。
    -- 先例:reprice_split 同样不带 SET。
    --
    -- 【直接调用它是安全的,靠的是 RLS 而不是"调不到"】它没有调用者检查,
    -- 也没有从 authenticated 收回 EXECUTE —— 因为它是 invoker:
    -- journal_lines / journal_entries 的 SELECT 策略就是
    -- has_permission('module.finance.view')(accounts 是 USING (true))。
    -- 直接调它的登录用户走的是自己那条策略,拿不到比 PostgREST 直查更多的东西。
    -- 三个 definer 调用方以属主身份执行、绕过 RLS —— 它们各自先 require_permission,
    -- 问的是同一条,只是问得更早。
    SELECT e.id, e.code, e.entry_date, e.memo,
           e.source_type, e.source_id, e.status,
           l.id, l.line_memo,
           a.id, a.code, a.name_en, a.name_zh, a.account_type,
           l.debit, l.credit,
           CASE WHEN a.account_type IN ('asset', 'cogs', 'expense')
                THEN l.debit - l.credit
                ELSE l.credit - l.debit END
    FROM journal_lines l
    JOIN journal_entries e ON e.id = l.entry_id
    JOIN accounts a ON a.id = l.account_id
    -- 【开关①:日期形状】NULL = 该侧不设界。期间表传 (from, to);
    -- 截至日表传 (NULL, as_of)。两者的差别只有这一处,别处不该再有。
    WHERE (p_from IS NULL OR e.entry_date >= p_from)
      AND (p_to IS NULL OR e.entry_date <= p_to)
    -- 【开关②:年结分录】FIN-23 的刻意不对称,理由写在两个调用点上。
    --
    -- 【IS DISTINCT FROM,不是 <>】source_type 可空。写成 <> 时,NULL 求值为
    -- NULL,于是【source_type 为 NULL 的分录会被整条丢掉】—— 一张少算了一笔
    -- 分录的报表不会报错,只会小一点。
      AND (p_include_year_close OR e.source_type IS DISTINCT FROM 'year_close');
$function$;

COMMENT ON FUNCTION public.journal_activity_lines(date, date, boolean) IS
'分录行的共享推导:journal_lines→journal_entries→accounts,刻意不过滤 status,附一条按科目类别分叉的符号列。pnl_statement / balance_sheet / account_ledger 三个读者共用。两个开关留在调用点:日期形状(期间 vs 累计)与年结分录(剔除 vs 包含)。';

-- ════════════════════════════════════════════════════════════════════════════
-- 2. 损益表 —— 改成读共享推导,数字不动
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.pnl_statement(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rev jsonb; v_cogs jsonb; v_exp jsonb;
    v_rev_sub numeric; v_cogs_sub numeric; v_exp_sub numeric;
    v_gross numeric; v_net numeric; v_margin numeric;
BEGIN
    -- 与页面此前的把关等价:journal_entries / journal_lines 的 SELECT 策略就是
    -- has_permission('module.finance.view')(accounts 是 USING (true))。所以这个
    -- definer 函数【不放宽任何东西】—— 它问的是调用者自己那一条,只是问得更早。
    PERFORM require_permission('module.finance.view');
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'PERIOD_REQUIRED';
    END IF;

    WITH agg AS (
        -- ════════════════════════════════════════════════════════════════════
        -- 【推导住在 journal_activity_lines 里】三表连接、不过滤 status、
        -- 以及符号规则,全在那个文件的头部,连同它们为什么是那样的理由。
        -- 此处只剩两个开关:
        --   ① 日期形状 = 期间 (p_from, p_to);
        --   ② 年结分录 = 【剔除】(false)。
        --
        -- 【FIN-23:剔除年结分录 —— 与资产负债表刻意不对称】本表按日期区间
        -- 聚合分录行,而结转分录恰好落在区间末日(财年末):不剔除,已结年度的
        -- 损益表会整表归零 —— 合法会计记录里【去年的报表必须永远可复现】。
        -- 资产负债表【包含】year_close(下面 balance_sheet(),注释互指):
        -- 已结年度的损益行合计归零,3100 接住结果,合成的"本期损益"行只剩
        -- 结转后的活动 —— 自洽。db/fixtures/28 把这条不对称钉住。
        --
        -- 【改任何一边前先读两边】—— 而"两边"现在指的是本函数与
        -- balance_sheet 各自那一个 false/true,不再包括推导本身:
        -- 推导只有一份,在 journal_activity_lines。
        -- ════════════════════════════════════════════════════════════════════
        SELECT j.account_code AS code, j.account_name_en AS name_en,
               j.account_name_zh AS name_zh, j.account_type,
               sum(j.debit) AS debits, sum(j.credit) AS credits,
               sum(j.signed_base) AS signed
        FROM journal_activity_lines(p_from, p_to, false) j
        WHERE j.account_type IN ('revenue', 'cogs', 'expense')
        GROUP BY j.account_code, j.account_name_en, j.account_name_zh, j.account_type
    ), amt AS (
        -- 收入贷正,成本/费用借正 —— 那条规则是共享推导的 signed_base 列。
        -- 零发生额科目在这里被排除 ——(a.debits !== 0 || a.credits !== 0) 同一条。
        SELECT g.code, g.name_en, g.name_zh, g.account_type,
               round(g.signed, 2) AS amount
        FROM agg g
        WHERE g.debits <> 0 OR g.credits <> 0
    )
    SELECT
        COALESCE(jsonb_agg(jsonb_build_object(
            'code', code, 'name_en', name_en, 'name_zh', name_zh, 'amount', amount)
            ORDER BY code) FILTER (WHERE account_type = 'revenue'), '[]'::jsonb),
        COALESCE(jsonb_agg(jsonb_build_object(
            'code', code, 'name_en', name_en, 'name_zh', name_zh, 'amount', amount)
            ORDER BY code) FILTER (WHERE account_type = 'cogs'), '[]'::jsonb),
        COALESCE(jsonb_agg(jsonb_build_object(
            'code', code, 'name_en', name_en, 'name_zh', name_zh, 'amount', amount)
            ORDER BY code) FILTER (WHERE account_type = 'expense'), '[]'::jsonb),
        -- 小计 = 【已经四舍五入到分的各行】之和,再取一次 —— 与页面同序,不是先合再舍
        COALESCE(round(sum(amount) FILTER (WHERE account_type = 'revenue'), 2), 0),
        COALESCE(round(sum(amount) FILTER (WHERE account_type = 'cogs'), 2), 0),
        COALESCE(round(sum(amount) FILTER (WHERE account_type = 'expense'), 2), 0)
    INTO v_rev, v_cogs, v_exp, v_rev_sub, v_cogs_sub, v_exp_sub
    FROM amt;

    v_gross := round(v_rev_sub - v_cogs_sub, 2);
    v_net   := round(v_gross - v_exp_sub, 2);

    -- 毛利率:收入为零时【返回 NULL 而不是 0】—— 0% 是个断言,"没有收入所以没有比率"
    -- 不是。页面此前就是这么写的(marginPct = ... : null),这里保住它。
    -- floor(x + 0.5) 是 JS Math.round 的精确等价(对负数也是,JS 是向 +∞ 取半),
    -- 写成 round() 会在负毛利率恰好落在半分位时与页面差一档。
    IF v_rev_sub <> 0 THEN
        v_margin := floor(v_gross / v_rev_sub * 1000 + 0.5) / 10;
    ELSE
        v_margin := NULL;
    END IF;

    RETURN jsonb_build_object(
        'period_from', p_from, 'period_to', p_to,
        'revenue', jsonb_build_object('rows', v_rev,  'subtotal', v_rev_sub),
        'cogs',    jsonb_build_object('rows', v_cogs, 'subtotal', v_cogs_sub),
        'expense', jsonb_build_object('rows', v_exp,  'subtotal', v_exp_sub),
        'gross_profit', v_gross,
        'net_profit', v_net,
        'margin_pct', v_margin
    );
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 3. 资产负债表 —— 同样改成读共享推导,数字不动
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.balance_sheet(p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_asset jsonb; v_liab jsonb; v_eq jsonb;
    v_asset_sub numeric; v_liab_sub numeric; v_eq_sub numeric;
    v_rev numeric; v_cogs numeric; v_exp numeric;
    v_earnings numeric; v_total_le numeric;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'AS_OF_REQUIRED';
    END IF;

    WITH agg AS (
        -- ════════════════════════════════════════════════════════════════════
        -- 【推导住在 journal_activity_lines 里】三表连接、不过滤 status、
        -- 以及符号规则,全在那个文件的头部。此处只剩两个开关:
        --   ① 日期形状 = 累计 (NULL, p_as_of) —— 起点不设界,这就是"截至日"。
        --   ② 年结分录 = 【包含】(true)。
        --
        -- 【FIN-23:本表【包含】year_close 分录 —— 与损益表刻意不对称】已结年度的
        -- 损益行合计归零,3100 接住净结果,合成的"本期损益"行只剩结转后的活动 ——
        -- 自洽,权益合计不变。损益表相反,【剔除】year_close(上面 pnl_statement(),
        -- 注释互指):否则结转会把已结年度的损益表清成零。
        --
        -- 【改任何一边前先读两边】—— 而"两边"现在指的是本函数与 pnl_statement
        -- 各自那一个 true/false,不再包括推导本身。db/fixtures/28 用同一个期间
        -- 同时问这两个函数,把不对称钉住。
        -- ════════════════════════════════════════════════════════════════════
        SELECT j.account_code AS code, j.account_name_en AS name_en,
               j.account_name_zh AS name_zh, j.account_type,
               sum(j.debit) AS debits, sum(j.credit) AS credits,
               sum(j.signed_base) AS signed
        FROM journal_activity_lines(NULL, p_as_of, true) j
        GROUP BY j.account_code, j.account_name_en, j.account_name_zh, j.account_type
    ), net AS (
        -- 资产借正,负债/权益贷正 —— 同样是共享推导的 signed_base 列。
        SELECT g.code, g.name_en, g.name_zh, g.account_type, g.debits, g.credits,
               g.signed, round(g.signed, 2) AS net
        FROM agg g
    )
    SELECT
        COALESCE(jsonb_agg(jsonb_build_object(
            'code', code, 'name_en', name_en, 'name_zh', name_zh, 'net', net)
            ORDER BY code) FILTER (WHERE account_type = 'asset' AND (debits <> 0 OR credits <> 0)), '[]'::jsonb),
        COALESCE(jsonb_agg(jsonb_build_object(
            'code', code, 'name_en', name_en, 'name_zh', name_zh, 'net', net)
            ORDER BY code) FILTER (WHERE account_type = 'liability' AND (debits <> 0 OR credits <> 0)), '[]'::jsonb),
        COALESCE(jsonb_agg(jsonb_build_object(
            'code', code, 'name_en', name_en, 'name_zh', name_zh, 'net', net)
            ORDER BY code) FILTER (WHERE account_type = 'equity' AND (debits <> 0 OR credits <> 0)), '[]'::jsonb),
        COALESCE(round(sum(net) FILTER (WHERE account_type = 'asset'     AND (debits <> 0 OR credits <> 0)), 2), 0),
        COALESCE(round(sum(net) FILTER (WHERE account_type = 'liability' AND (debits <> 0 OR credits <> 0)), 2), 0),
        COALESCE(round(sum(net) FILTER (WHERE account_type = 'equity'    AND (debits <> 0 OR credits <> 0)), 2), 0),
        -- 本期损益三项:【对整型别求和后才取整】—— 页面的 plNet 就是这个顺序
        -- (round2 套在 reduce 外面),与上面各行先取整再合计【不同】,照搬。
        -- 三项都取 signed_base:收入 = 贷−借,成本/费用 = 借−贷,与此前逐字等价。
        COALESCE(round(sum(signed) FILTER (WHERE account_type = 'revenue'), 2), 0),
        COALESCE(round(sum(signed) FILTER (WHERE account_type = 'cogs'), 2), 0),
        COALESCE(round(sum(signed) FILTER (WHERE account_type = 'expense'), 2), 0)
    INTO v_asset, v_liab, v_eq, v_asset_sub, v_liab_sub, v_eq_sub, v_rev, v_cogs, v_exp
    FROM net;

    -- 本期损益(截至日口径):收入 − 成本 − 费用,合成进权益
    v_earnings := round(v_rev - v_cogs - v_exp, 2);
    v_total_le := round(v_liab_sub + v_eq_sub + v_earnings, 2);

    RETURN jsonb_build_object(
        'as_of', p_as_of,
        'asset',     jsonb_build_object('rows', v_asset, 'subtotal', v_asset_sub),
        'liability', jsonb_build_object('rows', v_liab,  'subtotal', v_liab_sub),
        -- equity 给两个小计:subtotal 是科目行合计,total 额外含本期损益合成行 ——
        -- 屏幕上权益那一段的小计显示的是后者。页面不做算术,所以两个都给。
        'equity',    jsonb_build_object('rows', v_eq, 'subtotal', v_eq_sub,
                                        'total', round(v_eq_sub + v_earnings, 2)),
        'current_earnings', v_earnings,
        'total_assets', v_asset_sub,
        'total_liab_equity', v_total_le,
        -- 【自检】资产合计必须等于 负债+权益 合计。不等 = 这张表是错的,页面照实说。
        'balanced', (v_asset_sub = v_total_le)
    );
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 4. 第三个读者:科目明细(一个数字背后的那些行)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.account_ledger(
    p_account_code text,
    p_from date,
    p_to date,
    p_include_year_close boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text; v_name_en text; v_name_zh text; v_type text;
    v_rows jsonb; v_total numeric;
BEGIN
    -- 【权限:与两张报表同一道门】能看见那个数字的人,就能看见它背后的行 ——
    -- 反过来说,这个函数不该比它服务的报表松一格。module.finance.view 隐含
    -- 价格可见性(AGENTS.md 三条常设裁定之一:总账就是价格数据),所以这里
    -- 不再叠第二把锁。
    PERFORM require_permission('module.finance.view');

    IF p_account_code IS NULL OR btrim(p_account_code) = '' THEN
        RAISE EXCEPTION 'ACCOUNT_CODE_REQUIRED';
    END IF;
    -- 【截止日与开关都不给默认值】p_to 空了就拒,不 COALESCE 成 CURRENT_DATE:
    -- 一个悄悄换了期间的明细表会与它要对账的那张报表对不上,而那个不一致
    -- 看起来会像报表错了。开关同理 —— 猜错它就是猜错了年结那条不对称。
    IF p_to IS NULL THEN
        RAISE EXCEPTION 'PERIOD_REQUIRED';
    END IF;
    IF p_include_year_close IS NULL THEN
        RAISE EXCEPTION 'YEAR_CLOSE_SWITCH_REQUIRED';
    END IF;

    SELECT a.code, a.name_en, a.name_zh, a.account_type
      INTO v_code, v_name_en, v_name_zh, v_type
      FROM accounts a WHERE a.code = p_account_code;
    -- 【科目不存在 ≠ 科目没有分录】前者是问错了问题,后者是一个正当的答案。
    -- 把两者合成一个空表,就是把"打错了科目号"显示成"这个月没动过" ——
    -- 与 mustRows / restRows / check-i18n 后缀解析同一条:一次失败不是一个空集。
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_FOUND|%', p_account_code;
    END IF;

    WITH act AS (
        -- 【与两张报表逐字同一段推导】三表连接、不过滤 status、符号规则,
        -- 全在 journal_activity_lines 里。两个开关由调用者给:
        -- 损益表的下钻传 (from, to, false);资产负债表的下钻传 (NULL, as_of, true)。
        -- 【这就是"合计对得上"能成立的原因,也是它唯一能成立的原因】——
        -- 见下面 total 那里关于"这个对账能查出什么"的说明。
        SELECT * FROM journal_activity_lines(p_from, p_to, p_include_year_close)
    ), mine AS (
        SELECT * FROM act WHERE act.account_code = p_account_code
    ), cp AS (
        -- 对方科目:同一张分录里【反方向】的那些行。取反方向而不是"其余所有行",
        -- 是因为一借多贷时,一条借方行的对家是那些贷方行,不是同侧的兄弟行。
        SELECT m.line_id,
               jsonb_agg(DISTINCT jsonb_build_object(
                   'code', o.account_code,
                   'name_en', o.account_name_en,
                   'name_zh', o.account_name_zh)) AS accounts
        FROM mine m
        JOIN act o ON o.entry_id = m.entry_id
                  AND o.line_id <> m.line_id
                  AND ((m.debit > 0 AND o.credit > 0) OR (m.credit > 0 AND o.debit > 0))
        GROUP BY m.line_id
    )
    SELECT
        COALESCE(jsonb_agg(jsonb_build_object(
            'line_id',      m.line_id,
            'entry_id',     m.entry_id,
            'entry_code',   m.entry_code,
            'entry_date',   m.entry_date,
            'entry_memo',   m.entry_memo,
            'line_memo',    m.line_memo,
            'entry_status', m.entry_status,
            -- 来源单据:类型 + 主键。链接由页面用既有的 resolveSourceHrefs 解析 ——
            -- 那份映射已经服务分录列表页,不在这里抄第二份。
            'source_type',  m.source_type,
            'source_id',    m.source_id,
            'debit',        m.debit,
            'credit',       m.credit,
            -- 【符号:共享推导那一条,不是这里第三次写的一条】
            'amount',       m.signed_base,
            'counterparts', COALESCE(c.accounts, '[]'::jsonb))
            ORDER BY m.entry_date, m.entry_code, m.line_id), '[]'::jsonb),
        -- 【本函数自己的合计】页面会把它与报表上那个数字【并排】显示。
        --
        -- 【这个对账能查出什么,不能查出什么 —— 说清楚,免得它变成一句装饰】
        -- 查不出:算术错。两边共用 journal_activity_lines 的同一列,算术不可能
        --   各错各的(AGENTS.md/OPS-17:两个数只有能分开动,才算一个对账)。
        -- 查得出:【页面把参数传错了】—— 下钻带的期间与报表自己的期间不一致、
        --   年结开关传反、科目号带错。那正是一个下钻页最容易错的地方,
        --   也是这两个数唯一能分开动的方式。所以页面必须并排显示、
        --   不一致时说出来,而不是悄悄挑一个显示。
        COALESCE(round(sum(m.signed_base), 2), 0)
    INTO v_rows, v_total
    FROM mine m LEFT JOIN cp c ON c.line_id = m.line_id;

    RETURN jsonb_build_object(
        'account', jsonb_build_object(
            'code', v_code, 'name_en', v_name_en,
            'name_zh', v_name_zh, 'account_type', v_type),
        'period_from', p_from,
        'period_to', p_to,
        'include_year_close', p_include_year_close,
        'rows', v_rows,
        -- 【空是一个具名状态,不是一个错】科目存在、期间内没有分录 ——
        -- rows 为 [],line_count 为 0,total 为 0,页面据此说"本期间无分录",
        -- 而不是渲染一张空表让人猜是没数据还是没加载出来。
        'line_count', jsonb_array_length(v_rows),
        'total', v_total
    );
END;
$function$;

COMMENT ON FUNCTION public.account_ledger(text, date, date, boolean) IS
'一个报表数字背后的分录行:日期、凭证号、来源单据、对方科目、按共享符号规则的有向金额,以及本函数自己的合计。推导与 pnl_statement / balance_sheet 共用 journal_activity_lines;两个开关由调用者给(损益下钻 from/to/false,资产负债下钻 NULL/as_of/true)。权限:module.finance.view。';

COMMIT;
