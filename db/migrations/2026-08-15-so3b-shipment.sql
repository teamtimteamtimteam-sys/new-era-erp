-- db/migrations/2026-08-15-so3b-shipment.sql
-- SO-3b:发货 —— 选项 C 的第二半:合同负债换成收入,货离开台账
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这一刀合上的那条链】3a 让开票过账(借 1100 应收 / 贷 2500 合同负债);
-- 这一刀让发货过账(借 2500 / 贷 4000 收入)外加与直接销售逐字同形的 COGS。
-- 一张单全部发完之后,2500 精确归零 —— 那不是一句设计意图,是 fixture 68 的
-- 资产负债表臂在非 1 汇率上断言出来的。
--
-- 【应收只创建一次 —— 3a 停放的那句话在这里兑现】发货产生的销售记录带着
-- sales_order_line_id 标记,而 ar_open_items 的第一支与
-- customer_ar_exposure_base 的第一项【都显式排除它】。少了这条谓词,同一笔钱
-- 会在账龄与敞口里各被数两遍(一次以发票的身份、一次以销售记录的身份),
-- 而两次都"看起来对"。
--
-- 【发货这一步不查信用,而这是一个决定】债在【开票】当刻就被认下并查过额度了
-- (create_order_invoice 的 CREDIT_LIMIT_EXCEEDED)。到发货时再查一次,等于
-- 拿一个已经承诺过的数去挡一次履约 —— 客户会看到"你已经答应卖给我了,现在
-- 又不发货"。直接销售那条路【一个字没动】,它的信用闸照常在 record_output_sale
-- 里(两个方向都由 fixture 68 断言:标记路径不查,直接销售仍拒)。
--
-- 【定址消耗 vs 策略排空】预留【就是地址】(哪一批、哪个库位、多少),所以
-- ship_order 直接写那一条 'sale' 出库腿,不走 drain_stock。drain_stock 仍是
-- 【没有地址】那三条路(直接销售、投料、注销)的策略排空器 —— 两边的函数头
-- 互相指着对方,免得下一个人以为这里漏用了它。
--
-- 【部分发货 = 先拆预留,再整条消耗】拆分只有一处实现:release_reservation 的
-- "整笔释放 + 就地重新预留剩余"。要发 q(< 预留 r)时,先把 (r − q) 放回
-- available,剩下那条新预留正好是 q,再整条消耗。【为什么不直接取走 q】那会让
-- "committed 桶 = Σ 活预留"不再成立(剩余那份还在桶里却没有主人),而
-- create_stock_transfer 的整桶搬正是靠这条不变量。
--
-- 【预留的第二种终局】释放(货回 available,有反向流水)与消耗(货离开台账,
-- 没有反向流水)是【两个不同的事实】,所以是两组列而不是共用那三列 ——
-- release_pair_id 那条 CHECK 本来也不允许一次"没有反向流水的释放"。
-- 活预留的判据因此变成两个条件,全库七处同步(五个函数 + 两个部分索引)。
--
-- 【订单状态是现算的】partially_shipped / shipped 由 ship_order 按"已发 vs 已订"
-- 算出来后经 so_status_ctx 写入,不在 set_sales_order_status 的允许表右边 ——
-- 那张表只管人能点的那些。同时 confirmed → closed 那条路【关掉了】:
-- 一张还没发货的订单"走完了"说不通。发出去的货收不回来,所以
-- partially_shipped 没有任何手动去处,更正走贷项凭证。
--
-- 【3a 停放的 INVOICE_SHIPPED_NOT_VOIDABLE 在这一刀落地】判据是派生的:
-- 这张发票的行上有没有发出去过的货。
--
-- 【破窗】本迁移不撤策略、不删列,新列全部可空或带默认;旧应用的每一条读写
-- 路径原样可用。破窗内容 = 新功能缺席,不是坏。
--
-- 镜像:db/tables/{shipments,shipment_lines,shipment_issues(新),sales_orders,
--       sales_order_reservations,sales_order_history,sales_records,journal_entries}.sql、
--       db/views/{ar_open_items,sales_records_masked}.sql、
--       db/functions/{ship_order,next_shipment_code,record_shipment_issue,
--       guard_shipment_append_only(新),guard_sales_order_reservation_append_only,
--       set_sales_order_status,void_invoice,create_stock_transfer,reserve_stock,
--       release_reservation,customer_ar_exposure_base,drain_stock(仅注释),
--       inventory_ledger_triggers}.sql。
-- 行为断言:fixture 68。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 枚举加宽 ═══════════════════════════════════════════════════════════
ALTER TABLE public.journal_entries DROP CONSTRAINT journal_entries_source_type_check;
ALTER TABLE public.journal_entries ADD CONSTRAINT journal_entries_source_type_check
    CHECK (source_type IN ('manual','purchase','sale','processing_cost','allocation','stocktake','writeoff','payment','fx','expense','prepayment','payroll','transfer','revaluation','depreciation','asset_disposal','year_close','freight','invoice','shipment'));

ALTER TABLE public.sales_orders DROP CONSTRAINT sales_orders_status_check;
ALTER TABLE public.sales_orders ADD CONSTRAINT sales_orders_status_check
    CHECK (status IN ('draft','confirmed','partially_shipped','shipped','closed','cancelled'));

ALTER TABLE public.sales_order_history DROP CONSTRAINT sales_order_history_change_type_check;
ALTER TABLE public.sales_order_history ADD CONSTRAINT sales_order_history_change_type_check
    CHECK (change_type IN ('created','confirmed','closed','cancelled',
                           'line_added','line_changed','line_removed','issued',
                           'reserved','released','invoiced','invoice_voided','shipped'));

-- ═══ 2 · 发货三表(守卫函数先建 —— 建表时的 CREATE TRIGGER 要它已经在)═══
-- 【重建那一侧的顺序不同,也仍然成立】replay 是 functions → tables → views,
-- 所以镜像里守卫住在 db/functions/ 而三张表住在 db/tables/,天然满足;
-- 只有【这一支迁移】要自己把它排在前面。
CREATE OR REPLACE FUNCTION public.guard_shipment_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 发货单、发货行、送货单签发档共用这一条:只增不改。
    -- 【为什么没有"作废"】货发出去了就是发出去了 —— 2500 已经释放进 4000、
    -- 库存已经离开台账。改一张发货单等于把一件发生过的物理事件改写成另一件;
    -- 更正走【贷项凭证】(credit note,sales_records 表头停放的未来概念)。
    RAISE EXCEPTION 'SHIPMENT_IMMUTABLE|%', TG_OP;
END;
$function$;

-- ── 三张表 ──════════════════════════════════════════════════════════
CREATE SEQUENCE public.shipment_code_seq;

