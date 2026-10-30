-- db/migrations/2026-10-30-contract-esign.sql
-- CONTRACT-ESIGN(v1.4.85)—— 合同的电子文件、具名签署人、公司印章、在系统里签字。Tim 2026-10-29 的裁定(第 2 条)与 2026-10-30 Step 0 的 Q1–Q12。
--   由 db/scripts/build_contract_esign_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】
--   ① 新码 action.manage_signatories(签署人名单与公司印章,Q3),只授 admin;查看码声明 action.manage_signatories · module.suppliers.view。
--   ② 四张新表:contract_signatories(名单,具名的人)· signature_specimens(签署人本人画的签名,Q4)· company_stamps(公司印章)·
--      contract_files(合同文件的每一个版本:original → signed → countersigned;sha256 每一个版本都有;作废要理由,Q7)。只经函数写。
--   ③ 函数:contract_signatory_add / _remove · signature_specimen_record · company_stamp_record · contract_file_begin / _finish / _abandon ·
--      contract_sign_begin(只在生效中的合同上、只给名单上的人、要 5 分钟内重新输入过密码 —— 令牌 amr 里的 password 项,Q1 · Q3 · Q5)·
--      contract_file_void · 四条存储判据(contract_file_can_upload / _can_read · signing_asset_can_upload / _can_read)·
--      contract_file_readable(那一侧的读码 + 价格码,Q8)· contract_signatory_active · signing_password_verified_at · 两支守卫。
--   ④ 两个私有桶:contract-files(25 MB · 只收 PDF,Q12)与 signing-assets(1 MB · 只收 PNG);四条存储策略(传 / 读各两条),没有 UPDATE、没有 DELETE。
--   ⑤ 四张表进变更记录(名单的每一次增减都记下 —— Tim 2026-10-29)。
-- 【不做什么】不碰审批开关、hook、portal-uploads 与 claim-receipts 两个桶与它们的策略、任何账号与角色的授予(admin 角色多一个码是本刀唯一的授权改动);
--   不改任何既有的表、函数或策略;require_calibrated_since 保持空。
-- 【破窗】旧应用 + 新库这一窗里坏的(推导):没有 —— 本迁移只新增对象,旧应用一个都不读;admin 多出的码旧应用不认识也不用。
-- 镜像(同一个提交):db/tables/{contract_signatories,signature_specimens,company_stamps,contract_files,permissions,role_permissions}.sql ·
--   db/functions/ 上面那十九支 · db/views/zzz_change_log_triggers.sql · db/storage/buckets-and-policies.sql · db/seeds/{eleven,seven}-roles-2026-10-30.sql。
-- 运行期配置的表:本刀一张都没碰。
BEGIN;

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

COMMIT;
