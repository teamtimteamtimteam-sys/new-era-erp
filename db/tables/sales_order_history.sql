-- db/tables/sales_order_history.sql
-- SO-1:销售订单变更留痕,只增不改(形状取自 purchase_order_history)。
--
-- NOTE: introduced by db/migrations/2026-08-13-so1-sales-order-document.sql.
-- First-run script (plain CREATEs).

-- ═══ 3 · 历史(只增不改)════════════════════════════════════════════════════
CREATE TABLE public.sales_order_history (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sales_order_id uuid NOT NULL REFERENCES public.sales_orders (id),
    -- SO-2:'reserved' / 'released' —— 预留与释放【留在订单的历史里】,而不是
    -- 只留在库存流水里。看订单的人问的是"这张单许出去了什么、什么时候放回去的",
    -- 那个问题的答案不该要求他先去翻库存台账。
    change_type    text NOT NULL CHECK (change_type IN
                   ('created','confirmed','closed','cancelled','line_added','line_changed','line_removed','issued',
                    'reserved','released',
                    -- SO-3a:开票与发票作废也进订单的历史 —— 订单流要求先开票后发货,
                    -- "这张单开过票没有"是看订单的人的问题,不该要他去翻发票列表。
                    'invoiced','invoice_voided',
                    -- SO-3b:发货也进订单历史 —— "这张单发了什么、什么时候发的"
                    -- 是看订单的人的问题,不该要他去翻发货单列表。
                    'shipped',
                    -- SO-1b:改单的四种,由【触发器】写(trg_so_history_header /
                    -- trg_so_history_line),而且只在改单上下文里写。
                    -- 【与上面的 line_added/line_changed/line_removed 并存,不是换名】
                    -- 那三个是 SO-1 定下的、至今没有任何写入者的空位;这四个带着
                    -- 成对的 old_/new_ 与理由。合并会让"这一行是怎么来的"从两个
                    -- 不同的机制变成一个含混的名字。
                    'header_update','line_update','line_add','line_remove')),
    detail         text,
    changed_at     timestamptz NOT NULL DEFAULT now(),
    changed_by     uuid DEFAULT auth.uid(),
    -- ═══ SO-1b:改单留痕的机器可读一半 ═══════════════════════════════════════
    -- (ALTER 加的列按活库序排在最后 —— 见 AGENTS.md 的镜像规矩)
    -- 【为什么是成对的列,而不是一段 jsonb 或一句人话】与 purchase_order_history
    -- 同一条:机器读得懂的历史才查得了、比得了、做得出"这一版与上一版差在哪";
    -- 一句 '数量 12 → 10' 只有人眼读得了。
    sales_order_line_id uuid,      -- 行改动才有;【没有外键】见列注释
    line_no             integer,
    -- 表头侧【只有两列】—— 因为确认之后可改的只有这两列(其余永久冻结)
    old_notes           text,
    new_notes           text,
    old_terms_text      text,
    new_terms_text      text,
    -- 明细侧
    old_quantity        numeric,
    new_quantity        numeric,
    old_unit_price      numeric,
    new_unit_price      numeric,
    amend_reason        text
);

COMMENT ON TABLE public.sales_order_history IS
    'SO-1:销售订单的变更留痕,只增不改(形状取自 purchase_order_history)。守卫【自己报名】抛 SO_HISTORY_IMMUTABLE,不靠外键顺带挡(FIN-31)。SO-1b:改单史与事件史【同表】—— header_update/line_update/line_add/line_remove 由触发器在改单上下文里写,带成对的 old_/new_ 与理由;草稿的编辑不设那个上下文,所以不进本表。';

COMMENT ON COLUMN public.sales_order_history.amend_reason IS
    'SO-1b:这次改动的理由。由 amend_sales_order 经 set_config(''evoltrya.so_amend_reason'') 递给触发器 —— 触发器读不到函数参数。【草稿的编辑没有理由,也没有本表的行】:草稿还不是承诺,给它要一句解释是在给一件还没发生的事做记录。';

COMMENT ON COLUMN public.sales_order_history.sales_order_line_id IS
    'SO-1b:行改动指向的那一行。【没有外键,这是有意的】—— line_remove 那一行写下的时候,它指向的行正在被删掉。历史要记得住一个已经不存在的东西,否则最激烈的一种编辑(把这一行整个拿掉)会在历史里一言不发,而沉默读起来正好等于"什么都没改"。';

CREATE INDEX idx_sales_order_history_order ON public.sales_order_history (sales_order_id, changed_at DESC);

CREATE TRIGGER trg_sales_order_history_append_only
    BEFORE UPDATE OR DELETE ON public.sales_order_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_order_history_append_only();

ALTER TABLE public.sales_order_history ENABLE ROW LEVEL SECURITY;

-- 留痕与签发档【没有 INSERT 策略】:唯一写入口是属主权限的函数
-- (同 approval_log / notifications:留痕不该有第二个写法)。
CREATE POLICY "sales_order_history select by permission" ON public.sales_order_history
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));
