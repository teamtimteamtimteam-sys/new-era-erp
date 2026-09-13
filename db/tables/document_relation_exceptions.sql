-- db/tables/document_relation_exceptions.sql
-- ════════════════════════════════════════════════════════════════════════════
-- SEARCH-4(2026-09-13):**推导得出来、而【裁定】不显示**的那些关联 —— 逐条带理由
-- ════════════════════════════════════════════════════════════════════════════
--
-- 关联图由真外键推导(db/views/document_relations.sql),没有任何一张"要显示哪些
-- 表"的手写名单 —— 那正是裁定 ③ 要杀的东西。本表是它的【补集】,而补集必须小、
-- 必须逐条写明理由,否则它会长成同一份手写副本的另一个名字。
--
-- ★★★ 判据作用在【边】上,不作用在【对】上 —— 这一条是 SEARCH-4 §3.3 的实测教训
--   `expense_claims ↔ expenses` 经 finance_attachments 的桥是假的(XOR 作废),
--   而它经 expense_claims.expense_id 的直接外键是真的。**一支把整组关系一起删掉
--   的筛子会在这里安静地删掉一条真关系,而没有任何东西会红。**
--   ☞ 所以本表的键是 (owner_table, column_a, column_b):一条外键,或一张桥上的
--     两列 —— 不是一对表名。
--
-- ★ 本表里【没有】的三类,因为它们是推导出来的,不是声明出来的:
--   ① 查找表 / 行表    —— 按构造:节点只能是 document_types 登记的表;
--   ② XOR 作废的假桥   —— 按 num_nonnulls(…)=1 / <=1 与 (a IS NULL)<>(b IS NULL) 推导;
--   ③ 操作人列         —— 按构造:指向 employees 的 `*_by` / `user_id` 列不是关系
--                          (裁定 Q5)。实测它去掉 15 条噪音边、**一组关系都没少**。
--
-- ★ RLS:开着,SELECT 给 authenticated(USING true)—— document_relations 视图
--   以 INVOKER 身份读它,读不到就会【多显示】被裁掉的关系。
-- ★ 写:一条策略都不给。
-- ★ anon:不给。
--
-- 对应迁移:db/migrations/2026-09-13-search4a-document-relations.sql
-- 行为断言:db/fixtures/103-a-voided-bridge-does-not-void-a-real-relation.sql

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
