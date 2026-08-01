-- db/migrations/2026-08-02-perm4-self-service.sql
-- Permissions cut 4:账号邀请、员工自助、以及销售看得见自己单子的修复。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【员工自助为什么必须是行级,不能是模块级】
--   给普通员工 module.hr.view,他就看得见【所有人】的档案与薪酬 —— 那恰好是反的。
--   自助的正确形状是:与本人相关的那一行(或那几行),与模块权限无关。
--   Postgres 把多条 PERMISSIVE 策略【或】起来,所以再加一条"这是我自己的行"的
--   策略,等于在不碰任何模块策略的前提下,精确地放开了一行。
--
-- 【本切最要紧的一处:遮蔽必须对"自己的行"让路】
--   cut 2b 把 payroll_lines 的五个金额藏在 data.view_pay 后面。可是一个员工
--   【没有】这个码,却必须看得见【自己的】工资 —— 不然自助页面上是一排「受限」,
--   等于把人自己的薪水对他本人藏起来。
--   所以遮蔽视图的两处都要加 "或者这是我自己的行":
--       行谓词  WHERE has_permission('module.hr.view') OR employee_id = current_user_employee()
--       列遮蔽  CASE WHEN has_permission('data.view_pay') OR employee_id = current_user_employee()
--   两处【必须同时加】。只加行谓词 → 看得见自己的行但金额是空的;
--   只加列遮蔽 → 行根本取不出来。这是本切唯一一个"遮蔽让路"的场合,
--   让多了就泄露所有人的工资,让少了就藏起本人的工资。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ============================================================================
-- B1. set_user_employee_link —— 修 cut 3 遗留的两段式写入
-- ============================================================================
-- cut 3 的界面用两条语句做关联(先清旧的、再设新的)。中间失败,账号就谁也不关联了。
-- 收进一个函数里,两次写入同生共死。
CREATE OR REPLACE FUNCTION public.set_user_employee_link(
    p_user_id uuid,
    p_employee_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_prev  uuid;
    v_owner uuid;
    v_code  text;
BEGIN
    PERFORM require_permission('action.manage_permissions');

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'USER_REQUIRED';
    END IF;

    -- 目标员工若已经绑在【别的】账号上,拒绝 —— employees.user_id 上的
    -- partial unique index 也会拦,但那样抛出来的是索引名,不是人话。
    IF p_employee_id IS NOT NULL THEN
        SELECT user_id, code INTO v_owner, v_code
        FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND';
        END IF;
        IF v_owner IS NOT NULL AND v_owner <> p_user_id THEN
            RAISE EXCEPTION 'EMPLOYEE_ALREADY_LINKED|%', v_code;
        END IF;
    END IF;

    SELECT id INTO v_prev FROM employees WHERE user_id = p_user_id;

    -- 解绑旧的 + 绑上新的。两条 UPDATE 在同一个函数体里,
    -- 任何一条失败整个调用回滚 —— 不会再出现"清掉了但没设上"的中间态。
    UPDATE employees SET user_id = NULL
    WHERE user_id = p_user_id
      AND (p_employee_id IS NULL OR id <> p_employee_id);

    IF p_employee_id IS NOT NULL THEN
        UPDATE employees SET user_id = p_user_id WHERE id = p_employee_id;
    END IF;

    RETURN jsonb_build_object(
        'user_id', p_user_id,
        'previous_employee_id', v_prev,
        'employee_id', p_employee_id
    );
END;
$function$;

-- ============================================================================
-- B2. 自助:行级放开
-- ============================================================================
-- 追加的 PERMISSIVE 策略,与既有模块策略【或】起来。模块策略一行都没动。
-- 判定一律经 current_user_employee():它是 SECURITY DEFINER,以属主身份读 employees,
-- 因此挂在 employees 上的策略再调它也不会递归。

CREATE POLICY "employees select own row"
    ON public.employees AS PERMISSIVE FOR SELECT TO authenticated
    USING (id = current_user_employee());

CREATE POLICY "payroll_lines select own rows"
    ON public.payroll_lines AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());

CREATE POLICY "training_records select own rows"
    ON public.training_records AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());

CREATE POLICY "employment_history select own rows"
    ON public.employment_history AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());

-- 【本切只放开这四张】。请假与绩效等到有那些表的时候再说,
-- 现在多开一张,日后就多一处要重新想清楚的地方。

-- ---------------------------------------------------------------- 遮蔽让路
-- payroll_lines_masked:行谓词与列遮蔽【同时】加上"或者这是我自己的行"。
CREATE OR REPLACE VIEW public.payroll_lines_masked WITH (security_invoker = off) AS
SELECT
    id,
    payroll_period_id,
    employee_id,
    CASE WHEN has_permission('data.view_pay') OR employee_id = current_user_employee()
         THEN gross_pay ELSE NULL END AS gross_pay,
    CASE WHEN has_permission('data.view_pay') OR employee_id = current_user_employee()
         THEN employer_cpf ELSE NULL END AS employer_cpf,
    CASE WHEN has_permission('data.view_pay') OR employee_id = current_user_employee()
         THEN employee_cpf ELSE NULL END AS employee_cpf,
    CASE WHEN has_permission('data.view_pay') OR employee_id = current_user_employee()
         THEN other_deductions ELSE NULL END AS other_deductions,
    CASE WHEN has_permission('data.view_pay') OR employee_id = current_user_employee()
         THEN net_pay ELSE NULL END AS net_pay,
    notes,
    created_at
FROM public.payroll_lines
WHERE has_permission('module.hr.view') OR employee_id = current_user_employee();

