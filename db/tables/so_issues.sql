-- db/tables/so_issues.sql
-- SO-1:销售订单签发档(形状取自 po_issues),只增不改。
--
-- NOTE: introduced by db/migrations/2026-08-13-so1-sales-order-document.sql.
-- First-run script (plain CREATEs).
--
-- 【没有"已发送"标志】系统不知道对方收没收到,而一个永远为 false 的标志
-- 会被读成"没发出去"。

-- ═══ 4 · 签发档(逐字镜像 po_issues)════════════════════════════════════════
CREATE TABLE public.so_issues (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sales_order_id uuid NOT NULL REFERENCES public.sales_orders (id),
    -- 每张单自己的版本号,从 1 起。客户手里那份是【某个具体版本】——
    -- 重新签发产生新版本,旧版本原样留着。
    version        integer NOT NULL CHECK (version >= 1),
    file_path      text NOT NULL,
    sha256         text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at      timestamptz NOT NULL DEFAULT now(),
    issued_by      uuid,
    UNIQUE (sales_order_id, version)
);

COMMENT ON TABLE public.so_issues IS
    'SO-1:销售订单签发档(形状取自 po_issues),只增不改。谁、何时、第几版、哪个对象、字节摘要。【没有"已发送"标志】—— 系统不知道对方收没收到,而一个永远为 false 的标志会被读成"没发出去"。唯一写入口 record_so_issue();重新签发 = 新的一行,绝不覆盖旧行 —— 客户手里那份是某个具体版本。';

CREATE INDEX idx_so_issues_order ON public.so_issues (sales_order_id, version DESC);

CREATE TRIGGER trg_so_issues_append_only
    BEFORE UPDATE OR DELETE ON public.so_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_so_issues_append_only();

ALTER TABLE public.so_issues           ENABLE ROW LEVEL SECURITY;

CREATE POLICY "so_issues select by permission" ON public.so_issues
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));
