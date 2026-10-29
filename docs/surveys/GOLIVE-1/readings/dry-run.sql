\set ON_ERROR_STOP 1
SET lock_timeout = '10s';
\timing on
BEGIN;
SELECT 'PROOF|clock before|' || clock_timestamp();
SELECT 'PROOF|B|postgres|' || json_build_object(
  'roles', (SELECT string_agg(r.code || ':' || (SELECT count(*) FROM public.user_roles ur WHERE ur.role_id = r.id AND ur.revoked_at IS NULL) || 'h/'
                              || (SELECT count(*) FROM public.role_permissions rp WHERE rp.role_id = r.id) || 'c', ' ' ORDER BY r.code) FROM public.roles r),
  'held_hr_proc_sales_incl_revoked', (SELECT count(*) FROM public.user_roles ur JOIN public.roles r ON r.id = ur.role_id WHERE r.code IN ('hr','procurement','sales')),
  'seven_grants', (SELECT count(*) || ' ' || md5(string_agg(r.code || '/' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code IN ('admin','cco','cfo','cto','finance','gm','warehouse')),
  'user_roles', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.user_roles t),
  'suppliers', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.suppliers t), 'employees', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.employees t), 'contracts', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contracts t),
  'sales_settlements', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.sales_settlements t), 'contract_pricing_terms', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contract_pricing_terms t),
  'contract_refining_charges', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contract_refining_charges t), 'contract_penalty_elements', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contract_penalty_elements t),
  'contract_insurance_obligations', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contract_insurance_obligations t),
  'cod_issues', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.cod_issues t), 'cods', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.certificates_of_destruction t),
  'anon_relations', (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r','v','m','p','f')
                       AND has_table_privilege('anon', c.oid, 'SELECT')),
  'anon_functions', (SELECT string_agg(p.proname, ',' ORDER BY p.proname) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND has_function_privilege('anon', p.oid, 'EXECUTE')),
  'auditor', (SELECT string_agg(rp.permission_code, ',' ORDER BY rp.permission_code) FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code = 'auditor'),
  'employee_desc', (SELECT left(description_en, 60) FROM public.roles WHERE code = 'employee'),
  'policies', (SELECT json_object_agg(tablename || ' / ' || policyname, qual ORDER BY tablename, policyname) FROM pg_policies
                WHERE schemaname = 'public' AND cmd = 'SELECT' AND tablename IN ('metal_prices', 'index_market_calendar', 'pricing_settings')),
  'container_overview_where', (SELECT substring(pg_get_viewdef('public.container_overview'::regclass) FROM 'WHERE .*$')),
  'price_columns_granted', (SELECT count(*) FROM (VALUES ('sales_settlements','amount_usd'), ('contract_refining_charges','usd_per_tonne_of_metal'),
                              ('contract_penalty_elements','usd_per_tonne_per_pct_over'), ('contract_insurance_obligations','min_amount'),
                              ('contract_pricing_terms','payable_pct')) x(t, col) WHERE has_column_privilege('authenticated', 'public.' || x.t, x.col, 'SELECT')),
  'status_history_trigger', (SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgrelid = 'public.suppliers'::regclass AND tgname = 'trg_suppliers_status_history'))::text;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|B|cfo|reads|' || json_build_object(
  'metal_prices', (SELECT count(*) FROM public.metal_prices), 'calendar', (SELECT count(*) FROM public.index_market_calendar),
  'pricing_settings', (SELECT count(*) FROM public.pricing_settings), 'container_overview', (SELECT count(*) FROM public.container_overview),
  'settlements', (SELECT count(*) FROM public.sales_settlements), 'pricing_terms', (SELECT count(*) FROM public.contract_pricing_terms),
  'refining', (SELECT count(*) FROM public.contract_refining_charges), 'penalty', (SELECT count(*) FROM public.contract_penalty_elements),
  'insurance', (SELECT count(*) FROM public.contract_insurance_obligations))::text;
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"01ae00e4-306f-4527-8537-10291e4750c7","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|B|cco|reads|' || json_build_object(
  'metal_prices', (SELECT count(*) FROM public.metal_prices), 'calendar', (SELECT count(*) FROM public.index_market_calendar),
  'pricing_settings', (SELECT count(*) FROM public.pricing_settings), 'container_overview', (SELECT count(*) FROM public.container_overview),
  'settlements', (SELECT count(*) FROM public.sales_settlements), 'pricing_terms', (SELECT count(*) FROM public.contract_pricing_terms),
  'refining', (SELECT count(*) FROM public.contract_refining_charges), 'penalty', (SELECT count(*) FROM public.contract_penalty_elements),
  'insurance', (SELECT count(*) FROM public.contract_insurance_obligations))::text;
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"c8116e6c-80db-4a16-be12-24fb6ce6859d","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|B|warehouse|reads|' || json_build_object(
  'metal_prices', (SELECT count(*) FROM public.metal_prices), 'calendar', (SELECT count(*) FROM public.index_market_calendar),
  'pricing_settings', (SELECT count(*) FROM public.pricing_settings), 'container_overview', (SELECT count(*) FROM public.container_overview),
  'settlements', (SELECT count(*) FROM public.sales_settlements), 'pricing_terms', (SELECT count(*) FROM public.contract_pricing_terms),
  'refining', (SELECT count(*) FROM public.contract_refining_charges), 'penalty', (SELECT count(*) FROM public.contract_penalty_elements),
  'insurance', (SELECT count(*) FROM public.contract_insurance_obligations))::text;
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"476bf8c8-c248-4352-9a75-945bf52ca390","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|B|finance|reads|' || json_build_object(
  'metal_prices', (SELECT count(*) FROM public.metal_prices), 'calendar', (SELECT count(*) FROM public.index_market_calendar),
  'pricing_settings', (SELECT count(*) FROM public.pricing_settings), 'container_overview', (SELECT count(*) FROM public.container_overview),
  'settlements', (SELECT count(*) FROM public.sales_settlements), 'pricing_terms', (SELECT count(*) FROM public.contract_pricing_terms),
  'refining', (SELECT count(*) FROM public.contract_refining_charges), 'penalty', (SELECT count(*) FROM public.contract_penalty_elements),
  'insurance', (SELECT count(*) FROM public.contract_insurance_obligations))::text;
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000601e","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|B|no-role|reads|' || json_build_object(
  'metal_prices', (SELECT count(*) FROM public.metal_prices), 'calendar', (SELECT count(*) FROM public.index_market_calendar),
  'pricing_settings', (SELECT count(*) FROM public.pricing_settings), 'container_overview', (SELECT count(*) FROM public.container_overview),
  'settlements', (SELECT count(*) FROM public.sales_settlements), 'pricing_terms', (SELECT count(*) FROM public.contract_pricing_terms),
  'refining', (SELECT count(*) FROM public.contract_refining_charges), 'penalty', (SELECT count(*) FROM public.contract_penalty_elements),
  'insurance', (SELECT count(*) FROM public.contract_insurance_obligations))::text;
