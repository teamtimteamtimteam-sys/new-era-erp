-- db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql
-- MES-6b-1 —— 质量暂扣经不合格报告;卖方合同的质量验收限(V17);可计价金属也能当惩罚元素(F4);只测惩罚元素的化验是补充(F5)
--   (MES 组的第十四刀,v1.4.50;发布那一行在 docs/handbacks/MES-6b-1.md 的抬头)。
-- 由 db/scripts/build_mes6b1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-15:MES-6b Step 0 的 Q2–Q9 · Q15–Q16 · Q18–Q28 · Q33–Q42,一律照裁定)
--   ① 不合格报告(Q7):nonconformance_reports(NCR-YYYY-NNNN,按年无洞;进料 XOR 产出;来源 manual · quality_limit · customer_complaint,
--      inspection 保留;说明必填;可挂化验 / 争议 / 销售单 / 判定;open → decided 只经函数;只追加)。open_ncr(module.quality.edit)·
--      decide_ncr(action.ncr_decide;开单人永远不能决定自己那一张,按人认;系统开的任何持码人都能决定)。
--   ② 质量暂扣(Q2 · Q3):一批有一张开着的报告、或一张拒收而货还在的报告,就在暂扣里(判据 ncr_holds 一处;batch_quality_hold 读它)。
--      流水上一支 BEFORE INSERT 守卫(guard_quality_hold)按名拒 QUALITY_HOLD_OPEN|批号|报告编号:投料、销售、发货那条腿、进 committed、
--      不在 CFO 注销申请里的注销;转移、盘点、暂扣 / 释放、释放预留、收货、产出、冲销照常。结算(Q4)与配料计划的建 / 改 / 放行另外显式问。
--   ③ V17(Q8 · Q25–Q27):contract_quality_limits(卖方合同;参数 = 水分或一个指标码;可选物料;下 / 上限)· 结算口径多一列
--      quality_limit_basis(none_agreed · per_parameter;空 = 未设,卖方合同申请生效前必须设;per_parameter 而一行都没有按名拒)。
--      挂接那一刻随结算口径抄进单据的合同副本;化验登记(产出批预留给有限的单)与预留(批已有化验)两处判一次,一参数一行只追加的
--      quality_limit_judgements;越限 → 同一笔事务里开一张来源 quality_limit 的报告,预留照留。
--   ④ F4(Q15 · Q33 · Q34):惩罚条款收惩罚元素或可计价金属;同一份合同里一种物质既计价又罚,两张条款表上一支守卫按名拒
--      SUBSTANCE_PRICED_AND_PENALISED|<码>,申请生效时再问一次;结算的计价圈跳过被列为惩罚元素的可计价金属。
--   ⑤ F5(Q16 · Q36):一份一种可计价金属都没测的化验是【补充】—— 两侧的应用只换掉它测了的那几种、不计价、不顶替前一份、
--      也不被下一份顶替;撤销只删它自己那几行。预览说出它换掉哪几种。
--   ⑥ 三支提醒(ncr_open · quality_hold_reserved · quality_prompt_ncr)· V17 那一行待定值 · 单据登记 NCR · 审计主语 ncr ·
--      三张新表进变更记录(豁免仍是 8;没有遮蔽的列)· action.ncr_decide 进目录并授 cco · cto · admin。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;授权只多 action.ncr_decide 那三行;不写、不改、不冲任何一张既有单据、批次、
--   化验、合同、条款、预留、流水、结算、配料计划、费用单、付款、分录;不建任何合同、验收限、判定、报告或化验;
--   require_calibrated_since 保持空。线上由本迁移造出的只有:quality_limit_basis 那一列(空)、一个权限码与它的三条授权、
--   单据登记 NCR 那一行。
--
-- 【破窗】旧应用不认 QUALITY_HOLD_OPEN(印兜底句 + 短码)—— 但线上零张报告,所以没有一批在暂扣里,守卫一次都不会拒;
--   旧的合同页不画质量验收限、也不画 quality_limit_basis:卖方合同在部署之前【申请生效会被拒】(清单第 5 项),旧页印那一项的原码。
--   线上 0 份合同,所以窗口里没有人会撞上。窗口 ≈ 部署时长。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了 action.ncr_decide 的三行,admin 持目录里每一个码(78);
--   在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的合同、条款、化验、批次、含量、
--   流水、预留、销售单、结算、争议、样品、配料计划、仓库申请、定价申请、价格历史、开票申请、分录、费用单、付款、物质、指标、物料、
--   供应商、客户逐字未变;三张新表零行;变更记录只多了本刀种的那几行;六支新函数员工调得到、五支内层与触发器调不到;
--   anon 能执行的【恰好】两支;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 114);单据登记 58 行、
--   豁免 45 行;提醒 65 支、待定值 23 行;295 张表。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES6B1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.nonconformance_reports') IS NOT NULL OR to_regclass('public.contract_quality_limits') IS NOT NULL
       OR to_regclass('public.quality_limit_judgements') IS NOT NULL OR to_regclass('public.ncr_rows') IS NOT NULL
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'contract_settlement_terms'
                    AND column_name = 'quality_limit_basis')
       OR EXISTS (SELECT 1 FROM permissions WHERE code = 'action.ncr_decide')
       OR EXISTS (SELECT 1 FROM document_types WHERE key = 'ncr' OR prefix = 'NCR')
       OR to_regprocedure('public.batch_quality_hold(uuid, uuid)') IS NOT NULL
       OR to_regprocedure('public.guard_quality_hold()') IS NOT NULL THEN
        RAISE EXCEPTION 'MES6B1_PRE|MES-6b-1 objects already exist';
    END IF;
    IF (SELECT count(*) FROM roles WHERE code IN ('admin', 'cco', 'cto')) <> 3 THEN
        RAISE EXCEPTION 'MES6B1_PRE|expected the admin, cco and cto roles';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES6B1_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 77
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES6B1_PRE|expected a catalogue of 77 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 57 OR (SELECT count(*) FROM document_type_exceptions) <> 45 THEN
        RAISE EXCEPTION 'MES6B1_PRE|expected 57 document types and 45 exceptions';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 62 THEN
        RAISE EXCEPTION 'MES6B1_PRE|operations_now should have 62 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 22 THEN
        RAISE EXCEPTION 'MES6B1_PRE|pending_values should have 22 arms before';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES6B1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES6B1_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 292 THEN
        RAISE EXCEPTION 'MES6B1_PRE|expected 292 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6B1_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes6b1_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes6b1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes6b1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes6b1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes6b1_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contracts t) AS contracts,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'quality_limit_basis')::text, '|' ORDER BY (to_jsonb(t) - 'quality_limit_basis')::text), '')) FROM contract_settlement_terms t) AS contract_settlement_terms,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_pricing_terms t) AS contract_pricing_terms,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_penalty_elements t) AS contract_penalty_elements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_refining_charges t) AS contract_refining_charges,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_grade_specs t) AS contract_grade_specs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_document_terms t) AS contract_document_terms,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM terms_requests t) AS terms_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_results t) AS assay_results,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_result_metals t) AS assay_result_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_result_indicators t) AS assay_result_indicators,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t) AS inbound_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t) AS output_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batch_metals t) AS inbound_batch_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batch_metals t) AS output_batch_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inventory_movements t) AS inventory_movements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_order_reservations t) AS sales_order_reservations,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_orders t) AS sales_orders,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_order_lines t) AS sales_order_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_settlements t) AS sales_settlements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_disputes t) AS assay_disputes,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM samples t) AS samples,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM blending_plans t) AS blending_plans,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM blending_plan_lines t) AS blending_plan_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM warehouse_requests t) AS warehouse_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM receipt_price_requests t) AS receipt_price_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM price_history t) AS price_history,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM invoice_requests t) AS invoice_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_allocations t) AS payment_allocations,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_requests t) AS payment_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM substances t) AS substances,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_indicators t) AS assay_indicators,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM materials t) AS materials,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t) AS suppliers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM customers t) AS customers;

-- ── 1 · 新函数(镜像原样),先于新表的四支:纯判据 ncr_holds · 取号 · 报告只追加的触发器函数 · 条款守卫 ───

-- db/functions/ncr_holds.sql
-- MES-6b-1(2026-10-15,MES-0 Q66;MES-6b Step 0 Q2 · Q21,Tim):【一张不合格报告此刻扣不扣着它那一批】—— 判据只写在这里一次,而且是一支【纯】函数:
--   它只看传进来的四个值,不读任何表。于是两种读者都用得上它而不会被读规则蒙住眼:
--     · batch_quality_hold(INVOKER)以调用者的读规则读报告与批次,再问它;
--     · ncr_rows(属主视图)以属主的眼睛读批次的余量,再问它。
--   扣着 ⇔ 报告还开着;或者决定为 reject,而那一批还在(没删)、还有货(remaining_qty > 0)—— reject 不放行,暂扣留到货没了为止(Q21)。
--   别的处置(accept · accept_with_penalty · rework · downgrade)都放行。余量为空读成 0(一批没有余量缓存就是没有货)。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.ncr_holds(p_status text, p_disposition text, p_batch_deleted_at timestamp with time zone, p_remaining_qty numeric)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT COALESCE(p_status = 'open'
                    OR (p_status = 'decided' AND p_disposition = 'reject'
                        AND p_batch_deleted_at IS NULL AND COALESCE(p_remaining_qty, 0) > 0), false)
$function$;

-- db/functions/next_ncr_code.sql
-- MES-6b-1(2026-10-15,MES-0 Q53 · MES-6b Step 0 Q7):不合格报告的编号 NCR-YYYY-NNNN —— 按年、无洞,与 next_sample_code 逐行同形
--   (自己的一把 advisory lock;MAX(split_part)+1 带 LIKE 过滤;前缀从 document_types 读)。
--   ★ 宽度 GREATEST(4, 位数)(CODE-WIDTH-4):LPAD 到固定的 4 位会在第 10,000 张时把号【截短】成一个已经发过的号 —— 新的取号函数不再照抄那一句。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.next_ncr_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】NCR 与 SMP / BLD 各自连号 —— 共用一把会让一种单据烧掉另一种的号。
    PERFORM pg_advisory_xact_lock(hashtext('ncr_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM nonconformance_reports
    WHERE code LIKE document_type_prefix('ncr') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('ncr') || '-' || v_year::text || '-' || LPAD(v_seq::text, GREATEST(4, length(v_seq::text)), '0');
END;
$function$;

-- db/functions/guard_ncr_mutation.sql
-- MES-6b-1(2026-10-15,MES-6b Step 0 Q7):不合格报告【只追加】—— 一行写下就不改,唯一的例外是 open → decided 那一次,而那一次只许动决定的那几列
--   (status · disposition · decision_note · decided_at · decided_by · 两张钱的单据)。别的改动、任何删除一律按名拒 NCR_IMMUTABLE|<编号>|<操作>。
--   更正一张报告 = 开一张新的、在描述里指出旧的那一张(Q7)。
--   【属主路径同样受它管】它守的是记录的形状(一张决定过的报告不许被改回开着,一张报告的批次与来源不许换),不是权限 —— 与
--   guard_append_only_log 同一个立场。写这张表的只有 open_ncr / decide_ncr / judge_quality_limits 三支 DEFINER 函数。
--   INVOKER:它不读别的表。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.guard_ncr_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'NCR_IMMUTABLE|%|delete', OLD.code;
    END IF;
    -- UPDATE:只认 open → decided,而且除了决定那几列,一个字都不许变
    IF OLD.status <> 'open' OR NEW.status <> 'decided'
       OR (to_jsonb(NEW) - 'status' - 'disposition' - 'decision_note' - 'decided_at' - 'decided_by'
                         - 'penalty_invoice_request_id' - 'penalty_price_request_id')
          IS DISTINCT FROM
          (to_jsonb(OLD) - 'status' - 'disposition' - 'decision_note' - 'decided_at' - 'decided_by'
                         - 'penalty_invoice_request_id' - 'penalty_price_request_id') THEN
        RAISE EXCEPTION 'NCR_IMMUTABLE|%|update', OLD.code
          USING HINT = '一张不合格报告只在【决定】那一次改得动(open → decided,只动决定那几列)。要更正,开一张新的、在描述里指出这一张。';
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_substance_priced_and_penalised.sql
-- MES-6b-1(2026-10-15,F4;MES-6b Step 0 Q33,Tim):【一种物质在一份合同里要么计价、要么罚,不两者都是】。
--   此前两条都成立时结算两样都做:按含量付钱、扣精炼费,再按超阈值罚(sale_settlement_compute 的两圈互不相看)—— 没有任何东西挡着。
--   从 F4 起惩罚条款也收可计价的金属(铜作为镍黑粉里的杂质),于是这一条必须在【条款】这一层就拒:
--     contract_pricing_terms   BEFORE INSERT OR UPDATE OF metal, contract_id     —— 同一份合同的惩罚条款里已经有它
--     contract_penalty_elements BEFORE INSERT OR UPDATE OF substance, contract_id —— 同一份合同的计价条款里已经有它
--   → SUBSTANCE_PRICED_AND_PENALISED|<码>。申请生效时 contract_activation_missing 再问一次(条款表之外的写路、或这一道之前写下的行)。
--   【属主路径同样受它管】它守的是条款的一致性,不是权限(与 guard_substance_role 同一个立场)。
--   SECURITY DEFINER:对面那张表的读策略认码(客户 / 供应商查看),一个只持 action.contract_terms 的写者读不到它也不能因此放过去 ——
--   void 断言读不到就是放行(INVOKER-JOIN 那一族),所以这里借属主的眼睛。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.guard_substance_priced_and_penalised()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_TABLE_NAME = 'contract_pricing_terms' THEN
        IF EXISTS (SELECT 1 FROM contract_penalty_elements pe
                    WHERE pe.contract_id = NEW.contract_id AND pe.substance = NEW.metal) THEN
            RAISE EXCEPTION 'SUBSTANCE_PRICED_AND_PENALISED|%', NEW.metal
              USING HINT = '这份合同的惩罚条款里已经有这种物质 —— 一种物质在一份合同里要么计价、要么罚。';
        END IF;
    ELSE
        IF EXISTS (SELECT 1 FROM contract_pricing_terms pt
                    WHERE pt.contract_id = NEW.contract_id AND pt.metal = NEW.substance) THEN
            RAISE EXCEPTION 'SUBSTANCE_PRICED_AND_PENALISED|%', NEW.substance
              USING HINT = '这份合同的计价条款里已经有这种物质 —— 一种物质在一份合同里要么计价、要么罚。';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 2 · 结算口径多一列(与 db/tables/contract_settlement_terms.sql 逐字同一份的约束与注释;可空 = V17 未设,不给默认值)────
ALTER TABLE public.contract_settlement_terms ADD COLUMN
    quality_limit_basis text
        CHECK (quality_limit_basis IS NULL OR quality_limit_basis IN ('none_agreed', 'per_parameter'));
COMMENT ON COLUMN public.contract_settlement_terms.quality_limit_basis IS
    'MES-6b-1(V17;MES-6b Step 0 Q25):质量验收限(水分、粒径、任何一个化验指标)的口径声明 —— none_agreed(声明了没有限)· per_parameter(有,行在 contract_quality_limits)。**可空 = V17 Not yet set,不给默认值**:没声明不是"没有限"。卖方合同申请生效要它;per_parameter 而没有一行限按名拒 QUALITY_LIMITS_NOT_FILED(本表中心句的第四个实例,SETTLE-1 ③ 的同一个形状)。挂接那一刻随结算口径一起抄进单据的合同副本,判定(judge_quality_limits)只读那一份。';

-- ── 3 · 新表(镜像原样):质量验收限 · 判定 · 不合格报告(外键次序)─────────────────────────────────────────────

-- db/tables/contract_quality_limits.sql
-- MES-6b-1(2026-10-15,MES-6a Step 0 Q5 · V17;MES-6b Step 0 Q8 · Q25 · Q26,Tim):【卖方合同的质量验收限】—— 水分与粒径(以及任何一个化验指标)
--   的上 / 下限,逐份合同、可以按物料分。合同的第八张条款表,与品位规格(contract_grade_specs)是兄弟:品位规格的 metal 是指向 substances 的外键,
--   装不下水分与指标,所以另开一张(Step 0 §1.4)。
--
--   【参数】parameter = 'moisture_pct'(化验自己那一列水分)或 assay_indicators 里的一个码(残粉 · 箔纯度 · D10 / D50 / D90)。
--     一对 CHECK / 外键把它钉住:indicator 是由 parameter 算出来的存储列(水分时为空),外键指 assay_indicators(code) ——
--     于是一个不在字典里的指标写不进来,而水分不需要字典。
--   【界】min_value 与 / 或 max_value(至少一个),不小于 0;水分另有 ≤ 100。下界不高于上界。
--   【按物料】material_id 可空 = 这份合同的每一种物料;指了物料的那一行对那种物料优先于空的那一行(与配料计划抄品位规格同一个规矩)。
--     一份合同 × 物料 × 参数一行(NULLS NOT DISTINCT:两条"每一种物料"的同参数行也是重复)。
--   【冻结】与另外七张条款表同一套:写 action.contract_terms;合同生效中 / 有在等的生效申请 / 到期 / 终止时直连写按名拒
--     CONTRACT_TERMS_FROZEN(guard_contract_terms_frozen);挂接销售单那一刻随结算口径一起抄进 contract_document_terms.settlement_terms
--     的 quality_limits(link_document_to_contract),以后合同再改【不】回头判(Q26)。
--   【声明】contract_settlement_terms.quality_limit_basis:'none_agreed' = 声明了没有限;'per_parameter' = 有,行在本表;空 = V17 Not yet set。
--     卖方合同申请生效要它(contract_activation_missing),per_parameter 而本表没有行按名拒 QUALITY_LIMITS_NOT_FILED(SETTLE-1 ③ 那一条)。
--   【只有卖方】条款编辑器把这一段放在卖方那一侧(termSpecs SELL_ONLY,与计价 / 结算 / 精炼费 / 惩罚同一个处置);判定只读挂在销售单上的副本,
--     所以一行写在买方合同上的限永远不被判(Q28:没有买方的 V17)。
--   【没有金额】—— 没有遮蔽的列(Q39)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contract_quality_limits (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id  uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,
    -- 可空 = 这份合同的每一种物料
    material_id  uuid REFERENCES public.materials (id),
    parameter    text NOT NULL CHECK (btrim(parameter) = parameter AND parameter <> ''),
    -- 由 parameter 算出来:水分时为空,否则就是那个指标码 —— 外键把它钉在字典上
    indicator    text GENERATED ALWAYS AS (CASE WHEN parameter = 'moisture_pct' THEN NULL ELSE parameter END) STORED
                 REFERENCES public.assay_indicators (code),
    min_value    numeric CHECK (min_value IS NULL OR min_value >= 0),
    max_value    numeric CHECK (max_value IS NULL OR max_value >= 0),
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    CONSTRAINT contract_quality_limits_a_bound CHECK (min_value IS NOT NULL OR max_value IS NOT NULL),
    CONSTRAINT contract_quality_limits_bounds_order CHECK (min_value IS NULL OR max_value IS NULL OR min_value <= max_value),
    CONSTRAINT contract_quality_limits_moisture_pct CHECK (
        parameter <> 'moisture_pct' OR (COALESCE(min_value, 0) <= 100 AND COALESCE(max_value, 0) <= 100)),
    CONSTRAINT contract_quality_limits_one_per_parameter UNIQUE NULLS NOT DISTINCT (contract_id, material_id, parameter)
);

CREATE INDEX idx_contract_quality_limits_contract ON public.contract_quality_limits (contract_id);
CREATE INDEX contract_quality_limits_material_id_rel ON public.contract_quality_limits (material_id);
CREATE INDEX contract_quality_limits_indicator_rel ON public.contract_quality_limits (indicator);

COMMENT ON TABLE public.contract_quality_limits IS
    'MES-6b-1(V17;MES-6b Step 0 Q8 · Q25 · Q26):卖方合同的质量验收限 —— 参数(moisture_pct 或一个化验指标码)× 可选物料 × 上 / 下限。合同的第八张条款表:写 action.contract_terms,与另外七张一起冻结(CONTRACT_TERMS_FROZEN),挂接那一刻随结算口径抄进 contract_document_terms.settlement_terms.quality_limits,以后不回头判。有没有限由 contract_settlement_terms.quality_limit_basis 声明(none_agreed / per_parameter;空 = V17 Not yet set)。判定在 judge_quality_limits:一批产出批的化验遇上一张挂着这份合同的销售单上的预留时,越限就开一张 quality_limit 的不合格报告(→ 质量暂扣)。没有金额。';
COMMENT ON COLUMN public.contract_quality_limits.parameter IS
    'moisture_pct(化验那一列水分,%)或 assay_indicators 的一个码(residual_powder_pct · foil_purity_pct · d10_um · d50_um · d90_um)。单位跟着那个参数自己的单位走(% 或 µm)。';
COMMENT ON COLUMN public.contract_quality_limits.indicator IS
    '由 parameter 算出来的存储列:水分时为空,否则等于 parameter —— 它只是为了让外键把指标码钉在 assay_indicators 上(一对 CHECK / 外键,Step 0 Q8)。不要直接写它。';

ALTER TABLE public.contract_quality_limits ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract quality limits select by owner permission"
    ON public.contract_quality_limits AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));
