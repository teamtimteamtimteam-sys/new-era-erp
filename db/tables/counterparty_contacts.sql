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
-- NOTE: introduced by db/migrations/2026-08-29-party1-counterparty-contacts-and-the-overlap-report.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

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
