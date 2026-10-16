-- db/migrations/2026-10-16-mes7b1-incidents.sql
-- MES-7b-1 —— 事故登记簿:一个新的「安全」区记事故(INC-…)—— 热失控、起火、气体与粉尘释放、工伤、未遂与排放超标 —— 发生了什么、当场做了什么;
--   受伤的细节只给读得到健康数据的人与受伤的那名员工本人;一件事故可以链上它碰过的批次、一段停机、一条异常事件与一次交接班;
--   一件要向 NEA 通报的事故挂着提醒直到记下通报,并显示书面报告的期限(V19,仍标"未确认")。
--   (MES 组的第十八刀,v1.4.54;发布那一行在 docs/handbacks/MES-7b-1.md 的抬头。)由 db/scripts/build_mes7b1_migration.py 从镜像拼出;
--   改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-16:MES-7b Step 0 —— Q1 拆两刀,本刀是 7b-1;Q6 · Q11 · Q12 · Q25 Tim 自己的话;其余属于本刀的照推荐)
--   ① 码(Q2):module.safety.view → 每一个持 module.processing.view 的角色;module.safety.edit → admin · cto · warehouse。没有新的动作码。
--      data.view_health 的描述多一句"事故的受伤细节";它【不】授给任何新角色(Q6)。
--   ② 六张新表:incident_kinds(七种,没有 other;用过的代号冻住)· incidents(INC- 按年无洞;写下就不改;受伤的四样细节 + 受伤的人
--      列授权收回、只经 incidents_masked 读)· incident_updates(通报 / 书面报告 / 关闭 / 带理由的更正,只追加)· incident_batches(人确认的
--      批次链接,解链接要理由)· safety_settings(单行:V19 = 2,未确认 —— Q11)· shift_handover_incident_refs(交接班指着事故,Q12)。
--   ③ 函数:record_incident · record_incident_update · suggest_incident_batches · link_ / unlink_incident_batch · set_safety_settings ·
--      business_days_after(工作日,读公共假期表;缺日历返回空)· next_incident_code · 四支守卫;来源 device 保留并按名拒(Q5)。
--   ④ 不合格报告多一种来源 incident 与一列 incident_id(Q8):open_ncr / ncr_open_internal 末尾多一个带默认的参数(换签名:DROP + CREATE);
--      ncr_rows 末尾多两列。submit_shift_handover 末尾多一个 p_incident_ids(换签名)。
--   ⑤ 提醒两支(incident_nea_notify_due · incident_report_due)· 待补的值一支(V19)· 审计主语三个(incident · safety_settings ·
--      dictionary_incident_kinds)与它们的成员 · 遮蔽规则 +5(114 → 119)· 单据登记 INC(59 → 60)与一行例外 · 六张新表进变更记录(豁免仍是 8)。
--   ⑥ F12(Q23):线上 material_kinds 备件那一行的说明改成镜像里那一句(received as lots so stock and cost are counted; issued against a
--      maintenance record; no per-piece traceability),本事务的自证把它读回来与镜像逐字比对。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;除了上面那十二行安全码的授权,不加任何码、不改任何授权;不写、不改任何一件既有的批次、流水、
--   分录、物料、停机、保养、加工单、异常事件、不合格报告、交接班、证书、安全状态、员工、公共假期;不建任何事故、更新、链接或交接班引用;不回填(Q94);
--   require_calibrated_since 保持空。线上由本迁移造出的只有:七种事故种类、V19(2,未确认)、十二行授权与两个码、F12 那一句说明。
--
-- 【破窗】(Q21:这一窗什么都不坏)旧应用不读新表;它调 open_ncr 与 submit_shift_handover 都按具名参数、不带新参数 → 默认值,照旧走得通;
--   ncr_rows 只多两列、operations_now 只多两支(旧应用的提醒清单不认得这两种类型,不画);角色页上多出两个它没有菜单的码(名字从目录读)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了那十二行、别的一行没动,admin 持目录里每一个码(81);每一个角色仍满足
--   "编辑码蕴含查看码"与"动作码蕴含查看码";data.view_health 的持有人一个没变(cto 与仓库不在其中);在途单据一张不少、一张不多,每一张仍有
--   一个不是它当事人的决定人;七个账号一个都没被停;既有的行逐字未变(见 DIGEST_TABLES);六张新表空(种类七行、设定一行 V19 = 2 未确认);
--   备件那一行说明 = 镜像那一句;本事务往变更记录只写了本刀种的那几行;anon 能执行的【恰好】两支;员工函数 DEFINER、调得到,守卫与内层调不到;
--   那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 119);提醒臂 68、待补的值 25;单据登记 60 行;305 张表。
--   断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子(开场读数,docs/surveys/MES-7b-1/live-readings.sql)──────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES7B1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.incidents') IS NOT NULL OR to_regclass('public.incident_kinds') IS NOT NULL
       OR to_regclass('public.safety_settings') IS NOT NULL OR to_regclass('public.shift_handover_incident_refs') IS NOT NULL
       OR EXISTS (SELECT 1 FROM permissions WHERE code LIKE 'module.safety.%')
       OR EXISTS (SELECT 1 FROM document_types WHERE key = 'incident' OR prefix = 'INC') THEN
        RAISE EXCEPTION 'MES7B1_PRE|MES-7b-1 objects already exist';
    END IF;
    IF to_regprocedure('public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint)') IS NULL
       OR to_regprocedure('public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid)') IS NULL
       OR to_regprocedure('public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[])') IS NULL THEN
        RAISE EXCEPTION 'MES7B1_PRE|open_ncr / ncr_open_internal / submit_shift_handover do not have the signatures this migration replaces';
    END IF;
    IF EXISTS (SELECT 1 FROM nonconformance_reports) THEN
        RAISE EXCEPTION 'MES7B1_PRE|expected no NCR on live (opening reading)';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES7B1_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 79
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES7B1_PRE|expected a catalogue of 79 codes, all held by admin';
    END IF;
    IF (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'module.processing.view') IS DISTINCT FROM 'admin,auditor,cco,cfo,cto,finance,gm,operations,warehouse' THEN
        RAISE EXCEPTION 'MES7B1_PRE|the holders of module.processing.view are not the nine of the opening reading';
    END IF;
    IF (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'data.view_health') IS DISTINCT FROM 'admin,cco,cfo,finance,hr' THEN
        RAISE EXCEPTION 'MES7B1_PRE|the holders of data.view_health are not the five of the opening reading';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 59 THEN
        RAISE EXCEPTION 'MES7B1_PRE|expected 59 document types';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES7B1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES7B1_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 66 THEN
        RAISE EXCEPTION 'MES7B1_PRE|operations_now should have 66 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 24 THEN
        RAISE EXCEPTION 'MES7B1_PRE|pending_values should have 24 arms before';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 299 THEN
        RAISE EXCEPTION 'MES7B1_PRE|expected 299 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES7B1_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes7b1_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes7b1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes7b1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes7b1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes7b1_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t ) AS inbound_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t ) AS output_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inventory_movements t ) AS inventory_movements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM materials t ) AS materials,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM material_kinds t WHERE code <> 'spare_part') AS material_kinds,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_downtime t ) AS equipment_downtime,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_maintenance t ) AS equipment_maintenance,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_runs t ) AS processing_runs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_inputs t ) AS processing_inputs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_outputs t ) AS processing_outputs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_run_events t ) AS processing_run_events,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'incident_id')::text, '|' ORDER BY (to_jsonb(t) - 'incident_id')::text), '')) FROM nonconformance_reports t ) AS nonconformance_reports,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batch_safety_states t ) AS inbound_batch_safety_states,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batch_safety_states t ) AS output_batch_safety_states,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM shift_handovers t ) AS shift_handovers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM shift_handover_items t ) AS shift_handover_items,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM shift_handover_equipment_refs t ) AS shift_handover_equipment_refs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM storage_locations t ) AS storage_locations,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t ) AS employees,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM public_holidays t ) AS public_holidays,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t ) AS certificates_of_destruction,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) AS cod_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_analysis t ) AS certificates_of_analysis,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM coa_issues t ) AS coa_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM warehouse_requests t ) AS warehouse_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) AS approval_log,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM fixed_assets t ) AS fixed_assets,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM accounts t ) AS accounts,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t WHERE code NOT IN ('module.safety.view', 'module.safety.edit', 'data.view_health')) AS permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t WHERE key <> 'incident') AS document_types,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) AS ingest_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_data_classes t ) AS ingest_data_classes;

-- ── 1 · 权限目录:两个安全码(与 db/tables/permissions.sql 逐字同一份);data.view_health 的描述多一句事故的受伤细节 ──────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('module.safety.view', 'module', 'Safety (view)', '安全(查看)', 'Incidents — thermal runaway, fire, gas and dust releases, injuries, near misses and emission exceedances — with their NEA reminders, the batches they touched and the shift handovers that cite them; read only. Injury details also need Health data.', '事故 —— 热失控、起火、气体与粉尘释放、工伤、未遂与排放超标 —— 连同它们的 NEA 提醒、碰过的批次与引用它们的交接班;只读。受伤的细节另要「健康数据」。', 152),
    ('module.safety.edit', 'module', 'Safety (edit)', '安全(编辑)', 'Record an incident (including injury details, which only Health data holders read back), record that NEA was notified or the written report submitted, close or correct an incident with a reason, link and unlink the batches it touched, edit the incident kinds and set the NEA written-report deadline (V19).', '记一件事故(包括受伤的细节 —— 读回来只给持「健康数据」的人)、记下通报了 NEA 或交了书面报告、关闭或带理由地更正一件事故、链上与解开它碰过的批次、改事故种类、设 NEA 书面报告的期限(V19)。', 153);
UPDATE public.permissions SET description_en = 'Medical-claim descriptions and amounts, the reasons, certificate references and exception reasons on leave requests, and the injury details of an incident (who was hurt, the injury, the treatment, days lost). Everyone still sees their own.', description_zh = '医疗报销的事由与金额,请假单上的事由、病假单号与例外理由,以及事故的受伤细节(谁受了伤、伤情、处理、误工天数)。每个人照旧看得见自己的。'
 WHERE code = 'data.view_health';

-- ── 2 · 新函数(镜像原样),先于新表:四支守卫(种类代号冻住 · 事故写下就不改 · 更新只追加 · 链接只在解链接那一次改)──

-- db/functions/guard_incident_kind_code.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q4,Tim):【一种事故被用过之后,它的代号冻住】—— incident_kinds 上 BEFORE UPDATE OR DELETE,行级。
--   改代号(或删掉这一种)时,只要还有一件事故是这一种,或者有一次更正把某件事故改成了这一种,就按名拒
--   INCIDENT_KIND_CODE_LOCKED|<代号>|<件数> —— 改代号就是改外键指着的东西,而更正里存的是代号的字,外键看不见它。
--   名字、顺序、说明、启用照常可改(代号不变时直接放行)。
--   【DEFINER】数的是【所有】事故,不是读者读得到的那几件 —— 一个读不到某件事故的人,不能因此把它的种类改掉。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.guard_incident_kind_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n integer;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.code IS NOT DISTINCT FROM OLD.code THEN
        RETURN NEW;
    END IF;
    SELECT count(*) INTO v_n
      FROM (SELECT i.id FROM incidents i WHERE i.kind_code = OLD.code
            UNION
            SELECT u.incident_id FROM incident_updates u
             WHERE u.kind = 'correction' AND u.field = 'kind_code' AND u.new_value = OLD.code) x;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'INCIDENT_KIND_CODE_LOCKED|%|%', OLD.code, v_n
          USING HINT = '这一种已经被事故用过 —— 代号是事故指着的东西,改了或删了,那些事故就说不出自己是哪一种。名字可以改;要换代号,就新加一种。';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_incident_write.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q5 · Q9,Tim):incidents 的守卫,一支函数两种挂法 ——
--   UPDATE / DELETE(语句级):对谁都按名拒 INCIDENT_IMMUTABLE|<动作> —— 一件事故写下就不改,以后的事实是 incident_updates 的一行。
--   INSERT(行级):
--     ① 会话里直连插入(row_security_active = 真)按名拒 INCIDENT_THROUGH_FUNCTION_ONLY;record_incident(属主路径)放行。
--     ② 下面这几条说的是【行】,所以对每一个写入者都成立(迁移、fixture、DEFINER 函数都一样):
--        来源只能是 manual(device 保留 —— INCIDENT_SOURCE_RESERVED|device,Q5)· 发生时刻不在未来(INCIDENT_TIME_IN_FUTURE|<时刻>)·
--        种类在清单里(INCIDENT_KIND_UNKNOWN|<代号>)而且启用着(INCIDENT_KIND_INACTIVE|<代号>)·
--        引用的停机是同一台机器的(INCIDENT_DOWNTIME_OTHER_MACHINE|<停机那台机器的编号>)、没作废(INCIDENT_DOWNTIME_VOIDED)·
--        引用的异常事件存在、没撤回、没被更正(INCIDENT_RUN_EVENT_NOT_FOUND / INCIDENT_RUN_EVENT_WITHDRAWN / INCIDENT_RUN_EVENT_CORRECTED|<更正那一行>)。
--   【为什么是 INVOKER】row_security_active 必须反映【调用者】的视角(guard_part_issue_write 同一个理由);① 在会话路径上第一个就抛,
--     所以后面那几句读表只在属主路径上跑。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.guard_incident_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_dt record;
    v_ev record;
BEGIN
    IF TG_LEVEL = 'STATEMENT' THEN
        RAISE EXCEPTION 'INCIDENT_IMMUTABLE|%', lower(TG_OP)
          USING HINT = '一件事故写下就不改。之后的事(通报了 NEA、交了书面报告、关闭、带理由的更正)在事故页上各记一行。';
    END IF;
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'INCIDENT_THROUGH_FUNCTION_ONLY';
    END IF;
    IF NEW.source IS DISTINCT FROM 'manual' THEN
        RAISE EXCEPTION 'INCIDENT_SOURCE_RESERVED|%', COALESCE(NEW.source, '?')
          USING HINT = '报警面板的事件格式还没有,所以今天每一件事故都是手工记的;device 这个来源留给它。';
    END IF;
    IF NEW.occurred_at > now() THEN
        RAISE EXCEPTION 'INCIDENT_TIME_IN_FUTURE|%', to_char(NEW.occurred_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM incident_kinds k WHERE k.code = NEW.kind_code) THEN
        RAISE EXCEPTION 'INCIDENT_KIND_UNKNOWN|%', COALESCE(NEW.kind_code, '?');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM incident_kinds k WHERE k.code = NEW.kind_code AND k.is_active) THEN
        RAISE EXCEPTION 'INCIDENT_KIND_INACTIVE|%', NEW.kind_code;
    END IF;
    IF NEW.downtime_id IS NOT NULL THEN
        SELECT d.equipment_id, d.voided_at, fa.code AS equipment_code INTO v_dt
          FROM equipment_downtime d JOIN fixed_assets fa ON fa.id = d.equipment_id
         WHERE d.id = NEW.downtime_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INCIDENT_DOWNTIME_NOT_FOUND|%', NEW.downtime_id;
        END IF;
        IF v_dt.equipment_id IS DISTINCT FROM NEW.equipment_id THEN
            RAISE EXCEPTION 'INCIDENT_DOWNTIME_OTHER_MACHINE|%', v_dt.equipment_code
              USING HINT = '一件事故只能引用它自己那台机器的停机 —— 另一台机器的停机说的是另一件事。';
        END IF;
        IF v_dt.voided_at IS NOT NULL THEN
            RAISE EXCEPTION 'INCIDENT_DOWNTIME_VOIDED';
        END IF;
    END IF;
    IF NEW.run_event_id IS NOT NULL THEN
        -- 一条事件的撤回与更正是【另一行】(corrects_id 指回它):引用的必须是那一条事件此刻说话的那一行
        SELECT e.withdrawn,
               (SELECT x.id FROM processing_run_events x WHERE x.corrects_id = e.id) AS superseded_by,
               COALESCE((SELECT x.withdrawn FROM processing_run_events x WHERE x.corrects_id = e.id), false) AS withdrawn_by
          INTO v_ev FROM processing_run_events e WHERE e.id = NEW.run_event_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INCIDENT_RUN_EVENT_NOT_FOUND|%', NEW.run_event_id;
        END IF;
        IF v_ev.withdrawn OR v_ev.withdrawn_by THEN
            RAISE EXCEPTION 'INCIDENT_RUN_EVENT_WITHDRAWN|%', NEW.run_event_id;
        END IF;
        IF v_ev.superseded_by IS NOT NULL THEN
            RAISE EXCEPTION 'INCIDENT_RUN_EVENT_CORRECTED|%', v_ev.superseded_by
              USING HINT = '这一条事件已经被更正过 —— 引用更正之后的那一行。';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_incident_update_write.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3,Tim):incident_updates 的两道守卫,一支函数 ——
--   UPDATE / DELETE(语句级):对谁都按名拒 INCIDENT_UPDATE_IMMUTABLE|<动作> —— 只可追加,一次记错的更正靠下一次更正。
--   INSERT(行级):会话里直连插入按名拒 INCIDENT_UPDATE_THROUGH_FUNCTION_ONLY;record_incident_update(属主路径)放行。
--   INVOKER:row_security_active 要反映调用者(guard_part_issue_write 同一个理由)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.guard_incident_update_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_LEVEL = 'STATEMENT' THEN
        RAISE EXCEPTION 'INCIDENT_UPDATE_IMMUTABLE|%', lower(TG_OP);
    END IF;
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'INCIDENT_UPDATE_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_incident_batch_write.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q7,Tim):incident_batches 的守卫,一支函数两种挂法 ——
--   语句级(UPDATE / DELETE):删除对谁都按名拒 INCIDENT_LINK_IMMUTABLE|delete;会话里直连的 UPDATE 按名拒
--     INCIDENT_LINK_THROUGH_FUNCTION_ONLY —— 语句级,所以 RLS 让它碰不到任何一行时照样抛,不是一次"成功的空操作"(ALERT-1)。
--   行级:直连插入按名拒(同上);一行链接只在【解链接】那一次改得动 —— 从有效变成解除,而且只许动 unlinked_at / unlinked_by /
--     unlink_reason 三列;别的改动一律 INCIDENT_LINK_IMMUTABLE|update(属主路径同样受它管:它守的是记录的形状)。
--   INVOKER:row_security_active 要反映调用者。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.guard_incident_batch_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'INCIDENT_LINK_IMMUTABLE|delete';
    END IF;
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'INCIDENT_LINK_THROUGH_FUNCTION_ONLY';
    END IF;
    IF TG_LEVEL = 'STATEMENT' OR TG_OP = 'INSERT' THEN
        IF TG_LEVEL = 'STATEMENT' THEN
            RETURN NULL;
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.unlinked_at IS NOT NULL OR NEW.unlinked_at IS NULL
       OR (to_jsonb(NEW) - 'unlinked_at' - 'unlinked_by' - 'unlink_reason')
          IS DISTINCT FROM (to_jsonb(OLD) - 'unlinked_at' - 'unlinked_by' - 'unlink_reason') THEN
        RAISE EXCEPTION 'INCIDENT_LINK_IMMUTABLE|update'
          USING HINT = '一条链接只在解链接那一次改(带理由),之后不改、不删。要重新链上,就再链一次。';
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 3 · 新表(镜像原样):事故种类 · 安全的设定(V19)· 事故 · 之后的事实 · 批次链接 · 交接班的引用 ─────────────────────