RESET ROLE;
SELECT 'PROOF|clock migration start|' || clock_timestamp();

-- ════════════════════════════════════════════════════════════════════════════
-- 第 5 行 · 删之前先量:hr / procurement / sales 必须 0 个持有人(含已撤销的授予 —— user_roles 对 roles 是 ON DELETE RESTRICT)
-- ════════════════════════════════════════════════════════════════════════════
DO $held$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM public.user_roles ur JOIN public.roles r ON r.id = ur.role_id WHERE r.code IN ('hr', 'procurement', 'sales');
    IF n <> 0 THEN
        RAISE EXCEPTION 'GOLIVE1_ROLE_HELD|% grant row(s) on hr / procurement / sales — not deleting a held role', n;
    END IF;
    IF (SELECT count(*) FROM public.roles WHERE code IN ('hr', 'procurement', 'sales')) <> 3 THEN
        RAISE EXCEPTION 'GOLIVE1_ROLES_MISSING|expected hr, procurement and sales to exist before the delete';
    END IF;
END
$held$;

-- ════════════════════════════════════════════════════════════════════════════
-- 第 1 行 · 三张表的读策略
-- ════════════════════════════════════════════════════════════════════════════
DROP POLICY "metal_prices select by permission" ON public.metal_prices;
CREATE POLICY "metal_prices select by permission"
    ON public.metal_prices
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_any_permission(ARRAY['module.pricing.view'::text, 'module.suppliers.view'::text, 'module.inventory.view'::text, 'module.materials.view'::text, 'action.metal_prices'::text])));

DROP POLICY "index market calendar select by pricing permission" ON public.index_market_calendar;
CREATE POLICY "index market calendar select by pricing permission"
    ON public.index_market_calendar AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_any_permission(ARRAY['module.pricing.view'::text, 'action.metal_prices'::text])));

DROP POLICY "pricing_settings select" ON public.pricing_settings;
CREATE POLICY "pricing_settings select"
    ON public.pricing_settings AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_any_permission(ARRAY['module.pricing.view'::text, 'module.inventory.view'::text, 'action.metal_prices'::text])));

-- ════════════════════════════════════════════════════════════════════════════
-- 第 4 行 · 改身份回待审
-- ════════════════════════════════════════════════════════════════════════════

