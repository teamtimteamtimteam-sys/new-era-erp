-- db/migrations/2026-10-08-mes5b1-balance-and-yield.sql
-- MES-5b-1 —— 物料平衡与得率、"动作码蕴含查看码"的检查、引导的 admin(MES 组第九刀,v1.4.45;发布那一行在 docs/handbacks/MES-5b-1.md 的抬头)。
-- 由 db/scripts/build_mes5b1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-08:MES-5b Step 0 的平衡 / 得率 / f 检查那一部分 —— Q1 · Q3–Q14 · Q30 · Q32–Q37 —— 照建议裁定,
--   Q15 加 V37,Q31 修引导;docs/surveys/MES-5b/STEP0-HANDBACK.md)
--   ① 一炉在质量账上算哪一类(processing_run_flow_all):消耗 / 穿过去(深度放电)/ 搬运(拆去隔离)/ 回滚;单位不全是 kg 的单不合计(Q3 · Q10)。
--   ② 月度物料平衡(processing_balance_monthly_all + 外壳)与库存的月度滚动(stock_rollforward_monthly_all + 外壳)(Q8 · Q9)。
--   ③ 一个批次往下走的质量树,按投入质量成比例、精确的份额(batch_balance_tree_all + 外壳)(Q4 · Q5 · Q6 · Q7)。
--   ④ 质量得率:每一炉(processing_run_yield_all + 外壳)、按工序 × 月 × 分组(processing_run_origin_share_all · processing_yield_summary_all + 外壳)(Q13 · Q14)。
--   ⑤ V37:operation_type_output_forms.expected_yield_pct(空)+ pending_values 一支(Q15 · Q33)。
--   ⑥ 拆去隔离那一炉自己结平(split_failed_modules_to_quarantine,同签名)+ 这道工序的容差播成 0(Q11)。
--   ⑦ f 检查:permissions.requires_view_any(声明块 + 目录自检)+ set_role_permissions 按名拒 ACTION_REQUIRES_VIEW(Q30)。
--      引导的 admin 与财务(Q31)只在镜像里改 —— 那是全新安装的起点,线上的角色本刀【一个都不动】。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改任何一张既有单据、加工单、批次、
--   流水或分录;不回填任何东西;V37 保持空;require_calibrated_since 保持空。线上只多出:两列新列(一列空、一列是 33 个动作码的声明)、
--   拆分工序的容差 0、十二张视图、换掉的两支函数与一张视图。
--
-- 【破窗】见 docs/surveys/MES-5b/STEP0-HANDBACK.md §11:只加视图;拆分那一炉从此自己结平(旧应用不受影响);旧应用存一个违反新规矩的角色
--   会被按名拒(ACTION_REQUIRES_VIEW,旧应用画成一句兜底话)—— 线上七个角色今天全部满足(文末断言)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多;七个账号一个都没被停;
--   既有的加工单、投料与产出腿、损耗、结平、批次、流水、分录、费用单、设备与安全状态逐字未变;变更记录只在 permissions(33 行声明)
--   与 operation_types(1 行容差)上动了;线上每一个角色都满足"动作码蕴含查看码";V37 没有一个值;anon 能执行的【恰好】两支;
--   基视图谁都读不到;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免仍是 8、规则 111 条);提醒臂 59 支不变;
--   待补的值 20 支(V37 今天零行 —— 线上没有一张 MES-4a 之后的单);每一张在途单据仍有一个不是它当事人的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES5B1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.processing_run_flow_all') IS NOT NULL OR to_regclass('public.batch_balance_tree_all') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B1_PRE|MES-5b-1 views already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'permissions' AND column_name = 'requires_view_any')
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'operation_type_output_forms' AND column_name = 'expected_yield_pct') THEN
        RAISE EXCEPTION 'MES5B1_PRE|a MES-5b-1 column already exists';
    END IF;
    IF (SELECT balance_tolerance_pct FROM operation_types WHERE code = 'discharge_quarantine_split') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B1_PRE|the split operation''s tolerance is expected empty';
    END IF;
    IF (SELECT count(*) FROM permissions WHERE category = 'action') <> 34 THEN
        RAISE EXCEPTION 'MES5B1_PRE|expected 34 action codes, got %', (SELECT count(*) FROM permissions WHERE category = 'action');
    END IF;
    IF (SELECT count(*) FROM auth.users) <> 7 THEN
        RAISE EXCEPTION 'MES5B1_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5B1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 111 THEN
        RAISE EXCEPTION 'MES5B1_PRE|expected 111 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59 THEN
        RAISE EXCEPTION 'MES5B1_PRE|operations_now should have 59 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 19 THEN
        RAISE EXCEPTION 'MES5B1_PRE|pending_values should have 19 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B1_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes5b1_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes5b1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes5b1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes5b1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes5b1_ops_before ON COMMIT DROP AS
SELECT md5(string_agg((to_jsonb(o) - 'balance_tolerance_pct')::text || '|' || CASE WHEN o.code = 'discharge_quarantine_split' THEN '' ELSE COALESCE(o.balance_tolerance_pct::text, '') END, '|' ORDER BY o.code)) AS d
  FROM operation_types o;
CREATE TEMP TABLE mes5b1_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_runs t) AS processing_runs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_inputs t) AS processing_inputs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_outputs t) AS processing_outputs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_run_losses t) AS processing_run_losses,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_run_closures t) AS processing_run_closures,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM inbound_batches t) AS inbound_batches,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM output_batches t) AS output_batches,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM inventory_movements t) AS inventory_movements,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM journal_entries t) AS journal_entries,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM journal_lines t) AS journal_lines,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM expenses t) AS expenses,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM payments t) AS payments,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM devices t) AS devices,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM inbound_batch_safety_states t) AS inbound_batch_safety_states,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM output_batch_safety_states t) AS output_batch_safety_states,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_cost_entries t) AS processing_cost_entries,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM discharge_module_splits t) AS discharge_module_splits,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM operation_type_output_forms t) AS operation_type_output_forms;

-- ── 1 · 目录:每一个动作码声明"用它的那一页要哪几个查看码之一"(Q30)——列、注释、声明块、目录自检,与 db/tables/permissions.sql 逐字同一份 ──
ALTER TABLE public.permissions ADD COLUMN requires_view_any text[];
COMMENT ON COLUMN public.permissions.requires_view_any IS
    'MES-5b-1(MES-5a-2 close-out 裁定 f · MES-5b Step 0 Q30):一个动作码的持有人必须【至少】持其中一个码,才进得去用这个动作的页面。只有动作码声明;页面由这个码自己把门的写它自己;空 = 没有页面用它(action.anonymise_employee)。set_role_permissions 按名拒 ACTION_REQUIRES_VIEW|<码>|<查看码,…>。';

UPDATE public.permissions p SET requires_view_any = d.views
  FROM (VALUES
    ('action.apply_assay',              ARRAY['module.inbound.view','module.output.view']),
    ('action.approve_review',           ARRAY['module.hr.view']),
    ('action.batch_write_off',          ARRAY['module.inbound.view','module.inventory.view','module.output.view']),
    ('action.bulk_import',              ARRAY['action.bulk_import']),
    ('action.confirm_capture',          ARRAY['module.inbound.view','module.logistics.view','module.processing.view']),
    ('action.contract_terms',           ARRAY['module.suppliers.view']),
    ('action.customer_credit',          ARRAY['module.customers.view']),
    ('action.decide_hr_requests',       ARRAY['module.hr.view']),
    ('action.direct_sale',              ARRAY['module.output.view']),
    ('action.finance_reopen',           ARRAY['module.finance.view']),
    ('action.finance_settings',         ARRAY['module.finance.view']),
    ('action.hr_reviews',               ARRAY['module.hr.view']),
    ('action.issue_cod',                ARRAY['module.inbound.view','module.inventory.view']),
    ('action.manage_devices',           ARRAY['module.processing.view']),
    ('action.manage_permissions',       ARRAY['action.manage_permissions']),
    ('action.metal_prices',             ARRAY['action.metal_prices']),
    ('action.overtime_approve',         ARRAY['action.overtime_approve']),
    ('action.overtime_enter',           ARRAY['action.overtime_enter']),
    ('action.price_receipts',           ARRAY['module.inbound.view']),
    ('action.processing_aftercare',     ARRAY['module.processing.view']),
    ('action.processing_commit',        ARRAY['module.inbound.view','module.output.view','module.processing.view']),
    ('action.processing_rollback',      ARRAY['module.inventory.view','module.processing.view']),
    ('action.raise_po_consumables',     ARRAY['module.purchasing.view']),
    ('action.raise_po_equipment',       ARRAY['module.purchasing.view']),
    ('action.raise_po_office',          ARRAY['module.purchasing.view']),
    ('action.receive_goods',            ARRAY['module.inbound.view','module.logistics.view','module.processing.view','module.purchasing.view']),
    ('action.request_shipping_release', ARRAY['module.sales.view']),
    ('action.ship_goods',               ARRAY['action.ship_goods']),
    ('action.stocktake_count',          ARRAY['module.inbound.view','module.output.view','module.stocktakes.view']),
    ('action.stocktake_post',           ARRAY['module.stocktakes.view']),
    ('action.supplier_approve',         ARRAY['module.suppliers.view']),
    ('action.wo_create',                ARRAY['module.processing.view']),
    ('action.wo_release',               ARRAY['module.processing.view'])
  ) AS d(code, views)
 WHERE p.code = d.code;

