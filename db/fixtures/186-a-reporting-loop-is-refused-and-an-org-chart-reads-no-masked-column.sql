-- 186 汇报环写不进去;而组织架构图读的那几列,一个遮蔽列都没有
--
-- CHART-1 ③(2026-09-03)。**这支 fixture 钉的是【库那一半】。**
-- 树的推导那一半(没有上级 / 多个根 / 上级看不见 / 空部门 / 环 / 自环)
-- 住在 lib/orgTree.ts,由 scripts/check-org-tree.mjs 逐个喂 —— 那些分支
-- **线上一次都走不到**(实测 2026-09-03:9 个未删员工,manager_id 非空 0 个),
-- 所以它们只能在纯函数那一侧被断言。两边合起来才完整,谁都不能冒充谁。
--
-- 这里问的是库自己回答得了的三个问题:
--   A. 一条汇报环,**写得进去吗**?(guard_manager_cycle)
--   B. employees_masked 的可见性,**真的**是「有 module.hr.view 看全部,
--      没有就只看得见自己」吗?—— ③ 要求「按 live 授权算出来,不是假设」,
--      而一份算出来的答案要有人去【验】它。
--   C. 组织架构图读的那七列,**没有一列是遮蔽列**。
--
-- ★【为什么 C 要用 has_column_privilege 而不是"我看了一眼视图定义"】★
-- 遮蔽是**列授权**这一侧的事实,而不是某份文档里的一句话。写死一份"遮蔽列清单"
-- 就是本仓库反复付账的那个形状 —— 线上收回第六列的那天,那份清单只会烂在原地,
-- 而这一页会开始把它读出来。这里现问 pg_catalog,所以它跟得上。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_hr      uuid := gen_random_uuid();   -- 持 module.hr.view
    v_plain   uuid := gen_random_uuid();   -- 【不】持 module.hr.view,但他自己是一名员工
    r_hr uuid; r_plain uuid;
    e_boss uuid; e_sub uuid; e_plain uuid;
    v_dept uuid;
    n int; n_self int; n_boss int;
    v_msg text;
    v_cycle_refused boolean := false;
    v_masked text[];
    v_read   text[] := ARRAY['id','code','legal_name','preferred_name',
                             'department_id','manager_id','employment_status'];
    v_overlap text[];
