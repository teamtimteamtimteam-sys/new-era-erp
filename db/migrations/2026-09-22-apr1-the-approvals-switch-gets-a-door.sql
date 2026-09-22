-- db/migrations/2026-09-22-apr1-the-approvals-switch-gets-a-door.sql
-- APR-1 · 审批开关的写路径 —— 一支 RPC、一道列作用域的守卫、一张留痕表
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【它补的是什么】APR-0 勘察出来的两件事:
--   ① 那四列【没有任何写路径】—— `/settings/approvals` 是只读的,线上那一行
--      是直接改库改出来的(docs/handbacks/APR-0.md §2.2);
--   ② `finance_settings` 的写闸是表级的 `enforce_write_permission('module.finance.edit')`,
--      而持有它的是 admin · finance · gm —— ★ **`finance` 正是被裁定的一级审批角色**。
--      也就是说:约束她的那条策略,写闸这一侧对她是开着的
--      (`docs/known-issues.md` APR0-APPROVALS-SWITCH-WRITE-GATE)。
--
-- Tim 的裁定(2026-09-22,APR-0 Q2):一支查 `action.manage_permissions` 的
-- SECURITY DEFINER RPC,**外加**一道守卫 —— 审批策略那四列凡不经该 RPC 的改动
-- 一律【按名拒绝】;守卫【不许】碰其余各列;拒绝要有名字。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★【守卫靠什么认出"这是 RPC 写的" —— 而这一段是本刀最要紧的一页】★★★
-- ════════════════════════════════════════════════════════════════════════════
-- 本仓库被 `set_config(..., true)` 烧过一次(PUR2-FU2,2026-08-11):那个 `true`
-- 是 is_local = **事务局部**,不是语句局部,于是【举起一次旗子就把这道闸放倒到
-- 事务结束】。所以一个"举旗-放行"式的守卫,先天就要回答两个问题:
--   (一) 旗子能不能被【外面】举起来?
--   (二) 举一次能放行几条语句?
--
-- ★ (一) 的答案是【能】—— 而且是本刀实测出来的,不是推的。
--   2026-09-22,一次回滚掉的探针,`SET LOCAL ROLE authenticated` 之后:
--       set_config('evoltrya.apr1_forge_probe','1',true)  →  成功,读回 '1',无错
--   **一个自定义命名空间的 GUC 不是一项权限,它是一个谁都写得进的值。**
--   ☞ 所以【旗子永远不能是那道边界】。
--
-- ★ 真正的边界是 `row_security_active(TG_RELID)` —— 它不是一个值,是一件关于
--   【调用者是谁】的事实。同一次探针里:
--       row_security_active(finance_settings)  as postgres       →  f
--                                              as authenticated  →  t
--       SET LOCAL row_security = off  as authenticated           →  接受,但
--       row_security_active 仍然是 t,而任何一次读当场报错:
--           "query would be affected by row-level security policy for
--            table \"finance_settings\""
--   ☞ **它举不起来**:没有任何 GUC、claim 或会话设置能让一个 RLS 之下的调用者
--     把它变成 false;要豁免,只能【是】表的属主,或者跑在属主的 SECURITY DEFINER
--     函数体内 —— 那是一次授权,不是一个值。
--
-- ★ 【为什么这支守卫是 INVOKER,不是 DEFINER】`row_security_active` 必须反映
--   【调用者】的视角。`enforce_write_permission` 的抬头逐字写着同一句话,而它
--   也正是全库唯一一支 `prosecdef = false` 的守卫。一支 DEFINER 的守卫问的是
--   它自己,于是它会放行一切。
--
-- ★ (二) 的答案:**守卫自己把旗子放倒**,在它放行的第一行上。于是举一次旗只
--   授权一次写入,而不是"事务的余生"。`finance_settings` 是单行表,所以
--   一条语句就是一行 —— 这里的"用完即焚"是精确的,不是近似的。
--
-- ★★ 【这道守卫【不】拦 postgres —— 照直说,因为没有任何东西拦得住】★★
--   属主可以 DROP 掉这个触发器。它建起来的边界是:**任何受 RLS 约束的调用者
--   都改不动这四列,包括持 `module.finance.edit` 的一级审批人本人** ——
--   那正是 APR0-APPROVALS-SWITCH-WRITE-GATE 登记的那个洞。迁移与 fixture 仍然
--   写得了,但它们必须【显式举旗】,也就是必须在源码里留下一句"我知道我在
--   直接写这四列"。那与 fixture 127 里 `evoltrya.po_status_ctx` 的用法同形。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它与 guard_approvals_switch 的关系:不绕过,也不重复】
-- RPC 发出的是一条【普通的 UPDATE】,所以 `trg_approvals_switch` 照常开火,
-- 开/关两个方向的九条具名拒绝一条不少。RPC 里【没有】EXCEPTION 块,
-- 于是那些拒绝原样穿过它到达界面。
-- ★ 触发器按名字排序开火,所以这道写闸叫 `trg_approvals_policy_write_gate`
--   ("po" < "sw"),它【先于】`trg_approvals_switch` 开火 —— 一次直连写拿到的
--   是"你不该直接写这四列",而不是一句关于策略完整性的、会把人带偏的话。
--
-- 【留痕:新建一张表,而不是塞进 approval_log】approval_log 的主体是
-- (subject_type, subject_id),subject_id 指向一【行单据】;finance_settings 是
-- 单行表,没有那样的 id。塞进去只能编一个假 subject_id 或者给枚举加一个不是
-- 单据的取值 —— 两者都是把一次【策略变更】伪装成一次【对某张单据的决定】。
-- 形状照 pricing_formula_history(谁 · 何时 · old → new)。
--
-- 【N6:approvals_readiness 的内检改成 action.manage_permissions】页面的闸是
-- 前者,而它调的这支函数内部要求 `module.finance.view` —— 两个码守同一块屏幕。
-- 今天 admin 与 cco 两个码都持有,所以看不出问题;哪一天有人持
-- action.manage_permissions 而不持 module.finance.view,那一页会渲染成 readError。
--
-- 【APR0-WORK-ORDER-APPROVALS-INVISIBLE:approval_log 的读策略补上 work_order 这一支】
-- WO-1b 动了枚举、动了 record_approval_decision、动了 release_work_order,
-- 【没动】RLS 读策略,于是 work_order 落进 `ELSE false`:写得进、读不出,
-- 对每一个人都是 0 行【而且不报错】。线上今天正有 1 行这样的留痕。
-- ★ 取的码是 `module.processing.view` —— 与 `work_orders` 自己的读策略【同一个】。
--   于是"这里零行"在屏幕上就真的只有一个意思。
--   ⚠ 照直说一件事:`cfo` 不持 `module.processing.view`,所以【二级审批人仍然
--   读不到工单的审批留痕】。那是对的:读工单的判据只该有一份定义。
--
-- 【本刀不打开审批】Tim 的裁定:approvals_enabled 保持 false,由他自己
-- 在 APR-1 之后从屏幕上打开一次。本迁移不写那四列的任何值。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 留痕表 ═════════════════════════════════════════════════════════════

