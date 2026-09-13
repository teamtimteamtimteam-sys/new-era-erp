-- SEARCH-2b · 迁移 C —— 「最近编辑过」要的那一组索引
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【T3 的裁定】recents = `updated_by = auth.uid()`,按 `updated_at DESC` 取前 5,
-- 索引形状 `(updated_by, updated_at DESC)`。SEARCH-0 §Q5 实测:这两列上
-- 今天【一条索引都没有】(updated_at 0 条 · updated_by 0 条)。
--
-- ★★★ 裁定写的是「21 条」,这里是【22 条】—— 差的那一条是 contracts ★★★
--   **这不是重开裁定,是那个数的【分母】掉了一层。** 逐条写清楚,因为
--   AGENTS.md 里「一个数被抄走时,它的分母掉了」已经付过账:
--     · 六轮里量的是「**31 张有行的表**里 21 张带 updated_by/at」——
--       分母是 **31**,也就是今天已经开出过单据的那些表;
--     · 而单据种类是 **39 张表 / 40 个前缀**(另外 8 张今天一行都没有)。
--       实测(2026-09-13):把同一个判据放在 39 张上,**22 张两列都有**,
--       多出来的正是 `contracts` —— 一张在册、今天还没有行的表。
--   ☞ 处置照【迁移 A 已经裁过的那条原则】走,一个字不改:
--     **「document_types 定义的是这套系统能铸什么,不是它铸过什么」** ——
--     A 给那 8 张空表也建了 trigram GIN,理由是「它们第一次被开出来的那天,
--     是 39 张里唯独没有索引的那几张,而没有人会注意到」。
--     contracts 落在同一句话里。少建这一条,第一份合同被编辑的那天
--     它就是唯一一张 recents 走全表扫的表。
--   ☞ 同一个分母搬家也让「10 张未覆盖的表在屏幕上点名」变成 **17 张**
--     (39 − 22)。★ 而应用层【不许把 10 或 17 写死】:那一行从
--     `document_types` join 目录现算,见 lib/search/recents.ts 的抬头。
--
-- 【破窗】纯增量:22 条索引。旧代码不读它们,也不可能被它们改变行为。
--
-- 【为什么不带 WHERE deleted_at IS NULL】这 22 张里并非每一张都有 deleted_at,
--   而一条【部分】索引在没有那一列的表上建不出来;更要紧的是 recents 的查询
--   写的是 `updated_by = auth.uid() ORDER BY updated_at DESC LIMIT 5`,
--   可见性由 RLS 决定、不由这条索引决定 —— 把可见性的一半塞进索引谓词,
--   就是把同一条规则写第二遍。

BEGIN;

-- 22 张:单据表里 updated_by 与 updated_at 【两列都有】的那些(实测 2026-09-13)。
CREATE INDEX IF NOT EXISTS assay_results_recents      ON public.assay_results      (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS bank_statements_recents    ON public.bank_statements    (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS containers_recents         ON public.containers         (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS contracts_recents          ON public.contracts          (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS customers_recents          ON public.customers          (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS employees_recents          ON public.employees          (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS freight_documents_recents  ON public.freight_documents  (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS inbound_batches_recents    ON public.inbound_batches    (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS leave_requests_recents     ON public.leave_requests     (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS materials_recents          ON public.materials          (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS medical_claims_recents     ON public.medical_claims     (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS output_batches_recents     ON public.output_batches     (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS payroll_periods_recents    ON public.payroll_periods    (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS pricing_formulas_recents   ON public.pricing_formulas   (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS processing_runs_recents    ON public.processing_runs    (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS purchase_orders_recents    ON public.purchase_orders    (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS quotes_recents             ON public.quotes             (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS sales_orders_recents       ON public.sales_orders       (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS stocktakes_recents         ON public.stocktakes         (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS suppliers_recents          ON public.suppliers          (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS tasks_recents              ON public.tasks              (updated_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS work_orders_recents        ON public.work_orders        (updated_by, updated_at DESC);

COMMIT;
