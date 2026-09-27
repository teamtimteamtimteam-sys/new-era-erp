-- db/migrations/2026-09-27-terms-edit1-contract-terms-editor.sql
-- TERMS-EDIT-1 —— 合同条款编辑器(/contracts/[id])的数据库那一半:卖方合同先填齐条款才申请得了生效;结束了的合同条款冻结。
-- 由 db/scripts/build_terms_edit1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(TERMS-EDIT-1 grilling Q3 · Q4,Tim 2026-09-27)
--   ① 新:contract_activation_missing(uuid) → text[] —— 卖方合同申请生效前还缺哪几条(结算口径一行 · 至少一条计价 ·
--      per_metal 时每个计价金属一行精炼费 · per_element 时至少一条惩罚);买方合同什么都不要求。SECURITY INVOKER ——
--      详情页以调用者身份读它画清单;提交那一支以属主身份读它。
--   ② 替换:terms_request_submit_internal —— 合同那一支在期限检查之后加一条 CONTRACT_TERMS_INCOMPLETE|编号|缺的那几条。
--   ③ 替换:contract_terms_lock_reason —— 除了 'request:<label>' 与 'active',还回 'expired' / 'terminated',
--      于是七张条款表在结束了的合同上按名拒 CONTRACT_TERMS_FROZEN|编号|expired / terminated。
--      表头那一支(guard_contract_write)只读 'request:',表头的规矩不变。
--
-- 【不做什么】不加新码(所以"新码同一迁移里授给 admin"这条常设裁定这里没有东西可授);不碰审批开关、名册、策略;
-- 不碰 user_roles / role_permissions;不写任何业务行;不改 APR-8 的任何一条规矩(新增的是提交时的一条拒绝,Tim 裁定)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;
-- 留痕、分录、合同、七张条款表、条款申请一行没变;三支函数的形状对(INVOKER / DEFINER);提交那一支读清单;
-- 每一张在途单据都还有一个【不是它自己当事人】的决定人,条款申请链二级有人批。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'TE1_PRE|approvals are expected ON';
    END IF;
    IF to_regprocedure('public.contract_activation_missing(uuid)') IS NOT NULL THEN
        RAISE EXCEPTION 'TE1_PRE|contract_activation_missing already exists';
    END IF;
    IF position('CONTRACT_TERMS_INCOMPLETE' IN (SELECT prosrc FROM pg_proc WHERE oid = 'public.terms_request_submit_internal(text, uuid, jsonb, text)'::regprocedure)) > 0 THEN
        RAISE EXCEPTION 'TE1_PRE|terms_request_submit_internal already refuses incomplete contracts';
    END IF;
    -- Step 0 的读数(postgres,基表,2026-09-27 17:26):没有一张在等的条款申请
    IF EXISTS (SELECT 1 FROM terms_requests WHERE status = 'submitted') THEN
        RAISE EXCEPTION 'TE1_PRE|a terms request is waiting';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE te1_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE te1_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || updated_at::text, ',' ORDER BY code), ''))
          FROM contracts) AS contracts,
       (SELECT count(*) FROM contract_grade_specs) AS grade_specs,
       (SELECT count(*) FROM contract_insurance_obligations) AS insurance,
       (SELECT count(*) FROM contract_volume_commitments) AS volume,
       (SELECT count(*) FROM contract_pricing_terms) AS pricing,
       (SELECT count(*) FROM contract_settlement_terms) AS settlement,
       (SELECT count(*) FROM contract_refining_charges) AS refining,
       (SELECT count(*) FROM contract_penalty_elements) AS penalty,
       (SELECT md5(COALESCE(string_agg(label || ':' || status, ',' ORDER BY label), '')) FROM terms_requests) AS terms_requests,
       (SELECT locked_before FROM finance_settings) AS locked_before;
CREATE TEMP TABLE te1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 新:卖方合同申请生效前还缺什么(镜像原样)────────────────────────────

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
      ) m
     WHERE c.id = p_contract_id AND c.side = 'sell'
$function$;

-- ── 2 · 替换:提交那一支读清单(镜像原样)──────────────────────────────────

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
--   2. 理由必填(TERMS_REQUEST_REASON_REQUIRED|种类|编号)。
--   3. 同一个主体上已有一张在等 → TERMS_REQUEST_OPEN|编号|那一张(grilling Q5;唯一索引是第二道)。
--   4. ★ 审批开着时:提单人这个【人】之外,二级还有没有人批得动 → TERMS_REQUEST_NO_OTHER_DECIDER|label
--      (assert_other_decider,按人认)。线上 admin@ 与 tim@ 是同一个人,而二级只有 tim@ —— admin@ 提的一律按名拒。
--   5. 落一行 submitted:snapshot 与 fingerprint 冻结;按批准那一刻的同一支试跑(terms_request_dry_run)。
--   6. 审批开着:留痕 submitted,二级。关着:当场生效,状态 approved,留痕 auto_approved。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql;
--       replaced by db/migrations/2026-09-27-terms-edit1-contract-terms-editor.sql (CONTRACT_TERMS_INCOMPLETE).

