-- db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql
-- MES-8b-1 —— 进料毛利、库存敞口与月度合规包:每一批进料看得到它到今天为止经由用它做出来、卖出去的每一样赚了多少(没卖的按成本在库);
--   价格敞口页多一节「还在库的可计价金属按最新的价值多少」;一个关了账的月份可以冻成一份合规包(CPK-…),带那个月的物料平衡、库存变动、
--   执照位置、事故、环境监测与巡检,下载的 PDF 定格在冻下来那一刻。
--   (MES 组的第二十一刀,v1.4.57;发布那一行在 docs/handbacks/MES-8b-1.md 的抬头。)由 db/scripts/build_mes8b1_migration.py 从镜像拼出;
--   改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-17:MES-8 Step 0 的 Q10–Q18 · Q28,以及 Q21–Q24 里 8b-1 那一半,照推荐裁定)
--   ① 三张新表:compliance_settings(单行;V26 NEA 申报的格式与频率,V27 欧盟回收效率的方法与目标 —— 全空引导)·
--      compliance_packs(CPK-YYYY-MM,重出 -2;payload 冻下来;只许被取代)· compliance_pack_issues(PDF 的每一版:路径与 sha256,只追加)。
--   ② 函数:inbound_batch_margin(按投入质量的份额逐层乘下去;收入只取 sales_records;任一条腿没价 → not computable,永远不是 0)·
--      inventory_metal_exposure(可计价金属 × 在库 × 含量 × 今天或之前最新的价,带价的日子;not measured · no price · price ambiguous)·
--      compliance_pack_data(八节)· freeze_compliance_pack(只冻关了账的月份)· record_compliance_pack_issue · set_compliance_settings ·
--      compliance_pack_month_status(月结那一行)· 两支守卫。两支读者的门都是常设决定 2:data.view_prices AND (finance.view OR processing.view)。
--   ③ 新码 module.compliance.view → admin · auditor · cco · cfo · cto · gm;action.compliance_pack(声明 module.compliance.view)→ admin · cto
--      —— 本刀唯一的授权改动(Q17,八行);单据登记 CPK(62 → 63);提醒一支 compliance_pack_not_frozen(71 → 72);待补的值两支 V26 · V27(31 → 33);
--      审计主语两个与成员一个;三张新表进变更记录(豁免仍是 8);没有遮蔽的列(规则仍 119)。
--   ④ 私有桶 compliance-documents 与它的三条策略(读 module.compliance.view;传 action.compliance_pack;删 action.compliance_pack 且那个对象还没被记)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;授权只多上面那八行;不写、不改任何一批进料、产出、流水、销售、结算、价、含量、执照、
--   事故、监测、巡检、分录、对账单、证书或销毁证书(两张已签发的 COD 的字节与档案一个字不动);不冻任何一份包、不给 V26 / V27;不锁也不开任何一个月;
--   不回填;require_calibrated_since 保持空。线上由本迁移造出的只有:三张表(设定那一行四样全空)、目录两行与八行授权、单据登记一行、一个空桶。
--
-- 【破窗】(Q23:这一窗什么都不坏)旧应用不读新表与新函数;operations_now 只多一支(线上 locked_before = system_start_date = 2026-08-01,
--   没有一个已关账的月 → 一行都不出);pending_values 只多两支(V26 · V27 各一行;旧应用的待补值页认不得这两个值码,会画成键名,直到部署);
--   trail_subjects / trail_subject_members 只多三行(旧应用不认这两个主语,从不问它们)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了那八行,admin 持目录里每一个码(84),每一个持动作码的角色也持它声明的
--   查看码;在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的行逐字未变(见 DIGEST_TABLES);
--   包与签发档空、设定那一行四样全空;anon 能执行的【恰好】两支;员工函数 DEFINER、调得到,守卫调不到;那 44 条开着的读策略还是 44 条;
--   变更记录覆盖与遮蔽零缺口(豁免 8、规则 119);提醒臂 72(新那一支一行都不出)、待补的值 33 支;单据登记 63 行;320 张表;没有一张视图对 anon /
--   authenticated 带写授权;桶私有、空、三条策略;两张 COD 的存储对象一个字节不动。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子(开场读数,docs/surveys/MES-8b-1/live-readings.sql)──────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES8B1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.compliance_settings') IS NOT NULL OR to_regclass('public.compliance_packs') IS NOT NULL
       OR to_regclass('public.compliance_pack_issues') IS NOT NULL
       OR to_regprocedure('public.inbound_batch_margin(uuid)') IS NOT NULL OR to_regprocedure('public.inventory_metal_exposure()') IS NOT NULL
       OR EXISTS (SELECT 1 FROM document_types WHERE key = 'compliance_pack' OR prefix = 'CPK')
       OR EXISTS (SELECT 1 FROM permissions WHERE code IN ('module.compliance.view', 'action.compliance_pack'))
       OR EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'compliance-documents') THEN
        RAISE EXCEPTION 'MES8B1_PRE|MES-8b-1 objects already exist';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES8B1_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 82
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES8B1_PRE|expected a catalogue of 82 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM roles WHERE code IN ('admin', 'auditor', 'cco', 'cfo', 'cto', 'gm') AND is_active) <> 6 THEN
        RAISE EXCEPTION 'MES8B1_PRE|the roles admin, auditor, cco, cfo, cto, gm must exist and be active (Q17)';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 62 THEN
        RAISE EXCEPTION 'MES8B1_PRE|expected 62 document types';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES8B1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 119 THEN
        RAISE EXCEPTION 'MES8B1_PRE|expected 119 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 71 THEN
        RAISE EXCEPTION 'MES8B1_PRE|operations_now should have 71 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 31 THEN
        RAISE EXCEPTION 'MES8B1_PRE|pending_values should have 31 arms before';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 317 THEN
        RAISE EXCEPTION 'MES8B1_PRE|expected 317 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES8B1_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'MES8B1_PRE|expected the two recorded COD byte strings';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes8b1_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes8b1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes8b1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes8b1_cod_objects_before ON COMMIT DROP AS
SELECT name, metadata ->> 'size' AS size, metadata ->> 'eTag' AS etag FROM storage.objects WHERE bucket_id = 'cod-documents';
CREATE TEMP TABLE mes8b1_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t ) AS inbound_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t ) AS output_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inventory_movements t ) AS inventory_movements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_runs t ) AS processing_runs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_inputs t ) AS processing_inputs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_outputs t ) AS processing_outputs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_records t ) AS sales_records,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_settlements t ) AS sales_settlements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM metal_prices t ) AS metal_prices,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM metal_price_indices t ) AS metal_price_indices,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batch_metals t ) AS inbound_batch_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batch_metals t ) AS output_batch_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM substances t ) AS substances,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM materials t ) AS materials,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM material_kinds t ) AS material_kinds,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_allocations t ) AS payment_allocations,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t ) AS suppliers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM purchase_orders t ) AS purchase_orders,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM customers t ) AS customers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM company_compliance t ) AS company_compliance,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM licence_storage_limits t ) AS licence_storage_limits,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM nea_waste_categories t ) AS nea_waste_categories,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM receipt_ceiling_checks t ) AS receipt_ceiling_checks,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM incidents t ) AS incidents,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM incident_updates t ) AS incident_updates,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM environmental_results t ) AS environmental_results,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM environmental_parameters t ) AS environmental_parameters,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_templates t ) AS inspection_templates,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_runs t ) AS inspection_runs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_results t ) AS inspection_results,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_findings t ) AS inspection_findings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_finding_closures t ) AS inspection_finding_closures,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM management_packs t ) AS management_packs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM company_profile t ) AS company_profile,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_statements t ) AS supplier_statements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_statement_issues t ) AS supplier_statement_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t ) AS certificates_of_destruction,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) AS cod_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_analysis t ) AS certificates_of_analysis,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM coa_issues t ) AS coa_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM customer_statements t ) AS customer_statements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM statement_issues t ) AS statement_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) AS approval_log,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM accounts t ) AS accounts,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t ) AS employees,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM tasks t ) AS tasks,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t WHERE code NOT IN ('module.compliance.view', 'action.compliance_pack')) AS permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t WHERE permission_code NOT IN ('module.compliance.view', 'action.compliance_pack')) AS role_permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) AS roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) AS user_roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t WHERE key <> 'compliance_pack') AS document_types,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) AS ingest_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) AS finance_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM safety_settings t ) AS safety_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_score_settings t ) AS supplier_score_settings;

-- ── 1 · 新函数(镜像原样),先于新表:两支守卫(冻下来的包只许被取代 · 签发档只追加)──

-- db/functions/guard_compliance_pack_write.sql
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q16):【冻下来的合规包不改】—— compliance_packs 的删对谁都按名拒;改只许一件事:
--   一份还没被取代的包【被取代】(superseded_at / superseded_by / superseded_reason 从空到有,别的一列都不动)——
--   freeze_compliance_pack 为同一个月出 -2 时那一步。其余一律 COMPLIANCE_PACK_IMMUTABLE|<动作>。旧的 payload 因此一个字不动。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.guard_compliance_pack_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'UPDATE'
       AND OLD.superseded_at IS NULL AND NEW.superseded_at IS NOT NULL
       AND (to_jsonb(NEW) - 'superseded_at' - 'superseded_by' - 'superseded_reason')
           = (to_jsonb(OLD) - 'superseded_at' - 'superseded_by' - 'superseded_reason') THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'COMPLIANCE_PACK_IMMUTABLE|%', lower(TG_OP);
END;
$function$;

-- db/functions/guard_compliance_pack_issue_write.sql
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q16):【签发档只追加】—— compliance_pack_issues 的改与删对谁都按名拒。一份存下的 PDF 就是交出去过的那一份;
--   重新渲染 = 新的一版(record_compliance_pack_issue),绝不覆盖旧行。自己报名(一句写着别的单据的拒绝在合规包上是一句假话)。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.guard_compliance_pack_issue_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'COMPLIANCE_PACK_ISSUE_IMMUTABLE|%', lower(TG_OP);
END;
$function$;

-- ── 2 · 新表(镜像原样):合规包的设定 · 合规包 · 它的签发档 ─────────────────────

