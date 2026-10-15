-- db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql
-- MES-6b-2 —— 分析证书(CoA)、产出批的来料化学确定度(N38)、作废分析证书的 CFO 申请(MES 组的第十五刀,v1.4.51;
--   发布那一行在 docs/handbacks/MES-6b-2.md 的抬头)。由 db/scripts/build_mes6b2_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-15:MES-6b Step 0 的 Q10–Q14 · Q17 · Q20 · Q29–Q32 · Q38–Q42 照推荐裁定;Q13:证书印「Issued by <名字>, <职位>」
--   与签发时刻,不放签名图片)
--   ① certificates_of_analysis(COA-YYYY-NNNN,按年无洞,签发那一刻铸):一批产出批,可选地点名一张预留过或发过它的销售单;一批 × 一张单同时
--      只有一张活证书;说话的那一份化验(结案争议点名的 → 点了单就合同约定那一方最新的 → 我们最新的,必须 is_final;成分读那一份化验自己的行,
--      从不读 output_batch_metals);快照由库组装一次(coa_assemble),签发之后只许作废、作废之后只许填一次替代品(guard_coa_mutation)。
--      coa_issues:字节的路径与 sha256(只追加);字节在私有桶 coa-documents。
--   ② issue_coa(action.issue_coa):拒绝清单 coa_issue_blockers 的第一句原样拒 —— 没有最终化验 · 质量暂扣 · 开着的争议 · 产出腿称重不在校准期内 ·
--      点名的单越限而报告没被接受 · 单不是这一批的 · 已有活证书 · 公司名没录;签发人不是员工 / 没有职位另拒。coa_certificate_data
--      (module.output.view)是同一份组装的预览外加拒绝清单。record_coa_issue 记字节。
--   ③ N38:output_batch_chemistry_certainty(属主权限,谓词 = 产出批的读策略)读无判据基视图 _all:进料叶子上最弱的那一个。
--   ④ 作废(Q20 · Q32):warehouse_requests 多一种 coa_void(主体列 coa_id,ALTER 加在末尾,列权限与遮蔽伴生视图同一支迁移里加上),
--      submit_coa_void_request(action.issue_coa)→ CFO 二级批准 → void_coa_internal;没有一步作废的门。重开一张时 issue_coa 链上 replaced_by_coa_id。
--   ⑤ 提醒 coa_facts_changed(action.issue_coa)· 审计主语 coa(两个批次主语下都挂着证书)· 单据登记 COA · 两张新表进变更记录(豁免仍是 8;
--      没有遮蔽的列)· action.issue_coa 进目录、声明 module.output.view 与 module.quality.view,授 cco · admin · 私有桶 coa-documents 与三条策略
--      (读:module.output.view;传:action.issue_coa;删:action.issue_coa 且那个对象还没被记进 coa_issues —— 签发时记哈希失败的孤儿;改:没有)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;授权只多 action.issue_coa 那两行;不写、不改任何一张既有单据、批次、化验、争议、报告、
--   证书、申请、合同、销售单、流水;不建任何分析证书或申请;不往桶里放任何对象;require_calibrated_since 保持空。线上由本迁移造出的只有:
--   两张空表、warehouse_requests 的 coa_id 那一列(全空)、一个权限码与它的两条授权、单据登记 COA 那一行、一个空的私有桶与它的三条策略。
--
-- 【破窗】新表、新视图、新函数旧应用一样都不读;warehouse_requests 的 kind 多一个取值、多一列(全空)—— 旧应用照旧读它认得的四种;
--   旧的提醒页按它自己的清单画牌子,coa_facts_changed 被跳过(线上零张证书,它也是空的)。窗口里什么都不坏;窗口 ≈ 部署时长。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了 action.issue_coa 的两行,admin 持目录里每一个码(79);在途单据一张不少、
--   一张不多,每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的申请、批次、化验、争议、报告、销毁证书、加工单、销售单、预留、
--   合同、流水、称重、校准、公司资料、员工、职位、客户、审批留痕、分录、付款、费用单、开票与定价申请逐字未变;两张新表零行;桶空;
--   变更记录只多了本刀种的那几行;五支对外的函数员工调得到、六支内层与触发器调不到;anon 能执行的【恰好】两支;那 44 条开着的读策略还是 44 条;
--   变更记录覆盖与遮蔽零缺口(豁免 8、规则 114);单据登记 59 行、豁免 45 行;提醒 66 支、待定值 23 行;297 张表。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES6B2_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.certificates_of_analysis') IS NOT NULL OR to_regclass('public.coa_issues') IS NOT NULL
       OR to_regclass('public.coa_rows') IS NOT NULL OR to_regclass('public.output_batch_chemistry_certainty') IS NOT NULL
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'warehouse_requests'
                    AND column_name = 'coa_id')
       OR EXISTS (SELECT 1 FROM permissions WHERE code = 'action.issue_coa')
       OR EXISTS (SELECT 1 FROM document_types WHERE key = 'coa' OR prefix = 'COA')
       OR to_regprocedure('public.issue_coa(uuid, uuid)') IS NOT NULL
       OR EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'coa-documents') THEN
        RAISE EXCEPTION 'MES6B2_PRE|MES-6b-2 objects already exist';
    END IF;
    IF (SELECT count(*) FROM roles WHERE code IN ('admin', 'cco')) <> 2 THEN
        RAISE EXCEPTION 'MES6B2_PRE|expected the admin and cco roles';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES6B2_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 78
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES6B2_PRE|expected a catalogue of 78 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 58 OR (SELECT count(*) FROM document_type_exceptions) <> 45 THEN
        RAISE EXCEPTION 'MES6B2_PRE|expected 58 document types and 45 exceptions';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 65 THEN
        RAISE EXCEPTION 'MES6B2_PRE|operations_now should have 65 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 23 THEN
        RAISE EXCEPTION 'MES6B2_PRE|pending_values should have 23 arms';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES6B2_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES6B2_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 295 THEN
        RAISE EXCEPTION 'MES6B2_PRE|expected 295 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6B2_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes6b2_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes6b2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes6b2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes6b2_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes6b2_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'coa_id')::text, '|' ORDER BY (to_jsonb(t) - 'coa_id')::text), '')) FROM warehouse_requests t) AS warehouse_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t) AS output_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t) AS inbound_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_results t) AS assay_results,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_result_metals t) AS assay_result_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_result_indicators t) AS assay_result_indicators,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batch_metals t) AS output_batch_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_disputes t) AS assay_disputes,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM nonconformance_reports t) AS nonconformance_reports,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM quality_limit_judgements t) AS quality_limit_judgements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t) AS certificates_of_destruction,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t) AS cod_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_runs t) AS processing_runs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_inputs t) AS processing_inputs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_outputs t) AS processing_outputs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_orders t) AS sales_orders,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_order_lines t) AS sales_order_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_order_reservations t) AS sales_order_reservations,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM shipment_lines t) AS shipment_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contracts t) AS contracts,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_settlement_terms t) AS contract_settlement_terms,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_document_terms t) AS contract_document_terms,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inventory_movements t) AS inventory_movements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM weighings t) AS weighings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM instrument_calibrations t) AS instrument_calibrations,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM company_profile t) AS company_profile,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t) AS employees,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM positions t) AS positions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM customers t) AS customers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t) AS approval_log,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM invoice_requests t) AS invoice_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM receipt_price_requests t) AS receipt_price_requests;

-- ── 1 · 新函数(镜像原样),先于新表的两支:取号 · 证书的变更守卫(新表的触发器要它)───

