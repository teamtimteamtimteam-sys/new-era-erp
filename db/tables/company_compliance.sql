-- db/tables/company_compliance.sql
-- 公司自己的执照与资质(CMP-1)。【空着是预期状态】—— 公司尚未运营,静默正确,
-- 故无空登记簿告警;录入提醒在 docs/fresh-install-checklist.md。第一张真执照进来
-- 不需要任何 schema 变更:号码、签发方、范围、有效期、文件都在。
-- SELECT 挂 module.suppliers.view 的理由在 docs/compliance-scoping.md §C。
-- NOTE: introduced by db/migrations/2026-08-09-cmp1-certificate-types-and-compliance-framework.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

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
    updated_by     uuid,
    -- ── CMPL-1 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────────
    issue_date     date,
    -- 【没有多余的 IS NULL OR】CHECK 在表达式求值为 NULL 时放行,而
    -- NULL IN (...) 就是 NULL —— 所以这一句已经允许 NULL。多写一遍不但冗余,
    -- 还会让 check-i18n 的 sqlCheckIn 认不出这个枚举(fu 迁移改回来的)。
    status         text CHECK (status IN ('active', 'suspended', 'revoked')),
    -- ★ 把一个【数字】从散文里挪出来的那一格 ★ 见列注与 licence_storage_within_limit()
    approved_storage_limit_tonnes numeric
                   CHECK (approved_storage_limit_tonnes IS NULL OR approved_storage_limit_tonnes > 0)
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

COMMENT ON COLUMN public.company_compliance.issue_date IS
    'CMPL-1:执照的【签发日】—— 与 valid_from 是两件事。样本上两者可以不同(签发在前、生效在后),所以分两列;把它们合成一列会让"什么时候发的"不可恢复。NULL = 没录。';

COMMENT ON COLUMN public.company_compliance.status IS
    'CMPL-1:执照的【当下标准】。三个值,而且【故意不包含 expired】—— 是否过期由 valid_until 推得出来,再存一个 expired 就是同一个事实的第二份,而两份必然漂开(LOG-5a 那一课)。NULL = 没说。三值取的是【推导不出来】的那几种:active / suspended / revoked(监管方可以中止或吊销一张仍在有效期内的执照)。';

COMMENT ON COLUMN public.company_compliance.approved_storage_limit_tonnes IS
    'CMPL-1:执照批准的【贮存上限】,吨。★这是本刀把一个数字从散文里挪出来的那一格★ —— 此前它只能写在自由文本 scope 里,而**一句话不是一个可以判的值**(与 LOG-5a 把 free_time_terms 换成 free_days 逐字同一件事)。**NULL 不表示"没有上限",表示"没有人录过上限"**,而按 R2,读到 NULL 的判据必须【拒绝作判断】,绝不能放行 —— 见 licence_storage_within_limit()。';

COMMENT ON COLUMN public.company_compliance.scope IS
    '执照的适用范围与条件正文 —— **散文,给人读的**。★【没有任何判据读这一列】★(CMPL-1,2026-08-30):机器要判的那几格已经搬成了真列(目前是 approved_storage_limit_tonnes)。**不要把新的限额写进这句话里**,也不要写解析它的代码 —— 一句话不是一个可以判的值。执照正文里那些【机器判不了】的条件(车辆、人员培训、收运时段、记录保存)正是这一列该装的东西。';