CREATE TABLE public.finance_settings_history (
    id                            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    old_approvals_enabled         boolean,
    new_approvals_enabled         boolean,
    old_approval_level1_role_code text,
    new_approval_level1_role_code text,
    old_approval_level2_role_code text,
    new_approval_level2_role_code text,
    old_approval_threshold_base   numeric,
    new_approval_threshold_base   numeric,
    changed_at                    timestamptz NOT NULL DEFAULT now(),
    changed_by                    uuid
);

CREATE INDEX idx_finance_settings_history_changed
    ON public.finance_settings_history (changed_at DESC);

COMMENT ON TABLE public.finance_settings_history IS
    '审批策略的只增不改变更史(APR-1,pricing_formula_history 的形状)。谁、什么时候、四列各从什么改到什么。★ 唯一的写入者是 set_approvals_policy() —— 与 approval_log 同一条规矩:留痕不该有第二个写法,所以本表没有 INSERT 策略。★ 本表【不记】迁移或属主直接改库的那些变更:那些写得进四列(守卫不拦属主),但它们不经 RPC,于是这里没有行。空白好过编造 —— 同 pricing_formula_history「触发器之前的编辑没有行」。读的门取 action.manage_permissions,与【谁改得了它】同一个码。';

-- 历史本身不许被改写 —— 否则"留痕"只是摆设(同 guard_pricing_formula_history_append_only)
CREATE OR REPLACE FUNCTION public.guard_finance_settings_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'HISTORY_APPEND_ONLY';
END;
$function$;

CREATE TRIGGER trg_finance_settings_history_append_only
    BEFORE UPDATE OR DELETE ON public.finance_settings_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_finance_settings_history_append_only();

