-- 32 审批留痕:驳回之后再批准留下【两行】,不是一行被覆盖;只增不改;金额冻结在当时
--
-- 【判别臂是 A:驳回 → 再提 → 批准】
-- 只测"批准写了一行"是【测不出任何东西的】—— 现有的列覆盖式写法(leave_requests
-- 的 decided_at/decided_by)在那种测法下同样通过。Doc 1 要的是"谁批的、谁驳的、
-- 什么时候",而恰恰是【被覆盖掉的那次驳回】证明这张表存在的理由。
-- 所以断言的是:同一张单子上留痕有两行,且顺序与决定一致。
--
-- 【B/C 臂:只增不改】UPDATE 与 DELETE 各自点名拒绝。守卫【自己报名】而不是靠外键
-- 顺带挡住 —— FIN-31 的教训:硬删此前只是被一条审计表外键"顺便"拦着,那不是拒绝。
--
-- 【D 臂:金额冻结】决定写下之后再改单据金额,留痕里的数【不许跟着动】。
-- 这是 FIN-27 抄条款的同一条理由,也是决定 4(改价抬过阈值就作废重路由)的依据:
-- 拿新金额跟冻结的那个比,而不是跟一个已经变了的自己比。
--
-- 【E 臂:主体必须存在】(subject_type, subject_id) 没有外键,补偿是唯一写入口
-- 会先核对。指向空气的 subject_id 必须被点名拒绝,否则那条取舍就是白让的。
--
-- 【切数据库角色】(README 第 6 条):RLS 的读策略按 subject_type 分模块判,
-- 不切角色就测不到它。fixture 以 postgres 跑会绕过 RLS。
BEGIN;
DO $$
DECLARE
    u_hr uuid := gen_random_uuid();
    u_none uuid := gen_random_uuid();
    r_hr uuid; r_none uuid;
    v_emp uuid; v_ccy text;
    v_claim uuid; v_claim2 uuid;
    v_rows int; v_types text[];
    v_first text; v_second text;
    v_frozen numeric; v_after numeric;
    v_log_id uuid;
    v_denied boolean;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    -- 医疗额度按 system_start_date 设界(HR-6),不设它 decide_medical_claim 会
    -- 拒绝 —— README 第 4 条:需要什么就自己设,不继承。
    UPDATE finance_settings SET system_start_date = '2027-01-01', locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-32-hr', 'f', 'f', true) RETURNING id INTO r_hr;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_hr, 'module.hr.edit'), (r_hr, 'module.hr.view');
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-32-none', 'f', 'f', true) RETURNING id INTO r_none;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_none, 'module.finance.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_hr, r_hr), (u_none, r_none);

    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('ZZFIX32-E', 'fixture 32 employee', 'full_time', 'office', '2027-01-01')
    RETURNING id INTO v_emp;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_hr), true);

    -- ══════════ A. 驳回 → 再提 → 批准:留痕【两行】,不是一行被覆盖 ══════════
    -- 医疗报销走这一臂:它的决定函数最短,而且带金额(D 臂要用)。
    INSERT INTO medical_claims (code, employee_id, claim_date, claim_year, amount_sgd)
    VALUES ('ZZFIX32-MC1', v_emp, '2027-03-01', 2027, 120) RETURNING id INTO v_claim;

    PERFORM decide_medical_claim(v_claim, false, 'fixture 32: missing receipt');

    -- 现实里"再提"是新开一张单;这里同一张单再走一次决定,足以证明留痕不覆盖。
    -- (把状态推回 submitted 是 fixture 的手法,不是产品路径 —— 产品路径在 APR-2。)
    UPDATE medical_claims SET status = 'submitted' WHERE id = v_claim;
    PERFORM decide_medical_claim(v_claim, true, 'fixture 32: receipt provided');

    SELECT count(*) INTO v_rows FROM approval_log
     WHERE subject_type = 'medical_claim' AND subject_id = v_claim;
    IF v_rows <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 32A 失败:驳回再批准应留下【2】行留痕,实得 % 行 —— 1 行意味着第二次决定把第一次覆盖了,那正是这张表要终结的行为(而"只测一次批准"的写法在覆盖式实现下同样会通过)',
            v_rows;
    END IF;

    -- 【按 seq 排,不按 decided_at】同一个事务里两次决定的 now() 是同一个值 ——
    -- 用时间戳排序在这里是不确定的,而"先驳回后批准"正是本臂要讲的事。
    SELECT decision INTO v_first FROM approval_log
     WHERE subject_type='medical_claim' AND subject_id=v_claim ORDER BY seq LIMIT 1;
    SELECT decision INTO v_second FROM approval_log
     WHERE subject_type='medical_claim' AND subject_id=v_claim ORDER BY seq DESC LIMIT 1;
    IF v_first <> 'rejected' OR v_second <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 32A 失败:两行的顺序应为 rejected → approved,实得 % → % —— 顺序错了等于把"先被驳回过"这件事讲反了',
            v_first, v_second;
    END IF;

    -- 而单据自己【仍然只记得最后一次】—— 这就是为什么留痕不能是行上的列。
    IF (SELECT status FROM medical_claims WHERE id = v_claim) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 32A 前置失败:单据终态应为 approved';
    END IF;

    -- ══════════ B. UPDATE 被点名拒绝 ════════════════════════════════════════
    SELECT id INTO v_log_id FROM approval_log
     WHERE subject_type='medical_claim' AND subject_id=v_claim LIMIT 1;
    v_denied := false;
    BEGIN
        UPDATE approval_log SET note = 'tampered' WHERE id = v_log_id;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'APPROVAL_LOG_APPEND_ONLY|update%' THEN
            RAISE EXCEPTION 'FIXTURE 32B 失败:UPDATE 被拒了,但报的不是自己的名字,而是「%」—— 靠别的约束顺带挡住不算拒绝(FIN-31)', SQLERRM;
        END IF;
        v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 32B 失败:留痕被 UPDATE 成功了 —— 能改写的留痕不是留痕';
    END IF;

    -- ══════════ C. DELETE 被点名拒绝 ════════════════════════════════════════
    v_denied := false;
    BEGIN
        DELETE FROM approval_log WHERE id = v_log_id;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'APPROVAL_LOG_APPEND_ONLY|delete%' THEN
            RAISE EXCEPTION 'FIXTURE 32C 失败:DELETE 被拒了,但报的不是自己的名字,而是「%」', SQLERRM;
        END IF;
        v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 32C 失败:留痕被 DELETE 成功了';
    END IF;

    -- ══════════ D. 金额冻结在决定当时 ═══════════════════════════════════════
    INSERT INTO medical_claims (code, employee_id, claim_date, claim_year, amount_sgd)
    VALUES ('ZZFIX32-MC2', v_emp, '2027-04-01', 2027, 200) RETURNING id INTO v_claim2;
    PERFORM decide_medical_claim(v_claim2, true, 'fixture 32: frozen amount');

    SELECT amount_base INTO v_frozen FROM approval_log
     WHERE subject_type='medical_claim' AND subject_id=v_claim2;
    IF v_frozen <> 200 THEN
        RAISE EXCEPTION 'FIXTURE 32D 失败:决定当时的金额应冻结为 200,实得 %', v_frozen;
    END IF;
    IF (SELECT count(*) FROM approval_log WHERE subject_id = v_claim2) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 32D 失败:一次决定应恰好写一行留痕';
    END IF;

    -- 单据金额事后被改动 —— 留痕里的数【不许跟着动】
    UPDATE medical_claims SET amount_sgd = 999 WHERE id = v_claim2;
    SELECT amount_base INTO v_after FROM approval_log
     WHERE subject_type='medical_claim' AND subject_id=v_claim2;
    IF v_after <> v_frozen THEN
        RAISE EXCEPTION 'FIXTURE 32D 失败:单据改成 999 之后,留痕里的金额从 % 变成了 % —— 那说明它是 join 出来的,不是冻结的,于是"批的时候值多少"这个问题永远问不出答案',
            v_frozen, v_after;
    END IF;
    IF (SELECT amount_sgd FROM medical_claims WHERE id = v_claim2) <> 999 THEN
        RAISE EXCEPTION 'FIXTURE 32D 前置失败:单据金额没有真的改掉,本臂是空转的';
    END IF;

    -- ══════════ E. 主体不存在 → 点名拒绝(外键换来的那个补偿)════════════════
    v_denied := false;
    BEGIN
        PERFORM record_approval_decision('medical_claim', gen_random_uuid(), 'approved', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'APPROVAL_SUBJECT_NOT_FOUND%' THEN
            RAISE EXCEPTION 'FIXTURE 32E 失败:主体不存在时报的不是 APPROVAL_SUBJECT_NOT_FOUND,而是「%」', SQLERRM;
        END IF;
        v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 32E 失败:可以对一个不存在的主体写留痕 —— 放弃外键换来的唯一补偿失效了';
    END IF;

    -- 未知的 subject_type 同样要被点名(CHECK 枚举之外的字符串)
    v_denied := false;
    BEGIN
        PERFORM record_approval_decision('not_a_subject', v_claim2, 'approved', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN
        v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 32E 失败:未知的 subject_type 被接受了';
    END IF;

    -- ══════════ F. 读策略按模块分:HR 的留痕不给只有财务权限的人 ══════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_hr), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_rows FROM approval_log WHERE subject_type = 'medical_claim';
    RESET ROLE;
    IF v_rows < 3 THEN
        RAISE EXCEPTION 'FIXTURE 32F 失败:持 module.hr.view 的读者应看得见本 fixture 写的 3 行医疗报销留痕,实得 %', v_rows;
    END IF;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_none), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_rows FROM approval_log WHERE subject_type = 'medical_claim';
    RESET ROLE;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 32F 失败:只有 module.finance.view 的读者不该看见医疗报销的留痕,实得 % 行', v_rows;
    END IF;
END $$;
ROLLBACK;