-- db/functions/next_coa_code.sql
-- MES-6b-2(2026-10-15,MES-0 Q53 · MES-6b Step 0 Q30):分析证书的编号 COA-YYYY-NNNN —— 按年、无洞,与 next_ncr_code 逐行同形
--   (自己的一把 advisory lock;MAX(split_part)+1 带 LIKE 过滤;前缀从 document_types 读)。号在签发那一刻铸(issue_coa)。
--   ★ 宽度 GREATEST(4, 位数)(CODE-WIDTH-4)。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.next_coa_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】COA 与 NCR / SMP 各自连号 —— 共用一把会让一种单据烧掉另一种的号。
    PERFORM pg_advisory_xact_lock(hashtext('coa_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM certificates_of_analysis
    WHERE code LIKE document_type_prefix('coa') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('coa') || '-' || v_year::text || '-' || LPAD(v_seq::text, GREATEST(4, length(v_seq::text)), '0');
END;
$function$;

-- db/functions/guard_coa_mutation.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q31 · Q32):分析证书【签发之后内容一个字都不许改】(trg_certificates_of_analysis_mutation,BEFORE UPDATE OR DELETE)。
--   允许的只有两次改动,都由函数做:
--     ① issued → void(void_coa_internal):只动 status · void_reason · voided_at · voided_by;
--     ② 一张已作废、还没有替代品的证书,填一次 replaced_by_coa_id(issue_coa 签发它的下一张时)。
--   其余 —— 号、批、单、说话的化验、快照、签发时刻与人、作废之后再改回来、替代品改第二次 —— 一律按名拒 COA_ISSUED_IMMUTABLE|<号>;
--   作废不可逆 COA_ALREADY_VOID|<号>;删 COA_NO_DELETE|<号>。属主路径同样受它管 —— 它守的是档案的形状,不是权限。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.guard_coa_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'COA_NO_DELETE|%', OLD.code;
    END IF;
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.code IS DISTINCT FROM OLD.code
       OR NEW.output_batch_id IS DISTINCT FROM OLD.output_batch_id
       OR NEW.sales_order_id IS DISTINCT FROM OLD.sales_order_id
       OR NEW.governing_assay_id IS DISTINCT FROM OLD.governing_assay_id
       OR NEW.issued_at IS DISTINCT FROM OLD.issued_at
       OR NEW.issued_by IS DISTINCT FROM OLD.issued_by
       OR NEW.snapshot IS DISTINCT FROM OLD.snapshot
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'COA_ISSUED_IMMUTABLE|%', OLD.code;
    END IF;
    IF OLD.status = 'void' THEN
        IF NEW.status <> 'void' THEN
            RAISE EXCEPTION 'COA_ALREADY_VOID|%', OLD.code;
        END IF;
        -- 作废之后:作废那几列冻住;替代品只许从空填一次
        IF NEW.void_reason IS DISTINCT FROM OLD.void_reason OR NEW.voided_at IS DISTINCT FROM OLD.voided_at
           OR NEW.voided_by IS DISTINCT FROM OLD.voided_by
           OR (OLD.replaced_by_coa_id IS NOT NULL AND NEW.replaced_by_coa_id IS DISTINCT FROM OLD.replaced_by_coa_id) THEN
            RAISE EXCEPTION 'COA_ISSUED_IMMUTABLE|%', OLD.code;
        END IF;
        RETURN NEW;
    END IF;
    -- OLD.status = 'issued':只许 → void(替代品在作废之后才有)
    IF NEW.replaced_by_coa_id IS NOT NULL THEN
        RAISE EXCEPTION 'COA_ISSUED_IMMUTABLE|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 2 · 新表(镜像原样):分析证书 · 它的字节档案(外键次序)─────────────────────────────────────────────

-- db/tables/certificates_of_analysis.sql
-- MES-6b-2(2026-10-15,MES-0 功能 18 · Q53 · Q67 · Q68 · Q89 · Q90;MES-6b Step 0 Q10–Q14 · Q29–Q32,Tim):【一张分析证书(CoA)】——
--   交给买方的那张纸:这一批产出是什么成分、谁测的、按哪一份结果说话、来料的化学有多确定。
--
--   【主体】恰好一批产出批;可选地点名一张销售单(Q10)—— 点名了,纸上多出那张单所挂合同的 V17 验收限与判定、以及客户的名字。
--     销售单必须是预留过或发过这一批的那几张之一(COA_SALES_ORDER_NOT_FOR_BATCH)。
--     【一批 × 一张单(或不点名)同时只有一张活证书】(uq_coa_live_per_batch_order);作废的留着。
--   【号在签发那一刻铸】COA-YYYY-NNNN,按年无洞(next_coa_code;document_types 的 'coa';宽度 GREATEST(4, 位数))。没有 pending 状态 ——
--     一张证书生下来就是签发了的(与 COD 不同:COD 由判据自己成立、等人签发;CoA 是人在那一刻要一张)。
--   【说话的那一份化验】governing_assay_id(Q11):结案争议点名的那一份;否则点名了单 → 那张单的合同约定那一方最新一份活的;否则我们最新一份活的。
--     它必须 is_final。纸上的成分读【那一份化验自己的行】(assay_result_metals / assay_result_indicators),【从不读 output_batch_metals】。
--   【快照】snapshot:签发那一刻纸上每一个值,由库组装一次(coa_assemble)。PDF 只从它渲染;字节存进私有桶 coa-documents,
--     哈希在 coa_issues(Q31)。读取路径【不许】拿快照里的 id 回查内容(与 certificates_of_destruction.snapshot 同一条)。
--   【作废】只经 CFO 申请(warehouse_requests 的 coa_void,二级,不分档;Q20 · Q32):行留着,快照与字节一个字不动;
--     重开一张是一个新号,作废的那一张 replaced_by_coa_id 指向它。【永远不会被自动作废】—— 事实变了只在提醒 coa_facts_changed 里说。
--   【读】跟着那一批的查看码(module.output.view,Q30)。写:一条策略都不给 —— 只经 issue_coa / void_coa_internal。
--   【没有金额】—— 没有遮蔽的列(Q39)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.certificates_of_analysis (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                text NOT NULL UNIQUE,
    output_batch_id     uuid NOT NULL REFERENCES public.output_batches (id),
    -- 可选:点名的那一张销售单(Q10)
    sales_order_id      uuid REFERENCES public.sales_orders (id),
    -- 说话的那一份化验(Q11)—— 签发那一刻选定,冻住
    governing_assay_id  uuid NOT NULL REFERENCES public.assay_results (id),
    status              text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued', 'void')),
    issued_at           timestamptz NOT NULL,
    issued_by           uuid NOT NULL,
    -- 签发那一刻纸上的每一个值(由库组装一次)
    snapshot            jsonb NOT NULL,
    void_reason         text,
    voided_at           timestamptz,
    voided_by           uuid,
    -- 作废之后顶上来的那一张(同一批 × 同一张单的下一张证书,签发时由 issue_coa 填)
    replaced_by_coa_id  uuid REFERENCES public.certificates_of_analysis (id),
    created_at          timestamptz NOT NULL DEFAULT now(),
    -- 作废必须有理由、时刻与人 —— 与 cod_void_has_reason 同一条
    CONSTRAINT certificates_of_analysis_void_shape CHECK (
        (status = 'void') = (voided_at IS NOT NULL)
        AND (voided_at IS NULL) = (voided_by IS NULL)
        AND (status <> 'void' OR (void_reason IS NOT NULL AND btrim(void_reason) <> ''))),
    -- 只有作废的那一张才有替代品,而且不是它自己
    CONSTRAINT certificates_of_analysis_replacement_shape CHECK (
        replaced_by_coa_id IS NULL OR (status = 'void' AND replaced_by_coa_id <> id))
);

-- 【一批 × 一张单(或不点名)同时只有一张活证书】作废掉的留着 —— 买方手里那张纸要查得到。
CREATE UNIQUE INDEX uq_coa_live_per_batch_order
    ON public.certificates_of_analysis (output_batch_id, COALESCE(sales_order_id, '00000000-0000-0000-0000-000000000000'::uuid))
    WHERE status <> 'void';
CREATE INDEX certificates_of_analysis_output_batch_id_rel ON public.certificates_of_analysis (output_batch_id);
CREATE INDEX certificates_of_analysis_sales_order_id_rel ON public.certificates_of_analysis (sales_order_id);
CREATE INDEX certificates_of_analysis_governing_assay_id_rel ON public.certificates_of_analysis (governing_assay_id);
CREATE INDEX certificates_of_analysis_replaced_by_coa_id_rel ON public.certificates_of_analysis (replaced_by_coa_id);
-- 搜索:code 的后缀匹配(与 nonconformance_reports 同一条)
CREATE INDEX certificates_of_analysis_code_trgm ON public.certificates_of_analysis USING gin (code extensions.gin_trgm_ops);

COMMENT ON TABLE public.certificates_of_analysis IS
    'MES-6b-2:一张分析证书(COA-YYYY-NNNN)—— 恰好一批产出批,可选地点名一张预留过或发过它的销售单(点名了就多出合同的 V17 验收限、判定与客户名)。一批 × 一张单同时只有一张活证书。号在签发那一刻铸,没有 pending。说话的那一份化验(governing_assay_id)是结案争议点名的那一份,否则合同约定那一方(点名了单)或我们最新一份活的结果,必须 is_final;成分读那一份化验自己的行,从不读批次含量。快照由库组装一次,PDF 只从快照渲染,字节在私有桶 coa-documents、哈希在 coa_issues。作废只经 CFO 申请(warehouse_requests 的 coa_void),行、快照与字节都留着;重开一张是新号,旧的 replaced_by_coa_id 指向它;永远不会被自动作废。读跟着那一批的查看码。没有金额。';
COMMENT ON COLUMN public.certificates_of_analysis.snapshot IS
    'MES-6b-2(Q31):签发那一刻纸上每一个值的副本 —— 公司、批次、说话的那一份化验与它的成分 / 指标、来料化学确定度(N38)、点名的单与合同的验收限 / 判定 / 客户名、签发人(名字与职位)与签发时刻。由 coa_assemble 组装一次;PDF 只从它渲染。里面的 *_id 只回答"这来自哪一行",【任何读取路径都不许拿它回查内容】。';
COMMENT ON COLUMN public.certificates_of_analysis.governing_assay_id IS
    'MES-6b-2(Q11):纸上说话的那一份化验 —— 结案争议点名的那一份(最近结案的那一件);否则点名了销售单 → 那张单所挂合同约定那一方最新一份没删的结果;否则我们(ours)最新一份没删的结果。必须 is_final(COA_NO_FINAL_ASSAY)。签发那一刻选定,冻住。';

ALTER TABLE public.certificates_of_analysis ENABLE ROW LEVEL SECURITY;
-- 读:跟着那一批的查看码(Q30)。写:一条策略都不给 —— 只经 issue_coa / void_coa_internal(SECURITY DEFINER)。
CREATE POLICY "certificates_of_analysis select by permission" ON public.certificates_of_analysis
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.output.view'::text));
GRANT SELECT ON public.certificates_of_analysis TO authenticated;
REVOKE ALL ON public.certificates_of_analysis FROM anon;

-- 【签发之后内容一个字都不许改 —— 只许作废,作废之后只许填一次替代品】;不许删、不许清空。属主路径同样受它管。
CREATE TRIGGER trg_certificates_of_analysis_mutation
    BEFORE UPDATE OR DELETE ON public.certificates_of_analysis
    FOR EACH ROW EXECUTE FUNCTION public.guard_coa_mutation();
CREATE TRIGGER trg_certificates_of_analysis_truncate
    BEFORE TRUNCATE ON public.certificates_of_analysis
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

-- db/tables/coa_issues.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q31,Tim):分析证书的字节档案 —— *_issues 那一族的第十份,形状取自 cod_issues。
--   * 【没有 version】数据变了就作废旧的、发一张新号的,所以永远没有第二版(与 cod_issues 同一条);
--   * 只追加(改、删、清空一律语句级拒 APPEND_ONLY),唯一写入口是 record_coa_issue();
--   * 作废【不动本表】—— 买方手里那份仍然对得上哈希;
--   * 字节在私有桶 coa-documents,键 <证书 id>/<随机 id>.pdf(record_coa_issue 核对前缀);GET ?coa= 流出存下的字节并重算 sha256,
--     对不上就 409。
--   * 读跟着证书(module.output.view)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.coa_issues (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    coa_id     uuid NOT NULL REFERENCES public.certificates_of_analysis (id),
    file_path  text NOT NULL UNIQUE,
    sha256     text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at  timestamptz NOT NULL DEFAULT now(),
    issued_by  uuid,
    UNIQUE (coa_id)
);

COMMENT ON TABLE public.coa_issues IS
    'MES-6b-2:分析证书的字节档案(*_issues 族的第十份,形状取自 cod_issues)。一张证书一份字节,【没有 version】;只追加;作废不动它。字节在私有桶 coa-documents(键 <证书 id>/<随机 id>.pdf),sha256 在这里 —— 取签发档时重算,对不上就拒(409)。';

ALTER TABLE public.coa_issues ENABLE ROW LEVEL SECURITY;
CREATE POLICY "coa_issues select by permission" ON public.coa_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.output.view'::text));
-- 【没有 INSERT 策略,这是刻意的】唯一写入口是 record_coa_issue()。
GRANT SELECT ON public.coa_issues TO authenticated;
REVOKE ALL ON public.coa_issues FROM anon;

-- 只追加:改、删、清空一律语句级拒 APPEND_ONLY|<表>|<操作>(没有写策略时行级触发器在 RLS 那里醒不过来 —— guard_append_only_log 的理由)
CREATE TRIGGER trg_coa_issues_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.coa_issues
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

-- ── 3 · 仓库申请多一种 coa_void(与 db/tables/warehouse_requests.sql 逐字同一份的列、约束、索引、列权限与表注释)──────────────
--   列加在末尾(镜像照"后加的列在最后"排);三条约束先删后建(CHECK 不能就地改);列清单 SELECT 授权【不会】自己延伸到新列 ——
--   所以同一支迁移里给它加上,遮蔽伴生视图也在下面换(AGENTS.md「给遮蔽表加列」:三件事一支迁移)。
ALTER TABLE public.warehouse_requests ADD COLUMN
    coa_id             uuid REFERENCES public.certificates_of_analysis (id) ON DELETE RESTRICT;
ALTER TABLE public.warehouse_requests DROP CONSTRAINT warehouse_requests_kind_check;
ALTER TABLE public.warehouse_requests ADD CONSTRAINT warehouse_requests_kind_check
CHECK (kind IN ('write_off_inbound', 'write_off_output', 'rollback', 'cod_void', 'coa_void'));
ALTER TABLE public.warehouse_requests DROP CONSTRAINT warehouse_requests_kind_shape;
ALTER TABLE public.warehouse_requests ADD
    CONSTRAINT warehouse_requests_kind_shape CHECK (
        (kind = 'write_off_inbound') = (inbound_batch_id IS NOT NULL)
        AND (kind = 'write_off_output') = (output_batch_id IS NOT NULL)
        AND (kind = 'rollback') = (run_id IS NOT NULL)
        AND (kind = 'cod_void') = (cod_id IS NOT NULL)
        AND (kind = 'coa_void') = (coa_id IS NOT NULL));
ALTER TABLE public.warehouse_requests DROP CONSTRAINT warehouse_requests_one_subject;
ALTER TABLE public.warehouse_requests ADD
    CONSTRAINT warehouse_requests_one_subject CHECK (num_nonnulls(inbound_batch_id, output_batch_id, run_id, cod_id, coa_id) = 1);
CREATE UNIQUE INDEX warehouse_requests_one_open_coa
    ON public.warehouse_requests (coa_id) WHERE status = 'submitted';
CREATE INDEX warehouse_requests_coa_id_rel ON public.warehouse_requests (coa_id);
GRANT SELECT (coa_id) ON public.warehouse_requests TO authenticated;
COMMENT ON TABLE public.warehouse_requests IS
    'APR-7:注销批次(write_off_inbound / write_off_output)、加工回滚(rollback)、作废销毁证书(cod_void)、作废分析证书(coa_void,MES-6b-2)的申请 —— 仓库提(分析证书由持 action.issue_coa 的人提),CFO 批每一张,不分档,批准当场生效。submitted → approved(CFO)· rejected(要理由)· withdrawn(提单人本人或该种类的码)。审批关着时生下来就是 approved 并当场生效(auto_approved)。在等的时候:主体批次上的任何库存流水按名拒 WAREHOUSE_REQUEST_FREEZES_BATCH;一个批次、它的证书、消耗它的加工单同一时刻只挂一张在等的申请(WAREHOUSE_REQUEST_OPEN)。空批(没有料也没有已签发证书)不经这里。';

