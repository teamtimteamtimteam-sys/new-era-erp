-- db/tables/certificates_of_destruction.sql
-- COD-1:销毁证书 —— 交给【送料方】的那张纸,证明他交来的料被合法处理了。
--   * 【一次进货一张】,整批加工完才成立。判据是【派生】的,住在
--     db/functions/cod_delivery_completion.sql —— 不是本表的任何一列;
--   * 四个状态:pending(已成立、未签发、【没有号】)/ issued / void /
--     以及第四个【组装不出来】—— 那不是一行,是 cod_certificate_data() 的一句具名拒绝;
--   * 写入口只有四支 SECURITY DEFINER 函数(refresh_cod_for_batch / issue_cod /
--     void_cod / void_cod_internal),所以没有 INSERT / UPDATE / DELETE 策略;
--   * 字节档案是另一张表(db/tables/cod_issues.sql)—— 作废【不动它一个字】。
--
-- NOTE: introduced by db/migrations/2026-09-07-cod1-certificate-of-destruction.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.certificates_of_destruction (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbound_batch_id  uuid NOT NULL REFERENCES public.inbound_batches (id),
    -- 【这一票货是哪一天加工完的】= 消耗它的【未冲销】加工单里最晚的那个 process_date。
    -- 它是派生的,所以【必须在签发时冻进 snapshot】—— 一旦后续有单被冲销,
    -- 它就再也算不回来了(S6 点名的那一条)。
    completed_on      date NOT NULL,
    -- 【没签发就没有号】nothing that was never sent consumes a number。
    -- 号在签发那一刻由 next_cod_code() 铸出,之前一直是 NULL。
    code              text,
    status            text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'issued', 'void')),
    issued_at         timestamptz,
    issued_by         uuid,
    -- 【核验令牌:与证书号毫无关系】UUID,122 位随机。改一位数字得到的是一个
    -- 【不存在】的值,而不是另一张证书 —— 这正是它不能由号码推出来的理由。
    verification_token uuid,
    -- 【冻结的数据行】签发那一刻纸上的每一个值,解析成文字与数字,绝不是外键。
    -- 读取路径【不许】拿里面的 id 回查内容(见 contract_document_terms 的警告:
    -- *"一旦那么写,抄就退化成了引用,而退化是静悄悄的"*)。
    snapshot          jsonb,
    void_reason       text,
    voided_at         timestamptz,
    voided_by         uuid,
    -- 【作废之后顶上来的那一张】数据变了要重发时非空;因冲销而作废时【为空】——
    -- 冲销说的是"这次加工没发生",于是这票货不再是加工完的,没有替代品。
    replaced_by_cod_id uuid REFERENCES public.certificates_of_destruction (id),
    created_at        timestamptz NOT NULL DEFAULT now(),
    -- 签发过的必须号、令牌、快照、签发时刻俱全 —— 缺一个就渲染不出核验页。
    CONSTRAINT cod_issued_fields_present CHECK (
        status <> 'issued' OR (code IS NOT NULL AND verification_token IS NOT NULL
                               AND snapshot IS NOT NULL AND issued_at IS NOT NULL)),
    -- 作废必须有理由 —— 与 void_invoice 的 REASON_REQUIRED 同一条。
    CONSTRAINT cod_void_has_reason CHECK (
        status <> 'void' OR (void_reason IS NOT NULL AND btrim(void_reason) <> ''
                             AND voided_at IS NOT NULL)),
    -- 【没签发就不许有号】反向也钉住,免得将来某条路径顺手预铸一个号。
    CONSTRAINT cod_pending_has_no_number CHECK (
        status <> 'pending' OR (code IS NULL AND verification_token IS NULL AND snapshot IS NULL))
);

-- 【一票货同时只能有一张活证书】作废掉的留着 —— 供应商手里那张纸要查得到。
CREATE UNIQUE INDEX uq_cod_live_per_batch
    ON public.certificates_of_destruction (inbound_batch_id) WHERE status <> 'void';
-- 号在全库唯一(无缝编号的另一半:MAX+1 靠它不出现重号)。
CREATE UNIQUE INDEX uq_cod_code ON public.certificates_of_destruction (code) WHERE code IS NOT NULL;
CREATE UNIQUE INDEX uq_cod_token
    ON public.certificates_of_destruction (verification_token) WHERE verification_token IS NOT NULL;

COMMENT ON TABLE public.certificates_of_destruction IS
    'COD-1:销毁证书。一次进货一张,【整批加工完】才存在(判据见 cod_delivery_completion(),它是派生的、不是状态位)。四个状态:pending(已成立、未签发、【没有号】)/ issued(号、签发人、日期、印章、PDF、二维码、令牌、数据全冻)/ void(作废,行留着,字节与快照一字不动)/ 以及第四个【组装不出来】—— 那不是一行,是 cod_certificate_data() 的一句具名拒绝。【纸上没有任何产出批、没有化验、没有工序、没有人名】—— 产出是 Evoltrya 的产品,不是送料方的事。';

COMMENT ON COLUMN public.certificates_of_destruction.snapshot IS
    'COD-1:签发那一刻纸上每一个值的【副本】,解析成文字与数字。★与八个 *_issues 族的"只冻字节"是【刻意的背离】★ —— 字节证明那张纸没被改过,但一个 blob 加一个哈希【渲染不成网页】;核验页要显示证书的内容,所以必须有一行数据。纸是副本,核验页是原件。里面的 *_id 只回答"这来自哪一行",【任何读取路径都不许拿它回查内容】。';

ALTER TABLE public.certificates_of_destruction ENABLE ROW LEVEL SECURITY;

-- 【读:一个权限码,不多不少】S7 的裁定 —— 判据必须正好是一个能力,
-- 而且这张表【不接受供应商 id 作参数】,所以它成不了一扇查供应商的门。
CREATE POLICY "certificates_of_destruction select by permission"
    ON public.certificates_of_destruction
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('action.issue_cod'::text));
-- 【没有 INSERT / UPDATE / DELETE 策略,这是刻意的】唯一写入口是本刀的
-- 四支 SECURITY DEFINER 函数。档案不该有第二个写法。

-- 【签发之后,证书的内容一个字都不许改 —— 只许作废】
-- 与 invoices 同形:单据行本身可变(只能变成 void),而字节档案完全不可变。
-- 守卫函数见 db/functions/guard_cod_immutable_after_issue.sql 与
-- db/functions/guard_cod_no_delete_after_issue.sql(与 traceability_report_issues
-- 同一条约定:挂载语句住在表这边,函数体住在 db/functions/)。
CREATE TRIGGER trg_cod_immutable_after_issue
    BEFORE UPDATE ON public.certificates_of_destruction
    FOR EACH ROW EXECUTE FUNCTION public.guard_cod_immutable_after_issue();

-- 【签发过的证书不许硬删】pending 的可以(它从来不算数,见 refresh_cod_for_batch)。
CREATE TRIGGER trg_cod_no_delete_after_issue
    BEFORE DELETE ON public.certificates_of_destruction
    FOR EACH ROW EXECUTE FUNCTION public.guard_cod_no_delete_after_issue();
