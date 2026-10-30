-- db/tables/company_stamps.sql
-- CONTRACT-ESIGN(Tim 2026-10-29 · 2026-10-30 Q3):【公司印章】—— admin 上传一次印章图(PNG,私有桶 signing-assets,路径 stamps/<这一行的 id>.png);
--   换一张时旧的一行记 superseded_at(换掉留历史)。只有签署人名单上的人能把它盖到一份合同上(contract_sign_begin 判)。
--   写只经 company_stamp_record(action.manage_signatories,只授 admin)。
-- 【谁读】持 action.manage_signatories 的人,与此刻在签署人名单上的人(签字页要预览它)。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.company_stamps (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    file_path      text NOT NULL UNIQUE
                   CHECK (file_path ~ '^stamps/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.png$'),
    file_size      bigint NOT NULL CHECK (file_size > 0),
    sha256         text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid NOT NULL,
    superseded_at  timestamptz
);

CREATE UNIQUE INDEX company_stamps_one_current ON public.company_stamps ((true)) WHERE superseded_at IS NULL;

COMMENT ON TABLE public.company_stamps IS
    'CONTRACT-ESIGN(Tim 2026-10-29 · Q3):公司印章图(PNG,signing-assets 桶)。只经 company_stamp_record 写(action.manage_signatories);换一张时旧的记 superseded_at,不删。只有签署人能盖。';

CREATE TRIGGER trg_company_stamps_guard
    BEFORE UPDATE ON public.company_stamps
    FOR EACH ROW EXECUTE FUNCTION public.guard_signing_asset_write();

ALTER TABLE public.company_stamps ENABLE ROW LEVEL SECURITY;

CREATE POLICY "company_stamps select by permission or signatory" ON public.company_stamps
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('action.manage_signatories'::text))
        OR (SELECT contract_signatory_active()));

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是 company_stamp_record(属主权限)。
REVOKE ALL ON public.company_stamps FROM authenticated, anon;
GRANT SELECT ON public.company_stamps TO authenticated;
