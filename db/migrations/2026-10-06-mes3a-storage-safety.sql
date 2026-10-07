-- db/migrations/2026-10-06-mes3a-storage-safety.sql
-- MES-3a —— 仓储安全(MES 组的第三刀,v1.4.39;发布那一行在 docs/handbacks/MES-3a.md 的抬头)。
-- 由 db/scripts/build_mes3a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-06:MES-3a Step 0 的 Q1–Q33 全部照建议裁定;裁定 1–5 见 docs/surveys/MES-3a/STEP0-HANDBACK.md §0)
--   ① 库存上限(功能 4):三张新表 nea_waste_categories(NEA 废物类别,从空开始 —— V29)· licence_storage_limits(执照 × 类别的上限,V2)·
--      receipt_ceiling_checks(每一张收货 / 手工产出进来时怎么判的,只追加);materials 加 nea_waste_category_code。
--      两支收货函数与 create_output_batch 落库之后判一次:超过给了的上限按名拒,没给就照收、记下是哪一种(Q33)。
--      licence_storage_within_limit / hazardous_qty_on_hand_tonnes 删掉(没有调用方,而且"读到空就拒绝作判断"与 Q33 相反)。
--   ② 滞留提醒(功能 5):inbound_safety_states 加 dwell_warning_days(V3);视图 safety_state_dwell;提醒臂 safety_state_dwell。
--   ③ 隔离(功能 6):storage_locations 加 is_quarantine;inbound_safety_states 加 requires_quarantine(鼓包或漏液 = 要,
--      已放电 = 不要,其余没定 —— V4);收货与转移在写入之前按名拒 QUARANTINE_LOCATION_REQUIRED;视图 quarantine_exposure;
--      提醒臂 quarantine_required;库存流水的直连插入关上(MOVEMENTS_THROUGH_FUNCTION_ONLY,Q3)。
--   ④ 安全状态有历史(Q36 · Q22–Q25):两张状态表换成 id 主键,加 ended_at / ended_by / end_reason / ended_by_run_id /
--      created_by_run_id / reopened_from_id;开着的 (批次, 状态) 只有一条(部分唯一索引);只经函数写、只结束一次、永不删;
--      set_inbound_safety_states 只加新勾上的、只结束拿掉的(结束要理由);新的 set_output_safety_states;加工提交结束它解决掉的状态,
--      回滚把它们重新开出来、并结束它写上的那一条(Q2)。
--   ⑤ 并入:校准规则还原(Tim 的裁定 1)—— 不在校准期内的读数永远拒,开关只管两种缺席。
--   ⑥ 视图:operations_now 多三支(52 → 55,列契约一字未动)· pending_values 多五个值(V2 · V29 · V3 · V4 · V34)·
--      processing_wip 只数开着的状态 · 新视图 storage_ceiling_status。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改任何一张既有单据;
--   不给任何类别、上限、滞留天数、隔离库位(只播两个状态的 requires_quarantine,Q34 / Q18);require_calibrated_since 保持空。
--   线上那两条安全状态行原样开着(Q24)。
--
-- 【破窗】见 docs/surveys/MES-3a/STEP0-HANDBACK.md §12:产出批页面的安全状态面板直连插 / 删,那两条策略拿掉之后它在窗口里存不进去;
--   批次页面的到货状态面板勾上照样能存,拿掉一个会被要理由拒(旧页面不传理由);新拒绝码在旧页面上显示原文;
--   旧的审计记录把"结束一条状态"说成"记下一条状态"。定价与证书:线上 0 条称重,还原的校准规则什么都不拒。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多;七个账号一个都没被停;
--   变更记录只在 inbound_safety_states(两行引导)上动了;三张新表与类别都是空的;没有一个库位被标成隔离、没有一个滞留天数;
--   开关是空的;anon 能执行的【恰好】两支;内层谁都调不到;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口;
--   提醒臂 55 支;每一张在途单据仍有一个不是它当事人的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES3A_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.nea_waste_categories') IS NOT NULL OR to_regclass('public.licence_storage_limits') IS NOT NULL
       OR to_regclass('public.receipt_ceiling_checks') IS NOT NULL THEN
        RAISE EXCEPTION 'MES3A_PRE|MES-3a tables already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                 AND ((table_name = 'inbound_batch_safety_states' AND column_name = 'ended_at')
                      OR (table_name = 'storage_locations' AND column_name = 'is_quarantine'))) THEN
        RAISE EXCEPTION 'MES3A_PRE|MES-3a columns already exist';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES3A_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES3A_PRE|expected 105 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 52 THEN
        RAISE EXCEPTION 'MES3A_PRE|operations_now should have 52 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES3A_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes3a_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes3a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes3a_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes3a_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes3a_states_before ON COMMIT DROP AS
SELECT 'inbound'::text AS k, inbound_batch_id AS b, safety_state_code AS c, created_at, created_by FROM inbound_batch_safety_states
UNION ALL
SELECT 'output', output_batch_id, safety_state_code, created_at, created_by FROM output_batch_safety_states;

-- ── 1 · 触发器函数(镜像原样)—— 表上的触发器要先有它们 ──────────────────────────

-- db/functions/guard_safety_state_rows.sql
-- MES-3a(2026-10-06,MES-0 Q36;MES-3a Step 0 Q22 · Q23,Tim):两张安全状态表(进料批 · 产出批)共用的守卫。
--   ① 删除 / 清空一律拒,属主路径也拒:SAFETY_STATE_NEVER_DELETED|<表>。状态被【结束】,不被删(批次本身不能硬删,
--      所以 ON DELETE CASCADE 走不到这里)。
--   ② 直连写(row_security_active = 真:从一个会话直接 INSERT / UPDATE)按名拒:SAFETY_STATES_THROUGH_FUNCTION_ONLY|<表>|<操作>。
--      写只经 set_inbound_safety_states · set_output_safety_states · 两支收货函数 · 加工的提交与回滚(都是 SECURITY DEFINER)。
--      语句级那一支管"零行的 UPDATE"(没有 UPDATE 策略时它在 RLS 那里是零行,行级触发器不醒 —— SILENT-1 那一族)。
--   ③ 属主路径上的 UPDATE 只许做一件事:把一条【开着的】行结束一次 —— ended_at 填上、理由不空,别的列一格都不动。
--      已经结束的 → SAFETY_STATE_ALREADY_ENDED|<状态>;改了别的列或把 ended_at 改回空 → SAFETY_STATE_ROW_FIXED|<表>;
--      结束没理由 → SAFETY_STATE_END_REASON_REQUIRED|<状态>(表上的 CHECK 是第二道)。
--   【为什么是 INVOKER】row_security_active 必须反映【调用者】的视角(guard_processing_direct_write 同一个理由)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.guard_safety_state_rows()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'SAFETY_STATE_NEVER_DELETED|%', TG_TABLE_NAME;
    END IF;
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'SAFETY_STATES_THROUGH_FUNCTION_ONLY|%|%', TG_TABLE_NAME, lower(TG_OP);
    END IF;
    IF TG_LEVEL = 'STATEMENT' THEN
        RETURN NULL;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.ended_at IS NOT NULL THEN
            RAISE EXCEPTION 'SAFETY_STATE_ALREADY_ENDED|%', OLD.safety_state_code;
        END IF;
        IF NEW.ended_at IS NULL
           OR (to_jsonb(NEW) - ARRAY['ended_at', 'ended_by', 'end_reason', 'ended_by_run_id'])
              IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['ended_at', 'ended_by', 'end_reason', 'ended_by_run_id']) THEN
            RAISE EXCEPTION 'SAFETY_STATE_ROW_FIXED|%', TG_TABLE_NAME;
        END IF;
        IF btrim(COALESCE(NEW.end_reason, '')) = '' THEN
            RAISE EXCEPTION 'SAFETY_STATE_END_REASON_REQUIRED|%', OLD.safety_state_code;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_ceiling_check_append_only.sql
-- MES-3a(2026-10-06,MES-3a Step 0 Q10):receipt_ceiling_checks 只追加 —— 一次判法记下来就不改、不删。
--   UPDATE / DELETE / TRUNCATE 一律语句级拒(没有写策略时 authenticated 的 UPDATE / DELETE 在 RLS 那里是零行,行级触发器不会醒)。
--   STORAGE_CEILING_CHECK_APPEND_ONLY|<操作>。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.guard_ceiling_check_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'STORAGE_CEILING_CHECK_APPEND_ONLY|%', lower(TG_OP);
END;
$function$;

-- db/functions/guard_movement_direct_insert.sql
-- MES-3a(2026-10-06,MES-3a Step 0 Q3,Tim):库存流水【不许从会话里直连插】—— MOVEMENTS_THROUGH_FUNCTION_ONLY。
--   此前 inventory_movements 上有一条 INSERT 策略(module.inventory.edit):一对手搭的 transfer_out / transfer_in 过得了台账
--   不变式,却绕过每一道落闸(货位分类、隔离)。策略已拿掉;这一支让直连插【按名】拒,而不是一句没名字的 RLS 违规。
--   属主路径(row_security_active = 假:SECURITY DEFINER 的收货、转移、暂扣、发货、加工、盘点,以及批次上的触发器)放行。
--   【为什么是 INVOKER】row_security_active 必须反映【调用者】的视角(guard_processing_direct_write 同一个理由)。
--   行级 BEFORE INSERT:RLS 的 WITH CHECK 在 BEFORE 行触发器之后才判,所以这一句先到。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.guard_movement_direct_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'MOVEMENTS_THROUGH_FUNCTION_ONLY|%', NEW.movement_type;
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 2 · NEA 类别字典(镜像原样,从空开始)与物料上的类别列 ───────────────────────────

-- db/tables/nea_waste_categories.sql
-- MES-3a(2026-10-06,MES-0 Q32 · V29;MES-3a Step 0 Q4,Tim):【NEA 批准的废物类别】字典 —— 库存上限按"执照 × 类别"记(吨)。
--   【引导一行都不播,而这是一个决定】类别的名字与编号是 NEA 执照条件里写的,不是这里能编的。
--   今天唯一的分类是 waste_classifications 的 focused / non_focused,而把那两个映射到 NEA 的类别上是"发明,不是建模"
--   (hazardous_qty_on_hand_tonnes 的旧注释原话)—— 所以本表从空开始,"类别列表还没给"在 /settings/pending-values 上是 V29。
--   【为什么不是 waste_classifications 的新行】那张表决定哪个货架收哪类料(storage_location_allowed_classes);
--   一份执照的词汇混进去,改一个类别就会改掉货架的规矩(MES-3a Step 0 Q4)。
--   RUNTIME CONFIG:加一类是加一行(/settings/dictionaries,module.materials.edit),记进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.nea_waste_categories (
    code        text PRIMARY KEY,
    name_en     text NOT NULL,
    name_zh     text NOT NULL,
    is_active   boolean NOT NULL DEFAULT true,
    sort_order  integer NOT NULL DEFAULT 0,
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.nea_waste_categories IS
    'MES-3a:NEA 批准的废物类别(RUNTIME CONFIG,从空开始 —— V29,由 NEA 执照给)。库存上限按执照 × 类别记(licence_storage_limits),物料的类别在 materials.nea_waste_category_code。不是 waste_classifications(那张决定货架收什么)。';

CREATE TRIGGER trg_nea_waste_categories_updated_at
    BEFORE UPDATE ON public.nea_waste_categories
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.nea_waste_categories ENABLE ROW LEVEL SECURITY;
-- 读:要用到它的四个模块(物料主数据、执照、库存、进料 / 产出)—— 不是 USING (true):那 44 条开着的读策略不再加一条(MES-0 Q86)。
CREATE POLICY "nea_waste_categories select by permission"
    ON public.nea_waste_categories AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.materials.view') OR has_permission('module.suppliers.view')
           OR has_permission('module.inventory.view') OR has_permission('module.inbound.view')
           OR has_permission('module.output.view'));
CREATE POLICY "nea_waste_categories write by permission"
    ON public.nea_waste_categories AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.materials.edit'))
    WITH CHECK (has_permission('module.materials.edit'));

REVOKE ALL ON public.nea_waste_categories FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"(与 waste_classifications 同一条)。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.nea_waste_categories
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');

ALTER TABLE public.materials ADD COLUMN nea_waste_category_code text REFERENCES public.nea_waste_categories (code);
COMMENT ON COLUMN public.materials.nea_waste_category_code IS
    'MES-3a(MES-0 Q32 · V29):这个物料属于 NEA 执照上的哪一类废物。库存上限按执照 × 类别判(licence_storage_limits),存量按这一列的【现值】归类。NULL = 没人分过:收货照收,记 category_not_set。不是 waste_classification_code —— 那一列决定货架收什么。';

-- 带 code 列的表要么是单据、要么在例外表里带一句理由(fixture 102 · check-document-registry)。镜像原样。
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
    ('nea_waste_categories',          'NEA 批准的废物类别目录(MES-3a):code 是类别代号,物料与库存上限引用它');

-- ── 3 · 上限与判法两张表(镜像原样)────────────────────────────────────────────

-- db/tables/licence_storage_limits.sql
-- MES-3a(2026-10-06,MES-0 Q32 · V2;MES-3a Step 0 Q5 · Q12,Tim):【一张执照对一类 NEA 废物批准的库存上限】,吨。
--   一行 = 执照 × 类别;同一张执照同一类只有一行(唯一约束)。没有行 = "上限没给"(V2)—— 不是"没有上限":
--   收货照收,并在 receipt_ceiling_checks 记下 ceiling_not_set(Q33)。有行 → 收货时对着那一类的存量判,超了按名拒。
--   执照自己那一行的 approved_storage_limit_tonnes 是总上限(Q6),也照样判。
--   【谁改】执照页 /purchasing/licences,码与执照本身同一个:module.suppliers.edit。历史 = 变更记录(Q12)。
--   【用哪一张执照】收货那一天在效的 gwdf 执照(storage_licence_in_force —— 销毁证书的同一条挑法,Q5)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.licence_storage_limits (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    licence_id    uuid NOT NULL REFERENCES public.company_compliance (id),
    category_code text NOT NULL REFERENCES public.nea_waste_categories (code),
    limit_tonnes  numeric NOT NULL CHECK (limit_tonnes > 0),
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid DEFAULT auth.uid(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid DEFAULT auth.uid(),
    CONSTRAINT licence_storage_limits_one_per_category UNIQUE (licence_id, category_code)
);

COMMENT ON TABLE public.licence_storage_limits IS
    'MES-3a:一张执照对一类 NEA 废物批准的库存上限(吨,V2)。没有行 = 上限没给:收货照收并记 ceiling_not_set;有行 = 收货时超了按名拒 STORAGE_CEILING_EXCEEDED。改在 /purchasing/licences(module.suppliers.edit)。';

CREATE TRIGGER trg_licence_storage_limits_updated_at
    BEFORE UPDATE ON public.licence_storage_limits
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.licence_storage_limits ENABLE ROW LEVEL SECURITY;
-- 与 company_compliance 同一对码:读 module.suppliers.view,写 module.suppliers.edit。
CREATE POLICY "licence_storage_limits select by permission"
    ON public.licence_storage_limits AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'));
CREATE POLICY "licence_storage_limits insert by permission"
    ON public.licence_storage_limits AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.suppliers.edit'));
CREATE POLICY "licence_storage_limits update by permission"
    ON public.licence_storage_limits AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.suppliers.edit'))
    WITH CHECK (has_permission('module.suppliers.edit'));
CREATE POLICY "licence_storage_limits delete by permission"
    ON public.licence_storage_limits AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.suppliers.edit'));

REVOKE ALL ON public.licence_storage_limits FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.licence_storage_limits
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.suppliers.edit');

-- db/tables/receipt_ceiling_checks.sql
-- MES-3a(2026-10-06,MES-0 Q33;MES-3a Step 0 Q7–Q10,Tim):【每一张收货单(与每一批手工建的产出批)进来那一刻,库存上限是怎么判的】。
--   一批一行、只追加。写它的只有 receipt_ceiling_check_internal(两支收货函数与 create_output_batch 在落库后、同一笔事务里调);
--   超过一个【给了的】上限就整笔拒(STORAGE_CEILING_EXCEEDED),于是这里只会留下放行了的那几种:
--     within               —— 这一类的上限给了,而且收进来之后没超(总上限给了的话也没超)
--     ceiling_not_set      —— 这一类的上限没给(Q33:照收,记下来);总上限给了的话照样判过、照样记在 total_* 两列
--     category_not_set     —— 物料没有 NEA 类别(今天每一种物料都是这样:类别列表还是空的,V29)
--     licence_not_in_force —— 收货那一天没有一张在效的 gwdf 执照(没录、没生效、过期、中止,或两张重叠 —— Q5:照收)
--     unit_not_convertible —— 这一批或这一类的存量里有换算不成吨的单位(件 / 别的),而这一类与总量都没有给上限(Q8)
--   on_hand_before_t / total_on_hand_before_t = 这一批进来【之前】的存量(吨,三种库存状态都算,Q7);quantity_t = 这一批。
--   【为什么不是 inbound_batches 上的一列】那张表是遮蔽表(一列 = 加列 + 列授权 + _masked 视图,三件事一支迁移);
--   而且产出批也要同一份记录。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.receipt_ceiling_checks (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbound_batch_id       uuid REFERENCES public.inbound_batches (id),
    output_batch_id        uuid REFERENCES public.output_batches (id),
    licence_id             uuid REFERENCES public.company_compliance (id),
    category_code          text REFERENCES public.nea_waste_categories (code),
    outcome                text NOT NULL CHECK (outcome IN ('within', 'ceiling_not_set', 'category_not_set',
                                                            'licence_not_in_force', 'unit_not_convertible')),
    quantity_t             numeric,
    on_hand_before_t       numeric,
    limit_t                numeric,
    total_on_hand_before_t numeric,
    total_limit_t          numeric,
    checked_on             date NOT NULL,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid DEFAULT auth.uid(),
    CONSTRAINT receipt_ceiling_checks_one_batch CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    CONSTRAINT receipt_ceiling_checks_inbound_once UNIQUE (inbound_batch_id),
    CONSTRAINT receipt_ceiling_checks_output_once UNIQUE (output_batch_id)
);

COMMENT ON TABLE public.receipt_ceiling_checks IS
    'MES-3a:每一张收货单与每一批手工产出批进来时,库存上限的判法(一批一行,只追加)。outcome:within · ceiling_not_set · category_not_set · licence_not_in_force · unit_not_convertible;超过给了的上限的那一次整笔被拒,不留行。数字都是吨,存量是这一批进来之前的。';

-- 【语句级,连 UPDATE 也是】没有 UPDATE / DELETE 策略时,authenticated 的 UPDATE / DELETE 在 RLS 那里是零行,行级触发器不会醒 ——
-- 一次"成功的空操作"(SILENT-1 那一族)。语句级零行也照样触发,属主路径也一样拒(这张表没有任何一条合法的改或删)。
CREATE TRIGGER trg_receipt_ceiling_checks_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.receipt_ceiling_checks
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_ceiling_check_append_only();

ALTER TABLE public.receipt_ceiling_checks ENABLE ROW LEVEL SECURITY;

-- 跟着那一批判:进料行要进料查看码,产出行要产出查看码。没有写策略:只有那支内层函数(属主身份)写。
CREATE POLICY "receipt_ceiling_checks select by permission" ON public.receipt_ceiling_checks
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
            OR (output_batch_id IS NOT NULL AND has_permission('module.output.view'::text))));

REVOKE ALL ON public.receipt_ceiling_checks FROM anon;

-- ── 4 · 隔离库位;安全状态字典的两列(Q14 · Q18)与它们的引导值 ──────────────────────────────
ALTER TABLE public.storage_locations ADD COLUMN is_quarantine boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.storage_locations.is_quarantine IS
    'MES-3a(MES-0 Q34):隔离库位。带着 requires_quarantine 状态的批只能收进 / 移进这里(QUARANTINE_LOCATION_REQUIRED);移进隔离永远准许。线上一个都没标 —— 标一个之前鼓包或漏液的料收不进来(V34)。';
