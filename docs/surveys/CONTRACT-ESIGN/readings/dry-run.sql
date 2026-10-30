\set ON_ERROR_STOP 1
SET lock_timeout = '10s';
\timing on
BEGIN;
SELECT 'PROOF|A|postgres|' || json_build_object(
  'seven_grants', (SELECT count(*) || ' ' || md5(string_agg(r.code || '/' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code IN ('admin','cco','cfo','cto','finance','gm','warehouse')),
  'six_grants_no_admin', (SELECT count(*) || ' ' || md5(string_agg(r.code || '/' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code IN ('admin','cco','cfo','cto','finance','gm','warehouse') AND r.code <> 'admin'),
  'user_roles', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.user_roles t),
  'change_log', (SELECT count(*) || ' max ' || max(seq) FROM public.change_log),
  'contracts', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contracts t), 'cod_issues', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.cod_issues t),
  'buckets', (SELECT count(*) FROM storage.buckets), 'storage_policies', (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage'),
  'anon_relations', (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r','v','m','p','f')
                       AND has_table_privilege('anon', c.oid, 'SELECT')),
  'new_tables', (SELECT string_agg(relname, ',' ORDER BY relname) FROM pg_class WHERE relnamespace = 'public'::regnamespace
                   AND relname IN ('contract_files','contract_signatories','signature_specimens','company_stamps')),
  'manage_signatories_holders', (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
                   WHERE rp.permission_code = 'action.manage_signatories'),
  'approvals', (SELECT approvals_enabled FROM public.finance_settings),
  'req_cal', (SELECT COALESCE(require_calibrated_since::text, 'NULL') FROM public.ingest_settings))::text;
-- ── migration body ──

-- ── 0 · 前提:线上是我们以为的那个样子 ──
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'CES_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.contract_files') IS NOT NULL OR to_regclass('public.contract_signatories') IS NOT NULL
       OR to_regclass('public.signature_specimens') IS NOT NULL OR to_regclass('public.company_stamps') IS NOT NULL
       OR EXISTS (SELECT 1 FROM storage.buckets WHERE id IN ('contract-files', 'signing-assets'))
       OR EXISTS (SELECT 1 FROM permissions WHERE code = 'action.manage_signatories') THEN
        RAISE EXCEPTION 'CES_PRE|the e-sign tables, buckets or code already exist';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 58 OR (SELECT count(*) FROM storage.buckets) <> 21 THEN
        RAISE EXCEPTION 'CES_PRE|expected 58 storage policies and 21 buckets';
    END IF;
    IF (SELECT count(*) FROM roles) <> 11 OR NOT EXISTS (SELECT 1 FROM roles WHERE code = 'admin') THEN
        RAISE EXCEPTION 'CES_PRE|expected the 11 roles including admin';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'CES_PRE|require_calibrated_since must be empty and the two COD byte strings recorded';
    END IF;
END;
$pre$;
CREATE TEMP TABLE ces_policies_before ON COMMIT DROP AS
SELECT policyname, cmd, roles::text AS roles, COALESCE(qual, '') AS qual, COALESCE(with_check, '') AS with_check FROM pg_policies WHERE schemaname = 'storage';
CREATE TEMP TABLE ces_buckets_before ON COMMIT DROP AS
SELECT id, name, public, file_size_limit, allowed_mime_types::text AS mimes FROM storage.buckets;
CREATE TEMP TABLE ces_grants_before ON COMMIT DROP AS
SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE ces_user_roles_before ON COMMIT DROP AS
SELECT user_id, role_id, revoked_at FROM user_roles;

-- ── 1 · 新码(与 db/tables/permissions.sql 同一行)+ admin 持它(admin 持目录里的每一个码 —— db/tables/role_permissions.sql)──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.manage_signatories', 'action', 'Manage contract signatories and the company stamp', '管理合同签署人与公司印章', 'Add and remove the named people who may sign contracts in the system, and upload the company stamp. Signing itself needs no code: the person must be on the list and able to read that contract. A signatory or a holder of this code can void a signed version with a reason.', '增减可以在系统里签合同的具名签署人,上传公司印章。签字本身不要码:那个人要在名单上、读得到那份合同。签署人或持本码的人可以作废一份签过的版本(要理由)。', 1011);
UPDATE public.permissions SET requires_view_any = ARRAY['action.manage_signatories','module.suppliers.view'] WHERE code = 'action.manage_signatories';
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'action.manage_signatories' FROM public.roles r WHERE r.code = 'admin'
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 2 · 只读既有表的判据与守卫(镜像原样:db/functions/contract_file_readable.sql)──
-- db/functions/contract_file_readable.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q8):调用者读不读得到这份合同的电子文件 —— 合同那一侧的读码【加上】那一侧的价格码:
--   客户合同 module.customers.view + data.view_prices;供应商合同 module.suppliers.view + data.view_purchase_prices。
--   PDF 里写着价格,所以文件跟着价格码走(GOLIVE-1 第 12 行按那一侧遮价格,同一个判据)。合同不存在 → false(关着失败)。
--   contract_files 的读策略、contract-files 桶的存储判据与写那几支函数问的都是这一句。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_file_readable(p_contract_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE((SELECT CASE WHEN c.customer_id IS NOT NULL THEN has_permission('module.customers.view') AND has_permission('data.view_prices')
                                 WHEN c.supplier_id IS NOT NULL THEN has_permission('module.suppliers.view') AND has_permission('data.view_purchase_prices')
                                 ELSE false END
                       FROM contracts c WHERE c.id = p_contract_id AND c.deleted_at IS NULL), false);
$function$;
-- db/functions/signing_password_verified_at.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q5):这个令牌【最近一次凭密码登录】的时刻 —— 令牌 amr 里 method = password 那一项的 timestamp。
--   签字的服务端动作用调用者刚刚重新输入的密码另开一个会话(不换掉浏览器里那一个),签字那几步都用这个新会话的令牌;
--   contract_sign_begin 要求这个时刻在 5 分钟之内 —— 于是"签字时重新输入了密码"是库自己从令牌里读出来的,不是谁说了算。
--   没有这一项 / 读不出 → NULL(调用方按名拒)。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.signing_password_verified_at()
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ts timestamptz;
BEGIN
    SELECT max(to_timestamp((a ->> 'timestamp')::double precision)) INTO v_ts
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(auth.jwt() -> 'amr') = 'array' THEN auth.jwt() -> 'amr' ELSE '[]'::jsonb END) a
     WHERE a ->> 'method' = 'password' AND (a ->> 'timestamp') ~ '^[0-9]+(\.[0-9]+)?$';
    RETURN v_ts;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$function$;
-- db/functions/guard_signing_asset_write.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q4 · Q3):签字样本(signature_specimens)与公司印章(company_stamps)共用的守卫 ——
--   一行只许被换下一次(superseded_at 从空到有),别的列一个都不许改。删行不挡:盖过 / 签过的那一张由 contract_files 的外键(RESTRICT)护着,
--   没用过的一张只有属主路径删得掉(没有任何删除策略)—— 一次性证明收尾时用。函数之外的路(postgres 手改)也挡在这里。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.guard_signing_asset_write()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF (to_jsonb(NEW) - 'superseded_at') IS DISTINCT FROM (to_jsonb(OLD) - 'superseded_at')
       OR OLD.superseded_at IS NOT NULL OR NEW.superseded_at IS NULL THEN
        RAISE EXCEPTION 'SIGNING_ASSET_IMMUTABLE|%', TG_TABLE_NAME;
    END IF;
    RETURN NEW;
END;
$function$;
-- db/functions/guard_contract_file_write.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q1 · Q7):contract_files 的守卫 —— 一个版本存下之后,它的字节、哈希、签署人、样本、印章与位置一个都不许改。
--   只放这几步(其余任何一列变了 → CONTRACT_FILE_IMMUTABLE|<id>):
--     uploading → current     存下:sha256 · file_size · stored_at 从空到有
--     uploading → abandoned   没传成
--     current   → superseded  只有 original,被新的一份替换:superseded_at
--     current   → void        只有 signed / countersigned:voided_at · voided_by · void_reason
--   删行只放两种:还在 uploading / abandoned 的一行;以及【合同本身已经不在了】(合同被删 → 级联下来;只有属主路径删得掉合同)。
--   别的删除 → CONTRACT_FILE_NO_DELETE|<id>。属主路径也挡(与 COD 的存档表同一条:函数之外的路也不许改一份签过的文件)。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.guard_contract_file_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_changed text[];
    v_allowed text[];
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status IN ('uploading', 'abandoned') OR NOT EXISTS (SELECT 1 FROM contracts c WHERE c.id = OLD.contract_id) THEN
            RETURN OLD;
        END IF;
        RAISE EXCEPTION 'CONTRACT_FILE_NO_DELETE|%', OLD.id;
    END IF;
    SELECT COALESCE(array_agg(n.key ORDER BY n.key), ARRAY[]::text[]) INTO v_changed
      FROM jsonb_each(to_jsonb(NEW)) n
      JOIN jsonb_each(to_jsonb(OLD)) o ON o.key = n.key
     WHERE n.value IS DISTINCT FROM o.value;
    v_allowed := CASE
        WHEN OLD.status = 'uploading' AND NEW.status = 'current' THEN ARRAY['status', 'sha256', 'file_size', 'stored_at']
        WHEN OLD.status = 'uploading' AND NEW.status = 'abandoned' THEN ARRAY['status']
        WHEN OLD.status = 'current' AND NEW.status = 'superseded' AND OLD.kind = 'original' THEN ARRAY['status', 'superseded_at']
        WHEN OLD.status = 'current' AND NEW.status = 'void' AND OLD.kind IN ('signed', 'countersigned')
            THEN ARRAY['status', 'voided_at', 'voided_by', 'void_reason']
        ELSE NULL END;
    IF v_allowed IS NULL OR NOT (v_changed <@ v_allowed)
       OR (OLD.status = 'uploading' AND NEW.status = 'current' AND OLD.sha256 IS NOT NULL)
       OR (OLD.status = 'uploading' AND NEW.status = 'current' AND OLD.file_size IS NOT NULL AND 'file_size' = ANY (v_changed)) THEN
        RAISE EXCEPTION 'CONTRACT_FILE_IMMUTABLE|%', OLD.id;
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 3 · 名单(镜像原样:db/tables/contract_signatories.sql)──
-- db/tables/contract_signatories.sql
-- CONTRACT-ESIGN(Tim 2026-10-29 · 2026-10-30 Q3):【签署人名单】—— 谁可以代表公司在系统里签合同。是【具名的人】,不是一个角色:
--   一行 = 一名有登录账号的员工 + 他签字时印出来的职衔。加入与移除都只经函数(contract_signatory_add / _remove),
--   要 action.manage_signatories(只授 admin);两次都进变更记录。
-- 【移除不删行】removed_at / removed_by 记下来;移除不作废他已经签过的任何一份(Q7)—— contract_files.signatory_id 指着这一行,
--   外键 RESTRICT 保证一份签过的文件永远找得到它的签署人那一行。一个人同一时刻最多一行在册(部分唯一索引);再加入是新的一行。
-- 【谁读】持 action.manage_signatories 的人读全部(设置页);每个人读得到自己那一行(签字页要知道自己在不在册)。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contract_signatories (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id  uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    title        text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 120),
    added_at     timestamptz NOT NULL DEFAULT now(),
    added_by     uuid NOT NULL,
    removed_at   timestamptz,
    removed_by   uuid,
    CONSTRAINT contract_signatories_removed CHECK ((removed_at IS NULL) = (removed_by IS NULL))
);

CREATE UNIQUE INDEX contract_signatories_one_active ON public.contract_signatories (employee_id) WHERE removed_at IS NULL;

COMMENT ON TABLE public.contract_signatories IS
    'CONTRACT-ESIGN(Tim 2026-10-29 · Q3):签署人名单 —— 具名的人(一名有登录账号的员工 + 职衔),不是角色。只经 contract_signatory_add / _remove 写(action.manage_signatories,只授 admin)。移除只记 removed_at,不作废他签过的任何一份(Q7)。';

-- 【只许移除一次,别的列不可改】函数之外的路也挡在这里。删行不挡:签过字的那一行由 contract_files 的外键(RESTRICT)护着,
--   没签过字的一行只有属主路径删得掉(没有任何删除策略)—— 一次性证明收尾时用。
CREATE OR REPLACE FUNCTION public.guard_contract_signatory_write()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF (to_jsonb(NEW) - 'removed_at' - 'removed_by') IS DISTINCT FROM (to_jsonb(OLD) - 'removed_at' - 'removed_by')
       OR OLD.removed_at IS NOT NULL THEN
        RAISE EXCEPTION 'CONTRACT_SIGNATORY_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_contract_signatories_guard
    BEFORE UPDATE ON public.contract_signatories
    FOR EACH ROW EXECUTE FUNCTION public.guard_contract_signatory_write();

ALTER TABLE public.contract_signatories ENABLE ROW LEVEL SECURITY;

CREATE POLICY "contract_signatories select by permission or own row" ON public.contract_signatories
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('action.manage_signatories'::text))
        OR employee_id = (SELECT current_user_employee()));

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是属主权限函数(contract_signatory_add · _remove)。
REVOKE ALL ON public.contract_signatories FROM authenticated, anon;
GRANT SELECT ON public.contract_signatories TO authenticated;

-- ── 4 · 「我在不在名单上」(读名单那张表)(镜像原样:db/functions/contract_signatory_active.sql)──
-- db/functions/contract_signatory_active.sql
-- CONTRACT-ESIGN(Tim 2026-10-29 · Q3):调用者此刻在不在签署人名单上(contract_signatories 里有他员工档案的一行、没被移除)。
--   公司印章的读策略、signing-assets 的存储判据与签字 / 作废的那几支函数问的都是这一句 —— 单独一支,不内联。
--   SECURITY DEFINER:名单对普通读者只露自己那一行,而这里也只问"我自己"。没有员工档案的会话 → false。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_signatory_active()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(EXISTS (SELECT 1 FROM contract_signatories s
                             WHERE s.employee_id = current_user_employee() AND s.removed_at IS NULL), false);
$function$;

-- ── 5 · 签字样本(镜像原样:db/tables/signature_specimens.sql)──
-- db/tables/signature_specimens.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q4):【签字样本】—— 每一名签署人【自己】、以自己的账号登录,在屏幕上画一次自己的签名;
--   存成一张 PNG(私有桶 signing-assets,路径 specimens/<员工 id>/<这一行的 id>.png),这一行记下它的路径、大小与 sha256。
--   签字时盖到 PDF 上的就是当时【在用的那一张】(superseded_at 为空的那一行),contract_files.specimen_id 记下是哪一张。
-- 【只有本人写得进来】signature_specimen_record 只认调用者自己的员工 id、而且调用者此刻在签署人名单上;
--   admin 替别人设不了(Q4)—— 存储的上传策略同样只放行 specimens/<自己的员工 id>/ 这一段路径。
-- 【换一张不删旧的】新的一行进来,旧的那一行记 superseded_at(Q4:换掉留历史);旧图对象留在桶里。
-- 【谁读】本人读自己的;持 action.manage_signatories 的人读得到行(设置页显示"有没有样本"),读不到图(存储的读策略只给本人)。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.signature_specimens (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id    uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    file_path      text NOT NULL UNIQUE
                   CHECK (file_path ~ '^specimens/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.png$'),
    file_size      bigint NOT NULL CHECK (file_size > 0),
    sha256         text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid NOT NULL,
    superseded_at  timestamptz
);

CREATE UNIQUE INDEX signature_specimens_one_current ON public.signature_specimens (employee_id) WHERE superseded_at IS NULL;

COMMENT ON TABLE public.signature_specimens IS
    'CONTRACT-ESIGN(Tim 2026-10-30 Q4):签署人本人在屏幕上画的签名(PNG,signing-assets 桶)。只经 signature_specimen_record 写,只认调用者自己;换一张时旧的记 superseded_at,不删。';

-- 【只许被换下一次,别的列不可改】守卫函数在 db/functions/guard_signing_asset_write.sql(两张表共用)。
CREATE TRIGGER trg_signature_specimens_guard
    BEFORE UPDATE ON public.signature_specimens
    FOR EACH ROW EXECUTE FUNCTION public.guard_signing_asset_write();

ALTER TABLE public.signature_specimens ENABLE ROW LEVEL SECURITY;

CREATE POLICY "signature_specimens select own or by permission" ON public.signature_specimens
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = (SELECT current_user_employee())
        OR (SELECT has_permission('action.manage_signatories'::text)));

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是 signature_specimen_record(属主权限)。
REVOKE ALL ON public.signature_specimens FROM authenticated, anon;
GRANT SELECT ON public.signature_specimens TO authenticated;

-- ── 6 · 公司印章(镜像原样:db/tables/company_stamps.sql)──
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

-- ── 7 · 合同文件(镜像原样:db/tables/contract_files.sql)──
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

