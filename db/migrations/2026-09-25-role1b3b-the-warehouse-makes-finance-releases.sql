-- db/migrations/2026-09-25-role1b3b-the-warehouse-makes-finance-releases.sql
-- ROLE-1 Batch 3b —— 收货建单、工单、加工提交、回滚与注销归仓库;工单下达归财务,建单人永远不能下达。
-- 由 db/scripts/build_role1b3b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(ROLE-1 Batch 3 grilling Q1 · Q6–Q9,Tim 2026-09-25;Batch 3b grilling Q1–Q6,同日)
--   ① 七个新码,全部一并授给 admin(Tim 的常设裁定):
--      action.receive_goods(建收货单:create_inbound_batch · receive_inbound_batch_against_po)→ warehouse
--      action.batch_write_off(soft_delete_inbound_batch · soft_delete_output_batch)→ warehouse
--      action.wo_create(建工单;改 / 取消 / 关闭 = 它或 module.processing.edit)→ warehouse
--      action.wo_release(下达;建单人按人认永远不能下达 —— forbid_self_approval 早已在)→ finance
--      action.processing_commit · action.processing_rollback → warehouse
--      action.processing_aftercare(损耗分类与交接班 = 它或 module.processing.edit;Batch 3b Q2)→ warehouse
--      仓库另拿 module.processing.view(Q6);【不】拿 module.materials.view(Q8)。
--   ② create_work_order:建单人之外没有真持有人持 action.wo_release → WO_NO_OTHER_RELEASER(Batch 3b Q3)。
--   ③ 加工三张表不许绕过函数写(Q7 · Batch 3b Q1):runs / outputs 的 INSERT 策略、runs / outputs / inputs 的
--      DELETE 策略拿掉;guard_processing_direct_write 按名拒 PROCESSING_THROUGH_FUNCTION_ONLY(直连插、直连删、
--      runs 上直连改 status 或 work_order_id)。UPDATE 策略留着(登记)。
--   ④ material_lookup 的谓词加 module.processing.view(Batch 3b Q4);三页改读它(应用侧)。
--
-- 【不做什么】不碰审批开关与策略、user_roles、任何业务行;不动 COD 作废与发货(Q9);不动加工费用条目
-- (processing_cost_entries 仍归 module.processing.edit)与分摊(module.finance.edit,读 _all —— 3a 的裁定)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权 = 之前 + 裁定的那十五行;七个新码的持有人
-- 正好是裁定的角色;在途单据一张不少、一张不多;approval_log、journal_entries、工单、加工单(按状态)、产出、投料、
-- 损耗、收货与产出批次(全部 / 已注销)一行没变;五条策略没了、五支守卫触发器挂上;十三支函数的门换成新码;
-- 每一张在途单据(含草稿工单:下达人不是建单人)都还有一个决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B3B_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ('action.receive_goods', 'action.batch_write_off', 'action.wo_create', 'action.wo_release', 'action.processing_commit', 'action.processing_rollback', 'action.processing_aftercare')) THEN
        RAISE EXCEPTION 'ROLE1B3B_PRE|new codes already exist';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public'
         AND policyname IN ('processing_runs insert by permission', 'processing_runs delete by permission',
                            'processing_outputs insert by permission', 'processing_outputs delete by permission',
                            'processing_inputs delete by permission')) <> 5 THEN
        RAISE EXCEPTION 'ROLE1B3B_PRE|the five processing write policies are not all there to drop';
    END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                WHERE r.code = 'warehouse' AND rp.permission_code = 'module.processing.view') THEN
        RAISE EXCEPTION 'ROLE1B3B_PRE|warehouse already holds module.processing.view';
    END IF;
    -- 下达要读得到工单:finance 今天持 module.processing.view
    IF NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                    WHERE r.code = 'finance' AND rp.permission_code = 'module.processing.view') THEN
        RAISE EXCEPTION 'ROLE1B3B_PRE|finance does not hold module.processing.view';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE b3b_pending_before ON COMMIT DROP AS
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
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted';
CREATE TEMP TABLE b3b_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM work_orders) AS work_orders,
       (SELECT count(*) FROM work_orders WHERE status = 'released') AS work_orders_released,
       (SELECT count(*) FROM processing_runs WHERE status = 'committed') AS runs_committed,
       (SELECT count(*) FROM processing_runs WHERE status = 'reversed') AS runs_reversed,
       (SELECT count(*) FROM processing_outputs) AS processing_outputs,
       (SELECT count(*) FROM processing_inputs) AS processing_inputs,
       (SELECT count(*) FROM processing_run_losses) AS processing_run_losses,
       (SELECT count(*) FROM inbound_batches) AS receipts_all,
       (SELECT count(*) FROM inbound_batches WHERE deleted_at IS NOT NULL) AS receipts_written_off,
       (SELECT count(*) FROM output_batches) AS outputs_all,
       (SELECT count(*) FROM output_batches WHERE deleted_at IS NOT NULL) AS outputs_written_off,
       (SELECT count(*) FROM shift_handovers) AS shift_handovers;
CREATE TEMP TABLE b3b_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 目录:七个新码 ─────────────────────────────────────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.receive_goods', 'action', 'Create goods receipts', '建收货单', 'Create a goods receipt at the desk, or receive against a purchase order on the floor. Pricing a receipt stays with Price and reprice goods receipts; editing a receipt stays with Inbound (edit).', '在收货台建一张收货单,或在现场按采购单收货。给收货定价仍归「收货定价与改价」;修改收货单仍归「进料(编辑)」。', 1080),
    ('action.batch_write_off', 'action', 'Write off batches', '注销批次', 'Write off an inbound or an output batch, with a reason; the stock leaves the books. Until a write-off request exists, whoever holds this code does it alone.', '注销一个进料或产出批次,要写理由;这批货从账上离开。在注销申请落地之前,持这个码的人一个人做完。', 1090),
    ('action.wo_create', 'action', 'Create work orders', '建工单', 'Create a work order, and amend, cancel or close one (Processing (edit) may also amend, cancel and close). Releasing it is Release work orders; nobody releases a work order they created.', '建一张工单,以及修改、取消、关闭工单(「加工(编辑)」也可以改、取消、关闭)。下达是「下达工单」;没有人能下达自己建的工单。', 1100),
    ('action.wo_release', 'action', 'Release work orders', '下达工单', 'Release a draft work order so that processing runs can be committed against it. Nobody releases a work order they created (judged per person, across their accounts).', '下达一张草稿工单,之后才能照它提交加工。没有人能下达自己建的工单(按人认,跨账号)。', 1110),
    ('action.processing_commit', 'action', 'Commit processing runs', '提交加工', 'Commit a processing run: the inputs leave stock and the outputs are created, against a released work order or on their own. Allocating processing cost stays with Finance (edit).', '提交一次加工:投料出库、产出入库,照一张已下达的工单或单独一次。分摊加工成本仍归「财务(编辑)」。', 1120),
    ('action.processing_rollback', 'action', 'Roll back processing runs', '回滚加工', 'Reverse a committed processing run, with a reason: the inputs return to stock and the outputs are removed. Until a rollback request exists, whoever holds this code does it alone.', '回滚一次已提交的加工,要写理由:投料回库、产出撤掉。在回滚申请落地之前,持这个码的人一个人做完。', 1130),
    ('action.processing_aftercare', 'action', 'Record run losses and shift handovers', '记录加工损耗与交接班', 'Record the loss categories of a processing run, and submit or acknowledge a shift handover. Processing cost entries stay with Processing (edit).', '记录一次加工的损耗分类,以及提交、确认交接班。加工费用条目仍归「加工(编辑)」。', 1140);

-- ── 2 · 授权(在函数之前:下面的自证要问到它们)────────────────────────────────
-- 仓库做、财务下达;admin 七个都拿(Tim 的常设裁定);仓库另拿 module.processing.view。幂等。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, g.c FROM roles r
  JOIN (VALUES ('warehouse', 'action.receive_goods'),
               ('warehouse', 'action.batch_write_off'),
               ('warehouse', 'action.wo_create'),
               ('warehouse', 'action.processing_commit'),
               ('warehouse', 'action.processing_rollback'),
               ('warehouse', 'action.processing_aftercare'),
               ('admin', 'action.receive_goods'),
               ('admin', 'action.batch_write_off'),
               ('admin', 'action.wo_create'),
               ('admin', 'action.wo_release'),
               ('admin', 'action.processing_commit'),
               ('admin', 'action.processing_rollback'),
               ('admin', 'action.processing_aftercare'),
               ('finance', 'action.wo_release'),
               ('warehouse', 'module.processing.view')) g(role_code, c)
    ON g.role_code = r.code
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 3 · 守卫函数(新;触发器要用到它)────────────────────────────────────────

