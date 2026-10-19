-- db/functions/portal_deliveries.sql
-- MES-9b(2026-10-19,MES-9 Step 0 Q14 · Q15 · §4,Tim):【门户的收货与地磅单】—— 调用者自己那一家的收货记录,以及记在这些收货上的地磅单,
--   【按今天库里记着的样子】(as_of 是这一次读的时刻;页面写"as recorded today")。它们是记录,不是签发过的单据,所以没有 PDF。
--   先过 portal_require_link()(角色 · 链接 · 撤销 · 会话);供应商只从链接推出来,没有任何参数。
--   收货:单号 · 到货日 · 物料名 · 数量与单位 · 关联的采购单号。地磅单:单号 · 方向 · 完成时刻 · 是否作废 · 【分到这家收货上的公斤数】
--     (一张地磅单可以分给几张收货 —— 只回分给【自己那几张】的那几份,别家的那一份连存在都不说)。
--   【一个价钱都没有,一样内部的都没有】(Q15 · §4):不回单价、计价状态、估值、安全状态、库位、加工阶段、备注、车牌、照片、
--     毛重皮重、任何员工的名字。软删的收货不出现;作废的地磅单照样列出、标 voided。
--   EXECUTE 只授 supplier_portal(zzz_function_grants.sql;db/portal-grants-baseline.tsv,判词八)。
-- NOTE: introduced by db/migrations/2026-10-19-mes9b-what-a-supplier-sees.sql.
CREATE OR REPLACE FUNCTION public.portal_deliveries()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link     uuid := portal_require_link();
    v_supplier uuid;
BEGIN
    SELECT p.supplier_id INTO v_supplier FROM supplier_portal_users p WHERE p.id = v_link;
    RETURN jsonb_build_object(
        'supplier_code', (SELECT s.code FROM suppliers s WHERE s.id = v_supplier),
        'as_of', now(),
        'receipts', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'code', b.code,
                       'arrival_date', b.arrival_date,
                       'material', m.name,
                       'quantity', b.quantity,
                       'unit', b.unit,
                       'purchase_order_code', (SELECT po.code FROM purchase_orders po WHERE po.id = b.purchase_order_id AND po.deleted_at IS NULL),
                       'tickets', COALESCE((
                           SELECT jsonb_agg(t.code ORDER BY t.code)
                             FROM weighbridge_ticket_shares sh JOIN weighbridge_tickets t ON t.id = sh.ticket_id
                            WHERE sh.inbound_batch_id = b.id), '[]'::jsonb))
                   ORDER BY b.arrival_date DESC NULLS LAST, b.code DESC)
              FROM inbound_batches b
              JOIN materials m ON m.id = b.material_id
             WHERE b.supplier_id = v_supplier AND b.deleted_at IS NULL), '[]'::jsonb),
        'tickets', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'code', t.code,
                       'direction', t.direction,
                       'completed_at', t.completed_at,
                       'voided', t.voided_at IS NOT NULL,
                       'shares', (SELECT jsonb_agg(jsonb_build_object('receipt_code', b.code, 'kg', sh.kg) ORDER BY b.code)
                                    FROM weighbridge_ticket_shares sh JOIN inbound_batches b ON b.id = sh.inbound_batch_id
                                   WHERE sh.ticket_id = t.id AND b.supplier_id = v_supplier AND b.deleted_at IS NULL))
                   ORDER BY t.created_at DESC, t.code DESC)
              FROM weighbridge_tickets t
             WHERE EXISTS (SELECT 1 FROM weighbridge_ticket_shares sh JOIN inbound_batches b ON b.id = sh.inbound_batch_id
                            WHERE sh.ticket_id = t.id AND b.supplier_id = v_supplier AND b.deleted_at IS NULL)), '[]'::jsonb));
END;
$function$;
