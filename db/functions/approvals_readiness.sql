-- db/functions/approvals_readiness.sql
-- SOD-1:审批开关【能不能开】,以及开不了的话缺哪几样 —— 屏幕与闸读同一份判据。
-- 一个屏幕上说"可以开"、闸却拒绝的系统,比两者都拒绝更坏(fixture 127 C8 钉这一条)。
--
-- 【数的是【真的登录得了的】持有人】线上有 66 条 user_roles 的 user_id 在
-- auth.users 里根本不存在(docs/known-issues.md 的 ACCOUNTS-STALE 条)。
-- 一个只由幽灵持有的角色,是一个永远不会有人来批的队列。
--
-- 【它答不了的那一件,不假装答得了】"是否存在第二个真人",本函数【不判】——
-- 线上五个 test.local 走查账号都持 admin,任何按账号数的判据都会因为它们而通过,
-- 也就是为了错的理由通过。那一条留在 docs/fresh-install-checklist.md 里由人判断。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql;
-- 内检的权限码由 db/migrations/2026-09-22-apr1-the-approvals-switch-gets-a-door.sql
-- 从 module.finance.view 换成 action.manage_permissions(APR-0 的 N6)。
--
-- 【fu2:一个【非阻塞】的忠告字段 level1_holders_who_cannot_raise】
-- 独立复测量到:`finance` 角色自己就持 module.purchasing.edit,于是被裁定的
-- 一级审批角色里,"结构上提不了单"的持有人是 **0** 个。
-- **它报告,不拦** —— 做成拒绝会让 Tim 自己裁定的策略开不起来,
-- 而一道拦住既定决定的闸是一道会被绕过去的闸。留给 Tim 的三选一写在
-- db/migrations/2026-08-24-sod1-fu2-*.sql 的抬头。
--
-- 【fu2 同时补上了调用者检查】gate 的 B2 抓到它是 SECURITY DEFINER 且无检查而可调用。
-- 它【要】被 /finance/settings 调用,所以走的是"加检查"这一半,不是"收权限"那一半
-- (另外三支内层函数走的是后者,见 db/views/zzz_function_grants.sql)。

CREATE OR REPLACE FUNCTION public.approvals_readiness()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s          record;
    v_blocking   text[] := '{}';
    v_l1_total   integer := 0;  v_l1_real integer := 0;
    v_l2_total   integer := 0;  v_l2_real integer := 0;
    -- APR-ROUTE-1 Batch B(Tim 的 Q3):每一级的【人】数,与账号数并排
    v_l1_people  integer := 0;  v_l2_people integer := 0;
    v_l1_norais  integer := 0;
    v_l1_sees    boolean := false;
    v_l2_sees    boolean := false;
    v_pending    integer := 0;
    v_blocking_p integer := 0;
    v_pendchains jsonb   := '[]'::jsonb;
    v_chains     jsonb   := '[]'::jsonb;
    v_deadchains integer := 0;
    v_owngaps    jsonb   := '[]'::jsonb;