-- db/functions/guard_processing_direct_write.sql
-- ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q7;Batch 3b grilling Q1):**加工的三张表不许绕过函数写**。
--
-- 【Step 0 量出来的侧门】processing_runs / processing_outputs 的 INSERT 策略、以及三张表(再加
-- processing_inputs)的 DELETE 策略都开在 module.processing.edit 上:任何持它的人不经
-- commit_processing_run 就能直连插一张 status = 'committed' 的加工单(库存与总账一行没动),
-- 不经 rollback_processing_run 就能把一张已提交的单改成 reversed、改挂到另一张工单上,或者整行硬删。
-- 提交归仓库(action.processing_commit)、回滚归仓库(action.processing_rollback)都是空话,
-- 除非这几扇门关上。Step 0 实测:app/、lib/、scripts/ 里【没有一处】直连写这三张表(全是读)。
--
-- 【怎么关】INSERT 策略(runs · outputs)与 DELETE 策略(runs · outputs · inputs)拿掉;
-- UPDATE 策略留着(登记 ROLE1B3B-PROCESSING-UPDATE-POLICIES),但 processing_runs 上改 status 或
-- work_order_id 按名拒。本守卫挂成:
--   · processing_runs    —— 行级 BEFORE INSERT OR UPDATE(UPDATE 只在 status / work_order_id 变了时拒)
--                           + 语句级 BEFORE DELETE
--   · processing_outputs —— 行级 BEFORE INSERT + 语句级 BEFORE DELETE
--   · processing_inputs  —— 语句级 BEFORE DELETE(直连 INSERT 早由 guard_processing_input 按名拒)
-- 语句级那一支零行也照样触发(没有 DELETE 策略时直连 DELETE 是零行、不报错 —— SILENT-1 那一族)。
-- 按名拒 PROCESSING_THROUGH_FUNCTION_ONLY|表|动作。属主路径(row_security_active = false:
-- SECURITY DEFINER 的提交 / 回滚、迁移、种子)一律放行。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径;理由见 guard_lock_reopen_path 的抬头。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b3b-the-warehouse-makes-finance-releases.sql.

CREATE OR REPLACE FUNCTION public.guard_processing_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        IF TG_LEVEL = 'ROW' THEN
            RETURN NEW;
        END IF;
        RETURN NULL;
    END IF;
    -- 只挂在 processing_runs 的行级 UPDATE 上:别的列照旧走 UPDATE 策略。
    IF TG_OP = 'UPDATE' THEN
        IF NEW.status IS NOT DISTINCT FROM OLD.status
           AND NEW.work_order_id IS NOT DISTINCT FROM OLD.work_order_id THEN
            RETURN NEW;
        END IF;
    END IF;
    RAISE EXCEPTION 'PROCESSING_THROUGH_FUNCTION_ONLY|%|%', TG_TABLE_NAME, lower(TG_OP);
END;
$function$;

COMMENT ON FUNCTION public.guard_processing_direct_write() IS
'ROLE-1 Batch 3b:processing_runs / processing_outputs 的直连 INSERT、三张加工表(再加 processing_inputs)的直连 DELETE、以及 processing_runs 上直连改 status 或 work_order_id,按名拒 PROCESSING_THROUGH_FUNCTION_ONLY|表|动作。提交走 commit_processing_run(action.processing_commit),回滚走 rollback_processing_run(action.processing_rollback),两支都是 SECURITY DEFINER。属主路径放行。';

-- ── 4 · 加工三张表:INSERT / DELETE 写策略拿掉,直连写按名拒 ─────────────────────
DROP POLICY "processing_runs insert by permission" ON public.processing_runs;
DROP POLICY "processing_runs delete by permission" ON public.processing_runs;
DROP POLICY "processing_outputs insert by permission" ON public.processing_outputs;
DROP POLICY "processing_outputs delete by permission" ON public.processing_outputs;
DROP POLICY "processing_inputs delete by permission" ON public.processing_inputs;
CREATE TRIGGER trg_processing_runs_direct_write
    BEFORE INSERT OR UPDATE ON public.processing_runs
    FOR EACH ROW EXECUTE FUNCTION public.guard_processing_direct_write();
CREATE TRIGGER trg_processing_runs_direct_delete
    BEFORE DELETE ON public.processing_runs
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_processing_direct_write();
CREATE TRIGGER trg_processing_outputs_direct_write
    BEFORE INSERT ON public.processing_outputs
    FOR EACH ROW EXECUTE FUNCTION public.guard_processing_direct_write();
CREATE TRIGGER trg_processing_outputs_direct_delete
    BEFORE DELETE ON public.processing_outputs
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_processing_direct_write();
CREATE TRIGGER trg_processing_inputs_direct_delete
    BEFORE DELETE ON public.processing_inputs
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_processing_direct_write();

-- ── 5 · 损耗分类:module.processing.edit 或 action.processing_aftercare ────────────
DROP POLICY "processing_run_losses insert by permission" ON public.processing_run_losses;
CREATE POLICY "processing_run_losses insert by permission"
    ON public.processing_run_losses AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_any_permission(ARRAY['module.processing.edit'::text, 'action.processing_aftercare'::text]));
DROP POLICY "processing_run_losses update by permission" ON public.processing_run_losses;
CREATE POLICY "processing_run_losses update by permission"
    ON public.processing_run_losses AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_any_permission(ARRAY['module.processing.edit'::text, 'action.processing_aftercare'::text]))
    WITH CHECK (has_any_permission(ARRAY['module.processing.edit'::text, 'action.processing_aftercare'::text]));
DROP POLICY "processing_run_losses delete by permission" ON public.processing_run_losses;
CREATE POLICY "processing_run_losses delete by permission"
    ON public.processing_run_losses AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_any_permission(ARRAY['module.processing.edit'::text, 'action.processing_aftercare'::text]));
DROP TRIGGER enforce_write_permission ON public.processing_run_losses;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.processing_run_losses
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit', 'action.processing_aftercare');

-- ── 6 · material_lookup:谓词加 module.processing.view(列清单不变)────────────────
CREATE OR REPLACE VIEW public.material_lookup WITH (security_invoker = off) AS
 SELECT m.id,
    m.code,
    m.name,
    m.deleted_at,
    m.unit,
    m.kind_code,
    k.name_en AS kind_name_en,
    k.name_zh AS kind_name_zh,
    m.waste_classification_code
   FROM materials m
     LEFT JOIN material_kinds k ON k.code = m.kind_code
  WHERE has_permission('module.materials.view'::text) OR has_permission('module.inbound.view'::text) OR has_permission('module.output.view'::text) OR has_permission('module.inventory.view'::text) OR has_permission('module.purchasing.view'::text) OR has_permission('module.processing.view'::text);

-- ── 7 · 函数(镜像原样)──────────────────────────────────────────────────────

-- ─── create_inbound_batch
CREATE OR REPLACE FUNCTION public.create_inbound_batch(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date, p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text, p_currency text DEFAULT NULL::text)
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

-- ─── receive_inbound_batch_against_po
CREATE OR REPLACE FUNCTION public.receive_inbound_batch_against_po(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_arrival_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text)
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
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$

;

