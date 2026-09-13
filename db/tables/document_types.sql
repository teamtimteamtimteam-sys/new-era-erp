-- db/tables/document_types.sql
-- ════════════════════════════════════════════════════════════════════════════
-- SEARCH-2b(2026-09-13):这套系统能铸的单据种类 —— **前缀是数据,不是字面量**
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【安装种子 / INSTALL SEED —— 逐行跟踪线上,check_mirrors.py 逐行比对】
-- 界面里没有任何地方写这张表:它由 44 支铸码函数【读】(document_type_prefix),
-- 由 search_documents / search_recents 读。加一种单据是迁移级动作,天生如此。
-- 【本表是迁移专属的】db/scripts/ 下的数据脚本永远不许写它。
--
-- ★★ RLS:开着,而 SELECT 是 USING (true) —— 而这条策略【是承重的】★★
--   9 支触发器铸码函数是 INVOKER(prosecdef=f,实测),生产上以 authenticated 跑。
--   没有这条策略,它们读不到前缀 —— 而 db/fixtures 以 postgres 跑
--   (rolbypassrls=t,RLS 被绕过),**门会一路绿,生产上铸码全部失败。**
--   这是门【按构造】看不见的那一格,所以它写在这里,也在切次报告里以
--   authenticated 真跑过一遍(带反面对照:撤掉策略,同一格当场红)。
--
-- ★ 写:一条策略都不给 —— 与 permissions / tax_codes / wht_rates 同一类。
-- ★ anon:不给。新表的默认权限里【没有】anon(pg_default_acl 实测:
--   postgres 在 public 上的默认权限只含 authenticated + service_role),
--   所以 db/anon-grants-baseline.tsv 一行都不用动。
--
-- 对应迁移:db/migrations/2026-09-13-search2b-document-types.sql(表 + 种子 + 44 支函数体)
--           db/migrations/2026-09-13-search2d-search-functions.sql(view_permission 列)
-- 行为断言:db/fixtures/100-every-document-code-still-mints-identically.sql

CREATE TABLE public.document_types (
    key           text PRIMARY KEY,
    prefix        text NOT NULL UNIQUE,
    table_name    text NOT NULL,
    -- ★ T1:两套编号语义都留,存成这一列。收敛任何一边都会改掉那一边的输出,
    --   而那正是停止条件 (g)。'gapless' = MAX(split_part)+1(号码之间没有洞);
    --   'gapped'  = nextval(回滚不还号 —— 线上已经烧掉 1,177 个号,实测)。
    numbering     text NOT NULL CHECK (numbering IN ('gapless', 'gapped')),
    sequence_name text,
    route         text NOT NULL,
    link_mode     text NOT NULL CHECK (link_mode IN ('detail', 'list', 'list_q')),
    label_column  text,
    match_columns text[] NOT NULL DEFAULT '{}'::text[],
    -- ★ SEARCH-2b · 迁移 D:这一类单据的【模块闸】,ANY 语义 ——
    --   一个码都不持有就一条都看不见。归属放宽项(module.tasks.view_all 之类)
    --   【不入列】:T4 明写「只数模块扣下的,不数归属扣下的」。
    --   由 db/fixtures/101 核对:每一个码都必须真的出现在该表 SELECT 策略的谓词里。
    view_permission text[] NOT NULL,
    -- 有洞的必须指名它那条序列;无洞的不许有 —— 一行自相矛盾的登记会让
    -- (g) 的期望值算在错的分支上,而那正是「suppliers 存着 0095、下一个是 0445」
    -- 那条实测要防的事。
    CONSTRAINT document_types_view_permission_present
        CHECK (cardinality(view_permission) > 0),
    CONSTRAINT document_types_sequence_shape CHECK (
        (numbering = 'gapped'  AND sequence_name IS NOT NULL) OR
        (numbering = 'gapless' AND sequence_name IS NULL))
);

