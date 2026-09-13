-- SEARCH-2 · 迁移 A —— pg_trgm,单独一支,先于一切依赖它的东西
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【Tim 的 T2】装 pg_trgm 并给 code 建 GIN,买下【后缀匹配】(`0001`)——
-- btree 结构上【seek 不了】一个后缀。
--
-- ★★【一条要写下来的更正:btree 【能】服务 %0001,只是不能 seek】★★
--   委托书说 btree「structurally cannot serve」后缀匹配。**实测不是这样。**
--   在 journal_entries(80 行)上,`SET enable_seqscan=off` 之后规划器选的是
--   **`journal_entries_code_key` —— 那条 btree UNIQUE 索引**,走 Bitmap Index Scan
--   (全索引扫 + recheck)。它服务得了,只是不是一次 seek。
--   ☞ **一次"强制走索引"的 EXPLAIN 会证明错的东西** —— 它会显示"索引被用上了",
--     而用上的正是那条据说不能用的 btree。真话是:**btree 不能 seek 一个后缀。**
--
-- ★★【而这一支在【今天的数据上】买不到任何可测量的东西 —— 这是 Tim 知情买下的】★★
--   实测(回滚掉的事务里真的建了扩展与索引):
--     · 最大的单据表 journal_entries = **80 行**;31 张表合计 **319 行**;
--     · 默认计划:**Seq Scan** —— 规划器在这个体量上【永远】不会选索引;
--     · 合成 200,000 行:默认计划变成 **Bitmap Index Scan on 合成的 trgm 索引**,
--       **12.0ms vs 强制 seq scan 33.4ms(2.8×)**。
--   ☞ 所以这句话要原样写下来,它是这次采购的理由本身:
--     **pg_trgm 在今天 319 行上买不到任何可测量的东西;装它是为了让 job ① 在数据
--     长起来的时候【不必重写】。** 而**标签列将来也需要同样的处理,那不是这一刀的事**
--     —— 已立案,没有建。
--
-- 【为什么装在 extensions 架构】线上既有的三个扩展都在那里
-- (pgcrypto · uuid-ossp · pg_stat_statements,实测)。不新开一个惯例。
--
-- ★★【它同时要进 db/platform-prelude.sql —— 否则门退 2】★★
--   实测:`db/migrations/` 与 prelude 里**今天一个 CREATE EXTENSION 都没有**,
--   pg_trgm 会是这个仓库自己装的第一个扩展。而 `db/verify_rebuild.py` 从 prelude
--   建库 —— prelude 不提供它,重建会在建索引那一步失败,判词【可重建性】退 2。
--   AGENTS.md:prelude 是「镜像期待平台提供什么」的唯一书面记录。
--
-- 【破窗】本支是**纯增量**:装一个扩展 + 建 39 条索引。旧代码不读它们,
-- 也不可能被它们改变行为。**A 这一支的窗口是良性的**,而 B 不是 —— 见那一支的抬头。

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;

-- 单据表的 code 上各一条 trigram GIN —— 先是有行的那 31 张,再是空的那 8 张(见下)。
-- 【为什么不是 75 张】75 张带 code 列的表里,只有这些**真的铸单据码**
--   (实测:code 有 583 行,其中 274 行是单据形状、309 行是主数据的自由格式码)。
--   job ① 找的是单据,所以索引跟着单据走。
-- 【写成 IF NOT EXISTS 是为了让这一支可重放】—— 它不是"怕失败",
--   是让 verify_rebuild 的重建路径与线上走同一段文本。
CREATE INDEX IF NOT EXISTS assay_results_code_trgm              ON public.assay_results              USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS bank_statements_code_trgm            ON public.bank_statements            USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS certificates_of_destruction_code_trgm ON public.certificates_of_destruction USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS containers_code_trgm                 ON public.containers                 USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS credit_notes_code_trgm               ON public.credit_notes               USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS customers_code_trgm                  ON public.customers                  USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS employees_code_trgm                  ON public.employees                  USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS expense_claims_code_trgm             ON public.expense_claims             USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS expenses_code_trgm                   ON public.expenses                   USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS fixed_assets_code_trgm               ON public.fixed_assets               USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS freight_documents_code_trgm          ON public.freight_documents          USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS inbound_batches_code_trgm            ON public.inbound_batches            USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS invoices_code_trgm                   ON public.invoices                   USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS journal_entries_code_trgm            ON public.journal_entries            USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS leave_requests_code_trgm             ON public.leave_requests             USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS materials_code_trgm                  ON public.materials                  USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS medical_claims_code_trgm             ON public.medical_claims             USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS output_batches_code_trgm             ON public.output_batches             USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS payments_code_trgm                   ON public.payments                   USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS payroll_periods_code_trgm            ON public.payroll_periods            USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS pricing_formulas_code_trgm           ON public.pricing_formulas           USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS processing_runs_code_trgm            ON public.processing_runs            USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS purchase_orders_code_trgm            ON public.purchase_orders            USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS quotes_code_trgm                     ON public.quotes                     USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS sales_orders_code_trgm               ON public.sales_orders               USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS shipments_code_trgm                  ON public.shipments                  USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS stocktakes_code_trgm                 ON public.stocktakes                 USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS suppliers_code_trgm                  ON public.suppliers                  USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS tasks_code_trgm                      ON public.tasks                      USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS traceability_report_issues_code_trgm ON public.traceability_report_issues USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS work_orders_code_trgm                ON public.work_orders                USING gin (code extensions.gin_trgm_ops);

-- ★【另外 8 张:今天【一行单据都没有】,而它们的铸码函数是真的】★
--   实测:CHASE→collection_chases · FCST→cash_forecasts · STMT→customer_statements ·
--   CON→contracts · PACK→management_packs · ATT→attendance_periods ·
--   GST→gst_periods · WHT→wht_remittances —— 八张表都在,都带 code 列,只是还没有行。
--   ☞ Tim 的裁定:document_types 定义的是【这套系统能铸什么】,不是【它铸过什么】。
--     索引跟着同一条规矩走 —— 否则这 8 种单据第一次被开出来的那天,
--     它们是 39 张表里【唯独没有索引】的那几张,而没有人会注意到。
CREATE INDEX IF NOT EXISTS attendance_periods_code_trgm  ON public.attendance_periods  USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS cash_forecasts_code_trgm      ON public.cash_forecasts      USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS collection_chases_code_trgm   ON public.collection_chases   USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS contracts_code_trgm           ON public.contracts           USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS customer_statements_code_trgm ON public.customer_statements USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS gst_periods_code_trgm         ON public.gst_periods         USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS management_packs_code_trgm    ON public.management_packs    USING gin (code extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS wht_remittances_code_trgm     ON public.wht_remittances     USING gin (code extensions.gin_trgm_ops);

COMMIT;
