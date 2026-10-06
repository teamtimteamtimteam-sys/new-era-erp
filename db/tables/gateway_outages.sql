-- db/tables/gateway_outages.sql
-- MES-1(2026-10-06,规格 §6.2;MES-0 Q9 · §3.8;MES-1 Step 0 Q17 · Q21,Tim):【网关中断】—— 过去的沉默,在网关回来那一刻记下。
--
-- 【没有调度器】(MES-0 §0 6)库里没有 pg_cron。所以"此刻在不在沉默"是读的时候算的(gateway_health);"那一段沉默"在网关
--   回来的那一次调用里写一行:上一次听到它的时刻 → 这一次,前提是两者之差超过了那台网关的心跳间隔。
--   间隔为空(Not yet set)就不记 —— 沉默无从判断,不发明一个数(Q17)。
-- 【一台坏了的网关与一台没事可报的网关分得开】没事可报的还在心跳;坏了的不心跳,回来时留下一行。
-- 【只追加,不进变更记录】(MES-0 Q14)。所以中断不在审计记录里 —— 设备页上自己一块列出来(Q21)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.gateway_outages (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gateway_id  uuid NOT NULL REFERENCES public.devices (id),
    silent_from timestamptz NOT NULL,
    silent_to   timestamptz NOT NULL,
    interval_s  integer NOT NULL CHECK (interval_s > 0),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT gateway_outages_range CHECK (silent_from < silent_to)
);

COMMENT ON TABLE public.gateway_outages IS
    'MES-1:网关中断。网关在一段超过它心跳间隔的沉默之后回来时,ingest_submit 记一行(上一次听到 → 这一次)。间隔没给就不记。只追加,不进变更记录(MES-0 Q14);设备页上自己一块列出来(Q21)。';

CREATE INDEX gateway_outages_gateway ON public.gateway_outages (gateway_id, silent_from);

CREATE TRIGGER trg_gateway_outages_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.gateway_outages
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_gateway_outages_append_only();

ALTER TABLE public.gateway_outages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "gateway_outages select by permission" ON public.gateway_outages
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.gateway_outages FROM anon;