-- db/tables/compliance_settings.sql
-- MES-8b-1(2026-10-17,MES-0 §5.1 V26 · V27 · Q82 · Q93;MES-8 Step 0 Q14 · Q18 · Q28,Tim):【合规包的两个待补的值 —— 单行】。
--   V26  nea_return_format · nea_return_frequency   NEA 申报的格式与频率(NEA 执照下来时由执照写明)。
--   V27  eu_efficiency_method · eu_efficiency_targets  欧盟回收效率的计算方法与目标(欧盟实施条例或欧盟买家给出)。
--   【引导一律为空】(Q18):这一行在线上从第一天起就是两行待补的值(V18 / V20 的先例:一本空的字典也是一行)。
--   【填了也不算任何东西】(Q28):合规包把这几句话照原样印进第 7、8 节;本刀不按它们算 NEA 申报表、不算回收效率 —— 那是 V27 给了之后
--   自己那一刀的事。每一份冻下来的包把【当时】这一行抄进 payload,所以改这一行永远不改写一份过去的包。
--   由 action.compliance_pack 经 set_compliance_settings 改;修改史在变更记录里(主语 compliance_settings,画在合规包页)。
--   RUNTIME CONFIG:Tim 设一次,线上就与本文件不同 —— 那是系统在正常工作(supplier_score_settings 的先例)。
--
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.compliance_settings (
    id                    boolean PRIMARY KEY DEFAULT true CHECK (id),
    nea_return_format     text CHECK (nea_return_format IS NULL OR btrim(nea_return_format) <> ''),
    nea_return_frequency  text CHECK (nea_return_frequency IS NULL OR btrim(nea_return_frequency) <> ''),
    eu_efficiency_method  text CHECK (eu_efficiency_method IS NULL OR btrim(eu_efficiency_method) <> ''),
    eu_efficiency_targets text CHECK (eu_efficiency_targets IS NULL OR btrim(eu_efficiency_targets) <> ''),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    updated_by            uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.compliance_settings IS
    'MES-8b-1:合规包的设定(单行)。V26 = nea_return_format · nea_return_frequency(NEA 申报的格式与频率);V27 = eu_efficiency_method · eu_efficiency_targets(欧盟回收效率的方法与目标)。引导一律为空(Q18)。只是被印进合规包的几句话 —— 本刀不按它们算任何东西(Q28)。每一份冻下来的包抄走这一行。action.compliance_pack 经 set_compliance_settings 改。';
COMMENT ON COLUMN public.compliance_settings.nea_return_format IS
    'V26:NEA 申报的格式(执照写明的那一份表)。空 = Not yet set(合规包第 7 节读「NEA return — format not yet set (V26)」)。';
COMMENT ON COLUMN public.compliance_settings.nea_return_frequency IS
    'V26:NEA 申报的频率。与格式一起才算给了。';
COMMENT ON COLUMN public.compliance_settings.eu_efficiency_method IS
    'V27:欧盟回收效率的计算方法(实施条例 / 欧盟买家)。空 = Not yet set(第 8 节读「EU recycling efficiency — method not yet set (V27)」)。';
COMMENT ON COLUMN public.compliance_settings.eu_efficiency_targets IS
    'V27:欧盟回收效率的目标。与方法一起才算给了。';

INSERT INTO public.compliance_settings (id) VALUES (true);

CREATE TRIGGER trg_compliance_settings_updated_at
    BEFORE UPDATE ON public.compliance_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.compliance_settings ENABLE ROW LEVEL SECURITY;
-- 读:合规的查看码(合规包页的设定面板、待补的值那两行)。写只经函数。
CREATE POLICY "compliance_settings select by permission" ON public.compliance_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.compliance.view'::text));
GRANT SELECT ON public.compliance_settings TO authenticated;
REVOKE ALL ON public.compliance_settings FROM anon;

-- db/tables/compliance_packs.sql
-- MES-8b-1(2026-10-17,MES-0 Q82;MES-8 Step 0 Q14 · Q15 · Q16 · Q28,Tim):【一个月的合规包 —— 冻下来的那一份】。
--   payload 就是 compliance_pack_data(那个月) 的返回值(一份实现,两个调用方:页面预览与冻结),冻结那一刻抄下:
--     ① 那个月的物料平衡(全厂与每道工序)② 库存滚动 ③ 当月末在效的执照、月末按 NEA 类别的在库吨数与当月的上限判定
--     ④ 当月的事故(种类、要不要通报 NEA、通报与书面报告的日子 —— 【不带任何受伤的细节】,也不带任何一段人写的文字)
--     ⑤ 当月的环境监测结果与它们的限值、判词 ⑥ 当月做过的巡检与月末还开着的发现 ⑦ NEA 申报(V26)⑧ 欧盟回收效率(V27)。
--   【只有关账的月份冻得下来】(Q15):判据 locked_before > 月末,与 freeze_management_pack 的 PACK_MONTH_NOT_LOCKED 逐字同源 ——
--     月份锁上之后那些数不会再动,冻下来的才是一个承诺(COMPLIANCE_PACK_MONTH_NOT_LOCKED|<YYYY-MM>|<锁到>)。
--   编号 CPK-YYYY-MM;同一个月重出一份 = CPK-YYYY-MM-2、-3 …,要写理由,旧的那一份落 superseded_*(Q16)——
--     【旧的 payload 与它存下的字节一个字不动】;没有作废。
--   对外(NEA、审计、要求它的买家):PDF 只从 payload 渲染,存私有桶 compliance-documents,按 sha256 记在 compliance_pack_issues,
--   每一次取档重算,对不上 409。一律英文。
--   【不带钱】—— payload 里没有一个价、一笔金额或工资;它也不抄任何受伤的细节(Q14 · Q22)。
--   只追加:除了"被取代"那一步,一列都改不了;删对谁都按名拒(trg_compliance_packs_write)。唯一写入口 freeze_compliance_pack()。
--
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.compliance_packs (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                     text NOT NULL UNIQUE CHECK (code ~ '^CPK-[0-9]{4}-[0-9]{2}(-[0-9]+)?$'),
    period_month             date NOT NULL CHECK (period_month = date_trunc('month', period_month)::date),
    period_start             date NOT NULL,
    period_end               date NOT NULL,
    locked_before_at_freeze  date NOT NULL,
    payload                  jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    notes                    text,
    frozen_at                timestamptz NOT NULL DEFAULT now(),
    frozen_by                uuid,
    superseded_at            timestamptz,
    superseded_by            uuid REFERENCES public.compliance_packs (id) DEFERRABLE INITIALLY DEFERRED,   -- 旧的那一份先落 superseded、新的那一行随后才插(一个月只许一份在册),所以这条引用在事务末尾才查
    superseded_reason        text,
    CONSTRAINT compliance_packs_period CHECK (period_start = period_month AND period_end = (period_month + INTERVAL '1 month - 1 day')::date),
    CONSTRAINT compliance_packs_locked CHECK (locked_before_at_freeze > period_end),
    CONSTRAINT compliance_packs_superseded_whole CHECK ((superseded_at IS NULL) = (superseded_by IS NULL)
                                                         AND (superseded_at IS NULL) = (superseded_reason IS NULL))
);

COMMENT ON TABLE public.compliance_packs IS
    'MES-8b-1:一个月的合规包(CPK-YYYY-MM;重出 -2、-3 …,带理由取代旧的)。payload = compliance_pack_data(那个月) 在冻结那一刻的返回值:物料平衡 · 库存滚动 · 执照与 NEA 类别的在库与上限判定 · 事故(不带受伤细节)· 环境监测 · 巡检与开着的发现 · V26 · V27。只有关账的月份冻得下来。不带钱。PDF 只从 payload 渲染,字节在私有桶 compliance-documents、哈希在 compliance_pack_issues。只追加;唯一写入口 freeze_compliance_pack()。';

-- 一个月只许有一份在册(取代时旧的那一份【先】落 superseded —— freeze_management_pack 的同一个顺序)
CREATE UNIQUE INDEX idx_compliance_packs_live_month ON public.compliance_packs (period_month) WHERE superseded_at IS NULL;

CREATE TRIGGER trg_compliance_packs_write
    BEFORE UPDATE OR DELETE ON public.compliance_packs
    FOR EACH ROW EXECUTE FUNCTION public.guard_compliance_pack_write();

ALTER TABLE public.compliance_packs ENABLE ROW LEVEL SECURITY;
-- 读:合规的查看码(清单、包页、PDF)。写只经函数。
CREATE POLICY "compliance_packs select by permission" ON public.compliance_packs
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.compliance.view'::text));
GRANT SELECT ON public.compliance_packs TO authenticated;
REVOKE ALL ON public.compliance_packs FROM anon;

-- db/tables/compliance_pack_issues.sql
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q16,Tim):合规包的签发档 —— supplier_statement_issues 的形状(一份包可以渲染好几版,每一版一行),
--   记录它的那支函数照分析证书那一份写:哈希一律小写存;路径必须在 <包 id>/ 之下;同一份包上同一串字节【只记一次】
--   (COMPLIANCE_PACK_BYTES_ALREADY_RECORDED)。字节在私有桶 compliance-documents;取档时重算 sha256,对不上就拒(409)。
--   只追加(trg_compliance_pack_issues_append_only),唯一写入口 record_compliance_pack_issue()。
--   【没有"已寄出"标志】—— 系统不知道 NEA 或买家收没收到。
--
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.compliance_pack_issues (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    pack_id    uuid NOT NULL REFERENCES public.compliance_packs (id),
    version    integer NOT NULL CHECK (version >= 1),
    file_path  text NOT NULL,
    sha256     text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at  timestamptz NOT NULL DEFAULT now(),
    issued_by  uuid,
    UNIQUE (pack_id, version),
    UNIQUE (pack_id, sha256)
);

COMMENT ON TABLE public.compliance_pack_issues IS
    'MES-8b-1:合规包的签发档(*_issues 族)。谁、何时、第几版、哪一份包、字节摘要。哈希小写;路径在 <包 id>/ 之下;同一份包同一串字节只记一次。字节在私有桶 compliance-documents,取档重算 sha256、对不上 409。只追加;唯一写入口 record_compliance_pack_issue()。数字变了要出的是【另一份包】(CPK-…-2),不是这里的下一版。';

CREATE INDEX idx_compliance_pack_issues_pack
    ON public.compliance_pack_issues (pack_id, version DESC);

CREATE TRIGGER trg_compliance_pack_issues_append_only
    BEFORE UPDATE OR DELETE ON public.compliance_pack_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_compliance_pack_issue_write();

ALTER TABLE public.compliance_pack_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY "compliance_pack_issues select by permission" ON public.compliance_pack_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.compliance.view'::text));
GRANT SELECT ON public.compliance_pack_issues TO authenticated;
REVOKE ALL ON public.compliance_pack_issues FROM anon;

-- ── 3 · 权限目录两行 + 动作码声明的查看码(与 db/tables/permissions.sql 逐字同一份)· 单据登记 CPK(与 db/tables/document_types.sql 那一行同一份)──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('module.compliance.view', 'module', 'Compliance (view)', '合规(查看)', 'Monthly compliance packs — a locked month''s processing balance, stock movement, licence position by NEA category, incidents (without injury details), environmental results and inspections — the live preview, the frozen packs and their PDFs, and the two pending values V26 / V27; read only.', '月度合规包 —— 一个已关账月份的物料平衡、库存变动、按 NEA 类别的执照位置、事故(不带受伤的细节)、环境监测结果与巡检 —— 实时预览、冻下来的包与它们的 PDF,以及两个待补的值 V26 / V27;只读。', 154),
    ('action.compliance_pack', 'action', 'Freeze compliance packs', '冻结合规包', 'Freeze the compliance pack of a finance-locked month (CPK-YYYY-MM), re-issue it with a required reason (CPK-YYYY-MM-2, the first one kept), archive its PDF, and set the NEA return format (V26) and the EU recycling-efficiency method (V27).', '冻下一个已关账月份的合规包(CPK-YYYY-MM)、写明理由重出一份(CPK-YYYY-MM-2,第一份留着)、存它的 PDF,以及设 NEA 申报的格式(V26)与欧盟回收效率的方法(V27)。', 1270);
UPDATE public.permissions SET requires_view_any = ARRAY['module.compliance.view'] WHERE code = 'action.compliance_pack';
INSERT INTO public.document_types (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission) VALUES
    ('compliance_pack', 'CPK', 'compliance_packs', 'gapless', NULL, '/compliance/packs', 'detail', 'superseded_reason', ARRAY['superseded_reason']::text[], ARRAY['module.compliance.view']::text[]);

