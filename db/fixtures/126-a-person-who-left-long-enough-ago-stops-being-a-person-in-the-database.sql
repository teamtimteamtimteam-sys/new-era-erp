-- db/fixtures/126-a-person-who-left-long-enough-ago-stops-being-a-person-in-the-database.sql
-- PDPA-1:匿名化的【四条按名拒绝】、一次真的匿名化、以及当事人查阅的范围。
--
-- 【本 fixture 的第一臂是这一刀的判词】保留期没有设的时候,anonymise_employee
-- **必须按名拒绝**。那不是一条防御性的分支 —— 保留期是一个【法律问题】,
-- 而"没有答案时替人选一个默认值"正是这支函数存在的理由的反面。
-- **一条关着的路必须证明它真的关着**,否则"它会拒绝"只是一句注释。
--
-- 【为什么 E 臂要造一条 salary_change 历史行】anonymise_employee 会把
-- employment_history 的 old_/new_monthly_salary 置 NULL,而这张表上有一条
-- employment_history_salary_shape:change_type='salary_change' 的行【必须】有
-- new_monthly_salary。**一个涨过薪的人正是最可能走到保留期满的那种人** ——
-- 只用没有薪资历史的样本测,这条相撞永远不会出现在测试里,只会出现在第一次真实
-- 匿名化的那一刻。所以这一臂刻意造一个【有加薪记录的离职者】。

BEGIN;
DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    v_user2  uuid := gen_random_uuid();
    r_all    uuid;
    v_emp    uuid;
    v_emp2   uuid;
    v_emp3   uuid;
    v_row    employees%ROWTYPE;
    v_rep    jsonb;
    v_n      int;
