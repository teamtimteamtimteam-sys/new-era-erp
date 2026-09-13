-- db/views/document_relations.sql
-- ════════════════════════════════════════════════════════════════════════════
-- SEARCH-4(2026-09-13):关联图 —— **从真外键推导,不是一份手写的副本**
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【为什么是视图,不是表】(Q14)一张物化的关系表就是裁定 ③ 点名要杀的那份手写
-- 副本:它在写下来那天与线上一致,之后悄悄分开。这张视图 SELECT 自 pg_constraint
-- —— **它按定义不可能与线上不一致,因为它就是线上**。新表带上真外键的那一刻,
-- 它自动进入关联搜索,一行代码都不用改。
--   实测(SET LOCAL ROLE authenticated 的回滚事务里):authenticated 读得到
--   pg_constraint(397 条)、document_types(40 行)、pg_get_constraintdef。
--
-- ── 形状,一句话(SEARCH-4 §2 的裁定)────────────────────────────────────────
--   **节点只能是 document_types 登记的 39 张表;非单据表只能当边,不能当端点。**
--   一跳 = 单据 →(0 或 1 张非单据表)→ 单据。
--   ☞ 这一句按构造同时消掉两种噪音:查找表不是单据(一张发票不会"关联"到一行
--     SGD),行表不是单据(PO 不会"关联" 4 条 purchase_order_lines —— 那是它
--     自己的内脏)。**不需要一张"不要显示这些表"的名单。**
--
-- ── 四条筛子,三条推导、一条声明 ────────────────────────────────────────────
--   ① 端点必须登记          —— 推导(document_types)
--   ② XOR 型 CHECK 作废假桥 —— 推导。两种写法都认:
--        `num_nonnulls(a,b,…) = 1` / `<= 1`,以及 `(a IS NULL) <> (b IS NULL)`。
--        ★ 只认 num_nonnulls 的解析器会把 inventory_movements / stocktake_lines
--          整组放过去,而那正好是 inbound_batches ↔ output_batches 这组假关联。
--        实测 19 条 XOR 型 CHECK,分布 19 张表,作废 24 条桥边 / 净减 14 组关系。
--   ③ 操作人列不是关系      —— 推导(Q5)。指向 employees 的 `*_by` / `user_id`。
--        ★ 判据里的「指向 employees」是承重的:`superseded_by` / `reversed_by`
--          也以 _by 结尾,而它们指向【同一张单据表】,是作废/冲销链,要显示。
--        实测:去掉 15 条噪音边,**一组关系都没少**(employees ↔ tasks 经
--        task_participants(employee_id, task_id) 照样在)。
--   ④ document_relation_exceptions —— 声明,逐条带理由,**键是边不是对**。
--
-- ⚠ 本视图【不含】多态列(subject_type/source_id 那 4 对)—— Q11 裁定不进这一刀,
--   「类型串 → 表名」那张映射立案为一条声明,不是一个黑箱。
--
-- 对应迁移:db/migrations/2026-09-13-search4a-document-relations.sql
-- 读它的:  db/functions/search_related.sql

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
