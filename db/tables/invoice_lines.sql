-- db/tables/invoice_lines.sql
-- 发票明细行:一行对应一张已存在的 sales_record(发票是"归拢",不是新的应收)。
-- 行内容在开票当刻定死(摘要 = 产出批次编号 + 物料名,数量/单位/单价/金额取自
-- sales_record),即便日后物料改名,重打发票仍是当时寄出的内容。
--
-- 【一张销售只能挂在一张在册发票上,作废后可以重开】—— 落地方式:
--   部分唯一索引的 WHERE 子句不能引用另一张表(void 状态在 invoices 上),
--   所以单靠 invoice_lines 上的索引做不到。这里两条腿一起用:
--   1) 冗余列 invoice_voided,由 invoices 的 AFTER UPDATE 触发器
--      (propagate_invoice_void)自动同步 —— 作废是唯一会改它的路径,不会漂移 ——
--      再对它建部分唯一索引。这是【硬保证】:并发下也不可能让同一张销售挂上两张
--      在册发票。重复开票给客户是真实的账务事故,值得一个索引级的保证,而不是
--      "先查后插"那种带竞态窗口的写法。
--   2) create_invoice 里先做一次友好检查,抛 'ALREADY_INVOICED|sale_code|invoice_code',
--      让用户看到"这张销售已在 INV-xxxx 上",而不是一条原始唯一约束报错。
--   索引负责正确性,函数检查负责可读性。
--
-- IMMUTABLE:INSERT+SELECT RLS + 守卫触发器逐列锁死;唯一例外是触发器写的
-- invoice_voided 标记(故另给一条 UPDATE 策略,列级限制仍由守卫执行)。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut2a-invoices.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.invoice_lines (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id      uuid NOT NULL REFERENCES public.invoices (id) ON DELETE RESTRICT,
    -- SO-3a 起可空:行的来源二选一(XOR 在文末,ALTER 加的列排在末尾)——
    -- sale 头的行指销售记录,order 头的行指订单行;头上的 kind 说了算,
    -- guard_invoice_line_kind 钉住两边一致。
    sales_record_id uuid REFERENCES public.sales_records (id),
    line_no         integer NOT NULL,
    description     text NOT NULL,
    quantity        numeric NOT NULL,
    unit            text NOT NULL,
    unit_price      numeric NOT NULL,
    amount_base      numeric NOT NULL,
    -- 冗余的作废标记,仅供下面的部分唯一索引使用;由 invoices 的触发器维护,
    -- 应用代码不要直接写它。
    invoice_voided  boolean NOT NULL DEFAULT false,
    created_at      timestamptz DEFAULT now(),
    -- INV-1(ALTER 加的列,故排在末尾 —— 与 live 的 attnum 一致):行金额的
    -- 【单据币种】版本。生成列,round(quantity × unit_price, 2),不经汇率,
    -- 所以与 unit_price 天生同币种,既有行由 Postgres 当场算出、无从回填错。
    -- 客户账单印它;amount_base 是同一行的本位币金额,给账用。
    amount_ccy      numeric GENERATED ALWAYS AS (round(quantity * unit_price, 2)) STORED,
    -- ── SO-3a 追加(ALTER 加的列排在末尾)──────────────────────────────────
    -- 订单流发票的行指向【订单行】—— 开票时销售记录还不存在(发货才产生它)。
    sales_order_line_id uuid REFERENCES public.sales_order_lines (id),
    -- ── GST-2 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 【税码与税率在开票那一刻【冻在行上】】一张已开出的发票永远不按今天的设置
    -- 重算它的税 —— 与已承诺的价格条款同一条规矩。2022 年那张票永远是 7%。
    -- F5 的 box1/box2/box3 从 tax_code 推导、box6 从 tax_base 推导,
    -- 而【期间由 invoices.issue_date 决定】:新加坡的税点是开票日,不是销售日。
    tax_code        text REFERENCES public.tax_codes (code),
    tax_rate_pct    numeric,
    tax_base        numeric NOT NULL DEFAULT 0,
    UNIQUE (invoice_id, line_no),
    CONSTRAINT invoice_lines_one_source CHECK (num_nonnulls(sales_record_id, sales_order_line_id) = 1),
    -- 【三列是一件事,不是三件】要么整套有,要么整套没有 —— 一个有税码却没有
    -- 税率的行,报得出格却算不出税。
    CONSTRAINT invoice_lines_tax_shape CHECK (
        (tax_code IS NULL     AND tax_rate_pct IS NULL     AND tax_base = 0)
     OR (tax_code IS NOT NULL AND tax_rate_pct IS NOT NULL AND tax_base >= 0))
);

CREATE INDEX idx_invoice_lines_invoice ON public.invoice_lines (invoice_id);
CREATE INDEX idx_invoice_lines_sale ON public.invoice_lines (sales_record_id);

-- 硬保证:一张销售最多出现在一张未作废的发票上
CREATE UNIQUE INDEX uq_invoice_lines_live_sale
    ON public.invoice_lines (sales_record_id)
    WHERE NOT invoice_voided;

