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
    PERFORM require_permission('module.hr.edit');

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
