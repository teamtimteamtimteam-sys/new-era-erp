-- db/scripts/2026-08-05-set-system-start-date.sql
-- 设定 finance_settings.system_start_date = 2026-08-01。
--
-- 【纯数据】。不建表、不改函数、不动策略 —— 所以没有迁移文件、不涉及镜像
-- (finance_settings 是 RUNTIME CONFIG,check_mirrors 刻意不逐行比对它)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么是 2026-08-01 —— 把理由记下来,而不是留一个"谁填的"数字】
-- ════════════════════════════════════════════════════════════════════════════
-- 这个字段的含义是【本库自哪一天起持有完整记录】(见列注释与安装清单)。
--
--   * 2026-08-01 是第一位员工的入职日(EMP-2026-0001),也大致是真实的钱开始
--     发生的时候。本库在那之前没有任何业务记录 —— 不是"记录不全",是压根没有。
--   * 因此它也很可能就是【生产环境的取值】:测试库与生产库取同一个日期,
--     意味着接下来的走查是在【真实配置下】跑守卫,而不是被一个过于宽松的日期
--     把守卫全部关掉。
--
-- 【设定前后的实测差异 —— 回滚事务里量过】
--   设定前:medical_claim_balance / carry_forward_annual_leave 一律 SYSTEM_START_NOT_SET;
--   设定后:
--     · 2026 年医疗额度 = 417(1000 × 5/12,8–12 月共 5 个月)
--       —— 与设定前【完全一样】:hr_settings.medical_pro_rate_for_joiners 为真,
--          而该员工入职月正是 8 月,原本就按 5 个月折算。所以现有数据一分不变。
--     · medical_claim_balance(…, 2025) → CLAIM_YEAR_BEFORE_SYSTEM_START|2025|2026-08-01
--     · carry_forward_annual_leave(2026) → 正常执行(结转进 2027)
--     · carry_forward_annual_leave(2025) → CARRY_FORWARD_BEFORE_SYSTEM_START|2025|2026-08-01
--
-- 【如果走查中它挡住了什么】那是一个【发现】,报出来。
-- **不要把日期往前挪去让它通过** —— "为了让守卫放行而移动界线"正是这个字段
-- 要防的那件事,只是换到了上一层。真要挪,得先有一个关于"本库到底从哪天起
-- 记录完整"的答案,并且把切换前的交易真的补录进来(见安装清单)。

BEGIN;

UPDATE public.finance_settings SET system_start_date = '2026-08-01';

-- 自证:恰好一行、值正确。不然就回滚。
DO $$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM finance_settings WHERE system_start_date = DATE '2026-08-01';
    IF n <> 1 THEN
        RAISE EXCEPTION '预期恰好 1 行 system_start_date = 2026-08-01,实得 %', n;
    END IF;
END $$;

COMMIT;