-- db/functions/requeue_supplier_on_identity_change.sql
-- GOLIVE-1 第 4 行(Tim 2026-10-20 d2 #14 · 2026-10-29 Q7):一家【已批准】的供应商改了法定名、税号或类型,它就回到待审,批准戳清空。
--   批的是"这一家";改完之后它可能已经不是那一家。不是拒绝那次改动 —— 改动照存,批准作废,要重新批。
--   「已批准」= approved · active · suspended(带着批准戳的三种状态,Tim Q7)。草稿、待审、驳回、拉黑、归档的改动不动状态。
--   回到待审之后,既有的守卫照常挡住付款与新采购单(guard_po_supplier_approved · payment_request_payee_check)。
-- 【每一条路径都适用】直连改(/suppliers/[id]/edit)、属主路径(批量导入、fixture)一样 —— 一家被换了身份的供应商,
--   不因为是哪一扇门改的就保住批准。
-- 【触发器顺序】挂在 trg_suppliers_zz_requeue_on_identity_change 上,名字排在 trg_suppliers_direct_write(直连写不许改状态 ——
--   它先看,看到的是没变的状态)、trg_suppliers_normalise_identity(先去空白、大写,所以只改大小写或空白不算改)与
--   trg_suppliers_status_transition(跳转图里没有 approved → pending_review 这一步;它先看,也看到没变的状态)之后。
--   状态历史(trg_suppliers_status_history)是 AFTER 触发器,本刀把它从 UPDATE OF status 改成 UPDATE … WHEN 状态变了,
--   所以这一次回待审照样记一行(OF status 只认 SET 列表里写了 status 的语句,而直连改从不写它)。
-- 【比较的是 IS DISTINCT FROM】NULL → 一个税号算改;同值重存不算。
CREATE OR REPLACE FUNCTION public.requeue_supplier_on_identity_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF OLD.status IN ('approved', 'active', 'suspended')
       AND NEW.status = OLD.status
       AND (NEW.legal_name IS DISTINCT FROM OLD.legal_name
            OR NEW.tax_id IS DISTINCT FROM OLD.tax_id
            OR NEW.counterparty_type IS DISTINCT FROM OLD.counterparty_type) THEN
        NEW.status      := 'pending_review';
        NEW.approved_by := NULL;
        NEW.approved_at := NULL;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.requeue_supplier_on_identity_change() IS
'GOLIVE-1 第 4 行(Tim d2 #14 · Q7):approved / active / suspended 的供应商改了 legal_name、tax_id 或 counterparty_type → 回到 pending_review,approved_by / approved_at 清空。每一条路径都适用;挂在 trg_suppliers_zz_requeue_on_identity_change(BEFORE UPDATE,排在直连守卫、身份规整与跳转校验之后)。';

DROP TRIGGER trg_suppliers_status_history ON public.suppliers;
CREATE TRIGGER trg_suppliers_status_history
    AFTER UPDATE ON public.suppliers
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION public.log_supplier_status_change();

CREATE TRIGGER trg_suppliers_zz_requeue_on_identity_change
    BEFORE UPDATE ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION public.requeue_supplier_on_identity_change();

-- ════════════════════════════════════════════════════════════════════════════
-- 第 5 行 · 空角色
-- ════════════════════════════════════════════════════════════════════════════
DELETE FROM public.roles WHERE code IN ('hr', 'procurement', 'sales');   -- role_permissions 随之 CASCADE

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, c FROM public.roles r, unnest(ARRAY['module.quality.view', 'data.view_cod', 'data.view_change_log']) c
 WHERE r.code = 'auditor'
ON CONFLICT (role_id, permission_code) DO NOTHING;

UPDATE public.roles
   SET description_en = 'Holds no codes. It opens only the personal pages every account gets: your own profile (/me), your reviews, the workbench, notifications, reminders, the calendar and the unit converter. Employee self-service is row-level and applies automatically to any account linked to an employee record.',
       description_zh = '不持任何码。它只打得开每一个账号都有的个人页:本人档案(/me)、我的评估、工作台、通知、提醒、日历与单位换算。员工自助是行级的,只要账号关联了员工档案即自动生效。'
 WHERE code = 'employee';

-- ════════════════════════════════════════════════════════════════════════════
-- 第 6 行 · container_overview 的读者
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE VIEW public.container_overview WITH (security_invoker = off) AS
 SELECT c.id,
    c.code,
    c.container_number,
    c.vessel,
    c.voyage,
    c.departure_date,
    c.bl_number,
    c.lane_id,
    c.forwarder_id,
    f.legal_name AS forwarder_name,
    (( SELECT count(*) AS count
           FROM shipments s
          WHERE s.container_id = c.id))::integer AS shipment_count,
    (( SELECT count(DISTINCT o.customer_id) AS count
           FROM shipments s
             JOIN sales_orders o ON o.id = s.sales_order_id
          WHERE s.container_id = c.id))::integer AS customer_count,
    ( SELECT m.milestone
           FROM container_milestones m
          WHERE m.container_id = c.id
          ORDER BY m.event_date DESC, m.recorded_at DESC
         LIMIT 1) AS latest_milestone,
    ( SELECT m.event_date
           FROM container_milestones m
          WHERE m.container_id = c.id
          ORDER BY m.event_date DESC, m.recorded_at DESC
         LIMIT 1) AS latest_milestone_date,
    COALESCE(ls.checklist_state, 'no_lane'::text) AS lane_checklist_state,
    (( SELECT count(*) AS count
           FROM container_documents d
          WHERE d.container_id = c.id AND d.status = 'pending'::text))::integer AS documents_pending
   FROM containers c
     LEFT JOIN suppliers f ON f.id = c.forwarder_id
     LEFT JOIN lane_checklist_status ls ON ls.lane_id = c.lane_id
  WHERE c.deleted_at IS NULL AND (( SELECT has_permission('module.logistics.view'::text) AS has_permission));

COMMENT ON VIEW public.container_overview IS
    'LOG-2a:箱子一行 —— 发货单数、涉及几个客户、最新里程碑、清单状态、待收单据数。
【lane_checklist_state 原样带着三种状态】(not_defined / defined_empty / defined,外加没挂航段的 no_lane):
把 not_defined 折叠成"0 条待收",就是把"没人看过"显示成"齐了"。
【属主权限,不是 invoker(LOG-2a-fu1)】:它跨 purchasing + sales + suppliers 三个模块,
invoker 语义下一个只持 purchasing 的读者会【静默地少看到几条发货单】——
计数会小,而没有任何东西报错(OPS-14 那五处缺陷的形状)。
门写在视图体里那一句 has_permission(''module.logistics.view'')(GOLIVE-1:物流有自己的码,读者只认它);
has_permission 是 DEFINER、解析的是调用者,所以属主权限并不放宽模块边界。';

-- ════════════════════════════════════════════════════════════════════════════
-- 第 11 行 · 员工表单不清身份四列
-- ════════════════════════════════════════════════════════════════════════════

-- db/functions/save_employee.sql
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q8):员工表单的【一次】保存 —— 员工那一行与它的任职履历,【一笔事务】。
--   以前是两次请求(app/hr/employees/actions.ts:先写 employees,再另起一次请求写 employment_history,线上实测相隔 0.5–0.9 秒),
--   于是一次"入职"在审计记录里是两条("Employee added"与"Hired"),而第二次请求失败时履历会安静地缺一行。
--   与 1b-3 Q13 的 save_storage_location 同一个处置:修写的那一头 —— 一次调用,只写变了的。
-- 【参数】p_id 为空 = 新建(返回新员工的 id);否则编辑那一名(返回同一个 id)。
--   p_fields:表单写的那 25 列(app/hr/employees/actions.ts 的 readForm,去掉 effective_date 与 user_id)。没给的列按 NULL 写 ——
--   表单每一次都交齐。
--   p_history:要补的那一行履历(change_type、生效日、职位文本、部门、类型、状态、说明),为空就不补 —— 推断哪一种变动、
--   说明怎么写仍在页面那一侧(inferChangeType / describeChanges),这里只负责让它与员工那一行【同生共死】。
-- 【账号关联不在这里】那是另一个权限(action.manage_permissions)的另一次调用(set_user_employee_link,它自己一笔事务)——
--   Step 0 的 Q8 照建议:关联仍是它自己的那一次。
-- 【SECURITY INVOKER】按调用者的身份跑:employees / employment_history 的读写策略与守卫(module.hr.edit;月薪只经
--   set_initial_salary,guard_employee_salary_write)照常管 —— 这支函数不放宽任何东西,它只把两次写入装进一笔。
--   ★ 但一开头先 require_permission('module.hr.edit'):被 RLS 的 USING 挡住的 UPDATE 不报错,它是一次【成功的空操作】
--     (AGENTS.md「写那一半更坏」)—— 不先问,一个没有编辑权的人点保存会得到一句"保存成功"。
-- 【一列都没变就不留痕】不在这里逐列比旧值:那要读几列被遮蔽的列(证件号、工作邮箱、月薪 —— 列级 SELECT 授权里没有它们),
--   调用者身份下读不得(实测 42501);而变更记录的触发器本来就不为"改了等于没改"写行(fixture 234 A3)—— 同一个结果,不多读一列。
-- ★ GOLIVE-1 第 11 行(Tim 2026-10-23 TABLE-EXPORT-2b Q5 · 2026-10-29 Q8):看不见身份四列的人保存,那四列【原样不动】。
--   work_email · work_phone · identity_no · work_pass_no 在 employees_masked 里按 data.view_identity(或这一行就是读者本人)遮;
--   编辑页对这样的人画「受限」、不送值 —— 而这里不看表单送了什么:看不见的人(编辑别人)那一次 UPDATE 根本不写那四列。
--   【为什么是两句 UPDATE 而不是 SET col = CASE … ELSE e.col】后者要读那一列,而那四列不在 authenticated 的列级 SELECT 里(42501);
--   只写一句、按看不看得见挑列,一次保存仍是一行变更记录。新建(p_id 为空)不变:还没有存下的值可遮,新建页照常可填(Q8)。
CREATE OR REPLACE FUNCTION public.save_employee(p_id uuid, p_fields jsonb, p_history jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    f    employees%ROWTYPE;
    v_id uuid := p_id;
BEGIN
    PERFORM require_permission('module.hr.edit');
    IF p_fields IS NULL OR jsonb_typeof(p_fields) <> 'object' THEN
        RAISE EXCEPTION 'EMPLOYEE_FIELDS_REQUIRED';
    END IF;
    f := jsonb_populate_record(NULL::employees, p_fields);
    IF v_id IS NULL THEN
        INSERT INTO employees (legal_name, first_name, last_name, preferred_name, department_id, position_id, manager_id,
                               employment_type, work_category, is_site_staff, hire_date, probation_end_date, employment_status,
                               separation_date, separation_type, separation_notes, work_email, work_phone, residency_status,
                               identity_no, work_pass_type, work_pass_no, work_pass_issue_date, work_pass_expiry_date, notes)
        VALUES (f.legal_name, f.first_name, f.last_name, f.preferred_name, f.department_id, f.position_id, f.manager_id,
                f.employment_type, f.work_category, COALESCE(f.is_site_staff, false), f.hire_date, f.probation_end_date, f.employment_status,
                f.separation_date, f.separation_type, f.separation_notes, f.work_email, f.work_phone, f.residency_status,
                f.identity_no, f.work_pass_type, f.work_pass_no, f.work_pass_issue_date, f.work_pass_expiry_date, f.notes)
        RETURNING id INTO v_id;
    ELSIF NOT (has_permission('data.view_identity') OR v_id IS NOT DISTINCT FROM current_user_employee()) THEN
        -- 看不见身份四列:那四列不在这一句里(GOLIVE-1 第 11 行)
        UPDATE employees e SET
               (legal_name, first_name, last_name, preferred_name, department_id, position_id, manager_id,
                employment_type, work_category, is_site_staff, hire_date, probation_end_date, employment_status,
                separation_date, separation_type, separation_notes, residency_status,
                work_pass_type, work_pass_issue_date, work_pass_expiry_date, notes)
             = (f.legal_name, f.first_name, f.last_name, f.preferred_name, f.department_id, f.position_id, f.manager_id,
                f.employment_type, f.work_category, COALESCE(f.is_site_staff, false), f.hire_date, f.probation_end_date, f.employment_status,
                f.separation_date, f.separation_type, f.separation_notes, f.residency_status,
                f.work_pass_type, f.work_pass_issue_date, f.work_pass_expiry_date, f.notes)
         WHERE e.id = v_id;
        IF NOT FOUND AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.id = v_id AND e.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', v_id;
        END IF;
    ELSE
        UPDATE employees e SET
               (legal_name, first_name, last_name, preferred_name, department_id, position_id, manager_id,
                employment_type, work_category, is_site_staff, hire_date, probation_end_date, employment_status,
                separation_date, separation_type, separation_notes, work_email, work_phone, residency_status,
                identity_no, work_pass_type, work_pass_no, work_pass_issue_date, work_pass_expiry_date, notes)
             = (f.legal_name, f.first_name, f.last_name, f.preferred_name, f.department_id, f.position_id, f.manager_id,
                f.employment_type, f.work_category, COALESCE(f.is_site_staff, false), f.hire_date, f.probation_end_date, f.employment_status,
                f.separation_date, f.separation_type, f.separation_notes, f.work_email, f.work_phone, f.residency_status,
                f.identity_no, f.work_pass_type, f.work_pass_no, f.work_pass_issue_date, f.work_pass_expiry_date, f.notes)
         WHERE e.id = v_id;
        IF NOT FOUND AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.id = v_id AND e.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', v_id;
        END IF;
    END IF;
    IF p_history IS NOT NULL AND jsonb_typeof(p_history) = 'object' THEN
        INSERT INTO employment_history (employee_id, effective_date, change_type, job_title, department_id,
                                        employment_type, employment_status, notes)
        VALUES (v_id, NULLIF(p_history ->> 'effective_date', '')::date, p_history ->> 'change_type', p_history ->> 'job_title',
                NULLIF(p_history ->> 'department_id', '')::uuid, p_history ->> 'employment_type', p_history ->> 'employment_status',
                NULLIF(p_history ->> 'notes', ''));
    END IF;
    RETURN v_id;
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 第 12 行 · 结算与合同条款上的价格:列级遮蔽 + 伴生视图 + 变更记录规则
-- ════════════════════════════════════════════════════════════════════════════

-- db/functions/contract_terms_price_visible.sql
-- GOLIVE-1 第 12 行(Tim 2026-10-25 TABLE-EXPORT-3c Q3 · 2026-10-29 Q9):一份合同条款上的【价格数字】对当前读者看不看得见 ——
--   按合同的【那一侧】:
--     客户合同(customer_id 不空)→ data.view_prices        (销售那一侧的价格)
--     供应商合同(supplier_id 不空)→ data.view_purchase_prices(采购那一侧;那个码的说明里写着「committed terms」)
--   合同不存在 / 两边都空 → false(关着失败)。
-- 【单独一支,不内联】四张条款视图(contract_*_masked)与变更记录的遮蔽规则(change_log_rule_visible 的 contract_price)问的是同一句话 ——
--   与 pricing_formula_terms_visible 同一个理由:内联就是五份判据。
-- 【SECURITY DEFINER】它要读 contracts 的那一侧,而那一行对读者的行级策略是另一回事(读者在别处问的是"这一行看不看得见");
--   返回的只是一个布尔,而且 has_permission() 解析的始终是【调用者】。anon 不可执行。
CREATE OR REPLACE FUNCTION public.contract_terms_price_visible(p_contract_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE((SELECT CASE WHEN c.customer_id IS NOT NULL THEN has_permission('data.view_prices')
                                 WHEN c.supplier_id IS NOT NULL THEN has_permission('data.view_purchase_prices')
                                 ELSE false END
                       FROM contracts c WHERE c.id = p_contract_id), false);
$function$;

REVOKE EXECUTE ON FUNCTION public.contract_terms_price_visible(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.contract_terms_price_visible(uuid) TO authenticated, service_role;

REVOKE SELECT ON public.sales_settlements FROM authenticated, anon;
GRANT SELECT (id, sales_order_id, output_batch_id, assay_result_id, settling_party_used, weight_basis_used, gross_weight_kg, moisture_pct, settlement_weight_kg, superseded_by, computed_at, computed_by) ON public.sales_settlements TO authenticated;
REVOKE SELECT ON public.contract_pricing_terms FROM authenticated, anon;
GRANT SELECT (id, contract_id, metal, base_event, qp_months, index_code, notes, created_at, created_by, updated_at, updated_by) ON public.contract_pricing_terms TO authenticated;
REVOKE SELECT ON public.contract_refining_charges FROM authenticated, anon;
GRANT SELECT (id, contract_id, metal, notes, created_at, created_by, updated_at, updated_by) ON public.contract_refining_charges TO authenticated;
REVOKE SELECT ON public.contract_penalty_elements FROM authenticated, anon;
GRANT SELECT (id, contract_id, substance, threshold_pct, notes, created_at, created_by, updated_at, updated_by) ON public.contract_penalty_elements TO authenticated;
REVOKE SELECT ON public.contract_insurance_obligations FROM authenticated, anon;
GRANT SELECT (id, contract_id, insured_by, cover_type, currency, notes, created_at, created_by, updated_at, updated_by) ON public.contract_insurance_obligations TO authenticated;

CREATE VIEW public.sales_settlements_masked WITH (security_invoker = off) AS
 SELECT
    id,
    sales_order_id,
    output_batch_id,
    assay_result_id,
    settling_party_used,
    weight_basis_used,
    gross_weight_kg,
    moisture_pct,
    settlement_weight_kg,
        CASE
            WHEN ( SELECT has_permission('data.view_prices'::text) AS has_permission) THEN metal_value_usd
            ELSE NULL::numeric
        END AS metal_value_usd,
        CASE
            WHEN ( SELECT has_permission('data.view_prices'::text) AS has_permission) THEN refining_charge_usd
            ELSE NULL::numeric
        END AS refining_charge_usd,
        CASE
            WHEN ( SELECT has_permission('data.view_prices'::text) AS has_permission) THEN penalty_usd
            ELSE NULL::numeric
        END AS penalty_usd,
        CASE
            WHEN ( SELECT has_permission('data.view_prices'::text) AS has_permission) THEN amount_usd
            ELSE NULL::numeric
        END AS amount_usd,
        CASE
            WHEN ( SELECT has_permission('data.view_prices'::text) AS has_permission) THEN breakdown
            ELSE NULL::jsonb
        END AS breakdown,
        CASE
            WHEN ( SELECT has_permission('data.view_prices'::text) AS has_permission) THEN terms_snapshot
            ELSE NULL::jsonb
        END AS terms_snapshot,
    superseded_by,
    computed_at,
    computed_by
   FROM sales_settlements
  WHERE ( SELECT has_permission('module.customers.view'::text) AS has_permission);

REVOKE ALL ON public.sales_settlements_masked FROM authenticated, anon;
GRANT SELECT ON public.sales_settlements_masked TO authenticated;

CREATE VIEW public.contract_pricing_terms_masked WITH (security_invoker = off) AS
 SELECT
    t.id,
    t.contract_id,
    t.metal,
    t.base_event,
    t.qp_months,
    t.index_code,
        CASE
            WHEN contract_terms_price_visible(t.contract_id) THEN t.payable_pct
            ELSE NULL::numeric
        END AS payable_pct,
    t.notes,
    t.created_at,
    t.created_by,
    t.updated_at,
    t.updated_by
   FROM contract_pricing_terms t
     JOIN contracts c ON c.id = t.contract_id
  WHERE (c.customer_id IS NOT NULL AND ( SELECT has_permission('module.customers.view'::text) AS has_permission))
     OR (c.supplier_id IS NOT NULL AND ( SELECT has_permission('module.suppliers.view'::text) AS has_permission));

REVOKE ALL ON public.contract_pricing_terms_masked FROM authenticated, anon;
GRANT SELECT ON public.contract_pricing_terms_masked TO authenticated;

CREATE VIEW public.contract_refining_charges_masked WITH (security_invoker = off) AS
 SELECT
    t.id,
    t.contract_id,
    t.metal,
        CASE
            WHEN contract_terms_price_visible(t.contract_id) THEN t.usd_per_tonne_of_metal
            ELSE NULL::numeric
        END AS usd_per_tonne_of_metal,
    t.notes,
    t.created_at,
    t.created_by,
    t.updated_at,
    t.updated_by
   FROM contract_refining_charges t
     JOIN contracts c ON c.id = t.contract_id
  WHERE (c.customer_id IS NOT NULL AND ( SELECT has_permission('module.customers.view'::text) AS has_permission))
     OR (c.supplier_id IS NOT NULL AND ( SELECT has_permission('module.suppliers.view'::text) AS has_permission));

REVOKE ALL ON public.contract_refining_charges_masked FROM authenticated, anon;
GRANT SELECT ON public.contract_refining_charges_masked TO authenticated;

CREATE VIEW public.contract_penalty_elements_masked WITH (security_invoker = off) AS
 SELECT
    t.id,
    t.contract_id,
    t.substance,
    t.threshold_pct,
        CASE
            WHEN contract_terms_price_visible(t.contract_id) THEN t.usd_per_tonne_per_pct_over
            ELSE NULL::numeric
        END AS usd_per_tonne_per_pct_over,
    t.notes,
    t.created_at,
    t.created_by,
    t.updated_at,
    t.updated_by
   FROM contract_penalty_elements t
     JOIN contracts c ON c.id = t.contract_id
  WHERE (c.customer_id IS NOT NULL AND ( SELECT has_permission('module.customers.view'::text) AS has_permission))
     OR (c.supplier_id IS NOT NULL AND ( SELECT has_permission('module.suppliers.view'::text) AS has_permission));

REVOKE ALL ON public.contract_penalty_elements_masked FROM authenticated, anon;
GRANT SELECT ON public.contract_penalty_elements_masked TO authenticated;

CREATE VIEW public.contract_insurance_obligations_masked WITH (security_invoker = off) AS
 SELECT
    t.id,
    t.contract_id,
    t.insured_by,
    t.cover_type,
        CASE
            WHEN contract_terms_price_visible(t.contract_id) THEN t.min_amount
            ELSE NULL::numeric
        END AS min_amount,
    t.currency,
    t.notes,
    t.created_at,
    t.created_by,
    t.updated_at,
    t.updated_by
   FROM contract_insurance_obligations t
     JOIN contracts c ON c.id = t.contract_id
  WHERE (c.customer_id IS NOT NULL AND ( SELECT has_permission('module.customers.view'::text) AS has_permission))
     OR (c.supplier_id IS NOT NULL AND ( SELECT has_permission('module.suppliers.view'::text) AS has_permission));

REVOKE ALL ON public.contract_insurance_obligations_masked FROM authenticated, anon;
GRANT SELECT ON public.contract_insurance_obligations_masked TO authenticated;


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
--   contract_price               contract_terms_price_visible(这一行的 contract_id)—— 合同那一侧的价格码(GOLIVE-1 第 12 行,Q9)
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
-- ★ GOLIVE-1(2026-10-29,第 12 行,Tim TABLE-EXPORT-3c Q3 · Q9)加了 10 行:结算的六列钱(sales_settlements_masked,data.view_prices)与
--   四张合同条款表上的价格(contract_*_masked,contract_price —— 客户合同问 data.view_prices、供应商合同问 data.view_purchase_prices)。
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
        ('sales_records', 'price_provenance', 'code:data.view_prices'),
        ('sales_settlements', 'metal_value_usd', 'code:data.view_prices'),
        ('sales_settlements', 'refining_charge_usd', 'code:data.view_prices'),
        ('sales_settlements', 'penalty_usd', 'code:data.view_prices'),
        ('sales_settlements', 'amount_usd', 'code:data.view_prices'),
        ('sales_settlements', 'breakdown', 'code:data.view_prices'),
        ('sales_settlements', 'terms_snapshot', 'code:data.view_prices'),
        ('contract_pricing_terms', 'payable_pct', 'contract_price'),
        ('contract_refining_charges', 'usd_per_tonne_of_metal', 'contract_price'),
        ('contract_penalty_elements', 'usd_per_tonne_per_pct_over', 'contract_price'),
        ('contract_insurance_obligations', 'min_amount', 'contract_price');
$function$;

-- db/functions/change_log_rule_visible.sql
-- HISTORY-1:一条遮蔽规则(change_log_mask_rules)对【当前读者】、就【这一行记录】成不成立。
-- 与 _masked 视图里那句 CASE WHEN 逐条同一个判据;认不出的规则按【看不见】答(关着失败)。
-- ★ U1-A(UNBLOCK-1,2026-10-05)两种新写法,各自与它那张 _masked 视图里的 CASE 同一个判据:
--   pay_journal:<码>   持码,或这一行所在分录(entry_id → journal_entries.source_type)不是 'payroll'(journal_lines_masked)。
--                       分录找不到 → 看不见(关着失败;分录不可删,所以这只在影像里根本没有 entry_id 时发生)。
--   apr_amount         approval_log_amount_visible(subject_type, subject_id) —— 视图与这里调同一支函数(approval_log_masked)。
-- ★ U1-B(2026-10-05)两种新写法,同一个道理:
--   apr_note           approval_log_note_visible(subject_type, subject_id)(approval_log_masked 的 note;医疗报销的说明是健康的字)。
--   jr_amount          journal_request_amount_visible(这一行的 id)(journal_requests_masked;工资分录的冲销申请要 data.view_pay)。
-- ★ MES-1(2026-10-06,Q20)一种新写法:
--   never              谁都看不见(gateway_keys_masked 里那一列恒为空)。它与"认不出的规则"答的是同一个 false,
--                       而它在这里点名写出来 —— 一条只因为认不出才成立的规则,是一份只写在注释里的契约。
-- ★ GOLIVE-1(2026-10-29,第 12 行)一种新写法:
--   contract_price     contract_terms_price_visible(这一行的 contract_id)—— 与四张 contract_*_masked 视图里的 CASE 调同一支函数。
CREATE OR REPLACE FUNCTION public.change_log_rule_visible(p_rule text, p_table text, p_key jsonb, p_old jsonb, p_new jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_part text[] := string_to_array(p_rule, ':');
    v_fid  text;
BEGIN
    IF p_rule = 'never' THEN
        RETURN false;
    ELSIF v_part[1] = 'code' THEN
        RETURN has_permission(v_part[2]);
    ELSIF v_part[1] = 'code_or_self' THEN
        RETURN has_permission(v_part[2])
            OR COALESCE(change_log_field(p_table, p_key, p_old, p_new, v_part[3]) = current_user_employee()::text, false);
    ELSIF v_part[1] = 'pay_journal' THEN
        RETURN has_permission(v_part[2])
            OR COALESCE(change_log_field('journal_entries',
                            jsonb_build_object('id', change_log_field(p_table, p_key, p_old, p_new, 'entry_id')),
                            NULL, NULL, 'source_type') <> 'payroll', false);
    ELSIF p_rule = 'apr_amount' THEN
        RETURN COALESCE(approval_log_amount_visible(change_log_field(p_table, p_key, p_old, p_new, 'subject_type'),
                                                    change_log_field(p_table, p_key, p_old, p_new, 'subject_id')::uuid), false);
    ELSIF p_rule = 'apr_note' THEN
        RETURN COALESCE(approval_log_note_visible(change_log_field(p_table, p_key, p_old, p_new, 'subject_type'),
                                                  change_log_field(p_table, p_key, p_old, p_new, 'subject_id')::uuid), false);
    ELSIF p_rule = 'contract_price' THEN
        RETURN COALESCE(contract_terms_price_visible(change_log_field(p_table, p_key, p_old, p_new, 'contract_id')::uuid), false);
    ELSIF p_rule = 'jr_amount' THEN
        RETURN COALESCE(journal_request_amount_visible(change_log_field(p_table, p_key, p_old, p_new, 'id')::uuid), false);
    ELSIF p_rule = 'pft:direction' THEN
        RETURN pricing_formula_terms_visible(change_log_field(p_table, p_key, p_old, p_new, 'direction'));
    ELSIF p_rule IN ('pft:formula_id', 'pft3') THEN
        v_fid := change_log_field(p_table, p_key, p_old, p_new, 'formula_id');
        IF NOT pricing_formula_terms_visible(
               change_log_field('pricing_formulas', jsonb_build_object('id', v_fid), NULL, NULL, 'direction')) THEN
            RETURN false;
        END IF;
        IF p_rule = 'pft:formula_id' THEN
            RETURN true;
        END IF;
        RETURN pricing_formula_terms_visible(COALESCE(change_log_field(p_table, p_key, p_old, p_new, 'old_direction'), 'both'))
           AND pricing_formula_terms_visible(COALESCE(change_log_field(p_table, p_key, p_old, p_new, 'new_direction'), 'both'));
    END IF;
    RETURN false;
END;
$function$;

-- db/functions/list_totals_settlements.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/contracts 上「已记录的结算」那张表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/contracts/page.tsx:112-116 同一套:sales_settlements,superseded_by IS NULL(没有地址栏筛选)。
-- 【合计】amount(amount_usd)。currency 给 NULL:这一列固定是美元,列头(contracts.settlement.colAmount)写着 USD。
-- 【净额】被改记的结算由 superseded_by 指向新的那一条,旧的不在集合里 —— 每一笔结算只算它当前的那一次。
-- 【门】require_permission('module.suppliers.view') —— 与页面守卫(requireModule(MOD.suppliers))同一个码。invoker。
-- 【受限】整个读者:NOT has_permission('module.customers.view')。页面的门是 suppliers.view,而这张表的读策略要
--   customers.view(sales_settlements.sql:90-92)—— 不持它的读者读到【零行】,而那不是「没有结算」。
--   所以那时回一行 restricted(currency NULL,total NULL),不回零行。
-- ★ GOLIVE-1 第 12 行(Tim Q9):结算金额从此按 data.view_prices 遮 —— amount_usd 不在 authenticated 的列级 SELECT 里,
--   这里改读 sales_settlements_masked;不持 data.view_prices 的读者同样回一行 restricted(屏幕上那一列是「受限」,表尾不许是一个数)。
CREATE OR REPLACE FUNCTION public.list_totals_settlements()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.suppliers.view');
    IF NOT has_permission('module.customers.view') OR NOT has_permission('data.view_prices') THEN
        RETURN QUERY SELECT ''::text, NULL::text, 'amount'::text, NULL::numeric, true;
        RETURN;
    END IF;
    RETURN QUERY
    SELECT ''::text, NULL::text, 'amount'::text, round(sum(ss.amount_usd), 2), false
      FROM sales_settlements_masked ss
     WHERE ss.superseded_by IS NULL
    HAVING count(*) > 0;
END;
$function$;

-- ── 事务内自证:任何一条不成立,整支回滚 ────────────────────────────────────
DO $proof$
DECLARE v text; n int;
BEGIN
    SELECT string_agg(code, ',' ORDER BY code) INTO v FROM public.roles;
    IF v IS DISTINCT FROM 'admin,auditor,cco,cfo,cto,employee,finance,floor_display,gm,operations,warehouse' THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF roles: %', v;
    END IF;
    SELECT count(*) INTO n FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code = 'auditor';
    IF n <> 25 OR EXISTS (SELECT 1 FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
                           WHERE r.code = 'auditor' AND (rp.permission_code NOT LIKE '%.view%' OR rp.permission_code IN
                                 ('data.view_banking', 'data.view_pay', 'data.view_identity', 'data.view_health', 'data.view_reviews'))) THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF auditor: % codes', n;
    END IF;
    IF (SELECT count(*) FROM public.permissions WHERE code LIKE 'module.%.view'
          AND code NOT IN (SELECT rp.permission_code FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code = 'auditor')) <> 0 THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF auditor lacks a module view code';
    END IF;
    IF EXISTS (SELECT 1 FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code = 'employee') THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF employee holds a code';
    END IF;
    SELECT count(*) INTO n FROM pg_policies WHERE schemaname = 'public' AND cmd = 'SELECT'
       AND tablename IN ('metal_prices', 'index_market_calendar', 'pricing_settings') AND qual LIKE '%action.metal_prices%';
    IF n <> 3 THEN RAISE EXCEPTION 'GOLIVE1_PROOF metal read policies: % of 3', n; END IF;
    IF pg_get_viewdef('public.container_overview'::regclass) LIKE '%purchasing%'
       OR pg_get_viewdef('public.container_overview'::regclass) NOT LIKE '%module.logistics.view%'
       OR NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'public.container_overview'::regclass AND 'security_invoker=off' = ANY (reloptions)) THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF container_overview';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.suppliers'::regclass AND tgname = 'trg_suppliers_zz_requeue_on_identity_change') THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF requeue trigger';
    END IF;
    IF has_column_privilege('authenticated', 'public.sales_settlements', 'amount_usd', 'SELECT')
       OR has_column_privilege('authenticated', 'public.contract_refining_charges', 'usd_per_tonne_of_metal', 'SELECT')
       OR has_column_privilege('authenticated', 'public.contract_penalty_elements', 'usd_per_tonne_per_pct_over', 'SELECT')
       OR has_column_privilege('authenticated', 'public.contract_insurance_obligations', 'min_amount', 'SELECT')
       OR has_column_privilege('authenticated', 'public.contract_pricing_terms', 'payable_pct', 'SELECT')
       OR NOT has_column_privilege('authenticated', 'public.sales_settlements', 'sales_order_id', 'SELECT')
       OR has_table_privilege('anon', 'public.sales_settlements', 'SELECT') THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF column grants';
    END IF;
    SELECT count(*) INTO n FROM change_log_mask_rules();
    IF n <> 129 THEN RAISE EXCEPTION 'GOLIVE1_PROOF mask rules: %', n; END IF;
    IF jsonb_array_length(change_log_mask_gaps() -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF mask gaps: %', change_log_mask_gaps();
    END IF;
    RAISE NOTICE 'GOLIVE1_PROOF ok';
END
$proof$;

SELECT 'PROOF|clock migration end|' || clock_timestamp();
SELECT 'PROOF|A|postgres|' || json_build_object(
  'roles', (SELECT string_agg(r.code || ':' || (SELECT count(*) FROM public.user_roles ur WHERE ur.role_id = r.id AND ur.revoked_at IS NULL) || 'h/'
                              || (SELECT count(*) FROM public.role_permissions rp WHERE rp.role_id = r.id) || 'c', ' ' ORDER BY r.code) FROM public.roles r),
  'held_hr_proc_sales_incl_revoked', (SELECT count(*) FROM public.user_roles ur JOIN public.roles r ON r.id = ur.role_id WHERE r.code IN ('hr','procurement','sales')),
  'seven_grants', (SELECT count(*) || ' ' || md5(string_agg(r.code || '/' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code IN ('admin','cco','cfo','cto','finance','gm','warehouse')),
  'user_roles', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.user_roles t),
  'suppliers', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.suppliers t), 'employees', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.employees t), 'contracts', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contracts t),
  'sales_settlements', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.sales_settlements t), 'contract_pricing_terms', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contract_pricing_terms t),
  'contract_refining_charges', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contract_refining_charges t), 'contract_penalty_elements', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contract_penalty_elements t),
  'contract_insurance_obligations', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contract_insurance_obligations t),
  'cod_issues', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.cod_issues t), 'cods', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.certificates_of_destruction t),
  'anon_relations', (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r','v','m','p','f')
                       AND has_table_privilege('anon', c.oid, 'SELECT')),
  'anon_functions', (SELECT string_agg(p.proname, ',' ORDER BY p.proname) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND has_function_privilege('anon', p.oid, 'EXECUTE')),
  'auditor', (SELECT string_agg(rp.permission_code, ',' ORDER BY rp.permission_code) FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code = 'auditor'),
  'employee_desc', (SELECT left(description_en, 60) FROM public.roles WHERE code = 'employee'),
  'policies', (SELECT json_object_agg(tablename || ' / ' || policyname, qual ORDER BY tablename, policyname) FROM pg_policies
                WHERE schemaname = 'public' AND cmd = 'SELECT' AND tablename IN ('metal_prices', 'index_market_calendar', 'pricing_settings')),
  'container_overview_where', (SELECT substring(pg_get_viewdef('public.container_overview'::regclass) FROM 'WHERE .*$')),
  'price_columns_granted', (SELECT count(*) FROM (VALUES ('sales_settlements','amount_usd'), ('contract_refining_charges','usd_per_tonne_of_metal'),
                              ('contract_penalty_elements','usd_per_tonne_per_pct_over'), ('contract_insurance_obligations','min_amount'),
                              ('contract_pricing_terms','payable_pct')) x(t, col) WHERE has_column_privilege('authenticated', 'public.' || x.t, x.col, 'SELECT')),
  'status_history_trigger', (SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgrelid = 'public.suppliers'::regclass AND tgname = 'trg_suppliers_status_history'))::text;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|A|cfo|reads|' || json_build_object(
  'metal_prices', (SELECT count(*) FROM public.metal_prices), 'calendar', (SELECT count(*) FROM public.index_market_calendar),
  'pricing_settings', (SELECT count(*) FROM public.pricing_settings), 'container_overview', (SELECT count(*) FROM public.container_overview),
  'settlements', (SELECT count(*) FROM public.sales_settlements_masked), 'pricing_terms', (SELECT count(*) FROM public.contract_pricing_terms_masked),
  'refining', (SELECT count(*) FROM public.contract_refining_charges_masked), 'penalty', (SELECT count(*) FROM public.contract_penalty_elements_masked),
  'insurance', (SELECT count(*) FROM public.contract_insurance_obligations_masked))::text;
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"01ae00e4-306f-4527-8537-10291e4750c7","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|A|cco|reads|' || json_build_object(
  'metal_prices', (SELECT count(*) FROM public.metal_prices), 'calendar', (SELECT count(*) FROM public.index_market_calendar),
  'pricing_settings', (SELECT count(*) FROM public.pricing_settings), 'container_overview', (SELECT count(*) FROM public.container_overview),
  'settlements', (SELECT count(*) FROM public.sales_settlements_masked), 'pricing_terms', (SELECT count(*) FROM public.contract_pricing_terms_masked),
  'refining', (SELECT count(*) FROM public.contract_refining_charges_masked), 'penalty', (SELECT count(*) FROM public.contract_penalty_elements_masked),
  'insurance', (SELECT count(*) FROM public.contract_insurance_obligations_masked))::text;
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"c8116e6c-80db-4a16-be12-24fb6ce6859d","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|A|warehouse|reads|' || json_build_object(
  'metal_prices', (SELECT count(*) FROM public.metal_prices), 'calendar', (SELECT count(*) FROM public.index_market_calendar),
  'pricing_settings', (SELECT count(*) FROM public.pricing_settings), 'container_overview', (SELECT count(*) FROM public.container_overview),
  'settlements', (SELECT count(*) FROM public.sales_settlements_masked), 'pricing_terms', (SELECT count(*) FROM public.contract_pricing_terms_masked),
  'refining', (SELECT count(*) FROM public.contract_refining_charges_masked), 'penalty', (SELECT count(*) FROM public.contract_penalty_elements_masked),
  'insurance', (SELECT count(*) FROM public.contract_insurance_obligations_masked))::text;
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"476bf8c8-c248-4352-9a75-945bf52ca390","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|A|finance|reads|' || json_build_object(
  'metal_prices', (SELECT count(*) FROM public.metal_prices), 'calendar', (SELECT count(*) FROM public.index_market_calendar),
  'pricing_settings', (SELECT count(*) FROM public.pricing_settings), 'container_overview', (SELECT count(*) FROM public.container_overview),
  'settlements', (SELECT count(*) FROM public.sales_settlements_masked), 'pricing_terms', (SELECT count(*) FROM public.contract_pricing_terms_masked),
  'refining', (SELECT count(*) FROM public.contract_refining_charges_masked), 'penalty', (SELECT count(*) FROM public.contract_penalty_elements_masked),
  'insurance', (SELECT count(*) FROM public.contract_insurance_obligations_masked))::text;
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000601e","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|A|no-role|reads|' || json_build_object(
  'metal_prices', (SELECT count(*) FROM public.metal_prices), 'calendar', (SELECT count(*) FROM public.index_market_calendar),
  'pricing_settings', (SELECT count(*) FROM public.pricing_settings), 'container_overview', (SELECT count(*) FROM public.container_overview),
  'settlements', (SELECT count(*) FROM public.sales_settlements_masked), 'pricing_terms', (SELECT count(*) FROM public.contract_pricing_terms_masked),
  'refining', (SELECT count(*) FROM public.contract_refining_charges_masked), 'penalty', (SELECT count(*) FROM public.contract_penalty_elements_masked),
  'insurance', (SELECT count(*) FROM public.contract_insurance_obligations_masked))::text;
RESET ROLE;
SELECT 'PROOF|Q7|before|' || (SELECT json_build_object('code', code, 'status', status, 'approved_at', approved_at, 'legal_name', legal_name)::text
                                         FROM public.suppliers WHERE code = 'SUP-2026-0003');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"c8116e6c-80db-4a16-be12-24fb6ce6859d","role":"authenticated"}', true) \g /dev/null
UPDATE public.suppliers SET legal_name = legal_name || ' (GOLIVE-1 dry run)' WHERE code = 'SUP-2026-0003';
RESET ROLE;
SELECT 'PROOF|Q7|after|' || (SELECT json_build_object('code', code, 'status', status, 'approved_by', approved_by, 'approved_at', approved_at, 'legal_name', legal_name)::text
                                        FROM public.suppliers WHERE code = 'SUP-2026-0003')
       || ' · history ' || (SELECT count(*) FROM public.supplier_status_history h JOIN public.suppliers s ON s.id = h.supplier_id
                              WHERE s.code = 'SUP-2026-0003' AND h.from_status = 'approved' AND h.to_status = 'pending_review' AND h.changed_at = now());
SELECT 'PROOF|clock rollback|' || clock_timestamp();
ROLLBACK;

