-- db/tables/contract_files.sql
-- CONTRACT-ESIGN(Tim 2026-10-29 · 2026-10-30 Q1–Q12):【一份合同的电子文件,每一个版本一行】—— 私有桶 contract-files(25 MB · 只收 PDF,Q12),
--   路径 <合同 id>/<这一行的 id>.pdf(由库定,不取文件名)。三种:
--     original      —— 未签的合同文件。草稿与生效中的合同上传或替换(Q1);替换时旧的那一行记 superseded,不删(A)。
--                      我方签过、没有作废的那一份在,就替换不了(D)—— 先作废。
--     signed        —— 我方签过的版本:服务端把签署人本人的签字样本(与选了的公司印章)盖到【在用的那一份 original】上,
--                      另存成新的一份 PDF(源文件一个字节不动)。只在生效中的合同上(Q1);每一份 original 最多一份在用的签过版本(Q9)。
--                      记下谁签的(签署人那一行 · 员工 · 名字与职衔原样)、用的是哪一张样本 / 哪一张印章、盖在第几页哪个位置(Q6)、
--                      这一次重新输入密码的时刻(Q5,来自令牌里 amr 的 password 那一项)。
--     countersigned —— 对方在系统之外签回来的扫描件(E):只在我方签过、没有作废之后,只收 PDF(Q10);它是最终版本。
--                      传上来那一天,合同的 signed_on 若还空着就填上(Q2)。
-- 【sha256 每一个版本都有】由服务端读整份对象算出来(original 与 countersigned 由 contract_file_finish 收,signed 由盖完章的那一份字节算);
--   下载时再算一次,对不上拒(与 COD 同一个形状)。
-- 【状态只往前走】uploading → current | abandoned;current → superseded(只有 original,被新的一份替换)| void(signed 与 countersigned,
--   要一句理由,签署人或 admin —— Q7)。作废的 PDF 留在桶里、照样列出来,标「作废」。作废一份签过版本,建在它上面的对方签回件一起作废。
-- 【谁读】这份合同那一侧的读码【加上】那一侧的价格码(Q8:客户合同 module.customers.view + data.view_prices;供应商合同
--   module.suppliers.view + data.view_purchase_prices)—— contract_file_readable。读不到的人在合同页上看到「受限」与理由。
-- 【谁写】只经函数(contract_file_begin · _finish · _abandon · contract_sign_begin · contract_file_void),没有任何写策略。
-- 【删行】守卫只放两种:还在 uploading / abandoned 的一行,与随着【合同本身被删】而级联下来的(只有属主路径删得掉合同 —— 一次性证明收尾用)。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contract_files (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id           uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,
    kind                  text NOT NULL CHECK (kind IN ('original', 'signed', 'countersigned')),
    source_file_id        uuid REFERENCES public.contract_files (id) ON DELETE CASCADE,
    status                text NOT NULL DEFAULT 'uploading'
                          CHECK (status IN ('uploading', 'current', 'superseded', 'void', 'abandoned')),
    file_name             text NOT NULL CHECK (length(file_name) BETWEEN 1 AND 200),
    file_size             bigint CHECK (file_size > 0),
    bucket_id             text NOT NULL DEFAULT 'contract-files' CHECK (bucket_id = 'contract-files'),
    file_path             text NOT NULL UNIQUE,
    sha256                text CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    created_at            timestamptz NOT NULL DEFAULT now(),
    created_by            uuid NOT NULL,
    stored_at             timestamptz,
    superseded_at         timestamptz,
    signatory_id          uuid REFERENCES public.contract_signatories (id) ON DELETE RESTRICT,
    signer_employee_id    uuid REFERENCES public.employees (id) ON DELETE RESTRICT,
    signer_name           text,
    signer_title          text,
    specimen_id           uuid REFERENCES public.signature_specimens (id) ON DELETE RESTRICT,
    stamp_id              uuid REFERENCES public.company_stamps (id) ON DELETE RESTRICT,
    signature_page        integer CHECK (signature_page >= 1),
    signature_x           numeric CHECK (signature_x >= 0 AND signature_x <= 1),
    signature_y           numeric CHECK (signature_y >= 0 AND signature_y <= 1),
    stamp_page            integer CHECK (stamp_page >= 1),
    stamp_x               numeric CHECK (stamp_x >= 0 AND stamp_x <= 1),
    stamp_y               numeric CHECK (stamp_y >= 0 AND stamp_y <= 1),
    password_verified_at  timestamptz,
    voided_at             timestamptz,
    voided_by             uuid,
    void_reason           text,
    CONSTRAINT contract_files_stored CHECK ((status IN ('current', 'superseded', 'void'))
                                            = (stored_at IS NOT NULL AND sha256 IS NOT NULL AND file_size IS NOT NULL)),
    CONSTRAINT contract_files_source CHECK ((kind = 'original') = (source_file_id IS NULL)),
    CONSTRAINT contract_files_signing CHECK ((kind = 'signed') = (signatory_id IS NOT NULL AND signer_employee_id IS NOT NULL
                                            AND signer_name IS NOT NULL AND signer_title IS NOT NULL AND specimen_id IS NOT NULL
                                            AND signature_page IS NOT NULL AND signature_x IS NOT NULL AND signature_y IS NOT NULL
                                            AND password_verified_at IS NOT NULL)),
    CONSTRAINT contract_files_stamp CHECK ((stamp_id IS NULL) = (stamp_page IS NULL AND stamp_x IS NULL AND stamp_y IS NULL)
                                           AND (stamp_id IS NULL OR kind = 'signed')),
    CONSTRAINT contract_files_superseded CHECK ((status = 'superseded') = (superseded_at IS NOT NULL)
                                                AND (status <> 'superseded' OR kind = 'original')),
    CONSTRAINT contract_files_void CHECK ((status = 'void') = (voided_at IS NOT NULL AND voided_by IS NOT NULL
                                          AND void_reason IS NOT NULL AND btrim(void_reason) <> '')
                                          AND (status <> 'void' OR kind IN ('signed', 'countersigned')))
);