BEGIN
    -- ★ APR-1(N6):此前这里要求 module.finance.view,而 /settings/approvals
    --   那一页的闸是 action.manage_permissions —— **两个码守同一块屏幕**。
    --   今天 admin 与 cco 两个码都持有,所以看不出问题;哪一天有人持前者而不持
    --   后者,那一页会渲染成 readError,而那读起来像"读不到",不像"你没权限"。
    --   这支函数的抬头自己就写着"屏幕与闸读同一份判据"。
    PERFORM require_permission('action.manage_permissions');

    SELECT approvals_enabled, approval_level1_role_code, approval_threshold_base,
           approval_level2_role_code
      INTO v_s FROM finance_settings LIMIT 1;

    -- ── 一级 ──
    IF v_s.approval_level1_role_code IS NULL THEN
        v_blocking := v_blocking || 'approval_level1_role_code'::text;
    ELSE
        SELECT count(*) INTO v_l1_real FROM real_role_holders(v_s.approval_level1_role_code);
        -- ★ Batch B(Q3):同一个人的两个账号只算一个人 —— 经 account_person 认人。
        SELECT count(DISTINCT COALESCE(account_person(h.user_id)::text, 'account:' || h.user_id::text))
          INTO v_l1_people FROM real_role_holders(v_s.approval_level1_role_code) h;
        SELECT count(*) INTO v_l1_total
          FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE r.code = v_s.approval_level1_role_code AND r.is_active AND ur.revoked_at IS NULL;
        v_l1_sees := role_can_see_amounts(v_s.approval_level1_role_code);

        IF v_l1_real = 0 AND v_l1_total > 0 THEN
            v_blocking := v_blocking || 'approval_level1_holder_cannot_sign_in'::text;
        ELSIF v_l1_real = 0 THEN
            v_blocking := v_blocking || 'approval_level1_role_has_no_real_holder'::text;
        END IF;
        IF NOT v_l1_sees THEN
            v_blocking := v_blocking || 'approval_level1_role_cannot_see_amounts'::text;
        END IF;

        -- 【报告,不拦】这个角色的持有人里,有几个是【提不了采购单】的(SOD-1 fu2)。
        SELECT count(*) INTO v_l1_norais
          FROM real_role_holders(v_s.approval_level1_role_code) h
         WHERE NOT EXISTS (
            SELECT 1 FROM user_roles ur2
              JOIN roles r2 ON r2.id = ur2.role_id
              JOIN role_permissions rp ON rp.role_id = r2.id
             WHERE ur2.user_id = h.user_id AND r2.is_active AND ur2.revoked_at IS NULL
               AND rp.permission_code = 'module.purchasing.edit');
    END IF;

    IF v_s.approval_threshold_base IS NULL THEN
        v_blocking := v_blocking || 'approval_threshold_base'::text;
    END IF;

    -- ── 二级:与一级【同等对待】,这正是本刀要的 ──
    IF v_s.approval_level2_role_code IS NULL THEN
        v_blocking := v_blocking || 'approval_level2_role_code'::text;
    ELSE
        SELECT count(*) INTO v_l2_real FROM real_role_holders(v_s.approval_level2_role_code);
        SELECT count(DISTINCT COALESCE(account_person(h.user_id)::text, 'account:' || h.user_id::text))
          INTO v_l2_people FROM real_role_holders(v_s.approval_level2_role_code) h;
        SELECT count(*) INTO v_l2_total
          FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE r.code = v_s.approval_level2_role_code AND r.is_active AND ur.revoked_at IS NULL;
        v_l2_sees := role_can_see_amounts(v_s.approval_level2_role_code);

        IF v_l2_real = 0 AND v_l2_total > 0 THEN
            v_blocking := v_blocking || 'approval_level2_holder_cannot_sign_in'::text;
        ELSIF v_l2_real = 0 THEN
            v_blocking := v_blocking || 'approval_level2_role_has_no_real_holder'::text;
        END IF;
        IF NOT v_l2_sees THEN
            v_blocking := v_blocking || 'approval_level2_role_cannot_see_amounts'::text;
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★ APR-3(Tim 的 Q6):在途张数放宽到【每一条接上引擎的链】,
    --    而 can_disable 仍然只看【关掉之后会批不动的那些】 ★★
    -- ════════════════════════════════════════════════════════════════════════
    -- 两个数长得一样,问的不是同一件事,所以它们是两个字段 ——
    -- 而【两个都出自同一支函数】(approval_pending_documents),于是屏幕与闸
    -- 不可能各读一份判据。那一句判别写在那个函数的抬头,下一刀照它回答一次:
    --   **这条链的决定函数,在审批关着的时候还跑不跑得动?**
    --
    -- ★【为什么不把 can_disable 一起放宽】线上今天有一张 submitted 的报销单,
    --   而报销在审批关着时照常批得了 —— 把它算进去会让审批从此【关不掉】,
    --   一个没有人要求过的新约束,而且它看起来会像一个 bug。
    --
    -- ⚠【pending_purchase_orders 这个字段名保留】它喂的是屏幕上那一句
    --   「关掉会怎样」,而那句话说的正是采购单。改名要连着文案一起改,
    --   而本刀没有理由动它 —— 它今天仍然逐字等于 blocks_disable 的那个数,
    --   因为今天只有采购单 blocks_disable。
    SELECT count(*) FILTER (WHERE d.subject_type = 'purchase_order'),
           count(*) FILTER (WHERE d.blocks_disable)
      INTO v_pending, v_blocking_p
      FROM approval_pending_documents() d;

    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'subject_type'), '[]'::jsonb)
      INTO v_pendchains
      FROM (
        SELECT jsonb_build_object(
                   'subject_type',    d.subject_type,
                   'pending',         count(*),
                   'blocks_disable',  bool_or(d.blocks_disable),
                   -- 分不出档的那些单独报出来,不混进计数里读成零
                   'amount_unknown',  count(*) FILTER (WHERE d.amount_base IS NULL)) AS x
          FROM approval_pending_documents() d
         GROUP BY d.subject_type
      ) g;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★ APR-2:屏幕上也要看得见「这条链真的有人批得动吗」 ★★
    -- ════════════════════════════════════════════════════════════════════════
    -- 本函数的抬头写着"屏幕与闸读同一份判据"。APR-2 给 guard_approvals_switch
    -- 加了一道新闸(链的模块门 ∩ 那一级的角色持有人 = 空 → 按名拒),
    -- ★ 所以那道闸【必须】同时出现在这里 —— 否则就又是一块说"可以开"、
    --   而闸会拒绝的屏幕,也就是本函数存在的全部理由的反面。
    --
    -- ⚠ 这里【不】传参,读的是已经落库的那两个角色码 —— 面板说的是
    --   "以现在这条策略,能不能开"。闸那一侧传的是 NEW(它判的是正要写下去的
    --   那条策略),两者的差别写在 approval_gate_intersections 的抬头。
    -- ★★ 只在【两级角色都已经设好】时才问这个问题 —— 而这不是为了少说一句话,
    --    是为了与闸【同序】:guard_approvals_switch 先抛 APPROVALS_POLICY_INCOMPLETE,
    --    根本走不到这道新闸。策略整个没设时,role_code 是 NULL,求交必然全 0,
    --    于是 blocking 会多出第四条 —— 一句【真的、但重复的】话,
    --    它说的还是上面那三条已经说过的事,而它会把"策略没设"与
    --    "策略设好了却没有人批得动"这两种完全不同的状态搅在一起。
    IF v_s.approval_level1_role_code IS NOT NULL
       AND v_s.approval_level2_role_code IS NOT NULL THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'subject_type',     i.subject_type,
                   'action_function',  i.action_function,
                   'level',            i.level,
                   'role_code',        i.role_code,
                   'gate_permissions', to_jsonb(i.gate_permissions),
                   'approvers',        i.approvers)
                   ORDER BY i.subject_type, i.action_function, i.level), '[]'::jsonb),
               count(*) FILTER (WHERE i.approvers = 0)
          INTO v_chains, v_deadchains
          FROM approval_gate_intersections() i;

        IF v_deadchains > 0 THEN
            v_blocking := v_blocking || 'approval_chain_has_no_approver'::text;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- ★★ APR-ROUTE-1(Tim 的 R4 · Q10):【他自己的单,谁来批】—— 忠告,不拦 ★★
        -- ════════════════════════════════════════════════════════════════════
        -- 上面那一段问"这一级有没有任何人"。它答"有"的时候,那个人自己提的、
        -- 或者说的就是他自己的单据,仍然可以没有人批:提单人那条腿拦他,
        -- 而这一级只有他一个人(EMP-SELF-0 的 F2;线上 admin 的大额采购单正是这样)。
        -- 所以这里把每一个【批得动这一级的人】逐个代入成"提单人兼主角",
        -- 再问一次 approval_deciders:除了他自己,还有没有人?
        --   · 没有,而 R2 的例外也不覆盖他  → self_exception = false(他的单会搁死)
        --   · 没有,但 R2 的例外让他自己批  → self_exception = true(只能自批,并被标记)
        -- ★【为什么是忠告】(Tim 的 Q10)线上今天就有这样的格子,而把它做成拦
        --   会让一条 Tim 自己裁定的策略开不起来。★ 等独立 CFO 账号落地、二级有了
        --   第二个人,Tim 会再看一次要不要把它改成拦 —— docs/approvals.md 记着这句。
        -- 【判据只有一份】approval_deciders;这里只是换了一组参数去问它。
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'subject_type',    x.subject_type,
                   'action_function', x.action_function,
                   'level',           x.level,
                   'role_code',       x.role_code,
                   'user_id',         x.user_id,
                   'who',             x.who,
                   'self_exception',  x.self_only)
                   ORDER BY x.subject_type, x.action_function, x.level, x.who), '[]'::jsonb)
          INTO v_owngaps
          FROM (
            SELECT i.subject_type, i.action_function, i.level, i.role_code, p.user_id,
                   COALESCE(e.legal_name, u.email, p.user_id::text) AS who,
                   EXISTS (SELECT 1 FROM approval_deciders(i.subject_type, i.action_function, i.level,
                                             p.user_id, account_person(p.user_id),
                                             v_s.approval_level1_role_code, v_s.approval_level2_role_code) d
                            WHERE d.via_self_exception) AS self_only
              FROM approval_gate_intersections() i
              -- 每一个批得动这一级的【人】,取他的一个账号代入
              CROSS JOIN LATERAL (
                  SELECT DISTINCT ON (d0.person_key) d0.user_id
                    FROM approval_deciders(i.subject_type, i.action_function, i.level,
                                           NULL::uuid, NULL::uuid,
                                           v_s.approval_level1_role_code, v_s.approval_level2_role_code) d0
                   ORDER BY d0.person_key, d0.user_id) p
              LEFT JOIN auth.users u ON u.id = p.user_id
              LEFT JOIN employees e ON e.id = account_person(p.user_id)
             WHERE NOT EXISTS (
                     SELECT 1 FROM approval_deciders(i.subject_type, i.action_function, i.level,
                                        p.user_id, account_person(p.user_id),
                                        v_s.approval_level1_role_code, v_s.approval_level2_role_code) d
                      WHERE NOT d.via_self_exception)
          ) x;
    END IF;

    RETURN jsonb_build_object(
        'enabled',                 v_s.approvals_enabled,
        'level1_role_code',        v_s.approval_level1_role_code,
        'level1_holders_total',    v_l1_total,
        'level1_real_holders',     v_l1_real,
        -- ★ APR-ROUTE-1 Batch B(Q3):账号数与人数并排。独立 CFO 账号落地之后,
        --   二级会是【2 个账号、1 个人】—— 前者说"那个账号是真的",后者说"二级仍然只有一个人"。
        'level1_people',           v_l1_people,
        'level1_can_see_amounts',  v_l1_sees,
        'level1_holders_who_cannot_raise', v_l1_norais,
        'threshold_base',          v_s.approval_threshold_base,
        'level2_role_code',        v_s.approval_level2_role_code,
        'level2_holders_total',    v_l2_total,
        'level2_real_holders',     v_l2_real,
        'level2_people',           v_l2_people,
        'level2_can_see_amounts',  v_l2_sees,
        'pending_purchase_orders', v_pending,
        -- ★ APR-3:逐链的在途张数(屏幕用),与【会挡住关闭的】那个数(闸用)。
        --   两个都从 approval_pending_documents() 来 —— 一份判据,两个问题。
        'pending_by_chain',        v_pendchains,
        'pending_blocking_disable', v_blocking_p,
        -- ★ APR-2:逐条给出"这条链有几个人批得动",而不是一个布尔 ——
        --   与两级持有人给两个数、不给一个布尔是同一条理由:
        --   要分开的是"哪一条链死了、死在哪一级、缺的是哪个码"。
        'chain_gates',             v_chains,
        'chains_without_approver', v_deadchains,
        -- ★ APR-ROUTE-1(R4):一个人自己的单,除了他自己没有人批得动 —— 逐格点名。
        --   忠告,不进 blocking(Tim 的 Q10);own_document_gaps_block = false 跟着返回值走,
        --   与 no_deputy_by_decision 同形:一句只躺在文档里的"这是裁定"会被当成遗漏。
        'own_document_gaps',       v_owngaps,
        'own_document_gaps_block', false,
        'blocking',                to_jsonb(v_blocking),
        'can_enable',              (NOT v_s.approvals_enabled AND cardinality(v_blocking) = 0),
        -- ★ APR-3:判据换成【会被搁死的那些】,与 guard_approvals_switch 的
        --   关闭那一支逐字同源(它读的是同一支函数的同一个过滤条件)。
        'can_disable',             (v_s.approvals_enabled AND v_blocking_p = 0),
        -- 跟着数字走的那句话,不只躺在文档里(与 PARTY-1 的处置同形)
        'no_deputy_by_decision',   true);
END;
$function$;

COMMENT ON FUNCTION public.approvals_readiness() IS
'SOD-1,CHAIN-BUILD-1 改写(2026-08-30):审批开关能不能开,以及开不了缺哪几样 —— 屏幕与闸读同一份判据。★两级【同等对待】★:各返回 holders_total(未撤销的授权数)与 real_holders(真的登录得了的),**两个数而不是一个数加一个布尔**,因为要分开的是三种状态:没人持有 / 有人持有但登录不了 / 有能干活的人 —— 中间那一种若报成"没有持有人",操作的人会去再授一次权,而那个角色已经授过了。持有人判据只有一处定义(real_role_holders)。另报每一级的 can_see_amounts(R4)。**没有代理人、没有升级**:某一级没人就停在那一级,这是裁定,不是遗漏(no_deputy_by_decision 跟着返回值走)。';