DO $requires_view_check$
DECLARE v_bad text;
BEGIN
    SELECT string_agg(p.code || ' -> ' || v, ', ' ORDER BY p.code, v) INTO v_bad
      FROM permissions p CROSS JOIN LATERAL unnest(p.requires_view_any) v
     WHERE p.category <> 'action'
        OR NOT EXISTS (SELECT 1 FROM permissions q WHERE q.code = v)
        OR NOT (v = p.code OR (v LIKE 'module.%.view' AND v <> 'module.tasks.view_all'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'PERMISSIONS_REQUIRES_VIEW_INVALID|%', v_bad;
    END IF;
    SELECT string_agg(code, ', ' ORDER BY code) INTO v_bad FROM permissions
     WHERE category = 'action' AND (requires_view_any IS NULL OR cardinality(requires_view_any) = 0)
       AND code <> 'action.anonymise_employee';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'PERMISSIONS_REQUIRES_VIEW_UNDECLARED|%', v_bad;
    END IF;
END;
$requires_view_check$;

-- ── 2 · V37:每道工序 × 每种产出形态的预期质量得率(Q15)—— 空(Not yet set);只标不拒 ──────────────────────────────
ALTER TABLE public.operation_type_output_forms ADD COLUMN expected_yield_pct  numeric CHECK (expected_yield_pct IS NULL OR (expected_yield_pct >= 0 AND expected_yield_pct <= 100));
COMMENT ON COLUMN public.operation_type_output_forms.expected_yield_pct IS
    'MES-5b-1(V37;MES-5b Step 0 Q15):这道工序 × 这一种产出形态的预期质量得率(占总投入的 %,0–100)。为空 = Not yet set(Tim 与工艺工程师在试车之后给)。只标不拒:得率页把低于它的一炉、一道工序的一个月标出来。改它要 module.processing.edit(工序页,与容差同一个码)。';

-- ── 3 · 拆去隔离那一道工序的平衡容差 = 0(Q11):这道工序原样搬运质量,任何不为 0 的余数按定义就是错的 ──────────────────
UPDATE public.operation_types SET balance_tolerance_pct = 0 WHERE code = 'discharge_quarantine_split';

-- ── 4 · 换掉的两支函数(镜像原样,同签名):角色保存多一道 ACTION_REQUIRES_VIEW · 拆分那一炉自己结平 ──────────────

-- db/functions/set_role_permissions.sql
-- 整体替换一个角色的授权。要 action.manage_permissions。
--
-- 【edit 蕴含 view 的强制在这里,不只在界面】。2b 的 fixture 量过:只授 edit 不授 view 时
-- PostgREST 的 INSERT ... RETURNING 会 42501,整条写入路径断掉 —— 那是坏配置,不是审美问题。
-- 界面挡不住 RPC 直调,所以守卫必须在数据库里。
-- 【动作码蕴含查看码同理】(MES-5b-1):ACTION_REQUIRES_VIEW|<动作码>|<查看码,…> —— 持动作码就要持用它那一页的查看码之一。
--
-- NOTE: introduced by db/migrations/2026-08-02-perm3-banking-and-directory.sql;
--       diff-aware since db/migrations/2026-09-28-history1-change-log.sql (HISTORY-1, Tim's Q16).
--       action-implies-view since db/migrations/2026-10-08-mes5b1-balance-and-yield.sql (MES-5b-1, ruling f · Q30).

CREATE OR REPLACE FUNCTION public.set_role_permissions(p_role_id uuid, p_permission_codes text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_codes   text[] := COALESCE(p_permission_codes, ARRAY[]::text[]);
    v_role    record;
    v_missing text;
    v_bad     text;
    v_action  text;
    v_views   text;
    v_added   integer;
    v_removed integer;
BEGIN
    PERFORM require_permission('action.manage_permissions');

    SELECT id, code, is_system INTO v_role
    FROM roles WHERE id = p_role_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ROLE_NOT_FOUND';
    END IF;

    -- 未知权限码直接拒绝(目录是迁移级的,界面不该能凭空造码)
    SELECT c INTO v_bad
    FROM unnest(v_codes) c
    WHERE NOT EXISTS (SELECT 1 FROM permissions p WHERE p.code = c)
    LIMIT 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'PERMISSION_NOT_FOUND|%', v_bad;
    END IF;

    -- 【核心守卫】每一个 module.<m>.edit 都必须有对应的 module.<m>.view 同行
    SELECT split_part(c, '.', 2) INTO v_missing
    FROM unnest(v_codes) c
    WHERE c LIKE 'module.%.edit'
      AND NOT ('module.' || split_part(c, '.', 2) || '.view') = ANY (v_codes)
    LIMIT 1;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'EDIT_REQUIRES_VIEW|%', v_missing;
    END IF;

    -- ★ MES-5b-1(MES-5a-2 close-out 裁定 f · Step 0 Q30,Tim):一个动作码只与【用它的那一页】的查看码一起授 ——
    --   permissions.requires_view_any 列的是那几个码,持其中【任一】就够(页面由这个码自己把门的,列它自己)。
    --   只持动作码的角色进不了那一页,给出去的是一个用不了的角色(close-out §2 f 量过三次)。按名拒,点出码与它要的查看码。
    SELECT p.code, array_to_string(p.requires_view_any, ',') INTO v_action, v_views
    FROM unnest(v_codes) c
    JOIN permissions p ON p.code = c
    WHERE p.requires_view_any IS NOT NULL
      AND NOT (p.requires_view_any && v_codes)
    ORDER BY p.code
    LIMIT 1;
    IF v_action IS NOT NULL THEN
        RAISE EXCEPTION 'ACTION_REQUIRES_VIEW|%|%', v_action, v_views;
    END IF;

    -- 系统角色不可被摘掉管理权限 —— 否则一次保存就能把权限系统本身锁死
    IF v_role.is_system AND NOT ('action.manage_permissions' = ANY (v_codes)) THEN
        RAISE EXCEPTION 'SYSTEM_ROLE_PROTECTED';
    END IF;

    -- ★ HISTORY-1(Tim 的 Q16):只动【有差别】的码。此前整批删掉再整批插回,于是每一次保存
    --   都把一个角色的每一行重写一遍,旧的码单从库里读不回来,而通用变更记录会把一次保存
    --   记成 N 删 + N 插,埋掉真正变了的那一个。现在:删掉不再要的,插进新要的,留着的一行不碰
    --   (它的 created_at / created_by 仍是当初授它的那一次 —— 比每次重写更真)。
    --   入参里重复的码被 DISTINCT + ON CONFLICT 吸收(此前会撞主键)。
    DELETE FROM role_permissions
     WHERE role_id = p_role_id AND permission_code <> ALL (v_codes);
    GET DIAGNOSTICS v_removed = ROW_COUNT;
    INSERT INTO role_permissions (role_id, permission_code, created_by)
    SELECT DISTINCT p_role_id, c, auth.uid() FROM unnest(v_codes) c
    ON CONFLICT (role_id, permission_code) DO NOTHING;
    GET DIAGNOSTICS v_added = ROW_COUNT;

    RETURN jsonb_build_object(
        'role_id', v_role.id,
        'code', v_role.code,
        'permission_count', (SELECT count(DISTINCT c) FROM unnest(v_codes) c),
        'added', v_added,
        'removed', v_removed
    );
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
--     ⑥ MES-5b-1(Step 0 Q11):拆分那一炉自己结平(close_run_balance;余数 0,容差 0)—— 它是一次搬运,没有损耗、没有余数,不该挂成"没结"。
--   码:action.processing_aftercare(Tim 的 Q10);记那一炉本身照旧还要 action.processing_commit(每一炉都要)——线上两码同一批人持。
--   返回 {split_run_id, split_run_code, batch_id, batch_code, modules, parent_verified, parent_code, balance_closure_id}。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.
--       replaced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql (MES-5b-1: the split closes its own balance).

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
    v_closure  bigint;
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

    -- MES-5b-1(Step 0 Q11):拆分那一炉在同一步里结平。称出来的产出 = 原批消耗的那一份(上面同一个 v_qty 记两条腿),余数按构造是 0,
    --   这道工序的容差是 0 —— 所以它在容差里,说明可选,而且不再挂在"平衡没结"的提醒与月末那一行上。经 close_run_balance(一份判据):
    --   它若拒(例如有人给这道工序加了必填字段),整个拆分照样回滚,拒绝按名说出来。
    v_closure := close_run_balance(v_split, NULL);

    RETURN jsonb_build_object('split_run_id', v_split, 'split_run_code', (SELECT pr.code FROM processing_runs pr WHERE pr.id = v_split),
                              'batch_id', v_new, 'batch_code', v_new_code, 'modules', to_jsonb(v_refs), 'parent_verified', v_ok,
                              'parent_code', v_code, 'balance_closure_id', v_closure);
END;
$function$;

-- ── 5 · 十二张新视图(镜像原样,依赖顺序;基视图从 authenticated 收回,外壳带门)──────────────────────────

-- db/views/processing_run_flow_all.sql
-- MES-5b-1(2026-10-08,规格 §4 · §3.5;MES-0 Q59 · Q60;MES-5b Step 0 Q3 · Q6 · Q7 · Q10 · Q13 · Q37,Tim):【一炉在质量账上算哪一类】—— 基视图,不给人读。
--   每一炉一行;平衡、得率、月度平衡与批次的去向树都从这里读"这一炉算不算消耗、算多少公斤",一份分类、一份算术。
--   flow:
--     reversed      已回滚 / 已删(status <> committed 或 deleted_at 不空)—— 不进任何合计,另列(Q7)
--     pass_through  工序的种类不吃料(operation_kinds.consumes_input = false:深度放电)—— 料穿过去,另列成事件,不是消耗(Q3)
--     transfer      拆去隔离那一炉(discharge_module_splits 里有它)—— 一次转给子批的搬运:没有损耗、没有余数,子批接着带走份额(Q3 · Q11)
--     consumption   其余:工序的种类吃料;以及【没有工序】的老单(MES-4a 之前、工序必填之前记下的 13 张 —— PROC-SUPPORT-1 之前的单全是转化型,
--                   operation_kinds 的 transforming 那一行的注释写着"今天线上 13 张加工单全部是这一类(虽然它们还没有工序类型)")
--   not_kg:这一炉有任何一条投料腿或产出腿的批次单位不是 kg —— 整炉不进任何合计、另列成"单位不是 kg —— 不合计"(Q10);
--     一炉里混着两种单位时它的投入、余数与得率都没有定义,所以按炉排除,不按腿。
--   era_mes4a:有开始时刻 = MES-4a 之后记下的单。之前的单照样进质量合计(Q6),它的余数读作"记在有名字的损耗之前的损耗"。
--   公斤数全部取自 processing_run_balance_all(投入 = 表头 total_input、产出、有名字的损耗、余数)—— 一份算术,这里一个字都不重算;
--     放电那一炉没有产出腿,穿过去的质量 = 它的投入(表头)。
--   remainder_state:closed_within(最新一次结平当前、在给了的容差里,或余数正好是 0)· closed_explained(当前、带说明 —— 容差外或容差没给)·
--     open · before_closure(MES-4a 之前)· not_applicable(放电)· reversed。
--   processing_run_energy 不读这里也不被这里读(Q37:它的读者只画一炉,印着那一炉自己的状态;一切按炉求和的地方都在这里先滤掉回滚的)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_run_flow_all WITH (security_invoker = off) AS
 SELECT r.id AS run_id,
    r.code AS run_code,
    r.process_date,
    (date_trunc('month'::text, r.process_date::timestamp without time zone))::date AS month,
    r.status,
    r.deleted_at,
    r.operation_type_code,
    r.equipment_id,
    r.corrects_run_id,
    r.started_at IS NOT NULL AS era_mes4a,
        CASE
            WHEN r.status <> 'committed'::text OR r.deleted_at IS NOT NULL THEN 'reversed'::text
            WHEN k.consumes_input IS FALSE THEN 'pass_through'::text
            WHEN EXISTS ( SELECT 1
               FROM discharge_module_splits s
              WHERE s.split_run_id = r.id) THEN 'transfer'::text
            ELSE 'consumption'::text
        END AS flow,
    (EXISTS ( SELECT 1
           FROM processing_inputs pi
             LEFT JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = pi.output_batch_id
          WHERE pi.run_id = r.id AND COALESCE(ib.unit, ob.unit) IS DISTINCT FROM 'kg'::text)) OR (EXISTS ( SELECT 1
           FROM processing_outputs po
             JOIN output_batches ob ON ob.id = po.output_batch_id
          WHERE po.run_id = r.id AND ob.unit IS DISTINCT FROM 'kg'::text)) AS not_kg,
    b.input_qty,
    b.output_qty,
    b.named_loss_qty,
    b.remainder_qty,
    b.balance_state,
        CASE
            WHEN b.balance_state = 'closed'::text AND (c.within_tolerance IS TRUE OR c.remainder_qty = 0::numeric) THEN 'closed_within'::text
            WHEN b.balance_state = 'closed'::text THEN 'closed_explained'::text
            ELSE b.balance_state
        END AS remainder_state
   FROM processing_runs r
     JOIN processing_run_balance_all b ON b.run_id = r.id
     LEFT JOIN operation_types ot ON ot.code = r.operation_type_code
     LEFT JOIN operation_kinds k ON k.code = ot.kind_code
     LEFT JOIN processing_run_closures c ON c.id = b.last_closure_id;

COMMENT ON VIEW public.processing_run_flow_all IS
    'MES-5b-1:一炉在质量账上算哪一类(flow:consumption / pass_through / transfer / reversed)、单位是不是全是 kg、是不是 MES-4a 之后的单,连同它的投入 · 产出 · 有名字的损耗 · 余数与余数的状态(公斤数取自 processing_run_balance_all,一份算术)。基视图,不给人读。';

REVOKE ALL ON public.processing_run_flow_all FROM authenticated, anon;

-- db/views/processing_balance_monthly_all.sql
-- MES-5b-1(2026-10-08,规格 §4;MES-0 Q48 · Q59;MES-5b Step 0 Q8 · Q9 · Q10 · Q12,Tim):【月度物料平衡】—— 基视图,不给人读。
--   按 process_date 的月,全厂一份(scope = plant,operation_type_code 空)、每道工序一份(scope = operation;没有工序的老单
--   operation_type_code 为空、scope = operation —— "没记工序",不是"全厂")。长表:每一行是一条线。
--   line / line_key / basis:
--     input         —— 消耗那几炉的投入(flow = consumption,单位全是 kg)
--     output        —— 同那几炉的产出腿,line_key = 产出物料的形态(没有形态的物料 '(none)')
--     loss          —— 同那几炉有名字的损耗(每一类更正链的末端),line_key = 损耗类别,basis = measured / derived
--     remainder     —— 同那几炉的余数,line_key = 余数的状态(closed_within / closed_explained / open / before_closure)
--     pass_through  —— 不是消耗:line_key = discharge(深度放电穿过去的质量)/ split(拆去隔离转给子批的质量)
--     reversed      —— 回滚了的单:件数与公斤,另列,不进上面任何一条
--     not_kg        —— 有一条腿单位不是 kg 的单:件数,不合计(qty 为空 —— 混着单位的数加不起来)
--   【恒等式】每一个(月 × 范围 × 工序):input = Σ output + Σ loss + Σ remainder,逐炉成立所以逐月成立(余数就是那三者的差,
--     来自 processing_run_balance_all 那一份算术;产出腿之和 = 表头产出,commit_processing_run 保证)。fixture 257 MONTH 逐月断言它。
--   【实时数,不冻结】(Q9)一张事后补记的、日期落在过去的单会改掉过去那个月的数;冻结是 MES-8b 合规包的事(MES-0 Q82)。
--   读者经 processing_balance_monthly(带门)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_balance_monthly_all WITH (security_invoker = off) AS
 WITH lines AS (
         SELECT f.month,
            f.operation_type_code,
            'input'::text AS line,
            NULL::text AS line_key,
            NULL::text AS basis,
            f.input_qty AS qty,
            f.run_id
           FROM processing_run_flow_all f
          WHERE f.flow = 'consumption'::text AND NOT f.not_kg
        UNION ALL
         SELECT f.month,
            f.operation_type_code,
            'output'::text AS line,
            COALESCE(m.form_code, '(none)'::text) AS line_key,
            NULL::text AS basis,
            po.quantity_produced AS qty,
            f.run_id
           FROM processing_run_flow_all f
             JOIN processing_outputs po ON po.run_id = f.run_id
             JOIN output_batches ob ON ob.id = po.output_batch_id
             JOIN materials m ON m.id = ob.material_id
          WHERE f.flow = 'consumption'::text AND NOT f.not_kg
        UNION ALL
         SELECT f.month,
            f.operation_type_code,
            'loss'::text AS line,
            l.loss_category_code AS line_key,
            l.basis,
            l.quantity AS qty,
            f.run_id
           FROM processing_run_flow_all f
             JOIN processing_run_losses l ON l.run_id = f.run_id
          WHERE f.flow = 'consumption'::text AND NOT f.not_kg AND NOT (EXISTS ( SELECT 1
                   FROM processing_run_losses x
                  WHERE x.corrects_id = l.id))
        UNION ALL
         SELECT f.month,
            f.operation_type_code,
            'remainder'::text AS line,
            f.remainder_state AS line_key,
            NULL::text AS basis,
            f.remainder_qty AS qty,
            f.run_id
           FROM processing_run_flow_all f
          WHERE f.flow = 'consumption'::text AND NOT f.not_kg
        UNION ALL
         SELECT f.month,
            f.operation_type_code,
            'pass_through'::text AS line,
                CASE f.flow
                    WHEN 'pass_through'::text THEN 'discharge'::text
                    ELSE 'split'::text
                END AS line_key,
            NULL::text AS basis,
            f.input_qty AS qty,
            f.run_id
           FROM processing_run_flow_all f
          WHERE f.flow = ANY (ARRAY['pass_through'::text, 'transfer'::text])
        UNION ALL
         SELECT f.month,
            f.operation_type_code,
            'reversed'::text AS line,
            NULL::text AS line_key,
            NULL::text AS basis,
            f.input_qty AS qty,
            f.run_id
           FROM processing_run_flow_all f
          WHERE f.flow = 'reversed'::text
        UNION ALL
         SELECT f.month,
            f.operation_type_code,
            'not_kg'::text AS line,
            NULL::text AS line_key,
            NULL::text AS basis,
            NULL::numeric AS qty,
            f.run_id
           FROM processing_run_flow_all f
          WHERE f.flow = 'consumption'::text AND f.not_kg
        )
 SELECT lines.month,
    'operation'::text AS scope,
    lines.operation_type_code,
    lines.line,
    lines.line_key,
    lines.basis,
    sum(lines.qty) AS qty,
    count(DISTINCT lines.run_id) AS runs
   FROM lines
  GROUP BY lines.month, lines.operation_type_code, lines.line, lines.line_key, lines.basis
UNION ALL
 SELECT lines.month,
    'plant'::text AS scope,
    NULL::text AS operation_type_code,
    lines.line,
    lines.line_key,
    lines.basis,
    sum(lines.qty) AS qty,
    count(DISTINCT lines.run_id) AS runs
   FROM lines
  GROUP BY lines.month, lines.line, lines.line_key, lines.basis;

COMMENT ON VIEW public.processing_balance_monthly_all IS
    'MES-5b-1:月度物料平衡(按 process_date 的月;全厂与每道工序)—— 投入 · 按形态的产出 · 按类别 × 来由的有名字损耗 · 按状态的余数 · 穿过去的质量(放电 / 拆去隔离)· 回滚的单 · 单位不是 kg 的单。实时数,不冻结。基视图,不给人读。';

REVOKE ALL ON public.processing_balance_monthly_all FROM authenticated, anon;

-- db/views/stock_rollforward_monthly_all.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q8,Tim):【库存的月度滚动】—— 基视图,不给人读。从 inventory_movements(库存的唯一真源)按
--   business_date 的月、按单位:期初 · 收货 · 加工产出 · 加工消耗(消耗与回滚还原的净额)· 销售 · 注销 · 盘点调整 · 回滚作废 ·
--   搬动(转移与状态变更,两条腿相抵,净额恒为 0)· 期末。每一个流向都取那一行流水的 qty_delta 原样(出为负、进为正)。
--   【没有"对得上"的旗标 —— 刻意的】期末 = 期初 + 本月各行之和,按构造成立;一个两边动不开的旗标是装饰(AGENTS.md
--   「两边只有在能分开的时候才是一个检查」)。所以这里只给数,不给判断。
--   【没有业务日期的流水】(FIN-32 之前写下的行,business_date 为空 —— 表的注释:不回填,界面读作"未知")不进任何一个月:
--     它们在 month 为空的那一行(每个单位一行),期初 / 期末为空。于是"某个月的期末"只是【有日期的】流水之和 —— 页面照直说。
--   月份从最早一条有日期的流水所在的月,连续到今天(新加坡日历)所在的月;没有流水的月也有一行(期初 = 期末)。
--   一个流水类型若不在下面的清单里,它不进任何一列 —— 期末于是对不上库存,看得见(不设"其他"兜底,AGENTS.md「兜底桶」)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.stock_rollforward_monthly_all WITH (security_invoker = off) AS
 WITH mv AS (
         SELECT (date_trunc('month'::text, m.business_date::timestamp without time zone))::date AS month,
            COALESCE(ib.unit, ob.unit) AS unit,
            m.movement_type,
            m.qty_delta
           FROM inventory_movements m
             LEFT JOIN inbound_batches ib ON ib.id = m.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = m.output_batch_id
        ), months AS (
         SELECT u.unit,
            (g.g)::date AS month
           FROM ( SELECT DISTINCT mv.unit
                   FROM mv) u
             CROSS JOIN LATERAL generate_series((( SELECT min(mv.month) AS min
                   FROM mv
                  WHERE mv.month IS NOT NULL))::timestamp without time zone, (date_trunc('month'::text, (now() AT TIME ZONE 'Asia/Singapore'::text)))::timestamp without time zone, '1 mon'::interval) g(g)
        ), flows AS (
         SELECT mv.month,
            mv.unit,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'receipt'::text), 0::numeric) AS received,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'processing_produce'::text), 0::numeric) AS produced,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = ANY (ARRAY['processing_consume'::text, 'reversal_restore'::text])), 0::numeric) AS consumed,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'sale'::text), 0::numeric) AS sold,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'writeoff'::text), 0::numeric) AS written_off,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'adjustment'::text), 0::numeric) AS adjusted,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'reversal_void'::text), 0::numeric) AS voided,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = ANY (ARRAY['transfer_out'::text, 'transfer_in'::text, 'status_change_out'::text, 'status_change_in'::text])), 0::numeric) AS moved
           FROM mv
          GROUP BY mv.month, mv.unit
        ), dated AS (
         SELECT ms.month,
            ms.unit,
            COALESCE(f.received, 0::numeric) AS received,
            COALESCE(f.produced, 0::numeric) AS produced,
            COALESCE(f.consumed, 0::numeric) AS consumed,
            COALESCE(f.sold, 0::numeric) AS sold,
            COALESCE(f.written_off, 0::numeric) AS written_off,
            COALESCE(f.adjusted, 0::numeric) AS adjusted,
            COALESCE(f.voided, 0::numeric) AS voided,
            COALESCE(f.moved, 0::numeric) AS moved
           FROM months ms
             LEFT JOIN flows f ON f.month = ms.month AND f.unit = ms.unit
        ), step AS (
         SELECT d.month,
            d.unit,
            d.received,
            d.produced,
            d.consumed,
            d.sold,
            d.written_off,
            d.adjusted,
            d.voided,
            d.moved,
            d.received + d.produced + d.consumed + d.sold + d.written_off + d.adjusted + d.voided + d.moved AS net
           FROM dated d
        )
 SELECT s.month,
    s.unit,
    COALESCE(sum(s.net) OVER (PARTITION BY s.unit ORDER BY s.month ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0::numeric) AS opening,
    s.received,
    s.produced,
    s.consumed,
    s.sold,
    s.written_off,
    s.adjusted,
    s.voided,
    s.moved,
    sum(s.net) OVER (PARTITION BY s.unit ORDER BY s.month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS closing
   FROM step s
UNION ALL
 SELECT NULL::date AS month,
    f.unit,
    NULL::numeric AS opening,
    f.received,
    f.produced,
    f.consumed,
    f.sold,
    f.written_off,
    f.adjusted,
    f.voided,
    f.moved,
    NULL::numeric AS closing
   FROM flows f
  WHERE f.month IS NULL;

COMMENT ON VIEW public.stock_rollforward_monthly_all IS
    'MES-5b-1:库存的月度滚动(inventory_movements 按 business_date 的月、按单位):期初 · 收货 · 加工产出 · 加工消耗 · 销售 · 注销 · 调整 · 回滚作废 · 搬动 · 期末。没有"对得上"的旗标(期末按构造 = 期初 + 本月之和)。没有业务日期的流水在 month 为空的那一行。基视图,不给人读。';

REVOKE ALL ON public.stock_rollforward_monthly_all FROM authenticated, anon;

-- db/views/batch_balance_tree_all.sql
-- MES-5b-1(2026-10-08,规格 §4.2;MES-0 Q59;MES-5b Step 0 Q3–Q7 · Q10 · Q11,Tim):【一个批次的质量去了哪里 —— 往下走的树】—— 基视图,不给人读。
--   每一个批次(进料与产出)是一棵树的根(root_kind / root_id)。树上的结点(node_type):
--     batch       根批次自己(depth 0),x = 它收进来的量(收货 + 加工产出的流水之和)
--     fate        一个批次结点的去向,line_key:on_hand · sold · written_off · adjusted · voided(回滚作废)· consumed(喂进消耗那几炉)·
--                 split(拆去隔离转给子批)· consumed_not_kg(喂进一炉单位不全是 kg 的单 —— 料离开了库存,但那一炉不展开、不合计)·
--                 unexplained(收进来的 − 以上之和;流水与投料腿对得上时恒为 0 —— 两边是两份真源,所以它动得开,是一个检查,不是装饰)
--     run         这个批次喂进的一炉(消耗或拆分),x = 这一条投料腿的量
--     run_output  那一炉的一条产出腿 = 一个子批次结点(x = 产出量,run_id = 产出它的那一炉);子批次自己的去向挂在它下面,并且接着往下走
--     run_loss    那一炉有名字的损耗(每一类更正链的末端),line_key = 类别,loss_basis = measured / derived
--     run_remainder  那一炉的余数(拆分那一炉没有:它没有损耗、没有余数,Q3 · Q11)
--     event       不进合计、另列的事:line_key = pass_through(深度放电 —— 料穿过去,"放电并核实,由 PROC-…")·
--                 reversed(回滚了的单,带回滚时刻与更正它的那一炉)· not_kg(喂进一炉单位不全是 kg 的单)
--   【份额(Q4):按投入质量成比例,逐层乘下去,精确】一炉的产出、损耗与余数按每条投料腿的 quantity_consumed ÷ 那一炉的投入分给它;
--     一个子批次接着带着它分到的那一份走进下一炉。份额写成一对精确的数 share_num / share_den(各层投料量之积 / 各层投入之积),
--     不做除法,所以每一层【精确】加得起来:一个结点的未缩放量 x 等于它孩子们的 x 之和(批次:收进来的 = 各去向;
--     一炉:投入 = 各产出 + 各损耗 + 余数;产出腿 = 子批次收进来的),同一层的孩子共用同一对份额。
--     qty = x × share_num ÷ share_den 只是给屏幕看的(四舍五入只在屏幕上)。
--   【不是 batch_lineage】那张往上走的表在一炉多产出时把整条投料腿重复到每一条产出上(Step 0 §1.8),加不起来,所以不复用。
--   只有【没回滚、单位全是 kg】的消耗与拆分那几炉会被展开(processing_run_flow_all 的 flow = consumption / transfer、not_kg = false)。
--   批次 → 一炉 → 产出的走法只经 processing_inputs / processing_outputs;一个产出批次只由一条产出腿生出来(processing_outputs 的约定),
--   所以子批次收进来的 = 那条产出腿的量。深度上限 20(工序链今天最长 6 段)。
--   读者:batch_balance_tree(带门)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.batch_balance_tree_all WITH (security_invoker = off) AS
 WITH RECURSIVE batches AS (
         SELECT 'inbound'::text AS kind,
            b.id,
            b.code,
            b.material_id,
            b.unit
           FROM inbound_batches b
        UNION ALL
         SELECT 'output'::text AS kind,
            b.id,
            b.code,
            b.material_id,
            b.unit
           FROM output_batches b
        ), legs AS (
         SELECT pi.id AS leg_id,
            pi.run_id,
                CASE
                    WHEN pi.inbound_batch_id IS NOT NULL THEN 'inbound'::text
                    ELSE 'output'::text
                END AS kind,
            COALESCE(pi.inbound_batch_id, pi.output_batch_id) AS batch_id,
            pi.quantity_consumed AS q,
            f.flow,
            f.not_kg,
            f.input_qty AS run_input
           FROM processing_inputs pi
             JOIN processing_run_flow_all f ON f.run_id = pi.run_id
        ), walk(root_kind, root_id, kind, batch_id, node_key, parent_key, depth, num, den, via_output_qty, via_run_id) AS (
         SELECT b.kind,
            b.id,
            b.kind,
            b.id,
            'r'::text AS node_key,
            NULL::text AS parent_key,
            0 AS depth,
            1::numeric AS num,
            1::numeric AS den,
            NULL::numeric AS via_output_qty,
            NULL::uuid AS via_run_id
           FROM batches b
        UNION ALL
         SELECT w.root_kind,
            w.root_id,
            'output'::text AS kind,
            po.output_batch_id,
            (((w.node_key || '/'::text) || l.leg_id::text) || '/o:'::text) || po.id::text,
            (w.node_key || '/'::text) || l.leg_id::text,
            w.depth + 2,
            w.num * l.q,
            w.den * l.run_input,
            po.quantity_produced,
            l.run_id
           FROM walk w
             JOIN legs l ON l.kind = w.kind AND l.batch_id = w.batch_id
             JOIN processing_outputs po ON po.run_id = l.run_id
          WHERE (l.flow = ANY (ARRAY['consumption'::text, 'transfer'::text])) AND NOT l.not_kg AND l.run_input > 0::numeric AND w.depth < 40
        ), mvagg AS (
         SELECT
                CASE
                    WHEN m.inbound_batch_id IS NOT NULL THEN 'inbound'::text
                    ELSE 'output'::text
                END AS kind,
            COALESCE(m.inbound_batch_id, m.output_batch_id) AS batch_id,
            COALESCE(sum(m.qty_delta) FILTER (WHERE m.movement_type = ANY (ARRAY['receipt'::text, 'processing_produce'::text])), 0::numeric) AS received,
            sum(m.qty_delta) AS on_hand,
            COALESCE(- sum(m.qty_delta) FILTER (WHERE m.movement_type = 'sale'::text), 0::numeric) AS sold,
            COALESCE(- sum(m.qty_delta) FILTER (WHERE m.movement_type = 'writeoff'::text), 0::numeric) AS written_off,
            COALESCE(- sum(m.qty_delta) FILTER (WHERE m.movement_type = 'adjustment'::text), 0::numeric) AS adjusted,
            COALESCE(- sum(m.qty_delta) FILTER (WHERE m.movement_type = 'reversal_void'::text), 0::numeric) AS voided
           FROM inventory_movements m
          GROUP BY (
                CASE
                    WHEN m.inbound_batch_id IS NOT NULL THEN 'inbound'::text
                    ELSE 'output'::text
                END), (COALESCE(m.inbound_batch_id, m.output_batch_id))
        ), legagg AS (
         SELECT l.kind,
            l.batch_id,
            COALESCE(sum(l.q) FILTER (WHERE l.flow = 'consumption'::text AND NOT l.not_kg), 0::numeric) AS consumed,
            COALESCE(sum(l.q) FILTER (WHERE l.flow = 'transfer'::text AND NOT l.not_kg), 0::numeric) AS split,
            COALESCE(sum(l.q) FILTER (WHERE (l.flow = ANY (ARRAY['consumption'::text, 'transfer'::text])) AND l.not_kg), 0::numeric) AS consumed_not_kg
           FROM legs l
          GROUP BY l.kind, l.batch_id
        ), nodes AS (
         SELECT w.root_kind,
            w.root_id,
            w.kind,
            w.batch_id,
            w.node_key,
            w.parent_key,
            w.depth,
            w.num,
            w.den,
            w.via_output_qty,
            w.via_run_id,
            COALESCE(ma.received, 0::numeric) AS received,
            COALESCE(ma.on_hand, 0::numeric) AS on_hand,
            COALESCE(ma.sold, 0::numeric) AS sold,
            COALESCE(ma.written_off, 0::numeric) AS written_off,
            COALESCE(ma.adjusted, 0::numeric) AS adjusted,
            COALESCE(ma.voided, 0::numeric) AS voided,
            COALESCE(la.consumed, 0::numeric) AS consumed,
            COALESCE(la.split, 0::numeric) AS split,
            COALESCE(la.consumed_not_kg, 0::numeric) AS consumed_not_kg
           FROM walk w
             LEFT JOIN mvagg ma ON ma.kind = w.kind AND ma.batch_id = w.batch_id
             LEFT JOIN legagg la ON la.kind = w.kind AND la.batch_id = w.batch_id
        ), tree AS (
         SELECT n.root_kind,
            n.root_id,
            n.node_key,
            n.parent_key,
            n.depth,
                CASE
                    WHEN n.depth = 0 THEN 'batch'::text
                    ELSE 'run_output'::text
                END AS node_type,
            NULL::text AS line_key,
            COALESCE(n.via_output_qty, n.received) AS x,
            n.num AS share_num,
            n.den AS share_den,
            n.kind AS batch_kind,
            n.batch_id,
            n.via_run_id AS run_id,
            NULL::text AS loss_category_code,
            NULL::text AS loss_basis
           FROM nodes n
        UNION ALL
         SELECT n.root_kind,
            n.root_id,
            (n.node_key || '|'::text) || v.line_key,
            n.node_key,
            n.depth + 1,
            'fate'::text,
            v.line_key,
            v.x,
            n.num,
            n.den,
            n.kind,
            n.batch_id,
            NULL::uuid,
            NULL::text,
            NULL::text
           FROM nodes n
             CROSS JOIN LATERAL ( VALUES ('on_hand'::text,n.on_hand,1), ('sold'::text,n.sold,2), ('written_off'::text,n.written_off,3), ('adjusted'::text,n.adjusted,4), ('voided'::text,n.voided,5), ('consumed'::text,n.consumed,6), ('split'::text,n.split,7), ('consumed_not_kg'::text,n.consumed_not_kg,8), ('unexplained'::text,n.received - n.on_hand - n.sold - n.written_off - n.adjusted - n.voided - n.consumed - n.split - n.consumed_not_kg,9)) v(line_key, x, ord)
        UNION ALL
         SELECT n.root_kind,
            n.root_id,
            (n.node_key || '/'::text) || l.leg_id::text,
            n.node_key,
            n.depth + 1,
                CASE
                    WHEN (l.flow = ANY (ARRAY['consumption'::text, 'transfer'::text])) AND NOT l.not_kg THEN 'run'::text
                    ELSE 'event'::text
                END,
                CASE
                    WHEN (l.flow = ANY (ARRAY['consumption'::text, 'transfer'::text])) AND NOT l.not_kg THEN l.flow
                    WHEN l.flow = 'pass_through'::text THEN 'pass_through'::text
                    WHEN l.flow = 'reversed'::text THEN 'reversed'::text
                    ELSE 'not_kg'::text
                END,
            l.q,
            n.num,
            n.den,
            n.kind,
            n.batch_id,
            l.run_id,
            NULL::text,
            NULL::text
           FROM nodes n
             JOIN legs l ON l.kind = n.kind AND l.batch_id = n.batch_id
        UNION ALL
         SELECT n.root_kind,
            n.root_id,
            (((n.node_key || '/'::text) || l.leg_id::text) || '/l:'::text) || pl.id::text,
            (n.node_key || '/'::text) || l.leg_id::text,
            n.depth + 2,
            'run_loss'::text,
            pl.loss_category_code,
            pl.quantity,
            n.num * l.q,
            n.den * l.run_input,
            NULL::text,
            NULL::uuid,
            l.run_id,
            pl.loss_category_code,
            pl.basis
           FROM nodes n
             JOIN legs l ON l.kind = n.kind AND l.batch_id = n.batch_id
             JOIN processing_run_losses pl ON pl.run_id = l.run_id
          WHERE l.flow = 'consumption'::text AND NOT l.not_kg AND l.run_input > 0::numeric AND NOT (EXISTS ( SELECT 1
                   FROM processing_run_losses x
                  WHERE x.corrects_id = pl.id))
        UNION ALL
         SELECT n.root_kind,
            n.root_id,
            ((n.node_key || '/'::text) || l.leg_id::text) || '/rem'::text,
            (n.node_key || '/'::text) || l.leg_id::text,
            n.depth + 2,
            'run_remainder'::text,
            f.remainder_state,
            f.remainder_qty,
            n.num * l.q,
            n.den * l.run_input,
            NULL::text,
            NULL::uuid,
            l.run_id,
            NULL::text,
            NULL::text
           FROM nodes n
             JOIN legs l ON l.kind = n.kind AND l.batch_id = n.batch_id
             JOIN processing_run_flow_all f ON f.run_id = l.run_id
          WHERE l.flow = 'consumption'::text AND NOT l.not_kg AND l.run_input > 0::numeric
        )
 SELECT t.root_kind,
    t.root_id,
    rb.code AS root_code,
    t.node_key,
    t.parent_key,
    t.depth,
    t.node_type,
    t.line_key,
    t.x,
    t.share_num,
    t.share_den,
    t.x * t.share_num / t.share_den AS qty,
    t.batch_kind,
    t.batch_id,
    bb.code AS batch_code,
    bb.unit,
    mat.name AS material_name,
    mat.form_code,
    t.run_id,
    rf.run_code,
    rf.operation_type_code,
    rf.process_date,
    rf.flow,
    rf.remainder_state,
    rf.era_mes4a,
    rf.deleted_at AS reversed_at,
    cr.code AS corrects_run_code,
    cb.code AS corrected_by_run_code,
    t.loss_category_code,
    t.loss_basis
   FROM tree t
     JOIN batches rb ON rb.kind = t.root_kind AND rb.id = t.root_id
     LEFT JOIN batches bb ON bb.kind = t.batch_kind AND bb.id = t.batch_id
     LEFT JOIN materials mat ON mat.id = bb.material_id
     LEFT JOIN processing_run_flow_all rf ON rf.run_id = t.run_id
     LEFT JOIN processing_runs cr ON cr.id = rf.corrects_run_id
     LEFT JOIN LATERAL ( SELECT c.code
           FROM processing_runs c
          WHERE c.corrects_run_id = t.run_id
          ORDER BY c.created_at, c.code
         LIMIT 1) cb ON true;

COMMENT ON VIEW public.batch_balance_tree_all IS
    'MES-5b-1:每一个批次往下走的质量树 —— 批次 → 去向(在手 · 卖出 · 注销 · 调整 · 回滚作废 · 消耗 · 拆去隔离 · 未解释)→ 喂进的每一炉 → 它的产出(子批次,接着往下走)、有名字的损耗与余数;放电、回滚与单位不是 kg 的单另列成事件。份额按投入质量成比例,写成精确的一对 share_num / share_den,每一层的未缩放量 x 精确相加;qty = x × num ÷ den 只给屏幕。基视图,不给人读。';

REVOKE ALL ON public.batch_balance_tree_all FROM authenticated, anon;

-- db/views/processing_run_yield_all.sql
-- MES-5b-1(2026-10-08,规格 §3.5a;MES-5a Q23;MES-5b Step 0 Q13 · Q15,Tim):【一炉的质量得率】—— 基视图,不给人读。
--   只算【消耗】那几炉(processing_run_flow_all.flow = consumption、单位全是 kg):放电与拆去隔离没有得率(它们不消耗),
--   回滚了的单不算;MES-4a 之前的单算,era_mes4a = false 让页面标出来(Q6)。
--   分母一律是这一炉的总投入(MES-5a Q23 的裁定;electrode_powder_line 的总投入就是极片,所以它正是规格 §3.5 的"每单位极片出多少粉")。
--   每一炉几行(line_kind / line_key):
--     output        —— 一种产出形态(产出物料的 form_code;没有形态 '(none)')一行,qty = 这一形态的产出腿之和。除尘收集的粉尘是一种产出(MES-4b)
--     total_output  —— 全部产出
--     loss          —— 一个损耗类别一行(更正链末端),recoverable = 这一类不是真损耗(loss_categories.is_true_loss = false:设备挂料、扫地料 —— 金属"留着")
--     remainder     —— 余数,line_key = 它的状态
--   yield_pct = qty × 100 ÷ 投入(投入为 0 时为空)。
--   V37(Q15):output 那几行带上 operation_type_output_forms.expected_yield_pct(这道工序 × 这一形态的预期得率,Not yet set = 空)与
--     below_expected(得率低于它为真;没给为空 —— "判断不了",不是"没低于")。只标,从不拒。
--   读者:processing_run_yield(带门);分组的合计在 processing_yield_summary_all。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_run_yield_all WITH (security_invoker = off) AS
 WITH runs AS (
         SELECT f.run_id,
            f.run_code,
            f.process_date,
            f.month,
            f.operation_type_code,
            f.equipment_id,
            f.era_mes4a,
            f.input_qty,
            f.output_qty,
            f.remainder_qty,
            f.remainder_state
           FROM processing_run_flow_all f
          WHERE f.flow = 'consumption'::text AND NOT f.not_kg
        ), lines AS (
         SELECT r.run_id,
            'output'::text AS line_kind,
            COALESCE(m.form_code, '(none)'::text) AS line_key,
            NULL::boolean AS recoverable,
            sum(po.quantity_produced) AS qty
           FROM runs r
             JOIN processing_outputs po ON po.run_id = r.run_id
             JOIN output_batches ob ON ob.id = po.output_batch_id
             JOIN materials m ON m.id = ob.material_id
          GROUP BY r.run_id, (COALESCE(m.form_code, '(none)'::text))
        UNION ALL
         SELECT r.run_id,
            'total_output'::text,
            NULL::text,
            NULL::boolean,
            r.output_qty
           FROM runs r
        UNION ALL
         SELECT r.run_id,
            'loss'::text,
            l.loss_category_code,
            NOT lc.is_true_loss,
            sum(l.quantity) AS sum
           FROM runs r
             JOIN processing_run_losses l ON l.run_id = r.run_id
             JOIN loss_categories lc ON lc.code = l.loss_category_code
          WHERE NOT (EXISTS ( SELECT 1
                   FROM processing_run_losses x
                  WHERE x.corrects_id = l.id))
          GROUP BY r.run_id, l.loss_category_code, lc.is_true_loss
        UNION ALL
         SELECT r.run_id,
            'remainder'::text,
            r.remainder_state,
            NULL::boolean,
            r.remainder_qty
           FROM runs r
        )
 SELECT r.run_id,
    r.run_code,
    r.process_date,
    r.month,
    r.operation_type_code,
    r.equipment_id,
    r.era_mes4a,
    r.input_qty,
    l.line_kind,
    l.line_key,
    l.recoverable,
    l.qty,
        CASE
            WHEN r.input_qty > 0::numeric THEN l.qty * 100::numeric / r.input_qty
            ELSE NULL::numeric
        END AS yield_pct,
    tf.expected_yield_pct,
        CASE
            WHEN l.line_kind = 'output'::text AND tf.expected_yield_pct IS NOT NULL AND r.input_qty > 0::numeric THEN (l.qty * 100::numeric / r.input_qty) < tf.expected_yield_pct
            ELSE NULL::boolean
        END AS below_expected
   FROM runs r
     JOIN lines l ON l.run_id = r.run_id
     LEFT JOIN operation_type_output_forms tf ON l.line_kind = 'output'::text AND tf.operation_type_code = r.operation_type_code AND tf.form_code = l.line_key;

COMMENT ON VIEW public.processing_run_yield_all IS
    'MES-5b-1:一炉的质量得率(只算消耗那几炉,分母 = 总投入):每一种产出形态 · 全部产出 · 每一类有名字的损耗(带"可回收")· 余数,各占投入的 %;产出那几行带 V37(预期得率)与 below_expected(只标,不拒)。基视图,不给人读。';

REVOKE ALL ON public.processing_run_yield_all FROM authenticated, anon;

-- db/views/processing_run_origin_share_all.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q4 · Q14,Tim):【一炉的投入里,有多少来自哪一个"源头批次"】—— 基视图,不给人读。
--   源头 = 每一个进料批次,以及每一个【不是由加工产出】的产出批次(手工建的产出批 —— 它往上没有加工单可追)。
--   份额就是 batch_balance_tree_all 往下走时算出来的那一份(按投入质量成比例,逐层乘下去):一炉经由某个源头的每一条路径
--   分到的投入之和 ÷ 这一炉的投入。只有消耗那几炉(flow = consumption)。同一炉在全部源头上的份额加起来 = 1
--   (这里是一次除法,得率的分组用它 —— 屏幕上是百分数;批次那棵树本身不做这次除法,它保持精确)。
--   供应商与化学体系两种分组经它走到源头批次(Q14):进料批的供应商与物料的化学体系;手工产出批没有供应商。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_run_origin_share_all WITH (security_invoker = off) AS
 SELECT t.run_id,
    t.root_kind,
    t.root_id,
    sum(t.qty) / f.input_qty AS share
   FROM batch_balance_tree_all t
     JOIN processing_run_flow_all f ON f.run_id = t.run_id
  WHERE t.node_type = 'run'::text AND t.line_key = 'consumption'::text AND f.input_qty > 0::numeric
    AND (t.root_kind = 'inbound'::text OR NOT (EXISTS ( SELECT 1
           FROM processing_outputs po
          WHERE po.output_batch_id = t.root_id)))
  GROUP BY t.run_id, t.root_kind, t.root_id, f.input_qty;

COMMENT ON VIEW public.processing_run_origin_share_all IS
    'MES-5b-1:一炉(消耗)的投入里来自每一个源头批次(进料批,或不由加工产出的产出批)的份额,按投入质量成比例逐层乘下去;同一炉的份额之和 = 1。供应商与化学体系的得率分组经它走到源头。基视图,不给人读。';

REVOKE ALL ON public.processing_run_origin_share_all FROM authenticated, anon;

-- db/views/processing_yield_summary_all.sql
-- MES-5b-1(2026-10-08,MES-0 Q60;MES-5b Step 0 Q13 · Q14 · Q15,Tim):【得率按工序 × 月 × 分组的合计】—— 基视图,不给人读。
--   一行 = (分组 × 分组键 × 工序 × 月 × 一条线)。分母 = 这一组在这道工序、这个月里【全部】消耗那几炉的投入之和(不是只算产出了
--   这一形态的那几炉 —— 一炉没产出某种形态,那一形态在它身上就是 0)。分子 = 同一组那条线之和。
--   group_kind:
--     all        —— 不分组(每一炉份额 1)
--     machine    —— processing_runs.equipment_id(空 = 没记机器,group_key 为空)
--     chemistry  —— 源头批次物料的化学体系(经 processing_run_origin_share_all 按份额分);空 = "化学体系没记"(MES-0 Q60)
--     supplier   —— 源头进料批的供应商(同上);空 = 源头是一个手工建的产出批,没有供应商
--   产出形态就是 line_key(line_kind = output),所以"按形态"不是另一种分组。
--   V37:output 那几行的 expected_yield_pct 与 below_expected(只标,不拒);给了值才判断,没给为空。
--   runs / pre_mes4a_runs:这一组这一格里有几炉、其中几炉是 MES-4a 之前记的(页面据此标"含结平之前的单")。
--   回滚的、放电的、拆去隔离的、单位不是 kg 的单都不在这里(processing_run_yield_all 只收消耗那几炉)。
--   读者:processing_yield_summary(带门;供应商的名字跟进料批自己的查看码走,Q14 · Q32)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_yield_summary_all WITH (security_invoker = off) AS
 WITH runs AS (
         SELECT DISTINCT y.run_id,
            y.operation_type_code,
            y.month,
            y.equipment_id,
            y.era_mes4a,
            y.input_qty
           FROM processing_run_yield_all y
        ), origin AS (
         SELECT s.run_id,
            s.share,
            ib.supplier_id,
            m.chemistry
           FROM processing_run_origin_share_all s
             LEFT JOIN inbound_batches ib ON s.root_kind = 'inbound'::text AND ib.id = s.root_id
             LEFT JOIN output_batches ob ON s.root_kind = 'output'::text AND ob.id = s.root_id
             LEFT JOIN materials m ON m.id = COALESCE(ib.material_id, ob.material_id)
        ), grp AS (
         SELECT 'all'::text AS group_kind,
            NULL::text AS group_key,
            r.run_id,
            1::numeric AS share
           FROM runs r
        UNION ALL
         SELECT 'machine'::text,
            r.equipment_id::text,
            r.run_id,
            1::numeric
           FROM runs r
        UNION ALL
         SELECT 'chemistry'::text,
            o.chemistry,
            o.run_id,
            sum(o.share) AS sum
           FROM origin o
          GROUP BY o.chemistry, o.run_id
        UNION ALL
         SELECT 'supplier'::text,
            o.supplier_id::text,
            o.run_id,
            sum(o.share) AS sum
           FROM origin o
          GROUP BY o.supplier_id, o.run_id
        ), den AS (
         SELECT g.group_kind,
            g.group_key,
            r.operation_type_code,
            r.month,
            sum(g.share * r.input_qty) AS input_qty,
            count(DISTINCT r.run_id) AS runs,
            count(DISTINCT r.run_id) FILTER (WHERE NOT r.era_mes4a) AS pre_mes4a_runs
           FROM grp g
             JOIN runs r ON r.run_id = g.run_id
          GROUP BY g.group_kind, g.group_key, r.operation_type_code, r.month
        ), num AS (
         SELECT g.group_kind,
            g.group_key,
            y.operation_type_code,
            y.month,
            y.line_kind,
            y.line_key,
            y.recoverable,
            sum(g.share * y.qty) AS qty
           FROM grp g
             JOIN processing_run_yield_all y ON y.run_id = g.run_id
          GROUP BY g.group_kind, g.group_key, y.operation_type_code, y.month, y.line_kind, y.line_key, y.recoverable
        )
 SELECT n.group_kind,
    n.group_key,
    n.operation_type_code,
    n.month,
    n.line_kind,
    n.line_key,
    n.recoverable,
    n.qty,
    d.input_qty,
    d.runs,
    d.pre_mes4a_runs,
        CASE
            WHEN d.input_qty > 0::numeric THEN n.qty * 100::numeric / d.input_qty
            ELSE NULL::numeric
        END AS yield_pct,
    tf.expected_yield_pct,
        CASE
            WHEN n.line_kind = 'output'::text AND tf.expected_yield_pct IS NOT NULL AND d.input_qty > 0::numeric THEN (n.qty * 100::numeric / d.input_qty) < tf.expected_yield_pct
            ELSE NULL::boolean
        END AS below_expected
   FROM num n
     JOIN den d ON d.group_kind = n.group_kind AND NOT d.group_key IS DISTINCT FROM n.group_key AND NOT d.operation_type_code IS DISTINCT FROM n.operation_type_code AND d.month = n.month
     LEFT JOIN operation_type_output_forms tf ON n.line_kind = 'output'::text AND tf.operation_type_code = n.operation_type_code AND tf.form_code = n.line_key;

COMMENT ON VIEW public.processing_yield_summary_all IS
    'MES-5b-1:得率按 分组(all / machine / chemistry / supplier)× 工序 × 月 的合计;分母是这一格全部消耗那几炉的投入,化学体系与供应商按份额分到源头批次;产出那几行带 V37 与 below_expected。基视图,不给人读。';

REVOKE ALL ON public.processing_yield_summary_all FROM authenticated, anon;

-- db/views/processing_balance_monthly.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q8 · Q12,Tim):【月度物料平衡 —— 带门的外壳】。/operation/balance 与 /inventory 的物料平衡合计读它。
--   门 = processing_run_lookup 给同样这几个数(投入 · 产出 · 损耗,只有公斤)时的那一组码:module.processing.view、module.finance.view
--   或 module.inventory.view 任一 —— /inventory 今天就凭这三个之一读平衡合计,换一份真源不该把谁挡在外面。一个字的算术都不在这里。
--   属主权限:基视图从 authenticated 收回了;视图读视图走属主替换。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_balance_monthly WITH (security_invoker = off) AS
 SELECT month,
    scope,
    operation_type_code,
    line,
    line_key,
    basis,
    qty,
    runs
   FROM processing_balance_monthly_all
  WHERE has_permission('module.processing.view'::text) OR has_permission('module.finance.view'::text) OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.processing_balance_monthly IS
    'MES-5b-1:月度物料平衡,带门(module.processing.view / module.finance.view / module.inventory.view 任一)。算术全在 processing_balance_monthly_all。';

