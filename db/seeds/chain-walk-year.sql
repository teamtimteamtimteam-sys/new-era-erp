-- db/seeds/chain-walk-year.sql
-- ════════════════════════════════════════════════════════════════════════════
-- CHAIN-WALK-COST(Tim 2026-10-28 Q2):【一年的量】—— 四条单据链 + 变更记录,按线上今天的链接形状造,给按角色计时的 fixture 与勘察用。
-- ════════════════════════════════════════════════════════════════════════════
-- 【只对着一个一次性的【本地重建】跑 —— 永远不对线上】它用 session_replication_role = replica(与 fixture 296 同一个先例:外键与触发器都不跑,
--   单据号、外键值与变更记录由本文件自己写对)。调用方先开事务、\ir db/seeds/seven-roles-2026-10-28.sql,再 \ir 本文件;
--   fixture 297 整支回滚。勘察时(docs/surveys/CHAIN-WALK-COST)也只灌进本机的一次性库。
--
-- 【体量】(64d-4 的一年清单 + Tim Q2 加的那几样;最终行数由 fixture / 勘察读回并记在读数里)
--   采购单 2,000 · 进料批 7,300(6,000 张挂在采购单上,每张 3 批 —— 线上最多 4)· 化验 7,300(每批一张)·
--   应付 = 每批一张计价分录 7,300 · 付款申请 4,000(每张核销 1–2 批,已付)· 付款 8,000(付出 5,000,其中 4,000 由申请付出;收款 3,000)·
--   对账单 12(每月一张)· 对账单行 10,000(8,000 行匹配付款分录的银行行)· 工单 1,500 · 加工 3,000(一半挂工单)·
--   投入 7,300(每批货被一次加工吃掉,平均每次 2.4 批)· 产出批 15,000(每次 5 批,8 种前缀)· 成本分摊 7,300(每个投入一行)·
--   库存移动 60,000(收货 7,300 · 投入 7,300 · 产出 15,000 · 销售 4,000 · 调拨对 26,400)· 报价 3,000(2,000 张转成订单)·
--   销售订单 2,000(每张两行、每行一笔预留与一笔销售)· 柜 1,000 · 发货 2,500 · 发票 2,000 · 收款核销 3,000 · 贷项通知单 100 ·
--   员工 60 · 考勤期间 12 × 60 行 · 加班批 12(已批准,每批 60 行)· 请假 1,500(七成已批准)· 工资期间 12 × 60 行(每月一张付薪分录 +
--   公积金 + 扣款各一张)· 分录约 30,000(上面这些 + 加工成本 3,000 + 手工凑到 30,000)· 分录行 2 / 张 · 变更记录约 600,000。
-- 【日期】全部落在 2025 年(fixture README 第 4 条:不依赖会过期的引导数据)。
-- 【读者】七个角色各一个账号(user 与 employee 各一行),角色码与读码按 :'seven_roles'(线上快照)覆盖写入。
-- ════════════════════════════════════════════════════════════════════════════

SET LOCAL session_replication_role = replica;