-- ── 4 · 授权(MES-8 Step 0 Q17):module.compliance.view → admin · auditor · cco · cfo · cto · gm;action.compliance_pack → admin · cto
--   —— 本刀唯一的授权改动(八行)──
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'module.compliance.view' FROM roles r WHERE r.code IN ('admin', 'auditor', 'cco', 'cfo', 'cto', 'gm')
ON CONFLICT (role_id, permission_code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'action.compliance_pack' FROM roles r WHERE r.code IN ('admin', 'cto')
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 5 · 新函数(镜像原样),新表之后 ──────────────

-- db/functions/inbound_batch_margin.sql
-- MES-8b-1(2026-10-17,MES-0 Q80;MES-8 Step 0 Q10 · Q11 · Q13,Tim):【一批进料到今天为止赚了多少 —— 经由用它做出来、卖出去的每一样】。
--   ★ 归属(Q10):一批进料在每一个下游产出批里的份额 = MES-5b 的按投入质量成比例的份额(batch_balance_tree_all,share_num / share_den,
--     精确,逐层乘下去)—— 【不是】那一炉的 allocation_basis:那一条把一炉的【成本】分到它的几样产出上,它不说一样产出的收入怎么分回几条投料腿
--     (MES-8 Step 0 §14 第 1 条)。成本那一半已经带着 allocation_basis 的分法:它就是那个产出批的 unit_cost_base。
--   ★ 毛利 = Σ 份额 × (那个产出批已售数量的收入 − 它的 unit_cost_base × 已售数量)。收入与已售数量取 sales_records,
--     与 batch_margin 读法逐字相同(Q11,一个定义、一个地方):sum(amount_base) 与 sum(quantity)。
--     卖方结算(sales_settlements)【只在它过了账之后才算】—— 今天没有一条结算会过账(SETTLE-1),所以它们一笔都不进来,
--     而这是按构造的:本函数一个字都不读那张表。
--   ★ 没卖出去的那一份:按成本列为在库(份额 × 在库量 × 单位成本;进料批自己剩下的按它的落地单价)—— 不算进毛利。
--   ★ 路径上【任何】一条腿没价(进料批自己没有落地成本 / 一个产出批没有单位成本 / 一个产出批的成本不完整 —— 有没计价的投入被当成零),
--     毛利与在库成本都读「not computable」(NULL),原因逐条列出 —— 【永远不是 0】(batch_margin 那一条,NULL 传播,不靠 COALESCE)。
--     一样都没卖出去时 margin_state = nothing_sold、毛利为 NULL(没有可说的毛利,也不是 0)。
--   ★ 门(AGENTS.md 常设决定 2,Q13):data.view_prices AND (module.finance.view OR module.processing.view)。不满足就按名拒 ——
--     这支函数的 NULL 已经有主了(「not computable」),所以拒绝不能也是 NULL(CLEANUP-A 的判据);页面在调用之前按同一个判据画「受限」。
--   SECURITY DEFINER:它要读的落地单价函数刻意没授给 authenticated(inbound_batch_valuation_rows 的同一个理由)。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.inbound_batch_margin(p_inbound_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b        inbound_batches%ROWTYPE;
    v_base     text;
    v_landed   numeric;
    v_priced   boolean;
    v_lines    jsonb;
    v_reasons  jsonb;
    v_rev      numeric;
    v_cost     numeric;
    v_sold     numeric;
    v_onhand   numeric;
    v_onval    numeric;
    v_root_on  numeric;
    v_any_sold boolean;
    v_ok       boolean;
BEGIN
    PERFORM require_permission('data.view_prices');
    IF NOT (has_permission('module.finance.view') OR has_permission('module.processing.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view · module.processing.view';
    END IF;

    SELECT * INTO v_b FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_BATCH_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 落地单价(读者名:它自己再问 data.view_prices);它的 NULL 就是"这批没有落地成本"(inbound_batch_has_landed_cost 与它逐字互补 ——
    --   那一支问的是库存查看码,而本函数的门是常设决定 2,两条门不相同,所以这里只读价格那一支)
    v_landed := inbound_batch_landed_unit_cost(v_b.id);
    v_priced := v_landed IS NOT NULL;

    WITH t AS (
        SELECT * FROM batch_balance_tree_all WHERE root_kind = 'inbound' AND root_id = v_b.id
    ), nodes AS (            -- 树上的每一个产出批结点(一个产出批可以经两条路出现两次 —— 每一次是它自己的一份)
        SELECT t.node_key, t.depth, t.batch_id, t.share_num, t.share_den,
               ob.code AS batch_code, po.unit_cost_base, COALESCE(po.cost_incomplete, false) AS cost_incomplete, po.id AS po_id,
               COALESCE((SELECT f.x FROM t f WHERE f.parent_key = t.node_key AND f.node_type = 'fate' AND f.line_key = 'on_hand'), 0) AS on_hand
          FROM t JOIN output_batches ob ON ob.id = t.batch_id
          LEFT JOIN processing_outputs po ON po.output_batch_id = t.batch_id
         WHERE t.node_type = 'run_output'
    ), s AS (                -- 与 batch_margin 同一句:每一个产出批的已售数量与收入
        SELECT sr.output_batch_id, sum(sr.quantity) AS qty, sum(sr.amount_base) AS rev
          FROM sales_records sr WHERE sr.output_batch_id IN (SELECT batch_id FROM nodes) GROUP BY sr.output_batch_id
    ), l AS (
        SELECT n.*, COALESCE(s.qty, 0) AS qty_sold, COALESCE(s.rev, 0) AS revenue
          FROM nodes n LEFT JOIN s ON s.output_batch_id = n.batch_id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'node_key', l.node_key, 'depth', l.depth, 'batch_id', l.batch_id, 'batch_code', l.batch_code,
               'share', round(l.share_num / l.share_den, 6),
               'unit_cost_base', l.unit_cost_base, 'cost_incomplete', l.cost_incomplete,
               'qty_sold', round(l.qty_sold * l.share_num / l.share_den, 3),
               'revenue_base', round(l.revenue * l.share_num / l.share_den, 2),
               'cost_base', round(l.unit_cost_base * l.qty_sold * l.share_num / l.share_den, 2),
               'margin_base', round((l.revenue - l.unit_cost_base * l.qty_sold) * l.share_num / l.share_den, 2),
               'on_hand', round(l.on_hand * l.share_num / l.share_den, 3),
               'on_hand_at_cost_base', round(l.unit_cost_base * l.on_hand * l.share_num / l.share_den, 2))
             ORDER BY l.depth, l.batch_code, l.node_key), '[]'::jsonb),
           COALESCE(jsonb_agg(DISTINCT jsonb_build_object('code', CASE WHEN l.po_id IS NULL THEN 'output_not_from_a_run'
                                                                       WHEN l.unit_cost_base IS NULL THEN 'output_no_unit_cost'
                                                                       ELSE 'output_cost_incomplete' END,
                                                          'batch_code', l.batch_code))
                    FILTER (WHERE l.unit_cost_base IS NULL OR l.cost_incomplete), '[]'::jsonb),
           sum(l.revenue * l.share_num / l.share_den),
           sum(l.unit_cost_base * l.qty_sold * l.share_num / l.share_den),
           COALESCE(sum(l.qty_sold * l.share_num / l.share_den), 0),
           COALESCE(sum(l.on_hand * l.share_num / l.share_den), 0),
           sum(l.unit_cost_base * l.on_hand * l.share_num / l.share_den),
           COALESCE(bool_or(l.qty_sold > 0), false)
      INTO v_lines, v_reasons, v_rev, v_cost, v_sold, v_onhand, v_onval, v_any_sold
      FROM l;

    -- 进料批自己还在库的(份额 1)
    SELECT COALESCE(t.x, 0) INTO v_root_on FROM batch_balance_tree_all t
     WHERE t.root_kind = 'inbound' AND t.root_id = v_b.id AND t.node_type = 'fate' AND t.line_key = 'on_hand' AND t.parent_key = 'r';
    v_root_on := COALESCE(v_root_on, 0);
    IF NOT v_priced THEN
        v_reasons := jsonb_build_array(jsonb_build_object('code', 'inbound_unpriced', 'batch_code', v_b.code)) || v_reasons;
    END IF;
    v_ok := jsonb_array_length(v_reasons) = 0;

    RETURN jsonb_build_object(
        'inbound_batch_id', v_b.id, 'code', v_b.code, 'unit', v_b.unit, 'base_currency', v_base,
        'computable', v_ok, 'reasons', v_reasons,
        'margin_state', CASE WHEN NOT v_ok THEN 'not_computable' WHEN NOT v_any_sold THEN 'nothing_sold' ELSE 'computed' END,
        'qty_sold', round(v_sold, 3),
        'revenue_base', CASE WHEN v_ok THEN round(COALESCE(v_rev, 0), 2) END,
        'cost_of_sold_base', CASE WHEN v_ok THEN round(COALESCE(v_cost, 0), 2) END,
        'margin_base', CASE WHEN v_ok AND v_any_sold THEN round(v_rev - v_cost, 2) END,
        'on_hand_downstream', round(v_onhand, 3),
        'on_hand_own', round(v_root_on, 3),
        'landed_unit_cost', v_landed,
        'on_hand_at_cost_base', CASE WHEN v_ok THEN round(COALESCE(v_onval, 0) + v_root_on * v_landed, 2) END,
        'revenue_source', 'sales_records',
        'lines', v_lines);
END;
$function$;

-- db/functions/inventory_metal_exposure.sql
-- MES-8b-1(2026-10-17,MES-0 Q81;MES-8 Step 0 Q12 · Q13,Tim):【还在库的料里,可计价金属按最新的价值多少 —— 美元,带每一个价的日子】。
--   ★ 只算可计价金属(substances.role = 'payable_metal')—— 惩罚元素与别的物质不进来。
--   ★ 每一个金属:Σ 在库量(kg,进料批与产出批的流水之和 —— MES-5b 的同一个真源)× 含量 % × 那个金属【今天(新加坡日期)或之前】最新的一条
--     metal_prices(美元 / 吨),逐行带出那条价的日子(Q12)。价比那一批含量的日子还旧时,那一批记作 price_older_than_content(Step 0 Q12:标出来,不改数)。
--   ★ 只看可能含金属的料:物料种类 may_ever_be_processed(电池料、电子废料)—— 备件、耗材、包装没有含量,列进来只会是一屏的"not measured"。
--   ★ 一批一种可计价金属都没有含量:「not measured」—— 列出它的 kg,不估值;一批有别的金属的含量而缺这一种:这一种对它「not measured」。
--   ★ 一个金属一条价都没有:「no price」—— 金属吨数照列,不估值。同一个最新日子上有几条价(不同的指数):「price ambiguous」—— 不替人挑一条。
--   ★ 单位不是 kg 的批不合计,另列(unit not kg)。
--   ★ 不折算(Q81:USD,换算的那一条裁定还开着 —— BLOCKERS-0 Q1/Q2),不设阈值(Q12)。
--   ★ 门(Q13,AGENTS.md 常设决定 2):data.view_prices AND (module.finance.view OR module.processing.view);不满足按名拒,页面先画「受限」。
--     (一份"一行都没有"的敞口与一次拒绝是两件事 —— 返回集合的函数用零行表示受限就分不开,CLEANUP-A。)
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.inventory_metal_exposure()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_today date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_metals jsonb;
    v_unmeasured jsonb;
    v_not_kg jsonb;
    v_total numeric;
    v_complete boolean;
BEGIN
    PERFORM require_permission('data.view_prices');
    IF NOT (has_permission('module.finance.view') OR has_permission('module.processing.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view · module.processing.view';
    END IF;

    WITH stock AS (          -- 每一批在库量(流水之和),只看可能含金属的料、没删的批、量 > 0
        SELECT 'inbound'::text AS kind, b.id, b.code, b.unit, sum(mv.qty_delta) AS qty
          FROM inventory_movements mv JOIN inbound_batches b ON b.id = mv.inbound_batch_id
          JOIN materials m ON m.id = b.material_id JOIN material_kinds k ON k.code = m.kind_code
         WHERE b.deleted_at IS NULL AND k.may_ever_be_processed GROUP BY b.id, b.code, b.unit
        UNION ALL
        SELECT 'output'::text, b.id, b.code, b.unit, sum(mv.qty_delta)
          FROM inventory_movements mv JOIN output_batches b ON b.id = mv.output_batch_id
          JOIN materials m ON m.id = b.material_id JOIN material_kinds k ON k.code = m.kind_code
         WHERE b.deleted_at IS NULL AND k.may_ever_be_processed GROUP BY b.id, b.code, b.unit
    ), live AS (
        SELECT * FROM stock WHERE qty > 0
    ), content AS (          -- 可计价金属的含量,带含量的日子(新加坡日期)
        SELECT 'inbound'::text AS kind, c.inbound_batch_id AS id, c.metal, c.content_pct,
               (c.updated_at AT TIME ZONE 'Asia/Singapore')::date AS content_on
          FROM inbound_batch_metals c JOIN substances s ON s.code = c.metal AND s.role = 'payable_metal'
        UNION ALL
        SELECT 'output'::text, c.output_batch_id, c.metal, c.content_pct, (c.updated_at AT TIME ZONE 'Asia/Singapore')::date
          FROM output_batch_metals c JOIN substances s ON s.code = c.metal AND s.role = 'payable_metal'
    ), measured AS (         -- 单位是 kg、至少有一种可计价金属的含量的批
        SELECT l.* FROM live l WHERE l.unit = 'kg' AND EXISTS (SELECT 1 FROM content c WHERE c.kind = l.kind AND c.id = l.id)
    ), latest AS (           -- 每一个可计价金属今天或之前最新的那一天,与那一天上的几条价
        SELECT s.code AS metal, s.sort_order, d.price_date,
               (SELECT count(*) FROM metal_prices p WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date = d.price_date) AS n_prices,
               (SELECT p.price_usd_per_tonne FROM metal_prices p WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date = d.price_date
                 ORDER BY p.price_index NULLS FIRST LIMIT 1) AS price,
               (SELECT p.price_index FROM metal_prices p WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date = d.price_date
                 ORDER BY p.price_index NULLS FIRST LIMIT 1) AS price_index,
               (SELECT p.source FROM metal_prices p WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date = d.price_date
                 ORDER BY p.price_index NULLS FIRST LIMIT 1) AS price_source
          FROM substances s
          LEFT JOIN LATERAL (SELECT max(p.price_date) AS price_date FROM metal_prices p
                              WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date <= v_today) d ON true
         WHERE s.role = 'payable_metal'
    ), per AS (              -- 一个金属 × 一批:那一批这个金属的吨数
        SELECT m.kind, m.id, m.code, m.qty, c.metal, c.content_pct, c.content_on,
               m.qty * c.content_pct / 100 AS metal_kg
          FROM measured m JOIN content c ON c.kind = m.kind AND c.id = m.id
    ), lines AS (
        SELECT lt.metal, lt.sort_order, lt.price_date, lt.n_prices, lt.price, lt.price_index, lt.price_source,
               CASE WHEN lt.price_date IS NULL THEN 'no_price' WHEN lt.n_prices > 1 THEN 'price_ambiguous' ELSE 'priced' END AS state,
               (SELECT count(*) FROM per p WHERE p.metal = lt.metal) AS batches,
               (SELECT COALESCE(sum(p.qty), 0) FROM per p WHERE p.metal = lt.metal) AS material_kg,
               (SELECT COALESCE(sum(p.metal_kg), 0) FROM per p WHERE p.metal = lt.metal) AS metal_kg,
               (SELECT count(*) FROM per p WHERE p.metal = lt.metal AND lt.price_date IS NOT NULL AND lt.price_date < p.content_on) AS price_older_than_content,
               (SELECT COALESCE(sum(m.qty), 0) FROM measured m WHERE NOT EXISTS (SELECT 1 FROM per p WHERE p.kind = m.kind AND p.id = m.id AND p.metal = lt.metal)) AS not_measured_kg,
               (SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', p.kind, 'code', p.code, 'kg', round(p.qty, 3), 'content_pct', p.content_pct,
                                                             'content_on', p.content_on, 'metal_kg', round(p.metal_kg, 3),
                                                             'price_older_than_content', lt.price_date IS NOT NULL AND lt.price_date < p.content_on)
                                          ORDER BY p.code), '[]'::jsonb) FROM per p WHERE p.metal = lt.metal) AS batch_lines
          FROM latest lt
    )
    SELECT jsonb_agg(jsonb_build_object(
               'metal', l.metal, 'state', l.state, 'price_date', l.price_date,
               'price_usd_per_tonne', CASE WHEN l.state = 'priced' THEN l.price END,
               'price_index', CASE WHEN l.state = 'priced' THEN l.price_index END,
               'price_source', CASE WHEN l.state = 'priced' THEN l.price_source END,
               'prices_on_that_date', l.n_prices,
               'batches', l.batches, 'material_kg', round(l.material_kg, 3), 'metal_kg', round(l.metal_kg, 3),
               'value_usd', CASE WHEN l.state = 'priced' THEN round(l.metal_kg / 1000 * l.price, 2) END,
               'price_older_than_content', l.price_older_than_content,
               'not_measured_kg', round(l.not_measured_kg, 3),
               'batch_lines', l.batch_lines) ORDER BY l.sort_order, l.metal),
           sum(CASE WHEN l.state = 'priced' THEN round(l.metal_kg / 1000 * l.price, 2) END),
           bool_and(l.state = 'priced' OR l.metal_kg = 0)
      INTO v_metals, v_total, v_complete
      FROM lines l;

    WITH stock AS (
        SELECT 'inbound'::text AS kind, b.id, b.code, b.unit, sum(mv.qty_delta) AS qty
          FROM inventory_movements mv JOIN inbound_batches b ON b.id = mv.inbound_batch_id
          JOIN materials m ON m.id = b.material_id JOIN material_kinds k ON k.code = m.kind_code
         WHERE b.deleted_at IS NULL AND k.may_ever_be_processed GROUP BY b.id, b.code, b.unit
        UNION ALL
        SELECT 'output'::text, b.id, b.code, b.unit, sum(mv.qty_delta)
          FROM inventory_movements mv JOIN output_batches b ON b.id = mv.output_batch_id
          JOIN materials m ON m.id = b.material_id JOIN material_kinds k ON k.code = m.kind_code
         WHERE b.deleted_at IS NULL AND k.may_ever_be_processed GROUP BY b.id, b.code, b.unit
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', s.kind, 'code', s.code, 'kg', round(s.qty, 3)) ORDER BY s.code)
                    FILTER (WHERE s.unit = 'kg' AND NOT EXISTS (SELECT 1 FROM inbound_batch_metals c JOIN substances x ON x.code = c.metal AND x.role = 'payable_metal'
                                                                  WHERE s.kind = 'inbound' AND c.inbound_batch_id = s.id)
                                              AND NOT EXISTS (SELECT 1 FROM output_batch_metals c JOIN substances x ON x.code = c.metal AND x.role = 'payable_metal'
                                                                  WHERE s.kind = 'output' AND c.output_batch_id = s.id)), '[]'::jsonb),
           COALESCE(jsonb_agg(jsonb_build_object('kind', s.kind, 'code', s.code, 'qty', round(s.qty, 3), 'unit', s.unit) ORDER BY s.code)
                    FILTER (WHERE s.unit <> 'kg'), '[]'::jsonb)
      INTO v_unmeasured, v_not_kg
      FROM stock s WHERE s.qty > 0;

    RETURN jsonb_build_object(
        'as_of', v_today,
        'metals', COALESCE(v_metals, '[]'::jsonb),
        'value_usd_priced', round(COALESCE(v_total, 0), 2),
        'complete', COALESCE(v_complete, true) AND jsonb_array_length(v_unmeasured) = 0 AND jsonb_array_length(v_not_kg) = 0,
        'not_measured', v_unmeasured,
        'not_measured_kg', (SELECT COALESCE(round(sum((x ->> 'kg')::numeric), 3), 0) FROM jsonb_array_elements(v_unmeasured) x),
        'unit_not_kg', v_not_kg);
END;
$function$;

-- db/functions/compliance_pack_data.sql
-- MES-8b-1(2026-10-17,MES-0 Q82;MES-8 Step 0 Q14 · Q15 · Q18 · Q22 · Q28,Tim):【一个日历月的合规包 —— 现算的那一份】。
--   ★ 一份实现,两个调用方:合规包页的实时预览与 freeze_compliance_pack(它把这里的返回值原样冻进 payload —— 在那里重算一遍就是第二份实现)。
--   ★ 八节(Q14),都只读这一个月、都按新加坡日期:
--     1 processing_balance   那个月的物料平衡,全厂(scope = plant)与每道工序(scope = operation)—— processing_balance_monthly_all 原样
--     2 stock_rollforward    那个月的库存滚动(期初 · 收货 · 产出 · 消耗 · 售出 · 注销 · 调整 · 作废 · 出给保养 · 移库 · 期末)—— stock_rollforward_monthly_all 原样
--     3 licence              月末那一天在效的废物处置执照(storage_licence_in_force(月末),与收货判上限同一条挑法)· 月末按 NEA 类别的在库吨数
--                            (流水 business_date ≤ 月末之和,按物料此刻的类别归类 —— nea_category_on_hand_all 的同一个口径,截到月末)与执照下每一类的上限 ·
--                            没有类别的在库吨数 · 当月每一种上限判定的次数(receipt_ceiling_checks,按 checked_on)
--     4 incidents            当月发生的事故:编号、种类、要不要通报 NEA、通报的日子、交书面报告的日子、期限与它的状态、关闭的日子 ——
--                            【不带任何受伤的细节】(谁受伤、伤情、处置、损失天数、外人的名字),也不带任何一段人写的文字(经过、处置、负责人的名字):
--                            读的是 incident_current_all,那张视图本来就不带受伤的那几列(Q14 · Q22)
--     5 environmental        当月取样的监测结果:参数、取样点、日子、数、单位、抄在结果上的限值与它的方向、判词(exceeds / within / not judged)、
--                            它开的那件事故与它更正的那一条
--     6 inspections          当月做过的巡检(编号、清单、片区、日子、合格 / 不合格 / 不适用的项数、被谁更正)与【月末】还开着的发现:
--                            巡检日在月末或之前、到月末还没有关闭的(一条发现属于它那一次巡检 —— 记下它的时刻可以晚于巡检那一天);
--                            带那一次巡检、那一项的字、纠正措施、到期日、从巡检日到月末开了几天 —— 发现里不带人名
--     7 nea_return           V26:格式与频率给了就照原样印,没给就是「NEA return — format not yet set (V26)」;【本系统不出 NEA 申报表】
--     8 eu_efficiency        V27:方法没给就是「method not yet set (V27)」,旁边放这个月的投入与各形态产出(第 1 节的同一组数)—— 不算效率(Q28)
--   ★ 不带钱:没有一个价、一笔金额、一个工资数(Q22)。不带人名。
--   ★ 门:module.compliance.view(Q17)。SECURITY DEFINER —— 它读的几张基视图刻意不给员工读(MES-5b 的平衡、MES-3a 的 NEA 在库、MES-7b 的事故现值),
--     读者只要合规的查看码就能读一份完整的包(Q17:包是以属主权限冻下来的)。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.compliance_pack_data(p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_start    date;
    v_end      date;
    v_fs       finance_settings%ROWTYPE;
    v_cs       compliance_settings%ROWTYPE;
    v_lic_id   uuid;
    v_lic      jsonb;
    v_company  jsonb;
    v_balance  jsonb;
    v_roll     jsonb;
    v_cats     jsonb;
    v_uncat    numeric;
    v_undated  bigint;
    v_checks   jsonb;
    v_inc      jsonb;
    v_env      jsonb;
    v_runs     jsonb;
    v_open     jsonb;
    v_masses   jsonb;
BEGIN
    PERFORM require_permission('module.compliance.view');
    IF p_month IS NULL THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_PERIOD_REQUIRED';
    END IF;
    v_start := date_trunc('month', p_month)::date;
    v_end   := (v_start + INTERVAL '1 month - 1 day')::date;
    SELECT * INTO v_fs FROM finance_settings;
    SELECT * INTO v_cs FROM compliance_settings WHERE id;

    SELECT jsonb_build_object('legal_name', cp.legal_name, 'registration_no', cp.registration_no, 'address_lines', cp.address_lines,
                              'city', cp.city, 'postal_code', cp.postal_code, 'country', cp.country, 'phone', cp.phone, 'email', cp.email,
                              'website', cp.website)
      INTO v_company FROM company_profile cp LIMIT 1;

    -- 1 · 物料平衡
    SELECT COALESCE(jsonb_agg(jsonb_build_object('scope', b.scope, 'operation_type_code', b.operation_type_code, 'line', b.line,
                                                 'line_key', b.line_key, 'basis', b.basis, 'qty_kg', b.qty, 'runs', b.runs)
                              ORDER BY b.scope DESC, b.operation_type_code NULLS FIRST, b.line, b.line_key NULLS FIRST, b.basis NULLS FIRST), '[]'::jsonb)
      INTO v_balance FROM processing_balance_monthly_all b WHERE b.month = v_start;

    -- 2 · 库存滚动
    SELECT COALESCE(jsonb_agg(jsonb_build_object('unit', r.unit, 'opening', r.opening, 'received', r.received, 'produced', r.produced,
                                                 'consumed', r.consumed, 'sold', r.sold, 'written_off', r.written_off, 'adjusted', r.adjusted,
                                                 'voided', r.voided, 'issued_to_maintenance', r.issued_to_maintenance, 'moved', r.moved,
                                                 'closing', r.closing) ORDER BY r.unit), '[]'::jsonb)
      INTO v_roll FROM stock_rollforward_monthly_all r WHERE r.month = v_start;

    -- 3 · 执照、月末按 NEA 类别的在库、当月的上限判定
    v_lic_id := storage_licence_in_force(v_end);
    SELECT jsonb_build_object('cert_type_code', c.cert_type_code, 'cert_no', c.cert_no, 'issuing_body', c.issuing_body, 'scope', c.scope,
                              'valid_from', c.valid_from, 'valid_until', c.valid_until, 'approved_storage_limit_tonnes', c.approved_storage_limit_tonnes)
      INTO v_lic FROM company_compliance c WHERE c.id = v_lic_id;
    WITH bal AS (
        SELECT b.material_id, b.unit, sum(mv.qty_delta) AS qty
          FROM inventory_movements mv JOIN inbound_batches b ON b.id = mv.inbound_batch_id
         WHERE mv.business_date <= v_end GROUP BY b.id, b.material_id, b.unit
        UNION ALL
        SELECT b.material_id, b.unit, sum(mv.qty_delta)
          FROM inventory_movements mv JOIN output_batches b ON b.id = mv.output_batch_id
         WHERE mv.business_date <= v_end GROUP BY b.id, b.material_id, b.unit
    ), cat AS (
        SELECT m.nea_waste_category_code AS code, count(*) AS batches, sum(quantity_in_tonnes(bal.qty, bal.unit)) AS tonnes,
               count(*) FILTER (WHERE quantity_in_tonnes(bal.qty, bal.unit) IS NULL) AS unconvertible_batches
          FROM bal JOIN materials m ON m.id = bal.material_id
         WHERE bal.qty <> 0 AND m.nea_waste_category_code IS NOT NULL GROUP BY m.nea_waste_category_code
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('category_code', k.code, 'name_en', k.name_en, 'batches', COALESCE(cat.batches, 0),
                                                 'tonnes', COALESCE(round(cat.tonnes, 3), 0), 'unconvertible_batches', COALESCE(cat.unconvertible_batches, 0),
                                                 'limit_tonnes', l.limit_tonnes,
                                                 'state', CASE WHEN v_lic_id IS NULL THEN 'licence_not_in_force' WHEN l.limit_tonnes IS NULL THEN 'ceiling_not_set'
                                                               WHEN COALESCE(cat.tonnes, 0) > l.limit_tonnes THEN 'above_ceiling' ELSE 'within_ceiling' END)
                              ORDER BY k.sort_order, k.code), '[]'::jsonb)
      INTO v_cats
      FROM nea_waste_categories k
      LEFT JOIN cat ON cat.code = k.code
      LEFT JOIN licence_storage_limits l ON l.licence_id = v_lic_id AND l.category_code = k.code
     WHERE k.is_active OR cat.code IS NOT NULL;
    WITH bal AS (
        SELECT b.material_id, b.unit, sum(mv.qty_delta) AS qty
          FROM inventory_movements mv JOIN inbound_batches b ON b.id = mv.inbound_batch_id
         WHERE mv.business_date <= v_end GROUP BY b.id, b.material_id, b.unit
        UNION ALL
        SELECT b.material_id, b.unit, sum(mv.qty_delta)
          FROM inventory_movements mv JOIN output_batches b ON b.id = mv.output_batch_id
         WHERE mv.business_date <= v_end GROUP BY b.id, b.material_id, b.unit
    )
    SELECT COALESCE(round(sum(quantity_in_tonnes(bal.qty, bal.unit)), 3), 0) INTO v_uncat
      FROM bal JOIN materials m ON m.id = bal.material_id WHERE bal.qty <> 0 AND m.nea_waste_category_code IS NULL;
    SELECT count(*) INTO v_undated FROM inventory_movements mv WHERE mv.business_date IS NULL;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('outcome', x.outcome, 'category_code', x.category_code, 'checks', x.n) ORDER BY x.outcome, x.category_code NULLS FIRST), '[]'::jsonb)
      INTO v_checks
      FROM (SELECT c.outcome, c.category_code, count(*) AS n FROM receipt_ceiling_checks c
             WHERE c.checked_on BETWEEN v_start AND v_end GROUP BY c.outcome, c.category_code) x;

    -- 4 · 事故(不带受伤的细节、不带人写的文字)
    SELECT COALESCE(jsonb_agg(jsonb_build_object('code', i.code, 'kind_code', i.kind_code, 'kind_name_en', k.name_en, 'occurred_on', i.occurred_on,
                                                 'nea_reportable', i.nea_reportable,
                                                 'notified_on', (i.notified_at AT TIME ZONE 'Asia/Singapore')::date,
                                                 'report_submitted_on', (i.report_submitted_at AT TIME ZONE 'Asia/Singapore')::date,
                                                 'report_deadline', i.report_deadline, 'deadline_state', i.deadline_state,
                                                 'closed_on', (i.closed_at AT TIME ZONE 'Asia/Singapore')::date)
                              ORDER BY i.occurred_at, i.code), '[]'::jsonb)
      INTO v_inc
      FROM incident_current_all i LEFT JOIN incident_kinds k ON k.code = i.kind_code
     WHERE i.occurred_on BETWEEN v_start AND v_end;

    -- 5 · 环境监测
    SELECT COALESCE(jsonb_agg(jsonb_build_object('parameter_code', r.parameter_code, 'parameter_name_en', p.name_en, 'sample_point', r.sample_point,
                                                 'sampled_on', r.sampled_on, 'value', r.value, 'unit', r.unit, 'limit_value', r.limit_value,
                                                 'limit_basis', r.limit_basis,
                                                 'judgement', CASE WHEN r.exceeds IS NULL THEN 'not_judged' WHEN r.exceeds THEN 'exceeds' ELSE 'within' END,
                                                 'incident_code', inc.code,
                                                 'corrects', (SELECT o.sampled_on::text || ' ' || o.parameter_code FROM environmental_results o WHERE o.id = r.corrects_result_id),
                                                 'superseded', EXISTS (SELECT 1 FROM environmental_results n WHERE n.corrects_result_id = r.id))
                              ORDER BY r.sampled_on, r.parameter_code, r.recorded_at), '[]'::jsonb)
      INTO v_env
      FROM environmental_results r
      LEFT JOIN environmental_parameters p ON p.code = r.parameter_code
      LEFT JOIN incidents inc ON inc.id = r.incident_id
     WHERE r.sampled_on BETWEEN v_start AND v_end;

    -- 6 · 巡检与月末还开着的发现
    SELECT COALESCE(jsonb_agg(jsonb_build_object('code', r.code, 'template_code', r.template_code, 'template_name', r.template_name, 'area', r.template_area,
                                                 'inspected_on', (r.inspected_at AT TIME ZONE 'Asia/Singapore')::date,
                                                 'passed', (SELECT count(*) FROM inspection_results x WHERE x.run_id = r.id AND x.result = 'pass'),
                                                 'failed', (SELECT count(*) FROM inspection_results x WHERE x.run_id = r.id AND x.result = 'fail'),
                                                 'not_applicable', (SELECT count(*) FROM inspection_results x WHERE x.run_id = r.id AND x.result = 'na'),
                                                 'corrects', (SELECT o.code FROM inspection_runs o WHERE o.id = r.corrects_run_id),
                                                 'corrected_by', (SELECT n.code FROM inspection_runs n WHERE n.corrects_run_id = r.id ORDER BY n.recorded_at LIMIT 1))
                              ORDER BY r.inspected_at, r.code), '[]'::jsonb)
      INTO v_runs
      FROM inspection_runs r
     WHERE (r.inspected_at AT TIME ZONE 'Asia/Singapore')::date BETWEEN v_start AND v_end;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('run_code', r.code, 'item', x.item_text, 'corrective_action', f.corrective_action, 'due_date', f.due_date,
                                                 'inspected_on', (r.inspected_at AT TIME ZONE 'Asia/Singapore')::date,
                                                 'days_open_at_month_end', v_end - (r.inspected_at AT TIME ZONE 'Asia/Singapore')::date)
                              ORDER BY r.inspected_at, r.code, f.recorded_at), '[]'::jsonb)
      INTO v_open
      FROM inspection_findings f JOIN inspection_runs r ON r.id = f.run_id LEFT JOIN inspection_results x ON x.id = f.result_id
     WHERE (r.inspected_at AT TIME ZONE 'Asia/Singapore')::date <= v_end
       AND NOT EXISTS (SELECT 1 FROM inspection_finding_closures c WHERE c.finding_id = f.id
                        AND (c.closed_at AT TIME ZONE 'Asia/Singapore')::date <= v_end);

    -- 8 · 第 1 节里与回收效率有关的那几个数(全厂):投入与各形态的产出
    SELECT jsonb_build_object(
               'input_kg', COALESCE((SELECT sum(b.qty) FROM processing_balance_monthly_all b WHERE b.month = v_start AND b.scope = 'plant' AND b.line = 'input'), 0),
               'outputs', COALESCE((SELECT jsonb_agg(jsonb_build_object('form', b.line_key, 'qty_kg', b.qty) ORDER BY b.line_key)
                                      FROM processing_balance_monthly_all b WHERE b.month = v_start AND b.scope = 'plant' AND b.line = 'output'), '[]'::jsonb))
      INTO v_masses;

    RETURN jsonb_build_object(
        'month', to_char(v_start, 'YYYY-MM'), 'period_start', v_start, 'period_end', v_end,
        'locked_before', v_fs.locked_before, 'month_locked', v_fs.locked_before IS NOT NULL AND v_fs.locked_before > v_end,
        'system_start_date', v_fs.system_start_date,
        'company', v_company,
        'processing_balance', v_balance,
        'stock_rollforward', v_roll,
        'licence', jsonb_build_object('in_force', v_lic, 'on_hand_by_category', v_cats, 'uncategorised_tonnes', v_uncat,
                                      'movements_without_business_date', v_undated, 'ceiling_checks', v_checks),
        'incidents', v_inc,
        'environmental', v_env,
        'inspections', jsonb_build_object('done', v_runs, 'findings_open_at_month_end', v_open),
        'nea_return', CASE WHEN v_cs.nea_return_format IS NULL OR v_cs.nea_return_frequency IS NULL
                           THEN jsonb_build_object('state', 'not_set', 'value_code', 'V26')
                           ELSE jsonb_build_object('state', 'set', 'value_code', 'V26', 'format', v_cs.nea_return_format, 'frequency', v_cs.nea_return_frequency) END,
        'eu_efficiency', CASE WHEN v_cs.eu_efficiency_method IS NULL OR v_cs.eu_efficiency_targets IS NULL
                              THEN jsonb_build_object('state', 'not_set', 'value_code', 'V27', 'masses', v_masses)
                              ELSE jsonb_build_object('state', 'set', 'value_code', 'V27', 'method', v_cs.eu_efficiency_method,
                                                      'targets', v_cs.eu_efficiency_targets, 'masses', v_masses, 'computed', false) END);