-- db/tables/incident_kinds.sql
-- MES-7b-1(2026-10-16,MES-0 功能 24 · Q73;MES-7b Step 0 Q4,Tim):【一件事故是哪一种】—— 一张可编辑的清单。
--   引导七种:规格书要 ERP 当作异常收下的那几样安全信号(热失控 · 起火冒烟 · 气体释放(电解液蒸汽 / HF)· 粉尘浓度),
--   WSH 登记簿的工伤与未遂(docs/forward-queue.md:2402),以及排放超标(MES-0 Q75,环境监测在 MES-7b-2 来)。
--   ★ 没有 other:一件说不出是哪一种的事故,与"其它"那个兜底桶是同一个病(规格 §4.1 对损耗、downtime_causes 对停机说的同一句话)。
--     加一种是加一行(/settings/dictionaries,module.safety.edit)。
--   ★ 一种被事故引用之后,它的代号冻住(guard_incident_kind_code,INCIDENT_KIND_CODE_LOCKED|<代号>|<件数>)—— 改代号就是改外键指着的
--     东西,删它就是让一件事故说不出自己是哪一种。名字、顺序、说明、启用照常可改;停用只管"以后还能不能新选"。
--   RUNTIME CONFIG。读:module.safety.view;写:module.safety.edit(与表的写策略同一个码 —— 字典页的门照它)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.incident_kinds (
    code       text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$' AND code <> 'other'),
    name_en    text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh    text NOT NULL CHECK (btrim(name_zh) <> ''),
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.incident_kinds IS
    'MES-7b-1:事故的种类(没有 other)。引导七种:thermal_runaway · fire_smoke · gas_release · dust_concentration · injury · near_miss · emission_exceedance。被一件事故引用之后代号冻住(INCIDENT_KIND_CODE_LOCKED)。RUNTIME CONFIG。读 module.safety.view,写 module.safety.edit。';

INSERT INTO public.incident_kinds (code, name_en, name_zh, sort_order, notes) VALUES
    ('thermal_runaway', 'Thermal runaway', '热失控', 10, 'A cell or module heating out of control (temperature or rate of rise beyond the site interlock).'),
    ('fire_smoke', 'Fire or smoke', '起火或冒烟', 20, 'Fire, flame or smoke anywhere on site.'),
    ('gas_release', 'Gas release', '气体释放', 30, 'Electrolyte vapour, HF or another gas released.'),
    ('dust_concentration', 'Dust concentration', '粉尘浓度', 40, 'Dust concentration beyond the site alarm (powder stripping, black mass handling).'),
    ('injury', 'Injury', '工伤', 50, 'A person was hurt at work.'),
    ('near_miss', 'Near miss', '未遂事件', 60, 'Something that could have hurt someone or caused damage, but did not.'),
    ('emission_exceedance', 'Emission exceedance', '排放超标', 70, 'A monitored emission above its licence limit.');

ALTER TABLE public.incident_kinds ENABLE ROW LEVEL SECURITY;
CREATE POLICY "incident_kinds select by permission" ON public.incident_kinds
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.safety.view'::text));
CREATE POLICY "incident_kinds write by permission" ON public.incident_kinds
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.safety.edit'::text)) WITH CHECK (has_permission('module.safety.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.incident_kinds TO authenticated;
REVOKE ALL ON public.incident_kinds FROM anon;

-- 被引用之后代号冻住、不能删(外键也挡删除,但那是一串约束名;这里按名说出被引用几件)。
CREATE TRIGGER trg_incident_kinds_code_locked
    BEFORE UPDATE OR DELETE ON public.incident_kinds
    FOR EACH ROW EXECUTE FUNCTION public.guard_incident_kind_code();

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.incident_kinds
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.safety.edit');

-- db/tables/safety_settings.sql
-- MES-7b-1(2026-10-16,MES-0 §5.1 V19 · Q74;MES-7b Step 0 Q10 · Q11,Tim):【安全的设定 —— 单行】。今天只有一样:V19。
--   nea_report_working_days —— 一件要向 NEA 通报的事故,书面报告要在几个【工作日】内交。
--     期限 = 从事故日(新加坡日期)之后的第一个工作日数起,数到第 V19 个工作日(business_days_after,公共假期表与 is_business_day)。
--   ★ Q11(Tim):引导存 2,【未确认】—— 出处是仓库里那一条义务的记录(docs/forward-queue.md:2402,「立即通报 … 两个工作日内提交书面报告」),
--     不是执照原文。所以 confirmed_at 为空:页面上的期限一律标"未确认",V19 一直挂在待补的值上,直到持 module.safety.edit 的人
--     对着执照把它确认(set_safety_settings 带 p_confirmed = true)。改天数不带确认 = 又回到未确认。
--   空(NULL)= Not yet set:书面报告的期限算不出来(屏幕上说"期限没有设定"),通报的提醒照旧。
--   由 module.safety.edit 经 set_safety_settings 改;修改史在变更记录里(主语 safety_settings,画在 /safety/incidents)。
--   RUNTIME CONFIG:Tim 确认一次,线上就与本文件不同 —— 那是系统在正常工作(quality_settings 的先例)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.safety_settings (
    id                           boolean PRIMARY KEY DEFAULT true CHECK (id),
    nea_report_working_days      integer CHECK (nea_report_working_days IS NULL OR nea_report_working_days > 0),
    nea_report_days_source       text,
    nea_report_days_confirmed_at timestamptz,
    nea_report_days_confirmed_by uuid,
    updated_at                   timestamptz NOT NULL DEFAULT now(),
    updated_by                   uuid DEFAULT auth.uid(),
    -- 确认的是一个数:没有数就没有确认;确认与确认人同进同出
    CONSTRAINT safety_settings_confirmation_consistent CHECK (
        (nea_report_days_confirmed_at IS NULL AND nea_report_days_confirmed_by IS NULL)
        OR (nea_report_days_confirmed_at IS NOT NULL AND nea_report_working_days IS NOT NULL))
);

COMMENT ON TABLE public.safety_settings IS
    'MES-7b-1:安全的设定(单行)。nea_report_working_days = V19,向 NEA 交书面报告的工作日数;引导 2、未确认(出处:仓库里那条义务的记录,不是执照原文 —— Q11)。期限照它算、照它标"未确认",V19 留在待补的值上直到有人对着执照确认。module.safety.edit 经 set_safety_settings 改。';
COMMENT ON COLUMN public.safety_settings.nea_report_working_days IS
    'V19(MES-0 §5.1):书面报告要在事故日之后的第几个工作日之前交到 NEA。空 = Not yet set(期限算不出来)。';
COMMENT ON COLUMN public.safety_settings.nea_report_days_source IS
    'V19 这个数从哪里来的 —— 页面照原样显示。引导值的出处是 docs/forward-queue.md:2402 那一条义务的记录。';
COMMENT ON COLUMN public.safety_settings.nea_report_days_confirmed_at IS
    'V19 被对着 NEA 执照确认的时刻;空 = 未确认 —— 期限照算,但标"未确认",V19 留在 /settings/pending-values 上。';

INSERT INTO public.safety_settings (id, nea_report_working_days, nea_report_days_source) VALUES
    (true, 2, 'Repository record of the NEA duty — docs/forward-queue.md:2402 ("立即通报 … 两个工作日内提交书面报告"); not yet confirmed against the NEA licence.');

CREATE TRIGGER trg_safety_settings_updated_at
    BEFORE UPDATE ON public.safety_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.safety_settings ENABLE ROW LEVEL SECURITY;
-- 读:安全查看码(事故页的设定面板、期限与待补的值那一行)。写只经函数。
CREATE POLICY "safety_settings select by permission" ON public.safety_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.safety.view'::text));
GRANT SELECT ON public.safety_settings TO authenticated;
REVOKE ALL ON public.safety_settings FROM anon;

-- db/tables/incidents.sql
-- MES-7b-1(2026-10-16,MES-0 功能 24 · Q53 · Q73 · Q76 · Q91;MES-7b Step 0 Q3 · Q5 · Q6 · Q9 · Q10 · Q27 · Q28,Tim):【一件事故】——
--   WSH 事故与未遂登记簿的一行(docs/forward-queue.md:2402 那条义务的载体):什么时候、哪一种、在哪、哪台机器、发生了什么、当场做了什么、
--   谁负责、要不要向 NEA 通报。
--
--   【编号】INC-YYYY-NNNN,按年、无洞(next_incident_code;document_types 的 'incident';宽度 GREATEST(4, 位数) —— CODE-WIDTH-4)。
--   【必填】种类 · 发生时刻(不在未来)· 发生了什么 · 当场做了什么 · 负责的人(一名员工,或写下名字)· 要不要通报 NEA(是 / 否,没有默认 ——
--     由记录的人对着那条义务回答,Q10:没有一条规矩替他判)。【可选】库位 · 机器(只认设备类资产)· 持续多久(分钟)。
--   【可选的引用】(Q9)一段停机(必须是同一台机器的、没作废的)· 一条加工单的异常事件(没撤回的)—— 引用,不是副本;两者谁都不取代谁:
--     可靠性(MTBF / MTTR)照旧只数停机,事故只进事故登记簿,同一件事不会被数两次。
--   【来源】manual · device。device【保留】(Q5):报警面板没有负载格式、也没有转换层(safety_alarm 那一类 transform_function 仍是空),
--     一行 device 按名拒(INCIDENT_SOURCE_RESERVED|device)—— equipment_downtime 的同一个先例。
--   【这一行写下就不改】(Q3)以后的事实是 incident_updates 的一行:通报了 NEA · 交了书面报告 · 关闭 · 一次带理由的更正。
--     页面上的"现在是什么样"由这一行加上那些更正算出来(incident_current_all)。
--   【受伤的细节】(Q6 · MES-0 Q76 · Q91)受伤的人(一名员工,或一个不是员工的人的名字)· 伤情 · 处理 · 误工天数 —— 健康数据:
--     从列授权里拿掉,只经 incidents_masked 读,给持 data.view_health 的人,并【对受伤的那名员工本人让路】
--     (change_log_mask_rules 的 code_or_self:data.view_health:injured_employee_id,三处同一个判据)。
--     任何持 module.safety.edit 的人都记得进去;记下之后,一个不持 data.view_health 的记录人看见的是「受限」。data.view_health 不授给 cto 与仓库。
--   【写】只经 SECURITY DEFINER 函数 record_incident(module.safety.edit,Q28)。会话里直连插入按名拒 INCIDENT_THROUGH_FUNCTION_ONLY;
--     改与删对谁都按名拒 INCIDENT_IMMUTABLE(语句级,所以 RLS 碰不到行时照样抛)。
--   【读】module.safety.view(基表的读策略);受伤的那名员工读自己那一件经 incidents_masked(那张视图的行谓词带本人)。
--   【没有金额】。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.incidents (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                    text NOT NULL UNIQUE,
    kind_code               text NOT NULL REFERENCES public.incident_kinds (code),
    occurred_at             timestamptz NOT NULL,
    location_id             uuid REFERENCES public.storage_locations (id),
    equipment_id            uuid REFERENCES public.fixed_assets (id),
    duration_min            numeric CHECK (duration_min IS NULL OR duration_min >= 0),
    what_happened           text NOT NULL CHECK (btrim(what_happened) <> ''),
    immediate_action        text NOT NULL CHECK (btrim(immediate_action) <> ''),
    responsible_employee_id uuid REFERENCES public.employees (id),
    responsible_name        text,
    nea_reportable          boolean NOT NULL,
    source                  text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'device')),
    downtime_id             uuid REFERENCES public.equipment_downtime (id),
    run_event_id            bigint REFERENCES public.processing_run_events (id),
    injured_employee_id     uuid REFERENCES public.employees (id),
    injured_person_name     text,
    injury_nature           text,
    injury_treatment        text,
    days_lost               numeric CHECK (days_lost IS NULL OR days_lost >= 0),
    recorded_at             timestamptz NOT NULL DEFAULT now(),
    recorded_by             uuid DEFAULT auth.uid(),
    -- 负责的人:一名员工,或写下的一个名字(至少一样)
    CONSTRAINT incidents_responsible_named CHECK (
        responsible_employee_id IS NOT NULL OR (responsible_name IS NOT NULL AND btrim(responsible_name) <> '')),
    -- 受伤的人最多一个:一名员工,或一个不是员工的人的名字
    CONSTRAINT incidents_one_injured_person CHECK (num_nonnulls(injured_employee_id, injured_person_name) <= 1),
    -- 伤情、处理、误工天数要说的是某一个人
    CONSTRAINT incidents_injury_needs_person CHECK (
        (injury_nature IS NULL AND injury_treatment IS NULL AND days_lost IS NULL)
        OR num_nonnulls(injured_employee_id, injured_person_name) = 1),
    -- 引用一段停机就必须说出是哪台机器(同一台由 guard_incident_write 判)
    CONSTRAINT incidents_downtime_needs_machine CHECK (downtime_id IS NULL OR equipment_id IS NOT NULL)
);

CREATE INDEX incidents_kind_code_rel ON public.incidents (kind_code);
CREATE INDEX incidents_location_id_rel ON public.incidents (location_id);
CREATE INDEX incidents_equipment_id_rel ON public.incidents (equipment_id);
CREATE INDEX incidents_responsible_employee_id_rel ON public.incidents (responsible_employee_id);
CREATE INDEX incidents_downtime_id_rel ON public.incidents (downtime_id);
CREATE INDEX incidents_run_event_id_rel ON public.incidents (run_event_id);
CREATE INDEX incidents_injured_employee_id_rel ON public.incidents (injured_employee_id);
-- 搜索:code 的后缀匹配(与 nonconformance_reports 同一条)
CREATE INDEX incidents_code_trgm ON public.incidents USING gin (code extensions.gin_trgm_ops);

COMMENT ON TABLE public.incidents IS
    'MES-7b-1:一件事故(INC-YYYY-NNNN)—— 种类、时刻(不在未来)、可选的库位 / 机器 / 时长、发生了什么、当场做了什么、负责的人、要不要通报 NEA;可选地引用一段同一台机器的停机与一条异常事件。来源 manual(device 保留,按名拒)。写下就不改,以后的事实是 incident_updates 的行。受伤的人、伤情、处理、误工天数是健康数据:只经 incidents_masked 读(data.view_health 或受伤的那名员工本人)。写只经 record_incident(module.safety.edit)。';
COMMENT ON COLUMN public.incidents.nea_reportable IS
    '要不要向 NEA 通报 —— 记录的人对着那条义务回答(Q10),必填、没有默认。是:通报的提醒挂到记下通报为止;书面报告的期限 = 事故日之后第 V19 个工作日。';
COMMENT ON COLUMN public.incidents.source IS
    'manual(手工记)· device(保留 —— 报警面板没有负载格式,今天按名拒 INCIDENT_SOURCE_RESERVED)。';
COMMENT ON COLUMN public.incidents.downtime_id IS
    '可选:这件事故造成的那一段停机(同一台机器、没作废)。引用,不是副本 —— 可靠性照旧只数停机(Q9)。';
COMMENT ON COLUMN public.incidents.run_event_id IS
    '可选:加工单上的那一条异常事件(没撤回)。一条 safety_alarm 事件自己不开事故;两者谁都不取代谁(Q9)。';
COMMENT ON COLUMN public.incidents.injured_employee_id IS
    '健康数据(Q6):受伤的那名员工。只经 incidents_masked 读 —— data.view_health,或就是这名员工本人。';

ALTER TABLE public.incidents ENABLE ROW LEVEL SECURITY;
-- 读:安全查看码。写:一条策略都不给 —— 只经 record_incident。
CREATE POLICY "incidents select by permission" ON public.incidents
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.safety.view'::text));
-- ★ 健康数据(Q6):受伤的人、伤情、处理、误工天数从列授权里拿掉,只经 incidents_masked 读。
--   表级 SELECT 授权蕴含所有列,所以先整表收回、再逐列授回(medical_claims 的同一个做法)。
--   列授权不随 ADD COLUMN 自动延伸:给这张表加列,要回到这一行,并把它放进 incidents_masked(gate 的 colgrant)。
--   INSERT / UPDATE / DELETE 授着,是为了让直连的写走到下面那两支守卫、按名被拒,而不是撞上一句 42501。
REVOKE SELECT ON public.incidents FROM authenticated, anon;
GRANT SELECT (id, code, kind_code, occurred_at, location_id, equipment_id, duration_min, what_happened, immediate_action,
              responsible_employee_id, responsible_name, nea_reportable, source, downtime_id, run_event_id, recorded_at, recorded_by)
    ON public.incidents TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.incidents TO authenticated;
REVOKE ALL ON public.incidents FROM anon;

-- 插入:来源、时刻、种类、停机是不是同一台机器 —— 对每一个写入者都成立(属主路径也一样);会话里直连插入按名拒。
CREATE TRIGGER trg_incidents_insert
    BEFORE INSERT ON public.incidents
    FOR EACH ROW EXECUTE FUNCTION public.guard_incident_write();
-- 写下就不改:改与删对谁都按名拒 —— 语句级,所以 RLS 让一句 UPDATE 碰不到任何一行时它照样抛(ALERT-1)。
CREATE TRIGGER trg_incidents_immutable
    BEFORE UPDATE OR DELETE ON public.incidents
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_incident_write();
CREATE TRIGGER trg_incidents_truncate
    BEFORE TRUNCATE ON public.incidents
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

-- db/tables/incident_updates.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q10,Tim):【一件事故之后发生的事实】—— 事故那一行写下就不改,以后的事一律是这里的一行(只追加)。
--   nea_notified      通报了 NEA:什么时候(必填、不在未来)、怎么通报的 / 编号(可选)。每件最多一行。
--                      有了它,incident_nea_notify_due 那条提醒就消失。
--   report_submitted  交了书面报告:什么时候(必填、不在未来)、报告编号(可选)。每件最多一行。有了它,incident_report_due 消失。
--   closed            关闭:一句总结(必填)。每件最多一行。关闭之后不再收更正(INCIDENT_CLOSED);NEA 的两件事实照常收 ——
--                      法定的义务不因为"关闭"而结束,两条提醒也不看关没关。
--   correction        一次带理由的更正:哪一个字段、新值(文本)、理由(必填)。可以更正的字段只有这七个:种类 · 发生时刻 · 发生了什么 ·
--                      当场做了什么 · 负责的人(名字)· 持续多久 · 要不要通报 NEA。库位、机器、两条引用与受伤的细节【不】在这里更正
--                      (库位与机器决定了批次的建议,引用是另一张表的行;受伤的细节是健康数据,写进一行不遮蔽的更正就是把它泄出去)。
--                      同一字段多次更正,最后一次(id 最大的那一行 —— identity 记录先后,不是 created_at)说了算。
--   【写】只经 record_incident_update(module.safety.edit)。会话里直连插入按名拒;改与删对谁都按名拒 INCIDENT_UPDATE_IMMUTABLE。
--   【读】module.safety.view。【没有遮蔽的列】—— 受伤的细节不经这里。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.incident_updates (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    incident_id uuid NOT NULL REFERENCES public.incidents (id),
    kind        text NOT NULL CHECK (kind IN ('nea_notified', 'report_submitted', 'closed', 'correction')),
    occurred_at timestamptz,
    reference   text,
    field       text CHECK (field IS NULL OR field IN ('kind_code', 'occurred_at', 'what_happened', 'immediate_action',
                                                      'responsible_name', 'duration_min', 'nea_reportable')),
    new_value   text,
    reason      text,
    summary     text,
    recorded_at timestamptz NOT NULL DEFAULT now(),
    recorded_by uuid DEFAULT auth.uid(),
    -- 每一种的形状:该有的有,不该有的没有
    CONSTRAINT incident_updates_shape CHECK (
        (kind IN ('nea_notified', 'report_submitted') AND occurred_at IS NOT NULL
            AND field IS NULL AND new_value IS NULL AND reason IS NULL AND summary IS NULL)
        OR (kind = 'closed' AND summary IS NOT NULL AND btrim(summary) <> ''
            AND occurred_at IS NULL AND reference IS NULL AND field IS NULL AND new_value IS NULL AND reason IS NULL)
        OR (kind = 'correction' AND field IS NOT NULL AND new_value IS NOT NULL AND reason IS NOT NULL AND btrim(reason) <> ''
            AND occurred_at IS NULL AND reference IS NULL AND summary IS NULL))
);

CREATE INDEX incident_updates_incident_id_rel ON public.incident_updates (incident_id);
-- 通报、交报告、关闭:每件最多一行(两个人同一刻记同一件事 —— 部分唯一索引是声明式的兜底)
CREATE UNIQUE INDEX incident_updates_one_fact ON public.incident_updates (incident_id, kind)
    WHERE kind IN ('nea_notified', 'report_submitted', 'closed');

COMMENT ON TABLE public.incident_updates IS
    'MES-7b-1:一件事故之后的事实(只追加):nea_notified(通报了 NEA)· report_submitted(交了书面报告)· closed(关闭,带总结)· correction(七个字段之一的更正,带理由;最后一次说了算)。写只经 record_incident_update(module.safety.edit)。';

ALTER TABLE public.incident_updates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "incident_updates select by permission" ON public.incident_updates
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.safety.view'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.incident_updates TO authenticated;
REVOKE ALL ON public.incident_updates FROM anon;

-- 会话里直连插入按名拒(行级 BEFORE INSERT 先于 RLS 的 WITH CHECK);属主路径(record_incident_update)放行。
CREATE TRIGGER trg_incident_updates_direct
    BEFORE INSERT ON public.incident_updates
    FOR EACH ROW EXECUTE FUNCTION public.guard_incident_update_write();
-- 只可追加:改与删对谁都按名拒(语句级)。
CREATE TRIGGER trg_incident_updates_immutable
    BEFORE UPDATE OR DELETE ON public.incident_updates
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_incident_update_write();
CREATE TRIGGER trg_incident_updates_truncate
    BEFORE TRUNCATE ON public.incident_updates
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

-- db/tables/incident_batches.sql
-- MES-7b-1(2026-10-16,MES-0 Q73;MES-7b Step 0 Q7 · Q8,Tim):【一件事故碰过哪几批货】—— 一条链接,由一个人确认。
--   【建议从哪里来】(suggest_incident_batches,Q7)只有两种,而且【没有编一个时间窗】:
--     location     那一刻在事故库位上有货的批(那个库位上、发生时刻之前的流水净数 > 0);
--     machine_run  那一刻正在那台机器上跑的加工单([started_at, ended_at) 包含发生时刻、已提交、没回滚)的投入与产出批。
--   人对每一条建议各自确认(建一行,basis 记下是哪一种建议);任何一批也可以按批号挑出来(basis = picked)。
--   【一条链接不是一个安全状态】(MES-0 Q73,Tim 的裁定,inbound_safety_states.sql:49-55)—— 建 / 解链接一个字都不碰
--     inbound_batch_safety_states / output_batch_safety_states,也不动库存。要扣住一批,是在事故页上由持 module.quality.edit 的人
--     开一张来源 incident 的不合格报告(Q8),那时既有的质量暂扣照常生效。
--   【解链接要理由】一行链接只改一次:填上 unlinked_at / unlinked_by / unlink_reason(必填),之后对谁都不改;不删。
--     同一件事故 × 同一批同时最多一条有效链接(部分唯一索引);解了之后可以再链一次(新的一行)。
--   【写】只经 link_incident_batch / unlink_incident_batch(module.safety.edit)。会话里直连的写按名拒 INCIDENT_LINK_THROUGH_FUNCTION_ONLY。
--   【读】module.safety.view,或那一批自己那一页的查看码(批次页上的「关联的事故」那一行给两种码任一的人看 —— 样品与 NCR 同一个处置)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.incident_batches (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    incident_id      uuid NOT NULL REFERENCES public.incidents (id),
    inbound_batch_id uuid REFERENCES public.inbound_batches (id),
    output_batch_id  uuid REFERENCES public.output_batches (id),
    basis            text NOT NULL CHECK (basis IN ('location', 'machine_run', 'picked')),
    linked_at        timestamptz NOT NULL DEFAULT now(),
    linked_by        uuid DEFAULT auth.uid(),
    unlinked_at      timestamptz,
    unlinked_by      uuid,
    unlink_reason    text,
    CONSTRAINT incident_batches_one_batch CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    -- 解链接的三样同进同出,理由不许是空白
    CONSTRAINT incident_batches_unlink_consistent CHECK (
        (unlinked_at IS NULL AND unlinked_by IS NULL AND unlink_reason IS NULL)
        OR (unlinked_at IS NOT NULL AND unlink_reason IS NOT NULL AND btrim(unlink_reason) <> ''))
);

