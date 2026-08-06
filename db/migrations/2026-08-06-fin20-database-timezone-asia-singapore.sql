-- db/migrations/2026-08-06-fin20-database-timezone-asia-singapore.sql
--
-- FIN-20:数据库的"今天"改为新加坡的今天。
--
-- 【症状,走查实测两头】库跑 UTC 时,每天 SG 00:00–08:00 服务器的 CURRENT_DATE
-- 是【昨天】:
--   * record_assay_result 把日期为今天的化验拒为"未来"(ASSAY_DATE_INVALID)——
--     Tim 在 SG 8/6 01:29 撞上;
--   * reprice_inbound_batch 以 CURRENT_DATE 取牌价并记账 —— 窗口内静默用了
--     前一天的牌价(精确命中,FIN-19 都不经过),分录也记在前一天。
--     JE-2026-0036 / JE-2026-0038 就是这么来的(已列入 known-wrong-until-cutover)。
--   * 全部服务端盖章的分录日期(冲销镜像、触发器、盘点、预付冲抵)同病;
--     月初 00:00–08:00 撞上期间锁的情形已记入 docs/known-issues.md。
--
-- 【为什么是改库时区而不是逐处传日期】剩下用 CURRENT_DATE 的位置恰恰是【设计上
-- 没有客户端日期】的:冲销镜像、触发器分录、定价日、"不得晚于今天"的校验基准。
-- 逐处传参还是得先回答"服务器的今天按哪个时区算"—— 绕回同一个决定。业务单辖区,
-- SG 假日表 / is_business_day / CPF / GST 全都已按新加坡承重。将来真有第二辖区,
-- 正确做法是把业务日期改成显式参数,而不是再改时区。
--
-- 【生效边界】ALTER DATABASE 只影响新会话。应用连接逐请求新建,立即生效;
-- 本迁移会话自身保持 UTC,自检据此写(不能在本会话断言 current_setting)。
--
-- 【重建路径】同一设定在 db/database-settings.sql,verify_rebuild 每次重建都跑
-- (无论平台在不在 —— 它是应用配置,不是平台基座,新开的 Supabase 项目不会自带)。
-- gate.py 的 guc 行自此逐条比对线上与重建的库级 GUC;fixture 15 钉行为。
--
-- 【为何白天应用】修的正是"半夜服务器的今天是昨天"。在窗口内应用它,应用瞬间
-- CURRENT_DATE 从昨天跳到今天 —— 半夜看着对、早上九点错的那一类。白天应用,
-- 跳变为零(两个"今天"本来就相等)。

BEGIN;

ALTER DATABASE postgres SET timezone TO 'Asia/Singapore';

-- 自检:设定必须已落进 pg_db_role_setting(对库、对所有角色)。
-- (current_setting 在本会话仍是 UTC —— ALTER DATABASE 只影响新会话,不能拿它断言。)
DO $mig$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_db_role_setting s
        JOIN pg_database d ON d.oid = s.setdatabase
        WHERE d.datname = current_database() AND s.setrole = 0
          AND s.setconfig @> ARRAY['TimeZone=Asia/Singapore']
    ) THEN
        RAISE EXCEPTION 'FIN20_SELFCHECK_FAILED|库级 TimeZone 设定没有写进 pg_db_role_setting';
    END IF;
END
$mig$;

COMMIT;
