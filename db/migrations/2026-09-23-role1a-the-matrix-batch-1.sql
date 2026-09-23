-- db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql
-- ROLE-1 · Batch 1 —— Tim 的角色与审批矩阵(2026-09-23,docs/role-matrix.md)的第一批。
--
-- 【本批做什么】(Step 0 grilling 的 Q1–Q13,Tim 全部接受)
--   ① 五个新动作码:action.finance_reopen · action.approve_review · action.decide_hr_requests
--      · action.hr_reviews · action.anonymise_employee
--   ② 财务:重开已关的月、年结、重开年度 → action.finance_reopen(CFO);
--      手动锁那扇侧门(直连把 locked_before 往回搬过一个已关的月)→ 新守卫
--      guard_lock_reopen_path;加工成本分摊 → module.finance.edit(原 module.processing.edit);
--      采购质保金释放 → module.finance.edit(原 module.purchasing.edit)
--   ③ 人事拆开:KPI 与绩效评估 → action.hr_reviews(cco);其余人事与薪资仍是
--      module.hr.edit,改归 finance;请假与医疗申报的决定 → action.decide_hr_requests
--      (finance + cfo,Q4);批评估 → review_approval_code(CFO;CFO 是提交人或主角时 cco,Q5);
--      员工匿名化 → action.anonymise_employee(admin)
--   ④ R2 扩到请假,只对 CFO(Tim 自己的假自己批,标 self_decided)
--   ⑤ 月薪:直连写一律拒绝;第一份月薪走 set_initial_salary(finance,Q7);批量导入不许带月薪
--   ⑥ 授权:admin 只剩系统管理三码(Q8);cco 交出 manage_permissions / bulk_import /
--      hr.edit / view_identity;cto 交出 bulk_import / issue_cod / view_identity;finance 交出
--      bulk_import、接过人事;cfo 拿到本批要它做的决定与读那些决定要的只读码(Q3)
--   ⑦ employee_lookup 对 action.manage_permissions 放行(只有名字)—— admin 不再持
--      module.hr.view,/settings/accounts 仍要列出可关联的人
--
-- 【不做什么】Batch 2–5 与全部 [LC] —— 见 docs/forward-queue.md 与 docs/role-matrix.md。
-- 审批开关与策略一个字都不碰;审批角色(finance / cfo)与门槛不变。
--
-- 【RUNTIME CONFIG 的引导默认值,照 AGENTS.md 那条规矩说清楚】
--   · role_permissions 的引导默认值【改了】(admin 只剩三码;finance 接过人事)——
--     它说的仍是它原来的意思(全新安装的起点),而且更接近线上;cco / cto / cfo 三个角色
--     仍然不在引导里,那一条登记在 docs/known-issues.md(ROLE1-BOOTSTRAP-MISSING-ROLES)。
--   · permissions 是逐行比对的种子,新增五行、改一行描述,镜像同步。
--   · 本批【没有】改变任何 RUNTIME CONFIG 表里某一列的【含义】。
--
-- 【审批是开着的】本迁移一提交就在线上生效。最后那一段自证在同一笔事务里断言:
-- 开关仍开、在途单据一张不少、每一张在途单据都还有一个【不是它自己的当事人】的决定人。
-- 断言失败 = 整笔回滚,线上一个字都不变。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ('action.finance_reopen','action.approve_review',
               'action.decide_hr_requests','action.hr_reviews','action.anonymise_employee')) THEN
        RAISE EXCEPTION 'ROLE1_PRE|new codes already exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                    WHERE r.code = 'cco' AND rp.permission_code = 'action.manage_permissions') THEN
        RAISE EXCEPTION 'ROLE1_PRE|cco is expected to hold action.manage_permissions';
    END IF;
END;
$pre$;

-- 在途单据的"之前"读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE role1_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL;
CREATE TEMP TABLE role1_log_before ON COMMIT DROP AS SELECT count(*) AS n FROM approval_log;

-- ── 1 · 目录:五个新码,一行描述 ──────────────────────────────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.finance_reopen', 'action', 'Reopen closed months; close and reopen financial years', '重开已关的月;年结与重开年度', 'Reopen a closed month, close a financial year, reopen a closed financial year. Month-end close itself stays with Finance (edit).', '重开一个已关的月、年结、重开一个已结的年度。月结本身仍归「财务(编辑)」。', 930),
    ('action.approve_review', 'action', 'Approve performance reviews', '批准绩效评估', 'Approve a submitted performance review — which can change the person''s monthly salary. When the holder of this code is the review''s submitter or subject, the review is approved under "Performance reviews & KPI" instead.', '批准一张已提交的绩效评估 —— 它可以改变那个人的月薪。持有本码的人是这张评估的提交人或主角时,改由「绩效评估与 KPI」批准。', 940),
    ('action.decide_hr_requests', 'action', 'Decide leave requests and medical claims', '决定请假与医疗申报', 'Approve or reject leave requests and medical claims. Nobody decides their own, except the top approval level, whose own decisions are flagged.', '批准或驳回请假与医疗申报。没有人决定自己的单 —— 最高一级审批例外,每一次都被标记。', 950),
    ('action.hr_reviews', 'action', 'Performance reviews & KPI', '绩效评估与 KPI', 'Run the KPI and performance-review work: cycles, goals, scoring, reviewers, conclusions and the salary proposal. Does not include any other HR or payroll work.', '做 KPI 与绩效评估这一块:周期、目标、打分、评估人、结论与调薪建议。不含任何其他人事或薪资工作。', 960),
    ('action.anonymise_employee', 'action', 'Anonymise an employee record', '匿名化员工档案', 'Irreversibly anonymise a separated employee''s personal data. System administration only.', '不可逆地抹去一名离职员工的个人数据。仅限系统管理。', 970);

UPDATE public.permissions
   SET description_en = 'Employees, payroll, attendance, leave and training — create, change, remove. Not performance reviews or KPI (ROLE-1).',
       description_zh = '员工、薪资、考勤、假期与培训 —— 新建、修改、删除。不含绩效评估与 KPI(ROLE-1)。'
 WHERE code = 'module.hr.edit';

-- ── 2 · 函数 ────────────────────────────────────────────────────────────────
-- ─── review_approval_code
-- db/functions/review_approval_code.sql
-- ROLE-1(Tim 的矩阵,2026-09-23):一张绩效评估【要哪一个码才批得了】—— 唯一的定义。
--
-- 【规则,原样】绩效评估由 cco 做、CFO 批;Tim 自己的评估由 cco 批。
-- Step 0 的 grilling 量出来还有第二种情形:Choo Er 的上级(manager_id)是 Tim,
-- 所以她的评估是 Tim 以评估人身份【提交】的 —— 那时 CFO 是提交人,自批拒绝会挡住他。
-- 于是 Tim 的 Q5 裁定:**CFO 批;CFO 是提交人【或】主角时,cco 批。**
--
--   · 一般情形            → 'action.approve_review'(cfo 持有)
--   · CFO 是提交人或主角  → 'action.hr_reviews'   (cco 持有 —— 做评估的那个码)
--
-- "CFO" = finance_settings.approval_level2_role_code 那个角色的【真持有人】,按【人】认
-- (account_person —— Tim 的两个账号是一个人)。与 R2 的 self_approval_exception
-- 用同一个判据,不另写一份"谁是 CFO"。二级角色没设 → 一般情形。
--
-- 【两个读者】approve_review(门)与评估详情页(按钮可不可按、为什么)。
-- 一份定义两个读者 —— 页面【不】在 TypeScript 里重算这条规矩(AGENTS.md 的预览规则)。
--
-- 【永不返回 NULL】它的返回值直接喂给 require_permission;NULL 会变成一次
-- "谁都没有的码"的拒绝,读起来像权限问题,其实是这里写错了。
--
-- NOTE: introduced by db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql.