-- 写条款只归 cco(action.contract_terms),与另外七张条款表同一条(ROLE-1 Batch 2b)。
CREATE POLICY "contract quality limits write by owner permission"
    ON public.contract_quality_limits AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('action.contract_terms'::text))
    WITH CHECK (has_permission('action.contract_terms'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.contract_quality_limits TO authenticated;
REVOKE ALL ON public.contract_quality_limits FROM anon;

-- SILENT-1 的语句级闸:被 RLS 挡下的改 / 删不许是一次"成功的空操作"(与另外七张条款表同一支)。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_quality_limits
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.contract_terms');

-- APR-8 的冻结:生效中、或挂着一张在等的生效申请时,直连写按名拒 CONTRACT_TERMS_FROZEN。属主路径放行。
CREATE TRIGGER trg_contract_quality_limits_frozen
    BEFORE INSERT OR UPDATE OR DELETE ON public.contract_quality_limits
    FOR EACH ROW EXECUTE FUNCTION public.guard_contract_terms_frozen();

-- db/tables/quality_limit_judgements.sql
-- MES-6b-1(2026-10-15,V17;MES-6b Step 0 Q26 · Q27,Tim):【一次质量验收限的判定】—— 一批产出批的一份化验,对着一张销售单挂着的合同副本里
--   的一个参数,判出来是什么。只追加,一行写下就不改不删(guard_append_only_log)。
--
--   【什么时候判】(judge_quality_limits,内层)两个时刻:
--     · record_assay_result 记下一份产出化验,而这一批已经预留给一张挂着【有限】的合同的销售单(trigger_event = 'assay_recorded');
--     · reserve_stock_internal 把一批【已经有化验】的产出批预留给这样一张销售单(trigger_event = 'reserved')。
--   【判哪一份化验】合同结算口径约定的那一方(settling_party)最新的一份没删的结果;那一批有过一件已结案、点名了说了算的那一份的争议时,
--     读那一份(governing_assay_id)—— 与结算选化验同一条规矩。
--   【判什么】那张销售单的合同副本(contract_document_terms.settlement_terms)里 quality_limit_basis = per_parameter 时,它的 quality_limits
--     里【适用于这批物料】的每一个参数(指了这种物料的那一行优先于空物料的那一行)。限【抄进本行】(limit_min_at / limit_max_at):
--     以后谁也改不了一条旧判定的依据 —— 合同改了也不回头判(Q26;副本本来就是挂接那一刻冻下的)。
--   【结果】within · below_min · above_max · not_measured(那份化验没报这个参数:value 为空 —— 空永远不是零,也不是"在限内",C3)。
--   【一次】(批 × 销售单 × 化验 × 参数)一行(唯一约束):同一份化验对同一张单的同一个参数只判一次 —— 部分发货就地重新预留、或同一张单的
--     第二行预留同一批,都不会再判一遍。一份【新的】化验是一个新的事实,照判。
--   【越限】below_min / above_max → 同一笔事务里开一张来源 quality_limit 的不合格报告(nonconformance_reports.judgement_id 指回本行)
--     → 这一批进质量暂扣(Q27:预留照留,不拒;发货被暂扣挡住)。not_measured 不开。
--   【读】module.quality.view,或产出批的查看码(判定挂在批次上,Q39)。写:一条策略都没有 —— 只经 judge_quality_limits。没有金额。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.quality_limit_judgements (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    output_batch_id  uuid NOT NULL REFERENCES public.output_batches (id),
    sales_order_id   uuid NOT NULL REFERENCES public.sales_orders (id),
    contract_id      uuid NOT NULL REFERENCES public.contracts (id),
    assay_result_id  uuid NOT NULL REFERENCES public.assay_results (id),
    parameter        text NOT NULL,
    -- 判的那个值:水分取化验的 moisture_pct,指标取 assay_result_indicators;没报 = 空
    value            numeric,
    -- 判的那一刻在效的限,抄下来(V36 · V11 · V9 的先例:range_min_at · warning_pct_at · pass_voltage_v_at)
    limit_min_at     numeric,
    limit_max_at     numeric,
    result           text NOT NULL CHECK (result IN ('within', 'below_min', 'above_max', 'not_measured')),
    trigger_event    text NOT NULL CHECK (trigger_event IN ('assay_recorded', 'reserved')),
    judged_at        timestamptz NOT NULL DEFAULT now(),
    judged_by        uuid DEFAULT auth.uid(),
    CONSTRAINT quality_limit_judgements_once UNIQUE (output_batch_id, sales_order_id, assay_result_id, parameter),
    CONSTRAINT quality_limit_judgements_a_limit CHECK (limit_min_at IS NOT NULL OR limit_max_at IS NOT NULL),
    -- 【结果与它的证据必须同时成立】没报 ⇔ 没有值;越下限 ⇔ 有下限且值低于它;越上限 ⇔ 有上限且值高于它
    CONSTRAINT quality_limit_judgements_result_consistent CHECK (
        (result = 'not_measured' AND value IS NULL)
        OR (result = 'below_min' AND value IS NOT NULL AND limit_min_at IS NOT NULL AND value < limit_min_at)
        OR (result = 'above_max' AND value IS NOT NULL AND limit_max_at IS NOT NULL AND value > limit_max_at
            AND (limit_min_at IS NULL OR value >= limit_min_at))
        OR (result = 'within' AND value IS NOT NULL
            AND (limit_min_at IS NULL OR value >= limit_min_at) AND (limit_max_at IS NULL OR value <= limit_max_at)))
);

CREATE INDEX quality_limit_judgements_output_batch_id_rel ON public.quality_limit_judgements (output_batch_id);
CREATE INDEX quality_limit_judgements_sales_order_id_rel ON public.quality_limit_judgements (sales_order_id);
CREATE INDEX quality_limit_judgements_contract_id_rel ON public.quality_limit_judgements (contract_id);
CREATE INDEX quality_limit_judgements_assay_result_id_rel ON public.quality_limit_judgements (assay_result_id);

COMMENT ON TABLE public.quality_limit_judgements IS
    'MES-6b-1(V17;Step 0 Q26 · Q27):一次质量验收限的判定 —— 一批产出批 × 一张销售单(它的合同副本)× 一份化验(合同约定一方最新的那份,或已结案争议点名的那份)× 一个参数,一行。限抄进本行,合同以后改了不回头判;同一份化验对同一张单的同一个参数只判一次。结果 within / below_min / above_max / not_measured(没报 ≠ 在限内)。越限在同一笔事务里开一张 quality_limit 的不合格报告(→ 质量暂扣)。只追加;只经 judge_quality_limits 写;读 module.quality.view 或产出批的查看码。';
COMMENT ON COLUMN public.quality_limit_judgements.trigger_event IS
    '判在哪一刻:assay_recorded(record_assay_result 记下一份产出化验,而这一批已预留给这张单)· reserved(reserve_stock_internal 把一批已有化验的产出批预留给这张单)。';

ALTER TABLE public.quality_limit_judgements ENABLE ROW LEVEL SECURITY;
-- 读:质量查看码,或产出批的查看码(Q39:判定挂在批次上)。写:一条策略都不给 —— 只经 judge_quality_limits。
CREATE POLICY "quality limit judgements select by permission" ON public.quality_limit_judgements
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.quality.view'::text) OR has_permission('module.output.view'::text));
GRANT SELECT ON public.quality_limit_judgements TO authenticated;
REVOKE ALL ON public.quality_limit_judgements FROM anon;

-- 只追加:改、删、清空一律语句级拒 APPEND_ONLY|<表>|<操作>(没有写策略时行级触发器在 RLS 那里醒不过来 —— guard_append_only_log 的理由)
CREATE TRIGGER trg_quality_limit_judgements_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.quality_limit_judgements
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

-- db/tables/nonconformance_reports.sql
-- MES-6b-1(2026-10-15,MES-0 功能 17 · Q53 · Q65 · Q66;MES-6b Step 0 Q2 · Q7 · Q9 · Q21 · Q22,Tim):【一张不合格报告(NCR)】——
--   有人(或系统)说"这一批货有问题,先别动它",直到另一个人决定怎么处置。
--
--   【它就是质量暂扣】(Q2):一批货在【它有一张 open 的不合格报告】期间处于质量暂扣 —— 没有第二张"暂扣"表,一件事一条记录、一条放行的路。
--     手动暂扣 = 开一张来源 manual 的报告。hold_stock / release_stock(库存桶 on_hold)仍是它自己那件库存动作,与这里无关。
--     暂扣挡什么、放什么在流水上的那一道守卫里(guard_quality_hold,inventory_movements BEFORE INSERT);另外三处明着问:销售结算
--     (sale_settlement_compute)与配料计划(建 / 改不收、放行拒)。判"这一批此刻是不是被暂扣"只有一支:batch_quality_hold。
--   【编号】NCR-YYYY-NNNN,按年、无洞(next_ncr_code;document_types 的 'ncr';宽度 GREATEST(4, 位数) —— CODE-WIDTH-4)。
--   【父】恰好一批 —— 进料批或产出批(num_nonnulls = 1)。一批可以同时有几张开着的;暂扣持续到【每一张】都决定了(Q7)。
--   【来源】manual(人开的)· customer_complaint(客户投诉,人开的)· quality_limit(系统开的:一次 V17 越限,judgement_id 指那一行判定)·
--     inspection(留给 MES-7b 的来料检验,今天开不出来 —— open_ncr 按名拒)。【只有 V17 越限自动开】(Q6):来料品位违反、交叉污染过 V11、
--     放电失败只在提醒(quality_prompt_ncr)里提示人去开一张。
--   【可选的指向】一份化验、一件化验争议、一张销售单(只有产出批有)、一行判定 —— 都必须是同一批的(open_ncr 判)。
--   【两态】open → decided,只经函数(Q7):
--     open     open_ncr(module.quality.edit;人开的)/ judge_quality_limits(系统开的,opened_by 为空)。描述必填。
--              人开的:除开单人这个【人】之外,没有一个真持有人持 action.ncr_decide,就不让它生下来(NCR_NO_OTHER_DECIDER —— 否则它是一张
--              永远决定不了的报告,而它挡着那一批货)。
--     decided  decide_ncr(action.ncr_decide;cco · cto · admin)—— 处置 + 一句说明 + 谁、什么时候。【开单人永远不能决定自己开的那一张】
--              (forbid_self_approval,按人认 → SELF_APPROVAL_FORBIDDEN|raiser);系统开的(opened_by 空)任何持码人都能决定(Q9)。
--   【处置】(Q22)accept 放行 · accept_with_penalty 放行,并指出钱走哪一张既有单据(产出批 → 一张贷项通知申请 invoice_requests;
--     进料批 → 一张收货定价申请 receipt_price_requests)—— 报告本身【不带金额】· rework 放行(下一张加工单就是返工)·
--     downgrade 放行,只记下(没有改等级的函数 —— 登记在 known-issues)· reject 【不放行】:暂扣留着,直到这一批没有货了 ——
--     它的出路是既有的 CFO 注销申请(Q21;流水守卫在执行那张申请时放行注销)。
--   【只追加】决定之外,一行写下就不改:open → decided 那一次只许动决定那几列;不许删(guard_ncr_mutation)。更正 = 开一张新的、在描述里
--     指出旧的那一张。写只经上面那几支 SECURITY DEFINER 函数 —— 表上一条写策略都没有。
--   【读】module.quality.view,或那一批自己那一页的查看码(批次页上的暂扣那一行给两种码任一的人看,与样品同一个处置)。
--   【没有金额】—— 没有遮蔽的列(Q39)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.nonconformance_reports (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                        text NOT NULL UNIQUE,
    inbound_batch_id            uuid REFERENCES public.inbound_batches (id),
    output_batch_id             uuid REFERENCES public.output_batches (id),
    source                      text NOT NULL CHECK (source IN ('manual', 'customer_complaint', 'quality_limit', 'inspection')),
    description                 text NOT NULL CHECK (btrim(description) <> ''),
    -- 可选的指向:都必须是同一批的(open_ncr 判;系统开的那一张由 judge_quality_limits 填)
    assay_result_id             uuid REFERENCES public.assay_results (id),
    assay_dispute_id            uuid REFERENCES public.assay_disputes (id),
    sales_order_id              uuid REFERENCES public.sales_orders (id),
    judgement_id                bigint REFERENCES public.quality_limit_judgements (id),
    status                      text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'decided')),
    opened_at                   timestamptz NOT NULL DEFAULT now(),
    -- 空 = 系统开的(quality_limit);人开的是开单人的账号
    opened_by                   uuid,
    disposition                 text CHECK (disposition IN ('accept', 'accept_with_penalty', 'reject', 'rework', 'downgrade')),
    decision_note               text,
    decided_at                  timestamptz,
    decided_by                  uuid,
    -- accept_with_penalty 时钱走的那一张既有单据:产出批 → 贷项通知申请;进料批 → 收货定价申请(Q22)
    penalty_invoice_request_id  uuid REFERENCES public.invoice_requests (id),
    penalty_price_request_id    uuid REFERENCES public.receipt_price_requests (id),
    CONSTRAINT nonconformance_reports_one_batch CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    CONSTRAINT nonconformance_reports_sales_order_on_output CHECK (sales_order_id IS NULL OR output_batch_id IS NOT NULL),
    -- 系统开的 ⇔ 没有开单人,并且必须指着它那一行判定
    CONSTRAINT nonconformance_reports_system_opened CHECK (
        (source = 'quality_limit') = (opened_by IS NULL)
        AND (source <> 'quality_limit' OR judgement_id IS NOT NULL)),
    -- 【状态与它的证据必须同时成立】(配料计划、争议那几条 CHECK 的同一个理由:约束对任何写入者都成立)
    CONSTRAINT nonconformance_reports_decided_consistent CHECK (
        (status = 'open' AND disposition IS NULL AND decision_note IS NULL AND decided_at IS NULL AND decided_by IS NULL)
        OR (status = 'decided' AND disposition IS NOT NULL AND decision_note IS NOT NULL AND btrim(decision_note) <> ''
            AND decided_at IS NOT NULL AND decided_by IS NOT NULL)),
    -- 带罚的接受恰好指一张钱的单据,而且是这一批那一侧的那一种;别的处置一张都不指
    CONSTRAINT nonconformance_reports_penalty_document CHECK (
        (disposition IS DISTINCT FROM 'accept_with_penalty'
            AND penalty_invoice_request_id IS NULL AND penalty_price_request_id IS NULL)
        OR (disposition = 'accept_with_penalty' AND output_batch_id IS NOT NULL
            AND penalty_invoice_request_id IS NOT NULL AND penalty_price_request_id IS NULL)
        OR (disposition = 'accept_with_penalty' AND inbound_batch_id IS NOT NULL
            AND penalty_price_request_id IS NOT NULL AND penalty_invoice_request_id IS NULL))
);

CREATE INDEX nonconformance_reports_inbound_batch_id_rel ON public.nonconformance_reports (inbound_batch_id);
CREATE INDEX nonconformance_reports_output_batch_id_rel ON public.nonconformance_reports (output_batch_id);
CREATE INDEX nonconformance_reports_assay_result_id_rel ON public.nonconformance_reports (assay_result_id);
CREATE INDEX nonconformance_reports_assay_dispute_id_rel ON public.nonconformance_reports (assay_dispute_id);
CREATE INDEX nonconformance_reports_sales_order_id_rel ON public.nonconformance_reports (sales_order_id);
CREATE INDEX nonconformance_reports_judgement_id_rel ON public.nonconformance_reports (judgement_id);
CREATE INDEX nonconformance_reports_penalty_invoice_request_id_rel ON public.nonconformance_reports (penalty_invoice_request_id);
CREATE INDEX nonconformance_reports_penalty_price_request_id_rel ON public.nonconformance_reports (penalty_price_request_id);
-- 搜索:code 的后缀匹配(与 samples 同一条)
CREATE INDEX nonconformance_reports_code_trgm ON public.nonconformance_reports USING gin (code extensions.gin_trgm_ops);

COMMENT ON TABLE public.nonconformance_reports IS
    'MES-6b-1:一张不合格报告(NCR-YYYY-NNNN)—— 恰好一批(进料或产出)。它开着,那一批就在质量暂扣里(Step 0 Q2:没有另一张暂扣表;判据只有 batch_quality_hold):流水上不许投料、销售、发货、预留(guard_quality_hold),结算与配料计划也不收。来源 manual / customer_complaint(人开,module.quality.edit)· quality_limit(V17 越限时系统开)· inspection(留给 MES-7b)。open → decided 只经 decide_ncr(action.ncr_decide;开单人按人认永远不能决定自己那一张;系统开的任何持码人都能决定)。处置 accept / accept_with_penalty(指出钱走的那张贷项通知申请或收货定价申请,报告不带金额)/ rework / downgrade 放行;reject 不放行,出路是 CFO 注销申请,货没了暂扣就结束。决定之外只追加。';
COMMENT ON COLUMN public.nonconformance_reports.opened_by IS
    '开单人的账号;空 = 系统开的(来源 quality_limit:一次 V17 越限)。四眼认的就是它 —— 人开的那一张开单人这个人永远不能决定;系统开的没有开单人,任何持 action.ncr_decide 的人都能决定(Step 0 Q9)。';
COMMENT ON COLUMN public.nonconformance_reports.disposition IS
    '处置(MES-0 Q65):accept 放行 · accept_with_penalty 放行,钱走 penalty_invoice_request_id / penalty_price_request_id 指的那张既有单据 · rework 放行(下一张加工单就是返工)· downgrade 放行,只记下(今天没有改等级的函数)· reject 不放行 —— 暂扣留到这一批没有货(出路是 CFO 注销申请)。';

ALTER TABLE public.nonconformance_reports ENABLE ROW LEVEL SECURITY;
-- 读:质量查看码,或那一批自己那一页的查看码。写:一条策略都不给 —— 只经 open_ncr / decide_ncr / judge_quality_limits。
CREATE POLICY "nonconformance_reports select by permission" ON public.nonconformance_reports
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.quality.view'::text)
        OR (inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)));
GRANT SELECT ON public.nonconformance_reports TO authenticated;
REVOKE ALL ON public.nonconformance_reports FROM anon;

-- 只追加,唯一的例外是 open → decided 那一次(只许动决定那几列);不许删、不许清空。属主路径同样受它管 —— 它守的是记录的形状,不是权限。
CREATE TRIGGER trg_nonconformance_reports_mutation
    BEFORE UPDATE OR DELETE ON public.nonconformance_reports
    FOR EACH ROW EXECUTE FUNCTION public.guard_ncr_mutation();
CREATE TRIGGER trg_nonconformance_reports_truncate
    BEFORE TRUNCATE ON public.nonconformance_reports
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

-- ── 4 · 新函数(镜像原样),新表之后:开 / 决定 / 判定 / 流水守卫 · 暂扣的判据 · 一份化验是不是补充 ──────────────────────

-- db/functions/ncr_open_internal.sql
-- MES-6b-1(2026-10-15,MES-6b Step 0 Q7):落一张不合格报告 —— 取号、写一行 open。两个调用方各自先把关:
--   open_ncr(人开的:module.quality.edit、来源、描述、指向是不是同一批、除了开单人还有没有人能决定)与
--   judge_quality_limits(系统开的:一次 V17 越限,opened_by 为空)。
--   ★ 内层算子:不问码、不判来源;EXECUTE 已从 authenticated 收回(zzz_function_grants)。返回 {ncr_id, code}。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.ncr_open_internal(p_inbound_batch_id uuid, p_output_batch_id uuid, p_source text, p_description text, p_assay_result_id uuid, p_assay_dispute_id uuid, p_sales_order_id uuid, p_judgement_id bigint, p_opened_by uuid)
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
                                        assay_result_id, assay_dispute_id, sales_order_id, judgement_id, opened_by)
    VALUES (v_id, v_code, p_inbound_batch_id, p_output_batch_id, p_source, btrim(p_description),
            p_assay_result_id, p_assay_dispute_id, p_sales_order_id, p_judgement_id, p_opened_by);
    RETURN jsonb_build_object('ncr_id', v_id, 'code', v_code);
END;
$function$;

-- db/functions/open_ncr.sql
-- MES-6b-1(2026-10-15,MES-0 Q65 · Q66;MES-6b Step 0 Q2 · Q7 · Q9,Tim):【开一张不合格报告】—— 人开的那一种(manual · customer_complaint);
--   开下来这一批就在质量暂扣里(batch_quality_hold),直到另一个人决定它。module.quality.edit(取样、立争议的同一个码;admin · cco · cto)。
--
--   判的顺序就是人下一步该改什么的顺序:
--     ① 恰好一批(NCR_ONE_BATCH),存在、没删(INBOUND_NOT_FOUND / OUTPUT_NOT_FOUND)。
--     ② 来源:manual · customer_complaint;quality_limit 只由系统开(NCR_SOURCE_SYSTEM_ONLY —— 一次 V17 越限由判定当场开,人不替它开);
--        inspection 留给 MES-7b(NCR_SOURCE_RESERVED|inspection);别的 NCR_SOURCE_INVALID|<值>。
--     ③ 描述必填(NCR_DESCRIPTION_REQUIRED)。
--     ④ 可选的指向都必须是同一批的:化验、争议、判定(NCR_LINK_NOT_FOR_BATCH|<种类>|<编号或 id>);销售单只有产出批有
--        (NCR_SALES_ORDER_OUTPUT_ONLY),而且必须是这一批预留过或发过的那几张之一(NCR_LINK_NOT_FOR_BATCH|sales_order|<单号>)。
--     ⑤ ★ 除了开单人这个【人】之外,没有一个真持有人持 action.ncr_decide → 不让它生下来(NCR_NO_OTHER_DECIDER)—— 开单人永远不能决定
--        自己开的那一张,于是没有别人的时候它会是一张永远决定不了、却一直扣着货的报告(配料计划 BLEND_NO_OTHER_RELEASER 同一句判据:
--        real_role_grants · self_leg 按人认,跨账号;不看审批开关)。
--   一批可以同时有几张开着的(Q7)—— 本支不拒"已经有一张开着"。返回 {ncr_id, code, status}。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.open_ncr(p_source text, p_description text, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_assay_result_id uuid DEFAULT NULL::uuid, p_assay_dispute_id uuid DEFAULT NULL::uuid, p_sales_order_id uuid DEFAULT NULL::uuid, p_judgement_id bigint DEFAULT NULL::bigint)
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
    ELSIF p_source IS NULL OR p_source NOT IN ('manual', 'customer_complaint') THEN
        RAISE EXCEPTION 'NCR_SOURCE_INVALID|%', COALESCE(p_source, '?');
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
                             p_assay_result_id, p_assay_dispute_id, p_sales_order_id, p_judgement_id, v_user);
    RETURN v_r || jsonb_build_object('status', 'open');
END;
$function$;

-- db/functions/decide_ncr.sql
-- MES-6b-1(2026-10-15,MES-0 Q65 · Q66;MES-6b Step 0 Q9 · Q21 · Q22,Tim):【决定一张不合格报告】—— action.ncr_decide(cco · cto · admin)。
--   open → decided,只此一次(之后报告只追加,guard_ncr_mutation)。
--   ★ 开单人这个【人】永远不能决定自己开的那一张(forbid_self_approval,按人认 → SELF_APPROVAL_FORBIDDEN|raiser;同一个人的另一个账号也算)。
--     系统开的(来源 quality_limit,opened_by 为空)没有开单人,任何持码人都能决定(Q9)。不是一张审批单据:四眼是工单那一种,不进审批引擎,
--     审批开关不管它(NCR 的处置是一个质量决定;钱走既有的、自己有审批的单据)。
--   处置(Q22):
--     accept               放行
--     accept_with_penalty  放行,并【指出钱走哪一张既有单据】—— 产出批:一张贷项通知申请(invoice_requests,kind = credit_note);
--                          进料批:这一批的一张收货定价申请(receipt_price_requests)。那一张必须还活着(在等或已批)。报告本身不带金额。
--     rework               放行(下一张加工单就是返工)
--     downgrade            放行,只记下(今天没有改等级的函数 —— 登记在 known-issues)
--     reject               【不放行】:暂扣留到这一批没有货(batch_quality_hold);出路是既有的 CFO 注销申请(Q21)
--   说明必填(NCR_DECISION_NOTE_REQUIRED)。返回 {ncr_id, code, status, disposition, batch_still_held, held_by}:同一批上可能还有别的开着的报告,
--   所以"这一张决定了"不等于"这一批放行了" —— 后者由 batch_quality_hold 当场再问一次。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.decide_ncr(p_ncr_id uuid, p_disposition text, p_note text, p_penalty_invoice_request_id uuid DEFAULT NULL::uuid, p_penalty_price_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_n    nonconformance_reports%ROWTYPE;
    v_hold record;
BEGIN
    PERFORM require_permission('action.ncr_decide');
    SELECT * INTO v_n FROM nonconformance_reports WHERE id = p_ncr_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'NCR_NOT_FOUND|%', COALESCE(p_ncr_id::text, '?');
    END IF;
    IF v_n.status <> 'open' THEN
        RAISE EXCEPTION 'NCR_NOT_OPEN|%|%', v_n.code, v_n.status;
    END IF;
    -- 开单人这个人不决定自己那一张;系统开的(opened_by 为空)这一句放行 —— self_leg 的 NULL 一律不匹配
    PERFORM forbid_self_approval(v_n.opened_by, NULL::uuid, 'ncr');

    IF p_disposition IS NULL OR p_disposition NOT IN ('accept', 'accept_with_penalty', 'reject', 'rework', 'downgrade') THEN
        RAISE EXCEPTION 'NCR_DISPOSITION_INVALID|%', COALESCE(p_disposition, '?');
    END IF;
    IF p_note IS NULL OR btrim(p_note) = '' THEN
        RAISE EXCEPTION 'NCR_DECISION_NOTE_REQUIRED|%', v_n.code;
    END IF;

    IF p_disposition = 'accept_with_penalty' THEN
        IF v_n.output_batch_id IS NOT NULL THEN
            IF p_penalty_invoice_request_id IS NULL OR p_penalty_price_request_id IS NOT NULL THEN
                RAISE EXCEPTION 'NCR_PENALTY_DOCUMENT_REQUIRED|%|credit_note', v_n.code
                  USING HINT = '带罚接受一批产出批:钱走一张贷项通知申请 —— 先在发票上提那一张,再在这里指出它。';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM invoice_requests r WHERE r.id = p_penalty_invoice_request_id
                              AND r.kind = 'credit_note' AND r.status IN ('submitted', 'approved')) THEN
                RAISE EXCEPTION 'NCR_PENALTY_DOCUMENT_INVALID|%|credit_note', v_n.code;
            END IF;
        ELSE
            IF p_penalty_price_request_id IS NULL OR p_penalty_invoice_request_id IS NOT NULL THEN
                RAISE EXCEPTION 'NCR_PENALTY_DOCUMENT_REQUIRED|%|price_request', v_n.code
                  USING HINT = '带罚接受一批进料:钱走这一批的一张收货定价申请 —— 先在收货页上提那一张,再在这里指出它。';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM receipt_price_requests r WHERE r.id = p_penalty_price_request_id
                              AND r.inbound_batch_id = v_n.inbound_batch_id AND r.status IN ('submitted', 'approved')) THEN
                RAISE EXCEPTION 'NCR_PENALTY_DOCUMENT_INVALID|%|price_request', v_n.code;
            END IF;
        END IF;
    ELSIF p_penalty_invoice_request_id IS NOT NULL OR p_penalty_price_request_id IS NOT NULL THEN
        RAISE EXCEPTION 'NCR_PENALTY_DOCUMENT_ONLY_WITH_PENALTY|%', v_n.code;
    END IF;

    UPDATE nonconformance_reports
       SET status = 'decided', disposition = p_disposition, decision_note = btrim(p_note),
           decided_at = now(), decided_by = v_user,
           penalty_invoice_request_id = CASE WHEN p_disposition = 'accept_with_penalty' THEN p_penalty_invoice_request_id END,
           penalty_price_request_id = CASE WHEN p_disposition = 'accept_with_penalty' THEN p_penalty_price_request_id END
     WHERE id = p_ncr_id;

    SELECT h.ncr_code INTO v_hold FROM batch_quality_hold(v_n.inbound_batch_id, v_n.output_batch_id) h;
    RETURN jsonb_build_object('ncr_id', v_n.id, 'code', v_n.code, 'status', 'decided', 'disposition', p_disposition,
                              'batch_still_held', v_hold.ncr_code IS NOT NULL, 'held_by', v_hold.ncr_code);