-- ─── soft_delete_inbound_batch
CREATE OR REPLACE FUNCTION public.soft_delete_inbound_batch(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_code text;
    v_open numeric;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q9):注销批次归仓库 —— action.batch_write_off
    --   (warehouse · admin),在注销申请(CFO 批)落地之前一个人做完。
    PERFORM require_permission('action.batch_write_off');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        -- 【理由必填,而且拒绝要按名】注销一批料是一次真实的物理事件
        -- (它会写一条 writeoff 流水)。没有理由的注销,事后没有人答得出为什么。
        RAISE EXCEPTION 'DELETE_REASON_REQUIRED|inbound_batches|%',
            COALESCE((SELECT code FROM inbound_batches WHERE id = p_batch_id), '?');
    END IF;

    SELECT code INTO v_code FROM inbound_batches
     WHERE id = p_batch_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;

    -- ★ ROLE-1 Batch 4b(Tim 的 Q5):挂着一张在等 CFO 的定价申请时不许注销 —— 先撤回或等它被决定。
    --   guard_inbound_batch_price_request 在 UPDATE 上还有第二道。
    IF receipt_price_open(p_batch_id) IS NOT NULL THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_OPEN|%|%', v_code, receipt_price_open(p_batch_id);
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- AP-RECON-1(Tim AP-RECON-0 Q2):【还欠着供应商钱的已计价批次,不许注销】
    --   注销只写一条 writeoff 流水(借 5200 / 贷 1200)—— 存货拿走了,那笔计价分录记下的
    --   【应付】却原样留在 2000 上。而每一个应付读者(ap_open_items、ap_aging_asof、
    --   record_payment_internal)都过滤 deleted_at IS NULL:于是那笔债从清单上消失、
    --   付款也核销不进去,只剩手工分录一条路。IN-2026-0154 的 4,032.00 就是这样来的
    --   (测试数据,不修,记在 known-wrong-until-cutover)。
    --   欠款 = 数量×单价 − 已过账付款的核销 − 预付冲抵 —— 与 ap_open_items 进料支同一条算术。
    --   【读基表,不读 ap_open_items】本函数的门是 action.batch_write_off(ROLE-1 Batch 3b 之前是 inbound.edit);那张视图对没有
    --   finance.view 的读者是 0 行,读它会让一个仓库账号的"欠款为 0"成为一句假话,于是放行。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT round(round(ib.quantity * ib.unit_price, 2)
                 - COALESCE((SELECT sum(pa.allocated_ccy)
                               FROM payment_allocations pa
                               JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                              WHERE pa.inbound_batch_id = ib.id), 0)
                 - COALESCE((SELECT sum(ppa.amount_base)
                               FROM prepayment_applications ppa
                              WHERE ppa.inbound_batch_id = ib.id), 0), 2)
      INTO v_open
      FROM inbound_batches ib
     WHERE ib.id = p_batch_id AND ib.unit_price IS NOT NULL;
    IF COALESCE(v_open, 0) > 0 THEN
        RAISE EXCEPTION 'INBOUND_HAS_OPEN_PAYABLE|%|%', v_code, v_open
          USING HINT = '这批货的计价还欠着供应商这笔钱(它在应付 2000 上)—— 注销会让它从应付清单上消失、再也付不进来。先付清,或先把价格更正过来;实物损失不是注销单据的理由';
    END IF;

    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE inbound_batches
       SET deleted_at = now(), deleted_by = v_user, delete_reason = btrim(p_reason),
           updated_by = v_user, updated_at = now()
     WHERE id = p_batch_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);

    -- ── COD-1:注销掉的料【不是被处理掉的】────────────────────────────────
    -- 实测:线上 11 张 remaining_qty = 0 的进料批里 8 张是这一类。
    -- 一张已签发的证书在这里作废 —— 它说的是"我们处理了你的料",而这票货被报废了。
    PERFORM refresh_cod_for_batch(p_batch_id);

    RETURN jsonb_build_object('id', p_batch_id, 'code', v_code, 'deleted_by', v_user);
END;
$function$;

-- ─── soft_delete_output_batch
CREATE OR REPLACE FUNCTION public.soft_delete_output_batch(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_code text;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q9):注销批次归仓库 —— action.batch_write_off。
    PERFORM require_permission('action.batch_write_off');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DELETE_REASON_REQUIRED|output_batches|%',
            COALESCE((SELECT code FROM output_batches WHERE id = p_batch_id), '?');
    END IF;

    SELECT code INTO v_code FROM output_batches
     WHERE id = p_batch_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;

    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE output_batches
       SET deleted_at = now(), deleted_by = v_user, delete_reason = btrim(p_reason),
           updated_by = v_user, updated_at = now()
     WHERE id = p_batch_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);

    RETURN jsonb_build_object('id', p_batch_id, 'code', v_code, 'deleted_by', v_user);
END;
$function$;

