-- db/migrations/2026-10-15-mes7a1-equipment-reliability.sql
-- MES-7a-1 —— 设备可靠性:停机原因与来源、设备记录只经函数、MTBF / MTTR;分析证书签发人先过字体(F9);销毁证书从快照渲染(F10)
--   (MES 组的第十六刀,v1.4.52;发布那一行在 docs/handbacks/MES-7a-1.md 的抬头)。由 db/scripts/build_mes7a1_migration.py 从镜像拼出;
--   改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-15:MES-7a Step 0 的 Q1 拆两刀,本刀是前一半;Q3–Q9 · Q18–Q22 · Q24–Q26 照推荐裁定;Q6:记设备的码仍是
--   module.processing.edit,不加仓库)
--   ① downtime_causes(停机原因字典,类别 failure · planned · external,没有 other;引导每一类一行:breakdown · planned_maintenance ·
--      external;被引用之后类别冻住)。equipment_downtime 多两列:cause_code(→ 字典;插入时必填 —— 本刀之前那一行留空,读作"未分类")
--      与 source(manual · device;device 保留,今天每一行都是 manual)。reason 照旧是自由文本的说明。
--   ② 五支函数取代直连写(Q6):open_ · close_ · correct_equipment_downtime · record_equipment_maintenance(可以点名同一台机器、没有作废的
--      一段停机)· save_equipment_service_interval —— 按名拒,不再是约束名。三张表的 INSERT 与 UPDATE 策略拿掉;直连写由
--      guard_equipment_direct_write 按名拒(EQUIPMENT_THROUGH_FUNCTION_ONLY);作废照旧 void_equipment_downtime;停机照旧删不掉;
--      间隔的 DELETE 策略留着(删一条 = 回到「未监控」)。
--   ③ equipment_reliability(Q5):运转小时 = 已提交未冲销的加工单 [开始, 结束) 的并集;一次故障 = 未作废、原因属于 failure 类、开始落在
--      区间里的停机;MTBF = 小时 ÷ 次数,MTTR = 已关上的故障的平均时长;零次故障 / 零小时不给数,给一个状态;区间默认整段记录。
--   ④ F9(Q8):coa_issuer() —— 签发人的唯一一份解析,issue_coa 改调它(同样的拒绝、同样的次序);路由在铸号之前用它过字体。
--   ⑤ F10(Q9):issue_cod 的返回值多一个 snapshot(与写进证书的同一份);路由照它渲染,不再回读。
--   ⑥ 审计:字典段 dictionary_downtime_causes(与别的字典同一个形状;停机的原因与来源在 equipment 主语下说 —— 没有新的记录主语);
--      downtime_causes 进变更记录(豁免仍是 8;没有遮蔽的列)。过时的注释就地更正(停机表注 · 保养表注 · 间隔的公斤列注 · 提交加工单)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;授权一行不动;不写、不改任何一段既有的停机、保养、间隔、资产、加工单、证书、
--   字节档案;不建任何停机、保养、间隔、关联、分析证书或销毁证书;不往任何桶里放对象;不回填(Q94)—— 线上那一段 "Test-1" 停机的原因
--   留空、仍然开着;require_calibrated_since 保持空。线上由本迁移造出的只有:原因字典与它的三行引导、单据例外一行(downtime_causes)、停机的两列(旧行 NULL 与 'manual')。
--
-- 【破窗】(Q21,照推荐接受并写明)旧应用的 /finance/assets/[id] 直连写三张设备表 —— 策略拿掉、原因必填之后,**从旧应用记停机、
--   保养与间隔会失败,直到部署**(旧应用读到的是 EQUIPMENT_THROUGH_FUNCTION_ONLY 那一句)。线上用这条路的只有八月的三行测试数据。
--   分析证书的签发:签名与拒绝不变。销毁证书:issue_cod 多一个返回键,旧路由不读它。代码先行、迁移最后,窗口 ≈ 部署时长。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动,admin 持目录里每一个码(79);在途单据一张不少、一张不多,
--   每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的停机(减掉两列新列)、保养、间隔、资产、加工单、证书、字节档案、
--   申请、员工、职位、公司资料、批次、费用、审批留痕、分录、付款、流水逐字未变;旧的停机每一行原因为空、来源 manual;字典恰好三行引导;
--   三张设备表上没有 INSERT / UPDATE 策略、守卫都在;本事务往变更记录只写了单据例外那一行(字典的引导在绑定之前种下);七支对外的函数员工调得到、
--   五支内层与触发器调不到;anon 能执行的【恰好】两支;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 114);
--   单据登记 59 行、例外 46 行;提醒 66 支、待定值 23 行;298 张表。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES7A1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.downtime_causes') IS NOT NULL
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'equipment_downtime'
                    AND column_name IN ('cause_code', 'source'))
       OR to_regprocedure('public.coa_issuer()') IS NOT NULL
       OR to_regprocedure('public.equipment_reliability(uuid, timestamp with time zone, timestamp with time zone)') IS NOT NULL
       OR to_regprocedure('public.open_equipment_downtime(uuid, timestamp with time zone, text, text, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A1_PRE|MES-7a-1 objects already exist';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public'
          AND tablename IN ('equipment_downtime', 'equipment_maintenance', 'equipment_service_intervals')
          AND cmd IN ('INSERT', 'UPDATE')) <> 6 THEN
        RAISE EXCEPTION 'MES7A1_PRE|expected the six direct INSERT / UPDATE policies on the equipment tables';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES7A1_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 79
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES7A1_PRE|expected a catalogue of 79 codes, all held by admin';
    END IF;
    IF (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'action.issue_coa') IS DISTINCT FROM 'admin,cco' THEN
        RAISE EXCEPTION 'MES7A1_PRE|action.issue_coa is expected to be held by admin and cco';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 59 OR (SELECT count(*) FROM document_type_exceptions) <> 45 THEN
        RAISE EXCEPTION 'MES7A1_PRE|expected 59 document types and 45 exceptions';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 66 THEN
        RAISE EXCEPTION 'MES7A1_PRE|operations_now should have 66 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 23 THEN
        RAISE EXCEPTION 'MES7A1_PRE|pending_values should have 23 arms';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES7A1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES7A1_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 297 THEN
        RAISE EXCEPTION 'MES7A1_PRE|expected 297 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A1_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes7a1_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes7a1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes7a1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes7a1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes7a1_downtime_ids_before ON COMMIT DROP AS
SELECT id FROM equipment_downtime;
CREATE TEMP TABLE mes7a1_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'cause_code' - 'source')::text, '|' ORDER BY (to_jsonb(t) - 'cause_code' - 'source')::text), '')) FROM equipment_downtime t) AS equipment_downtime,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_maintenance t) AS equipment_maintenance,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_service_intervals t) AS equipment_service_intervals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM fixed_assets t) AS fixed_assets,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM fixed_asset_cost_entries t) AS fixed_asset_cost_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM shift_handover_equipment_refs t) AS shift_handover_equipment_refs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM operation_type_equipment t) AS operation_type_equipment,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_runs t) AS processing_runs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_run_events t) AS processing_run_events,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t) AS certificates_of_destruction,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t) AS cod_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_analysis t) AS certificates_of_analysis,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM coa_issues t) AS coa_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM warehouse_requests t) AS warehouse_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t) AS employees,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM positions t) AS positions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM company_profile t) AS company_profile,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t) AS inbound_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t) AS output_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t) AS approval_log,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inventory_movements t) AS inventory_movements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM maintenance_settings t) AS maintenance_settings;

-- ── 1 · 新函数(镜像原样),先于新表与新列:原因类别冻住 · 停机的原因与来源 · 设备表只经函数(三支触发器函数)─────

-- db/functions/guard_downtime_cause_class.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q3):【一种停机原因被引用之后,它的类别冻住】。
--   MTBF / MTTR 读的是原因【此刻】的类别(downtime_causes.class)。若一种已经被停机引用的原因从 planned 改成 failure,
--   过去每一段那样的停机都会悄悄变成一次故障,已经报出去的 MTBF 跟着变 —— 而没有任何一行停机被改过。所以:
--   引用之后改类别按名拒(DOWNTIME_CAUSE_CLASS_LOCKED|<代号>|<已被几段停机引用>);名字、排序、停用、备注照改。
--   要换类别,就新加一种原因。删一种被引用的原因由停机表的外键挡着。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.guard_downtime_cause_class()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n integer;
BEGIN
    IF NEW.code IS DISTINCT FROM OLD.code OR NEW.class IS DISTINCT FROM OLD.class THEN
        SELECT count(*) INTO v_n FROM equipment_downtime d WHERE d.cause_code = OLD.code;
        IF v_n > 0 THEN
            RAISE EXCEPTION 'DOWNTIME_CAUSE_CLASS_LOCKED|%|%', OLD.code, v_n;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_downtime_cause.sql
