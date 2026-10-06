-- db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql
-- MES-2 —— 确认、称重与校准(MES 组的第二刀,v1.4.38;发布那一行在 docs/handbacks/MES-2.md 的抬头)。
-- 由 db/scripts/build_mes2_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-06:MES-2 Step 0 的 Q1–Q35 全部照建议裁定;MES-0 Q1–Q96 与 MES-1 Q1–Q30 照旧成立)
--   ① 七张表:capture_drafts(草稿)· capture_draft_changes(确认时改过的值)· weighings(称重的正式记录)·
--      weighbridge_tickets(地磅单 WB-)· weighbridge_ticket_shares(分给收货单 / 发货行的份)· weighbridge_ticket_photos ·
--      instrument_calibrations(校准记录)。七张都进变更记录,没有一列遮蔽。
--   ② 两张既有表各加列:ingest_settings(require_calibrated_since —— 校准规则的开关,空 = 关;calibration_lead_days —— V8);
--      ingest_data_classes(creates_draft)。weighing 那一行接上 transform_weighing_v1、手工录入码 action.confirm_capture、落草稿。
--   ③ 分派器落草稿;"Process received" 也取已有转换器的 awaiting_transform 行;手工录入、确认 / 驳回 / 更正;地磅单、份、照片;
--      校准记录;校准闸(reprice_inbound_batch · 它的试算 · issue_cod)—— 开关空着时什么都不拒。
--   ④ 两支收货函数末尾多三个参数(地磅单的份 + 数量的理由):DROP + CREATE,参数都带默认值,旧应用的调用照样解析。
--   ⑤ 一个码:action.confirm_capture → admin · cto · warehouse。单据种类 WB(有洞)。
--   ⑥ 视图:weighing_calibration_all(基视图,不给人读)· weighing_calibration · instrument_calibration_now ·
--      weighbridge_ticket_weights;operations_now 多三支(capture_draft_pending · instrument_calibration_due ·
--      instrument_calibration_approaching),列契约一字未动;pending_values 多两支(V8 · V33)。
--   ⑦ 私有桶 capture-photos 与它的两条策略(读:收货或物流查看码;传:action.confirm_capture;不能改、不能删)。
--      桶不在镜像里(AGENTS.md),它的证明是 db/scripts/2026-10-06-mes2-capture-photos-policy-proof.sql。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不写、不改任何一张既有单据;require_calibrated_since 保持空。
--   唯一的数据写入:权限码一行与它的三条授权 · 单据种类一行 · 数据类 weighing 那一行的三格 · 一个桶。
--
-- 【破窗】旧应用调两支收货函数时不传新参数 —— 它们带默认值,照样解析(DROP + CREATE 之后 NOTIFY pgrst 重载);
--   reprice_inbound_batch 与 issue_cod 在开关为空时与从前逐字同一个结果;新表、新视图旧应用一样都不读;
--   operations_now 列不变,旧的提醒页按它自己的清单画牌子,三支新臂被跳过。线上没有一行 weighing 类的收件箱(MES-1 的探针只发
--   connection_test),所以分派器从这一刻起落草稿,也没有东西可落。预计窗口里什么都不坏。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权只多那三行;在途单据一张不少、一张不多;七个账号一个都没被停;
--   变更记录只在种子那几张表上动了;anon 能执行的【恰好】两支;员工那几支 anon 调不到、内层谁都调不到;那 44 条开着的读策略
--   还是 44 条、没有一条落在新表上;变更记录覆盖与遮蔽零缺口;每一张在途单据仍有一个不是它当事人的决定人;开关是空的。
--   断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES2_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.capture_drafts') IS NOT NULL OR to_regclass('public.weighings') IS NOT NULL
       OR to_regclass('public.weighbridge_tickets') IS NOT NULL OR to_regclass('public.instrument_calibrations') IS NOT NULL THEN
        RAISE EXCEPTION 'MES2_PRE|MES-2 objects already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code = 'action.confirm_capture')
       OR EXISTS (SELECT 1 FROM document_types WHERE key = 'weighbridge_ticket') THEN
        RAISE EXCEPTION 'MES2_PRE|the code or the document type already exists';
    END IF;
    IF (SELECT count(*) FROM roles WHERE code IN ('admin', 'cto', 'warehouse')) <> 3 THEN
        RAISE EXCEPTION 'MES2_PRE|roles admin, cto and warehouse are expected';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES2_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES2_PRE|expected 105 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM document_types) <> 42 THEN
        RAISE EXCEPTION 'MES2_PRE|expected 42 document types';
    END IF;
    IF EXISTS (SELECT 1 FROM ingest_inbox WHERE data_class = 'weighing') THEN
        RAISE EXCEPTION 'MES2_PRE|weighing rows already wait in the inbox';
    END IF;
    IF EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'capture-photos') THEN
        RAISE EXCEPTION 'MES2_PRE|bucket capture-photos already exists';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes2_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes2_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;

-- ── 1 · 一个码(镜像原样)与授权 —— admin 拿到每一个新码(常设裁定);warehouse · cto 是 MES-0 Q11 / Q90 点名的持有人。幂等。──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.confirm_capture', 'action', 'Confirm captured readings', '确认采集到的数据', 'Confirm or reject the drafts that scales and other devices send (a changed value keeps the original and needs a reason), enter a weighing by hand, correct a confirmed weighing, open and void weighbridge tickets, and add or withdraw ticket photos. Reading the queue needs only Processing (view).', '确认或驳回秤与其他设备送来的草稿(改过的值留着原值并要写理由)、手工录入一次称重、更正一次已确认的称重、开出与作废地磅单、传上或撤下地磅单的照片。读确认队列只要「加工(查看)」。', 1230);

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, 'action.confirm_capture' FROM roles r WHERE r.code IN ('admin', 'cto', 'warehouse')
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 2 · 触发器函数(镜像原样)—— 表上的触发器要先有它们 ──────────────────────────

-- db/functions/guard_capture_append_only.sql
-- MES-2(2026-10-06,规格 §4.2 · §6.3;MES-0 §3.7;MES-2 Step 0 Q9 · Q11 · Q18):三张【只追加】的采集记录共用的守卫 ——
--   weighings(正式称重记录:更正是一条新行,corrects_id 指回原行)· capture_draft_changes(确认时改过的值,原值 + 新值 + 理由)·
--   weighbridge_ticket_shares(地磅单分给收货单 / 发货行的公斤数)。
--   UPDATE 一律拒(行级);DELETE / TRUNCATE 一律拒(【语句级】—— 没有 DELETE 策略时 authenticated 的 DELETE 在 RLS 那里就是
--   零行,行级触发器不会醒,U1-B 的那一课)。CAPTURE_RECORD_APPEND_ONLY|<表>|<操作>。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.guard_capture_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'CAPTURE_RECORD_APPEND_ONLY|%|%', TG_TABLE_NAME, lower(TG_OP);
END;
$function$;

-- db/functions/guard_capture_drafts_write.sql
-- MES-2(2026-10-06,规格 §6.3;MES-0 Q12 · Q13;MES-2 Step 0 Q4 · Q10):草稿的守卫。
--   ① DELETE / TRUNCATE 一律拒(CAPTURE_DRAFT_NEVER_DELETED),语句级 —— 草稿永不过期、永不删(MES-0 Q13)。
--   ② 一张草稿只决定一次:确认或驳回之后冻住(CAPTURE_DRAFT_DECIDED|<id>)。驳回是终局(Q10)。
--   ③ 唯一会变的是【决定】那几列(status · confirmed_at/by · rejected_at/by · reject_reason);转换器给的 proposed、
--      收件箱那一行、设备、数据类、来源一个字都不改(CAPTURE_DRAFT_ONLY_DECISION|<id>)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.guard_capture_drafts_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'CAPTURE_DRAFT_NEVER_DELETED';
    END IF;
    IF OLD.status <> 'pending' THEN
        RAISE EXCEPTION 'CAPTURE_DRAFT_DECIDED|%', OLD.id;
    END IF;
    IF (to_jsonb(NEW) - 'status' - 'confirmed_at' - 'confirmed_by' - 'rejected_at' - 'rejected_by' - 'reject_reason')
       IS DISTINCT FROM
       (to_jsonb(OLD) - 'status' - 'confirmed_at' - 'confirmed_by' - 'rejected_at' - 'rejected_by' - 'reject_reason') THEN
        RAISE EXCEPTION 'CAPTURE_DRAFT_ONLY_DECISION|%', OLD.id;
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_weighbridge_tickets_write.sql
-- MES-2(2026-10-06,MES-0 Q19;MES-2 Step 0 Q16):地磅单的守卫。
--   ① DELETE / TRUNCATE 一律拒(TICKET_NEVER_DELETED),语句级 —— 一张不要了的单的去处是作废(要理由、而且没有分出去的份)。
--   ② 作废之后冻住(TICKET_VOIDED|<编号>)。
--   ③ 编号、方向、建单人与时刻定下就不动(TICKET_FIELD_FIXED|<编号>):方向决定第一磅是毛重还是皮重(Q16),
--      改了它,已经落下的那一磅的角色就说错了。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.guard_weighbridge_tickets_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'TICKET_NEVER_DELETED';
    END IF;
    IF OLD.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'TICKET_VOIDED|%', OLD.code;
    END IF;
    IF NEW.code IS DISTINCT FROM OLD.code OR NEW.direction IS DISTINCT FROM OLD.direction
       OR NEW.created_at IS DISTINCT FROM OLD.created_at OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION 'TICKET_FIELD_FIXED|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/generate_weighbridge_ticket_code.sql
-- MES-2(2026-10-06,MES-0 Q53;MES-2 Step 0 Q16):地磅单编号 WB-YYYY-NNNN —— 有洞(nextval 回滚不还号),保存时生成。
-- 形状与 generate_device_code 逐字同一个(前缀经 document_type_prefix('weighbridge_ticket') 读,年取 NOW(),四位补零);
-- 只填空的 code。不是 SECURITY DEFINER:它是 weighbridge_tickets 的 BEFORE INSERT 触发器,插入只经确认 / 手工录入那几支函数。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.generate_weighbridge_ticket_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := document_type_prefix('weighbridge_ticket') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('weighbridge_ticket_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_ticket_photos_write.sql
-- MES-2(2026-10-06,MES-0 Q20;MES-2 Step 0 Q21):地磅单照片的守卫。
--   ① DELETE / TRUNCATE 一律拒(TICKET_PHOTO_NEVER_DELETED),语句级 —— 一张拍错的照片【撤下】(带理由),行与对象都留着。
--   ② 撤下之后冻住(TICKET_PHOTO_WITHDRAWN|<id>)。
--   ③ 唯一会变的是撤下那三列(TICKET_PHOTO_ONLY_WITHDRAW|<id>):文件路径、类型、大小、谁何时传的一个字都不改。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.guard_ticket_photos_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'TICKET_PHOTO_NEVER_DELETED';
    END IF;
    IF OLD.withdrawn_at IS NOT NULL THEN
        RAISE EXCEPTION 'TICKET_PHOTO_WITHDRAWN|%', OLD.id;
    END IF;
    IF (to_jsonb(NEW) - 'withdrawn_at' - 'withdrawn_by' - 'withdraw_reason')
       IS DISTINCT FROM (to_jsonb(OLD) - 'withdrawn_at' - 'withdrawn_by' - 'withdraw_reason') THEN
        RAISE EXCEPTION 'TICKET_PHOTO_ONLY_WITHDRAW|%', OLD.id;
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_instrument_calibrations_write.sql
-- MES-2(2026-10-06,规格 §8.2;MES-0 Q31;MES-2 Step 0 Q24):校准记录的守卫 —— 只追加。
--   ① DELETE / TRUNCATE 一律拒(CALIBRATION_NEVER_DELETED),语句级。
--   ② 一条记错了的校准【作废】(带理由),不改:作废之后冻住(CALIBRATION_VOIDED|<id>)。
--   ③ 唯一会变的是作废那三列(CALIBRATION_ONLY_VOID|<id>):日期、有效期、结论、证书号、机构一个字都不改 ——
--      "某一刻这台仪器在不在校准期内"是从这些列【读的时候推出来的】(Q25),改它们就是改历史。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.guard_instrument_calibrations_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'CALIBRATION_NEVER_DELETED';
    END IF;
    IF OLD.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'CALIBRATION_VOIDED|%', OLD.id;
    END IF;
    IF (to_jsonb(NEW) - 'voided_at' - 'voided_by' - 'void_reason')
       IS DISTINCT FROM (to_jsonb(OLD) - 'voided_at' - 'voided_by' - 'void_reason') THEN
        RAISE EXCEPTION 'CALIBRATION_ONLY_VOID|%', OLD.id;
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 3 · 两张既有表各加列(ALTER 加的列,镜像里在 CREATE 的末尾)与注释;weighing 那一行接上转换器 ────────────────
ALTER TABLE public.ingest_settings ADD COLUMN require_calibrated_since date;
ALTER TABLE public.ingest_settings ADD COLUMN calibration_lead_days integer CHECK (calibration_lead_days > 0);
ALTER TABLE public.ingest_data_classes ADD COLUMN creates_draft boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.ingest_settings.require_calibrated_since IS
    'MES-2(Q26):校准规则的开关 —— 一个日期,空 = 关。关着时校准状态处处看得见,但什么都不拒。开着时,【这一天及以后建的】收货单定价与销毁证书在三种情形下按名拒:读数的仪器不在校准期内(READING_INSTRUMENT_NOT_CALIBRATED)、读数没有记录仪器(READING_INSTRUMENT_NOT_RECORDED)、收货单没有挂任何一次称重(RECEIPT_READING_NOT_RECORDED)。更早的收货单不受影响。';
COMMENT ON COLUMN public.ingest_settings.calibration_lead_days IS
    'MES-2(V8,Q30):校准到期前多少天开始提醒 —— 一个数,所有仪器共用;空 = "Not yet set",到期前的提醒(instrument_calibration_approaching)不上牌,过期本身照样上牌(每一条记录自己的有效期是必填的)。由校准机构 / 仪器厂商给。';
COMMENT ON COLUMN public.ingest_data_classes.creates_draft IS
    'MES-2:这一类转换成功之后,分派器在同一个子事务里落一张草稿(capture_drafts)等人确认。weighing 为真;connection_test 为假。';
UPDATE public.ingest_data_classes
   SET target_en = 'Weighing records', transform_function = 'transform_weighing_v1', manual_entry_code = 'action.confirm_capture', creates_draft = true
 WHERE code = 'weighing';

-- ── 4 · 七张表(镜像原样:表 · 触发器 · RLS · 授权)────────────────────────────────

-- db/tables/capture_drafts.sql
-- MES-2(2026-10-06,规格 §6.3;MES-0 §3.6 · Q10–Q13;MES-2 Step 0 Q4 · Q8 · Q10,Tim):【草稿】—— 网关送来的数据先成为一张草稿,
--   工位上的人确认之后才成为正式记录(规格 §6.3:"Automatic direct posting is not used")。
--
-- 【一行收件箱 → 一张草稿】(Q4)分派器(ingest_transform_row)在把收件箱一行标成 transformed 的同一个子事务里,
--   为 creates_draft 为真的那几类(MES-2:weighing)落一张草稿;proposed = 转换器的输出,原样。inbox_id 唯一。
--   转换器是 IMMUTABLE、只吃 payload(MES-1 的决定 7),所以它落不了草稿 —— 分派器落。
-- 【决定】pending → confirmed(confirm_capture_draft,写出正式记录 weighings,改过的值各一行 capture_draft_changes)
--   或 rejected(reject_capture_draft,理由必填,终局 —— Q10)。决定只做一次,之后冻住(守卫)。草稿永不过期(MES-0 Q13),
--   提醒臂 capture_draft_pending 按年龄列出来。
-- 【手工录入】(MES-0 Q10)同一条路:收件箱一行(source = manual)→ 同一支转换器 → 草稿 → 同一步里由录入人确认。
--   于是手工的草稿生下来就是 confirmed;一张 pending 的草稿只可能来自网关。
-- 【读】module.processing.view(MES-0 §3.10);【写】只经函数,没有写策略。进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.capture_drafts (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbox_id      bigint NOT NULL UNIQUE REFERENCES public.ingest_inbox (id),
    data_class    text NOT NULL REFERENCES public.ingest_data_classes (code),
    source        text NOT NULL CHECK (source IN ('device', 'manual')),
    device_id     uuid REFERENCES public.devices (id),
    station       text,
    proposed      jsonb NOT NULL,
    status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'rejected')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    confirmed_at  timestamptz,
    confirmed_by  uuid,
    rejected_at   timestamptz,
    rejected_by   uuid,
    reject_reason text,
    CONSTRAINT capture_drafts_confirmed_shape
        CHECK ((status = 'confirmed') = (confirmed_at IS NOT NULL AND confirmed_by IS NOT NULL)),
    CONSTRAINT capture_drafts_rejected_shape
        CHECK ((status = 'rejected') = (rejected_at IS NOT NULL AND rejected_by IS NOT NULL
                                        AND btrim(COALESCE(reject_reason, '')) <> ''))
);

COMMENT ON TABLE public.capture_drafts IS
    'MES-2:草稿(规格 §6.3)。分派器为 creates_draft 的数据类(weighing)每一行 transformed 的收件箱落一张,proposed = 转换器输出。pending → confirmed(写出 weighings,改过的值记在 capture_draft_changes)或 rejected(理由必填,终局)。只决定一次;永不过期、永不删。手工录入在同一步里由录入人确认。读:module.processing.view;写只经函数。';

CREATE INDEX capture_drafts_status ON public.capture_drafts (status, created_at);
CREATE INDEX capture_drafts_device ON public.capture_drafts (device_id);

