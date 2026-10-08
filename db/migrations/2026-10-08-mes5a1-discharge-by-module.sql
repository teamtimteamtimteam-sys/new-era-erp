-- db/migrations/2026-10-08-mes5a1-discharge-by-module.sql
-- MES-5a-1 —— 逐模组的放电结果、按结果核实、失效模组拆去隔离、放电的三处老毛病(MES 组的第七刀,v1.4.43;发布那一行在
-- docs/handbacks/MES-5a-1.md 的抬头)。由 db/scripts/build_mes5a1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-08:MES-5a Step 0 的放电那一半 —— Q3–Q18 与 Q1 · Q29–Q34 · Q36 的放电部分 —— 全部照建议裁定;
--   Q2 拆成两刀,能量那一半(Q19–Q28 · Q35 · V25)是 MES-5a-2;docs/surveys/MES-5a/STEP0-HANDBACK.md)
--   ① 模组数(Q4):两张批次表 + module_count(进料批是遮蔽表:列 + 列级授权 + _masked 视图,一支迁移)· guard_batch_module_count
--      (只对装电芯的形态成立;不许低于已有结论的模组数;核实之后锁住)· set_batch_module_count · 两支收货函数末尾一个可缺省的参数。
--   ② 逐模组结果(Q3 · Q5–Q8 · Q12):discharge_module_results(只追加;判失败处置必填;V9 抄进行里、矛盾只标出)·
--      discharge_channel_assignments(只追加)· record / correct_discharge_module_result(action.confirm_capture)·
--      assign / correct_discharge_channel(action.processing_aftercare)· 内层两支。设备转换器【没有建】(Bosch 的逐模组导出格式没人给过 ——
--      MES-3b Q25 · MES-4a Q14);结果行的来源 / 收件箱 / 草稿 / 现场数据那几列已经在。
--   ③ 按结果核实(Q5 · Q6):operation_types.verifies_by_unit(引导:只有 deep_discharge)—— 提交不再改状态;discharge_verify_batch
--      (每一个计数的模组都有一条当前的通过、或已被拆去隔离 → 已放电并核实,记下是哪一炉;不再成立 → 撤回)。
--   ④ 拆去隔离(Q11):discharge_quarantine_split(转化型工序;只从加工单页上起 —— started_from_run_page)· discharge_module_splits ·
--      split_failed_modules_to_quarantine · create_stock_transfer 拆成判码的外壳 + 内层(拆分的门是 aftercare,不是库存编辑码)。
--   ⑤ 三处老毛病(Q14 · Q15 · Q6):P3 产出批这一侧的放电不再扣库存;P2 回滚只在工序吃料时还原库存;P1 由 ③ 关掉。
--   ⑥ 读者与登记(Q18 · Q29–Q32):两张核实视图 + 两张带门的读法 · operations_now +2 支 · pending_values +1 支(V9,materials 上一列)·
--      审计记录(加工单 · 两种批次 · 设备)· 变更记录绑三张新表 · 关系图例外 +2 行(原批 ↔ 拆出来的那一批走拆分那一炉,两跳)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改任何一张既有单据、批次、加工单或
--   安全状态(PROC-2026-0494 与线上开着的两个状态原样);不给任何批次记模组数;不给任何物料通过电压(V9);不标任何隔离库位;不记任何通道;
--   require_calibrated_since 保持空。只播:deep_discharge 的 verifies_by_unit、一道新工序 discharge_quarantine_split 与它的受理 / 形态信息行、
--   关系图例外的两行。
--
-- 【破窗】见 docs/surveys/MES-5a/STEP0-HANDBACK.md §8:部署之前,旧表单记的一炉深度放电照样提交,但【不再核实】那一批(状态由结果改,
--   而旧应用没有记结果的地方)—— 部署之后在那一炉的页面上补记结果。线上没有 MES-4a 起记的加工单。其余照旧。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多;七个账号一个都没被停;
--   既有的每一张加工单与它的腿、每一批进料与产出(除了多出来的那一列,而它全是空的)、每一条安全状态、每一个物料、每一个库位逐字未变;
--   变更记录只在引导的那几张表上动了、恰好 15 行;新的数据表是空的;开关是空的;anon 能执行的【恰好】两支;内层谁都调不到;
--   那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口;提醒臂 59 支;待补的值 18 支;每一张在途单据仍有一个不是它当事人的决定人。
--   断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES5A1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.discharge_module_results') IS NOT NULL OR to_regclass('public.discharge_channel_assignments') IS NOT NULL
       OR to_regclass('public.discharge_module_splits') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A1_PRE|MES-5a-1 tables already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                 AND ((table_name IN ('inbound_batches', 'output_batches') AND column_name = 'module_count')
                      OR (table_name = 'materials' AND column_name = 'discharge_pass_voltage_v')
                      OR (table_name = 'operation_types' AND column_name IN ('verifies_by_unit', 'started_from_run_page')))) THEN
        RAISE EXCEPTION 'MES5A1_PRE|MES-5a-1 columns already exist';
    END IF;
    IF (SELECT count(*) FROM operation_types) <> 7 OR EXISTS (SELECT 1 FROM operation_types WHERE code = 'discharge_quarantine_split') THEN
        RAISE EXCEPTION 'MES5A1_PRE|operation types are not the MES-4b shape (7, no split operation)';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5A1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES5A1_PRE|expected 105 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 57 THEN
        RAISE EXCEPTION 'MES5A1_PRE|operations_now should have 57 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 17 THEN
        RAISE EXCEPTION 'MES5A1_PRE|pending_values should have 17 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A1_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT transform_function FROM ingest_data_classes WHERE code = 'discharge_module') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A1_PRE|the discharge_module class already has a transform';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes5a1_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes5a1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes5a1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes5a1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes5a1_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_runs t) AS runs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_inputs t) AS inputs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_outputs t) AS outputs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM inbound_batches t) AS inbound,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM output_batches t) AS output,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM materials t) AS materials,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM inbound_batch_safety_states t) AS ib_states,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM output_batch_safety_states t) AS ob_states,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM storage_locations t) AS locations,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM inventory_movements t) AS movements;

-- ── 1 · 先建的函数:两张批次表上要挂的触发器(镜像原样)──────────────────────────

-- db/functions/guard_batch_module_count.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-5a Step 0 Q4 · Q6,Tim):【模组数这一列的三条规矩】—— 挂在 inbound_batches 与 output_batches 上
--   (BEFORE INSERT OR UPDATE OF module_count, material_id),所以收货、批次页、拆分与直连 SQL 一起盖住。
--   ① 只对仍装着电芯的形态成立:物料的形态 implies_dismantling 为假 → MODULE_COUNT_NOT_APPLICABLE|<批号>|<形态>。
--      没有形态的物料不拦(不知道不等于不适用 —— 与 guard_batch_cell_construction 同一条)。
--   ② 不许低于这一批已经有结论的模组数(含拆出去的),也不许在有结论之后清空:MODULE_COUNT_BELOW_RESULTS|<批号>|<已有结论的模组数>。
--   ③ 这一批此刻开着那道工序的结果状态(已放电并核实)→ 锁住:MODULE_COUNT_LOCKED|<批号>(Q4:核实之后锁住)。
--   【为什么是 SECURITY DEFINER】②③ 要数放电结果与读安全状态 —— 一个持进料编辑码、却不持加工查看码的人直连 UPDATE 时,
--   invoker 读法会被 RLS 安静地数成 0,规矩就漏了。触发器函数的 EXECUTE 不在触发时检查,所以 EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.guard_batch_module_count()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_form       text;
    v_dismantles boolean;
    v_n          bigint;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.module_count IS NOT DISTINCT FROM OLD.module_count
       AND NEW.material_id IS NOT DISTINCT FROM OLD.material_id THEN
        RETURN NEW;
    END IF;

    IF NEW.module_count IS NOT NULL THEN
        SELECT f.code, f.implies_dismantling INTO v_form, v_dismantles
          FROM materials m LEFT JOIN material_forms f ON f.code = m.form_code
         WHERE m.id = NEW.material_id;
        IF v_form IS NOT NULL AND NOT v_dismantles THEN
            RAISE EXCEPTION 'MODULE_COUNT_NOT_APPLICABLE|%|%', NEW.code, v_form
              USING HINT = '模组数只对仍装着电芯的形态成立(整包、模组、散电芯、已开壳电芯、混合料)。这一批的物料形态里没有电芯。';
        END IF;
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.module_count IS DISTINCT FROM OLD.module_count THEN
        SELECT count(*) INTO v_n FROM discharge_module_current_all c WHERE c.batch_id = NEW.id;
        IF v_n > 0 AND (NEW.module_count IS NULL OR NEW.module_count < v_n) THEN
            RAISE EXCEPTION 'MODULE_COUNT_BELOW_RESULTS|%|%', NEW.code, v_n
              USING HINT = '这一批已经有这么多个模组记了放电结论(含拆出去的)—— 模组数不能比它少,也不能清空。';
        END IF;
        IF EXISTS (SELECT 1 FROM discharge_batch_status_all s
                    WHERE s.batch_id = NEW.id AND s.currently_verified) THEN
            RAISE EXCEPTION 'MODULE_COUNT_LOCKED|%', NEW.code
              USING HINT = '这一批已经是"已放电并核实"—— 那个结论是按这个模组数判的,核实之后不再改。';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 2 · 工序(Q5 · Q11):按结果核实的标志 · 只从加工单页上起的标志 · 一道新工序(拆去隔离)与它的受理 / 形态信息行 ──────────
ALTER TABLE public.operation_types
    ADD COLUMN verifies_by_unit boolean NOT NULL DEFAULT false,
    ADD COLUMN started_from_run_page boolean NOT NULL DEFAULT false;
INSERT INTO public.operation_types (code, name_en, name_zh, kind_code, resulting_safety_state_code, sort_order, notes) VALUES
    ('discharge_quarantine_split', 'Quarantine split of failed modules', '失效模组拆去隔离', 'transforming', NULL, 8,
     '【MES-5a-1 · 规格 §3.1 · MES-0 Q23】放电失败、处置为隔离的模组,从原批里拆出来:称它们的重量,原批消耗这么多,产出同一物料的一批,带"带电未放电",放进隔离库位。只从放电那一炉的页面上起(split_failed_modules_to_quarantine),不在新建加工单的选单里。');
UPDATE public.operation_types SET verifies_by_unit = true WHERE code = 'deep_discharge';
UPDATE public.operation_types SET started_from_run_page = true WHERE code = 'discharge_quarantine_split';
COMMENT ON COLUMN public.operation_types.verifies_by_unit IS
    'MES-5a-1(规格 §3.1;MES-0 Q23 · Q24;MES-5a Step 0 Q5 · Q6):这道状态改变型工序的结果状态由逐件的结果判,不在提交时写。为真时 commit_processing_run 只记下这一炉、不动状态;每一个计数的模组(module_count)都有一条当前的通过(最新一条,所在的那一炉没回滚)或已被拆去隔离时,discharge_verify_batch 才把批次改成结果状态并记下是哪一炉做到的 —— 状态史与回滚照旧。引导:只有 deep_discharge。';
COMMENT ON COLUMN public.operation_types.started_from_run_page IS
    'MES-5a-1(MES-5a Step 0 Q11 · Q13):这道工序只从一张加工单的页面上起(新建加工单的选单不列它)。引导:只有 discharge_quarantine_split —— 它由 split_failed_modules_to_quarantine 从放电那一炉的页面上起,同时记下拆出去的是哪几个模组。提交函数本身不拒它(拆分函数就是经提交函数记那一炉的)。';
INSERT INTO public.operation_type_safety_states (operation_type_code, safety_state_code, resolves, notes) VALUES
    ('discharge_quarantine_split', 'charged_not_discharged', false,
     '【MES-5a-1 · MES-0 Q23】从一批还没核实的料里拆出放电失败、处置为隔离的模组。不解决 —— 拆出去的那一批照样是"带电未放电",进隔离库位。'),
    ('discharge_quarantine_split', 'discharged_verified', false,
     '【MES-5a-1】受理、不解决 —— 保住 fixture 178 D3 的重合(一般可投的状态被每一道启用的工序受理)。拆分函数另外要求点名的模组是"失败 · 隔离"。');
INSERT INTO public.operation_type_input_forms (operation_type_code, form_code, notes) VALUES
    ('discharge_quarantine_split', 'whole_pack', NULL),
    ('discharge_quarantine_split', 'module', NULL),
    ('discharge_quarantine_split', 'loose_cells', NULL),
    ('discharge_quarantine_split', 'mixed_unsorted', NULL);
INSERT INTO public.operation_type_output_forms (operation_type_code, form_code, notes) VALUES
    ('discharge_quarantine_split', 'whole_pack', '【MES-5a-1】同一物料,拆出去的那几个模组。'),
    ('discharge_quarantine_split', 'module', '【MES-5a-1】同上。'),
    ('discharge_quarantine_split', 'loose_cells', '【MES-5a-1】同上。'),
    ('discharge_quarantine_split', 'mixed_unsorted', '【MES-5a-1】同上。');

-- ── 3 · V9(Q8):物料的放电通过电压 ──────────────────────────
ALTER TABLE public.materials ADD COLUMN discharge_pass_voltage_v numeric CHECK (discharge_pass_voltage_v IS NULL OR discharge_pass_voltage_v > 0);
COMMENT ON COLUMN public.materials.discharge_pass_voltage_v IS
    'MES-5a-1(V9;规格 §3.1;MES-5a Step 0 Q8):这一种物料的一个模组放电之后的通过电压(伏),按物料给 —— 模组的终止电压取决于串联节数。为空 = Not yet set(Bosch 文档 / 模组规格书,放电调试时)。只标出一条与它矛盾的放电判定(判通过而出口电压高于它,或判失败而不高于它),从不拒、从不替人判;为空 = 判不了。记一条模组结果时抄进 discharge_module_results.pass_voltage_v_at,之后改它不重判旧行。';

-- ── 4 · 进料批的模组数(Q4):一列 + 列级授权 + 遮蔽视图(三件事一起)+ 守卫触发器 ──────────────────────────
ALTER TABLE public.inbound_batches ADD COLUMN module_count integer CHECK (module_count IS NULL OR module_count > 0);
GRANT SELECT (id, code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, stage, notes, status, deleted_at, created_at, created_by, updated_at, updated_by, purchase_order_id, purchase_order_line_id, pricing_formula_id, pricing_status, deleted_by, delete_reason, declared_qty, chemistry_certainty_code,
    -- CMPL-1:进口尽调那四列。【不敏感】,所以进列清单授权 —— 给遮蔽表加列
    -- 必须同时做三件事(ADD COLUMN + 本授权 + _masked 视图),少一件就"写得进、读不出"。
    imported, import_permit_ref, import_permit_verified_by, import_permit_verified_at,
    -- PROC-1B-iii:实际到的货能不能深度放电。同上,三件事一件都不能少 ——
    -- 而这一列漏掉的后果特别隐蔽:"读不到"会显示成"未记录",
    -- 与本刀刻意设计的"缺一侧就是 NULL"长得一模一样。
    deep_discharge_actual_code,
    -- RECV-SOURCE-1:来源理由四列。不敏感(审计轨迹第一环,不是钱),
    -- 进列清单授权 —— 三件事(列 + 本授权 + _masked 视图)同一支迁移。
    source_reason_code, source_reason_note,
    source_reason_recorded_by, source_reason_recorded_at,
    -- MES-4b:电芯结构。不敏感(工艺路由要用的事实),进列清单授权 —— 三件事(列 + 本授权 + _masked 视图)同一支迁移。
    cell_construction_code,
    -- MES-5a-1:模组数。不敏感(放电核实要用的计数),进列清单授权 —— 三件事同一支迁移。
    module_count)
    ON public.inbound_batches TO authenticated;
CREATE TRIGGER trg_inbound_batches_module_count
    BEFORE INSERT OR UPDATE OF module_count, material_id ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_module_count();
COMMENT ON COLUMN public.inbound_batches.module_count IS
'MES-5a-1(规格 §3.1;MES-5a Step 0 Q4 · Q6):这一批有几个模组。为空 = 没记(收货时可选,批次页上补:set_batch_module_count,进料编辑码或加工提交码)。
记这一批第一条放电模组结果之前必须有(BATCH_MODULE_COUNT_REQUIRED)。这一批被核实为"已放电并核实"(每一个模组都有一条当前的通过,或已被拆去隔离)
之后锁住(MODULE_COUNT_LOCKED);不许低于已经记了结果的模组数(MODULE_COUNT_BELOW_RESULTS)。只对仍装着电芯的形态成立(没有形态的物料不拦)。
不遮蔽:列级授权 + _masked 视图原样透出。';