-- MES-7a-1(2026-10-15,MES-0 Q71;MES-7a Step 0 Q3 · Q4,Tim):【一段新记的停机必须说出原因,而且来源只能是手工】。
--   ① INSERT:cause_code 必填(DOWNTIME_CAUSE_REQUIRED)—— 在【插入】这一刻判,所以本刀之前那一行("Test-1",原因为空)
--      原样留着、读作"未分类";MES-4a 给加工单的开始 / 结束 / 班次立的是同一个先例(INSERT 触发器,不是一条 NOT VALID 的 CHECK)。
--      原因必须是启用着的(DOWNTIME_CAUSE_INACTIVE|<代号>);不存在的代号由外键拒,函数在前面先按名拒(DOWNTIME_CAUSE_UNKNOWN)。
--   ② 来源(Q4):manual · device。device【保留】—— 没有任何控制器的负载格式,也没有转换层,于是今天每一行都是 manual,
--      一行 device 按名拒(DOWNTIME_SOURCE_RESERVED);一行的来源记下之后不改(DOWNTIME_SOURCE_FIXED)。
--   ③ UPDATE:一段已经说出原因的停机不能被改回"没有原因"(DOWNTIME_CAUSE_REQUIRED);改到一种停用的原因也拒。
--      旧的那一行(原因为空)不更正就一直是空 —— 更正它的人必须给它一个原因(correct_equipment_downtime)。
--   【属主路径不放行】这条规矩说的是行,不是门:迁移、fixture、SECURITY DEFINER 的函数插进来的每一行都要有原因。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.guard_downtime_cause()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.cause_code IS NULL THEN
            RAISE EXCEPTION 'DOWNTIME_CAUSE_REQUIRED';
        END IF;
        IF NEW.source IS DISTINCT FROM 'manual' THEN
            RAISE EXCEPTION 'DOWNTIME_SOURCE_RESERVED|%', COALESCE(NEW.source, '?');
        END IF;
    ELSE
        IF NEW.source IS DISTINCT FROM OLD.source THEN
            RAISE EXCEPTION 'DOWNTIME_SOURCE_FIXED|%', OLD.source;
        END IF;
        IF NEW.cause_code IS NULL AND OLD.cause_code IS NOT NULL THEN
            RAISE EXCEPTION 'DOWNTIME_CAUSE_REQUIRED';
        END IF;
        IF NEW.cause_code IS NOT DISTINCT FROM OLD.cause_code THEN
            RETURN NEW;
        END IF;
    END IF;
    IF NEW.cause_code IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM downtime_causes c WHERE c.code = NEW.cause_code AND c.is_active) THEN
        RAISE EXCEPTION 'DOWNTIME_CAUSE_INACTIVE|%', NEW.cause_code;
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_equipment_direct_write.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q6,Tim):【设备的三张表不许绕过函数写】—— 关掉 EQP-2d 登记的"三张表没有 RPC"。
--   停机 · 保养维修 · 保养间隔此前经 PostgREST 直连 + RLS 写(INSERT / UPDATE 策略开在 module.processing.edit 上),
--   拒绝因此是约束名而不是业务码;本刀给它们五支函数 —— open_equipment_downtime · close_equipment_downtime ·
--   correct_equipment_downtime · record_equipment_maintenance · save_equipment_service_interval —— 按名拒,并拿掉直连的
--   INSERT 与 UPDATE 策略。作废停机照旧只经 void_equipment_downtime;资本化照旧只经 record_expense。
--   【为什么还要这一支】策略拿掉之后,直连 INSERT 撞的是一句没有名字的 RLS 违反,直连 UPDATE 是【零行、不报错】(SILENT-1 那一族)。
--   所以挂成【语句级 BEFORE】,零行也照样触发,按名拒 EQUIPMENT_THROUGH_FUNCTION_ONLY|表|动作。
--   挂法:equipment_downtime 与 equipment_service_intervals —— INSERT OR UPDATE(停机的 DELETE 早由 guard_downtime_write 按名拒;
--   间隔的 DELETE 策略刻意留着:删一条间隔 = 回到「未监控」,那是一个正当的决定,见那张表的注释);
--   equipment_maintenance —— INSERT OR UPDATE OR DELETE(干过的活删不掉;此前没有 DELETE 策略时那一句是一次静默的零行)。
--   属主路径(row_security_active = false:SECURITY DEFINER 的函数、迁移、种子、fixture 以 postgres 跑)一律放行。
--   【为什么是 INVOKER】要分出直连写与属主路径;理由与 guard_processing_direct_write 的抬头相同。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.guard_equipment_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'EQUIPMENT_THROUGH_FUNCTION_ONLY|%|%', TG_TABLE_NAME, lower(TG_OP);
END;
$function$;

-- ── 2 · 新表(镜像原样):停机原因字典与它的三行引导 ─────────────────────────────────────────────

-- db/tables/downtime_causes.sql
-- MES-7a-1(2026-10-15,MES-0 Q71;MES-7a Step 0 Q3,Tim):【一段停机,是为什么停的】—— 一张固定的清单,每一种原因属于三类之一:
--   failure(坏了)· planned(计划内的停,例如例行保养)· external(机器之外的原因:停电、缺料、等待)。没有"其它"。
--   ★ 可靠性只认 failure 这一类:MTBF / MTTR 的"一次故障" = 一段未作废、原因属于 failure 的停机(MES-0 Q71)。
--   引导每一类一行,不再更细(breakdown · planned_maintenance · external)—— 工厂自己的原因清单是 Tim / cto 的数据,
--   加一种是加一行(/settings/dictionaries,module.processing.edit)。
--   ★ 没有 other:一段说不出为什么的停机,算不进任何一类,而"其它"会把这张清单变成一个兜底桶(规格 §4.1 对损耗说的同一句话)。
--   ★ 一种原因被停机引用之后,它的类别冻住(guard_downtime_cause_class)—— 改类别会悄悄改写已经算过的 MTBF。要改,就新加一种。
--   RUNTIME CONFIG。读:module.processing.view 或 module.finance.view(与停机表的读策略同一对 —— 资产卡上也要读得出原因的名字)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.downtime_causes (
    code       text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$' AND code <> 'other'),
    class      text NOT NULL CHECK (class IN ('failure', 'planned', 'external')),
    name_en    text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh    text NOT NULL CHECK (btrim(name_zh) <> ''),
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.downtime_causes IS
    'MES-7a-1:停机原因与它的类别(failure · planned · external,没有 other)。可靠性只把 failure 类的停机算作一次故障。引导:breakdown · planned_maintenance · external。被引用之后类别冻住。RUNTIME CONFIG。';

COMMENT ON COLUMN public.downtime_causes.class IS
    'MES-7a-1:这一种原因属于哪一类。failure = 机器坏了(MTBF / MTTR 只数这一类);planned = 计划内的停;external = 机器之外的原因。被一段停机引用之后不可再改(DOWNTIME_CAUSE_CLASS_LOCKED)。';

INSERT INTO public.downtime_causes (code, class, name_en, name_zh, sort_order, notes) VALUES
    ('breakdown', 'failure', 'Breakdown', '故障', 10, 'The machine failed. Counted as a failure for MTBF and MTTR.'),
    ('planned_maintenance', 'planned', 'Planned maintenance', '计划保养', 20, 'A planned stop, such as routine servicing. Not a failure.'),
    ('external', 'external', 'External cause', '外部原因', 30, 'A cause outside the machine: no power, no material, waiting. Not a failure.');

ALTER TABLE public.downtime_causes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "downtime_causes select by permission" ON public.downtime_causes
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text) OR has_permission('module.finance.view'::text));
CREATE POLICY "downtime_causes write by permission" ON public.downtime_causes
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.downtime_causes TO authenticated;
REVOKE ALL ON public.downtime_causes FROM anon;

-- 被引用之后类别冻住(删除由停机表的外键挡着)。
CREATE TRIGGER trg_downtime_causes_class
    BEFORE UPDATE ON public.downtime_causes
    FOR EACH ROW EXECUTE FUNCTION public.guard_downtime_cause_class();

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.downtime_causes
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');

-- 它带 code 列而不是一张单据:登记进 document_type_exceptions(与 db/tables/document_type_exceptions.sql 那一行逐字同一份;fixture 102)
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
    ('downtime_causes',               '停机原因目录(MES-7a-1):code 是原因代号(类别 failure · planned · external),停机记录引用它');

-- ── 3 · 三张设备表(与 db/tables/equipment_*.sql 逐字同一份的列、注释、触发器)──────────────────────────────
--   停机的两列加在末尾(镜像照"后加的列在最后"排);旧行:cause_code 为空("未分类"),source 取默认 'manual'(列默认值,不经触发器 ——
--   这不是回填,是新列在旧行上的值)。三张表各拿掉 INSERT 与 UPDATE 两条策略(Q6);间隔的 DELETE 策略留着。
ALTER TABLE public.equipment_downtime ADD COLUMN
    cause_code   text REFERENCES public.downtime_causes (code);
ALTER TABLE public.equipment_downtime ADD COLUMN
    source       text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'device'));
COMMENT ON TABLE public.equipment_downtime IS 'EQP-2a:一行 = 一台机器【没有在跑】的一段时间。
【开口的那一段是常态,不是例外】ended_at 可空 —— 机器停下来的那一刻就有人记它,
而那时没人知道它什么时候好。所以"已开始、未结束"必须表示得出来。
【一台机器同时只能有一段没结束的停机】uq_equipment_downtime_open 那条部分唯一索引 ——
机器不会同时坏两次。
【本刀不连保养记录】保养/维修记录要到 EQP-2b 才存在,所以这里【一列都不留】。
留一个指向不存在的表的空列,读起来像"忘了填"而不是"还没到"。
**这个缺席是排期,不是疏漏** —— EQP-2b 落地时加那条外键。
【本刀刻意不算可用率,也不算 OEE】记下"机器停了多久"是一个【事实】;
算出"可用率 87%"是一个【判断】,而它的分母没有人选过:
日历小时?排班小时?计划生产小时?三种算出来的是三个数。
★ MES-7a-1(2026-10-15):可靠性的分母【有人定了】(MES-0 Q71,Tim):运转小时 = 这台机器上已提交加工单的 [开始, 结束) 的并集
(加工单从 MES-4a 起记开始 / 结束 / 班次 —— 原文"加工那一族里没有任何开始/结束/班次列"那一句已经不成立);
一次故障 = 一段未作废、原因属于 failure 类的停机(cause_code → downtime_causes)。MTBF / MTTR 由 equipment_reliability() 算,不存。
**可用率与 OEE 仍然不算** —— Q71 只回答了可靠性的分母,可用率的那一个(日历 / 排班 / 计划小时)仍然没有人选过。
【写只经函数】(MES-7a-1,Q6)开 / 关 / 更正走 open_ · close_ · correct_equipment_downtime,作废走 void_equipment_downtime;
直连 INSERT / UPDATE 按名拒(guard_equipment_direct_write),DELETE 一律拒(guard_downtime_write)。';
COMMENT ON COLUMN public.equipment_downtime.cause_code IS 'MES-7a-1:这一段为什么停 —— downtime_causes 的代号(类别 failure · planned · external)。新记的停机必填(插入时判,guard_downtime_cause);本刀之前的行可以为空,读作"未分类",不算故障也不算计划内。';
COMMENT ON COLUMN public.equipment_downtime.source IS 'MES-7a-1:这一行从哪里来 —— manual(人在页面上记的)或 device(保留给将来的控制器;没有负载格式,不建转换层,今天一行都不许是它)。';
DROP POLICY "equipment_downtime insert by permission" ON public.equipment_downtime;
DROP POLICY "equipment_downtime update by permission" ON public.equipment_downtime;
CREATE TRIGGER trg_equipment_downtime_cause
    BEFORE INSERT OR UPDATE ON public.equipment_downtime
    FOR EACH ROW EXECUTE FUNCTION public.guard_downtime_cause();