-- ─── create_work_order
CREATE OR REPLACE FUNCTION public.create_work_order(p_lines jsonb, p_expected jsonb DEFAULT NULL::jsonb, p_scheduled_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_code text;
    v_elem jsonb;
    v_mat  uuid;
    v_qty  numeric;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25):建工单归仓库 —— action.wo_create(warehouse · admin);
    --   下达归财务(action.wo_release),建单人永远不能下达(release_work_order 里的 forbid_self_approval,按人认)。
    PERFORM require_permission('action.wo_create');
    -- ★ Batch 3b grilling Q3:建单人之外没有人下达得了,就不让它生下来 —— 否则它是一张永远的草稿。
    --   "有人" = 一个真持有人(real_role_grants:未撤销 / 已确认 / 未封禁 / 未删除)持 action.wo_release,
    --   而且不是同一个人(self_leg 按人认,跨账号)。与下达那一侧的四眼一样,不看审批开关。
    IF NOT EXISTS (SELECT 1
                     FROM role_permissions rp
                     JOIN roles r ON r.id = rp.role_id
                    CROSS JOIN LATERAL real_role_grants(r.code) g
                    WHERE rp.permission_code = 'action.wo_release'
                      AND self_leg(v_user, NULL::uuid, g.user_id) = 'none') THEN
        RAISE EXCEPTION 'WO_NO_OTHER_RELEASER';
    END IF;

    -- 【拒绝的顺序就是"人下一步该改什么"的顺序】两条同时不成立时,先说哪一条
    -- 决定了他打开哪个输入框(与 record_invoice_issue 的四条同一条道理)。
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'WO_NO_LINES';
    END IF;

    -- 投料行:先把每一行自己看一遍,再看行与行之间
    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_qty := (v_elem->>'planned_qty')::numeric;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'WO_LINE_QTY_INVALID';
        END IF;
        v_mat := (v_elem->>'material_id')::uuid;
        IF v_mat IS NULL OR NOT EXISTS (
            SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'WO_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
        END IF;
    END LOOP;
    -- 【重复物料按名拒,而不是靠唯一约束抛 23505】约束是兜底,不是文案:
    -- 一条 duplicate key value violates unique constraint 到不了人眼里就是机器串。
    SELECT (elem->>'material_id')::uuid INTO v_mat
      FROM jsonb_array_elements(p_lines) elem
     GROUP BY 1 HAVING count(*) > 1 LIMIT 1;
    IF v_mat IS NOT NULL THEN
        RAISE EXCEPTION 'WO_DUPLICATE_MATERIAL|%', v_mat;
    END IF;

    -- 预期产出:【可以整个不给】—— 没有预期是一种诚实的状态,不是缺失。
    IF p_expected IS NOT NULL AND jsonb_typeof(p_expected) = 'array'
       AND jsonb_array_length(p_expected) > 0 THEN
        FOR v_elem IN SELECT * FROM jsonb_array_elements(p_expected)
        LOOP
            v_qty := (v_elem->>'expected_qty')::numeric;
            IF v_qty IS NULL OR v_qty <= 0 THEN
                RAISE EXCEPTION 'WO_EXPECTED_QTY_INVALID';
            END IF;
            v_mat := (v_elem->>'material_id')::uuid;
            IF v_mat IS NULL OR NOT EXISTS (
                SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'WO_EXPECTED_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
            END IF;
        END LOOP;
        SELECT (elem->>'material_id')::uuid INTO v_mat
          FROM jsonb_array_elements(p_expected) elem
         GROUP BY 1 HAVING count(*) > 1 LIMIT 1;
        IF v_mat IS NOT NULL THEN
            RAISE EXCEPTION 'WO_DUPLICATE_EXPECTED|%', v_mat;
        END IF;
    END IF;

    v_code := next_work_order_code(COALESCE(p_scheduled_date, CURRENT_DATE));
    -- 【注意这个 COALESCE 是给【年份】用的,不是给 scheduled_date 用的】
    -- 存进表里的仍然是 p_scheduled_date 本身(可以是 NULL)。取号要一个年份,
    -- 而"没排期"的单子只能落在今年 —— 这与"永不给日期默认值"不冲突:
    -- 被默认的是号码的年段,不是那句对外的承诺。
    INSERT INTO work_orders (code, status, scheduled_date, notes, created_by, updated_by)
    VALUES (v_code, 'draft', p_scheduled_date, NULLIF(btrim(COALESCE(p_notes,'')), ''), v_user, v_user)
    RETURNING id INTO v_id;

    INSERT INTO work_order_lines (work_order_id, material_id, planned_qty)
    SELECT v_id, (elem->>'material_id')::uuid, (elem->>'planned_qty')::numeric
      FROM jsonb_array_elements(p_lines) elem;

    IF p_expected IS NOT NULL AND jsonb_typeof(p_expected) = 'array'
       AND jsonb_array_length(p_expected) > 0 THEN
        -- ════════════════════════════════════════════════════════════════
        -- PROC-SUPPORT-1(R3):每一条预期产出必须说出它的【出处】。
        -- 【自己一条码,不与 WO_EXPECTED_QTY_INVALID 合并】下一步动作不同:
        --   · 数量非法 → 回去改那个数;
        --   · 出处没说 → 回去说这个数【是怎么来的】。
        -- 后者不是一次数据校验,是这一列存在的全部理由 —— 六个月后要分得出
        -- "被真实生产验证过的"与"当初那个猜测"。
        -- 【空字符串与缺席一样被拒】—— 一个空串在数据库里不是 NULL,却和
        -- "没人说过"是同一件事,而它会绕过 NOT NULL 类的检查。
        -- ════════════════════════════════════════════════════════════════
        -- 【一条谓词同时管住"没说"与"说错了"】btrim 之后的空串落不进那三个
        -- 取值里,所以缺席、空串、错值走的是同一条拒绝 —— 它们对操作员是同一件事:
        -- 【这一栏还没有一个正当的答案】。
        IF EXISTS (
            SELECT 1 FROM jsonb_array_elements(p_expected) elem
             WHERE btrim(COALESCE(elem->>'basis',''))
                   NOT IN ('planner_estimate','seeded_industry','calibrated')
        ) THEN
            RAISE EXCEPTION 'WO_EXPECTED_BASIS_REQUIRED'
              USING HINT = '每一条预期产出都要说出它是怎么来的:排计划的人估的、照行业经验播的、还是对着真实生产校准过的。没有默认值 —— 漏填是一次失败,不是悄悄补上一个看起来像答案的值。';
        END IF;

        INSERT INTO work_order_expected_outputs (work_order_id, material_id, expected_qty, basis, basis_reference)
        SELECT v_id, (elem->>'material_id')::uuid, (elem->>'expected_qty')::numeric,
               btrim(elem->>'basis'),
               NULLIF(btrim(COALESCE(elem->>'basis_reference','')), '')
          FROM jsonb_array_elements(p_expected) elem;
    END IF;

    INSERT INTO work_order_history (work_order_id, change_type, detail, changed_by)
    VALUES (v_id, 'created', v_code, v_user);

    RETURN jsonb_build_object('work_order_id', v_id, 'code', v_code, 'status', 'draft');
END;
$function$;

-- ─── amend_work_order
CREATE OR REPLACE FUNCTION public.amend_work_order(p_work_order_id uuid, p_reason text, p_scheduled_date date DEFAULT NULL::date, p_set_scheduled boolean DEFAULT false, p_notes text DEFAULT NULL::text, p_set_notes boolean DEFAULT false, p_lines jsonb DEFAULT NULL::jsonb, p_expected jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_wo       work_orders%ROWTYPE;
    v_elem     jsonb;
    v_line     work_order_lines%ROWTYPE;
    v_exp      work_order_expected_outputs%ROWTYPE;
    v_basis    text;   -- PROC-SUPPORT-1(R3):这一条预期产出的出处
    v_ref      text;   -- 同上,凭据(自由文本)
    v_mat      uuid;
    v_qty      numeric;
    v_consumed numeric;
    v_changes  integer := 0;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q6):改 / 取消 / 关闭工单 = action.wo_create
    --   (仓库)或 module.processing.edit(cco · cto 留着它们的宽码)。拒绝点名 action.wo_create。
    IF NOT has_any_permission(ARRAY['action.wo_create', 'module.processing.edit']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.wo_create';
    END IF;
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status NOT IN ('draft','released') THEN
        RAISE EXCEPTION 'WO_NOT_AMENDABLE|%|%', v_wo.code, v_wo.status;
    END IF;
    -- 【理由必填,而且在动手之前就问】—— 一次没有理由的计划改动,过两天没人
    -- 说得清当时是为了什么(与 hold_stock 的 STK_REASON_REQUIRED 同一条)。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_AMEND_REASON_REQUIRED|%', v_wo.code;
    END IF;

    -- ── 表头 ────────────────────────────────────────────────────────────────
    -- 【为什么要 p_set_* 这个布尔】NULL 在这里有两个意思:"不改这一项"与
    -- "把它清空"。少了这个开关,"取消排期"就表达不出来 —— 而取消排期是一件
    -- 真实的事(计划推迟到不知道什么时候)。
    IF p_set_scheduled AND p_scheduled_date IS DISTINCT FROM v_wo.scheduled_date THEN
        INSERT INTO work_order_history (work_order_id, change_type,
                    old_scheduled_date, new_scheduled_date, amend_reason, changed_by)
        VALUES (p_work_order_id, 'header_update', v_wo.scheduled_date, p_scheduled_date,
                btrim(p_reason), v_user);
        UPDATE work_orders SET scheduled_date = p_scheduled_date WHERE id = p_work_order_id;
        v_changes := v_changes + 1;
    END IF;
    IF p_set_notes AND NULLIF(btrim(COALESCE(p_notes,'')),'') IS DISTINCT FROM v_wo.notes THEN
        INSERT INTO work_order_history (work_order_id, change_type,
                    old_notes, new_notes, amend_reason, changed_by)
        VALUES (p_work_order_id, 'header_update', v_wo.notes,
                NULLIF(btrim(COALESCE(p_notes,'')),''), btrim(p_reason), v_user);
        UPDATE work_orders SET notes = NULLIF(btrim(COALESCE(p_notes,'')),'')
         WHERE id = p_work_order_id;
        v_changes := v_changes + 1;
    END IF;

    -- ── 计划投料行 ──────────────────────────────────────────────────────────
    -- 每个元素:{material_id, planned_qty}。planned_qty 省略或为 null = 删这一行。
    IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
        FOR v_elem IN SELECT * FROM jsonb_array_elements(p_lines)
        LOOP
            v_mat := (v_elem->>'material_id')::uuid;
            IF v_mat IS NULL OR NOT EXISTS (
                SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'WO_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
            END IF;
            v_qty := (v_elem->>'planned_qty')::numeric;

            -- 【地板:已经吃掉的量】—— 挂在这张工单上的加工单,吃掉了多少这种料。
            -- 投料腿指向批次,批次才有物料,所以两侧都要 join 过去(进料批与
            -- 再加工的产出批各一条腿,FIN-25 的 XOR)。
            SELECT COALESCE(sum(pi.quantity_consumed), 0) INTO v_consumed
              FROM processing_runs r
              JOIN processing_inputs pi ON pi.run_id = r.id
              LEFT JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
              LEFT JOIN output_batches  ob ON ob.id = pi.output_batch_id
             WHERE r.work_order_id = p_work_order_id
               AND r.deleted_at IS NULL
               AND r.status = 'committed'
               AND COALESCE(ib.material_id, ob.material_id) = v_mat;

            SELECT * INTO v_line FROM work_order_lines
             WHERE work_order_id = p_work_order_id AND material_id = v_mat;

            IF v_qty IS NULL THEN
                -- 删行
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'WO_LINE_NOT_FOUND|%', v_mat;
                END IF;
                -- 【删掉一条已经吃过料的行,与把它改成 0 是同一件事】所以同一道地板
                IF v_consumed > 0 THEN
                    RAISE EXCEPTION 'WO_LINE_BELOW_CONSUMED|%|%|%', v_mat, 0, v_consumed;
                END IF;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_line_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'line_remove', v_line.id, v_mat,
                        v_line.planned_qty, NULL, btrim(p_reason), v_user);
                DELETE FROM work_order_lines WHERE id = v_line.id;
                v_changes := v_changes + 1;
            ELSIF v_qty <= 0 THEN
                RAISE EXCEPTION 'WO_LINE_QTY_INVALID';
            ELSIF NOT FOUND THEN
                -- 加行
                INSERT INTO work_order_lines (work_order_id, material_id, planned_qty)
                VALUES (p_work_order_id, v_mat, v_qty) RETURNING * INTO v_line;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_line_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'line_add', v_line.id, v_mat, NULL, v_qty,
                        btrim(p_reason), v_user);
                v_changes := v_changes + 1;
            ELSIF v_qty IS DISTINCT FROM v_line.planned_qty THEN
                -- 改量 —— 地板在这里
                IF v_qty < v_consumed THEN
                    RAISE EXCEPTION 'WO_LINE_BELOW_CONSUMED|%|%|%', v_mat, v_qty, v_consumed;
                END IF;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_line_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'line_update', v_line.id, v_mat,
                        v_line.planned_qty, v_qty, btrim(p_reason), v_user);
                UPDATE work_order_lines SET planned_qty = v_qty WHERE id = v_line.id;
                v_changes := v_changes + 1;
            END IF;
        END LOOP;
    END IF;

    -- ── 预期产出行 ──────────────────────────────────────────────────────────
    -- 【预期产出没有地板】它是一句估计,不是一个已经发生的事实 —— 改小它不会
    -- 与任何已经发生的事情矛盾。这与计划投料行刻意不同,而不同的理由值得写下来:
    -- 地板护的是"实绩不可否认",预期产出这一侧没有实绩可否认。
    IF p_expected IS NOT NULL AND jsonb_typeof(p_expected) = 'array' THEN
        FOR v_elem IN SELECT * FROM jsonb_array_elements(p_expected)
        LOOP
            v_mat := (v_elem->>'material_id')::uuid;
            IF v_mat IS NULL OR NOT EXISTS (
                SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'WO_EXPECTED_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
            END IF;
            v_qty := (v_elem->>'expected_qty')::numeric;
            -- PROC-SUPPORT-1(R3):出处。**改一行预期产出时它是可选的** ——
            -- 不给就是"这一次不改出处",给了就必须是三个取值之一。
            -- 【新增一行时它是必填的】,那一条在下面的 add 分支里。
            v_basis := NULLIF(btrim(COALESCE(v_elem->>'basis','')), '');
            v_ref   := NULLIF(btrim(COALESCE(v_elem->>'basis_reference','')), '');
            IF v_basis IS NOT NULL
               AND v_basis NOT IN ('planner_estimate','seeded_industry','calibrated') THEN
                RAISE EXCEPTION 'WO_EXPECTED_BASIS_REQUIRED'
                  USING HINT = '出处只有三个取值:planner_estimate / seeded_industry / calibrated。';
            END IF;
            SELECT * INTO v_exp FROM work_order_expected_outputs
             WHERE work_order_id = p_work_order_id AND material_id = v_mat;

            IF v_qty IS NULL THEN
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'WO_EXPECTED_NOT_FOUND|%', v_mat;
                END IF;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_expected_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'expected_remove', v_exp.id, v_mat,
                        v_exp.expected_qty, NULL, btrim(p_reason), v_user);
                DELETE FROM work_order_expected_outputs WHERE id = v_exp.id;
                v_changes := v_changes + 1;
            ELSIF v_qty <= 0 THEN
                RAISE EXCEPTION 'WO_EXPECTED_QTY_INVALID';
            ELSIF NOT FOUND THEN
                -- PROC-SUPPORT-1(R3):**新增一行必须说出出处。**
                IF v_basis IS NULL THEN
                    RAISE EXCEPTION 'WO_EXPECTED_BASIS_REQUIRED'
                      USING HINT = '新增一条预期产出要说出它是怎么来的:排计划的人估的、照行业经验播的、还是对着真实生产校准过的。';
                END IF;
                INSERT INTO work_order_expected_outputs (work_order_id, material_id, expected_qty, basis, basis_reference)
                VALUES (p_work_order_id, v_mat, v_qty, v_basis, v_ref) RETURNING * INTO v_exp;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_expected_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'expected_add', v_exp.id, v_mat, NULL, v_qty,
                        btrim(p_reason), v_user);
                v_changes := v_changes + 1;
            ELSIF v_qty IS DISTINCT FROM v_exp.expected_qty
                  OR (v_basis IS NOT NULL AND v_basis IS DISTINCT FROM v_exp.basis)
                  OR (jsonb_exists(v_elem, 'basis_reference')
                      AND v_ref IS DISTINCT FROM v_exp.basis_reference) THEN
                -- ════════════════════════════════════════════════════════════
                -- PROC-SUPPORT-1(R3):**改出处也算一次改动,而且要留痕。**
                -- 一个数从 seeded_industry 变成 calibrated,是这张表上
                -- 【最重要】的一次变化 —— 那是"猜的"变成"验证过的"那一刻。
                -- 让它悄悄发生,六个月后就没有人说得出它是什么时候变的。
                -- 【出处的新旧值写进 detail】—— old_qty/new_qty 那一对是给数字的,
                -- 借用它去装文本会让那一对的含义在第二种用法上就开始漂。
                -- ════════════════════════════════════════════════════════════
                INSERT INTO work_order_history (work_order_id, change_type, work_order_expected_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by, detail)
                VALUES (p_work_order_id, 'expected_update', v_exp.id, v_mat,
                        v_exp.expected_qty, v_qty, btrim(p_reason), v_user,
                        CASE WHEN v_basis IS NOT NULL AND v_basis IS DISTINCT FROM v_exp.basis
                             THEN format('basis: %s -> %s', COALESCE(v_exp.basis, '(none stated)'), v_basis)
                        END);
                UPDATE work_order_expected_outputs
                   SET expected_qty    = v_qty,
                       basis           = COALESCE(v_basis, basis),
                       basis_reference = CASE WHEN jsonb_exists(v_elem, 'basis_reference')
                                              THEN v_ref ELSE basis_reference END
                 WHERE id = v_exp.id;
                v_changes := v_changes + 1;
            END IF;
        END LOOP;
    END IF;

    IF v_changes = 0 THEN
        RAISE EXCEPTION 'WO_AMEND_NO_CHANGES|%', v_wo.code;
    END IF;

    UPDATE work_orders SET updated_at = now(), updated_by = v_user WHERE id = p_work_order_id;
    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'changes', v_changes);
