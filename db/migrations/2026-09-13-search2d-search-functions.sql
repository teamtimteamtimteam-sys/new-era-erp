-- SEARCH-2b · 迁移 D —— 搜索的三支函数,以及【被扣下的那个计数】
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【T4 的裁定】「definer 计数,**调策略自己调的那些谓词**;只数【模块】扣下的,
--   不数【归属】扣下的。」这一支把它落成三件东西:
--     · document_types.view_permission —— 每一种单据的【模块闸】,声明在表里;
--     · search_documents()            —— INVOKER,RLS 自然生效,他看得见什么就返回什么;
--     · search_documents_withheld()   —— DEFINER,数他【因为模块进不去】而看不到的条数。
--
-- ★★ 为什么可见性走 INVOKER、计数走 DEFINER —— 这不是两种风格,是两个问题 ★★
--   「他能看见哪几条」这个问题的答案【已经写在 RLS 策略里】,再写一遍就是
--   把同一条规则写第二遍,而两份迟早各说各话(本仓库反复付账的那一条)。
--   所以 search_documents 是 INVOKER:策略自己回答。
--   「他看不见的还有几条」这个问题 RLS 按构造答不了 —— 那些行根本不进他的视野。
--   所以只有这一半需要 DEFINER,而它【只数数,不返回任何内容】:
--   S9 的裁定是「存在说出来,内容不给」。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★ view_permission 的形状,以及它【数不了】的那一格(照直写)
-- ════════════════════════════════════════════════════════════════════════════
--   实测 39 张单据表的 SELECT 策略,谓词有四种形状,不是一种:
--     ① 单条        `has_permission('module.finance.view')`            —— 大多数
--     ② 析取        `has_permission('A') OR has_permission('B')`       —— freight_documents
--                   `has_any_permission(ARRAY['A','B'])`               —— traceability_report_issues
--     ③ 【按行】析取 `(customer_id IS NOT NULL AND has_permission('A'))
--                    OR (supplier_id IS NOT NULL AND has_permission('B'))`
--                   —— assay_results · contracts
--     ④ 模块闸 AND 归属项 `has_permission('module.tasks.view') AND (… OR owner_id = …
--                          OR has_permission('module.tasks.view_all'))` —— tasks
--   ☞ 本列存的是【模块闸】,也就是「一个码都不持有就一条都看不见」的那个 ANY 集合:
--     ④ 里的 `module.tasks.view_all` 是一个【归属放宽项】,不是闸,所以不入列 ——
--     T4 明写「不数归属扣下的」。
--   ☞ ★ 而 ③ 有一格这支函数【数不出来】,写在这里而不是藏着:
--     一个持 module.customers.view 但不持 module.suppliers.view 的人,
--     看不见供应商合同。那【是】一次模块扣下,但要数出它得逐行看 supplier_id ——
--     而那等于把行的内容拿进计数里。本支的规则是:
--     **一个码都不持有 ⇒ 该类的匹配行全部计入;持有其中之一 ⇒ 不计。**
--     于是那一格是【少报】,不是多报 —— 偏在"不声称自己知道"的那一边。
--     这句话要跟着数一起活着,所以它写在这里,也写在 lib/search 的抬头里。
--
-- 【破窗】纯增量:一列(带默认值,不重写任何既有行为)+ 三支新函数。
--   旧代码不调它们。函数的 anon EXECUTE 由 apply_migration.sh 在同一笔事务里收回。

BEGIN;

-- ── 1 · 模块闸,声明在表里,由闸核对 ────────────────────────────────────────
ALTER TABLE public.document_types
    ADD COLUMN view_permission text[] NOT NULL DEFAULT '{}'::text[];

COMMENT ON COLUMN public.document_types.view_permission IS
    '这一类单据的【模块闸】:ANY 语义 —— 一个码都不持有就一条都看不见。'
    '归属放宽项(module.tasks.view_all 之类)不入列。由 db/fixtures 核对:'
    '每一个码都必须真的出现在该表 SELECT 策略的谓词里。';

