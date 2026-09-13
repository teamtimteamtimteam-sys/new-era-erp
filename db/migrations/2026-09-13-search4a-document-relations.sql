-- SEARCH-4 · 迁移 A —— 关联记录:关系图(视图)+ 计数函数 + 两张例外表
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【这一刀在做什么】搜 "Acme" 今天返回一条供应商命中,然后就没了 —— 而屏幕上
-- 的进料列表里明明写着 "Acme…"。这支迁移让那一条命中**带着它的关联记录**:
--   Acme Battery Recycling Pte Ltd
--     进料批 11 →   付款 8 →   采购单 4 →   支出 3 →
-- **按目标单据种类分组,每组一行一个计数,不展开行**(裁定 Q7)。
-- 理由不是省地方:**一个分组行答得出「这个供应商现在什么情况」,而 11 行批号
-- 答不出** —— 那正是 Tim 否掉小改法的那句话。
--
-- 【形状,一句话】节点 = document_types 登记的 39 张表;非单据表只当边,
-- 不当端点。一跳 = 单据 →(0 或 1 张非单据表)→ 单据。详见视图抬头。
--
-- 【四件东西,而只有一件是"名单"】
--   1. document_type_exceptions      —— 有 code 列却不是单据的 36 张,逐张带理由
--                                       (承重的是那道构建闸,见下)
--   2. document_relation_exceptions  —— 推导得出来而裁定不显示的 6 条边,带理由
--   3. document_relations(视图)     —— 关系图,SELECT 自 pg_constraint(Q14:
--                                       **不要建表** —— 物化的关系表就是裁定 ③
--                                       点名要杀的那份手写副本)
--   4. search_related()              —— INVOKER 的分组计数(Q13)
--
-- ★★ 为什么这一刀非要顺手补那道【新表必须登记】的闸(Q16)★★
--   关联图的节点集**就是** document_types。于是一张没有登记的新单据表,
--   不只是搜不到它自己 —— **所有指向它的关联边会一起安静地消失**。
--   漏登记一次,漏掉的不是一条结果,是一片边。
--   闸在 scripts/check-document-registry.mjs,跑在 npm run build 里;
--   它自己的覆盖是两条独立的断言,并且已经故意红过五次(切次报告 §5)。
--
-- 【破窗】★ 纯增量,而且是【良性】的那一族(与 SEARCH-2b 的迁移 A / C / D 同族,
--   **不与迁移 B 同族**):两张新表、一张新视图、一支新函数。
--   **旧代码看不见它们,也不调用它们** —— 窗口里生产跑的是旧代码 + 新库,
--   而新库多出来的每一样东西旧代码都够不到。窗口期间坏掉的东西:**没有**。
--   ⚠ 这一行是必填字段,不许写"无",见 AGENTS.md「破窗时长是切次报告的一个
--     必填字段」。时长与影响都写在 docs/handbacks/SEARCH-4.md。
--
-- 镜像:db/tables/document_type_exceptions.sql · db/tables/document_relation_exceptions.sql
--       db/views/document_relations.sql · db/functions/search_related.sql
-- 行为断言:db/fixtures/102-a-code-bearing-table-is-registered-or-excepted.sql
--           db/fixtures/103-a-voided-bridge-does-not-void-a-real-relation.sql

BEGIN;

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

CREATE TABLE public.document_relation_exceptions (
    -- 持有这条边的那张表:直接外键 = 外键所在的表;桥 = 桥表本身。
    owner_table text NOT NULL,
    column_a    text NOT NULL,
    -- 桥的第二列。直接外键写 ''(空串),不是 NULL —— 它进主键。
    column_b    text NOT NULL DEFAULT '',
    reason      text NOT NULL,
    CONSTRAINT document_relation_exceptions_pkey PRIMARY KEY (owner_table, column_a, column_b),
    CONSTRAINT document_relation_exceptions_reason_present CHECK (btrim(reason) <> ''),
    -- 一条边不许写成它自己的对称:桥的两列取字典序小的在前,于是
    -- (a,b) 与 (b,a) 不会各写一行、各带一句不一样的理由。
    CONSTRAINT document_relation_exceptions_ordered
        CHECK (column_b = '' OR column_a < column_b)
);