ALTER TABLE public.inbound_safety_states ADD COLUMN dwell_warning_days integer CHECK (dwell_warning_days > 0);
ALTER TABLE public.inbound_safety_states ADD COLUMN requires_quarantine boolean;
COMMENT ON COLUMN public.inbound_safety_states.dwell_warning_days IS
    'MES-3a(MES-0 Q35 · V3):带着这个状态的一批在厂里待多少天就提醒(提醒臂 safety_state_dwell、批次页、/inventory/storage-safety)。NULL = 没给(V3,不提醒)。只提醒,不拒收、不拦投料。时钟 = 那一条状态被记下的时刻,新加坡日历天;只算还有存量的批。';
COMMENT ON COLUMN public.inbound_safety_states.requires_quarantine IS
    'MES-3a(MES-0 Q34 · V4):带着这个状态的一批只能收进 / 移进隔离库位(QUARANTINE_LOCATION_REQUIRED)。引导:swollen_leaking = true(Q34),discharged_verified = false,其余三个 NULL = 没定(V4),当作不要。记下一个状态永远不拒;已经放在别处的会被标出来(提醒臂 quarantine_required)。';
-- 引导(与镜像的 INSERT 逐字同义):鼓包或漏液 = 要隔离(Q34);已放电并核验 = 不要;其余三个留空(V4)。没有一个滞留天数(V3)。
UPDATE public.inbound_safety_states SET requires_quarantine = true  WHERE code = 'swollen_leaking';
UPDATE public.inbound_safety_states SET requires_quarantine = false WHERE code = 'discharged_verified';
COMMENT ON COLUMN public.company_compliance.approved_storage_limit_tonnes IS
    'CMPL-1:执照批准的【贮存上限】,吨。★这是本刀把一个数字从散文里挪出来的那一格★ —— 此前它只能写在自由文本 scope 里,而**一句话不是一个可以判的值**(与 LOG-5a 把 free_time_terms 换成 free_days 逐字同一件事)。**NULL 不表示"没有上限",表示"没有人录过上限"**。★ MES-3a(2026-10-06,MES-3a Step 0 Q6 · Q11,Tim):它是这张执照的【总上限】—— 收货时对着【所有有 NEA 类别的存量】之和判,超了按名拒(STORAGE_CEILING_EXCEEDED);每一类的上限在 licence_storage_limits。NULL 时不判总量、照收(Q33:记下来,不拦);licence_storage_within_limit()(读到 NULL 就拒绝作判断)已删 —— 它与 Q33 相反,且从没有调用方。';
COMMENT ON COLUMN public.ingest_settings.require_calibrated_since IS
    'MES-2(Q26)· MES-3a(Tim 的裁定 1,2026-10-06):校准规则的开关 —— 一个日期,空 = 关。【读数的仪器不在校准期内】(READING_INSTRUMENT_NOT_CALIBRATED)不看开关:定价、试算与销毁证书永远拒。开关只管两种缺席,而且只管【这一天及以后建的】收货单:读数没有记录仪器(READING_INSTRUMENT_NOT_RECORDED)、收货单没有挂任何一次称重(RECEIPT_READING_NOT_RECORDED)。关着时这两种只在页面上标出来。线上保持空。';

-- ── 5 · 两张安全状态表:有历史(Q22)—— 主键换成 id,开着的只有一条,只经函数写,只结束一次,永不删 ──────────

DROP TRIGGER enforce_write_permission ON public.inbound_batch_safety_states;
DROP POLICY "inbound_batch_safety_states insert by permission" ON public.inbound_batch_safety_states;
DROP POLICY "inbound_batch_safety_states delete by permission" ON public.inbound_batch_safety_states;
ALTER TABLE public.inbound_batch_safety_states DROP CONSTRAINT inbound_batch_safety_states_pkey;
ALTER TABLE public.inbound_batch_safety_states ADD COLUMN id uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE public.inbound_batch_safety_states ADD COLUMN created_by_run_id uuid REFERENCES public.processing_runs (id);
ALTER TABLE public.inbound_batch_safety_states ADD COLUMN ended_at timestamptz;
ALTER TABLE public.inbound_batch_safety_states ADD COLUMN ended_by uuid;
ALTER TABLE public.inbound_batch_safety_states ADD COLUMN end_reason text;
ALTER TABLE public.inbound_batch_safety_states ADD COLUMN ended_by_run_id uuid REFERENCES public.processing_runs (id);
ALTER TABLE public.inbound_batch_safety_states ADD COLUMN reopened_from_id uuid;
ALTER TABLE public.inbound_batch_safety_states ADD CONSTRAINT inbound_batch_safety_states_pkey PRIMARY KEY (id);
ALTER TABLE public.inbound_batch_safety_states ADD CONSTRAINT inbound_batch_safety_states_reopened_from_fkey
    FOREIGN KEY (reopened_from_id) REFERENCES public.inbound_batch_safety_states (id);
ALTER TABLE public.inbound_batch_safety_states ADD CONSTRAINT inbound_batch_safety_states_end_shape
    CHECK ((ended_at IS NULL AND ended_by IS NULL AND end_reason IS NULL AND ended_by_run_id IS NULL)
           OR (ended_at IS NOT NULL AND end_reason IS NOT NULL AND btrim(end_reason) <> ''));
CREATE UNIQUE INDEX inbound_batch_safety_states_open_once
    ON public.inbound_batch_safety_states (inbound_batch_id, safety_state_code) WHERE ended_at IS NULL;
CREATE TRIGGER trg_inbound_safety_states_rows
    BEFORE INSERT OR UPDATE ON public.inbound_batch_safety_states
    FOR EACH ROW EXECUTE FUNCTION public.guard_safety_state_rows();
CREATE TRIGGER trg_inbound_safety_states_statement
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.inbound_batch_safety_states
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_safety_state_rows();
DROP TRIGGER zzz_change_log ON public.inbound_batch_safety_states;
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.inbound_batch_safety_states
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
COMMENT ON TABLE public.inbound_batch_safety_states IS
'PROC-2:一批料【身上的安全状态】,一行一个。**多值,而且这是它单独成表的全部理由** ——
一批料可以同时是「进过水」与「破损」,而一个单值的列表达不了它。

【开着的 (批次, 状态) 只有一条】(MES-3a 起:部分唯一索引 inbound_batch_safety_states_open_once;此前是主键)。
重复不是"更确定",它只会让任何按状态计数的读法开始骗人。
【有历史】(MES-3a,MES-0 Q36):一条状态被结束(ended_at · ended_by · end_reason,加工解决的还有 ended_by_run_id),不被删掉;
读"现在身上有什么"的地方一律带 ended_at IS NULL。加工写上的那一条记 created_by_run_id,回滚据此把它结束、
并把它结束掉的那几条重新开出来(reopened_from_id 指回原行,记录时刻照抄原行 —— 滞留时钟不因回滚重来)。

【没有安全状态行 = 没有人记过,【不是】"安全"】这与本仓库反复付账的那个区别
是同一个(METAL-1 的 no_reference、SS-1 的阈值为 NULL、PROC-1 的 may_be_processed)。
读它的屏幕与 PROC-3 那道闸都必须把"一条都没有"按名说出来,而不是当成通过。';

DROP TRIGGER enforce_write_permission ON public.output_batch_safety_states;
DROP POLICY "output_batch_safety_states insert by permission" ON public.output_batch_safety_states;
DROP POLICY "output_batch_safety_states delete by permission" ON public.output_batch_safety_states;
ALTER TABLE public.output_batch_safety_states DROP CONSTRAINT output_batch_safety_states_pkey;
ALTER TABLE public.output_batch_safety_states ADD COLUMN id uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE public.output_batch_safety_states ADD COLUMN created_by_run_id uuid REFERENCES public.processing_runs (id);
ALTER TABLE public.output_batch_safety_states ADD COLUMN ended_at timestamptz;
ALTER TABLE public.output_batch_safety_states ADD COLUMN ended_by uuid;
ALTER TABLE public.output_batch_safety_states ADD COLUMN end_reason text;
ALTER TABLE public.output_batch_safety_states ADD COLUMN ended_by_run_id uuid REFERENCES public.processing_runs (id);
ALTER TABLE public.output_batch_safety_states ADD COLUMN reopened_from_id uuid;
ALTER TABLE public.output_batch_safety_states ADD CONSTRAINT output_batch_safety_states_pkey PRIMARY KEY (id);
ALTER TABLE public.output_batch_safety_states ADD CONSTRAINT output_batch_safety_states_reopened_from_fkey
    FOREIGN KEY (reopened_from_id) REFERENCES public.output_batch_safety_states (id);
ALTER TABLE public.output_batch_safety_states ADD CONSTRAINT output_batch_safety_states_end_shape
    CHECK ((ended_at IS NULL AND ended_by IS NULL AND end_reason IS NULL AND ended_by_run_id IS NULL)
           OR (ended_at IS NOT NULL AND end_reason IS NOT NULL AND btrim(end_reason) <> ''));
CREATE UNIQUE INDEX output_batch_safety_states_open_once
    ON public.output_batch_safety_states (output_batch_id, safety_state_code) WHERE ended_at IS NULL;
CREATE TRIGGER trg_output_safety_states_rows
    BEFORE INSERT OR UPDATE ON public.output_batch_safety_states
    FOR EACH ROW EXECUTE FUNCTION public.guard_safety_state_rows();
CREATE TRIGGER trg_output_safety_states_statement
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.output_batch_safety_states
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_safety_state_rows();
DROP TRIGGER zzz_change_log ON public.output_batch_safety_states;
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.output_batch_safety_states
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
COMMENT ON TABLE public.output_batch_safety_states IS
'PROC-WIRE-1B-ii(R1 / M4):一批【产出】料身上的安全状态,一行一个。多值。

★【它存在的理由:那处不对称是"问不了",不是"不需要问"】★
guard_processing_input 里 PROC-3 那一段过去只问 inbound_batch_id ——
于是【买进来的】极片要过火闸,而【自己产的】极片连问都问不到。
Tim 的 R1:**抬高产出这一侧,绝不放低进料那一侧。** 这张表就是那个抬高。

【为什么是平行表,而不是把 inbound_batch_safety_states 改成 XOR】
仓库里两个先例指向两个方向:processing_inputs 走 XOR,
inbound_batch_metals / output_batch_metals 走平行表。
**更近的是金属那一对** —— 一个逐批的实测事实,两种出处。
改老表要动一个带主键、带触发器、有线上行的结构,买到的只是少一条分支。
**照抄一个先例之前要问那个先例成立的条件在这里成不成立。**

★【没有安全状态行 = 没有人记过,【不是】"安全"】★ 与进料侧【同一个意思】——
**这正是它必须与那边一致的地方**:同一种"空"在两张表里若有相反的意思,
就是本仓库反复付账的那一族(METAL-1 的 no_reference、SS-1 的阈值 NULL、
PROC-1 的 may_be_processed)。缺席 → PRODUCED_SAFETY_STATE_NOT_RECORDED。

★【回填:一行都没有写,而这是一个【决定】】★ 线上 20 批产出全是测试残留,
产线一天没开过。给它们写上一个状态等于**记下一次没有人做过的核验** ——
一条假记录,与把 ZZ-PROCCOST1-DEMO 注销掉是同一种错。
所以:**不回填,而缺席拦人。** 代价量过:线上 14 批活着的产出批一批都没记过,
于是此后再投料它们中的任何一批都会被拦,直到有人去记 ——
**今天代价为零(产线没开),而那正是这道火闸要的那个动作。**';

-- ── 6 · 库存流水的直连插入关上(Q3)────────────────────────────────────────────
DROP POLICY "inventory_movements insert by permission" ON public.inventory_movements;
CREATE TRIGGER trg_inventory_movements_through_function
    BEFORE INSERT ON public.inventory_movements
    FOR EACH ROW EXECUTE FUNCTION public.guard_movement_direct_insert();

-- ── 7 · 新函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/quantity_in_tonnes.sql
-- MES-3a(2026-10-06,MES-3a Step 0 Q8,Tim):一个数量连同它的单位,换成吨 —— 库存上限的唯一一份换算。
--   kg → ÷1000 · 吨 / t → ×1 · 克 / g → ÷1,000,000;件,或任何别的(包括空)→ NULL = 换算不成。
--   【不猜】一"件"有多重,这里不知道,也不该编一个数(allocate_processing_costs 的 UNIT_NOT_KG 同一条);
--   调用方拿到 NULL 时:这一类或总量给了上限 → 按名拒(STORAGE_CEILING_UNIT_NOT_CONVERTIBLE),没给 → 记 unit_not_convertible。
--   纯函数(IMMUTABLE,不读表),所以属主视图里调它不撞读者的 RLS。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.quantity_in_tonnes(p_qty numeric, p_unit text)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE lower(btrim(COALESCE(p_unit, '')))
               WHEN 'kg' THEN p_qty / 1000
               WHEN 't' THEN p_qty
               WHEN '吨' THEN p_qty
               WHEN 'g' THEN p_qty / 1000000
               WHEN '克' THEN p_qty / 1000000
           END;
$function$;

-- db/functions/storage_licence_in_force.sql
-- MES-3a(2026-10-06,MES-0 Q32;MES-3a Step 0 Q5,Tim):【那一天,库存上限按哪一张执照判】—— 销毁证书的同一条挑法
--   (cod_governing_licence):gwdf、没软删、号不空、status = active、两个日期都在、那一天落在 valid_from … valid_until 里。
--   恰好一张 → 它的 id;一张都没有,或两张重叠 → NULL(收货照收,记 licence_not_in_force —— Q5;一张过期的公司执照今天
--   不拦收货,在这里开始拦就是一条没人要的新规矩)。【重叠时不挑】—— 挑就是替录错的人做主(cod_governing_licence 的原话)。
--   SECURITY DEFINER:读 company_compliance 不过 RLS,只回一个 id;属主视图(storage_ceiling_status、提醒臂)以读者身份调它。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.storage_licence_in_force(p_on date)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN count(*) = 1 THEN (array_agg(cc.id))[1] END
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
       AND cc.status = 'active'
       AND cc.valid_from IS NOT NULL AND cc.valid_until IS NOT NULL
       AND p_on BETWEEN cc.valid_from AND cc.valid_until;
$function$;

-- db/functions/assert_quarantine_landing.sql
-- MES-3a(2026-10-06,MES-0 Q34;MES-3a Step 0 Q19,Tim):【带着要隔离的状态,就只能落进隔离库位】。
--   p_states:这一批身上的状态(收货:请求里的 p_safety_states;转移:这一批【开着的】状态)。其中任何一个
--   requires_quarantine = true(引导:swollen_leaking),而落点不是一个【在用的】隔离库位 →
--   QUARANTINE_LOCATION_REQUIRED|<状态>|<库位编号,或 unspecified>。【未指定库位不是隔离】。
--   requires_quarantine 为 NULL(没定,V4)当作不要 —— 一个没人给过的规矩不拦人。
--   调用方:create_inbound_batch · receive_inbound_batch_against_po(写入之前)· create_stock_transfer(入腿)。
--   【记下一个状态永远不经过这里】—— 一个危险必须永远记得下来;已经放在别处的,由提醒臂 quarantine_required 标出来(Q20)。
--   内层:不是 SECURITY DEFINER,EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.assert_quarantine_landing(p_states text[], p_location_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_state text;
BEGIN
    SELECT s.code INTO v_state
      FROM inbound_safety_states s
     WHERE s.code = ANY (COALESCE(p_states, ARRAY[]::text[])) AND s.requires_quarantine IS TRUE
     ORDER BY s.sort_order, s.code
     LIMIT 1;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    IF p_location_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM storage_locations l WHERE l.id = p_location_id AND l.is_active AND l.is_quarantine) THEN
        RETURN;
    END IF;
    RAISE EXCEPTION 'QUARANTINE_LOCATION_REQUIRED|%|%', v_state,
        COALESCE((SELECT l.code FROM storage_locations l WHERE l.id = p_location_id), 'unspecified');
END;
$function$;