CREATE TRIGGER trg_capture_drafts_write
    BEFORE UPDATE ON public.capture_drafts
    FOR EACH ROW EXECUTE FUNCTION public.guard_capture_drafts_write();
CREATE TRIGGER trg_capture_drafts_no_delete
    BEFORE DELETE OR TRUNCATE ON public.capture_drafts
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_capture_drafts_write();

ALTER TABLE public.capture_drafts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "capture_drafts select by permission" ON public.capture_drafts
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.capture_drafts FROM anon;

-- db/tables/capture_draft_changes.sql
-- MES-2(2026-10-06,规格 §6.3;MES-0 §3.6 · Q12;MES-2 Step 0 Q9,Tim):【确认时改过的值】—— 原值、确认值、理由,一个字段一行。
--   规格 §6.3:"both the original and corrected values are retained and a reason for correction is required"。
--   confirm_capture_draft 只在确认值与 proposed 里那一格【不一样】时落一行;理由必填(CHECK + 函数里按名拒
--   CAPTURE_CHANGE_REASON_REQUIRED|<字段>)。能改的只有【量出来的值】(称重:weight_kg);设备、网关、序号、来源、现场时间
--   一个都改不了(CAPTURE_FIELD_FIXED|<字段>,MES-0 Q12)。主语(哪一张地磅单、毛重还是皮重)是确认时【选】的 ——
--   网关的 proposed 里没有它(Q7:payload 只有 weight_kg),所以选它不是"改",不落行。
--   只追加(guard_capture_append_only)。进变更记录。读:module.processing.view。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.capture_draft_changes (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    draft_id        uuid NOT NULL REFERENCES public.capture_drafts (id),
    field           text NOT NULL CHECK (field ~ '^[a-z][a-z0-9_]*$'),
    original_value  jsonb,
    confirmed_value jsonb NOT NULL,
    reason          text NOT NULL CHECK (btrim(reason) <> ''),
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    CONSTRAINT capture_draft_changes_one_per_field UNIQUE (draft_id, field),
    CONSTRAINT capture_draft_changes_really_changed CHECK (original_value IS DISTINCT FROM confirmed_value)
);

COMMENT ON TABLE public.capture_draft_changes IS
    'MES-2:确认时改过的值(规格 §6.3)—— 原值、确认值、必填理由,一个字段一行;只在两者不同时落。能改的只有量出来的值(weight_kg);设备、网关、序号、来源、现场时间改不了。只追加。';

CREATE TRIGGER trg_capture_draft_changes_append_only
    BEFORE UPDATE ON public.capture_draft_changes
    FOR EACH ROW EXECUTE FUNCTION public.guard_capture_append_only();
CREATE TRIGGER trg_capture_draft_changes_no_delete
    BEFORE DELETE OR TRUNCATE ON public.capture_draft_changes
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_capture_append_only();

ALTER TABLE public.capture_draft_changes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "capture_draft_changes select by permission" ON public.capture_draft_changes
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.capture_draft_changes FROM anon;

-- db/tables/weighbridge_tickets.sql
-- MES-2(2026-10-06,MES-0 Q19 · Q53;MES-2 Step 0 Q16 · Q17 · Q22,Tim):【地磅单】—— 一辆车进出地磅的那两磅。
--
-- 【两磅成一张】一张单由它的第一磅开出、第二磅完成(Q16):进厂(inbound)第一磅是毛重(满载进来),出厂(outbound)
--   第一磅是皮重(空车进来);第二磅是另一种。净重 = 毛重 − 皮重,≤ 0 按名拒(TICKET_NET_NOT_POSITIVE)。
--   两磅是 weighings 里 ticket_id 指着本单的那两行(角色 gross / tare);【更正】是一条新的称重(corrects_id),本单读最新的那一行,
--   所以毛重、皮重、净重、状态都【不存在本表】—— 在视图 weighbridge_ticket_weights 里读的时候算(一份算术,不两份)。
--   completed_at 是第二磅落下的那一刻(只记一次,给列表排序与"完成于"用)。
-- 【车】只记车牌(Q17):必填;不记司机姓名、不记证件号 —— 下游没有一处要一个人,车牌是过磅员配进出两磅的凭据。
-- 【编号】WB-YYYY-NNNN,有洞,保存时生成(MES-0 Q53);前缀住在 document_types(key weighbridge_ticket)。
-- 【作废】只在它【一份都没分出去】的时候,带理由(TICKET_HAS_SHARES)。不删(守卫)。
-- 【读】module.inbound.view 或 module.logistics.view(Q22,与照片桶同一道门);【写】只经函数。进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.
-- First-run script (plain CREATEs).

CREATE SEQUENCE public.weighbridge_ticket_code_seq;

CREATE TABLE public.weighbridge_tickets (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code         text NOT NULL UNIQUE,
    direction    text NOT NULL CHECK (direction IN ('inbound', 'outbound')),
    vehicle_reg  text NOT NULL CHECK (btrim(vehicle_reg) <> '' AND char_length(vehicle_reg) <= 20),
    notes        text,
    completed_at timestamptz,
    voided_at    timestamptz,
    voided_by    uuid,
    void_reason  text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    CONSTRAINT weighbridge_tickets_voided_shape
        CHECK ((voided_at IS NULL) = (voided_by IS NULL)
               AND (voided_at IS NULL OR btrim(COALESCE(void_reason, '')) <> ''))
);

COMMENT ON TABLE public.weighbridge_tickets IS
    'MES-2:地磅单 WB-YYYY-NNNN。一辆车进出的两磅:进厂第一磅毛重、出厂第一磅皮重;净重 = 毛重 − 皮重(> 0)。两磅是 weighings 里指着本单的行(更正读最新的),重量与状态在 weighbridge_ticket_weights 里读的时候算。只记车牌。作废要理由、且一份都没分出去。读:module.inbound.view 或 module.logistics.view。';
COMMENT ON COLUMN public.weighbridge_tickets.completed_at IS
    '第二磅落下的那一刻(记一次)。毛重、皮重、净重不在本表 —— 见视图 weighbridge_ticket_weights。';

CREATE INDEX weighbridge_tickets_created ON public.weighbridge_tickets (created_at);

CREATE TRIGGER trg_weighbridge_tickets_code
    BEFORE INSERT ON public.weighbridge_tickets
    FOR EACH ROW EXECUTE FUNCTION public.generate_weighbridge_ticket_code();
CREATE TRIGGER trg_weighbridge_tickets_updated_at
    BEFORE UPDATE ON public.weighbridge_tickets
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER trg_weighbridge_tickets_write
    BEFORE UPDATE ON public.weighbridge_tickets
    FOR EACH ROW EXECUTE FUNCTION public.guard_weighbridge_tickets_write();
CREATE TRIGGER trg_weighbridge_tickets_no_delete
    BEFORE DELETE OR TRUNCATE ON public.weighbridge_tickets
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_weighbridge_tickets_write();

ALTER TABLE public.weighbridge_tickets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "weighbridge_tickets select by permission" ON public.weighbridge_tickets
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((has_permission('module.inbound.view'::text) OR has_permission('module.logistics.view'::text)));

REVOKE ALL ON public.weighbridge_tickets FROM anon;

-- db/tables/weighings.sql
-- MES-2(2026-10-06,规格 §3.2 · §6.3 · §8.2;MES-0 §3.9 · Q12;MES-2 Step 0 Q7 · Q9 · Q11 · Q14 · Q22,Tim):【称重 —— 正式记录】。
--
-- 【怎么来的】一张确认了的草稿(网关送来的,或手工录入在同一步里确认的)。inbox_id 与 draft_id 各唯一,
--   于是一条称重一跳回到它的收件箱那一行(网关、流、序号、原始 payload)与它的草稿(改过什么、谁确认的)。
-- 【读数】weight_kg(> 0)—— 确认时的值;转换器给的原值若被改过,原值与理由在 capture_draft_changes 里。
-- 【仪器】device_id = 读数来自哪一台秤 / 地磅;为空 = 没有记录仪器("instrument not recorded",Q14:手工录入可以不选,
--   标出来,不拒)。校准状态在读数的那一刻是否有效,从 instrument_calibrations 读的时候推(Q25,视图 weighing_calibration)。
-- 【主语】ticket_id + role:挂在一张地磅单上的是毛重或皮重(gross / tare);不挂单的是一次单独的净重(net)。
--   称重挂到批次与加工的进出料是 MES-4a 的事(MES-0 Q22)。
-- 【现场指针】site_from · site_to · site_dataset_ref(规格 §2.1:原始数据留在现场,ERP 只存指针);captured_at = 读数的时刻
--   (现场时间,没有就取确认时刻)—— 校准判据看的正是它。
-- 【只追加】(规格 §4.2)更正是一条新行:corrects_id 指回被更正的那一行、correction_reason 必填(Q11);读的人取【没有被更正过】
--   的那一行。每一行最多被更正一次(corrects_id 唯一),所以"最新"是一条链的末端,不靠时间戳排序。
-- 【读】module.processing.view 或 module.inbound.view 或 module.logistics.view(Q22:地磅单页上要看得见两磅)。进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.weighings (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbox_id          bigint NOT NULL UNIQUE REFERENCES public.ingest_inbox (id),
    draft_id          uuid NOT NULL UNIQUE REFERENCES public.capture_drafts (id),
    device_id         uuid REFERENCES public.devices (id),
    source            text NOT NULL CHECK (source IN ('device', 'manual')),
    weight_kg         numeric NOT NULL CHECK (weight_kg > 0),
    role              text NOT NULL CHECK (role IN ('gross', 'tare', 'net')),
    ticket_id         uuid REFERENCES public.weighbridge_tickets (id),
    site_from         timestamptz,
    site_to           timestamptz,
    site_dataset_ref  text,
    captured_at       timestamptz NOT NULL,
    confirmed_at      timestamptz NOT NULL DEFAULT now(),
    confirmed_by      uuid NOT NULL,
    corrects_id       uuid UNIQUE REFERENCES public.weighings (id),
    correction_reason text,
    CONSTRAINT weighings_subject_shape
        CHECK ((ticket_id IS NULL AND role = 'net') OR (ticket_id IS NOT NULL AND role IN ('gross', 'tare'))),
    CONSTRAINT weighings_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> '')),
    CONSTRAINT weighings_site_range
        CHECK (site_from IS NULL OR site_to IS NULL OR site_from <= site_to)
);

COMMENT ON TABLE public.weighings IS
    'MES-2:称重的正式记录(一张确认了的草稿)。weight_kg;device_id 为空 = 没有记录仪器;挂在地磅单上的是毛重 / 皮重,不挂的是净重。现场指针 site_*;captured_at 是读数时刻(校准判据看它)。只追加:更正是新行(corrects_id + 必填理由),读最新的。读:加工 / 收货 / 物流的查看码任一。';

CREATE INDEX weighings_ticket ON public.weighings (ticket_id);
CREATE INDEX weighings_device ON public.weighings (device_id);

CREATE TRIGGER trg_weighings_append_only
    BEFORE UPDATE ON public.weighings
    FOR EACH ROW EXECUTE FUNCTION public.guard_capture_append_only();
CREATE TRIGGER trg_weighings_no_delete
    BEFORE DELETE OR TRUNCATE ON public.weighings
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_capture_append_only();

ALTER TABLE public.weighings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "weighings select by permission" ON public.weighings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((has_permission('module.processing.view'::text) OR has_permission('module.inbound.view'::text)
            OR has_permission('module.logistics.view'::text)));

REVOKE ALL ON public.weighings FROM anon;

-- db/tables/weighbridge_ticket_shares.sql
-- MES-2(2026-10-06,MES-0 Q19 · Q21;MES-2 Step 0 Q18 · Q19 · Q20,Tim):【一张地磅单分给谁、各多少公斤】。
--   一行指向【恰好一个】去处:一张收货单(inbound_batch_id)或一条发货行(shipment_line_id)—— payment_allocations 的 XOR 形状;
--   kg 明写。只能从一张【完成了的】单分(TICKET_NOT_COMPLETE);方向要对:进厂单分给收货单、出厂单分给发货行
--   (TICKET_DIRECTION_MISMATCH)。各份之和【对着】净重显示,差多少就说多少 —— 从不强迫相等(MES-0 Q19)。
-- 【收货单】(Q19)份是在建收货单【的那一刻】给的:数量默认 = 这一份;人填了别的数,要写理由(receipt_quantity_reason)——
--   "收货单两个都留着" = 份的公斤数在这里、收货的数量在收货单上。收货单的数量建好之后不能改(QUANTITY_IMMUTABLE),
--   所以从地磅单页上把一张【已经存在】的收货单挂上来,它的数量一个字都不动,差多少照直显示。
-- 【发货行】(Q20)由持 action.ship_goods 的人从地磅单页上分;发货、开票、过账一样都不动 —— 不挪钱。
-- 【只追加】(guard_capture_append_only):分错的一份不撤 —— 它就是那一刻说过的话;差额在单上看得见。
-- 【读】module.inbound.view 或 module.logistics.view。进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.weighbridge_ticket_shares (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ticket_id               uuid NOT NULL REFERENCES public.weighbridge_tickets (id),
    inbound_batch_id        uuid REFERENCES public.inbound_batches (id),
    shipment_line_id        uuid REFERENCES public.shipment_lines (id),
    kg                      numeric NOT NULL CHECK (kg > 0),
    receipt_quantity_reason text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid DEFAULT auth.uid(),
    CONSTRAINT weighbridge_ticket_shares_one_target CHECK (num_nonnulls(inbound_batch_id, shipment_line_id) = 1),
    CONSTRAINT weighbridge_ticket_shares_reason_shape
        CHECK (receipt_quantity_reason IS NULL OR (inbound_batch_id IS NOT NULL AND btrim(receipt_quantity_reason) <> '')),
    CONSTRAINT weighbridge_ticket_shares_receipt_once UNIQUE (ticket_id, inbound_batch_id),
    CONSTRAINT weighbridge_ticket_shares_line_once UNIQUE (ticket_id, shipment_line_id)
);

COMMENT ON TABLE public.weighbridge_ticket_shares IS
    'MES-2:一张地磅单分给一张收货单或一条发货行的公斤数(恰好一个去处)。只从完成了的单分,方向要对;各份之和对着净重显示,不强迫相等。收货单的份在建单那一刻给,数量与份不同要写理由(receipt_quantity_reason)。发货行的份不挪钱。只追加。';

CREATE INDEX weighbridge_ticket_shares_batch ON public.weighbridge_ticket_shares (inbound_batch_id);
CREATE INDEX weighbridge_ticket_shares_line ON public.weighbridge_ticket_shares (shipment_line_id);

CREATE TRIGGER trg_weighbridge_ticket_shares_append_only
    BEFORE UPDATE ON public.weighbridge_ticket_shares
    FOR EACH ROW EXECUTE FUNCTION public.guard_capture_append_only();
CREATE TRIGGER trg_weighbridge_ticket_shares_no_delete
    BEFORE DELETE OR TRUNCATE ON public.weighbridge_ticket_shares
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_capture_append_only();

ALTER TABLE public.weighbridge_ticket_shares ENABLE ROW LEVEL SECURITY;

CREATE POLICY "weighbridge_ticket_shares select by permission" ON public.weighbridge_ticket_shares
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((has_permission('module.inbound.view'::text) OR has_permission('module.logistics.view'::text)));

REVOKE ALL ON public.weighbridge_ticket_shares FROM anon;

-- db/tables/weighbridge_ticket_photos.sql
-- MES-2(2026-10-06,MES-0 Q20;MES-2 Step 0 Q21,Tim):【地磅单的照片】—— 文件在私有桶 capture-photos 里,这里是它的登记行。
--   桶的读策略:module.inbound.view 或 module.logistics.view(本仓库第一个按权限码读的桶);传:action.confirm_capture;
--   桶里不能改、不能删。路径 = <地磅单 id>/<随机 id>-<文件名>;类型只收 jpeg / png / webp,大小 ≤ 10 MB(桶自己也卡)。
--   一张拍错的照片【撤下】(withdrawn_*,理由必填),行与对象都留着(守卫)。读:module.inbound.view 或 module.logistics.view。
--   桶与它的策略【不在镜像里】(AGENTS.md),它们的证明是 db/scripts/2026-10-06-mes2-capture-photos-policy-proof.sql。进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.weighbridge_ticket_photos (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ticket_id       uuid NOT NULL REFERENCES public.weighbridge_tickets (id),
    file_path       text NOT NULL UNIQUE,
    file_name       text NOT NULL CHECK (btrim(file_name) <> ''),
    mime_type       text NOT NULL CHECK (mime_type IN ('image/jpeg', 'image/png', 'image/webp')),
    size_bytes      integer NOT NULL CHECK (size_bytes > 0 AND size_bytes <= 10485760),
    uploaded_at     timestamptz NOT NULL DEFAULT now(),
    uploaded_by     uuid DEFAULT auth.uid(),
    withdrawn_at    timestamptz,
    withdrawn_by    uuid,
    withdraw_reason text,
    CONSTRAINT weighbridge_ticket_photos_path_shape CHECK (file_path LIKE ticket_id::text || '/%'),
    CONSTRAINT weighbridge_ticket_photos_withdrawn_shape
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)
               AND (withdrawn_at IS NULL OR btrim(COALESCE(withdraw_reason, '')) <> ''))
);

COMMENT ON TABLE public.weighbridge_ticket_photos IS
    'MES-2:地磅单照片的登记行;文件在私有桶 capture-photos(读:收货或物流查看码;传:action.confirm_capture;不能改、不能删)。jpeg / png / webp,≤ 10 MB。拍错的撤下(理由必填),行与对象都留着。';

CREATE INDEX weighbridge_ticket_photos_ticket ON public.weighbridge_ticket_photos (ticket_id);

