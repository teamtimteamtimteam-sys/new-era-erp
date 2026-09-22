-- db/functions/guard_approvals_switch.sql
-- SOD-1:审批开关的两道闸 —— 把"开着但没配"变成一个【到不了】的状态。
--
-- docs/approvals-scoping.md 记着三个状态,其中"on, policy unset → 拒绝路由"。
-- 那个状态会把在途单据搁死:create_purchase_order 照常生成 pending 的单,
-- 而 approve_purchase_order 撞上 APPROVAL_LEVEL1_ROLE_NOT_SET —— 批不了也收不了货。
-- 所以这里做成【到不了】,而不是【到了会拒绝】。
--
-- 【反方向那一半才是真正会搁死人的】关掉开关时,已经 pending 的单会永远停在
-- pending(approve_purchase_order 抛 APPROVALS_NOT_ENABLED)。所以关闭同样有闸,
-- 并且【点名】还剩几张、是哪几张 —— 拒绝要给出路,不是给一堵墙。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql.

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
    v_gap     record;
    v_doc     record;
    v_thr     numeric;
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

        -- ════════════════════════════════════════════════════════════════════
        -- ★★★ APR-2:每一条接上引擎的链,都必须【真的有人批得动】 ★★★
        -- ════════════════════════════════════════════════════════════════════
        -- 上面那一段问的是"这一级的角色有没有真人、看不看得见金额" ——
        -- 两个都是【关于角色的】问题。而它们全部为真时,这条链仍然可以是死的:
        -- 一个持有那个角色的人,可能根本进不了那张单据所在的模块。
        -- ★ 这不是假设:WO-1b 就是这么在线上造出一把锁的,而当时三道闸全绿
        --   (逐项实测写在 db/functions/approval_chain_gates.sql 的抬头)。
        --
        -- ★★ 传的是 NEW 的两个角色码,【不能】让它自己去读表:本触发器是
        --    BEFORE UPDATE,而策略四列是一起写的 —— 读表读到的是 OLD,
        --    于是这道闸会去判上一版策略,并且全绿。
        --
        -- 【为什么是拒绝,不是忠告】与本函数抬头那句话同一条:把"开着但没人批"
        -- 做成一个【到不了】的状态,而不是【到了才发现】。后者的代价是一批
        -- 永远停在 pending 的单据,而开关此时已经关不掉了(下面那道闸)。
        FOR v_gap IN
            SELECT i.action_function, i.level, i.role_code,
                   array_to_string(i.gate_permissions, '+') AS perms
              FROM approval_gate_intersections(NEW.approval_level1_role_code,
                                               NEW.approval_level2_role_code) i
             WHERE i.approvers = 0
             ORDER BY i.action_function, i.level
             LIMIT 1
        LOOP
            RAISE EXCEPTION 'APPROVALS_CHAIN_HAS_NO_APPROVER|%|%|%|%',
                v_gap.action_function, v_gap.level, v_gap.role_code, v_gap.perms;
        END LOOP;
    END IF;

    -- ── 关:会被永远搁死的在途单据,先点名 ──
    -- ★★ APR-3(Tim 的 Q6):判据从"数采购单"换成 approval_pending_documents()
    --    里 blocks_disable 为真的那些 —— 而今天这两件事【算出同一个数】。
    --    换它不是为了换出一个新数字,是为了让这道闸与屏幕读【同一支函数】:
    --    APR-3 把屏幕上的在途张数放宽到了每一条链,而这道闸【没有】跟着放宽,
    --    两个数从此不同。它们必须出自同一个定义,否则下一个读代码的人无从
    --    知道哪一个才是拦人的那个。
    -- ★【为什么不是"每一条链都算"】那会当场把审批锁死在开着的状态:线上今天
    --    有一张 submitted 的报销单,而一张 submitted 的报销单在审批关着时
    --    【照样批得了】(decide_expense_claim 只有分档那一步是条件性的)。
    --    判别的那一句话写在 approval_pending_documents 的抬头,
    --    下一刀接一条链时照它回答一次:**这条链的决定函数,在审批关着的时候
    --    还跑不跑得动?**
    IF OLD.approvals_enabled AND NOT NEW.approvals_enabled THEN
        SELECT count(*)::integer, string_agg(d.code, ', ' ORDER BY d.code)
          INTO v_pending, v_codes
          FROM approval_pending_documents() d
         WHERE d.blocks_disable;
        IF COALESCE(v_pending, 0) > 0 THEN
            RAISE EXCEPTION 'APPROVALS_CANNOT_DISABLE_WITH_PENDING|%|%', v_pending, v_codes;
        END IF;
    END IF;

    -- ── 开着的时候不许把策略值抽走 ──
    -- ★★ APR-3 把这一段【提到 WOULD_STRAND 之前】,而这不是排版:
    --   抽走门槛(NEW 为 NULL)时,下面那一段会拿一个 NULL 门槛去重新分档,
    --   于是每一张在途单据都被当成二级判 —— 二级碰巧没有人批得动时,
    --   它会抛出 WOULD_STRAND,而**这次编辑真正的毛病是"你不能在开着的时候
    --   把这个值抽走"**。☞ 一条更含糊的拒绝盖住一条更准的拒绝,
    --   在屏幕上就是一句指错路的话。**结构上就不合法的那一种,先拒。**
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

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★★ APR-3:APPROVALS_POLICY_WOULD_STRAND —— 一条【定向】拒绝 ★★★
    -- ════════════════════════════════════════════════════════════════════════
    -- Tim 的 N8 裁定:**不做一刀切的锁。** 最需要改策略的时刻,正是某条链配错了、
    -- 单据卡住的时刻;锁住它会把一个救得回来的状态变成一个救不回来的状态,
    -- 而那正是本函数抬头那句「拒绝要给出路,不是给一堵墙」。
    --
    -- ★【它判的是什么】审批【开着】,而这次编辑动了角色或门槛:拿【新策略】
    --   把每一张在途单据重新分一次档,再问那一档那条链有没有人批得动。
    --   有一张落在没人批得动的档上 → 按名拒,并【点出那张单、那一级、那个角色】。
    --   其余一律放行 —— 包括"把某一级换成一个更窄的角色"这种一般性的改动,
    --   只要今天在途的这些单据都还有人批。
    --
    -- ★★【为什么必须拿 NEW 的门槛,而不是让 approval_level_for 自己去读表】
    --   本触发器是 BEFORE UPDATE:读 finance_settings 读到的是 OLD 那一行。
    --   于是"重新分档"会拿【旧门槛】去分,并且全绿 —— 与上面那道
    --   APPROVALS_CHAIN_HAS_NO_APPROVER 传 NEW 角色码是逐字同一个陷阱。
    --   分档那个比较号只有一份定义(approval_level_at),这里传参用它。
    --
    -- ★【金额分不出来的那一张,按二级判】Tim 的 N4 原话:「不明金额的安全方向
    --   是往上」。一张查不到牌价的报销单分不了档,这里不放它过去,也不发明
    --   一个新规矩 —— 复用那一条。今天线上没有这样的单据。
    --
    -- ★【它不重复定义"谁批得动"】那一句仍然只有 approval_gate_intersections()
    --   一份实现,这里只是按 (subject_type, level) 去查它的答案。
    IF NEW.approvals_enabled AND OLD.approvals_enabled
       AND (NEW.approval_level1_role_code IS DISTINCT FROM OLD.approval_level1_role_code
         OR NEW.approval_level2_role_code IS DISTINCT FROM OLD.approval_level2_role_code
         OR NEW.approval_threshold_base   IS DISTINCT FROM OLD.approval_threshold_base) THEN
        v_thr := NEW.approval_threshold_base;
        FOR v_doc IN
            SELECT d.subject_type, d.code,
                   CASE WHEN d.amount_base IS NULL OR v_thr IS NULL
                        THEN 2::smallint
                        ELSE approval_level_at(d.amount_base, v_thr) END AS lvl
              FROM approval_pending_documents() d
             ORDER BY d.subject_type, d.code
        LOOP
            FOR v_gap IN
                SELECT i.action_function, i.role_code,
                       array_to_string(i.gate_permissions, '+') AS perms
                  FROM approval_gate_intersections(NEW.approval_level1_role_code,
                                                   NEW.approval_level2_role_code) i
                 WHERE i.subject_type = v_doc.subject_type
                   AND i.level = v_doc.lvl
                   AND i.approvers = 0
                 ORDER BY i.action_function
                 LIMIT 1
            LOOP
                RAISE EXCEPTION 'APPROVALS_POLICY_WOULD_STRAND|%|%|%|%|%',
                    v_doc.code, v_doc.lvl, v_gap.role_code, v_gap.action_function, v_gap.perms;
            END LOOP;
        END LOOP;
    END IF;

    RETURN NEW;
END;
$function$;
