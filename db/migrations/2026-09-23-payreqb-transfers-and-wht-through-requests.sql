-- db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql
-- PAY-REQ-1 · Batch B —— 银行转账与其冲销、代扣税缴纳与其冲销,都走付款申请(Tim 2026-09-23 的 Q15;
-- Batch B grilling Q2–Q4 与 Q16,Tim 全部接受)。
--
-- 【本批做什么】
--   ① payment_requests 扩四种:bank_transfer · bank_transfer_reversal · wht_remittance ·
--      wht_remittance_reversal。四种都【没有收款人】(counterparty_type 放开 NULL);新增九列
--      (ALTER,在表尾);形状约束逐种写出;执行结果另记 result_journal_entry_id / result_transfer_id;
--      三条"同时只能有一张未了结"的唯一索引(每笔转账一张冲销、每个代扣月一张缴纳、每笔缴纳一张冲销)。
--   ② record_bank_transfer / reverse_bank_transfer / remit_wht 的函数体搬进 *_internal
--      (authenticated 调不到);外壳按名拒 PAYMENT_REQUEST_REQUIRED|<kind>。
--      remit_wht_internal 多一个 p_expected_amount:申请冻结的是提交那一刻推导出来的数,
--      执行时推导值变了就按名拒 WHT_REMIT_AMOUNT_CHANGED。
--      新增 reverse_wht_remittance_internal(代扣税缴纳的更正,Q3)。
--   ③ 四支提交函数;payment_request_dry_run 与 pay_payment_request 逐种一支,
--      不认识的种类按名拒 PAYMENT_REQUEST_KIND_UNKNOWN(此前的 ELSE 会把新种类当成付款冲销)。
--   ④ reverse_journal_entry 对 source_type = 'wht_remittance' 也关门(Q3)。
--
-- 【不需要改的】decide_payment_request / withdraw_payment_request / approval_pending_documents /
--   approval_chain_gates / guard_approvals_switch / approval_log / record_approval_decision 都与种类无关
--   (批的门、二级固定、blocks_disable、留痕金额都读申请行上的同一组列)—— 逐支读过。
--
-- 【RUNTIME CONFIG】本批不碰任何 RUNTIME CONFIG 表。
--
-- 【审批是开着的】一提交就在线上生效。文末自证在同一笔事务里断言:开关仍开、在途单据一张不少、
-- 留痕 / 分录 / 付款 / 转账 / 代扣税缴纳 / 付款申请一行没多、各角色的码一个没动、四支内层引擎
-- authenticated 调不到、每一条链二级有人批得动。失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提与"之前" ───────────────────────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'PAYREQB_PRE|approvals are expected ON';
    END IF;
    IF to_regproc('public.record_bank_transfer_internal') IS NOT NULL THEN
        RAISE EXCEPTION 'PAYREQB_PRE|already applied';
    END IF;
END;
$pre$;

CREATE TEMP TABLE payreqb_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved');
CREATE TEMP TABLE payreqb_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS log_n, (SELECT count(*) FROM journal_entries) AS je_n,
       (SELECT count(*) FROM payments) AS pay_n, (SELECT count(*) FROM bank_transfers) AS bt_n,
       (SELECT count(*) FROM wht_remittances) AS wht_n, (SELECT count(*) FROM payment_requests) AS pr_n;
CREATE TEMP TABLE payreqb_codes_before ON COMMIT DROP AS
SELECT r.code AS role, rp.permission_code AS code
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · payment_requests ────────────────────────────────────────────────────
ALTER TABLE public.payment_requests DROP CONSTRAINT payment_requests_kind_check;
ALTER TABLE public.payment_requests ADD CONSTRAINT payment_requests_kind_check
    CHECK (kind IN ('payment_out', 'payment_reversal', 'bank_transfer', 'bank_transfer_reversal', 'wht_remittance', 'wht_remittance_reversal'));
ALTER TABLE public.payment_requests ALTER COLUMN counterparty_type DROP NOT NULL;

ALTER TABLE public.payment_requests
    ADD COLUMN to_account_code    text,
    ADD COLUMN amount_in          numeric CHECK (amount_in IS NULL OR amount_in > 0),
    ADD COLUMN bank_reference     text,
    ADD COLUMN transfer_id        uuid REFERENCES public.bank_transfers (id) ON DELETE RESTRICT,
    ADD COLUMN period_month       date CHECK (period_month IS NULL OR period_month = date_trunc('month', period_month)::date),
    ADD COLUMN filed_reference    text,
    ADD COLUMN wht_remittance_id  uuid REFERENCES public.wht_remittances (id) ON DELETE RESTRICT,
    ADD COLUMN result_transfer_id      uuid REFERENCES public.bank_transfers (id) ON DELETE RESTRICT,
    ADD COLUMN result_journal_entry_id uuid REFERENCES public.journal_entries (id) ON DELETE RESTRICT;

ALTER TABLE public.payment_requests DROP CONSTRAINT payment_requests_counterparty_shape;
ALTER TABLE public.payment_requests ADD CONSTRAINT payment_requests_counterparty_shape CHECK (
        (counterparty_type IS NULL AND num_nonnulls(supplier_id, employee_id, customer_id) = 0)
        OR
        (num_nonnulls(supplier_id, employee_id, customer_id) = 1
        AND (counterparty_type <> 'supplier' OR supplier_id IS NOT NULL)
        AND (counterparty_type <> 'employee' OR employee_id IS NOT NULL)
        AND (counterparty_type <> 'customer' OR customer_id IS NOT NULL)));
