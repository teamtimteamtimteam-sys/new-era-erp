-- db/fixtures/124-an-imported-code-does-not-collide-with-the-next-one.sql
-- IMPORT-1(2026-08-24):**导入进来的编号,不许把下一次自动取号撞死。**
--
-- 【为什么这一条要有自己的 fixture,而不是一句"记得推进序列"】
-- 编号由文件给出(3.1),而取号触发器是【填空式】的:`IF NEW.code IS NULL …`。
-- 于是导入一整批 MAT-2026-9xxx 之后,`material_code_seq` **一格都没有动**。
-- 下一次有人在界面上新建物料,取号会从旧位置继续 —— 撞上刚导入的编号,
-- 报一句 `duplicate key value violates unique constraint "materials_code_key"`,
-- **而那时没有任何人会想到是几周前的一次导入造成的。**
--
-- 这正是本仓库反复点名的形状:一个【要靠人记着】的收尾步骤。
-- 处置照旧 —— 把它做进那支函数,然后**让一条断言看着它**。
--
-- 【本 fixture 的判据不是"序列变大了",而是"下一个真取到的号不撞"】
-- 只断言 `last_value` 变了,一个把序列推到某个无关数字的实现也能过。
-- 所以 C 臂走的是**真正的那条路**:插一行 code 为 NULL 的物料,让触发器取号,
-- 然后断言它【不等于】任何一个刚导入的编号,而且【大于】其中最大的那个。
--
-- 【三张表要,三张表不要 —— 而"不要"也断言】(F 臂)
--   · materials / suppliers / customers 用序列取号 → 要推进;
--   · employees 的 next_employee_code 是 MAX(...)+1,**天然看得见导入进去的最大号**;
--   · departments / storage_locations **根本没有取号触发器**,编号一律由人给。
-- 后两种如果哪天被"顺手"加上推进逻辑,F 臂会红 —— 那正是它存在的理由。
--
-- ⚠ **这支 fixture 【不要】拿去对着线上跑,而理由是实测出来的:**
-- **`setval` 不是事务性的 —— 它活过 ROLLBACK。** 本 fixture 的 B 臂会真的推进
-- 序列,而那一格【留在库上】。写它的时候我对着线上跑了两次,把 live 的
-- `material_code_seq` 从 76 推到了 14002,顺带撞出了 H 臂那个四位截断的缺陷,
-- 然后把它还原回 76。**gate 跑在【重建库】上,那份库用完即弃,所以那里是安全的。**
-- 要单独跑它,请对着一个 scratch 库跑。

BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all  uuid;
    v_seq_before bigint;
    v_seq_after  bigint;
    v_new_code   text;
    v_kind       text;
    v_report     jsonb;
    v_emp_code   text;
    v_target     bigint;      -- 这一跑要导入的那个"高号"
    v_emp_target bigint;
