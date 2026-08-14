-- db/tables/shipment_issues.sql
-- SO-3b:送货单签发档(逐字取自 so_issues 的形状),只增不改。
--
-- NOTE: introduced by db/migrations/2026-08-15-so3b-shipment.sql.
-- First-run script (plain CREATEs).
--
-- 【签发的是记录,不是视图】客户手里那份送货单是【某个具体版本】的字节;
-- 此后数据、渲染器、字体子集怎么变,那份字节都原样在桶里(so-documents 那一条)。
-- 【没有"已发送"标志】系统不知道对方收没收到,而一个永远为 false 的标志
-- 会被读成"没发出去"。

CREATE TABLE public.shipment_issues (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    shipment_id uuid NOT NULL REFERENCES public.shipments (id),
    version     integer NOT NULL CHECK (version >= 1),
    file_path   text NOT NULL,
    sha256      text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at   timestamptz NOT NULL DEFAULT now(),
    issued_by   uuid,
    UNIQUE (shipment_id, version)
);

COMMENT ON TABLE public.shipment_issues IS
    'SO-3b:送货单签发档(形状取自 so_issues),只增不改。谁、何时、第几版、哪张发货单、字节摘要。唯一写入口 record_shipment_issue();重新签发 = 新的一行,绝不覆盖旧行 —— 客户手里那份是某个具体版本。【没有"已发送"标志】:系统不知道对方收没收到。';

CREATE INDEX idx_shipment_issues_shipment ON public.shipment_issues (shipment_id, version DESC);

CREATE TRIGGER trg_shipment_issues_append_only
    BEFORE UPDATE OR DELETE ON public.shipment_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_shipment_append_only();

ALTER TABLE public.shipment_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY "shipment_issues select by permission" ON public.shipment_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.sales.view'::text));
