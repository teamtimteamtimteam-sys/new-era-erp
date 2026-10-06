-- db/views/weighbridge_ticket_weights.sql
-- MES-2(2026-10-06,MES-0 Q19;MES-2 Step 0 Q16 · Q18,Tim):【一张地磅单此刻的毛重、皮重、净重,以及分出去了多少】—— 读的时候算。
--   毛重 / 皮重 = 指着本单、角色 gross / tare、【没被更正过】的那一行称重;净重 = 毛重 − 皮重(两磅都在才有)。
--   status:voided · complete(两磅都在)· open。
--   shared_kg = 分给【没删除】的收货单与发货行的份之和;difference_kg = 净重 − shared_kg —— 照直显示,从不强迫为 0(MES-0 Q19)。
--   deleted_receipt_shares = 分给了后来被删除的收货单的份数(那几份不计入 shared_kg,单上点名)。
--   【属主视图】读称重、份与收货单不过 RLS,所以行谓词在这里再问一次 —— 与地磅单表的读策略逐字同一句(收货或物流)。

CREATE VIEW public.weighbridge_ticket_weights WITH (security_invoker = off) AS
 SELECT t.id AS ticket_id,
    t.code,
    t.direction,
    t.vehicle_reg,
    t.notes,
    t.created_at,
    t.created_by,
    t.completed_at,
    t.voided_at,
    t.void_reason,
        CASE
            WHEN t.voided_at IS NOT NULL THEN 'voided'::text
            WHEN g.weight_kg IS NOT NULL AND tr.weight_kg IS NOT NULL THEN 'complete'::text
            ELSE 'open'::text
        END AS status,
    g.id AS gross_weighing_id,
    g.weight_kg AS gross_kg,
    g.captured_at AS gross_at,
    tr.id AS tare_weighing_id,
    tr.weight_kg AS tare_kg,
    tr.captured_at AS tare_at,
    g.weight_kg - tr.weight_kg AS net_kg,
    COALESCE(sh.shared_kg, 0::numeric) AS shared_kg,
    g.weight_kg - tr.weight_kg - COALESCE(sh.shared_kg, 0::numeric) AS difference_kg,
    COALESCE(sh.share_count, 0::bigint) AS share_count,
    COALESCE(sh.deleted_receipt_shares, 0::bigint) AS deleted_receipt_shares
   FROM weighbridge_tickets t
     LEFT JOIN LATERAL ( SELECT w.id,
            w.weight_kg,
            w.captured_at
           FROM weighings w
          WHERE w.ticket_id = t.id AND w.role = 'gross'::text
            AND NOT (EXISTS ( SELECT 1 FROM weighings x WHERE x.corrects_id = w.id))) g ON true
     LEFT JOIN LATERAL ( SELECT w.id,
            w.weight_kg,
            w.captured_at
           FROM weighings w
          WHERE w.ticket_id = t.id AND w.role = 'tare'::text
            AND NOT (EXISTS ( SELECT 1 FROM weighings x WHERE x.corrects_id = w.id))) tr ON true
     LEFT JOIN LATERAL ( SELECT sum(s.kg) FILTER (WHERE b.deleted_at IS NULL) AS shared_kg,
            count(*) FILTER (WHERE b.deleted_at IS NULL) AS share_count,
            count(*) FILTER (WHERE b.deleted_at IS NOT NULL) AS deleted_receipt_shares
           FROM weighbridge_ticket_shares s
             LEFT JOIN inbound_batches b ON b.id = s.inbound_batch_id
          WHERE s.ticket_id = t.id) sh ON true
  WHERE has_permission('module.inbound.view'::text) OR has_permission('module.logistics.view'::text);

COMMENT ON VIEW public.weighbridge_ticket_weights IS
    'MES-2:地磅单此刻的毛重、皮重(没被更正过的那两行)、净重、状态(voided · complete · open),以及分给没删除的收货单与发货行的公斤数之和与差额(照直显示,不强迫为 0)。行谓词:收货或物流查看码。';

GRANT SELECT ON public.weighbridge_ticket_weights TO authenticated;
REVOKE ALL ON public.weighbridge_ticket_weights FROM anon;
