-- 204 APR-3:【报销单接上引擎】· 【在途张数的两个问法】· 【会搁死单据的策略编辑】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】
--   ★ 四格(APR-0 §3.2)在【报销单】上逐格走一遍,而第 ④ 格是唯一一个
--     漏掉也不会有任何东西变红的 —— 所以它在这里有自己的一臂,用【真身份】读:
--   Q  ① 枚举:expense_claim 在 approval_log 的 CHECK 里(不在 → 响亮地抛)
--   R  ② 分支:record_approval_decision 认得它,并且【把金额冻结下来】
--   S  ③ 决定路径:分档 · 四眼 · 留痕(A/B/C/D 四臂)
--   T  ★★ ④ 读策略那一支:写得进、【读得出】—— 一个持 module.finance.view 的
--        真身份读得到那一行,一个不持的读到 0 行【而且不报错】。
--        ☞ 少了它,那一行对每一个人都是 0 行,而屏幕上与"还没有人批过"逐字相同。
--
--   A  ★ 提单的人自己批 → SELF_APPROVAL_FORBIDDEN|raiser
--   B  ★★ 【单据说的那位】自己批 → …|subject(代人提单时两者是两个人)
--   C  ★ 【对照】第三个人批得动,而且正好落一行留痕、level 是【那一档】
--   D  ★★ 分档:1000.00 恰好等于门槛 → 二级;999.99 → 一级。
--        而【一级的人去批那张二级的单】→ APPROVAL_NOT_AUTHORISED|2|<二级角色>
--        ☞ 少了这一条,"分档"只是一个算出来却没有人读的数。
--   E  ★★ 名册:expense_claim 两行【在】approval_chain_gates() 里,而它们的门是
--        module.finance.view + data.view_prices —— ★【不是】module.finance.edit。
--        ☞ 写成 edit 的话今天照样全绿(cfo 的唯一真持有人就是 admin 账号),
--          而独立 CFO 账号一落地二级就归零。这一臂把那个区别钉死在【码】上。
--   F  ★ 盘点:四眼(只有 raiser 那条腿)+ 留痕 level 是 NULL + 对照臂过账得了
--   G  ★ 工单:审批【关着】时写的是 approved,★【不是】auto_approved(Tim 的 Q7)
--   H  ★★ approval_pending_documents 的三条边界:
--        H1 submitted 的报销单【在】里面,blocks_disable = false
--        H2 open 的盘点【不在】里面(open 是"正在点",不是"在等人批")
--        H3 pending 的采购单【在】里面,blocks_disable = true
--        ☞ 三条合起来才说明白"在途"与"会被搁死"是两个问题。
--   I  ★★ 屏幕与闸读同一份判据:approvals_readiness 的 pending_blocking_disable
--        必须逐字等于闸那一支数出来的那个数,而 can_disable 跟着它、
--        【不】跟着逐链那个更大的数。
--   J  ★★★ APPROVALS_POLICY_WOULD_STRAND,两个方向:
--        J1 一次会把在途单据推到"没有人批得动"那一档的策略编辑 → 按名拒,
--           并点出【那张单 · 那一级 · 那个角色 · 那支函数 · 缺的码】
--        J2 ★ 一次【无害的】策略编辑 → 放行
--           ☞ 少了 J2,一个"策略一律不许改"的实现会全绿 —— 而那正是
--             Tim 的 N8 裁定要排除的东西(「拒绝要给出路,不是给一堵墙」)。
--
-- 【躲开的陷阱,逐条】
--  (a) 两份实现碰巧一致 —— 每一条拒绝都配一条【会成功】的对照
--      (C 之于 A/B,D 的两档互为对照,F2 之于 F,J2 之于 J1)。
--  (b) 空集通过 —— E 先断言名册里【有】那两行再比码;H 断言的是【具体的数】。
--  (c) 一个"永远拒绝"的实现全绿 —— C / F2 / J2 就是为这个存在的。
--  (d) 断言为真却没有管辖权 —— A/B 的演员【持有那条链的模块门】(C 当场证明),
--      所以他们的失败不可能是权限门造成的。
--  (e) 读【文件】而不是读【目录】—— E 与 G 查的是 pg_proc / 真的落库行。
--  (f) ★ RLS 的断言必须【切到真身份】跑 —— fixture 以 postgres 跑,它 bypass RLS,
--      不切角色的话 T 臂整个空转(fixture 26 的那一课,原样适用)。
--
-- 自带数据(README 第 2 条)。不继承线上任何值 —— 自己设(README 第 4 条)。
-- ★ 本位币从 currencies.is_base 读,不写死(THE FX RULE:币种是数据,不是常量)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    -- 人
    u_l1    uuid := gen_random_uuid();   -- 一级审批角色的真持有人
    u_l2    uuid := gen_random_uuid();   -- 二级审批角色的真持有人(★ 另一个人)
    u_rais  uuid := gen_random_uuid();   -- 代人提单的那位(财务),他也是盘点的建单人
    u_subj  uuid := gen_random_uuid();   -- 单据说的就是他 —— 而且他也持那条链的门
    u_nof   uuid := gen_random_uuid();   -- 持门、但不在任何一级审批角色里(审批关着时的对照)
    u_adm   uuid := gen_random_uuid();   -- action.manage_permissions:开关那扇门的钥匙
    -- ★ T 臂的【反方向】演员:一个【不持 module.finance.view】的真身份。
    --   少了他,T 臂只证明了"读得到",而一条 USING (true) 的策略也读得到。
    u_nofin uuid := gen_random_uuid();
    -- ★★ J1 的二级角色【必须由一个只持它的人】持有 —— 见那一臂的注释。
    u_l2b   uuid := gen_random_uuid();
    r_l2b   uuid;
    r_l1 uuid; r_l2 uuid; r_fin uuid; r_adm uuid; r_nofin uuid;
    e_subj uuid := gen_random_uuid();
    e_rais uuid := gen_random_uuid();
    e_nof  uuid := gen_random_uuid();
    -- 单据
    c_hi  uuid := gen_random_uuid();     -- 恰好 1000.00 → 二级
    c_lo  uuid := gen_random_uuid();     -- 999.99      → 一级
    c_ctl uuid := gen_random_uuid();     -- 对照臂用
    c_sub uuid := gen_random_uuid();     -- subject 那条腿用
    st_id uuid := gen_random_uuid();
    wo_id uuid := gen_random_uuid();
    po_id uuid := gen_random_uuid();
    sup_id uuid := gen_random_uuid();
    v_base text;
    v_n integer; v_msg text; v_denied boolean;
    v_lvl smallint; v_amt numeric; v_ccy text; v_rate numeric;
    v_read jsonb; v_gate integer;
    v_perms text[];
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    IF v_base IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 204 布景失败:currencies 里没有本位币 —— 这支 fixture 依赖那份种子数据';
    END IF;

    -- ══════════════════════ 布景 ══════════════════════
    -- confirmed_at 是【生成列】,所以设 email_confirmed_at(fixture 151/202/203 同一课)。
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_l1, now()), (u_l2, now()), (u_rais, now()),
        (u_subj, now()), (u_nof, now()), (u_adm, now()), (u_nofin, now()), (u_l2b, now());

    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx204-l1','f','f',true)  RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx204-l2','f','f',true)  RETURNING id INTO r_l2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx204-fin','f','f',true) RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx204-adm','f','f',true) RETURNING id INTO r_adm;
    -- ★ 一个【进得了系统、而进不了财务】的角色 —— T 臂的反方向要它。
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx204-nofin','f','f',true) RETURNING id INTO r_nofin;

    -- ★ 报销那条链的门:module.finance.view + data.view_prices —— 【不是】edit。
    --   两级都要 data.view_prices,否则开关会先撞上 ..._CANNOT_SEE_AMOUNTS(R4),
    --   而那会让下面的臂为【错的理由】变红。
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_l1,  'module.finance.view'), (r_l1, 'data.view_prices'), (r_l1, 'data.view_purchase_prices'),
        (r_l2,  'module.finance.view'), (r_l2, 'data.view_prices'), (r_l2, 'data.view_purchase_prices'),
        (r_fin, 'module.finance.view'), (r_fin, 'data.view_prices'), (r_fin, 'data.view_purchase_prices'),
        (r_fin, 'module.stocktakes.edit'), (r_fin, 'module.stocktakes.view'),
        (r_fin, 'module.processing.edit'),
        (r_adm, 'action.manage_permissions'),
        (r_adm, 'module.finance.view'), (r_adm, 'data.view_prices'), (r_adm, 'data.view_purchase_prices'),
        -- 采购单那条链今天也在名册里,两级都必须有人批得动,
        -- 否则开关那道闸会为【别的链】变红,而 J 臂要的是报销那一条。
        (r_l1,  'module.purchasing.view'), (r_l2,  'module.purchasing.view'),
        -- H3 要一张 pending 的采购单,建它要这两个码
        (r_adm, 'module.purchasing.edit'), (r_adm, 'module.suppliers.edit'),
        -- ★ 它【只有】人事那个读码 —— 一个字的财务权限都没有。
        (r_nofin, 'module.hr.view');

    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_l1, r_l1), (u_l2, r_l2),
        (u_rais, r_fin), (u_subj, r_fin), (u_nof, r_fin), (u_adm, r_adm),
        (u_nofin, r_nofin);

    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_subj, 'FX204-S', 'S', 'full_time', 'office', DATE '2020-01-01', u_subj),
        (e_rais, 'FX204-R', 'R', 'full_time', 'office', DATE '2020-01-01', u_rais),
        (e_nof,  'FX204-N', 'N', 'full_time', 'office', DATE '2020-01-01', u_nof);

    -- ★ 四张报销单,主角【都是员工 S】、提单的【都是 u_rais】—— 也就是
    --   "财务代人录入"那个形状。raiser 与 subject 因此是两个【不同的】人,
    --   两条腿才分得开(合在一起写,B 那一臂会被 A 那一臂顺带通过)。
    --   金额一律本位币,于是它不依赖 fx_rates 里有没有那一天的牌价 ——
    --   这一支要验的是分档与四眼,不是 THE FX RULE。
    INSERT INTO expense_claims (id, code, employee_id, spend_date, amount_ccy, currency,
                                description, no_receipt_reason, status, created_by) VALUES
        (c_hi,  'FX204-C-HI',  e_subj, DATE '2030-03-01', 1000.00, v_base, 'hi',  'none', 'submitted', u_rais),
        (c_lo,  'FX204-C-LO',  e_subj, DATE '2030-03-01',  999.99, v_base, 'lo',  'none', 'submitted', u_rais),
        (c_ctl, 'FX204-C-CTL', e_subj, DATE '2030-03-01',  100.00, v_base, 'ctl', 'none', 'submitted', u_rais),
        (c_sub, 'FX204-C-SUB', e_subj, DATE '2030-03-01',  100.00, v_base, 'sub', 'none', 'submitted', u_rais);

    INSERT INTO stocktakes (id, code, status, created_by)
      VALUES (st_id, 'FX204-ST-1', 'open', u_rais);
    INSERT INTO work_orders (id, code, status, created_by)
      VALUES (wo_id, 'FX204-WO-1', 'draft', u_rais);

    -- 一张 pending 的采购单(H3 与 J 臂要它)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_adm), true);
    -- ROLE-1 Batch 2a:新采购单 / 付款申请要一家【已批准】的供应商(approved / active)。
    -- 属主路径直接生成 active —— 直连 INSERT 必须是 draft 那条只管客户端会话。
    INSERT INTO suppliers (status, id, code, legal_name, country, counterparty_type)
      VALUES ('active', sup_id, 'FX204-SUP', 'Sup', 'SG', 'goods_supplier');
    INSERT INTO purchase_orders (id, code, supplier_id, order_date, currency, fx_rate,
                                 estimated_total_ccy, status, approval_status, created_by)
      VALUES (po_id, 'FX204-PO-1', sup_id, DATE '2030-03-01', v_base, 1, 50.00,
              'draft', 'pending', u_rais);

    -- ══════════════════════ 策略:两级各一个真持有人,门槛 1000 ══════════════════════
    -- 【这一臂自己设策略】重建出来的库里 finance_settings 是没配的,
    --   依赖线上的值,这一支在重建库上就是一句空话(README 第 4 条)。
    -- APR-1:直写这四列必须【显式举旗】(守卫用完即焚,所以每一次写都要举一次)。
    -- ★ PAYROLL-APR-1(2026-09-24):工资过账申请这条链的门是 module.hr.view + data.view_pay(Tim 的 Q8)。
    --   二级角色不持这两个码,开审批就会按名拒 APPROVALS_CHAIN_HAS_NO_APPROVER|decide_payroll_request —— 本 fixture 测的不是它。
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, c FROM roles r CROSS JOIN unnest(ARRAY['module.hr.view', 'data.view_pay']) c
     WHERE r.code = 'fx204-l2'
    ON CONFLICT (role_id, permission_code) DO NOTHING;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx204-l1',
                                approval_level2_role_code = 'fx204-l2',
                                approval_threshold_base   = 1000;

    -- ══════════════════════ Q ① 枚举 ══════════════════════
    -- 不在枚举里的话,下面每一条 record_approval_decision 都会抛
    -- APPROVAL_SUBJECT_TYPE_UNKNOWN —— 响亮,所以这一臂只是把它说出来。
    SELECT count(*) INTO v_n
      FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
     WHERE t.relname = 'approval_log' AND c.contype = 'c'
       AND pg_get_constraintdef(c.oid) LIKE '%expense_claim%';
    IF v_n < 1 THEN
        RAISE EXCEPTION 'FIXTURE 204Q 失败:approval_log 的 CHECK 枚举里没有 expense_claim'; END IF;

    -- ══════════════════════ G ★ 工单:关着的时候写的是 approved ══════════════════════
    -- 【先跑它,因为它要审批【关着】】—— 下面 S/D/J 各臂才把开关打开。
    -- Tim 的 Q7:放行是一个人按下去的动作,开着关着都是。
    -- ★ 这一臂断言的是【没有】auto_approved —— 而"没有"这种断言最容易空转,
    --   所以它同时断言【有】一行 approved:两个方向一起钉。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_nof), true);
    PERFORM release_work_order(wo_id);
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_type='work_order' AND subject_id=wo_id AND decision='approved';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 204G 失败:审批关着时放行工单应当落一行 approved 的留痕,实得 % 行', v_n; END IF;
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_type='work_order' AND subject_id=wo_id AND decision='auto_approved';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 204G 失败:★ 工单还在写 auto_approved —— 而放行是一个人按下去的,那一行留痕会说"没有人做过这个决定",旁边却记着是谁'; END IF;

    -- ══════════════════════ 打开审批 ══════════════════════
    -- 走 UPDATE 而不是 set_approvals_policy():后者要 action.manage_permissions,
    -- 而这一支要验的是 guard_approvals_switch 那几道闸本身。举旗照旧。
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- ══════════════════════ E ★★ 名册:报销那两行,以及它们的【门】 ══════════════════════
    -- 【零必须是一次测量,不是一次缺席】—— 先断言那两行在,再比码。
    SELECT count(*) INTO v_n FROM approval_chain_gates()
     WHERE subject_type = 'expense_claim' AND action_function = 'decide_expense_claim';
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 204E 失败:approval_chain_gates() 里报销那条链应当有两行(一级与二级),实得 %', v_n; END IF;
    FOR v_lvl IN 1..2 LOOP
        SELECT gate_permissions INTO v_perms FROM approval_chain_gates()
         WHERE subject_type='expense_claim' AND level = v_lvl;
        IF NOT ('module.finance.view' = ANY(v_perms) AND 'data.view_prices' = ANY(v_perms)) THEN
            RAISE EXCEPTION 'FIXTURE 204E 失败:报销链第 % 级的门应当是 module.finance.view + data.view_prices,实得 %', v_lvl, v_perms; END IF;
        -- ★★ 这一句是本臂的要点:门【不是】 module.finance.edit。
        --   写成 edit 的话今天照样全绿(二级角色的唯一真持有人恰好另有 edit),
        --   而独立 CFO 账号一落地,二级当场归零 —— 那一天没有任何东西会说
        --   是这一刀造成的。
        IF 'module.finance.edit' = ANY(v_perms) THEN
            RAISE EXCEPTION 'FIXTURE 204E 失败:★ 报销链第 % 级的门写了 module.finance.edit —— 批的人不该是提得了这张单的人,而且 cfo 不持这个码', v_lvl; END IF;
    END LOOP;

    -- ══════════════════════ D ★★ 分档:恰好等于门槛的那一笔走二级 ══════════════════════
    -- 【只有"恰好等于"那一个数能分辨 >= 与 >】—— fixture 151 的 T 臂钉的是
    --   approval_level_for 本身,这里钉的是【报销这条链真的按它路由】。
    SELECT b.amount_base INTO v_amt FROM expense_claim_amount_base(c_hi) b;
    IF v_amt IS DISTINCT FROM 1000.00 THEN
        RAISE EXCEPTION 'FIXTURE 204D 失败:1000.00 本位币的报销单算出来的 amount_base 是 %', v_amt; END IF;
    IF approval_level_for(v_amt) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 204D 失败:★ 恰好等于门槛的那一笔应当走二级,实得 %', approval_level_for(v_amt); END IF;
    SELECT b.amount_base INTO v_amt FROM expense_claim_amount_base(c_lo) b;
    IF approval_level_for(v_amt) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 204D 失败:999.99 应当走一级,实得 %', approval_level_for(v_amt); END IF;

    -- ★ 而分档要【真的拦人】才算数:一级那位去批那张二级的单 → 按名拒。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_l1), true);
    v_denied := false;
    BEGIN
        PERFORM decide_expense_claim(c_hi, false, NULL, NULL, NULL, 'no');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'APPROVAL_NOT_AUTHORISED|2|fx204-l2'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 204D 失败:一级的人去批那张二级的单应当报 APPROVAL_NOT_AUTHORISED|2|fx204-l2,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    -- ★ 对照:同一个人去批那张【一级】的单 —— 走得通。
    --   少了它,上面那条拒绝可能只说明这条路整个不通。
    PERFORM decide_expense_claim(c_lo, false, NULL, NULL, NULL, 'no');
    SELECT level INTO v_lvl FROM approval_log
     WHERE subject_type='expense_claim' AND subject_id=c_lo;
    IF v_lvl <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 204D 失败:999.99 那张单的留痕层级应当是 1,实得 %', COALESCE(v_lvl::text,'NULL'); END IF;

    -- ══════════════════════ R ② 分支:金额冻结在决定当时 ══════════════════════
    SELECT amount_ccy, currency, fx_rate, amount_base INTO v_amt, v_ccy, v_rate, v_n
      FROM approval_log WHERE subject_type='expense_claim' AND subject_id=c_lo;
    IF v_amt IS DISTINCT FROM 999.99 OR v_ccy IS DISTINCT FROM v_base OR v_rate IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 204R 失败:留痕没有把金额冻结下来 —— amount_ccy=% currency=% fx_rate=%', v_amt, v_ccy, v_rate; END IF;

    -- ══════════════════════ A ★ raiser 那条腿 ══════════════════════
    -- 演员 u_rais 【持有这条链的门】(下面 C 臂当场证明这条路是通的),
    -- 所以他的失败不可能是权限门造成的。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_rais), true);
    v_denied := false;
    BEGIN
        PERFORM decide_expense_claim(c_ctl, false, NULL, NULL, NULL, 'no');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|raiser'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 204A 失败:提单的人自己批应当报 SELF_APPROVAL_FORBIDDEN|raiser,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ B ★★ subject 那条腿 ══════════════════════
    -- ★ 这一臂只有在【提单人与主角是两个人】时才有意义:否则 raiser 先判,
    --   它永远走不到 subject 那一句(线上那两张请假单就是这个形状,APR-2 §5 记过)。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_subj), true);
    v_denied := false;
    BEGIN
        PERFORM decide_expense_claim(c_sub, false, NULL, NULL, NULL, 'no');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|subject'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 204B 失败:★ 单据说的那位自己批应当报 SELF_APPROVAL_FORBIDDEN|subject —— 他拿得到这笔钱,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════════════════ C ★ 对照:第三个人批得动 ══════════════════════
    -- 【没有这一臂,A 与 B 证明的可能只是"这条路根本不通"】
    -- 100.00 < 1000 → 一级,而 u_l1 正是一级那位,且他既不是提单人也不是主角。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_l1), true);
    PERFORM decide_expense_claim(c_ctl, false, NULL, NULL, NULL, 'no good reason');
    SELECT count(*) INTO v_n FROM expense_claims WHERE id = c_ctl AND status = 'rejected';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 204C 失败:第三个人应当驳得回那张单'; END IF;
    -- ★ 驳回【也】留痕 —— APR-1 建这张表的第一条理由就是"驳回不留痕迹"。
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_type='expense_claim' AND subject_id=c_ctl AND decision='rejected';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 204C 失败:驳回应当正好落一行 rejected 的留痕,实得 %', v_n; END IF;

    -- ══════════════════════ T ★★★ ④ 读策略那一支 —— 用【真身份】读 ══════════════════════
    -- 【这是四格里唯一一个漏掉也不会有任何东西变红的】写得进、读不出:
    --   对每一个人都是 0 行,而且不报错 —— 与"还没有人批过这张单"在屏幕上逐字相同。
    -- ★ fixture 以 postgres 跑,它 bypass RLS,所以【必须切到 authenticated】——
    --   不切的话这一臂整个空转(fixture 26 那一课,原样适用)。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_l1), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_type='expense_claim' AND subject_id=c_ctl;
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 204T 失败:★ 一个持 module.finance.view 的真身份读不到报销的留痕(实得 % 行)—— approval_log 的读策略缺了 expense_claim 那一支,而它写得进、读不出,对每一个人都是 0 行且不报错', v_n; END IF;
    -- ★★ 反方向:一个【不持那个码】的真身份读到 0 行,【而且不报错】。
    --   少了它,一条 `USING (true)` 的策略会让上面那一句照样通过 ——
    --   也就是说上面那个 1 证明的会是"策略整个敞着",不是"这一支接对了"。
    --   ☞ 演员必须是一个【一个字财务权限都没有】的人:u_subj / u_l2 / u_adm
    --     全都持 module.finance.view,拿他们当反例是一次空转。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_nofin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_type='expense_claim' AND subject_id=c_ctl;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 204T 失败:★ 一个不持 module.finance.view 的人读到了 % 行报销留痕 —— 那一支策略太宽', v_n; END IF;

    -- ══════════════════════ F ★ 盘点:四眼 + 留痕 level 是 NULL ══════════════════════
    -- 建单的是 u_rais,所以他自己过不了账 —— 与线上那五张 open 的盘点同形
    -- (那五张都是 admin 建的,从 APR-3 起 admin 自己过不了)。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_rais), true);
    v_denied := false;
    BEGIN
        PERFORM post_stocktake(st_id);
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|raiser'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 204F 失败:建盘点的人自己过账应当报 …|raiser,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;
    -- ★ 对照:另一个持 module.stocktakes.edit 的人过得了账。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_nof), true);
    PERFORM post_stocktake(st_id);
    SELECT count(*) INTO v_n FROM stocktakes WHERE id = st_id AND status = 'posted';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 204F 失败:第二个持 module.stocktakes.edit 的人应当过得了账'; END IF;
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_type='stocktake' AND subject_id=st_id AND decision='approved';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 204F 失败:盘点过账应当正好落一行 approved 的留痕,实得 %', v_n; END IF;
    SELECT level INTO v_lvl FROM approval_log WHERE subject_type='stocktake' AND subject_id=st_id;
    IF v_lvl IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 204F 失败:盘点留痕写了层级 % —— 它没有按角色分级,写一个级别就是声称有过一次授权步骤', v_lvl; END IF;

    -- ══════════════════════ H ★★ 在途:三条边界 ══════════════════════
    -- H1 submitted 的报销单在里面,而它【不】挡关闭
    SELECT count(*) INTO v_n FROM approval_pending_documents()
     WHERE subject_type='expense_claim' AND NOT blocks_disable;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 204H1 失败:应当有 2 张 submitted 的报销单在途且不挡关闭(c_hi 与 c_sub),实得 %', v_n; END IF;
    -- H2 ★ open 的盘点【不在】里面 —— open 是"正在点",不是"在等人批"
    --    (上面 F 臂已经把 st_id 过账了,所以另建一张 open 的来问)
    INSERT INTO stocktakes (id, code, status, created_by)
      VALUES (gen_random_uuid(), 'FX204-ST-2', 'open', u_rais);
    SELECT count(*) INTO v_n FROM approval_pending_documents() WHERE subject_type='stocktake';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 204H2 失败:★ open 的盘点被数成了在途待批(实得 % 张)—— open 的意思是"正在点",把它数进去会让屏幕说一句假话,而且会让审批关不掉', v_n; END IF;
    -- H3 pending 的采购单在里面,而它【挡】关闭
    SELECT count(*) INTO v_n FROM approval_pending_documents()
     WHERE subject_type='purchase_order' AND blocks_disable;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 204H3 失败:pending 的采购单应当在途且挡住关闭,实得 %', v_n; END IF;

    -- ══════════════════════ I ★★ 屏幕与闸读同一份判据 ══════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_adm), true);
    v_read := approvals_readiness();
    SELECT count(*)::integer INTO v_gate FROM approval_pending_documents() WHERE blocks_disable;
    IF (v_read->>'pending_blocking_disable')::int <> v_gate THEN
        RAISE EXCEPTION 'FIXTURE 204I 失败:屏幕说 %,闸数出 % —— 两个数必须出自同一支函数',
            v_read->>'pending_blocking_disable', v_gate; END IF;
    -- ★ can_disable 跟着【窄】的那个数走,不跟着逐链那个更大的数走。
    IF (v_read->>'can_disable')::boolean <> (v_gate = 0) THEN
        RAISE EXCEPTION 'FIXTURE 204I 失败:can_disable=% 而会挡关闭的在途张数=%', v_read->>'can_disable', v_gate; END IF;
    -- ★ 逐链那一块【要真的有东西】—— 空数组会让上面两条都通过
    IF jsonb_array_length(COALESCE(v_read->'pending_by_chain','[]'::jsonb)) < 2 THEN
        RAISE EXCEPTION 'FIXTURE 204I 失败:逐链在途那一块应当至少两条链(报销与采购单),实得 %',
            jsonb_array_length(COALESCE(v_read->'pending_by_chain','[]'::jsonb)); END IF;

    -- ══════════════════════ J ★★★ APPROVALS_POLICY_WOULD_STRAND ══════════════════════
    -- J1 把二级换成一个【没有人持有报销那条链的门】的角色 —— 而在途有一张
    --    恰好 1000.00 的报销单,它就在二级那一档上。
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx204-l2b','f','f',true) RETURNING id INTO r_l2b;
    -- 它看得见金额(否则会先撞上 R4 那道闸,而那会让 J1 为【错的理由】变红),
    -- 也进得了采购模块(否则采购那条链先红),★ 但它【不持 module.finance.view】。
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_l2b, 'data.view_prices'), (r_l2b, 'data.view_purchase_prices'), (r_l2b, 'module.purchasing.view');
    -- ★★★【这个角色必须由一个【只持它】的人持有,而这一格本刀自己先踩了一次】★★★
    --   第一版把 fx204-l2b 授给了 u_l2 —— 而他已经持着 fx204-l2(带 module.finance.view)。
    --   **求交是按【人】算的,不是按角色算的:一个人的权限是他所有角色的并集。**
    --   于是他经由旧角色拿到了那个门,交集非空,WOULD_STRAND 根本不开火,
    --   J1 静静地变成空转。
    --   ☞ 这与 APR-2 §6⑤ 在 fixture 203 的 H1 上犯的是【同一个错】,
    --     隔了一刀又犯了一次 —— 所以这一段写在这里,不写在交回报告里。
    INSERT INTO user_roles (user_id, role_id) VALUES (u_l2b, r_l2b);
    -- ★ 而它【真的只持那一个角色】,这一句把上面那段话变成一条断言:
    SELECT count(*) INTO v_n FROM user_roles WHERE user_id = u_l2b AND revoked_at IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 204J1 布景失败:那个二级持有人持了 % 个角色 —— 多一个就可能经由它拿到那个门,而这一臂会静静空转', v_n; END IF;
    -- ★★【把上一臂留下的报错清掉】v_msg 是复用的变量。不清它,一次"根本没报错"
    --   会在失败消息里印出【上一臂】的那句拒绝 —— 一条"拒了"的读数,拒的是另一件事。
    v_msg := NULL;
    v_denied := false;
    BEGIN
        PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
        UPDATE finance_settings SET approval_level2_role_code = 'fx204-l2b';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'APPROVALS_POLICY_WOULD_STRAND|FX204-C-HI|2|fx204-l2b|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 204J1 失败:一次会把在途单据推到"没有人批得动"那一档的策略编辑应当按名拒并点出那张单,实得 %', COALESCE(v_msg,'(没有报错)'); END IF;

    -- J2 ★★ 一次【无害的】策略编辑 —— 必须放行。
    -- 【少了这一臂,一个"策略一律不许改"的实现会全绿】而那正是 Tim 的 N8
    --   裁定要排除的东西:最需要改策略的时刻,正是某条链配错了的时刻。
    -- 把门槛抬到 2000:那张 1000.00 的单从二级落到一级,而一级有人批得动。
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_threshold_base = 2000;
    SELECT approval_threshold_base INTO v_amt FROM finance_settings;
    IF v_amt <> 2000 THEN
        RAISE EXCEPTION 'FIXTURE 204J2 失败:★ 一次无害的策略编辑被拦住了 —— 拒绝要给出路,不是给一堵墙(实得门槛 %)', v_amt; END IF;

    RAISE NOTICE 'FIXTURE 204 全部通过:报销单四格逐格走通(Q/R/S/T,★ 读策略那一支用真身份两头读)· 分档恰好在门槛上分开且真的拦人(D)· 名册里报销那两行的门是 view+prices 而不是 edit(E)· raiser 与 subject 两条腿各自按名拒、第三个人批得动(A/B/C)· 盘点四眼且留痕层级为 NULL(F)· 工单关着时写 approved 不写 auto_approved(G)· 在途三条边界:报销在且不挡关闭、open 的盘点不在、采购单在且挡关闭(H)· 屏幕与闸读同一份判据(I)· 会搁死单据的策略编辑按名拒、无害的放行(J1/J2)';
END $$;
ROLLBACK;
