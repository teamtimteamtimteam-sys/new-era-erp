-- CHASE-1 fu1:next_chase_code 不该是 SECURITY DEFINER —— gate 的 B2 当场抓到
--
-- 【发生了什么】主刀把取号器写成了 SECURITY DEFINER。它的【七个先例】
-- (next_statement_code / next_credit_note_code / …)一个都不是 —— 全是普通的
-- invoker 函数。多给的这一份权限没有任何理由:取号器只在
-- record_collection_chase(它自己是 definer 且第一句就 require_permission)
-- 内部被调,而 invoker 函数在 definer 函数里本来就跑在属主上下文里。
--
-- 【是谁抓到的】`db/gate.py` 的 B2 不变量,线上与重建【两侧同时】报:
--   B2 VIOLATION next_chase_code: SECURITY DEFINER, no caller check, and executable
-- 这正是 AGENTS.md 记的那条「一个报告了却不拦的判词不是闸」的反面 ——
-- 它报了,而且它【拦住了】:GATE_EXIT=1,这一刀因此没有就这么过去。
--
-- 【为什么是一支 fu 迁移,而不是回去改上一支】上一支已经提交进线上了。
-- 迁移是【变更日志】:它记录真的发生过什么,而真的发生过的是"先写错了,
-- 再改回来"。回去改掉那一行会让日志说一件没发生过的事。
BEGIN;

ALTER FUNCTION public.next_chase_code(date) SECURITY INVOKER;

COMMENT ON FUNCTION public.next_chase_code(date) IS
    'CHASE-1:CHASE-YYYY-NNNN,按年重置、无缝。取号惯用法与 next_statement_code / next_credit_note_code 逐字相同,含各自一把 advisory 锁。【fu1:它是 SECURITY INVOKER,与七个先例一致】主刀误写成 DEFINER,被 gate 的 B2 不变量在线上与重建两侧同时抓到 —— 一个取号器不需要属主权限:它只在 record_collection_chase(自身 definer,首句 require_permission)内部被调,而 invoker 函数在 definer 函数里本来就跑在属主上下文。';

COMMIT;
