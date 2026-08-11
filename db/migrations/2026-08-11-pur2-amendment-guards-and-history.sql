-- PUR-2 第一部分(2026-08-11):采购单修改的【守卫】与【留痕】
--
-- Doc 1 点名 "PO change management(quantity/price changes audited, versioned)",
-- 至今没有修改入口:填错了只能作废重开。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【调查先于设计,而调查把这一刀的形状换了】
-- 原以为要"审慎地放宽某些冻结"。实际查下来:**几乎什么都没被冻结**。
--   * purchase_orders 只有两个触发器:updated_at,与 APR-2 的作废审批;
--     RLS 允许任何持 module.purchasing.edit 的人 UPDATE。
--   * purchase_order_lines **一个触发器都没有**,连 updated_at 都没有;RLS 同样放行。
-- 也就是说"只能作废重开"不是系统在执行的规则,而是**应用里没有那个按钮**
-- (actions.ts 只导出 cancel/close/reopen 三个)。
--
-- **于是这一刀的实质不是"放宽守卫",而是"给一片本来就没上锁的面"补上锁**:
-- 商业字段从来只是【够不着】,不是【被保护】。而 PostgREST 那条路今天就通 ——
-- 只要有人直接对表发一个 UPDATE。所以守卫必须与入口【同一刀】写完,
-- 否则加了按钮等于把下面每一条约束一次性变成可达。
--
-- 【两层,是有意的】
--   * 身份字段与已收下限 → **触发器**:它们必须挡得住那条直连的 PostgREST UPDATE;
--   * 付款计划与状态判断 → **RPC 里**:它们要看见整次修改,而触发器只看得见一行。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1 · 留痕表(pricing_formula_history 的形状)──────────────────────────────
CREATE TABLE public.purchase_order_history (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_order_id uuid NOT NULL REFERENCES public.purchase_orders (id),
    -- 明细行的改动也进本表。【为什么不能只记表头】pricing_formula_history 的抬头
    -- 已经写过这条教训:界面表达"这一行不要了"的方式是【DELETE 掉它】,
    -- 只记表头的历史对最激烈的一种编辑一言不发,而沉默读起来正好等于"什么都没改"。
    purchase_order_line_id uuid,      -- 行改动才有;删行时这个 id 已经不存在,故无外键
    line_no           integer,
    change_type       text NOT NULL CHECK (change_type IN
                      ('header_update','line_update','line_add','line_remove')),
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

-- ── 2 · 守卫:身份字段 + 状态旁门 ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_po_amendable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【改了就是另一笔交易 —— 重开一张,不是改这一张】
    -- 供应商:应付、预付、签发档全挂在这笔交易上,换人等于把它们悄悄重指。
    -- 币种:fx_rate 锚在 order_date 的 tt_sell 上,而付款计划的定额腿是按【那个】
    --       币种谈的(FIN-29 明确拒绝换币种的单)—— 换币种把整个金额框架作废。
    IF NEW.supplier_id IS DISTINCT FROM OLD.supplier_id THEN
        RAISE EXCEPTION 'PO_FIELD_IMMUTABLE|supplier_id|%', OLD.code;
    END IF;
    IF NEW.currency IS DISTINCT FROM OLD.currency THEN
        RAISE EXCEPTION 'PO_FIELD_IMMUTABLE|currency|%', OLD.code;
    END IF;
    IF NEW.code IS DISTINCT FROM OLD.code THEN
        RAISE EXCEPTION 'PO_FIELD_IMMUTABLE|code|%', OLD.code;
    END IF;

    -- 【状态与审批状态不走"修改"这条路】它们各有自己的转换
    -- (cancel/close/reopen、审批函数)。一个能把 approval_status 设成 approved 的
    -- 编辑表单,就是一条不经审批的审批路径。
    -- 【但要放行那三个转换本身】—— 它们改的正是这两列,靠上下文标记区分,
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法。
    IF current_setting('evoltrya.po_status_ctx', true) IS DISTINCT FROM '1' THEN
        IF NEW.status IS DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION 'PO_STATUS_NOT_AMENDABLE|status|%|%', OLD.status, NEW.status;
        END IF;
        -- APR-2 的作废触发器【也】改 approval_status。它是 BEFORE UPDATE、
        -- 与本守卫同级,执行顺序按名字排:guard_(g) 在 trg_(t) 之前,
        -- 于是本守卫看到的是【还没被作废触发器改过的】值 —— 放行的判据因此是
        -- "调用方有没有自己动它",而不是"最终值是不是变了"。
        IF NEW.approval_status IS DISTINCT FROM OLD.approval_status THEN
            RAISE EXCEPTION 'PO_STATUS_NOT_AMENDABLE|approval_status|%|%',
                OLD.approval_status, NEW.approval_status;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

CREATE TRIGGER guard_purchase_orders_amendable
    BEFORE UPDATE ON public.purchase_orders
    FOR EACH ROW EXECUTE FUNCTION public.guard_po_amendable();

-- ── 3 · 守卫:已收下限 ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_po_line_received_floor()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_received numeric;
    v_line record;
BEGIN
    v_line := CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;

    SELECT COALESCE(SUM(ib.quantity), 0) INTO v_received
    FROM inbound_batches ib
    WHERE ib.purchase_order_line_id = v_line.id AND ib.deleted_at IS NULL;

    IF TG_OP = 'DELETE' THEN
        -- 收过货的行不能删:那批货真的到了,单据上却没有它的出处
        IF v_received > 0 THEN
            RAISE EXCEPTION 'PO_LINE_HAS_RECEIPTS|%|%', OLD.line_no, v_received;
        END IF;
        RETURN OLD;
    END IF;

    -- 【下限是"已收",不是"零"】把订量砍到已收之下,等于让单据宣称我们订的
    -- 比实际到的还少 —— 而货已经在院子里了。等于已收是允许的(边界在内)。
    IF NEW.quantity < v_received THEN
        RAISE EXCEPTION 'PO_LINE_BELOW_RECEIVED|%|%|%', NEW.line_no, v_received, NEW.quantity;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER guard_po_lines_received_floor
    BEFORE UPDATE OR DELETE ON public.purchase_order_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_po_line_received_floor();

-- ── 4 · 留痕触发器:表头与明细各一 ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_po_history_header()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 只记【商业字段】的改动:updated_at/updated_by 的变化不是编辑史。
    -- 状态转换(cancel/close/reopen)也不记 —— 它们有自己的记录路径,
    -- 记进来会让编辑史被状态噪音淹掉。
    IF NEW.order_date IS NOT DISTINCT FROM OLD.order_date
       AND NEW.expected_delivery_date IS NOT DISTINCT FROM OLD.expected_delivery_date
       AND NEW.fx_rate IS NOT DISTINCT FROM OLD.fx_rate
       AND NEW.estimated_total_ccy IS NOT DISTINCT FROM OLD.estimated_total_ccy
       AND NEW.incoterm IS NOT DISTINCT FROM OLD.incoterm
       AND NEW.terms_text IS NOT DISTINCT FROM OLD.terms_text
       AND NEW.notes IS NOT DISTINCT FROM OLD.notes THEN
        RETURN NEW;
    END IF;

    INSERT INTO purchase_order_history (
        purchase_order_id, change_type,
        old_order_date, new_order_date,
        old_expected_delivery_date, new_expected_delivery_date,
        old_fx_rate, new_fx_rate,
        old_estimated_total_ccy, new_estimated_total_ccy,
        old_incoterm, new_incoterm, old_terms_text, new_terms_text,
        old_notes, new_notes, amend_reason)
    VALUES (NEW.id, 'header_update',
        OLD.order_date, NEW.order_date,
        OLD.expected_delivery_date, NEW.expected_delivery_date,
        OLD.fx_rate, NEW.fx_rate,
        OLD.estimated_total_ccy, NEW.estimated_total_ccy,
        OLD.incoterm, NEW.incoterm, OLD.terms_text, NEW.terms_text,
        OLD.notes, NEW.notes,
        NULLIF(current_setting('evoltrya.amend_reason', true), ''));
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_purchase_orders_history
    AFTER UPDATE ON public.purchase_orders
    FOR EACH ROW EXECUTE FUNCTION public.trg_po_history_header();

CREATE OR REPLACE FUNCTION public.trg_po_history_line()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_reason text := NULLIF(current_setting('evoltrya.amend_reason', true), '');
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- 【建单时的那一批行不记】否则每张新单都会先长出一份"全是新增"的历史,
        -- 把真正的修改埋掉。建单本身有 approval_log 的 auto_approved / submitted。
        IF current_setting('evoltrya.po_amend_ctx', true) IS DISTINCT FROM '1' THEN
            RETURN NEW;
        END IF;
        INSERT INTO purchase_order_history (purchase_order_id, purchase_order_line_id,
            line_no, change_type, new_quantity, new_unit,
            new_estimated_unit_price, new_estimated_amount_ccy, amend_reason)
        VALUES (NEW.purchase_order_id, NEW.id, NEW.line_no, 'line_add',
            NEW.quantity, NEW.unit, NEW.estimated_unit_price, NEW.estimated_amount_ccy, v_reason);
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO purchase_order_history (purchase_order_id, purchase_order_line_id,
            line_no, change_type, old_quantity, old_unit,
            old_estimated_unit_price, old_estimated_amount_ccy, amend_reason)
        VALUES (OLD.purchase_order_id, OLD.id, OLD.line_no, 'line_remove',
            OLD.quantity, OLD.unit, OLD.estimated_unit_price, OLD.estimated_amount_ccy, v_reason);
        RETURN OLD;
    END IF;

    IF NEW.quantity IS NOT DISTINCT FROM OLD.quantity
       AND NEW.unit IS NOT DISTINCT FROM OLD.unit
       AND NEW.estimated_unit_price IS NOT DISTINCT FROM OLD.estimated_unit_price
       AND NEW.estimated_amount_ccy IS NOT DISTINCT FROM OLD.estimated_amount_ccy THEN
        RETURN NEW;
    END IF;
    INSERT INTO purchase_order_history (purchase_order_id, purchase_order_line_id,
        line_no, change_type,
        old_quantity, new_quantity, old_unit, new_unit,
        old_estimated_unit_price, new_estimated_unit_price,
        old_estimated_amount_ccy, new_estimated_amount_ccy, amend_reason)
    VALUES (NEW.purchase_order_id, NEW.id, NEW.line_no, 'line_update',
        OLD.quantity, NEW.quantity, OLD.unit, NEW.unit,
        OLD.estimated_unit_price, NEW.estimated_unit_price,
        OLD.estimated_amount_ccy, NEW.estimated_amount_ccy, v_reason);
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_purchase_order_lines_history
    AFTER INSERT OR UPDATE OR DELETE ON public.purchase_order_lines
    FOR EACH ROW EXECUTE FUNCTION public.trg_po_history_line();

COMMIT;