BEGIN
    -- ── 场景:两个账号 + 一个部门 + 三名员工 ──────────────────────────────
    INSERT INTO auth.users (id) VALUES (v_hr), (v_plain);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-186-hr','f','f',true) RETURNING id INTO r_hr;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_hr, 'module.hr.view');
    -- 【他有权限,只是没有 hr 的】—— 否则"看不见"可能只是"他什么都没有",
    -- 那样 B 臂就证明不了是 module.hr.view 在把门(fixture 183 同一条讲究)。
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-186-plain','f','f',true) RETURNING id INTO r_plain;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_plain, 'module.inventory.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_hr, r_hr), (v_plain, r_plain);

    INSERT INTO departments (code, name_en, name_zh)
    VALUES ('ZZFIX186-D','fixture 186 dept','186 部门') RETURNING id INTO v_dept;

    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status, department_id)
    VALUES ('ZZFIX186-BOSS','fixture 186 boss','full_time','office',DATE '2027-01-01','active', v_dept)
    RETURNING id INTO e_boss;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status, manager_id)
    VALUES ('ZZFIX186-SUB','fixture 186 sub','full_time','office',DATE '2027-01-02','active', e_boss)
    RETURNING id INTO e_sub;
    -- 这一位【绑着那个不持 hr 权限的账号】—— B 臂要的正是"他看得见自己"
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status, user_id)
    VALUES ('ZZFIX186-PLAIN','fixture 186 plain','full_time','office',DATE '2027-01-03','active', v_plain)
    RETURNING id INTO e_plain;

    -- ══════════ A. 一条汇报环【写不进去】 ═════════════════════════════════
    -- boss → sub 已经存在;现在让 boss 汇报给 sub,就成了 A→B→A。
    -- 【这条断言是本刀报告里一句话的证据】:页面上的"环"分支是防御性的,
    -- 因为库【在写入那一刻就拦住了】。没有这条断言,那句话就只是我读了一遍触发器。
    BEGIN
        UPDATE employees SET manager_id = e_sub WHERE id = e_boss;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg = 'MANAGER_CYCLE' THEN
            v_cycle_refused := true;
        ELSE
            RAISE EXCEPTION 'FIXTURE 186A 失败:环被拒了,但拒绝的名字不对(实得 %)', v_msg;
        END IF;
    END;
    IF NOT v_cycle_refused THEN
        RAISE EXCEPTION 'FIXTURE 186A 失败:A→B→A 居然写进去了 —— guard_manager_cycle 没有拦住';
    END IF;

    -- 自环同理:一个人不能是自己的上级
    v_cycle_refused := false;
    BEGIN
        UPDATE employees SET manager_id = e_plain WHERE id = e_plain;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg = 'MANAGER_CYCLE' THEN v_cycle_refused := true; END IF;
    END;
    IF NOT v_cycle_refused THEN
        RAISE EXCEPTION 'FIXTURE 186A2 失败:自环(自己是自己的上级)居然写进去了';
    END IF;

    -- ══════════ B. 可见性:持 hr 看全部,不持只看得见自己 ══════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_hr), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n FROM employees_masked
     WHERE code IN ('ZZFIX186-BOSS','ZZFIX186-SUB','ZZFIX186-PLAIN');
    RESET ROLE;
    IF n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 186B 失败:持 module.hr.view 的读者应当看得见全部 3 名(实得 %)', n;
    END IF;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_plain), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_self FROM employees_masked WHERE id = e_plain;
    SELECT count(*) INTO n_boss FROM employees_masked WHERE id = e_boss;
    RESET ROLE;
    IF n_self <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 186B2 失败:不持 hr 权限的员工应当看得见【自己】(实得 % 行)', n_self;
    END IF;
    IF n_boss <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 186B3 失败:不持 hr 权限的员工不该看得见别人(看见了 % 行)', n_boss;
    END IF;

    -- ══════════ C. 本页读的七列,一个遮蔽列都没有 ═════════════════════════
    -- 【遮蔽列 = authenticated 读不到的列】—— 现问 pg_catalog,不抄清单。
    SELECT array_agg(a.attname ORDER BY a.attnum) INTO v_masked
      FROM pg_attribute a
     WHERE a.attrelid = 'public.employees'::regclass
       AND a.attnum > 0 AND NOT a.attisdropped
       AND NOT has_column_privilege('authenticated', 'public.employees', a.attname, 'SELECT');

    -- 【解析出 0 个不是"没有遮蔽列"】—— 那是解析器坏了,或者遮蔽整个没了。
    -- 两种都必须响,而不是让 C 臂真空通过(fixture 26 那一课)。
    IF v_masked IS NULL OR array_length(v_masked, 1) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 186C 失败:employees 上一个遮蔽列都查不出来 —— 遮蔽没了,或者这条断言问错了';
    END IF;

    SELECT array_agg(x) INTO v_overlap FROM unnest(v_read) x WHERE x = ANY(v_masked);
    IF v_overlap IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 186C 失败:组织架构图读的列里有遮蔽列 —— %(遮蔽列全集:%)',
            array_to_string(v_overlap, ', '), array_to_string(v_masked, ', ');
    END IF;

    -- 反方向:那七列必须【真的读得到】。少了这一句,把 v_read 写成一个
    -- 根本不存在的列名也会"通过" —— 一条恒真的断言等于没有断言。
    FOR n IN 1 .. array_length(v_read, 1) LOOP
        IF NOT has_column_privilege('authenticated', 'public.employees', v_read[n], 'SELECT') THEN
            RAISE EXCEPTION 'FIXTURE 186C2 失败:本页要读的列 % ,authenticated 读不到', v_read[n];
        END IF;
    END LOOP;

    RAISE NOTICE 'fixture 186 ok:环两种都被按名拒 · 可见性 3/1/0 · 遮蔽列 % 列,与本页所读七列无交集',
        array_length(v_masked, 1);
END $$;
ROLLBACK;