END;
$function$;

-- ─── cancel_work_order
CREATE OR REPLACE FUNCTION public.cancel_work_order(p_work_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_wo   work_orders%ROWTYPE;
    v_runs integer;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q6):改 / 取消 / 关闭工单 = action.wo_create
    --   (仓库)或 module.processing.edit(cco · cto 留着它们的宽码)。拒绝点名 action.wo_create。
    IF NOT has_any_permission(ARRAY['action.wo_create', 'module.processing.edit']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.wo_create';
    END IF;
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status NOT IN ('draft','released') THEN
        RAISE EXCEPTION 'WO_NOT_CANCELLABLE|%|%', v_wo.code, v_wo.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_CANCEL_REASON_REQUIRED|%', v_wo.code;
    END IF;

    -- 【已经开过工的单子不能取消 —— 它只能收工】取消的意思是"这件事没有发生过";
    -- 而挂着一条加工单,就意味着料真的下去了、产出真的进了库。把它标成 cancelled
    -- 会让那几次加工失去它们的出处,而出处是这套系统存在的理由。
    --
    -- 【只数没有被冲销的 —— 而这两个条件今天是【等价】的】
    -- 链接是历史,它断言过的消耗不是:一次被冲销的加工,料退回了、产出批作废了,
    -- 那次消耗不再是发生过的事实,所以它拦不住取消。
    -- rollback_processing_run 同时写 status='reversed' 与 deleted_at,所以单写
    -- deleted_at IS NULL 也能得到同一个结果 —— 两个条件都在这里,是因为它们的
    -- 等价【是一个巧合】:哪天有一条路径只写其中一列,它们就分开了,而那时没有
    -- 任何东西会喊。把隐含的巧合写成显式的判据。
    -- (WO-1b 一度把这写成"修掉了 WO-1a 的一个 bug" —— 那句话是错的,
    --  见 db/migrations/2026-08-16-wo1b-fu1-*.sql。)
    SELECT count(*) INTO v_runs FROM processing_runs
     WHERE work_order_id = p_work_order_id AND deleted_at IS NULL AND status = 'committed';
    IF v_runs > 0 THEN
        RAISE EXCEPTION 'WO_HAS_RUNS|%|%', v_wo.code, v_runs;
    END IF;

    UPDATE work_orders
       SET status = 'cancelled', cancelled_at = now(), cancelled_by = v_user,
           cancel_reason = btrim(p_reason), updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, amend_reason, changed_by)
    VALUES (p_work_order_id, 'cancelled', btrim(p_reason), v_user);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code, 'status', 'cancelled');
END;
$function$

;

-- ─── close_work_order
CREATE OR REPLACE FUNCTION public.close_work_order(p_work_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_wo   work_orders%ROWTYPE;
    v_runs integer;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q6):改 / 取消 / 关闭工单 = action.wo_create
    --   (仓库)或 module.processing.edit(cco · cto 留着它们的宽码)。拒绝点名 action.wo_create。
    IF NOT has_any_permission(ARRAY['action.wo_create', 'module.processing.edit']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.wo_create';
    END IF;
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status <> 'released' THEN
        -- draft 的单子要"不做了",走 cancel —— 见上面那张迁移表的最后一段
        RAISE EXCEPTION 'WO_NOT_RELEASED|%|%', v_wo.code, v_wo.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_CLOSE_REASON_REQUIRED|%', v_wo.code;
    END IF;

    -- 【短交不拦 —— 这是一个决定,不是遗漏】实际做的比计划少,是一个要记下来的
    -- 事实。拦住它只会让人把计划改小以求关单,而那正好把差异从账上抹掉 ——
    -- 一条逼人去伪造数据的规则比没有规则更坏。收工时挂了几条加工单一并记进理由行,
    -- 让"关的时候是什么样"留在历史里,而不必事后重算。
    -- 口径与 WO_HAS_RUNS、与改单的地板一致(见 cancel_work_order 里那段说明:
    -- 两个条件今天等价,写全是为了让判据显式而不是靠巧合)。
    SELECT count(*) INTO v_runs FROM processing_runs
     WHERE work_order_id = p_work_order_id AND deleted_at IS NULL AND status = 'committed';

    UPDATE work_orders
       SET status = 'closed', closed_at = now(), closed_by = v_user,
           close_reason = btrim(p_reason), updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, detail, amend_reason, changed_by)
    VALUES (p_work_order_id, 'closed', 'runs=' || v_runs::text, btrim(p_reason), v_user);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'status', 'closed', 'runs', v_runs);