-- db/views/inbound_batches_masked.sql
-- ★ ROLE-1 Batch 4a(2026-09-25,Tim 的 Q9 线):本视图是【采购那一侧】的价格 —— 遮蔽码从 data.view_prices
--   换成 data.view_purchase_prices(今天持 view_prices 的每一个角色一并拿到它,仓库只拿它)。
-- 【PROC-2:多一列 chemistry_certainty_code】遮蔽表加一列是三件事,这是第三件 ——
-- gate 的 colgrant 判据是「一张表一旦有 _masked 伴生,每一列都必须在那张视图里,
-- 授权与否都一样」,所以这一列即便是非敏感的、已经列级授权了,也必须在这里出现。
-- 遮蔽伴生视图:inbound_batches 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:unit_price → data.view_prices
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.inbound.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- RECV-SOURCE-1(2026-09-01)追加四列(source_reason_code / _note /
-- _recorded_by / _recorded_at),不遮蔽 —— 同 CMPL-1 那四列的处置。
--
-- GRN-1a:declared_qty 追加在末尾。它【不遮蔽】—— 它是一个量,不是价;而它必须
-- 出现在本视图里,因为 colgrant 的规矩是"一张表有了 _masked,它的每一列都得在里面"
-- (WO-1a)。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.

-- CMPL-1(2026-08-30)追加四列(imported / import_permit_ref /
-- import_permit_verified_by / import_permit_verified_at)。
-- 【它们是【不敏感】的,所以走列清单 GRANT + 出现在本视图里,不做遮蔽】——
-- 真正敏感的仍然只有 unit_price,按 data.view_prices 透出。
-- 【给遮蔽表加列是三件事一起做】ADD COLUMN + 列清单 GRANT + 本视图;
-- 少任何一件,应用都会"写得进、读不出"(FIN-6 的原样重演),而 gate 的
-- colgrant 判词会在 live 与 rebuild 两侧同时点名。
CREATE OR REPLACE VIEW public.inbound_batches_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    material_id,
    supplier_id,
    quantity,
    unit,
    remaining_qty,
    arrival_date,
    stage,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    purchase_order_id,
    purchase_order_line_id,
    pricing_formula_id,
    pricing_status,
    deleted_by,
    delete_reason,
    declared_qty,
    chemistry_certainty_code,
    imported,
    import_permit_ref,
    import_permit_verified_by,
    import_permit_verified_at,
    -- PROC-1B-iii fu1:遮蔽表加一列 = 三件事(列 + 列级授权 + 本视图)。
    -- 【不遮蔽,原样透出】它是工艺路由要用的事实,不是钱、不是个人信息。
    deep_discharge_actual_code,
    -- RECV-SOURCE-1:来源理由四列。【不遮蔽,原样透出】—— 审计轨迹的第一环,
    -- 不是钱、不是个人信息;colgrant 的规矩是"有 _masked 伴生,每一列都得在里面"。
    source_reason_code,
    source_reason_note,
    source_reason_recorded_by,
    source_reason_recorded_at,
    -- MES-4b:电芯结构。【不遮蔽,原样透出】—— 工艺路由要用的事实;三件事的第三件。
    cell_construction_code,
    -- MES-5a-1:模组数。【不遮蔽,原样透出】—— 放电核实要用的计数;三件事的第三件。
    module_count
   FROM inbound_batches
  WHERE has_permission('module.inbound.view'::text);;

GRANT SELECT ON public.inbound_batches_masked TO authenticated;

-- ── 5 · 产出批的模组数(Q4;不是遮蔽表)+ 守卫触发器 ──────────────────────────
ALTER TABLE public.output_batches ADD COLUMN module_count integer CHECK (module_count IS NULL OR module_count > 0);
CREATE TRIGGER trg_output_batches_module_count
    BEFORE INSERT OR UPDATE OF module_count, material_id ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_module_count();
COMMENT ON COLUMN public.output_batches.module_count IS
'MES-5a-1(规格 §3.1;MES-5a Step 0 Q4 · Q6 · Q11):这一批有几个模组 —— 与 inbound_batches.module_count 同义同规矩(guard_batch_module_count)。
拆去隔离的那一批(discharge_quarantine_split 的产出)由 split_failed_modules_to_quarantine 写上拆出去的模组数。';

-- ── 5b · 更正一句过期的列注释(MES-5a Step 0 §10.4 · Q36):processing_runs.equipment_id 说"没有工序 ↔ 资产的关联",MES-4a 之后不成立 ──
COMMENT ON COLUMN public.processing_runs.equipment_id IS
    'EQP-2a:这一炉是哪台机器跑的。可空,而"空"是一个【具名类别】(未归属),不是零。
★【这一列在表上【不】跟着 operation_type_code 一起变成必填 —— 不要"修"掉这处不对称】★
PROC-SUPPORT-1 / R2 的理由是当时的一次【测量】:线上 fixed_assets 只有 2 行,都是深度放电机,另外四道工序一台在册机器都没有 —— 表上必填会让那四道工序一张单都提交不了;而当时库里没有【工序 ↔ 资产】的关联,那才是缺口本身。
MES-4a(2026-10-07)建了那条关联(operation_type_equipment),于是必填改成【按工序】判,不在表上:一道工序挂着至少一台没处置的机器,这一炉就必须给机器,而且只能是挂着的那几台之一(assert_run_equipment:EQUIPMENT_REQUIRED_FOR_OPERATION · EQUIPMENT_NOT_LINKED_TO_OPERATION);没挂机器的工序照旧可以留空。机器挂不挂在哪道工序上是数据(工序页),不是这一列的约束。
(MES-5a-1 更正,MES-5a Step 0 §10.4 · Q36:此前这段写着"今天这个库里没有这条关联",MES-4a 之后已不成立。)';

-- ── 6 · 三张新表(镜像原样:结果 · 通道分配 · 拆去隔离的模组)──────────────────────────────────────────

-- db/tables/discharge_module_results.sql
-- MES-5a-1(2026-10-08,规格 §3.1 · §9;MES-0 Q23–Q25;MES-5a Step 0 Q3–Q8 · Q12,Tim):【一个模组一次放电的结果】—— 只追加,逐次记。
--   一行挂在一炉深度放电(run_id,工序的 verifies_by_unit 为真)与那一炉的一批投料(inbound_batch_id XOR output_batch_id)上,
--   说的是那一批里的【一个模组】(module_ref:铭牌上读得出的序列号,读不出就写在模组上的位置标签,如 M01 —— 在这一批里唯一;
--   再放一次电沿用同一个)。通道号(channel_no)是另一格,可选。
--   必填:出口电压(伏)· 判定 pass | fail · 判定时刻 · 来源。判 fail 时【处置必填】re_discharge | quarantine(规格 §3.1:没有它,
--   一批里失败的模组在后面的记录里没有去处)。可选:起始电压 · 时长(分钟)· 回收能量(瓦时)· 一张屏幕照片(capture-photos 桶)·
--   设备、收件箱、草稿与现场数据指针(设备来的行)。
--   V9(materials.discharge_pass_voltage_v,按物料)在记录那一刻抄进 pass_voltage_v_at;contradicts_pass_voltage = 判通过而出口电压
--   高于它、或判失败而不高于它 —— 只标出来,从不拒,从不替人判;线为空 → NULL = 判不了。时长只记,不判。
--   【当前】= 没被更正(没有一行的 corrects_id 指着它)、所在的那一炉没回滚;【最新】= 同一批同一个模组的当前行里判定时刻最晚的那一条
--   (再按 id)—— 再放一次电时最新的赢。重放次数是推出来的(结果条数 − 1),不存。
--   【更正】新行指回原行(corrects_id 唯一)+ 必填理由;读链的末端。
--   【来源】今天只有 manual(MES-5a-1:Bosch 的逐模组导出格式没人给过,所以设备转换器【没有建】—— MES-3b Q25 · MES-4a Q14 的先例);
--   source / inbox_id / draft_id / site_* 这几列已经在,将来接上设备不必改表。
--   只经 record_discharge_module_result / correct_discharge_module_result(action.confirm_capture)写;UPDATE / DELETE / TRUNCATE 语句级拒。
--   读:加工、进料或产出查看码(批次页上要看得见自己那一批的逐模组结果)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.discharge_module_results (
    id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id                   uuid NOT NULL REFERENCES public.processing_runs (id),
    inbound_batch_id         uuid REFERENCES public.inbound_batches (id),
    output_batch_id          uuid REFERENCES public.output_batches (id),
    module_ref               text NOT NULL CHECK (btrim(module_ref) = module_ref AND module_ref <> '' AND length(module_ref) <= 60),
    channel_no               integer CHECK (channel_no IS NULL OR channel_no > 0),
    outlet_voltage_v         numeric NOT NULL CHECK (outlet_voltage_v >= 0),
    start_voltage_v          numeric CHECK (start_voltage_v IS NULL OR start_voltage_v >= 0),
    verdict                  text NOT NULL CHECK (verdict IN ('pass', 'fail')),
    verdict_at               timestamptz NOT NULL,
    disposition              text CHECK (disposition IN ('re_discharge', 'quarantine')),
    duration_min             numeric CHECK (duration_min IS NULL OR duration_min >= 0),
    energy_recovered_wh      numeric CHECK (energy_recovered_wh IS NULL OR energy_recovered_wh >= 0),
    pass_voltage_v_at        numeric,
    contradicts_pass_voltage boolean GENERATED ALWAYS AS (
                                 CASE WHEN pass_voltage_v_at IS NULL THEN NULL
                                      WHEN verdict = 'pass' THEN outlet_voltage_v > pass_voltage_v_at
                                      ELSE outlet_voltage_v <= pass_voltage_v_at END) STORED,
    photo_path               text,
    notes                    text,
    source                   text NOT NULL CHECK (source IN ('manual', 'device')),
    device_id                uuid REFERENCES public.devices (id),
    inbox_id                 bigint REFERENCES public.ingest_inbox (id),
    draft_id                 uuid REFERENCES public.capture_drafts (id),
    site_from                timestamptz,
    site_to                  timestamptz,
    site_dataset_ref         text,
    recorded_at              timestamptz NOT NULL DEFAULT now(),
    recorded_by              uuid DEFAULT auth.uid(),
    corrects_id              bigint UNIQUE REFERENCES public.discharge_module_results (id),
    correction_reason        text,
    CONSTRAINT discharge_module_results_one_batch CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    CONSTRAINT discharge_module_results_disposition_shape CHECK ((verdict = 'fail') = (disposition IS NOT NULL)),
    CONSTRAINT discharge_module_results_site_range CHECK (site_from IS NULL OR site_to IS NULL OR site_from <= site_to),
    CONSTRAINT discharge_module_results_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> ''))
);

COMMENT ON TABLE public.discharge_module_results IS
    'MES-5a-1:一个模组一次深度放电的结果,逐次、只追加(规格 §3.1)。一炉 × 一批 × 一个模组(module_ref,批内唯一,再放电沿用)。出口电压 · 判定 · 判定时刻必填;判失败时处置必填(再放电 / 隔离)。V9 抄进 pass_voltage_v_at,矛盾只标出不拒。最新的当前一条赢。更正 = 新行(corrects_id + 理由)。今天只有手工来源;设备那几列已在,设备转换器没有建(格式没人给过)。';

COMMENT ON COLUMN public.discharge_module_results.contradicts_pass_voltage IS
    'MES-5a-1(V9;Step 0 Q8):这一条判定是否与记录那一刻的通过电压(pass_voltage_v_at)矛盾 —— 判通过而出口电压高于它,或判失败而不高于它。线为空 → NULL = 判不了,不是"不矛盾"。只标出来,从不拒,从不替人判。';

-- 一炉一批一个模组只有一条原始行(其余是更正);再放电是另一炉
CREATE UNIQUE INDEX discharge_module_results_one_original
    ON public.discharge_module_results (run_id, COALESCE(inbound_batch_id, output_batch_id), module_ref)
    WHERE corrects_id IS NULL;
CREATE INDEX discharge_module_results_inbound ON public.discharge_module_results (inbound_batch_id);
CREATE INDEX discharge_module_results_output ON public.discharge_module_results (output_batch_id);

CREATE TRIGGER trg_discharge_module_results_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.discharge_module_results
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.discharge_module_results ENABLE ROW LEVEL SECURITY;
CREATE POLICY "discharge_module_results select by permission" ON public.discharge_module_results
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.processing.view'::text, 'module.inbound.view'::text, 'module.output.view'::text]));
GRANT SELECT ON public.discharge_module_results TO authenticated;
REVOKE ALL ON public.discharge_module_results FROM anon;

-- db/tables/discharge_channel_assignments.sql
-- MES-5a-1(2026-10-08,规格 §3.1 "the mapping between discharge channel number and module number";MES-0 Q9;MES-5a Step 0 Q9,Tim):
--   【一炉放电里,哪个通道接的是哪个模组】—— 只追加。装机时记:这一炉(run_id)、这一批(inbound_batch_id XOR output_batch_id)、
--   通道号、模组(module_ref,与 discharge_module_results 同一个批内标识)。
--   【当前】= 没被更正、没被撤回、那一炉没回滚。同一炉一个通道只有一条当前的;同一炉同一批一个模组也只有一条当前的
--   (record 函数判,不在这里建部分唯一索引 —— "当前"要看更正链,是一个读出来的判断)。
--   手工录入可以不记通道(录入时把模组与通道一起写在结果里);设备送来的结果只认通道号 —— 那一天,一个没记过的通道在收件箱里
--   【看得见地失败】(那条规矩跟着设备转换器一起建;MES-5a-1 没有建转换器,见 discharge_module_results 的抬头)。
--   一条结果带了通道号、而这一炉这个通道当前记着另一个模组 → DISCHARGE_CHANNEL_MODULE_MISMATCH(两份记录不许各说各话)。
--   【更正】新行指回原行(corrects_id 唯一)+ 必填理由;withdrawn = 撤回这一条(通道空出来)。
--   只经 assign_discharge_channel / correct_discharge_channel(action.processing_aftercare)写;UPDATE / DELETE / TRUNCATE 语句级拒。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.discharge_channel_assignments (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id            uuid NOT NULL REFERENCES public.processing_runs (id),
    inbound_batch_id  uuid REFERENCES public.inbound_batches (id),
    output_batch_id   uuid REFERENCES public.output_batches (id),
    channel_no        integer NOT NULL CHECK (channel_no > 0),
    module_ref        text NOT NULL CHECK (btrim(module_ref) = module_ref AND module_ref <> '' AND length(module_ref) <= 60),
    withdrawn         boolean NOT NULL DEFAULT false,
    assigned_at       timestamptz NOT NULL DEFAULT now(),
    assigned_by       uuid DEFAULT auth.uid(),
    corrects_id       bigint UNIQUE REFERENCES public.discharge_channel_assignments (id),
    correction_reason text,
    CONSTRAINT discharge_channel_assignments_one_batch CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    CONSTRAINT discharge_channel_assignments_withdrawn_is_correction CHECK (NOT withdrawn OR corrects_id IS NOT NULL),
    CONSTRAINT discharge_channel_assignments_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> ''))
);

COMMENT ON TABLE public.discharge_channel_assignments IS
    'MES-5a-1:一炉放电的通道 → 模组(规格 §3.1),只追加。当前 = 没被更正、没被撤回、那一炉没回滚;同一炉一个通道、同一批一个模组各只有一条当前的。更正 = 新行(corrects_id + 理由),撤回 = 一条 withdrawn 的更正。手工录入可以不记;设备来的结果只认通道号(那条"没记的通道在收件箱里看得见地失败"跟着设备转换器一起建)。';

CREATE INDEX discharge_channel_assignments_run ON public.discharge_channel_assignments (run_id);

CREATE TRIGGER trg_discharge_channel_assignments_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.discharge_channel_assignments
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.discharge_channel_assignments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "discharge_channel_assignments select by permission" ON public.discharge_channel_assignments
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.processing.view'::text, 'module.inbound.view'::text, 'module.output.view'::text]));
GRANT SELECT ON public.discharge_channel_assignments TO authenticated;
REVOKE ALL ON public.discharge_channel_assignments FROM anon;