ALTER TABLE public.finance_settings_history ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是属主权限的 RPC。
-- 读的门与【谁改得了这条策略】取同一个码 —— 两道门同码,于是"这里零行"
-- 在屏幕上只有一个意思。
CREATE POLICY "finance_settings_history select by permission"
    ON public.finance_settings_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('action.manage_permissions'::text));

-- ═══ 2 · 列作用域的写闸 ══════════════════════════════════════════════════════
--
-- 【INVOKER,不是 DEFINER】见抬头:row_security_active 必须反映调用者。

CREATE OR REPLACE FUNCTION public.guard_approvals_policy_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_changed text[] := '{}';
BEGIN
    -- 【列作用域:比【值】,不比【提没提到】】`UPDATE OF col` 在列被【写进
    -- SET 子句】时就开火,哪怕值没变;而 setPeriodLock 与 GST 开关送的是整份
    -- 补丁。比值,这道闸才真的只管这四列。
    IF NEW.approvals_enabled IS DISTINCT FROM OLD.approvals_enabled THEN
        v_changed := v_changed || 'approvals_enabled'::text;
    END IF;
    IF NEW.approval_level1_role_code IS DISTINCT FROM OLD.approval_level1_role_code THEN
        v_changed := v_changed || 'approval_level1_role_code'::text;
    END IF;
    IF NEW.approval_level2_role_code IS DISTINCT FROM OLD.approval_level2_role_code THEN
        v_changed := v_changed || 'approval_level2_role_code'::text;
    END IF;
    IF NEW.approval_threshold_base IS DISTINCT FROM OLD.approval_threshold_base THEN
        v_changed := v_changed || 'approval_threshold_base'::text;
    END IF;

    -- 四列一个都没变 → 这不是一次策略改动,放行(setPeriodLock 走这一支)。
    IF cardinality(v_changed) = 0 THEN
        RETURN NEW;
    END IF;

    -- ★★ 真正的边界:受 RLS 约束的调用者一律拒。举不起来的那一道。★★
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'APPROVALS_POLICY_DIRECT_WRITE|%', array_to_string(v_changed, ', ');
    END IF;

    -- ★ 属主边界【之内】的精确度:必须是【显式举过旗】的那条路。
    --   它拦不住一个铁了心的属主(属主可以 DROP 这个触发器),它要的是:
    --   任何一条直接写这四列的路,都必须在源码里说出这句话。
    IF NULLIF(current_setting('evoltrya.approvals_policy_ctx', true), '') IS NULL THEN
        RAISE EXCEPTION 'APPROVALS_POLICY_DIRECT_WRITE|%', array_to_string(v_changed, ', ');
    END IF;

    -- ★★ 用完即焚 —— PUR2-FU2 那一课的修法。set_config(..., true) 是【事务局部】,
    --    举一次旗本来会把这道闸放倒到事务结束;在这里放倒它,一次举旗就只
    --    授权【这一行】。单行表 ⇒ 一条语句就是一行,所以这是精确的。
    PERFORM set_config('evoltrya.approvals_policy_ctx', '', true);
    RETURN NEW;
END;
$function$;

-- ★ 名字排在 trg_approvals_switch 【之前】("po" < "sw")—— 触发器按名开火,
--   于是一次直连写拿到的是这道闸的拒绝,而不是一句关于策略完整性的话。
CREATE TRIGGER trg_approvals_policy_write_gate
    BEFORE UPDATE ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION public.guard_approvals_policy_write();