CREATE TRIGGER trg_equipment_downtime_direct
    BEFORE INSERT OR UPDATE ON public.equipment_downtime
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_equipment_direct_write();

COMMENT ON TABLE public.equipment_maintenance IS
'EQP-2b:一行 = 对一台机器做过的一次活(例行保养 或 修理)。

【这张表【一分钱都不过】—— 而这句话是它最重要的一条】
钱由 record_expense 过,并且只由它过。本表【指着】那笔支出(expense_id),
自己不带任何金额、不写任何分录。
**下一个最容易被提出的要求就是"让这一行带个成本吧"—— 那会开出第二条过账路,
而两条过账路正是这套系统长出两本对不上的账的方式。**
要金额,读它指着的那张支出单。

【两条链接都是可选的,两个方向都是】
* 停机(downtime_id):计划停机里做的保养不造成停机,而一次故障可以在还没有人
  动手之前就被记下来。**有保养不蕴含有停机,有停机也不蕴含有保养。**
* 支出(expense_id):自己人花两小时紧一颗螺丝,没有任何单据。

【资本化是【记录下来的判断】,不是算出来的】
Tim 的规矩有两半:延长寿命或提高产能(人的判断),【并且】花费够大(一个数)。
系统只算得了第二半,所以它只【建议】—— 见 equipment_maintenance_advice,
以及 maintenance_settings 的表注。本表存的是那个【判断】和它的【理由】:
capitalised = true 而没有 capitalisation_reason 的行,表上那条 CHECK 直接拒。

【capitalised_expense_id 现在填得了了 —— CAPEX-1,2026-08-29】
原文说的是"这一列对一台在跑的机器建不出来",理由是 record_expense 一律按名拒
(ASSET_ALREADY_IN_SERVICE)。**那条一律拒已经换成一条窄的**:资产已投用时,
追加成本必须【经由本表的一行】—— 标了 capitalised、写了理由、且还没有资本化过。
条件不满足时按名拒并指路(ASSET_IN_SERVICE_NEEDS_MAINTENANCE /
MAINTENANCE_NOT_CAPITALISED / MAINTENANCE_ALREADY_CAPITALISED 等)。
★【为什么偏偏是这张表】★(Tim 2026-08-24)判断与理由只住在这里,
而"钱要不要进成本"就是那个判断。让支出表单也能独立地做这件事,
等于【两个源头 + 一条优先级规则】—— 一份第二定义披着破平局的外衣。
所以只留一个源头,另一条路按名拒。
写它的是 record_expense 的资本化分支(SECURITY DEFINER)。
★ MES-7a-1 更正:原文"本表没有 UPDATE 策略"在它写下的时候是假的(EQP-2b 给 module.processing.edit 开着一条 UPDATE 策略)。
**MES-7a-1 起它才是真的**:INSERT 与 UPDATE 两条策略都拿掉了,一行保养只经 record_equipment_maintenance 写进来、
capitalised_expense_id 只经 record_expense 写;直连的 INSERT / UPDATE / DELETE 由 guard_equipment_direct_write 按名拒。

【它可以点名它修好的那一段停机】(downtime_id,MES-7a-1 之前没有任何写入方)—— record_equipment_maintenance 只收
【同一台机器】的、【没有作废】的一段(MAINTENANCE_DOWNTIME_OTHER_MACHINE · MAINTENANCE_DOWNTIME_VOIDED)。

【更正的形状:可改 + 留痕,没有历史表 —— 与 equipment_downtime 一致】
成对旧/新的强类型历史(purchase_order_history)是给【会被改单并重新签发给对方的
单据】和【驱动金钱的数字】用的。本表不过账、不寄给任何人,而它的亲兄弟
equipment_downtime(EQP-2a)正是可改 + 留痕。把"这台机器身上发生的事"的两半
做成两种更正形状,才是那个不一致。
**返回条件:资本化判断哪天需要审计轨迹,就抄 purchase_order_history 的形状。**

【调度层读这些行,但它不在这一刀里】保养间隔、下次到期、"逾期"的推导与看板臂
都是 EQP-2c;界面是 EQP-2d。**它们的缺席是排期,不是遗漏。**';
DROP POLICY "equipment_maintenance insert by permission" ON public.equipment_maintenance;
DROP POLICY "equipment_maintenance update by permission" ON public.equipment_maintenance;
CREATE TRIGGER trg_equipment_maintenance_direct
    BEFORE INSERT OR UPDATE OR DELETE ON public.equipment_maintenance
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_equipment_direct_write();

COMMENT ON COLUMN public.equipment_service_intervals.interval_kg IS
'EQP-2c:每处理多少公斤算一轮。判据是【投料】(processing_runs.total_input)——
磨损来自进去的料,不是出来的料。**只有公斤,没有运转小时** —— 当时(EQP-2a)加工这一族里没有任何开始/结束/班次列。
★ MES-7a-1 更正:加工单从 MES-4a 起记开始与结束,运转小时如今推导得出来(equipment_reliability 的分母);
按运转小时配保养间隔仍然没有建 —— 那是一列 interval_hours 与它的推导,等第一份按小时给的保养要求。
可空:与 interval_days 至少说出一个即可(表上那条 num_nonnulls CHECK)。';
DROP POLICY "equipment_service_intervals insert by permission" ON public.equipment_service_intervals;
DROP POLICY "equipment_service_intervals update by permission" ON public.equipment_service_intervals;
CREATE TRIGGER trg_equipment_service_intervals_direct
    BEFORE INSERT OR UPDATE ON public.equipment_service_intervals
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_equipment_direct_write();

-- ── 4 · 新函数(镜像原样),新表与新列之后:两句共用判据 · 五支记录函数 · 可靠性 · 签发人 ─────