ALTER TABLE public.payment_requests DROP CONSTRAINT payment_requests_kind_shape;
ALTER TABLE public.payment_requests ADD CONSTRAINT payment_requests_kind_shape CHECK (
        (kind = 'payment_out' AND payment_id IS NULL AND planned_date IS NOT NULL
             AND counterparty_type IN ('supplier', 'employee')
             AND num_nonnulls(to_account_code, amount_in, transfer_id, period_month, wht_remittance_id) = 0)
        OR
        (kind = 'payment_reversal' AND payment_id IS NOT NULL AND planned_date IS NULL
             AND jsonb_array_length(allocations) = 0 AND btrim(COALESCE(notes, '')) <> ''
             AND num_nonnulls(to_account_code, amount_in, transfer_id, period_month, wht_remittance_id) = 0)
        OR
        (kind = 'bank_transfer' AND counterparty_type IS NULL AND planned_date IS NOT NULL
             AND bank_account_code IS NOT NULL AND to_account_code IS NOT NULL AND amount_in IS NOT NULL
             AND jsonb_array_length(allocations) = 0
             AND num_nonnulls(payment_id, transfer_id, period_month, wht_remittance_id) = 0)
        OR
        (kind = 'bank_transfer_reversal' AND counterparty_type IS NULL AND transfer_id IS NOT NULL
             AND planned_date IS NULL AND jsonb_array_length(allocations) = 0
             AND btrim(COALESCE(notes, '')) <> ''
             AND num_nonnulls(payment_id, period_month, wht_remittance_id) = 0)
        OR
        (kind = 'wht_remittance' AND counterparty_type IS NULL AND planned_date IS NOT NULL
             AND period_month IS NOT NULL AND btrim(COALESCE(filed_reference, '')) <> ''
             AND bank_account_code IS NOT NULL AND jsonb_array_length(allocations) = 0
             AND num_nonnulls(payment_id, to_account_code, amount_in, transfer_id, wht_remittance_id) = 0)
        OR
        (kind = 'wht_remittance_reversal' AND counterparty_type IS NULL AND wht_remittance_id IS NOT NULL
             AND planned_date IS NULL AND jsonb_array_length(allocations) = 0
             AND btrim(COALESCE(notes, '')) <> ''
             AND num_nonnulls(payment_id, to_account_code, amount_in, transfer_id) = 0));
ALTER TABLE public.payment_requests DROP CONSTRAINT payment_requests_paid_shape;
ALTER TABLE public.payment_requests ADD CONSTRAINT payment_requests_paid_shape CHECK (
        (status = 'paid') = (paid_at IS NOT NULL)
        AND (paid_at IS NULL) = (paid_by IS NULL)
        AND CASE WHEN kind IN ('payment_out', 'payment_reversal')
                 THEN (result_payment_id IS NULL) = (paid_at IS NULL)
                      AND result_journal_entry_id IS NULL AND result_transfer_id IS NULL
                 ELSE result_payment_id IS NULL
                      AND (result_journal_entry_id IS NULL) = (paid_at IS NULL)
                      AND (result_transfer_id IS NULL) = (kind <> 'bank_transfer' OR paid_at IS NULL)
            END);

CREATE UNIQUE INDEX payment_requests_one_open_transfer_reversal
    ON public.payment_requests (transfer_id)
    WHERE kind = 'bank_transfer_reversal' AND status IN ('submitted', 'approved');
CREATE UNIQUE INDEX payment_requests_one_open_wht_month
    ON public.payment_requests (period_month)
    WHERE kind = 'wht_remittance' AND status IN ('submitted', 'approved');
CREATE UNIQUE INDEX payment_requests_one_open_wht_reversal
    ON public.payment_requests (wht_remittance_id)
    WHERE kind = 'wht_remittance_reversal' AND status IN ('submitted', 'approved');
CREATE INDEX payment_requests_transfer_id_rel ON public.payment_requests (transfer_id);
CREATE INDEX payment_requests_wht_remittance_id_rel ON public.payment_requests (wht_remittance_id);
CREATE INDEX payment_requests_result_transfer_id_rel ON public.payment_requests (result_transfer_id);
CREATE INDEX payment_requests_result_journal_entry_id_rel ON public.payment_requests (result_journal_entry_id);

COMMENT ON TABLE public.payment_requests IS
    'PAY-REQ-1:付款申请 —— 钱离开之前的在途态(Tim:钱离开之前要先批)。submitted → approved(CFO,每一张都批、不分档)→ paid(财务;分录只在这一刻过账)。另有 rejected(要理由)与 withdrawn。审批关着时生下来就是 approved(auto_approved,与采购单同形)。六种:payment_out 存 record_payment 的那组参数;payment_reversal 冲销一笔已记账的付款(收款或出款都算);Batch B 加 bank_transfer / bank_transfer_reversal / wht_remittance / wht_remittance_reversal(没有收款人;代扣税的金额冻结提交那一刻的推导值)。提单人永远不能批(按人认)。approved 也可撤回:一张付不出去的申请不许永远占着它要付的单据。';

COMMENT ON TABLE public.bank_transfers IS
    '行内转账。两边金额照银行实际;分录两条银行线各记本币,供两边对账单各自认领。PAY-REQ-1 Batch B 起:转账与其冲销都经付款申请(提 → CFO 批 → 执行),执行时调 record_bank_transfer_internal / reverse_bank_transfer_internal。';