END;
$function$

;

-- db/functions/release_work_order.sql
-- 放行一张工单。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ APR-2(2026-09-22):这里【曾经】有一句按级别授权的检查,而它是一把锁 ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- WO-1b 的推理只错了一步,而那一步没有任何东西在看:它选了"层级 1",
-- 却没有问【第一级那个角色的人,持不持有 module.processing.edit】。
-- 实测(2026-09-22,以 postgres 读 user_roles / role_permissions / auth.users 基表,
-- 外加 require_approver_for 自己逐人给出的答案):
--     一级 = finance,唯一真持有人 chooer@evoltrya.test
--     module.processing.edit 的持有人 = admin · phua · sandra · vince
--     ★ 交集 = 空
-- 于是 Tim 在 2026-09-22 12:25:06 打开审批的那一刻起,
-- **线上没有任何人放行得了一张工单** —— 而屏幕上出现的是
-- 「APPROVAL_NOT_AUTHORISED|1|finance」,一句听起来像"你级别不够"、
-- 实际上对每一个人都成立的话。当时 work_orders 的 draft = 0,所以没有单据卡住;
-- 下一张就再也放行不了。**WO-1b 写下那一行时,三道闸全绿。**
--
-- ★ Tim 的裁定(Q1,2026-09-22)——【修订】了他自己早前那条"没有金额的单据
--   一律走一级":**按角色分级只管【带钱的单据】。** 不带钱的单据,谁能批仍由
--   它自己的模块权限说了算。工单没有金额,所以它回到 module.processing.edit。
-- ☞ 代价照直说:**工单少了一道名义上的一级闸,而那道闸【谁都过不去】。**
--   换来的是这条链重新走得通。真要给工单一个独立的审批人,那是一次建模改动
--   (给它自己的审批角色),不是把那一句放回来。登记在 docs/forward-queue.md。
-- ★ 而【下一次不会再靠人看出来】:approval_gate_intersections() 逐条断言
--   "这条链真的有人批得动",guard_approvals_switch 在【开】的那一刻按名拒。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ⚠★【为什么这一整段写在函数体【外面】】★⚠
-- ════════════════════════════════════════════════════════════════════════════
-- db/fixtures/203 的 P 臂与本刀迁移的自证 ⑥ 都断言
--     pg_proc.prosrc NOT LIKE '%require_approver_for%'
-- —— 而 **prosrc 里是带注释的**。第一版把这段解释写在 BEGIN 之后,
-- 于是那条断言被【这段解释自己】点亮,fixture 当场红。
-- ☞ 这就是 AGENTS.md「一句注释可以污染将来对它自己的计数」那一条,
--   而本刀在同一天里撞了它两次(另一次在 app/finance/financeErrorCodes.ts:
--   注释里一个带引号的码被 check-i18n 的 tsSet 当成了真的码)。
-- **要解释一件"这里【没有】什么"的事,就不要在它旁边写出那个名字。**
--
-- NOTE: introduced by db/migrations/2026-08-16-wo1b-*.sql;
-- 按级别授权那一句由 db/migrations/2026-09-22-apr2-self-approval-and-the-approver-that-nobody-is.sql 摘除。

CREATE OR REPLACE FUNCTION public.release_work_order(p_work_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_wo      work_orders%ROWTYPE;
    v_appr_on boolean := approvals_enabled();
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25):下达归财务 —— action.wo_release(finance · admin)。
    --   上面抬头说"谁能放行由 module.processing.edit 说了算"—— 从本刀起是 action.wo_release。
    PERFORM require_permission('action.wo_release');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status <> 'draft' THEN
        RAISE EXCEPTION 'WO_NOT_DRAFT|%|%', v_wo.code, v_wo.status;
    END IF;

    -- ★ APR-2:四眼。判据只有一份定义(forbid_self_approval)。
    -- 【只有一条腿】—— 工单没有"这张单说的是谁"(它说的是一批料,不是一个人),
    -- 所以第二个参数是 NULL,而 NULL 一律不匹配。不硬塞一个主语进去。
    PERFORM forbid_self_approval(v_wo.created_by, NULL::uuid, 'work_order');

    -- 【放行是那个要有人负责的动作】(WO-1b)Doc 2 点名要"who approved the work
    -- order"。可审批的是放行 —— 不是新建(草稿谁都可以写),也不是收工(事后记录)。
    --
    -- ★ APR-2:谁能放行,由 module.processing.edit 说了算(ROLE-1 Batch 3b 起:action.wo_release)—— 本函数【不】按角色
    --   分级。工单没有金额,而按角色分级只管带钱的单据(Tim 的 Q1 裁定)。
    --   ☞ 这里原先有一句按级别授权的检查,而它在线上是一把【谁都过不去】的锁。
    --     整段来龙去脉写在本文件的抬头 —— **刻意写在函数体外面**,
    --     见抬头最后一段说明为什么。

    UPDATE work_orders
       SET status = 'released', updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, changed_by)
    VALUES (p_work_order_id, 'released', v_user);

    -- 【留痕要说实话】—— 而 APR-3(Tim 的 Q7)把"实话"这一句本身改了。
    -- ★ 两条分支现在写的是【同一个决定值】:放行是一个人按下去的动作,
    --   审批开着还是关着都是;开关只改变"有没有一道按级别的授权",
    --   不改变"有没有人做过这个决定"。
    -- ★ 层级恒 NULL,不写 1。此前写的是 1,而那是一句【假记录】——
    --   这条路上【没有跑过任何一级授权检查】(上面那一段说明了为什么),
    --   于是 level = 1 会让留痕声称发生过一件没有发生的事。
    --   与 HR 三条链同形:它们也一律 NULL(approval_log 的 level 列注释)。
    PERFORM record_approval_decision('work_order', p_work_order_id, 'approved', NULL::smallint,
        CASE WHEN v_appr_on THEN NULL
             ELSE '审批流未启用(finance_settings.approvals_enabled = false)—— 没有按级别的授权步骤,而放行是这个人按下去的' END);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'status', 'released', 'approvals_enabled', v_appr_on);
END;
$function$

;

-- ─── commit_processing_run
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
            IF NOT v_produces AND v_result_state IS NOT NULL THEN
                DELETE FROM inbound_batch_safety_states s
                 WHERE s.inbound_batch_id = v_inbound_id
                   AND s.safety_state_code IN (
                       SELECT a.safety_state_code FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op AND a.resolves);

                INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
                VALUES (v_inbound_id, v_result_state)
                ON CONFLICT (inbound_batch_id, safety_state_code) DO NOTHING;
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
            IF NOT v_produces AND v_result_state IS NOT NULL THEN
                DELETE FROM output_batch_safety_states s
                 WHERE s.output_batch_id = v_output_id
                   AND s.safety_state_code IN (
                       SELECT a.safety_state_code FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op AND a.resolves);

                INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code)
                VALUES (v_output_id, v_result_state)
                ON CONFLICT (output_batch_id, safety_state_code) DO NOTHING;
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

-- ─── rollback_processing_run
CREATE OR REPLACE FUNCTION public.rollback_processing_run(p_run_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
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
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q9):回滚归仓库 —— action.processing_rollback
    --   (warehouse · admin),在回滚申请(CFO 批)落地之前一个人做完。
    PERFORM require_permission('action.processing_rollback');
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

