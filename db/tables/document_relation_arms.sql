-- db/tables/document_relation_arms.sql
-- ════════════════════════════════════════════════════════════════════════════
-- SYSTEM-MAP-3(Tim 2026-10-27,裁定 2.4 (12) 与 SYSTEM-MAP-3 grilling 第 1 条):**外键推不出来的关联,逐条声明**
-- ════════════════════════════════════════════════════════════════════════════
--
-- 关联图由真外键推导(db/views/document_relations.sql)。四条单据链上有五对相邻的单据【没有外键】把它们连起来,
-- 而它们在业务上是同一件事的两步(SYSTEM-MAP-0 §3.1 · docs/surveys/SYSTEM-MAP-3/README.md 那张表):
--   ① 付款申请 ↔ 进料批(应付)—— 申请的核销对象存在 payment_requests.allocations 这个 jsonb 里;
--   ② 付款 ↔ 银行对账单       —— 付款 → 分录 → 分录行 ← 对账匹配 → 对账单行 → 对账单,隔着三张表;
--   ③ 考勤期间 ↔ 工资期间       —— 只共用一个 period_month;
--   ④ 加班批 ↔ 工资期间         —— 同上(只认【已批准】的批:驳回 / 作废 / 冲销的批一个小时都没进工资);
--   ⑤ 请假 ↔ 工资期间           —— 请假的日子落在那个月里(Tim Q3:只认【已批准】的请假;待批与驳回的请假没有工资那一头)。
-- (工资期间 ↔ 付薪分录【不在这里】:它有真外键 —— payroll_lines.paid_journal_entry_id 与 payroll_periods 的
--   cpf_journal_entry_id / deductions_journal_entry_id —— 勘察时当成"多态的 source_id"是一次误判,开工时量出来的。)
--
-- 本表一行 = 一条【有向】边(两个方向各一行),取数在 db/functions/document_relation_arm_ids.sql 里按 arm 的名字分支。
-- 关联图把它们并进来(kind = 'arm'),于是 search_related() / search_related_rows() / document_chain_walk() 与
-- 关联页、单据链条读的是【同一份】定义 —— 没有第二份手写的关系。
--
-- ★ 与 document_relation_exceptions 同一个形状:RLS 开着、SELECT 给 authenticated(document_relations 以视图
--   属主身份读它,而重建库与线上的默认权限不是同一份,所以授权写在这里)、写一条策略都不给、anon 不给。
-- ★ 加一条声明 = 一支迁移 + 本文件 + document_relation_arm_ids() 里那一支 + fixture 296 的那一对。
--
-- 对应迁移:db/migrations/2026-10-27-system-map-3-chain-bar.sql
-- 行为断言:db/fixtures/296-every-adjacent-pair-on-the-four-chains-links-both-ways.sql

CREATE TABLE public.document_relation_arms (
    arm        text PRIMARY KEY,
    from_table text NOT NULL,
    to_table   text NOT NULL,
    reason     text NOT NULL,
    CONSTRAINT document_relation_arms_reason_present CHECK (btrim(reason) <> ''),
    CONSTRAINT document_relation_arms_name_shape CHECK (arm ~ '^[a-z][a-z_]*$'),
    CONSTRAINT document_relation_arms_one_per_direction UNIQUE (from_table, to_table)
);

COMMENT ON TABLE public.document_relation_arms IS
    'SYSTEM-MAP-3:外键推不出来、而单据链上必须有的关联,逐条声明(每个方向一行)。'
    '取数在 document_relation_arm_ids(arm, id);document_relations 把它们并成 kind = ''arm'' 的边。';

ALTER TABLE public.document_relation_arms ENABLE ROW LEVEL SECURITY;

CREATE POLICY document_relation_arms_select ON public.document_relation_arms
    FOR SELECT TO authenticated USING (true);

REVOKE ALL ON public.document_relation_arms FROM anon;
GRANT SELECT ON public.document_relation_arms TO authenticated;

-- ── 种子:5 条关联 × 两个方向 = 10 行 ──────────────────────────────────────────
INSERT INTO public.document_relation_arms (arm, from_table, to_table, reason) VALUES
    ('payment_request_to_inbound_batch', 'payment_requests', 'inbound_batches',
     '付款申请核销的进料批存在 payment_requests.allocations(jsonb)里 —— 没有外键;单据链「应付 → 付款申请」那一对。'),
    ('inbound_batch_to_payment_request', 'inbound_batches', 'payment_requests',
     '上一条的反方向:一批货(它的应付)被哪几张付款申请核销过。'),
    ('payment_to_bank_statement', 'payments', 'bank_statements',
     '一笔付款的分录行被对账单上哪一行匹配了:payments.journal_entry_id → journal_lines ← bank_line_matches → '
     'bank_statement_lines → bank_statements,隔着三张表;单据链「付款 → 银行对账」那一对。'),
    ('bank_statement_to_payment', 'bank_statements', 'payments',
     '上一条的反方向:一张对账单上匹配掉的分录行属于哪几笔付款。'),
    ('attendance_period_to_payroll_period', 'attendance_periods', 'payroll_periods',
     '考勤与工资只共用一个 period_month(都是当月 1 号);工资读的是那个月完成的考勤。'),
    ('payroll_period_to_attendance_period', 'payroll_periods', 'attendance_periods',
     '上一条的反方向。'),
    ('overtime_batch_to_payroll_period', 'overtime_batches', 'payroll_periods',
     '加班批与工资只共用一个 period_month;只认已批准的批 —— 批过的小时数在那个月考勤完成时冻进考勤,再进工资。'),
    ('payroll_period_to_overtime_batch', 'payroll_periods', 'overtime_batches',
     '上一条的反方向(同样只认已批准的批)。'),
    ('leave_request_to_payroll_period', 'leave_requests', 'payroll_periods',
     'Tim SYSTEM-MAP-3 Q3:已批准的请假连到它的日子碰到的每一个月的工资期间;待批与驳回的请假没有工资那一头。'),
    ('payroll_period_to_leave_request', 'payroll_periods', 'leave_requests',
     '上一条的反方向(同样只认已批准的请假)。');
