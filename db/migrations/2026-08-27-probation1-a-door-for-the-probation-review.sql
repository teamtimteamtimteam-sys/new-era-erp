-- db/migrations/2026-08-27-probation1-a-door-for-the-probation-review.sql
-- PROBATION-1:给试用期转正这条路装一扇门 —— 它今天一扇都没有。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这一刀为什么存在】REVIEW-SURVEY 测出来的:试用期评估【下游全部建好了】——
-- 决定表单的 probation 分支、approve_review 写 confirmation_date、hr_alerts 三支、
-- 列表页的 probation 过滤器 —— 全都在对着一行【没有任何东西造得出来】的记录工作。
--   · `open_review_cycle` 是 performance_reviews 【唯一】的写入者,而它只造
--     `review_type='annual'`,并且明确把 probation 状态的员工排除在外;
--   · `performance_reviews_cycle_shape` 要求 probation ⇒ cycle_id IS NULL,
--     而那支函数【永远】写 cycle_id —— 所以它在结构上也造不出一份试用期评估;
--   · app 里没有任何一个动作 INSERT 过 performance_reviews(saveHrDecision 只 UPDATE)。
--
-- ★ 最尖锐的证据:冒烟脚本必须【直接 POST 到 REST】才能造出那一行来测页面。
--   **测试绕过了产品,因为产品没有那条路。** 本刀把那条路建出来,并让冒烟改走它。
--
-- 【这件事有雇佣后果】它决定一个人过不过试用期,并且带着一个调薪字段。
-- 所以下面每一条拒绝都是【按名】的,没有一条靠猜、靠默认值、靠"大概是这个日期"。
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 【三个决定,Tim 2026-08-27】
-- ① **人工发起,不自动生成。** hr_alerts 的 probation_ending 已经在算那个日期了
--    (到期前 30 天起,14 天内升为 critical)——【推导那一半已经有了】,缺的是
--    有人据此按一下。而一行【写着某个人名字、还指派了评估人】的记录自己冒出来,
--    不是一件小事。这也与既有形状一致:open_review_cycle 也是人按按钮,不是定时任务。
-- ② **期间 = hire_date → probation_end_date,取不到就【按名拒绝】。**
--    实测线上 4 个 probation 员工【一个都没有填 probation_end_date】。
--    替他们编一个日期,等于凭空造出转正决定所依据的那个事实本身。
-- ③ **评估人沿用 open_review_cycle 那套三级解析** —— 而"沿用"是把它【抽出来】,
--    不是抄一遍(见下面第 1 节)。解析不出来就留 NULL,
--    hr_alerts 的 review_no_reviewer 一支本来就在等这种情况。

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1 · 评估人解析:抽成一处,两个调用方
-- ───────────────────────────────────────────────────────────────────────────
-- 【为什么先抽再用】"沿用同一套解析"如果靠复制,就是同一条规矩的第二份实现 ——
-- 这个仓库为这个形状反复付过账(aging_bucket 是上一次)。抽出来之后,
-- 「谁评估这个人」在库里只有一个答案;改它,两个入口一起改。
CREATE OR REPLACE FUNCTION public.resolve_review_reviewer(p_employee_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$
    -- 【三级解析】部门经理 → 本人就是部门经理时取【上级部门】的经理 → 再不行 NULL。
    -- 每一级都排除"解析到本人":自己不能评自己
    -- (performance_reviews_not_self_review 这条 CHECK 也会拦,但拦在这里更早)。
    -- NULL 【不是】被忽略 —— hr_alerts 的 review_no_reviewer 一支会把它顶出来。
    SELECT COALESCE(
               NULLIF(d.manager_employee_id, e.id),
               NULLIF(pd.manager_employee_id, e.id)
           )
      FROM employees e
      LEFT JOIN departments d  ON d.id = e.department_id
      LEFT JOIN departments pd ON pd.id = d.parent_department_id
     WHERE e.id = p_employee_id;
$function$;

COMMENT ON FUNCTION public.resolve_review_reviewer(uuid) IS
    'PROBATION-1:「谁评估这个人」的【唯一一处】定义 —— 部门经理 → 上级部门经理 → NULL,每一级排除本人。两个调用方:open_review_cycle(年度轮)与 open_probation_review(试用期)。抽出来之前它只写在 open_review_cycle 的 INSERT ... SELECT 里;本刀要第二个调用方,而复制它就是同一条规矩的两份实现。解析不出来返回 NULL 是刻意的:hr_alerts 的 review_no_reviewer 一支专门等这种情况,悄悄塞一个人进去才是错的。';

-- ───────────────────────────────────────────────────────────────────────────
-- 2 · open_review_cycle 改调那一处解析(行为一字未变)
-- ───────────────────────────────────────────────────────────────────────────
-- 只把 INSERT ... SELECT 里那段 COALESCE 换成函数调用,其余逐字未动。
-- 换完之后两个入口读同一份解析;fixture 136 的 F 臂做目录断言把这件事钉住。
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
    PERFORM require_permission('module.hr.edit');

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

-- ───────────────────────────────────────────────────────────────────────────
-- 3 · 门本身:从产品内部造出一份试用期评估
-- ───────────────────────────────────────────────────────────────────────────
-- 【为什么是【另一支函数】,不是给 open_review_cycle 加一个参数】
-- `performance_reviews_cycle_shape` 写着:annual ⇒ cycle_id IS NOT NULL,
-- probation ⇒ cycle_id IS NULL。**试用期评估不是年度评估的一个变体,是另一种形状。**
-- 一支函数硬吃两种形状,意味着它一半的参数在另一半永远为空、
-- 而它的名字("开启一轮")对单人单件那一支根本不成立。
-- 两支函数各自说得清自己是什么,并且【共用】评估人解析那一处(见第 1 节)。
--
-- 【幂等由库保证,而拒绝由函数按名给出】
-- `idx_performance_reviews_one_probation` 是一条部分唯一索引:
-- 一个人【非作废】的试用期评估最多一份。撞上它会抛 23505 —— 一串机器文本。
-- 所以这里先查再拒,按名说出是谁、现在是什么状态(docs/machine-text-reaching-humans.md)。
-- 作废之后可以重开:那条索引带着 status <> 'void'。
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
    PERFORM require_permission('module.hr.edit');

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

-- ───────────────────────────────────────────────────────────────────────────
-- 4 · hr_alerts:告警要认得出"已经有人在办了"
-- ───────────────────────────────────────────────────────────────────────────
-- 【为什么这一条属于本刀,而不是另排一刀】
-- `probation_ending` 的 NOT EXISTS 只认【已批准且 confirm】的评估。也就是说:
-- 你按下新装的这扇门、指派了评估人、写了目标、走完自评、提交 ——
-- **这盏灯从头到尾一动不动,还是同一个颜色。** 做对事的人得不到任何回应。
-- 本刀装的门通向的正是这张页面,所以"门装好了、页面还在喊你没开门"必须一起收掉。
--
-- 【新增一个具名类型,不是把严重度悄悄调低】(Tim 2026-08-27)
-- 调低颜色而不说原因,正是本仓库反复拒绝的"算得出来却不说话"。
-- 一个具名类型读得出、筛得出、也讲得清:有人已经开始了,去把它办完。
-- `hr.alertType.` 的后缀集合由 check-i18n 从【本文件】现读,所以新增这一支
-- 会自动要求 en/zh 两个语言各补一句 —— 少一句,构建就红。
--
-- 【overdue 一支【不动】】(同上裁定)已过期而仍无已批准的决定,是过期就是过期;
-- 手上有没有在办的草稿不改变这一点。软化它,等于把唯一一盏"这个人已经过了
-- 试用期终点却没有结论"的灯调暗 —— 那是本刀唯一有可能把真问题弄安静的改动。
CREATE OR REPLACE VIEW public.hr_alerts WITH (security_invoker = off) AS
 SELECT alert_type,
    severity,
    employee_id,
    employee_code,
    employee_name,
    subject,
    due_date,
    days_remaining
   FROM ( SELECT 'work_pass_expiry'::text AS alert_type,
                CASE
                    WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
                    WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
                    ELSE 'warning'::text
                END AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            COALESCE(e.work_pass_type, 'Work pass'::text) AS subject,
            e.work_pass_expiry_date AS due_date,
            e.work_pass_expiry_date - CURRENT_DATE AS days_remaining
           FROM employees e
          WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND e.work_pass_expiry_date IS NOT NULL AND (e.work_pass_expiry_date - CURRENT_DATE) <= 90 AND (e.work_pass_expiry_date - CURRENT_DATE) >= '-30'::integer
        UNION ALL
         SELECT 'probation_ending'::text AS alert_type,
                CASE
                    WHEN (e.probation_end_date - CURRENT_DATE) <= 14 THEN 'critical'::text
                    ELSE 'warning'::text
                END AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            'Probation'::text AS subject,
            e.probation_end_date AS due_date,
            e.probation_end_date - CURRENT_DATE AS days_remaining
           FROM employees e
          WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND e.probation_end_date IS NOT NULL AND e.probation_end_date >= CURRENT_DATE AND (e.probation_end_date - CURRENT_DATE) <= 30 AND NOT (EXISTS ( SELECT 1
                   FROM performance_reviews r
                  WHERE r.employee_id = e.id AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome = 'confirm'::text)) AND NOT (EXISTS ( SELECT 1
                   FROM performance_reviews u
                  WHERE u.employee_id = e.id AND u.review_type = 'probation'::text AND (u.status = ANY (ARRAY['draft'::text, 'self_review'::text, 'submitted'::text]))))
        UNION ALL
         SELECT 'probation_review_underway'::text AS alert_type,
            'warning'::text AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            'Probation review in progress'::text AS subject,
            e.probation_end_date AS due_date,
            e.probation_end_date - CURRENT_DATE AS days_remaining
           FROM employees e
             JOIN performance_reviews u ON u.employee_id = e.id AND u.review_type = 'probation'::text AND (u.status = ANY (ARRAY['draft'::text, 'self_review'::text, 'submitted'::text]))
          WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text
        UNION ALL
         SELECT 'probation_overdue'::text AS alert_type,
            'expired'::text AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            'Probation ended without a decision'::text AS subject,
            e.probation_end_date AS due_date,
            e.probation_end_date - CURRENT_DATE AS days_remaining
           FROM employees e
          WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND e.probation_end_date IS NOT NULL AND e.probation_end_date < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
                   FROM performance_reviews r
                  WHERE r.employee_id = e.id AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome IS NOT NULL))
        UNION ALL
         SELECT 'probation_not_confirmed'::text AS alert_type,
            'expired'::text AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            'Probation not confirmed — separation is a manual decision'::text AS subject,
            COALESCE(e.probation_end_date, r.approved_at::date) AS due_date,
            COALESCE(e.probation_end_date, r.approved_at::date) - CURRENT_DATE AS days_remaining
           FROM employees e
             JOIN performance_reviews r ON r.employee_id = e.id
          WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome = 'not_confirm'::text
        UNION ALL
         SELECT 'salary_not_set'::text AS alert_type,
                CASE
                    WHEN e.employment_status = 'notice'::text THEN 'critical'::text
                    ELSE 'warning'::text
                END AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            'Monthly fixed gross not set — leave encashment cannot be computed'::text AS subject,
            NULL::date AS due_date,
            NULL::integer AS days_remaining
           FROM employees e
          WHERE e.deleted_at IS NULL AND (e.employment_status = ANY (ARRAY['probation'::text, 'active'::text, 'notice'::text])) AND NOT e.monthly_salary_set
        UNION ALL
         SELECT 'review_no_reviewer'::text AS alert_type,
            'critical'::text AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            COALESCE(c.name, 'Probation review'::text) || ' — no reviewer assigned'::text AS subject,
            c.due_date,
            c.due_date - CURRENT_DATE AS days_remaining
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
             LEFT JOIN review_cycles c ON c.id = r.cycle_id
          WHERE r.reviewer_employee_id IS NULL AND (r.status <> ALL (ARRAY['approved'::text, 'acknowledged'::text, 'void'::text])) AND e.deleted_at IS NULL
        UNION ALL
         SELECT 'review_cycle_overdue'::text AS alert_type,
            'critical'::text AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            c.name AS subject,
            c.due_date,
            c.due_date - CURRENT_DATE AS days_remaining
           FROM performance_reviews r
             JOIN review_cycles c ON c.id = r.cycle_id
             JOIN employees e ON e.id = r.employee_id
          WHERE c.deleted_at IS NULL AND c.status = 'open'::text AND c.due_date < CURRENT_DATE AND (r.status = ANY (ARRAY['draft'::text, 'self_review'::text]))
        UNION ALL
         SELECT 'cpf_due'::text AS alert_type,
                CASE
                    WHEN (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date < CURRENT_DATE THEN 'expired'::text
                    WHEN ((date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE) <= 3 THEN 'critical'::text
                    ELSE 'warning'::text
                END AS severity,
            NULL::uuid AS employee_id,
            p.code AS employee_code,
            'CPF'::text AS employee_name,
            'CPF contribution unpaid — due 14th of the following month, late payment attracts interest'::text AS subject,
            (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date AS due_date,
            (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE AS days_remaining
           FROM payroll_periods p
          WHERE p.deleted_at IS NULL AND p.status = 'posted'::text AND p.cpf_paid_at IS NULL AND (COALESCE(p.employer_cpf_total, 0::numeric) + COALESCE(p.employee_cpf_total, 0::numeric)) > 0::numeric AND ((date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE) <= 7
        UNION ALL
         SELECT 'training_expiry'::text AS alert_type,
                CASE
                    WHEN t.expiry_date < CURRENT_DATE THEN 'expired'::text
                    WHEN (t.expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
                    ELSE 'warning'::text
                END AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            t.training_name AS subject,
            t.expiry_date AS due_date,
            t.expiry_date - CURRENT_DATE AS days_remaining
           FROM training_records t
             JOIN employees e ON e.id = t.employee_id
          WHERE t.deleted_at IS NULL AND e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND t.expiry_date IS NOT NULL AND (t.expiry_date - CURRENT_DATE) <= 90 AND (t.expiry_date - CURRENT_DATE) >= '-30'::integer
        UNION ALL
         SELECT 'holiday_calendar_missing'::text AS alert_type,
            'expired'::text AS severity,
            NULL::uuid AS employee_id,
            ''::text AS employee_code,
            ''::text AS employee_name,
            EXTRACT(year FROM CURRENT_DATE)::text AS subject,
            CURRENT_DATE AS due_date,
            0 AS days_remaining
          WHERE NOT (EXISTS ( SELECT 1
                   FROM public_holidays h
                  WHERE h.is_active AND h.country = 'SG'::text AND EXTRACT(year FROM h.holiday_date) = EXTRACT(year FROM CURRENT_DATE)))
        UNION ALL
         SELECT 'holiday_calendar_next_year'::text AS alert_type,
                CASE
                    WHEN EXTRACT(month FROM CURRENT_DATE) = 12::numeric THEN 'critical'::text
                    ELSE 'warning'::text
                END AS severity,
            NULL::uuid AS employee_id,
            ''::text AS employee_code,
            ''::text AS employee_name,
            (EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::text AS subject,
            make_date((EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::integer, 1, 1) AS due_date,
            make_date((EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::integer, 1, 1) - CURRENT_DATE AS days_remaining
          WHERE EXTRACT(month FROM CURRENT_DATE) >= 10::numeric AND NOT (EXISTS ( SELECT 1
                   FROM public_holidays h
                  WHERE h.is_active AND h.country = 'SG'::text AND EXTRACT(year FROM h.holiday_date) = (EXTRACT(year FROM CURRENT_DATE) + 1::numeric)))
        UNION ALL
         SELECT 'system_start_not_set'::text AS alert_type,
            'expired'::text AS severity,
            NULL::uuid AS employee_id,
            ''::text AS employee_code,
            ''::text AS employee_name,
            ''::text AS subject,
            CURRENT_DATE AS due_date,
            0 AS days_remaining
          WHERE NOT (EXISTS ( SELECT 1
                   FROM finance_settings s
                  WHERE s.system_start_date IS NOT NULL))) a
  WHERE has_permission('module.hr.view'::text);

COMMIT;
