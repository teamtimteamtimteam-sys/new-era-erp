-- db/functions/document_type_prefix.sql
-- SEARCH-2b:44 支铸码函数【读前缀】的那一支。T1 的 prefix-as-data 落在这里。
-- 镜像的表在 db/tables/document_types.sql;行为断言在
-- db/fixtures/100-every-document-code-still-mints-identically.sql 的第 2 与第 7 臂。

-- ── 前缀读取器 ──────────────────────────────────────────────────────────────
-- ★★ 读不到就【抛】,不返回 NULL ★★
--   返回 NULL 会让 'X' || NULL || '-' 整体变成 NULL,于是 code 变成 NULL ——
--   一次安静的错误,而不是一次响亮的失败。RLS 挡住读的那一刻正是这个函数
--   唯一有可能读不到的时刻,所以它必须在那里出声。
CREATE OR REPLACE FUNCTION public.document_type_prefix(p_key text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_prefix text;
BEGIN
    SELECT prefix INTO v_prefix FROM public.document_types WHERE key = p_key;
    IF v_prefix IS NULL THEN
        RAISE EXCEPTION 'DOCUMENT_TYPE_PREFIX_MISSING|%', p_key
            USING HINT = 'document_types 里没有这一行,或者当前角色读不到它'
                         '(RLS / GRANT)。铸码在此停下,而不是铸出一个 NULL 号。';
    END IF;
    RETURN v_prefix;
END;
$function$;
