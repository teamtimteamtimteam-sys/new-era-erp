-- db/functions/counterparty_overlap_report.sql
-- PARTY-1:同一家公司在两侧各有一行吗 —— 一份【报告】,不是一个结构。
--
-- ★★【它【故意】不把两边的敞口加起来,而这是本刀最要紧的一句话】★★
--   一个既欠你钱、又被你欠钱的对手方,读的人第一反应是"那就轧个差"。
--   **轧差是一次【法律行为】,不是一次算术。** 它要有一份【抵销权】,
--   而抵销权住在一份合同里 —— 这个仓库里没有任何一处记录过那样一份合同;
--   各法域对"抵销权在对方破产之后还成不成立"的答案也不一样。
--   悄悄轧差会【同时低估应收与应付】,而两个数一起变小、没有任何东西报错,
--   正是 OPS-17 抓到的那个病穿上会计外衣的样子。
--   **所以这份报告把两个敞口【并排摆着】,并且自己说出它不加它们、以及为什么。**
--   要一个数的人,得知道那是【有人要做的一次决定】,不是系统扣着不给的一个和。
--
-- ★★【非空由构造保证 —— 而"0 条重叠"必须与"没有东西可比"分得开】★★
--   实测(2026-08-29):线上 customers **一个 tax_id 都没有**,
--   所以任何按 tax_id 的重叠今天【必然】返回 0 行 —— 那不是"没有重叠",
--   那是"没有可比的东西"。一份只返回 matches 的报告在这两种情形下
--   长得一模一样,而那正是本仓库反复付账的那种沉默。
--   **所以返回值里带着【分母】**:两侧各有多少行、其中多少行有登记号。
--   于是「0 条重叠 / 0 个可比客户」与「0 条重叠 / 40 个可比客户」
--   在屏幕上是两句不同的话,而后者才是一句关于重叠的断言。
--
-- 【两种匹配,强弱分开报,不合并】
--   · tax_id:**身份**。两边的写入触发器 normalise_counterparty_identity()
--     用同一套规则归一(去空白 + 大写 + '' → NULL),所以跨表比较本来就是可靠的,
--     不需要在这里再洗一遍 —— 洗第二遍就是第二份实现。
--   · 归一化名字:**线索**,不是身份。同名公司真实存在,而改名的同一家公司比不上。
--     它单独一组返回,绝不与 tax_id 那组混在一起 ——
--     把一条线索摆进身份那一栏,是把"可能"读成"是"。
--
-- 【为什么是函数不是视图】它要回答的不只是"有哪些行",还有"分母是多少"、
--   以及那句"不加它们"的话。一个视图给不出分母(0 行就是 0 行)。

CREATE OR REPLACE FUNCTION public.counterparty_overlap_report()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_by_tax   jsonb := '[]'::jsonb;
    v_by_name  jsonb := '[]'::jsonb;
    v_cov      jsonb;
