-- db/functions/search_documents_sql.sql
-- SEARCH-2b · 迁移 D。表的镜像在 db/tables/document_types.sql;
-- 模块闸的行为断言在 db/fixtures/101-a-declared-module-gate-is-the-one-the-policy-calls.sql。

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
