-- db/tables/scan_events.sql
-- MES-3b(2026-10-07,MES-0 §3.1 · Q28 · Q29;MES-3b Step 0 Q19 · Q20,Tim):【每一次扫码】—— 一次解析一行,只追加。
--   写它的只有 resolve_scan_code(属主身份):页面上扫到 / 敲进去的那一串、在什么场合(查看 · 收货 · 转移 · 投料 · 预留 · 发货)、
--   用的什么(keyboard = 扫码枪或手敲 —— 对一个页面来说这两样一模一样;camera = 浏览器的 BarcodeDetector;
--   link = 有人打开了标签上的短链接 /b/… /loc/…)、认出来是什么、结果(found · restricted · unknown · unreadable)。
--   【id 只记给看得见它的人】resolved_id 只在 outcome = found 时有;restricted 只记那是哪一种东西、编号是什么(Q19)。
--   【不进变更记录】(Q20,MES-0 Q14 的先例):它自己就是一本只追加的日志,再记一遍只是翻倍。
--   读:库存查看码;页面上只画"你最近的扫码"(/inventory/scan)。
--   id 是 bigserial —— "最近"要排得出先后(AGENTS.md「取最新那一行要先问:这张表排得出先后吗」)。
--   固定式扫码器走 ingest 的 scan 类(MES-1),它的转换器这一刀不建(Q25):那些行照设计停在 awaiting_transform。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.scan_events (
    id             bigserial PRIMARY KEY,
    scanned_at     timestamptz NOT NULL DEFAULT now(),
    scanned_by     uuid NOT NULL DEFAULT auth.uid(),
    context        text NOT NULL CHECK (context IN ('lookup', 'receipt', 'transfer', 'feed', 'reserve', 'ship')),
    method         text NOT NULL CHECK (method IN ('keyboard', 'camera', 'link')),
    raw_value      text NOT NULL,
    parsed_code    text,
    resolved_kind  text CHECK (resolved_kind IN ('inbound_batch', 'output_batch', 'storage_location')),
    resolved_id    uuid,
    outcome        text NOT NULL CHECK (outcome IN ('found', 'restricted', 'unknown', 'unreadable')),
    CONSTRAINT scan_events_id_only_when_found CHECK (resolved_id IS NULL OR outcome = 'found'),
    CONSTRAINT scan_events_kind_when_resolved CHECK (outcome NOT IN ('found', 'restricted') OR resolved_kind IS NOT NULL)
);

COMMENT ON TABLE public.scan_events IS
    'MES-3b:每一次扫码的解析(只追加,不进变更记录)。context · method(keyboard · camera · link)· raw_value · 认出来的种类与编号 · outcome(found · restricted · unknown · unreadable);resolved_id 只在 found 时有。只有 resolve_scan_code 写。';

CREATE INDEX idx_scan_events_by ON public.scan_events (scanned_by, id DESC);

CREATE TRIGGER trg_scan_events_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.scan_events
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.scan_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "scan_events select by permission" ON public.scan_events
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inventory.view'::text));

REVOKE ALL ON public.scan_events FROM anon;