COMMENT ON TABLE public.document_relation_exceptions IS
    'SEARCH-4:推导得出来、而裁定不显示的关联,逐条带理由。'
    '键是【边】不是【对】—— 一支作用在对上的筛子会删掉真关系而不吭声(§3.3)。';

ALTER TABLE public.document_relation_exceptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY document_relation_exceptions_select ON public.document_relation_exceptions
    FOR SELECT TO authenticated USING (true);

-- ★ anon 明写收掉 —— 表有 RLS 挡着,但 B1 判的是【拿不拿得到】,
--   而重建出来的库与线上的默认权限不是同一份(见 document_relations.sql)。
REVOKE ALL ON public.document_relation_exceptions FROM anon;
GRANT SELECT ON public.document_relation_exceptions TO authenticated;

-- ── 种子:6 条,每一条各有一份出处 ──────────────────────────────────────────
INSERT INTO public.document_relation_exceptions (owner_table, column_a, column_b, reason) VALUES
    -- ① Q10 —— 页面已经做过相反的决定,而搜索不比页面松
    ('containers', 'forwarder_id', '',
     'LOG-1b:货代不进供应商名单(他们保留 supplier id 只为账上那条链)。'
     'app/inbound/inboundQuery.ts 把货代刻意排除在供应商之外 —— 页面裁过一次,搜索照它。'),
    -- ② Q4 —— 11 条自指边共用一个形状,机器分不开;这一条靠声明,不靠启发式
    ('employees', 'manager_id', '',
     'Q4:自指边显示【作废/冲销链】。"这张单据被哪一张作废了"该显示,'
     '"这个员工的上级是谁"是另一回事 —— 11 条自指边共用一个形状,机器分不开,所以这里写一个字。'),
    -- ③④⑤⑥ Q3 的残渣 —— XOR 筛不掉的三组噪音,逐【边】点名
    ('purchase_order_lines', 'asset_id', 'pricing_formula_id',
     'Q3 残渣:同一张桥上两列都可空、又没有 XOR,于是"某固定资产关联某计价公式"'
     '只是同一张采购单行上碰巧同时出现 —— 不是一条关系。'),
    ('equipment_maintenance', 'capitalised_expense_id', 'expense_id',
     'Q3 残渣:一次维修的费用行与它资本化后的那一行,是同一件事的两条记账,'
     '不是"这笔支出关联那笔支出"。★ 注意 expenses ↔ expenses 这一【对】照样成立 —— '
     'expenses.reversed_by_expense 是真的冲销链(§3.3 的教训:筛边,不筛对)。'),
    ('performance_reviews', 'employee_id', 'reviewer_employee_id',
     'Q3 残渣:考核人是这次考核的【参与方】,不是被考核人的一条关联单据。'),
    ('shift_handovers', 'incoming_employee_id', 'outgoing_employee_id',
     'Q3 残渣:交接班的上下家是同一张交接单的两端,不是"这个员工关联那个员工"。')
ON CONFLICT (owner_table, column_a, column_b) DO NOTHING;

