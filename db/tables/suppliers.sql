-- db/tables/suppliers.sql
-- 供应商主档。三样东西在这份文件里同住:
--   * supplier_status 枚举 + validate_supplier_status_transition —— 供应商是唯一
--     有【状态机】的主档(draft → pending_review → approved → active → …),
--     非法跳转在 BEFORE UPDATE 触发器里直接拒绝;
--   * code 'SUP-YYYY-NNNN' 由 BEFORE INSERT 触发器从序列取号(非无缝,主档无所谓);
--   * updated_at 由共享的 update_updated_at() 维护(定义在
--     db/functions/update_updated_at.sql,勿在此重复定义)。
-- created_by/updated_by/owner_id 直接外键到 auth.users —— 这是建库初期的写法,
-- 后来的表都不再挂 auth 外键(只存 uuid);保持线上原样,不"顺手统一"。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- default_payment_term_template_id 为
-- db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql 追加(列序按线上
-- attnum,追加列在末尾)。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TYPE public.supplier_status AS ENUM (
    'draft', 'pending_review', 'approved', 'rejected',
    'active', 'suspended', 'blacklisted', 'archived'
);

CREATE SEQUENCE public.supplier_code_seq;

CREATE TABLE public.suppliers (
    id                               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                             text NOT NULL UNIQUE,  -- 'SUP-YYYY-NNNN',触发器取号
    legal_name                       text NOT NULL,
    short_name                       text,
    country                          text NOT NULL,
    address                          text,
    tax_id                           text,
    supplier_types                   text[] NOT NULL DEFAULT '{}',
    payment_terms                    text,
    incoterm                         text,
    credit_rating                    text,
    status                           supplier_status NOT NULL DEFAULT 'draft',
    owner_id                         uuid REFERENCES auth.users (id),
    deleted_at                       timestamptz,
    notes                            text,
    created_at                       timestamptz NOT NULL DEFAULT now(),
    created_by                       uuid REFERENCES auth.users (id),
    updated_at                       timestamptz NOT NULL DEFAULT now(),
    updated_by                       uuid REFERENCES auth.users (id),
    default_payment_term_template_id uuid REFERENCES public.payment_term_templates (id),
    -- ── ALTER 加的列排在末尾,与 attnum 顺序一致 ──────────────────────────
    -- LOG-1a:交易对手类型 —— 唯一的真源。NOT NULL 且【没有默认值】:写入方必须选。
    counterparty_type                text NOT NULL
                                     CHECK (counterparty_type IN ('goods_supplier', 'forwarder', 'service_vendor')),
    -- LOG-1a:supplies_goods 由上一列【派生】,不可写。它在 attnum 上排最后,
    -- 因为本刀把原来那个普通列 DROP 之后重新 ADD 成了生成列
    -- (PostgreSQL 不能把普通列原地改成生成列)。
    supplies_goods                   boolean
                                     GENERATED ALWAYS AS (counterparty_type = 'goods_supplier') STORED,
    -- ── GST-2 追加的列(ALTER 加的列排在末尾)────────────────────────────────
    -- 这家供应商的账单默认用哪个【进项】税码。初值 NULL;已注册时记费用按名拒
    -- (TAX_CODE_REQUIRED|supplier)。与 customers.default_tax_code 逐字同一条理由。
    -- 侧别由 trg_suppliers_default_tax_code_side 钉住。
    default_tax_code                 text REFERENCES public.tax_codes (code),
    -- ── WHT-1 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)────────────
    -- 这一家在【新加坡所得税】上是不是居民。三态,NULL = 没有人回答过。
    -- **它不是 country** —— 详见列注释,那是本列存在的全部理由。
    tax_residence                    text
                                     CHECK (tax_residence IS NULL OR tax_residence IN ('resident', 'non_resident'))
);

COMMENT ON COLUMN public.suppliers.counterparty_type IS
'LOG-1a:这一家【是什么】—— 单值,唯一的真源。
goods_supplier = 我们向他们买货并收货;forwarder = 货代/承运人,我们付他们运费、永远不会收到他们的"货";
service_vendor = 房东、水电、保险、专业服务、承包商这一类:付钱,但不会有一车货到场。
【货代保留 supplier id 是有意的】:一家公司一个 id,应付账龄、付款分摊、预付冲抵、外币重估整条链因此一个字都不用改
(ap_open_items 早就有一支 doc_kind=''freight'')。类型只决定他【出现在哪些名单里】,不决定他在账上是谁。
【NOT NULL 且无默认】:写入方必须选。默认值会让"没想过"与"确实是供货商"无法区分。
supplies_goods 是本列的【派生列】,不要反过来写它。';

