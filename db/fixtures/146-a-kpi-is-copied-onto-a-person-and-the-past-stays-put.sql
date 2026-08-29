-- 146 KPI-1:KPI 是【复制】到人身上的,而复制出去的那一份不再随模板变
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【五个点名要躲开的陷阱,逐条写出它是怎么躲的】
--
--  (a) **一条断言之所以过,是因为两份实现碰巧一致。**
--      C 臂不比"两个实现算出同一个数",它比的是【同一个对象在两个时刻】:
--      复制 → 改模板 → 再读那份副本,断言它**逐字节没变**。
--      一个"读取时回查模板"的实现在这里必定红 —— 它会跟着模板一起变。
--
--  (b) **一条目录断言命中的是注释里的一次提及。**
--      G 臂查的是 pg_constraint / pg_policy / pg_proc.prosecdef / pg_trigger
--      这些**目录事实**,不 grep 源码文本。注释里写一万遍 "DEFERRABLE"
--      也不会让那个约束触发器存在。
--
--  (c) **一支 SECURITY DEFINER 函数没有权限检查。**
--      F 臂**真的用一个没权限的角色去调**两支新函数,断言按名拒 ——
--      而不是去源码里找 require_permission 那几个字(那属于陷阱 b)。
--
--  (d) **断言过了,是因为那个集合是空的。**
--      每一处比对之前先断言集合非空、而且【正好是预期的行数】。
--      A 臂尤其要紧:它拿职位级矩阵与规格 §9.1 那张【已验算过】的表逐格对 ——
--      六行、每行五个数,一个空视图过不去。
--
--  (e) **一个什么都没注入的注入,长得和一个通过了的注入一模一样。**
--      每一处 replace 之后都断言【定义真的变了】,变不了就当场报
--      "这个注入什么也没删"。fixture 77 就是这样红过一次的。
--
-- 【本 fixture 钉住的东西】
--   A ★ 职位级联动矩阵 = 规格 §9.1 那张验算过的表(六行逐格)
--   B 权重闸:组织 100、每职位 100 —— 而且是【提交时】才判(DEFERRABLE)
--   C ★★ 复制不是引用:改模板,已复制的条目【逐字节不变】★★(5.4)
--   D 打分:0–5、算出来的 vs 人判的、安全否决是【封顶】不是分数
--   E roll-up:没打分的不算 0;封顶进得了加权分
--   F 权限:两支 definer 函数各自按名拒;而权限补回来就放行(证明那不是死路)
--   G 目录事实
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    r_all    uuid;
    v_pos    uuid;
    v_emp    uuid;
    v_cycle  uuid;
    v_tpl    uuid;
    v_before jsonb;
    v_after  jsonb;
    v_r      jsonb;
    v_n      integer;
    v_num    numeric;
    v_denied boolean;
    v_msg    text;
    v_row    record;
    def_asg  text;
    v_inj    text;
    -- 规格 §9.1 那张【已经验算过】的表,逐字抄进来当对照
    -- (它在规格里已经与原表第五页逐格核对过,六行全中)
    v_expect jsonb := '{
        "MD":       [1,1,1,1,1],
        "CFO":      [1,1,4,0,1],
        "CTO":      [1,3,0,0,2],
        "CCO":      [0,0,3,5,1],
        "LEAD-ACC": [1,0,2,0,3],
        "LEAD-WH":  [1,1,1,2,3]}'::jsonb;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-146', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    def_asg := pg_get_functiondef('public.assign_position_kpis(uuid,uuid)'::regprocedure);

    -- ══════════ A. ★ 矩阵 = 规格 §9.1 那张验算过的表,六行逐格 ★ ═══════════
    -- 陷阱 (d):先证明它【不是空的】,而且正好六行。
    SELECT count(*) INTO v_n FROM kpi_position_linkage_matrix;
    IF v_n <> 6 THEN
        RAISE EXCEPTION 'FIXTURE 146A 失败:职位级矩阵应当有 6 行,实得 % —— 少一行就不是那张表了', v_n;
    END IF;
    FOR v_row IN SELECT * FROM kpi_position_linkage_matrix LOOP
        IF NOT (v_expect ? v_row.position_code) THEN
            RAISE EXCEPTION 'FIXTURE 146A 失败:矩阵里多出一个职位 % —— 规格 §9.1 只有六个', v_row.position_code;
        END IF;
        IF v_row.o1_count <> (v_expect->v_row.position_code->>0)::int
           OR v_row.o2_count <> (v_expect->v_row.position_code->>1)::int
           OR v_row.o3_count <> (v_expect->v_row.position_code->>2)::int
           OR v_row.o4_count <> (v_expect->v_row.position_code->>3)::int
           OR v_row.o5_count <> (v_expect->v_row.position_code->>4)::int THEN
            RAISE EXCEPTION 'FIXTURE 146A 失败:% 的联动数与规格 §9.1 对不上 —— 实得 %/%/%/%/%,应为 %',
                v_row.position_code, v_row.o1_count, v_row.o2_count, v_row.o3_count,
                v_row.o4_count, v_row.o5_count, v_expect->v_row.position_code;
        END IF;
        -- 每个职位五条、合计 100
        IF v_row.kpi_count <> 5 THEN
            RAISE EXCEPTION 'FIXTURE 146A 失败:% 应当有 5 条 KPI,实得 %', v_row.position_code, v_row.kpi_count; END IF;
        IF v_row.weight_total <> 100 THEN
            RAISE EXCEPTION 'FIXTURE 146A 失败:% 的权重合计应当 100,实得 %', v_row.position_code, v_row.weight_total; END IF;
    END LOOP;
    -- 组织那五条也要合计 100(§9.3 的另一半)
    SELECT count(*), sum(weight_pct) INTO v_n, v_num FROM kpi_organisation;
    IF v_n <> 5 OR v_num <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 146A 失败:组织 KPI 应当 5 条、合计 100,实得 % 条 / %', v_n, v_num; END IF;

    -- ══════════ B. 权重闸 —— 而它必须在【提交时】才判 ═══════════════════════
    -- 【为什么这一臂要用子事务】DEFERRABLE 约束触发器在 COMMIT 时才跑,
    -- 而 fixture 整支跑在一笔最终 ROLLBACK 的事务里 —— 直接改会等到最后才炸,
    -- 那时已经分不清是哪一臂。用 SAVEPOINT 造一个能提交的内层边界。
    BEGIN
        UPDATE kpi_organisation SET weight_pct = weight_pct + 5 WHERE code = 'O1';
        -- 到这里【还不该报错】—— 闸是 DEFERRABLE 的,立即报错说明它被写成了即时触发器
        PERFORM 1;
        SET CONSTRAINTS ALL IMMEDIATE;   -- 逼它现在判
        RAISE EXCEPTION 'FIXTURE 146B 失败:组织权重改成 105 之后,那道闸没有拦住';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'KPI_ORG_WEIGHTS_NOT_100|%' THEN
            RAISE EXCEPTION 'FIXTURE 146B 失败:期望 KPI_ORG_WEIGHTS_NOT_100,实得 %', SQLERRM;
        END IF;
    END;
    -- 【回到干净状态】子事务已回滚,重新把约束设回 DEFERRED
    SET CONSTRAINTS ALL DEFERRED;
    SELECT sum(weight_pct) INTO v_num FROM kpi_organisation;
    IF v_num <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 146B 失败:被拒之后权重应当还是 100,实得 %', v_num; END IF;

    -- ══════════ 场景:一个人、一个职位、一个周期 ═══════════════════════════
    SELECT id INTO v_pos FROM positions WHERE code = 'CTO';
    INSERT INTO employees (code, legal_name, hire_date, employment_type, work_category,
                           employment_status, position_id)
    VALUES ('ZZ146-E1', 'Fixture 146 person', '2026-01-01', 'full_time', 'office',
            'active', v_pos)
    RETURNING id INTO v_emp;
    INSERT INTO kpi_cycles (name, period_start, period_end, due_date, status, gate)
    VALUES ('Fixture 146 cycle', '2026-09-01', '2026-11-30', '2026-12-05', 'open', 'M3')
    RETURNING id INTO v_cycle;

    -- ══════════ C. ★★ 复制不是引用 ★★(5.4 —— 本刀最要紧的一臂)══════════
    v_r := assign_position_kpis(v_emp, v_cycle);
    IF (v_r->>'entries_created')::int <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 146C 失败:应当复制出 5 条,实得 %', v_r->>'entries_created'; END IF;
    -- 陷阱 (d):比对之前先证明集合非空且正好 5 行
    SELECT count(*) INTO v_n FROM kpi_entries WHERE employee_id = v_emp AND cycle_id = v_cycle;
    IF v_n <> 5 THEN RAISE EXCEPTION 'FIXTURE 146C 失败:条目应当 5 条,实得 %', v_n; END IF;

    -- 复制【之前】的快照:把每一个抄过来的字段都收进去
    SELECT jsonb_agg(jsonb_build_object(
               'ref', kpi_ref, 'title', title, 'w', weight_pct, 'target', target_text,
               'prov', is_provisional, 'note', provisional_note, 'org', org_codes,
               'src_ver', source_template_version) ORDER BY kpi_ref)
      INTO v_before FROM kpi_entries WHERE employee_id = v_emp AND cycle_id = v_cycle;

    -- ★ 现在【改模板】—— 改得面目全非,而且把版本推上去 ★
    SELECT id INTO v_tpl FROM kpi_position_templates
     WHERE position_id = v_pos AND kpi_ref = 'C1';
    UPDATE kpi_position_templates
       SET title = 'REWRITTEN BY FIXTURE 146',
           target_text = 'REWRITTEN TARGET — if this reaches a copied entry, copy has degraded into reference',
           is_provisional = true,
           provisional_note = 'rewritten',
           version = version + 1
     WHERE id = v_tpl;
    -- 权重不动 —— 动了会撞那道 100 的闸,而这一臂要测的不是闸
    DELETE FROM kpi_template_org_links WHERE template_id = v_tpl;
    INSERT INTO kpi_template_org_links (template_id, org_code) VALUES (v_tpl, 'O4');

    -- ★★ 断言:那五条【逐字节】没变 ★★
    SELECT jsonb_agg(jsonb_build_object(
               'ref', kpi_ref, 'title', title, 'w', weight_pct, 'target', target_text,
               'prov', is_provisional, 'note', provisional_note, 'org', org_codes,
               'src_ver', source_template_version) ORDER BY kpi_ref)
      INTO v_after FROM kpi_entries WHERE employee_id = v_emp AND cycle_id = v_cycle;
    IF v_before IS DISTINCT FROM v_after THEN
        RAISE EXCEPTION 'FIXTURE 146C 失败:★ 改了职位模板之后,已经复制出去的条目变了 ★ / 之前 = % / 之后 = %',
            v_before, v_after;
    END IF;
    -- 【而模板【确实】变了 —— 否则上面那句"没变"什么也没证明】
    IF (SELECT title FROM kpi_position_templates WHERE id = v_tpl) <> 'REWRITTEN BY FIXTURE 146' THEN
        RAISE EXCEPTION 'FIXTURE 146C 失败:模板没有被改动 —— 这一臂因此证明不了任何事'; END IF;
    -- 【副本记着的是【复制那一刻】的版本,不是模板现在的版本】
    SELECT source_template_version INTO v_n FROM kpi_entries
     WHERE employee_id = v_emp AND cycle_id = v_cycle AND kpi_ref = 'C1';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 146C 失败:副本应当记着复制时的版本 1,实得 %', v_n; END IF;
    IF (SELECT version FROM kpi_position_templates WHERE id = v_tpl) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 146C 失败:模板版本应当已经推到 2'; END IF;

    -- 【重复生成按名拒】—— 而不是悄悄再长出一套
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM assign_position_kpis(v_emp, v_cycle);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'KPI_ENTRIES_ALREADY_GENERATED|%' THEN
        RAISE EXCEPTION 'FIXTURE 146C 失败:重复生成应当按名拒,实得 %', COALESCE(v_msg,'(又生成了一套)'); END IF;

    -- ══════════ D. 打分:0–5、算的 vs 判的、安全否决是【封顶】═══════════════
    SELECT id INTO v_tpl FROM kpi_entries
     WHERE employee_id = v_emp AND cycle_id = v_cycle AND kpi_ref = 'C1';
    -- 范围
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM score_kpi_entry(v_tpl, 6); EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'KPI_SCORE_OUT_OF_RANGE|%' THEN
        RAISE EXCEPTION 'FIXTURE 146D 失败:6 分应当被拒,实得 %', COALESCE(v_msg,'(收下了)'); END IF;
    -- ★【说自己是算出来的,就得说出算的是什么】★ 否则 computed 只是个好看的标签
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM score_kpi_entry(v_tpl, 4, 'computed');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'KPI_COMPUTED_NEEDS_BASIS|%' THEN
        RAISE EXCEPTION 'FIXTURE 146D 失败:computed 没有 basis 应当被拒,实得 %', COALESCE(v_msg,'(收下了)'); END IF;
    -- 封顶要有理由
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM score_kpi_entry(v_tpl, 4, 'judged', NULL, NULL, 2);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'KPI_OVERRIDE_NEEDS_REASON|%' THEN
        RAISE EXCEPTION 'FIXTURE 146D 失败:没有理由的封顶应当被拒,实得 %', COALESCE(v_msg,'(收下了)'); END IF;

    -- 正常打分:一条 computed(带 basis)、一条 judged
    v_r := score_kpi_entry(v_tpl, 4, 'computed', 'from stocktakes', '2026-09 盘点:98.4%');
    IF (v_r->>'weighted')::numeric <> round(4::numeric/5*25, 2) THEN
        RAISE EXCEPTION 'FIXTURE 146D 失败:C1 权重 25、4 分,加权应当 % 实得 %',
            round(4::numeric/5*25,2), v_r->>'weighted'; END IF;
    -- ★ 封顶:原始分与封顶都留着,生效分是小的那个 ★
    v_r := score_kpi_entry(v_tpl, 5, 'judged', NULL, NULL, 2, 'unauthorized operation observed');
    IF (v_r->>'effective_score')::int <> 2 OR (v_r->>'capped')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 146D 失败:5 分被封到 2,生效分应当是 2 且 capped=true,实得 %', v_r; END IF;
    IF (SELECT score FROM kpi_entries WHERE id = v_tpl) <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 146D 失败:★ 封顶不该覆盖原始判断 —— 原始分应当还是 5 ★'; END IF;

    -- ══════════ E. roll-up:没打分的不算 0;封顶进得了加权分 ═════════════════
    SELECT * INTO v_row FROM kpi_employee_rollup
     WHERE employee_id = v_emp AND cycle_id = v_cycle;
    IF NOT FOUND THEN RAISE EXCEPTION 'FIXTURE 146E 失败:roll-up 里找不到这个人'; END IF;
    IF v_row.kpi_count <> 5 OR v_row.scored_count <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 146E 失败:应当 5 条里打了 1 条,实得 %/%', v_row.scored_count, v_row.kpi_count; END IF;
    -- ★【分母是【打过分那些行】的权重和,不是 100】★ 否则"还没评"会被读成"没做到"
    IF v_row.performance_pct <> round(2::numeric/5*25 / 25 * 100, 1) THEN
        RAISE EXCEPTION 'FIXTURE 146E 失败:performance%% 应当按已打分的权重算(%),实得 %',
            round(2::numeric/5*25/25*100,1), v_row.performance_pct; END IF;
    IF v_row.weighted_score_achieved <> round(2::numeric/5*25, 2) THEN
        RAISE EXCEPTION 'FIXTURE 146E 失败:加权分应当用【封顶后】的 2 分,实得 %', v_row.weighted_score_achieved; END IF;
    IF v_row.capped_count <> 1 OR v_row.computed_count <> 0 OR v_row.judged_count <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 146E 失败:封顶/算的/判的计数不对:%/%/%',
            v_row.capped_count, v_row.computed_count, v_row.judged_count; END IF;

    -- ══════════ F. 权限 —— 真的换一个没权限的角色去调 ═══════════════════════
    DELETE FROM role_permissions WHERE role_id = r_all AND permission_code = 'module.hr.edit';
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM score_kpi_entry(v_tpl, 3, 'judged');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 146F 失败:没有 hr.edit 不该打得了分,实得 %', COALESCE(v_msg,'(打了)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM assign_position_kpis(v_emp, v_cycle);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 146F 失败:没有 hr.edit 不该生成得了条目,实得 %', COALESCE(v_msg,'(生成了)'); END IF;
    -- 【补回权限就放行 —— 证明上面两个拒绝不是"函数本来就不工作"】
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_all, 'module.hr.edit');
    v_r := score_kpi_entry(v_tpl, 3, 'judged');
    IF (v_r->>'score')::int <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 146F 失败:补回权限之后应当打得了分 —— 上面那两个拒绝因此不是一次测量'; END IF;

    -- 【没有职位的人生不出条目,而拒绝要指路】
    INSERT INTO employees (code, legal_name, hire_date, employment_type, work_category, employment_status)
    VALUES ('ZZ146-E2', 'Fixture 146 no position', '2026-01-01', 'full_time', 'office', 'active')
    RETURNING id INTO v_emp;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM assign_position_kpis(v_emp, v_cycle);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'EMPLOYEE_HAS_NO_POSITION|%' THEN
        RAISE EXCEPTION 'FIXTURE 146F 失败:没有职位应当按名拒,实得 %', COALESCE(v_msg,'(生成了)'); END IF;

    -- ══════════ G. 目录事实 —— 查 pg_catalog,不 grep 源码(陷阱 b)═════════
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgrelid = 'public.kpi_organisation'::regclass
                      AND tgname = 'trg_kpi_org_weight_total' AND tgdeferrable) THEN
        RAISE EXCEPTION 'FIXTURE 146G 失败:组织权重那道闸不在目录里,或者不是 DEFERRABLE 的'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgrelid = 'public.kpi_position_templates'::regclass
                      AND tgname = 'trg_kpi_template_weight_total' AND tgdeferrable) THEN
        RAISE EXCEPTION 'FIXTURE 146G 失败:模板权重那道闸不在目录里,或者不是 DEFERRABLE 的'; END IF;
    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname IN ('assign_position_kpis','score_kpi_entry') AND prosecdef;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 146G 失败:两支函数都应当是 SECURITY DEFINER,实得 %', v_n; END IF;
    -- 【employees.job_title 真的没了】留着就是同一个事实两个写入口
    SELECT count(*) INTO v_n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='employees' AND column_name='job_title';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 146G 失败:employees.job_title 还在'; END IF;
    -- 【而 employment_history.job_title 必须【还在】—— 它是履历快照】
    SELECT count(*) INTO v_n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='employment_history' AND column_name='job_title';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 146G 失败:★ employment_history.job_title 被删了 —— 那是一条不可变的履历快照 ★'; END IF;
    -- 【既有考核模块一个字节没动】review_goals 那三条 SELECT 策略还在
    SELECT count(*) INTO v_n FROM pg_policy
     WHERE polrelid = 'public.review_goals'::regclass AND polcmd = 'r';
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 146G 失败:review_goals 的三条 SELECT 策略应当原样还在,实得 % 条 —— 自评可见性机制不许被这一刀碰', v_n; END IF;

    -- ══════════ 故障注入 —— 先证明"注入真的改了东西"(陷阱 e)═══════════════
    -- 注入:把 assign 里那句"抄 target_text"改成【留空】,断言它建不出来。
    -- FIN-27 的下半句就是这条:引用了模板却没留下副本的记录要按名拒。
    v_inj := replace(def_asg, 'v_t.target_text', 'NULL::text');
    IF v_inj = def_asg THEN
        RAISE EXCEPTION 'FIXTURE 146 注入 失败:没找到"抄 target_text"那一段 —— 这个注入什么也没删'; END IF;
    EXECUTE v_inj;
    DELETE FROM kpi_entries WHERE cycle_id = v_cycle;
    SELECT id INTO v_emp FROM employees WHERE code = 'ZZ146-E1';
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM assign_position_kpis(v_emp, v_cycle);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 146 注入 失败:抄不下目标却建成了条目 —— 那正是 FIN-27 下半句要拦的"悄悄回退去读现在的模板"'; END IF;
    EXECUTE def_asg;   -- 放回去
    -- 放回去之后同一件事应当成功(证明上面那次红是注入造成的)
    v_r := assign_position_kpis(v_emp, v_cycle);
    IF (v_r->>'entries_created')::int <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 146 注入 失败:恢复之后应当又能生成 5 条'; END IF;
END $$;
ROLLBACK;