CREATE OR REPLACE VIEW public.document_relations AS
WITH doc AS (
    SELECT DISTINCT table_name FROM public.document_types
),
fk AS (
    -- 单列外键,public → public。多列外键不参与:一条关联边要能写成一个等值
    -- 条件,而多列的写不成 —— 今天 public 里一条这样的跨单据外键都没有。
    SELECT st.relname::text  AS src,
           sa.attname::text  AS srccol,
           tt.relname::text  AS tgt,
           ta.attname::text  AS tgtcol
      FROM pg_constraint c
      JOIN pg_class     st ON st.oid = c.conrelid
      JOIN pg_namespace sn ON sn.oid = st.relnamespace
      JOIN pg_class     tt ON tt.oid = c.confrelid
      JOIN pg_namespace tn ON tn.oid = tt.relnamespace
      JOIN pg_attribute sa ON sa.attrelid = c.conrelid  AND sa.attnum = c.conkey[1]
      JOIN pg_attribute ta ON ta.attrelid = c.confrelid AND ta.attnum = c.confkey[1]
     WHERE c.contype = 'f'
       AND sn.nspname = 'public' AND tn.nspname = 'public'
       AND array_length(c.conkey, 1) = 1
),
-- ③ 操作人列:指向 employees 的 `*_by` / `user_id`
actor AS (
    SELECT src, srccol FROM fk
     WHERE tgt = 'employees' AND srccol ~ '(_by|user_id)$'
),
-- ② XOR 型 CHECK 的两种写法
checkdef AS (
    SELECT t.relname::text AS tbl, pg_get_constraintdef(c.oid) AS def
      FROM pg_constraint c
      JOIN pg_class     t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
     WHERE c.contype = 'c' AND n.nspname = 'public'
),
xor_cols AS (
    SELECT tbl, btrim(unnest(string_to_array(cols, ','))) AS col
      FROM (
        SELECT tbl, (regexp_match(def, 'num_nonnulls\(([^)]*)\)\s*(?:=|<=)\s*1'))[1] AS cols
          FROM checkdef WHERE def ~ 'num_nonnulls\([^)]*\)\s*(?:=|<=)\s*1'
        UNION ALL
        SELECT tbl, (regexp_match(def, '\(([a-z_]+) IS NULL\) <> \(([a-z_]+) IS NULL\)'))[1] || ',' ||
                    (regexp_match(def, '\(([a-z_]+) IS NULL\) <> \(([a-z_]+) IS NULL\)'))[2]
          FROM checkdef WHERE def ~ '\([a-z_]+ IS NULL\) <> \([a-z_]+ IS NULL\)'
      ) s
),
xor_pair AS (
    SELECT DISTINCT a.tbl, a.col AS c1, b.col AS c2
      FROM xor_cols a JOIN xor_cols b ON a.tbl = b.tbl AND a.col <> b.col
),
edges AS (
    -- 出边:这张单据的一列指着对方 —— 按构造最多 1 条
    SELECT f.src AS from_table, f.srccol AS from_column,
           NULL::text AS via_table, NULL::text AS via_from_column, NULL::text AS via_to_column,
           f.tgt AS to_table, f.tgtcol AS to_column,
           'out'::text AS kind,
           f.src AS owner_table, f.srccol AS owner_column_a, ''::text AS owner_column_b
      FROM fk f
     WHERE f.src IN (SELECT table_name FROM doc)
       AND f.tgt IN (SELECT table_name FROM doc)
       AND (f.src, f.srccol) NOT IN (SELECT src, srccol FROM actor)

    UNION ALL

    -- 入边:对方的一列指着这张单据 —— 按构造是【一叠】
    SELECT f.tgt, f.tgtcol,
           NULL::text, NULL::text, NULL::text,
           f.src, f.srccol,
           'in'::text,
           f.src, f.srccol, ''::text
      FROM fk f
     WHERE f.src IN (SELECT table_name FROM doc)
       AND f.tgt IN (SELECT table_name FROM doc)
       AND (f.src, f.srccol) NOT IN (SELECT src, srccol FROM actor)

    UNION ALL

    -- 桥边:一张非单据表同时指着两张单据 —— 36 组关系【只】存在于这里
    SELECT f1.tgt, f1.tgtcol,
           f1.src, f1.srccol, f2.srccol,
           f2.tgt, f2.tgtcol,
           'bridge'::text,
           f1.src, least(f1.srccol, f2.srccol), greatest(f1.srccol, f2.srccol)
      FROM fk f1
      JOIN fk f2 ON f2.src = f1.src AND f2.srccol <> f1.srccol
     WHERE f1.src NOT IN (SELECT table_name FROM doc)
       AND f1.tgt IN (SELECT table_name FROM doc)
       AND f2.tgt IN (SELECT table_name FROM doc)
       AND (f1.src, f1.srccol) NOT IN (SELECT src, srccol FROM actor)
       AND (f2.src, f2.srccol) NOT IN (SELECT src, srccol FROM actor)
       AND NOT EXISTS (
             SELECT 1 FROM xor_pair x
              WHERE x.tbl = f1.src AND x.c1 = f1.srccol AND x.c2 = f2.srccol)
)
SELECT e.from_table, e.from_column,
       e.via_table, e.via_from_column, e.via_to_column,
       e.to_table, e.to_column,
       e.kind,
       e.owner_table, e.owner_column_a, e.owner_column_b
  FROM edges e
 WHERE NOT EXISTS (
         SELECT 1 FROM public.document_relation_exceptions x
          WHERE x.owner_table   = e.owner_table
            AND x.column_a      = e.owner_column_a
            AND x.column_b      = e.owner_column_b);