CREATE FUNCTION pg_temp.u(p_kind text, p_n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT md5('cwc-' || p_kind || '-' || p_n)::uuid $$;
CREATE FUNCTION pg_temp.d(p_n integer, p_of integer) RETURNS date LANGUAGE sql IMMUTABLE AS $$ SELECT DATE '2025-01-01' + ((p_n - 1) * 364 / p_of) $$;
CREATE TEMP TABLE cwc_ctx ON COMMIT DROP AS
SELECT (SELECT code FROM currencies WHERE is_base) AS ccy,
       (SELECT id FROM accounts WHERE code = '1000') AS a_bank,
       (SELECT id FROM accounts WHERE code = '2000') AS a_ap,
       (SELECT id FROM accounts WHERE code = '1200') AS a_ar,
       (SELECT id FROM accounts WHERE code = '1300') AS a_inv,
       (SELECT id FROM accounts WHERE code = '4000') AS a_rev,
       (SELECT id FROM accounts WHERE code = '5000') AS a_cogs,
       (SELECT code FROM operation_types ORDER BY code LIMIT 1) AS op_type;
DO $pre$ BEGIN
    IF (SELECT ccy IS NULL OR a_bank IS NULL OR a_ap IS NULL OR a_ar IS NULL OR a_inv IS NULL OR a_rev IS NULL OR a_cogs IS NULL OR op_type IS NULL FROM cwc_ctx) THEN
        RAISE EXCEPTION 'CWC_SEED 前提失败:基础币种、科目 1000/2000/1200/1300/4000/5000 与一种加工类型应当由引导给出';
    END IF;
END $pre$;

-- ── 七个读者(角色码与读码 = 线上快照)──────────────────────────────────────────
CREATE TEMP TABLE cwc_roles ON COMMIT DROP AS
SELECT row_number() OVER (ORDER BY k)::integer AS n, k AS role_code, v AS codes
  FROM jsonb_each(:'seven_roles'::jsonb) AS j(k, v);
INSERT INTO roles (code, name_en, name_zh, is_active)
SELECT r.role_code, r.role_code, r.role_code, true FROM cwc_roles r WHERE NOT EXISTS (SELECT 1 FROM roles x WHERE x.code = r.role_code);
UPDATE roles SET is_active = true, deleted_at = NULL WHERE code IN (SELECT role_code FROM cwc_roles);
DELETE FROM role_permissions WHERE role_id IN (SELECT id FROM roles WHERE code IN (SELECT role_code FROM cwc_roles));
INSERT INTO role_permissions (role_id, permission_code)
SELECT ro.id, c FROM cwc_roles r JOIN roles ro ON ro.code = r.role_code, jsonb_array_elements_text(r.codes) c;
INSERT INTO auth.users (id, email) SELECT pg_temp.u('user', n), 'cwc-' || role_code || '@seed.test' FROM cwc_roles;
INSERT INTO user_roles (user_id, role_id) SELECT pg_temp.u('user', r.n), ro.id FROM cwc_roles r JOIN roles ro ON ro.code = r.role_code;
CREATE TEMP TABLE cwc_readers ON COMMIT DROP AS SELECT role_code, pg_temp.u('user', n) AS user_id FROM cwc_roles;

-- ── 主数据 ──────────────────────────────────────────────────────────────────
INSERT INTO suppliers (id, code, legal_name, country, counterparty_type, status)
SELECT pg_temp.u('sup', n), format('SUP-2025-%s', lpad(n::text, 4, '0')), 'seed supplier ' || n, 'SG', 'goods_supplier', 'active' FROM generate_series(1, 40) n;
INSERT INTO customers (id, code, legal_name, country)
SELECT pg_temp.u('cus', n), format('CUS-2025-%s', lpad(n::text, 4, '0')), 'seed customer ' || n, 'SG' FROM generate_series(1, 30) n;
INSERT INTO materials (id, code, name, kind_code, may_be_processed, form_code, source_code)
SELECT pg_temp.u('mat', n), format('MAT-2025-%s', lpad(n::text, 4, '0')), 'seed material ' || n, 'battery_material', true, 'black_mass', 'end_of_life'
  FROM generate_series(1, 13) n;
INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
SELECT pg_temp.u('emp', n), format('EMP-2025-%s', lpad(n::text, 4, '0')), 'seed employee ' || n, 'full_time',
       CASE WHEN n % 3 = 0 THEN 'office' ELSE 'shopfloor' END, DATE '2024-01-01',
       (SELECT pg_temp.u('user', r.n) FROM cwc_roles r WHERE r.n = s.n)
  FROM generate_series(1, 60) s(n);

-- ── 采购链 ─────────────────────────────────────────────────────────────────
INSERT INTO purchase_orders (id, code, supplier_id, order_date, fx_rate, category, currency, status)
SELECT pg_temp.u('po', n), format('PO-2025-%s', lpad(n::text, 4, '0')), pg_temp.u('sup', (n % 40) + 1), pg_temp.d(n, 2000), 1, 'consumables',
       (SELECT ccy FROM cwc_ctx), 'closed'
  FROM generate_series(1, 2000) n;
INSERT INTO inbound_batches (id, code, material_id, supplier_id, quantity, remaining_qty, purchase_order_id, arrival_date, pricing_status)
SELECT pg_temp.u('ib', n), format('IN-2025-%s', lpad(n::text, 4, '0')), pg_temp.u('mat', (n % 3) + 1),
       pg_temp.u('sup', CASE WHEN n <= 6000 THEN (((n - 1) / 3 + 1) % 40) + 1 ELSE (n % 40) + 1 END),
       1000, 0, CASE WHEN n <= 6000 THEN pg_temp.u('po', (n - 1) / 3 + 1) END, pg_temp.d(n, 7300), 'final'
  FROM generate_series(1, 7300) n;
INSERT INTO assay_results (id, code, assay_date, result_party, inbound_batch_id)
SELECT pg_temp.u('asy', n), format('ASY-2025-%s', lpad(n::text, 4, '0')), pg_temp.d(n, 7300) + 1, 'ours', pg_temp.u('ib', n) FROM generate_series(1, 7300) n;
-- 应付 = 这一批的计价分录
INSERT INTO journal_entries (id, code, entry_date, source_type, source_id, status)
SELECT pg_temp.u('je-pur', n), format('JE-2025-P%s', lpad(n::text, 5, '0')), pg_temp.d(n, 7300) + 2, 'purchase', pg_temp.u('ib', n), 'posted'
  FROM generate_series(1, 7300) n;
-- 付出 5,000 笔(前 4,000 笔由付款申请付出),收款 3,000 笔
INSERT INTO journal_entries (id, code, entry_date, source_type, source_id, status)
SELECT pg_temp.u('je-pay', n), format('JE-2025-Y%s', lpad(n::text, 5, '0')), pg_temp.d(n, 8000) + 5, 'payment', pg_temp.u('pay', n), 'posted'
  FROM generate_series(1, 8000) n;
INSERT INTO payments (id, code, direction, counterparty_type, supplier_id, customer_id, amount_ccy, currency, fx_rate, amount_base,
                      bank_account_code, payment_date, journal_entry_id, status)
SELECT pg_temp.u('pay', n),
       CASE WHEN n <= 5000 THEN format('PMT-2025-%s', lpad(n::text, 4, '0')) ELSE format('RCPT-2025-%s', lpad((n - 5000)::text, 4, '0')) END,
       CASE WHEN n <= 5000 THEN 'out' ELSE 'in' END, CASE WHEN n <= 5000 THEN 'supplier' ELSE 'customer' END,
       CASE WHEN n <= 5000 THEN pg_temp.u('sup', (n % 40) + 1) END, CASE WHEN n > 5000 THEN pg_temp.u('cus', (n % 30) + 1) END,
       500, (SELECT ccy FROM cwc_ctx), 1, 500, '1000', pg_temp.d(n, 8000) + 5, pg_temp.u('je-pay', n), 'posted'
  FROM generate_series(1, 8000) n;
INSERT INTO journal_lines (id, entry_id, account_id, currency, amount_ccy, fx_rate, debit, credit)
SELECT pg_temp.u('jl-pay-bank', n), pg_temp.u('je-pay', n), (SELECT a_bank FROM cwc_ctx), (SELECT ccy FROM cwc_ctx), 500, 1,
       CASE WHEN n > 5000 THEN 500 ELSE 0 END, CASE WHEN n <= 5000 THEN 500 ELSE 0 END
  FROM generate_series(1, 8000) n
UNION ALL
SELECT pg_temp.u('jl-pay-ctr', n), pg_temp.u('je-pay', n), (SELECT CASE WHEN n <= 5000 THEN a_ap ELSE a_ar END FROM cwc_ctx), (SELECT ccy FROM cwc_ctx), 500, 1,
       CASE WHEN n <= 5000 THEN 500 ELSE 0 END, CASE WHEN n > 5000 THEN 500 ELSE 0 END
  FROM generate_series(1, 8000) n;
INSERT INTO payment_requests (id, code, kind, counterparty_type, supplier_id, amount_ccy, currency, amount_base, created_by,
                              planned_date, allocations, status, decided_at, decided_by, paid_at, paid_by, result_payment_id)
SELECT pg_temp.u('preq', n), format('PREQ-2025-%s', lpad(n::text, 4, '0')), 'payment_out', 'supplier', pg_temp.u('sup', (n % 40) + 1),
       500, (SELECT ccy FROM cwc_ctx), 500, (SELECT user_id FROM cwc_readers WHERE role_code = 'finance'), pg_temp.d(n, 8000) + 4,
       CASE WHEN n <= 3300
            THEN jsonb_build_array(jsonb_build_object('inbound_batch_id', pg_temp.u('ib', n)::text, 'amount', 250),
                                   jsonb_build_object('inbound_batch_id', pg_temp.u('ib', n + 4000)::text, 'amount', 250))
            ELSE jsonb_build_array(jsonb_build_object('inbound_batch_id', pg_temp.u('ib', n)::text, 'amount', 500)) END,
       'paid', TIMESTAMPTZ '2025-06-01', (SELECT user_id FROM cwc_readers WHERE role_code = 'cfo'),
       TIMESTAMPTZ '2025-06-02', (SELECT user_id FROM cwc_readers WHERE role_code = 'finance'), pg_temp.u('pay', n)
  FROM generate_series(1, 4000) n;
INSERT INTO payment_allocations (id, payment_id, inbound_batch_id, allocated_base, allocated_ccy, allocated_pay)
SELECT pg_temp.u('pa-out', n), pg_temp.u('pay', n), pg_temp.u('ib', n), 500, 500, 500 FROM generate_series(1, 5000) n;
INSERT INTO bank_statements (id, code, bank_account_code, currency, period_start, period_end, opening_balance, closing_balance, status)
SELECT pg_temp.u('bs', m), format('BS-2025-%s', lpad(m::text, 4, '0')), '1000', (SELECT ccy FROM cwc_ctx),
       (DATE '2025-01-01' + make_interval(months => m - 1))::date, ((DATE '2025-01-01' + make_interval(months => m)) - interval '1 day')::date,
       100000, 100000, 'open'
  FROM generate_series(1, 12) m;
-- 10,000 行:前 8,000 行是付款分录的银行那一行(对上),后 2,000 行未匹配
INSERT INTO bank_statement_lines (id, statement_id, line_no, line_date, amount, match_status)
SELECT pg_temp.u('bsl', n), pg_temp.u('bs', least(12, extract(month FROM pg_temp.d(least(n, 8000), 8000) + 5)::integer)),
       n, CASE WHEN n <= 8000 THEN pg_temp.d(n, 8000) + 5 ELSE pg_temp.d(n - 8000, 2000) END,
       CASE WHEN n <= 5000 THEN -500 ELSE 500 END, CASE WHEN n <= 8000 THEN 'matched' ELSE 'unmatched' END
  FROM generate_series(1, 10000) n;
INSERT INTO bank_line_matches (id, statement_line_id, journal_line_id, matched_amount)
SELECT pg_temp.u('blm', n), pg_temp.u('bsl', n), pg_temp.u('jl-pay-bank', n), 500 FROM generate_series(1, 8000) n;

-- ── 加工链 ─────────────────────────────────────────────────────────────────
INSERT INTO work_orders (id, code, status) SELECT pg_temp.u('wo', n), format('WO-2025-%s', lpad(n::text, 4, '0')), 'released' FROM generate_series(1, 1500) n;
INSERT INTO processing_runs (id, code, status, allocation_basis, work_order_id, operation_type_code, started_at, ended_at)
SELECT pg_temp.u('run', n), format('PROC-2025-%s', lpad(n::text, 4, '0')), 'committed', 'weight',
       CASE WHEN n <= 1500 THEN pg_temp.u('wo', n) END, (SELECT op_type FROM cwc_ctx),
       pg_temp.d(n, 3000) + 10, pg_temp.d(n, 3000) + 10 + interval '6 hours'
  FROM generate_series(1, 3000) n;
INSERT INTO processing_inputs (id, run_id, inbound_batch_id, quantity_consumed)
SELECT pg_temp.u('pin', n), pg_temp.u('run', ((n - 1) % 3000) + 1), pg_temp.u('ib', n), 1000 FROM generate_series(1, 7300) n;
INSERT INTO output_batches (id, code, material_id, quantity, remaining_qty)
SELECT pg_temp.u('ob', n),
       format('%s-2025-%s', (ARRAY['OUT', 'CPW', 'APW', 'CUF', 'ALF', 'SEP', 'CSG', 'DST'])[(n % 8) + 1], lpad(n::text, 5, '0')),
       pg_temp.u('mat', (n % 8) + 4), 400, CASE WHEN n <= 4000 THEN 0 ELSE 400 END
  FROM generate_series(1, 15000) n;
INSERT INTO processing_outputs (id, run_id, output_batch_id, quantity_produced, unit_cost_base)
SELECT pg_temp.u('pout', n), pg_temp.u('run', ((n - 1) % 3000) + 1), pg_temp.u('ob', n), 400, 2.5 FROM generate_series(1, 15000) n;
INSERT INTO batch_processing_cost_allocations (id, run_id, inbound_batch_id, amount_base, basis_qty, basis_total_qty)
SELECT pg_temp.u('alloc', n), pg_temp.u('run', ((n - 1) % 3000) + 1), pg_temp.u('ib', n), 100, 1000, 2400 FROM generate_series(1, 7300) n;
INSERT INTO journal_entries (id, code, entry_date, source_type, source_id, status)
SELECT pg_temp.u('je-run', n), format('JE-2025-R%s', lpad(n::text, 5, '0')), pg_temp.d(n, 3000) + 11, 'processing_cost', pg_temp.u('run', n), 'posted'
  FROM generate_series(1, 3000) n;
-- 库存移动 60,000
INSERT INTO inventory_movements (id, inbound_batch_id, output_batch_id, run_id, movement_type, qty_delta, stock_status, business_date, pair_id)
SELECT pg_temp.u('mv-rcv', n), pg_temp.u('ib', n), NULL::uuid, NULL::uuid, 'receipt', 1000, 'available', pg_temp.d(n, 7300), NULL::uuid FROM generate_series(1, 7300) n
UNION ALL
SELECT pg_temp.u('mv-con', n), pg_temp.u('ib', n), NULL, pg_temp.u('run', ((n - 1) % 3000) + 1), 'processing_consume', -1000, 'available',
       pg_temp.d(((n - 1) % 3000) + 1, 3000) + 10, NULL FROM generate_series(1, 7300) n
UNION ALL
SELECT pg_temp.u('mv-pro', n), NULL, pg_temp.u('ob', n), pg_temp.u('run', ((n - 1) % 3000) + 1), 'processing_produce', 400, 'available',
       pg_temp.d(((n - 1) % 3000) + 1, 3000) + 10, NULL FROM generate_series(1, 15000) n
UNION ALL
SELECT pg_temp.u('mv-sale', n), NULL, pg_temp.u('ob', n), NULL, 'sale', -400, 'available', pg_temp.d(n, 4000) + 30, NULL FROM generate_series(1, 4000) n
UNION ALL
SELECT pg_temp.u('mv-tro', n), NULL, pg_temp.u('ob', 4000 + ((n - 1) % 11000) + 1), NULL, 'transfer_out', -400, 'available',
       pg_temp.d(((n - 1) % 13200) + 1, 13200), pg_temp.u('mv-pair', n) FROM generate_series(1, 13200) n
UNION ALL
SELECT pg_temp.u('mv-tri', n), NULL, pg_temp.u('ob', 4000 + ((n - 1) % 11000) + 1), NULL, 'transfer_in', 400, 'available',
       pg_temp.d(((n - 1) % 13200) + 1, 13200), pg_temp.u('mv-pair', n) FROM generate_series(1, 13200) n;

-- ── 销售链 ─────────────────────────────────────────────────────────────────
INSERT INTO sales_orders (id, code, customer_id, order_date, currency, fx_rate, status)
SELECT pg_temp.u('so', n), format('SO-2025-%s', lpad(n::text, 4, '0')), pg_temp.u('cus', (n % 30) + 1), pg_temp.d(n, 2000) + 20,
       (SELECT ccy FROM cwc_ctx), 1, 'shipped'
  FROM generate_series(1, 2000) n;
INSERT INTO quotes (id, code, customer_id, quote_date, valid_until, currency, fx_rate, status, converted_order_id)
SELECT pg_temp.u('qt', n), format('QT-2025-%s', lpad(n::text, 4, '0')), pg_temp.u('cus', (n % 30) + 1), pg_temp.d(n, 3000) + 15, pg_temp.d(n, 3000) + 45,
       (SELECT ccy FROM cwc_ctx), 1, CASE WHEN n <= 2000 THEN 'converted' ELSE 'issued' END, CASE WHEN n <= 2000 THEN pg_temp.u('so', n) END
  FROM generate_series(1, 3000) n;
INSERT INTO sales_order_lines (id, sales_order_id, line_no, material_id, quantity, unit_price)
SELECT pg_temp.u('sol', n), pg_temp.u('so', (n - 1) / 2 + 1), ((n - 1) % 2) + 1, pg_temp.u('mat', (n % 8) + 4), 400, 5 FROM generate_series(1, 4000) n;
INSERT INTO sales_order_reservations (id, sales_order_line_id, output_batch_id, qty, pair_id, consumed_at)
SELECT pg_temp.u('res', n), pg_temp.u('sol', n), pg_temp.u('ob', n), 400, pg_temp.u('res-pair', n), TIMESTAMPTZ '2025-07-01' FROM generate_series(1, 4000) n;
INSERT INTO sales_records (id, output_batch_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date, customer_id, sales_order_line_id, price_source)
SELECT pg_temp.u('sr', n), pg_temp.u('ob', n), 400, 5, (SELECT ccy FROM cwc_ctx), 1, 2000, pg_temp.d(n, 4000) + 30, pg_temp.u('cus', (((n - 1) / 2 + 1) % 30) + 1),
       pg_temp.u('sol', n), 'manual'
  FROM generate_series(1, 4000) n;
INSERT INTO containers (id, code, departure_date) SELECT pg_temp.u('ctr', n), format('CTR-2025-%s', lpad(n::text, 4, '0')), pg_temp.d(n, 1000) + 40 FROM generate_series(1, 1000) n;
INSERT INTO shipments (id, code, sales_order_id, ship_date, container_id)
SELECT pg_temp.u('shp', n), format('SHP-2025-%s', lpad(n::text, 4, '0')), pg_temp.u('so', ((n - 1) % 2000) + 1), pg_temp.d(((n - 1) % 2000) + 1, 2000) + 40,
       pg_temp.u('ctr', ((n - 1) % 1000) + 1)
  FROM generate_series(1, 2500) n;
INSERT INTO journal_entries (id, code, entry_date, source_type, source_id, status)
SELECT pg_temp.u('je-inv', n), format('JE-2025-I%s', lpad(n::text, 5, '0')), pg_temp.d(n, 2000) + 41, 'invoice', pg_temp.u('inv', n), 'posted' FROM generate_series(1, 2000) n;
INSERT INTO invoices (id, code, customer_id, issue_date, due_date, payment_terms_days, currency, subtotal_base, total_base,
                      bill_to_snapshot, kind, sales_order_id, entry_id, fx_rate, status)
SELECT pg_temp.u('inv', n), format('INV-2025-%s', lpad(n::text, 4, '0')), pg_temp.u('cus', (n % 30) + 1), pg_temp.d(n, 2000) + 41, pg_temp.d(n, 2000) + 71, 30,
       (SELECT ccy FROM cwc_ctx), 4000, 4000, '{}'::jsonb, 'order', pg_temp.u('so', n), pg_temp.u('je-inv', n), 1, 'issued'
  FROM generate_series(1, 2000) n;
INSERT INTO payment_allocations (id, payment_id, invoice_id, allocated_base, allocated_ccy, allocated_pay)
SELECT pg_temp.u('pa-in', n), pg_temp.u('pay', 5000 + n), pg_temp.u('inv', ((n - 1) % 2000) + 1), 500, 500, 500 FROM generate_series(1, 3000) n;
INSERT INTO journal_entries (id, code, entry_date, source_type, source_id, status)
SELECT pg_temp.u('je-cn', n), format('JE-2025-C%s', lpad(n::text, 5, '0')), pg_temp.d(n, 100) + 60, 'credit_note', pg_temp.u('cn', n), 'posted' FROM generate_series(1, 100) n;
INSERT INTO credit_notes (id, code, invoice_id, reason, note_date, entry_id, currency, fx_rate)
SELECT pg_temp.u('cn', n), format('CN-2025-%s', lpad(n::text, 4, '0')), pg_temp.u('inv', n * 20), 'seed', pg_temp.d(n, 100) + 60, pg_temp.u('je-cn', n),
       (SELECT ccy FROM cwc_ctx), 1
  FROM generate_series(1, 100) n;

-- ── 人事链 ─────────────────────────────────────────────────────────────────
INSERT INTO attendance_periods (id, code, period_month, status, completed_at)
SELECT pg_temp.u('att', m), format('ATT-2025-%s', lpad(m::text, 2, '0')), (DATE '2025-01-01' + make_interval(months => m - 1))::date, 'complete', TIMESTAMPTZ '2025-12-31'
  FROM generate_series(1, 12) m;
INSERT INTO attendance_lines (id, period_id, employee_id)
SELECT pg_temp.u('attl', (m - 1) * 60 + e), pg_temp.u('att', m), pg_temp.u('emp', e) FROM generate_series(1, 12) m, generate_series(1, 60) e;
INSERT INTO overtime_batches (id, label, period_month, seq, status, submitted_at, decided_at, code)
SELECT pg_temp.u('ot', m), format('OT 2025-%s #1', lpad(m::text, 2, '0')), (DATE '2025-01-01' + make_interval(months => m - 1))::date, 1, 'approved',
       TIMESTAMPTZ '2025-12-01', TIMESTAMPTZ '2025-12-02', format('OT-2025-%s', lpad(m::text, 2, '0'))
  FROM generate_series(1, 12) m;
INSERT INTO overtime_lines (id, batch_id, employee_id, work_date, hours, day_kind)
SELECT pg_temp.u('otl', (m - 1) * 60 + e), pg_temp.u('ot', m), pg_temp.u('emp', e), (DATE '2025-01-01' + make_interval(months => m - 1))::date + 9, 2, 'weekday'
  FROM generate_series(1, 12) m, generate_series(1, 60) e;
INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status)
SELECT pg_temp.u('lv', n), format('LV-2025-%s', lpad(n::text, 4, '0')), pg_temp.u('emp', (n % 60) + 1), 'annual',
       pg_temp.d(n, 1500), pg_temp.d(n, 1500) + 1, 2, CASE WHEN n % 10 < 7 THEN 'approved' ELSE 'pending' END
  FROM generate_series(1, 1500) n;
