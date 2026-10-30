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
