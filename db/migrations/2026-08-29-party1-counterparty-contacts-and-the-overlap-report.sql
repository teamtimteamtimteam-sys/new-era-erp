-- PARTY-1:对手方联系人子表 + 客户主数据的一处【编造】+ 一方两身的【报告】
--
-- 【本刀不建 parties 主表 —— 而这是一个裁定,不是一个遗漏】(Tim 2026-08-29,A2)
--   GO-4 自己的记录(known-issues 的 COUNTERPARTY-ONE-PARTY)写着:那是一次
--   迁移加一轮全模块复核,返回条件是【批量导入那一刀】。而实测线上
--   customers 的 tax_id 是【0 个】,所以一张 parties 主表今天会为【零行】
--   服务。**一次开了头又放下的结构改动,比一份诚实的报告坏。**
--   队列那一条【改写,不划掉】——「一件看起来相关的东西上线了就划掉一条队列,
--   正是队列开始说谎的方式」(GLEXPORT-1 立的规矩)。
--
-- 【三件事,顺序有讲究】
--   ① 建 counterparty_contacts,并把 customers 那三列【搬进去】;
--   ② 两支开票函数改成从主联系人取快照,并把【编出来的 30 天账期】换成按名拒;
--   ③ 建重叠报告(带分母,好让"0 条"说得出它是哪一种 0)。
--   ①必须在②之前:②要读的表得先存在。删列必须在②之后:
--   函数体里还引用着 v_cust.contact_person,先删列会让 CREATE OR REPLACE 失败。

BEGIN;
-- ═══ ① counterparty_contacts ═══════════════════════════════════════════
-- db/tables/counterparty_contacts.sql
-- PARTY-1:一个对手方的【联系人们】—— 一张表同时服务客户与供应商。
--
-- ★★【它【不是】一方两身那个结构 —— 这句话写在最前面,因为它最容易被误读】★★
--   这张表让【一张表】同时服务客户与供应商,但它**不把某个客户与某个供应商连起来**。
--   一行只属于一边(下面那条 CHECK 逼着),两边之间没有任何指针。
--   「同一家公司既是供应商又是客户」仍然是一个**没有被结构回答**的问题 ——
--   见 docs/known-issues.md 的 COUNTERPARTY-ONE-PARTY,以及 PARTY-1 只做的那份
--   【重叠报告】(counterparty_overlap_report)。
--   **下一个读到这张表的人很容易得出"一方两身已经解决了"的结论,而那是错的。**
--
-- 【为什么是一张表而不是两张】(Tim 2026-08-29 裁定 A6)
--   这是本刀里唯一一处"把对手方当成一个概念"而【不需要付结构代价】的地方:
--   一行的归属由 exactly-one CHECK 钉死,读权按归属那一侧判。
--   好处是将来真的建 parties 主表时,**要重新指向的是一张表,不是两张**。
--
-- 【为什么客户那三列被【搬走并删掉】,而不是留着】(A1)
--   customers.contact_person / email / phone 是 2026-07-31 加的单列。
--   留着 = 同一个事实两个地方,而本仓库为"两份实现在写下来那天一致、之后
--   悄悄分家"付过四次账。所以搬走、删掉,**这张表是唯一的真源**。
--
-- ★【一件【不受影响】的事,说出来免得被误伤:已经开出去的发票】★
--   invoices.bill_to_snapshot 是一份 jsonb 快照,它记的是【开票那一刻】
--   billed to 的是谁。**它自成一体,本刀一个字节都不动它** ——
--   变的只是【下一张】发票的快照从哪儿取(改为取本表里 is_primary 的那一行)。
--   与 FIN-27 的已承诺条款、customer_statements、collection_chases 同一条:
--   **发出去的东西不因主数据后来变了而改写。**
--
-- ★【collection_chases.contacted_person 【仍然是纯文本】,而且必须是】★
--   一次催收是一行【不可变】的事件,记的是"那天我们接触到了谁"。
--   把它改成指向本表的外键,就意味着**删掉或改名一个联系人会改写一件发生过的事**
--   —— 甚至让那一行指向一个已删的联系人。所以那一列不动:
--   界面可以从本表【提供候选】,而选中的名字按【文本】抄过去。
--   同一条抄写规矩:先例是 bill_to_snapshot 与 FIN-27。
--

CREATE TABLE public.counterparty_contacts (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 【归属:恰好一边】两个都填或都不填,都是"这一行属于谁"没有答案。
    customer_id    uuid REFERENCES public.customers (id) ON DELETE RESTRICT,
    supplier_id    uuid REFERENCES public.suppliers (id) ON DELETE RESTRICT,
    -- 【名字必填,而且不许是空白】一个没有名字的联系人在列表里读起来是"没有人";
    -- 具名的缺席才是缺席,空白不是。
    name           text NOT NULL CHECK (btrim(name) <> ''),
    -- ★【这个名字是【推出来的】,不是人写的】★ 迁移时遇到"有邮箱没名字"的行,
    --   不丢、也不留空,而是从邮箱本地部分派生一个名字,并把这一列标 true。
    --   读的人于是知道这三个字不是对方自报的姓名,而是系统凑出来的。
    name_inferred  boolean NOT NULL DEFAULT false,
    -- 职能(应付、采购、物流……)。自由文本:各家公司的叫法不一样,
    -- 而一个猜出来的枚举会逼着人把真实职能塞进最近的那一格。
    role           text,
    email          text,
    phone          text,
    -- 【主联系人:开票快照取的就是这一行】每一个对手方最多一个,由下面的
    -- 部分唯一索引钉死(软删的行不算)。
    is_primary     boolean NOT NULL DEFAULT false,
    notes          text,
    deleted_at     timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid,
    -- ★ 恰好属于一边。写成 num_nonnulls 而不是两条 OR,是因为它对
    --   "两个都填"与"两个都不填"给出同一句拒绝,而那正是同一个错误。
    CONSTRAINT counterparty_contacts_exactly_one_owner
        CHECK (num_nonnulls(customer_id, supplier_id) = 1),
    -- 【至少要有一条够得着人的路】只有名字、没有邮箱也没有电话的"联系人",
    -- 在催收或开票的场景里帮不上任何忙。空字符串在写入路径上落成 NULL(见函数)。
    CONSTRAINT counterparty_contacts_reachable
        CHECK (email IS NOT NULL OR phone IS NOT NULL)
);

-- 每个对手方最多一个主联系人(软删的不算)。
CREATE UNIQUE INDEX counterparty_contacts_one_primary_customer
    ON public.counterparty_contacts (customer_id)
    WHERE is_primary AND deleted_at IS NULL AND customer_id IS NOT NULL;
CREATE UNIQUE INDEX counterparty_contacts_one_primary_supplier
    ON public.counterparty_contacts (supplier_id)
    WHERE is_primary AND deleted_at IS NULL AND supplier_id IS NOT NULL;

CREATE INDEX idx_counterparty_contacts_customer
    ON public.counterparty_contacts (customer_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_counterparty_contacts_supplier
    ON public.counterparty_contacts (supplier_id) WHERE deleted_at IS NULL;

ALTER TABLE public.counterparty_contacts ENABLE ROW LEVEL SECURITY;

-- 【读权按【归属那一侧】判,不是一个笼统的"对手方"权限】
-- 一个只做采购的人看得到供应商的联系人,看不到客户的 —— 反之亦然。
CREATE POLICY "counterparty contacts select by owner permission"
    ON public.counterparty_contacts
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
        OR (supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)));
