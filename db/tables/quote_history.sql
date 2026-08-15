-- db/tables/quote_history.sql
-- SO-4a:报价的生命周期留痕,只增不改。
--
-- NOTE: introduced by db/migrations/2026-08-15-so4a-quotation-engine.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.quote_history (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    quote_id    uuid NOT NULL REFERENCES public.quotes (id),
    -- 【只记生命周期的四件事,不记逐行编辑】报价的每一次改动都是谈判本身,
    -- 记进来只会把这四件真正的事件淹掉;而"当时报的是什么"有一个更硬的答案 ——
    -- qt_issues 里那份签发过的字节。
    change_type text NOT NULL CHECK (change_type IN ('created','issued','declined','converted')),
    detail      text,
    changed_at  timestamptz NOT NULL DEFAULT now(),
    changed_by  uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.quote_history IS
    'SO-4a:报价的生命周期留痕,只增不改(形状取自 sales_order_history)。【只记四件事】created / issued / declined / converted —— 逐行编辑不进来:报价的每一次改动都是谈判本身,记进来会把这四个真正的事件淹掉,而"当时报的是什么"有一个更硬的答案(qt_issues 里签发过的那份字节)。【created 由触发器写,不由某扇门写】:SO-1 的建单是三条客户端直插、留痕那条被 RLS 拒且错误被丢掉,于是线上 SO-2026-0001 至今缺着那一行;SO-2b 的修法是收门,而报价这边【直接编辑就是设计】,收门走不通 —— 换成 AFTER INSERT 触发器。两种解法,同一条保证:留痕不能是"想写才写"的。';

CREATE INDEX idx_quote_history_quote ON public.quote_history (quote_id, changed_at DESC);

CREATE TRIGGER trg_quote_history_append_only
    BEFORE UPDATE OR DELETE ON public.quote_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_quote_history_append_only();

ALTER TABLE public.quote_history ENABLE ROW LEVEL SECURITY;

-- 留痕【没有 INSERT 策略】:唯一写入口是属主权限的触发器与函数
-- (同 approval_log / so_issues:档案不该有第二个写法)。
CREATE POLICY "quote_history select by permission" ON public.quote_history
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));
