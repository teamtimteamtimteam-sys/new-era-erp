-- db/migrations/2026-10-06-mes1-entry-point.sql
-- MES-1 —— 车间设备的数据入口(MES 组的第一刀,v1.4.37;发布那一行在 docs/handbacks/MES-1.md 的抬头)。
-- 由 db/scripts/build_mes1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-06:MES-1 Step 0 的 Q1–Q30 全部照建议裁定;MES-0 的 Q1–Q96 照旧成立)
--   ① 七张表:devices(设备与网关登记)· gateway_keys(网关钥匙,只存 sha256)· ingest_settings(传输上限,单行)·
--      ingest_data_classes(数据类字典,只经迁移改)· ingest_inbox(收件箱)· ingest_transmissions(传输日志与两种桶)·
--      gateway_outages(网关中断)。后三张只追加、不进变更记录(MES-0 Q14);前四张进变更记录,钥匙的哈希用 never 规则遮住(Q20)。
--   ② 一支给 anon 的函数:ingest_submit —— 网关唯一够得着的东西(MES-0 Q4)。只插入三份日志(两种桶的四个计数列除外),
--      一行设备都不改,不跑转换代码,只回调用者自己的序号与固定的码;authenticated 与 service_role 都调不到(Q4)。
--   ③ 员工那一侧:登记 / 停用设备、发 / 撤钥匙、改上限、处理收件箱、重试 / 丢弃(action.manage_devices;处理只要 module.processing.view,Q11)。
--   ④ 一个码:action.manage_devices → admin · cto(admin 拿到每一个新码 —— 常设裁定)。
--   ⑤ 单据种类 DEV(有洞,device_code_seq;Q28);document_type_exceptions 多一行 ingest_data_classes。
--   ⑥ 视图:gateway_keys_masked · gateway_health · ingest_sequence_gaps · ingest_transmission_anomalies · pending_values;
--      operations_now 多两支(gateway_silent · capture_inbox_failed),列契约一字未动。
--   ⑦ 变更记录:四张新表各两条绑定;三张日志表豁免(带理由);遮蔽规则多 never 一行;审计记录多两个主语(device · ingest_settings)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不写、不改任何一张既有单据。
--   唯一的数据写入:权限码一行与它的两条授权 · 单据种类一行 · 例外表一行 · 两张新表的种子(数据类九行、上限一行)。
--
-- 【破窗】一切都是新的,部署之前的旧应用一样东西都不读它们:operations_now 列不变,旧的提醒页按它自己的清单画牌子,
--   两支新臂被跳过、不印成键名;trail_subjects 等同签名原地替换。匿名函数从 COMMIT 起就在,但在新页面部署之前没有人发得出
--   一把钥匙,所以没有一台网关认证得过。预计窗口里什么都不坏。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权只多那两行;在途单据一张不少、一张不多;七个账号一个都没被停;
--   变更记录只在那几张种子表上动了;anon 能执行的【恰好】两支;ingest_submit 对 authenticated / service_role 关着;
--   那 44 条开着的读策略还是 44 条、没有一条落在新表上;变更记录覆盖与遮蔽零缺口;每一张在途单据仍有一个不是它当事人的决定人。
--   断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES1_PRE|approvals are expected ON';
    END IF;
    IF current_setting('server_version_num')::int < 130000 THEN
        RAISE EXCEPTION 'MES1_PRE|built-in sha256 / gen_random_uuid need PostgreSQL 13+ (Q5)';
    END IF;
    IF to_regclass('public.devices') IS NOT NULL OR to_regclass('public.ingest_inbox') IS NOT NULL
       OR to_regclass('public.gateway_keys') IS NOT NULL OR to_regprocedure('public.ingest_submit(text, text, jsonb)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES1_PRE|MES-1 objects already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code = 'action.manage_devices') OR EXISTS (SELECT 1 FROM document_types WHERE key = 'device') THEN
        RAISE EXCEPTION 'MES1_PRE|the code or the document type already exists';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM roles WHERE code = 'cto') OR NOT EXISTS (SELECT 1 FROM roles WHERE code = 'admin') THEN
        RAISE EXCEPTION 'MES1_PRE|roles admin and cto are expected';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 104 THEN
        RAISE EXCEPTION 'MES1_PRE|expected 104 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes1_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';
CREATE TEMP TABLE mes1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;

-- ── 1 · 一个码(镜像原样)与授权 —— admin 拿到每一个新码(常设裁定,2026-09-24);cto 是 MES-0 Q90 点名的持有人。幂等。──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.manage_devices', 'action', 'Manage devices and gateway keys', '管理设备与网关钥匙', 'Register devices and gateways, retire them, issue and revoke gateway keys (each secret is shown once), retry or discard rows in the data inbox, and change the ingestion limits. Reading devices, the inbox and the transmission log needs only Processing (view).', '登记设备与网关、停用它们、发放与撤销网关钥匙(每一把密钥只显示一次)、重试或丢弃数据收件箱里的行,以及修改采集层的传输上限。读设备、收件箱与传输日志只要「加工(查看)」。', 1220);

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, 'action.manage_devices' FROM roles r WHERE r.code IN ('admin', 'cto')
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 2 · 触发器函数(镜像原样)—— 表上的触发器要先有它们 ──────────────────────────