CREATE TABLE public.shipments (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code           text NOT NULL UNIQUE,   -- 'SHP-YYYY-NNNN',无缝,自己的咨询锁
    sales_order_id uuid NOT NULL REFERENCES public.sales_orders (id),
    -- 【物理事件日,永不默认】货是哪天离开仓库的。补一个 CURRENT_DATE 会让
    -- "留空"比"填对"更容易通过,而这个日期同时决定收入落进哪个会计期间
    -- (AGENTS.md 的日期规矩;FIN-10 那一族的命名)。
    ship_date      date NOT NULL,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.shipments IS
    'SO-3b:发货单头(选项 C 的第二半)。一张发货单属于一张订单;每一行都必须坐在一张【在册且已过账】的订单流发票上 —— 那是一条派生检查(查 invoice_lines/invoices),不是订单上的状态位,因为状态位会与真相漂开。【不可作废、没有冲销】:货发出去了、负债已释放进收入、库存已离开台账,更正走贷项凭证(sales_records 表头停放的未来概念)。ship_date 是物理事件日,必填、永不默认 —— 它同时决定收入落进哪个会计期间。';

CREATE INDEX idx_shipments_order ON public.shipments (sales_order_id, ship_date);

-- 只增不改(函数在 db/functions/guard_shipment_append_only.sql)
CREATE TRIGGER trg_shipments_append_only
    BEFORE UPDATE OR DELETE ON public.shipments
    FOR EACH ROW EXECUTE FUNCTION public.guard_shipment_append_only();

ALTER TABLE public.shipments ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT / UPDATE / DELETE 策略,这是前提而不是遗漏】唯一写入口是
-- ship_order(DEFINER,module.sales.edit)。留一条客户端能直插的路,等于让人
-- 写出一张【没有对应流水、没有对应分录】的发货单 —— 而这张表存在的意义就是
-- 它与那两样说的是同一件事(建批次 IOD-1b / 建单 SO-2b 的同一条)。
CREATE POLICY "shipments select by permission" ON public.shipments
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.sales.view'::text));

CREATE TABLE public.shipment_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    shipment_id         uuid NOT NULL REFERENCES public.shipments (id) ON DELETE RESTRICT,
    sales_order_line_id uuid NOT NULL REFERENCES public.sales_order_lines (id),
    -- 被消耗掉的那条预留。UNIQUE:一条预留只能被发一次 —— 没有它,同一份
    -- committed 的货可以被两张发货单各取走一遍,而桶只会在提交时才炸。
    reservation_id      uuid NOT NULL UNIQUE REFERENCES public.sales_order_reservations (id),
    -- 冗余但【必要】:预留行的 location_id 会随整桶转移改写,而发货单要记的是
    -- 【发货当刻货在哪】。两者日后可以不同,那正是两个不同的事实。
    output_batch_id     uuid NOT NULL REFERENCES public.output_batches (id),
    location_id         uuid REFERENCES public.storage_locations (id),
    qty                 numeric NOT NULL CHECK (qty > 0),
    -- 这一行产生的销售记录(收入与 COGS 都挂在它上面)
    sales_record_id     uuid NOT NULL REFERENCES public.sales_records (id),
    created_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.shipment_lines IS
    'SO-3b:发货单行 —— 一行 = 一次【消耗掉一条预留】。主语是预留而不是订单行,因为只有预留带着地址(哪一批货、哪个库位);发货要从 committed 桶里精确取走那一份,不让排空策略去猜。ship_order 只消耗【整条】预留(部分发货先用 release_reservation 那一手把预留拆开),于是 qty 恒等于那条预留的全部数量 —— 这条不变量让"committed 桶 = Σ 活预留"始终成立。location_id 是【发货当刻】的库位,与预留行上那个可能不同(整桶转移会改写后者),两者是两个事实。';

CREATE INDEX idx_shipment_lines_shipment ON public.shipment_lines (shipment_id);
CREATE INDEX idx_shipment_lines_order_line ON public.shipment_lines (sales_order_line_id);

CREATE TRIGGER trg_shipment_lines_append_only
    BEFORE UPDATE OR DELETE ON public.shipment_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_shipment_append_only();

ALTER TABLE public.shipment_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "shipment_lines select by permission" ON public.shipment_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.sales.view'::text));

CREATE TABLE public.shipment_issues (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    shipment_id uuid NOT NULL REFERENCES public.shipments (id),
    version     integer NOT NULL CHECK (version >= 1),
    file_path   text NOT NULL,
    sha256      text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at   timestamptz NOT NULL DEFAULT now(),
    issued_by   uuid,
    UNIQUE (shipment_id, version)
);

COMMENT ON TABLE public.shipment_issues IS
    'SO-3b:送货单签发档(形状取自 so_issues),只增不改。谁、何时、第几版、哪张发货单、字节摘要。唯一写入口 record_shipment_issue();重新签发 = 新的一行,绝不覆盖旧行 —— 客户手里那份是某个具体版本。【没有"已发送"标志】:系统不知道对方收没收到。';

CREATE INDEX idx_shipment_issues_shipment ON public.shipment_issues (shipment_id, version DESC);

CREATE TRIGGER trg_shipment_issues_append_only
    BEFORE UPDATE OR DELETE ON public.shipment_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_shipment_append_only();

ALTER TABLE public.shipment_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY "shipment_issues select by permission" ON public.shipment_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.sales.view'::text));


-- ═══ 3 · 预留的第二种终局:消耗 ═════════════════════════════════════════════
ALTER TABLE public.sales_order_reservations
    ADD COLUMN consumed_at timestamptz,
    ADD COLUMN consumed_by uuid,
    ADD COLUMN shipment_line_id uuid REFERENCES public.shipment_lines (id),
    ADD CONSTRAINT sales_order_reservations_consume_complete CHECK (
        (consumed_at IS NULL     AND shipment_line_id IS NULL)
     OR (consumed_at IS NOT NULL AND shipment_line_id IS NOT NULL)),
    ADD CONSTRAINT sales_order_reservations_one_ending CHECK (
        released_at IS NULL OR consumed_at IS NULL);

COMMENT ON COLUMN public.sales_order_reservations.consumed_at IS
    'SO-3b:这条预留被【发货消耗】掉的时刻。与 released_* 并列而不是共用那三列 —— 释放是"货回到 available"(有一对反向流水),消耗是"货离开了台账"(没有反向流水,对应一条 sale 出库腿与一行 shipment_lines)。活预留 = released_at IS NULL AND consumed_at IS NULL。';

DROP INDEX idx_so_reservations_line;
DROP INDEX idx_so_reservations_bucket;
CREATE INDEX idx_so_reservations_line   ON public.sales_order_reservations (sales_order_line_id) WHERE released_at IS NULL AND consumed_at IS NULL;
CREATE INDEX idx_so_reservations_bucket ON public.sales_order_reservations (output_batch_id, location_id) WHERE released_at IS NULL AND consumed_at IS NULL;

-- ═══ 4 · 销售记录的【订单行标记】—— 应收只创建一次的落点 ═══════════════════
ALTER TABLE public.sales_records
    ADD COLUMN sales_order_line_id uuid REFERENCES public.sales_order_lines (id);

COMMENT ON COLUMN public.sales_records.sales_order_line_id IS
    'SO-3b:这一行是不是【订单流发货】产生的。非空 = 是,并指向它满足的那条订单行。后果就在本刀落地:这样的行【不产生应收】—— 那笔债在开票当刻已经记过(借 1100 / 贷 2500),发货只是把负债释放进收入。ar_open_items 的第一支与 customer_ar_exposure_base 的第一项都显式排除它,于是同一笔债不会被数两遍(选项 C 的核心不变量:应收只创建一次)。由 ship_order 在 INSERT 当刻写好,之后不可改(SALE_IMMUTABLE)。';

GRANT SELECT (sales_order_line_id) ON public.sales_records TO authenticated;

-- 不可变守卫多认一列
CREATE OR REPLACE FUNCTION public.reject_sales_record_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'SALE_IMMUTABLE';
    END IF;
    IF NEW.id              IS DISTINCT FROM OLD.id
       OR NEW.output_batch_id IS DISTINCT FROM OLD.output_batch_id
       OR NEW.quantity        IS DISTINCT FROM OLD.quantity
       OR NEW.unit_price      IS DISTINCT FROM OLD.unit_price
       OR NEW.currency        IS DISTINCT FROM OLD.currency
       OR NEW.fx_rate         IS DISTINCT FROM OLD.fx_rate
       OR NEW.amount_base      IS DISTINCT FROM OLD.amount_base
       OR NEW.sale_date       IS DISTINCT FROM OLD.sale_date
       OR NEW.notes           IS DISTINCT FROM OLD.notes
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
       OR NEW.created_by      IS DISTINCT FROM OLD.created_by
       -- SAL-A:出处两列同样不可变 —— 卖出去之后改口"这是算出来的"与改价同罪
       OR NEW.price_source     IS DISTINCT FROM OLD.price_source
       OR NEW.price_provenance IS DISTINCT FROM OLD.price_provenance
       -- SO-3b:订单行标记同样不可变 —— 改它就是把一笔"已在发票上认过的债"
       -- 悄悄变成一笔新的应收(或反过来),而两者的差别正是选项 C 的全部。
       OR NEW.sales_order_line_id IS DISTINCT FROM OLD.sales_order_line_id
       -- cut 2a:cogs_entry_id 首挂(NULL → 非 NULL),挂上之后不许再动
       OR (NEW.cogs_entry_id IS DISTINCT FROM OLD.cogs_entry_id
           AND NOT (OLD.cogs_entry_id IS NULL AND NEW.cogs_entry_id IS NOT NULL))
       -- SAL-C:customer_id 的【单向】放宽 —— 只允许 NULL → 某客户,且只允许
       -- attribute_sale_customer 那一次(ctx 在场)。改投他人 / 退回 NULL 一律拒:
       -- 把已存在的债改记到另一个人头上是另一种行为,不该从这条路够得着。
       OR (NEW.customer_id IS DISTINCT FROM OLD.customer_id
           AND NOT (OLD.customer_id IS NULL
                    AND NEW.customer_id IS NOT NULL
                    AND current_setting('evoltrya.attribution_ctx', true) = 'attribute_sale_customer'))
    THEN
        RAISE EXCEPTION 'SALE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

-- ═══ 5 · 遮蔽视图追加列,应收两支不相交,敞口同一条谓词 ═════════════════════
CREATE OR REPLACE VIEW public.sales_records_masked WITH (security_invoker = off) AS
 SELECT id,
    output_batch_id,
    customer_id,
    quantity,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
    currency,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    sale_date,
    notes,
    created_at,
    created_by,
    cogs_entry_id,
    price_source,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN price_provenance
            ELSE NULL::jsonb
        END AS price_provenance,
    sales_order_line_id
   FROM sales_records
  WHERE has_permission('module.finance.view'::text);

CREATE OR REPLACE VIEW public.ar_open_items WITH (security_invoker = off) AS
 SELECT sr.id AS sales_record_id,
    ob.code AS doc_code,
    sr.customer_id,
    c.legal_name AS customer_name,
    sr.sale_date,
    sr.amount_base,
    sr.currency,
    round(sr.quantity * sr.unit_price, 2) AS amount_ccy,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_ccy,
    round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric), 2) AS open_ccy,
    round((sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric)) * sr.fx_rate, 2) AS open_base,
    CURRENT_DATE - sr.sale_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - sr.sale_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket,
    inv.invoice_id,
    inv.invoice_code,
    'sale'::text AS doc_kind,
    round(COALESCE(s.settled, 0::numeric) * sr.fx_rate, 2) AS settled_base
   FROM sales_records_masked sr
     JOIN output_batches ob ON ob.id = sr.output_batch_id
     LEFT JOIN customers c ON c.id = sr.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.sales_record_id = sr.id) s ON true
     LEFT JOIN LATERAL ( SELECT i.id AS invoice_id,
            i.code AS invoice_code
           FROM invoice_lines_masked il
             JOIN invoices_masked i ON i.id = il.invoice_id
          WHERE il.sales_record_id = sr.id AND NOT il.invoice_voided
         LIMIT 1) inv ON true
  WHERE round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric), 2) > 0::numeric
    AND sr.sales_order_line_id IS NULL
    AND has_permission('module.finance.view'::text)