GRANT SELECT ON public.processing_balance_monthly TO authenticated;
REVOKE ALL ON public.processing_balance_monthly FROM anon;

-- db/views/stock_rollforward_monthly.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q8,Tim):【库存的月度滚动 —— 带门的外壳】。/operation/balance 的第二块读它。
--   门与月度平衡同一组码(module.processing.view / module.finance.view / module.inventory.view 任一):只有数量,没有一分钱。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.stock_rollforward_monthly WITH (security_invoker = off) AS
 SELECT month,
    unit,
    opening,
    received,
    produced,
    consumed,
    sold,
    written_off,
    adjusted,
    voided,
    moved,
    closing
   FROM stock_rollforward_monthly_all
  WHERE has_permission('module.processing.view'::text) OR has_permission('module.finance.view'::text) OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.stock_rollforward_monthly IS
    'MES-5b-1:库存的月度滚动,带门(module.processing.view / module.finance.view / module.inventory.view 任一)。算术全在 stock_rollforward_monthly_all。';

GRANT SELECT ON public.stock_rollforward_monthly TO authenticated;
REVOKE ALL ON public.stock_rollforward_monthly FROM anon;

-- db/views/batch_balance_tree.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q4 · Q5,Tim):【一个批次往下走的质量树 —— 带门的外壳】。/inbound/[id]/edit 与 /output/[id]/edit 的
--   平衡面板读它(按 root_id 取一棵)。门:module.processing.view(整棵树是加工的事实),或这个根批次自己那一页的查看码 ——
--   进料批 module.inbound.view、产出批 module.output.view(Q4:"加上批次自己那一页的码")。树上的批次编号、物料名与单号是标签,
--   跟着这一行走(AGENTS.md 常设决定 3);一个数字的钱都没有。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.batch_balance_tree WITH (security_invoker = off) AS
 SELECT root_kind,
    root_id,
    root_code,
    node_key,
    parent_key,
    depth,
    node_type,
    line_key,
    x,
    share_num,
    share_den,
    qty,
    batch_kind,
    batch_id,
    batch_code,
    unit,
    material_name,
    form_code,
    run_id,
    run_code,
    operation_type_code,
    process_date,
    flow,
    remainder_state,
    era_mes4a,
    reversed_at,
    corrects_run_code,
    corrected_by_run_code,
    loss_category_code,
    loss_basis
   FROM batch_balance_tree_all
  WHERE has_permission('module.processing.view'::text) OR root_kind = 'inbound'::text AND has_permission('module.inbound.view'::text) OR root_kind = 'output'::text AND has_permission('module.output.view'::text);