-- ═══ 3 · 唯一的写入口 ════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.set_approvals_policy(
    p_enabled          boolean,
    p_level1_role_code text,
    p_level2_role_code text,
    p_threshold_base   numeric
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old   finance_settings%ROWTYPE;
    v_actor uuid := auth.uid();
BEGIN
    -- ★ 这一刀的全部理由:写这条策略的判据是【能不能管权限】,
    --   不是【能不能编辑财务设置】。后者 finance 自己就持有,而 finance
    --   正是被裁定的一级审批角色。
    PERFORM require_permission('action.manage_permissions');

    SELECT * INTO v_old FROM finance_settings WHERE id LIMIT 1;
    IF NOT FOUND THEN
        -- 单行表的那一行不见了。响亮地说,而不是 INSERT 一行把它变成默认值 ——
        -- 后者会把"策略丢了"悄悄换成"策略是空的"。
        RAISE EXCEPTION 'APPROVALS_SETTINGS_MISSING';
    END IF;

    -- 【什么都没改 = 不写库,也不落一行史】一份记满了"没发生的事"的历史,
    --   会把真正发生过的那几次埋掉。
    IF  v_old.approvals_enabled         IS NOT DISTINCT FROM p_enabled
    AND v_old.approval_level1_role_code IS NOT DISTINCT FROM p_level1_role_code
    AND v_old.approval_level2_role_code IS NOT DISTINCT FROM p_level2_role_code
    AND v_old.approval_threshold_base   IS NOT DISTINCT FROM p_threshold_base THEN
        RETURN jsonb_build_object('changed', false);
    END IF;

    -- 举旗 —— 守卫会在它放行的那一行上把它放倒(用完即焚,见守卫函数体)。
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);

    -- ★【没有 EXCEPTION 块,这是刻意的】guard_approvals_switch 的九条具名拒绝
    --   必须原样穿过这里到达屏幕。接住它们再翻译一遍,就是"谁可以开这个开关"
    --   的第二份实现。
    UPDATE finance_settings
       SET approvals_enabled         = p_enabled,
           approval_level1_role_code = p_level1_role_code,
           approval_level2_role_code = p_level2_role_code,
           approval_threshold_base   = p_threshold_base,
           updated_by                = v_actor
     WHERE id;

    -- 守卫已经放倒了它;这一句是为了"这条路上没有任何一面旗留在事务里"
    -- 这件事不依赖于守卫有没有开火(比如将来有人把守卫改成语句级)。
    PERFORM set_config('evoltrya.approvals_policy_ctx', '', true);

    INSERT INTO finance_settings_history (
        old_approvals_enabled,         new_approvals_enabled,
        old_approval_level1_role_code, new_approval_level1_role_code,
        old_approval_level2_role_code, new_approval_level2_role_code,
        old_approval_threshold_base,   new_approval_threshold_base,
        changed_by)
    VALUES (
        v_old.approvals_enabled,         p_enabled,
        v_old.approval_level1_role_code, p_level1_role_code,
        v_old.approval_level2_role_code, p_level2_role_code,
        v_old.approval_threshold_base,   p_threshold_base,
        v_actor);

    RETURN jsonb_build_object('changed', true);
END;
$function$;

COMMENT ON FUNCTION public.set_approvals_policy(boolean, text, text, numeric) IS
'审批策略那四列的【唯一】写入口(APR-1)。判据是 action.manage_permissions —— 不是 module.finance.edit,因为后者被一级审批角色 finance 自己持有(APR0-APPROVALS-SWITCH-WRITE-GATE)。四列一起写,因为 guard_approvals_switch 是把它们放在一起判的。★ 它【不绕过】那道闸:发出的是一条普通 UPDATE,开/关两个方向的具名拒绝照常开火并原样穿过本函数。★ 什么都没改 → 不写库、不落史。每一次真的改动落一行 finance_settings_history。';

-- ═══ 4 · N6 · 屏幕与它调的那支函数读【同一份】判据 ═══════════════════════════

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

-- ═══ 5 · APR0-WORK-ORDER-APPROVALS-INVISIBLE ════════════════════════════════
--
-- 写得进、读不出。★ 它的失败方式是一个【安静的零】:一张"这张工单谁放行的"
-- 的留痕页会渲染成一片正确的空白,而那与"还没有被放行过"在屏幕上逐字相同。

DROP POLICY "approval_log select by permission" ON public.approval_log;
CREATE POLICY "approval_log select by permission"
    ON public.approval_log
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (
        CASE subject_type
            WHEN 'leave_request'      THEN has_permission('module.hr.view'::text)
            WHEN 'medical_claim'      THEN has_permission('module.hr.view'::text)
            WHEN 'performance_review' THEN has_permission('module.hr.view'::text)
            WHEN 'purchase_order'     THEN has_permission('module.purchasing.view'::text)
            WHEN 'payment'            THEN has_permission('module.finance.view'::text)
            WHEN 'expense'            THEN has_permission('module.finance.view'::text)
            WHEN 'pricing_formula'    THEN has_permission('module.pricing.view'::text)
            WHEN 'stocktake'          THEN has_permission('module.stocktakes.view'::text)
            -- ★ APR-1:WO-1b 漏掉的那一支。取的码与 work_orders 自己的读策略
            --   【同一个】—— 读工单的判据只该有一份定义。
            WHEN 'work_order'         THEN has_permission('module.processing.view'::text)
            ELSE false
        END
    );