UPDATE public.document_types SET view_permission = v.perms
FROM (VALUES
    ('assay_result',        ARRAY['module.inbound.view','module.output.view']),
    ('collection_chase',    ARRAY['module.finance.view']),
    ('cod',                 ARRAY['action.issue_cod']),
    ('container',           ARRAY['module.logistics.view']),
    ('credit_note',         ARRAY['module.finance.view']),
    ('employee',            ARRAY['module.hr.view']),
    ('expense_claim',       ARRAY['module.finance.view']),
    ('fixed_asset',         ARRAY['module.finance.view']),
    ('cash_forecast',       ARRAY['module.finance.view']),
    ('leave_request',       ARRAY['module.hr.view']),
    ('medical_claim',       ARRAY['module.hr.view']),
    ('payroll_period',      ARRAY['module.hr.view']),
    ('pricing_formula',     ARRAY['module.pricing.view']),
    ('purchase_order',      ARRAY['module.purchasing.view']),
    ('quote',               ARRAY['module.sales.view']),
    ('sales_order',         ARRAY['module.sales.view']),
    ('shipment',            ARRAY['module.sales.view']),
    ('customer_statement',  ARRAY['module.finance.view']),
    ('traceability_report', ARRAY['module.sales.view','module.processing.view']),
    ('work_order',          ARRAY['module.processing.view']),
    ('contract',            ARRAY['module.customers.view','module.suppliers.view']),
    ('customer',            ARRAY['module.customers.view']),
    ('inbound_batch',       ARRAY['module.inbound.view']),
    ('material',            ARRAY['module.materials.view']),
    ('output_batch',        ARRAY['module.output.view']),
    ('processing_run',      ARRAY['module.processing.view']),
    ('stocktake',           ARRAY['module.stocktakes.view']),
    ('supplier',            ARRAY['module.suppliers.view']),
    ('task',                ARRAY['module.tasks.view']),
    ('invoice',             ARRAY['module.finance.view']),
    ('management_pack',     ARRAY['module.finance.view']),
    ('bank_statement',      ARRAY['module.finance.view']),
    ('attendance_period',   ARRAY['module.hr.view']),
    ('gst_period',          ARRAY['module.finance.view']),
    ('journal_entry',       ARRAY['module.finance.view']),
    ('expense',             ARRAY['module.finance.view']),
    ('freight_document',    ARRAY['module.inbound.view','module.finance.view']),
    ('wht_remittance',      ARRAY['module.finance.view']),
    ('payment_receipt',     ARRAY['module.finance.view']),
    ('payment_out',         ARRAY['module.finance.view'])
) AS v(key, perms)
WHERE document_types.key = v.key;

ALTER TABLE public.document_types ALTER COLUMN view_permission DROP DEFAULT;
ALTER TABLE public.document_types
    ADD CONSTRAINT document_types_view_permission_present
    CHECK (cardinality(view_permission) > 0);

