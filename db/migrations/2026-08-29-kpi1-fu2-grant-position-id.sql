-- KPI-1 fu2:把 position_id 加进 employees 的【列清单授权】。
--
-- 【为什么需要它】employees 走的是列清单 SELECT 授权,而 AGENTS.md 记着:
-- **列清单授权【不会】自动扩展到后加的列**(表级 INSERT/UPDATE 会,SELECT 不会)。
-- 于是一个 ADD COLUMN 会造出"写得进、读不出"的列 —— FIN-6 就是这么让
-- /finance/processing-costs 从上线那天起就是空的,而所有闸都是绿的。
-- WO-1a 把这条写成了三件事要在【同一次迁移】里做完:ADD COLUMN、GRANT、_masked。
-- **我把第二、三件漏在了主迁移外面** —— 第三件在 fu1,这是第二件。
-- (今天没有读者靠这条授权:界面读的是属主权限的 employees_masked。
--  但镜像与线上必须一致,而且下一个直接读 employees 的人不该踩这个坑。)
BEGIN;
GRANT SELECT (position_id) ON public.employees TO authenticated;
COMMIT;
