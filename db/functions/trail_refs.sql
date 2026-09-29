-- db/functions/trail_refs.sql
-- AUDIT-TRAIL-1a(Tim 的 Q40):一行记录里【每一个指着别处的值】→ 它的名字。形状:
--   {"<列>": {"<原值>": {"label": …, "gone": …} | {"person": {…}}}}
--   扫的是这一行的旧影像、新影像与上下文影像(ctx,这一行今天的样子)里出现的值;受限标记与 null 不解析。
--   哪些列是引用由 trail_fk_targets 回答(目录里的外键 + 没有外键的账号列)。
-- 两个读法(record_trail · change_log_rows)共用。【属主身份】EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.trail_refs(p_table text, p_old jsonb, p_new jsonb, p_ctx jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    f     record;
    v     text;
    v_out jsonb := '{}'::jsonb;
    v_col jsonb;
BEGIN
    FOR f IN SELECT * FROM trail_fk_targets(p_table) LOOP
        v_col := '{}'::jsonb;
        FOR v IN SELECT DISTINCT x.val
                   FROM (SELECT p_old -> f.column_name AS j UNION ALL SELECT p_new -> f.column_name
                         UNION ALL SELECT p_ctx -> f.column_name) s
                   CROSS JOIN LATERAL (SELECT s.j #>> '{}' AS val) x
                  WHERE s.j IS NOT NULL AND jsonb_typeof(s.j) IN ('string', 'number') LOOP
            v_col := v_col || jsonb_build_object(v, trail_ref_label(f.target_table, f.target_column, v));
        END LOOP;
        IF v_col <> '{}'::jsonb THEN
            v_out := v_out || jsonb_build_object(f.column_name, v_col);
        END IF;
    END LOOP;
    RETURN v_out;
END;
$function$;
