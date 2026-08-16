CREATE OR REPLACE FUNCTION public.account_ledger(p_account_code text, p_from date, p_to date, p_include_year_close boolean)
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