BEGIN
    -- ── 布景:一个持全权限的主体,外加两名员工 ────────────────────────────────
    INSERT INTO roles (code,name_en,name_zh,is_active)
      VALUES ('fixture-126','f','f',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id,permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id,role_id) VALUES (v_user,r_all);
    -- employees.user_id 自 EXEC-2 起有指向 auth.users 的外键,所以登录身份要真的存在
    INSERT INTO auth.users (id) VALUES (v_user), (v_user2);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 甲:离职很久、涨过薪、带着一整套身份数据的人
    INSERT INTO employees (code, legal_name, preferred_name, employment_type, work_category,
                           hire_date, employment_status, separation_date, separation_type,
                           separation_notes, job_title, work_email, work_phone, identity_no,
                           residency_status, work_pass_type, work_pass_no,
                           work_pass_issue_date, work_pass_expiry_date,
                           monthly_salary, notes, user_id)
      VALUES ('ZZFIX126-EMP-1','ZZFIX126 Departed Person','Depa','full_time','office',
              CURRENT_DATE - interval '6 years', 'separated',
              (CURRENT_DATE - interval '25 months')::date, 'resignation',
              'ZZFIX126 离职备注 —— 个人数据', 'Storeman',
              'zzfix126.one@example.com','+65 90000126','SZZFIX126A',
              'work_pass','Work Permit','WPZZFIX126',
              (CURRENT_DATE - interval '5 years')::date, (CURRENT_DATE + interval '1 year')::date,
              4321, 'ZZFIX126 私人备注', v_user)
      RETURNING id INTO v_emp;

    -- 【关键的一行】一条加薪历史 —— employment_history_salary_shape 盯着它
    INSERT INTO employment_history (employee_id, effective_date, change_type,
                                    old_monthly_salary, new_monthly_salary, notes)
      VALUES (v_emp, (CURRENT_DATE - interval '3 years')::date, 'salary_change',
              3800, 4321, 'ZZFIX126 调薪备注 —— 个人数据');

    -- 一条绩效评估 —— 用来证明【正文不进导出,元数据进】
    -- 用 probation 型:performance_reviews_cycle_shape 要求 annual 必须挂在一个
    -- review_cycle 上,而 probation 型必须【不】挂 —— 这里不需要一整个考核周期。
    INSERT INTO performance_reviews (employee_id, review_type, period_start, period_end)
      VALUES (v_emp, 'probation', (CURRENT_DATE - interval '6 years')::date,
                                  (CURRENT_DATE - interval '69 months')::date);

    -- 乙:刚离职的人(保留期没满),以及后面 G 臂的查阅主体
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status, separation_date, identity_no, user_id)
      VALUES ('ZZFIX126-EMP-2','ZZFIX126 Just Left','full_time','shopfloor',
              CURRENT_DATE - interval '2 years', 'separated',
              (CURRENT_DATE - interval '1 month')::date, 'SZZFIX126B', v_user2)
      RETURNING id INTO v_emp2;

    -- 丙:**还在职**的人 —— C 臂要的那个主语,而它必须由本 fixture 自己造出来。
    -- 【第一版没有造它,于是 C 臂在 gate 里红了】原来写的是
    --     SELECT id FROM employees WHERE separation_date IS NULL LIMIT 1
    -- —— 在【线上】找得到人(库里有在职员工),在【重建出来的库】里那是空集,
    -- 于是传进去的是 NULL,撞的是 PDPA_EMPLOYEE_NOT_FOUND,而这一臂要断言的是
    -- PDPA_EMPLOYEE_NOT_SEPARATED。**两个都是"按名拒绝",所以它看起来很像通过了。**
    -- 一支依赖线上数据的 fixture,在重建那一侧证明不了任何东西 ——
    -- 而 gate 的两侧同跑正是为了抓这个。
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
      VALUES ('ZZFIX126-EMP-3','ZZFIX126 Still Here','full_time','office',
              (CURRENT_DATE - interval '1 year')::date)
      RETURNING id INTO v_emp3;

    -- ══════════ A · 保留期【没有设】→ 按名拒绝(本 fixture 的判词)════════════
    -- 前置:线上今天就是 NULL,而这一臂不依赖那个巧合,它自己先确保 NULL。
    UPDATE hr_settings SET personal_data_retention_months = NULL;
    BEGIN
        PERFORM anonymise_employee(v_emp, '保留期到了');
        RAISE EXCEPTION 'FIXTURE 126A 失败:保留期没有设,匿名化却跑了 —— 一个默认值替人做出了法律表态';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%PDPA_RETENTION_PERIOD_NOT_SET%' THEN
            RAISE EXCEPTION 'FIXTURE 126A 失败:拒绝不是按名的 —— %', SQLERRM;
        END IF;
    END;

    -- ══════════ B · 没有理由 → 按名拒绝 ════════════════════════════════════════
    UPDATE hr_settings SET personal_data_retention_months = 12;
    BEGIN
        PERFORM anonymise_employee(v_emp, '   ');
        RAISE EXCEPTION 'FIXTURE 126B 失败:空白理由被收下了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%PDPA_REASON_REQUIRED%' THEN
            RAISE EXCEPTION 'FIXTURE 126B 失败:拒绝不是按名的 —— %', SQLERRM;
        END IF;
    END;

    -- ══════════ C · 人还在职 → 按名拒绝(目的还没有结束)══════════════════════
    BEGIN
        PERFORM anonymise_employee(v_emp3, '试着匿名一个在职的人');
        RAISE EXCEPTION 'FIXTURE 126C 失败:一个在职的人被匿名化了 —— 那不是合规,那是毁掉在用的数据';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%PDPA_EMPLOYEE_NOT_SEPARATED%' THEN
            RAISE EXCEPTION 'FIXTURE 126C 失败:拒绝不是按名的 —— %', SQLERRM;
        END IF;
    END;

    -- ══════════ D · 保留期没满 → 按名拒绝,并且说出到期日 ══════════════════════
    BEGIN
        PERFORM anonymise_employee(v_emp2, '还没到期就想删');
        RAISE EXCEPTION 'FIXTURE 126D 失败:保留期没满却匿名化了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%PDPA_RETENTION_NOT_ELAPSED%' THEN
            RAISE EXCEPTION 'FIXTURE 126D 失败:拒绝不是按名的 —— %', SQLERRM;
        END IF;
    END;

    -- ══════════ E · 一次【真的】匿名化 ════════════════════════════════════════
    v_rep := anonymise_employee(v_emp, '离职满 12 个月,保留目的结束');
    IF v_rep->>'employee_code' <> 'ZZFIX126-EMP-1' THEN
        RAISE EXCEPTION 'FIXTURE 126E 失败:回执没有说它匿名了谁 —— %', v_rep::text;
    END IF;

    SELECT * INTO v_row FROM employees WHERE id = v_emp;

    -- 【覆盖掉的:身份列】
    IF v_row.legal_name <> 'ANONYMISED ZZFIX126-EMP-1'
       OR v_row.preferred_name IS NOT NULL OR v_row.identity_no IS NOT NULL
       OR v_row.work_email IS NOT NULL OR v_row.work_phone IS NOT NULL
       OR v_row.work_pass_no IS NOT NULL OR v_row.work_pass_type IS NOT NULL
       OR v_row.work_pass_issue_date IS NOT NULL OR v_row.work_pass_expiry_date IS NOT NULL
       OR v_row.residency_status IS NOT NULL OR v_row.monthly_salary IS NOT NULL
       OR v_row.notes IS NOT NULL OR v_row.separation_notes IS NOT NULL
       OR v_row.job_title IS NOT NULL OR v_row.user_id IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 126E 失败:还有身份列没有被覆盖 —— 个人数据仍然在那里';
    END IF;
    IF v_row.anonymised_at IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 126E 失败:行上没有留痕,证明不了"已经不再保留"';
    END IF;

    -- 【留下的:结构性的列】—— 原则 7 要的可审计正是这些
    IF v_row.code <> 'ZZFIX126-EMP-1' OR v_row.employment_type <> 'full_time'
       OR v_row.work_category <> 'office' OR v_row.hire_date IS NULL
       OR v_row.separation_date IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 126E 失败:结构性的列被一起抹掉了 —— 历史读不回来了';
    END IF;

    -- 【薪资历史也是个人数据】
    SELECT count(*) INTO v_n FROM employment_history
     WHERE employee_id = v_emp
       AND (old_monthly_salary IS NOT NULL OR new_monthly_salary IS NOT NULL OR notes IS NOT NULL);
    IF v_n > 0 THEN
        RAISE EXCEPTION 'FIXTURE 126E 失败:employment_history 里还留着 % 行薪资/备注', v_n;
    END IF;
    -- 而那些行【本身】必须还在 —— 匿名化不是删除
    SELECT count(*) INTO v_n FROM employment_history WHERE employee_id = v_emp;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 126E 失败:employment_history 的行被删掉了 —— 那违反原则 7';
    END IF;

    -- ══════════ F · 已经匿名过 → 按名拒绝 ════════════════════════════════════
    BEGIN
        PERFORM anonymise_employee(v_emp, '再来一次');
        RAISE EXCEPTION 'FIXTURE 126F 失败:同一行被匿名化了两次';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%PDPA_ALREADY_ANONYMISED%' THEN
            RAISE EXCEPTION 'FIXTURE 126F 失败:拒绝不是按名的 —— %', SQLERRM;
        END IF;
    END;

    -- ══════════ G · 当事人查阅:没有参数,只导出【自己】 ══════════════════════
    -- 【它没有参数】—— 这不是一句注释,是一条可以断言的目录事实
    SELECT p.pronargs INTO v_n FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
     WHERE ns.nspname='public' AND p.proname='export_my_personal_data';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 126G 失败:export_my_personal_data 有 % 个参数 —— 它就能拿到别人的了', v_n;
    END IF;

    -- 换成乙的身份
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user2, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user2), true);
    v_rep := export_my_personal_data();
    IF v_rep->'about'->>'employee_code' <> 'ZZFIX126-EMP-2' THEN
        RAISE EXCEPTION 'FIXTURE 126G 失败:导出的不是调用者自己 —— %', v_rep->'about'->>'employee_code';
    END IF;
    IF v_rep->'about'->>'identity_no' IS DISTINCT FROM 'SZZFIX126B' THEN
        RAISE EXCEPTION 'FIXTURE 126G 失败:当事人拿不到自己的身份证号 —— 遮蔽保护的是别人看不到,不是他自己看不到';
    END IF;

    -- 【绩效评估的正文不在里面,而它的存在与时间在】
    IF NOT (v_rep ? 'performance_reviews_metadata_only') THEN
        RAISE EXCEPTION 'FIXTURE 126G 失败:评估元数据那一节整个不见了';
    END IF;
    IF v_rep->>'note' IS NULL OR v_rep->>'note' NOT LIKE '%evaluative-purpose%' THEN
        RAISE EXCEPTION 'FIXTURE 126G 失败:排除评估正文这件事没有【对当事人说出来】—— 一次沉默的省略与一次说明了的排除不是一回事';
    END IF;

    -- ══════════ H · 匿名化之后,那个人【查不到自己】—— 因为已经不再保留 ════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    BEGIN
        PERFORM export_my_personal_data();
        RAISE EXCEPTION 'FIXTURE 126H 失败:一个已经匿名化的人还导得出个人数据';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%PDPA_NO_EMPLOYEE_RECORD%' THEN
            RAISE EXCEPTION 'FIXTURE 126H 失败:拒绝不是按名的 —— %', SQLERRM;
        END IF;
    END;

    -- ══════════ I · 不可变守卫的例外必须【窄】════════════════════════════════
    -- PDPA-1-fu 给 employment_history 开了一条 UPDATE 例外。**一条例外如果宽了,
    -- 它就不再是例外而是一扇门。** 所以这一臂证明它只放过匿名化那一个形状。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 【先造出那一行】一次 UPDATE 匹配到零行不会碰到触发器,于是"被拒绝了"与
    -- "什么都没改到"在屏幕上一模一样。**这一臂第一版正是这样假绿的**:乙没有
    -- 任何履历行,三条断言全部对着空集跑。判据必须真的碰到那一行。
    INSERT INTO employment_history (employee_id, effective_date, change_type, job_title, notes)
      VALUES (v_emp2, (CURRENT_DATE - interval '6 months')::date, 'promotion',
              'ZZFIX126 原职务', 'ZZFIX126 原备注');
    SELECT count(*) INTO v_n FROM employment_history
     WHERE employee_id = v_emp2 AND change_type = 'promotion';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 126I 前置失败:那一行没有造出来,后面三条会对着空集变绿';
    END IF;

    -- ① 普通改历史 —— 照旧拒绝
    BEGIN
        UPDATE employment_history SET job_title = 'ZZFIX126 改历史'
         WHERE employee_id = v_emp2 AND change_type = 'promotion';
        RAISE EXCEPTION 'FIXTURE 126I-1 失败:任职履历被普通 UPDATE 改动了 —— 不可变没了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%EMPLOYMENT_HISTORY_IMMUTABLE%' THEN
            RAISE EXCEPTION 'FIXTURE 126I-1 失败:拒绝不是按名的 —— %', SQLERRM;
        END IF;
    END;

    -- ② DELETE —— 永远拒绝(匿名化不删行)
    BEGIN
        DELETE FROM employment_history WHERE employee_id = v_emp;
        RAISE EXCEPTION 'FIXTURE 126I-2 失败:履历行被删掉了 —— 原则 7 的可审计靠的正是它们还在';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%EMPLOYMENT_HISTORY_IMMUTABLE%' THEN
            RAISE EXCEPTION 'FIXTURE 126I-2 失败:拒绝不是按名的 —— %', SQLERRM;
        END IF;
    END;

    -- ③ **披着匿名化外衣的改动** —— 置了 anonymised_at,却【顺手】改了别的列。
    --    这是这一臂真正要挡的那件事:例外由形状定义,而这个形状不对。
    BEGIN
        UPDATE employment_history
           SET anonymised_at = now(), old_monthly_salary = NULL, new_monthly_salary = NULL,
               notes = NULL,
               job_title = 'ZZFIX126 偷改的职务'   -- ← 这一列不该动
         WHERE employee_id = v_emp2 AND change_type = 'promotion';
        RAISE EXCEPTION 'FIXTURE 126I-3 失败:一次【披着匿名化外衣】的改动通过了 —— 那条例外是一扇门,不是一个形状';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%EMPLOYMENT_HISTORY_IMMUTABLE%' THEN
            RAISE EXCEPTION 'FIXTURE 126I-3 失败:拒绝不是按名的 —— %', SQLERRM;
        END IF;
    END;

    -- ④ 而【正确的那个形状】通过 —— 否则上面三条只是证明了"什么都不放过"
    UPDATE employment_history
       SET anonymised_at = now(), old_monthly_salary = NULL,
           new_monthly_salary = NULL, notes = NULL
     WHERE employee_id = v_emp2 AND change_type = 'promotion';
    SELECT count(*) INTO v_n FROM employment_history
     WHERE employee_id = v_emp2 AND change_type = 'promotion'
       AND anonymised_at IS NOT NULL AND notes IS NULL AND job_title = 'ZZFIX126 原职务';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 126I-4 失败:匿名化形状本身没有通过,或者动了不该动的列';
    END IF;

END $$;
ROLLBACK;
