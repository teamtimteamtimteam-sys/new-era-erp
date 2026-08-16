-- 78 员工↔登录账号:指向空气的 id 当场被拒;账号被回收时人还在(EXEC-2)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么值得常设】这一列的两个读者都【不会报错】:签发档面板拿不到名字就显示
-- "该账号未关联员工档案",绩效评估的分派路径只是查不到人。所以一个敲错的 uuid
-- 在屏幕上与"这个人没有账号"长得一模一样 —— 那正是外键要挡的东西,
-- 而外键有没有生效,只有行为断言看得见(镜像比对看结构,看不出它拦不拦得住)。
--
-- 三臂,而第三臂是这条外键【选了哪一种删除行为】的断言:
--   A 指向空气的 uuid → 被拒,且按【约束名】断言(不是"报了个错就算");
--   B 真的账号 → 连得上,并且留得住;
--   C 账号被回收 → **员工行还在,只有那根线断了**(ON DELETE SET NULL)。
--     一个写 CASCADE 的实现在这一臂会把员工删掉;一个写 RESTRICT 的会拒绝删账号。
--     三种行为在 A、B 两臂上完全一样 —— 只有这一臂分得开。
--
-- 自带数据(README 第 2 条)。auth.users 由 platform-prelude 提供,重建库里也在。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_uid   uuid := gen_random_uuid();
    v_dept  uuid;
    v_emp   uuid;
    v_msg text; v_denied boolean; v_n integer;
BEGIN
    -- 一个真的登录账号(prelude 建的 auth.users 只有 id 一列是必须的)
    INSERT INTO auth.users (id) VALUES (v_uid);

    INSERT INTO departments (code, name_en, name_zh)
    VALUES ('ZZ78-D', 'f78', 'f78') RETURNING id INTO v_dept;

    -- ══════════ A. 指向空气的 uuid → 被拒,按约束名 ═════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO employees (code, legal_name, department_id, hire_date,
                               employment_type, work_category, user_id)
        VALUES ('ZZ78-E1', 'fixture 78 bogus link', v_dept, DATE '2028-01-01',
                'full_time', 'office', gen_random_uuid());
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 78A 失败:指向空气的 user_id 应当被拒 —— 静默入库的话,读者只会"查不到人",而那与"这个人没有账号"长得一模一样';
    END IF;
    -- 【按名断言,不是"报了个错就算"】别的约束也会报错,而那些错误证明不了
    -- 这条外键存在。**这句断言第一次跑就证明了自己**:那一版少写了两个必填列,
    -- 于是被拒的原因是 employment_type 的非空约束 —— 只写"被拒了"的话,
    -- 那一版会通过,而这条外键当时还没被验到分毫。
    IF v_msg NOT LIKE '%employees_user_id_fkey%' THEN
        RAISE EXCEPTION 'FIXTURE 78A 失败:拒绝应当来自 employees_user_id_fkey,实得 %', v_msg;
    END IF;

    -- ══════════ B. 真的账号 → 连得上,而且留得住 ═════════════════════════════
    INSERT INTO employees (code, legal_name, department_id, hire_date,
                           employment_type, work_category, user_id)
    VALUES ('ZZ78-E2', 'fixture 78 real link', v_dept, DATE '2028-01-01',
            'full_time', 'office', v_uid)
    RETURNING id INTO v_emp;
    IF (SELECT user_id FROM employees WHERE id = v_emp) IS DISTINCT FROM v_uid THEN
        RAISE EXCEPTION 'FIXTURE 78B 失败:合法的账号应当连得上';
    END IF;

    -- ══════════ C. 账号被回收 → 人还在,线断了 ══════════════════════════════
    -- 【这一臂是本刀选了哪种删除行为的断言】CASCADE 会把员工删掉,
    -- RESTRICT 会拒绝删账号 —— 两者在 A、B 臂上与 SET NULL 完全一样。
    DELETE FROM auth.users WHERE id = v_uid;

    SELECT count(*) INTO v_n FROM employees WHERE id = v_emp;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 78C 失败:回收一个登录账号不该删掉员工档案 —— 员工是 HR 的记录,它的存在与这个人有没有系统账号无关(实得 % 行)', v_n;
    END IF;
    IF (SELECT user_id FROM employees WHERE id = v_emp) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 78C 失败:账号没了之后那根线应当断成 NULL,而不是指着一个已删的 id';
    END IF;
END $$;
ROLLBACK;
