-- db/functions/warehouse_request_snapshot.sql
-- APR-7(2026-09-25,grilling Q5 · Q8):提交时冻给 CFO 读的那一组。CFO 不持 action.issue_cod,读不到证书表 ——
-- 所以"这会作废哪一张证书"要在这里说出来;回滚的加工日是否落在已锁期间(finance_settings.locked_before)
-- 也在这里说出来(Q5:准许,但批之前要看得见)。【不含金额】—— 金额在 amount_base,按 data.view_prices 给。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_snapshot(p_kind text, p_subject uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_kind
    WHEN 'write_off_inbound' THEN (
        SELECT jsonb_build_object(
            'batch_code', ib.code, 'material_code', m.code, 'material_name', m.name,
            'supplier_name', COALESCE(s.short_name, s.legal_name), 'remaining_qty', ib.remaining_qty,
            'quantity', ib.quantity, 'unit', ib.unit, 'priced', ib.unit_price IS NOT NULL,
            'cods_voided', COALESCE((SELECT jsonb_agg(c.code ORDER BY c.code) FROM certificates_of_destruction c
                                      WHERE c.inbound_batch_id = ib.id AND c.status = 'issued'), '[]'::jsonb))
          FROM inbound_batches ib
          LEFT JOIN materials m ON m.id = ib.material_id
          LEFT JOIN suppliers s ON s.id = ib.supplier_id
         WHERE ib.id = p_subject)
    WHEN 'write_off_output' THEN (
        SELECT jsonb_build_object(
            'batch_code', ob.code, 'material_code', m.code, 'material_name', m.name,
            'remaining_qty', ob.remaining_qty, 'quantity', ob.quantity, 'unit', ob.unit, 'state', ob.state,
            'run_code', (SELECT pr.code FROM processing_outputs po JOIN processing_runs pr ON pr.id = po.run_id
                          WHERE po.output_batch_id = ob.id LIMIT 1),
            'cods_voided', '[]'::jsonb)
          FROM output_batches ob
          LEFT JOIN materials m ON m.id = ob.material_id
         WHERE ob.id = p_subject)
    WHEN 'rollback' THEN (
        SELECT jsonb_build_object(
            'run_code', pr.code, 'process_date', pr.process_date,
            'locked_period', pr.process_date < (SELECT fs.locked_before FROM finance_settings fs),
            'locked_before', (SELECT fs.locked_before FROM finance_settings fs),
            'outputs', COALESCE((SELECT jsonb_agg(ob.code ORDER BY ob.code) FROM processing_outputs po
                                   JOIN output_batches ob ON ob.id = po.output_batch_id
                                  WHERE po.run_id = pr.id AND ob.deleted_at IS NULL), '[]'::jsonb),
            'inputs', COALESCE((SELECT jsonb_agg(DISTINCT COALESCE(ib.code, ob.code)) FROM processing_inputs pi
                                  LEFT JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
                                  LEFT JOIN output_batches ob ON ob.id = pi.output_batch_id
                                 WHERE pi.run_id = pr.id), '[]'::jsonb),
            'cods_voided', COALESCE((SELECT jsonb_agg(DISTINCT c.code) FROM processing_inputs pi
                                       JOIN certificates_of_destruction c
                                         ON c.inbound_batch_id = pi.inbound_batch_id AND c.status = 'issued'
                                      WHERE pi.run_id = pr.id), '[]'::jsonb))
          FROM processing_runs pr
         WHERE pr.id = p_subject)
    WHEN 'cod_void' THEN (
        SELECT jsonb_build_object(
            'cod_code', c.code, 'batch_code', ib.code, 'supplier_name', COALESCE(s.short_name, s.legal_name),
            'material_name', m.name, 'issued_at', c.issued_at, 'completed_on', c.completed_on,
            'cods_voided', jsonb_build_array(c.code))
          FROM certificates_of_destruction c
          JOIN inbound_batches ib ON ib.id = c.inbound_batch_id
          LEFT JOIN materials m ON m.id = ib.material_id
          LEFT JOIN suppliers s ON s.id = ib.supplier_id
         WHERE c.id = p_subject)
    END
$function$;