-- ── 4 · 新函数(镜像原样),新表与新列之后:说话的化验 · 称重校准 · 拒绝清单 · 组装 · 预览 · 签发 · 记字节 · 作废 · 作废的申请 ─────

-- db/functions/coa_governing_assay.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q11,Tim):【一张分析证书说话的那一份化验】—— 一份判据,三个读它的:签发(issue_coa)、
--   预览(coa_certificate_data)、拒绝清单(coa_issue_blockers)。返回 {assay_id, basis, dispute_id};一份都没有 → assay_id 为空。
--   ① 这一批有一件已结案的争议 → 它点名的那一份(最近结案的那一件;与 judge_quality_limits、结算同一个选法)—— basis 'dispute';
--   ② 否则点名了销售单 → 那张单挂接那一刻抄下的合同副本里约定那一方(settling_party)最新一份没删的结果 —— basis 'settling_party';
--      单没挂合同、或副本里没说哪一方 → 落到 ③;
--   ③ 否则我们(ours)最新一份没删的结果 —— basis 'ours'。
--   "最新"= 化验日、再按编号(与 judge_quality_limits 同一个排序)。【它不看 is_final】—— 那是拒绝清单的事(COA_NO_FINAL_ASSAY):
--   说话的那一份必须是最终结果,而不是"最新的一份最终结果"(一份更新的初步结果在场时,证书不越过它去说一份旧的)。
--   【从不读 output_batch_metals】—— 选的是一份化验,纸上的成分读它自己的行。
--   内层算子:不问码;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.coa_governing_assay(p_output_batch_id uuid, p_sales_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id    uuid;
    v_disp  uuid;
    v_party text;
    v_basis text;
BEGIN
    SELECT a.id, d.id INTO v_id, v_disp
      FROM assay_disputes d
      JOIN assay_results a ON a.id = d.governing_assay_id AND a.deleted_at IS NULL
     WHERE d.output_batch_id = p_output_batch_id AND d.status = 'resolved'
     ORDER BY d.resolved_at DESC
     LIMIT 1;
    IF v_id IS NOT NULL THEN
        RETURN jsonb_build_object('assay_id', v_id, 'basis', 'dispute', 'dispute_id', v_disp);
    END IF;

    IF p_sales_order_id IS NOT NULL THEN
        SELECT NULLIF(t.settlement_terms ->> 'settling_party', '') INTO v_party
          FROM contract_document_terms t WHERE t.sales_order_id = p_sales_order_id;
    END IF;
    v_basis := CASE WHEN v_party IS NOT NULL THEN 'settling_party' ELSE 'ours' END;
    v_party := COALESCE(v_party, 'ours');

    SELECT a.id INTO v_id
      FROM assay_results a
     WHERE a.output_batch_id = p_output_batch_id AND a.deleted_at IS NULL AND a.result_party = v_party
     ORDER BY a.assay_date DESC, a.code DESC
     LIMIT 1;
    RETURN jsonb_build_object('assay_id', v_id, 'basis', v_basis, 'party', v_party, 'dispute_id', NULL);
END;
$function$;

-- db/functions/coa_output_calibration_problem.sql
-- MES-6b-2(2026-10-15,MES-0 Q68 · MES-6b Step 0 Q29,Tim):【一批产出批的称重有没有不在校准期内的】—— 分析证书说的数量是这批产出的过磅数,
--   所以它的读数要过 MES-2 的同一支判据(weighing_calibration_all,与加工提交、收货证书同一份)。返回第一句拒绝;没有问题 → NULL。
--   · 一条产出腿(processing_outputs,所在的加工单没被冲销)挂着的那一次称重,仪器在读数那一天【已知】不在校准期内 → 永远拒
--     READING_INSTRUMENT_NOT_CALIBRATED|<仪器>|<日期>(与 commit_processing_run 逐字同一句);
--   · 缺席由 require_calibrated_since 管(线上今天是空):称重没有记仪器 → COA_OUTPUT_WEIGHING_NOT_RECORDED|<加工单>|<批号>;
--     这一批一条称过的产出腿都没有(MES-4a 之前的单、手工建的产出批)→ COA_OUTPUT_READING_NOT_RECORDED|<批号>。
--     开关给了、而且那一炉的加工日(没有腿时:产出日)在它之后才拒 —— 开关空着时只有"已知不在校准期内"会拒。
--   内层算子;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.coa_output_calibration_problem(p_output_batch_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_since date;
    v_code  text;
    v_date  date;
    v_n     integer := 0;
    r       record;
BEGIN
    SELECT s.require_calibrated_since INTO v_since FROM ingest_settings s WHERE s.id;
    SELECT b.code, b.output_date INTO v_code, v_date FROM output_batches b WHERE b.id = p_output_batch_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    FOR r IN SELECT pr.code AS run_code, pr.process_date, wc.device_code, wc.captured_on, wc.status
               FROM processing_outputs po
               JOIN processing_runs pr ON pr.id = po.run_id AND pr.deleted_at IS NULL
               JOIN weighing_calibration_all wc ON wc.weighing_id = po.weighing_id
              WHERE po.output_batch_id = p_output_batch_id
              ORDER BY pr.code LOOP
        v_n := v_n + 1;
        IF r.status = 'not_recorded' THEN
            IF v_since IS NOT NULL AND r.process_date >= v_since THEN
                RETURN format('COA_OUTPUT_WEIGHING_NOT_RECORDED|%s|%s', r.run_code, v_code);
            END IF;
        ELSIF r.status <> 'in_calibration' THEN
            RETURN format('READING_INSTRUMENT_NOT_CALIBRATED|%s|%s', r.device_code, to_char(r.captured_on, 'YYYY-MM-DD'));
        END IF;
    END LOOP;
    IF v_n = 0 AND v_since IS NOT NULL AND v_date >= v_since THEN
        RETURN format('COA_OUTPUT_READING_NOT_RECORDED|%s', v_code);
    END IF;
    RETURN NULL;
END;
$function$;

-- db/functions/coa_issue_blockers.sql
-- MES-6b-2(2026-10-15,MES-0 Q68 · MES-6b Step 0 Q10 · Q29,Tim):【这一批(× 这张单)此刻为什么签发不了一张分析证书】—— 一份判据,两个读它的:
--   issue_coa 拒第一句;批次页的证书一块把每一句都摆出来(经 coa_certificate_data)。按次序,每一句都是一句具名的拒绝:
--     COA_SALES_ORDER_NOT_FOR_BATCH|<单号>|<批号>   点名的单不是预留过或发过这一批的那几张之一(与 open_ncr 同一个判法)
--     COA_ALREADY_ISSUED|<号>                       这一批 × 这张单(或不点名)已经有一张活的证书 —— 先经 CFO 作废它
--     QUALITY_HOLD_OPEN|<批号>|<报告>               这一批在质量暂扣里(判据 batch_quality_hold 一支)
--     ASSAY_DISPUTE_OPEN|<批号>|<争议>              这一批挂着一件开着的化验争议
--     COA_NO_FINAL_ASSAY|<批号>|<化验号或 ->        没有说话的那一份化验,或它不是最终结果(coa_governing_assay)
--     READING_INSTRUMENT_NOT_CALIBRATED|…  /  COA_OUTPUT_WEIGHING_NOT_RECORDED|…  /  COA_OUTPUT_READING_NOT_RECORDED|…
--                                                   一条产出腿的称重不在校准期内(缺席由 require_calibrated_since 管)
--     COA_LIMIT_BREACHED|<批号>|<单号>|<参数>       点名的单:这一批对那张单的 V17 判定(每个参数最近的那一行)越限,
--                                                   而为那一行开的报告没有以 accept / accept_with_penalty 决定
--     COMPANY_LEGAL_NAME_MISSING|/finance/company   纸头上的公司名还没录
--   签发人那两句(不是员工、没有职位)不在这里 —— 它们说的是按按钮的那个人,不是这一批;由 issue_coa 自己问。
--   内层算子;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.coa_issue_blockers(p_output_batch_id uuid, p_sales_order_id uuid)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_out   text[] := '{}'::text[];
    v_code  text;
    v_so    text;
    v_live  text;
    v_hold  record;
    v_disp  uuid;
    v_gov   jsonb;
    v_final boolean;
    v_acode text;
    v_cal   text;
    v_j     record;
BEGIN
    SELECT b.code INTO v_code FROM output_batches b WHERE b.id = p_output_batch_id AND b.deleted_at IS NULL;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    IF p_sales_order_id IS NOT NULL THEN
        SELECT so.code INTO v_so FROM sales_orders so WHERE so.id = p_sales_order_id;
        IF NOT EXISTS (SELECT 1 FROM sales_order_reservations r JOIN sales_order_lines l ON l.id = r.sales_order_line_id
                        WHERE l.sales_order_id = p_sales_order_id AND r.output_batch_id = p_output_batch_id)
           AND NOT EXISTS (SELECT 1 FROM shipment_lines sl JOIN sales_order_lines l ON l.id = sl.sales_order_line_id
                            WHERE l.sales_order_id = p_sales_order_id AND sl.output_batch_id = p_output_batch_id) THEN
            v_out := v_out || format('COA_SALES_ORDER_NOT_FOR_BATCH|%s|%s', COALESCE(v_so, p_sales_order_id::text), v_code);
        END IF;
    END IF;

    SELECT c.code INTO v_live FROM certificates_of_analysis c
     WHERE c.output_batch_id = p_output_batch_id AND c.sales_order_id IS NOT DISTINCT FROM p_sales_order_id
       AND c.status <> 'void';
    IF v_live IS NOT NULL THEN
        v_out := v_out || format('COA_ALREADY_ISSUED|%s', v_live);
    END IF;

    SELECT h.ncr_code INTO v_hold FROM batch_quality_hold(NULL::uuid, p_output_batch_id) h;
    IF FOUND THEN
        v_out := v_out || format('QUALITY_HOLD_OPEN|%s|%s', v_code, v_hold.ncr_code);
    END IF;

    SELECT d.id INTO v_disp FROM assay_disputes d WHERE d.output_batch_id = p_output_batch_id AND d.status = 'open' LIMIT 1;
    IF v_disp IS NOT NULL THEN
        v_out := v_out || format('ASSAY_DISPUTE_OPEN|%s|%s', v_code, v_disp);
    END IF;

    v_gov := coa_governing_assay(p_output_batch_id, p_sales_order_id);
    SELECT a.is_final, a.code INTO v_final, v_acode FROM assay_results a WHERE a.id = (v_gov ->> 'assay_id')::uuid;
    IF v_acode IS NULL OR NOT v_final THEN
        v_out := v_out || format('COA_NO_FINAL_ASSAY|%s|%s', v_code, COALESCE(v_acode, '-'));
    END IF;

    v_cal := coa_output_calibration_problem(p_output_batch_id);
    IF v_cal IS NOT NULL THEN
        v_out := v_out || v_cal;
    END IF;

    IF p_sales_order_id IS NOT NULL THEN
        FOR v_j IN SELECT DISTINCT ON (j.parameter) j.id, j.parameter, j.result
                     FROM quality_limit_judgements j
                    WHERE j.output_batch_id = p_output_batch_id AND j.sales_order_id = p_sales_order_id
                    ORDER BY j.parameter, j.id DESC LOOP
            IF v_j.result IN ('below_min', 'above_max')
               AND NOT EXISTS (SELECT 1 FROM nonconformance_reports n
                                WHERE n.judgement_id = v_j.id AND n.status = 'decided'
                                  AND n.disposition IN ('accept', 'accept_with_penalty')) THEN
                v_out := v_out || format('COA_LIMIT_BREACHED|%s|%s|%s', v_code, COALESCE(v_so, p_sales_order_id::text), v_j.parameter);
            END IF;
        END LOOP;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM company_profile cp WHERE btrim(COALESCE(cp.legal_name, '')) <> '') THEN
        v_out := v_out || 'COMPANY_LEGAL_NAME_MISSING|/finance/company'::text;
    END IF;

    RETURN v_out;
END;
$function$;

-- db/functions/coa_assemble.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q10–Q12 · Q31,Tim):【组装一张分析证书纸上的每一个值】—— 签发时冻进快照的就是它(issue_coa 再补上
--   号、签发时刻与签发人);预览读同一份(coa_certificate_data)。PDF 只从这一份渲染,所以纸与档案按构造一致。
--   company       纸头:公司法定名、注册号、地址(company_profile)
--   batch         批号、物料、数量与单位、产出日
--   assay         说话的那一份化验(coa_governing_assay):编号、化验日、实验室、证书号、样品号、出具方、重量基、水分、是否最终、
--                 怎么选出来的(dispute / settling_party / ours)
--   composition   【那一份化验自己的行】(assay_result_metals),按物质字典排序,带物质的角色(惩罚元素在纸上旁边印 ppm)——
--                 ★ 从不读 output_batch_metals(Q11:批次含量是"最后一次应用的那一份",不是说话的那一份)
--   indicators    那一份化验的指标值(assay_result_indicators),带名字与单位;没报的不印
--   chemistry     N38:来料化学确定度(output_batch_chemistry_certainty_all —— 基视图,理由见它的抬头)与它的字典名
--   sales_order   点名了单才有:单号、客户法定名(标签跟着单据走)、合同号与标题、质量验收限的口径、
--                 适用于这批物料的验收限(挂接那一刻抄下的副本 —— 与 judge_quality_limits 同一份、同一个"指名物料的优先")、
--                 这一批对这张单每个参数最近的那一行判定(值、抄下的限、结果、判的是哪一份化验)
--   内层算子:不问码(签发与预览各自问);EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.coa_assemble(p_output_batch_id uuid, p_sales_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch   record;
    v_gov     jsonb;
    v_assay   jsonb;
    v_aid     uuid;
    v_so      jsonb := NULL;
    v_t       record;
BEGIN
    SELECT ob.id, ob.code, ob.quantity, ob.unit, ob.output_date, ob.material_id, m.code AS material_code, m.name AS material_name
      INTO v_batch
      FROM output_batches ob LEFT JOIN materials m ON m.id = ob.material_id
     WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    v_gov := coa_governing_assay(p_output_batch_id, p_sales_order_id);
    v_aid := (v_gov ->> 'assay_id')::uuid;
    IF v_aid IS NOT NULL THEN
        SELECT jsonb_build_object(
                   'id', a.id, 'code', a.code, 'assay_date', a.assay_date,
                   'lab_code', a.lab_name, 'lab_name', COALESCE(lab.name_en, a.lab_name),
                   'certificate_ref', a.certificate_ref, 'sample_ref', a.sample_ref,
                   'result_party', a.result_party, 'weight_basis', a.weight_basis, 'moisture_pct', a.moisture_pct,
                   'is_final', a.is_final, 'basis', v_gov ->> 'basis', 'dispute_id', v_gov -> 'dispute_id')
          INTO v_assay
          FROM assay_results a LEFT JOIN laboratories lab ON lab.code = a.lab_name
         WHERE a.id = v_aid;
    END IF;

    IF p_sales_order_id IS NOT NULL THEN
        SELECT so.code, COALESCE(cu.legal_name, cu.short_name) AS customer_name, t.contract_code, t.contract_title,
               t.settlement_terms
          INTO v_t
          FROM sales_orders so
          LEFT JOIN customers cu ON cu.id = so.customer_id
          LEFT JOIN contract_document_terms t ON t.sales_order_id = so.id
         WHERE so.id = p_sales_order_id;
        v_so := jsonb_build_object(
            'id', p_sales_order_id, 'code', v_t.code, 'customer_name', v_t.customer_name,
            'contract_code', v_t.contract_code, 'contract_title', v_t.contract_title,
            'quality_limit_basis', v_t.settlement_terms ->> 'quality_limit_basis',
            'limits', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'parameter', l.parameter,
                           'name', CASE WHEN l.parameter = 'moisture_pct' THEN 'Moisture' ELSE COALESCE(ai.name_en, l.parameter) END,
                           'unit', CASE WHEN l.parameter = 'moisture_pct' THEN '%' ELSE ai.unit END,
                           'min_value', l.min_value, 'max_value', l.max_value)
                         ORDER BY CASE WHEN l.parameter = 'moisture_pct' THEN 0 ELSE 1 END, ai.sort_order, l.parameter)
                  FROM (SELECT DISTINCT ON (e ->> 'parameter')
                               e ->> 'parameter' AS parameter,
                               (e ->> 'min_value')::numeric AS min_value,
                               (e ->> 'max_value')::numeric AS max_value
                          FROM jsonb_array_elements(COALESCE(v_t.settlement_terms -> 'quality_limits', '[]'::jsonb)) e
                         WHERE (e ->> 'material_id') IS NULL OR (e ->> 'material_id')::uuid = v_batch.material_id
                         ORDER BY e ->> 'parameter', ((e ->> 'material_id') IS NULL)) l
                  LEFT JOIN assay_indicators ai ON ai.code = l.parameter), '[]'::jsonb),
            'judgements', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'parameter', j.parameter,
                           'name', CASE WHEN j.parameter = 'moisture_pct' THEN 'Moisture' ELSE COALESCE(ai.name_en, j.parameter) END,
                           'unit', CASE WHEN j.parameter = 'moisture_pct' THEN '%' ELSE ai.unit END,
                           'value', j.value, 'limit_min', j.limit_min_at, 'limit_max', j.limit_max_at, 'result', j.result,
                           'assay_code', a.code, 'judged_at', j.judged_at)
                         ORDER BY CASE WHEN j.parameter = 'moisture_pct' THEN 0 ELSE 1 END, ai.sort_order, j.parameter)
                  FROM (SELECT DISTINCT ON (x.parameter) x.* FROM quality_limit_judgements x
                         WHERE x.output_batch_id = p_output_batch_id AND x.sales_order_id = p_sales_order_id
                         ORDER BY x.parameter, x.id DESC) j
                  JOIN assay_results a ON a.id = j.assay_result_id
                  LEFT JOIN assay_indicators ai ON ai.code = j.parameter), '[]'::jsonb));
    END IF;

    RETURN jsonb_build_object(
        'company', (SELECT jsonb_build_object('legal_name', cp.legal_name, 'registration_no', cp.registration_no,
                                              'address_lines', cp.address_lines, 'city', cp.city, 'postal_code', cp.postal_code,
                                              'country', cp.country)
                      FROM company_profile cp LIMIT 1),
        'batch', jsonb_build_object('id', v_batch.id, 'code', v_batch.code, 'material_code', v_batch.material_code,
                                    'material_name', v_batch.material_name, 'quantity', v_batch.quantity, 'unit', v_batch.unit,
                                    'output_date', v_batch.output_date),
        'assay', v_assay,
        'composition', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('substance', m.metal, 'name', COALESCE(s.name_en, m.metal), 'symbol', s.symbol,
                                                'role', s.role, 'content_pct', m.content_pct)
                             ORDER BY s.sort_order NULLS LAST, m.metal)
              FROM assay_result_metals m LEFT JOIN substances s ON s.code = m.metal
             WHERE m.assay_result_id = v_aid), '[]'::jsonb),
        'indicators', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('code', i.indicator, 'name', COALESCE(ai.name_en, i.indicator), 'unit', ai.unit,
                                                'value', i.value)
                             ORDER BY ai.sort_order NULLS LAST, i.indicator)
              FROM assay_result_indicators i LEFT JOIN assay_indicators ai ON ai.code = i.indicator
             WHERE i.assay_result_id = v_aid), '[]'::jsonb),
        'chemistry', (SELECT jsonb_build_object('certainty', c.certainty,
                                                'certainty_name', CASE WHEN c.certainty = 'not_recorded' THEN 'Not recorded'
                                                                       ELSE COALESCE(d.name_en, c.certainty) END,
                                                'inbound_leaves', c.inbound_leaves, 'leaves_single_known', c.leaves_single_known,
                                                'leaves_mixed', c.leaves_mixed, 'leaves_not_recorded', c.leaves_not_recorded,
                                                'leaves_unknown_pending', c.leaves_unknown_pending)
                        FROM output_batch_chemistry_certainty_all c
                        LEFT JOIN inbound_chemistry_certainties d ON d.code = c.certainty
                       WHERE c.output_batch_id = p_output_batch_id),
        'sales_order', v_so);
