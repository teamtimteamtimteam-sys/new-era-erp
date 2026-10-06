-- db/tables/weighbridge_ticket_shares.sql
-- MES-2(2026-10-06,MES-0 Q19 · Q21;MES-2 Step 0 Q18 · Q19 · Q20,Tim):【一张地磅单分给谁、各多少公斤】。
--   一行指向【恰好一个】去处:一张收货单(inbound_batch_id)或一条发货行(shipment_line_id)—— payment_allocations 的 XOR 形状;
--   kg 明写。只能从一张【完成了的】单分(TICKET_NOT_COMPLETE);方向要对:进厂单分给收货单、出厂单分给发货行
--   (TICKET_DIRECTION_MISMATCH)。各份之和【对着】净重显示,差多少就说多少 —— 从不强迫相等(MES-0 Q19)。
-- 【收货单】(Q19)份是在建收货单【的那一刻】给的:数量默认 = 这一份;人填了别的数,要写理由(receipt_quantity_reason)——
--   "收货单两个都留着" = 份的公斤数在这里、收货的数量在收货单上。收货单的数量建好之后不能改(QUANTITY_IMMUTABLE),
--   所以从地磅单页上把一张【已经存在】的收货单挂上来,它的数量一个字都不动,差多少照直显示。
-- 【发货行】(Q20)由持 action.ship_goods 的人从地磅单页上分;发货、开票、过账一样都不动 —— 不挪钱。
-- 【只追加】(guard_capture_append_only):分错的一份不撤 —— 它就是那一刻说过的话;差额在单上看得见。
-- 【读】module.inbound.view 或 module.logistics.view。进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.weighbridge_ticket_shares (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ticket_id               uuid NOT NULL REFERENCES public.weighbridge_tickets (id),
    inbound_batch_id        uuid REFERENCES public.inbound_batches (id),
    shipment_line_id        uuid REFERENCES public.shipment_lines (id),
    kg                      numeric NOT NULL CHECK (kg > 0),
    receipt_quantity_reason text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid DEFAULT auth.uid(),
    CONSTRAINT weighbridge_ticket_shares_one_target CHECK (num_nonnulls(inbound_batch_id, shipment_line_id) = 1),
    CONSTRAINT weighbridge_ticket_shares_reason_shape
        CHECK (receipt_quantity_reason IS NULL OR (inbound_batch_id IS NOT NULL AND btrim(receipt_quantity_reason) <> '')),
    CONSTRAINT weighbridge_ticket_shares_receipt_once UNIQUE (ticket_id, inbound_batch_id),
    CONSTRAINT weighbridge_ticket_shares_line_once UNIQUE (ticket_id, shipment_line_id)
);

COMMENT ON TABLE public.weighbridge_ticket_shares IS
    'MES-2:一张地磅单分给一张收货单或一条发货行的公斤数(恰好一个去处)。只从完成了的单分,方向要对;各份之和对着净重显示,不强迫相等。收货单的份在建单那一刻给,数量与份不同要写理由(receipt_quantity_reason)。发货行的份不挪钱。只追加。';

CREATE INDEX weighbridge_ticket_shares_batch ON public.weighbridge_ticket_shares (inbound_batch_id);
CREATE INDEX weighbridge_ticket_shares_line ON public.weighbridge_ticket_shares (shipment_line_id);

CREATE TRIGGER trg_weighbridge_ticket_shares_append_only
    BEFORE UPDATE ON public.weighbridge_ticket_shares
    FOR EACH ROW EXECUTE FUNCTION public.guard_capture_append_only();
CREATE TRIGGER trg_weighbridge_ticket_shares_no_delete
    BEFORE DELETE OR TRUNCATE ON public.weighbridge_ticket_shares
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_capture_append_only();

ALTER TABLE public.weighbridge_ticket_shares ENABLE ROW LEVEL SECURITY;

CREATE POLICY "weighbridge_ticket_shares select by permission" ON public.weighbridge_ticket_shares
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((has_permission('module.inbound.view'::text) OR has_permission('module.logistics.view'::text)));

REVOKE ALL ON public.weighbridge_ticket_shares FROM anon;
