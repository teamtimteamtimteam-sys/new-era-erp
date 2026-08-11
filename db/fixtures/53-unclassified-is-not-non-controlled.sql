-- 53 受控废物分类:【没分类】与【分类为非受控】必须分得开
--
-- 【A 臂是这份 fixture 的全部要点,其余几臂都是它的配套】
-- 一个把 NULL 当成"非受控"的实现,能通过下面每一条其它断言:分类表建出来了、
-- 外键成立、种子两行都在、受控那一行的布尔量是 true —— 全都对,
-- 而"这个物料没有人分过类"这件事在系统里读不出来。
--
-- 这个仓库已经三次遇到同一个形状,答案每次都一样:
--     no_reference(METAL-1)    —— 没有可比的对象,不是"比过、没问题"
--     「无检查记录」(METAL-1)  —— 当时还没有这项检查,不是"检查通过"
--     price_index IS NULL(METAL-2)—— 没人说过它来自哪个市场,不是"来自 LME"
-- 而这一次是【承重的】:一个合规判断会踩在它上面。所以 A 臂不只断言"两者的
-- 分类码不同"(那太便宜),它断言【三种状态在同一个查询里各自可辨】,
-- 并且断言"未分类"不能被误算进任何一边。
--
-- 【B 臂:第三种分类是加一行,不是跑一次迁移】RUNTIME CONFIG 的意义就在这里 ——
-- 插一行新分类,物料立刻能指向它,不需要动任何 CHECK。
--
-- 【C 臂:外键真的在】指向一个不存在的分类码应当被拒 —— 否则这一列就是自由文本,
-- 而自由文本的分类会在第一次手滑之后变成两种拼法。
--
-- 日期无关(本 fixture 不涉及任何随时间移动的状态)。自带数据(README 第 2 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_m_focused uuid; v_m_non uuid; v_m_null uuid; v_m_third uuid;
    v_n int; v_denied boolean; v_msg text;
    v_controlled int; v_non_controlled int; v_unclassified int;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-53', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_all, unnest(ARRAY['module.materials.view','module.materials.edit']);
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 三个物料,三种状态。【category 与 chemistry 故意完全相同】——
    -- 那正是"本列与它们不重复"的证明:我们怎么看这批货一模一样,
    -- 而监管怎么看它可以不同。
    INSERT INTO materials (code, name, category, chemistry, waste_classification_code)
    VALUES ('ZZFIX53-F', 'fixture 53 focused', '进料-电池', 'NMC', 'focused')
    RETURNING id INTO v_m_focused;
    INSERT INTO materials (code, name, category, chemistry, waste_classification_code)
    VALUES ('ZZFIX53-N', 'fixture 53 non-focused', '进料-电池', 'NMC', 'non_focused')
    RETURNING id INTO v_m_non;
    INSERT INTO materials (code, name, category, chemistry)
    VALUES ('ZZFIX53-U', 'fixture 53 unclassified', '进料-电池', 'NMC')
    RETURNING id INTO v_m_null;

    -- ══════════ A. 三种状态各自可辨 —— 未分类既不算受控,也不算非受控 ═════════
    SELECT
        count(*) FILTER (WHERE wc.is_controlled IS TRUE),
        count(*) FILTER (WHERE wc.is_controlled IS FALSE),
        count(*) FILTER (WHERE m.waste_classification_code IS NULL)
      INTO v_controlled, v_non_controlled, v_unclassified
      FROM materials m
      LEFT JOIN waste_classifications wc ON wc.code = m.waste_classification_code
     WHERE m.code IN ('ZZFIX53-F','ZZFIX53-N','ZZFIX53-U');

    IF v_controlled <> 1 OR v_non_controlled <> 1 OR v_unclassified <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 53A 失败:三个物料应当【各占一种状态】(受控 1 / 非受控 1 / 未分类 1),实得 %/%/% —— 把 NULL 当成"非受控"的实现会得到 1/2/0,而它能通过本 fixture 其它每一条断言',
            v_controlled, v_non_controlled, v_unclassified;
    END IF;

    -- 【正面再钉一次:未分类那一个不能被任何一边收编】
    IF EXISTS (
        SELECT 1 FROM materials m
        LEFT JOIN waste_classifications wc ON wc.code = m.waste_classification_code
        WHERE m.code = 'ZZFIX53-U' AND wc.is_controlled IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'FIXTURE 53A 失败:未分类的物料【解析不出任何 is_controlled 值】才是对的 —— 解析出 false 就是把"没人分过类"读成了"分过、结论是不受控",而一个合规判断会踩在这个区别上';
    END IF;

    -- 【与 category / chemistry 不重复】三者的 category 与 chemistry 完全相同
    SELECT count(DISTINCT category || '|' || COALESCE(chemistry,'')) INTO v_n
      FROM materials WHERE code IN ('ZZFIX53-F','ZZFIX53-N','ZZFIX53-U');
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 53A 前置失败:三个物料的 category/chemistry 本应完全相同(才证明得了新列与它们不蕴含),实得 % 种组合', v_n;
    END IF;

    -- ══════════ B. 第三种分类 = 加一行,不动任何 CHECK ═══════════════════════
    INSERT INTO waste_classifications (code, name_en, name_zh, is_controlled, sort_order, notes)
    VALUES ('ZZFIX53-THIRD', 'fixture third class', 'fixture 第三类', true, 99,
            'fixture 53:证明加一种分类是加一行');
    INSERT INTO materials (code, name, category, waste_classification_code)
    VALUES ('ZZFIX53-T', 'fixture 53 third', '进料-电池', 'ZZFIX53-THIRD')
    RETURNING id INTO v_m_third;
    IF (SELECT wc.is_controlled FROM materials m
         JOIN waste_classifications wc ON wc.code = m.waste_classification_code
        WHERE m.id = v_m_third) IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 53B 失败:新加的第三种分类应当立刻可用 —— 那正是"分类是一张表而不是一个 CHECK"的全部意义(加一种分类不该是一次迁移)';
    END IF;

    -- ══════════ C. 外键真的在:指向不存在的分类码应被拒 ══════════════════════
    v_denied := false;
    BEGIN
        INSERT INTO materials (code, name, category, waste_classification_code)
        VALUES ('ZZFIX53-BAD', 'fixture 53 bad', '进料-电池', 'no_such_class');
    EXCEPTION WHEN foreign_key_violation THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 53C 失败:指向不存在的分类码应当被外键挡住 —— 否则这一列就是自由文本,而自由文本的分类在第一次手滑之后会变成两种拼法(materials.category 今天正是这样:线上已有 NiH 与 black_mass 两个不在选项表里的值)';
    END IF;

    -- ══════════ D. 引导的两行:语义在 is_controlled 上,不在 code 上 ══════════
    IF (SELECT is_controlled FROM waste_classifications WHERE code = 'focused') IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 53D 失败:重点物料应当 is_controlled = true';
    END IF;
    IF (SELECT is_controlled FROM waste_classifications WHERE code = 'non_focused') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 53D 失败:非重点物料应当 is_controlled = false —— 【而这与"未分类"是两回事】:这一行的意思是有人分过类、结论是不受控';
    END IF;
END $$;
ROLLBACK;