-- db/functions/equipment_record_target.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q6 · Q7):【这一条记录要挂的,是不是一台在册的机器】—— 五支设备记录函数共用的一句判据。
--   不存在 → EQUIPMENT_NOT_FOUND|<id>;不是设备类(车、办公电脑)→ EQUIPMENT_NOT_A_MACHINE|<编号>(/operation/equipment 只列设备类,Q7)。
--   返回资产编号,供拒绝的句子用。已处置的机器【不】在这里拒:它在役那几年的停机与保养仍然可以补记、更正。
--   【内层】不是 SECURITY DEFINER、没有调用者检查(调用方都是 DEFINER,以属主身份读 fixed_assets);EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.equipment_record_target(p_equipment_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_fa record;
BEGIN
    SELECT fa.code, fa.category INTO v_fa FROM fixed_assets fa WHERE fa.id = p_equipment_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EQUIPMENT_NOT_FOUND|%', COALESCE(p_equipment_id::text, '?');
    END IF;
    IF v_fa.category IS DISTINCT FROM 'equipment' THEN
        RAISE EXCEPTION 'EQUIPMENT_NOT_A_MACHINE|%', v_fa.code;
    END IF;
    RETURN v_fa.code;
END;
$function$;

-- db/functions/downtime_cause_check.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q3):【这个原因代号能不能用】—— 开一段停机与更正一段停机共用的一句判据。
--   空 → DOWNTIME_CAUSE_REQUIRED;不在清单里 → DOWNTIME_CAUSE_UNKNOWN|<代号>;停用 → DOWNTIME_CAUSE_INACTIVE|<代号>。
--   返回它的类别(failure · planned · external)。表上的 guard_downtime_cause 是同一条规矩的第二道(属主路径也过它)。
--   【内层】EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.downtime_cause_check(p_cause_code text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c record;
BEGIN
    IF p_cause_code IS NULL OR btrim(p_cause_code) = '' THEN
        RAISE EXCEPTION 'DOWNTIME_CAUSE_REQUIRED';
    END IF;
    SELECT c.class, c.is_active INTO v_c FROM downtime_causes c WHERE c.code = p_cause_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOWNTIME_CAUSE_UNKNOWN|%', p_cause_code;
    END IF;
    IF NOT v_c.is_active THEN
        RAISE EXCEPTION 'DOWNTIME_CAUSE_INACTIVE|%', p_cause_code;
    END IF;
    RETURN v_c.class;
END;
$function$;

-- db/functions/open_equipment_downtime.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q3 · Q4 · Q6,Tim):【一台机器停下来了】—— 开一段停机,结束时刻留空(= 还在停)。
--   门 module.processing.edit(记停机的是车间,与 void_equipment_downtime 同一个码;Q6:码不变,仓库不加)。
--   按名拒:不是一台在册的机器(equipment_record_target)· 没有开始时刻(DOWNTIME_START_REQUIRED —— 停机是世界那一侧的事实,
--   不给默认值)· 没有原因代号(DOWNTIME_CAUSE_REQUIRED)· 代号不在清单里(DOWNTIME_CAUSE_UNKNOWN|<代号>)或已停用
--   (DOWNTIME_CAUSE_INACTIVE|<代号>)· 没有说明(DOWNTIME_REASON_REQUIRED —— reason 仍是自由文本的说明,原因代号是分类)·
--   这台机器已经有一段开着的(DOWNTIME_ALREADY_OPEN|<那一段的开始>)。开始时刻在未来、与另一段重叠由 guard_downtime_period 按名拒。
--   来源永远是 manual(Q4:device 保留,没有转换层)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.open_equipment_downtime(p_equipment_id uuid, p_started_at timestamp with time zone, p_cause_code text, p_reason text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code  text;
    v_open  timestamptz;
    v_id    uuid;
BEGIN
    PERFORM require_permission('module.processing.edit');
    v_code := equipment_record_target(p_equipment_id);
    -- 同一台机器的两次开口排队(部分唯一索引是第二道)
    PERFORM 1 FROM fixed_assets fa WHERE fa.id = p_equipment_id FOR UPDATE;
    IF p_started_at IS NULL THEN
        RAISE EXCEPTION 'DOWNTIME_START_REQUIRED';
    END IF;
    PERFORM downtime_cause_check(p_cause_code);
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DOWNTIME_REASON_REQUIRED';
    END IF;
    SELECT d.started_at INTO v_open FROM equipment_downtime d
     WHERE d.equipment_id = p_equipment_id AND d.ended_at IS NULL AND d.voided_at IS NULL;
    IF FOUND THEN
        RAISE EXCEPTION 'DOWNTIME_ALREADY_OPEN|%', to_char(v_open AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    END IF;
    BEGIN
        INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason, notes, cause_code, source, created_by, updated_by)
        VALUES (p_equipment_id, p_started_at, NULL, btrim(p_reason), NULLIF(btrim(COALESCE(p_notes, '')), ''), p_cause_code, 'manual',
                auth.uid(), auth.uid())
        RETURNING id INTO v_id;
    EXCEPTION WHEN unique_violation THEN
        -- 两个人同一刻开(重叠判据的 SELECT 不是并发安全的,部分唯一索引是声明式的兜底):说成同一句,不是一串约束名
        RAISE EXCEPTION 'DOWNTIME_ALREADY_OPEN|%', to_char(p_started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    END;
    RETURN jsonb_build_object('downtime_id', v_id, 'equipment_id', p_equipment_id, 'equipment_code', v_code, 'open', true);
END;
$function$;

-- db/functions/close_equipment_downtime.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q6,Tim):【机器回来了】—— 把开着的那一段停机关上。门 module.processing.edit。
--   按名拒:找不到(DOWNTIME_NOT_FOUND|<id>)· 已作废(DOWNTIME_VOIDED|<开始> —— 作废的那一段没有发生过,不能被"关上")·
--   已经关了(DOWNTIME_ALREADY_CLOSED|<开始>)· 没有结束时刻(DOWNTIME_END_REQUIRED)· 结束早于开始(DOWNTIME_END_BEFORE_START|<开始> ——
--   此前是约束名 equipment_downtime_period_order,现在先按名拒,约束留着做第二道)。结束在未来、与别的一段重叠由 guard_downtime_period 拒。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.close_equipment_downtime(p_downtime_id uuid, p_ended_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_d equipment_downtime%ROWTYPE;
    v_s text;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_d FROM equipment_downtime WHERE id = p_downtime_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOWNTIME_NOT_FOUND|%', COALESCE(p_downtime_id::text, '?');
    END IF;
    v_s := to_char(v_d.started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    IF v_d.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'DOWNTIME_VOIDED|%', v_s;
    END IF;
    IF v_d.ended_at IS NOT NULL THEN
        RAISE EXCEPTION 'DOWNTIME_ALREADY_CLOSED|%', v_s;
    END IF;
    IF p_ended_at IS NULL THEN
        RAISE EXCEPTION 'DOWNTIME_END_REQUIRED';
    END IF;
    IF p_ended_at < v_d.started_at THEN
        RAISE EXCEPTION 'DOWNTIME_END_BEFORE_START|%', v_s;
    END IF;
    UPDATE equipment_downtime SET ended_at = p_ended_at, updated_at = now(), updated_by = auth.uid() WHERE id = p_downtime_id;
    RETURN jsonb_build_object('downtime_id', p_downtime_id, 'equipment_id', v_d.equipment_id, 'open', false);
END;
$function$;

-- db/functions/correct_equipment_downtime.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q3 · Q6,Tim):【更正一段停机】—— 起止时刻、原因代号与说明。门 module.processing.edit。
--   取代 U1-B 的直连 UPDATE(Tim 的 UNBLOCK-1 Q15 说"更正走表上的 UPDATE 策略" —— 那条策略本刀拿掉,更正改走本函数;
--   变更记录照旧留着旧值,因为写的仍是那一行)。作废照旧只经 void_equipment_downtime。
--   【开着的一段不借更正关上,关了的一段不借更正重新打开】开着的那一段只能传空的结束时刻(给了就 DOWNTIME_CORRECT_CANNOT_CLOSE ——
--   关上它走 close_equipment_downtime);关了的那一段必须给结束时刻(DOWNTIME_END_REQUIRED)。
--   【原因代号必填】(Q3)—— 本刀之前那一行原因为空;谁更正它,谁就要给它一个原因(表上的 guard_downtime_cause 同一条)。
--   按名拒:DOWNTIME_NOT_FOUND · DOWNTIME_VOIDED · DOWNTIME_START_REQUIRED · DOWNTIME_END_BEFORE_START · 原因(downtime_cause_check)·
--   DOWNTIME_REASON_REQUIRED · DOWNTIME_NOTHING_CHANGED(什么都没改的一次"更正"不写任何东西,也不说成功)。
--   未来的时刻与重叠由 guard_downtime_period 按名拒。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.correct_equipment_downtime(p_downtime_id uuid, p_started_at timestamp with time zone, p_ended_at timestamp with time zone, p_cause_code text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_d equipment_downtime%ROWTYPE;
    v_s text;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_d FROM equipment_downtime WHERE id = p_downtime_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOWNTIME_NOT_FOUND|%', COALESCE(p_downtime_id::text, '?');
    END IF;
    v_s := to_char(v_d.started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    IF v_d.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'DOWNTIME_VOIDED|%', v_s;
    END IF;
    IF p_started_at IS NULL THEN
        RAISE EXCEPTION 'DOWNTIME_START_REQUIRED';
    END IF;
    IF v_d.ended_at IS NULL AND p_ended_at IS NOT NULL THEN
        RAISE EXCEPTION 'DOWNTIME_CORRECT_CANNOT_CLOSE|%', v_s;
    END IF;
    IF v_d.ended_at IS NOT NULL AND p_ended_at IS NULL THEN
        RAISE EXCEPTION 'DOWNTIME_END_REQUIRED';
    END IF;
    IF p_ended_at IS NOT NULL AND p_ended_at < p_started_at THEN
        RAISE EXCEPTION 'DOWNTIME_END_BEFORE_START|%', to_char(p_started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    END IF;
    PERFORM downtime_cause_check(p_cause_code);
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DOWNTIME_REASON_REQUIRED';
    END IF;
    IF p_started_at = v_d.started_at AND p_ended_at IS NOT DISTINCT FROM v_d.ended_at
       AND p_cause_code IS NOT DISTINCT FROM v_d.cause_code AND btrim(p_reason) = v_d.reason THEN
        RAISE EXCEPTION 'DOWNTIME_NOTHING_CHANGED|%', v_s;
    END IF;
    UPDATE equipment_downtime
       SET started_at = p_started_at, ended_at = p_ended_at, cause_code = p_cause_code, reason = btrim(p_reason),
           updated_at = now(), updated_by = auth.uid()
     WHERE id = p_downtime_id;
    RETURN jsonb_build_object('downtime_id', p_downtime_id, 'equipment_id', v_d.equipment_id, 'corrected', true);
END;
$function$;

-- db/functions/record_equipment_maintenance.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q6,Tim):【记一次保养或维修】—— 取代 EQP-2d 的直连 INSERT。门 module.processing.edit。
--   本表一分钱都不过(表注那一句不变):支出只被【指着】(p_expense_id),资本化的钱照旧只经 record_expense。
--   【可以点名它修好的那一段停机】(equipment_maintenance.downtime_id 此前没有任何写入方、也没有守卫)——
--   只能是【同一台机器】的、【没有作废】的一段:MAINTENANCE_DOWNTIME_OTHER_MACHINE|<那一段的开始>|<那台机器的编号> ·
--   MAINTENANCE_DOWNTIME_VOIDED|<开始> · MAINTENANCE_DOWNTIME_NOT_FOUND|<id>。开着的一段可以点名(修理常在机器回来之前就记下)。
--   其余按名拒(此前是约束名):不是一台在册的机器 · MAINT_DATE_REQUIRED(干活的日期是世界那一侧的事实,不给默认值)·
--   MAINT_KIND_INVALID|<种类> · MAINT_DESCRIPTION_REQUIRED · MAINT_PERFORMER_REQUIRED(谁做的,至少说出一个)·
--   MAINT_PERFORMER_AMBIGUOUS(员工与供应商只能二选一)· MAINT_EMPLOYEE_NOT_FOUND · MAINT_SUPPLIER_NOT_FOUND · MAINT_EXPENSE_NOT_FOUND ·
--   MAINT_REASON_REQUIRED(说要资本化,就得说为什么)。表上的 CHECK 留着,做直连那条路之外的第二道。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.record_equipment_maintenance(p_equipment_id uuid, p_performed_on date, p_kind text, p_description text, p_performed_by_employee_id uuid DEFAULT NULL::uuid, p_performed_by_supplier_id uuid DEFAULT NULL::uuid, p_performed_by_name text DEFAULT NULL::text, p_downtime_id uuid DEFAULT NULL::uuid, p_expense_id uuid DEFAULT NULL::uuid, p_capitalised boolean DEFAULT false, p_capitalisation_reason text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code  text;
    v_name  text := NULLIF(btrim(COALESCE(p_performed_by_name, '')), '');
    v_dt    record;
    v_id    uuid;
BEGIN
    PERFORM require_permission('module.processing.edit');
    v_code := equipment_record_target(p_equipment_id);
    IF p_performed_on IS NULL THEN
        RAISE EXCEPTION 'MAINT_DATE_REQUIRED';
    END IF;
    IF p_kind IS NULL OR p_kind NOT IN ('service', 'repair') THEN
        RAISE EXCEPTION 'MAINT_KIND_INVALID|%', COALESCE(p_kind, '?');
    END IF;
    IF p_description IS NULL OR btrim(p_description) = '' THEN
        RAISE EXCEPTION 'MAINT_DESCRIPTION_REQUIRED';
    END IF;
    IF p_performed_by_employee_id IS NOT NULL AND p_performed_by_supplier_id IS NOT NULL THEN
        RAISE EXCEPTION 'MAINT_PERFORMER_AMBIGUOUS';
    END IF;
    IF p_performed_by_employee_id IS NULL AND p_performed_by_supplier_id IS NULL AND v_name IS NULL THEN
        RAISE EXCEPTION 'MAINT_PERFORMER_REQUIRED';
    END IF;
    IF p_performed_by_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.id = p_performed_by_employee_id) THEN
        RAISE EXCEPTION 'MAINT_EMPLOYEE_NOT_FOUND|%', p_performed_by_employee_id;
    END IF;
    IF p_performed_by_supplier_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM suppliers s WHERE s.id = p_performed_by_supplier_id) THEN
        RAISE EXCEPTION 'MAINT_SUPPLIER_NOT_FOUND|%', p_performed_by_supplier_id;
    END IF;
    IF p_expense_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM expenses x WHERE x.id = p_expense_id) THEN
        RAISE EXCEPTION 'MAINT_EXPENSE_NOT_FOUND|%', p_expense_id;
    END IF;
    IF COALESCE(p_capitalised, false) AND (p_capitalisation_reason IS NULL OR btrim(p_capitalisation_reason) = '') THEN
        RAISE EXCEPTION 'MAINT_REASON_REQUIRED';
    END IF;
    IF p_downtime_id IS NOT NULL THEN
        SELECT d.equipment_id, d.voided_at, d.started_at, fa.code AS machine INTO v_dt
          FROM equipment_downtime d JOIN fixed_assets fa ON fa.id = d.equipment_id WHERE d.id = p_downtime_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'MAINTENANCE_DOWNTIME_NOT_FOUND|%', p_downtime_id;
        END IF;
        IF v_dt.equipment_id <> p_equipment_id THEN
            RAISE EXCEPTION 'MAINTENANCE_DOWNTIME_OTHER_MACHINE|%|%',
                to_char(v_dt.started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI'), v_dt.machine;
        END IF;
        IF v_dt.voided_at IS NOT NULL THEN
            RAISE EXCEPTION 'MAINTENANCE_DOWNTIME_VOIDED|%', to_char(v_dt.started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
        END IF;
    END IF;
    INSERT INTO equipment_maintenance (equipment_id, performed_on, kind, description, performed_by_employee_id,
                                       performed_by_supplier_id, performed_by_name, downtime_id, expense_id, capitalised,
                                       capitalisation_reason, notes, created_by, updated_by)
    VALUES (p_equipment_id, p_performed_on, p_kind, btrim(p_description), p_performed_by_employee_id, p_performed_by_supplier_id,
            v_name, p_downtime_id, p_expense_id, COALESCE(p_capitalised, false),
            CASE WHEN COALESCE(p_capitalised, false) THEN btrim(p_capitalisation_reason) END,
            NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid(), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('maintenance_id', v_id, 'equipment_id', p_equipment_id, 'equipment_code', v_code);
END;
$function$;

-- db/functions/save_equipment_service_interval.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q6,Tim):【存一条保养间隔】(新的,或改一条已有的)—— 取代 EQP-2d 的直连 INSERT / UPDATE。
--   门 module.processing.edit。p_interval_id 为空 = 新加一条;否则改那一条(它必须属于这台机器:INTERVAL_OTHER_MACHINE)。
--   删一条间隔(= 回到「未监控」)仍走表上的 DELETE 策略,不在这里 —— 那张表的注释说明了删行与 ignore 是两件事。
--   按名拒(此前是约束名):不是一台在册的机器 · INTERVAL_NOT_FOUND|<id> · INTERVAL_KIND_INVALID|<种类> · INTERVAL_NOTHING_STATED
--   (公斤与天数至少说出一个)· INTERVAL_VALUE_INVALID|kg 或 days(间隔必须 > 0)· INTERVAL_LEAD_REQUIRED|kg 或 days
--   (给了间隔就要给提前量;0 是一个决定 = 不提前警告)· INTERVAL_LEAD_NOT_BELOW|kg 或 days(提前量在 0 与间隔之间,不含间隔 ——
--   等于间隔是一盏从第一天就亮着的灯)· INTERVAL_DISPOSITION_INVALID|<值> · INTERVAL_ALREADY_SET|<种类>(一台机器一种活一条)。
--   量度为空时它的提前量一并清空(表单上看不见的旧值不许跟着提交)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.save_equipment_service_interval(p_equipment_id uuid, p_interval_id uuid, p_kind text, p_interval_kg numeric, p_lead_kg numeric, p_interval_days integer, p_lead_days integer, p_disposition text DEFAULT 'warn'::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_cur  equipment_service_intervals%ROWTYPE;
    v_lkg  numeric := CASE WHEN p_interval_kg IS NULL THEN NULL ELSE p_lead_kg END;
    v_ldy  integer := CASE WHEN p_interval_days IS NULL THEN NULL ELSE p_lead_days END;
    v_id   uuid;
BEGIN
    PERFORM require_permission('module.processing.edit');
    v_code := equipment_record_target(p_equipment_id);
    IF p_interval_id IS NOT NULL THEN
        SELECT * INTO v_cur FROM equipment_service_intervals WHERE id = p_interval_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INTERVAL_NOT_FOUND|%', p_interval_id;
        END IF;
        IF v_cur.equipment_id <> p_equipment_id THEN
            RAISE EXCEPTION 'INTERVAL_OTHER_MACHINE|%', v_code;
        END IF;
    END IF;
    IF p_kind IS NULL OR p_kind NOT IN ('service', 'repair') THEN
        RAISE EXCEPTION 'INTERVAL_KIND_INVALID|%', COALESCE(p_kind, '?');
    END IF;
    IF p_interval_kg IS NULL AND p_interval_days IS NULL THEN
        RAISE EXCEPTION 'INTERVAL_NOTHING_STATED';
    END IF;
    IF p_interval_kg IS NOT NULL AND p_interval_kg <= 0 THEN
        RAISE EXCEPTION 'INTERVAL_VALUE_INVALID|kg';
    END IF;
    IF p_interval_days IS NOT NULL AND p_interval_days <= 0 THEN
        RAISE EXCEPTION 'INTERVAL_VALUE_INVALID|days';
    END IF;
    IF p_interval_kg IS NOT NULL AND v_lkg IS NULL THEN
        RAISE EXCEPTION 'INTERVAL_LEAD_REQUIRED|kg';
    END IF;
    IF p_interval_days IS NOT NULL AND v_ldy IS NULL THEN
        RAISE EXCEPTION 'INTERVAL_LEAD_REQUIRED|days';
    END IF;
    IF v_lkg IS NOT NULL AND (v_lkg < 0 OR v_lkg >= p_interval_kg) THEN
        RAISE EXCEPTION 'INTERVAL_LEAD_NOT_BELOW|kg';
    END IF;
    IF v_ldy IS NOT NULL AND (v_ldy < 0 OR v_ldy >= p_interval_days) THEN
        RAISE EXCEPTION 'INTERVAL_LEAD_NOT_BELOW|days';
    END IF;
    IF p_disposition IS NULL OR p_disposition NOT IN ('warn', 'ignore') THEN
        RAISE EXCEPTION 'INTERVAL_DISPOSITION_INVALID|%', COALESCE(p_disposition, '?');
    END IF;
    IF EXISTS (SELECT 1 FROM equipment_service_intervals i
                WHERE i.equipment_id = p_equipment_id AND i.kind = p_kind AND i.id IS DISTINCT FROM p_interval_id) THEN
        RAISE EXCEPTION 'INTERVAL_ALREADY_SET|%', p_kind;
    END IF;
    BEGIN
    IF p_interval_id IS NULL THEN
        INSERT INTO equipment_service_intervals (equipment_id, kind, interval_kg, lead_kg, interval_days, lead_days, disposition, notes,
                                                 created_by, updated_by)
        VALUES (p_equipment_id, p_kind, p_interval_kg, v_lkg, p_interval_days, v_ldy, p_disposition,
                NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid(), auth.uid())
        RETURNING id INTO v_id;
    ELSE
        UPDATE equipment_service_intervals
           SET kind = p_kind, interval_kg = p_interval_kg, lead_kg = v_lkg, interval_days = p_interval_days, lead_days = v_ldy,
               disposition = p_disposition, notes = NULLIF(btrim(COALESCE(p_notes, '')), ''), updated_at = now(), updated_by = auth.uid()
         WHERE id = p_interval_id;
        v_id := p_interval_id;
    END IF;
    EXCEPTION WHEN unique_violation THEN
        -- 同一刻两个人给同一种活各加一条(唯一键 one_per_kind 是并发兜底):说成同一句
        RAISE EXCEPTION 'INTERVAL_ALREADY_SET|%', p_kind;
    END;
    RETURN jsonb_build_object('interval_id', v_id, 'equipment_id', p_equipment_id, 'equipment_code', v_code);
END;
$function$;

-- db/functions/equipment_reliability.sql
-- MES-7a-1(2026-10-15,MES-0 Q71;MES-7a Step 0 Q5 · Q19,Tim):【一台机器多久坏一次、坏了多久修好】—— MTBF 与 MTTR,按机器、按区间。
--   ① 运转小时(分母,Q71 · Q5)= 这台机器上【已提交、未冲销】的加工单(status = committed、deleted_at 为空)的 [started_at, ended_at)
--      取【并集】、再与区间相交之后的总长。并集而不是相加:没有任何东西挡住同一台机器上两张单的时段重叠,相加会把重叠的那一段数两遍。
--      没有开始或结束时刻的单不进分母(它们的时长不知道),而它们有几张单独报出来(runs_without_times)。
--   ② 一次故障 = 一段【未作废】、原因属于 failure 类、【开始】落在区间里的停机。计划内与外部原因不算;没有原因的(本刀之前的那一行)
--      读作"未分类",也不算(unclassified_stops 单独报)。开着的一段算一次故障(它确实坏了),但不进 MTTR(还不知道修了多久)。
--   ③ MTBF = 运转小时 ÷ 故障次数。零次故障 → 没有数(mtbf_state = no_failure,页面写"N 小时的运转里没有故障");
--      零运转小时 → 没有数(no_hours,"没有记录到运转小时")—— 两者都不是 0,也不是无穷大。
--   ④ MTTR = 区间里【已经关上】的故障停机的平均时长(小时)。没有关上的故障 → NULL。
--   ⑤ 区间(Q5):p_from / p_to 由页面选;不给 = 这台机器的整段记录 —— 从它的取得日(新加坡时间零点)到此刻。不发明一个窗口。
--   ⑥ 只数停机(Q19):加工单上的 unplanned_stop 事件与停机指标是【一炉之内】的记录,不在这里数(两边都数会把一次停机数两遍)。
--   ⑦ 不算可用率、不算 OEE(Q71 只回答了可靠性的分母)。
--   runs_without_machine:区间里(按加工日)已提交、却没有记机器的单 —— 【全厂】的数,每台机器那一行都一样:它说的是"分母可能不全"。
--   只列设备类资产(Q7)。门 module.processing.view;不持的读者按名拒,不是零行(零行与"没有机器"分不开)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.equipment_reliability(p_equipment_id uuid DEFAULT NULL::uuid, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS TABLE(equipment_id uuid, equipment_code text, equipment_description text, equipment_status text, range_from timestamp with time zone, range_to timestamp with time zone, operating_hours numeric, runs_counted integer, runs_without_times integer, runs_without_machine integer, failures integer, failures_open integer, mtbf_hours numeric, mtbf_state text, mttr_hours numeric, repairs_closed integer, planned_stops integer, external_stops integer, unclassified_stops integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
    PERFORM require_permission('module.processing.view');
    IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_from >= p_to THEN
        RAISE EXCEPTION 'RELIABILITY_RANGE_INVALID|%|%',
            to_char(p_from AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI'), to_char(p_to AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    END IF;
    RETURN QUERY
    WITH m AS (
        SELECT fa.id, fa.code, fa.description, fa.status,
               COALESCE(p_from, (fa.acquisition_date::timestamp AT TIME ZONE 'Asia/Singapore')) AS f,
               COALESCE(p_to, now()) AS t
          FROM fixed_assets fa
         WHERE fa.category = 'equipment' AND (p_equipment_id IS NULL OR fa.id = p_equipment_id)
    ), w AS (
        -- 取得日在此刻之后(一台还没到的机器)= 一段空区间:一行照给,运转小时 0
        SELECT m.*, tstzrange(LEAST(m.f, m.t), m.t, '[)') AS win,
               (m.f AT TIME ZONE 'Asia/Singapore')::date AS d_from, (m.t AT TIME ZONE 'Asia/Singapore')::date AS d_to
          FROM m
    ), hrs AS (
        SELECT w.id,
               COALESCE((SELECT sum(EXTRACT(EPOCH FROM (upper(x) - lower(x))))
                           FROM unnest((SELECT range_agg(tstzrange(pr.started_at, pr.ended_at, '[)') * w.win)
                                          FROM processing_runs pr
                                         WHERE pr.equipment_id = w.id AND pr.status = 'committed' AND pr.deleted_at IS NULL
                                           AND pr.started_at IS NOT NULL AND pr.ended_at IS NOT NULL
                                           AND tstzrange(pr.started_at, pr.ended_at, '[)') && w.win)) x), 0) / 3600.0 AS op_h,
               (SELECT count(*) FROM processing_runs pr
                 WHERE pr.equipment_id = w.id AND pr.status = 'committed' AND pr.deleted_at IS NULL
                   AND pr.started_at IS NOT NULL AND pr.ended_at IS NOT NULL
                   AND tstzrange(pr.started_at, pr.ended_at, '[)') && w.win)::int AS n_runs,
               (SELECT count(*) FROM processing_runs pr
                 WHERE pr.equipment_id = w.id AND pr.status = 'committed' AND pr.deleted_at IS NULL
                   AND (pr.started_at IS NULL OR pr.ended_at IS NULL)
                   AND pr.process_date BETWEEN w.d_from AND w.d_to)::int AS n_no_times,
               (SELECT count(*) FROM processing_runs pr
                 WHERE pr.equipment_id IS NULL AND pr.status = 'committed' AND pr.deleted_at IS NULL
                   AND pr.process_date BETWEEN w.d_from AND w.d_to)::int AS n_no_machine
          FROM w
    ), dt AS (
        SELECT w.id,
               count(*) FILTER (WHERE c.class = 'failure')::int AS n_fail,
               count(*) FILTER (WHERE c.class = 'failure' AND d.ended_at IS NULL)::int AS n_fail_open,
               count(*) FILTER (WHERE c.class = 'failure' AND d.ended_at IS NOT NULL)::int AS n_fail_closed,
               avg(EXTRACT(EPOCH FROM (d.ended_at - d.started_at))) FILTER (WHERE c.class = 'failure' AND d.ended_at IS NOT NULL) / 3600.0
                   AS mttr_h,
               count(*) FILTER (WHERE c.class = 'planned')::int AS n_planned,
               count(*) FILTER (WHERE c.class = 'external')::int AS n_external,
               count(*) FILTER (WHERE d.id IS NOT NULL AND d.cause_code IS NULL)::int AS n_unclassified
          FROM w
          LEFT JOIN equipment_downtime d ON d.equipment_id = w.id AND d.voided_at IS NULL
                                        AND d.started_at >= w.f AND d.started_at < w.t
          LEFT JOIN downtime_causes c ON c.code = d.cause_code
         GROUP BY w.id
    )
    SELECT w.id, w.code, w.description, w.status, w.f, w.t,
           round(h.op_h, 2), h.n_runs, h.n_no_times, h.n_no_machine,
           dt.n_fail, dt.n_fail_open,
           CASE WHEN h.op_h > 0 AND dt.n_fail > 0 THEN round(h.op_h / dt.n_fail, 2) END,
           CASE WHEN h.op_h = 0 THEN 'no_hours' WHEN dt.n_fail = 0 THEN 'no_failure' ELSE 'value' END,
           round(dt.mttr_h, 2), dt.n_fail_closed, dt.n_planned, dt.n_external, dt.n_unclassified
      FROM w JOIN hrs h ON h.id = w.id JOIN dt ON dt.id = w.id
     ORDER BY w.code;
END;
$function$;

-- db/functions/coa_issuer.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q8 · F9,Tim):【这个账号签发一张分析证书时,纸上会印成谁】—— 签发人的【唯一】一份解析。
--   issue_coa 用它决定快照里的 issuer;PDF 路由在【铸号之前】用它把名字与职位填进字体覆盖检查(MES6B2-ISSUED-WITHOUT-BYTES 漏掉的那一格:
--   此前名字与职位要到签发那一刻才进快照,于是一个纸上画不出来的字会在号已铸之后才让渲染失败);批次页的签发表单用它说出
--   "You will be named as <名字>, <职位>"。一份实现,三个读者。
--   名字 = 这个账号的员工(current_user_employee:主账号或 employee_accounts)的常用名、否则法定名;职位 = 他的 positions.title。
--   不是员工 → COA_ISSUER_NOT_AN_EMPLOYEE;没有职位 → COA_ISSUER_POSITION_MISSING|<名字>(与 issue_coa 原来那两句逐字相同,次序也相同)。
--   门 action.issue_coa(只有签发的人需要知道自己会被印成谁;不持码的人在 issue_coa 那里按码拒,不在这里被告知一个名字)。
--   返回 {employee_id, name, position}。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql (the resolution moved here from issue_coa).

CREATE OR REPLACE FUNCTION public.coa_issuer()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp      uuid;
    v_name     text;
    v_position text;
BEGIN
    PERFORM require_permission('action.issue_coa');
    v_emp := current_user_employee();
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'COA_ISSUER_NOT_AN_EMPLOYEE';
    END IF;
    SELECT COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name), NULLIF(btrim(p.title), '')
      INTO v_name, v_position
      FROM employees e LEFT JOIN positions p ON p.id = e.position_id
     WHERE e.id = v_emp;
    IF v_position IS NULL THEN
        RAISE EXCEPTION 'COA_ISSUER_POSITION_MISSING|%', v_name;
    END IF;
    RETURN jsonb_build_object('employee_id', v_emp, 'name', v_name, 'position', v_position);
END;
$function$;

-- ── 5 · 换掉的函数(镜像原样,同签名):签发分析证书改调 coa_issuer · 签发销毁证书多返回 snapshot · 审计主语多一本字典 · 提交加工单的一句注释 ─

-- db/functions/issue_coa.sql
-- MES-6b-2(2026-10-15,MES-0 Q67 · Q68 · Q90;MES-6b Step 0 Q10–Q13 · Q29–Q32,Tim):【签发一张分析证书】—— 铸号、组装、冻住,一笔事务。
--   门 action.issue_coa(cco · admin)。
--   ① 拒绝清单 coa_issue_blockers 的第一句原样抛出(没有最终化验 · 质量暂扣 · 开着的争议 · 称重不在校准期内 · 点名的单越限而没被接受 ·
--      单不是这一批的 · 这一批 × 这张单已有一张活证书 · 公司名没录)—— 与批次页摆出来的是同一份判据。
--   ② 签发人(Q13):纸上印「Issued by <名字>, <职位>」与签发时刻,不放签名图片。★ MES-7a-1(F9):解析搬进 coa_issuer() ——
--      PDF 路由在铸号之前、批次页的签发表单在按下之前问的是同一支,所以三处说的是同一个人。名字 = 员工的常用名、否则法定名;
--      职位 = positions.title。不是员工 → COA_ISSUER_NOT_AN_EMPLOYEE;没有职位 → COA_ISSUER_POSITION_MISSING|<名字>
--      (纸上不印半句,与 COMPANY_LEGAL_NAME_MISSING 同一条:缺一格就按名拒,不印空白)。次序不变:拒绝清单之后、铸号之前。
--   ③ 号 next_coa_code(按年无洞);快照 = coa_assemble 的那一份 + certificate(号、签发时刻)+ issuer(名字、职位)——
--      【由库组装一次,不收调用者递进来的一份】,PDF 只从它渲染(Q31)。
--   ④ 这一批 × 这张单(或不点名)最近作废、还没有替代品的那一张,replaced_by_coa_id 指向这一张(Q32)。
--   返回 {coa_id, code, status, issued_at, replaces, snapshot} —— 路由拿 snapshot 渲染,不再回读。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.issue_coa(p_output_batch_id uuid, p_sales_order_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_block    text[];
    v_issuer   jsonb;
    v_code     text;
    v_now      timestamptz;
    v_snap     jsonb;
    v_id       uuid := gen_random_uuid();
    v_replaces text;
BEGIN
    PERFORM require_permission('action.issue_coa');
    -- 同一批的两次签发排队(唯一索引是第二道)
    PERFORM 1 FROM output_batches b WHERE b.id = p_output_batch_id FOR UPDATE;

    v_block := coa_issue_blockers(p_output_batch_id, p_sales_order_id);
    IF cardinality(v_block) > 0 THEN
        RAISE EXCEPTION '%', v_block[1];
    END IF;

    v_issuer := coa_issuer();

    v_code := next_coa_code();
    v_now := clock_timestamp();
    v_snap := coa_assemble(p_output_batch_id, p_sales_order_id)
        || jsonb_build_object('certificate', jsonb_build_object('id', v_id, 'code', v_code, 'status', 'issued', 'issued_at', v_now),
                              'issuer', jsonb_build_object('name', v_issuer ->> 'name', 'position', v_issuer ->> 'position'));

    INSERT INTO certificates_of_analysis (id, code, output_batch_id, sales_order_id, governing_assay_id, status,
                                          issued_at, issued_by, snapshot)
    VALUES (v_id, v_code, p_output_batch_id, p_sales_order_id, (v_snap -> 'assay' ->> 'id')::uuid, 'issued',
            v_now, auth.uid(), v_snap);

    UPDATE certificates_of_analysis c SET replaced_by_coa_id = v_id
     WHERE c.id = (SELECT x.id FROM certificates_of_analysis x
                    WHERE x.output_batch_id = p_output_batch_id AND x.sales_order_id IS NOT DISTINCT FROM p_sales_order_id
                      AND x.status = 'void' AND x.replaced_by_coa_id IS NULL AND x.id <> v_id
                    ORDER BY x.voided_at DESC, x.code DESC
                    LIMIT 1)
    RETURNING c.code INTO v_replaces;

    RETURN jsonb_build_object('coa_id', v_id, 'code', v_code, 'status', 'issued', 'issued_at', v_now,
                              'replaces', v_replaces, 'snapshot', v_snap);
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

    -- ★ MES-7a-1(F10):返回值多一个 snapshot —— 与写进 certificates_of_destruction.snapshot 的【同一份】。PDF 路由照它渲染,
    --   不再在签发之后回读活数据(此前那一次 cod_certificate_data 是 known-issues MES6B1-COD-PDF-RENDERS-LIVE 登记的那一处)。
    --   加一个键是兼容的:旧的路由不读它。
    RETURN jsonb_build_object(
        'cod_id', v_cod.id, 'code', v_code, 'status', 'issued',
        'verification_token', v_token, 'issued_at', v_now,
        'batch_code', v_data->'inbound_batch'->>'code',
        'snapshot', v_data);
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
-- MES-5a-2(2026-10-08,MES-5a Step 0 Q31,Tim):
--   electricity_allocation → /finance/electricity/[id]   requireModule(MOD.finance) = module.finance.view
--                     成员 electricity_allocation_lines(一炉一行;它在加工单上也出现,但家在这里)。金额由 change_log_mask_rules 遮(data.view_prices)。
--                     MES-5b-2:成员加 electricity_allocation_reversals(一张单最多一行;它在它覆盖过的每一炉上也出现,家在这里)。
-- MES-5b-3(2026-10-09):
--   blending_plan   → /operation/blending/[id]         requireModule(MOD.processing)  = module.processing.view
--                     成员 blending_plan_targets(目标品位)与 blending_plan_lines(候选批次),都住在这里。没有金额,不遮。
--                     (MES-5b-2 也把 operation_type_output_forms 挂到 operation_type 下 —— V37 的改动从此在工序页自己的审计记录上。)
--   electricity_settings   → /finance/electricity 上的 V25 那一块  module.finance.view;单行设置作根(M5)
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q39):
--   sample          → /quality/samples/[id]          requireFunction(FN.qualitySamples) = module.quality.view
--                     成员 sample_events(保管记录,住在这里)。样品与它的保管记录也出现在它那一批的记录上(进料 / 产出主语,家不在那里)。
--   assay_dispute   → /quality/disputes/[id]         requireFunction(FN.qualityDisputes) = module.quality.view。没有成员;也出现在它那一批的记录上。
--   quality_settings → /quality/samples 上的 V16 那一块   module.quality.view;单行设置作根(electricity_settings 的先例)
-- MES-6b-1(2026-10-15,MES-6b Step 0 Q39):
--   ncr             → /quality/ncr/[id]              requireFunction(FN.qualityNcr) = module.quality.view。没有成员;也出现在它那一批的记录上
--                     (进料 / 产出主语,家不在那里)。质量验收限住在合同下(contract 的成员),判定住在产出批下。
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
        -- MES-4b(2026-10-07,MES-4b Step 0 Q3 · Q21):电芯结构字典与交叉污染流字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries)。
        ('dictionary_cell_constructions', ARRAY['module.processing.view'], 'cell_constructions', 'code', 'collection', NULL),
        ('dictionary_contamination_streams', ARRAY['module.processing.view'], 'contamination_streams', 'code', 'collection', NULL),
        -- MES-7a-1(2026-10-15,MES-7a Step 0 Q20):停机原因字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries)。
        --   【不是一个新的记录主语】一段停机的原因与来源照旧在 equipment 主语下说(停机是那一页的成员);这一行只是字典那一段的记录。
        ('dictionary_downtime_causes', ARRAY['module.processing.view'], 'downtime_causes', 'code', 'collection', NULL),
        -- MES-6a-2(2026-10-10,MES-6a Step 0 Q3 · Q39):化验指标字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries;读与那一节同一个码)。
        ('dictionary_assay_indicators', ARRAY['module.materials.view'], 'assay_indicators', 'code', 'collection', NULL),
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
        ('weighbridge_ticket',  ARRAY['module.inbound.view', 'module.logistics.view'], 'weighbridge_tickets', 'id', 'table', NULL),
        -- MES-5a-2(2026-10-08,MES-5a Step 0 Q31):一张电费单的分摊(/finance/electricity/[id],财务查看码)· 分摊的设定(V25,单行设置作根)
        ('electricity_allocation', ARRAY['module.finance.view'],  'electricity_allocations', 'id', 'table', NULL),
        ('electricity_settings',   ARRAY['module.finance.view'],  'electricity_settings',    'id', 'table', NULL),
        -- MES-5b-3(2026-10-09,MES-5b Step 0 Q32 · Q35):一份配料计划(/operation/blending/[id],加工查看码 —— 与表的读策略同一个)
        ('blending_plan',          ARRAY['module.processing.view'], 'blending_plans',        'id', 'table', NULL),
        -- MES-6a-1(2026-10-09,MES-6a Step 0 Q39):一份样品 · 一件化验争议(质量查看码 —— 页面的门;行再过一次它自己那张表的读规则)·
        --   质量的设定(V16,单行设置作根)
        ('sample',                 ARRAY['module.quality.view'],   'samples',               'id', 'table', NULL),
        ('assay_dispute',          ARRAY['module.quality.view'],   'assay_disputes',        'id', 'table', NULL),
        ('quality_settings',       ARRAY['module.quality.view'],   'quality_settings',      'id', 'table', NULL),
        -- MES-6b-1(2026-10-15,MES-6b Step 0 Q39):一张不合格报告(质量查看码 —— 页面的门;行再过一次它自己那张表的读规则)
        ('ncr',                    ARRAY['module.quality.view'],   'nonconformance_reports', 'id', 'table', NULL),
        -- MES-6b-2(2026-10-15,MES-6b Step 0 Q38 · Q39):一张分析证书(/quality/coa/[id];产出查看码 —— 与证书表的读策略同一个,Q30)
        ('coa',                    ARRAY['module.output.view'],    'certificates_of_analysis', 'id', 'table', NULL)
    ) AS s(subject, view_codes, root_table, root_key, root_rule, root_columns);
$function$;

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
    --   (2) 而那需要一条【工序 ↔ 资产】的关联 —— 写下这段时库里没有这条关联(那是当时真正的前置缺口,
    --       记在 docs/processing-support-as-built.md);★ MES-7a-1 更正:MES-4a 建了它(operation_type_equipment,见下一段)。
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

-- ── 6 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份;字典的引导在这之前种下,所以不进变更记录)──
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.downtime_causes
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.downtime_causes
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 7 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.open_equipment_downtime(uuid, timestamp with time zone, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.open_equipment_downtime(uuid, timestamp with time zone, text, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.close_equipment_downtime(uuid, timestamp with time zone) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.close_equipment_downtime(uuid, timestamp with time zone) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.correct_equipment_downtime(uuid, timestamp with time zone, timestamp with time zone, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_equipment_downtime(uuid, timestamp with time zone, timestamp with time zone, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_equipment_maintenance(uuid, date, text, text, uuid, uuid, text, uuid, uuid, boolean, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_equipment_maintenance(uuid, date, text, text, uuid, uuid, text, uuid, uuid, boolean, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.save_equipment_service_interval(uuid, uuid, text, numeric, numeric, integer, integer, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_equipment_service_interval(uuid, uuid, text, numeric, numeric, integer, integer, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.equipment_reliability(uuid, timestamp with time zone, timestamp with time zone) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.equipment_reliability(uuid, timestamp with time zone, timestamp with time zone) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.coa_issuer() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.coa_issuer() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_downtime_cause() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_downtime_cause() TO service_role;
REVOKE EXECUTE ON FUNCTION public.guard_downtime_cause() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_downtime_cause_class() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_downtime_cause_class() TO service_role;
REVOKE EXECUTE ON FUNCTION public.guard_downtime_cause_class() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_equipment_direct_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_equipment_direct_write() TO service_role;
REVOKE EXECUTE ON FUNCTION public.guard_equipment_direct_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.equipment_record_target(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.equipment_record_target(uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.equipment_record_target(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.downtime_cause_check(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.downtime_cause_check(text) TO service_role;
REVOKE EXECUTE ON FUNCTION public.downtime_cause_check(text) FROM authenticated;

-- ── 8 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes7a1_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes7a1_pending_after ON COMMIT DROP AS
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
    -- ① 授权一行没动;admin 持目录里每一个码(79);action.issue_coa 仍是 admin 与 cco
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes7a1_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM mes7a1_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A1_PROOF|a grant changed: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM permissions) <> 79
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES7A1_PROOF|admin does not hold every one of the 79 codes';
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES7A1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes7a1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes7a1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES7A1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变(停机比对时减掉两列新列);旧停机原因为空、来源 manual;没有新停机
    IF EXISTS ((SELECT b.k, b.id FROM mes7a1_pending_before b EXCEPT SELECT a.k, a.id FROM mes7a1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes7a1_pending_after a EXCEPT SELECT b.k, b.id FROM mes7a1_pending_before b)) THEN
        RAISE EXCEPTION 'MES7A1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'cause_code' - 'source')::text, '|' ORDER BY (to_jsonb(t) - 'cause_code' - 'source')::text), '')) FROM equipment_downtime t) IS DISTINCT FROM (SELECT equipment_downtime FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_maintenance t) IS DISTINCT FROM (SELECT equipment_maintenance FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_service_intervals t) IS DISTINCT FROM (SELECT equipment_service_intervals FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM fixed_assets t) IS DISTINCT FROM (SELECT fixed_assets FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM fixed_asset_cost_entries t) IS DISTINCT FROM (SELECT fixed_asset_cost_entries FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM shift_handover_equipment_refs t) IS DISTINCT FROM (SELECT shift_handover_equipment_refs FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM operation_type_equipment t) IS DISTINCT FROM (SELECT operation_type_equipment FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_runs t) IS DISTINCT FROM (SELECT processing_runs FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_run_events t) IS DISTINCT FROM (SELECT processing_run_events FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t) IS DISTINCT FROM (SELECT certificates_of_destruction FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t) IS DISTINCT FROM (SELECT cod_issues FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_analysis t) IS DISTINCT FROM (SELECT certificates_of_analysis FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM coa_issues t) IS DISTINCT FROM (SELECT coa_issues FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM warehouse_requests t) IS DISTINCT FROM (SELECT warehouse_requests FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t) IS DISTINCT FROM (SELECT employees FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM positions t) IS DISTINCT FROM (SELECT positions FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM company_profile t) IS DISTINCT FROM (SELECT company_profile FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t) IS DISTINCT FROM (SELECT inbound_batches FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t) IS DISTINCT FROM (SELECT output_batches FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t) IS DISTINCT FROM (SELECT expenses FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t) IS DISTINCT FROM (SELECT approval_log FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t) IS DISTINCT FROM (SELECT journal_entries FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t) IS DISTINCT FROM (SELECT journal_lines FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t) IS DISTINCT FROM (SELECT payments FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inventory_movements t) IS DISTINCT FROM (SELECT inventory_movements FROM mes7a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM maintenance_settings t) IS DISTINCT FROM (SELECT maintenance_settings FROM mes7a1_rows_before) THEN
        RAISE EXCEPTION 'MES7A1_PROOF|a pre-existing downtime, maintenance, interval, asset, run, certificate, byte record, request, employee, position, company, batch, expense, approval, journal, payment or movement changed';
    END IF;
    IF EXISTS (SELECT 1 FROM equipment_downtime WHERE cause_code IS NOT NULL OR source <> 'manual')
       OR EXISTS (SELECT id FROM equipment_downtime EXCEPT SELECT id FROM mes7a1_downtime_ids_before) THEN
        RAISE EXCEPTION 'MES7A1_PROOF|existing downtime must stay unclassified and manual, and none may be added';
    END IF;

    -- ④ 字典恰好三行引导,每一类一行
    IF (SELECT string_agg(code || ':' || class, ',' ORDER BY code) FROM downtime_causes)
         IS DISTINCT FROM 'breakdown:failure,external:external,planned_maintenance:planned' THEN
        RAISE EXCEPTION 'MES7A1_PROOF|downtime_causes must hold exactly the three seeded causes';
    END IF;

    -- ⑤ 三张设备表上没有 INSERT / UPDATE 策略;读策略在;间隔的 DELETE 策略在;守卫都在
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND tablename IN ('equipment_downtime', 'equipment_maintenance', 'equipment_service_intervals')
                 AND cmd IN ('INSERT', 'UPDATE', 'ALL')) THEN
        RAISE EXCEPTION 'MES7A1_PROOF|a direct write policy remains on an equipment table';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public'
          AND tablename IN ('equipment_downtime', 'equipment_maintenance', 'equipment_service_intervals') AND cmd = 'SELECT') <> 3
       OR NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'equipment_service_intervals' AND cmd = 'DELETE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|the read policies and the interval delete policy must remain';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_equipment_downtime_cause' AND tgrelid = 'public.equipment_downtime'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_equipment_downtime_direct' AND tgrelid = 'public.equipment_downtime'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_equipment_downtime_period' AND tgrelid = 'public.equipment_downtime'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_equipment_downtime_write' AND tgrelid = 'public.equipment_downtime'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_equipment_downtime_no_delete' AND tgrelid = 'public.equipment_downtime'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_equipment_maintenance_direct' AND tgrelid = 'public.equipment_maintenance'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_equipment_service_intervals_direct' AND tgrelid = 'public.equipment_service_intervals'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_downtime_causes_class' AND tgrelid = 'public.downtime_causes'::regclass) THEN
        RAISE EXCEPTION 'MES7A1_PROOF|a guard trigger is missing';
    END IF;

    -- ⑥ 本事务没有往变更记录写一行(按 txid 认 —— 同一时刻同事们在线上的写不算在本刀头上);require_calibrated_since 仍空
    SELECT string_agg(c.table_name || ':' || c.op, ', ' ORDER BY c.seq) INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes7a1_log_before), 0) AND c.txid = txid_current();
    IF v_bad IS DISTINCT FROM 'document_type_exceptions:INSERT' THEN
        RAISE EXCEPTION 'MES7A1_PROOF|change_log rows of this transaction: % (expected only the one exception row)', v_bad;
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A1_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑦ 结构:单据登记 59 行、例外 46 行;提醒 66 支、待定值 23 行;298 张表;字典段在册;销毁证书一张没动
    IF (SELECT count(*) FROM document_types) <> 59 OR (SELECT count(*) FROM document_type_exceptions) <> 46
       OR NOT EXISTS (SELECT 1 FROM document_type_exceptions WHERE table_name = 'downtime_causes') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|document_types should stay 59 and exceptions be 46 with downtime_causes';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 66
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 23 THEN
        RAISE EXCEPTION 'MES7A1_PROOF|operations_now should have 66 arms and pending_values 23';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 298 THEN
        RAISE EXCEPTION 'MES7A1_PROOF|expected 298 public tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'dictionary_downtime_causes') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|trail subject dictionary_downtime_causes is not registered';
    END IF;

    -- ⑧ 函数面:七支员工调得到;五支内层与触发器调不到;anon 能执行的【恰好】两支;新表 anon 读不到
    IF NOT has_function_privilege('authenticated', 'public.open_equipment_downtime(uuid, timestamp with time zone, text, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.open_equipment_downtime(uuid, timestamp with time zone, text, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|public.open_equipment_downtime(uuid, timestamp with time zone, text, text, text) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.close_equipment_downtime(uuid, timestamp with time zone)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.close_equipment_downtime(uuid, timestamp with time zone)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|public.close_equipment_downtime(uuid, timestamp with time zone) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.correct_equipment_downtime(uuid, timestamp with time zone, timestamp with time zone, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.correct_equipment_downtime(uuid, timestamp with time zone, timestamp with time zone, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|public.correct_equipment_downtime(uuid, timestamp with time zone, timestamp with time zone, text, text) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.record_equipment_maintenance(uuid, date, text, text, uuid, uuid, text, uuid, uuid, boolean, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_equipment_maintenance(uuid, date, text, text, uuid, uuid, text, uuid, uuid, boolean, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|public.record_equipment_maintenance(uuid, date, text, text, uuid, uuid, text, uuid, uuid, boolean, text, text) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.save_equipment_service_interval(uuid, uuid, text, numeric, numeric, integer, integer, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.save_equipment_service_interval(uuid, uuid, text, numeric, numeric, integer, integer, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|public.save_equipment_service_interval(uuid, uuid, text, numeric, numeric, integer, integer, text, text) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.equipment_reliability(uuid, timestamp with time zone, timestamp with time zone)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.equipment_reliability(uuid, timestamp with time zone, timestamp with time zone)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|public.equipment_reliability(uuid, timestamp with time zone, timestamp with time zone) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.coa_issuer()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.coa_issuer()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|public.coa_issuer() must be callable by staff and not by anon';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_downtime_cause()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_downtime_cause()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|public.guard_downtime_cause() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_downtime_cause_class()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_downtime_cause_class()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|public.guard_downtime_cause_class() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_equipment_direct_write()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_equipment_direct_write()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|public.guard_equipment_direct_write() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.equipment_record_target(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.equipment_record_target(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|public.equipment_record_target(uuid) must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.downtime_cause_check(text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.downtime_cause_check(text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|public.downtime_cause_check(text) must be a function nobody outside can call';
    END IF;
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES7A1_PROOF|anon executes: %', v_bad;
    END IF;
    IF has_table_privilege('anon', 'public.downtime_causes'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|anon reads downtime_causes';
    END IF;

    -- ⑨ 那 44 条开着的读策略还是 44 条
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES7A1_PROOF|the open read policies are no longer 44';
    END IF;

    -- ⑩ 变更记录:覆盖零缺口(字典记,豁免仍是 8);遮蔽零缺口(规则仍是 114 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES7A1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES7A1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑪ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes7a1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES7A1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes7a1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES7A1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes7a1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