-- ═══ 6 · 自证 ═══════════════════════════════════════════════════════════════
--
-- 【为什么自证的是【形状】,不是一个总数】EQP-PAY-1 把自证钉在"cfo 恰好四个码"
-- 上,而同一天另一刀出于完全正当的理由让它变成五个 —— 一个钉在总数上的自证,
-- 钉的是一个别人可以为了好理由挪动的数字(docs/approvals.md §0 的 APR-0 批注)。
DO $$
DECLARE
    v_n integer;
BEGIN
    -- ① 写闸必须排在开关闸【前面】—— 触发器按名开火,顺序是被设计的。
    SELECT count(*) INTO v_n
      FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
     WHERE c.relname = 'finance_settings' AND NOT t.tgisinternal
       AND t.tgname = 'trg_approvals_policy_write_gate';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'APR1_SELFCHECK|写闸没有装在 finance_settings 上';
    END IF;
    IF 'trg_approvals_policy_write_gate' >= 'trg_approvals_switch' THEN
        RAISE EXCEPTION 'APR1_SELFCHECK|写闸的名字排在开关闸之后,它会后开火';
    END IF;

    -- ② 守卫必须是 INVOKER —— DEFINER 的话 row_security_active 问的是它自己。
    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname = 'guard_approvals_policy_write' AND NOT prosecdef;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'APR1_SELFCHECK|守卫不是 INVOKER,row_security_active 会问错人';
    END IF;

    -- ③ RPC 必须是 DEFINER —— 它要越过 finance_settings 的表级写闸。
    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname = 'set_approvals_policy' AND prosecdef;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'APR1_SELFCHECK|set_approvals_policy 不是 SECURITY DEFINER';
    END IF;

    -- ④ 本刀【不打开审批】,也不动那四列的任何值。
    IF (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR1_SELFCHECK|审批在本次迁移后是开着的 —— 本刀不许打开它';
    END IF;

    -- ⑤ 留痕表建出来时必须是空的:本刀没有经 RPC 写过任何一次策略。
    SELECT count(*) INTO v_n FROM finance_settings_history;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'APR1_SELFCHECK|finance_settings_history 不是空的';
    END IF;
END $$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ★【本刀原先在这里写的那段话是【错】的,整门当场抓到 —— 更正留在这里,不删】★
--
-- 原话:「新表会拿到 Supabase 的默认表级授权(与其余留痕表一样),所以
--        db/anon-grants-baseline.tsv 里那一行是刻意加的」。
--
-- **实测(2026-09-22,迁移之后读 information_schema.role_table_grants):**
--     finance_settings_history → authenticated · postgres · service_role
--                                ★ 【没有】 anon —— 与 fixed_asset_history 逐字相同
--     approval_log / pricing_formula_history → ★ 【有】 anon(旧的那一套默认权限)
--
-- 原因 FA-HIST-1 两天前已经量过,写在 db/tables/fixed_asset_history.sql 里:
-- 线上 public 有【两套】默认权限,而 db/apply_migration.sh 以 postgres 身份直连,
-- 这样落下来的表【本来就没有】 anon 的授权。本地重建的 prelude 复刻的是另一套,
-- 于是重建出来的表多了 anon —— 镜像与线上对不上,整门 exit 1。
--
-- ☞ 处置(与 FA-HIST-1 逐字相同,取【严的那一边】):镜像里显式
--   `REVOKE ALL ON public.finance_settings_history FROM anon`,让【本地重建】长成
--   线上的样子;**不是反过来给线上补一条 anon 授权** —— 为了让一次比对变绿而
--   放宽权限,方向就反了。基线里那一行【已撤掉】:那份文件记的是"anon 够得着的
--   东西",而 anon 够不着它;往一份「只许缩小」的基线里加一行,方向同样反了。
--
-- ☞ 为什么记在这里而不是把那句话删掉:★ **同一个坑,两天之内被踩了第二次。**
--   第一次的教训写在一个【表镜像】的注释里,而下一个建表的人不会去读那个文件。
--   这一条因此属于"下一刀建表时会撞上"的那一类,不属于"本刀的花絮"。
-- ════════════════════════════════════════════════════════════════════════════