UNION ALL
 SELECT NULL::uuid AS sales_record_id,
    o.code AS doc_code,
    o.customer_id,
    c.legal_name AS customer_name,
    o.issue_date AS sale_date,
    round(o.amount_ccy * o.fx_rate, 2) AS amount_base,
    o.currency,
    o.amount_ccy,
    o.settled_ccy,
    o.open_ccy,
    o.open_base,
    CURRENT_DATE - o.issue_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - o.issue_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - o.issue_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - o.issue_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket,
    o.invoice_id,
    o.code AS invoice_code,
    'invoice'::text AS doc_kind,
    round(o.settled_ccy * o.fx_rate, 2) AS settled_base
   FROM order_invoice_open_all o
     LEFT JOIN customers c ON c.id = o.customer_id
  WHERE has_permission('module.finance.view'::text) AND has_permission('data.view_prices'::text);

CREATE OR REPLACE FUNCTION public.customer_ar_exposure_base(p_customer_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- SO-3a:敞口 = 未结清销售 + 【已过账未结清的订单流发票】。第二项读
    -- order_invoice_open_all —— ar_open_items 的第二支读的也是它:面板显示的
    -- 余额与拒绝的那道闸必须是同一个数(fixture 67 的目录断言钉住两个消费者)。
    -- 两项按构造不相交:发货(3b)产生的销售记录不带应收,第一项看不见它们。
    SELECT COALESCE((
        SELECT sum(open_base) FROM (
            SELECT round((sr.quantity * sr.unit_price - COALESCE(s.settled, 0)) * sr.fx_rate, 2) AS open_base
            FROM sales_records sr
            LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                FROM payment_allocations pa
                JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                WHERE pa.sales_record_id = sr.id
            ) s ON true
            WHERE sr.customer_id = p_customer_id
              -- SO-3b:发货产生的销售记录【不带应收】—— 那笔债在开票当刻已经
              -- 记过(借 1100 / 贷 2500)。与 ar_open_items 第一支逐字同一条谓词:
              -- 少了它,同一笔钱会在敞口里被数两遍。
              AND sr.sales_order_line_id IS NULL
              AND round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0), 2) > 0
        ) x), 0)
    + COALESCE((
        SELECT sum(o.open_base) FROM order_invoice_open_all o
        WHERE o.customer_id = p_customer_id), 0);
$function$;

