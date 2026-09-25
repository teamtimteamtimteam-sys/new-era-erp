-- db/tables/shipping_release_lines.sql
-- APR-5b(2026-09-25,grilling Q2):一张放行点名的发票行 —— 一行一条。
--
-- 【为什么点名发票行,而不是订单行】开票是整行的(invoice_lines 的唯一索引:一条订单行同时只有一条
--   在册发票行,开的就是整行数量),所以放行不需要数量;而覆盖要能【自己失效】—— 发票作废时那条
--   发票行 invoice_voided = true,「approved 且 NOT invoice_voided」这句话就不再成立,不需要任何
--   东西去改放行(Q3)。重开的发票是一条新的发票行,要一张新的放行。
-- 【sales_order_line_id 冗余存一份】发货按订单行问"被覆盖了吗",照发票行反查也行,但存一份让那个问题
--   只是一次等值连接;两列一致由提交函数保证(它就是从那条发票行读出来的),发票行冻结后不会再变。
--
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE TABLE public.shipping_release_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    release_id          uuid NOT NULL REFERENCES public.shipping_releases (id) ON DELETE RESTRICT,
    invoice_line_id     uuid NOT NULL REFERENCES public.invoice_lines (id) ON DELETE RESTRICT,
    sales_order_line_id uuid NOT NULL REFERENCES public.sales_order_lines (id) ON DELETE RESTRICT,
    created_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT shipping_release_lines_once UNIQUE (release_id, invoice_line_id)
);

COMMENT ON TABLE public.shipping_release_lines IS
    'APR-5b:放行点名的发票行,一行一条。覆盖 = 所属放行 approved 且这条发票行 NOT invoice_voided(现算;作废自动失效)。只经 submit_shipping_release 写。';

CREATE INDEX shipping_release_lines_invoice_line_id_rel ON public.shipping_release_lines (invoice_line_id);
CREATE INDEX shipping_release_lines_sales_order_line_id_rel ON public.shipping_release_lines (sales_order_line_id);

ALTER TABLE public.shipping_release_lines ENABLE ROW LEVEL SECURITY;

-- 读:与 shipping_releases 同一个码。写:一条策略都不给(只经 submit_shipping_release)。
CREATE POLICY "shipping_release_lines select by permission" ON public.shipping_release_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.sales.view'::text));

REVOKE ALL ON public.shipping_release_lines FROM anon;
