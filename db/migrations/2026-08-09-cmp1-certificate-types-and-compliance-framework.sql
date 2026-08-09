-- CMP-1:资质框架 —— 证书类型是数据、公司资质有了家、到期有牌、过期能挡
--
-- Tim 已答复:公司暂无执照,没关系 —— 要的是机器。类型给合理默认值,但【必须
-- 保持为可编辑的数据】。规格与 A1–D 的报告在 docs/compliance-scoping.md。
--
-- 【类型是一张表,不是枚举】CHECK 或 pg enum 意味着加一种证书要跑一次迁移;
-- 查找表意味着在屏幕上改一行。与 leave_types 同一形状:RUNTIME CONFIG ——
-- 引导播种、check_mirrors 不逐行比对(操作员改了它是系统在正常工作,不是漂移)。
--
-- 【disposition 是这张表的全部要点】block / warn / ignore 逐类型声明:
-- 改一行数据就改变收货闸门的行为,不改一行代码(fixture 37 B 臂钉住这一点)。
--
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. 证书类型:查找表 + 引导默认值
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.certificate_types (
    code           text PRIMARY KEY,
    name_en        text NOT NULL,
    name_zh        text NOT NULL,
    -- block:过期即挡收货;warn:只提醒;ignore:不提醒不挡
    disposition    text NOT NULL CHECK (disposition IN ('block', 'warn', 'ignore')),
    -- 到期前多少天开始上看板
    warn_lead_days integer NOT NULL DEFAULT 90 CHECK (warn_lead_days >= 0),
    is_active      boolean NOT NULL DEFAULT true,
    sort_order     integer NOT NULL DEFAULT 0,
    notes          text
);

COMMENT ON TABLE public.certificate_types IS
    '证书/资质类型(CMP-1)。RUNTIME CONFIG:引导播种默认值,操作员在界面上增改 —— 加一种证书是编辑一行,不是跑一次迁移。disposition 决定过期后果(block 挡收货 / warn 只提醒 / ignore),warn_lead_days 决定到期前多少天上看板。下面播种的默认值哪些是【默认】哪些是【决定】,行内 notes 写明。';

ALTER TABLE public.certificate_types ENABLE ROW LEVEL SECURITY;
CREATE POLICY "certificate_types select all"
    ON public.certificate_types
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);   -- 类型目录不敏感:与 leave_types/currencies 同一处置
CREATE POLICY "certificate_types insert by permission"
    ON public.certificate_types
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.suppliers.edit'::text));
CREATE POLICY "certificate_types update by permission"
    ON public.certificate_types
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.suppliers.edit'::text))
    WITH CHECK (has_permission('module.suppliers.edit'::text));

-- 【默认值的理由写在行上,读的人才分得清"默认"与"决定"】——
-- Basel / Article 18 / TFS / NEA / GWDF 是【处理或移动受控废物的法定前置条件】,
-- 缺了它交易本身违法 → block;ISO 一类管理体系认证是【商业保证】,过期是商务
-- 瑕疵不是违法 → warn。Tim 改任何一条 = 在界面上编辑那一行。
INSERT INTO public.certificate_types (code, name_en, name_zh, disposition, warn_lead_days, sort_order, notes) VALUES
    ('basel',      'Basel Convention',  '巴塞尔公约',        'block', 90, 1, '默认 block:跨境转移受控废物的法定前置。这是默认值,不是决定 —— 要改就改本行'),
    ('article_18', 'Article 18',        '第 18 条',          'block', 90, 2, '默认 block:同上,法定前置'),
    ('tfs',        'TFS Document',      'TFS 文件',          'block', 90, 3, '默认 block:跨境废物运输文件'),
    ('nea_import', 'NEA Import Permit', 'NEA 进口许可',      'block', 90, 4, '默认 block:新加坡国家环境局进口许可,缺了不能收'),
    ('gwdf',       'GWDF Licence',      'GWDF 执照',         'block', 90, 5, '默认 block:一般废物处置设施执照'),
    ('iso',        'ISO Certification', 'ISO 认证',          'warn',  60, 6, '默认 warn:管理体系认证是商业保证,过期是瑕疵不是违法'),
    ('other',      'Other',             '其他',              'warn',  30, 7, '默认 warn:未归类的证书先提醒,归了类再定处置');

-- ════════════════════════════════════════════════════════════════════════════
-- 2. 既有自由文本 → 类型码。【映射不上就大声失败】——
--    错归类的证书 = 指错仪器的拦截规则,比失败糟得多。
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.supplier_compliance
    ADD COLUMN cert_type_code text REFERENCES public.certificate_types (code);

UPDATE public.supplier_compliance SET cert_type_code = CASE cert_type
    WHEN 'Basel Convention'  THEN 'basel'
    WHEN 'Article 18'        THEN 'article_18'
    WHEN 'TFS Document'      THEN 'tfs'
    WHEN 'NEA Import Permit' THEN 'nea_import'
    WHEN 'GWDF Licence'      THEN 'gwdf'
    WHEN '其他'              THEN 'other'
    ELSE NULL
END;

DO $$
DECLARE v_bad text;
BEGIN
    SELECT string_agg(DISTINCT cert_type, ' / ') INTO v_bad
    FROM supplier_compliance WHERE cert_type_code IS NULL;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'CMP1_UNMAPPED_CERT_TYPE|%|映射不上的自由文本不许静默归入默认类型 —— 请把该值加进上面的 CASE 或先在界面上更正数据,再重跑本迁移', v_bad;
    END IF;
END $$;