CREATE INDEX incident_batches_incident_id_rel ON public.incident_batches (incident_id);
CREATE INDEX incident_batches_inbound_batch_id_rel ON public.incident_batches (inbound_batch_id);
CREATE INDEX incident_batches_output_batch_id_rel ON public.incident_batches (output_batch_id);
-- 同一件事故 × 同一批,同时最多一条有效链接
CREATE UNIQUE INDEX incident_batches_one_active
    ON public.incident_batches (incident_id, COALESCE(inbound_batch_id, output_batch_id))
    WHERE unlinked_at IS NULL;

COMMENT ON TABLE public.incident_batches IS
    'MES-7b-1:一件事故碰过的一批货(进料或产出,恰好一个)。basis:location(那一刻在事故库位上有货)· machine_run(那一刻在那台机器上跑的加工单的投入 / 产出)· picked(按批号挑的)。人确认才有这一行;解链接要理由,之后不改、不删。一条链接从不设任何安全状态(MES-0 Q73)。写只经 link_incident_batch / unlink_incident_batch(module.safety.edit)。';

ALTER TABLE public.incident_batches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "incident_batches select by permission" ON public.incident_batches
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.safety.view'::text)
        OR (inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.incident_batches TO authenticated;
REVOKE ALL ON public.incident_batches FROM anon;

-- 会话里直连的插入与改按名拒(属主路径放行);一行链接只在【解链接】那一次改,只许动那三列;不删。
CREATE TRIGGER trg_incident_batches_row
    BEFORE INSERT OR UPDATE OR DELETE ON public.incident_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_incident_batch_write();
-- 语句级:RLS 让一句 UPDATE / DELETE 碰不到任何一行时,它照样抛(ALERT-1)
CREATE TRIGGER trg_incident_batches_statement
    BEFORE UPDATE OR DELETE ON public.incident_batches
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_incident_batch_write();
CREATE TRIGGER trg_incident_batches_truncate
    BEFORE TRUNCATE ON public.incident_batches
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

-- db/tables/shift_handover_incident_refs.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q12,Tim):这次交接班【指着】哪几件事故 —— 引用,不是副本(shift_handover_equipment_refs 的同一个形状)。
--   docs/forward-queue.md:2402 等的那一刻到了:WSH 登记簿(incidents)建好之后,交接班才引用事故,"在那之前刻意不留空列"。
--   Q12 裁的形状是一张引用表,不是交接班上的一列:一个班可以有好几件要下一个班注意的事故。
--   在交接班表单上挑(submit_shift_handover 的 p_incident_ids),在交接班页与事故页两边都看得见。
--   【写】只经 submit_shift_handover(交接班一次交齐,之后不改)—— 表上没有写策略,直连的写撞 RLS。
--   【读】module.processing.view(交接班那一页)或 module.safety.view(事故那一页)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.shift_handover_incident_refs (
    handover_id uuid NOT NULL REFERENCES public.shift_handovers (id) ON DELETE CASCADE,
    incident_id uuid NOT NULL REFERENCES public.incidents (id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid(),
    PRIMARY KEY (handover_id, incident_id)
);

CREATE INDEX shift_handover_incident_refs_incident_id_rel ON public.shift_handover_incident_refs (incident_id);

COMMENT ON TABLE public.shift_handover_incident_refs IS
    'MES-7b-1:这次交接班指着哪几件事故(引用,不是副本)。只经 submit_shift_handover 写;交接班页与事故页都读它(module.processing.view 或 module.safety.view)。';

ALTER TABLE public.shift_handover_incident_refs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "shift_handover_incident_refs select by permission" ON public.shift_handover_incident_refs
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text) OR has_permission('module.safety.view'::text));
-- 默认权限会把 INSERT / UPDATE / DELETE 也授给 authenticated(线上 pg_default_acl)—— 收掉:这张表只经 submit_shift_handover 写,直连写按 42501 拒。
REVOKE ALL ON public.shift_handover_incident_refs FROM authenticated, anon;
GRANT SELECT ON public.shift_handover_incident_refs TO authenticated;

-- ── 4 · 不合格报告:多一种来源 incident 与一列 incident_id(与 db/tables/nonconformance_reports.sql 逐字同一份;约束名是线上那一个)────────
ALTER TABLE public.nonconformance_reports DROP CONSTRAINT nonconformance_reports_source_check;
ALTER TABLE public.nonconformance_reports ADD CONSTRAINT nonconformance_reports_source_check
    CHECK (source IN ('manual', 'customer_complaint', 'quality_limit', 'inspection', 'incident'));
ALTER TABLE public.nonconformance_reports ADD COLUMN incident_id uuid REFERENCES public.incidents (id);
ALTER TABLE public.nonconformance_reports ADD CONSTRAINT
nonconformance_reports_incident_source CHECK ((source = 'incident') = (incident_id IS NOT NULL));
CREATE INDEX nonconformance_reports_incident_id_rel ON public.nonconformance_reports (incident_id);
COMMENT ON TABLE public.nonconformance_reports IS
    'MES-6b-1:一张不合格报告(NCR-YYYY-NNNN)—— 恰好一批(进料或产出)。它开着,那一批就在质量暂扣里(Step 0 Q2:没有另一张暂扣表;判据只有 batch_quality_hold):流水上不许投料、销售、发货、预留(guard_quality_hold),结算与配料计划也不收。来源 manual / customer_complaint(人开,module.quality.edit)· quality_limit(V17 越限时系统开)· inspection(留给 MES-7b)· incident(事故页上人开,指着那件事故,那一批必须链在它上 —— MES-7b-1)。open → decided 只经 decide_ncr(action.ncr_decide;开单人按人认永远不能决定自己那一张;系统开的任何持码人都能决定)。处置 accept / accept_with_penalty(指出钱走的那张贷项通知申请或收货定价申请,报告不带金额)/ rework / downgrade 放行;reject 不放行,出路是 CFO 注销申请,货没了暂扣就结束。决定之外只追加。';
COMMENT ON COLUMN public.nonconformance_reports.incident_id IS
    'MES-7b-1(MES-7b Step 0 Q8):来源 incident 的那一张指着的事故(恰好在来源是 incident 时有值)。那一批必须有一条有效链接挂在这件事故上(open_ncr 判 NCR_INCIDENT_BATCH_NOT_LINKED)。事故从不自己扣货 —— 扣货的是这张报告。';

-- ── 5 · 交接班两句表注释(WSH 登记簿建好了;与各自的表镜像逐字同一份)────────────────────────────────────────────
COMMENT ON TABLE public.shift_handovers IS
    'PROC-SUPPORT-1(R4/R5):一次交接班。**它【指向】别处的记录,不【复述】它们。**
【一张交接班上确定有的东西】哪个班(shift_code)、哪一天、谁交给谁、接班人的签收。
【刻意【没有】的东西,逐条给理由 —— 请不要"补全"它们】
  ① **"这个班处理了什么、多少" —— 没有这一栏。** processing_runs 只有 process_date(一个 date),全库 time 列在本刀之前为 0,所以**一张加工单归不到某一个班次上**。这是阶段 7 的 **G8**。一个自由文本会装一个猜测,而那个猜测会与加工单算出来的数打架 —— **人们读到的那一份会是错的那一份**。缺席看得见,不一致看不见。
  ② **设备状态 —— 不在这张表上,在 equipment_downtime(EQP-2a)。** 交接班经 shift_handover_equipment_refs 挂一条【引用】。同一件事记两遍,迟早不一致。
  ③ **事故 —— 连一列都不留。** 它属于那本尚未建的 WSH 事故与未遂事件登记簿(forward-queue.md:1198,触发条件"第一个技师上岗")。留一个指向不存在的表的空外键,读起来像"忘了填" —— EQP-2a 已经按名拒绝过这种做法。 ★ MES-7b-1(2026-10-16,MES-7b Step 0 Q12):登记簿(incidents)建好了 —— 事故经引用表 shift_handover_incident_refs 挂上来(与设备停机同一个形状),这张表仍然一列都不加。
  ④ **NEA 的法定时限(立即通报 / 两个工作日内书面报告)不在这里。** 见 R6 与 docs/processing-support-as-built.md:法定时限只能有一个载体。
【第一天它会装什么】**零行。** 线上 work_category = ''shopfloor'' 的员工数是 **0** —— 没有人交班,也没有人接班。本刀交付的是形状与屏幕,不是内容,而这一点不许被打扮成别的样子。';
COMMENT ON TABLE public.handover_item_types IS
    'PROC-SUPPORT-1(R4):交接班【记哪几类内容】。RUNTIME CONFIG —— ★ 第七个交接班字段是【加一行】,不是一次改代码 ★,那正是 Tim 要的形状。
形状抄仓库里已经被用了三次的那一套(operation_type_input_forms / _output_forms / operation_type_safety_states),规则列抄 output_batch_purposes.is_saleable_stock:**行为由数据回答,不由写死的字符串回答。**
★【第一天这张字典里只有【一行】,而那正是重点】★ Tim 列的七项确定内容里:
  · 哪个班、几点到几点 → shifts 那张表(时刻待 Tim 填);
  · 谁交给谁 / 接班人签收 → shift_handovers 上的列(它们是每张交接班【恰好一份】的事实,不是可增删的条目);
  · 设备状态 → **引用** equipment_downtime(R5,不复述);
  · 事故 → 属于 WSH 登记簿(R5/R6)—— ★ MES-7b-1 建好了:交接班经引用表 shift_handover_incident_refs 指着事故,不是一类条目;
  · 这个班处理了什么 → **答不出来,阻塞在 G8**,所以不建;
  · 未完成工作 → **就是这一行**,而且它是这一件里【唯一】没有现成载体的实质内容。
所以一行不是"建少了",是把每一项都放回了它该在的地方之后剩下的那一项。';

-- ── 6 · 单据登记:INC(与 db/tables/document_types.sql 那一行逐字同一份)· 一行例外(事故种类的 code 不是单据号)──────────────
INSERT INTO public.document_types (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission) VALUES
    ('incident', 'INC', 'incidents', 'gapless', NULL, '/safety/incidents', 'detail', 'what_happened', ARRAY['what_happened']::text[], ARRAY['module.safety.view']::text[]);
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
    ('incident_kinds',                '事故种类目录(MES-7b-1):code 是种类代号(没有 other),事故引用它')
ON CONFLICT (table_name) DO NOTHING;
-- 受伤的那一列不当关联边(与 db/tables/document_relation_exceptions.sql 那一行逐字同一份)
INSERT INTO public.document_relation_exceptions (owner_table, column_a, column_b, reason) VALUES
    ('incidents', 'injured_employee_id', '',
     'MES-7b-1(Q6):受伤的那名员工是健康数据(data.view_health 或本人才读得到,只经 incidents_masked)—— 员工 ↔ 事故经这一列的关联不进图,否则关联搜索会把谁受过伤列出来。负责的人那一列照常是一条关联。')
ON CONFLICT (owner_table, column_a, column_b) DO NOTHING;

-- ── 7 · 新函数(镜像原样),新表之后:取号 · 工作日 · 记事故 · 记之后的事实 · 批次建议 · 链 / 解链 · V19 ──────────────