END;
$function$;

-- db/functions/coa_certificate_data.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q10 · Q11 · Q29,Tim):【一张分析证书此刻会是什么样子,以及为什么还签发不了】—— 批次页的证书一块与
--   PDF 路由的预览读它。返回 coa_assemble 的那一份(与签发时冻进快照的同一支组装)外加 blockers(coa_issue_blockers 的每一句,按次序;
--   空数组 = 这一批此刻签发得了)。它【不铸号、不落库、不留任何东西】。
--   门:module.output.view —— 与证书表与产出批的读策略同一个码(看证书跟着那一批的查看码,Q30)。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.coa_certificate_data(p_output_batch_id uuid, p_sales_order_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.output.view');
    RETURN coa_assemble(p_output_batch_id, p_sales_order_id)
        || jsonb_build_object('blockers', to_jsonb(coa_issue_blockers(p_output_batch_id, p_sales_order_id)),
                              'certificate', NULL::jsonb, 'issuer', NULL::jsonb);
END;
$function$;

-- db/functions/issue_coa.sql
-- MES-6b-2(2026-10-15,MES-0 Q67 · Q68 · Q90;MES-6b Step 0 Q10–Q13 · Q29–Q32,Tim):【签发一张分析证书】—— 铸号、组装、冻住,一笔事务。
--   门 action.issue_coa(cco · admin)。
--   ① 拒绝清单 coa_issue_blockers 的第一句原样抛出(没有最终化验 · 质量暂扣 · 开着的争议 · 称重不在校准期内 · 点名的单越限而没被接受 ·
--      单不是这一批的 · 这一批 × 这张单已有一张活证书 · 公司名没录)—— 与批次页摆出来的是同一份判据。
--   ② 签发人(Q13):纸上印「Issued by <名字>, <职位>」与签发时刻,不放签名图片。名字 = 这个账号的员工(current_user_employee:
--      主账号或 employee_accounts)的常用名、否则法定名;职位 = 他的 positions.title。不是员工 → COA_ISSUER_NOT_AN_EMPLOYEE;
--      没有职位 → COA_ISSUER_POSITION_MISSING|<名字>(纸上不印半句,与 COMPANY_LEGAL_NAME_MISSING 同一条:缺一格就按名拒,不印空白)。
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
    v_emp      uuid;
    v_name     text;
    v_position text;
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

    v_code := next_coa_code();
    v_now := clock_timestamp();
    v_snap := coa_assemble(p_output_batch_id, p_sales_order_id)
        || jsonb_build_object('certificate', jsonb_build_object('id', v_id, 'code', v_code, 'status', 'issued', 'issued_at', v_now),
                              'issuer', jsonb_build_object('name', v_name, 'position', v_position));

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

-- db/functions/record_coa_issue.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q31):【记下一张分析证书的字节】—— PDF 已经由路由照快照渲染、传进私有桶 coa-documents,
--   这里落它的路径与 sha256(coa_issues,只追加)。门 action.issue_coa(与桶的上传策略同一个码)。
--   证书要在、要是已签发(COA_NOT_FOUND · COA_NOT_ISSUED);路径必须是 <证书 id>/…(COA_ISSUE_PATH_INVALID);
--   一张证书只记一份字节(COA_BYTES_ALREADY_RECORDED —— 没有第二版,与 cod_issues 同一条)。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.record_coa_issue(p_coa_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c record;
BEGIN
    PERFORM require_permission('action.issue_coa');
    SELECT c.id, c.code, c.status INTO v_c FROM certificates_of_analysis c WHERE c.id = p_coa_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'COA_NOT_FOUND|%', COALESCE(p_coa_id::text, '?');
    END IF;
    IF v_c.status <> 'issued' THEN
        RAISE EXCEPTION 'COA_NOT_ISSUED|%|%', v_c.code, v_c.status;
    END IF;
    IF p_file_path IS NULL OR p_file_path NOT LIKE v_c.id::text || '/%' THEN
        RAISE EXCEPTION 'COA_ISSUE_PATH_INVALID|%', v_c.code;
    END IF;
    IF EXISTS (SELECT 1 FROM coa_issues i WHERE i.coa_id = p_coa_id) THEN
        RAISE EXCEPTION 'COA_BYTES_ALREADY_RECORDED|%', v_c.code;
    END IF;
    INSERT INTO coa_issues (coa_id, file_path, sha256, issued_by) VALUES (p_coa_id, p_file_path, lower(p_sha256), auth.uid());
    RETURN jsonb_build_object('coa_id', p_coa_id, 'code', v_c.code, 'sha256', lower(p_sha256));
END;
$function$;

-- db/functions/void_coa_internal.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q20 · Q32):作废一张已签发的分析证书 —— 只经 CFO 批准的 coa_void 申请走到这里
--   (warehouse_request_execute_internal)。voided_by = 提单人(APR-7 grilling Q6 的同一条);作废【不动】快照与字节档案一个字。
--   没有替代品:重开一张是另一个新号,签发它时由 issue_coa 链上 replaced_by_coa_id。
--   内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.void_coa_internal(p_coa_id uuid, p_reason text, p_voided_by uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    UPDATE certificates_of_analysis
       SET status = 'void', void_reason = p_reason,
           voided_at = clock_timestamp(), voided_by = COALESCE(p_voided_by, auth.uid())
     WHERE id = p_coa_id AND status = 'issued';
END;
$function$;

-- db/functions/submit_coa_void_request.sql
-- MES-6b-2(2026-10-15,MES-0 Q89 · MES-6b Step 0 Q20 · Q32,Tim):提一张申请 —— 作废一张已签发的分析证书。CFO 批准才生效
--   (warehouse_requests 的 coa_void,二级,不分档;提单人永远不能批)。门 action.issue_coa(cco · admin);其余全在
--   warehouse_request_submit_internal。【这是作废一张分析证书唯一的路】—— 没有一步作废的函数。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.submit_coa_void_request(p_coa_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.issue_coa');
    RETURN warehouse_request_submit_internal('coa_void', p_coa_id, p_reason);
END;
$function$;

-- ── 5 · 换掉的函数(镜像原样,同签名):仓库申请认 coa_void · 审计主语 coa 与它在两个批次主语下的成员 ──────────────────────

-- db/functions/warehouse_request_submit_internal.sql
-- APR-7(2026-09-25):提一张仓库申请 —— 四扇提交的门各问完自己的码,落进这一支。本支不问码。
--
--   1. 理由必填(WAREHOUSE_REQUEST_REASON_REQUIRED|种类|编号)—— 它原样成为 delete_reason / 回滚理由 / void_reason。
--   2. 主体要在、没被删、这一种要成立:
--        注销:batch_write_off_needs_request 为真,否则 WAREHOUSE_REQUEST_NOT_NEEDED|批号(空批一步删,Q1);
--        回滚:加工单在且未回滚(RUN_NOT_FOUND · RUN_ALREADY_DELETED);
--        作废:证书在且已签发(COD_NOT_FOUND · COD_NOT_ISSUED);
--        ★ MES-6b-2:作废分析证书(coa_void):证书在且已签发(COA_NOT_FOUND · COA_NOT_ISSUED)。
--   3. 碰到同一样东西的在等申请 → WAREHOUSE_REQUEST_OPEN|编号|那一张(Q3,跨种类;唯一索引是同种类的第二道)。
--   4. ★ 审批开着时:提单人这个【人】之外,二级还有没有人批得动 → WAREHOUSE_REQUEST_NO_OTHER_DECIDER|label
--      (assert_other_decider,按人认)。线上是 admin@:它与 tim@ 是同一个人,而二级只有 tim@。
--   5. 落一行 submitted,snapshot 冻结;按批准那一刻的同一支试跑(warehouse_request_dry_run)——
--      欠款、订单预留、产出动过、期间锁,全按原话拒。amount_base 取试跑的结果。
--   6. 审批开着:留痕 submitted,二级。关着:当场生效,状态 approved,留痕 auto_approved。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_submit_internal(p_kind text, p_subject uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_on    boolean := approvals_enabled();
    v_id    uuid := gen_random_uuid();
    v_code  text;
    v_del   timestamptz;
    v_stat  text;
    v_open  text;
    v_n     integer;
    v_label text;
    v_dry   jsonb;
    v_exec  jsonb := NULL;
BEGIN
    IF p_kind = 'write_off_inbound' THEN
        SELECT code INTO v_code FROM inbound_batches WHERE id = p_subject AND deleted_at IS NULL FOR UPDATE;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
    ELSIF p_kind = 'write_off_output' THEN
        SELECT code INTO v_code FROM output_batches WHERE id = p_subject AND deleted_at IS NULL FOR UPDATE;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
    ELSIF p_kind = 'rollback' THEN
        SELECT code, deleted_at INTO v_code, v_del FROM processing_runs WHERE id = p_subject FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'RUN_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
        IF v_del IS NOT NULL THEN
            RAISE EXCEPTION 'RUN_ALREADY_DELETED';
        END IF;
    ELSIF p_kind = 'cod_void' THEN
        SELECT COALESCE(code, id::text), status INTO v_code, v_stat
          FROM certificates_of_destruction WHERE id = p_subject FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'COD_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
        IF v_stat <> 'issued' THEN
            RAISE EXCEPTION 'COD_NOT_ISSUED|%|%', v_code, v_stat;
        END IF;
    ELSIF p_kind = 'coa_void' THEN
        SELECT code, status INTO v_code, v_stat FROM certificates_of_analysis WHERE id = p_subject FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'COA_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
        IF v_stat <> 'issued' THEN
            RAISE EXCEPTION 'COA_NOT_ISSUED|%|%', v_code, v_stat;
        END IF;
    ELSE
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_REASON_REQUIRED|%|%', p_kind, v_code;
    END IF;

    IF p_kind IN ('write_off_inbound', 'write_off_output')
       AND NOT batch_write_off_needs_request(
               CASE WHEN p_kind = 'write_off_inbound' THEN p_subject END,
               CASE WHEN p_kind = 'write_off_output' THEN p_subject END) THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_NEEDED|%', v_code;
    END IF;

    v_open := warehouse_request_conflict(p_kind, p_subject);
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_OPEN|%|%', v_code, v_open;
    END IF;

    -- label:同一个主体上第几张。咨询锁串行化"数一遍 + 1"。
    PERFORM pg_advisory_xact_lock(hashtext('warehouse_request_label')::bigint);
    SELECT count(*) + 1 INTO v_n FROM warehouse_requests r
     WHERE r.kind = p_kind
       AND COALESCE(r.inbound_batch_id, r.output_batch_id, r.run_id, r.cod_id, r.coa_id) = p_subject;
    v_label := v_code || ' · ' || CASE p_kind WHEN 'rollback' THEN 'rollback'
                                               WHEN 'cod_void' THEN 'void'
                                               WHEN 'coa_void' THEN 'void'
                                               ELSE 'write-off' END || ' #' || v_n::text;

    PERFORM assert_other_decider('warehouse_request', 'decide_warehouse_request', 2::smallint,
                                 'WAREHOUSE_REQUEST_NO_OTHER_DECIDER|' || v_label);

    INSERT INTO warehouse_requests (id, kind, status, label, inbound_batch_id, output_batch_id, run_id, cod_id, coa_id,
                                    reason, snapshot, amount_base, created_by)
    VALUES (v_id, p_kind, 'submitted', v_label,
            CASE WHEN p_kind = 'write_off_inbound' THEN p_subject END,
            CASE WHEN p_kind = 'write_off_output' THEN p_subject END,
            CASE WHEN p_kind = 'rollback' THEN p_subject END,
            CASE WHEN p_kind = 'cod_void' THEN p_subject END,
            CASE WHEN p_kind = 'coa_void' THEN p_subject END,
            btrim(p_reason), warehouse_request_snapshot(p_kind, p_subject), 0, auth.uid());

    v_dry := warehouse_request_dry_run(v_id);
    UPDATE warehouse_requests SET amount_base = (v_dry->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('warehouse_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        v_exec := warehouse_request_execute_internal(v_id);
        UPDATE warehouse_requests
           SET status = 'approved', executed_at = now(),
               amount_base = (v_exec->>'amount_base')::numeric,
               result_entry_ids = ARRAY(SELECT jsonb_array_elements_text(v_exec->'entry_ids')::uuid)
         WHERE id = v_id;
        PERFORM record_approval_decision('warehouse_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场生效,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'kind', p_kind,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        'amount_base', COALESCE(v_exec->'amount_base', v_dry->'amount_base'));
END;
$function$;

-- db/functions/warehouse_request_execute_internal.sql
-- APR-7(2026-09-25):让一张仓库申请【生效】—— 批准、审批关着时的提交、提交时的试跑,三处都走这一支,
-- 所以试跑拒的与批准拒的是同一句话。
--   write_off_inbound → soft_delete_inbound_batch_internal(欠款检查在那里,Q4:提交时一遍、批准时再一遍)
--   write_off_output  → soft_delete_output_batch_internal(订单预留在注销触发器里拒)
--   rollback          → rollback_processing_run_internal(OUTPUT_CONSUMED 在那里)
--   cod_void          → 只有已签发的作废得掉(COD_NOT_ISSUED),void_cod_internal,没有替代品
--   coa_void          → ★ MES-6b-2:只有已签发的分析证书作废得掉(COA_NOT_ISSUED),void_coa_internal;快照与字节一个字不动
-- 每一种的 deleted_by / voided_by = 提单人(grilling Q6)。
-- 【冻结放行】evoltrya.warehouse_request_ctx = 本申请 id,guard_warehouse_request_freeze 只放它自己写的流水。
-- 返回 amount_base(本次过出来那几张分录的借方合计,本位币)与 entry_ids。"本次过出来的"= 本事务里
-- 执行之前不存在、之后存在的分录(created_at 默认 now(),即事务时间)。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_execute_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r      warehouse_requests%ROWTYPE;
    v_before uuid[];
    v_ids    uuid[];
    v_amt    numeric;
    v_cod    record;
    v_coa    record;
BEGIN
    SELECT * INTO v_r FROM warehouse_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;

    v_before := ARRAY(SELECT je.id FROM journal_entries je WHERE je.created_at = now());
    PERFORM set_config('evoltrya.warehouse_request_ctx', v_r.id::text, true);

    IF v_r.kind = 'write_off_inbound' THEN
        PERFORM soft_delete_inbound_batch_internal(v_r.inbound_batch_id, v_r.reason, v_r.created_by);
    ELSIF v_r.kind = 'write_off_output' THEN
        PERFORM soft_delete_output_batch_internal(v_r.output_batch_id, v_r.reason, v_r.created_by);
    ELSIF v_r.kind = 'rollback' THEN
        PERFORM rollback_processing_run_internal(v_r.run_id, v_r.reason, v_r.created_by);
    ELSIF v_r.kind = 'cod_void' THEN
        SELECT c.id, c.code, c.status INTO v_cod
          FROM certificates_of_destruction c WHERE c.id = v_r.cod_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'COD_NOT_FOUND|%', COALESCE(v_r.cod_id::text, '?');
        END IF;
        IF v_cod.status <> 'issued' THEN
            RAISE EXCEPTION 'COD_NOT_ISSUED|%|%', COALESCE(v_cod.code, v_cod.id::text), v_cod.status;
        END IF;
        PERFORM void_cod_internal(v_cod.id, v_r.reason, NULL, v_r.created_by);
    ELSIF v_r.kind = 'coa_void' THEN
        SELECT c.id, c.code, c.status INTO v_coa
          FROM certificates_of_analysis c WHERE c.id = v_r.coa_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'COA_NOT_FOUND|%', COALESCE(v_r.coa_id::text, '?');
        END IF;
        IF v_coa.status <> 'issued' THEN
            RAISE EXCEPTION 'COA_NOT_ISSUED|%|%', v_coa.code, v_coa.status;
        END IF;
        PERFORM void_coa_internal(v_coa.id, v_r.reason, v_r.created_by);
    ELSE
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_KIND_UNKNOWN|%', v_r.kind;
    END IF;

    PERFORM set_config('evoltrya.warehouse_request_ctx', '', true);

    v_ids := ARRAY(SELECT je.id FROM journal_entries je
                    WHERE je.created_at = now() AND je.id <> ALL (v_before) ORDER BY je.code);
    SELECT COALESCE(round(sum(l.debit), 2), 0) INTO v_amt
      FROM journal_lines l WHERE l.entry_id = ANY (v_ids);

    RETURN jsonb_build_object('amount_base', v_amt, 'entry_ids', to_jsonb(v_ids));
END;
$function$;

-- db/functions/warehouse_request_snapshot.sql
-- APR-7(2026-09-25,grilling Q5 · Q8):提交时冻给 CFO 读的那一组。CFO 不持 action.issue_cod,读不到证书表 ——
-- 所以"这会作废哪一张证书"要在这里说出来;回滚的加工日是否落在已锁期间(finance_settings.locked_before)
-- 也在这里说出来(Q5:准许,但批之前要看得见)。【不含金额】—— 金额在 amount_base,按 data.view_prices 给。
-- ★ MES-6b-2:coa_void —— 证书号、批号与批 id(给屏幕链回批次页)、点名的销售单号与客户名、签发时刻、说话的那一份化验。
--   CFO 持 module.output.view,读得到证书;这一组仍然冻在申请上:批的是提交那一刻看见的那一张。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_snapshot(p_kind text, p_subject uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_kind
    WHEN 'write_off_inbound' THEN (
        SELECT jsonb_build_object(
            'batch_code', ib.code, 'material_code', m.code, 'material_name', m.name,
            'supplier_name', COALESCE(s.short_name, s.legal_name), 'remaining_qty', ib.remaining_qty,
            'quantity', ib.quantity, 'unit', ib.unit, 'priced', ib.unit_price IS NOT NULL,
            'cods_voided', COALESCE((SELECT jsonb_agg(c.code ORDER BY c.code) FROM certificates_of_destruction c
                                      WHERE c.inbound_batch_id = ib.id AND c.status = 'issued'), '[]'::jsonb))
          FROM inbound_batches ib
          LEFT JOIN materials m ON m.id = ib.material_id
          LEFT JOIN suppliers s ON s.id = ib.supplier_id
         WHERE ib.id = p_subject)
    WHEN 'write_off_output' THEN (
        SELECT jsonb_build_object(
            'batch_code', ob.code, 'material_code', m.code, 'material_name', m.name,
            'remaining_qty', ob.remaining_qty, 'quantity', ob.quantity, 'unit', ob.unit, 'state', ob.state,
            'run_code', (SELECT pr.code FROM processing_outputs po JOIN processing_runs pr ON pr.id = po.run_id
                          WHERE po.output_batch_id = ob.id LIMIT 1),
            'cods_voided', '[]'::jsonb)
          FROM output_batches ob
          LEFT JOIN materials m ON m.id = ob.material_id
         WHERE ob.id = p_subject)
    WHEN 'rollback' THEN (
        SELECT jsonb_build_object(
            'run_code', pr.code, 'process_date', pr.process_date,
            'locked_period', pr.process_date < (SELECT fs.locked_before FROM finance_settings fs),
            'locked_before', (SELECT fs.locked_before FROM finance_settings fs),
            'outputs', COALESCE((SELECT jsonb_agg(ob.code ORDER BY ob.code) FROM processing_outputs po
                                   JOIN output_batches ob ON ob.id = po.output_batch_id
                                  WHERE po.run_id = pr.id AND ob.deleted_at IS NULL), '[]'::jsonb),
            'inputs', COALESCE((SELECT jsonb_agg(DISTINCT COALESCE(ib.code, ob.code)) FROM processing_inputs pi
                                  LEFT JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
                                  LEFT JOIN output_batches ob ON ob.id = pi.output_batch_id
                                 WHERE pi.run_id = pr.id), '[]'::jsonb),
            'cods_voided', COALESCE((SELECT jsonb_agg(DISTINCT c.code) FROM processing_inputs pi
                                       JOIN certificates_of_destruction c
                                         ON c.inbound_batch_id = pi.inbound_batch_id AND c.status = 'issued'
                                      WHERE pi.run_id = pr.id), '[]'::jsonb))
          FROM processing_runs pr
         WHERE pr.id = p_subject)
    WHEN 'cod_void' THEN (
        SELECT jsonb_build_object(
            'cod_code', c.code, 'batch_code', ib.code, 'supplier_name', COALESCE(s.short_name, s.legal_name),
            'material_name', m.name, 'issued_at', c.issued_at, 'completed_on', c.completed_on,
            'cods_voided', jsonb_build_array(c.code))
          FROM certificates_of_destruction c
          JOIN inbound_batches ib ON ib.id = c.inbound_batch_id
          LEFT JOIN materials m ON m.id = ib.material_id
          LEFT JOIN suppliers s ON s.id = ib.supplier_id
         WHERE c.id = p_subject)
    WHEN 'coa_void' THEN (
        SELECT jsonb_build_object(
            'coa_code', c.code, 'batch_code', ob.code, 'output_batch_id', ob.id, 'material_name', m.name,
            'sales_order_code', so.code, 'customer_name', COALESCE(cu.short_name, cu.legal_name),
            'issued_at', c.issued_at, 'assay_code', a.code, 'cods_voided', '[]'::jsonb)
          FROM certificates_of_analysis c
          JOIN output_batches ob ON ob.id = c.output_batch_id
          LEFT JOIN materials m ON m.id = ob.material_id
          LEFT JOIN sales_orders so ON so.id = c.sales_order_id
          LEFT JOIN customers cu ON cu.id = so.customer_id
          LEFT JOIN assay_results a ON a.id = c.governing_assay_id
         WHERE c.id = p_subject)
    END
$function$;

-- db/functions/warehouse_request_touches.sql
-- APR-7(2026-09-25,grilling Q3):一张仓库申请【碰到】哪些东西 —— 一份判据,三个读它的人:
--   提交时的"同一时刻只挂一张"(warehouse_request_conflict)· 一步删空批的那扇门 · 屏幕上"为什么灰掉"。
--   write_off_inbound  那一批('in')+ 它的活证书('cod')
--   write_off_output   那一批('out')
--   rollback           那张单('run')+ 它的产出批('out')+ 它的投料 —— 进料批('in')与产出批投料('out')
--                      + 投料进料批上的活证书('cod')
--   cod_void           那张证书('cod')+ 它的进料批('in')
--   coa_void           那张分析证书('coa')—— ★ MES-6b-2:只碰它自己。一张分析证书永远不会被自动作废(Q32),所以注销或回滚
--                      它那一批不会让一张在等的作废申请批不出来,不必互斥。
-- 【现读,不冻结】碰到什么是此刻的事实;冻结(guard_warehouse_request_freeze)保证它在等的时候不变。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_touches(p_kind text, p_subject uuid)
 RETURNS TABLE(t text, id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT 'in'::text, p_subject WHERE p_kind = 'write_off_inbound'
    UNION
    SELECT 'cod', c.id FROM certificates_of_destruction c
     WHERE p_kind = 'write_off_inbound' AND c.inbound_batch_id = p_subject AND c.status <> 'void'
    UNION
    SELECT 'out', p_subject WHERE p_kind = 'write_off_output'
    UNION
    SELECT 'run', p_subject WHERE p_kind = 'rollback'
    UNION
    SELECT 'out', po.output_batch_id FROM processing_outputs po
     WHERE p_kind = 'rollback' AND po.run_id = p_subject
    UNION
    SELECT CASE WHEN pi.inbound_batch_id IS NOT NULL THEN 'in' ELSE 'out' END,
           COALESCE(pi.inbound_batch_id, pi.output_batch_id)
      FROM processing_inputs pi
     WHERE p_kind = 'rollback' AND pi.run_id = p_subject
    UNION
    SELECT 'cod', c.id FROM processing_inputs pi
      JOIN certificates_of_destruction c ON c.inbound_batch_id = pi.inbound_batch_id AND c.status <> 'void'
     WHERE p_kind = 'rollback' AND pi.run_id = p_subject
    UNION
    SELECT 'cod', p_subject WHERE p_kind = 'cod_void'
    UNION
    SELECT 'in', c.inbound_batch_id FROM certificates_of_destruction c
     WHERE p_kind = 'cod_void' AND c.id = p_subject
    UNION
    SELECT 'coa', p_subject WHERE p_kind = 'coa_void'
$function$;

COMMENT ON FUNCTION public.warehouse_request_touches(text, uuid) IS
'APR-7(grilling Q3):一张仓库申请碰到的批次(in / out)、加工单(run)、销毁证书(cod)与分析证书(coa,MES-6b-2:只碰它自己)。一个批次、它的证书、消耗它的加工单同一时刻只许挂一张在等的申请 —— 那条规矩就是"两张申请的这个集合不许相交"。';

-- db/functions/warehouse_request_conflict.sql
-- APR-7(2026-09-25,grilling Q3):与 (p_kind, p_subject) 碰到同一样东西的、在等的那一张仓库申请的 label;
-- 没有 → NULL。提交时按名拒 WAREHOUSE_REQUEST_OPEN,一步删空批的那扇门也问它。
-- 【为什么要跨种类】一张在等的证书作废申请,遇上同一批货的注销或回滚被批准 —— 那一刻证书被自动作废,
-- 作废申请就再也批不出来,挂在那里挡住审批关闭。所以不让它们同时存在。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_conflict(p_kind text, p_subject uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT r.label
      FROM warehouse_requests r
     WHERE r.status = 'submitted'
       AND EXISTS (
           SELECT 1
             FROM warehouse_request_touches(r.kind, COALESCE(r.inbound_batch_id, r.output_batch_id, r.run_id, r.cod_id, r.coa_id)) a
             JOIN warehouse_request_touches(p_kind, p_subject) b ON b.t = a.t AND b.id = a.id)
     ORDER BY r.created_at
     LIMIT 1
$function$;

-- db/functions/withdraw_warehouse_request.sql
-- APR-7(2026-09-25):撤回一张在等的仓库申请。谁能撤:提单人本人(按人认),或持这一种那个码的人
-- (注销 action.batch_write_off · 回滚 action.processing_rollback · 作废 action.issue_cod · ★ MES-6b-2 作废分析证书 action.issue_coa)。
-- 只撤 submitted。撤回什么都不生效、冻结随之解开;记在本行上,【不】写 approval_log(撤回不是一次决定)。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.withdraw_warehouse_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r warehouse_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM warehouse_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission(CASE v_r.kind WHEN 'rollback' THEN 'action.processing_rollback'
                                                 WHEN 'cod_void' THEN 'action.issue_cod'
                                                 WHEN 'coa_void' THEN 'action.issue_coa'
                                                 ELSE 'action.batch_write_off' END);
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE warehouse_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
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
        ('inbound_batch',     51, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- ── 6 · 视图:N38 的基视图与读面 · 证书的读面(新)· 仓库申请的遮蔽伴生多 coa_id · 提醒多一支(镜像原样,列只在末尾加)──────────

-- db/views/output_batch_chemistry_certainty_all.sql
-- MES-6b-2(2026-10-15,N38;MES-6b Step 0 Q12,Tim):output_batch_chemistry_certainty 的【无判据基视图】—— 一批产出批的来料化学有多确定。
--   沿 batch_lineage_all 走到每一张【进料叶子】(parent_kind = 'inbound',任意深度),取叶子上 chemistry_certainty_code 里【最弱】的那一个:
--     unknown_pending(认不出,等鉴定)< 未记录(没人记过,NULL)< mixed(已知是混的)< single_known(单一、已知)。
--   一个字典里将来新加、这里不认得的码排在最弱之下(rank 0),并原样报出它的码 —— 一份不认得的确定度不该被读成"已知"。
--   没有任何进料叶子(手工建的产出批、或血缘走不到进料)→ 'not_recorded',inbound_leaves = 0:来料的化学没有任何一条记录。
--   为什么要基视图:属主视图里的 has_permission 按调用者解析 —— issue_coa / coa_assemble 以属主身份读它时,调用者(持 action.issue_coa
--   的人)不一定持 module.output.view(那个码声明的查看码是"任一");所以判据挪到外层 output_batch_chemistry_certainty,内层不授给任何人
--   (与 batch_lineage_all / batch_lineage 同一个先例)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.

CREATE VIEW public.output_batch_chemistry_certainty_all WITH (security_invoker = off) AS
 WITH leaves AS (
         SELECT DISTINCT l.output_batch_id,
            l.parent_batch_id AS inbound_batch_id
           FROM batch_lineage_all l
          WHERE l.parent_kind = 'inbound'::text
        ), ranked AS (
         SELECT lv.output_batch_id,
            ib.chemistry_certainty_code,
                CASE
                    WHEN ib.chemistry_certainty_code IS NULL THEN 2
                    WHEN ib.chemistry_certainty_code = 'unknown_pending'::text THEN 1
                    WHEN ib.chemistry_certainty_code = 'mixed'::text THEN 3
                    WHEN ib.chemistry_certainty_code = 'single_known'::text THEN 4
                    ELSE 0
                END AS rank
           FROM leaves lv
             JOIN inbound_batches ib ON ib.id = lv.inbound_batch_id
        ), agg AS (
         SELECT r.output_batch_id,
            count(*)::integer AS inbound_leaves,
            count(*) FILTER (WHERE r.chemistry_certainty_code = 'single_known'::text)::integer AS leaves_single_known,
            count(*) FILTER (WHERE r.chemistry_certainty_code = 'mixed'::text)::integer AS leaves_mixed,
            count(*) FILTER (WHERE r.chemistry_certainty_code IS NULL)::integer AS leaves_not_recorded,
            count(*) FILTER (WHERE r.chemistry_certainty_code = 'unknown_pending'::text)::integer AS leaves_unknown_pending,
            min(r.rank) AS weakest_rank,
            (array_agg(r.chemistry_certainty_code ORDER BY r.rank, r.chemistry_certainty_code))[1] AS weakest_code
           FROM ranked r
          GROUP BY r.output_batch_id
        )
 SELECT ob.id AS output_batch_id,
        CASE
            WHEN a.output_batch_id IS NULL THEN 'not_recorded'::text
            WHEN a.weakest_rank = 2 THEN 'not_recorded'::text
            ELSE a.weakest_code
        END AS certainty,
    COALESCE(a.inbound_leaves, 0) AS inbound_leaves,
    COALESCE(a.leaves_single_known, 0) AS leaves_single_known,
    COALESCE(a.leaves_mixed, 0) AS leaves_mixed,
    COALESCE(a.leaves_not_recorded, 0) AS leaves_not_recorded,
    COALESCE(a.leaves_unknown_pending, 0) AS leaves_unknown_pending
   FROM output_batches ob
     LEFT JOIN agg a ON a.output_batch_id = ob.id;

COMMENT ON VIEW public.output_batch_chemistry_certainty_all IS
    'MES-6b-2(N38):每一批产出批的来料化学确定度 —— 进料叶子(batch_lineage_all,任意深度)上 chemistry_certainty_code 最弱的那一个:unknown_pending < not_recorded(NULL)< mixed < single_known;不认得的码排在最弱之下并原样报出;没有进料叶子 → not_recorded、0 张叶子。【无判据基视图,不授给任何人】—— 对外读 output_batch_chemistry_certainty。';

REVOKE ALL ON public.output_batch_chemistry_certainty_all FROM authenticated, anon;

-- db/views/output_batch_chemistry_certainty.sql
-- MES-6b-2(2026-10-15,N38;MES-6b Step 0 Q12,Tim):【一批产出批的来料化学有多确定】—— 读的就是这一张。
--   判据与 output_batches 自己的读策略逐字同一个(module.output.view):看得见这一批的人看得见它的确定度,别人一行都没有。
--   【属主权限】基视图(output_batch_chemistry_certainty_all)与它读的 batch_lineage_all 都不授给任何人 —— 叶子可能在读者读不到的进料批上,
--   而确定度是一个关于【这一批产出】的派生事实(AGENTS.md 那张表的 (a):派生的事实走属主权限,谓词写回视图体)。
--   批次页与分析证书都读它;证书在签发那一刻把它冻进快照(coa_assemble 读基视图,理由见基视图的抬头)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.

CREATE VIEW public.output_batch_chemistry_certainty WITH (security_invoker = off) AS
 SELECT output_batch_id,
    certainty,
    inbound_leaves,
    leaves_single_known,
    leaves_mixed,
    leaves_not_recorded,
    leaves_unknown_pending
   FROM output_batch_chemistry_certainty_all
  WHERE has_permission('module.output.view'::text);

COMMENT ON VIEW public.output_batch_chemistry_certainty IS
    'MES-6b-2(N38):一批产出批的来料化学确定度(最弱的进料叶子:unknown_pending < not_recorded < mixed < single_known)与各档叶子数。属主权限,谓词 = output_batches 的读策略(module.output.view)。批次页显示它,分析证书签发时冻进快照。';

GRANT SELECT ON public.output_batch_chemistry_certainty TO authenticated;
REVOKE ALL ON public.output_batch_chemistry_certainty FROM anon;

-- db/views/coa_rows.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q10 · Q14 · Q30 · Q32,Tim):【分析证书的读面】—— 清单页、证书页、批次页的证书一块、销售单页的下载都读它。
--   每一张证书一行:号、状态、那一批的批号、点名的销售单号与客户名、说话的那一份化验的编号、签发时刻与签发人(快照里冻的那一份)、
--   作废的理由与时刻、替代它的那一张的号、字节档案在不在、碰到它的那一张在等的作废申请的 label。
--   【判据 = 证书表自己的读策略】module.output.view(Q30:看证书跟着那一批的查看码)。
--   【属主权限】客户名与销售单号是【这张证书的显示标签】(AGENTS.md 常设决定 3:标签跟着单据走)—— 看得见证书的人看得见它是给谁的,
--   不必另持 module.sales.view / module.customers.view;除了名字与单号,客户与销售单的任何别的属性都不经这里。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.

CREATE VIEW public.coa_rows WITH (security_invoker = off) AS
 SELECT c.id,
    c.code,
    c.status,
    c.output_batch_id,
    ob.code AS batch_code,
    c.sales_order_id,
    so.code AS sales_order_code,
    COALESCE(cu.short_name, cu.legal_name) AS customer_name,
    c.governing_assay_id,
    ga.code AS governing_assay_code,
    c.issued_at,
    c.snapshot -> 'issuer' ->> 'name' AS issued_by_name,
    c.snapshot -> 'issuer' ->> 'position' AS issued_by_position,
    c.void_reason,
    c.voided_at,
    c.replaced_by_coa_id,
    rc.code AS replaced_by_code,
    (EXISTS ( SELECT 1
           FROM coa_issues i
          WHERE i.coa_id = c.id)) AS has_bytes,
    ( SELECT r.label
           FROM warehouse_requests r
          WHERE r.coa_id = c.id AND r.status = 'submitted'::text
         LIMIT 1) AS open_request_label
   FROM certificates_of_analysis c
     JOIN output_batches ob ON ob.id = c.output_batch_id
     JOIN assay_results ga ON ga.id = c.governing_assay_id
     LEFT JOIN sales_orders so ON so.id = c.sales_order_id
     LEFT JOIN customers cu ON cu.id = so.customer_id
     LEFT JOIN certificates_of_analysis rc ON rc.id = c.replaced_by_coa_id
  WHERE has_permission('module.output.view'::text);

COMMENT ON VIEW public.coa_rows IS
    'MES-6b-2:分析证书的读面 —— 号、状态、批号、点名的销售单号与客户名(标签跟着单据走)、说话的化验编号、签发时刻与签发人(快照里的)、作废、替代它的号、字节在不在、在等的作废申请。属主权限,谓词 = 证书表的读策略(module.output.view)。';

GRANT SELECT ON public.coa_rows TO authenticated;
REVOKE ALL ON public.coa_rows FROM anon;

-- db/views/warehouse_requests_masked.sql
-- 遮蔽伴生视图:warehouse_requests 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:amount_base → data.view_prices
--
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 Q12):仓库申请的读规则与 /inventory 那一块【已经给人看的】对齐 ——
--   持 module.inventory.view(仓库、CFO)或 module.finance.view 的人读得到申请;金额是一个价格(注销的价值),
--   没有 data.view_prices 的读者看到 NULL(屏幕上是 Restricted)。与 warehouse_requests_visible() 同一个判法。
--   于是批次 / 加工单页底的审计记录里,仓库的人看得见"谁提了注销、谁批的",看不见金额 —— 而不是整行 Restricted。
-- 【属主权限,不是 SECURITY INVOKER】理由同 processing_runs_masked:基表的 amount_base 已经收回了列权限,
--   invoker 视图会对调用者报 42501。模块谓词原样写回视图体,与基表的读策略逐行等价 —— 视图不放宽任何行访问。
-- 【一旦一张表有了 _masked 伴生,它的每一列都必须在这张视图里】(colgrant 的第二个分支)。
-- MES-6b-2:基表末尾加了 coa_id(作废分析证书的主体)—— 同一支迁移里加进列权限与本视图(AGENTS.md「给遮蔽表加列」:三件事一支迁移)。

CREATE OR REPLACE VIEW public.warehouse_requests_masked WITH (security_invoker = off) AS
 SELECT id,
    kind,
    status,
    label,
    inbound_batch_id,
    output_batch_id,
    run_id,
    cod_id,
    reason,
    snapshot,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    decided_at,
    decided_by,
    decision_notes,
    executed_at,
    result_entry_ids,
    withdrawn_at,
    withdrawn_by,
    withdraw_reason,
    created_at,
    created_by,
    coa_id
   FROM warehouse_requests
  WHERE has_permission('module.inventory.view'::text) OR has_permission('module.finance.view'::text);

-- anon 什么都不给:anon 的面只许缩小(db/anon-grants-baseline.tsv · db/check_grants.py)
REVOKE ALL ON public.warehouse_requests_masked FROM anon;

-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行
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
                  WHERE (n2.inbound_batch_id = q.batch_id OR n2.output_batch_id = q.batch_id) AND n2.opened_at >= q.found_at))) a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type))) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));;