-- ── 2 · 函数 ─────────────────────────────────────────────────────────────────
-- ── record_bank_transfer_internal ──
CREATE OR REPLACE FUNCTION public.record_bank_transfer_internal(p_transfer_date date, p_from_account text, p_to_account text, p_amount_out numeric, p_amount_in numeric, p_bank_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base     text;   -- OPS-8:本位币从 currencies.is_base 读
    v_from_ccy text;
    v_to_ccy   text;
    v_fx_out   numeric;
    v_fx_in    numeric;
    v_je       jsonb;
    v_id       uuid;
BEGIN
    -- OPS-8:本位币是【数据】(currencies.is_base),不是字面量。
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    -- ★ PAY-REQ-1 Batch B:这里【没有】权限检查 —— 内层引擎,EXECUTE 已从 authenticated 收回。
    --   唯一的外门是 pay_payment_request(finance.edit,且只执行一张已批准的转账申请);
    --   payment_request_dry_run 在提交与批准时照同一套规矩核一遍再回滚。

    IF p_from_account IS NULL OR p_from_account NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_from_account, '?');
    END IF;
    IF p_to_account IS NULL OR p_to_account NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_to_account, '?');
    END IF;
    IF p_from_account = p_to_account THEN
        RAISE EXCEPTION 'TRANSFER_SAME_ACCOUNT|%', p_from_account;
    END IF;
    IF p_amount_out IS NULL OR p_amount_out <= 0 OR p_amount_in IS NULL OR p_amount_in <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_transfer_date IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;

    v_from_ccy := bank_native_currency(p_from_account);
    v_to_ccy   := bank_native_currency(p_to_account);

    -- 同币种:没有 FX 这回事,两边必须相等
    IF v_from_ccy = v_to_ccy AND p_amount_out <> p_amount_in THEN
        RAISE EXCEPTION 'TRANSFER_AMOUNTS_UNEQUAL|%|%', p_amount_out, p_amount_in;
    END IF;

    -- 本位币侧 fx=1;外币侧 fx=本笔实际隐含汇率(两边都是实际数,分录恰好配平)
    v_fx_out := CASE WHEN v_from_ccy = v_base THEN 1 ELSE p_amount_in / p_amount_out END;
    v_fx_in  := CASE WHEN v_to_ccy   = v_base THEN 1 ELSE p_amount_out / p_amount_in END;

    v_je := post_journal_entry(
        p_transfer_date,
        format('Transfer %s -> %s%s', p_from_account, p_to_account,
               CASE WHEN p_bank_reference IS NULL THEN '' ELSE ' (' || p_bank_reference || ')' END),
        'transfer',
        NULL,
        jsonb_build_array(
            jsonb_build_object('account_code', p_to_account,   'side', 'debit',
                               'currency', v_to_ccy,   'amount_ccy', p_amount_in,  'fx_rate', v_fx_in),
            jsonb_build_object('account_code', p_from_account, 'side', 'credit',
                               'currency', v_from_ccy, 'amount_ccy', p_amount_out, 'fx_rate', v_fx_out)));

    INSERT INTO bank_transfers (transfer_date, from_account, to_account, amount_out, amount_in,
                                bank_reference, notes, journal_entry_id)
    VALUES (p_transfer_date, p_from_account, p_to_account, p_amount_out, p_amount_in,
            p_bank_reference, p_notes, (v_je->>'entry_id')::uuid)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('transfer_id', v_id, 'journal_code', v_je->>'code',
                              'entry_id', v_je->>'entry_id');
END;
$function$;

