-- db/tables/document_type_exceptions.sql
-- ════════════════════════════════════════════════════════════════════════════
-- SEARCH-4(2026-09-13):有 `code` 列、但【不是一张单据表】的那些 —— 逐张带理由
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【为什么要这张表】SEARCH-4 的裁定 ③ 把关联搜索的【节点集】绑在 document_types
-- 上:一张没有登记的新单据表,不只是搜不到它自己 —— **所有指向它的关联边会一起
-- 安静地消失**。漏掉一次登记,漏掉的不是一条结果,是一片边。
--
-- ☞ 于是判据照 SEARCH-1 收紧后的 check-nav-routes 判据 ② 的形状写:
--   **public 里每一张有 `code` 列的表,要么在 document_types 里,要么在本表里
--   【带一句理由】,否则构建红。** 核对由 scripts/check-document-registry.mjs 做。
--
-- ★ 「有 code 列」本身不是判据 —— 实测 36 张有 code 列的表不是单据表
--   (accounts · currencies · material_forms · positions ……)。判据是
--   **"要么登记、要么例外"**,而例外必须写出理由。理由是这张表存在的全部意义:
--   一张只有表名的例外表,与一条 `-- TODO` 注释等价。
--
-- ★ RLS:开着,SELECT 给 authenticated(USING true)—— 与 document_types 同一条
--   理由的弱化版:本表不承重生产路径,但闸的 SQL 断言要读得到它。
-- ★ 写:一条策略都不给。加一行是迁移级动作,天生如此。
-- ★ anon:不给(新表默认权限里没有 anon,anon-grants-baseline.tsv 一行不动)。
--
-- 对应迁移:db/migrations/2026-09-13-search4a-document-relations.sql
-- 行为断言:db/fixtures/102-a-code-bearing-table-is-registered-or-excepted.sql

CREATE TABLE public.document_type_exceptions (
    table_name text PRIMARY KEY,
    -- ★ 一句话,而且它【不许为空】—— 这条 CHECK 是本表唯一承重的东西。
    --   一张能塞进空理由的例外表,就是一张"不要红"的名单。
    reason     text NOT NULL,
    CONSTRAINT document_type_exceptions_reason_present
        CHECK (btrim(reason) <> '')
);

COMMENT ON TABLE public.document_type_exceptions IS
    'SEARCH-4:有 code 列但不是单据表的那些,逐张带理由。'
    '判据在 scripts/check-document-registry.mjs —— 不在册、又不在这里,构建红。';

COMMENT ON COLUMN public.document_type_exceptions.reason IS
    '为什么它不是一张单据:一句话。空字符串被 CHECK 拒掉。';

ALTER TABLE public.document_type_exceptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY document_type_exceptions_select ON public.document_type_exceptions
    FOR SELECT TO authenticated USING (true);

-- ★ anon 明写收掉 —— 表有 RLS 挡着,但 B1 判的是【拿不拿得到】,
--   而重建出来的库与线上的默认权限不是同一份(见 document_relations.sql)。
REVOKE ALL ON public.document_type_exceptions FROM anon;
GRANT SELECT ON public.document_type_exceptions TO authenticated;

-- ── 种子:36 行,今天实测的全部 ─────────────────────────────────────────────
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
    ('accounts',                      '会计科目表:code 是科目号,它是一条【科目】不是一张单据'),
    ('battery_chemistries',           '电池化学体系的参考目录,进料/产出行引用它'),
    ('certificate_types',             '证书种类的参考目录,证书本身是别的表'),
    ('currencies',                    '币种目录:code 是 ISO 货币码'),
    ('deep_discharge_judgements',     '深放电判定的取值目录,进料检验行引用它'),
    ('departments',                   '组织架构的部门节点,不是一张开得出来的单据'),
    ('handover_item_types',           '交接班检查项的种类目录'),
    ('inbound_chemistry_certainties', '进料化学确定度的取值目录'),
    ('inbound_safety_states',         '进料安全状态的取值目录'),
    ('inbound_source_reasons',        '进料来源原因的取值目录'),
    ('kpi_organisation',              'KPI 组织树的节点,归属用,不是单据'),
    ('laboratories',                  '化验室名录:code 是实验室代号,化验单引用它'),
    ('leave_types',                   '假别目录:请假单(leave_requests)才是单据'),
    ('loss_categories',               '损耗分类目录,产出核算行引用它'),
    ('loss_metal_fates',              '损耗金属去向的取值目录'),
    ('material_forms',                '物料形态目录(粉/块/液……),物料与批次引用它'),
    ('material_kinds',                '物料大类目录'),
    ('material_size_formats',         '物料粒度/尺寸格式目录'),
    ('material_sources',              '物料来源目录'),
    ('metal_price_indices',           '金属价格指数的名录:code 是指数代号,不是一次报价'),
    ('operation_kinds',               '作业大类目录'),
    ('operation_types',               '作业类型目录,工单引用它'),
    ('output_batch_purposes',         '产出批用途的取值目录'),
    ('output_batch_states',           '产出批状态的取值目录'),
    ('payment_trigger_events',        '付款触发事件目录,付款条款行引用它'),
    ('permissions',                   '权限码目录:code 是权限码,它是这套闸自己的字母表'),
    ('ports',                         '港口名录:code 是港口代号,运输单据引用它'),
    ('positions',                     '岗位名录:code 是岗位代号,员工(employees)才是单据'),
    ('review_rating_scale',           '绩效评分标尺的取值目录'),
    ('roles',                         '角色目录:code 是角色码,与 permissions 同族'),
    ('shifts',                        '班次定义(早/中/夜):它是排班的参考行,不是一张单据'),
    ('storage_locations',             '库位名录:code 是库位号,库存移动引用它'),
    ('substances',                    '物质名录:code 是物质代号,危废分类引用它'),
    ('tax_codes',                     '税码目录:code 是税码,发票行与费用行引用它'),
    ('waste_classifications',         '危废分类目录:code 是分类代号'),
    ('wht_natures',                   '预扣税性质目录:wht_remittances 才是单据')
ON CONFLICT (table_name) DO NOTHING;
