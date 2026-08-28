-- ATTEND-1 fu1:attendance_unpaid_days 改回 SECURITY INVOKER
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【gate 的 B1 抓到的,而它抓得对】
-- 原版写成 SECURITY DEFINER,而它【没有、也无法有】权限检查 —— 它是一支
-- LANGUAGE sql 的推导函数,PERFORM require_permission(...) 在那里写不出来。
-- 于是任何一个 authenticated 用户都可以
--     SELECT attendance_unpaid_days('<同事的 employee_id>', '2026-07-01')
-- 问出别人这个月请了几天无薪假 —— 而 leave_requests 的行级策略本来是拦着的。
-- **一支绕过 RLS 的读取函数,就是一条第二条读取路径**,而这条没有人守。
--
-- 【为什么 INVOKER 不会打断内部调用】它的三个调用者【本身】都在属主权限下跑:
--   · complete_attendance_period —— SECURITY DEFINER;
--   · attendance_period_status —— WITH (security_invoker = off);
--   · 而 fixture 与 psql 里的直接调用跑在库主身上。
-- SECURITY INVOKER 的意思是"用当前生效身份",在上述三处那个身份就是属主 ——
-- 行为一个字节不变。变的只有【员工直接调它】那一条路:那时它按 leave_requests
-- 自己的策略读,于是问别人只会得到 0。那正是本该有的答案。
--
-- 【同形前科】CHASE-1 的 next_chase_code 写成 DEFINER,七个先例全是 invoker,
-- 同样由 B1 抓到、同样用一支 fu1 迁移 ALTER 回来。第二次了 —— 记在切次报告里。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

ALTER FUNCTION public.attendance_unpaid_days(uuid, date) SECURITY INVOKER;

COMMENT ON FUNCTION public.attendance_unpaid_days(uuid, date) IS
    'ATTEND-1:某人在某个月里【已批准的无薪假】天数 —— 推导,不重记。天数一律走 calculate_leave_days(它已经懂工作日与公共假期);在这里再数一遍日子就是它的第二份实现。跨月的请假单按月裁剪,而【半天标记只在裁剪之后仍是原端点时才成立】—— 裁出来的那一端不是任何人请过的半天。★【SECURITY INVOKER,不是 DEFINER】★(fu1)一支 LANGUAGE sql 的推导函数写不出权限检查,DEFINER 会让它变成一条绕过 leave_requests 行级策略的第二读取路径 —— 任何人都能问出同事请了几天无薪假。三个内部调用者(complete_attendance_period 是 DEFINER、attendance_period_status 是 security_invoker=off、fixture 跑在库主上)本身就在属主权限下,所以改成 INVOKER 对它们一个字节不变。';

COMMIT;