-- ── reverse_bank_transfer_internal ──
CREATE OR REPLACE FUNCTION public.reverse_bank_transfer_internal(p_transfer_id uuid, p_reversal_date date DEFAULT NULL::date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t  bank_transfers%ROWTYPE;
    v_je jsonb;
BEGIN
    -- ★ PAY-REQ-1 Batch B:这里【没有】权限检查 —— 内层引擎,EXECUTE 已从 authenticated 收回;
    --   唯一的外门是 pay_payment_request(一张已批准的 bank_transfer_reversal 申请)。
    IF p_reversal_date IS NULL THEN
        RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
    END IF;

    SELECT * INTO v_t FROM bank_transfers WHERE id = p_transfer_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_NOT_FOUND|%', COALESCE(p_transfer_id::text, '?');
    END IF;
    IF v_t.reversed_at IS NOT NULL THEN
        RAISE EXCEPTION 'TRANSFER_ALREADY_REVERSED|%', p_transfer_id;
    END IF;

    v_je := reverse_journal_entry_internal(v_t.journal_entry_id,
                p_reversal_date,
                COALESCE(p_memo, 'Reverse bank transfer'));

    UPDATE bank_transfers
    SET reversed_at = now(), reversed_by = auth.uid(),
        reversal_entry_id = (v_je->>'reversal_id')::uuid
    WHERE id = p_transfer_id;

    RETURN jsonb_build_object('transfer_id', p_transfer_id,
                              'reversal_journal_code', v_je->>'code',
                              'reversal_entry_id', v_je->>'reversal_id');
END;
$function$;

-- ── remit_wht_internal ──
CREATE OR REPLACE FUNCTION public.remit_wht_internal(p_period_month date, p_remitted_on date DEFAULT NULL::date, p_filed_reference text DEFAULT NULL::text, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_expected_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_month   date;
    v_amount  numeric;
    v_bank    text;
    v_base    text;
    v_ref     text;
    v_seq     integer;
    v_code    text;
    v_je      jsonb;
    v_id      uuid := gen_random_uuid();
BEGIN
    -- ★ PAY-REQ-1 Batch B:这里【没有】写权限检查 —— 内层引擎,EXECUTE 已从 authenticated
    --   收回;唯一的外门是 pay_payment_request(finance.edit,只执行一张已批准的代扣税缴纳申请)。
    --   下面那一句 view 检查【留着】,而它不是调用者检查,是这次【读】的前提(WHT-1 fu1):
    PERFORM require_permission('module.finance.view');

    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'WHT_PERIOD_REQUIRED';
    END IF;
    v_month := date_trunc('month', p_period_month)::date;

    IF p_remitted_on IS NULL THEN
        RAISE EXCEPTION 'WHT_REMIT_DATE_REQUIRED|%', v_month;
    END IF;
    IF p_remitted_on < v_month THEN
        -- 还没发生的代扣汇不出去。
        RAISE EXCEPTION 'WHT_REMIT_DATE_BEFORE_PERIOD|%|%', p_remitted_on, v_month;
    END IF;

    -- 【参考号必填,而 gst_periods 那一条允许空 —— 两者不是同一件事】
    -- GST 那边"申报"与"缴款"是两个动作,回执可能晚到;这里是【一次缴款】,
    -- 而一笔说不出参考号的缴款,日后对着 IRAS 无从交代。
    v_ref := NULLIF(btrim(COALESCE(p_filed_reference, '')), '');
    IF v_ref IS NULL THEN
        RAISE EXCEPTION 'WHT_FILED_REFERENCE_REQUIRED|%', v_month
          USING HINT = '填 IRAS S45 申报的回执/参考号 —— 一笔交代不出出处的缴款,日后无从对账';
    END IF;

    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 【银行必须是本位币户,而这一条【故意】比 pay_payroll_cpf 严】
    -- IRAS 只收新元。pay_payroll_cpf 允许 1010 却把两条腿都按本位币记 ——
    -- 那意味着一笔从美元户走的钱会被记成等额新元离开,而实际离开的是美元。
    -- 那一支不在本刀范围内(不顺手改别人的函数),但这一支不复制它。
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    IF bank_native_currency(v_bank) <> v_base THEN
        RAISE EXCEPTION 'WHT_REMIT_BANK_NOT_BASE|%|%', v_bank, bank_native_currency(v_bank)
          USING HINT = 'IRAS 只收本位币 —— 从外币户汇出去要先兑换,而那笔兑换是它自己的一笔交易';
    END IF;

    -- 【欠多少从那张视图读,不在这里再算一遍】视图是唯一的实现,而它对
    -- 冲销的处理(经 journal_activity_lines)是这条链上最容易写错的一段。
    -- 在这里重算 = 第二份实现,而两份会在写下来那天一致、之后悄悄分开。
    SELECT unremitted_base INTO v_amount
    FROM wht_liability_by_month WHERE period_month = v_month;

    IF COALESCE(v_amount, 0) <= 0 THEN
        RAISE EXCEPTION 'WHT_NOTHING_TO_REMIT|%|%', v_month, COALESCE(v_amount, 0)
          USING HINT = '这个月没有未汇的代扣税 —— 也可能是已经汇过了(补汇是新的一行,不是改旧的那一行)';
    END IF;

    -- ★ PAY-REQ-1 Batch B:申请冻结的是【提交那一刻】推导出来的数,CFO 批的就是它。
    --   付款那一刻推导值变了(这个月又进了一笔带代扣的付款、有一笔被冲销、有人手工调了 2150),
    --   就按名拒 —— 不许悄悄汇一个没人批过的数。撤回这张、按新数重提。
    IF p_expected_amount IS NOT NULL AND v_amount <> p_expected_amount THEN
        RAISE EXCEPTION 'WHT_REMIT_AMOUNT_CHANGED|%|%|%', v_month, p_expected_amount, v_amount
          USING HINT = '申请批的是提交时的数;现在推导出来的不一样了 —— 撤回这张申请,按新数重提';
    END IF;

    -- 分录走【普通过账路径】,所以期间锁照常生效 —— 与 CPF 同一条:
    -- 一笔汇款不因为它是法定义务就可以进一个已经关掉的月份。
    v_je := post_journal_entry(
        p_remitted_on,
        'Withholding tax remittance ' || to_char(v_month, 'YYYY-MM'),
        'wht_remittance', v_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2150', 'side', 'debit',
                'currency', v_base, 'amount_ccy', v_amount,
                'line_memo', 'WHT for ' || to_char(v_month, 'YYYY-MM')),
            jsonb_build_object('account_code', v_bank, 'side', 'credit',
                'currency', v_base, 'amount_ccy', v_amount,
                'line_memo', 'IRAS ' || v_ref)));

    -- 编号:同一个月可以有多笔(补汇),第二笔起带序号。
    -- 咨询锁串行化,与 EXP/JE/收付款的取号手法一致。
    PERFORM pg_advisory_xact_lock(hashtext('wht_remit_' || to_char(v_month, 'YYYY-MM'))::bigint);
    SELECT COUNT(*) + 1 INTO v_seq FROM wht_remittances WHERE period_month = v_month;
    v_code := document_type_prefix('wht_remittance') || '-' || to_char(v_month, 'YYYY-MM') ||
              CASE WHEN v_seq > 1 THEN '-' || v_seq::text ELSE '' END;

    INSERT INTO wht_remittances (id, code, period_month, remitted_on, amount_base,
                                 filed_reference, journal_entry_id, notes, created_by)
    VALUES (v_id, v_code, v_month, p_remitted_on, v_amount,
            v_ref, (v_je->>'entry_id')::uuid, p_notes, auth.uid());

    RETURN jsonb_build_object(
        'remittance_id', v_id,
        'code', v_code,
        'period_month', v_month,
        'remitted_on', p_remitted_on,
        'amount_base', v_amount,
        'currency', v_base,
        'filed_reference', v_ref,
        'journal_code', v_je->>'code',
        'entry_id', v_je->>'entry_id');