-- db/functions/next_incident_code.sql
-- MES-7b-1(2026-10-16,MES-0 Q53 · MES-7b Step 0 Q3 · Q27):事故的编号 INC-YYYY-NNNN —— 按年、无洞,与 next_ncr_code 逐行同形
--   (自己的一把 advisory lock;MAX(split_part)+1 带 LIKE 过滤;前缀从 document_types 读;宽度 GREATEST(4, 位数) —— CODE-WIDTH-4)。
--   年份按【记录那一天】(record_incident 传 CURRENT_DATE),与 NCR / SMP 同一个先例 —— 编号是登记的顺序,不是事故发生的顺序。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.next_incident_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】INC 与 NCR / SMP 各自连号 —— 共用一把会让一种单据烧掉另一种的号。
    PERFORM pg_advisory_xact_lock(hashtext('incident_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM incidents
    WHERE code LIKE document_type_prefix('incident') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('incident') || '-' || v_year::text || '-' || LPAD(v_seq::text, GREATEST(4, length(v_seq::text)), '0');
END;
$function$;

-- db/functions/business_days_after.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q10,Tim):【某一天之后的第 n 个工作日】—— 从 p_date 的【下一天】数起,只数工作日
--   (is_business_day:周一到周五、不是新加坡的启用的公共假期 —— 汇率回溯与假期计算用的同一个定义),数到第 n 个,返回那一天。
--   n = 2、事故在星期五:星期一是第 1 个,星期二是第 2 个 → 星期二。
--   ★ 算不出来就返回 NULL,不猜一个日子:
--     · p_date 或 p_n 为空、或 p_n < 1;
--     · 数的过程中碰到的任何一天,它那一年在 public_holidays 里【一行启用的新加坡假期都没有】—— 那一年的日历缺了,
--       "这一天是不是工作日"答不出来(hr_alerts 的 holiday_calendar_missing 用的是同一条判据)。屏幕上说"算不出来"。
--   STABLE,不读调用者是谁:谁都可以调(它只读公共假期表,而那张表对每一个登录的人可读)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.business_days_after(p_date date, p_n integer)
 RETURNS date
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_day     date := p_date;
    v_counted integer := 0;
    v_steps   integer := 0;
    v_year    integer := NULL;
BEGIN
    IF p_date IS NULL OR p_n IS NULL OR p_n < 1 THEN
        RETURN NULL;
    END IF;
    WHILE v_counted < p_n LOOP
        v_day := v_day + 1;
        v_steps := v_steps + 1;
        -- 有界:一年最多 366 天,任何 n 都不会让这个循环数过十年 —— 真到那一步,是日历本身出了问题
        IF v_steps > 3660 THEN
            RETURN NULL;
        END IF;
        IF v_year IS DISTINCT FROM EXTRACT(YEAR FROM v_day)::integer THEN
            v_year := EXTRACT(YEAR FROM v_day)::integer;
            IF NOT EXISTS (SELECT 1 FROM public_holidays h
                            WHERE h.is_active AND h.country = 'SG' AND EXTRACT(YEAR FROM h.holiday_date)::integer = v_year) THEN
                RETURN NULL;
            END IF;
        END IF;
        IF is_business_day(v_day) THEN
            v_counted := v_counted + 1;
        END IF;
    END LOOP;
    RETURN v_day;
END;
$function$;

-- db/functions/record_incident.sql
-- MES-7b-1(2026-10-16,MES-0 Q73 · Q76;MES-7b Step 0 Q3 · Q5 · Q6 · Q9 · Q10 · Q28,Tim):【记一件事故】—— module.safety.edit(Q28:今天
--   admin · cto · warehouse;放宽到每一个查看码的持有人是 Tim 以后的一句授权)。没有审批(Q18:一件事故是一件发生过的事的记录)。
--
--   判的顺序就是人下一步该改什么的顺序:
--     ① 种类必填(INCIDENT_KIND_REQUIRED)· 发生时刻必填(INCIDENT_TIME_REQUIRED —— 世界那一侧的事实,不给默认值)·
--        发生了什么(INCIDENT_WHAT_REQUIRED)· 当场做了什么(INCIDENT_ACTION_REQUIRED)· 负责的人(一名员工或一个名字,INCIDENT_RESPONSIBLE_REQUIRED)·
--        要不要通报 NEA(是 / 否必须回答,INCIDENT_NEA_REPORTABLE_REQUIRED —— Q10:没有规矩替人判,也没有默认)。
--     ② 来源:manual;device 保留(INCIDENT_SOURCE_RESERVED|device,Q5)。
--     ③ 可选项:库位存在(LOCATION_NOT_FOUND|<id>)· 机器是一台在册的设备(equipment_record_target:EQUIPMENT_NOT_FOUND /
--        EQUIPMENT_NOT_A_MACHINE)· 时长 ≥ 0(INCIDENT_DURATION_INVALID)· 引用停机就要先说出机器(INCIDENT_DOWNTIME_NEEDS_MACHINE)·
--        负责的员工存在(EMPLOYEE_NOT_FOUND)。
--     ④ 受伤的细节(Q6):受伤的人最多一个 —— 一名员工或一个名字(INCIDENT_INJURED_ONE_PERSON);伤情 / 处理 / 误工天数要说的是某一个人
--        (INCIDENT_INJURY_NEEDS_PERSON);误工天数 ≥ 0(INCIDENT_DAYS_LOST_INVALID)。任何持 module.safety.edit 的人都记得进去 ——
--        记下之后读它要 data.view_health(或就是受伤的那名员工本人),记录人自己看见的可能是「受限」。
--     ⑤ 表上的守卫(guard_incident_write)再判【行】:时刻不在未来(INCIDENT_TIME_IN_FUTURE)· 种类在清单里、启用着 ·
--        停机是同一台机器的、没作废 · 异常事件存在、没撤回 —— 对每一个写入者都成立,这里不写第二份。
--   编号 INC-YYYY-NNNN(next_incident_code,记录那一天的年)。返回 {incident_id, code}。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.record_incident(p_kind_code text, p_occurred_at timestamp with time zone, p_what_happened text, p_immediate_action text, p_nea_reportable boolean, p_responsible_employee_id uuid DEFAULT NULL::uuid, p_responsible_name text DEFAULT NULL::text, p_location_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_duration_min numeric DEFAULT NULL::numeric, p_downtime_id uuid DEFAULT NULL::uuid, p_run_event_id bigint DEFAULT NULL::bigint, p_injured_employee_id uuid DEFAULT NULL::uuid, p_injured_person_name text DEFAULT NULL::text, p_injury_nature text DEFAULT NULL::text, p_injury_treatment text DEFAULT NULL::text, p_days_lost numeric DEFAULT NULL::numeric, p_source text DEFAULT 'manual'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user          uuid := auth.uid();
    v_id            uuid := gen_random_uuid();
    v_code          text;
    v_resp_name     text := NULLIF(btrim(COALESCE(p_responsible_name, '')), '');
    v_injured_name  text := NULLIF(btrim(COALESCE(p_injured_person_name, '')), '');
    v_nature        text := NULLIF(btrim(COALESCE(p_injury_nature, '')), '');
    v_treatment     text := NULLIF(btrim(COALESCE(p_injury_treatment, '')), '');
BEGIN
    PERFORM require_permission('module.safety.edit');

    -- ① 必填
    IF p_kind_code IS NULL OR btrim(p_kind_code) = '' THEN
        RAISE EXCEPTION 'INCIDENT_KIND_REQUIRED';
    END IF;
    IF p_occurred_at IS NULL THEN
        RAISE EXCEPTION 'INCIDENT_TIME_REQUIRED';
    END IF;
    IF p_what_happened IS NULL OR btrim(p_what_happened) = '' THEN
        RAISE EXCEPTION 'INCIDENT_WHAT_REQUIRED';
    END IF;
    IF p_immediate_action IS NULL OR btrim(p_immediate_action) = '' THEN
        RAISE EXCEPTION 'INCIDENT_ACTION_REQUIRED';
    END IF;
    IF p_responsible_employee_id IS NULL AND v_resp_name IS NULL THEN
        RAISE EXCEPTION 'INCIDENT_RESPONSIBLE_REQUIRED';
    END IF;
    IF p_nea_reportable IS NULL THEN
        RAISE EXCEPTION 'INCIDENT_NEA_REPORTABLE_REQUIRED'
          USING HINT = '工伤或火灾事故须立即通报 NEA,并在规定的工作日内提交书面报告 —— 这一件要不要通报,由记录的人回答。';
    END IF;

    -- ② 来源
    IF p_source IS DISTINCT FROM 'manual' THEN
        RAISE EXCEPTION 'INCIDENT_SOURCE_RESERVED|%', COALESCE(p_source, '?');
    END IF;

    -- ③ 可选项
    IF p_location_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = p_location_id) THEN
        RAISE EXCEPTION 'LOCATION_NOT_FOUND|%', p_location_id;
    END IF;
    IF p_equipment_id IS NOT NULL THEN
        PERFORM equipment_record_target(p_equipment_id);
    END IF;
    IF p_duration_min IS NOT NULL AND p_duration_min < 0 THEN
        RAISE EXCEPTION 'INCIDENT_DURATION_INVALID';
    END IF;
    IF p_downtime_id IS NOT NULL AND p_equipment_id IS NULL THEN
        RAISE EXCEPTION 'INCIDENT_DOWNTIME_NEEDS_MACHINE';
    END IF;
    IF p_responsible_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM employees WHERE id = p_responsible_employee_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', p_responsible_employee_id;
    END IF;

    -- ④ 受伤的细节
    IF p_injured_employee_id IS NOT NULL AND v_injured_name IS NOT NULL THEN
        RAISE EXCEPTION 'INCIDENT_INJURED_ONE_PERSON';
    END IF;
    IF (v_nature IS NOT NULL OR v_treatment IS NOT NULL OR p_days_lost IS NOT NULL)
       AND p_injured_employee_id IS NULL AND v_injured_name IS NULL THEN
        RAISE EXCEPTION 'INCIDENT_INJURY_NEEDS_PERSON';
    END IF;
    IF p_days_lost IS NOT NULL AND p_days_lost < 0 THEN
        RAISE EXCEPTION 'INCIDENT_DAYS_LOST_INVALID';
    END IF;
    IF p_injured_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM employees WHERE id = p_injured_employee_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', p_injured_employee_id;
    END IF;

    v_code := next_incident_code(CURRENT_DATE);
    INSERT INTO incidents (id, code, kind_code, occurred_at, location_id, equipment_id, duration_min, what_happened, immediate_action,
                           responsible_employee_id, responsible_name, nea_reportable, source, downtime_id, run_event_id,
                           injured_employee_id, injured_person_name, injury_nature, injury_treatment, days_lost, recorded_by)
    VALUES (v_id, v_code, btrim(p_kind_code), p_occurred_at, p_location_id, p_equipment_id, p_duration_min, btrim(p_what_happened),
            btrim(p_immediate_action), p_responsible_employee_id, v_resp_name, p_nea_reportable, 'manual', p_downtime_id, p_run_event_id,
            p_injured_employee_id, v_injured_name, v_nature, v_treatment, p_days_lost, v_user);
    RETURN jsonb_build_object('incident_id', v_id, 'code', v_code);
END;
$function$;

-- db/functions/record_incident_update.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q10,Tim):【一件事故之后的一个事实】—— 事故那一行不改,这里加一行(incident_updates)。
--   module.safety.edit(记事故的同一个码)。返回 {update_id, kind}。
--
--   nea_notified / report_submitted —— 只对【现在】要通报的事故(更正过的值说了算,incident_current_all)收(INCIDENT_NOT_NEA_REPORTABLE|<编号>);
--     什么时候必填(INCIDENT_UPDATE_TIME_REQUIRED)、不在未来(INCIDENT_UPDATE_TIME_IN_FUTURE)、不早于事故(INCIDENT_UPDATE_BEFORE_INCIDENT);
--     编号 / 怎么通报的可选。每件各一行(INCIDENT_ALREADY_RECORDED|<种类>)。两者之间不规定先后(没有人裁过)。
--   closed —— 一句总结必填(INCIDENT_CLOSE_SUMMARY_REQUIRED);每件一行。关闭不清掉两条 NEA 提醒:法定的义务不因"关闭"而结束。
--   correction —— 关闭之后不收(INCIDENT_CLOSED|<编号>);字段只认七个(INCIDENT_CORRECTION_FIELD_INVALID|<字段>);理由必填
--     (INCIDENT_CORRECTION_REASON_REQUIRED);新值按字段判(INCIDENT_CORRECTION_VALUE_INVALID|<字段>):种类在清单里而且启用着、时刻读得出来
--     而且不在未来(INCIDENT_TIME_IN_FUTURE)、文字不是空白、时长是 ≥ 0 的数、通报是 true / false;与现在的值相同就不是一次更正
--     (INCIDENT_CORRECTION_NO_CHANGE|<字段>)。新值存成规范的字(时刻 → ISO,布尔 → true / false),读的一侧照它转回去。
--   同一件事故的两次更新排队(advisory lock),于是"每件一行"与"与现在的值相同"不会被并发绕过(部分唯一索引是第二道)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.record_incident_update(p_incident_id uuid, p_kind text, p_occurred_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_reference text DEFAULT NULL::text, p_field text DEFAULT NULL::text, p_new_value text DEFAULT NULL::text, p_reason text DEFAULT NULL::text, p_summary text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_cur   record;
    v_new   text;
    v_old   text;
    v_ts    timestamptz;
    v_num   numeric;
    v_id    bigint;
BEGIN
    PERFORM require_permission('module.safety.edit');
    IF p_incident_id IS NULL OR NOT EXISTS (SELECT 1 FROM incidents WHERE id = p_incident_id) THEN
        RAISE EXCEPTION 'INCIDENT_NOT_FOUND|%', COALESCE(p_incident_id::text, '?');
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('incident_update_' || p_incident_id::text)::bigint);
    SELECT * INTO v_cur FROM incident_current_all c WHERE c.id = p_incident_id;

    IF p_kind IS NULL OR p_kind NOT IN ('nea_notified', 'report_submitted', 'closed', 'correction') THEN
        RAISE EXCEPTION 'INCIDENT_UPDATE_KIND_INVALID|%', COALESCE(p_kind, '?');
    END IF;

    IF p_kind IN ('nea_notified', 'report_submitted') THEN
        IF NOT v_cur.nea_reportable THEN
            RAISE EXCEPTION 'INCIDENT_NOT_NEA_REPORTABLE|%', v_cur.code;
        END IF;
        IF p_occurred_at IS NULL THEN
            RAISE EXCEPTION 'INCIDENT_UPDATE_TIME_REQUIRED';
        END IF;
        IF p_occurred_at > now() THEN
            RAISE EXCEPTION 'INCIDENT_UPDATE_TIME_IN_FUTURE';
        END IF;
        IF p_occurred_at < v_cur.occurred_at THEN
            RAISE EXCEPTION 'INCIDENT_UPDATE_BEFORE_INCIDENT|%', to_char(v_cur.occurred_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
        END IF;
        IF EXISTS (SELECT 1 FROM incident_updates WHERE incident_id = p_incident_id AND kind = p_kind) THEN
            RAISE EXCEPTION 'INCIDENT_ALREADY_RECORDED|%', p_kind;
        END IF;
        INSERT INTO incident_updates (incident_id, kind, occurred_at, reference, recorded_by)
        VALUES (p_incident_id, p_kind, p_occurred_at, NULLIF(btrim(COALESCE(p_reference, '')), ''), v_user)
        RETURNING id INTO v_id;
        RETURN jsonb_build_object('update_id', v_id, 'kind', p_kind);
    END IF;

    IF p_kind = 'closed' THEN
        IF p_summary IS NULL OR btrim(p_summary) = '' THEN
            RAISE EXCEPTION 'INCIDENT_CLOSE_SUMMARY_REQUIRED';
        END IF;
        IF v_cur.closed_at IS NOT NULL THEN
            RAISE EXCEPTION 'INCIDENT_ALREADY_RECORDED|closed';
        END IF;
        INSERT INTO incident_updates (incident_id, kind, summary, recorded_by)
        VALUES (p_incident_id, 'closed', btrim(p_summary), v_user)
        RETURNING id INTO v_id;
        RETURN jsonb_build_object('update_id', v_id, 'kind', 'closed');
    END IF;

    -- correction
    IF v_cur.closed_at IS NOT NULL THEN
        RAISE EXCEPTION 'INCIDENT_CLOSED|%', v_cur.code;
    END IF;
    IF p_field IS NULL OR p_field NOT IN ('kind_code', 'occurred_at', 'what_happened', 'immediate_action', 'responsible_name',
                                          'duration_min', 'nea_reportable') THEN
        RAISE EXCEPTION 'INCIDENT_CORRECTION_FIELD_INVALID|%', COALESCE(p_field, '?');
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'INCIDENT_CORRECTION_REASON_REQUIRED';
    END IF;
    v_new := NULLIF(btrim(COALESCE(p_new_value, '')), '');
    IF v_new IS NULL THEN
        RAISE EXCEPTION 'INCIDENT_CORRECTION_VALUE_INVALID|%', p_field;
    END IF;
    IF p_field = 'kind_code' THEN
        IF NOT EXISTS (SELECT 1 FROM incident_kinds k WHERE k.code = v_new) THEN
            RAISE EXCEPTION 'INCIDENT_KIND_UNKNOWN|%', v_new;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM incident_kinds k WHERE k.code = v_new AND k.is_active) THEN
            RAISE EXCEPTION 'INCIDENT_KIND_INACTIVE|%', v_new;
        END IF;
        v_old := v_cur.kind_code;
    ELSIF p_field = 'occurred_at' THEN
        BEGIN
            v_ts := v_new::timestamptz;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'INCIDENT_CORRECTION_VALUE_INVALID|occurred_at';
        END;
        IF v_ts > now() THEN
            RAISE EXCEPTION 'INCIDENT_TIME_IN_FUTURE|%', to_char(v_ts AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
        END IF;
        v_new := to_char(v_ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
        v_old := to_char(v_cur.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
    ELSIF p_field = 'duration_min' THEN
        BEGIN
            v_num := v_new::numeric;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'INCIDENT_CORRECTION_VALUE_INVALID|duration_min';
        END;
        IF v_num < 0 THEN
            RAISE EXCEPTION 'INCIDENT_CORRECTION_VALUE_INVALID|duration_min';
        END IF;
        v_new := v_num::text;
        v_old := v_cur.duration_min::text;
        IF v_cur.duration_min IS NOT NULL AND v_cur.duration_min = v_num THEN
            v_old := v_new;
        END IF;
    ELSIF p_field = 'nea_reportable' THEN
        IF lower(v_new) NOT IN ('true', 'false') THEN
            RAISE EXCEPTION 'INCIDENT_CORRECTION_VALUE_INVALID|nea_reportable';
        END IF;
        v_new := lower(v_new);
        v_old := v_cur.nea_reportable::text;
    ELSIF p_field = 'what_happened' THEN
        v_old := v_cur.what_happened;
    ELSIF p_field = 'immediate_action' THEN
        v_old := v_cur.immediate_action;
    ELSE
        v_old := v_cur.responsible_name;
    END IF;
    IF v_new IS NOT DISTINCT FROM v_old THEN
        RAISE EXCEPTION 'INCIDENT_CORRECTION_NO_CHANGE|%', p_field;
    END IF;
    INSERT INTO incident_updates (incident_id, kind, field, new_value, reason, recorded_by)
    VALUES (p_incident_id, 'correction', p_field, v_new, btrim(p_reason), v_user)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('update_id', v_id, 'kind', 'correction', 'field', p_field);
END;
$function$;

-- db/functions/suggest_incident_batches.sql
-- MES-7b-1(2026-10-16,MES-0 Q73;MES-7b Step 0 Q7,Tim):【这件事故可能碰过哪几批货】—— 只是建议,一条都不自动链上。两种,而且【不编一个时间窗】:
--   location     事故有库位时:那一刻在那个库位上有货的批 —— 那个库位上、发生时刻(更正过的)【之前或正好那一刻】的流水,按批求净数,> 0 的才列。
--                evidence = 库位编号;qty = 那一刻的净数(那一批自己的单位)。
--   machine_run  事故有机器时:那一刻正在那台机器上跑的加工单 —— 已提交、没删、[started_at, ended_at) 包含发生时刻;它的投入批与产出批。
--                没记开始或结束时刻的加工单说不出那一刻在不在跑,不列(那是一条缺了的记录,不是一条规矩)。
--                evidence = 加工单号;qty = 投入的数量 / 产出的数量。
--   already_linked:这一批现在有没有一条有效链接挂在这件事故上(页面据此把"确认"换成"已链上")。
--   一批同时由两种建议而来时各列一行(两种理由都说出来)。
--   【门】module.safety.view —— 读不到就按名拒(一个返回集合的函数用"零行"表示拒绝,与"真的没有建议"分不开 —— AGENTS.md)。
--   【DEFINER】流水、库位、加工单各有各的读策略;建议要看见的是【那一刻的事实】,不是读者恰好读得到的那几行。返回的只有批号与数量,不带价。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.suggest_incident_batches(p_incident_id uuid)
 RETURNS TABLE(batch_kind text, batch_id uuid, batch_code text, basis text, evidence text, qty numeric, already_linked boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cur record;
BEGIN
    PERFORM require_permission('module.safety.view');
    SELECT c.id, c.occurred_at, c.location_id, c.equipment_id INTO v_cur FROM incident_current_all c WHERE c.id = p_incident_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INCIDENT_NOT_FOUND|%', COALESCE(p_incident_id::text, '?');
    END IF;
    RETURN QUERY
    WITH s AS (
        -- ① 那一刻在事故库位上有货的批
        SELECT 'inbound'::text AS k, m.inbound_batch_id AS b, 'location'::text AS why, l.code AS ev, sum(m.qty_delta) AS q
          FROM inventory_movements m
          JOIN storage_locations l ON l.id = m.location_id
          JOIN inbound_batches ib ON ib.id = m.inbound_batch_id AND ib.deleted_at IS NULL
         WHERE v_cur.location_id IS NOT NULL AND m.location_id = v_cur.location_id AND m.occurred_at <= v_cur.occurred_at
           AND m.inbound_batch_id IS NOT NULL
         GROUP BY m.inbound_batch_id, l.code
        HAVING sum(m.qty_delta) > 0
        UNION ALL
        SELECT 'output'::text, m.output_batch_id, 'location'::text, l.code, sum(m.qty_delta)
          FROM inventory_movements m
          JOIN storage_locations l ON l.id = m.location_id
          JOIN output_batches ob ON ob.id = m.output_batch_id AND ob.deleted_at IS NULL
         WHERE v_cur.location_id IS NOT NULL AND m.location_id = v_cur.location_id AND m.occurred_at <= v_cur.occurred_at
           AND m.output_batch_id IS NOT NULL
         GROUP BY m.output_batch_id, l.code
        HAVING sum(m.qty_delta) > 0
        UNION ALL
        -- ② 那一刻在那台机器上跑的加工单的投入与产出
        SELECT CASE WHEN pi.inbound_batch_id IS NOT NULL THEN 'inbound'::text ELSE 'output'::text END,
               COALESCE(pi.inbound_batch_id, pi.output_batch_id), 'machine_run'::text, r.code, sum(pi.quantity_consumed)
          FROM processing_runs r
          JOIN processing_inputs pi ON pi.run_id = r.id
         WHERE v_cur.equipment_id IS NOT NULL AND r.equipment_id = v_cur.equipment_id AND r.status = 'committed' AND r.deleted_at IS NULL
           AND r.started_at IS NOT NULL AND r.ended_at IS NOT NULL
           AND r.started_at <= v_cur.occurred_at AND r.ended_at > v_cur.occurred_at
           AND COALESCE(pi.inbound_batch_id, pi.output_batch_id) IS NOT NULL
         GROUP BY 1, 2, r.code
        UNION ALL
        SELECT 'output'::text, po.output_batch_id, 'machine_run'::text, r.code, sum(po.quantity_produced)
          FROM processing_runs r
          JOIN processing_outputs po ON po.run_id = r.id
         WHERE v_cur.equipment_id IS NOT NULL AND r.equipment_id = v_cur.equipment_id AND r.status = 'committed' AND r.deleted_at IS NULL
           AND r.started_at IS NOT NULL AND r.ended_at IS NOT NULL
           AND r.started_at <= v_cur.occurred_at AND r.ended_at > v_cur.occurred_at
         GROUP BY po.output_batch_id, r.code
    )
    SELECT s.k, s.b, COALESCE(ib.code, ob.code), s.why, s.ev, s.q,
           EXISTS (SELECT 1 FROM incident_batches x
                    WHERE x.incident_id = p_incident_id AND x.unlinked_at IS NULL
                      AND COALESCE(x.inbound_batch_id, x.output_batch_id) = s.b)
      FROM s
      LEFT JOIN inbound_batches ib ON s.k = 'inbound' AND ib.id = s.b
      LEFT JOIN output_batches ob ON s.k = 'output' AND ob.id = s.b
     ORDER BY s.why, COALESCE(ib.code, ob.code);
END;
$function$;

-- db/functions/link_incident_batch.sql
-- MES-7b-1(2026-10-16,MES-0 Q73;MES-7b Step 0 Q7,Tim):【确认一批货碰过这件事故】—— module.safety.edit。一个人按下一次,建一行链接。
--   basis = location / machine_run:确认一条建议 —— 这一批此刻必须仍在 suggest_incident_batches 的那一种建议里
--     (INCIDENT_LINK_NOT_SUGGESTED|<种类>|<批号>:建议是从记录算出来的,不由页面送来的字说了算);
--   basis = picked:按批号挑任何一批(存在、没删)。
--   按名拒:恰好一批(INCIDENT_LINK_ONE_BATCH)· 依据不认得(INCIDENT_LINK_BASIS_INVALID|<值>)· 找不到事故 / 批次 ·
--   这一批已经有一条有效链接挂在这件事故上(INCIDENT_BATCH_ALREADY_LINKED|<批号>)。
--   【一条链接从不设任何安全状态,也不动库存】(MES-0 Q73,Tim)—— 本函数只写 incident_batches 这一行。要扣住那一批,是事故页上开一张
--   来源 incident 的不合格报告(Q8)。返回 {link_id}。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.link_incident_batch(p_incident_id uuid, p_basis text, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch uuid := COALESCE(p_inbound_batch_id, p_output_batch_id);
    v_kind  text := CASE WHEN p_inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END;
    v_code  text;
    v_id    bigint;
BEGIN
    PERFORM require_permission('module.safety.edit');
    IF p_incident_id IS NULL OR NOT EXISTS (SELECT 1 FROM incidents WHERE id = p_incident_id) THEN
        RAISE EXCEPTION 'INCIDENT_NOT_FOUND|%', COALESCE(p_incident_id::text, '?');
    END IF;
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'INCIDENT_LINK_ONE_BATCH';
    END IF;
    IF p_basis IS NULL OR p_basis NOT IN ('location', 'machine_run', 'picked') THEN
        RAISE EXCEPTION 'INCIDENT_LINK_BASIS_INVALID|%', COALESCE(p_basis, '?');
    END IF;
    IF p_inbound_batch_id IS NOT NULL THEN
        SELECT code INTO v_code FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
        END IF;
    ELSE
        SELECT code INTO v_code FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
        END IF;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('incident_link_' || p_incident_id::text)::bigint);
    IF p_basis <> 'picked' AND NOT EXISTS (
        SELECT 1 FROM suggest_incident_batches(p_incident_id) s
         WHERE s.basis = p_basis AND s.batch_kind = v_kind AND s.batch_id = v_batch) THEN
        RAISE EXCEPTION 'INCIDENT_LINK_NOT_SUGGESTED|%|%', p_basis, v_code;
    END IF;
    IF EXISTS (SELECT 1 FROM incident_batches x
                WHERE x.incident_id = p_incident_id AND x.unlinked_at IS NULL
                  AND COALESCE(x.inbound_batch_id, x.output_batch_id) = v_batch) THEN
        RAISE EXCEPTION 'INCIDENT_BATCH_ALREADY_LINKED|%', v_code;
    END IF;
    INSERT INTO incident_batches (incident_id, inbound_batch_id, output_batch_id, basis, linked_by)
    VALUES (p_incident_id, p_inbound_batch_id, p_output_batch_id, p_basis, auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('link_id', v_id, 'batch_code', v_code);
END;
$function$;

-- db/functions/unlink_incident_batch.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q7,Tim):【这一批其实没碰过这件事故】—— 解一条链接,理由必填。module.safety.edit。
--   那一行链接只改这一次(unlinked_at / unlinked_by / unlink_reason);之后不改、不删(guard_incident_batch_write)。
--   按名拒:找不到(INCIDENT_LINK_NOT_FOUND|<id>)· 已经解过(INCIDENT_LINK_ALREADY_UNLINKED|<批号>)· 没有理由(INCIDENT_UNLINK_REASON_REQUIRED)。
--   不碰安全状态、不碰库存、不碰挂在那一批上的不合格报告(那张报告由决定它的人放行)。返回 {link_id}。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.unlink_incident_batch(p_link_id bigint, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link record;
BEGIN
    PERFORM require_permission('module.safety.edit');
    SELECT b.*, COALESCE(ib.code, ob.code) AS batch_code INTO v_link
      FROM incident_batches b
      LEFT JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
      LEFT JOIN output_batches ob ON ob.id = b.output_batch_id
     WHERE b.id = p_link_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INCIDENT_LINK_NOT_FOUND|%', COALESCE(p_link_id::text, '?');
    END IF;
    IF v_link.unlinked_at IS NOT NULL THEN
        RAISE EXCEPTION 'INCIDENT_LINK_ALREADY_UNLINKED|%', v_link.batch_code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'INCIDENT_UNLINK_REASON_REQUIRED';
    END IF;
    UPDATE incident_batches
       SET unlinked_at = now(), unlinked_by = auth.uid(), unlink_reason = btrim(p_reason)
     WHERE id = p_link_id;
    RETURN jsonb_build_object('link_id', p_link_id);
END;
$function$;

-- db/functions/set_safety_settings.sql
-- MES-7b-1(2026-10-16,MES-0 §5.1 V19 · Q93;MES-7b Step 0 Q11,Tim):【改 V19 / 对着执照确认它】—— module.safety.edit。
--   p_nea_report_working_days:书面报告的工作日数(空 = Not yet set;> 0,否则 SAFETY_REPORT_DAYS_INVALID)。
--   p_confirmed:true = 这个数已经对着 NEA 执照核过(记下确认的时刻与人);false = 未确认(期限照算,标"未确认",V19 留在待补的值上)。
--     没有数不能确认(SAFETY_CONFIRM_NEEDS_VALUE)。【改了数而不确认,就回到未确认】—— 一个改过的数不继承上一个数的确认。
--   p_source:这个数从哪里来(可选,例如执照的条款号);空 = 清掉引导值那句出处(那句说的是引导值,不是新数)。
--   修改史在变更记录里(主语 safety_settings)。返回这一行。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.set_safety_settings(p_nea_report_working_days integer, p_confirmed boolean, p_source text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_row  safety_settings%ROWTYPE;
BEGIN
    PERFORM require_permission('module.safety.edit');
    IF p_nea_report_working_days IS NOT NULL AND p_nea_report_working_days < 1 THEN
        RAISE EXCEPTION 'SAFETY_REPORT_DAYS_INVALID';
    END IF;
    IF COALESCE(p_confirmed, false) AND p_nea_report_working_days IS NULL THEN
        RAISE EXCEPTION 'SAFETY_CONFIRM_NEEDS_VALUE';
    END IF;
    UPDATE safety_settings
       SET nea_report_working_days = p_nea_report_working_days,
           nea_report_days_source = NULLIF(btrim(COALESCE(p_source, '')), ''),
           nea_report_days_confirmed_at = CASE WHEN COALESCE(p_confirmed, false) THEN now() END,
           nea_report_days_confirmed_by = CASE WHEN COALESCE(p_confirmed, false) THEN v_user END,
           updated_by = v_user
     WHERE id
    RETURNING * INTO v_row;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SAFETY_SETTINGS_MISSING';
    END IF;
    RETURN to_jsonb(v_row);
END;
$function$;

-- ── 8 · 换签名(末尾多一个带默认的参数):DROP 旧的,CREATE 新的 —— 两支并存是一次镜像看不见的重载 ─────────────
DROP FUNCTION public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid);
DROP FUNCTION public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint);
DROP FUNCTION public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[]);

-- db/functions/ncr_open_internal.sql
-- MES-6b-1(2026-10-15,MES-6b Step 0 Q7):落一张不合格报告 —— 取号、写一行 open。两个调用方各自先把关:
--   open_ncr(人开的:module.quality.edit、来源、描述、指向是不是同一批、除了开单人还有没有人能决定)与
--   judge_quality_limits(系统开的:一次 V17 越限,opened_by 为空)。
--   ★ 内层算子:不问码、不判来源;EXECUTE 已从 authenticated 收回(zzz_function_grants)。返回 {ncr_id, code}。
--   ★ MES-7b-1(2026-10-16,MES-7b Step 0 Q8):末尾多一个 p_incident_id(带默认 NULL)—— 来源 incident 的那一张指着它那件事故
--     (表上 nonconformance_reports_incident_source:来源 incident ⇔ 有事故)。签名变了,迁移先 DROP 旧的再建;judge_quality_limits
--     按位置传九个参数,照旧落到这一支(第十个取默认)。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE FUNCTION public.ncr_open_internal(p_inbound_batch_id uuid, p_output_batch_id uuid, p_source text, p_description text, p_assay_result_id uuid, p_assay_dispute_id uuid, p_sales_order_id uuid, p_judgement_id bigint, p_opened_by uuid, p_incident_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id   uuid := gen_random_uuid();
    v_code text;
BEGIN
    v_code := next_ncr_code(CURRENT_DATE);
    INSERT INTO nonconformance_reports (id, code, inbound_batch_id, output_batch_id, source, description,
                                        assay_result_id, assay_dispute_id, sales_order_id, judgement_id, opened_by, incident_id)
    VALUES (v_id, v_code, p_inbound_batch_id, p_output_batch_id, p_source, btrim(p_description),
            p_assay_result_id, p_assay_dispute_id, p_sales_order_id, p_judgement_id, p_opened_by, p_incident_id);
    RETURN jsonb_build_object('ncr_id', v_id, 'code', v_code);
END;
$function$;

-- db/functions/open_ncr.sql
-- MES-6b-1(2026-10-15,MES-0 Q65 · Q66;MES-6b Step 0 Q2 · Q7 · Q9,Tim):【开一张不合格报告】—— 人开的那一种(manual · customer_complaint);
--   开下来这一批就在质量暂扣里(batch_quality_hold),直到另一个人决定它。module.quality.edit(取样、立争议的同一个码;admin · cco · cto)。
--
--   判的顺序就是人下一步该改什么的顺序:
--     ① 恰好一批(NCR_ONE_BATCH),存在、没删(INBOUND_NOT_FOUND / OUTPUT_NOT_FOUND)。
--     ② 来源:manual · customer_complaint · incident(MES-7b-1,见下);quality_limit 只由系统开(NCR_SOURCE_SYSTEM_ONLY —— 一次 V17 越限由判定当场开,人不替它开);
--        inspection 留给 MES-7b(NCR_SOURCE_RESERVED|inspection);别的 NCR_SOURCE_INVALID|<值>。
--     ③ 描述必填(NCR_DESCRIPTION_REQUIRED)。
--     ④ 可选的指向都必须是同一批的:化验、争议、判定(NCR_LINK_NOT_FOR_BATCH|<种类>|<编号或 id>);销售单只有产出批有
--        (NCR_SALES_ORDER_OUTPUT_ONLY),而且必须是这一批预留过或发过的那几张之一(NCR_LINK_NOT_FOR_BATCH|sales_order|<单号>)。
--     ⑤ ★ 除了开单人这个【人】之外,没有一个真持有人持 action.ncr_decide → 不让它生下来(NCR_NO_OTHER_DECIDER)—— 开单人永远不能决定
--        自己开的那一张,于是没有别人的时候它会是一张永远决定不了、却一直扣着货的报告(配料计划 BLEND_NO_OTHER_RELEASER 同一句判据:
--        real_role_grants · self_leg 按人认,跨账号;不看审批开关)。
--   一批可以同时有几张开着的(Q7)—— 本支不拒"已经有一张开着"。返回 {ncr_id, code, status}。
--   ★ MES-7b-1(2026-10-16,MES-7b Step 0 Q8,Tim):第三种人开的来源 incident —— 事故页上,持 module.quality.edit 的人对一批【链在那件事故上】
--     的货开一张(p_incident_id,末尾带默认的新参数;签名变了,迁移先 DROP 旧的再建,既有的具名调用照旧走得通):
--     来源 incident 而没给事故 → NCR_INCIDENT_REQUIRED;给了事故而来源不是 incident → NCR_INCIDENT_ONLY_WITH_SOURCE;
--     找不到那件事故 → INCIDENT_NOT_FOUND|<id>;那一批此刻没有一条有效链接挂在那件事故上 → NCR_INCIDENT_BATCH_NOT_LINKED|<事故编号>。
--     事故自己从不扣货 —— 扣货的是这一张报告,照既有的质量暂扣,由持 action.ncr_decide 的另一个人决定。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE FUNCTION public.open_ncr(p_source text, p_description text, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_assay_result_id uuid DEFAULT NULL::uuid, p_assay_dispute_id uuid DEFAULT NULL::uuid, p_sales_order_id uuid DEFAULT NULL::uuid, p_judgement_id bigint DEFAULT NULL::bigint, p_incident_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_r    jsonb;
BEGIN
    PERFORM require_permission('module.quality.edit');

    -- ① 恰好一批,存在、没删
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'NCR_ONE_BATCH';
    END IF;
    IF p_inbound_batch_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;
    IF p_output_batch_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;

    -- ② 来源
    IF p_source = 'quality_limit' THEN
        RAISE EXCEPTION 'NCR_SOURCE_SYSTEM_ONLY'
          USING HINT = '一次质量验收限的越限由系统在判定那一刻自己开报告 —— 人开的报告选"手动"或"客户投诉"。';
    ELSIF p_source = 'inspection' THEN
        RAISE EXCEPTION 'NCR_SOURCE_RESERVED|inspection'
          USING HINT = '来料检验开出的报告随 MES-7b 一起来;今天请选"手动"。';
    ELSIF p_source IS NULL OR p_source NOT IN ('manual', 'customer_complaint', 'incident') THEN
        RAISE EXCEPTION 'NCR_SOURCE_INVALID|%', COALESCE(p_source, '?');
    END IF;
    -- ②b 来源 incident ⇔ 指着一件事故,而且那一批链在它上面(MES-7b-1 Q8)
    IF p_source = 'incident' AND p_incident_id IS NULL THEN
        RAISE EXCEPTION 'NCR_INCIDENT_REQUIRED';
    END IF;
    IF p_source <> 'incident' AND p_incident_id IS NOT NULL THEN
        RAISE EXCEPTION 'NCR_INCIDENT_ONLY_WITH_SOURCE';
    END IF;
    IF p_incident_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM incidents WHERE id = p_incident_id) THEN
            RAISE EXCEPTION 'INCIDENT_NOT_FOUND|%', p_incident_id;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM incident_batches b
                        WHERE b.incident_id = p_incident_id AND b.unlinked_at IS NULL
                          AND b.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
                          AND b.output_batch_id IS NOT DISTINCT FROM p_output_batch_id) THEN
            RAISE EXCEPTION 'NCR_INCIDENT_BATCH_NOT_LINKED|%', (SELECT code FROM incidents WHERE id = p_incident_id);
        END IF;
    END IF;

    -- ③ 描述必填
    IF p_description IS NULL OR btrim(p_description) = '' THEN
        RAISE EXCEPTION 'NCR_DESCRIPTION_REQUIRED';
    END IF;

    -- ④ 指向都必须是同一批的
    IF p_assay_result_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM assay_results a WHERE a.id = p_assay_result_id AND a.deleted_at IS NULL
           AND a.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
           AND a.output_batch_id IS NOT DISTINCT FROM p_output_batch_id) THEN
        RAISE EXCEPTION 'NCR_LINK_NOT_FOR_BATCH|assay|%',
            COALESCE((SELECT code FROM assay_results WHERE id = p_assay_result_id), p_assay_result_id::text);
    END IF;
    IF p_assay_dispute_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM assay_disputes d WHERE d.id = p_assay_dispute_id
           AND d.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
           AND d.output_batch_id IS NOT DISTINCT FROM p_output_batch_id) THEN
        RAISE EXCEPTION 'NCR_LINK_NOT_FOR_BATCH|dispute|%', p_assay_dispute_id;
    END IF;
    IF p_sales_order_id IS NOT NULL THEN
        IF p_output_batch_id IS NULL THEN
            RAISE EXCEPTION 'NCR_SALES_ORDER_OUTPUT_ONLY';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM sales_order_reservations r JOIN sales_order_lines l ON l.id = r.sales_order_line_id
                        WHERE l.sales_order_id = p_sales_order_id AND r.output_batch_id = p_output_batch_id)
           AND NOT EXISTS (SELECT 1 FROM shipment_lines sl JOIN sales_order_lines l ON l.id = sl.sales_order_line_id
                            WHERE l.sales_order_id = p_sales_order_id AND sl.output_batch_id = p_output_batch_id) THEN
            RAISE EXCEPTION 'NCR_LINK_NOT_FOR_BATCH|sales_order|%',
                COALESCE((SELECT code FROM sales_orders WHERE id = p_sales_order_id), p_sales_order_id::text);
        END IF;
    END IF;
    IF p_judgement_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM quality_limit_judgements j WHERE j.id = p_judgement_id AND j.output_batch_id = p_output_batch_id) THEN
        RAISE EXCEPTION 'NCR_LINK_NOT_FOR_BATCH|judgement|%', p_judgement_id;
    END IF;

    -- ⑤ 除了开单人之外,要有一个真持有人决定得了它
    IF NOT EXISTS (SELECT 1
                     FROM role_permissions rp
                     JOIN roles r ON r.id = rp.role_id
                    CROSS JOIN LATERAL real_role_grants(r.code) g
                    WHERE rp.permission_code = 'action.ncr_decide'
                      AND self_leg(v_user, NULL::uuid, g.user_id) = 'none') THEN
        RAISE EXCEPTION 'NCR_NO_OTHER_DECIDER'
          USING HINT = '开单人永远不能决定自己开的不合格报告,而此刻除你之外没有人持决定的码(action.ncr_decide)。请管理员先把这个码给另一个人。';
    END IF;

    v_r := ncr_open_internal(p_inbound_batch_id, p_output_batch_id, p_source, p_description,
                             p_assay_result_id, p_assay_dispute_id, p_sales_order_id, p_judgement_id, v_user, p_incident_id);
    RETURN v_r || jsonb_build_object('status', 'open');