COMMENT ON COLUMN public.suppliers.supplies_goods IS
'SUP-TYPE-1a 建立,LOG-1a 起【改为派生】:GENERATED ALWAYS AS (counterparty_type = ''goods_supplier'') STORED。
语义一个字没变 —— 仍然是【我们会不会收到这一家的实物货】,仍然把关三处:operations_now 的 qualification_missing 支、supplier_receipt_pattern、以及收货触发器 guard_inbound_supplier_supplies_goods(RECEIPT_AGAINST_NON_GOODS_VENDOR)。
变的是【谁说了算】:真源是 counterparty_type,这一列跟着它走。
【它不可写】。想改一家的供货能力,改 counterparty_type;直接写这一列会被 PostgreSQL 拒绝,那是刻意的 —— 两处都能写就是两个真源。
货代(forwarder)与服务商(service_vendor)在这里都是 false,但它们【不是同一类】:前者不进供应商名单,后者要留在费用类的选择器里。要区分它们请读 counterparty_type,不要读这一列。';


CREATE INDEX idx_suppliers_code ON public.suppliers (code);
CREATE INDEX idx_suppliers_country ON public.suppliers (country) WHERE deleted_at IS NULL;
CREATE INDEX idx_suppliers_owner ON public.suppliers (owner_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_suppliers_status ON public.suppliers (status) WHERE deleted_at IS NULL;

CREATE OR REPLACE FUNCTION public.generate_supplier_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
  IF NEW.code IS NULL OR NEW.code = '' THEN
    NEW.code := 'SUP-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                LPAD(nextval('supplier_code_seq')::TEXT, 4, '0');
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.validate_supplier_status_transition()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
  -- INSERT 时不检查
  IF TG_OP = 'INSERT' THEN
    RETURN NEW;
  END IF;

  -- 状态没变,不检查
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- 定义合法跳转
  IF NOT (
    (OLD.status = 'draft'          AND NEW.status IN ('pending_review', 'archived')) OR
    (OLD.status = 'pending_review' AND NEW.status IN ('approved', 'rejected', 'draft')) OR
    (OLD.status = 'rejected'       AND NEW.status IN ('draft', 'archived')) OR
    (OLD.status = 'approved'       AND NEW.status IN ('active', 'suspended', 'archived')) OR
    (OLD.status = 'active'         AND NEW.status IN ('suspended', 'blacklisted', 'archived')) OR
    (OLD.status = 'suspended'      AND NEW.status IN ('active', 'blacklisted', 'archived')) OR
    (OLD.status = 'blacklisted'    AND NEW.status IN ('archived')) OR
    (OLD.status = 'archived'       AND NEW.status IN ('draft'))  -- 归档后可恢复为草稿
  ) THEN
    RAISE EXCEPTION '非法状态跳转: % → %', OLD.status, NEW.status;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_generate_supplier_code
    BEFORE INSERT ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION generate_supplier_code();

CREATE TRIGGER trg_suppliers_status_transition
    BEFORE UPDATE ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION validate_supplier_status_transition();

CREATE TRIGGER trg_suppliers_updated_at
    BEFORE UPDATE ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE UNIQUE INDEX suppliers_tax_id_unique ON public.suppliers (tax_id) WHERE tax_id IS NOT NULL AND deleted_at IS NULL;

CREATE TRIGGER trg_suppliers_normalise_identity
    BEFORE INSERT OR UPDATE ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION public.normalise_counterparty_identity();

-- SOD-1:让 created_by 真的落下来 —— 它是职责分离控制②的【主语】。
-- 此前这一列无默认值、app 的 INSERT 也不传它,于是线上 8 行全为 NULL,
-- 而一条挂在恒为 NULL 的列上的规矩永远不会触发。
-- 【不是 DEFAULT auth.uid()】本列有 FK -> auth.users(id),而 89 份既有 fixture
-- 会把 claims 设成一个不在 auth.users 里的随机 uuid —— 加 DEFAULT 会让它们整片
-- 撞 FK 违反。判据因此取自外键自己的条件,见 db/functions/stamp_supplier_creator.sql。
CREATE TRIGGER trg_supplier_creator
    BEFORE INSERT ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION public.stamp_supplier_creator();

COMMENT ON COLUMN public.suppliers.tax_id IS
    '登记号/税号(新加坡 UEN、中国统一社会信用代码)。**这是这一行的身份**,不是名字 —— GO-4。写入时去空白并大写;非空且未软删的行上唯一。【不是必填】:18 行里只有 2 行有值,而为了满足约束去编造值是禁止的;必填这一步留给【批量导入那一刀】,因为那是真实主数据到场、而补做成本开始上升的时刻。';

ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "suppliers select by permission"
    ON public.suppliers
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'::text));

CREATE POLICY "suppliers insert by permission"
    ON public.suppliers
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.suppliers.edit'::text));

CREATE POLICY "suppliers update by permission"
    ON public.suppliers
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.suppliers.edit'::text)) WITH CHECK (has_permission('module.suppliers.edit'::text));

CREATE POLICY "suppliers delete by permission"
    ON public.suppliers
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.suppliers.edit'::text));


COMMENT ON COLUMN public.suppliers.created_by IS
    'SOD-1:建这一行的人。【职责分离控制②的主语】—— sod_supplier_creator() 读它,建供应商的人不得对该供应商付款。此前无默认值且 app 的 INSERT 不传它,所以线上 8 行全为 NULL;那 8 行不回填(FIN-26:捏造的来历比空白更坏),控制②对它们不适用,见 docs/known-issues.md 的 SOD-1-BLIND 条。今起由 trg_supplier_creator 落笔,而它只在 auth.uid() 确实是一个 auth.users 账号时落笔 —— 那正是本列外键会接受的条件。';

-- GST-2:默认税码的【侧别】—— 进项码才挂得上供应商。
CREATE TRIGGER trg_suppliers_default_tax_code_side
    BEFORE INSERT OR UPDATE OF default_tax_code ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION public.guard_default_tax_code_side();

COMMENT ON COLUMN public.suppliers.default_tax_code IS
    'GST-2:这家供应商的账单默认用哪个进项税码。初值 NULL,已注册时记费用会按名拒(TAX_CODE_REQUIRED|supplier)。与 customers.default_tax_code 逐字同一条理由。';

-- WHT-1:税务居民身份 —— 声明的,不是从国别推出来的。
COMMENT ON COLUMN public.suppliers.tax_residence IS
'WHT-1:这一家在【新加坡所得税】上是不是居民。三态,而中间那个是重点:
  · ''resident''      —— 新加坡税务居民,付给他的款不触发预提税;
  · ''non_resident''  —— 非居民,付给他的服务/利息/特许权使用费要代扣;
  · NULL              —— **没有人回答过这个问题**,不是"默认居民"。

★【它【不是】country,而这一条是本列存在的全部理由】★
country 是账单地址;税务居民身份取决于【管理与控制在哪里行使】。
一家在新加坡注册的外国公司分支可以是非居民,一家在境外注册、由新加坡管理的
公司可以是居民。**按国别推居民身份,等于把一个证据问题答成一个地址问题** ——
与 customers.default_tax_code 上那句「尤其不按国别自动推 ZR」逐字同一条理由:
出口零税率取决于出口证据,居民身份取决于居民证明,两者都不取决于地址。
线上实测:唯一一家外国供应商(SUP-2026-0003,CN)是【货物】供应商,
买货从来不触发预提税 —— 也就是说按国别推,第一条推论就会是错的。

★【NULL 【不】按名拒,而这是一个量过成本之后的决定,不是一次退让】★
本列既有 8 行全部为 NULL,不回填 —— 捏造一个居民身份比空白坏(FIN-26)。
真正的问题是:一张【身份未申报】的供应商单据要不要拒?实测代价:
**16 份 fixture 调用 record_expense**,每一份都自建供应商,于是任何形式的
「必须申报」(表上的 NOT VALID CHECK、或函数里的按名拒)都会同时改写 16 个
本刀没写过的文件 —— 而它防的那个场景在线上【一个实例都没有】
(0 家 service_vendor,唯一的外国供应商是买货的)。

所以规矩是【非对称】的,按"这个答案会不会改变结果"来划:
  · tax_residence = ''non_resident''  → 记费用时【必须】回答代扣问题
    (WHT_NATURE_REQUIRED;答"不适用"用 wht_natures 的 ''none'' 那一行,
     它是一个【显式的否】,不是一个空白);
  · tax_residence IS NULL             → 不问,照记 —— 而这个缺口
    **被数出来摆在脸上**:/finance/wht 那一页印着"N 家供应商没有申报税务居民
    身份",N 由页面现查。它是 4.2「具名缺席,不是空白」的一次真用。
  · 显式传了代扣性质、而供应商身份是 NULL → 按名拒
    (WHT_RESIDENCE_NOT_STATED):你在断言要代扣,而收款人根本没被分类过。

【残留的风险,照直写】一家【未申报身份】的非居民服务商,今天可以被记费用、
被付款,而系统一分钱都不会代扣。这是上面那个取舍买来的,不是没想到 ——
按名记在 docs/known-issues.md,返回条件是第一家真实的非居民服务商到场。';