CREATE TRIGGER trg_weighbridge_ticket_photos_write
    BEFORE UPDATE ON public.weighbridge_ticket_photos
    FOR EACH ROW EXECUTE FUNCTION public.guard_ticket_photos_write();
CREATE TRIGGER trg_weighbridge_ticket_photos_no_delete
    BEFORE DELETE OR TRUNCATE ON public.weighbridge_ticket_photos
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_ticket_photos_write();

ALTER TABLE public.weighbridge_ticket_photos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "weighbridge_ticket_photos select by permission" ON public.weighbridge_ticket_photos
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((has_permission('module.inbound.view'::text) OR has_permission('module.logistics.view'::text)));

REVOKE ALL ON public.weighbridge_ticket_photos FROM anon;

-- db/tables/instrument_calibrations.sql
-- MES-2(2026-10-06,规格 §8.2;MES-0 Q30 · Q31;MES-2 Step 0 Q23–Q25,Tim):【校准记录】—— "calibration records held in the system"。
--
-- 【一次校准 = 一行】哪一台仪器(秤、地磅、电表、在线仪表 —— Q23)、哪一天校的、证书自己写的有效期(必填,MES-0 Q31)、
--   通过还是没通过、证书号、校准机构。由持 action.manage_devices 的人记(Q24)。
-- 【在不在校准期内 —— 读的时候推】(Q25)对一个时刻 T(读数的那一天,新加坡日历):取这台仪器【没作废、calibrated_on ≤ T】
--   的最近一行(按 calibrated_on,再按 id —— id 是 identity,同一天记两次也排得出先后);通过且 T ≤ valid_until = 在期内;
--   通过而 T 已过期 = expired;没通过 = failed;一行都没有 = never_calibrated —— 也算不在期内。补录的证书对它覆盖的那段时间算数
--   (这一行本身进变更记录:谁、何时录的)。判据只有一份:calibration_status_from(结论, 有效期, T)。
-- 【只追加】记错了的作废(带理由),不改;不删(守卫)。【读】module.processing.view。进变更记录(设备那个审计主语的成员)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.instrument_calibrations (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    device_id        uuid NOT NULL REFERENCES public.devices (id),
    calibrated_on    date NOT NULL,
    valid_until      date NOT NULL,
    result           text NOT NULL CHECK (result IN ('passed', 'failed')),
    certificate_no   text,
    calibrating_body text,
    notes            text,
    recorded_at      timestamptz NOT NULL DEFAULT now(),
    recorded_by      uuid DEFAULT auth.uid(),
    voided_at        timestamptz,
    voided_by        uuid,
    void_reason      text,
    CONSTRAINT instrument_calibrations_valid_after CHECK (valid_until >= calibrated_on),
    CONSTRAINT instrument_calibrations_voided_shape
        CHECK ((voided_at IS NULL) = (voided_by IS NULL)
               AND (voided_at IS NULL OR btrim(COALESCE(void_reason, '')) <> ''))
);

COMMENT ON TABLE public.instrument_calibrations IS
    'MES-2:校准记录(规格 §8.2)。仪器、校准日、证书有效期(必填)、通过 / 没通过、证书号、机构。某一刻在不在期内是读的时候推的:没作废、calibrated_on ≤ 那一天的最近一行,通过且没过期 = 在期内;一行都没有 = 不在期内。只追加:记错的作废(理由必填)。读:module.processing.view;写:action.manage_devices。';

CREATE INDEX instrument_calibrations_device ON public.instrument_calibrations (device_id, calibrated_on);

CREATE TRIGGER trg_instrument_calibrations_write
    BEFORE UPDATE ON public.instrument_calibrations
    FOR EACH ROW EXECUTE FUNCTION public.guard_instrument_calibrations_write();
CREATE TRIGGER trg_instrument_calibrations_no_delete
    BEFORE DELETE OR TRUNCATE ON public.instrument_calibrations
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_instrument_calibrations_write();

ALTER TABLE public.instrument_calibrations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "instrument_calibrations select by permission" ON public.instrument_calibrations
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.instrument_calibrations FROM anon;

-- ── 5 · 单据种类 WB(镜像原样)──────────────────────────────────────────────────
INSERT INTO public.document_types
    (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission)
VALUES
    ('weighbridge_ticket', 'WB', 'weighbridge_tickets', 'gapped', 'weighbridge_ticket_code_seq', '/operation/weighbridge', 'detail', 'vehicle_reg', ARRAY['vehicle_reg', 'notes']::text[], ARRAY['module.inbound.view','module.logistics.view']::text[]);

-- ── 6 · 新函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/transform_weighing_v1.sql
-- MES-2(2026-10-06,规格 §6.4;MES-0 §3.5;MES-2 Step 0 Q7,Tim):称重这一类的【转换器】—— 第一支落得出业务记录的转换器。
--   payload 只能是 {"weight_kg": <数 > 0>},别的什么都没有(Q7):单位在网关那头换算成公斤;毛重 / 皮重 / 净重与挂哪一张地磅单
--   是工位上的人在确认时选的,不是秤说的。对象以外、多一个键 → WEIGHING_PAYLOAD_INVALID;weight_kg 不是数或不 > 0 →
--   WEIGHING_WEIGHT_INVALID。返回 {"weight_kg": <数>}。
--   IMMUTABLE、只吃 payload(MES-1 的决定 7):它读不到任何表、写不了任何表。确认时改过的值也经它再验一次(同一支验证器,两个调用方)。
--   【内层】EXECUTE 从 authenticated 收回;分派器与确认那几支以属主身份按名字调它。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.transform_weighing_v1(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_kg numeric;
BEGIN
    IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k <> 'weight_kg') THEN
        RAISE EXCEPTION 'WEIGHING_PAYLOAD_INVALID';
    END IF;
    IF jsonb_typeof(p_payload -> 'weight_kg') IS DISTINCT FROM 'number' THEN
        RAISE EXCEPTION 'WEIGHING_WEIGHT_INVALID';
    END IF;
    v_kg := (p_payload ->> 'weight_kg')::numeric;
    IF v_kg <= 0 THEN
        RAISE EXCEPTION 'WEIGHING_WEIGHT_INVALID';
    END IF;
    RETURN jsonb_build_object('weight_kg', v_kg);
END;
$function$;

-- db/functions/calibration_status_from.sql
-- MES-2(2026-10-06,MES-0 Q30 · Q31;MES-2 Step 0 Q25,Tim):【在不在校准期内】的那一句判据 —— 唯一一份。
--   入参是【已经挑出来的那一行校准记录】(没作废、calibrated_on ≤ 那一天的最近一行)的结论与有效期,以及那一天:
--     没有记录(p_result 为空)→ never_calibrated(也算不在期内,Q25)
--     没通过                  → failed
--     通过、那一天 ≤ 有效期    → in_calibration
--     通过、那一天已过有效期   → expired
--   纯函数(IMMUTABLE,不读任何表),所以在属主视图里调它不会撞上读者的 RLS:挑那一行的是视图自己(属主身份),
--   这里只做判断。读它的:weighing_calibration_all(每一次称重在它那一刻)· instrument_calibration_now(每一台仪器在今天)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.calibration_status_from(p_result text, p_valid_until date, p_on date)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
               WHEN p_result IS NULL THEN 'never_calibrated'
               WHEN p_result = 'failed' THEN 'failed'
               WHEN p_on <= p_valid_until THEN 'in_calibration'
               ELSE 'expired'
           END;
$function$;