COMMENT ON VIEW public.document_relations IS
    'SEARCH-4:单据↔单据的关联图,由 pg_constraint 现算。'
    '节点 = document_types 登记的表;非单据表只当边。XOR 型 CHECK 作废假桥;'
    '指向 employees 的 *_by / user_id 是操作人不是关系;其余裁定在 '
    'document_relation_exceptions 里逐条带理由。';


-- ★★【REVOKE,而它【必须住在镜像里】—— 这一条是门当场抓到的】★★
--   db/gate.py --offline 第一次跑就红了:fixture 196 的 B1 报
--   「匿名请求从 337 个关系里读到了行:document_relations(254)」。
--   ☞ 线上实测 anon **拿不到**这张视图(`pg_default_acl` 里 postgres 在 public
--     上的默认权限不含 anon);而**重建出来的那个库里它拿得到** —— 两处的
--     默认权限不是同一份。**一个只在线上成立的收口不是收口。**
--   ☞ 而 collection_promise_status.sql 早就把这一课写下来了,逐字可抄:
--     「一条只住在迁移里的 REVOKE,重建出来的库【是开着的】。」
--   ⚠ 视图没有 RLS —— 两张例外表有策略挡着,这张【只有 GRANT 这一层】。
REVOKE ALL ON public.document_relations FROM anon;
GRANT SELECT ON public.document_relations TO authenticated;

