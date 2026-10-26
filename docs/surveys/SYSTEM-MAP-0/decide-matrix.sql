-- SYSTEM-MAP-0 Part 3.2 · 谁决定得了哪一种审批 —— 只对【本地重建】跑(线上的角色授权已装进来,load-grants-local.sql)。
-- 每个角色一个合成用户:auth.users 一行(已确认、未封禁、未删除 —— real_role_grants 的四条判据)+ user_roles 一行;审批链设成线上的值
-- (approvals ON · 一级 finance · 二级 cfo · 门槛 1000,线上读数 readback-closeout.txt)。然后以每个人的 JWT sub(postgres 身份;
-- has_permission 与 auth.uid() 都读 request.jwt.claims)逐条求【库里那道门】:权限码用 has_permission(),
-- 角色级别用 require_approver_for(1|2)(拒绝即 0)。门的出处:每一支 decide 函数的守卫行(readings.md §3.2 的表逐条注明)。
\set ON_ERROR_STOP 1
BEGIN;
CREATE TEMP TABLE synth(role_code text, uid uuid) ON COMMIT DROP;
INSERT INTO synth SELECT c, gen_random_uuid() FROM unnest(ARRAY['admin','cfo','cco','cto','finance','gm','warehouse']) c;
INSERT INTO auth.users (id, email, email_confirmed_at, created_at) SELECT uid, 'sm0-' || role_code || '@local.test', now(), now() FROM synth;
INSERT INTO user_roles (user_id, role_id) SELECT s.uid, r.id FROM synth s JOIN roles r ON r.code = s.role_code;
-- 本地重建里引导出来的角色持有人(若有)随后撤掉(先插新的,否则撞 guard_last_admin),让「真持有人」只剩这七个合成用户 —— 与线上每个角色恰好 1 个持有人同形
UPDATE user_roles SET revoked_at = now() WHERE revoked_at IS NULL AND user_id NOT IN (SELECT uid FROM synth);
-- 审批策略只经 set_approvals_policy 写(guard_approvals_policy_write);以合成 admin 的身份调(它持 action.manage_permissions)
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT uid FROM synth WHERE role_code = 'admin'), 'role', 'authenticated')::text, true) \g /dev/null
SELECT set_approvals_policy(true, 'finance', 'cfo', 1000) \g /dev/null
SELECT 'POLICY|' || approvals_enabled || '|' || approval_level1_role_code || '/' || approval_level2_role_code || '/' || approval_threshold_base::int FROM finance_settings \g
CREATE TEMP TABLE gate(decision text, codes text[], level smallint) ON COMMIT DROP;
INSERT INTO gate VALUES
 ('payment request (decide_payment_request)',           ARRAY['module.finance.view','data.view_prices'], 2),
 ('credit note / invoice void (decide_invoice_request)', ARRAY['module.finance.view','data.view_prices'], 2),
 ('GST filing (decide_gst_filing_request)',             ARRAY['module.finance.view','data.view_prices'], 2),
 ('manual journal (decide_journal_request)',            ARRAY['module.finance.view','data.view_prices'], 2),
 ('asset disposal (decide_asset_disposal_request)',     ARRAY['module.finance.view','data.view_prices'], 2),
 ('warehouse request (decide_warehouse_request)',       ARRAY['module.finance.view','data.view_prices'], 2),
 ('payroll post/reversal (decide_payroll_request)',     ARRAY['module.hr.view','data.view_pay'], 2),
 ('terms (decide_terms_request)',                       ARRAY['module.pricing.view','data.view_prices','data.view_purchase_prices','module.suppliers.view','module.customers.view'], 2),
 ('receipt price (decide_receipt_price_request)',       ARRAY['module.inbound.view','data.view_purchase_prices'], 2),
 ('shipping release (decide_shipping_release)',         ARRAY['module.sales.view','data.view_prices'], 2),
 ('expense claim < 1,000 (decide_expense_claim_items)', ARRAY['module.finance.view','data.view_prices'], 1),
 ('expense claim >= 1,000 (decide_expense_claim_items)',ARRAY['module.finance.view','data.view_prices'], 2),
 ('PO < 1,000 (approve_purchase_order)',                ARRAY['module.purchasing.view','data.view_purchase_prices'], 1),
 ('PO >= 1,000 (approve_purchase_order)',               ARRAY['module.purchasing.view','data.view_purchase_prices'], 2),
 ('salary change, normal (pay_decision_code)',          ARRAY['module.hr.view','data.view_pay','action.approve_review'], NULL),
 ('salary change, CFO is party',                        ARRAY['module.hr.view','data.view_pay','action.hr_reviews'], NULL),
 ('review approval, normal (review_approval_code)',     ARRAY['action.approve_review'], NULL),
 ('review approval, CFO is party',                      ARRAY['action.hr_reviews'], NULL),
 ('leave (decide_leave_request)',                       ARRAY['action.decide_hr_requests'], NULL),
 ('medical claim (decide_medical_claim)',               ARRAY['action.decide_hr_requests'], NULL),
 ('overtime batch (decide_overtime_batch)',             ARRAY['action.overtime_approve'], NULL),
 ('supplier approve (set_supplier_status)',             ARRAY['action.supplier_approve'], NULL),
 ('NCR disposition (decide_ncr)',                       ARRAY['action.ncr_decide'], NULL),
 ('capture draft (confirm_capture_draft)',              ARRAY['action.confirm_capture'], NULL),
 ('work-order / blending release (release_*)',          ARRAY['action.wo_release'], NULL),
 ('stocktake post (post_stocktake)',                    ARRAY['action.stocktake_post'], NULL);
DO $$
DECLARE s record; g record; ok boolean; lvl_ok boolean;
BEGIN
  FOR s IN SELECT * FROM synth ORDER BY array_position(ARRAY['admin','cfo','cco','cto','finance','gm','warehouse'], role_code) LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', s.uid, 'role', 'authenticated')::text, true);
    FOR g IN SELECT * FROM gate LOOP
      SELECT bool_and(has_permission(c)) INTO ok FROM unnest(g.codes) c;
      lvl_ok := true;
      IF g.level IS NOT NULL THEN
        BEGIN PERFORM require_approver_for(g.level); EXCEPTION WHEN OTHERS THEN lvl_ok := false; END;
      END IF;
      RAISE NOTICE 'DECIDE|%|%|%|codes=%|level=%', s.role_code, g.decision, (ok AND lvl_ok), ok, CASE WHEN g.level IS NULL THEN '-' ELSE lvl_ok::text END;
    END LOOP;
  END LOOP;
END $$;
ROLLBACK;
