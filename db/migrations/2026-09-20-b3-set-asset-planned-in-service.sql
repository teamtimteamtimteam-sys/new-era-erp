-- db/migrations/2026-09-20-b3-set-asset-planned-in-service.sql
-- B3 · 「计划投用日」那扇门 —— 它从落地那天起就是死的,这一刀给它一扇【会说话】的门
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【它修的是什么】`fixed_assets` 开着 RLS,而全表【只有一条 SELECT 策略】。
--   于是 `app/finance/assets/[id]/actions.ts` 那一处直连 UPDATE 对【所有人】
--   都匹配零行 —— 包括 admin。零行不是错误,所以 `error` 是 null。
--   (DBLOCK-1 已经让它不再报告成功,走 refuseNothingChanged;门仍然是关的,
--    只是现在它会说自己关着。这一刀把门【打开】。)
--
-- ★★【为什么是一支函数,不是补一条 UPDATE 策略】★★(BLOCKERS-0 §3 B3,Tim 裁定 C1)
--   ① 这张表上其余每一次写入都【已经】是 SECURITY DEFINER 函数 —— 线上实测
--      16 支碰它的函数,`prosecdef` 全部为 true。补策略会造出**第二扇门**,
--      而 known-issues 的 LINK-1 正是为「两扇门、两套规矩」立的案。
--   ② 这张表【没有 updated_by / updated_at】(线上实测 23 列,一列都没有)。
--      所以补策略要么不留痕,要么把一次迁移变成两次。
--   ③ 这张表【没有 enforce_write_permission 语句级触发器】—— 它上面只有两支
--      守卫触发器(acceptance_not_future · in_service_not_future),两支都不管权限。
--      补策略之后,被拒的写在**数据库那侧仍然是静默的零行**。
--      ☞ 而一支函数可以【按名拒】。那正是这张表从来没有过的那一半。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ⚠★★【计划 ≠ 事件 —— 这支函数与 set_asset_in_service 【必须】保持两件事】★★⚠
-- ════════════════════════════════════════════════════════════════════════════
--   `set_asset_in_service` 记的是一件【已经发生】的事,所以它拒未来的日期
--   (trg_fixed_assets_in_service_not_future)。
--   `planned_in_service_date` 【可以】在未来 —— **那是它存在的全部理由**。
--   线上实测佐证:这一列身上【一条 CHECK 约束都没有】,连 "after acquisition"
--   都没有;两支守卫触发器看的都是另外两列。
--
--   ☞ 所以本函数:
--     · **没有** not-future 守卫 —— 一次从 set_asset_in_service 复制粘贴会
--       带来那条守卫,而那会把这扇门修成它要替代的那一件东西;
--     · **不写** in_service_date,一个字节都不写;
--     · **接受 NULL** = 撤掉这个计划。计划会变,撤计划是一个正当的动作,
--       不是一个要被拦的状态(调用点的注释逐字写着这一条)。
--       ★ 这也是与 set_asset_in_service 的第二处分歧:那一支对 NULL 抛
--         DATE_REQUIRED,而在这里那会是一条错的规矩。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【权限:module.finance.edit】(Tim 裁定 C2)
--   同表的 SELECT 策略用的是 module.finance.view;而应用侧今天被拒时**已经**
--   按 module.finance.edit 报错(refuseNothingChanged('module.finance.edit'))。
--   换成别的码,会让屏幕上那句拒绝变成一句假话。
--   ★ 判据进了函数体,所以将来要判得更细(例如「已投用的卡不许再改计划」)
--     **不需要再来一次迁移**。本刀【没有】加那一条 —— 它没有被裁定,
--     而一条没人要求的规矩会拦住一个正当的动作。
--
-- 【留痕:本刀【没有】做到,而这是一个具名项,不是一个沉默的缺口】(Tim 裁定 C5)
--   C5 要的是「在函数体里记下谁设的、什么时候」,而不加列、不新建表。
--   **全库找过了,没有一个够得着的落点** —— 逐条写在 docs/handbacks/B3.md,
--   摘要:这个库里每一条留痕都是【一张表配一张影子表】(11 张 *_history,
--   各带 changed_by);`fixed_assets` 没有影子表,而新建一张正是 C5 禁止的
--   「发明一张表」。`approval_log` 被两条 CHECK 锁死(subject_type 的 9 个取值
--   里没有资产,decision 的 7 个取值全是审批动词),`notifications` 是告警流。
--   往任何一个里塞,都要既改别的子系统的约束(第二个迁移面),又说一句假话。
--   ☞ **所以这一刀不留痕。** 记在 docs/known-issues.md,带返回条件。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.set_asset_planned_in_service(p_asset_id uuid, p_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_a fixed_assets%ROWTYPE;
BEGIN
    -- 【按名拒】这张表从来没有过的那一半:RLS 的零行是静默的,这一句不是。
    PERFORM require_permission('module.finance.edit');

    -- p_date 允许为 NULL(= 撤掉计划)—— 见抬头。这里【故意】没有 DATE_REQUIRED。
    SELECT * INTO v_a FROM fixed_assets WHERE id = p_asset_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_NOT_FOUND|%', COALESCE(p_asset_id::text, '?');
    END IF;

    -- ⚠ 只写这一列。in_service_date 是另一件事,见抬头那一节。
    UPDATE fixed_assets SET planned_in_service_date = p_date WHERE id = p_asset_id;

    RETURN jsonb_build_object('asset_id', p_asset_id, 'code', v_a.code,
                              'planned_in_service_date', p_date);
END;
$function$;

-- 与 db/views/zzz_function_grants.sql 同向(apply_migration.sh 在 COMMIT 之前
-- 把那支文件在同一个事务里重放一遍,它的第一句是 REVOKE … FROM PUBLIC, anon)。
-- 本函数【有调用者检查】,所以它走的是那另一半保证,不需要在那支文件里加行。
REVOKE EXECUTE ON FUNCTION public.set_asset_planned_in_service(uuid, date)
    FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.set_asset_planned_in_service(uuid, date)
    TO authenticated, service_role;

COMMIT;
