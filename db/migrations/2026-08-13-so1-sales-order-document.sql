-- db/migrations/2026-08-13-so1-sales-order-document.sql
-- SO-1:销售订单【单据】—— 一张对客户的承诺,而不是一条事后的销售记录
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【今天缺的是什么】销售这一侧【没有单据】:record_output_sale 在产出批次页上
-- 事后记一笔,同一个事务里扣库存、记收入、记 COGS。也就是说系统里
-- 【"卖出去了"与"答应要卖"是同一件事】,而它们在业务上差着一整段时间。
-- 这一刀只补【单据】那一半:一张有编号、有客户、有明细、能签发出去的订单。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本刀【不】做的四件事,以及它们各自的落点 —— 写在会有人去加的那个位置】
--   * 预留(committed 库存桶):inventory_movements.stock_status 的注释里点名
--     等的就是这一刀落地("等销售单落地那一刀再加")。但【本刀不加】:
--     加一个没有写入者的枚举值,与当初拒绝它的理由一模一样。归 SO-1 的预留那一刀。
--   * 发货 / 履约状态:见 sales_orders.status 的注释 —— 状态机今天只到
--     draft/confirmed/closed/cancelled,fulfilment 那几个状态归发货那一刀。
--   * 发票关联:create_invoice 今天从 sales_records 组行,而销售记录只能由
--     record_output_sale 产生(它同事务扣库存)—— 于是【今天开不出一张先于发货的
--     发票】。Tim 把开票排在发货之前,那是一次真正的改动,归它自己那一刀。
--   * 合同条款(承诺价):pricing_term_commitments 的主体今天只有采购两列
--     (purchase_order_line_id / inbound_batch_id,XOR 二选一)。销售侧要用它,
--     要么加两列把 XOR 扩成四选一,要么改成 (subject_type, subject_id) 的多态
--     形状(approval_log / notifications 那一种)。那是一个决定,不是一次扩展。
--     本刀的行只带 FIN-26 的 price_source/price_provenance 配对,不带承诺。
--   * 改单(amendment):PUR-2 那套(可改性守卫 + 历史 + 重新签发)归 SO-1b。
--     本刀只做【确认即冻结】,冻结的守卫与编辑路径【同时出生】。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【权限:module.sales.* 不存在 —— 查过目录,不是假设】
-- 线上只有 module.output.* / module.customers.* / module.finance.* 与
-- data.view_sales。而【销售这条链今天是分开的】:
--     record_output_sale   要 module.output.edit(它长在产出批次页上)
--     sales_records 的 RLS 是 module.finance.view / .edit
--     create_invoice / attribute_sale_customer 要 module.finance.edit
-- 本刀按"跟着数据自己的策略走":销售订单四张表一律
-- module.finance.view / module.finance.edit —— 与 sales_records 同一对码。
-- 【这留下一个真实的分叉,交给 Tim】录入销售的人今天持的是 output.edit,
-- 而订单页要 finance.edit,两者不是同一群人。要么将来真的开一个 module.sales.*
-- (那是权限码 + 角色授权 + 模块条目三件事),要么把入口挪进财务。
-- 【不在这一刀里替他决定】,但也不假装它不存在。
--
-- 【FX:与采购单同一条(FIN-35)】fx_rate NOT NULL、无默认值 —— 汇率的默认值
-- 只能是一个假设,而假设出来的 1:1 在非本位币单据上永远是错的,还看起来正常。
-- 金额以【本单据自己的币种】记,不换算(FIN-28 的教训:列名带 usd 就是撒谎)。
--
-- 镜像:db/tables/{sales_orders,sales_order_lines,sales_order_history,so_issues}.sql、
--       db/functions/{next_sales_order_code,set_sales_order_status,record_so_issue,
--       guard_sales_order_confirmed_immutable,guard_sales_order_line_confirmed_immutable,
--       guard_sales_order_history_append_only,guard_so_issues_append_only}.sql。
-- 行为断言:fixture 63。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 单据头 ═════════════════════════════════════════════════════════════
CREATE TABLE public.sales_orders (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code          text NOT NULL UNIQUE,
    -- 【NOT NULL,与 sales_records 刻意不同】一条销售【记录】可以没有客户
    -- (货先卖了、客户还没登记,SAL-C 事后归属);但一张【订单】是"答应卖给某人"——
    -- 没有那个人,这张单据就没有主语。无客户的那条路仍然走直接销售,不走订单。
    customer_id   uuid NOT NULL REFERENCES public.customers (id),
    -- 【物理事件日,永不默认】(AGENTS.md 的日期规矩、FIN-32 同形):
    -- 补一个 CURRENT_DATE 会让"留空"比"填对"更容易通过。
    order_date    date NOT NULL,
    status        text NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft','confirmed','closed','cancelled')),
    currency      text NOT NULL REFERENCES public.currencies (code),
    fx_rate       numeric NOT NULL CHECK (fx_rate > 0),
    notes         text,
    terms_text    text,
    confirmed_at  timestamptz,
    closed_at     timestamptz,
    cancelled_at  timestamptz,
    cancel_reason text,
    deleted_at    timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid DEFAULT auth.uid(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid,
    -- 作废必须给理由(与采购单同形):一张没有理由的作废单,三个月后没有人
    -- 说得出它为什么作废。
    CONSTRAINT sales_orders_cancel_reason_required
        CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL)
);