COMMENT ON VIEW public.batch_balance_tree IS
    'MES-5b-1:一个批次往下走的质量树,带门(module.processing.view,或根批次自己的查看码:进料 module.inbound.view / 产出 module.output.view)。算术全在 batch_balance_tree_all。';

GRANT SELECT ON public.batch_balance_tree TO authenticated;
REVOKE ALL ON public.batch_balance_tree FROM anon;

-- db/views/processing_run_yield.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q13,Tim):【一炉的质量得率 —— 带门的外壳】。/operation/yield 的逐炉一段读它。
--   门与 processing_runs 的读规则同一个码(module.processing.view)。算术全在 processing_run_yield_all。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_run_yield WITH (security_invoker = off) AS
 SELECT run_id,
    run_code,
    process_date,
    month,
    operation_type_code,
    equipment_id,
    era_mes4a,
    input_qty,
    line_kind,
    line_key,
    recoverable,
    qty,
    yield_pct,
    expected_yield_pct,
    below_expected
   FROM processing_run_yield_all
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_run_yield IS
    'MES-5b-1:一炉的质量得率,带门(module.processing.view)。算术全在 processing_run_yield_all。';

GRANT SELECT ON public.processing_run_yield TO authenticated;
REVOKE ALL ON public.processing_run_yield FROM anon;

