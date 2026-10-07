-- db/migrations/2026-10-07-mes4a-processing-record.sql
-- MES-4a —— 加工记录:参数、配方与物料平衡结平(MES 组的第五刀,v1.4.41;发布那一行在 docs/handbacks/MES-4a.md 的抬头)。
-- 由 db/scripts/build_mes4a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-07:MES-4a Step 0 的 Q1–Q36 全部照建议裁定;docs/surveys/MES-4a/STEP0-HANDBACK.md §15)
--   ① 表头(Q7 · Q8 · Q9):processing_runs 加 started_at · ended_at · shift_code(MES-4a 起必填 —— INSERT 触发器 + 提交函数里同一支
--      assert_run_header,只管新行)· recipe_version_id · corrects_run_id。工序 ↔ 机器(operation_type_equipment):挂着没处置的机器的
--      工序必须选挂着的那一台(assert_run_equipment)。一条都不预挂。
--   ② 参数与指标(Q10–Q15):operation_type_fields(配置是数据;引导规格书点名的计数与指标,全部不必填、没有范围)·
--      processing_run_values(只追加,越界照记标出来)· processing_event_types(三种,没有 other)· processing_run_events(只追加)。
--      不建任何设备转换器(Q14)。
--   ③ 配方(Q16):process_recipes · process_recipe_versions(一版写了不改);加工单记它用的那一版,预填参数。
--   ④ 称重(Q24–Q26):processing_outputs.weighing_id —— MES-4a 起每一条转化型产出腿都挂一次称重(挑一条,或在提交时敲重量经正常路径落一条
--      手工称重);不在校准期内的拒;挂上之后那条称重不再更正(WEIGHING_IN_USE)。
--   ⑤ 损耗与结平(Q17–Q23 · Q28):loss_qty = 投入 − 产出(敲一个不同的数按名拒);processing_run_losses 改成只追加(id 主键、更正链、
--      撤回 = 更正成 0;只经两支函数写);processing_run_closures(只追加,按 id 水位线重开)· close_run_balance · 两张平衡视图;
--      operation_types.balance_tolerance_pct(V1)。三类新损耗(取样消耗 · 留在设备里的料 · 回收的扫地料)。
--   ⑥ 更正(Q29–Q32):processing_run_corrections + correct_run_header(六个字段);三张加工表的 UPDATE 策略拿掉(ROLE1B3B 关闭),
--      直连改按名拒。
--   ⑦ 两道新工序(Q3):casing_removal · electrode_separation(只受理已放电并核实的料)。
--   ⑧ 读者:operations_now +1 支(processing_balance_unclosed)· pending_values +2 支(V1 · V36),V6 的去处搬到班次字典 ·
--      月末的一行警告(processing_runs_unclosed_balance,不挡关账)· 审计记录(加工单 +4 成员;新主语 operation_type;两本字典)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改任何一张既有单据或加工单;
--   不挂任何机器、不建任何配方、不给任何容差、范围或班次时刻;不碰 MES-3a / 3b 的任何设定;require_calibrated_since 保持空。
--   只播:两道工序(连同它们的形态与安全状态行)、27 个字段、三类损耗、三种异常事件,与例外表的两行。
--
-- 【破窗】见 docs/surveys/MES-4a/STEP0-HANDBACK.md §13:旧的加工单表单照名调 commit_processing_run,而它现在要开始、结束、班次
--   与称重 —— 部署之前,从页面记一张加工单按名拒(RUN_TIMES_REQUIRED);旧的损耗面板直连写,写策略已拿掉 —— 部署之前分类损耗被拒。
--   读的一侧只多了列。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多;七个账号一个都没被停;
--   既有的每一张加工单、每一条产出腿与投入腿逐字未变;变更记录只在引导的那几张字典与例外表上动了;新的数据表全是空的;
--   没有一台机器被挂、没有一个配方、容差、范围或班次时刻;开关是空的;anon 能执行的【恰好】两支;内层谁都调不到;
--   那 44 条开着的读策略还是 44 条;三张加工表的写策略恰好拿掉;变更记录覆盖与遮蔽零缺口;每一张被记录的表的绑定键都是它的主键;
--   提醒臂 56 支;待补的值 15 支;每一张在途单据仍有一个不是它当事人的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES4A_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.operation_type_fields') IS NOT NULL OR to_regclass('public.processing_run_values') IS NOT NULL
       OR to_regclass('public.processing_run_closures') IS NOT NULL OR to_regclass('public.process_recipes') IS NOT NULL THEN
        RAISE EXCEPTION 'MES4A_PRE|MES-4a tables already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                 AND ((table_name = 'processing_runs' AND column_name IN ('started_at', 'ended_at', 'shift_code', 'recipe_version_id', 'corrects_run_id'))
                      OR (table_name = 'processing_outputs' AND column_name = 'weighing_id')
                      OR (table_name = 'processing_run_losses' AND column_name IN ('id', 'corrects_id'))
                      OR (table_name = 'operation_types' AND column_name = 'balance_tolerance_pct'))) THEN
        RAISE EXCEPTION 'MES4A_PRE|MES-4a columns already exist';
    END IF;
    IF (SELECT string_agg(code, ',' ORDER BY code) FROM operation_types)
       IS DISTINCT FROM 'battery_powder_line,deep_discharge,electrode_line,electrode_powder_line,manual_disassembly' THEN
        RAISE EXCEPTION 'MES4A_PRE|operation_types are not the five expected';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES4A_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES4A_PRE|expected 105 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 55 THEN
        RAISE EXCEPTION 'MES4A_PRE|operations_now should have 55 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 13 THEN
        RAISE EXCEPTION 'MES4A_PRE|pending_values should have 13 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES4A_PRE|require_calibrated_since must be empty';
    END IF;
    IF EXISTS (SELECT 1 FROM shifts WHERE starts_at IS NOT NULL OR ends_at IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4A_PRE|shift times are expected empty';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes4a_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes4a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes4a_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes4a_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes4a_runs_before ON COMMIT DROP AS
SELECT md5(COALESCE(string_agg(t::text, '|' ORDER BY t.id), '')) AS digest, count(*) AS n
  FROM (SELECT id, code, process_date, total_input, total_output, loss_qty, notes, status, deleted_at, created_at, created_by, updated_at, updated_by, allocation_basis, material_cost_base, process_cost_base, total_cost_base, allocation_snapshot, allocated_at, allocated_by, capitalized_cost_base, capitalization_entry_id, allocation_basis_changed_at, work_order_id, deleted_by, delete_reason, equipment_id, operation_type_code FROM processing_runs) t;
CREATE TEMP TABLE mes4a_legs_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg(i::text, '|' ORDER BY i.id), '')) FROM (SELECT id, run_id, inbound_batch_id, quantity_consumed, created_at, output_batch_id FROM processing_inputs) i) AS inputs,
       (SELECT md5(COALESCE(string_agg(o::text, '|' ORDER BY o.id), '')) FROM (SELECT id, run_id, output_batch_id, quantity_produced, created_at, allocated_cost_base, unit_cost_base, cost_incomplete FROM processing_outputs) o) AS outputs,
       (SELECT count(*) FROM processing_run_losses) AS losses;

-- ── 1 · 先建的函数:改造既有表时要挂的触发器(镜像原样)──────────────────────────

-- db/functions/assert_run_header.sql
-- MES-4a(2026-10-07,MES-0 Q42;MES-4a Step 0 Q7,Tim):【一张新加工单的表头说得通吗】—— 一份判据,三个调用方:
--   commit_processing_run(在任何业务判断之前先问它,于是操作员先看到这一句)· guard_processing_run_header(INSERT 触发器 ——
--   对任何写入者成立)· correct_run_header(改开始 / 结束 / 班次时按新值再问一遍)。
--   按顺序:
--     RUN_TIMES_REQUIRED|<开始或结束缺哪一个>      开始、结束必填
--     RUN_SHIFT_REQUIRED                           班次必填(选的,不是推的 —— 班次的起止时刻今天是空的)
--     RUN_SHIFT_UNKNOWN|<码>                       班次不存在或已停用
--     RUN_END_BEFORE_START|<开始>|<结束>            结束必须晚于开始
--     RUN_IN_FUTURE|<结束>                          还没发生的事不记(fixture 214 那一族:发生了的事,日期不晚于今天)
--     RUN_DATE_OUTSIDE_RUN_TIME|<加工日>|<开始那天>|<结束那天>  加工日要落在开始与结束的【新加坡日期】之间(含两端)
--   加工日仍是库存流水的业务日期(它决定期间),所以它【不从时刻推出来】—— 人选,这里只问它与时刻对不对得上。
--   【内层】不是 SECURITY DEFINER、没有调用者检查;它不读任何人的数据(只读班次字典),EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.assert_run_header(p_process_date date, p_started_at timestamp with time zone, p_ended_at timestamp with time zone, p_shift_code text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_from date;
    v_to   date;
BEGIN
    IF p_started_at IS NULL OR p_ended_at IS NULL THEN
        RAISE EXCEPTION 'RUN_TIMES_REQUIRED|%', CASE WHEN p_started_at IS NULL AND p_ended_at IS NULL THEN 'start,end'
                                                     WHEN p_started_at IS NULL THEN 'start' ELSE 'end' END
          USING HINT = 'MES-4a 起每一张加工单都要说出它从几点跑到几点(规格 §3.2 · §5)。';
    END IF;
    IF p_shift_code IS NULL OR btrim(p_shift_code) = '' THEN
        RAISE EXCEPTION 'RUN_SHIFT_REQUIRED'
          USING HINT = 'MES-4a 起每一张加工单都要选一个班次。班次是选的,不是从时刻推的 —— 班次的起止时刻还没人给(V6 · V7)。';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shifts s WHERE s.code = p_shift_code AND s.is_active) THEN
        RAISE EXCEPTION 'RUN_SHIFT_UNKNOWN|%', p_shift_code;
    END IF;
    IF p_ended_at <= p_started_at THEN
        RAISE EXCEPTION 'RUN_END_BEFORE_START|%|%', p_started_at, p_ended_at;
    END IF;
    IF p_ended_at > now() THEN
        RAISE EXCEPTION 'RUN_IN_FUTURE|%', p_ended_at
          USING HINT = '一炉还没跑完就不记 —— 结束时刻晚于此刻。';
    END IF;
    v_from := (p_started_at AT TIME ZONE 'Asia/Singapore')::date;
    v_to := (p_ended_at AT TIME ZONE 'Asia/Singapore')::date;
    IF p_process_date IS NOT NULL AND (p_process_date < v_from OR p_process_date > v_to) THEN
        RAISE EXCEPTION 'RUN_DATE_OUTSIDE_RUN_TIME|%|%|%', p_process_date, v_from, v_to
          USING HINT = '加工日要落在这一炉开始那天与结束那天(新加坡日期)之间。';
    END IF;
END;
$function$;

-- db/functions/guard_processing_run_header.sql
-- MES-4a(2026-10-07,MES-0 Q42;MES-4a Step 0 Q7,Tim):processing_runs 的 BEFORE INSERT 触发器 —— 每一张【新】加工单的表头过
--   assert_run_header(开始、结束、班次必填;时间合理;加工日落在两者之间)。只挂 INSERT:旧单(开始时刻为空)永远不被它碰,
--   于是它们照样分摊得了、冲销得了 —— 一条 NOT VALID 的 CHECK 做不到这一点(它对旧行的每一次 UPDATE 照样检查)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.guard_processing_run_header()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM assert_run_header(NEW.process_date, NEW.started_at, NEW.ended_at, NEW.shift_code);
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.guard_processing_run_losses()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_run_id  uuid := NEW.run_id;
    v_sum     numeric;
    v_loss    numeric;
    v_code    text;
BEGIN
    SELECT r.loss_qty, r.code INTO v_loss, v_code
      FROM public.processing_runs r WHERE r.id = v_run_id;

    -- MES-4a:只追加之后,一类的【当前】量是它那条更正链的末端(没有被别的行更正过的那一行)
    SELECT COALESCE(sum(l.quantity), 0) INTO v_sum
      FROM public.processing_run_losses l
     WHERE l.run_id = v_run_id
       AND NOT EXISTS (SELECT 1 FROM public.processing_run_losses x WHERE x.corrects_id = l.id);

    -- 【loss_qty 为空时不拦】空的意思是"这张单没有记过损耗总量",
    -- 而不是"总量是零"。拿 0 去比会把一条【没人填过】读成【上限为零】,
    -- 那正是本仓库反复付账的那个错(METAL-1 的 no_reference)。
    IF v_loss IS NOT NULL AND v_sum > v_loss THEN
        RAISE EXCEPTION 'LOSS_CATEGORIES_EXCEED_LOSS_QTY|%|%|%', v_code, v_sum, v_loss
          USING HINT = '有名字的损耗之和超过了这张加工单的损耗总量(投入 − 产出)。剩下的那一截是还没解释的余数,不许被说成比它更多。';
    END IF;
    RETURN NULL;
END;
$function$;

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
-- ★ MES-4a(2026-10-07,MES-4a Step 0 Q32,Tim):【直连 UPDATE 也一律拒】—— 三张表的 UPDATE 策略拿掉了
--   (ROLE1B3B-PROCESSING-UPDATE-POLICIES 关闭)。没有 UPDATE 策略时,直连 UPDATE 在 RLS 那里是零行、行级触发器不会醒,
--   所以三张表都挂成【语句级 BEFORE UPDATE OR DELETE】(trg_<表>_direct_change),零行也照样按名拒;
--   processing_runs / processing_outputs 的行级 BEFORE INSERT 照旧。此前"只在改 status 或 work_order_id 时拒"那一支删掉 ——
--   表头能改的只剩 correct_run_header 那六个字段(留更正行),它是 SECURITY DEFINER,走属主路径。
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
    RAISE EXCEPTION 'PROCESSING_THROUGH_FUNCTION_ONLY|%|%', TG_TABLE_NAME, lower(TG_OP);
END;
$function$;

COMMENT ON FUNCTION public.guard_processing_direct_write() IS
'ROLE-1 Batch 3b · MES-4a:processing_runs / processing_outputs 的直连 INSERT,以及三张加工表(runs · inputs · outputs)的直连 UPDATE 与 DELETE,一律按名拒 PROCESSING_THROUGH_FUNCTION_ONLY|表|动作。提交走 commit_processing_run,回滚走 rollback_processing_run,表头更正走 correct_run_header,成本走 allocate_processing_costs —— 都是 SECURITY DEFINER。属主路径放行。';

-- ── 2 · 工序字典:两道新工序(Q3)与它们的形态、安全状态行;容差列(V1);三类新损耗(Q2 · Q56)──────────
ALTER TABLE public.operation_types ADD COLUMN balance_tolerance_pct numeric CHECK (balance_tolerance_pct IS NULL OR balance_tolerance_pct >= 0);
COMMENT ON COLUMN public.operation_types.balance_tolerance_pct IS
    'MES-4a(规格 §4.1 · MES-0 Q46 · Q47):这道工序一炉物料平衡允许的余数,投入的百分比。为空 = Not yet set(V1)—— 不是 0:没给的时候任何不为零的余数都要书面说明。结平时抄进 processing_run_closures.tolerance_pct。只对转化型有意义(状态改变型投入恒等于产出)。';
INSERT INTO public.operation_types (code, name_en, name_zh, kind_code, resulting_safety_state_code, sort_order, notes) VALUES
    ('casing_removal', 'Casing removal', '开壳', 'transforming', NULL, 6,
     '【MES-4a · 规格 §3.3】电芯 → 已开壳电芯 + 壳体。硬壳与软包是两台设备;先分类(分类本身是一条记录)。只受理已放电并核实的料。'),
    ('electrode_separation', 'Electrode separation', '极片分离', 'transforming', NULL, 7,
     '【MES-4a · 规格 §3.4】已开壳电芯 → 正极片 / 负极片 / 隔膜(三路分开称)。卷绕与叠片是两台设备。电解液在这一段挥发或回收 —— 它是一个损耗类别,不是产出形态。只受理已放电并核实的料。');
INSERT INTO public.operation_type_input_forms (operation_type_code, form_code, notes) VALUES
    ('casing_removal', 'loose_cells', NULL),
    ('electrode_separation', 'de_cased_cell', '【F2/R2】已开壳电芯也可以是【买进来的】——同一种物质,同一条下游路。');
INSERT INTO public.operation_type_output_forms (operation_type_code, form_code, notes) VALUES
    ('casing_removal', 'de_cased_cell', NULL),
    ('casing_removal', 'casing', NULL),
    ('electrode_separation', 'cathode_sheet', NULL),
    ('electrode_separation', 'anode_sheet', NULL),
    ('electrode_separation', 'separator', '【R4】它是一个【出口】——离开这条线,不再往下走。');
INSERT INTO public.operation_type_safety_states (operation_type_code, safety_state_code, resolves, notes) VALUES
    ('casing_removal', 'discharged_verified', false, NULL),
    ('electrode_separation', 'discharged_verified', false, NULL);
INSERT INTO public.loss_categories (code, name_en, name_zh, metal_fate, is_true_loss, sort_order, notes) VALUES
    ('sampling_consumption',
     'Sampling consumption', '取样消耗', 'leaves', true, 5,
     '【MES-4a · 规格 §4.1】取样拿去化验、不回来的那部分 —— 质量与金属一起离开这一炉(去了化验室)。'),
    ('equipment_holdup',
     'Material held up in equipment', '留在设备里的料', 'stays', false, 6,
     '【MES-4a · 规格 §4.1 · R7】一炉跑完留在机器里、被下一炉带走的料(heel)。Tim 的 R7:heel 是存货 —— 它没有离开工厂,所以 is_true_loss 为 false、金属留着。'),
    ('sweepings',
     'Sweepings recovered', '回收的扫地料', 'stays', false, 7,
     '【MES-4a · 规格 §4.1】扫起来、收回来的料 —— 它没有丢,只是还没回到一条有名字的产出里,所以 is_true_loss 为 false、金属留着。');

-- ── 3 · 九张新表(镜像原样,带它们的守卫、引导、策略与触发器)──────────────────────────

-- db/tables/operation_type_fields.sql
-- MES-4a(2026-10-07,MES-0 Q43 · MES-4a Step 0 Q10 · Q13,Tim):【一道工序记哪些参数与指标】—— 配置是数据,不是固定的列。
--   一行 = 某道工序上的一个字段:kind(parameter = 这一炉用的设定 · indicator = 这一炉出来的结果)、value_type(number · count · text · yes_no)、
--   单位、要不要必填(必填在【结平】时判,不在提交时判 —— Q11)、有没有范围(has_range;范围上下限为空 = Not yet set,V36)。
--   【退役,不删】一个字段一旦存在,它就可能有值;删掉它会让旧值失去意思。所以没有 DELETE(OPERATION_FIELD_RETIRE_NOT_DELETE),
--   停用就是 is_active = false;用上之后它的 kind / value_type / unit 也不许改(OPERATION_FIELD_IN_USE)—— 改了,旧值就换了意思。
--   【引导】规格书点名的那些计数与指标(Q13):全部不必填、全部没有范围。要必填、要范围,是 Tim 以后在工序页上的设定,不是改码。
--   RUNTIME CONFIG(加一个字段是加一行)。读:module.processing.view;写:module.processing.edit。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.operation_type_fields (
    operation_type_code text NOT NULL REFERENCES public.operation_types (code),
    field_code          text NOT NULL CHECK (field_code ~ '^[a-z][a-z0-9_]*$'),
    name_en             text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh             text NOT NULL CHECK (btrim(name_zh) <> ''),
    kind                text NOT NULL CHECK (kind IN ('parameter', 'indicator')),
    value_type          text NOT NULL CHECK (value_type IN ('number', 'count', 'text', 'yes_no')),
    unit                text,
    is_required         boolean NOT NULL DEFAULT false,
    has_range           boolean NOT NULL DEFAULT false,
    range_min           numeric,
    range_max           numeric,
    is_active           boolean NOT NULL DEFAULT true,
    sort_order          integer NOT NULL DEFAULT 0,
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          uuid DEFAULT auth.uid(),
    PRIMARY KEY (operation_type_code, field_code),
    -- 范围只对数(number · count)有意思;没声明有范围的字段,上下限必须是空的 —— 空的意思由 has_range 回答,不靠读的人猜
    CONSTRAINT operation_type_fields_range_shape
        CHECK ((has_range OR (range_min IS NULL AND range_max IS NULL))
               AND (NOT has_range OR value_type IN ('number', 'count'))
               AND (range_min IS NULL OR range_max IS NULL OR range_min <= range_max))
);

COMMENT ON TABLE public.operation_type_fields IS
    'MES-4a:一道工序记哪些参数(parameter,这一炉用的设定)与指标(indicator,这一炉出来的结果)。配置是数据(MES-0 Q43)。必填在结平时判(Q11);范围为空 = Not yet set(V36);越出范围照记、标出来,不拒(Q12)。退役不删;用上之后 kind / value_type / unit 不许改。RUNTIME CONFIG。';
COMMENT ON COLUMN public.operation_type_fields.has_range IS
    'MES-4a:这个字段【有】一个范围(由设备厂商或工艺工程师给)。为真而上下限都空 = Not yet set,列在 /settings/pending-values 的 V36。为假 = 这个字段没有范围可言(计数、文字),不是"没人给"。';

-- 【属主身份】"用上了没有"要数所有加工单的值与所有配方 —— 不能让改字段的人的读权限少数几行(RLS 静默丢行,xmodule 那一族)。
CREATE OR REPLACE FUNCTION public.guard_operation_type_field()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'OPERATION_FIELD_RETIRE_NOT_DELETE|%|%', OLD.operation_type_code, OLD.field_code;
    END IF;
    IF NEW.operation_type_code IS DISTINCT FROM OLD.operation_type_code OR NEW.field_code IS DISTINCT FROM OLD.field_code THEN
        RAISE EXCEPTION 'OPERATION_FIELD_KEY_FIXED|%|%', OLD.operation_type_code, OLD.field_code;
    END IF;
    IF (NEW.kind IS DISTINCT FROM OLD.kind OR NEW.value_type IS DISTINCT FROM OLD.value_type OR NEW.unit IS DISTINCT FROM OLD.unit)
       AND (EXISTS (SELECT 1 FROM processing_run_values v
                     WHERE v.operation_type_code = OLD.operation_type_code AND v.field_code = OLD.field_code)
            OR EXISTS (SELECT 1 FROM process_recipe_versions rv JOIN process_recipes r ON r.id = rv.recipe_id
                        WHERE r.operation_type_code = OLD.operation_type_code AND rv.param_values ? OLD.field_code)) THEN
        RAISE EXCEPTION 'OPERATION_FIELD_IN_USE|%|%', OLD.operation_type_code, OLD.field_code;
    END IF;
    NEW.updated_at := now();
    NEW.updated_by := auth.uid();
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_operation_type_fields_guard
    BEFORE UPDATE OR DELETE ON public.operation_type_fields
    FOR EACH ROW EXECUTE FUNCTION public.guard_operation_type_field();

INSERT INTO public.operation_type_fields (operation_type_code, field_code, name_en, name_zh, kind, value_type, unit, sort_order, notes) VALUES
    -- 规格 §3.2 人工拆解
    ('manual_disassembly', 'modules_in', 'Modules in', '投入模组数', 'indicator', 'count', 'pcs', 10, 'Spec §3.2: module count in (the mass is the input leg).'),
    ('manual_disassembly', 'cells_out', 'Cells out', '产出电芯数', 'indicator', 'count', 'pcs', 20, 'Spec §3.2: cell count out (routing is by unit).'),
    ('manual_disassembly', 'cells_damaged', 'Cells damaged in disassembly', '拆解中损坏的电芯数', 'indicator', 'count', 'pcs', 30, 'Spec §3.2: tooling, technique and safety indicator.'),
    -- 规格 §3.3 开壳
    ('casing_removal', 'cells_in_hard_case', 'Cells in, hard case', '投入硬壳电芯数', 'indicator', 'count', 'pcs', 10, 'Spec §3.3: classification count.'),
    ('casing_removal', 'cells_in_pouch', 'Cells in, pouch', '投入软包电芯数', 'indicator', 'count', 'pcs', 20, 'Spec §3.3: classification count.'),
    ('casing_removal', 'classified_by', 'Classified by (visual or equipment)', '分类方式(目视或设备)', 'indicator', 'text', NULL, 30, 'Spec §3.3: visual and manual, or equipment identification.'),
    ('casing_removal', 'units_judged_by_hand', 'Units the equipment could not identify, judged by hand', '设备认不出、人工判定的件数', 'indicator', 'count', 'pcs', 40, 'Spec §3.3: the indicator of identification effectiveness.'),
    ('casing_removal', 'misclassifications', 'Misclassifications', '分错的件数', 'indicator', 'count', 'pcs', 50, 'Spec §3.3: persistently non-zero means the classification step needs revision.'),
    ('casing_removal', 'scrap_cut_through', 'Scrap: cut through', '报废:切穿', 'indicator', 'count', 'pcs', 60, 'Spec §3.3 scrap by cause.'),
    ('casing_removal', 'scrap_internal_short', 'Scrap: internal short circuit', '报废:内短路', 'indicator', 'count', 'pcs', 70, 'Spec §3.3 scrap by cause.'),
    ('casing_removal', 'scrap_smoke', 'Scrap: smoke', '报废:冒烟', 'indicator', 'count', 'pcs', 80, 'Spec §3.3 scrap by cause.'),
    ('casing_removal', 'scrap_fire', 'Scrap: fire', '报废:起火', 'indicator', 'count', 'pcs', 90, 'Spec §3.3 scrap by cause.'),
    ('casing_removal', 'cuts_this_run', 'Cuts this run', '本炉切割次数', 'indicator', 'count', 'cuts', 100, 'Spec §3.3: cumulative cut count per tool is built from these.'),
    -- 规格 §3.4 极片分离(与合在一起的 electrode_line 同一组)
    ('electrode_separation', 'cells_in', 'Cells in', '投入电芯数', 'indicator', 'count', 'pcs', 10, 'Spec §3.4.'),
    ('electrode_separation', 'run_time_min', 'Run time', '运行时间', 'indicator', 'number', 'min', 20, 'Spec §3.4: read from the machine controller.'),
    ('electrode_separation', 'energy_kwh', 'Energy', '能耗', 'indicator', 'number', 'kWh', 30, 'Spec §3.4.'),
    ('electrode_separation', 'unplanned_stops', 'Unplanned stops', '非计划停机次数', 'indicator', 'count', 'stops', 40, 'Spec §3.4.'),
    ('electrode_separation', 'unplanned_stop_min', 'Unplanned stop time', '非计划停机时长', 'indicator', 'number', 'min', 50, 'Spec §3.4.'),
    ('electrode_line', 'cells_in', 'Cells in', '投入电芯数', 'indicator', 'count', 'pcs', 10, 'Spec §3.4 (the combined casing-removal and separation machine).'),
    ('electrode_line', 'run_time_min', 'Run time', '运行时间', 'indicator', 'number', 'min', 20, 'Spec §3.4.'),
    ('electrode_line', 'energy_kwh', 'Energy', '能耗', 'indicator', 'number', 'kWh', 30, 'Spec §3.4.'),
    ('electrode_line', 'unplanned_stops', 'Unplanned stops', '非计划停机次数', 'indicator', 'count', 'stops', 40, 'Spec §3.4.'),
    ('electrode_line', 'unplanned_stop_min', 'Unplanned stop time', '非计划停机时长', 'indicator', 'number', 'min', 50, 'Spec §3.4.'),
    -- 规格 §3.5 两条粉料线
    ('electrode_powder_line', 'run_time_min', 'Run time', '运行时间', 'indicator', 'number', 'min', 10, 'Spec §3.5.'),
    ('electrode_powder_line', 'energy_kwh', 'Energy', '能耗', 'indicator', 'number', 'kWh', 20, 'Spec §3.5.'),
    ('battery_powder_line', 'run_time_min', 'Run time', '运行时间', 'indicator', 'number', 'min', 10, 'Spec §3.5.'),
    ('battery_powder_line', 'energy_kwh', 'Energy', '能耗', 'indicator', 'number', 'kWh', 20, 'Spec §3.5.');