END;
$function$;

-- db/functions/submit_shift_handover.sql
-- ★ MES-7b-1(2026-10-16,MES-7b Step 0 Q12,Tim):末尾多一个 p_incident_ids(带默认 NULL)—— 这次交接班指着哪几件事故
--   (shift_handover_incident_refs,引用不是副本;docs/forward-queue.md:2402 等的那一刻:登记簿建好之后交接班才引用事故)。
--   找不到的事故按名拒 HANDOVER_INCIDENT_NOT_FOUND。签名变了,迁移先 DROP 旧的再建;旧的具名调用不带它 → 默认值,照旧走得通。
CREATE FUNCTION public.submit_shift_handover(p_shift_code text, p_handover_date date, p_outgoing_employee_id uuid, p_incoming_employee_id uuid, p_notes text DEFAULT NULL::text, p_items jsonb DEFAULT NULL::jsonb, p_downtime_ids uuid[] DEFAULT NULL::uuid[], p_incident_ids uuid[] DEFAULT NULL::uuid[])
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
        -- U1-B(Q15):一段作废了的停机没有发生过,交接单不能引用它(新建交接单的勾选里本来就不列它)。
        IF EXISTS (SELECT 1 FROM unnest(p_downtime_ids) d
                     JOIN equipment_downtime e ON e.id = d
                    WHERE e.voided_at IS NOT NULL) THEN
            RAISE EXCEPTION 'HANDOVER_DOWNTIME_VOIDED';
        END IF;
        INSERT INTO shift_handover_equipment_refs (handover_id, downtime_id, created_by)
        SELECT v_id, d, v_user FROM unnest(p_downtime_ids) d
        ON CONFLICT DO NOTHING;
    END IF;

    -- MES-7b-1(Q12):事故也是一条【引用】—— 存 incident_id,不抄一句"发生了什么"。
    IF p_incident_ids IS NOT NULL AND array_length(p_incident_ids, 1) > 0 THEN
        IF EXISTS (SELECT 1 FROM unnest(p_incident_ids) x
                    WHERE NOT EXISTS (SELECT 1 FROM incidents i WHERE i.id = x)) THEN
            RAISE EXCEPTION 'HANDOVER_INCIDENT_NOT_FOUND';
        END IF;
        INSERT INTO shift_handover_incident_refs (handover_id, incident_id, created_by)
        SELECT v_id, x, v_user FROM unnest(p_incident_ids) x
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_id;
END;
$function$;