-- db/views/processing_yield_summary.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q14 · Q32,Tim):【得率的分组合计 —— 带门的外壳】。/operation/yield 读它。门 module.processing.view。
--   分组的标签(group_label):
--     machine   —— 机器的资产编号与名称(fixed_assets.code · description)—— 标签跟着这一行走(AGENTS.md 常设决定 3)
--     chemistry —— 化学体系的代码(battery_chemistries.code);空 = 化学体系没记
--     supplier  —— 供应商的法定名称,【只给持 module.inbound.view 的人】:供应商经进料批而来,标签跟着那张批次自己的查看码走(Q14 · Q32)。
--                  不持它的人 group_label 为空、group_label_restricted 为真 —— 页面画「受限」;group_key 为空(源头不是进料批)时
--                  group_label_restricted 为假、页面画"不是来自进料批"。一个 NULL 不许同时表示"受限"与"没有"(AGENTS.md「NULL 有没有主」)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_yield_summary WITH (security_invoker = off) AS
 SELECT s.group_kind,
    s.group_key,
        CASE s.group_kind
            WHEN 'machine'::text THEN (fa.code || ' · '::text) || fa.description
            WHEN 'chemistry'::text THEN s.group_key
            WHEN 'supplier'::text THEN
            CASE
                WHEN has_permission('module.inbound.view'::text) THEN sp.legal_name
                ELSE NULL::text
            END
            ELSE NULL::text
        END AS group_label,
    s.group_kind = 'supplier'::text AND s.group_key IS NOT NULL AND NOT has_permission('module.inbound.view'::text) AS group_label_restricted,
    s.operation_type_code,
    s.month,
    s.line_kind,
    s.line_key,
    s.recoverable,
    s.qty,
    s.input_qty,
    s.runs,
    s.pre_mes4a_runs,
    s.yield_pct,
    s.expected_yield_pct,
    s.below_expected
   FROM processing_yield_summary_all s
     LEFT JOIN fixed_assets fa ON s.group_kind = 'machine'::text AND fa.id::text = s.group_key
     LEFT JOIN suppliers sp ON s.group_kind = 'supplier'::text AND sp.id::text = s.group_key
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_yield_summary IS
    'MES-5b-1:得率的分组合计,带门(module.processing.view);供应商的名字只给持 module.inbound.view 的人(否则 group_label_restricted = true),机器与化学体系的标签跟着行走。算术全在 processing_yield_summary_all。';