ALTER TABLE public.operation_type_fields ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_type_fields select by permission" ON public.operation_type_fields
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
CREATE POLICY "operation_type_fields insert by permission" ON public.operation_type_fields
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.processing.edit'::text));
CREATE POLICY "operation_type_fields update by permission" ON public.operation_type_fields
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE ON public.operation_type_fields TO authenticated;
REVOKE ALL ON public.operation_type_fields FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"(与 operation_types 同一条)。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.operation_type_fields
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');

-- db/tables/operation_type_equipment.sql
-- MES-4a(2026-10-07,MES-0 Q41 · MES-4a Step 0 Q9,Tim):【哪台机器跑哪道工序】—— 工序 ↔ 资产的关联,processing_runs.equipment_id
--   能变成必填的那个前置条件(此前"今天这个库里根本没有这条关联",commit_processing_run 的 EQP-2a 段落与 docs/processing-support-as-built.md)。
--   ① 只关联【设备】类资产(fixed_assets.category = 'equipment'):车辆、办公、其它不是跑工序的机器 → EQUIPMENT_LINK_NOT_EQUIPMENT|<编号>|<类>。
--   ② 规则在 commit_processing_run:一道工序只要挂着【至少一台没处置的】机器,这一炉就必须说出是哪一台,而且必须是挂着的那几台之一
--      (EQUIPMENT_REQUIRED_FOR_OPERATION · EQUIPMENT_NOT_LINKED_TO_OPERATION)。处置掉的机器不算数。
--   ③ 【引导是空的】哪台机器跑哪道工序是 Tim 的数据,在工序页上挂;这张表不在 RUNTIME CONFIG 清单里(没有引导可比 —— 与配方同一类)。
--   读:module.processing.view;写:module.processing.edit。挂上、摘下都进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.operation_type_equipment (
    operation_type_code text NOT NULL REFERENCES public.operation_types (code),
    fixed_asset_id      uuid NOT NULL REFERENCES public.fixed_assets (id),
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    PRIMARY KEY (operation_type_code, fixed_asset_id)
);

COMMENT ON TABLE public.operation_type_equipment IS
    'MES-4a:哪台机器跑哪道工序(MES-0 Q41)。只关联设备类资产;一道工序挂着至少一台没处置的机器时,它的加工单必须说出是挂着的哪一台。引导是空的(Tim 在工序页上挂)。';

CREATE INDEX operation_type_equipment_asset ON public.operation_type_equipment (fixed_asset_id);

CREATE OR REPLACE FUNCTION public.guard_operation_type_equipment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_cat  text;
BEGIN
    -- 属主读 fixed_assets(它只给财务读;挂机器的人持加工的码)—— 只取类与编号,不外泄别的列
    SELECT fa.code, fa.category INTO v_code, v_cat FROM fixed_assets fa WHERE fa.id = NEW.fixed_asset_id;
    IF v_cat IS DISTINCT FROM 'equipment' THEN
        RAISE EXCEPTION 'EQUIPMENT_LINK_NOT_EQUIPMENT|%|%', COALESCE(v_code, NEW.fixed_asset_id::text), COALESCE(v_cat, '?');
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_operation_type_equipment_guard
    BEFORE INSERT OR UPDATE ON public.operation_type_equipment
    FOR EACH ROW EXECUTE FUNCTION public.guard_operation_type_equipment();

ALTER TABLE public.operation_type_equipment ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_type_equipment select by permission" ON public.operation_type_equipment
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
CREATE POLICY "operation_type_equipment write by permission" ON public.operation_type_equipment
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.operation_type_equipment TO authenticated;
REVOKE ALL ON public.operation_type_equipment FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.operation_type_equipment
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');

-- db/tables/process_recipes.sql
-- MES-4a(2026-10-07,MES-0 Q44 · MES-4a Step 0 Q16,Tim):【配方】—— 一道工序上一组有名字的参数预设。
--   一个配方只是一个名字(code 由人敲,不走单据前缀 —— document_type_exceptions 里有一行);它的内容住在
--   process_recipe_versions 里,一版一行、写了就不改。加工单记它用的是【哪一版】(processing_runs.recipe_version_id)。
--   停用(is_active = false)= 以后别再选它;已经用过它的加工单不受影响。读:module.processing.view;写:module.processing.edit。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.process_recipes (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    operation_type_code text NOT NULL REFERENCES public.operation_types (code),
    code                text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9][A-Z0-9_-]*$'),
    name_en             text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh             text NOT NULL CHECK (btrim(name_zh) <> ''),
    is_active           boolean NOT NULL DEFAULT true,
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.process_recipes IS
    'MES-4a:一道工序上的一个配方(有名字的参数预设,MES-0 Q44)。内容在 process_recipe_versions(一版一行,写了不改);加工单记它用的那一版。code 由人敲(大写、数字、- 与 _),不走单据前缀。';

CREATE INDEX process_recipes_operation ON public.process_recipes (operation_type_code);

CREATE OR REPLACE FUNCTION public.guard_process_recipe()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'RECIPE_RETIRE_NOT_DELETE|%', OLD.code;
    END IF;
    -- 一个配方属于哪道工序、叫什么码,定了就不改 —— 它的每一版都是按那道工序的参数写的
    IF NEW.operation_type_code IS DISTINCT FROM OLD.operation_type_code OR NEW.code IS DISTINCT FROM OLD.code THEN
        RAISE EXCEPTION 'RECIPE_KEY_FIXED|%', OLD.code;
    END IF;
    NEW.updated_at := now();
    NEW.updated_by := auth.uid();
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_process_recipes_guard
    BEFORE UPDATE OR DELETE ON public.process_recipes
    FOR EACH ROW EXECUTE FUNCTION public.guard_process_recipe();

ALTER TABLE public.process_recipes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "process_recipes select by permission" ON public.process_recipes
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
CREATE POLICY "process_recipes insert by permission" ON public.process_recipes
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.processing.edit'::text));
CREATE POLICY "process_recipes update by permission" ON public.process_recipes
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE ON public.process_recipes TO authenticated;
REVOKE ALL ON public.process_recipes FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.process_recipes
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');

-- db/tables/process_recipe_versions.sql
-- MES-4a(2026-10-07,MES-0 Q44 · MES-4a Step 0 Q16,Tim):【配方的一版】—— 写了就不改(只追加)。
--   param_values = {字段码: 值},只许是这道工序上【启用着的参数】(parameter;指标是结果,不是预设 —— RECIPE_FIELD_NOT_A_PARAMETER),
--   每个值按字段的类型验(数、计数、文字、是/否)。要改就再出一版(version + 1)。
--   只经 create_recipe_version(module.processing.edit)写;UPDATE / DELETE / TRUNCATE 语句级拒(APPEND_ONLY)。
--   加工单记的是【这一版的 id】,于是"这一炉照哪一版跑的"永远答得出来,哪怕配方后来又出了新版。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.process_recipe_versions (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    recipe_id  uuid NOT NULL REFERENCES public.process_recipes (id),
    version    integer NOT NULL CHECK (version >= 1),
    param_values jsonb NOT NULL CHECK (jsonb_typeof(param_values) = 'object'),
    notes      text,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid DEFAULT auth.uid(),
    UNIQUE (recipe_id, version)
);

COMMENT ON TABLE public.process_recipe_versions IS
    'MES-4a:配方的一版(只追加)。param_values = {字段码: 值},只收这道工序上启用的参数。改配方 = 出新一版;加工单记它用的那一版。只经 create_recipe_version 写。';

CREATE TRIGGER trg_process_recipe_versions_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.process_recipe_versions
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.process_recipe_versions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "process_recipe_versions select by permission" ON public.process_recipe_versions
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
GRANT SELECT ON public.process_recipe_versions TO authenticated;
REVOKE ALL ON public.process_recipe_versions FROM anon;

-- db/tables/processing_event_types.sql
-- MES-4a(2026-10-07,规格 §3.1 · §5 · §6.2;MES-4a Step 0 Q15,Tim):【一炉里的异常事件,是哪一种】—— 一张固定的清单,没有"其它"。
--   引导三行:非计划停机 · 设备报警 · 安全报警(规格点名的三种)。加一种是加一行(/settings/dictionaries,module.processing.edit)。
--   ★ 没有 other:一件说不出是哪一种的异常没有审计价值(规格 §4.1 对损耗说的同一句话),而"其它"会把这条清单变成一个兜底桶。
--   RUNTIME CONFIG。读:module.processing.view。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.processing_event_types (
    code       text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$' AND code <> 'other'),
    name_en    text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh    text NOT NULL CHECK (btrim(name_zh) <> ''),
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.processing_event_types IS
    'MES-4a:一炉里异常事件的种类(规格 §5 "Exception events")。引导:unplanned_stop · equipment_alarm · safety_alarm;没有 other。RUNTIME CONFIG。';

INSERT INTO public.processing_event_types (code, name_en, name_zh, sort_order, notes) VALUES
    ('unplanned_stop', 'Unplanned stop', '非计划停机', 10, 'Spec §3.4: unplanned stop count and duration.'),
    ('equipment_alarm', 'Equipment alarm', '设备报警', 20, 'Spec §5: equipment alarms recorded individually.'),
    ('safety_alarm', 'Safety alarm', '安全报警', 30, 'Spec §2 · §6.2: the ERP receives the record that a safety alarm occurred; the alarm itself is hardwired at site.');

ALTER TABLE public.processing_event_types ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_event_types select by permission" ON public.processing_event_types
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
CREATE POLICY "processing_event_types write by permission" ON public.processing_event_types
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.processing_event_types TO authenticated;
REVOKE ALL ON public.processing_event_types FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.processing_event_types
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');

-- db/tables/processing_run_values.sql
-- MES-4a(2026-10-07,MES-0 Q43 · MES-4a Step 0 Q11 · Q12 · Q14 · Q29,Tim):【一炉记下的参数与指标】—— 只追加。
--   一行 = 这一炉的一个字段(operation_type_fields)的一个值;字段必须属于这一炉的工序(RUN_VALUE_FIELD_NOT_ON_OPERATION)。
--   值按字段的类型落在三列之一:value_number(number · count)· value_text(text)· value_bool(yes_no)。
--   【什么时候记】提交时(commit_processing_run 的 p_values,配方那一版先预填参数 —— source = 'recipe'),或之后在加工单页上
--   (record_run_value,action.processing_aftercare)。【必填在结平时判】(close_run_balance,Q11)—— 网关在批次结束时才送来的
--   指标,也能把一炉补完整。
--   【范围】记下的那一刻把字段的范围抄进来(range_min_at / range_max_at);越出它 → out_of_range 为真,【照记、标出来,不拒】(Q12)。
--   范围没给(Not yet set)→ out_of_range 是 NULL,不是 false —— "没法判"与"判过、在范围里"分得开。
--   【更正】一条新行:corrects_id 指回被更正的那一行、correction_reason 必填;每一行最多被更正一次(corrects_id 唯一),
--   读的人取链的末端(newest wins)。更正成"没有值"= 三列都空(撤回)。
--   【现场指针】source = 'device' 的行将来由网关的转换器写(MES-0 §3.9):inbox_id 与 site_from / site_to / site_dataset_ref。
--   本刀不建转换器(Q14);列先在这里,于是那一天不改这张表。
--   只经函数写;UPDATE / DELETE / TRUNCATE 语句级拒(APPEND_ONLY)。读:module.processing.view。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.processing_run_values (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id              uuid NOT NULL REFERENCES public.processing_runs (id),
    operation_type_code text NOT NULL,
    field_code          text NOT NULL,
    value_number        numeric,
    value_text          text,
    value_bool          boolean,
    range_min_at        numeric,
    range_max_at        numeric,
    out_of_range        boolean GENERATED ALWAYS AS (
                            CASE WHEN value_number IS NULL OR (range_min_at IS NULL AND range_max_at IS NULL) THEN NULL
                                 ELSE (value_number < range_min_at OR value_number > range_max_at) IS TRUE END) STORED,
    source              text NOT NULL CHECK (source IN ('manual', 'device', 'recipe')),
    inbox_id            bigint REFERENCES public.ingest_inbox (id),
    site_from           timestamptz,
    site_to             timestamptz,
    site_dataset_ref    text,
    recorded_at         timestamptz NOT NULL DEFAULT now(),
    recorded_by         uuid DEFAULT auth.uid(),
    corrects_id         bigint UNIQUE REFERENCES public.processing_run_values (id),
    correction_reason   text,
    FOREIGN KEY (operation_type_code, field_code) REFERENCES public.operation_type_fields (operation_type_code, field_code),
    CONSTRAINT processing_run_values_one_value
        CHECK (num_nonnulls(value_number, value_text, value_bool) = 1
               OR (num_nonnulls(value_number, value_text, value_bool) = 0 AND corrects_id IS NOT NULL)),
    CONSTRAINT processing_run_values_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> '')),
    CONSTRAINT processing_run_values_site_range
        CHECK (site_from IS NULL OR site_to IS NULL OR site_from <= site_to)
);

COMMENT ON TABLE public.processing_run_values IS
    'MES-4a:一炉记下的参数与指标,只追加。字段属于这一炉的工序;提交时或之后都能记;必填在结平时判。越出记下那一刻的范围 → out_of_range 为真(照记,不拒);范围没给 → NULL。更正 = 新行(corrects_id + 理由),读链的末端。source manual / device / recipe;device 行带现场指针(转换器以后建)。';

CREATE INDEX processing_run_values_run ON public.processing_run_values (run_id);
CREATE INDEX processing_run_values_field ON public.processing_run_values (operation_type_code, field_code);

CREATE TRIGGER trg_processing_run_values_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.processing_run_values
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.processing_run_values ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_run_values select by permission" ON public.processing_run_values
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
GRANT SELECT ON public.processing_run_values TO authenticated;
REVOKE ALL ON public.processing_run_values FROM anon;

-- db/tables/processing_run_events.sql
-- MES-4a(2026-10-07,规格 §3.1 · §5;MES-4a Step 0 Q15 · Q29,Tim):【一炉里的异常事件】—— 只追加,逐件记。
--   一行 = 一件:什么时候(occurred_at)、哪一种(processing_event_types)、多久(duration_min,可空 —— 一次报警可以没有时长)、
--   做了什么(action_taken)、谁负责(responsible_person)。规格 §3.1:"recorded individually, with time of occurrence, type, duration,
--   action taken and responsible person"。
--   【更正】新行指回原行(corrects_id 唯一)+ 必填理由;withdrawn = 这件事撤回(记错了一件不存在的事)。读链的末端。
--   【现场指针】source = 'device' 的行将来由网关的转换器写(workstation_event 类,本刀不建 —— Q14)。
--   只经 record_run_event / correct_run_event(action.processing_aftercare)写;UPDATE / DELETE / TRUNCATE 语句级拒。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.processing_run_events (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id             uuid NOT NULL REFERENCES public.processing_runs (id),
    event_type_code    text NOT NULL REFERENCES public.processing_event_types (code),
    occurred_at        timestamptz NOT NULL,
    duration_min       numeric CHECK (duration_min IS NULL OR duration_min >= 0),
    action_taken       text NOT NULL CHECK (btrim(action_taken) <> ''),
    responsible_person text NOT NULL CHECK (btrim(responsible_person) <> ''),
    notes              text,
    withdrawn          boolean NOT NULL DEFAULT false,
    source             text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'device')),
    inbox_id           bigint REFERENCES public.ingest_inbox (id),
    site_from          timestamptz,
    site_to            timestamptz,
    site_dataset_ref   text,
    recorded_at        timestamptz NOT NULL DEFAULT now(),
    recorded_by        uuid DEFAULT auth.uid(),
    corrects_id        bigint UNIQUE REFERENCES public.processing_run_events (id),
    correction_reason  text,
    CONSTRAINT processing_run_events_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> '')
               AND (NOT withdrawn OR corrects_id IS NOT NULL)),
    CONSTRAINT processing_run_events_site_range
        CHECK (site_from IS NULL OR site_to IS NULL OR site_from <= site_to)
);

COMMENT ON TABLE public.processing_run_events IS
    'MES-4a:一炉里的异常事件,逐件、只追加(规格 §3.1 · §5):时刻、种类、时长、处置、负责人。更正 = 新行(corrects_id + 理由),withdrawn = 撤回;读链的末端。';

CREATE INDEX processing_run_events_run ON public.processing_run_events (run_id);

CREATE TRIGGER trg_processing_run_events_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.processing_run_events
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.processing_run_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_run_events select by permission" ON public.processing_run_events
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
GRANT SELECT ON public.processing_run_events TO authenticated;
REVOKE ALL ON public.processing_run_events FROM anon;

-- db/tables/processing_run_closures.sql
-- MES-4a(2026-10-07,规格 §4.1;MES-0 Q46 · Q47 · Q50;MES-4a Step 0 Q17–Q23,Tim):【一炉的物料平衡结平】—— 只追加。
--   规格 §4.1:每一个分叉点,投入 = 各产出之和 + 有名字的损耗;偏差带按工序预先定好,超出它的不能直接结,要一句书面说明。
--   一行 = 一次结平,抄下那一刻的账:投入、产出、有名字的损耗、余数(= 投入 − 产出 − 有名字的损耗,即"没解释的质量")、
--   那道工序当时的容差(balance_tolerance_pct;为空 = Not yet set,V1)与判断(within_tolerance;容差没给时为 NULL)、说明、谁、何时。
--   ★ 规则在 close_run_balance(action.processing_aftercare,Q50):余数为 0 → 结;在一个【给了的】容差里 → 结,说明可选;
--     容差没给而余数不为 0(Q46),或超出容差(Q47)→ 必须写说明,不要第二个人。必填的值缺着、或有产出没挂称重 → 不许结。
--   【重开】之后再有一条损耗或一个值被记下或更正(它们的 id 大于这一行抄下的水位线 loss_watermark / value_watermark),
--   这次结平就【不再是当前的】—— 那一炉回到"没结平",要人再结一次。只追加,所以重开不改任何一行:它是读出来的。
--   水位线用 id(identity)而不是时间:同一笔事务里写的两行,now() 一模一样(AGENTS.md「取最新那一行」)。
--   UPDATE / DELETE / TRUNCATE 语句级拒。读:module.processing.view。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.processing_run_closures (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id           uuid NOT NULL REFERENCES public.processing_runs (id),
    input_qty        numeric NOT NULL,
    output_qty       numeric NOT NULL,
    named_loss_qty   numeric NOT NULL,
    remainder_qty    numeric NOT NULL,
    tolerance_pct    numeric,
    within_tolerance boolean,
    explanation      text,
    loss_watermark   bigint NOT NULL DEFAULT 0,
    value_watermark  bigint NOT NULL DEFAULT 0,
    closed_at        timestamptz NOT NULL DEFAULT now(),
    closed_by        uuid DEFAULT auth.uid(),
    CONSTRAINT processing_run_closures_arithmetic
        CHECK (remainder_qty = input_qty - output_qty - named_loss_qty),
    CONSTRAINT processing_run_closures_explained
        CHECK (remainder_qty = 0 OR within_tolerance IS TRUE OR (explanation IS NOT NULL AND btrim(explanation) <> ''))
);

COMMENT ON TABLE public.processing_run_closures IS
    'MES-4a:一炉物料平衡的结平(规格 §4.1),只追加。抄下那一刻的投入 · 产出 · 有名字的损耗 · 余数 · 容差与判断 · 说明。余数不为 0 而又不在一个给了的容差里 → 必须有说明(表上的 CHECK 与 close_run_balance 同一句)。之后的损耗或值越过水位线 → 这次结平不再当前(重开是读出来的)。';

CREATE INDEX processing_run_closures_run ON public.processing_run_closures (run_id);

CREATE TRIGGER trg_processing_run_closures_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.processing_run_closures
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.processing_run_closures ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_run_closures select by permission" ON public.processing_run_closures
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
GRANT SELECT ON public.processing_run_closures TO authenticated;
REVOKE ALL ON public.processing_run_closures FROM anon;

