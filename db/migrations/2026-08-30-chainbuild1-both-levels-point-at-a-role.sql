-- db/migrations/2026-08-30-chainbuild1-both-levels-point-at-a-role.sql
-- CHAIN-BUILD-1:审批链两级【都指向角色】,而"谁算一个审批人"只剩【一个】定义。
--
-- ★★【本刀【只建能力,不做配置】】★★ 审批开关仍然是关的,链仍然【没有配】——
--   没有设任何角色、任何用户、任何门槛。本刀之后,链是【配得起来】的,不是【配好了】。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★【一、本刀顺手修掉的一个缺陷 —— 它比 R3 更早、更安静,单独记】★★★
--
--   **持有人判据【把已经撤销的授权也算成持有人】。**
--   `user_roles` 有 `revoked_at`,而 `user_directory` 视图是滤掉它的;
--   `guard_approvals_switch` 与 `approvals_readiness` **两处都没有滤**。
--
--   实测(2026-08-30,线上 15 条授权里 **5 条是 revoked**):
--
--       角色      | 今天算出来 | 只加 revoked 过滤 | 再加 R3(能不能登录)
--       ----------|-----------|------------------|--------------------
--       admin     |     6     |        1         |         1
--       finance   |     1     |        1         |         0
--
--   也就是说:**一个把授权【全部撤销掉】的角色,今天照样能通过零持有人那道闸**,
--   审批可以据此被打开 —— 打开之后没有一个人批得了。
--   这与 R3 是【两件事】:撤销是"这份授权已经不作数了",登录能力是"这个人够不着系统"。
--   四条判据里 **第 ① 条是这个缺陷的修复,第 ②③④ 条才是 R3**,下面逐条标了。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★【二、本刀最重要的后果,写在最前面,免得后来的人把它读成 bug】★★★
--
--   改完之后,**全系统只剩一个账号算得上审批人**(admin@swm-os.test)。
--   于是:**把任何一级指向 admin 以外的角色,开关都会按名拒。**
--
--   **那是这道控制在【正常工作】,不是它坏了。** 真相就是"今天没有人批得了",
--   而此前的判据把这句真话藏了起来 —— 它数的是"有没有一行账号记录",
--   不是"这个人来得了吗"。
--
--   **不要为了让它今天能打开而放松判据、加旁路、或加一个 override。**
--   到期条件写在 docs/approvals.md:**第二个账号被确认之后**。
--   语气与"匿名化函数永久拒绝"那一条相同 —— 那也是一条【按裁定拒绝】的路,
--   而没有那条注记,后来的人会把它当成没做完的活去"修"。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【三、Tim 的裁定,本刀实现的是它们的后果,不是它们本身】
--   R1 两级都指向角色(level 2 从此收角色码,不再收 user_id)
--   R2 **没有代理人、没有升级、没有破窗**:某一级的人不在,那一级的单据就停着。
--      加第二个审批人是【分工】,不是【互为代理】—— 互为代理会让金额门槛失去意义。
--   R3 持有人判据改成【真的登录得了】,而不是【有一行账号记录】。
--   R4 审批的人必须【看得见金额】。
--   R5 docs/approvals-scoping.md 里"二级指向具名用户、不建 cfo 角色"那条决定
--      **被推翻**:它的理由(指名一个人才能逼出代理机制)已经作废,因为代理被否决了。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1 · real_role_holders —— ★【"谁算一个真的持有人"从此只有这一个定义】★
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【为什么返回【集合】而不是一个计数】(这是对 3b 的一处加强,理由写在这里)
--   同一个判据要回答【两个】问题:
--     · 「这个角色有几个持有人」—— 开关那道闸与就绪面板要的
--     · 「这个人算不算持有人」  —— require_approver_for 授权时要的
--   写成计数函数,第二个问题就只能【另写一份】判据 —— 而那正是本刀要消灭的东西。
--   返回集合,两个问题都由这一份定义回答:count(*) 与 EXISTS。
--
--   ★ 授权那一侧此前也【没有】滤 revoked_at ★ —— 也就是说一份【已经撤销】的授权
--   照样批得了单。集合化把那条路一并收进同一个定义里。
--
-- 【四条判据,逐条说明它是哪一条规矩来的】
--   ① ur.revoked_at IS NULL      —— ★缺陷修复★,不是 R3。授权被撤销了就不算数。
--   ② u.confirmed_at IS NOT NULL —— R3。confirmed_at 是【生成列】:
--                                   LEAST(email_confirmed_at, phone_confirmed_at),
--                                   所以它同时覆盖邮箱与手机确认,比只看 email 更准。
--   ③ 未被封禁                    —— R3。
--   ④ 未被删除                    —— R3。
--
-- 【关于第 ③ 条,两件必须写下来的实况,免得下一个人误判它的分量】
--   · **它在今天的数据上【不是】起作用的那一条**:线上五个 test.local 账号确实被封,
--     但它们的授权【也已经撤销】,第 ① 条就已经把它们排除了。
--   · **`banned_until` 在本仓库里别处一次都没有出现过**(db/ app/ lib/ scripts/ 全搜过)
--     —— 那几个封禁是在仓库之外做的。所以这一条引入了一个本仓库原本不建模的概念,
--     保留它是因为 R3 的原话是"真的登录得了",而被封的账号登录不了 —— 与理由无关。
--
-- 【它【不】判什么】角色被软删(roles.deleted_at)这一条没有加进来:
--   本刀沿用既有判据里的 r.is_active,不多不少。实测线上软删角色 **0 个**,
--   所以今天两者等价;真出现"软删了但仍 is_active"的角色时,这里会多算 ——
--   **报告出来,不顺手改**,因为那是另一条规矩(角色软删该不该连带停用)。
CREATE OR REPLACE FUNCTION public.real_role_holders(p_role_code text)
 RETURNS TABLE(user_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT ur.user_id
      FROM user_roles ur
      JOIN roles r      ON r.id = ur.role_id
      JOIN auth.users u ON u.id = ur.user_id
     WHERE r.code = p_role_code
       AND r.is_active
       AND ur.revoked_at IS NULL                                    -- ① 缺陷修复
       AND u.confirmed_at IS NOT NULL                               -- ② R3
       AND (u.banned_until IS NULL OR u.banned_until < now())       -- ③ R3
       AND u.deleted_at IS NULL;                                    -- ④ R3
$function$;

COMMENT ON FUNCTION public.real_role_holders(text) IS
'CHAIN-BUILD-1:★「谁算一个真的持有人」的【唯一】定义★ —— 开关那道闸、就绪面板、以及授权检查,三处读的都是它。返回【集合】而不是计数,是因为同一份判据要回答两个问题(有几个 / 这个人算不算),写成计数就会逼出第二份判据。四条:① 授权未撤销(**这一条是缺陷修复**:此前三处都没滤 revoked_at,于是一个把授权全撤销掉的角色照样能通过零持有人那道闸;实测线上 15 条授权里 5 条是 revoked,admin 因此虚报 6 个持有人);②③④ 是 R3(账号已确认 / 未封禁 / 未删除),把"有一行账号记录"换成"真的登录得了"。confirmed_at 是生成列 LEAST(email_confirmed_at, phone_confirmed_at),故同时覆盖邮箱与手机。**banned_until 在今天的数据上不是起作用的那一条**(那五个被封账号的授权也已撤销),而且它在本仓库别处一次都没出现过 —— 保留它只因为 R3 的原话是"真的登录得了"。';

-- ════════════════════════════════════════════════════════════════════════════
-- 2 · role_can_see_amounts —— R4 在【角色】这一侧的判据
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么单独一支而不是内联】开关那道闸与就绪面板两处都要问同一句话,
-- 内联就是两份。与上面那支同一条理由。
CREATE OR REPLACE FUNCTION public.role_can_see_amounts(p_role_code text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM roles r
          JOIN role_permissions rp ON rp.role_id = r.id
         WHERE r.code = p_role_code
           AND r.is_active
           AND rp.permission_code = 'data.view_prices');
$function$;

COMMENT ON FUNCTION public.role_can_see_amounts(text) IS
'CHAIN-BUILD-1(R4):这个角色看得见金额吗 —— 即它有没有 data.view_prices。采购单的金额在 purchase_orders_masked / purchase_order_lines_masked 上是遮蔽列,而审批【按金额选级别】,所以一个看不见金额的角色批的是自己看不见的数字。开关时用它按名拒(策略层面,可全知);批准时另有一道问【这个人】的检查(个体层面,权限是多角色的并集)—— 两者问的不是同一件事,不是重复。';

-- ════════════════════════════════════════════════════════════════════════════
-- 3 · DDL:二级从 user_id 换成 role_code
-- ════════════════════════════════════════════════════════════════════════════
-- 【形状逐字照抄一级】一级是 text + REFERENCES roles(code)(实测:
-- finance_settings_approval_level1_role_code_fkey)。两级必须同形,否则
-- "二级的角色码"会长成与一级不一样的东西,而下一个读的人得先分辨它们哪里不同。
ALTER TABLE public.finance_settings
    ADD COLUMN approval_level2_role_code text REFERENCES public.roles (code);

COMMENT ON COLUMN public.finance_settings.approval_level2_role_code IS
'CHAIN-BUILD-1(R1):二级审批【角色】码。★它取代了 approval_level2_user_id★ —— 两列各能指定一个审批人,就是"谁可以批"的两份定义,而那是本仓库最老的漂移形状。旧列在线上是 NULL,所以本刀直接退役它,不留兼容期。**没有代理人、没有升级**(R2):这一级的人不在,这一级的单据就停着,那是裁定过的,不是漏掉的。';

COMMENT ON COLUMN public.finance_settings.approval_level1_role_code IS
'一级审批【角色】码。★【没有代理人、没有升级、没有破窗 —— 这是一条裁定,不是一处遗漏】★(R2,CHAIN-BUILD-1 2026-08-30):某一级的持有人不在,这一级的单据就【停着】,而且系统会把这件事【说出来】(就绪面板的三种状态),但**绝不绕过去**。互为代理被考虑过并否决了 —— 两个互为代理的人会让金额门槛失去意义。加第二个审批人是【分工】,不是【互为代理】。理由与写法见 docs/approvals.md。';

-- 【退役,而不是两列并存】旧列在线上是 NULL(实测),所以没有任何东西会丢。
-- 读它的六处全部在本刀里改写:require_approver_for / guard_approvals_switch /
-- approvals_readiness / ApprovalsPanel.tsx / lib/database.types.ts / fixtures 127,35,52。
ALTER TABLE public.finance_settings DROP COLUMN approval_level2_user_id;

-- ════════════════════════════════════════════════════════════════════════════
-- 4 · require_approver_for —— 两级都按【角色成员资格】授权
-- ════════════════════════════════════════════════════════════════════════════
-- 【两级现在是同一段逻辑,只是读不同的那一列】—— 这本身就是 R1 的意思:
-- 二级不再是"你是不是那一个人",而是"你在不在那个角色里"。
-- 拒绝码仍然点名级别与角色,因为读到它的人要知道【是哪一级卡住了】。
CREATE OR REPLACE FUNCTION public.require_approver_for(p_level smallint)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_role text;
BEGIN
    IF p_level = 1 THEN
        SELECT approval_level1_role_code INTO v_role FROM finance_settings LIMIT 1;
        IF v_role IS NULL THEN
            RAISE EXCEPTION 'APPROVAL_LEVEL1_ROLE_NOT_SET';
        END IF;
    ELSIF p_level = 2 THEN
        SELECT approval_level2_role_code INTO v_role FROM finance_settings LIMIT 1;
        IF v_role IS NULL THEN
            RAISE EXCEPTION 'APPROVAL_LEVEL2_ROLE_NOT_SET';
        END IF;
    ELSE
        RAISE EXCEPTION 'APPROVAL_LEVEL_INVALID|%', p_level;
    END IF;

    -- ★ 与"有几个持有人"读同一份定义 —— 于是【一份撤销掉的授权批不了单】,
    --   而这一条此前是漏的(见本文件抬头的缺陷段)。
    IF NOT EXISTS (SELECT 1 FROM real_role_holders(v_role) h WHERE h.user_id = auth.uid()) THEN
        RAISE EXCEPTION 'APPROVAL_NOT_AUTHORISED|%|%', p_level, v_role;
    END IF;
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 5 · guard_approvals_switch —— 两级同等对待,外加 R4 的金额可见性
-- ════════════════════════════════════════════════════════════════════════════
-- 【开的那一侧,三类拒绝,都在开关翻过去的【那一刻】判 —— 那时状态是全知的,
--   而后果是全体的(每一张单都会卡)。所以是【拒绝】,不是【告警】。】
--   ① 策略没配齐
--   ② 某一级没有【真的】持有人 —— 而"一个都没有"与"有人但登录不了"
--      **必须是两条不同的拒绝**:后者若报成"没有持有人",操作的人会去再授一次权,
--      而那个角色【已经授过了】,再授一次不会有任何变化(3c 的中间态)。
--   ③ 某一级的角色看不见金额(R4/4b)
CREATE OR REPLACE FUNCTION public.guard_approvals_switch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_missing text[] := '{}';
    v_pending integer;
    v_codes   text;
    v_lvl     integer;
    v_role    text;
    v_total   integer;
    v_real    integer;
BEGIN
    -- ── 开:策略必须齐,两级都必须【有人批】而且【看得见金额】 ──
    IF NEW.approvals_enabled AND NOT OLD.approvals_enabled THEN
        IF NEW.approval_level1_role_code IS NULL THEN
            v_missing := v_missing || 'approval_level1_role_code'::text;
        END IF;
        IF NEW.approval_threshold_base IS NULL THEN
            v_missing := v_missing || 'approval_threshold_base'::text;
        END IF;
        IF NEW.approval_level2_role_code IS NULL THEN
            v_missing := v_missing || 'approval_level2_role_code'::text;
        END IF;
        IF cardinality(v_missing) > 0 THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_INCOMPLETE|%', array_to_string(v_missing, ', ');
        END IF;

        -- 两级走【同一段】判断 —— 两级不同形正是上一版留下的问题。
        FOR v_lvl IN 1..2 LOOP
            v_role := CASE v_lvl WHEN 1 THEN NEW.approval_level1_role_code
                                 ELSE NEW.approval_level2_role_code END;

            SELECT count(*) INTO v_real FROM real_role_holders(v_role);

            IF v_real = 0 THEN
                -- 【分辨两种零】总数是从 user_roles 上数的(未撤销的授权),
                -- 与 real 的差,正好就是"有人持有,但他登录不了"。
                SELECT count(*) INTO v_total
                  FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                 WHERE r.code = v_role AND r.is_active AND ur.revoked_at IS NULL;

                IF v_total > 0 THEN
                    -- ★ 3c 的中间态:角色【有人】,但那个人【登录不了】。
                    --   报成"没有持有人"会把人送去再授一次权,而那不会改变任何事。
                    RAISE EXCEPTION 'APPROVALS_LEVEL%_HOLDER_CANNOT_SIGN_IN|%|%', v_lvl, v_role, v_total;
                ELSE
                    RAISE EXCEPTION 'APPROVALS_LEVEL%_ROLE_UNHELD|%', v_lvl, v_role;
                END IF;
            END IF;

            -- R4/4b:看不见金额的角色批不了它该批的东西 —— 同一时刻、同一理由。
            IF NOT role_can_see_amounts(v_role) THEN
                RAISE EXCEPTION 'APPROVALS_LEVEL%_ROLE_CANNOT_SEE_AMOUNTS|%', v_lvl, v_role;
            END IF;
        END LOOP;
    END IF;

    -- ── 关:在途的 pending 单会被永远搁死,所以先点名(原样保留)──
    IF OLD.approvals_enabled AND NOT NEW.approvals_enabled THEN
        SELECT count(*), string_agg(code, ', ' ORDER BY code)
          INTO v_pending, v_codes
          FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL;
        IF COALESCE(v_pending, 0) > 0 THEN
            RAISE EXCEPTION 'APPROVALS_CANNOT_DISABLE_WITH_PENDING|%|%', v_pending, v_codes;
        END IF;
    END IF;

    -- ── 开着的时候不许把策略值抽走 ──
    IF NEW.approvals_enabled THEN
        IF NEW.approval_level1_role_code IS NULL AND OLD.approval_level1_role_code IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_level1_role_code';
        END IF;
        IF NEW.approval_threshold_base IS NULL AND OLD.approval_threshold_base IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_threshold_base';
        END IF;
        IF NEW.approval_level2_role_code IS NULL AND OLD.approval_level2_role_code IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_level2_role_code';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 6 · approvals_readiness —— 每一级【两个计数】,三种状态由它们的关系推出来
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么是两个数,不是一个数加一个布尔】(3c / A6)
--   要分开的三种状态是:没人持有 / 有人持有但登录不了 / 有能干活的人。
--   一个计数加一个布尔说不清那个布尔在修饰谁;
--   两个数(holders_total / real_holders)让中间态是一次【测量】,
--   而不是一个要靠人维护同步的标记。
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
    v_l1_norais  integer := 0;
    v_l1_sees    boolean := false;
    v_l2_sees    boolean := false;
    v_pending    integer := 0;
BEGIN
    PERFORM require_permission('module.finance.view');

    SELECT approvals_enabled, approval_level1_role_code, approval_threshold_base,
           approval_level2_role_code
      INTO v_s FROM finance_settings LIMIT 1;

    -- ── 一级 ──
    IF v_s.approval_level1_role_code IS NULL THEN
        v_blocking := v_blocking || 'approval_level1_role_code'::text;
    ELSE
        SELECT count(*) INTO v_l1_real FROM real_role_holders(v_s.approval_level1_role_code);
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

    SELECT count(*) INTO v_pending
      FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL;

    RETURN jsonb_build_object(
        'enabled',                 v_s.approvals_enabled,
        'level1_role_code',        v_s.approval_level1_role_code,
        'level1_holders_total',    v_l1_total,
        'level1_real_holders',     v_l1_real,
        'level1_can_see_amounts',  v_l1_sees,
        'level1_holders_who_cannot_raise', v_l1_norais,
        'threshold_base',          v_s.approval_threshold_base,
        'level2_role_code',        v_s.approval_level2_role_code,
        'level2_holders_total',    v_l2_total,
        'level2_real_holders',     v_l2_real,
        'level2_can_see_amounts',  v_l2_sees,
        'pending_purchase_orders', v_pending,
        'blocking',                to_jsonb(v_blocking),
        'can_enable',              (NOT v_s.approvals_enabled AND cardinality(v_blocking) = 0),
        'can_disable',             (v_s.approvals_enabled AND v_pending = 0),
        -- 跟着数字走的那句话,不只躺在文档里(与 PARTY-1 的处置同形)
        'no_deputy_by_decision',   true);
END;
$function$;

COMMENT ON FUNCTION public.approvals_readiness() IS
'SOD-1,CHAIN-BUILD-1 改写(2026-08-30):审批开关能不能开,以及开不了缺哪几样 —— 屏幕与闸读同一份判据。★两级【同等对待】★:各返回 holders_total(未撤销的授权数)与 real_holders(真的登录得了的),**两个数而不是一个数加一个布尔**,因为要分开的是三种状态:没人持有 / 有人持有但登录不了 / 有能干活的人 —— 中间那一种若报成"没有持有人",操作的人会去再授一次权,而那个角色已经授过了。持有人判据只有一处定义(real_role_holders)。另报每一级的 can_see_amounts(R4)。**没有代理人、没有升级**:某一级没人就停在那一级,这是裁定,不是遗漏(no_deputy_by_decision 跟着返回值走)。';

-- ════════════════════════════════════════════════════════════════════════════
-- 7 · approve_purchase_order —— R4 在【个人】这一侧的判据
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.approve_purchase_order(p_po_id uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po    record;
    v_base  numeric;
    v_level smallint;
BEGIN
    PERFORM require_permission('module.purchasing.view');
    -- ★★【R4:批的人必须看得见他批的那个数】★★(CHAIN-BUILD-1,2026-08-30)
    --   本函数按【金额】选级别(approval_level_for),而金额在 purchase_orders_masked /
    --   purchase_order_lines_masked 上是遮蔽列,门是 data.view_prices。
    --   于是一个只持 module.purchasing.view 的人可以【打开单据、按下批准】,
    --   而屏幕上那一格写着「受限」—— 他批的是一个自己看不见的数字。
    --
    --   【为什么是"要这个权限",不是"在审批路径上解遮蔽"】(4a 的两条路,选了前者)
    --   解遮蔽会开出【第二条看价格的路】,绕过 _masked 那一套 —— 而那一套自己带着
    --   gate 的 colgrant / colreader 两条判词。多一条路 = 多一份定义,正是本仓库
    --   反复付账的那个形状。这里不发明新权限码,只是要求一个【已经存在】的。
    --
    --   【它与开关那道闸不重复,两者问的不是同一件事】
    --     · 开关时问:这个【角色】看得见金额吗(策略层面,可全知,后果是全体)
    --     · 批准时问:这个【人】看得见金额吗(个体层面,权限是多角色的并集)
    --   与 AGENTS.md「决定期间的值:控件禁用 + 服务端独立拒绝」是同一个两道闸的形状。
    PERFORM require_permission('data.view_prices');
    -- APR-2c:审批未生效时,"批准"是一个没有意义的动作 —— 单据本来就已经是 approved。
    -- 点名拒绝,而不是默默成功:后者会让人以为审批流在跑。
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    SELECT id, code, created_by, approval_status, status, currency, fx_rate, estimated_total_ccy
    INTO v_po FROM purchase_orders WHERE id = p_po_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_po_id::text, '?');
    END IF;
    IF v_po.approval_status <> 'pending' THEN
        RAISE EXCEPTION 'PO_NOT_PENDING|%|%', v_po.code, v_po.approval_status;
    END IF;

    -- 【四眼】提单的人不能自己批。与 approve_review 的 SELF_APPROVAL_FORBIDDEN 同名同理。
    IF v_po.created_by IS NOT NULL AND v_po.created_by = auth.uid() THEN
        RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN';
    END IF;

    -- 【本位币比,用单据自己存的汇率】(决定 3)。FIN-35 删掉了 fx_rate 的默认值,
    -- 所以一张外币单要么带着真汇率,要么根本不存在 —— 这里不必再防平价。
    v_base  := round(v_po.estimated_total_ccy * v_po.fx_rate, 2);
    v_level := approval_level_for(v_base);
    PERFORM require_approver_for(v_level);

    -- PUR-2:告诉 guard_po_amendable 这是一次【状态转换】,不是一次修改。
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法:显式声明,
    -- 而不是让守卫去猜调用方是谁。
    -- 【用完立刻清掉 —— 这一句是 fu2 的全部内容】set_config(..., true) 是
    -- 【事务】局部,不是语句局部。只在函数开头设一次,守卫就会在这次调用之后、
    -- 整个事务余下的时间里【一直是关着的】:跑过一次 close_purchase_order 之后,
    -- 同一事务里一条直连的 UPDATE ... SET status 就畅通无阻(实测过)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders
    SET approval_status = 'approved',
        approved_at = now(),
        approved_by = auth.uid(),
        -- 批准把单据从 draft 推到 confirmed;advance_po_on_receipt 仍按 confirmed 走
        status = CASE WHEN status = 'draft' THEN 'confirmed' ELSE status END,
        updated_by = auth.uid()
    WHERE id = p_po_id;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);


    PERFORM record_approval_decision('purchase_order', p_po_id, 'approved', v_level, p_note);

    RETURN jsonb_build_object('purchase_order_id', p_po_id, 'code', v_po.code,
                              'level', v_level, 'amount_base', v_base);
END;
$function$;

COMMIT;