COMMENT ON TABLE public.document_types IS
    'SEARCH-2:这套系统能铸的单据种类。前缀是数据,不是字面量(T1)。'
    '定义的是【能铸什么】,不是【铸过什么】—— 8 张今天还没有行的表照样在册。';

COMMENT ON COLUMN public.document_types.view_permission IS
    '这一类单据的【模块闸】:ANY 语义 —— 一个码都不持有就一条都看不见。'
    '归属放宽项(module.tasks.view_all 之类)不入列。由 db/fixtures 核对:'
    '每一个码都必须真的出现在该表 SELECT 策略的谓词里。';

ALTER TABLE public.document_types ENABLE ROW LEVEL SECURITY;

-- ★ 见抬头:没有这条策略,9 支 INVOKER 触发器在生产上读不到前缀,而 fixture
--   以 postgres 跑、rolbypassrls=t,一路绿。前缀不是秘密,读它没有门槛。
CREATE POLICY "document_types select by anyone signed in"
    ON public.document_types
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);

-- 写:一条策略都不给 —— 与 permissions / tax_codes / wht_rates 同一类
--（它们也都只有 SELECT 策略,实测)。改它要走迁移。
GRANT SELECT ON public.document_types TO authenticated;

-- ★★ anon 一格都不给 —— 而这一句【必须写在这里】,不是可以省略的谨慎 ★★
--   db/platform-prelude.sql 早就把这一幕预告了(它那段注释逐字写着):
--     「将来加一张表时会发生什么 —— 线上不会给它 anon,重建会给,于是门会报一处
--       漂移,而修法是【在那张表的镜像里写一句 REVOKE】。那正是我们要的:
--       一张新表对匿名开不开,必须有人写下来。」
--   本刀实测到的就是这一幕:迁移 B 之后整门报 2 处漂移,两处都是
--   document_types 的 anon 授权(table_grants + column_grants),【只在重建那一侧】。
--   原因不在迁移里:线上建表走 postgres 在 public 上的默认权限,而那一组
--   **不含 anon**(pg_default_acl 实测);prelude 为了重现平台基座,写的是
--   `ALTER DEFAULT PRIVILEGES … TO anon, authenticated, service_role`。
--   ☞ 所以线上一个字都不用改(它本来就没给),要写下来的是【这个决定】。
--   ☞ 而 db/anon-grants-baseline.tsv 一行都不用动:线上仍然是它的子集。
REVOKE ALL ON public.document_types FROM anon;

INSERT INTO public.document_types
    (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission)