-- db/tables/processing_run_corrections.sql
-- MES-4a(2026-10-07,规格 §4.2;MES-0 Q49;MES-4a Step 0 Q30,Tim):【加工单表头的更正】—— 只追加。
--   只有六个字段改得了:开始 · 结束 · 班次 · 机器 · 配方版本 · 备注(correct_run_header)。一次更正 = 一行:哪个字段、原来是什么、
--   改成什么、为什么(必填)、谁、何时;表头随之改成新值 —— 原值留在这里与变更记录里。
--   【改不了的】加工日、数量、工序、工单:那些改了就是另一炉 —— 走回滚申请(CFO)+ 一张新单带 corrects_run_id(Q31)。
--   UPDATE / DELETE / TRUNCATE 语句级拒。读:module.processing.view。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.processing_run_corrections (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       uuid NOT NULL REFERENCES public.processing_runs (id),
    field        text NOT NULL CHECK (field IN ('started_at', 'ended_at', 'shift_code', 'equipment_id', 'recipe_version_id', 'notes')),
    old_value    text,
    new_value    text,
    reason       text NOT NULL CHECK (btrim(reason) <> ''),
    corrected_at timestamptz NOT NULL DEFAULT now(),
    corrected_by uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.processing_run_corrections IS
    'MES-4a:加工单表头的更正,只追加 —— 开始 · 结束 · 班次 · 机器 · 配方版本 · 备注六个字段;原值、新值、理由(必填)、谁、何时。加工日、数量、工序、工单不在这里改(回滚 + 新单)。';

CREATE INDEX processing_run_corrections_run ON public.processing_run_corrections (run_id);

CREATE TRIGGER trg_processing_run_corrections_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.processing_run_corrections
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.processing_run_corrections ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_run_corrections select by permission" ON public.processing_run_corrections
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
GRANT SELECT ON public.processing_run_corrections TO authenticated;
REVOKE ALL ON public.processing_run_corrections FROM anon;

-- 带 code 列的表要么是单据、要么在例外表里带一句理由(fixture 102 · check-document-registry)。镜像原样。
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
    ('process_recipes',               '配方目录(MES-4a):code 是由人敲的配方名,加工单经它的版本引用它 —— 不是一张开得出来的单据(Q16)'),
    ('processing_event_types',        '异常事件种类目录(MES-4a):code 是种类代号,加工单的异常事件引用它');

-- ── 4 · 加工单表头(Q7 · Q16 · Q31 · Q32):五列 + 授权 + 遮蔽视图(三件事一起);UPDATE 策略拿掉;直连改按名拒;新单的表头闸 ──
ALTER TABLE public.processing_runs
    ADD COLUMN started_at timestamptz,
    ADD COLUMN ended_at timestamptz,
    ADD COLUMN shift_code text REFERENCES public.shifts (code),
    ADD COLUMN recipe_version_id uuid REFERENCES public.process_recipe_versions (id),
    ADD COLUMN corrects_run_id uuid UNIQUE REFERENCES public.processing_runs (id),
    ADD CONSTRAINT processing_runs_end_after_start CHECK (ended_at IS NULL OR started_at IS NULL OR ended_at > started_at);
DROP POLICY "processing_runs update by permission" ON public.processing_runs;
GRANT SELECT (id, code, process_date, total_input, total_output, loss_qty, notes, status, deleted_at, created_at, created_by, updated_at, updated_by, allocation_basis, allocation_snapshot, allocated_at, allocated_by, capitalization_entry_id, allocation_basis_changed_at, work_order_id, deleted_by, delete_reason, equipment_id, operation_type_code, started_at, ended_at, shift_code, recipe_version_id, corrects_run_id)
    ON public.processing_runs TO authenticated;

DROP TRIGGER trg_processing_runs_direct_write ON public.processing_runs;
DROP TRIGGER trg_processing_runs_direct_delete ON public.processing_runs;
CREATE TRIGGER trg_processing_runs_direct_write
    BEFORE INSERT ON public.processing_runs
    FOR EACH ROW EXECUTE FUNCTION public.guard_processing_direct_write();
CREATE TRIGGER trg_processing_runs_direct_change
    BEFORE UPDATE OR DELETE ON public.processing_runs
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_processing_direct_write();
CREATE TRIGGER trg_processing_runs_header
    BEFORE INSERT ON public.processing_runs
    FOR EACH ROW EXECUTE FUNCTION public.guard_processing_run_header();
COMMENT ON COLUMN public.processing_runs.started_at IS
    'MES-4a(MES-0 Q42):这一炉开始的时刻。MES-4a 起提交的每一张必填(RUN_TIMES_REQUIRED);之前的单为空 —— 不回填。读者用"开始时刻为空"认出结平之前记下的单(processing_run_balance_all.balance_state = before_closure)。';
COMMENT ON COLUMN public.processing_runs.shift_code IS
    'MES-4a(MES-0 Q42):这一炉哪个班。选的,不是推的 —— 班次的起止时刻今天是空的(V6 · V7),推不出来。MES-4a 起提交的每一张必填(RUN_SHIFT_REQUIRED)。';
COMMENT ON COLUMN public.processing_runs.corrects_run_id IS
    'MES-4a(MES-0 Q49 · Q31):这一张是来更正哪一张的。数量的更正 = 回滚申请(CFO)冲掉原单 + 一张新单指回它;原单必须已经回滚,而且只能被更正一次。';

-- db/views/processing_runs_masked.sql
-- 遮蔽伴生视图:processing_runs 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:capitalized_cost_base → data.view_prices, material_cost_base → data.view_prices, process_cost_base → data.view_prices, total_cost_base → data.view_prices
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.processing.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.
-- PROC-WIRE-1B-i fu1:加了 operation_type_code(不遮蔽,原样透出)。
-- EQP-2a:加了 equipment_id(不遮蔽,原样透出)。
-- MES-4a:加了 started_at · ended_at · shift_code · recipe_version_id · corrects_run_id(都不遮蔽,原样透出;列清单授权同一支迁移)。**一旦一张表有了 _masked 伴生,
-- 它的每一列都必须在这张视图里** —— 授没授权都一样(colgrant 的第二个分支)。

CREATE OR REPLACE VIEW public.processing_runs_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    process_date,
    total_input,
    total_output,
    loss_qty,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    allocation_basis,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN material_cost_base
            ELSE NULL::numeric
        END AS material_cost_base,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN process_cost_base
            ELSE NULL::numeric
        END AS process_cost_base,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN total_cost_base
            ELSE NULL::numeric
        END AS total_cost_base,
    allocation_snapshot,
    allocated_at,
    allocated_by,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN capitalized_cost_base
            ELSE NULL::numeric
        END AS capitalized_cost_base,
    capitalization_entry_id,
    allocation_basis_changed_at,
    work_order_id,
    deleted_by,
    delete_reason,
    equipment_id,
    operation_type_code,
    started_at,
    ended_at,
    shift_code,
    recipe_version_id,
    corrects_run_id
   FROM processing_runs
  WHERE has_permission('module.processing.view'::text);

-- ── 5 · 产出腿的称重(Q24):一列 + 授权 + 遮蔽视图;UPDATE 策略拿掉;直连改按名拒 ──────────────────────────
ALTER TABLE public.processing_outputs ADD COLUMN weighing_id uuid UNIQUE REFERENCES public.weighings (id);
DROP POLICY "processing_outputs update by permission" ON public.processing_outputs;
GRANT SELECT (id, run_id, output_batch_id, quantity_produced, created_at, cost_incomplete, weighing_id)
    ON public.processing_outputs TO authenticated;
DROP TRIGGER trg_processing_outputs_direct_delete ON public.processing_outputs;
CREATE TRIGGER trg_processing_outputs_direct_change
    BEFORE UPDATE OR DELETE ON public.processing_outputs
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_processing_direct_write();
COMMENT ON COLUMN public.processing_outputs.weighing_id IS
    'MES-4a(MES-0 Q22):这条产出腿的数量来自哪一次称重(一条确认了的、单独的、没被更正过的净重;quantity_produced = 它的 weight_kg)。提交时选一条,或敲一个重量 —— 后者在同一笔事务里经正常的录入路径落一条手工称重。一次称重只给一条腿用。挂上之后那条称重不能再更正(WEIGHING_IN_USE):数量的更正是回滚 + 新单。之前的单为空。';

-- db/views/processing_outputs_masked.sql
-- 遮蔽伴生视图:processing_outputs 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:allocated_cost_base → data.view_prices, unit_cost_base → data.view_prices
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.processing.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.
-- FIN-25:追加 cost_incomplete(不敏感 —— 布尔标记,不是价格;列清单授权同步扩)。
-- MES-4a:追加 weighing_id(不敏感 —— 一次称重的引用;列清单授权同一支迁移)。

CREATE OR REPLACE VIEW public.processing_outputs_masked WITH (security_invoker = off) AS
 SELECT id,
    run_id,
    output_batch_id,
    quantity_produced,
    created_at,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN allocated_cost_base
            ELSE NULL::numeric
        END AS allocated_cost_base,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_cost_base
            ELSE NULL::numeric
        END AS unit_cost_base,
    cost_incomplete,
    weighing_id
   FROM processing_outputs
  WHERE has_permission('module.processing.view'::text);

-- ── 6 · 投入腿:UPDATE 策略拿掉;直连改按名拒 ──────────────────────────────────────────
DROP POLICY "processing_inputs update by permission" ON public.processing_inputs;
DROP TRIGGER trg_processing_inputs_direct_delete ON public.processing_inputs;
CREATE TRIGGER trg_processing_inputs_direct_change
    BEFORE UPDATE OR DELETE ON public.processing_inputs
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_processing_direct_write();

-- ── 7 · 损耗改成只追加(Q28):id 主键 · 更正链 · 撤回 = 更正成 0 · 只经两支函数写 · 绑定键跟着换 ──────────────────
DROP POLICY "processing_run_losses insert by permission" ON public.processing_run_losses;
DROP POLICY "processing_run_losses update by permission" ON public.processing_run_losses;
DROP POLICY "processing_run_losses delete by permission" ON public.processing_run_losses;
DROP TRIGGER enforce_write_permission ON public.processing_run_losses;
DROP TRIGGER trg_processing_run_losses_within_total ON public.processing_run_losses;
ALTER TABLE public.processing_run_losses DROP CONSTRAINT processing_run_losses_pkey;
ALTER TABLE public.processing_run_losses DROP CONSTRAINT processing_run_losses_quantity_check;
ALTER TABLE public.processing_run_losses
    ADD COLUMN id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ADD COLUMN corrects_id bigint UNIQUE REFERENCES public.processing_run_losses (id),
    ADD COLUMN correction_reason text,
    ADD CONSTRAINT processing_run_losses_quantity_shape
        CHECK (quantity > 0 OR (quantity = 0 AND corrects_id IS NOT NULL)),
    ADD CONSTRAINT processing_run_losses_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> ''));
CREATE UNIQUE INDEX processing_run_losses_one_original ON public.processing_run_losses (run_id, loss_category_code)
    WHERE corrects_id IS NULL;
CREATE CONSTRAINT TRIGGER trg_processing_run_losses_within_total
    AFTER INSERT ON public.processing_run_losses
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW EXECUTE FUNCTION public.guard_processing_run_losses();
CREATE TRIGGER trg_processing_run_losses_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.processing_run_losses
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();
REVOKE ALL ON public.processing_run_losses FROM authenticated, anon;
GRANT SELECT ON public.processing_run_losses TO authenticated;
DROP TRIGGER zzz_change_log ON public.processing_run_losses;
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.processing_run_losses
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
COMMENT ON TABLE public.processing_run_losses IS
'PROC-BUILD-1:一张加工单上【分了类的那部分损耗】,一类一行。

【它与 processing_runs.loss_qty 的关系 —— 本刀【不动】那一列】
  * **它们不必相等,而且现在【刻意】不要求相等。** 产线还没开,没有人知道
    三类各占多少;要求相等等于逼操作员编一个数去凑平,而编出来的数
    与量出来的数在报表里长得一模一样。
  * **但分类之和【不许超过】 loss_qty** —— 这条守得住,因为它不需要知道真实配比。
    它与 commit_processing_run 的 OUTPUT_EXCEEDS_INPUT 是同一个形状:
    一条【不等式】可以在真值未知时断言,一条【等式】不行。
    违反时按名拒:LOSS_CATEGORIES_EXCEED_LOSS_QTY。
  * 差额(loss_qty − 已分类之和)= **还没有解释的质量**,由
    processing_run_loss_breakdown 说出来。

【★ 它【不能】回答的那个问题,写在这里免得被当成已解决 ★】
**"过磅误差不是损耗"** —— 这张表把质量分成【已解释】与【未解释】两部分,
但【未解释】里混着两件事:还没有人去分类的损耗,与账本身对不上。
**要分开这两件,需要有人【断言】"这批数字对不上",而那个断言今天没有地方放。**
本刀【刻意不建】一个叫"过磅误差"的损耗类别 —— 那会把一个记账问题
伪装成一件物理事实,而这正是 loss_qty 今天在犯的错的小号版本。
记为遗留缺口,归属:称重与对账那一刀。';
COMMENT ON COLUMN public.processing_run_losses.quantity IS
'PROC-BUILD-1:这一类损耗的量,单位与加工单一致。原始记录**必须为正** ——
一笔为零的损耗与"没有这一类"分不开,而后者由"没有这一行"表示。
MES-4a:更正行可以是 0 —— 那就是撤回这一类(链的末端是 0,当前之和不算它)。';

-- ── 8 · 新函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/assert_run_equipment.sql
-- MES-4a(2026-10-07,MES-0 Q41;MES-4a Step 0 Q9,Tim):【这一炉的机器说得通吗】—— 一份判据,两个调用方:
--   commit_processing_run(提交)· correct_run_header(更正机器)。
--   ① 给了机器(EQP-2a 的三条,原样搬来):EQUIPMENT_NOT_FOUND · EQUIPMENT_NOT_ACQUIRED(加工日早于取得日)·
--      EQUIPMENT_DISPOSED(加工日晚于处置日)。投用之前【不】拒 —— 试车是有名有姓的事(见 commit_processing_run 原注)。
--   ② 工序 ↔ 资产(operation_type_equipment):这道工序挂着至少一台【没处置的】机器 → 必须给机器(EQUIPMENT_REQUIRED_FOR_OPERATION|<工序>),
--      而且必须是挂着的那几台之一(EQUIPMENT_NOT_LINKED_TO_OPERATION|<编号>|<工序>)。处置掉的机器不算数。
--      没挂任何机器的工序:机器可选,给了也照收(U1-B 可选选择器今天的样子;挂不挂是 Tim 的数据)。
--   【内层】不是 SECURITY DEFINER、没有调用者检查(调用方都是 DEFINER,以属主身份读 fixed_assets);EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql (the EQP-2a checks moved here from commit_processing_run).

CREATE OR REPLACE FUNCTION public.assert_run_equipment(p_operation_type_code text, p_equipment_id uuid, p_process_date date)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_eq     fixed_assets%ROWTYPE;
    v_linked integer;
BEGIN
    IF p_equipment_id IS NOT NULL THEN
        SELECT * INTO v_eq FROM fixed_assets WHERE id = p_equipment_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_FOUND|%', p_equipment_id;
        END IF;
        -- 【拒绝的边界钉在"真的不可能"上,不钉在"还没投用"上】加工日早于取得日 = 那天这台机器还不是我们的。
        IF p_process_date < v_eq.acquisition_date THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_ACQUIRED|%|%|%', v_eq.code, v_eq.acquisition_date, p_process_date
              USING HINT = '这一炉的日期早于这台机器的取得日 —— 那天它还不是我们的';
        END IF;
        -- 处置之后它已经不在了。
        IF v_eq.status = 'disposed' AND v_eq.disposal_date IS NOT NULL AND p_process_date > v_eq.disposal_date THEN
            RAISE EXCEPTION 'EQUIPMENT_DISPOSED|%|%|%', v_eq.code, v_eq.disposal_date, p_process_date
              USING HINT = '这一炉的日期晚于这台机器的处置日 —— 那时它已经不在了';
        END IF;
    END IF;

    SELECT count(*) INTO v_linked
      FROM operation_type_equipment l JOIN fixed_assets fa ON fa.id = l.fixed_asset_id
     WHERE l.operation_type_code = p_operation_type_code AND fa.status <> 'disposed';
    IF v_linked > 0 THEN
        IF p_equipment_id IS NULL THEN
            RAISE EXCEPTION 'EQUIPMENT_REQUIRED_FOR_OPERATION|%', p_operation_type_code
              USING HINT = '这道工序挂着机器 —— 选这一炉跑在哪一台上。';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM operation_type_equipment l JOIN fixed_assets fa ON fa.id = l.fixed_asset_id
                        WHERE l.operation_type_code = p_operation_type_code AND l.fixed_asset_id = p_equipment_id
                          AND fa.status <> 'disposed') THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_LINKED_TO_OPERATION|%|%', v_eq.code, p_operation_type_code
              USING HINT = '这台机器没有挂在这道工序上(或已处置)。在工序页上挂上它,或选挂着的那一台。';
        END IF;
    END IF;
END;
$function$;

-- db/functions/record_manual_weighing_internal.sql
-- MES-4a(2026-10-07,规格 §3.2 规则 1;MES-0 Q22;MES-4a Step 0 Q24,Tim):【一次在提交那一刻敲进来的称重】—— 内层。
--   规格 §3.2:"weighing and recording occur within the same action"。操作员在提交加工单时给一条产出腿敲一个重量(没有现成的称重
--   可挑),这一支就走【正常的录入路径】落一条手工称重:收件箱 manual(录入人 = 本人)→ 同一个分派器、同一支转换器(transform_weighing_v1)
--   → 草稿 → 由录入人在同一步里确认(capture_confirm_internal)。与 submit_manual_capture 逐字同一条路,只是不再查 action.confirm_capture ——
--   调用方 commit_processing_run 已经查过 action.processing_commit,而这一磅就是那一次提交的一部分。
--   仪器可选:给了,就要是一台没停用的秤 / 地磅 / 电表 / 在线仪表(CAPTURE_DEVICE_INVALID);没给,这一磅标"没有记录仪器",照收。
--   转换没过 → 按转换器那一句码拒(整笔回滚)。返回新称重的 id。
--   【内层】不是 SECURITY DEFINER、没有调用者检查;EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.record_manual_weighing_internal(p_weight_kg numeric, p_device_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_payload jsonb;
    v_inbox   bigint;
    v_state   text;
    v_err     text;
    v_draft   uuid;
BEGIN
    IF p_device_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM devices d WHERE d.id = p_device_id AND d.retired_at IS NULL
               AND d.kind IN ('scale', 'weighbridge', 'meter', 'inline_instrument')) THEN
        RAISE EXCEPTION 'CAPTURE_DEVICE_INVALID|%', p_device_id;
    END IF;
    v_payload := jsonb_build_object('weight_kg', p_weight_kg);
    INSERT INTO ingest_inbox (source, entered_by, device_id, data_class, payload, payload_bytes, payload_sha256)
    VALUES ('manual', auth.uid(), p_device_id, 'weighing', v_payload, octet_length(v_payload::text),
            sha256(convert_to(v_payload::text, 'UTF8')))
    RETURNING id INTO v_inbox;
    v_state := ingest_transform_row(v_inbox);
    IF v_state <> 'transformed' THEN
        SELECT error_code INTO v_err FROM ingest_inbox WHERE id = v_inbox;
        RAISE EXCEPTION '%', COALESCE(v_err, 'CAPTURE_NOT_TRANSFORMED|' || v_state);
    END IF;
    SELECT id INTO v_draft FROM capture_drafts WHERE inbox_id = v_inbox;
    RETURN capture_confirm_internal(v_draft, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, NULL, NULL);
END;
$function$;

