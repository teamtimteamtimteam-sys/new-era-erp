-- TASK-1c-a-fu2:三条策略【漏了 TO authenticated】,补回来
--
-- 【gate 的结构比对抓到的,而它抓得对】。1c-a 把 tasks 的 select/update/delete
-- 三条策略搬到谓词上时,CREATE POLICY 写成了不带 TO 子句的形式:
--     CREATE POLICY "tasks select by predicate" ON public.tasks FOR SELECT USING (...)
-- 没有 TO 就是 TO PUBLIC。原来那三条是 TO authenticated,镜像文件里也写的
-- authenticated —— 于是线上是 PUBLIC、重建是 authenticated,两边对不上。
--
-- 【实际后果有多大:小,但方向是错的】。谓词里 has_permission() 对 anon 返回 false,
-- 所以 anon 读不到任何行;真正变了的是【这三条策略适用于谁】,而不是谁读得到。
-- 但"靠里面那层谓词恰好也拦得住"不是一个可以留着的理由 —— 本仓库对
-- 「绿的,却对某一类读者是错的」点过太多次名。策略的适用范围要说的就是它自己那句话。
BEGIN;

DROP POLICY "tasks select by predicate" ON public.tasks;
DROP POLICY "tasks update by predicate" ON public.tasks;
DROP POLICY "tasks delete by predicate" ON public.tasks;

CREATE POLICY "tasks select by predicate" ON public.tasks
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (can_view_task(id));

CREATE POLICY "tasks update by predicate" ON public.tasks
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (can_edit_task(id)) WITH CHECK (can_edit_task(id));

CREATE POLICY "tasks delete by predicate" ON public.tasks
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (can_edit_task(id));

COMMIT;