-- db/functions/receipt_ceiling_check_internal.sql
-- MES-3a(2026-10-06,MES-0 Q32 · Q33;MES-3a Step 0 Q5–Q10,Tim):【一批进厂的料,对着执照的库存上限判一次,并且记下来】。
--   调用方:create_inbound_batch · receive_inbound_batch_against_po · create_output_batch —— 在批次落库【之后】、同一笔事务里
--   (于是这一批自己的入库流水已经在存量里;拒绝即整笔回滚,什么都没发生)。处理、回滚、盘点、转移不调它(Q9):
--   它们不是从外面进料,超了由提醒臂 storage_ceiling_exceeded 说出来(Q13)。
--   ① 执照:收货那一天在效的 gwdf(storage_licence_in_force,Q5)。没有 → licence_not_in_force,照收。
--   ② 类别:物料的 nea_waste_category_code。没有 → category_not_set,照收(今天每一种物料都是这样,V29)。
--   ③ 锁:那一张执照行,与这一类的上限行(FOR UPDATE)—— 两张并发的收货不可能都"刚好没超":后到的那一笔等前一笔提交,
--      再按提交后的存量判(READ COMMITTED,每一句一个新快照)。锁在读存量【之前】。
--   ④ 吨:这一批与这一类(以及总量)的存量换成吨(quantity_in_tonnes)。换不成 → 这一类或总量给了上限就按名拒
--      STORAGE_CEILING_UNIT_NOT_CONVERTIBLE|<批号>|<类别或 *>,没给就记 unit_not_convertible(Q8)。
--   ⑤ 判:这一类给了上限而收进来之后超了 → STORAGE_CEILING_EXCEEDED|<执照号>|<类别>|<之前 t>|<这一批 t>|<上限 t>;
--      执照的总上限(approved_storage_limit_tonnes,所有有类别的存量之和)给了而超了 → 同一个码,类别写 *(Q6)。
--   ⑥ 记:within(这一类给了上限、没超)· ceiling_not_set(这一类没给 —— Q33:照收,记下来;总量给了的照样判过、记在 total_*)。
--   返回写下的那一行(jsonb)。内层:不是 SECURITY DEFINER、没有调用者检查,EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.receipt_ceiling_check_internal(p_inbound_batch_id uuid, p_output_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_material uuid;
    v_qty      numeric;
    v_unit     text;
    v_on       date;
    v_code     text;
    v_lic      uuid;
    v_lic_no   text;
    v_cat      text;
    v_qt       numeric;
    v_lim      numeric;
    v_tot_lim  numeric;
    v_cat_t    numeric;
    v_cat_bad  bigint;
    v_tot_t    numeric;
    v_tot_bad  bigint;
    v_outcome  text;
    v_row      receipt_ceiling_checks%ROWTYPE;
BEGIN
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'STORAGE_CEILING_ONE_BATCH';
    END IF;
    IF p_inbound_batch_id IS NOT NULL THEN
        SELECT b.material_id, b.quantity, b.unit, b.arrival_date, b.code INTO v_material, v_qty, v_unit, v_on, v_code
          FROM inbound_batches b WHERE b.id = p_inbound_batch_id;
    ELSE
        SELECT b.material_id, b.quantity, b.unit, b.output_date, b.code INTO v_material, v_qty, v_unit, v_on, v_code
          FROM output_batches b WHERE b.id = p_output_batch_id;
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STORAGE_CEILING_BATCH_NOT_FOUND|%', COALESCE(p_inbound_batch_id, p_output_batch_id);
    END IF;
    v_on := COALESCE(v_on, (now() AT TIME ZONE 'Asia/Singapore')::date);
    v_qt := quantity_in_tonnes(v_qty, v_unit);

    v_lic := storage_licence_in_force(v_on);
    IF v_lic IS NULL THEN
        v_outcome := 'licence_not_in_force';
    ELSE
        SELECT m.nea_waste_category_code INTO v_cat FROM materials m WHERE m.id = v_material;
        IF v_cat IS NULL THEN
            v_outcome := 'category_not_set';
        END IF;
    END IF;

    IF v_outcome IS NULL THEN
        -- ③ 锁在读存量之前
        SELECT cc.cert_no, cc.approved_storage_limit_tonnes INTO v_lic_no, v_tot_lim
          FROM company_compliance cc WHERE cc.id = v_lic FOR UPDATE;
        SELECT l.limit_tonnes INTO v_lim
          FROM licence_storage_limits l WHERE l.licence_id = v_lic AND l.category_code = v_cat FOR UPDATE;

        SELECT a.tonnes, a.unconvertible_batches INTO v_cat_t, v_cat_bad
          FROM nea_category_on_hand_all a WHERE a.category_code = v_cat;
        SELECT sum(a.tonnes), sum(a.unconvertible_batches) INTO v_tot_t, v_tot_bad FROM nea_category_on_hand_all a;

        -- ④ 换算不成吨
        IF v_qt IS NULL OR COALESCE(v_cat_bad, 0) > 0 THEN
            IF v_lim IS NOT NULL THEN
                RAISE EXCEPTION 'STORAGE_CEILING_UNIT_NOT_CONVERTIBLE|%|%', v_code, v_cat;
            END IF;
            v_outcome := 'unit_not_convertible';
        END IF;
        IF v_tot_lim IS NOT NULL AND (v_qt IS NULL OR COALESCE(v_tot_bad, 0) > 0) THEN
            RAISE EXCEPTION 'STORAGE_CEILING_UNIT_NOT_CONVERTIBLE|%|*', v_code;
        END IF;

        IF v_outcome IS NULL THEN
            -- ⑤ 判(存量里已经有这一批)
            IF v_lim IS NOT NULL AND v_cat_t > v_lim THEN
                RAISE EXCEPTION 'STORAGE_CEILING_EXCEEDED|%|%|%|%|%', v_lic_no, v_cat,
                    round(v_cat_t - v_qt, 3), round(v_qt, 3), v_lim;
            END IF;
            IF v_tot_lim IS NOT NULL AND v_tot_t > v_tot_lim THEN
                RAISE EXCEPTION 'STORAGE_CEILING_EXCEEDED|%|*|%|%|%', v_lic_no,
                    round(v_tot_t - v_qt, 3), round(v_qt, 3), v_tot_lim;
            END IF;
            v_outcome := CASE WHEN v_lim IS NULL THEN 'ceiling_not_set' ELSE 'within' END;
        END IF;
    END IF;

    INSERT INTO receipt_ceiling_checks (inbound_batch_id, output_batch_id, licence_id, category_code, outcome, quantity_t,
                                        on_hand_before_t, limit_t, total_on_hand_before_t, total_limit_t, checked_on)
    VALUES (p_inbound_batch_id, p_output_batch_id, v_lic, v_cat, v_outcome, v_qt,
            CASE WHEN v_outcome IN ('within', 'ceiling_not_set') THEN COALESCE(v_cat_t, 0) - v_qt END,
            v_lim,
            CASE WHEN v_outcome IN ('within', 'ceiling_not_set') AND COALESCE(v_tot_bad, 0) = 0 THEN COALESCE(v_tot_t, 0) - v_qt END,
            v_tot_lim, v_on)
    RETURNING * INTO v_row;
    RETURN to_jsonb(v_row);
END;
$function$;

-- db/functions/set_output_safety_states.sql
-- MES-3a(2026-10-06,MES-0 Q36;MES-3a Step 0 Q22 · Q23,Tim):一批【产出】料的安全状态 —— 与 set_inbound_safety_states 逐字同形:
--   只加新勾上的、只结束拿掉的(结束要理由,空 → SAFETY_STATE_END_REASON_REQUIRED|<状态>),没变的一个字节都不动。
--   此前产出批页面从浏览器直连插 / 删这张表(删 = 硬删,没有理由、没有墓碑,SafetyStatePanel 自己的注释这么说);
--   那两条写策略已拿掉,写只经这里(module.output.edit)与加工的提交 / 回滚。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.set_output_safety_states(p_output_batch_id uuid, p_codes text[], p_end_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n      int;
    v_codes  text[] := COALESCE(p_codes, ARRAY[]::text[]);
    v_ending text;
BEGIN
    PERFORM require_permission('module.output.edit');

    IF p_output_batch_id IS NULL THEN
        RAISE EXCEPTION 'SAFETY_STATES_BATCH_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM output_batches WHERE id = p_output_batch_id) THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;

    SELECT string_agg(s.safety_state_code, ',' ORDER BY s.safety_state_code) INTO v_ending
      FROM output_batch_safety_states s
     WHERE s.output_batch_id = p_output_batch_id AND s.ended_at IS NULL
       AND NOT (s.safety_state_code = ANY (v_codes));
    IF v_ending IS NOT NULL AND btrim(COALESCE(p_end_reason, '')) = '' THEN
        RAISE EXCEPTION 'SAFETY_STATE_END_REASON_REQUIRED|%', v_ending;
    END IF;

    UPDATE output_batch_safety_states s
       SET ended_at = now(), ended_by = auth.uid(), end_reason = btrim(p_end_reason)
     WHERE s.output_batch_id = p_output_batch_id AND s.ended_at IS NULL
       AND NOT (s.safety_state_code = ANY (v_codes));

    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code)
    SELECT p_output_batch_id, c FROM unnest(v_codes) c
     WHERE NOT EXISTS (SELECT 1 FROM output_batch_safety_states s
                        WHERE s.output_batch_id = p_output_batch_id AND s.ended_at IS NULL
                          AND s.safety_state_code = c);

    SELECT count(*) INTO v_n FROM output_batch_safety_states
     WHERE output_batch_id = p_output_batch_id AND ended_at IS NULL;
    RETURN jsonb_build_object('output_batch_id', p_output_batch_id, 'count', v_n);
END;
$function$;

-- ── 8 · 改过的函数(镜像原样,同签名);投料闸住在 processing_inputs 的表镜像里 ────────────────

-- db/functions/create_inbound_batch.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q19,Tim):末尾多三个参数(p_ticket_id · p_ticket_share_kg · p_quantity_reason),都带默认值 ——
--   签名变了,所以迁移是 DROP + CREATE(preflight 不许 CREATE OR REPLACE 换签名);已部署的旧应用不传它们,照样解析到这一支。
-- MES-3a(2026-10-06,MES-3a Step 0 Q9 · Q10 · Q19,Tim):写入之前过隔离闸(请求里带着要隔离的状态,就只能收进隔离库位);
--   落库之后对着执照的库存上限判一次并记下来(receipt_ceiling_check_internal)。签名不变;返回值多一个 'ceiling'(那一行)。

CREATE OR REPLACE FUNCTION public.create_inbound_batch(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date, p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text, p_currency text DEFAULT NULL::text, p_ticket_id uuid DEFAULT NULL::uuid, p_ticket_share_kg numeric DEFAULT NULL::numeric, p_quantity_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ceiling jsonb;
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

    -- MES-3a(2026-10-06,MES-0 Q34;MES-3a Step 0 Q19,Tim):带着要隔离的状态(鼓包或漏液)只能收进一个在用的隔离库位 ——
    --   读的是【请求里】的状态(状态在落库之后才写,所以不能等它们),写入之前按名拒 QUARANTINE_LOCATION_REQUIRED。
    PERFORM assert_quarantine_landing(p_safety_states, p_location_id);

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

    -- MES-3a(2026-10-06,MES-0 Q32 · Q33;MES-3a Step 0 Q5–Q10,Tim):对着执照的库存上限判一次,并且【每一张都记下来】
    --   (receipt_ceiling_checks)。在落库之后判 —— 这一批的入库流水已经在存量里;超过一个给了的上限就按名拒
    --   STORAGE_CEILING_EXCEEDED,整笔回滚。没给上限 / 没有类别 / 没有在效执照:照收,记下是哪一种。
    v_ceiling := receipt_ceiling_check_internal(v_id, NULL);

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
                              'pricing', v_pricing, 'ceiling', v_ceiling);
END;
$function$

;

-- db/functions/receive_inbound_batch_against_po.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q19,Tim):末尾多三个参数(p_ticket_id · p_ticket_share_kg · p_quantity_reason),都带默认值 ——
--   签名变了,迁移是 DROP + CREATE;已部署的旧应用不传它们,照样解析到这一支。
-- MES-3a(2026-10-06,MES-3a Step 0 Q9 · Q10 · Q19,Tim):写入之前过隔离闸(请求里带着要隔离的状态,就只能收进隔离库位);
--   落库之后对着执照的库存上限判一次并记下来(receipt_ceiling_check_internal)。签名不变;返回值多一个 'ceiling'(那一行)。

CREATE OR REPLACE FUNCTION public.receive_inbound_batch_against_po(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_arrival_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text, p_ticket_id uuid DEFAULT NULL::uuid, p_ticket_share_kg numeric DEFAULT NULL::numeric, p_quantity_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ceiling jsonb;
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

    -- MES-3a(2026-10-06,MES-0 Q34;MES-3a Step 0 Q19,Tim):带着要隔离的状态(鼓包或漏液)只能收进一个在用的隔离库位 ——
    --   读的是【请求里】的状态(状态在落库之后才写,所以不能等它们),写入之前按名拒 QUARANTINE_LOCATION_REQUIRED。
    PERFORM assert_quarantine_landing(p_safety_states, p_location_id);

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

    -- MES-3a(2026-10-06,MES-0 Q32 · Q33;MES-3a Step 0 Q5–Q10,Tim):对着执照的库存上限判一次,并且【每一张都记下来】
    --   (receipt_ceiling_checks)。在落库之后判 —— 这一批的入库流水已经在存量里;超过一个给了的上限就按名拒
    --   STORAGE_CEILING_EXCEEDED,整笔回滚。没给上限 / 没有类别 / 没有在效执照:照收,记下是哪一种。
    v_ceiling := receipt_ceiling_check_internal(v_id, NULL);
    IF p_ticket_id IS NOT NULL THEN
        PERFORM weighbridge_share_internal(p_ticket_id, v_id, NULL, p_ticket_share_kg,
                                           CASE WHEN p_quantity IS DISTINCT FROM p_ticket_share_kg THEN p_quantity_reason END);
    END IF;
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn), 'ceiling', v_ceiling);
END;
$function$

;

-- db/functions/create_output_batch.sql
-- MES-3a(2026-10-06,MES-3a Step 0 Q9 · Q10,Tim):手工建一批产出 = 料从外面进厂(加工出来的产出批不走这里)——
--   落库之后对着执照的库存上限判一次并记下来(receipt_ceiling_check_internal),超过给了的上限按名拒。
--   隔离闸不在这里:产出批建出来时身上没有状态(状态在产出批页面上记)。签名不变;返回值多一个 'ceiling'。

CREATE OR REPLACE FUNCTION public.create_output_batch(p_material_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_output_date date DEFAULT NULL::date, p_state text DEFAULT '库存中'::text, p_customer_id uuid DEFAULT NULL::uuid, p_purity text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
    v_ceiling jsonb;
BEGIN
    PERFORM require_permission('module.output.edit');

    -- IOD-2-fu1:产出日【按名】必填 —— 手走就是在这一条上看见了约束原文。
    IF p_output_date IS NULL THEN
        RAISE EXCEPTION 'OUTPUT_DATE_REQUIRED';
    END IF;

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸,写入之前。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    INSERT INTO output_batches (
        material_id, customer_id, quantity, unit, remaining_qty, output_date,
        state, purity, notes, created_by, updated_by)
    VALUES (
        p_material_id, p_customer_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_output_date,
        COALESCE(p_state,'库存中'), p_purity, p_notes, v_user, v_user)
    RETURNING id INTO v_id;

    PERFORM set_config('evoltrya.location_ctx', '', true);

    -- MES-3a:库存上限(见文件抬头)。落库之后判 —— 这一批的入库流水已经在存量里。
    v_ceiling := receipt_ceiling_check_internal(NULL, v_id);
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn), 'ceiling', v_ceiling);
END;
$function$

;

-- db/functions/create_stock_transfer.sql
-- MES-3a(2026-10-06,MES-0 Q34;MES-3a Step 0 Q19 · Q20,Tim):一批身上开着一个要隔离的状态(鼓包或漏液),
--   它的下一次移动只能进一个在用的隔离库位 —— 入腿过 assert_quarantine_landing,拒绝 QUARANTINE_LOCATION_REQUIRED。
--   移进隔离永远准许;从隔离移到另一个隔离也准许。签名不变。

CREATE OR REPLACE FUNCTION public.create_stock_transfer(p_qty numeric, p_to_location_id uuid, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_from_location_id uuid DEFAULT NULL::uuid, p_stock_status text DEFAULT 'available'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_pair     uuid := gen_random_uuid();
    v_have     numeric;
    v_today    date := CURRENT_DATE;
    v_material uuid;
    v_warn     text[];
    v_reserved numeric;
BEGIN
    PERFORM require_permission('module.inventory.edit');

    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'STK_ONE_BATCH';
    END IF;
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'STK_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;
    -- SO-2:【一个坏状态不是一个坏数量】。此前这里抛的是 STK_QTY_INVALID,
    -- 于是"你传了一个系统不认识的库存状态"会在屏幕上显示成"数量无效" ——
    -- 一条把人送去看错地方的消息。三个桶都在这里列出来。
    IF p_stock_status IS NULL OR p_stock_status NOT IN ('available','on_hold','committed') THEN
        RAISE EXCEPTION 'IOD_TRANSFER_STATUS_INVALID|%', COALESCE(p_stock_status, '?');
    END IF;
    -- 【源与目的相同】不是一次无害的空操作:它会写下两行互相抵消的流水,
    -- 把台账弄脏,而且几乎总是意味着操作的人选错了一边。
    IF p_from_location_id IS NOT DISTINCT FROM p_to_location_id THEN
        RAISE EXCEPTION 'IOD_TRANSFER_SAME_LOCATION';
    END IF;
    -- 目的地必须是一个【在用】的库位。停用的库位不该再收货(LOC-1 的停用语义)。
    IF p_to_location_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = p_to_location_id AND is_active) THEN
        RAISE EXCEPTION 'IOD_TRANSFER_TO_INACTIVE|%', COALESCE(p_to_location_id::text, '?');
    END IF;

    -- 【同一粒度】对着派生桶比,与 STK-1 的暂扣/释放一模一样:
    -- remaining_qty 没有库位轴,在这个粒度上现算是唯一可能的来源。
    v_have := derived_stock_qty(p_inbound_batch_id, p_output_batch_id, p_from_location_id, p_stock_status);
    IF p_qty > v_have THEN
        RAISE EXCEPTION 'IOD_TRANSFER_EXCEEDS_BUCKET|%|%', p_qty, v_have;
    END IF;

    -- IOD-2:落闸,【只在入腿上】。物料从批次反查 —— 两种批次二选一(上面的
    -- XOR 已经保证恰好一个非空),两张表都有 material_id NOT NULL。
    -- 【出腿一个字都不查】:分类管的是货可以待在哪里,不是货能不能离开;拦住
    -- 一批放错地方的货【离开】,只会把它焊死在错的地方。
    v_material := COALESCE(
        (SELECT material_id FROM inbound_batches WHERE id = p_inbound_batch_id),
        (SELECT material_id FROM output_batches  WHERE id = p_output_batch_id));
    v_warn := check_location_class(p_to_location_id, v_material);
    -- NTF-1:告警留一份下来(入腿的库位/物料)。返回值那一份不变。
    PERFORM notify_landing_warnings(v_warn, p_to_location_id, v_material);

    -- MES-3a(Q19 · Q20):这一批身上【开着的】状态里有要隔离的 → 入腿只能是在用的隔离库位。出腿不查(与分类同一条:
    --   拦住一批放错地方的货【离开】,只会把它焊死在错的地方)。
    PERFORM assert_quarantine_landing(
        CASE WHEN p_inbound_batch_id IS NOT NULL
             THEN ARRAY(SELECT s.safety_state_code FROM inbound_batch_safety_states s
                         WHERE s.inbound_batch_id = p_inbound_batch_id AND s.ended_at IS NULL)
             ELSE ARRAY(SELECT s.safety_state_code FROM output_batch_safety_states s
                         WHERE s.output_batch_id = p_output_batch_id AND s.ended_at IS NULL)
        END,
        p_to_location_id);

    -- 成对:出源库位、进目的库位。【状态原样带过去】—— 转移搬的是位置,
    -- 不是状态;一批被扣住的货换个货架仍然是被扣住的。
    INSERT INTO inventory_movements
        (inbound_batch_id, output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_inbound_batch_id, p_output_batch_id, p_from_location_id, 'transfer_out',
         -p_qty, p_stock_status, v_pair, v_today, NULLIF(btrim(COALESCE(p_note,'')),''), v_user),
        (p_inbound_batch_id, p_output_batch_id, p_to_location_id, 'transfer_in',
          p_qty, p_stock_status, v_pair, v_today, NULLIF(btrim(COALESCE(p_note,'')),''), v_user);

    -- ════════════════════════════════════════════════════════════════════════
    -- SO-2:【committed 的货搬走了,预留行必须跟着走 —— 而且只允许整桶搬】
    --
    -- 预留行记的是 批次 × 库位 这个桶。桶里的货搬到别的库位,而预留行还写着
    -- 老库位,那两句话当场对不上:流水说这 40kg 在 B,预留说它在 A。
    --
    -- 【为什么只允许整桶】部分搬走就得回答"这 40 里哪 15 跟着走" —— 而预留行
    -- 是按订单行分的,没有任何东西能回答那个问题;系统替人挑一行,就是编造。
    -- 所以:整桶搬,预留行的 location_id 跟着改(那是"这批货现在放在哪",不是
    -- "当初许了什么");搬不完就点名拒绝,补救写在消息里 —— 先部分释放,
    -- 再搬,再重新预留。三步各自留下自己的痕迹。
    --
    -- 【改 location_id 是本表唯一允许的事后改写】,由 evoltrya.reservation_move_ctx
    -- 向守卫说明"这是转移在改",而不是让守卫对任何 UPDATE 都放行一列。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_stock_status = 'committed' THEN
        SELECT COALESCE(sum(r.qty), 0) INTO v_reserved
          FROM sales_order_reservations r
         WHERE r.output_batch_id IS NOT DISTINCT FROM p_output_batch_id
           AND r.location_id IS NOT DISTINCT FROM p_from_location_id
           AND r.released_at IS NULL AND r.consumed_at IS NULL;

        IF v_reserved > 0 AND p_qty <> v_reserved THEN
            RAISE EXCEPTION 'IOD_TRANSFER_COMMITTED_PARTIAL|%|%', p_qty, v_reserved;
        END IF;

        IF v_reserved > 0 THEN
            PERFORM set_config('evoltrya.reservation_move_ctx', '1', true);
            UPDATE sales_order_reservations
               SET location_id = p_to_location_id
             WHERE output_batch_id IS NOT DISTINCT FROM p_output_batch_id
               AND location_id IS NOT DISTINCT FROM p_from_location_id
               AND released_at IS NULL AND consumed_at IS NULL;
            PERFORM set_config('evoltrya.reservation_move_ctx', '', true);
        END IF;
    END IF;

    RETURN jsonb_build_object('pair_id', v_pair, 'qty', p_qty,
                              'stock_status', p_stock_status,
                              'warnings', to_jsonb(v_warn));
END;
$function$

;