-- db/functions/generate_device_code.sql
-- MES-1(2026-10-06,Q28):设备编号 DEV-YYYY-NNNN —— 有洞(nextval 回滚不还号),保存时生成。
-- 形状与 generate_task_code 逐字同一个(前缀经 document_type_prefix('device') 读,年取 NOW(),四位补零);
-- 只填空的 code。不是 SECURITY DEFINER:它是 devices 的 BEFORE INSERT 触发器,插入只经 save_device。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.generate_device_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := document_type_prefix('device') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('device_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_devices_write.sql
-- MES-1(2026-10-06):设备登记的守卫。
--   ① DELETE 一律拒(DEVICE_NEVER_DELETED)—— 收件箱、传输日志与网关钥匙指着它;一台不用了的设备的去处是停用。
--      挂在【语句级】:没有 DELETE 策略时 authenticated 的 DELETE 在 RLS 那里就是零行,行级触发器不会醒(U1-B 的那一课)。
--   ② 编号与种类定下就不动(DEVICE_CODE_FIXED · DEVICE_KIND_FIXED)—— 一台网关的钥匙、一台秤送来的消息都按它们认。
--   ③ 停用之后冻住(DEVICE_RETIRED|<编号>)。停用本身那一次 UPDATE(OLD.retired_at 为空)照常过。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.guard_devices_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'DEVICE_NEVER_DELETED';
    END IF;
    IF OLD.retired_at IS NOT NULL THEN
        RAISE EXCEPTION 'DEVICE_RETIRED|%', OLD.code;
    END IF;
    IF NEW.code IS DISTINCT FROM OLD.code THEN
        RAISE EXCEPTION 'DEVICE_CODE_FIXED|%', OLD.code;
    END IF;
    IF NEW.kind IS DISTINCT FROM OLD.kind THEN
        RAISE EXCEPTION 'DEVICE_KIND_FIXED|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_gateway_keys_write.sql
-- MES-1(2026-10-06,MES-0 Q5):网关钥匙的守卫。
--   ① 插入:那台设备必须是一台没停用的网关(GATEWAY_KEY_NOT_A_GATEWAY · GATEWAY_KEY_GATEWAY_RETIRED);
--      同一台网关已经有两把有效钥匙就拒第三把(GATEWAY_KEY_TWO_ACTIVE)—— 两把才能不停线地轮换,三把没有理由。
--   ② 更新:只许【撤销】,而且只撤一次 —— 撤销的三列从空到有;其余每一列(含哈希)一个字都不改
--      (GATEWAY_KEY_ONLY_REVOKE · GATEWAY_KEY_ALREADY_REVOKED)。撤了的钥匙不能复活。
--   ③ DELETE 一律拒(GATEWAY_KEY_NEVER_DELETED),语句级 —— 零行也触发。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.guard_gateway_keys_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_kind    text;
    v_retired timestamptz;
    v_code    text;
    v_n       integer;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'GATEWAY_KEY_NEVER_DELETED';
    END IF;
    IF TG_OP = 'INSERT' THEN
        SELECT d.kind, d.retired_at, d.code INTO v_kind, v_retired, v_code FROM devices d WHERE d.id = NEW.gateway_id;
        IF v_kind IS DISTINCT FROM 'gateway' THEN
            RAISE EXCEPTION 'GATEWAY_KEY_NOT_A_GATEWAY|%', COALESCE(v_code, '?');
        END IF;
        IF v_retired IS NOT NULL THEN
            RAISE EXCEPTION 'GATEWAY_KEY_GATEWAY_RETIRED|%', v_code;
        END IF;
        IF NEW.revoked_at IS NOT NULL THEN
            RAISE EXCEPTION 'GATEWAY_KEY_ONLY_REVOKE';
        END IF;
        SELECT count(*) INTO v_n FROM gateway_keys k WHERE k.gateway_id = NEW.gateway_id AND k.revoked_at IS NULL;
        IF v_n >= 2 THEN
            RAISE EXCEPTION 'GATEWAY_KEY_TWO_ACTIVE|%', v_code;
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.revoked_at IS NOT NULL THEN
        RAISE EXCEPTION 'GATEWAY_KEY_ALREADY_REVOKED|%', OLD.key_prefix;
    END IF;
    IF (to_jsonb(NEW) - 'revoked_at' - 'revoked_by' - 'revoke_reason')
       IS DISTINCT FROM (to_jsonb(OLD) - 'revoked_at' - 'revoked_by' - 'revoke_reason') THEN
        RAISE EXCEPTION 'GATEWAY_KEY_ONLY_REVOKE';
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_ingest_transmissions_write.sql
-- MES-1(2026-10-06,MES-1 Step 0 Q7 · Q8,Tim):传输日志只追加 —— 唯一的例外是两种桶的四个计数列,而且只经 ingest_submit。
--   ① DELETE / TRUNCATE 一律拒(INGEST_LOG_APPEND_ONLY|ingest_transmissions|<操作>),语句级。
--   ② 一次调用的那一行(kind = call)定下就不改。
--   ③ 桶(heartbeat_hour · rejected_overflow):只有 bucket_count · bucket_bytes · bucket_last_at · bucket_first_at 会变;
--      count / bytes / last_at 只许变大或不变,first_at 只许变小或不变(INGEST_BUCKET_ONLY_GROWS);
--      而且只在 ingest_submit 自己设的那个事务级标记下(INGEST_BUCKET_THROUGH_FUNCTION_ONLY)。
--      标记是事务内的 set_config(…, true),由函数在那一句 upsert 前后设与清 —— 别的路径(哪怕是属主手写一句 UPDATE)都碰不到。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.guard_ingest_transmissions_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'INGEST_LOG_APPEND_ONLY|ingest_transmissions|%', lower(TG_OP);
    END IF;
    IF OLD.kind = 'call' THEN
        RAISE EXCEPTION 'INGEST_LOG_APPEND_ONLY|ingest_transmissions|update';
    END IF;
    IF COALESCE(current_setting('evoltrya.ingest_ctx', true), '') <> 'ingest_submit' THEN
        RAISE EXCEPTION 'INGEST_BUCKET_THROUGH_FUNCTION_ONLY';
    END IF;
    IF (to_jsonb(NEW) - 'bucket_count' - 'bucket_bytes' - 'bucket_first_at' - 'bucket_last_at')
       IS DISTINCT FROM (to_jsonb(OLD) - 'bucket_count' - 'bucket_bytes' - 'bucket_first_at' - 'bucket_last_at')
       OR NEW.bucket_count < OLD.bucket_count
       OR NEW.bucket_bytes < OLD.bucket_bytes
       OR NEW.bucket_last_at < OLD.bucket_last_at
       OR NEW.bucket_first_at > OLD.bucket_first_at THEN
        RAISE EXCEPTION 'INGEST_BUCKET_ONLY_GROWS';
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_ingest_inbox_write.sql
-- MES-1(2026-10-06,规格 §6.4;MES-1 Step 0 Q11 · Q15,Tim):收件箱只追加 —— 唯一会变的是【转换】那几列。
--   ① DELETE / TRUNCATE 一律拒(INGEST_LOG_APPEND_ONLY|ingest_inbox|<操作>),语句级。规格 §6.4:失败的转换不丢。
--   ② 转换成功或丢弃之后冻住(INBOX_ROW_FROZEN|<id>)。
--   ③ 只有 status · transformed_with · transform_result · error_code · attempts · last_attempt_at · last_attempt_by ·
--      discarded_at · discarded_by · discard_reason 会变;网关送来的那些(网关、流、序号、设备、类、payload、哈希、现场时间、
--      收到时刻)一个字都不改(INBOX_ONLY_STATUS_CHANGES)。
--   ④ 而且只在处理 / 重试 / 丢弃那三支函数设的事务级标记下(INBOX_THROUGH_FUNCTION_ONLY)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.guard_ingest_inbox_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'INGEST_LOG_APPEND_ONLY|ingest_inbox|%', lower(TG_OP);
    END IF;
    IF OLD.status IN ('transformed', 'discarded') THEN
        RAISE EXCEPTION 'INBOX_ROW_FROZEN|%', OLD.id;
    END IF;
    IF COALESCE(current_setting('evoltrya.ingest_ctx', true), '') <> 'inbox_process' THEN
        RAISE EXCEPTION 'INBOX_THROUGH_FUNCTION_ONLY';
    END IF;
    IF (to_jsonb(NEW) - 'status' - 'transformed_with' - 'transform_result' - 'error_code' - 'attempts'
                      - 'last_attempt_at' - 'last_attempt_by' - 'discarded_at' - 'discarded_by' - 'discard_reason')
       IS DISTINCT FROM
       (to_jsonb(OLD) - 'status' - 'transformed_with' - 'transform_result' - 'error_code' - 'attempts'
                      - 'last_attempt_at' - 'last_attempt_by' - 'discarded_at' - 'discarded_by' - 'discard_reason') THEN
        RAISE EXCEPTION 'INBOX_ONLY_STATUS_CHANGES|%', OLD.id;
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_gateway_outages_append_only.sql
-- MES-1(2026-10-06):网关中断只追加 —— 一段过去的沉默记下了就不改、不删(INGEST_LOG_APPEND_ONLY|gateway_outages|<操作>)。
-- 语句级:UPDATE / DELETE / TRUNCATE 不论命中几行都按名拒(零行也触发)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.guard_gateway_outages_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'INGEST_LOG_APPEND_ONLY|gateway_outages|%', lower(TG_OP);
END;
$function$;

-- ── 3 · 七张表(镜像原样:表 · 种子 · 触发器 · RLS · 授权)────────────────────────

-- db/tables/ingest_data_classes.sql
-- MES-1(2026-10-06,MES-0 §3.2 · §3.5;MES-1 Step 0 Q3 · Q12,Tim):采集层的【数据类】字典。
--
-- 【一类数据 = 一行】一台设备送来的每一条消息都声明它是哪一类(weighing · discharge_module · …);
--   这一行说的是:这一类由哪一支转换函数验证并规整(transform_function),以及它最终落到哪一种正式记录(target_en,给人读的)。
-- 【transform_function 为空 = 还没有转换器】这一类的消息照收,停在收件箱里,状态 awaiting_transform,看得见、不丢
--   (MES-0 §3.2:目标还没建的类)。MES-1 只给 connection_test 一支转换器 —— 它证明分派、成功、失败、重试与丢弃;
--   其余八类各由它的刀接上(称重 MES-2 · 放电 MES-5a · 控制器与工位 MES-4a · 电表 MES-5a · 扫码 MES-3b · 在线质量 MES-6a ·
--   安全报警 MES-7b)。
-- 【INSTALL SEED,只经迁移改】(Q12)这一行【点名一支会按名字被执行的函数】,所以它不是运营改得动的配置:
--   没有写策略;check_mirrors 逐行比对(SEED_TABLES)。transform_function 的形状由 CHECK 钉成
--   transform_<类>_v<版本> —— 分派器只认 public.<这个名字>(jsonb)。一次格式改动 = 一支 _v<n+1> + 一次迁移(规格 §6.4)。
-- 【manual_entry_code】手工录入这一类要持的码。MES-1 全部为空:手工录入的整条路在 MES-2(Q14)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.ingest_data_classes (
    code               text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$'),
    name_en            text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh            text NOT NULL CHECK (btrim(name_zh) <> ''),
    target_en          text NOT NULL CHECK (btrim(target_en) <> ''),
    transform_function text CHECK (transform_function ~ '^transform_[a-z0-9_]+_v[0-9]+$'),
    manual_entry_code  text REFERENCES public.permissions (code),
    is_active          boolean NOT NULL DEFAULT true,
    sort_order         integer NOT NULL
);

COMMENT ON TABLE public.ingest_data_classes IS
    'MES-1:采集层的数据类字典(INSTALL SEED,只经迁移改)。每一条进来的消息声明它属于哪一类;transform_function 点名验证并规整它的那一支函数 public.<名>(jsonb),为空 = 这一类还没有转换器,消息停在收件箱里(awaiting_transform)。MES-1 只有 connection_test 一支转换器;其余八类各由它的刀接上。';
COMMENT ON COLUMN public.ingest_data_classes.transform_function IS
    '转换函数的名字(不带参数):分派器调 public.<名>(jsonb)。形状由 CHECK 钉成 transform_<类>_v<版本>。为空 = 还没有转换器。';

INSERT INTO public.ingest_data_classes (code, name_en, name_zh, target_en, transform_function, manual_entry_code, is_active, sort_order) VALUES
    ('connection_test', 'Connection test', '连通测试', 'No record: proves that a device reaches the system end to end', 'transform_connection_test_v1', NULL, true, 10),
    ('weighing', 'Weighing', '称重', 'Weighing records (MES-2)', NULL, NULL, true, 20),
    ('discharge_module', 'Discharge result per module', '逐模组放电结果', 'Per-module discharge results (MES-5a)', NULL, NULL, true, 30),
    ('controller_summary', 'Controller batch summary', '控制器批次汇总', 'Processing-run values (MES-4a)', NULL, NULL, true, 40),
    ('meter_reading', 'Meter reading', '电表读数', 'Meter readings (MES-5a)', NULL, NULL, true, 50),
    ('workstation_event', 'Workstation event', '工位事件', 'Processing-run events (MES-4a)', NULL, NULL, true, 60),
    ('scan', 'Scan', '扫码', 'Scan events (MES-3b)', NULL, NULL, true, 70),
    ('inline_quality', 'Inline quality reading', '在线质量读数', 'Assay indicators (MES-6a)', NULL, NULL, true, 80),
    ('safety_alarm', 'Safety alarm', '安全报警', 'Incidents (MES-7b)', NULL, NULL, true, 90);

ALTER TABLE public.ingest_data_classes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ingest_data_classes select by permission" ON public.ingest_data_classes
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.ingest_data_classes FROM anon;

-- db/tables/devices.sql
-- MES-1(2026-10-06,MES-0 §3.2 · §5.2;MES-1 Step 0,Tim):【设备登记】—— 每一个物理数据源,网关也在内。
--
-- 【一台设备 = 一行】秤、地磅、放电柜、控制器、电表、工位终端、扫码枪、在线仪表、报警盘,以及把它们的数据带进来的
--   【网关】(kind = 'gateway')。一台非网关设备由哪一台网关带着,写在 gateway_id;网关只接受它自己带着的设备的消息
--   (DEVICE_NOT_ON_THIS_GATEWAY,Q6)。
-- 【编号】DEV-YYYY-NNNN,有洞(nextval,回滚不还号),保存时生成(Q28);人读的名字是另一列 name。
--   前缀住在 document_types(key 'device'),铸码只经 document_type_prefix('device') —— 与 task 同一个形状。
-- 【机器】equipment_id 指一张资产卡(fixed_assets)。那张表只给财务读,所以加工的读者经 equipment_usage 读它的标签(Q29)。
-- 【采购合同里的六条数据接口条款】(规格 §8.1)各一列:not_confirmed(默认,页面写 "Not yet confirmed")·
--   confirmed · not_offered(厂商不给)。它们是登记,不是闸。
-- 【心跳间隔】只有网关有;为空 = "Not yet set — silence cannot be judged"(V5,集成商在网关调试时给,Q17)。
-- 【没有"最后一次听到"这一类列】(Q7)最后一次调用、最后一次心跳、每一条流最大的序号,都在读的时候从
--   ingest_transmissions / ingest_inbox 推出来。本表记在变更记录里,一列每次心跳都改的列会让变更记录每分钟多一行 ——
--   而 Q14 排除那三张日志表正是为了不要那个量。于是网关那一次匿名调用【一行都不改】本表。
-- 【写】只经 SECURITY DEFINER 函数(save_device · retire_device,action.manage_devices);没有写策略。
--   停用(retired_at)不删:收件箱与传输日志指着它;删一台设备要先有它从来没送过数据 —— 不提供,停用就是它的去处。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.
-- First-run script (plain CREATEs).

CREATE SEQUENCE public.device_code_seq;

CREATE TABLE public.devices (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                     text NOT NULL UNIQUE,
    name                     text NOT NULL CHECK (btrim(name) <> ''),
    kind                     text NOT NULL
        CHECK (kind IN ('gateway', 'scale', 'weighbridge', 'discharge_cabinet', 'controller', 'meter',
                        'workstation', 'scanner', 'inline_instrument', 'alarm_panel')),
    gateway_id               uuid REFERENCES public.devices (id),
    data_class               text REFERENCES public.ingest_data_classes (code),
    equipment_id             uuid REFERENCES public.fixed_assets (id),
    station                  text,
    capacity                 numeric CHECK (capacity > 0),
    resolution               numeric CHECK (resolution > 0),
    unit                     text,
    protection_rating        text,
    interface_status         text NOT NULL DEFAULT 'reserved'
        CHECK (interface_status IN ('reserved', 'manual_only', 'connected')),
    term_protocol            text NOT NULL DEFAULT 'not_confirmed'
        CHECK (term_protocol IN ('not_confirmed', 'confirmed', 'not_offered')),
    term_point_list          text NOT NULL DEFAULT 'not_confirmed'
        CHECK (term_point_list IN ('not_confirmed', 'confirmed', 'not_offered')),
    term_timestamp_precision text NOT NULL DEFAULT 'not_confirmed'
        CHECK (term_timestamp_precision IN ('not_confirmed', 'confirmed', 'not_offered')),
    term_no_charge           text NOT NULL DEFAULT 'not_confirmed'
        CHECK (term_no_charge IN ('not_confirmed', 'confirmed', 'not_offered')),
    term_retention_export    text NOT NULL DEFAULT 'not_confirmed'
        CHECK (term_retention_export IN ('not_confirmed', 'confirmed', 'not_offered')),
    term_documentation       text NOT NULL DEFAULT 'not_confirmed'
        CHECK (term_documentation IN ('not_confirmed', 'confirmed', 'not_offered')),
    heartbeat_interval_s     integer CHECK (heartbeat_interval_s > 0),
    notes                    text,
    retired_at               timestamptz,
    retired_by               uuid,
    retire_reason            text,
    created_at               timestamptz NOT NULL DEFAULT now(),
    created_by               uuid DEFAULT auth.uid(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    updated_by               uuid DEFAULT auth.uid(),
    -- 网关不被别的网关带着,也不声明数据类(它带的设备才声明)
    CONSTRAINT devices_gateway_shape
        CHECK (kind <> 'gateway' OR (gateway_id IS NULL AND data_class IS NULL)),
    -- 心跳间隔只属于网关
    CONSTRAINT devices_heartbeat_gateway_only
        CHECK (kind = 'gateway' OR heartbeat_interval_s IS NULL),
    CONSTRAINT devices_not_own_gateway
        CHECK (gateway_id IS DISTINCT FROM id),
    CONSTRAINT devices_retired_shape
        CHECK ((retired_at IS NULL AND retired_by IS NULL AND retire_reason IS NULL)
            OR (retired_at IS NOT NULL AND btrim(COALESCE(retire_reason, '')) <> ''))
);

COMMENT ON TABLE public.devices IS
    'MES-1:设备登记 —— 每一个物理数据源(秤、地磅、放电柜、控制器、电表、工位终端、扫码枪、在线仪表、报警盘)与把它们的数据带进来的网关(kind = gateway)。编号 DEV-YYYY-NNNN 保存时生成;人读的名字是 name。网关只接受它自己带着的设备(gateway_id)的消息。六条采购合同的数据接口条款各一列(not_confirmed / confirmed / not_offered)。心跳间隔只有网关有,为空 = 还没给(V5)。最后一次听到网关的时刻不存在这里,读的时候从传输日志推出来 —— 网关的匿名调用一行都不改本表。写只经 save_device / retire_device(action.manage_devices);停用,不删。';
COMMENT ON COLUMN public.devices.heartbeat_interval_s IS
    '网关的心跳间隔(秒)。为空 = Not yet set:沉默无从判断,不记中断、不上提醒(Q17)。由集成商在网关调试时给(V5)。';
COMMENT ON COLUMN public.devices.interface_status IS
    'reserved:接口还没接上(默认);manual_only:这台设备永远手工录;connected:网关在送它的数据。';

CREATE INDEX devices_gateway_id ON public.devices (gateway_id);
CREATE INDEX devices_code_trgm ON public.devices USING gin (code extensions.gin_trgm_ops);

CREATE TRIGGER trg_generate_device_code
    BEFORE INSERT ON public.devices
    FOR EACH ROW EXECUTE FUNCTION public.generate_device_code();

CREATE TRIGGER trg_devices_updated_at
    BEFORE UPDATE ON public.devices
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- 编号与种类定下就不动;停用的那一行冻住;任何人都删不掉(语句级 —— 零行也触发,U1-B 的那一课)。
CREATE TRIGGER trg_devices_write
    BEFORE UPDATE ON public.devices
    FOR EACH ROW EXECUTE FUNCTION public.guard_devices_write();
CREATE TRIGGER trg_devices_no_delete
    BEFORE DELETE ON public.devices
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_devices_write();

ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;

-- 读:持加工查看码的人(MES-0 §3.10)。写只经函数。
CREATE POLICY "devices select by permission" ON public.devices
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.devices FROM anon;

-- db/tables/gateway_keys.sql
-- MES-1(2026-10-06,MES-0 Q5 · §3.4;MES-1 Step 0 Q5 · Q20,Tim):【网关钥匙】—— 每一台网关自己的、可单独撤销的密钥。
--
-- 【只存哈希】密钥本身在发放那一刻显示一次(issue_gateway_key 的返回值),之后哪里都没有它:这里存的是
--   key_hash = sha256(密钥)(PostgreSQL 内建的 sha256 —— Q5:不用 pgcrypto,线上 17.6 实测)与 key_prefix(密钥里
--   'ngk_' 之后的 8 个十六进制字符,页面显示 "ngk_1a2b3c4d…",认得出是哪一把,推不出整把)。
-- 【哈希谁都看不见】(Q20)key_hash 不在给 authenticated 的列授权里;gateway_keys_masked 里它恒为空
--   (CASE WHEN false);变更记录用 never 规则遮它 —— 任何读者、任何页面、任何一份记录都不给。
--   它推不出密钥(sha256 · 244 位随机),藏它是卫生,不是唯一的锁。
-- 【一台网关同一时刻最多两把有效】(Q5)两把才能【不停线】轮换:发第二把 → 网关换上 → 撤第一把。第三把按名拒
--   (GATEWAY_KEY_TWO_ACTIVE)。
-- 【撤销】下一次调用就生效 —— ingest_submit 每一次都现查。撤销只写一次(撤了的不能再撤、不能复活);任何人都删不掉一行。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.gateway_keys (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    gateway_id    uuid NOT NULL REFERENCES public.devices (id),
    key_prefix    text NOT NULL CHECK (key_prefix ~ '^[0-9a-f]{8}$'),
    key_hash      bytea NOT NULL UNIQUE CHECK (octet_length(key_hash) = 32),
    issued_at     timestamptz NOT NULL DEFAULT now(),
    issued_by     uuid,
    revoked_at    timestamptz,
    revoked_by    uuid,
    revoke_reason text,
    CONSTRAINT gateway_keys_revoked_shape
        CHECK ((revoked_at IS NULL AND revoked_by IS NULL AND revoke_reason IS NULL)
            OR (revoked_at IS NOT NULL AND btrim(COALESCE(revoke_reason, '')) <> ''))
);

COMMENT ON TABLE public.gateway_keys IS
    'MES-1:网关钥匙。每一台网关自己的密钥,只存 sha256 哈希与 8 个字符的前缀;密钥在发放那一刻显示一次。哈希谁都看不见(列授权里没有它,gateway_keys_masked 恒为空,变更记录 never 规则)。一台网关同一时刻最多两把有效,好让轮换不停线。撤销在下一次调用生效;不能复活、不能删。';
COMMENT ON COLUMN public.gateway_keys.key_hash IS
    'sha256(密钥 UTF-8 字节)。谁都看不见 —— 不在列授权里,遮蔽视图里恒为空,变更记录 never 规则(Q20)。';

CREATE INDEX gateway_keys_gateway_active ON public.gateway_keys (gateway_id) WHERE revoked_at IS NULL;

-- 最多两把有效 · 只能撤一次 · 撤销之外一个字都不改 · 任何人都删不掉(语句级 —— 零行也触发)。
CREATE TRIGGER trg_gateway_keys_write
    BEFORE INSERT OR UPDATE ON public.gateway_keys
    FOR EACH ROW EXECUTE FUNCTION public.guard_gateway_keys_write();
CREATE TRIGGER trg_gateway_keys_no_delete
    BEFORE DELETE ON public.gateway_keys
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_gateway_keys_write();

ALTER TABLE public.gateway_keys ENABLE ROW LEVEL SECURITY;

CREATE POLICY "gateway_keys select by permission" ON public.gateway_keys
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.gateway_keys FROM anon;
-- 【遮蔽:列授权】key_hash 不给任何人(AGENTS.md 遮蔽表三件事:列授权 · _masked 视图 · 变更记录规则,一支迁移)。
REVOKE SELECT ON public.gateway_keys FROM authenticated;
GRANT SELECT (id, gateway_id, key_prefix, issued_at, issued_by, revoked_at, revoked_by, revoke_reason)
    ON public.gateway_keys TO authenticated;

-- db/tables/ingest_settings.sql
-- MES-1(2026-10-06,MES-0 Q7 · V32;MES-1 Step 0 Q9 · Q13 · Q22,Tim):采集层的【传输上限】—— 单行配置。
--
-- 【这些是传输上限,不是业务标准】(MES-0 Q7)它们保护的是日志与库,不是任何一道工艺:
--   fail_budget / fail_window_s    一个【报上来的网关编号】滚动 10 分钟里 30 次失败调用 —— 之后它的失败不再一行一行记,
--                                  计进 10 分钟一行的溢出桶(Q9)。持【有效钥匙】的调用永远不受它限(Q9)。
--   global_reject_budget           全部失败调用滚动 10 分钟里 300 次的总闸 —— 防的是轮换编造的编号把日志写满(Q9)。
--   max_payload_bytes · max_messages  每次调用 256 KB、500 条消息。
--   clock_ahead_s                  一条消息的 site_to 比服务器收到它的时刻晚这么多秒以上,就标 "clock ahead"(Q13,5 分钟)。
-- 【RUNTIME CONFIG】持 action.manage_devices 的人在设备页上改(set_ingest_settings);引导值就是 Q7 / Q9 / Q13 裁定的那几个数,
--   线上被改过就与本文件不同 —— 那是系统在正常工作。修改史 = 变更记录 + 审计记录主语 ingest_settings(Q22),没有另一张历史表。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.ingest_settings (
    id                   boolean PRIMARY KEY DEFAULT true CHECK (id),
    fail_budget          integer NOT NULL DEFAULT 30 CHECK (fail_budget > 0),
    fail_window_s        integer NOT NULL DEFAULT 600 CHECK (fail_window_s > 0),
    global_reject_budget integer NOT NULL DEFAULT 300 CHECK (global_reject_budget > 0),
    max_payload_bytes    integer NOT NULL DEFAULT 262144 CHECK (max_payload_bytes > 0),
    max_messages         integer NOT NULL DEFAULT 500 CHECK (max_messages > 0),
    clock_ahead_s        integer NOT NULL DEFAULT 300 CHECK (clock_ahead_s > 0),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    updated_by           uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.ingest_settings IS
    'MES-1:采集层的传输上限(单行)。每个报上来的网关编号滚动窗口里的失败次数(30 / 600 秒)、全部失败调用的总闸(300)、每次调用的字节与消息上限(256 KB / 500)、"时钟超前"的判据(300 秒)。它们保护日志与库,不是业务标准;持有效钥匙的调用永远不受失败预算限。由 action.manage_devices 经 set_ingest_settings 修改;修改史在变更记录里。';

INSERT INTO public.ingest_settings (id) VALUES (true);

CREATE TRIGGER trg_ingest_settings_updated_at
    BEFORE UPDATE ON public.ingest_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.ingest_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ingest_settings select by permission" ON public.ingest_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.ingest_settings FROM anon;

-- db/tables/ingest_transmissions.sql
-- MES-1(2026-10-06,规格 §7「Logged」;MES-0 Q6 · Q7 · Q18;MES-1 Step 0 Q7 · Q8 · Q9 · Q18,Tim):【传输日志】。
--
-- 【三种行】
--   call               一次数据调用一行,接受的与拒绝的都记(哪一台网关报的编号、钥匙前缀、字节、消息数、几条收下 / 重复 / 退回、
--                      退回的每一条为什么、调用方报上来的地址)。
--   heartbeat_hour     一台网关一小时一行:那一小时的心跳次数、字节、第一次与最后一次(Q8)。每次心跳只让这四列往上长
--                      (count / bytes / last_at 只增,first_at 只减或不变),而且只经 ingest_submit —— 守卫按名拒别的写法。
--   rejected_overflow  失败太多时的溢出桶,10 分钟一行(Q9):一个报上来的编号滚动窗口里失败到预算(30),或全部失败调用到总闸(300),
--                      之后的失败不再一行一行记,只在这一行上计数 —— 编造编号的探测写不满这张表。
-- 【只追加】除了那两种桶的四个计数列,任何一行定下就不改;任何人都删不掉(语句级 —— 零行也触发)。
-- 【不进变更记录】(MES-0 Q14,Tim)它本身就是一份只追加的日志,再记一遍是把规格 §2.1 警告的量翻一倍,而不多一个事实。
-- 【调用方地址】(Q18)PostgREST 交过来的转发链原样存下,页面标 "reported address (not verified)";拿不到就是 'not available'。
--   X-Forwarded-For 调用方自己写得了,所以它是一条线索,不是一项证明。
-- 【读】持加工查看码的人;写只经 ingest_submit(SECURITY DEFINER)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.ingest_transmissions (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind                 text NOT NULL CHECK (kind IN ('call', 'heartbeat_hour', 'rejected_overflow')),
    received_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    presented_gateway    text CHECK (char_length(presented_gateway) <= 64),
    gateway_id           uuid REFERENCES public.devices (id),
    presented_key_prefix text CHECK (presented_key_prefix ~ '^[0-9a-f]{8}$'),
    result               text CHECK (result IN ('accepted', 'unknown_gateway', 'bad_key', 'revoked_key', 'retired_gateway',
                                                'too_large', 'too_many', 'malformed')),
    bytes                integer CHECK (bytes >= 0),
    message_count        integer CHECK (message_count >= 0),
    accepted_count       integer CHECK (accepted_count >= 0),
    duplicate_count      integer CHECK (duplicate_count >= 0),
    rejected_count       integer CHECK (rejected_count >= 0),
    stream               text,
    first_seq            bigint,
    last_seq             bigint,
    rejections           jsonb,
    client_address       text NOT NULL DEFAULT 'not available' CHECK (char_length(client_address) <= 200),
    bucket_start         timestamptz,
    bucket_count         integer CHECK (bucket_count > 0),
    bucket_bytes         bigint CHECK (bucket_bytes >= 0),
    bucket_first_at      timestamptz,
    bucket_last_at       timestamptz,
    CONSTRAINT ingest_transmissions_call_shape
        CHECK (kind <> 'call' OR (result IS NOT NULL AND bytes IS NOT NULL AND bucket_start IS NULL AND bucket_count IS NULL
                                  AND bucket_bytes IS NULL AND bucket_first_at IS NULL AND bucket_last_at IS NULL)),
    CONSTRAINT ingest_transmissions_bucket_shape
        CHECK (kind = 'call' OR (result IS NULL AND bucket_start IS NOT NULL AND bucket_count IS NOT NULL
                                 AND bucket_bytes IS NOT NULL AND bucket_first_at IS NOT NULL AND bucket_last_at IS NOT NULL
                                 AND bucket_first_at <= bucket_last_at)),
    CONSTRAINT ingest_transmissions_heartbeat_has_gateway
        CHECK (kind <> 'heartbeat_hour' OR gateway_id IS NOT NULL),
    CONSTRAINT ingest_transmissions_overflow_has_no_gateway
        CHECK (kind <> 'rejected_overflow' OR gateway_id IS NULL),
    CONSTRAINT ingest_transmissions_accepted_has_gateway
        CHECK (result IS DISTINCT FROM 'accepted' OR gateway_id IS NOT NULL)
);

COMMENT ON TABLE public.ingest_transmissions IS
    'MES-1:传输日志。call = 一次数据调用一行(接受的与拒绝的都记);heartbeat_hour = 一台网关一小时一行的心跳计数(Q8);rejected_overflow = 失败到预算之后 10 分钟一行的溢出计数(Q9)。只追加:除了两种桶的四个计数列,一行定下就不改,任何人都删不掉。不进变更记录(MES-0 Q14)。调用方地址原样存下,未经核实(Q18)。写只经 ingest_submit。';
COMMENT ON COLUMN public.ingest_transmissions.client_address IS
    'PostgREST 交过来的转发链(X-Forwarded-For),原样;调用方自己写得了,页面标 "reported address (not verified)"。拿不到就是 not available(Q18)。';

CREATE UNIQUE INDEX ingest_transmissions_heartbeat_hour
    ON public.ingest_transmissions (gateway_id, bucket_start) WHERE kind = 'heartbeat_hour';
CREATE UNIQUE INDEX ingest_transmissions_overflow_window
    ON public.ingest_transmissions (bucket_start) WHERE kind = 'rejected_overflow';
-- 失败预算的两次计数(按报上来的编号 / 全部)与"最后一次听到"(接受的调用)各一条
CREATE INDEX ingest_transmissions_failures_by_code
    ON public.ingest_transmissions (presented_gateway, received_at) WHERE kind = 'call' AND result <> 'accepted';
CREATE INDEX ingest_transmissions_failures
    ON public.ingest_transmissions (received_at) WHERE kind = 'call' AND result <> 'accepted';
CREATE INDEX ingest_transmissions_accepted_by_gateway
    ON public.ingest_transmissions (gateway_id, received_at) WHERE kind = 'call' AND result = 'accepted';

CREATE TRIGGER trg_ingest_transmissions_write
    BEFORE UPDATE ON public.ingest_transmissions
    FOR EACH ROW EXECUTE FUNCTION public.guard_ingest_transmissions_write();
CREATE TRIGGER trg_ingest_transmissions_no_delete
    BEFORE DELETE OR TRUNCATE ON public.ingest_transmissions
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_ingest_transmissions_write();

ALTER TABLE public.ingest_transmissions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ingest_transmissions select by permission" ON public.ingest_transmissions
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.ingest_transmissions FROM anon;

-- db/tables/ingest_inbox.sql
-- MES-1(2026-10-06,规格 §6.4;MES-0 §3.2 · §3.5 · Q15;MES-1 Step 0 Q11 · Q13 · Q14 · Q15,Tim):【数据收件箱】—— 规格说的"落地表"。
--
-- 【网关不写业务表】(规格 §6.4)一条被收下的消息在这里落一行;ERP 这边的代码验证并规整它(转换),之后才有正式记录(MES-2 起)。
-- 【只收下,不转换】(Q11)网关那一次匿名调用只插入,状态 received;转换只在员工的会话里跑(ingest_process_pending,
--   收件箱页上的 "Process received" 按钮,持加工查看码的人)。于是从外面够得着的那一支函数里没有一行转换代码。
-- 【身份】(Q13)一条设备消息由 (网关, 流, 序号) 认:网关每次启动生成一个新的流 id,序号在一条流里递增。同一个三元组再来一次:
--   payload 哈希相同 = 重复,回 duplicates、不再落行;不同 = SEQ_REUSED,退回、不落行(那一次在传输日志里有记录)。
--   缺号不挡任何东西(MES-0 Q8),由 ingest_sequence_gaps 按流列出来。
-- 【信封错与内容错】(Q15)信封错(没有序号、不认识的类、不是这台网关的设备……)退回、不落行;内容错照收,在转换时失败,
--   看得见(status = failed + error_code),可以重试、可以带理由丢弃,永远不删。
-- 【手工录入走同一条路】(Q14)source = 'manual' ⇔ 没有网关、有录入人;整条手工路在 MES-2,本刀只建列与那条 CHECK。
-- 【只追加】一行定下之后只有转换的那几列会变(status · transformed_with · transform_result · error_code · attempts ·
--   last_attempt_*),丢弃的三列只写一次;转换成功或丢弃之后冻住;任何人都删不掉。规格 §6.4:失败的转换不丢。
-- 【保留】全部留着(MES-0 Q15)。
-- 【不进变更记录】(MES-0 Q14)它本身是一份只追加的日志;状态的变化记在行上(attempts · last_attempt_* · discarded_*)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.ingest_inbox (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transmission_id  bigint REFERENCES public.ingest_transmissions (id),
    source           text NOT NULL CHECK (source IN ('device', 'manual')),
    gateway_id       uuid REFERENCES public.devices (id),
    stream           text CHECK (char_length(stream) BETWEEN 1 AND 64),
    seq              bigint CHECK (seq >= 1),
    entered_by       uuid,
    device_id        uuid REFERENCES public.devices (id),
    data_class       text NOT NULL REFERENCES public.ingest_data_classes (code),
    payload          jsonb NOT NULL,
    payload_bytes    integer NOT NULL CHECK (payload_bytes >= 0),
    payload_sha256   bytea NOT NULL CHECK (octet_length(payload_sha256) = 32),
    site_from        timestamptz,
    site_to          timestamptz,
    site_dataset_ref text,
    clock_ahead      boolean NOT NULL DEFAULT false,
    received_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    status           text NOT NULL DEFAULT 'received'
        CHECK (status IN ('received', 'transformed', 'failed', 'awaiting_transform', 'discarded')),
    transformed_with text,
    transform_result jsonb,
    error_code       text,
    attempts         integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    last_attempt_at  timestamptz,
    last_attempt_by  uuid,
    discarded_at     timestamptz,
    discarded_by     uuid,
    discard_reason   text,
    -- Q14:手工 ⇔ 没有网关、有录入人;设备消息有网关、流、序号、设备,没有录入人
    CONSTRAINT ingest_inbox_source_shape
        CHECK ((source = 'manual' AND gateway_id IS NULL AND stream IS NULL AND seq IS NULL AND entered_by IS NOT NULL)
            OR (source = 'device' AND gateway_id IS NOT NULL AND stream IS NOT NULL AND seq IS NOT NULL
                AND device_id IS NOT NULL AND entered_by IS NULL)),
    CONSTRAINT ingest_inbox_site_range
        CHECK (site_from IS NULL OR site_to IS NULL OR site_from <= site_to),
    -- 失败一定带码;丢弃的那一行留着它丢弃之前的那个码(为什么失败,丢了也还看得见)
    CONSTRAINT ingest_inbox_failed_has_code
        CHECK (status <> 'failed' OR error_code IS NOT NULL),
    CONSTRAINT ingest_inbox_transformed_shape
        CHECK ((status = 'transformed') = (transformed_with IS NOT NULL)),
    CONSTRAINT ingest_inbox_discarded_shape
        CHECK ((status = 'discarded') = (discarded_at IS NOT NULL)
               AND (discarded_at IS NULL OR btrim(COALESCE(discard_reason, '')) <> ''))
);

COMMENT ON TABLE public.ingest_inbox IS
    'MES-1:数据收件箱(规格 §6.4 的落地表)。网关的匿名调用只插入(status = received);转换只在员工会话里跑(ingest_process_pending)。一条设备消息由 (网关, 流, 序号) 认:同 payload 再来 = 重复,不同 = SEQ_REUSED 退回。信封错退回不落行;内容错照收,转换失败看得见(failed + error_code),可重试、可带理由丢弃,永远不删。source = manual ⇔ 没有网关、有录入人(手工路在 MES-2)。只追加:只有转换的那几列会变;成功或丢弃之后冻住。不进变更记录(MES-0 Q14)。';
COMMENT ON COLUMN public.ingest_inbox.clock_ahead IS
    'site_to 比服务器收到它的时刻晚 ingest_settings.clock_ahead_s 秒以上(Q13,5 分钟)—— 网关的时钟走快了。标记,不退回。';

CREATE UNIQUE INDEX ingest_inbox_identity ON public.ingest_inbox (gateway_id, stream, seq) WHERE source = 'device';
CREATE INDEX ingest_inbox_status ON public.ingest_inbox (status, id);
CREATE INDEX ingest_inbox_device ON public.ingest_inbox (device_id);
CREATE INDEX ingest_inbox_transmission ON public.ingest_inbox (transmission_id);

CREATE TRIGGER trg_ingest_inbox_write
    BEFORE UPDATE ON public.ingest_inbox
    FOR EACH ROW EXECUTE FUNCTION public.guard_ingest_inbox_write();
CREATE TRIGGER trg_ingest_inbox_no_delete
    BEFORE DELETE OR TRUNCATE ON public.ingest_inbox
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_ingest_inbox_write();

ALTER TABLE public.ingest_inbox ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ingest_inbox select by permission" ON public.ingest_inbox
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.ingest_inbox FROM anon;

-- db/tables/gateway_outages.sql
-- MES-1(2026-10-06,规格 §6.2;MES-0 Q9 · §3.8;MES-1 Step 0 Q17 · Q21,Tim):【网关中断】—— 过去的沉默,在网关回来那一刻记下。
--
-- 【没有调度器】(MES-0 §0 6)库里没有 pg_cron。所以"此刻在不在沉默"是读的时候算的(gateway_health);"那一段沉默"在网关
--   回来的那一次调用里写一行:上一次听到它的时刻 → 这一次,前提是两者之差超过了那台网关的心跳间隔。
--   间隔为空(Not yet set)就不记 —— 沉默无从判断,不发明一个数(Q17)。
-- 【一台坏了的网关与一台没事可报的网关分得开】没事可报的还在心跳;坏了的不心跳,回来时留下一行。
-- 【只追加,不进变更记录】(MES-0 Q14)。所以中断不在审计记录里 —— 设备页上自己一块列出来(Q21)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.gateway_outages (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gateway_id  uuid NOT NULL REFERENCES public.devices (id),
    silent_from timestamptz NOT NULL,
    silent_to   timestamptz NOT NULL,
    interval_s  integer NOT NULL CHECK (interval_s > 0),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT gateway_outages_range CHECK (silent_from < silent_to)
);

COMMENT ON TABLE public.gateway_outages IS
    'MES-1:网关中断。网关在一段超过它心跳间隔的沉默之后回来时,ingest_submit 记一行(上一次听到 → 这一次)。间隔没给就不记。只追加,不进变更记录(MES-0 Q14);设备页上自己一块列出来(Q21)。';

CREATE INDEX gateway_outages_gateway ON public.gateway_outages (gateway_id, silent_from);

CREATE TRIGGER trg_gateway_outages_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.gateway_outages
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_gateway_outages_append_only();

ALTER TABLE public.gateway_outages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "gateway_outages select by permission" ON public.gateway_outages
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.gateway_outages FROM anon;

-- ── 4 · 单据种类 DEV 与例外表一行(镜像原样)────────────────────────────────────
INSERT INTO public.document_types
    (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission)
VALUES
    ('device', 'DEV', 'devices', 'gapped', 'device_code_seq', '/operation/devices', 'detail', 'name', ARRAY['name', 'station', 'notes']::text[], ARRAY['module.processing.view']::text[]);
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
    ('ingest_data_classes',           '采集层的数据类目录(MES-1):code 是数据类代号,收件箱行与设备引用它')
ON CONFLICT (table_name) DO NOTHING;

-- ── 5 · 新函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/transform_connection_test_v1.sql
-- MES-1(2026-10-06,MES-1 Step 0 Q3 · Q12,Tim):【connection_test 这一类的转换器,第一版】—— 采集层唯一一支 MES-1 就有的转换器。
--   它证明分派、成功、失败、重试与丢弃,也让厂商在任何业务类存在之前就能从头到尾试一次(docs/integration/gateway-interface.md)。
--   payload 必须是 {"text": "<1–200 个字符>"};否则按名拒 CONNECTION_TEST_TEXT_REQUIRED —— 那一行进 failed,看得见。
--   成功的结果是 {"text": <去掉首尾空白的那段字>};它不落到任何正式记录(这一类没有目标)。
--   【只读它的参数】IMMUTABLE,不碰任何表 —— 一支转换器只做验证与规整;落正式记录是 MES-2 起的事。
--   不是 SECURITY DEFINER;EXECUTE 从 authenticated 收回(只经 ingest_transform_row 调)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.transform_connection_test_v1(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_text text;
BEGIN
    IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR jsonb_typeof(p_payload -> 'text') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'CONNECTION_TEST_TEXT_REQUIRED';
    END IF;
    v_text := btrim(p_payload ->> 'text');
    IF char_length(v_text) NOT BETWEEN 1 AND 200 THEN
        RAISE EXCEPTION 'CONNECTION_TEST_TEXT_REQUIRED';
    END IF;
    RETURN jsonb_build_object('text', v_text);
END;
$function$;

-- db/functions/ingest_transform_row.sql
-- MES-1(2026-10-06,规格 §6.4;MES-0 §3.5;MES-1 Step 0 Q11 · Q12 · Q15,Tim):【分派器】—— 收件箱的一行交给它那一类的转换器。
--   读 ingest_data_classes.transform_function:为空 → awaiting_transform(这一类还没有转换器,行看得见、不丢);
--   不为空 → 调 public.<名>(jsonb)(名字的形状由表上的 CHECK 钉成 transform_<类>_v<版本>,函数不存在就记
--   TRANSFORM_FUNCTION_MISSING|<名>)。成功 → transformed(记下用的是哪一支、结果);转换器 RAISE → failed + error_code
--   (一句机器码原样留下;别的错误记 TRANSFORM_UNEXPECTED|<SQLSTATE>)。每一次都 attempts + 1 并记下是谁、何时。
--   一行转换器的错只回滚它自己(子事务),不碰同一批里的别的行。
--   【内层】不是 SECURITY DEFINER、没有调用者检查,EXECUTE 从 authenticated 收回 —— 只由 ingest_process_pending ·
--   retry_inbox_row 调(它们各自查码,以属主身份调它)。状态只在它设的事务级标记下改得动(守卫)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.ingest_transform_row(p_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r       ingest_inbox%ROWTYPE;
    v_fn    text;
    v_out   jsonb;
    v_err   text;
    v_state text;
BEGIN
    SELECT * INTO r FROM ingest_inbox WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOX_ROW_NOT_FOUND|%', p_id;
    END IF;
    IF r.status NOT IN ('received', 'failed', 'awaiting_transform') THEN
        RAISE EXCEPTION 'INBOX_ROW_FROZEN|%', p_id;
    END IF;
    SELECT c.transform_function INTO v_fn FROM ingest_data_classes c WHERE c.code = r.data_class;

    PERFORM set_config('evoltrya.ingest_ctx', 'inbox_process', true);
    IF v_fn IS NULL THEN
        v_state := 'awaiting_transform';
        UPDATE ingest_inbox
           SET status = v_state, error_code = NULL, attempts = attempts + 1,
               last_attempt_at = clock_timestamp(), last_attempt_by = auth.uid()
         WHERE id = p_id;
    ELSIF to_regprocedure('public.' || v_fn || '(jsonb)') IS NULL THEN
        v_state := 'failed';
        UPDATE ingest_inbox
           SET status = v_state, error_code = 'TRANSFORM_FUNCTION_MISSING|' || v_fn, attempts = attempts + 1,
               last_attempt_at = clock_timestamp(), last_attempt_by = auth.uid()
         WHERE id = p_id;
    ELSE
        BEGIN
            EXECUTE format('SELECT public.%I($1)', v_fn) INTO v_out USING r.payload;
            v_state := 'transformed';
        EXCEPTION WHEN OTHERS THEN
            v_err := SQLERRM;
            IF v_err !~ '^[A-Z][A-Z0-9_]*(\|.*)?$' THEN
                v_err := 'TRANSFORM_UNEXPECTED|' || SQLSTATE;
            END IF;
            v_state := 'failed';
        END;
        UPDATE ingest_inbox
           SET status = v_state,
               transformed_with = CASE WHEN v_state = 'transformed' THEN v_fn END,
               transform_result = CASE WHEN v_state = 'transformed' THEN v_out END,
               error_code = CASE WHEN v_state = 'failed' THEN left(v_err, 200) END,
               attempts = attempts + 1, last_attempt_at = clock_timestamp(), last_attempt_by = auth.uid()
         WHERE id = p_id;
    END IF;
    PERFORM set_config('evoltrya.ingest_ctx', '', true);
    RETURN v_state;
END;
$function$;

-- db/functions/ingest_submit.sql
-- MES-1(2026-10-06,规格 §6 · §7;MES-0 Q4–Q9 · §3.3;MES-1 Step 0 Q4–Q11 · Q13 · Q15 · Q18,Tim):
-- ★★★ 网关唯一够得着的东西 —— 本库第二支、也是最后一支 anon 可执行的函数 ★★★
--
-- 【调法】POST https://<项目>.supabase.co/rest/v1/rpc/ingest_submit,body {p_gateway, p_key, p_body}。
--   给厂商的完整写法在 docs/integration/gateway-interface.md。VOLATILE,所以 PostgREST 只收 POST —— 钥匙永远不进网址。
-- 【它的"权限"是什么】持有那把钥匙:'ngk_' + 64 个十六进制字符(两个 gen_random_uuid,244 位随机)。这里只比哈希:
--   sha256(钥匙的 UTF-8 字节)= gateway_keys.key_hash,而且那把钥匙属于【报上来的那台网关】、没撤、网关没停用。
--   cod_verification 同一个道理:匿名的入口不问 has_permission,它的门就是那个随机值。
-- 【它碰得到什么 —— 白名单,不是减法】
--   读:ingest_settings(上限)· devices(报上来的网关与它带着的设备)· gateway_keys(哈希比对)· ingest_data_classes(类在不在)·
--       ingest_transmissions(失败预算的两次计数、最后一次听到)· ingest_inbox(同一个 (网关, 流, 序号) 来过没有)。
--   写:【只插入】ingest_transmissions · ingest_inbox · gateway_outages;唯一的 UPDATE 是两种桶上的四个计数列(Q8 · Q9,
--       守卫只认本函数设的事务级标记)。devices 一行都不改(Q7)。不跑任何转换代码(Q11)—— 收下的消息停在 received。
--   回:只回调用者自己的序号与固定的码 —— {ok, accepted, duplicates, rejected, code};一个字的表内容都不回。没有反向通道(规格 §7)。
-- 【拒绝只有一句话】(Q10)不认识的网关、错的钥匙、撤了的钥匙、停用的网关 —— 一律 {"ok": false, "code": "refused"};
--   确切理由只在传输日志里、设备页上。分得开就是让人试出哪些网关编号存在。
--   传输上的毛病(太大、太多、形状不对)是网关自己能改的事,所以照名回:too_large · too_many · malformed —— 但只回给【认证过】
--   的调用者;一个没认证的调用者不管送来什么,都只得到 refused。
-- 【失败预算】(Q9)每一次失败都记一行 —— 直到:报上来的同一个编号在滚动窗口(600 秒)里失败了 30 次,或全部失败调用到了 300 次;
--   之后的失败只在 10 分钟一行的溢出桶里计数。答案不变(仍是 refused)。持【有效钥匙】的调用永远不被它限:先认证,
--   认证过的就不看预算(与 cod_verification 有效令牌永不被限流同一条 —— 攻击者拿不出有效钥匙,所以他限不掉任何一台真网关)。
-- 【永不 RAISE 一次认证失败】那会把日志那一行一起回滚 —— 失败必须留下痕迹(规格 §7「Logged」)。
-- 【心跳】{"heartbeat": true}:只让这台网关这一小时的那一行桶往上长(Q8),不落收件箱。
-- 【中断】(MES-0 Q9)认证过、而且这一次会被收下的调用,若上一次听到它已经超过它的心跳间隔,先记一行 gateway_outages。
--   间隔没给(Not yet set)就不记。
-- 【一条消息】{seq, device, class, payload, site_from?, site_to?, dataset_ref?}。信封错(Q15)退回、不落行:
--   ENVELOPE_INVALID · DEVICE_NOT_ON_THIS_GATEWAY(设备不存在、停用了、或不是这台网关带着的 —— 一个码,Q6)· CLASS_UNKNOWN ·
--   SEQ_REUSED(同一个 (网关, 流, 序号) 已经收过一份【不同】的 payload,Q13)。同一份再来 = duplicates。
--   内容(payload 里面)对不对不在这里判 —— 那是转换的事,失败看得见(Q15)。
-- 【并发】同一台网关的调用按顾问锁排队,于是"这个序号来过没有"问的是一个不会在中途变的答案。
-- 【调用方地址】(Q18)PostgREST 把请求头放在 request.headers 里;X-Forwarded-For 原样存下(未经核实),拿不到就是 not available。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.ingest_submit(p_gateway text, p_key text, p_body jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    c_overflow_s constant integer := 600;
    s            ingest_settings%ROWTYPE;
    v_now        timestamptz := clock_timestamp();
    v_code       text := NULLIF(left(btrim(COALESCE(p_gateway, '')), 64), '');
    v_bytes      integer := COALESCE(octet_length(p_body::text), 0);
    v_prefix     text;
    v_addr       text;
    v_gw         devices%ROWTYPE;
    v_found      boolean := false;
    v_key_id     uuid;
    v_revoked    boolean;
    v_result     text;
    v_msgs       jsonb;
    v_stream     text;
    v_n_all      integer;
    v_n_code     integer;
    v_last       timestamptz;
    v_tid        bigint;
    v_i          integer;
    v_m          jsonb;
    v_seq        bigint;
    v_dev        uuid;
    v_from       timestamptz;
    v_to         timestamptz;
    v_ref        text;
    v_sha        bytea;
    v_prior      bytea;
    v_err        text;
    v_seen       jsonb := '{}'::jsonb;
    v_ok         jsonb := '[]'::jsonb;
    v_acc        jsonb := '[]'::jsonb;
    v_dup        jsonb := '[]'::jsonb;
    v_rej        jsonb := '[]'::jsonb;
BEGIN
    SELECT * INTO s FROM ingest_settings WHERE id;

    BEGIN
        v_addr := left(NULLIF(btrim(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for'), ''), 200);
    EXCEPTION WHEN OTHERS THEN
        v_addr := NULL;
    END;
    v_addr := COALESCE(v_addr, 'not available');
    IF p_key ~ '^ngk_[0-9a-f]{8}' THEN
        v_prefix := substr(p_key, 5, 8);
    END IF;

    -- ── ① 认证:先认证,认证过的不看失败预算 ─────────────────────────────────
    IF v_code IS NOT NULL THEN
        SELECT d.* INTO v_gw FROM devices d WHERE d.code = v_code AND d.kind = 'gateway';
        v_found := FOUND;
    END IF;
    IF NOT v_found THEN
        v_result := 'unknown_gateway';
    ELSE
        SELECT k.id, k.revoked_at IS NOT NULL INTO v_key_id, v_revoked
          FROM gateway_keys k
         WHERE k.gateway_id = v_gw.id AND k.key_hash = sha256(convert_to(COALESCE(p_key, ''), 'UTF8'));
        IF v_gw.retired_at IS NOT NULL THEN
            v_result := 'retired_gateway';
        ELSIF v_key_id IS NULL THEN
            v_result := 'bad_key';
        ELSIF v_revoked THEN
            v_result := 'revoked_key';
        END IF;
    END IF;

    -- ── ② 认证过的调用:形状与上限 ─────────────────────────────────────────
    IF v_result IS NULL THEN
        IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN
            v_result := 'malformed';
        ELSIF v_bytes > s.max_payload_bytes THEN
            v_result := 'too_large';
        ELSIF p_body ? 'heartbeat' THEN
            IF p_body -> 'heartbeat' IS DISTINCT FROM 'true'::jsonb OR p_body ? 'messages' THEN
                v_result := 'malformed';
            END IF;
        ELSE
            v_msgs := p_body -> 'messages';
            v_stream := p_body ->> 'stream';
            IF jsonb_typeof(v_msgs) IS DISTINCT FROM 'array' OR jsonb_array_length(v_msgs) = 0
               OR jsonb_typeof(p_body -> 'stream') IS DISTINCT FROM 'string'
               OR char_length(v_stream) NOT BETWEEN 1 AND 64 THEN
                v_result := 'malformed';
            ELSIF jsonb_array_length(v_msgs) > s.max_messages THEN
                v_result := 'too_many';
            END IF;
        END IF;
    END IF;

    -- ── ③ 失败:记下来(预算之内一行一行,超了就进溢出桶),回一句固定的话 ────────
    IF v_result IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtext('ingest_transmissions:failures')::bigint);
        SELECT count(*), count(*) FILTER (WHERE t.presented_gateway IS NOT DISTINCT FROM v_code)
          INTO v_n_all, v_n_code
          FROM ingest_transmissions t
         WHERE t.kind = 'call' AND t.result <> 'accepted'
           AND t.received_at >= v_now - make_interval(secs => s.fail_window_s);
        IF v_n_all >= s.global_reject_budget OR v_n_code >= s.fail_budget THEN
            PERFORM set_config('evoltrya.ingest_ctx', 'ingest_submit', true);
            INSERT INTO ingest_transmissions (kind, received_at, bucket_start, bucket_count, bucket_bytes, bucket_first_at, bucket_last_at)
            VALUES ('rejected_overflow', v_now,
                    to_timestamp(floor(EXTRACT(EPOCH FROM v_now) / c_overflow_s) * c_overflow_s), 1, v_bytes, v_now, v_now)
            ON CONFLICT (bucket_start) WHERE kind = 'rejected_overflow'
            DO UPDATE SET bucket_count   = ingest_transmissions.bucket_count + 1,
                          bucket_bytes   = ingest_transmissions.bucket_bytes + EXCLUDED.bucket_bytes,
                          bucket_last_at = GREATEST(ingest_transmissions.bucket_last_at, EXCLUDED.bucket_last_at);
            PERFORM set_config('evoltrya.ingest_ctx', '', true);
        ELSE
            INSERT INTO ingest_transmissions (kind, received_at, presented_gateway, gateway_id, presented_key_prefix, result,
                                              bytes, client_address)
            VALUES ('call', v_now, v_code, CASE WHEN v_found THEN v_gw.id END, v_prefix, v_result, v_bytes, v_addr);
        END IF;
        IF v_result IN ('malformed', 'too_large', 'too_many') THEN
            RETURN jsonb_build_object('ok', false, 'code', v_result);
        END IF;
        RETURN jsonb_build_object('ok', false, 'code', 'refused');
    END IF;

    -- ── ④ 认证过、形状对:同一台网关排队;回来之前沉默太久就记一段中断 ─────────
    PERFORM pg_advisory_xact_lock(hashtext('ingest:' || v_gw.id::text)::bigint);
    SELECT GREATEST(
               (SELECT max(t.received_at) FROM ingest_transmissions t
                 WHERE t.kind = 'call' AND t.result = 'accepted' AND t.gateway_id = v_gw.id),
               (SELECT max(t.bucket_last_at) FROM ingest_transmissions t
                 WHERE t.kind = 'heartbeat_hour' AND t.gateway_id = v_gw.id))
      INTO v_last;
    IF v_gw.heartbeat_interval_s IS NOT NULL AND v_last IS NOT NULL
       AND v_now - v_last > make_interval(secs => v_gw.heartbeat_interval_s) THEN
        INSERT INTO gateway_outages (gateway_id, silent_from, silent_to, interval_s)
        VALUES (v_gw.id, v_last, v_now, v_gw.heartbeat_interval_s);
    END IF;

    -- ── ⑤ 心跳:只让这一小时的桶往上长 ──────────────────────────────────────
    IF p_body ? 'heartbeat' THEN
        PERFORM set_config('evoltrya.ingest_ctx', 'ingest_submit', true);
        INSERT INTO ingest_transmissions (kind, received_at, gateway_id, bucket_start, bucket_count, bucket_bytes,
                                          bucket_first_at, bucket_last_at)
        VALUES ('heartbeat_hour', v_now, v_gw.id, date_trunc('hour', v_now), 1, v_bytes, v_now, v_now)
        ON CONFLICT (gateway_id, bucket_start) WHERE kind = 'heartbeat_hour'
        DO UPDATE SET bucket_count   = ingest_transmissions.bucket_count + 1,
                      bucket_bytes   = ingest_transmissions.bucket_bytes + EXCLUDED.bucket_bytes,
                      bucket_last_at = GREATEST(ingest_transmissions.bucket_last_at, EXCLUDED.bucket_last_at);
        PERFORM set_config('evoltrya.ingest_ctx', '', true);
        RETURN jsonb_build_object('ok', true);
    END IF;

    -- ── ⑥ 逐条看信封 ────────────────────────────────────────────────────────
    FOR v_i IN 0 .. jsonb_array_length(v_msgs) - 1 LOOP
        v_m := v_msgs -> v_i;
        v_seq := NULL; v_dev := NULL; v_from := NULL; v_to := NULL; v_ref := NULL; v_err := NULL;
        IF jsonb_typeof(v_m) IS DISTINCT FROM 'object' OR jsonb_typeof(v_m -> 'seq') IS DISTINCT FROM 'number'
           OR (v_m ->> 'seq') !~ '^[1-9][0-9]{0,17}$' THEN
            v_err := 'ENVELOPE_INVALID';
        ELSE
            v_seq := (v_m ->> 'seq')::bigint;
            IF NOT (v_m ? 'payload') OR jsonb_typeof(v_m -> 'device') IS DISTINCT FROM 'string'
               OR jsonb_typeof(v_m -> 'class') IS DISTINCT FROM 'string'
               OR (v_m ? 'dataset_ref' AND jsonb_typeof(v_m -> 'dataset_ref') IS DISTINCT FROM 'string')
               OR char_length(COALESCE(v_m ->> 'dataset_ref', '')) > 200 THEN
                v_err := 'ENVELOPE_INVALID';
            END IF;
        END IF;
        IF v_err IS NULL THEN
            BEGIN
                v_from := (v_m ->> 'site_from')::timestamptz;
                v_to := (v_m ->> 'site_to')::timestamptz;
            EXCEPTION WHEN OTHERS THEN
                v_err := 'ENVELOPE_INVALID';
            END;
            IF v_err IS NULL AND v_from > v_to THEN
                v_err := 'ENVELOPE_INVALID';
            END IF;
        END IF;
        IF v_err IS NULL THEN
            SELECT d.id INTO v_dev FROM devices d
             WHERE d.code = v_m ->> 'device' AND d.gateway_id = v_gw.id AND d.retired_at IS NULL;
            IF v_dev IS NULL THEN
                v_err := 'DEVICE_NOT_ON_THIS_GATEWAY';
            ELSIF NOT EXISTS (SELECT 1 FROM ingest_data_classes c WHERE c.code = v_m ->> 'class' AND c.is_active) THEN
                v_err := 'CLASS_UNKNOWN';
            END IF;
        END IF;
        IF v_err IS NULL THEN
            v_sha := sha256(convert_to((v_m -> 'payload')::text, 'UTF8'));
            v_prior := decode(v_seen ->> v_seq::text, 'hex');
            IF v_prior IS NULL THEN
                SELECT b.payload_sha256 INTO v_prior FROM ingest_inbox b
                 WHERE b.source = 'device' AND b.gateway_id = v_gw.id AND b.stream = v_stream AND b.seq = v_seq;
            END IF;
            IF v_prior IS NOT NULL THEN
                IF v_prior = v_sha THEN
                    v_dup := v_dup || to_jsonb(v_seq);
                    CONTINUE;
                END IF;
                v_err := 'SEQ_REUSED';
            END IF;
        END IF;
        IF v_err IS NOT NULL THEN
            v_rej := v_rej || jsonb_build_array(jsonb_build_object('index', v_i, 'seq', v_seq, 'code', v_err));
            CONTINUE;
        END IF;
        v_seen := v_seen || jsonb_build_object(v_seq::text, encode(v_sha, 'hex'));
        v_acc := v_acc || to_jsonb(v_seq);
        v_ok := v_ok || jsonb_build_array(jsonb_build_object(
            'seq', v_seq, 'device_id', v_dev, 'class', v_m ->> 'class', 'payload', v_m -> 'payload',
            'sha', encode(v_sha, 'hex'), 'from', v_from, 'to', v_to, 'ref', v_m ->> 'dataset_ref'));
    END LOOP;

    -- ── ⑦ 一次调用一行,然后收下的那几条各一行 ────────────────────────────────
    INSERT INTO ingest_transmissions (kind, received_at, presented_gateway, gateway_id, presented_key_prefix, result, bytes,
                                      message_count, accepted_count, duplicate_count, rejected_count, stream, first_seq, last_seq,
                                      rejections, client_address)
    VALUES ('call', v_now, v_code, v_gw.id, v_prefix, 'accepted', v_bytes, jsonb_array_length(v_msgs),
            jsonb_array_length(v_acc), jsonb_array_length(v_dup), jsonb_array_length(v_rej), v_stream,
            (SELECT min(x::bigint) FROM jsonb_array_elements_text(v_acc) x),
            (SELECT max(x::bigint) FROM jsonb_array_elements_text(v_acc) x),
            CASE WHEN jsonb_array_length(v_rej) > 0 THEN v_rej END, v_addr)
    RETURNING id INTO v_tid;

    INSERT INTO ingest_inbox (transmission_id, source, gateway_id, stream, seq, device_id, data_class, payload, payload_bytes,
                              payload_sha256, site_from, site_to, site_dataset_ref, clock_ahead, received_at)
    SELECT v_tid, 'device', v_gw.id, v_stream, (o ->> 'seq')::bigint, (o ->> 'device_id')::uuid, o ->> 'class', o -> 'payload',
           octet_length((o -> 'payload')::text), decode(o ->> 'sha', 'hex'),
           (o ->> 'from')::timestamptz, (o ->> 'to')::timestamptz, o ->> 'ref',
           COALESCE((o ->> 'to')::timestamptz > v_now + make_interval(secs => s.clock_ahead_s), false), v_now
      FROM jsonb_array_elements(v_ok) o;

    RETURN jsonb_build_object('ok', true, 'accepted', v_acc, 'duplicates', v_dup, 'rejected', v_rej);
END;
$function$;

-- db/functions/issue_gateway_key.sql
-- MES-1(2026-10-06,MES-0 Q5 · §3.4;MES-1 Step 0 Q5,Tim):给一台网关发一把钥匙 —— 【密钥只在这一次返回值里出现】。
--   持 action.manage_devices;那台设备必须是一台没停用的网关;它已经有两把有效钥匙就按名拒(守卫:GATEWAY_KEY_TWO_ACTIVE)。
--   密钥 = 'ngk_' + 两个 gen_random_uuid() 去掉连字符(64 个十六进制字符,244 位随机;PostgreSQL 内建,不用 pgcrypto —— Q5,
--   线上 17.6)。存下的是 'ngk_' 之后的 8 个字符(前缀,页面认得出是哪一把)与 sha256(密钥) —— 密钥本身哪里都不存。
--   变更记录记下发放这件事(前缀、谁、何时);哈希被 never 规则遮住(Q20)。
--   返回 {key_id, prefix, secret}。页面把 secret 显示一次,然后它就没了:丢了就再发一把、撤旧的那把。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.issue_gateway_key(p_gateway_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_secret text;
    v_id     uuid;
BEGIN
    PERFORM require_permission('action.manage_devices');
    IF p_gateway_id IS NULL THEN
        RAISE EXCEPTION 'GATEWAY_KEY_NOT_A_GATEWAY|?';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('ingest:' || p_gateway_id::text)::bigint);
    v_secret := 'ngk_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
    INSERT INTO gateway_keys (gateway_id, key_prefix, key_hash, issued_by)
    VALUES (p_gateway_id, substr(v_secret, 5, 8), sha256(convert_to(v_secret, 'UTF8')), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('key_id', v_id, 'prefix', substr(v_secret, 5, 8), 'secret', v_secret);
END;
$function$;

-- db/functions/revoke_gateway_key.sql
-- MES-1(2026-10-06,MES-0 Q5 · §3.4):撤一把网关钥匙 —— 下一次调用就生效(ingest_submit 每一次都现查)。
--   持 action.manage_devices;要写理由(GATEWAY_KEY_REVOKE_REASON_REQUIRED);撤过的再撤按名拒(守卫:GATEWAY_KEY_ALREADY_REVOKED)。
--   撤一台网关的钥匙碰不到任何别的网关(钥匙按网关分)。轮换:发第二把 → 网关换上 → 撤第一把,线不停。
--   零行不许报成功:钥匙不存在就按名拒(GATEWAY_KEY_NOT_FOUND)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.revoke_gateway_key(p_key_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.manage_devices');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'GATEWAY_KEY_REVOKE_REASON_REQUIRED';
    END IF;
    UPDATE gateway_keys
       SET revoked_at = now(), revoked_by = auth.uid(), revoke_reason = btrim(p_reason)
     WHERE id = p_key_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'GATEWAY_KEY_NOT_FOUND';
    END IF;
END;
$function$;

-- db/functions/save_device.sql
-- MES-1(2026-10-06,MES-0 §3.2 · §5.2;MES-1 Step 0 Q6 · Q28,Tim):登记或修改一台设备 —— 设备登记唯一的写入口。
--   持 action.manage_devices。p_id 不给(为空)= 新登记(编号 DEV-YYYY-NNNN 由触发器生成,Q28);否则改那一台。
--   p_fields 只认下面这些键,别的键按名拒(DEVICE_FIELD_UNKNOWN|<键>)—— 一个打错的键不许安静地什么都没改:
--     name · kind(只在新登记时)· gateway_id · data_class · equipment_id · station · capacity · resolution · unit ·
--     protection_rating · interface_status · term_protocol · term_point_list · term_timestamp_precision · term_no_charge ·
--     term_retention_export · term_documentation · heartbeat_interval_s · notes
--   修改时只改给了的键;给一个键而值是 null = 清空它。
--   判据(各自按名拒):带它的网关必须是一台没停用的网关(DEVICE_GATEWAY_INVALID);资产卡要存在(DEVICE_EQUIPMENT_UNKNOWN);
--   数据类要在字典里(DEVICE_CLASS_UNKNOWN);种类定下不改、停用的冻住(守卫)。表上的 CHECK 管其余的形状。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.save_device(p_fields jsonb, p_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    c_keys constant text[] := ARRAY['name', 'kind', 'gateway_id', 'data_class', 'equipment_id', 'station', 'capacity',
        'resolution', 'unit', 'protection_rating', 'interface_status', 'term_protocol', 'term_point_list',
        'term_timestamp_precision', 'term_no_charge', 'term_retention_export', 'term_documentation',
        'heartbeat_interval_s', 'notes'];
    v_key  text;
    v_row  devices%ROWTYPE;
    v_id   uuid;
    f      jsonb := COALESCE(p_fields, '{}'::jsonb);
BEGIN
    PERFORM require_permission('action.manage_devices');
    IF jsonb_typeof(f) <> 'object' THEN
        RAISE EXCEPTION 'DEVICE_FIELD_UNKNOWN|?';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF NOT v_key = ANY (c_keys) THEN
            RAISE EXCEPTION 'DEVICE_FIELD_UNKNOWN|%', v_key;
        END IF;
    END LOOP;

    IF p_id IS NULL THEN
        v_row.name := f ->> 'name';
        v_row.kind := f ->> 'kind';
        v_row.interface_status := COALESCE(f ->> 'interface_status', 'reserved');
        v_row.term_protocol := COALESCE(f ->> 'term_protocol', 'not_confirmed');
        v_row.term_point_list := COALESCE(f ->> 'term_point_list', 'not_confirmed');
        v_row.term_timestamp_precision := COALESCE(f ->> 'term_timestamp_precision', 'not_confirmed');
        v_row.term_no_charge := COALESCE(f ->> 'term_no_charge', 'not_confirmed');
        v_row.term_retention_export := COALESCE(f ->> 'term_retention_export', 'not_confirmed');
        v_row.term_documentation := COALESCE(f ->> 'term_documentation', 'not_confirmed');
    ELSE
        SELECT * INTO v_row FROM devices WHERE id = p_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'DEVICE_NOT_FOUND';
        END IF;
        IF f ? 'kind' AND (f ->> 'kind') IS DISTINCT FROM v_row.kind THEN
            RAISE EXCEPTION 'DEVICE_KIND_FIXED|%', v_row.code;
        END IF;
        IF f ? 'name' THEN v_row.name := f ->> 'name'; END IF;
        IF f ? 'interface_status' THEN v_row.interface_status := f ->> 'interface_status'; END IF;
        IF f ? 'term_protocol' THEN v_row.term_protocol := f ->> 'term_protocol'; END IF;
        IF f ? 'term_point_list' THEN v_row.term_point_list := f ->> 'term_point_list'; END IF;
        IF f ? 'term_timestamp_precision' THEN v_row.term_timestamp_precision := f ->> 'term_timestamp_precision'; END IF;
        IF f ? 'term_no_charge' THEN v_row.term_no_charge := f ->> 'term_no_charge'; END IF;
        IF f ? 'term_retention_export' THEN v_row.term_retention_export := f ->> 'term_retention_export'; END IF;
        IF f ? 'term_documentation' THEN v_row.term_documentation := f ->> 'term_documentation'; END IF;
    END IF;
    IF p_id IS NULL OR f ? 'gateway_id' THEN v_row.gateway_id := NULLIF(f ->> 'gateway_id', '')::uuid; END IF;
    IF p_id IS NULL OR f ? 'data_class' THEN v_row.data_class := NULLIF(f ->> 'data_class', ''); END IF;
    IF p_id IS NULL OR f ? 'equipment_id' THEN v_row.equipment_id := NULLIF(f ->> 'equipment_id', '')::uuid; END IF;
    IF p_id IS NULL OR f ? 'station' THEN v_row.station := NULLIF(btrim(f ->> 'station'), ''); END IF;
    IF p_id IS NULL OR f ? 'capacity' THEN v_row.capacity := NULLIF(f ->> 'capacity', '')::numeric; END IF;
    IF p_id IS NULL OR f ? 'resolution' THEN v_row.resolution := NULLIF(f ->> 'resolution', '')::numeric; END IF;
    IF p_id IS NULL OR f ? 'unit' THEN v_row.unit := NULLIF(btrim(f ->> 'unit'), ''); END IF;
    IF p_id IS NULL OR f ? 'protection_rating' THEN v_row.protection_rating := NULLIF(btrim(f ->> 'protection_rating'), ''); END IF;
    IF p_id IS NULL OR f ? 'heartbeat_interval_s' THEN v_row.heartbeat_interval_s := NULLIF(f ->> 'heartbeat_interval_s', '')::integer; END IF;
    IF p_id IS NULL OR f ? 'notes' THEN v_row.notes := NULLIF(btrim(f ->> 'notes'), ''); END IF;
    v_row.name := btrim(COALESCE(v_row.name, ''));

    IF v_row.gateway_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM devices g WHERE g.id = v_row.gateway_id AND g.kind = 'gateway' AND g.retired_at IS NULL) THEN
        RAISE EXCEPTION 'DEVICE_GATEWAY_INVALID';
    END IF;
    IF v_row.equipment_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fixed_assets a WHERE a.id = v_row.equipment_id) THEN
        RAISE EXCEPTION 'DEVICE_EQUIPMENT_UNKNOWN';
    END IF;
    IF v_row.data_class IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ingest_data_classes c WHERE c.code = v_row.data_class) THEN
        RAISE EXCEPTION 'DEVICE_CLASS_UNKNOWN|%', v_row.data_class;
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO devices (name, kind, gateway_id, data_class, equipment_id, station, capacity, resolution, unit,
                             protection_rating, interface_status, term_protocol, term_point_list, term_timestamp_precision,
                             term_no_charge, term_retention_export, term_documentation, heartbeat_interval_s, notes,
                             created_by, updated_by)
        VALUES (v_row.name, v_row.kind, v_row.gateway_id, v_row.data_class, v_row.equipment_id, v_row.station, v_row.capacity,
                v_row.resolution, v_row.unit, v_row.protection_rating, v_row.interface_status, v_row.term_protocol,
                v_row.term_point_list, v_row.term_timestamp_precision, v_row.term_no_charge, v_row.term_retention_export,
                v_row.term_documentation, v_row.heartbeat_interval_s, v_row.notes, auth.uid(), auth.uid())
        RETURNING id INTO v_id;
        RETURN v_id;
    END IF;
    UPDATE devices
       SET name = v_row.name, gateway_id = v_row.gateway_id, data_class = v_row.data_class, equipment_id = v_row.equipment_id,
           station = v_row.station, capacity = v_row.capacity, resolution = v_row.resolution, unit = v_row.unit,
           protection_rating = v_row.protection_rating, interface_status = v_row.interface_status,
           term_protocol = v_row.term_protocol, term_point_list = v_row.term_point_list,
           term_timestamp_precision = v_row.term_timestamp_precision, term_no_charge = v_row.term_no_charge,
           term_retention_export = v_row.term_retention_export, term_documentation = v_row.term_documentation,
           heartbeat_interval_s = v_row.heartbeat_interval_s, notes = v_row.notes, updated_by = auth.uid()
     WHERE id = p_id;
    RETURN p_id;
END;
$function$;

-- db/functions/retire_device.sql
-- MES-1(2026-10-06):停用一台设备 —— 不删(收件箱、传输日志、钥匙都指着它),停用就是它的去处。
--   持 action.manage_devices;要写理由(DEVICE_RETIRE_REASON_REQUIRED);已经停用的按名拒(DEVICE_RETIRED)。
--   停用一台网关,同一笔事务里把它还有效的钥匙一并撤掉(理由照抄)—— 一台停用的网关本来就一律被拒(retired_gateway),
--   撤掉钥匙是让设备页上不再挂着"有效"两个字。它带着的设备不动(它们的消息本来就要经它进来)。
--   停用之后那一行冻住(守卫)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.retire_device(p_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_row devices%ROWTYPE;
BEGIN
    PERFORM require_permission('action.manage_devices');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DEVICE_RETIRE_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_row FROM devices WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DEVICE_NOT_FOUND';
    END IF;
    IF v_row.retired_at IS NOT NULL THEN
        RAISE EXCEPTION 'DEVICE_RETIRED|%', v_row.code;
    END IF;
    IF v_row.kind = 'gateway' THEN
        UPDATE gateway_keys
           SET revoked_at = now(), revoked_by = auth.uid(), revoke_reason = btrim(p_reason)
         WHERE gateway_id = p_id AND revoked_at IS NULL;
    END IF;
    UPDATE devices
       SET retired_at = now(), retired_by = auth.uid(), retire_reason = btrim(p_reason), updated_by = auth.uid()
     WHERE id = p_id;
END;
$function$;

-- db/functions/set_ingest_settings.sql
-- MES-1(2026-10-06,MES-0 Q7;MES-1 Step 0 Q9 · Q13 · Q22):改采集层的传输上限 —— 那一行配置唯一的写入口。
--   持 action.manage_devices。p_fields 只认六个键(fail_budget · fail_window_s · global_reject_budget · max_payload_bytes ·
--   max_messages · clock_ahead_s),别的键按名拒(INGEST_SETTING_UNKNOWN|<键>);每一个值必须是正整数
--   (INGEST_SETTING_INVALID|<键>)。修改史 = 变更记录(Q22)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.set_ingest_settings(p_fields jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    c_keys constant text[] := ARRAY['fail_budget', 'fail_window_s', 'global_reject_budget', 'max_payload_bytes',
                                    'max_messages', 'clock_ahead_s'];
    v_key text;
    f     jsonb := COALESCE(p_fields, '{}'::jsonb);
BEGIN
    PERFORM require_permission('action.manage_devices');
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF NOT v_key = ANY (c_keys) THEN
            RAISE EXCEPTION 'INGEST_SETTING_UNKNOWN|%', v_key;
        END IF;
        IF COALESCE(f ->> v_key, '') !~ '^[1-9][0-9]{0,8}$' THEN
            RAISE EXCEPTION 'INGEST_SETTING_INVALID|%', v_key;
        END IF;
    END LOOP;
    UPDATE ingest_settings
       SET fail_budget          = COALESCE((f ->> 'fail_budget')::integer, fail_budget),
           fail_window_s        = COALESCE((f ->> 'fail_window_s')::integer, fail_window_s),
           global_reject_budget = COALESCE((f ->> 'global_reject_budget')::integer, global_reject_budget),
           max_payload_bytes    = COALESCE((f ->> 'max_payload_bytes')::integer, max_payload_bytes),
           max_messages         = COALESCE((f ->> 'max_messages')::integer, max_messages),
           clock_ahead_s        = COALESCE((f ->> 'clock_ahead_s')::integer, clock_ahead_s),
           updated_by           = auth.uid()
     WHERE id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INGEST_SETTINGS_MISSING';
    END IF;
END;
$function$;

-- db/functions/ingest_process_pending.sql
-- MES-1(2026-10-06,MES-1 Step 0 Q11,Tim):【"Process received"】—— 把收件箱里 status = received 的行按到达顺序交给分派器。
--   转换只在员工的会话里跑(Q11),所以这是收件箱上的一个按钮,持 module.processing.view 的人能按;
--   MES-2 的确认队列打开时会调它。它只改状态那几列(守卫),处理一遍是幂等的:没有 received 的行就什么都不做。
--   p_limit 一次最多几行(默认 200,1–1000);返回 {processed, transformed, failed, awaiting}。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.ingest_process_pending(p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id    bigint;
    v_state text;
    v_t     integer := 0;
    v_f     integer := 0;
    v_a     integer := 0;
BEGIN
    PERFORM require_permission('module.processing.view');
    FOR v_id IN SELECT b.id FROM ingest_inbox b WHERE b.status = 'received'
                 ORDER BY b.id LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 1000) LOOP
        v_state := ingest_transform_row(v_id);
        IF v_state = 'transformed' THEN v_t := v_t + 1;
        ELSIF v_state = 'failed' THEN v_f := v_f + 1;
        ELSE v_a := v_a + 1;
        END IF;
    END LOOP;
    RETURN jsonb_build_object('processed', v_t + v_f + v_a, 'transformed', v_t, 'failed', v_f, 'awaiting', v_a);
END;
$function$;

-- db/functions/retry_inbox_row.sql
-- MES-1(2026-10-06,MES-0 §3.5):重试收件箱里一行失败的或待转换的 —— 例如一支转换器修好了、或一类刚接上了转换器之后。
--   持 action.manage_devices。只收 failed / awaiting_transform(INBOX_NOT_RETRIABLE|<状态>);返回这一次的结果状态。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.retry_inbox_row(p_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_status text;
BEGIN
    PERFORM require_permission('action.manage_devices');
    SELECT status INTO v_status FROM ingest_inbox WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOX_ROW_NOT_FOUND|%', p_id;
    END IF;
    IF v_status NOT IN ('failed', 'awaiting_transform') THEN
        RAISE EXCEPTION 'INBOX_NOT_RETRIABLE|%', v_status;
    END IF;
    RETURN ingest_transform_row(p_id);
END;
$function$;

-- db/functions/discard_inbox_row.sql
-- MES-1(2026-10-06,规格 §6.4;MES-0 §3.5):带理由丢弃收件箱里一行失败的或待转换的 —— 【永远不删】。
--   持 action.manage_devices;要写理由(INBOX_DISCARD_REASON_REQUIRED);只收 failed / awaiting_transform
--   (INBOX_NOT_DISCARDABLE|<状态>)。丢弃之后那一行冻住,留在收件箱里,标着谁、何时、为什么;失败的那个码留着。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.discard_inbox_row(p_id bigint, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_status text;
BEGIN
    PERFORM require_permission('action.manage_devices');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'INBOX_DISCARD_REASON_REQUIRED';
    END IF;
    SELECT status INTO v_status FROM ingest_inbox WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOX_ROW_NOT_FOUND|%', p_id;
    END IF;
    IF v_status NOT IN ('failed', 'awaiting_transform') THEN
        RAISE EXCEPTION 'INBOX_NOT_DISCARDABLE|%', v_status;
    END IF;
    PERFORM set_config('evoltrya.ingest_ctx', 'inbox_process', true);
    UPDATE ingest_inbox
       SET status = 'discarded', discarded_at = now(), discarded_by = auth.uid(),
           discard_reason = btrim(p_reason)
     WHERE id = p_id;
    PERFORM set_config('evoltrya.ingest_ctx', '', true);
END;
$function$;

-- ── 6 · 改过的函数:变更记录的豁免与遮蔽、审计记录的主语与成员(镜像原样,同签名)──────────

-- db/functions/change_log_exclusions.sql
-- HISTORY-1(Tim 的 Q5):不挂变更记录触发器的表 —— 【唯一】的一份名单,每一条带理由。
--
-- 三处读它,所以它只能有一份:
--   · change_log_coverage_gaps() —— gate 的 changelog 那一行(线上 + 重建)与 fixture 234;
--   · scripts/check-change-log-coverage.mjs —— 构建里的静态检查,从本文件的 VALUES 里读;
--   · db/scripts/gen_change_log_bindings.py —— 生成绑定清单时跳过这几张。
-- ★ 规矩(docs/change-log.md):新建的每一张 public 表,要么在 db/views/zzz_change_log_triggers.sql
--   里有两条绑定,要么在这里有一行带理由的豁免。两者都没有,构建与 gate 都会红。
-- ★ MES-1(2026-10-06,MES-0 Q14,Tim):第二种被接受的豁免 —— 【采集层的三份日志】(收件箱 · 传输日志 · 网关中断)。
--   它们本身就是只追加的日志(守卫按名拒改与删);再记一遍是把规格 §2.1 警告的量翻一倍,而不多一个事实。
--   状态的变化记在行上(收件箱的 attempts · last_attempt_* · discarded_*)。
CREATE OR REPLACE FUNCTION public.change_log_exclusions()
 RETURNS TABLE(table_name text, reason text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    VALUES
        ('change_log'::text, 'The change log itself; a trigger on it would record its own writes.'::text),
        ('festival_doodles', 'Home-screen holiday artwork; screen decoration with no business meaning.'),
        ('gateway_outages', 'Ingestion log (MES-1): itself an append-only record of gateway silences; logging it again doubles the volume and adds no fact.'),
        ('home_greetings', 'Home-screen greeting text; screen decoration with no business meaning.'),
        ('ingest_inbox', 'Ingestion log (MES-1): itself an append-only landing table; its status changes are recorded on the row (attempts, last attempt, discard).'),
        ('ingest_transmissions', 'Ingestion log (MES-1): itself an append-only log of every gateway call; logging it again doubles the volume and adds no fact.'),
        ('notification_reads', 'Per-viewer "seen" marks on notifications; screen state with no business meaning.');
$function$;

-- db/functions/change_log_mask_rules.sql
-- HISTORY-1(Tim 的 Q10 · Q7 · Q20):change_log_rows() 的遮蔽规则 —— 【一份】名单,一列一行。
--
-- 【来源】逐条抄自每一张 <表>_masked 视图里那句 CASE WHEN … THEN <列> ELSE NULL END(以 postgres
--   读 pg_get_viewdef,2026-09-28),外加本刀新建的 purchase_order_history_masked。
--   "源屏幕怎么遮,记录就怎么遮" —— 屏幕读的就是这些视图。
-- 【规则的写法】
--   code:<码>                    持这个码才看得见
--   code_or_self:<码>:<列>       持码,或那一行的 <列> 就是读者自己的员工 id(视图里的 OR id = current_user_employee())
--   pft:direction                pricing_formula_terms_visible(这一行的 direction)
--   pft:formula_id               pricing_formula_terms_visible(这一行所属公式的 direction)
--   pft3                         pricing_formula_history_masked 那三段:公式当前方向 ∧ old_direction ∧ new_direction
--   pay_journal:<码>             持码,或这一行所在分录不是工资分录(journal_lines_masked;U1-A,UNBLOCK-1 Q1)
--   apr_amount                   approval_log_amount_visible(subject_type, subject_id)(approval_log_masked;U1-A,Q8 · Q10)
--   apr_note                     approval_log_note_visible(subject_type, subject_id)(approval_log_masked;U1-B)
--   jr_amount                    journal_request_amount_visible(id)(journal_requests_masked;U1-B)
--   never                        谁都看不见(gateway_keys_masked 里 CASE WHEN false;MES-1 Q20:网关钥匙的哈希)
-- ★ MES-1(2026-10-06)加了 1 行(104 → 105):网关钥匙的哈希 —— never(Q20:任何读者、任何一份记录都不给)。
-- ★ U1-B(2026-10-05)加了 3 行(101 → 104):工资分录冲销申请的金额 · 医疗报销的批准 / 驳回理由(在报销单上与在审批留痕上)。
-- ★ U1-A(UNBLOCK-1,2026-10-05)加了 20 行(81 → 101):工资分录的金额(Q1)· 审批留痕上的金额(Q8 · Q10)· 人事备注(Q6)·
--   健康数据(Q8)· 工资期的合计与工资申请的快照和金额(Q9 · Q10)。每一行都抄自它那张 _masked 视图里的 CASE。
-- 【它会不会和视图漂开】会 —— 所以有一道闸:change_log_mask_gaps() 拿目录里【真的被遮的列】
--   (_masked 视图里 CASE … END AS <基表的列>)与本名单逐列对,缺一条或多一条都报;
--   gate 的 changemask 那一行在线上与重建两侧各问一次,fixture 234 里注入"删掉一条"必须变红。
CREATE OR REPLACE FUNCTION public.change_log_mask_rules()
 RETURNS TABLE(table_name text, column_name text, rule text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    VALUES
        ('approval_log'::text, 'amount_ccy'::text, 'apr_amount'::text),
        ('gateway_keys', 'key_hash', 'never'),
        ('approval_log', 'amount_base', 'apr_amount'),
        ('approval_log', 'note', 'apr_note'),
        ('company_profile', 'bank_name', 'code:data.view_banking'),
        ('company_profile', 'bank_account_name', 'code:data.view_banking'),
        ('company_profile', 'bank_account_no', 'code:data.view_banking'),
        ('company_profile', 'bank_swift', 'code:data.view_banking'),
        ('company_profile', 'bank_address', 'code:data.view_banking'),
        ('employees', 'work_email', 'code_or_self:data.view_identity:id'),
        ('employees', 'work_phone', 'code_or_self:data.view_identity:id'),
        ('employees', 'identity_no', 'code_or_self:data.view_identity:id'),
        ('employees', 'work_pass_no', 'code_or_self:data.view_identity:id'),
        ('employees', 'monthly_salary', 'code_or_self:data.view_pay:id'),
        ('employees', 'notes', 'code:module.hr.view'),
        ('employees', 'separation_notes', 'code:module.hr.view'),
        ('employment_history', 'old_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('employment_history', 'new_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('inbound_batches', 'unit_price', 'code:data.view_purchase_prices'),
        ('invoice_lines', 'unit_price', 'code:data.view_prices'),
        ('invoice_lines', 'amount_base', 'code:data.view_prices'),
        ('invoice_lines', 'amount_ccy', 'code:data.view_prices'),
        ('invoice_lines', 'tax_base', 'code:data.view_prices'),
        ('invoices', 'subtotal_base', 'code:data.view_prices'),
        ('invoices', 'tax_base', 'code:data.view_prices'),
        ('invoices', 'total_base', 'code:data.view_prices'),
        ('invoices', 'fx_rate', 'code:data.view_prices'),
        ('journal_lines', 'debit', 'pay_journal:data.view_pay'),
        ('journal_lines', 'credit', 'pay_journal:data.view_pay'),
        ('journal_lines', 'amount_ccy', 'pay_journal:data.view_pay'),
        ('journal_requests', 'amount_base', 'jr_amount'),
        ('leave_requests', 'reason', 'code_or_self:data.view_health:employee_id'),
        ('leave_requests', 'certificate_ref', 'code_or_self:data.view_health:employee_id'),
        ('leave_requests', 'exception_reason', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'amount_sgd', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'description', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'decision_notes', 'code_or_self:data.view_health:employee_id'),
        ('payment_term_template_lines', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('payroll_lines', 'gross_pay', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'employer_cpf', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'employee_cpf', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'other_deductions', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'net_pay', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_periods', 'gross_total', 'code:data.view_pay'),
        ('payroll_periods', 'employer_cpf_total', 'code:data.view_pay'),
        ('payroll_periods', 'employee_cpf_total', 'code:data.view_pay'),
        ('payroll_periods', 'other_deductions_total', 'code:data.view_pay'),
        ('payroll_periods', 'net_pay_total', 'code:data.view_pay'),
        ('payroll_requests', 'snapshot', 'code:data.view_pay'),
        ('payroll_requests', 'gross_total', 'code:data.view_pay'),
        ('payroll_requests', 'amount_base', 'code:data.view_pay'),
        ('performance_reviews', 'new_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('prepayment_applications', 'amount_base', 'code:data.view_purchase_prices'),
        ('prepayment_applications', 'amount_ccy', 'code:data.view_purchase_prices'),
        ('price_history', 'old_unit_price', 'code:data.view_purchase_prices'),
        ('price_history', 'new_unit_price', 'code:data.view_purchase_prices'),
        ('price_history', 'original_price', 'code:data.view_purchase_prices'),
        ('price_history', 'fx_rate', 'code:data.view_purchase_prices'),
        ('pricing_formula_history', 'old_payable_pct', 'pft3'),
        ('pricing_formula_history', 'new_payable_pct', 'pft3'),
        ('pricing_formula_history', 'old_treatment_charge_usd_per_tonne', 'pft3'),
        ('pricing_formula_history', 'new_treatment_charge_usd_per_tonne', 'pft3'),
        ('pricing_formula_history', 'old_flat_discount_pct', 'pft3'),
        ('pricing_formula_history', 'new_flat_discount_pct', 'pft3'),
        ('pricing_formula_metals', 'payable_pct', 'pft:formula_id'),
        ('pricing_formulas', 'treatment_charge_usd_per_tonne', 'pft:direction'),
        ('pricing_formulas', 'flat_discount_pct', 'pft:direction'),
        ('pricing_term_commitment_metals', 'payable_pct', 'code:data.view_purchase_prices'),
        ('pricing_term_commitments', 'treatment_charge_usd_per_tonne', 'code:data.view_purchase_prices'),
        ('pricing_term_commitments', 'flat_discount_pct', 'code:data.view_purchase_prices'),
        ('processing_cost_entries', 'amount_base', 'code:data.view_prices'),
        ('processing_cost_entry_history', 'old_amount_base', 'code:data.view_prices'),
        ('processing_cost_entry_history', 'new_amount_base', 'code:data.view_prices'),
        ('processing_outputs', 'allocated_cost_base', 'code:data.view_prices'),
        ('processing_outputs', 'unit_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'material_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'process_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'total_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'capitalized_cost_base', 'code:data.view_prices'),
        ('warehouse_requests', 'amount_base', 'code:data.view_prices'),
        ('purchase_order_history', 'old_fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_payment_term', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_payment_term', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'released_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'withheld_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'price_provenance', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'tax_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_payment_terms', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'tax_total_ccy', 'code:data.view_purchase_prices'),
        ('sales_records', 'unit_price', 'code:data.view_prices'),
        ('sales_records', 'fx_rate', 'code:data.view_prices'),
        ('sales_records', 'amount_base', 'code:data.view_prices'),
        ('sales_records', 'price_provenance', 'code:data.view_prices');
$function$;

-- db/functions/change_log_rule_visible.sql
-- HISTORY-1:一条遮蔽规则(change_log_mask_rules)对【当前读者】、就【这一行记录】成不成立。
-- 与 _masked 视图里那句 CASE WHEN 逐条同一个判据;认不出的规则按【看不见】答(关着失败)。
-- ★ U1-A(UNBLOCK-1,2026-10-05)两种新写法,各自与它那张 _masked 视图里的 CASE 同一个判据:
--   pay_journal:<码>   持码,或这一行所在分录(entry_id → journal_entries.source_type)不是 'payroll'(journal_lines_masked)。
--                       分录找不到 → 看不见(关着失败;分录不可删,所以这只在影像里根本没有 entry_id 时发生)。
--   apr_amount         approval_log_amount_visible(subject_type, subject_id) —— 视图与这里调同一支函数(approval_log_masked)。
-- ★ U1-B(2026-10-05)两种新写法,同一个道理:
--   apr_note           approval_log_note_visible(subject_type, subject_id)(approval_log_masked 的 note;医疗报销的说明是健康的字)。
--   jr_amount          journal_request_amount_visible(这一行的 id)(journal_requests_masked;工资分录的冲销申请要 data.view_pay)。
-- ★ MES-1(2026-10-06,Q20)一种新写法:
--   never              谁都看不见(gateway_keys_masked 里那一列恒为空)。它与"认不出的规则"答的是同一个 false,
--                       而它在这里点名写出来 —— 一条只因为认不出才成立的规则,是一份只写在注释里的契约。
CREATE OR REPLACE FUNCTION public.change_log_rule_visible(p_rule text, p_table text, p_key jsonb, p_old jsonb, p_new jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_part text[] := string_to_array(p_rule, ':');
    v_fid  text;
BEGIN
    IF p_rule = 'never' THEN
        RETURN false;
    ELSIF v_part[1] = 'code' THEN
        RETURN has_permission(v_part[2]);
    ELSIF v_part[1] = 'code_or_self' THEN
        RETURN has_permission(v_part[2])
            OR COALESCE(change_log_field(p_table, p_key, p_old, p_new, v_part[3]) = current_user_employee()::text, false);
    ELSIF v_part[1] = 'pay_journal' THEN
        RETURN has_permission(v_part[2])
            OR COALESCE(change_log_field('journal_entries',
                            jsonb_build_object('id', change_log_field(p_table, p_key, p_old, p_new, 'entry_id')),
                            NULL, NULL, 'source_type') <> 'payroll', false);
    ELSIF p_rule = 'apr_amount' THEN
        RETURN COALESCE(approval_log_amount_visible(change_log_field(p_table, p_key, p_old, p_new, 'subject_type'),
                                                    change_log_field(p_table, p_key, p_old, p_new, 'subject_id')::uuid), false);
    ELSIF p_rule = 'apr_note' THEN
        RETURN COALESCE(approval_log_note_visible(change_log_field(p_table, p_key, p_old, p_new, 'subject_type'),
                                                  change_log_field(p_table, p_key, p_old, p_new, 'subject_id')::uuid), false);
    ELSIF p_rule = 'jr_amount' THEN
        RETURN COALESCE(journal_request_amount_visible(change_log_field(p_table, p_key, p_old, p_new, 'id')::uuid), false);
    ELSIF p_rule = 'pft:direction' THEN
        RETURN pricing_formula_terms_visible(change_log_field(p_table, p_key, p_old, p_new, 'direction'));
    ELSIF p_rule IN ('pft:formula_id', 'pft3') THEN
        v_fid := change_log_field(p_table, p_key, p_old, p_new, 'formula_id');
        IF NOT pricing_formula_terms_visible(
               change_log_field('pricing_formulas', jsonb_build_object('id', v_fid), NULL, NULL, 'direction')) THEN
            RETURN false;
        END IF;
        IF p_rule = 'pft:formula_id' THEN
            RETURN true;
        END IF;
        RETURN pricing_formula_terms_visible(COALESCE(change_log_field(p_table, p_key, p_old, p_new, 'old_direction'), 'both'))
           AND pricing_formula_terms_visible(COALESCE(change_log_field(p_table, p_key, p_old, p_new, 'new_direction'), 'both'));
    END IF;
    RETURN false;
END;
$function$;

-- db/functions/trail_subjects.sql
-- AUDIT-TRAIL-1a(Tim 的 Q5):审计记录的【主语登记表】。页面只说"哪一种记录、哪一条",从不说表名;
--   表名、根键、以及【这一页自己的查看权限码】只住在这里(服务端)。不在这里的主语 → TRAIL_SUBJECT_UNKNOWN。
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M1 · M3 · M6)多了三列:
--   view_codes   【任一】即可进(M1)—— 与页面守卫同一组码。一页只认一个码时就是一个元素的数组。
--                warehouse_request:/inventory 那一块(module.inventory.view)与财务(module.finance.view)都读它。
--   root_rule    (AUDIT-TRAIL-1d-1 多了两种:'collection' —— M11,一张表整张是一条记录;'gate:<名字>' —— M12,比表的规则更窄)
--                'table'(默认):根行还要过它自己那张表的读规则,过不了 → TRAIL_NOT_PERMITTED。
--                'page'(M3):页面的码就是门;根行自己的那几次改动照子行的规矩走 —— 读者过不了根表的读规则,
--                那几条就是 Restricted(Q4)。equipment 用它:根表 fixed_assets 只给财务读,而这一页给加工的人。
--   root_columns 非空(M6):根行只取这几列的改动(一块面板只管它自己编辑的那几个字段,Q25 的同一条规矩)。
--                NULL = 整行。1b-3 的三个阈值面板会用到它;本刀先建好,fixture 237 用一个临时主语证它。
-- view_codes 与页面守卫逐字同一组码:
--   purchase_order → /purchasing/orders/[id]        requireModule(MOD.purchasing) = module.purchasing.view
--   processing_run → /operation/processing/[id]     requireModule(MOD.processing) = module.processing.view
--   role           → /settings/roles/[id]           requireManagePermissions()     = action.manage_permissions
--   inbound_batch  → /inbound/[id]/edit             requireModule(MOD.inbound)     = module.inbound.view
--   output_batch   → /output/[id]/edit              requireModule(MOD.output)      = module.output.view
--   work_order     → /operation/orders/[id]         requireModule(MOD.processing)  = module.processing.view
--   stocktake      → /stocktakes/[id]               requireModule(MOD.stocktakes)  = module.stocktakes.view
--   equipment      → /operation/equipment/[id]      requireModule(MOD.processing)  = module.processing.view
--   shift_handover → /operation/handovers/[id]      requireModule(MOD.processing)  = module.processing.view
--   warehouse_request → /inventory 的申请一块        requireModule(MOD.inventory)   = module.inventory.view(+ 财务)
-- AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a 的商务那一半):
--   quote          → /sales/quotes/[id]              requireModule(MOD.sales)       = module.sales.view
--   sales_order    → /sales/orders/[id]              requireModule(MOD.sales)       = module.sales.view
--   shipment       → /sales/shipments/[id]           action.ship_goods,否则 requireModule(MOD.sales)(M1:任一)
--   customer       → /sales/customers/[id]           requireModule(MOD.customers)   = module.customers.view
--   commission_agreement → /sales/commissions/[id]/edit(只有这一页,Q2)requireModule(MOD.suppliers) = module.suppliers.view
--   supplier       → /suppliers/[id]/edit(只有这一页,Q2)requireModule(MOD.suppliers) = module.suppliers.view
--   container      → /logistics/containers/[id]      requireModule(MOD.logistics)   = module.logistics.view
--   forwarder      → /logistics/forwarders/[id]      requireModule(MOD.logistics)   = module.logistics.view
--                    根表是 suppliers(读规则 module.suppliers.view)—— M3:页面的码是门,根行自己的改动逐行判
--   lane · port    → /logistics/lanes(只有清单页,按条合起来,见 app/components/trail/ListTrail.tsx)module.logistics.view
--   company_licence → /purchasing/licences(只有清单页)门是 module.purchasing.view,而这张表的读规则是
--                    module.suppliers.view —— 这一块只画在持 suppliers.view 的那一支里(页面本来就那样分),所以登记后者
-- AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a 的主数据与工具):
--   material       → /materials/[id]/edit(只有这一页,Q2)requireModule(MOD.materials) = module.materials.view
--   storage_location → /inventory/locations/[id]/edit(只有这一页)requireModule(MOD.inventory) = module.inventory.view
--   metal_price    → /tools/pricing/metal-prices/[id]/edit(只有这一页)requireEditPermission('action.metal_prices')
--   pricing_formula → /tools/pricing/formulas/[id]/edit(只有这一页)requireModule(MOD.pricing) = module.pricing.view
--   task           → /tools/tasks/[id]                requireModule(MOD.tasks)       = module.tasks.view
--                    私人任务也读得到(Q3):根行要过 tasks 自己的读规则(团队任务 · 自己的 · 或持 module.tasks.view_all)——
--                    那正是"谁打得开这一页"的同一个判据,而遮蔽那一步本来就先问任务隐私
--   processing_settings → /operation/orders 的工单阈值面板          module.processing.view;M6:只取面板编辑的两列
--   pricing_settings    → /tools/pricing/metal-prices 的异常阈值面板  module.pricing.view;M6:只取那一列
--   receiving_settings  → /purchasing/discrepancies 的收货阈值面板   module.inbound.view(面板只画在这一支里);M6:三列
--                    三张都是单行表,主键 id boolean —— M5:页面传 'true',读法按根行自己的类型重建那个键
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第一刀:账上的单据):
--   journal_entry   → /finance/journal/[id]             requireModule(MOD.finance)     = module.finance.view
--   invoice         → /finance/invoices/[id]            requireModule(MOD.finance)     = module.finance.view
--   credit_note     → /finance/credit-notes/[id]        requireModule(MOD.finance)     = module.finance.view
--   payment         → /finance/payments/[id]            requireModule(MOD.finance)     = module.finance.view
--   payment_request → /finance/payment-requests/[id]    requireModule(MOD.finance)     = module.finance.view
--                    (行内转账、代扣税缴纳与它们的冲销也住在这一页 —— 它们没有自己的页,Q17)
--   expense         → /finance/expenses/[id]            requireModule(MOD.finance)     = module.finance.view
--   payable         → /finance/payables/[batchId]       requireModule(MOD.finance)     = module.finance.view
--                    根表是 inbound_batches(读规则 module.inbound.view)—— M3:页面的码是门(Q5,forwarder 的先例);
--                    M6:只取应付那几列(数量、单价、供应商、采购单、计价状态、到货日、注销三列)—— 批次的仓库那一面
--                    (化验、安全状态、库位……)住在 /inbound/[id]/edit 的 inbound_batch 上,不在应付页上再说一遍。
--                    注销那三列必须在里面:M6 丢掉 root_columns 之外的戳(record_trail),不在里面注销就看不见(Q5 的横幅)。
-- AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第二刀:其余的单据与合同):
--   sale            → /finance/receivables/[saleId]     requireModule(MOD.finance)     = module.finance.view
--   freight         → /finance/freight/[id]             requireModule(MOD.finance)     = module.finance.view
--                    (根表的读规则是 inbound.view OR finance.view,再加一条 finance.edit 的 ALL —— 页面的码过得了,不需要 M3)
--   fixed_asset     → /finance/assets/[id]              requireModule(MOD.finance)     = module.finance.view
--                    根表与 equipment 同一张 fixed_assets(supplier / forwarder 的先例:一张表两个主语,Q10)——
--                    equipment 的门是加工,这一页的门是财务;根表的读规则就是 finance.view,所以是 'table'
--   bank_statement  → /finance/bank/statements/[id]     requireModule(MOD.finance)     = module.finance.view
--                    删掉的对账单也读得到(Q6:持 data.view_deleted 的人只读打开;根表的读规则不过滤已删的行)
--   gst_period      → /finance/gst/[periodId]           requireModule(MOD.finance)     = module.finance.view
--   fx_rate         → /finance/fx/[id]/edit(只有这一页,Q2)requireModule(MOD.finance) = module.finance.view
--                    撤回了的汇率也读得到(Q7:页面对本来的读者只读打开)
--   management_pack → /finance/packs/[id]               requireModule(MOD.finance)     = module.finance.view
--   contract        → /contracts/[id]                   requireModule(MOD.suppliers)   = module.suppliers.view
--                    根表的读规则按方向:卖方合同要 customers.view、买方合同要 suppliers.view —— 页面在 RLS 下读、读不到就 404,
--                    所以 'table' 与页面同一个答案(看不见的合同对他而言不存在)
-- AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第三刀:期末、设置与清单页上的记录):
--   finance_lock    → /finance/settings 锁期面板之下 · /finance/close 关账史之下(Q25 · Q29)  module.finance.view
--                    根表 finance_settings(单行,id boolean —— M5,页面传 'true');M6:只取 locked_before 一列;
--                    月结 / 反结(period_closes)经 M7 整张表属于这一行(两张表之间一个键都没有,Q3)
--   finance_gst     → /finance/settings GST 面板之下                                       module.finance.view
--                    同一行(M5);M6:只取 gst_registered、gst_registration_no 两列 —— 两块面板各看各的(Q25);
--                    这一行上没有面板的六列(gst_rate_pct · system_start_date · 三个财年列 · default_allocation_basis)
--                    哪一块都不取,只在 /settings/change-history 上找得到(Q4);审批方针那四列归 AT-1d(Q2)
--   company_profile → /finance/company                                                     requireModule(MOD.finance)
--                    单行(M5),整行 —— 一块面板编辑整行;银行那五列按 HISTORY-1 的规则对不持 data.view_banking 的人遮
--   year_close      → /finance/close 年结那一块(清单块,ListTrail)                          module.finance.view
--   journal_request → /finance/journal 每一张申请卡片里(Q17,一张一块)                     module.finance.view
--   expense_claim   → /finance/claims 每一张报销单一块(Q20)                                module.finance.view
--   my_expense_claim → /me 报销人自己那几张(Q20 的另一半)—— ★ M8:没有页面码(view_codes 为空数组),
--                    根行自己那张表的读规则就是门(expense_claims:module.finance.view 或者【这张单说的就是你】);
--                    只许与 'table' 同用(record_trail 里拒绝 'page' —— 那会对每一个人敞开)。
--                    审批留痕那一支(approval_log 的 expense_claim)不给本人开口子,所以本人看到的是 Restricted(Q4)
--   bank_transfer   → /finance/bank 转账那一块(清单块)                                     module.finance.view
--   wht_remittance  → /finance/wht 缴纳那一块(清单块)                                      module.finance.view
--   cash_forecast · cash_forecast_line → /finance/cash-forecast(清单块,Q16:冻结 + 作废旧的一张是一次操作)
--   bank_import_profile → /finance/bank/import(清单块,删掉的也读)                         module.finance.view
--   (重估 / 折旧 / 工资付款 / 加工成本结算的批次与批量汇率【不】另立主语:它们各自的清单块读 journal_entry · expense ·
--    fx_rate 那几个现成主语,Q16 的 op_key 把一次操作并成一条 —— Q18 · Q19)
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第一刀:机制、设置与员工):
--   account         → /settings/accounts 每一行一块(Q24)        requireManagePermissions()     = action.manage_permissions
--                    ★ M9:根表 auth.users 不在 public 里 —— trail_log_only_tables() 给它一份安全投影与声明的读码;
--                    事件(建立 / 停用 / 恢复 / 失败 / 回滚)住在 change_log(record_account_event)
--   approval_policy → /settings/approvals(Q25,1c 的 Q2 挪过来)requireFunction(FN.approvals) = action.manage_permissions
--                    同一行 finance_settings(M5);M6:只取它编辑的四列;修改史 finance_settings_history 经 M7 整张属于这一行。
--                    根表的读规则是 module.finance.view —— 'table':读者两个码都要(线上唯一持 manage_permissions 的 admin 两个都有,Q23)
--   employee        → /hr/employees/[id]                        requireModule(MOD.hr)          = module.hr.view
--                    根表的读规则是 hr.view 或【这就是你】—— 与页面同一个答案
--   department      → /hr/departments/[id]/edit(只有这一页)   requireModule(MOD.hr)          = module.hr.view
--   training_record → /hr/training/[id]/edit(只有这一页,Q29) requireModule(MOD.hr)          = module.hr.view
--   import_batch    → /settings/import 的批次一块(清单块,Q24) can('action.bulk_import')      = action.bulk_import
--   dictionary_*    → /settings/dictionaries 每一段一块(Q4)    每一段自己的查看码(registry.ts 的 viewPermission)
--                    ★ M11:'collection' —— 没有根行,那张字典表的每一行、change_log 里它的每一行都属于这一块;根键照写那张表的主键
--                    (code),record_trail 不用它。
--   ☞ M12('gate:reviewer')本刀没有主语用它(它的第一个用户是 AT-1d-3 的 /my-reviews —— 1d-3 已接上,见下面 my_review);fixture 244 用一个临时主语证它。
-- AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第二刀:请假与考勤):
--   leave_request     → /hr/leave/[id]                  requireModule(MOD.hr)          = module.hr.view
--                    根表的读规则是 hr.view 或【这张单说的就是你】—— 与页面同一个答案
--   my_leave_request  → /me 本人那几张(Q14,M8:没有页面码 —— 根行自己的读规则就是门;审批与消耗那几行对本人是 Restricted)
--   leave_grant       → /hr/leave/grants 那一块(清单块,按年)         module.hr.view
--   leave_types       → /hr/leave/types(M11 集合,根键 code)         module.hr.view
--   public_holidays   → /hr/leave/holidays(M11 集合 —— 假期是【硬删】的,一行删掉之后只剩变更记录里那一份影像)
--   medical_claim     → /hr/claims/[id]                 requireModule(MOD.hr)          = module.hr.view
--   my_medical_claim  → /me 本人那几张(Q14,M8)
--   overtime_batch    → /hr/overtime/[id]               requireFunction(FN.overtime)   = M1:hr.view · overtime_enter · overtime_approve
--                    (与页面守卫、与 overtime_batches 的读规则逐字同一组码)
--   attendance_period → /hr/attendance/[id]             requireModule(MOD.hr)          = module.hr.view
-- AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第三刀:工资与评审):
--   payroll_period      → /hr/payroll/[id]              requireModule(MOD.hr)          = module.hr.view
--                      根表的读规则是 hr.view —— 与页面同一个答案;工资行的金额对不持 data.view_pay 的人照遮蔽规则说 Restricted
--   performance_review  → /hr/reviews/[id]              requireModule(MOD.hr)          = module.hr.view
--                      根表的读规则是 (hr.view 且 view_reviews) 或审核人 或【这是你的、已批】—— 页面读 performance_reviews_masked,
--                      同一个谓词,读不到就 notFound;所以 auditor / finance(hr.view,不持 view_reviews)两边都进不去
--   my_review           → /my-reviews/[id](审核人那一页,没有模块守卫)  M8 + M12:没有页面码,root_rule 'gate:reviewer' ——
--                      根行先过表的读规则,【再】过 trail_root_gate('reviewer'):只给这一份评审点名的审核人,
--                      不给被评审的本人(他在批准之后经"own approved"那一条读得到行,但这一段不是给他的,Q5)
--   review_cycle        → /hr/reviews/cycles 那一块(清单块,每一轮一条)   module.hr.view(Q6:没有成员 —— 开轮时铺下的那几份评审
--                      不挂进来,轮次那一块只说"开了 / 关了";每一份评审自己的那一段以"Annual review opened (cycle …)"开头)
--   review_rating_scale → /hr/reviews/scale(M11 集合,根键 code)      module.hr.view
--   kpi_entry           → /hr/kpi/score 那一块(清单块,选中那一个月的条目;只在 canSeeScores 那一支里画)  module.hr.view
--                      根表的读规则是 (hr.view 且 view_reviews) 或本人 —— 不持 view_reviews 的读者在页面那一支就进不来
-- 【后面几刀加主语】加一行这里、在 trail_subject_members 里登记它的子行与相关行、需要的话在
--   trail_prelog_sources 里登记"记录开始之前"的来源,然后在 lib/trail/ 里补它的措辞 —— 见 docs/change-log.md §9。
-- MES-1(2026-10-06,MES-1 Step 0 Q21 · Q22,Tim):
--   device          → /operation/devices/[id]           requireModule(MOD.processing) = module.processing.view
--                     成员 gateway_keys(钥匙的发放与撤销;哈希被 never 规则遮住)。收件箱、传输日志与中断不进变更记录(MES-0 Q14),
--                     所以不在这里 —— 设备页把中断单独列成一块(Q21)。
--   ingest_settings → /operation/devices 上的传输上限面板  module.processing.view;单行设置作根(M5),修改史就是变更记录(Q22)
CREATE OR REPLACE FUNCTION public.trail_subjects()
 RETURNS TABLE(subject text, view_codes text[], root_table text, root_key text, root_rule text, root_columns text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('purchase_order',    ARRAY['module.purchasing.view'],    'purchase_orders',    'id', 'table', NULL::text[]),
        ('processing_run',    ARRAY['module.processing.view'],    'processing_runs',    'id', 'table', NULL),
        ('role',              ARRAY['action.manage_permissions'], 'roles',              'id', 'table', NULL),
        ('inbound_batch',     ARRAY['module.inbound.view'],       'inbound_batches',    'id', 'table', NULL),
        ('output_batch',      ARRAY['module.output.view'],        'output_batches',     'id', 'table', NULL),
        ('work_order',        ARRAY['module.processing.view'],    'work_orders',        'id', 'table', NULL),
        ('stocktake',         ARRAY['module.stocktakes.view'],    'stocktakes',         'id', 'table', NULL),
        ('equipment',         ARRAY['module.processing.view'],    'fixed_assets',       'id', 'page',  NULL),
        ('shift_handover',    ARRAY['module.processing.view'],    'shift_handovers',    'id', 'table', NULL),
        ('warehouse_request', ARRAY['module.inventory.view', 'module.finance.view'], 'warehouse_requests', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-2
        ('quote',             ARRAY['module.sales.view'],         'quotes',             'id', 'table', NULL),
        ('sales_order',       ARRAY['module.sales.view'],         'sales_orders',       'id', 'table', NULL),
        ('shipment',          ARRAY['module.sales.view', 'action.ship_goods'], 'shipments', 'id', 'table', NULL),
        ('customer',          ARRAY['module.customers.view'],     'customers',          'id', 'table', NULL),
        ('commission_agreement', ARRAY['module.suppliers.view'],  'commission_agreements', 'id', 'table', NULL),
        ('supplier',          ARRAY['module.suppliers.view'],     'suppliers',          'id', 'table', NULL),
        ('container',         ARRAY['module.logistics.view'],     'containers',         'id', 'table', NULL),
        ('forwarder',         ARRAY['module.logistics.view'],     'suppliers',          'id', 'page',  NULL),
        ('lane',              ARRAY['module.logistics.view'],     'lanes',              'id', 'table', NULL),
        ('port',              ARRAY['module.logistics.view'],     'ports',              'id', 'table', NULL),
        ('company_licence',   ARRAY['module.suppliers.view'],     'company_compliance', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-3
        ('material',          ARRAY['module.materials.view'],     'materials',          'id', 'table', NULL),
        ('storage_location',  ARRAY['module.inventory.view'],     'storage_locations',  'id', 'table', NULL),
        ('metal_price',       ARRAY['action.metal_prices'],       'metal_prices',       'id', 'table', NULL),
        ('pricing_formula',   ARRAY['module.pricing.view'],       'pricing_formulas',   'id', 'table', NULL),
        ('task',              ARRAY['module.tasks.view'],         'tasks',              'id', 'table', NULL),
        ('processing_settings', ARRAY['module.processing.view'],  'processing_settings', 'id', 'table',
            ARRAY['wo_input_overrun_pct', 'wo_output_shortfall_pct']),
        ('pricing_settings',  ARRAY['module.pricing.view'],       'pricing_settings',   'id', 'table',
            ARRAY['metal_price_change_warn_pct']),
        ('receiving_settings', ARRAY['module.inbound.view'],      'receiving_settings', 'id', 'table',
            ARRAY['grn_short_pct', 'grn_over_pct', 'grn_assay_tolerance_pct']),
        -- AUDIT-TRAIL-1c-1
        ('journal_entry',     ARRAY['module.finance.view'],       'journal_entries',    'id', 'table', NULL),
        ('invoice',           ARRAY['module.finance.view'],       'invoices',           'id', 'table', NULL),
        ('credit_note',       ARRAY['module.finance.view'],       'credit_notes',       'id', 'table', NULL),
        ('payment',           ARRAY['module.finance.view'],       'payments',           'id', 'table', NULL),
        ('payment_request',   ARRAY['module.finance.view'],       'payment_requests',   'id', 'table', NULL),
        ('expense',           ARRAY['module.finance.view'],       'expenses',           'id', 'table', NULL),
        ('payable',           ARRAY['module.finance.view'],       'inbound_batches',    'id', 'page',
            ARRAY['supplier_id', 'purchase_order_id', 'quantity', 'unit', 'unit_price', 'pricing_status', 'arrival_date',
                  'deleted_at', 'deleted_by', 'delete_reason']),
        -- AUDIT-TRAIL-1c-2
        ('sale',              ARRAY['module.finance.view'],       'sales_records',      'id', 'table', NULL),
        ('freight',           ARRAY['module.finance.view'],       'freight_documents',  'id', 'table', NULL),
        ('fixed_asset',       ARRAY['module.finance.view'],       'fixed_assets',       'id', 'table', NULL),
        ('bank_statement',    ARRAY['module.finance.view'],       'bank_statements',    'id', 'table', NULL),
        ('gst_period',        ARRAY['module.finance.view'],       'gst_periods',        'id', 'table', NULL),
        ('fx_rate',           ARRAY['module.finance.view'],       'fx_rates',           'id', 'table', NULL),
        ('management_pack',   ARRAY['module.finance.view'],       'management_packs',   'id', 'table', NULL),
        ('contract',          ARRAY['module.suppliers.view'],     'contracts',          'id', 'table', NULL),
        -- AUDIT-TRAIL-1c-3
        ('finance_lock',      ARRAY['module.finance.view'],       'finance_settings',   'id', 'table', ARRAY['locked_before']),
        ('finance_gst',       ARRAY['module.finance.view'],       'finance_settings',   'id', 'table',
            ARRAY['gst_registered', 'gst_registration_no']),
        ('company_profile',   ARRAY['module.finance.view'],       'company_profile',    'id', 'table', NULL),
        ('year_close',        ARRAY['module.finance.view'],       'year_closes',        'id', 'table', NULL),
        ('journal_request',   ARRAY['module.finance.view'],       'journal_requests',   'id', 'table', NULL),
        ('expense_claim',     ARRAY['module.finance.view'],       'expense_claims',     'id', 'table', NULL),
        ('my_expense_claim',  ARRAY[]::text[],                    'expense_claims',     'id', 'table', NULL),
        ('bank_transfer',     ARRAY['module.finance.view'],       'bank_transfers',     'id', 'table', NULL),
        ('wht_remittance',    ARRAY['module.finance.view'],       'wht_remittances',    'id', 'table', NULL),
        ('cash_forecast',     ARRAY['module.finance.view'],       'cash_forecasts',     'id', 'table', NULL),
        ('cash_forecast_line', ARRAY['module.finance.view'],      'cash_forecast_lines', 'id', 'table', NULL),
        ('bank_import_profile', ARRAY['module.finance.view'],     'bank_import_profiles', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1d-1
        ('account',           ARRAY['action.manage_permissions'], 'auth.users',         'id', 'table', NULL),
        ('approval_policy',   ARRAY['action.manage_permissions'], 'finance_settings',   'id', 'table',
            ARRAY['approvals_enabled', 'approval_threshold_base', 'approval_level1_role_code', 'approval_level2_role_code']),
        ('employee',          ARRAY['module.hr.view'],            'employees',          'id', 'table', NULL),
        ('department',        ARRAY['module.hr.view'],            'departments',        'id', 'table', NULL),
        ('training_record',   ARRAY['module.hr.view'],            'training_records',   'id', 'table', NULL),
        ('import_batch',      ARRAY['action.bulk_import'],        'import_batches',     'id', 'table', NULL),
        ('dictionary_substances',          ARRAY['module.materials.view'], 'substances',             'code', 'collection', NULL),
        ('dictionary_battery_chemistries', ARRAY['module.materials.view'], 'battery_chemistries',    'code', 'collection', NULL),
        ('dictionary_material_kinds',      ARRAY['module.materials.view'], 'material_kinds',         'code', 'collection', NULL),
        ('dictionary_inbound_safety_states', ARRAY['module.materials.view'], 'inbound_safety_states', 'code', 'collection', NULL),
        ('dictionary_laboratories',        ARRAY['module.inbound.view'],   'laboratories',           'code', 'collection', NULL),
        ('dictionary_inbound_source_reasons', ARRAY['module.inbound.view'], 'inbound_source_reasons', 'code', 'collection', NULL),
        -- AUDIT-TRAIL-1d-2
        ('leave_request',     ARRAY['module.hr.view'],            'leave_requests',     'id', 'table', NULL),
        ('my_leave_request',  ARRAY[]::text[],                    'leave_requests',     'id', 'table', NULL),
        ('leave_grant',       ARRAY['module.hr.view'],            'leave_grants',       'id', 'table', NULL),
        ('leave_types',       ARRAY['module.hr.view'],            'leave_types',        'code', 'collection', NULL),
        ('public_holidays',   ARRAY['module.hr.view'],            'public_holidays',    'id', 'collection', NULL),
        ('medical_claim',     ARRAY['module.hr.view'],            'medical_claims',     'id', 'table', NULL),
        ('my_medical_claim',  ARRAY[]::text[],                    'medical_claims',     'id', 'table', NULL),
        ('overtime_batch',    ARRAY['module.hr.view', 'action.overtime_enter', 'action.overtime_approve'], 'overtime_batches', 'id', 'table', NULL),
        ('attendance_period', ARRAY['module.hr.view'],            'attendance_periods', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1d-3
        ('payroll_period',      ARRAY['module.hr.view'],          'payroll_periods',     'id', 'table', NULL),
        ('performance_review',  ARRAY['module.hr.view'],          'performance_reviews', 'id', 'table', NULL),
        ('my_review',           ARRAY[]::text[],                  'performance_reviews', 'id', 'gate:reviewer', NULL),
        ('review_cycle',        ARRAY['module.hr.view'],          'review_cycles',       'id', 'table', NULL),
        ('review_rating_scale', ARRAY['module.hr.view'],          'review_rating_scale', 'code', 'collection', NULL),
        ('kpi_entry',           ARRAY['module.hr.view'],          'kpi_entries',         'id', 'table', NULL),
        -- MES-1
        ('device',              ARRAY['module.processing.view'],  'devices',             'id', 'table', NULL),
        ('ingest_settings',     ARRAY['module.processing.view'],  'ingest_settings',     'id', 'table', NULL)
    ) AS s(subject, view_codes, root_table, root_key, root_rule, root_columns);
$function$;

-- db/functions/trail_subject_members.sql
-- AUDIT-TRAIL-1a(Tim 的 Q3 · Q6):一个主语的审计记录【由哪些行组成】—— 根行之外的子行与相关行。
--   每一行说:这张表里 fk_column 等于 parent_table 某一行的 id 的那些行,属于这条记录;match 是额外的固定条件
--   (多态的 approval_log 靠 subject_type 认主)。parent_table 可以是另一张子表(孙行:付款保留金挂在明细行上)。
--   按 ord 依次展开,所以孙行排在它的父行之后。
-- 【子行是在读的时候找出来的】(Q6)—— 不在记录上写父键。找法见 record_trail:今天还在的行按外键查,
--   已经删掉或改过父键的行从 change_log 的影像里查(GIN 索引 idx_change_log_image / idx_change_log_update_old)。
-- 【每一行子行都要再过一次它自己那张表的读规则】(Q4)—— 由 record_trail 调 trail_row_visible 做,不在这里。
--
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M4 与 Q4)多了三列:
--   hop    'down'(默认):table.fk_column = parent 那一行的 id(往下走)。
--          'up'(M4):table.id = parent 那一行的 fk_column(往上走一跳 —— 批次 → 消耗它的加工单、它收货的采购单)。
--   shown  true:这张表的行是这条记录的一部分,它们的每一次改动都进审计记录。
--          false:【垫脚石】—— 只用来够到它下面的行,它自己的改动不进来(Q4:"只限碰到这个批次的那些事")。
--          批次的审计记录经由加工单够到那张单的成本修改、分录与工单的审批,但加工单本身的编辑不在批次上。
--   home   true:这张表的行【住在】这个主语下 —— /settings/change-history 的"Record"一栏沿 home 的那一条往上走
--          (trail_row_record)。同一张表挂在两个主语下时(加工投入既属于加工单、也出现在批次上),只有一处是家。
--   原来旧批次审计记录那 20 支(db/views/batch_audit_trail_all.sql)的每一支都在下面有它的来处 ——
--   fixture 238 逐行对照两边,少一行就红。
CREATE OR REPLACE FUNCTION public.trail_subject_members()
 RETURNS TABLE(subject text, ord integer, table_name text, parent_table text, fk_column text, match jsonb, hop text, shown boolean, home boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        -- 采购单:明细行 · 付款计划 · 保留金 · 条款承诺 · 签发 · 合同条款 · 审批 · 修改史(Tim 的 AT-1a 范围)
        ('purchase_order', 1, 'purchase_order_lines',           'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 2, 'purchase_order_payment_terms',   'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 3, 'purchase_order_line_retentions', 'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 4, 'pricing_term_commitments',       'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 5, 'po_issues',                      'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 6, 'contract_document_terms',        'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 7, 'approval_log',                   'purchase_orders',      'subject_id',             '{"subject_type": "purchase_order"}'::jsonb, 'down', true, true),
        ('purchase_order', 8, 'purchase_order_history',         'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        -- 加工单:投入 · 产出 · 成本条目及其修改史 · 成本分摊 · 损耗;1b-1 加:回滚申请及其审批(Q12)
        ('processing_run', 1, 'processing_inputs',                 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 2, 'processing_outputs',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 3, 'processing_cost_entries',           'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 4, 'processing_cost_entry_history',     'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 5, 'batch_processing_cost_allocations', 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 6, 'processing_run_losses',             'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 7, 'warehouse_requests',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, false),
        ('processing_run', 8, 'approval_log',                      'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        -- 角色:授权(加上 / 拿掉);AUDIT-TRAIL-1d-1 加:授给了谁(Q22 —— 家在账号那一边:授出去的是那个账号)
        ('role', 1, 'role_permissions', 'roles', 'role_id', '{}'::jsonb, 'down', true, true),
        ('role', 2, 'user_roles',       'roles', 'role_id', '{}'::jsonb, 'down', true, false),

        -- ── 进料批次(1b-1)────────────────────────────────────────────────────────────────────────────
        -- 批次自己的:金属含量 · 化验与化验的金属 · 安全状态 · 价格 · 收货定价申请与它的审批 · 预付款核销 · 条款承诺 ·
        --   库存流水 · 盘点行与盘点的每一次清点 · 加工投入 · 成本分摊 · 销毁证书与签发 · 仓库申请(注销、证书作废)与它的审批 ·
        --   运费分摊 · 付款核销 · 财务附件
        ('inbound_batch',  1, 'inbound_batch_metals',              'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  2, 'assay_results',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  3, 'assay_result_metals',               'assay_results',               'assay_result_id',  '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  4, 'inbound_batch_safety_states',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  5, 'price_history',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  6, 'receipt_price_requests',            'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  7, 'approval_log',                      'receipt_price_requests',      'subject_id',       '{"subject_type": "receipt_price_request"}'::jsonb, 'down', true, true),
        ('inbound_batch',  8, 'prepayment_applications',           'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  9, 'pricing_term_commitments',          'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 10, 'pricing_term_commitment_metals',    'pricing_term_commitments',    'commitment_id',    '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 11, 'inventory_movements',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 12, 'stocktake_lines',                   'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 13, 'stocktake_counts',                  'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 14, 'processing_inputs',                 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 15, 'batch_processing_cost_allocations', 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 16, 'certificates_of_destruction',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 17, 'cod_issues',                        'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 18, 'warehouse_requests',                'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 19, 'warehouse_requests',                'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 20, 'approval_log',                      'warehouse_requests',          'subject_id',       '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch', 21, 'freight_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 22, 'payment_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 23, 'finance_attachments',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4),只取碰到这个批次的那些事:
        --   它收货的采购单 → 那张单的审批与修改史(旧 approval / po_change 两支)
        ('inbound_batch', 24, 'purchase_orders',                   'inbound_batches',             'purchase_order_id', '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 25, 'approval_log',                      'purchase_orders',             'subject_id',        '{"subject_type": "purchase_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 26, 'purchase_order_history',            'purchase_orders',             'purchase_order_id', '{}'::jsonb, 'down', true,  false),
        --   消耗它的加工单 → 那张单的成本修改史、成本条目(垫脚石)、工单(垫脚石)→ 工单的审批与修改史
        ('inbound_batch', 27, 'processing_runs',                   'processing_inputs',           'run_id',            '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 28, 'processing_cost_entry_history',     'processing_runs',             'run_id',            '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 29, 'processing_cost_entries',           'processing_runs',             'run_id',            '{}'::jsonb, 'down', false, false),
        ('inbound_batch', 30, 'work_orders',                       'processing_runs',             'work_order_id',     '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 31, 'approval_log',                      'work_orders',                 'subject_id',        '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 32, 'work_order_history',                'work_orders',                 'work_order_id',     '{}'::jsonb, 'down', true,  false),
        --   盘点过它的那一次盘点(垫脚石)→ 那次盘点过账的分录
        ('inbound_batch', 33, 'stocktakes',                        'stocktake_lines',             'stocktake_id',      '{}'::jsonb, 'up',  false, false),
        --   分录:直接挂在批次上的(计价、注销)· 预付款核销的 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('inbound_batch', 34, 'journal_entries',                   'inbound_batches',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 35, 'journal_entries',                   'prepayment_applications',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 36, 'journal_entries',                   'processing_cost_entries',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 37, 'journal_entries',                   'processing_runs',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 38, 'journal_entries',                   'stocktakes',                  'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 39, 'journal_entries',                   'journal_entries',             'reversed_by',       '{}'::jsonb, 'up',  true,  false),

        -- ── 产出批次(1b-1)────────────────────────────────────────────────────────────────────────────
        ('output_batch',  1, 'output_batch_metals',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  2, 'assay_results',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  3, 'assay_result_metals',               'assay_results',      'assay_result_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  4, 'output_batch_safety_states',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  5, 'inventory_movements',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  6, 'processing_outputs',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  7, 'processing_inputs',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  8, 'stocktake_lines',                   'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  9, 'stocktake_counts',                  'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 10, 'warehouse_requests',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 11, 'approval_log',                      'warehouse_requests', 'subject_id',      '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch', 12, 'sales_records',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 13, 'sales_record_movements',            'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 14, 'sales_attribution_log',             'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 15, 'invoice_lines',                     'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 16, 'payment_allocations',               'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 17, 'sales_order_reservations',          'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 18, 'shipment_lines',                    'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 19, 'traceability_report_issues',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 20, 'sales_settlements',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4):产出它 / 消耗它的加工单 → 成本修改史、成本条目(垫脚石)、工单 → 审批与修改史;
        --   盘点过它的盘点(垫脚石);它的销售对应的订单行(垫脚石)→ 那一行的订单修改史(旧 so_change 一支)
        ('output_batch', 21, 'processing_runs',                   'processing_outputs', 'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 22, 'processing_runs',                   'processing_inputs',  'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 23, 'processing_cost_entry_history',     'processing_runs',    'run_id',              '{}'::jsonb, 'down', true,  false),
        ('output_batch', 24, 'processing_cost_entries',           'processing_runs',    'run_id',              '{}'::jsonb, 'down', false, false),
        ('output_batch', 25, 'work_orders',                       'processing_runs',    'work_order_id',       '{}'::jsonb, 'up',  false, false),
        ('output_batch', 26, 'approval_log',                      'work_orders',        'subject_id',          '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('output_batch', 27, 'work_order_history',                'work_orders',        'work_order_id',       '{}'::jsonb, 'down', true,  false),
        ('output_batch', 28, 'stocktakes',                        'stocktake_lines',    'stocktake_id',        '{}'::jsonb, 'up',  false, false),
        ('output_batch', 29, 'sales_order_lines',                 'sales_records',      'sales_order_line_id', '{}'::jsonb, 'up',  false, false),
        ('output_batch', 30, 'sales_order_history',               'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true,  false),
        --   分录:注销(直接挂在批次上)· 销售与发货的成本 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('output_batch', 31, 'journal_entries',                   'output_batches',     'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 32, 'journal_entries',                   'sales_records',      'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 33, 'journal_entries',                   'processing_cost_entries', 'source_id',      '{}'::jsonb, 'down', true,  false),
        ('output_batch', 34, 'journal_entries',                   'processing_runs',    'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 35, 'journal_entries',                   'stocktakes',         'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 36, 'journal_entries',                   'journal_entries',    'reversed_by',         '{}'::jsonb, 'up',  true,  false),

        -- ── 工单(1b-1):明细 · 预期产出 · 修改史 · 放行审批 ─────────────────────────────────────────────
        ('work_order', 1, 'work_order_lines',            'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 2, 'work_order_expected_outputs', 'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 3, 'work_order_history',          'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 4, 'approval_log',                'work_orders', 'subject_id',    '{"subject_type": "work_order"}'::jsonb, 'down', true, true),

        -- ── 盘点(1b-1):盘点行 · 每一次清点 · 过账审批 · 过账分录(财务读)─────────────────────────────────
        ('stocktake', 1, 'stocktake_lines',  'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 2, 'stocktake_counts', 'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 3, 'approval_log',     'stocktakes', 'subject_id',   '{"subject_type": "stocktake"}'::jsonb, 'down', true, true),
        ('stocktake', 4, 'journal_entries',  'stocktakes', 'source_id',    '{"source_type": "stocktake"}'::jsonb, 'down', true, false),

        -- ── 设备(1b-1,Q22):保养维修 · 停机 · 保养周期 · 交接班里提到的那次停机 ────────────────────────────
        ('equipment', 1, 'equipment_maintenance',         'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 2, 'equipment_downtime',            'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 3, 'equipment_service_intervals',   'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 4, 'shift_handover_equipment_refs', 'equipment_downtime', 'downtime_id',  '{}'::jsonb, 'down', true, false),

        -- ── 交接班(1b-1,Q23):交接事项 · 提到的停机 ───────────────────────────────────────────────────
        ('shift_handover', 1, 'shift_handover_items',          'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),
        ('shift_handover', 2, 'shift_handover_equipment_refs', 'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),

        -- ── 仓库申请(1b-1,Q12):/inventory 那一块 —— 申请本身与它的审批 ─────────────────────────────────
        ('warehouse_request', 1, 'approval_log', 'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a)· 商务:报价、订单、发货、客户、佣金、供应商、物流 ══
        -- ── 报价:明细(硬删的行从影像里找)· 签发档 · 事件史 ─────────────────────────────────────────
        ('quote', 1, 'quote_lines',  'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 2, 'qt_issues',    'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 3, 'quote_history', 'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        -- ── 销售订单:明细 · 明细的预留 · 发货放行与它的明细、审批 · 签发档 · 事件史 · 合同条款 ──────────────
        --   ★ 预留、发货单明细、订单事件史以前挂在产出批次下面(home = false);它们的【家】是这张订单 / 这张发货单,
        --     所以 /settings/change-history 的 Record 一栏从此指向订单 / 发货单(trail_row_record 只沿 home 走)。
        ('sales_order', 1, 'sales_order_lines',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 2, 'sales_order_reservations', 'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true, true),
        ('sales_order', 3, 'shipping_releases',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 4, 'shipping_release_lines',   'shipping_releases',  'release_id',          '{}'::jsonb, 'down', true, true),
        ('sales_order', 5, 'approval_log',             'shipping_releases',  'subject_id',          '{"subject_type": "shipping_release"}'::jsonb, 'down', true, true),
        ('sales_order', 6, 'so_issues',                'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 7, 'sales_order_history',      'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 8, 'contract_document_terms',  'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        -- ── 发货单(M1:销售或发货的人都读得到):明细 · 送货单签发档 ─────────────────────────────────────
        ('shipment', 1, 'shipment_lines',  'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        ('shipment', 2, 'shipment_issues', 'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        -- ── 客户:联系人 · 附件 · 信用史 · 对账单与它的签发档 · 催收与它挂的单据、承诺
        --   (后四张只给财务读 —— 读不了的人那几行是 Restricted,Q4)────────────────────────────────────
        ('customer', 1, 'counterparty_contacts',      'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 2, 'customer_attachments',       'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 3, 'customer_credit_history',    'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 4, 'customer_statements',        'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 5, 'statement_issues',           'customer_statements', 'statement_id', '{}'::jsonb, 'down', true, true),
        ('customer', 6, 'collection_chases',          'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 7, 'collection_chase_documents', 'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        ('customer', 8, 'collection_promises',        'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        -- ── 供应商:合规证书 · 附件 · 联系人 · 状态变动史 · 审批(送审、批准、驳回)────────────────────────
        ('supplier', 1, 'supplier_compliance',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 2, 'supplier_attachments',    'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 3, 'counterparty_contacts',   'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 4, 'supplier_status_history', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 5, 'approval_log',            'suppliers', 'subject_id',  '{"subject_type": "supplier"}'::jsonb, 'down', true, true),
        -- ── 集装箱:里程碑 · 单据清单 ────────────────────────────────────────────────────────────────
        ('container', 1, 'container_milestones', 'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        ('container', 2, 'container_documents',  'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        -- ── 货代(M3):物流属性(一家一行,主键就是 supplier_id)· 按航段的报价 ──────────────────────────────
        ('forwarder', 1, 'forwarder_details',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('forwarder', 2, 'forwarder_rate_quotes', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        -- ── 航段:它的单据清单;港口:从它出发、到它为止的航段(两个外键,两行)──────────────────────────────
        ('lane', 1, 'lane_document_requirements', 'lanes', 'lane_id',             '{}'::jsonb, 'down', true, true),
        ('port', 1, 'lanes',                      'ports', 'origin_port_id',      '{}'::jsonb, 'down', true, false),
        ('port', 2, 'lanes',                      'ports', 'destination_port_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a)· 主数据与工具:物料、库位、金属价格、公式、任务 ══
        -- ── 物料:附件 · 必须化验的金属(复合主键,叶子)───────────────────────────────────────────────
        ('material', 1, 'material_attachments',     'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        ('material', 2, 'material_required_metals', 'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        -- ── 库位:允许存放的废物分类(Q13:保存只改变动的那几条,一次调用 —— save_storage_location)──────────
        ('storage_location', 1, 'storage_location_allowed_classes', 'storage_locations', 'location_id', '{}'::jsonb, 'down', true, true),
        -- ── 公式:应付金属(叶子)· 修改史 · 条款申请(只给持价格码的人读,别人那一行是 Restricted,Q4)· 申请的审批 ────
        ('pricing_formula', 1, 'pricing_formula_metals',  'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 2, 'pricing_formula_history', 'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 3, 'terms_requests',          'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 4, 'approval_log',            'terms_requests',   'subject_id', '{"subject_type": "terms_request"}'::jsonb, 'down', true, true),
        -- ── 任务(Q3:私人任务也是):步骤 · 参与者 · 修改史(三张表的人都是员工 id,M2)─────────────────────
        ('task', 1, 'task_nodes',        'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 2, 'task_participants', 'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 3, 'task_history',      'tasks', 'task_id', '{}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a)· 账上的单据 ══════════════════════════════════
        -- 冲销分录的 source_id 指的是【原分录】(reverse_journal_entry_internal),不是原单据 —— 所以一张单据够到它的冲销,
        --   只走原分录的 reversed_by(往上一跳,M4;批次 ord 39 的同一个做法),绝不按 source_id = 单据 id 去找。
        -- 一张冲销分录的行【不】挂在原分录上(Q33):行(ord 1)排在冲销(ord 2)之前展开,所以只取到根分录自己的行。
        -- ── 分录:行 · 它的冲销(往上)· 它冲的那一张(往下,在冲销分录的页上)· 申请(人工分录 / 冲销)与申请的审批 ──
        ('journal_entry', 1, 'journal_lines',    'journal_entries',  'entry_id',                '{}'::jsonb, 'down', true, true),
        ('journal_entry', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('journal_entry', 3, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'down', true, false),
        ('journal_entry', 4, 'journal_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('journal_entry', 5, 'journal_requests', 'journal_entries',  'target_entry_id',         '{}'::jsonb, 'down', true, false),
        ('journal_entry', 6, 'approval_log',     'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, false),
        -- AUDIT-TRAIL-1c-3:一次折旧的分录带着它记到每一张资产卡上的那一行(/finance/assets 的折旧批次一块读这张分录;
        --   家仍是资产那一页 —— 每一张资产卡自己也有它那一行,Step 0 §a)
        ('journal_entry', 7, 'fixed_asset_depreciation', 'journal_entries', 'journal_entry_id', '{}'::jsonb, 'down', true, false),
        -- ── 发票:行 · 签发档 · 作废 / 贷项申请与它的审批 · 由它开出的贷项通知 · 核销它的收款 · 它的分录与冲销 ──────
        ('invoice', 1, 'invoice_lines',    'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 2, 'invoice_issues',   'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 3, 'invoice_requests', 'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 4, 'approval_log',     'invoice_requests', 'subject_id',              '{"subject_type": "invoice_request"}'::jsonb, 'down', true, true),
        ('invoice', 5, 'credit_notes',     'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 6, 'payment_allocations', 'invoices',      'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 7, 'journal_entries',  'invoices',         'entry_id',                '{}'::jsonb, 'up',   true, false),
        ('invoice', 8, 'journal_entries',  'invoice_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        ('invoice', 9, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        -- ── 贷项通知:行 · 签发档 · 开出它的那张申请与审批 · 它的分录 ──────────────────────────────────────────
        ('credit_note', 1, 'credit_note_lines', 'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 2, 'cn_issues',         'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 3, 'invoice_requests',  'credit_notes',     'result_credit_note_id', '{}'::jsonb, 'down', true, false),
        ('credit_note', 4, 'approval_log',      'invoice_requests', 'subject_id',            '{"subject_type": "invoice_request"}'::jsonb, 'down', true, false),
        ('credit_note', 5, 'journal_entries',   'credit_notes',     'entry_id',              '{}'::jsonb, 'up',   true, false),
        -- ── 收付款:核销行 · 附件 · 冲销它的那一笔(往上)/ 它冲的那一笔(往下,在镜像单上)· 付出它的申请 · 冲它的申请 ·
        --    申请的审批 · 它的分录与冲销 ────────────────────────────────────────────────────────────────────────
        ('payment', 1, 'payment_allocations', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, true),
        ('payment', 2, 'finance_attachments', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 3, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'up',   true, false),
        ('payment', 4, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'down', true, false),
        ('payment', 5, 'payment_requests',    'payments',         'result_payment_id',   '{}'::jsonb, 'down', true, false),
        ('payment', 6, 'payment_requests',    'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 7, 'approval_log',        'payment_requests', 'subject_id',          '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        ('payment', 8, 'journal_entries',     'payments',         'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('payment', 9, 'journal_entries',     'journal_entries',  'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 付款申请(六种:付款 · 付款冲销 · 行内转账 · 转账冲销 · 代扣税缴纳 · 缴纳冲销):审批 · 付出的那一笔 ·
        --    被冲的那一笔(垫脚石:它自己的事不是这张申请的)· 转账 · 缴纳 · 过账的分录与冲销 ──────────────────
        --    ★ 一张"代扣税缴纳"申请没有指向它造出的那一笔缴纳的外键(形状检查让 wht_remittance_id 在这一种上恒为空)——
        --      唯一的路是 申请 → result_journal_entry_id → wht_remittances.journal_entry_id(ord 8)。
        ('payment_request',  1, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, true),
        ('payment_request',  2, 'payments',         'payment_requests', 'result_payment_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  3, 'payments',         'payment_requests', 'payment_id',              '{}'::jsonb, 'up',   false, false),
        ('payment_request',  4, 'bank_transfers',   'payment_requests', 'result_transfer_id',      '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  5, 'bank_transfers',   'payment_requests', 'transfer_id',             '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  6, 'wht_remittances',  'payment_requests', 'wht_remittance_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  7, 'journal_entries',  'payment_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  8, 'wht_remittances',  'journal_entries',  'journal_entry_id',        '{}'::jsonb, 'down', true,  false),
        ('payment_request',  9, 'journal_entries',  'bank_transfers',   'reversal_entry_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request', 10, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true,  false),
        -- ── 费用 / 供应商账单:核销行 · 附件 · 定金冲抵 · 冲销它的那一张(往上)/ 它冲的那一张(往下)· 报销单与它的审批 ·
        --    资本化进资产的那一笔成本 · 它的分录 · 定金冲抵的分录 · 冲销 ────────────────────────────────────────
        ('expense',  1, 'payment_allocations',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  2, 'finance_attachments',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  3, 'prepayment_applications',  'expenses',                'expense_id',          '{}'::jsonb, 'down', true, true),
        ('expense',  4, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('expense',  5, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'down', true, false),
        ('expense',  6, 'expense_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  7, 'approval_log',             'expense_claims',          'subject_id',          '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('expense',  8, 'fixed_asset_cost_entries', 'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  9, 'journal_entries',          'expenses',                'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('expense', 10, 'journal_entries',          'prepayment_applications', 'source_id',           '{}'::jsonb, 'down', true, false),
        ('expense', 11, 'journal_entries',          'journal_entries',         'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- AUDIT-TRAIL-1d-2(Q37):医疗报销付款时建的那张费用单 —— 费用页够得到是哪一张报销单让它生出来的(家仍在报销单那一页)
        ('expense', 12, 'medical_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        -- ── 应付(Q5,M3 · M6):只有钱的那几样 —— 核销 · 运费分摊 · 定金冲抵 · 财务附件 · 价格 · 计价 / 注销 / 定金的分录与冲销 ──
        ('payable', 1, 'payment_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 2, 'freight_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 3, 'prepayment_applications', 'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 4, 'finance_attachments',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 5, 'price_history',           'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 6, 'journal_entries',         'inbound_batches',         'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 7, 'journal_entries',         'prepayment_applications', 'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 8, 'journal_entries',         'journal_entries',         'reversed_by',      '{}'::jsonb, 'up',   true, false),

        -- ══ AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a)· 其余的单据与合同 ══════════════════════════════════
        -- ── 销售(Q14):出库 · 归属客户 · 开票的那一行 · 收款核销 · 附件 · 收入 / 成本分录与它们的冲销 ─────────────────
        --    ★ 销售自己是一个主语的根了 —— /settings/change-history 的 Record 一栏把销售那一行与它的子行归到【这一笔销售】
        --      (以前归到产出批次:产出批次 ord 12 的 home 改成 false,于是从子行往上走到销售就停下)
        ('sale', 1, 'sales_record_movements', 'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 2, 'sales_attribution_log',  'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 3, 'invoice_lines',          'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 4, 'payment_allocations',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 5, 'finance_attachments',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, true),
        ('sale', 6, 'journal_entries',        'sales_records',   'source_id',       '{"source_type": "sale"}'::jsonb, 'down', true, false),
        ('sale', 7, 'journal_entries',        'sales_records',   'cogs_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('sale', 8, 'journal_entries',        'journal_entries', 'reversed_by',     '{}'::jsonb, 'up',   true, false),
        -- ── 运费单:分摊到的批次(家在这里 —— 它是这张单分出去的)· 付它的核销 · 过账分录 · 冲销分录 ───────────────────
        ('freight', 1, 'freight_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, true),
        ('freight', 2, 'payment_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, false),
        ('freight', 3, 'journal_entries',     'freight_documents', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('freight', 4, 'journal_entries',     'freight_documents', 'reversal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('freight', 5, 'journal_entries',     'journal_entries',   'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 资产(财务那一页,Q10):资产卡的修改史 · 成本 · 折旧与折旧基点 · 处置申请与它的审批 · 处置 / 折旧的分录 ·
        --    保养维修、停机、保养间隔(家仍是 equipment —— 加工那一页)─────────────────────────────────────────────
        ('fixed_asset',  1, 'fixed_asset_history',              'fixed_assets',             'fixed_asset_id',      '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  2, 'fixed_asset_cost_entries',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  3, 'fixed_asset_depreciation',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  4, 'fixed_asset_depreciation_anchors', 'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  5, 'asset_disposal_requests',          'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  6, 'approval_log',                     'asset_disposal_requests',  'subject_id',          '{"subject_type": "asset_disposal_request"}'::jsonb, 'down', true, true),
        ('fixed_asset',  7, 'equipment_maintenance',            'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  8, 'equipment_downtime',               'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  9, 'equipment_service_intervals',      'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 10, 'shift_handover_equipment_refs',    'equipment_downtime',       'downtime_id',         '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 11, 'journal_entries',                  'fixed_assets',             'disposal_journal_id', '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 12, 'journal_entries',                  'fixed_asset_depreciation', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 13, 'journal_entries',                  'journal_entries',          'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 对账单:行与每一行的匹配 · 对账记录与它写明的差额 ────────────────────────────────────────────────────
        ('bank_statement', 1, 'bank_statement_lines',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 2, 'bank_line_matches',                  'bank_statement_lines', 'statement_line_id', '{}'::jsonb, 'down', true, true),
        ('bank_statement', 3, 'bank_reconciliations',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 4, 'bank_reconciliation_variance_items', 'bank_reconciliations', 'reconciliation_id', '{}'::jsonb, 'down', true, true),
        -- ── GST 期间:申报那一刻抄下来的每一格 · 申报申请与它的审批。★ Q22:更正期间【不】挂在原期间上(那样更正件之后的
        --    每一次改动都会出现在原件上);更正件自己的记录以"为 GST-… 开的更正"开头,原件页上那一条链接照旧 ──────────────
        ('gst_period', 1, 'gst_return_boxes',    'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 2, 'gst_filing_requests', 'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 3, 'approval_log',        'gst_filing_requests', 'subject_id', '{"subject_type": "gst_filing_request"}'::jsonb, 'down', true, true),
        -- ── 汇率:它的修改史(录入 · 更正 · 撤回 —— 一件事两行:记录开始之后变更记录那一行说,之前修改史那一行说)──────
        ('fx_rate', 1, 'fx_rate_history', 'fx_rates', 'fx_rate_id', '{}'::jsonb, 'down', true, true),
        -- ── 管理包:没有成员(一份新包取代旧包时,旧包自己那几列说"被谁取代";不经 superseded_by 自连 —— 那会把前一份的
        --    整段历史拉到这一份上)
        -- ── 合同:七张条款表 · 它的申请(生效)与申请的审批(没有 pricing.view 的读者那几行是 Restricted,Q21)·
        --    把它挂到采购单 / 销售订单上的那一份快照(家仍在那张订单上)────────────────────────────────────────────
        ('contract',  1, 'contract_grade_specs',           'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  2, 'contract_insurance_obligations', 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  3, 'contract_volume_commitments',    'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  4, 'contract_pricing_terms',         'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  5, 'contract_settlement_terms',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  6, 'contract_refining_charges',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  7, 'contract_penalty_elements',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  8, 'terms_requests',                 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  9, 'approval_log',                   'terms_requests', 'subject_id',  '{"subject_type": "terms_request"}'::jsonb, 'down', true, false),
        ('contract', 10, 'contract_document_terms',        'contracts',      'contract_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a)· 期末、设置与清单页上的记录 ══════════════════════════
        -- ── 锁期(Q25 · Q3 · M7):月结 / 反结的 period_closes 与 finance_settings 之间一个键都没有 —— 整张表属于那一行。
        --    关账在同一笔里写 period_closes 一行、把锁往后挪;反结在同一笔里给那一行盖反结的戳、把锁往回挪 —— 各是一条
        ('finance_lock', 1, 'period_closes', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 年结:结转分录(往上)· 反结的冲销分录(往上)──────────────────────────────────────────────────
        ('year_close', 1, 'journal_entries', 'year_closes', 'closing_journal_id',  '{}'::jsonb, 'up', true, false),
        ('year_close', 2, 'journal_entries', 'year_closes', 'reversal_journal_id', '{}'::jsonb, 'up', true, false),
        -- ── 人工分录 / 冲销申请(Q17):它的审批(家在这里 —— 一张还没批的申请没有分录,它唯一的家是它自己)· 过账的那一张 ──
        ('journal_request', 1, 'approval_log',    'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, true),
        ('journal_request', 2, 'journal_entries', 'journal_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        -- ── 报销单(Q20):审批 · 收据(附件)· 批准时记下的那张费用单(往上)。/me 上报销人自己读同样的几张(M8)──────
        ('expense_claim',    1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, true),
        ('expense_claim',    2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, true),
        ('expense_claim',    3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        ('my_expense_claim', 1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('my_expense_claim', 2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, false),
        ('my_expense_claim', 3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        -- ── 行内转账:过账分录 · 冲销分录(往上)· 付出它 / 冲它的申请(往下,两把外键 —— 港口的先例)与申请的审批 ──
        ('bank_transfer', 1, 'journal_entries',  'bank_transfers',   'journal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 2, 'journal_entries',  'bank_transfers',   'reversal_entry_id',  '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 3, 'payment_requests', 'bank_transfers',   'result_transfer_id', '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 4, 'payment_requests', 'bank_transfers',   'transfer_id',        '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 5, 'approval_log',     'payment_requests', 'subject_id',         '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        -- ── 代扣税缴纳(Q30):它的分录 · 冲销那一张(经原分录的 reversed_by,往上)· 冲它的申请(wht_remittance_id)·
        --    付出它的申请(那种申请没有指向缴纳的外键 —— 只能经分录:payment_requests.result_journal_entry_id,往下)· 审批 ──
        ('wht_remittance', 1, 'journal_entries',  'wht_remittances',  'journal_entry_id',        '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 3, 'payment_requests', 'wht_remittances',  'wht_remittance_id',       '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 4, 'payment_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 5, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a · §d · §e)· 机制、设置与员工 ══════════════════════════════
        -- ── 账号(M9,Q24):授给它的角色(家在这里,Q22)· 它作为附加账号挂在谁身上 · 那张挂接史 · 它是谁的主账号
        --    (employees.user_id —— M10 只取那一列:那名员工别的每一次编辑不是账号的事)──────────────────────────────
        ('account', 1, 'user_roles',               'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 2, 'employee_accounts',        'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 3, 'employee_account_history', 'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 4, 'employees',                'auth.users', 'user_id', '{}'::jsonb, 'down', true, false),
        -- ── 审批方针(M7 · Q25):修改史整张属于那一行设置(两张表之间没有键 —— 锁期 / period_closes 的同一个做法)──────────
        ('approval_policy', 1, 'finance_settings_history', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 员工(Q28):任职履历 · 调薪申请与它的审批(只给 view_pay 的人读,别人那几行是 Restricted)· 培训(家在培训那一页,Q29)·
        --    附加账号与它的挂接史 · 账号的镜像(Q24 · Q21):主账号与附加账号(往上一跳到 auth.users,M9)与授给它们的角色 ——
        --    每一行照它自己的读规则:授权人人读得到,账号事件与挂接史只给 manage_permissions,别人是 Restricted ────────────────
        ('employee', 1, 'employment_history',       'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 2, 'salary_change_requests',   'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 3, 'approval_log',             'salary_change_requests', 'subject_id',  '{"subject_type": "salary_change_request"}'::jsonb, 'down', true, true),
        ('employee', 4, 'training_records',         'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 5, 'employee_accounts',        'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 6, 'employee_account_history', 'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 7, 'auth.users',               'employees',              'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 8, 'auth.users',               'employee_accounts',      'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 9, 'user_roles',               'auth.users',             'user_id',     '{}'::jsonb, 'down', true, false),
        -- ── 部门 · 培训记录 · 导入批次:没有成员。六本字典:M11 集合,没有成员 ──────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a)· 请假与考勤 ══════════════════════════════════════════
        -- ── 请假:消耗账(批准时扣、取消时还 —— 家在这里)· 审批 ─────────────────────────────────────────────
        --    /me 上本人读同样的两张(M8);两张的读规则都只给 hr.view,所以本人看到的是 Restricted(Q4 · Q14)
        ('leave_request',    1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, true),
        ('leave_request',    2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, true),
        ('my_leave_request', 1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, false),
        ('my_leave_request', 2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, false),
        -- ── 医疗报销:审批 · 付它的那张费用单(往上,M4)· 费用的分录 · 核销 · 冲销它的费用单与分录(只给财务,别人 Restricted)──
        ('medical_claim',    1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, true),
        ('medical_claim',    2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('medical_claim',    5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, false),
        ('my_medical_claim', 2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('my_medical_claim', 5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        -- ── 加班:行(删掉的行从 DELETE 的影像里找)· 审批(送审 · 批准 · 退回)──────────────────────────────────
        ('overtime_batch',   1, 'overtime_lines',      'overtime_batches', 'batch_id',          '{}'::jsonb, 'down', true, true),
        ('overtime_batch',   2, 'approval_log',        'overtime_batches', 'subject_id',        '{"subject_type": "overtime_batch"}'::jsonb, 'down', true, true),
        -- ── 考勤:每人一行(开月 · 补新人 · 记录 · 完成时冻住的那几列 —— 完成那一下的整批改动在界面上是一句)──────────
        ('attendance_period', 1, 'attendance_lines',   'attendance_periods', 'period_id',       '{}'::jsonb, 'down', true, true),
        -- ── 假期发放(清单块)· 假别 · 公共假期(M11 集合):没有成员 ──────────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a)· 工资与评审 ══════════════════════════════════════════
        -- ── 工资期:工资行(每次保存删了重插 —— 一次操作里按员工配对,Q11;家在这里)· 过账 / 撤销的申请与它们的审批 ·
        --    这一期的分录(过账 · 发薪 · CPF · 代扣款)按 source_id + source_type = 'payroll' 找 —— 【不】经 journal_entry_id
        --    往上走:撤销过账会把那一列置空(unpost_payroll_period_internal),往上一跳读的是今天的样子,过账与它的冲销会一起丢掉;
        --    source_id 撤不掉。冲销分录自己的 source_id 是原分录(1c-1),所以它经 reversed_by 往上一跳。分录只给财务(别人 Restricted)
        ('payroll_period',     1, 'payroll_lines',    'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     2, 'payroll_requests', 'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     3, 'approval_log',     'payroll_requests',    'subject_id',        '{"subject_type": "payroll_request"}'::jsonb, 'down', true, true),
        ('payroll_period',     4, 'journal_entries',  'payroll_periods',     'source_id',         '{"source_type": "payroll"}'::jsonb, 'down', true, false),
        ('payroll_period',     5, 'journal_entries',  'journal_entries',     'reversed_by',       '{}'::jsonb, 'up',   true, false),
        -- ── 评审:目标(删掉的目标从 DELETE 的影像里找)· 审批(送审 · 批准 · 本人确认;作废不写审批)──────────────────
        --    批准时改的员工那一行与任职履历【不】挂进来(Q7):它们没有指回评审的键,评审那一段按评审自己的几列说出结论
        --    /my-reviews 上审核人读同样的两张(M12);审批那几行的读规则是 hr.view,不持它的审核人看到的是 Restricted(Q5 · Q4)
        ('performance_review', 1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, true),
        ('performance_review', 2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, true),
        ('my_review',          1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, false),
        ('my_review',          2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, false),
        -- ── MES-1:设备 —— 网关钥匙(发放与撤销;哈希被 never 规则遮住)。收件箱 · 传输日志 · 中断不进变更记录(MES-0 Q14),不在这里 ──
        ('device',             1, 'gateway_keys',     'devices',             'gateway_id',        '{}'::jsonb, 'down', true, true)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- ── 7 · 新视图(镜像原样)──────────────────────────────────────────────────────

-- db/views/gateway_keys_masked.sql
-- MES-1(2026-10-06,MES-0 Q91;MES-1 Step 0 Q20,Tim):网关钥匙的遮蔽伴生视图。
-- 【遮什么】key_hash —— 【谁都看不见】:CASE WHEN false,恒为空。规则 never 与这一句同一个判据(change_log_mask_rules)。
--   表上的列授权里没有它,所以 API 读基表拿不到;读这张视图拿到的是空 —— 两条路都不给。页面只认 key_prefix。
-- 【行谓词】= 基表的读策略(module.processing.view)—— 属主视图绕过 RLS,所以这里必须再问一次。
-- 【列】基表的每一列都在这里(colgrant)。

CREATE VIEW public.gateway_keys_masked WITH (security_invoker = off) AS
 SELECT id,
    gateway_id,
    key_prefix,
        CASE
            WHEN false THEN key_hash
            ELSE NULL::bytea
        END AS key_hash,
    issued_at,
    issued_by,
    revoked_at,
    revoked_by,
    revoke_reason
   FROM gateway_keys
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.gateway_keys_masked IS
    'MES-1:网关钥匙的遮蔽伴生视图。key_hash 谁都看不见(恒为空,never 规则)。行谓词 = 基表的读策略(module.processing.view)。';

GRANT SELECT ON public.gateway_keys_masked TO authenticated;
REVOKE ALL ON public.gateway_keys_masked FROM anon;

-- db/views/gateway_health.sql
-- MES-1(2026-10-06,规格 §6.2;MES-0 Q9 · §3.8;MES-1 Step 0 Q7 · Q16 · Q17,Tim):【网关此刻的状态 —— 读的时候算】。
--   没有调度器,所以"它是不是在沉默"不存在任何地方,每一次读都从传输日志现算:
--     last_call_at       最后一次被收下的数据调用(ingest_transmissions,kind = call,result = accepted)
--     last_heartbeat_at  最后一次心跳(这台网关的 heartbeat_hour 桶里最大的 last_at)
--     last_heard_at      两者里晚的那一个
--   status(按这个顺序判):
--     retired            停用了
--     not_yet_heard      一次都没听到过 —— "Not yet heard from",不上提醒(Q16:登记了、还没调试是正常状态)
--     interval_not_set   心跳间隔没给 —— "Not yet set — silence cannot be judged",不上提醒(Q17)
--     silent             now() − last_heard_at 超过了它的心跳间隔 —— 上提醒(gateway_silent)
--     ok                 其余
-- 【属主视图】读传输日志不过 RLS,所以行谓词在这里再问一次(module.processing.view)。

CREATE VIEW public.gateway_health WITH (security_invoker = off) AS
 SELECT d.id AS gateway_id,
    d.code,
    d.name,
    d.retired_at,
    d.heartbeat_interval_s,
    lc.last_call_at,
    hb.last_heartbeat_at,
    GREATEST(lc.last_call_at, hb.last_heartbeat_at) AS last_heard_at,
    ( SELECT count(*) AS count
           FROM gateway_keys k
          WHERE k.gateway_id = d.id AND k.revoked_at IS NULL) AS active_keys,
        CASE
            WHEN d.retired_at IS NOT NULL THEN 'retired'::text
            WHEN GREATEST(lc.last_call_at, hb.last_heartbeat_at) IS NULL THEN 'not_yet_heard'::text
            WHEN d.heartbeat_interval_s IS NULL THEN 'interval_not_set'::text
            WHEN (now() - GREATEST(lc.last_call_at, hb.last_heartbeat_at)) > make_interval(secs => d.heartbeat_interval_s::double precision) THEN 'silent'::text
            ELSE 'ok'::text
        END AS status
   FROM devices d
     LEFT JOIN LATERAL ( SELECT max(t.received_at) AS last_call_at
           FROM ingest_transmissions t
          WHERE t.kind = 'call'::text AND t.result = 'accepted'::text AND t.gateway_id = d.id) lc ON true
     LEFT JOIN LATERAL ( SELECT max(t.bucket_last_at) AS last_heartbeat_at
           FROM ingest_transmissions t
          WHERE t.kind = 'heartbeat_hour'::text AND t.gateway_id = d.id) hb ON true
  WHERE d.kind = 'gateway'::text AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.gateway_health IS
    'MES-1:网关此刻的状态,读的时候从传输日志算(没有调度器)。status:retired · not_yet_heard(不上提醒)· interval_not_set(Not yet set,不上提醒)· silent(超过心跳间隔,上提醒)· ok。行谓词 module.processing.view。';

GRANT SELECT ON public.gateway_health TO authenticated;
REVOKE ALL ON public.gateway_health FROM anon;

-- db/views/ingest_sequence_gaps.sql
-- MES-1(2026-10-06,MES-0 Q8;MES-1 Step 0 Q13,Tim):收件箱里【按流】缺了的序号段 —— 列出来,不挡任何东西。
--   一条流(网关每次启动生成一个)里,收下的序号排好之后相邻两个之间的空当,以及第一个之前的空当(一条流从 1 起)。
--   缺的号补上来(网关按序回填)之后那一段就自己消失。
-- 【属主视图】行谓词在这里再问一次(module.processing.view)。

CREATE VIEW public.ingest_sequence_gaps WITH (security_invoker = off) AS
 WITH s AS (
         SELECT b.gateway_id,
            b.stream,
            b.seq,
            lag(b.seq) OVER (PARTITION BY b.gateway_id, b.stream ORDER BY b.seq) AS prev_seq,
            max(b.received_at) OVER (PARTITION BY b.gateway_id, b.stream) AS last_received_at
           FROM ingest_inbox b
          WHERE b.source = 'device'::text
        )
 SELECT s.gateway_id,
    s.stream,
    COALESCE(s.prev_seq, 0::bigint) + 1 AS missing_from,
    s.seq - 1 AS missing_to,
    s.seq - COALESCE(s.prev_seq, 0::bigint) - 1 AS missing_count,
    s.last_received_at
   FROM s
  WHERE s.seq > (COALESCE(s.prev_seq, 0::bigint) + 1) AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.ingest_sequence_gaps IS
    'MES-1:收件箱里按 (网关, 流) 缺了的序号段(含第一个收下的号之前那一段)。只列出来,不挡(MES-0 Q8)。行谓词 module.processing.view。';

GRANT SELECT ON public.ingest_sequence_gaps TO authenticated;
REVOKE ALL ON public.ingest_sequence_gaps FROM anon;

-- db/views/ingest_transmission_anomalies.sql
-- MES-1(2026-10-06,规格 §7「Logged」;MES-1 Step 0 Q19,Tim):【传输上的异常】—— 规格要求"认得出"的那几种。
--   unknown_gateway · bad_key · revoked_key · retired_gateway  每一次被拒的调用(在预算之内一行一行记的那些)
--   too_large · too_many · malformed                           认证过、但传输形状不对的调用
--   overflow                                                   失败到预算之后的溢出桶(10 分钟一行,occurrences = 那一段的次数)
--   seq_reused                                                 收下的调用里,某一条序号带着一份不同的 payload 又来了(Q13)
--   clock_ahead                                                site_to 比服务器收到它的时刻晚 5 分钟以上的那几条(Q13)
--   ☞ "工作时间以外的数据调用"不在这里:工作时间是 V6(班次的起止时刻),还没给 —— /settings/pending-values 列着它。
--     不发明一个数(Q19)。也不设字节阈值。
-- 【属主视图】行谓词在这里再问一次(module.processing.view)。

CREATE VIEW public.ingest_transmission_anomalies WITH (security_invoker = off) AS
 SELECT a.occurred_at,
    a.anomaly,
    a.transmission_id,
    a.inbox_id,
    a.gateway_id,
    a.presented_gateway,
    a.seq,
    a.occurrences,
    a.client_address
   FROM ( SELECT t.received_at AS occurred_at,
            t.result AS anomaly,
            t.id AS transmission_id,
            NULL::bigint AS inbox_id,
            t.gateway_id,
            t.presented_gateway,
            NULL::bigint AS seq,
            1 AS occurrences,
            t.client_address
           FROM ingest_transmissions t
          WHERE t.kind = 'call'::text AND t.result <> 'accepted'::text
        UNION ALL
         SELECT t.bucket_last_at AS occurred_at,
            'overflow'::text AS anomaly,
            t.id AS transmission_id,
            NULL::bigint AS inbox_id,
            NULL::uuid AS gateway_id,
            NULL::text AS presented_gateway,
            NULL::bigint AS seq,
            t.bucket_count AS occurrences,
            NULL::text AS client_address
           FROM ingest_transmissions t
          WHERE t.kind = 'rejected_overflow'::text
        UNION ALL
         SELECT t.received_at AS occurred_at,
            'seq_reused'::text AS anomaly,
            t.id AS transmission_id,
            NULL::bigint AS inbox_id,
            t.gateway_id,
            t.presented_gateway,
            (e.value ->> 'seq'::text)::bigint AS seq,
            1 AS occurrences,
            t.client_address
           FROM ingest_transmissions t,
            LATERAL jsonb_array_elements(t.rejections) e(value)
          WHERE t.kind = 'call'::text AND t.rejections IS NOT NULL AND (e.value ->> 'code'::text) = 'SEQ_REUSED'::text
        UNION ALL
         SELECT b.received_at AS occurred_at,
            'clock_ahead'::text AS anomaly,
            b.transmission_id,
            b.id AS inbox_id,
            b.gateway_id,
            NULL::text AS presented_gateway,
            b.seq,
            1 AS occurrences,
            NULL::text AS client_address
           FROM ingest_inbox b
          WHERE b.clock_ahead) a
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.ingest_transmission_anomalies IS
    'MES-1:传输上的异常 —— 被拒的调用(按理由)、认证过但形状不对的调用、溢出桶、序号带着不同的 payload 又来(seq_reused)、时钟超前的消息。工作时间以外的调用要等 V6(班次时刻)给了才列。行谓词 module.processing.view。';

GRANT SELECT ON public.ingest_transmission_anomalies TO authenticated;
REVOKE ALL ON public.ingest_transmission_anomalies FROM anon;

-- db/views/pending_values.sql
-- MES-1(2026-10-06,MES-0 §5 · Q92 · Q93;MES-1 Step 0 Q1 · Q2,Tim):【还没给的标准值】—— /settings/pending-values 读它。
--   一支一个值(像 operations_now 那样),每一支带着它自己的权限码;读者只看得到他持码的那几支(末尾的 WHERE)。
--   每一行是一件具体还空着的事:哪一个值(value_code,对应 docs/mes-pending-values.md 里那一行)、空在哪一条记录上、去哪儿填。
--   给了值,那一行就自己消失(这张视图不存任何东西)。
-- 【MES-1 播两支】
--   V5  网关的心跳间隔 —— 每一台没停用、间隔为空的网关一行。由集成商在网关调试时给(MES-0 §5.1 V5)。
--   V6  传输异常的工作时间 —— 读班次的起止时刻(shifts.starts_at / ends_at,为空是设计如此:没人说过几点到几点)。
--       每一个启用、而起止为空的班次一行。由 Tim 给(V6)。
-- 【规矩】之后每一刀加它自己的那几支,并在【同一个提交里】往 docs/mes-pending-values.md 加它们的行(Tim,Q2)。
-- 【属主视图】读 devices / shifts 不过 RLS,所以每一支的码在末尾的 WHERE 里问一次。

CREATE VIEW public.pending_values WITH (security_invoker = off) AS
 SELECT p.value_code,
    p.permission,
    p.item_id,
    p.item_code,
    p.item_label,
    p.href
   FROM ( SELECT 'V5'::text AS value_code,
            'module.processing.view'::text AS permission,
            d.id AS item_id,
            d.code AS item_code,
            d.name AS item_label,
            '/operation/devices/'::text || d.id::text AS href
           FROM devices d
          WHERE d.kind = 'gateway'::text AND d.retired_at IS NULL AND d.heartbeat_interval_s IS NULL
        UNION ALL
         SELECT 'V6'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            sh.code AS item_code,
            sh.name_en AS item_label,
            '/operation/handovers'::text AS href
           FROM shifts sh
          WHERE sh.is_active AND sh.starts_at IS NULL AND sh.ends_at IS NULL) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间)。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- ── 8 · 改过的视图(镜像原样,CREATE OR REPLACE —— 列契约一字未动)──────────────────────

-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行
-- ★ ROLE-1 Batch 2a(2026-09-24,Q9):加一支 supplier_pending_approval —— 等 CFO 批的供应商
--   (action.supplier_approve;只有持这个码的人看得见,点进去由 set_supplier_status 裁)。
--   等了多久从【最后一次送审】起算(supplier_status_history),没有那一行时退回 updated_at。
-- ★ PAY-REQ-1(2026-09-23):加一支 payment_request_pending —— 等 CFO 批的付款申请
--   (module.finance.view;finance 与 cfo 都看得见,点进去由 decide_payment_request 裁谁能批)。
-- ★ PAYROLL-APR-1(2026-09-24):加一支 payroll_request_pending —— 等 CFO 批的工资过账 / 撤销申请
--   (data.view_pay:看得见工资数的人才看得见这一格;点进去由 decide_payroll_request 裁谁能批)。
--   item_id 是【工资期】的 id,不是申请的 —— 申请没有自己的页面,它住在工资期页上。
-- ★ ROLE-1 Batch 4b(2026-09-25):加一支 receipt_price_request_pending —— 等 CFO 批的收货定价申请
--   (data.view_purchase_prices,Tim 的 Q10:看得见采购价的人都看得见这一格;点进去由
--   decide_receipt_price_request 裁谁能批)。item_id 是【收货】的 id —— 申请住在收货页上。
-- ★ APR-5b(2026-09-25):加两支。shipping_release_pending —— 等 CFO 批的发货放行(module.sales.view:
--   读得到放行的人都看得见这一格;点进去由 decide_shipping_release 裁谁能批);item_id 是【订单】的 id ——
--   放行住在订单页上。shipping_release_ready —— 放行过、还有没发完的订单(action.ship_goods:仓库的信号;
--   剩余与发货队列读同一张 sales_order_line_releasable_all;点进去是 /logistics/shipping)。
-- ★ APR-6(2026-09-25):加一支 journal_request_pending —— 等 CFO 批的手工凭证 / 冲销申请
--   (module.finance.view:读得到凭证的人都看得见这一格;点进去由 decide_journal_request 裁谁能批)。
--   item_id 是【申请】的 id —— 一张手工凭证在批准之前还没有分录,申请住在凭证列表页上(/finance/journal)。
--   subject 是摘要 / 冲销理由(申请没有对手方)。
-- ★ APR-7(2026-09-25):加一支 warehouse_request_pending —— 等 CFO 批的注销 / 回滚 / 证书作废申请
--   (module.finance.view:与 decide_warehouse_request 的门同一个码;点进去由它裁谁能批)。item_id 是【申请】的 id ——
--   申请住在库存页上(/inventory#wr-<id>);subject 是提单人的理由。
-- ★ APR-8(2026-09-26):加一支 terms_request_pending —— 等 CFO 批的定价公式 / 合同生效申请
--   (module.pricing.view:公式页的门,cfo 持;点进去由 decide_terms_request 裁谁能批)。item_id 是【申请】的 id;
--   doc_kind 分开两处住址:formula → 公式列表页(/tools/pricing/formulas#tr-<id>),contract → 合同页(/contracts#tr-<id>)。
--   subject 是提单人的理由。
-- ★ APR-9(2026-09-27):加两支。asset_disposal_pending —— 等 CFO 批的固定资产处置申请(module.finance.view:与
--   decide_asset_disposal_request 的门同一个码;item_id 是【申请】的 id,住在资产页 /finance/assets#adr-<id>)。
--   salary_change_pending —— 等批的调薪申请(data.view_pay:看得见工资的人 —— 财务、CFO、cco;谁能批由
--   decide_salary_change_request 按人裁)。★ item_id 是【员工】的 id:申请住在那个人的档案页
--   (/hr/employees/<id>#salary-requests);item_code 是 label,subject 是提单人的理由。月薪数不进这张视图。
-- ★ APR-10(2026-09-27):加一支 gst_filing_pending —— 等 CFO 批的 GST 申报申请(module.finance.view:与
--   decide_gst_filing_request 的门同一个码)。★ item_id 是【期间】的 id:申请住在那一期的页面上
--   (/finance/gst/<id>#gst-filing);item_code 是 label,subject 是提单人的附言(可空)。
--
-- 【为什么是一张视图而不是九个页面各查各的】仪表盘的每一块牌子背后都是"有多少件
-- 事在等"这一类问题;九个问题九处写,就是九份会各自漂移的实现。hr_alerts 已经证明
-- 过这个形状:一个 UNION,每一种等待状态一支,页面只负责画。
--
-- 【属主权限 + 每支自带 permission 列,外层一次性把关】(OPS-14 修法 (a))。
-- 本视图横跨六个模块,invoker 会让 RLS 把读者无权模块的行【静默丢掉】—— 行消失
-- 在这里意味着"那个数少算了",而不是报错。属主权限读全量,外层
-- WHERE has_permission(a.permission) 按【调用者】逐支裁决:无权的支【整支缺席】,
-- 不是零。谓词写一次而不是九遍 —— hr_alerts 的注释说过,复述 N 遍只会给下一个
-- 加支的人留一个漏写的机会;这里每支【声明】自己的权限码,外层【执行】它。
--
-- 【缺席 ≠ 零,页面必须自己分辨】视图对无权读者不发一行,于是"没有行"有两种
-- 含义:真的零,或者你看不见。app/page.tsx 先查权限再渲染每块牌子 —— 无权显示
-- 「受限」(common.restricted),绝不显示 0。这是仪表盘最容易犯、且任何 gate 都
-- 查不出的那个错(0 与"你看不见"在屏幕上一模一样 —— moduleGuard 的老病换了件衣服)。
--
-- 【item_type 写成 'x'::text 字面量】check-i18n 的 sqlLiteralAs 解析器现读本文件,
-- dashboard.item.* 的后缀集合就是这里的支列表 —— 加一支,键检查自动跟着变宽。
--
-- 【两笔贵的读数,按界所限】(OPS-16 报告点名的两处):
--   * fx_rate_gaps 按 (日期,币种) 对每组跑 fx_rate_asof,本身不受期间约束 ——
--     这里限 rate_date >= CURRENT_DATE - 45:仪表盘答"最近有没有漏",完整历史
--     归 /finance/month-end 按月翻。谓词落在分组键上,能下推进聚合。
--   * 银行对账这支【只数报表侧的未匹配行】(bank_statement_lines,行数 = 导入量,
--     天然有界)。bank_reconciliation_status 的账簿侧 LATERAL 要扫 journal_lines
--     全表 —— 那是对账页的活,不上人人都开的首页。
--
-- 【不在此列的】批次毛利 —— 有未决的设计问题(哪些限定词随数字走、已过账 COGS
-- 还是当前成本),自成一切,谓词已录在 AGENTS.md 常设决定 2。月结的七个信号 ——
-- /finance/month-end 是它们的枢纽,首页放一个入口,不复制信号。
--
-- NOTE: introduced by db/migrations/2026-08-09-ops18-operations-now-and-the-dashboard.sql.
-- EXEC-3a(2026-08-16):再【两】支 —— work_order_overdue 与
-- work_order_variance_beyond(WO-1c 记下的两个候选)。差异那一支的两个阈值
-- 现读 processing_settings,【两个数不是一个】(投入超耗是成本问题、
-- 产出短交是收率问题,合成一个数等于说它们一样严重)。
-- 【本刀一度加了资质那两支,而它们 CMP-2 就已经在了】—— 清单文件里那行
-- "Candidate, not built" 是过时的,重复分支由 fixture 37C 与 30A 当场抓住,
-- fu1 撤掉。见 db/migrations/2026-08-16-exec3a-fu1-*.sql。
-- 【batch_margin 撤了】:一个卖出去的批次毛利偏低是一个【状态】,没有清除动作 ——
-- 看板装的是待办,毛利的家是 /margin;可处理的那一半已经是 arm 15。
--
-- EXEC-1a(2026-08-16):两支高管臂 —— metal_quote_stale(行情陈旧,阈值现读
-- pricing_settings.metal_quote_stale_days,按 price_date 不按 created_at)与
-- orders_unfulfilled(confirmed / partially_shipped 的订单)。规格见
-- docs/dashboard-arm-inventory.md;【谁要看哪一支】见 docs/exec-views-plan.md。
--
-- OPS-19(2026-08-09):补上原始定稿漏掉的四支(awaiting_assay / batch_unpriced /
-- invoice_overdue / ar_over_90 + ap_over_90),并新增 output_unsold_aging —— sales
-- 这一行唯一够得着的支(它没有 module.finance.view,当初猜的 AR 支对它同样是「受限」)。
-- assay_unapplied 的粒度同时从"一份未执行化验一行"改成"一个批次一行",与
-- awaiting_assay 同源同粒度、互斥;live 该支当时为 0,故不改变任何现有数字。
--
-- ── SUP-TYPE-1a(2026-08-18):qualification_missing 收窄到【供货的】供应商 ──
-- EXEC-3a 在 2026-08-16-exec3a-four-executive-arms.sql:349 写着:判据是"一张都没有"
-- 而不是"缺某一类",因为没有一张"谁必须持哪张证"的要求矩阵;并且明写着
-- **"有了'这家需要合规文件'的标记之后,这一支应当收窄到它"**。
-- **那个标记现在有了(suppliers.supplies_goods),这一支已经收窄,那句话到此退休。**
-- 提交信息改不了历史文件,所以退休记录写在这里 —— 沿着引用走过来的人在这里落地。
--
-- 【为什么必须收窄:实测过的永久亮灯】SUP-TYPE-0 把它走了一遍:把一个只收钱、
-- 不供货的往来户沿合法路径推到 status='active',这一支当场亮起、days_waiting 一路
-- 长下去,而它永远不会灭 —— 房东不会去办危废证。收窄之后同样的走法【不再亮】,
-- 而一个没有证书的【真供应商】仍然照亮(fixture 89 两边都钉)。
--
-- CMP-1(2026-08-09):两支资质臂。qualification_expiring 到【类型自己的 lead days】就上牌,
-- 过期后【不落牌、无 -30 天下限】—— 工作证过期 30 天人已走,证书过期两年而进场仍可能,
-- 它就还站在那儿(live 那张 2024 年就过期的 Article 18 正是证据)。续期(valid_until
-- 前移)即安静。qualification_missing 是"一张证都没有"的缺席臂(与 awaiting_assay /
-- assay_unapplied 的分立同理)。disposition='ignore' 的类型不上牌。
-- 【规格在 docs/dashboard-arm-inventory.md】每一支是什么意思、挂哪个权限码、界在
-- 哪里、以及【哪些支被考虑过又被排除、为什么】都在那里。
-- 定稿只存在于一次对话里,代价是四支 —— 所以规矩是:
-- 【加一支 = 在同一个提交里往那份清单加一行】。
--
-- MAR-1(2026-08-10):支的权限从【一个码】放宽到【一个谓词】—— permission(必须有)
-- + permission_any(任意其一,由 arm_permission_any 一处声明,SELECT 与 WHERE 共用)。
-- 起因是批次毛利跨两个模块(prices AND (finance OR processing)),而没有任何 live 角色
-- 同时持有后两者。合成一个新权限码那条路被否掉:那会是谁能看毛利的第二份定义,
-- 与 batch_margin 自己的谓词必然漂开。fixture 45 三种读者各钉一次。
-- ASY-P1(2026-08-17):awaiting_assay 那一支【换了问题】。原来问的是"这个批次一份
-- 化验都没有"(batch_assay_status.assay_count = 0),它看不见"化验做了一半",
-- 也灭不掉料已耗尽那两盏灯(线上 IN-2026-0011 / IN-2026-0153,remaining_qty = 0)。
-- 现在读 batch_required_assay_gaps:物料声明了要验哪些金属、其中至少一种还没有被
-- 一份【已应用的】化验覆盖、并且【还取得到样】。subject 从供应商名换成【缺哪几种
-- 金属】—— subject 这一列在每一支里放的都是那一支最该让人看见的事实,而能让人
-- 下一步动起来的是缺哪几种。判据与理由住在那张视图里,不在这里。
-- LINKS-1(2026-08-11):每支多带一个 item_id —— 支从"指向一张列表"变成"指向那一件事"。
-- 【item_id 指的是谁】承载【补救动作】的那张页面所对应的行。十七支里它就是等待中的
-- 那一行;两支里是它的父:bank_unmatched(行没有页面,匹配动作在对账工作台上 →
-- 对账单)与 margin_cost_not_allocated(补救是给加工单分摊成本 → 加工单)。
-- 于是同一支的几行可以共用一个 item_id,那是对的,不是重复 —— fixture 47 因此断言
-- 的是"item_id 落在这一支该落的那张表里",不是"一行一个 id",也不是互不相同。
-- 【SO-3a:应收也成了两种单据】ar_over_90 的 doc_kind 从此非空('sale' 销售记录 /
-- 'invoice' 订单流发票),item_id 相应二选一 —— 门牌各是应收单据页与发票页,
-- app/page.tsx 按 doc_kind 分支,认不出的种类不给链接(与 ap 同一条)。
-- 【doc_kind 是披露】应付账款本来就是两种单据(ap_open_items 自己就按它分支,
-- 应付列表页也一直照它画链接),这张视图先前只是没说出口。其余十八支主体只有一种,
-- 该列为 NULL。【fx_rate_gap 没有 item_id】它的主体是一条不存在的牌价行,缺的东西
-- 没有 id —— 它指向按币种过滤的列表,那是"诚实过滤的列表"那类答案,不是按码搜索。
-- 每支的门牌与"补救是否在那张页面上"这条判据,写在 docs/dashboard-arm-inventory.md。
-- NOTE: item_id / doc_kind added by
-- db/migrations/2026-08-11-links1-operations-now-item-id.sql(列集变了 → DROP + CREATE)。
-- SS-1(2026-08-13):第二十支 safety_stock_below —— 物料的可用量低于它自己的
-- 安全库存阈值。【阈值 NULL 的物料一次都不响】:NULL 是"还没有人决定要盯它",
-- 不是"阈值为零",而把不响读成"查过了没问题"正是 METAL-1 的那一课。
-- 可用量来自 material_stock_available(一处求和,暂扣不算 —— 阈值问的是"还有多少
-- 能用的货",一次暂扣若能掩盖缺货,这个告警就在最该说话的时刻哑掉)。
-- item_date 用【最后一次库存移动】退回今天:阈值告警是持续状态,没有发生日;
-- 去算"哪天跌破的"要在首页翻整段流水史,那条界不允许(credit_over_limit 同形)。

-- LOG-5a(2026-08-20):第 23–26 支 —— 物流的四支告警。全部是【臂】(算出来、
-- 会自愈),不是 notifications 的事件。末尾的 WHERE 多了一个【放宽】算子
-- arm_permission_widen():它与收窄用的 arm_permission_any() 方向相反,
-- 对除 free_time_expiring 以外的每一支都返回 NULL(fixture 102G 逐支断言)。
-- LOG-5d(2026-08-20):同一种里程碑之内,算数的是【最后被录入】的那一条
-- (recorded_at DESC, id DESC)。此前按 event_date DESC 排,于是一条把日期
-- 改【早】的更正永远排不到前面、一次都不会生效(线上 CTR-2026-0009)。
-- EQP-2c(2026-08-21):第 27–28 支 —— 保养【到期】与【将到期】,两支不是一支。
-- 列契约一字未动。规格见 docs/dashboard-arm-inventory.md;推导与它的基线
-- (那两条"低读数有两种意思"的事实)整段写在 equipment_service_status 的视图注释里。
-- 【放宽】两支都走 arm_permission_widen(processing OR finance)—— 机器卡在财务、
-- 干活的人在加工,而它们底下每一张表/视图的读者都是这两个码的 OR。
-- CMPL-1(2026-08-30)追加两支:
--   · company_licence_expiring —— **形状逐字取自 qualification_expiring**,只是把
--     supplier_compliance 换成 company_compliance(少一跳供应商)。它读的仍是
--     certificate_types 自带的 warn_lead_days 与 disposition,所以 gwc 加进字典那天
--     它的到期提醒【自动就有】。**没有另起一套到期机制。**
--   · import_permit_unverified —— 是进口货、而那张进口准证还没有人核过。
--     **它不拦任何东西**:拦的那一半由 nea_import 的 block 处置在收货上做
--     (supplier_receiving_blocked → trg_inbound_batches_po_receivable),
--     这一支说的是"这一票还欠一次人工核对"。理由见 db/tables/inbound_batches.sql 的列注。
-- MES-1(2026-10-06,MES-1 Step 0 Q16 · Q17 · Q23,Tim):第 48–49 支 ——
--   · gateway_silent:一台网关此刻在沉默 —— 它的心跳间隔给了,而最后一次听到它已经超过那个间隔(gateway_health.status = silent)。
--     一次都没听到过的("Not yet heard from")与间隔没给的("Not yet set")【不上牌】:前者是还没调试的正常状态(Q16),
--     后者是沉默无从判断(Q17)。item_id = 那台网关(/operation/devices/[id])。
--   · capture_inbox_failed:收件箱里有转换失败的行 —— 按设备合成一块(item_id = 设备,subject = 设备名 · 失败行数,
--     item_date = 最早的那一行)。不为 awaiting_transform 上牌:那是每一个还没接上转换器的类的正常状态(Q23)。
--   两支都只要 module.processing.view;规格在 docs/dashboard-arm-inventory.md。
CREATE OR REPLACE VIEW public.operations_now AS
 SELECT item_type,
    permission,
    arm_permission_any(item_type) AS permission_any,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM ( SELECT 'awaiting_assay'::text AS item_type,
            'module.inbound.view'::text AS permission,
            g.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            g.batch_code AS item_code,
            array_to_string(g.missing_metals, ', '::text) AS subject,
            g.arrival_date AS item_date
           FROM batch_required_assay_gaps g
          WHERE g.sampleable
        UNION ALL
         SELECT 'assay_unapplied'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.latest_assay_code AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.has_unapplied_assay
        UNION ALL
         SELECT 'batch_unpriced'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.pricing_status = 'unpriced'::text
        UNION ALL
         SELECT 'allocation_stale'::text AS item_type,
            'module.processing.view'::text AS permission,
            s.run_id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            NULL::text AS subject,
            s.last_cost_change::date AS item_date
           FROM processing_run_allocation_status s
          WHERE s.is_stale OR s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL
        UNION ALL
         SELECT 'po_awaiting_receipt'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.id AS item_id,
            NULL::text AS doc_kind,
            po.code AS item_code,
            po.status AS subject,
            po.order_date AS item_date
           FROM purchase_orders po
          WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
        UNION ALL
         SELECT 'stocktake_open'::text AS item_type,
            'module.stocktakes.view'::text AS permission,
            st.id AS item_id,
            NULL::text AS doc_kind,
            st.code AS item_code,
            NULL::text AS subject,
            st.started_at::date AS item_date
           FROM stocktakes st
          WHERE st.deleted_at IS NULL AND st.status = 'open'::text
        UNION ALL
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_1.id AS item_id,
            NULL::text AS doc_kind,
            s_1.code AS item_code,
            (ct.name_en || ' — '::text) || s_1.legal_name AS subject,
            sc.valid_until AS item_date
           FROM supplier_compliance sc
             JOIN certificate_types ct ON ct.code = sc.cert_type_code
             JOIN suppliers s_1 ON s_1.id = sc.supplier_id
          WHERE sc.deleted_at IS NULL AND s_1.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND sc.valid_until IS NOT NULL AND sc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'qualification_missing'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_2.id AS item_id,
            NULL::text AS doc_kind,
            s_2.code AS item_code,
            s_2.legal_name AS subject,
            s_2.created_at::date AS item_date
           FROM suppliers s_2
          WHERE s_2.deleted_at IS NULL AND s_2.supplies_goods AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
                   FROM supplier_compliance sc2
                  WHERE sc2.supplier_id = s_2.id AND sc2.deleted_at IS NULL))
        UNION ALL
         SELECT 'credit_over_limit'::text AS item_type,
            'module.customers.view'::text AS permission,
            c_1.id AS item_id,
            NULL::text AS doc_kind,
            c_1.code AS item_code,
            c_1.legal_name AS subject,
            COALESCE(( SELECT min(sr.sale_date) AS min
                   FROM sales_records sr
                  WHERE sr.customer_id = c_1.id), CURRENT_DATE) AS item_date
           FROM customers c_1
          WHERE c_1.deleted_at IS NULL AND c_1.credit_limit_base IS NOT NULL AND customer_ar_exposure_visible(c_1.id) >= c_1.credit_limit_base
        UNION ALL
         SELECT 'output_unsold_aging'::text AS item_type,
            'module.output.view'::text AS permission,
            ob.id AS item_id,
            NULL::text AS doc_kind,
            ob.code AS item_code,
            ob.state AS subject,
            COALESCE(ob.output_date, ob.created_at::date) AS item_date
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0::numeric AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
        UNION ALL
         SELECT 'safety_stock_below'::text AS item_type,
            'module.inventory.view'::text AS permission,
            msa.material_id AS item_id,
            NULL::text AS doc_kind,
            msa.code AS item_code,
            (((((trim_scale(msa.available_qty)::text || ' / '::text) || trim_scale(msa.safety_stock_qty)::text) || ' '::text) || COALESCE(msa.unit, ''::text)) || ' — short '::text) || trim_scale(msa.safety_stock_qty - msa.available_qty)::text AS subject,
            COALESCE(msa.last_movement_date, CURRENT_DATE) AS item_date
           FROM material_stock_available msa
          WHERE msa.safety_stock_qty IS NOT NULL AND msa.available_qty < msa.safety_stock_qty
        UNION ALL
         SELECT 'leave_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            lr.id AS item_id,
            NULL::text AS doc_kind,
            lr.code AS item_code,
            e.legal_name AS subject,
            lr.created_at::date AS item_date
           FROM leave_requests lr
             JOIN employees e ON e.id = lr.employee_id
          WHERE lr.status = 'pending'::text AND lr.deleted_at IS NULL
        UNION ALL
         SELECT 'claim_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            mc.id AS item_id,
            NULL::text AS doc_kind,
            mc.code AS item_code,
            e.legal_name AS subject,
            mc.created_at::date AS item_date
           FROM medical_claims mc
             JOIN employees e ON e.id = mc.employee_id
          WHERE mc.status = 'submitted'::text AND mc.deleted_at IS NULL
        UNION ALL
         SELECT 'review_submitted'::text AS item_type,
            'module.hr.view'::text AS permission,
            r.id AS item_id,
            NULL::text AS doc_kind,
            e.code AS item_code,
            e.legal_name AS subject,
            COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
          WHERE r.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            i.invoice_id AS item_id,
            NULL::text AS doc_kind,
            i.code AS item_code,
            i.customer_name AS subject,
            i.due_date AS item_date
           FROM invoice_status i
          WHERE i.overdue
        UNION ALL
         SELECT 'ar_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            COALESCE(ar.sales_record_id, ar.invoice_id) AS item_id,
            ar.doc_kind,
            ar.doc_code AS item_code,
            ar.customer_name AS subject,
            ar.sale_date AS item_date
           FROM ar_open_items ar
          WHERE ar.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'ap_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ap.doc_id AS item_id,
            ap.doc_kind,
            ap.doc_code AS item_code,
            ap.supplier_name AS subject,
            ap.doc_date AS item_date
           FROM ap_open_items ap
          WHERE ap.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'fx_rate_gap'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            g.currency AS item_code,
            array_to_string(g.missing_types, ', '::text) AS subject,
            g.rate_date AS item_date
           FROM fx_rate_gaps g
          WHERE g.rate_date >= (CURRENT_DATE - 45)
        UNION ALL
         SELECT 'bank_unmatched'::text AS item_type,
            'module.finance.view'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.bank_account_code AS item_code,
            s.code AS subject,
            l.line_date AS item_date
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE l.match_status = 'unmatched'::text AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'margin_cost_not_allocated'::text AS item_type,
            'data.view_prices'::text AS permission,
            bm.run_id AS item_id,
            NULL::text AS doc_kind,
            bm.batch_code AS item_code,
            bm.material_name AS subject,
            ob.output_date AS item_date
           FROM batch_margin bm
             JOIN output_batches ob ON ob.id = bm.output_batch_id
          WHERE bm.margin_status = 'no_unit_cost'::text
        UNION ALL
         SELECT 'metal_quote_stale'::text AS item_type,
            'module.pricing.view'::text AS permission,
            mp.latest_id AS item_id,
            NULL::text AS doc_kind,
            mp.metal AS item_code,
            mp.latest_price::text AS subject,
            mp.max_date AS item_date
           FROM ( SELECT p.metal,
                    max(p.price_date) AS max_date,
                    (array_agg(p.id ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_id,
                    (array_agg(p.price_usd_per_tonne ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_price
                   FROM metal_prices p
                  WHERE p.deleted_at IS NULL
                  GROUP BY p.metal) mp
          WHERE (CURRENT_DATE - mp.max_date) > (( SELECT ps.metal_quote_stale_days
                   FROM pricing_settings ps
                 LIMIT 1))
        UNION ALL
         SELECT 'orders_unfulfilled'::text AS item_type,
            'module.sales.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            so.status AS subject,
            so.order_date AS item_date
           FROM sales_orders so
          WHERE so.deleted_at IS NULL AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
        UNION ALL
         SELECT 'work_order_overdue'::text AS item_type,
            'module.processing.view'::text AS permission,
            w.id AS item_id,
            NULL::text AS doc_kind,
            w.code AS item_code,
            w.scheduled_date::text AS subject,
            w.scheduled_date AS item_date
           FROM work_orders w
          WHERE w.status = 'released'::text AND w.scheduled_date IS NOT NULL AND w.scheduled_date < CURRENT_DATE
        UNION ALL
         SELECT 'work_order_variance_beyond'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.work_order_id AS item_id,
            NULL::text AS doc_kind,
            f.work_order_code AS item_code,
                CASE
                    WHEN f.side = 'input'::text THEN (((('input overrun · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                    ELSE (((('output shortfall · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                END AS subject,
            COALESCE(w2.scheduled_date, w2.created_at::date) AS item_date
           FROM work_order_fulfilment f
             JOIN work_orders w2 ON w2.id = f.work_order_id
          WHERE f.has_plan AND f.planned_or_expected_qty > 0::numeric AND (f.side = 'input'::text AND (w2.status = ANY (ARRAY['released'::text, 'closed'::text])) AND f.actual_qty > (f.planned_or_expected_qty * (1::numeric + (( SELECT ps.wo_input_overrun_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)) OR f.side = 'output'::text AND w2.status = 'closed'::text AND f.actual_qty < (f.planned_or_expected_qty * (1::numeric - (( SELECT ps.wo_output_shortfall_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)))
        UNION ALL
         SELECT 'free_time_expiring'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            ((((q.free_days - (CURRENT_DATE - arr.event_date))::text) || ' left of '::text) || q.free_days::text) || COALESCE(' — '::text || f.legal_name, ''::text) AS subject,
            arr.event_date AS item_date
           FROM containers c
             LEFT JOIN suppliers f ON f.id = c.forwarder_id
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'arrived'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) arr ON true
             JOIN forwarder_rate_quotes q ON q.supplier_id = c.forwarder_id AND q.lane_id = c.lane_id AND q.deleted_at IS NULL AND c.departure_date >= q.valid_from AND c.departure_date <= q.valid_to
          WHERE c.deleted_at IS NULL AND q.free_days IS NOT NULL AND (q.free_days - (CURRENT_DATE - arr.event_date)) <= 2
        UNION ALL
         SELECT 'container_no_arrival'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            dep.event_date::text AS subject,
            dep.event_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'departed'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) dep ON true
          WHERE c.deleted_at IS NULL AND (CURRENT_DATE - dep.event_date) >= 14 AND NOT (EXISTS ( SELECT 1
                   FROM container_milestones m2
                  WHERE m2.container_id = c.id AND m2.milestone = 'arrived'::text))
        UNION ALL
         SELECT 'container_eta_overdue'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            c.expected_arrival_date::text AS subject,
            c.expected_arrival_date AS item_date
           FROM containers c
          WHERE c.deleted_at IS NULL AND c.expected_arrival_date IS NOT NULL AND c.expected_arrival_date < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
                   FROM container_milestones m3
                  WHERE m3.container_id = c.id AND m3.milestone = 'arrived'::text))
        UNION ALL
         SELECT 'container_documents_late'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            p.n::text || ' pending'::text AS subject,
            c.departure_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT count(*) AS n
                   FROM container_documents d
                  WHERE d.container_id = c.id AND d.status = 'pending'::text) p ON true
          WHERE c.deleted_at IS NULL AND p.n > 0 AND (CURRENT_DATE - c.departure_date) >= 7
        UNION ALL
         SELECT 'equipment_service_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess.equipment_code AS item_code,
            (ess.service_kind || ' — '::text) || ess.equipment_description AS subject,
            ess.baseline_date AS item_date
           FROM equipment_service_status ess
          WHERE ess.monitored AND ess.disposition = 'warn'::text AND ess.equipment_status <> 'disposed'::text AND ess.is_due
        UNION ALL
         SELECT 'equipment_service_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess_1.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess_1.equipment_code AS item_code,
            (ess_1.service_kind || ' — '::text) || ess_1.equipment_description AS subject,
            ess_1.baseline_date AS item_date
           FROM equipment_service_status ess_1
          WHERE ess_1.monitored AND ess_1.disposition = 'warn'::text AND ess_1.equipment_status <> 'disposed'::text AND ess_1.is_approaching
        UNION ALL
         SELECT 'gateway_silent'::text AS item_type,
            'module.processing.view'::text AS permission,
            gh.gateway_id AS item_id,
            NULL::text AS doc_kind,
            gh.code AS item_code,
            gh.name AS subject,
            gh.last_heard_at::date AS item_date
           FROM gateway_health gh
          WHERE gh.status = 'silent'::text
        UNION ALL
         SELECT 'capture_inbox_failed'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.device_id AS item_id,
            NULL::text AS doc_kind,
            f.device_code AS item_code,
            (f.device_name || ' · '::text) || f.failed_rows::text AS subject,
            f.first_failed AS item_date
           FROM ( SELECT b.device_id,
                    d.code AS device_code,
                    d.name AS device_name,
                    count(*) AS failed_rows,
                    min(b.received_at)::date AS first_failed
                   FROM ingest_inbox b
                     JOIN devices d ON d.id = b.device_id
                  WHERE b.status = 'failed'::text
                  GROUP BY b.device_id, d.code, d.name) f
        UNION ALL
         SELECT 'promise_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            ps.promise_id AS item_id,
            NULL::text AS doc_kind,
            ps.chase_code AS item_code,
            ps.customer_name AS subject,
            ps.promised_date AS item_date
           FROM collection_promise_status ps
          WHERE ps.is_overdue
        UNION ALL
         SELECT 'wht_due'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            to_char(w.period_month::timestamp without time zone, 'YYYY-MM'::text) AS item_code,
            (to_char(w.unremitted_base, 'FM999G999G990D00'::text) || ' '::text) || (( SELECT c.code
                   FROM currencies c
                  WHERE c.is_base)) AS subject,
            w.due_date AS item_date
           FROM wht_liability_by_month w
          WHERE w.unremitted_base > 0::numeric AND (w.due_date - CURRENT_DATE) <= 7
        UNION ALL
         SELECT 'company_licence_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            cc.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(cc.cert_no, ct.code) AS item_code,
            ct.name_en AS subject,
            cc.valid_until AS item_date
           FROM company_compliance cc
             JOIN certificate_types ct ON ct.code = cc.cert_type_code
          WHERE cc.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND cc.valid_until IS NOT NULL AND cc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'import_permit_unverified'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            ib.code AS item_code,
            s.legal_name AS subject,
            ib.arrival_date AS item_date
           FROM inbound_batches ib
             JOIN suppliers s ON s.id = ib.supplier_id
          WHERE ib.deleted_at IS NULL AND ib.imported IS TRUE AND ib.import_permit_verified_at IS NULL
        UNION ALL
         SELECT 'payment_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            pr.id AS item_id,
            NULL::text AS doc_kind,
            pr.code AS item_code,
            COALESCE(s.legal_name, e.legal_name, c.legal_name) AS subject,
            pr.created_at::date AS item_date
           FROM payment_requests pr
             LEFT JOIN suppliers s ON s.id = pr.supplier_id
             LEFT JOIN employees e ON e.id = pr.employee_id
             LEFT JOIN customers c ON c.id = pr.customer_id
          WHERE pr.status = 'submitted'::text
        UNION ALL
         SELECT 'supplier_pending_approval'::text AS item_type,
            'action.supplier_approve'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            s.legal_name AS subject,
            COALESCE(( SELECT max(h.changed_at) AS max
                   FROM supplier_status_history h
                  WHERE h.supplier_id = s.id AND h.to_status = 'pending_review'::text), s.updated_at)::date AS item_date
           FROM suppliers s
          WHERE s.status = 'pending_review'::supplier_status AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'payroll_request_pending'::text AS item_type,
            'data.view_pay'::text AS permission,
            q.payroll_period_id AS item_id,
            NULL::text AS doc_kind,
            q.label AS item_code,
            pp.code AS subject,
            q.created_at::date AS item_date
           FROM payroll_requests q
             JOIN payroll_periods pp ON pp.id = q.payroll_period_id
          WHERE q.status = 'submitted'::text
        UNION ALL
         SELECT 'receipt_price_request_pending'::text AS item_type,
            'data.view_purchase_prices'::text AS permission,
            rq.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            rq.label AS item_code,
            ib.code AS subject,
            rq.created_at::date AS item_date
           FROM receipt_price_requests rq
             JOIN inbound_batches ib ON ib.id = rq.inbound_batch_id
          WHERE rq.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            iq.invoice_id AS item_id,
            NULL::text AS doc_kind,
            iq.label AS item_code,
            c.legal_name AS subject,
            iq.created_at::date AS item_date
           FROM invoice_requests iq
             JOIN invoices i ON i.id = iq.invoice_id
             JOIN customers c ON c.id = i.customer_id
          WHERE iq.status = 'submitted'::text
        UNION ALL
         SELECT 'shipping_release_pending'::text AS item_type,
            'module.sales.view'::text AS permission,
            sr.sales_order_id AS item_id,
            NULL::text AS doc_kind,
            sr.label AS item_code,
            c.legal_name AS subject,
            sr.created_at::date AS item_date
           FROM shipping_releases sr
             JOIN sales_orders so ON so.id = sr.sales_order_id
             JOIN customers c ON c.id = so.customer_id
          WHERE sr.status = 'submitted'::text
        UNION ALL
         SELECT 'journal_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            jq.id AS item_id,
            NULL::text AS doc_kind,
            jq.label AS item_code,
            jq.memo AS subject,
            jq.created_at::date AS item_date
           FROM journal_requests jq
          WHERE jq.status = 'submitted'::text
        UNION ALL
         SELECT 'warehouse_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            wq.id AS item_id,
            NULL::text AS doc_kind,
            wq.label AS item_code,
            wq.reason AS subject,
            wq.created_at::date AS item_date
           FROM warehouse_requests wq
          WHERE wq.status = 'submitted'::text
        UNION ALL
         SELECT 'terms_request_pending'::text AS item_type,
            'module.pricing.view'::text AS permission,
            tq.id AS item_id,
                CASE
                    WHEN tq.contract_id IS NOT NULL THEN 'contract'::text
                    ELSE 'formula'::text
                END AS doc_kind,
            tq.label AS item_code,
            tq.reason AS subject,
            tq.created_at::date AS item_date
           FROM terms_requests tq
          WHERE tq.status = 'submitted'::text
        UNION ALL
         SELECT 'asset_disposal_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            dq.id AS item_id,
            NULL::text AS doc_kind,
            dq.label AS item_code,
            dq.reason AS subject,
            dq.created_at::date AS item_date
           FROM asset_disposal_requests dq
          WHERE dq.status = 'submitted'::text
        UNION ALL
         SELECT 'salary_change_pending'::text AS item_type,
            'data.view_pay'::text AS permission,
            sq.employee_id AS item_id,
            NULL::text AS doc_kind,
            sq.label AS item_code,
            sq.reason AS subject,
            sq.created_at::date AS item_date
           FROM salary_change_requests sq
          WHERE sq.status = 'submitted'::text
        UNION ALL
         SELECT 'gst_filing_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            gq.period_id AS item_id,
            NULL::text AS doc_kind,
            gq.label AS item_code,
            gq.note AS subject,
            gq.created_at::date AS item_date
           FROM gst_filing_requests gq
          WHERE gq.status = 'submitted'::text
        UNION ALL
         SELECT 'shipping_release_ready'::text AS item_type,
            'action.ship_goods'::text AS permission,
            q.sales_order_id AS item_id,
            NULL::text AS doc_kind,
            q.order_code AS item_code,
            q.customer_name AS subject,
            q.released_on AS item_date
           FROM ( SELECT so.id AS sales_order_id,
                    so.code AS order_code,
                    c.legal_name AS customer_name,
                    max(r.decided_at)::date AS released_on
                   FROM shipping_releases r
                     JOIN shipping_release_lines rl ON rl.release_id = r.id
                     JOIN invoice_lines il ON il.id = rl.invoice_line_id
                     JOIN sales_orders so ON so.id = r.sales_order_id
                     JOIN customers c ON c.id = so.customer_id
                  WHERE r.status = 'approved'::text AND NOT il.invoice_voided
                    AND so.deleted_at IS NULL
                    AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
                    AND (( SELECT ra.releasable_qty
                           FROM sales_order_line_releasable_all ra
                          WHERE ra.invoice_line_id = il.id)) > COALESCE(( SELECT sum(sl.qty) AS sum
                           FROM shipment_lines sl
                          WHERE sl.sales_order_line_id = rl.sales_order_line_id), 0::numeric)
                  GROUP BY so.id, so.code, c.legal_name) q) a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type))) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));;

GRANT SELECT ON public.operations_now TO authenticated;

-- ── 9 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)────────────────
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.devices
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.devices
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.gateway_keys
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.gateway_keys
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.ingest_settings
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.ingest_settings
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.ingest_data_classes
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.ingest_data_classes
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 10 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
--   下面的自证跑在本体【里面】,所以权限要在这里先落好,自证才问得到真值。
REVOKE EXECUTE ON FUNCTION public.issue_gateway_key(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.issue_gateway_key(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.revoke_gateway_key(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revoke_gateway_key(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.save_device(jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_device(jsonb, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.retire_device(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.retire_device(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.set_ingest_settings(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_ingest_settings(jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.ingest_process_pending(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ingest_process_pending(integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.retry_inbox_row(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.retry_inbox_row(bigint) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.discard_inbox_row(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.discard_inbox_row(bigint, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.ingest_transform_row(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ingest_transform_row(bigint) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.transform_connection_test_v1(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transform_connection_test_v1(jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.generate_device_code() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.generate_device_code() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_devices_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_devices_write() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_gateway_keys_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_gateway_keys_write() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_ingest_transmissions_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_ingest_transmissions_write() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_ingest_inbox_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_ingest_inbox_write() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_gateway_outages_append_only() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_gateway_outages_append_only() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.ingest_submit(text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ingest_submit(text, text, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.ingest_transform_row(bigint) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.transform_connection_test_v1(jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.ingest_submit(text, text, jsonb) TO anon;
REVOKE EXECUTE ON FUNCTION public.ingest_submit(text, text, jsonb) FROM authenticated, service_role;

-- ── 11 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes1_pending_decider_check(p_after boolean DEFAULT true)
 RETURNS TABLE(k text, doc text, raiser text, subject text, deciders int, decider_names text)
 LANGUAGE sql STABLE
AS $f$
WITH fs AS (SELECT approval_level1_role_code AS l1, approval_level2_role_code AS l2 FROM public.finance_settings),
real_perm AS (
    SELECT DISTINCT rp.permission_code, rg.user_id
      FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     CROSS JOIN LATERAL public.real_role_grants(r.code) rg),
people AS (SELECT DISTINCT user_id FROM real_perm),
holds AS (SELECT user_id, array_agg(permission_code) AS codes FROM real_perm GROUP BY user_id),
items AS (
    -- 报销单:分档链,直接问 approval_deciders
    SELECT 'expense_claim'::text AS k, c.code::text AS doc, c.created_by AS raiser, c.employee_id AS subj,
           d.user_id AS u
      FROM public.expense_claims c CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim',
                 public.approval_level_for((SELECT b.amount_base FROM public.expense_claim_amount_base(c.id) b)),
                 c.created_by, c.employee_id, fs.l1, fs.l2) d ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- 采购单:分档链;金额档位按更严的二级问(一级的资格 ⊇ 二级,R1)
    SELECT 'purchase_order', p.code, p.created_by, NULL,
           d.user_id
      FROM public.purchase_orders p CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('purchase_order', 'approve_purchase_order', 2::smallint,
                 p.created_by, NULL, fs.l1, fs.l2) d ON true
     WHERE p.approval_status = 'pending' AND p.deleted_at IS NULL
    UNION ALL
    -- 请假:decide_leave_request 的门(之前 module.hr.edit,之后 action.decide_hr_requests)
    --       + 余额函数要 module.hr.view(或本人)+ 四眼(R2 之后覆盖请假)
    SELECT 'leave_request', l.code, l.created_by, l.employee_id, h.user_id
      FROM public.leave_requests l CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = l.employee_id)
                       AND (public.self_leg(l.created_by, l.employee_id, h.user_id) = 'none'
                            OR (p_after AND public.self_approval_exception('leave_request', l.employee_id, h.user_id, fs.l2)))
     WHERE l.status = 'pending' AND l.deleted_at IS NULL
    UNION ALL
    SELECT 'medical_claim_submitted', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = m.employee_id)
                       AND (public.self_leg(m.created_by, m.employee_id, h.user_id) = 'none'
                            OR public.self_approval_exception('medical_claim', m.employee_id, h.user_id, fs.l2))
     WHERE m.status = 'submitted' AND m.deleted_at IS NULL
    UNION ALL
    -- 已批未付的医疗申报:pay_medical_claim 只要 module.finance.edit,没有自付检查(量过,Tim 的矩阵允许)
    SELECT 'medical_claim_approved (pay)', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m
      LEFT JOIN holds h ON 'module.finance.edit' = ANY (h.codes)
     WHERE m.status = 'approved' AND m.deleted_at IS NULL
    UNION ALL
    SELECT 'performance_review', r.id::text, r.submitted_by, r.employee_id, h.user_id
      FROM public.performance_reviews r
      LEFT JOIN holds h ON (CASE WHEN p_after THEN public.review_approval_code(r.submitted_by, r.employee_id)
                                 ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND public.self_leg(r.submitted_by, r.employee_id, h.user_id) = 'none'
     WHERE r.status = 'submitted'
    UNION ALL
    SELECT 'work_order', w.code, w.created_by, NULL, h.user_id
      FROM public.work_orders w
      -- ROLE-1 Batch 3b:下达归 action.wo_release;建单人不算(按人认)
      LEFT JOIN holds h ON 'action.wo_release' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      -- ROLE-1 Batch 3a:过账归 action.stocktake_post;开单人与录过数的每一个人都不算(按人认)
      LEFT JOIN holds h ON 'action.stocktake_post' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.stocktake_counts c
                                        WHERE c.stocktake_id = s.id
                                          AND public.self_leg(c.counted_by, NULL, h.user_id) <> 'none')
     WHERE s.status = 'open' AND s.deleted_at IS NULL
    UNION ALL
    -- ★ APR-7(grilling Q9):每一条申请链 —— 付款、工资、收货定价、贷项 / 作废、发货放行、手工凭证、仓库申请。
    --   它们在 approval_pending_documents 里带 fixed_level;决定人按 approval_deciders 问(与提交时的
    --   assert_other_decider 同一份判据),门取 approval_chain_gates 里那一行。APR-5b / APR-6 的自证只问了
    --   "这条链此刻有没有人",没有逐张问 —— 这一支补上。
    SELECT pd.subject_type, pd.code, pd.raiser_user_id, pd.subject_employee_id, d.user_id
      FROM public.approval_pending_documents() pd
      JOIN public.approval_chain_gates() g ON g.subject_type = pd.subject_type AND g.level = pd.fixed_level
     CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders(pd.subject_type, g.action_function, pd.fixed_level,
                 pd.raiser_user_id, pd.subject_employee_id, fs.l1, fs.l2) d ON true
     WHERE pd.fixed_level IS NOT NULL AND pd.subject_type NOT IN ('expense_claim', 'purchase_order')
    UNION ALL
    -- ★ APR-9:调薪申请按人路由(pay_decision_code),不在 approval_chain_gates 里 —— 问 salary_change_deciders,
    --   与 submit_salary_change_request 的"别人批得动吗"同一份判据。
    SELECT 'salary_change_request', q.label, q.created_by, q.employee_id, d.user_id
      FROM public.salary_change_requests q
      LEFT JOIN LATERAL public.salary_change_deciders(q.created_by, q.employee_id) d ON true
     WHERE q.status = 'submitted'
)
SELECT i.k, i.doc,
       (SELECT email::text FROM auth.users WHERE id = i.raiser),
       (SELECT legal_name FROM public.employees WHERE id = i.subj),
       count(DISTINCT COALESCE(public.account_person(i.u)::text, i.u::text))::int,
       string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = i.u), ' ')
  FROM items i
 GROUP BY i.k, i.doc, i.raiser, i.subj
 ORDER BY 1, 2
$f$;

CREATE TEMP TABLE mes1_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权只多那两行(admin · cto ← action.manage_devices),一行没少
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes1_grants_before
         EXCEPT SELECT unnest(ARRAY['admin:action.manage_devices', 'cto:action.manage_devices']))
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES1_PROOF|unexpected grant change: %', v_bad; END IF;
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'action.manage_devices') <> 2 THEN
        RAISE EXCEPTION 'MES1_PROOF|action.manage_devices should be held by exactly admin and cto';
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;变更记录只在种子那几张表上动了
    IF EXISTS ((SELECT b.k, b.id FROM mes1_pending_before b EXCEPT SELECT a.k, a.id FROM mes1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes1_pending_after a EXCEPT SELECT b.k, b.id FROM mes1_pending_before b)) THEN
        RAISE EXCEPTION 'MES1_PROOF|a pending document changed state';
    END IF;
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM mes1_log_before)
       AND c.table_name NOT IN ('permissions', 'role_permissions', 'document_types', 'document_type_exceptions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES1_PROOF|change_log moved on %', v_bad; END IF;

    -- ④ 新表:除了两张种子表,一行都没有;种子是九类数据、一行上限
    IF EXISTS (SELECT 1 FROM devices) OR EXISTS (SELECT 1 FROM gateway_keys) OR EXISTS (SELECT 1 FROM ingest_inbox)
       OR EXISTS (SELECT 1 FROM ingest_transmissions) OR EXISTS (SELECT 1 FROM gateway_outages) THEN
        RAISE EXCEPTION 'MES1_PROOF|a new log or register table is not empty';
    END IF;
    IF (SELECT count(*) FROM ingest_data_classes) <> 9
       OR (SELECT count(*) FROM ingest_data_classes WHERE transform_function IS NOT NULL) <> 1
       OR (SELECT count(*) FROM ingest_settings) <> 1 THEN
        RAISE EXCEPTION 'MES1_PROOF|the seeds are not nine classes (one transformer) and one settings row';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 42 THEN RAISE EXCEPTION 'MES1_PROOF|document_types is not 42 rows'; END IF;

    -- ⑤ 匿名面:anon 能执行的【恰好】两支;ingest_submit 对 authenticated 与 service_role 关着;员工那几支 anon 调不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES1_PROOF|anon executes: %', v_bad;
    END IF;
    IF has_function_privilege('authenticated', 'public.ingest_submit(text, text, jsonb)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('service_role', 'public.ingest_submit(text, text, jsonb)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES1_PROOF|ingest_submit is callable by authenticated or service_role';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.issue_gateway_key(uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.issue_gateway_key(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.issue_gateway_key(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES1_PROOF|public.issue_gateway_key(uuid): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.revoke_gateway_key(uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.revoke_gateway_key(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.revoke_gateway_key(uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES1_PROOF|public.revoke_gateway_key(uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.save_device(jsonb, uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.save_device(jsonb, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.save_device(jsonb, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES1_PROOF|public.save_device(jsonb, uuid): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.retire_device(uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.retire_device(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.retire_device(uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES1_PROOF|public.retire_device(uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.set_ingest_settings(jsonb)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.set_ingest_settings(jsonb)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.set_ingest_settings(jsonb)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES1_PROOF|public.set_ingest_settings(jsonb): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.ingest_process_pending(integer)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.ingest_process_pending(integer)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.ingest_process_pending(integer)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES1_PROOF|public.ingest_process_pending(integer): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.retry_inbox_row(bigint)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.retry_inbox_row(bigint)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.retry_inbox_row(bigint)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES1_PROOF|public.retry_inbox_row(bigint): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.discard_inbox_row(bigint, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.discard_inbox_row(bigint, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.discard_inbox_row(bigint, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES1_PROOF|public.discard_inbox_row(bigint, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF has_function_privilege('authenticated', 'public.ingest_transform_row(bigint)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.ingest_transform_row(bigint)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES1_PROOF|public.ingest_transform_row(bigint) must not be callable from outside';
    END IF;
    IF has_function_privilege('authenticated', 'public.transform_connection_test_v1(jsonb)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.transform_connection_test_v1(jsonb)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES1_PROOF|public.transform_connection_test_v1(jsonb) must not be callable from outside';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('devices', 'gateway_keys', 'ingest_settings', 'ingest_data_classes', 'ingest_inbox',
           'ingest_transmissions', 'gateway_outages', 'gateway_keys_masked', 'gateway_health', 'ingest_sequence_gaps',
           'ingest_transmission_anomalies', 'pending_values')
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES1_PROOF|anon can read %', v_bad; END IF;
    IF has_column_privilege('authenticated', 'public.gateway_keys', 'key_hash', 'SELECT') THEN
        RAISE EXCEPTION 'MES1_PROOF|gateway_keys.key_hash is readable by authenticated';
    END IF;

    -- ⑥ 那 44 条开着的读策略还是 44 条,没有一条落在新表上
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES1_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND qual = 'true'
                AND tablename IN ('devices', 'gateway_keys', 'ingest_settings', 'ingest_data_classes', 'ingest_inbox',
                                  'ingest_transmissions', 'gateway_outages')) THEN
        RAISE EXCEPTION 'MES1_PROOF|an open read policy sits on a MES-1 table';
    END IF;

    -- ⑦ 变更记录:覆盖零缺口(四张记、三张豁免);遮蔽零缺口(105 条)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 7 THEN
        RAISE EXCEPTION 'MES1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑧ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