CREATE OR REPLACE FUNCTION public.terms_request_submit_internal(p_kind text, p_subject uuid, p_proposed jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
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
        IF cardinality(contract_activation_missing(p_subject)) > 0 THEN
            RAISE EXCEPTION 'CONTRACT_TERMS_INCOMPLETE|%|%', v_code,
                array_to_string(contract_activation_missing(p_subject), ',');
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

-- ── 3 · 替换:结束了的合同条款冻结(镜像原样)────────────────────────────────

-- db/functions/contract_terms_lock_reason.sql
-- APR-8(2026-09-26,grilling Q2 · Q5):一份合同此刻为什么不许直连改 —— 两支守卫(合同表头、七张条款表)的一份判据。
--   'request:<label>'  有一张在等的生效申请(TERMS_REQUEST_FREEZES_CONTRACT / CONTRACT_TERMS_FROZEN)
--   'active'           合同在生效中:条款冻结;表头只许把状态改成暂停 / 到期 / 终止
--   'expired' / 'terminated'  ★ TERMS-EDIT-1(Tim 2026-09-27,grilling Q4):已经结束的合同,七张条款表也冻结 ——
--                      一份到期或终止了的协议,它当时约定的是什么是一件已经发生的事,改它就是改历史。
--                      (表头那一支 guard_contract_write 只读 'request:',所以这两个值不改变表头的规矩。)
--   NULL               草稿、暂停,或不存在:照改
-- SECURITY DEFINER:守卫以调用者身份跑,而调用者未必读得到申请表(它只给 CFO 那一组码)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql;
--       replaced by db/migrations/2026-09-27-terms-edit1-contract-terms-editor.sql (expired / terminated).

CREATE OR REPLACE FUNCTION public.contract_terms_lock_reason(p_contract_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(
        (SELECT 'request:' || r.label FROM terms_requests r
          WHERE r.contract_id = p_contract_id AND r.status = 'submitted' LIMIT 1),
        (SELECT c.status FROM contracts c
          WHERE c.id = p_contract_id AND c.status IN ('active', 'expired', 'terminated')))
$function$;

-- ── 4 · 自证 ─────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.te1_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE te1_pending_after ON COMMIT DROP AS
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
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一行没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM te1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM te1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'TE1_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'TE1_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、合同、七张条款表、条款申请一行没变
    IF EXISTS ((SELECT b.k, b.id FROM te1_pending_before b EXCEPT SELECT a.k, a.id FROM te1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM te1_pending_after a EXCEPT SELECT b.k, b.id FROM te1_pending_before b)) THEN
        RAISE EXCEPTION 'TE1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM te1_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || updated_at::text, ',' ORDER BY code), ''))
          FROM contracts) AS contracts,
       (SELECT count(*) FROM contract_grade_specs) AS grade_specs,
       (SELECT count(*) FROM contract_insurance_obligations) AS insurance,
       (SELECT count(*) FROM contract_volume_commitments) AS volume,
       (SELECT count(*) FROM contract_pricing_terms) AS pricing,
       (SELECT count(*) FROM contract_settlement_terms) AS settlement,
       (SELECT count(*) FROM contract_refining_charges) AS refining,
       (SELECT count(*) FROM contract_penalty_elements) AS penalty,
       (SELECT md5(COALESCE(string_agg(label || ':' || status, ',' ORDER BY label), '')) FROM terms_requests) AS terms_requests,
       (SELECT locked_before FROM finance_settings) AS locked_before) n) THEN
        RAISE EXCEPTION 'TE1_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM te1_counts_before c), (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || updated_at::text, ',' ORDER BY code), ''))
          FROM contracts) AS contracts,
       (SELECT count(*) FROM contract_grade_specs) AS grade_specs,
       (SELECT count(*) FROM contract_insurance_obligations) AS insurance,
       (SELECT count(*) FROM contract_volume_commitments) AS volume,
       (SELECT count(*) FROM contract_pricing_terms) AS pricing,
       (SELECT count(*) FROM contract_settlement_terms) AS settlement,
       (SELECT count(*) FROM contract_refining_charges) AS refining,
       (SELECT count(*) FROM contract_penalty_elements) AS penalty,
       (SELECT md5(COALESCE(string_agg(label || ':' || status, ',' ORDER BY label), '')) FROM terms_requests) AS terms_requests,
       (SELECT locked_before FROM finance_settings) AS locked_before) n);
    END IF;

    -- ④ 形状:清单是 INVOKER、authenticated 调得到;锁仍是 DEFINER;提交那一支仍然调不到、并且读清单
    IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.contract_activation_missing(uuid)'::regprocedure) THEN
        RAISE EXCEPTION 'TE1_PROOF|contract_activation_missing must be SECURITY INVOKER';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.contract_activation_missing(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'TE1_PROOF|authenticated cannot execute contract_activation_missing';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.contract_terms_lock_reason(uuid)'::regprocedure) THEN
        RAISE EXCEPTION 'TE1_PROOF|contract_terms_lock_reason must stay SECURITY DEFINER';
    END IF;
    IF has_function_privilege('authenticated', 'public.terms_request_submit_internal(text, uuid, jsonb, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'TE1_PROOF|authenticated can execute terms_request_submit_internal';
    END IF;
    IF position('contract_activation_missing(' IN (SELECT prosrc FROM pg_proc
                 WHERE oid = 'public.terms_request_submit_internal(text, uuid, jsonb, text)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'TE1_PROOF|terms_request_submit_internal does not read the checklist';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ('trg_contracts_guard_write',
        'trg_contract_grade_specs_frozen', 'trg_contract_insurance_obligations_frozen', 'trg_contract_volume_commitments_frozen',
        'trg_contract_pricing_terms_frozen', 'trg_contract_settlement_terms_frozen', 'trg_contract_refining_charges_frozen',
        'trg_contract_penalty_elements_frozen');
    IF v_n <> 8 THEN RAISE EXCEPTION 'TE1_PROOF|expected the 8 APR-8 contract guards, got %', v_n; END IF;

    -- ⑤ 条款申请链此刻有人批得了
    SELECT count(*) INTO v_n FROM approval_deciders('terms_request', 'decide_terms_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'TE1_PROOF|nobody can decide a terms request'; END IF;
    RAISE NOTICE 'TE1 deciders for terms_request: %', v_n;

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.te1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'TE1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.te1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'TE1_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.te1_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.te1_pending_decider_check(boolean);

COMMIT;
