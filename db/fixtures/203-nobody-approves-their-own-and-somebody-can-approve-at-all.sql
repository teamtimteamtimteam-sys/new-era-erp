-- 203 APR-2:【没有人批自己的单】,以及【每一条链真的有人批得动】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】
--   P  ★ forbid_self_approval 是【唯一】那份判据,而且【不是】SECURITY DEFINER
--        (DEFINER 且无调用者检查会被 gate 的 B2 点名);四支决定函数都调它
--   E  ★★ 【名册 vs 目录】approval_chain_gates() 列的那组函数,必须逐字等于
--        pg_proc 里真正调 require_approver_for 的那组 —— 这一条是本支最耐用的:
--        下一刀接了一条链却忘了登记,它当场红
--   A  ★ 请假 · 提单的人自己批 → SELF_APPROVAL_FORBIDDEN|raiser
--   B  ★★ 请假 · 【单据说的那位】自己批 → …|subject
--        (HR 代人提单时 raiser 与 subject 是两个人 —— 少了这条腿,主角照样批得了)
--   C  ★ 【对照】第三个人批得动 —— 少了它,A/B 证明的可能只是"这条路根本不通"
--   D  ★ 医疗申报 · subject 那条腿 + 同样的对照
--   F  ★★ 绩效 · subject 那条腿 —— 【这一条此前全库都没有】,而 approve_review
--        会写 employees.monthly_salary:一个人可以批准自己的加薪
--   G  ★★ 工单 · 审批【开着】时,一个持 module.processing.edit 而【不在一级
--        审批角色里】的人放行得了 —— 这正是 APR-2 之前线上那把锁;
--        外加留痕那一行的 level【是 NULL】(写 1 是一句假记录)
--   H  ★★ 开关那道新闸,【两个方向都要】:
--        H1 一条没有人批得动的链 → 按名拒(点出函数 · 级别 · 角色 · 缺的码)
--        H2 把缺的那个码补上 → ★【开得起来】—— 少了这一臂,一个"永远不许开"
--           的实现会全绿
--   I  ★ 屏幕与闸读同一份判据:approvals_readiness().chain_gates 的条数与
--        "死了几条"必须与 approval_gate_intersections() 逐字相同
--
-- 【躲开的陷阱,逐条】
--  (a) 两份实现碰巧一致 —— 每一条拒绝都配一条【会成功】的对照(C 之于 A/B,
--      D2 之于 D,F2 之于 F,G 本身就是"从拒绝变成成功",H2 之于 H1)。
--  (b) 空集通过 —— E 先断言名册【非空】再比;I 断言的是【具体的数】。
--  (c) 一个"永远拒绝"的实现全绿 —— H2 与 C/D2/F2 就是为这个存在的。
--  (d) 断言为真却没有管辖权 —— A/B 的演员【持有 module.hr.edit】(C 当场证明),
--      所以他们的失败不可能是权限门造成的。
--  (e) 读【文件】而不是读【目录】—— P 与 E 全部查 pg_proc.prosrc,
--      于是"我以为我改了"与"它真的改了"分得开。
--
-- 自带数据(README 第 2 条)。不继承线上任何值 —— 自己设(README 第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    -- 人:三个 HR、一个生产、一个管权限的、一个一级审批角色的持有人
    u_hrA   uuid := gen_random_uuid();   -- HR 甲:代人提单的那位
    u_hrB   uuid := gen_random_uuid();   -- HR 乙:单据说的就是他(而且他持 hr.edit)
    u_hrC   uuid := gen_random_uuid();   -- HR 丙:第三个人 —— 对照臂的演员
    u_proc  uuid := gen_random_uuid();   -- 持 module.processing.edit,【不在】一级审批角色里
    u_adm   uuid := gen_random_uuid();   -- 持 action.manage_permissions:开关那扇门的钥匙
    u_l1    uuid := gen_random_uuid();   -- 一级审批角色的真持有人
    -- ★ 二级【必须是另一个人】。第一版让 u_l1 同时持两个角色,于是他经由
    --   二级那个角色拿到了 module.purchasing.view —— 求交是按【人】算的,
    --   不是按角色算的,H1 那一臂因此静静地变成空转(开关开起来了)。
    --   ☞ 这正是本刀要抓的那件事的镜像:**一个人的权限是他【所有】角色的并集。**
    u_l2    uuid := gen_random_uuid();
    r_hr uuid; r_proc uuid; r_adm uuid; r_l1 uuid; r_l2 uuid;
    e_A  uuid := gen_random_uuid();      -- 员工 A = u_hrA
    e_B  uuid := gen_random_uuid();      -- 员工 B = u_hrB  ← 单据的主角
    e_C  uuid := gen_random_uuid();      -- 员工 C = u_hrC
    lv_id  uuid := gen_random_uuid();
    lv2_id uuid := gen_random_uuid();
    mc_id  uuid := gen_random_uuid();
    mc2_id uuid := gen_random_uuid();
    pr_id  uuid := gen_random_uuid();
    pr2_id uuid := gen_random_uuid();
    wo_id  uuid := gen_random_uuid();
    v_rating text;
    v_n      integer;
    v_msg    text; v_denied boolean;
    v_reg  text[]; v_cat text[];
    v_read jsonb;
    v_lvl  smallint;
BEGIN
    -- ══════════════════════ 布景 ══════════════════════
    -- confirmed_at 是【生成列】,所以设 email_confirmed_at(fixture 151/202 的同一课)。
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_hrA, now()), (u_hrB, now()), (u_hrC, now()),
        (u_proc, now()), (u_adm, now()), (u_l1, now()), (u_l2, now());

    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx203-hr','f','f',true)   RETURNING id INTO r_hr;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx203-proc','f','f',true) RETURNING id INTO r_proc;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx203-adm','f','f',true)  RETURNING id INTO r_adm;
    -- ★ 一级审批角色:有真持有人、看得见金额,【而它的持有人不持 module.purchasing.view】
    --   —— H1 那一臂要的正是这个形状。
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx203-l1','f','f',true)   RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx203-l2','f','f',true)   RETURNING id INTO r_l2;

    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_hr,   'module.hr.edit'),
        (r_hr,   'module.hr.view'),
        -- ROLE-1(2026-09-23):决定请假/医疗、做与批绩效评估各自有了自己的码。
        --   这份 fixture 问的是【四眼】,不是谁持哪个码 —— 所以 HR 演员三个都拿。
        (r_hr,   'action.decide_hr_requests'),
        (r_hr,   'action.hr_reviews'),
        (r_hr,   'action.approve_review'),
        (r_proc, 'module.processing.edit'),
        (r_proc, 'module.processing.view'),
        (r_adm,  'action.manage_permissions'),
        (r_adm,  'module.finance.view'),
        -- 两级都要 data.view_prices,否则开关会先撞上 ..._CANNOT_SEE_AMOUNTS(R4),
        -- 而那会让 H1 为【错的理由】变红。
        (r_l1,   'data.view_prices'),
        (r_l2,   'data.view_prices'),
        -- ★★ APR-3(2026-09-22):报销单那条链接上了引擎,它的门是
        --   module.finance.view + data.view_prices。两级都要补上 module.finance.view,
        --   ☞ 【否则 H1 报出来的会是报销那条链,而不是本臂刻意造出来的采购那条】——
        --     那样这一臂仍然会绿,而它证的已经是另一件事了。
        --   ★ 本臂刻意留着的缺口【只有一个码】:module.purchasing.view(两级都不持,
        --     理由见下)。H2 随后只补给二级,于是"补齐就开得起来"证的是那一个码 ——
        --     并且顺带证了 R1:一级那条链靠的是二级的人。
        (r_l1,   'module.finance.view'),
        (r_l2,   'module.finance.view');
        -- ★★ APR-ROUTE-1(R1,2026-09-23):二级这一支【不再】一开始就配齐。
        --   R1 之后一级的有资格名单 = 一级持有人 ∪ 二级持有人;二级若先持
        --   module.purchasing.view,一级那条采购链就经由 u_l2 有了批得动的人,
        --   H1 当场变成空转(开关开起来了)—— 与本文件上面 u_l2 那段注释
        --   是同一个形状:求交按【人】算,而 R1 让二级的人也站进了一级。
        --   ☞ 所以 H1 时两级都缺这个码(报出来的仍然是 approve_purchase_order|1,
        --     按 action_function、level 排序的第一格);H2 只补给【二级】。

    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_hrA, r_hr), (u_hrB, r_hr), (u_hrC, r_hr),
        (u_proc, r_proc), (u_adm, r_adm),
        (u_l1, r_l1), (u_l2, r_l2);

    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_A, 'FX203-A', 'A', 'full_time', 'office', DATE '2020-01-01', u_hrA),
        (e_B, 'FX203-B', 'B', 'full_time', 'office', DATE '2020-01-01', u_hrB),
        (e_C, 'FX203-C', 'C', 'full_time', 'office', DATE '2020-01-01', u_hrC);

    -- 不累积的假期类型 —— 于是 decide_leave_request 的额度机制整个不参与,
    -- 这一支要验的是【四眼】,不是余额。
    INSERT INTO leave_types (code, name_en, name_zh, is_accrued, is_active)
      VALUES ('fx203-lv', 'f', 'f', false, true);

    -- ★ 两张请假单,而【主角都是员工 B】、【提单的都是 HR 甲】——
    --   也就是"HR 代人提单"那个形状。raiser 与 subject 因此是两个【不同的】人,
    --   两条腿才分得开(合在一起写,B 那一臂会被 A 那一臂顺带通过)。
    INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status, created_by) VALUES
        (lv_id,  'FX203-LV-1', e_B, 'fx203-lv', DATE '2030-03-04', DATE '2030-03-04', 1, 'pending', u_hrA),
        (lv2_id, 'FX203-LV-2', e_B, 'fx203-lv', DATE '2030-04-01', DATE '2030-04-01', 1, 'pending', u_hrA);

    INSERT INTO medical_claims (id, code, employee_id, claim_date, claim_year, amount_sgd, status, created_by) VALUES
        (mc_id,  'FX203-MC-1', e_B, DATE '2030-03-04', 2030, 10, 'submitted', u_hrA),
        (mc2_id, 'FX203-MC-2', e_B, DATE '2030-03-05', 2030, 10, 'submitted', u_hrA);

    SELECT code INTO v_rating FROM review_rating_scale ORDER BY code LIMIT 1;
    IF v_rating IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 203 布景失败:review_rating_scale 是空的 —— 这支 fixture 依赖那份种子数据';
    END IF;

    -- ★ 两份绩效评估,主角都是员工 B,提交人是 HR 甲。
    --   review_type = probation 且 outcome = not_confirm:approve_review 的
    --   转正支与调薪支都不进,于是这一臂只在验四眼,不在验那两段业务。
    --   (一名员工只有一份未作废的试用期评估 → 第二份挂在员工 C 上。)
    INSERT INTO performance_reviews
        (id, employee_id, review_type, period_start, period_end, reviewer_employee_id,
         status, rating_code, summary_text, probation_outcome, submitted_at, submitted_by) VALUES
        (pr_id,  e_B, 'probation', DATE '2030-01-01', DATE '2030-03-01', e_A,
         'submitted', v_rating, 's', 'not_confirm', now(), u_hrA),
        (pr2_id, e_C, 'probation', DATE '2030-01-01', DATE '2030-03-01', e_A,
         'submitted', v_rating, 's', 'not_confirm', now(), u_hrA);

    INSERT INTO work_orders (id, code, status, created_by)
      VALUES (wo_id, 'FX203-WO-1', 'draft', u_proc);

    -- ══════════════════════ P · 结构:一份判据,四个调用点 ══════════════════════
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'forbid_self_approval';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 203P 失败:forbid_self_approval 不在库里(实得 % 支)', v_n; END IF;
    -- 【它不该是 DEFINER】它不读任何受 RLS 约束的东西;DEFINER 且无调用者检查
    -- 会被 gate 的 B2 点名,而那时的解法只会是再写一条豁免。
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'forbid_self_approval' AND NOT p.prosecdef;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 203P 失败:forbid_self_approval 是 SECURITY DEFINER —— 它不需要,而它会因此欠一条 B2 豁免'; END IF;
    -- 四支决定函数都接上了【同一支】判据 —— 读的是目录,不是这个文件。
    FOR v_msg IN
        SELECT p.proname::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname IN ('decide_leave_request','decide_medical_claim','approve_review','release_work_order')
           AND p.prosrc NOT LIKE '%forbid_self_approval%'
    LOOP
        RAISE EXCEPTION 'FIXTURE 203P 失败:% 没有调 forbid_self_approval —— 一条写成四遍的规矩,第五条链一定会漏掉它', v_msg;
    END LOOP;
    -- ★ 工单那一行真的摘掉了(不然 G 会为一个已经修好的理由变红,而我们不会知道)
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname='public' AND p.proname='release_work_order' AND p.prosrc LIKE '%require_approver_for%';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 203P 失败:release_work_order 里还有 require_approver_for'; END IF;

    -- ══════════════════════ E ★★ 名册 vs 目录 ══════════════════════
    -- 【本支最耐用的一条】approval_chain_gates() 是一张手写名册,而手写的东西会漂。
    -- 这一条让"下一刀接了一条链却忘了登记"当场变红,而不是等到某天有人发现
    -- 一条链谁都批不动。
    SELECT array_agg(DISTINCT action_function ORDER BY action_function) INTO v_reg
      FROM approval_chain_gates();
    SELECT array_agg(DISTINCT p.proname::text ORDER BY p.proname::text) INTO v_cat
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prosrc LIKE '%require_approver_for%'
       AND p.proname <> 'require_approver_for';
    -- 【零必须是一次测量,不是一次缺席】—— 空名册会让下面那个比对空转通过
    IF COALESCE(cardinality(v_reg), 0) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 203E 失败:名册是空的 —— 一个空名册会让下面那条比对无论如何都通过'; END IF;
    IF v_reg IS DISTINCT FROM v_cat THEN
        RAISE EXCEPTION 'FIXTURE 203E 失败:名册与目录对不上 —— 名册=% 目录=%。接一条链上 require_approver_for,就要在 approval_chain_gates() 里加一行', v_reg, v_cat; END IF;

    -- ══════════════════════ A ★ 请假 · 提单的人自己批 ══════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hrA), true);
    v_denied := false;
    BEGIN
        PERFORM decide_leave_request(lv_id, false, 'x');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|raiser'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 203A 失败:提单的人自己批应当报 SELF_APPROVAL_FORBIDDEN|raiser,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ B ★★ 请假 · 单据说的那位自己批 ══════════════════════
    -- 【这条腿是 APR-2 新加的】。员工 B 持 module.hr.edit,而这张单**不是他提的** ——
    -- 只判 raiser 的实现会在这里【放行】,而那正是今天线上的形状。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hrB), true);
    v_denied := false;
    BEGIN
        PERFORM decide_leave_request(lv_id, false, 'x');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|subject'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 203B 失败:单据说的那位自己批应当报 SELF_APPROVAL_FORBIDDEN|subject,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ C ★ 对照:第三个人批得动 ══════════════════════
    -- 少了这一臂,A/B 证明的可能只是"这条路根本走不通"。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hrC), true);
    PERFORM decide_leave_request(lv_id, false, 'ok');
    SELECT count(*) INTO v_n FROM leave_requests WHERE id = lv_id AND status = 'rejected' AND decided_by = u_hrC;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 203C 失败:第三个人应当批得动这张单'; END IF;
    SELECT count(*) INTO v_n FROM approval_log WHERE subject_type='leave_request' AND subject_id = lv_id;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 203C 失败:那一次决定应当正好落一行留痕,实得 %', v_n; END IF;
    -- 【HR 三条链的 level 一律 NULL】它们没有层级,写 1 或 2 都是编出来的
    SELECT level INTO v_lvl FROM approval_log WHERE subject_type='leave_request' AND subject_id = lv_id;
    IF v_lvl IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 203C 失败:请假的留痕带了层级 % —— HR 三条链没有层级', v_lvl; END IF;

    -- ══════════════════════ D ★ 医疗申报 · subject 腿 + 对照 ══════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hrB), true);
    v_denied := false;
    BEGIN
        PERFORM decide_medical_claim(mc_id, false, 'x');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|subject'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 203D 失败:报销的主角自己批应当报 …|subject,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hrA), true);
    v_denied := false;
    BEGIN
        PERFORM decide_medical_claim(mc_id, false, 'x');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|raiser'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 203D 失败:报销的提单人自己批应当报 …|raiser,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hrC), true);
    PERFORM decide_medical_claim(mc_id, false, 'ok');
    SELECT count(*) INTO v_n FROM medical_claims WHERE id = mc_id AND status='rejected' AND decided_by = u_hrC;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 203D 失败:第三个人应当批得动这张报销'; END IF;

    -- ══════════════════════ F ★★ 绩效 · subject 腿 ══════════════════════
    -- 【此前全库都没有这条腿】approve_review 只拒 submitted_by,于是
    -- "别人提交、被评的那位自己批准"一路通到底 —— 而这条路会写
    -- employees.monthly_salary 与一行 employment_history 调薪记录。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hrB), true);
    v_denied := false;
    BEGIN
        PERFORM approve_review(pr_id);
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|subject'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 203F 失败:★ 被评的那位批准了自己的绩效(而这条路会写调薪),实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    -- raiser 那条腿仍然在(它是老规矩,不许被新的那条挤掉)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hrA), true);
    v_denied := false;
    BEGIN
        PERFORM approve_review(pr_id);
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|raiser'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 203F 失败:提交人自己批应当报 …|raiser,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    -- 对照:另一个人批得动(用第二份评估,免得被上面两次拒绝影响状态)。
    -- ★ 这里用的是 u_hrB,【不是】u_hrC —— 而这一处是本支自己踩出来的:
    --   第二份评估挂在员工 C 身上(一名员工只有一份未作废的试用期评估,
    --   所以它不能再挂给 B),于是 u_hrC 恰好【就是那张单说的人】,
    --   subject 那条腿当场开火,对照臂被自己要证的规矩拦住。
    --   ☞ 记在这里,因为它正是这条新规矩会咬到的那个形状:
    --     "找个第三方来批"这句话,要先确认那个第三方不是单据的主角。
    --   u_hrB 对这一张既不是提单人(u_hrA 提的)、也不是主角(主角是 C)。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hrB), true);
    PERFORM approve_review(pr2_id);
    SELECT count(*) INTO v_n FROM performance_reviews WHERE id = pr2_id AND status='approved';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 203F 失败:第三个人应当批得动那份评估'; END IF;

    -- ══════════════════════ H1 ★★ 一条没有人批得动的链 → 开不起来 ══════════
    -- ★ 顺序要紧:H 必须在 G 【之前】—— G 要的是"审批开着",而开着的钥匙
    --   正好是 H2 转出来的那一下。
    -- 此刻 fx203-l1 有真持有人(u_l1)、看得见金额(data.view_prices),
    -- 而他【不持 module.purchasing.view】—— 也就是 approve_purchase_order 的门。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_adm), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_approvals_policy(false, 'fx203-l1', 'fx203-l2', 1000);
    v_denied := false;
    BEGIN
        PERFORM set_approvals_policy(true, 'fx203-l1', 'fx203-l2', 1000);
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'APPROVALS_CHAIN_HAS_NO_APPROVER|approve_purchase_order|1|fx203-l1|%'); END;
    EXECUTE 'RESET ROLE';
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 203H1 失败:一条没有人批得动的链应当让开关【开不起来】,并点出函数·级别·角色·缺的码,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    IF (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'FIXTURE 203H1 失败:被拒绝之后开关却开着了'; END IF;

    -- ══════════════════════ H2 ★★ 把缺的码补上 → 开得起来 ══════════════════
    -- 【少了这一臂,一个"永远不许开"的实现会全绿】—— 与 fixture 202 的 G 同一条。
    -- ★ APR-ROUTE-1(R1):只补给【二级】。一级那条采购链从此经由 u_l2 批得动 ——
    --   R1 之前这一行补在 r_l1 上;补在 r_l2 上还开得起来,正是 R1 生效的读数。
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_l2, 'module.purchasing.view');
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_adm), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_approvals_policy(true, 'fx203-l1', 'fx203-l2', 1000);
    EXECUTE 'RESET ROLE';
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'FIXTURE 203H2 失败:三样齐备之后开关仍然开不起来 —— 那道闸变成了"永远不许开"'; END IF;
    SELECT count(*) FILTER (WHERE approvers = 0) INTO v_n FROM approval_gate_intersections();
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 203H2 失败:补上那个码之后仍有 % 条链没有人批得动', v_n; END IF;

    -- ══════════════════════ I ★ 屏幕与闸读同一份判据 ══════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_adm), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_read := approvals_readiness();
    EXECUTE 'RESET ROLE';
    SELECT count(*) INTO v_n FROM approval_gate_intersections();
    IF jsonb_array_length(v_read->'chain_gates') <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 203I 失败:面板报 % 条链,而判据有 % 条 —— 一块说"可以开"而闸会拒绝的屏幕',
            jsonb_array_length(v_read->'chain_gates'), v_n; END IF;
    IF (v_read->>'chains_without_approver')::integer <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 203I 失败:面板说还有 % 条链没人批得动,而判据说 0', v_read->>'chains_without_approver'; END IF;

    -- ══════════════════════ G ★★ 工单:审批【开着】时放行得了 ══════════════
    -- ★★ 这一臂是 APR-2 的头条:APR-2 之前,这里【必然】抛
    --    APPROVAL_NOT_AUTHORISED|1|<一级角色> —— 因为 u_proc 持
    --    module.processing.edit 而【不在】一级审批角色里,而那正是线上的形状。
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'FIXTURE 203G 布景失败:这一臂要审批【开着】才有意义'; END IF;
    -- 先证四眼那条腿在工单上也生效:建这张工单的就是 u_proc 自己
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_proc), true);
    v_denied := false;
    BEGIN
        PERFORM release_work_order(wo_id);
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|raiser'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 203G 失败:建这张工单的人自己放行应当报 …|raiser,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    -- ★ 换一个【也持 module.processing.edit、也不在一级审批角色里】的人 → 成功
    INSERT INTO user_roles (user_id, role_id) VALUES (u_hrC, r_proc);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hrC), true);
    PERFORM release_work_order(wo_id);
    SELECT count(*) INTO v_n FROM work_orders WHERE id = wo_id AND status = 'released';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 203G 失败:★ 审批开着时,一个持 module.processing.edit 的人仍然放行不了工单 —— 那把锁还在'; END IF;
    -- ★ 留痕那一行的层级必须是 NULL:这条路上没有跑过任何一级授权检查,
    --   写 1 就是让留痕声称发生过一件没有发生的事。
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_type='work_order' AND subject_id = wo_id AND decision='approved';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 203G 失败:放行应当正好落一行 approved 的留痕,实得 %', v_n; END IF;
    SELECT level INTO v_lvl FROM approval_log WHERE subject_type='work_order' AND subject_id = wo_id;
    IF v_lvl IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 203G 失败:工单留痕写了层级 % —— 这条路上没有跑过任何一级授权检查,那是一句假记录', v_lvl; END IF;

    RAISE NOTICE 'FIXTURE 203 全部通过:一份四眼判据、四个调用点(P)· 名册 vs 目录逐字相等(E)· 请假/报销/绩效的 raiser 与 subject 两条腿各自按名拒、且第三个人批得动(A/B/C/D/F)· 没有人批得动的链开不起来、补上码就开得起来(H1/H2)· 屏幕与闸读同一份判据(I)· ★ 审批开着时工单重新放行得了,而留痕的层级是 NULL(G)';
END $$;
ROLLBACK;