CREATE OR REPLACE FUNCTION public.review_approval_code(p_submitted_by uuid, p_employee_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN EXISTS (
                SELECT 1
                  FROM finance_settings fs
                 CROSS JOIN LATERAL real_role_holders(fs.approval_level2_role_code) h
                 WHERE fs.approval_level2_role_code IS NOT NULL
                   AND account_person(h.user_id) IS NOT NULL
                   AND (account_person(h.user_id) = p_employee_id
                        OR account_person(h.user_id) = account_person(p_submitted_by)))
           THEN 'action.hr_reviews'
           ELSE 'action.approve_review'
           END;
$function$;

COMMENT ON FUNCTION public.review_approval_code(uuid, uuid) IS
'ROLE-1(Tim 的矩阵 · Q5):批一张绩效评估要哪一个码 —— CFO(二级审批角色的真持有人,按人认)是提交人或主角时 action.hr_reviews(cco),否则 action.approve_review(cfo)。两个读者:approve_review 的门与评估详情页。永不返回 NULL。';

-- ─── period_close_floor
-- db/functions/period_close_floor.sql
-- ROLE-1(2026-09-23):【最早一个还在生效的关账之后的第一天】—— 锁定日往回搬时
-- 不能越过的那条线。没有生效中的关账 → NULL(没有线)。
--
-- 为什么单独一支、为什么 SECURITY DEFINER:读它的是 guard_lock_reopen_path,
-- 一支 INVOKER 触发器(它必须是 INVOKER,才能用 row_security_active 分出"直连写"与
-- "reopen_period 这类属主路径")。INVOKER 里直接读 period_closes 会受调用者的 RLS 约束 ——
-- 一个读不到 period_closes 的写入者会读到 0 行、线变成 NULL、闸空转。
-- **空集不是"没有关账"**(与 guard_finance_settings_sod 头上那句同一条)。
-- 所以这一次读以属主身份做。
-- ★ EXECUTE【不】从 authenticated 收回 —— 这是故意的:调它的是一支 INVOKER 触发器,
--   而 EXECUTE 按【当前用户】判(AGENTS.md「属主权限视图替得了表,替不了函数的 EXECUTE」)。
--   收回它,每一次手动锁都会撞上 42501。它只返回一个日期,那个日期在关账页上本来就看得见。
--
-- NOTE: introduced by db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql.

CREATE OR REPLACE FUNCTION public.period_close_floor()
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT MAX(period_end) + 1
      FROM period_closes
     WHERE reopened_at IS NULL;
$function$;

COMMENT ON FUNCTION public.period_close_floor() IS
'ROLE-1:最新一个仍生效的关账之后的第一天(没有 → NULL)。guard_lock_reopen_path 的判据:一次直连写把 locked_before 搬到它之前(或清空),就等于重开了一个已关的月。以属主身份读 period_closes。EXECUTE 故意【不】收回:调用它的是一支 INVOKER 触发器。';

-- ─── guard_lock_reopen_path
-- db/functions/guard_lock_reopen_path.sql
-- ROLE-1(Tim 的矩阵,2026-09-23):**重开已关的月只有 CFO 能做** —— 而此前有一扇侧门。
--
-- 【侧门】/finance/settings 的"手动锁"是对 finance_settings.locked_before 的一次直连
-- UPDATE,只要 module.finance.edit(RLS)。把它往回搬 —— 搬到一个已关的月之前,或者清空 ——
-- 效果与 reopen_period 一样(那个月又能过账了),却【不】在 period_closes 上盖重开戳、
-- 不要理由、也不经过 reopen_period 的门。guard_finance_settings_sod 只管【前进】的锁
-- (它的抬头写着"解锁不隐藏任何东西")—— 那句话管的是职责分离,不是【谁可以重开】。
--
-- 【规则】一次【直连】写(row_security_active = true),若把 locked_before 搬到
-- period_close_floor() 之前(或清空,而那条线存在),就拒绝:REOPEN_THROUGH_CLOSE_ONLY|<线-1>。
-- 往回搬但不越过那条线 —— 只是撤掉一次手动锁、没有重开任何已关的月 —— 照常放行:
-- 财务撤销自己的手动锁,不是一次"重开"。
--
-- 【为什么是 INVOKER】要分出"直连写"与属主路径(reopen_period 是 SECURITY DEFINER,
-- 它本身已要求 action.finance_reopen,并盖戳)。在 SECURITY DEFINER 里
-- row_security_active 答的是属主,永远 false —— 与 enforce_write_permission 同一个理由。
-- 线本身经 period_close_floor(属主身份)读,理由写在那支函数的抬头。
--
-- 【为什么不是"持 action.finance_reopen 就放行"】持那个码的 cfo 不持 module.finance.edit,
-- RLS 本来就不让它直连写这张表;而同时持两者的人今天不存在。给直连写开一条"有码就行"的
-- 路,等于给一条【不留戳】的重开路开门。重开只走 reopen_period。
--
-- NOTE: introduced by db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql.

CREATE OR REPLACE FUNCTION public.guard_lock_reopen_path()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_floor date;
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF NEW.locked_before IS NOT DISTINCT FROM OLD.locked_before THEN
        RETURN NEW;
    END IF;
    -- 只管往回搬(或清空)
    IF NEW.locked_before IS NOT NULL
       AND (OLD.locked_before IS NULL OR NEW.locked_before >= OLD.locked_before) THEN
        RETURN NEW;
    END IF;

    v_floor := period_close_floor();
    IF v_floor IS NOT NULL
       AND (NEW.locked_before IS NULL OR NEW.locked_before < v_floor) THEN
        RAISE EXCEPTION 'REOPEN_THROUGH_CLOSE_ONLY|%', to_char(v_floor - 1, 'YYYY-MM-DD');
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_lock_reopen_path() IS
'ROLE-1:一次直连写若把 finance_settings.locked_before 搬到最新生效关账之后第一天之前(或清空),拒绝 REOPEN_THROUGH_CLOSE_ONLY —— 重开已关的月只走 reopen_period(action.finance_reopen,CFO),那条路盖戳、要理由。不越线的回搬(撤销一次手动锁)照常放行。INVOKER,以分出直连写与属主路径。';

-- ─── set_initial_salary
-- db/functions/set_initial_salary.sql
-- ROLE-1(Tim 的矩阵 · Q7,2026-09-23):**一个人的第一份月薪,由财务录一次。**
--
-- 【规则,原样】调薪只走绩效评估或调薪申请(申请那一条是 [LC],未建),由 CFO 批;
-- 对 employees.monthly_salary 的直连写一律拒绝(guard_employee_salary_write)。
-- Step 0 量出那条拒绝会造出一堵墙:线上 6 名员工的 monthly_salary【全是 NULL】,
-- 评估 0 张 —— 拒绝落地之后,就再也没有任何一条路能录下第一份工资。
-- 于是 Tim 的 Q7:**NULL → 数值只许一次,由财务录,记进 employment_history。**
-- 之后的每一次变动走评估或 [LC] 的调薪申请。
--
-- 【门】module.hr.edit(ROLE-1 起只有 finance 持有它)**且** data.view_pay ——
-- 一个看不见工资的人不该能写工资,理由与"看不见价格的人不能定价"同一条。
--
-- 【拒绝】
--   SALARY_ALREADY_SET|<code>                 已有月薪 —— 之后的变动不走这里
--   SALARY_EFFECTIVE_DATE_REQUIRED            生效日决定它落在哪个工资期:必填,不给默认
--   SALARY_EFFECTIVE_IN_POSTED_PERIOD|<期>    与 approve_review 同一条:已过账的工资期不追改
--   SALARY_AMOUNT_INVALID                     NULL 或负数
--   EMPLOYEE_NOT_FOUND / PDPA_ALREADY_ANONYMISED|<日> / EMPLOYEE_SEPARATED|<code>
--
-- 【它是属主路径】写 employees 与 employment_history 时 row_security_active = false,
-- 所以两支"直连写薪资"守卫放它过去 —— 那两支守卫拦的正是【绕过本函数】的写法。
--
-- NOTE: introduced by db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql.

CREATE OR REPLACE FUNCTION public.set_initial_salary(p_employee_id uuid, p_amount numeric, p_effective_date date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    employees%ROWTYPE;
    v_period text;
BEGIN
    PERFORM require_permission('module.hr.edit');
    PERFORM require_permission('data.view_pay');

    IF p_amount IS NULL OR p_amount < 0 THEN
        RAISE EXCEPTION 'SALARY_AMOUNT_INVALID';
    END IF;
    IF p_effective_date IS NULL THEN
        RAISE EXCEPTION 'SALARY_EFFECTIVE_DATE_REQUIRED';
    END IF;

    SELECT * INTO v_emp FROM employees
     WHERE id = p_employee_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
    IF v_emp.anonymised_at IS NOT NULL THEN
        RAISE EXCEPTION 'PDPA_ALREADY_ANONYMISED|%', v_emp.anonymised_at::date;
    END IF;
    IF v_emp.employment_status = 'separated' THEN
        RAISE EXCEPTION 'EMPLOYEE_SEPARATED|%', v_emp.code;
    END IF;
    IF v_emp.monthly_salary IS NOT NULL THEN
        RAISE EXCEPTION 'SALARY_ALREADY_SET|%', v_emp.code;
    END IF;

    -- 与 approve_review 逐字同一个问法:生效日落在一个已过账的工资期里 → 拒。
    SELECT p.code INTO v_period
      FROM payroll_periods p
     WHERE p.deleted_at IS NULL AND p.status = 'posted'
       AND p_effective_date >= p.period_month
       AND p_effective_date < (p.period_month + interval '1 month')::date
     ORDER BY p.period_month
     LIMIT 1;
    IF v_period IS NOT NULL THEN
        RAISE EXCEPTION 'SALARY_EFFECTIVE_IN_POSTED_PERIOD|%', v_period;
    END IF;

    UPDATE employees
       SET monthly_salary = p_amount, updated_by = auth.uid()
     WHERE id = v_emp.id;

    INSERT INTO employment_history
        (employee_id, effective_date, change_type, job_title, department_id,
         employment_type, employment_status, old_monthly_salary, new_monthly_salary, notes, created_by)
    SELECT e.id, p_effective_date, 'salary_change',
           (SELECT p.title FROM positions p WHERE p.id = e.position_id), e.department_id,
           e.employment_type, e.employment_status, NULL, p_amount,
           COALESCE(NULLIF(btrim(p_notes), ''), 'Initial monthly salary'),
           auth.uid()
      FROM employees e WHERE e.id = v_emp.id;

    RETURN jsonb_build_object(
        'employee_id', v_emp.id, 'employee_code', v_emp.code,
        'new_monthly_salary', p_amount, 'effective_date', p_effective_date);
END;
$function$;

COMMENT ON FUNCTION public.set_initial_salary(uuid, numeric, date, text) IS
'ROLE-1(Tim 的 Q7):一个人的第一份月薪 —— NULL → 数值只许一次,门是 module.hr.edit 且 data.view_pay(ROLE-1 起即 finance),记一行 employment_history salary_change(old = NULL)。已有月薪 → SALARY_ALREADY_SET;之后的变动走绩效评估或调薪申请([LC])。生效日必填,落在已过账工资期里拒绝。';

-- ─── guard_employee_salary_write
-- db/functions/guard_employee_salary_write.sql
-- ROLE-1(Tim 的矩阵,2026-09-23):**对 employees.monthly_salary 的直连写一律拒绝。**
--
-- 【洞】authenticated 对 employees 持表级 INSERT/UPDATE(含 monthly_salary 这一列;
-- ROLE-MATRIX-0 以 information_schema.column_privileges 实测),更新策略只问
-- module.hr.edit。屏幕上没有改月薪的栏位,但数据库接受 —— 包括改自己的。
-- 绩效评估那条"本人不能批自己的加薪"(APR-2)可以这样整个绕过去。
--
-- 【规则】一次【直连】写(row_security_active = true):
--   · INSERT 带一个非 NULL 的 monthly_salary → 拒;
--   · UPDATE 让 monthly_salary 变了 → 拒。
-- 拒绝码 SALARY_DIRECT_WRITE_REFUSED。合法的路都是属主路径,这支守卫看不见它们:
-- approve_review(评估批准)、set_initial_salary(第一份月薪,Q7)、
-- anonymise_employee(依法清空)。
--
-- 【为什么用触发器而不是收列权限】列级 GRANT 要在每次 ADD COLUMN 时记得扩 ——
-- 本仓库为 SELECT 那一份列清单已经付过四次账(AGENTS.md「masked table」一节)。
-- 触发器只认这一列,加列不用碰它。形状与 enforce_write_permission 相同:INVOKER +
-- row_security_active 分出直连写。
--
-- NOTE: introduced by db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql.

CREATE OR REPLACE FUNCTION public.guard_employee_salary_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' AND NEW.monthly_salary IS NOT NULL THEN
        RAISE EXCEPTION 'SALARY_DIRECT_WRITE_REFUSED';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.monthly_salary IS DISTINCT FROM OLD.monthly_salary THEN
        RAISE EXCEPTION 'SALARY_DIRECT_WRITE_REFUSED';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_employee_salary_write() IS
'ROLE-1:直连写 employees.monthly_salary(INSERT 带值,或 UPDATE 改了它)一律 SALARY_DIRECT_WRITE_REFUSED。合法的路是属主路径:approve_review、set_initial_salary、anonymise_employee。INVOKER + row_security_active,与 enforce_write_permission 同形。';

-- ─── guard_employment_history_salary_write
-- db/functions/guard_employment_history_salary_write.sql
-- ROLE-1(2026-09-23):guard_employee_salary_write 的另一半。
--
-- employment_history 的插入策略只问 module.hr.edit。一行直连插进来的 salary_change
-- (old_/new_monthly_salary)会在履历上留下一次【没有发生过】的调薪 —— 人读履历时
-- 无从分辨。调薪的留痕只该由写 monthly_salary 的那几条属主路径自己写
-- (approve_review、set_initial_salary),所以:
--
-- 【规则】一次【直连】INSERT(row_security_active = true)带非 NULL 的
-- old_monthly_salary 或 new_monthly_salary,或 change_type = 'salary_change' → 拒,
-- SALARY_DIRECT_WRITE_REFUSED。app 自己的两处插入(app/hr/employees/actions.ts
-- 入职与调岗)从不写这两列,不受影响。
--
-- UPDATE 不需要它:trg_employment_history_immutable 本来就不让改。
--
-- NOTE: introduced by db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql.

CREATE OR REPLACE FUNCTION public.guard_employment_history_salary_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF NEW.change_type = 'salary_change'
       OR NEW.old_monthly_salary IS NOT NULL
       OR NEW.new_monthly_salary IS NOT NULL THEN
        RAISE EXCEPTION 'SALARY_DIRECT_WRITE_REFUSED';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_employment_history_salary_write() IS
'ROLE-1:直连插入一行带薪资数字(或 change_type = salary_change)的履历,一律 SALARY_DIRECT_WRITE_REFUSED —— 调薪留痕只由写 monthly_salary 的属主路径自己写(approve_review、set_initial_salary)。';

-- ─── reopen_period
CREATE OR REPLACE FUNCTION public.reopen_period(p_period_end date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_close_id uuid;
    v_new_lock date;
BEGIN
    PERFORM require_permission('action.finance_reopen');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 与 close_period 同一把锁,串行化
    PERFORM 1 FROM finance_settings WHERE id FOR UPDATE;

    SELECT id INTO v_close_id
    FROM period_closes
    WHERE period_end = p_period_end AND reopened_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM period_closes WHERE period_end = p_period_end) THEN
            RAISE EXCEPTION 'ALREADY_REOPENED';
        END IF;
        RAISE EXCEPTION 'CLOSE_NOT_FOUND';
    END IF;

    UPDATE period_closes
    SET reopened_at = now(), reopened_by = auth.uid(), reopen_reason = btrim(p_reason)
    WHERE id = v_close_id;

    -- 更早的仍有效关账 → 其 period_end + 1;没有 → 解除锁定
    SELECT MAX(period_end) + 1 INTO v_new_lock
    FROM period_closes
    WHERE reopened_at IS NULL AND period_end < p_period_end;

    UPDATE finance_settings
    SET locked_before = v_new_lock, updated_by = auth.uid()
    WHERE id;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'locked_before', v_new_lock
    );
END;
$function$;

-- ─── close_financial_year
-- db/functions/close_financial_year.sql
-- 年结(FIN-23)。一张分录、日期 = 财年末:每个非零损益科目清零,净额对 3100。
-- 科目按 account_type 推导(见 preview 头注);幂等靠算术(已结/空年 → 全零,
-- 不过账不留行);只能结推导出的下一个财年(乱序会打断 3100 的链条)。
-- 硬前置:月结锁位已过年末(只断言,不动锁)、试算平衡、重估已平、折旧已平 ——
-- 每条点名拒。结转分录凭 evoltrya.close_ctx 过月锁(用毕即清);year_closes 行
-- 随后落库,自此 YEAR_CLOSED 闸生效。

CREATE OR REPLACE FUNCTION public.close_financial_year(p_year_end date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_fs       record;
    v_preview  jsonb;
    v_r        jsonb;
    v_lines    jsonb := '[]'::jsonb;
    v_net      numeric;
    v_amt      numeric;
    v_je       jsonb;
    v_close_id uuid := gen_random_uuid();
BEGIN
    PERFORM require_permission('action.finance_reopen');
    IF p_year_end IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;
    -- 串行化(与月结同一把锁)
    SELECT * INTO v_fs FROM finance_settings WHERE id FOR UPDATE;

    v_preview := preview_close_financial_year(p_year_end);

    -- 幂等出口:已结(累计已归零)→ 什么都不做,原样说明
    IF (v_preview->>'already_closed')::boolean THEN
        RETURN jsonb_build_object('year_end', p_year_end, 'net_result', 0,
                                  'journal_code', NULL, 'already_closed', true);
    END IF;

    -- 只能结【推导出的下一个财年】—— 乱序关年会把留存收益链条打断
    IF p_year_end <> (v_preview->>'expected_year_end')::date THEN
        RAISE EXCEPTION 'YEAR_END_INVALID|%|%', p_year_end, v_preview->>'expected_year_end';
    END IF;

    -- 硬前置,逐条点名(软警告不在此列 —— 年末应计与草稿薪资由界面提示复核)
    IF NOT (v_preview->>'final_period_closed')::boolean THEN
        RAISE EXCEPTION 'FINAL_PERIOD_NOT_CLOSED|%|%', p_year_end,
            COALESCE(v_fs.locked_before::text, '(unlocked)');
    END IF;
    IF NOT (v_preview->>'trial_balanced')::boolean THEN
        RAISE EXCEPTION 'TRIAL_BALANCE_UNBALANCED|%', p_year_end;
    END IF;
    IF NOT (v_preview->>'revaluation_level')::boolean THEN
        RAISE EXCEPTION 'REVALUATION_NOT_RUN|%', p_year_end;
    END IF;
    IF NOT (v_preview->>'depreciation_level')::boolean THEN
        RAISE EXCEPTION 'DEPRECIATION_NOT_RUN|%', p_year_end;
    END IF;

    v_net := (v_preview->>'net_result')::numeric;

    -- 结转行:把每个非零损益科目清零(贷余借清、借余贷清),净额对 3100
    FOR v_r IN SELECT * FROM jsonb_array_elements(v_preview->'rows')
    LOOP
        v_amt := (v_r->>'net')::numeric;
        v_lines := v_lines || jsonb_build_object(
            'account_code', v_r->>'account',
            'side', CASE WHEN v_amt > 0 THEN 'debit' ELSE 'credit' END,
            'currency', base_currency_code(), 'amount_ccy', abs(v_amt),
            'line_memo', 'year-end close');
    END LOOP;

    IF jsonb_array_length(v_lines) = 0 THEN
        -- 全年损益净额与逐科目都为零(空年)—— 无可结转,不留分录不留行
        RETURN jsonb_build_object('year_end', p_year_end, 'net_result', 0,
                                  'journal_code', NULL, 'already_closed', false);
    END IF;

    IF v_net <> 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '3100',
            'side', CASE WHEN v_net > 0 THEN 'credit' ELSE 'debit' END,
            'currency', base_currency_code(), 'amount_ccy', abs(v_net),
            'line_memo', 'net result to retained earnings');
    END IF;

    -- 结转分录日期 = 年末,而年末已被月结锁住(硬前置)—— 凭 close_ctx 过月锁,
    -- 用毕即清(movement_ctx 同款)。YEAR_CLOSED 闸此刻无感:本年的 year_closes
    -- 行还没落库。
    PERFORM set_config('evoltrya.close_ctx', 'year_close', true);
    v_je := post_journal_entry(p_year_end,
        'Year-end close FY ending ' || p_year_end, 'year_close', v_close_id, v_lines);
    PERFORM set_config('evoltrya.close_ctx', '', true);

    INSERT INTO year_closes (id, year_end, closing_journal_id, net_result, notes, closed_by)
    VALUES (v_close_id, p_year_end, (v_je->>'entry_id')::uuid, v_net, p_notes, v_user);

    RETURN jsonb_build_object('year_end', p_year_end, 'net_result', v_net,
        'journal_code', v_je->>'code', 'rows', v_preview->'rows',
        'already_closed', false);
END;
$function$;

-- ─── reopen_financial_year
-- db/functions/reopen_financial_year.sql
-- 重开年(FIN-23)。分录不可变 → 重开 = 结转分录的镜像冲销(日期同为年末,连
-- "截至年末"口径的报表一并复原)+ year_closes 盖章留痕(守卫触发器只放行这一种
-- UPDATE)。必须给理由;隔着后年重开前年拒绝(LATER_YEAR_CLOSED)。
-- 【不动 locked_before】:关年没动过它,重开也不动 —— 要改年内月份,下一步是
-- reopen_period(月级、自己留痕);YEAR_CLOSED 闸已随盖章抬起。

CREATE OR REPLACE FUNCTION public.reopen_financial_year(p_year_end date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_row   record;
    v_lines jsonb := '[]'::jsonb;
    v_l     record;
    v_je    jsonb;
BEGIN
    PERFORM require_permission('action.finance_reopen');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;
    PERFORM 1 FROM finance_settings WHERE id FOR UPDATE;

    SELECT * INTO v_row FROM year_closes
    WHERE year_end = p_year_end AND reopened_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM year_closes WHERE year_end = p_year_end) THEN
            RAISE EXCEPTION 'ALREADY_REOPENED';
        END IF;
        RAISE EXCEPTION 'CLOSE_NOT_FOUND';
    END IF;
    -- 只能从最晚的仍有效年结往回重开 —— 隔着后年重开前年,3100 的链条就断了
    IF EXISTS (SELECT 1 FROM year_closes
               WHERE reopened_at IS NULL AND year_end > p_year_end) THEN
        RAISE EXCEPTION 'LATER_YEAR_CLOSED|%', p_year_end;
    END IF;

    -- 冲销行 = 结转分录的镜像(借贷互换),日期同为年末 —— 恢复到关年之前的
    -- 状态,连"截至年末"口径的报表也一并复原
    FOR v_l IN
        SELECT a.code, jl.debit, jl.credit
        FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
        WHERE jl.entry_id = v_row.closing_journal_id
        ORDER BY a.code
    LOOP
        v_lines := v_lines || jsonb_build_object(
            'account_code', v_l.code,
            'side', CASE WHEN v_l.debit > 0 THEN 'credit' ELSE 'debit' END,
            'currency', base_currency_code(), 'amount_ccy', CASE WHEN v_l.debit > 0 THEN v_l.debit ELSE v_l.credit END, 'line_memo', 'year-end close reversal');
    END LOOP;

    -- 凭 close_ctx 过两道闸(本年 year_closes 行此刻仍有效 → YEAR_CLOSED 需豁免;
    -- 月锁同理),先过账、后一次性盖章 —— 守卫触发器只放行这一种 UPDATE。
    PERFORM set_config('evoltrya.close_ctx', 'year_close', true);
    v_je := post_journal_entry(p_year_end,
        'REVERSAL: year-end close FY ending ' || p_year_end || ' — ' || btrim(p_reason),
        'year_close', v_row.id, v_lines);
    PERFORM set_config('evoltrya.close_ctx', '', true);

    UPDATE year_closes
    SET reopened_at = now(), reopened_by = v_user, reopen_reason = btrim(p_reason),
        reversal_journal_id = (v_je->>'entry_id')::uuid
    WHERE id = v_row.id;

    RETURN jsonb_build_object('year_end', p_year_end,
        'reversal_journal_code', v_je->>'code', 'net_result_reversed', v_row.net_result);
END;
$function$;

-- ─── allocate_processing_costs
CREATE OR REPLACE FUNCTION public.allocate_processing_costs(p_run_id uuid, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- Cost allocation. Metals with a usable price (deleted_at IS NULL, price_date <= run
-- process_date) contribute to metal value; metals WITHOUT one contribute 0 and are
-- recorded in allocation_snapshot.skipped_metals (the former missing-price hard error is gone).
-- NO_METAL_VALUE still blocks when the total metal value across all legs is 0.
-- (Phase 1 follow-up 1, 2026-07-03.)
-- cut 2a (2026-07-06): 10a 资本化分录(借 1220 / 贷 1200 材料 + 贷 5xxx 费用;
-- 重分摊 = 冲旧 + 重挂);10b 给无 COGS 的既有销售按原 sale_date 补挂 COGS。
DECLARE
    v_user                 uuid := auth.uid();
    v_run                  processing_runs%ROWTYPE;
    v_basis                text;
    v_process_date         date;
    v_material             numeric;
    v_process              numeric;
    v_total                numeric;
    v_inputs_without_price integer;
    v_total_basis          numeric;
    v_total_metal_value    numeric;
    v_bad_code             text;
    v_bad_metal            text;
    v_prices_used          jsonb;
    v_default_index        text;
    v_skipped_metals       jsonb;
    v_outputs              jsonb;
    v_sum_alloc            numeric;
    v_snapshot             jsonb;
    v_ct                   record;
    v_sale                 record;
    v_cap_lines            jsonb;
    v_cap_total            numeric;
    v_cap_je               jsonb;
    v_cap_entry_id         uuid;
    v_cogs                 numeric;
    v_cogs_je              jsonb;
    -- FIN-24:差额法用
    v_prior                jsonb;      -- 分摊前各产出腿的 allocated(差额的"已记录"侧)
    v_rec_src              jsonb;      -- 已记录的各来源(material / 各 cost_type)
    v_rec_total            numeric;
    v_by_source            jsonb;      -- 本次各来源(写进 snapshot,下次的"已记录")
    v_delta                numeric;
    v_leg                  record;
    v_d1220                numeric := 0;
    v_d5000                numeric := 0;
    v_d5200                numeric := 0;
    v_l1220                numeric;
    v_l5000                numeric;
    v_other                numeric;
    v_cred_total           numeric := 0;
    v_deb_total            numeric;
    v_cap_status           text;
    -- FIN-25:再加工
    v_material_in          numeric;   -- 进料批投料(→ 1200)
    v_material_re          numeric;   -- 产出批投料(→ 1220 解除上游)
    v_upstream_incomplete  boolean;
    v_re_without_price     integer;
    -- PROC-COST-1:状态改变型分支
    v_state_changing       boolean;
    v_sc_out_inputs        integer;
    v_sc_in_inputs         integer;
    v_sc_basis_total       numeric;
    v_sc_rows              jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. Lock the run; must exist and be a live committed run.
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;
    IF v_run.deleted_at IS NOT NULL OR v_run.status <> 'committed' THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.status;
    END IF;

    -- PROC-COST-1:那条"无处可落"的拒绝在这里【换成了真正的去处】——
    -- 状态改变型的分支在第 6 步之后(它需要 v_material / v_process 都已算出)。
    -- 仍然拒绝的四种情形在分支里逐一按名点出,理由见本迁移的 2e 段。

    -- 2. Resolve + validate basis.
    v_basis := COALESCE(p_basis, v_run.allocation_basis);
    IF v_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', v_basis;
    END IF;
    v_process_date := v_run.process_date;

    -- 3. Unit guard: all math assumes kg.
    SELECT ib.code INTO v_bad_code
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id AND ib.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    SELECT ob.code INTO v_bad_code
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id AND ob.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    -- 4. Material cost(FIN-25 起两路):进料批按 inbound.unit_price;产出批
    --    (再加工)按上游 processing_outputs.unit_cost_base。NULL 价照旧计 0 并
    --    计数 —— 【允许,不拒绝】:车间按天走,财务分摊按月走,拒绝会让车间等
    --    财务。零不静默:cost_incomplete 标记打在本单产出上,逐级传染(见 9c),
    --    上游补分摊后本单过期,重跑即修复。
    -- FRT-1:材料成本 = 【落地成本】,不只是单价 —— 单价 + 分摊到该批的单位运费。
    -- 运费资本化进批次之后,这里若仍只读 unit_price,运费就停在 1200/5000,
    -- 永远走不到产出批的 unit_cost_base,batch_margin 会继续停在运费之前的那个数
    -- (而运费那张分录本身完全正确)。这正是"资本化的错误藏在存货里"最具体的一种。
    SELECT COALESCE(SUM(pi.quantity_consumed
             * (COALESCE(ib.unit_price, 0)
                + CASE WHEN ib.quantity > 0 THEN batch_freight_base(ib.id) / ib.quantity ELSE 0 END
                -- PROC-COST-1:第三个成本组件 —— 该批身上已资本化的加工成本
                -- (放电等状态改变型工序留下的)。【不加这一项,成本就走不出去】:
                -- 它是进料批上的资本化成本【唯一】能到达损益表的那条路。
                + CASE WHEN ib.quantity > 0 THEN batch_processing_cost_base(ib.id) / ib.quantity ELSE 0 END)), 0),
           COUNT(*) FILTER (WHERE ib.unit_price IS NULL)
      INTO v_material_in, v_inputs_without_price
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id;

    SELECT COALESCE(SUM(pi.quantity_consumed * COALESCE(po_up.unit_cost_base, 0)), 0),
           COUNT(*) FILTER (WHERE po_up.unit_cost_base IS NULL),
           COALESCE(bool_or(po_up.unit_cost_base IS NULL OR po_up.cost_incomplete), false)
      INTO v_material_re, v_re_without_price, v_upstream_incomplete
    FROM processing_inputs pi
    JOIN processing_outputs po_up ON po_up.output_batch_id = pi.output_batch_id
    WHERE pi.run_id = p_run_id;
    v_inputs_without_price := v_inputs_without_price + COALESCE(v_re_without_price, 0);
    v_material := v_material_in + v_material_re;

    -- 5. Process cost = Σ live cost entries.
    SELECT COALESCE(SUM(amount_base), 0) INTO v_process
    FROM processing_cost_entries
    WHERE run_id = p_run_id AND deleted_at IS NULL;

    -- 6. Total.
    v_total := v_material + v_process;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-COST-1:【状态改变型 —— 成本资本化回投料批】
    -- 没有产出腿,于是收件人是那批【还在那里的】原料本身。深度放电不产出任何
    -- 新东西:料进去、料出来,只是不带电了 —— 所以它仍然是原料,成本落在 1200。
    -- 【只有加工成本资本化,材料成本【不】动】那批料的价值早就在 1200 上了;
    -- 再借一次 1200 就是拿 1200 对自己重复计数。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT NOT k.produces_outputs INTO v_state_changing
      FROM operation_types ot
      JOIN operation_kinds k ON k.code = ot.kind_code
     WHERE ot.code = v_run.operation_type_code;
    v_state_changing := COALESCE(v_state_changing, false);

    IF v_state_changing THEN
        -- 【拒绝 1】金属价值基准按【产出批的金属含量】拆分,而这里没有产出批。
        -- 那不是"算出来是零",是那个基准在这里根本没有可读的数。
        IF v_basis = 'metal_value' THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_BASIS|%|%', v_run.code, v_basis
              USING HINT = '金属价值基准读的是产出批的金属含量(output_batch_metals),而状态改变型工序没有产出批。按质量(weight)分摊。';
        END IF;

        SELECT count(*) FILTER (WHERE pi.output_batch_id IS NOT NULL),
               count(*) FILTER (WHERE pi.inbound_batch_id IS NOT NULL)
          INTO v_sc_out_inputs, v_sc_in_inputs
          FROM processing_inputs pi
         WHERE pi.run_id = p_run_id;

        -- 【拒绝 2】成本载体按 inbound_batch_id 记地址,自产产出批不在那个地址空间里。
        -- **按名拒绝,不许悄悄把成本丢掉** —— 要建这条路,先决定产出批的资本化载体
        -- 是什么(产出批已有 unit_cost_base,那是另一种形状,不是这一张台账)。
        IF v_sc_out_inputs > 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_OUTPUT_INPUT|%|%', v_run.code, v_sc_out_inputs
              USING HINT = '成本载体 batch_processing_cost_allocations 按进料批记地址,自产产出批不在它的地址空间里。这条路要建,先决定产出批的资本化载体是什么 —— 在那之前按名拒绝,而不是悄悄把这笔成本丢掉。';
        END IF;

        -- 【拒绝 3】没有投料批,资本化没有收件人。
        IF v_sc_in_inputs = 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_NO_INPUT|%', v_run.code
              USING HINT = '这张单没有进料批投料,资本化没有收件人。';
        END IF;

        SELECT COALESCE(SUM(pi.quantity_consumed), 0) INTO v_sc_basis_total
          FROM processing_inputs pi
         WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL;
        IF v_sc_basis_total <= 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_NO_BASIS|%', v_run.code
              USING HINT = '投料量合计为零,按质量分摊没有可用的分母。';
        END IF;

        -- 【拒绝 4 与既有路径同一条】资本化分录被人工冲销 → 基准与总账已分道。
        IF v_run.capitalization_entry_id IS NOT NULL THEN
            SELECT status INTO v_cap_status FROM journal_entries WHERE id = v_run.capitalization_entry_id;
            IF v_cap_status <> 'posted' THEN
                RAISE EXCEPTION 'ALLOCATION_LEDGER_DIVERGED|%', v_run.code;
            END IF;
            -- 【重分摊 = 冲旧 + 重挂,而这在这里是安全的 —— 论证只在这里成立】
            -- FIN-24 禁止转化型这么做,是因为成本已顺着产出批流向已售份额,而已过账
            -- 的 COGS 从不重述。状态改变型【没有产出批】:成本停在 1200 上一批仍然
            -- 是原料的货上,没有任何下游把它当成本消费掉。若那批料后来被一张转化型
            -- 加工单吃掉,那张单会因【第七过期源】而过期,重跑即修正。
            PERFORM reverse_journal_entry_internal(v_run.capitalization_entry_id, CURRENT_DATE,
                'Re-allocation ' || v_run.code);
            UPDATE processing_runs
               SET capitalization_entry_id = NULL, capitalized_cost_base = 0
             WHERE id = p_run_id;
        END IF;

        -- ── 台账:先删后插(幂等)。按投料量拆,最大份额吸收进位余数 ────────────
        -- 【零成本不写行 —— 一面为零而举的旗,等于喊狼来了】fu3:载体行是
        -- 第七过期源。一张【一分钱成本都没有】的放电单若也写下载体行,
        -- 它会把吃过那批料的下游单标成过期 —— 而那张单要重跑出来的数
        -- 与它现在的数【一模一样】。本仓库对无条件举旗已有成文处置
        -- (fixture 54:含量没变就不举旗,"没人看的旗和没有旗是同一样东西")。
        -- 【先删仍然无条件执行】:300 → 0 的重分摊必须真的把那一行拿掉。
        DELETE FROM batch_processing_cost_allocations WHERE run_id = p_run_id;

        IF round(v_process, 2) <> 0 THEN
        WITH legs AS (
            SELECT pi.inbound_batch_id AS ib, SUM(pi.quantity_consumed) AS q
              FROM processing_inputs pi
             WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL
             GROUP BY pi.inbound_batch_id
        ),
        calc AS (
            SELECT ib, q,
                   round(v_process * q / v_sc_basis_total, 2) AS raw,
                   row_number() OVER (ORDER BY q DESC, ib) AS rn
              FROM legs
        ),
        adj AS (
            SELECT c.*, (round(v_process, 2) - SUM(c.raw) OVER ()) AS rem FROM calc c
        )
        INSERT INTO batch_processing_cost_allocations
            (run_id, inbound_batch_id, amount_base, basis_qty, basis_total_qty)
        SELECT p_run_id, ib, raw + CASE WHEN rn = 1 THEN rem ELSE 0 END, q, v_sc_basis_total
          FROM adj;
        END IF;

        SELECT jsonb_agg(jsonb_build_object(
                   'inbound_batch_id', a.inbound_batch_id,
                   'amount_base', a.amount_base,
                   'basis_qty', a.basis_qty)
               ORDER BY a.inbound_batch_id)
          INTO v_sc_rows
          FROM batch_processing_cost_allocations a WHERE a.run_id = p_run_id;

        -- ── 分录:借 1200 / 贷 5xxx —— 【重分类,不是新成本】────────────────────
        -- 电费在录入那一刻就已经进了总账(fin_journal_cost_entry:借 5110 / 贷 2200)。
        -- 这一步不新增任何金额,它把已经在 COGS 里的钱拨进存货。
        v_cap_lines := '[]'::jsonb;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
              FROM processing_cost_entries
             WHERE run_id = p_run_id AND deleted_at IS NULL
             GROUP BY cost_type
             ORDER BY cost_type
        LOOP
            IF v_ct.amt > 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type),
                    'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_ct.amt);
            ELSIF v_ct.amt < 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type),
                    'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', -v_ct.amt);
            END IF;
        END LOOP;

        v_cap_entry_id := NULL;
        IF round(v_process, 2) <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object(
                'account_code', '1200',
                'side', CASE WHEN v_process > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(round(v_process, 2)),
                'line_memo', 'capitalised onto input batch — state-changing run')) || v_cap_lines;
            v_cap_je := post_journal_entry(CURRENT_DATE, 'Capitalize ' || v_run.code,
                'allocation', p_run_id, v_cap_lines);
            v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
        END IF;

        -- 【快照】capitalized_by_source 只列各 cost_type,【故意没有 material 一项】——
        -- 材料没有被资本化(它早就在 1200 上了),写进去会让后来的人以为它进过账。
        v_by_source := '{}'::jsonb;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
              FROM processing_cost_entries
             WHERE run_id = p_run_id AND deleted_at IS NULL
             GROUP BY cost_type
        LOOP
            v_by_source := v_by_source || jsonb_build_object(v_ct.cost_type, v_ct.amt);
        END LOOP;

        UPDATE processing_runs
        SET material_cost_base   = round(v_material, 2),
            process_cost_base    = round(v_process, 2),
            total_cost_base      = round(v_total, 2),
            allocation_basis     = v_basis,
            allocation_snapshot  = jsonb_build_object(
                'capitalized_by_source', v_by_source,
                'capitalised_component', 'process_only',
                'capitalised_onto', 'input_batches',
                'destination_account', '1200',
                'basis', v_basis,
                'computed_at', now(),
                'inputs_without_price', v_inputs_without_price,
                'allocations', COALESCE(v_sc_rows, '[]'::jsonb)),
            allocated_at         = now(),
            allocated_by         = v_user,
            capitalized_cost_base   = round(v_process, 2),
            capitalization_entry_id = v_cap_entry_id,
            updated_at           = now(),
            updated_by           = v_user
        WHERE id = p_run_id;

        RETURN jsonb_build_object(
            'run_id', p_run_id,
            'basis', v_basis,
            'state_changing', true,
            'material_cost_base', round(v_material, 2),
            'process_cost_base', round(v_process, 2),
            'total_cost_base', round(v_total, 2),
            'capitalized_cost_base', round(v_process, 2),
            'capitalised_onto', COALESCE(v_sc_rows, '[]'::jsonb),
            'inputs_without_price', v_inputs_without_price,
            'outputs', '[]'::jsonb
        );
    END IF;

    -- 7. Basis totals. Metals without a usable price contribute 0 (LEFT JOIN + COALESCE)
    --    and are recorded in skipped_metals; only a zero grand total blocks (NO_METAL_VALUE).
    IF v_basis = 'metal_value' THEN
        -- METAL-2:分摊【没有交易可以继承指数】—— 一张加工单不是一笔谈定的买卖,
        -- 没有对手方、没有条款,所以它按 pricing_settings 的房屋约定取价。
        -- 【这是默认值在替一条缺席的条款站位,不是"这批成本按某个声明的指数结算了"】。
        -- 快照里一并记下用的是哪个指数,免得日后有人把它读成一条谈定的条款。
        SELECT default_metal_index INTO v_default_index FROM pricing_settings WHERE id;

        SELECT COALESCE(SUM(
                 po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0)
               ), 0)
          INTO v_total_metal_value
        FROM processing_outputs po
        JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
        LEFT JOIN LATERAL (
            SELECT mp.price_usd_per_tonne
            FROM metal_prices mp
            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
              AND mp.price_index IS NOT DISTINCT FROM v_default_index   -- METAL-2
              AND mp.price_date <= v_process_date
            ORDER BY mp.price_date DESC
            LIMIT 1
        ) pr ON true
        WHERE po.run_id = p_run_id;

        IF COALESCE(v_total_metal_value, 0) = 0 THEN
            RAISE EXCEPTION 'NO_METAL_VALUE';
        END IF;

        v_total_basis := v_total_metal_value;

        SELECT COALESCE(jsonb_agg(
                   jsonb_build_object('metal', metal,
                                      'price_usd_per_tonne', price_usd_per_tonne,
                                      'price_date', price_date)
                   ORDER BY metal), '[]'::jsonb)
          INTO v_prices_used
        FROM (
            SELECT DISTINCT ON (mp.metal) mp.metal, mp.price_usd_per_tonne, mp.price_date
            FROM metal_prices mp
            WHERE mp.deleted_at IS NULL AND mp.price_date <= v_process_date
              AND mp.price_index IS NOT DISTINCT FROM v_default_index   -- METAL-2
              AND mp.metal IN (
                  SELECT DISTINCT obm.metal
                  FROM processing_outputs po
                  JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
                  WHERE po.run_id = p_run_id AND obm.content_pct > 0
              )
            ORDER BY mp.metal, mp.price_date DESC
        ) q;

        -- Metals present (content > 0) on this run with NO usable price row: excluded from
        -- value (they contributed 0 above) and reported in the snapshot as skipped.
        SELECT COALESCE(jsonb_agg(m ORDER BY m), '[]'::jsonb)
          INTO v_skipped_metals
        FROM (
            SELECT DISTINCT obm.metal AS m
            FROM processing_outputs po
            JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
            WHERE po.run_id = p_run_id AND obm.content_pct > 0
              AND NOT EXISTS (
                  SELECT 1 FROM metal_prices mp
                  WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                    AND mp.price_date <= v_process_date
              )
        ) s;
    ELSE
        SELECT COALESCE(SUM(quantity_produced), 0) INTO v_total_basis
        FROM processing_outputs WHERE run_id = p_run_id;
        v_total_metal_value := NULL;
        v_prices_used := '[]'::jsonb;
        v_skipped_metals := '[]'::jsonb;
    END IF;

    -- FIN-24:差额法的"已记录"侧 —— 在下面的 UPDATE 改写之前,把各产出腿
    -- 当前的 allocated 拍下来。目标 − 已记录 = 应过账的差额(与重估/折旧同形)。
    SELECT COALESCE(jsonb_object_agg(po.output_batch_id::text,
                    COALESCE(po.allocated_cost_base, 0)), '{}'::jsonb)
      INTO v_prior
    FROM processing_outputs po WHERE po.run_id = p_run_id;

    -- 8 + 9. Allocate (largest-share row absorbs the rounding remainder), persist legs,
    --        and collect the per-output result — all in one statement.
    WITH legs AS (
        SELECT po.id AS leg_id, po.output_batch_id, po.quantity_produced,
               CASE WHEN v_basis = 'weight' THEN po.quantity_produced::numeric
                    ELSE COALESCE((
                        SELECT SUM(po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0))
                        FROM output_batch_metals obm
                        LEFT JOIN LATERAL (
                            SELECT mp.price_usd_per_tonne
                            FROM metal_prices mp
                            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                              AND mp.price_date <= v_process_date
                            ORDER BY mp.price_date DESC
                            LIMIT 1
                        ) pr ON true
                        WHERE obm.output_batch_id = po.output_batch_id
                    ), 0)
               END AS basis_value
        FROM processing_outputs po
        WHERE po.run_id = p_run_id
    ),
    calc AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               round(v_total * basis_value / NULLIF(v_total_basis, 0), 2) AS alloc_raw,
               row_number() OVER (ORDER BY basis_value DESC, leg_id) AS rn
        FROM legs
    ),
    adj AS (
        SELECT c.*, (round(v_total, 2) - SUM(alloc_raw) OVER ()) AS remainder
        FROM calc c
    ),
    final AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               alloc_raw + CASE WHEN rn = 1 THEN remainder ELSE 0 END AS allocated
        FROM adj
    ),
    upd AS (
        UPDATE processing_outputs po
        SET allocated_cost_base = f.allocated,
            unit_cost_base = round(f.allocated / f.quantity_produced, 4)
        FROM final f
        WHERE po.id = f.leg_id
        RETURNING f.output_batch_id, f.basis_value, f.allocated, po.unit_cost_base
    )
    SELECT jsonb_agg(
               jsonb_build_object(
                   'output_batch_id', output_batch_id,
                   'share', round(basis_value / NULLIF(v_total_basis, 0), 6),
                   'allocated_cost_base', allocated,
                   'unit_cost_base', unit_cost_base)
               ORDER BY output_batch_id),
           COALESCE(SUM(allocated), 0)
      INTO v_outputs, v_sum_alloc
    FROM upd;

    -- 9b. Snapshot + run header.
    -- FIN-24:by_source = 本次各来源的入账口径(材料 + 逐 cost_type,各 2 位),
    -- 下一次差额跑的"已记录"就从这里读 —— recorded,不再从分录反推。
    v_by_source := jsonb_build_object('material', round(v_material_in, 2));
    IF round(v_material_re, 2) <> 0 THEN
        -- 再加工材料单列一源:首挂贷 1220(解除上游产出),差额与 material 同贷 5000
        v_by_source := v_by_source || jsonb_build_object('material_reprocessed', round(v_material_re, 2));
    END IF;
    FOR v_ct IN
        SELECT cost_type, round(sum(amount_base), 2) AS amt
        FROM processing_cost_entries
        WHERE run_id = p_run_id AND deleted_at IS NULL
        GROUP BY cost_type
    LOOP
        v_by_source := v_by_source || jsonb_build_object(v_ct.cost_type, v_ct.amt);
    END LOOP;

    v_snapshot := jsonb_build_object(
        'capitalized_by_source', v_by_source,
        'basis', v_basis,
        'computed_at', now(),
        'inputs_without_price', v_inputs_without_price,
        'total_output_metal_value_usd',
            CASE WHEN v_basis = 'metal_value' THEN round(v_total_metal_value, 2) ELSE NULL END,
        'prices_used', v_prices_used,
        -- METAL-2:用的是哪个指数,以及它【是房屋约定而不是条款】。
        -- 读快照的人必须能分清这两件事:这批成本不是"按 LME 结算"的,
        -- 它是"在没有条款可循时,按当时的房屋约定取了 LME 的价"。
        'price_index', v_default_index,
        'price_index_is_house_default', true,
        'skipped_metals', v_skipped_metals
    );

    -- 9c(FIN-25):不完整成本标记 —— 任何投料无价、或上游产出自己就带着标记,
    --    本单全部产出打上 cost_incomplete。零永不静默,层层传染;上游补分摊后
    --    本单过期(状态视图第三支),重跑即清。
    UPDATE processing_outputs
    SET cost_incomplete = (v_inputs_without_price > 0 OR v_upstream_incomplete)
    WHERE run_id = p_run_id;

    -- FIN-36c:告诉基准触发器"这次基准变动是【跟着重分摊一起发生的】,不是漂移"。
    -- 与年结用 evoltrya.close_ctx 穿过期间锁是同一个惯用法(post_journal_entry)。
    -- 【为什么不靠时间戳判断】now() 是事务时间:同一个事务里两次分摊拿到相同的
    -- allocated_at,任何"看 allocated_at 变没变"的判据都会失效(fixture 就在一个
    -- 事务里跑)。显式的上下文标记不受事务边界影响。
    PERFORM set_config('evoltrya.alloc_ctx', '1', true);

    UPDATE processing_runs
    SET material_cost_base   = round(v_material, 2),
        process_cost_base    = round(v_process, 2),
        total_cost_base      = round(v_total, 2),
        allocation_basis    = v_basis,
        allocation_snapshot = v_snapshot,
        allocated_at        = now(),
        allocated_by        = v_user,
        updated_at          = now(),
        updated_by          = v_user
    WHERE id = p_run_id;

    -- 标记只覆盖上面那一条 UPDATE:同一事务里【之后】的裸改基准仍算漂移
    PERFORM set_config('evoltrya.alloc_ctx', '', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- 10a.【FIN-24:首挂全额,此后差额 —— 不再全额冲销重挂】
    -- 旧实现重述资本化(1220 按新价整体改写)而已过账 COGS 从不重述:卖掉份额的
    -- 价差留在库存里,卖得越多错得越多;材料价差贷 1200,而 reprice 早把已耗份额
    -- 记进了 5000 —— 两处叠加 = 重复计数 + 1200 变负(实测:100kg@1 全耗、重定价
    -- 到 2、重分摊 → 1220=200 但 5000 多挂 100、1200=−100)。
    -- 差额法(与重估/折旧同形):目标 − 已记录,只过差额,第二次跑为零。
    --   * 每个产出批按【自己】的处置比例拆(Part B:一炉多批、各卖各的):
    --       在库 + 已售未挂COGS → 1220(后者价值仍躺在 1220,10b 随后按新单位成本解除)
    --       已售已挂COGS       → 5000(COGS 补差)
    --       注销/盘亏           → 5200(处置在产出粒度可知,注销总额是运营信号,
    --                              不并进材料成本 —— Tim 的裁定,推翻了与 reprice
    --                              一致性的论证;reprice 在进料粒度分不出注销与
    --                              耗用、整体进 5000 的不精确,另记 known-issues)
    --   * 贷方:材料差额 → 5000(reprice 把已耗价差停在那里;5000 同时是 COGS
    --     科目,已售份额的借方与之同户恰好互抵 —— 这一巧合是本设计的支点);
    --     费用差额 → 各自成本科目(fin_cost_account)。
    --   * 产出批喂回再加工在 schema 上【不可表示】(processing_inputs 只指
    --     inbound_batches)—— 处置只有在库/已售/注销三种。粉线大概率多段加工,
    --     真建了再加工必须先扩这套拆分(known-issues 有账)。
    -- ════════════════════════════════════════════════════════════════════════
    v_rec_total := COALESCE(v_run.capitalized_cost_base, 0);
    IF v_run.capitalization_entry_id IS NOT NULL THEN
        SELECT status INTO v_cap_status FROM journal_entries WHERE id = v_run.capitalization_entry_id;
        IF v_cap_status <> 'posted' THEN
            -- 资本化分录被人工冲销:存量"已记录"与总账已分道,差额法的基准不再可信。
            -- 这是【唯一】剩下的红色情形:人工冲销是人做的决定,修复也该是人工分录。
            RAISE EXCEPTION 'ALLOCATION_LEDGER_DIVERGED|%', v_run.code;
        END IF;
    END IF;

    IF v_run.capitalization_entry_id IS NULL THEN
        -- ── 首挂:全额资本化(原路径)────────────────────────────────────────
        v_cap_lines := '[]'::jsonb;
        v_cap_total := 0;
        IF round(v_material_in, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', round(v_material_in, 2));
            v_cap_total := v_cap_total + round(v_material_in, 2);
        END IF;
        -- FIN-25:再加工材料 —— 解除的是上游产出的 1220,不是原料的 1200。
        -- 同科目 Dr(资本化进本单产出)/Cr(解除上游)两腿并存,净额即增量。
        IF round(v_material_re, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', round(v_material_re, 2), 'line_memo', 're-processed input relieved');
            v_cap_total := v_cap_total + round(v_material_re, 2);
        END IF;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
            FROM processing_cost_entries
            WHERE run_id = p_run_id AND deleted_at IS NULL
            GROUP BY cost_type
            ORDER BY cost_type
        LOOP
            IF v_ct.amt > 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            ELSIF v_ct.amt < 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', -v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            END IF;
        END LOOP;

        v_cap_entry_id := NULL;
        IF v_cap_total <> 0 THEN
            v_cap_lines := jsonb_build_array(
                jsonb_build_object('account_code', '1220',
                                   'side', CASE WHEN v_cap_total > 0 THEN 'debit' ELSE 'credit' END,
                                   'currency', base_currency_code(), 'amount_ccy', abs(v_cap_total))
            ) || v_cap_lines;
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Capitalize ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = v_cap_total,
            capitalization_entry_id = v_cap_entry_id
        WHERE id = p_run_id;
    ELSE
        -- ── 差额路径 ─────────────────────────────────────────────────────────
        -- 已记录的各来源:优先 snapshot(FIN-24 起写入);老单从已过账的资本化
        -- 分录行反推 —— 1200 行 = 材料,5xxx 行按 fin_cost_account 的反向映射。
        v_rec_src := v_run.allocation_snapshot->'capitalized_by_source';
        IF v_rec_src IS NULL THEN
            SELECT COALESCE(jsonb_object_agg(q.src, q.amt), '{}'::jsonb) INTO v_rec_src FROM (
                SELECT CASE a.code
                           WHEN '1200' THEN 'material'
                           WHEN '5100' THEN 'labour'
                           WHEN '5110' THEN 'electricity'
                           WHEN '5120' THEN 'gas'
                           WHEN '5130' THEN 'depreciation'
                           WHEN '5140' THEN 'consumables'
                           WHEN '5150' THEN 'waste_treatment'
                           WHEN '5190' THEN 'other'
                       END AS src,
                       round(SUM(jl.credit) - SUM(jl.debit), 2) AS amt
                FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
                WHERE jl.entry_id = v_run.capitalization_entry_id AND a.code <> '1220'
                GROUP BY a.code) q
            WHERE q.src IS NOT NULL;
        END IF;

        -- 贷方:逐来源差额。材料 → 5000(不是 1200!—— reprice 已把已耗价差记在
        -- 5000,这里把属于未售产出的部分从 5000 拨进 1220,双方不再叠加);
        -- 费用 → 各自成本科目。负差翻借方。
        v_cap_lines := '[]'::jsonb;
        v_cred_total := 0;
        FOR v_ct IN
            SELECT key AS src, (v_by_source->>key)::numeric - COALESCE((v_rec_src->>key)::numeric, 0) AS d
            FROM jsonb_object_keys(v_by_source) AS key
            UNION
            SELECT key, 0 - (v_rec_src->>key)::numeric
            FROM jsonb_object_keys(v_rec_src) AS key
            WHERE v_by_source->>key IS NULL
            ORDER BY 1
        LOOP
            IF v_ct.d <> 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object(
                    'account_code', CASE WHEN v_ct.src IN ('material', 'material_reprocessed') THEN '5000' ELSE fin_cost_account(v_ct.src) END,
                    'side', CASE WHEN v_ct.d > 0 THEN 'credit' ELSE 'debit' END,
                    'currency', base_currency_code(), 'amount_ccy', abs(v_ct.d),
                    'line_memo', 'allocation delta: ' || v_ct.src);
                v_cred_total := v_cred_total + v_ct.d;
            END IF;
        END LOOP;

        -- 借方:逐产出批的差额,按该批自己的处置比例拆
        FOR v_leg IN
            SELECT po.output_batch_id, po.quantity_produced AS qty,
                   po.allocated_cost_base AS new_alloc,
                   COALESCE((v_prior->>po.output_batch_id::text)::numeric, 0) AS old_alloc,
                   ob.remaining_qty,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NOT NULL), 0) AS sold_cogs,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NULL), 0) AS sold_nocogs,
                   -- FIN-25 第四处置:被下游加工消耗的份额 → 5000 停车
                   --(与 reprice 对已耗进料完全同构:下游过期后重跑,其材料差额
                   -- 贷 5000 收回停车 —— 传导靠既有过期旗逐级走,不递归)
                   COALESCE((SELECT SUM(pi2.quantity_consumed) FROM processing_inputs pi2
                             WHERE pi2.output_batch_id = po.output_batch_id), 0) AS consumed_proc
            FROM processing_outputs po
            JOIN output_batches ob ON ob.id = po.output_batch_id
            WHERE po.run_id = p_run_id
        LOOP
            v_delta := round(v_leg.new_alloc - v_leg.old_alloc, 2);
            IF v_delta = 0 OR v_leg.qty = 0 THEN CONTINUE; END IF;
            v_other := GREATEST(0, v_leg.qty - v_leg.remaining_qty - v_leg.sold_cogs - v_leg.sold_nocogs - v_leg.consumed_proc);
            v_l1220 := round(v_delta * (v_leg.remaining_qty + v_leg.sold_nocogs) / v_leg.qty, 2);
            v_l5000 := round(v_delta * (v_leg.sold_cogs + v_leg.consumed_proc) / v_leg.qty, 2);
            -- 5200 取残差,保证三桶之和恰等于该批差额
            v_d1220 := v_d1220 + v_l1220;
            v_d5000 := v_d5000 + v_l5000;
            v_d5200 := v_d5200 + (v_delta - v_l1220 - v_l5000);
        END LOOP;

        -- 强制配平:Σ借(三桶)与 Σ贷(逐来源)各自取整后可差一两分 ——
        -- 差额并进 1220 桶(金额最大、且是"目标状态"侧,与 8+9 步的
        -- largest-share-absorbs 同一习惯)。
        v_deb_total := v_d1220 + v_d5000 + v_d5200;
        v_d1220 := v_d1220 + round(v_cred_total - v_deb_total, 2);

        IF v_d1220 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '1220',
                'side', CASE WHEN v_d1220 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d1220),
                'line_memo', 'in-stock share')) || v_cap_lines;
        END IF;
        IF v_d5000 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5000',
                'side', CASE WHEN v_d5000 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d5000),
                'line_memo', 'sold/consumed share — COGS catch-up / re-processing park')) || v_cap_lines;
        END IF;
        IF v_d5200 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5200',
                'side', CASE WHEN v_d5200 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d5200),
                'line_memo', 'written-off share')) || v_cap_lines;
        END IF;

        -- 幂等出口:没有任何差额 → 不过账(allocated_at 照常刷新,过期标记消除)
        IF jsonb_array_length(v_cap_lines) > 0 THEN
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Re-allocation delta ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            -- 差额分录记进 snapshot 的留痕数组;capitalization_entry_id 仍指首挂
            v_snapshot := v_snapshot || jsonb_build_object('delta_entry_ids',
                COALESCE(v_run.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)
                    || to_jsonb((v_cap_je->>'entry_id')::text));
            UPDATE processing_runs SET allocation_snapshot = v_snapshot WHERE id = p_run_id;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = round(v_rec_total + v_cred_total, 2)
        WHERE id = p_run_id;
    END IF;

    -- 10b. cut 2a:COGS 补挂 —— 只补此前无 COGS 分录的销售(cogs_entry_id IS NULL),
    --      用最新 unit_cost_base,按各自原 sale_date(撞期间锁则 PERIOD_LOCKED 直接抛出)。
    --      已挂 COGS 不追溯重述(标准成本式简化;重述属人工冲销决策)。
    FOR v_sale IN
        SELECT sr.id, sr.quantity, sr.sale_date, ob.code AS batch_code, po.unit_cost_base
        FROM sales_records sr
        JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = p_run_id
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        WHERE sr.cogs_entry_id IS NULL
        ORDER BY sr.sale_date, sr.created_at
    LOOP
        v_cogs := round(v_sale.quantity * v_sale.unit_cost_base, 2);
        IF v_cogs <> 0 THEN
            v_cogs_je := post_journal_entry(
                v_sale.sale_date,
                'COGS ' || v_sale.batch_code,
                'sale', v_sale.id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_cogs_je->>'entry_id')::uuid WHERE id = v_sale.id;
        END IF;
    END LOOP;

    -- 10. Return.
    RETURN jsonb_build_object(
        'run_id', p_run_id,
        'basis', v_basis,
        'material_cost_base', round(v_material, 2),
        'process_cost_base', round(v_process, 2),
        'total_cost_base', round(v_total, 2),
        'inputs_without_price', v_inputs_without_price,
        'outputs', COALESCE(v_outputs, '[]'::jsonb)
    );