ALTER TABLE public.supplier_compliance ALTER COLUMN cert_type_code SET NOT NULL;
-- 自由文本列退役:类型自此只有一种写法。标签由 certificate_types 的双语名提供。
ALTER TABLE public.supplier_compliance DROP COLUMN cert_type;

-- 缺陷修复之一:document_id 有名无实(无外键、无人写入)。补上外键 ——
-- 证书记录从此能【走到】证书本身。写入它的界面在 CompliancePanel(同一切次)。
-- 目标选 supplier_attachments 而不是新桶:理由见 docs/compliance-scoping.md 附录。
ALTER TABLE public.supplier_compliance
    ADD CONSTRAINT supplier_compliance_document_fkey
    FOREIGN KEY (document_id) REFERENCES public.supplier_attachments (id);

-- ════════════════════════════════════════════════════════════════════════════
-- 3. 公司资质:自己的表。【空着是预期状态】—— 公司尚未运营,静默是对的,
--    所以没有"空登记簿"告警;fresh-install checklist 加了一步来提醒录入。
--    第一张真执照进来不需要任何 schema 变更:号码、签发方、范围、有效期、文件。
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.company_compliance (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cert_type_code text NOT NULL REFERENCES public.certificate_types (code),
    cert_no        text,
    issuing_body   text,
    -- 执照的适用范围(如"E 类有害废物贮存,上限 60 吨")—— 供应商表没有这一列,
    -- 公司执照有配额与类别,范围是它区别于"有没有"的那一半
    scope          text,
    valid_from     date,
    valid_until    date,
    -- company-assets 桶里的对象键(logo 同桶)。公司侧没有附件表,先用对象键;
    -- 若将来公司文件多到要管理,再建 company_attachments —— 那是加表,不动本表
    document_path  text,
    notes          text,
    deleted_at     timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid
);

CREATE INDEX idx_company_compliance_valid_until
    ON public.company_compliance (valid_until) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_company_compliance_updated_at
    BEFORE UPDATE ON public.company_compliance
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

COMMENT ON TABLE public.company_compliance IS
    '公司自己的执照与资质(CMP-1)。空着是预期状态 —— 公司尚未运营,静默正确,故无空登记簿告警(录入提醒在 docs/fresh-install-checklist.md)。SELECT 挂 module.suppliers.view:合规没有自己的模块,而资质的读者与供应商资质是同一批人 —— 记录在 docs/compliance-scoping.md §C,将来建合规模块时这里是要改的那一行。';

ALTER TABLE public.company_compliance ENABLE ROW LEVEL SECURITY;
CREATE POLICY "company_compliance select by permission"
    ON public.company_compliance
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'::text));
CREATE POLICY "company_compliance insert by permission"
    ON public.company_compliance
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.suppliers.edit'::text));
CREATE POLICY "company_compliance update by permission"
    ON public.company_compliance
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.suppliers.edit'::text))
    WITH CHECK (has_permission('module.suppliers.edit'::text));

-- ════════════════════════════════════════════════════════════════════════════
-- 4. 收货闸门:block 类型过期 → 点名拒绝
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.guard_inbound_po_receivable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po record;
    v_cert record;
BEGIN
    -- CMP-1:【block 类型的证书过期 → 本供应商不能收货】,不论这单挂没挂采购单 ——
    -- Doc 1 问的是"有害废物【进场】",进场是物理事件,与单据无关。只在 INSERT 时查
    -- (换采购单的 UPDATE 不重复查:货已在场,换单不是又进了一次场)。
    -- 【disposition 从类型表现读】—— 改一行数据就改行为,这正是类型作为表的全部意义。
    -- 【缺证不挡】:挡的是"过期",不是"没有"—— A3 的答复只到这里。
    IF TG_OP = 'INSERT' AND NEW.supplier_id IS NOT NULL THEN
        SELECT ct.code, ct.name_en, sc.valid_until, s.code AS supplier_code
        INTO v_cert
        FROM supplier_compliance sc
        JOIN certificate_types ct ON ct.code = sc.cert_type_code
        JOIN suppliers s ON s.id = sc.supplier_id
        WHERE sc.supplier_id = NEW.supplier_id
          AND sc.deleted_at IS NULL
          AND ct.disposition = 'block'
          AND sc.valid_until IS NOT NULL
          AND sc.valid_until < CURRENT_DATE
        ORDER BY sc.valid_until
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'SUPPLIER_QUALIFICATION_EXPIRED|%|%|%',
                v_cert.supplier_code, v_cert.code, v_cert.valid_until;
        END IF;
    END IF;

    IF NEW.purchase_order_id IS NULL THEN
        RETURN NEW;
    END IF;
    -- UPDATE 时只在换单时把关(同单上改行号之类不重复检查)
    IF TG_OP = 'UPDATE' AND NEW.purchase_order_id IS NOT DISTINCT FROM OLD.purchase_order_id THEN
        RETURN NEW;
    END IF;
    SELECT code, status, approval_status INTO v_po FROM purchase_orders WHERE id = NEW.purchase_order_id;
    IF FOUND AND v_po.status IN ('cancelled', 'closed') THEN
        RAISE EXCEPTION 'PO_NOT_RECEIVABLE|%|%', v_po.code, v_po.status;
    END IF;
    -- APR-2:【未获批的采购单不能收货】。这是审批从"状态列"变成"管控"的那一步:
    -- 收货走的是裸 INSERT,没有 RPC,所以这个触发器就是唯一的咽喉。
    IF FOUND AND v_po.approval_status <> 'approved' THEN
        RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_po.code, v_po.approval_status;
    END IF;
    RETURN NEW;
END;
$function$;

COMMIT;
