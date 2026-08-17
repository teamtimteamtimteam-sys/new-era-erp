-- db/tables/purchase_order_history.sql
-- 采购单的只增不改编辑史(PUR-2,pricing_formula_history 的形状)。
--
-- NOTE: introduced by db/migrations/2026-08-11-pur2-amendment-guards-and-history.sql.
-- First-run script (plain CREATEs).
--
-- 【表头与明细同表】界面表达"这一行不要了"的方式是【删掉它】,只记表头的历史
-- 对最激烈的一种编辑一言不发,而沉默读起来正好等于"什么都没改"。
-- 【触发器写,不由应用写】应用侧留痕是"想写才写"的;触发器接得住每一条路径,
-- 包括直接连库改的那次 —— 而 PUR-2 的调查结论正是"那条路今天就通"。
-- 【与 approval_log 不重复】那张答"谁批了什么金额",这张答"这张单当时说的是什么"。

CREATE TABLE public.purchase_order_history (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_order_id uuid NOT NULL REFERENCES public.purchase_orders (id),
    -- 明细行的改动也进本表。【为什么不能只记表头】pricing_formula_history 的抬头
    -- 已经写过这条教训:界面表达"这一行不要了"的方式是【DELETE 掉它】,
    -- 只记表头的历史对最激烈的一种编辑一言不发,而沉默读起来正好等于"什么都没改"。
    purchase_order_line_id uuid,      -- 行改动才有;删行时这个 id 已经不存在,故无外键
    line_no           integer,
    change_type       text NOT NULL CHECK (change_type IN
                      ('header_update','line_update','line_add','line_remove','cancelled')),
    -- 表头侧
    old_order_date    date,          new_order_date    date,
    old_expected_delivery_date date,  new_expected_delivery_date date,
    old_fx_rate       numeric,       new_fx_rate       numeric,
    old_estimated_total_ccy numeric, new_estimated_total_ccy numeric,
    old_incoterm      text,          new_incoterm      text,
    old_terms_text    text,          new_terms_text    text,
    old_notes         text,          new_notes         text,
    -- 明细侧
    old_quantity      numeric,       new_quantity      numeric,
    old_unit          text,          new_unit          text,
    old_estimated_unit_price numeric, new_estimated_unit_price numeric,
    old_estimated_amount_ccy numeric, new_estimated_amount_ccy numeric,
    -- 改动的理由:由 RPC 经 set_config 传进来(触发器读不到函数参数)
    amend_reason      text,
    changed_at        timestamptz NOT NULL DEFAULT now(),
    changed_by        uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.purchase_order_history IS
    'PUR-2:采购单的只增不改编辑史(pricing_formula_history 的形状)。表头与明细【同表】—— 界面表达"这一行不要了"的方式是删掉它,只记表头会对最激烈的编辑一言不发。由触发器写,不由应用写:应用侧留痕是"想写才写"的,而触发器接得住每一条路径,包括直接连库改的那次。与 approval_log 不重复 —— 那张答"谁批了什么金额",这张答"这张单当时说的是什么"。';

CREATE INDEX idx_po_history_po ON public.purchase_order_history (purchase_order_id, changed_at DESC);

ALTER TABLE public.purchase_order_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "po_history select by permission"
    ON public.purchase_order_history AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text));
-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是触发器(属主权限)——
-- 与 approval_log / po_issues 同一条:档案不该有第二个写法。

CREATE OR REPLACE FUNCTION public.guard_po_history_append_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'PO_HISTORY_APPEND_ONLY|%', TG_OP;
END;
$function$;

CREATE TRIGGER trg_po_history_append_only
    BEFORE UPDATE OR DELETE ON public.purchase_order_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_po_history_append_only();
