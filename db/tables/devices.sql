-- db/tables/devices.sql
-- MES-1(2026-10-06,MES-0 §3.2 · §5.2;MES-1 Step 0,Tim):【设备登记】—— 每一个物理数据源,网关也在内。
--
-- 【一台设备 = 一行】秤、地磅、放电柜、控制器、电表、工位终端、扫码枪、在线仪表、报警盘,以及把它们的数据带进来的
--   【网关】(kind = 'gateway')。一台非网关设备由哪一台网关带着,写在 gateway_id;网关只接受它自己带着的设备的消息
--   (DEVICE_NOT_ON_THIS_GATEWAY,Q6)。
-- 【编号】DEV-YYYY-NNNN,有洞(nextval,回滚不还号),保存时生成(Q28);人读的名字是另一列 name。
--   前缀住在 document_types(key 'device'),铸码只经 document_type_prefix('device') —— 与 task 同一个形状。
-- 【机器】equipment_id 指一张资产卡(fixed_assets)。那张表只给财务读,所以加工的读者经 equipment_usage 读它的标签(Q29)。
-- 【采购合同里的六条数据接口条款】(规格 §8.1)各一列:not_confirmed(默认,页面写 "Not yet confirmed")·
--   confirmed · not_offered(厂商不给)。它们是登记,不是闸。
-- 【心跳间隔】只有网关有;为空 = "Not yet set — silence cannot be judged"(V5,集成商在网关调试时给,Q17)。
-- 【没有"最后一次听到"这一类列】(Q7)最后一次调用、最后一次心跳、每一条流最大的序号,都在读的时候从
--   ingest_transmissions / ingest_inbox 推出来。本表记在变更记录里,一列每次心跳都改的列会让变更记录每分钟多一行 ——
--   而 Q14 排除那三张日志表正是为了不要那个量。于是网关那一次匿名调用【一行都不改】本表。
-- 【写】只经 SECURITY DEFINER 函数(save_device · retire_device,action.manage_devices);没有写策略。
--   停用(retired_at)不删:收件箱与传输日志指着它;删一台设备要先有它从来没送过数据 —— 不提供,停用就是它的去处。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.
-- First-run script (plain CREATEs).

CREATE SEQUENCE public.device_code_seq;

CREATE TABLE public.devices (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                     text NOT NULL UNIQUE,
    name                     text NOT NULL CHECK (btrim(name) <> ''),
    kind                     text NOT NULL
        CHECK (kind IN ('gateway', 'scale', 'weighbridge', 'discharge_cabinet', 'controller', 'meter',
                        'workstation', 'scanner', 'inline_instrument', 'alarm_panel')),
    gateway_id               uuid REFERENCES public.devices (id),
    data_class               text REFERENCES public.ingest_data_classes (code),
    equipment_id             uuid REFERENCES public.fixed_assets (id),
    station                  text,
    capacity                 numeric CHECK (capacity > 0),
    resolution               numeric CHECK (resolution > 0),
    unit                     text,
    protection_rating        text,
    interface_status         text NOT NULL DEFAULT 'reserved'
        CHECK (interface_status IN ('reserved', 'manual_only', 'connected')),
    term_protocol            text NOT NULL DEFAULT 'not_confirmed'
        CHECK (term_protocol IN ('not_confirmed', 'confirmed', 'not_offered')),
    term_point_list          text NOT NULL DEFAULT 'not_confirmed'
        CHECK (term_point_list IN ('not_confirmed', 'confirmed', 'not_offered')),
    term_timestamp_precision text NOT NULL DEFAULT 'not_confirmed'
        CHECK (term_timestamp_precision IN ('not_confirmed', 'confirmed', 'not_offered')),
    term_no_charge           text NOT NULL DEFAULT 'not_confirmed'
        CHECK (term_no_charge IN ('not_confirmed', 'confirmed', 'not_offered')),
    term_retention_export    text NOT NULL DEFAULT 'not_confirmed'
        CHECK (term_retention_export IN ('not_confirmed', 'confirmed', 'not_offered')),
    term_documentation       text NOT NULL DEFAULT 'not_confirmed'
        CHECK (term_documentation IN ('not_confirmed', 'confirmed', 'not_offered')),
    heartbeat_interval_s     integer CHECK (heartbeat_interval_s > 0),
    notes                    text,
    retired_at               timestamptz,
    retired_by               uuid,
    retire_reason            text,
    created_at               timestamptz NOT NULL DEFAULT now(),
    created_by               uuid DEFAULT auth.uid(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    updated_by               uuid DEFAULT auth.uid(),
    -- 网关不被别的网关带着,也不声明数据类(它带的设备才声明)
    CONSTRAINT devices_gateway_shape
        CHECK (kind <> 'gateway' OR (gateway_id IS NULL AND data_class IS NULL)),
    -- 心跳间隔只属于网关
    CONSTRAINT devices_heartbeat_gateway_only
        CHECK (kind = 'gateway' OR heartbeat_interval_s IS NULL),
    CONSTRAINT devices_not_own_gateway
        CHECK (gateway_id IS DISTINCT FROM id),
    CONSTRAINT devices_retired_shape
        CHECK ((retired_at IS NULL AND retired_by IS NULL AND retire_reason IS NULL)
            OR (retired_at IS NOT NULL AND btrim(COALESCE(retire_reason, '')) <> ''))
);

COMMENT ON TABLE public.devices IS
    'MES-1:设备登记 —— 每一个物理数据源(秤、地磅、放电柜、控制器、电表、工位终端、扫码枪、在线仪表、报警盘)与把它们的数据带进来的网关(kind = gateway)。编号 DEV-YYYY-NNNN 保存时生成;人读的名字是 name。网关只接受它自己带着的设备(gateway_id)的消息。六条采购合同的数据接口条款各一列(not_confirmed / confirmed / not_offered)。心跳间隔只有网关有,为空 = 还没给(V5)。最后一次听到网关的时刻不存在这里,读的时候从传输日志推出来 —— 网关的匿名调用一行都不改本表。写只经 save_device / retire_device(action.manage_devices);停用,不删。';
COMMENT ON COLUMN public.devices.heartbeat_interval_s IS
    '网关的心跳间隔(秒)。为空 = Not yet set:沉默无从判断,不记中断、不上提醒(Q17)。由集成商在网关调试时给(V5)。';
COMMENT ON COLUMN public.devices.interface_status IS
    'reserved:接口还没接上(默认);manual_only:这台设备永远手工录;connected:网关在送它的数据。';

CREATE INDEX devices_gateway_id ON public.devices (gateway_id);
CREATE INDEX devices_code_trgm ON public.devices USING gin (code extensions.gin_trgm_ops);

CREATE TRIGGER trg_generate_device_code
    BEFORE INSERT ON public.devices
    FOR EACH ROW EXECUTE FUNCTION public.generate_device_code();

CREATE TRIGGER trg_devices_updated_at
    BEFORE UPDATE ON public.devices
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- 编号与种类定下就不动;停用的那一行冻住;任何人都删不掉(语句级 —— 零行也触发,U1-B 的那一课)。
CREATE TRIGGER trg_devices_write
    BEFORE UPDATE ON public.devices
    FOR EACH ROW EXECUTE FUNCTION public.guard_devices_write();
CREATE TRIGGER trg_devices_no_delete
    BEFORE DELETE ON public.devices
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_devices_write();

ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;

-- 读:持加工查看码的人(MES-0 §3.10)。写只经函数。
CREATE POLICY "devices select by permission" ON public.devices
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.devices FROM anon;