-- ═══ 6 · 发货的函数们 ═══════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.next_shipment_code(p_date date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_year integer;
    v_seq  integer;
BEGIN
    -- 【无缝编号,自己的那把锁】互斥点是 advisory key 这个字符串 ——
    -- 'shipment_code_<year>',与发票('invoice_code_')、销售订单各自一把。
    -- MAX+1 只是推导;两个并发调用靠这把锁串行,回滚即释放号码。
    v_year := EXTRACT(YEAR FROM p_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('shipment_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM shipments WHERE code LIKE 'SHP-' || v_year::text || '-%';
    RETURN 'SHP-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_shipment_issue(p_shipment_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ship shipments%ROWTYPE;
    v_next integer;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_ship FROM shipments WHERE id = p_shipment_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIPMENT_NOT_FOUND|%', COALESCE(p_shipment_id::text, '?');
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('shipment_issue_' || p_shipment_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next FROM shipment_issues WHERE shipment_id = p_shipment_id;

    INSERT INTO shipment_issues (shipment_id, version, file_path, sha256, issued_by)
    VALUES (p_shipment_id, v_next, p_file_path, p_sha256, auth.uid());

    RETURN jsonb_build_object('version', v_next);
END;
$function$;

CREATE OR REPLACE FUNCTION public.ship_order(p_sales_order_id uuid, p_ship_date date, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_order    sales_orders%ROWTYPE;
    v_ship_id  uuid := gen_random_uuid();
    v_code     text;
    v_item     jsonb;
    v_res      record;
    v_res_id   uuid;
    v_split    jsonb;
    v_inv      record;
    v_line_ids uuid[] := ARRAY[]::uuid[];
    v_mv       uuid;
    v_sl_id    uuid;
    v_sale_id  uuid;
    v_rev_ccy  numeric := 0;
    v_rev_base numeric := 0;
    v_fx       numeric;
    v_unit     numeric;
    v_cogs     numeric;
    v_je1      jsonb;
    v_je2      jsonb;
    v_rem      numeric;
    v_state    text;
    v_ordered  numeric;
    v_shipped  numeric;
    v_status   text;
    v_n        int;
BEGIN
    -- ════════════════════════════════════════════════════════════════════════
    -- 【为什么是 module.sales.edit,而不是 module.inventory.edit】
    -- 与 reserve_stock 逐字同一条:发货【就是】一次销售行为,做它的人是销售。
    -- 给它挑一个"销售与库存都满足"的权限码,只能挑一个比两者都松的 ——
    -- 那不是把关、是把关的样子(zzz_function_grants 给 drain_stock 写的理由)。
    -- 台账的不变量不依赖调用者是谁:check_no_negative_bucket 是约束触发器,
    -- check_ledger_invariant 也是,对任何身份一视同仁。
    --
    -- 【收入与 COGS 的过账也在这里,而它们是财务的事】—— 但把这一步拆成
    -- "销售发货 + 财务过账"两次调用,就等于允许一个【发了货却没记收入】的
    -- 中间态存在。选项 C 的整条链是一个事务,所以它是一个函数。
    -- ════════════════════════════════════════════════════════════════════════
    PERFORM require_permission('module.sales.edit');

    -- 【发货日必填,永不默认】物理事件日,而且它决定收入落进哪个会计期间。
    IF p_ship_date IS NULL THEN
        RAISE EXCEPTION 'SHIP_DATE_REQUIRED';
    END IF;

    SELECT * INTO v_order FROM sales_orders WHERE id = p_sales_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_id::text, '?');
    END IF;
    IF v_order.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SO_SHIP_ORDER_NOT_SHIPPABLE|%|%', v_order.code, v_order.status;
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'SO_SHIP_NO_LINES|%', v_order.code;
    END IF;

    v_code := next_shipment_code(p_ship_date);
    INSERT INTO shipments (id, code, sales_order_id, ship_date, notes, created_by)
    VALUES (v_ship_id, v_code, p_sales_order_id, p_ship_date, NULL, v_user);

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_res_id := NULLIF(v_item->>'reservation_id', '')::uuid;

        SELECT r.id, r.sales_order_line_id, r.output_batch_id, r.location_id, r.qty,
               r.released_at, r.consumed_at,
               l.line_no, l.unit_price, l.sales_order_id,
               l.price_source, l.price_provenance
          INTO v_res
          FROM sales_order_reservations r
          JOIN sales_order_lines l ON l.id = r.sales_order_line_id
         WHERE r.id = v_res_id
         FOR UPDATE OF r;
        -- 【不是这张单的预留 / 不存在 / 已释放 / 已发过 —— 都是"没有这条预留"】
        IF NOT FOUND OR v_res.sales_order_id <> p_sales_order_id
           OR v_res.released_at IS NOT NULL OR v_res.consumed_at IS NOT NULL THEN
            RAISE EXCEPTION 'SO_SHIP_NOT_RESERVED|%', COALESCE(v_res_id::text, '?');
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【先开票后发货 —— 而判据是【派生】的,不是订单上的一个状态位】
        -- 这一行必须坐在一张【在册且已过账】的订单流发票上。状态位会与真相
        -- 漂开(作废一张票之后那个位还亮着),而这个问题每次都问得起。
        -- 顺带把那张票的【存下来的汇率】取出来:释放负债要按它,不按今天的行情
        -- —— 2500 里躺着的就是按它记进去的那个数(FIN-27 一族)。
        -- ════════════════════════════════════════════════════════════════════
        SELECT i.id, i.code, i.fx_rate, i.currency
          INTO v_inv
          FROM invoice_lines il
          JOIN invoices i ON i.id = il.invoice_id
         WHERE il.sales_order_line_id = v_res.sales_order_line_id
           AND NOT il.invoice_voided
           AND i.kind = 'order' AND i.status = 'issued'
         LIMIT 1;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'SO_SHIP_NOT_INVOICED|%|%', v_order.code, v_res.line_no;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【部分发货:先把预留拆开,再整条消耗】(SO-2 的形状,一处实现)
        -- release_reservation(id, 要放回的数量, 理由) = 整笔释放 + 就地重新
        -- 预留剩余。所以要发 q(< 预留量 r)时,先把 (r − q) 放回 available,
        -- 剩下的那条新预留就正好是 q,然后【整条】消耗它。
        -- 【为什么不直接从这条预留里取走 q】那会让"committed 桶 = Σ 活预留"
        -- 不再成立:剩余的 (r − q) 还在桶里,却没有任何一行说它属于谁 ——
        -- 而 create_stock_transfer 的整桶搬正是靠那条不变量。
        -- 【也不在这里抄一份拆分逻辑】拆分只有一处实现,就是 release_reservation。
        -- ════════════════════════════════════════════════════════════════════
        IF (v_item->>'qty') IS NOT NULL AND (v_item->>'qty')::numeric <> v_res.qty THEN
            IF (v_item->>'qty')::numeric <= 0 OR (v_item->>'qty')::numeric > v_res.qty THEN
                RAISE EXCEPTION 'SO_SHIP_EXCEEDS_RESERVATION|%|%', v_item->>'qty', v_res.qty;
            END IF;
            v_split := release_reservation(v_res.id, v_res.qty - (v_item->>'qty')::numeric,
                                           'partial shipment ' || v_code);
            v_res_id := (v_split->'rereserved'->>'reservation_id')::uuid;
            SELECT r.id, r.sales_order_line_id, r.output_batch_id, r.location_id, r.qty,
                   l.line_no, l.unit_price, l.price_source, l.price_provenance
              INTO v_res
              FROM sales_order_reservations r
              JOIN sales_order_lines l ON l.id = r.sales_order_line_id
             WHERE r.id = v_res_id;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【出库:直接写,不走 drain_stock】—— 预留【就是地址】(哪一批、哪个
        -- 库位、多少),所以这是一次【定址消耗】。drain_stock 是给【没有地址】
        -- 的消耗用的策略排空器(销售直接卖、投料、注销):它按 NULL 桶优先、
        -- 再按库位 code 升序去猜该动哪一份。这里没有可猜的 —— 猜反而会取错桶。
        -- 两个函数的函数头互相指着对方,免得下一个人以为这里漏用了它。
        -- ════════════════════════════════════════════════════════════════════
        INSERT INTO inventory_movements
            (output_batch_id, location_id, movement_type, qty_delta, stock_status,
             business_date, notes, created_by)
        VALUES (v_res.output_batch_id, v_res.location_id, 'sale', -v_res.qty, 'committed',
                p_ship_date, 'shipped ' || v_code, v_user)
        RETURNING id INTO v_mv;

        -- 销售记录:一条腿一行。价格与币种取【订单】的,汇率取【发票存下来的】。
        -- 出处从订单行原样抄过来(FIN-26:记录,不推断)。
        -- sales_order_line_id 就是那个标记 —— 它让这一行【不产生应收】
        -- (ar_open_items 第一支与 customer_ar_exposure_base 第一项都排除它)。
        INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                                   currency, fx_rate, amount_base, sale_date, notes,
                                   created_by, price_source, price_provenance,
                                   sales_order_line_id)
        VALUES (v_res.output_batch_id, v_order.customer_id, v_res.qty, v_res.unit_price,
                v_order.currency, v_inv.fx_rate,
                round(v_res.qty * v_res.unit_price * v_inv.fx_rate, 2),
                p_ship_date, 'shipped ' || v_code || ' · ' || v_order.code,
                v_user, v_res.price_source, v_res.price_provenance,
                v_res.sales_order_line_id)
        RETURNING id INTO v_sale_id;

        -- SO-2b:腿表 —— 一条出库腿一行(这里恰好一条,因为消耗是定址的)
        INSERT INTO sales_record_movements (sales_record_id, movement_id)
        VALUES (v_sale_id, v_mv);

        INSERT INTO shipment_lines (shipment_id, sales_order_line_id, reservation_id,
                                    output_batch_id, location_id, qty, sales_record_id)
        VALUES (v_ship_id, v_res.sales_order_line_id, v_res.id,
                v_res.output_batch_id, v_res.location_id, v_res.qty, v_sale_id)
        RETURNING id INTO v_sl_id;

        -- 预留的第二种终局:【消耗】。没有反向流水 —— 货离开了台账。
        UPDATE sales_order_reservations
           SET consumed_at = now(), consumed_by = v_user, shipment_line_id = v_sl_id
         WHERE id = v_res.id;

        -- 库存缓存:与 record_output_sale 逐字同一套(remaining_qty 与 state)
        SELECT remaining_qty INTO v_rem FROM output_batches WHERE id = v_res.output_batch_id FOR UPDATE;
        v_rem := v_rem - v_res.qty;
        v_state := CASE WHEN v_rem = 0 THEN '已售罄' ELSE '部分售出' END;
        UPDATE output_batches
           SET remaining_qty = v_rem, state = v_state, updated_by = v_user, updated_at = now()
         WHERE id = v_res.output_batch_id;

        -- COGS:与 record_output_sale 逐字同形 —— 有产出腿单位成本才挂,
        -- 没有就等 allocate_processing_costs 补挂(它读 sales_records,
        -- 而这一行就是一条普通的 sales_records,所以它自然看得见)。
        SELECT po.unit_cost_base INTO v_unit
        FROM processing_outputs po WHERE po.output_batch_id = v_res.output_batch_id LIMIT 1;
        IF v_unit IS NOT NULL THEN
            v_cogs := round(v_res.qty * v_unit, 2);
            IF v_cogs <> 0 THEN
                v_je2 := post_journal_entry(
                    p_ship_date,
                    'COGS ' || (SELECT code FROM output_batches WHERE id = v_res.output_batch_id),
                    'shipment', v_sale_id,
                    jsonb_build_array(
                        jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                        jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
                UPDATE sales_records SET cogs_entry_id = (v_je2->>'entry_id')::uuid WHERE id = v_sale_id;
            END IF;
        END IF;

        -- 收入侧按【发票存下来的汇率】累计(一张发货单属于一张订单,所以一个汇率)
        v_fx := v_inv.fx_rate;
        v_rev_ccy := v_rev_ccy + round(v_res.qty * v_res.unit_price, 2);
        v_line_ids := v_line_ids || v_res.sales_order_line_id;
    END LOOP;

    v_rev_base := round(v_rev_ccy * v_fx, 2);

    -- ════════════════════════════════════════════════════════════════════════
    -- 【过账:借 2500 释放合同负债 / 贷 4000 收入】单据币种,按发票存下来的汇率。
    -- 这就是选项 C 的第二步 —— 开票认了债(借 1100 / 贷 2500),发货把那笔
    -- 负债换成收入。2500 因此在一张单全部发完之后精确归零(fixture 68 钉住)。
    -- ════════════════════════════════════════════════════════════════════════
    v_je1 := post_journal_entry(
        p_ship_date,
        'Shipment ' || v_code || ' · ' || v_order.code,
        'shipment', v_ship_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2500', 'side', 'debit',
                'currency', v_order.currency, 'amount_ccy', v_rev_ccy, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '4000', 'side', 'credit',
                'currency', v_order.currency, 'amount_ccy', v_rev_ccy, 'fx_rate', v_fx)));

    -- ════════════════════════════════════════════════════════════════════════
    -- 【订单状态是【现算】出来的,不是人点的】已发 vs 已订,逐行比。
    -- 经 so_status_ctx 写入 —— 冻结守卫据此知道是"函数在动状态列"。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT COALESCE(sum(l.quantity), 0) INTO v_ordered
      FROM sales_order_lines l WHERE l.sales_order_id = p_sales_order_id;
    SELECT COALESCE(sum(sl.qty), 0) INTO v_shipped
      FROM shipment_lines sl JOIN shipments s ON s.id = sl.shipment_id
     WHERE s.sales_order_id = p_sales_order_id;
    v_status := CASE WHEN v_shipped >= v_ordered THEN 'shipped' ELSE 'partially_shipped' END;

    PERFORM set_config('evoltrya.so_status_ctx', '1', true);
    UPDATE sales_orders
       SET status = v_status, updated_at = now(), updated_by = v_user
     WHERE id = p_sales_order_id;
    PERFORM set_config('evoltrya.so_status_ctx', '', true);

    INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
    VALUES (p_sales_order_id, 'shipped',
            v_code || ' · ' || trim_scale(v_shipped)::text || '/' || trim_scale(v_ordered)::text,
            v_user);

    -- 【断言,不是假设】发货行的条数必须等于递进来的条数。将来有人给上面任何
    -- 一段加一个提前 CONTINUE,这里当场炸,而不是留下一张少了几行的发货单
    -- (而那张单的收入分录已经按【全部】行算过了)。
    SELECT count(*) INTO v_n FROM shipment_lines WHERE shipment_id = v_ship_id;
    IF v_n <> jsonb_array_length(p_lines) THEN
        RAISE EXCEPTION 'SO_SHIP_LINES_LOST|%|%', jsonb_array_length(p_lines), v_n;
    END IF;

    RETURN jsonb_build_object(
        'shipment_id', v_ship_id,
        'code', v_code,
        'ship_date', p_ship_date,
        'line_count', v_n,
        'revenue_ccy', v_rev_ccy,
        'revenue_base', v_rev_base,
        'currency', v_order.currency,
        'fx_rate', v_fx,
        'order_status', v_status,
        'revenue_journal', v_je1->>'code');
END;
$function$;

-- ═══ 7 · 预留守卫认第二种终局;活预留判据全库同步 ═══════════════════════════
CREATE OR REPLACE FUNCTION public.guard_sales_order_reservation_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_move text := current_setting('evoltrya.reservation_move_ctx', true);
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'SO_RESERVATION_IMMUTABLE|delete';
    END IF;

    -- 【放行的只有三种改动,逐条写出来】
    -- ① 一次性的释放:三列一起从空变成非空,其余一个字不动。
    IF OLD.released_at IS NULL AND NEW.released_at IS NOT NULL
       AND OLD.consumed_at IS NULL AND NEW.consumed_at IS NULL
       AND NEW.id                  IS NOT DISTINCT FROM OLD.id
       AND NEW.sales_order_line_id IS NOT DISTINCT FROM OLD.sales_order_line_id
       AND NEW.output_batch_id     IS NOT DISTINCT FROM OLD.output_batch_id
       AND NEW.location_id         IS NOT DISTINCT FROM OLD.location_id
       AND NEW.qty                 IS NOT DISTINCT FROM OLD.qty
       AND NEW.pair_id             IS NOT DISTINCT FROM OLD.pair_id
       AND NEW.created_at          IS NOT DISTINCT FROM OLD.created_at
       AND NEW.created_by          IS NOT DISTINCT FROM OLD.created_by
    THEN
        RETURN NEW;
    END IF;

    -- ② 一次性的消耗(发货):consumed_at + shipment_line_id 一起从空变成非空,
    --    其余一个字不动。与释放并列,而不是共用那三列 —— 见表头。
    IF OLD.consumed_at IS NULL AND NEW.consumed_at IS NOT NULL
       AND OLD.released_at IS NULL AND NEW.released_at IS NULL
       AND NEW.id                  IS NOT DISTINCT FROM OLD.id
       AND NEW.sales_order_line_id IS NOT DISTINCT FROM OLD.sales_order_line_id
       AND NEW.output_batch_id     IS NOT DISTINCT FROM OLD.output_batch_id
       AND NEW.location_id         IS NOT DISTINCT FROM OLD.location_id
       AND NEW.qty                 IS NOT DISTINCT FROM OLD.qty
       AND NEW.pair_id             IS NOT DISTINCT FROM OLD.pair_id
       AND NEW.created_at          IS NOT DISTINCT FROM OLD.created_at
       AND NEW.created_by          IS NOT DISTINCT FROM OLD.created_by
    THEN
        RETURN NEW;
    END IF;

    -- ③ 整桶转移带着它换库位 —— 只在转移函数设下的上下文里,且【只有】库位变。
    IF v_move IS NOT NULL AND btrim(v_move) <> ''
       AND OLD.released_at IS NULL AND NEW.released_at IS NULL
       AND OLD.consumed_at IS NULL AND NEW.consumed_at IS NULL
       AND NEW.id                  IS NOT DISTINCT FROM OLD.id
       AND NEW.sales_order_line_id IS NOT DISTINCT FROM OLD.sales_order_line_id
       AND NEW.output_batch_id     IS NOT DISTINCT FROM OLD.output_batch_id
       AND NEW.qty                 IS NOT DISTINCT FROM OLD.qty
       AND NEW.pair_id             IS NOT DISTINCT FROM OLD.pair_id
       AND NEW.created_at          IS NOT DISTINCT FROM OLD.created_at
       AND NEW.created_by          IS NOT DISTINCT FROM OLD.created_by
    THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'SO_RESERVATION_IMMUTABLE|update';
END;
$function$;

CREATE OR REPLACE FUNCTION public.reserve_stock(p_sales_order_line_id uuid, p_output_batch_id uuid, p_qty numeric, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_pair     uuid := gen_random_uuid();
    v_today    date := CURRENT_DATE;
    v_line     record;
    v_batch    record;
    v_avail    numeric;
    v_already  numeric;
    v_res_id   uuid;
BEGIN
    -- 【为什么是 module.sales.edit,而不是 module.inventory.edit】
    -- 预留就是一次销售行为 —— 做它的人是销售。给它挑一个"销售与库存都满足"的
    -- 权限码,只能挑一个比两者都松的,那不是把关、是把关的样子(与
    -- zzz_function_grants 给 drain_stock 写的那条理由同形)。而台账的不变量
    -- 不依赖调用者是谁:成对写入让物理总量按构造不动,check_no_negative_bucket
    -- 是约束触发器,对任何身份一视同仁。
    PERFORM require_permission('module.sales.edit');

    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'SO_RESERVE_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;

    SELECT l.id, l.quantity, l.material_id, l.line_no,
           o.id AS order_id, o.code AS order_code, o.status, o.deleted_at
      INTO v_line
      FROM sales_order_lines l
      JOIN sales_orders o ON o.id = l.sales_order_id
     WHERE l.id = p_sales_order_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_line_id::text, '?');
    END IF;

    -- 【只有确认了的订单才预留】草稿是还没答应的事,给它扣住货,等于让一张
    -- 随手建的单据把库存冻起来,而没有任何人做过那个承诺。
    IF v_line.deleted_at IS NOT NULL OR v_line.status <> 'confirmed' THEN
        RAISE EXCEPTION 'SO_RESERVE_ORDER_NOT_CONFIRMED|%|%',
            v_line.order_code, COALESCE(v_line.status, '?');
    END IF;

    -- 【产出批次,且还在】—— 见本表注释:预留一个进料批次会造出永远消耗不掉的
    -- 承诺库存(movement_type='sale' 被 inventory_movements_side 钉在产出侧)。
    SELECT ob.id, ob.code, ob.material_id, ob.unit
      INTO v_batch
      FROM output_batches ob
     WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_RESERVE_OUTPUT_ONLY|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    IF v_batch.material_id IS DISTINCT FROM v_line.material_id THEN
        RAISE EXCEPTION 'SO_RESERVE_MATERIAL_MISMATCH|%|%|%',
            v_batch.code,
            (SELECT code FROM materials WHERE id = v_batch.material_id),
            (SELECT code FROM materials WHERE id = v_line.material_id);
    END IF;

    -- 【行的天花板】一行订单最多只能许出它自己的数量。超过就是把同一批货
    -- 许给同一行两次 —— 屏幕上看不出来,发货时才炸。
    SELECT COALESCE(sum(r.qty), 0) INTO v_already
      FROM sales_order_reservations r
     WHERE r.sales_order_line_id = p_sales_order_line_id AND r.released_at IS NULL AND r.consumed_at IS NULL;
    IF v_already + p_qty > v_line.quantity THEN
        RAISE EXCEPTION 'SO_RESERVE_EXCEEDS_LINE|%|%|%', p_qty, v_line.quantity, v_already;
    END IF;

    -- 【就地求和,不调 derived_stock_qty】那个函数体里有
    -- require_permission('module.inventory.view'),而 has_permission 解析的是
    -- 【调用者】的 JWT —— DEFINER 换得了行的可见性,换不了函数体内那句对调用者
    -- 的判断。销售的人没有库存的码,调过去当场 PERMISSION_DENIED。
    -- record_output_sale 就地求和,同一个理由。
    SELECT COALESCE(sum(m.qty_delta), 0) INTO v_avail
      FROM inventory_movements m
     WHERE m.output_batch_id = p_output_batch_id
       AND m.inbound_batch_id IS NULL
       AND m.location_id IS NOT DISTINCT FROM p_location_id
       AND m.stock_status = 'available';
    IF p_qty > v_avail THEN
        RAISE EXCEPTION 'SO_RESERVE_EXCEEDS_AVAILABLE|%|%', p_qty, v_avail;
    END IF;

    -- 成对:出 available、进 committed。同批次、同库位。物理总量按构造不动,
    -- remaining_qty 一个字不变,批次的 state 也不变(承诺不是销售)。
    INSERT INTO inventory_movements
        (output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_output_batch_id, p_location_id, 'status_change_out',
         -p_qty, 'available', v_pair, v_today,
         'reserved for ' || v_line.order_code || ' line ' || v_line.line_no, v_user),
        (p_output_batch_id, p_location_id, 'status_change_in',
          p_qty, 'committed', v_pair, v_today,
         'reserved for ' || v_line.order_code || ' line ' || v_line.line_no, v_user);

    INSERT INTO sales_order_reservations
        (sales_order_line_id, output_batch_id, location_id, qty, pair_id, created_by)
    VALUES (p_sales_order_line_id, p_output_batch_id, p_location_id, p_qty, v_pair, v_user)
    RETURNING id INTO v_res_id;

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (v_line.order_id, 'reserved',
            format('line %s · %s %s %s', v_line.line_no, v_batch.code, p_qty, v_batch.unit));

    RETURN jsonb_build_object(
        'reservation_id', v_res_id, 'pair_id', v_pair, 'qty', p_qty,
        'output_batch_id', p_output_batch_id, 'location_id', p_location_id,
        'available_after', v_avail - p_qty,
        'line_reserved_after', v_already + p_qty,
        'line_quantity', v_line.quantity);
END;
$function$;

CREATE OR REPLACE FUNCTION public.release_reservation(p_reservation_id uuid, p_qty numeric DEFAULT NULL::numeric, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_pair   uuid := gen_random_uuid();
    v_today  date := CURRENT_DATE;
    v_res    record;
    v_order  record;
    v_want   numeric;
    v_rest   numeric;
    v_new    jsonb := NULL;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT r.*, l.line_no, l.sales_order_id
      INTO v_res
      FROM sales_order_reservations r
      JOIN sales_order_lines l ON l.id = r.sales_order_line_id
     WHERE r.id = p_reservation_id
     FOR UPDATE OF r;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_RESERVATION_NOT_FOUND|%', COALESCE(p_reservation_id::text, '?');
    END IF;
    IF v_res.released_at IS NOT NULL THEN
        RAISE EXCEPTION 'SO_RESERVATION_ALREADY_RELEASED|%', p_reservation_id;
    END IF;
    -- SO-3b:已经发出去的货放不回来 —— 更正走贷项凭证,不是"再释放一次"。
    IF v_res.consumed_at IS NOT NULL THEN
        RAISE EXCEPTION 'SO_RESERVATION_ALREADY_SHIPPED|%', p_reservation_id;
    END IF;

    -- 【释放要留下为什么,与暂扣同一条】一次没有理由的释放,过两天没人说得清
    -- 那批货为什么不再属于那张订单了。(hold_stock 的理由必填 / release_stock 的
    -- 备注可选,那处不对称是因为放开暂扣是"回到常态";这里不是 —— 撤回一个
    -- 已经做出的承诺【本身】就是一个需要解释的动作。)
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'SO_RELEASE_REASON_REQUIRED|%', p_reservation_id;
    END IF;

    v_want := COALESCE(p_qty, v_res.qty);
    IF v_want <= 0 OR v_want > v_res.qty THEN
        RAISE EXCEPTION 'SO_RELEASE_EXCEEDS|%|%', v_want, v_res.qty;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【部分释放 = 整行释放 + 就地重新预留剩余】
    -- 不是"把 qty 改小"。一行预留是一个发生过的事实(某日许了 40),把它改成
    -- 25 是在改写历史。整行释放之后再预留 15,留下的是两条都为真的事实,
    -- 合起来正好是发生过的经过 —— 而且流水侧一样对得上:先整笔 40 回到
    -- available,再 15 进 committed,净效果就是放回 25。
    -- 【重新预留走的是 reserve_stock 本身】,不是一段抄过来的插入:它会重新
    -- 走一遍订单状态、行天花板、桶余量三道检查。同一条规则,一个实现。
    -- ════════════════════════════════════════════════════════════════════════
    INSERT INTO inventory_movements
        (output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (v_res.output_batch_id, v_res.location_id, 'status_change_out',
         -v_res.qty, 'committed', v_pair, v_today, btrim(p_reason), v_user),
        (v_res.output_batch_id, v_res.location_id, 'status_change_in',
          v_res.qty, 'available', v_pair, v_today, btrim(p_reason), v_user);

    UPDATE sales_order_reservations
       SET released_at     = now(),
           released_by     = v_user,
           release_reason  = btrim(p_reason),
           release_pair_id = v_pair
     WHERE id = p_reservation_id;

    v_rest := v_res.qty - v_want;
    IF v_rest > 0 THEN
        v_new := reserve_stock(v_res.sales_order_line_id, v_res.output_batch_id,
                               v_rest, v_res.location_id);
    END IF;

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (v_res.sales_order_id, 'released',
            format('line %s · %s · %s', v_res.line_no, v_want, btrim(p_reason)));

    RETURN jsonb_build_object(
        'reservation_id', p_reservation_id,
        'released_qty', v_want,
        'release_pair_id', v_pair,
        'rereserved_qty', v_rest,
        'rereserved', v_new);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_stock_transfer(p_qty numeric, p_to_location_id uuid, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_from_location_id uuid DEFAULT NULL::uuid, p_stock_status text DEFAULT 'available'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_pair     uuid := gen_random_uuid();
    v_have     numeric;
    v_today    date := CURRENT_DATE;
    v_material uuid;
    v_warn     text[];
    v_reserved numeric;
BEGIN
    PERFORM require_permission('module.inventory.edit');

    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'STK_ONE_BATCH';
    END IF;
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'STK_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;
    -- SO-2:【一个坏状态不是一个坏数量】。此前这里抛的是 STK_QTY_INVALID,
    -- 于是"你传了一个系统不认识的库存状态"会在屏幕上显示成"数量无效" ——
    -- 一条把人送去看错地方的消息。三个桶都在这里列出来。
    IF p_stock_status IS NULL OR p_stock_status NOT IN ('available','on_hold','committed') THEN
        RAISE EXCEPTION 'IOD_TRANSFER_STATUS_INVALID|%', COALESCE(p_stock_status, '?');
    END IF;
    -- 【源与目的相同】不是一次无害的空操作:它会写下两行互相抵消的流水,
    -- 把台账弄脏,而且几乎总是意味着操作的人选错了一边。
    IF p_from_location_id IS NOT DISTINCT FROM p_to_location_id THEN
        RAISE EXCEPTION 'IOD_TRANSFER_SAME_LOCATION';
    END IF;
    -- 目的地必须是一个【在用】的库位。停用的库位不该再收货(LOC-1 的停用语义)。
    IF p_to_location_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = p_to_location_id AND is_active) THEN
        RAISE EXCEPTION 'IOD_TRANSFER_TO_INACTIVE|%', COALESCE(p_to_location_id::text, '?');
    END IF;

    -- 【同一粒度】对着派生桶比,与 STK-1 的暂扣/释放一模一样:
    -- remaining_qty 没有库位轴,在这个粒度上现算是唯一可能的来源。
    v_have := derived_stock_qty(p_inbound_batch_id, p_output_batch_id, p_from_location_id, p_stock_status);
    IF p_qty > v_have THEN
        RAISE EXCEPTION 'IOD_TRANSFER_EXCEEDS_BUCKET|%|%', p_qty, v_have;
    END IF;

    -- IOD-2:落闸,【只在入腿上】。物料从批次反查 —— 两种批次二选一(上面的
    -- XOR 已经保证恰好一个非空),两张表都有 material_id NOT NULL。
    -- 【出腿一个字都不查】:分类管的是货可以待在哪里,不是货能不能离开;拦住
    -- 一批放错地方的货【离开】,只会把它焊死在错的地方。
    v_material := COALESCE(
        (SELECT material_id FROM inbound_batches WHERE id = p_inbound_batch_id),
        (SELECT material_id FROM output_batches  WHERE id = p_output_batch_id));
    v_warn := check_location_class(p_to_location_id, v_material);
    -- NTF-1:告警留一份下来(入腿的库位/物料)。返回值那一份不变。
    PERFORM notify_landing_warnings(v_warn, p_to_location_id, v_material);

    -- 成对:出源库位、进目的库位。【状态原样带过去】—— 转移搬的是位置,
    -- 不是状态;一批被扣住的货换个货架仍然是被扣住的。
    INSERT INTO inventory_movements
        (inbound_batch_id, output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_inbound_batch_id, p_output_batch_id, p_from_location_id, 'transfer_out',
         -p_qty, p_stock_status, v_pair, v_today, NULLIF(btrim(COALESCE(p_note,'')),''), v_user),
        (p_inbound_batch_id, p_output_batch_id, p_to_location_id, 'transfer_in',
          p_qty, p_stock_status, v_pair, v_today, NULLIF(btrim(COALESCE(p_note,'')),''), v_user);

    -- ════════════════════════════════════════════════════════════════════════
    -- SO-2:【committed 的货搬走了,预留行必须跟着走 —— 而且只允许整桶搬】
    --
    -- 预留行记的是 批次 × 库位 这个桶。桶里的货搬到别的库位,而预留行还写着
    -- 老库位,那两句话当场对不上:流水说这 40kg 在 B,预留说它在 A。
    --
    -- 【为什么只允许整桶】部分搬走就得回答"这 40 里哪 15 跟着走" —— 而预留行
    -- 是按订单行分的,没有任何东西能回答那个问题;系统替人挑一行,就是编造。
    -- 所以:整桶搬,预留行的 location_id 跟着改(那是"这批货现在放在哪",不是
    -- "当初许了什么");搬不完就点名拒绝,补救写在消息里 —— 先部分释放,
    -- 再搬,再重新预留。三步各自留下自己的痕迹。
    --
    -- 【改 location_id 是本表唯一允许的事后改写】,由 evoltrya.reservation_move_ctx
    -- 向守卫说明"这是转移在改",而不是让守卫对任何 UPDATE 都放行一列。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_stock_status = 'committed' THEN
        SELECT COALESCE(sum(r.qty), 0) INTO v_reserved
          FROM sales_order_reservations r
         WHERE r.output_batch_id IS NOT DISTINCT FROM p_output_batch_id
           AND r.location_id IS NOT DISTINCT FROM p_from_location_id
           AND r.released_at IS NULL AND r.consumed_at IS NULL;

        IF v_reserved > 0 AND p_qty <> v_reserved THEN
            RAISE EXCEPTION 'IOD_TRANSFER_COMMITTED_PARTIAL|%|%', p_qty, v_reserved;
        END IF;

        IF v_reserved > 0 THEN
            PERFORM set_config('evoltrya.reservation_move_ctx', '1', true);
            UPDATE sales_order_reservations
               SET location_id = p_to_location_id
             WHERE output_batch_id IS NOT DISTINCT FROM p_output_batch_id
               AND location_id IS NOT DISTINCT FROM p_from_location_id
               AND released_at IS NULL AND consumed_at IS NULL;
            PERFORM set_config('evoltrya.reservation_move_ctx', '', true);
        END IF;
    END IF;

    RETURN jsonb_build_object('pair_id', v_pair, 'qty', p_qty,
                              'stock_status', p_stock_status,
                              'warnings', to_jsonb(v_warn));
END;
$function$;

CREATE OR REPLACE FUNCTION public.emit_batch_writeoff_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx   text := current_setting('evoltrya.movement_ctx', true);
    v_run   uuid;
    v_value numeric;
    v_acct  text;
    v_amt   numeric;
    v_bd    date;      -- FIN-32:这条流水的【业务日】
    v_resn  int;       -- SO-2:这批货上还有几条【活预留】
    v_orders text;
BEGIN
    -- ════════════════════════════════════════════════════════════════════════
    -- SO-2:【一批还许着人的货,不能就这么注销掉】
    -- 排空一律走 drain_stock 的 ARRAY['available','on_hold'] —— 那两个桶是
    -- 【没有外部账】的:暂扣只是一个理由字符串。committed 不同,它在
    -- sales_order_reservations 里有一行对应的事实,还挂在某张订单的某一行上。
    -- 把它排空,那一行预留会指着一批不存在的货,而订单页上什么都不会变。
    -- 【所以这里不是"把 committed 加进排空数组",而是拒绝】—— 补救写在消息里:
    -- 先释放(那一步会留下理由、会回到 available、会写进订单历史),再注销。
    -- 【一个决定,而不是一次保守】:注销是不可逆的,而释放是有主人的动作;
    -- 让系统替销售决定"这个承诺可以撤了",正是它不该做的事。
    -- 反过来说,下面 drain 的两个数组【一个字都不用改】:committed 在这里就被
    -- 挡住了,排空永远见不到它 —— 这条注释是那两个数组为什么可以原样不动的
    -- 全部理由,删掉守卫就必须同时回来改数组。
    -- ════════════════════════════════════════════════════════════════════════
    IF TG_TABLE_NAME = 'output_batches' THEN
        SELECT count(*), string_agg(DISTINCT o.code, ', ' ORDER BY o.code)
          INTO v_resn, v_orders
          FROM sales_order_reservations r
          JOIN sales_order_lines l ON l.id = r.sales_order_line_id
          JOIN sales_orders o      ON o.id = l.sales_order_id
         WHERE r.output_batch_id = OLD.id AND r.released_at IS NULL AND r.consumed_at IS NULL;
        IF v_resn > 0 THEN
            RAISE EXCEPTION 'SO_BATCH_HAS_RESERVATIONS|%|%|%', OLD.code, v_resn, v_orders;
        END IF;
    END IF;

    IF OLD.remaining_qty > 0 THEN
        -- ════════════════════════════════════════════════════════════════════
        -- FIN-32:business_date =【这件事在业务上发生在哪一天】,与它被记进系统的
        -- 时刻是两回事。两类事,两个答案,不能共用一个:
        --
        --   * 注销(writeoff)是【真实发生的物理事件】—— 货报废了。发生在有人
        --     按下注销的那天,而那天就写在行上:deleted_at。取它的日期部分,
        --     是【读记录】而不是 CURRENT_DATE 那种【当场编一个】。
        --     (触发器只在 deleted_at 由空变非空时触发,所以它必然有值。)
        --
        --   * 冲销(reversal_void)【不是物理事件】—— 电池处理过了就处理过了,
        --     回滚是在更正一次【记错的加工单】。所以它的业务日是【原加工单的
        --     process_date】,不是今天:那样一错一改在同一天对消,中间那几天的
        --     库存历史不会凭空多出一批实际并不存在的货。
        --     会计侧的先例同向:reverse_journal_entry 把冲销日做成【显式入参】,
        --     从不假定 —— 这里没有入参可传,但答案同样来自记录(run.process_date),
        --     不来自时钟。
        --
        -- 【两个账会给出两个日期,这是知情的选择,不是疏漏】(FIN-32-fu1)
        -- 同一次更正:分录侧的冲销按【显式传入的冲销日】入账(它必须如此 ——
        -- 期间锁不许往已关闭的月份里塞东西),而这里的流水按【原加工日】。
        -- 于是一次更正在两个账里带着两个日期。这是两种账的性质不同:
        --   * 分录是【价值账,带锁】—— 它记的是"这笔更正在哪个会计期发生";
        --   * 流水是【数量账,无锁】—— 它记的是"那批货实际在不在库里"。
        -- 按日期把两个账对起来的人一定会撞上这处差异,所以写在这里:
        -- 撞上时该问的是"这两个日期各自回答的是哪个问题",不是"哪个错了"。
        -- ════════════════════════════════════════════════════════════════════
        IF TG_TABLE_NAME = 'inbound_batches' THEN
            -- IOD-1:注销排空【所有】桶,两种状态都算 —— 报废一批货,不会因为其中
            -- 一部分被扣住就留在账上。这也是三个消耗方里唯一一个必须动 on_hold 的。
            -- SO-2:committed 不在数组里,因为它【到不了这里】(上面的守卫已经拒了);
            -- 进料批次本来也不可能有 committed —— 预留只指向产出批次。
            PERFORM drain_stock(
                p_qty => OLD.remaining_qty, p_movement_type => 'writeoff',
                p_business_date => NEW.deleted_at::date, p_inbound_batch_id => OLD.id,
                p_statuses => ARRAY['available','on_hold'], p_created_by => NEW.updated_by);
        ELSE  -- output_batches
            IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'reversal' THEN
                v_run := split_part(v_ctx, ':', 2)::uuid;
                SELECT process_date INTO v_bd FROM processing_runs WHERE id = v_run;
                PERFORM drain_stock(
                    p_qty => OLD.remaining_qty, p_movement_type => 'reversal_void',
                    p_business_date => v_bd, p_output_batch_id => OLD.id,
                    p_statuses => ARRAY['available','on_hold'], p_run_id => v_run,
                    p_created_by => NEW.updated_by);
            ELSE
                PERFORM drain_stock(
                    p_qty => OLD.remaining_qty, p_movement_type => 'writeoff',
                    p_business_date => NEW.deleted_at::date, p_output_batch_id => OLD.id,
                    p_statuses => ARRAY['available','on_hold'], p_created_by => NEW.updated_by);
            END IF;
        END IF;

        -- cut 2a:注销即入账(仅已计值批次,借 5200 / 贷 1200|1220)。
        -- processing 回滚(reversal_void)不入账:本 cut 不记加工产出/消耗分录,
        -- void 的产出从未入过 1220,无可冲销。未计值批次只出量不入账。
        IF v_ctx IS NULL OR split_part(v_ctx, ':', 1) <> 'reversal' THEN
            IF TG_TABLE_NAME = 'inbound_batches' THEN
                v_value := OLD.unit_price;
                v_acct := '1200';
            ELSE
                SELECT po.unit_cost_base INTO v_value
                FROM public.processing_outputs po
                WHERE po.output_batch_id = OLD.id
                LIMIT 1;
                v_acct := '1220';
            END IF;
            IF v_value IS NOT NULL THEN
                v_amt := round(OLD.remaining_qty * v_value, 2);
                IF v_amt <> 0 THEN
                    PERFORM post_journal_entry(
                        CURRENT_DATE,
                        'Write-off ' || OLD.code,
                        'writeoff', OLD.id,
                        jsonb_build_array(
                            jsonb_build_object('account_code', '5200', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt),
                            jsonb_build_object('account_code', v_acct, 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt)));
                END IF;
            END IF;
        END IF;

        NEW.remaining_qty := 0;
    END IF;
    RETURN NEW;
END;
$function$;

-- ═══ 8 · 状态机加宽;3a 停放的作废检查落地 ══════════════════════════════════
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
    v_res   record;
    v_freed numeric := 0;
    v_left  int;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_order FROM sales_orders WHERE id = p_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_order_id::text, '?');
    END IF;

    -- 【允许的去处,逐个状态写出来】
    -- SO-3b:履约两态落地,而它们【不在这张表的右边】—— partially_shipped /
    -- shipped 由 ship_order 按"已发 vs 已订"现算后写入(经 so_status_ctx),
    -- 不是人手点的。这张表只管【人能点的那些】。
    -- 【closed 现在要求发完货】confirmed → closed 那条路没了:一张还没发货的
    -- 订单"走完了"是说不通的,而此前它是可点的。
    -- 【发出去的货收不回来】partially_shipped 是终点之一:2500 已经释放进 4000、
    -- 库存已经离开台账,作废它需要的是【贷项凭证】(sales_records 表头停放的
    -- 未来概念),不是一次状态跳转。shipped 只能走向 closed,同理。
    v_ok := CASE v_order.status
        WHEN 'draft'             THEN p_to IN ('confirmed','cancelled')
        WHEN 'confirmed'         THEN p_to IN ('cancelled')
        WHEN 'partially_shipped' THEN false      -- 见上:更正走贷项凭证
        WHEN 'shipped'           THEN p_to IN ('closed')
        WHEN 'closed'            THEN false      -- 终态
        WHEN 'cancelled'         THEN false      -- 终态
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

    -- ════════════════════════════════════════════════════════════════════════
    -- SO-2:【作废即释放,而且在改状态【之前】做】
    -- 一张作废的订单不该继续扣着货 —— 那批货会以 committed 的身份留在账上,
    -- 谁也卖不掉、谁也投不了,而屏幕上没有任何东西解释为什么。
    -- 【为什么在 UPDATE 之前】释放走 release_reservation,它会重新读这一行;
    -- 放在后面就得让它面对一个已经作废的订单,那是给自己造一个例外。
    -- 放在前面,任何一条释放失败都会把整个作废一起回滚 —— 要么单据作废了、
    -- 货也放回来了,要么两件都没发生。
    -- 【closed 不释放,那是另一件事】走完的订单,它的货是发出去了,不是放回去了。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_to = 'cancelled' THEN
        FOR v_res IN
            SELECT r.id, r.qty
              FROM sales_order_reservations r
              JOIN sales_order_lines l ON l.id = r.sales_order_line_id
             WHERE l.sales_order_id = p_order_id AND r.released_at IS NULL AND r.consumed_at IS NULL
             ORDER BY r.created_at
        LOOP
            PERFORM release_reservation(v_res.id, NULL, 'order cancelled: ' || btrim(p_reason));
            v_freed := v_freed + v_res.qty;
        END LOOP;

        -- 【断言,不是假设】上面那个循环跑完之后【不该】还剩活预留。
        -- 一条 release 悄悄没生效(将来有人给它加了一个提前 RETURN),
        -- 结果是一张作废的单还扣着货 —— 而那件事不会有任何东西报出来。
        SELECT count(*) INTO v_left
          FROM sales_order_reservations r
          JOIN sales_order_lines l ON l.id = r.sales_order_line_id
         WHERE l.sales_order_id = p_order_id AND r.released_at IS NULL AND r.consumed_at IS NULL;
        IF v_left <> 0 THEN
            RAISE EXCEPTION 'SO_CANCEL_RESERVATIONS_LEFT|%|%', v_order.code, v_left;
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

    RETURN jsonb_build_object('id', p_order_id, 'status', p_to,
                              'released_qty', v_freed);
END;
$function$;

CREATE OR REPLACE FUNCTION public.void_invoice(p_invoice_id uuid, p_reason text, p_reversal_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inv invoices%ROWTYPE;
    v_n   int;
    v_rev jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    IF v_inv.status <> 'issued' THEN
        RAISE EXCEPTION 'INVOICE_ALREADY_VOID|%', v_inv.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    IF v_inv.kind = 'order' THEN
        -- 【冲销日必填,永不默认】它决定冲销分录的期间;期间锁/年结闸由
        -- post_journal_entry 对它统一执行(锁住的月份按名拒,不是悄悄挪到今天)。
        IF p_reversal_date IS NULL THEN
            RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
        END IF;
        -- 【有活核销就不作废】核销行不可变、只随收款的冲销失效 —— 先冲收款
        -- (reverse_payment,先例),再作废发票。顺序反过来会留下一堆指着
        -- 已作废单据的活核销。
        SELECT count(*) INTO v_n
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
        WHERE pa.invoice_id = p_invoice_id;
        IF v_n > 0 THEN
            RAISE EXCEPTION 'INVOICE_HAS_SETTLEMENTS|%|%', v_inv.code, v_n;
        END IF;
        -- 【SO-3b:停放的那条检查在这里落地】发货一旦释放过这张票的负债
        -- (部分或全部),冲销就没有足额的 2500 可借 —— 按名拒,更正走
        -- 【贷项凭证】(credit note,sales_records 表头停放的未来概念)。
        -- 判据是【派生】的:这张发票的行上,有没有发出去过的货。不设状态位 ——
        -- 状态位会与真相漂开,而这个问题每次都问得起(与 ship_order 的
        -- SO_SHIP_NOT_INVOICED 同一条)。
        SELECT count(*) INTO v_n
        FROM shipment_lines sl
        JOIN invoice_lines il ON il.sales_order_line_id = sl.sales_order_line_id
        WHERE il.invoice_id = p_invoice_id AND NOT il.invoice_voided;
        IF v_n > 0 THEN
            RAISE EXCEPTION 'INVOICE_SHIPPED_NOT_VOIDABLE|%', v_inv.code;
        END IF;
        v_rev := reverse_journal_entry_internal(v_inv.entry_id, p_reversal_date, 'Void ' || v_inv.code);
    ELSE
        -- sale 头没有分录可冲 —— 收下一个日期再忽略它,是在骗调用方
        -- (record_output_sale 拒 p_fx_rate 的同一条)。
        IF p_reversal_date IS NOT NULL THEN
            RAISE EXCEPTION 'REVERSAL_DATE_NOT_ACCEPTED|%', v_inv.code;
        END IF;
    END IF;

    -- 明细行保留供审计;作废标记由 trg_invoices_propagate_void 同步到明细行,
    -- 行(销售或订单行)随之重新可开票。
    UPDATE invoices
    SET status = 'void',
        void_reason = btrim(p_reason),
        voided_at = now(),
        voided_by = auth.uid()
    WHERE id = p_invoice_id;

    IF v_inv.kind = 'order' THEN
        INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
        VALUES (v_inv.sales_order_id, 'invoice_voided',
                v_inv.code || ' · ' || btrim(p_reason), auth.uid());
    END IF;

    RETURN jsonb_build_object(
        'invoice_id', p_invoice_id,
        'code', v_inv.code,
        'status', 'void',
        'reversal_code', v_rev->>'code');
END;
$function$;

COMMIT;
