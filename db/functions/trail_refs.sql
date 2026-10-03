-- db/functions/trail_refs.sql
-- AUDIT-TRAIL-1a(Tim 的 Q40):一行记录里【每一个指着别处的值】→ 它的名字。形状:
--   {"<列>": {"<原值>": {"label": …, "gone": …} | {"person": {…}}}}
--   扫的是这一行的旧影像、新影像与上下文影像(ctx,这一行今天的样子)里出现的值;受限标记与 null 不解析。
--   哪些列是引用由 trail_fk_targets 回答(目录里的外键 + 没有外键的账号列)。
-- 两个读法(record_trail · change_log_rows)共用。【属主身份】EXECUTE 已从 authenticated 收回。
-- AUDIT-TRAIL-1c-1(Q13):付款申请的 allocations 是一段 JSONB(要结清哪几张单据),不是外键 —— 里面的每一个单据 id
--   照样解析成单号,放在 refs 的 'allocations' 一格下;界面据此把它说成"PO-… · 1,000.00",不说 "Details changed"。
--   键 → 表:expense_id → expenses · inbound_batch_id → inbound_batches · purchase_order_id → purchase_orders ·
--   freight_document_id → freight_documents(与 record_payment 收的那一组同一个形状)。
-- AUDIT-TRAIL-1c-2(Q10):资产卡的修改史(fixed_asset_history)把每一列存成一对 old_<列> / new_<列>,而这一对没有外键 ——
--   于是"处置分录"、"来自哪张费用"在修改史里读不出名字。这里按 fixed_assets 自己那一列的外键去解析那一对,
--   放在 old_<列> / new_<列> 那两格下(界面按资产卡的列说它们,同一个名字)。
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
    IF p_table = 'fixed_asset_history' THEN
        FOR f IN SELECT ft.*, pre.p FROM trail_fk_targets('fixed_assets') ft CROSS JOIN (VALUES ('old_'), ('new_')) pre(p) LOOP
            v_col := '{}'::jsonb;
            FOR v IN SELECT DISTINCT x.val
                       FROM (SELECT p_old -> (f.p || f.column_name) AS j UNION ALL SELECT p_new -> (f.p || f.column_name)
                             UNION ALL SELECT p_ctx -> (f.p || f.column_name)) s
                       CROSS JOIN LATERAL (SELECT s.j #>> '{}' AS val) x
                      WHERE s.j IS NOT NULL AND jsonb_typeof(s.j) IN ('string', 'number') LOOP
                v_col := v_col || jsonb_build_object(v, trail_ref_label(f.target_table, f.target_column, v));
            END LOOP;
            IF v_col <> '{}'::jsonb THEN
                v_out := v_out || jsonb_build_object(f.p || f.column_name, v_col);
            END IF;
        END LOOP;
    END IF;
    IF p_table = 'payment_requests' THEN
        v_col := '{}'::jsonb;
        FOR f IN SELECT DISTINCT e.key AS k, e.value #>> '{}' AS v
                   FROM (SELECT p_old -> 'allocations' AS j UNION ALL SELECT p_new -> 'allocations' UNION ALL SELECT p_ctx -> 'allocations') s
                   CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(s.j) = 'array' THEN s.j ELSE '[]'::jsonb END) a
                   CROSS JOIN LATERAL jsonb_each(CASE WHEN jsonb_typeof(a) = 'object' THEN a ELSE '{}'::jsonb END) e
                  WHERE e.key IN ('expense_id', 'inbound_batch_id', 'purchase_order_id', 'freight_document_id')
                    AND jsonb_typeof(e.value) = 'string' LOOP
            v_col := v_col || jsonb_build_object(f.v, trail_ref_label(
                CASE f.k WHEN 'expense_id' THEN 'expenses' WHEN 'inbound_batch_id' THEN 'inbound_batches'
                         WHEN 'purchase_order_id' THEN 'purchase_orders' ELSE 'freight_documents' END, 'id', f.v));
        END LOOP;
        IF v_col <> '{}'::jsonb THEN
            v_out := v_out || jsonb_build_object('allocations', v_col);
        END IF;
    END IF;
    RETURN v_out;
END;
$function$;