CREATE OR REPLACE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text, p_work_order_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_operation_type_code text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id      uuid := auth.uid();
    v_process_date date;
    v_run_id       uuid;
    v_total_input  numeric := 0;
    v_total_output numeric := 0;
    v_input        jsonb;
    v_output       jsonb;
    v_inbound_id   uuid;
    v_output_id    uuid;   -- FIN-25:再加工投料(产出批为源)
    v_consumed     numeric;
    v_remaining    numeric;
    v_available     numeric;
    v_held          numeric;
    v_new_remaining numeric;
    v_material_id  uuid;
    v_qty          numeric;
    v_unit         text;
    v_purity       text;
    v_new_output_id uuid;
    v_wo           work_orders%ROWTYPE;   -- WO-1b
    v_eq           fixed_assets%ROWTYPE;  -- EQP-2a:这一炉归给哪台机器
    -- PROC-WIRE-1B-i:这一炉跑的是哪道工序,以及那道工序【吃不吃料、产不产批】。
    -- 【分支读的是字典那两列,不是一个写死的字符串,也不是调用方传的旗标】
    -- 【PROC-SUPPORT-1】v_consumes / v_produces 不再有"没有工序时"的默认值 ——
    -- 到得了这里就一定有工序,两个值都由字典填。留着 := true 会是一句谎:
    -- 它读起来像"还有一条没有工序的路",而那条路已经在上面被拒掉了。
    v_op           text;
    v_consumes     boolean;
    v_produces     boolean;
    v_result_state text;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25):提交加工归仓库 —— action.processing_commit(warehouse · admin)。
    PERFORM require_permission('action.processing_commit');
    IF p_process_date IS NULL THEN
        RAISE EXCEPTION 'PROCESS_DATE_REQUIRED';
    END IF;

    -- FIN-36:分摊基准【必填】。不在这里回退到 finance_settings 的公司默认值 ——
    -- 那只会把"没人选过"从 schema 挪进函数,同一个病换一层楼。表单永远带着值来
    -- (预选自 finance_settings.default_allocation_basis),所以必填没有代价。
    IF p_allocation_basis IS NULL THEN
        RAISE EXCEPTION 'ALLOCATION_BASIS_REQUIRED';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★【PROC-SUPPORT-1:工序【必填】,而且【自己一条码】】★
    --
    -- 【为什么它必须与下面那四条拒绝分开,绝不合并】
    -- 下一步动作完全不同:
    --   · OPERATION_TYPE_REQUIRED        → 【你还没选工序】,回去选一个;
    --   · OPERATION_TYPE_UNKNOWN         → 选了,但那个码不存在或已停用;
    --   · OPERATION_PRODUCES_NO_OUTPUTS  → 选对了码,但这一单的形状与它矛盾;
    --   · STATE_CHANGE_LOSS_NOT_ZERO     → 同上,矛盾在损耗那一栏;
    --   · INPUT_SAFETY_STATE_NOT_ACCEPTED→ 码没错,是这一批料这道工序不收。
    -- 合并任何两条,屏幕上就会有一句话对应两个去处,而操作员会走错门。
    -- (与 PROC-3 那三条"听起来绝不一样"的拒绝同一条理由,fixture 154 钉着。)
    --
    -- 【位置为什么在这里】紧跟 PROCESS_DATE_REQUIRED / ALLOCATION_BASIS_REQUIRED,
    -- 也就是【所有必填项一起,在任何业务判断之前】。放到下面去,一张没选工序的
    -- 单会先撞上 NO_INPUTS 之类的话,而那句话是【真的,但没用】。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_operation_type_code IS NULL THEN
        RAISE EXCEPTION 'OPERATION_TYPE_REQUIRED'
          USING HINT = '从今天起每一张加工单必须说出它跑的是哪一道工序。产出有无、状态改变型的损耗守恒、逐工序安全状态受理、工序本身是否存在 —— 四道闸全都读这一列,而它为空时前三道要么关掉、要么降级成一条更弱的规则。历史上那 14 张没有工序的单是测试残留,刻意不回填,报表把它们显示成【未归属】。';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-WIRE-1B-i:解析工序类型。**分支由【工序】决定,不由调用方传旗标决定** ——
    -- 一个 p_is_state_changing 参数会让"这一炉算不算直通"变成调用方的意见,
    -- 而它是那道工序的事实。两者的区别在第一次有人传错的时候才显形,那太晚了。
    -- 【PROC-SUPPORT-1:这一段不再被 IF ... IS NOT NULL 包着】—— 上面那条拒绝
    -- 已经保证到得了这里就有工序。留着那个 IF 会读起来像"还有一条没有工序的路"。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT ot.code, k.consumes_input, k.produces_outputs, ot.resulting_safety_state_code
      INTO v_op, v_consumes, v_produces, v_result_state
      FROM operation_types ot
      JOIN operation_kinds k ON k.code = ot.kind_code
     WHERE ot.code = p_operation_type_code AND ot.is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OPERATION_TYPE_UNKNOWN|%', p_operation_type_code
          USING HINT = '未知或已停用的工序。停用的意思是"以后别再选它",不是"把历史改掉"。';
    END IF;
    IF p_allocation_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', p_allocation_basis;
    END IF;

    -- ── WO-1b:工单这一支【只在给了参数的时候才存在】────────────────────────
    -- 【为什么是可选的,而不是必填】临时起意的加工是合法的 —— 车间不会为了系统
    -- 先去补一张计划。把它变成必填,得到的不是纪律,是一堆事后补的假工单。
    -- 差异报表因此必须把 work_order_id 为空的那些显示成【计划外】这一个具名的
    -- 类别,而不是让它们悄悄消失(那是 WO-1c 的事,规则记在这里)。
    IF p_work_order_id IS NOT NULL THEN
        SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'WO_NOT_FOUND|%', p_work_order_id;
        END IF;
        -- 【只有放行了的工单可以开工】草稿是还没答应的事(与 reserve_stock 只认
        -- 已确认订单同一条);而 closed / cancelled 是【已经结束的事】,再往上挂
        -- 一次加工会让那张单的完成度在它收工之后继续变 —— 收工时写进理由行的
        -- 那句"runs=N"从此不再复算得出来。
        IF v_wo.status <> 'released' THEN
            RAISE EXCEPTION 'WO_NOT_RELEASED|%|%', v_wo.code, v_wo.status;
        END IF;
    END IF;

    -- ── EQP-2a:机器这一支【也只在给了参数的时候才存在】────────────────────
    -- ════════════════════════════════════════════════════════════════════════
    -- ★★【PROC-SUPPORT-1 / R2:equipment_id 【不】跟着 operation_type_code
    --      一起变成必填。这不是一次对称性偏好,是一次【字典完整性】判断。】★★
    --
    -- 【量出来的,不是想出来的】线上 fixed_assets 只有 2 行,而且两行【都是
    --  深度放电机】(FA-2026-0001 Bosch Deep Discharging Machine、
    --  FA-2026-0002 Mobile Discharging Solution),两行的 in_service_date 都是 NULL。
    -- 于是"一台机器一道工序"这个假设在线上【两个方向都是假的】:
    --   · deep_discharge ↔ 两台机器 → 工序【推不出】机器,不能"顺手带出来";
    --   · manual_disassembly / electrode_line / electrode_powder_line /
    --     battery_powder_line —— 五道工序里的【四道】,一台在册机器都没有。
    --     一旦 equipment_id 必填,这四道工序的加工单【一张都提交不了】。
    --
    -- 所以两列的区别是:
    --   · operation_type_code 的字典【完整】—— 5 道工序全部已播种,任何一张单
    --     都答得出来,于是必填的代价是零;
    --   · equipment_id 的字典【残缺】—— 5 道里 4 道无资产可指,于是必填的代价
    --     是让四道工序停摆。
    --
    -- ★【给后来人:不要"修"掉这处不对称】★ 它看起来像是漏了一半,不是。
    -- 要让 equipment_id 也必填,前置条件是【可以查询的】,不是一次感觉:
    --   (1) 每一道启用的工序至少有一台在册、在役的资产;
    --   (2) 而那需要一条【工序 ↔ 资产】的关联,**今天这个库里根本没有这条关联**
    --       —— 那才是真正的前置缺口,记在 docs/processing-support-as-built.md。
    -- 在那之前,空【是一个具名类别(未归属)】,不是零。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_equipment_id IS NOT NULL THEN
        SELECT * INTO v_eq FROM fixed_assets WHERE id = p_equipment_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_FOUND|%', p_equipment_id;
        END IF;
        -- 【拒绝的边界钉在"真的不可能"上,不钉在"还没投用"上】
        -- 加工日早于取得日 = 那天这台机器还不是我们的。
        IF p_process_date < v_eq.acquisition_date THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_ACQUIRED|%|%|%',
                v_eq.code, v_eq.acquisition_date, p_process_date
              USING HINT = '这一炉的日期早于这台机器的取得日 —— 那天它还不是我们的';
        END IF;
        -- 处置之后它已经不在了。
        IF v_eq.status = 'disposed' AND v_eq.disposal_date IS NOT NULL
           AND p_process_date > v_eq.disposal_date THEN
            RAISE EXCEPTION 'EQUIPMENT_DISPOSED|%|%|%',
                v_eq.code, v_eq.disposal_date, p_process_date
              USING HINT = '这一炉的日期晚于这台机器的处置日 —— 那时它已经不在了';
        END IF;
        -- 【投用之前【不】拒 —— 这是 EQP-2a 对原设计改动最大的一处】
        -- 原设计要拒"加工日那天机器不在役",而 in_service_date 是【投用】日。
        -- 投用之前的试车是这盘生意里一件有名有姓的事:
        -- docs/equipment-survey.md 的资本化边界那一节把"试车料"与安装、调试并列。
        -- 拒掉它们,系统就【记不下那些正好用来证明投用日的加工】,也丢掉了
        -- 那段真实的磨损 —— 而 EQP-2b 的保养间隔要读它。
        -- 剩下被拒的两种都是真的不可能,所以它们【是拒绝,不是警告】。
    END IF;

    v_process_date := p_process_date;
    -- 0. 基本校验
    IF p_inputs IS NULL OR jsonb_array_length(p_inputs) = 0 THEN
        RAISE EXCEPTION 'NO_INPUTS';
    END IF;
    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-WIRE-1B-i:产出的有无,由【工序】说了算
    --   * 会产出的工序(转化型)少了产出 → 照旧 NO_OUTPUTS,一个字没松;
    --   * 不产出的工序(状态改变型,R3)带着产出来 → 【也是拒】,而且是另一条码。
    -- 后者容易被漏掉:只放松一侧会让一张"放电还产出了黑粉"的单悄悄成立。
    -- 【PROC-SUPPORT-1:这道闸现在【总是】有一个工序可读】—— 此前 v_produces
    -- 在无工序时默认 true,于是这条 IF 走的是"照旧"那一支,闸等于不存在。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_produces THEN
        IF p_outputs IS NULL OR jsonb_array_length(p_outputs) = 0 THEN
            RAISE EXCEPTION 'NO_OUTPUTS';
        END IF;
    ELSE
        IF p_outputs IS NOT NULL AND jsonb_array_length(p_outputs) > 0 THEN
            RAISE EXCEPTION 'OPERATION_PRODUCES_NO_OUTPUTS|%', v_op
              USING HINT = '这道工序【按定义】不产新批次(R3:同一批进、同一批出,只改状态)。带着产出提交它,说明选错了工序或者选错了单。';
        END IF;
    END IF;
    IF p_loss_qty IS NOT NULL AND p_loss_qty < 0 THEN
        RAISE EXCEPTION 'LOSS_NEGATIVE';
    END IF;

    -- 0b. 同一批次(不论来源)不能重复添加。FIN-25:投料可为进料批或产出批,
    --     恰一非空;两个都给或都不给 → INPUT_PARENT_INVALID。
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_inputs) elem
        WHERE num_nonnulls(elem->>'inbound_batch_id', elem->>'output_batch_id') <> 1
    ) THEN
        RAISE EXCEPTION 'INPUT_PARENT_INVALID';
    END IF;
    IF (SELECT count(DISTINCT COALESCE(elem->>'inbound_batch_id', elem->>'output_batch_id'))
        FROM jsonb_array_elements(p_inputs) elem) <> jsonb_array_length(p_inputs) THEN
        RAISE EXCEPTION 'DUPLICATE_INPUT';
    END IF;

    -- 1. 遍历投入:校验库存(并锁行)+ 累计投入合计
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_output_id  := (v_input->>'output_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_consumed IS NULL OR v_consumed <= 0 THEN
            RAISE EXCEPTION 'INPUT_QTY_INVALID';
        END IF;

        IF v_inbound_id IS NOT NULL THEN
            SELECT remaining_qty INTO v_remaining
            FROM inbound_batches
            WHERE id = v_inbound_id AND deleted_at IS NULL
            FOR UPDATE;
            IF v_remaining IS NULL THEN
                RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_inbound_id;
            END IF;
        ELSE
            -- FIN-25:产出批投料 —— 同一套校验、同一把锁。库存机器本就共用
            -- (inventory_movements 两侧 XOR,remaining_qty 两表同义)。
            SELECT remaining_qty INTO v_remaining
            FROM output_batches
            WHERE id = v_output_id AND deleted_at IS NULL
            FOR UPDATE;
            IF v_remaining IS NULL THEN
                RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_output_id;
            END IF;
        END IF;
        -- IOD-1:投得进去的是【可用】,不是【物理剩余】—— 被扣住的货还在批次里,
        -- 但它不可动用。拒绝同时说出可用与暂扣两个数,否则人看着 remaining 够
        -- 却投不进去,屏幕上没有任何解释。
        v_available := COALESCE((SELECT sum(qty_delta) FROM inventory_movements m
                                 WHERE m.inbound_batch_id IS NOT DISTINCT FROM v_inbound_id
                                   AND m.output_batch_id IS NOT DISTINCT FROM v_output_id
                                   AND m.stock_status = 'available'), 0);
        v_held := COALESCE((SELECT sum(qty_delta) FROM inventory_movements m
                            WHERE m.inbound_batch_id IS NOT DISTINCT FROM v_inbound_id
                              AND m.output_batch_id IS NOT DISTINCT FROM v_output_id
                              AND m.stock_status = 'on_hold'), 0);
        IF v_consumed > v_available THEN
            RAISE EXCEPTION 'IOD_CONSUME_EXCEEDS_AVAILABLE|%|%|%', v_consumed, v_available, v_held;
        END IF;

        v_total_input := v_total_input + v_consumed;
    END LOOP;

    -- 2. 遍历产出:校验 + 累计产出合计
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_qty := (v_output->>'quantity')::numeric;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'OUTPUT_QTY_INVALID';
        END IF;
        IF (v_output->>'material_id') IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NO_MATERIAL';
        END IF;
        v_total_output := v_total_output + v_qty;
    END LOOP;

    -- 3. 质量守恒:产出不能大于投入
    IF v_total_output > v_total_input THEN
        RAISE EXCEPTION 'OUTPUT_EXCEEDS_INPUT|%|%', v_total_output, v_total_input;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-WIRE-1B-i:直通式的质量账
    -- **料【穿过】工序,没有被吃掉** —— 所以投入 = 产出 = 通过量,损耗【真的是 0】
    -- (放电不带走任何质量;这不是"没量过所以填 0",是 R3 说的同一批进同一批出)。
    -- 不这么写的话:total_output = 0 会让质量平衡读成"投了 100 出来 0",
    -- 而 loss_qty = COALESCE(p_loss_qty, 100 - 0) 会凭空记下一笔【等于全部投入】
    -- 的损耗 —— 一张放电单会报告它把碰过的东西全毁了。
    -- 【PROC-SUPPORT-1 实测:无工序时这一整段【从不执行】】—— v_produces 默认
    -- true,于是 NOT v_produces 永远为假。线上量到的那 3 公斤损耗就是这么来的。
    -- ════════════════════════════════════════════════════════════════════════
    IF NOT v_produces THEN
        v_total_output := v_total_input;
        IF COALESCE(p_loss_qty, 0) <> 0 THEN
            RAISE EXCEPTION 'STATE_CHANGE_LOSS_NOT_ZERO|%|%', v_op, p_loss_qty
              USING HINT = '状态改变型工序不带走质量,所以它的损耗只能是 0。填了别的数,要么选错了工序,要么这一炉其实是转化型。';
        END IF;
    END IF;

    -- 4. 建加工单表头(code 由触发器生成)
    INSERT INTO processing_runs (
        process_date, total_input, total_output, loss_qty, notes, status,
        allocation_basis, work_order_id, created_by, updated_by, equipment_id,
        operation_type_code
    ) VALUES (
        v_process_date, v_total_input, v_total_output,
        CASE WHEN v_produces THEN COALESCE(p_loss_qty, v_total_input - v_total_output)
             ELSE 0 END,
        p_notes, 'committed', p_allocation_basis, p_work_order_id, v_user_id, v_user_id,
        p_equipment_id,
        v_op
    )
    RETURNING id INTO v_run_id;

    -- 5. 再遍历投入:扣库存 + 更新阶段 + 建投入腿 + 记库存流水(消耗)
    --    FIN-25:ctx 提前到这里 —— 投入腿的守卫触发器(guard_processing_input)
    --    只放行函数上下文;原来 ctx 在第 6 步(产出)才设,投入腿就会被自己拒掉。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_output_id  := (v_input->>'output_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_inbound_id IS NOT NULL THEN
            -- ════════════════════════════════════════════════════════════
            -- PROC-WIRE-1B-i:【直通式不扣库存】
            -- 一炉深度放电结束之后,那批货还在院子里,还是那么多克。
            -- 扣掉它 = 账上把一批还存在的货销掉,而这是那个"只放松 NO_OUTPUTS"
            -- 的实现最先造成的破坏(它会把 remaining_qty 扣到 0)。
            -- **投入腿照记** —— 那是【通过量】,记的是"这批料走过这道工序",
            -- 不是"这批料被吃掉了"。设备用量与工时因此仍然读得到它。
            -- ════════════════════════════════════════════════════════════
            IF v_consumes THEN
                SELECT remaining_qty INTO v_remaining
                FROM inbound_batches WHERE id = v_inbound_id;
                v_new_remaining := v_remaining - v_consumed;

                UPDATE inbound_batches
                SET remaining_qty = v_new_remaining,
                    stage = CASE WHEN v_new_remaining <= 0 THEN '已加工完' ELSE '加工中' END,
                    updated_by = v_user_id,
                    updated_at = now()
                WHERE id = v_inbound_id;

                -- IOD-1:投料走 drain_stock —— 可能跨几个库位桶,于是写出多行(规则见其函数头)
                PERFORM drain_stock(
                    p_qty => v_consumed, p_movement_type => 'processing_consume',
                    p_business_date => v_process_date, p_inbound_batch_id => v_inbound_id,
                    p_statuses => ARRAY['available'], p_run_id => v_run_id, p_created_by => v_user_id);
            END IF;

            INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
            VALUES (v_run_id, v_inbound_id, v_consumed);

            -- ════════════════════════════════════════════════════════════
            -- PROC-WIRE-1B-i:**R3 的"改状态"就落在这里**
            -- 被这道工序【解决掉】的状态从批次上删掉,再写上结果状态。
            -- 不删的话,一批放完电的货会永远带着"未放电",于是下一道工序
            -- 仍然拒绝它 —— 那正是本刀要解的那个死锁,只是换了个位置复发。
            -- ════════════════════════════════════════════════════════════
            -- ★ MES-3a(2026-10-06,MES-0 Q36;MES-3a Step 0 Q22 · Q2,Tim):解决掉的状态被【结束】(记下是哪一张加工单),
            --   不再被删;写上的结果状态记 created_by_run_id —— 回滚据这两列把这一炉做过的事原样撤回。
            --   结果状态已经开着(批次本来就带着它)→ 不插(开着的只有一条),于是回滚也不会结束那条不是它写的。
            IF NOT v_produces AND v_result_state IS NOT NULL THEN
                UPDATE inbound_batch_safety_states s
                   SET ended_at = now(), ended_by = v_user_id, ended_by_run_id = v_run_id,
                       end_reason = 'resolved by processing run ' || (SELECT pr.code FROM processing_runs pr WHERE pr.id = v_run_id)
                 WHERE s.inbound_batch_id = v_inbound_id AND s.ended_at IS NULL
                   AND s.safety_state_code IN (
                       SELECT a.safety_state_code FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op AND a.resolves);

                INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code, created_by_run_id)
                VALUES (v_inbound_id, v_result_state, v_run_id)
                ON CONFLICT (inbound_batch_id, safety_state_code) WHERE ended_at IS NULL DO NOTHING;
            END IF;
        ELSE
            -- ════════════════════════════════════════════════════════════
            -- ★【PROC-WIRE-1B-ii:那条占位的拒绝在这里被【拆掉】】★
            -- 此前这里按名拒 STATE_CHANGE_OUTPUT_INPUT_UNSUPPORTED,理由是
            -- 结构性的:安全状态只有进料批有,"把状态改成已放电"这件事在
            -- 产出批上【无处可写】,放过去会得到一炉什么都没改的放电。
            -- **PROC-WIRE-1B-ii 建了 output_batch_safety_states,那个理由不复存在** ——
            -- 于是拒绝也必须跟着走。R1 说得很清楚:闸问的是【这批料和它的
            -- 状态】,不是【这批料从哪来】;一道工序因为料是自己产的就拒绝它,
            -- 正是那处不对称本身。
            -- 【留着它会更坏】表建好了、拒绝还在,下一个人会以为这条路仍然
            -- 没通,而 fixture 会对着一条早该消失的拒绝变绿。
            -- ════════════════════════════════════════════════════════════
            -- FIN-25:产出批投料。state 是【销售状态】(表注),消耗不碰它 ——
            -- 只扣 remaining_qty,流水挂 output_batch_id(XOR 的另一侧)。
            SELECT remaining_qty INTO v_remaining
            FROM output_batches WHERE id = v_output_id;
            v_new_remaining := v_remaining - v_consumed;

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_output_id;

            PERFORM drain_stock(
                p_qty => v_consumed, p_movement_type => 'processing_consume',
                p_business_date => v_process_date, p_output_batch_id => v_output_id,
                p_statuses => ARRAY['available'], p_run_id => v_run_id, p_created_by => v_user_id);

            INSERT INTO processing_inputs (run_id, output_batch_id, quantity_consumed)
            VALUES (v_run_id, v_output_id, v_consumed);

            -- ════════════════════════════════════════════════════════════
            -- PROC-WIRE-1B-ii:**R3 的"改状态",产出批这一侧** ——
            -- 与上面进料那一段逐字同形。不删被解决掉的状态,一批放完电的
            -- 自产料会永远带着"未放电",下一道工序仍然拒绝它 —— 那就是
            -- 1B-i 解掉的那个死锁,换到产出批上原样复发。
            -- ════════════════════════════════════════════════════════════
            -- ★ MES-3a:与进料侧逐字同形 —— 结束,不删;结果状态记 created_by_run_id。
            IF NOT v_produces AND v_result_state IS NOT NULL THEN
                UPDATE output_batch_safety_states s
                   SET ended_at = now(), ended_by = v_user_id, ended_by_run_id = v_run_id,
                       end_reason = 'resolved by processing run ' || (SELECT pr.code FROM processing_runs pr WHERE pr.id = v_run_id)
                 WHERE s.output_batch_id = v_output_id AND s.ended_at IS NULL
                   AND s.safety_state_code IN (
                       SELECT a.safety_state_code FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op AND a.resolves);

                INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code, created_by_run_id)
                VALUES (v_output_id, v_result_state, v_run_id)
                ON CONFLICT (output_batch_id, safety_state_code) WHERE ended_at IS NULL DO NOTHING;
            END IF;
        END IF;
    END LOOP;

    -- 6. 遍历产出:建产出批次 + 建产出腿
    --    产出的入库流水由 AFTER INSERT 触发器发出;先设置上下文标记本批产出属于本加工单。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_material_id := (v_output->>'material_id')::uuid;
        v_qty         := (v_output->>'quantity')::numeric;
        v_unit        := COALESCE(NULLIF(v_output->>'unit', ''), 'kg');
        v_purity      := NULLIF(v_output->>'purity', '');

        INSERT INTO output_batches (
            material_id, quantity, unit, remaining_qty, output_date, state, purity,
            created_by, updated_by
        ) VALUES (
            v_material_id, v_qty, v_unit, v_qty, v_process_date, '库存中', v_purity,
            v_user_id, v_user_id
        )
        RETURNING id INTO v_new_output_id;

        INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced)
        VALUES (v_run_id, v_new_output_id, v_qty);
    END LOOP;

    -- 用毕即清(price_ctx 同一条理由:免得同事务内后续的直改被误放行 ——
    -- fixture 19F 实测:不清,守卫触发器对残留 ctx 放行裸 INSERT)
    PERFORM set_config('evoltrya.movement_ctx', '', true);

    -- ── COD-1:这一投料可能【刚好把某一票货加工完】────────────────────────
    -- 销毁证书是一条【必须存在】的记录(像化验报告),不等谁打开页面。
    -- 幂等,没完成就什么也不做;判据在 cod_delivery_completion(),不在这里。
    FOR v_inbound_id IN
        SELECT DISTINCT pi.inbound_batch_id FROM processing_inputs pi
         WHERE pi.run_id = v_run_id AND pi.inbound_batch_id IS NOT NULL
    LOOP
        PERFORM refresh_cod_for_batch(v_inbound_id);
    END LOOP;

    RETURN v_run_id;
