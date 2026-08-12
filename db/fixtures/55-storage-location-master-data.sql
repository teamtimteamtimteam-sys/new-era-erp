-- 55 库位主数据(LOC-1):生命周期、具名拒绝,以及【未配置】不是【不允许】
--
-- 【E 臂是这份 fixture 的要点,其余几臂是配套】
-- 一个把"零行 = 不允许任何分类"实现出来的系统,能通过下面每一条其它断言:
-- 表建出来了、外键成立、唯一约束在、重号被拒、停用有效 —— 全都对,
-- 而"这个库位还没有人配过"这件事读不出来。那正是 LOC-1 买的东西。
--
-- 这个仓库已经四次遇到同一个形状,答案每次都一样:
--     no_reference(METAL-1)          —— 没有可比的对象,不是"比过、没问题"
--     price_index IS NULL(METAL-2)   —— 没人说过它来自哪个市场
--     未分类(MAT-1 / fixture 53)     —— 没人分过类,不是"分过、不受控"
--     未测(REC-1 / 回收率两侧)        —— 没测过,不是"测出来是零"
-- 而这一次同样是【承重的】:出入库那一刀会踩在它上面 —— 未配置要【告警】,
-- 配了但不含这一类才【拒绝】。压成一个布尔量,就是把"没人想过"演成
-- "想过、结论是不行":一个不会响的拦截比没有拦截更坏。
--
-- 各臂:
--   A 前提:分类字典非空(引导种子真的插进来了)—— 一切派生断言的地基
--   B 生命周期:建 → 改名 → 停用,每一步都断言
--   C 允许分类:配两条就恰好读回两条,且都指得回字典
--   D 重号【具名】被拒(LOC_CODE_EXISTS),改名不撞自己
--   E 【未配置】与【配了、但不含这一类】在同一个查询里各自可辨
--   F 硬删【具名】被拒(LOCATION_NO_HARD_DELETE),停用仍然可用
--
-- 日期无关(本 fixture 不涉及任何随时间移动的状态)。自带数据(README 第 2 条)。
-- 【自己插分类行,不借引导的那两行】—— 引导值是 RUNTIME CONFIG,界面改得动
-- (README 第 4/5 条);A 臂断言引导非空是另一回事,那是在查种子有没有插进来。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    loc_a uuid; loc_b uuid; loc_unconf uuid;
    v_n int; v_denied boolean; v_msg text;
    v_name text; v_active boolean;
    v_configured int; v_unconfigured int; v_allows_ctrl int;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-55', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_all, unnest(ARRAY['module.inventory.view','module.inventory.edit']);
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ A. 前提:分类字典非空 ═══════════════════════════════════════
    -- 【先断前提,再断派生】E 臂要证明"配了 vs 没配"分得开,而如果字典是空的,
    -- 那两种状态在数据上会长得一模一样 —— 断言会【因为错的理由通过】。
    -- 这一条同时替引导种子把关:RUNTIME CONFIG 不与线上比对,一条 INSERT
    -- 只要 WHERE 不再匹配就会安安静静插入零行(check_mirrors 的 bootstrap
    -- 那一行防的是同一件事,这里是它在行为侧的回声)。
    SELECT count(*) INTO v_n FROM waste_classifications;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 55A 失败:waste_classifications 一行都没有 —— 引导种子没插进来。后面每一条关于"可存放分类"的断言都会因为集合为空而空转通过';
    END IF;

    -- 本 fixture 自己的两种分类(不借引导那两行 —— 它们是操作员改得动的运行期配置)
    INSERT INTO waste_classifications (code, name_en, name_zh, is_controlled, sort_order)
    VALUES ('zzfix55_ctrl', 'fixture 55 controlled', 'f55 受控', true, 901),
           ('zzfix55_free', 'fixture 55 free',       'f55 不受控', false, 902);

    -- ══════════ B. 生命周期:建 → 改名 → 停用 ═══════════════════════════════
    INSERT INTO storage_locations (code, name, zone)
    VALUES ('ZZFIX55-A', 'fixture 55 location A', 'A 区')
    RETURNING id INTO loc_a;

    SELECT name, is_active INTO v_name, v_active FROM storage_locations WHERE id = loc_a;
    IF v_name <> 'fixture 55 location A' THEN
        RAISE EXCEPTION 'FIXTURE 55B 失败:新建之后读回的名字不对:%', v_name;
    END IF;
    -- 【默认启用】—— 新建一个库位不该需要有人再去把它打开
    IF v_active IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 55B 失败:新建的库位应当默认 is_active = true,实际 %', v_active;
    END IF;

    UPDATE storage_locations SET name = 'fixture 55 renamed' WHERE id = loc_a;
    SELECT name INTO v_name FROM storage_locations WHERE id = loc_a;
    IF v_name <> 'fixture 55 renamed' THEN
        RAISE EXCEPTION 'FIXTURE 55B 失败:改名没生效:%', v_name;
    END IF;

    UPDATE storage_locations SET is_active = false WHERE id = loc_a;
    SELECT is_active INTO v_active FROM storage_locations WHERE id = loc_a;
    IF v_active IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 55B 失败:停用没生效';
    END IF;
    -- 【停用不是删除】—— 行还在,身份还在,历史指得回来
    SELECT count(*) INTO v_n FROM storage_locations WHERE id = loc_a;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 55B 失败:停用之后这一行应当还在(停用不是删除),实际 % 行', v_n;
    END IF;

    -- ══════════ C. 允许分类:配两条就恰好两条 ═══════════════════════════════
    INSERT INTO storage_locations (code, name) VALUES ('ZZFIX55-B', 'fixture 55 location B')
    RETURNING id INTO loc_b;
    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    VALUES (loc_b, 'zzfix55_ctrl'), (loc_b, 'zzfix55_free');

    SELECT count(*) INTO v_n FROM storage_location_allowed_classes WHERE location_id = loc_b;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 55C 失败:配了两类,应当恰好读回 2 行,实际 %', v_n;
    END IF;
    -- 每一条都指得回字典 —— 否则这一列就是自由文本(fixture 53C 同一条)
    SELECT count(*) INTO v_n
      FROM storage_location_allowed_classes a
      JOIN waste_classifications wc ON wc.code = a.classification_code
     WHERE a.location_id = loc_b;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 55C 失败:有配置行指不回分类字典,实际连得上的只有 %', v_n;
    END IF;
    -- 同一个库位同一类不许配两遍
    v_denied := false;
    BEGIN
        INSERT INTO storage_location_allowed_classes (location_id, classification_code)
        VALUES (loc_b, 'zzfix55_ctrl');
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 55C 失败:同一库位同一分类配第二遍应当被唯一约束挡住';
    END IF;

    -- ══════════ D. 重号【具名】被拒;改名不撞自己 ═══════════════════════════
    -- 【故障注入记录 —— 它抓到的是这份 fixture 自己】把触发器里的
    -- id <> NEW.id 去掉(即"任何同号行都算冲突",包括自己)再跑一次:
    -- 【第一版依旧全绿】。原因是下面第二段当时写的是只改 name 的 UPDATE,
    -- 而触发器是 UPDATE **OF code** —— 根本没被触发,那一臂在空转。
    -- 改成把 code 一并写回(表单本来就是整份提交)之后,同一次注入当场红了:
    --     ERROR: LOC_CODE_EXISTS|ZZFIX55-B
    -- 恢复之后两段都绿。与 FIN-30 那条空转的第三臂、fixture 26 第一版的
    -- A/C 两臂同一种病:【绿的理由必须验过,否则绿只是没人问过】。
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO storage_locations (code, name) VALUES ('ZZFIX55-B', 'fixture 55 duplicate');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'LOC_CODE_EXISTS|ZZFIX55-B' THEN
        RAISE EXCEPTION 'FIXTURE 55D 失败:重复库位号应当被【具名】拒绝(LOC_CODE_EXISTS|ZZFIX55-B),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了 —— 两个库位共用了一个号' END;
    END IF;

    -- 【改自己不算重号】—— 一条把"存在同号行"写成不带 id <> NEW.id 的实现,
    -- 会让任何一次编辑都撞上自己,而那种 bug 在界面上表现为"改名保存不了"。
    --
    -- 【必须把 code 一起写进去,否则这一臂是空转的】触发器是
    -- BEFORE INSERT OR UPDATE **OF code**:只改 name 的 UPDATE 根本不会
    -- 触发它,于是"改自己不算重号"什么也没证明。第一版正是这么写的,
    -- 故障注入当场揭穿了它 —— 去掉 id <> NEW.id 之后 fixture 【依旧全绿】。
    -- 表单提交的本来就是整份表单(code 一并回写),所以带上 code 才是实况。
    UPDATE storage_locations
       SET code = 'ZZFIX55-B', name = 'fixture 55 B renamed'
     WHERE id = loc_b;
    SELECT name INTO v_name FROM storage_locations WHERE id = loc_b;
    IF v_name <> 'fixture 55 B renamed' THEN
        RAISE EXCEPTION 'FIXTURE 55D 失败:改自己的名字被当成了重号';
    END IF;

    -- ══════════ E. 【未配置】与【配了、但不含这一类】各自可辨 ════════════════
    INSERT INTO storage_locations (code, name) VALUES ('ZZFIX55-U', 'fixture 55 unconfigured')
    RETURNING id INTO loc_unconf;
    -- loc_unconf:一行都不配 —— 未配置
    -- loc_a:只配【不受控】那一类 —— 配过了,但不含受控类
    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    VALUES (loc_a, 'zzfix55_free');

    SELECT
        count(*) FILTER (WHERE cfg.n > 0),
        count(*) FILTER (WHERE cfg.n = 0),
        count(*) FILTER (WHERE cfg.n > 0 AND cfg.has_ctrl)
      INTO v_configured, v_unconfigured, v_allows_ctrl
      FROM storage_locations l
      JOIN LATERAL (
            SELECT count(*) AS n,
                   bool_or(a.classification_code = 'zzfix55_ctrl') AS has_ctrl
              FROM storage_location_allowed_classes a
             WHERE a.location_id = l.id
      ) cfg ON true
     WHERE l.code LIKE 'ZZFIX55-%';

    -- 三个库位:B 配了两类(含受控)、A 配了一类(不含受控)、U 一条没配
    IF v_configured <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 55E 失败:应当有 2 个【已配置】库位,实际 %', v_configured;
    END IF;
    IF v_unconfigured <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 55E 失败:应当有 1 个【未配置】库位,实际 %', v_unconfigured;
    END IF;
    IF v_allows_ctrl <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 55E 失败:应当只有 1 个库位明确允许受控类,实际 %', v_allows_ctrl;
    END IF;

    -- 【这一条是 E 臂的心脏】未配置的那个,与"配了、但不含受控类"的那个,
    -- 在"允许受控类吗"这个问题上都答【否】—— 而它们不是同一件事:
    -- 前者是没人决定过(将来告警),后者是有人决定了(将来拒绝)。
    -- 一个把两者压成同一个布尔量的实现,恰恰在这里读不出区别,所以这里
    -- 断言的是【区别本身存在】,而不是那个布尔量。
    IF (SELECT count(*) FROM storage_location_allowed_classes WHERE location_id = loc_unconf) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 55E 失败:未配置的库位不该有任何配置行';
    END IF;
    IF (SELECT count(*) FROM storage_location_allowed_classes WHERE location_id = loc_a) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 55E 失败:loc_a 配过一类,不该读成未配置 —— 若这里为零,"配了但不含" 与 "没配过" 就塌成了同一种状态,而它们导向相反的处置(拒绝 vs 告警)';
    END IF;

    -- ══════════ F. 硬删【具名】被拒;停用仍然是可用的那条路 ═══════════════════
    -- 【故障注入记录】把 trg_storage_locations_no_hard_delete 停掉
    -- (ALTER TABLE ... DISABLE TRIGGER)跑过一次:DELETE 当场成功,本臂红,
    -- 报的正是"成功了"那一支。恢复之后转绿 —— 所以它不是空转。
    -- 【为什么要具名】LOC-1 之前"删不掉"是 inventory_movements 的外键顺手挡的,
    -- 而 loc_unconf 没有任何流水指着它:靠外键的实现【会让这一行删掉】,
    -- 于是这一臂同时钉住了"守卫独立于外键存在"这件事。
    v_denied := false; v_msg := NULL;
    BEGIN
        DELETE FROM storage_locations WHERE id = loc_unconf;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'LOCATION_NO_HARD_DELETE|ZZFIX55-U' THEN
        RAISE EXCEPTION 'FIXTURE 55F 失败:硬删库位应当被【具名】拒绝(LOCATION_NO_HARD_DELETE|ZZFIX55-U),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了 —— 而这一行没有任何流水指着它,所以靠外键挡的实现会放它过去' END;
    END IF;

    -- 拒绝之后这一行必须原样还在(拒绝 = 什么都没写)
    SELECT count(*) INTO v_n FROM storage_locations WHERE id = loc_unconf;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 55F 失败:硬删被拒之后这一行应当原样还在,实际 % 行', v_n;
    END IF;

    -- 而【停用】这条路必须仍然走得通 —— 否则这就不是"换一条路",是"没有路"
    UPDATE storage_locations SET is_active = false WHERE id = loc_unconf;
    SELECT is_active INTO v_active FROM storage_locations WHERE id = loc_unconf;
    IF v_active IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 55F 失败:硬删被拒了,而停用也走不通 —— 那就没有任何下架路径了';
    END IF;
END $$;
ROLLBACK;