-- 【没有 INSERT / UPDATE / DELETE 策略】唯一写入口是 save_counterparty_contact
-- (SECURITY DEFINER)。理由与 collection_chases、折旧锚点同一条:
-- "把某一行设成主联系人"要在【一笔事务】里把上一个主联系人撤掉,
-- 而两条直连写入之间的那道缝会撞上部分唯一索引 —— 或者更坏,静静地留下两个主。

COMMENT ON TABLE public.counterparty_contacts IS
    'PARTY-1:一个对手方的联系人们 —— 一张表同时服务客户与供应商,一行只属于一边(num_nonnulls CHECK)。★**它不是一方两身那个结构**:它不把任何客户与任何供应商连起来,「同一家公司既是供应商又是客户」仍然只有一份【报告】(counterparty_overlap_report),没有结构上的答案 —— 见 docs/known-issues.md 的 COUNTERPARTY-ONE-PARTY。一张表而不是两张,是为了将来真建 parties 主表时只有一张表要重新指向。customers 的 contact_person/email/phone 三列已【搬进来并删掉】,本表是唯一真源。**已开出的发票不受影响**:bill_to_snapshot 是自成一体的 jsonb 快照,记的是开票那一刻的事实;变的只是下一张发票从本表的 is_primary 行取。**collection_chases.contacted_person 仍是纯文本且必须是**:那是一行不可变的事件,改成外键就意味着删一个联系人会改写一件发生过的事。';

COMMENT ON COLUMN public.counterparty_contacts.name_inferred IS
    'PARTY-1:这个名字是【系统从邮箱本地部分凑出来的】,不是对方自报的。迁移时"有邮箱、没名字"的行走这一支 —— 不丢(那会丢掉唯一一条够得着人的路),也不留空(空白在列表里读起来是"没有人")。读的人据此知道这三个字的来路。';

COMMENT ON COLUMN public.counterparty_contacts.is_primary IS
    'PARTY-1:开票快照(create_invoice / create_order_invoice 的 bill_to_snapshot)取的就是这一行。每个对手方最多一个,由部分唯一索引钉死(软删的不算)。没有主联系人不是错误 —— 快照里那三个键会是 NULL,与本刀之前"客户没填联系人"的效果逐字一致。';

-- ═══ ①b 把 customers 那三列搬进来 ═══════════════════════════════════════
-- ★【"有邮箱、没名字"怎么办 —— 不丢,也不留空】★(Tim 2026-08-29 裁定 A1)
--   丢掉 = 丢掉唯一一条够得着这个人的路;留空 = 名单里一行没有名字的联系人,
--   而**空白在名单里读起来就是「没有人」**。所以从邮箱本地部分派生一个名字,
--   并把 name_inferred 标 true —— 读的人于是知道这三个字的来路。
--   实测:线上只有【一行】会走到这一支之外(CUS-2026-0002:Mike /
--   mike.tan@stengineering.com,名字与邮箱都有),派生那一支今天【0 行】命中。
--   写出来是因为它是一条规则,不是一次数据清洗:下一次导入就会用到它。
INSERT INTO public.counterparty_contacts
    (customer_id, name, name_inferred, email, phone, is_primary, notes)
SELECT c.id,
       COALESCE(
           NULLIF(btrim(c.contact_person), ''),
           -- 派生:取邮箱 @ 之前那一段,把 . _ - 换成空格
           initcap(replace(replace(replace(split_part(c.email, '@', 1), '.', ' '), '_', ' '), '-', ' ')),
           '?'),
       (NULLIF(btrim(c.contact_person), '') IS NULL),
       NULLIF(btrim(c.email), ''),
       NULLIF(btrim(c.phone), ''),
       true,           -- 搬过来的这一行就是主联系人:它本来就是"那个联系人"
       'PARTY-1 migrated from customers.contact_person/email/phone (2026-08-29)'
  FROM public.customers c
 WHERE c.deleted_at IS NULL
   -- 【至少要有一条够得着人的路】只有名字、没有邮箱也没有电话的,搬过去会撞
   -- counterparty_contacts_reachable 那条 CHECK —— 而那条 CHECK 是对的:
   -- 那样一行在开票或催收时帮不上任何忙。实测线上这样的行是 0 行。
   AND (NULLIF(btrim(c.email), '') IS NOT NULL OR NULLIF(btrim(c.phone), '') IS NOT NULL);

-- 【搬不过去的行要被【看见】,不能静静消失】
DO $$
DECLARE v_left integer;
BEGIN
    SELECT count(*) INTO v_left FROM public.customers c
     WHERE c.deleted_at IS NULL
       AND NULLIF(btrim(c.contact_person), '') IS NOT NULL
       AND NULLIF(btrim(c.email), '') IS NULL
       AND NULLIF(btrim(c.phone), '') IS NULL;
    IF v_left > 0 THEN
        RAISE EXCEPTION 'PARTY1_MIGRATION_WOULD_DROP_CONTACTS|%', v_left;
    END IF;
    RAISE NOTICE 'PARTY-1 迁移:counterparty_contacts 现有 % 行', (SELECT count(*) FROM public.counterparty_contacts);
END $$;