-- db/tables/discharge_module_splits.sql
-- MES-5a-1(2026-10-08,规格 §3.1 "re-discharge or quarantine, and both paths generate a record";MES-0 Q23;MES-5a Step 0 Q11,Tim):
--   【哪几个放电失败的模组被拆去隔离了,拆进了哪一批】—— 只追加,一个模组一行。
--   拆分本身是一张加工单(工序 discharge_quarantine_split,转化型:原批消耗拆出去的那几个模组称出来的重量,产出同一物料的一批,
--   带"带电未放电",放进隔离库位)—— 那张单记的是质量;这张表记的是【是哪几个模组】,那是加工单的腿记不下的。
--   一行 = 拆分那一炉(split_run_id)· 那个模组判失败的那一炉放电(discharge_run_id)· 原批(inbound_batch_id XOR output_batch_id)·
--   模组(module_ref)· 拆出来的那一批(new_output_batch_id)。
--   【当前】= 拆分那一炉没回滚 —— 回滚拆分那一炉,这几个模组就回到原批(核实跟着重算,discharge_verify_batch)。
--   核实时,拆出去的模组算"已处置",与当前的"通过"一起凑满原批的模组数(Q6)。
--   只经 split_failed_modules_to_quarantine(action.processing_aftercare;记那一炉还要 action.processing_commit)写;
--   UPDATE / DELETE / TRUNCATE 语句级拒。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.discharge_module_splits (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    split_run_id        uuid NOT NULL REFERENCES public.processing_runs (id),
    discharge_run_id    uuid NOT NULL REFERENCES public.processing_runs (id),
    inbound_batch_id    uuid REFERENCES public.inbound_batches (id),
    output_batch_id     uuid REFERENCES public.output_batches (id),
    module_ref          text NOT NULL CHECK (btrim(module_ref) = module_ref AND module_ref <> '' AND length(module_ref) <= 60),
    new_output_batch_id uuid NOT NULL REFERENCES public.output_batches (id),
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    CONSTRAINT discharge_module_splits_one_batch CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    CONSTRAINT discharge_module_splits_once_per_run UNIQUE (split_run_id, module_ref)
);

COMMENT ON TABLE public.discharge_module_splits IS
    'MES-5a-1:放电失败、处置为隔离的模组被拆去了哪一批(规格 §3.1 · MES-0 Q23)。拆分本身是一张 discharge_quarantine_split 加工单(记质量);这里记是哪几个模组。当前 = 拆分那一炉没回滚。核实时拆出去的模组算已处置。只经 split_failed_modules_to_quarantine 写。';

CREATE INDEX discharge_module_splits_inbound ON public.discharge_module_splits (inbound_batch_id);
CREATE INDEX discharge_module_splits_output ON public.discharge_module_splits (output_batch_id);

CREATE TRIGGER trg_discharge_module_splits_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.discharge_module_splits
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.discharge_module_splits ENABLE ROW LEVEL SECURITY;
CREATE POLICY "discharge_module_splits select by permission" ON public.discharge_module_splits
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.processing.view'::text, 'module.inbound.view'::text, 'module.output.view'::text]));
GRANT SELECT ON public.discharge_module_splits TO authenticated;
REVOKE ALL ON public.discharge_module_splits FROM anon;

-- 关系图例外:原批 ↔ 拆出来的那一批走拆分那一炉加工单(两跳),与进料批 ↔ 产出批不进图同一条裁定(fixture 103 A)。镜像原样。
INSERT INTO public.document_relation_exceptions (owner_table, column_a, column_b, reason) VALUES
    ('discharge_module_splits', 'inbound_batch_id', 'new_output_batch_id',
     'MES-5a-1:原批 → 拆去隔离的那一批,关系走拆分那一炉加工单(两跳),与进料批 ↔ 产出批不进图同一条裁定(SEARCH-4 ②)。'),
    ('discharge_module_splits', 'new_output_batch_id', 'output_batch_id',
     'MES-5a-1:同上 —— 原批是一批自产料时,原批 → 拆出来的那一批同样走拆分那一炉加工单。');

-- ── 7a · 四张新视图(镜像原样)—— 排在函数【之前】:discharge_verify_batch 用 discharge_batch_status_all%ROWTYPE,
--        迁移里 check_function_bodies 是开着的,声明在建函数那一刻就要解析(重建侧关着它,所以那边看不见这个先后)──────

-- db/views/discharge_module_current_all.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23;MES-5a Step 0 Q6 · Q12,Tim):【每一批的每一个模组,此刻的放电结论】—— 一个模组一行。
--   当前 = 没被更正、所在的那一炉没回滚;最新 = 同一批同一个模组的当前行里判定时刻最晚的那一条(再按 id —— 同刻时记得晚的赢)。
--   attempts = 这个模组的当前结果条数(一炉一条;更正不算新的一次),redischarge_count = attempts − 1。
--   split_out = 这个模组被拆去隔离了(拆分那一炉没回滚),带出拆进的那一批。
--   属主视图、EXECUTE / SELECT 不给 authenticated:读者经 discharge_module_rows(带门);核实(discharge_verify_batch)与提醒臂读它。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE VIEW public.discharge_module_current_all WITH (security_invoker = off) AS
 WITH cur AS (
         SELECT r.id,
            r.run_id,
            r.inbound_batch_id,
            r.output_batch_id,
                CASE
                    WHEN r.inbound_batch_id IS NOT NULL THEN 'inbound'::text
                    ELSE 'output'::text
                END AS batch_kind,
            COALESCE(r.inbound_batch_id, r.output_batch_id) AS batch_id,
            r.module_ref,
            r.channel_no,
            r.outlet_voltage_v,
            r.verdict,
            r.verdict_at,
            r.disposition,
            r.pass_voltage_v_at,
            r.contradicts_pass_voltage,
            row_number() OVER (PARTITION BY (COALESCE(r.inbound_batch_id, r.output_batch_id)), r.module_ref ORDER BY r.verdict_at DESC, r.id DESC) AS rn,
            count(*) OVER (PARTITION BY (COALESCE(r.inbound_batch_id, r.output_batch_id)), r.module_ref) AS attempts
           FROM discharge_module_results r
             JOIN processing_runs pr ON pr.id = r.run_id
          WHERE pr.status = 'committed'::text AND pr.deleted_at IS NULL AND NOT (EXISTS ( SELECT 1
                   FROM discharge_module_results x
                  WHERE x.corrects_id = r.id))
        )
 SELECT c.batch_kind,
    c.batch_id,
    c.module_ref,
    c.id AS result_id,
    c.run_id,
    c.channel_no,
    c.outlet_voltage_v,
    c.verdict,
    c.verdict_at,
    c.disposition,
    c.pass_voltage_v_at,
    c.contradicts_pass_voltage,
    c.attempts,
    c.attempts - 1 AS redischarge_count,
    sp.split_run_id IS NOT NULL AS split_out,
    sp.split_run_id,
    sp.new_output_batch_id
   FROM cur c
     LEFT JOIN LATERAL ( SELECT s.split_run_id,
            s.new_output_batch_id
           FROM discharge_module_splits s
             JOIN processing_runs sr ON sr.id = s.split_run_id
          WHERE COALESCE(s.inbound_batch_id, s.output_batch_id) = c.batch_id AND s.module_ref = c.module_ref AND sr.status = 'committed'::text AND sr.deleted_at IS NULL
          ORDER BY s.id DESC
         LIMIT 1) sp ON true
  WHERE c.rn = 1;

REVOKE ALL ON public.discharge_module_current_all FROM PUBLIC, anon, authenticated;

-- db/views/discharge_batch_status_all.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23 · Q24;MES-5a Step 0 Q4–Q6 · Q18,Tim):【一批料的放电核实到哪儿了】—— 一批一行。
--   只列"放电跟它有关"的批:记了模组数,或有放电结果,或做过一炉 verifies_by_unit 的工序的投料。
--   计数(都只数【当前最新】的结论,discharge_module_current_all):
--     modules_recorded  有结论的模组数(含拆出去的)
--     passed            最新一条是通过、没被拆走
--     failed_redischarge 最新一条是失败、处置再放电、没被拆走
--     failed_quarantine  最新一条是失败、处置隔离、还没拆走(提醒臂 discharge_quarantine_pending 的那一类)
--     split_out          已拆去隔离
--     contradictions     最新一条与 V9 矛盾(只标出)
--   rule_verified = 记了模组数,并且 通过 + 拆走 = 模组数(Q6)—— 那是"这一批该是已放电并核实"的唯一一份判据;
--     discharge_verify_batch 照它改状态,提醒臂 discharge_unverified 照它列。部分放电(只放了几个模组)永远凑不满 —— P1 就此关掉。
--   currently_verified = 这一批此刻开着那道工序的结果状态(deep_discharge → discharged_verified)。
--   latest_run_* = 这一批做过的、没回滚的、最晚的那一炉 verifies_by_unit 工序(核实改状态时记的就是它)。
--   属主视图,不给 authenticated:读者经 discharge_batch_status(带门)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE VIEW public.discharge_batch_status_all WITH (security_invoker = off) AS
 WITH b AS (
         SELECT 'inbound'::text AS batch_kind,
            ib.id AS batch_id,
            ib.code AS batch_code,
            ib.material_id,
            ib.module_count
           FROM inbound_batches ib
          WHERE ib.deleted_at IS NULL
        UNION ALL
         SELECT 'output'::text AS batch_kind,
            ob.id AS batch_id,
            ob.code AS batch_code,
            ob.material_id,
            ob.module_count
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL
        ), runs AS (
         SELECT COALESCE(pi.inbound_batch_id, pi.output_batch_id) AS batch_id,
            pr.id AS run_id,
            pr.code AS run_code,
            pr.process_date,
            ot.resulting_safety_state_code AS result_state,
            row_number() OVER (PARTITION BY (COALESCE(pi.inbound_batch_id, pi.output_batch_id)) ORDER BY pr.process_date DESC, pr.started_at DESC NULLS LAST, pr.code DESC) AS rn
           FROM processing_inputs pi
             JOIN processing_runs pr ON pr.id = pi.run_id
             JOIN operation_types ot ON ot.code = pr.operation_type_code
          WHERE ot.verifies_by_unit AND pr.status = 'committed'::text AND pr.deleted_at IS NULL
        ), m AS (
         SELECT c.batch_id,
            count(*) AS modules_recorded,
            count(*) FILTER (WHERE NOT c.split_out AND c.verdict = 'pass'::text) AS passed,
            count(*) FILTER (WHERE NOT c.split_out AND c.verdict = 'fail'::text AND c.disposition = 're_discharge'::text) AS failed_redischarge,
            count(*) FILTER (WHERE NOT c.split_out AND c.verdict = 'fail'::text AND c.disposition = 'quarantine'::text) AS failed_quarantine,
            count(*) FILTER (WHERE c.split_out) AS split_out,
            count(*) FILTER (WHERE c.contradicts_pass_voltage) AS contradictions
           FROM discharge_module_current_all c
          GROUP BY c.batch_id
        )
 SELECT b.batch_kind,
    b.batch_id,
    b.batch_code,
    b.material_id,
    b.module_count,
    COALESCE(m.modules_recorded, 0::bigint) AS modules_recorded,
    COALESCE(m.passed, 0::bigint) AS passed,
    COALESCE(m.failed_redischarge, 0::bigint) AS failed_redischarge,
    COALESCE(m.failed_quarantine, 0::bigint) AS failed_quarantine,
    COALESCE(m.split_out, 0::bigint) AS split_out,
    COALESCE(m.contradictions, 0::bigint) AS contradictions,
    b.module_count IS NOT NULL AND (COALESCE(m.passed, 0::bigint) + COALESCE(m.split_out, 0::bigint)) = b.module_count AS rule_verified,
    r.run_id AS latest_run_id,
    r.run_code AS latest_run_code,
    r.process_date AS latest_run_date,
    COALESCE(r.result_state, ( SELECT ot.resulting_safety_state_code
           FROM operation_types ot
          WHERE ot.verifies_by_unit
          ORDER BY ot.code
         LIMIT 1)) AS result_state,
        CASE
            WHEN b.batch_kind = 'inbound'::text THEN (EXISTS ( SELECT 1
               FROM inbound_batch_safety_states s
              WHERE s.inbound_batch_id = b.batch_id AND s.ended_at IS NULL AND s.safety_state_code = COALESCE(r.result_state, ( SELECT ot.resulting_safety_state_code
                       FROM operation_types ot
                      WHERE ot.verifies_by_unit
                      ORDER BY ot.code
                     LIMIT 1))))
            ELSE (EXISTS ( SELECT 1
               FROM output_batch_safety_states s
              WHERE s.output_batch_id = b.batch_id AND s.ended_at IS NULL AND s.safety_state_code = COALESCE(r.result_state, ( SELECT ot.resulting_safety_state_code
                       FROM operation_types ot
                      WHERE ot.verifies_by_unit
                      ORDER BY ot.code
                     LIMIT 1))))
        END AS currently_verified
   FROM b
     LEFT JOIN m ON m.batch_id = b.batch_id
     LEFT JOIN runs r ON r.batch_id = b.batch_id AND r.rn = 1
  WHERE b.module_count IS NOT NULL OR m.batch_id IS NOT NULL OR r.run_id IS NOT NULL;

REVOKE ALL ON public.discharge_batch_status_all FROM PUBLIC, anon, authenticated;

-- db/views/discharge_module_rows.sql
-- MES-5a-1(2026-10-08,MES-5a Step 0 Q7 · Q13,Tim):【一条一条的放电模组结果,带上它的那一炉与那一批】—— 带门的属主视图。
--   放电那一炉的页面(模组结果面板)与两种批次页读它。门:加工、进料或产出查看码任一(与三张放电表的读规则同一个)。
--   【为什么是属主视图】只持进料或产出码的人读不到 processing_runs(加工码),一张 invoker 视图把它们 join 起来会安静地丢掉每一行
--   (AGENTS.md 的 xmodule)。借过去的只有那一炉的单号、加工日与是否回滚 —— 一个显示标签与它本来就挂着的事实。
--   is_current:没有被别的行更正过、那一炉没回滚;is_latest:这个模组此刻的结论就是这一条(discharge_module_current_all);
--   split_out:这个模组被拆去隔离了。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE VIEW public.discharge_module_rows WITH (security_invoker = off) AS
 SELECT d.id,
    d.run_id,
    r.code AS run_code,
    r.process_date,
    r.status AS run_status,
        CASE
            WHEN d.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    COALESCE(d.inbound_batch_id, d.output_batch_id) AS batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
    d.module_ref,
    d.channel_no,
    d.outlet_voltage_v,
    d.start_voltage_v,
    d.verdict,
    d.verdict_at,
    d.disposition,
    d.duration_min,
    d.energy_recovered_wh,
    d.pass_voltage_v_at,
    d.contradicts_pass_voltage,
    d.photo_path,
    d.notes,
    d.source,
    d.device_id,
    d.recorded_at,
    d.recorded_by,
    d.corrects_id,
    d.correction_reason,
    r.status = 'committed'::text AND r.deleted_at IS NULL AND NOT (EXISTS ( SELECT 1
           FROM discharge_module_results x
          WHERE x.corrects_id = d.id)) AS is_current,
    (EXISTS ( SELECT 1
           FROM discharge_module_current_all c
          WHERE c.result_id = d.id)) AS is_latest,
    COALESCE(( SELECT c.split_out
           FROM discharge_module_current_all c
          WHERE c.batch_id = COALESCE(d.inbound_batch_id, d.output_batch_id) AND c.module_ref = d.module_ref), false) AS split_out
   FROM discharge_module_results d
     JOIN processing_runs r ON r.id = d.run_id
     LEFT JOIN inbound_batches ib ON ib.id = d.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = d.output_batch_id
  WHERE has_any_permission(ARRAY['module.processing.view'::text, 'module.inbound.view'::text, 'module.output.view'::text]);

COMMENT ON VIEW public.discharge_module_rows IS
    'MES-5a-1:放电模组结果逐条,带那一炉的单号 / 加工日 / 状态与那一批的批号;is_current = 链的末端且那一炉没回滚,is_latest = 这个模组此刻的结论,split_out = 已拆去隔离。带门(加工、进料或产出查看码)的属主视图。';

GRANT SELECT ON public.discharge_module_rows TO authenticated;
REVOKE ALL ON public.discharge_module_rows FROM anon;