-- ── 8 · 读新表的函数(镜像原样)──
-- db/functions/contract_signatory_add.sql
-- CONTRACT-ESIGN(Tim 2026-10-29 · Q3):把一名员工加进签署人名单(设置页 · 签署人)。要 action.manage_signatories(只授 admin)。
--   按名拒:没有这个码 → PERMISSION_DENIED|action.manage_signatories;员工不存在 / 已删 → CONTRACT_SIGNATORY_EMPLOYEE_NOT_FOUND;
--   员工没有登录账号(签字要他以自己的账号登录)→ CONTRACT_SIGNATORY_NO_LOGIN|<员工号>;已经在册 → CONTRACT_SIGNATORY_ALREADY_LISTED|<员工号>;
--   职衔空(签字时要印出来)→ CONTRACT_SIGNATORY_TITLE_REQUIRED。过了写一行(变更记录记下谁、何时加了谁)。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_signatory_add(p_employee_id uuid, p_title text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_e  employees%ROWTYPE;
    v_id uuid;
BEGIN
    PERFORM require_permission('action.manage_signatories');
    SELECT * INTO v_e FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_SIGNATORY_EMPLOYEE_NOT_FOUND';
    END IF;
    IF v_e.user_id IS NULL AND NOT EXISTS (SELECT 1 FROM employee_accounts a WHERE a.employee_id = v_e.id) THEN
        RAISE EXCEPTION 'CONTRACT_SIGNATORY_NO_LOGIN|%', v_e.code;
    END IF;
    IF EXISTS (SELECT 1 FROM contract_signatories s WHERE s.employee_id = v_e.id AND s.removed_at IS NULL) THEN
        RAISE EXCEPTION 'CONTRACT_SIGNATORY_ALREADY_LISTED|%', v_e.code;
    END IF;
    IF p_title IS NULL OR btrim(p_title) = '' THEN
        RAISE EXCEPTION 'CONTRACT_SIGNATORY_TITLE_REQUIRED';
    END IF;
    INSERT INTO contract_signatories (employee_id, title, added_by)
    VALUES (v_e.id, left(btrim(p_title), 120), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('id', v_id, 'employee_id', v_e.id);
END;
$function$;
-- db/functions/contract_signatory_remove.sql
-- CONTRACT-ESIGN(Tim 2026-10-29 · Q3 · Q7):把一名签署人移出名单 —— 那一行记 removed_at / removed_by,不删;
--   他已经签过的每一份照旧有效(Q7:移除不作废任何一份)。要 action.manage_signatories。
--   按名拒:没有码 → PERMISSION_DENIED|action.manage_signatories;这一行不存在或已经移除 → CONTRACT_SIGNATORY_NOT_LISTED。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_signatory_remove(p_signatory_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.manage_signatories');
    UPDATE contract_signatories SET removed_at = now(), removed_by = auth.uid()
     WHERE id = p_signatory_id AND removed_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_SIGNATORY_NOT_LISTED';
    END IF;
    RETURN jsonb_build_object('id', p_signatory_id, 'state', 'removed');
END;
$function$;
-- db/functions/signing_asset_can_upload.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q3 · Q4):【存储策略的判据】—— 这个会话能不能往 signing-assets 的这一条路径传字节。
--   specimens/<自己的员工 id>/<uuid>.png —— 只有【本人】、而且此刻在签署人名单上(Q4:admin 替别人设不了签名);
--   stamps/<uuid>.png                  —— 只有持 action.manage_signatories 的人(Q3)。
--   一条已经被登记过的路径不再收(signature_specimens / company_stamps 里有它)。改与删没有策略。【绝不抛】,不成立就回 false。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.signing_asset_can_upload(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(p_bucket = 'signing-assets'
       AND ((p_name ~ ('^specimens/' || current_user_employee()::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.png$')
             AND contract_signatory_active()
             AND NOT EXISTS (SELECT 1 FROM signature_specimens s WHERE s.file_path = p_name))
         OR (p_name ~ '^stamps/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.png$'
             AND has_permission('action.manage_signatories')
             AND NOT EXISTS (SELECT 1 FROM company_stamps s WHERE s.file_path = p_name))), false)
$function$;
-- db/functions/signing_asset_can_read.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q3 · Q4):【存储策略的判据】—— 这个会话能不能读 signing-assets 里的这一个对象。
--   specimens/<员工 id>/… —— 只有本人(签字时服务端以本人的会话取它;admin 看得到"有没有样本",看不到那张图);
--   stamps/…            —— 持 action.manage_signatories 的人,与此刻在签署人名单上的人(签字页预览、服务端盖章)。【绝不抛】。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.signing_asset_can_read(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(p_bucket = 'signing-assets'
       AND ((current_user_employee() IS NOT NULL AND p_name LIKE 'specimens/' || current_user_employee()::text || '/%')
         OR (p_name LIKE 'stamps/%' AND (has_permission('action.manage_signatories') OR contract_signatory_active()))), false)
$function$;
-- db/functions/signature_specimen_record.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q4):【登记签署人本人刚传上来的签字样本】—— 服务端动作把画好的签名重编码成 PNG、以本人的会话传到
--   signing-assets 的 specimens/<本人员工 id>/<p_specimen_id>.png,然后调这一支。它在【之前那一张】上记 superseded_at(换掉留历史),写新的一行。
--   按名拒:调用者没有员工档案或此刻不在签署人名单上 → CONTRACT_SIGN_NOT_SIGNATORY;对象不在 → SIGNING_ASSET_NOT_STORED;
--   不是 PNG → SIGNING_ASSET_TYPE;sha256 不是 64 位小写十六进制 → SIGNING_ASSET_HASH_INVALID。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.signature_specimen_record(p_specimen_id uuid, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp  uuid := current_user_employee();
    v_path text;
    v_meta jsonb;
BEGIN
    IF v_emp IS NULL OR NOT contract_signatory_active() THEN
        RAISE EXCEPTION 'CONTRACT_SIGN_NOT_SIGNATORY';
    END IF;
    IF p_sha256 IS NULL OR p_sha256 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'SIGNING_ASSET_HASH_INVALID';
    END IF;
    v_path := 'specimens/' || v_emp::text || '/' || p_specimen_id::text || '.png';
    SELECT COALESCE(o.metadata, '{}'::jsonb) INTO v_meta FROM storage.objects o WHERE o.bucket_id = 'signing-assets' AND o.name = v_path;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SIGNING_ASSET_NOT_STORED';
    END IF;
    IF v_meta ->> 'mimetype' IS DISTINCT FROM 'image/png' OR NOT (v_meta ? 'size') THEN
        RAISE EXCEPTION 'SIGNING_ASSET_TYPE';
    END IF;
    UPDATE signature_specimens SET superseded_at = now() WHERE employee_id = v_emp AND superseded_at IS NULL;
    INSERT INTO signature_specimens (id, employee_id, file_path, file_size, sha256, created_by)
    VALUES (p_specimen_id, v_emp, v_path, (v_meta ->> 'size')::bigint, p_sha256, auth.uid());
    RETURN jsonb_build_object('id', p_specimen_id, 'path', v_path);
END;
$function$;
-- db/functions/company_stamp_record.sql
-- CONTRACT-ESIGN(Tim 2026-10-29 · Q3):【登记 admin 刚传上来的公司印章】—— 服务端动作把上传的图重编码成 PNG、传到 signing-assets 的
--   stamps/<p_stamp_id>.png,然后调这一支:之前在用的那一张记 superseded_at(换掉留历史),写新的一行。要 action.manage_signatories。
--   按名拒:没有码 → PERMISSION_DENIED|action.manage_signatories;对象不在 → SIGNING_ASSET_NOT_STORED;不是 PNG → SIGNING_ASSET_TYPE;
--   sha256 形状不对 → SIGNING_ASSET_HASH_INVALID。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.company_stamp_record(p_stamp_id uuid, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_path text := 'stamps/' || p_stamp_id::text || '.png';
    v_meta jsonb;
BEGIN
    PERFORM require_permission('action.manage_signatories');
    IF p_sha256 IS NULL OR p_sha256 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'SIGNING_ASSET_HASH_INVALID';
    END IF;
    SELECT COALESCE(o.metadata, '{}'::jsonb) INTO v_meta FROM storage.objects o WHERE o.bucket_id = 'signing-assets' AND o.name = v_path;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SIGNING_ASSET_NOT_STORED';
    END IF;
    IF v_meta ->> 'mimetype' IS DISTINCT FROM 'image/png' OR NOT (v_meta ? 'size') THEN
        RAISE EXCEPTION 'SIGNING_ASSET_TYPE';
    END IF;
    UPDATE company_stamps SET superseded_at = now() WHERE superseded_at IS NULL;
    INSERT INTO company_stamps (id, file_path, file_size, sha256, created_by)
    VALUES (p_stamp_id, v_path, (v_meta ->> 'size')::bigint, p_sha256, auth.uid());
    RETURN jsonb_build_object('id', p_stamp_id, 'path', v_path);
END;
$function$;
-- db/functions/contract_file_begin.sql
-- CONTRACT-ESIGN(Tim 2026-10-29 · 2026-10-30 Q1 · Q10 · Q12):【开始给一份合同传一个文件】—— 在【任何一个字节存下之前】判完,过了才登记一行
--   uploading、给出私有桶 contract-files 里的路径;字节由浏览器直传(GOLIVE-2 第 9 行的形状),contract_file_finish 确认。
--   p_kind:'original'(未签的合同文件)或 'countersigned'(对方签回的扫描件)。签过的版本不走这里(contract_sign_begin)。
--   依次按名拒(第一条不过就停,什么都不写):
--     没有 action.contract_terms                                         → PERMISSION_DENIED|action.contract_terms
--     合同不存在 / 已删                                                  → CONTRACT_NOT_FOUND
--     读不到这份合同的文件(那一侧的读码 + 价格码,Q8)                  → CONTRACT_FILE_RESTRICTED|<合同号>
--     种类不是这两种                                                     → CONTRACT_FILE_KIND_INVALID|<种类>
--     original:合同不在 draft / active(Q1)                            → CONTRACT_FILE_CONTRACT_CLOSED|<合同号>|<状态>
--     original:在用的那一份已经被我方签过、没有作废(D)                → CONTRACT_FILE_SIGNED_LOCKED|<合同号>
--     countersigned:没有一份在用的我方签过版本(Q10:先签)              → CONTRACT_COUNTERSIGN_NEEDS_SIGNED|<合同号>
--     countersigned:那一份签过版本已经有了在用的签回件(它是最终版本)  → CONTRACT_FILE_COUNTERSIGNED_FINAL|<合同号>
--     不是 PDF(Q10 · Q12:两种都只收 PDF)                              → CONTRACT_FILE_TYPE_NOT_ACCEPTED|<类型>
--     大小 ≤ 0 / 超过 25 MB(Q12,桶上也是这个数)                       → CONTRACT_FILE_EMPTY / CONTRACT_FILE_TOO_LARGE|26214400
--     文件名空                                                           → CONTRACT_FILE_NAME_REQUIRED
--     整个项目的存储已到 900 MB(CLAIM-RECEIPTS-1 Q10 那一条,免费方案)  → CONTRACT_FILE_STORAGE_FULL|<已用字节数>|<上限字节数>
--   过了:写一行(路径 = <合同 id>/<这一行的 id>.pdf),回 id · 桶 · 路径。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_file_begin(p_contract_id uuid, p_kind text, p_file_name text, p_file_type text, p_file_size bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c       contracts%ROWTYPE;
    v_orig    contract_files%ROWTYPE;
    v_signed  uuid;
    v_source  uuid;
    v_max     constant bigint := 26214400;    -- 25 MB(Tim Q12;与桶的 file_size_limit 同一个数)
    v_ceiling constant bigint := 943718400;   -- 900 MB(CLAIM-RECEIPTS-1 Q10,免费方案 1 GB)
    v_used    bigint;
    v_id      uuid := gen_random_uuid();
    v_path    text;
    v_name    text := left(btrim(regexp_replace(COALESCE(p_file_name, ''), '[\\/[:cntrl:]]+', '_', 'g')), 200);
BEGIN
    PERFORM require_permission('action.contract_terms');
    SELECT * INTO v_c FROM contracts WHERE id = p_contract_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND';
    END IF;
    IF NOT contract_file_readable(v_c.id) THEN
        RAISE EXCEPTION 'CONTRACT_FILE_RESTRICTED|%', v_c.code;
    END IF;
    IF p_kind IS NULL OR p_kind NOT IN ('original', 'countersigned') THEN
        RAISE EXCEPTION 'CONTRACT_FILE_KIND_INVALID|%', COALESCE(p_kind, '');
    END IF;
    SELECT * INTO v_orig FROM contract_files f WHERE f.contract_id = v_c.id AND f.kind = 'original' AND f.status = 'current';
    IF FOUND THEN
        SELECT f.id INTO v_signed FROM contract_files f WHERE f.source_file_id = v_orig.id AND f.kind = 'signed' AND f.status = 'current';
    END IF;
    IF p_kind = 'original' THEN
        IF v_c.status NOT IN ('draft', 'active') THEN
            RAISE EXCEPTION 'CONTRACT_FILE_CONTRACT_CLOSED|%|%', v_c.code, v_c.status;
        END IF;
        IF v_signed IS NOT NULL THEN
            RAISE EXCEPTION 'CONTRACT_FILE_SIGNED_LOCKED|%', v_c.code;
        END IF;
    ELSE
        IF v_signed IS NULL THEN
            RAISE EXCEPTION 'CONTRACT_COUNTERSIGN_NEEDS_SIGNED|%', v_c.code;
        END IF;
        IF EXISTS (SELECT 1 FROM contract_files f WHERE f.source_file_id = v_signed AND f.kind = 'countersigned' AND f.status = 'current') THEN
            RAISE EXCEPTION 'CONTRACT_FILE_COUNTERSIGNED_FINAL|%', v_c.code;
        END IF;
        v_source := v_signed;
    END IF;
    IF p_file_type IS DISTINCT FROM 'application/pdf' THEN
        RAISE EXCEPTION 'CONTRACT_FILE_TYPE_NOT_ACCEPTED|%', COALESCE(p_file_type, '');
    END IF;
    IF p_file_size IS NULL OR p_file_size <= 0 THEN
        RAISE EXCEPTION 'CONTRACT_FILE_EMPTY';
    END IF;
    IF p_file_size > v_max THEN
        RAISE EXCEPTION 'CONTRACT_FILE_TOO_LARGE|%', v_max;
    END IF;
    IF v_name = '' THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NAME_REQUIRED';
    END IF;
    SELECT COALESCE(sum((o.metadata ->> 'size')::bigint), 0) INTO v_used FROM storage.objects o;
    IF v_used + p_file_size > v_ceiling THEN
        RAISE EXCEPTION 'CONTRACT_FILE_STORAGE_FULL|%|%', v_used, v_ceiling;
    END IF;
    v_path := v_c.id::text || '/' || v_id::text || '.pdf';
    INSERT INTO contract_files (id, contract_id, kind, source_file_id, file_name, file_size, file_path, created_by)
    VALUES (v_id, v_c.id, p_kind, v_source, v_name, p_file_size, v_path, auth.uid());
    RETURN jsonb_build_object('id', v_id, 'bucket', 'contract-files', 'path', v_path);
END;
$function$;
-- db/functions/contract_file_finish.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 A · D · E · Q2):【一个合同文件的字节到了】—— 确认对象在桶里、是 PDF、大小对得上,收下服务端算出来的 sha256,
--   这一行变成 current。三种各自再判一次(begin 与这一步之间合同可能变了):
--     original      合同仍在 draft / active、在用的那一份没有被签;之前在用的那一份记 superseded(A:替换留历史)。
--     signed        源文件仍是在用的 original、合同仍是 active、还没有别的在用签过版本、签它的人仍在名单上;大小取存下来的那一份。
--     countersigned 它下面那份签过版本仍在用、还没有在用的签回件;合同的 signed_on 若还空着,填成新加坡的今天(Q2)。
--   按名拒:不是自己登记的 → CONTRACT_FILE_NOT_FOUND;不在 uploading → CONTRACT_FILE_NOT_UPLOADING|<状态>;
--     对象不在 → CONTRACT_FILE_NOT_STORED;不是 PDF / 大小对不上 → CONTRACT_FILE_MISMATCH;sha256 形状不对 → CONTRACT_FILE_HASH_INVALID;
--     合同状态 / 已签 / 签回件 / 签署人 —— 与 begin 那几条同名。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_file_finish(p_file_id uuid, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r      contract_files%ROWTYPE;
    v_c    contracts%ROWTYPE;
    v_src  contract_files%ROWTYPE;
    v_meta jsonb;
    v_size bigint;
BEGIN
    SELECT * INTO r FROM contract_files x WHERE x.id = p_file_id AND x.created_by = auth.uid();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_FOUND';
    END IF;
    SELECT * INTO v_c FROM contracts WHERE id = r.contract_id FOR UPDATE;
    SELECT * INTO r FROM contract_files x WHERE x.id = p_file_id FOR UPDATE;
    IF r.status <> 'uploading' THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_UPLOADING|%', r.status;
    END IF;
    IF p_sha256 IS NULL OR p_sha256 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'CONTRACT_FILE_HASH_INVALID';
    END IF;
    SELECT COALESCE(o.metadata, '{}'::jsonb) INTO v_meta FROM storage.objects o WHERE o.bucket_id = r.bucket_id AND o.name = r.file_path;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_STORED';
    END IF;
    v_size := NULLIF(v_meta ->> 'size', '')::bigint;
    IF v_meta ->> 'mimetype' IS DISTINCT FROM 'application/pdf' OR v_size IS NULL OR v_size <= 0
       OR (r.file_size IS NOT NULL AND v_size <> r.file_size) THEN
        RAISE EXCEPTION 'CONTRACT_FILE_MISMATCH';
    END IF;
    IF r.kind = 'original' THEN
        IF v_c.status NOT IN ('draft', 'active') OR v_c.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'CONTRACT_FILE_CONTRACT_CLOSED|%|%', v_c.code, v_c.status;
        END IF;
        IF EXISTS (SELECT 1 FROM contract_files o JOIN contract_files s ON s.source_file_id = o.id AND s.kind = 'signed' AND s.status = 'current'
                    WHERE o.contract_id = v_c.id AND o.kind = 'original' AND o.status = 'current') THEN
            RAISE EXCEPTION 'CONTRACT_FILE_SIGNED_LOCKED|%', v_c.code;
        END IF;
        UPDATE contract_files SET status = 'superseded', superseded_at = now()
         WHERE contract_id = v_c.id AND kind = 'original' AND status = 'current';
    ELSIF r.kind = 'signed' THEN
        SELECT * INTO v_src FROM contract_files WHERE id = r.source_file_id FOR UPDATE;
        IF v_src.status <> 'current' THEN
            RAISE EXCEPTION 'CONTRACT_SIGN_NOT_CURRENT_ORIGINAL|%', v_c.code;
        END IF;
        IF v_c.status <> 'active' OR v_c.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'CONTRACT_SIGN_NOT_ACTIVE|%|%', v_c.code, v_c.status;
        END IF;
        IF EXISTS (SELECT 1 FROM contract_files f WHERE f.source_file_id = v_src.id AND f.kind = 'signed' AND f.status = 'current') THEN
            RAISE EXCEPTION 'CONTRACT_FILE_ALREADY_SIGNED|%', v_c.code;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM contract_signatories s WHERE s.id = r.signatory_id AND s.removed_at IS NULL
                          AND s.employee_id = current_user_employee()) THEN
            RAISE EXCEPTION 'CONTRACT_SIGN_NOT_SIGNATORY';
        END IF;
    ELSE
        SELECT * INTO v_src FROM contract_files WHERE id = r.source_file_id FOR UPDATE;
        IF v_src.status <> 'current' THEN
            RAISE EXCEPTION 'CONTRACT_COUNTERSIGN_NEEDS_SIGNED|%', v_c.code;
        END IF;
        IF EXISTS (SELECT 1 FROM contract_files f WHERE f.source_file_id = v_src.id AND f.kind = 'countersigned' AND f.status = 'current') THEN
            RAISE EXCEPTION 'CONTRACT_FILE_COUNTERSIGNED_FINAL|%', v_c.code;
        END IF;
    END IF;
    UPDATE contract_files SET status = 'current', sha256 = p_sha256, file_size = COALESCE(file_size, v_size), stored_at = now()
     WHERE id = r.id;
    IF r.kind = 'countersigned' THEN
        UPDATE contracts SET signed_on = (now() AT TIME ZONE 'Asia/Singapore')::date WHERE id = v_c.id AND signed_on IS NULL;
    END IF;
    RETURN jsonb_build_object('id', r.id, 'kind', r.kind, 'state', 'current', 'sha256', p_sha256, 'size', v_size);
END;
$function$;
-- db/functions/contract_file_abandon.sql
-- CONTRACT-ESIGN(Tim 2026-10-30):【一个合同文件没传成 / 没签成】—— 自己登记的、还在 uploading 的那一行变成 abandoned。
--   传字节失败、服务端按文件头认出不是 PDF、PDF 带密码打不开、或盖章那一步失败时,由服务端动作调它。桶里若已留下字节,它们留着
--   (没有删除策略 —— 与报销收据、门户同一条)。按名拒:不是自己登记的、或此刻读不到那份合同的文件 → CONTRACT_FILE_NOT_FOUND;不在 uploading → CONTRACT_FILE_NOT_UPLOADING|<状态>。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_file_abandon(p_file_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_status   text;
    v_contract uuid;
BEGIN
    SELECT x.status, x.contract_id INTO v_status, v_contract FROM contract_files x WHERE x.id = p_file_id AND x.created_by = auth.uid() FOR UPDATE;
    IF NOT FOUND OR NOT contract_file_readable(v_contract) THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_FOUND';
    END IF;
    IF v_status <> 'uploading' THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_UPLOADING|%', v_status;
    END IF;
    UPDATE contract_files SET status = 'abandoned' WHERE id = p_file_id;
    RETURN jsonb_build_object('id', p_file_id, 'state', 'abandoned');
END;
$function$;
-- db/functions/contract_sign_begin.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q1 · Q3 · Q4 · Q5 · Q6 · Q9):【开始签一份合同文件】—— 判完才登记一行 kind = signed、status = uploading,
--   给出签过版本的路径、源文件的路径与哈希、签署人自己的签字样本与(选了的话)公司印章的路径、印出来的名字与职衔。
--   服务端动作随后把样本与印章盖到源文件上、另存成新的一份 PDF、按这条路径传、调 contract_file_finish(那一步才算签了)。
--   调这一支的会话【必须是刚刚凭密码登录的那一个】:服务端用签署人重新输入的密码另开一个会话,不换掉浏览器里那一个(Q5)。
--   依次按名拒:
--     文件不存在                                              → CONTRACT_FILE_NOT_FOUND
--     不是一份在用的 original(被替换了 / 是签过的版本)       → CONTRACT_SIGN_NOT_CURRENT_ORIGINAL|<合同号>
--     调用者此刻不在签署人名单上(Q3)                        → CONTRACT_SIGN_NOT_SIGNATORY
--     读不到这份合同的文件(Q3:要读得到那份合同 + Q8)        → CONTRACT_FILE_RESTRICTED|<合同号>
--     这个令牌不是 5 分钟之内凭密码登录的(Q5)               → CONTRACT_SIGN_PASSWORD_REQUIRED
--     合同不在 active(Q1:只签条款已经过 CFO 的合同)         → CONTRACT_SIGN_NOT_ACTIVE|<合同号>|<状态>
--     这一份已经有一份在用的签过版本(Q9)                    → CONTRACT_FILE_ALREADY_SIGNED|<合同号>
--     本人还没有签字样本(Q4:先在 /me 画一次)               → CONTRACT_SIGN_NO_SPECIMEN
--     选了印章而还没有在用的印章                              → CONTRACT_SIGN_NO_STAMP
--     页码 < 1、位置不在 0..1 之间、或印章的位置给了一半      → CONTRACT_SIGN_PLACEMENT_INVALID
--   页码不超过源文件的页数,由服务端在打开 PDF 之后判(库读不到 PDF)。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_sign_begin(p_file_id uuid, p_with_stamp boolean, p_signature_page integer, p_signature_x numeric, p_signature_y numeric, p_stamp_page integer DEFAULT NULL::integer, p_stamp_x numeric DEFAULT NULL::numeric, p_stamp_y numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_f     contract_files%ROWTYPE;
    v_c     contracts%ROWTYPE;
    v_sig   contract_signatories%ROWTYPE;
    v_emp   employees%ROWTYPE;
    v_pw    timestamptz;
    v_spec  signature_specimens%ROWTYPE;
    v_stamp company_stamps%ROWTYPE;
    v_id    uuid := gen_random_uuid();
    v_path  text;
BEGIN
    SELECT * INTO v_f FROM contract_files WHERE id = p_file_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_FOUND';
    END IF;
    SELECT * INTO v_c FROM contracts WHERE id = v_f.contract_id;
    IF v_f.kind <> 'original' OR v_f.status <> 'current' THEN
        RAISE EXCEPTION 'CONTRACT_SIGN_NOT_CURRENT_ORIGINAL|%', v_c.code;
    END IF;
    SELECT * INTO v_sig FROM contract_signatories s WHERE s.employee_id = current_user_employee() AND s.removed_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_SIGN_NOT_SIGNATORY';
    END IF;
    IF NOT contract_file_readable(v_c.id) THEN
        RAISE EXCEPTION 'CONTRACT_FILE_RESTRICTED|%', v_c.code;
    END IF;
    v_pw := signing_password_verified_at();
    IF v_pw IS NULL OR v_pw < now() - interval '5 minutes' THEN
        RAISE EXCEPTION 'CONTRACT_SIGN_PASSWORD_REQUIRED';
    END IF;
    IF v_c.status <> 'active' OR v_c.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'CONTRACT_SIGN_NOT_ACTIVE|%|%', v_c.code, v_c.status;
    END IF;
    IF EXISTS (SELECT 1 FROM contract_files f WHERE f.source_file_id = v_f.id AND f.kind = 'signed' AND f.status = 'current') THEN
        RAISE EXCEPTION 'CONTRACT_FILE_ALREADY_SIGNED|%', v_c.code;
    END IF;
    SELECT * INTO v_spec FROM signature_specimens s WHERE s.employee_id = v_sig.employee_id AND s.superseded_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_SIGN_NO_SPECIMEN';
    END IF;
    IF COALESCE(p_with_stamp, false) THEN
        SELECT * INTO v_stamp FROM company_stamps s WHERE s.superseded_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'CONTRACT_SIGN_NO_STAMP';
        END IF;
    END IF;
    IF p_signature_page IS NULL OR p_signature_page < 1 OR p_signature_x IS NULL OR p_signature_y IS NULL
       OR p_signature_x < 0 OR p_signature_x > 1 OR p_signature_y < 0 OR p_signature_y > 1
       OR (COALESCE(p_with_stamp, false) AND (p_stamp_page IS NULL OR p_stamp_page < 1 OR p_stamp_x IS NULL OR p_stamp_y IS NULL
                                              OR p_stamp_x < 0 OR p_stamp_x > 1 OR p_stamp_y < 0 OR p_stamp_y > 1)) THEN
        RAISE EXCEPTION 'CONTRACT_SIGN_PLACEMENT_INVALID';
    END IF;
    SELECT * INTO v_emp FROM employees WHERE id = v_sig.employee_id;
    v_path := v_c.id::text || '/' || v_id::text || '.pdf';
    INSERT INTO contract_files (id, contract_id, kind, source_file_id, file_name, file_path, created_by,
                                signatory_id, signer_employee_id, signer_name, signer_title, specimen_id, stamp_id,
                                signature_page, signature_x, signature_y, stamp_page, stamp_x, stamp_y, password_verified_at)
    VALUES (v_id, v_c.id, 'signed', v_f.id, left('signed-' || v_f.file_name, 200), v_path, auth.uid(),
            v_sig.id, v_emp.id, v_emp.legal_name, v_sig.title, v_spec.id,
            CASE WHEN COALESCE(p_with_stamp, false) THEN v_stamp.id END,
            p_signature_page, p_signature_x, p_signature_y,
            CASE WHEN COALESCE(p_with_stamp, false) THEN p_stamp_page END,
            CASE WHEN COALESCE(p_with_stamp, false) THEN p_stamp_x END,
            CASE WHEN COALESCE(p_with_stamp, false) THEN p_stamp_y END,
            v_pw);
    RETURN jsonb_build_object('id', v_id, 'bucket', 'contract-files', 'path', v_path, 'contract_code', v_c.code,
                              'source_path', v_f.file_path, 'source_sha256', v_f.sha256,
                              'specimen_path', v_spec.file_path, 'specimen_sha256', v_spec.sha256,
                              'stamp_path', CASE WHEN COALESCE(p_with_stamp, false) THEN v_stamp.file_path END,
                              'stamp_sha256', CASE WHEN COALESCE(p_with_stamp, false) THEN v_stamp.sha256 END,
                              'signer_name', v_emp.legal_name, 'signer_title', v_sig.title,
                              'password_verified_at', v_pw);
END;
$function$;
-- db/functions/contract_file_void.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q7):【作废一份签过的版本(或一份对方签回件)】—— 签署人名单上的人或 admin(持 action.manage_signatories),
--   要一句理由;在对方签回之前或之后都可以。作废的 PDF 留在桶里、照样列出来,标「作废」;之后那份合同文件可以替换,或者重新签。
--   作废一份我方签过的版本时,建在它上面、还在用的对方签回件一起作废(同一句理由)—— 签回件签的是那一份。
--   按名拒:文件不存在 → CONTRACT_FILE_NOT_FOUND;不是一份在用的 signed / countersigned → CONTRACT_FILE_NOT_VOIDABLE|<合同号>|<种类>|<状态>;
--     既不在名单上也不持 action.manage_signatories → CONTRACT_VOID_NOT_PERMITTED;读不到这份合同的文件 → CONTRACT_FILE_RESTRICTED|<合同号>;
--     理由空 → CONTRACT_VOID_REASON_REQUIRED|<合同号>。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_file_void(p_file_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_f  contract_files%ROWTYPE;
    v_c  contracts%ROWTYPE;
    v_n  int := 0;
BEGIN
    SELECT * INTO v_f FROM contract_files WHERE id = p_file_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_FOUND';
    END IF;
    SELECT * INTO v_c FROM contracts WHERE id = v_f.contract_id;
    IF v_f.kind NOT IN ('signed', 'countersigned') OR v_f.status <> 'current' THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_VOIDABLE|%|%|%', v_c.code, v_f.kind, v_f.status;
    END IF;
    IF NOT (contract_signatory_active() OR has_permission('action.manage_signatories')) THEN
        RAISE EXCEPTION 'CONTRACT_VOID_NOT_PERMITTED';
    END IF;
    IF NOT contract_file_readable(v_c.id) THEN
        RAISE EXCEPTION 'CONTRACT_FILE_RESTRICTED|%', v_c.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'CONTRACT_VOID_REASON_REQUIRED|%', v_c.code;
    END IF;
    IF v_f.kind = 'signed' THEN
        UPDATE contract_files SET status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason)
         WHERE source_file_id = v_f.id AND kind = 'countersigned' AND status = 'current';
        GET DIAGNOSTICS v_n = ROW_COUNT;
    END IF;
    UPDATE contract_files SET status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason)
     WHERE id = v_f.id;
    RETURN jsonb_build_object('id', v_f.id, 'state', 'void', 'countersigned_voided', v_n);
END;
$function$;
-- db/functions/contract_file_can_upload.sql
-- CONTRACT-ESIGN(Tim 2026-10-30):【存储策略的判据】—— 这个会话能不能往 contract-files 的这一条路径传字节。
--   成立 = 有一行 status = uploading 的合同文件,路径正是这一条、是【这个会话自己】在十分钟内登记的(contract_file_begin 或
--   contract_sign_begin 判过调用者之后才写那一行)。于是:没先过 begin 的字节存不进来;别人的路径、已经存下的、过了十分钟的,一律存不进来。
--   传的人此刻仍要读得到那份合同的文件(contract_file_readable,Q8)。改与删没有策略(一份存下的文件不能被覆盖)。【绝不抛】,不成立就回 false。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_file_can_upload(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(p_bucket = 'contract-files'
       AND EXISTS (SELECT 1 FROM contract_files f
                    WHERE f.file_path = p_name AND f.status = 'uploading' AND f.created_by = auth.uid()
                      AND f.created_at > now() - interval '10 minutes' AND contract_file_readable(f.contract_id)), false)
$function$;
-- db/functions/contract_file_can_read.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q8):【存储策略的判据】—— 这个会话能不能读 contract-files 里的这一个对象。
--   成立 = 它是一行合同文件的路径,这个会话读得到那份合同的文件(那一侧的读码 + 价格码,contract_file_readable),而且那一行已经存下
--   (current / superseded / void —— 作废的照样读得到,Q7),或者是这个会话自己刚登记、还在传的那一条(Storage API 的读回)。【绝不抛】。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_file_can_read(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(p_bucket = 'contract-files'
       AND EXISTS (SELECT 1 FROM contract_files f
                    WHERE f.file_path = p_name
                      AND (f.status IN ('current', 'superseded', 'void') OR (f.status = 'uploading' AND f.created_by = auth.uid()))
                      AND contract_file_readable(f.contract_id)), false)
$function$;

-- ── 9 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 同一串字)──
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.company_stamps
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.company_stamps
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.contract_files
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.contract_files
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.contract_signatories
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.contract_signatories
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.signature_specimens
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.signature_specimens
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 10 · 存储(与 db/storage/buckets-and-policies.sql 逐字同一份):两个桶 · 四条策略 ──
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('contract-files', 'contract-files', false, 26214400, ARRAY['application/pdf'])
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('signing-assets', 'signing-assets', false, 1048576, ARRAY['image/png'])
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ── 合同的电子文件与签字用的图(CONTRACT-ESIGN,2026-10-30,Tim Q3 · Q4 · Q8 · Q12)—— 第 59–62 条策略 ─────────────────────────────────────
-- contract-files(25 MB · 只收 PDF):传 = 只有【这个会话自己】一行 uploading 的合同文件登记过的那一条路径(contract_file_can_upload;
--   那一行只由 contract_file_begin / contract_sign_begin 在判过调用者之后写);读 = 那份合同那一侧的读码 + 价格码(Q8),
--   已经存下的(作废的照样读得到),或自己刚登记、还在传的那一条(contract_file_can_read)。
-- signing-assets(1 MB · 只收 PNG):specimens/<员工 id>/ 只有本人传、本人读(Q4:admin 替别人设不了签名);
--   stamps/ 由持 action.manage_signatories 的人传,签署人与持码的人读(Q3)。
-- 【两个桶都没有 UPDATE、没有 DELETE】一份存下的文件不能被覆盖、也删不掉;没传成的字节留着(与报销收据同一条)。
DROP POLICY IF EXISTS "contract files upload own registered path" ON storage.objects;
CREATE POLICY "contract files upload own registered path"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (((bucket_id = 'contract-files'::text) AND public.contract_file_can_upload(bucket_id, name)));

DROP POLICY IF EXISTS "contract files read by contract side and price code" ON storage.objects;
CREATE POLICY "contract files read by contract side and price code"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (((bucket_id = 'contract-files'::text) AND public.contract_file_can_read(bucket_id, name)));

DROP POLICY IF EXISTS "signing assets upload own specimen or stamp" ON storage.objects;
CREATE POLICY "signing assets upload own specimen or stamp"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (((bucket_id = 'signing-assets'::text) AND public.signing_asset_can_upload(bucket_id, name)));

DROP POLICY IF EXISTS "signing assets read own specimen or stamp" ON storage.objects;
CREATE POLICY "signing assets read own specimen or stamp"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (((bucket_id = 'signing-assets'::text) AND public.signing_asset_can_read(bucket_id, name)));

-- ── 11 · 自证 ──
DO $proof$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'CES_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT user_id, role_id, revoked_at FROM user_roles EXCEPT SELECT * FROM ces_user_roles_before)
               UNION ALL (SELECT * FROM ces_user_roles_before EXCEPT SELECT user_id, role_id, revoked_at FROM user_roles)) THEN
        RAISE EXCEPTION 'CES_PROOF|a role grant to an account changed';
    END IF;
    IF EXISTS ((SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id EXCEPT SELECT * FROM ces_grants_before)
               EXCEPT SELECT 'admin', 'action.manage_signatories')
       OR EXISTS (SELECT * FROM ces_grants_before EXCEPT SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)
       OR NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin' AND rp.permission_code = 'action.manage_signatories') THEN
        RAISE EXCEPTION 'CES_PROOF|role codes: expected exactly one new grant (admin · action.manage_signatories)';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 62
       OR EXISTS (SELECT policyname, cmd, roles, qual, with_check FROM ces_policies_before
                  EXCEPT SELECT policyname, cmd, roles::text, COALESCE(qual, ''), COALESCE(with_check, '') FROM pg_policies WHERE schemaname = 'storage')
       OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND cmd IN ('UPDATE', 'DELETE', 'ALL')
                   AND COALESCE(qual, '') || COALESCE(with_check, '') ~ '(contract-files|signing-assets)') THEN
        RAISE EXCEPTION 'CES_PROOF|storage policies: expected the 58 unchanged plus four, and no update / delete on the two new buckets';
    END IF;
    IF (SELECT count(*) FROM storage.buckets) <> 23
       OR EXISTS (SELECT id, name, public, file_size_limit, mimes FROM ces_buckets_before
                  EXCEPT SELECT id, name, public, file_size_limit, allowed_mime_types::text FROM storage.buckets)
       OR NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'contract-files' AND NOT public AND file_size_limit = 26214400 AND allowed_mime_types = ARRAY['application/pdf'])
       OR NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'signing-assets' AND NOT public AND file_size_limit = 1048576 AND allowed_mime_types = ARRAY['image/png']) THEN
        RAISE EXCEPTION 'CES_PROOF|buckets: expected the 21 unchanged plus contract-files (25 MB · PDF) and signing-assets (1 MB · PNG), both private';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(ARRAY['contract_signatories', 'signature_specimens', 'company_stamps', 'contract_files']) t
                WHERE NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass)
                   OR has_table_privilege('anon', 'public.' || t, 'SELECT')
                   OR has_table_privilege('authenticated', 'public.' || t, 'INSERT')
                   OR has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
                   OR has_table_privilege('authenticated', 'public.' || t, 'DELETE')
                   OR NOT has_table_privilege('authenticated', 'public.' || t, 'SELECT')) THEN
        RAISE EXCEPTION 'CES_PROOF|a new table is not read-only-under-RLS for authenticated and closed to anon';
    END IF;
    IF jsonb_array_length(change_log_coverage_gaps() -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'CES_PROOF|change-log coverage: %', change_log_coverage_gaps();
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'CES_PROOF|require_calibrated_since was set or a COD changed';
    END IF;
END;
$proof$;

NOTIFY pgrst, 'reload schema';

-- ── function-grant replay (apply_migration.sh does this inside the same transaction) ──
-- db/views/zzz_function_grants.sql
-- 【函数的 EXECUTE 权限 —— 镜像此前完全没有记它们】
--
-- ════════════════════════════════════════════════════════════════════════════
-- pg_get_functiondef 不吐 GRANT/REVOKE,而表镜像是【手写】把 GRANT 补进去的
-- (22 个表镜像里都有),函数镜像没有。后果是实测出来的:
--     live    calculate_metal_price_internal  anon=false authenticated=false
--     rebuilt calculate_metal_price_internal  anon=true  authenticated=true
--     live    reverse_journal_entry_internal  anon=false authenticated=false
--     rebuilt reverse_journal_entry_internal  anon=true  authenticated=true
-- 也就是说【这个系统里每一次 REVOKE 都活不过一次重建】。照镜像切到生产,
-- 冲销分录的引擎会向匿名用户敞开 —— 而匿名 key 是随应用公开发出去的。
--
-- 【为什么这个文件住在 db/views/ 而不是 db/functions/】重放顺序是
-- functions → tables → views,而【表镜像里也定义函数】(守卫触发器、取号函数,共 36 个)。
-- 放在 db/functions 里跑,那 36 个还没建出来,REVOKE ON ALL FUNCTIONS 收不到它们 ——
-- 实测:重建之后 anon 仍能调 36 个。放在 views 阶段、文件名 zzz 排最后,才真的收得干净。
-- 它不定义任何视图,只声明权限。
--
-- 【anon 在 public 架构里不该有任何 EXECUTE】anon 就是互联网。
-- 未登录的界面(登录页、设置密码页)走的是 Supabase auth 端点,不调 public 的函数,
-- 所以这是一句可以下得很死的断言,而不是需要逐个斟酌的清单。
-- 真有哪个函数将来必须给 anon,就在下面显式加一行【并写明理由】。
-- ════════════════════════════════════════════════════════════════════════════

-- 先全部收回(含 PUBLIC —— 默认授权给的是 PUBLIC,authenticated 是从它继承的;
-- 只收 authenticated/anon 是没有用的,OPS-3 实测过)。
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon;

-- 再把登录用户与服务角色需要的授回。
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, service_role;

-- 【内层函数:连 authenticated 也不给】它们没有调用者检查,靠的就是调不到。
-- 有调用者检查的函数不在此列 —— 那是另一半保证(见 check 的 C1 不变式)。
REVOKE EXECUTE ON FUNCTION public.calculate_metal_price_internal(uuid, jsonb, numeric, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_journal_entry_internal(uuid, date, text) FROM authenticated;
-- FIN-27:条款解析与承诺写入的内层算子。同上 —— 没有调用者检查,靠的就是调不到;
-- 它们只从 calculate_metal_price_internal / apply_assay_result /
-- reprice_from_committed_terms / create_purchase_order 的函数体内被调用(属主身份)。
-- SOD-1(2026-08-24):职责分离的三支内层函数。**gate 的 B2 抓到它们**,
-- 而其中两支是真的越权读:sod_manual_posters_in / sod_supplier_creator 是
-- SECURITY DEFINER 且没有调用者检查,留着 authenticated 的 EXECUTE,任何登录用户
-- 都能绕过 RLS 读出"谁记过手工凭证"与"谁建了这家供应商"。
-- 三支都只从 guard_payment_sod / guard_finance_settings_sod 的函数体内被调用,
-- 而那两个是属主身份跑的触发器 —— 所以收回之后照常工作,靠的就是调不到。
-- (approvals_readiness 不在此列:它【要】被页面调用,所以走的是另一半保证 ——
--  fu2 给它加了 require_permission(...)。★ APR-1(N6)把那个码从 module.finance.view
--  换成了 action.manage_permissions —— 与 /settings/approvals 那一页的闸同一个码,
--  于是屏幕与它调的函数不再是两个码守同一块屏幕。)
REVOKE EXECUTE ON FUNCTION public.assert_segregated(text, uuid[], text) FROM authenticated;

-- GST-1(2026-08-24):两支查表函数。**gate 的 definer 判词点了它们的名**。
-- 它们都是 SECURITY DEFINER 且没有调用者检查:tax_rate_for 绕过 tax_rates 的 RLS,
-- gst_registered 绕过 finance_settings 的 RLS。
-- 实测 app / lib 里没有任何一处调它们 —— 界面调的是 f5_return / f5_box_detail
-- (两者都带 require_permission),以及 finance_settings.gst_registered 这一【列】
-- (走该表自己的 RLS)。库内只有 f5_return 与 post_journal_entry 调它们,
-- 两个都是 SECURITY DEFINER,以属主身份执行,收回之后照常工作。
-- 【为什么不给它们加 require_permission】它们被属主(postgres)在 definer 内部调用,
-- 而 postgres 没有 claims —— 加了门反而会在过账与出表的路上抛权限错。
-- 与上面三支同形:够不着的东西不需要门,需要的是【真的够不着】。
REVOKE EXECUTE ON FUNCTION public.gst_registered() FROM authenticated;

-- EQP-PAY-1(2026-09-01):一张采购单是设备单还是材料单。**gate 的 B2 点了它的名。**
-- 它是 SECURITY DEFINER 且没有调用者检查 —— 而那是【故意的】:它是给守卫触发器
-- 认主语用的。若它受 RLS 约束,一个看不见行的调用者会拿到 NULL,而守卫会因此
-- 【静默放行】—— 正是本仓库记过的"守卫对主语缺席这一格是瞎的"那条病。
--
-- 【为什么不给它加 require_permission,而是收回 EXECUTE】它唯一的库内调用者
-- guard_payment_term_applicable 是【属主身份跑的触发器】,而属主(postgres)没有
-- claims —— 加一道门反而会在每一次写付款计划的路上抛权限错。与上面
-- gst_registered / tax_rate_for 同形:**够不着的东西不需要门,需要的是【真的够不着】。**
-- app / lib 里没有任何一处调它(实测);报表里要用它,以 postgres 身份跑。
REVOKE EXECUTE ON FUNCTION public.purchase_order_kind(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.tax_rate_for(text, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.sod_manual_posters_in(date, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.sod_supplier_creator(uuid) FROM authenticated;

-- COD-1(2026-09-07):销毁证书的三支内层函数。**gate 的 B2 点了它们的名,
-- 而其中一支是真的越权动作** —— void_cod_internal 是 SECURITY DEFINER 且【没有
-- 调用者检查】,留着 authenticated 的 EXECUTE,任何登录用户都能作废任何一张
-- 已签发的销毁证书,完全绕开 action.issue_cod。带门的那一支叫 void_cod;
-- 这一支存在,是因为【冲销加工单的人不持有签发权限】,而冲销必须能作废证书。
--
-- 三支各自的唯一调用者,全部是属主身份跑的 SECURITY DEFINER:
--   * void_cod_internal      ← void_cod、refresh_cod_for_batch
--   * refresh_cod_for_batch  ← commit_processing_run / rollback_processing_run /
--                              soft_delete_inbound_batch(三处挂钩)
--   * cod_delivery_completion ← refresh_cod_for_batch、cod_certificate_data
-- 所以收回之后照常工作,靠的就是【真的够不着】。
--
-- 【为什么不给它们加 require_permission,而是收回 EXECUTE】与上面 gst_registered /
-- purchase_order_kind 同形,但这里的理由更硬一格:refresh_cod_for_batch 是在
-- 【投料的那个人】的会话里被调用的,而运营角色不持有 action.issue_cod ——
-- 加一道门会让"提交加工单"这个动作本身抛权限错。
--
-- ★【界面因此走带门的那一支】★ 面板要显示"为什么还不能签发",而那句话
-- 由 cod_certificate_data 的 CANNOT_CERTIFY|批号|理由 抛出 —— 它有
-- action.issue_cod 的门。判据仍然只有一份实现,而外面只有一扇门。
REVOKE EXECUTE ON FUNCTION public.void_cod_internal(uuid, text, uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.refresh_cod_for_batch(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.cod_delivery_completion(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.pricing_terms_of_formula(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.pricing_terms_of_commitment(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.calculate_metal_price_from_terms(jsonb, jsonb, numeric, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.commit_pricing_terms(uuid, uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.resolve_pricing_commitment(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.committed_terms_price(uuid, date) FROM authenticated;
-- TASK-1c-a-fu1:【一个事实,一个写入者】那个函数 —— 归属人置为活跃参与者。
-- 它没有调用者检查,只从两扇门的触发器体内被调用(属主身份),所以靠的就是调不到。
-- 门被 gate 的 B2 抓到过一次:留着 authenticated 的 EXECUTE,任何登录用户都能
-- 把【自己】插成【任何一张任务】的活跃参与者 —— 而活跃参与者正是 can_edit_task
-- 团队分支的全部判据。也就是说它等于一把万能写权限。
REVOKE EXECUTE ON FUNCTION public.ensure_task_owner_participant(uuid, uuid, uuid) FROM authenticated;
-- APR-1:审批留痕的唯一写入口。没有调用者检查 —— 它只从 decide_leave_request /
-- decide_medical_claim / submit_review / approve_review / acknowledge_review 的函数体内
-- 以属主身份被调用,而那五个各自已经把过关了。给了 authenticated 就等于任何登录用户
-- 都能伪造一行留痕,而留痕正是"不可伪造"才有意义的东西。
REVOKE EXECUTE ON FUNCTION public.record_approval_decision(text, uuid, text, smallint, text) FROM authenticated;
-- APR-2:审批引擎的两个内层算子。approval_level_for 读的是 finance_settings 上的阈值,
-- require_approver_for 是"你能不能批这一级"的判词本身 —— 两个都没有调用者检查,
-- 靠的就是调不到。公开入口是 approve_purchase_order / reject_purchase_order,
-- 它们各自 require_permission。给了 authenticated 就等于把阈值和授权判断敞开。
REVOKE EXECUTE ON FUNCTION public.approval_level_for(numeric) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.require_approver_for(smallint) FROM authenticated;
-- ★ APR-3:分档那个比较号搬出来单独成一支(approval_level_at)。它【不是】DEFINER
-- (它一个东西都不读:两个入参,一次比较),所以 gate 的 B2 与它无关;收权是为了
-- 与它的公开入口 approval_level_for 一致 —— 两支答的是同一个问题,不该一支敞着。
REVOKE EXECUTE ON FUNCTION public.approval_level_at(numeric, numeric) FROM authenticated;
-- ★ APR-3:一张报销单值多少本位币。【不是】DEFINER —— 它读 expense_claims 与
-- fx_rates,而那两张表的 RLS 正是这个问题该有的答案。收权的理由不是安全(RLS
-- 已经管住了),是【它是一支内层算子】:它的三个调用方都以属主身份跑,而一个
-- 敞着的内层算子迟早会长出第四个调用方,那时谁也说不清它该答什么。
REVOKE EXECUTE ON FUNCTION public.expense_claim_amount_base(uuid) FROM authenticated;
-- ★★ APR-3:哪些单据正在等人批。SECURITY DEFINER 且【没有】调用者检查,
-- 与 real_role_holders / approval_gate_intersections 逐字同源同理由:它的三个
-- 调用方里两个是【属主身份跑的触发器】(guard_approvals_switch 的关闭那一支与
-- APPROVALS_POLICY_WOULD_STRAND),属主没有 claims,加一道门会在每一次写策略的
-- 路上抛权限错;第三个 approvals_readiness 自己开头就查 action.manage_permissions。
-- 给了 authenticated 就等于把采购与财务两个模块的在途单据编号一起敞开。
REVOKE EXECUTE ON FUNCTION public.approval_pending_documents() FROM authenticated;
-- SAL-B:客户敞口算子。无调用者检查,靠调不到 —— 消费方是 record_output_sale
-- (definer)与 operations_now(属主视图),两者都以属主身份执行。给了
-- authenticated 就等于把任意客户的应收敞口敞开给没有财务权限的人。
REVOKE EXECUTE ON FUNCTION public.customer_ar_exposure_base(uuid) FROM authenticated;
-- IOD-1:库存排空与冲销镜像的内层算子。无调用者检查,靠的就是调不到 ——
-- drain_stock 的调用方是 record_output_sale(output.edit)、commit_processing_run
-- (processing.edit)与注销触发器(批次侧的 edit),【三者各自已经把过关】,
-- 而它们分属不同模块:给 drain_stock 挑一个权限码只能挑一个比三者都松的,
-- 那不是把关、那是把关的样子。mirror_consume_restore 只从 rollback_processing_run
-- 体内被调用。给了 authenticated 就等于任何登录用户都能凭空写出入库/出库流水。
REVOKE EXECUTE ON FUNCTION public.drain_stock(numeric, text, date, uuid, uuid, text[], uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.mirror_consume_restore(uuid, uuid, uuid, numeric, date, uuid) FROM authenticated;
-- IOD-1b:收货库位的翻译器。三个建批次 RPC 共用它,而那三个分属两个模块
-- (进料 inbound.edit / 产出 output.edit)且各自已把过关 —— 给它挑一个权限码
-- 只能挑一个比两者都松的。靠"调不到"。
REVOKE EXECUTE ON FUNCTION public.resolve_receipt_location(uuid) FROM authenticated;
-- IOD-2:库位/物料分类的判词。同 resolve_receipt_location —— 四个落地点共用它,
-- 而那四个分属三个模块(inbound.edit / output.edit / inventory.edit)且各自已把
-- 过关;给它挑一个权限码只能挑一个比三者都松的,那不是把关、是把关的样子。
-- 它没有调用者检查,靠的就是调不到(gate 的 B2 判词认这条出路)。
REVOKE EXECUTE ON FUNCTION public.check_location_class(uuid, uuid) FROM authenticated;
-- NTF-1:两个通知发射器。【它们能凭空写出一条通知】,而 notifications 之所以可信,
-- 靠的正是"只有属主身份的函数写得进"(与 approval_log 同一条:留痕不该有第二个
-- 写法)。给了 authenticated,任何登录用户都能伪造一条"某某库位违规"的事件 ——
-- 而通知是拿来被相信的东西。
-- 【调用它们的是谁】notify_landing_warnings 从四个建批次 RPC 的函数体内被调用
-- (那四个是 DEFINER,以属主身份执行);notify_class_violations 从两个触发器函数
-- 内被调用,而那两个触发器函数【也声明了 SECURITY DEFINER】—— 触发器函数默认以
-- 调用者身份跑,不声明就会在这里撞上"调不到"。
REVOKE EXECUTE ON FUNCTION public.notify_landing_warnings(text[], uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_class_violations(text, uuid[], uuid[]) FROM authenticated;
-- SO-3b:发货单号的取号器。无调用者检查,靠的就是调不到 —— 唯一调用方是
-- ship_order(DEFINER,module.sales.edit,以属主身份执行)。给了 authenticated
-- 就等于任何登录用户都能凭空烧掉一个无缝单号,而无缝的意思正是"号码之间没有洞"。
REVOKE EXECUTE ON FUNCTION public.next_shipment_code(date) FROM authenticated;
-- LOG-2a:集装箱取号器。同 next_shipment_code —— 无调用者检查,靠的就是调不到。
REVOKE EXECUTE ON FUNCTION public.next_container_code(date) FROM authenticated;
-- SO-3b fu5:"这一行已经许出去多少"(已发 + 活预留)。无调用者检查,靠的就是
-- 调不到 —— 消费方是 reserve_stock(DEFINER,module.sales.edit),以及下一刀
-- SO-1b 的改单下限。它读的是订单行的履约情况,而那是 module.sales.view 的东西;
-- 给了 authenticated 就等于任何登录用户都能一行一行问出别人订单的发货进度。
REVOKE EXECUTE ON FUNCTION public.line_spoken_for(uuid) FROM authenticated;
-- SO-1b:"这张单发完了没有"(已发 vs 已订)。同上 —— 没有调用者检查,靠的就是
-- 调不到;两个消费方 ship_order 与 amend_sales_order 都是 DEFINER、都要
-- module.sales.edit,以属主身份执行。给了 authenticated 就等于任何登录用户都能
-- 一张一张问出别人订单的履约进度,而那是 module.sales.view 的东西。
REVOKE EXECUTE ON FUNCTION public.sales_order_fulfilment_status(uuid) FROM authenticated;
-- CN-1:贷项凭证的取号器。同 next_shipment_code —— 无调用者检查,靠的就是调不到;
-- 唯一调用方是 create_credit_note(DEFINER,module.finance.edit,以属主身份执行)。
-- 给了 authenticated 就等于任何登录用户都能凭空烧掉一个无缝单号,而无缝的意思
-- 正是"号码之间没有洞"。
REVOKE EXECUTE ON FUNCTION public.next_credit_note_code(date) FROM authenticated;
-- SO-4a:报价的取号器。同上 —— 无调用者检查,靠的就是调不到。
-- 【而建报价【走直连】,没有 RPC 门可以代取】—— 两者放在一起,客户端就永远
-- 拿不到号。解法不是把它授出去,是让号【根本不由客户端取】:
-- generate_quote_code(BEFORE INSERT,属主身份)在同一条语句里补上,
-- 先例是 customers.generate_customer_code。客户端插的是一行没有号的报价。
REVOKE EXECUTE ON FUNCTION public.next_quote_code(date) FROM authenticated;
-- EQP-1c-a:固定资产的取号器。同 next_shipment_code / next_container_code /
-- next_quote_code —— 没有调用者检查,靠的就是调不到。它有【两个】调用方
-- (record_expense 的新建支与 create_fixed_asset),两个都是 DEFINER 且各自
-- require_permission('module.finance.edit'),以属主身份执行。给了 authenticated
-- 就等于任何登录用户都能凭空烧掉一个 FA 号,而"无缝"的意思正是号码之间没有洞。
REVOKE EXECUTE ON FUNCTION public.next_fixed_asset_code(date) FROM authenticated;

-- GST-2(2026-08-25):税码解析器。与上面 GST-1 那两支【逐字同一条理由】——
-- SECURITY DEFINER、没有调用者检查、绕过 tax_codes 的 RLS 读出整本税码字典。
-- 界面从不调它:屏幕上的税码下拉读的是 tax_codes 这张表本身(走它自己的 RLS,
-- 谓词是 has_permission('module.finance.view'))。库内只有 create_invoice /
-- create_order_invoice / record_expense 调它,三支都是 SECURITY DEFINER、
-- 以属主身份执行,收回之后照常工作。
-- 【为什么不给它加 require_permission】它被属主(postgres)在 definer 内部调用,
-- 而 postgres 没有 claims —— 加了门反而会在开票与记费用的路上抛权限错。
REVOKE EXECUTE ON FUNCTION public.resolve_tax_code(text, text, text, text) FROM authenticated;

-- CHAIN-BUILD-1(2026-08-30):审批链的两支内层判据。
-- 【为什么收回】两支都是 SECURITY DEFINER 且【没有调用者检查】,而 gate 的 B2
-- 正是查这个。它们【不需要】门,需要的是【真的够不着】——
-- real_role_holders 读 auth.users(账号是否确认/封禁/删除)与 user_roles,
-- 给了 authenticated 就等于任何登录用户都能把整个账号目录的登录状态问出来;
-- role_can_see_amounts 读 role_permissions,同理会把权限矩阵问出来。
-- 【唯一的调用方,逐个点名】三支都是 SECURITY DEFINER、以属主身份执行,
-- 而且三支各自已经把过关(readiness 有 require_permission;另两支是闸自己):
--   · real_role_holders   ← guard_approvals_switch / approvals_readiness / require_approver_for
--   · role_can_see_amounts ← guard_approvals_switch / approvals_readiness
-- 收回之后照常工作,靠的就是调不到 —— 与上面 SOD-1 那三支逐字同一条理由。
REVOKE EXECUTE ON FUNCTION public.real_role_holders(text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.role_can_see_amounts(text) FROM authenticated;

-- ★ APR-2(2026-09-22):approval_gate_intersections —— 与上面这两支【同源同理由】。
-- 它经 real_role_grants 读 auth.users 的登录状态,并把整张 role_permissions
-- 摊平成"谁真的持有哪个码"。给了 authenticated 就等于把账号目录 + 权限矩阵
-- 一次问出来 —— 比单独任何一支都宽。
-- 【唯一的两个调用方】approvals_readiness(自己有 require_permission)与
-- guard_approvals_switch(属主身份跑的触发器),两者都是 SECURITY DEFINER,
-- 收回之后照常工作,靠的就是调不到。
-- ⚠【为什么这一行必须在这里】C-1 的 real_role_grants 实测过:
--   apply_migration.sh 在 COMMIT 【之前】重放本文件,而本文件第一句是
--   REVOKE EXECUTE ON ALL FUNCTIONS ... FROM PUBLIC 后面跟着 GRANT ... TO authenticated
--   —— 只写在迁移里的那次 REVOKE 会被原样冲掉,而迁移报告成功。
REVOKE EXECUTE ON FUNCTION public.approval_gate_intersections(text, text) FROM authenticated;

-- ★ APR-2:approval_chain_gates 与 forbid_self_approval 【故意不收】。
--   两支都【不是】SECURITY DEFINER,也都不读任何受 RLS 约束的东西:
--   前者是一张常量名册,后者只比较 auth.uid() 与两个传进来的 uuid。
--   ☞ 照直写下来,免得下一个人以为它们是被漏掉的 —— 一份"该收而没收"的
--     清单与一份"想过、不收"的清单,在文件里长得一模一样。
--   ★ APR-ROUTE-1 之后【后半句不再逐字成立】:forbid_self_approval 现在经
--     self_leg 与 self_approval_exception 去问(两者都已收回)。它仍然【不收】——
--     它自己不是 DEFINER,一个 authenticated 直接调它会在那两支上撞 42501,
--     什么都探不到;而它唯一的调用方是 DEFINER 决定函数,以属主身份执行。

-- ★ C-1(2026-09-04):real_role_grants —— 与上面 real_role_holders 【同源同理由】。
-- 它就是那四条判据的行级形状(返回 grant_id + user_id),real_role_holders 如今
-- 是它的投影。所以它读的东西一字不差:auth.users 的确认/封禁/删除 + user_roles。
-- 给了 authenticated 就等于把整个账号目录的登录状态问出来 —— 收回。
-- 【唯一的调用方】guard_last_admin(user_roles 上的 BEFORE UPDATE/DELETE 触发器)。
-- ★ 它正是因此才被改成 SECURITY DEFINER 的:调用者权限的触发器以 authenticated
--   身份跑,收回之后就【调不到】,守卫会在每一次撤销授权时抛权限错。
--   DEFINER 让它以属主身份跑,于是"收回"与"守卫能用"同时成立。
--
-- ⚠【这一行是被实测逼出来的,不是照抄】C-1 起初只把 REVOKE 写在迁移里。
--   apply_migration.sh 在 COMMIT 之后会【重新断言一遍本文件】(那是它的兜底),
--   而本文件当时没有这一行 —— 于是那次 REVOKE 被原样冲掉,
--   实测 has_function_privilege('authenticated', 'real_role_grants', 'EXECUTE') = true,
--   一条【活的 B2 违规】。**收回必须写在这里,写在迁移里不算数。**
REVOKE EXECUTE ON FUNCTION public.real_role_grants(text) FROM authenticated;

-- PROC-COST-2(2026-08-31):【计值读取器】与【单位落地成本】三支内层函数。
-- 三支都是 SECURITY DEFINER 且【没有调用者检查】,而 gate 的 B2 正是查这个。
-- 它们【不该】有门,需要的是【真的够不着】—— 理由与上面那一族逐字同源,
-- 但这里的"为什么不加门"有它自己的一条,值得写清楚:
--
-- 【为什么这两支【必须】没有判据】batch_freight_base / batch_processing_cost_base
-- 是【屏幕读取器】,无权返回 NULL(受限)——「受限」与 0.00 不是同一件事。
-- 而注销与盘点要过账的那个金额【不许取决于谁按的按钮】:一个只有
-- module.inbound.edit 的仓管按下注销时,若计值读的是带判据的那一支,
-- COALESCE(NULL, 0) 会让它安静地退回按 unit_price 计值 —— 也就是 PROC-COST-2
-- 正在修的那个缺陷原样复发,而且再没有人看得见。所以算术与受众拆成两层:
-- 算术在 _all 这一对里(只有一份定义),受众在带判据的那一对里。
--
-- 【唯一的调用方,逐个点名】三支都只从属主身份执行的地方被调用:
--   · batch_freight_base_all          ← batch_freight_base(definer,带判据)
--                                       inbound_batch_landed_unit_cost(definer)
--                                       allocate_processing_costs(definer,ROLE-1 Batch 3a 起)
--   · batch_processing_cost_base_all  ← batch_processing_cost_base(definer,带判据)
--                                       inbound_batch_landed_unit_cost(definer)
--                                       allocate_processing_costs(definer,ROLE-1 Batch 3a 起)
--   · inbound_batch_landed_unit_cost_all ← emit_batch_writeoff_movement(触发器,definer)
--                                       post_stocktake(definer)
--                                       inventory_control_reconciliation(definer)
--                                       inventory_valuation_snapshot(definer)
--     【CLEANUP-A fu1】它是【过账】原语,刻意没有判据 —— 账上的金额不许取决于
--     按按钮的人有什么读权限。所以它必须靠"调不到"活着,与上面那一对同一条规矩。
--   · inbound_batch_landed_unit_cost  ← inbound_batch_valuation_rows(definer)
--     【它自己带判据(CLEANUP-A / R3)】,收权是第二层,不是唯一那层。
--     (此处原写着 post_stocktake(definer,module.stocktakes.edit)—— 不对:fu1 起 post_stocktake
--      读 _all。ROLE-1 Batch 3a 顺手更正,并拿掉了判据里 stocktakes.edit 那一支。)
-- 给了 authenticated 就等于把【绕过 RLS 的运费与加工成本读取】敞开给任何登录
-- 用户 —— 那正是带判据的那一对存在的全部理由,而这三支会把它一句话作废。
-- 收回之后照常工作,靠的就是调不到。
REVOKE EXECUTE ON FUNCTION public.batch_freight_base_all(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.batch_processing_cost_base_all(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.inbound_batch_landed_unit_cost(uuid) FROM authenticated;
-- CLEANUP-A fu1:过账原语,无判据,必须靠"调不到"活着。
REVOKE EXECUTE ON FUNCTION public.inbound_batch_landed_unit_cost_all(uuid) FROM authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ COD-2(2026-09-08):本仓库【第一条】给 anon 的 EXECUTE ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- 本文件抬头写着:「anon 在 public 架构里不该有任何 EXECUTE……真有哪个函数
-- 将来必须给 anon,就在下面显式加一行【并写明理由】。」这就是那一行,
-- 而下面是那个理由。
--
-- 【它是什么】cod_verification(text) —— 销毁证书核验页的取数。供应商扫证书上
-- 的二维码打开 /verify/cod/<令牌>,那一页就是这支函数的输出。**这是本系统
-- 第一个不用登录就打得开的页面**,而这支函数是它够得着的【唯一】一样东西。
--
-- 【为什么必须给 anon,不能靠"页面在服务端用 service_role 读"】
--   两种都成立,而选这一种的理由是【判据落在哪里】:给 anon 授权,把关的是
--   数据库 —— 这支函数收一个令牌、回一份白名单子集,任何调用者都只拿得到那些。
--   走 service_role 的话,把关的是"那一页恰好是服务端渲染的、而且它恰好只
--   显示了该显示的" —— 一次页面重写就可能悄悄改掉它,而没有任何东西会说话。
--   ★ 一条能在数据库这边说清的判据,不该寄存在一个页面的写法里。★
--
-- 【它没有调用者检查,而这是【正确的】】它的"权限"就是【持有那个令牌】:
--   122 位随机、与证书号毫无关系、改一位数字得到的是一个不存在的值。
--   一个匿名的核验入口若还要问 has_permission,它就永远回答不了任何人。
--   check_mirrors 的 DEFINER_NO_CHECK_ALLOWED 里有它,理由逐字同此。
--
-- 【它的限流住在函数体里,不在路由上】anon key 随浏览器包发出去,所以
--   POST /rest/v1/rpc/cod_verification 是第二条门,不经过 Vercel ——
--   一个住在路由上的限流器会被它要拦的那个工具整个绕过去。
--
-- ⚠★【这一行【必须】在这里,而不是只在迁移里】★⚠ 与 C-1 的 real_role_grants
--   那一段【方向相反、道理相同】:db/apply_migration.sh 把本文件拼在 COMMIT
--   之前、同一个事务里重跑一遍,而本文件的第一句是
--       REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon;
--   一条只写在迁移里的 GRANT 会在提交之前被它冲掉,**而迁移报告成功**。
--   所以真源在这里,写在那句 REVOKE 的【后面】。
GRANT EXECUTE ON FUNCTION public.cod_verification(text) TO anon;

-- COD-2:执照判据(在完成日当天在效的那一张 GWDF)。与 cod_delivery_completion
-- 逐字同一条理由 —— SECURITY DEFINER、没有调用者检查,靠的就是【调不到】。
-- 它绕过 company_compliance 的 RLS(那张表的谓词借的是 module.suppliers.view,
-- 而仓储现场读不到它,却仍然被这道闸管着 —— 那正是它必须 DEFINER 的原因)。
-- 给了 authenticated 就等于任何登录用户都能把公司的执照号、发证机关与有效期
-- 问出来。唯一的两个调用方 issue_cod 与 cod_certificate_data 都是 DEFINER、
-- 各自 require action.issue_cod,以属主身份执行,收回之后照常工作。
REVOKE EXECUTE ON FUNCTION public.cod_governing_licence(date) FROM authenticated;

-- ★ APR-ROUTE-1(2026-09-23):五支新的内层函数,全部【收回】。
--   五支都是 SECURITY DEFINER、没有调用者检查,靠的就是【调不到】:
--     account_person          —— 回答【任意一个账号】是哪一名员工(账号目录);
--     self_leg                —— 经它能逐个探测"某账号是不是某单据的提单人/主角";
--     self_approval_exception —— 经 real_role_holders 读审批人名单;
--     approval_level_eligible —— 同上;
--     approval_deciders       —— 读 auth.users 的登录状态与整张权限矩阵。
--   调用方(forbid_self_approval 在 DEFINER 决定函数里、record_approval_decision、
--   require_approver_for、approval_gate_intersections、approvals_readiness、
--   guard_approvals_switch)全部以属主身份执行,收回之后照常工作。
--   ⚠ 写在这里而不是只写在迁移里:理由见上面 approval_gate_intersections 那一段。
--   ☞ self_approved_decisions【不收】:它有自己的调用者检查
--     (require_permission('data.view_self_approvals')),而 /finance/self-approved 要调它。
REVOKE EXECUTE ON FUNCTION public.account_person(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.self_leg(uuid, uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.self_approval_exception(text, uuid, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.approval_level_eligible(smallint, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.approval_deciders(text, text, smallint, uuid, uuid, text, text) FROM authenticated;

-- PAY-REQ-1(2026-09-23):付款申请的内层引擎与算子。**这几支没有调用者检查,靠的就是调不到。**
--   record_payment_internal / reverse_payment_internal —— 原 record_payment / reverse_payment
--     的函数体,拿掉了 require_permission(CFO 批准时要用它们试跑,而 CFO 不持 finance.edit)。
--     留着 authenticated 的 EXECUTE,任何登录用户都能不经申请直接出款 —— 本刀要关的正是这扇门。
--     唯一的外门:record_payment(收款 + 豁免出款)与 pay_payment_request(已批准的申请)。
--   payment_request_dry_run —— 按 id 试跑一张申请再回滚;无检查,只从申请函数体内调用。
--   payment_request_conflict / payment_request_payee_check —— 申请函数体内的两个判断。
--   调用方全部是 SECURITY DEFINER,以属主身份执行,收回之后照常工作。
REVOKE EXECUTE ON FUNCTION public.record_payment_internal(text, uuid, numeric, text, numeric, text, date, text, jsonb, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_payment_internal(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payment_request_dry_run(uuid, date, numeric) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payment_request_conflict(jsonb, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payment_request_payee_check(text, uuid) FROM authenticated;

-- PAY-REQ-1 · Batch B(2026-09-23):行内转账、转账冲销、代扣税缴纳与其冲销的内层引擎。
--   同一条理由:它们拿掉了权限检查(CFO 批准时要用它们试跑,而 CFO 不持 finance.edit),
--   靠的就是调不到。唯一的外门是 pay_payment_request(一张已批准的申请);
--   record_bank_transfer / reverse_bank_transfer / remit_wht 只剩按名拒绝的外壳。
REVOKE EXECUTE ON FUNCTION public.record_bank_transfer_internal(date, text, text, numeric, numeric, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_bank_transfer_internal(uuid, date, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.remit_wht_internal(date, date, text, text, text, numeric) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_wht_remittance_internal(uuid, date, text) FROM authenticated;

-- PAYROLL-APR-1(2026-09-24):工资过账的内层引擎与申请的算子。**这几支没有调用者检查,靠的就是调不到。**
--   post_payroll_period_internal / unpost_payroll_period_internal —— 原 post_payroll_period /
--     unpost_payroll_period 的函数体,拿掉了 require_permission(CFO 批准时要用它们试跑,而 CFO
--     不持 module.hr.edit)。留着 authenticated 的 EXECUTE,任何登录用户都能不经申请直接过账 ——
--     本刀要关的正是这扇门。唯一的外门:post_payroll_period / unpost_payroll_period(要一张已批的申请)。
--   payroll_request_dry_run —— 按 id 试跑一张申请再回滚;只从申请函数体内调用。
--   payroll_period_fingerprint —— 一个期间此刻的那一组数(含逐行摘要),只从申请函数体内调用。
--   ☞ payroll_period_frozen 【不在】此列:调它的是两支 INVOKER 守卫,收回就 42501
--     (period_close_floor 同一条;两处 allowlist 有它)。
REVOKE EXECUTE ON FUNCTION public.post_payroll_period_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.unpost_payroll_period_internal(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_request_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_period_fingerprint(uuid) FROM authenticated;
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22):四支内层函数,没有调用者检查,靠的就是调不到 ——
--   reverse_payroll_payment_internal —— 冲一次工资付款的引擎;外门是 reverse_payroll_payment(要一张批过的申请)与申请的两次试跑。
--   assert_entry_not_bank_matched —— 银行行已配对就按名拒(Q6);只在四支冲销引擎的函数体内调用。
--   payroll_payment_entry_kind —— 从已付的戳认付款种类;只在引擎、路由、付薪页读者(都是 DEFINER)里调用。
--   leave_service_entitlement —— 按服务期给的额度(B1);只在 leave_balance_internal 里调用。
REVOKE EXECUTE ON FUNCTION public.reverse_payroll_payment_internal(uuid, date, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_entry_not_bank_matched(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_payment_entry_kind(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.leave_service_entitlement(text, date, date) FROM authenticated;

-- ROLE-1 Batch 4a(2026-09-25,侧门 (c)):reprice_inbound_batch 是每一条定价路径落进来的那支【引擎】
--   (写 unit_price、price_history,过 purchase 分录)。它留着 authenticated 的 EXECUTE,就是
--   set_inbound_unit_price 之外的第二扇公开的定价门。外门只剩:set_inbound_unit_price ·
--   reprice_from_committed_terms · create_inbound_batch(带价)—— 各问 action.price_receipts ——
--   与 apply_assay_result(action.apply_assay)。引擎自己仍问 data.view_purchase_prices
--   (看不见价格的人不能定价),所以它【有】调用者检查;收回是再加的一道,不是唯一的一道。
REVOKE EXECUTE ON FUNCTION public.reprice_inbound_batch(uuid, numeric, text, numeric, text) FROM authenticated;

-- ROLE-1 Batch 4b(2026-09-25):收货定价申请的内层算子。**这几支没有调用者检查,靠的就是调不到。**
--   receipt_price_submit_internal —— 四扇门(定价面板 · 按承诺条款改价 · 收货台带价 · 应用化验)
--     各问完自己的码才落进来;留着 EXECUTE,任何登录用户都能不经那几扇门直接提申请(或在审批
--     关着时直接过账)。
--   receipt_price_post_internal —— 过账本身(调引擎);只从批准、审批关着时的提交与试跑里调用。
--   receipt_price_request_dry_run · receipt_price_withdraw_internal · receipt_price_fingerprint ·
--   receipt_settled_base —— 只从申请函数体内调用。
--   ☞ receipt_price_open 【不在】此列:调它的是两支 INVOKER 守卫,收回就 42501
--     (payroll_period_frozen 同一条;两处 allowlist 有它)。
REVOKE EXECUTE ON FUNCTION public.receipt_price_submit_internal(uuid, numeric, text, text, uuid, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_price_post_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_price_request_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_price_withdraw_internal(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_price_fingerprint(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_settled_base(uuid) FROM authenticated;

-- ROLE-1 Batch 3a(2026-09-25,Q12):assert_other_decider —— 提单人之外没人批得动时按名拒的那一句断言。
--   只从 SECURITY DEFINER 的提交函数(submit_payroll_request 与六支付款申请提交)里调用;它读
--   approval_deciders(本身已收回),留着 EXECUTE 就是把"谁批得了"这张名单的一个问法敞开。
REVOKE EXECUTE ON FUNCTION public.assert_other_decider(text, text, smallint, text) FROM authenticated;
-- U1-B(2026-10-05):带主角的那一版,同一条理由。
REVOKE EXECUTE ON FUNCTION public.assert_other_decider_for_subject(text, text, smallint, uuid, text) FROM authenticated;

-- APR-5a(2026-09-25):贷项 / 作废申请的内层算子。**这几支没有调用者检查,靠的就是调不到。**
--   void_invoice_internal · create_credit_note_internal —— 原 void_invoice / create_credit_note 的函数体(去掉门);
--     留着 EXECUTE,财务就能不经 CFO 直接作废、直接开贷项,而这正是本刀要关的那一扇。
--   invoice_request_submit_internal —— 两扇提交的门各问完 module.finance.edit 才落进来。
--   invoice_request_post_internal —— 过账本身;只从批准、审批关着时的提交与试跑里调用。
--   invoice_request_dry_run —— 只从提交里调用。
REVOKE EXECUTE ON FUNCTION public.void_invoice_internal(uuid, text, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.create_credit_note_internal(uuid, date, text, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.invoice_request_submit_internal(uuid, text, date, text, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.invoice_request_post_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.invoice_request_dry_run(uuid) FROM authenticated;

-- APR-5b(2026-09-25,grilling Q7):预留的两支内层算子。**没有调用者检查,靠的就是调不到。**
--   release_reservation_internal —— 原 release_reservation 的函数体(去掉门)。两个调用方各自先问:
--     release_reservation(module.sales.edit)· ship_order(action.ship_goods,部分发货先放回多出来的那一截)。
--   reserve_stock_internal —— 原 reserve_stock 的函数体(去掉门)。调用方:reserve_stock(module.sales.edit)·
--     release_reservation_internal(部分释放就地重新预留剩余)。
--   留着 EXECUTE,任何登录用户都能不经销售就改别人订单的预留 —— 而仓库发货正是要够得着这一半、够不着那一半。
REVOKE EXECUTE ON FUNCTION public.release_reservation_internal(uuid, numeric, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reserve_stock_internal(uuid, uuid, numeric, uuid) FROM authenticated;

-- APR-6(2026-09-25,grilling Q1):**人手里过手工凭证的门从 post_journal_entry 换成 submit_journal_request。**
--   post_journal_entry —— 过账核心,INVOKER、本体不问码、收调用方给的任意 source_type。线上调它的 30 支函数
--     全是 SECURITY DEFINER(属主 postgres),在属主身份下执行,不需要 authenticated 的 EXECUTE;而留着它,
--     持 module.finance.edit 的人就能不经 CFO 过一张任意标签的分录(一张 'purchase' 进 2000 · 一笔贷银行)——
--     ROLE1B4A-PURCHASE-JOURNAL-FORGEABLE 与 PAYREQ1-MANUAL-JOURNAL-CREDITS-BANK 两扇门的根。
--   journal_request_submit_internal —— 两扇提交的门各问完 module.finance.edit 才落进来。
--   journal_request_post_internal —— 过账本身;只从批准、审批关着时的提交与试跑里调用。
--   journal_request_dry_run —— 只从提交里调用。**这几支没有调用者检查,靠的就是调不到。**
REVOKE EXECUTE ON FUNCTION public.post_journal_entry(date, text, text, uuid, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.journal_request_submit_internal(text, date, text, jsonb, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.journal_request_post_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.journal_request_dry_run(uuid) FROM authenticated;

-- APR-7(2026-09-25):**注销、回滚、证书作废的门换成了四张申请**(仓库提,CFO 批)。
--   soft_delete_inbound_batch_internal / soft_delete_output_batch_internal / rollback_processing_run_internal ——
--     原来三扇门的函数体(去掉了码的检查)。调用者:空批一步删的两扇门(先问 action.batch_write_off 与
--     "要不要经 CFO")与 warehouse_request_execute_internal。留着 EXECUTE,任何登录用户都能不经 CFO、
--     不经任何码注销一批料或回滚一张加工单 —— 那正是本刀要关的门。
--   warehouse_request_submit_internal —— 四扇提交的门各问完自己的码才落进来。
--   warehouse_request_execute_internal —— 生效本身;只从批准、审批关着时的提交与试跑里调用。
--   warehouse_request_dry_run —— 只从提交里调用。
--   warehouse_request_touches / warehouse_request_freezing / warehouse_request_snapshot —— 三支读者只给上面几支
--     与冻结守卫用;snapshot 会把供应商名、证书号交给任何登录用户。**这几支没有调用者检查,靠的就是调不到。**
REVOKE EXECUTE ON FUNCTION public.soft_delete_inbound_batch_internal(uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.soft_delete_output_batch_internal(uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.rollback_processing_run_internal(uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_submit_internal(text, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_touches(text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_freezing(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_snapshot(text, uuid) FROM authenticated;
-- warehouse_request_conflict / batch_write_off_needs_request:只从两扇一步删的门与提交里调(属主身份);屏幕从
--   warehouse_requests_visible 与批次行自己的数读同一件事,不需要它们。
REVOKE EXECUTE ON FUNCTION public.warehouse_request_conflict(text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.batch_write_off_needs_request(uuid, uuid) FROM authenticated;

-- APR-8(2026-09-26):**合同条款与定价公式的生效换成了一张申请**(cco 提,CFO 批)。
--   terms_request_submit_internal —— 四扇提交的门各问完自己的码才落进来。
--   terms_request_execute_internal —— 生效本身(把条款写进公式并启用 / 把合同改成 active);只从批准、审批关着时的
--     提交与试跑里调用。留着 EXECUTE,任何登录用户都能不经 CFO 让一张公式或一份合同生效 —— 那正是本刀要关的门。
--   terms_request_dry_run —— 只从提交里调用。
--   terms_request_snapshot / terms_request_fingerprint / formula_terms_state / contract_terms_state —— 会把公式的
--     费率与比例、合同的条款交给任何登录用户(公式表的费率列本来只经遮蔽视图读)。**这几支没有调用者检查,靠的就是调不到。**
--   contract_terms_lock_reason 【留着】:两支合同守卫以调用者身份问它;它只说出 active 或那一张在等申请的 label。
REVOKE EXECUTE ON FUNCTION public.terms_request_submit_internal(text, uuid, jsonb, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_snapshot(text, uuid, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_fingerprint(text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.formula_terms_state(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.contract_terms_state(uuid) FROM authenticated;

-- APR-9(2026-09-27):**调薪与固定资产处置换成了申请**(调薪:财务提、CFO 批 / CFO 是当事人时 cco 批;处置:财务提、CFO 批)。
--   salary_change_execute_internal / asset_disposal_execute_internal / dispose_fixed_asset_internal —— 生效本身
--     (改月薪、过处置分录)。留着 EXECUTE,任何登录用户都能不经批准改一个人的月薪或处置一台资产 —— 那正是本刀要关的门。
--   asset_disposal_dry_run —— 只从提交里调用。
--   salary_change_fingerprint / salary_change_open / salary_change_deciders / salary_effective_period_block /
--   pay_decision_code / asset_disposal_fingerprint —— 会交出月薪、账号 ↔ 员工对照或资产成本;
--     **没有调用者检查,靠的就是调不到**。屏幕经 salary_change_requests_visible / asset_disposal_requests_visible /
--     review_approval_code(本来就给)读它们的答案。
REVOKE EXECUTE ON FUNCTION public.salary_change_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.asset_disposal_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.dispose_fixed_asset_internal(uuid, date, numeric, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.asset_disposal_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_change_fingerprint(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_change_open(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_change_deciders(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_effective_period_block(date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.pay_decision_code(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.asset_disposal_fingerprint(uuid) FROM authenticated;

-- APR-10(2026-09-27):**GST 申报换成了申请;采购单按品类开、按开单人或这一类的码改。**
--   gst_filing_execute_internal —— 生效本身(写 gst_return_boxes、期间 → approved)。留着 EXECUTE,任何登录用户都能
--     不经 CFO 批就把一组数定成"批准过的申报"—— 那正是本刀要关的门。
--   assert_po_manager —— 只从五扇改单的门里调(全是 DEFINER);它自己不查调用者之外的任何事,靠的是调不到。
--     屏幕读 po_may_manage(只回读者自己的一个布尔)。
REVOKE EXECUTE ON FUNCTION public.gst_filing_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_po_manager(uuid) FROM authenticated;

-- OVERTIME-1(2026-09-28):三支内层判据只由 DEFINER 的加班函数与 complete_attendance_period 在属主身份下调用。
REVOKE EXECUTE ON FUNCTION public.overtime_approved_hours(date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.overtime_assert_month_open(date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.overtime_other_approver_exists(uuid, uuid[]) FROM authenticated;

-- HISTORY-1(2026-09-28):通用变更记录的内层函数只由 DEFINER 的读法(change_log_rows)、写法(change_log_capture
--   触发器)与匿名化(anonymise_employee)在属主身份下调用。
--   change_log_field —— 按表名动态读【任意一张表】的任意一列:给了 authenticated 就是一扇绕过列级遮蔽的门
--     (以调用者身份跑时列权限仍挡着,但那是第二道;第一道是调不到)。
--   change_log_rule_visible / change_log_task_visible —— 经它们能逐行探测别人的员工 id 与任务归属。
--   change_log_redact_employee —— 唯一能改 change_log 的路;只许 anonymise_employee 走(它自己也查码)。
--   change_log_capture —— 触发器函数,不该被直接调。
--   ☞ change_log_rows / change_log_filters / record_account_event【不收】:各自查 data.view_change_log /
--     action.manage_permissions,屏幕与服务端动作要调它们。change_log_mask_gaps / change_log_coverage_gaps
--     只读目录与常量名单,gate 与 fixture 调它们。
REVOKE EXECUTE ON FUNCTION public.change_log_field(text, jsonb, jsonb, jsonb, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.change_log_rule_visible(text, text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.change_log_task_visible(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.change_log_redact_employee(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.change_log_capture() FROM authenticated;

-- AUDIT-TRAIL-1a(2026-09-29):审计记录的内层函数只由 DEFINER 的读法(record_trail · change_log_rows ·
--   change_log_filters)在属主身份下调用,自己没有调用者检查,靠的就是调不到:
--   change_log_mask_row —— 遮蔽那一步;它调的 change_log_field 能按表名读任意一张表。
--   trail_current_image / trail_ref_label / trail_refs / trail_row_record —— 按表名动态读任意一行(或它最后的影像)。
--   trail_row_visible —— 给了 authenticated 就是一支"任意一行你看不看得见"的探针。
--   trail_actor —— 回答任意一个账号 / 员工 id 是谁(与 account_person 同一个理由)。
--   ☞ record_trail / change_log_find_records【不收】:前者查主语的查看码与根行的读规则,后者查 data.view_change_log。
--     trail_subjects / trail_subject_members / trail_prelog_sources / trail_pk_columns / trail_fk_targets /
--     change_log_began_at 只读常量名单或目录,留着(fixture 与检查脚本会调)。
REVOKE EXECUTE ON FUNCTION public.change_log_mask_row(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_current_image(text, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_ref_label(text, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_refs(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_row_record(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_row_visible(text, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_actor(text, uuid, uuid) FROM authenticated;

-- AUDIT-TRAIL-1d-1(2026-10-04):M12 的门只由 record_trail(属主身份)调用 —— 给了 authenticated 就是一支
--   "这一份评审的审核人是不是你"的探针。M9 / M10 的两张登记表(trail_log_only_tables · trail_member_columns)只读常量,留着
--   (与 trail_subjects 同一个理由:fixture 与检查脚本会调)。save_employee【不收】:它是员工表单的那一次写入,
--   按调用者的身份跑(SECURITY INVOKER),表的策略与守卫照常管。
REVOKE EXECUTE ON FUNCTION public.trail_root_gate(text, text, jsonb) FROM authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ MES-1(2026-10-06):本仓库【第二条】、也是 MES 组里【唯一一条】给 anon 的 EXECUTE ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- 【它是什么】ingest_submit(text, text, jsonb) —— 车间网关唯一够得着的东西(MES-0 Q4,Tim)。网关带着项目的公开 apikey
--   POST /rest/v1/rpc/ingest_submit;它的"权限"是那把 244 位随机的网关钥匙,函数里只比 sha256(MES-0 Q5)。
-- 【它碰得到什么】白名单:只插入收件箱、传输日志与网关中断(两种桶的四个计数列除外),一行设备都不改,不跑转换代码,
--   只回调用者自己的序号与固定的码。函数抬头逐条写着;fixture 249 按事务内的逐表计数证"它只写了这三张"。
-- 【为什么给 anon,不给一个登录角色或一个 Supabase 账号】MES-0 §3.3:authenticated 默认执行每一支函数、44 条策略
--   USING (true) —— 一个登录的网关第一天就读得到内部的表;而 db/check_grants.py 只看 anon,一个登录角色它看不见。
-- ⚠★【必须写在这里,写在本文件第一句 REVOKE 的后面】与 cod_verification 同一个理由:apply_migration.sh 把本文件拼在
--   COMMIT 之前、同一个事务里重跑,一条只写在迁移里的 GRANT 会被那句 REVOKE 冲掉,而迁移报告成功。
GRANT EXECUTE ON FUNCTION public.ingest_submit(text, text, jsonb) TO anon;
-- ★ 而且【只】给 anon(MES-1 Step 0 Q4,Tim):本文件第 31 行把每一支函数授给 authenticated 与 service_role ——
--   给了 authenticated,任何一个登录的人都能冒充网关送数(只要拿得到钥匙)而且绕开网关那条路的全部语义;
--   service_role 是服务端的钥匙,没有一条合法的服务端路径要调它。两个都收回;fixture 249 GRANT 臂两个都断言。
--   ☞ 这两句写在第 31 行【之后】,所以每一次重放都是"先全授、再收回"—— 顺序就是判据。
REVOKE EXECUTE ON FUNCTION public.ingest_submit(text, text, jsonb) FROM authenticated, service_role;

-- MES-1:分派器与转换器是【内层】—— 没有调用者检查,只由 ingest_process_pending / retry_inbox_row(各自查码)以属主身份调。
--   给了 authenticated,就是一支"随便哪一行收件箱都替你转换"的后门,也绕开了处理按钮的那一道码。
REVOKE EXECUTE ON FUNCTION public.ingest_transform_row(bigint) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.transform_connection_test_v1(jsonb) FROM authenticated;

-- MES-2(2026-10-06):四支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   transform_weighing_v1:称重的转换器(分派器与确认按名字调它)。
--   capture_confirm_internal:确认一张草稿(confirm_capture_draft · submit_manual_capture · correct_weighing)。给了 authenticated,
--     就是一支绕开 action.confirm_capture 把草稿写成正式记录的后门。
--   weighbridge_share_internal:把地磅单分一份出去(两支收货函数 · share_weighbridge_ticket)—— 给了,就绕开收货与发货那两个码。
--   assert_receipt_reading_calibrated:校准闸(reprice_inbound_batch · preview_reprice_inbound_batch · issue_cod)。
--   calibration_status_from【不收】:它是一句纯判断(IMMUTABLE,不读任何表),属主视图里由读者的身份执行 —— 收了它,
--   weighing_calibration / instrument_calibration_now 对每一个读者 42501(AGENTS.md「属主视图替得了表,替不了函数的 EXECUTE」)。
REVOKE EXECUTE ON FUNCTION public.transform_weighing_v1(jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.capture_confirm_internal(uuid, jsonb, jsonb, jsonb, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.weighbridge_share_internal(uuid, uuid, uuid, numeric, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_receipt_reading_calibrated(uuid) FROM authenticated;

-- MES-3a(2026-10-06):两支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   receipt_ceiling_check_internal:库存上限的判法与那一行记录(两支收货函数 · create_output_batch)。给了 authenticated,
--     就是一支随手往 receipt_ceiling_checks 里写判法、还能锁执照行的后门。
--   assert_quarantine_landing:隔离闸(两支收货函数 · create_stock_transfer)。
--   quantity_in_tonnes【不收】:一句纯换算(IMMUTABLE),属主视图里由读者的身份执行。
--   storage_licence_in_force【不收】:它是 DEFINER,只回一个 id;storage_ceiling_status 与 pending_values 以读者身份调它。
REVOKE EXECUTE ON FUNCTION public.receipt_ceiling_check_internal(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_quarantine_landing(text[], uuid) FROM authenticated;

-- MES-3b(2026-10-07):三支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   label_object_data:一张标签上印什么(物料名与供应商名以属主身份读 —— Q2 的并入)。给了 authenticated,就是一支绕开 materials /
--     suppliers 的 RLS、按 id 读任何一批物料名与供应商名的后门。调用方:label_print_context。
--   label_print_context:印标签之前的全部判断(种类、查看码、模板、以前印过几次)。调用方:label_print_preview · record_label_print。
--   batch_quarantine_states:一批身上开着的要隔离的状态。调用方:shipment_document · shipping_queue_rows。
--   resolve_scan_code / label_print_preview / record_label_print【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.label_object_data(text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.label_print_context(text, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.batch_quarantine_states(uuid) FROM authenticated;

-- MES-4a(2026-10-07):五支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   assert_run_header:一张新加工单的表头说不说得通(commit_processing_run · correct_run_header;以及 processing_runs 的 INSERT 触发器 ——
--     直连插入早在 guard_processing_direct_write 那一步就按名拒了,触发器只在属主路径上真的跑到它)。
--   assert_run_equipment:这一炉的机器(EQP-2a 的三条 + 工序 ↔ 资产)。调用方:commit_processing_run · correct_run_header。给了 authenticated,
--     就是一支按 id 探 fixed_assets(只给财务读)的后门。
--   record_manual_weighing_internal:在提交那一刻落一条手工称重(收件箱 → 转换 → 草稿 → 确认)。给了,就绕开 action.confirm_capture。
--   record_run_value_internal:给一炉记 / 更正一个值。调用方:commit_processing_run · record_run_value · correct_run_value。给了,就绕开
--     action.processing_aftercare 与"加工单必须已提交"那一句。
--   run_event_check:一件异常事件的五样(record_run_event · correct_run_event)。
--   record_run_value / correct_run_value / record_run_event / correct_run_event / record_run_loss / correct_run_loss / close_run_balance /
--   correct_run_header / create_recipe_version / processing_runs_unclosed_balance【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.assert_run_header(date, timestamp with time zone, timestamp with time zone, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_run_equipment(text, uuid, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.record_manual_weighing_internal(numeric, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.record_run_value_internal(uuid, text, jsonb, text, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.run_event_check(text, timestamp with time zone, numeric, text, text) FROM authenticated;

-- MES-4b(2026-10-07):一支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   contamination_check_internal:一次交叉污染抽检的判据与落库(record_contamination_check · correct_contamination_check)。
--     给了 authenticated,就绕开 action.processing_aftercare,也绕开"只能更正链的末端"那一句。
--   set_batch_cell_construction / record_derived_electrolyte_loss / rederive_electrolyte_loss / record_contamination_check /
--   correct_contamination_check【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   guard_batch_cell_construction 是触发器函数(与其余触发器同一条:EXECUTE 只在被直接调用时才有意义)。
REVOKE EXECUTE ON FUNCTION public.contamination_check_internal(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text, bigint, text) FROM authenticated;

-- MES-5a-1(2026-10-08):四支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   discharge_result_internal:一条放电模组结果的判据与落库(record / correct_discharge_module_result)—— 给了 authenticated,
--     就绕开 action.confirm_capture,也绕开"只能更正链的末端"。
--   discharge_channel_internal:一条通道分配的判据与落库(assign / correct_discharge_channel)—— 绕开 action.processing_aftercare。
--   discharge_verify_batch:按逐模组结论改一批的安全状态 —— 给了 authenticated,任何人都能把一批"核实"成已放电(火闸的另一侧)。
--   create_stock_transfer_internal:库存转移的函数体(create_stock_transfer 判 module.inventory.edit 后转交;拆去隔离判
--     action.processing_aftercare 后转交)—— 给了 authenticated,就绕开库存编辑码。
--   guard_batch_module_count 是 SECURITY DEFINER 的触发器函数(它要数放电结果、读安全状态,不能被 RLS 数成 0);
--     触发器触发时不查 EXECUTE,所以收回它只关掉"被直接调用"那一条路。
--   set_batch_module_count / record_discharge_module_result / correct_discharge_module_result / assign_discharge_channel /
--   correct_discharge_channel / split_failed_modules_to_quarantine【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.discharge_result_internal(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.discharge_channel_internal(uuid, text, uuid, integer, text, boolean, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.discharge_verify_batch(text, uuid, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.create_stock_transfer_internal(numeric, uuid, uuid, uuid, uuid, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_batch_module_count() FROM authenticated;

-- MES-5a-2(2026-10-08):两支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   meter_reading_internal:一条电表读数的判据与落库(record / correct_meter_reading)—— 给了 authenticated,就绕开 action.confirm_capture,
--     也绕开"只能更正链的末端"。
--   electricity_allocation_compute:电费单怎么分(preview / post_electricity_allocation)—— 它自己不写任何东西,但它不查码,
--     而它读的是电表读数、各炉的电量与运行时长、估计的金额(加工成本的金额要 data.view_prices);给了 authenticated 就是一支绕开那道遮蔽的读法。
--   record_meter_reading / correct_meter_reading / preview_electricity_allocation / post_electricity_allocation / set_electricity_shared_pool_rule
--   【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.meter_reading_internal(uuid, timestamp with time zone, numeric, boolean, text, text, boolean, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.electricity_allocation_compute(date, date, numeric, numeric, text, text, text) FROM authenticated;

-- MES-5b-2(2026-10-09):一支【内层】与一支触发器函数。
--   reverse_expense_internal:冲一张费用单的那一段(reverse_expense 与 reverse_electricity_allocation 共用)—— 它不查码;给了 authenticated
--     就是一支绕开 module.finance.edit、也绕开"电费分摊的费用单只许整张撤回"的冲销。
--   guard_electricity_line_one_live_allocation:分摊行的插入守卫(触发器函数;触发时不查 EXECUTE,收掉只是让它不在 API 上)。
--   reverse_electricity_allocation【不收】:它是 DEFINER,自己查码,员工就是要调它。
REVOKE EXECUTE ON FUNCTION public.reverse_expense_internal(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_electricity_line_one_live_allocation() FROM authenticated;

-- MES-5b-3(2026-10-09):一支【内层】与两支触发器函数。
--   blending_plan_write_children:配料计划的判据与落库(create / amend_blending_plan 共用;INVOKER,在它们里面以属主身份跑)—— 它不查码;给了 authenticated
--     就是一支绕开 action.wo_create、也绕开"只有草稿改得动"的写法。
--   guard_blending_run_from_plan · guard_blended_batch_metals_from_assay:触发器函数(触发时不查 EXECUTE,收掉只是让它们不在 API 上;
--     后一支是 DEFINER,更不该在 API 上)。
--   create / amend / release / cancel / execute_blending_plan【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   next_blending_plan_code【不收】:与 next_work_order_code 一样,是一支只读的取号函数(读 document_types 与编号的最大值)。
REVOKE EXECUTE ON FUNCTION public.blending_plan_write_children(uuid, uuid, uuid, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_blending_run_from_plan() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_blended_batch_metals_from_assay() FROM authenticated;

-- MES-6a-1(2026-10-09):一支触发器函数。
--   guard_assay_sample_batch:化验指着的样品必须是同一批的(触发器函数;触发时不查 EXECUTE,收掉只是让它不在 API 上 —— 它是 DEFINER,更不该在)。
--   record_sample / record_sample_event / set_quality_settings / open_assay_dispute / record_dispute_umpire / withdraw_assay_dispute /
--   resolve_assay_dispute / link_dispute_fee【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   next_sample_code【不收】:与 next_blending_plan_code 一样,是一支只读的取号函数。
REVOKE EXECUTE ON FUNCTION public.guard_assay_sample_batch() FROM authenticated;

-- MES-6a-2(2026-10-10):一支触发器函数与一支【内层】。
--   guard_substance_role:定价那几张表只收按含量计价的金属、惩罚条款只收惩罚元素(触发器函数;触发时不查 EXECUTE,收掉只是让它不在 API 上)。
--   payable_metals_only:把一张含量清单里的惩罚元素拿掉(只给那几支 DEFINER 计价读者在体内用;给了 authenticated 也只是一支无害的过滤器,
--     收掉是让 API 上少一支没有屏幕的函数)。
--   record_assay_result 的新签名(尾部多了 p_indicators)【不收】:它是 DEFINER,自己查码,员工就是要调它(上面那一句整体授权覆盖它)。
REVOKE EXECUTE ON FUNCTION public.guard_substance_role() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payable_metals_only(jsonb) FROM authenticated;

-- MES-6b-1(2026-10-15):三支触发器函数与两支【内层】。
--   guard_quality_hold:质量暂扣守在流水上(触发器函数;触发时不查 EXECUTE,收掉只是让它不在 API 上 —— 它是 DEFINER,更不该在)。
--   guard_substance_priced_and_penalised:一种物质在一份合同里要么计价、要么罚(触发器函数,DEFINER)。
--   guard_ncr_mutation:不合格报告只追加(触发器函数)。
--   ncr_open_internal:落一张不合格报告(取号、写一行)—— 不问码、不判来源;给了 authenticated 就是一支绕开 module.quality.edit、
--     也绕开"系统才开 quality_limit"的写法。
--   judge_quality_limits:判一批对一张单的质量验收限并在越限时开报告 —— 不问码;只在 record_assay_result / reserve_stock_internal 里以属主身份跑。
--   open_ncr / decide_ncr【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   batch_quality_hold【不收】:它是 INVOKER,以调用者的读规则读(销售结算的预览以读者身份调它);assay_is_supplement 同理【不收】。
--   next_ncr_code【不收】:与 next_sample_code 一样,是一支只读的取号函数。
REVOKE EXECUTE ON FUNCTION public.guard_quality_hold() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_substance_priced_and_penalised() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_ncr_mutation() FROM authenticated;
-- MES-7b-1:末尾多了 p_incident_id(来源 incident 的那一张指着的事故)—— 签名换了,这一行跟着换。
-- MES-7b-2:末尾又多了 p_inspection_finding_id(来源 inspection 的那一张引用的巡检发现)—— 签名又换了,这一行再跟着换。
REVOKE EXECUTE ON FUNCTION public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid, uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.judge_quality_limits(uuid, uuid, text) FROM authenticated;

-- MES-6b-2(2026-10-15):一支触发器函数与五支【内层】。
--   guard_coa_mutation:分析证书签发之后只许作废、作废之后只许填一次替代品(触发器函数)。
--   coa_governing_assay · coa_output_calibration_problem · coa_issue_blockers · coa_assemble:证书说话的那一份化验、称重的校准、拒绝清单、
--     纸上每一个值 —— 不问码,以属主身份读批次、化验、争议、报告、合同副本与客户名;给了 authenticated 就是一扇绕开 module.output.view
--     读这些的门。外面经 coa_certificate_data(查 module.output.view)与 issue_coa(查 action.issue_coa)读它们。
--   void_coa_internal:作废一张分析证书 —— 只经 CFO 批准的 coa_void 申请走到这里;给了 authenticated 就是一扇绕开 CFO 的作废门。
--   issue_coa / record_coa_issue / submit_coa_void_request / coa_certificate_data【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   next_coa_code【不收】:与 next_ncr_code 一样,是一支只读的取号函数。
REVOKE EXECUTE ON FUNCTION public.guard_coa_mutation() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_governing_assay(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_output_calibration_problem(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_issue_blockers(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_assemble(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.void_coa_internal(uuid, text, uuid) FROM authenticated;
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q3 · Q6):设备记录的内层与触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_downtime_cause · guard_downtime_cause_class · guard_equipment_direct_write:触发器函数(停机的原因与来源 · 被引用的原因类别冻住 ·
--     三张设备表不许绕过函数写)。
--   equipment_record_target · downtime_cause_check:五支设备记录函数共用的两句判据(一台在册的机器 · 一个能用的原因代号)。
--     调用方都是 DEFINER(open_ · close_ · correct_equipment_downtime · record_equipment_maintenance · save_equipment_service_interval),
--     以属主身份读 fixed_assets 与 downtime_causes。
--   那五支、equipment_reliability 与 coa_issuer【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.guard_downtime_cause() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_downtime_cause_class() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_equipment_direct_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.equipment_record_target(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.downtime_cause_check(text) FROM authenticated;
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q12 · Q13 · Q14):备件出库的内层与触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_maintenance_movement · guard_part_issue_write · guard_maintenance_capitalise_parts:触发器函数(两种保养流水只经那两支函数 ·
--     出库记录只可追加、只经函数写 · 还挂着件的保养记录不能资本化)。
--   inbound_batch_maintenance_net_qty:一批出给保养的净数量 —— 只在 reprice_inbound_batch · preview_reprice_inbound_batch ·
--     inventory_control_reconciliation(都是 DEFINER)里被调用;它不问码。
--   issue_spare_parts · return_spare_parts【不收】:它们是 DEFINER,自己查 module.inventory.edit,员工就是要调它们。
--   reprice_split【不收】(签名换成五个入参):纯算术,IMMUTABLE,不读任何表 —— 与它换签名之前一样。
REVOKE EXECUTE ON FUNCTION public.guard_maintenance_movement() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_part_issue_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_maintenance_capitalise_parts() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.inbound_batch_maintenance_net_qty(uuid) FROM authenticated;
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q4 · Q7):事故登记簿的四支触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_incident_kind_code(用过的种类代号冻住)· guard_incident_write(事故写下就不改、只经函数写、来源 / 时刻 / 种类 / 停机 / 事件的行规矩)·
--   guard_incident_update_write(之后的事实只可追加、只经函数写)· guard_incident_batch_write(链接只经函数写、只在解链接那一次改)。
--   record_incident · record_incident_update · link_incident_batch · unlink_incident_batch · suggest_incident_batches · set_safety_settings【不收】:
--   它们是 DEFINER,自己查码(module.safety.edit / module.safety.view),员工就是要调它们。
--   business_days_after · next_incident_code【不收】:一支只读公共假期表的算术、一支只读的取号函数(与 next_ncr_code 一样)。
REVOKE EXECUTE ON FUNCTION public.guard_incident_kind_code() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_incident_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_incident_update_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_incident_batch_write() FROM authenticated;
-- MES-7b-2(2026-10-16,MES-7b Step 0 Q13 · Q14 · Q16):巡检与环境监测的四支触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_inspection_template_write(清单与检查项只经函数写、清单不许删)· guard_inspection_record_write(巡检 / 结果 / 发现 / 关闭交了就不改、
--   只经函数写、发现只挂在不合格的那一项上)· guard_environmental_parameter_code(限值成对、用过的代号冻住)· guard_environmental_result_write
--   (结果只追加、只经函数写、采样日不在未来)。
--   save_inspection_template · record_inspection_run · record_inspection_finding · close_inspection_finding · raise_inspection_finding_task ·
--   record_environmental_result【不收】:它们是 DEFINER,自己查码(module.safety.edit / module.safety.view),员工就是要调它们。
--   next_inspection_code【不收】:一支只读的取号函数(与 next_incident_code 一样)。
REVOKE EXECUTE ON FUNCTION public.guard_inspection_template_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_inspection_record_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_environmental_parameter_code() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_environmental_result_write() FROM authenticated;
-- MES-8a(2026-10-16,MES-8 Step 0 Q2 · Q5 · Q7):三支触发器函数与一支内层 —— 没有调用者检查,靠的就是调不到。
--   guard_supplier_scorecard_review_write(评审只追加)· guard_supplier_statement_write(签发了的对账单只许被取代)·
--   guard_supplier_statement_issue_write(签发档只追加)·
--   supplier_grade_advice_internal(等级建议的那一份实现;create_purchase_order 调它,对外的是 supplier_grade_advice,查 module.suppliers.view)。
--   supplier_scorecard_measures · supplier_scorecard_preview · record_supplier_review · set_supplier_score_settings · supplier_grade_advice ·
--   supplier_statement_data · issue_supplier_statement · record_supplier_statement_issue【不收】:它们是 DEFINER,自己查码。
--   supplier_scorecard_measure_keys · supplier_scorecard_grade · next_supplier_statement_code【不收】:纯函数 / 取号,不读不写别人的东西。
REVOKE EXECUTE ON FUNCTION public.guard_supplier_scorecard_review_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_supplier_statement_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_supplier_statement_issue_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.supplier_grade_advice_internal(uuid, jsonb, numeric) FROM authenticated;
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q10 · Q12 · Q14–Q17):两支触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_compliance_pack_write(冻下来的包只许被取代)· guard_compliance_pack_issue_write(签发档只追加)。
--   inbound_batch_margin · inventory_metal_exposure · compliance_pack_data · freeze_compliance_pack · record_compliance_pack_issue ·
--   set_compliance_settings · compliance_pack_month_status【不收】:它们是 DEFINER,自己查码。
REVOKE EXECUTE ON FUNCTION public.guard_compliance_pack_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_compliance_pack_issue_write() FROM authenticated;
-- MES-8b-2(2026-10-17,MES-8 Step 0 Q19 · Q20):本刀没有要收的函数 —— floor_board · set_floor_board_settings · session_is_floor_display_only 是 DEFINER,
--   自己查码(session_is_floor_display_only 只读调用者自己的授权,所以对每一个登录的人开放);floor_board_arms 是纯函数,不读任何表。

-- ════════════════════════════════════════════════════════════════════════════
-- MES-9a(2026-10-19,MES-9 Step 0 Q2 · Q3 · Q11 · Q27,Tim):【供应商门户】—— 三类函数,三种授法。
-- ════════════════════════════════════════════════════════════════════════════
-- ① 门户会话调的(portal_me · portal_export_my_data):【只】授 supplier_portal。authenticated 与 service_role 从第 31 行那一句拿到的收回 ——
--    一个员工会话(或 hook 被关掉之后拿着 authenticated 令牌的门户账号)调它们是 42501,门户看得见地停下(Q11)。
--    supplier_portal 能执行的每一支都在 db/portal-grants-baseline.tsv 里(判词八,两侧逐条相等);fixture 275 对其中每一支跑两家供应商。
REVOKE EXECUTE ON FUNCTION public.portal_me() FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_export_my_data() FROM authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_me() TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_export_my_data() TO supplier_portal;
-- ② 内层判据 portal_require_link:谁都不授 —— 只由 ① 在它们自己的 DEFINER 体内调用(属主身份)。
REVOKE EXECUTE ON FUNCTION public.portal_require_link() FROM authenticated, service_role;
-- ③ access token hook:只授 supabase_auth_admin(Supabase Auth 调它的那个身份)。它对每一个人的每一次签发都跑,
--    authenticated / anon / service_role 都没有理由调它。
REVOKE EXECUTE ON FUNCTION public.portal_access_token_hook(jsonb) FROM authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_access_token_hook(jsonb) TO supabase_auth_admin;
-- 员工那一侧的(portal_user_create_link · portal_user_revoke · portal_contact_anonymise · portal_actor_labels · set_account_setting)
--   照第 31 行授给 authenticated —— 它们是 DEFINER,自己查码(action.manage_portal_users / action.manage_permissions)或会话(auth.uid())。
-- ④ MES-9b(2026-10-19,MES-9 Step 0 Q14 · Q22):供应商看得见什么 —— 四支,同 ① 的授法:【只】授 supplier_portal。
--    portal_documents · portal_deliveries(清单,只读)· portal_document_open(写调用者自己的一行下载记录,交出路径与哈希)·
--    portal_can_read_object(storage.objects 上那条 TO supplier_portal 的读策略的判据 —— 策略以调用者身份求值,所以门户角色要执行得到它)。
--    fixture 276 对其中每一支跑两家供应商;判词八逐条比基线。
REVOKE EXECUTE ON FUNCTION public.portal_documents() FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_deliveries() FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_document_open(text, uuid) FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_can_read_object(text, text) FROM authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_documents() TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_deliveries() TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_document_open(text, uuid) TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_can_read_object(text, text) TO supplier_portal;
-- ⑤ MES-9c(2026-10-20,MES-9 Step 0 §5 · Q19 · V39):门户交证书 —— 五支,同 ① 的授法:【只】授 supplier_portal。
--    portal_certificates(清单与 V39)· portal_submission_begin(先按 V39 判,登记一行 uploading)· portal_submission_finish(字节到了 → 等审核)·
--    portal_submission_abandon(没传成 → 收回)· portal_can_upload_object(portal-uploads 上两条 TO supplier_portal 策略的判据)。
--    fixture 277 对其中每一支跑两家供应商;判词八逐条比基线。员工审核那两支(portal_submission_accept · _reject)照第 31 行授给
--    authenticated —— DEFINER,自己查 module.suppliers.edit(Q19)。
REVOKE EXECUTE ON FUNCTION public.portal_certificates() FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_submission_begin(text, text, text, bigint, text, date, date) FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_submission_finish(uuid) FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_submission_abandon(uuid) FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_can_upload_object(text, text) FROM authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_certificates() TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_submission_begin(text, text, text, bigint, text, date, date) TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_submission_finish(uuid) TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_submission_abandon(uuid) TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_can_upload_object(text, text) TO supplier_portal;

-- ════════════════════════════════════════════════════════════════════════════
-- F16(MES-7b-2,2026-10-16,Tim):【视图一律不可写】—— 收回 anon / authenticated(与 PUBLIC)在 public 里【每一张视图】上的
--   INSERT · UPDATE · DELETE · TRUNCATE。
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么】平台的默认权限把 arwdDxtm 授给每一个新建的关系,视图也一样;而一张【简单】的属主权限视图是可以自动更新的 ——
--   写穿它,对基表用的是【视图属主】的权限,RLS 不按调用者判。MES-7b-1 量到 163 张视图对 authenticated 带着写授权
--   (MES7B1-VIEW-DEFAULT-WRITE-GRANTS);MES-7b-2 在线上以一个不持任何码的一次性账号量:45 张视图收下了一句零行的写
--   (db/scripts/2026-10-16-mes7b2-view-writes.mjs)。应用与 db/ 里没有一处写穿视图(F16 第 2 步的勘察,交回报告里逐条列着)。
-- 【为什么住在这个文件里】这个文件在重建的最后一步跑(视图都建好了),而 db/apply_migration.sh 在【每一支迁移的同一个事务里】再跑它一遍 ——
--   于是"以后的视图也拿不到写授权"不靠任何人记得:一支迁移建了一张新视图,它提交的那一刻这一段已经把写授权收回了。
--   ★ 那正是委托书"默认权限也要改"那一句要的结果。PostgreSQL 的 ALTER DEFAULT PRIVILEGES 分不出视图与表(对象类型只有 TABLES 一种),
--     在线上把它改成"不授写"会让【以后的每一张新表】也拿不到 authenticated 的写 —— 而 303 份表镜像里 273 份靠的就是那条默认授权,
--     重建库(prelude 照旧按默认授)与线上会在每一张新表上悄悄分开。所以本刀【不改】默认权限,改用这一段 + gate 的 viewwrite 断言
--     (线上与重建两侧都问:任何一张视图对 anon / authenticated 带写授权就红)。
-- 【幂等】对一张没有写授权的视图 REVOKE 是空操作;跑两遍不改任何 relacl。
DO $f16$
DECLARE
    v record;
BEGIN
    FOR v IN SELECT c.oid::regclass AS rel
               FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'public' AND c.relkind = 'v'
              ORDER BY c.relname LOOP
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON %s FROM PUBLIC, anon, authenticated', v.rel);
    END LOOP;
END
$f16$;

-- ★ SYSTEM-MAP-2(2026-10-27):self_approval_allows 是 forbid_self_approval 的判据(从它搬出来的),经 self_leg /
--   self_approval_exception 去问(两者都已收回)—— 与它们同一条理由收回。waiting_decisions / waiting_mine /
--   waiting_decision_reach 【不收】:它们是 SECURITY DEFINER,只答【调用者自己】(auth.uid() / current_user_employee()),
--   operations_now(属主视图)调用 waiting_decisions,而视图里的函数按读者判 EXECUTE。
REVOKE EXECUTE ON FUNCTION public.self_approval_allows(uuid, uuid, text, uuid) FROM authenticated;

-- GOLIVE-2(Tim 2026-10-30 Q5):结算的算术只由 record_sale_settlement(SECURITY DEFINER,先问 module.customers.edit,不持 data.view_prices
--   时把六样钱读成受限)调用。它自己是 SECURITY INVOKER、没有价格码的判断 —— 留着 authenticated 的 EXECUTE,任何登录用户都能直接调它,
--   绕过 sales_settlements_masked 拿到结算金额(app / lib 里没有任何一处调它)。收回之后它照常在 record_sale_settlement 的函数体里以属主身份跑。
REVOKE EXECUTE ON FUNCTION public.sale_settlement_compute(uuid, uuid, uuid) FROM authenticated;

SELECT 'PROOF|B|postgres|' || json_build_object(
  'seven_grants', (SELECT count(*) || ' ' || md5(string_agg(r.code || '/' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code IN ('admin','cco','cfo','cto','finance','gm','warehouse')),
  'six_grants_no_admin', (SELECT count(*) || ' ' || md5(string_agg(r.code || '/' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code IN ('admin','cco','cfo','cto','finance','gm','warehouse') AND r.code <> 'admin'),
  'user_roles', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.user_roles t),
  'change_log', (SELECT count(*) || ' max ' || max(seq) FROM public.change_log),
  'contracts', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contracts t), 'cod_issues', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.cod_issues t),
  'buckets', (SELECT count(*) FROM storage.buckets), 'storage_policies', (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage'),
  'anon_relations', (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r','v','m','p','f')
                       AND has_table_privilege('anon', c.oid, 'SELECT')),
  'new_tables', (SELECT string_agg(relname, ',' ORDER BY relname) FROM pg_class WHERE relnamespace = 'public'::regnamespace
                   AND relname IN ('contract_files','contract_signatories','signature_specimens','company_stamps')),
  'manage_signatories_holders', (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
                   WHERE rp.permission_code = 'action.manage_signatories'),
  'approvals', (SELECT approvals_enabled FROM public.finance_settings),
  'req_cal', (SELECT COALESCE(require_calibrated_since::text, 'NULL') FROM public.ingest_settings))::text;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|B|cfo|signatory_active ' || public.contract_signatory_active()::text;
SELECT 'PROOF|B|cfo|files_visible ' || (SELECT count(*) FROM public.contract_files);
DO $c$ BEGIN PERFORM public.contract_sign_begin(gen_random_uuid(), false, 1, 0.5, 0.5); RAISE NOTICE 'PROOF|B|cfo|sign_begin returned (should have refused)';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PROOF|B|cfo|sign_begin refused %', SQLERRM; END $c$;
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"c8116e6c-80db-4a16-be12-24fb6ce6859d","role":"authenticated"}', true) \g /dev/null
DO $w$ BEGIN PERFORM public.contract_signatory_add(gen_random_uuid(), 'x'); RAISE NOTICE 'PROOF|B|warehouse|signatory_add returned (should have refused)';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PROOF|B|warehouse|signatory_add refused %', SQLERRM; END $w$;
RESET ROLE;
ROLLBACK;
SELECT 'PROOF|C|after rollback|new_tables=' || COALESCE((SELECT string_agg(relname, ',') FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname IN ('contract_files','contract_signatories','signature_specimens','company_stamps')), 'none') || ' buckets=' || (SELECT count(*) FROM storage.buckets);
