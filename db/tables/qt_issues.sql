-- db/tables/qt_issues.sql
-- SO-4a:报价的签发档,so_issues 的第五份,一个字没改。
--
-- NOTE: introduced by db/migrations/2026-08-15-so4a-quotation-engine.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.qt_issues (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    quote_id   uuid NOT NULL REFERENCES public.quotes (id),
    version    integer NOT NULL CHECK (version >= 1),
    file_path  text NOT NULL,
    sha256     text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    -- 【clock_timestamp() 而不是 now() —— fu1】它是"签发之后又改过"那个比较式
    -- 的一边,而 now() 在一个事务里是常量,比不出先后(fixture 72 G 臂撞出来的)。
    issued_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
    issued_by  uuid,
    UNIQUE (quote_id, version)
);

COMMENT ON TABLE public.qt_issues IS
    'SO-4a:报价的签发档,形状逐字取自 so_issues / po_issues / shipment_issues / cn_issues(这是第五份)。【它比别处更要紧】:报价的 draft/issued 行不上冻结守卫,所以"当初报的是什么"这个问题的唯一硬答案就是这里的字节 —— 客户手里那份是某个具体版本,sha256 对不上就拒绝给出。唯一写入口 record_qt_issue();第一次签发把 draft 翻成 issued。';

COMMENT ON COLUMN public.qt_issues.issued_at IS
    'SO-4a:这一版签发出去的时刻。【clock_timestamp() 而不是 now()】—— 它是"签发之后又改过"那个比较式的一边,而 now() 是事务开始时刻、在一个事务里是常量:同一事务里先签发后改动会拿到同一个时间戳,信号于是永远不亮(fixture 72 G 臂撞出来的)。列的用途是比出先后,时钟就必须会走。';

CREATE INDEX idx_qt_issues_quote ON public.qt_issues (quote_id, version DESC);

CREATE TRIGGER trg_qt_issues_append_only
    BEFORE UPDATE OR DELETE ON public.qt_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_quote_history_append_only();

ALTER TABLE public.qt_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY "qt_issues select by permission" ON public.qt_issues
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));