-- db/views/discharge_status_by_batch.sql
-- MES-5a-1(2026-10-08,MES-5a Step 0 Q6 · Q13,Tim):【一批料的放电核实到哪儿了】—— discharge_batch_status_all 的带门读法。
--   【名字为什么不叫 discharge_batch_status】视图的重放顺序(check_mirrors.view_replay_order)按"引用了几张别的视图"排、同数按文件名 ——
--   它不是真的拓扑排序,一张引用了一张、而被引用的那张自己也引用了一张的视图会与它打平,文件名靠前就先建、当场报"不存在"。
--   取一个排在 discharge_batch_status_all 后面的名字,而不是在这一刀里改门的工具(记在 docs/known-issues.md)。
--   门:加工、进料或产出查看码任一。放电那一炉的页面、两种批次页与新建加工单表单读它("n 个模组里核实了几个")。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE VIEW public.discharge_status_by_batch WITH (security_invoker = off) AS
 SELECT s.batch_kind,
    s.batch_id,
    s.batch_code,
    s.material_id,
    s.module_count,
    s.modules_recorded,
    s.passed,
    s.failed_redischarge,
    s.failed_quarantine,
    s.split_out,
    s.contradictions,
    s.rule_verified,
    s.latest_run_id,
    s.latest_run_code,
    s.latest_run_date,
    s.result_state,
    s.currently_verified
   FROM discharge_batch_status_all s
  WHERE has_any_permission(ARRAY['module.processing.view'::text, 'module.inbound.view'::text, 'module.output.view'::text]);

COMMENT ON VIEW public.discharge_status_by_batch IS
    'MES-5a-1:一批料的放电核实进度(模组数、通过、待再放电、待拆去隔离、已拆走、与 V9 矛盾的条数、按规则是否已核实、此刻是否开着结果状态)。带门(加工、进料或产出查看码)的属主视图。';

GRANT SELECT ON public.discharge_status_by_batch TO authenticated;
REVOKE ALL ON public.discharge_status_by_batch FROM anon;

-- ── 7 · 新函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/set_batch_module_count.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-5a Step 0 Q4,Tim):【在批次页上补或改一批的模组数】—— 进料批与产出批共用这一扇门。
--   p_kind:'inbound' | 'output'(BATCH_KIND_UNKNOWN)。码:批次那个模块的编辑码,或 action.processing_commit(放电站台的操作员);
--   都没有 → PERMISSION_DENIED|<模块编辑码>。p_count 为空 = 清掉;≤ 0 → MODULE_COUNT_INVALID|<值>。批次不在或已注销 → BATCH_NOT_FOUND。
--   适用性、下限与锁由表上的 guard_batch_module_count 判(同一份判据,直连 SQL 也过它)—— 这里一个字都不重复。
--   与原值相同 → 什么都不写。改了之后照规则重判一次核实(数改小可能刚好凑满;discharge_verify_batch)。返回批号。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.set_batch_module_count(p_kind text, p_batch_id uuid, p_count integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch   text;
    v_current integer;
BEGIN
    IF p_kind = 'inbound' THEN
        IF NOT has_any_permission(ARRAY['module.inbound.edit', 'action.processing_commit']) THEN
            RAISE EXCEPTION 'PERMISSION_DENIED|module.inbound.edit';
        END IF;
    ELSIF p_kind = 'output' THEN
        IF NOT has_any_permission(ARRAY['module.output.edit', 'action.processing_commit']) THEN
            RAISE EXCEPTION 'PERMISSION_DENIED|module.output.edit';
        END IF;
    ELSE
        RAISE EXCEPTION 'BATCH_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;
    IF p_count IS NOT NULL AND p_count <= 0 THEN
        RAISE EXCEPTION 'MODULE_COUNT_INVALID|%', p_count;
    END IF;

    IF p_kind = 'inbound' THEN
        SELECT b.code, b.module_count INTO v_batch, v_current
          FROM inbound_batches b WHERE b.id = p_batch_id AND b.deleted_at IS NULL FOR UPDATE;
    ELSE
        SELECT b.code, b.module_count INTO v_batch, v_current
          FROM output_batches b WHERE b.id = p_batch_id AND b.deleted_at IS NULL FOR UPDATE;
    END IF;
    IF v_batch IS NULL THEN
        RAISE EXCEPTION 'BATCH_NOT_FOUND|%', p_batch_id;
    END IF;
    IF v_current IS NOT DISTINCT FROM p_count THEN
        RETURN v_batch;
    END IF;

    IF p_kind = 'inbound' THEN
        UPDATE inbound_batches SET module_count = p_count, updated_by = auth.uid(), updated_at = now() WHERE id = p_batch_id;
    ELSE
        UPDATE output_batches SET module_count = p_count, updated_by = auth.uid(), updated_at = now() WHERE id = p_batch_id;
    END IF;
    PERFORM discharge_verify_batch(p_kind, p_batch_id,
        (SELECT s.latest_run_id FROM discharge_batch_status_all s WHERE s.batch_id = p_batch_id),
        'module count set to ' || COALESCE(p_count::text, 'none'));
    RETURN v_batch;
END;
$function$;

-- db/functions/discharge_verify_batch.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23 · Q24;MES-5a Step 0 Q5 · Q6,Tim):【让一批的安全状态与它的逐模组结论对上】—— 内层,唯一一处按结果改状态。
--   判据只有一份:discharge_batch_status_all.rule_verified(记了模组数,并且 当前最新为通过 + 已拆去隔离 = 模组数)。
--   ① 这一批还没有任何结论(没有当前结果、没有拆分)→ 什么都不做:结果还没开始管它(一批在 MES-5a-1 之前就核实过的料不被碰)。
--   ② 规则成立 → 结束这道工序【解决】的那几个状态(带电未放电),写上结果状态(已放电并核实),都记 p_run_id 做到的(created_by_run_id /
--      ended_by_run_id)—— 状态史与回滚照旧:回滚那一炉,它写的结束、它结束的重开(rollback_processing_run_internal)。
--   ③ 规则不成立而结果状态开着(一条更正把通过改成了失败、一炉被回滚、模组数改大了)→ 结束结果状态,重开被它解决的那个状态。
--      【安全的一侧】:一条失败的结论说这个模组没放完电,火闸就必须重新拦住这一批。
--   p_run_id 可以为空(回滚之后重判时,这一批已经没有一炉没回滚的放电了);p_note 写进结束理由。返回此刻是否开着结果状态。
--   不是 DEFINER:只被几支 DEFINER 函数调用(记 / 更正结果、改模组数、拆分、回滚);EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.discharge_verify_batch(p_kind text, p_batch_id uuid, p_run_id uuid, p_note text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s       discharge_batch_status_all%ROWTYPE;
    v_op      text;
    v_resolve text[];
    v_code    text;
    v_why     text;
BEGIN
    SELECT * INTO v_s FROM discharge_batch_status_all s WHERE s.batch_id = p_batch_id;
    IF NOT FOUND OR v_s.modules_recorded = 0 OR v_s.result_state IS NULL THEN
        RETURN COALESCE(v_s.currently_verified, false);
    END IF;

    SELECT ot.code INTO v_op FROM operation_types ot
     WHERE ot.verifies_by_unit AND ot.resulting_safety_state_code = v_s.result_state ORDER BY ot.code LIMIT 1;
    SELECT array_agg(a.safety_state_code ORDER BY a.safety_state_code) INTO v_resolve
      FROM operation_type_safety_states a WHERE a.operation_type_code = v_op AND a.resolves;
    v_code := (SELECT pr.code FROM processing_runs pr WHERE pr.id = p_run_id);
    v_why := COALESCE(NULLIF(btrim(COALESCE(p_note, '')), ''), '');

    IF v_s.rule_verified THEN
        IF v_s.currently_verified THEN
            RETURN true;
        END IF;
        IF p_kind = 'inbound' THEN
            UPDATE inbound_batch_safety_states s
               SET ended_at = now(), ended_by = auth.uid(), ended_by_run_id = p_run_id,
                   end_reason = 'verified by module results' || COALESCE(' (' || v_code || ')', '') || CASE WHEN v_why <> '' THEN ': ' || v_why ELSE '' END
             WHERE s.inbound_batch_id = p_batch_id AND s.ended_at IS NULL AND s.safety_state_code = ANY (COALESCE(v_resolve, ARRAY[]::text[]));
            INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code, created_by_run_id)
            VALUES (p_batch_id, v_s.result_state, p_run_id)
            ON CONFLICT (inbound_batch_id, safety_state_code) WHERE ended_at IS NULL DO NOTHING;
        ELSE
            UPDATE output_batch_safety_states s
               SET ended_at = now(), ended_by = auth.uid(), ended_by_run_id = p_run_id,
                   end_reason = 'verified by module results' || COALESCE(' (' || v_code || ')', '') || CASE WHEN v_why <> '' THEN ': ' || v_why ELSE '' END
             WHERE s.output_batch_id = p_batch_id AND s.ended_at IS NULL AND s.safety_state_code = ANY (COALESCE(v_resolve, ARRAY[]::text[]));
            INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code, created_by_run_id)
            VALUES (p_batch_id, v_s.result_state, p_run_id)
            ON CONFLICT (output_batch_id, safety_state_code) WHERE ended_at IS NULL DO NOTHING;
        END IF;
        RETURN true;
    END IF;

    IF NOT v_s.currently_verified THEN
        RETURN false;
    END IF;
    IF p_kind = 'inbound' THEN
        UPDATE inbound_batch_safety_states s
           SET ended_at = now(), ended_by = auth.uid(), ended_by_run_id = p_run_id,
               end_reason = 'module results no longer verify this batch' || COALESCE(' (' || v_code || ')', '') || CASE WHEN v_why <> '' THEN ': ' || v_why ELSE '' END
         WHERE s.inbound_batch_id = p_batch_id AND s.ended_at IS NULL AND s.safety_state_code = v_s.result_state;
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code, created_by_run_id)
        SELECT p_batch_id, x, p_run_id FROM unnest(COALESCE(v_resolve, ARRAY[]::text[])) x
        ON CONFLICT (inbound_batch_id, safety_state_code) WHERE ended_at IS NULL DO NOTHING;
    ELSE
        UPDATE output_batch_safety_states s
           SET ended_at = now(), ended_by = auth.uid(), ended_by_run_id = p_run_id,
               end_reason = 'module results no longer verify this batch' || COALESCE(' (' || v_code || ')', '') || CASE WHEN v_why <> '' THEN ': ' || v_why ELSE '' END
         WHERE s.output_batch_id = p_batch_id AND s.ended_at IS NULL AND s.safety_state_code = v_s.result_state;
        INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code, created_by_run_id)
        SELECT p_batch_id, x, p_run_id FROM unnest(COALESCE(v_resolve, ARRAY[]::text[])) x
        ON CONFLICT (output_batch_id, safety_state_code) WHERE ended_at IS NULL DO NOTHING;
    END IF;
    RETURN false;
END;
$function$;