-- db/functions/record_run_value_internal.sql
-- MES-4a(2026-10-07,MES-0 Q43;MES-4a Step 0 Q10–Q12 · Q29,Tim):【给一炉记一个值,或更正一个值】—— 内层,一份判据三个调用方:
--   commit_processing_run(提交时的值与配方预填)· record_run_value · correct_run_value(之后在加工单页上)。
--   ① 字段必须属于这一炉的工序(RUN_VALUE_FIELD_NOT_ON_OPERATION|<字段>|<工序>);【新记】一个值时字段必须启用着(RUN_VALUE_FIELD_RETIRED|<字段>)
--      —— 更正一个旧值不看它(退役不冻结历史)。
--   ② 新记时这一炉这个字段已经有一个当前值 → RUN_VALUE_ALREADY_RECORDED|<字段>(要改就更正它,不是再记一条)。
--   ③ 值按字段的类型验:number → 数 · count → 不小于 0 的整数 · text → 非空文字 · yes_no → true / false;不对 → RUN_VALUE_INVALID|<字段>|<类型>。
--      更正时可以给 null = 撤回(三列都空)。
--   ④ 记下那一刻抄进字段的范围(range_min_at / range_max_at)—— 越出它照记,out_of_range 由表上的生成列算出来(不拒,Q12)。
--   ⑤ 更正:被更正的那一行必须是这一炉的、而且是链的末端(RUN_VALUE_SUPERSEDED|<id>);理由必填(RUN_VALUE_CORRECTION_REASON_REQUIRED)。
--   返回新行的 id。【内层】不是 SECURITY DEFINER、没有调用者检查;EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.record_run_value_internal(p_run_id uuid, p_field_code text, p_value jsonb, p_source text, p_corrects bigint, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_op    text;
    v_f     operation_type_fields%ROWTYPE;
    v_orig  processing_run_values%ROWTYPE;
    v_num   numeric;
    v_txt   text;
    v_bool  boolean;
    v_id    bigint;
BEGIN
    SELECT r.operation_type_code INTO v_op FROM processing_runs r WHERE r.id = p_run_id;
    IF p_corrects IS NOT NULL THEN
        SELECT * INTO v_orig FROM processing_run_values v WHERE v.id = p_corrects AND v.run_id = p_run_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'RUN_VALUE_NOT_FOUND|%', p_corrects;
        END IF;
        IF EXISTS (SELECT 1 FROM processing_run_values x WHERE x.corrects_id = v_orig.id) THEN
            RAISE EXCEPTION 'RUN_VALUE_SUPERSEDED|%', v_orig.id;
        END IF;
        IF p_reason IS NULL OR btrim(p_reason) = '' THEN
            RAISE EXCEPTION 'RUN_VALUE_CORRECTION_REASON_REQUIRED';
        END IF;
        p_field_code := v_orig.field_code;
    END IF;
    SELECT * INTO v_f FROM operation_type_fields f WHERE f.operation_type_code = v_op AND f.field_code = p_field_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_VALUE_FIELD_NOT_ON_OPERATION|%|%', COALESCE(p_field_code, '?'), COALESCE(v_op, '?');
    END IF;
    IF p_corrects IS NULL THEN
        IF NOT v_f.is_active THEN
            RAISE EXCEPTION 'RUN_VALUE_FIELD_RETIRED|%', p_field_code;
        END IF;
        IF EXISTS (SELECT 1 FROM processing_run_values v
                    WHERE v.run_id = p_run_id AND v.field_code = p_field_code
                      AND NOT EXISTS (SELECT 1 FROM processing_run_values x WHERE x.corrects_id = v.id)) THEN
            RAISE EXCEPTION 'RUN_VALUE_ALREADY_RECORDED|%', p_field_code;
        END IF;
    END IF;

    IF p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN
        IF p_corrects IS NULL THEN
            RAISE EXCEPTION 'RUN_VALUE_INVALID|%|%', p_field_code, v_f.value_type;
        END IF;
    ELSIF v_f.value_type IN ('number', 'count') THEN
        BEGIN
            v_num := CASE jsonb_typeof(p_value) WHEN 'number' THEN (p_value #>> '{}')::numeric
                                                 WHEN 'string' THEN NULLIF(btrim(p_value #>> '{}'), '')::numeric END;
        EXCEPTION WHEN others THEN
            v_num := NULL;
        END;
        IF v_num IS NULL OR (v_f.value_type = 'count' AND (v_num < 0 OR v_num <> trunc(v_num))) THEN
            RAISE EXCEPTION 'RUN_VALUE_INVALID|%|%', p_field_code, v_f.value_type;
        END IF;
    ELSIF v_f.value_type = 'text' THEN
        v_txt := NULLIF(btrim(p_value #>> '{}'), '');
        IF v_txt IS NULL THEN
            RAISE EXCEPTION 'RUN_VALUE_INVALID|%|%', p_field_code, v_f.value_type;
        END IF;
    ELSE
        v_bool := CASE WHEN jsonb_typeof(p_value) = 'boolean' THEN (p_value #>> '{}')::boolean
                       WHEN lower(p_value #>> '{}') IN ('true', 'yes') THEN true
                       WHEN lower(p_value #>> '{}') IN ('false', 'no') THEN false END;
        IF v_bool IS NULL THEN
            RAISE EXCEPTION 'RUN_VALUE_INVALID|%|%', p_field_code, v_f.value_type;
        END IF;
    END IF;

    INSERT INTO processing_run_values (run_id, operation_type_code, field_code, value_number, value_text, value_bool,
                                       range_min_at, range_max_at, source, corrects_id, correction_reason)
    VALUES (p_run_id, v_op, p_field_code, v_num, v_txt, v_bool,
            CASE WHEN v_f.has_range THEN v_f.range_min END, CASE WHEN v_f.has_range THEN v_f.range_max END,
            COALESCE(p_source, 'manual'), p_corrects, NULLIF(btrim(COALESCE(p_reason, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/record_run_value.sql
-- MES-4a(2026-10-07,MES-0 Q43;MES-4a Step 0 Q11 · Q34,Tim):【提交之后,在加工单页上给一炉记一个值】。
--   持 action.processing_aftercare(记损耗与交接班的那个码 —— 提交之后的补记归它,Q34)。加工单必须已提交、没回滚(RUN_NOT_COMMITTED)。
--   判据全在 record_run_value_internal(字段属于这道工序、启用着、还没有当前值、按类型验、抄范围)。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.record_run_value(p_run_id uuid, p_field_code text, p_value jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run processing_runs%ROWTYPE;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, p_run_id::text);
    END IF;
    RETURN record_run_value_internal(p_run_id, p_field_code, p_value, 'manual', NULL, NULL);
END;
$function$;

-- db/functions/correct_run_value.sql
-- MES-4a(2026-10-07,规格 §4.2;MES-0 Q49;MES-4a Step 0 Q29,Tim):【更正一炉的一个值】—— 不改原行,落一条新的指回它(newest wins)。
--   持 action.processing_aftercare。理由必填;只能更正链的末端;p_value 为 null = 撤回这个值。加工单必须已提交、没回滚。
--   判据在 record_run_value_internal。返回新行 id。之后结平的水位线被越过 → 那一炉回到"没结平"(Q19)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.correct_run_value(p_value_id bigint, p_value jsonb, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run processing_runs%ROWTYPE;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT r.* INTO v_run FROM processing_runs r JOIN processing_run_values v ON v.run_id = r.id
     WHERE v.id = p_value_id FOR UPDATE OF r;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_VALUE_NOT_FOUND|%', p_value_id;
    END IF;
    IF v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.code;
    END IF;
    RETURN record_run_value_internal(v_run.id, NULL, p_value, 'manual', p_value_id, p_reason);
END;
$function$;

-- db/functions/run_event_check.sql
-- MES-4a(2026-10-07,MES-4a Step 0 Q15,Tim):【一件异常事件的五样说得通吗】—— 一份判据,两个调用方(record_run_event · correct_run_event)。
--   种类是字典里启用着的(RUN_EVENT_TYPE_UNKNOWN|<码>)· 时刻必填(RUN_EVENT_TIME_REQUIRED)· 时长为空或不为负(RUN_EVENT_DURATION_INVALID)·
--   做了什么(RUN_EVENT_ACTION_REQUIRED)· 谁负责(RUN_EVENT_RESPONSIBLE_REQUIRED)。
--   【内层】只读事件种类字典,没有调用者检查;EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.run_event_check(p_event_type text, p_occurred_at timestamp with time zone, p_duration_min numeric, p_action_taken text, p_responsible_person text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM processing_event_types t WHERE t.code = p_event_type AND t.is_active) THEN
        RAISE EXCEPTION 'RUN_EVENT_TYPE_UNKNOWN|%', COALESCE(p_event_type, '?');
    END IF;
    IF p_occurred_at IS NULL THEN
        RAISE EXCEPTION 'RUN_EVENT_TIME_REQUIRED';
    END IF;
    IF p_duration_min IS NOT NULL AND p_duration_min < 0 THEN
        RAISE EXCEPTION 'RUN_EVENT_DURATION_INVALID|%', p_duration_min;
    END IF;
    IF p_action_taken IS NULL OR btrim(p_action_taken) = '' THEN
        RAISE EXCEPTION 'RUN_EVENT_ACTION_REQUIRED';
    END IF;
    IF p_responsible_person IS NULL OR btrim(p_responsible_person) = '' THEN
        RAISE EXCEPTION 'RUN_EVENT_RESPONSIBLE_REQUIRED';
    END IF;
END;
$function$;

-- db/functions/record_run_event.sql
-- MES-4a(2026-10-07,规格 §3.1 · §5;MES-4a Step 0 Q15 · Q34,Tim):【给一炉记一件异常】—— 逐件记。
--   持 action.processing_aftercare。加工单必须已提交、没回滚(RUN_NOT_COMMITTED)。种类必须是字典里启用着的(RUN_EVENT_TYPE_UNKNOWN);
--   时刻必填(RUN_EVENT_TIME_REQUIRED);时长不为负(RUN_EVENT_DURATION_INVALID);做了什么、谁负责必填(RUN_EVENT_ACTION_REQUIRED ·
--   RUN_EVENT_RESPONSIBLE_REQUIRED)。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.record_run_event(p_run_id uuid, p_event_type text, p_occurred_at timestamp with time zone, p_duration_min numeric, p_action_taken text, p_responsible_person text, p_notes text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run processing_runs%ROWTYPE;
    v_id  bigint;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, p_run_id::text);
    END IF;
    PERFORM run_event_check(p_event_type, p_occurred_at, p_duration_min, p_action_taken, p_responsible_person);
    INSERT INTO processing_run_events (run_id, event_type_code, occurred_at, duration_min, action_taken, responsible_person, notes)
    VALUES (p_run_id, p_event_type, p_occurred_at, p_duration_min, btrim(p_action_taken), btrim(p_responsible_person),
            NULLIF(btrim(COALESCE(p_notes, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/correct_run_event.sql
-- MES-4a(2026-10-07,规格 §4.2;MES-0 Q49;MES-4a Step 0 Q29,Tim):【更正一件异常事件】—— 不改原行,落一条新的指回它(newest wins)。
--   持 action.processing_aftercare。理由必填(RUN_EVENT_CORRECTION_REASON_REQUIRED);只能更正链的末端(RUN_EVENT_SUPERSEDED);
--   p_withdraw = true 撤回这件事(记错了一件不存在的事 —— 五样照抄原行,withdrawn 为真);否则五样按新值、过同一份判据。
--   加工单必须已提交、没回滚。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.correct_run_event(p_event_id bigint, p_event_type text, p_occurred_at timestamp with time zone, p_duration_min numeric, p_action_taken text, p_responsible_person text, p_notes text, p_withdraw boolean, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run  processing_runs%ROWTYPE;
    v_orig processing_run_events%ROWTYPE;
    v_id   bigint;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT * INTO v_orig FROM processing_run_events WHERE id = p_event_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_EVENT_NOT_FOUND|%', p_event_id;
    END IF;
    SELECT * INTO v_run FROM processing_runs WHERE id = v_orig.run_id FOR UPDATE;
    IF v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.code;
    END IF;
    IF EXISTS (SELECT 1 FROM processing_run_events x WHERE x.corrects_id = v_orig.id) THEN
        RAISE EXCEPTION 'RUN_EVENT_SUPERSEDED|%', v_orig.id;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'RUN_EVENT_CORRECTION_REASON_REQUIRED';
    END IF;
    IF COALESCE(p_withdraw, false) THEN
        INSERT INTO processing_run_events (run_id, event_type_code, occurred_at, duration_min, action_taken, responsible_person, notes,
                                           withdrawn, corrects_id, correction_reason)
        VALUES (v_orig.run_id, v_orig.event_type_code, v_orig.occurred_at, v_orig.duration_min, v_orig.action_taken,
                v_orig.responsible_person, v_orig.notes, true, v_orig.id, btrim(p_reason))
        RETURNING id INTO v_id;
    ELSE
        PERFORM run_event_check(p_event_type, p_occurred_at, p_duration_min, p_action_taken, p_responsible_person);
        INSERT INTO processing_run_events (run_id, event_type_code, occurred_at, duration_min, action_taken, responsible_person, notes,
                                           corrects_id, correction_reason)
        VALUES (v_orig.run_id, p_event_type, p_occurred_at, p_duration_min, btrim(p_action_taken), btrim(p_responsible_person),
                NULLIF(btrim(COALESCE(p_notes, '')), ''), v_orig.id, btrim(p_reason))
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$function$;

-- db/functions/record_run_loss.sql
-- MES-4a(2026-10-07,规格 §4.1 · §4.2;MES-0 Q49;MES-4a Step 0 Q28,Tim):【给一炉记一条有名字的损耗】—— 只追加的那张表的两扇门之一。
--   此前页面直连 upsert 这张表;现在只经这里与 correct_run_loss。码与此前那三条写策略同一组:module.processing.edit 或
--   action.processing_aftercare(仓库 —— 提交加工的人记它的损耗,ROLE-1 Batch 3b Q2)。
--   加工单必须已提交、没回滚(RUN_NOT_COMMITTED);类别必须启用着(RUN_LOSS_CATEGORY_UNKNOWN);量为正(RUN_LOSS_QTY_INVALID);
--   这一类已经有一条(任何一条,哪怕撤回成 0)→ RUN_LOSS_ALREADY_RECORDED|<类别>(要改就更正它)。
--   有名字的损耗之和不许超过 loss_qty(= 投入 − 产出)—— 表上的约束触发器 LOSS_CATEGORIES_EXCEED_LOSS_QTY。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.record_run_loss(p_run_id uuid, p_loss_category_code text, p_quantity numeric, p_notes text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run processing_runs%ROWTYPE;
    v_id  bigint;
BEGIN
    IF NOT has_any_permission(ARRAY['module.processing.edit', 'action.processing_aftercare']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.processing_aftercare';
    END IF;
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, p_run_id::text);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM loss_categories c WHERE c.code = p_loss_category_code AND c.is_active) THEN
        RAISE EXCEPTION 'RUN_LOSS_CATEGORY_UNKNOWN|%', COALESCE(p_loss_category_code, '?');
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'RUN_LOSS_QTY_INVALID|%', p_quantity;
    END IF;
    IF EXISTS (SELECT 1 FROM processing_run_losses l WHERE l.run_id = p_run_id AND l.loss_category_code = p_loss_category_code) THEN
        RAISE EXCEPTION 'RUN_LOSS_ALREADY_RECORDED|%', p_loss_category_code;
    END IF;
    INSERT INTO processing_run_losses (run_id, loss_category_code, quantity, notes)
    VALUES (p_run_id, p_loss_category_code, p_quantity, NULLIF(btrim(COALESCE(p_notes, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/correct_run_loss.sql
-- MES-4a(2026-10-07,规格 §4.2;MES-0 Q49;MES-4a Step 0 Q28,Tim):【更正一条有名字的损耗】—— 不改原行,落一条新的指回它。
--   码:module.processing.edit 或 action.processing_aftercare。理由必填(RUN_LOSS_CORRECTION_REASON_REQUIRED);只能更正链的末端
--   (RUN_LOSS_SUPERSEDED|<id>);新量不为负(RUN_LOSS_QTY_INVALID)—— 0 就是【撤回】这一类;与原值相同按名拒(RUN_LOSS_CORRECTION_SAME_VALUE)。
--   类别与加工单照抄原行。之和仍不许超过 loss_qty。之后结平的水位线被越过 → 那一炉回到"没结平"(Q19)。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.correct_run_loss(p_loss_id bigint, p_quantity numeric, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run  processing_runs%ROWTYPE;
    v_orig processing_run_losses%ROWTYPE;
    v_id   bigint;
BEGIN
    IF NOT has_any_permission(ARRAY['module.processing.edit', 'action.processing_aftercare']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.processing_aftercare';
    END IF;
    SELECT * INTO v_orig FROM processing_run_losses WHERE id = p_loss_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_LOSS_NOT_FOUND|%', p_loss_id;
    END IF;
    SELECT * INTO v_run FROM processing_runs WHERE id = v_orig.run_id FOR UPDATE;
    IF v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.code;
    END IF;
    IF EXISTS (SELECT 1 FROM processing_run_losses x WHERE x.corrects_id = v_orig.id) THEN
        RAISE EXCEPTION 'RUN_LOSS_SUPERSEDED|%', v_orig.id;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'RUN_LOSS_CORRECTION_REASON_REQUIRED';
    END IF;
    IF p_quantity IS NULL OR p_quantity < 0 THEN
        RAISE EXCEPTION 'RUN_LOSS_QTY_INVALID|%', p_quantity;
    END IF;
    IF p_quantity = v_orig.quantity THEN
        RAISE EXCEPTION 'RUN_LOSS_CORRECTION_SAME_VALUE';
    END IF;
    INSERT INTO processing_run_losses (run_id, loss_category_code, quantity, notes, corrects_id, correction_reason)
    VALUES (v_orig.run_id, v_orig.loss_category_code, p_quantity, v_orig.notes, v_orig.id, btrim(p_reason))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/create_recipe_version.sql
-- MES-4a(2026-10-07,MES-0 Q44;MES-4a Step 0 Q16,Tim):【给一个配方出新的一版】—— 一版写了就不改,改配方 = 出下一版。
--   持 module.processing.edit。配方必须存在且启用着(RECIPE_NOT_FOUND · RECIPE_INACTIVE)。p_values = {字段码: 值},不能是空的
--   (RECIPE_VALUES_REQUIRED);每一个键必须是这道工序上【启用着的参数】(RECIPE_FIELD_NOT_A_PARAMETER|<字段>)—— 指标是这一炉出来的
--   结果,不是预设;每个值按字段的类型验(数 · 计数 · 文字 · 是/否 → RECIPE_VALUE_INVALID|<字段>|<类型>)。存的是规整过的值
--   (数是 jsonb 数,是/否是 jsonb 布尔)。版本号 = 这个配方已有的最大版本 + 1(加锁,两次并发不会撞号)。返回新一版的 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.create_recipe_version(p_recipe_id uuid, p_values jsonb, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rc   process_recipes%ROWTYPE;
    v_f    operation_type_fields%ROWTYPE;
    v_key  text;
    v_val  jsonb;
    v_out  jsonb := '{}'::jsonb;
    v_num  numeric;
    v_ver  integer;
    v_id   uuid;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_rc FROM process_recipes WHERE id = p_recipe_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RECIPE_NOT_FOUND|%', p_recipe_id;
    END IF;
    IF NOT v_rc.is_active THEN
        RAISE EXCEPTION 'RECIPE_INACTIVE|%', v_rc.code;
    END IF;
    IF p_values IS NULL OR jsonb_typeof(p_values) <> 'object' OR p_values = '{}'::jsonb THEN
        RAISE EXCEPTION 'RECIPE_VALUES_REQUIRED';
    END IF;
    FOR v_key IN SELECT k FROM jsonb_object_keys(p_values) k ORDER BY k LOOP
        SELECT * INTO v_f FROM operation_type_fields f
         WHERE f.operation_type_code = v_rc.operation_type_code AND f.field_code = v_key AND f.is_active AND f.kind = 'parameter';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'RECIPE_FIELD_NOT_A_PARAMETER|%', v_key;
        END IF;
        v_val := p_values -> v_key;
        IF v_f.value_type IN ('number', 'count') THEN
            BEGIN
                v_num := CASE jsonb_typeof(v_val) WHEN 'number' THEN (v_val #>> '{}')::numeric
                                                   WHEN 'string' THEN NULLIF(btrim(v_val #>> '{}'), '')::numeric END;
            EXCEPTION WHEN others THEN
                v_num := NULL;
            END;
            IF v_num IS NULL OR (v_f.value_type = 'count' AND (v_num < 0 OR v_num <> trunc(v_num))) THEN
                RAISE EXCEPTION 'RECIPE_VALUE_INVALID|%|%', v_key, v_f.value_type;
            END IF;
            v_out := v_out || jsonb_build_object(v_key, v_num);
        ELSIF v_f.value_type = 'text' THEN
            IF NULLIF(btrim(v_val #>> '{}'), '') IS NULL THEN
                RAISE EXCEPTION 'RECIPE_VALUE_INVALID|%|%', v_key, v_f.value_type;
            END IF;
            v_out := v_out || jsonb_build_object(v_key, btrim(v_val #>> '{}'));
        ELSE
            IF jsonb_typeof(v_val) = 'boolean' THEN
                v_out := v_out || jsonb_build_object(v_key, (v_val #>> '{}')::boolean);
            ELSIF lower(v_val #>> '{}') IN ('true', 'yes') THEN
                v_out := v_out || jsonb_build_object(v_key, true);
            ELSIF lower(v_val #>> '{}') IN ('false', 'no') THEN
                v_out := v_out || jsonb_build_object(v_key, false);
            ELSE
                RAISE EXCEPTION 'RECIPE_VALUE_INVALID|%|%', v_key, v_f.value_type;
            END IF;
        END IF;
    END LOOP;
    SELECT COALESCE(max(version), 0) + 1 INTO v_ver FROM process_recipe_versions WHERE recipe_id = p_recipe_id;
    INSERT INTO process_recipe_versions (recipe_id, version, param_values, notes)
    VALUES (p_recipe_id, v_ver, v_out, NULLIF(btrim(COALESCE(p_notes, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/close_run_balance.sql
-- MES-4a(2026-10-07,规格 §4.1;MES-0 Q46 · Q47 · Q50;MES-4a Step 0 Q19–Q21,Tim):【结平一炉的物料平衡】。
--   持 action.processing_aftercare(Q50 —— 记损耗的那个码;不要第二个人,Q47)。算术读 processing_run_balance_all(一份算术)。
--   按顺序拒:
--     RUN_NOT_COMMITTED|<单>             已回滚 / 已删
--     RUN_BALANCE_NOT_APPLICABLE|<单>    状态改变型(放电):投入恒等于产出,没有平衡可结(Q20)
--     RUN_BALANCE_BEFORE_CLOSURE|<单>    MES-4a 之前记下的单(开始时刻为空):不能结(Q21)
--     RUN_BALANCE_ALREADY_CLOSED|<单>    最新一次结平还是当前的
--     RUN_REQUIRED_VALUES_MISSING|<单>|<字段,…>   必填的参数 / 指标缺着(必填在这里判,不在提交时,Q11)
--     RUN_OUTPUT_WEIGHING_MISSING|<单>|<条数>      有产出腿没挂称重(Q22)
--     RUN_BALANCE_EXPLANATION_REQUIRED|<单>|<余数>|<容差 或 not_set>
--         余数不为 0,而容差没给(Q46)或超出了给的容差(Q47)→ 要一句书面说明。余数为 0、或在给了的容差里 → 说明可选。
--   落一行 processing_run_closures:那一刻的账、容差与判断、说明、损耗与值的 id 水位线。返回它的 id。
--   之后再有损耗或值被记下或更正 → 水位线被越过 → 这次结平不再当前(重开,不改任何一行)。
--   【与成本无关,两个方向都是】分摊不读损耗,结平不动钱;分摊也不等结平(Q23)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.close_run_balance(p_run_id uuid, p_explanation text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    b      record;
    v_expl text := NULLIF(btrim(COALESCE(p_explanation, '')), '');
    v_id   bigint;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT r.code INTO v_code FROM processing_runs r WHERE r.id = p_run_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;
    SELECT * INTO b FROM processing_run_balance_all WHERE run_id = p_run_id;
    IF b.balance_state = 'reversed' THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_code;
    END IF;
    IF b.balance_state = 'not_applicable' THEN
        RAISE EXCEPTION 'RUN_BALANCE_NOT_APPLICABLE|%', v_code
          USING HINT = '状态改变型工序(放电)同一批进、同一批出 —— 投入恒等于产出,损耗恒为 0,没有平衡可结。';
    END IF;
    IF b.balance_state = 'before_closure' THEN
        RAISE EXCEPTION 'RUN_BALANCE_BEFORE_CLOSURE|%', v_code
          USING HINT = '这张单记在结平之前(没有开始时刻、产出没有称重):不能结,也不回填。';
    END IF;
    IF b.balance_state = 'closed' THEN
        RAISE EXCEPTION 'RUN_BALANCE_ALREADY_CLOSED|%', v_code;
    END IF;
    IF cardinality(b.required_missing) > 0 THEN
        RAISE EXCEPTION 'RUN_REQUIRED_VALUES_MISSING|%|%', v_code, array_to_string(b.required_missing, ',')
          USING HINT = '这道工序上必填的参数或指标还缺着 —— 先在加工单页上记下来再结。';
    END IF;
    IF b.outputs_unweighed > 0 THEN
        RAISE EXCEPTION 'RUN_OUTPUT_WEIGHING_MISSING|%|%', v_code, b.outputs_unweighed;
    END IF;
    IF b.remainder_qty <> 0 AND b.within_tolerance IS NOT TRUE AND v_expl IS NULL THEN
        RAISE EXCEPTION 'RUN_BALANCE_EXPLANATION_REQUIRED|%|%|%', v_code, b.remainder_qty, COALESCE(b.tolerance_pct::text, 'not_set')
          USING HINT = '投入不等于产出加有名字的损耗,而余数不在一个给了的容差里(或容差还没给)—— 写一句说明这一截去了哪里。';
    END IF;
    INSERT INTO processing_run_closures (run_id, input_qty, output_qty, named_loss_qty, remainder_qty, tolerance_pct, within_tolerance,
                                         explanation, loss_watermark, value_watermark)
    VALUES (p_run_id, b.input_qty, b.output_qty, b.named_loss_qty, b.remainder_qty, b.tolerance_pct, b.within_tolerance,
            v_expl, b.max_loss_id, b.max_value_id)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/correct_run_header.sql
-- MES-4a(2026-10-07,规格 §4.2;MES-0 Q49;MES-4a Step 0 Q30,Tim):【更正一张加工单表头的一个字段】—— 留一行更正,再改表头。
--   只有六个字段:started_at · ended_at · shift_code · equipment_id · recipe_version_id · notes;别的 → RUN_HEADER_FIELD_NOT_CORRECTABLE|<字段>
--   (加工日、数量、工序、工单改了就是另一炉:回滚申请 + 新单带 corrects_run_id)。
--   码:action.processing_commit —— 提交那一炉的人(warehouse · admin)。加工单必须已提交、没回滚(RUN_NOT_COMMITTED)。理由必填;
--   新值与旧值相同按名拒(RUN_HEADER_CORRECTION_SAME_VALUE)。
--   【MES-4a 之前的单】(开始时刻为空)一个字段都不改 → RUN_HEADER_PREDATES_RECORD|<单>:给它补时刻、班次、机器、配方就是回填(Q21 不回填);
--   连备注也不改 —— 那些单都没有工序,而 processing_runs_operation_type_required 那条 NOT VALID 的 CHECK 对【每一次 UPDATE】照样检查,
--   改任何一列都会撞上它(登记在 docs/known-issues.md 的 MES4A-NOT-VALID-CHECK-BLOCKS-OLD-RUN-UPDATES)。旧单原样留着。
--   新值过与提交时【同一份】判据:时刻与班次 → assert_run_header(按改后的整组再问一遍);机器 → assert_run_equipment;
--   配方版本 → 属于这道工序、配方启用着(或清空)。表头经属主路径改(updated_by / updated_at 跟着动),原值留在 processing_run_corrections
--   与变更记录里。返回更正行的 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.correct_run_header(p_run_id uuid, p_field text, p_value text, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run   processing_runs%ROWTYPE;
    v_val   text := NULLIF(btrim(COALESCE(p_value, '')), '');
    v_old   text;
    v_ts    timestamptz;
    v_uuid  uuid;
    v_rc    record;
    v_id    bigint;
BEGIN
    PERFORM require_permission('action.processing_commit');
    IF p_field IS NULL OR p_field NOT IN ('started_at', 'ended_at', 'shift_code', 'equipment_id', 'recipe_version_id', 'notes') THEN
        RAISE EXCEPTION 'RUN_HEADER_FIELD_NOT_CORRECTABLE|%', COALESCE(p_field, '?')
          USING HINT = '能更正的只有开始、结束、班次、机器、配方版本与备注。加工日、数量、工序与工单改了就是另一炉:走回滚申请,再记一张新单指回它。';
    END IF;
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, p_run_id::text);
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'RUN_HEADER_CORRECTION_REASON_REQUIRED';
    END IF;
    IF v_run.started_at IS NULL THEN
        RAISE EXCEPTION 'RUN_HEADER_PREDATES_RECORD|%', v_run.code
          USING HINT = '这张单记在 MES-4a 之前:表头不更正。给它补时刻、班次、机器或配方就是回填,而旧单不回填。';
    END IF;

    v_old := CASE p_field WHEN 'started_at' THEN v_run.started_at::text WHEN 'ended_at' THEN v_run.ended_at::text
                          WHEN 'shift_code' THEN v_run.shift_code WHEN 'equipment_id' THEN v_run.equipment_id::text
                          WHEN 'recipe_version_id' THEN v_run.recipe_version_id::text ELSE v_run.notes END;

    IF p_field IN ('started_at', 'ended_at') THEN
        IF v_val IS NULL THEN
            RAISE EXCEPTION 'RUN_TIMES_REQUIRED|%', CASE p_field WHEN 'started_at' THEN 'start' ELSE 'end' END;
        END IF;
        BEGIN
            v_ts := v_val::timestamptz;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'RUN_HEADER_VALUE_INVALID|%', p_field;
        END;
        IF v_ts IS NOT DISTINCT FROM (CASE p_field WHEN 'started_at' THEN v_run.started_at ELSE v_run.ended_at END) THEN
            RAISE EXCEPTION 'RUN_HEADER_CORRECTION_SAME_VALUE';
        END IF;
        PERFORM assert_run_header(v_run.process_date,
                                  CASE p_field WHEN 'started_at' THEN v_ts ELSE v_run.started_at END,
                                  CASE p_field WHEN 'ended_at' THEN v_ts ELSE v_run.ended_at END,
                                  v_run.shift_code);
        IF p_field = 'started_at' THEN
            UPDATE processing_runs SET started_at = v_ts, updated_by = auth.uid(), updated_at = now() WHERE id = p_run_id;
        ELSE
            UPDATE processing_runs SET ended_at = v_ts, updated_by = auth.uid(), updated_at = now() WHERE id = p_run_id;
        END IF;
        v_val := v_ts::text;
    ELSIF p_field = 'shift_code' THEN
        IF v_val IS NOT DISTINCT FROM v_run.shift_code THEN
            RAISE EXCEPTION 'RUN_HEADER_CORRECTION_SAME_VALUE';
        END IF;
        PERFORM assert_run_header(v_run.process_date, v_run.started_at, v_run.ended_at, v_val);
        UPDATE processing_runs SET shift_code = v_val, updated_by = auth.uid(), updated_at = now() WHERE id = p_run_id;
    ELSIF p_field = 'equipment_id' THEN
        BEGIN
            v_uuid := v_val::uuid;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'RUN_HEADER_VALUE_INVALID|%', p_field;
        END;
        IF v_uuid IS NOT DISTINCT FROM v_run.equipment_id THEN
            RAISE EXCEPTION 'RUN_HEADER_CORRECTION_SAME_VALUE';
        END IF;
        PERFORM assert_run_equipment(v_run.operation_type_code, v_uuid, v_run.process_date);
        UPDATE processing_runs SET equipment_id = v_uuid, updated_by = auth.uid(), updated_at = now() WHERE id = p_run_id;
    ELSIF p_field = 'recipe_version_id' THEN
        BEGIN
            v_uuid := v_val::uuid;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'RUN_HEADER_VALUE_INVALID|%', p_field;
        END;
        IF v_uuid IS NOT DISTINCT FROM v_run.recipe_version_id THEN
            RAISE EXCEPTION 'RUN_HEADER_CORRECTION_SAME_VALUE';
        END IF;
        IF v_uuid IS NOT NULL THEN
            SELECT rc.code, rc.operation_type_code, rc.is_active INTO v_rc
              FROM process_recipe_versions rv JOIN process_recipes rc ON rc.id = rv.recipe_id WHERE rv.id = v_uuid;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'RECIPE_VERSION_NOT_FOUND|%', v_uuid;
            END IF;
            IF v_rc.operation_type_code <> v_run.operation_type_code THEN
                RAISE EXCEPTION 'RECIPE_VERSION_NOT_FOR_OPERATION|%|%', v_rc.code, v_run.operation_type_code;
            END IF;
            IF NOT v_rc.is_active THEN
                RAISE EXCEPTION 'RECIPE_INACTIVE|%', v_rc.code;
            END IF;
        END IF;
        UPDATE processing_runs SET recipe_version_id = v_uuid, updated_by = auth.uid(), updated_at = now() WHERE id = p_run_id;
    ELSE
        IF v_val IS NOT DISTINCT FROM NULLIF(btrim(COALESCE(v_run.notes, '')), '') THEN
            RAISE EXCEPTION 'RUN_HEADER_CORRECTION_SAME_VALUE';
        END IF;
        UPDATE processing_runs SET notes = v_val, updated_by = auth.uid(), updated_at = now() WHERE id = p_run_id;
    END IF;

    INSERT INTO processing_run_corrections (run_id, field, old_value, new_value, reason)
    VALUES (p_run_id, p_field, v_old, v_val, btrim(p_reason))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/processing_runs_unclosed_balance.sql
-- MES-4a(2026-10-07,MES-0 Q48;MES-4a Step 0 Q22,Tim):【一个月末之前,物料平衡还没结的加工单】—— 月结清单的那一行警告。
--   数的是 processing_run_balance_all 里 balance_state = 'open' 的单(MES-4a 起记的、转化型的、已提交没回滚的、最新结平不当前的),
--   日期不晚于那个月末。【只是警告,不挡关账】—— close_period 一个字没动(它只挡没分摊成本的单,processing_runs_blocking_close):
--   把生产的结平绑到财务的关账上,是 Q48 不要的。MES-4a 之前的单(before_closure)不在这里 —— 它们结不了,列出来只会永远挂着。
--   【SECURITY DEFINER + 调用者检查】与 processing_runs_blocking_close 同一扇门(module.finance.view)、同一个理由:月结的读者
--   不一定持加工的码,经基表读会静默地少掉那几张单。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.processing_runs_unclosed_balance(p_period_end date)
 RETURNS TABLE(run_count integer, run_codes text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'PERIOD_END_REQUIRED';
    END IF;
    RETURN QUERY
    SELECT count(*)::integer, string_agg(b.run_code, ', ' ORDER BY b.process_date, b.run_code)
      FROM processing_run_balance_all b
     WHERE b.balance_state = 'open'
       AND b.process_date <= p_period_end;
END;
$function$;

-- ── 9 · 改过的函数(镜像原样,同签名)──────────────────────────────────────────

-- db/functions/correct_weighing.sql
-- MES-2(2026-10-06,规格 §4.2;MES-0 §3.7;MES-2 Step 0 Q11,Tim):【更正一次已确认的称重】—— 不改原行,落一条新的。
--   持 action.confirm_capture;理由必填(WEIGHING_CORRECTION_REASON_REQUIRED);一行只更正一次(WEIGHING_SUPERSEDED|<id>:
--   要再改,改最新的那一行);值没变按名拒(WEIGHING_CORRECTION_SAME_VALUE)。
--   新的那一次走手工录入的同一条路(收件箱 manual → 同一支转换器 → 草稿 → 一步确认),仪器、现场时间、主语(地磅单与角色)
--   都照抄原行 —— 它更正的是【那一次读数】,不是一次新的过磅。新行 corrects_id 指回原行;地磅单从此读最新的,
--   两磅凑齐时净重照样要 > 0(TICKET_NET_NOT_POSITIVE)。已经分出去的份与收货单的数量一个字都不动(收货单数量不可改),
--   差多少在单上照直显示。返回新那一行的 id。
--
--   ★ MES-4a(2026-10-07,Q26):挂在一条加工产出腿上的称重不再更正 → WEIGHING_IN_USE|<加工单>。
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
    -- MES-4a(MES-0 Q49;MES-4a Step 0 Q26):一次已经给一条加工产出腿用了的称重不再更正 —— 那条腿的数量就是它;
    -- 数量的更正是回滚申请(CFO)+ 一张新单(corrects_run_id)。
    IF EXISTS (SELECT 1 FROM processing_outputs po WHERE po.weighing_id = v_orig.id) THEN
        RAISE EXCEPTION 'WEIGHING_IN_USE|%', (SELECT r.code FROM processing_outputs po JOIN processing_runs r ON r.id = po.run_id
                                               WHERE po.weighing_id = v_orig.id);
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
--   operation_type → /operation/operation-types/[code] requireModule(MOD.processing) = module.processing.view(MES-4a)
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
        -- MES-3b(2026-10-07):危险品 UN 编号字典(module.materials.view)· 标签模板字典(module.inventory.view)
        ('dictionary_dangerous_goods_codes', ARRAY['module.materials.view'], 'dangerous_goods_codes', 'code', 'collection', NULL),
        ('dictionary_label_templates',      ARRAY['module.inventory.view'], 'label_templates',       'code', 'collection', NULL),
        -- MES-4a(2026-10-07,MES-4a Step 0 Q33):一道工序 —— 它的参数与指标、挂着的机器、配方与每一版、容差(根行自己那几列);
        --   页面 /operation/operation-types/[code],门 module.processing.view;根键 code(成员按 operation_type_code 挂在它下面)。
        --   异常事件种类字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries)。
        ('operation_type',    ARRAY['module.processing.view'],    'operation_types',    'code', 'table', NULL),
        ('dictionary_processing_event_types', ARRAY['module.processing.view'], 'processing_event_types', 'code', 'collection', NULL),
        --   班次字典 —— MES-4a 把它放进 /settings/dictionaries(新的"时刻"字段:V6 · V7 的去处),于是它也有一段清单块的记录。
        ('dictionary_shifts', ARRAY['module.processing.view'], 'shifts', 'code', 'collection', NULL),
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
        ('output_batch',      37, 'receipt_ceiling_checks', 'output_batches',     'output_batch_id',  '{}'::jsonb, 'down', true, false),
        -- ── MES-3b(2026-10-07,MES-3b Step 0 Q7 · Q27):每一次印标签(印 · 补印与理由)—— 挂在它印的那样东西下面。
        --    一张表挂三个主语,只有一处是家(trail_row_record 沿 home 往上走):进料批那一支,与 receipt_ceiling_checks 同一个选法 ──
        ('inbound_batch',     41, 'label_prints',           'inbound_batches',    'inbound_batch_id',    '{}'::jsonb, 'down', true, true),
        ('output_batch',      38, 'label_prints',           'output_batches',     'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('storage_location',   2, 'label_prints',           'storage_locations',  'storage_location_id', '{}'::jsonb, 'down', true, false),
        -- ── MES-4a(2026-10-07,MES-4a Step 0 Q33):加工单 —— 记下的值、异常事件、结平、表头更正(都只追加,都按 run_id 挂)。
        --    一道工序 —— 它的字段、挂着的机器、配方(按 operation_type_code 挂在根行的 code 下)与配方的每一版(挂在配方下)。──
        ('processing_run',     9, 'processing_run_values',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    10, 'processing_run_events',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    11, 'processing_run_closures',    'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    12, 'processing_run_corrections', 'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('operation_type',     1, 'operation_type_fields',      'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     2, 'operation_type_equipment',   'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     3, 'process_recipes',            'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     4, 'process_recipe_versions',    'process_recipes',  'recipe_id',           '{}'::jsonb, 'down', true, true)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- db/functions/record_trail.sql
-- AUDIT-TRAIL-1a(Tim 的 Q1–Q6 · Q12 · Q13 · Q17 · Q40):一页底部"Audit trail"的【唯一】读法。
--
-- 【页面只说"哪一种记录、哪一条"】p_subject 是 trail_subjects() 里的一个主语,不是表名;p_id 是那条记录的 id。
--   不认识的主语 → TRAIL_SUBJECT_UNKNOWN。页面自己的查看权限码不在身上、或那条根记录过不了它自己那张表的读规则
--   (包括根本不存在)→ TRAIL_NOT_PERMITTED。★ 拒绝一律 RAISE,【绝不返回空列表】—— 空列表读起来是"什么都没发生过"。
--
-- 【哪些行】根行 + trail_subject_members() 登记的子行、孙行、相关行(Q3)。子行是【读的时候】找的(Q6):
--   今天还在的行按外键查;删掉了的、或父键被改过的,从 change_log 的影像里查(两条 GIN 部分索引)。
--   ☞ 为什么不能只按影像里的外键找:一次编辑只记改了的那几列,改一条明细行的单价,那一行记录里没有 purchase_order_id。
--     所以先收齐【这条记录有哪些行的主键】,再按 (表, 主键) 取那些行的全部记录。
--
-- 【每一行再过一次它自己那张表的读规则】(Q4)trail_row_visible。过不了的行照样占一个位置(时间还在),
--   其余一律为空、row_hidden = true —— 界面在"做了什么"与"谁"的位置印 Restricted。
-- 【遮蔽】过得了的行走 change_log_mask_row —— 与 /settings/change-history 同一步、同一份 HISTORY-1 规则,不加规则。
--
-- 【一次操作 = 一笔事务 = 一条记录】(Q2)按 txid 分组,entry_no 从新到旧编号。
-- 【变更记录开始之前】(Q1)trail_prelog_sources() 登记的领域历史与生命周期戳,凡是早于 change_log_began_at() 的,
--   拼成 prelog = true 的行(没有 seq);同一时刻写下的归成一条(同一笔事务的 now() 相同)。它们永远排在所有
--   变更记录之后,界面在两者之间画分界线。change_log 已经记着的(那一行的 INSERT、那一戳的改动)一律不再拼 —— 不会出现两次。
--
-- 【每一行带回】actor(trail_actor)、ctx(这一行今天的样子,已遮蔽 —— 子行的"第几行、哪个物料"从这里取)、
--   refs(trail_refs:每一个指着别处的值 → 名字)。界面把这些造成英文句子(Q40)。
-- 【分页】p_entries 条记录(默认 20,1..500),more 说后面还有没有更旧的。
-- 【SECURITY DEFINER 的理由】change_log 对应用角色没有任何授权(HISTORY-1);读权限在函数体里由上面三道判定。
--
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M1–M6):
--   M1 一页可以认【任一】个码(trail_subjects.view_codes;has_any_permission)。
--   M2 "记录开始之前"的人可以记成员工 id(trail_prelog_sources.by_kind = 'employee')—— 交给 trail_actor 的员工那一格。
--   M3 root_rule = 'page':页面的码就是门,根行不再过它自己那张表的读规则;根行自己的改动照子行的规矩逐行判(Q4)。
--   M4 hop = 'up':从一行往上走到它指着的那一行(批次 → 消耗它的加工单);shown = false 的是【垫脚石】——
--      只用来够到它下面的行,它自己不进审计记录,也不判读规则、不拼"之前"那一段(Q4:只限碰到这条记录的事)。
--   M5 根键按根行【自己的类型】重建(jsonb_build_object(root_key, image -> root_key)):单行设置表的主键是
--      boolean,change_log 里存的是 {"id": true};按文字 'true' 去对,永远对不上 —— 审计记录会【空着而不报错】。
--   M6 root_columns 非空:根行只取这几列(改动取交集,一列都不沾的那次改动整条不算;新增 / 删除的影像只留这几列)。
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 的 Q3 · Q16):
--   M7 hop = 'all'(fk_column 为空):一张【没有外键】的表整张属于一个单行设置主语 —— 那张表今天的每一行,加上 change_log
--      里它的每一行(按 match 过滤)。只在父表就是这个主语的根表时生效(一个单行设置表:M5 的那一种);挂在别处的一行
--      'all' 不展开任何东西。第一个用户是 1c-3 的锁期面板(月结 / 反结的 period_closes 与 finance_settings 之间
--      一个键都没有);本刀先建好,fixture 241 用一个临时主语证它。
--   Q16 op_key:每一行带回它属于哪一次操作 —— 记录开始之后是那笔事务('L' || txid),之前是那一刻('P' || 时刻)。
--      entry_no 只在【一条】记录里排得出先后;一个清单页把几条记录合起来时(ListTrail),同一次操作碰到几条记录就会
--      各出一条 —— 一次批量录汇率是 N 条、一次冻结预测(新一张 + 旧一张作废)是两条。op_key 让它们并成一条。
--      ☞ 返回列多了一列,CREATE OR REPLACE 换不了返回类型 —— 迁移里是 DROP + CREATE(同一笔事务;授权由
--        apply_migration.sh 回放 zzz_function_grants 给回去)。
-- AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 的 Q20):
--   M8 view_codes 为【空数组】:这一个主语没有页面码 —— 根行自己那张表的读规则就是唯一的门(/me 上报销人读自己那几张报销单:
--      expense_claims 的读规则是 module.finance.view 或者【这张单说的就是你】)。只许与 root_rule = 'table' 同用:
--      空的码配 'page' 等于对每一个登录的人敞开,所以那样登记的主语一律 TRAIL_NOT_PERMITTED。NULL 不是"没有码",照旧被拒。
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q2–Q5 —— M9 · M10 · M11 · M12):
--   M9  根表可以是一张【只在变更记录里出现】的表(trail_log_only_tables():auth.users)—— trail_current_image 读它那一份
--       安全投影,trail_row_visible 用登记表里声明的码判;它的"建立"在记录开始之后是一行 ACCOUNT_CREATE,不是 INSERT,
--       所以"记录开始之前"那一段的建立在两者任一存在时都不再拼(否则账号建立会说两次)。
--   M10 成员可以【只取声明的几列】(trail_member_columns(),M6 用在成员上):一次改动一列都不沾 → 不算;沾了 → 只留这几列;
--       之前那一段只拼落在这几列上的戳,不拼那一行的建立。根行的 root_columns 是同一条路(下标 1)。
--   M11 root_rule = 'collection':一个【集合】主语 —— 没有根行;那张表今天的每一行,加上 change_log 里它的每一行,都属于
--       这条记录,每一行各过它自己的读规则(Q4)。p_id 不用。假期表、六本字典、假别、评分刻度(AT-1d Step 0 的 Q4)。
--   M12 root_rule = 'gate:<名字>':根行先过它那张表的读规则('table' 那一道),【再】过 trail_root_gate 点名的那一道 ——
--       比表的规则更窄(/my-reviews 只给审核人,不给被评审的人)。与 M8(没有页面码)同用是允许的:门比 'table' 更窄,
--       不会更宽。
CREATE OR REPLACE FUNCTION public.record_trail(p_subject text, p_id text, p_entries integer DEFAULT 20)
 RETURNS TABLE(entry_no integer, prelog boolean, seq bigint, occurred_at timestamp with time zone, table_name text, row_key jsonb, op text, actor jsonb, changed_columns text[], old jsonb, new jsonb, ctx jsonb, refs jsonb, row_hidden boolean, row_restricted boolean, more boolean, op_key text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    s        record;
    m        record;
    p        record;
    r        record;
    v_limit  integer := LEAST(GREATEST(COALESCE(p_entries, 20), 1), 500);
    v_root   jsonb;
    v_img    record;
    v_tabs   text[] := ARRAY[]::text[];
    v_keys   jsonb[] := ARRAY[]::jsonb[];
    v_vis    boolean[] := ARRAY[]::boolean[];
    v_ctx    jsonb[] := ARRAY[]::jsonb[];
    v_crefs  jsonb[] := ARRAY[]::jsonb[];
    v_rr     jsonb;
    v_pids   text[];
    v_pk     text[];
    v_found  jsonb[];
    v_found2 jsonb[];
    v_k      jsonb;
    i        integer;
    v_pseudo jsonb := '[]'::jsonb;
    v_at     timestamptz;
    v_cols   text[];
    v_new    jsonb;
    v_op     text;
    v_mask   jsonb;
    v_began  timestamptz := change_log_began_at();
    v_total  integer;
    v_shown  boolean[] := ARRAY[]::boolean[];
    v_rcols  text[];
    v_fkv    text[];
    v_cimg   record;
    v_icols  jsonb[] := ARRAY[]::jsonb[];
    v_mcols  jsonb;
    v_c      text[];
    v_coll   boolean;
    v_gate   text;
BEGIN
    SELECT ts.* INTO s FROM trail_subjects() ts WHERE ts.subject = p_subject;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRAIL_SUBJECT_UNKNOWN|%', COALESCE(p_subject, '');
    END IF;
    v_coll := s.root_rule = 'collection';
    v_gate := CASE WHEN s.root_rule LIKE 'gate:%' THEN substr(s.root_rule, 6) END;
    IF cardinality(s.view_codes) = 0 THEN
        -- M8:没有页面码 —— 根行的读规则是门,而那只在 'table'(或比它更窄的 M12 门)时才问
        IF s.root_rule IS DISTINCT FROM 'table' AND v_gate IS NULL THEN
            RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;
        END IF;
    ELSIF NOT has_any_permission(s.view_codes) THEN
        RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;
    END IF;
    v_rcols := s.root_columns;
    IF v_coll THEN
        -- M11:集合 —— 那张表今天的每一行 + change_log 里它的每一行;没有根行,每一行各过它自己的读规则
        v_pk := trail_pk_columns(s.root_table);
        EXECUTE format('SELECT array_agg(jsonb_build_object(%s)) FROM public.%I t',
                       (SELECT string_agg(format('%L, t.%I', c, c), ', ') FROM unnest(v_pk) c), s.root_table)
           INTO v_found;
        SELECT array_agg(DISTINCT c.row_key) INTO v_found2
          FROM change_log c WHERE c.table_name = s.root_table AND c.row_key IS NOT NULL;
        FOR v_k IN SELECT DISTINCT x FROM unnest(COALESCE(v_found, ARRAY[]::jsonb[]) || COALESCE(v_found2, ARRAY[]::jsonb[])) x
                    WHERE x IS NOT NULL LOOP
            v_tabs := array_append(v_tabs, s.root_table);
            v_keys := array_append(v_keys, v_k);
            v_shown := array_append(v_shown, true);
            v_icols := array_append(v_icols, NULL::jsonb);
        END LOOP;
    ELSE
        v_root := jsonb_build_object(s.root_key, p_id);
        SELECT * INTO v_img FROM trail_current_image(s.root_table, v_root);
        IF v_img.image IS NULL
           OR ((s.root_rule = 'table' OR v_gate IS NOT NULL) AND NOT trail_row_visible(s.root_table, v_root, v_img.image))
           OR (v_gate IS NOT NULL AND NOT trail_root_gate(v_gate, s.root_table, v_img.image)) THEN
            RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;
        END IF;
        -- M5:根键按它自己的类型重建(boolean / 数字主键),否则与 change_log 的 row_key 永远对不上
        IF v_img.image ? s.root_key THEN
            v_root := jsonb_build_object(s.root_key, v_img.image -> s.root_key);
        END IF;
        v_tabs := ARRAY[s.root_table];
        v_keys := ARRAY[v_root];
        v_shown := ARRAY[true];
        v_icols := ARRAY[to_jsonb(v_rcols)];
    END IF;

    -- ① 这条记录有哪些行(按 ord 展开,孙行在父行之后;hop = 'up' 往上走一跳,shown = false 的只作垫脚石)
    FOR m IN SELECT tm.* FROM trail_subject_members() tm WHERE tm.subject = p_subject ORDER BY tm.ord LOOP
        v_found := NULL;
        v_found2 := NULL;
        IF m.hop = 'all' THEN
            -- M7:整张表属于这个单行设置主语(父表必须就是根表)
            CONTINUE WHEN m.parent_table IS DISTINCT FROM s.root_table;
            v_pk := trail_pk_columns(m.table_name);
            EXECUTE format('SELECT array_agg(jsonb_build_object(%s)) FROM public.%I t WHERE to_jsonb(t) @> $1',
                           (SELECT string_agg(format('%L, t.%I', c, c), ', ') FROM unnest(v_pk) c), m.table_name)
               INTO v_found USING m.match;
            SELECT array_agg(DISTINCT c.row_key) INTO v_found2
              FROM change_log c
             WHERE c.table_name = m.table_name AND c.row_key IS NOT NULL AND COALESCE(c.new, c.old) @> m.match;
        ELSIF m.hop = 'up' THEN
            -- 父行今天那份(或它最后一份影像)里的那一列 → 被指着的那一行的 id
            v_fkv := ARRAY[]::text[];
            FOR v_k IN SELECT u.k FROM unnest(v_tabs, v_keys) AS u(t, k) WHERE u.t = m.parent_table LOOP
                SELECT * INTO v_cimg FROM trail_current_image(m.parent_table, v_k);
                IF v_cimg.image ->> m.fk_column IS NOT NULL THEN
                    v_fkv := array_append(v_fkv, v_cimg.image ->> m.fk_column);
                END IF;
            END LOOP;
            CONTINUE WHEN cardinality(v_fkv) = 0;
            SELECT array_agg(DISTINCT jsonb_build_object('id', x.v)) INTO v_found
              FROM unnest(v_fkv) AS x(v)
             WHERE (trail_current_image(m.table_name, jsonb_build_object('id', x.v))).image @> m.match;
        ELSE
            -- MES-4a:父行的键不叫 id 而只有一列(operation_types 的 code)时,用那一列的值 —— 成员按它挂(operation_type_code)。
            --   今天所有带成员的主语,父行键都是 id,所以它们的行为一个字不变;多列键的父行仍然不往下走。
            SELECT array_agg(DISTINCT COALESCE(u.k ->> 'id', (SELECT e.value FROM jsonb_each_text(u.k) e))) INTO v_pids
              FROM unnest(v_tabs, v_keys) AS u(t, k)
             WHERE u.t = m.parent_table AND (u.k ? 'id' OR (SELECT count(*) FROM jsonb_object_keys(u.k)) = 1);
            CONTINUE WHEN v_pids IS NULL;
            v_pk := trail_pk_columns(m.table_name);
            EXECUTE format('SELECT array_agg(jsonb_build_object(%s)) FROM public.%I t WHERE t.%I::text = ANY ($1) AND to_jsonb(t) @> $2',
                           (SELECT string_agg(format('%L, t.%I', c, c), ', ') FROM unnest(v_pk) c),
                           m.table_name, m.fk_column)
               INTO v_found USING v_pids, m.match;
            SELECT array_agg(DISTINCT c.row_key) INTO v_found2
              FROM unnest(v_pids) AS pid(v)
              JOIN change_log c ON c.table_name = m.table_name
                               AND (COALESCE(c.new, c.old) @> (jsonb_build_object(m.fk_column, pid.v) || m.match)
                                    OR (c.op = 'UPDATE' AND c.old @> jsonb_build_object(m.fk_column, pid.v)));
        END IF;
        -- M10:这一个成员只取声明的几列(NULL = 整行)
        SELECT to_jsonb(mc.columns) INTO v_mcols FROM trail_member_columns() mc WHERE mc.subject = p_subject AND mc.ord = m.ord;
        FOR v_k IN SELECT DISTINCT x FROM unnest(COALESCE(v_found, ARRAY[]::jsonb[]) || COALESCE(v_found2, ARRAY[]::jsonb[])) x
                    WHERE x IS NOT NULL LOOP
            IF NOT EXISTS (SELECT 1 FROM unnest(v_tabs, v_keys) u(t, k) WHERE u.t = m.table_name AND u.k = v_k) THEN
                v_tabs := array_append(v_tabs, m.table_name);
                v_keys := array_append(v_keys, v_k);
                v_shown := array_append(v_shown, m.shown);
                v_icols := array_append(v_icols, v_mcols);
            END IF;
        END LOOP;
    END LOOP;

    -- ② 每一行:过不过它自己那张表的读规则;今天的样子(遮蔽之后);"记录开始之前"的那一段从哪里拼
    FOR i IN 1 .. cardinality(v_tabs) LOOP
        IF NOT v_shown[i] THEN
            -- 垫脚石:不判、不取上下文、不拼"之前"(它自己不进这条记录)
            v_vis := array_append(v_vis, false);
            v_ctx := array_append(v_ctx, NULL::jsonb);
            v_crefs := array_append(v_crefs, '{}'::jsonb);
            CONTINUE;
        END IF;
        SELECT * INTO v_img FROM trail_current_image(v_tabs[i], v_keys[i]);
        v_vis := array_append(v_vis, (i = 1 AND NOT v_coll AND (s.root_rule = 'table' OR v_gate IS NOT NULL))
                                     OR COALESCE(trail_row_visible(v_tabs[i], v_keys[i], v_img.image), false));
        IF v_vis[i] AND v_img.image IS NOT NULL THEN
            v_mask := change_log_mask_row(v_tabs[i], v_keys[i], NULL, v_img.image);
            v_ctx := array_append(v_ctx, COALESCE(NULLIF(v_mask -> 'new', 'null'::jsonb), '{}'::jsonb)
                                         || jsonb_build_object('$gone', v_img.gone));
            v_crefs := array_append(v_crefs, trail_refs(v_tabs[i], NULL, NULL, v_ctx[i]));
        ELSE
            v_ctx := array_append(v_ctx, NULL::jsonb);
            v_crefs := array_append(v_crefs, '{}'::jsonb);
        END IF;
        CONTINUE WHEN v_img.image IS NULL OR v_img.gone;
        FOR p IN SELECT ps.* FROM trail_prelog_sources() ps WHERE ps.table_name = v_tabs[i] LOOP
            v_at := NULLIF(v_img.image ->> p.at_column, '')::timestamptz;
            CONTINUE WHEN v_at IS NULL OR v_at >= v_began;
            -- M6 · M10:根行 / 成员只管声明的那几列 —— 别的列上的戳不属于这一块;限了列的成员不拼它那一行的建立
            v_c := CASE WHEN v_icols[i] IS NULL OR jsonb_typeof(v_icols[i]) <> 'array' THEN NULL
                        ELSE ARRAY(SELECT jsonb_array_elements_text(v_icols[i])) END;
            CONTINUE WHEN v_c IS NOT NULL AND ((p.kind = 'stamp' AND NOT (p.at_column = ANY (v_c))) OR (p.kind = 'created' AND i > 1));
            IF p.kind = 'created' THEN
                -- M9:登记的只在变更记录里出现的表,建立那一下记成 ACCOUNT_CREATE(record_account_event),不是 INSERT
                CONTINUE WHEN EXISTS (SELECT 1 FROM change_log c
                                       WHERE c.table_name = v_tabs[i] AND c.row_key = v_keys[i] AND c.op IN ('INSERT', 'ACCOUNT_CREATE'));
                v_op := 'INSERT';
                v_cols := NULL;
                v_new := v_img.image;
            ELSE
                CONTINUE WHEN EXISTS (SELECT 1 FROM change_log c
                                       WHERE c.table_name = v_tabs[i] AND c.row_key = v_keys[i]
                                         AND (p.at_column = ANY (c.changed_columns)
                                              OR (c.op = 'INSERT' AND c.new ->> p.at_column IS NOT NULL)));
                v_op := 'UPDATE';
                v_cols := ARRAY[p.at_column] || COALESCE(ARRAY[p.by_column], ARRAY[]::text[]) || COALESCE(p.extra, ARRAY[]::text[]);
                v_cols := ARRAY(SELECT c FROM unnest(v_cols) c WHERE c IS NOT NULL);
                SELECT jsonb_object_agg(c, v_img.image -> c) INTO v_new FROM unnest(v_cols) c WHERE v_img.image ? c;
            END IF;
            v_pseudo := v_pseudo || jsonb_build_array(jsonb_build_object(
                'i', i, 'at', v_at, 'op', v_op, 'cols', to_jsonb(v_cols), 'new', v_new,
                'account', CASE WHEN p.by_column IS NULL OR p.by_kind = 'employee' THEN NULL ELSE v_img.image -> p.by_column END,
                'employee', CASE WHEN p.by_column IS NOT NULL AND p.by_kind = 'employee' THEN v_img.image -> p.by_column END));
        END LOOP;
    END LOOP;

    -- ③ 变更记录 + 拼回来的那一段,按记录(事务)编号,从新到旧
    SELECT count(DISTINCT g) INTO v_total FROM (
        SELECT 'L' || c.txid AS g
          FROM unnest(v_tabs, v_keys, v_shown, v_icols) WITH ORDINALITY u(t, k, sh, ic, i)
          JOIN change_log c ON c.table_name = u.t AND c.row_key = u.k
         WHERE u.sh AND (u.ic IS NULL OR jsonb_typeof(u.ic) <> 'array' OR c.op <> 'UPDATE'
                         OR c.changed_columns && ARRAY(SELECT jsonb_array_elements_text(u.ic)))
        UNION ALL
        SELECT 'P' || (x ->> 'at') FROM jsonb_array_elements(v_pseudo) x) z;

    FOR r IN
        WITH k AS (
            SELECT u.t, u.k, u.ic, u.i::integer AS i FROM unnest(v_tabs, v_keys, v_shown, v_icols) WITH ORDINALITY u(t, k, sh, ic, i) WHERE u.sh),
        allr AS (
            SELECT c.seq AS a_seq, c.occurred_at AS a_at, 'L' || c.txid AS a_g, k.i AS a_i, c.op AS a_op,
                   c.actor_kind AS a_kind, c.actor_account AS a_account, c.actor_employee AS a_employee,
                   c.changed_columns AS a_cols, c.old AS a_old, c.new AS a_new, false AS a_pre
              FROM k JOIN change_log c ON c.table_name = k.t AND c.row_key = k.k
             WHERE k.ic IS NULL OR jsonb_typeof(k.ic) <> 'array' OR c.op <> 'UPDATE'
                OR c.changed_columns && ARRAY(SELECT jsonb_array_elements_text(k.ic))
            UNION ALL
            SELECT NULL::bigint, (x ->> 'at')::timestamptz, 'P' || (x ->> 'at'), (x ->> 'i')::integer, x ->> 'op',
                   'prelog', (x ->> 'account')::uuid, (x ->> 'employee')::uuid,
                   CASE WHEN jsonb_typeof(x -> 'cols') = 'array'
                        THEN ARRAY(SELECT jsonb_array_elements_text(x -> 'cols')) END,
                   NULL::jsonb, x -> 'new', true
              FROM jsonb_array_elements(v_pseudo) x),
        ent AS (
            SELECT a_g AS e_g, bool_or(a_pre) AS e_pre, max(a_seq) AS e_mx, max(a_at) AS e_at FROM allr GROUP BY a_g),
        num AS (
            SELECT e_g, row_number() OVER (ORDER BY e_pre, e_mx DESC NULLS LAST, e_at DESC, e_g)::integer AS e_n FROM ent)
        SELECT allr.*, num.e_n FROM allr JOIN num ON num.e_g = allr.a_g
         WHERE num.e_n <= v_limit
         ORDER BY num.e_n, allr.a_seq NULLS LAST, allr.a_i
    LOOP
        entry_no := r.e_n;
        prelog := r.a_pre;
        seq := r.a_seq;
        occurred_at := r.a_at;
        more := v_total > v_limit;
        op_key := r.a_g;
        IF NOT v_vis[r.a_i] THEN
            table_name := NULL; row_key := NULL; op := NULL; actor := NULL; changed_columns := NULL;
            old := NULL; new := NULL; ctx := NULL; refs := NULL;
            row_hidden := true;
            row_restricted := true;
        ELSE
            table_name := v_tabs[r.a_i];
            row_key := v_keys[r.a_i];
            op := r.a_op;
            actor := trail_actor(r.a_kind, r.a_account, r.a_employee);
            changed_columns := r.a_cols;
            v_mask := change_log_mask_row(v_tabs[r.a_i], v_keys[r.a_i], r.a_old, r.a_new);
            old := NULLIF(v_mask -> 'old', 'null'::jsonb);
            new := NULLIF(v_mask -> 'new', 'null'::jsonb);
            -- M6 · M10:根行 / 限了列的成员只留声明的那几列
            IF v_icols[r.a_i] IS NOT NULL AND jsonb_typeof(v_icols[r.a_i]) = 'array' THEN
                v_c := ARRAY(SELECT jsonb_array_elements_text(v_icols[r.a_i]));
                changed_columns := CASE WHEN r.a_cols IS NULL THEN NULL
                                        ELSE ARRAY(SELECT c FROM unnest(r.a_cols) c WHERE c = ANY (v_c)) END;
                SELECT jsonb_object_agg(e.key, e.value) INTO old FROM jsonb_each(old) e WHERE e.key = ANY (v_c);
                SELECT jsonb_object_agg(e.key, e.value) INTO new FROM jsonb_each(new) e WHERE e.key = ANY (v_c);
            END IF;
            row_restricted := (v_mask ->> 'row_restricted')::boolean;
            ctx := v_ctx[r.a_i];
            -- 这一行今天那份的名字(每个主键只解析一次)+ 这一次记录里新旧值的名字,按列合并
            v_rr := trail_refs(v_tabs[r.a_i], old, new, NULL);
            SELECT COALESCE(jsonb_object_agg(kk, COALESCE(v_crefs[r.a_i] -> kk, '{}'::jsonb) || COALESCE(v_rr -> kk, '{}'::jsonb)),
                            '{}'::jsonb)
              INTO refs
              FROM (SELECT jsonb_object_keys(v_crefs[r.a_i]) AS kk UNION SELECT jsonb_object_keys(v_rr)) z;
            row_hidden := false;
        END IF;
        RETURN NEXT;
    END LOOP;
END;
$function$;

-- db/functions/trail_refs.sql
-- AUDIT-TRAIL-1a(Tim 的 Q40):一行记录里【每一个指着别处的值】→ 它的名字。形状:
--   {"<列>": {"<原值>": {"label": …, "gone": …} | {"person": {…}}}}
--   扫的是这一行的旧影像、新影像与上下文影像(ctx,这一行今天的样子)里出现的值;受限标记与 null 不解析。
--   哪些列是引用由 trail_fk_targets 回答(目录里的外键 + 没有外键的账号列)。
-- 两个读法(record_trail · change_log_rows)共用。【属主身份】EXECUTE 已从 authenticated 收回。
-- AUDIT-TRAIL-1c-1(Q13):付款申请的 allocations 是一段 JSONB(要结清哪几张单据),不是外键 —— 里面的每一个单据 id
--   照样解析成单号,放在 refs 的 'allocations' 一格下;界面据此把它说成"PO-… · 1,000.00",不说 "Details changed"。
--   键 → 表:expense_id → expenses · inbound_batch_id → inbound_batches · purchase_order_id → purchase_orders ·
--   freight_document_id → freight_documents(与 record_payment 收的那一组同一个形状)。
-- AUDIT-TRAIL-1c-2(Q10):资产卡的修改史(fixed_asset_history)把每一列存成一对 old_<列> / new_<列>,而这一对没有外键 ——
--   于是"处置分录"、"来自哪张费用"在修改史里读不出名字。这里按 fixed_assets 自己那一列的外键去解析那一对,
--   放在 old_<列> / new_<列> 那两格下(界面按资产卡的列说它们,同一个名字)。
-- MES-4a(2026-10-07):processing_run_values.field_code 指着 (operation_type_code, field_code) 两列的外键 —— 单独解析(见末尾)。
CREATE OR REPLACE FUNCTION public.trail_refs(p_table text, p_old jsonb, p_new jsonb, p_ctx jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    f     record;
    v     text;
    v_out jsonb := '{}'::jsonb;
    v_col jsonb;
BEGIN
    FOR f IN SELECT * FROM trail_fk_targets(p_table) LOOP
        v_col := '{}'::jsonb;
        FOR v IN SELECT DISTINCT x.val
                   FROM (SELECT p_old -> f.column_name AS j UNION ALL SELECT p_new -> f.column_name
                         UNION ALL SELECT p_ctx -> f.column_name) s
                   CROSS JOIN LATERAL (SELECT s.j #>> '{}' AS val) x
                  WHERE s.j IS NOT NULL AND jsonb_typeof(s.j) IN ('string', 'number') LOOP
            v_col := v_col || jsonb_build_object(v, trail_ref_label(f.target_table, f.target_column, v));
        END LOOP;
        IF v_col <> '{}'::jsonb THEN
            v_out := v_out || jsonb_build_object(f.column_name, v_col);
        END IF;
    END LOOP;
    IF p_table = 'fixed_asset_history' THEN
        FOR f IN SELECT ft.*, pre.p FROM trail_fk_targets('fixed_assets') ft CROSS JOIN (VALUES ('old_'), ('new_')) pre(p) LOOP
            v_col := '{}'::jsonb;
            FOR v IN SELECT DISTINCT x.val
                       FROM (SELECT p_old -> (f.p || f.column_name) AS j UNION ALL SELECT p_new -> (f.p || f.column_name)
                             UNION ALL SELECT p_ctx -> (f.p || f.column_name)) s
                       CROSS JOIN LATERAL (SELECT s.j #>> '{}' AS val) x
                      WHERE s.j IS NOT NULL AND jsonb_typeof(s.j) IN ('string', 'number') LOOP
                v_col := v_col || jsonb_build_object(v, trail_ref_label(f.target_table, f.target_column, v));
            END LOOP;
            IF v_col <> '{}'::jsonb THEN
                v_out := v_out || jsonb_build_object(f.p || f.column_name, v_col);
            END IF;
        END LOOP;
    END IF;
    IF p_table = 'payment_requests' THEN
        v_col := '{}'::jsonb;
        FOR f IN SELECT DISTINCT e.key AS k, e.value #>> '{}' AS v
                   FROM (SELECT p_old -> 'allocations' AS j UNION ALL SELECT p_new -> 'allocations' UNION ALL SELECT p_ctx -> 'allocations') s
                   CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(s.j) = 'array' THEN s.j ELSE '[]'::jsonb END) a
                   CROSS JOIN LATERAL jsonb_each(CASE WHEN jsonb_typeof(a) = 'object' THEN a ELSE '{}'::jsonb END) e
                  WHERE e.key IN ('expense_id', 'inbound_batch_id', 'purchase_order_id', 'freight_document_id')
                    AND jsonb_typeof(e.value) = 'string' LOOP
            v_col := v_col || jsonb_build_object(f.v, trail_ref_label(
                CASE f.k WHEN 'expense_id' THEN 'expenses' WHEN 'inbound_batch_id' THEN 'inbound_batches'
                         WHEN 'purchase_order_id' THEN 'purchase_orders' ELSE 'freight_documents' END, 'id', f.v));
        END LOOP;
        IF v_col <> '{}'::jsonb THEN
            v_out := v_out || jsonb_build_object('allocations', v_col);
        END IF;
    END IF;
    -- MES-4a(2026-10-07):一炉的一个值指着它的字段,而那条外键是两列(工序 + 字段代号)—— trail_fk_targets 只认单列的,
    --   于是这里按影像里的工序把 field_code 解析成字段的英文名,放在 'field_code' 一格下("Value recorded · Blade speed")。
    --   字段不删(只退役),所以一定解析得到;解析不到就照通用那一形状说 gone。
    IF p_table = 'processing_run_values' THEN
        v_col := '{}'::jsonb;
        FOR f IN SELECT DISTINCT s.j ->> 'operation_type_code' AS op, s.j ->> 'field_code' AS fc
                   FROM (SELECT p_old AS j UNION ALL SELECT p_new UNION ALL SELECT p_ctx) s
                  WHERE s.j IS NOT NULL AND s.j ->> 'field_code' IS NOT NULL LOOP
            v_col := v_col || jsonb_build_object(f.fc, COALESCE(
                (SELECT jsonb_build_object('label', otf.name_en, 'gone', false) FROM operation_type_fields otf
                  WHERE otf.operation_type_code = f.op AND otf.field_code = f.fc),
                jsonb_build_object('label', NULL, 'gone', true)));
        END LOOP;
        IF v_col <> '{}'::jsonb THEN
            v_out := v_out || jsonb_build_object('field_code', v_col);
        END IF;
    END IF;
    RETURN v_out;
END;
$function$;

-- db/functions/trail_ref_label.sql
-- AUDIT-TRAIL-1a(Tim 的 Q12 · Q13 · Q40):一个被引用的值 → 屏幕上认得出的名字。数据库解析,界面只负责造句。
--   返回 {"label": …, "gone": bool, "person": {…}}(person 只在 p_table = 'auth.users' 时有):
--   · 单据(document_types 登记的表)→ 单据编号(PO-2026-0010);客户 / 供应商 → 法定名;物料 → 名称;
--     员工 → 称呼名,没有就法定名;批次 → 编号 · 物料名(外加 unit);采购单明细行 → 采购单编号 line N;
--     字典(有 name_en 的表)→ name_en;币种 → 代码;其余依次试 name / legal_name / title / label。
--   · 一个都没有 → label 为 NULL,界面说 "a <thing>"。【绝不回落到 uuid 或内部代码】。
--   · 那一行已经被硬删 → 取 change_log 里它最后一份完整影像,gone = true(界面加 "(since deleted)");
--     连影像都没有(早于变更记录,或从未存在)→ label NULL + gone = true(界面说 "a … that has since been deleted")。
--   · 'auth.users':一个登录账号 → 那个人(trail_actor 同一套答法)。
-- AUDIT-TRAIL-1b-1:
--   · 加工单多带一个 ended(它已经回滚了)—— 批次页上"用在加工 PROC-…"那一条据此加一句灰字
--     "This processing was later rolled back"(旧批次记录的 run_voided,Q5)。
--   · 交接班 → "DD/MM/YYYY · 班次";停机 → "机器编号 · DD/MM/YYYY HH:MM"(新加坡时间)—— 两张表都没有编号或名字,
--     以前只能说 "a handover" / "a downtime"。
-- AUDIT-TRAIL-1b-2:订单 / 报价明细行 → "SO-… line N";港口 → "代码 名称";航段 → "起运港 → 目的港";
--   执照与合规证书 → "种类 · 编号";附件 → 文件名;集装箱单据 → 单据种类 —— 这几张表都没有编号或 name 一类的列。
--   物料多带一个 unit(与批次同一个做法):订单 / 报价明细行的数量据此说成 "10 kg"。
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 的 Q12 · Q33):
--   · 员工 → 走 trail_actor(与"谁做的"同一份答法):不持 module.hr.view 的读者只认得出他自己,别人一律 Restricted ——
--     与 ActorName、与每一页的人名同一条规矩(§9.7 早就说"每一个指着人的值都走同一个函数",而此前这一支直接把名字交了出去)。
--     付款、费用、报销单、付款申请上的 employee_id 都是这一种。匿名化了的人说 "A former employee"(以前是一个空名字)。
--   · 单据(document_types 里 link_mode = 'detail' 的)多带一个 href(详情页的路径)—— 审计记录里"被 JE-… 冲销"那一行
--     是一个链接(Q33),路径来自登记表,界面不拼路由。
-- AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §g · Q14):这几张表没有编号或名字,以前只能说 "a …":
--   · 销售 → "OUT-2026-0186 sale 01/08/2026"(卖的那一批 + 售出日;与 "PO-… line N" 同一种说法),外加 href 指向它的应收页
--     (Q14:销售没有 code 列,所以【不】进 document_types —— 进了,全站搜索会对它拼一句 SELECT code,当场报错;
--      Record 一栏的名字与链接由这里与 trail_row_record 给,与单据同一个形状);
--   · 汇率 → "USD · TT selling rate · 01/08/2026";对账单行 → "BS-… line N";分录行 → "JE-… · 科目";申报格 → "Box 1";
--     对账记录 → "BS-… reconciliation DD/MM/YYYY";折旧 → "FA-… · period ending DD/MM/YYYY"。
-- AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a):这几张也没有编号或名字 ——
--   · 财务设置那一行 → "Finance settings";公司资料那一行 → "Company profile"(两张都是单行表,id = true);
--   · 月结 → "Period ending DD/MM/YYYY";年结 → "Year ending DD/MM/YYYY";
--   · 行内转账 → "Transfer DD/MM/YYYY · Cash at Bank – SGD → Cash at Bank – USD"(两头按科目表的名字说,不说 1000 / 1010)。
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a):
--   · 登录账号('auth.users')多带一个 label —— 认得出的那个人的名字(trail_actor 同一份答法:不持 hr.view 的读者只认得出
--     自己):/settings/change-history 的 Record 一栏(授权、附加账号的家是账号,Q22)读 label,不读 person。认不出就没有名字,
--     界面说 "a login account" —— 【不】回落到邮箱(那是账号的身份数据,不是它的名字)。
--   · 培训记录 → 培训的名字;导入批次 → 文件名(两张表都没有 name / title / label 一类的列)。
-- AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a · Q36):
--   · 假期发放 → "Annual leave 2027"(假别的英文名 + 那一个假期年;那张表没有名字一类的列);
--   · 加班批 → 它的 label("OT 2026-10 #1",照旧),外加 href 指向 /hr/overtime/<id>。加班批没有 code 列,所以它【不】进
--     document_types(全站搜索会对登记的每一张表拼一句 SELECT code —— 销售那一刀记过同一个理由);链接在这里给,与销售同一个形状。
-- AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a · Q10):
--   · 评审 → "Annual review 01/01/2026–31/12/2026"(种类 + 期间;那张表没有名字一类的列 —— 被评审的人【不】进名字:
--     名字要过 ActorName 那一道,而这一句是一个单据的名字,不经 trail_actor);外加 href 指向 /hr/reviews/<id>;
--   · 工资申请 → "PAY-2026-0001 posting request"(label 里那一截原样的种类 "· post #1" 不上屏 —— Q10;种类说成英文);
--   · KPI 条目 → "F1 · Stock accuracy"(参考号 · 标题)。轮次(name)与评分刻度(name_en)走通用的那一支。
-- 【属主身份】按表名动态读;EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.trail_ref_label(p_table text, p_column text, p_value text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_img   jsonb;
    v_gone  boolean := false;
    v_label text;
    v_doc   boolean;
    v_extra text;
BEGIN
    IF p_value IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_table = 'auth.users' THEN
        IF p_value !~ '^[0-9a-fA-F-]{36}$' THEN
            RETURN NULL;
        END IF;
        v_img := trail_actor('prelog', p_value::uuid, NULL);
        RETURN jsonb_build_object('person', v_img, 'label', CASE WHEN v_img ->> 'state' = 'person' THEN v_img ->> 'name' END);
    END IF;
    IF to_regclass(format('public.%I', p_table)) IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_table = 'employees' AND p_column = 'id' THEN
        IF p_value !~ '^[0-9a-fA-F-]{36}$' THEN
            RETURN NULL;
        END IF;
        -- label 一并带回(只在认得出名字时):/settings/change-history 的 Record 一栏读 label,不读 person
        v_img := trail_actor('prelog', NULL, p_value::uuid);
        RETURN jsonb_build_object('person', v_img, 'gone', false,
                                  'label', CASE WHEN v_img ->> 'state' = 'person' THEN v_img ->> 'name' END);
    END IF;
    EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.%I::text = $1 LIMIT 1', p_table, p_column)
       INTO v_img USING p_value;
    IF v_img IS NULL THEN
        v_gone := true;
        SELECT CASE WHEN c.op = 'DELETE' THEN c.old ELSE c.new END INTO v_img
          FROM change_log c
         WHERE c.table_name = p_table AND c.row_key = jsonb_build_object(p_column, p_value)
           AND c.op IN ('INSERT', 'DELETE')
         ORDER BY c.seq DESC LIMIT 1;
        IF v_img IS NULL THEN
            RETURN jsonb_build_object('label', NULL, 'gone', true);
        END IF;
    END IF;
    v_doc := EXISTS (SELECT 1 FROM document_types d WHERE d.table_name = p_table);
    v_label := CASE
        WHEN p_table = 'employees' THEN
            CASE WHEN v_img ->> 'anonymised_at' IS NULL
                 THEN COALESCE(NULLIF(v_img ->> 'preferred_name', ''), v_img ->> 'legal_name') END
        WHEN p_table IN ('suppliers', 'customers') THEN v_img ->> 'legal_name'
        WHEN p_table = 'materials' THEN v_img ->> 'name'
        WHEN p_table = 'currencies' THEN v_img ->> 'code'
        WHEN p_table = 'training_records' THEN v_img ->> 'training_name'
        WHEN p_table = 'import_batches' THEN v_img ->> 'file_name'
        WHEN p_table = 'purchase_order_lines' THEN
            (SELECT po.code FROM purchase_orders po WHERE po.id::text = v_img ->> 'purchase_order_id')
            || ' line ' || (v_img ->> 'line_no')
        WHEN v_doc AND v_img ? 'code' THEN v_img ->> 'code'
        WHEN v_img ? 'name_en' THEN v_img ->> 'name_en'
        WHEN v_img ? 'name' THEN v_img ->> 'name'
        WHEN v_img ? 'legal_name' THEN v_img ->> 'legal_name'
        WHEN v_img ? 'title' THEN v_img ->> 'title'
        WHEN v_img ? 'label' THEN v_img ->> 'label'
    END;
    IF p_table = 'shift_handovers' THEN
        v_label := to_char((v_img ->> 'handover_date')::date, 'DD/MM/YYYY')
                   || COALESCE(' · ' || (SELECT s.name_en FROM shifts s WHERE s.code = v_img ->> 'shift_code'), '');
    ELSIF p_table = 'equipment_downtime' THEN
        v_label := COALESCE((SELECT fa.code FROM fixed_assets fa WHERE fa.id::text = v_img ->> 'equipment_id') || ' · ', '')
                   || to_char(((v_img ->> 'started_at')::timestamptz) AT TIME ZONE 'Asia/Singapore', 'DD/MM/YYYY HH24:MI');
    ELSIF p_table IN ('sales_order_lines', 'quote_lines', 'invoice_lines') THEN
        -- AUDIT-TRAIL-1b-2:订单 / 报价的明细行 → "SO-2026-0001 line 1"(与采购单明细同一种说法)
        -- AUDIT-TRAIL-1c-1:发票明细行同一种说法(贷项通知的每一行冲的是发票的哪一行)
        v_label := CASE p_table
            WHEN 'sales_order_lines' THEN (SELECT so.code FROM sales_orders so WHERE so.id::text = v_img ->> 'sales_order_id')
            WHEN 'invoice_lines' THEN (SELECT i.code FROM invoices i WHERE i.id::text = v_img ->> 'invoice_id')
            ELSE (SELECT q.code FROM quotes q WHERE q.id::text = v_img ->> 'quote_id') END
            || ' line ' || (v_img ->> 'line_no');
    ELSIF p_table = 'ports' THEN
        -- 港口 → "SGSIN Singapore"(航段页、货代页上的同一种写法)
        v_label := concat_ws(' ', v_img ->> 'code', v_img ->> 'name');
    ELSIF p_table = 'lanes' THEN
        -- 航段没有名字 → "起运港 → 目的港"(两头各按港口那一句说)
        v_label := COALESCE((SELECT concat_ws(' ', pt.code, pt.name) FROM ports pt WHERE pt.id::text = v_img ->> 'origin_port_id'), '?')
                   || ' → ' ||
                   COALESCE((SELECT concat_ws(' ', pt.code, pt.name) FROM ports pt WHERE pt.id::text = v_img ->> 'destination_port_id'), '?');
    ELSIF p_table IN ('company_compliance', 'supplier_compliance') THEN
        -- 执照 / 证书 → "证书种类 · 编号"
        v_label := concat_ws(' · ', (SELECT ct.name_en FROM certificate_types ct WHERE ct.code = v_img ->> 'cert_type_code'),
                             NULLIF(v_img ->> 'cert_no', ''));
    ELSIF p_table IN ('customer_attachments', 'supplier_attachments') THEN
        v_label := v_img ->> 'file_name';
    ELSIF p_table = 'container_documents' THEN
        v_label := v_img ->> 'document_type';
    ELSIF p_table = 'sales_records' THEN
        v_label := COALESCE((SELECT ob.code FROM output_batches ob WHERE ob.id::text = v_img ->> 'output_batch_id') || ' sale ', 'Sale ')
                   || to_char((v_img ->> 'sale_date')::date, 'DD/MM/YYYY');
        RETURN jsonb_build_object('label', v_label, 'gone', v_gone)
               || CASE WHEN p_column = 'id' AND NOT v_gone
                       THEN jsonb_build_object('href', '/finance/receivables/' || p_value) ELSE '{}'::jsonb END;
    ELSIF p_table = 'fx_rates' THEN
        v_label := concat_ws(' · ', v_img ->> 'currency',
                             CASE v_img ->> 'rate_type' WHEN 'tt_buy' THEN 'TT buying rate' WHEN 'tt_sell' THEN 'TT selling rate'
                                                        WHEN 'mid' THEN 'Mid rate' END,
                             to_char((v_img ->> 'rate_date')::date, 'DD/MM/YYYY'));
    ELSIF p_table = 'journal_lines' THEN
        -- 对账单的一行匹配到的那一行分录 → "JE-2026-0001 · Cash at Bank – SGD"(分录号 · 科目)
        v_label := concat_ws(' · ', (SELECT je.code FROM journal_entries je WHERE je.id::text = v_img ->> 'entry_id'),
                             (SELECT a.name_en FROM accounts a WHERE a.id::text = v_img ->> 'account_id'));
    ELSIF p_table = 'bank_statement_lines' THEN
        v_label := (SELECT bs.code FROM bank_statements bs WHERE bs.id::text = v_img ->> 'statement_id') || ' line ' || (v_img ->> 'line_no');
    ELSIF p_table = 'gst_return_boxes' THEN
        v_label := 'Box ' || regexp_replace(v_img ->> 'box', '^box', '');
    ELSIF p_table = 'bank_reconciliations' THEN
        v_label := (SELECT bs.code FROM bank_statements bs WHERE bs.id::text = v_img ->> 'statement_id')
                   || ' reconciliation ' || to_char(((v_img ->> 'reconciled_at')::timestamptz) AT TIME ZONE 'Asia/Singapore', 'DD/MM/YYYY');
    ELSIF p_table = 'fixed_asset_depreciation' THEN
        v_label := (SELECT fa.code FROM fixed_assets fa WHERE fa.id::text = v_img ->> 'asset_id')
                   || ' · period ending ' || to_char((v_img ->> 'period_end')::date, 'DD/MM/YYYY');
    ELSIF p_table = 'finance_settings' THEN
        v_label := 'Finance settings';
    ELSIF p_table = 'company_profile' THEN
        v_label := 'Company profile';
    ELSIF p_table = 'period_closes' THEN
        v_label := 'Period ending ' || to_char((v_img ->> 'period_end')::date, 'DD/MM/YYYY');
    ELSIF p_table = 'year_closes' THEN
        v_label := 'Year ending ' || to_char((v_img ->> 'year_end')::date, 'DD/MM/YYYY');
    ELSIF p_table = 'bank_transfers' THEN
        v_label := 'Transfer ' || to_char((v_img ->> 'transfer_date')::date, 'DD/MM/YYYY') || ' · '
                   || COALESCE((SELECT a.name_en FROM accounts a WHERE a.code = v_img ->> 'from_account'), '?') || ' → '
                   || COALESCE((SELECT a.name_en FROM accounts a WHERE a.code = v_img ->> 'to_account'), '?');
    ELSIF p_table = 'leave_grants' THEN
        v_label := concat_ws(' ', (SELECT lt.name_en FROM leave_types lt WHERE lt.code = v_img ->> 'leave_type_code'), v_img ->> 'leave_year');
    ELSIF p_table = 'overtime_batches' THEN
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
               || CASE WHEN p_column = 'id' AND NOT v_gone
                       THEN jsonb_build_object('href', '/hr/overtime/' || p_value) ELSE '{}'::jsonb END;
    ELSIF p_table = 'performance_reviews' THEN
        v_label := CASE v_img ->> 'review_type' WHEN 'probation' THEN 'Probation review' ELSE 'Annual review' END
                   || ' ' || to_char((v_img ->> 'period_start')::date, 'DD/MM/YYYY') || '–' || to_char((v_img ->> 'period_end')::date, 'DD/MM/YYYY');
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
               || CASE WHEN p_column = 'id' AND NOT v_gone
                       THEN jsonb_build_object('href', '/hr/reviews/' || p_value) ELSE '{}'::jsonb END;
    ELSIF p_table = 'payroll_requests' THEN
        v_label := COALESCE((SELECT pp.code FROM payroll_periods pp WHERE pp.id::text = v_img ->> 'payroll_period_id') || ' ', '')
                   || CASE v_img ->> 'kind' WHEN 'reversal' THEN 'unposting request' ELSE 'posting request' END;
    ELSIF p_table = 'process_recipe_versions' THEN
        -- MES-4a(2026-10-07):一个配方版本说成"配方代号 v版本号"(CR-STD v2)—— 它自己没有 code / name 列
        v_label := (SELECT rc.code FROM process_recipes rc WHERE rc.id::text = v_img ->> 'recipe_id') || ' v' || (v_img ->> 'version');
    ELSIF p_table = 'kpi_entries' THEN
        v_label := concat_ws(' · ', NULLIF(v_img ->> 'kpi_ref', ''), NULLIF(v_img ->> 'title', ''));
    ELSIF p_table = 'processing_runs' THEN
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone, 'ended', v_img ->> 'deleted_at' IS NOT NULL);
    END IF;
    IF p_table = 'materials' THEN
        -- AUDIT-TRAIL-1b-2:物料带回它的单位 —— 订单 / 报价的明细行没有单位列,"10"要说成"10 kg"
        --   只在影像里真有单位时才带(一份早于变更记录、只剩名字的影像不说单位 —— 与"名字 + gone"那一形状逐字相同)
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
               || CASE WHEN v_img ->> 'unit' IS NOT NULL THEN jsonb_build_object('unit', v_img ->> 'unit') ELSE '{}'::jsonb END;
    END IF;
    IF p_table IN ('inbound_batches', 'output_batches') THEN
        IF v_img ->> 'material_id' IS NOT NULL THEN
            SELECT m.name INTO v_extra FROM materials m WHERE m.id::text = v_img ->> 'material_id';
            IF v_extra IS NOT NULL THEN
                v_label := v_label || ' · ' || v_extra;
            END IF;
        END IF;
        -- 批次的数量单位随名字一起带回 —— 加工单的"用了 300"要说成"300 kg",而投入 / 产出行自己没有单位列
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone, 'unit', v_img ->> 'unit');
    END IF;
    RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
           || COALESCE((SELECT jsonb_build_object('href', d.route || '/' || p_value) FROM document_types d
                         WHERE d.table_name = p_table AND d.link_mode = 'detail' AND p_column = 'id' AND NOT v_gone
                         ORDER BY d.key LIMIT 1), '{}'::jsonb);
END;
$function$;

-- ── 10 · 签名变了的一支:DROP 旧的、CREATE 新的(末尾六个可缺省的参数)────────────────────────

DROP FUNCTION public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text, p_work_order_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_operation_type_code text DEFAULT NULL::text, p_started_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ended_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_shift_code text DEFAULT NULL::text, p_recipe_version_id uuid DEFAULT NULL::uuid, p_values jsonb DEFAULT NULL::jsonb, p_corrects_run_id uuid DEFAULT NULL::uuid)
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
    -- PROC-WIRE-1B-i:这一炉跑的是哪道工序,以及那道工序【吃不吃料、产不产批】。
    -- 【分支读的是字典那两列,不是一个写死的字符串,也不是调用方传的旗标】
    -- 【PROC-SUPPORT-1】v_consumes / v_produces 不再有"没有工序时"的默认值 ——
    -- 到得了这里就一定有工序,两个值都由字典填。留着 := true 会是一句谎:
    -- 它读起来像"还有一条没有工序的路",而那条路已经在上面被拒掉了。
    v_op           text;
    v_consumes     boolean;
    v_produces     boolean;
    v_result_state text;
    -- MES-4a:机器的挂接、更正的原单、配方那一版、每条产出腿的称重
    v_corr         processing_runs%ROWTYPE;
    v_recipe       record;
    v_since        date;
    v_n            integer;
    v_wid          uuid;
    v_w            weighings%ROWTYPE;
    v_wcal         record;
    v_dev          uuid;
    v_out_qty      numeric[] := ARRAY[]::numeric[];
    v_out_wid      uuid[] := ARRAY[]::uuid[];
    v_key          text;
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
    -- ★ MES-4a(2026-10-07,MES-0 Q42;MES-4a Step 0 Q7,Tim):【开始、结束、班次】与上面三条必填【一起】,在任何业务判断之前。
    --   判据只有一份(assert_run_header):表上的 INSERT 触发器问的是同一支,correct_run_header 改时刻时也问它。
    -- ════════════════════════════════════════════════════════════════════════
    PERFORM assert_run_header(p_process_date, p_started_at, p_ended_at, p_shift_code);

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
    -- EQP-2a 的三条(没找到 · 早于取得 · 晚于处置)与 MES-4a 的工序 ↔ 资产规则,判据都在 assert_run_equipment ——
    -- correct_run_header 改机器时问的是同一支。投用之前不拒、试车照收的理由见那支函数与上面这段。
    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-4a(2026-10-07,MES-0 Q41;MES-4a Step 0 Q9,Tim):【上面那段等的前置条件到了】—— 工序 ↔ 资产的关联
    --   (operation_type_equipment)。一道工序只要挂着【至少一台没处置的】机器,这一炉就必须说出是哪一台,而且必须是挂着的那几台之一。
    --   处置掉的机器不算数(一道只挂着一台已处置机器的工序 = 没有挂机器)。没有挂任何机器的工序照旧:机器可选。
    --   【为什么不在"没挂机器"时也拒一台被点名的机器】那正是 U1-B 的可选选择器今天的样子,而挂不挂是 Tim 的数据 ——
    --   在他挂之前,一张记下了用哪台机器的单是更多的信息,不是错。
    -- ════════════════════════════════════════════════════════════════════════
    PERFORM assert_run_equipment(v_op, p_equipment_id, p_process_date);

    -- ── MES-4a(MES-0 Q49;Q31):这一张来更正哪一张 —— 原单必须已经回滚,而且只能被更正一次 ─────────────
    IF p_corrects_run_id IS NOT NULL THEN
        SELECT * INTO v_corr FROM processing_runs WHERE id = p_corrects_run_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_corrects_run_id;
        END IF;
        IF v_corr.status <> 'reversed' THEN
            RAISE EXCEPTION 'RUN_CORRECTS_NOT_REVERSED|%', v_corr.code
              USING HINT = '数量的更正 = 先经回滚申请(CFO 批)把原单冲掉,再记这一张新单指回它。原单还没冲销。';
        END IF;
        IF EXISTS (SELECT 1 FROM processing_runs r WHERE r.corrects_run_id = p_corrects_run_id) THEN
            RAISE EXCEPTION 'RUN_ALREADY_CORRECTED|%|%', v_corr.code,
                (SELECT r.code FROM processing_runs r WHERE r.corrects_run_id = p_corrects_run_id);
        END IF;
    END IF;

    -- ── MES-4a(MES-0 Q44;Q16):配方的那一版 —— 必须是这道工序的、配方还启用着 ─────────────
    IF p_recipe_version_id IS NOT NULL THEN
        SELECT rv.id, rv.version, rv.param_values, rc.code, rc.operation_type_code, rc.is_active INTO v_recipe
          FROM process_recipe_versions rv JOIN process_recipes rc ON rc.id = rv.recipe_id
         WHERE rv.id = p_recipe_version_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'RECIPE_VERSION_NOT_FOUND|%', p_recipe_version_id;
        END IF;
        IF v_recipe.operation_type_code <> v_op THEN
            RAISE EXCEPTION 'RECIPE_VERSION_NOT_FOR_OPERATION|%|%', v_recipe.code, v_op;
        END IF;
        IF NOT v_recipe.is_active THEN
            RAISE EXCEPTION 'RECIPE_INACTIVE|%', v_recipe.code;
        END IF;
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
    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-4a(2026-10-07,规格 §3.2 · §4.1;MES-0 Q22;MES-4a Step 0 Q24–Q26,Tim):【每一条产出腿都是称出来的】
    --   一条腿二选一:
    --     · weighing_id —— 挑一条现成的称重:确认了的、单独的净重(不挂地磅单)、没被更正过、没给别的腿用过;
    --     · weight_kg(+ 可选 device_id)—— 在这里敲一个重量:经正常的录入路径在同一笔事务里落一条手工称重(record_manual_weighing_internal)。
    --   腿的数量【就是】那次称重的公斤数(单位只能是 kg —— OUTPUT_UNIT_NOT_KG);再带一个不一样的 quantity → OUTPUT_QTY_NOT_WEIGHING。
    --   两样都没有 → OUTPUT_WEIGHING_REQUIRED|<第几条>。
    --   校准(MES-3a 的裁定 1,同一个判据 weighing_calibration_all):仪器在读数那一天【已知】不在校准期内 → 永远拒
    --   (READING_INSTRUMENT_NOT_CALIBRATED);没有记录仪器 → 开关 require_calibrated_since 空着时只标出来,开关给了且加工日在它之后才拒。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT s.require_calibrated_since INTO v_since FROM ingest_settings s WHERE s.id;
    v_n := 0;
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_n := v_n + 1;
        IF (v_output->>'material_id') IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NO_MATERIAL';
        END IF;
        IF NULLIF(v_output->>'unit', '') IS NOT NULL AND v_output->>'unit' <> 'kg' THEN
            RAISE EXCEPTION 'OUTPUT_UNIT_NOT_KG|%|%', v_n, v_output->>'unit';
        END IF;
        v_wid := NULLIF(v_output->>'weighing_id', '')::uuid;
        IF v_wid IS NOT NULL AND NULLIF(v_output->>'weight_kg', '') IS NOT NULL THEN
            RAISE EXCEPTION 'OUTPUT_WEIGHING_AMBIGUOUS|%', v_n;
        END IF;
        IF v_wid IS NULL THEN
            IF NULLIF(v_output->>'weight_kg', '') IS NULL THEN
                RAISE EXCEPTION 'OUTPUT_WEIGHING_REQUIRED|%', v_n
                  USING HINT = 'MES-4a 起每一条产出腿都要有一次称重:挑一条现成的,或在这里敲重量(会记成一次手工称重)。';
            END IF;
            v_qty := (v_output->>'weight_kg')::numeric;
            IF v_qty IS NULL OR v_qty <= 0 THEN
                RAISE EXCEPTION 'OUTPUT_QTY_INVALID';
            END IF;
            v_dev := NULLIF(v_output->>'device_id', '')::uuid;
            v_wid := record_manual_weighing_internal(v_qty, v_dev);
        END IF;
        SELECT * INTO v_w FROM weighings WHERE id = v_wid;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'WEIGHING_NOT_FOUND|%', v_wid;
        END IF;
        IF v_w.ticket_id IS NOT NULL OR v_w.role <> 'net' THEN
            RAISE EXCEPTION 'WEIGHING_NOT_STANDALONE_NET|%', v_n;
        END IF;
        IF EXISTS (SELECT 1 FROM weighings x WHERE x.corrects_id = v_w.id) THEN
            RAISE EXCEPTION 'WEIGHING_SUPERSEDED|%', v_w.id;
        END IF;
        IF v_wid = ANY (v_out_wid) THEN
            RAISE EXCEPTION 'WEIGHING_ALREADY_USED|%', v_n;
        END IF;
        IF EXISTS (SELECT 1 FROM processing_outputs po WHERE po.weighing_id = v_wid) THEN
            RAISE EXCEPTION 'WEIGHING_ALREADY_USED|%', (SELECT r.code FROM processing_outputs po JOIN processing_runs r ON r.id = po.run_id
                                                         WHERE po.weighing_id = v_wid);
        END IF;
        SELECT wc.status, wc.device_code, wc.captured_on INTO v_wcal FROM weighing_calibration_all wc WHERE wc.weighing_id = v_wid;
        IF v_wcal.status = 'not_recorded' THEN
            IF v_since IS NOT NULL AND v_process_date >= v_since THEN
                RAISE EXCEPTION 'OUTPUT_WEIGHING_INSTRUMENT_NOT_RECORDED|%', v_n;
            END IF;
        ELSIF v_wcal.status <> 'in_calibration' THEN
            RAISE EXCEPTION 'READING_INSTRUMENT_NOT_CALIBRATED|%|%', v_wcal.device_code, to_char(v_wcal.captured_on, 'YYYY-MM-DD');
        END IF;
        v_qty := v_w.weight_kg;
        IF NULLIF(v_output->>'quantity', '') IS NOT NULL AND (v_output->>'quantity')::numeric <> v_qty THEN
            RAISE EXCEPTION 'OUTPUT_QTY_NOT_WEIGHING|%|%|%', v_n, v_output->>'quantity', v_qty;
        END IF;
        v_out_wid := array_append(v_out_wid, v_wid);
        v_out_qty := array_append(v_out_qty, v_qty);
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
    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-4a(2026-10-07,规格 §4.1;MES-4a Step 0 Q17,Tim):【loss_qty 是推出来的:投入 − 产出】
    --   此前它是 COALESCE(p_loss_qty, 投入 − 产出)—— 调用方敲一个不同的数,那个数就被相信了,而它与投入 − 产出之间的差
    --   没有任何人过问(规格 §4.1:一笔只以差额存在的损耗没有审计价值)。现在敲一个不同的数按名拒;
    --   有名字的损耗(processing_run_losses)不许超过它,剩下的就是余数,由结平说出来。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_produces AND p_loss_qty IS NOT NULL AND p_loss_qty <> v_total_input - v_total_output THEN
        RAISE EXCEPTION 'LOSS_QTY_NOT_INPUT_MINUS_OUTPUT|%|%', p_loss_qty, v_total_input - v_total_output
          USING HINT = '损耗总量就是投入减产出,不另填。有名字的损耗在加工单页上分类记;剩下没解释的由结平说出来。';
    END IF;

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
        operation_type_code, started_at, ended_at, shift_code, recipe_version_id, corrects_run_id
    ) VALUES (
        v_process_date, v_total_input, v_total_output,
        CASE WHEN v_produces THEN v_total_input - v_total_output ELSE 0 END,
        p_notes, 'committed', p_allocation_basis, p_work_order_id, v_user_id, v_user_id,
        p_equipment_id,
        v_op, p_started_at, p_ended_at, p_shift_code, p_recipe_version_id, p_corrects_run_id
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
    v_n := 0;
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_n := v_n + 1;
        v_material_id := (v_output->>'material_id')::uuid;
        v_qty         := v_out_qty[v_n];     -- MES-4a:称出来的公斤数(上面第 2 步定下的)
        v_unit        := 'kg';
        v_purity      := NULLIF(v_output->>'purity', '');

        INSERT INTO output_batches (
            material_id, quantity, unit, remaining_qty, output_date, state, purity,
            created_by, updated_by
        ) VALUES (
            v_material_id, v_qty, v_unit, v_qty, v_process_date, '库存中', v_purity,
            v_user_id, v_user_id
        )
        RETURNING id INTO v_new_output_id;

        INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced, weighing_id)
        VALUES (v_run_id, v_new_output_id, v_qty, v_out_wid[v_n]);
    END LOOP;

    -- 用毕即清(price_ctx 同一条理由:免得同事务内后续的直改被误放行 ——
    -- fixture 19F 实测:不清,守卫触发器对残留 ctx 放行裸 INSERT)
    PERFORM set_config('evoltrya.movement_ctx', '', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-4a(2026-10-07,MES-0 Q43 · Q44;MES-4a Step 0 Q11 · Q16,Tim):【这一炉记下的参数与指标】
    --   配方那一版先预填它的参数(source = 'recipe');p_values 里给了的字段用给的值(source = 'manual')。
    --   配方里一个后来退役了的字段不预填(退役 = 以后别再用它)。必填【不在这里判】—— 在结平时判(Q11)。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_values IS NOT NULL AND jsonb_typeof(p_values) <> 'object' THEN
        RAISE EXCEPTION 'RUN_VALUES_INVALID';
    END IF;
    IF p_recipe_version_id IS NOT NULL THEN
        FOR v_key IN SELECT k FROM jsonb_object_keys(v_recipe.param_values) k ORDER BY k LOOP
            CONTINUE WHEN p_values IS NOT NULL AND p_values ? v_key;
            CONTINUE WHEN NOT EXISTS (SELECT 1 FROM operation_type_fields f
                                       WHERE f.operation_type_code = v_op AND f.field_code = v_key AND f.is_active);
            PERFORM record_run_value_internal(v_run_id, v_key, v_recipe.param_values -> v_key, 'recipe', NULL, NULL);
        END LOOP;
    END IF;
    IF p_values IS NOT NULL THEN
        FOR v_key IN SELECT k FROM jsonb_object_keys(p_values) k ORDER BY k LOOP
            CONTINUE WHEN jsonb_typeof(p_values -> v_key) = 'null';
            PERFORM record_run_value_internal(v_run_id, v_key, p_values -> v_key, 'manual', NULL, NULL);
        END LOOP;
    END IF;

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

-- ── 11 · 视图(镜像原样):改过的 CREATE OR REPLACE(列只在末尾加)· 新的三张 ──────────────────────

-- db/views/processing_run_loss_breakdown.sql
-- PROC-BUILD-1:一张加工单的损耗,分成【已解释】与【还没解释】两块。
-- **unexplained_qty 不是过磅误差** —— 它是还没有人说这部分去了哪。两者今天分不开
-- (见 processing_run_losses 的表注),而把它命名成误差会让一个记账问题看起来
-- 像一件已经查清的物理事实。
-- 【loss_qty 为空时差额是 NULL 不是 0】—— 0 会把没人记过总量读成全部解释完了。
-- MES-4a(2026-10-07):损耗只追加之后,每一类只算它更正链的末端(没被更正过的那一行)—— 撤回(更正成 0)就不算。
-- NOTE: introduced by db/migrations/2026-08-30-procbuild1-loss-categories-forms-and-saleability.sql.

CREATE OR REPLACE VIEW public.processing_run_loss_breakdown WITH (security_invoker = true) AS
 SELECT r.id AS run_id,
    r.code AS run_code,
    r.process_date,
    r.loss_qty,
    COALESCE(l.categorised_qty, 0::numeric) AS categorised_qty,
        CASE
            WHEN r.loss_qty IS NULL THEN NULL::numeric
            ELSE r.loss_qty - COALESCE(l.categorised_qty, 0::numeric)
        END AS unexplained_qty
   FROM processing_runs r
     LEFT JOIN ( SELECT l_1.run_id,
            sum(l_1.quantity) AS categorised_qty
           FROM processing_run_losses l_1
          WHERE NOT (EXISTS ( SELECT 1
                   FROM processing_run_losses x
                  WHERE x.corrects_id = l_1.id))
          GROUP BY l_1.run_id) l ON l.run_id = r.id
  WHERE r.deleted_at IS NULL;

-- db/views/equipment_usage.sql
-- EQP-2a:每台机器【做过什么】—— 从既有的加工记录推导,一个数都不存。
--
-- 【只有公斤,没有小时 —— 这是一个测量结果,不是一个将就】加工这一族里没有
-- 任何开始/结束/班次/工时列(实测:processing_runs 上唯一的世界侧日期是
-- process_date,一个 date;其余全是记账时刻;work_orders 只有 scheduled_date)。
-- 所以运转小时【推导不出来】,而本刀不为了让它可能而加一个时长字段。
-- EQP-2b 的保养间隔因此按公斤走。
--
-- 【口径:读表头,不重算腿】total_input / total_output / loss_qty 是
-- commit_processing_run 从腿上算好写下的;再从腿上算一遍只会造出同一个问题的
-- 第二个答案。实测线上五炉逐一比对,表头与腿的合计完全一致。
--
-- 【不算数的两种炉子】rollback_processing_run 在同一条 UPDATE 里把 status 置为
-- 'reversed' 并写下 deleted_at —— 两个标记同源,所以永远同步。判据两列一起看:
-- 任何一个将来被单独改动,这里都会立刻不一致。实测线上十三炉:
-- committed 且未删 10 条、reversed 且已删 3 条,另外两种组合零条。
--
-- 【LEFT JOIN 是刻意的】没跑过任何一炉的机器也要在,带一排 0;而
-- first/last_run_date 是 NULL —— 那不是零,是"还没有第一次"。
-- 【equipment_id 为空的炉子不在这张视图里】它们没有机器可归。要看它们得另读
-- processing_runs,并按那一列的注释显示成【未归属】这个具名类别。
--
-- 【属主权限 + 两个模块的 OR】机器卡在财务、干活的人在加工,两边都要读得到。
-- 这个 OR 是 AGENTS.md 第 2 条常设决定,batch_margin 里逐字实现着 ——
-- 实测没有哪个业务角色两个都持。
-- ★ MES-4a(2026-10-07,MES-4a Step 0 §1.7 · Q9):末尾多一列 equipment_category(fixed_assets.category)。此前加工单上的机器选择器
--   读这张视图时【每一张资产卡都给】,车辆与办公资产也在里面;现在选择器只给这道工序挂着的机器,而工序页挂机器时只给设备类 ——
--   两处都按这一列筛。只是加了一列,行不变。
-- NOTE: introduced by db/migrations/2026-08-21-eqp2a-what-the-machine-did.sql.

CREATE OR REPLACE VIEW public.equipment_usage WITH (security_invoker = off) AS
 SELECT fa.id AS equipment_id,
    fa.code AS equipment_code,
    fa.description AS equipment_description,
    fa.acquisition_date,
    fa.in_service_date,
    fa.status AS equipment_status,
    count(pr.id) AS run_count,
    COALESCE(sum(pr.total_input), 0::numeric) AS input_kg,
    COALESCE(sum(pr.total_output), 0::numeric) AS output_kg,
    COALESCE(sum(pr.loss_qty), 0::numeric) AS loss_kg,
    min(pr.process_date) AS first_run_date,
    max(pr.process_date) AS last_run_date,
    fa.category AS equipment_category
   FROM fixed_assets fa
     LEFT JOIN processing_runs pr ON pr.equipment_id = fa.id AND pr.status = 'committed'::text AND pr.deleted_at IS NULL
  WHERE has_permission('module.finance.view'::text) OR has_permission('module.processing.view'::text)
  GROUP BY fa.id, fa.code, fa.description, fa.acquisition_date, fa.in_service_date, fa.status, fa.category;

-- db/views/processing_run_balance_all.sql
-- MES-4a(2026-10-07,规格 §4.1;MES-0 Q46–Q48;MES-4a Step 0 Q17–Q22,Tim):【一炉的物料平衡,一份算术】—— 基视图,不给人读。
--   投入(表头 total_input)= 产出(表头 total_output)+ 有名字的损耗(每一类更正链末端之和)+ 余数。余数就是"没解释的质量"。
--   balance_state:
--     reversed        已回滚 / 已删 —— 不进任何清单
--     not_applicable  状态改变型(放电):投入恒等于产出、损耗恒为 0,没有平衡可结(Q20)
--     before_closure  开始时刻为空 = MES-4a 之前记下的单:不能结、不进清单,不回填(Q21)
--     closed          最新一次结平【还是当前的】—— 它之后没有更晚的损耗行、值行(按 id 水位线,Q19)
--     open            其余:还没结,或结过而被之后的更正重开
--   required_missing:这道工序上必填、启用着、而这一炉没有当前值的字段码(结平时拒,Q11)。
--   outputs_unweighed:没挂称重的产出腿条数(结平时拒,Q22 —— MES-4a 之后的单按构造是 0)。
--   tolerance_pct:这道工序【此刻】的容差(为空 = Not yet set);within_tolerance:余数的绝对值不超过 投入 × 容差%(容差为空时 NULL)。
--   【一份算术三个读者】close_run_balance(以属主身份读它)· processing_run_balance(带门的外壳,加工单页与清单读)·
--   operations_now 的 processing_balance_unclosed 与月末那一行(processing_runs_unclosed_balance)。
--   【属主视图、不带谓词、SELECT 从 authenticated 收回】—— 读者经 processing_run_balance。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE VIEW public.processing_run_balance_all WITH (security_invoker = off) AS
 SELECT r.id AS run_id,
    r.code AS run_code,
    r.process_date,
    r.status,
    r.operation_type_code,
    k.produces_outputs,
    r.started_at,
    r.total_input AS input_qty,
    r.total_output AS output_qty,
    r.loss_qty,
    COALESCE(nl.named_loss_qty, 0::numeric) AS named_loss_qty,
    r.total_input - r.total_output - COALESCE(nl.named_loss_qty, 0::numeric) AS remainder_qty,
    ot.balance_tolerance_pct AS tolerance_pct,
        CASE
            WHEN ot.balance_tolerance_pct IS NULL THEN NULL::boolean
            ELSE abs(r.total_input - r.total_output - COALESCE(nl.named_loss_qty, 0::numeric)) <= (r.total_input * ot.balance_tolerance_pct / 100::numeric)
        END AS within_tolerance,
    COALESCE(ow.outputs_total, 0::bigint) AS outputs_total,
    COALESCE(ow.outputs_unweighed, 0::bigint) AS outputs_unweighed,
    COALESCE(rq.required_missing, ARRAY[]::text[]) AS required_missing,
    lc.id AS last_closure_id,
    lc.closed_at AS last_closed_at,
    (lc.id IS NOT NULL AND COALESCE(mx.max_loss_id, 0::bigint) <= lc.loss_watermark AND COALESCE(mx.max_value_id, 0::bigint) <= lc.value_watermark) AS closure_current,
        CASE
            WHEN r.status <> 'committed'::text OR r.deleted_at IS NOT NULL THEN 'reversed'::text
            WHEN NOT k.produces_outputs THEN 'not_applicable'::text
            WHEN r.started_at IS NULL THEN 'before_closure'::text
            WHEN lc.id IS NOT NULL AND COALESCE(mx.max_loss_id, 0::bigint) <= lc.loss_watermark AND COALESCE(mx.max_value_id, 0::bigint) <= lc.value_watermark THEN 'closed'::text
            ELSE 'open'::text
        END AS balance_state,
    COALESCE(mx.max_loss_id, 0::bigint) AS max_loss_id,
    COALESCE(mx.max_value_id, 0::bigint) AS max_value_id
   FROM processing_runs r
     LEFT JOIN operation_types ot ON ot.code = r.operation_type_code
     LEFT JOIN operation_kinds k ON k.code = ot.kind_code
     LEFT JOIN LATERAL ( SELECT sum(l.quantity) AS named_loss_qty
           FROM processing_run_losses l
          WHERE l.run_id = r.id AND NOT (EXISTS ( SELECT 1
                   FROM processing_run_losses x
                  WHERE x.corrects_id = l.id))) nl ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS outputs_total,
            count(*) FILTER (WHERE po.weighing_id IS NULL) AS outputs_unweighed
           FROM processing_outputs po
          WHERE po.run_id = r.id) ow ON true
     LEFT JOIN LATERAL ( SELECT array_agg(f.field_code ORDER BY f.sort_order, f.field_code) AS required_missing
           FROM operation_type_fields f
          WHERE f.operation_type_code = r.operation_type_code AND f.is_required AND f.is_active
            AND NOT (EXISTS ( SELECT 1
                   FROM processing_run_values v
                  WHERE v.run_id = r.id AND v.field_code = f.field_code
                    AND num_nonnulls(v.value_number, v.value_text, v.value_bool) > 0
                    AND NOT (EXISTS ( SELECT 1
                           FROM processing_run_values x
                          WHERE x.corrects_id = v.id))))) rq ON true
     LEFT JOIN LATERAL ( SELECT c.id, c.closed_at, c.loss_watermark, c.value_watermark
           FROM processing_run_closures c
          WHERE c.run_id = r.id
          ORDER BY c.id DESC
         LIMIT 1) lc ON true
     LEFT JOIN LATERAL ( SELECT ( SELECT max(l.id) AS max
                   FROM processing_run_losses l
                  WHERE l.run_id = r.id) AS max_loss_id,
            ( SELECT max(v.id) AS max
                   FROM processing_run_values v
                  WHERE v.run_id = r.id) AS max_value_id) mx ON true;

COMMENT ON VIEW public.processing_run_balance_all IS
    'MES-4a:一炉的物料平衡(规格 §4.1)—— 投入 · 产出 · 有名字的损耗 · 余数 · 此刻的容差与判断 · 缺的必填值 · 没称重的产出 · 最新结平是否当前 · balance_state(reversed / not_applicable / before_closure / closed / open)。基视图,不给人读:读者经 processing_run_balance;结平与两支清单以属主身份读它。';

REVOKE ALL ON public.processing_run_balance_all FROM authenticated, anon;

-- db/views/processing_run_balance.sql
-- MES-4a(2026-10-07,MES-4a Step 0 Q19 · Q22,Tim):【一炉的物料平衡 —— 带门的外壳】。加工单页的平衡面板、加工单清单的那一栏读它。
--   门与 processing_runs 的读规则同一个码(module.processing.view);算术在 processing_run_balance_all,这里一个字都不重算。
--   属主权限:基视图从 authenticated 收回了;视图读视图走属主替换(AGENTS.md「属主视图替得了表」)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE VIEW public.processing_run_balance WITH (security_invoker = off) AS
 SELECT run_id,
    run_code,
    process_date,
    status,
    operation_type_code,
    produces_outputs,
    started_at,
    input_qty,
    output_qty,
    loss_qty,
    named_loss_qty,
    remainder_qty,
    tolerance_pct,
    within_tolerance,
    outputs_total,
    outputs_unweighed,
    required_missing,
    last_closure_id,
    last_closed_at,
    closure_current,
    balance_state
   FROM processing_run_balance_all
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_run_balance IS
    'MES-4a:一炉的物料平衡,带门(module.processing.view)。算术全在 processing_run_balance_all。';

GRANT SELECT ON public.processing_run_balance TO authenticated;
REVOKE ALL ON public.processing_run_balance FROM anon;

-- db/views/run_weighing_options.sql
-- MES-4a(2026-10-07,MES-0 Q22;MES-4a Step 0 Q24 · Q25,Tim):【提交加工单时,一条产出腿挑得到的称重】。
--   确认了的、单独的净重(不挂地磅单)、没被更正过、还没给任何一条产出腿用过 —— 与 commit_processing_run 第 2 步的判据逐条同一组;
--   带着仪器编号、读数时刻,以及仪器在读数那一天的校准状态(weighing_calibration_all 那一句判据:not_recorded 只标出来;
--   不在校准期内的照样列出来,提交时按名拒 —— 页面先说,而不是让它消失)。
--   属主权限 + 加工的门(module.processing.view):基视图 weighing_calibration_all 从 authenticated 收回了,视图读视图走属主替换。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE VIEW public.run_weighing_options WITH (security_invoker = off) AS
 SELECT w.id AS weighing_id,
    w.weight_kg,
    w.source,
    w.device_id,
    wc.device_code,
    w.captured_at,
    wc.status AS calibration_status
   FROM weighings w
     JOIN weighing_calibration_all wc ON wc.weighing_id = w.id
  WHERE w.ticket_id IS NULL AND w.role = 'net'::text
    AND NOT (EXISTS ( SELECT 1
           FROM weighings x
          WHERE x.corrects_id = w.id))
    AND NOT (EXISTS ( SELECT 1
           FROM processing_outputs po
          WHERE po.weighing_id = w.id))
    AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.run_weighing_options IS
    'MES-4a:提交加工单时一条产出腿挑得到的称重 —— 单独的、当前的净重,还没给任何一条腿用过;带仪器与读数那天的校准状态。门:module.processing.view。';

GRANT SELECT ON public.run_weighing_options TO authenticated;
REVOKE ALL ON public.run_weighing_options FROM anon;

-- db/views/processing_run_values_current.sql
-- MES-4a(2026-10-07,MES-0 Q43 · Q44;MES-4a Step 0 Q12 · Q16 · Q29,Tim):【一炉每个字段【当前】的值,与它对着配方差在哪】。
--   一行 = 一炉的一个字段的更正链末端(没有被别的行更正过的那一行;更正成"没有值"= 三列都空,也是一行 —— 撤回是看得见的)。
--   带着字段的名字、类型、单位、是不是必填;越界标记(记下那一刻的范围,out_of_range —— 照记,不拒);是不是被更正过(corrected);
--   以及这一炉用的配方那一版里这个字段的值(recipe_value)与 differs_from_recipe:配方有这个字段而当前值与它不同(撤回也算不同)→ true,
--   相同 → false,配方里没有这个字段或这一炉没用配方 → NULL(没法比,不是"没差")。
--   【一份比较,两个读者】加工单页的"参数与指标"那一块与 fixture 253 读它 —— 页面不自己比(AGENTS.md「一个预览的屏幕问数据库」)。
--   属主权限 + 加工的门(module.processing.view)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE VIEW public.processing_run_values_current WITH (security_invoker = off) AS
 SELECT v.run_id,
    v.id AS value_id,
    v.operation_type_code,
    v.field_code,
    f.name_en,
    f.name_zh,
    f.kind,
    f.value_type,
    f.unit,
    f.is_required,
    f.is_active AS field_active,
    v.value_number,
    v.value_text,
    v.value_bool,
    v.source,
    v.out_of_range,
    v.range_min_at,
    v.range_max_at,
    v.recorded_at,
    v.recorded_by,
    (v.corrects_id IS NOT NULL) AS corrected,
    v.correction_reason,
    rv.param_values -> v.field_code AS recipe_value,
        CASE
            WHEN rv.param_values IS NULL OR NOT (rv.param_values ? v.field_code) THEN NULL::boolean
            WHEN f.value_type = ANY (ARRAY['number'::text, 'count'::text]) THEN v.value_number IS DISTINCT FROM ((rv.param_values ->> v.field_code)::numeric)
            WHEN f.value_type = 'yes_no'::text THEN v.value_bool IS DISTINCT FROM ((rv.param_values ->> v.field_code)::boolean)
            ELSE v.value_text IS DISTINCT FROM (rv.param_values ->> v.field_code)
        END AS differs_from_recipe
   FROM processing_run_values v
     JOIN operation_type_fields f ON f.operation_type_code = v.operation_type_code AND f.field_code = v.field_code
     JOIN processing_runs r ON r.id = v.run_id
     LEFT JOIN process_recipe_versions rv ON rv.id = r.recipe_version_id
  WHERE NOT (EXISTS ( SELECT 1
           FROM processing_run_values x
          WHERE x.corrects_id = v.id))
    AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_run_values_current IS
    'MES-4a:一炉每个字段当前的值(更正链末端),带越界标记、是否更正过,以及它对着这一炉配方那一版的值差不差(differs_from_recipe;没法比时为 NULL)。门:module.processing.view。';

GRANT SELECT ON public.processing_run_values_current TO authenticated;
REVOKE ALL ON public.processing_run_values_current FROM anon;

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
-- 【MES-3b 加三支】(2026-10-07,MES-0 §5.1 V30 · V31;MES-3b Step 0 Q29 · V35,Tim)
--   V30  每一个启用的危险品 UN 编号的包装标记文字、包装说明、标签尺寸 —— 三样里有任何一样为空的每个编号一行
--        (去处:/settings/dictionaries;门 module.materials.view)。由有 DG 资质的货代在第一次出口之前给。
--   V31  每一种没删的电池料(种类吃得下状态轴)的 HS 编码 —— 为空的每种一行(去处:那个物料;门 module.materials.view)。
--        由报关行在第一次出口之前给。
--   V35  每一种没删的电池料的危险品 UN 编号 —— 没选的每种一行(同上)。由货代与 Tim 在第一次出口或第一次危险品发货之前给。
--        没给:标签与发货单上提示"没给",不拒(Q15)。
-- 【MES-4a 加两支、改一支】(2026-10-07,MES-0 §5.1 V1 · V7;MES-4a Step 0 Q35,Tim)
--   V1   每一道启用的【转化型】工序的物料平衡容差(投入的百分比)—— balance_tolerance_pct 为空的每道一行(去处:那道工序的页面;
--        门 module.processing.view)。由 Tim 与 cto 在每一段调试结束时给。没给:任何不为零的余数都要书面说明才能结平(Q46)。
--        状态改变型(放电)不列 —— 它投入恒等于产出,没有容差可言。
--   V36  每一个启用的、声明了【有范围】(has_range)而上下限都空着的参数 —— 一个字段一行(去处:那道工序的页面)。由设备厂商或
--        工艺工程师在那一段调试时给。没给:那个字段的值照记,不判越界。引导的字段一个都没声明有范围,所以今天是零行。
--   V6   【改了去处,一支答两个值】班次的起止时刻 —— MES-1 的 V6(传输异常的工作时间)与 MES-0 的 V7(加工单的班次时刻)读的是
--        同一组列(shifts.starts_at / ends_at),一支一行就够,两行说的会是同一件事。去处从 /operation/handovers(那一页只读班次,
--        改不了时刻)搬到 /settings/dictionaries(MES-4a 给班次加了一种"时刻"字段)。
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
            '/settings/dictionaries'::text AS href
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
                  WHERE l.is_active AND l.is_quarantine))
        UNION ALL
         SELECT 'V30'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            g.code AS item_code,
            g.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM dangerous_goods_codes g
          WHERE g.is_active AND (g.marking_text IS NULL OR g.packing_instruction IS NULL OR g.label_size IS NULL)
        UNION ALL
         SELECT 'V31'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.hs_code IS NULL
        UNION ALL
         SELECT 'V35'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.dg_code IS NULL
        UNION ALL
         SELECT 'V1'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            ot.code AS item_code,
            ot.name_en AS item_label,
            '/operation/operation-types/'::text || ot.code AS href
           FROM operation_types ot
             JOIN operation_kinds k ON k.code = ot.kind_code
          WHERE ot.is_active AND k.produces_outputs AND ot.balance_tolerance_pct IS NULL
        UNION ALL
         SELECT 'V36'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            (f.operation_type_code || '/'::text) || f.field_code AS item_code,
            f.name_en AS item_label,
            '/operation/operation-types/'::text || f.operation_type_code AS href
           FROM operation_type_fields f
             JOIN operation_types ot ON ot.code = f.operation_type_code
          WHERE f.is_active AND ot.is_active AND f.has_range AND f.range_min IS NULL AND f.range_max IS NULL) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程);MES-3a 加 V2(执照 × 类别的库存上限)、V29(NEA 类别与物料的类别)、V3(每个安全状态的滞留提醒天数)、V4(每个安全状态要不要隔离)与 V34(隔离库位);MES-3b 加 V30(危险品编号的标记 · 包装说明 · 标签尺寸)、V31(电池料的 HS 编码)与 V35(电池料的危险品编号);MES-4a 加 V1(转化型工序的物料平衡容差)与 V36(声明了有范围的参数的上下限),并把 V6 的去处搬到班次字典(V6 同时答 V7)。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行
-- ★ MES-4a(2026-10-07,MES-0 Q48;MES-4a Step 0 Q22,Tim):加一支 processing_balance_unclosed —— 物料平衡还没结的加工单
--   (MES-4a 起记的、转化型的、已提交没回滚的、最新结平不当前的;processing_run_balance_all 的 balance_state = 'open')。
--   门 module.processing.view;点进去是那张加工单(平衡面板在上面)。只是提醒:月末那一行也只警告,不挡关账。
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
         SELECT 'processing_balance_unclosed'::text AS item_type,
            'module.processing.view'::text AS permission,
            b.run_id AS item_id,
            NULL::text AS doc_kind,
            b.run_code AS item_code,
            b.operation_type_code AS subject,
            b.process_date AS item_date
           FROM processing_run_balance_all b
          WHERE b.balance_state = 'open'::text
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

-- ── 12 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──────────────────────────
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.operation_type_fields
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('operation_type_code', 'field_code');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.operation_type_fields
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.operation_type_equipment
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('operation_type_code', 'fixed_asset_id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.operation_type_equipment
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.process_recipes
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.process_recipes
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.process_recipe_versions
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.process_recipe_versions
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.processing_event_types
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.processing_event_types
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.processing_run_values
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.processing_run_values
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.processing_run_events
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.processing_run_events
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.processing_run_closures
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.processing_run_closures
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.processing_run_corrections
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.processing_run_corrections
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 13 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, timestamp with time zone, text, uuid, jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, timestamp with time zone, text, uuid, jsonb, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_run_value(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_run_value(uuid, text, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.correct_run_value(bigint, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_run_value(bigint, jsonb, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_run_event(uuid, text, timestamp with time zone, numeric, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_run_event(uuid, text, timestamp with time zone, numeric, text, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.correct_run_event(bigint, text, timestamp with time zone, numeric, text, text, text, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_run_event(bigint, text, timestamp with time zone, numeric, text, text, text, boolean, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_run_loss(uuid, text, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_run_loss(uuid, text, numeric, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.correct_run_loss(bigint, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_run_loss(bigint, numeric, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.create_recipe_version(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_recipe_version(uuid, jsonb, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.close_run_balance(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.close_run_balance(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.correct_run_header(uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_run_header(uuid, text, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.processing_runs_unclosed_balance(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.processing_runs_unclosed_balance(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.assert_run_header(date, timestamp with time zone, timestamp with time zone, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assert_run_header(date, timestamp with time zone, timestamp with time zone, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.assert_run_equipment(text, uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assert_run_equipment(text, uuid, date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_manual_weighing_internal(numeric, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_manual_weighing_internal(numeric, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_run_value_internal(uuid, text, jsonb, text, bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_run_value_internal(uuid, text, jsonb, text, bigint, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.run_event_check(text, timestamp with time zone, numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.run_event_check(text, timestamp with time zone, numeric, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_processing_run_header() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_processing_run_header() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_operation_type_field() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_operation_type_field() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_operation_type_equipment() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_operation_type_equipment() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_process_recipe() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_process_recipe() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.assert_run_header(date, timestamp with time zone, timestamp with time zone, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_run_equipment(text, uuid, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.record_manual_weighing_internal(numeric, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.record_run_value_internal(uuid, text, jsonb, text, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.run_event_check(text, timestamp with time zone, numeric, text, text) FROM authenticated;

-- ── 14 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes4a_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes4a_pending_after ON COMMIT DROP AS
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
         EXCEPT SELECT role_code || ':' || permission_code FROM mes4a_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes4a_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4A_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES4A_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes4a_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes4a_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES4A_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有加工单与它们的腿、损耗逐字未变
    IF EXISTS ((SELECT b.k, b.id FROM mes4a_pending_before b EXCEPT SELECT a.k, a.id FROM mes4a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes4a_pending_after a EXCEPT SELECT b.k, b.id FROM mes4a_pending_before b)) THEN
        RAISE EXCEPTION 'MES4A_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg(t::text, '|' ORDER BY t.id), '')) FROM (SELECT id, code, process_date, total_input, total_output, loss_qty, notes, status, deleted_at, created_at, created_by, updated_at, updated_by, allocation_basis, material_cost_base, process_cost_base, total_cost_base, allocation_snapshot, allocated_at, allocated_by, capitalized_cost_base, capitalization_entry_id, allocation_basis_changed_at, work_order_id, deleted_by, delete_reason, equipment_id, operation_type_code FROM processing_runs) t)
       IS DISTINCT FROM (SELECT digest FROM mes4a_runs_before) THEN
        RAISE EXCEPTION 'MES4A_PROOF|a pre-existing processing run changed';
    END IF;
    IF EXISTS (SELECT 1 FROM processing_runs WHERE started_at IS NOT NULL OR ended_at IS NOT NULL OR shift_code IS NOT NULL
                 OR recipe_version_id IS NOT NULL OR corrects_run_id IS NOT NULL)
       OR EXISTS (SELECT 1 FROM processing_outputs WHERE weighing_id IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4A_PROOF|a pre-existing run or leg got a MES-4a value';
    END IF;
    IF (SELECT md5(COALESCE(string_agg(i::text, '|' ORDER BY i.id), '')) FROM (SELECT id, run_id, inbound_batch_id, quantity_consumed, created_at, output_batch_id FROM processing_inputs) i)
           IS DISTINCT FROM (SELECT inputs FROM mes4a_legs_before)
       OR (SELECT md5(COALESCE(string_agg(o::text, '|' ORDER BY o.id), '')) FROM (SELECT id, run_id, output_batch_id, quantity_produced, created_at, allocated_cost_base, unit_cost_base, cost_incomplete FROM processing_outputs) o)
           IS DISTINCT FROM (SELECT outputs FROM mes4a_legs_before)
       OR (SELECT count(*) FROM processing_run_losses) <> (SELECT losses FROM mes4a_legs_before)
       OR EXISTS (SELECT 1 FROM processing_run_losses WHERE corrects_id IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4A_PROOF|a pre-existing input leg, output leg or loss row changed';
    END IF;

    -- ④ 变更记录只在引导的那几张字典与例外表上动了(两道工序 2 · 投料形态 2 · 产出形态 5 · 安全状态 2 · 损耗类别 3 · 例外表 2 = 16);
    --   新表的引导在它们的绑定之前插入(第 3 段 → 第 12 段),所以不进变更记录
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM mes4a_log_before)
       AND c.table_name NOT IN ('operation_types', 'operation_type_input_forms', 'operation_type_output_forms',
                                'operation_type_safety_states', 'loss_categories', 'document_type_exceptions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4A_PROOF|change_log moved on %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > (SELECT mx FROM mes4a_log_before)) <> 16 THEN
        RAISE EXCEPTION 'MES4A_PROOF|expected 16 change-log rows, got %',
            (SELECT count(*) FROM change_log c WHERE c.seq > (SELECT mx FROM mes4a_log_before));
    END IF;

    -- ⑤ 引导恰好是引导;新的数据表全是空的;一台机器都没挂;容差、范围、班次时刻、开关都空着
    IF (SELECT string_agg(code, ',' ORDER BY sort_order) FROM operation_types)
       IS DISTINCT FROM 'deep_discharge,manual_disassembly,electrode_line,electrode_powder_line,battery_powder_line,casing_removal,electrode_separation'
       OR EXISTS (SELECT 1 FROM operation_types WHERE balance_tolerance_pct IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4A_PROOF|operation_types are not the seven expected, or a tolerance was set';
    END IF;
    IF (SELECT count(*) FROM operation_type_fields) <> 27
       OR EXISTS (SELECT 1 FROM operation_type_fields WHERE is_required OR has_range OR range_min IS NOT NULL OR range_max IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4A_PROOF|the fields are not exactly their bootstrap (27, none required, no range)';
    END IF;
    IF (SELECT string_agg(code, ',' ORDER BY sort_order) FROM processing_event_types) IS DISTINCT FROM 'unplanned_stop,equipment_alarm,safety_alarm' THEN
        RAISE EXCEPTION 'MES4A_PROOF|the event types are not exactly their bootstrap';
    END IF;
    IF (SELECT count(*) FROM loss_categories) <> 7 THEN
        RAISE EXCEPTION 'MES4A_PROOF|expected 7 loss categories';
    END IF;
    IF EXISTS (SELECT 1 FROM operation_type_equipment) OR EXISTS (SELECT 1 FROM process_recipes) OR EXISTS (SELECT 1 FROM process_recipe_versions)
       OR EXISTS (SELECT 1 FROM processing_run_values) OR EXISTS (SELECT 1 FROM processing_run_events)
       OR EXISTS (SELECT 1 FROM processing_run_closures) OR EXISTS (SELECT 1 FROM processing_run_corrections) THEN
        RAISE EXCEPTION 'MES4A_PROOF|a new data table is not empty';
    END IF;
    IF EXISTS (SELECT 1 FROM shifts WHERE starts_at IS NOT NULL OR ends_at IS NOT NULL)
       OR (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL
       OR EXISTS (SELECT 1 FROM nea_waste_categories) OR EXISTS (SELECT 1 FROM licence_storage_limits)
       OR EXISTS (SELECT 1 FROM storage_locations WHERE is_quarantine)
       OR EXISTS (SELECT 1 FROM materials WHERE dg_code IS NOT NULL OR hs_code IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4A_PROOF|a shift time, the calibration switch or a MES-3a / 3b setting was set';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;员工那几支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES4A_PROOF|anon executes: %', v_bad;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, timestamp with time zone, text, uuid, jsonb, uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, timestamp with time zone, text, uuid, jsonb, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, timestamp with time zone, text, uuid, jsonb, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, timestamp with time zone, text, uuid, jsonb, uuid): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_run_value(uuid, text, jsonb)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_run_value(uuid, text, jsonb)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_run_value(uuid, text, jsonb)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.record_run_value(uuid, text, jsonb): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.correct_run_value(bigint, jsonb, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.correct_run_value(bigint, jsonb, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.correct_run_value(bigint, jsonb, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.correct_run_value(bigint, jsonb, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_run_event(uuid, text, timestamp with time zone, numeric, text, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_run_event(uuid, text, timestamp with time zone, numeric, text, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_run_event(uuid, text, timestamp with time zone, numeric, text, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.record_run_event(uuid, text, timestamp with time zone, numeric, text, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.correct_run_event(bigint, text, timestamp with time zone, numeric, text, text, text, boolean, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.correct_run_event(bigint, text, timestamp with time zone, numeric, text, text, text, boolean, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.correct_run_event(bigint, text, timestamp with time zone, numeric, text, text, text, boolean, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.correct_run_event(bigint, text, timestamp with time zone, numeric, text, text, text, boolean, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_run_loss(uuid, text, numeric, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_run_loss(uuid, text, numeric, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_run_loss(uuid, text, numeric, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.record_run_loss(uuid, text, numeric, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.correct_run_loss(bigint, numeric, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.correct_run_loss(bigint, numeric, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.correct_run_loss(bigint, numeric, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.correct_run_loss(bigint, numeric, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.create_recipe_version(uuid, jsonb, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.create_recipe_version(uuid, jsonb, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.create_recipe_version(uuid, jsonb, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.create_recipe_version(uuid, jsonb, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.close_run_balance(uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.close_run_balance(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.close_run_balance(uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.close_run_balance(uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.correct_run_header(uuid, text, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.correct_run_header(uuid, text, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.correct_run_header(uuid, text, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.correct_run_header(uuid, text, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.processing_runs_unclosed_balance(date)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.processing_runs_unclosed_balance(date)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.processing_runs_unclosed_balance(date)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.processing_runs_unclosed_balance(date): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF has_function_privilege('authenticated', 'public.assert_run_header(date, timestamp with time zone, timestamp with time zone, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.assert_run_header(date, timestamp with time zone, timestamp with time zone, text)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.assert_run_header(date, timestamp with time zone, timestamp with time zone, text)'::regprocedure) THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.assert_run_header(date, timestamp with time zone, timestamp with time zone, text) must be an internal function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.assert_run_equipment(text, uuid, date)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.assert_run_equipment(text, uuid, date)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.assert_run_equipment(text, uuid, date)'::regprocedure) THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.assert_run_equipment(text, uuid, date) must be an internal function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.record_manual_weighing_internal(numeric, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_manual_weighing_internal(numeric, uuid)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_manual_weighing_internal(numeric, uuid)'::regprocedure) THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.record_manual_weighing_internal(numeric, uuid) must be an internal function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.record_run_value_internal(uuid, text, jsonb, text, bigint, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_run_value_internal(uuid, text, jsonb, text, bigint, text)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_run_value_internal(uuid, text, jsonb, text, bigint, text)'::regprocedure) THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.record_run_value_internal(uuid, text, jsonb, text, bigint, text) must be an internal function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.run_event_check(text, timestamp with time zone, numeric, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.run_event_check(text, timestamp with time zone, numeric, text, text)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.run_event_check(text, timestamp with time zone, numeric, text, text)'::regprocedure) THEN
        RAISE EXCEPTION 'MES4A_PROOF|public.run_event_check(text, timestamp with time zone, numeric, text, text) must be an internal function nobody outside can call';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('operation_type_fields', 'operation_type_equipment', 'process_recipes', 'process_recipe_versions', 'processing_event_types', 'processing_run_values', 'processing_run_events', 'processing_run_closures', 'processing_run_corrections', 'processing_run_balance_all', 'processing_run_balance', 'run_weighing_options', 'processing_run_values_current')
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4A_PROOF|anon can read %', v_bad; END IF;
    IF to_regprocedure('public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES4A_PROOF|the old commit_processing_run signature survived';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条;只追加的表上没有写策略;三张加工表与损耗表的写策略恰好是这样
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES4A_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('process_recipe_versions', 'processing_run_values', 'processing_run_events', 'processing_run_closures', 'processing_run_corrections', 'processing_run_losses') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES4A_PROOF|a write policy exists on an append-only table';
    END IF;
    SELECT string_agg(tablename || ':' || cmd, ',' ORDER BY tablename, cmd) INTO v_bad FROM pg_policies
     WHERE schemaname = 'public' AND tablename IN ('processing_runs', 'processing_inputs', 'processing_outputs', 'processing_run_losses');
    IF v_bad IS DISTINCT FROM 'processing_inputs:INSERT,processing_inputs:SELECT,processing_outputs:SELECT,processing_run_losses:SELECT,processing_runs:SELECT' THEN
        RAISE EXCEPTION 'MES4A_PROOF|processing policies are %', v_bad;
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(九张新表都记,豁免仍是 8);遮蔽零缺口(仍是 105 条);每一张被记录的表的绑定键都是它的主键
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES4A_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES4A_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    SELECT string_agg(t.relname, ', ') INTO v_bad
      FROM (SELECT c.relname, substring(pg_get_triggerdef(tg.oid) FROM 'change_log_capture\((.*)\)') AS args
              FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND tg.tgname = 'zzz_change_log') t
      LEFT JOIN (SELECT c.relname, string_agg(quote_literal(a.attname), ', ' ORDER BY array_position(i.indkey::int2[], a.attnum)) AS cols
                   FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                   JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY (i.indkey)
                  WHERE n.nspname = 'public' AND i.indisprimary GROUP BY c.relname) pk ON pk.relname = t.relname
     WHERE t.args IS DISTINCT FROM pk.cols;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4A_PROOF|change-log key is not the primary key on %', v_bad; END IF;

    -- ⑨ 提醒臂 55 → 56;待补的值 13 → 15 支
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 56 THEN
        RAISE EXCEPTION 'MES4A_PROOF|operations_now should have 56 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 15 THEN
        RAISE EXCEPTION 'MES4A_PROOF|pending_values should have 15 arms';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes4a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES4A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes4a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES4A_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes4a_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