COMMENT ON TABLE public.sales_orders IS
    'SO-1:销售订单单据头。【与 sales_records 是两件事】:订单是"答应卖给某人",销售记录是"已经卖了"(record_output_sale 同事务扣库存、记收入与 COGS)。customer_id NOT NULL —— 订单的主语就是那个客户;无客户的销售仍走直接销售那条路(SAL-C 的事后归属只对销售记录成立)。状态机今天只有 draft/confirmed/closed/cancelled:【履约/发货那几个状态归发货那一刀】,加在这里之前先读那一刀的注释。确认即冻结商业字段(guard_sales_order_confirmed_immutable),改单归 SO-1b。';

COMMENT ON COLUMN public.sales_orders.status IS
    'SO-1:单据状态。draft 可编辑;confirmed 之后商业字段冻结(按名拒 SO_CONFIRMED_IMMUTABLE|<字段>);closed 是这张单走完了;cancelled 必须带理由。【发货/履约状态不在这里】—— partially_shipped / shipped 之类要等发货那一刀,而那一刀要一并回答"部分发货怎么算"。在此之前不加空状态:一个没有写入者的状态会被读成"从来没发生过",而不是"系统还不知道"(与 stock_status 拒绝 committed 同一条)。';

COMMENT ON COLUMN public.sales_orders.fx_rate IS
    'SO-1:本单据成立时的折本位币汇率。【没有默认值,这是有意的 —— FIN-35】:汇率的默认值只能是一个假设,而假设出来的 1:1 在非本位币单据上永远是错的,还看起来完全正常。';

CREATE INDEX idx_sales_orders_customer ON public.sales_orders (customer_id, order_date DESC);
CREATE INDEX idx_sales_orders_status   ON public.sales_orders (status);

-- ═══ 2 · 单据行 ═════════════════════════════════════════════════════════════
CREATE TABLE public.sales_order_lines (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sales_order_id uuid NOT NULL REFERENCES public.sales_orders (id) ON DELETE CASCADE,
    line_no        integer NOT NULL CHECK (line_no >= 1),
    -- 【行指向物料,不指向批次】客户买的是"一种产品",不是"那一箱货"。
    -- 【履约(行 ↔ 批次,多对多)归预留/发货那一刀】—— 那时才需要回答
    -- "一行由哪几批货满足"。今天加一个批次外键,等于替那一刀先做了一个
    -- 一对一的决定,而它几乎肯定不是一对一。
    material_id    uuid NOT NULL REFERENCES public.materials (id),
    quantity       numeric NOT NULL CHECK (quantity > 0),
    unit_price     numeric NOT NULL CHECK (unit_price > 0),
    -- FIN-26 的形状:出处【记录,不推断】,而且成对出现或都不出现。
    price_source     text CHECK (price_source IN ('computed','manual')),
    price_provenance jsonb,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (sales_order_id, line_no),
    CONSTRAINT sales_order_lines_provenance_pairing CHECK (
        (price_source IS NULL AND price_provenance IS NULL)
        OR (price_source IS NOT NULL AND price_provenance IS NOT NULL)
    )
);