-- ─── submit_shift_handover
CREATE OR REPLACE FUNCTION public.submit_shift_handover(p_shift_code text, p_handover_date date, p_outgoing_employee_id uuid, p_incoming_employee_id uuid, p_notes text DEFAULT NULL::text, p_items jsonb DEFAULT NULL::jsonb, p_downtime_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_elem jsonb;
    v_bad  text;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3b grilling Q2):交接班 = action.processing_aftercare
    --   (仓库)或 module.processing.edit。拒绝点名 action.processing_aftercare。
    IF NOT has_any_permission(ARRAY['action.processing_aftercare', 'module.processing.edit']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.processing_aftercare';
    END IF;

    -- 【世界侧日期不给默认值】与 FIN-10「永不给日期默认值」同一条:
    -- 交接班发生在哪一天是一件世界里的事实,不是 now() 的一个副产品。
    IF p_handover_date IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_DATE_REQUIRED';
    END IF;
    IF p_shift_code IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_SHIFT_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shifts WHERE code = p_shift_code AND is_active) THEN
        RAISE EXCEPTION 'HANDOVER_SHIFT_UNKNOWN|%', p_shift_code
          USING HINT = '未知或已停用的班次。停用的意思是"以后别再排它",不是"把历史改掉"。';
    END IF;
    -- 【交与接【两个人都要有名有姓】】一次说不出是谁交的班,不是一次交接班。
    IF p_outgoing_employee_id IS NULL OR p_incoming_employee_id IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_PEOPLE_REQUIRED'
          USING HINT = '交班的人与接班的人都要点名 —— 一次说不出是谁交给谁的交接班,没有传递任何责任。';
    END IF;
    IF p_outgoing_employee_id = p_incoming_employee_id THEN
        RAISE EXCEPTION 'HANDOVER_SAME_PERSON'
          USING HINT = '交班人与接班人是同一个人 —— 那样的"交接"没有把任何东西传给任何人。';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM employees WHERE id = p_outgoing_employee_id AND deleted_at IS NULL)
       OR NOT EXISTS (SELECT 1 FROM employees WHERE id = p_incoming_employee_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'HANDOVER_EMPLOYEE_NOT_FOUND';
    END IF;

    -- 【条目的类型必须是字典里的】—— 加第七类内容是【加一行字典】,
    -- 而不是在这里放行一个自由字符串。
    IF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
        SELECT elem->>'item_type_code' INTO v_bad
          FROM jsonb_array_elements(p_items) elem
         WHERE NOT EXISTS (SELECT 1 FROM handover_item_types t
                            WHERE t.code = elem->>'item_type_code' AND t.is_active)
         LIMIT 1;
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'HANDOVER_ITEM_TYPE_UNKNOWN|%', v_bad;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) elem
                    WHERE btrim(COALESCE(elem->>'body','')) = '') THEN
            RAISE EXCEPTION 'HANDOVER_ITEM_BODY_REQUIRED'
              USING HINT = '一条内容为空的条目与没有这条条目是同一件事,而它会在计数里冒充"填过了"。';
        END IF;
    END IF;

    -- 【必填的那几类:字典说了算,不是代码说了算】
    SELECT t.name_zh INTO v_bad
      FROM handover_item_types t
     WHERE t.is_active AND t.is_required
       AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(COALESCE(p_items,'[]'::jsonb)) elem
            WHERE elem->>'item_type_code' = t.code
              AND btrim(COALESCE(elem->>'body','')) <> '')
     LIMIT 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'HANDOVER_REQUIRED_ITEM_MISSING|%', v_bad;
    END IF;

    INSERT INTO shift_handovers (shift_code, handover_date, outgoing_employee_id,
                                 incoming_employee_id, notes, submitted_by, created_by, updated_by)
    VALUES (p_shift_code, p_handover_date, p_outgoing_employee_id, p_incoming_employee_id,
            NULLIF(btrim(COALESCE(p_notes,'')), ''), v_user, v_user, v_user)
    RETURNING id INTO v_id;

    IF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
        INSERT INTO shift_handover_items (handover_id, item_type_code, body, sort_order, created_by)
        SELECT v_id, elem->>'item_type_code', btrim(elem->>'body'),
               COALESCE((elem->>'sort_order')::integer, ord::integer), v_user
          FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(elem, ord);
    END IF;

    -- R5:设备状态是一条【引用】。这里存 downtime_id,绝不抄一份 reason。
    IF p_downtime_ids IS NOT NULL AND array_length(p_downtime_ids, 1) > 0 THEN
        IF EXISTS (SELECT 1 FROM unnest(p_downtime_ids) d
                    WHERE NOT EXISTS (SELECT 1 FROM equipment_downtime e WHERE e.id = d)) THEN
            RAISE EXCEPTION 'HANDOVER_DOWNTIME_NOT_FOUND';
        END IF;
        INSERT INTO shift_handover_equipment_refs (handover_id, downtime_id, created_by)
        SELECT v_id, d, v_user FROM unnest(p_downtime_ids) d
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_id;
END;
$function$;