CREATE OR REPLACE FUNCTION public.search_related(p_key text, p_id uuid)
 RETURNS TABLE(target_key text, target_table text, route text, link_mode text, n bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_table  text;
    v_rows   jsonb := '[]'::jsonb;
    r        record;
    e        record;
    parts    text[];
    v_where  text;
    v_n      bigint;
BEGIN
    IF p_key IS NULL OR p_id IS NULL THEN
        RETURN;
    END IF;

    SELECT d.table_name INTO v_table FROM public.document_types d WHERE d.key = p_key;
    IF v_table IS NULL THEN
        -- 与 document_type_prefix() 同一条:读不到就响,不要静默返回空。
        -- 一个"这张单据没有关联记录"的空态,和一个拼错的 key,在屏幕上长得一模一样。
        RAISE EXCEPTION 'SEARCH_UNKNOWN_DOCUMENT_TYPE|% —— 它不在 document_types 里,'
                        '而一次拼错的 key 与一张真的没有关联的单据在屏幕上分不开', p_key;
    END IF;

    FOR r IN
        SELECT d.key, d.table_name, d.route, d.link_mode, d.prefix,
               (SELECT count(*) > 1 FROM public.document_types d2
                 WHERE d2.table_name = d.table_name) AS shared
          FROM public.document_types d
         WHERE EXISTS (SELECT 1 FROM public.document_relations dr
                        WHERE dr.from_table = v_table AND dr.to_table = d.table_name)
         ORDER BY d.key
    LOOP
        parts := '{}';
        FOR e IN
            SELECT * FROM public.document_relations dr
             WHERE dr.from_table = v_table AND dr.to_table = r.table_name
        LOOP
            IF e.kind = 'bridge' THEN
                parts := parts || format(
                    'SELECT t.id, t.code FROM public.%I v JOIN public.%I t ON t.%I = v.%I '
                    ' WHERE v.%I = (SELECT s.%I FROM public.%I s WHERE s.id = $1)',
                    e.via_table, e.to_table, e.to_column, e.via_to_column,
                    e.via_from_column, e.from_column, e.from_table);
            ELSE
                -- 出边与入边在这里是【同一个形状】:出边的 from_column 是本表那一列,
                -- 入边的 from_column 是被指向的那一列(几乎总是 id)。
                parts := parts || format(
                    'SELECT t.id, t.code FROM public.%I t '
                    ' WHERE t.%I = (SELECT s.%I FROM public.%I s WHERE s.id = $1)',
                    e.to_table, e.to_column, e.from_column, e.from_table);
            END IF;
        END LOOP;

        CONTINUE WHEN cardinality(parts) = 0;

        v_where := 'TRUE';
        -- 一张表两个前缀(payments = RCPT + PMT):不加前缀过滤,同一条关联会在
        -- 两种单据下各数一次。与 search_documents_sql() 逐字同一条理由。
        IF r.shared THEN
            v_where := v_where || format(' AND u.code LIKE %L', r.prefix || '-%');
        END IF;
        -- 自指关系不把自己算成自己的关联记录。
        IF r.table_name = v_table THEN
            v_where := v_where || ' AND u.id <> $1';
        END IF;

        EXECUTE format(
            'SELECT count(*) FROM (SELECT DISTINCT u.id FROM (%s) u (id, code) WHERE %s) z',
            array_to_string(parts, E'\nUNION ALL\n'), v_where)
          INTO v_n USING p_id;

        -- 0 组不返回:「这张单据没有关联记录」由应用层画,而不是画 39 行 0。
        CONTINUE WHEN v_n = 0;

        v_rows := v_rows || jsonb_build_object(
            'target_key', r.key, 'target_table', r.table_name,
            'route', r.route, 'link_mode', r.link_mode, 'n', v_n);
    END LOOP;

    RETURN QUERY
    SELECT x->>'target_key', x->>'target_table', x->>'route', x->>'link_mode',
           (x->>'n')::bigint
      FROM jsonb_array_elements(v_rows) x
     ORDER BY (x->>'n')::bigint DESC, x->>'target_key';
END;
$function$;

COMMENT ON FUNCTION public.search_related(text, uuid) IS
    'SEARCH-4:一条命中带出来的关联记录,**按目标单据种类分组,每组一个计数**。'
    'INVOKER —— 数的是"你看得见几条"(Q13)。行不取回来:一个分组行答得出'
    '"这个供应商现在什么情况",而 11 行批号答不出。';

-- ★ EXECUTE 的授权【不写在这里】:db/views/zzz_function_grants.sql 是那一条的
--   唯一出处(先 REVOKE FROM PUBLIC, anon，再 GRANT ON ALL FUNCTIONS TO
--   authenticated, service_role)。在这里再写一遍就是第二份真相 ——
--   而 search_documents / search_recents 四支的镜像里也都没有它。
--   ⚠ 迁移那一侧【显式写了】:一支刚建出来的函数拿的是默认权限，
--     而「默认多半是对的」正是本刀在 document_relations 上刚栽过的那一跮。

-- ★ 函数的 EXECUTE:显式写,不靠默认。
--   实测线上五支 search_* 的 proacl 都是 `postgres | authenticated | service_role`
--   (没有 PUBLIC),所以【多半】不写也对 —— 而本刀刚刚因为同一句「多半」在
--   document_relations 上被 fixture 196 的 B1 当场抓到:重建出来的库与线上的
--   默认权限不是同一份。☞ 重建那一侧由 db/views/zzz_function_grants.sql 兜底,
--   线上这一侧由下面这两行兜底,两边都不靠默认。
REVOKE EXECUTE ON FUNCTION public.search_related(text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.search_related(text, uuid) TO authenticated, service_role;

COMMIT;