-- db/functions/capture_confirm_internal.sql
-- MES-2(2026-10-06,规格 §6.3;MES-0 §3.6 · Q12;MES-2 Step 0 Q9 · Q11 · Q12 · Q16,Tim):【确认一张草稿 —— 内层】。
--   三个调用方各自查码、以属主身份调它:confirm_capture_draft(工位上确认网关送来的)· submit_manual_capture(手工录入,
--   同一步里由录入人确认)· correct_weighing(更正,新一行指回原行)。
--   ① 改值(p_overrides):只认【量出来的值】(weighing:weight_kg);设备、网关、流、序号、来源、现场时间、数据类 →
--      CAPTURE_FIELD_FIXED|<字段>(MES-0 Q12);别的键 → CAPTURE_FIELD_UNKNOWN|<字段>。合并之后【交给同一支转换器再验一次】
--      (一份验证器,两个调用方);确认值与 proposed 不同的每一格要有理由(CAPTURE_CHANGE_REASON_REQUIRED|<字段>),
--      并落一行 capture_draft_changes(原值 · 确认值 · 理由)。
--   ② 量程(Q12):这台仪器登记了量程,读数超过它 → WEIGHING_ABOVE_CAPACITY|<编号>|<量程 kg>。量程按设备登记的单位读
--      (kg · t · g;空 = kg);别的单位比不了,不判。没有登记量程 → 不判(V33 把它列在「待补的标准值」上)。
--   ③ 主语(p_subject,Q16):{} = 一次单独的净重;{"new_ticket": {"direction", "vehicle_reg", "notes"}} = 用这一磅开一张地磅单
--      (进厂第一磅是毛重,出厂第一磅是皮重);{"ticket_id"} = 这一磅完成那张开着的单(另一种角色)。更正时主语照抄原行。
--      主语不是"改":网关的 proposed 里没有它(Q7),所以选它不落 capture_draft_changes。
--   ④ 落 weighings(captured_at = 现场时间,没有就是确认时刻;更正照抄原行的 —— 它更正的是那一次读数),草稿标 confirmed。
--   ⑤ 一张单两磅都在 → 净重 = 毛重 − 皮重,≤ 0 按名拒(TICKET_NET_NOT_POSITIVE|<编号>|<毛>|<皮>);第一次凑齐时记 completed_at。
--   【内层】不是 SECURITY DEFINER、没有调用者检查,EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.capture_confirm_internal(p_draft_id uuid, p_overrides jsonb, p_reasons jsonb, p_subject jsonb, p_corrects uuid, p_correction_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    c_fixed    constant text[] := ARRAY['device', 'device_id', 'gateway', 'gateway_id', 'stream', 'seq', 'source', 'site_from',
                                        'site_to', 'site_dataset_ref', 'data_class', 'class'];
    c_measured constant text[] := ARRAY['weight_kg'];
    d          capture_drafts%ROWTYPE;
    b          ingest_inbox%ROWTYPE;
    v_orig     weighings%ROWTYPE;
    v_dev      devices%ROWTYPE;
    v_tk       weighbridge_tickets%ROWTYPE;
    v_ov       jsonb := COALESCE(p_overrides, '{}'::jsonb);
    v_sub      jsonb := COALESCE(p_subject, '{}'::jsonb);
    v_fn       text;
    v_out      jsonb;
    k          text;
    v_cap      numeric;
    v_role     text := 'net';
    v_ticket   uuid;
    v_dir      text;
    v_captured timestamptz;
    v_w        uuid;
    v_gross    numeric;
    v_tare     numeric;
BEGIN
    SELECT * INTO d FROM capture_drafts WHERE id = p_draft_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CAPTURE_DRAFT_NOT_FOUND|%', COALESCE(p_draft_id::text, '?');
    END IF;
    IF d.status <> 'pending' THEN
        RAISE EXCEPTION 'CAPTURE_DRAFT_DECIDED|%', d.status;
    END IF;
    IF d.data_class <> 'weighing' THEN
        RAISE EXCEPTION 'CAPTURE_CLASS_HAS_NO_RECORD|%', d.data_class;
    END IF;
    SELECT * INTO b FROM ingest_inbox WHERE id = d.inbox_id;

    -- ① 改值:只认量出来的值;合并之后同一支转换器再验
    IF jsonb_typeof(v_ov) <> 'object' THEN
        RAISE EXCEPTION 'CAPTURE_FIELD_UNKNOWN|overrides';
    END IF;
    FOR k IN SELECT jsonb_object_keys(v_ov) LOOP
        IF k = ANY (c_fixed) THEN
            RAISE EXCEPTION 'CAPTURE_FIELD_FIXED|%', k;
        END IF;
        IF NOT k = ANY (c_measured) THEN
            RAISE EXCEPTION 'CAPTURE_FIELD_UNKNOWN|%', k;
        END IF;
    END LOOP;
    SELECT c.transform_function INTO v_fn FROM ingest_data_classes c WHERE c.code = d.data_class;
    EXECUTE format('SELECT public.%I($1)', v_fn) INTO v_out USING (d.proposed || v_ov);
    FOR k IN SELECT jsonb_object_keys(v_ov) LOOP
        IF (v_out -> k) IS DISTINCT FROM (d.proposed -> k)
           AND btrim(COALESCE(p_reasons ->> k, '')) = '' THEN
            RAISE EXCEPTION 'CAPTURE_CHANGE_REASON_REQUIRED|%', k;
        END IF;
    END LOOP;

    -- ② 量程
    IF d.device_id IS NOT NULL THEN
        SELECT * INTO v_dev FROM devices WHERE id = d.device_id;
        IF v_dev.capacity IS NOT NULL THEN
            v_cap := v_dev.capacity * CASE lower(btrim(COALESCE(v_dev.unit, 'kg')))
                                          WHEN 'kg' THEN 1 WHEN 't' THEN 1000 WHEN 'g' THEN 0.001 END;
            IF v_cap IS NOT NULL AND (v_out ->> 'weight_kg')::numeric > v_cap THEN
                RAISE EXCEPTION 'WEIGHING_ABOVE_CAPACITY|%|%', v_dev.code, v_cap;
            END IF;
        END IF;
    END IF;

    -- ③ 主语
    IF p_corrects IS NOT NULL THEN
        SELECT * INTO v_orig FROM weighings WHERE id = p_corrects;
        v_ticket := v_orig.ticket_id;
        v_role := v_orig.role;
        v_captured := v_orig.captured_at;
    ELSIF v_sub ? 'new_ticket' THEN
        v_dir := v_sub -> 'new_ticket' ->> 'direction';
        IF v_dir IS NULL OR v_dir NOT IN ('inbound', 'outbound') THEN
            RAISE EXCEPTION 'TICKET_DIRECTION_INVALID|%', COALESCE(v_dir, '?');
        END IF;
        IF btrim(COALESCE(v_sub -> 'new_ticket' ->> 'vehicle_reg', '')) = '' THEN
            RAISE EXCEPTION 'TICKET_VEHICLE_REQUIRED';
        END IF;
        INSERT INTO weighbridge_tickets (direction, vehicle_reg, notes, created_by, updated_by)
        VALUES (v_dir, upper(btrim(v_sub -> 'new_ticket' ->> 'vehicle_reg')),
                NULLIF(btrim(COALESCE(v_sub -> 'new_ticket' ->> 'notes', '')), ''), auth.uid(), auth.uid())
        RETURNING id INTO v_ticket;
        v_role := CASE v_dir WHEN 'inbound' THEN 'gross' ELSE 'tare' END;
    ELSIF v_sub ? 'ticket_id' THEN
        SELECT * INTO v_tk FROM weighbridge_tickets WHERE id = (v_sub ->> 'ticket_id')::uuid FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'TICKET_NOT_FOUND|%', v_sub ->> 'ticket_id';
        END IF;
        IF v_tk.voided_at IS NOT NULL THEN
            RAISE EXCEPTION 'TICKET_VOIDED|%', v_tk.code;
        END IF;
        IF v_tk.completed_at IS NOT NULL THEN
            RAISE EXCEPTION 'TICKET_ALREADY_COMPLETE|%', v_tk.code;
        END IF;
        v_ticket := v_tk.id;
        v_role := CASE v_tk.direction WHEN 'inbound' THEN 'tare' ELSE 'gross' END;
    ELSIF v_sub <> '{}'::jsonb THEN
        RAISE EXCEPTION 'CAPTURE_SUBJECT_UNKNOWN';
    END IF;

    -- ④ 正式记录;改过的值;草稿标 confirmed
    INSERT INTO weighings (inbox_id, draft_id, device_id, source, weight_kg, role, ticket_id, site_from, site_to, site_dataset_ref,
                           captured_at, confirmed_by, corrects_id, correction_reason)
    VALUES (b.id, d.id, d.device_id, d.source, (v_out ->> 'weight_kg')::numeric, v_role, v_ticket, b.site_from, b.site_to,
            b.site_dataset_ref, COALESCE(v_captured, b.site_to, b.site_from, now()), auth.uid(), p_corrects,
            NULLIF(btrim(COALESCE(p_correction_reason, '')), ''))
    RETURNING id INTO v_w;
    FOR k IN SELECT jsonb_object_keys(v_ov) LOOP
        IF (v_out -> k) IS DISTINCT FROM (d.proposed -> k) THEN
            INSERT INTO capture_draft_changes (draft_id, field, original_value, confirmed_value, reason)
            VALUES (d.id, k, d.proposed -> k, v_out -> k, btrim(p_reasons ->> k));
        END IF;
    END LOOP;
    UPDATE capture_drafts SET status = 'confirmed', confirmed_at = now(), confirmed_by = auth.uid() WHERE id = d.id;

    -- ⑤ 两磅凑齐:净重 > 0;第一次凑齐时记 completed_at
    IF v_ticket IS NOT NULL THEN
        SELECT max(w.weight_kg) FILTER (WHERE w.role = 'gross'), max(w.weight_kg) FILTER (WHERE w.role = 'tare')
          INTO v_gross, v_tare
          FROM weighings w
         WHERE w.ticket_id = v_ticket AND NOT EXISTS (SELECT 1 FROM weighings x WHERE x.corrects_id = w.id);
        IF v_gross IS NOT NULL AND v_tare IS NOT NULL THEN
            IF v_gross - v_tare <= 0 THEN
                RAISE EXCEPTION 'TICKET_NET_NOT_POSITIVE|%|%|%', (SELECT t.code FROM weighbridge_tickets t WHERE t.id = v_ticket),
                    v_gross, v_tare;
            END IF;
            UPDATE weighbridge_tickets SET completed_at = now(), updated_by = auth.uid()
             WHERE id = v_ticket AND completed_at IS NULL;
        END IF;
    END IF;
    RETURN v_w;
END;
$function$;

-- db/functions/confirm_capture_draft.sql
-- MES-2(2026-10-06,规格 §6.3;MES-0 Q11 · Q12;MES-2 Step 0 Q8 · Q9,Tim):工位上【确认】一张网关送来的草稿 —— 它从此是正式记录。
--   持 action.confirm_capture(warehouse · cto · admin;任何一个持有人确认任何一个工位的草稿,工位照显示,MES-0 Q11)。
--   p_overrides {"weight_kg": …} 改量出来的值,p_reasons {"weight_kg": "…"} 写改的理由(改了就必填);p_subject 选主语
--   ({} 净重 · {"new_ticket": …} 开一张地磅单 · {"ticket_id": …} 完成一张)。全部规则在 capture_confirm_internal。
--   返回那一次称重的 id。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.confirm_capture_draft(p_draft_id uuid, p_overrides jsonb DEFAULT '{}'::jsonb, p_reasons jsonb DEFAULT '{}'::jsonb, p_subject jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.confirm_capture');
    RETURN capture_confirm_internal(p_draft_id, p_overrides, p_reasons, p_subject, NULL, NULL);
END;
$function$;

-- db/functions/reject_capture_draft.sql
-- MES-2(2026-10-06,MES-0 Q13;MES-2 Step 0 Q10,Tim):【驳回】一张草稿 —— 理由必填,终局。
--   持 action.confirm_capture。驳回之后不落任何正式记录;收件箱那一行照旧是 transformed(它的守卫冻着它)。
--   一次被驳错的读数,由人手工再录一次(那一次照样记成 manual)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.reject_capture_draft(p_draft_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_status text;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'CAPTURE_REJECT_REASON_REQUIRED';
    END IF;
    SELECT status INTO v_status FROM capture_drafts WHERE id = p_draft_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CAPTURE_DRAFT_NOT_FOUND|%', COALESCE(p_draft_id::text, '?');
    END IF;
    IF v_status <> 'pending' THEN
        RAISE EXCEPTION 'CAPTURE_DRAFT_DECIDED|%', v_status;
    END IF;
    UPDATE capture_drafts SET status = 'rejected', rejected_at = now(), rejected_by = auth.uid(), reject_reason = btrim(p_reason)
     WHERE id = p_draft_id;
END;
$function$;

-- db/functions/submit_manual_capture.sql
-- MES-2(2026-10-06,规格 §6.3 · §10;MES-0 Q10;MES-1 Q14;MES-2 Step 0 Q13–Q15,Tim):【手工录入】—— 走网关那一条路,一步确认。
--   ① 这一类要允许手工录入(manual_entry_code 不为空、creates_draft 为真),否则 CAPTURE_NO_MANUAL_ENTRY|<类>;
--      持它的 manual_entry_code(称重:action.confirm_capture,Q15)。
--   ② 仪器可选(Q14):给了,就要是一台没停用的秤 / 地磅 / 电表 / 在线仪表(CAPTURE_DEVICE_INVALID);没给,这次称重标
--      "instrument not recorded",照收。
--   ③ 收件箱落一行(source = manual,录入人 = 本人)→ 【同一个分派器、同一支转换器】→ 草稿 → 同一步里由录入人确认
--      (confirmed_by = entered_by,不落改值行)。
--   ④ 转换没过(Q13):按转换器那一句码拒,【整笔回滚 —— 什么都不留】。收件箱里失败的行是给没人看着的机器的;
--      站在这里的人当场就能改。
--   返回 {inbox_id, draft_id, weighing_id}。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.submit_manual_capture(p_data_class text, p_payload jsonb, p_device_id uuid DEFAULT NULL::uuid, p_site_from timestamptz DEFAULT NULL::timestamptz, p_site_to timestamptz DEFAULT NULL::timestamptz, p_subject jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_class ingest_data_classes%ROWTYPE;
    v_inbox bigint;
    v_state text;
    v_err   text;
    v_draft uuid;
    v_w     uuid;
BEGIN
    SELECT * INTO v_class FROM ingest_data_classes WHERE code = p_data_class;
    IF NOT FOUND OR NOT v_class.is_active THEN
        RAISE EXCEPTION 'CAPTURE_CLASS_UNKNOWN|%', COALESCE(p_data_class, '?');
    END IF;
    IF v_class.manual_entry_code IS NULL OR NOT v_class.creates_draft THEN
        RAISE EXCEPTION 'CAPTURE_NO_MANUAL_ENTRY|%', p_data_class;
    END IF;
    PERFORM require_permission(v_class.manual_entry_code);
    IF p_device_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM devices d WHERE d.id = p_device_id AND d.retired_at IS NULL
               AND d.kind IN ('scale', 'weighbridge', 'meter', 'inline_instrument')) THEN
        RAISE EXCEPTION 'CAPTURE_DEVICE_INVALID|%', p_device_id;
    END IF;
    IF p_payload IS NULL THEN
        RAISE EXCEPTION 'CAPTURE_PAYLOAD_REQUIRED';
    END IF;
    IF p_site_from IS NOT NULL AND p_site_to IS NOT NULL AND p_site_from > p_site_to THEN
        RAISE EXCEPTION 'CAPTURE_SITE_RANGE_INVALID';
    END IF;

    INSERT INTO ingest_inbox (source, entered_by, device_id, data_class, payload, payload_bytes, payload_sha256, site_from, site_to)
    VALUES ('manual', auth.uid(), p_device_id, p_data_class, p_payload, octet_length(p_payload::text),
            sha256(convert_to(p_payload::text, 'UTF8')), p_site_from, p_site_to)
    RETURNING id INTO v_inbox;

    v_state := ingest_transform_row(v_inbox);
    IF v_state <> 'transformed' THEN
        SELECT error_code INTO v_err FROM ingest_inbox WHERE id = v_inbox;
        RAISE EXCEPTION '%', COALESCE(v_err, 'CAPTURE_NOT_TRANSFORMED|' || v_state);
    END IF;
    SELECT id INTO v_draft FROM capture_drafts WHERE inbox_id = v_inbox;
    v_w := capture_confirm_internal(v_draft, '{}'::jsonb, '{}'::jsonb, p_subject, NULL, NULL);
    RETURN jsonb_build_object('inbox_id', v_inbox, 'draft_id', v_draft, 'weighing_id', v_w);
END;
$function$;

-- db/functions/correct_weighing.sql
-- MES-2(2026-10-06,规格 §4.2;MES-0 §3.7;MES-2 Step 0 Q11,Tim):【更正一次已确认的称重】—— 不改原行,落一条新的。
--   持 action.confirm_capture;理由必填(WEIGHING_CORRECTION_REASON_REQUIRED);一行只更正一次(WEIGHING_SUPERSEDED|<id>:
--   要再改,改最新的那一行);值没变按名拒(WEIGHING_CORRECTION_SAME_VALUE)。
--   新的那一次走手工录入的同一条路(收件箱 manual → 同一支转换器 → 草稿 → 一步确认),仪器、现场时间、主语(地磅单与角色)
--   都照抄原行 —— 它更正的是【那一次读数】,不是一次新的过磅。新行 corrects_id 指回原行;地磅单从此读最新的,
--   两磅凑齐时净重照样要 > 0(TICKET_NET_NOT_POSITIVE)。已经分出去的份与收货单的数量一个字都不动(收货单数量不可改),
--   差多少在单上照直显示。返回新那一行的 id。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.correct_weighing(p_weighing_id uuid, p_weight_kg numeric, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig    weighings%ROWTYPE;
    v_payload jsonb;
    v_inbox   bigint;
    v_state   text;
    v_err     text;
    v_draft   uuid;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WEIGHING_CORRECTION_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_orig FROM weighings WHERE id = p_weighing_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WEIGHING_NOT_FOUND|%', COALESCE(p_weighing_id::text, '?');
    END IF;
    IF EXISTS (SELECT 1 FROM weighings x WHERE x.corrects_id = v_orig.id) THEN
        RAISE EXCEPTION 'WEIGHING_SUPERSEDED|%', v_orig.id;
    END IF;
    IF v_orig.ticket_id IS NOT NULL AND EXISTS (SELECT 1 FROM weighbridge_tickets t WHERE t.id = v_orig.ticket_id AND t.voided_at IS NOT NULL) THEN
        RAISE EXCEPTION 'TICKET_VOIDED|%', (SELECT t.code FROM weighbridge_tickets t WHERE t.id = v_orig.ticket_id);
    END IF;
    IF p_weight_kg IS NOT DISTINCT FROM v_orig.weight_kg THEN
        RAISE EXCEPTION 'WEIGHING_CORRECTION_SAME_VALUE';
    END IF;
    v_payload := jsonb_build_object('weight_kg', p_weight_kg);

    INSERT INTO ingest_inbox (source, entered_by, device_id, data_class, payload, payload_bytes, payload_sha256, site_from, site_to,
                              site_dataset_ref)
    VALUES ('manual', auth.uid(), v_orig.device_id, 'weighing', v_payload, octet_length(v_payload::text),
            sha256(convert_to(v_payload::text, 'UTF8')), v_orig.site_from, v_orig.site_to, v_orig.site_dataset_ref)
    RETURNING id INTO v_inbox;
    v_state := ingest_transform_row(v_inbox);
    IF v_state <> 'transformed' THEN
        SELECT error_code INTO v_err FROM ingest_inbox WHERE id = v_inbox;
        RAISE EXCEPTION '%', COALESCE(v_err, 'CAPTURE_NOT_TRANSFORMED|' || v_state);
    END IF;
    SELECT id INTO v_draft FROM capture_drafts WHERE inbox_id = v_inbox;
    RETURN capture_confirm_internal(v_draft, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, v_orig.id, p_reason);
END;
$function$;

-- db/functions/weighbridge_share_internal.sql
-- MES-2(2026-10-06,MES-0 Q19 · Q21;MES-2 Step 0 Q18 · Q19 · Q20,Tim):【把一张地磅单分一份出去 —— 内层】。
--   调用方:create_inbound_batch · receive_inbound_batch_against_po(建收货单那一刻,带数量的理由)· share_weighbridge_ticket(从单上分)。
--   只从一张【完成了的】、没作废的单分(TICKET_NOT_COMPLETE · TICKET_VOIDED);kg > 0(TICKET_SHARE_KG_INVALID);
--   方向要对 —— 进厂单分给收货单、出厂单分给发货行(TICKET_DIRECTION_MISMATCH|<编号>|<该是的方向>);同一个去处只分一次
--   (TICKET_ALREADY_SHARED|<编号>)。各份之和【不】对着净重设上限:差多少在单上照直显示,从不强迫相等(MES-0 Q19)。
--   【内层】不是 SECURITY DEFINER、没有调用者检查,EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.weighbridge_share_internal(p_ticket_id uuid, p_inbound_batch_id uuid, p_shipment_line_id uuid, p_kg numeric, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tk weighbridge_tickets%ROWTYPE;
    v_id uuid;
BEGIN
    SELECT * INTO v_tk FROM weighbridge_tickets WHERE id = p_ticket_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TICKET_NOT_FOUND|%', COALESCE(p_ticket_id::text, '?');
    END IF;
    IF v_tk.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'TICKET_VOIDED|%', v_tk.code;
    END IF;
    IF v_tk.completed_at IS NULL THEN
        RAISE EXCEPTION 'TICKET_NOT_COMPLETE|%', v_tk.code;
    END IF;
    IF p_kg IS NULL OR p_kg <= 0 THEN
        RAISE EXCEPTION 'TICKET_SHARE_KG_INVALID';
    END IF;
    IF p_inbound_batch_id IS NOT NULL AND v_tk.direction <> 'inbound' THEN
        RAISE EXCEPTION 'TICKET_DIRECTION_MISMATCH|%|inbound', v_tk.code;
    END IF;
    IF p_shipment_line_id IS NOT NULL AND v_tk.direction <> 'outbound' THEN
        RAISE EXCEPTION 'TICKET_DIRECTION_MISMATCH|%|outbound', v_tk.code;
    END IF;
    IF EXISTS (SELECT 1 FROM weighbridge_ticket_shares s WHERE s.ticket_id = p_ticket_id
                  AND (s.inbound_batch_id = p_inbound_batch_id OR s.shipment_line_id = p_shipment_line_id)) THEN
        RAISE EXCEPTION 'TICKET_ALREADY_SHARED|%', v_tk.code;
    END IF;
    INSERT INTO weighbridge_ticket_shares (ticket_id, inbound_batch_id, shipment_line_id, kg, receipt_quantity_reason, created_by)
    VALUES (p_ticket_id, p_inbound_batch_id, p_shipment_line_id, p_kg, NULLIF(btrim(COALESCE(p_reason, '')), ''), auth.uid())
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/share_weighbridge_ticket.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q19 · Q20,Tim):【从地磅单页上分一份】—— 给一条发货行,或给一张【已经存在】的收货单。
--   恰好一个去处(TICKET_SHARE_TARGET_REQUIRED)。
--   · 发货行(Q20):持 action.ship_goods;发货、开票、过账一样都不动 —— 不挪钱。
--   · 已经存在的收货单(Q19):持 action.receive_goods;它的数量一个字都不动(建好之后本来就改不了),份与数量差多少照直显示。
--     建收货单【那一刻】给份(数量默认 = 份,改了要理由)走的是收货那两支函数,不是这里。
--   规则在 weighbridge_share_internal。返回那一份的 id。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.share_weighbridge_ticket(p_ticket_id uuid, p_kg numeric, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_shipment_line_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF num_nonnulls(p_inbound_batch_id, p_shipment_line_id) <> 1 THEN
        RAISE EXCEPTION 'TICKET_SHARE_TARGET_REQUIRED';
    END IF;
    IF p_inbound_batch_id IS NOT NULL THEN
        PERFORM require_permission('action.receive_goods');
        IF NOT EXISTS (SELECT 1 FROM inbound_batches b WHERE b.id = p_inbound_batch_id AND b.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
        END IF;
    ELSE
        PERFORM require_permission('action.ship_goods');
        IF NOT EXISTS (SELECT 1 FROM shipment_lines l WHERE l.id = p_shipment_line_id) THEN
            RAISE EXCEPTION 'SHIPMENT_LINE_NOT_FOUND|%', p_shipment_line_id;
        END IF;
    END IF;
    RETURN weighbridge_share_internal(p_ticket_id, p_inbound_batch_id, p_shipment_line_id, p_kg, NULL);
END;
$function$;

-- db/functions/void_weighbridge_ticket.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q16,Tim):【作废一张地磅单】—— 理由必填,而且只在它一份都没分出去的时候(TICKET_HAS_SHARES|<编号>)。
--   持 action.confirm_capture。作废之后冻住(守卫);它的称重留着(只追加),不再能完成、不再能分、不再能更正。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.void_weighbridge_ticket(p_ticket_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tk weighbridge_tickets%ROWTYPE;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'TICKET_VOID_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_tk FROM weighbridge_tickets WHERE id = p_ticket_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TICKET_NOT_FOUND|%', COALESCE(p_ticket_id::text, '?');
    END IF;
    IF v_tk.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'TICKET_VOIDED|%', v_tk.code;
    END IF;
    IF EXISTS (SELECT 1 FROM weighbridge_ticket_shares s WHERE s.ticket_id = p_ticket_id) THEN
        RAISE EXCEPTION 'TICKET_HAS_SHARES|%', v_tk.code;
    END IF;
    UPDATE weighbridge_tickets
       SET voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason), updated_by = auth.uid()
     WHERE id = p_ticket_id;
END;
$function$;

-- db/functions/record_ticket_photo.sql
-- MES-2(2026-10-06,MES-0 Q20;MES-2 Step 0 Q21,Tim):【登记一张地磅单照片】—— 文件已经由浏览器传进私有桶 capture-photos,
--   这里落它的登记行。持 action.confirm_capture(与桶的上传策略同一个码)。单要在、没作废(TICKET_NOT_FOUND · TICKET_VOIDED);
--   路径必须是 <单 id>/…(TICKET_PHOTO_PATH_INVALID);类型只收 jpeg / png / webp(TICKET_PHOTO_TYPE_INVALID);
--   ≤ 10 MB(TICKET_PHOTO_TOO_LARGE)。服务端动作在调它之前还会再核一次类型;桶本身只收这三种类型、≤ 10 MB,
--   而桶里的对象谁都删不了(没有 DELETE 策略)—— 所以一个被这里拒掉的对象会留在桶里、没有登记行(交回报告记着)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.record_ticket_photo(p_ticket_id uuid, p_file_path text, p_file_name text, p_mime_type text, p_size_bytes integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tk weighbridge_tickets%ROWTYPE;
    v_id uuid;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    SELECT * INTO v_tk FROM weighbridge_tickets WHERE id = p_ticket_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TICKET_NOT_FOUND|%', COALESCE(p_ticket_id::text, '?');
    END IF;
    IF v_tk.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'TICKET_VOIDED|%', v_tk.code;
    END IF;
    IF p_file_path IS NULL OR p_file_path NOT LIKE p_ticket_id::text || '/%' OR btrim(COALESCE(p_file_name, '')) = '' THEN
        RAISE EXCEPTION 'TICKET_PHOTO_PATH_INVALID';
    END IF;
    IF p_mime_type IS NULL OR p_mime_type NOT IN ('image/jpeg', 'image/png', 'image/webp') THEN
        RAISE EXCEPTION 'TICKET_PHOTO_TYPE_INVALID|%', COALESCE(p_mime_type, '?');
    END IF;
    IF p_size_bytes IS NULL OR p_size_bytes <= 0 OR p_size_bytes > 10485760 THEN
        RAISE EXCEPTION 'TICKET_PHOTO_TOO_LARGE|%', COALESCE(p_size_bytes::text, '?');
    END IF;
    INSERT INTO weighbridge_ticket_photos (ticket_id, file_path, file_name, mime_type, size_bytes, uploaded_by)
    VALUES (p_ticket_id, p_file_path, btrim(p_file_name), p_mime_type, p_size_bytes, auth.uid())
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/withdraw_ticket_photo.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q21,Tim):【撤下一张拍错的照片】—— 理由必填(TICKET_PHOTO_WITHDRAW_REASON_REQUIRED);
--   行与桶里的对象都留着(桶不许删,行的守卫不许删),只是页面上不再当成这张单的照片。持 action.confirm_capture。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.withdraw_ticket_photo(p_photo_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_withdrawn timestamptz;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'TICKET_PHOTO_WITHDRAW_REASON_REQUIRED';
    END IF;
    SELECT withdrawn_at INTO v_withdrawn FROM weighbridge_ticket_photos WHERE id = p_photo_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TICKET_PHOTO_NOT_FOUND|%', COALESCE(p_photo_id::text, '?');
    END IF;
    IF v_withdrawn IS NOT NULL THEN
        RAISE EXCEPTION 'TICKET_PHOTO_WITHDRAWN|%', p_photo_id;
    END IF;
    UPDATE weighbridge_ticket_photos SET withdrawn_at = now(), withdrawn_by = auth.uid(), withdraw_reason = btrim(p_reason)
     WHERE id = p_photo_id;
END;
$function$;

-- db/functions/record_instrument_calibration.sql
-- MES-2(2026-10-06,规格 §8.2;MES-0 Q31;MES-2 Step 0 Q23 · Q24,Tim):【记一次校准】。持 action.manage_devices(cto · admin)。
--   仪器要在、没停用(DEVICE_NOT_FOUND · DEVICE_RETIRED|<编号>),而且是一台量东西的仪器 —— 秤、地磅、电表、在线仪表
--   (CALIBRATION_KIND_INVALID|<种类>,Q23)。校准日与证书有效期都必填(CALIBRATION_DATE_REQUIRED);有效期不早于校准日
--   (CALIBRATION_VALID_UNTIL_BEFORE_CALIBRATED);校准日不在将来(CALIBRATION_IN_FUTURE —— 补录过去的证书可以,
--   它对它覆盖的那段时间算数,Q25);结论 passed / failed(CALIBRATION_RESULT_INVALID)。返回那一行的 id。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.record_instrument_calibration(p_device_id uuid, p_calibrated_on date, p_valid_until date, p_result text, p_certificate_no text DEFAULT NULL::text, p_calibrating_body text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_dev devices%ROWTYPE;
    v_id  bigint;
BEGIN
    PERFORM require_permission('action.manage_devices');
    SELECT * INTO v_dev FROM devices WHERE id = p_device_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DEVICE_NOT_FOUND';
    END IF;
    IF v_dev.retired_at IS NOT NULL THEN
        RAISE EXCEPTION 'DEVICE_RETIRED|%', v_dev.code;
    END IF;
    IF v_dev.kind NOT IN ('scale', 'weighbridge', 'meter', 'inline_instrument') THEN
        RAISE EXCEPTION 'CALIBRATION_KIND_INVALID|%', v_dev.kind;
    END IF;
    IF p_calibrated_on IS NULL OR p_valid_until IS NULL THEN
        RAISE EXCEPTION 'CALIBRATION_DATE_REQUIRED';
    END IF;
    IF p_valid_until < p_calibrated_on THEN
        RAISE EXCEPTION 'CALIBRATION_VALID_UNTIL_BEFORE_CALIBRATED';
    END IF;
    IF p_calibrated_on > CURRENT_DATE THEN
        RAISE EXCEPTION 'CALIBRATION_IN_FUTURE';
    END IF;
    IF p_result IS NULL OR p_result NOT IN ('passed', 'failed') THEN
        RAISE EXCEPTION 'CALIBRATION_RESULT_INVALID|%', COALESCE(p_result, '?');
    END IF;
    INSERT INTO instrument_calibrations (device_id, calibrated_on, valid_until, result, certificate_no, calibrating_body, notes, recorded_by)
    VALUES (p_device_id, p_calibrated_on, p_valid_until, p_result, NULLIF(btrim(COALESCE(p_certificate_no, '')), ''),
            NULLIF(btrim(COALESCE(p_calibrating_body, '')), ''), NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid())
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/void_instrument_calibration.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q24,Tim):【作废一条记错了的校准记录】—— 理由必填(CALIBRATION_VOID_REASON_REQUIRED);
--   只作废一次(CALIBRATION_VOIDED|<id>)。作废的那一行从此不参与"在不在期内"的判断。持 action.manage_devices。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.void_instrument_calibration(p_id bigint, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_voided timestamptz;
BEGIN
    PERFORM require_permission('action.manage_devices');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'CALIBRATION_VOID_REASON_REQUIRED';
    END IF;
    SELECT voided_at INTO v_voided FROM instrument_calibrations WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CALIBRATION_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_voided IS NOT NULL THEN
        RAISE EXCEPTION 'CALIBRATION_VOIDED|%', p_id;
    END IF;
    UPDATE instrument_calibrations SET voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason) WHERE id = p_id;
END;
$function$;

-- db/functions/assert_receipt_reading_calibrated.sql
-- MES-2(2026-10-06,规格 §8.2;MES-0 Q30;MES-2 Step 0 Q26 · Q27,Tim 的 MES-2 委托书):【校准闸】—— 一张收货单的读数可不可以拿去定价、拿去签证书。
--   调用方:reprice_inbound_batch(每一条收货定价路径都落进来的那一支引擎)· preview_reprice_inbound_batch(与它同一份算术的试算)·
--   issue_cod(销毁证书证的就是这张收货单的数量)。三处问的是同一支函数 —— 一份判据。
--   【开关】ingest_settings.require_calibrated_since:空 = 关 —— 什么都不拒(Tim 的 MES-2 委托书:"nothing refuses when it is NULL";
--     校准状态在页面上照样处处看得见)。开着时,只管【这一天及以后建的】收货单(新加坡日历),更早的照旧。
--   开着、而且管到这一张时,对它挂着的每一张地磅单的【最新】两磅(更正读最新的):
--     · 没有记录仪器        → READING_INSTRUMENT_NOT_RECORDED|<地磅单>|<角色>
--     · 仪器在读数那一天不在校准期内(过期 · 没通过 · 从来没校过)→ READING_INSTRUMENT_NOT_CALIBRATED|<仪器编号>|<读数日期>
--   一张地磅单都没挂 → RECEIPT_READING_NOT_RECORDED|<收货单>。
--   读数那一天的状态来自 weighing_calibration_all(那张基视图里的挑法 + calibration_status_from 那一句判据)。
--   【内层】不是 SECURITY DEFINER、没有调用者检查,EXECUTE 从 authenticated 收回;调用方都是 DEFINER,以属主身份读。STABLE:试算也调它。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.assert_receipt_reading_calibrated(p_inbound_batch_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_since   date;
    v_code    text;
    v_created timestamptz;
    v_n       integer := 0;
    r         record;
BEGIN
    SELECT s.require_calibrated_since INTO v_since FROM ingest_settings s WHERE s.id;
    IF v_since IS NULL THEN
        RETURN;
    END IF;
    SELECT b.code, b.created_at INTO v_code, v_created FROM inbound_batches b WHERE b.id = p_inbound_batch_id;
    IF NOT FOUND OR (v_created AT TIME ZONE 'Asia/Singapore')::date < v_since THEN
        RETURN;
    END IF;
    FOR r IN SELECT t.code AS ticket_code, wc.role, wc.device_code, wc.captured_on, wc.status
               FROM weighbridge_ticket_shares s
               JOIN weighbridge_tickets t ON t.id = s.ticket_id
               JOIN weighing_calibration_all wc ON wc.ticket_id = s.ticket_id AND wc.is_current
              WHERE s.inbound_batch_id = p_inbound_batch_id
              ORDER BY t.code, wc.role LOOP
        v_n := v_n + 1;
        IF r.status = 'not_recorded' THEN
            RAISE EXCEPTION 'READING_INSTRUMENT_NOT_RECORDED|%|%', r.ticket_code, r.role;
        ELSIF r.status <> 'in_calibration' THEN
            RAISE EXCEPTION 'READING_INSTRUMENT_NOT_CALIBRATED|%|%', r.device_code, to_char(r.captured_on, 'YYYY-MM-DD');
        END IF;
    END LOOP;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'RECEIPT_READING_NOT_RECORDED|%', v_code;
    END IF;
END;
$function$;

-- ── 7 · 改过的函数(镜像原样,同签名)────────────────────────────────────────────

-- db/functions/ingest_transform_row.sql
-- MES-1(2026-10-06,规格 §6.4;MES-0 §3.5;MES-1 Step 0 Q11 · Q12 · Q15,Tim):【分派器】—— 收件箱的一行交给它那一类的转换器。
--   读 ingest_data_classes.transform_function:为空 → awaiting_transform(这一类还没有转换器,行看得见、不丢);
--   不为空 → 调 public.<名>(jsonb)(名字的形状由表上的 CHECK 钉成 transform_<类>_v<版本>,函数不存在就记
--   TRANSFORM_FUNCTION_MISSING|<名>)。成功 → transformed(记下用的是哪一支、结果);转换器 RAISE → failed + error_code
--   (一句机器码原样留下;别的错误记 TRANSFORM_UNEXPECTED|<SQLSTATE>)。每一次都 attempts + 1 并记下是谁、何时。
--   一行转换器的错只回滚它自己(子事务),不碰同一批里的别的行。
--   【内层】不是 SECURITY DEFINER、没有调用者检查,EXECUTE 从 authenticated 收回 —— 只由 ingest_process_pending ·
--   retry_inbox_row · submit_manual_capture · correct_weighing 调(它们各自查码,以属主身份调它)。状态只在它设的事务级标记下改得动(守卫)。
-- MES-2(2026-10-06,MES-2 Step 0 Q4,Tim):【草稿由分派器落】—— 转换器是 IMMUTABLE、只吃 payload,落不了任何东西;
--   所以这一类若 creates_draft 为真(MES-2:weighing),分派器在把这一行标成 transformed 的同一次里落一张 capture_drafts
--   (proposed = 转换器的输出,原样;工位 = 设备登记的 station)。inbox_id 唯一 —— 一行收件箱最多一张草稿。
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
    v_draft boolean;
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
    SELECT c.transform_function, c.creates_draft INTO v_fn, v_draft FROM ingest_data_classes c WHERE c.code = r.data_class;

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
        -- MES-2:这一类要人确认 → 同一次里落草稿
        IF v_state = 'transformed' AND v_draft THEN
            INSERT INTO capture_drafts (inbox_id, data_class, source, device_id, station, proposed)
            VALUES (p_id, r.data_class, r.source, r.device_id,
                    (SELECT d.station FROM devices d WHERE d.id = r.device_id), v_out);
        END IF;
    END IF;
    PERFORM set_config('evoltrya.ingest_ctx', '', true);
    RETURN v_state;
END;
$function$;

-- db/functions/ingest_process_pending.sql
-- MES-1(2026-10-06,MES-1 Step 0 Q11,Tim):【"Process received"】—— 把收件箱里 status = received 的行按到达顺序交给分派器。
--   转换只在员工的会话里跑(Q11),所以这是收件箱上的一个按钮,持 module.processing.view 的人能按;
--   MES-2 的确认队列打开时会调它。它只改状态那几列(守卫),处理一遍是幂等的:没有 received 的行就什么都不做。
--   p_limit 一次最多几行(默认 200,1–1000);返回 {processed, transformed, failed, awaiting}。
-- MES-2(2026-10-06,MES-2 Step 0 Q6,Tim):它也取 awaiting_transform 的行 —— 但【只取它那一类此刻已经有转换器的】。
--   一类接上转换器之前送来的行(MES-1 起它们停在 awaiting_transform),从此由同一个按钮接着处理,不必由 cto / admin 一行一行重试;
--   还没有转换器的类照旧不碰(再交给分派器一次只会把 attempts 白白加一)。
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
    FOR v_id IN SELECT b.id FROM ingest_inbox b
                 WHERE b.status = 'received'
                    OR (b.status = 'awaiting_transform'
                        AND EXISTS (SELECT 1 FROM ingest_data_classes c
                                     WHERE c.code = b.data_class AND c.transform_function IS NOT NULL))
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

-- db/functions/set_ingest_settings.sql
-- MES-1(2026-10-06,MES-0 Q7;MES-1 Step 0 Q9 · Q13 · Q22):改采集层的传输上限 —— 那一行配置唯一的写入口。
--   持 action.manage_devices。p_fields 只认六个键(fail_budget · fail_window_s · global_reject_budget · max_payload_bytes ·
--   max_messages · clock_ahead_s),别的键按名拒(INGEST_SETTING_UNKNOWN|<键>);每一个值必须是正整数
--   (INGEST_SETTING_INVALID|<键>)。修改史 = 变更记录(Q22)。
-- MES-2(2026-10-06,MES-2 Step 0 Q26 · Q30,Tim):多认两个键,两者都可以给 null(= 清空):
--   require_calibrated_since  校准规则的开关 —— 'YYYY-MM-DD' 或 null(关)
--   calibration_lead_days     V8,校准到期前多少天开始提醒 —— 正整数或 null("Not yet set")
--   原来那六个键照旧只认正整数、不认 null。一个键没给 = 那一列不动。
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
    c_nullable constant text[] := ARRAY['require_calibrated_since', 'calibration_lead_days'];
    v_key text;
    f     jsonb := COALESCE(p_fields, '{}'::jsonb);
BEGIN
    PERFORM require_permission('action.manage_devices');
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF v_key = ANY (c_keys) THEN
            IF COALESCE(f ->> v_key, '') !~ '^[1-9][0-9]{0,8}$' THEN
                RAISE EXCEPTION 'INGEST_SETTING_INVALID|%', v_key;
            END IF;
        ELSIF v_key = 'require_calibrated_since' THEN
            -- 一个不存在的日期(2026-13-40)在转换时就抛 —— 接住,按名拒;转回来逐字相同才算一个 YYYY-MM-DD
            IF jsonb_typeof(f -> v_key) <> 'null' THEN
                BEGIN
                    IF COALESCE(f ->> v_key, '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' OR (f ->> v_key)::date::text <> f ->> v_key THEN
                        RAISE EXCEPTION 'not a date';
                    END IF;
                EXCEPTION WHEN OTHERS THEN
                    RAISE EXCEPTION 'INGEST_SETTING_INVALID|%', v_key;
                END;
            END IF;
        ELSIF v_key = 'calibration_lead_days' THEN
            IF jsonb_typeof(f -> v_key) <> 'null' AND COALESCE(f ->> v_key, '') !~ '^[1-9][0-9]{0,4}$' THEN
                RAISE EXCEPTION 'INGEST_SETTING_INVALID|%', v_key;
            END IF;
        ELSE
            RAISE EXCEPTION 'INGEST_SETTING_UNKNOWN|%', v_key;
        END IF;
    END LOOP;
    UPDATE ingest_settings
       SET fail_budget          = COALESCE((f ->> 'fail_budget')::integer, fail_budget),
           fail_window_s        = COALESCE((f ->> 'fail_window_s')::integer, fail_window_s),
           global_reject_budget = COALESCE((f ->> 'global_reject_budget')::integer, global_reject_budget),
           max_payload_bytes    = COALESCE((f ->> 'max_payload_bytes')::integer, max_payload_bytes),
           max_messages         = COALESCE((f ->> 'max_messages')::integer, max_messages),
           clock_ahead_s        = COALESCE((f ->> 'clock_ahead_s')::integer, clock_ahead_s),
           require_calibrated_since = CASE WHEN f ? 'require_calibrated_since'
                                           THEN (f ->> 'require_calibrated_since')::date ELSE require_calibrated_since END,
           calibration_lead_days    = CASE WHEN f ? 'calibration_lead_days'
                                           THEN (f ->> 'calibration_lead_days')::integer ELSE calibration_lead_days END,
           updated_by           = auth.uid()
     WHERE id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INGEST_SETTINGS_MISSING';
    END IF;
END;
$function$;


-- MES-2(2026-10-06,MES-2 Step 0 Q27):校准闸在这里 —— 每一条收货定价路径都落进本引擎,所以只问一次
-- (assert_receipt_reading_calibrated;试算 preview_reprice_inbound_batch 问同一支)。
-- FIN-21(2026-08-06):改问 fx_rate_asof —— 同一条解析规则,多拿一个【取自哪一天】,
-- 与所用侧(恒 tt_sell)一起记进 price_history.rate_as_of / rate_type。
-- 缺牌价仍拒:再调一次 fx_rate_for 抛唯一的 FX_RATE_MISSING(重估写入侧同一模式)。

CREATE OR REPLACE FUNCTION public.reprice_inbound_batch(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text DEFAULT 'USD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_old       numeric;
    v_deleted   timestamptz;
    v_qty       numeric;
    v_remaining numeric;
    v_code      text;
    v_fx        numeric;
    v_fx_asof date;   -- FIN-21:牌价取自哪一天(fx_rate_asof 的 as_of)
    v_usd       numeric;
    v_split     jsonb;
    v_delta     numeric;
    v_ratio     numeric;
    v_inv       numeric := 0;
    v_cost      numeric := 0;
    v_lines     jsonb;
    v_je        jsonb := NULL;
BEGIN
    -- ★ ROLE-1 Batch 4a(Tim 2026-09-24:看不见价格的人不能定价,【在库里】挡):这是每一条定价路径
    --   (建单带价、定价面板、按已承诺条款改价、应用化验)都落进来的那一支引擎,所以
    --   "看得见采购价"在这里问【按按钮的那个人】(DEFINER 不改 auth.uid())。它原来那道嵌套的
    --   module.inbound.edit 拆掉(ROLE-1 Batch 2 grilling 第 4 条登记给 Batch 4 的那一处):
    --   谁能定价由各自的门说 —— 手工定价 action.price_receipts,应用化验 action.apply_assay。
    --   本支的 EXECUTE 已从 authenticated 收回(侧门 (c)),只经那几扇门进来。
    PERFORM require_permission('data.view_purchase_prices');
    SELECT unit_price, deleted_at, quantity, remaining_qty, code
    INTO v_old, v_deleted, v_qty, v_remaining, v_code
    FROM inbound_batches WHERE id = p_inbound_batch_id FOR UPDATE;
    IF NOT FOUND OR v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;
    -- MES-2(Q26 · Q27):校准闸 —— 这张收货单的读数可不可以拿去定价。开关空着时什么都不拒;判据只在那一支函数里。
    PERFORM assert_receipt_reading_calibrated(p_inbound_batch_id);
    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【定价日】的行方卖出价(tt_sell)估值 ——
    -- 这批货将来要向银行买外币去付。当日无牌价即拒(FX_RATE_MISSING);
    -- 汇率不再由调用方递入(p_fx_rate 必须为空),原币与所用汇率仍进 price_history。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    -- FIN-21:问 fx_rate_asof —— 同一条解析规则,多拿一个【取自哪一天】。
    -- 缺牌价时它返回空行;再调一次 fx_rate_for 让它抛出唯一的那份
    -- FX_RATE_MISSING|币种|日期|侧(重估写入侧同一模式,错误文案不写第二遍)。
    SELECT a.rate, a.as_of INTO v_fx, v_fx_asof
    FROM fx_rate_asof(p_currency, CURRENT_DATE, 'tt_sell') a;
    IF v_fx IS NULL THEN
        PERFORM fx_rate_for(p_currency, CURRENT_DATE, 'tt_sell');
    END IF;

    v_usd := round(p_unit_price * v_fx, 4);  -- 单价 4 位小数(FIN-0 起为 SGD 本位价;列名沿用 _usd,重命名与生产重建同批)

    -- GUC 放行本函数内的 unit_price 更新(guard_inbound_price_change),用毕即清,
    -- 免得同事务内后续的直改被误放行(同 movement_ctx 模式)。
    PERFORM set_config('evoltrya.price_ctx', 'set_inbound_unit_price', true);
    UPDATE inbound_batches
    SET unit_price = v_usd, updated_by = v_user, updated_at = now()
    WHERE id = p_inbound_batch_id;
    PERFORM set_config('evoltrya.price_ctx', '', true);

    INSERT INTO price_history (inbound_batch_id, old_unit_price, new_unit_price, currency, original_price, fx_rate,
                               rate_as_of, rate_type, notes, created_by)
    VALUES (p_inbound_batch_id, v_old, v_usd, p_currency, p_unit_price, v_fx,
            v_fx_asof, 'tt_sell', p_notes, v_user);

    -- cut 2a:计价即入账 —— 整批数量 × 价差(负债在收货整批上成立,非剩余量)。
    -- 记于定价日 CURRENT_DATE(到货日尚无金额,刻意如此);USD 口径(原币在 price_history)。
    -- 拆分算术来自 reprice_split —— 与 preview_reprice_inbound_batch 共用同一份。
    v_split := reprice_split(v_qty, v_remaining, v_old, v_usd);
    v_delta := (v_split->>'delta_usd')::numeric;
    v_ratio := (v_split->>'in_stock_ratio')::numeric;

    IF v_delta <> 0 THEN
        -- 拆账:在库份额进 1200,已消耗份额进 5000;贷方(负差时借方)恒 2000
        v_inv  := (v_split->>'inventory_share_usd')::numeric;
        v_cost := (v_split->>'cost_share_usd')::numeric;

        v_lines := '[]'::jsonb;
        IF abs(v_inv) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '1200',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_inv),
                'line_memo', 'in-stock share');
        END IF;
        IF abs(v_cost) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '5000',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_cost),
                'line_memo', 'consumed share');
        END IF;
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2000',
            'side', CASE WHEN v_delta > 0 THEN 'credit' ELSE 'debit' END,
            'currency', base_currency_code(), 'amount_ccy', abs(v_delta));

        v_je := post_journal_entry(
            CURRENT_DATE,
            'Pricing ' || v_code,
            'purchase',
            p_inbound_batch_id,
            v_lines
        );
    END IF;

    RETURN jsonb_build_object(
        -- 旧返回键原样保留(既有调用方靠它们)
        'batch_id', p_inbound_batch_id,
        'unit_price_usd', v_usd,
        -- cut 5a 起的完整分解(界面与对账都要能逐项交代)
        'batch_code', v_code,
        'old_unit_price', v_old,
        'new_unit_price', v_usd,
        'price_delta_usd', v_delta,
        'in_stock_ratio', v_ratio,
        'inventory_share_usd', v_inv,
        'cost_share_usd', v_cost,
        'journal_code', v_je->>'code'
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.preview_reprice_inbound_batch(p_inbound_batch_id uuid, p_new_unit_price numeric, p_currency text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old       numeric;
    v_qty       numeric;
    v_remaining numeric;
    v_fx        numeric;
    v_fx_asof   date;
    v_base      numeric;
    v_split     jsonb;
    v_delta     numeric;
BEGIN
    PERFORM require_permission('data.view_purchase_prices');
    SELECT unit_price, quantity, remaining_qty
    INTO v_old, v_qty, v_remaining
    FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    -- MES-2(Q27):与 reprice_inbound_batch 同一道校准闸 —— 提交会被拒的,试算也不许说"可以"
    PERFORM assert_receipt_reading_calibrated(p_inbound_batch_id);
    IF p_new_unit_price IS NULL OR p_new_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;

    -- 【与 reprice_inbound_batch 逐行同构】本位币免换算;外币按【定价日】(即
    -- 提交时的 CURRENT_DATE)的 tt_sell 折算,缺牌价时用同一个 fx_rate_for 抛出
    -- 同一份 FX_RATE_MISSING|币种|日期|侧。少乘这一次就是 ASY-1 之前那个 56% 的差。
    SELECT a.rate, a.as_of INTO v_fx, v_fx_asof
    FROM fx_rate_asof(p_currency, CURRENT_DATE, 'tt_sell') a;
    IF v_fx IS NULL THEN
        PERFORM fx_rate_for(p_currency, CURRENT_DATE, 'tt_sell');
    END IF;

    v_base  := round(p_new_unit_price * v_fx, 4);
    v_split := reprice_split(v_qty, v_remaining, v_old, v_base);
    v_delta := (v_split->>'delta_usd')::numeric;

    -- 价差不为零时提交要过账 —— 过账过不去的日子,试算也不许说"可以"
    IF v_delta <> 0 THEN
        PERFORM assert_posting_allowed(CURRENT_DATE, 'purchase');
    END IF;

    RETURN jsonb_build_object(
        'old_unit_price', v_old,
        'new_unit_price', v_base,
        'delta_usd', v_delta,
        'in_stock_ratio', (v_split->>'in_stock_ratio')::numeric,
        'inventory_share_usd', (v_split->>'inventory_share_usd')::numeric,
        'cost_share_usd', (v_split->>'cost_share_usd')::numeric,
        -- 折算用的牌价与它取自哪天:屏幕上的数是怎么来的,要指得出来(FIN-21)
        'fx_rate', v_fx,
        'rate_as_of', v_fx_asof,
        'currency', p_currency
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.issue_cod(p_cod_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cod   record;
    v_lic   jsonb;
    v_done  jsonb;
    v_data  jsonb;
    v_code  text;
    v_token uuid;
    v_now   timestamptz;
BEGIN
    IF NOT has_permission('action.issue_cod') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;

    SELECT c.id, c.inbound_batch_id, c.status, c.completed_on INTO v_cod
      FROM certificates_of_destruction c WHERE c.id = p_cod_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'COD_NOT_FOUND|%', COALESCE(p_cod_id::text, '?');
    END IF;
    IF v_cod.status <> 'pending' THEN
        RAISE EXCEPTION 'COD_ALREADY_ISSUED|%', v_cod.status;
    END IF;

    -- 【签发那一刻再问一次判据】—— 不重写,问同一支函数。
    v_done := cod_delivery_completion(v_cod.inbound_batch_id);
    IF NOT (v_done->>'complete')::boolean THEN
        RAISE EXCEPTION 'CANNOT_CERTIFY|%|%', v_done->>'batch_code', v_done->>'reason';
    END IF;

    -- ── 执照闸(COD-2:两端日期都查)────────────────────────────────────────
    -- 【判据不在这里重写】cod_governing_licence() 是唯一那一份,六句具名拒绝
    -- 也住在那里。这里只负责把它抛出去 —— 而【抛出去的名字必须各不相同】,
    -- 因为补救的办法各不相同(去录一行 / 去补日期 / 去核对到货日期)。
    -- 【不发明任何占位执照号】—— 表今天是空的,所以今天什么都签发不了,而那是对的:
    -- NEA 发照之前 Tim 不会买料。
    v_lic := cod_governing_licence((v_done->>'completed_on')::date);
    IF NOT (v_lic->>'ok')::boolean THEN
        -- 【拒绝要说得出下一步去哪】与 loadDocumentCompany 的 COMPANY_MISSING_MESSAGE
        -- 同一条:一句报不出去处的拒绝,等于把人留在原地。
        RAISE EXCEPTION '%|%', v_lic->>'reason', v_lic->>'detail';
    END IF;

    -- MES-2(Q27):校准闸 —— 证书证的是这张收货单的数量(cod_certificate_data 印 ib.quantity),它的读数要过同一支判据。
    -- 【放在这里,不放进 cod_delivery_completion】那一支与 refresh_cod_for_batch 共用,在那里拒会去作废证书。
    PERFORM assert_receipt_reading_calibrated(v_cod.inbound_batch_id);

    v_code  := next_cod_code();
    v_token := gen_random_uuid();
    v_now   := clock_timestamp();

    -- 【快照由服务端自己组装,不收调用者递进来的一份】否则冻住的是调用者说的话。
    -- (record_traceability_report_issue 自己调 traceability_report_data,同一条。)
    v_data := cod_certificate_data(v_cod.inbound_batch_id);

    -- 【证书这一块用【真的】签发值覆盖】组装时它还是 pending。
    -- ★ issued_by 只存 uuid,【不解析成人名】★ —— 裁定:纸上没有人名,
    -- "谁处理的"是公司。签发人是一条记录,不是印在证书上的一行。
    v_data := (v_data - 'certificate') || jsonb_build_object(
        'certificate', jsonb_build_object(
            'id', v_cod.id, 'code', v_code, 'status', 'issued',
            'issued_at', v_now, 'issued_by', auth.uid(),
            'verification_token', v_token,
            'completed_on', v_cod.completed_on));

    -- 【任何一格缺了就按名拒,绝不回落去读活行、也绝不印一片空白】(S6 规则二)
    IF v_data->'company'->>'legal_name' IS NULL
       OR btrim(v_data->'company'->>'legal_name') = '' THEN
        RAISE EXCEPTION 'COMPANY_LEGAL_NAME_MISSING|/finance/company';
    END IF;
    IF v_data->'supplier'->>'name' IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_NAME_MISSING|%', v_data->'inbound_batch'->>'code';
    END IF;
    -- 【第二道,刻意留着】上面的闸已经过了,这一句问的是"组装出来的那一份里
    -- 到底有没有那一格" —— 两句问的不是同一件事,而快照是核验页几年后的唯一依据。
    IF v_data->'licence' = 'null'::jsonb OR v_data->'licence' IS NULL THEN
        RAISE EXCEPTION 'COD_LICENCE_NOT_RECORDED|/purchasing/licences';
    END IF;

    UPDATE certificates_of_destruction
       SET status = 'issued', code = v_code, verification_token = v_token,
           snapshot = v_data, issued_at = v_now, issued_by = auth.uid()
     WHERE id = p_cod_id;

    RETURN jsonb_build_object(
        'cod_id', v_cod.id, 'code', v_code, 'status', 'issued',
        'verification_token', v_token, 'issued_at', v_now,
        'batch_code', v_data->'inbound_batch'->>'code');
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
        ('ingest_settings',     ARRAY['module.processing.view'],  'ingest_settings',     'id', 'table', NULL),
        -- MES-2(2026-10-06,MES-2 Step 0 Q33):地磅单 —— 收货或物流查看码任一(与表的读策略逐字同一对,Q22)
        ('weighbridge_ticket',  ARRAY['module.inbound.view', 'module.logistics.view'], 'weighbridge_tickets', 'id', 'table', NULL)
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
        ('device',             1, 'gateway_keys',     'devices',             'gateway_id',        '{}'::jsonb, 'down', true, true),
        -- ── MES-2:设备 —— 校准记录(记 · 作废;Q33)。地磅单 —— 它的称重(毛重 · 皮重 · 更正)、分出去的份、照片(传 · 撤)。
        --    草稿与确认时改过的值不挂进来:它们的读码是加工(查看),不是地磅单的门;确认队列与地磅单页上直接列它们 ──
        ('device',             2, 'instrument_calibrations', 'devices',      'device_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 1, 'weighings',        'weighbridge_tickets', 'ticket_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 2, 'weighbridge_ticket_shares', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 3, 'weighbridge_ticket_photos', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- ── 8 · 换了签名的两支收货函数:DROP 旧签名、CREATE 新的(镜像原样;新参数都在末尾、都带默认值)──────────

DROP FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text);

-- db/functions/create_inbound_batch.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q19,Tim):末尾多三个参数(p_ticket_id · p_ticket_share_kg · p_quantity_reason),都带默认值 ——
--   签名变了,所以迁移是 DROP + CREATE(preflight 不许 CREATE OR REPLACE 换签名);已部署的旧应用不传它们,照样解析到这一支。

CREATE OR REPLACE FUNCTION public.create_inbound_batch(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date, p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text, p_currency text DEFAULT NULL::text, p_ticket_id uuid DEFAULT NULL::uuid, p_ticket_share_kg numeric DEFAULT NULL::numeric, p_quantity_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_id      uuid;
    v_warn    text[];
    v_pricing jsonb := NULL;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q1):建收货单归仓库 —— action.receive_goods
    --   (warehouse · admin),不再是 module.inbound.edit。先问它,所以拒绝点名的是它;带价那一支另外
    --   还要 action.price_receipts + data.view_purchase_prices(下面,不变 —— Batch 3b Q5)。
    PERFORM require_permission('action.receive_goods');
    -- ★ ROLE-1 Batch 4a(grilling Q4):建单【带价】就是定价 —— 要 action.price_receipts 与
    --   data.view_purchase_prices,在【写入之前】按名拒,整笔建单回滚;绝不悄悄丢掉那个价。
    --   不带价的建单只要 module.inbound.edit(仓库照建)。
    IF p_unit_price IS NOT NULL THEN
        PERFORM require_permission('action.price_receipts');
        PERFORM require_permission('data.view_purchase_prices');
    END IF;

    -- IOD-2-fu1:到货日【按名】必填。不写这一句,漏出去的是 FIN-32 的约束原文。
    -- 【不给默认值】:CURRENT_DATE 会让留空比填对更容易通过。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    -- MES-2(Tim 2026-10-06,MES-0 Q21 · MES-2 Step 0 Q19):建单【那一刻】挂一张地磅单的份 —— 数量默认 = 这一份,
    --   人填了别的数要写理由(收货单两个都留着:份的公斤数在 weighbridge_ticket_shares,数量在这里)。写入之前按名拒。
    IF p_ticket_id IS NULL AND (p_ticket_share_kg IS NOT NULL OR p_quantity_reason IS NOT NULL) THEN
        RAISE EXCEPTION 'TICKET_SHARE_WITHOUT_TICKET';
    END IF;
    IF p_ticket_id IS NOT NULL THEN
        IF COALESCE(p_unit, 'kg') <> 'kg' THEN
            RAISE EXCEPTION 'RECEIPT_TICKET_NEEDS_KG|%', p_unit;
        END IF;
        IF p_ticket_share_kg IS NULL OR p_ticket_share_kg <= 0 THEN
            RAISE EXCEPTION 'TICKET_SHARE_KG_INVALID';
        END IF;
        IF p_quantity IS DISTINCT FROM p_ticket_share_kg AND btrim(COALESCE(p_quantity_reason, '')) = '' THEN
            RAISE EXCEPTION 'RECEIPT_QUANTITY_REASON_REQUIRED|%|%', p_quantity, p_ticket_share_kg;
        END IF;
    END IF;

    -- 【顺序要紧】库位先校验再落库:拒绝必须发生在写入之前,否则一次被拒的
    -- 收货会留下半个批次(单事务会回滚,但错误信息的语义也该是"什么都没发生")。
    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸。同样在写入之前 —— 它可能抛 IOD_CLASS_EXCLUDED。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    -- GRN-1a:p_declared_qty 原样落库,【不拒绝任何差异】,也【绝不从采购行推断】。
    -- PROC-2c:确定度随表头一起落 —— 适用性由 trg_inbound_batches_condition_applicable
    -- 判(它在库里,所以这条路、批次页面、直连 SQL 三条一起盖住)。
    -- RECV-SOURCE-1:理由原样落库,拒绝(RECEIPT_SOURCE_REQUIRED /
    -- SOURCE_REASON_EXPLANATION_REQUIRED)由 guard_receipt_source_stated 抛 ——
    -- 本函数一个字都不重复它们,重复一遍就是第二份会漂开的判断。
    -- INB-PAY-1:unit_price 【不在这里落】—— 见下面定价那一段。
    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, unit, remaining_qty, arrival_date,
        stage, notes, purchase_order_id, purchase_order_line_id,
        declared_qty, chemistry_certainty_code, source_reason_code, source_reason_note,
        created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_arrival_date,
        COALESCE(p_stage,'待加工'), p_notes, p_purchase_order_id, p_purchase_order_line_id,
        p_declared_qty, p_chemistry_certainty, p_source_reason_code,
        NULLIF(btrim(COALESCE(p_source_reason_note, '')), ''),
        v_user, v_user)
    RETURNING id INTO v_id;

    -- PROC-2c:安全状态【只在给了参数时才碰】。
    -- 【NULL 与 '{}' 在这里是两件事】NULL = "这条路没提这件事"(既有调用点),
    -- '{}' = "明说了:一个状态都没有"。两者结果相同(零行),但只有前者
    -- 保证【一个字节都不动】—— F1 钉的正是这个。
    IF p_safety_states IS NOT NULL THEN
        PERFORM set_inbound_safety_states(v_id, p_safety_states);
    END IF;

    -- 用毕即清 —— 同 commit_processing_run 的 movement_ctx:免得同事务内后续的
    -- 插入把这个库位当成自己的(那正是 ctx 这种机制唯一的锋利处)。
    PERFORM set_config('evoltrya.location_ctx', '', true);

    -- MES-2:地磅单的份【先于】定价落下 —— 建单带价时的定价会过校准闸,闸要看得见这张单的读数。
    IF p_ticket_id IS NOT NULL THEN
        PERFORM weighbridge_share_internal(p_ticket_id, v_id, NULL, p_ticket_share_kg,
                                           CASE WHEN p_quantity IS DISTINCT FROM p_ticket_share_kg THEN p_quantity_reason END);
    END IF;

    -- INB-PAY-1:建单带价 = 建单 + 定价,【同一事务】。
    -- ★ ROLE-1 Batch 4b(Tim 的 Q4):建单带价从此是【建单(不带价)+ 同一事务里提一张定价申请】
    --   (来源 desk)—— CFO 批了才进账;收货页上看得见它在等 CFO。提交时照批准那一刻的同一支过账
    --   试跑,所以非正价格、非法币种、缺牌价照旧按名拒,任何一条拒绝都让整笔建单回滚。
    --   审批关着时申请生下来就是 approved 并当场过账(与从前一样一步到位)。
    IF p_unit_price IS NOT NULL THEN
        v_pricing := receipt_price_submit_internal(v_id, p_unit_price, p_currency, 'desk', NULL, NULL, NULL);
    END IF;

    -- IOD-2:返回值从 uuid 变成 jsonb —— 告警要有地方回去。batch_id 仍在里面。
    -- INB-PAY-1:定价的分解随之返回;不带价时为 null。ROLE-1 Batch 4b 起它是那张申请
    -- (request_id / label / status;审批关着时还有 journal_code)。
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn),
                              'pricing', v_pricing);
END;
$function$

;

DROP FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text);

-- db/functions/receive_inbound_batch_against_po.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q19,Tim):末尾多三个参数(p_ticket_id · p_ticket_share_kg · p_quantity_reason),都带默认值 ——
--   签名变了,迁移是 DROP + CREATE;已部署的旧应用不传它们,照样解析到这一支。

CREATE OR REPLACE FUNCTION public.receive_inbound_batch_against_po(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_arrival_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text, p_ticket_id uuid DEFAULT NULL::uuid, p_ticket_share_kg numeric DEFAULT NULL::numeric, p_quantity_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q1):现场收货归仓库 —— action.receive_goods。
    PERFORM require_permission('action.receive_goods');

    -- IOD-2-fu1:同上 —— 现场收货这条路一样进得到 FIN-32 的约束。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    -- MES-2(MES-2 Step 0 Q19):见 create_inbound_batch 里同一段 —— 份在建单那一刻给,数量与份不同要写理由。
    IF p_ticket_id IS NULL AND (p_ticket_share_kg IS NOT NULL OR p_quantity_reason IS NOT NULL) THEN
        RAISE EXCEPTION 'TICKET_SHARE_WITHOUT_TICKET';
    END IF;
    IF p_ticket_id IS NOT NULL THEN
        IF p_ticket_share_kg IS NULL OR p_ticket_share_kg <= 0 THEN
            RAISE EXCEPTION 'TICKET_SHARE_KG_INVALID';
        END IF;
        IF p_quantity IS DISTINCT FROM p_ticket_share_kg AND btrim(COALESCE(p_quantity_reason, '')) = '' THEN
            RAISE EXCEPTION 'RECEIPT_QUANTITY_REASON_REQUIRED|%|%', p_quantity, p_ticket_share_kg;
        END IF;
    END IF;

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸,写入之前。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    -- 单位固定 kg、stage 用默认值 —— 与收货表单今天的行为逐字一致。
    -- 【采购单侧的那一串拒绝(PO_NOT_RECEIVABLE / PO_LINE_MISMATCH /
    --  PO_NOT_APPROVED / SUPPLIER_QUALIFICATION_EXPIRED)仍由表上的触发器抛出】,
    -- 这个函数一个字都不重复它们 —— 重复一遍就是第二份会漂开的判断。
    -- RECV-SOURCE-1 的两条拒绝(RECEIPT_SOURCE_REQUIRED / PO_HEADER_WITHOUT_LINE)
    -- 同一条:触发器抛,这里不抄。
    -- 【GRN-1a:收错料【不拒绝】】—— 换料是一个正当的、可以谈成的场景,
    -- 而拒绝会把它变成一次不可能完成的收货。它由 grn_discrepancies 点名
    -- (material_mismatch),由人去判断。
    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, remaining_qty, unit, arrival_date,
        notes, purchase_order_id, purchase_order_line_id, declared_qty,
        chemistry_certainty_code, source_reason_code, source_reason_note,
        created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, p_quantity, 'kg', p_arrival_date,
        p_notes, p_purchase_order_id, p_purchase_order_line_id, p_declared_qty,
        p_chemistry_certainty, p_source_reason_code,
        NULLIF(btrim(COALESCE(p_source_reason_note, '')), ''),
        v_user, v_user)
    RETURNING id INTO v_id;

    -- PROC-2c:见 create_inbound_batch 里同一段注释 —— NULL 与 '{}' 是两件事。
    IF p_safety_states IS NOT NULL THEN
        PERFORM set_inbound_safety_states(v_id, p_safety_states);
    END IF;

    PERFORM set_config('evoltrya.location_ctx', '', true);
    IF p_ticket_id IS NOT NULL THEN
        PERFORM weighbridge_share_internal(p_ticket_id, v_id, NULL, p_ticket_share_kg,
                                           CASE WHEN p_quantity IS DISTINCT FROM p_ticket_share_kg THEN p_quantity_reason END);
    END IF;
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$

;

-- ── 9 · 新视图(镜像原样)──────────────────────────────────────────────────────

-- db/views/weighing_calibration_all.sql
-- MES-2(2026-10-06,MES-0 Q30;MES-2 Step 0 Q25 · Q27,Tim):【每一次称重,在它那一刻,仪器在不在校准期内】—— 基视图,不给人读。
--   captured_on = 读数那一天(新加坡日历);对它挑这台仪器【没作废、calibrated_on ≤ captured_on】的最近一行校准
--   (按 calibrated_on,再按 id —— id 是 identity,同一天记两行也排得出先后),交给 calibration_status_from 判:
--   in_calibration · expired · failed · never_calibrated;没有记录仪器 → not_recorded。
--   is_current = 这一行没有被更正过(更正读最新的)。
--   【属主视图、不带谓词、EXECUTE / SELECT 从 authenticated 收回】:读者经 weighing_calibration(带门的外壳)读它;
--   校准闸 assert_receipt_reading_calibrated(调用方都是 DEFINER)以属主身份直接读它。视图读视图走属主替换。

CREATE VIEW public.weighing_calibration_all WITH (security_invoker = off) AS
 SELECT w.id AS weighing_id,
    w.ticket_id,
    w.role,
    w.weight_kg,
    w.source,
    w.device_id,
    d.code AS device_code,
    w.captured_at,
    (w.captured_at AT TIME ZONE 'Asia/Singapore'::text)::date AS captured_on,
    NOT (EXISTS ( SELECT 1
           FROM weighings x
          WHERE x.corrects_id = w.id)) AS is_current,
    c.id AS calibration_id,
    c.result AS calibration_result,
    c.valid_until,
        CASE
            WHEN w.device_id IS NULL THEN 'not_recorded'::text
            ELSE calibration_status_from(c.result, c.valid_until, (w.captured_at AT TIME ZONE 'Asia/Singapore'::text)::date)
        END AS status
   FROM weighings w
     LEFT JOIN devices d ON d.id = w.device_id
     LEFT JOIN LATERAL ( SELECT ic.id,
            ic.result,
            ic.valid_until
           FROM instrument_calibrations ic
          WHERE ic.device_id = w.device_id AND ic.voided_at IS NULL
            AND ic.calibrated_on <= (w.captured_at AT TIME ZONE 'Asia/Singapore'::text)::date
          ORDER BY ic.calibrated_on DESC, ic.id DESC
         LIMIT 1) c ON true;

COMMENT ON VIEW public.weighing_calibration_all IS
    'MES-2:每一次称重在读数那一天(新加坡日历)仪器在不在校准期内 —— in_calibration · expired · failed · never_calibrated · not_recorded(没有记录仪器)。is_current = 没被更正过。基视图,不给人读:读者经 weighing_calibration;校准闸以属主身份读它。';

REVOKE ALL ON public.weighing_calibration_all FROM authenticated, anon;

-- db/views/weighing_calibration.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q28,Tim):weighing_calibration_all 的【带门外壳】—— 地磅单页、收货单页、确认队列读它,
--   把"instrument not recorded" / 不在校准期内标出来(开关关着时只标,不拒)。行谓词与 weighings 的读策略逐字同一句。