BEGIN
    -- 【SECURITY DEFINER 必须自己查权限】属主权限绕过 RLS,所以这一句不是礼节。
    -- 要【两侧都看得见】才给看:这份报告的全部内容就是把两侧摆在一起,
    -- 只有一侧权限的人拿到的会是一份误导性的半张表。
    PERFORM require_permission('module.customers.view');
    PERFORM require_permission('module.suppliers.view');

    -- ── 强匹配:同一个登记号 ────────────────────────────────────────────
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'tax_id'), '[]'::jsonb) INTO v_by_tax
    FROM (
        SELECT jsonb_build_object(
                   'tax_id',            c.tax_id,
                   'customer_id',       c.id,
                   'customer_code',     c.code,
                   'customer_name',     c.legal_name,
                   'supplier_id',       s.id,
                   'supplier_code',     s.code,
                   'supplier_name',     s.legal_name,
                   'counterparty_type', s.counterparty_type,
                   -- 【并排摆着的两个数,而不是一个和】见抬头。
                   'ar_open_base',      COALESCE(ar.v, 0),
                   'ap_open_base',      COALESCE(ap.v, 0)) AS x
        FROM customers c
        JOIN suppliers s ON s.tax_id = c.tax_id
        LEFT JOIN LATERAL (SELECT SUM(o.open_base) v FROM ar_open_items o
                            WHERE o.customer_id = c.id) ar ON true
        LEFT JOIN LATERAL (SELECT SUM(o.open_base) v FROM ap_open_items o
                            WHERE o.supplier_id = s.id) ap ON true
        WHERE c.deleted_at IS NULL AND s.deleted_at IS NULL
          AND c.tax_id IS NOT NULL
    ) t;

    -- ── 弱信号:归一化之后同名。**单独一组,不与上面合并。** ────────────
    -- 排除掉已经被登记号匹配上的那些对,否则同一对会出现两次,
    -- 而"两条证据"会被读成"两个重叠"。
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'customer_code'), '[]'::jsonb) INTO v_by_name
    FROM (
        SELECT jsonb_build_object(
                   'customer_id',   c.id,
                   'customer_code', c.code,
                   'customer_name', c.legal_name,
                   'supplier_id',   s.id,
                   'supplier_code', s.code,
                   'supplier_name', s.legal_name,
                   'counterparty_type', s.counterparty_type) AS x
        FROM customers c
        JOIN suppliers s
          ON lower(regexp_replace(s.legal_name, '\s+', '', 'g'))
           = lower(regexp_replace(c.legal_name, '\s+', '', 'g'))
        WHERE c.deleted_at IS NULL AND s.deleted_at IS NULL
          AND NOT (c.tax_id IS NOT NULL AND s.tax_id IS NOT NULL AND c.tax_id = s.tax_id)
    ) t;

    -- ── ★ 分母:让"0 条"说得出它是哪一种 0 ★ ────────────────────────────
    SELECT jsonb_build_object(
        'customers_total',       (SELECT count(*) FROM customers WHERE deleted_at IS NULL),
        'customers_with_tax_id', (SELECT count(*) FROM customers WHERE deleted_at IS NULL AND tax_id IS NOT NULL),
        'suppliers_total',       (SELECT count(*) FROM suppliers WHERE deleted_at IS NULL),
        'suppliers_with_tax_id', (SELECT count(*) FROM suppliers WHERE deleted_at IS NULL AND tax_id IS NOT NULL))
    INTO v_cov;

    RETURN jsonb_build_object(
        'by_tax_id',  v_by_tax,
        'by_name',    v_by_name,
        'coverage',   v_cov,
        -- 【这两句话跟着数字走,不只躺在文档里】(Tim 2026-08-29 裁定 A3)
        -- 读到这份报告的人,就是会想去轧差的那个人。
        'exposures_are_not_netted', true,
        'why_not_netted',
            'Set-off is a legal act, not an arithmetic one: it requires a set-off right '
            'that lives in a contract, and no such contract is recorded in this system. '
            'Jurisdictions also differ on whether set-off survives insolvency. Netting '
            'silently would understate receivables and payables at the same time, so the '
            'two exposures are shown side by side and deliberately not added. Producing a '
            'single number is a decision somebody has to make, not a sum the system withheld.');
END;
$function$;

COMMENT ON FUNCTION public.counterparty_overlap_report() IS
'PARTY-1:同一家公司在两侧各有一行吗 —— 一份报告,**不是一个结构**(一方两身仍未被结构回答,见 known-issues 的 COUNTERPARTY-ONE-PARTY)。**它故意不把两边的敞口加起来**:轧差是一次法律行为,要有抵销权,而抵销权住在一份这个系统里没有记录过的合同里;悄悄轧差会同时低估应收与应付。所以两个敞口并排摆着,并且返回值自己带着那句理由。**返回值带分母(coverage)**,因为线上 customers 一个 tax_id 都没有 —— "0 条重叠"与"没有可比的东西"必须分得开,而只返回 matches 的报告在两种情形下长得一模一样。tax_id 是身份(两表写入触发器归一化规则相同,跨表比较本来就可靠),归一化名字只是线索,两组分开返回、绝不合并。';