END;
$function$;

-- db/functions/rollback_processing_run_internal.sql
-- APR-7(2026-09-25):回滚一张加工单 —— ROLE-1 Batch 3b 的 rollback_processing_run 的函数体原样搬进来,
-- 只拿掉了码的检查、加了 p_deleted_by(grilling Q6:产出批与加工单的 deleted_by、还原流水的 created_by =
-- 提单人;不给 = 调用者本人)。冲销分录的 created_by 是调用者(批准的 CFO)。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.rollback_processing_run_internal(p_run_id uuid, p_reason text, p_deleted_by uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid := COALESCE(p_deleted_by, auth.uid());
    v_run_deleted_at timestamptz;
    v_process_date date;     -- FIN-32:还原流水的业务日 = 原加工单的加工日
    v_bad_output record;
    v_input record;
    v_old_remaining numeric;
    v_new_remaining numeric;
    v_quantity numeric;
    v_cap uuid;             -- 首挂的资本化分录
    v_delta_id uuid;        -- PROC-COST-2:重分摊的差额分录,逐张
    v_code text;
BEGIN
    -- ★ APR-7:本支是回滚那一步【本身】,不问码 —— EXECUTE 已从 authenticated 收回。唯一的调用者是
    --   warehouse_request_execute_internal(CFO 批准的回滚申请;deleted_by = 提单人,grilling Q6)。
    -- AUDEL-1b:【理由必填】回滚一张加工单是一次很大的操作动作 —— 它软删产出批、
    -- 还原投入、写一整串冲销流水 —— 而此前它【一个 why 都不记】。
    -- 校验放在任何写之前:被拒 = 什么都没发生。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'ROLLBACK_REASON_REQUIRED|%',
            COALESCE((SELECT code FROM processing_runs WHERE id = p_run_id), '?');
    END IF;
    -- 1. 锁定加工单，校验存在且未删除
    SELECT process_date INTO v_process_date FROM processing_runs WHERE id = p_run_id;
    SELECT deleted_at INTO v_run_deleted_at
    FROM processing_runs
    WHERE id = p_run_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;

    IF v_run_deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_ALREADY_DELETED';
    END IF;

    -- 标记本次为回滚上下文,供产出批次软删触发器发出 reversal_void。
    PERFORM set_config('evoltrya.movement_ctx', 'reversal:' || p_run_id::text, true);

    -- 2. 安全检查：任何一个产出批次动过就拒绝
    SELECT ob.code, ob.state, ob.quantity, ob.remaining_qty
    INTO v_bad_output
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id
      AND ob.deleted_at IS NULL
      AND (ob.state <> '库存中' OR ob.remaining_qty <> ob.quantity)
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'OUTPUT_CONSUMED|%|%|%|%',
            v_bad_output.code, v_bad_output.state, v_bad_output.remaining_qty, v_bad_output.quantity;
    END IF;

    -- 3. 还原进料：加回 remaining_qty，重判 stage，记 reversal_restore 流水。
    --    FIN-25:产出批投料同样还原(不碰 state —— 那是销售状态)。
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.output_batch_id, pi.quantity_consumed
        FROM processing_inputs pi
        WHERE pi.run_id = p_run_id
    LOOP
        IF v_input.inbound_batch_id IS NOT NULL THEN
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM inbound_batches
            WHERE id = v_input.inbound_batch_id
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 进料批次已被删，跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE inbound_batches
            SET remaining_qty = v_new_remaining,
                stage = CASE WHEN v_new_remaining >= v_quantity THEN '待加工' ELSE '加工中' END,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.inbound_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                -- FIN-32:还原不是物理事件,是在更正一次记错的加工单 —— 业务日取
                -- 【原加工单的 process_date】,于是消耗与还原在同一天对消,
                -- 中间那几天的库存历史不会凭空少掉一批实际还在的货。
                --
                -- 【IOD-1:逐行镜像原始流水,不按规则重新分配】投料现在可能跨几个
                -- 库位桶写出多行;还原必须把货放回【它原来所在的那些桶】,而不是
                -- 按 drain 的顺序倒着来一遍 —— 那两者在一般情形下并不相等,
                -- 差额会安静地把库存挪到别的库位上。所以这里读原始的
                -- processing_consume 行,逐行取反。
                PERFORM mirror_consume_restore(p_run_id, v_input.inbound_batch_id, NULL,
                                                 v_new_remaining - COALESCE(v_old_remaining, 0),
                                                 v_process_date, v_user_id);
            END IF;
        ELSE
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM output_batches
            WHERE id = v_input.output_batch_id AND deleted_at IS NULL
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 上游产出批已被删（如其自身加工单已冲销），跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.output_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                -- FIN-32:同上 —— 产出批投料的还原(FIN-25 那条边)业务日一样取原加工日
                PERFORM mirror_consume_restore(p_run_id, NULL, v_input.output_batch_id,
                                                 v_new_remaining - COALESCE(v_old_remaining, 0),
                                                 v_process_date, v_user_id);
            END IF;
        END IF;
    END LOOP;

    -- 4. 软删这张单生成的产出批次(void 流水 + 归零由 BEFORE UPDATE 触发器处理)
    -- AUDEL-1b:软删要走门 —— 标记 + deleted_by + delete_reason,否则
    -- guard_soft_delete_provenance 会按名拒。产出批的删除理由【就是这次回滚的
    -- 理由】:它们不是被单独注销的,是被这次回滚带走的。
    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-3a(2026-10-06,MES-3a Step 0 Q2,Tim):【回滚也撤回这一炉对安全状态做过的事】。
    --   此前回滚不碰状态:一炉深度放电回滚之后,那一批还挂着"已放电并核验",而"带电未放电"已经被删 ——
    --   一批屏幕上说放过电的料可以被投进破碎机。现在:
    --     · 这一炉写上的结果状态(created_by_run_id = 本单)→ 结束,理由写明是哪一次回滚;
    --     · 这一炉结束掉的状态(ended_by_run_id = 本单)→ 重新开一条,记录时刻与记录人照抄原行(滞留时钟不因回滚重来),
    --       reopened_from_id 指回原行。那一类状态此刻已经开着(之后有人又记了一次)就不重开。
    --   进料批与产出批两张表同一套。
    -- ════════════════════════════════════════════════════════════════════════
    UPDATE inbound_batch_safety_states s
       SET ended_at = now(), ended_by = v_user_id,
           end_reason = 'undone by rollback of ' || COALESCE((SELECT pr.code FROM processing_runs pr WHERE pr.id = p_run_id), '?')
                        || ': ' || btrim(p_reason)
     WHERE s.created_by_run_id = p_run_id AND s.ended_at IS NULL;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code, created_at, created_by, reopened_from_id)
    SELECT s.inbound_batch_id, s.safety_state_code, s.created_at, s.created_by, s.id
      FROM inbound_batch_safety_states s
     WHERE s.ended_by_run_id = p_run_id
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states o
                        WHERE o.inbound_batch_id = s.inbound_batch_id AND o.safety_state_code = s.safety_state_code
                          AND o.ended_at IS NULL);
    UPDATE output_batch_safety_states s
       SET ended_at = now(), ended_by = v_user_id,
           end_reason = 'undone by rollback of ' || COALESCE((SELECT pr.code FROM processing_runs pr WHERE pr.id = p_run_id), '?')
                        || ': ' || btrim(p_reason)
     WHERE s.created_by_run_id = p_run_id AND s.ended_at IS NULL;
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code, created_at, created_by, reopened_from_id)
    SELECT s.output_batch_id, s.safety_state_code, s.created_at, s.created_by, s.id
      FROM output_batch_safety_states s
     WHERE s.ended_by_run_id = p_run_id
       AND NOT EXISTS (SELECT 1 FROM output_batch_safety_states o
                        WHERE o.output_batch_id = s.output_batch_id AND o.safety_state_code = s.safety_state_code
                          AND o.ended_at IS NULL);

    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE output_batches
    SET deleted_at = now(),
        deleted_by = v_user_id,
        delete_reason = btrim(p_reason),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id IN (
        SELECT output_batch_id FROM processing_outputs WHERE run_id = p_run_id
    )
    AND deleted_at IS NULL;

    -- 5. 软删加工单本身（腿表保留作审计）
    UPDATE processing_runs
    SET status = 'reversed',
        deleted_at = now(),
        deleted_by = v_user_id,
        delete_reason = btrim(p_reason),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id = p_run_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);   -- 用毕即清(同 movement_ctx)

    -- ════════════════════════════════════════════════════════════════════════
    -- 【解除资本化 —— 台账与分录在同一个地方一起解除】(PROC-COST-1 立,
    --   PROC-COST-2 把工序种类的判断【拿掉】)
    --
    -- 台账那一半由基函数按本单的 deleted_at 自动排除(形状免费提供的);
    -- 分录那一半必须显式冲销 —— 两半都在这里发生,所以它们永远不会各说各话。
    -- 少做任何一半:要么成本留在存货上而单已经没了(账挂在一张不存在的单上),
    -- 要么台账清了而存货虚高。
    --
    -- ★【PROC-COST-2:这里原来有一句 `IF v_sc_kind`,只管状态改变型】★
    -- 于是**转化型加工单回滚之后,它的资本化分录(借 1220 / 贷 1200 / 贷 5xxx)
    -- 原样立着** —— 产出批已经被软删,1220 上却还挂着它的成本。
    -- 那个判断本刀【拿掉】:两种工序共用同一段代码,不是照着它再写一份。
    --   * 状态改变型:冲销 借 1200 / 贷 5xxx,成本从原料批上退回费用;
    --   * 转化型:    冲销 借 1220 / 贷 1200 / 贷 5xxx —— 1220 上的产出成本
    --     被拿掉,而投料的 1200 同时被还回来,与第 3 步还原 remaining_qty 同向。
    --
    -- 【产出批软删【不再】另外入账,这两件事必须一起读】注销触发器在
    -- reversal 上下文里不写分录 —— 因为解除 1220 的是这里冲销的这张分录。
    -- 两处都做就是重复计数。
    --
    -- ★【差额分录也要冲 —— 只补首挂的话,一张被重分摊过的单仍然错】★
    -- 转化型重分摊走的是差额路径:capitalization_entry_id 仍指首挂,新的差额
    -- 分录记在 allocation_snapshot->'delta_entry_ids' 里。只冲首挂,差额留在
    -- 1220 上,而这张单看起来已经修好了 —— 那是最坏的一种半修。
    -- (状态改变型不会有差额分录:它走的是冲旧挂新,capitalization_entry_id
    --  永远指着唯一活着的那一张。这个循环对它自然空转,不需要分支。)
    --
    -- 【第四个候选:sales_records 上的 COGS 分录 —— 不需要任何处置】
    -- 第 2 步的 OUTPUT_CONSUMED 闸在任何产出动过之后就拒绝回滚,而一次销售
    -- 必然动 remaining_qty。**够不到的东西不需要修,但需要被点名**,
    -- 否则下一个读到这里的人会把这条推理重做一遍。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT code, capitalization_entry_id INTO v_code, v_cap
      FROM processing_runs WHERE id = p_run_id;

    IF v_cap IS NOT NULL
       AND (SELECT status FROM journal_entries WHERE id = v_cap) = 'posted' THEN
        PERFORM reverse_journal_entry_internal(v_cap, reversal_date_for(v_cap),  -- AP-RECON-1 Batch B
            'Rollback ' || COALESCE(v_code, '?'));
    END IF;

    FOR v_delta_id IN
        SELECT (jsonb_array_elements_text(
                    COALESCE(pr.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)))::uuid
          FROM processing_runs pr WHERE pr.id = p_run_id
    LOOP
        IF (SELECT status FROM journal_entries WHERE id = v_delta_id) = 'posted' THEN
            PERFORM reverse_journal_entry_internal(v_delta_id, reversal_date_for(v_delta_id),  -- AP-RECON-1 Batch B
                'Rollback ' || COALESCE(v_code, '?'));
        END IF;
    END LOOP;

    UPDATE processing_runs
       SET capitalization_entry_id = NULL, capitalized_cost_base = 0
     WHERE id = p_run_id;

    PERFORM set_config('evoltrya.movement_ctx', '', true);   -- 用毕即清(同 commit)

    -- ── COD-1:冲销之后,这几票货不再是"加工完"的 ────────────────────────
    -- 【已签发的证书在这里作废,而且没有替代品】—— 冲销说的是那次加工没发生。
    -- 不做这一步,供应商手里那张纸就还在说着一件系统已经不再相信的事,
    -- 而没有任何东西会提醒任何人。将来重新加工到完,那时会成立一张新的证书。
    FOR v_input IN
        SELECT DISTINCT pi.inbound_batch_id FROM processing_inputs pi
         WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL
    LOOP
        PERFORM refresh_cod_for_batch(v_input.inbound_batch_id);
    END LOOP;
END;
$function$;

-- db/functions/assert_receipt_reading_calibrated.sql
-- MES-2(2026-10-06,规格 §8.2;MES-0 Q30;MES-2 Step 0 Q26 · Q27,Tim 的 MES-2 委托书):【校准闸】—— 一张收货单的读数可不可以拿去定价、拿去签证书。
--   调用方:reprice_inbound_batch(每一条收货定价路径都落进来的那一支引擎)· preview_reprice_inbound_batch(与它同一份算术的试算)·
--   issue_cod(销毁证书证的就是这张收货单的数量)。三处问的是同一支函数 —— 一份判据。
--   ★ MES-3a(2026-10-06,Tim 的裁定 1,MES-3a Step 0 §0):【校准规则还原成 MES-2 Step 0 当初裁下的那一条】。
--     MES-2 委托书里那句"开关空着什么都不拒"是一处错,MES-2 照它建了;Tim 裁:还原。从此:
--     · 一张收货单挂着的每一张地磅单的【最新】两磅(更正读最新的),只要仪器在读数那一天【已知】不在校准期内
--       (过期 · 没通过 · 从来没校过,MES-2 Q25)→ READING_INSTRUMENT_NOT_CALIBRATED|<仪器编号>|<读数日期> ——
--       【永远拒】,不看开关,也不看收货单是哪天建的。
--     · 开关 ingest_settings.require_calibrated_since(一个日期)只管【两种缺席】,而且只管那一天及以后建的收货单(新加坡日历):
--       读数没有记录仪器 → READING_INSTRUMENT_NOT_RECORDED|<地磅单>|<角色>;一张地磅单都没挂 → RECEIPT_READING_NOT_RECORDED|<收货单>。
--       开关空着,这两种只在页面上标出来,不拒。线上开关保持空。
--   读数那一天的状态来自 weighing_calibration_all(那张基视图里的挑法 + calibration_status_from 那一句判据)。
--   【内层】不是 SECURITY DEFINER、没有调用者检查,EXECUTE 从 authenticated 收回;调用方都是 DEFINER,以属主身份读。STABLE:试算也调它。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql; the rule restored by 2026-10-06-mes3a-storage-safety.sql.

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
    v_applies boolean;
    v_n       integer := 0;
    r         record;