END;
$function$;

-- db/functions/freeze_compliance_pack.sql
-- MES-8b-1(2026-10-17,MES-0 Q82;MES-8 Step 0 Q15 · Q16 · Q17,Tim):【把一个【已关账】月份的合规包冻下来】—— freeze_management_pack 的形状。
--   ★ 它自己不算任何东西:payload 就是 compliance_pack_data(那个月) 的返回值(一份实现,两个调用方)。
--   ★ 只有关账的月份冻得下来(Q15):locked_before > 月末,与 PACK_MONTH_NOT_LOCKED 逐字同源 —— 按名拒并把两个日期都说出来:
--     COMPLIANCE_PACK_MONTH_NOT_LOCKED|<YYYY-MM>|<锁到>。
--   ★ 编号(Q16):CPK-YYYY-MM;同一个月已有一份在册,再冻要写理由(COMPLIANCE_PACK_SUPERSEDE_REASON_REQUIRED|<号>),
--     新的一份是 CPK-YYYY-MM-2(-3 …),旧的那一份【先】落 superseded(部分唯一索引:一个月只许一份在册),它的 payload 与存下的字节一个字不动。
--     没有在册的一份时写了理由:COMPLIANCE_PACK_REASON_WITHOUT_SUPERSEDE(一句没有对象的理由是一句假话)。
--   ★ 门(Q17):action.compliance_pack(cto · admin),它声明 module.compliance.view;payload 来自只要查看码的那一支。
--   没有作废(Q16)。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.freeze_compliance_pack(p_period_month date, p_notes text DEFAULT NULL::text, p_supersede_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_start   date;
    v_end     date;
    v_locked  date;
    v_prev    compliance_packs%ROWTYPE;
    v_reason  text := NULLIF(btrim(COALESCE(p_supersede_reason, '')), '');
    v_payload jsonb;
    v_seq     integer;
    v_code    text;
    v_id      uuid := gen_random_uuid();
BEGIN
    PERFORM require_permission('action.compliance_pack');
    PERFORM require_permission('module.compliance.view');

    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_PERIOD_REQUIRED';
    END IF;
    v_start := date_trunc('month', p_period_month)::date;
    v_end   := (v_start + INTERVAL '1 month - 1 day')::date;

    SELECT locked_before INTO v_locked FROM finance_settings;
    IF v_locked IS NULL OR v_locked <= v_end THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_MONTH_NOT_LOCKED|%|%', to_char(v_start, 'YYYY-MM'), COALESCE(v_locked::text, '—')
          USING HINT = '只有已关账的月份才冻得下来 —— 开放月份看得到实时预览,但那不是一份可以交出去的包;先在月结那一步关账';
    END IF;

    -- 同一个月的编号与在册那一份:咨询锁串行化(freeze_management_pack 的同一个手法)
    PERFORM pg_advisory_xact_lock(hashtext('compliance_pack_' || to_char(v_start, 'YYYY-MM'))::bigint);
    SELECT * INTO v_prev FROM compliance_packs WHERE period_month = v_start AND superseded_at IS NULL;
    IF FOUND AND v_reason IS NULL THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_SUPERSEDE_REASON_REQUIRED|%', v_prev.code
          USING HINT = '这个月已经有一份在册的合规包 —— 再冻一份要说明为什么(重开期间补记了什么?哪一节变了?)';
    END IF;
    IF NOT FOUND AND v_reason IS NOT NULL THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_REASON_WITHOUT_SUPERSEDE|%', to_char(v_start, 'YYYY-MM');
    END IF;

    v_payload := compliance_pack_data(v_start);

    SELECT COUNT(*) + 1 INTO v_seq FROM compliance_packs WHERE period_month = v_start;
    v_code := document_type_prefix('compliance_pack') || '-' || to_char(v_start, 'YYYY-MM') ||
              CASE WHEN v_seq > 1 THEN '-' || v_seq::text ELSE '' END;

    IF v_prev.id IS NOT NULL THEN
        UPDATE compliance_packs
           SET superseded_at = now(), superseded_by = v_id, superseded_reason = v_reason
         WHERE id = v_prev.id;
    END IF;

    INSERT INTO compliance_packs (id, code, period_month, period_start, period_end, locked_before_at_freeze, payload, notes, frozen_by)
    VALUES (v_id, v_code, v_start, v_start, v_end, v_locked, v_payload, NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid());

    RETURN jsonb_build_object('pack_id', v_id, 'code', v_code, 'period_month', v_start, 'period_end', v_end,
                              'locked_before_at_freeze', v_locked, 'superseded', v_prev.code);
END;
$function$;

-- db/functions/record_compliance_pack_issue.sql
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q16,Tim):【记下一份合规包的字节】—— PDF 已经由路由从冻下来的 payload 渲染、传进私有桶
--   compliance-documents,这里落它的路径与 sha256(compliance_pack_issues,只追加,一份包可以有好几版)。门 action.compliance_pack。
--   照分析证书那一份写:包要在(COMPLIANCE_PACK_NOT_FOUND)、没被取代(COMPLIANCE_PACK_SUPERSEDED|<号>|<理由> —— 被取代的不再交出去,
--   既有的版本仍然读得到);路径必须是 <包 id>/…(COMPLIANCE_PACK_ISSUE_PATH_INVALID|<号>);哈希必须是 64 位十六进制、一律小写存
--   (COMPLIANCE_PACK_SHA_INVALID);同一串字节在同一份包上只记一次(COMPLIANCE_PACK_BYTES_ALREADY_RECORDED|<号>|<版本>)。
--   版本由这里裁决(锁住那一行)。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.record_compliance_pack_issue(p_pack_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p    compliance_packs%ROWTYPE;
    v_sha  text := lower(btrim(COALESCE(p_sha256, '')));
    v_next integer;
    v_had  integer;
BEGIN
    PERFORM require_permission('action.compliance_pack');

    SELECT * INTO v_p FROM compliance_packs WHERE id = p_pack_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_NOT_FOUND|%', COALESCE(p_pack_id::text, '?');
    END IF;
    IF v_p.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_SUPERSEDED|%|%', v_p.code, COALESCE(v_p.superseded_reason, '');
    END IF;
    IF p_file_path IS NULL OR p_file_path NOT LIKE v_p.id::text || '/%' THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_ISSUE_PATH_INVALID|%', v_p.code;
    END IF;
    IF v_sha !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_SHA_INVALID';
    END IF;
    SELECT version INTO v_had FROM compliance_pack_issues WHERE pack_id = p_pack_id AND sha256 = v_sha;
    IF FOUND THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_BYTES_ALREADY_RECORDED|%|%', v_p.code, v_had;
    END IF;

    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next FROM compliance_pack_issues WHERE pack_id = p_pack_id;
    INSERT INTO compliance_pack_issues (pack_id, version, file_path, sha256, issued_by)
    VALUES (p_pack_id, v_next, p_file_path, v_sha, auth.uid());

    RETURN jsonb_build_object('pack_id', p_pack_id, 'code', v_p.code, 'version', v_next, 'file_path', p_file_path, 'sha256', v_sha);
END;
$function$;

-- db/functions/set_compliance_settings.sql
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q18 · Q28,Tim):【给 V26 与 V27】—— NEA 申报的格式与频率、欧盟回收效率的方法与目标(compliance_settings 那一行)。
--   门 action.compliance_pack(冻包的人;cto · admin)。每一格:空串读作"还没给"(NULL),不是一句空话;两两成对 —— 只给格式不给频率、
--   只给方法不给目标都按名拒(COMPLIANCE_SETTINGS_PAIR_INCOMPLETE|V26 / |V27):半句标准在包上会读成一句完整的。
--   给了也不算任何东西(Q28)。修改史在变更记录里。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.set_compliance_settings(p_nea_return_format text, p_nea_return_frequency text, p_eu_efficiency_method text, p_eu_efficiency_targets text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_f  text := NULLIF(btrim(COALESCE(p_nea_return_format, '')), '');
    v_q  text := NULLIF(btrim(COALESCE(p_nea_return_frequency, '')), '');
    v_m  text := NULLIF(btrim(COALESCE(p_eu_efficiency_method, '')), '');
    v_t  text := NULLIF(btrim(COALESCE(p_eu_efficiency_targets, '')), '');
BEGIN
    PERFORM require_permission('action.compliance_pack');
    IF (v_f IS NULL) <> (v_q IS NULL) THEN
        RAISE EXCEPTION 'COMPLIANCE_SETTINGS_PAIR_INCOMPLETE|V26';
    END IF;
    IF (v_m IS NULL) <> (v_t IS NULL) THEN
        RAISE EXCEPTION 'COMPLIANCE_SETTINGS_PAIR_INCOMPLETE|V27';
    END IF;
    UPDATE compliance_settings
       SET nea_return_format = v_f, nea_return_frequency = v_q, eu_efficiency_method = v_m, eu_efficiency_targets = v_t,
           updated_by = auth.uid()
     WHERE id;
    RETURN (SELECT to_jsonb(s) - 'id' FROM compliance_settings s WHERE s.id);
END;
$function$;

-- db/functions/compliance_pack_month_status.sql
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q15,Tim):【这个月的合规包冻了没有】—— 月结那一步的一行警告读它(从不挡关账,MES-0 Q48 的形状)。
--   返回 {month, locked, pack_code}:月份锁上了而没有一份在册的包 → 页面说「Compliance pack for <月>: not frozen」并指向合规包页。
--   一个"有没有"的事实,不是一份包的内容,所以门是 module.finance.view【或】module.compliance.view(月结页的读者是财务,
--   而财务不持合规的码 —— OPS-14 的 (a):借来的派生事实,属主权限 + 读者自己的模块码)。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.compliance_pack_month_status(p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_start  date;
    v_end    date;
    v_locked date;
BEGIN
    IF NOT (has_permission('module.finance.view') OR has_permission('module.compliance.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view · module.compliance.view';
    END IF;
    IF p_month IS NULL THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_PERIOD_REQUIRED';
    END IF;
    v_start := date_trunc('month', p_month)::date;
    v_end   := (v_start + INTERVAL '1 month - 1 day')::date;
    SELECT locked_before INTO v_locked FROM finance_settings;
    RETURN jsonb_build_object(
        'month', to_char(v_start, 'YYYY-MM'),
        'locked', v_locked IS NOT NULL AND v_locked > v_end,
        'pack_code', (SELECT p.code FROM compliance_packs p WHERE p.period_month = v_start AND p.superseded_at IS NULL));
END;
$function$;

-- ── 6 · 换掉的函数(镜像原样,同签名):审计主语与成员 ──────────────────────────────────────

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
-- MES-7b-2(2026-10-16,MES-7b Step 0 Q19):
--   inspection_run      → /safety/inspections/[id]            requireFunction(FN.safetyInspections) = module.safety.view。成员:结果、发现、
--                         发现的关闭(住在这里);引用一条发现的不合格报告也出现在这里(家在报告自己那里)。
--   inspection_template → /safety/inspections/templates/[id]  module.safety.view。成员:检查项(住在这里)。
--   dictionary_environmental_parameters → /settings/dictionaries 的监测参数那一段   module.safety.view
--   safety_environment  → /safety/environment(只有清单页,整张表是一条记录 —— 'collection')   module.safety.view
-- MES-8a(2026-10-16,MES-8 Step 0 Q22):
--   supplier_scorecard_review → /suppliers/scorecards(评审只有清单页 —— 'collection')   module.suppliers.view;每一家的评审也出现在
--                         那家供应商的记录上(supplier 主语的成员,家不在那里)。
--   supplier_score_settings   → /suppliers/scorecards 上的 V23 / V24 那一块   module.suppliers.view;单行设置作根(safety_settings 的先例)
--   supplier_statement        → /finance/supplier-statements/[id]   requireFunction(FN.financeSupplierStatements) = module.finance.view。
--                         成员:签发档(supplier_statement_issues,住在这里)。
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q22):
--   compliance_pack     → /compliance/packs/[id]   requireFunction(FN.compliancePacks) = module.compliance.view。成员:签发档(compliance_pack_issues,住在这里)。
--                         被谁取代是旧那一份自己那几列说的,不经 superseded_by 自连(管理包的同一个理由)。
--   compliance_settings → /compliance/packs 上的 V26 / V27 那一块   module.compliance.view;单行设置作根(supplier_score_settings 的先例)
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
        ('dictionary_incident_kinds', ARRAY['module.safety.view'], 'incident_kinds',        'code', 'collection', NULL),
        -- MES-7b-2(2026-10-16,MES-7b Step 0 Q19):一次巡检 · 一张巡检清单(安全查看码 —— 页面的门;行再过一次它自己那张表的读规则)·
        --   监测参数字典(清单块,/settings/dictionaries)· 环境监测结果(只有清单页,整张表一条记录)
        ('inspection_run',         ARRAY['module.safety.view'],    'inspection_runs',       'id', 'table', NULL),
        ('inspection_template',    ARRAY['module.safety.view'],    'inspection_templates',  'id', 'table', NULL),
        ('dictionary_environmental_parameters', ARRAY['module.safety.view'], 'environmental_parameters', 'code', 'collection', NULL),
        ('safety_environment',     ARRAY['module.safety.view'],    'environmental_results', 'id', 'collection', NULL),
        -- MES-8a(2026-10-16,MES-8 Step 0 Q22):供应商评审(只有评分卡页,整张表一条记录 —— 'collection';每一家的评审也出现在那家供应商下)·
        --   供应商评分的设定(V23 / V24,单行设置作根)· 一份供应商对账单(财务查看码;它的签发档住在这里)
        ('supplier_scorecard_review', ARRAY['module.suppliers.view'], 'supplier_scorecard_reviews', 'id', 'collection', NULL),
        ('supplier_score_settings', ARRAY['module.suppliers.view'], 'supplier_score_settings', 'id', 'table', NULL),
        ('supplier_statement',     ARRAY['module.finance.view'],   'supplier_statements',   'id', 'table', NULL),
        -- MES-8b-1(2026-10-17,MES-8 Step 0 Q22):一份合规包(合规查看码;它的签发档住在这里)· 合规包的设定(V26 / V27,单行设置作根)
        ('compliance_pack',        ARRAY['module.compliance.view'], 'compliance_packs',     'id', 'table', NULL),
        ('compliance_settings',    ARRAY['module.compliance.view'], 'compliance_settings',  'id', 'table', NULL)
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
        ('output_batch',      52, 'incident_batches',                 'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-7b-2(2026-10-16,MES-7b Step 0 Q19):一次巡检 —— 它的结果、发现与发现的关闭住在这里;引用一条发现的不合格报告也出现在这里
        --    (家在报告自己那里)。一张巡检清单 —— 它的检查项住在这里。──
        ('inspection_run',      1, 'inspection_results',               'inspection_runs',              'run_id',              '{}'::jsonb, 'down', true, true),
        ('inspection_run',      2, 'inspection_findings',              'inspection_runs',              'run_id',              '{}'::jsonb, 'down', true, true),
        ('inspection_run',      3, 'inspection_finding_closures',      'inspection_findings',          'finding_id',          '{}'::jsonb, 'down', true, true),
        ('inspection_run',      4, 'nonconformance_reports',           'inspection_findings',          'inspection_finding_id', '{}'::jsonb, 'down', true, false),
        ('inspection_template', 1, 'inspection_template_items',        'inspection_templates',         'template_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-8a(2026-10-16,MES-8 Step 0 Q22):一份供应商对账单 —— 它的签发档住在这里。一家供应商的评审也出现在它下面
        --    (家在评分卡页那条集合记录里)。──
        ('supplier_statement',  1, 'supplier_statement_issues',        'supplier_statements',          'statement_id',        '{}'::jsonb, 'down', true, true),
        ('supplier',            6, 'supplier_scorecard_reviews',       'suppliers',                    'supplier_id',         '{}'::jsonb, 'down', true, false),
        -- ── MES-8b-1(2026-10-17,MES-8 Step 0 Q22):一份合规包 —— 它的签发档住在这里。──
        ('compliance_pack',     1, 'compliance_pack_issues',           'compliance_packs',             'pack_id',             '{}'::jsonb, 'down', true, true)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- ── 7 · 视图(镜像原样):提醒 +1 支(compliance_pack_not_frozen)· 待补的值 +V26 +V27 ──

-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行
-- ★ MES-8b-1(2026-10-17,MES-8 Step 0 Q15,Tim):加一支,门 action.compliance_pack(冻包的人 —— 提醒是给能动手的人的)。
--   compliance_pack_not_frozen —— 从 system_start_date 那个月起,每一个【已关账】(月末 < locked_before)而没有一份在册合规包的月,一行。
--     item_id 空(一个月不是一行记录);item_code = YYYY-MM;subject = 'Compliance pack';item_date = 那个月的月末。冻了就消失。
--     月结页同一件事只是一行警告(compliance_pack_month_status),【从不挡关账】(MES-0 Q48 的形状)。
-- ★ MES-8a(2026-10-16,MES-8 Step 0 Q27,Tim):加一支,门 action.supplier_review(记评审的人 —— 提醒是给能动手的人的)。
--   supplier_review_due —— 一家批准过 / 在用的进货供应商,而它最近一次没被取代的评审的日子 + V23 的评审周期 ≤ 今天(doc_kind = due,
--     item_date = 那一天到期的日子),或一次评审都没有(doc_kind = never_reviewed,item_date = 建档那一天)。
--     ★【V23 的周期空着时这一支一行都不出】(Q27 —— V18 的先例:没有数,就没有提醒;不猜一个周期)。
--     item_id = 那家供应商;item_code = 供应商代码;subject = 它的名字(标签跟着单据走)。
-- ★ MES-7b-1(2026-10-16,MES-7b Step 0 Q10 · Q11,Tim):加两支,门都是 module.safety.view,都读 incident_current_all(事故现在的值:
-- ★ MES-7b-2(2026-10-16,MES-7b Step 0 Q13 · Q14 · Q20,Tim):加两支,门都是 module.safety.view。
--   inspection_due —— 一张启用的巡检清单【有频率】(V18)而该巡了:还没巡过(doc_kind = never_run,item_date = 建清单那一天),或最近一次没被
--     更正过的巡检的日子 + 频率 ≤ 今天(doc_kind = due,item_date = 那一天到期的日子)。频率空着的清单不进来 —— 没有日子可数(V18 那一行在
--     待补的值页上)。判据住在 inspection_template_due_all(清单页读同一份)。item_id = 那张清单;item_code = 清单代号;subject = 清单名字。
--   inspection_finding_open —— 一条还没关闭的巡检发现。item_id = 那条发现;doc_kind = 它那一次巡检的 id(门牌指巡检页上那一条);
--     item_code = 巡检编号;subject = 那一项的字;item_date = 记下发现的那一天(首页数它开了几天;人选的到期日在巡检页上说)。
--     关掉它那张任务不关闭它(Q14)—— 只有记一次关闭才让它消失。
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
          WHERE c.nea_reportable AND c.report_submitted_at IS NULL
        UNION ALL
         SELECT 'inspection_due'::text AS item_type,
            'module.safety.view'::text AS permission,
            t.id AS item_id,
            d.due_state AS doc_kind,
            t.code AS item_code,
            t.name AS subject,
            COALESCE(d.next_due_on, (t.created_at AT TIME ZONE 'Asia/Singapore'::text)::date) AS item_date
           FROM inspection_templates t
             JOIN inspection_template_due_all d ON d.id = t.id
          WHERE t.is_active AND d.due_state = ANY (ARRAY['due'::text, 'never_run'::text])
        UNION ALL
         SELECT 'inspection_finding_open'::text AS item_type,
            'module.safety.view'::text AS permission,
            f.id AS item_id,
            f.run_id::text AS doc_kind,
            r.code AS item_code,
            s.item_text AS subject,
            (f.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date AS item_date
           FROM inspection_findings f
             JOIN inspection_runs r ON r.id = f.run_id
             JOIN inspection_results s ON s.id = f.result_id
          WHERE NOT (EXISTS ( SELECT 1
                   FROM inspection_finding_closures c
                  WHERE c.finding_id = f.id))
        UNION ALL
         SELECT 'supplier_review_due'::text AS item_type,
            'action.supplier_review'::text AS permission,
            s.id AS item_id,
            CASE WHEN lr.recorded_at IS NULL THEN 'never_reviewed'::text ELSE 'due'::text END AS doc_kind,
            s.code AS item_code,
            s.legal_name AS subject,
            COALESCE(((lr.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date + ss.review_window_days),
                     (s.created_at AT TIME ZONE 'Asia/Singapore'::text)::date) AS item_date
           FROM suppliers s
             JOIN supplier_score_settings ss ON ss.id AND ss.review_window_days IS NOT NULL
             LEFT JOIN supplier_latest_reviews lr ON lr.supplier_id = s.id
          WHERE s.deleted_at IS NULL AND s.supplies_goods AND (s.status = ANY (ARRAY['approved'::supplier_status, 'active'::supplier_status]))
            AND (lr.recorded_at IS NULL OR ((lr.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date + ss.review_window_days) <= (now() AT TIME ZONE 'Asia/Singapore'::text)::date)
        UNION ALL
         SELECT 'compliance_pack_not_frozen'::text AS item_type,
            'action.compliance_pack'::text AS permission,
            NULL::uuid AS item_id,
            'not_frozen'::text AS doc_kind,
            to_char(m.m, 'YYYY-MM'::text) AS item_code,
            'Compliance pack'::text AS subject,
            (m.m + '1 mon -1 days'::interval)::date AS item_date
           FROM finance_settings fs
             CROSS JOIN LATERAL generate_series(date_trunc('month'::text, fs.system_start_date::timestamp without time zone), date_trunc('month'::text, fs.locked_before::timestamp without time zone), '1 mon'::interval) m(m)
          WHERE fs.system_start_date IS NOT NULL AND fs.locked_before IS NOT NULL
            AND (m.m + '1 mon'::interval)::date <= fs.locked_before
            AND NOT (EXISTS ( SELECT 1
                   FROM compliance_packs cp
                  WHERE cp.period_month = m.m::date AND cp.superseded_at IS NULL))) a
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
-- 【MES-7b-2 加两支】(2026-10-16,MES-0 §5.1 V18 · V20;MES-7b Step 0 Q13 · Q16 · Q20,Tim)—— 两支都是 module.safety.view,
--   字典是空的时各自【一行】(V29 的先例:没有东西可补的时候,也说出"还没有")。
--   V18  巡检清单的频率(天)与检查项 —— 一张启用的清单都没有时一行(去处:/safety/inspections);有了之后,每一张启用的、频率空着的清单一行
--        (去处:那张清单)。由安全工程公司 / WSH 主任给。
--   V20  每一个监测参数的排放限值 —— 参数字典一行都没有时一行(去处:/settings/dictionaries);有了之后,每一个启用的、没有限值的参数一行。
--        由 NEA 执照给。没有限值的参数照样记得进结果,读作"不判定"。
-- 【MES-8a 加两支】(2026-10-16,MES-0 §5.1 V23 · V24;MES-8 Step 0 Q4 · Q5 · Q27,Tim)—— 两支都是 module.suppliers.view,去处都是 /suppliers/scorecards。
--   V23  供应商评分的权重、等级线与评审周期 —— supplier_score_settings 那一行里三样有一样空着就一行(引导三样全空,所以从第一天起就有这一行)。
--        由 Tim 与 cco 给。没给:评审照记,读"Not graded — V23 not set";周期没给 → supplier_review_due 一行都不出。
--   V24  每一个等级的预付上限 % 与抽样级别 —— 有了等级线之后,每一个两样里缺一样的等级一行(没有等级线就没有等级,V23 先来)。由 Tim 与 cco 给。
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
          WHERE ss.id AND (ss.nea_report_working_days IS NULL OR ss.nea_report_days_confirmed_at IS NULL)
        UNION ALL
         SELECT 'V18'::text AS value_code,
            'module.safety.view'::text AS permission,
            NULL::uuid AS item_id,
            'inspection_templates'::text AS item_code,
            'Inspection checklists'::text AS item_label,
            '/safety/inspections'::text AS href
          WHERE NOT (EXISTS ( SELECT 1
                   FROM inspection_templates t
                  WHERE t.is_active))
        UNION ALL
         SELECT 'V18'::text AS value_code,
            'module.safety.view'::text AS permission,
            t.id AS item_id,
            t.code AS item_code,
            t.name AS item_label,
            '/safety/inspections/templates/'::text || t.id::text AS href
           FROM inspection_templates t
          WHERE t.is_active AND t.frequency_days IS NULL
        UNION ALL
         SELECT 'V20'::text AS value_code,
            'module.safety.view'::text AS permission,
            NULL::uuid AS item_id,
            'environmental_parameters'::text AS item_code,
            'Monitored environmental parameters'::text AS item_label,
            '/settings/dictionaries'::text AS href
          WHERE NOT (EXISTS ( SELECT 1
                   FROM environmental_parameters ep))
        UNION ALL
         SELECT 'V20'::text AS value_code,
            'module.safety.view'::text AS permission,
            NULL::uuid AS item_id,
            ep.code AS item_code,
            ep.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM environmental_parameters ep
          WHERE ep.is_active AND ep.limit_value IS NULL
        UNION ALL
         SELECT 'V23'::text AS value_code,
            'module.suppliers.view'::text AS permission,
            NULL::uuid AS item_id,
            'supplier_score_settings'::text AS item_code,
            'Supplier scorecard weights, grade lines and review window'::text AS item_label,
            '/suppliers/scorecards'::text AS href
           FROM supplier_score_settings ss
          WHERE ss.id AND (ss.weights IS NULL OR ss.grade_lines IS NULL OR ss.review_window_days IS NULL)
        UNION ALL
         SELECT 'V24'::text AS value_code,
            'module.suppliers.view'::text AS permission,
            NULL::uuid AS item_id,
            gl.value ->> 'grade'::text AS item_code,
            'Grade '::text || (gl.value ->> 'grade'::text) AS item_label,
            '/suppliers/scorecards'::text AS href
           FROM supplier_score_settings ss
             CROSS JOIN LATERAL jsonb_array_elements(ss.grade_lines) gl(value)
          WHERE ss.id AND ss.grade_lines IS NOT NULL
            AND ((((ss.grade_caps -> (gl.value ->> 'grade'::text)) ->> 'prepayment_cap_pct'::text) IS NULL)
                 OR (((ss.grade_caps -> (gl.value ->> 'grade'::text)) ->> 'sampling_level'::text) IS NULL))
        UNION ALL
         SELECT 'V26'::text AS value_code,
            'module.compliance.view'::text AS permission,
            NULL::uuid AS item_id,
            'compliance_settings'::text AS item_code,
            'NEA return format and frequency'::text AS item_label,
            '/compliance/packs'::text AS href
           FROM compliance_settings cs
          WHERE cs.id AND (cs.nea_return_format IS NULL OR cs.nea_return_frequency IS NULL)
        UNION ALL
         SELECT 'V27'::text AS value_code,
            'module.compliance.view'::text AS permission,
            NULL::uuid AS item_id,
            'compliance_settings'::text AS item_code,
            'EU recycling-efficiency method and targets'::text AS item_label,
            '/compliance/packs'::text AS href
           FROM compliance_settings cs
          WHERE cs.id AND (cs.eu_efficiency_method IS NULL OR cs.eu_efficiency_targets IS NULL)) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程);MES-3a 加 V2(执照 × 类别的库存上限)、V29(NEA 类别与物料的类别)、V3(每个安全状态的滞留提醒天数)、V4(每个安全状态要不要隔离)与 V34(隔离库位);MES-3b 加 V30(危险品编号的标记 · 包装说明 · 标签尺寸)、V31(电池料的 HS 编码)与 V35(电池料的危险品编号);MES-4a 加 V1(转化型工序的物料平衡容差)与 V36(声明了有范围的参数的上下限),并把 V6 的去处搬到班次字典(V6 同时答 V7);MES-4b 加 V10(勾了电解液挥发的工序的电解液份额)与 V11(交叉污染流的警戒线)。MES-5a-1 加 V9(物料的放电通过电压,只在那种物料有了放电结果之后才列);MES-5a-2 加 V25(共用池的电怎么摊,有共用池电表而规则为空时一行)。MES-5b-1 加 V37(每道工序 × 每种产出形态的预期质量得率;只在那道工序有了至少一张 MES-4a 之后的消耗炉次时才列 —— V9 的先例:没人能动手的行不列)。MES-6a-1 加 V16(没有合同天数的样品留多少天;只在有一份没处置、留样日 Not yet set 的样品时才列)与 V14(仲裁费怎么分;每一份有过一件开着或已结案的争议而规则为空的合同一行)。MES-6b-1 加 V17(卖方合同的质量验收限;每一份挂了销售单而口径没声明的卖方合同一行)。MES-7a-2 加 V21(备件的最低库存;每一种收过至少一批而最低库存为空的备件物料一行)。MES-7b-1 加 V19(NEA 书面报告的工作日数;空着或还没对着执照确认时一行)。MES-7b-2 加 V18(巡检清单的频率与检查项;一张启用的清单都没有时一行,之后每一张频率空着的启用清单一行)与 V20(监测参数的排放限值;字典空着时一行,之后每一个没有限值的启用参数一行)。MES-8a 加 V23(供应商评分的权重、等级线与评审周期;三样里有一样空着就一行)与 V24(每一个等级的预付上限与抽样级别;有了等级线之后,每一个缺其中一样的等级一行)。MES-8b-1 加 V26(NEA 申报的格式与频率)与 V27(欧盟回收效率的方法与目标)—— 两支都是从第一天起就一行(合规包的设定一行、全空),读 module.compliance.view。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- ── 8 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.compliance_settings
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.compliance_settings
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.compliance_packs
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.compliance_packs
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.compliance_pack_issues
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.compliance_pack_issues
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 9 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.inbound_batch_margin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inbound_batch_margin(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.inventory_metal_exposure() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inventory_metal_exposure() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.compliance_pack_data(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.compliance_pack_data(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.freeze_compliance_pack(date, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.freeze_compliance_pack(date, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_compliance_pack_issue(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_compliance_pack_issue(uuid, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.set_compliance_settings(text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_compliance_settings(text, text, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.compliance_pack_month_status(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.compliance_pack_month_status(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_compliance_pack_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_compliance_pack_write() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_compliance_pack_issue_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_compliance_pack_issue_write() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_compliance_pack_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_compliance_pack_issue_write() FROM authenticated;

-- ── 10 · 私有桶 compliance-documents 与它的三条策略(桶不在镜像里 —— AGENTS.md;它的证明是
--   db/scripts/2026-10-17-mes8b1-live-proof.mjs 的 PDF 一段)。只收 PDF、≤ 10 MB。读:module.compliance.view(合规包的读码)。
--   传:action.compliance_pack(存档的那一个码)。删:action.compliance_pack【并且】那个对象还没被记进 compliance_pack_issues —— 记哈希失败留下的孤儿
--   可以由存档的人清掉;记下了的字节谁都删不掉。改:一条策略都不给(覆盖一份已存的字节,就是改一份交出去过的包)。
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('compliance-documents', 'compliance-documents', false, 10485760, ARRAY['application/pdf'])
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "compliance-documents read by compliance view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'compliance-documents'::text AND public.has_permission('module.compliance.view'::text));

CREATE POLICY "compliance-documents upload by compliance pack"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'compliance-documents'::text AND public.has_permission('action.compliance_pack'::text));

CREATE POLICY "compliance-documents remove unrecorded by compliance pack"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'compliance-documents'::text AND public.has_permission('action.compliance_pack'::text)
           AND NOT EXISTS (SELECT 1 FROM public.compliance_pack_issues i WHERE i.file_path = objects.name));

-- ── 11 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes8b1_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes8b1_pending_after ON COMMIT DROP AS
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
    -- ① 授权:恰好多了那八行;目录 84 个码,admin 持每一个;持动作码的角色也持它声明的查看码
    IF (SELECT count(*) FROM permissions) <> 84
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|admin does not hold every one of the 84 codes';
    END IF;
    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v_bad FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code = 'module.compliance.view';
    IF v_bad IS DISTINCT FROM 'admin,auditor,cco,cfo,cto,gm' THEN
        RAISE EXCEPTION 'MES8B1_PROOF|module.compliance.view is held by % (ruled: admin,auditor,cco,cfo,cto,gm)', COALESCE(v_bad, '<nobody>');
    END IF;
    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v_bad FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code = 'action.compliance_pack';
    IF v_bad IS DISTINCT FROM 'admin,cto' THEN
        RAISE EXCEPTION 'MES8B1_PROOF|action.compliance_pack is held by % (ruled: admin,cto)', COALESCE(v_bad, '<nobody>');
    END IF;
    IF (SELECT requires_view_any FROM permissions WHERE code = 'action.compliance_pack') IS DISTINCT FROM ARRAY['module.compliance.view'] THEN
        RAISE EXCEPTION 'MES8B1_PROOF|action.compliance_pack must declare module.compliance.view';
    END IF;
    SELECT string_agg(r.code || ':' || p.code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'MES8B1_PROOF|an action code is held without its declared view: %', v_bad;
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES8B1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes8b1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes8b1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变;两张 COD 的存储对象一个字节不动
    IF EXISTS ((SELECT b.k, b.id FROM mes8b1_pending_before b EXCEPT SELECT a.k, a.id FROM mes8b1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes8b1_pending_after a EXCEPT SELECT b.k, b.id FROM mes8b1_pending_before b)) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t ) IS DISTINCT FROM (SELECT inbound_batches FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t ) IS DISTINCT FROM (SELECT output_batches FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inventory_movements t ) IS DISTINCT FROM (SELECT inventory_movements FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_runs t ) IS DISTINCT FROM (SELECT processing_runs FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_inputs t ) IS DISTINCT FROM (SELECT processing_inputs FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_outputs t ) IS DISTINCT FROM (SELECT processing_outputs FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_records t ) IS DISTINCT FROM (SELECT sales_records FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_settlements t ) IS DISTINCT FROM (SELECT sales_settlements FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM metal_prices t ) IS DISTINCT FROM (SELECT metal_prices FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM metal_price_indices t ) IS DISTINCT FROM (SELECT metal_price_indices FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batch_metals t ) IS DISTINCT FROM (SELECT inbound_batch_metals FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batch_metals t ) IS DISTINCT FROM (SELECT output_batch_metals FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM substances t ) IS DISTINCT FROM (SELECT substances FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM materials t ) IS DISTINCT FROM (SELECT materials FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM material_kinds t ) IS DISTINCT FROM (SELECT material_kinds FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) IS DISTINCT FROM (SELECT journal_entries FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) IS DISTINCT FROM (SELECT journal_lines FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) IS DISTINCT FROM (SELECT payments FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_allocations t ) IS DISTINCT FROM (SELECT payment_allocations FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) IS DISTINCT FROM (SELECT expenses FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t ) IS DISTINCT FROM (SELECT suppliers FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM purchase_orders t ) IS DISTINCT FROM (SELECT purchase_orders FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM customers t ) IS DISTINCT FROM (SELECT customers FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM company_compliance t ) IS DISTINCT FROM (SELECT company_compliance FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM licence_storage_limits t ) IS DISTINCT FROM (SELECT licence_storage_limits FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM nea_waste_categories t ) IS DISTINCT FROM (SELECT nea_waste_categories FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM receipt_ceiling_checks t ) IS DISTINCT FROM (SELECT receipt_ceiling_checks FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM incidents t ) IS DISTINCT FROM (SELECT incidents FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM incident_updates t ) IS DISTINCT FROM (SELECT incident_updates FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM environmental_results t ) IS DISTINCT FROM (SELECT environmental_results FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM environmental_parameters t ) IS DISTINCT FROM (SELECT environmental_parameters FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_templates t ) IS DISTINCT FROM (SELECT inspection_templates FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_runs t ) IS DISTINCT FROM (SELECT inspection_runs FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_results t ) IS DISTINCT FROM (SELECT inspection_results FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_findings t ) IS DISTINCT FROM (SELECT inspection_findings FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inspection_finding_closures t ) IS DISTINCT FROM (SELECT inspection_finding_closures FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM management_packs t ) IS DISTINCT FROM (SELECT management_packs FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM company_profile t ) IS DISTINCT FROM (SELECT company_profile FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_statements t ) IS DISTINCT FROM (SELECT supplier_statements FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_statement_issues t ) IS DISTINCT FROM (SELECT supplier_statement_issues FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t ) IS DISTINCT FROM (SELECT certificates_of_destruction FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) IS DISTINCT FROM (SELECT cod_issues FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_analysis t ) IS DISTINCT FROM (SELECT certificates_of_analysis FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM coa_issues t ) IS DISTINCT FROM (SELECT coa_issues FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM customer_statements t ) IS DISTINCT FROM (SELECT customer_statements FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM statement_issues t ) IS DISTINCT FROM (SELECT statement_issues FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) IS DISTINCT FROM (SELECT approval_log FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM accounts t ) IS DISTINCT FROM (SELECT accounts FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t ) IS DISTINCT FROM (SELECT employees FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM tasks t ) IS DISTINCT FROM (SELECT tasks FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t WHERE code NOT IN ('module.compliance.view', 'action.compliance_pack')) IS DISTINCT FROM (SELECT permissions FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t WHERE permission_code NOT IN ('module.compliance.view', 'action.compliance_pack')) IS DISTINCT FROM (SELECT role_permissions FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) IS DISTINCT FROM (SELECT roles FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) IS DISTINCT FROM (SELECT user_roles FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t WHERE key <> 'compliance_pack') IS DISTINCT FROM (SELECT document_types FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) IS DISTINCT FROM (SELECT ingest_settings FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) IS DISTINCT FROM (SELECT finance_settings FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM safety_settings t ) IS DISTINCT FROM (SELECT safety_settings FROM mes8b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_score_settings t ) IS DISTINCT FROM (SELECT supplier_score_settings FROM mes8b1_rows_before) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|a pre-existing row changed';
    END IF;
    IF EXISTS ((SELECT name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects WHERE bucket_id = 'cod-documents'
                EXCEPT SELECT name, size, etag FROM mes8b1_cod_objects_before)
               UNION ALL
               (SELECT name, size, etag FROM mes8b1_cod_objects_before
                EXCEPT SELECT name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects WHERE bucket_id = 'cod-documents')) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|a COD object changed';
    END IF;

    -- ④ 包与签发档一行都没有;设定那一行在、四样全空
    IF EXISTS (SELECT 1 FROM compliance_packs) OR EXISTS (SELECT 1 FROM compliance_pack_issues) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|no pack or issue may be created';
    END IF;
    IF (SELECT count(*) FROM compliance_settings) <> 1
       OR EXISTS (SELECT 1 FROM compliance_settings WHERE nea_return_format IS NOT NULL OR nea_return_frequency IS NOT NULL
                                                       OR eu_efficiency_method IS NOT NULL OR eu_efficiency_targets IS NOT NULL) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|the settings row must exist with V26 and V27 empty (Q18: nothing is guessed)';
    END IF;

    -- ⑤ 本事务往变更记录只写了:目录两行(+ 动作码的查看码)、八行授权、单据登记一行(按 txid 认)
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes8b1_log_before), 0) AND c.txid = txid_current()
       AND NOT ((c.op = 'INSERT' AND c.table_name IN ('permissions', 'role_permissions', 'document_types', 'compliance_settings'))
                OR (c.op = 'UPDATE' AND c.table_name = 'permissions'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES8B1_PROOF|unexpected change_log rows: %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes8b1_log_before), 0) AND c.txid = txid_current()
          AND c.table_name = 'role_permissions') <> 8 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|expected exactly 8 role_permissions rows written';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES8B1_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑥ 结构:守卫在;单据登记 63 行,CPK 一行;320 张表;审计主语在册
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_compliance_packs_write' AND tgrelid = 'public.compliance_packs'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_compliance_pack_issues_append_only' AND tgrelid = 'public.compliance_pack_issues'::regclass) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|a guard trigger is missing';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 63 OR document_type_prefix('compliance_pack') <> 'CPK' THEN
        RAISE EXCEPTION 'MES8B1_PROOF|document_types should be 63 with CPK';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 320 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|expected 320 public tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'compliance_pack' AND s.view_codes = ARRAY['module.compliance.view'])
       OR NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'compliance_settings')
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'compliance_pack' AND m.table_name = 'compliance_pack_issues' AND m.home) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|the compliance trail subjects or members are missing';
    END IF;

    -- ⑦ 匿名面与函数面
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES8B1_PROOF|anon executes: %', v_bad;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.inbound_batch_margin(uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.inbound_batch_margin(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.inbound_batch_margin(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B1_PROOF|public.inbound_batch_margin(uuid): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.inventory_metal_exposure()'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.inventory_metal_exposure()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.inventory_metal_exposure()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B1_PROOF|public.inventory_metal_exposure(): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.compliance_pack_data(date)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.compliance_pack_data(date)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.compliance_pack_data(date)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B1_PROOF|public.compliance_pack_data(date): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.freeze_compliance_pack(date, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.freeze_compliance_pack(date, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.freeze_compliance_pack(date, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B1_PROOF|public.freeze_compliance_pack(date, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_compliance_pack_issue(uuid, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_compliance_pack_issue(uuid, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_compliance_pack_issue(uuid, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B1_PROOF|public.record_compliance_pack_issue(uuid, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.set_compliance_settings(text, text, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.set_compliance_settings(text, text, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.set_compliance_settings(text, text, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B1_PROOF|public.set_compliance_settings(text, text, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.compliance_pack_month_status(date)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.compliance_pack_month_status(date)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.compliance_pack_month_status(date)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B1_PROOF|public.compliance_pack_month_status(date): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_compliance_pack_write()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_compliance_pack_write()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B1_PROOF|public.guard_compliance_pack_write() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_compliance_pack_issue_write()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_compliance_pack_issue_write()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B1_PROOF|public.guard_compliance_pack_issue_write() must be a function nobody outside can call';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('compliance_settings', 'compliance_packs', 'compliance_pack_issues')
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES8B1_PROOF|anon can read %', v_bad; END IF;

    -- ⑧ 那 44 条开着的读策略还是 44 条
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|the open read policies are no longer 44';
    END IF;

    -- ⑨ 变更记录:覆盖零缺口(三张新表记,豁免仍是 8);遮蔽零缺口(规则仍 119 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 119 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑩ 提醒臂 72(compliance_pack_not_frozen 一行都不出 —— 没有一个已关账的月)、待补的值 33 支(V26 · V27 各一行)
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 72
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 33 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|reminder arms 72 / pending-value arms 33 expected';
    END IF;
    IF (SELECT locked_before FROM finance_settings) > (SELECT system_start_date FROM finance_settings) THEN
        RAISE NOTICE 'MES8B1 a month is locked on live — compliance_pack_not_frozen will list it';
    END IF;

    -- ⑪ F16:没有一张视图对 anon / authenticated 带写授权
    v_n := (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
             OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE')));
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑫ 桶:私有、空、三条策略
    IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'compliance-documents' AND NOT public)
       OR EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'compliance-documents')
       OR (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
             AND policyname LIKE 'compliance-documents %') <> 3 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|bucket compliance-documents must exist, be private, be empty and carry exactly three policies';
    END IF;

    -- ⑬ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes8b1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES8B1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes8b1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes8b1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