-- ─── acknowledge_shift_handover
CREATE OR REPLACE FUNCTION public.acknowledge_shift_handover(p_handover_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ho  shift_handovers%ROWTYPE;
    v_emp uuid := current_user_employee();
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3b grilling Q2):交接班 = action.processing_aftercare
    --   (仓库)或 module.processing.edit。拒绝点名 action.processing_aftercare。
    IF NOT has_any_permission(ARRAY['action.processing_aftercare', 'module.processing.edit']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.processing_aftercare';
    END IF;

    SELECT * INTO v_ho FROM shift_handovers WHERE id = p_handover_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'HANDOVER_NOT_FOUND|%', p_handover_id;
    END IF;
    IF v_ho.acknowledged_at IS NOT NULL THEN
        RAISE EXCEPTION 'HANDOVER_ALREADY_ACKNOWLEDGED|%', v_ho.acknowledged_at
          USING HINT = '这张交接班已经被签收过了。**签收不是一个可以重来的动作** —— 覆盖它会把第一次签收的人与时刻抹掉,而那正是这一列存在的理由。';
    END IF;
    -- ════════════════════════════════════════════════════════════════════════
    -- ★【签收的人必须【是这张交接班点名的那位接班人】】★
    -- Tim 的原话是"**接班的那个人**的签收"。放宽成"任何有权限的人都能签",
    -- 这一列就退化成一个时间戳 —— 它会永远是满的,而它本来要回答的问题
    -- (**下一个班的人真的看过这些话了吗**)从此没有答案。
    -- 【为什么按 employee 而不是按 auth 用户】车间可能共用工位账号,
    -- 而"谁接的班"必须是一个人。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_ACK_NO_EMPLOYEE'
          USING HINT = '签收要落到一个【员工】身上,而这个登录账号没有对应的员工档案。签收是一个人做的事,不是一个账号做的事。';
    END IF;
    IF v_emp <> v_ho.incoming_employee_id THEN
        RAISE EXCEPTION 'HANDOVER_ACK_NOT_INCOMING'
          USING HINT = '只有这张交接班点名的那位【接班人】能签收它。别人代签,这一栏就只是一个时间戳,而它本来要回答的是"下一个班的人真的看过这些话了吗"。接班的人换了,就先把交接班改成他。';
    END IF;

    UPDATE shift_handovers
       SET acknowledged_at = now(),
           acknowledged_by = v_emp,
           updated_by      = auth.uid()
     WHERE id = p_handover_id;

    RETURN p_handover_id;
END;
$function$;

-- ── 8 · 自证 ──────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.b3b_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE b3b_pending_after ON COMMIT DROP AS
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
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权 = 之前 + 裁定的那十五行,一行不少、一行不多
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT (SELECT role_code || ':' || permission_code FROM b3b_grants_before
                 UNION SELECT unnest(ARRAY['warehouse:action.receive_goods', 'warehouse:action.batch_write_off', 'warehouse:action.wo_create', 'warehouse:action.processing_commit', 'warehouse:action.processing_rollback', 'warehouse:action.processing_aftercare', 'admin:action.receive_goods', 'admin:action.batch_write_off', 'admin:action.wo_create', 'admin:action.wo_release', 'admin:action.processing_commit', 'admin:action.processing_rollback', 'admin:action.processing_aftercare', 'finance:action.wo_release', 'warehouse:module.processing.view'])))
        UNION ALL
        ((SELECT role_code || ':' || permission_code FROM b3b_grants_before
          UNION SELECT unnest(ARRAY['warehouse:action.receive_goods', 'warehouse:action.batch_write_off', 'warehouse:action.wo_create', 'warehouse:action.processing_commit', 'warehouse:action.processing_rollback', 'warehouse:action.processing_aftercare', 'admin:action.receive_goods', 'admin:action.batch_write_off', 'admin:action.wo_create', 'admin:action.wo_release', 'admin:action.processing_commit', 'admin:action.processing_rollback', 'admin:action.processing_aftercare', 'finance:action.wo_release', 'warehouse:module.processing.view']))
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B3B_PROOF|grants differ from before + ruled: %', v_bad; END IF;
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.receive_goods';
    IF v_bad IS DISTINCT FROM 'admin warehouse' THEN RAISE EXCEPTION 'ROLE1B3B_PROOF|action.receive_goods holders are %', v_bad; END IF;
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.batch_write_off';
    IF v_bad IS DISTINCT FROM 'admin warehouse' THEN RAISE EXCEPTION 'ROLE1B3B_PROOF|action.batch_write_off holders are %', v_bad; END IF;
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.wo_create';
    IF v_bad IS DISTINCT FROM 'admin warehouse' THEN RAISE EXCEPTION 'ROLE1B3B_PROOF|action.wo_create holders are %', v_bad; END IF;
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.processing_commit';
    IF v_bad IS DISTINCT FROM 'admin warehouse' THEN RAISE EXCEPTION 'ROLE1B3B_PROOF|action.processing_commit holders are %', v_bad; END IF;
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.processing_rollback';
    IF v_bad IS DISTINCT FROM 'admin warehouse' THEN RAISE EXCEPTION 'ROLE1B3B_PROOF|action.processing_rollback holders are %', v_bad; END IF;
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.processing_aftercare';
    IF v_bad IS DISTINCT FROM 'admin warehouse' THEN RAISE EXCEPTION 'ROLE1B3B_PROOF|action.processing_aftercare holders are %', v_bad; END IF;
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.wo_release';
    IF v_bad IS DISTINCT FROM 'admin finance' THEN RAISE EXCEPTION 'ROLE1B3B_PROOF|action.wo_release holders are %', v_bad; END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                WHERE r.code = 'warehouse' AND rp.permission_code = 'module.materials.view') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|warehouse must not hold module.materials.view (Q8)';
    END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;业务行一行没变
    IF EXISTS ((SELECT b.k, b.id FROM b3b_pending_before b EXCEPT SELECT a.k, a.id FROM b3b_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM b3b_pending_after a EXCEPT SELECT b.k, b.id FROM b3b_pending_before b)) THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM b3b_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM work_orders) AS work_orders,
       (SELECT count(*) FROM work_orders WHERE status = 'released') AS work_orders_released,
       (SELECT count(*) FROM processing_runs WHERE status = 'committed') AS runs_committed,
       (SELECT count(*) FROM processing_runs WHERE status = 'reversed') AS runs_reversed,
       (SELECT count(*) FROM processing_outputs) AS processing_outputs,
       (SELECT count(*) FROM processing_inputs) AS processing_inputs,
       (SELECT count(*) FROM processing_run_losses) AS processing_run_losses,
       (SELECT count(*) FROM inbound_batches) AS receipts_all,
       (SELECT count(*) FROM inbound_batches WHERE deleted_at IS NOT NULL) AS receipts_written_off,
       (SELECT count(*) FROM output_batches) AS outputs_all,
       (SELECT count(*) FROM output_batches WHERE deleted_at IS NOT NULL) AS outputs_written_off,
       (SELECT count(*) FROM shift_handovers) AS shift_handovers) n) THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|a business row count changed: % → %',
            (SELECT row(c.*)::text FROM b3b_counts_before c), (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM work_orders) AS work_orders,
       (SELECT count(*) FROM work_orders WHERE status = 'released') AS work_orders_released,
       (SELECT count(*) FROM processing_runs WHERE status = 'committed') AS runs_committed,
       (SELECT count(*) FROM processing_runs WHERE status = 'reversed') AS runs_reversed,
       (SELECT count(*) FROM processing_outputs) AS processing_outputs,
       (SELECT count(*) FROM processing_inputs) AS processing_inputs,
       (SELECT count(*) FROM processing_run_losses) AS processing_run_losses,
       (SELECT count(*) FROM inbound_batches) AS receipts_all,
       (SELECT count(*) FROM inbound_batches WHERE deleted_at IS NOT NULL) AS receipts_written_off,
       (SELECT count(*) FROM output_batches) AS outputs_all,
       (SELECT count(*) FROM output_batches WHERE deleted_at IS NOT NULL) AS outputs_written_off,
       (SELECT count(*) FROM shift_handovers) AS shift_handovers) n);
    END IF;

    -- ④ 结构:五条策略没了;五支守卫挂上;损耗四处认两码;查名视图认 processing.view;十三支函数的门
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND ((tablename IN ('processing_runs', 'processing_outputs') AND cmd IN ('INSERT', 'DELETE'))
                  OR (tablename = 'processing_inputs' AND cmd = 'DELETE'))) THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|a processing insert / delete policy is still there';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE tgname IN ('trg_processing_runs_direct_write', 'trg_processing_runs_direct_delete', 'trg_processing_outputs_direct_write', 'trg_processing_outputs_direct_delete', 'trg_processing_inputs_direct_delete');
    IF v_n <> 5 THEN RAISE EXCEPTION 'ROLE1B3B_PROOF|expected 5 processing guard triggers, got %', v_n; END IF;
    SELECT count(*) INTO v_n FROM pg_policies WHERE schemaname = 'public' AND tablename = 'processing_run_losses'
       AND cmd <> 'SELECT' AND coalesce(qual, with_check) LIKE '%action.processing_aftercare%';
    IF v_n <> 3 THEN RAISE EXCEPTION 'ROLE1B3B_PROOF|expected 3 loss write policies naming aftercare, got %', v_n; END IF;
    IF pg_get_viewdef('public.material_lookup'::regclass) NOT LIKE '%module.processing.view%' THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|material_lookup does not admit module.processing.view';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'create_inbound_batch' AND pronamespace = 'public'::regnamespace)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'create_inbound_batch' AND pronamespace = 'public'::regnamespace
                     AND prosrc NOT LIKE '%require_permission(''action.receive_goods'')%') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|create_inbound_batch is not gated as ruled';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'receive_inbound_batch_against_po' AND pronamespace = 'public'::regnamespace)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'receive_inbound_batch_against_po' AND pronamespace = 'public'::regnamespace
                     AND prosrc NOT LIKE '%require_permission(''action.receive_goods'')%') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|receive_inbound_batch_against_po is not gated as ruled';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'soft_delete_inbound_batch' AND pronamespace = 'public'::regnamespace)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'soft_delete_inbound_batch' AND pronamespace = 'public'::regnamespace
                     AND prosrc NOT LIKE '%require_permission(''action.batch_write_off'')%') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|soft_delete_inbound_batch is not gated as ruled';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'soft_delete_output_batch' AND pronamespace = 'public'::regnamespace)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'soft_delete_output_batch' AND pronamespace = 'public'::regnamespace
                     AND prosrc NOT LIKE '%require_permission(''action.batch_write_off'')%') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|soft_delete_output_batch is not gated as ruled';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'create_work_order' AND pronamespace = 'public'::regnamespace)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'create_work_order' AND pronamespace = 'public'::regnamespace
                     AND prosrc NOT LIKE '%require_permission(''action.wo_create'')%') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|create_work_order is not gated as ruled';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'amend_work_order' AND pronamespace = 'public'::regnamespace)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'amend_work_order' AND pronamespace = 'public'::regnamespace
                     AND prosrc NOT LIKE '%has_any_permission(ARRAY[''action.wo_create'', ''module.processing.edit''])%') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|amend_work_order is not gated as ruled';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'cancel_work_order' AND pronamespace = 'public'::regnamespace)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'cancel_work_order' AND pronamespace = 'public'::regnamespace
                     AND prosrc NOT LIKE '%has_any_permission(ARRAY[''action.wo_create'', ''module.processing.edit''])%') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|cancel_work_order is not gated as ruled';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'close_work_order' AND pronamespace = 'public'::regnamespace)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'close_work_order' AND pronamespace = 'public'::regnamespace
                     AND prosrc NOT LIKE '%has_any_permission(ARRAY[''action.wo_create'', ''module.processing.edit''])%') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|close_work_order is not gated as ruled';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'release_work_order' AND pronamespace = 'public'::regnamespace)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'release_work_order' AND pronamespace = 'public'::regnamespace
                     AND prosrc NOT LIKE '%require_permission(''action.wo_release'')%') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|release_work_order is not gated as ruled';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'commit_processing_run' AND pronamespace = 'public'::regnamespace)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'commit_processing_run' AND pronamespace = 'public'::regnamespace
                     AND prosrc NOT LIKE '%require_permission(''action.processing_commit'')%') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|commit_processing_run is not gated as ruled';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'rollback_processing_run' AND pronamespace = 'public'::regnamespace)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'rollback_processing_run' AND pronamespace = 'public'::regnamespace
                     AND prosrc NOT LIKE '%require_permission(''action.processing_rollback'')%') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|rollback_processing_run is not gated as ruled';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'submit_shift_handover' AND pronamespace = 'public'::regnamespace)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'submit_shift_handover' AND pronamespace = 'public'::regnamespace
                     AND prosrc NOT LIKE '%has_any_permission(ARRAY[''action.processing_aftercare'', ''module.processing.edit''])%') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|submit_shift_handover is not gated as ruled';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'acknowledge_shift_handover' AND pronamespace = 'public'::regnamespace)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'acknowledge_shift_handover' AND pronamespace = 'public'::regnamespace
                     AND prosrc NOT LIKE '%has_any_permission(ARRAY[''action.processing_aftercare'', ''module.processing.edit''])%') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|acknowledge_shift_handover is not gated as ruled';
    END IF;

    -- ⑤ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求;草稿工单:下达人不是建单人)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.b3b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ROLE1B3B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.b3b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.b3b_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.b3b_pending_decider_check(boolean);

COMMIT;