BEGIN
    SELECT s.require_calibrated_since INTO v_since FROM ingest_settings s WHERE s.id;
    SELECT b.code, b.created_at INTO v_code, v_created FROM inbound_batches b WHERE b.id = p_inbound_batch_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    -- 开关管不管这一张:只决定两种【缺席】拒不拒;不在校准期内的读数不看它(Tim 的裁定 1)。
    v_applies := v_since IS NOT NULL AND (v_created AT TIME ZONE 'Asia/Singapore')::date >= v_since;
    FOR r IN SELECT t.code AS ticket_code, wc.role, wc.device_code, wc.captured_on, wc.status
               FROM weighbridge_ticket_shares s
               JOIN weighbridge_tickets t ON t.id = s.ticket_id
               JOIN weighing_calibration_all wc ON wc.ticket_id = s.ticket_id AND wc.is_current
              WHERE s.inbound_batch_id = p_inbound_batch_id
              ORDER BY t.code, wc.role LOOP
        v_n := v_n + 1;
        IF r.status = 'not_recorded' THEN
            IF v_applies THEN
                RAISE EXCEPTION 'READING_INSTRUMENT_NOT_RECORDED|%|%', r.ticket_code, r.role;
            END IF;
        ELSIF r.status <> 'in_calibration' THEN
            RAISE EXCEPTION 'READING_INSTRUMENT_NOT_CALIBRATED|%|%', r.device_code, to_char(r.captured_on, 'YYYY-MM-DD');
        END IF;
    END LOOP;
    IF v_n = 0 AND v_applies THEN
        RAISE EXCEPTION 'RECEIPT_READING_NOT_RECORDED|%', v_code;
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
    -- MES-2(Q26 · Q27)/ MES-3a(Tim 的裁定 1):校准闸 —— 不在校准期内的读数永远拒;开关只管两种缺席。判据只在那一支函数里。
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
        -- MES-3a(2026-10-06,MES-3a Step 0 Q4 · Q12):NEA 废物类别字典 —— 与其余六本同一个形状(清单块,/settings/dictionaries)
        ('dictionary_nea_waste_categories', ARRAY['module.materials.view'], 'nea_waste_categories', 'code', 'collection', NULL),
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
        ('weighbridge_ticket', 3, 'weighbridge_ticket_photos', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        -- ── MES-3a(2026-10-06,MES-3a Step 0 Q12 · Q10):执照 —— 它每一类 NEA 废物的库存上限(给 · 改 · 拿掉)。
        --    进料批 / 产出批 —— 它进厂那一刻库存上限的判法(一批一行,只追加)。──
        ('company_licence',    1, 'licence_storage_limits', 'company_compliance', 'licence_id',  '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     40, 'receipt_ceiling_checks', 'inbound_batches',    'inbound_batch_id', '{}'::jsonb, 'down', true, true),
        ('output_batch',      37, 'receipt_ceiling_checks', 'output_batches',     'output_batch_id',  '{}'::jsonb, 'down', true, false)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

CREATE OR REPLACE FUNCTION public.guard_processing_input()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_material_id uuid;
    v_may  boolean;
    v_code text;
    v_axes       boolean;
    v_batch_code text;
    v_n          integer;
    v_bad_zh     text;
    v_bad_en     text;
    v_c_zh       text;
    v_c_en       text;
    -- PROC-WIRE-1B-i
    v_op         text;
    v_op_zh      text;
BEGIN
    IF current_setting('evoltrya.movement_ctx', true) NOT LIKE 'processing:%'
       AND current_setting('evoltrya.movement_ctx', true) NOT LIKE 'reversal:%' THEN
        RAISE EXCEPTION 'PROCESSING_INPUT_DIRECT_INSERT';
    END IF;
    IF NEW.output_batch_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM processing_outputs po
        WHERE po.output_batch_id = NEW.output_batch_id AND po.run_id = NEW.run_id
    ) THEN
        RAISE EXCEPTION 'PROCESSING_INPUT_SELF_CONSUME|%', NEW.run_id;
    END IF;
    -- ── PROC-1:只有【说了可以投料】的物料进得来 ────────────────────────────
    SELECT COALESCE(ib.material_id, ob.material_id) INTO v_material_id
      FROM (SELECT 1) x
      LEFT JOIN inbound_batches ib ON ib.id = NEW.inbound_batch_id
      LEFT JOIN output_batches  ob ON ob.id = NEW.output_batch_id;
    IF v_material_id IS NOT NULL THEN
        SELECT m.may_be_processed, m.code INTO v_may, v_code
          FROM materials m WHERE m.id = v_material_id;
        IF v_may IS NOT TRUE THEN
            RAISE EXCEPTION 'MATERIAL_NOT_PROCESSABLE|%|%', v_code,
                CASE WHEN v_may IS NULL THEN 'undecided' ELSE 'false' END
              USING HINT = '这一种物料没有被声明为可投料;第二个参数说的是【没人决定过】还是【决定了不投】。';
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-3:这一【批】货现在是什么状态
    --
    -- ★【PROC-WIRE-1B-ii(R1 / M4):两侧都问了】★
    -- 此前这里只问进料批,而原注释写的理由是【问不了】—— 安全状态那时只有
    -- 进料批有。现在产出批也有(output_batch_safety_states),于是
    -- **这道闸的问题从"这批料从哪来"变成了"这批料和它的状态是什么"**。
    -- Tim 的 R1:抬高产出这一侧,绝不放低进料那一侧 —— 下面进料那一段一个字没动。
    -- ════════════════════════════════════════════════════════════════════════
    IF NEW.inbound_batch_id IS NOT NULL THEN
        SELECT mk.has_condition_axes INTO v_axes
          FROM inbound_batches ib
          JOIN materials       m  ON m.id   = ib.material_id
          JOIN material_kinds  mk ON mk.code = m.kind_code
         WHERE ib.id = NEW.inbound_batch_id;

        IF FOUND AND v_axes IS TRUE THEN
            SELECT ib.code INTO v_batch_code
              FROM inbound_batches ib WHERE ib.id = NEW.inbound_batch_id;

            -- 【D1:缺席仍然是自己那一条拒绝】"没有人记过"→ 去把它记下来。
            -- 这一条【与工序无关】:不管跑哪道工序,没人看过的料都不许进。
            SELECT count(*) INTO v_n
              FROM inbound_batch_safety_states s
             WHERE s.inbound_batch_id = NEW.inbound_batch_id AND s.ended_at IS NULL;
            IF v_n = 0 THEN
                RAISE EXCEPTION 'INPUT_SAFETY_STATE_NOT_RECORDED|%', v_batch_code
                  USING HINT = '一条安全状态都没有的意思是【没有人记过】,不是"这批货安全"。到【进料 → 打开这一批 → 到货状态】那一块把它记上。';
            END IF;

            -- ════════════════════════════════════════════════════════════════
            -- ★ PROC-WIRE-1B-i:受理由【这道工序】回答 ★
            --
            -- 【没有工序类型 → may_be_fed,今天的行为一个字不变】
            -- 【有工序类型 → 只受理明写的那些,没写的一律拒】
            --
            -- **方向只有一个:声明一道工序只会把闸收紧。** 任何放宽都必须是
            -- operation_type_safety_states 里一行明写的数据 —— 绝没有
            -- "状态改变型一律放行"那种按 kind 的旁路(那会让一块鼓包漏液的
            -- 电池进放电机,而放电机解决不了它)。
            --
            -- 【D2 合取仍然成立】一批料身上每一个状态都必须被受理;
            -- 有一条不被受理就拒,并且【一次点完】所有不被受理的。
            -- 【D4:仍然不读 is_active】—— 已经记下来的事实不因字典停用而改变。
            -- ════════════════════════════════════════════════════════════════
            SELECT pr.operation_type_code INTO v_op
              FROM processing_runs pr WHERE pr.id = NEW.run_id;

            IF v_op IS NULL THEN
                SELECT string_agg(d.name_zh, '、' ORDER BY d.sort_order)
                         FILTER (WHERE d.may_be_fed IS NOT TRUE),
                       string_agg(d.name_en, ', ' ORDER BY d.sort_order)
                         FILTER (WHERE d.may_be_fed IS NOT TRUE)
                  INTO v_bad_zh, v_bad_en
                  FROM inbound_batch_safety_states s
                  JOIN inbound_safety_states d ON d.code = s.safety_state_code
                 WHERE s.inbound_batch_id = NEW.inbound_batch_id AND s.ended_at IS NULL;

                IF v_bad_zh IS NOT NULL THEN
                    RAISE EXCEPTION 'INPUT_SAFETY_STATE_NOT_FEEDABLE|%|%|%',
                        v_batch_code, v_bad_zh, v_bad_en
                      USING HINT = '这一批带着不可投料的安全状态(全部列在消息里,一次清完)。状态改了要到【进料 → 打开这一批 → 到货状态】那一块改。';
                END IF;
            ELSE
                SELECT ot.name_zh INTO v_op_zh FROM operation_types ot WHERE ot.code = v_op;

                SELECT string_agg(d.name_zh, '、' ORDER BY d.sort_order),
                       string_agg(d.name_en, ', ' ORDER BY d.sort_order)
                  INTO v_bad_zh, v_bad_en
                  FROM inbound_batch_safety_states s
                  JOIN inbound_safety_states d ON d.code = s.safety_state_code
                 WHERE s.inbound_batch_id = NEW.inbound_batch_id AND s.ended_at IS NULL
                   AND NOT EXISTS (
                       SELECT 1 FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op
                          AND a.safety_state_code = s.safety_state_code);

                IF v_bad_zh IS NOT NULL THEN
                    RAISE EXCEPTION 'INPUT_SAFETY_STATE_NOT_ACCEPTED|%|%|%|%',
                        v_batch_code, COALESCE(v_op_zh, v_op), v_bad_zh, v_bad_en
                      USING HINT = '这道工序【不受理】这一批身上的某些安全状态(全部列在消息里)。这与"不可投料"是两句话:换一道受理它的工序也许就行 —— 比如没放电的料要先走【深度放电】。';
                END IF;
            END IF;

            -- 【D3:确定度【没记】仍然放行】不要"修"掉这处不对称 ——
            -- 安全状态防的是【起火】,确定度防的是【数字算错】,后者由化验回答,
            -- 不由停线回答。线上 23 批货一条确定度都没有。
            SELECT c.name_zh, c.name_en INTO v_c_zh, v_c_en
              FROM inbound_batches ib
              JOIN inbound_chemistry_certainties c ON c.code = ib.chemistry_certainty_code
             WHERE ib.id = NEW.inbound_batch_id
               AND c.may_be_fed IS NOT TRUE;
            IF FOUND THEN
                RAISE EXCEPTION 'INPUT_CHEMISTRY_NOT_FEEDABLE|%|%|%',
                    v_batch_code, v_c_zh, v_c_en
                  USING HINT = '这一批的化学体系确定度被记成了一个不可投料的值。到【进料 → 打开这一批 → 到货状态】那一块改。';
            END IF;
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★【产出批那一侧:M4 的修法】★★
    --
    -- ★【与进料侧【刻意的分歧】:这里【不】看 has_condition_axes】★
    -- **这是一处有意的不同,不是照抄时漏掉的一行。**
    -- 进料侧那道闸包在 `IF FOUND AND v_axes IS TRUE` 里;产出侧不能照抄,
    -- 理由是一次测量:**线上 20 批产出,它们的物料 kind_code 全是 NULL**,
    -- 于是 has_condition_axes 全是 NULL —— 照抄那一行,这道闸会对【零】批货
    -- 生效,而那份证明它生效的 fixture 会对着空气变绿。
    -- ★ 对产出料,"种类没人分过"的意思是**没有人分过类**,而那【不是许可】。
    --   **这是一道火闸:未知的安全状态不是许可。**
    -- (进料侧那个相反的取舍是刻意的、有记录的,本刀不动:那边的空意思是
    --  "这条轴比这行料还年轻",拦掉它等于停掉线上每一笔收货。)
    --
    -- 【三条拒绝与进料侧【同形但不同名】】下一步动作差在【去哪块屏幕记】:
    -- 进料侧是"进料 → 打开这一批 → 到货状态",产出侧是"产出批次页"。
    -- 同一句话配两个去处,操作员会走错门 —— 所以分名,不合并。
    -- ════════════════════════════════════════════════════════════════════════
    IF NEW.output_batch_id IS NOT NULL THEN
        SELECT ob.code INTO v_batch_code
          FROM output_batches ob WHERE ob.id = NEW.output_batch_id;

        -- 【缺席 = 没有人记过,不是"安全"】与进料侧 D1 同一个意思。
        SELECT count(*) INTO v_n
          FROM output_batch_safety_states s
         WHERE s.output_batch_id = NEW.output_batch_id AND s.ended_at IS NULL;
        IF v_n = 0 THEN
            RAISE EXCEPTION 'PRODUCED_SAFETY_STATE_NOT_RECORDED|%', v_batch_code
              USING HINT = '这一批是【自己产出】的料,而它一条安全状态都没有 —— 那的意思是【没有人记过】,不是"它安全"。自产的料与买进来的料在这道火闸面前是同一个问题。到【产出 → 打开这一批 → 安全状态】那一块把它记上。';
        END IF;

        -- 【收紧不变式:与进料侧逐字同一条】没有工序类型 → may_be_fed;
        -- 有工序类型 → 只受理 operation_type_safety_states 里明写的那些。
        -- **声明一道工序只会把闸收紧**,产出侧不给任何按 kind 的旁路。
        SELECT pr.operation_type_code INTO v_op
          FROM processing_runs pr WHERE pr.id = NEW.run_id;

        IF v_op IS NULL THEN
            SELECT string_agg(d.name_zh, '、' ORDER BY d.sort_order)
                     FILTER (WHERE d.may_be_fed IS NOT TRUE),
                   string_agg(d.name_en, ', ' ORDER BY d.sort_order)
                     FILTER (WHERE d.may_be_fed IS NOT TRUE)
              INTO v_bad_zh, v_bad_en
              FROM output_batch_safety_states s
              JOIN inbound_safety_states d ON d.code = s.safety_state_code
             WHERE s.output_batch_id = NEW.output_batch_id AND s.ended_at IS NULL;

            IF v_bad_zh IS NOT NULL THEN
                RAISE EXCEPTION 'PRODUCED_SAFETY_STATE_NOT_FEEDABLE|%|%|%',
                    v_batch_code, v_bad_zh, v_bad_en
                  USING HINT = '这一批自产的料带着不可投料的安全状态(全部列在消息里,一次清完)。到【产出 → 打开这一批 → 安全状态】那一块改。';
            END IF;
        ELSE
            SELECT ot.name_zh INTO v_op_zh FROM operation_types ot WHERE ot.code = v_op;

            SELECT string_agg(d.name_zh, '、' ORDER BY d.sort_order),
                   string_agg(d.name_en, ', ' ORDER BY d.sort_order)
              INTO v_bad_zh, v_bad_en
              FROM output_batch_safety_states s
              JOIN inbound_safety_states d ON d.code = s.safety_state_code
             WHERE s.output_batch_id = NEW.output_batch_id AND s.ended_at IS NULL
               AND NOT EXISTS (
                   SELECT 1 FROM operation_type_safety_states a
                    WHERE a.operation_type_code = v_op
                      AND a.safety_state_code = s.safety_state_code);

            IF v_bad_zh IS NOT NULL THEN
                RAISE EXCEPTION 'PRODUCED_SAFETY_STATE_NOT_ACCEPTED|%|%|%|%',
                    v_batch_code, COALESCE(v_op_zh, v_op), v_bad_zh, v_bad_en
                  USING HINT = '这道工序【不受理】这一批自产料身上的某些安全状态(全部列在消息里)。这与"不可投料"是两句话:换一道受理它的工序也许就行。';
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$
;

-- ── 9 · 换了签名的两支:DROP 旧签名、CREATE 新的(新参数都在末尾、都带默认值)──────────

DROP FUNCTION public.set_inbound_safety_states(uuid, text[]);

-- db/functions/set_inbound_safety_states.sql
-- PROC-2c:一批货的安全状态,一笔事务。批次页面与两条建批次的路共用它。
-- ★ MES-3a(2026-10-06,MES-0 Q36;MES-3a Step 0 Q15 · Q22 · Q23,Tim):【只加新勾上的、只结束拿掉的】。
--   p_codes = 这一批此刻该有的全部状态(与从前一样)。与【开着的】那几条比:
--     · 新出现的 → 插一条(记录时刻 = 现在,记录人 = 本人);
--     · 不再出现的 → 结束那一条:ended_at = 现在、ended_by = 本人、end_reason = p_end_reason(必填,空 →
--       SAFETY_STATE_END_REASON_REQUIRED|<状态,逗号分隔>,一条都不写);
--     · 两边都有的 → 一个字节都不动(滞留时钟从它被记下的那一刻起算,不因保存重来 —— 此前每一次保存都删掉重插)。
--   签名多了 p_end_reason(末尾、带默认值):迁移是 DROP + CREATE;已部署的旧页面不传它,勾上照样能存,拿掉会被要理由拒。
--   重复的代码不去重 —— 让"开着的只有一条"那个唯一索引去拒(PROC-2c 的原理由:去重会把一个输入错误藏起来)。
--
-- NOTE: introduced by db/migrations/2026-08-22-proc2-intake-condition-axes.sql; rewritten by 2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.set_inbound_safety_states(p_inbound_batch_id uuid, p_codes text[], p_end_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n      int;
    v_codes  text[] := COALESCE(p_codes, ARRAY[]::text[]);
    v_ending text;
BEGIN
    PERFORM require_permission('module.inbound.edit');

    IF p_inbound_batch_id IS NULL THEN
        RAISE EXCEPTION 'SAFETY_STATES_BATCH_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id) THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;

    -- 要结束的那几条:开着、而这一次没再勾上。结束要理由 —— 在写任何东西之前问。
    SELECT string_agg(s.safety_state_code, ',' ORDER BY s.safety_state_code) INTO v_ending
      FROM inbound_batch_safety_states s
     WHERE s.inbound_batch_id = p_inbound_batch_id AND s.ended_at IS NULL
       AND NOT (s.safety_state_code = ANY (v_codes));
    IF v_ending IS NOT NULL AND btrim(COALESCE(p_end_reason, '')) = '' THEN
        RAISE EXCEPTION 'SAFETY_STATE_END_REASON_REQUIRED|%', v_ending;
    END IF;

    UPDATE inbound_batch_safety_states s
       SET ended_at = now(), ended_by = auth.uid(), end_reason = btrim(p_end_reason)
     WHERE s.inbound_batch_id = p_inbound_batch_id AND s.ended_at IS NULL
       AND NOT (s.safety_state_code = ANY (v_codes));

    -- 新勾上的:只插开着的里面还没有的。同一次请求里写了两遍的代码不去重,让唯一索引去拒。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT p_inbound_batch_id, c FROM unnest(v_codes) c
     WHERE NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = p_inbound_batch_id AND s.ended_at IS NULL
                          AND s.safety_state_code = c);

    SELECT count(*) INTO v_n FROM inbound_batch_safety_states
     WHERE inbound_batch_id = p_inbound_batch_id AND ended_at IS NULL;
    RETURN jsonb_build_object('inbound_batch_id', p_inbound_batch_id, 'count', v_n);
END;
$function$;

COMMENT ON FUNCTION public.set_inbound_safety_states(uuid, text[], text) IS
'★ MES-3a(2026-10-06,MES-3a Step 0 Q22 · Q23,Tim):从【整组替换】改成【只加新勾上的、只结束拿掉的】—— 没变的那几条一个字节都不动,
于是它们的记录时刻(滞留时钟,Q15)不因每一次保存重来;拿掉的那几条被【结束】(ended_at · ended_by · end_reason),不被删掉,
而结束要一个理由(p_end_reason,空 → SAFETY_STATE_END_REASON_REQUIRED|<状态>)。下面是 PROC-2c 的原注释,【整组替换】那一句从此按这一句读。

PROC-2c:一批货的安全状态【整组替换】,一笔事务。批次页面与两条建批次的路【共用它】。

【它为什么存在】PROC-2b 在 app 侧"先删后插",而 PostgREST 一次一条语句 ——
两步之间失败会留下一个空集。**而空集在这套系统里是一句有含义的话:"没有人记过"。**
于是一次失败的保存会把"有人记过"改写成"没有人记过" —— 一个静默的、方向明确的谎。
放进函数体,失败即整体回滚,前一组原样还在。

════════════════════════════════════════════════════════════════════════════
【D3 的判决:【不】加一个 not_checked 取值 —— 而 grill 找到了它的镜像,一并写下】

**不加的理由:** 这张字典回答的是【这批货处在什么状态】,而"没有人看过"
不是货的属性,是我们知道多少的属性。把它放进字典还会让它可以与真状态【并列勾选】
(「进过水」+「没人看过」),而那是一句读不通的话。
**所以缺席就是缺席,而且它是一个有名字的状态**:屏幕上写着
「没有记过任何安全状态。那的意思是没有人记过,不是这批货是安全的」。

**而 grill 找到了 brief 没有点名的那一半 —— 它对 PROC-3 要紧:**

> **「看过了,五种都不适用」今天与「没有人看过」长得一模一样。**

一批【厂内边角料】:从来没充过电、没破损、没进水、没鼓包 —— 五个取值一个都不适用,
于是零行。而零行读作"没有人记过"。**这与 measured-zero 对 never-measured 是同一族。**

**它不在本刀里补,理由有两条:**
1. **消费者是 PROC-3,而这个区别的代价只有它算得出来** —— 一道拒绝"没有安全状态"
   的闸会不会冤枉一批完全合格的厂内边角料,是那一刀要回答的;
2. **PROC-2 已经把工具建好了一半**:`material_sources.implies_never_charged`。
   PROC-3 读得到它 —— 一批来源为厂内边角料的货,零行【不是】一个缺口。
   剩下的那部分(退役料、看过了确实没问题)才需要一个新的表达方式,
   而那多半是一个"检查过了"的时刻戳(是【检查】的属性),不是字典里的一个值。
**返回条件:PROC-3 决定"零行"对投料意味着什么的那一刻。**
════════════════════════════════════════════════════════════════════════════';

DROP FUNCTION public.save_storage_location(text, text, text[], uuid, text, text);

-- db/functions/save_storage_location.sql
-- AUDIT-TRAIL-1b-3(Tim 的 Q13,AT-1b Step 0,2026-09-29):保存一个库位 —— 新建或修改,连同它允许存放的废物分类,
--   【一次调用、一笔事务、只写变了的】。
--
-- 【为什么要它】此前 app/inventory/locations/actions.ts 分三次写:改库位那一行 · 删掉它全部的允许分类 · 再把勾上的
--   全部插回去 —— 三笔事务。于是审计记录里每保存一次,没动过的分类也读成"拿掉了"又"加上了",而且是三条记录
--   (Step 0 §f)。现在:库位那一行只有真的变了才写;分类只删【不再勾着】的、只插【新勾上】的;全在这一笔里。
-- 【空集合是合法的,它的意思是"未配置"】与原来的动作同一条:不拦空。
-- 【违规提醒照旧】trg_slac_notify_written 只接 INSERT(清空到零行 = 未配置,不是违规)。原来"整体删了再插"每次都
--   让它响;现在只拿掉、不加的那一次没有 INSERT,它不会响 —— 而拿掉一个分类恰恰可能让已有存量变成违规。
--   所以这一支在那种情形下自己按同一个判据叫一次 notify_class_violations(剩下的集合非空时,与原来一字不差)。
--   集合一条都没变的保存不再叫 —— 原来那一次是"整体重写"的副作用,不是一个新的配置。
-- 【SECURITY DEFINER 的理由】notify_class_violations 对 authenticated 收回了执行权;门在函数第一行
--   (require_permission('module.inventory.edit'),与两张表的写策略同一个码)。change_log 的"谁"取自登录,不受影响。
-- ★ MES-3a(2026-10-06,MES-0 Q34;MES-3a Step 0 Q17,Tim):末尾多一个 p_is_quarantine(隔离库位)。NULL = 不改(修改时)/
--   否(新建时)—— 已部署的旧页面不传它,照样解析,也不会把一个已标的隔离库位悄悄改回去。签名变了:迁移是 DROP + CREATE。
CREATE OR REPLACE FUNCTION public.save_storage_location(p_code text, p_name text, p_classes text[], p_id uuid DEFAULT NULL::uuid, p_zone text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_is_quarantine boolean DEFAULT NULL::boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id      uuid := p_id;
    v_classes text[] := ARRAY(SELECT DISTINCT c FROM unnest(COALESCE(p_classes, ARRAY[]::text[])) c WHERE c IS NOT NULL AND c <> '');
    v_removed integer := 0;
    v_added   integer := 0;
BEGIN
    PERFORM require_permission('module.inventory.edit');
    IF v_id IS NULL THEN
        INSERT INTO storage_locations (code, name, zone, notes, is_quarantine)
        VALUES (p_code, p_name, p_zone, p_notes, COALESCE(p_is_quarantine, false))
        RETURNING id INTO v_id;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = v_id) THEN
            RAISE EXCEPTION 'LOCATION_NOT_FOUND|%', v_id;
        END IF;
        UPDATE storage_locations
           SET code = p_code, name = p_name, zone = p_zone, notes = p_notes,
               is_quarantine = COALESCE(p_is_quarantine, is_quarantine)
         WHERE id = v_id
           AND (code, name, zone, notes, is_quarantine)
               IS DISTINCT FROM (p_code, p_name, p_zone, p_notes, COALESCE(p_is_quarantine, is_quarantine));
    END IF;

    DELETE FROM storage_location_allowed_classes
     WHERE location_id = v_id AND NOT (classification_code = ANY (v_classes));
    GET DIAGNOSTICS v_removed = ROW_COUNT;

    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    SELECT v_id, c FROM unnest(v_classes) c
     WHERE NOT EXISTS (SELECT 1 FROM storage_location_allowed_classes a
                        WHERE a.location_id = v_id AND a.classification_code = c);
    GET DIAGNOSTICS v_added = ROW_COUNT;

    IF v_removed > 0 AND v_added = 0 AND cardinality(v_classes) > 0 THEN
        PERFORM notify_class_violations('location_configured', NULL, ARRAY[v_id]);
    END IF;
    RETURN v_id;
END;
$function$;

-- ── 10 · 删掉的两支(Q11):没有调用方,而且读到空就拒绝作判断 —— 与 Q33 相反 ─────────────
DROP FUNCTION public.licence_storage_within_limit();
DROP FUNCTION public.hazardous_qty_on_hand_tonnes();

-- ── 11 · 新视图(镜像原样)──────────────────────────────────────────────────────

-- db/views/nea_category_on_hand_all.sql
-- MES-3a(2026-10-06,MES-0 Q32;MES-3a Step 0 Q7 · Q8,Tim):【每一类 NEA 废物此刻在厂里有多少吨】—— 基视图,不给人读。
--   存量 = 每一批(进料 + 产出)的流水之和(Σ qty_delta,三种库存状态都算 —— 暂扣与已承诺的货也还在厂里),
--   只算还有货的批(≠ 0;注销的批由它的注销腿归零),按物料【此刻】的 nea_waste_category_code 归类,换成吨(quantity_in_tonnes)。
--   unconvertible_batches = 这一类里单位换算不成吨的批数(件 / 别的);tonnes 只加得进换算得了的那些 —— 所以读的人必须先看这一格。
--   读它的:receipt_ceiling_check_internal(收货那一笔事务里,锁了执照行之后读 —— 这一批自己的入库流水已经在里面)·
--   storage_ceiling_status(读者视图)· operations_now 的 storage_ceiling_exceeded 臂。
--   【属主视图、从 authenticated 收回】与 weighing_calibration_all 同形:收货的人不一定持库存查看码,判法却不能因此少算一批。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE VIEW public.nea_category_on_hand_all WITH (security_invoker = off) AS
 SELECT m.nea_waste_category_code AS category_code,
    count(*) AS batches,
    sum(quantity_in_tonnes(b.qty, b.unit)) AS tonnes,
    count(*) FILTER (WHERE quantity_in_tonnes(b.qty, b.unit) IS NULL) AS unconvertible_batches
   FROM ( SELECT ib.material_id,
            ib.unit,
            sum(mv.qty_delta) AS qty
           FROM inventory_movements mv
             JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
          GROUP BY ib.id, ib.material_id, ib.unit
        UNION ALL
         SELECT ob.material_id,
            ob.unit,
            sum(mv.qty_delta) AS qty
           FROM inventory_movements mv
             JOIN output_batches ob ON ob.id = mv.output_batch_id
          GROUP BY ob.id, ob.material_id, ob.unit) b
     JOIN materials m ON m.id = b.material_id
  WHERE b.qty <> 0::numeric AND m.nea_waste_category_code IS NOT NULL
  GROUP BY m.nea_waste_category_code;

COMMENT ON VIEW public.nea_category_on_hand_all IS
    'MES-3a:每一类 NEA 废物此刻在厂里的吨数(进料 + 产出批的流水之和,三种库存状态都算,按物料此刻的类别归类)与换算不成吨的批数。基视图,不给人读:收货的判法与 storage_ceiling_status 以属主身份读它。';

REVOKE ALL ON public.nea_category_on_hand_all FROM anon, authenticated;

-- db/views/storage_ceiling_status.sql
-- MES-3a(2026-10-06,MES-0 Q32;MES-3a Step 0 Q6 · Q13 · Q32,Tim):【此刻在效的那张执照下,每一类 NEA 废物的存量对着上限】。
--   一行一类(启用的类别,加上停用了却还有存量或还有上限的),再加一行总量(category_code 为空 = 执照的 approved_storage_limit_tonnes
--   对着所有有类别的存量之和)。执照 = 今天(新加坡日历)在效的 gwdf(storage_licence_in_force);没有在效执照 → 零行(页面说出来)。
--   status:not_set(上限没给)· not_computable(存量里有换算不成吨的批)· exceeded(超了)· within。
--   读它的:/inventory/storage-safety · operations_now 的 storage_ceiling_exceeded 臂(只提醒,Q13)。
--   【属主视图 + 体内谓词】读执照、上限与存量基视图不过 RLS;门:module.suppliers.view(执照那一侧)或 module.inventory.view(库存那一侧)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE VIEW public.storage_ceiling_status WITH (security_invoker = off) AS
 WITH lic AS (
         SELECT cc.id,
            cc.cert_no,
            cc.approved_storage_limit_tonnes
           FROM company_compliance cc
          WHERE cc.id = storage_licence_in_force((now() AT TIME ZONE 'Asia/Singapore'::text)::date)
        ), cat_rows AS (
         SELECT lic.id AS licence_id,
            lic.cert_no,
            c.code AS category_code,
            c.name_en,
            c.name_zh,
            c.sort_order,
            l.limit_tonnes,
            oh.tonnes AS on_hand_t,
            COALESCE(oh.batches, 0::bigint) AS batches,
            COALESCE(oh.unconvertible_batches, 0::bigint) AS unconvertible_batches
           FROM lic
             CROSS JOIN nea_waste_categories c
             LEFT JOIN licence_storage_limits l ON l.licence_id = lic.id AND l.category_code = c.code
             LEFT JOIN nea_category_on_hand_all oh ON oh.category_code = c.code
          WHERE c.is_active OR oh.batches > 0 OR l.id IS NOT NULL
        UNION ALL
         SELECT lic.id AS licence_id,
            lic.cert_no,
            NULL::text AS category_code,
            'All NEA categories'::text AS name_en,
            '所有 NEA 类别'::text AS name_zh,
            2147483647 AS sort_order,
            lic.approved_storage_limit_tonnes AS limit_tonnes,
            ( SELECT sum(a.tonnes) AS sum
                   FROM nea_category_on_hand_all a) AS on_hand_t,
            COALESCE(( SELECT sum(a.batches) AS sum
                   FROM nea_category_on_hand_all a), 0::numeric)::bigint AS batches,
            COALESCE(( SELECT sum(a.unconvertible_batches) AS sum
                   FROM nea_category_on_hand_all a), 0::numeric)::bigint AS unconvertible_batches
           FROM lic
        )
 SELECT licence_id,
    cert_no,
    category_code,
    name_en,
    name_zh,
    sort_order,
    limit_tonnes,
    COALESCE(on_hand_t, 0::numeric) AS on_hand_t,
    batches,
    unconvertible_batches,
        CASE
            WHEN limit_tonnes IS NULL THEN 'not_set'::text
            WHEN unconvertible_batches > 0 THEN 'not_computable'::text
            WHEN COALESCE(on_hand_t, 0::numeric) > limit_tonnes THEN 'exceeded'::text
            ELSE 'within'::text
        END AS status
   FROM cat_rows
  WHERE has_permission('module.suppliers.view'::text) OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.storage_ceiling_status IS
    'MES-3a:今天在效的 gwdf 执照下,每一类 NEA 废物的存量(吨)对着上限,外加一行总量(category_code 为空)。status:not_set · not_computable · exceeded · within。没有在效执照 → 零行。门:module.suppliers.view 或 module.inventory.view。';

GRANT SELECT ON public.storage_ceiling_status TO authenticated;
REVOKE ALL ON public.storage_ceiling_status FROM anon;

-- db/views/safety_state_dwell.sql
-- MES-3a(2026-10-06,MES-0 Q35;MES-3a Step 0 Q14–Q16,Tim):【每一批身上每一条开着的安全状态,在厂里待了多久】。
--   一行 = 一条开着的状态(ended_at 为空),进料批与产出批两侧;注销的批不算。
--   days_recorded = 今天(新加坡日历)− 这条状态被记下的那一天(新加坡日历)—— 时钟从【记下的时刻】起算(Q35),
--   而那个时刻不因保存重来(set_*_safety_states 只加新勾上的、只结束拿掉的)。
--   dwell_status:not_set(这个状态的 dwell_warning_days 没给,V3)· past(到了或过了)· within。
--   on_site = 这一批此刻还有存量(流水之和 > 0)—— 提醒臂只看还在厂里的(Q15)。
--   读它的:两个批次页(每一条状态的那一行)· /inventory/storage-safety · operations_now 的 safety_state_dwell 臂。
--   【属主视图 + 逐行谓词】进料行要 module.inbound.view,产出行要 module.output.view(与两张状态表的读策略同一对)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE VIEW public.safety_state_dwell WITH (security_invoker = off) AS
 SELECT x.batch_kind,
    x.state_row_id,
    x.batch_id,
    x.batch_code,
    x.safety_state_code,
    d.name_en,
    d.name_zh,
    d.sort_order,
    x.recorded_at,
    x.recorded_by,
    (x.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date AS recorded_on,
    (now() AT TIME ZONE 'Asia/Singapore'::text)::date - (x.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date AS days_recorded,
    d.dwell_warning_days,
    d.requires_quarantine,
        CASE
            WHEN d.dwell_warning_days IS NULL THEN 'not_set'::text
            WHEN ((now() AT TIME ZONE 'Asia/Singapore'::text)::date - (x.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date) >= d.dwell_warning_days THEN 'past'::text
            ELSE 'within'::text
        END AS dwell_status,
    COALESCE(x.on_site_qty, 0::numeric) > 0::numeric AS on_site
   FROM ( SELECT 'inbound'::text AS batch_kind,
            s.id AS state_row_id,
            b.id AS batch_id,
            b.code AS batch_code,
            s.safety_state_code,
            s.created_at AS recorded_at,
            s.created_by AS recorded_by,
            ( SELECT sum(mv.qty_delta) AS sum
                   FROM inventory_movements mv
                  WHERE mv.inbound_batch_id = b.id) AS on_site_qty
           FROM inbound_batch_safety_states s
             JOIN inbound_batches b ON b.id = s.inbound_batch_id
          WHERE s.ended_at IS NULL AND b.deleted_at IS NULL AND has_permission('module.inbound.view'::text)
        UNION ALL
         SELECT 'output'::text AS batch_kind,
            s.id AS state_row_id,
            b.id AS batch_id,
            b.code AS batch_code,
            s.safety_state_code,
            s.created_at AS recorded_at,
            s.created_by AS recorded_by,
            ( SELECT sum(mv.qty_delta) AS sum
                   FROM inventory_movements mv
                  WHERE mv.output_batch_id = b.id) AS on_site_qty
           FROM output_batch_safety_states s
             JOIN output_batches b ON b.id = s.output_batch_id
          WHERE s.ended_at IS NULL AND b.deleted_at IS NULL AND has_permission('module.output.view'::text)) x
     JOIN inbound_safety_states d ON d.code = x.safety_state_code;

COMMENT ON VIEW public.safety_state_dwell IS
    'MES-3a:每一条开着的安全状态(进料批与产出批)被记下之后过了几个新加坡日历天,对着这个状态的 dwell_warning_days(V3):not_set · past · within;on_site = 这一批还有存量。只提醒,不拒。逐行谓词:进料行 module.inbound.view,产出行 module.output.view。';

GRANT SELECT ON public.safety_state_dwell TO authenticated;
REVOKE ALL ON public.safety_state_dwell FROM anon;

-- db/views/quarantine_exposure.sql
-- MES-3a(2026-10-06,MES-0 Q34;MES-3a Step 0 Q20,Tim):【该在隔离区、却还放在别处的货】。
--   一行 = 一批 × 一个【不是隔离库位】的库位桶(未指定也算不是),那一桶里还有货,而这一批身上开着一条
--   requires_quarantine = true 的状态(引导:鼓包或漏液)。来路:一个状态记在了已经放好的货上(记下永远不拒,Q20)、
--   一次回滚把料还回原库位、盘点盘盈落在未指定 —— 这几条路不能拒,所以在这里被标出来。
--   读它的:批次页的横幅 · /inventory/storage-safety · operations_now 的 quarantine_required 臂。下一次移动只能进隔离(Q19)。
--   【属主视图 + 逐行谓词】进料行 module.inbound.view,产出行 module.output.view。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE VIEW public.quarantine_exposure WITH (security_invoker = off) AS
 SELECT q.batch_kind,
    q.batch_id,
    q.batch_code,
    q.safety_state_code,
    d.name_en,
    d.name_zh,
    q.recorded_on,
    q.location_id,
    l.code AS location_code,
    q.qty
   FROM ( SELECT 'inbound'::text AS batch_kind,
            b.id AS batch_id,
            b.code AS batch_code,
            s.safety_state_code,
            (s.created_at AT TIME ZONE 'Asia/Singapore'::text)::date AS recorded_on,
            mv.location_id,
            sum(mv.qty_delta) AS qty
           FROM inbound_batch_safety_states s
             JOIN inbound_safety_states sd ON sd.code = s.safety_state_code AND sd.requires_quarantine IS TRUE
             JOIN inbound_batches b ON b.id = s.inbound_batch_id
             JOIN inventory_movements mv ON mv.inbound_batch_id = b.id
             LEFT JOIN storage_locations ml ON ml.id = mv.location_id
          WHERE s.ended_at IS NULL AND b.deleted_at IS NULL AND NOT COALESCE(ml.is_quarantine, false)
            AND has_permission('module.inbound.view'::text)
          GROUP BY b.id, b.code, s.safety_state_code, s.created_at, mv.location_id
         HAVING sum(mv.qty_delta) <> 0::numeric
        UNION ALL
         SELECT 'output'::text AS batch_kind,
            b.id AS batch_id,
            b.code AS batch_code,
            s.safety_state_code,
            (s.created_at AT TIME ZONE 'Asia/Singapore'::text)::date AS recorded_on,
            mv.location_id,
            sum(mv.qty_delta) AS qty
           FROM output_batch_safety_states s
             JOIN inbound_safety_states sd ON sd.code = s.safety_state_code AND sd.requires_quarantine IS TRUE
             JOIN output_batches b ON b.id = s.output_batch_id
             JOIN inventory_movements mv ON mv.output_batch_id = b.id
             LEFT JOIN storage_locations ml ON ml.id = mv.location_id
          WHERE s.ended_at IS NULL AND b.deleted_at IS NULL AND NOT COALESCE(ml.is_quarantine, false)
            AND has_permission('module.output.view'::text)
          GROUP BY b.id, b.code, s.safety_state_code, s.created_at, mv.location_id
         HAVING sum(mv.qty_delta) <> 0::numeric) q
     JOIN inbound_safety_states d ON d.code = q.safety_state_code
     LEFT JOIN storage_locations l ON l.id = q.location_id;

COMMENT ON VIEW public.quarantine_exposure IS
    'MES-3a:身上开着一条要隔离的状态(requires_quarantine,引导:鼓包或漏液)、却还有货放在非隔离库位(含未指定)的批 × 库位桶。只标出来,不拒(记下状态永远不拒,Q20);下一次移动只能进隔离。逐行谓词:进料 module.inbound.view,产出 module.output.view。';

GRANT SELECT ON public.quarantine_exposure TO authenticated;
REVOKE ALL ON public.quarantine_exposure FROM anon;

-- ── 12 · 改过的视图(镜像原样,CREATE OR REPLACE —— 列契约一字未动)──────────────────────

-- db/views/processing_wip.sql
-- PROC-WIRE-1B-ii(R3):在制品 —— 已被指定为下游工序投料、且还有余量的产出批。
--
-- ★【它是一个【投影】,不是一张表】★ R3:在制品不需要新对象。那一行就是
-- output_batches 里那一行(PROC-WIRE-1A 立的);再建一张 WIP 表会把同一批料
-- 数两遍,而两处迟早各说各话。fixture 166 L2 直接对着 pg_class 钉住这一条。
--
-- 【属主权限 + 体内谓词】(修法 (a))它跨 output 与 processing 两个模块 ——
-- invoker 会让一个只有 processing.view 的读者把每一行都丢掉,而**一块"在等什么"
-- 的屏幕空着,与"没有东西在等"长得一模一样**。
--
-- NOTE: introduced by db/migrations/2026-08-31-procwire1bii-an-assertion-that-cannot-see-must-refuse-by-name.sql.
-- First-run script. Re-running requires DROP VIEW first.

CREATE OR REPLACE VIEW public.processing_wip WITH (security_invoker = off) AS
 SELECT ob.id AS output_batch_id,
    ob.code AS batch_code,
    ob.material_id,
    m.code AS material_code,
    m.name AS material_name,
    ob.remaining_qty,
    ob.unit,
    ob.purpose_code,
    ob.awaiting_operation_type_code,
    ot.name_zh AS awaiting_operation_zh,
    ot.name_en AS awaiting_operation_en,
    ob.output_date,
    -- 【安全状态记了没有】—— 这块屏要能回答"这批为什么投不进去"。
    -- 【0 的意思是"没有人记过",不是"安全"】与那道闸同一个意思。
    (SELECT count(*) FROM public.output_batch_safety_states s
      WHERE s.output_batch_id = ob.id AND s.ended_at IS NULL) AS safety_states_recorded
   FROM public.output_batches ob
   JOIN public.materials m ON m.id = ob.material_id
   JOIN public.output_batch_purposes p ON p.code = ob.purpose_code
   LEFT JOIN public.operation_types ot ON ot.code = ob.awaiting_operation_type_code
  WHERE ob.deleted_at IS NULL
    AND p.is_saleable_stock IS FALSE      -- 【判据读的是那一列,不是写死的码】
    AND ob.remaining_qty > 0              -- 【吃光了就不在等了】
    AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_wip IS
'PROC-WIRE-1B-ii(R3):在制品 —— 已被指定为下游工序投料、且还有余量的产出批。

★【它是一个【投影】,不是一张表】★ 在制品那一行**就是** output_batches 里
那一行(PROC-WIRE-1A 立的)。建一张 WIP 表会让同一批料被数两遍,
而两处迟早各说各话。**本视图不存任何东西。**

【判据读的是 output_batch_purposes.is_saleable_stock 那一列,不是写死的码】
将来多一种不可售用途,这块屏自动跟着走。

【remaining_qty > 0】被工序吃光的投料不再"在等" —— 而它的 state 仍然不是"已售罄"
(那是另一条轴,合并会认下一笔从来没发生过的收入)。

【属主权限 + 体内谓词】(修法 (a))它跨 output(批次)与 processing(工序字典)
两个模块 —— invoker 会让一个只有 processing.view 的读者把每一行都丢掉,
而**一块"在等什么"的屏幕空着,与"没有东西在等"长得一模一样**。';

GRANT SELECT ON public.processing_wip TO authenticated;

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
-- 【MES-3a 加五支】(2026-10-06,MES-0 §5.1 V2 · V3 · V4 · V29;MES-3a Step 0 Q21 · Q31,Tim)
--   V2   一张执照对一类 NEA 废物的库存上限 —— 今天在效的那张执照 × 每一个启用的类别,没有 licence_storage_limits 行的一行
--        (去处:/purchasing/licences;门 module.suppliers.view)。由 NEA 执照条件给。类别列表是空的时它也是空的(V29 先来)。
--   V29  NEA 废物类别 —— 类别列表里一个启用的都没有时一行;有了之后,每一种没删、种类吃得下状态轴(电池料)而没有类别的物料一行
--        (去处:/settings/dictionaries 或那个物料;门 module.materials.view)。由 NEA 执照给。
--   V3   每一个启用的安全状态的滞留提醒天数 —— dwell_warning_days 为空的每个一行(去处:/settings/dictionaries;门 module.materials.view)。
--        由 Tim 与 WSH 负责人给,或执照的贮存条件。
--   V4   每一个启用的安全状态要不要隔离 —— requires_quarantine 为空的每个一行(同上)。引导只定了两个(鼓包或漏液 = 要,已放电 = 不要)。
--   V34  隔离库位 —— 有任何一个状态要隔离,而一个在用的隔离库位都没有时一行(去处:/inventory/locations;门 module.inventory.view)。
--        没有它,鼓包或漏液的料收不进来(QUARANTINE_LOCATION_REQUIRED)。由 Tim / 仓库在第一批这样的料到之前给。
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
            AND d.retired_at IS NULL AND d.interface_status <> 'reserved'::text AND d.capacity IS NULL
        UNION ALL
         SELECT 'V2'::text AS value_code,
            'module.suppliers.view'::text AS permission,
            cc.id AS item_id,
            c.code AS item_code,
            (cc.cert_no || ' · '::text) || c.name_en AS item_label,
            '/purchasing/licences'::text AS href
           FROM company_compliance cc
             CROSS JOIN nea_waste_categories c
          WHERE cc.id = storage_licence_in_force((now() AT TIME ZONE 'Asia/Singapore'::text)::date) AND c.is_active
            AND NOT (EXISTS ( SELECT 1
                   FROM licence_storage_limits l
                  WHERE l.licence_id = cc.id AND l.category_code = c.code))
        UNION ALL
         SELECT 'V29'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            'nea_waste_categories'::text AS item_code,
            'NEA waste categories'::text AS item_label,
            '/settings/dictionaries'::text AS href
          WHERE NOT (EXISTS ( SELECT 1
                   FROM nea_waste_categories c
                  WHERE c.is_active))
        UNION ALL
         SELECT 'V29'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.nea_waste_category_code IS NULL
            AND (EXISTS ( SELECT 1
                   FROM nea_waste_categories c
                  WHERE c.is_active))
        UNION ALL
         SELECT 'V3'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            st.code AS item_code,
            st.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM inbound_safety_states st
          WHERE st.is_active AND st.dwell_warning_days IS NULL
        UNION ALL
         SELECT 'V4'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            st.code AS item_code,
            st.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM inbound_safety_states st
          WHERE st.is_active AND st.requires_quarantine IS NULL
        UNION ALL
         SELECT 'V34'::text AS value_code,
            'module.inventory.view'::text AS permission,
            NULL::uuid AS item_id,
            'quarantine_location'::text AS item_code,
            'Quarantine location'::text AS item_label,
            '/inventory/locations'::text AS href
          WHERE (EXISTS ( SELECT 1
                   FROM inbound_safety_states st
                  WHERE st.is_active AND st.requires_quarantine IS TRUE))
            AND NOT (EXISTS ( SELECT 1
                   FROM storage_locations l
                  WHERE l.is_active AND l.is_quarantine))) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程);MES-3a 加 V2(执照 × 类别的库存上限)、V29(NEA 类别与物料的类别)、V3(每个安全状态的滞留提醒天数)、V4(每个安全状态要不要隔离)与 V34(隔离库位)。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

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
-- MES-3a(2026-10-06,MES-0 Q13 · Q35 · Q34;MES-3a Step 0 Q13 · Q16 · Q20,Tim):第 53–55 支 —— 三支都【只提醒,不拒】——
--   · storage_ceiling_exceeded:今天在效的执照下,一类 NEA 废物(或总量)的存量超过了给了的上限(storage_ceiling_status.status = exceeded)。
--     收货在超之前就被拒了,所以走到这里的是别的路:加工把料变成了另一类、回滚还回了料、上限被调低了。item_id = 执照,
--     item_code = 类别(总量是 *),门 module.inventory.view。
--   · safety_state_dwell:一批还在厂里的货,身上一条开着的状态待满了它的 dwell_warning_days(V3;没给的不上牌)。
--     一批 × 一条状态一行;item_date = 那条状态被记下的那一天,所以 days_waiting 就是它待了多久。doc_kind = inbound / output,
--     门逐行:进料 module.inbound.view,产出 module.output.view。
--   · quarantine_required:一批身上开着一条要隔离的状态(鼓包或漏液),却还有货放在非隔离库位(quarantine_exposure)。
--     一批 × 一个库位桶一行;doc_kind 与门同上;item_date = 那条状态被记下的那一天。
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
         SELECT 'storage_ceiling_exceeded'::text AS item_type,
            'module.inventory.view'::text AS permission,
            sc.licence_id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(sc.category_code, '*'::text) AS item_code,
            (((sc.cert_no || ' · '::text) || sc.name_en) || ' · '::text) || round(sc.on_hand_t, 3)::text || ' / '::text || sc.limit_tonnes::text || ' t'::text AS subject,
            (now() AT TIME ZONE 'Asia/Singapore'::text)::date AS item_date
           FROM storage_ceiling_status sc
          WHERE sc.status = 'exceeded'::text
        UNION ALL
         SELECT 'safety_state_dwell'::text AS item_type,
                CASE dw.batch_kind
                    WHEN 'inbound'::text THEN 'module.inbound.view'::text
                    ELSE 'module.output.view'::text
                END AS permission,
            dw.batch_id AS item_id,
            dw.batch_kind AS doc_kind,
            dw.batch_code AS item_code,
            dw.name_en AS subject,
            dw.recorded_on AS item_date
           FROM safety_state_dwell dw
          WHERE dw.dwell_status = 'past'::text AND dw.on_site
        UNION ALL
         SELECT 'quarantine_required'::text AS item_type,
                CASE qe.batch_kind
                    WHEN 'inbound'::text THEN 'module.inbound.view'::text
                    ELSE 'module.output.view'::text
                END AS permission,
            qe.batch_id AS item_id,
            qe.batch_kind AS doc_kind,
            qe.batch_code AS item_code,
            (qe.name_en || ' · '::text) || COALESCE(qe.location_code, 'unspecified'::text) AS subject,
            qe.recorded_on AS item_date
           FROM quarantine_exposure qe
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

-- ── 13 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)────────────────
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.nea_waste_categories
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.nea_waste_categories
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.licence_storage_limits
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.licence_storage_limits
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.receipt_ceiling_checks
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.receipt_ceiling_checks
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 14 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.set_inbound_safety_states(uuid, text[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_inbound_safety_states(uuid, text[], text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.set_output_safety_states(uuid, text[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_output_safety_states(uuid, text[], text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.save_storage_location(text, text, text[], uuid, text, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_storage_location(text, text, text[], uuid, text, text, boolean) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.receipt_ceiling_check_internal(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.receipt_ceiling_check_internal(uuid, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.assert_quarantine_landing(text[], uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assert_quarantine_landing(text[], uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.quantity_in_tonnes(numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.quantity_in_tonnes(numeric, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.storage_licence_in_force(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.storage_licence_in_force(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_safety_state_rows() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_safety_state_rows() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_ceiling_check_append_only() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_ceiling_check_append_only() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_movement_direct_insert() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_movement_direct_insert() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.receipt_ceiling_check_internal(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_quarantine_landing(text[], uuid) FROM authenticated;

-- ── 15 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes3a_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes3a_pending_after ON COMMIT DROP AS
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
    -- ① 授权一行都没动(本刀不加码、不改授权)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes3a_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes3a_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3A_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES3A_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes3a_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes3a_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES3A_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;变更记录只在两行引导上动了
    IF EXISTS ((SELECT b.k, b.id FROM mes3a_pending_before b EXCEPT SELECT a.k, a.id FROM mes3a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes3a_pending_after a EXCEPT SELECT b.k, b.id FROM mes3a_pending_before b)) THEN
        RAISE EXCEPTION 'MES3A_PROOF|a pending document changed state';
    END IF;
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM mes3a_log_before) AND c.table_name NOT IN ('inbound_safety_states', 'document_type_exceptions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3A_PROOF|change_log moved on %', v_bad; END IF;

    -- ④ 新表与类别都是空的;没有一个库位被标成隔离、没有一个滞留天数、没有一种物料有类别;引导只是那两格;开关是空的
    SELECT string_agg(t, ', ') INTO v_bad FROM unnest(ARRAY['nea_waste_categories', 'licence_storage_limits', 'receipt_ceiling_checks']) t
     WHERE (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', t), false, true, '')))[1]::text <> '0';
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3A_PROOF|new tables not empty: %', v_bad; END IF;
    IF EXISTS (SELECT 1 FROM storage_locations WHERE is_quarantine)
       OR EXISTS (SELECT 1 FROM inbound_safety_states WHERE dwell_warning_days IS NOT NULL)
       OR EXISTS (SELECT 1 FROM materials WHERE nea_waste_category_code IS NOT NULL) THEN
        RAISE EXCEPTION 'MES3A_PROOF|a quarantine location, dwell period or category was set';
    END IF;
    IF (SELECT string_agg(code || '=' || COALESCE(requires_quarantine::text, 'null'), ',' ORDER BY code) FROM inbound_safety_states)
       IS DISTINCT FROM 'charged_not_discharged=null,damaged_deformed=null,discharged_verified=false,swollen_leaking=true,water_exposed=null' THEN
        RAISE EXCEPTION 'MES3A_PROOF|requires_quarantine bootstrap is not as ruled';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES3A_PROOF|require_calibrated_since must stay empty';
    END IF;

    -- ⑤ 两张状态表:原来的行一行不少、原样开着(批次、状态、记录时刻、记录人),没有一行结束
    IF EXISTS ((SELECT sb.k, sb.b, sb.c, sb.created_at, sb.created_by FROM mes3a_states_before sb
                EXCEPT
                SELECT 'inbound', inbound_batch_id, safety_state_code, created_at, created_by FROM inbound_batch_safety_states WHERE ended_at IS NULL
                EXCEPT
                SELECT 'output', output_batch_id, safety_state_code, created_at, created_by FROM output_batch_safety_states WHERE ended_at IS NULL)) THEN
        RAISE EXCEPTION 'MES3A_PROOF|a safety-state row did not survive the re-key';
    END IF;
    IF EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE ended_at IS NOT NULL)
       OR EXISTS (SELECT 1 FROM output_batch_safety_states WHERE ended_at IS NOT NULL) THEN
        RAISE EXCEPTION 'MES3A_PROOF|a safety state was ended by the migration';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;员工那几支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到;旧的两支没了
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES3A_PROOF|anon executes: %', v_bad;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.set_inbound_safety_states(uuid, text[], text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.set_inbound_safety_states(uuid, text[], text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.set_inbound_safety_states(uuid, text[], text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES3A_PROOF|public.set_inbound_safety_states(uuid, text[], text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.set_output_safety_states(uuid, text[], text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.set_output_safety_states(uuid, text[], text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.set_output_safety_states(uuid, text[], text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES3A_PROOF|public.set_output_safety_states(uuid, text[], text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.save_storage_location(text, text, text[], uuid, text, text, boolean)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.save_storage_location(text, text, text[], uuid, text, text, boolean)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.save_storage_location(text, text, text[], uuid, text, text, boolean)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES3A_PROOF|public.save_storage_location(text, text, text[], uuid, text, text, boolean): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF has_function_privilege('authenticated', 'public.receipt_ceiling_check_internal(uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.receipt_ceiling_check_internal(uuid, uuid)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.receipt_ceiling_check_internal(uuid, uuid)'::regprocedure) THEN
        RAISE EXCEPTION 'MES3A_PROOF|public.receipt_ceiling_check_internal(uuid, uuid) must be an internal function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.assert_quarantine_landing(text[], uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.assert_quarantine_landing(text[], uuid)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.assert_quarantine_landing(text[], uuid)'::regprocedure) THEN
        RAISE EXCEPTION 'MES3A_PROOF|public.assert_quarantine_landing(text[], uuid) must be an internal function nobody outside can call';
    END IF;
    IF to_regprocedure('public.licence_storage_within_limit()') IS NOT NULL
       OR to_regprocedure('public.hazardous_qty_on_hand_tonnes()') IS NOT NULL
       OR to_regprocedure('public.set_inbound_safety_states(uuid, text[])') IS NOT NULL
       OR to_regprocedure('public.save_storage_location(text, text, text[], uuid, text, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES3A_PROOF|an old function or signature survived';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('nea_waste_categories', 'licence_storage_limits', 'receipt_ceiling_checks', 'nea_category_on_hand_all', 'storage_ceiling_status', 'safety_state_dwell', 'quarantine_exposure')
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3A_PROOF|anon can read %', v_bad; END IF;
    IF has_table_privilege('authenticated', 'public.nea_category_on_hand_all', 'SELECT') THEN
        RAISE EXCEPTION 'MES3A_PROOF|nea_category_on_hand_all must not be readable by authenticated';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条,没有一条落在新表上;两张状态表与库存流水上再没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES3A_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND tablename IN ('inbound_batch_safety_states', 'output_batch_safety_states', 'inventory_movements')
                 AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES3A_PROOF|a write policy remains on a state table or on inventory_movements';
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(三张新表都记,豁免仍是 7);遮蔽零缺口(仍是 105 条)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 7 THEN
        RAISE EXCEPTION 'MES3A_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES3A_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑨ 提醒臂 55 支
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 55 THEN
        RAISE EXCEPTION 'MES3A_PROOF|operations_now should have 55 arms';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes3a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES3A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes3a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES3A_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes3a_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
