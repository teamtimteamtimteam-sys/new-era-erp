-- db/tables/ingest_inbox.sql
-- MES-1(2026-10-06,规格 §6.4;MES-0 §3.2 · §3.5 · Q15;MES-1 Step 0 Q11 · Q13 · Q14 · Q15,Tim):【数据收件箱】—— 规格说的"落地表"。
--
-- 【网关不写业务表】(规格 §6.4)一条被收下的消息在这里落一行;ERP 这边的代码验证并规整它(转换),之后才有正式记录(MES-2 起)。
-- 【只收下,不转换】(Q11)网关那一次匿名调用只插入,状态 received;转换只在员工的会话里跑(ingest_process_pending,
--   收件箱页上的 "Process received" 按钮,持加工查看码的人)。于是从外面够得着的那一支函数里没有一行转换代码。
-- 【身份】(Q13)一条设备消息由 (网关, 流, 序号) 认:网关每次启动生成一个新的流 id,序号在一条流里递增。同一个三元组再来一次:
--   payload 哈希相同 = 重复,回 duplicates、不再落行;不同 = SEQ_REUSED,退回、不落行(那一次在传输日志里有记录)。
--   缺号不挡任何东西(MES-0 Q8),由 ingest_sequence_gaps 按流列出来。
-- 【信封错与内容错】(Q15)信封错(没有序号、不认识的类、不是这台网关的设备……)退回、不落行;内容错照收,在转换时失败,
--   看得见(status = failed + error_code),可以重试、可以带理由丢弃,永远不删。
-- 【手工录入走同一条路】(Q14)source = 'manual' ⇔ 没有网关、有录入人;整条手工路在 MES-2,本刀只建列与那条 CHECK。
-- 【只追加】一行定下之后只有转换的那几列会变(status · transformed_with · transform_result · error_code · attempts ·
--   last_attempt_*),丢弃的三列只写一次;转换成功或丢弃之后冻住;任何人都删不掉。规格 §6.4:失败的转换不丢。
-- 【保留】全部留着(MES-0 Q15)。
-- 【不进变更记录】(MES-0 Q14)它本身是一份只追加的日志;状态的变化记在行上(attempts · last_attempt_* · discarded_*)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.ingest_inbox (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transmission_id  bigint REFERENCES public.ingest_transmissions (id),
    source           text NOT NULL CHECK (source IN ('device', 'manual')),
    gateway_id       uuid REFERENCES public.devices (id),
    stream           text CHECK (char_length(stream) BETWEEN 1 AND 64),
    seq              bigint CHECK (seq >= 1),
    entered_by       uuid,
    device_id        uuid REFERENCES public.devices (id),
    data_class       text NOT NULL REFERENCES public.ingest_data_classes (code),
    payload          jsonb NOT NULL,
    payload_bytes    integer NOT NULL CHECK (payload_bytes >= 0),
    payload_sha256   bytea NOT NULL CHECK (octet_length(payload_sha256) = 32),
    site_from        timestamptz,
    site_to          timestamptz,
    site_dataset_ref text,
    clock_ahead      boolean NOT NULL DEFAULT false,
    received_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    status           text NOT NULL DEFAULT 'received'
        CHECK (status IN ('received', 'transformed', 'failed', 'awaiting_transform', 'discarded')),
    transformed_with text,
    transform_result jsonb,
    error_code       text,
    attempts         integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    last_attempt_at  timestamptz,
    last_attempt_by  uuid,
    discarded_at     timestamptz,
    discarded_by     uuid,
    discard_reason   text,
    -- Q14:手工 ⇔ 没有网关、有录入人;设备消息有网关、流、序号、设备,没有录入人
    CONSTRAINT ingest_inbox_source_shape
        CHECK ((source = 'manual' AND gateway_id IS NULL AND stream IS NULL AND seq IS NULL AND entered_by IS NOT NULL)
            OR (source = 'device' AND gateway_id IS NOT NULL AND stream IS NOT NULL AND seq IS NOT NULL
                AND device_id IS NOT NULL AND entered_by IS NULL)),
    CONSTRAINT ingest_inbox_site_range
        CHECK (site_from IS NULL OR site_to IS NULL OR site_from <= site_to),
    -- 失败一定带码;丢弃的那一行留着它丢弃之前的那个码(为什么失败,丢了也还看得见)
    CONSTRAINT ingest_inbox_failed_has_code
        CHECK (status <> 'failed' OR error_code IS NOT NULL),
    CONSTRAINT ingest_inbox_transformed_shape
        CHECK ((status = 'transformed') = (transformed_with IS NOT NULL)),
    CONSTRAINT ingest_inbox_discarded_shape
        CHECK ((status = 'discarded') = (discarded_at IS NOT NULL)
               AND (discarded_at IS NULL OR btrim(COALESCE(discard_reason, '')) <> ''))
);

COMMENT ON TABLE public.ingest_inbox IS
    'MES-1:数据收件箱(规格 §6.4 的落地表)。网关的匿名调用只插入(status = received);转换只在员工会话里跑(ingest_process_pending)。一条设备消息由 (网关, 流, 序号) 认:同 payload 再来 = 重复,不同 = SEQ_REUSED 退回。信封错退回不落行;内容错照收,转换失败看得见(failed + error_code),可重试、可带理由丢弃,永远不删。source = manual ⇔ 没有网关、有录入人(手工路在 MES-2)。只追加:只有转换的那几列会变;成功或丢弃之后冻住。不进变更记录(MES-0 Q14)。';
COMMENT ON COLUMN public.ingest_inbox.clock_ahead IS
    'site_to 比服务器收到它的时刻晚 ingest_settings.clock_ahead_s 秒以上(Q13,5 分钟)—— 网关的时钟走快了。标记,不退回。';

CREATE UNIQUE INDEX ingest_inbox_identity ON public.ingest_inbox (gateway_id, stream, seq) WHERE source = 'device';
CREATE INDEX ingest_inbox_status ON public.ingest_inbox (status, id);
CREATE INDEX ingest_inbox_device ON public.ingest_inbox (device_id);
CREATE INDEX ingest_inbox_transmission ON public.ingest_inbox (transmission_id);

CREATE TRIGGER trg_ingest_inbox_write
    BEFORE UPDATE ON public.ingest_inbox
    FOR EACH ROW EXECUTE FUNCTION public.guard_ingest_inbox_write();
CREATE TRIGGER trg_ingest_inbox_no_delete
    BEFORE DELETE OR TRUNCATE ON public.ingest_inbox
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_ingest_inbox_write();

ALTER TABLE public.ingest_inbox ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ingest_inbox select by permission" ON public.ingest_inbox
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.ingest_inbox FROM anon;