CREATE INDEX idx_contract_files_contract ON public.contract_files (contract_id, created_at);
CREATE INDEX idx_contract_files_source ON public.contract_files (source_file_id) WHERE source_file_id IS NOT NULL;
CREATE UNIQUE INDEX contract_files_one_current_original ON public.contract_files (contract_id)
    WHERE kind = 'original' AND status = 'current';
CREATE UNIQUE INDEX contract_files_one_current_signed ON public.contract_files (source_file_id)
    WHERE kind = 'signed' AND status = 'current';
CREATE UNIQUE INDEX contract_files_one_current_countersigned ON public.contract_files (source_file_id)
    WHERE kind = 'countersigned' AND status = 'current';

COMMENT ON TABLE public.contract_files IS
    'CONTRACT-ESIGN(Tim 2026-10-29 · 2026-10-30 Q1–Q12):合同的电子文件,一个版本一行(contract-files 桶,25 MB,只收 PDF)。original(草稿 / 生效中上传或替换,旧的记 superseded)→ signed(签署人在生效中的合同上签,服务端盖章另存一份,sha256、签署人、时刻、样本、印章与位置都记下;每份 original 最多一份在用)→ countersigned(对方签回的扫描件,最终版本)。作废要理由(签署人或 admin),作废的留着。读:那一侧的读码加价格码(contract_file_readable)。只经函数写。';

CREATE TRIGGER trg_contract_files_guard
    BEFORE UPDATE OR DELETE ON public.contract_files
    FOR EACH ROW EXECUTE FUNCTION public.guard_contract_file_write();

ALTER TABLE public.contract_files ENABLE ROW LEVEL SECURITY;

-- Q8:这份合同那一侧的读码 + 价格码;还在传的一行只给传它的那个人(Storage API 传完之后读回要它)
CREATE POLICY "contract_files select by contract side and price code" ON public.contract_files
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (contract_file_readable(contract_id)
           AND (status IN ('current', 'superseded', 'void') OR created_by = (SELECT auth.uid())));

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是属主权限函数。
REVOKE ALL ON public.contract_files FROM authenticated, anon;
GRANT SELECT ON public.contract_files TO authenticated;