GRANT SELECT ON public.processing_yield_summary TO authenticated;
REVOKE ALL ON public.processing_yield_summary FROM anon;

-- ── 6 · 换掉的视图(镜像原样):待补的值 +V37 ──────────────────────────────────────────────

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
                  WHERE f.operation_type_code = tf.operation_type_code AND f.flow = 'consumption'::text AND f.era_mes4a))) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程);MES-3a 加 V2(执照 × 类别的库存上限)、V29(NEA 类别与物料的类别)、V3(每个安全状态的滞留提醒天数)、V4(每个安全状态要不要隔离)与 V34(隔离库位);MES-3b 加 V30(危险品编号的标记 · 包装说明 · 标签尺寸)、V31(电池料的 HS 编码)与 V35(电池料的危险品编号);MES-4a 加 V1(转化型工序的物料平衡容差)与 V36(声明了有范围的参数的上下限),并把 V6 的去处搬到班次字典(V6 同时答 V7);MES-4b 加 V10(勾了电解液挥发的工序的电解液份额)与 V11(交叉污染流的警戒线)。MES-5a-1 加 V9(物料的放电通过电压,只在那种物料有了放电结果之后才列);MES-5a-2 加 V25(共用池的电怎么摊,有共用池电表而规则为空时一行)。MES-5b-1 加 V37(每道工序 × 每种产出形态的预期质量得率;只在那道工序有了至少一张 MES-4a 之后的消耗炉次时才列 —— V9 的先例:没人能动手的行不列)。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- ── 7 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes5b1_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes5b1_pending_after ON COMMIT DROP AS
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
    -- ① 授权一行都没动(本刀不加码、不改任何一个角色的授权;引导的修正只在镜像里)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes5b1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes5b1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B1_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES5B1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes5b1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes5b1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES5B1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的加工单、腿、损耗、结平、批次、流水、分录、费用单、付款、设备、安全状态逐字未变(不回填)
    IF EXISTS ((SELECT b.k, b.id FROM mes5b1_pending_before b EXCEPT SELECT a.k, a.id FROM mes5b1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes5b1_pending_after a EXCEPT SELECT b.k, b.id FROM mes5b1_pending_before b)) THEN
        RAISE EXCEPTION 'MES5B1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_runs t) IS DISTINCT FROM (SELECT processing_runs FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_inputs t) IS DISTINCT FROM (SELECT processing_inputs FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_outputs t) IS DISTINCT FROM (SELECT processing_outputs FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_run_losses t) IS DISTINCT FROM (SELECT processing_run_losses FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_run_closures t) IS DISTINCT FROM (SELECT processing_run_closures FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM inbound_batches t) IS DISTINCT FROM (SELECT inbound_batches FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM output_batches t) IS DISTINCT FROM (SELECT output_batches FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM inventory_movements t) IS DISTINCT FROM (SELECT inventory_movements FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM journal_entries t) IS DISTINCT FROM (SELECT journal_entries FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM journal_lines t) IS DISTINCT FROM (SELECT journal_lines FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM expenses t) IS DISTINCT FROM (SELECT expenses FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM payments t) IS DISTINCT FROM (SELECT payments FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM devices t) IS DISTINCT FROM (SELECT devices FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM inbound_batch_safety_states t) IS DISTINCT FROM (SELECT inbound_batch_safety_states FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM output_batch_safety_states t) IS DISTINCT FROM (SELECT output_batch_safety_states FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_cost_entries t) IS DISTINCT FROM (SELECT processing_cost_entries FROM mes5b1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM discharge_module_splits t) IS DISTINCT FROM (SELECT discharge_module_splits FROM mes5b1_rows_before) THEN
        RAISE EXCEPTION 'MES5B1_PROOF|a pre-existing run, leg, loss, closure, batch, movement, journal, expense, payment, device or state changed';
    END IF;
    -- 产出形态表:只多了一列空的(去掉那一列之后逐字相同)
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'expected_yield_pct')::text, '|' ORDER BY (to_jsonb(t) - 'expected_yield_pct')::text), '')) FROM operation_type_output_forms t)
         IS DISTINCT FROM (SELECT operation_type_output_forms FROM mes5b1_rows_before)
       OR EXISTS (SELECT 1 FROM operation_type_output_forms WHERE expected_yield_pct IS NOT NULL) THEN
        RAISE EXCEPTION 'MES5B1_PROOF|operation_type_output_forms changed beyond an empty V37 column';
    END IF;
    -- 工序表:除了拆分那一道的容差,逐字相同;拆分那一道的容差 = 0
    IF (SELECT md5(string_agg((to_jsonb(o) - 'balance_tolerance_pct')::text || '|' || CASE WHEN o.code = 'discharge_quarantine_split' THEN '' ELSE COALESCE(o.balance_tolerance_pct::text, '') END, '|' ORDER BY o.code)) FROM operation_types o)
         IS DISTINCT FROM (SELECT d FROM mes5b1_ops_before)
       OR (SELECT balance_tolerance_pct FROM operation_types WHERE code = 'discharge_quarantine_split') IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|operation_types changed beyond the split tolerance 0';
    END IF;

    -- ④ 变更记录只在 permissions(33 行声明)与 operation_types(1 行容差)上动了
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes5b1_log_before), 0) AND c.table_name NOT IN ('permissions', 'operation_types');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B1_PROOF|change_log moved on %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes5b1_log_before), 0) AND c.table_name = 'permissions') <> 33
       OR (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes5b1_log_before), 0) AND c.table_name = 'operation_types') <> 1 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|expected 33 permissions rows and 1 operation_types row in the change log';
    END IF;

    -- ⑤ 声明:33 个动作码声明了,没有屏幕的那一个没声明;线上【每一个】角色都满足"动作码蕴含查看码"(Step 0 §0:67 / 67)
    IF (SELECT count(*) FROM permissions WHERE requires_view_any IS NOT NULL) <> 33
       OR (SELECT requires_view_any FROM permissions WHERE code = 'action.anonymise_employee') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B1_PROOF|expected 33 declared action codes and action.anonymise_employee undeclared';
    END IF;
    SELECT string_agg(ro.code || ' -> ' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B1_PROOF|a live role holds an action without any of its views: %', v_bad; END IF;

    -- ⑥ 没有设任何东西:V37 空(上面)、require_calibrated_since 空;线上没有一张 MES-4a 之后的单,所以 V37 那一支零行
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B1_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑦ 匿名面:anon 能执行的【恰好】两支;十二张新视图 anon 一张都读不到;基视图 authenticated 读不到,外壳读得到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES5B1_PROOF|anon executes: %', v_bad;
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('processing_run_flow_all', 'processing_balance_monthly_all', 'stock_rollforward_monthly_all', 'batch_balance_tree_all', 'processing_run_yield_all', 'processing_run_origin_share_all', 'processing_yield_summary_all', 'processing_balance_monthly', 'stock_rollforward_monthly', 'batch_balance_tree', 'processing_run_yield', 'processing_yield_summary') AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B1_PROOF|anon can read %', v_bad; END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('processing_run_flow_all', 'processing_balance_monthly_all', 'stock_rollforward_monthly_all', 'batch_balance_tree_all', 'processing_run_yield_all', 'processing_run_origin_share_all', 'processing_yield_summary_all') AND has_table_privilege('authenticated', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B1_PROOF|a base view is readable by authenticated: %', v_bad; END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('processing_balance_monthly', 'stock_rollforward_monthly', 'batch_balance_tree', 'processing_run_yield', 'processing_yield_summary') AND NOT has_table_privilege('authenticated', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B1_PROOF|a reader is not readable by authenticated: %', v_bad; END IF;
    IF (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relname IN ('processing_run_flow_all', 'processing_balance_monthly_all', 'stock_rollforward_monthly_all', 'batch_balance_tree_all', 'processing_run_yield_all', 'processing_run_origin_share_all', 'processing_yield_summary_all', 'processing_balance_monthly', 'stock_rollforward_monthly', 'batch_balance_tree', 'processing_run_yield', 'processing_yield_summary')) <> 12 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|expected 12 new views';
    END IF;

    -- ⑧ 那 44 条开着的读策略还是 44 条;变更记录覆盖零缺口(没有新表,豁免仍是 8);遮蔽零缺口(规则仍是 111 条 —— 没有新的遮蔽列)
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|the open read policies are no longer 44';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 111 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑨ 提醒臂 59 不变;待补的值 19 → 20 支;V37 今天零行;V1 不再列拆分那道工序
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|operations_now should still have 59 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 20 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|pending_values should have 20 arms';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes5b1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES5B1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes5b1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes5b1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
