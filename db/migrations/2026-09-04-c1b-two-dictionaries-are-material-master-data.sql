-- ════════════════════════════════════════════════════════════════════════════
-- C-1b(2026-09-04):实验室名录与无单收货理由,【写】权从收货抬到物料主数据
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【缺陷】这两张字典的 insert/update 策略要 module.inbound.edit,而
--   warehouse(仓储现场)持有它 —— 现场收货要用。于是一个仓储现场负责人
--   【建得了实验室,也翻得动 inbound_source_reasons.requires_explanation】,
--   而后者是一条【规则】开关:它决定无单收货要不要写明理由。那不是他的活。
--
-- 【为什么不是收回 warehouse 的 module.inbound.edit】那会把现场收货一起弄坏,
--   而收货正是他每天的工作。Tim 点名不许(C-1b 的 Q8/item 2)。
--
-- 【所以改的是这两张表要哪个码】写要 module.materials.edit —— 它们本来就是
--   【物料主数据】那一族:实验室名录决定化验结果挂在谁名下,来源理由决定一批
--   没有单据的料怎么被解释。读仍然对所有登录用户开放(SELECT USING (true)),
--   所以现场的人照样看得见名录,填得了单 —— 界面那一侧由
--   app/settings/dictionaries/registry.ts 的 viewPermission(= module.inbound.view)
--   把这两节渲染成【只读】。
--
-- ★★【为什么这必须是一支迁移,而不是只改 registry.ts】★★
--   registry.ts 的 permission 字段【只是界面的门】—— 字典的写入路径
--   (app/settings/dictionaries/actions.ts)没有任何 require_permission,
--   它靠的就是这几条 RLS 策略。只改 registry 会得到
--   **一张藏起来的表单 + 一个敞开的写入**:Fu Sheng 在界面上看不到按钮,
--   而一次直连 PostgREST 的 INSERT 照样成功。那比不改更坏,因为矩阵会被
--   后来的人当成真的。**本仓库没有任何机器在检查 registry 与 RLS 一致**
--   (check-permission-predicate 回答的是另外三个问题),所以这条只能靠人守。
--
-- 【谁受影响 —— 实测,逐个点名】
--   失去这两节的编辑权 = 持 inbound.edit 而【不持】materials.edit 的角色。
--   实测线上 12 个在册角色里,**只有 warehouse 一个**。
--   admin / cco / finance / gm / operations / procurement 都同时持 materials.edit,
--   一个都不受影响。**没有任何角色因此获得新的编辑权。**
--
-- 【为什么没有 DELETE 策略要改】这两张表【本来就没有】DELETE 策略 ——
--   RLS 打开而没有 permissive 的 DELETE 策略,等于谁都删不掉。字典是软停用
--   (is_active),不是删除。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

DROP POLICY "laboratories insert by permission" ON public.laboratories;
CREATE POLICY "laboratories insert by permission"
    ON public.laboratories AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'::text));

DROP POLICY "laboratories update by permission" ON public.laboratories;
CREATE POLICY "laboratories update by permission"
    ON public.laboratories AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit'::text))
    WITH CHECK (has_permission('module.materials.edit'::text));

DROP POLICY "inbound_source_reasons insert by permission" ON public.inbound_source_reasons;
CREATE POLICY "inbound_source_reasons insert by permission"
    ON public.inbound_source_reasons AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'::text));

DROP POLICY "inbound_source_reasons update by permission" ON public.inbound_source_reasons;
CREATE POLICY "inbound_source_reasons update by permission"
    ON public.inbound_source_reasons AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit'::text))
    WITH CHECK (has_permission('module.materials.edit'::text));

-- ── 事务内自检:四条策略都必须已经指向 materials.edit,一条都不许漏 ──────
DO $check$
DECLARE v_bad text;
BEGIN
    SELECT string_agg(tablename || '.' || policyname, ', ') INTO v_bad
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('laboratories', 'inbound_source_reasons')
      AND cmd IN ('INSERT', 'UPDATE')
      AND coalesce(qual, '') || coalesce(with_check, '') NOT LIKE '%module.materials.edit%';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'C1B_POLICY_NOT_MOVED|%', v_bad;
    END IF;
END $check$;

COMMIT;
