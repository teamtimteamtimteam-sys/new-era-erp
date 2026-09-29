-- db/functions/change_log_find_records.sql
-- AUDIT-TRAIL-1a(Tim 的 Q30):/settings/change-history 的"Record"筛选 —— 按【单据号或名字】找,不再要人输入 uuid。
--   返回找到的那些记录的 id(文本),交给 change_log_rows(p_record_ids => …):
--   · 单据号(document_types 登记的表的 code,大小写不论,整串相等)—— 今天还在的,与已经被删、只剩记录影像的;
--   · 名字(包含即可,大小写不论):供应商 / 客户的法定名、物料名、员工的称呼名与法定名、角色的英文名。
--   最多 50 个。门与 change_log_rows 相同。
CREATE OR REPLACE FUNCTION public.change_log_find_records(p_text text)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_q   text := btrim(COALESCE(p_text, ''));
    v_ids text[] := ARRAY[]::text[];
    v_one text[];
    d     record;
BEGIN
    PERFORM require_permission('data.view_change_log');
    IF length(v_q) < 2 THEN
        RETURN v_ids;
    END IF;
    FOR d IN SELECT DISTINCT dt.table_name FROM document_types dt LOOP
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_attribute a
                                   WHERE a.attrelid = format('public.%I', d.table_name)::regclass
                                     AND a.attname = 'code' AND NOT a.attisdropped);
        EXECUTE format('SELECT array_agg(t.id::text) FROM public.%I t WHERE upper(t.code) = upper($1)', d.table_name)
           INTO v_one USING v_q;
        v_ids := v_ids || COALESCE(v_one, ARRAY[]::text[]);
    END LOOP;
    v_ids := v_ids || COALESCE((SELECT array_agg(DISTINCT c.row_key ->> 'id') FROM change_log c
                                  WHERE COALESCE(c.new, c.old) @> jsonb_build_object('code', upper(v_q))
                                    AND c.row_key ? 'id'), ARRAY[]::text[]);
    v_ids := v_ids || COALESCE((SELECT array_agg(x.id) FROM (
                 SELECT s.id::text AS id FROM suppliers s WHERE s.legal_name ILIKE '%' || v_q || '%'
                 UNION SELECT c.id::text FROM customers c WHERE c.legal_name ILIKE '%' || v_q || '%'
                 UNION SELECT m.id::text FROM materials m WHERE m.name ILIKE '%' || v_q || '%'
                 UNION SELECT e.id::text FROM employees e
                        WHERE e.anonymised_at IS NULL
                          AND (e.legal_name ILIKE '%' || v_q || '%' OR e.preferred_name ILIKE '%' || v_q || '%')
                 UNION SELECT r.id::text FROM roles r WHERE r.name_en ILIKE '%' || v_q || '%') x), ARRAY[]::text[]);
    RETURN (SELECT array_agg(DISTINCT x) FROM (SELECT unnest(v_ids) x LIMIT 50) z);
END;
$function$;