-- db/functions/discharge_result_internal.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23 · Q25;MES-5a Step 0 Q3–Q9 · Q12,Tim):【一条放电模组结果的判据与落库】—— 记与更正共用这一份。
--   内层:不是 DEFINER,authenticated 调不到(只经 record_discharge_module_result / correct_discharge_module_result)。
--   p_corrects_id 为空 = 记一条新的;不为空 = 更正那一条(那一炉、那一批、那个模组从原行来,不许换;理由必填)。
--   拒(按这个先后):
--     RUN_NOT_COMMITTED|<单>                          加工单没提交或已回滚
--     DISCHARGE_RUN_NOT_BY_UNIT|<单>|<工序>            这一炉的工序不按逐件结果核实(verifies_by_unit 为假)
--     BATCH_KIND_UNKNOWN|<种类> · DISCHARGE_BATCH_NOT_INPUT|<单>   这一批不是这一炉的投料
--     BATCH_MODULE_COUNT_REQUIRED|<批号>               这一批还没记模组数(Q4:记第一条结果之前必须有)
--     DISCHARGE_MODULE_REF_REQUIRED                    模组标识为空(或超过 60 个字)
--     DISCHARGE_MODULE_SPLIT_OUT|<模组>|<拆进的那一批>   这个模组已经被拆去隔离了 —— 它的结论记在那一批上
--     DISCHARGE_RESULT_ALREADY_RECORDED|<模组>|<单>     这一炉已经记过这个模组(要改就更正那一条)
--     DISCHARGE_MODULES_EXCEED_COUNT|<批号>|<模组数>     又一个新模组会超过这一批的模组数(Q6)
--     DISCHARGE_VERDICT_UNKNOWN|<判定> · DISCHARGE_DISPOSITION_REQUIRED|<模组>(判失败必须说再放电还是隔离)·
--     DISCHARGE_DISPOSITION_ON_PASS|<模组> · DISCHARGE_DISPOSITION_UNKNOWN|<处置>
--     DISCHARGE_VOLTAGE_INVALID                        出口电压为空或为负
--     DISCHARGE_VERDICT_AT_REQUIRED · DISCHARGE_VERDICT_IN_FUTURE · DISCHARGE_VERDICT_BEFORE_RUN|<单>
--     DISCHARGE_VALUE_INVALID|<字段>                    起始电压 / 时长 / 回收能量为负,或通道号不是正数
--     DISCHARGE_CHANNEL_MODULE_MISMATCH|<通道>|<当前记着的模组>   这一炉这个通道当前记着另一个模组
--     DISCHARGE_DEVICE_INVALID|<设备>                   给了设备却不是一台没停用的放电柜
--     更正:DISCHARGE_RESULT_NOT_FOUND|<id> · DISCHARGE_RESULT_SUPERSEDED|<id>(已被更正过 —— 更正链的末端)·
--           DISCHARGE_CORRECTION_REASON_REQUIRED · DISCHARGE_CORRECTION_SAME_VALUE(什么都没改)
--   V9(这一批物料的 discharge_pass_voltage_v)此刻的值抄进 pass_voltage_v_at;矛盾只标出(生成列),从不拒。来源 = manual。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.discharge_result_internal(p_run_id uuid, p_kind text, p_batch_id uuid, p_module_ref text, p_outlet_voltage_v numeric, p_verdict text, p_verdict_at timestamp with time zone, p_disposition text, p_channel_no integer, p_start_voltage_v numeric, p_duration_min numeric, p_energy_recovered_wh numeric, p_device_id uuid, p_photo_path text, p_notes text, p_corrects_id bigint, p_correction_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig     discharge_module_results%ROWTYPE;
    v_run      processing_runs%ROWTYPE;
    v_by_unit  boolean;
    v_kind     text := p_kind;
    v_batch    uuid := p_batch_id;
    v_ref      text := NULLIF(btrim(COALESCE(p_module_ref, '')), '');
    v_code     text;
    v_count    integer;
    v_material uuid;
    v_pass     numeric;
    v_cur      record;
    v_n        bigint;
    v_assigned text;
    v_disp     text := NULLIF(btrim(COALESCE(p_disposition, '')), '');
    v_id       bigint;
BEGIN
    IF p_corrects_id IS NOT NULL THEN
        SELECT * INTO v_orig FROM discharge_module_results WHERE id = p_corrects_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'DISCHARGE_RESULT_NOT_FOUND|%', p_corrects_id;
        END IF;
        IF EXISTS (SELECT 1 FROM discharge_module_results x WHERE x.corrects_id = p_corrects_id) THEN
            RAISE EXCEPTION 'DISCHARGE_RESULT_SUPERSEDED|%', p_corrects_id
              USING HINT = '这一条已经被更正过 —— 要再改,改链的末端那一条。';
        END IF;
        IF NULLIF(btrim(COALESCE(p_correction_reason, '')), '') IS NULL THEN
            RAISE EXCEPTION 'DISCHARGE_CORRECTION_REASON_REQUIRED';
        END IF;
        v_kind := CASE WHEN v_orig.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END;
        v_batch := COALESCE(v_orig.inbound_batch_id, v_orig.output_batch_id);
        v_ref := v_orig.module_ref;
    END IF;

    SELECT * INTO v_run FROM processing_runs WHERE id = COALESCE(v_orig.run_id, p_run_id);
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, COALESCE(p_run_id::text, '?'));
    END IF;
    SELECT ot.verifies_by_unit INTO v_by_unit FROM operation_types ot WHERE ot.code = v_run.operation_type_code;
    IF v_by_unit IS NOT TRUE THEN
        RAISE EXCEPTION 'DISCHARGE_RUN_NOT_BY_UNIT|%|%', v_run.code, COALESCE(v_run.operation_type_code, '?');
    END IF;

    IF v_kind = 'inbound' THEN
        SELECT b.code, b.module_count, b.material_id INTO v_code, v_count, v_material
          FROM inbound_batches b WHERE b.id = v_batch AND b.deleted_at IS NULL;
        IF NOT EXISTS (SELECT 1 FROM processing_inputs pi WHERE pi.run_id = v_run.id AND pi.inbound_batch_id = v_batch) THEN
            RAISE EXCEPTION 'DISCHARGE_BATCH_NOT_INPUT|%', v_run.code;
        END IF;
    ELSIF v_kind = 'output' THEN
        SELECT b.code, b.module_count, b.material_id INTO v_code, v_count, v_material
          FROM output_batches b WHERE b.id = v_batch AND b.deleted_at IS NULL;
        IF NOT EXISTS (SELECT 1 FROM processing_inputs pi WHERE pi.run_id = v_run.id AND pi.output_batch_id = v_batch) THEN
            RAISE EXCEPTION 'DISCHARGE_BATCH_NOT_INPUT|%', v_run.code;
        END IF;
    ELSE
        RAISE EXCEPTION 'BATCH_KIND_UNKNOWN|%', COALESCE(v_kind, '?');
    END IF;
    IF v_count IS NULL THEN
        RAISE EXCEPTION 'BATCH_MODULE_COUNT_REQUIRED|%', v_code
          USING HINT = '先在批次页上记下这一批有几个模组 —— 核实要每一个模组都有结论,没有总数就无从判"每一个"。';
    END IF;
    IF v_ref IS NULL OR length(v_ref) > 60 THEN
        RAISE EXCEPTION 'DISCHARGE_MODULE_REF_REQUIRED';
    END IF;

    SELECT * INTO v_cur FROM discharge_module_current_all c WHERE c.batch_id = v_batch AND c.module_ref = v_ref;
    IF FOUND AND v_cur.split_out THEN
        RAISE EXCEPTION 'DISCHARGE_MODULE_SPLIT_OUT|%|%', v_ref,
            COALESCE((SELECT ob.code FROM output_batches ob WHERE ob.id = v_cur.new_output_batch_id), '?');
    END IF;
    IF p_corrects_id IS NULL THEN
        IF EXISTS (SELECT 1 FROM discharge_module_results r
                    WHERE r.run_id = v_run.id AND COALESCE(r.inbound_batch_id, r.output_batch_id) = v_batch
                      AND r.module_ref = v_ref AND r.corrects_id IS NULL) THEN
            RAISE EXCEPTION 'DISCHARGE_RESULT_ALREADY_RECORDED|%|%', v_ref, v_run.code
              USING HINT = '这一炉已经记过这个模组 —— 要改,在那一条上更正(带理由)。再放一次电是另一炉。';
        END IF;
        IF v_cur.module_ref IS NULL THEN
            SELECT count(*) INTO v_n FROM discharge_module_current_all c WHERE c.batch_id = v_batch;
            IF v_n >= v_count THEN
                RAISE EXCEPTION 'DISCHARGE_MODULES_EXCEED_COUNT|%|%', v_code, v_count
                  USING HINT = '这一批记着这么多个模组,而它们都已经有结论了 —— 这一个是多出来的。模组数记错了就先在批次页上改它。';
            END IF;
        END IF;
    END IF;

    IF p_verdict IS NULL OR p_verdict NOT IN ('pass', 'fail') THEN
        RAISE EXCEPTION 'DISCHARGE_VERDICT_UNKNOWN|%', COALESCE(p_verdict, '?');
    END IF;
    IF p_verdict = 'fail' AND v_disp IS NULL THEN
        RAISE EXCEPTION 'DISCHARGE_DISPOSITION_REQUIRED|%', v_ref
          USING HINT = '一个没放完电的模组必须说出去处:再放一次电,或拆去隔离(规格 §3.1:两条路都要留下记录)。';
    END IF;
    IF p_verdict = 'pass' AND v_disp IS NOT NULL THEN
        RAISE EXCEPTION 'DISCHARGE_DISPOSITION_ON_PASS|%', v_ref;
    END IF;
    IF v_disp IS NOT NULL AND v_disp NOT IN ('re_discharge', 'quarantine') THEN
        RAISE EXCEPTION 'DISCHARGE_DISPOSITION_UNKNOWN|%', v_disp;
    END IF;
    IF p_outlet_voltage_v IS NULL OR p_outlet_voltage_v < 0 THEN
        RAISE EXCEPTION 'DISCHARGE_VOLTAGE_INVALID';
    END IF;
    IF p_verdict_at IS NULL THEN
        RAISE EXCEPTION 'DISCHARGE_VERDICT_AT_REQUIRED';
    END IF;
    IF p_verdict_at > now() THEN
        RAISE EXCEPTION 'DISCHARGE_VERDICT_IN_FUTURE';
    END IF;
    IF v_run.started_at IS NOT NULL AND p_verdict_at < v_run.started_at THEN
        RAISE EXCEPTION 'DISCHARGE_VERDICT_BEFORE_RUN|%', v_run.code;
    END IF;
    IF p_start_voltage_v IS NOT NULL AND p_start_voltage_v < 0 THEN
        RAISE EXCEPTION 'DISCHARGE_VALUE_INVALID|start_voltage_v';
    END IF;
    IF p_duration_min IS NOT NULL AND p_duration_min < 0 THEN
        RAISE EXCEPTION 'DISCHARGE_VALUE_INVALID|duration_min';
    END IF;
    IF p_energy_recovered_wh IS NOT NULL AND p_energy_recovered_wh < 0 THEN
        RAISE EXCEPTION 'DISCHARGE_VALUE_INVALID|energy_recovered_wh';
    END IF;
    IF p_channel_no IS NOT NULL AND p_channel_no <= 0 THEN
        RAISE EXCEPTION 'DISCHARGE_VALUE_INVALID|channel_no';
    END IF;
    IF p_channel_no IS NOT NULL THEN
        SELECT a.module_ref INTO v_assigned
          FROM discharge_channel_assignments a
         WHERE a.run_id = v_run.id AND a.channel_no = p_channel_no AND NOT a.withdrawn
           AND NOT EXISTS (SELECT 1 FROM discharge_channel_assignments x WHERE x.corrects_id = a.id)
         ORDER BY a.id DESC LIMIT 1;
        IF v_assigned IS NOT NULL AND v_assigned <> v_ref THEN
            RAISE EXCEPTION 'DISCHARGE_CHANNEL_MODULE_MISMATCH|%|%', p_channel_no, v_assigned
              USING HINT = '这一炉这个通道记着另一个模组 —— 两份记录不能各说各话。先更正通道的分配,或改这一条的通道号。';
        END IF;
    END IF;
    IF p_device_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM devices d WHERE d.id = p_device_id AND d.retired_at IS NULL AND d.kind = 'discharge_cabinet') THEN
        RAISE EXCEPTION 'DISCHARGE_DEVICE_INVALID|%', p_device_id;
    END IF;

    IF p_corrects_id IS NOT NULL
       AND v_orig.outlet_voltage_v = p_outlet_voltage_v AND v_orig.verdict = p_verdict
       AND v_orig.verdict_at = p_verdict_at AND v_orig.disposition IS NOT DISTINCT FROM v_disp
       AND v_orig.channel_no IS NOT DISTINCT FROM p_channel_no AND v_orig.start_voltage_v IS NOT DISTINCT FROM p_start_voltage_v
       AND v_orig.duration_min IS NOT DISTINCT FROM p_duration_min AND v_orig.energy_recovered_wh IS NOT DISTINCT FROM p_energy_recovered_wh
       AND v_orig.device_id IS NOT DISTINCT FROM p_device_id
       AND v_orig.photo_path IS NOT DISTINCT FROM NULLIF(btrim(COALESCE(p_photo_path, '')), '')
       AND v_orig.notes IS NOT DISTINCT FROM NULLIF(btrim(COALESCE(p_notes, '')), '') THEN
        RAISE EXCEPTION 'DISCHARGE_CORRECTION_SAME_VALUE';
    END IF;

    SELECT m.discharge_pass_voltage_v INTO v_pass FROM materials m WHERE m.id = v_material;

    INSERT INTO discharge_module_results (run_id, inbound_batch_id, output_batch_id, module_ref, channel_no, outlet_voltage_v,
                                          start_voltage_v, verdict, verdict_at, disposition, duration_min, energy_recovered_wh,
                                          pass_voltage_v_at, photo_path, notes, source, device_id, corrects_id, correction_reason)
    VALUES (v_run.id,
            CASE WHEN v_kind = 'inbound' THEN v_batch END,
            CASE WHEN v_kind = 'output' THEN v_batch END,
            v_ref, p_channel_no, p_outlet_voltage_v, p_start_voltage_v, p_verdict, p_verdict_at, v_disp,
            p_duration_min, p_energy_recovered_wh, v_pass,
            NULLIF(btrim(COALESCE(p_photo_path, '')), ''), NULLIF(btrim(COALESCE(p_notes, '')), ''),
            'manual', p_device_id, p_corrects_id, NULLIF(btrim(COALESCE(p_correction_reason, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/record_discharge_module_result.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q25;MES-5a Step 0 Q7 · Q10,Tim):【记一个模组这一炉的放电结果】—— 手工录入(来源 manual)。
--   码:action.confirm_capture(采集那条管道的码 —— 现场的人读放电柜的屏幕记下来;MES-5a Step 0 Q10)。
--   判据都在 discharge_result_internal;记下之后照规则重判这一批(discharge_verify_batch:凑满了就改成已放电并核实,记下是这一炉)。
--   【为什么不经 submit_manual_capture】那条手工路要跑这一类的转换器,而 discharge_module 的转换器【没有建】—— Bosch 的逐模组导出
--   格式没人给过,照着一个编出来的格式建就是 MES-3b Q25 / MES-4a Q14 说的那件事。所以照 MES-4a 记参数的先例:直接记,source = manual,
--   收件箱 / 草稿 / 现场数据那几列留空;将来接上设备,那几列已经在,不必改表。
--   返回 {id, batch_code, verified}。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.record_discharge_module_result(p_run_id uuid, p_kind text, p_batch_id uuid, p_module_ref text, p_outlet_voltage_v numeric, p_verdict text, p_verdict_at timestamp with time zone, p_disposition text DEFAULT NULL::text, p_channel_no integer DEFAULT NULL::integer, p_start_voltage_v numeric DEFAULT NULL::numeric, p_duration_min numeric DEFAULT NULL::numeric, p_energy_recovered_wh numeric DEFAULT NULL::numeric, p_device_id uuid DEFAULT NULL::uuid, p_photo_path text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id  bigint;
    v_ok  boolean;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    v_id := discharge_result_internal(p_run_id, p_kind, p_batch_id, p_module_ref, p_outlet_voltage_v, p_verdict, p_verdict_at,
                                      p_disposition, p_channel_no, p_start_voltage_v, p_duration_min, p_energy_recovered_wh,
                                      p_device_id, p_photo_path, p_notes, NULL, NULL);
    v_ok := discharge_verify_batch(p_kind, p_batch_id, p_run_id, NULL);
    RETURN jsonb_build_object('id', v_id, 'verified', v_ok,
        'batch_code', COALESCE((SELECT b.code FROM inbound_batches b WHERE b.id = p_batch_id),
                               (SELECT b.code FROM output_batches b WHERE b.id = p_batch_id)));
END;
$function$;

-- db/functions/correct_discharge_module_result.sql
-- MES-5a-1(2026-10-08,规格 §4.2 "process records are append-only";MES-5a Step 0 Q7,Tim):【更正一条放电模组结果】—— 新行指回原行,理由必填。
--   那一炉、那一批、那个模组从原行来,不许换;其余每一格都按这一次给的值重写(判据与记一条新的同一份,discharge_result_internal)。
--   码:action.confirm_capture。更正之后照规则重判这一批 —— 把一条通过改成失败,会让一批已经核实的料重新拦在火闸外(discharge_verify_batch)。
--   返回 {id, batch_code, verified}。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.correct_discharge_module_result(p_id bigint, p_outlet_voltage_v numeric, p_verdict text, p_verdict_at timestamp with time zone, p_disposition text, p_channel_no integer, p_start_voltage_v numeric, p_duration_min numeric, p_energy_recovered_wh numeric, p_device_id uuid, p_photo_path text, p_notes text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig  discharge_module_results%ROWTYPE;
    v_id    bigint;
    v_kind  text;
    v_batch uuid;
    v_ok    boolean;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    v_id := discharge_result_internal(NULL, NULL, NULL, NULL, p_outlet_voltage_v, p_verdict, p_verdict_at, p_disposition, p_channel_no,
                                      p_start_voltage_v, p_duration_min, p_energy_recovered_wh, p_device_id, p_photo_path, p_notes,
                                      p_id, p_reason);
    SELECT * INTO v_orig FROM discharge_module_results WHERE id = v_id;
    v_kind := CASE WHEN v_orig.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END;
    v_batch := COALESCE(v_orig.inbound_batch_id, v_orig.output_batch_id);
    v_ok := discharge_verify_batch(v_kind, v_batch, v_orig.run_id, 'result corrected: ' || btrim(p_reason));
    RETURN jsonb_build_object('id', v_id, 'verified', v_ok,
        'batch_code', COALESCE((SELECT b.code FROM inbound_batches b WHERE b.id = v_batch),
                               (SELECT b.code FROM output_batches b WHERE b.id = v_batch)));
END;
$function$;

-- db/functions/discharge_channel_internal.sql
-- MES-5a-1(2026-10-08,MES-5a Step 0 Q9,Tim):【一条通道分配的判据与落库】—— 记与更正共用这一份。内层:不是 DEFINER,authenticated 调不到。
--   "当前" = 没被更正、没被撤回。查重时不算正在被更正的那一条(p_corrects_id)。撤回那一行不查重(它让通道空出来)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.discharge_channel_internal(p_run_id uuid, p_kind text, p_batch_id uuid, p_channel_no integer, p_module_ref text, p_withdraw boolean, p_corrects_id bigint, p_correction_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run     processing_runs%ROWTYPE;
    v_by_unit boolean;
    v_ref     text := NULLIF(btrim(COALESCE(p_module_ref, '')), '');
    v_other   text;
    v_id      bigint;
BEGIN
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, COALESCE(p_run_id::text, '?'));
    END IF;
    SELECT ot.verifies_by_unit INTO v_by_unit FROM operation_types ot WHERE ot.code = v_run.operation_type_code;
    IF v_by_unit IS NOT TRUE THEN
        RAISE EXCEPTION 'DISCHARGE_RUN_NOT_BY_UNIT|%|%', v_run.code, COALESCE(v_run.operation_type_code, '?');
    END IF;
    IF p_kind NOT IN ('inbound', 'output') OR p_kind IS NULL THEN
        RAISE EXCEPTION 'BATCH_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM processing_inputs pi WHERE pi.run_id = p_run_id
                     AND ((p_kind = 'inbound' AND pi.inbound_batch_id = p_batch_id) OR (p_kind = 'output' AND pi.output_batch_id = p_batch_id))) THEN
        RAISE EXCEPTION 'DISCHARGE_BATCH_NOT_INPUT|%', v_run.code;
    END IF;
    IF p_channel_no IS NULL OR p_channel_no <= 0 THEN
        RAISE EXCEPTION 'DISCHARGE_VALUE_INVALID|channel_no';
    END IF;
    IF v_ref IS NULL OR length(v_ref) > 60 THEN
        RAISE EXCEPTION 'DISCHARGE_MODULE_REF_REQUIRED';
    END IF;

    IF NOT COALESCE(p_withdraw, false) THEN
        SELECT a.module_ref INTO v_other FROM discharge_channel_assignments a
         WHERE a.run_id = p_run_id AND a.channel_no = p_channel_no AND NOT a.withdrawn
           AND a.id IS DISTINCT FROM p_corrects_id
           AND NOT EXISTS (SELECT 1 FROM discharge_channel_assignments x WHERE x.corrects_id = a.id)
         LIMIT 1;
        IF v_other IS NOT NULL THEN
            RAISE EXCEPTION 'DISCHARGE_CHANNEL_TAKEN|%|%', p_channel_no, v_other;
        END IF;
        SELECT a.channel_no::text INTO v_other FROM discharge_channel_assignments a
         WHERE a.run_id = p_run_id AND COALESCE(a.inbound_batch_id, a.output_batch_id) = p_batch_id AND a.module_ref = v_ref
           AND NOT a.withdrawn AND a.id IS DISTINCT FROM p_corrects_id
           AND NOT EXISTS (SELECT 1 FROM discharge_channel_assignments x WHERE x.corrects_id = a.id)
         LIMIT 1;
        IF v_other IS NOT NULL THEN
            RAISE EXCEPTION 'DISCHARGE_MODULE_ALREADY_ON_CHANNEL|%|%', v_ref, v_other;
        END IF;
    END IF;

    INSERT INTO discharge_channel_assignments (run_id, inbound_batch_id, output_batch_id, channel_no, module_ref, withdrawn,
                                               corrects_id, correction_reason)
    VALUES (p_run_id, CASE WHEN p_kind = 'inbound' THEN p_batch_id END, CASE WHEN p_kind = 'output' THEN p_batch_id END,
            p_channel_no, v_ref, COALESCE(p_withdraw, false), p_corrects_id, NULLIF(btrim(COALESCE(p_correction_reason, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/assign_discharge_channel.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-5a Step 0 Q9,Tim):【记下一炉放电里一个通道接的是哪个模组】—— 装机时记;手工录入可以不记。
--   码:action.processing_aftercare(提交之后记的事,MES-4a 的码)。拒:
--     RUN_NOT_COMMITTED|<单> · DISCHARGE_RUN_NOT_BY_UNIT|<单>|<工序> · BATCH_KIND_UNKNOWN · DISCHARGE_BATCH_NOT_INPUT|<单>
--     DISCHARGE_VALUE_INVALID|channel_no · DISCHARGE_MODULE_REF_REQUIRED
--     DISCHARGE_CHANNEL_TAKEN|<通道>|<当前记着的模组>   这一炉这个通道当前已经记着一个模组(要换就更正那一条)
--     DISCHARGE_MODULE_ALREADY_ON_CHANNEL|<模组>|<通道>  这一炉这一批的这个模组当前已经记在另一个通道上
--   内层共用:discharge_channel_internal(更正也走它)。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.assign_discharge_channel(p_run_id uuid, p_kind text, p_batch_id uuid, p_channel_no integer, p_module_ref text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    RETURN discharge_channel_internal(p_run_id, p_kind, p_batch_id, p_channel_no, p_module_ref, false, NULL, NULL);
END;
$function$;

-- db/functions/correct_discharge_channel.sql
-- MES-5a-1(2026-10-08,MES-5a Step 0 Q9,Tim):【更正或撤回一条通道分配】—— 新行指回原行(corrects_id 唯一)+ 理由必填;只追加。
--   p_withdraw 为真 = 撤回(这个通道空出来;通道号与模组照抄原行);否则用这一次给的通道号与模组重写(同一套判据)。
--   码:action.processing_aftercare。拒:DISCHARGE_ASSIGNMENT_NOT_FOUND|<id> · DISCHARGE_ASSIGNMENT_SUPERSEDED|<id> ·
--   DISCHARGE_CORRECTION_REASON_REQUIRED · DISCHARGE_CORRECTION_SAME_VALUE,以及 assign_discharge_channel 那几条。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.correct_discharge_channel(p_id bigint, p_channel_no integer, p_module_ref text, p_withdraw boolean, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig discharge_channel_assignments%ROWTYPE;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT * INTO v_orig FROM discharge_channel_assignments WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DISCHARGE_ASSIGNMENT_NOT_FOUND|%', p_id;
    END IF;
    IF EXISTS (SELECT 1 FROM discharge_channel_assignments x WHERE x.corrects_id = p_id) THEN
        RAISE EXCEPTION 'DISCHARGE_ASSIGNMENT_SUPERSEDED|%', p_id;
    END IF;
    IF v_orig.withdrawn THEN
        RAISE EXCEPTION 'DISCHARGE_ASSIGNMENT_SUPERSEDED|%', p_id;
    END IF;
    IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
        RAISE EXCEPTION 'DISCHARGE_CORRECTION_REASON_REQUIRED';
    END IF;
    IF NOT COALESCE(p_withdraw, false) AND p_channel_no IS NOT DISTINCT FROM v_orig.channel_no
       AND NULLIF(btrim(COALESCE(p_module_ref, '')), '') IS NOT DISTINCT FROM v_orig.module_ref THEN
        RAISE EXCEPTION 'DISCHARGE_CORRECTION_SAME_VALUE';
    END IF;
    RETURN discharge_channel_internal(v_orig.run_id,
        CASE WHEN v_orig.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END,
        COALESCE(v_orig.inbound_batch_id, v_orig.output_batch_id),
        CASE WHEN COALESCE(p_withdraw, false) THEN v_orig.channel_no ELSE p_channel_no END,
        CASE WHEN COALESCE(p_withdraw, false) THEN v_orig.module_ref ELSE p_module_ref END,
        COALESCE(p_withdraw, false), p_id, p_reason);
END;
$function$;

-- db/functions/create_stock_transfer_internal.sql
-- MES-5a-1(2026-10-08,MES-5a Step 0 Q11,Tim):create_stock_transfer 的函数体原样搬进来,只拿掉了码的检查(与 rollback_processing_run_internal
--   同一个形状)。理由:拆去隔离(split_failed_modules_to_quarantine)要把拆出来的那一批放进隔离库位,而那一扇门的码是
--   action.processing_aftercare(Tim 的 Q10),不是库存编辑码 —— 两支 DEFINER 调它,各自先判自己的码:
--     create_stock_transfer          → module.inventory.edit(签名、行为与此前逐字相同)
--     split_failed_modules_to_quarantine → action.processing_aftercare
--   内层算子,无调用者检查;不是 DEFINER;EXECUTE 从 authenticated 收回。其余判据(库位在用、桶里够、分类告警、隔离落闸、预留跟着走)一个字不改。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.create_stock_transfer_internal(p_qty numeric, p_to_location_id uuid, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_from_location_id uuid DEFAULT NULL::uuid, p_stock_status text DEFAULT 'available'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
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
$function$;

-- db/functions/split_failed_modules_to_quarantine.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23;MES-5a Step 0 Q11,Tim):【把放电失败、处置为隔离的模组拆成另一批,放进隔离库位】
--   —— 从放电那一炉的页面上起。一笔事务里:
--     ① 判:那一炉是没回滚的 verifies_by_unit 工序;这一批是它的投料;每一个点名的模组在这一批上的最新结论是"失败 · 隔离"、还没被拆走
--        (DISCHARGE_SPLIT_MODULE_NOT_QUARANTINE|<模组>);至少点一个、不重复(DISCHARGE_SPLIT_MODULES_REQUIRED);
--        库位是一个在用的隔离库位(QUARANTINE_LOCATION_REQUIRED|charged_not_discharged|<库位编号或 unspecified> —— MES-3a 那条码,
--        同一句话;没有任何隔离库位时永远拒)。
--     ② 记一炉 discharge_quarantine_split(经 commit_processing_run —— 它照旧判 action.processing_commit、开始 / 结束 / 班次、称重、
--        火闸):原批消耗拆出去的那几个模组称出来的重量(p_weight_kg 敲一个 → 一条手工称重;或 p_weighing_id 挑一条),
--        产出同一物料的一批,重量就是那一次称重。
--     ③ 记下是哪几个模组(discharge_module_splits);新批的模组数 = 点名的个数;新批照抄原批此刻开着的安全状态
--        (它们是同一批模组 —— 原批没核实,所以那里面一定有"带电未放电"),记 created_by_run_id = 拆分那一炉(回滚拆分就把它们结束)。
--     ④ 把新批整批转进那个隔离库位(create_stock_transfer_internal —— 与库存转移同一份;门是本函数的码)。
--     ⑤ 照规则重判原批(拆走的模组算已处置;凑满了就核实,记下是拆分那一炉)。
--   码:action.processing_aftercare(Tim 的 Q10);记那一炉本身照旧还要 action.processing_commit(每一炉都要)——线上两码同一批人持。
--   返回 {split_run_id, split_run_code, batch_id, batch_code, modules, parent_verified}。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.split_failed_modules_to_quarantine(p_discharge_run_id uuid, p_kind text, p_batch_id uuid, p_module_refs text[], p_process_date date, p_started_at timestamp with time zone, p_ended_at timestamp with time zone, p_shift_code text, p_location_id uuid, p_weight_kg numeric DEFAULT NULL::numeric, p_weighing_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run      processing_runs%ROWTYPE;
    v_by_unit  boolean;
    v_refs     text[];
    v_ref      text;
    v_cur      record;
    v_material uuid;
    v_code     text;
    v_loc      storage_locations%ROWTYPE;
    v_qty      numeric;
    v_split    uuid;
    v_new      uuid;
    v_new_code text;
    v_ok       boolean;
BEGIN
    PERFORM require_permission('action.processing_aftercare');

    SELECT * INTO v_run FROM processing_runs WHERE id = p_discharge_run_id;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, COALESCE(p_discharge_run_id::text, '?'));
    END IF;
    SELECT ot.verifies_by_unit INTO v_by_unit FROM operation_types ot WHERE ot.code = v_run.operation_type_code;
    IF v_by_unit IS NOT TRUE THEN
        RAISE EXCEPTION 'DISCHARGE_RUN_NOT_BY_UNIT|%|%', v_run.code, COALESCE(v_run.operation_type_code, '?');
    END IF;
    IF p_kind = 'inbound' THEN
        SELECT b.material_id, b.code INTO v_material, v_code FROM inbound_batches b WHERE b.id = p_batch_id AND b.deleted_at IS NULL;
        IF NOT EXISTS (SELECT 1 FROM processing_inputs pi WHERE pi.run_id = v_run.id AND pi.inbound_batch_id = p_batch_id) THEN
            RAISE EXCEPTION 'DISCHARGE_BATCH_NOT_INPUT|%', v_run.code;
        END IF;
    ELSIF p_kind = 'output' THEN
        SELECT b.material_id, b.code INTO v_material, v_code FROM output_batches b WHERE b.id = p_batch_id AND b.deleted_at IS NULL;
        IF NOT EXISTS (SELECT 1 FROM processing_inputs pi WHERE pi.run_id = v_run.id AND pi.output_batch_id = p_batch_id) THEN
            RAISE EXCEPTION 'DISCHARGE_BATCH_NOT_INPUT|%', v_run.code;
        END IF;
    ELSE
        RAISE EXCEPTION 'BATCH_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;

    SELECT array_agg(DISTINCT x ORDER BY x) INTO v_refs
      FROM unnest(COALESCE(p_module_refs, ARRAY[]::text[])) r(y), LATERAL (SELECT NULLIF(btrim(r.y), '') AS x) z
     WHERE z.x IS NOT NULL;
    IF v_refs IS NULL OR cardinality(v_refs) = 0
       OR cardinality(v_refs) <> (SELECT count(*) FROM unnest(p_module_refs) y WHERE NULLIF(btrim(y), '') IS NOT NULL) THEN
        RAISE EXCEPTION 'DISCHARGE_SPLIT_MODULES_REQUIRED';
    END IF;
    FOREACH v_ref IN ARRAY v_refs LOOP
        SELECT * INTO v_cur FROM discharge_module_current_all c WHERE c.batch_id = p_batch_id AND c.module_ref = v_ref;
        IF NOT FOUND OR v_cur.split_out OR v_cur.verdict <> 'fail' OR v_cur.disposition IS DISTINCT FROM 'quarantine' THEN
            RAISE EXCEPTION 'DISCHARGE_SPLIT_MODULE_NOT_QUARANTINE|%', v_ref
              USING HINT = '只能拆最新一条结论是"失败、处置为隔离"、而且还没被拆走的模组。';
        END IF;
    END LOOP;

    SELECT * INTO v_loc FROM storage_locations l WHERE l.id = p_location_id AND l.is_active AND l.is_quarantine;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'QUARANTINE_LOCATION_REQUIRED|charged_not_discharged|%',
            COALESCE((SELECT l.code FROM storage_locations l WHERE l.id = p_location_id), 'unspecified')
          USING HINT = '拆出来的失效模组只能进一个在用的隔离库位。还没有隔离库位,先在库位编辑器里标一个。';
    END IF;

    IF p_weighing_id IS NOT NULL THEN
        SELECT w.weight_kg INTO v_qty FROM weighings w WHERE w.id = p_weighing_id;
    ELSE
        v_qty := p_weight_kg;
    END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN
        RAISE EXCEPTION 'OUTPUT_WEIGHING_REQUIRED|1'
          USING HINT = '拆出去的那几个模组要称一次:敲一个重量,或挑一条现成的称重。';
    END IF;

    v_split := commit_processing_run(
        p_process_date, COALESCE(NULLIF(btrim(COALESCE(p_notes, '')), ''), 'Quarantine split of ' || array_to_string(v_refs, ', ') || ' from ' || v_run.code),
        NULL,
        jsonb_build_array(CASE WHEN p_kind = 'inbound'
                               THEN jsonb_build_object('inbound_batch_id', p_batch_id, 'quantity_consumed', v_qty)
                               ELSE jsonb_build_object('output_batch_id', p_batch_id, 'quantity_consumed', v_qty) END),
        jsonb_build_array(CASE WHEN p_weighing_id IS NOT NULL
                               THEN jsonb_build_object('material_id', v_material, 'weighing_id', p_weighing_id)
                               ELSE jsonb_build_object('material_id', v_material, 'weight_kg', v_qty) END),
        'weight', NULL, NULL, 'discharge_quarantine_split', p_started_at, p_ended_at, p_shift_code, NULL, NULL, NULL);

    SELECT po.output_batch_id, ob.code INTO v_new, v_new_code
      FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id WHERE po.run_id = v_split;

    INSERT INTO discharge_module_splits (split_run_id, discharge_run_id, inbound_batch_id, output_batch_id, module_ref, new_output_batch_id)
    SELECT v_split, v_run.id, CASE WHEN p_kind = 'inbound' THEN p_batch_id END, CASE WHEN p_kind = 'output' THEN p_batch_id END, r, v_new
      FROM unnest(v_refs) r;

    UPDATE output_batches SET module_count = cardinality(v_refs) WHERE id = v_new;

    IF p_kind = 'inbound' THEN
        INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code, created_by_run_id)
        SELECT v_new, s.safety_state_code, v_split FROM inbound_batch_safety_states s
         WHERE s.inbound_batch_id = p_batch_id AND s.ended_at IS NULL;
    ELSE
        INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code, created_by_run_id)
        SELECT v_new, s.safety_state_code, v_split FROM output_batch_safety_states s
         WHERE s.output_batch_id = p_batch_id AND s.ended_at IS NULL;
    END IF;

    PERFORM create_stock_transfer_internal(v_qty, v_loc.id, NULL, v_new, NULL, 'available',
                                           'Quarantine split ' || (SELECT pr.code FROM processing_runs pr WHERE pr.id = v_split));

    v_ok := discharge_verify_batch(p_kind, p_batch_id, v_split, 'failed modules split to quarantine');

    RETURN jsonb_build_object('split_run_id', v_split, 'split_run_code', (SELECT pr.code FROM processing_runs pr WHERE pr.id = v_split),
                              'batch_id', v_new, 'batch_code', v_new_code, 'modules', to_jsonb(v_refs), 'parent_verified', v_ok,
                              'parent_code', v_code);
END;
$function$;

-- ── 8 · 改过的函数(镜像原样,同签名)──────────────────────────────────────────

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
    -- MES-4b:电芯结构 —— 这道工序要不要它、每一批投料带着什么、产出继承什么
    v_req_cc       boolean;
    v_batch_code   text;
    v_cc           text;
    v_cc_vals      text[] := ARRAY[]::text[];
    v_cc_any_null  boolean := false;
    v_cc_inherit   text;
    v_dismantles   boolean;
    -- MES-5a-1:这道工序的结果状态由逐件的结果判,不在提交时写
    v_by_unit      boolean;
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
    SELECT ot.code, k.consumes_input, k.produces_outputs, ot.resulting_safety_state_code, ot.requires_cell_construction, ot.verifies_by_unit
      INTO v_op, v_consumes, v_produces, v_result_state, v_req_cc, v_by_unit
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
            -- ★ MES-5a-1(2026-10-08,MES-0 Q23 · Q24;MES-5a Step 0 Q5 · Q6,Tim):【verifies_by_unit 的工序在这里不改状态】—— 提交只记下这一炉。
            --   结果状态由逐件的结果判(discharge_verify_batch:每一个计数的模组都有一条当前的通过,或已被拆去隔离);一张单单靠提交永远核实不了。
            --   这同时关掉了 P1:此前放 10 kg 一批 100 kg 的料,整批都会被写成已放电并核实。
            IF NOT v_produces AND v_result_state IS NOT NULL AND NOT v_by_unit THEN
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
            -- ★ MES-5a-1(2026-10-08,P3;MES-5a Step 0 Q14,Tim):【直通式不扣库存 —— 产出批这一侧也一样】进料批那一侧一直有
            --   IF v_consumes 这一道(上面 PROC-WIRE-1B-i 那一段),这一侧没有:一炉深度放电放一批自产的料,会把放过的那几公斤从库存里扣掉,
            --   而那批货还在院子里。现在两侧同一句。投入腿照记(通过量)。
            IF v_consumes THEN
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
            END IF;

            INSERT INTO processing_inputs (run_id, output_batch_id, quantity_consumed)
            VALUES (v_run_id, v_output_id, v_consumed);

            -- ════════════════════════════════════════════════════════════
            -- PROC-WIRE-1B-ii:**R3 的"改状态",产出批这一侧** ——
            -- 与上面进料那一段逐字同形。不删被解决掉的状态,一批放完电的
            -- 自产料会永远带着"未放电",下一道工序仍然拒绝它 —— 那就是
            -- 1B-i 解掉的那个死锁,换到产出批上原样复发。
            -- ════════════════════════════════════════════════════════════
            -- ★ MES-3a:与进料侧逐字同形 —— 结束,不删;结果状态记 created_by_run_id。MES-5a-1:verifies_by_unit 的工序同样不在这里改。
            IF NOT v_produces AND v_result_state IS NOT NULL AND NOT v_by_unit THEN
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
        -- ════════════════════════════════════════════════════════════════════
        -- ★ MES-4b(2026-10-07,规格 §3.4;MES-0 Q45;MES-4b Step 0 Q5 · Q6,Tim):【分极片的工序要知道电芯是卷绕还是叠片】
        --   operation_types.requires_cell_construction 为真(引导:electrode_separation · electrode_line)时,每一批投料都必须带一个
        --   确定的结构(cell_constructions.is_determined)—— 没记或 unknown → INPUT_CELL_CONSTRUCTION_REQUIRED|<批号>。
        --   是一个标志,不是这里的一张码表。【放在投入腿落下之后】—— 投入腿的守卫先判安全状态(起火那一道闸先说话:
        --   一批没放电的料,要先听到"这道工序不收它",而不是"先记下它是卷绕还是叠片")。同时记下每一批的值,第 6 步据此决定产出继承什么。
        -- ════════════════════════════════════════════════════════════════════
        IF v_inbound_id IS NOT NULL THEN
            SELECT b.code, b.cell_construction_code INTO v_batch_code, v_cc FROM inbound_batches b WHERE b.id = v_inbound_id;
        ELSE
            SELECT b.code, b.cell_construction_code INTO v_batch_code, v_cc FROM output_batches b WHERE b.id = v_output_id;
        END IF;
        IF v_req_cc AND (v_cc IS NULL OR NOT EXISTS (SELECT 1 FROM cell_constructions c WHERE c.code = v_cc AND c.is_determined)) THEN
            RAISE EXCEPTION 'INPUT_CELL_CONSTRUCTION_REQUIRED|%', v_batch_code
              USING HINT = '这道工序按电芯结构分设备(卷绕 / 叠片)。先在批次页上记下这一批是哪一种 —— 没记或"看过分不出"都过不去。';
        END IF;
        IF v_cc IS NULL THEN
            v_cc_any_null := true;
        ELSE
            v_cc_vals := array_append(v_cc_vals, v_cc);
        END IF;
    END LOOP;

    -- MES-4b(Q6):每一批投料都带着【同一个】结构 → 装电芯的产出继承它;有一批没记、或彼此不同 → 留空,到批次页上补。
    IF NOT v_cc_any_null AND (SELECT count(DISTINCT x) FROM unnest(v_cc_vals) x) = 1 THEN
        v_cc_inherit := v_cc_vals[1];
    END IF;

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
        -- MES-4b(Q6):只有【明确装着电芯】的形态继承结构(没有形态的物料不继承 —— 不知道它装不装电芯)。
        SELECT f.implies_dismantling INTO v_dismantles
          FROM materials m JOIN material_forms f ON f.code = m.form_code WHERE m.id = v_material_id;

        INSERT INTO output_batches (
            material_id, quantity, unit, remaining_qty, output_date, state, purity,
            created_by, updated_by, cell_construction_code
        ) VALUES (
            v_material_id, v_qty, v_unit, v_qty, v_process_date, '库存中', v_purity,
            v_user_id, v_user_id, CASE WHEN v_dismantles IS TRUE THEN v_cc_inherit END
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

-- db/functions/rollback_processing_run_internal.sql
-- APR-7(2026-09-25):回滚一张加工单 —— ROLE-1 Batch 3b 的 rollback_processing_run 的函数体原样搬进来,
-- 只拿掉了码的检查、加了 p_deleted_by(grilling Q6:产出批与加工单的 deleted_by、还原流水的 created_by =
-- 提单人;不给 = 调用者本人)。冲销分录的 created_by 是调用者(批准的 CFO)。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- MES-5a-1(2026-10-08,P2;MES-5a Step 0 Q15,Tim):第 3 步只在这一炉的工序【吃料】时还原库存 —— 一炉深度放电从没扣过库存,
--   此前回滚却照样"还原":批次满着时被封顶成 0 而碰巧没事;批次之后被别的单用掉一部分时,还原对不上原始流水,
--   IOD_RESTORE_MISMATCH|<放过的量>|0,于是这一炉放电再也回滚不了。另:回滚之后照规则重判每一批投料的放电核实
--   (discharge_verify_batch —— 回滚掉的结果、拆分不再算数)。
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
    v_consumes boolean;     -- MES-5a-1(P2):这一炉的工序吃不吃料(没有工序的历史单按吃料算 —— 那正是它们当年做的事)
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
    --    MES-5a-1(P2):只在这一炉的工序吃料时 —— 状态改变型(深度放电)提交时没扣过,回滚就没有东西可还(commit_processing_run 的 v_consumes 那一道,两边同一个判据)。
    SELECT COALESCE((SELECT k.consumes_input FROM processing_runs pr JOIN operation_types ot ON ot.code = pr.operation_type_code
                       JOIN operation_kinds k ON k.code = ot.kind_code WHERE pr.id = p_run_id), true)
      INTO v_consumes;
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.output_batch_id, pi.quantity_consumed
        FROM processing_inputs pi
        WHERE pi.run_id = p_run_id AND v_consumes
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

    -- ── MES-5a-1(Step 0 Q6 · Q15):回滚之后,照规则重判这一炉每一批投料的放电核实 ────────────────────────
    --   回滚掉的那一炉的结果、它做的拆分都不再算数;上面那一段已经撤回了它自己写过的状态,这里让剩下的结论说了算
    --   (还有别的没回滚的放电结论时,可能重新核实;记的是那一批此刻最晚的那一炉)。一批从没有过结论的料不被碰。
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.output_batch_id FROM processing_inputs pi WHERE pi.run_id = p_run_id
    LOOP
        PERFORM discharge_verify_batch(
            CASE WHEN v_input.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END,
            COALESCE(v_input.inbound_batch_id, v_input.output_batch_id),
            (SELECT s.latest_run_id FROM discharge_batch_status_all s
              WHERE s.batch_id = COALESCE(v_input.inbound_batch_id, v_input.output_batch_id)),
            'after rollback of ' || COALESCE(v_code, '?'));
    END LOOP;

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

-- db/functions/create_stock_transfer.sql
-- MES-3a(2026-10-06,MES-0 Q34;MES-3a Step 0 Q19 · Q20,Tim):一批身上开着一个要隔离的状态(鼓包或漏液),
--   它的下一次移动只能进一个在用的隔离库位 —— 入腿过 assert_quarantine_landing,拒绝 QUARANTINE_LOCATION_REQUIRED。
--   移进隔离永远准许;从隔离移到另一个隔离也准许。签名不变。
-- MES-5a-1(2026-10-08):函数体搬进 create_stock_transfer_internal(同签名、同行为);这里只判码再转交 —— 拆去隔离要用同一份转移,
--   而它的门是 action.processing_aftercare。签名不变。

CREATE OR REPLACE FUNCTION public.create_stock_transfer(p_qty numeric, p_to_location_id uuid, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_from_location_id uuid DEFAULT NULL::uuid, p_stock_status text DEFAULT 'available'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.inventory.edit');
    RETURN create_stock_transfer_internal(p_qty, p_to_location_id, p_inbound_batch_id, p_output_batch_id, p_from_location_id, p_stock_status, p_note);
END;
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
        ('operation_type',     4, 'process_recipe_versions',    'process_recipes',  'recipe_id',           '{}'::jsonb, 'down', true, true),
        -- ── MES-4b(2026-10-07,MES-4b Step 0 Q28):交叉污染抽检 —— 挂在它那一炉(家)与它抽的那一批极片下面(receipt_ceiling_checks 的先例:
        --    一张表挂两个主语,只有一处是家)。没抽的那一种没有批次,只出现在加工单上。──
        ('processing_run',    13, 'contamination_checks',       'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('output_batch',      39, 'contamination_checks',       'output_batches',   'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-1(2026-10-08,MES-5a Step 0 Q31):放电 —— 逐模组结果、通道分配、拆去隔离的模组。家在那一炉(结果与分配挂在放电那一炉,
        --    拆分挂在拆分那一炉);也出现在它们说的那一批上,结果还出现在记下它的放电柜上(device_id;今天手工录入不填它)。──
        ('processing_run',    14, 'discharge_module_results',      'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    15, 'discharge_channel_assignments', 'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    16, 'discharge_module_splits',       'processing_runs', 'split_run_id',     '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     42, 'discharge_module_results',      'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     43, 'discharge_module_splits',       'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('output_batch',      40, 'discharge_module_results',      'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('output_batch',      41, 'discharge_module_splits',       'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('device',             3, 'discharge_module_results',      'devices',         'device_id',        '{}'::jsonb, 'down', true, false)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- ── 9 · 签名变了的两支:DROP 旧的、CREATE 新的(末尾一个可缺省的参数 p_module_count)────────────────────────

DROP FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text);

-- db/functions/create_inbound_batch.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q19,Tim):末尾多三个参数(p_ticket_id · p_ticket_share_kg · p_quantity_reason),都带默认值 ——
--   签名变了,所以迁移是 DROP + CREATE(preflight 不许 CREATE OR REPLACE 换签名);已部署的旧应用不传它们,照样解析到这一支。
-- MES-3a(2026-10-06,MES-3a Step 0 Q9 · Q10 · Q19,Tim):写入之前过隔离闸(请求里带着要隔离的状态,就只能收进隔离库位);
--   落库之后对着执照的库存上限判一次并记下来(receipt_ceiling_check_internal)。签名不变;返回值多一个 'ceiling'(那一行)。
-- MES-4b(2026-10-07,MES-4b Step 0 Q4,Tim):末尾多一个可缺省的参数 p_cell_construction(电芯结构,收货时可选;空 = 没记)——
--   签名变了,迁移是 DROP + CREATE;已部署的旧应用不传它,照样解析到这一支。适用性与锁由表上的 guard_batch_cell_construction 判。

-- MES-5a-1(2026-10-08,MES-5a Step 0 Q4,Tim):末尾多一个可缺省的参数 p_module_count(这一批有几个模组,收货时可选;空 = 没记)——
--   签名变了,迁移是 DROP + CREATE;已部署的旧应用不传它,照样解析到这一支。适用性由表上的 guard_batch_module_count 判。
CREATE OR REPLACE FUNCTION public.create_inbound_batch(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date, p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text, p_currency text DEFAULT NULL::text, p_ticket_id uuid DEFAULT NULL::uuid, p_ticket_share_kg numeric DEFAULT NULL::numeric, p_quantity_reason text DEFAULT NULL::text, p_cell_construction text DEFAULT NULL::text, p_module_count integer DEFAULT NULL::integer)
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
    -- MES-4b(Q4):电芯结构可选;给了就必须是一个在用的值(写入之前按名拒,不让外键报一串约束名)。
    IF NULLIF(btrim(COALESCE(p_cell_construction, '')), '') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM cell_constructions c WHERE c.code = btrim(p_cell_construction) AND c.is_active) THEN
        RAISE EXCEPTION 'CELL_CONSTRUCTION_UNKNOWN|%', btrim(p_cell_construction);
    END IF;
    -- MES-5a-1(Q4):模组数可选;给了就必须是正数(写入之前按名拒,不让 CHECK 报一串约束名)。适用性由 guard_batch_module_count 判。
    IF p_module_count IS NOT NULL AND p_module_count <= 0 THEN
        RAISE EXCEPTION 'MODULE_COUNT_INVALID|%', p_module_count;
    END IF;

    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, unit, remaining_qty, arrival_date,
        stage, notes, purchase_order_id, purchase_order_line_id,
        declared_qty, chemistry_certainty_code, source_reason_code, source_reason_note,
        created_by, updated_by, cell_construction_code, module_count)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_arrival_date,
        COALESCE(p_stage,'待加工'), p_notes, p_purchase_order_id, p_purchase_order_line_id,
        p_declared_qty, p_chemistry_certainty, p_source_reason_code,
        NULLIF(btrim(COALESCE(p_source_reason_note, '')), ''),
        v_user, v_user, NULLIF(btrim(COALESCE(p_cell_construction, '')), ''), p_module_count)
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

DROP FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text);

-- db/functions/receive_inbound_batch_against_po.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q19,Tim):末尾多三个参数(p_ticket_id · p_ticket_share_kg · p_quantity_reason),都带默认值 ——
--   签名变了,迁移是 DROP + CREATE;已部署的旧应用不传它们,照样解析到这一支。
-- MES-3a(2026-10-06,MES-3a Step 0 Q9 · Q10 · Q19,Tim):写入之前过隔离闸(请求里带着要隔离的状态,就只能收进隔离库位);
--   落库之后对着执照的库存上限判一次并记下来(receipt_ceiling_check_internal)。签名不变;返回值多一个 'ceiling'(那一行)。
-- MES-4b(2026-10-07,MES-4b Step 0 Q4,Tim):末尾多一个可缺省的参数 p_cell_construction(电芯结构,收货时可选;空 = 没记)——
--   签名变了,迁移是 DROP + CREATE;已部署的旧应用不传它,照样解析到这一支。适用性与锁由表上的 guard_batch_cell_construction 判。

-- MES-5a-1(2026-10-08,MES-5a Step 0 Q4,Tim):末尾多一个可缺省的参数 p_module_count(这一批有几个模组,收货时可选;空 = 没记)——
--   签名变了,迁移是 DROP + CREATE;已部署的旧应用不传它,照样解析到这一支。适用性由表上的 guard_batch_module_count 判。
CREATE OR REPLACE FUNCTION public.receive_inbound_batch_against_po(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_arrival_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text, p_ticket_id uuid DEFAULT NULL::uuid, p_ticket_share_kg numeric DEFAULT NULL::numeric, p_quantity_reason text DEFAULT NULL::text, p_cell_construction text DEFAULT NULL::text, p_module_count integer DEFAULT NULL::integer)
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
    -- MES-4b(Q4):电芯结构可选;给了就必须是一个在用的值(写入之前按名拒,不让外键报一串约束名)。
    IF NULLIF(btrim(COALESCE(p_cell_construction, '')), '') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM cell_constructions c WHERE c.code = btrim(p_cell_construction) AND c.is_active) THEN
        RAISE EXCEPTION 'CELL_CONSTRUCTION_UNKNOWN|%', btrim(p_cell_construction);
    END IF;
    -- MES-5a-1(Q4):模组数可选;给了就必须是正数(写入之前按名拒,不让 CHECK 报一串约束名)。适用性由 guard_batch_module_count 判。
    IF p_module_count IS NOT NULL AND p_module_count <= 0 THEN
        RAISE EXCEPTION 'MODULE_COUNT_INVALID|%', p_module_count;
    END IF;

    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, remaining_qty, unit, arrival_date,
        notes, purchase_order_id, purchase_order_line_id, declared_qty,
        chemistry_certainty_code, source_reason_code, source_reason_note,
        created_by, updated_by, cell_construction_code, module_count)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, p_quantity, 'kg', p_arrival_date,
        p_notes, p_purchase_order_id, p_purchase_order_line_id, p_declared_qty,
        p_chemistry_certainty, p_source_reason_code,
        NULLIF(btrim(COALESCE(p_source_reason_note, '')), ''),
        v_user, v_user, NULLIF(btrim(COALESCE(p_cell_construction, '')), ''), p_module_count)
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

-- ── 10 · 视图(镜像原样):待补的值与提醒 ──────────────────────

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
-- 【MES-4b 加两支】(2026-10-07,MES-0 §5.1 V10 · V11;MES-4b Step 0 Q29,Tim)
--   V10  每一道启用的、勾了「Electrolyte evaporates in this step」而电解液份额为空的工序 —— 一道一行(去处:那道工序的页面;
--        门 module.processing.view)。由电芯供应商的规格书 / 工艺工程师在第一批极片分离之前给。引导一道都没勾,所以今天是零行。
--        没给:那一段的电解液挥发只能量出来,算不出来(ELECTROLYTE_SHARE_NOT_SET)。
--   V11  每一条启用的交叉污染流的警戒线(contamination_streams.warning_pct)—— 为空的每条一行(去处:/settings/dictionaries;
--        门 module.processing.view)。由 Tim / 第一份黑粉承购合同的规格在第一份承购合同之前给。没给:抽检照记,判不了超没超(NULL)。
-- 【MES-5a-1 加一支】(2026-10-08,MES-0 §5.1 V9;MES-5a Step 0 Q8 · Q32,Tim)
--   V9   放电通过电压(materials.discharge_pass_voltage_v,按物料 —— 模组的终止电压取决于串联节数)。【只在这种物料的一批已经有了
--        放电结果之后才列】,免得页面一下子被每一种装电芯的物料填满(去处:物料编辑页;门 module.materials.view)。由 Bosch 文档 /
--        模组规格书在放电调试时给。没给:结果照记,判定照收,那一格是"判不了"(contradicts_pass_voltage 为 NULL)。
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
          WHERE f.is_active AND ot.is_active AND f.has_range AND f.range_min IS NULL AND f.range_max IS NULL
        UNION ALL
         SELECT 'V10'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            ot.code AS item_code,
            ot.name_en AS item_label,
            '/operation/operation-types/'::text || ot.code AS href
           FROM operation_types ot
          WHERE ot.is_active AND ot.electrolyte_loss_applies AND ot.electrolyte_share_pct IS NULL
        UNION ALL
         SELECT 'V11'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            cs.code AS item_code,
            cs.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM contamination_streams cs
          WHERE cs.is_active AND cs.warning_pct IS NULL
        UNION ALL
         SELECT 'V9'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
          WHERE m.deleted_at IS NULL AND m.discharge_pass_voltage_v IS NULL AND (EXISTS ( SELECT 1
                   FROM discharge_module_results r
                     LEFT JOIN inbound_batches ib ON ib.id = r.inbound_batch_id
                     LEFT JOIN output_batches ob ON ob.id = r.output_batch_id
                  WHERE COALESCE(ib.material_id, ob.material_id) = m.id))) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程);MES-3a 加 V2(执照 × 类别的库存上限)、V29(NEA 类别与物料的类别)、V3(每个安全状态的滞留提醒天数)、V4(每个安全状态要不要隔离)与 V34(隔离库位);MES-3b 加 V30(危险品编号的标记 · 包装说明 · 标签尺寸)、V31(电池料的 HS 编码)与 V35(电池料的危险品编号);MES-4a 加 V1(转化型工序的物料平衡容差)与 V36(声明了有范围的参数的上下限),并把 V6 的去处搬到班次字典(V6 同时答 V7);MES-4b 加 V10(勾了电解液挥发的工序的电解液份额)与 V11(交叉污染流的警戒线)。MES-5a-1 加 V9(物料的放电通过电压,只在那种物料有了放电结果之后才列)。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行
