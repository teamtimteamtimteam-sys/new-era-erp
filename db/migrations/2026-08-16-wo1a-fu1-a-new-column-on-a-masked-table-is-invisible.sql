-- WO-1a-fu1:新列加在遮蔽表上,不补授权就【写得进、读不出】
--
-- AGENTS.md 有整整一节写着这件事("Adding a column to a masked table: extend the
-- grant, or it is invisible"),FIN-6 为它付过一次代价 —— /finance/processing-costs
-- 与月结那一步从上线那天起就是空的,而所有闸门全绿。
-- 【本刀还是撞上了。】WO-1a 给 processing_runs 加了 work_order_id,而
-- processing_runs 是列清单授权的遮蔽表:
--     REVOKE SELECT ON processing_runs; GRANT SELECT (逐列) ...
-- PostgreSQL 对两个动词不对称 —— 表级 INSERT/UPDATE 授权【会】自动延伸到后加的
-- 列,列清单的 SELECT 授权【不会】。实测(本刀提交之后立刻查的):
--     has_column_privilege('authenticated','processing_runs','work_order_id','SELECT') = false
--     has_column_privilege('authenticated','processing_runs','process_date',  'SELECT') = true
-- 也就是说 WO-1b 一旦让 commit_processing_run 写这一列,任何 select 它、
-- 甚至只是【按它过滤】的查询都会 42501,而不是返回空。
--
-- 【它不是敏感列】它是一个单据之间的链接,与同表已经授权的
-- capitalization_entry_id 同一类:谁能看见这张加工单,谁就能看见它是照哪张工单做的
-- (AGENTS.md 那条"展示用的标签跟着单据走")。所以补进列清单,而不是只进遮蔽视图。
--
-- 【记下这次的教训,因为它不是"忘了看文档"】文档在,而且写得很清楚。真正缺的是
-- 【一条会在当场喊出来的检查】—— 而它其实存在:db/gate.py 的 colgrant 会红。
-- 本刀是在跑 gate 之前先手查了一次权限才发现的,顺序纯属侥幸。
-- 结论不是"下次记得",而是:**给遮蔽表加列的那一支迁移,授权要写在同一支里** ——
-- 与 OPS-7 用脚本替掉两句"记得检查 B1 与 is_system"是同一条。
BEGIN;

GRANT SELECT (work_order_id) ON public.processing_runs TO authenticated;

COMMIT;