INSERT INTO journal_entries (id, code, entry_date, source_type, source_id, status)
SELECT pg_temp.u('je-pp-' || k, m), format('JE-2025-W%s%s', k, lpad(m::text, 2, '0')), (DATE '2025-01-01' + make_interval(months => m - 1))::date + 27,
       'payroll', pg_temp.u('pp', m), 'posted'
  FROM generate_series(1, 12) m, unnest(ARRAY['pay', 'cpf', 'ded']) k;
INSERT INTO payroll_periods (id, code, period_month, payment_date, fx_rate, currency, status, cpf_journal_entry_id, deductions_journal_entry_id)
SELECT pg_temp.u('pp', m), format('PAY-2025-%s', lpad(m::text, 4, '0')), (DATE '2025-01-01' + make_interval(months => m - 1))::date,
       (DATE '2025-01-01' + make_interval(months => m - 1))::date + 27, 1, (SELECT ccy FROM cwc_ctx), 'posted',
       pg_temp.u('je-pp-cpf', m), pg_temp.u('je-pp-ded', m)
  FROM generate_series(1, 12) m;
INSERT INTO payroll_lines (id, payroll_period_id, employee_id, gross_pay, net_pay, paid_journal_entry_id, paid_at)
SELECT pg_temp.u('pl', (m - 1) * 60 + e), pg_temp.u('pp', m), pg_temp.u('emp', e), 4000, 3200, pg_temp.u('je-pp-pay', m), TIMESTAMPTZ '2025-12-31'
  FROM generate_series(1, 12) m, generate_series(1, 60) e;