-- ★ MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23;MES-5a Step 0 Q18,Tim):加两支,都读 discharge_batch_status_all,门 module.processing.view。
--   discharge_unverified —— 一批做过一炉没回滚的深度放电(verifies_by_unit 的工序),却还没有开着"已放电并核实"
--   (逐模组的结论还没凑满:没记模组数、结果没记完、有模组要再放电)。item_id = 那一批最晚的那一炉;subject = 批号。
--   discharge_quarantine_pending —— 一批里有模组最新一条结论是"失败、处置为隔离",还没拆走。item_id = 那一批最晚的那一炉(拆分从那一页上起);
--   subject = 批号。拆走、或更正了那一条,它就消失。
-- ★ MES-4b(2026-10-07,规格 §3.4;MES-0 Q52;MES-4b Step 0 Q24,Tim):加一支 contamination_check_missing —— 一个班、一条流没有抽检
--   (那一天那一班有一张 MES-4a 起记的、已提交没回滚的单产出了这条流的极片,而同一天同一班任何一张单上都没有一条当前的抽检,
--   两种都算 —— contamination_shift_status_all 的 check_state = 'missing')。门 module.processing.view;item_id = 那一格最早的那一炉
--   (fixture 47:一行提醒要指着一条真实的行),subject = 流。记一条"没抽"(带理由)也关掉它。
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
         SELECT 'contamination_check_missing'::text AS item_type,
            'module.processing.view'::text AS permission,
            cs.first_run_id AS item_id,
            NULL::text AS doc_kind,
            cs.first_run_code AS item_code,
            cs.stream_code AS subject,
            cs.process_date AS item_date
           FROM contamination_shift_status_all cs
          WHERE cs.check_state = 'missing'::text
        UNION ALL
         SELECT 'discharge_unverified'::text AS item_type,
            'module.processing.view'::text AS permission,
            ds.latest_run_id AS item_id,
            NULL::text AS doc_kind,
            ds.latest_run_code AS item_code,
            ds.batch_code AS subject,
            ds.latest_run_date AS item_date
           FROM discharge_batch_status_all ds
          WHERE ds.latest_run_id IS NOT NULL AND NOT ds.currently_verified
        UNION ALL
         SELECT 'discharge_quarantine_pending'::text AS item_type,
            'module.processing.view'::text AS permission,
            ds.latest_run_id AS item_id,
            NULL::text AS doc_kind,
            ds.latest_run_code AS item_code,
            ds.batch_code AS subject,
            ds.latest_run_date AS item_date
           FROM discharge_batch_status_all ds
          WHERE ds.failed_quarantine > 0 AND ds.latest_run_id IS NOT NULL
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

