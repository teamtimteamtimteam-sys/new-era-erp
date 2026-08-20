-- db/tables/containers.sql
-- LOG-2a:集装箱 —— 坐在 shipments 之上的一层。镜像与 db/migrations/2026-08-20-log2a-*.sql 同源。
-- 守卫与取号函数在 db/functions/(guard_container_forwarder / next_container_code /
-- soft_delete_container),这里只挂触发器。

CREATE SEQUENCE IF NOT EXISTS public.container_code_seq;

CREATE TABLE public.containers (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code             text NOT NULL UNIQUE,
    container_number text,
    vessel           text,
    voyage           text,
    lane_id          uuid REFERENCES public.lanes (id),
    forwarder_id     uuid REFERENCES public.suppliers (id),
    departure_date   date NOT NULL,
    bl_number        text,
    notes            text,
    deleted_at       timestamptz,
    deleted_by       uuid,
    delete_reason    text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.containers IS
'LOG-2a:集装箱 / 一次装运的物理载体 —— **坐在 shipments 之上**。
一个箱子可以装多张发货单,而那些发货单可以属于不同客户的不同订单;
但【每一张发货单仍然只属于一张订单】,所以 ship_order、完成度判据、ship_date 全都不动
(LOG-2-SURVEY 数过:那条路上有 10 个读者,这一层一个都不碰)。
【这里没有钱】:没有运费金额、没有应付 —— 那是第 4 层。
【提单号是承运人给的】,所以它是字段不是号段。【跟踪只有手工录入】。';

COMMENT ON COLUMN public.containers.departure_date IS
'LOG-2a:船开的那一天 —— 【世界那一侧的事实,系统永不代填】。
它不决定任何会计期间(收入期间仍由 shipments.ship_date 决定,见本刀抬头),
但它是里程碑与单据时限的锚点,填错了没有任何下游会喊。所以必填、无默认。';

CREATE INDEX idx_containers_lane ON public.containers (lane_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_containers_forwarder ON public.containers (forwarder_id) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_containers_updated_at
    BEFORE UPDATE ON public.containers
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_containers_forwarder
    BEFORE INSERT OR UPDATE ON public.containers
    FOR EACH ROW EXECUTE FUNCTION guard_container_forwarder();

ALTER TABLE public.containers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "containers select" ON public.containers
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.purchasing.view'::text));
CREATE POLICY "containers write" ON public.containers
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));
