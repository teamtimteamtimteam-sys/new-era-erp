-- db/tables/ingest_settings.sql
-- MES-1(2026-10-06,MES-0 Q7 · V32;MES-1 Step 0 Q9 · Q13 · Q22,Tim):采集层的【传输上限】—— 单行配置。
--
-- 【这些是传输上限,不是业务标准】(MES-0 Q7)它们保护的是日志与库,不是任何一道工艺:
--   fail_budget / fail_window_s    一个【报上来的网关编号】滚动 10 分钟里 30 次失败调用 —— 之后它的失败不再一行一行记,
--                                  计进 10 分钟一行的溢出桶(Q9)。持【有效钥匙】的调用永远不受它限(Q9)。
--   global_reject_budget           全部失败调用滚动 10 分钟里 300 次的总闸 —— 防的是轮换编造的编号把日志写满(Q9)。
--   max_payload_bytes · max_messages  每次调用 256 KB、500 条消息。
--   clock_ahead_s                  一条消息的 site_to 比服务器收到它的时刻晚这么多秒以上,就标 "clock ahead"(Q13,5 分钟)。
-- 【RUNTIME CONFIG】持 action.manage_devices 的人在设备页上改(set_ingest_settings);引导值就是 Q7 / Q9 / Q13 裁定的那几个数,
--   线上被改过就与本文件不同 —— 那是系统在正常工作。修改史 = 变更记录 + 审计记录主语 ingest_settings(Q22),没有另一张历史表。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.ingest_settings (
    id                   boolean PRIMARY KEY DEFAULT true CHECK (id),
    fail_budget          integer NOT NULL DEFAULT 30 CHECK (fail_budget > 0),
    fail_window_s        integer NOT NULL DEFAULT 600 CHECK (fail_window_s > 0),
    global_reject_budget integer NOT NULL DEFAULT 300 CHECK (global_reject_budget > 0),
    max_payload_bytes    integer NOT NULL DEFAULT 262144 CHECK (max_payload_bytes > 0),
    max_messages         integer NOT NULL DEFAULT 500 CHECK (max_messages > 0),
    clock_ahead_s        integer NOT NULL DEFAULT 300 CHECK (clock_ahead_s > 0),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    updated_by           uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.ingest_settings IS
    'MES-1:采集层的传输上限(单行)。每个报上来的网关编号滚动窗口里的失败次数(30 / 600 秒)、全部失败调用的总闸(300)、每次调用的字节与消息上限(256 KB / 500)、"时钟超前"的判据(300 秒)。它们保护日志与库,不是业务标准;持有效钥匙的调用永远不受失败预算限。由 action.manage_devices 经 set_ingest_settings 修改;修改史在变更记录里。';

INSERT INTO public.ingest_settings (id) VALUES (true);

CREATE TRIGGER trg_ingest_settings_updated_at
    BEFORE UPDATE ON public.ingest_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.ingest_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ingest_settings select by permission" ON public.ingest_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.ingest_settings FROM anon;
