-- 202 APR-1:审批策略那四列【只有一扇门】,而那扇门问的是"你能不能管权限"
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】
--   P ★ 写闸的名字排在 trg_approvals_switch 【之前】—— 触发器按名开火,顺序是设计的
--   A ★ RPC 写下四列,并且【正好】落一行史(谁 · 何时 · old → new)
--   B   什么都没改的一次保存:不落史(Q6)
--   C ★ 不持 action.manage_permissions 的人被 RPC 按名拒 —— 哪怕他持 module.finance.edit
--   D ★★ 直连写那四列被守卫按名拒,【哪怕他持 module.finance.edit】——
--        这正是 APR0-APPROVALS-SWITCH-WRITE-GATE 那个洞,而持有它的正是一级审批角色
--   E ★ 【对照】同一个会话直连写【非审批列】(期间锁)照常成功 ——
--        少了它,D 证明的可能只是"这条路根本不通"
--   F   留痕拒 UPDATE 与 DELETE,各自报名
--   G ★ RPC 不绕过 guard_approvals_switch:策略不全、角色没有真持有人 → 开不起来;
--        而三样齐备时【开得起来】(少了这一臂,一个"永远不许开"的实现全绿)
--   H ★★ work_order 的留痕【读得出来了】—— 而且两侧都有对照:
--        有 module.processing.view 的人读得到它、读不到别人的;
--        没有的人读得到自己那一支、读不到 work_order 这一支
--   I ★ N6:approvals_readiness 与页面的闸读【同一个码】
--   J   F6:RPC 不动 locked_before,所以 trg_finance_settings_sod 不会误伤它
--
-- 【躲开的陷阱,逐条】
--  (a) 两份实现碰巧一致 —— C/D/F/G 每一条拒绝都配一条【会成功】的对照,
--      于是"拒了"与"这条路根本走不通"分得开(E 是 D 的对照,A 是 C 的对照)。
--  (b) 断言为真却没有管辖权 —— D 用的人【持有 module.finance.edit】,
--      所以他的失败不可能是 enforce_write_permission 干的;E 当场证明他写得了这张表。
--  (c) 空集通过 —— H 的每一处可见性都断言【具体的数】,不是"非空"。
--  (d) 角色没切过去 —— H 的两个会话各自读到【不同的、都不是全集的】行数,
--      于是"零行"不可能是因为还在 postgres 身上(那会读到全部三行)。
--  (e) 旗子被外面举起来 —— D 的会话【没有】举旗的能力问题:它举得起来
--      (APR-1 实测 authenticated 可以 set_config),而它仍然被拒 ——
--      因为载重的那道测试是 row_security_active,不是旗子。D2 专门钉这一条。
--
-- 自带数据(README 第 2 条)。不继承线上任何值 —— 自己设(README 第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    u_adm   uuid := gen_random_uuid();   -- 持 action.manage_permissions:这扇门的钥匙
    u_fin   uuid := gen_random_uuid();   -- 持 module.finance.edit,【不】持前者 —— 一级审批人的形状
    u_proc  uuid := gen_random_uuid();   -- 持 module.processing.view:读得到工单留痕
    u_hr    uuid := gen_random_uuid();   -- 持 module.hr.view:读得到请假留痕,读不到工单
    r_adm   uuid; r_fin uuid; r_proc uuid; r_hr uuid; r_l1 uuid; r_l2 uuid; r_empty uuid;
    v_n     integer;
    v_msg   text; v_denied boolean;
    v_res   jsonb;
    v_hist  record;
    v_lock  date := DATE '2020-03-01';
    wo_id   uuid := gen_random_uuid();
    pay_id  uuid := gen_random_uuid();
    lv_id   uuid := gen_random_uuid();
BEGIN
    -- ══════════ 布景 ══════════
    -- confirmed_at 是【生成列】,所以设 email_confirmed_at(fixture 151 的同一课)。
    INSERT INTO auth.users (id, email_confirmed_at)
      VALUES (u_adm, now()), (u_fin, now()), (u_proc, now()), (u_hr, now());

    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx202-adm','f','f',true)   RETURNING id INTO r_adm;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx202-fin','f','f',true)   RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx202-proc','f','f',true)  RETURNING id INTO r_proc;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx202-hr','f','f',true)    RETURNING id INTO r_hr;
    -- 两个【有真持有人、且看得见金额】的审批角色 —— G 的"开得起来"那一臂要它们
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx202-l1','f','f',true)    RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx202-l2','f','f',true)    RETURNING id INTO r_l2;
    -- 一个【没有任何人持有】的角色 —— G 的"开不起来"那一臂要它
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx202-empty','f','f',true) RETURNING id INTO r_empty;

    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_adm,  'action.manage_permissions'),
        (r_adm,  'module.finance.view'),
        -- ★ D/E 的主角:他【持有】那张表的写权限。他的失败不可能是写权限造成的。
        (r_fin,  'module.finance.edit'),
        (r_fin,  'module.finance.view'),
        (r_proc, 'module.processing.view'),
        (r_hr,   'module.hr.view');
    -- 审批角色要看得见金额(R4),否则开关会以 ..._CANNOT_SEE_AMOUNTS 按名拒
    INSERT INTO role_permissions (role_id, permission_code)
      SELECT r, p FROM unnest(ARRAY[r_l1, r_l2]) r,
                       unnest(ARRAY['module.purchasing.view','data.view_prices', 'data.view_purchase_prices']) p;
    INSERT INTO role_permissions (role_id, permission_code)
      SELECT r_empty, unnest(ARRAY['module.purchasing.view','data.view_prices', 'data.view_purchase_prices']);

    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_adm, r_adm), (u_fin, r_fin), (u_proc, r_proc), (u_hr, r_hr),
        -- 两级各一个真的登录得了的持有人
        (u_adm, r_l1), (u_fin, r_l2);

    -- 期间锁先设一个值 —— E 与 J 都要它【不是 NULL】,否则那两臂在空库上空转。
    UPDATE finance_settings SET locked_before = v_lock;

    -- ══════════ P · 写闸装上了,而且【先于】开关闸开火 ══════════
    SELECT count(*) INTO v_n
      FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
     WHERE c.relname = 'finance_settings' AND NOT t.tgisinternal
       AND t.tgname = 'trg_approvals_policy_write_gate';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 202P 失败:写闸没有装在 finance_settings 上'; END IF;
    -- 触发器按【名字】排序开火。顺序不是巧合,它决定了一次直连写听到的是哪一句话。
    IF 'trg_approvals_policy_write_gate' >= 'trg_approvals_switch' THEN
        RAISE EXCEPTION 'FIXTURE 202P 失败:写闸的名字排在开关闸之后 —— 一次直连写会先听到一句关于策略完整性的话,而那会把人带偏'; END IF;
    -- 【守卫必须是 INVOKER】DEFINER 的话 row_security_active 问的是守卫自己,
    -- 于是它对每一个调用者都回答"RLS 没生效",这道闸【整个失效】而且全绿。
    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname = 'guard_approvals_policy_write' AND NOT prosecdef;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 202P 失败:守卫不是 INVOKER —— row_security_active 会问它自己,这道闸会放行一切'; END IF;

    -- ══════════ A ★ RPC 写下四列,并且正好落一行史 ══════════
    -- ★ PAYROLL-APR-1(2026-09-24):工资过账申请这条链的门是 module.hr.view + data.view_pay(Tim 的 Q8)。
    --   二级角色不持这两个码,开审批就会按名拒 APPROVALS_CHAIN_HAS_NO_APPROVER|decide_payroll_request —— 本 fixture 测的不是它。
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, c FROM roles r CROSS JOIN unnest(ARRAY['module.hr.view', 'data.view_pay']) c
     WHERE r.code = 'fx202-l2'
    ON CONFLICT (role_id, permission_code) DO NOTHING;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_adm), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := set_approvals_policy(false, 'fx202-l1', 'fx202-l2', 777);
    EXECUTE 'RESET ROLE';

    IF (v_res->>'changed')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 202A 失败:RPC 说什么都没改,实得 %', v_res; END IF;

    SELECT count(*) INTO v_n FROM finance_settings
     WHERE approvals_enabled = false
       AND approval_level1_role_code = 'fx202-l1'
       AND approval_level2_role_code = 'fx202-l2'
       AND approval_threshold_base = 777;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 202A 失败:四列没有被一起写下去'; END IF;

    SELECT count(*) INTO v_n FROM finance_settings_history;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 202A 失败:一次改动应当正好落 1 行史,实得 %', v_n; END IF;

    SELECT * INTO v_hist FROM finance_settings_history;
    -- 【old → new 两侧都要】只记 new 的历史答不了"它从什么改过来的",
    -- 而那正是一份变更史唯一不可替代的问题。
    IF v_hist.new_approval_level1_role_code <> 'fx202-l1'
       OR v_hist.new_approval_level2_role_code <> 'fx202-l2'
       OR v_hist.new_approval_threshold_base <> 777
       OR v_hist.old_approval_level1_role_code IS NOT NULL
       OR v_hist.changed_by <> u_adm THEN
        RAISE EXCEPTION 'FIXTURE 202A 失败:那一行史记错了(who=% old_l1=% new_l1=% new_thr=%)',
            v_hist.changed_by, v_hist.old_approval_level1_role_code,
            v_hist.new_approval_level1_role_code, v_hist.new_approval_threshold_base; END IF;

    -- ══════════ J · RPC 不动期间锁,所以 SOD 那道闸不会误伤它 ══════════
    -- 【为什么这一臂存在】trg_finance_settings_sod 对【任何一次】UPDATE 开火;
    -- 它只在 locked_before 往前搬时才问 SOD。RPC 一旦顺手改动那一列,
    -- 这条路就会继承一条它没有做过的改动所带来的拒绝。
    IF (SELECT locked_before FROM finance_settings) IS DISTINCT FROM v_lock THEN
        RAISE EXCEPTION 'FIXTURE 202J 失败:RPC 动了期间锁'; END IF;

    -- ══════════ B · 什么都没改 → 不落史(Q6)══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_adm), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := set_approvals_policy(false, 'fx202-l1', 'fx202-l2', 777);
    EXECUTE 'RESET ROLE';
    IF (v_res->>'changed')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 202B 失败:原封不动的一次保存不该报告成一次改动'; END IF;
    SELECT count(*) INTO v_n FROM finance_settings_history;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 202B 失败:没改动的一次保存落了史,史现在有 % 行 —— 一份记满了"没发生的事"的历史会把真正发生过的那几次埋掉', v_n; END IF;

    -- ══════════ C ★ 不持 action.manage_permissions → RPC 按名拒 ══════════
    -- 【他持 module.finance.edit】—— 也就是说他【写得了】这张表(E 当场证明),
    -- 所以这一条拒绝只可能来自 RPC 自己的判据。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false;
    BEGIN
        PERFORM set_approvals_policy(false, 'fx202-l2', 'fx202-l1', 999);
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        v_denied := (SQLERRM = 'PERMISSION_DENIED|action.manage_permissions');
    END;
    IF NOT v_denied THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 202C 失败:持 module.finance.edit 而不持 action.manage_permissions 的人应当被 RPC 按名拒,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════ D ★★ 直连写那四列 → 守卫按名拒,而他【写得了这张表】 ══════════
    -- 仍然是 u_fin 的会话(authenticated)。
    v_denied := false;
    BEGIN
        UPDATE finance_settings SET approvals_enabled = true;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        v_denied := (SQLERRM = 'APPROVALS_POLICY_DIRECT_WRITE|approvals_enabled');
    END;
    IF NOT v_denied THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 202D 失败:★ 一级审批角色直接改得动那条约束她自己的策略 ★ —— 实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- 【拒绝要【点名是哪几列】】一条只说"不许"的拒绝,读的人不知道自己碰了什么。
    v_denied := false;
    BEGIN
        UPDATE finance_settings SET approval_threshold_base = 5, approval_level1_role_code = 'fx202-l2';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        v_denied := (SQLERRM = 'APPROVALS_POLICY_DIRECT_WRITE|approval_level1_role_code, approval_threshold_base');
    END;
    IF NOT v_denied THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 202D 失败:拒绝没有逐列点名,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════ D2 ★ 旗子举得起来,而它仍然拦得住 ══════════
    -- 【本仓库被 set_config 烧过一次】所以这一臂问的是:把旗子举起来,能不能
    -- 混过去?**不能** —— 载重的那道测试是 row_security_active,而它举不起来。
    -- APR-1 实测:authenticated 确实 set_config 得了(成功、读得回、不报错)。
    v_denied := false;
    BEGIN
        PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
        UPDATE finance_settings SET approvals_enabled = true;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        v_denied := (SQLERRM = 'APPROVALS_POLICY_DIRECT_WRITE|approvals_enabled');
    END;
    IF NOT v_denied THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 202D2 失败:★ 自己举一次旗就混过了这道闸 ★ —— 那说明边界建在一个谁都写得进的值上,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '', true);

    -- ══════════ E ★ 对照:同一个会话直连写【非审批列】照常成功 ══════════
    -- 【少了这一臂,D 证明的可能只是"这条路根本不通"】——
    -- 而且它同时钉住"守卫不许碰其余各列"这条裁定。
    UPDATE finance_settings SET locked_before = v_lock - 1;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    EXECUTE 'RESET ROLE';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 202E 失败:期间锁这条直连写被连累了(rows=%)—— 守卫越出了它那四列', v_n; END IF;
    IF (SELECT locked_before FROM finance_settings) <> v_lock - 1 THEN
        RAISE EXCEPTION 'FIXTURE 202E 失败:期间锁没有真的写进去'; END IF;

    -- ══════════ F · 留痕拒 UPDATE 与 DELETE ══════════
    v_denied := false;
    BEGIN
        UPDATE finance_settings_history SET new_approval_threshold_base = 1;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'HISTORY_APPEND_ONLY'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 202F 失败:留痕改得动,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    v_denied := false;
    BEGIN
        DELETE FROM finance_settings_history;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'HISTORY_APPEND_ONLY'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 202F 失败:留痕删得掉,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════ G ★ RPC 不绕过 guard_approvals_switch ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_adm), true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    -- G1 策略不全 → 开不起来
    v_denied := false;
    BEGIN
        PERFORM set_approvals_policy(true, 'fx202-l1', NULL, 777);
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'APPROVALS_POLICY_INCOMPLETE|%'); END;
    IF NOT v_denied THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 202G1 失败:策略不全也开得起来,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- G2 角色没有任何真持有人 → 开不起来,而且【点名是哪一级、哪个角色】
    v_denied := false;
    BEGIN
        PERFORM set_approvals_policy(true, 'fx202-empty', 'fx202-l2', 777);
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'APPROVALS_LEVEL1_ROLE_UNHELD|fx202-empty'); END;
    IF NOT v_denied THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 202G2 失败:指向一个没人持有的角色也开得起来,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- G3 ★【会成功】的那一臂 —— 少了它,一个"永远不许开"的实现全绿
    v_res := set_approvals_policy(true, 'fx202-l1', 'fx202-l2', 777);
    IF (v_res->>'changed')::boolean IS NOT TRUE
       OR NOT (SELECT approvals_enabled FROM finance_settings) THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 202G3 失败:三样齐备时也开不起来 —— 那说明上面两条拒绝证明不了任何事'; END IF;
    SELECT count(*) INTO v_n FROM finance_settings_history;
    IF v_n <> 2 THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 202G3 失败:开关被翻开却没有落史,史有 % 行', v_n; END IF;

    -- ══════════ I ★ N6:approvals_readiness 与页面的闸读同一个码 ══════════
    v_res := approvals_readiness();
    IF v_res->>'level1_role_code' <> 'fx202-l1' THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 202I 失败:持 action.manage_permissions 的人读不到就绪面板'; END IF;
    EXECUTE 'RESET ROLE';

    -- 【对照】持 module.finance.view 而不持 action.manage_permissions 的人被拒 ——
    -- 这正是 N6 之前那块屏幕的形状:页面的闸放他进来,函数把他挡在外面。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false;
    BEGIN
        PERFORM approvals_readiness();
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.manage_permissions'); END;
    EXECUTE 'RESET ROLE';
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 202I 失败:就绪面板的内检没有跟页面的闸对齐,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════ H ★★ work_order 的留痕读得出来了 ══════════
    -- 三行,三个 subject_type。【属主身份直插】—— approval_log 没有 INSERT 策略,
    -- 唯一的写入口是 record_approval_decision,而这一臂要验的是【读】那一侧。
    INSERT INTO approval_log (subject_type, subject_id, decision, level, actor_user_id) VALUES
        ('work_order',    wo_id,  'approved', 1, u_adm),
        ('payment',       pay_id, 'approved', 1, u_adm),
        ('leave_request', lv_id,  'approved', NULL, u_adm);

    -- H1 持 module.processing.view 的人:读得到工单那一行
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_proc), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM approval_log WHERE subject_type = 'work_order';
    IF v_n <> 1 THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 202H1 失败:★ 工单的审批留痕仍然是一个安静的零 ★(实得 % 行)—— 一片正确的空白,与"这张工单还没有被放行过"在屏幕上逐字相同', v_n; END IF;
    -- 【同会话对照 ①:角色真的切过去了】还在 postgres 身上的话,下面这个数是 3。
    SELECT count(*) INTO v_n FROM approval_log;
    IF v_n <> 1 THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 202H1 失败:这个会话读到了 % 行 —— 它应当只读得到它那一支(角色没切过去,或者策略整个失效了)', v_n; END IF;
    EXECUTE 'RESET ROLE';

    -- H2 不持 module.processing.view 的人:读不到工单那一行 ——
    -- 【而且他读得到【自己那一支】】,所以这个零是"不该你看",不是"这张表读不了"。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hr), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM approval_log WHERE subject_type = 'work_order';
    IF v_n <> 0 THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 202H2 失败:没有 module.processing.view 的人读到了 % 行工单留痕', v_n; END IF;
    SELECT count(*) INTO v_n FROM approval_log WHERE subject_type = 'leave_request';
    IF v_n <> 1 THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 202H2 失败:他连自己那一支都读不到(实得 %)—— 那说明上面那个零证明不了任何事', v_n; END IF;
    EXECUTE 'RESET ROLE';

    RAISE NOTICE 'FIXTURE 202 全部通过:写闸先于开关闸开火 · RPC 是唯一的门(A/C)· 直连写按名拒且举旗也混不过去(D/D2)· 期间锁不受连累(E)· 留痕只增不改(F)· 不绕过开关的两道闸且开得起来(G)· N6 对齐(I)· 工单留痕读得出来(H)';
END $$;
ROLLBACK;
