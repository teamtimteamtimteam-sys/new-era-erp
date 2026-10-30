-- db/functions/dictionary_usage_counts.sql
-- GOLIVE-2(第 13 行,Tim 2026-10-30 Q2):/settings/dictionaries 的「有多少行带着这个值」—— 原来是每个字典值 × 每张引用表一次 count(*) HEAD
--   (线上 180 次往返,库里一共只干 23 ms 的活,页面 28–46 s);现在一次调用,每张引用表一条按值分组的查询。
-- 【SECURITY INVOKER】按读者自己的权限数:引用表的行级策略照样生效,所以每个角色读到的数与原来逐值数的那一份逐个相同;
--   读不了某张引用表的人照样被拒(42501)—— 「查不到不是零」不变。入参是页面注册表(app/settings/dictionaries/registry.ts)里的那几对 (表, 列);
--   表名不在 public 里就按名拒。返回 {"<表>.<列>": {"<值>": 行数, …}, …}。
CREATE OR REPLACE FUNCTION public.dictionary_usage_counts(p_refs jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r     record;
    v_map jsonb;
    v_out jsonb := '{}'::jsonb;
BEGIN
    -- 按读者自己的权限数(SECURITY INVOKER):每一张引用表的行级策略照样生效,读不了那张表的人照样被拒(42501)——
    --   与页面原来逐值发的 count(*) HEAD 同一个答案、同一种失败;只是一张引用表一条按值分组的查询,一次往返。
    FOR r IN SELECT x.ref_table, x.ref_column
               FROM jsonb_to_recordset(p_refs) AS x(ref_table text, ref_column text) LOOP
        IF to_regclass(format('public.%I', r.ref_table)) IS NULL THEN
            RAISE EXCEPTION 'DICT_USAGE_UNKNOWN_TABLE|%', r.ref_table;
        END IF;
        EXECUTE format('SELECT COALESCE(jsonb_object_agg(k, n), ''{}''::jsonb) FROM (SELECT t.%I::text AS k, count(*) AS n FROM public.%I t WHERE t.%I IS NOT NULL GROUP BY 1) s',
                       r.ref_column, r.ref_table, r.ref_column)
           INTO v_map;
        v_out := v_out || jsonb_build_object(r.ref_table || '.' || r.ref_column, v_map);
    END LOOP;
    RETURN v_out;
END;
$function$;