BEGIN
    -- 全权限角色 + 会话声明(本目录的惯例:自建角色,不借引导角色)
    INSERT INTO roles (code,name_en,name_zh,is_active)
      VALUES ('fixture-124','f','f',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id,permission_code)
      SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id,role_id) VALUES (v_user,r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 这个库里的物料种类:要一个【允许加工】且【不吃状态轴】的。
    --
    -- 【为什么两个条件都要,而且必须 ORDER BY —— 这一行错过一次】
    -- 第一版写的是 `WHERE may_ever_be_processed LIMIT 1`,没有 ORDER BY。
    -- 而 `may_ever_be_processed` 为真的有【两个】:`battery_material`(吃状态轴,
    -- 少了 form_code / source_code 会被 guard_material_condition_axes 拒)与
    -- `ewaste`(不吃)。没有 ORDER BY 的 LIMIT 1 返回哪一个是【未定义】的:
    -- 线上碰巧给了 ewaste,fixture 全绿;**重建库给了 battery_material,当场红**。
    -- 也就是说它在线上是【因为错的理由通过】的 —— 本仓库对这个形状点过很多次名
    -- (PROC-4 的 F5 臂靠并列的 sort_order 侥幸绿过,是同一课)。
    SELECT code INTO v_kind FROM material_kinds
     WHERE may_ever_be_processed AND NOT has_condition_axes
     ORDER BY code LIMIT 1;
    IF v_kind IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 124 前提失败:找不到一个【可加工且不吃状态轴】的物料种类';
    END IF;

    -- 【NULL,不是 0】一条从来没被取过号的序列,last_value 是 NULL ——
    -- 重建库正是这种状态。COALESCE 之后 A 臂才问得出它真正想问的问题。
    SELECT COALESCE(last_value, 0) INTO v_seq_before FROM pg_sequences
     WHERE schemaname='public' AND sequencename='material_code_seq';
    v_seq_before := COALESCE(v_seq_before, 0);

    -- ══════════ A · 前提:目标号【由当前序列算出来】,不是写死的 ═══════════════
    -- 【为什么不写死 9000 —— 这是本 fixture 自己踩出来的一课】
    -- **`setval` 不是事务性的:它活过 ROLLBACK。** 所以 B 臂推进的那一格,
    -- 在这支 fixture 回滚之后【仍然留在库上】。写死一个 9000,第二次跑时
    -- 前提就不成立了 —— 而本仓库要求一支 fixture【连跑两次都绿】(PROC-6 的那一课)。
    -- 目标号因此从当前值算:每一跑都在自己的起点之上。
    -- +100,**刻意留在 9999 以内** —— 取号格式只有四位(见 H 臂)。
    v_target := v_seq_before + 100;
    IF v_target IS NULL OR v_target > 9999 THEN
        RAISE EXCEPTION 'FIXTURE 124A 失败:目标号算不出来或超过四位上限(当前序列 %)', v_seq_before;
    END IF;

    -- ══════════ B · 导入一个【很高】的编号,走真正的那支函数 ═══════════════════
    v_report := master_import_apply(
        'materials',
        jsonb_build_array(jsonb_build_object(
            'code','MAT-2026-'||v_target,'name','ZZFIX124 imported material',
            'kind_code', v_kind, 'may_be_processed', false)),
        'fixture-124.csv',
        false);                       -- dry_run = false:真的提交

    IF NOT EXISTS (SELECT 1 FROM materials WHERE code='MAT-2026-'||v_target) THEN
        RAISE EXCEPTION 'FIXTURE 124B 失败:导入之后 MAT-2026-9000 不在表里(报告 %)', v_report;
    END IF;

    SELECT COALESCE(last_value, 0) INTO v_seq_after FROM pg_sequences
     WHERE schemaname='public' AND sequencename='material_code_seq';
    IF v_seq_after < v_target THEN
        RAISE EXCEPTION 'FIXTURE 124B 失败:序列没有被推进 —— 导入后仍是 %(应当 >= %)', v_seq_after, v_target;
    END IF;

    -- ══════════ C · **走【正常的 app 路径】新建一行,断言它不撞** ═══════════════
    -- 这一臂才是本 fixture 的判词:不是"序列变大了",而是"下一个真取到的号是干净的"。
    -- code 留空 → generate_material_code 触发器取号,与界面上新建走的是同一条路。
    INSERT INTO materials (name, kind_code, may_be_processed)
      VALUES ('ZZFIX124 app-created material', v_kind, false)
      RETURNING code INTO v_new_code;

    IF v_new_code = 'MAT-2026-'||v_target THEN
        RAISE EXCEPTION 'FIXTURE 124C 失败:自动取号撞上了导入的编号(%)', v_new_code;
    END IF;
    IF split_part(v_new_code,'-',3)::integer <= v_target THEN
        RAISE EXCEPTION 'FIXTURE 124C 失败:自动取号是 %,没有越过导入的最大号 % —— 下一次导入同一段就会撞', v_new_code, v_target;
    END IF;

    -- ══════════ D · 重跑同一份文件:**整份被拒,并点名撞上的编号** ═════════════
    BEGIN
        PERFORM master_import_apply(
            'materials',
            jsonb_build_array(jsonb_build_object(
                'code','MAT-2026-'||v_target,'name','ZZFIX124 second attempt',
                'kind_code', v_kind, 'may_be_processed', false)),
            'fixture-124.csv', false);
        RAISE EXCEPTION 'FIXTURE 124D 失败:重跑同一份文件【没有】被拒';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%IMPORT_CODE_ALREADY_EXISTS%' THEN
            RAISE EXCEPTION 'FIXTURE 124D 失败:重跑被拒了,但不是按名拒 —— %', SQLERRM;
        END IF;
        IF SQLERRM NOT LIKE '%MAT-2026-'||v_target||'%' THEN
            RAISE EXCEPTION 'FIXTURE 124D 失败:拒绝里没有点名撞上的编号 —— %', SQLERRM;
        END IF;
    END;

    -- ══════════ E · 预览【什么都不留下】═══════════════════════════════════════
    -- 预览真的插了一遍,靠 RAISE 回滚。这一臂断言那次回滚是真的。
    BEGIN
        PERFORM master_import_apply(
            'materials',
            jsonb_build_array(jsonb_build_object(
                'code','MAT-2026-'||(v_target+1),'name','ZZFIX124 preview only',
                'kind_code', v_kind, 'may_be_processed', false)),
            'fixture-124.csv', true);   -- dry_run
        RAISE EXCEPTION 'FIXTURE 124E 失败:预览没有抛异常 —— 那意味着它没有回滚';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%IMPORT_PREVIEW%' THEN
            RAISE EXCEPTION 'FIXTURE 124E 失败:预览抛的不是 IMPORT_PREVIEW —— %', SQLERRM;
        END IF;
    END;
    IF EXISTS (SELECT 1 FROM materials WHERE code='MAT-2026-'||(v_target+1)) THEN
        RAISE EXCEPTION 'FIXTURE 124E 失败:预览把行留下来了';
    END IF;

    -- ══════════ F · 【不该被推进的那三张表,断言它们没有被推进】═══════════════
    -- employees:next_employee_code 是 MAX(...)+1,导入一个高号之后【自动取号
    -- 天然让开】。这一臂证明的是"不需要序列"这件事本身,而不是"我们忘了做"。
    SELECT COALESCE(MAX(split_part(code,'-',3)::bigint),0) + 100 INTO v_emp_target
      FROM employees WHERE code ~ '^EMP-[0-9]{4}-[0-9]+$';   -- 员工没有四位上限(不走 LPAD 序列)
    PERFORM master_import_apply(
        'employees',
        jsonb_build_array(jsonb_build_object(
            'code','EMP-2026-'||v_emp_target,'legal_name','ZZFIX124 Imported Person',
            'employment_type','full_time','work_category','office','hire_date','2026-01-01')),
        'fixture-124-emp.csv', false);

    INSERT INTO employees (legal_name, employment_type, work_category, hire_date)
      VALUES ('ZZFIX124 App Person','full_time','office','2026-01-01')
      RETURNING code INTO v_emp_code;
    IF split_part(v_emp_code,'-',3)::bigint <= v_emp_target THEN
        RAISE EXCEPTION 'FIXTURE 124F 失败:员工自动取号是 %,没有越过导入的 %', v_emp_code, v_emp_target;
    END IF;

    -- storage_locations 根本没有取号触发器:编号必须由文件给,给不出就该被拒。
    BEGIN
        PERFORM master_import_apply(
            'storage_locations',
            jsonb_build_array(jsonb_build_object('name','ZZFIX124 no code')),
            'fixture-124-loc.csv', false);
        RAISE EXCEPTION 'FIXTURE 124F 失败:库位【没有编号】也被收下了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%IMPORT_CODE_REQUIRED%' AND SQLERRM NOT LIKE '%IMPORT_FAILED%' THEN
            RAISE EXCEPTION 'FIXTURE 124F 失败:缺编号的拒绝不是按名的 —— %', SQLERRM;
        END IF;
    END;

    -- ══════════ G · 往来户的登记号【只在导入这条路上】必填 ═══════════════════
    -- 而表上【没有】NOT NULL —— 这一臂两个方向都断言,否则"加了 NOT NULL"
    -- 与"只在导入路上要求"在测试里长得一样。
    BEGIN
        PERFORM master_import_apply(
            'suppliers',
            jsonb_build_array(jsonb_build_object(
                'code','ZZFIX124-SUP-1','legal_name','ZZFIX124 No Tax Id',
                'country','SG','counterparty_type','goods_supplier')),
            'fixture-124-sup.csv', false);
        RAISE EXCEPTION 'FIXTURE 124G 失败:导入一个【没有登记号】的供应商被收下了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%IMPORT_TAX_ID_REQUIRED%' AND SQLERRM NOT LIKE '%IMPORT_FAILED%' THEN
            RAISE EXCEPTION 'FIXTURE 124G 失败:缺登记号的拒绝不是按名的 —— %', SQLERRM;
        END IF;
    END;
    -- 反方向:**直插**一个没有登记号的供应商【必须仍然成立】—— 线上 6/7 行就是这样,
    -- 一条表级 NOT NULL 会把它们冻住(PROC-1 的 materials_kind_stated 前例)。
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
      VALUES ('ZZFIX124-SUP-2','ZZFIX124 Direct No Tax Id','SG','goods_supplier');

    -- ══════════ H · 编号超过四位【按名拒】,而不是把取号推坏 ═══════════════════
    -- 【这一臂是本刀实测撞出来的,不是设计时想到的】
    -- lpad('10000',4,'0') = '1000' —— PostgreSQL 的 LPAD **会截断**。
    -- 于是序列一旦被推过 9999,下一个自动取号就是一个被截短的编号,
    -- 第一次可能不撞、第二次必然撞,而报出来的是一句 duplicate key。
    BEGIN
        PERFORM master_import_apply(
            'materials',
            jsonb_build_array(jsonb_build_object(
                'code','MAT-2026-10000','name','ZZFIX124 over the ceiling',
                'kind_code', v_kind, 'may_be_processed', false)),
            'fixture-124-ceiling.csv', false);
        RAISE EXCEPTION 'FIXTURE 124H 失败:一个超过四位的编号被收下了 —— 它会把自动取号推坏';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%IMPORT_CODE_NUMBER_TOO_HIGH%' THEN
            RAISE EXCEPTION 'FIXTURE 124H 失败:拒绝不是按名的 —— %', SQLERRM;
        END IF;
    END;
    -- 反方向:**恰好 9999 必须过得了这道闸** —— 少了这一句,一个"一律拒绝"的
    -- 实现也能通过 H 臂。
    -- 【用预览,不用提交】提交会把序列推到 9999,而 **setval 活过 ROLLBACK**
    -- (见本文件抬头);预览在推进序列【之前】就 RAISE 了,所以它证明得了
    -- "这道闸放行 9999",又不会给任何库留下一个顶在天花板上的序列。
    BEGIN
        PERFORM master_import_apply(
            'materials',
            jsonb_build_array(jsonb_build_object(
                'code','MAT-2026-9999','name','ZZFIX124 at the ceiling',
                'kind_code', v_kind, 'may_be_processed', false)),
            'fixture-124-ceiling-ok.csv', true);
        RAISE EXCEPTION 'FIXTURE 124H 失败:预览没有抛异常';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%IMPORT_CODE_NUMBER_TOO_HIGH%' THEN
            RAISE EXCEPTION 'FIXTURE 124H 失败:9999 被那道上限闸拒了 —— 它应当恰好放行';
        END IF;
        IF SQLERRM NOT LIKE '%IMPORT_PREVIEW%' THEN
            RAISE EXCEPTION 'FIXTURE 124H 失败:9999 的预览抛的不是 IMPORT_PREVIEW —— %', SQLERRM;
        END IF;
    END;

END $$;
ROLLBACK;