-- ── 分录凑到约 30,000 张(手工),每张两行;以上各张也各补两行 ─────────────────
INSERT INTO journal_entries (id, code, entry_date, source_type, status)
SELECT pg_temp.u('je-man', n), format('JE-2025-M%s', lpad(n::text, 5, '0')), pg_temp.d(n, 9564), 'manual', 'posted' FROM generate_series(1, 9564) n;
INSERT INTO journal_lines (id, entry_id, account_id, currency, amount_ccy, fx_rate, debit, credit)
SELECT gen_random_uuid(), e.id, CASE WHEN s.k = 1 THEN c.a_inv ELSE c.a_ap END, c.ccy, 100, 1,
       CASE WHEN s.k = 1 THEN 100 ELSE 0 END, CASE WHEN s.k = 2 THEN 100 ELSE 0 END
  FROM journal_entries e CROSS JOIN cwc_ctx c CROSS JOIN generate_series(1, 2) s(k)
 WHERE e.source_type <> 'payment' AND e.entry_date BETWEEN DATE '2025-01-01' AND DATE '2026-01-31';

SET LOCAL session_replication_role = origin;

-- ── 变更记录:每一行一次 INSERT,文件里的单据再补到合计约 600,000 行(UPDATE)─────────────
--   影像就是那一行今天的样子;UPDATE 只碰一列(status / pricing_status / remaining_qty / notes 里第一列存在的)。
--   txid 每一行各一笔(审计记录按 txid 分组 —— 一行一条记录,是悲观的分组)。直接写入,不经触发器(replica 已经关回 origin,
--   但 change_log 自己只拒改与删)。
DO $cl$
DECLARE
    t text;
    v_ins bigint := 0;
    v_n bigint;
    v_docs text[] := ARRAY['purchase_orders', 'inbound_batches', 'assay_results', 'payments', 'payment_requests', 'work_orders', 'processing_runs',
                           'output_batches', 'quotes', 'sales_orders', 'shipments', 'containers', 'invoices', 'credit_notes', 'leave_requests',
                           'journal_entries', 'inventory_movements'];
    v_all text[] := ARRAY['suppliers', 'customers', 'materials', 'employees', 'purchase_orders', 'inbound_batches', 'assay_results', 'journal_entries',
                          'journal_lines', 'payments', 'payment_requests', 'payment_allocations', 'bank_statements', 'bank_statement_lines',
                          'bank_line_matches', 'work_orders', 'processing_runs', 'processing_inputs', 'output_batches', 'processing_outputs',
                          'batch_processing_cost_allocations', 'inventory_movements', 'sales_orders', 'quotes', 'sales_order_lines',
                          'sales_order_reservations', 'sales_records', 'containers', 'shipments', 'invoices', 'credit_notes', 'attendance_periods',
                          'attendance_lines', 'overtime_batches', 'overtime_lines', 'leave_requests', 'payroll_periods', 'payroll_lines'];
    v_actor uuid := (SELECT user_id FROM cwc_readers WHERE role_code = 'admin');
    v_doc_rows bigint := 0;
    v_per integer;
    v_ratio numeric;
    v_col text;