CREATE VIEW public.weighing_calibration WITH (security_invoker = off) AS
 SELECT weighing_id,
    ticket_id,
    role,
    weight_kg,
    source,
    device_id,
    device_code,
    captured_at,
    captured_on,
    is_current,
    calibration_id,
    calibration_result,
    valid_until,
    status
   FROM weighing_calibration_all
  WHERE has_permission('module.processing.view'::text) OR has_permission('module.inbound.view'::text)
     OR has_permission('module.logistics.view'::text);

COMMENT ON VIEW public.weighing_calibration IS
    'MES-2:weighing_calibration_all 的带门外壳(加工 / 收货 / 物流查看码任一,与 weighings 的读策略同一句)。';

GRANT SELECT ON public.weighing_calibration TO authenticated;
REVOKE ALL ON public.weighing_calibration FROM anon;

-- db/views/instrument_calibration_now.sql
-- MES-2(2026-10-06,规格 §8.2;MES-0 Q31 · V8;MES-2 Step 0 Q23 · Q25 · Q29,Tim):【每一台仪器今天在不在校准期内】——
--   /operation/calibration 与设备页读它,两条提醒臂(instrument_calibration_due · _approaching)也读它。
--   仪器 = 秤、地磅、电表、在线仪表(Q23),没停用的。in_use = interface_status 不是 reserved(登记了、还没装的占位不催)。
--   今天的状态:挑法与 weighing_calibration_all 同一个(没作废、calibrated_on ≤ 今天的最近一行,calibrated_on 再 id),
--   判断是同一支 calibration_status_from。approaching:在期内、V8 给了、有效期落在 [今天, 今天 + 提前天数] 里;V8 没给 → 恒为 false。
--   【属主视图】读校准记录与设置不过 RLS,所以行谓词在这里再问一次(module.processing.view)。