-- employees_masked:同理。身份证件号对【本人】可见 —— 那是他自己的证件号。
CREATE OR REPLACE VIEW public.employees_masked WITH (security_invoker = off) AS
SELECT
    id, code, legal_name, preferred_name, department_id, job_title, manager_id,
    employment_type, work_category, hire_date, probation_end_date, employment_status,
    separation_date, separation_type, separation_notes, annual_leave_days,
    CASE WHEN has_permission('data.view_identity') OR id = current_user_employee()
         THEN work_email ELSE NULL END AS work_email,
    CASE WHEN has_permission('data.view_identity') OR id = current_user_employee()
         THEN work_phone ELSE NULL END AS work_phone,
    residency_status,
    CASE WHEN has_permission('data.view_identity') OR id = current_user_employee()
         THEN identity_no ELSE NULL END AS identity_no,
    work_pass_type,
    CASE WHEN has_permission('data.view_identity') OR id = current_user_employee()
         THEN work_pass_no ELSE NULL END AS work_pass_no,
    work_pass_issue_date, work_pass_expiry_date,
    user_id, notes, deleted_at, created_at, created_by, updated_at, updated_by
FROM public.employees
WHERE has_permission('module.hr.view') OR id = current_user_employee();

-- ============================================================================
-- B3. my_profile —— 自助页面的那一行
-- ============================================================================
-- 属主权限 + 视图体里的 current_user_employee() 谓词,与既有遮蔽视图同一套做法。
-- 敏感列【照给】:这是这个人自己的数据。
-- 账号没有关联员工档案时,current_user_employee() 返回 NULL,这里自然是零行。
CREATE VIEW public.my_profile WITH (security_invoker = off) AS
SELECT
    e.id                AS employee_id,
    e.code,
    e.legal_name,
    e.preferred_name,
    e.job_title,
    e.employment_type,
    e.work_category,
    e.employment_status,
    e.hire_date,
    e.probation_end_date,
    e.annual_leave_days,
    e.residency_status,
    e.work_pass_type,
    e.work_pass_no,
    e.work_pass_issue_date,
    e.work_pass_expiry_date,
    e.identity_no,
    e.work_email,
    e.work_phone,
    d.name_en           AS department_name_en,
    d.name_zh           AS department_name_zh,
    mgr.legal_name      AS manager_name,
    mgr.code            AS manager_code,
    COALESCE(tr.cnt, 0) AS training_count,
    pp.code             AS latest_payroll_code,
    pp.period_month     AS latest_payroll_month
FROM public.employees e
LEFT JOIN public.departments d ON d.id = e.department_id
LEFT JOIN public.employees mgr ON mgr.id = e.manager_id
LEFT JOIN LATERAL (
    SELECT count(*) AS cnt FROM public.training_records t
    WHERE t.employee_id = e.id AND t.deleted_at IS NULL
) tr ON true
LEFT JOIN LATERAL (
    SELECT p.code, p.period_month
    FROM public.payroll_lines pl
    JOIN public.payroll_periods p ON p.id = pl.payroll_period_id
    WHERE pl.employee_id = e.id AND p.status = 'posted' AND p.deleted_at IS NULL
    ORDER BY p.period_month DESC
    LIMIT 1
) pp ON true
WHERE e.id = current_user_employee() AND e.deleted_at IS NULL;

GRANT SELECT ON public.my_profile TO authenticated;

-- ============================================================================
-- B4. 销售看得见自己的销售记录
-- ============================================================================
-- 【先查了线上授权,结果是必须引入一个更窄的权限】:
--   module.output.view 的持有者是 admin / gm / finance / auditor / sales /
--   【operations】/【warehouse】—— 后两个【没有】data.view_prices。
-- 也就是说,若按 module.output.view 放开这张视图,现场与运营会当场看见售价,
-- 而"现场不需要钱"正是 cut 4 之前刚刚立下的原则。所以不这么放。
--
-- 引入 data.view_sales:它比 data.view_prices 窄(只是产出批次的成交记录,
-- 不含采购成本、加工成本、计价公式),因此可以发给需要看销售盘子的岗位,
-- 而不必把整个成本面一起打开。
INSERT INTO permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('data.view_sales', 'data', 'View sales records', '查看销售记录',
     'Quantity, unit price, amount, customer and date of sales made from output batches',
     '产出批次的销售数量、单价、金额、客户与日期', 240);

-- 发给需要看销售盘子的岗位。【不给 warehouse,不给 operations】——
-- 他们持有 module.output.view 是为了发货与库存,不是为了知道卖了多少钱。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, 'data.view_sales' FROM roles r
WHERE r.code IN ('admin', 'gm', 'finance', 'sales', 'auditor');

-- 【范围取"团队全部",不取 created_by】。理由:
--   1. 销售是小团队,互相顶班是常态 —— 按 created_by 切,同事替你录一单,
--      那单就从你的视野里消失了,拼不出一个完整的盘子;
--   2. sales_records.created_by 记的是【谁调用了 record_output_sale】,
--      而实际发货时那多半是运营或仓储的人 —— 用它当"这单是谁的"本身就不准。
-- 于是这张视图是"持有权限的人看得见全部销售",而不是"看得见自己录的"。
CREATE VIEW public.sales_records_visible WITH (security_invoker = off) AS
SELECT
    sr.id,
    sr.output_batch_id,
    ob.code             AS output_batch_code,
    sr.customer_id,
    c.legal_name        AS customer_name,
    sr.quantity,
    sr.unit_price,
    sr.currency,
    sr.fx_rate,
    sr.amount_usd,
    sr.sale_date,
    sr.notes,
    sr.created_at,
    sr.created_by
FROM public.sales_records sr
LEFT JOIN public.output_batches ob ON ob.id = sr.output_batch_id
LEFT JOIN public.customers c ON c.id = sr.customer_id
WHERE has_permission('module.output.view') AND has_permission('data.view_sales');

GRANT SELECT ON public.sales_records_visible TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