VALUES
    ('assay_result', 'ASY', 'assay_results', 'gapless', NULL, '/inbound', 'list_q', 'notes', ARRAY['lab_name', 'certificate_ref', 'sample_ref', 'notes']::text[], ARRAY['module.inbound.view','module.output.view']::text[]),
    ('collection_chase', 'CHASE', 'collection_chases', 'gapless', NULL, '/sales/customers', 'list_q', NULL, '{}'::text[], ARRAY['module.finance.view']::text[]),
    ('cod', 'COD', 'certificates_of_destruction', 'gapless', NULL, '/output', 'list_q', 'void_reason', ARRAY['void_reason']::text[], ARRAY['action.issue_cod']::text[]),
    ('container', 'CTR', 'containers', 'gapless', NULL, '/logistics/containers', 'detail', 'notes', ARRAY['container_number', 'vessel', 'voyage', 'bl_number', 'notes']::text[], ARRAY['module.logistics.view']::text[]),
    ('credit_note', 'CN', 'credit_notes', 'gapless', NULL, '/finance/credit-notes', 'list', 'reason', ARRAY['reason']::text[], ARRAY['module.finance.view']::text[]),
    ('employee', 'EMP', 'employees', 'gapless', NULL, '/hr/employees', 'detail', 'legal_name', ARRAY['legal_name', 'preferred_name', 'notes']::text[], ARRAY['module.hr.view']::text[]),
    ('expense_claim', 'CLM', 'expense_claims', 'gapless', NULL, '/hr/claims', 'list', 'description', ARRAY['description', 'no_receipt_reason', 'decision_notes']::text[], ARRAY['module.finance.view']::text[]),
    ('fixed_asset', 'FA', 'fixed_assets', 'gapless', NULL, '/finance/assets', 'detail', 'description', ARRAY['description', 'category', 'notes']::text[], ARRAY['module.finance.view']::text[]),
    ('cash_forecast', 'FCST', 'cash_forecasts', 'gapless', NULL, '/finance/cash-forecast', 'list', NULL, '{}'::text[], ARRAY['module.finance.view']::text[]),
    ('leave_request', 'LV', 'leave_requests', 'gapless', NULL, '/hr/leave', 'detail', 'reason', ARRAY['reason', 'certificate_ref', 'decision_notes']::text[], ARRAY['module.hr.view']::text[]),
    ('medical_claim', 'MC', 'medical_claims', 'gapless', NULL, '/hr/claims', 'list', 'description', ARRAY['description', 'receipt_ref', 'decision_notes']::text[], ARRAY['module.hr.view']::text[]),
    ('payroll_period', 'PAY', 'payroll_periods', 'gapless', NULL, '/hr/payroll', 'detail', 'notes', ARRAY['source_note', 'notes']::text[], ARRAY['module.hr.view']::text[]),
    ('pricing_formula', 'PF', 'pricing_formulas', 'gapless', NULL, '/tools/pricing/formulas', 'list', 'name', ARRAY['name', 'notes']::text[], ARRAY['module.pricing.view']::text[]),
    ('purchase_order', 'PO', 'purchase_orders', 'gapless', NULL, '/purchasing/orders', 'detail', 'notes', ARRAY['terms_text', 'notes', 'delivery_location']::text[], ARRAY['module.purchasing.view']::text[]),
    ('quote', 'QT', 'quotes', 'gapless', NULL, '/sales/quotes', 'detail', 'notes', ARRAY['terms_text', 'notes', 'decline_reason']::text[], ARRAY['module.sales.view']::text[]),
    ('sales_order', 'SO', 'sales_orders', 'gapless', NULL, '/sales/orders', 'detail', 'notes', ARRAY['terms_text', 'notes', 'cancel_reason']::text[], ARRAY['module.sales.view']::text[]),
    ('shipment', 'SHP', 'shipments', 'gapless', NULL, '/sales/shipments', 'detail', 'notes', ARRAY['notes']::text[], ARRAY['module.sales.view']::text[]),
    ('customer_statement', 'STMT', 'customer_statements', 'gapless', NULL, '/sales/customers', 'list_q', NULL, '{}'::text[], ARRAY['module.finance.view']::text[]),
    ('traceability_report', 'TRC', 'traceability_report_issues', 'gapless', NULL, '/output', 'list_q', NULL, '{}'::text[], ARRAY['module.sales.view','module.processing.view']::text[]),
    ('work_order', 'WO', 'work_orders', 'gapless', NULL, '/operation/orders', 'detail', 'notes', ARRAY['notes', 'close_reason']::text[], ARRAY['module.processing.view']::text[]),
    ('contract', 'CON', 'contracts', 'gapped', 'contract_code_seq', '/contracts', 'list', NULL, '{}'::text[], ARRAY['module.customers.view','module.suppliers.view']::text[]),
    ('customer', 'CUS', 'customers', 'gapped', 'customer_code_seq', '/sales/customers', 'detail', 'legal_name', ARRAY['legal_name', 'short_name', 'address', 'country', 'tax_id', 'notes']::text[], ARRAY['module.customers.view']::text[]),
    ('inbound_batch', 'IN', 'inbound_batches', 'gapped', 'inbound_code_seq', '/inbound', 'list_q', 'notes', ARRAY['notes', 'import_permit_ref', 'source_reason_note']::text[], ARRAY['module.inbound.view']::text[]),
    ('material', 'MAT', 'materials', 'gapped', 'material_code_seq', '/materials', 'list_q', 'name', ARRAY['name', 'chemistry', 'spec', 'notes']::text[], ARRAY['module.materials.view']::text[]),
    ('output_batch', 'OUT', 'output_batches', 'gapped', 'output_code_seq', '/output', 'list_q', 'notes', ARRAY['purity', 'notes']::text[], ARRAY['module.output.view']::text[]),
    ('processing_run', 'PROC', 'processing_runs', 'gapped', 'processing_code_seq', '/operation/processing', 'detail', 'notes', ARRAY['notes']::text[], ARRAY['module.processing.view']::text[]),
    ('stocktake', 'ST', 'stocktakes', 'gapped', 'stocktake_code_seq', '/stocktakes', 'detail', 'notes', ARRAY['notes']::text[], ARRAY['module.stocktakes.view']::text[]),
    ('supplier', 'SUP', 'suppliers', 'gapped', 'supplier_code_seq', '/suppliers', 'list_q', 'legal_name', ARRAY['legal_name', 'short_name', 'address', 'country', 'tax_id', 'notes']::text[], ARRAY['module.suppliers.view']::text[]),
    ('task', 'TASK', 'tasks', 'gapped', 'task_code_seq', '/tools/tasks', 'detail', 'title', ARRAY['title', 'description']::text[], ARRAY['module.tasks.view']::text[]),
    ('invoice', 'INV', 'invoices', 'gapless', NULL, '/finance/invoices', 'detail', 'notes', ARRAY['notes', 'terms_text', 'void_reason']::text[], ARRAY['module.finance.view']::text[]),
    ('management_pack', 'PACK', 'management_packs', 'gapless', NULL, '/finance/packs', 'detail', NULL, '{}'::text[], ARRAY['module.finance.view']::text[]),
    ('bank_statement', 'BS', 'bank_statements', 'gapless', NULL, '/finance/bank/statements', 'detail', 'notes', ARRAY['file_name', 'notes']::text[], ARRAY['module.finance.view']::text[]),
    ('attendance_period', 'ATT', 'attendance_periods', 'gapless', NULL, '/hr/attendance', 'list', NULL, '{}'::text[], ARRAY['module.hr.view']::text[]),
    ('gst_period', 'GST', 'gst_periods', 'gapless', NULL, '/finance/gst', 'list', NULL, '{}'::text[], ARRAY['module.finance.view']::text[]),
    ('journal_entry', 'JE', 'journal_entries', 'gapless', NULL, '/finance/journal', 'detail', 'memo', ARRAY['memo']::text[], ARRAY['module.finance.view']::text[]),
    ('expense', 'EXP', 'expenses', 'gapless', NULL, '/finance/expenses', 'detail', 'notes', ARRAY['payee_name', 'notes']::text[], ARRAY['module.finance.view']::text[]),
    ('freight_document', 'FRT', 'freight_documents', 'gapless', NULL, '/finance/freight', 'detail', 'notes', ARRAY['notes', 'reversal_reason']::text[], ARRAY['module.inbound.view','module.finance.view']::text[]),
    ('wht_remittance', 'WHT', 'wht_remittances', 'gapless', NULL, '/finance/wht', 'list', NULL, '{}'::text[], ARRAY['module.finance.view']::text[]),
    ('payment_receipt', 'RCPT', 'payments', 'gapless', NULL, '/finance/payments', 'detail', 'notes', ARRAY['notes']::text[], ARRAY['module.finance.view']::text[]),
    ('payment_out', 'PMT', 'payments', 'gapless', NULL, '/finance/payments', 'detail', 'notes', ARRAY['notes']::text[], ARRAY['module.finance.view']::text[]);