CREATE VIEW public.instrument_calibration_now WITH (security_invoker = off) AS
 SELECT d.id AS device_id,
    d.code,
    d.name,
    d.kind,
    d.station,
    d.interface_status,
    d.interface_status <> 'reserved'::text AS in_use,
    d.capacity,
    d.unit,
    d.created_at AS registered_at,
    c.id AS calibration_id,
    c.calibrated_on,
    c.valid_until,
    c.result,
    c.certificate_no,
    c.calibrating_body,
    calibration_status_from(c.result, c.valid_until, CURRENT_DATE) AS status,
    calibration_status_from(c.result, c.valid_until, CURRENT_DATE) = 'in_calibration'::text
      AND s.calibration_lead_days IS NOT NULL
      AND c.valid_until <= (CURRENT_DATE + s.calibration_lead_days) AS approaching,
    s.calibration_lead_days AS lead_days
   FROM devices d
     CROSS JOIN ( SELECT ingest_settings.calibration_lead_days
           FROM ingest_settings
          WHERE ingest_settings.id) s
     LEFT JOIN LATERAL ( SELECT ic.id,
            ic.calibrated_on,
            ic.valid_until,
            ic.result,
            ic.certificate_no,
            ic.calibrating_body
           FROM instrument_calibrations ic
          WHERE ic.device_id = d.id AND ic.voided_at IS NULL AND ic.calibrated_on <= CURRENT_DATE
          ORDER BY ic.calibrated_on DESC, ic.id DESC
         LIMIT 1) c ON true
  WHERE d.kind = ANY (ARRAY['scale'::text, 'weighbridge'::text, 'meter'::text, 'inline_instrument'::text])
    AND d.retired_at IS NULL AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.instrument_calibration_now IS
    'MES-2:每一台没停用的仪器(秤 · 地磅 · 电表 · 在线仪表)今天在不在校准期内 —— 最近一条没作废的校准记录 + calibration_status_from。in_use = 不是 reserved。approaching 只在 V8(calibration_lead_days)给了时才可能为真。行谓词 module.processing.view。';