END;
$function$;

-- db/functions/judge_quality_limits.sql
-- MES-6b-1(2026-10-15,V17;MES-6b Step 0 Q8 · Q26 · Q27,Tim):【判一批产出批对一张销售单的质量验收限】—— 判出来越限,同一笔事务里开一张
--   来源 quality_limit 的不合格报告(→ 质量暂扣)。【只有这一种事件会自动开报告】(Q6)。
--   两个调用方,都在 DEFINER 里:record_assay_result(记下一份产出化验,而这一批正预留给这张单 —— trigger_event 'assay_recorded')与
--   reserve_stock_internal(把一批已有化验的产出批预留给这张单 —— 'reserved')。
--
--   ① 依据是这张销售单【挂接那一刻抄下的】合同副本(contract_document_terms.settlement_terms):quality_limit_basis 不是 per_parameter
--      (none_agreed、没声明、或这张单没挂合同)→ 什么都不判。合同以后改了不回头判(Q26)。
--   ② 判哪一份化验(与结算选化验同一条规矩):这一批有一件已结案的争议点名了说了算的那一份 → 它(最近结案的那一件);否则合同约定那一方
--      (settling_party)最新的一份没删的结果(化验日、编号)。一份都没有 → 什么都不判。
--   ③ 判哪几个参数:副本里 quality_limits 适用于这批物料的每一个(物料为空的,或就是这种物料的;同一个参数两条都有时取指名物料的那一条)。
--   ④ 每个参数一行判定,限抄进去;同一份化验对同一张单的同一个参数已经判过就跳过(只判一次 —— 部分发货就地重新预留不会再判)。
--      值:水分取化验的 moisture_pct,指标取 assay_result_indicators;没报 → not_measured(不是"在限内",也不开报告)。
--   ⑤ below_min / above_max → ncr_open_internal(系统开的:opened_by 为空,指回化验、销售单与这一行判定)。预留照留(Q27)。
--   ★ 内层算子:不问码;EXECUTE 已从 authenticated 收回。返回 {judged, breaches, ncrs: [编号…]}。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.judge_quality_limits(p_output_batch_id uuid, p_sales_order_id uuid, p_trigger_event text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t        record;
    v_batch    record;
    v_assay    record;
    v_lim      record;
    v_so_code  text;
    v_val      numeric;
    v_res      text;
    v_jid      bigint;
    v_judged   integer := 0;
    v_breaches integer := 0;
    v_ncrs     jsonb := '[]'::jsonb;
    v_ncr      jsonb;
BEGIN
    -- ① 依据:挂接那一刻抄下的副本
    SELECT t.contract_id, t.contract_code, t.settlement_terms INTO v_t
      FROM contract_document_terms t WHERE t.sales_order_id = p_sales_order_id;
    IF NOT FOUND OR (v_t.settlement_terms ->> 'quality_limit_basis') IS DISTINCT FROM 'per_parameter' THEN
        RETURN jsonb_build_object('judged', 0, 'breaches', 0, 'ncrs', '[]'::jsonb);
    END IF;
    SELECT ob.id, ob.code, ob.material_id INTO v_batch
      FROM output_batches ob WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('judged', 0, 'breaches', 0, 'ncrs', '[]'::jsonb);
    END IF;

    -- ② 判哪一份化验:已结案争议点名的那一份,否则约定那一方最新的一份
    SELECT a.id, a.code, a.moisture_pct INTO v_assay
      FROM assay_disputes d
      JOIN assay_results a ON a.id = d.governing_assay_id AND a.deleted_at IS NULL
     WHERE d.output_batch_id = p_output_batch_id AND d.status = 'resolved'
     ORDER BY d.resolved_at DESC
     LIMIT 1;
    IF NOT FOUND THEN
        SELECT a.id, a.code, a.moisture_pct INTO v_assay
          FROM assay_results a
         WHERE a.output_batch_id = p_output_batch_id AND a.deleted_at IS NULL
           AND a.result_party = (v_t.settlement_terms ->> 'settling_party')
         ORDER BY a.assay_date DESC, a.code DESC
         LIMIT 1;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('judged', 0, 'breaches', 0, 'ncrs', '[]'::jsonb);
        END IF;
    END IF;
    SELECT so.code INTO v_so_code FROM sales_orders so WHERE so.id = p_sales_order_id;

    -- ③ ④ ⑤ 每一个适用的参数一行
    FOR v_lim IN
        SELECT DISTINCT ON (e ->> 'parameter')
               e ->> 'parameter' AS parameter,
               (e ->> 'min_value')::numeric AS min_value,
               (e ->> 'max_value')::numeric AS max_value
          FROM jsonb_array_elements(COALESCE(v_t.settlement_terms -> 'quality_limits', '[]'::jsonb)) e
         WHERE (e ->> 'material_id') IS NULL OR (e ->> 'material_id')::uuid = v_batch.material_id
         ORDER BY e ->> 'parameter', ((e ->> 'material_id') IS NULL)
    LOOP
        IF EXISTS (SELECT 1 FROM quality_limit_judgements j
                    WHERE j.output_batch_id = p_output_batch_id AND j.sales_order_id = p_sales_order_id
                      AND j.assay_result_id = v_assay.id AND j.parameter = v_lim.parameter) THEN
            CONTINUE;
        END IF;
        v_val := CASE WHEN v_lim.parameter = 'moisture_pct' THEN v_assay.moisture_pct
                      ELSE (SELECT i.value FROM assay_result_indicators i
                             WHERE i.assay_result_id = v_assay.id AND i.indicator = v_lim.parameter) END;
        v_res := CASE WHEN v_val IS NULL THEN 'not_measured'
                      WHEN v_lim.min_value IS NOT NULL AND v_val < v_lim.min_value THEN 'below_min'
                      WHEN v_lim.max_value IS NOT NULL AND v_val > v_lim.max_value THEN 'above_max'
                      ELSE 'within' END;
        INSERT INTO quality_limit_judgements (output_batch_id, sales_order_id, contract_id, assay_result_id, parameter,
                                              value, limit_min_at, limit_max_at, result, trigger_event)
        VALUES (p_output_batch_id, p_sales_order_id, v_t.contract_id, v_assay.id, v_lim.parameter,
                v_val, v_lim.min_value, v_lim.max_value, v_res, p_trigger_event)
        RETURNING id INTO v_jid;
        v_judged := v_judged + 1;

        IF v_res IN ('below_min', 'above_max') THEN
            v_breaches := v_breaches + 1;
            v_ncr := ncr_open_internal(
                NULL::uuid, p_output_batch_id, 'quality_limit',
                format('Quality limit breached: %s %s is %s (limit min %s, max %s) under contract %s, sales order %s, assay %s.',
                       v_batch.code,
                       CASE WHEN v_lim.parameter = 'moisture_pct' THEN 'moisture (%)'
                            ELSE COALESCE((SELECT ai.name_en || ' (' || ai.unit || ')' FROM assay_indicators ai WHERE ai.code = v_lim.parameter), v_lim.parameter) END,
                       v_val,
                       COALESCE(v_lim.min_value::text, '-'), COALESCE(v_lim.max_value::text, '-'),
                       v_t.contract_code, COALESCE(v_so_code, '?'), v_assay.code),
                v_assay.id, NULL::uuid, p_sales_order_id, v_jid, NULL::uuid);
            v_ncrs := v_ncrs || jsonb_build_array(v_ncr ->> 'code');
        END IF;
    END LOOP;

    RETURN jsonb_build_object('judged', v_judged, 'breaches', v_breaches, 'ncrs', v_ncrs);
END;
$function$;

-- db/functions/guard_quality_hold.sql
-- MES-6b-1(2026-10-15,MES-0 Q66 · G29;MES-6b Step 0 Q3 · Q21 · Q23 · Q24,Tim):【质量暂扣守在流水上】——
--   inventory_movements BEFORE INSERT(行级),与 APR-7 的注销 / 回滚冻结(guard_warehouse_request_freeze)并排:动库存的函数有几十支,
--   流水只有一张表,挂在这里就没有侧门(DEFINER 的调用者 —— 加工提交、发货、直接销售、预留 —— 一样被拒)。
--
--   一批在暂扣里(batch_quality_hold)时,写向它的这几种流水按名拒 QUALITY_HOLD_OPEN|<批号>|<不合格报告编号>:
--     processing_consume                  投料(含配料计划的执行 —— 它是一张 blending 加工单)
--     sale                                直接销售,以及发货那一条腿(ship_order 从 committed 桶里出)
--     status_change_in 进 committed        预留(available → committed 那一对的"进"腿;另一条腿与它同一句 INSERT,一起回滚)
--     writeoff,却不在一张仓库申请的执行里  注销只经 CFO 批的那张申请(warehouse_request_execute_internal 设 evoltrya.warehouse_request_ctx)
--   放行(Q3 · Q21 · Q23):收货、加工产出、转移(两条腿 —— 想把它搬进隔离库位就搬)、盘点调整、available ↔ on_hold、committed → available
--   (释放一个预留 —— 已有的预留照留,只是发不出去)、CFO 批过的注销、回滚的冲销两腿(reversal_restore / reversal_void)。
--   ★ 守卫只认【流水的种类与桶】,不认是谁写的:一张已经预留了的货,暂扣落下之后预留照旧在(Q23),发货那一条 sale 腿在这里被拒。
--   SECURITY DEFINER:暂扣的判据要读全部不合格报告(读策略认码),守卫不能因为写流水的人读不到那一张报告就放过去。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.guard_quality_hold()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_hold record;
BEGIN
    IF NOT (NEW.movement_type IN ('processing_consume', 'sale')
            OR (NEW.movement_type = 'status_change_in' AND NEW.stock_status = 'committed')
            OR (NEW.movement_type = 'writeoff'
                AND COALESCE(current_setting('evoltrya.warehouse_request_ctx', true), '') = '')) THEN
        RETURN NEW;
    END IF;
    SELECT h.ncr_code, h.batch_code INTO v_hold
      FROM batch_quality_hold(NEW.inbound_batch_id, NEW.output_batch_id) h;
    IF FOUND THEN
        RAISE EXCEPTION 'QUALITY_HOLD_OPEN|%|%', v_hold.batch_code, v_hold.ncr_code
          USING HINT = '这一批在质量暂扣里(一张开着的不合格报告,或一张决定为拒收而货还在的)—— 先让另一个人在报告上做出放行的处置;拒收的货走 CFO 注销申请。';
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/batch_quality_hold.sql
-- MES-6b-1(2026-10-15,MES-0 Q66 · G29;MES-6b Step 0 Q2 · Q21,Tim):【这一批此刻是不是在质量暂扣里 —— 是的话,被哪一张不合格报告扣着】。
--   判"被暂扣"只有这一支(流水守卫 guard_quality_hold、销售结算、配料计划的建 / 改 / 放行、批次页、提醒都读它)—— 一条规矩一份实现。
--
--   一批被暂扣,当且仅当它有一张【扣着它】的不合格报告(判据在 ncr_holds 一处,纯函数):
--     · 还开着(status = 'open')—— 不论这一批还有没有货:一批已经发走的货上开着一张客户投诉,结算照样挡住(Q4);或者
--     · 决定为 reject,而这一批【还有货】(没删、remaining_qty > 0)—— reject 不放行,暂扣留到货没了为止;出路是既有的 CFO 注销申请(Q21)。
--   别的处置(accept · accept_with_penalty · rework · downgrade)都放行。几张同时扣着时,返回最早开的那一张(opened_at、编号)。
--   不在暂扣里 → 零行。
--
--   【为什么是 INVOKER】它被两种人调:属主(流水守卫是 DEFINER;结算落库、配料计划、判定都在 DEFINER 里)—— 读全部;
--   以及一个登录的人经销售结算的预览(sale_settlement_compute 是 INVOKER)—— 那里先问过 module.output.view,而不合格报告与产出批的读策略
--   都认它,所以它不会因为读不到而把一张报告漏过去(INVOKER-JOIN-5 那一族)。不借属主的眼睛,也就不需要在函数体里再问一遍码。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.batch_quality_hold(p_inbound_batch_id uuid, p_output_batch_id uuid)
 RETURNS TABLE(ncr_id uuid, ncr_code text, batch_code text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT n.id, n.code, COALESCE(ib.code, ob.code)
      FROM nonconformance_reports n
      LEFT JOIN inbound_batches ib ON ib.id = n.inbound_batch_id
      LEFT JOIN output_batches ob ON ob.id = n.output_batch_id
     WHERE ((p_inbound_batch_id IS NOT NULL AND n.inbound_batch_id = p_inbound_batch_id)
         OR (p_output_batch_id IS NOT NULL AND n.output_batch_id = p_output_batch_id))
       AND ncr_holds(n.status, n.disposition, COALESCE(ib.deleted_at, ob.deleted_at), COALESCE(ib.remaining_qty, ob.remaining_qty))
     ORDER BY n.opened_at, n.code
     LIMIT 1
$function$;

-- db/functions/assay_is_supplement.sql
-- MES-6b-1(2026-10-15,F5;MES-6b Step 0 Q16 · Q36,Tim):【这份化验是不是一份"补充"】—— 它一种可计价的金属都没测(只测了氟、氯这类惩罚元素,
--   或者干脆只报了水分与指标)。补充在两侧(进料、产出)都这样应用:
--     · 只换掉【它测了的】那几种物质的含量行(行带 content_source = 'assay' 与它自己的 source_assay_id),别的含量一行不动;
--     · 不计价(进料不提定价申请);
--     · 不取代任何一份,也不被任何一份取代(superseded_by 两个方向都不碰);
--     · 撤销它只删它自己写下的那几行。
--   一份测了可计价金属的化验仍是"一份完整的陈述"—— 应用它就换掉整批含量(fixture 54E 一字未改)。
--   判"补充"只有这一支(应用、试算、撤销,进料与产出都读它)。INVOKER:读化验的含量行(跟着批次的读策略)与物质字典(对每个人开着)。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.assay_is_supplement(p_assay_result_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT NOT EXISTS (SELECT 1 FROM assay_result_metals m
                         JOIN substances s ON s.code = m.metal AND s.role = 'payable_metal'
                        WHERE m.assay_result_id = p_assay_result_id)
$function$;

-- ── 5 · 换掉的函数(镜像原样,同签名)────────────────────────────────────────────────────────────

-- db/functions/guard_substance_role.sql
-- MES-6a-2(2026-10-10,MES-0 Q69;MES-6a Step 0 Q27,Tim):一张只收【某一种】物质的表上,写进来的那个码必须是那一种。
--   TG_ARGV[0] = 要的 role(payable_metal / penalty_element),TG_ARGV[1] = 存码的那一列(metal / substance)。
--   定价那几张表要 payable_metal → 拒 SUBSTANCE_NOT_PAYABLE|<码>;合同的惩罚条款要 penalty_element → 拒 SUBSTANCE_NOT_PENALTY_ELEMENT|<码>。
--   写入函数(upsert_metal_prices、calculate_metal_price_from_terms)在自己那一步先按名说一遍;这一道守着【每一条】写路 ——
--   直连写的合同条款(action.contract_terms 的写策略)、公式的提交与它的试跑、承诺副本的复制。
--   不在字典里的码不归它管:外键在它之后照旧按 foreign_key_violation 拒(两件不同的事,两句不同的话)。
--   INVOKER:substances 的读策略对每一个登录的人都是 USING (true),没有什么要借属主的眼睛去看。
--   ★ MES-6b-1(2026-10-15,F4;MES-6b Step 0 Q15,Tim):第一个参数从【一种】角色变成【一组】(逗号分隔)—— 合同的惩罚条款从此收
--     payable_metal 或 penalty_element(铜、铝在镍黑粉里是杂质,一份合同可以罚它们);other 照拒。定价那几张表仍只收 payable_metal,
--     拒的那句话不变(SUBSTANCE_NOT_PAYABLE);惩罚条款拒 other 仍说 SUBSTANCE_NOT_PENALTY_ELEMENT。【每一条计价路仍只认可计价金属】——
--     一种既计价又罚的物质在同一份合同里由 guard_substance_priced_and_penalised 按名拒(Q33)。
-- NOTE: introduced by db/migrations/2026-10-10-mes6a2-penalty-elements-and-indicators.sql;
--       replaced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql (a set of roles).
CREATE OR REPLACE FUNCTION public.guard_substance_role()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code  text := to_jsonb(NEW) ->> TG_ARGV[1];
    v_roles text[] := string_to_array(TG_ARGV[0], ',');
    v_role  text;
BEGIN
    IF v_code IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT s.role INTO v_role FROM substances s WHERE s.code = v_code;
    IF NOT FOUND THEN
        RETURN NEW;   -- 外键会说"不在字典里",那不是这一道的话
    END IF;
    IF v_role IS NULL OR NOT (v_role = ANY (v_roles)) THEN
        IF v_roles = ARRAY['payable_metal'] THEN
            RAISE EXCEPTION 'SUBSTANCE_NOT_PAYABLE|%', v_code
              USING HINT = '这种物质不是按含量计价的金属(substances.role ≠ payable_metal)—— 它不进行情、公式、承诺、合同计价与精炼费';
        END IF;
        RAISE EXCEPTION 'SUBSTANCE_NOT_PENALTY_ELEMENT|%', v_code
          USING HINT = '合同的惩罚条款只收惩罚元素或可计价的金属(substances.role = penalty_element / payable_metal)';
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/contract_activation_missing.sql
-- TERMS-EDIT-1(Tim 2026-09-27,grilling Q3):一份合同【申请生效之前】还缺哪几条条款 —— 空数组 = 不缺。
--   只对卖方合同(side = 'sell')有要求;买方合同什么都不要求(采购侧的指数计价是 index-pricing-spec §9,仍在 Tim 那里)。
--   卖方合同缺的,按这个顺序逐条说出来:
--     'settlement_terms'           没有结算口径那一行(一份合同恰好一行;唯一约束管"不多于一行")
--     'pricing_terms'              一条计价条款都没有
--     'refining_charge:<metal>'    精炼费口径声明为 per_metal,而这个计价金属没有精炼费那一行
--     'penalty_elements'           惩罚口径声明为 per_element,而一条惩罚元素都没有
--   ★ 这四条正是 sale_settlement_compute 在结算那一刻会按名拒的四件事(SETTLEMENT_TERMS_NOT_SET ·
--     SETTLEMENT_PAYABLE_NOT_STATED · REFINING_CHARGE_NOT_FILED · PENALTY_ELEMENTS_NOT_FILED)。它们读的是挂接那一刻
--     抄下的副本(contract_document_terms),所以一份缺条款的合同一旦生效,挂在它下面的销售单到结算时才响 ——
--     而那时合同已经冻结了。所以在申请生效时就拒(terms_request_submit_internal → CONTRACT_TERMS_INCOMPLETE)。
--   ★ MES-6b-1(2026-10-15,V17 · F4;MES-6b Step 0 Q25 · Q33,Tim)多三条,同样只对卖方合同:
--     'quality_limit_basis'               结算口径里质量验收限的口径没声明(V17 Not yet set —— 没声明不是"没有限")
--     'quality_limits'                    声明了 per_parameter,而 contract_quality_limits 一行都没有
--     'priced_and_penalised:<码>'          同一种物质既在计价条款里、又在惩罚条款里(条款表上的守卫先拒,这里是第二道)
--     提交那一支把后两条说成它们自己的名字(QUALITY_LIMITS_NOT_FILED · SUBSTANCE_PRICED_AND_PENALISED),其余照旧 CONTRACT_TERMS_INCOMPLETE。
--   两处读它:提交那一支(属主身份,读全部)与合同详情页那张清单(以调用者身份,受 RLS —— 看不见这份合同的人读到空)。
--   SECURITY INVOKER:它不替任何人打开任何一行。
-- NOTE: introduced by db/migrations/2026-09-27-terms-edit1-contract-terms-editor.sql.

CREATE OR REPLACE FUNCTION public.contract_activation_missing(p_contract_id uuid)
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(array_agg(m.item ORDER BY m.ord, m.item), ARRAY[]::text[])
      FROM contracts c
      LEFT JOIN contract_settlement_terms st ON st.contract_id = c.id
      CROSS JOIN LATERAL (
          SELECT 1 AS ord, 'settlement_terms'::text AS item WHERE st.id IS NULL
          UNION ALL
          SELECT 2, 'pricing_terms'
           WHERE NOT EXISTS (SELECT 1 FROM contract_pricing_terms pt WHERE pt.contract_id = c.id)
          UNION ALL
          SELECT 3, 'refining_charge:' || pt.metal
            FROM contract_pricing_terms pt
           WHERE pt.contract_id = c.id AND st.refining_charge_basis = 'per_metal'
             AND NOT EXISTS (SELECT 1 FROM contract_refining_charges rc
                              WHERE rc.contract_id = c.id AND rc.metal = pt.metal)
          UNION ALL
          SELECT 4, 'penalty_elements'
           WHERE st.penalty_basis = 'per_element'
             AND NOT EXISTS (SELECT 1 FROM contract_penalty_elements pe WHERE pe.contract_id = c.id)
          UNION ALL
          SELECT 5, 'quality_limit_basis'
           WHERE st.id IS NOT NULL AND st.quality_limit_basis IS NULL
          UNION ALL
          SELECT 6, 'quality_limits'
           WHERE st.quality_limit_basis = 'per_parameter'
             AND NOT EXISTS (SELECT 1 FROM contract_quality_limits ql WHERE ql.contract_id = c.id)
          UNION ALL
          SELECT 7, 'priced_and_penalised:' || pt.metal
            FROM contract_pricing_terms pt
           WHERE pt.contract_id = c.id
             AND EXISTS (SELECT 1 FROM contract_penalty_elements pe
                          WHERE pe.contract_id = c.id AND pe.substance = pt.metal)
      ) m
     WHERE c.id = p_contract_id AND c.side = 'sell'
$function$;

-- db/functions/contract_terms_state.sql
-- APR-8(2026-09-26):一份合同此刻的样子 —— 表头(去掉 id、编号与创建 / 修改人时刻)与七张条款表的每一行
-- (去掉 id、contract_id 与创建 / 修改人时刻,按行文排序,于是同一组条款读出同一串字)。
-- 三个读它的人:CFO 的 snapshot(current;上一次批准时的那一份也是它)、fingerprint、屏幕上的差别。
-- ★ MES-6b-1(2026-10-15,V17):第八张条款表 contract_quality_limits 也在里面('quality_limits';算出来的 indicator 列去掉 —— 它只是 parameter 的影子)。
--   于是一份生效之后又暂停、改了质量限的合同,再申请生效时 CFO 看得见那一处差别,批准时的指纹也认它。
-- 不存在的合同 → NULL。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.contract_terms_state(p_contract_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object(
               'header', to_jsonb(c) - 'id' - 'code' - 'status' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by',
               'grade_specs', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_grade_specs t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'insurance_obligations', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_insurance_obligations t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'volume_commitments', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_volume_commitments t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'pricing_terms', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_pricing_terms t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'settlement_terms', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_settlement_terms t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'refining_charges', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_refining_charges t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'penalty_elements', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_penalty_elements t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'quality_limits', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'indicator' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_quality_limits t WHERE t.contract_id = c.id) x), '[]'::jsonb))
      FROM contracts c
     WHERE c.id = p_contract_id
$function$;

-- db/functions/terms_request_submit_internal.sql
-- APR-8(2026-09-26):提一张条款申请 —— 四扇提交的门各问完自己的码,落进这一支。本支不问码。
--
--   1. 主体要在、这一种要成立:
--        公式:没删(FORMULA_NOT_FOUND);修改要在用(FORMULA_NOT_ACTIVE);新建 / 重新启用要停用着(FORMULA_ALREADY_ACTIVE);
--              拟议条款规范化(formula_terms_normalize);修改而条款与此刻一模一样 → TERMS_REQUEST_NO_CHANGE|编号。
--        合同:没删(CONTRACT_NOT_FOUND);是 draft 或 suspended(CONTRACT_NOT_ACTIVATABLE|编号|状态);
--              合同期已经结束 → CONTRACT_PERIOD_ENDED|编号|截止日。
--              ★ TERMS-EDIT-1(Tim 2026-09-27,grilling Q3):卖方合同条款不齐 → CONTRACT_TERMS_INCOMPLETE|编号|缺的那几条
--              (逗号分隔,见 contract_activation_missing);买方合同不要求。
--              ★ MES-6b-1(V17 · F4):同一种物质既计价又罚 → SUBSTANCE_PRICED_AND_PENALISED|码;声明了按参数的质量验收限而一行都没填
--              → QUALITY_LIMITS_NOT_FILED|编号(两条先于 CONTRACT_TERMS_INCOMPLETE 说)。
--   2. 理由必填(TERMS_REQUEST_REASON_REQUIRED|种类|编号)。
--   3. 同一个主体上已有一张在等 → TERMS_REQUEST_OPEN|编号|那一张(grilling Q5;唯一索引是第二道)。
--   4. ★ 审批开着时:提单人这个【人】之外,二级还有没有人批得动 → TERMS_REQUEST_NO_OTHER_DECIDER|label
--      (assert_other_decider,按人认)。线上 admin@ 与 tim@ 是同一个人,而二级只有 tim@ —— admin@ 提的一律按名拒。
--   5. 落一行 submitted:snapshot 与 fingerprint 冻结;按批准那一刻的同一支试跑(terms_request_dry_run)。
--   6. 审批开着:留痕 submitted,二级。关着:当场生效,状态 approved,留痕 auto_approved。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql;
--       replaced by db/migrations/2026-09-27-terms-edit1-contract-terms-editor.sql (CONTRACT_TERMS_INCOMPLETE);
--       replaced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql (two named refusals).

CREATE OR REPLACE FUNCTION public.terms_request_submit_internal(p_kind text, p_subject uuid, p_proposed jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_missing text[];
    v_pp     text;
    v_on     boolean := approvals_enabled();
    v_id     uuid := gen_random_uuid();
    v_code   text;
    v_active boolean;
    v_status text;
    v_to     date;
    v_prop   jsonb := NULL;
    v_open   text;
    v_n      integer;
    v_label  text;
BEGIN
    IF p_kind IN ('formula_create', 'formula_change', 'formula_reactivate') THEN
        SELECT code, is_active INTO v_code, v_active FROM pricing_formulas
         WHERE id = p_subject AND deleted_at IS NULL FOR UPDATE;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
        IF p_kind = 'formula_change' AND NOT v_active THEN
            RAISE EXCEPTION 'FORMULA_NOT_ACTIVE|%', v_code;
        END IF;
        IF p_kind IN ('formula_create', 'formula_reactivate') AND v_active THEN
            RAISE EXCEPTION 'FORMULA_ALREADY_ACTIVE|%', v_code;
        END IF;
        v_prop := formula_terms_normalize(COALESCE(p_proposed, formula_terms_state(p_subject)));
        IF p_kind = 'formula_change' AND v_prop = formula_terms_state(p_subject) THEN
            RAISE EXCEPTION 'TERMS_REQUEST_NO_CHANGE|%', v_code;
        END IF;
    ELSIF p_kind = 'contract_activate' THEN
        SELECT code, status, effective_to INTO v_code, v_status, v_to FROM contracts
         WHERE id = p_subject AND deleted_at IS NULL FOR UPDATE;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'CONTRACT_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
        IF v_status NOT IN ('draft', 'suspended') THEN
            RAISE EXCEPTION 'CONTRACT_NOT_ACTIVATABLE|%|%', v_code, v_status;
        END IF;
        IF v_to IS NOT NULL AND v_to < CURRENT_DATE THEN
            RAISE EXCEPTION 'CONTRACT_PERIOD_ENDED|%|%', v_code, v_to;
        END IF;
        -- ★ MES-6b-1(V17 · F4;Step 0 Q25 · Q33):两条缺失有它们自己的名字 —— 一种物质既计价又罚(条款不一致,先说它),
        --   声明了按参数却没填限(SETTLE-1 ③ 的形状);其余照旧一句 CONTRACT_TERMS_INCOMPLETE 列出缺的那几条。
        v_missing := contract_activation_missing(p_subject);
        SELECT substr(x, length('priced_and_penalised:') + 1) INTO v_pp
          FROM unnest(v_missing) x WHERE x LIKE 'priced\_and\_penalised:%' ORDER BY x LIMIT 1;
        IF v_pp IS NOT NULL THEN
            RAISE EXCEPTION 'SUBSTANCE_PRICED_AND_PENALISED|%', v_pp
              USING HINT = '这份合同把同一种物质既写进了计价条款、又写进了惩罚条款 —— 一种物质要么计价、要么罚。';
        END IF;
        IF 'quality_limits' = ANY (v_missing) THEN
            RAISE EXCEPTION 'QUALITY_LIMITS_NOT_FILED|%', v_code
              USING HINT = '这份合同声明了按参数的质量验收限,却一行限都没有填 —— 【声明了有】与【填了哪些】是两件事。';
        END IF;
        IF cardinality(v_missing) > 0 THEN
            RAISE EXCEPTION 'CONTRACT_TERMS_INCOMPLETE|%|%', v_code, array_to_string(v_missing, ',');
        END IF;
    ELSE
        RAISE EXCEPTION 'TERMS_REQUEST_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'TERMS_REQUEST_REASON_REQUIRED|%|%', p_kind, v_code;
    END IF;

    SELECT r.label INTO v_open FROM terms_requests r
     WHERE r.status = 'submitted' AND (r.formula_id = p_subject OR r.contract_id = p_subject)
     LIMIT 1;
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'TERMS_REQUEST_OPEN|%|%', v_code, v_open;
    END IF;

    -- label:同一个主体上第几张。咨询锁串行化"数一遍 + 1"。
    PERFORM pg_advisory_xact_lock(hashtext('terms_request_label')::bigint);
    SELECT count(*) + 1 INTO v_n FROM terms_requests r
     WHERE COALESCE(r.formula_id, r.contract_id) = p_subject;
    v_label := v_code || ' · ' || CASE p_kind WHEN 'formula_create' THEN 'new'
                                               WHEN 'formula_change' THEN 'change'
                                               WHEN 'formula_reactivate' THEN 'reactivate'
                                               ELSE 'activate' END || ' #' || v_n::text;

    PERFORM assert_other_decider('terms_request', 'decide_terms_request', 2::smallint,
                                 'TERMS_REQUEST_NO_OTHER_DECIDER|' || v_label);

    INSERT INTO terms_requests (id, kind, status, label, formula_id, contract_id, reason, proposed,
                                snapshot, fingerprint, created_by)
    VALUES (v_id, p_kind, 'submitted', v_label,
            CASE WHEN p_kind <> 'contract_activate' THEN p_subject END,
            CASE WHEN p_kind = 'contract_activate' THEN p_subject END,
            btrim(p_reason), v_prop, terms_request_snapshot(p_kind, p_subject, v_prop),
            terms_request_fingerprint(p_kind, p_subject), auth.uid());

    PERFORM terms_request_dry_run(v_id);

    IF v_on THEN
        PERFORM record_approval_decision('terms_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM terms_request_execute_internal(v_id);
        UPDATE terms_requests SET status = 'approved', executed_at = now() WHERE id = v_id;
        PERFORM record_approval_decision('terms_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场生效,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'kind', p_kind,
        'subject_code', v_code,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END);
END;
$function$;

-- db/functions/link_document_to_contract.sql
-- CONTRACT-1:把一张单据挂到一份合同上,并**当场把在效条款抄下来**。
--
-- ★★【这支函数就是"登记簿不是文件柜"那句话的实现】★★
--   两条拒绝,而**两条都是【不一致】,不是【政策】**(Tim 2026-08-29 裁定 A1):
--     · CONTRACT_COUNTERPARTY_MISMATCH —— 合同是这家、单据是那家。
--       没有人会"故意"这么挂;这是一次录入错误,拒它不需要任何裁定。
--     · CONTRACT_NOT_ACTIVE —— 一份草稿/已终止的合同不该有新单据挂上来。
--   这正是 AGENTS.md 给 ALLOC_CURRENCY_MISMATCH(不一致 → 该拒)与
--   ALLOC_EXCEEDS(政策 → 先问这条规矩对不对)划的那条线。
--
-- ★【刻意【不】拒的那一条,写在这里而不是留成沉默】★
--   **单据日期落在合同期之外,本函数不拒。** 回填一张早于合同生效日的单据是
--   正当操作;而"能不能背靠一份尚未生效的合同下单"是一个**没有人裁过**的问题。
--   没有裁定就按名拒,买到的是绕过它的办法,不是控制(WHT-1 那条同款)。
--   要改这一条,先要有一次裁定,而不是先加一句 IF。
--
-- ★【抄写与检查在【同一笔事务】里,而那是本表不开 INSERT 策略的理由】★
--   分成两步(先查、再抄)之间那道缝,足够让一份刚被改成 terminated 的合同
--   把条款抄出去。所以两者必须同生共死。

CREATE OR REPLACE FUNCTION public.link_document_to_contract(
    p_document_kind text,
    p_document_id uuid,
    p_contract_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_con      contracts%ROWTYPE;
    v_doc_cp   uuid;
    v_doc_code text;
    v_specs    jsonb;
    v_pricing  jsonb;
    v_settle   jsonb;
BEGIN
    IF p_document_kind IS NULL OR p_document_kind NOT IN ('purchase_order','sales_order') THEN
        RAISE EXCEPTION 'CONTRACT_DOCUMENT_KIND_INVALID|%', COALESCE(p_document_kind, 'null')
          USING HINT = '今天只有采购单与销售单挂得上合同 —— 别的单据要先决定"它算不算在合同之下开出来的"';
    END IF;

    SELECT * INTO v_con FROM contracts WHERE id = p_contract_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND|%', p_contract_id;
    END IF;

    -- 【SECURITY DEFINER 自己查权限,按合同归属那一侧查】
    -- 属主权限绕过 RLS,所以这一句不是礼节。
    IF v_con.customer_id IS NOT NULL THEN
        PERFORM require_permission('module.customers.edit');
    ELSE
        PERFORM require_permission('module.suppliers.edit');
    END IF;

    -- ★ 拒绝一:合同不是 active ★
    IF v_con.status <> 'active' THEN
        RAISE EXCEPTION 'CONTRACT_NOT_ACTIVE|%|%', v_con.code, v_con.status
          USING HINT = '只有生效中的合同才收得下新单据 —— 草稿还没谈定,已终止的不该再长出新单据。要挂上去,先把合同置为 active';
    END IF;

    -- 取单据的对手方与编号
    IF p_document_kind = 'purchase_order' THEN
        SELECT supplier_id, code INTO v_doc_cp, v_doc_code
          FROM purchase_orders WHERE id = p_document_id AND deleted_at IS NULL;
        IF v_doc_code IS NULL THEN
            RAISE EXCEPTION 'PO_NOT_FOUND|%', p_document_id; END IF;
        -- ★ 拒绝二:一张采购单只挂得上【买方】合同 ★
        IF v_con.supplier_id IS NULL THEN
            RAISE EXCEPTION 'CONTRACT_SIDE_MISMATCH|%|%', v_con.code, 'purchase_order'
              USING HINT = '这是一份销售合同(对手方是客户),而你要挂的是一张采购单';
        END IF;
        IF v_doc_cp IS DISTINCT FROM v_con.supplier_id THEN
            RAISE EXCEPTION 'CONTRACT_COUNTERPARTY_MISMATCH|%|%', v_con.code, v_doc_code
              USING HINT = '合同的对手方与单据的对手方不是同一家 —— 这是一次录入错误,不是一条可以斟酌的规矩';
        END IF;
    ELSE
        SELECT customer_id, code INTO v_doc_cp, v_doc_code
          FROM sales_orders WHERE id = p_document_id AND deleted_at IS NULL;
        IF v_doc_code IS NULL THEN
            RAISE EXCEPTION 'SO_NOT_FOUND|%', p_document_id; END IF;
        IF v_con.customer_id IS NULL THEN
            RAISE EXCEPTION 'CONTRACT_SIDE_MISMATCH|%|%', v_con.code, 'sales_order'
              USING HINT = '这是一份采购合同(对手方是供应商),而你要挂的是一张销售单';
        END IF;
        IF v_doc_cp IS DISTINCT FROM v_con.customer_id THEN
            RAISE EXCEPTION 'CONTRACT_COUNTERPARTY_MISMATCH|%|%', v_con.code, v_doc_code
              USING HINT = '合同的对手方与单据的对手方不是同一家 —— 这是一次录入错误,不是一条可以斟酌的规矩';
        END IF;
    END IF;

    -- 已经挂过就按名拒,不悄悄改挂 —— 改挂等于把一张单据当初依据的条款换掉。
    IF EXISTS (SELECT 1 FROM contract_document_terms
                WHERE (p_document_kind = 'purchase_order' AND purchase_order_id = p_document_id)
                   OR (p_document_kind = 'sales_order'    AND sales_order_id    = p_document_id)) THEN
        RAISE EXCEPTION 'DOCUMENT_ALREADY_UNDER_CONTRACT|%', v_doc_code
          USING HINT = '这张单据已经挂在一份合同之下了 —— 改挂会把它当初依据的条款换掉,而那是改历史。要换,先决定已经抄下的那一份怎么办';
    END IF;

    -- ★★ 抄:把在效条款的【值】写下来,不是留一个指针 ★★
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'metal', g.metal, 'material_id', g.material_id,
               'min_pct', g.min_pct, 'max_pct', g.max_pct) ORDER BY g.metal), '[]'::jsonb)
      INTO v_specs
      FROM contract_grade_specs g WHERE g.contract_id = v_con.id;

    -- PRICE-1:计价条款一并抄下来。**同一笔事务、同一个抄写动作** ——
    -- 分成两步就会有一道缝,而一份刚被改过的合同可以从那道缝里把条款抄出去。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'metal', t.metal, 'base_event', t.base_event,
               'qp_months', t.qp_months, 'index_code', t.index_code,
               'payable_pct', t.payable_pct) ORDER BY t.metal), '[]'::jsonb)
      INTO v_pricing
      FROM contract_pricing_terms t WHERE t.contract_id = v_con.id;

    -- SETTLE-1:结算口径连同它两张子表,**一起**抄下来。
    -- 【三样一起冻】结算要靠它们一起算钱;分开冻,"我按哪一份算的"就变成三个时刻。
    SELECT COALESCE(to_jsonb(x) - 'id' - 'contract_id' - 'created_at' - 'created_by'
                    - 'updated_at' - 'updated_by'
                    || jsonb_build_object(
                         'refining_charges', COALESCE((
                             SELECT jsonb_agg(jsonb_build_object(
                                 'metal', r.metal,
                                 'usd_per_tonne_of_metal', r.usd_per_tonne_of_metal) ORDER BY r.metal)
                               FROM contract_refining_charges r WHERE r.contract_id = v_con.id), '[]'::jsonb),
                         'penalty_elements', COALESCE((
                             SELECT jsonb_agg(jsonb_build_object(
                                 'substance', pe.substance,
                                 'threshold_pct', pe.threshold_pct,
                                 'usd_per_tonne_per_pct_over', pe.usd_per_tonne_per_pct_over) ORDER BY pe.substance)
                               FROM contract_penalty_elements pe WHERE pe.contract_id = v_con.id), '[]'::jsonb),
                         -- ★ MES-6b-1(V17;Step 0 Q8 · Q26):质量验收限与它的口径声明一起冻 —— quality_limit_basis 随上面的 to_jsonb 进来,
                         --   这几行在这里;判定(judge_quality_limits)只读这一份,合同以后再改不回头判。
                         'quality_limits', COALESCE((
                             SELECT jsonb_agg(jsonb_build_object(
                                 'material_id', ql.material_id,
                                 'parameter', ql.parameter,
                                 'min_value', ql.min_value,
                                 'max_value', ql.max_value) ORDER BY ql.parameter, ql.material_id NULLS FIRST)
                               FROM contract_quality_limits ql WHERE ql.contract_id = v_con.id), '[]'::jsonb)),
                    '{}'::jsonb)
      INTO v_settle
      FROM contract_settlement_terms x WHERE x.contract_id = v_con.id;
    v_settle := COALESCE(v_settle, '{}'::jsonb);

    INSERT INTO contract_document_terms (
        purchase_order_id, sales_order_id, contract_id,
        contract_code, contract_title, incoterm, currency, payment_terms_days,
        grade_specs, pricing_terms, settlement_terms, linked_by)
    VALUES (
        CASE WHEN p_document_kind = 'purchase_order' THEN p_document_id END,
        CASE WHEN p_document_kind = 'sales_order'    THEN p_document_id END,
        v_con.id,
        v_con.code, v_con.title, v_con.incoterm, v_con.currency, v_con.payment_terms_days,
        v_specs, v_pricing, v_settle, auth.uid());

    -- 单据那一行也记下它挂在哪 —— 这一列是【导航】,条款仍然读上面那份副本。
    IF p_document_kind = 'purchase_order' THEN
        UPDATE purchase_orders SET contract_id = v_con.id WHERE id = p_document_id;
    ELSE
        UPDATE sales_orders SET contract_id = v_con.id WHERE id = p_document_id;
    END IF;

    RETURN jsonb_build_object(
        'document_kind', p_document_kind, 'document_code', v_doc_code,
        'contract_code', v_con.code,
        'grade_specs_copied', jsonb_array_length(v_specs),
        'pricing_terms_copied', jsonb_array_length(v_pricing),
        'settlement_terms_copied', (v_settle <> '{}'::jsonb),
        -- ★【PRICE-1:把"你冻的是哪一份"当场说出来,不要让人事后才发现】★
        --   回填挂接是**正当的**(CONTRACT-1 裁过,不改),而它的后果是:
        --   冻下来的是【挂接此刻】在效的条款,不是下单那天的。
        --   **对品位规格这条边不算锋利,对钱锋利** —— 所以判词跟着返回值走,
        --   而不是只躺在一句代码注释里。文案在 messages/*.ts,双语,按 locale 选。
        'terms_frozen_as_of', now(),
        'terms_frozen_note_code', 'TERMS_FROZEN_AT_LINK_TIME');
END;
$function$;

COMMENT ON FUNCTION public.link_document_to_contract(text, uuid, uuid) IS
'CONTRACT-1:把一张单据挂到合同上,并**当场把在效条款抄下来**。★**这支函数就是"登记簿不是文件柜"那句话的实现**★:两条拒绝 —— 对手方对不上、合同不是 active —— 而**两条都是【不一致】不是【政策】**(AGENTS.md 给 ALLOC_CURRENCY_MISMATCH 与 ALLOC_EXCEEDS 划的线):没有人会故意把 A 家的单挂到 B 家的合同上。★**刻意不拒的那一条**★:单据日期落在合同期之外【不拒】—— 回填是正当操作,而"能不能背靠未生效的合同下单"没有人裁过,没裁定就按名拒买到的是绕过它的办法。**抄写与检查在同一笔事务里**,这也是 contract_document_terms 不开 INSERT 策略的理由:分两步之间那道缝足够让一份刚被改成 terminated 的合同把条款抄出去。已经挂过按名拒,不悄悄改挂 —— 改挂等于把一张单据当初依据的条款换掉。';

-- db/functions/sale_settlement_compute.sql
-- SETTLE-1:一次销售最终结算的算法。CLEANUP-A 加了第二道闸(module.output.view)——
-- 闸问的和身体读的从前不是同一条权限。它【今天拦不到任何人】,而那正是它的理由:
-- 角色改一次就会无声地重新打开它。
--
-- ★【TOOLS-1 ④(2026-09-03):两处基准换算搬进 convert_weight_basis /
--   convert_grade_basis】★ 函数体其余部分【一个字节没动】——
--   `pg_get_functiondef` 的 diff 就是那两行。理由与证据见那两支函数的抬头、
--   db/fixtures/187(新旧逐点比对)与 db/fixtures/149(结算那条路,提取后重跑通过)。

CREATE OR REPLACE FUNCTION public.sale_settlement_compute(p_sales_order_id uuid, p_output_batch_id uuid, p_assay_result_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- SETTLE-1:一次销售最终结算的**算法** —— 四条条款是**同一条公式**里的四项。
--
-- ★★【一处实现,两个调用者】★★ 本支只**算**,不写;record_sale_settlement 调它
--   再落一行。本仓库为"两份实现在写下来那天一致、之后悄悄分开"付过**四次**账
--   (AGENTS.md 那条预览规则),所以预览与落库读的是同一段算术。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【公式(index-pricing-spec §3),四条条款各占一项】
--     (结算重量 × 含量 × 计价系数) × 计价期均价      ← 重量基准 / PRICE-1 的条款
--   − 精炼费(按【含金属】吨数)                       ← contract_refining_charges
--   − 惩罚(按【结算重量】吨数,超阈值部分)           ← contract_penalty_elements
--   而"用谁的化验"决定了上面的**含量**从哪一行来       ← result_party / settling_party
--
-- ★★【为什么湿基与干基结算出【不同的钱】】★★
--   含金属是**不变量**(换算对了的话,湿基算与干基算得到同一个含量),
--   所以**金属价值与精炼费不随基准变**。变的是**惩罚** ——
--   它按**结算重量**收,而水是随货一起进来的。
--   于是同一批货按湿基结算比按干基**多罚**,而那是对的。
--   **这也正是 GO-3 那个"钱的错误"之所以是钱的错误。**
--
-- 拒绝(全部按名,全部双语):
--   SETTLEMENT_PERMISSION_DENIED|<code>        没有权限(而不是让 RLS 报成"数据缺了")
--   SO_NOT_FOUND / OUTPUT_BATCH_NOT_FOUND / ASSAY_NOT_FOUND
--   SETTLEMENT_NO_CONTRACT_TERMS|<so>          这张单没挂合同,没有可依据的冻结条款
--   SETTLEMENT_TERMS_NOT_SET|<contract>        挂了合同,但那份合同没有结算口径
--   ASSAY_NOT_FOR_BATCH|<assay>|<batch>        选的化验不是这个批次的
--   ★ ASSAY_DISPUTE_OPEN|<batch>|<争议>        这一批挂着一件开着的化验争议(MES-6a-1,Q21)
--   ★ QUALITY_HOLD_OPEN|<batch>|<报告>         这一批在质量暂扣里(MES-6b-1,Step 0 Q4:一张开着的不合格报告 ——
--                                               客户投诉一批发走了的货,结算等它决定;判据 batch_quality_hold)
--   ★ ASSAY_WEIGHT_BASIS_NOT_STATED|<assay>    化验没说按哪种重量报 ← 本刀最要紧的那条
--   ASSAY_PARTY_NOT_THE_SETTLING_PARTY|…       选的化验不是合同约定的那一方(仲裁除外)
--   RESULTS_IN_DISPUTE|…                       两方结果不一致,而没有声明容差
--   RESULTS_EXCEED_SPLITTING_LIMIT|…           不一致超过了声明的容差 → 该走仲裁
--   SETTLEMENT_MOISTURE_NOT_STATED|<assay>     要换算基准却没有水分
--   SETTLEMENT_PAYABLE_NOT_STATED|<metal>      没有计价系数(PRICE-1 的条款)
--   SETTLEMENT_BASE_EVENT_DATE_UNKNOWN|<event> 基准事件的日期在卖方向还记不下来
--   REFINING_CHARGE_NOT_FILED|<contract>|<metal>   声明了按金属收,却没填那一行
--   PENALTY_ELEMENTS_NOT_FILED|<contract>          声明了按元素罚,却一行都没填
DECLARE
    v_st        jsonb;     -- 冻结的结算口径
    v_pricing   jsonb;     -- 冻结的计价条款(PRICE-1)
    v_terms     record;
    v_batch     record;
    v_assay     record;
    v_basis     text;
    v_gross     numeric;
    v_moist     numeric;
    v_swt       numeric;   -- 结算重量
    v_other     record;
    v_lim       numeric;
    v_maxdiff   numeric;
    v_el        jsonb;
    v_ccode     text;
    v_pt_event  text;
    v_pt_months integer;
    v_pt_index  text;
    v_metal     text;
    v_content   numeric;
    v_content_s numeric;
    v_contained numeric;
    v_payable   numeric;
    v_pay_kg    numeric;
    v_price     numeric;
    v_qp        record;
    v_rc        numeric;
    v_base_date date;
    v_lines     jsonb := '[]'::jsonb;
    v_pens      jsonb := '[]'::jsonb;
    v_mv        numeric := 0;
    v_rcs       numeric := 0;
    v_pen       numeric := 0;
    v_thr       numeric;
    v_rate      numeric;
    v_over      numeric;
    v_amt       numeric;
    v_disp      uuid;
    v_hold      record;
BEGIN
    IF p_sales_order_id IS NULL OR p_output_batch_id IS NULL OR p_assay_result_id IS NULL THEN
        RAISE EXCEPTION 'SETTLEMENT_ARGUMENTS_REQUIRED';
    END IF;
    -- 【权限按名拒,不让 RLS 把行藏起来报成"数据缺了"】PRICE-1 的 fu1 是这一课,
    -- 这里一开始就写上,而不是等 fixture 再抓一次。
    IF NOT has_permission('module.customers.view'::text) THEN
        RAISE EXCEPTION 'SETTLEMENT_PERMISSION_DENIED|%', 'module.customers.view'
          USING HINT = '看得见销售结算要有客户模块的查看权限 —— 这不是数据缺失,是权限';
    END IF;
    -- ★【第二道闸(CLEANUP-A)—— 它今天【拦不到任何人】,而那正是它的理由】★
    -- 上面那道闸问的是 module.customers.view,而本支接下来要读的是
    -- output_batches / assay_results / assay_result_metals —— 这三张的 RLS
    -- 策略问的都是 module.output.view。**闸问的和身体读的不是同一条权限。**
    -- 本支是 SECURITY INVOKER,所以一个只有 customers.view 的读者会走过第一道闸,
    -- 然后【读到零行化验金属】,而金属循环一次都不执行 → metal_value = 0、
    -- refining_charge = 0 → **amount_usd 结算成 0.00,附一张空的 breakdown**。
    -- 那是一个不报错的、可以被当成"这批货不值钱"的数字。
    --
    -- 【实测:今天线上没有任何角色能走到那一步,而这不是不修的理由】
    -- 持 customers.view 的五个角色(admin/auditor/finance/gm/sales)【全部】
    -- 也持 output.view,所以今天这条路复现不了;线上 contract_document_terms
    -- 还是零行,4 张化验单全在进料侧,函数在金属循环之前就按名拒了。
    -- **但这道闸关的不是"现在错着",是"角色改一次就会无声地重新打开它"** ——
    -- 而重新打开的那一天,没有任何东西会响。所以它现在就该在这里。
    -- 【fixture 会构造一个只有 customers.view 的读者来钉住它;那不是线上缺陷的证据。】
    IF NOT has_permission('module.output.view'::text) THEN
        RAISE EXCEPTION 'SETTLEMENT_PERMISSION_DENIED|%', 'module.output.view'
          USING HINT = '结算要读产出批次与它的化验结果 —— 那要产出模块的查看权限。'
                       '没有它,化验金属会读成零行,而结算金额会算成 0.00:'
                       '一个不报错、看起来像"这批货不值钱"的数字。';
    END IF;

    -- ── 冻结的条款副本(【抄】,不回查合同现在怎么写)────────────────────────
    SELECT * INTO v_terms FROM contract_document_terms WHERE sales_order_id = p_sales_order_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SETTLEMENT_NO_CONTRACT_TERMS|%', p_sales_order_id
          USING HINT = '这张销售单没有挂在任何合同之下 —— 结算口径是合同条款,没有合同就没有口径';
    END IF;
    v_st := v_terms.settlement_terms;
    v_pricing := v_terms.pricing_terms;
    v_ccode := v_terms.contract_code;
    IF v_st IS NULL OR jsonb_typeof(v_st) <> 'object' OR v_st = '{}'::jsonb THEN
        RAISE EXCEPTION 'SETTLEMENT_TERMS_NOT_SET|%', v_ccode
          USING HINT = '这份合同没有结算口径(重量基准 / 谁的化验说了算 / 精炼费与惩罚的口径)—— 先在合同上写明,再重新挂接';
    END IF;

    SELECT * INTO v_batch FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'OUTPUT_BATCH_NOT_FOUND|%', p_output_batch_id; END IF;
    SELECT * INTO v_assay FROM assay_results WHERE id = p_assay_result_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', p_assay_result_id; END IF;
    IF v_assay.output_batch_id IS DISTINCT FROM p_output_batch_id THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOR_BATCH|%|%', v_assay.code, v_batch.code;
    END IF;

    -- ── ★ MES-6a-1(MES-6a Step 0 Q21,Tim):这一批挂着一件【开着的】化验争议时,结算按名拒 ───────────────
    -- 下面那两道推出来的拒绝(RESULTS_IN_DISPUTE / RESULTS_EXCEED_SPLITTING_LIMIT)一字未改:它们看的是两份数字,
    -- 这一道看的是一件被人立起来的争议 —— 立了就等它结案或撤回。本支是 INVOKER:assay_disputes 的读策略给
    -- module.output.view(上面第二道闸刚问过它),所以一个走得到这里的读者不会因为读不到而把它放过去(INVOKER-JOIN-5 那一族)。
    SELECT d.id INTO v_disp FROM assay_disputes d WHERE d.output_batch_id = p_output_batch_id AND d.status = 'open';
    IF FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_OPEN|%|%', v_batch.code, v_disp
          USING HINT = '这一批有一件开着的化验争议 —— 先结案(点名哪一份说了算)或撤回,再结算';
    END IF;

    -- ── ★ MES-6b-1(MES-6b Step 0 Q4 · Q5,Tim):这一批在【质量暂扣】里时,结算按名拒 ─────────────────────────────
    -- "还不知道这是什么,就不结算" —— 与上面争议那一道同一条规矩,而两者互相独立:结了争议不放暂扣,决定了报告不结争议。
    -- 判据只有 batch_quality_hold 一支(流水守卫、配料计划读的同一支)。本支是 INVOKER:不合格报告与产出批的读策略都认 module.output.view
    -- (上面第二道闸刚问过它),所以读者不会因为读不到报告而把它放过去。
    SELECT h.ncr_code INTO v_hold FROM batch_quality_hold(NULL::uuid, p_output_batch_id) h;
    IF FOUND THEN
        RAISE EXCEPTION 'QUALITY_HOLD_OPEN|%|%', v_batch.code, v_hold.ncr_code
          USING HINT = '这一批在质量暂扣里 —— 先让另一个人在不合格报告上做出放行的处置,再结算';
    END IF;

    -- ── ★ 化验必须说出它按哪种重量报 ★ ─────────────────────────────────────
    -- GO-3:一张按干基出的化验单被乘在湿重上,含金属被**高估**,而没有任何东西会响。
    -- **留空 = 没有人说过**,而不是"按惯例是干基" —— 所以这里拒,不猜。
    IF v_assay.weight_basis IS NULL THEN
        RAISE EXCEPTION 'ASSAY_WEIGHT_BASIS_NOT_STATED|%', v_assay.code
          USING HINT = '这份化验没有说明它按湿基还是干基报 —— 而两者会结算出不同的金额,所以不能猜';
    END IF;

    -- ── 谁的化验说了算 ────────────────────────────────────────────────────
    -- 仲裁结果【总是】可以结算:它是那条升级路径的终点。
    IF v_assay.result_party <> 'umpire'
       AND v_assay.result_party IS DISTINCT FROM (v_st->>'settling_party') THEN
        RAISE EXCEPTION 'ASSAY_PARTY_NOT_THE_SETTLING_PARTY|%|%|%',
            v_assay.code, v_assay.result_party, (v_st->>'settling_party');
    END IF;

    -- ── 两方结果不一致时,【系统不自己选】────────────────────────────────
    -- ★ 让系统按容差自动选,等于让系统**决定谁的数字是钱**;而容差为空时,
    --   它还得**编一个默认值**才做得到那件事。所以:指出,不选。
    IF v_assay.result_party <> 'umpire' THEN
        SELECT a.code, a.id INTO v_other
          FROM assay_results a
         WHERE a.output_batch_id = p_output_batch_id AND a.deleted_at IS NULL
           AND a.id <> p_assay_result_id
           AND a.result_party IN ('ours', 'counterparty')
           AND a.result_party <> v_assay.result_party
         ORDER BY a.assay_date DESC LIMIT 1;
        IF FOUND THEN
            v_lim := (v_st->>'splitting_limit_pct')::numeric;
            -- 逐元素比,取最大差
            SELECT max(abs(x.content_pct - y.content_pct)) INTO v_maxdiff
              FROM assay_result_metals x JOIN assay_result_metals y
                ON y.metal = x.metal AND y.assay_result_id = v_other.id
             WHERE x.assay_result_id = p_assay_result_id;
            IF v_maxdiff IS NOT NULL AND v_maxdiff > 0 THEN
                IF v_lim IS NULL THEN
                    RAISE EXCEPTION 'RESULTS_IN_DISPUTE|%|%|%', v_assay.code, v_other.code, v_maxdiff
                      USING HINT = '两方的化验结果不一致,而这份合同没有声明容差 —— 要么在合同里写明容差,要么记录一份仲裁结果并按它结算;系统不会替你选哪一方的数字是钱';
                ELSIF v_maxdiff > v_lim THEN
                    RAISE EXCEPTION 'RESULTS_EXCEED_SPLITTING_LIMIT|%|%|%|%', v_assay.code, v_other.code, v_maxdiff, v_lim
                      USING HINT = '两方结果的差距超过了合同声明的容差 —— 按合同该送第三方复检,并用仲裁结果结算';
                END IF;
            END IF;
        END IF;
    END IF;

    -- ── 重量基准:换算,或按名拒 ──────────────────────────────────────────
    v_basis := v_st->>'sale_weight_basis';
    v_gross := v_batch.quantity;
    v_moist := v_assay.moisture_pct;
    IF v_assay.weight_basis <> v_basis AND v_moist IS NULL THEN
        RAISE EXCEPTION 'SETTLEMENT_MOISTURE_NOT_STATED|%', v_assay.code
          USING HINT = '化验按一种基准报、合同按另一种结算,换算要用水分 —— 而这份化验没有水分,所以算不了';
    END IF;
    -- TOOLS-1 ④:换算搬进 convert_weight_basis(表达式逐字未改)。一份实现,两个调用方。
    v_swt := convert_weight_basis(v_gross, 'as_received', v_basis, v_moist);

    -- ── 逐金属:含量 → 应付量 → 计价期均价 → 金额;并扣精炼费 ────────────
    -- MES-6a-2(MES-6a Step 0 Q28,Tim):这一圈只走【按含量计价的金属】—— 化验上的氟、氯不要计价条款、不收精炼费
    --   (此前它们在这里会按名拒 SETTLEMENT_PAYABLE_NOT_STATED / REFINING_CHARGE_NOT_FILED,一份测了氟的化验就结算不了);
    --   它们只在下面惩罚那一圈被读。
    -- ★ MES-6b-1(F4;MES-6b Step 0 Q34,Tim):一种可计价的金属,这份合同(冻结的副本)把它列成了惩罚元素、而按元素罚 → 它【不进】这一圈:
    --   它在这份合同里是杂质,不是货款(此前它在这里没有计价条款,于是按名拒 SETTLEMENT_PAYABLE_NOT_STATED,一份罚铜的合同就结算不了)。
    --   它在下面惩罚那一圈被读。别的可计价金属没有计价条款,照旧按名拒。同一种物质既计价又罚,在条款那一层就被拒了(Q33)。
    FOR v_metal, v_content IN
        SELECT m.metal, m.content_pct FROM assay_result_metals m
          JOIN substances s ON s.code = m.metal AND s.role = 'payable_metal'
         WHERE m.assay_result_id = p_assay_result_id
           AND NOT COALESCE(v_st->>'penalty_basis' = 'per_element'
                    AND EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_st->'penalty_elements', '[]'::jsonb)) pe
                                 WHERE pe->>'substance' = m.metal), false)
         ORDER BY m.metal
    LOOP
        -- 把含量换算到【结算基准】上。含金属因此是不变量 —— 见抬头。
        -- TOOLS-1 ④:换算搬进 convert_grade_basis(表达式逐字未改)。
        v_content_s := convert_grade_basis(v_content, v_assay.weight_basis, v_basis, v_moist);
        v_contained := round(v_swt * v_content_s / 100.0, 4);

        SELECT (e->>'payable_pct')::numeric INTO v_payable
          FROM jsonb_array_elements(COALESCE(v_pricing, '[]'::jsonb)) e
         WHERE e->>'metal' = v_metal;
        IF v_payable IS NULL THEN
            RAISE EXCEPTION 'SETTLEMENT_PAYABLE_NOT_STATED|%', v_metal
              USING HINT = '计价系数是一条合同条款(PRICE-1 的 contract_pricing_terms)—— 没有它就不知道买方按含量的多大比例付钱';
        END IF;
        v_pay_kg := round(v_contained * v_payable / 100.0, 4);

        -- 计价期均价 —— **调 PRICE-1 那一支,不另写一份**(两份实现会悄悄分开)
        SELECT e->>'base_event', (e->>'qp_months')::int, e->>'index_code'
          INTO v_pt_event, v_pt_months, v_pt_index
          FROM jsonb_array_elements(v_pricing) e WHERE e->>'metal' = v_metal;
        -- 【卖方向今天只记得下"化验完成"这一个事件日期】发货日与到货日在这一侧
        -- 还没有落点,所以按它们定基准月的合同**按名拒**,而不是拿一个别的日期顶替。
        v_base_date := CASE WHEN v_pt_event = 'assay_complete' THEN v_assay.assay_date END;
        IF v_base_date IS NULL THEN
            RAISE EXCEPTION 'SETTLEMENT_BASE_EVENT_DATE_UNKNOWN|%', COALESCE(v_pt_event, '(none)')
              USING HINT = '卖方向今天记得下来的事件日期只有【化验完成】—— 发货日与到货日还没有落点,所以按它们定基准月的合同结算不了';
        END IF;
        SELECT qp.qp_from, qp.qp_to INTO v_qp FROM quotational_period(v_base_date, v_pt_months) qp;
        v_price := (index_period_average(v_pt_index, v_metal, v_qp.qp_from, v_qp.qp_to)
                    ->>'avg_usd_per_tonne')::numeric;
        v_mv := v_mv + round(v_pay_kg / 1000.0 * v_price, 2);

        -- 精炼费:按【含金属】吨数 —— 所以它**不随基准变**
        v_rc := 0;
        IF v_st->>'refining_charge_basis' = 'per_metal' THEN
            SELECT (e->>'usd_per_tonne_of_metal')::numeric INTO v_rc
              FROM jsonb_array_elements(COALESCE(v_st->'refining_charges', '[]'::jsonb)) e
             WHERE e->>'metal' = v_metal;
            IF v_rc IS NULL THEN
                RAISE EXCEPTION 'REFINING_CHARGE_NOT_FILED|%|%', v_ccode, v_metal
                  USING HINT = '这份合同声明了按金属收精炼费,却没有填这一种金属的费率 —— 【声明了有】与【填了多少】是两件事,而只有后者算得出钱';
            END IF;
            v_rcs := v_rcs + round(v_contained / 1000.0 * v_rc, 2);
        END IF;

        v_lines := v_lines || jsonb_build_object(
            'metal', v_metal, 'content_pct_assay', v_content,
            'content_pct_settlement', round(v_content_s, 6),
            'contained_kg', v_contained, 'payable_pct', v_payable,
            'payable_kg', v_pay_kg, 'price_usd_per_tonne', v_price,
            'qp_from', v_qp.qp_from, 'qp_to', v_qp.qp_to,
            'refining_charge_usd_per_tonne_of_metal', v_rc);
    END LOOP;

    -- ── 惩罚:按【结算重量】吨数 —— 所以它**随基准变** ────────────────────
    IF v_st->>'penalty_basis' = 'per_element' THEN
        IF COALESCE(jsonb_array_length(v_st->'penalty_elements'), 0) = 0 THEN
            RAISE EXCEPTION 'PENALTY_ELEMENTS_NOT_FILED|%', v_ccode
              USING HINT = '这份合同声明了按元素罚,却一条惩罚条款都没有填 —— 【声明了有】与【填了哪些】是两件事';
        END IF;
        FOR v_el IN SELECT e FROM jsonb_array_elements(v_st->'penalty_elements') e LOOP
            v_thr  := (v_el->>'threshold_pct')::numeric;
            v_rate := (v_el->>'usd_per_tonne_per_pct_over')::numeric;
            SELECT m.content_pct INTO v_content FROM assay_result_metals m
             WHERE m.assay_result_id = p_assay_result_id AND m.metal = v_el->>'substance';
            IF v_content IS NULL THEN CONTINUE; END IF;   -- 这份化验没测这个元素
            v_content_s := CASE
                WHEN v_assay.weight_basis = v_basis THEN v_content
                WHEN v_assay.weight_basis = 'dry' AND v_basis = 'as_received'
                    THEN v_content * (1 - v_moist / 100.0)
                ELSE v_content / (1 - v_moist / 100.0) END;
            v_over := v_content_s - v_thr;
            IF v_over > 0 THEN
                v_pen := v_pen + round(v_swt / 1000.0 * v_over * v_rate, 2);
                v_pens := v_pens || jsonb_build_object(
                    'substance', v_el->>'substance', 'threshold_pct', v_thr,
                    'content_pct_settlement', round(v_content_s, 6),
                    'pct_over', round(v_over, 6), 'rate', v_rate);
            END IF;
        END LOOP;
    END IF;

    v_amt := round(v_mv - v_rcs - v_pen, 2);
    RETURN jsonb_build_object(
        'sales_order_id', p_sales_order_id, 'output_batch_id', p_output_batch_id,
        'assay_result_id', p_assay_result_id, 'assay_code', v_assay.code,
        'settling_party_used', v_assay.result_party,
        'weight_basis_used', v_basis,
        'assay_weight_basis', v_assay.weight_basis,
        'gross_weight_kg', v_gross, 'moisture_pct', v_moist,
        'settlement_weight_kg', v_swt,
        'metal_value_usd', v_mv, 'refining_charge_usd', v_rcs,
        'penalty_usd', v_pen, 'amount_usd', v_amt,
        'breakdown', jsonb_build_object('metals', v_lines, 'penalties', v_pens),
        'terms_snapshot', v_st);
END
$function$;

CREATE OR REPLACE FUNCTION public.record_assay_result(
    p_assay_date date,
    p_metals jsonb,
    p_lab_name text DEFAULT NULL::text,
    p_certificate_ref text DEFAULT NULL::text,
    p_sample_ref text DEFAULT NULL::text,
    p_is_final boolean DEFAULT true,
    p_notes text DEFAULT NULL::text,
    p_inbound_batch_id uuid DEFAULT NULL::uuid,
    p_output_batch_id uuid DEFAULT NULL::uuid,
    -- ── PROC-6 追加(尾部,带默认,与 PROC-2c 的做法一致)────────────────────
    -- 【两个都默认 NULL,而"必填"由别处执行】
    --   weight_basis  → 触发器(旧行补不出来,所以只管新行)
    --   result_party  → 本函数里具名拒绝 + 列上 NOT NULL 兜底
    -- 这里【不】给业务默认值:默认会让"忘了填"静静变成一个可以拿去算钱的答案。
    p_weight_basis text DEFAULT NULL::text,
    p_moisture_pct numeric DEFAULT NULL::numeric,
    p_result_party text DEFAULT NULL::text,
    -- ── MES-6a-1 追加(2026-10-09,Step 0 Q9):这份结果化验的是哪一份实物样品 —— 尾部、带默认,今天的调用照旧走得通 ──
    --   样品必须挂在同一批上(SAMPLE_NOT_FOR_BATCH);可空,sample_ref 那段自由文本照旧。
    p_sample_id uuid DEFAULT NULL::uuid,
    -- ── MES-6a-2 追加(2026-10-10,Step 0 Q3 · Q4):这份化验上的指标 —— [{indicator, value}, …],尾部、带默认 ──
    --   残粉 / 箔纯度 / 粒径(assay_indicators 的码);值 ≥ 0,没有上限、没有判定(Q3)。空 = 这一份没报指标。
    p_indicators jsonb DEFAULT NULL::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_id    uuid := gen_random_uuid();
    v_code  text;
    v_el    jsonb;
    v_metal text;
    v_pct   numeric;
    v_seen  text[] := ARRAY[]::text[];
    v_count integer := 0;
    v_ind   text;
    v_val   numeric;
    v_iseen text[] := ARRAY[]::text[];
    v_icount integer := 0;
    v_so    uuid;
    v_judge jsonb;
    v_ncrs  jsonb := '[]'::jsonb;
    v_qjudged integer := 0;
BEGIN
    -- PROC-1:两个父【二选一】。记录、编号、取代共享一张表一条序列;
    -- 权限跟着父走 —— 进料化验挂 inbound 模块,产出化验挂 output 模块。
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'ASSAY_ONE_PARENT';
    END IF;
    IF p_inbound_batch_id IS NOT NULL THEN
        PERFORM require_permission('module.inbound.edit');
        IF NOT EXISTS (
            SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
        END IF;
    ELSE
        PERFORM require_permission('module.output.edit');
        IF NOT EXISTS (
            SELECT 1 FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
        END IF;
    END IF;
    IF p_assay_date IS NULL OR p_assay_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ASSAY_DATE_INVALID|%', COALESCE(p_assay_date::text, '?');
    END IF;
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;
    -- MES-6a-2:指标要么不给(NULL),要么是一张清单 —— 一个读不懂的形状不当成"没有指标"
    IF p_indicators IS NOT NULL AND jsonb_typeof(p_indicators) <> 'array' THEN
        RAISE EXCEPTION 'INDICATORS_INVALID';
    END IF;

    -- PROC-6:出具方必须明说。**在这里具名拒绝,而不是等列上的 NOT NULL 抛机器话** ——
    -- 一个具名码翻得成人话,一个 null-value violation 翻不成。
    IF p_result_party IS NULL THEN
        RAISE EXCEPTION 'ASSAY_RESULT_PARTY_REQUIRED'
          USING HINT = '这一份结果是我们出的、对手方出的、还是仲裁实验室出的?没有默认值 —— 默认会让"忘了改"变成"这是我们测的"。';
    END IF;

    -- MES-6a-1(Q9):样品必须是同一批的 —— 在这里按名拒,而不是等表上的守卫抛(两道,同一句话)
    IF p_sample_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM samples s WHERE s.id = p_sample_id
           AND s.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
           AND s.output_batch_id IS NOT DISTINCT FROM p_output_batch_id) THEN
        RAISE EXCEPTION 'SAMPLE_NOT_FOR_BATCH|%', COALESCE((SELECT code FROM samples WHERE id = p_sample_id), p_sample_id::text);
    END IF;

    v_code := next_assay_code(p_assay_date);
    INSERT INTO assay_results (id, code, inbound_batch_id, output_batch_id, assay_date, lab_name,
                               certificate_ref, sample_ref, is_final, notes,
                               weight_basis, moisture_pct, result_party, sample_id,
                               created_by, updated_by)
    VALUES (v_id, v_code, p_inbound_batch_id, p_output_batch_id, p_assay_date, p_lab_name,
            p_certificate_ref, p_sample_ref, p_is_final, p_notes,
            p_weight_basis, p_moisture_pct, p_result_party, p_sample_id,
            v_user, v_user);

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        -- 【PROC-6 顺手修的一处 PROC-4 漏网】这里原本写着
        --     v_metal NOT IN ('ni','co','li','mn','cu','al','fe')
        -- —— **那是那份金属清单的第九个副本**,而 PROC-4 声称已经清干净了。
        -- 它没有:PROC-4 的 S1 只查了 pg_constraint,【没有查函数体】。
        -- 线上实测函数体里还有四份(见 docs/known-issues.md),本刀只修它正在
        -- 重建的这一支 —— 另外三支按名排期,不在这一刀里顺手动。
        -- 现在它读字典,于是"加一种物质"真的只要一行。
        IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances WHERE code = v_metal) THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;
        v_pct := (v_el->>'content_pct')::numeric;
        IF v_pct IS NULL OR v_pct < 0 OR v_pct > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;
        INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
        VALUES (v_id, v_metal, v_pct);
        v_count := v_count + 1;
    END LOOP;

    -- ── MES-6a-2(Step 0 Q3 · Q4):指标。在字典里才收(停用与否由表单的选单管,D5 —— 与上面金属那一段同一个判据);
    --   一个指标一行;值 ≥ 0,【没有上限、没有判定】—— 一个限是一条标准,而 Q3 说没有(V17 在 MES-6b)。
    FOR v_el IN SELECT * FROM jsonb_array_elements(COALESCE(p_indicators, '[]'::jsonb))
    LOOP
        v_ind := v_el->>'indicator';
        IF v_ind IS NULL OR NOT EXISTS (SELECT 1 FROM assay_indicators WHERE code = v_ind) THEN
            RAISE EXCEPTION 'INDICATOR_INVALID|%', COALESCE(v_ind, '?');
        END IF;
        IF v_ind = ANY (v_iseen) THEN
            RAISE EXCEPTION 'DUPLICATE_INDICATOR|%', v_ind;
        END IF;
        v_iseen := v_iseen || v_ind;
        BEGIN
            v_val := (v_el->>'value')::numeric;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'INDICATOR_VALUE_INVALID|%|%', v_ind, COALESCE(v_el->>'value', '?');
        END;
        IF v_val IS NULL OR v_val < 0 THEN
            RAISE EXCEPTION 'INDICATOR_VALUE_INVALID|%|%', v_ind, COALESCE(v_el->>'value', '?');
        END IF;
        INSERT INTO assay_result_indicators (assay_result_id, indicator, value) VALUES (v_id, v_ind, v_val);
        v_icount := v_icount + 1;
    END LOOP;

    -- ── MES-6b-1(V17;MES-6b Step 0 Q26 · Q27):一份产出化验落下时,这一批若正预留给挂着【有质量验收限】的合同的销售单,当场判 ──
    --   一张单一次(judge_quality_limits 自己决定判哪一份化验 —— 合同约定那一方最新的一份、或已结案争议点名的那一份 —— 所以记下的这一份
    --   不是那一方的,就什么都不新判)。越限在同一笔事务里开一张 quality_limit 的不合格报告(→ 暂扣)。进料化验没有这一步(Q28)。
    IF p_output_batch_id IS NOT NULL THEN
        FOR v_so IN SELECT DISTINCT l.sales_order_id
                      FROM sales_order_reservations r
                      JOIN sales_order_lines l ON l.id = r.sales_order_line_id
                     WHERE r.output_batch_id = p_output_batch_id AND r.released_at IS NULL AND r.consumed_at IS NULL
        LOOP
            v_judge := judge_quality_limits(p_output_batch_id, v_so, 'assay_recorded');
            v_qjudged := v_qjudged + (v_judge->>'judged')::int;
            v_ncrs := v_ncrs || (v_judge->'ncrs');
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'assay_result_id', v_id,
        'code', v_code,
        'metal_count', v_count,
        'indicator_count', v_icount,
        'quality_judged', v_qjudged,
        'ncrs_opened', v_ncrs
    );
END;
$function$

;

-- db/functions/reserve_stock_internal.sql
-- APR-5b(2026-09-25,grilling Q7):reserve_stock 的函数体搬到这里,不问码 —— 仓库发货时部分发货要就地
-- 重新预留剩余(release_reservation_internal → 本支),而仓库不持 module.sales.edit。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.reserve_stock_internal(p_sales_order_line_id uuid, p_output_batch_id uuid, p_qty numeric, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_pair     uuid := gen_random_uuid();
    v_today    date := CURRENT_DATE;
    v_line     record;
    v_batch    record;
    v_avail    numeric;
    v_already  numeric;
    v_res_id   uuid;
    v_judge    jsonb;
BEGIN
    -- ★ APR-5b(2026-09-25):本支是 reserve_stock 的函数体,【不问调用者的码】。两个调用方各自先问:
    --   reserve_stock(module.sales.edit —— 预留是销售行为)· release_reservation_internal(部分释放就地
    --   重新预留剩余;它的调用方 release_reservation 问 module.sales.edit,ship_order 问 action.ship_goods)。
    --   EXECUTE 已从 authenticated 收回(zzz_function_grants)。

    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'SO_RESERVE_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;

    SELECT l.id, l.quantity, l.material_id, l.line_no,
           o.id AS order_id, o.code AS order_code, o.status, o.deleted_at
      INTO v_line
      FROM sales_order_lines l
      JOIN sales_orders o ON o.id = l.sales_order_id
     WHERE l.id = p_sales_order_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_line_id::text, '?');
    END IF;

    -- 【只有确认了的订单才预留】草稿是还没答应的事,给它扣住货,等于让一张
    -- 随手建的单据把库存冻起来,而没有任何人做过那个承诺。
    -- 【SO-3b:partially_shipped 同样算数】一张发了一部分的单【仍然是活的】——
    -- 剩下的行还要预留、还要发。只认 confirmed 会让任何多行订单在第一次发货
    -- 之后就再也走不下去(fixture 68 第一次跑就撞上了这个)。
    IF v_line.deleted_at IS NOT NULL OR v_line.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SO_RESERVE_ORDER_NOT_CONFIRMED|%|%',
            v_line.order_code, COALESCE(v_line.status, '?');
    END IF;

    -- 【产出批次,且还在】—— 见本表注释:预留一个进料批次会造出永远消耗不掉的
    -- 承诺库存(movement_type='sale' 被 inventory_movements_side 钉在产出侧)。
    SELECT ob.id, ob.code, ob.material_id, ob.unit
      INTO v_batch
      FROM output_batches ob
     WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_RESERVE_OUTPUT_ONLY|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    IF v_batch.material_id IS DISTINCT FROM v_line.material_id THEN
        RAISE EXCEPTION 'SO_RESERVE_MATERIAL_MISMATCH|%|%|%',
            v_batch.code,
            (SELECT code FROM materials WHERE id = v_batch.material_id),
            (SELECT code FROM materials WHERE id = v_line.material_id);
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【行的天花板 —— 判据是"这一行已经许出去多少"】一行订单最多只能许出它
    -- 自己的数量。超过就是把同一行答应了两遍 —— 屏幕上看不出来,发货那天才炸。
    --
    -- 【SO-3b fu5:此前这里只数【活预留】,而发货会把预留移出那个集合】
    -- 于是一条发满的行,天花板重新变回满额:实测 12 kg 的行发掉 12 之后又预留
    -- 了 12、又发了一次,24 kg 出库、2500 落成净借方、收入是发票的两倍。
    -- 判据换成 line_spoken_for()(已发 + 活预留),而那是【唯一一处推导】——
    -- SO-1b 改单的下限读同一个函数,不另写一遍。
    -- 第三个数的含义随之变了:它现在是"已许出去",不是"已预留"(两种语言的
    -- 句子同步改过)。
    -- ════════════════════════════════════════════════════════════════════════
    v_already := line_spoken_for(p_sales_order_line_id);
    IF v_already + p_qty > v_line.quantity THEN
        RAISE EXCEPTION 'SO_RESERVE_EXCEEDS_LINE|%|%|%', p_qty, v_line.quantity, v_already;
    END IF;

    -- 【就地求和,不调 derived_stock_qty】那个函数体里有
    -- require_permission('module.inventory.view'),而 has_permission 解析的是
    -- 【调用者】的 JWT —— DEFINER 换得了行的可见性,换不了函数体内那句对调用者
    -- 的判断。销售的人没有库存的码,调过去当场 PERMISSION_DENIED。
    -- record_output_sale 就地求和,同一个理由。
    SELECT COALESCE(sum(m.qty_delta), 0) INTO v_avail
      FROM inventory_movements m
     WHERE m.output_batch_id = p_output_batch_id
       AND m.inbound_batch_id IS NULL
       AND m.location_id IS NOT DISTINCT FROM p_location_id
       AND m.stock_status = 'available';
    IF p_qty > v_avail THEN
        RAISE EXCEPTION 'SO_RESERVE_EXCEEDS_AVAILABLE|%|%', p_qty, v_avail;
    END IF;

    -- 成对:出 available、进 committed。同批次、同库位。物理总量按构造不动,
    -- remaining_qty 一个字不变,批次的 state 也不变(承诺不是销售)。
    INSERT INTO inventory_movements
        (output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_output_batch_id, p_location_id, 'status_change_out',
         -p_qty, 'available', v_pair, v_today,
         'reserved for ' || v_line.order_code || ' line ' || v_line.line_no, v_user),
        (p_output_batch_id, p_location_id, 'status_change_in',
          p_qty, 'committed', v_pair, v_today,
         'reserved for ' || v_line.order_code || ' line ' || v_line.line_no, v_user);

    INSERT INTO sales_order_reservations
        (sales_order_line_id, output_batch_id, location_id, qty, pair_id, created_by)
    VALUES (p_sales_order_line_id, p_output_batch_id, p_location_id, p_qty, v_pair, v_user)
    RETURNING id INTO v_res_id;

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (v_line.order_id, 'reserved',
            format('line %s · %s %s %s', v_line.line_no, v_batch.code, p_qty, v_batch.unit));

    -- ★ MES-6b-1(V17;MES-6b Step 0 Q26 · Q27,Tim):预留一批【已经有化验】的产出批给一张挂着有质量验收限的合同的销售单 → 当场判。
    --   越限:预留照留(上面已经写下),同一笔事务里开一张 quality_limit 的不合格报告 —— 拒掉预留会把发现藏在一句报错后面、什么都不留下;
    --   报告就是那份记录与那个决定。之后这一批在暂扣里:发货那条腿被流水守卫拒,释放预留照常。同一份化验对同一张单只判一次
    --   (部分发货就地重新预留走到这里时,judge_quality_limits 自己跳过)。没有化验、没挂合同、合同没声明按参数 → 什么都不判。
    v_judge := judge_quality_limits(p_output_batch_id, v_line.order_id, 'reserved');

    RETURN jsonb_build_object(
        'reservation_id', v_res_id, 'pair_id', v_pair, 'qty', p_qty,
        'output_batch_id', p_output_batch_id, 'location_id', p_location_id,
        'available_after', v_avail - p_qty,
        -- 【改名,因为含义改了】此前叫 line_reserved_after,而它现在含【已发】。
        -- 一个名字说着旧含义、值是新含义,比改名更贵(今天没有任何消费方读它,
        -- 现在改是最便宜的时刻)。
        'line_spoken_for_after', v_already + p_qty,
        'line_quantity', v_line.quantity,
        'quality_judged', (v_judge->>'judged')::int,
        'ncrs_opened', v_judge->'ncrs');
END;
$function$

;

-- db/functions/blending_plan_write_children.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q20,Tim):【一份配料计划的判据与落库 —— 产出物料、目标品位、候选批次】
--   create_blending_plan 与 amend_blending_plan 共用这一段(一份判据,两个调用者 —— AGENTS.md 的预览规则同一条)。
--   ★ 内层:它【不查码】,也【不是】DEFINER(reverse_expense_internal 的同一个形状)—— 它只在两支查过 action.wo_create 的 DEFINER 函数里
--     以属主身份跑;EXECUTE 从 authenticated 收回(zzz_function_grants.sql)。
--   判的顺序就是人下一步该改什么的顺序:先产出物料,再合同,再目标,再批次。
--     ① 产出物料:存在、没删;形态【可售】(material_forms.may_be_sold,R5)—— 否则 BLEND_OUTPUT_NOT_SALEABLE|<物料>|<形态>|<中文>|<英文>;
--        形态是配料这道工序声明的产出形态 —— 否则 BLEND_OUTPUT_FORM_NOT_BLENDABLE|<物料>|<形态或空>。
--     ② 合同(可空):存在 —— 否则 BLEND_CONTRACT_NOT_FOUND。
--     ③ 目标:p_targets 为 NULL 且有合同 → 抄那份合同里【适用于这种物料】的每一条品位规格(物料为空的,或就是这种物料的;同一种金属
--        两条都有时取指名物料的那一条)。否则逐条:{grade_spec_id} → 抄那一条(必须属于这份合同 BLEND_TARGET_SPEC_NOT_FROM_CONTRACT、
--        适用于这种物料 BLEND_TARGET_SPEC_OTHER_MATERIAL),来源 contract;{metal, min_pct, max_pct} → 人敲的,来源 manual:
--        金属在字典里(METAL_INVALID)· 至少一个界(BLEND_TARGET_NEEDS_A_BOUND)· 0–100(BLEND_TARGET_PCT_INVALID)·
--        下界不高于上界(BLEND_TARGET_BOUNDS_ORDER)· 一种金属一行(BLEND_TARGET_DUPLICATE_METAL)。
--     ④ 批次:至少一行(BLEND_NO_LINES);每一行恰好一批(BLEND_LINE_ONE_BATCH)、存在且没删(INBOUND_NOT_FOUND / OUTPUT_NOT_FOUND)、
--        单位是 kg(BLEND_LINE_UNIT_NOT_KG)、物料形态是配料收的(BLEND_LINE_FORM_NOT_BLENDABLE|<批号>|<形态或空>)、
--        计划公斤数 > 0(BLEND_LINE_KG_INVALID|<批号>)、一批一行(BLEND_LINE_DUPLICATE_BATCH|<批号>)、
--        ★ 不在质量暂扣里(QUALITY_HOLD_OPEN|<批号>|<报告>,MES-6b-1 Step 0 Q24 —— 放行那一步再问一次,执行那一步由流水守卫挡)。
--        【不】拒计划的公斤数超过这一批此刻的余量 —— 计划可以是为将来排的;真投的时候引擎照旧按余量拒。
--   然后整份替换:删掉这份计划原有的目标与批次,写入新的(变更记录逐行记下删与插)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.blending_plan_write_children(p_plan_id uuid, p_output_material_id uuid, p_source_contract_id uuid, p_targets jsonb, p_lines jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_mat      record;
    v_el       jsonb;
    v_spec     contract_grade_specs%ROWTYPE;
    v_metal    text;
    v_min      numeric;
    v_max      numeric;
    v_metals   text[] := ARRAY[]::text[];
    v_ib       uuid;
    v_ob       uuid;
    v_kg       numeric;
    v_bcode    text;
    v_bunit    text;
    v_bform    text;
    v_batches  text[] := ARRAY[]::text[];
    v_hold     record;
BEGIN
    -- ① 产出物料
    SELECT m.code, m.form_code, f.may_be_sold, f.name_zh, f.name_en INTO v_mat
      FROM materials m LEFT JOIN material_forms f ON f.code = m.form_code
     WHERE m.id = p_output_material_id AND m.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'MATERIAL_NOT_FOUND|%', COALESCE(p_output_material_id::text, '?');
    END IF;
    IF v_mat.form_code IS NOT NULL AND v_mat.may_be_sold IS FALSE THEN
        RAISE EXCEPTION 'BLEND_OUTPUT_NOT_SALEABLE|%|%|%|%', v_mat.code, v_mat.form_code, v_mat.name_zh, v_mat.name_en
          USING HINT = '配料混出来的那一批必须是可以卖的形态(R5)。这一种物料的形态在法律上不许出售,所以不能是一份配料计划的产出。';
    END IF;
    IF v_mat.form_code IS NULL OR NOT EXISTS (SELECT 1 FROM operation_type_output_forms o
                                               WHERE o.operation_type_code = 'blending' AND o.form_code = v_mat.form_code) THEN
        RAISE EXCEPTION 'BLEND_OUTPUT_FORM_NOT_BLENDABLE|%|%', v_mat.code, COALESCE(v_mat.form_code, '')
          USING HINT = '配料只混出可售的粉料(黑粉、正极粉、负极粉 —— 配料这道工序声明的产出形态)。先给这种物料选对形态,或换一种物料。';
    END IF;

    -- ② 合同
    IF p_source_contract_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM contracts c WHERE c.id = p_source_contract_id) THEN
        RAISE EXCEPTION 'BLEND_CONTRACT_NOT_FOUND|%', p_source_contract_id;
    END IF;

    DELETE FROM blending_plan_targets WHERE plan_id = p_plan_id;
    DELETE FROM blending_plan_lines WHERE plan_id = p_plan_id;

    -- ③ 目标
    IF p_targets IS NULL AND p_source_contract_id IS NOT NULL THEN
        INSERT INTO blending_plan_targets (plan_id, metal, min_pct, max_pct, source, source_grade_spec_id)
        SELECT DISTINCT ON (s.metal) p_plan_id, s.metal, s.min_pct, s.max_pct, 'contract', s.id
          FROM contract_grade_specs s
         WHERE s.contract_id = p_source_contract_id
           AND (s.material_id IS NULL OR s.material_id = p_output_material_id)
         ORDER BY s.metal, s.material_id NULLS LAST;
    ELSIF p_targets IS NOT NULL THEN
        IF jsonb_typeof(p_targets) <> 'array' THEN
            RAISE EXCEPTION 'BLEND_TARGETS_INVALID';
        END IF;
        FOR v_el IN SELECT * FROM jsonb_array_elements(p_targets) LOOP
            IF NULLIF(v_el ->> 'grade_spec_id', '') IS NOT NULL THEN
                SELECT * INTO v_spec FROM contract_grade_specs s WHERE s.id = (v_el ->> 'grade_spec_id')::uuid;
                IF NOT FOUND OR p_source_contract_id IS NULL OR v_spec.contract_id <> p_source_contract_id THEN
                    RAISE EXCEPTION 'BLEND_TARGET_SPEC_NOT_FROM_CONTRACT|%', v_el ->> 'grade_spec_id'
                      USING HINT = '从合同抄的目标品位必须来自这份计划选的那一份合同。';
                END IF;
                IF v_spec.material_id IS NOT NULL AND v_spec.material_id <> p_output_material_id THEN
                    RAISE EXCEPTION 'BLEND_TARGET_SPEC_OTHER_MATERIAL|%|%', v_spec.metal,
                        (SELECT m.code FROM materials m WHERE m.id = v_spec.material_id)
                      USING HINT = '这一条品位规格是给另一种物料的,不适用于这份计划混出来的那一种。';
                END IF;
                v_metal := v_spec.metal;
                IF v_metal = ANY (v_metals) THEN
                    RAISE EXCEPTION 'BLEND_TARGET_DUPLICATE_METAL|%', v_metal;
                END IF;
                INSERT INTO blending_plan_targets (plan_id, metal, min_pct, max_pct, source, source_grade_spec_id)
                VALUES (p_plan_id, v_spec.metal, v_spec.min_pct, v_spec.max_pct, 'contract', v_spec.id);
            ELSE
                v_metal := NULLIF(btrim(COALESCE(v_el ->> 'metal', '')), '');
                IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances s WHERE s.code = v_metal) THEN
                    RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
                END IF;
                IF v_metal = ANY (v_metals) THEN
                    RAISE EXCEPTION 'BLEND_TARGET_DUPLICATE_METAL|%', v_metal;
                END IF;
                v_min := NULLIF(v_el ->> 'min_pct', '')::numeric;
                v_max := NULLIF(v_el ->> 'max_pct', '')::numeric;
                IF v_min IS NULL AND v_max IS NULL THEN
                    RAISE EXCEPTION 'BLEND_TARGET_NEEDS_A_BOUND|%', v_metal
                      USING HINT = '一条两边都不设限的目标什么也没规定。至少填下界或上界。';
                END IF;
                IF (v_min IS NOT NULL AND (v_min < 0 OR v_min > 100)) OR (v_max IS NOT NULL AND (v_max < 0 OR v_max > 100)) THEN
                    RAISE EXCEPTION 'BLEND_TARGET_PCT_INVALID|%', v_metal;
                END IF;
                IF v_min IS NOT NULL AND v_max IS NOT NULL AND v_min > v_max THEN
                    RAISE EXCEPTION 'BLEND_TARGET_BOUNDS_ORDER|%|%|%', v_metal, v_min, v_max;
                END IF;
                INSERT INTO blending_plan_targets (plan_id, metal, min_pct, max_pct, source, source_grade_spec_id)
                VALUES (p_plan_id, v_metal, v_min, v_max, 'manual', NULL);
            END IF;
            v_metals := v_metals || v_metal;
        END LOOP;
    END IF;

    -- ④ 批次
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'BLEND_NO_LINES';
    END IF;
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        v_ib := NULLIF(v_el ->> 'inbound_batch_id', '')::uuid;
        v_ob := NULLIF(v_el ->> 'output_batch_id', '')::uuid;
        IF (v_ib IS NULL) = (v_ob IS NULL) THEN
            RAISE EXCEPTION 'BLEND_LINE_ONE_BATCH';
        END IF;
        IF v_ib IS NOT NULL THEN
            SELECT b.code, b.unit, m.form_code INTO v_bcode, v_bunit, v_bform
              FROM inbound_batches b JOIN materials m ON m.id = b.material_id WHERE b.id = v_ib AND b.deleted_at IS NULL;
            IF NOT FOUND THEN RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_ib; END IF;
        ELSE
            SELECT b.code, b.unit, m.form_code INTO v_bcode, v_bunit, v_bform
              FROM output_batches b JOIN materials m ON m.id = b.material_id WHERE b.id = v_ob AND b.deleted_at IS NULL;
            IF NOT FOUND THEN RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_ob; END IF;
        END IF;
        IF v_bunit IS DISTINCT FROM 'kg' THEN
            RAISE EXCEPTION 'BLEND_LINE_UNIT_NOT_KG|%|%', v_bcode, COALESCE(v_bunit, '?');
        END IF;
        IF v_bform IS NULL OR NOT EXISTS (SELECT 1 FROM operation_type_input_forms i
                                           WHERE i.operation_type_code = 'blending' AND i.form_code = v_bform) THEN
            RAISE EXCEPTION 'BLEND_LINE_FORM_NOT_BLENDABLE|%|%', v_bcode, COALESCE(v_bform, '')
              USING HINT = '配料只收可售的粉料(黑粉、正极粉、负极粉 —— 配料这道工序声明的投料形态)。';
        END IF;
        v_kg := NULLIF(v_el ->> 'planned_kg', '')::numeric;
        IF v_kg IS NULL OR v_kg <= 0 THEN
            RAISE EXCEPTION 'BLEND_LINE_KG_INVALID|%', v_bcode;
        END IF;
        IF v_bcode = ANY (v_batches) THEN
            RAISE EXCEPTION 'BLEND_LINE_DUPLICATE_BATCH|%', v_bcode;
        END IF;
        -- ★ MES-6b-1(MES-6b Step 0 Q24,Tim):一批在质量暂扣里的货不能是一份配料计划的一行 —— 判据 batch_quality_hold(流水守卫读的同一支)
        SELECT h.ncr_code INTO v_hold FROM batch_quality_hold(v_ib, v_ob) h;
        IF FOUND THEN
            RAISE EXCEPTION 'QUALITY_HOLD_OPEN|%|%', v_bcode, v_hold.ncr_code
              USING HINT = '这一批在质量暂扣里,不能排进配料计划 —— 先让另一个人在不合格报告上做出放行的处置。';
        END IF;
        v_batches := v_batches || v_bcode;
        INSERT INTO blending_plan_lines (plan_id, inbound_batch_id, output_batch_id, planned_kg)
        VALUES (p_plan_id, v_ib, v_ob, v_kg);
    END LOOP;
END;
$function$;

-- db/functions/release_blending_plan.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q19,Tim):【放行一份配料计划】—— action.wo_release(下达工单的同一个码);
--   【建单人永远不能放行】(forbid_self_approval,按人认 —— 与 release_work_order 同一句;只有 raiser 那一条腿,计划没有"说的是谁")。
--   只放行草稿(BLEND_PLAN_NOT_DRAFT);至少一条目标(BLEND_PLAN_NO_TARGETS)与一行批次(BLEND_NO_LINES)。
--   ★ MES-6b-1(MES-6b Step 0 Q24):一行的批次在质量暂扣里 → QUALITY_HOLD_OPEN|<批号>|<报告>。
--   预测出界【不挡】放行(Q20:标出来,不拒)。不是一张审批单据(Q32:没有新审批)—— 四眼是工单那一种,不进审批引擎。
--   返回 {plan_id, code, status}。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.release_blending_plan(p_plan_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_plan blending_plans%ROWTYPE;
    v_hold record;
BEGIN
    PERFORM require_permission('action.wo_release');
    SELECT * INTO v_plan FROM blending_plans WHERE id = p_plan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_FOUND|%', COALESCE(p_plan_id::text, '?');
    END IF;
    IF v_plan.status <> 'draft' THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_DRAFT|%|%', v_plan.code, v_plan.status;
    END IF;
    PERFORM forbid_self_approval(v_plan.created_by, NULL::uuid, 'blending_plan');
    IF NOT EXISTS (SELECT 1 FROM blending_plan_targets t WHERE t.plan_id = p_plan_id) THEN
        RAISE EXCEPTION 'BLEND_PLAN_NO_TARGETS|%', v_plan.code
          USING HINT = '一份没有目标品位的配料计划没有东西可对 —— 先给至少一种金属一个界。';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM blending_plan_lines l WHERE l.plan_id = p_plan_id) THEN
        RAISE EXCEPTION 'BLEND_NO_LINES';
    END IF;
    -- ★ MES-6b-1(MES-6b Step 0 Q24,Tim):一行的批次在草稿之后进了质量暂扣 → 不放行(建 / 改那一步已经拒过;这里是它在草稿里等着的那段时间)。
    --   执行一份已经放行的计划,由流水守卫挡在投料那一条腿上(guard_quality_hold)。
    SELECT h.ncr_code, h.batch_code INTO v_hold
      FROM blending_plan_lines l
      CROSS JOIN LATERAL batch_quality_hold(l.inbound_batch_id, l.output_batch_id) h
     WHERE l.plan_id = p_plan_id
     ORDER BY h.batch_code
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'QUALITY_HOLD_OPEN|%|%', v_hold.batch_code, v_hold.ncr_code
          USING HINT = '这份计划的一行批次在质量暂扣里 —— 先让另一个人在不合格报告上做出放行的处置,或把那一行从计划里拿掉。';
    END IF;

    UPDATE blending_plans
       SET status = 'released', released_at = now(), released_by = v_user, updated_at = now(), updated_by = v_user
     WHERE id = p_plan_id;

    RETURN jsonb_build_object('plan_id', p_plan_id, 'code', v_plan.code, 'status', 'released');
END;
$function$;

CREATE OR REPLACE FUNCTION public.apply_assay_result(p_assay_result_id uuid, p_pricing_formula_id uuid DEFAULT NULL::uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_assay    record;
    v_batch    record;
    v_commit   uuid;
    v_csrc     uuid;
    v_ccode    text;
    v_live     uuid;
    v_formula  uuid;
    v_fcode    text;
    v_metals   jsonb;
    v_calc     jsonb;
    v_unit     numeric;
    v_rep      jsonb := NULL;
    v_priced   boolean := false;
    v_status   text;
    v_prior    uuid;
    v_note     text := NULL;
    v_open     receipt_price_requests%ROWTYPE;
    v_disp     uuid;
    v_supp     boolean;
    v_measured text[];
BEGIN
    PERFORM require_permission('action.apply_assay');
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    -- PROC-1:产出化验不走这条路 —— 这里的第 2-5 步全是围着应付转的,
    -- 而产出批没有应付。拆函数,不在函数里藏 IF。
    IF v_assay.output_batch_id IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_IS_OUTPUT|%', v_assay.code;
    END IF;
    IF v_assay.applied_at IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
    END IF;

    SELECT * INTO v_batch FROM inbound_batches
    WHERE id = v_assay.inbound_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_assay.inbound_batch_id;
    END IF;

    -- 0a. ★ MES-6a-1(MES-0 Q62 · MES-6a Step 0 Q18,Tim):这一批挂着一件【开着的】化验争议时,应用任何一份化验都按名拒 ——
    --     争议没结,"哪一份说了算"就还没定,而应用正是在替人做那个选择。放在批次锁之后、任何改动之前;
    --     preview_assay_price 用同一句拒(fixture 40 的那条规矩:试算拒的地方提交也拒)。结案或撤回之后放开。
    SELECT d.id INTO v_disp FROM assay_disputes d WHERE d.inbound_batch_id = v_batch.id AND d.status = 'open';
    IF FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_OPEN|%|%', v_batch.code, v_disp
          USING HINT = '这一批有一件开着的化验争议 —— 先在争议页上结案(点名哪一份说了算)或撤回,再应用';
    END IF;

    -- 0b. ★ MES-6b-1(F5;MES-6b Step 0 Q16 · Q36,Tim):一份一种可计价金属都没测的化验是一份【补充】(assay_is_supplement):
    --     只换掉它测了的那几种物质、不计价、不取代也不被取代。它不能带着一张公式来(补充不定价 —— 那一步属于一份完整的化验)。
    v_supp := assay_is_supplement(p_assay_result_id);
    v_measured := ARRAY(SELECT arm.metal FROM assay_result_metals arm WHERE arm.assay_result_id = p_assay_result_id ORDER BY arm.metal);
    IF v_supp AND p_pricing_formula_id IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_SUPPLEMENT_PRICES_NOTHING|%', v_assay.code
          USING HINT = '这份化验一种可计价的金属都没测,它只补充它测了的那几种物质 —— 不计价,所以不带公式。';
    END IF;

    -- 0. ★ ROLE-1 Batch 4b(Tim 的 Q3 · Q5 · Q6):这张收货挂着一张在等 CFO 的定价申请时 ——
    --    · 来源不是化验(手工 / 按承诺条款 / 收货台):应用按名拒 RECEIPT_PRICE_REQUEST_OPEN,
    --      一个等着批的手工价不许被一份化验从脚下换掉含量;
    --    · 来源是化验:本次取代它 —— 先撤回那一张(理由写明被哪一份取代),本次再提自己的。
    --    放在改含量【之前】:含量守卫(guard_inbound_batch_metals_price_request)在有在等的申请时拒一切写。
    SELECT * INTO v_open FROM receipt_price_requests
     WHERE inbound_batch_id = v_batch.id AND status = 'submitted';
    IF FOUND THEN
        -- ★ MES-6b-1(F5):一份补充不取代任何一份 —— 包括那张来源是化验、在等的申请;它也写不进含量(含量守卫在有在等的申请时拒一切写)。
        --   所以补充在这里一律按名拒,等那一张批了或撤了再补。
        IF v_open.source <> 'assay' OR v_supp THEN
            RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_OPEN|%|%', v_batch.code, v_open.label;
        END IF;
        PERFORM receipt_price_withdraw_internal(v_open.id,
            'Superseded by assay ' || v_assay.code || ' applied');
    END IF;

    -- 1. 批次含量 = 本化验的含量(删后重插)。分摊、估值、回收率读的都是
    --    inbound_batch_metals —— 它必须始终是"当前最可信的真相";化验行本身留作历史。
    --    PROC-1:抄进的行带出处 —— content_source='assay',指回这份单据。
    --    ★ MES-6b-1(F5):补充只换掉它测了的那几种物质(别的含量行一行不动);完整的化验照旧整份换(fixture 54E)。
    DELETE FROM inbound_batch_metals
     WHERE inbound_batch_id = v_batch.id AND (NOT v_supp OR metal = ANY (v_measured));
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct,
                                      content_source, source_assay_id, created_by, updated_by)
    SELECT v_batch.id, arm.metal, arm.content_pct, 'assay', p_assay_result_id, v_user, v_user
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    IF v_supp THEN
        -- 补充:不计价、不提申请、不碰批次的公式、不取代也不被取代 —— 只记下它被应用了
        UPDATE assay_results
        SET applied_at = now(), applied_by = v_user, updated_by = v_user
        WHERE id = p_assay_result_id;
        SELECT pricing_status INTO v_status FROM inbound_batches WHERE id = v_batch.id;
        RETURN jsonb_build_object(
            'assay_result_id', p_assay_result_id,
            'code', v_assay.code,
            'inbound_batch_id', v_batch.id,
            'batch_code', v_batch.code,
            'supplement', true,
            'replaced_substances', to_jsonb(v_measured),
            'priced', false,
            'price_requested', false,
            'price_request', NULL,
            'superseded_request_id', NULL,
            'pricing_status', v_status,
            'note', 'supplement: replaces only the substances it measured; prices nothing');
    END IF;

    -- MES-6a-2(Step 0 Q28):交给计价引擎的只有按含量计价的金属 —— 一份同时测了氟、氯的化验照常落含量(上一步原样抄全部),
    --   而惩罚元素不进计价(引擎对它们按名拒;不计价的东西本来就不该出现在一张按含量付钱的清单里)。
    SELECT payable_metals_only(jsonb_agg(jsonb_build_object('metal', arm.metal, 'content_pct', arm.content_pct)))
    INTO v_metals
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    -- 2. 【结算条款 = 承诺时抄下的副本】(FIN-27)。解析次序与从前解析公式同构:
    --    批次自己的承诺 → 它那条采购行的承诺。活公式在这里【一次都不读】。
    v_commit := resolve_pricing_commitment(v_batch.id);

    IF p_pricing_formula_id IS NOT NULL THEN
        -- 结算时才指名公式(无采购单的现场收货):那一刻【就是】承诺时刻,现在抄。
        -- 已经有副本了就不许被顶掉 —— 副本一旦落下,它就是记录。
        IF v_commit IS NULL THEN
            v_commit := commit_pricing_terms(p_pricing_formula_id, NULL, v_batch.id);
        ELSE
            SELECT c.source_formula_id, c.source_formula_code INTO v_csrc, v_ccode
            FROM pricing_term_commitments c WHERE c.id = v_commit;
            IF v_csrc IS DISTINCT FROM p_pricing_formula_id THEN
                RAISE EXCEPTION 'PRICING_TERMS_ALREADY_COMMITTED|%|%', v_batch.code, v_ccode;
            END IF;
        END IF;
    END IF;

    IF v_commit IS NOT NULL THEN
        -- 3. 与计价器同一份算术(calculate_metal_price_from_terms),条款来自副本;
        --    再走与手工计价【同一条】重计价路径(reprice_inbound_batch)—— 价差分录、
        --    price_history、1200/5000 拆账三件事只存在一份实现。
        --    参考日默认化验日:结算价随行情,行情看化验那天。
        SELECT c.source_formula_id, c.source_formula_code INTO v_formula, v_fcode
        FROM pricing_term_commitments c WHERE c.id = v_commit;

        v_calc := calculate_metal_price_from_terms(
            pricing_terms_of_commitment(v_commit), v_metals, v_batch.quantity,
            COALESCE(p_reference_date, v_assay.assay_date));
        v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;

        IF v_unit > 0 THEN
            -- ★ ROLE-1 Batch 4b:算出来的价不再当场过账 —— 在第 7 步提一张申请(来源 assay),
            --   等本次的含量、取代链与 applied_at 都落定之后(指纹要看见"它就是最近一份已应用的化验")。
            v_priced := true;
        ELSE
            -- 低品位料可能"不值它的处理费"(净值 ≤ 0)。负价不入价格机器 ——
            -- 含量照常落地,价格留给人决断。
            v_note := 'computed price not positive: ' || COALESCE(v_unit::text, '?');
        END IF;
    ELSE
        -- 4. 没有副本。有活公式引用【却没有副本】= FIN-27 之前留下的承诺,当时没记
        --    条款 —— 点名拒。悄悄退回去读活公式正是本切要拆掉的行为,而把今天的
        --    公式当成当时谈定的条款,是编造一份承诺(D:不回填)。
        --    完全没有公式引用的批次照旧:手工定价的采购本来就由人定价,不是错误。
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        IF v_live IS NOT NULL THEN
            RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
                COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
        END IF;
        v_note := 'no pricing formula resolved';
    END IF;

    -- 5. 批次挂上这张公式。★ ROLE-1 Batch 4b(Tim 的 Q3):pricing_status 【不在这里】升 final ——
    --    只在 CFO 批准本次提的那张申请时(receipt_price_post_internal),而且只当这份化验 is_final。
    UPDATE inbound_batches
    SET pricing_formula_id = COALESCE(v_formula, pricing_formula_id),
        updated_by = v_user
    WHERE id = v_batch.id;

    -- 6. 取代链:此前已执行且未被取代的化验,superseded_by 指向本次
    -- code 作平局裁决:applied_at 在同一事务里可能相同(now() 冻结),
    -- 而编号无缝且单调 —— 排序必须确定
    -- ★ MES-6a-1(D4 · Step 0 Q20):只取代【同一出具方】的上一份 —— 应用一份对手方或仲裁的结果【不】把我们的那一份标成
    --   superseded(assay_results.superseded_by 的列注释:"对手方的结果不是对我们结果的取代")。此前这里不看出具方,
    --   一旦有人应用对手方的结果就会静静地盖掉我们自己测到的东西(今天线上从没应用过一份非 ours 的进料化验,所以它从没开过火)。
    -- ★ MES-6b-1(F5):一份补充不被取代 —— 取代链只在完整的化验之间连(assay_is_supplement)。
    SELECT id INTO v_prior FROM assay_results
    WHERE inbound_batch_id = v_batch.id AND id <> p_assay_result_id
      AND result_party = v_assay.result_party
      AND applied_at IS NOT NULL AND superseded_by IS NULL AND deleted_at IS NULL
      AND NOT assay_is_supplement(id)
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_prior IS NOT NULL THEN
        UPDATE assay_results SET superseded_by = p_assay_result_id, updated_by = v_user
        WHERE id = v_prior;
    END IF;

    UPDATE assay_results
    SET applied_at = now(), applied_by = v_user, updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 7. ★ ROLE-1 Batch 4b(Tim 的 Q3):同一事务里提一张定价申请,来源 assay,提单人 = 按应用的这个人。
    --    提交时照批准那一刻的同一支过账试跑;二级除了提单人再没有别人批得动 → 整次应用按名拒
    --    (RECEIPT_PRICE_NO_OTHER_DECIDER,Tim 的 Q1)。审批关着时当场过账,is_final 时同时升 final。
    IF v_priced THEN
        v_rep := receipt_price_submit_internal(v_batch.id, v_unit, 'USD', 'assay', p_assay_result_id,
                                               v_commit, 'Assay ' || v_assay.code || ' applied');
    END IF;
    SELECT pricing_status INTO v_status FROM inbound_batches WHERE id = v_batch.id;

    -- 完整分解:界面展示的、向供应商/审计师解释调整的,就是这一份 —— 每个数都留
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        -- ★ ROLE-1 Batch 4b:priced = 这一次【已经过了账】(只在审批关着时);
        --   price_requested = 提了一张定价申请,它的编号与状态在 price_request 里。
        'priced', COALESCE(v_rep->>'status' = 'approved', false),
        'price_requested', v_priced,
        'price_request', v_rep,
        'superseded_request_id', v_open.id,
        'formula_code', v_fcode,
        -- FIN-27:结算按【哪一份承诺】算的 —— 供应商问起来要指得出那份副本
        'commitment_id', v_commit,
        'old_unit_price', v_rep->'old_unit_price',
        'new_unit_price', v_rep->'new_unit_price',
        'price_delta_usd', v_rep->'price_delta_usd',
        'in_stock_ratio', v_rep->'in_stock_ratio',
        'inventory_share_usd', v_rep->'inventory_share_usd',
        'cost_share_usd', v_rep->'cost_share_usd',
        'journal_code', v_rep->'journal_code',
        'pricing_status', v_status,
        'supplement', false,
        'replaced_substances', to_jsonb(v_measured),
        'note', v_note
    );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.apply_output_assay(p_assay_result_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_assay record;
    v_batch record;
    v_prior uuid;
    v_count integer;
    v_run   record;
    v_supp  boolean;
    v_measured text[];
BEGIN
    PERFORM require_permission('action.apply_assay');
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    -- 进料化验不走这条路:它的应用【就是】重算应付,少了那一半不叫应用。
    IF v_assay.output_batch_id IS NULL THEN
        RAISE EXCEPTION 'ASSAY_IS_INBOUND|%', v_assay.code;
    END IF;
    IF v_assay.applied_at IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
    END IF;

    SELECT * INTO v_batch FROM output_batches
    WHERE id = v_assay.output_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_assay.output_batch_id;
    END IF;

    -- ★ MES-6b-1(F5;MES-6b Step 0 Q16 · Q36,Tim):一份一种可计价金属都没测的化验是一份【补充】(assay_is_supplement)——
    --   只换掉它测了的那几种物质、不取代也不被取代。此前它在这里照整份换:一份只测了氟、氯的产出化验会把这一批的镍、钴含量整个抹掉,
    --   之后销售报价按名拒 NO_METAL_CONTENT、按金属价值的成本分摊拒 NO_METAL_VALUE(Step 0 §1.10)。完整的化验照旧整份换。
    v_supp := assay_is_supplement(p_assay_result_id);
    v_measured := ARRAY(SELECT arm.metal FROM assay_result_metals arm WHERE arm.assay_result_id = p_assay_result_id ORDER BY arm.metal);

    -- 批次含量 = 本化验的含量(删后重插,同进料侧)。行带出处;updated_at/created_at
    -- 因此更新 —— 过期视图的第六个来源读的就是它,这一写【就是】举旗动作本身。
    DELETE FROM output_batch_metals
     WHERE output_batch_id = v_batch.id AND (NOT v_supp OR metal = ANY (v_measured));
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct,
                                     content_source, source_assay_id, created_by, updated_by)
    SELECT v_batch.id, arm.metal, arm.content_pct, 'assay', p_assay_result_id, v_user, v_user
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    -- 取代链:与进料侧同一条规则,按【产出批】成链(进料链与产出链互不相扰)
    -- ★ MES-6a-1(D4 · Step 0 Q20):与进料侧同一条修正 —— 只取代【同一出具方】的上一份;应用对手方或仲裁的结果不盖掉我们的。
    -- ★ MES-6b-1(F5):一份补充不取代任何一份,也不被任何一份取代 —— 取代链只在完整的化验之间连。
    SELECT id INTO v_prior FROM assay_results
    WHERE output_batch_id = v_batch.id AND id <> p_assay_result_id
      AND result_party = v_assay.result_party
      AND applied_at IS NOT NULL AND superseded_by IS NULL AND deleted_at IS NULL
      AND NOT assay_is_supplement(id)
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_supp THEN
        v_prior := NULL;
    END IF;
    IF v_prior IS NOT NULL THEN
        UPDATE assay_results SET superseded_by = p_assay_result_id, updated_by = v_user
        WHERE id = v_prior;
    END IF;

    UPDATE assay_results
    SET applied_at = now(), applied_by = v_user, updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 产出它的那张加工单:若已分摊,这次应用让 metal_value 拆分过期(过期视图
    -- 自己会说;这里把"哪张单、有没有分摊过"报出来,界面不用再拼)。
    SELECT r.id, r.code, r.allocated_at INTO v_run
    FROM processing_outputs po
    JOIN processing_runs r ON r.id = po.run_id AND r.deleted_at IS NULL
    WHERE po.output_batch_id = v_batch.id
    LIMIT 1;

    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'output_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'metal_count', v_count,
        'supplement', v_supp,
        'replaced_substances', to_jsonb(v_measured),
        'superseded_prior', v_prior IS NOT NULL,
        'producing_run_code', v_run.code,
        'producing_run_allocated_at', v_run.allocated_at,
        'allocation_now_stale', v_run.allocated_at IS NOT NULL
    );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.preview_apply_output_assay(p_output_batch_id uuid, p_assay_result_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_assay   record;
    v_batch   record;
    v_run     record;
    v_current jsonb;
    v_next    jsonb := NULL;
    v_supp    boolean := NULL;
    v_replaces jsonb := NULL;
BEGIN
    -- 试算给要按"应用"的人看 —— 权限同 apply_output_assay
    PERFORM require_permission('action.apply_assay');

    SELECT * INTO v_batch FROM output_batches
    WHERE id = p_output_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    IF p_assay_result_id IS NOT NULL THEN
        SELECT * INTO v_assay FROM assay_results
        WHERE id = p_assay_result_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
        END IF;
        -- 与 apply_output_assay 同一串拒绝,同一串码(试算在应用会拒的地方同样拒)
        IF v_assay.output_batch_id IS NULL THEN
            RAISE EXCEPTION 'ASSAY_IS_INBOUND|%', v_assay.code;
        END IF;
        IF v_assay.output_batch_id <> p_output_batch_id THEN
            -- 挂在别的产出批上:对这个批次而言它不存在
            RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', v_assay.code;
        END IF;
        IF v_assay.applied_at IS NOT NULL THEN
            RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
        END IF;

        SELECT jsonb_agg(jsonb_build_object('metal', arm.metal, 'content_pct', arm.content_pct)
                         ORDER BY arm.metal)
        INTO v_next
        FROM assay_result_metals arm
        WHERE arm.assay_result_id = p_assay_result_id;
        -- ★ MES-6b-1(F5):与 apply_output_assay 同一支判据 —— 一份补充只换掉它测了的那几种物质(试算把那几种说出来,页面照它说)
        v_supp := assay_is_supplement(p_assay_result_id);
        SELECT COALESCE(jsonb_agg(arm.metal ORDER BY arm.metal), '[]'::jsonb) INTO v_replaces
        FROM assay_result_metals arm
        WHERE arm.assay_result_id = p_assay_result_id;
    END IF;

    -- 当前含量,带出处 —— "被顶掉的是谁说的数"是这个预览存在的一半理由
    SELECT jsonb_agg(jsonb_build_object(
               'metal', obm.metal,
               'content_pct', obm.content_pct,
               'content_source', obm.content_source,
               'source_assay_code', src.code)
           ORDER BY obm.metal)
    INTO v_current
    FROM output_batch_metals obm
    LEFT JOIN assay_results src ON src.id = obm.source_assay_id
    WHERE obm.output_batch_id = p_output_batch_id;

    -- 产出它的加工单与过期后果。谓词与过期视图第六源同一条判断
    -- (metal_value 限定);fixture 54 的 I/D 臂把两者钉在一起。
    SELECT r.id, r.code, r.allocated_at, r.allocation_basis INTO v_run
    FROM processing_outputs po
    JOIN processing_runs r ON r.id = po.run_id AND r.deleted_at IS NULL
    WHERE po.output_batch_id = p_output_batch_id
    LIMIT 1;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'batch_code', v_batch.code,
        'current_metals', COALESCE(v_current, '[]'::jsonb),
        'assay_metals', v_next,
        'supplement', v_supp,
        'replaces', v_replaces,
        'producing_run_id', v_run.id,
        'producing_run_code', v_run.code,
        'producing_run_allocated_at', v_run.allocated_at,
        'producing_run_basis', v_run.allocation_basis,
        'will_flag_stale', v_run.allocated_at IS NOT NULL
                           AND v_run.allocation_basis = 'metal_value'
    );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.preview_assay_price(p_inbound_batch_id uuid, p_metals jsonb, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch  record;
    v_commit uuid;
    v_live   uuid;
    v_calc   jsonb;
    v_unit   numeric;
    v_impact jsonb := NULL;
    v_disp   uuid;
    v_sub    jsonb;
BEGIN
    PERFORM require_permission('action.apply_assay');
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;

    SELECT id, code, quantity, pricing_formula_id, purchase_order_line_id
    INTO v_batch FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    -- ★ MES-6a-1(MES-6a Step 0 Q18):与 apply_assay_result 同一句拒 —— 这一批挂着一件开着的化验争议(fixture 40 F 臂:两侧同一个码)
    SELECT d.id INTO v_disp FROM assay_disputes d WHERE d.inbound_batch_id = v_batch.id AND d.status = 'open';
    IF FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_OPEN|%|%', v_batch.code, v_disp
          USING HINT = '这一批有一件开着的化验争议 —— 先在争议页上结案(点名哪一份说了算)或撤回,再应用';
    END IF;

    -- ★ MES-6b-1(F5;MES-6b Step 0 Q16,Tim):一份一种可计价金属都没有的清单是一份【补充】—— 应用它只换掉它测了的那几种物质、不计价
    --   (apply_assay_result 同一个判据:可计价的金属一种都没有)。试算不再把它送进引擎撞 NO_METALS,而是当面说"补充,只换这几种,不计价"。
    SELECT COALESCE(jsonb_agg(e ->> 'metal' ORDER BY e ->> 'metal'), '[]'::jsonb) INTO v_sub
      FROM jsonb_array_elements(COALESCE(p_metals, '[]'::jsonb)) e;
    IF jsonb_array_length(COALESCE(payable_metals_only(p_metals), '[]'::jsonb)) = 0 THEN
        RETURN jsonb_build_object('calc', NULL, 'impact', NULL, 'supplement', true, 'replaces', v_sub);
    END IF;

    v_commit := resolve_pricing_commitment(v_batch.id);
    IF v_commit IS NULL THEN
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        IF v_live IS NOT NULL THEN
            RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
                COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
        END IF;
        RETURN jsonb_build_object('calc', NULL, 'impact', NULL);
    END IF;

    -- MES-6a-2(Q28):与 apply_assay_result 同一句 —— 惩罚元素不进计价(fixture 40 的规矩:试算与应用算的是同一份清单)。
    v_calc := calculate_metal_price_from_terms(
        pricing_terms_of_commitment(v_commit), payable_metals_only(p_metals), v_batch.quantity, p_reference_date);
    v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;
    -- 净值 ≤ 0 时不试算:apply_assay_result 那时也不定价(落含量、记 note),
    -- 【这是警告不是拒绝】—— 页面的琥珀提示照旧,按钮保持可用。
    IF v_unit > 0 THEN
        -- 计价口径是 USD/kg(行情与处理费都按 USD/吨),提交也是按 USD 递给
        -- reprice_inbound_batch 的 —— 币种在这里说出来,两边才对得上。
        v_impact := preview_reprice_inbound_batch(p_inbound_batch_id, v_unit, 'USD');
    END IF;
    RETURN jsonb_build_object('calc', v_calc, 'impact', v_impact);
END;
$function$;

CREATE OR REPLACE FUNCTION public.unapply_assay_result(p_assay_result_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_assay  record;
    v_latest uuid;
    v_req    uuid;
    v_supp   boolean;
    v_removed integer := 0;
BEGIN
    -- PROC-1:先读单据才知道父是谁,权限判在任何改动之前(定义者身份读,不漏行)
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND OR v_assay.applied_at IS NULL THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    PERFORM require_permission('action.apply_assay');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 只许撤最近一次:链条中间抽走一环,superseded_by 的叙事就断了。
    -- 链按【父】各自成链 —— 同一张表里进料链与产出链互不相扰。
    -- code 作平局裁决(applied_at 同事务内可能相同,编号无缝单调)。
    SELECT id INTO v_latest FROM assay_results
    WHERE (CASE WHEN v_assay.inbound_batch_id IS NOT NULL
                THEN inbound_batch_id = v_assay.inbound_batch_id
                ELSE output_batch_id = v_assay.output_batch_id END)
      AND applied_at IS NOT NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_latest IS DISTINCT FROM p_assay_result_id THEN
        RAISE EXCEPTION 'NOT_LATEST_ASSAY|%', v_assay.code;
    END IF;

    UPDATE assay_results
    SET applied_at = NULL, applied_by = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' unapplied] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 被本次取代的上一份化验,链解开
    UPDATE assay_results SET superseded_by = NULL, updated_by = v_user
    WHERE superseded_by = p_assay_result_id;

    -- ★ MES-6b-1(F5;MES-6b Step 0 Q36,Tim):撤一份【补充】只删它自己写下的那几行含量(content_source = 'assay' 且出处是它)——
    --   它只补了那几种物质,撤掉它就把那几种拿走,别的含量一行不动。一份完整的化验照旧【不】回含量(下面那段理由原样成立)。
    v_supp := assay_is_supplement(p_assay_result_id);
    IF v_supp THEN
        IF v_assay.inbound_batch_id IS NOT NULL THEN
            DELETE FROM inbound_batch_metals
             WHERE inbound_batch_id = v_assay.inbound_batch_id AND content_source = 'assay' AND source_assay_id = p_assay_result_id;
        ELSE
            DELETE FROM output_batch_metals
             WHERE output_batch_id = v_assay.output_batch_id AND content_source = 'assay' AND source_assay_id = p_assay_result_id;
        END IF;
        GET DIAGNOSTICS v_removed = ROW_COUNT;
    END IF;

    -- ★ ROLE-1 Batch 4b(Tim 的 Q3):这份化验还挂着一张在等 CFO 的定价申请 → 撤回它,理由写明是
    --   哪一份化验、为什么撤。已经批过的价【不动】(下面那段刻意不回价的理由原样成立)。
    SELECT id INTO v_req FROM receipt_price_requests
     WHERE assay_result_id = p_assay_result_id AND status = 'submitted';
    IF v_req IS NOT NULL THEN
        PERFORM receipt_price_withdraw_internal(v_req,
            'Assay ' || v_assay.code || ' unapplied: ' || btrim(p_reason));
    END IF;

    -- 【刻意不回价、不回含量】(一份完整的化验;补充见上面)撤销"已执行"标记只是承认这份结果不再作数;
    -- 价格与含量退回到哪一版,是新化验或手工计价的显式动作 —— 静默回滚一个
    -- 已经过完账、可能已被分摊读走的状态,比留着它更危险。
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_assay.inbound_batch_id,
        'output_batch_id', v_assay.output_batch_id,
        'reverted_price', false,
        'withdrawn_price_request_id', v_req,
        'supplement', v_supp,
        'content_rows_removed', v_removed
    );
END;
$function$
;

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
        ('ncr',                    ARRAY['module.quality.view'],   'nonconformance_reports', 'id', 'table', NULL)
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
        ('contract',          11, 'contract_quality_limits',          'contracts',                    'contract_id',         '{}'::jsonb, 'down', true, true)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

CREATE OR REPLACE FUNCTION public.arm_permission_any(p_item_type text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE WHEN p_item_type = 'margin_cost_not_allocated'
                THEN ARRAY['module.finance.view', 'module.processing.view']
                -- MES-6b-1:暂扣的判据(batch_quality_hold)以读者身份读不合格报告与产出批 —— 读者要持产出查看码,才不会少看一行
                WHEN p_item_type = 'quality_hold_reserved'
                THEN ARRAY['module.output.view']
           END;
$function$;

CREATE OR REPLACE FUNCTION public.arm_permission_widen(p_item_type text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    -- 【放宽】:持有其中任一码的读者,即便没有那一支声明的 permission,也看得见它。
    -- 与 arm_permission_any() 【方向相反】—— 那一个是【收窄】(与 permission 相与)。
    -- 两个名字很像而语义相反,所以两处注释互相点名。
    -- 免柜期是【钱】的事(滞港费),而录里程碑的人在操作侧:两边都要看得见,
    -- 而它们之间没有共同的权限码,所以只能放宽。
    -- NAV-REG-1:物流那一半从 module.purchasing.view 换成 module.logistics.view。
    -- EQP-2c:保养那两支同理 —— 机器卡在财务、干活的人在加工,而它们底下每一张
    -- 表/视图的读者都是这两个码的 OR。不放宽,财务会在首页读到「受限」,
    -- 而他明明读得到那张状态视图。
    SELECT CASE WHEN p_item_type = 'free_time_expiring'
                THEN ARRAY['module.logistics.view', 'module.finance.view']
                WHEN p_item_type IN ('equipment_service_due', 'equipment_service_approaching')
                THEN ARRAY['module.processing.view', 'module.finance.view']
                -- MES-6b-1(Step 0 Q38):一批被暂扣的货还挂着预留 —— 质量那一侧(决定报告的人)与销售那一侧(那张单的人)都要看得见
                WHEN p_item_type = 'quality_hold_reserved'
                THEN ARRAY['module.sales.view']
           END;
$function$;

-- ── 6 · 视图:不合格报告的读面(新)· 待定值多 V17 一行 · 提醒多三支(镜像原样,同列)─────────────────────────

-- db/views/ncr_rows.sql
-- MES-6b-1(2026-10-15,MES-6b Step 0 Q7 · Q9 · Q22 · Q39,Tim):【一张不合格报告与它此刻的样子】—— 报告清单、报告页、批次页上的暂扣那一行读它。
--   报告自己的列,加上几样显示用的标签(批号、化验单号、销售单号、合同编号、钱的那一张单据的标签 —— 标签跟着单据走,常设决定 3),
--   一行判定的内容(系统开的那一张:参数、值、抄下的限、结果),以及 holding:这一张此刻扣不扣着它那一批(判据 ncr_holds,纯函数 ——
--   这里以属主的眼睛读批次的余量再问它,于是一个只持质量查看码的读者也读得到"拒收而货还在"那一种)。
--   【门】质量查看码,或那一批自己那一页的查看码(与 nonconformance_reports 的读策略同一句)。属主视图:读批次、化验、单据、判定不再过
--   各自的 RLS,所以条件写在末尾的 WHERE 里一次。没有金额,不遮(报告不带金额;钱的那一张单据只给出它的标签)。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.

CREATE VIEW public.ncr_rows WITH (security_invoker = off) AS
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
    ncr_holds(n.status, n.disposition, COALESCE(ib.deleted_at, ob.deleted_at), COALESCE(ib.remaining_qty, ob.remaining_qty)) AS holding
   FROM nonconformance_reports n
     LEFT JOIN inbound_batches ib ON ib.id = n.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = n.output_batch_id
     LEFT JOIN assay_results a ON a.id = n.assay_result_id
     LEFT JOIN sales_orders so ON so.id = n.sales_order_id
     LEFT JOIN quality_limit_judgements j ON j.id = n.judgement_id
     LEFT JOIN contracts c ON c.id = j.contract_id
     LEFT JOIN invoice_requests ir ON ir.id = n.penalty_invoice_request_id
     LEFT JOIN receipt_price_requests pr ON pr.id = n.penalty_price_request_id
  WHERE has_permission('module.quality.view'::text)
     OR (n.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
     OR (n.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text));

COMMENT ON VIEW public.ncr_rows IS
    'MES-6b-1:一张不合格报告与它此刻的样子 —— 报告的列、显示用的标签(批号、化验、销售单、合同、钱的那一张单据,标签跟着单据走)、系统开的那一张的判定内容,以及 holding(这一张此刻扣不扣着它那一批 —— ncr_holds,属主读余量)。门与 nonconformance_reports 的读策略同一句(质量查看码,或那一批自己的查看码)。没有金额。';

GRANT SELECT ON public.ncr_rows TO authenticated;
REVOKE ALL ON public.ncr_rows FROM anon;

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
                  WHERE cst.contract_id = c.id AND cst.quality_limit_basis IS NOT NULL))) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程);MES-3a 加 V2(执照 × 类别的库存上限)、V29(NEA 类别与物料的类别)、V3(每个安全状态的滞留提醒天数)、V4(每个安全状态要不要隔离)与 V34(隔离库位);MES-3b 加 V30(危险品编号的标记 · 包装说明 · 标签尺寸)、V31(电池料的 HS 编码)与 V35(电池料的危险品编号);MES-4a 加 V1(转化型工序的物料平衡容差)与 V36(声明了有范围的参数的上下限),并把 V6 的去处搬到班次字典(V6 同时答 V7);MES-4b 加 V10(勾了电解液挥发的工序的电解液份额)与 V11(交叉污染流的警戒线)。MES-5a-1 加 V9(物料的放电通过电压,只在那种物料有了放电结果之后才列);MES-5a-2 加 V25(共用池的电怎么摊,有共用池电表而规则为空时一行)。MES-5b-1 加 V37(每道工序 × 每种产出形态的预期质量得率;只在那道工序有了至少一张 MES-4a 之后的消耗炉次时才列 —— V9 的先例:没人能动手的行不列)。MES-6a-1 加 V16(没有合同天数的样品留多少天;只在有一份没处置、留样日 Not yet set 的样品时才列)与 V14(仲裁费怎么分;每一份有过一件开着或已结案的争议而规则为空的合同一行)。MES-6b-1 加 V17(卖方合同的质量验收限;每一份挂了销售单而口径没声明的卖方合同一行)。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行
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

-- ── 7 · 守卫上表(与各自的表镜像逐字同一份)────────────────────────────────────────────────────
-- 7a · 惩罚条款的角色守卫改收一组角色(F4):触发器的参数是建的时候定死的,所以 DROP 再建
DROP TRIGGER trg_contract_penalty_elements_substance_role ON public.contract_penalty_elements;
CREATE TRIGGER trg_contract_penalty_elements_substance_role
    BEFORE INSERT OR UPDATE OF substance ON public.contract_penalty_elements
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_role('payable_metal,penalty_element', 'substance');
-- 7b · 一种物质要么计价、要么罚(两张条款表各一支,同一支函数)
CREATE TRIGGER trg_contract_penalty_elements_unpriced
    BEFORE INSERT OR UPDATE OF substance, contract_id ON public.contract_penalty_elements
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_priced_and_penalised();
CREATE TRIGGER trg_contract_pricing_terms_unpenalised
    BEFORE INSERT OR UPDATE OF metal, contract_id ON public.contract_pricing_terms
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_priced_and_penalised();
-- 7c · 质量暂扣守在流水上
CREATE TRIGGER trg_inventory_movements_quality_hold
    BEFORE INSERT ON public.inventory_movements
    FOR EACH ROW EXECUTE FUNCTION public.guard_quality_hold();
-- 7d · 惩罚条款的表注释(F4 改了它收什么)
COMMENT ON TABLE public.contract_penalty_elements IS
    'SETTLE-1:有害元素惩罚 —— **物质 + 阈值 + 费率**,三样都是合同条款,逐物质一行。前置条件(substances 字典)已完成,所以这里挂的是**外键而不是又一列自由文本**(F7:自由文本迟早要变字典,拖延很贵)。★★**费率的形状是【一种】写法,不是唯一一种**★★:本表表达「超过阈值后,每超 1 个百分点、每吨**结算重量**收多少美元」;真实合同还有阶梯、封顶、按批一口价等写法 —— **Tim 没有给条款清单**,所以本刀只建这一种,并把这句话写在这里,好让下一个拿到真合同的人知道该在哪儿加,而不是以为这就是全部。★**惩罚按结算重量收,所以它随湿基/干基变**★(与 RC 相反,RC 按含金属吨数、而含金属是不变量)—— 两条合起来解释了为什么同一批货按湿基与按干基结算出**不同的金额**。★**曾经的具名缺席,已经补上**★:访谈点名的头两个惩罚元素是**氟与氯**;MES-6a-2(2026-10-10)把它们加进了 substances(role = penalty_element)。★**MES-6b-1(F4,Q15)起本表收惩罚元素或可计价的金属**★(铜、铝在镍黑粉里是杂质;守卫 guard_substance_role,other 按名拒 SUBSTANCE_NOT_PENALTY_ELEMENT|<码>);同一份合同里一种物质既计价又罚按名拒 SUBSTANCE_PRICED_AND_PENALISED|<码>,结算的计价圈跳过被列为惩罚元素的可计价金属。阈值以 % 记(惩罚元素的阈值屏幕上旁带 ppm;可计价金属的阈值只写 %),费率仍是每超 1 个百分点。';

-- ── 8 · 权限目录一行 + 它声明的查看码(与 db/tables/permissions.sql 逐字同一份)· 单据登记 NCR(与 db/tables/document_types.sql 那一行同一份)──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.ncr_decide', 'action', 'Decide non-conformance reports', '决定不合格报告', 'Decide an open non-conformance report: accept, accept with a penalty (naming the credit note request or receipt price request that carries the money), rework, downgrade or reject. Every disposition except reject releases the quality hold on the batch. Nobody decides a report they opened themselves (judged per person); a report the system opened on a quality-limit breach may be decided by any holder. Opening a report is Quality (edit).', '决定一张开着的不合格报告:接受、带罚接受(指出钱走的那张贷项通知申请或收货定价申请)、返工、降级或拒收。除拒收之外,每一种处置都解除那一批的质量暂扣。开单人永远不能决定自己开的那一张(按人认);系统因质量验收限越限开的那一张,任何持码人都能决定。开一张报告是「质量(编辑)」。', 1240);
UPDATE public.permissions SET requires_view_any = ARRAY['module.quality.view'] WHERE code = 'action.ncr_decide';
INSERT INTO public.document_types (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission) VALUES
    ('ncr', 'NCR', 'nonconformance_reports', 'gapless', NULL, '/quality/ncr', 'detail', 'description', ARRAY['description']::text[], ARRAY['module.quality.view']::text[]);

-- ── 9 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.contract_quality_limits
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.contract_quality_limits
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.quality_limit_judgements
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.quality_limit_judgements
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.nonconformance_reports
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.nonconformance_reports
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 10 · 授权(MES-6b Step 0 Q9):action.ncr_decide → admin · cco · cto —— 本刀唯一的授权改动 ──
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'action.ncr_decide' FROM roles r WHERE r.code IN ('admin', 'cco', 'cto')
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 11 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.decide_ncr(uuid, text, text, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decide_ncr(uuid, text, text, uuid, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.batch_quality_hold(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.batch_quality_hold(uuid, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.ncr_holds(text, text, timestamp with time zone, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ncr_holds(text, text, timestamp with time zone, numeric) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.assay_is_supplement(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assay_is_supplement(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.next_ncr_code(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.next_ncr_code(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_quality_hold() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_quality_hold() TO service_role;
REVOKE EXECUTE ON FUNCTION public.guard_quality_hold() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_substance_priced_and_penalised() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_substance_priced_and_penalised() TO service_role;
REVOKE EXECUTE ON FUNCTION public.guard_substance_priced_and_penalised() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_ncr_mutation() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_ncr_mutation() TO service_role;
REVOKE EXECUTE ON FUNCTION public.guard_ncr_mutation() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.judge_quality_limits(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.judge_quality_limits(uuid, uuid, text) TO service_role;
REVOKE EXECUTE ON FUNCTION public.judge_quality_limits(uuid, uuid, text) FROM authenticated;

-- ── 12 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes6b1_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes6b1_pending_after ON COMMIT DROP AS
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
    -- ① 授权:恰好多了 action.ncr_decide 的三行,别的一行没动;admin 持目录里每一个码(78);每一个角色仍满足"动作码蕴含查看码"
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes6b1_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM mes6b1_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS DISTINCT FROM 'admin:action.ncr_decide, cco:action.ncr_decide, cto:action.ncr_decide' THEN
        RAISE EXCEPTION 'MES6B1_PROOF|grant change is not exactly the three ncr_decide grants: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM permissions) <> 78
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES6B1_PROOF|admin does not hold every one of the 78 codes';
    END IF;
    IF (SELECT requires_view_any FROM permissions WHERE code = 'action.ncr_decide') IS DISTINCT FROM ARRAY['module.quality.view'] THEN
        RAISE EXCEPTION 'MES6B1_PROOF|action.ncr_decide must declare module.quality.view';
    END IF;
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6B1_PROOF|action-implies-view violated: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES6B1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes6b1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes6b1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES6B1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变(结算口径比对时减掉新列)
    IF EXISTS ((SELECT b.k, b.id FROM mes6b1_pending_before b EXCEPT SELECT a.k, a.id FROM mes6b1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes6b1_pending_after a EXCEPT SELECT b.k, b.id FROM mes6b1_pending_before b)) THEN
        RAISE EXCEPTION 'MES6B1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contracts t) IS DISTINCT FROM (SELECT contracts FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'quality_limit_basis')::text, '|' ORDER BY (to_jsonb(t) - 'quality_limit_basis')::text), '')) FROM contract_settlement_terms t) IS DISTINCT FROM (SELECT contract_settlement_terms FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_pricing_terms t) IS DISTINCT FROM (SELECT contract_pricing_terms FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_penalty_elements t) IS DISTINCT FROM (SELECT contract_penalty_elements FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_refining_charges t) IS DISTINCT FROM (SELECT contract_refining_charges FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_grade_specs t) IS DISTINCT FROM (SELECT contract_grade_specs FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_document_terms t) IS DISTINCT FROM (SELECT contract_document_terms FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM terms_requests t) IS DISTINCT FROM (SELECT terms_requests FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_results t) IS DISTINCT FROM (SELECT assay_results FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_result_metals t) IS DISTINCT FROM (SELECT assay_result_metals FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_result_indicators t) IS DISTINCT FROM (SELECT assay_result_indicators FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t) IS DISTINCT FROM (SELECT inbound_batches FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t) IS DISTINCT FROM (SELECT output_batches FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batch_metals t) IS DISTINCT FROM (SELECT inbound_batch_metals FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batch_metals t) IS DISTINCT FROM (SELECT output_batch_metals FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inventory_movements t) IS DISTINCT FROM (SELECT inventory_movements FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_order_reservations t) IS DISTINCT FROM (SELECT sales_order_reservations FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_orders t) IS DISTINCT FROM (SELECT sales_orders FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_order_lines t) IS DISTINCT FROM (SELECT sales_order_lines FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_settlements t) IS DISTINCT FROM (SELECT sales_settlements FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_disputes t) IS DISTINCT FROM (SELECT assay_disputes FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM samples t) IS DISTINCT FROM (SELECT samples FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM blending_plans t) IS DISTINCT FROM (SELECT blending_plans FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM blending_plan_lines t) IS DISTINCT FROM (SELECT blending_plan_lines FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM warehouse_requests t) IS DISTINCT FROM (SELECT warehouse_requests FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM receipt_price_requests t) IS DISTINCT FROM (SELECT receipt_price_requests FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM price_history t) IS DISTINCT FROM (SELECT price_history FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM invoice_requests t) IS DISTINCT FROM (SELECT invoice_requests FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t) IS DISTINCT FROM (SELECT journal_entries FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t) IS DISTINCT FROM (SELECT journal_lines FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t) IS DISTINCT FROM (SELECT expenses FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t) IS DISTINCT FROM (SELECT payments FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_allocations t) IS DISTINCT FROM (SELECT payment_allocations FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_requests t) IS DISTINCT FROM (SELECT payment_requests FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM substances t) IS DISTINCT FROM (SELECT substances FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_indicators t) IS DISTINCT FROM (SELECT assay_indicators FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM materials t) IS DISTINCT FROM (SELECT materials FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t) IS DISTINCT FROM (SELECT suppliers FROM mes6b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM customers t) IS DISTINCT FROM (SELECT customers FROM mes6b1_rows_before) THEN
        RAISE EXCEPTION 'MES6B1_PROOF|a pre-existing contract, term, assay, batch, content, movement, reservation, order, settlement, dispute, sample, plan, request, price, journal, expense, payment, substance, indicator, material, supplier or customer changed';
    END IF;
    IF EXISTS (SELECT 1 FROM contract_settlement_terms WHERE quality_limit_basis IS NOT NULL) THEN
        RAISE EXCEPTION 'MES6B1_PROOF|quality_limit_basis must start empty (V17 not set) on every existing row';
    END IF;

    -- ④ 三张新表零行(本刀不在线上建任何验收限、判定或报告)
    IF EXISTS (SELECT 1 FROM contract_quality_limits) OR EXISTS (SELECT 1 FROM quality_limit_judgements)
       OR EXISTS (SELECT 1 FROM nonconformance_reports) THEN
        RAISE EXCEPTION 'MES6B1_PROOF|a new table has rows';
    END IF;

    -- ⑤ 变更记录只多了本刀种的那几行:permissions 1 插 1 改 · role_permissions 3 插 · document_types 1 插
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes6b1_log_before), 0)
       AND NOT ((c.op = 'INSERT' AND c.table_name IN ('permissions', 'role_permissions', 'document_types'))
                OR (c.op = 'UPDATE' AND c.table_name = 'permissions'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6B1_PROOF|unexpected change_log rows: %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes6b1_log_before), 0);
    IF v_n <> 6 THEN RAISE EXCEPTION 'MES6B1_PROOF|change_log moved by % (expected 1 + 1 + 3 + 1 = 6)', v_n; END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6B1_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑥ 结构:守卫都在;单据登记 58 行带 NCR、豁免 45 行;提醒 65 支、待定值 23 行;295 张表;审计主语 ncr 在册
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_contract_penalty_elements_substance_role' AND tgrelid = 'public.contract_penalty_elements'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_contract_penalty_elements_unpriced' AND tgrelid = 'public.contract_penalty_elements'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_contract_pricing_terms_unpenalised' AND tgrelid = 'public.contract_pricing_terms'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_inventory_movements_quality_hold' AND tgrelid = 'public.inventory_movements'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_nonconformance_reports_mutation' AND tgrelid = 'public.nonconformance_reports'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_nonconformance_reports_truncate' AND tgrelid = 'public.nonconformance_reports'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_quality_limit_judgements_append_only' AND tgrelid = 'public.quality_limit_judgements'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_contract_quality_limits_frozen' AND tgrelid = 'public.contract_quality_limits'::regclass) THEN
        RAISE EXCEPTION 'MES6B1_PROOF|a guard trigger is missing';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 58 OR document_type_prefix('ncr') <> 'NCR'
       OR (SELECT count(*) FROM document_type_exceptions) <> 45 THEN
        RAISE EXCEPTION 'MES6B1_PROOF|document_types should be 58 with NCR and exceptions stay 45';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 65
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 23 THEN
        RAISE EXCEPTION 'MES6B1_PROOF|operations_now should have 65 arms and pending_values 23';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 295 THEN
        RAISE EXCEPTION 'MES6B1_PROOF|expected 295 public tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'ncr') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|trail subject ncr is not registered';
    END IF;
    IF arm_permission_any('quality_hold_reserved') IS DISTINCT FROM ARRAY['module.output.view']
       OR arm_permission_widen('quality_hold_reserved') IS DISTINCT FROM ARRAY['module.sales.view'] THEN
        RAISE EXCEPTION 'MES6B1_PROOF|quality_hold_reserved must narrow to output view and widen to sales view';
    END IF;

    -- ⑦ 函数面:六支员工调得到;五支内层与触发器调不到;anon 能执行的【恰好】两支;新表与新视图 anon 读不到
    IF NOT has_function_privilege('authenticated', 'public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.decide_ncr(uuid, text, text, uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.decide_ncr(uuid, text, text, uuid, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|public.decide_ncr(uuid, text, text, uuid, uuid) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.batch_quality_hold(uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.batch_quality_hold(uuid, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|public.batch_quality_hold(uuid, uuid) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.ncr_holds(text, text, timestamp with time zone, numeric)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.ncr_holds(text, text, timestamp with time zone, numeric)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|public.ncr_holds(text, text, timestamp with time zone, numeric) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.assay_is_supplement(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.assay_is_supplement(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|public.assay_is_supplement(uuid) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.next_ncr_code(date)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.next_ncr_code(date)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|public.next_ncr_code(date) must be callable by staff and not by anon';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_quality_hold()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_quality_hold()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|public.guard_quality_hold() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_substance_priced_and_penalised()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_substance_priced_and_penalised()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|public.guard_substance_priced_and_penalised() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_ncr_mutation()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_ncr_mutation()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|public.guard_ncr_mutation() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid) must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.judge_quality_limits(uuid, uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.judge_quality_limits(uuid, uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|public.judge_quality_limits(uuid, uuid, text) must be a function nobody outside can call';
    END IF;
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES6B1_PROOF|anon executes: %', v_bad;
    END IF;
    IF has_table_privilege('anon', 'public.nonconformance_reports'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.contract_quality_limits'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.quality_limit_judgements'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.ncr_rows'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|anon can read a new relation';
    END IF;

    -- ⑧ 那 44 条开着的读策略还是 44 条;报告与判定表上没有写策略(只经函数)
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES6B1_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('nonconformance_reports', 'quality_limit_judgements')
                 AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|a write policy exists on nonconformance_reports or quality_limit_judgements';
    END IF;

    -- ⑨ 变更记录:覆盖零缺口(三张新表记,豁免仍是 8);遮蔽零缺口(规则仍是 114 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES6B1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES6B1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes6b1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES6B1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes6b1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES6B1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes6b1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