-- ── 11 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──────────────────────────
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.discharge_module_results
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.discharge_module_results
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.discharge_channel_assignments
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.discharge_channel_assignments
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.discharge_module_splits
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.discharge_module_splits
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 12 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.set_batch_module_count(text, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_batch_module_count(text, uuid, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_discharge_module_result(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_discharge_module_result(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.correct_discharge_module_result(bigint, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_discharge_module_result(bigint, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.assign_discharge_channel(uuid, text, uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assign_discharge_channel(uuid, text, uuid, integer, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.correct_discharge_channel(bigint, integer, text, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_discharge_channel(bigint, integer, text, boolean, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.split_failed_modules_to_quarantine(uuid, text, uuid, text[], date, timestamp with time zone, timestamp with time zone, text, uuid, numeric, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.split_failed_modules_to_quarantine(uuid, text, uuid, text[], date, timestamp with time zone, timestamp with time zone, text, uuid, numeric, uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.discharge_result_internal(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.discharge_result_internal(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, bigint, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.discharge_channel_internal(uuid, text, uuid, integer, text, boolean, bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.discharge_channel_internal(uuid, text, uuid, integer, text, boolean, bigint, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.discharge_verify_batch(text, uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.discharge_verify_batch(text, uuid, uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.create_stock_transfer_internal(numeric, uuid, uuid, uuid, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_stock_transfer_internal(numeric, uuid, uuid, uuid, uuid, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_batch_module_count() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_batch_module_count() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.discharge_result_internal(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.discharge_channel_internal(uuid, text, uuid, integer, text, boolean, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.discharge_verify_batch(text, uuid, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.create_stock_transfer_internal(numeric, uuid, uuid, uuid, uuid, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_batch_module_count() FROM authenticated;

-- ── 13 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes5a1_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes5a1_pending_after ON COMMIT DROP AS
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
         EXCEPT SELECT role_code || ':' || permission_code FROM mes5a1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes5a1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5A1_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES5A1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes5a1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes5a1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES5A1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的加工单与它的腿、安全状态、库位、库存流水逐字未变(PROC-2026-0494 在加工单那一份里);
    --   批次与物料除了多出来的那一列(全空)逐字未变
    IF EXISTS ((SELECT b.k, b.id FROM mes5a1_pending_before b EXCEPT SELECT a.k, a.id FROM mes5a1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes5a1_pending_after a EXCEPT SELECT b.k, b.id FROM mes5a1_pending_before b)) THEN
        RAISE EXCEPTION 'MES5A1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_runs t) IS DISTINCT FROM (SELECT runs FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_inputs t) IS DISTINCT FROM (SELECT inputs FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_outputs t) IS DISTINCT FROM (SELECT outputs FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM inbound_batch_safety_states t) IS DISTINCT FROM (SELECT ib_states FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM output_batch_safety_states t) IS DISTINCT FROM (SELECT ob_states FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM storage_locations t) IS DISTINCT FROM (SELECT locations FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM inventory_movements t) IS DISTINCT FROM (SELECT movements FROM mes5a1_rows_before) THEN
        RAISE EXCEPTION 'MES5A1_PROOF|a pre-existing run, leg, safety state, location or stock movement changed';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'module_count')::text, '|' ORDER BY t.id), '')) FROM inbound_batches t)
           IS DISTINCT FROM (SELECT inbound FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'module_count')::text, '|' ORDER BY t.id), '')) FROM output_batches t)
           IS DISTINCT FROM (SELECT output FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'discharge_pass_voltage_v')::text, '|' ORDER BY t.id), '')) FROM materials t)
           IS DISTINCT FROM (SELECT materials FROM mes5a1_rows_before)
       OR EXISTS (SELECT 1 FROM inbound_batches WHERE module_count IS NOT NULL)
       OR EXISTS (SELECT 1 FROM output_batches WHERE module_count IS NOT NULL)
       OR EXISTS (SELECT 1 FROM materials WHERE discharge_pass_voltage_v IS NOT NULL) THEN
        RAISE EXCEPTION 'MES5A1_PROOF|a pre-existing batch or material changed, or a module count / V9 was set';
    END IF;

    -- ④ 变更记录只在引导的那几张表上动了,恰好 15 行:工序 1 + 2(两个标志)· 受理 2 · 投料形态 4 · 产出形态 4 · 关系图例外 2。
    --   三张新表的绑定在建表之后(第 11 段),它们都是空的,所以不进变更记录。
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes5a1_log_before), 0)
       AND c.table_name NOT IN ('operation_types', 'operation_type_safety_states', 'operation_type_input_forms',
                                'operation_type_output_forms', 'document_relation_exceptions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5A1_PROOF|change_log moved on %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes5a1_log_before), 0)) <> 15 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|expected 15 change-log rows, got %',
            (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes5a1_log_before), 0));
    END IF;

    -- ⑤ 引导恰好是引导;新的数据表是空的;没有隔离库位被标;开关空着;设备转换器没有建
    IF (SELECT string_agg(code, ',' ORDER BY code) FROM operation_types WHERE verifies_by_unit) IS DISTINCT FROM 'deep_discharge'
       OR (SELECT string_agg(code, ',' ORDER BY code) FROM operation_types WHERE started_from_run_page) IS DISTINCT FROM 'discharge_quarantine_split'
       OR (SELECT kind_code FROM operation_types WHERE code = 'discharge_quarantine_split') IS DISTINCT FROM 'transforming'
       OR (SELECT count(*) FROM operation_types) <> 8 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|the operation flags are not exactly deep_discharge / the split operation (8 operations)';
    END IF;
    IF EXISTS (SELECT 1 FROM discharge_module_results) OR EXISTS (SELECT 1 FROM discharge_channel_assignments)
       OR EXISTS (SELECT 1 FROM discharge_module_splits) THEN
        RAISE EXCEPTION 'MES5A1_PROOF|a new data table is not empty';
    END IF;
    IF EXISTS (SELECT 1 FROM storage_locations WHERE is_quarantine) THEN
        RAISE EXCEPTION 'MES5A1_PROOF|a quarantine location exists (none was expected and none may be set by this cut)';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A1_PROOF|require_calibrated_since was set';
    END IF;
    IF (SELECT transform_function FROM ingest_data_classes WHERE code = 'discharge_module') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A1_PROOF|a discharge_module transform appeared';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;员工那几支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到;旧签名不在了
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES5A1_PROOF|anon executes: %', v_bad;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.set_batch_module_count(text, uuid, integer)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.set_batch_module_count(text, uuid, integer)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.set_batch_module_count(text, uuid, integer)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|public.set_batch_module_count(text, uuid, integer): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_discharge_module_result(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_discharge_module_result(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_discharge_module_result(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|public.record_discharge_module_result(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.correct_discharge_module_result(bigint, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.correct_discharge_module_result(bigint, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.correct_discharge_module_result(bigint, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|public.correct_discharge_module_result(bigint, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.assign_discharge_channel(uuid, text, uuid, integer, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.assign_discharge_channel(uuid, text, uuid, integer, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.assign_discharge_channel(uuid, text, uuid, integer, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|public.assign_discharge_channel(uuid, text, uuid, integer, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.correct_discharge_channel(bigint, integer, text, boolean, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.correct_discharge_channel(bigint, integer, text, boolean, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.correct_discharge_channel(bigint, integer, text, boolean, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|public.correct_discharge_channel(bigint, integer, text, boolean, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.split_failed_modules_to_quarantine(uuid, text, uuid, text[], date, timestamp with time zone, timestamp with time zone, text, uuid, numeric, uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.split_failed_modules_to_quarantine(uuid, text, uuid, text[], date, timestamp with time zone, timestamp with time zone, text, uuid, numeric, uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.split_failed_modules_to_quarantine(uuid, text, uuid, text[], date, timestamp with time zone, timestamp with time zone, text, uuid, numeric, uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|public.split_failed_modules_to_quarantine(uuid, text, uuid, text[], date, timestamp with time zone, timestamp with time zone, text, uuid, numeric, uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text, integer)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text, integer)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text, integer)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text, integer): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text, integer)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text, integer)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text, integer)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text, integer): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF has_function_privilege('authenticated', 'public.discharge_result_internal(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, bigint, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.discharge_result_internal(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, bigint, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|public.discharge_result_internal(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, bigint, text) must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.discharge_channel_internal(uuid, text, uuid, integer, text, boolean, bigint, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.discharge_channel_internal(uuid, text, uuid, integer, text, boolean, bigint, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|public.discharge_channel_internal(uuid, text, uuid, integer, text, boolean, bigint, text) must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.discharge_verify_batch(text, uuid, uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.discharge_verify_batch(text, uuid, uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|public.discharge_verify_batch(text, uuid, uuid, text) must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.create_stock_transfer_internal(numeric, uuid, uuid, uuid, uuid, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.create_stock_transfer_internal(numeric, uuid, uuid, uuid, uuid, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|public.create_stock_transfer_internal(numeric, uuid, uuid, uuid, uuid, text, text) must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_batch_module_count()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_batch_module_count()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|public.guard_batch_module_count() must be a function nobody outside can call';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('discharge_module_results', 'discharge_channel_assignments', 'discharge_module_splits', 'discharge_module_current_all', 'discharge_batch_status_all', 'discharge_module_rows', 'discharge_status_by_batch')
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5A1_PROOF|anon can read %', v_bad; END IF;
    IF to_regprocedure('public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text)') IS NOT NULL
       OR to_regprocedure('public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A1_PROOF|an old receipt-function signature survived';
    END IF;
    IF has_column_privilege('authenticated', 'public.inbound_batches'::regclass, 'module_count', 'SELECT') IS NOT TRUE THEN
        RAISE EXCEPTION 'MES5A1_PROOF|inbound_batches.module_count is not readable by authenticated (the grant is missing)';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条;三张新表上没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND tablename IN ('discharge_module_results', 'discharge_channel_assignments', 'discharge_module_splits') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|a write policy exists on a new discharge table';
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(三张新表都记,豁免仍是 8);遮蔽零缺口(仍是 105 条);每一张被记录的表的绑定键都是它的主键
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
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
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5A1_PROOF|change-log key is not the primary key on %', v_bad; END IF;

    -- ⑨ 提醒臂 57 → 59;待补的值 17 → 18 支
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|operations_now should have 59 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 18 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|pending_values should have 18 arms';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes5a1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES5A1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes5a1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes5a1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