GRANT SELECT ON public.instrument_calibration_now TO authenticated;
REVOKE ALL ON public.instrument_calibration_now FROM anon;

-- db/views/weighbridge_ticket_weights.sql
-- MES-2(2026-10-06,MES-0 Q19;MES-2 Step 0 Q16 · Q18,Tim):【一张地磅单此刻的毛重、皮重、净重,以及分出去了多少】—— 读的时候算。
--   毛重 / 皮重 = 指着本单、角色 gross / tare、【没被更正过】的那一行称重;净重 = 毛重 − 皮重(两磅都在才有)。
--   status:voided · complete(两磅都在)· open。
--   shared_kg = 分给【没删除】的收货单与发货行的份之和;difference_kg = 净重 − shared_kg —— 照直显示,从不强迫为 0(MES-0 Q19)。
--   deleted_receipt_shares = 分给了后来被删除的收货单的份数(那几份不计入 shared_kg,单上点名)。
--   【属主视图】读称重、份与收货单不过 RLS,所以行谓词在这里再问一次 —— 与地磅单表的读策略逐字同一句(收货或物流)。

CREATE VIEW public.weighbridge_ticket_weights WITH (security_invoker = off) AS
 SELECT t.id AS ticket_id,
    t.code,
    t.direction,
    t.vehicle_reg,
    t.notes,
    t.created_at,
    t.created_by,
    t.completed_at,
    t.voided_at,
    t.void_reason,
        CASE
            WHEN t.voided_at IS NOT NULL THEN 'voided'::text
            WHEN g.weight_kg IS NOT NULL AND tr.weight_kg IS NOT NULL THEN 'complete'::text
            ELSE 'open'::text
        END AS status,
    g.id AS gross_weighing_id,
    g.weight_kg AS gross_kg,
    g.captured_at AS gross_at,
    tr.id AS tare_weighing_id,
    tr.weight_kg AS tare_kg,
    tr.captured_at AS tare_at,
    g.weight_kg - tr.weight_kg AS net_kg,
    COALESCE(sh.shared_kg, 0::numeric) AS shared_kg,
    g.weight_kg - tr.weight_kg - COALESCE(sh.shared_kg, 0::numeric) AS difference_kg,
    COALESCE(sh.share_count, 0::bigint) AS share_count,
    COALESCE(sh.deleted_receipt_shares, 0::bigint) AS deleted_receipt_shares
   FROM weighbridge_tickets t
     LEFT JOIN LATERAL ( SELECT w.id,
            w.weight_kg,
            w.captured_at
           FROM weighings w
          WHERE w.ticket_id = t.id AND w.role = 'gross'::text
            AND NOT (EXISTS ( SELECT 1 FROM weighings x WHERE x.corrects_id = w.id))) g ON true
     LEFT JOIN LATERAL ( SELECT w.id,
            w.weight_kg,
            w.captured_at
           FROM weighings w
          WHERE w.ticket_id = t.id AND w.role = 'tare'::text
            AND NOT (EXISTS ( SELECT 1 FROM weighings x WHERE x.corrects_id = w.id))) tr ON true
     LEFT JOIN LATERAL ( SELECT sum(s.kg) FILTER (WHERE b.deleted_at IS NULL) AS shared_kg,
            count(*) FILTER (WHERE b.deleted_at IS NULL) AS share_count,
            count(*) FILTER (WHERE b.deleted_at IS NOT NULL) AS deleted_receipt_shares
           FROM weighbridge_ticket_shares s
             LEFT JOIN inbound_batches b ON b.id = s.inbound_batch_id
          WHERE s.ticket_id = t.id) sh ON true
  WHERE has_permission('module.inbound.view'::text) OR has_permission('module.logistics.view'::text);

