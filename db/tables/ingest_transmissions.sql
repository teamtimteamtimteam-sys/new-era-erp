-- db/tables/ingest_transmissions.sql
-- MES-1(2026-10-06,规格 §7「Logged」;MES-0 Q6 · Q7 · Q18;MES-1 Step 0 Q7 · Q8 · Q9 · Q18,Tim):【传输日志】。
--
-- 【三种行】
--   call               一次数据调用一行,接受的与拒绝的都记(哪一台网关报的编号、钥匙前缀、字节、消息数、几条收下 / 重复 / 退回、
--                      退回的每一条为什么、调用方报上来的地址)。
--   heartbeat_hour     一台网关一小时一行:那一小时的心跳次数、字节、第一次与最后一次(Q8)。每次心跳只让这四列往上长
--                      (count / bytes / last_at 只增,first_at 只减或不变),而且只经 ingest_submit —— 守卫按名拒别的写法。
--   rejected_overflow  失败太多时的溢出桶,10 分钟一行(Q9):一个报上来的编号滚动窗口里失败到预算(30),或全部失败调用到总闸(300),
--                      之后的失败不再一行一行记,只在这一行上计数 —— 编造编号的探测写不满这张表。
-- 【只追加】除了那两种桶的四个计数列,任何一行定下就不改;任何人都删不掉(语句级 —— 零行也触发)。
-- 【不进变更记录】(MES-0 Q14,Tim)它本身就是一份只追加的日志,再记一遍是把规格 §2.1 警告的量翻一倍,而不多一个事实。
-- 【调用方地址】(Q18)PostgREST 交过来的转发链原样存下,页面标 "reported address (not verified)";拿不到就是 'not available'。
--   X-Forwarded-For 调用方自己写得了,所以它是一条线索,不是一项证明。
-- 【读】持加工查看码的人;写只经 ingest_submit(SECURITY DEFINER)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.ingest_transmissions (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind                 text NOT NULL CHECK (kind IN ('call', 'heartbeat_hour', 'rejected_overflow')),
    received_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    presented_gateway    text CHECK (char_length(presented_gateway) <= 64),
    gateway_id           uuid REFERENCES public.devices (id),
    presented_key_prefix text CHECK (presented_key_prefix ~ '^[0-9a-f]{8}$'),
    result               text CHECK (result IN ('accepted', 'unknown_gateway', 'bad_key', 'revoked_key', 'retired_gateway',
                                                'too_large', 'too_many', 'malformed')),
    bytes                integer CHECK (bytes >= 0),
    message_count        integer CHECK (message_count >= 0),
    accepted_count       integer CHECK (accepted_count >= 0),
    duplicate_count      integer CHECK (duplicate_count >= 0),
    rejected_count       integer CHECK (rejected_count >= 0),
    stream               text,
    first_seq            bigint,
    last_seq             bigint,
    rejections           jsonb,
    client_address       text NOT NULL DEFAULT 'not available' CHECK (char_length(client_address) <= 200),
    bucket_start         timestamptz,
    bucket_count         integer CHECK (bucket_count > 0),
    bucket_bytes         bigint CHECK (bucket_bytes >= 0),
    bucket_first_at      timestamptz,
    bucket_last_at       timestamptz,
    CONSTRAINT ingest_transmissions_call_shape
        CHECK (kind <> 'call' OR (result IS NOT NULL AND bytes IS NOT NULL AND bucket_start IS NULL AND bucket_count IS NULL
                                  AND bucket_bytes IS NULL AND bucket_first_at IS NULL AND bucket_last_at IS NULL)),
    CONSTRAINT ingest_transmissions_bucket_shape
        CHECK (kind = 'call' OR (result IS NULL AND bucket_start IS NOT NULL AND bucket_count IS NOT NULL
                                 AND bucket_bytes IS NOT NULL AND bucket_first_at IS NOT NULL AND bucket_last_at IS NOT NULL
                                 AND bucket_first_at <= bucket_last_at)),
    CONSTRAINT ingest_transmissions_heartbeat_has_gateway
        CHECK (kind <> 'heartbeat_hour' OR gateway_id IS NOT NULL),
    CONSTRAINT ingest_transmissions_overflow_has_no_gateway
        CHECK (kind <> 'rejected_overflow' OR gateway_id IS NULL),
    CONSTRAINT ingest_transmissions_accepted_has_gateway
        CHECK (result IS DISTINCT FROM 'accepted' OR gateway_id IS NOT NULL)
);

COMMENT ON TABLE public.ingest_transmissions IS
    'MES-1:传输日志。call = 一次数据调用一行(接受的与拒绝的都记);heartbeat_hour = 一台网关一小时一行的心跳计数(Q8);rejected_overflow = 失败到预算之后 10 分钟一行的溢出计数(Q9)。只追加:除了两种桶的四个计数列,一行定下就不改,任何人都删不掉。不进变更记录(MES-0 Q14)。调用方地址原样存下,未经核实(Q18)。写只经 ingest_submit。';
COMMENT ON COLUMN public.ingest_transmissions.client_address IS
    'PostgREST 交过来的转发链(X-Forwarded-For),原样;调用方自己写得了,页面标 "reported address (not verified)"。拿不到就是 not available(Q18)。';

CREATE UNIQUE INDEX ingest_transmissions_heartbeat_hour
    ON public.ingest_transmissions (gateway_id, bucket_start) WHERE kind = 'heartbeat_hour';
CREATE UNIQUE INDEX ingest_transmissions_overflow_window
    ON public.ingest_transmissions (bucket_start) WHERE kind = 'rejected_overflow';
-- 失败预算的两次计数(按报上来的编号 / 全部)与"最后一次听到"(接受的调用)各一条
CREATE INDEX ingest_transmissions_failures_by_code
    ON public.ingest_transmissions (presented_gateway, received_at) WHERE kind = 'call' AND result <> 'accepted';
CREATE INDEX ingest_transmissions_failures
    ON public.ingest_transmissions (received_at) WHERE kind = 'call' AND result <> 'accepted';
CREATE INDEX ingest_transmissions_accepted_by_gateway
    ON public.ingest_transmissions (gateway_id, received_at) WHERE kind = 'call' AND result = 'accepted';

CREATE TRIGGER trg_ingest_transmissions_write
    BEFORE UPDATE ON public.ingest_transmissions
    FOR EACH ROW EXECUTE FUNCTION public.guard_ingest_transmissions_write();
CREATE TRIGGER trg_ingest_transmissions_no_delete
    BEFORE DELETE OR TRUNCATE ON public.ingest_transmissions
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_ingest_transmissions_write();

ALTER TABLE public.ingest_transmissions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ingest_transmissions select by permission" ON public.ingest_transmissions
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.ingest_transmissions FROM anon;
