-- TASK-1c-a-fu1:把 ensure_task_owner_participant 的 EXECUTE 从 authenticated 收回
--
-- 【gate 的 B2 抓到的,而它抓得对】。1c-a 把"归属人置为活跃参与者"抽成一个
-- SECURITY DEFINER 函数给两扇门共用 —— 抽得对,但没有收权。后果不是理论上的:
--     任何登录用户都可以 select ensure_task_owner_participant('<任何任务>', '<自己>')
-- 把自己插成那张任务的活跃参与者,而【活跃参与者就是 can_edit_task 团队分支的
-- 全部判据】。也就是说它是一把针对全部团队任务的万能写权限。
--
-- 修法照本仓库既有的那一条:内层函数【连 authenticated 也不给】,靠的就是调不到
-- (calculate_metal_price_internal / reverse_journal_entry_internal 同处理)。
-- 它只从 trg_tasks_type_transition 与 trg_tasks_team_owner_participant 的函数体内
-- 被调用,那两个都是 SECURITY DEFINER,以属主身份跑,不受这条 REVOKE 影响。
--
-- 声明写在 db/views/zzz_function_grants.sql 里(重建那一侧的唯一出口),
-- 这支迁移把它落到线上 —— apply_migration.sh 会在同一个事务里replay 那个文件。
BEGIN;

REVOKE EXECUTE ON FUNCTION public.ensure_task_owner_participant(uuid, uuid, uuid) FROM authenticated;

COMMIT;
