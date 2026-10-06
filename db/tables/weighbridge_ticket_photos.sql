-- db/tables/weighbridge_ticket_photos.sql
-- MES-2(2026-10-06,MES-0 Q20;MES-2 Step 0 Q21,Tim):【地磅单的照片】—— 文件在私有桶 capture-photos 里,这里是它的登记行。
--   桶的读策略:module.inbound.view 或 module.logistics.view(本仓库第一个按权限码读的桶);传:action.confirm_capture;
--   桶里不能改、不能删。路径 = <地磅单 id>/<随机 id>-<文件名>;类型只收 jpeg / png / webp,大小 ≤ 10 MB(桶自己也卡)。
--   一张拍错的照片【撤下】(withdrawn_*,理由必填),行与对象都留着(守卫)。读:module.inbound.view 或 module.logistics.view。
--   桶与它的策略【不在镜像里】(AGENTS.md),它们的证明是 db/scripts/2026-10-06-mes2-capture-photos-policy-proof.sql。进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.weighbridge_ticket_photos (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ticket_id       uuid NOT NULL REFERENCES public.weighbridge_tickets (id),
    file_path       text NOT NULL UNIQUE,
    file_name       text NOT NULL CHECK (btrim(file_name) <> ''),
    mime_type       text NOT NULL CHECK (mime_type IN ('image/jpeg', 'image/png', 'image/webp')),
    size_bytes      integer NOT NULL CHECK (size_bytes > 0 AND size_bytes <= 10485760),
    uploaded_at     timestamptz NOT NULL DEFAULT now(),
    uploaded_by     uuid DEFAULT auth.uid(),
    withdrawn_at    timestamptz,
    withdrawn_by    uuid,
    withdraw_reason text,
    CONSTRAINT weighbridge_ticket_photos_path_shape CHECK (file_path LIKE ticket_id::text || '/%'),
    CONSTRAINT weighbridge_ticket_photos_withdrawn_shape
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)
               AND (withdrawn_at IS NULL OR btrim(COALESCE(withdraw_reason, '')) <> ''))
);

COMMENT ON TABLE public.weighbridge_ticket_photos IS
    'MES-2:地磅单照片的登记行;文件在私有桶 capture-photos(读:收货或物流查看码;传:action.confirm_capture;不能改、不能删)。jpeg / png / webp,≤ 10 MB。拍错的撤下(理由必填),行与对象都留着。';

CREATE INDEX weighbridge_ticket_photos_ticket ON public.weighbridge_ticket_photos (ticket_id);

CREATE TRIGGER trg_weighbridge_ticket_photos_write
    BEFORE UPDATE ON public.weighbridge_ticket_photos
    FOR EACH ROW EXECUTE FUNCTION public.guard_ticket_photos_write();
CREATE TRIGGER trg_weighbridge_ticket_photos_no_delete
    BEFORE DELETE OR TRUNCATE ON public.weighbridge_ticket_photos
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_ticket_photos_write();

ALTER TABLE public.weighbridge_ticket_photos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "weighbridge_ticket_photos select by permission" ON public.weighbridge_ticket_photos
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((has_permission('module.inbound.view'::text) OR has_permission('module.logistics.view'::text)));

REVOKE ALL ON public.weighbridge_ticket_photos FROM anon;
