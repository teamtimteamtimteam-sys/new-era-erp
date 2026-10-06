-- db/tables/weighbridge_tickets.sql
-- MES-2(2026-10-06,MES-0 Q19 · Q53;MES-2 Step 0 Q16 · Q17 · Q22,Tim):【地磅单】—— 一辆车进出地磅的那两磅。
--
-- 【两磅成一张】一张单由它的第一磅开出、第二磅完成(Q16):进厂(inbound)第一磅是毛重(满载进来),出厂(outbound)
--   第一磅是皮重(空车进来);第二磅是另一种。净重 = 毛重 − 皮重,≤ 0 按名拒(TICKET_NET_NOT_POSITIVE)。
--   两磅是 weighings 里 ticket_id 指着本单的那两行(角色 gross / tare);【更正】是一条新的称重(corrects_id),本单读最新的那一行,
--   所以毛重、皮重、净重、状态都【不存在本表】—— 在视图 weighbridge_ticket_weights 里读的时候算(一份算术,不两份)。
--   completed_at 是第二磅落下的那一刻(只记一次,给列表排序与"完成于"用)。
-- 【车】只记车牌(Q17):必填;不记司机姓名、不记证件号 —— 下游没有一处要一个人,车牌是过磅员配进出两磅的凭据。
-- 【编号】WB-YYYY-NNNN,有洞,保存时生成(MES-0 Q53);前缀住在 document_types(key weighbridge_ticket)。
-- 【作废】只在它【一份都没分出去】的时候,带理由(TICKET_HAS_SHARES)。不删(守卫)。
-- 【读】module.inbound.view 或 module.logistics.view(Q22,与照片桶同一道门);【写】只经函数。进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.
-- First-run script (plain CREATEs).

CREATE SEQUENCE public.weighbridge_ticket_code_seq;

CREATE TABLE public.weighbridge_tickets (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code         text NOT NULL UNIQUE,
    direction    text NOT NULL CHECK (direction IN ('inbound', 'outbound')),
    vehicle_reg  text NOT NULL CHECK (btrim(vehicle_reg) <> '' AND char_length(vehicle_reg) <= 20),
    notes        text,
    completed_at timestamptz,
    voided_at    timestamptz,
    voided_by    uuid,
    void_reason  text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    CONSTRAINT weighbridge_tickets_voided_shape
        CHECK ((voided_at IS NULL) = (voided_by IS NULL)
               AND (voided_at IS NULL OR btrim(COALESCE(void_reason, '')) <> ''))
);

COMMENT ON TABLE public.weighbridge_tickets IS
    'MES-2:地磅单 WB-YYYY-NNNN。一辆车进出的两磅:进厂第一磅毛重、出厂第一磅皮重;净重 = 毛重 − 皮重(> 0)。两磅是 weighings 里指着本单的行(更正读最新的),重量与状态在 weighbridge_ticket_weights 里读的时候算。只记车牌。作废要理由、且一份都没分出去。读:module.inbound.view 或 module.logistics.view。';
COMMENT ON COLUMN public.weighbridge_tickets.completed_at IS
    '第二磅落下的那一刻(记一次)。毛重、皮重、净重不在本表 —— 见视图 weighbridge_ticket_weights。';

CREATE INDEX weighbridge_tickets_created ON public.weighbridge_tickets (created_at);

CREATE TRIGGER trg_weighbridge_tickets_code
    BEFORE INSERT ON public.weighbridge_tickets
    FOR EACH ROW EXECUTE FUNCTION public.generate_weighbridge_ticket_code();
CREATE TRIGGER trg_weighbridge_tickets_updated_at
    BEFORE UPDATE ON public.weighbridge_tickets
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER trg_weighbridge_tickets_write
    BEFORE UPDATE ON public.weighbridge_tickets
    FOR EACH ROW EXECUTE FUNCTION public.guard_weighbridge_tickets_write();
CREATE TRIGGER trg_weighbridge_tickets_no_delete
    BEFORE DELETE OR TRUNCATE ON public.weighbridge_tickets
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_weighbridge_tickets_write();

ALTER TABLE public.weighbridge_tickets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "weighbridge_tickets select by permission" ON public.weighbridge_tickets
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((has_permission('module.inbound.view'::text) OR has_permission('module.logistics.view'::text)));

REVOKE ALL ON public.weighbridge_tickets FROM anon;