BEGIN
    FOREACH t IN ARRAY v_all LOOP
        EXECUTE format($q$INSERT INTO change_log (occurred_at, txid, table_name, row_key, op, actor_account, actor_kind, db_role, new)
                          SELECT TIMESTAMPTZ '2025-01-01' + (row_number() OVER () * interval '37 seconds'), 900000000 + row_number() OVER (),
                                 %L, jsonb_build_object('id', x.id), 'INSERT', $1, 'user', 'authenticated', to_jsonb(x)
                            FROM public.%I x$q$, t, t) USING v_actor;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_ins := v_ins + v_n;
    END LOOP;
    FOREACH t IN ARRAY v_docs LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', t) INTO v_n;
        v_doc_rows := v_doc_rows + v_n;
    END LOOP;
    v_ratio := greatest(0, (600000 - v_ins)::numeric / v_doc_rows);   -- 每一张单据平均几次改动(小数部分按行号取一部分行)
    v_per := ceil(v_ratio)::integer;
    FOREACH t IN ARRAY v_docs LOOP
        SELECT c INTO v_col FROM unnest(ARRAY['status', 'pricing_status', 'remaining_qty', 'notes']) c
         WHERE EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = format('public.%I', t)::regclass AND a.attname = c AND NOT a.attisdropped)
         LIMIT 1;
        CONTINUE WHEN v_col IS NULL;
        EXECUTE format($q$INSERT INTO change_log (occurred_at, txid, table_name, row_key, op, actor_account, actor_kind, db_role, changed_columns, old, new)
                          SELECT TIMESTAMPTZ '2025-02-01' + ((row_number() OVER ()) * interval '41 seconds'), 950000000 + row_number() OVER (),
                                 %L, jsonb_build_object('id', x.id), 'UPDATE', $1, 'user', 'authenticated', ARRAY[%L],
                                 jsonb_build_object(%L, to_jsonb(x) -> %L), jsonb_build_object(%L, to_jsonb(x) -> %L)
                            FROM (SELECT y.*, row_number() OVER () AS rn FROM public.%I y) x CROSS JOIN generate_series(1, $2) g
                           WHERE g <= floor($3) OR (x.rn %% 1000) < round(($3 - floor($3)) * 1000)$q$, t, v_col, v_col, v_col, v_col, v_col, t)
            USING v_actor, v_per, v_ratio;
    END LOOP;
    RAISE NOTICE 'CWC_SEED change_log: % INSERT rows + % UPDATE rows per document row on average', v_ins, round(v_ratio, 3);
END $cl$;
ANALYZE;