END;
$function$;

-- ─── release_purchase_order_retention
CREATE OR REPLACE FUNCTION public.release_purchase_order_retention(p_retention_id uuid, p_released_amount_ccy numeric, p_withheld_amount_ccy numeric, p_withholding_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_state    text;
    v_total    numeric;
    v_code     text;
    v_maturity date;
    v_user     uuid := auth.uid();
BEGIN
    PERFORM require_permission('module.finance.edit');

    -- ★【为什么这里【不】读 purchase_order_retention_status】★ 那张视图体内带着
    -- has_permission('module.purchasing.view') 与按 data.view_prices 的金额遮蔽。
    -- 视图体里的谓词【不因为本函数是 DEFINER 而失效】—— 它是一个过滤条件,不是 RLS。
    -- 于是一个没有 data.view_prices 的调用者会拿到 retention_amount_ccy = NULL,
    -- 下面那条"放款+扣留必须等于总额"的校验会拿 NULL 去比,**结果是它不拦了**。
    -- 一道被遮蔽悄悄关掉的闸比没有闸更糟。所以判据一律从基表现算。
    SELECT po.code,
           CASE WHEN fa.acceptance_date IS NULL THEN NULL::date
                ELSE (fa.acceptance_date + (r.retention_months || ' months')::interval)::date END,
           CASE WHEN fa.acceptance_date IS NULL              THEN 'clock_not_started'
                WHEN r.released_at IS NOT NULL               THEN 'released'
                WHEN (fa.acceptance_date + (r.retention_months || ' months')::interval)::date
                     <= CURRENT_DATE                         THEN 'awaiting_confirmation'
                ELSE 'running' END,
           COALESCE(r.fixed_amount_ccy, round(pol.estimated_amount_ccy * r.percentage / 100.0, 2))
    INTO v_code, v_maturity, v_state, v_total
    FROM purchase_order_line_retentions r
    JOIN purchase_order_lines pol ON pol.id = r.purchase_order_line_id
    JOIN purchase_orders po ON po.id = pol.purchase_order_id
    JOIN fixed_assets fa ON fa.id = pol.asset_id
    WHERE r.id = p_retention_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RETENTION_NOT_FOUND|%', COALESCE(p_retention_id::text, '?');
    END IF;

    IF v_state = 'released' THEN
        RAISE EXCEPTION 'RETENTION_ALREADY_RELEASED|%', v_code;
    END IF;
    -- 【没验收就没有起算点】—— 这不是"还没到期",是【时钟还没开始走】。
    IF v_state = 'clock_not_started' THEN
        RAISE EXCEPTION 'RETENTION_CLOCK_NOT_STARTED|%', v_code
          USING HINT = '这台机器还没有验收日期(fixed_assets.acceptance_date)—— 质保期无从起算,更谈不上到期。先记验收(set_asset_acceptance)';
    END IF;
    -- 【提前放款等于把质保金废掉】质保金的全部意义是它在质保期内扣得下来。
    IF v_state = 'running' THEN
        RAISE EXCEPTION 'RETENTION_NOT_MATURE|%|%', v_code, v_maturity
          USING HINT = '质保期未满 —— 提前放款等于把质保金废掉。到期日由验收日推导,不是一个可以绕过的字面量';
    END IF;

    IF p_released_amount_ccy IS NULL OR p_withheld_amount_ccy IS NULL THEN
        RAISE EXCEPTION 'RETENTION_RELEASE_AMOUNTS_REQUIRED'
          USING HINT = '放多少、扣多少都要明说 —— 两个都不给默认值';
    END IF;
    IF p_released_amount_ccy < 0 OR p_withheld_amount_ccy < 0 THEN
        RAISE EXCEPTION 'RETENTION_RELEASE_AMOUNT_NEGATIVE|%|%', p_released_amount_ccy, p_withheld_amount_ccy;
    END IF;
    IF round(p_released_amount_ccy + p_withheld_amount_ccy, 2) <> round(v_total, 2) THEN
        RAISE EXCEPTION 'RETENTION_RELEASE_DOES_NOT_BALANCE|%|%|%',
            v_code, round(p_released_amount_ccy + p_withheld_amount_ccy, 2), round(v_total, 2)
          USING HINT = '放款 + 扣留必须恰好等于质保金总额 —— 差额若允许存在,那笔钱就没有下落了';
    END IF;
    -- 扣了钱就要说为什么。表上那条 CHECK 也拦,这里【先】说一遍,好让走门的人
    -- 拿到一个具名拒绝,而不是一条约束原文。
    IF p_withheld_amount_ccy > 0 AND COALESCE(btrim(p_withholding_reason), '') = '' THEN
        RAISE EXCEPTION 'RETENTION_WITHHOLDING_NEEDS_REASON|%', v_code
          USING HINT = '扣留了质保金就要写明理由 —— 一笔没有理由的扣款,在供应商问起来的那天答不出来';
    END IF;

    UPDATE purchase_order_line_retentions
    SET released_at         = now(),
        released_by         = v_user,
        released_amount_ccy = p_released_amount_ccy,
        withheld_amount_ccy = p_withheld_amount_ccy,
        withholding_reason  = CASE WHEN p_withheld_amount_ccy > 0
                                   THEN btrim(p_withholding_reason) ELSE NULL END
    WHERE id = p_retention_id;

    RETURN jsonb_build_object(
        'retention_id', p_retention_id,
        'purchase_order_code', v_code,
        'retention_amount_ccy', round(v_total, 2),
        'released_amount_ccy', p_released_amount_ccy,
        'withheld_amount_ccy', p_withheld_amount_ccy,
        'withholding_reason', CASE WHEN p_withheld_amount_ccy > 0 THEN btrim(p_withholding_reason) END);
END;
$function$;

-- ─── open_review_cycle
-- db/functions/open_review_cycle.sql
-- 开启一轮年度评估:每名【在职且已转正】(employment_status = 'active')的员工一份 draft。
-- 试用期、离职、在离职通知期('notice')的员工都不生成;【review_exempt 的整个跳过】
-- (组织架构顶端 —— 不建评估,也就不会报"没有评估人")。
--
-- 【HR-3b:评估人三级解析】部门经理 → 本人就是部门经理时取【上级部门】的经理 → NULL。
-- 每一级都排除"解析到本人"。留 NULL 的那些【不是被忽略了】—— hr_alerts 的
-- review_no_reviewer 一支会在开轮当天就把它们顶出来,好过到 due_date 才发现。
--
-- 【幂等】NOT EXISTS + 部分唯一索引双保险,重跑不会产生第二份。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3a-performance-reviews.sql;
--       reviewer resolution and review_exempt added by
--       db/migrations/2026-08-04-hr3b-salary-basis-and-review-visibility.sql.

-- PROBATION-1(2026-08-27):评估人那段三级解析抽成了 resolve_review_reviewer(),
-- 本函数改为调用它 —— 行为一字未变,只是"谁评估这个人"从此在库里只有一处定义。
-- 第二个调用方是 open_probation_review;db/fixtures/136 的 H 臂钉住两边都在调。

CREATE OR REPLACE FUNCTION public.open_review_cycle(p_cycle_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c          review_cycles%ROWTYPE;
    v_created    integer;
    v_total      integer;
    v_noreviewer integer;
    v_exempt     integer;
BEGIN
    PERFORM require_permission('action.hr_reviews');

    SELECT * INTO v_c FROM review_cycles WHERE id = p_cycle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CYCLE_NOT_FOUND|%', COALESCE(p_cycle_id::text, '?');
    END IF;
    IF v_c.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'CYCLE_NOT_FOUND|%', v_c.name;
    END IF;
    IF v_c.status = 'closed' THEN
        RAISE EXCEPTION 'CYCLE_CLOSED|%', v_c.name;
    END IF;

    WITH ins AS (
        INSERT INTO performance_reviews
            (employee_id, review_type, cycle_id, period_start, period_end,
             reviewer_employee_id, status)
        SELECT e.id, 'annual', v_c.id, v_c.period_start, v_c.period_end,
               -- 【E2 三级解析】部门经理 → 本人就是部门经理时取【上级部门】的经理
               -- → 再不行留 NULL(E3 的提醒会把它顶出来,不会悄悄躺着)。
               -- 每一级都排除"解析到本人",因为自己不能评自己(表上的 check 也会拦)。
               -- PROBATION-1:这一段抽成了 resolve_review_reviewer(),两个入口共读。
               resolve_review_reviewer(e.id),
               'draft'
        FROM employees e
        LEFT JOIN departments d  ON d.id = e.department_id
        LEFT JOIN departments pd ON pd.id = d.parent_department_id
        WHERE e.deleted_at IS NULL
          -- 【'active' = 在职且已转正】。probation 与 separated 按题意排除;
          -- 'notice'(在离职通知期内)同样不生成。
          AND e.employment_status = 'active'
          -- 【E1 免评估的整个跳过】不建评估,也就不会有"没有评估人"的提醒。
          AND NOT e.review_exempt
          AND NOT EXISTS (
              SELECT 1 FROM performance_reviews pr
              WHERE pr.employee_id = e.id AND pr.cycle_id = v_c.id AND pr.status <> 'void')
        RETURNING 1
    )
    SELECT count(*) INTO v_created FROM ins;

    UPDATE review_cycles SET status = 'open' WHERE id = p_cycle_id AND status <> 'open';

    SELECT count(*), count(*) FILTER (WHERE reviewer_employee_id IS NULL)
    INTO v_total, v_noreviewer
    FROM performance_reviews WHERE cycle_id = p_cycle_id AND status <> 'void';

    SELECT count(*) INTO v_exempt FROM employees
    WHERE deleted_at IS NULL AND employment_status = 'active' AND review_exempt;

    RETURN jsonb_build_object(
        'cycle_id', p_cycle_id, 'cycle_name', v_c.name, 'status', 'open',
        'created', v_created, 'total_reviews', v_total,
        -- 【故意留在返回值里】没有评估人的份数是要有人去处理的,不是可以忽略的余数。
        'without_reviewer', v_noreviewer,
        'skipped_review_exempt', v_exempt);
END;
$function$;

-- ─── open_probation_review
-- db/functions/open_probation_review.sql
-- PROBATION-1(2026-08-27):试用期转正评估的【那扇门】—— 在它之前一扇都没有。
--
-- 【它之前有多缺】performance_reviews 的唯一写入者是 open_review_cycle,
-- 而那支只造 review_type='annual' 且明确排除试用期员工;
-- performance_reviews_cycle_shape 要求 probation ⇒ cycle_id IS NULL,
-- 而它永远写 cycle_id —— 所以它在结构上也造不出一份试用期评估。
-- app 里没有任何一处 INSERT performance_reviews(saveHrDecision 只 UPDATE)。
-- ★ 最尖锐的证据:冒烟脚本必须【直接 POST 到 REST】才造得出那一行来测页面。★
--
-- 【为什么不是给 open_review_cycle 加参数】见函数注释:两种形状,不是一种的变体。
-- 【期间不编默认值】probation_end_date 为空就按名拒 —— 那个日期正是转正决定
-- 依据的事实本身。实测线上 4 个试用期员工【全部】没有填。
--
-- NOTE: introduced by db/migrations/2026-08-27-probation1-a-door-for-the-probation-review.sql.

CREATE OR REPLACE FUNCTION public.open_probation_review(p_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_e        employees%ROWTYPE;
    v_id       uuid := gen_random_uuid();
    v_reviewer uuid;
    v_ex_id    uuid;
    v_ex_stat  text;
BEGIN
    -- 与 open_review_cycle 同一道门:发起一次转正评估是 HR 的动作。
    PERFORM require_permission('action.hr_reviews');

    SELECT * INTO v_e FROM employees
     WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', COALESCE(p_employee_id::text, '?');
    END IF;

    -- 【只对在试用期的人成立】转正评估对一个已转正/已离职的人没有意义,
    -- 而 approve_review 的 confirm 分支会去改 employment_status —— 对着错的人跑
    -- 会把一个已经在职的人重新"转正"一次。
    IF v_e.employment_status <> 'probation' THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_ON_PROBATION|%|%', v_e.code, v_e.employment_status;
    END IF;

    -- ★【不给日期编默认值】★ period_start / period_end 是 NOT NULL,
    -- 而 probation_end_date 可以为空(实测线上 4 个试用期员工【全部】为空)。
    -- 拿 CURRENT_DATE 顶上去,就是替人凭空定下试用期的终点 ——
    -- 而那个日期正是转正决定所依据的事实本身,也是 hr_alerts 三支的锚点。
    -- 本仓库对"决定期间的日期"已经有一条规矩:要么有,要么按名拒,绝不默认。
    IF v_e.probation_end_date IS NULL THEN
        RAISE EXCEPTION 'PROBATION_END_DATE_NOT_SET|%', v_e.code;
    END IF;

    -- period_end >= period_start 是表上的 CHECK(performance_reviews_period_shape)。
    -- 先在这里按名拒,免得读到的是一串约束名。
    IF v_e.probation_end_date < v_e.hire_date THEN
        RAISE EXCEPTION 'PROBATION_PERIOD_INVALID|%|%|%',
            v_e.code, v_e.hire_date::text, v_e.probation_end_date::text;
    END IF;

    SELECT id, status INTO v_ex_id, v_ex_stat
      FROM performance_reviews
     WHERE employee_id = p_employee_id
       AND review_type = 'probation'
       AND status <> 'void'
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'PROBATION_REVIEW_EXISTS|%|%', v_e.code, v_ex_stat;
    END IF;

    v_reviewer := resolve_review_reviewer(p_employee_id);

    INSERT INTO performance_reviews
        (id, employee_id, review_type, cycle_id, period_start, period_end,
         reviewer_employee_id, status, created_by)
    VALUES (v_id, p_employee_id, 'probation', NULL, v_e.hire_date, v_e.probation_end_date,
            v_reviewer, 'draft', auth.uid());

    RETURN jsonb_build_object(
        'review_id',            v_id,
        'employee_code',        v_e.code,
        'period_start',         v_e.hire_date,
        'period_end',           v_e.probation_end_date,
        'reviewer_employee_id', v_reviewer,
        -- 【解析不出评估人不是失败】它是一件要被看见的事,所以照直报出来,
        -- 由 hr_alerts 的 review_no_reviewer 一支接手催。
        'reviewer_resolved',    (v_reviewer IS NOT NULL),
        'status',               'draft');
END;
$function$;

COMMENT ON FUNCTION public.open_probation_review(uuid) IS
    'PROBATION-1:从产品内部造出一份试用期评估 —— 这条路此前【一扇门都没有】(open_review_cycle 只造 annual 且排除试用期员工;cycle_shape 要求 probation ⇒ cycle_id IS NULL,所以它结构上也造不出;app 里没有任何一处 INSERT performance_reviews;冒烟必须直接 POST 到 REST 才测得了页面)。期间 = hire_date → probation_end_date,【取不到就按名拒】(PROBATION_END_DATE_NOT_SET)——替人编一个试用期终点,就是凭空造出转正决定所依据的那个事实。评估人走 resolve_review_reviewer(与年度轮同一处),解析不出留 NULL 并如实报出,由 hr_alerts 的 review_no_reviewer 接手。五条按名拒绝:EMPLOYEE_NOT_FOUND / EMPLOYEE_NOT_ON_PROBATION / PROBATION_END_DATE_NOT_SET / PROBATION_PERIOD_INVALID / PROBATION_REVIEW_EXISTS。人工发起,不自动生成(Tim 2026-08-27):一行写着某人名字、还指派了评估人的记录自己冒出来,不是一件小事。';

-- ─── set_review_reviewer
-- db/functions/set_review_reviewer.sql
-- 补上/更换评估人。module.hr.edit;拒绝自评,也拒绝把已离职的人设成评估人。
-- 补上之后 hr_alerts 的 review_no_reviewer 【自动消失】—— 那条提醒是派生的,不是存储的,
-- 所以不存在"改了数据忘了清提醒"这种状态。
--
-- NOTE: introduced by db/migrations/2026-08-04-hr3b-salary-basis-and-review-visibility.sql.

CREATE OR REPLACE FUNCTION public.set_review_reviewer(p_review_id uuid, p_reviewer_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r   performance_reviews%ROWTYPE;
    v_rev record;
BEGIN
    PERFORM require_permission('action.hr_reviews');

    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;
    IF v_r.status = 'void' THEN
        RAISE EXCEPTION 'REVIEW_ALREADY_VOID|%', p_review_id;
    END IF;

    IF p_reviewer_employee_id IS NULL THEN
        RAISE EXCEPTION 'REVIEWER_REQUIRED';
    END IF;
    IF p_reviewer_employee_id = v_r.employee_id THEN
        RAISE EXCEPTION 'SELF_REVIEW_FORBIDDEN';
    END IF;

    SELECT id, code, employment_status INTO v_rev
    FROM employees WHERE id = p_reviewer_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
    IF v_rev.employment_status = 'separated' THEN
        RAISE EXCEPTION 'REVIEWER_SEPARATED|%', v_rev.code;
    END IF;

    UPDATE performance_reviews
    SET reviewer_employee_id = p_reviewer_employee_id
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id,
                              'reviewer_employee_id', p_reviewer_employee_id,
                              'reviewer_code', v_rev.code,
                              'previous_reviewer', v_r.reviewer_employee_id);
END;
$function$;
;

-- ─── void_review
-- db/functions/void_review.sql
-- 作废评估。评估是单据:更正靠【作废 + 重开】,不靠改一份已批准的(同发票那一套)。
-- 【作废不回滚已经发生的雇佣事实】—— 转正与调薪已经写进 employees 与不可变的
-- employment_history。要改那些,靠新的评估或 HR 手工更正再补一行,不靠把历史抹掉。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3a-performance-reviews.sql.

CREATE OR REPLACE FUNCTION public.void_review(p_review_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r performance_reviews%ROWTYPE;
BEGIN
    PERFORM require_permission('action.hr_reviews');

    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;
    IF v_r.status = 'void' THEN
        RAISE EXCEPTION 'REVIEW_ALREADY_VOID|%', p_review_id;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    UPDATE performance_reviews
    SET status = 'void', void_reason = btrim(p_reason),
        voided_at = now(), voided_by = auth.uid()
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'void',
                              'previous_status', v_r.status,
                              'employment_facts_unchanged', true);
END;
$function$;
;

-- ─── score_kpi_entry
-- db/functions/score_kpi_entry.sql
-- KPI-1:给一条 KPI 打分 —— 0–5,并说清这个分是【算出来的】还是【人判的】(§10.2)。
--
-- ★【安全/监管否决是一个【封顶】动作,不是一个分数】★(原表第六页)
--   「Major breach can cap score at 0–2 depending on severity」、
--   「Critical control gap may cap at 2」、「Any unauthorized operation = 0」。
--   **封顶不覆盖原始判断**:score 与 override_cap 都留着,
--   于是事后分得清「他本来就只有 2 分」与「他被封到 2 分」——
--   这两句话在一次复盘里意思完全不同,而一个只存最终分的实现说不出后一句。
--   生效分 = LEAST(score, override_cap),由视图算,不另存(算得出来的不存)。
--
-- ★★【C-2(2026-09-05)加了两样,而其中一样是一道新的门】★★
--   ① `p_feedback_note` —— Sandra 录三样:分数、证据、反馈。
--      evidence_note 回答「凭什么是这个分」,feedback_note 回答「要跟他说什么」。
--   ② ★【locked_at:锁 ≠ 关】★ 此前只有 `status='closed'`,而它【同时】
--      做两件事:拒绝写入(冻结)与把分数放给本人看(揭晓)。Tim 的裁定是
--      「一个月在它的关口锁上之前一直可改」+「M3 关口锁住第 1–3 个月」——
--      一个 flag 表达不了:为了冻结而 close 会把分数提前揭晓给每个人,
--      不 close 则前两个月永远冻不住。所以拆成两个概念,而**锁那一道排在前面**:
--      被锁住的月份抛 KPI_CYCLE_LOCKED 而不是 KPI_CYCLE_CLOSED,
--      因为「重开周期」不是解决它的办法。
--
-- ★【签名变了要 DROP + CREATE,不是 CREATE OR REPLACE】★ 参数表变了就是另一个
--   签名,CREATE OR REPLACE 会留下【两个】同名函数(FIN-21 那次漂移)。
--   preflight_migration.py 正是为拒绝这件事而存在,而它认得同一支迁移里
--   出现在 CREATE 之前的 DROP —— 那是它放行的那条路。
--
-- NOTE: introduced by db/migrations/2026-08-29-kpi1-positions-and-the-kpi-framework.sql;
--       feedback + lock by db/migrations/2026-09-05-c2-hire-dates-holiday-identity-and-kpi-entry.sql.

CREATE OR REPLACE FUNCTION public.score_kpi_entry(p_entry_id uuid, p_score integer, p_score_kind text DEFAULT 'judged'::text, p_evidence_note text DEFAULT NULL::text, p_feedback_note text DEFAULT NULL::text, p_computed_basis text DEFAULT NULL::text, p_override_cap integer DEFAULT NULL::integer, p_override_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_e     kpi_entries%ROWTYPE;
    v_cycle kpi_cycles%ROWTYPE;
BEGIN
    PERFORM require_permission('action.hr_reviews');

    SELECT * INTO v_e FROM kpi_entries WHERE id = p_entry_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KPI_ENTRY_NOT_FOUND|%', p_entry_id; END IF;
    SELECT * INTO v_cycle FROM kpi_cycles WHERE id = v_e.cycle_id;

    -- ★★【锁在前,关在后 —— 两道分开的门,两句分开的话】★★
    --   锁是关口按下的冻结(M3 锁 1–3 月);关是"这个月结束了,分数对本人揭晓"。
    --   一个被锁住的月份说"被关口锁了",而不是"已经关了" —— 后者会让人以为
    --   去重开周期就能改,而那不是这里发生的事。
    IF v_cycle.locked_at IS NOT NULL THEN
        RAISE EXCEPTION 'KPI_CYCLE_LOCKED|%|%', v_cycle.name, COALESCE(v_cycle.gate, '')
          USING HINT = '这个月已被关口锁住 —— 一道过后还能靠改那个月推翻的关口,不是关口。要改先解锁,那一步会留痕';
    END IF;
    IF v_cycle.status = 'closed' THEN
        RAISE EXCEPTION 'KPI_CYCLE_CLOSED|%', v_cycle.name
          USING HINT = '这个周期已经关了 —— 改一个关掉的周期里的分数是在改历史,要改先重开周期,那一步会留痕';
    END IF;

    IF p_score IS NULL OR p_score < 0 OR p_score > 5 THEN
        RAISE EXCEPTION 'KPI_SCORE_OUT_OF_RANGE|%', COALESCE(p_score::text, 'null')
          USING HINT = '打分是 0–5 的整数(原表第六页逐档定义了 5/4/3/2/1/0,没有小数档)';
    END IF;
    IF p_score_kind IS NULL OR p_score_kind NOT IN ('judged','computed') THEN
        RAISE EXCEPTION 'KPI_SCORE_KIND_INVALID|%', COALESCE(p_score_kind, 'null')
          USING HINT = '一个分数要说出它是【算出来的】还是【人判的】—— 两者可靠性差着一个数量级,而屏幕上必须长得不一样(规格 §10.2)';
    END IF;
    IF p_score_kind = 'computed'
       AND NULLIF(btrim(COALESCE(p_computed_basis, '')), '') IS NULL THEN
        RAISE EXCEPTION 'KPI_COMPUTED_NEEDS_BASIS|%', v_e.kpi_ref
          USING HINT = '标成【算出来的】就要写清它算的是什么(哪几次盘点、哪张账龄、截至哪一天)—— 否则 computed 只是一个更好看的标签';
    END IF;
    IF p_override_cap IS NOT NULL
       AND NULLIF(btrim(COALESCE(p_override_reason, '')), '') IS NULL THEN
        RAISE EXCEPTION 'KPI_OVERRIDE_NEEDS_REASON|%', v_e.kpi_ref
          USING HINT = '安全/监管否决要写明是哪一件事(原表:major breach 可封到 0–2、unauthorized operation = 0)—— 没有理由的封顶,事后与一次低分长得一模一样';
    END IF;
    IF p_override_cap IS NOT NULL AND (p_override_cap < 0 OR p_override_cap > 5) THEN
        RAISE EXCEPTION 'KPI_SCORE_OUT_OF_RANGE|%', p_override_cap; END IF;

    UPDATE kpi_entries
       SET score = p_score,
           score_kind = p_score_kind,
           computed_basis = NULLIF(btrim(COALESCE(p_computed_basis, '')), ''),
           evidence_note = NULLIF(btrim(COALESCE(p_evidence_note, '')), ''),
           feedback_note = NULLIF(btrim(COALESCE(p_feedback_note, '')), ''),
           override_cap = p_override_cap,
           override_reason = NULLIF(btrim(COALESCE(p_override_reason, '')), ''),
           scored_by = auth.uid(), scored_at = now(),
           updated_at = now(), updated_by = auth.uid()
     WHERE id = p_entry_id;

    RETURN jsonb_build_object(
        'entry_id', p_entry_id,
        'kpi_ref', v_e.kpi_ref,
        'score', p_score,
        'score_kind', p_score_kind,
        'effective_score', LEAST(p_score, COALESCE(p_override_cap, 5)),
        'capped', (p_override_cap IS NOT NULL AND p_override_cap < p_score),
        'weighted', round(LEAST(p_score, COALESCE(p_override_cap, 5))::numeric / 5 * v_e.weight_pct, 2));
END;
$function$;

-- ─── assign_position_kpis
-- db/functions/assign_position_kpis.sql
-- KPI-1:把一个职位的五条模板【复制】到一个人名下(规格 §11 第 5 步、§8.3)。
--
-- ★★【复制,不是引用 —— 这支函数就是那句话的实现】★★
--   每一个来自模板的字段都在这里被**读出来、写进去**。写完之后,
--   kpi_entries 那一行与 kpi_position_templates 那一行【再无内容上的联系】:
--   改模板不动副本。source_template_id / source_template_version 只用来回答
--   "它从哪儿来、是哪一版",**任何读取路径都不许拿它回查内容** ——
--   一旦有人那么写,复制就退化成了引用,而退化是静悄悄的。
--
-- 【为什么权重在这里【再查一次】,尽管表上已经有 DEFERRABLE 闸】
--   那道闸守的是【写模板】那条路。这支函数是【读模板】——
--   而模板可能是在闸建起来之前就存在的、也可能被将来某条新路径绕过。
--   复制一份合计不是 100 的模板出去,人名下那五条就永远算不出可比的分数,
--   **而它算得出数、不报错**。所以这里按名拒,不猜。
--   (「闸要拦在今天所有的入口上」——AGENTS.md 记过两次的那条。)

CREATE OR REPLACE FUNCTION public.assign_position_kpis(p_employee_id uuid, p_cycle_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    employees%ROWTYPE;
    v_pos    positions%ROWTYPE;
    v_cycle  kpi_cycles%ROWTYPE;
    v_total  numeric;
    v_n      integer := 0;
    v_t      record;
    v_codes  text[];
BEGIN
    -- 【SECURITY DEFINER 自己查权限】属主权限绕过 RLS,所以这一句不是礼节。
    PERFORM require_permission('action.hr_reviews');

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', p_employee_id;
    END IF;
    SELECT * INTO v_cycle FROM kpi_cycles WHERE id = p_cycle_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'KPI_CYCLE_NOT_FOUND|%', p_cycle_id;
    END IF;
    IF v_cycle.status = 'closed' THEN
        RAISE EXCEPTION 'KPI_CYCLE_CLOSED|%', v_cycle.name
          USING HINT = '这个周期已经关了 —— 往一个关掉的周期里生成条目,等于事后给一段已经结束的考核补标准';
    END IF;

    -- 【没有职位就没有模板可抄】而这条拒绝要指路,不是一句"失败"。
    IF v_emp.position_id IS NULL THEN
        RAISE EXCEPTION 'EMPLOYEE_HAS_NO_POSITION|%', v_emp.code
          USING HINT = 'KPI 绑在职位上,不绑在人上(规格 §8.1)—— 先到【人事 → 员工】给这个人指定一个职位,他名下的五条才有来源';
    END IF;
    SELECT * INTO v_pos FROM positions WHERE id = v_emp.position_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'POSITION_NOT_FOUND|%', v_emp.position_id;
    END IF;

    -- 【已经生成过就按名拒,不悄悄再来一遍】重复生成会造出第二组条目,
    -- 而 UNIQUE(cycle_id, employee_id, kpi_ref) 会用一个裸约束名把它挡下来 ——
    -- 裸约束违例到了浏览器上是一串机器码。这里先说人话。
    SELECT count(*) INTO v_n FROM kpi_entries
     WHERE cycle_id = p_cycle_id AND employee_id = p_employee_id;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'KPI_ENTRIES_ALREADY_GENERATED|%|%|%', v_emp.code, v_cycle.name, v_n
          USING HINT = '这个人在这个周期里已经有条目了 —— 要换一套标准,先决定那已经存在的一套怎么办,不要在旁边再长出一套';
    END IF;

    -- ★【模板一条都没有 → 拒绝,而不是生成零条】★
    --   生成零条会成功返回,而屏幕上看起来"生成过了" —— 一个空集不是一次成功。
    SELECT count(*), COALESCE(SUM(weight_pct), 0) INTO v_n, v_total
      FROM kpi_position_templates WHERE position_id = v_pos.id;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'POSITION_HAS_NO_TEMPLATES|%', v_pos.code
          USING HINT = '这个职位还没有 KPI 模板 —— 生成零条会看起来像生成成功了,所以这里拒绝';
    END IF;
    -- 见抬头:闸要拦在今天所有的入口上。
    IF v_total <> 100 THEN
        RAISE EXCEPTION 'KPI_TEMPLATE_WEIGHTS_NOT_100|%|%', v_pos.code, v_total
          USING HINT = '这个职位的模板权重合计不是 100 —— 照它复制出去的五条永远算不出可比的分数,而它算得出数、不报错(规格 §9.3)';
    END IF;

    -- ★★ 逐条【抄】过去 ★★
    v_n := 0;
    FOR v_t IN
        SELECT * FROM kpi_position_templates WHERE position_id = v_pos.id ORDER BY sort_order, kpi_ref
    LOOP
        -- 链接也抄成快照数组 —— 见 kpi_entries.org_codes 的列注。
        SELECT array_agg(l.org_code ORDER BY l.org_code) INTO v_codes
          FROM kpi_template_org_links l WHERE l.template_id = v_t.id;
        -- 【一条不链任何组织 KPI 的模板是坏的】原表第三章每一条都有 `Linked Org KPI(s)`,
        -- 而 roll-up 与联动矩阵全靠它。抄出一条空链接,矩阵会静静少一格。
        IF v_codes IS NULL OR array_length(v_codes, 1) IS NULL THEN
            RAISE EXCEPTION 'KPI_TEMPLATE_HAS_NO_ORG_LINK|%|%', v_pos.code, v_t.kpi_ref
              USING HINT = '每一条个人 KPI 都要链到至少一条组织 KPI(原表第三章的 Linked Org KPI(s) 一列)—— 没有链接,联动矩阵会静静少一格';
        END IF;

        INSERT INTO kpi_entries (
            cycle_id, employee_id,
            source_position_id, source_template_id, source_template_version,
            kpi_ref, title, weight_pct, target_text, evidence_source,
            is_provisional, provisional_note, org_codes, created_by)
        VALUES (
            p_cycle_id, p_employee_id,
            v_pos.id, v_t.id, v_t.version,
            v_t.kpi_ref, v_t.title, v_t.weight_pct, v_t.target_text, v_t.evidence_source,
            v_t.is_provisional, v_t.provisional_note, v_codes, auth.uid());
        v_n := v_n + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'employee_code', v_emp.code,
        'position_code', v_pos.code,
        'cycle', v_cycle.name,
        'entries_created', v_n,
        -- 【把版本回给调用方】屏幕要说得出"这是照第几版模板抄的"
        'template_versions', (SELECT jsonb_object_agg(kpi_ref, version)
                                FROM kpi_position_templates WHERE position_id = v_pos.id));
END;
$function$;

COMMENT ON FUNCTION public.assign_position_kpis(uuid, uuid) IS
'KPI-1:把职位模板的五条【复制】到一个人名下(规格 §8.3、§11 第 5 步)。**每一个字段都是读出来再写进去的** —— 写完之后条目与模板再无内容上的联系,改模板不动副本;source_template_id/version 只回答"从哪儿来、哪一版",**任何读取路径都不许拿它回查内容**,一旦那么写,复制就静悄悄退化成了引用。权重在这里【再查一次】尽管表上已有 DEFERRABLE 闸:那道闸守的是写模板那条路,这支函数走的是读模板那条 ——「闸要拦在今天所有的入口上」。四条按名拒都带指路:没有职位、职位没有模板(生成零条会看起来像成功)、已经生成过、模板缺组织链接(矩阵会静静少一格)。';

-- ─── submit_review
CREATE OR REPLACE FUNCTION public.submit_review(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r      performance_reviews%ROWTYPE;
    v_goals  integer;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    IF NOT (has_permission('action.hr_reviews')
            OR is_reviewer_of(v_r.reviewer_employee_id)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.hr_reviews';
    END IF;

    -- self_review 是可选的一步,所以两个入口状态都收
    IF v_r.status NOT IN ('draft','self_review') THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    IF v_r.reviewer_employee_id IS NULL THEN
        RAISE EXCEPTION 'REVIEWER_REQUIRED';
    END IF;
    IF v_r.rating_code IS NULL THEN
        RAISE EXCEPTION 'RATING_REQUIRED';
    END IF;
    IF v_r.summary_text IS NULL OR btrim(v_r.summary_text) = '' THEN
        RAISE EXCEPTION 'SUMMARY_REQUIRED';
    END IF;
    IF v_r.review_type = 'probation' AND v_r.probation_outcome IS NULL THEN
        RAISE EXCEPTION 'PROBATION_OUTCOME_REQUIRED';
    END IF;

    SELECT count(*) INTO v_goals FROM review_goals WHERE review_id = p_review_id;
    IF v_goals = 0 THEN
        RAISE EXCEPTION 'GOALS_REQUIRED';
    END IF;

    UPDATE performance_reviews
    SET status = 'submitted', submitted_at = now(), submitted_by = auth.uid()
    WHERE id = p_review_id;

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('performance_review', p_review_id, 'submitted', NULL, NULL);

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'submitted',
                              'rating_code', v_r.rating_code, 'goals', v_goals);
END;
$function$;

-- ─── set_goal_actual_value
-- db/functions/set_goal_actual_value.sql
-- 评估人或 HR 在 draft / submitted 阶段填目标的实际值。
-- 【自评阶段不走这里】那时 actual_value 归本人写。只写 actual_value,碰不到 target_value 与 unit。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3d-reviewer-write-path.sql;

CREATE OR REPLACE FUNCTION public.set_goal_actual_value(p_goal_id uuid, p_actual_value numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_g review_goals%ROWTYPE;
    v_r performance_reviews%ROWTYPE;
BEGIN
    SELECT * INTO v_g FROM review_goals WHERE id = p_goal_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'GOAL_NOT_FOUND|%', COALESCE(p_goal_id::text,'?'); END IF;
    SELECT * INTO v_r FROM performance_reviews WHERE id = v_g.review_id;

    IF NOT (has_permission('action.hr_reviews')
            OR is_reviewer_of(v_r.reviewer_employee_id)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.hr_reviews';
    END IF;

    IF v_r.status NOT IN ('draft','submitted') THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    UPDATE review_goals SET actual_value = p_actual_value WHERE id = p_goal_id;

    RETURN jsonb_build_object('goal_id', p_goal_id, 'actual_value', p_actual_value,
                              'review_id', v_g.review_id, 'status', v_r.status);
END;
$function$;
;

-- ─── open_for_self_assessment
-- db/functions/open_for_self_assessment.sql
-- 开启(或【重开】)自评:评估人或 module.hr.edit,draft / self_review → self_review。
-- 已定稿的自评从这里重开(清掉 self_assessment_submitted_at)—— 重开是评估人的决定。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3d-reviewer-write-path.sql;

CREATE OR REPLACE FUNCTION public.open_for_self_assessment(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r        performance_reviews%ROWTYPE;
    v_reopened boolean := false;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    IF NOT (has_permission('action.hr_reviews')
            OR is_reviewer_of(v_r.reviewer_employee_id)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.hr_reviews';
    END IF;

    IF v_r.status NOT IN ('draft','self_review') THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    v_reopened := (v_r.status = 'self_review' AND v_r.self_assessment_submitted_at IS NOT NULL);

    UPDATE performance_reviews
    SET status = 'self_review', self_assessment_submitted_at = NULL
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'self_review',
                              'previous_status', v_r.status, 'reopened', v_reopened);
END;
$function$;
;

-- ─── require_reviewer_of
-- db/functions/require_reviewer_of.sql
-- 评估人写入路径的共用守卫:调用者是这一行的评估人(或持 module.hr.edit),
-- 且评估处在允许的状态。返回那一行,免得每个函数各查一次、各看到不同的行。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3d-reviewer-write-path.sql;

CREATE OR REPLACE FUNCTION public.require_reviewer_of(p_review_id uuid, p_allowed_status text[])
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- %ROWTYPE 在【函数体】里,check_function_bodies=off 豁免的正是这里,所以没问题。
DECLARE v_r performance_reviews%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;
    IF NOT (has_permission('action.hr_reviews')
            OR is_reviewer_of(v_r.reviewer_employee_id)) THEN
        RAISE EXCEPTION 'NOT_REVIEW_REVIEWER';
    END IF;
    IF NOT (v_r.status = ANY (p_allowed_status)) THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;
END;
$function$;
;

-- ─── approve_review
CREATE OR REPLACE FUNCTION public.approve_review(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r        performance_reviews%ROWTYPE;
    v_emp      employees%ROWTYPE;
    v_period   text;
    v_old_sal  numeric;
    v_conf     date;
    v_confirmed boolean := false;
    v_salaried  boolean := false;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    -- ★ ROLE-1(Tim 的矩阵,2026-09-23):批评估的是 CFO;CFO 是这张评估的
    --   提交人或主角时,改由 cco 批。【谁批】只有一份定义:review_approval_code。
    --   它要先读到这一行才答得出,所以门排在 SELECT 之后。
    PERFORM require_permission(review_approval_code(v_r.submitted_by, v_r.employee_id));
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    -- 【四眼原则】与"评估人不能是本人"是两条不同的规则:一条防自我评价
    -- (表上的 CHECK:reviewer_employee_id IS DISTINCT FROM employee_id),
    -- 这一条防自我批准。
    --
    -- ★★ APR-2 把它换成了全库唯一的那支判据,而这【不是】重构 ——
    -- 它补上了本函数缺的那条腿。此前只拒 submitted_by,于是这条路一直是通的:
    --   【别人提交、被评的那位自己批准】。
    -- 而本函数会写 employees.monthly_salary 与一行 employment_history 调薪记录,
    -- 也就是说 **一个人批得了自己的加薪**。线上三个持 module.hr.edit 的人
    -- 全部是在册员工(实测 2026-09-22),所以它不是理论上的。
    PERFORM forbid_self_approval(v_r.submitted_by, v_r.employee_id, 'performance_review');

    SELECT * INTO v_emp FROM employees WHERE id = v_r.employee_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    UPDATE performance_reviews
    SET status = 'approved', approved_at = now(), approved_by = auth.uid()
    WHERE id = p_review_id;

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('performance_review', p_review_id, 'approved', NULL, NULL);

    -- ── 试用期转正 ────────────────────────────────────────────────────────
    IF v_r.review_type = 'probation' AND v_r.probation_outcome = 'confirm' THEN
        IF v_emp.employment_status = 'separated' THEN
            RAISE EXCEPTION 'EMPLOYEE_SEPARATED|%', v_emp.code;
        END IF;
        v_conf := COALESCE(v_emp.probation_end_date, CURRENT_DATE);

        UPDATE employees
        SET employment_status = 'active',      -- 【没有 'confirmed' 这个状态,见文件头 (2)】
            confirmation_date = v_conf
        WHERE id = v_emp.id;

        -- 【恰好一行】履历。
        INSERT INTO employment_history
            (employee_id, effective_date, change_type, job_title, department_id,
             employment_type, employment_status, notes)
        VALUES (v_emp.id, v_conf, 'confirmed',
                -- KPI-1:履历存的是【当时那个职位的名称文本】,不是指针
                (SELECT p.title FROM positions p WHERE p.id = v_emp.position_id),
                v_emp.department_id,
                v_emp.employment_type, 'active',
                format('Probation confirmed by performance review %s', p_review_id));

        -- 【假期台账一个字都不写】年假的解锁是读时按 employment_status 派生的
        -- (submit_leave_request 的 PROBATION_NO_ANNUAL_LEAVE)。在这里补一笔授予
        -- 就是 HR-2a 结转重复计数的翻版。见文件头 (1)。
        v_confirmed := true;
    END IF;

    -- ── 不予转正:【什么都不改】 ──────────────────────────────────────────
    -- 决定记在评估单据上,提醒由 hr_alerts 的 probation_not_confirmed 一支发出。
    -- 【绝不把在职状态改成 separated,也绝不触发任何离职逻辑】——
    -- 离职是手工流程:人一旦 separated 就掉出工资表,而最后一个月的工资还没录。
    -- 先掉出去,那笔钱就再也发不出来了。

    -- ── 调薪 ──────────────────────────────────────────────────────────────
    IF v_r.new_monthly_salary IS NOT NULL THEN
        -- payroll_periods 没有起止两列:周期就是 period_month 那个整月(见文件头 (4))
        SELECT p.code INTO v_period
        FROM payroll_periods p
        WHERE p.deleted_at IS NULL AND p.status = 'posted'
          AND v_r.salary_effective_date >= p.period_month
          AND v_r.salary_effective_date < (p.period_month + interval '1 month')::date
        ORDER BY p.period_month
        LIMIT 1;

        IF v_period IS NOT NULL THEN
            -- 【连同上面的转正一起回滚】总账已经认了那个月的工资,
            -- 追改一个已过账周期里的薪酬会让账实不符。
            RAISE EXCEPTION 'SALARY_EFFECTIVE_IN_POSTED_PERIOD|%', v_period;
        END IF;

        v_old_sal := v_emp.monthly_salary;

        UPDATE employees SET monthly_salary = v_r.new_monthly_salary WHERE id = v_emp.id;

        INSERT INTO employment_history
            (employee_id, effective_date, change_type, job_title, department_id,
             employment_type, employment_status, old_monthly_salary, new_monthly_salary, notes)
        SELECT e.id, v_r.salary_effective_date, 'salary_change',
               (SELECT p.title FROM positions p WHERE p.id = e.position_id), e.department_id,
               e.employment_type, e.employment_status, v_old_sal, v_r.new_monthly_salary,
               format('Salary change approved with performance review %s', p_review_id)
        FROM employees e WHERE e.id = v_emp.id;

        v_salaried := true;
    END IF;

    RETURN jsonb_build_object(
        'review_id', p_review_id, 'status', 'approved',
        'employee_code', v_emp.code,
        'review_type', v_r.review_type,
        'probation_outcome', v_r.probation_outcome,
        'confirmed', v_confirmed,
        'confirmation_date', v_conf,
        'salary_changed', v_salaried,
        'old_monthly_salary', v_old_sal,
        'new_monthly_salary', v_r.new_monthly_salary,
        'salary_effective_date', v_r.salary_effective_date);
END;
$function$;

-- ─── decide_leave_request
CREATE OR REPLACE FUNCTION public.decide_leave_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_req    record;
    v_type   record;
    v_need   numeric;
    v_take   numeric;
    v_bal    jsonb;
    v_avail  numeric;
    v_accrual numeric;
    g        record;
    v_used   jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('action.decide_hr_requests');

    SELECT * INTO v_req FROM leave_requests WHERE id = p_request_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'REQUEST_NOT_FOUND'; END IF;
    IF v_req.status <> 'pending' THEN RAISE EXCEPTION 'REQUEST_NOT_PENDING|%', v_req.status; END IF;

    -- ★ APR-2:四眼。此前这条链【一条自批判据都没有】——
    -- 一个持 module.hr.edit 的人批得了自己的假(APR-0 §1.5 实测)。
    -- 两条腿,判据只有一份定义(见 forbid_self_approval 的抬头):
    --   ① 提这张单的人;② 这张单【说的是谁】。
    -- ★ 第二条在这里是承重的:HR 可以【代人】提单,那时 created_by 是 HR、
    --   employee_id 是员工本人 —— 只判第一条的话,那位员工(若他持
    --   module.hr.edit)照样批得了自己的假。
    PERFORM forbid_self_approval(v_req.created_by, v_req.employee_id, 'leave_request');

    SELECT * INTO v_type FROM leave_types WHERE code = v_req.leave_type_code;

    IF NOT p_approve THEN
        UPDATE leave_requests SET status='rejected', decided_at=now(), decided_by=auth.uid(),
               decision_notes=p_notes, updated_by=auth.uid()
        WHERE id = p_request_id;

        -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
        -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
        PERFORM record_approval_decision('leave_request', p_request_id, 'rejected', NULL, p_notes);
        RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','rejected');
    END IF;

    IF v_type.is_accrued THEN
        v_bal := leave_balance(v_req.employee_id, v_req.leave_type_code, v_req.start_date);
        v_avail := (v_bal->>'available')::numeric;
        IF v_avail < v_req.days THEN
            RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE|%|%',
                trim_scale(v_avail), trim_scale(v_req.days);
        END IF;

        v_need := v_req.days;
        -- ══════════════════════════════════════════════════════════════════
        -- 【先用旧的】:按 expires_on 从早到晚扣。
        -- 结转来的行有失效日,当年累积没有 —— 所以结转天数天然排在前面被先吃掉,
        -- 反过来的话它们会先烂掉,对员工是净损失。
        -- ══════════════════════════════════════════════════════════════════
        FOR g IN
            SELECT gr.id, gr.days, gr.expires_on, gr.leave_year, gr.grant_type,
                   gr.days
                   - COALESCE((SELECT SUM(CASE WHEN c.entry_type='draw' THEN c.days ELSE -c.days END)
                               FROM leave_consumption c WHERE c.leave_grant_id = gr.id), 0)
                   - COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                               WHERE cf.source_grant_id = gr.id AND cf.grant_type = 'carry_forward'
                                 AND cf.deleted_at IS NULL), 0) AS remaining
            FROM leave_grants gr
            WHERE gr.employee_id = v_req.employee_id AND gr.leave_type_code = v_req.leave_type_code
              AND gr.deleted_at IS NULL AND gr.granted_on <= v_req.start_date
              AND (gr.expires_on IS NULL OR gr.expires_on >= v_req.start_date)
            ORDER BY gr.expires_on NULLS LAST, gr.granted_on
        LOOP
            EXIT WHEN v_need <= 0;
            IF g.remaining <= 0 THEN CONTINUE; END IF;
            v_take := LEAST(g.remaining, v_need);
            INSERT INTO leave_consumption (leave_request_id, leave_grant_id, entry_type, days)
            VALUES (p_request_id, g.id, 'draw', v_take);
            v_need := v_need - v_take;
            v_used := v_used || jsonb_build_object('source', 'grant', 'grant_id', g.id,
                                                   'leave_year', g.leave_year,
                                                   'grant_type', g.grant_type,
                                                   'expires_on', g.expires_on, 'days', v_take);
        END LOOP;

        -- 结转吃完了还不够 → 从当年度的派生累积里扣(记 accrual_year,不挂授予行)
        IF v_need > 0 AND v_type.is_accrued THEN
            v_accrual := available_annual_accrual(v_req.employee_id, v_req.start_date);
            v_take := LEAST(v_accrual, v_need);
            IF v_take > 0 THEN
                INSERT INTO leave_consumption (leave_request_id, leave_grant_id, entry_type, days, accrual_year)
                VALUES (p_request_id, NULL, 'draw', v_take,
                        EXTRACT(YEAR FROM v_req.start_date)::integer);
                v_need := v_need - v_take;
                v_used := v_used || jsonb_build_object('source', 'accrual',
                                                       'leave_year', EXTRACT(YEAR FROM v_req.start_date)::integer,
                                                       'grant_type', 'monthly_accrual',
                                                       'expires_on', NULL, 'days', v_take);
            END IF;
        END IF;

        IF v_need > 0 THEN
            RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE|%|%',
                trim_scale(v_req.days - v_need), trim_scale(v_req.days);
        END IF;
    END IF;

    UPDATE leave_requests SET status='approved', decided_at=now(), decided_by=auth.uid(),
           decision_notes=p_notes, updated_by=auth.uid()
    WHERE id = p_request_id;

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('leave_request', p_request_id, 'approved', NULL, p_notes);

    RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','approved',
                              'days', v_req.days, 'consumed_from', v_used);
END;
$function$;

-- ─── decide_medical_claim
CREATE OR REPLACE FUNCTION public.decide_medical_claim(p_claim_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_claim record; v_bal jsonb; v_remaining numeric;
BEGIN
    PERFORM require_permission('action.decide_hr_requests');

    SELECT * INTO v_claim FROM medical_claims WHERE id = p_claim_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CLAIM_NOT_FOUND'; END IF;
    IF v_claim.status <> 'submitted' THEN RAISE EXCEPTION 'CLAIM_NOT_SUBMITTED|%', v_claim.status; END IF;

    -- ★ APR-2:四眼,与 decide_leave_request 逐字同一支判据、同样两条腿。
    -- 这条链此前也一条都没有 —— 而它【是真的在批钱】(amount_sgd)。
    PERFORM forbid_self_approval(v_claim.created_by, v_claim.employee_id, 'medical_claim');

    IF NOT p_approve THEN
        UPDATE medical_claims SET status='rejected', decided_at=now(), decided_by=auth.uid(),
               decision_notes=p_notes, updated_by=auth.uid() WHERE id = p_claim_id;

        -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
        -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
        PERFORM record_approval_decision('medical_claim', p_claim_id, 'rejected', NULL, p_notes);
        RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_claim.code, 'status','rejected');
    END IF;

    v_bal := medical_claim_balance(v_claim.employee_id, v_claim.claim_year);
    v_remaining := (v_bal->>'remaining_sgd')::numeric;
    IF v_claim.amount_sgd > v_remaining THEN
        RAISE EXCEPTION 'CLAIM_EXCEEDS_LIMIT|%|%', v_remaining, v_claim.amount_sgd;
    END IF;

    UPDATE medical_claims SET status='approved', decided_at=now(), decided_by=auth.uid(),
           decision_notes=p_notes, updated_by=auth.uid() WHERE id = p_claim_id;

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('medical_claim', p_claim_id, 'approved', NULL, p_notes);

    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_claim.code, 'status','approved',
                              'amount_sgd', v_claim.amount_sgd,
                              'remaining_after', v_remaining - v_claim.amount_sgd,
                              -- 与补偿一样,把"没有入账"写进返回值,免得调用方以为记过账了
                              'expense_posted', false,
                              'note', 'No expense is posted. Reimbursement route (payroll vs separate payment) is an operational decision; link it via medical_claims.expense_id once chosen.');
END;
$function$;

-- ─── anonymise_employee
-- db/functions/anonymise_employee.sql
-- PDPA 的"目的结束后不再保留":把一名【已离职且保留期已满】的员工就地匿名化 ——
-- 覆盖身份列,行留着。与 Doc 2 原则 7 的调和见 docs/as-built-divergences.md 第 2 条;
-- 范围、待决项与那条法律问题见 docs/pdpa.md。
--
-- 【四条按名拒绝】PDPA_RETENTION_PERIOD_NOT_SET(最要紧的一条:保留期是法律问题,
-- 这支函数不用默认值替人回答;而 2026-08-24 的裁定让它成为【今天唯一走得到】的
-- 那一条 —— 其余三条在这条裁定之下永远到不了)· PDPA_EMPLOYEE_NOT_SEPARATED
-- · PDPA_RETENTION_NOT_ELAPSED · PDPA_ALREADY_ANONYMISED。证据在 db/fixtures/126。
--
-- ★★ 【这支函数将不会被使用 —— 而这是一个决定,不是一件没做完的活】(Tim,2026-08-24)★★
-- 本函数存在、正确、有 fixture 覆盖,而在 Tim 2026-08-24 的裁定之下【将不会被使用】:
--   **员工个人数据无限期保留。没有保留期,而且不会有。**
-- 它因 hr_settings.personal_data_retention_months 为 NULL 而按名拒绝
-- (PDPA_RETENTION_PERIOD_NOT_SET),而在这条裁定之下那一列【保持 NULL】。
-- 它是一件【建好了、刻意休眠】的机制,不是没做完的活。
--
-- 【不要删掉它,不要放宽这条拒绝,不要设一个期限。】那句拒绝正是这次休眠诚实的地方 ——
-- 路是关着的,而且它说得出自己为什么关着。裁定哪天改口,把那一列设上就是全部的改动。
-- 裁定本身、它没有 settle 掉的东西(保留限制仍是 PDPA 的义务,无限期保留是公司
-- 采取的立场,不是本系统给出的豁免)、以及待决清单里它从 OPEN 变成 DECIDED 的那一行,
-- 都在 docs/pdpa.md 第二节与第五节。
--
-- 【它动两张表】employees 的身份列,与 employment_history 的薪资两列 + 备注。
-- 后者是【不可变】的表 —— 匿名化是它唯一的 UPDATE 例外,而那条例外由行的形状定义
-- (见 db/tables/employment_history.sql 里的 reject_employment_history_mutation)。
--
-- NOTE: introduced by db/migrations/2026-08-24-pdpa1-anonymise-and-subject-access.sql;
--       fixed by db/migrations/2026-08-24-pdpa1-fu-the-immutable-log-gets-one-named-exception.sql
--       (第一版在真实数据上必崩:履历不可变,而它有一句 UPDATE)。

CREATE OR REPLACE FUNCTION public.anonymise_employee(p_employee_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_months int;
    v_emp    employees%ROWTYPE;
    v_due    date;
BEGIN
    PERFORM require_permission('action.anonymise_employee');

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'PDPA_REASON_REQUIRED';
    END IF;

    -- 【没有保留期就【拒绝】,不走任何默认】默认值 = 一次法律表态。
    SELECT personal_data_retention_months INTO v_months FROM hr_settings LIMIT 1;
    IF v_months IS NULL THEN
        RAISE EXCEPTION 'PDPA_RETENTION_PERIOD_NOT_SET';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PDPA_EMPLOYEE_NOT_FOUND';
    END IF;
    IF v_emp.anonymised_at IS NOT NULL THEN
        RAISE EXCEPTION 'PDPA_ALREADY_ANONYMISED|%', v_emp.anonymised_at::date;
    END IF;
    -- 【在职的人不许匿名化】目的还没有结束 —— 那不是合规,那是把在用的数据毁掉。
    IF v_emp.separation_date IS NULL THEN
        RAISE EXCEPTION 'PDPA_EMPLOYEE_NOT_SEPARATED|%', v_emp.code;
    END IF;
    v_due := (v_emp.separation_date + make_interval(months => v_months))::date;
    IF v_due > CURRENT_DATE THEN
        RAISE EXCEPTION 'PDPA_RETENTION_NOT_ELAPSED|%|%', v_emp.code, v_due;
    END IF;

    -- 【覆盖身份列;结构性的列留着】
    -- 留下的那些(编号、雇佣类型、工种、入离职日、部门)**不指向一个人** ——
    -- 它们是让总账、历史与统计还读得懂所必需的,而原则 7 要的正是这个。
    UPDATE employees SET
        legal_name           = 'ANONYMISED ' || code,
        preferred_name       = NULL,
        identity_no          = NULL,
        work_email           = NULL,
        work_phone           = NULL,
        work_pass_no         = NULL,
        work_pass_type       = NULL,
        work_pass_issue_date = NULL,
        work_pass_expiry_date= NULL,
        residency_status     = NULL,
        monthly_salary       = NULL,
        notes                = NULL,
        separation_notes     = NULL,
        -- KPI-1:employees.job_title 已删,清的是【职位指针】。
        -- 【为什么职位也要清】职位本身是主数据、不是个人数据,但"这一行的人
        -- 曾经担任 CFO"仍然是一条关于那个人的事实 —— 匿名化要断掉的正是这种关联。
        -- **employment_history 上那一行不动**(那是不可变的履历,见 fixture 126)。
        position_id          = NULL,
        user_id              = NULL,          -- 与登录账号解绑
        anonymised_at        = now(),
        anonymised_by        = auth.uid()
    WHERE id = p_employee_id;

    -- 薪资历史也是个人数据。**其余每一张表都只按 employee_id 引用他**,
    -- 身份列一旦从这一行拿掉,那些行就不再指向一个可识别的人(化名化)。
    -- 【anonymised_at 必须一起写】—— 它是不可变守卫认得出这个形状的凭据,
    -- 也是 salary_change 行有权不说新薪资的凭据。少了它,这句 UPDATE 会被守卫
    -- 拒掉,而那正是 fixture 126 抓到的那一幕。
    UPDATE employment_history
       SET old_monthly_salary = NULL,
           new_monthly_salary = NULL,
           notes              = NULL,
           anonymised_at      = now()
     WHERE employee_id = p_employee_id
       AND anonymised_at IS NULL;

    RETURN jsonb_build_object(
        'employee_code', v_emp.code, 'anonymised_at', now(),
        'retention_months', v_months, 'due_since', v_due, 'reason', p_reason);
END;
$function$;

-- ─── self_approval_exception
-- db/functions/self_approval_exception.sql
-- APR-ROUTE-1(Tim 的 R2 · Q3):【"不许自己批自己"的唯一一个例外】—— 它在哪里成立。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【Tim 的裁定,原样】最高一级审批角色的持有人(今天是 cfo),可以决定
-- 【他自己的】报销单与医疗申报。每一次这样的决定都在 approval_log 里标成自批,
-- 并有一张报表列出全部自批。**这个例外永远不覆盖**薪资、绩效、调薪,
-- 或任何别的单据类型。Tim 选它而不选"把自己的单送给 MD",是有意识地选了
-- 【可追溯】而不是【可防止】。
-- ★ ROLE-1(Tim 的矩阵,2026-09-23):**请假加进来了,只对 CFO** ——
--   「Tim 自己的假,Tim 自己批,标成 self_decided」。上面那句原来写着"永远不覆盖
--   ……请假",那一句到此为止;划掉而不是删掉的理由与 approvals.md 同一条:
--   一条被收回的规矩与一条从来没写过的规矩,读起来一模一样。
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【三个条件,缺一不可】(Q3)
--   ① 单据类型是 expense_claim、medical_claim 或(ROLE-1 起)leave_request —— 写死在这里,★ 而且只写在这里;
--      approval_log 上的 CHECK(approval_log_self_decided_scope)是同一句话的
--      第二道保险:哪一天别的路径让一次自批漏过去,落留痕那一刻当场报错。
--   ② 这个账号属于【单据说的那个人】(经 account_person 按人认)。
--   ③ 这个账号【此刻】持有 finance_settings.approval_level2_role_code 那个角色
--      (真持有人判据,real_role_holders)。二级角色没设 → 没有例外。
--
-- 【它【不】放宽任何模块门】(Q5)本函数只回答"自批这一条拒不拒";
-- 能不能走到这一步,仍然由每一支决定函数自己的 require_permission 决定。
-- ☞ ROLE-1 之前,医疗申报上一个只持 cfo 的账号在 module.hr.edit 那一行就被拒,
--   根本到不了这里。ROLE-1 把请假与医疗申报的决定门换成 action.decide_hr_requests,
--   并授给了 cfo(Tim 的 Q4:CFO 可以决定任何一张)—— 于是 R2 在这两类上第一次真的走得到。
--
-- 【raiser 那条腿什么时候一起被豁免】只有当提单的人【也是】这个人。
-- 本函数的条件②已经要求"主角就是我",所以 forbid_self_approval 里
-- "raiser 腿成立 且 例外成立"只可能是"我提的、说的也是我"—— 一张我替别人
-- 提的单,条件②不成立,raiser 那一句照拒。
--
-- 【为什么返回 boolean 而这一次是对的】AGENTS.md 那条规矩管的是【拒绝】被表示成
-- 一个会被 COALESCE 掉的值。这里的值是一次【豁免】,它的 NULL 方向是安全的
-- (NULL 读成"不豁免")—— 而且本函数按构造不返回 NULL(见函数体)。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1a-higher-decides-lower-and-the-flagged-self.sql.

CREATE OR REPLACE FUNCTION public.self_approval_exception(p_subject_type text, p_subject_employee uuid, p_user uuid, p_level2_role text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(
               p_subject_type IN ('expense_claim', 'medical_claim', 'leave_request')
           AND p_subject_employee IS NOT NULL
           AND p_user IS NOT NULL
           AND p_level2_role IS NOT NULL
           AND account_person(p_user) = p_subject_employee
           AND EXISTS (SELECT 1 FROM real_role_holders(p_level2_role) h WHERE h.user_id = p_user),
           false);
$function$;

COMMENT ON FUNCTION public.self_approval_exception(text, uuid, uuid, text) IS
'APR-ROUTE-1(R2),ROLE-1 扩到请假:"不许自己批自己"的唯一例外 —— 单据是 expense_claim、medical_claim 或 leave_request、这个账号属于单据说的那个人、并且它此刻是二级审批角色的真持有人。永不返回 NULL。它不放宽任何模块门:能不能走到这一步仍由决定函数自己的 require_permission 决定。approval_log 上的 approval_log_self_decided_scope 是同一句话的第二道保险。EXECUTE 已从 authenticated 收回。';

-- ─── self_approved_decisions
-- db/functions/self_approved_decisions.sql
-- APR-ROUTE-1(Tim 的 R2 · Q4):【每一次自批,一行】—— 自批报表的唯一数据来源。
--
-- 【它为什么存在】Tim 裁定二级审批角色的持有人可以决定他自己的报销单与医疗申报,
-- 而且是有意识地选了【可追溯】而不是【可防止】。可追溯要成立,就必须有一个地方
-- 让别人【看得见】每一次这样的决定 —— 一个只写进 approval_log、却没有任何屏幕
-- 读它的标记,与没有标记是同一件事(本仓库反复付账的"写得进、读不出")。
--
-- 【谁看得见】持 data.view_self_approvals 的人:admin · gm(MD,Vince)· auditor
-- (Tim 的 Q4)。★ 这一个码是【新铸的】,不借 module.finance.view / module.hr.view:
-- 后两者 finance 与 cfo 自己就持有 —— 也就是被这张表报告的那个人,
-- 用借来的码他就总是看得见自己被报告了什么,而 Tim 要的读者是另外那几位。
--
-- 【为什么是一支 DEFINER 函数,不是一张视图】approval_log 的读策略按 subject_type
-- 分门(报销 → module.finance.view,医疗 → module.hr.view)。一个持本码而不持
-- 那两个模块码的审计者,经由那张表会读到【0 行,而且不报错】—— 与"从来没人自批过"
-- 逐字相同。所以这里以属主身份读,而门只有一个:本码。
-- ★ 读者没有这个码时【RAISE】,不返回零行 —— 零行在这里有主,它的意思是
--   "没有人自批过",把拒绝也表示成零行就是把拒绝伪装成一个合法答案
--   (AGENTS.md「拒绝要用哪个值表示」)。
--
-- 【名字跟着单据走】(Standing decision 3)决定人与主角的【显示名】随行返回;
-- 别的员工属性一概不带。
--
-- ★ ROLE-1(2026-09-23):R2 扩到请假(只对 CFO),于是主角的 LATERAL 多一支 leave_requests ——
--   不加它,Tim 自批的假在报表上会有一个空白的主角。admin 不再持 data.view_self_approvals
--   (Tim 的 Q8:admin 只做系统管理),读者剩 gm 与 auditor。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1a-higher-decides-lower-and-the-flagged-self.sql.

CREATE OR REPLACE FUNCTION public.self_approved_decisions()
 RETURNS TABLE(seq bigint, decided_at timestamp with time zone, subject_type text, subject_id uuid, subject_code text, decision text, level smallint, actor_user_id uuid, actor_name text, subject_employee_id uuid, subject_name text, amount_ccy numeric, currency text, amount_base numeric, note text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('data.view_self_approvals');

    RETURN QUERY
    SELECT a.seq, a.decided_at, a.subject_type, a.subject_id, a.subject_code, a.decision,
           a.level, a.actor_user_id,
           COALESCE(ae.legal_name, au.email::text, a.actor_user_id::text) AS actor_name,
           s.employee_id,
           se.legal_name,
           a.amount_ccy, a.currency, a.amount_base, a.note
      FROM approval_log a
      LEFT JOIN auth.users au ON au.id = a.actor_user_id
      LEFT JOIN employees ae ON ae.id = account_person(a.actor_user_id)
      LEFT JOIN LATERAL (
            SELECT c.employee_id FROM expense_claims c
             WHERE a.subject_type = 'expense_claim' AND c.id = a.subject_id
            UNION ALL
            SELECT m.employee_id FROM medical_claims m
             WHERE a.subject_type = 'medical_claim' AND m.id = a.subject_id
            UNION ALL
            SELECT l.employee_id FROM leave_requests l
             WHERE a.subject_type = 'leave_request' AND l.id = a.subject_id
      ) s ON true
      LEFT JOIN employees se ON se.id = s.employee_id
     WHERE a.self_decided
     ORDER BY a.seq DESC;
END;
$function$;

COMMENT ON FUNCTION public.self_approved_decisions() IS
'APR-ROUTE-1(R2 · Q4):自批报表 —— approval_log 里 self_decided 的每一行,带决定人与主角的显示名。门只有一个:data.view_self_approvals(ROLE-1 起:gm · auditor —— admin 不再持任何业务码);没有它就 RAISE,不返回零行(零行在这里的意思是"没有人自批过")。以属主身份读,因为 approval_log 的读策略按单据类型分门,一个只持本码的审计者经由那张表会静默读到零行。';

-- ─── master_import_forbidden_columns
CREATE OR REPLACE FUNCTION public.master_import_forbidden_columns()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT ARRAY[
        'id',                       -- 主键由库生成
        'created_at','updated_at','created_by','updated_by',   -- 审计,由库盖章
        'deleted_at','deleted_by','deletion_reason','owner_id',
        'user_id',                  -- 员工 ↔ 登录账号的关联走 set_user_employee_link
                                    -- (LINK-1 那条"两扇门两套规矩"还没裁,不在这里开第三扇)
        'status',                   -- suppliers.status 由 validate_supplier_status_transition 管
                                    -- 跳转规则;导入直接落一个状态会绕过那条规矩
        'default_payment_term_template_id', -- 指向 payment_term_templates,本刀范围外
        'monthly_salary'            -- ROLE-1(Tim 的矩阵):月薪只走 set_initial_salary(第一份)
                                    -- 与绩效评估 / 调薪申请。master_import_apply 是属主路径,
                                    -- guard_employee_salary_write 看不见它 —— 不在这里挡,
                                    -- 一份员工 CSV 就能绕过整条规矩。
    ];
$function$;

-- ─── batch_freight_base(只改函数体里那段注释:承重的那一格从 processing.edit 换成 finance.view)
CREATE OR REPLACE FUNCTION public.batch_freight_base(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【屏幕读取器】0.00 与「受限」不是同一件事:第一个是谎话。
    -- 白名单与 batch_processing_cost_base 逐字相同,理由也逐字相同 ——
    -- 【承重的那一格】allocate_processing_costs 的调用者【必然】读得到这里,于是
    -- 材料成本表达式里这一支【按构造】不可能是 NULL。一个 NULL 加数会让
    -- SUM 跳过整条投料腿(连 unit_price 一起),那比读到 0 更坏。
    -- ★ ROLE-1(2026-09-23):分摊的门从 module.processing.edit 换成 module.finance.edit,
    --   于是承重的是 finance.view 那一格(edit 蕴含 view —— set_role_permissions 的
    --   EDIT_REQUIRES_VIEW)。processing.edit 那一格原样留着:它不放宽任何东西
    --   (持它必持 processing.view),拿掉它是另一刀的事。fixture 163 的 D 臂钉的是这一格。
    SELECT CASE
        WHEN has_permission('module.inbound.view')
          OR has_permission('module.finance.view')
          OR has_permission('module.processing.view')
          OR has_permission('module.processing.edit')
        THEN batch_freight_base_all(p_inbound_batch_id)
        ELSE NULL
    END;
$function$;

-- ── 3 · 评估与 KPI 六张表的写策略与写触发器:module.hr.edit → action.hr_reviews ──
ALTER POLICY "performance_reviews insert by permission" ON public.performance_reviews WITH CHECK (has_permission('action.hr_reviews'::text));
ALTER POLICY "performance_reviews update by permission" ON public.performance_reviews USING (has_permission('action.hr_reviews'::text)) WITH CHECK (has_permission('action.hr_reviews'::text));
ALTER POLICY "performance_reviews delete by permission" ON public.performance_reviews USING (has_permission('action.hr_reviews'::text));
DROP TRIGGER enforce_write_permission ON public.performance_reviews;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.performance_reviews
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.hr_reviews');

ALTER POLICY "review_cycles insert by permission" ON public.review_cycles WITH CHECK (has_permission('action.hr_reviews'::text));
ALTER POLICY "review_cycles update by permission" ON public.review_cycles USING (has_permission('action.hr_reviews'::text)) WITH CHECK (has_permission('action.hr_reviews'::text));
ALTER POLICY "review_cycles delete by permission" ON public.review_cycles USING (has_permission('action.hr_reviews'::text));
DROP TRIGGER enforce_write_permission ON public.review_cycles;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.review_cycles
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.hr_reviews');

ALTER POLICY "review_goals insert by permission" ON public.review_goals WITH CHECK (has_permission('action.hr_reviews'::text));
ALTER POLICY "review_goals update by permission" ON public.review_goals USING (has_permission('action.hr_reviews'::text)) WITH CHECK (has_permission('action.hr_reviews'::text));
ALTER POLICY "review_goals delete by permission" ON public.review_goals USING (has_permission('action.hr_reviews'::text));
DROP TRIGGER enforce_write_permission ON public.review_goals;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.review_goals
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.hr_reviews');

ALTER POLICY "review_rating_scale insert by permission" ON public.review_rating_scale WITH CHECK (has_permission('action.hr_reviews'::text));
ALTER POLICY "review_rating_scale update by permission" ON public.review_rating_scale USING (has_permission('action.hr_reviews'::text)) WITH CHECK (has_permission('action.hr_reviews'::text));
ALTER POLICY "review_rating_scale delete by permission" ON public.review_rating_scale USING (has_permission('action.hr_reviews'::text));
DROP TRIGGER enforce_write_permission ON public.review_rating_scale;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.review_rating_scale
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.hr_reviews');

ALTER POLICY "kpi_cycles insert by permission" ON public.kpi_cycles WITH CHECK (has_permission('action.hr_reviews'::text));
ALTER POLICY "kpi_cycles update by permission" ON public.kpi_cycles USING (has_permission('action.hr_reviews'::text)) WITH CHECK (has_permission('action.hr_reviews'::text));
DROP TRIGGER enforce_write_permission ON public.kpi_cycles;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.kpi_cycles
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.hr_reviews');

ALTER POLICY "kpi_score_rubric insert by permission" ON public.kpi_score_rubric WITH CHECK (has_permission('action.hr_reviews'::text));
ALTER POLICY "kpi_score_rubric update by permission" ON public.kpi_score_rubric USING (has_permission('action.hr_reviews'::text)) WITH CHECK (has_permission('action.hr_reviews'::text));
ALTER POLICY "kpi_score_rubric delete by permission" ON public.kpi_score_rubric USING (has_permission('action.hr_reviews'::text));
DROP TRIGGER enforce_write_permission ON public.kpi_score_rubric;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.kpi_score_rubric
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.hr_reviews');

COMMENT ON TABLE public.kpi_score_rubric IS
    'C-2:0–5 打分刻度与安全/监管否决 —— 原表第六页逐格转录。★**它是【数据】不是文案**★:与公共假期同一条论证,打分的规则必须能不发版就改正(action.hr_reviews 可改 —— ROLE-1 前是 module.hr.edit)。★**否决那一栏落在每一行上,因为它对每一档都成立**★ —— 原表把「Does not override a major safety/regulatory breach」写在 5 分那一行、把「Any unauthorized operation = 0」写在 1 分那一行,而它们说的是同一条规矩的不同侧面。屏幕上把它贴在每一档旁边,是为了让打分的人在【按下 4 分的那一刻】看见它,而不是记得它。';

-- ── 4 · 三支新触发器 ────────────────────────────────────────────────────────
CREATE TRIGGER trg_lock_reopen_path
    BEFORE UPDATE OF locked_before ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION public.guard_lock_reopen_path();

CREATE TRIGGER trg_employees_salary_write
    BEFORE INSERT OR UPDATE ON public.employees
    FOR EACH ROW EXECUTE FUNCTION public.guard_employee_salary_write();

CREATE TRIGGER trg_employment_history_salary_write
    BEFORE INSERT ON public.employment_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_employment_history_salary_write();

-- ── 5 · approval_log:自批的第二道保险加上请假 ──────────────────────────────
ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_self_decided_scope;
ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_self_decided_scope CHECK (
    NOT self_decided OR subject_type IN ('expense_claim', 'medical_claim', 'leave_request'));
COMMENT ON COLUMN public.approval_log.self_decided IS
    'APR-ROUTE-1(Tim 的 R2):按下去的这个人,是不是这张单据的提单人或主角(按人认,经 self_leg)。★ 记的是【事实】不是【规则】:由 record_approval_decision 对 approved / rejected 两种决定计算;auto_approved 与 approval_voided 不是一次决定,恒为 false。唯一允许它为 true 的是 Tim 的例外(二级审批角色的持有人决定自己的报销单或医疗申报;ROLE-1 起加上请假),approval_log_self_decided_scope 把它钉在这三类上。自批报表 self_approved_decisions() 读它。★ 加列时线上 14 行里没有一行是"决定人 = 主角"的决定(APR-ROUTE-1 grilling 实测),所以 DEFAULT false 对历史行是真话,不是回填。';

-- ── 6 · employee_lookup:系统管理员要列得出可关联的人(只有名字)───────────
CREATE OR REPLACE VIEW public.employee_lookup WITH (security_invoker = off) AS
 SELECT id,
    code,
    preferred_name,
    legal_name,
    user_id,
    deleted_at
   FROM employees e
  WHERE has_permission('module.hr.view'::text) OR has_permission('module.finance.view'::text) OR has_permission('action.manage_permissions'::text);

COMMENT ON VIEW public.employee_lookup IS
    'FIX-2a:员工的【查名】视图 —— id / 工号 / 称呼名 / 法定名 / 登录账号。Tim 的 Q2 裁定:只有名字。付款、费用与薪资三处要把一份单据指向一个人。【没有】monthly_salary / identity_no / work_pass_* / residency_status / department_id / position_id / hire_date / separation_* / work_email / work_phone —— 那些才是人事事实,而 data.view_pay 与 data.view_identity 管着它们。行谓词 hr.view OR finance.view OR action.manage_permissions(ROLE-1:系统管理员账号不再持任何业务码,而账号↔员工关联归它 —— /settings/accounts 要列出可关联的人,只要名字)。与 ActorName 的分工:那一个答"谁做的",这一张答"这份单据指向谁"。';

GRANT SELECT ON public.employee_lookup TO authenticated;

-- ── 7 · 授权(Tim 的 Q2 / Q3 / Q6 / Q8)──────────────────────────────────────
-- admin:只剩系统管理(Q8)。Tim 的一切业务阅读与决定走 tim@(cfo),不走 admin@。
DELETE FROM role_permissions rp USING roles r
 WHERE r.id = rp.role_id AND r.code = 'admin'
   AND rp.permission_code NOT IN ('action.manage_permissions', 'action.bulk_import');
INSERT INTO role_permissions (role_id, permission_code)
SELECT id, 'action.anonymise_employee' FROM roles WHERE code = 'admin';

-- cco:权限与审批设置只归 admin;批量导入只归 admin;人事只留 KPI 与评估;身份信息只归财务(Q6)。
DELETE FROM role_permissions rp USING roles r
 WHERE r.id = rp.role_id AND r.code = 'cco'
   AND rp.permission_code IN ('action.manage_permissions', 'action.bulk_import',
                              'module.hr.edit', 'data.view_identity');
INSERT INTO role_permissions (role_id, permission_code)
SELECT id, 'action.hr_reviews' FROM roles WHERE code = 'cco';

-- cto:保留化验(Batch 2 才拆出它自己的码);批量导入只归 admin;COD 只归仓库;身份信息只归财务。
DELETE FROM role_permissions rp USING roles r
 WHERE r.id = rp.role_id AND r.code = 'cto'
   AND rp.permission_code IN ('action.bulk_import', 'action.issue_cod', 'data.view_identity');

-- finance:接过除 KPI 与评估以外的全部人事与薪资;决定请假与医疗申报;批量导入交出。
DELETE FROM role_permissions rp USING roles r
 WHERE r.id = rp.role_id AND r.code = 'finance'
   AND rp.permission_code IN ('action.bulk_import');
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, c FROM roles r
 CROSS JOIN unnest(ARRAY['module.hr.edit', 'module.hr.view', 'data.view_identity',
                         'action.decide_hr_requests']) c
 WHERE r.code = 'finance'
ON CONFLICT DO NOTHING;

-- cfo:本批要它做的决定,加上读那些决定要的只读码(Q3)。
--   ★ 没有一个码能让 cfo【开出】它要批的单据 —— 全部是 action.<决定> 或 *.view / data.view_*。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, c FROM roles r
 CROSS JOIN unnest(ARRAY['action.finance_reopen', 'action.approve_review', 'action.decide_hr_requests',
                         'module.hr.view', 'data.view_reviews',
                         'module.suppliers.view', 'module.customers.view', 'data.view_banking']) c
 WHERE r.code = 'cfo'
ON CONFLICT DO NOTHING;

-- 每一张在途单据,有几个【不是它自己当事人】的人决定得了它。按【人】数(account_person),
-- 不按账号 —— Tim 的两个账号只算一个。p_after = false 按 ROLE-1 之前的门问,true 按之后的门问。
-- ★ approval_deciders 只回答分档链(报销单、采购单)—— 它读 approval_chain_gates(),
--   而请假 / 医疗 / 评估 / 工单 / 盘点不在那张目录里。所以那几条链用它的【同一批零件】
--   (real_role_grants · self_leg · self_approval_exception)按各自决定函数真实的门来问。
CREATE FUNCTION pg_temp.role1_pending_decider_check(p_after boolean DEFAULT true)
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
      LEFT JOIN holds h ON 'module.processing.edit' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      LEFT JOIN holds h ON 'module.stocktakes.edit' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
     WHERE s.status = 'open' AND s.deleted_at IS NULL
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

CREATE TEMP TABLE role1_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL;

-- ── 8 · 自证:同一笔事务里,失败即整笔回滚 ────────────────────────────────────
DO $proof$
DECLARE
    v_bad    text;
    v_expect jsonb := jsonb_build_object(
      'admin', jsonb_build_array('action.anonymise_employee','action.bulk_import','action.manage_permissions'),
      'cfo', jsonb_build_array('action.approve_review','action.decide_hr_requests','action.finance_reopen',
             'data.view_banking','data.view_pay','data.view_prices','data.view_reviews',
             'module.customers.view','module.finance.view','module.hr.view','module.logistics.view',
             'module.purchasing.view','module.suppliers.view'),
      'cco', jsonb_build_array('action.hr_reviews','data.view_banking','data.view_deleted','data.view_pay',
             'data.view_prices','data.view_reviews','data.view_sales','module.customers.edit','module.customers.view',
             'module.finance.view','module.hr.view','module.inbound.edit','module.inbound.view','module.inventory.edit',
             'module.inventory.view','module.logistics.view','module.materials.edit','module.materials.view',
             'module.output.edit','module.output.view','module.pricing.edit','module.pricing.view',
             'module.processing.edit','module.processing.view','module.purchasing.edit','module.purchasing.view',
             'module.sales.edit','module.sales.view','module.stocktakes.edit','module.stocktakes.view',
             'module.suppliers.edit','module.suppliers.view','module.tasks.edit','module.tasks.view'),
      'cto', jsonb_build_array('data.view_banking','data.view_deleted','data.view_prices','data.view_reviews',
             'data.view_sales','module.customers.edit','module.customers.view','module.finance.view','module.hr.view',
             'module.inbound.edit','module.inbound.view','module.inventory.edit','module.inventory.view',
             'module.logistics.view','module.materials.edit','module.materials.view','module.output.edit',
             'module.output.view','module.pricing.edit','module.pricing.view','module.processing.edit',
             'module.processing.view','module.purchasing.edit','module.purchasing.view','module.sales.view',
             'module.stocktakes.edit','module.stocktakes.view','module.suppliers.edit','module.suppliers.view',
             'module.tasks.edit','module.tasks.view'),
      'finance', jsonb_build_array('action.decide_hr_requests','data.view_banking','data.view_deleted',
             'data.view_identity','data.view_pay','data.view_prices','data.view_sales','module.customers.edit',
             'module.customers.view','module.finance.edit','module.finance.view','module.hr.edit','module.hr.view',
             'module.inbound.edit','module.inbound.view','module.inventory.edit','module.inventory.view',
             'module.logistics.view','module.materials.edit','module.materials.view','module.output.edit',
             'module.output.view','module.pricing.edit','module.pricing.view','module.processing.view',
             'module.purchasing.edit','module.purchasing.view','module.sales.view','module.stocktakes.edit',
             'module.stocktakes.view','module.suppliers.edit','module.suppliers.view','module.tasks.edit',
             'module.tasks.view'),
      'warehouse', jsonb_build_array('action.issue_cod','module.inbound.edit','module.inbound.view',
             'module.inventory.edit','module.inventory.view','module.logistics.view','module.output.edit',
             'module.output.view','module.stocktakes.edit','module.stocktakes.view','module.tasks.edit',
             'module.tasks.view'),
      'gm', jsonb_build_array('data.view_banking','data.view_prices','data.view_reviews','data.view_sales',
             'data.view_self_approvals','module.customers.view','module.finance.view','module.hr.view',
             'module.inbound.view','module.inventory.view','module.logistics.view','module.materials.view',
             'module.output.view','module.pricing.view','module.processing.view','module.purchasing.view',
             'module.sales.view','module.stocktakes.view','module.suppliers.view','module.tasks.view'));
    k text;
    v_have jsonb;
    v_n    int;
BEGIN
    -- ① 每个有人持有的角色,授权【逐码】等于 Tim 裁定的那一份
    FOR k IN SELECT jsonb_object_keys(v_expect) LOOP
        SELECT COALESCE(jsonb_agg(rp.permission_code ORDER BY rp.permission_code), '[]'::jsonb) INTO v_have
          FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = k;
        IF v_have <> (SELECT jsonb_agg(x ORDER BY x) FROM jsonb_array_elements_text(v_expect->k) x) THEN
            RAISE EXCEPTION 'ROLE1_PROOF|role % holds %', k, v_have;
        END IF;
    END LOOP;

    -- ② edit 蕴含 view(set_role_permissions 的 EDIT_REQUIRES_VIEW,这里是直写,自己验)
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code LIKE 'module.%.edit'
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id
                        AND v.permission_code = replace(rp.permission_code, '.edit', '.view'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1_PROOF|edit without view: %', v_bad; END IF;

    -- ③ 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1_PROOF|approvals switched off';
    END IF;

    -- ④ 在途单据一张不少、一张不多;留痕一行没写
    IF EXISTS ((SELECT b.k, b.id FROM role1_pending_before b EXCEPT SELECT a.k, a.id FROM role1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM role1_pending_after a EXCEPT SELECT b.k, b.id FROM role1_pending_before b)) THEN
        RAISE EXCEPTION 'ROLE1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT count(*) FROM approval_log) <> (SELECT n FROM role1_log_before) THEN
        RAISE EXCEPTION 'ROLE1_PROOF|approval_log changed';
    END IF;

    -- ⑤ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.role1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ROLE1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.role1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ROLE1_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.role1_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.role1_pending_decider_check(boolean);

COMMIT;