-- ═══ ② 两支开票函数:快照取主联系人 + 账期不再编 ══════════════════════
-- db/functions/create_invoice.sql
-- GST-2(2026-08-25):发票开始【携带税】,并过一张【只有税】的分录。
-- 此前它读 finance_settings.gst_rate_pct 这个标量算税、且一张分录都不过。
-- 标量表达不了税率史(2022 年那张票永远是 7%),也表达不了零税率 / 豁免 /
-- 不在范围内这三件税率都为零、进的格子却完全不同的事。
-- 【分录只过税】收入在【销售】那一刻已经认过(借 1100 / 贷 4000);
-- 开票再认一次就是把同一笔生意记两遍。而税从来没有人过过 ——
-- invoices.total_base 一直写着 subtotal + tax,这张分录是第一次在总账里兑现它。
-- 【税码与税率冻在行上】已开出的发票永不按今天的设置重算它的税。
CREATE OR REPLACE FUNCTION public.create_invoice(p_customer_id uuid, p_sales_record_ids uuid[], p_issue_date date DEFAULT NULL::date, p_payment_terms_days integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text, p_terms_text text DEFAULT NULL::text, p_tax_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cust        customers%ROWTYPE;
    -- PARTY-1:开票快照里的联系人 —— 取本客户的【主联系人】那一行
    v_contact     counterparty_contacts%ROWTYPE;
    v_issue       date := COALESCE(p_issue_date, CURRENT_DATE);
    v_terms       integer;
    v_due         date;
    v_invoice_id  uuid := gen_random_uuid();
    v_year        integer;
    v_seq         integer;
    v_code        text;
    v_sale_id     uuid;
    v_seen        uuid[] := ARRAY[]::uuid[];
    v_sale        record;
    v_currency    text;
    v_no          integer := 0;
    v_subtotal    numeric := 0;
    v_tax_code    text;
    v_tax_rate    numeric := 0;
    v_tax         numeric := 0;
    v_line_tax    numeric;
    v_existing    text;
    v_base        text;
    v_je          jsonb;
    v_entry_id    uuid;
    v_lines       jsonb := '[]'::jsonb;  -- 第一趟收集,第二趟落库
    v_line        jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    -- 1. 客户
    SELECT * INTO v_cust FROM customers
    WHERE id = p_customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;

    -- PARTY-1:主联系人。**没有也不拒绝** —— 一张开给没填联系人的客户的发票
    -- 一直都是合法的,本刀不顺手把它变成一道新闸(那会是一次没人裁定过的收紧)。
    -- 没有时 v_contact 的三个字段是 NULL,快照里那三个键就是 NULL。
    SELECT * INTO v_contact FROM counterparty_contacts
     WHERE customer_id = v_cust.id AND is_primary AND deleted_at IS NULL;

    IF p_sales_record_ids IS NULL OR array_length(p_sales_record_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- ★★【2. 账期:显式 > 客户设定 > 【按名拒】—— 原来这里兜底 30 天】★★
    --   **PARTY-1(2026-08-29)把那个 30 拿掉了,而它不是一个装饰性的默认值。**
    --   实测:线上三个客户 payment_terms_days 全是 NULL,于是【九张发票无一例外】
    --   带着一个编出来的 30 天账期 —— 而 due_date 喂着 ar_aging_asof、
    --   customer_statement_data(对账单【与】催收,催收还把它冻起来)与
    --   cash_forecast_data。**一个编出来的到期日于是同时进了四个看起来权威的地方。**
    --   这是 FIN-10 那条规矩换了身衣服:那条说"决定期间的【日期】不许有默认值",
    --   这里是"决定到期日的【账期】不许有默认值"。
    --   【为什么不回填】把 30 写进客户主数据,就是把我的猜测变成一条永久的、
    --   而且再也标不出来的事实。已经开出去的九张单【保留】它们的 30 ——
    --   那是当时发出去的东西,历史不改写。
    v_terms := COALESCE(p_payment_terms_days, v_cust.payment_terms_days);
    IF v_terms IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_PAYMENT_TERMS_NOT_SET|%|%', v_cust.code, v_cust.legal_name
          USING HINT = '这张发票的到期日没有来路:客户主数据里没有付款账期,这次调用也没有给一个。去【客户 → 编辑】把「付款账期(天)」填上,或者在开票时明确指定一个 —— 系统不再替你假设 30 天。';
    END IF;
    IF v_terms < 0 THEN
        RAISE EXCEPTION 'TERMS_INVALID|%', v_terms;
    END IF;
    v_due := v_issue + v_terms;

    -- ════════════════════════════════════════════════════════════════════════
    -- 3. 【税点在这里】GST-2:税码经"往来对象默认 + 本单改写"解析,
    --    税率按【这张发票自己的开票日】解析 —— 两者一起冻在行上。
    -- ════════════════════════════════════════════════════════════════════════
    IF gst_registered() THEN
        v_tax_code := resolve_tax_code(p_tax_code, v_cust.default_tax_code, 'output', 'customer');
        v_tax_rate := tax_rate_for(v_tax_code, v_issue);
    ELSE
        -- 【未注册:与建 GST 之前一模一样】不解析、不盖码、不过分录。
        -- 【但传了码要按名拒,不能悄悄忽略】悄悄忽略会让一个以为自己在计税的人
        -- 以为计了 —— 而屏幕上一切正常。
        IF NULLIF(btrim(COALESCE(p_tax_code, '')), '') IS NOT NULL THEN
            RAISE EXCEPTION 'GST_NOT_REGISTERED|%', p_tax_code;
        END IF;
        v_tax_code := NULL;
        v_tax_rate := 0;
    END IF;

    -- 4. 无缝编号(按 issue_date 的年份),咨询锁串行化;回滚即释放号码
    v_year := EXTRACT(YEAR FROM v_issue)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('invoice_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM invoices
    WHERE code LIKE 'INV-' || v_year::text || '-%';
    v_code := 'INV-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 5. 第一趟:逐张销售校验(存在 → 归属 → 未被占用 → 币种一致)并累计金额。
    FOREACH v_sale_id IN ARRAY p_sales_record_ids
    LOOP
        IF v_sale_id = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_SALE|%',
                COALESCE((SELECT ob.code FROM sales_records sr
                          JOIN output_batches ob ON ob.id = sr.output_batch_id
                          WHERE sr.id = v_sale_id), v_sale_id::text);
        END IF;
        v_seen := v_seen || v_sale_id;

        SELECT sr.id, sr.customer_id, sr.quantity, sr.unit_price, sr.currency,
               sr.amount_base, ob.code AS batch_code, ob.unit, m.name AS material_name
        INTO v_sale
        FROM sales_records sr
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        LEFT JOIN materials m ON m.id = ob.material_id
        WHERE sr.id = v_sale_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'SALE_NOT_FOUND|%', v_sale_id;
        END IF;

        -- sales_records.customer_id 可空 —— 批次可能在客户还没登记时就卖了。
        -- SAL-C:【但无主的销售不能开给客户】。开票是对外声称"这个人欠这笔钱";
        -- 声称之前,销售自己得先记下这件事。出路是先补挂
        -- (attribute_sale_customer),不是在这里默认它属于收票人。
        IF v_sale.customer_id IS NULL THEN
            RAISE EXCEPTION 'SALE_NOT_ATTRIBUTED|%', v_sale.batch_code;
        END IF;
        IF v_sale.customer_id <> p_customer_id THEN
            RAISE EXCEPTION 'SALE_WRONG_CUSTOMER|%', v_sale.batch_code;
        END IF;

        SELECT i.code INTO v_existing
        FROM invoice_lines il
        JOIN invoices i ON i.id = il.invoice_id
        WHERE il.sales_record_id = v_sale_id AND NOT il.invoice_voided
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'ALREADY_INVOICED|%|%', v_sale.batch_code, v_existing;
        END IF;

        IF v_currency IS NULL THEN
            v_currency := v_sale.currency;
        ELSIF v_currency <> v_sale.currency THEN
            RAISE EXCEPTION 'MIXED_CURRENCY|%|%', v_currency, v_sale.currency;
        END IF;

        -- 【逐行算税、逐行取整,行加起来就是表头】口径与行金额一致:
        -- 表头的税 = Σ 行税,不是 round(Σ 行净额 × 税率) —— 两种算法差几分,
        -- 而客户手里那张纸上印的是行。
        v_line_tax := CASE WHEN v_tax_code IS NULL THEN 0
                           ELSE round(v_sale.amount_base * v_tax_rate / 100.0, 2) END;

        v_no := v_no + 1;
        v_lines := v_lines || jsonb_build_object(
            'sales_record_id', v_sale_id,
            'line_no', v_no,
            'description', v_sale.batch_code || COALESCE(' — ' || v_sale.material_name, ''),
            'quantity', v_sale.quantity,
            'unit', v_sale.unit,
            'unit_price', v_sale.unit_price,
            'amount_base', v_sale.amount_base,
            'tax_base', v_line_tax);

        v_subtotal := v_subtotal + v_sale.amount_base;
        v_tax := v_tax + v_line_tax;
    END LOOP;

    v_subtotal := round(v_subtotal, 2);
    v_tax := round(v_tax, 2);

    -- ════════════════════════════════════════════════════════════════════════
    -- 6. 【只过税的那张分录】借 1100 应收 / 贷 2100 销项税。
    --    零税率 / 豁免 / 不在范围内(税额为 0)不过分录 —— 一条 0 的腿在分录上
    --    读起来像"这一段发生了但金额为零",而且 post_journal_entry 会拒。
    --    供应额本身【不在这张分录里】,它在发票行上;F5 的 box1 从那里推导。
    --    期间锁与年结闸由 post_journal_entry 对 v_issue 统一执行。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_tax <> 0 THEN
        v_je := post_journal_entry(
            v_issue,
            'Invoice ' || v_code || ' GST',
            'invoice', v_invoice_id,
            jsonb_build_array(
                jsonb_build_object('account_code', '1100', 'side', 'debit',
                    'currency', v_base, 'amount_ccy', v_tax,
                    'line_memo', 'output tax ' || v_tax_code),
                jsonb_build_object('account_code', '2100', 'side', 'credit',
                    'currency', v_base, 'amount_ccy', v_tax,
                    'line_memo', 'output tax ' || v_tax_code)));
        v_entry_id := (v_je->>'entry_id')::uuid;
    END IF;

    -- 7. 第二趟:金额已定,一次写对发票头,再落明细行。
    INSERT INTO invoices (id, code, customer_id, issue_date, due_date, payment_terms_days,
                          currency, subtotal_base, tax_rate_pct, tax_base, total_base,
                          notes, terms_text, bill_to_snapshot, entry_id)
    VALUES (v_invoice_id, v_code, p_customer_id, v_issue, v_due, v_terms,
            v_currency, v_subtotal, v_tax_rate, v_tax, round(v_subtotal + v_tax, 2),
            p_notes, p_terms_text,
            jsonb_build_object(
                'code', v_cust.code,
                'legal_name', v_cust.legal_name,
                'short_name', v_cust.short_name,
                'country', v_cust.country,
                'tax_id', v_cust.tax_id,
                'address', v_cust.address,
                'payment_terms', v_cust.payment_terms,
                'incoterm', v_cust.incoterm,
                -- ★【联系人从 counterparty_contacts 的【主联系人】取,不再从客户那三列取】★
                --   PARTY-1 把那三列搬进了子表并删掉。**已经存下来的快照不受影响**:
                --   它们是自成一体的 jsonb,记的是开票那一刻的事实 —— 变的只是
                --   【下一张】发票从哪儿取。没有主联系人时这三个键是 NULL,
                --   与本刀之前"客户没填联系人"的效果逐字一致。
                'contact_person', v_contact.name,
                'email', v_contact.email,
                'phone', v_contact.phone),
            v_entry_id);

    FOR v_line IN SELECT * FROM jsonb_array_elements(v_lines)
    LOOP
        INSERT INTO invoice_lines (invoice_id, sales_record_id, line_no, description,
                                   quantity, unit, unit_price, amount_base,
                                   tax_code, tax_rate_pct, tax_base)
        VALUES (v_invoice_id,
                (v_line->>'sales_record_id')::uuid,
                (v_line->>'line_no')::integer,
                v_line->>'description',
                (v_line->>'quantity')::numeric,
                v_line->>'unit',
                (v_line->>'unit_price')::numeric,
                (v_line->>'amount_base')::numeric,
                v_tax_code,
                CASE WHEN v_tax_code IS NULL THEN NULL ELSE v_tax_rate END,
                (v_line->>'tax_base')::numeric);
    END LOOP;

    RETURN jsonb_build_object(
        'invoice_id', v_invoice_id,
        'code', v_code,
        'issue_date', v_issue,
        'due_date', v_due,
        'subtotal_base', v_subtotal,
        'tax_code', v_tax_code,
        'tax_rate_pct', v_tax_rate,
        'tax_base', v_tax,
        'total_base', round(v_subtotal + v_tax, 2),
        'line_count', v_no,
        'currency', v_currency,
        'journal_code', v_je->>'code'
    );
END;
$function$
;
CREATE OR REPLACE FUNCTION public.create_order_invoice(p_sales_order_id uuid, p_issue_date date, p_payment_terms_days integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text, p_terms_text text DEFAULT NULL::text, p_line_ids uuid[] DEFAULT NULL::uuid[], p_tax_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order    sales_orders%ROWTYPE;
    v_cust     customers%ROWTYPE;
    -- PARTY-1:开票快照里的联系人 —— 取本客户的【主联系人】那一行
    v_contact     counterparty_contacts%ROWTYPE;
    v_terms    integer;
    v_due      date;
    v_invoice_id uuid := gen_random_uuid();
    v_year     integer;
    v_seq      integer;
    v_code     text;
    v_line     record;
    v_no       integer := 0;
    v_sub_ccy  numeric := 0;
    v_sub_base numeric;
    v_tax_code text;
    v_tax_rate numeric := 0;
    v_tax      numeric := 0;      -- 单据币种
    v_tax_base numeric := 0;      -- 本位币
    v_line_tax numeric;
    v_existing text;
    v_exposure numeric;
    v_lines    jsonb := '[]'::jsonb;
    v_l        jsonb;
    v_je       jsonb;
    v_bad      int;
BEGIN
    -- 【权限:module.finance.edit,与 create_invoice 同一个码 —— 想过 B4(b) 那条路】
    -- "检查正在做的那件事"的规矩会指向 module.sales.edit(开票是订单流的一步);
    -- 但同一种单据(invoices)由两个码把门,是给下一个人埋的判断分叉 —— sale 头
    -- 已经是 finance.edit,而这张票【过账】,比 sale 头更财务而不是更不。
    -- 订单页上的按钮按持码与否显示/受限,不把人骗去撞一次拒绝。
    PERFORM require_permission('module.finance.edit');

    -- 【开票日必填 —— 它决定分录期间】sale 头的默认今天记录在
    -- docs/empty-string-to-rpc-audit.md(那种发票不过账);这张过账,按日期规矩拒。
    IF p_issue_date IS NULL THEN
        RAISE EXCEPTION 'INVOICE_DATE_REQUIRED';
    END IF;

    SELECT * INTO v_order FROM sales_orders WHERE id = p_sales_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_id::text, '?');
    END IF;
    -- 【只对确认单开票】草稿还不是承诺;作废/关闭的单没有可开的东西。
    -- 【SO-3b:partially_shipped 同样算数】发了一部分的单仍然是活的,剩下的行
    -- 还要开票才发得出去 —— 与 reserve_stock 同一条(fixture 68 撞出来的)。
    IF v_order.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SO_INVOICE_ORDER_NOT_CONFIRMED|%|%', v_order.code, v_order.status;
    END IF;

    -- 【客户是订单的客户,不是参数】—— 让开票替人改收票方,就是 SAL-C 修掉的
    -- 那种归属错位的反向版本。
    SELECT * INTO v_cust FROM customers WHERE id = v_order.customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', v_order.customer_id;
    END IF;

    -- PARTY-1:主联系人。**没有也不拒绝** —— 一张开给没填联系人的客户的发票
    -- 一直都是合法的,本刀不顺手把它变成一道新闸(那会是一次没人裁定过的收紧)。
    -- 没有时 v_contact 的三个字段是 NULL,快照里那三个键就是 NULL。
    SELECT * INTO v_contact FROM counterparty_contacts
     WHERE customer_id = v_cust.id AND is_primary AND deleted_at IS NULL;

    -- ★【账期不再兜底 30 天 —— 见 create_invoice 同一处的长注释】★
    --   两扇门必须同时改:只改一扇,那个编出来的到期日会从另一扇原样走出来,
    --   而两扇门都通向同一张 invoices 表(「闸要拦在今天所有的入口上」)。
    v_terms := COALESCE(p_payment_terms_days, v_cust.payment_terms_days);
    IF v_terms IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_PAYMENT_TERMS_NOT_SET|%|%', v_cust.code, v_cust.legal_name
          USING HINT = '这张发票的到期日没有来路:客户主数据里没有付款账期,这次调用也没有给一个。去【客户 → 编辑】把「付款账期(天)」填上,或者在开票时明确指定一个 —— 系统不再替你假设 30 天。';
    END IF;
    IF v_terms < 0 THEN
        RAISE EXCEPTION 'TERMS_INVALID|%', v_terms;
    END IF;
    v_due := p_issue_date + v_terms;

    -- 【显式子集必须整个属于这张单】—— 混进别的单的行 id,静默跳过等于把
    -- "开了哪些行"变成猜测。
    IF p_line_ids IS NOT NULL THEN
        SELECT count(*) INTO v_bad FROM unnest(p_line_ids) x
         WHERE NOT EXISTS (SELECT 1 FROM sales_order_lines l
                            WHERE l.id = x AND l.sales_order_id = p_sales_order_id);
        IF v_bad > 0 THEN
            RAISE EXCEPTION 'SO_INVOICE_LINE_INVALID|%|%', v_order.code, v_bad;
        END IF;
    END IF;

    FOR v_line IN
        SELECT l.id, l.line_no AS order_line_no, l.quantity, l.unit_price,
               m.code AS mat_code, m.name AS mat_name, m.unit AS mat_unit
        FROM sales_order_lines l
        JOIN materials m ON m.id = l.material_id
        WHERE l.sales_order_id = p_sales_order_id
          AND (p_line_ids IS NULL OR l.id = ANY (p_line_ids))
        ORDER BY l.line_no
    LOOP
        -- 友好检查;硬保证是 uq_invoice_lines_live_order_line(索引管正确性,
        -- 这里管可读性 —— 与销售侧 ALREADY_INVOICED 逐字同一个分工)。
        SELECT i.code INTO v_existing
        FROM invoice_lines il
        JOIN invoices i ON i.id = il.invoice_id
        WHERE il.sales_order_line_id = v_line.id AND NOT il.invoice_voided
        LIMIT 1;
        IF FOUND THEN
            IF p_line_ids IS NULL THEN
                CONTINUE;   -- "全部未开"的口径:已开的行自然跳过
            END IF;
            -- 点名要求开一条已开的行 → 按名拒,说出它在哪张票上
            RAISE EXCEPTION 'SO_LINE_ALREADY_INVOICED|%|%', v_line.order_line_no, v_existing;
        END IF;

        v_no := v_no + 1;
        v_lines := v_lines || jsonb_build_object(
            'sales_order_line_id', v_line.id,
            'line_no', v_no,
            'description', v_line.mat_code || ' — ' || v_line.mat_name,
            'quantity', v_line.quantity,
            'unit', v_line.mat_unit,
            'unit_price', v_line.unit_price,
            'amount_ccy', round(v_line.quantity * v_line.unit_price, 2));
        v_sub_ccy := v_sub_ccy + round(v_line.quantity * v_line.unit_price, 2);
    END LOOP;

    IF v_no = 0 THEN
        RAISE EXCEPTION 'SO_INVOICE_NOTHING_TO_BILL|%', v_order.code;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【GST-2:那条"明确不支持"的拒绝在这里退休 —— 因为它等的那个答案到了】
    -- 原话是"预收发票的销项税时点与科目没人回答过"。Tim 2026-08-25 的裁定
    -- 就是那个答案:税点是【开票】。而订单流发票【正是】一张先于发货开出的
    -- 税务发票 —— 也就是新加坡税点规则最典型的那一种。把它继续拒下去,
    -- 等于在开关打开的那一天关掉整条订单开票路。
    -- 【科目也随之确定】销项税贷 2100,与 sale 型逐字同一个落点。
    -- ════════════════════════════════════════════════════════════════════════
    IF gst_registered() THEN
        v_tax_code := resolve_tax_code(p_tax_code, v_cust.default_tax_code, 'output', 'customer');
        v_tax_rate := tax_rate_for(v_tax_code, p_issue_date);
    ELSE
        IF NULLIF(btrim(COALESCE(p_tax_code, '')), '') IS NOT NULL THEN
            RAISE EXCEPTION 'GST_NOT_REGISTERED|%', p_tax_code;
        END IF;
        v_tax_code := NULL;
        v_tax_rate := 0;
    END IF;

    -- 【逐行算税、逐行取整】表头的税 = Σ 行税,不是 round(Σ 行净额 × 税率):
    -- 两种算法差几分,而客户手里那张纸上印的是行。与 create_invoice 同一口径。
    IF v_tax_code IS NOT NULL THEN
        DECLARE v_acc jsonb := '[]'::jsonb; v_e jsonb;
        BEGIN
            FOR v_e IN SELECT * FROM jsonb_array_elements(v_lines)
            LOOP
                v_line_tax := round((v_e->>'amount_ccy')::numeric * v_tax_rate / 100.0, 2);
                v_tax      := v_tax + v_line_tax;
                v_tax_base := v_tax_base + round(v_line_tax * v_order.fx_rate, 2);
                v_acc := v_acc || (v_e || jsonb_build_object('tax_ccy', v_line_tax));
            END LOOP;
            v_lines := v_acc;
        END;
        v_tax      := round(v_tax, 2);
        v_tax_base := round(v_tax_base, 2);
    END IF;

    v_sub_ccy := round(v_sub_ccy, 2);
    -- 头上的本位币额与分录同式:round(Σccy × fx)。行的 amount_base 逐行取整,
    -- 是显示口径 —— 头对分录,行对纸面,两者相差不超过几分且各自自洽。
    v_sub_base := round(v_sub_ccy * v_order.fx_rate, 2);

    -- 【信用闸在这里 —— 产生敞口的是开票】确认订单只看 credit_hold(那里的注释
    -- 说了为什么);额度对着"敞口 + 本票"判,敞口含已过账未结清的订单流发票
    -- (customer_ar_exposure_base 的第二项,本刀加的)。消息四个数说全,
    -- 与 record_output_sale 同形。
    IF v_cust.credit_hold THEN
        RAISE EXCEPTION 'CREDIT_HOLD|%', v_cust.code;
    END IF;
    IF v_cust.credit_limit_base IS NOT NULL THEN
        v_exposure := customer_ar_exposure_base(v_cust.id);
        -- 【敞口按客户真正欠的钱算 —— 含税】开票即应收,而应收是净额 + 销项税。
        -- 只按净额判额度,会让每一张票都少占用一截额度。
        IF v_exposure + v_sub_base + v_tax_base > v_cust.credit_limit_base THEN
            RAISE EXCEPTION 'CREDIT_LIMIT_EXCEEDED|%|%|%|%',
                v_cust.code, v_cust.credit_limit_base, v_exposure, v_sub_base + v_tax_base;
        END IF;
    END IF;

    -- 【无缝编号,与 create_invoice 同一把锁】真正的互斥点是 advisory key
    -- 'invoice_code_<year>' 这个字符串 —— 两个函数必须逐字同一把;MAX+1 只是推导。
    v_year := EXTRACT(YEAR FROM p_issue_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('invoice_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM invoices WHERE code LIKE 'INV-' || v_year::text || '-%';
    v_code := 'INV-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 【过账:借 1100 应收 / 贷 2500 合同负债】单据币种,按订单抄来的汇率。
    -- 期间锁/年结闸由 post_journal_entry 对 p_issue_date 统一执行。
    v_je := post_journal_entry(
        p_issue_date,
        'Invoice ' || v_code || ' · ' || v_order.code,
        'invoice', v_invoice_id,
        CASE WHEN v_tax = 0 THEN
        jsonb_build_array(
            jsonb_build_object('account_code', '1100', 'side', 'debit',
                'currency', v_order.currency, 'amount_ccy', v_sub_ccy, 'fx_rate', v_order.fx_rate),
            jsonb_build_object('account_code', '2500', 'side', 'credit',
                'currency', v_order.currency, 'amount_ccy', v_sub_ccy, 'fx_rate', v_order.fx_rate))
        ELSE
        -- 【税是【第三、四条腿】,不是把 1100 那条腿加粗】两条独立取整的腿
        -- 精确对冲;把净额与税合成一条 round((净+税)×fx) 会与 2500/2100 两边
        -- 差一分钱,而那一分钱撞的是提交时的借贷平衡触发器。
        jsonb_build_array(
            jsonb_build_object('account_code', '1100', 'side', 'debit',
                'currency', v_order.currency, 'amount_ccy', v_sub_ccy, 'fx_rate', v_order.fx_rate),
            jsonb_build_object('account_code', '2500', 'side', 'credit',
                'currency', v_order.currency, 'amount_ccy', v_sub_ccy, 'fx_rate', v_order.fx_rate),
            -- 【税那两条腿的 fx 用 v_tax_base / v_tax,不是订单汇率本身】
            -- 【为什么】F5 的 box6(单据侧)是 Σ 行税额(逐行 round(原币税 × fx)),
            -- 而这两条腿若按订单汇率过,过的是 round(Σ原币税 × fx) —— 外币下
            -- 两者可以差一分钱,于是"单据 vs 总账"那条勾稽会在一张【完全正确的】
            -- 发票上报 false。一条会因为取整而误报的勾稽,一个季度之后就没人看了。
            -- 【这个写法是仓库里现成的】record_payment 的解除行逐字同一手:
            -- "行 fx = 目标基准额 ÷ 原币额(除后反乘取整恰好还原)"。
            jsonb_build_object('account_code', '1100', 'side', 'debit',
                'currency', v_order.currency, 'amount_ccy', v_tax, 'fx_rate', v_tax_base / v_tax,
                'line_memo', 'output tax ' || v_tax_code),
            jsonb_build_object('account_code', '2100', 'side', 'credit',
                'currency', v_order.currency, 'amount_ccy', v_tax, 'fx_rate', v_tax_base / v_tax,
                'line_memo', 'output tax ' || v_tax_code))
        END);

    INSERT INTO invoices (id, code, customer_id, issue_date, due_date, payment_terms_days,
                          currency, subtotal_base, tax_rate_pct, tax_base, total_base,
                          notes, terms_text, bill_to_snapshot,
                          kind, sales_order_id, entry_id, fx_rate)
    VALUES (v_invoice_id, v_code, v_cust.id, p_issue_date, v_due, v_terms,
            v_order.currency, v_sub_base, v_tax_rate, v_tax_base, v_sub_base + v_tax_base,
            p_notes, p_terms_text,
            jsonb_build_object(
                'code', v_cust.code,
                'legal_name', v_cust.legal_name,
                'short_name', v_cust.short_name,
                'country', v_cust.country,
                'tax_id', v_cust.tax_id,
                'address', v_cust.address,
                'payment_terms', v_cust.payment_terms,
                'incoterm', v_cust.incoterm,
                -- ★【联系人从 counterparty_contacts 的【主联系人】取,不再从客户那三列取】★
                --   PARTY-1 把那三列搬进了子表并删掉。**已经存下来的快照不受影响**:
                --   它们是自成一体的 jsonb,记的是开票那一刻的事实 —— 变的只是
                --   【下一张】发票从哪儿取。没有主联系人时这三个键是 NULL,
                --   与本刀之前"客户没填联系人"的效果逐字一致。
                'contact_person', v_contact.name,
                'email', v_contact.email,
                'phone', v_contact.phone),
            'order', p_sales_order_id, (v_je->>'entry_id')::uuid, v_order.fx_rate);

    FOR v_l IN SELECT * FROM jsonb_array_elements(v_lines)
    LOOP
        INSERT INTO invoice_lines (invoice_id, sales_order_line_id, line_no, description,
                                   quantity, unit, unit_price, amount_base,
                                   tax_code, tax_rate_pct, tax_base)
        VALUES (v_invoice_id,
                (v_l->>'sales_order_line_id')::uuid,
                (v_l->>'line_no')::integer,
                v_l->>'description',
                (v_l->>'quantity')::numeric,
                v_l->>'unit',
                (v_l->>'unit_price')::numeric,
                round((v_l->>'amount_ccy')::numeric * v_order.fx_rate, 2),
                v_tax_code,
                CASE WHEN v_tax_code IS NULL THEN NULL ELSE v_tax_rate END,
                CASE WHEN v_tax_code IS NULL THEN 0
                     ELSE round((v_l->>'tax_ccy')::numeric * v_order.fx_rate, 2) END);
    END LOOP;

    -- 开票进订单的历史 —— 订单流先开票后发货,"开过没有"是看订单的人的问题。
    INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
    VALUES (p_sales_order_id, 'invoiced', v_code, auth.uid());

    RETURN jsonb_build_object(
        'invoice_id', v_invoice_id,
        'code', v_code,
        'issue_date', p_issue_date,
        'due_date', v_due,
        'currency', v_order.currency,
        'fx_rate', v_order.fx_rate,
        'subtotal_ccy', v_sub_ccy,
        'tax_code', v_tax_code,
        'tax_ccy', v_tax,
        'tax_base', v_tax_base,
        'total_base', v_sub_base + v_tax_base,
        'line_count', v_no,
        'journal_code', v_je->>'code');
END;
$function$
;

-- ═══ ②b 现在才删列 —— 函数已经不引用它们了 ═══════════════════════════════
-- 【顺序不是风格问题】上面两支函数在被替换【之前】的版本里读着这三列;
-- 先删列,CREATE OR REPLACE 会因为 v_cust.contact_person 不存在而失败。
ALTER TABLE public.customers DROP COLUMN contact_person;
ALTER TABLE public.customers DROP COLUMN email;
ALTER TABLE public.customers DROP COLUMN phone;

-- ═══ ③ 联系人的写入口 + 一方两身的报告 ═══════════════════════════════
-- db/functions/save_counterparty_contact.sql
-- PARTY-1:写一个联系人 —— 新增或修改,以及"把它设成主联系人"。
--
-- 【为什么写入只有这一扇门】"设成主联系人"要在【同一笔事务】里把上一个主撤掉。
-- 两条直连写入之间那道缝会撞上部分唯一索引(报一个裸约束名),
-- 或者更坏 —— 顺序反过来时静静地留下两个主。所以本表不开 INSERT/UPDATE 策略。
--
-- 【空字符串在这里落成 NULL】表单交上来的空框是 '',而 '' 与 NULL 在
-- 「够不够得着人」那条 CHECK 面前是两回事:''不是 NULL,于是一个两个框都空着的
-- 联系人会溜过去。归一化放在这一支,而不是指望每个调用点都记得 —— 与
-- normalise_counterparty_identity 放触发器是同一条理由。

CREATE OR REPLACE FUNCTION public.save_counterparty_contact(
    p_customer_id uuid DEFAULT NULL::uuid,
    p_supplier_id uuid DEFAULT NULL::uuid,
    p_name text DEFAULT NULL::text,
    p_role text DEFAULT NULL::text,
    p_email text DEFAULT NULL::text,
    p_phone text DEFAULT NULL::text,
    p_notes text DEFAULT NULL::text,
    p_is_primary boolean DEFAULT false,
    p_contact_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_name  text := NULLIF(btrim(COALESCE(p_name,  '')), '');
    v_email text := NULLIF(btrim(COALESCE(p_email, '')), '');
    v_phone text := NULLIF(btrim(COALESCE(p_phone, '')), '');
    v_role  text := NULLIF(btrim(COALESCE(p_role,  '')), '');
    v_notes text := NULLIF(btrim(COALESCE(p_notes, '')), '');
    v_cust  uuid := p_customer_id;
    v_sup   uuid := p_supplier_id;
    v_id    uuid;
    v_old   counterparty_contacts%ROWTYPE;
BEGIN
    -- 【改一行时,归属从那一行读,不从调用方读】否则一次调用可以把某个客户的
    -- 联系人悄悄搬到另一个客户名下,而两边的权限检查各自都通过。
    IF p_contact_id IS NOT NULL THEN
        SELECT * INTO v_old FROM counterparty_contacts WHERE id = p_contact_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'CONTACT_NOT_FOUND|%', p_contact_id;
        END IF;
        IF v_old.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'CONTACT_DELETED|%', p_contact_id;
        END IF;
        v_cust := v_old.customer_id;
        v_sup  := v_old.supplier_id;
    END IF;

    -- 【SECURITY DEFINER 自己查权限】而且按【归属那一侧】查 ——
    -- 一个只做采购的人不该改得动客户的联系人。
    IF num_nonnulls(v_cust, v_sup) <> 1 THEN
        RAISE EXCEPTION 'CONTACT_OWNER_REQUIRED'
          USING HINT = '一个联系人要么属于一个客户,要么属于一个供应商 —— 恰好一个,不能都填也不能都不填';
    END IF;
    IF v_cust IS NOT NULL THEN
        PERFORM require_permission('module.customers.edit');
        IF NOT EXISTS (SELECT 1 FROM customers WHERE id = v_cust AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', v_cust;
        END IF;
    ELSE
        PERFORM require_permission('module.suppliers.edit');
        IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = v_sup AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', v_sup;
        END IF;
    END IF;

    IF v_name IS NULL THEN
        RAISE EXCEPTION 'CONTACT_NAME_REQUIRED'
          USING HINT = '一个没有名字的联系人在名单里读起来就是「没有人」—— 写下这个人怎么称呼';
    END IF;
    IF v_email IS NULL AND v_phone IS NULL THEN
        RAISE EXCEPTION 'CONTACT_UNREACHABLE|%', v_name
          USING HINT = '至少留一条够得着他的路(邮箱或电话)—— 只有名字的联系人在开票或催收时帮不上忙';
    END IF;

    -- ★【设主联系人:先撤旧的,同一笔事务】★ 顺序反过来会撞部分唯一索引。
    IF p_is_primary THEN
        UPDATE counterparty_contacts
           SET is_primary = false, updated_at = now(), updated_by = auth.uid()
         WHERE is_primary AND deleted_at IS NULL
           AND id IS DISTINCT FROM p_contact_id
           AND ((v_cust IS NOT NULL AND customer_id = v_cust)
             OR (v_sup  IS NOT NULL AND supplier_id = v_sup));
    END IF;

    IF p_contact_id IS NULL THEN
        INSERT INTO counterparty_contacts
            (customer_id, supplier_id, name, role, email, phone, notes, is_primary, updated_by)
        VALUES (v_cust, v_sup, v_name, v_role, v_email, v_phone, v_notes,
                COALESCE(p_is_primary, false), auth.uid())
        RETURNING id INTO v_id;
    ELSE
        UPDATE counterparty_contacts
           SET name = v_name, role = v_role, email = v_email, phone = v_phone,
               notes = v_notes, is_primary = COALESCE(p_is_primary, false),
               -- 【人改过名字之后,它就不再是"推出来的"了】
               name_inferred = CASE WHEN v_name IS DISTINCT FROM v_old.name
                                    THEN false ELSE v_old.name_inferred END,
               updated_at = now(), updated_by = auth.uid()
         WHERE id = p_contact_id
        RETURNING id INTO v_id;
    END IF;

    RETURN jsonb_build_object('contact_id', v_id, 'is_primary', COALESCE(p_is_primary, false));
END;
$function$;

COMMENT ON FUNCTION public.save_counterparty_contact(uuid, uuid, text, text, text, text, text, boolean, uuid) IS
'PARTY-1:联系人的唯一写入口。**"设成主联系人"要在同一笔事务里先撤掉上一个** —— 两条直连写入之间那道缝会撞部分唯一索引,或者顺序反过来时静静留下两个主,所以本表不开 INSERT/UPDATE 策略。改一行时【归属从那一行读,不从调用方读】,否则一次调用能把联系人从一个客户搬到另一个客户名下而两边权限各自都过。权限按归属那一侧查(customers.edit / suppliers.edit)。空字符串在这里落成 NULL —— '''' 不是 NULL,而那条「至少留一条够得着他的路」的 CHECK 拦不住两个空框。人改过名字之后 name_inferred 落回 false。';

-- db/functions/counterparty_overlap_report.sql
-- PARTY-1:同一家公司在两侧各有一行吗 —— 一份【报告】,不是一个结构。
--
-- ★★【它【故意】不把两边的敞口加起来,而这是本刀最要紧的一句话】★★
--   一个既欠你钱、又被你欠钱的对手方,读的人第一反应是"那就轧个差"。
--   **轧差是一次【法律行为】,不是一次算术。** 它要有一份【抵销权】,
--   而抵销权住在一份合同里 —— 这个仓库里没有任何一处记录过那样一份合同;
--   各法域对"抵销权在对方破产之后还成不成立"的答案也不一样。
--   悄悄轧差会【同时低估应收与应付】,而两个数一起变小、没有任何东西报错,
--   正是 OPS-17 抓到的那个病穿上会计外衣的样子。
--   **所以这份报告把两个敞口【并排摆着】,并且自己说出它不加它们、以及为什么。**
--   要一个数的人,得知道那是【有人要做的一次决定】,不是系统扣着不给的一个和。
--
-- ★★【非空由构造保证 —— 而"0 条重叠"必须与"没有东西可比"分得开】★★
--   实测(2026-08-29):线上 customers **一个 tax_id 都没有**,
--   所以任何按 tax_id 的重叠今天【必然】返回 0 行 —— 那不是"没有重叠",
--   那是"没有可比的东西"。一份只返回 matches 的报告在这两种情形下
--   长得一模一样,而那正是本仓库反复付账的那种沉默。
--   **所以返回值里带着【分母】**:两侧各有多少行、其中多少行有登记号。
--   于是「0 条重叠 / 0 个可比客户」与「0 条重叠 / 40 个可比客户」
--   在屏幕上是两句不同的话,而后者才是一句关于重叠的断言。
--
-- 【两种匹配,强弱分开报,不合并】
--   · tax_id:**身份**。两边的写入触发器 normalise_counterparty_identity()
--     用同一套规则归一(去空白 + 大写 + '' → NULL),所以跨表比较本来就是可靠的,
--     不需要在这里再洗一遍 —— 洗第二遍就是第二份实现。
--   · 归一化名字:**线索**,不是身份。同名公司真实存在,而改名的同一家公司比不上。
--     它单独一组返回,绝不与 tax_id 那组混在一起 ——
--     把一条线索摆进身份那一栏,是把"可能"读成"是"。
--
-- 【为什么是函数不是视图】它要回答的不只是"有哪些行",还有"分母是多少"、
--   以及那句"不加它们"的话。一个视图给不出分母(0 行就是 0 行)。

CREATE OR REPLACE FUNCTION public.counterparty_overlap_report()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_by_tax   jsonb := '[]'::jsonb;
    v_by_name  jsonb := '[]'::jsonb;
    v_cov      jsonb;
BEGIN
    -- 【SECURITY DEFINER 必须自己查权限】属主权限绕过 RLS,所以这一句不是礼节。
    -- 要【两侧都看得见】才给看:这份报告的全部内容就是把两侧摆在一起,
    -- 只有一侧权限的人拿到的会是一份误导性的半张表。
    PERFORM require_permission('module.customers.view');
    PERFORM require_permission('module.suppliers.view');

    -- ── 强匹配:同一个登记号 ────────────────────────────────────────────
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'tax_id'), '[]'::jsonb) INTO v_by_tax
    FROM (
        SELECT jsonb_build_object(
                   'tax_id',            c.tax_id,
                   'customer_id',       c.id,
                   'customer_code',     c.code,
                   'customer_name',     c.legal_name,
                   'supplier_id',       s.id,
                   'supplier_code',     s.code,
                   'supplier_name',     s.legal_name,
                   'counterparty_type', s.counterparty_type,
                   -- 【并排摆着的两个数,而不是一个和】见抬头。
                   'ar_open_base',      COALESCE(ar.v, 0),
                   'ap_open_base',      COALESCE(ap.v, 0)) AS x
        FROM customers c
        JOIN suppliers s ON s.tax_id = c.tax_id
        LEFT JOIN LATERAL (SELECT SUM(o.open_base) v FROM ar_open_items o
                            WHERE o.customer_id = c.id) ar ON true
        LEFT JOIN LATERAL (SELECT SUM(o.open_base) v FROM ap_open_items o
                            WHERE o.supplier_id = s.id) ap ON true
        WHERE c.deleted_at IS NULL AND s.deleted_at IS NULL
          AND c.tax_id IS NOT NULL
    ) t;

    -- ── 弱信号:归一化之后同名。**单独一组,不与上面合并。** ────────────
    -- 排除掉已经被登记号匹配上的那些对,否则同一对会出现两次,
    -- 而"两条证据"会被读成"两个重叠"。
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'customer_code'), '[]'::jsonb) INTO v_by_name
    FROM (
        SELECT jsonb_build_object(
                   'customer_id',   c.id,
                   'customer_code', c.code,
                   'customer_name', c.legal_name,
                   'supplier_id',   s.id,
                   'supplier_code', s.code,
                   'supplier_name', s.legal_name,
                   'counterparty_type', s.counterparty_type) AS x
        FROM customers c
        JOIN suppliers s
          ON lower(regexp_replace(s.legal_name, '\s+', '', 'g'))
           = lower(regexp_replace(c.legal_name, '\s+', '', 'g'))
        WHERE c.deleted_at IS NULL AND s.deleted_at IS NULL
          AND NOT (c.tax_id IS NOT NULL AND s.tax_id IS NOT NULL AND c.tax_id = s.tax_id)
    ) t;

    -- ── ★ 分母:让"0 条"说得出它是哪一种 0 ★ ────────────────────────────
    SELECT jsonb_build_object(
        'customers_total',       (SELECT count(*) FROM customers WHERE deleted_at IS NULL),
        'customers_with_tax_id', (SELECT count(*) FROM customers WHERE deleted_at IS NULL AND tax_id IS NOT NULL),
        'suppliers_total',       (SELECT count(*) FROM suppliers WHERE deleted_at IS NULL),
        'suppliers_with_tax_id', (SELECT count(*) FROM suppliers WHERE deleted_at IS NULL AND tax_id IS NOT NULL))
    INTO v_cov;

    RETURN jsonb_build_object(
        'by_tax_id',  v_by_tax,
        'by_name',    v_by_name,
        'coverage',   v_cov,
        -- 【这两句话跟着数字走,不只躺在文档里】(Tim 2026-08-29 裁定 A3)
        -- 读到这份报告的人,就是会想去轧差的那个人。
        'exposures_are_not_netted', true,
        'why_not_netted',
            'Set-off is a legal act, not an arithmetic one: it requires a set-off right '
            'that lives in a contract, and no such contract is recorded in this system. '
            'Jurisdictions also differ on whether set-off survives insolvency. Netting '
            'silently would understate receivables and payables at the same time, so the '
            'two exposures are shown side by side and deliberately not added. Producing a '
            'single number is a decision somebody has to make, not a sum the system withheld.');
END;
$function$;

COMMENT ON FUNCTION public.counterparty_overlap_report() IS
'PARTY-1:同一家公司在两侧各有一行吗 —— 一份报告,**不是一个结构**(一方两身仍未被结构回答,见 known-issues 的 COUNTERPARTY-ONE-PARTY)。**它故意不把两边的敞口加起来**:轧差是一次法律行为,要有抵销权,而抵销权住在一份这个系统里没有记录过的合同里;悄悄轧差会同时低估应收与应付。所以两个敞口并排摆着,并且返回值自己带着那句理由。**返回值带分母(coverage)**,因为线上 customers 一个 tax_id 都没有 —— "0 条重叠"与"没有可比的东西"必须分得开,而只返回 matches 的报告在两种情形下长得一模一样。tax_id 是身份(两表写入触发器归一化规则相同,跨表比较本来就可靠),归一化名字只是线索,两组分开返回、绝不合并。';


-- db/functions/soft_delete_counterparty_contact.sql
-- PARTY-1:把一个联系人从名单上拿下来 —— 【软删,不真删】。
--
-- 【为什么不真删】两件事要分得开:
--   ① "这个人已经不在那家公司了" —— 名单上不该再出现他;
--   ② "这个人从来不存在" —— 那不是真的,而且 collection_chases 上很可能
--      还留着"那天我们联系的是他"。那一列是【文本】,所以真删不会让它变错,
--      但会让"这个名字是谁"这个问题在系统里再也答不出来。
-- 所以留行、落 deleted_at。
--
-- 【它必须是一支函数,而不是一条 UPDATE 策略】本表没有 UPDATE 策略(见表注),
-- 而一条为了软删而开的 UPDATE 策略会顺带把【所有列】都开出去 ——
-- 包括 is_primary,于是"设主联系人"那条同一笔事务的保证被绕过去了。

CREATE OR REPLACE FUNCTION public.soft_delete_counterparty_contact(p_contact_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_row counterparty_contacts%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM counterparty_contacts WHERE id = p_contact_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTACT_NOT_FOUND|%', p_contact_id;
    END IF;
    -- 【SECURITY DEFINER 自己查权限,按归属那一侧查】
    IF v_row.customer_id IS NOT NULL THEN
        PERFORM require_permission('module.customers.edit');
    ELSE
        PERFORM require_permission('module.suppliers.edit');
    END IF;
    IF v_row.deleted_at IS NOT NULL THEN
        -- 【已经删过不是错误,但也不该假装刚删成功】幂等地返回,并说出来。
        RETURN jsonb_build_object('contact_id', p_contact_id, 'already_deleted', true);
    END IF;
    UPDATE counterparty_contacts
       SET deleted_at = now(), is_primary = false,
           updated_at = now(), updated_by = auth.uid()
     WHERE id = p_contact_id;
    -- 【主联系人被删掉之后,不自动挑一个顶上】谁是主联系人是一个【判断】,
    -- 而系统按 created_at 之类挑一个顶上,会让开票快照悄悄换人 ——
    -- 那是一次没有人做过的决定。屏幕上会显示"没有主联系人",人来指定。
    RETURN jsonb_build_object('contact_id', p_contact_id, 'already_deleted', false,
                              'was_primary', v_row.is_primary);
END;
$function$;

COMMENT ON FUNCTION public.soft_delete_counterparty_contact(uuid) IS
'PARTY-1:把联系人从名单上拿下来 —— 软删。「他不在那家公司了」与「他从来不存在」是两件事,而 collection_chases 上可能还留着"那天联系的是他"(那是文本,真删不会让它变错,但会让"这个名字是谁"再也答不出来)。**它必须是函数而不是一条 UPDATE 策略**:为软删开的 UPDATE 策略会连 is_primary 一起开出去,把"设主联系人要在同一笔事务里撤旧的"那条保证绕过去。**删掉主联系人之后不自动挑一个顶上** —— 那会让开票快照悄悄换人,而那是一次没有人做过的决定。';


COMMIT;