GRANT SELECT ON public.operations_now TO authenticated;

-- ── 7 · 权限目录一行 + 它声明的查看码(与 db/tables/permissions.sql 逐字同一份)· 单据登记 COA(与 db/tables/document_types.sql 那一行同一份)──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.issue_coa', 'action', 'Issue certificates of analysis', '签发分析证书', 'Issue a certificate of analysis for an output batch, optionally for one sales order (then it states that contract''s quality limits, the judgement and the customer). Refused while the batch is on quality hold, in an open assay dispute, has no final governing assay, has a weighing out of calibration, or breaches the order''s limits without an accepted report. Also raises the CFO request that voids one.', '为一批产出批签发分析证书,可点名一张销售单(此时证书写明那份合同的质量验收限、判定与客户)。这一批在质量暂扣里、挂着开着的化验争议、没有说话的最终化验、有称重不在校准期内、或对那张单越限而报告没有被接受时一律按名拒。作废一张证书的 CFO 申请也由这个码的人提。', 1250);
UPDATE public.permissions SET requires_view_any = ARRAY['module.output.view','module.quality.view'] WHERE code = 'action.issue_coa';
INSERT INTO public.document_types (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission) VALUES
    ('coa', 'COA', 'certificates_of_analysis', 'gapless', NULL, '/quality/coa', 'detail', 'void_reason', ARRAY['void_reason']::text[], ARRAY['module.output.view']::text[]);