-- ── 9 · 换掉的函数(镜像原样,同签名):审计主语与成员 · 遮蔽规则 +5 ──────────────────────────────────────

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
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q19):
--   incident        → /safety/incidents/[id]         requireFunction(FN.safetyIncidents) = module.safety.view。成员:之后的事实(incident_updates)
--                     与批次链接(incident_batches)住在这里;交接班的引用住在交接班下、也出现在这里;来源 incident 的不合格报告也出现在这里。
--                     受伤的细节由 change_log_mask_rules 遮(code_or_self:data.view_health:injured_employee_id)。
--   safety_settings → /safety/incidents 上的 V19 那一块   module.safety.view;单行设置作根(quality_settings 的先例)
--   dictionary_incident_kinds → /settings/dictionaries 的事故种类那一段   module.safety.view
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
        ('coa',                    ARRAY['module.output.view'],    'certificates_of_analysis', 'id', 'table', NULL),
        -- MES-7b-1(2026-10-16,MES-7b Step 0 Q19):一件事故(安全查看码 —— 页面的门;行再过一次它自己那张表的读规则)·
        --   安全的设定(V19,单行设置作根)· 事故种类字典(清单块,/settings/dictionaries)
        ('incident',               ARRAY['module.safety.view'],    'incidents',             'id', 'table', NULL),
        ('safety_settings',        ARRAY['module.safety.view'],    'safety_settings',       'id', 'table', NULL),
        ('dictionary_incident_kinds', ARRAY['module.safety.view'], 'incident_kinds',        'code', 'collection', NULL)
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
        ('device',             3, 'discharge_module_results',      'devices',         'device_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-2(2026-10-08,MES-5a Step 0 Q31):电表读数住在那台电表下;一张电费单分给一炉的那一份住在那张单下,也出现在那一炉上。──
        ('device',             4, 'meter_readings',                'devices',                 'device_id',     '{}'::jsonb, 'down', true, true),
        ('electricity_allocation', 1, 'electricity_allocation_lines', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    17, 'electricity_allocation_lines',  'processing_runs',         'run_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5b-2(2026-10-09,MES-5b Step 0 Q32 · Q34;MES5B1-V37-NOT-ON-OPERATION-TRAIL,Tim):一张电费单的撤回住在那张单下,
        --    也出现在它覆盖过的每一炉上(经那一炉的那一行往上一跳到那张分摊 —— 垫脚石,自己的改动不进来 —— 再往下到撤回)。
        --    一道工序每一种产出形态的预期得率(V37)住在那道工序下(按 operation_type_code 挂在根行的 code 下,与它的字段同形)。──
        ('electricity_allocation', 2, 'electricity_allocation_reversals', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    18, 'electricity_allocations',          'electricity_allocation_lines', 'allocation_id', '{}'::jsonb, 'up',   false, false),
        ('processing_run',    19, 'electricity_allocation_reversals', 'electricity_allocations',      'allocation_id', '{}'::jsonb, 'down', true, false),
        ('operation_type',     5, 'operation_type_output_forms',      'operation_types',              'operation_type_code', '{}'::jsonb, 'down', true, true),
        -- ── MES-5b-3(2026-10-09,MES-5b Step 0 Q32 · Q35):一份配料计划的目标品位与候选批次都住在那份计划下。──
        ('blending_plan',      1, 'blending_plan_targets',            'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        ('blending_plan',      2, 'blending_plan_lines',              'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        -- ── MES-6a-1(2026-10-09,MES-6a Step 0 Q39):一份样品的保管记录住在那份样品下;样品、它的保管记录与化验争议也出现在它们那一批上
        --    (家在样品 / 争议自己那里)。──
        ('sample',             1, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     44, 'samples',                          'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     45, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     46, 'assay_disputes',                   'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      42, 'samples',                          'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      43, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('output_batch',      44, 'assay_disputes',                   'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-6a-2(2026-10-10,MES-6a Step 0 Q39):一份化验的指标(残粉 · 箔纯度 · 粒径)与它的金属行同一个形状 ——
        --    住在那份化验挂着的那一批下(化验没有自己的主语;它的金属行也是这样挂的)。──
        ('inbound_batch',     47, 'assay_result_indicators',          'assay_results',                'assay_result_id',     '{}'::jsonb, 'down', true, true),
        ('output_batch',      45, 'assay_result_indicators',          'assay_results',                'assay_result_id',     '{}'::jsonb, 'down', true, true),
        -- ── MES-6b-1(2026-10-15,MES-6b Step 0 Q39):不合格报告也出现在它那一批上(家在报告自己那里);质量验收限的判定住在产出批下
        --    (判定挂在批次上,没有自己的主语);合同的第八张条款表住在合同下。──
        ('inbound_batch',     48, 'nonconformance_reports',           'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      46, 'nonconformance_reports',           'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      47, 'quality_limit_judgements',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, true),
        ('contract',          11, 'contract_quality_limits',          'contracts',                    'contract_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-6b-2(2026-10-15,MES-6b Step 0 Q38 · Q39):一张分析证书 —— 它的字节档案(家在证书)、作废它的 CFO 申请与那张申请的审批。
        --    证书也出现在两个批次主语下(家在证书自己那里):产出批 —— 它自己的证书、字节、作废申请与审批;进料批 —— 吃过这一批的加工单
        --    做出来的产出批上的证书(垫脚石:加工单 → 它的产出腿 → 那一批产出,只走一层;证书说的"来料化学确定度"正是这一批的事)。──
        ('coa',                1, 'coa_issues',                       'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, true),
        ('coa',                2, 'warehouse_requests',               'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('coa',                3, 'approval_log',                     'warehouse_requests',           'subject_id',          '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch',      48, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      49, 'coa_issues',                       'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('output_batch',      50, 'warehouse_requests',               'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('output_batch',      51, 'approval_log',                     'warehouse_requests',           'subject_id',          '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch',     49, 'processing_outputs',               'processing_runs',              'run_id',              '{}'::jsonb, 'down', false, false),
        ('inbound_batch',     50, 'output_batches',                   'processing_outputs',           'output_batch_id',     '{}'::jsonb, 'up',   false, false),
        ('inbound_batch',     51, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-7a-2(2026-10-16,MES-7a Step 0 Q20):备件出给保养与退回 —— 没有自己的主语(它没有自己的页)。家在设备(经那一条保养记录);
        --    也出现在进料批下(出的是这一批),连同那张分录(借 6800 / 贷 1200,source_type = maintenance_part,财务读)。──
        ('equipment',          5, 'maintenance_part_issues',          'equipment_maintenance',        'maintenance_id',      '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     52, 'maintenance_part_issues',          'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     53, 'journal_entries',                  'maintenance_part_issues',      'source_id',           '{"source_type": "maintenance_part"}'::jsonb, 'down', true, false),
        -- ── MES-7b-1(2026-10-16,MES-7b Step 0 Q12 · Q19):一件事故 —— 之后的事实与批次链接住在这里;交接班的引用住在交接班下(家),
        --    也出现在事故上;来源 incident 的不合格报告也出现在事故上(家在报告自己那里)。批次链接也出现在那一批上(Q19:事故在批次上看得见)。──
        ('incident',           1, 'incident_updates',                 'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, true),
        ('incident',           2, 'incident_batches',                 'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, true),
        ('incident',           3, 'shift_handover_incident_refs',     'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, false),
        ('incident',           4, 'nonconformance_reports',           'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, false),
        ('shift_handover',     3, 'shift_handover_incident_refs',     'shift_handovers',              'handover_id',         '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     54, 'incident_batches',                 'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      52, 'incident_batches',                 'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
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
-- ★ MES-7b-1(2026-10-16,MES-7b Step 0 Q6)加了 5 行(114 → 119):事故的受伤细节(受伤的人 · 名字 · 伤情 · 处理 · 误工天数)——
--   code_or_self:data.view_health:injured_employee_id,每一行抄自 incidents_masked 里那句 CASE。
-- ★ MES-5a-2(2026-10-08)加了 6 行(105 → 111):电费分摊的五列金额与分给一炉的金额 —— 加工成本那条规矩(data.view_prices,Q30),
--   每一行抄自 electricity_allocations_masked / electricity_allocation_lines_masked 里那句 CASE。
--   MES-5b-2:+3 行(electricity_allocation_reversals 的三列金额),抄自 electricity_allocation_reversals_masked 里那句 CASE。111 → 114。
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
        -- MES-7b-1(Q6):事故的受伤细节 —— 抄自 incidents_masked 里那句 CASE(data.view_health,或受伤的那名员工本人)
        ('incidents', 'injured_employee_id', 'code_or_self:data.view_health:injured_employee_id'),
        ('incidents', 'injured_person_name', 'code_or_self:data.view_health:injured_employee_id'),
        ('incidents', 'injury_nature', 'code_or_self:data.view_health:injured_employee_id'),
        ('incidents', 'injury_treatment', 'code_or_self:data.view_health:injured_employee_id'),
        ('incidents', 'days_lost', 'code_or_self:data.view_health:injured_employee_id'),
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
        ('electricity_allocations', 'bill_amount', 'code:data.view_prices'),
        ('electricity_allocations', 'price_per_kwh', 'code:data.view_prices'),
        ('electricity_allocations', 'allocated_amount', 'code:data.view_prices'),
        ('electricity_allocations', 'overhead_amount', 'code:data.view_prices'),
        ('electricity_allocations', 'relieved_estimate_amount', 'code:data.view_prices'),
        ('electricity_allocation_lines', 'amount', 'code:data.view_prices'),
        ('electricity_allocation_reversals', 'bill_amount', 'code:data.view_prices'),
        ('electricity_allocation_reversals', 'actual_line_amount', 'code:data.view_prices'),
        ('electricity_allocation_reversals', 'restored_estimate_amount', 'code:data.view_prices'),
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

-- ── 10 · 视图(镜像原样):事故现在的样子(底视图)· 遮蔽伴生 · 事故一行 · 批次链接 · 人选框;ncr_rows 末尾 +2 列 · 提醒 +2 支 · 待补的值 +V19 ──

-- db/views/incident_current_all.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q10 · Q11,Tim):【一件事故现在是什么样】—— 那一行(写下就不改)加上它的更正与之后的事实,
--   以及 NEA 书面报告的期限。【一份实现,四个读者】:事故页与清单(incident_rows)、两条提醒(operations_now 的 incident_nea_notify_due ·
--   incident_report_due)、批次的建议(suggest_incident_batches 用更正过的时刻)、更新函数(record_incident_update 判"与现在的值相同")。
--   ★ 底视图:不授给 authenticated(只由属主视图与 DEFINER 函数读)—— 它不带受伤的细节,但也不带读者的谓词。
--
--   【更正】每个字段取【最后一次】更正(id 最大 —— identity 记录先后;同一笔事务里的两行 recorded_at 一样,排不出先后,AGING-1)。
--     负责的人被更正成一个名字之后,原来指的那名员工不再算数(responsible_employee_id 读成空)。
--   【期限】(Q10 · Q11)只对现在要通报的事故算:report_deadline = business_days_after(事故的新加坡日期, V19)。
--     deadline_state:not_reportable(不用通报)· submitted(书面报告交了)· not_set(V19 是空的)· cannot_compute(数到的那几年里
--     有一年公共假期表是空的 —— 不猜日子)· computed。deadline_confirmed = V19 有没有被对着执照确认过(引导值没有,于是期限标"未确认")。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.

CREATE VIEW public.incident_current_all WITH (security_invoker = off) AS
 SELECT x.id,
    x.code,
    x.kind_code,
    x.occurred_at,
    (x.occurred_at AT TIME ZONE 'Asia/Singapore'::text)::date AS occurred_on,
    x.location_id,
    x.equipment_id,
    x.duration_min,
    x.what_happened,
    x.immediate_action,
    x.responsible_employee_id,
    x.responsible_name,
    x.nea_reportable,
    x.source,
    x.downtime_id,
    x.run_event_id,
    x.recorded_at,
    x.recorded_by,
    x.corrections,
    x.notified_at,
    x.notified_reference,
    x.report_submitted_at,
    x.report_reference,
    x.closed_at,
    x.closed_summary,
        CASE
            WHEN x.nea_reportable THEN business_days_after((x.occurred_at AT TIME ZONE 'Asia/Singapore'::text)::date, s.nea_report_working_days)
            ELSE NULL::date
        END AS report_deadline,
        CASE
            WHEN NOT x.nea_reportable THEN 'not_reportable'::text
            WHEN x.report_submitted_at IS NOT NULL THEN 'submitted'::text
            WHEN s.nea_report_working_days IS NULL THEN 'not_set'::text
            WHEN business_days_after((x.occurred_at AT TIME ZONE 'Asia/Singapore'::text)::date, s.nea_report_working_days) IS NULL THEN 'cannot_compute'::text
            ELSE 'computed'::text
        END AS deadline_state,
    s.nea_report_working_days AS deadline_working_days,
    s.nea_report_days_confirmed_at IS NOT NULL AS deadline_confirmed
   FROM ( SELECT i.id,
            i.code,
            COALESCE(c_kind.v, i.kind_code) AS kind_code,
            COALESCE(c_time.v::timestamptz, i.occurred_at) AS occurred_at,
            i.location_id,
            i.equipment_id,
            COALESCE(c_dur.v::numeric, i.duration_min) AS duration_min,
            COALESCE(c_what.v, i.what_happened) AS what_happened,
            COALESCE(c_act.v, i.immediate_action) AS immediate_action,
                CASE
                    WHEN c_resp.v IS NOT NULL THEN NULL::uuid
                    ELSE i.responsible_employee_id
                END AS responsible_employee_id,
            COALESCE(c_resp.v, i.responsible_name) AS responsible_name,
            COALESCE(c_nea.v::boolean, i.nea_reportable) AS nea_reportable,
            i.source,
            i.downtime_id,
            i.run_event_id,
            i.recorded_at,
            i.recorded_by,
            ( SELECT count(*)::integer AS count
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text) AS corrections,
            n.occurred_at AS notified_at,
            n.reference AS notified_reference,
            r.occurred_at AS report_submitted_at,
            r.reference AS report_reference,
            cl.recorded_at AS closed_at,
            cl.summary AS closed_summary
           FROM incidents i
             LEFT JOIN incident_updates n ON n.incident_id = i.id AND n.kind = 'nea_notified'::text
             LEFT JOIN incident_updates r ON r.incident_id = i.id AND r.kind = 'report_submitted'::text
             LEFT JOIN incident_updates cl ON cl.incident_id = i.id AND cl.kind = 'closed'::text
             LEFT JOIN LATERAL ( SELECT u.new_value AS v
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text AND u.field = 'kind_code'::text
                  ORDER BY u.id DESC
                 LIMIT 1) c_kind ON true
             LEFT JOIN LATERAL ( SELECT u.new_value AS v
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text AND u.field = 'occurred_at'::text
                  ORDER BY u.id DESC
                 LIMIT 1) c_time ON true
             LEFT JOIN LATERAL ( SELECT u.new_value AS v
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text AND u.field = 'duration_min'::text
                  ORDER BY u.id DESC
                 LIMIT 1) c_dur ON true
             LEFT JOIN LATERAL ( SELECT u.new_value AS v
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text AND u.field = 'what_happened'::text
                  ORDER BY u.id DESC
                 LIMIT 1) c_what ON true
             LEFT JOIN LATERAL ( SELECT u.new_value AS v
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text AND u.field = 'immediate_action'::text
                  ORDER BY u.id DESC
                 LIMIT 1) c_act ON true
             LEFT JOIN LATERAL ( SELECT u.new_value AS v
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text AND u.field = 'responsible_name'::text
                  ORDER BY u.id DESC
                 LIMIT 1) c_resp ON true
             LEFT JOIN LATERAL ( SELECT u.new_value AS v
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text AND u.field = 'nea_reportable'::text
                  ORDER BY u.id DESC
                 LIMIT 1) c_nea ON true) x
     LEFT JOIN safety_settings s ON s.id;

COMMENT ON VIEW public.incident_current_all IS
    'MES-7b-1:一件事故现在是什么样(更正过的值、通报 / 书面报告 / 关闭的事实、书面报告的期限与它的状态)。底视图,不授给 authenticated:读者是 incident_rows、operations_now 的两条 NEA 提醒、suggest_incident_batches 与 record_incident_update。不带受伤的细节。';

REVOKE ALL ON public.incident_current_all FROM authenticated, anon;

-- db/views/incidents_masked.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q6 · MES-0 Q76 · Q91,Tim):事故的遮蔽伴生视图。受伤的人(一名员工或一个名字)、伤情、处理、误工天数
--   要 data.view_health,【对受伤的那名员工本人让路】(行谓词与列遮蔽两处都带 OR injured_employee_id = current_user_employee() ——
--   medical_claims_masked 的同一个形状;COALESCE 收住 current_user_employee() 为空时的 NULL,CLEANUP-A 的那个陷阱)。
-- 行谓词 = 基表的读策略(module.safety.view)或本人。每一列都在这里(colgrant)。
-- 判据与 change_log_mask_rules 的 code_or_self:data.view_health:injured_employee_id 逐字同一个。

CREATE VIEW public.incidents_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    kind_code,
    occurred_at,
    location_id,
    equipment_id,
    duration_min,
    what_happened,
    immediate_action,
    responsible_employee_id,
    responsible_name,
    nea_reportable,
    source,
    downtime_id,
    run_event_id,
        CASE
            WHEN has_permission('data.view_health'::text) OR COALESCE(injured_employee_id = current_user_employee(), false) THEN injured_employee_id
            ELSE NULL::uuid
        END AS injured_employee_id,
        CASE
            WHEN has_permission('data.view_health'::text) OR COALESCE(injured_employee_id = current_user_employee(), false) THEN injured_person_name
            ELSE NULL::text
        END AS injured_person_name,
        CASE
            WHEN has_permission('data.view_health'::text) OR COALESCE(injured_employee_id = current_user_employee(), false) THEN injury_nature
            ELSE NULL::text
        END AS injury_nature,
        CASE
            WHEN has_permission('data.view_health'::text) OR COALESCE(injured_employee_id = current_user_employee(), false) THEN injury_treatment
            ELSE NULL::text
        END AS injury_treatment,
        CASE
            WHEN has_permission('data.view_health'::text) OR COALESCE(injured_employee_id = current_user_employee(), false) THEN days_lost
            ELSE NULL::numeric
        END AS days_lost,
    recorded_at,
    recorded_by
   FROM incidents
  WHERE has_permission('module.safety.view'::text) OR COALESCE(injured_employee_id = current_user_employee(), false);

COMMENT ON VIEW public.incidents_masked IS
    'MES-7b-1(Q6):事故的遮蔽伴生视图。受伤的人、伤情、处理、误工天数要 data.view_health 或就是受伤的那名员工本人;行谓词 = 基表的读策略(module.safety.view)或本人。';

-- ★ 默认权限会把 INSERT / UPDATE / DELETE 也授给 authenticated(线上 pg_default_acl:postgres 建的表与视图 authenticated=arwdDxtm),
--   而一张简单的属主视图是【可以写穿的】—— 以属主身份写基表,绕开 RLS 与那几支 DEFINER 函数的码。所以先全收,再只授回 SELECT。
REVOKE ALL ON public.incidents_masked FROM authenticated, anon;
GRANT SELECT ON public.incidents_masked TO authenticated;

-- db/views/incident_rows.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q6 · Q10 · Q11 · Q17,Tim):事故清单与事故页读的那一行 —— 现在的值(incident_current_all)
--   加上人读的标签(种类的名字、库位、机器、负责的人、引用的停机与异常事件)与受伤的细节(经 incidents_masked,遮蔽照旧)。
--   【属主权限】行谓词就是 incidents_masked 的那一句(module.safety.view,或受伤的那名员工本人):它读 incidents_masked,
--   而那张视图里的 has_permission / current_user_employee 回答的是【调用者】(AGENTS.md:属主视图不放宽模块的门)。
--   借来的列只有【标签】(名字、编号、时刻)—— 显示标签跟着单据走(四条常设裁定之三),没有任何一列钱。
--   injury_visible:这位读者能不能读受伤的细节(data.view_health 或本人)。为假时页面说「受限」—— 不论这一件有没有受伤的记录,
--   于是"有没有人受伤"这件事本身也不会从一个空字段里漏出去。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.

CREATE VIEW public.incident_rows WITH (security_invoker = off) AS
 SELECT m.id,
    m.code,
    c.kind_code,
    k.name_en AS kind_name_en,
    k.name_zh AS kind_name_zh,
    c.occurred_at,
    c.occurred_on,
    m.location_id,
    l.code AS location_code,
    l.name AS location_name,
    m.equipment_id,
    fa.code AS equipment_code,
    fa.description AS equipment_name,
    c.duration_min,
    c.what_happened,
    c.immediate_action,
    c.responsible_employee_id,
    COALESCE((re.code || ' · '::text) || COALESCE(re.preferred_name, re.legal_name), c.responsible_name) AS responsible_label,
    c.nea_reportable,
    m.source,
    m.downtime_id,
    d.started_at AS downtime_started_at,
    m.run_event_id,
    ev.run_id AS run_event_run_id,
    pr.code AS run_event_run_code,
    ev.event_type_code AS run_event_type,
    ev.occurred_at AS run_event_occurred_at,
    m.recorded_at,
    m.recorded_by,
    c.corrections,
    c.notified_at,
    c.notified_reference,
    c.report_submitted_at,
    c.report_reference,
    c.closed_at,
    c.closed_summary,
    c.report_deadline,
    c.deadline_state,
    c.deadline_working_days,
    c.deadline_confirmed,
    has_permission('data.view_health'::text) OR COALESCE(m.injured_employee_id = current_user_employee(), false) AS injury_visible,
    m.injured_employee_id,
    (ie.code || ' · '::text) || COALESCE(ie.preferred_name, ie.legal_name) AS injured_employee_label,
    m.injured_person_name,
    m.injury_nature,
    m.injury_treatment,
    m.days_lost,
    ( SELECT count(*)::integer AS count
           FROM incident_batches b
          WHERE b.incident_id = m.id AND b.unlinked_at IS NULL) AS linked_batches
   FROM incidents_masked m
     JOIN incident_current_all c ON c.id = m.id
     JOIN incident_kinds k ON k.code = c.kind_code
     LEFT JOIN storage_locations l ON l.id = m.location_id
     LEFT JOIN fixed_assets fa ON fa.id = m.equipment_id
     LEFT JOIN employees re ON re.id = c.responsible_employee_id
     LEFT JOIN employees ie ON ie.id = m.injured_employee_id
     LEFT JOIN equipment_downtime d ON d.id = m.downtime_id
     LEFT JOIN processing_run_events ev ON ev.id = m.run_event_id
     LEFT JOIN processing_runs pr ON pr.id = ev.run_id;

COMMENT ON VIEW public.incident_rows IS
    'MES-7b-1:事故清单与事故页的一行 —— 现在的值(更正过的)、NEA 通报 / 书面报告 / 关闭、期限与它的状态(未确认的 V19 照算、标出来)、人读的标签,以及受伤的细节(经 incidents_masked 遮蔽;injury_visible 为假时页面说「受限」)。属主权限,行谓词 = incidents_masked 的那一句(module.safety.view 或本人)。';

-- ★ 默认权限会把 INSERT / UPDATE / DELETE 也授给 authenticated(线上 pg_default_acl:postgres 建的表与视图 authenticated=arwdDxtm),
--   而一张简单的属主视图是【可以写穿的】—— 以属主身份写基表,绕开 RLS 与那几支 DEFINER 函数的码。所以先全收,再只授回 SELECT。
REVOKE ALL ON public.incident_rows FROM authenticated, anon;
GRANT SELECT ON public.incident_rows TO authenticated;

-- db/views/incident_batch_rows.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q7,Tim):一件事故的批次链接,带批号与事故的标签 —— 事故页的「碰过的批次」与批次页的「关联的事故」都读它。
--   【属主权限】行谓词 = incident_batches 的读策略(module.safety.view,或那一批自己那一页的查看码)。
--   借来的列只有标签:批号与物料名、事故编号、种类的名字、发生时刻 —— 显示标签跟着单据走(常设裁定之三);
--   一个只持批次查看码的人看得见"这一批链在 INC-… 上、是哪一种、什么时候",看不见那件事故的任何别的东西(事故页的门是 module.safety.view)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.

CREATE VIEW public.incident_batch_rows WITH (security_invoker = off) AS
 SELECT b.id,
    b.incident_id,
    i.code AS incident_code,
    c.kind_code,
    k.name_en AS kind_name_en,
    k.name_zh AS kind_name_zh,
    c.occurred_at AS incident_occurred_at,
        CASE
            WHEN b.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    COALESCE(b.inbound_batch_id, b.output_batch_id) AS batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
    COALESCE(im.name, om.name) AS material_name,
    b.basis,
    b.linked_at,
    b.linked_by,
    b.unlinked_at,
    b.unlinked_by,
    b.unlink_reason,
    b.unlinked_at IS NULL AS active
   FROM incident_batches b
     JOIN incidents i ON i.id = b.incident_id
     JOIN incident_current_all c ON c.id = b.incident_id
     JOIN incident_kinds k ON k.code = c.kind_code
     LEFT JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
     LEFT JOIN materials im ON im.id = ib.material_id
     LEFT JOIN output_batches ob ON ob.id = b.output_batch_id
     LEFT JOIN materials om ON om.id = ob.material_id
  WHERE has_permission('module.safety.view'::text)
     OR (b.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
     OR (b.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text));

COMMENT ON VIEW public.incident_batch_rows IS
    'MES-7b-1:事故 × 批次的链接(有效的与解除的),带批号、物料名、事故编号、种类与时刻。属主权限,行谓词 = incident_batches 的读策略。事故页与批次页读它。';

-- ★ 默认权限会把 INSERT / UPDATE / DELETE 也授给 authenticated(线上 pg_default_acl:postgres 建的表与视图 authenticated=arwdDxtm),
--   而一张简单的属主视图是【可以写穿的】—— 以属主身份写基表,绕开 RLS 与那几支 DEFINER 函数的码。所以先全收,再只授回 SELECT。
REVOKE ALL ON public.incident_batch_rows FROM authenticated, anon;
GRANT SELECT ON public.incident_batch_rows TO authenticated;

-- db/views/incident_people.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q6):记事故那张表单的两个人选框(负责的人、受伤的人)读的名单 —— handover_people 的同一个形状。
--   【为什么它存在】employees 的行策略要 module.hr.view,而记事故的人是 cto 与仓库(module.safety.edit)。不给这张视图,两个下拉框会静默地空着。
--   只有 id / code / preferred_name 三列 —— 工号与称呼名;legal_name、身份、联系方式、薪酬一列都不透。
--   ★ 挑一个人做"受伤的人"不是读健康数据:伤情是记录人自己写下的,读回来才要 data.view_health。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.

CREATE VIEW public.incident_people WITH (security_invoker = off) AS
 SELECT e.id,
    e.code,
    e.preferred_name
   FROM employees e
  WHERE e.deleted_at IS NULL AND has_permission('module.safety.view'::text);

COMMENT ON VIEW public.incident_people IS
    'MES-7b-1:记事故表单的人选框读的名单(工号与称呼名),门 module.safety.view。employees 的行策略要 HR 查看码,记事故的人没有它。';

-- ★ 默认权限会把 INSERT / UPDATE / DELETE 也授给 authenticated(线上 pg_default_acl:postgres 建的表与视图 authenticated=arwdDxtm),
--   而一张简单的属主视图是【可以写穿的】—— 以属主身份写基表,绕开 RLS 与那几支 DEFINER 函数的码。所以先全收,再只授回 SELECT。
REVOKE ALL ON public.incident_people FROM authenticated, anon;
GRANT SELECT ON public.incident_people TO authenticated;

-- db/views/ncr_rows.sql
-- MES-6b-1(2026-10-15,MES-6b Step 0 Q7 · Q9 · Q22 · Q39,Tim):【一张不合格报告与它此刻的样子】—— 报告清单、报告页、批次页上的暂扣那一行读它。
--   报告自己的列,加上几样显示用的标签(批号、化验单号、销售单号、合同编号、钱的那一张单据的标签 —— 标签跟着单据走,常设决定 3),
--   一行判定的内容(系统开的那一张:参数、值、抄下的限、结果),以及 holding:这一张此刻扣不扣着它那一批(判据 ncr_holds,纯函数 ——
--   这里以属主的眼睛读批次的余量再问它,于是一个只持质量查看码的读者也读得到"拒收而货还在"那一种)。
--   【门】质量查看码,或那一批自己那一页的查看码(与 nonconformance_reports 的读策略同一句)。属主视图:读批次、化验、单据、判定不再过
--   各自的 RLS,所以条件写在末尾的 WHERE 里一次。没有金额,不遮(报告不带金额;钱的那一张单据只给出它的标签)。
-- ★ MES-7b-1(2026-10-16,MES-7b Step 0 Q8):末尾多两列 incident_id / incident_code —— 来源 incident 的那一张指着的事故(编号是标签,跟着单据走)。
--   加在末尾,CREATE OR REPLACE VIEW 不动既有的列。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.

CREATE OR REPLACE VIEW public.ncr_rows WITH (security_invoker = off) AS
 SELECT n.id,
    n.code,
    n.status,
    n.source,
        CASE
            WHEN n.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    n.inbound_batch_id,
    n.output_batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
    n.description,
    n.assay_result_id,
    a.code AS assay_code,
    n.assay_dispute_id,
    n.sales_order_id,
    so.code AS sales_order_code,
    n.judgement_id,
    j.parameter AS judgement_parameter,
    j.value AS judgement_value,
    j.limit_min_at AS judgement_limit_min,
    j.limit_max_at AS judgement_limit_max,
    j.result AS judgement_result,
    c.code AS judgement_contract_code,
    n.opened_at,
    n.opened_by,
    n.opened_by IS NULL AS opened_by_system,
    n.disposition,
    n.decision_note,
    n.decided_at,
    n.decided_by,
    n.penalty_invoice_request_id,
    ir.label AS penalty_invoice_request_label,
    n.penalty_price_request_id,
    pr.label AS penalty_price_request_label,
    ncr_holds(n.status, n.disposition, COALESCE(ib.deleted_at, ob.deleted_at), COALESCE(ib.remaining_qty, ob.remaining_qty)) AS holding,
    n.incident_id,
    inc.code AS incident_code
   FROM nonconformance_reports n
     LEFT JOIN inbound_batches ib ON ib.id = n.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = n.output_batch_id
     LEFT JOIN assay_results a ON a.id = n.assay_result_id
     LEFT JOIN sales_orders so ON so.id = n.sales_order_id
     LEFT JOIN quality_limit_judgements j ON j.id = n.judgement_id
     LEFT JOIN contracts c ON c.id = j.contract_id
     LEFT JOIN invoice_requests ir ON ir.id = n.penalty_invoice_request_id
     LEFT JOIN receipt_price_requests pr ON pr.id = n.penalty_price_request_id
     LEFT JOIN incidents inc ON inc.id = n.incident_id
  WHERE has_permission('module.quality.view'::text)
     OR (n.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
     OR (n.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text));

COMMENT ON VIEW public.ncr_rows IS
    'MES-6b-1:一张不合格报告与它此刻的样子 —— 报告的列、显示用的标签(批号、化验、销售单、合同、钱的那一张单据,标签跟着单据走)、系统开的那一张的判定内容,以及 holding(这一张此刻扣不扣着它那一批 —— ncr_holds,属主读余量)。门与 nonconformance_reports 的读策略同一句(质量查看码,或那一批自己的查看码)。没有金额。';

GRANT SELECT ON public.ncr_rows TO authenticated;
REVOKE ALL ON public.ncr_rows FROM anon;

-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行
-- ★ MES-7b-1(2026-10-16,MES-7b Step 0 Q10 · Q11,Tim):加两支,门都是 module.safety.view,都读 incident_current_all(事故现在的值:
--   更正过的"要不要通报"说了算;一件更正成不用通报的事故两支都消失)。关闭【不】清掉它们 —— 法定的义务不因"关闭"而结束。
--   incident_nea_notify_due —— 一件要通报 NEA 的事故,还没有记下通报("立即":没有天数,只是挂着直到记下)。item_id = 那件事故;
--     item_code = 事故编号;subject = 种类的英文名;item_date = 事故日(新加坡日期)。
--   incident_report_due —— 一件要通报 NEA 的事故,还没有记下交了书面报告。item_date = 期限(事故日之后第 V19 个工作日);期限算不出来或
--     没有设定时退回事故日(item_date 在每一支上都不为空 —— 首页拿它算等了几天)。doc_kind 借来装期限的状态(computed · not_set ·
--     cannot_compute):只有 computed 时 item_date 才是期限 —— 门牌据此说"算不出来",不把事故日说成期限。
-- ★ MES-6b-2(2026-10-15,MES-6b Step 0 Q32 · Q38,Tim):加一支 coa_facts_changed —— 一张已签发的分析证书,而它那一批在签发之后多了一份
--   (没删的)化验、或开了一张不合格报告。证书【永远不会被自动作废】(Q32):这一格只把它摆到持 action.issue_coa 的人面前(签发与提作废申请
--   的是同一批人),由人决定要不要经 CFO 作废、重开一张。item_id = 那张证书;item_code = 证书号;subject = 批号 · 最早那一件新事的编号
--   (化验号或报告编号);item_date = 那件事的日子。证书作废之后它消失(重开的那一张从它自己的签发时刻重新算)。
-- ★ MES-6b-1(2026-10-15,MES-6b Step 0 Q6 · Q23 · Q38,Tim):加三支,门都是 module.quality.view。
--   ncr_open —— 一张开着的不合格报告(它扣着那一批)。item_id = 那张报告;item_code = 报告编号;subject = 批号;item_date = 开单日。
--   quality_hold_reserved —— 一批在质量暂扣里的产出批还挂着没释放的预留(Q23:预留照留,发不出去)。一张单 × 一批 × 扣着它的那张报告一行;
--     item_id = 那张销售单(门牌指它,释放预留在那一页);subject = 批号 · 报告编号;item_date = 最早那一笔预留的日子。
--     判据 batch_quality_hold(以读者身份调用的 INVOKER 函数)—— 所以这一支另外要 module.output.view(arm_permission_any):不合格报告与产出批的
--     读策略都认它,读者不会因为读不到而少看一行;质量那一侧之外,销售那一侧也看得见(arm_permission_widen:module.sales.view)。
--   quality_prompt_ncr —— 【提示人去开一张】(Q6:只有 V17 越限自动开):一批进料的品位违反(contract_grade_breaches —— 那张视图自己要
--     module.suppliers.view,今天每一个持质量查看码的角色都持它)、一批产出批的交叉污染抽检过了 V11 的警戒线(当前的、没被更正的那一条)、
--     一批的一个模组最新的放电结论是失败(没拆走)。一批一行;那一批上有一张开单时刻不早于那件事的不合格报告(任何状态)之后消失。
--     item_id = 那一批;doc_kind = 'inbound' / 'output'(门牌按它指 /quality/ncr/new 的那一批);subject = 那件事的出处(化验单号 · 流 · 模组号)。
-- ★ MES-6a-1(2026-10-09,MES-6a Step 0 Q15 · Q17,Tim):加三支,门都是 module.quality.view。
--   sample_retention_due —— 一份样品的留样日已经过了、还没处置(Q15)。item_id = 那份样品;subject = 批号;item_date = 留样日。
--     留样日 Not yet set 的样品不进来(没有日子可过)。
--   assay_dispute_open —— 一件开着的化验争议(它挡着进料的应用 / 定价过账与卖方结算)。item_id = 那件争议;item_code = 批号;
--     subject = 两份结果的单号。
--   assay_results_disagree —— 卖方:两方结果差得超过了合同的容差,而没有人立过争议(MES-0 Q62;assay_disagreements_all)。
--     item_id = 那一批产出批;subject = 销售单号。买方没有这一支(买方合同不带容差 —— Q17)。
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
                  GROUP BY so.id, so.code, c.legal_name) q
        UNION ALL
         SELECT 'sample_retention_due'::text AS item_type,
            'module.quality.view'::text AS permission,
            sr.id AS item_id,
            NULL::text AS doc_kind,
            sr.code AS item_code,
            sr.batch_code AS subject,
            sr.retain_until AS item_date
           FROM ( SELECT s.id,
                    s.code,
                    COALESCE(ib.code, ob.code) AS batch_code,
                    s.retain_until
                   FROM samples s
                     LEFT JOIN inbound_batches ib ON ib.id = s.inbound_batch_id
                     LEFT JOIN output_batches ob ON ob.id = s.output_batch_id
                  WHERE s.retain_until IS NOT NULL AND s.retain_until < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
                           FROM sample_events e
                          WHERE e.sample_id = s.id AND e.event_kind = 'disposed'::text))) sr
        UNION ALL
         SELECT 'assay_dispute_open'::text AS item_type,
            'module.quality.view'::text AS permission,
            d.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(ib.code, ob.code) AS item_code,
            (ao.code || ' / '::text) || ac.code AS subject,
            d.created_at::date AS item_date
           FROM assay_disputes d
             LEFT JOIN inbound_batches ib ON ib.id = d.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = d.output_batch_id
             JOIN assay_results ao ON ao.id = d.our_assay_id
             JOIN assay_results ac ON ac.id = d.counterparty_assay_id
          WHERE d.status = 'open'::text
        UNION ALL
         SELECT 'assay_results_disagree'::text AS item_type,
            'module.quality.view'::text AS permission,
            ad.output_batch_id AS item_id,
            NULL::text AS doc_kind,
            ad.batch_code AS item_code,
            ad.sales_order_code AS subject,
            ad.latest_assay_date AS item_date
           FROM assay_disagreements_all ad
        UNION ALL
         SELECT 'ncr_open'::text AS item_type,
            'module.quality.view'::text AS permission,
            n.id AS item_id,
            NULL::text AS doc_kind,
            n.code AS item_code,
            COALESCE(ib.code, ob.code) AS subject,
            n.opened_at::date AS item_date
           FROM nonconformance_reports n
             LEFT JOIN inbound_batches ib ON ib.id = n.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = n.output_batch_id
          WHERE n.status = 'open'::text
        UNION ALL
         SELECT 'quality_hold_reserved'::text AS item_type,
            'module.quality.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            (h.batch_code || ' · '::text) || h.ncr_code AS subject,
            min(r.created_at)::date AS item_date
           FROM sales_order_reservations r
             JOIN sales_order_lines l ON l.id = r.sales_order_line_id
             JOIN sales_orders so ON so.id = l.sales_order_id
             CROSS JOIN LATERAL batch_quality_hold(NULL::uuid, r.output_batch_id) h(ncr_id, ncr_code, batch_code)
          WHERE r.released_at IS NULL AND r.consumed_at IS NULL AND so.deleted_at IS NULL
          GROUP BY so.id, so.code, h.batch_code, h.ncr_code
        UNION ALL
         SELECT 'coa_facts_changed'::text AS item_type,
            'action.issue_coa'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            (ob.code || ' · '::text) || f.what AS subject,
            f.found_on AS item_date
           FROM certificates_of_analysis c
             JOIN output_batches ob ON ob.id = c.output_batch_id
             CROSS JOIN LATERAL ( SELECT x.what,
                    x.found_on
                   FROM ( SELECT a.code AS what,
                            a.created_at AS found_at,
                            a.created_at::date AS found_on
                           FROM assay_results a
                          WHERE a.output_batch_id = c.output_batch_id AND a.deleted_at IS NULL AND a.created_at > c.issued_at
                        UNION ALL
                         SELECT n.code,
                            n.opened_at,
                            n.opened_at::date AS opened_at_date
                           FROM nonconformance_reports n
                          WHERE n.output_batch_id = c.output_batch_id AND n.opened_at > c.issued_at) x
                  ORDER BY x.found_at, x.what
                 LIMIT 1) f
          WHERE c.status = 'issued'::text
        UNION ALL
         SELECT 'quality_prompt_ncr'::text AS item_type,
            'module.quality.view'::text AS permission,
            q.batch_id AS item_id,
            q.batch_kind AS doc_kind,
            q.batch_code AS item_code,
            q.evidence AS subject,
            q.found_on AS item_date
           FROM ( SELECT 'inbound'::text AS batch_kind,
                    gb.inbound_batch_id AS batch_id,
                    gb.inbound_batch_code AS batch_code,
                    min(ar.code) AS evidence,
                    min(gb.assay_date) AS found_on,
                    min(ar.created_at) AS found_at
                   FROM contract_grade_breaches gb
                     JOIN assay_results ar ON ar.id = gb.assay_result_id
                  GROUP BY gb.inbound_batch_id, gb.inbound_batch_code
                UNION ALL
                 SELECT 'output'::text,
                    cc.output_batch_id,
                    ob2.code,
                    min(cc.stream_code),
                    min(cc.sampled_at)::date,
                    min(cc.recorded_at)
                   FROM contamination_checks cc
                     JOIN output_batches ob2 ON ob2.id = cc.output_batch_id AND ob2.deleted_at IS NULL
                  WHERE cc.above_warning IS TRUE AND NOT (EXISTS ( SELECT 1
                           FROM contamination_checks x
                          WHERE x.corrects_id = cc.id))
                  GROUP BY cc.output_batch_id, ob2.code
                UNION ALL
                 SELECT dm.batch_kind,
                    dm.batch_id,
                    COALESCE(ib3.code, ob3.code),
                    min(dm.module_ref),
                    min(dm.verdict_at)::date,
                    min(dm.verdict_at)
                   FROM discharge_module_current_all dm
                     LEFT JOIN inbound_batches ib3 ON ib3.id = dm.batch_id AND dm.batch_kind = 'inbound'::text
                     LEFT JOIN output_batches ob3 ON ob3.id = dm.batch_id AND dm.batch_kind = 'output'::text
                  WHERE dm.verdict = 'fail'::text AND NOT dm.split_out
                    AND COALESCE(ib3.deleted_at, ob3.deleted_at) IS NULL AND COALESCE(ib3.id, ob3.id) IS NOT NULL
                  GROUP BY dm.batch_kind, dm.batch_id, ib3.code, ob3.code) q
          WHERE NOT (EXISTS ( SELECT 1
                   FROM nonconformance_reports n2
                  WHERE (n2.inbound_batch_id = q.batch_id OR n2.output_batch_id = q.batch_id) AND n2.opened_at >= q.found_at))
        UNION ALL
         SELECT 'incident_nea_notify_due'::text AS item_type,
            'module.safety.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            k.name_en AS subject,
            c.occurred_on AS item_date
           FROM incident_current_all c
             JOIN incident_kinds k ON k.code = c.kind_code
          WHERE c.nea_reportable AND c.notified_at IS NULL
        UNION ALL
         SELECT 'incident_report_due'::text AS item_type,
            'module.safety.view'::text AS permission,
            c.id AS item_id,
            c.deadline_state AS doc_kind,
            c.code AS item_code,
            k.name_en AS subject,
            COALESCE(c.report_deadline, c.occurred_on) AS item_date
           FROM incident_current_all c
             JOIN incident_kinds k ON k.code = c.kind_code
          WHERE c.nea_reportable AND c.report_submitted_at IS NULL) a
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
-- 【MES-5a-2 加一支】(2026-10-08,MES-0 §5.1 V25;MES-5a Step 0 Q25 · Q32,Tim)
--   V25  共用池的电怎么摊(electricity_settings.shared_pool_rule)—— 有一台没停用、没挂机器的电表(共用池),而规则为空时一行
--        (去处:/finance/electricity;门 module.finance.view)。由 Tim 在电表接上之后的第一张电费单时给。没给:不计量的电与
--        共用池量到的电在每一次分摊里都留在间接费用 6200。今天线上一台电表都没有,所以是零行。
-- 【MES-6a-1 加两支】(2026-10-09,MES-0 §5.1 V14 · V16;MES-6a Step 0 Q14 · Q22 · Q42,Tim)
--   V16  没有合同天数的样品留多少天(quality_settings.internal_retention_days)—— 为空、而且有一份没处置、留样日 Not yet set 的样品时一行
--        (去处:/quality/samples 的设定;门 module.quality.view)。由 Tim / 质量在第一份要留的样品时给。没给:那样的样品没有留样日,不进提醒。
--        只有一份没处置的 not_set 样品时才列 —— V9 的先例:没人能动手的行不列。
--   V14  仲裁费怎么分(contract_settlement_terms.arbitration_fee_rule,只卖方合同有)—— 每一份【有过一件开着或已结案的争议】(经那件争议的
--        销售单的合同副本认合同)、而它的结算口径里规则为空的合同一行(去处:那份合同;门 module.customers.view —— 条款自己的读码)。
--        由对手方合同在签约时给。没给:争议照立,仲裁费照记,对手方那一份算不出来(NULL)。
--   (V15 没有支:F / Cl 的惩罚阈值是逐份合同的条款,声明了 per_element 却没填时结算按名拒 PENALTY_ELEMENTS_NOT_FILED;V17 归 MES-6b。)
-- 【MES-6b-1 加一支】(2026-10-15,MES-0 §5.1 V17;MES-6a Step 0 Q5;MES-6b Step 0 Q37,Tim)
--   V17  水分与粒径(以及任何一个化验指标)的验收限,逐份卖方合同 —— 每一份没删的卖方合同,【至少挂了一张销售单】、而它的结算口径里
--        quality_limit_basis 为空(或还没有结算口径)的一行(去处:那份合同;门 module.customers.view —— 条款自己的读码)。由 Tim / 那份承购合同给。
--        V9 的先例:还没有一张销售单挂上来的合同不列(没人能对它动手的行不列;从此新生效的卖方合同都必须先声明,见 contract_activation_missing)。
--        没给:那张单上的预留与化验不判质量验收限(judge_quality_limits 只认 per_parameter),不开不合格报告。
-- 【MES-7a-2 加一支】(2026-10-16,MES-0 §5.1 V21;MES-7a Step 0 Q17,Tim)
--   V21  备件的最低库存(materials.safety_stock_qty,按备件物料 —— 已经在驱动 safety_stock_below 那条提醒)。【只在这种备件已经收过至少一批
--        时才列】—— V9 的先例:一种还没收过货的备件,没人能对它动手。给它的人:cto,或设备供应商在验收时给的推荐备件清单。
--        没给:那种备件低于多少都不提醒(safety_stock_below 只认填了的物料)。
-- 【MES-7b-1 加一支】(2026-10-16,MES-0 §5.1 V19;MES-7b Step 0 Q10 · Q11 · Q20,Tim)
--   V19  NEA 书面报告的期限(工作日数,safety_settings.nea_report_working_days)—— 【空着,或者还没对着执照确认】时一行(去处:/safety/incidents
--        的设定面板;门 module.safety.view)。Q11:引导存 2、未确认(出处是仓库里那条义务的记录),所以这一行从第一天起就在,直到有人
--        对着 NEA 执照确认。没给:期限算不出来;给了没确认:期限照算,标"未确认"。
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
                  WHERE COALESCE(ib.material_id, ob.material_id) = m.id))
        UNION ALL
         SELECT 'V25'::text AS value_code,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            'shared_pool_rule'::text AS item_code,
            'Shared-pool electricity rule'::text AS item_label,
            '/finance/electricity'::text AS href
           FROM electricity_settings es
          WHERE es.id AND es.shared_pool_rule IS NULL AND (EXISTS ( SELECT 1
                   FROM devices d
                  WHERE d.kind = 'meter'::text AND d.equipment_id IS NULL AND d.retired_at IS NULL))
        UNION ALL
         SELECT 'V37'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            (tf.operation_type_code || '/'::text) || tf.form_code AS item_code,
            (ot.name_en || ' · '::text) || COALESCE(mf.name_en, tf.form_code) AS item_label,
            '/operation/operation-types/'::text || tf.operation_type_code AS href
           FROM operation_type_output_forms tf
             JOIN operation_types ot ON ot.code = tf.operation_type_code
             LEFT JOIN material_forms mf ON mf.code = tf.form_code
          WHERE ot.is_active AND tf.expected_yield_pct IS NULL AND (EXISTS ( SELECT 1
                   FROM processing_run_flow_all f
                  WHERE f.operation_type_code = tf.operation_type_code AND f.flow = 'consumption'::text AND f.era_mes4a))
        UNION ALL
         SELECT 'V16'::text AS value_code,
            'module.quality.view'::text AS permission,
            NULL::uuid AS item_id,
            'internal_retention_days'::text AS item_code,
            'Internal sample retention (days)'::text AS item_label,
            '/quality/samples'::text AS href
           FROM quality_settings qs
          WHERE qs.id AND qs.internal_retention_days IS NULL AND (EXISTS ( SELECT 1
                   FROM samples s
                  WHERE s.retain_until_source = 'not_set'::text AND NOT (EXISTS ( SELECT 1
                           FROM sample_events e
                          WHERE e.sample_id = s.id AND e.event_kind = 'disposed'::text))))
        UNION ALL
         SELECT 'V14'::text AS value_code,
            'module.customers.view'::text AS permission,
            c.id AS item_id,
            c.code AS item_code,
            c.title AS item_label,
            '/contracts/'::text || c.id::text AS href
           FROM contracts c
          WHERE c.deleted_at IS NULL AND (EXISTS ( SELECT 1
                   FROM assay_disputes d
                     JOIN contract_document_terms t ON t.sales_order_id = d.sales_order_id
                  WHERE t.contract_id = c.id AND (d.status = ANY (ARRAY['open'::text, 'resolved'::text])))) AND NOT (EXISTS ( SELECT 1
                   FROM contract_settlement_terms cst
                  WHERE cst.contract_id = c.id AND cst.arbitration_fee_rule IS NOT NULL))
        UNION ALL
         SELECT 'V17'::text AS value_code,
            'module.customers.view'::text AS permission,
            c.id AS item_id,
            c.code AS item_code,
            c.title AS item_label,
            '/contracts/'::text || c.id::text AS href
           FROM contracts c
          WHERE c.deleted_at IS NULL AND c.customer_id IS NOT NULL AND (EXISTS ( SELECT 1
                   FROM contract_document_terms t
                  WHERE t.contract_id = c.id AND t.sales_order_id IS NOT NULL)) AND NOT (EXISTS ( SELECT 1
                   FROM contract_settlement_terms cst
                  WHERE cst.contract_id = c.id AND cst.quality_limit_basis IS NOT NULL))
        UNION ALL
         SELECT 'V21'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            ('/materials/'::text || m.id::text) || '/edit'::text AS href
           FROM materials m
          WHERE m.deleted_at IS NULL AND m.kind_code = 'spare_part'::text AND m.safety_stock_qty IS NULL AND (EXISTS ( SELECT 1
                   FROM inbound_batches b
                  WHERE b.material_id = m.id))
        UNION ALL
         SELECT 'V19'::text AS value_code,
            'module.safety.view'::text AS permission,
            NULL::uuid AS item_id,
            'nea_report_working_days'::text AS item_code,
            'NEA written-report deadline (working days)'::text AS item_label,
            '/safety/incidents'::text AS href
           FROM safety_settings ss
          WHERE ss.id AND (ss.nea_report_working_days IS NULL OR ss.nea_report_days_confirmed_at IS NULL)) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程);MES-3a 加 V2(执照 × 类别的库存上限)、V29(NEA 类别与物料的类别)、V3(每个安全状态的滞留提醒天数)、V4(每个安全状态要不要隔离)与 V34(隔离库位);MES-3b 加 V30(危险品编号的标记 · 包装说明 · 标签尺寸)、V31(电池料的 HS 编码)与 V35(电池料的危险品编号);MES-4a 加 V1(转化型工序的物料平衡容差)与 V36(声明了有范围的参数的上下限),并把 V6 的去处搬到班次字典(V6 同时答 V7);MES-4b 加 V10(勾了电解液挥发的工序的电解液份额)与 V11(交叉污染流的警戒线)。MES-5a-1 加 V9(物料的放电通过电压,只在那种物料有了放电结果之后才列);MES-5a-2 加 V25(共用池的电怎么摊,有共用池电表而规则为空时一行)。MES-5b-1 加 V37(每道工序 × 每种产出形态的预期质量得率;只在那道工序有了至少一张 MES-4a 之后的消耗炉次时才列 —— V9 的先例:没人能动手的行不列)。MES-6a-1 加 V16(没有合同天数的样品留多少天;只在有一份没处置、留样日 Not yet set 的样品时才列)与 V14(仲裁费怎么分;每一份有过一件开着或已结案的争议而规则为空的合同一行)。MES-6b-1 加 V17(卖方合同的质量验收限;每一份挂了销售单而口径没声明的卖方合同一行)。MES-7a-2 加 V21(备件的最低库存;每一种收过至少一批而最低库存为空的备件物料一行)。MES-7b-1 加 V19(NEA 书面报告的工作日数;空着或还没对着执照确认时一行)。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- ── 11 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.incident_kinds
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.incident_kinds
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.safety_settings
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.safety_settings
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.incidents
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.incidents
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.incident_updates
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.incident_updates
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.incident_batches
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.incident_batches
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.shift_handover_incident_refs
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('handover_id', 'incident_id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.shift_handover_incident_refs
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 12 · 授权(MES-0 Q90 · MES-7b Step 0 Q2):查看 → admin · auditor · cco · cfo · cto · finance · gm · operations · warehouse;编辑 → admin · cto · warehouse —— 本刀唯一的授权改动 ──
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'module.safety.view' FROM roles r WHERE r.code IN ('admin', 'auditor', 'cco', 'cfo', 'cto', 'finance', 'gm', 'operations', 'warehouse')
ON CONFLICT (role_id, permission_code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'module.safety.edit' FROM roles r WHERE r.code IN ('admin', 'cto', 'warehouse')
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 13 · F12(Q23):线上 material_kinds 备件那一行的说明改成镜像里那一句(幂等;按普通的改动进变更记录)──────────────────
UPDATE public.material_kinds
   SET notes = '机器的备件。按进料批收货,于是库存与成本都数得上(received as lots so stock and cost are counted);'
     || '出库挂在一条保养记录上(issued against a maintenance record);不逐件追溯(no per-piece traceability)。'
     || '【自成一类,不并进耗材】(PROC-0b N3,Tim 裁定;MES-0 Q70 · MES-7a Step 0 Q2 改写 —— 原来那句"不按批次追溯"与按批收货相反)。'
 WHERE code = 'spare_part' AND notes IS DISTINCT FROM '机器的备件。按进料批收货,于是库存与成本都数得上(received as lots so stock and cost are counted);'
     || '出库挂在一条保养记录上(issued against a maintenance record);不逐件追溯(no per-piece traceability)。'
     || '【自成一类,不并进耗材】(PROC-0b N3,Tim 裁定;MES-0 Q70 · MES-7a Step 0 Q2 改写 —— 原来那句"不按批次追溯"与按批收货相反)。';

-- ── 14 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.record_incident(text, timestamp with time zone, text, text, boolean, uuid, text, uuid, uuid, numeric, uuid, bigint, uuid, text, text, text, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_incident(text, timestamp with time zone, text, text, boolean, uuid, text, uuid, uuid, numeric, uuid, bigint, uuid, text, text, text, numeric, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_incident_update(uuid, text, timestamp with time zone, text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_incident_update(uuid, text, timestamp with time zone, text, text, text, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.suggest_incident_batches(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.suggest_incident_batches(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.link_incident_batch(uuid, text, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.link_incident_batch(uuid, text, uuid, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.unlink_incident_batch(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.unlink_incident_batch(bigint, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.set_safety_settings(integer, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_safety_settings(integer, boolean, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[], uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[], uuid[]) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.next_incident_code(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.next_incident_code(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.business_days_after(date, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.business_days_after(date, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_incident_kind_code() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_incident_kind_code() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_incident_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_incident_write() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_incident_update_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_incident_update_write() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_incident_batch_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_incident_batch_write() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_incident_kind_code() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_incident_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_incident_update_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_incident_batch_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid, uuid) FROM authenticated;

-- ── 15 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes7b1_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes7b1_pending_after ON COMMIT DROP AS
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
    -- ① 授权:恰好多了那十二行安全码,别的一行没动;admin 持目录里每一个码(81);编辑码蕴含查看码、动作码蕴含查看码;data.view_health 的持有人没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes7b1_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM mes7b1_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS DISTINCT FROM 'admin:module.safety.edit, admin:module.safety.view, auditor:module.safety.view, cco:module.safety.view, cfo:module.safety.view, cto:module.safety.edit, cto:module.safety.view, finance:module.safety.view, gm:module.safety.view, operations:module.safety.view, warehouse:module.safety.edit, warehouse:module.safety.view' THEN
        RAISE EXCEPTION 'MES7B1_PROOF|grant change is not exactly the twelve safety grants: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM permissions) <> 81
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES7B1_PROOF|admin does not hold every one of the 81 codes';
    END IF;
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code LIKE '%.edit'
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = replace(rp.permission_code, '.edit', '.view'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES7B1_PROOF|edit-implies-view violated: %', v_bad; END IF;
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES7B1_PROOF|action-implies-view violated: %', v_bad; END IF;
    IF (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'data.view_health') IS DISTINCT FROM 'admin,cco,cfo,finance,hr' THEN
        RAISE EXCEPTION 'MES7B1_PROOF|data.view_health holders changed';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code LIKE 'module.safety.%' AND requires_view_any IS NOT NULL) THEN
        RAISE EXCEPTION 'MES7B1_PROOF|module codes do not declare requires_view_any (only action codes do)';
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES7B1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes7b1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes7b1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES7B1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变(不合格报告减掉新加的那一列)
    IF EXISTS ((SELECT b.k, b.id FROM mes7b1_pending_before b EXCEPT SELECT a.k, a.id FROM mes7b1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes7b1_pending_after a EXCEPT SELECT b.k, b.id FROM mes7b1_pending_before b)) THEN
        RAISE EXCEPTION 'MES7B1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t ) IS DISTINCT FROM (SELECT inbound_batches FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t ) IS DISTINCT FROM (SELECT output_batches FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inventory_movements t ) IS DISTINCT FROM (SELECT inventory_movements FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) IS DISTINCT FROM (SELECT journal_entries FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) IS DISTINCT FROM (SELECT journal_lines FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM materials t ) IS DISTINCT FROM (SELECT materials FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM material_kinds t WHERE code <> 'spare_part') IS DISTINCT FROM (SELECT material_kinds FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_downtime t ) IS DISTINCT FROM (SELECT equipment_downtime FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_maintenance t ) IS DISTINCT FROM (SELECT equipment_maintenance FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_runs t ) IS DISTINCT FROM (SELECT processing_runs FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_inputs t ) IS DISTINCT FROM (SELECT processing_inputs FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_outputs t ) IS DISTINCT FROM (SELECT processing_outputs FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_run_events t ) IS DISTINCT FROM (SELECT processing_run_events FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'incident_id')::text, '|' ORDER BY (to_jsonb(t) - 'incident_id')::text), '')) FROM nonconformance_reports t ) IS DISTINCT FROM (SELECT nonconformance_reports FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batch_safety_states t ) IS DISTINCT FROM (SELECT inbound_batch_safety_states FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batch_safety_states t ) IS DISTINCT FROM (SELECT output_batch_safety_states FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM shift_handovers t ) IS DISTINCT FROM (SELECT shift_handovers FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM shift_handover_items t ) IS DISTINCT FROM (SELECT shift_handover_items FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM shift_handover_equipment_refs t ) IS DISTINCT FROM (SELECT shift_handover_equipment_refs FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM storage_locations t ) IS DISTINCT FROM (SELECT storage_locations FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t ) IS DISTINCT FROM (SELECT employees FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM public_holidays t ) IS DISTINCT FROM (SELECT public_holidays FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t ) IS DISTINCT FROM (SELECT certificates_of_destruction FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) IS DISTINCT FROM (SELECT cod_issues FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_analysis t ) IS DISTINCT FROM (SELECT certificates_of_analysis FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM coa_issues t ) IS DISTINCT FROM (SELECT coa_issues FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM warehouse_requests t ) IS DISTINCT FROM (SELECT warehouse_requests FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) IS DISTINCT FROM (SELECT expenses FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) IS DISTINCT FROM (SELECT payments FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) IS DISTINCT FROM (SELECT approval_log FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM fixed_assets t ) IS DISTINCT FROM (SELECT fixed_assets FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM accounts t ) IS DISTINCT FROM (SELECT accounts FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t WHERE code NOT IN ('module.safety.view', 'module.safety.edit', 'data.view_health')) IS DISTINCT FROM (SELECT permissions FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t WHERE key <> 'incident') IS DISTINCT FROM (SELECT document_types FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) IS DISTINCT FROM (SELECT ingest_settings FROM mes7b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_data_classes t ) IS DISTINCT FROM (SELECT ingest_data_classes FROM mes7b1_rows_before) THEN
        RAISE EXCEPTION 'MES7B1_PROOF|a pre-existing batch, movement, journal, material, kind, downtime, maintenance, run, event, NCR, safety state, handover, location, employee, holiday, certificate, request, expense, payment, approval, asset, account, permission, document type or ingestion row changed';
    END IF;

    -- ④ 新表:事故 / 更新 / 链接 / 交接班引用一行都没有;种类恰好那七种(没有 other);设定一行,V19 = 2,未确认,带出处
    IF EXISTS (SELECT 1 FROM incidents) OR EXISTS (SELECT 1 FROM incident_updates) OR EXISTS (SELECT 1 FROM incident_batches)
       OR EXISTS (SELECT 1 FROM shift_handover_incident_refs) OR EXISTS (SELECT 1 FROM nonconformance_reports WHERE incident_id IS NOT NULL) THEN
        RAISE EXCEPTION 'MES7B1_PROOF|no incident, update, link, handover reference or incident NCR may exist';
    END IF;
    IF (SELECT string_agg(code, ',' ORDER BY sort_order) FROM incident_kinds WHERE is_active)
         IS DISTINCT FROM 'thermal_runaway,fire_smoke,gas_release,dust_concentration,injury,near_miss,emission_exceedance'
       OR (SELECT count(*) FROM incident_kinds) <> 7 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|incident kinds are not the seven ruled (Q4)';
    END IF;
    IF (SELECT count(*) FROM safety_settings) <> 1
       OR (SELECT nea_report_working_days FROM safety_settings) IS DISTINCT FROM 2
       OR (SELECT nea_report_days_confirmed_at FROM safety_settings) IS NOT NULL
       OR (SELECT nea_report_days_source FROM safety_settings) NOT LIKE '%docs/forward-queue.md:2402%' THEN
        RAISE EXCEPTION 'MES7B1_PROOF|V19 must be stored as 2 working days, unconfirmed, with its source (Q11)';
    END IF;

    -- ⑤ F12:备件那一行的说明读回来 = 镜像那一句
    IF (SELECT notes FROM material_kinds WHERE code = 'spare_part') IS DISTINCT FROM '机器的备件。按进料批收货,于是库存与成本都数得上(received as lots so stock and cost are counted);'
     || '出库挂在一条保养记录上(issued against a maintenance record);不逐件追溯(no per-piece traceability)。'
     || '【自成一类,不并进耗材】(PROC-0b N3,Tim 裁定;MES-0 Q70 · MES-7a Step 0 Q2 改写 —— 原来那句"不按批次追溯"与按批收货相反)。' THEN
        RAISE EXCEPTION 'MES7B1_PROOF|F12: the spare_part note is not the mirror sentence: %', (SELECT notes FROM material_kinds WHERE code = 'spare_part');
    END IF;
    RAISE NOTICE 'MES7B1 F12 spare_part note read back: %', (SELECT notes FROM material_kinds WHERE code = 'spare_part');

    -- ⑥ 本事务往变更记录只写了本刀种的那几行(按 txid 认 —— 同一时刻同事们在线上的写不算在本刀头上):
    --    权限目录 2 插 1 改 · 授权 12 插 · 物料种类 1 改(F12)· 单据登记 / 例外 ≤ 1 插
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes7b1_log_before), 0) AND c.txid = txid_current()
       AND NOT ((c.op = 'INSERT' AND c.table_name IN ('permissions', 'role_permissions', 'incident_kinds', 'safety_settings',
                                                      'document_types', 'document_type_exceptions', 'document_relation_exceptions'))
                OR (c.op = 'UPDATE' AND c.table_name IN ('permissions', 'material_kinds')));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES7B1_PROOF|unexpected change_log rows: %', v_bad; END IF;
    -- 种类与设定的引导行在表建起来的那一刻插进去,而它们的变更记录绑定在第 11 步才挂上 —— 所以它们不在记录里(与每一本引导过的字典同一个样子)
    SELECT count(*) INTO v_n FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes7b1_log_before), 0) AND c.txid = txid_current()
       AND c.table_name IN ('role_permissions', 'material_kinds');
    IF v_n <> 13 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|change_log rows for grants + F12 = % (expected 12 + 1)', v_n;
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES7B1_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑦ 结构:三支换了签名的只剩新签名;守卫都在;NCR 的来源认 incident;单据登记 60 行,INC 一行;305 张表;审计主语在册
    IF to_regprocedure('public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid)') IS NOT NULL
       OR to_regprocedure('public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint)') IS NOT NULL
       OR to_regprocedure('public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[])') IS NOT NULL
       OR to_regprocedure('public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid, uuid)') IS NULL
       OR to_regprocedure('public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint, uuid)') IS NULL
       OR to_regprocedure('public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[], uuid[])') IS NULL THEN
        RAISE EXCEPTION 'MES7B1_PROOF|open_ncr / ncr_open_internal / submit_shift_handover must exist only with their new signatures';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_incidents_insert' AND tgrelid = 'public.incidents'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_incidents_immutable' AND tgrelid = 'public.incidents'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_incident_updates_immutable' AND tgrelid = 'public.incident_updates'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_incident_batches_row' AND tgrelid = 'public.incident_batches'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_incident_kinds_code_locked' AND tgrelid = 'public.incident_kinds'::regclass)
       OR pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'nonconformance_reports_source_check')) NOT LIKE '%incident%' THEN
        RAISE EXCEPTION 'MES7B1_PROOF|a guard trigger or the NCR source check is missing';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 60 OR document_type_prefix('incident') <> 'INC' THEN
        RAISE EXCEPTION 'MES7B1_PROOF|document_types should be 60 with INC';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 305 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|expected 305 public tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'incident' AND s.view_codes = ARRAY['module.safety.view'])
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'incident' AND m.table_name = 'incident_updates' AND m.home) THEN
        RAISE EXCEPTION 'MES7B1_PROOF|the incident trail subject or its members are missing';
    END IF;

    -- ⑧ 匿名面与函数面:anon 能执行的【恰好】两支;员工函数 DEFINER、调得到;两支只读的算术调得到;守卫与内层调不到;
    --    新表与视图 anon 读不到;底视图 authenticated 也读不到;受伤的四样细节与受伤的人不在 authenticated 的列授权里
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES7B1_PROOF|anon executes: %', v_bad;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_incident(text, timestamp with time zone, text, text, boolean, uuid, text, uuid, uuid, numeric, uuid, bigint, uuid, text, text, text, numeric, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_incident(text, timestamp with time zone, text, text, boolean, uuid, text, uuid, uuid, numeric, uuid, bigint, uuid, text, text, text, numeric, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_incident(text, timestamp with time zone, text, text, boolean, uuid, text, uuid, uuid, numeric, uuid, bigint, uuid, text, text, text, numeric, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.record_incident(text, timestamp with time zone, text, text, boolean, uuid, text, uuid, uuid, numeric, uuid, bigint, uuid, text, text, text, numeric, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_incident_update(uuid, text, timestamp with time zone, text, text, text, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_incident_update(uuid, text, timestamp with time zone, text, text, text, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_incident_update(uuid, text, timestamp with time zone, text, text, text, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.record_incident_update(uuid, text, timestamp with time zone, text, text, text, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.suggest_incident_batches(uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.suggest_incident_batches(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.suggest_incident_batches(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.suggest_incident_batches(uuid): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.link_incident_batch(uuid, text, uuid, uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.link_incident_batch(uuid, text, uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.link_incident_batch(uuid, text, uuid, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.link_incident_batch(uuid, text, uuid, uuid): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.unlink_incident_batch(bigint, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.unlink_incident_batch(bigint, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.unlink_incident_batch(bigint, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.unlink_incident_batch(bigint, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.set_safety_settings(integer, boolean, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.set_safety_settings(integer, boolean, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.set_safety_settings(integer, boolean, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.set_safety_settings(integer, boolean, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint, uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint, uuid): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[], uuid[])'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[], uuid[])'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[], uuid[])'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[], uuid[]): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.next_incident_code(date)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.next_incident_code(date)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.next_incident_code(date): expected authenticated yes, anon no';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.business_days_after(date, integer)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.business_days_after(date, integer)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.business_days_after(date, integer): expected authenticated yes, anon no';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_incident_kind_code()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_incident_kind_code()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.guard_incident_kind_code() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_incident_write()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_incident_write()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.guard_incident_write() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_incident_update_write()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_incident_update_write()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.guard_incident_update_write() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_incident_batch_write()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_incident_batch_write()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.guard_incident_batch_write() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid, uuid) must be a function nobody outside can call';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('incident_kinds', 'safety_settings', 'incidents', 'incident_updates', 'incident_batches', 'shift_handover_incident_refs', 'incident_current_all', 'incidents_masked', 'incident_rows', 'incident_batch_rows', 'incident_people')
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES7B1_PROOF|anon can read %', v_bad; END IF;
    IF has_table_privilege('authenticated', 'public.incident_current_all'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|the base view must not be readable by authenticated';
    END IF;
    SELECT string_agg(col, ', ') INTO v_bad FROM unnest(ARRAY['injured_employee_id', 'injured_person_name', 'injury_nature',
                                                             'injury_treatment', 'days_lost']) col
     WHERE has_column_privilege('authenticated', 'public.incidents'::regclass, col, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES7B1_PROOF|authenticated can read the injury column(s) % directly', v_bad; END IF;
    IF NOT has_column_privilege('authenticated', 'public.incidents'::regclass, 'what_happened', 'SELECT') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|the column-list grant on incidents is missing its ordinary columns';
    END IF;

    -- ⑨ 那 44 条开着的读策略还是 44 条
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|the open read policies are no longer 44';
    END IF;

    -- ⑩ 变更记录:覆盖零缺口(六张新表记,豁免仍是 8);遮蔽零缺口(规则 119 —— 多了事故的五列受伤细节)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 119 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑪ 提醒臂 68、待补的值 25(V19 那一行从第一天起就在:未确认)
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 68
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 25 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|reminder arms 68 / pending-value arms 25 expected';
    END IF;

    -- ⑫ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes7b1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES7B1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes7b1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes7b1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