COMMENT ON VIEW public.weighbridge_ticket_weights IS
    'MES-2:地磅单此刻的毛重、皮重(没被更正过的那两行)、净重、状态(voided · complete · open),以及分给没删除的收货单与发货行的公斤数之和与差额(照直显示,不强迫为 0)。行谓词:收货或物流查看码。';

GRANT SELECT ON public.weighbridge_ticket_weights TO authenticated;
REVOKE ALL ON public.weighbridge_ticket_weights FROM anon;

-- ── 10 · 改过的视图(镜像原样,CREATE OR REPLACE —— 列契约一字未动)──────────────────────

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
-- MES-2(2026-10-06,MES-0 Q13;MES-2 Step 0 Q29 · Q32,Tim):第 50–52 支 ——
--   · capture_draft_pending:一张网关送来的草稿还没人确认 —— 一张一行,item_date = 落草稿那一天,所以 days_waiting 就是它的年龄
--     (草稿永不过期,MES-0 Q13)。门是 action.confirm_capture(能确认它的人才需要被催)。手工录入的草稿生下来就确认了,不上牌。
--   · instrument_calibration_due:一台【在用的】仪器(interface_status 不是 reserved,没停用)今天不在校准期内 —— 过期、没通过、
--     或从来没校过。item_date = 有效期(从来没校过的取它登记那一天)。
--   · instrument_calibration_approaching:在期内、有效期落在 V8 给的提前天数里。V8(calibration_lead_days)没给 → 这一支恒为空,
--     过期本身照样由上一支上牌(每一条记录自己的有效期是必填的)。
--   后两支读 instrument_calibration_now(属主视图,一份挑法、一句判据),门是 module.processing.view。
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
         SELECT 'capture_draft_pending'::text AS item_type,
            'action.confirm_capture'::text AS permission,
            cd.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(dv.code, cd.data_class) AS item_code,
            (COALESCE(dv.name, cd.data_class) || ' · '::text) || COALESCE((cd.proposed ->> 'weight_kg'::text) || ' kg'::text, cd.data_class) AS subject,
            cd.created_at::date AS item_date
           FROM capture_drafts cd
             LEFT JOIN devices dv ON dv.id = cd.device_id
          WHERE cd.status = 'pending'::text
        UNION ALL
         SELECT 'instrument_calibration_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ic.device_id AS item_id,
            NULL::text AS doc_kind,
            ic.code AS item_code,
            (ic.name || ' · '::text) || ic.status AS subject,
            COALESCE(ic.valid_until, ic.registered_at::date) AS item_date
           FROM instrument_calibration_now ic
          WHERE ic.in_use AND ic.status <> 'in_calibration'::text
        UNION ALL
         SELECT 'instrument_calibration_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ic.device_id AS item_id,
            NULL::text AS doc_kind,
            ic.code AS item_code,
            ic.name AS subject,
            ic.valid_until AS item_date
           FROM instrument_calibration_now ic
          WHERE ic.in_use AND ic.approaching
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

-- db/views/pending_values.sql
-- MES-1(2026-10-06,MES-0 §5 · Q92 · Q93;MES-1 Step 0 Q1 · Q2,Tim):【还没给的标准值】—— /settings/pending-values 读它。
--   一支一个值(像 operations_now 那样),每一支带着它自己的权限码;读者只看得到他持码的那几支(末尾的 WHERE)。
--   每一行是一件具体还空着的事:哪一个值(value_code,对应 docs/mes-pending-values.md 里那一行)、空在哪一条记录上、去哪儿填。
--   给了值,那一行就自己消失(这张视图不存任何东西)。
-- 【MES-1 播两支】
--   V5  网关的心跳间隔 —— 每一台没停用、间隔为空的网关一行。由集成商在网关调试时给(MES-0 §5.1 V5)。
--   V6  传输异常的工作时间 —— 读班次的起止时刻(shifts.starts_at / ends_at,为空是设计如此:没人说过几点到几点)。
--       每一个启用、而起止为空的班次一行。由 Tim 给(V6)。
-- 【MES-2 加两支】(2026-10-06,MES-2 Step 0 Q12 · Q30,Tim)
--   V8   校准到期前多少天开始提醒 —— 一个值,ingest_settings.calibration_lead_days 为空时一行(去处:/operation/calibration)。
--        由校准机构 / 仪器厂商给,仪器安装时(MES-0 §5.1)。没给:到期前的提醒不上牌,过期照样上牌。
--   V33  每一台【在用的】仪器(秤 · 地磅 · 电表 · 在线仪表,interface_status 不是 reserved,没停用)的量程 —— 量程为空的每台一行
--        (去处:它的设备页)。由仪器厂商给(规格 §8.2)。没给:确认读数时不判量程(WEIGHING_ABOVE_CAPACITY 只在给了时拒)。
-- 【规矩】之后每一刀加它自己的那几支,并在【同一个提交里】往 docs/mes-pending-values.md 加它们的行(Tim,Q2)。
-- 【属主视图】读 devices / shifts 不过 RLS,所以每一支的码在末尾的 WHERE 里问一次。

CREATE OR REPLACE VIEW public.pending_values WITH (security_invoker = off) AS
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
          WHERE sh.is_active AND sh.starts_at IS NULL AND sh.ends_at IS NULL
        UNION ALL
         SELECT 'V8'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            'calibration_lead_days'::text AS item_code,
            'Calibration reminder lead days'::text AS item_label,
            '/operation/calibration'::text AS href
           FROM ingest_settings st
          WHERE st.id AND st.calibration_lead_days IS NULL
        UNION ALL
         SELECT 'V33'::text AS value_code,
            'module.processing.view'::text AS permission,
            d.id AS item_id,
            d.code AS item_code,
            d.name AS item_label,
            '/operation/devices/'::text || d.id::text AS href
           FROM devices d
          WHERE d.kind = ANY (ARRAY['scale'::text, 'weighbridge'::text, 'meter'::text, 'inline_instrument'::text])
            AND d.retired_at IS NULL AND d.interface_status <> 'reserved'::text AND d.capacity IS NULL) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程)。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- ── 11 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)────────────────
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.capture_drafts
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.capture_drafts
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.capture_draft_changes
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.capture_draft_changes
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.weighbridge_tickets
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.weighbridge_tickets
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.weighings
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.weighings
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.weighbridge_ticket_shares
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.weighbridge_ticket_shares
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.weighbridge_ticket_photos
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.weighbridge_ticket_photos
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.instrument_calibrations
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.instrument_calibrations
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 12 · 私有桶 capture-photos(MES-0 Q20 · MES-2 Step 0 Q21)—— 不在镜像里(AGENTS.md);证明在 db/scripts/2026-10-06-mes2-capture-photos-policy-proof.sql ──
--   本仓库第一个【按权限码读】的桶:此前每一个桶都只按 bucket_id 读,真正的门是它的登记表;这一个两道都有(登记表 + 桶)。
--   不给 UPDATE / DELETE 策略:照片不改、不删,拍错的在登记行上撤下。
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('capture-photos', 'capture-photos', false, 10485760, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "capture-photos read by inbound or logistics view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'capture-photos'::text
           AND (public.has_permission('module.inbound.view'::text) OR public.has_permission('module.logistics.view'::text)));

CREATE POLICY "capture-photos upload by confirm_capture"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'capture-photos'::text AND public.has_permission('action.confirm_capture'::text));

-- ── 13 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
--   下面的自证跑在本体【里面】,所以权限要在这里先落好,自证才问得到真值。
REVOKE EXECUTE ON FUNCTION public.confirm_capture_draft(uuid, jsonb, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_capture_draft(uuid, jsonb, jsonb, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.reject_capture_draft(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reject_capture_draft(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.submit_manual_capture(text, jsonb, uuid, timestamp with time zone, timestamp with time zone, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_manual_capture(text, jsonb, uuid, timestamp with time zone, timestamp with time zone, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.correct_weighing(uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_weighing(uuid, numeric, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.share_weighbridge_ticket(uuid, numeric, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.share_weighbridge_ticket(uuid, numeric, uuid, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.void_weighbridge_ticket(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_weighbridge_ticket(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_ticket_photo(uuid, text, text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_ticket_photo(uuid, text, text, text, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.withdraw_ticket_photo(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.withdraw_ticket_photo(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_instrument_calibration(uuid, date, date, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_instrument_calibration(uuid, date, date, text, text, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.void_instrument_calibration(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_instrument_calibration(bigint, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.transform_weighing_v1(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transform_weighing_v1(jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.capture_confirm_internal(uuid, jsonb, jsonb, jsonb, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.capture_confirm_internal(uuid, jsonb, jsonb, jsonb, uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.weighbridge_share_internal(uuid, uuid, uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.weighbridge_share_internal(uuid, uuid, uuid, numeric, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.assert_receipt_reading_calibrated(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assert_receipt_reading_calibrated(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.calibration_status_from(text, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.calibration_status_from(text, date, date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_capture_append_only() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_capture_append_only() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_capture_drafts_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_capture_drafts_write() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_weighbridge_tickets_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_weighbridge_tickets_write() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.generate_weighbridge_ticket_code() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.generate_weighbridge_ticket_code() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_ticket_photos_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_ticket_photos_write() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_instrument_calibrations_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_instrument_calibrations_write() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.transform_weighing_v1(jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.capture_confirm_internal(uuid, jsonb, jsonb, jsonb, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.weighbridge_share_internal(uuid, uuid, uuid, numeric, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_receipt_reading_calibrated(uuid) FROM authenticated;

-- ── 14 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes2_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes2_pending_after ON COMMIT DROP AS
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
    -- ① 授权只多那三行(admin · cto · warehouse ← action.confirm_capture),一行没少
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes2_grants_before
         EXCEPT SELECT unnest(ARRAY['admin:action.confirm_capture', 'cto:action.confirm_capture', 'warehouse:action.confirm_capture']))
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes2_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES2_PROOF|unexpected grant change: %', v_bad; END IF;
    IF (SELECT count(*) FROM role_permissions rp WHERE rp.permission_code = 'action.confirm_capture') <> 3 THEN
        RAISE EXCEPTION 'MES2_PROOF|action.confirm_capture should be held by exactly admin, cto and warehouse';
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes2_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes2_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES2_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;变更记录只在种子那几张表上动了
    IF EXISTS ((SELECT b.k, b.id FROM mes2_pending_before b EXCEPT SELECT a.k, a.id FROM mes2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes2_pending_after a EXCEPT SELECT b.k, b.id FROM mes2_pending_before b)) THEN
        RAISE EXCEPTION 'MES2_PROOF|a pending document changed state';
    END IF;
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM mes2_log_before)
       AND c.table_name NOT IN ('permissions', 'role_permissions', 'document_types', 'ingest_data_classes');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES2_PROOF|change_log moved on %', v_bad; END IF;

    -- ④ 新表一行都没有;数据类九行、两支转换器、一类落草稿;开关与 V8 都是空的;单据种类 43
    SELECT string_agg(t, ', ') INTO v_bad FROM unnest(ARRAY['capture_drafts', 'capture_draft_changes', 'weighbridge_tickets', 'weighings', 'weighbridge_ticket_shares', 'weighbridge_ticket_photos', 'instrument_calibrations']) t
     WHERE (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', t), false, true, '')))[1]::text <> '0';
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES2_PROOF|new tables not empty: %', v_bad; END IF;
    IF (SELECT count(*) FROM ingest_data_classes) <> 9
       OR (SELECT count(*) FROM ingest_data_classes WHERE transform_function IS NOT NULL) <> 2
       OR (SELECT string_agg(code, ',') FROM ingest_data_classes WHERE creates_draft) IS DISTINCT FROM 'weighing'
       OR (SELECT manual_entry_code FROM ingest_data_classes WHERE code = 'weighing') IS DISTINCT FROM 'action.confirm_capture' THEN
        RAISE EXCEPTION 'MES2_PROOF|the data classes are not as built';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL
       OR (SELECT calibration_lead_days FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES2_PROOF|require_calibrated_since and calibration_lead_days must start empty';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 43 THEN RAISE EXCEPTION 'MES2_PROOF|document_types is not 43 rows'; END IF;

    -- ⑤ 匿名面:anon 能执行的【恰好】两支;员工那几支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES2_PROOF|anon executes: %', v_bad;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.confirm_capture_draft(uuid, jsonb, jsonb, jsonb)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.confirm_capture_draft(uuid, jsonb, jsonb, jsonb)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.confirm_capture_draft(uuid, jsonb, jsonb, jsonb)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|public.confirm_capture_draft(uuid, jsonb, jsonb, jsonb): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.reject_capture_draft(uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.reject_capture_draft(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.reject_capture_draft(uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|public.reject_capture_draft(uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.submit_manual_capture(text, jsonb, uuid, timestamp with time zone, timestamp with time zone, jsonb)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.submit_manual_capture(text, jsonb, uuid, timestamp with time zone, timestamp with time zone, jsonb)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.submit_manual_capture(text, jsonb, uuid, timestamp with time zone, timestamp with time zone, jsonb)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|public.submit_manual_capture(text, jsonb, uuid, timestamp with time zone, timestamp with time zone, jsonb): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.correct_weighing(uuid, numeric, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.correct_weighing(uuid, numeric, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.correct_weighing(uuid, numeric, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|public.correct_weighing(uuid, numeric, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.share_weighbridge_ticket(uuid, numeric, uuid, uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.share_weighbridge_ticket(uuid, numeric, uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.share_weighbridge_ticket(uuid, numeric, uuid, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|public.share_weighbridge_ticket(uuid, numeric, uuid, uuid): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.void_weighbridge_ticket(uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.void_weighbridge_ticket(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.void_weighbridge_ticket(uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|public.void_weighbridge_ticket(uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_ticket_photo(uuid, text, text, text, integer)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_ticket_photo(uuid, text, text, text, integer)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_ticket_photo(uuid, text, text, text, integer)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|public.record_ticket_photo(uuid, text, text, text, integer): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.withdraw_ticket_photo(uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.withdraw_ticket_photo(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.withdraw_ticket_photo(uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|public.withdraw_ticket_photo(uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_instrument_calibration(uuid, date, date, text, text, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_instrument_calibration(uuid, date, date, text, text, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_instrument_calibration(uuid, date, date, text, text, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|public.record_instrument_calibration(uuid, date, date, text, text, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.void_instrument_calibration(bigint, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.void_instrument_calibration(bigint, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.void_instrument_calibration(bigint, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|public.void_instrument_calibration(bigint, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF has_function_privilege('authenticated', 'public.transform_weighing_v1(jsonb)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.transform_weighing_v1(jsonb)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.transform_weighing_v1(jsonb)'::regprocedure) THEN
        RAISE EXCEPTION 'MES2_PROOF|public.transform_weighing_v1(jsonb) must be an internal function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.capture_confirm_internal(uuid, jsonb, jsonb, jsonb, uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.capture_confirm_internal(uuid, jsonb, jsonb, jsonb, uuid, text)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.capture_confirm_internal(uuid, jsonb, jsonb, jsonb, uuid, text)'::regprocedure) THEN
        RAISE EXCEPTION 'MES2_PROOF|public.capture_confirm_internal(uuid, jsonb, jsonb, jsonb, uuid, text) must be an internal function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.weighbridge_share_internal(uuid, uuid, uuid, numeric, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.weighbridge_share_internal(uuid, uuid, uuid, numeric, text)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.weighbridge_share_internal(uuid, uuid, uuid, numeric, text)'::regprocedure) THEN
        RAISE EXCEPTION 'MES2_PROOF|public.weighbridge_share_internal(uuid, uuid, uuid, numeric, text) must be an internal function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.assert_receipt_reading_calibrated(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.assert_receipt_reading_calibrated(uuid)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.assert_receipt_reading_calibrated(uuid)'::regprocedure) THEN
        RAISE EXCEPTION 'MES2_PROOF|public.assert_receipt_reading_calibrated(uuid) must be an internal function nobody outside can call';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.calibration_status_from(text, date, date)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|calibration_status_from must stay executable (owner views call it as the reader)';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('capture_drafts', 'capture_draft_changes', 'weighbridge_tickets', 'weighings', 'weighbridge_ticket_shares', 'weighbridge_ticket_photos', 'instrument_calibrations', 'weighing_calibration_all', 'weighing_calibration', 'instrument_calibration_now', 'weighbridge_ticket_weights')
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES2_PROOF|anon can read %', v_bad; END IF;
    IF has_table_privilege('authenticated', 'public.weighing_calibration_all', 'SELECT') THEN
        RAISE EXCEPTION 'MES2_PROOF|weighing_calibration_all must not be readable by authenticated';
    END IF;

    -- ⑥ 那 44 条开着的读策略还是 44 条,没有一条落在新表上
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES2_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND tablename IN ('capture_drafts', 'capture_draft_changes', 'weighbridge_tickets', 'weighings', 'weighbridge_ticket_shares', 'weighbridge_ticket_photos', 'instrument_calibrations')) THEN
        RAISE EXCEPTION 'MES2_PROOF|an open read policy sits on a MES-2 table';
    END IF;

    -- ⑦ 变更记录:覆盖零缺口(七张新表都记,豁免仍是 7);遮蔽零缺口(仍是 105 条)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 7 THEN
        RAISE EXCEPTION 'MES2_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES2_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑧ 提醒臂 52 支;桶是私有的、带两条策略
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 52 THEN
        RAISE EXCEPTION 'MES2_PROOF|operations_now should have 52 arms';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'capture-photos' AND NOT public) THEN
        RAISE EXCEPTION 'MES2_PROOF|bucket capture-photos missing or public';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
          AND policyname LIKE 'capture-photos %') <> 2 THEN
        RAISE EXCEPTION 'MES2_PROOF|capture-photos should carry exactly two storage policies';
    END IF;

    -- ⑨ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES2_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