-- ── 8 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.certificates_of_analysis
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.certificates_of_analysis
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.coa_issues
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.coa_issues
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 9 · 授权(MES-0 Q90 · MES-6b Step 0 Q30):action.issue_coa → admin · cco —— 本刀唯一的授权改动 ──
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'action.issue_coa' FROM roles r WHERE r.code IN ('admin', 'cco')
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 10 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.issue_coa(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.issue_coa(uuid, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_coa_issue(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_coa_issue(uuid, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.submit_coa_void_request(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_coa_void_request(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.coa_certificate_data(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.coa_certificate_data(uuid, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.next_coa_code(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.next_coa_code(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_coa_mutation() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_coa_mutation() TO service_role;
REVOKE EXECUTE ON FUNCTION public.guard_coa_mutation() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_governing_assay(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.coa_governing_assay(uuid, uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.coa_governing_assay(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_output_calibration_problem(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.coa_output_calibration_problem(uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.coa_output_calibration_problem(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_issue_blockers(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.coa_issue_blockers(uuid, uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.coa_issue_blockers(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_assemble(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.coa_assemble(uuid, uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.coa_assemble(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.void_coa_internal(uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_coa_internal(uuid, text, uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.void_coa_internal(uuid, text, uuid) FROM authenticated;

-- ── 11 · 私有桶 coa-documents 与它的三条策略(桶不在镜像里 —— AGENTS.md;它的证明是 db/scripts/2026-10-15-mes6b2-live-proof.mjs 的 BUCKET 一段)──
--   只收 PDF、≤ 10 MB。读:module.output.view(看证书跟着那一批的查看码,Q30)。传:action.issue_coa(签发的那一个码)。
--   删:action.issue_coa【并且】那个对象还没被记进 coa_issues —— 签发时记哈希失败留下的孤儿可以由签发的人清掉;记下了的字节谁都删不掉
--   (作废不动字节,Q32)。改:一条策略都不给(覆盖一份已存的字节,就是改一张已签发的证书)。
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('coa-documents', 'coa-documents', false, 10485760, ARRAY['application/pdf'])
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "coa-documents read by output view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'coa-documents'::text AND public.has_permission('module.output.view'::text));

CREATE POLICY "coa-documents upload by issue_coa"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'coa-documents'::text AND public.has_permission('action.issue_coa'::text));

CREATE POLICY "coa-documents remove unrecorded by issue_coa"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'coa-documents'::text AND public.has_permission('action.issue_coa'::text)
           AND NOT EXISTS (SELECT 1 FROM public.coa_issues i WHERE i.file_path = objects.name));

-- ── 12 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes6b2_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes6b2_pending_after ON COMMIT DROP AS
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
    -- ① 授权:恰好多了 action.issue_coa 的两行,别的一行没动;admin 持目录里每一个码(79);每一个角色仍满足"动作码蕴含查看码"
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes6b2_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM mes6b2_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS DISTINCT FROM 'admin:action.issue_coa, cco:action.issue_coa' THEN
        RAISE EXCEPTION 'MES6B2_PROOF|grant change is not exactly the two issue_coa grants: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM permissions) <> 79
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES6B2_PROOF|admin does not hold every one of the 79 codes';
    END IF;
    IF (SELECT requires_view_any FROM permissions WHERE code = 'action.issue_coa') IS DISTINCT FROM ARRAY['module.output.view','module.quality.view'] THEN
        RAISE EXCEPTION 'MES6B2_PROOF|action.issue_coa must declare module.output.view and module.quality.view';
    END IF;
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6B2_PROOF|action-implies-view violated: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES6B2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes6b2_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes6b2_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES6B2_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变(仓库申请比对时减掉新列)
    IF EXISTS ((SELECT b.k, b.id FROM mes6b2_pending_before b EXCEPT SELECT a.k, a.id FROM mes6b2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes6b2_pending_after a EXCEPT SELECT b.k, b.id FROM mes6b2_pending_before b)) THEN
        RAISE EXCEPTION 'MES6B2_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'coa_id')::text, '|' ORDER BY (to_jsonb(t) - 'coa_id')::text), '')) FROM warehouse_requests t) IS DISTINCT FROM (SELECT warehouse_requests FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t) IS DISTINCT FROM (SELECT output_batches FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t) IS DISTINCT FROM (SELECT inbound_batches FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_results t) IS DISTINCT FROM (SELECT assay_results FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_result_metals t) IS DISTINCT FROM (SELECT assay_result_metals FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_result_indicators t) IS DISTINCT FROM (SELECT assay_result_indicators FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batch_metals t) IS DISTINCT FROM (SELECT output_batch_metals FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_disputes t) IS DISTINCT FROM (SELECT assay_disputes FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM nonconformance_reports t) IS DISTINCT FROM (SELECT nonconformance_reports FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM quality_limit_judgements t) IS DISTINCT FROM (SELECT quality_limit_judgements FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t) IS DISTINCT FROM (SELECT certificates_of_destruction FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t) IS DISTINCT FROM (SELECT cod_issues FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_runs t) IS DISTINCT FROM (SELECT processing_runs FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_inputs t) IS DISTINCT FROM (SELECT processing_inputs FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_outputs t) IS DISTINCT FROM (SELECT processing_outputs FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_orders t) IS DISTINCT FROM (SELECT sales_orders FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_order_lines t) IS DISTINCT FROM (SELECT sales_order_lines FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_order_reservations t) IS DISTINCT FROM (SELECT sales_order_reservations FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM shipment_lines t) IS DISTINCT FROM (SELECT shipment_lines FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contracts t) IS DISTINCT FROM (SELECT contracts FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_settlement_terms t) IS DISTINCT FROM (SELECT contract_settlement_terms FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_document_terms t) IS DISTINCT FROM (SELECT contract_document_terms FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inventory_movements t) IS DISTINCT FROM (SELECT inventory_movements FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM weighings t) IS DISTINCT FROM (SELECT weighings FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM instrument_calibrations t) IS DISTINCT FROM (SELECT instrument_calibrations FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM company_profile t) IS DISTINCT FROM (SELECT company_profile FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t) IS DISTINCT FROM (SELECT employees FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM positions t) IS DISTINCT FROM (SELECT positions FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM customers t) IS DISTINCT FROM (SELECT customers FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t) IS DISTINCT FROM (SELECT approval_log FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t) IS DISTINCT FROM (SELECT journal_entries FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t) IS DISTINCT FROM (SELECT journal_lines FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t) IS DISTINCT FROM (SELECT payments FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t) IS DISTINCT FROM (SELECT expenses FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM invoice_requests t) IS DISTINCT FROM (SELECT invoice_requests FROM mes6b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM receipt_price_requests t) IS DISTINCT FROM (SELECT receipt_price_requests FROM mes6b2_rows_before) THEN
        RAISE EXCEPTION 'MES6B2_PROOF|a pre-existing request, batch, assay, dispute, report, certificate, run, order, reservation, contract, movement, weighing, calibration, company, employee, position, customer, approval, journal, payment, expense or request changed';
    END IF;
    IF EXISTS (SELECT 1 FROM warehouse_requests WHERE coa_id IS NOT NULL) THEN
        RAISE EXCEPTION 'MES6B2_PROOF|coa_id must start empty on every existing request';
    END IF;

    -- ④ 两张新表零行;桶在、私有、空、三条策略
    IF EXISTS (SELECT 1 FROM certificates_of_analysis) OR EXISTS (SELECT 1 FROM coa_issues) THEN
        RAISE EXCEPTION 'MES6B2_PROOF|a new table has rows';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'coa-documents' AND NOT public)
       OR EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'coa-documents')
       OR (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname LIKE 'coa-documents %') <> 3 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|bucket coa-documents must exist, be private, be empty and carry exactly three policies';
    END IF;

    -- ⑤ 变更记录只多了本刀种的那几行:permissions 1 插 1 改 · role_permissions 2 插 · document_types 1 插
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes6b2_log_before), 0)
       AND NOT ((c.op = 'INSERT' AND c.table_name IN ('permissions', 'role_permissions', 'document_types'))
                OR (c.op = 'UPDATE' AND c.table_name = 'permissions'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6B2_PROOF|unexpected change_log rows: %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes6b2_log_before), 0);
    IF v_n <> 5 THEN RAISE EXCEPTION 'MES6B2_PROOF|change_log moved by % (expected 1 + 1 + 2 + 1 = 5)', v_n; END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6B2_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑥ 结构:守卫都在;单据登记 59 行带 COA、豁免 45 行;提醒 66 支、待定值 23 行;297 张表;审计主语 coa 在册;仓库申请认 coa_void
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_certificates_of_analysis_mutation' AND tgrelid = 'public.certificates_of_analysis'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_certificates_of_analysis_truncate' AND tgrelid = 'public.certificates_of_analysis'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_coa_issues_append_only' AND tgrelid = 'public.coa_issues'::regclass) THEN
        RAISE EXCEPTION 'MES6B2_PROOF|a guard trigger is missing';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 59 OR document_type_prefix('coa') <> 'COA'
       OR (SELECT count(*) FROM document_type_exceptions) <> 45 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|document_types should be 59 with COA and exceptions stay 45';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 66
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 23 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|operations_now should have 66 arms and pending_values 23';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 297 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|expected 297 public tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'coa') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|trail subject coa is not registered';
    END IF;
    IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'warehouse_requests_kind_check')) NOT LIKE '%coa_void%'
       OR NOT has_column_privilege('authenticated', 'public.warehouse_requests', 'coa_id', 'SELECT') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|warehouse_requests must accept coa_void and grant coa_id';
    END IF;

    -- ⑦ 函数面:五支员工调得到;六支内层与触发器调不到;anon 能执行的【恰好】两支;新表与新视图 anon 读不到
    IF NOT has_function_privilege('authenticated', 'public.issue_coa(uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.issue_coa(uuid, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|public.issue_coa(uuid, uuid) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.record_coa_issue(uuid, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_coa_issue(uuid, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|public.record_coa_issue(uuid, text, text) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.submit_coa_void_request(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.submit_coa_void_request(uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|public.submit_coa_void_request(uuid, text) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.coa_certificate_data(uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.coa_certificate_data(uuid, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|public.coa_certificate_data(uuid, uuid) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.next_coa_code(date)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.next_coa_code(date)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|public.next_coa_code(date) must be callable by staff and not by anon';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_coa_mutation()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_coa_mutation()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|public.guard_coa_mutation() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.coa_governing_assay(uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.coa_governing_assay(uuid, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|public.coa_governing_assay(uuid, uuid) must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.coa_output_calibration_problem(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.coa_output_calibration_problem(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|public.coa_output_calibration_problem(uuid) must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.coa_issue_blockers(uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.coa_issue_blockers(uuid, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|public.coa_issue_blockers(uuid, uuid) must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.coa_assemble(uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.coa_assemble(uuid, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|public.coa_assemble(uuid, uuid) must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.void_coa_internal(uuid, text, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.void_coa_internal(uuid, text, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|public.void_coa_internal(uuid, text, uuid) must be a function nobody outside can call';
    END IF;
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES6B2_PROOF|anon executes: %', v_bad;
    END IF;
    IF has_table_privilege('anon', 'public.certificates_of_analysis'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.coa_issues'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.coa_rows'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.output_batch_chemistry_certainty'::regclass, 'SELECT')
       OR has_table_privilege('authenticated', 'public.output_batch_chemistry_certainty_all'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|anon reads a new relation, or staff read the ungated base view';
    END IF;

    -- ⑧ 那 44 条开着的读策略还是 44 条;两张新表上没有写策略(只经函数)
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('certificates_of_analysis', 'coa_issues')
                 AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES6B2_PROOF|a write policy exists on certificates_of_analysis or coa_issues';
    END IF;

    -- ⑨ 变更记录:覆盖零缺口(两张新表记,豁免仍是 8);遮蔽零缺口(规则仍是 114 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes6b2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES6B2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes6b2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES6B2_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes6b2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