CREATE INDEX idx_invoice_lines_order_line ON public.invoice_lines (sales_order_line_id);

-- SO-3a:同一条硬保证的订单侧 —— 一条订单行最多挂在一张未作废的【订单流】发票上,
-- 索引负责正确性、create_order_invoice 的 SO_LINE_ALREADY_INVOICED 负责可读性,
-- 与销售侧逐字同一个分工。【部分开票(一行分几张发票开)是被这个索引明确挡住的】:
-- 要做它,先回答"行的已开金额记在哪、发货释放负债时按哪张发票的比例" —— 那是一个
-- 形状决定;放开这个索引而不回答它,得到的是两张发票对同一行各自记全额。
-- 要加部分开票的人,从这里开始。
CREATE UNIQUE INDEX uq_invoice_lines_live_order_line
    ON public.invoice_lines (sales_order_line_id)
    WHERE NOT invoice_voided;

CREATE OR REPLACE FUNCTION public.guard_invoice_line_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    IF NEW.id              IS DISTINCT FROM OLD.id
       OR NEW.invoice_id      IS DISTINCT FROM OLD.invoice_id
       OR NEW.sales_record_id IS DISTINCT FROM OLD.sales_record_id
       OR NEW.line_no         IS DISTINCT FROM OLD.line_no
       OR NEW.description     IS DISTINCT FROM OLD.description
       OR NEW.quantity        IS DISTINCT FROM OLD.quantity
       OR NEW.unit            IS DISTINCT FROM OLD.unit
       OR NEW.unit_price      IS DISTINCT FROM OLD.unit_price
       OR NEW.amount_base      IS DISTINCT FROM OLD.amount_base
       OR NEW.sales_order_line_id IS DISTINCT FROM OLD.sales_order_line_id
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_invoice_lines_immutable
    BEFORE UPDATE OR DELETE ON public.invoice_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_invoice_line_mutation();

-- SO-3a:行的来源必须与头上的 kind 一致 —— XOR 只保证"恰一个",说不出"是对的
-- 那一个"。invoice_lines 有面向客户端的 INSERT 策略(cut 2a 的遗留),所以这条
-- 一致性不能只靠两个建票函数自觉(函数在 db/functions/guard_invoice_line_kind.sql)。
CREATE TRIGGER trg_invoice_lines_kind
    BEFORE INSERT ON public.invoice_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_invoice_line_kind();

ALTER TABLE public.invoice_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "invoice_lines select by permission"
    ON public.invoice_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "invoice_lines insert by permission"
    ON public.invoice_lines
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "invoice_lines update by permission"
    ON public.invoice_lines
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 invoice_lines_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.invoice_lines FROM authenticated, anon;
GRANT SELECT (id, invoice_id, sales_record_id, line_no, description, quantity, unit, invoice_voided, created_at)
    ON public.invoice_lines TO authenticated;
-- SO-3a:订单行引用非敏感,进列清单(colgrant)。
GRANT SELECT (sales_order_line_id)
    ON public.invoice_lines TO authenticated;

-- FIN-1a:改名列的注释(说明写在数据库里,重建出来的库也带着)
COMMENT ON COLUMN public.invoice_lines.amount_base IS '本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。';
COMMENT ON COLUMN public.invoice_lines.amount_ccy IS '行金额,【单据币种】(INV-1)。= round(quantity × unit_price, 2),不经汇率,所以与 unit_price 天然同币种。客户账单上那一列印的就是它;amount_base 是同一行的【本位币】金额,给账用 —— 两者只在汇率为 1 时相等,把后者标成前者正是 INV-1 修掉的错。';

-- ★【GST-2:开关关着时,这张表上写不进税码】★
-- GST-1 把这条保证放在 post_journal_entry 上,那时 F5 九格全部从总账推导。
-- **GST-2 之后那句不再成立**:box1 改从本表推导,一个盖在这里的税码
-- 【根本不经过总账】就能让 F5 不为零 —— 一道只守旧路径的闸,
-- 在新路径开通的那一刻就不再是闸了。所以保证跟着搬过来。
CREATE TRIGGER trg_invoice_lines_tax_code_registered
    BEFORE INSERT OR UPDATE OF tax_code ON public.invoice_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_document_tax_code();

COMMENT ON COLUMN public.invoice_lines.tax_code IS
    'GST-2:这一行在 GST 上是什么性质,【开票那一刻冻在行上】。F5 的 box1/box2/box3 从这一列推导 —— 税点是开票日,所以供应额的期间由 invoices.issue_date 决定,不由销售日决定。';
COMMENT ON COLUMN public.invoice_lines.tax_rate_pct IS
    'GST-2:开票日经 tax_rate_for(code, invoices.issue_date) 解析出来的税率,【抄下来冻住】。一张已开出的发票永远不按今天的设置重算它的税 —— 与已承诺的价格条款同一条规矩。2022 年那张票永远是 7%。';