END;
$function$
;

-- ── reverse_wht_remittance_internal ──
CREATE OR REPLACE FUNCTION public.reverse_wht_remittance_internal(p_remittance_id uuid, p_reversal_date date DEFAULT NULL::date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_w  wht_remittances%ROWTYPE;
    v_st text;
    v_je jsonb;
BEGIN
    IF p_reversal_date IS NULL THEN
        RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
    END IF;
    SELECT * INTO v_w FROM wht_remittances WHERE id = p_remittance_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_NOT_FOUND|%', COALESCE(p_remittance_id::text, '?');
    END IF;
    SELECT status INTO v_st FROM journal_entries WHERE id = v_w.journal_entry_id;
    IF v_st IS DISTINCT FROM 'posted' THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_ALREADY_REVERSED|%', v_w.code;
    END IF;

    v_je := reverse_journal_entry_internal(v_w.journal_entry_id, p_reversal_date,
                COALESCE(p_memo, 'Reverse withholding tax remittance ' || v_w.code));

    RETURN jsonb_build_object('remittance_id', p_remittance_id, 'code', v_w.code,
                              'reversal_journal_code', v_je->>'code',
                              'reversal_entry_id', v_je->>'reversal_id');
END;
$function$
;

-- ── record_bank_transfer ──
CREATE OR REPLACE FUNCTION public.record_bank_transfer(p_transfer_date date, p_from_account text, p_to_account text, p_amount_out numeric, p_amount_in numeric, p_bank_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    RAISE EXCEPTION 'PAYMENT_REQUEST_REQUIRED|bank_transfer'
      USING HINT = '行内转账要先提转账申请、经 CFO 批准,再执行(PAY-REQ-1 Batch B)';
END;
$function$;

-- ── reverse_bank_transfer ──
CREATE OR REPLACE FUNCTION public.reverse_bank_transfer(p_transfer_id uuid, p_reversal_date date DEFAULT NULL::date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    RAISE EXCEPTION 'PAYMENT_REQUEST_REQUIRED|bank_transfer_reversal'
      USING HINT = '冲销行内转账要先提冲销申请、经 CFO 批准,再执行(PAY-REQ-1 Batch B)';
END;
$function$;

-- ── remit_wht ──
CREATE OR REPLACE FUNCTION public.remit_wht(p_period_month date, p_remitted_on date DEFAULT NULL::date, p_filed_reference text DEFAULT NULL::text, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    PERFORM require_permission('module.finance.view');
    RAISE EXCEPTION 'PAYMENT_REQUEST_REQUIRED|wht_remittance'
      USING HINT = '代扣税缴纳要先提缴纳申请、经 CFO 批准,再执行(PAY-REQ-1 Batch B)';
END;
$function$;

-- ── payment_request_dry_run ──
CREATE OR REPLACE FUNCTION public.payment_request_dry_run(p_request_id uuid, p_date date DEFAULT NULL::date, p_fx_rate numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r     record;
    v_res   jsonb;
    v_entry uuid;
    v_base  numeric;
BEGIN
    SELECT * INTO v_r FROM payment_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    BEGIN
        -- ★ Batch B:每一种都写出来,不认识的按名拒 —— 此前的 ELSE 会把任何新种类
        --   当成付款冲销,悄悄去冲一笔 payment_id 为 NULL 的付款。
        CASE v_r.kind
        WHEN 'payment_out' THEN
            v_res := record_payment_internal(
                'out',
                COALESCE(v_r.supplier_id, v_r.employee_id),
                v_r.amount_ccy, v_r.currency,
                COALESCE(p_fx_rate, v_r.fx_rate),
                v_r.bank_account_code,
                COALESCE(p_date, v_r.planned_date),
                v_r.notes, v_r.allocations, v_r.counterparty_type);
        WHEN 'payment_reversal' THEN
            v_res := reverse_payment_internal(v_r.payment_id, v_r.notes);
        WHEN 'bank_transfer' THEN
            v_res := record_bank_transfer_internal(
                COALESCE(p_date, v_r.planned_date), v_r.bank_account_code, v_r.to_account_code,
                v_r.amount_ccy, v_r.amount_in, v_r.bank_reference, v_r.notes);
            v_entry := (v_res->>'entry_id')::uuid;
        WHEN 'bank_transfer_reversal' THEN
            v_res := reverse_bank_transfer_internal(v_r.transfer_id, COALESCE(p_date, CURRENT_DATE), v_r.notes);
            v_entry := (v_res->>'reversal_entry_id')::uuid;
        WHEN 'wht_remittance' THEN
            v_res := remit_wht_internal(
                v_r.period_month, COALESCE(p_date, v_r.planned_date), v_r.filed_reference,
                v_r.bank_account_code, v_r.notes, v_r.amount_ccy);
            v_entry := (v_res->>'entry_id')::uuid;
        WHEN 'wht_remittance_reversal' THEN
            v_res := reverse_wht_remittance_internal(v_r.wht_remittance_id, COALESCE(p_date, CURRENT_DATE), v_r.notes);
            v_entry := (v_res->>'reversal_entry_id')::uuid;
        ELSE
            RAISE EXCEPTION 'PAYMENT_REQUEST_KIND_UNKNOWN|%|%', v_r.code, v_r.kind;
        END CASE;
        -- 付款两种的本位币额由引擎自己返回;另外四种没有,就读【这次会过账的那张分录】
        -- 的借方合计 —— 同一支引擎的产物,不在这里另算一份。
        IF v_entry IS NOT NULL THEN
            SELECT sum(l.debit) INTO v_base FROM journal_lines l WHERE l.entry_id = v_entry;
            v_res := v_res || jsonb_build_object('amount_base', v_base);
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'PQ001', MESSAGE = 'PAYMENT_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ001' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$
;

-- ── pay_payment_request ──
CREATE OR REPLACE FUNCTION public.pay_payment_request(p_request_id uuid, p_payment_date date DEFAULT NULL::date, p_fx_rate numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r   payment_requests%ROWTYPE;
    v_res jsonb;
    v_pid uuid;
    v_tid uuid;
    v_eid uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_r FROM payment_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'approved' THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_NOT_APPROVED|%|%', v_r.code, v_r.status;
    END IF;

    -- ★ Batch B:每一种都写出来,不认识的按名拒(此前的 ELSE 会把任何新种类当成付款冲销)。
    CASE v_r.kind
    WHEN 'payment_out' THEN
        IF p_payment_date IS NULL THEN
            RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
        END IF;
        PERFORM payment_request_payee_check(v_r.kind, v_r.supplier_id);
        v_res := record_payment_internal(
            'out',
            COALESCE(v_r.supplier_id, v_r.employee_id),
            v_r.amount_ccy, v_r.currency,
            COALESCE(p_fx_rate, v_r.fx_rate),
            v_r.bank_account_code,
            p_payment_date,
            COALESCE(v_r.notes || ' · ', '') || v_r.code,
            v_r.allocations, v_r.counterparty_type);
        v_pid := (v_res->>'payment_id')::uuid;
    WHEN 'payment_reversal' THEN
        IF p_payment_date IS NOT NULL OR p_fx_rate IS NOT NULL THEN
            RAISE EXCEPTION 'PAYMENT_REVERSAL_TAKES_NO_DATE|%', v_r.code;
        END IF;
        v_res := reverse_payment_internal(v_r.payment_id, v_r.notes || ' · ' || v_r.code);
        v_pid := (v_res->>'reversal_payment_id')::uuid;
    WHEN 'bank_transfer', 'bank_transfer_reversal', 'wht_remittance', 'wht_remittance_reversal' THEN
        -- 这四种:日期必填(它决定期间 —— FIN-10,不默认今天);没有成交价这一格 ——
        -- 转账两边金额在申请上就定了,代扣税只收本位币。
        IF p_payment_date IS NULL THEN
            RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
        END IF;
        IF p_fx_rate IS NOT NULL THEN
            RAISE EXCEPTION 'PAYMENT_REQUEST_TAKES_NO_RATE|%', v_r.code;
        END IF;
        IF v_r.kind = 'bank_transfer' THEN
            v_res := record_bank_transfer_internal(
                p_payment_date, v_r.bank_account_code, v_r.to_account_code,
                v_r.amount_ccy, v_r.amount_in, v_r.bank_reference,
                COALESCE(v_r.notes || ' · ', '') || v_r.code);
            v_tid := (v_res->>'transfer_id')::uuid;
            v_eid := (v_res->>'entry_id')::uuid;
        ELSIF v_r.kind = 'bank_transfer_reversal' THEN
            v_res := reverse_bank_transfer_internal(v_r.transfer_id, p_payment_date,
                                                    v_r.notes || ' · ' || v_r.code);
            v_eid := (v_res->>'reversal_entry_id')::uuid;
        ELSIF v_r.kind = 'wht_remittance' THEN
            v_res := remit_wht_internal(v_r.period_month, p_payment_date, v_r.filed_reference,
                                        v_r.bank_account_code,
                                        COALESCE(v_r.notes || ' · ', '') || v_r.code,
                                        v_r.amount_ccy);
            v_eid := (v_res->>'entry_id')::uuid;
        ELSE
            v_res := reverse_wht_remittance_internal(v_r.wht_remittance_id, p_payment_date,
                                                     v_r.notes || ' · ' || v_r.code);
            v_eid := (v_res->>'reversal_entry_id')::uuid;
        END IF;
    ELSE
        RAISE EXCEPTION 'PAYMENT_REQUEST_KIND_UNKNOWN|%|%', v_r.code, v_r.kind;
    END CASE;

    UPDATE payment_requests
       SET status = 'paid', paid_at = now(), paid_by = auth.uid(),
           result_payment_id = v_pid, result_transfer_id = v_tid, result_journal_entry_id = v_eid
     WHERE id = p_request_id;

    RETURN v_res || jsonb_build_object('request_id', p_request_id, 'request_code', v_r.code,
                                       'result_payment_id', v_pid,
                                       'result_transfer_id', v_tid,
                                       'result_journal_entry_id', v_eid);
END;
$function$
;

-- ── submit_bank_transfer_request ──
CREATE OR REPLACE FUNCTION public.submit_bank_transfer_request(p_planned_date date, p_from_account text, p_to_account text, p_amount_out numeric, p_amount_in numeric, p_bank_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id   uuid := gen_random_uuid();
    v_code text;
    v_res  jsonb;
    v_on   boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');

    IF p_planned_date IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;
    IF p_from_account IS NULL OR p_from_account NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_from_account, '?');
    END IF;
    IF p_to_account IS NULL OR p_to_account NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_to_account, '?');
    END IF;
    IF p_amount_out IS NULL OR p_amount_out <= 0 OR p_amount_in IS NULL OR p_amount_in <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;

    v_code := next_payment_request_code(p_planned_date);
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  amount_ccy, currency, amount_base, bank_account_code,
                                  to_account_code, amount_in, bank_reference,
                                  planned_date, notes, created_by)
    VALUES (v_id, v_code, 'bank_transfer',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            NULL,
            p_amount_out, bank_native_currency(p_from_account), 0, p_from_account,
            p_to_account, p_amount_in, NULLIF(btrim(COALESCE(p_bank_reference, '')), ''),
            p_planned_date, NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid());

    v_res := payment_request_dry_run(v_id);
    UPDATE payment_requests SET amount_base = (v_res->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('payment_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payment_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'code', v_code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
                              'amount_base', (v_res->>'amount_base')::numeric);
END;
$function$
;

-- ── submit_bank_transfer_reversal_request ──
CREATE OR REPLACE FUNCTION public.submit_bank_transfer_reversal_request(p_transfer_id uuid, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t    bank_transfers%ROWTYPE;
    v_id   uuid := gen_random_uuid();
    v_code text;
    v_res  jsonb;
    v_on   boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_t FROM bank_transfers WHERE id = p_transfer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_NOT_FOUND|%', COALESCE(p_transfer_id::text, '?');
    END IF;
    IF v_t.reversed_at IS NOT NULL THEN
        RAISE EXCEPTION 'TRANSFER_ALREADY_REVERSED|%', p_transfer_id;
    END IF;
    IF p_notes IS NULL OR btrim(p_notes) = '' THEN
        RAISE EXCEPTION 'REVERSAL_REASON_REQUIRED';
    END IF;
    IF EXISTS (SELECT 1 FROM payment_requests r
                WHERE r.transfer_id = p_transfer_id AND r.kind = 'bank_transfer_reversal'
                  AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'TRANSFER_REVERSAL_ALREADY_REQUESTED|%', p_transfer_id;
    END IF;

    v_code := next_payment_request_code(CURRENT_DATE);
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  amount_ccy, currency, amount_base, bank_account_code,
                                  to_account_code, amount_in, bank_reference,
                                  transfer_id, notes, created_by)
    VALUES (v_id, v_code, 'bank_transfer_reversal',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            NULL,
            v_t.amount_out, bank_native_currency(v_t.from_account), 0, v_t.from_account,
            v_t.to_account, v_t.amount_in, v_t.bank_reference,
            p_transfer_id, btrim(p_notes), auth.uid());

    v_res := payment_request_dry_run(v_id);
    UPDATE payment_requests SET amount_base = (v_res->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('payment_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payment_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'code', v_code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END);
END;
$function$
;

-- ── submit_wht_remittance_request ──
CREATE OR REPLACE FUNCTION public.submit_wht_remittance_request(p_period_month date, p_planned_date date DEFAULT NULL::date, p_filed_reference text DEFAULT NULL::text, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_month  date;
    v_ref    text;
    v_amount numeric;
    v_id     uuid := gen_random_uuid();
    v_code   text;
    v_res    jsonb;
    v_on     boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');
    PERFORM require_permission('module.finance.view');

    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'WHT_PERIOD_REQUIRED';
    END IF;
    v_month := date_trunc('month', p_period_month)::date;
    IF p_planned_date IS NULL THEN
        RAISE EXCEPTION 'WHT_REMIT_DATE_REQUIRED|%', v_month;
    END IF;
    v_ref := NULLIF(btrim(COALESCE(p_filed_reference, '')), '');
    IF v_ref IS NULL THEN
        RAISE EXCEPTION 'WHT_FILED_REFERENCE_REQUIRED|%', v_month;
    END IF;
    IF EXISTS (SELECT 1 FROM payment_requests r
                WHERE r.period_month = v_month AND r.kind = 'wht_remittance'
                  AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_ALREADY_REQUESTED|%', v_month;
    END IF;

    SELECT unremitted_base INTO v_amount FROM wht_liability_by_month WHERE period_month = v_month;
    IF COALESCE(v_amount, 0) <= 0 THEN
        RAISE EXCEPTION 'WHT_NOTHING_TO_REMIT|%|%', v_month, COALESCE(v_amount, 0);
    END IF;

    v_code := next_payment_request_code(p_planned_date);
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  amount_ccy, currency, amount_base, bank_account_code,
                                  period_month, filed_reference, planned_date, notes, created_by)
    VALUES (v_id, v_code, 'wht_remittance',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            NULL,
            v_amount, base_currency_code(), v_amount,
            COALESCE(NULLIF(btrim(COALESCE(p_bank_account, '')), ''), '1000'),
            v_month, v_ref, p_planned_date, NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid());

    v_res := payment_request_dry_run(v_id);
    UPDATE payment_requests SET amount_base = (v_res->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('payment_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payment_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'code', v_code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
                              'amount_base', (v_res->>'amount_base')::numeric);
END;
$function$
;

-- ── submit_wht_remittance_reversal_request ──
CREATE OR REPLACE FUNCTION public.submit_wht_remittance_reversal_request(p_remittance_id uuid, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_w    wht_remittances%ROWTYPE;
    v_st   text;
    v_id   uuid := gen_random_uuid();
    v_code text;
    v_res  jsonb;
    v_on   boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_w FROM wht_remittances WHERE id = p_remittance_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_NOT_FOUND|%', COALESCE(p_remittance_id::text, '?');
    END IF;
    SELECT status INTO v_st FROM journal_entries WHERE id = v_w.journal_entry_id;
    IF v_st IS DISTINCT FROM 'posted' THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_ALREADY_REVERSED|%', v_w.code;
    END IF;
    IF p_notes IS NULL OR btrim(p_notes) = '' THEN
        RAISE EXCEPTION 'REVERSAL_REASON_REQUIRED';
    END IF;
    IF EXISTS (SELECT 1 FROM payment_requests r
                WHERE r.wht_remittance_id = p_remittance_id AND r.kind = 'wht_remittance_reversal'
                  AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'WHT_REVERSAL_ALREADY_REQUESTED|%', v_w.code;
    END IF;

    v_code := next_payment_request_code(CURRENT_DATE);
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  amount_ccy, currency, amount_base,
                                  period_month, filed_reference, wht_remittance_id, notes, created_by)
    VALUES (v_id, v_code, 'wht_remittance_reversal',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            NULL,
            v_w.amount_base, base_currency_code(), v_w.amount_base,
            v_w.period_month, v_w.filed_reference, p_remittance_id, btrim(p_notes), auth.uid());

    v_res := payment_request_dry_run(v_id);
    UPDATE payment_requests SET amount_base = (v_res->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('payment_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payment_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'code', v_code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END);
END;
$function$
;

-- ── reverse_journal_entry ──
CREATE OR REPLACE FUNCTION public.reverse_journal_entry(p_entry_id uuid, p_reversal_date date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_src text;
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- ★ PAY-REQ-1(Tim 的 Q2(b)):付款与银行转账的分录【不许】从这里冲 ——
    --   这里冲掉一笔付款的分录,钱在总账上回来了,而付款行仍是 posted、核销仍然
    --   算数(结算按 payments.status 求和),而且绕过了冲销申请与 CFO 的批准。
    --   付款走冲销申请(reverse_payment 那一条);转账走转账冲销申请。
    --   ★ PAY-REQ-1 Batch B(Tim 的 Q3):代扣税缴纳也关在这里 —— 它的更正从此走
    --   wht_remittance_reversal 申请(reverse_wht_remittance_internal),经 CFO 批准。
    SELECT source_type, code INTO v_src, v_code FROM journal_entries WHERE id = p_entry_id;
    IF v_src IN ('payment', 'transfer', 'wht_remittance') THEN
        RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_code, v_src;
    END IF;
    RETURN reverse_journal_entry_internal(p_entry_id, p_reversal_date, p_memo);
END;
$function$;

-- ── 3 · 内层引擎调不到(apply_migration.sh 会在同一笔事务里再重放一遍 zzz_function_grants)──
REVOKE EXECUTE ON FUNCTION public.record_bank_transfer_internal(date, text, text, numeric, numeric, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_bank_transfer_internal(uuid, date, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.remit_wht_internal(date, date, text, text, text, numeric) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_wht_remittance_internal(uuid, date, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.record_bank_transfer_internal(date, text, text, numeric, numeric, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reverse_bank_transfer_internal(uuid, date, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.remit_wht_internal(date, date, text, text, text, numeric) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reverse_wht_remittance_internal(uuid, date, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_bank_transfer_internal(date, text, text, numeric, numeric, text, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.reverse_bank_transfer_internal(uuid, date, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.remit_wht_internal(date, date, text, text, text, numeric) FROM anon;
REVOKE EXECUTE ON FUNCTION public.reverse_wht_remittance_internal(uuid, date, text) FROM anon;

-- ── 4 · 自证 ─────────────────────────────────────────────────────────────────
CREATE TEMP TABLE payreqb_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved');

DO $proof$
DECLARE
    v_f text;
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|approvals switched off';
    END IF;
    IF EXISTS ((SELECT k, id FROM payreqb_pending_before EXCEPT SELECT k, id FROM payreqb_pending_after)
               UNION ALL
               (SELECT k, id FROM payreqb_pending_after EXCEPT SELECT k, id FROM payreqb_pending_before)) THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|a pending document changed state';
    END IF;
    IF (SELECT count(*) FROM approval_log) <> (SELECT log_n FROM payreqb_counts_before)
       OR (SELECT count(*) FROM journal_entries) <> (SELECT je_n FROM payreqb_counts_before)
       OR (SELECT count(*) FROM payments) <> (SELECT pay_n FROM payreqb_counts_before)
       OR (SELECT count(*) FROM bank_transfers) <> (SELECT bt_n FROM payreqb_counts_before)
       OR (SELECT count(*) FROM wht_remittances) <> (SELECT wht_n FROM payreqb_counts_before)
       OR (SELECT count(*) FROM payment_requests) <> (SELECT pr_n FROM payreqb_counts_before) THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|a ledger, payment, transfer, remittance, request or log row changed';
    END IF;
    IF EXISTS ((SELECT role, code FROM payreqb_codes_before EXCEPT
                SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)
               UNION ALL
               (SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                EXCEPT SELECT role, code FROM payreqb_codes_before)) THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|a role code list changed';
    END IF;
    FOREACH v_f IN ARRAY ARRAY[
        'public.record_bank_transfer_internal(date, text, text, numeric, numeric, text, text)',
        'public.reverse_bank_transfer_internal(uuid, date, text)',
        'public.remit_wht_internal(date, date, text, text, text, numeric)',
        'public.reverse_wht_remittance_internal(uuid, date, text)'] LOOP
        IF has_function_privilege('authenticated', v_f, 'EXECUTE') OR has_function_privilege('anon', v_f, 'EXECUTE') THEN
            RAISE EXCEPTION 'PAYREQB_PROOF|% is executable by authenticated or anon', v_f;
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM approval_gate_intersections((SELECT approval_level1_role_code FROM finance_settings),
                                       (SELECT approval_level2_role_code FROM finance_settings)) i
                WHERE i.approvers = 0) THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|some chain has no approver';
    END IF;
END;
$proof$;

COMMIT;