COMMENT ON TABLE public.sales_order_lines IS
    'SO-1:销售订单行。【指向物料,不指向批次】—— 客户买的是一种产品;"这一行由哪几批货满足"是【履约】,是多对多,归预留/发货那一刀(今天加一个批次外键就是替那一刀先做了一个几乎肯定错的一对一决定)。price_source/price_provenance 按 FIN-26 成对:出处记录、不事后推断,要么都有要么都没有(约束 sales_order_lines_provenance_pairing)。【承诺价不在这里】:pricing_term_commitments 的主体今天只有采购两列,销售侧要用它是一次形状决定(见本刀迁移抬头)。';

CREATE INDEX idx_sales_order_lines_order ON public.sales_order_lines (sales_order_id, line_no);

-- ═══ 3 · 历史(只增不改)════════════════════════════════════════════════════
CREATE TABLE public.sales_order_history (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sales_order_id uuid NOT NULL REFERENCES public.sales_orders (id),
    change_type    text NOT NULL CHECK (change_type IN
                   ('created','confirmed','closed','cancelled','line_added','line_changed','line_removed','issued')),
    detail         text,
    changed_at     timestamptz NOT NULL DEFAULT now(),
    changed_by     uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.sales_order_history IS
    'SO-1:销售订单的变更留痕,只增不改(形状取自 purchase_order_history)。守卫【自己报名】抛 SO_HISTORY_IMMUTABLE,不靠外键顺带挡(FIN-31)。';

CREATE INDEX idx_sales_order_history_order ON public.sales_order_history (sales_order_id, changed_at DESC);

CREATE OR REPLACE FUNCTION public.guard_sales_order_history_append_only()
 RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    RAISE EXCEPTION 'SO_HISTORY_IMMUTABLE';
END;
$function$;

CREATE TRIGGER trg_sales_order_history_append_only
    BEFORE UPDATE OR DELETE ON public.sales_order_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_order_history_append_only();

-- ═══ 4 · 签发档(逐字镜像 po_issues)════════════════════════════════════════
CREATE TABLE public.so_issues (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sales_order_id uuid NOT NULL REFERENCES public.sales_orders (id),
    -- 每张单自己的版本号,从 1 起。客户手里那份是【某个具体版本】——
    -- 重新签发产生新版本,旧版本原样留着。
    version        integer NOT NULL CHECK (version >= 1),
    file_path      text NOT NULL,
    sha256         text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at      timestamptz NOT NULL DEFAULT now(),
    issued_by      uuid,
    UNIQUE (sales_order_id, version)
);

COMMENT ON TABLE public.so_issues IS
    'SO-1:销售订单签发档(形状取自 po_issues),只增不改。谁、何时、第几版、哪个对象、字节摘要。【没有"已发送"标志】—— 系统不知道对方收没收到,而一个永远为 false 的标志会被读成"没发出去"。唯一写入口 record_so_issue();重新签发 = 新的一行,绝不覆盖旧行 —— 客户手里那份是某个具体版本。';

CREATE INDEX idx_so_issues_order ON public.so_issues (sales_order_id, version DESC);

CREATE OR REPLACE FUNCTION public.guard_so_issues_append_only()
 RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    RAISE EXCEPTION 'SO_ISSUE_IMMUTABLE';
END;
$function$;

CREATE TRIGGER trg_so_issues_append_only
    BEFORE UPDATE OR DELETE ON public.so_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_so_issues_append_only();

-- ═══ 5 · 编号(与采购单同一条:年内连号,advisory lock 串行化)═══════════════
CREATE OR REPLACE FUNCTION public.next_sales_order_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('sales_order_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM sales_orders
    WHERE code LIKE 'SO-' || v_year::text || '-%';
    RETURN 'SO-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ═══ 6 · 确认即冻结 —— 守卫与编辑路径【同时出生】══════════════════════════
-- 【为什么是一张字段表而不是"确认后整行只读"】(PUR-2 的形状)
-- 冻结的是【商业内容】:客户、币种、汇率、订单日、编号。备注与条款正文不冻结 ——
-- 它们不改变这笔交易是什么。状态列自己有转换函数,不走编辑这条路;
-- 放行的判据是【调用方有没有自己动它】,靠上下文标记,与 po_status_ctx 同一惯用法。
CREATE OR REPLACE FUNCTION public.guard_sales_order_confirmed_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- draft 随便改;作废/关闭之后也不该再改商业字段
    IF OLD.status = 'draft' THEN
        -- 状态列仍然只走转换函数
        IF current_setting('evoltrya.so_status_ctx', true) IS DISTINCT FROM '1'
           AND NEW.status IS DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION 'SO_STATUS_NOT_EDITABLE|%|%', OLD.status, NEW.status;
        END IF;
        RETURN NEW;
    END IF;

    IF current_setting('evoltrya.so_status_ctx', true) = '1' THEN
        RETURN NEW;   -- 转换函数自己在动状态列
    END IF;

    IF NEW.customer_id IS DISTINCT FROM OLD.customer_id THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|customer_id|%', OLD.code;
    END IF;
    IF NEW.currency IS DISTINCT FROM OLD.currency THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|currency|%', OLD.code;
    END IF;
    IF NEW.fx_rate IS DISTINCT FROM OLD.fx_rate THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|fx_rate|%', OLD.code;
    END IF;
    IF NEW.order_date IS DISTINCT FROM OLD.order_date THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|order_date|%', OLD.code;
    END IF;
    IF NEW.code IS DISTINCT FROM OLD.code THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|code|%', OLD.code;
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        RAISE EXCEPTION 'SO_STATUS_NOT_EDITABLE|%|%', OLD.status, NEW.status;
    END IF;

    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_sales_orders_confirmed_immutable
    BEFORE UPDATE ON public.sales_orders
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_order_confirmed_immutable();

-- 行:确认之后既不能改、也不能增删(那是改单,归 SO-1b)
CREATE OR REPLACE FUNCTION public.guard_sales_order_line_confirmed_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order sales_orders%ROWTYPE;
BEGIN
    SELECT * INTO v_order FROM sales_orders
     WHERE id = COALESCE(NEW.sales_order_id, OLD.sales_order_id);

    IF v_order.status = 'draft' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|lines|%', v_order.code;
END;
$function$;

CREATE TRIGGER trg_sales_order_lines_confirmed_immutable
    BEFORE INSERT OR UPDATE OR DELETE ON public.sales_order_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_order_line_confirmed_immutable();

-- ═══ 7 · 状态转换:每个状态各自写清楚允许去哪 ═══════════════════════════════
-- 【不是一句"除了 X 都行"】—— 一条按排除写的规则,读的人永远不知道它到底允许
-- 什么;而且新增一个状态时,排除式默认把它放行。所以逐个状态列出去处。
CREATE OR REPLACE FUNCTION public.set_sales_order_status(p_order_id uuid, p_to text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order sales_orders%ROWTYPE;
    v_cust  record;
    v_ok    boolean;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_order FROM sales_orders WHERE id = p_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_order_id::text, '?');
    END IF;

    -- 【允许的去处,逐个状态写出来】
    v_ok := CASE v_order.status
        WHEN 'draft'     THEN p_to IN ('confirmed','cancelled')
        WHEN 'confirmed' THEN p_to IN ('closed','cancelled')
        WHEN 'closed'    THEN false      -- 终态
        WHEN 'cancelled' THEN false      -- 终态
        ELSE false
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'SO_TRANSITION_NOT_ALLOWED|%|%', v_order.status, p_to;
    END IF;

    IF p_to = 'cancelled' AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
        RAISE EXCEPTION 'SO_CANCEL_REASON_REQUIRED|%', v_order.code;
    END IF;

    -- 【确认要看客户的信用冻结】一张确认了的订单是一个承诺;对一个被冻结的
    -- 客户做承诺,与 record_output_sale 拒绝给他发货是同一条判断,只是早一步。
    -- 【只看 credit_hold,不看额度】额度是随敞口变的,而订单还没产生敞口 ——
    -- 拿一个将来的数去拒绝一张今天的单,会把"可能超限"演成"已经超限"。
    IF p_to = 'confirmed' THEN
        SELECT credit_hold, code INTO v_cust FROM customers WHERE id = v_order.customer_id;
        IF v_cust.credit_hold THEN
            RAISE EXCEPTION 'SO_CUSTOMER_ON_HOLD|%', v_cust.code;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM sales_order_lines WHERE sales_order_id = p_order_id) THEN
            RAISE EXCEPTION 'SO_NO_LINES|%', v_order.code;
        END IF;
    END IF;

    -- 上下文标记:让冻结守卫知道是【转换函数】在动状态列(同 po_status_ctx)
    PERFORM set_config('evoltrya.so_status_ctx', '1', true);
    UPDATE sales_orders
       SET status       = p_to,
           confirmed_at = CASE WHEN p_to = 'confirmed' THEN now() ELSE confirmed_at END,
           closed_at    = CASE WHEN p_to = 'closed'    THEN now() ELSE closed_at END,
           cancelled_at = CASE WHEN p_to = 'cancelled' THEN now() ELSE cancelled_at END,
           cancel_reason= CASE WHEN p_to = 'cancelled' THEN p_reason ELSE cancel_reason END,
           updated_at   = now(),
           updated_by   = auth.uid()
     WHERE id = p_order_id;
    PERFORM set_config('evoltrya.so_status_ctx', '', true);

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (p_order_id, p_to, p_reason);

    RETURN jsonb_build_object('id', p_order_id, 'status', p_to);
END;
$function$;

-- ═══ 8 · 签发:唯一写入口 ═══════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.record_so_issue(p_order_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order sales_orders%ROWTYPE;
    v_next  integer;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_order FROM sales_orders WHERE id = p_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_order_id::text, '?');
    END IF;
    -- 草稿不签发:签发出去的是一份对外承诺,而草稿还不是承诺。
    IF v_order.status = 'draft' THEN
        RAISE EXCEPTION 'SO_NOT_ISSUABLE|%|%', v_order.code, v_order.status;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('so_issue_' || p_order_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next FROM so_issues WHERE sales_order_id = p_order_id;

    INSERT INTO so_issues (sales_order_id, version, file_path, sha256, issued_by)
    VALUES (p_order_id, v_next, p_file_path, p_sha256, auth.uid());

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (p_order_id, 'issued', 'v' || v_next::text);

    RETURN jsonb_build_object('version', v_next);
END;
$function$;

-- ═══ 9 · RLS —— 跟着 sales_records 自己的那一对码 ═══════════════════════════
ALTER TABLE public.sales_orders        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_lines   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.so_issues           ENABLE ROW LEVEL SECURITY;

CREATE POLICY "sales_orders select by permission" ON public.sales_orders
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));
CREATE POLICY "sales_orders insert by permission" ON public.sales_orders
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.finance.edit'::text));
CREATE POLICY "sales_orders update by permission" ON public.sales_orders
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "sales_order_lines select by permission" ON public.sales_order_lines
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));
CREATE POLICY "sales_order_lines insert by permission" ON public.sales_order_lines
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.finance.edit'::text));
CREATE POLICY "sales_order_lines update by permission" ON public.sales_order_lines
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));
CREATE POLICY "sales_order_lines delete by permission" ON public.sales_order_lines
    AS PERMISSIVE FOR DELETE TO authenticated USING (has_permission('module.finance.edit'::text));

-- 留痕与签发档【没有 INSERT 策略】:唯一写入口是属主权限的函数
-- (同 approval_log / notifications:留痕不该有第二个写法)。
CREATE POLICY "sales_order_history select by permission" ON public.sales_order_history
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));
CREATE POLICY "so_issues select by permission" ON public.so_issues
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));

COMMIT;