-- ── 2 · 一次搜索要查哪些表,由登记表现算 ────────────────────────────────────
-- 【为什么是一支函数,不是应用里 39 次查询】39 次往返是 39 次往返;
-- 更要紧的是排序是【跨表】的(精确 code 要排在别的表的标签命中前面),
-- 而跨表排序在应用里做,就得先把 39 张表的命中【全部】取回来 —— 包括那些
-- 只用来排序、最后被截掉的。那正是 S9 禁止的那件事的另一种走法。
CREATE OR REPLACE FUNCTION public.search_documents_sql(p_kind text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    r       record;
    parts   text[] := '{}';
    v_label text;
    v_upd   text;
    v_where text;
    v_shared boolean;
BEGIN
    FOR r IN SELECT * FROM document_types ORDER BY key LOOP
        -- ★ 一张表两个前缀(payments = RCPT + PMT):不加前缀过滤,每一条命中
        --   会在两种单据下各出现一次。而【只有】共享表需要这条过滤 ——
        --   给所有表都加上,materials 里那行 IB25 这种历史码就搜不到了,
        --   而它在页面上看得见(Tim 的裁定:页面上看得见的都要搜得到)。
        SELECT count(*) > 1 INTO v_shared
          FROM document_types d WHERE d.table_name = r.table_name;

        v_label := CASE WHEN r.label_column IS NULL THEN 'NULL::text'
                        ELSE format('%I::text', r.label_column) END;
        v_upd := CASE WHEN EXISTS (
                          SELECT 1 FROM pg_attribute a
                           WHERE a.attrelid = format('public.%I', r.table_name)::regclass
                             AND a.attname = 'updated_at' AND a.attnum > 0 AND NOT a.attisdropped)
                      THEN 'updated_at' ELSE 'NULL::timestamptz' END;

        IF p_kind = 'recents' THEN
            -- 【最近编辑过】只对两列都有的那些表成立 —— 其余的在屏幕上点名,
            --   而点名那一半由 lib/search 从本登记表现算,不写死一个数。
            CONTINUE WHEN v_upd = 'NULL::timestamptz';
            v_where := 'updated_by = auth.uid()';
        ELSE
            -- 匹配面:code 无下限;标签要 2 个字符(裁定,而这个数是挑的不是量的)。
            v_where := 'code ILIKE ''%'' || $1 || ''%''';
            IF cardinality(r.match_columns) > 0 THEN
                v_where := v_where || ' OR (length($1) >= 2 AND (' ||
                    (SELECT string_agg(format('%I::text ILIKE ''%%'' || $1 || ''%%''', c), ' OR ')
                       FROM unnest(r.match_columns) c) || '))';
            END IF;
        END IF;
        IF v_shared THEN
            v_where := format('(%s) AND code LIKE %L', v_where, r.prefix || '-%');
        END IF;

        parts := parts || format(
            'SELECT %L::text AS key, id::text AS id, code::text, %s AS label, %s AS updated_at, '
            'CASE WHEN upper(code) = upper($1) THEN 1 '
            '     WHEN upper(code) LIKE upper($1) || ''%%'' THEN 2 '
            '     WHEN upper(code) LIKE ''%%'' || upper($1) THEN 3 '
            '     WHEN upper(code) LIKE ''%%'' || upper($1) || ''%%'' THEN 3 '
            '     ELSE 4 END AS rank '
            'FROM public.%I WHERE %s',
            r.key, v_label, v_upd, r.table_name, v_where);
    END LOOP;

    IF cardinality(parts) = 0 THEN
        RAISE EXCEPTION 'SEARCH_NO_DOCUMENT_TYPES|% —— 登记表是空的,而一支什么都不查的'
                        '搜索会安静地返回"没找到"', p_kind;
    END IF;
    RETURN array_to_string(parts, E'\nUNION ALL\n');
END;
$function$;

-- ★ INVOKER:他能看见哪几条,由 RLS 策略自己回答,这里不写第二遍。
CREATE OR REPLACE FUNCTION public.search_documents(p_query text, p_limit integer DEFAULT 8)
 RETURNS TABLE(key text, id text, code text, label text, route text, link_mode text,
               updated_at timestamptz, total bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_sql text;
BEGIN
    IF p_query IS NULL OR btrim(p_query) = '' THEN
        RETURN;                       -- 空查询不是一次搜索
    END IF;
    v_sql := search_documents_sql('search');
    -- ★★ total 是【截断之前】的条数,而它必须由这一支给出 ★★
    --   裁定写着「不许静默截断」,而一个 `LIMIT n+1` 的写法只答得出
    --   "还有没有更多",答不出"还有几条" —— 于是 more 会在有 50 条时报 1。
    --   一个说了个小数的截断提示,与一个不提截断的结果,读起来一样错。
    --   count(*) OVER () 在 LIMIT 之前求值,所以它数的是整个匹配面。
    RETURN QUERY EXECUTE format(
        'SELECT q.key, q.id, q.code, q.label, q.route, q.link_mode, q.updated_at, q.total FROM ('
        '  SELECT h.key, h.id, h.code, h.label, d.route, d.link_mode, h.updated_at, '
        '         count(*) OVER () AS total, h.rank '
        '    FROM (%s) h JOIN document_types d ON d.key = h.key '
        -- 排序(裁定):精确 code → code 前缀 → code 后缀 → 标签;
        -- 组内 updated_at DESC,没有那一列的按 code DESC。
        '   ORDER BY h.rank, h.updated_at DESC NULLS LAST, h.code DESC '
        '   LIMIT %s) q (key, id, code, label, route, link_mode, updated_at, total, rank)',
        v_sql, p_limit::text)
    USING btrim(p_query);
END;
$function$;

-- ★★ DEFINER,而且【只返回数】—— S9:存在说出来,内容不给。
--    调用者检查:has_permission(),逐个模块闸求值 —— 就是策略自己调的那一支。
CREATE OR REPLACE FUNCTION public.search_documents_withheld(p_query text)
 RETURNS TABLE(key text, route text, n bigint)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r      record;
    v_sql  text;
    v_n    bigint;
    v_shared boolean;
    v_where text;
BEGIN
    IF p_query IS NULL OR btrim(p_query) = '' THEN
        RETURN;
    END IF;
    FOR r IN SELECT * FROM document_types ORDER BY key LOOP
        -- ★ 只数【模块扣下的】:一个闸码都不持有 ⇒ 这一类他一条都看不见。
        --   持有其中之一 ⇒ 不数(剩下看不见的是归属/行别扣下的,T4 明写不数)。
        IF has_any_permission(r.view_permission) THEN
            CONTINUE;
        END IF;
        SELECT count(*) > 1 INTO v_shared FROM document_types d WHERE d.table_name = r.table_name;
        v_where := 'code ILIKE ''%'' || $1 || ''%''';
        IF cardinality(r.match_columns) > 0 THEN
            v_where := v_where || ' OR (length($1) >= 2 AND (' ||
                (SELECT string_agg(format('%I::text ILIKE ''%%'' || $1 || ''%%''', c), ' OR ')
                   FROM unnest(r.match_columns) c) || '))';
        END IF;
        IF v_shared THEN
            v_where := format('(%s) AND code LIKE %L', v_where, r.prefix || '-%');
        END IF;
        v_sql := format('SELECT count(*) FROM public.%I WHERE %s', r.table_name, v_where);
        EXECUTE v_sql INTO v_n USING btrim(p_query);
        IF v_n > 0 THEN
            key := r.key; route := r.route; n := v_n;
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$function$;

-- ★ INVOKER:最近编辑过的单据。看不见的行【静默消失】(裁定),
--   因为 RLS 就是这么工作的 —— 这里不加第二层过滤。
CREATE OR REPLACE FUNCTION public.search_recents(p_limit integer DEFAULT 5)
 RETURNS TABLE(key text, id text, code text, label text, route text, link_mode text, updated_at timestamptz)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_sql text;
BEGIN
    v_sql := search_documents_sql('recents');
    RETURN QUERY EXECUTE format(
        'SELECT h.key, h.id, h.code, h.label, d.route, d.link_mode, h.updated_at '
        '  FROM (%s) h JOIN document_types d ON d.key = h.key '
        ' WHERE h.updated_at IS NOT NULL '
        ' ORDER BY h.updated_at DESC LIMIT %s', v_sql, p_limit::text)
    USING '';
END;
$function$;

-- ── 「最近编辑过」覆盖不到几张表 —— ★ 现算,不写死 ★ ────────────────────────
-- 【为什么是一支函数而不是应用里的一个常量】裁定当时写的是「10 张未覆盖的表在
--   屏幕上点名」,而那个 10 的分母是【31 张有行的表】;单据种类是 39 张表,
--   同一个判据给出 17。一个抄进 TSX 的数字会在下一次加一张单据表时安静地错掉,
--   而没有任何东西会红。☞ 让机器把这个事实读出来,不叮嘱下一个人记着改。
-- 【数的是【表】,不是【种类】】payments 一张表上挂着两个前缀(RCPT / PMT);
--   屏幕上那句话说的是"有几张表还没有这半功能",所以按 table_name 去重。
CREATE OR REPLACE FUNCTION public.search_recents_uncovered()
 RETURNS integer
 LANGUAGE sql
 STABLE
AS $function$
    SELECT count(DISTINCT d.table_name)::integer
      FROM document_types d
     WHERE NOT EXISTS (
            SELECT 1 FROM pg_attribute a
             WHERE a.attrelid = format('public.%I', d.table_name)::regclass
               AND a.attname = 'updated_by' AND a.attnum > 0 AND NOT a.attisdropped)
        OR NOT EXISTS (
            SELECT 1 FROM pg_attribute a
             WHERE a.attrelid = format('public.%I', d.table_name)::regclass
               AND a.attname = 'updated_at' AND a.attnum > 0 AND NOT a.attisdropped);
$function$;

COMMIT;
