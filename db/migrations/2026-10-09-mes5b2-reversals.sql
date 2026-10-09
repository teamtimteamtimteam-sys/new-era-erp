-- db/migrations/2026-10-09-mes5b2-reversals.sql
-- MES-5b-2 —— 撤回:一张电费单整张撤回、冲掉一张月结冲抵把估计放回去、经付款结过的费用单先冲付款、结算戳只经财务函数改
--   (MES 组的第十刀,v1.4.46;发布那一行在 docs/handbacks/MES-5b-2.md 的抬头)。
-- 由 db/scripts/build_mes5b2_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-09:MES-5b Step 0 的撤回那一部分 —— Q21–Q29 与 Q1 · Q32 · Q34–Q36 的撤回部分 —— 全部照推荐裁定;
--   并入 MES5B1-V37-NOT-ON-OPERATION-TRAIL;docs/surveys/MES-5b/STEP0-HANDBACK.md §14 E)
--   ① F2(Q21):reverse_expense 冲掉一张月结冲抵时,同一笔事务清掉它冲抵过的估计上的戳(不过分录 —— 冲掉的那张分录已经还回 2200);
--      那一炉此后被一张没撤回的电费分摊覆盖了就按名拒 RELIEF_ESTIMATE_NOW_ALLOCATED;processing_cost_variance 不再算冲销过的冲抵;
--      relieve_processing_accruals 的 'SGD', 1 换成从数据读的本位币。
--   ② F1(Q22):reverse_electricity_allocation(module.finance.edit,理由必填)—— 一笔事务、一个冲销日:冲费用单与分录
--      (reverse_expense_internal,与 reverse_expense 同一段);每一炉的实际电费行清戳再软删;被冲掉的估计清戳、取消软删、明写重新计提;
--      一行 electricity_allocation_reversals(金额遮蔽:列 + 列级授权 + _masked 视图 + 遮蔽规则,一支迁移)。
--   ③ Q23:electricity_allocation_lines.run_id 的唯一约束换成"一炉最多在一张没撤回的分摊里"的守卫;compute 的"已分过"与"重叠"不认撤回过的。
--   ④ Q24:经付款结过的费用单(每一种)按名拒 EXPENSE_HAS_SETTLEMENT,先冲付款;冲抵过预付款的按名拒 EXPENSE_HAS_PREPAYMENT_APPLIED。
--   ⑤ Q26:结算戳(remitted_* / relieved_* 四列)只许经五支财务函数改 —— guard_cost_entry_settled 认事务级标记,插入那一半也一样;
--      COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY。
--   ⑥ Q28:post_electricity_allocation 也要 module.finance.view。
--   ⑦ Q32 · 并入:审计记录 —— 撤回住在那张电费单下、也出现在它覆盖过的每一炉上;V37(operation_type_output_forms)挂到工序下。
--      变更记录绑一张新表;遮蔽规则 +3。processing_run_energy 只读没撤回的那一张分摊的那一行。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改、不冲任何一张既有单据、费用单、
--   付款、成本行、分录、加工单或设备;不过任何账单、不撤任何分摊;require_calibrated_since 保持空。不播任何行。
--
-- 【破窗】见 docs/surveys/MES-5b/STEP0-HANDBACK.md §11:旧应用调的函数都没改签名。旧的费用单页上冲销一张冲抵,从此也把估计放回去(更好,不坏);
--   冲销一张经付款结过的费用单从此按名拒(新);一次直连改结算戳从此按名拒(旧应用不发这种请求);旧的电费页没有撤回钮(线上 0 次分摊)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;
--   七个账号一个都没被停;既有的加工单、成本行与它的修改史、费用单、分录、付款与核销、预付款冲抵、设备、资产、分摊逐字未变;
--   变更记录一行都没动;新表是空的;run_id 不再唯一而守卫在;'SGD' 字面量不在了;anon 能执行的【恰好】两支;内层谁都调不到;
--   金额不在列级授权里;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免仍是 8、规则 114 条);提醒臂 59、待补的值 20 不变。
--   断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES5B2_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.electricity_allocation_reversals') IS NOT NULL OR to_regprocedure('public.reverse_electricity_allocation(uuid, text)') IS NOT NULL
       OR to_regprocedure('public.reverse_expense_internal(uuid, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B2_PRE|MES-5b-2 objects already exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'electricity_allocation_lines_run_id_key' AND contype = 'u'
                     AND conrelid = 'public.electricity_allocation_lines'::regclass) THEN
        RAISE EXCEPTION 'MES5B2_PRE|expected the unique constraint electricity_allocation_lines_run_id_key';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.relieve_processing_accruals(uuid[], numeric, date, text, text, uuid, text, text)'::regprocedure)
         NOT LIKE '%''SGD'', 1%' THEN
        RAISE EXCEPTION 'MES5B2_PRE|expected the SGD literal in relieve_processing_accruals (MES5A2-RELIEVE-SGD-LITERAL)';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES5B2_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5B2_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 111 THEN
        RAISE EXCEPTION 'MES5B2_PRE|expected 111 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59 THEN
        RAISE EXCEPTION 'MES5B2_PRE|operations_now should have 59 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 20 THEN
        RAISE EXCEPTION 'MES5B2_PRE|pending_values should have 20 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B2_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes5b2_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';
CREATE TEMP TABLE mes5b2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes5b2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes5b2_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes5b2_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_runs t) AS processing_runs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_cost_entries t) AS processing_cost_entries,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_cost_entry_history t) AS processing_cost_entry_history,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM expenses t) AS expenses,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM journal_entries t) AS journal_entries,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM journal_lines t) AS journal_lines,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM payments t) AS payments,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM payment_allocations t) AS payment_allocations,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM prepayment_applications t) AS prepayment_applications,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM devices t) AS devices,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM fixed_assets t) AS fixed_assets,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM fixed_asset_cost_entries t) AS fixed_asset_cost_entries,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM electricity_allocations t) AS electricity_allocations,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM electricity_allocation_lines t) AS electricity_allocation_lines,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM operation_type_output_forms t) AS operation_type_output_forms;

-- ── 1 · 新表(镜像原样):一张电费单的撤回 ─────────────────────────────────────────────

-- db/tables/electricity_allocation_reversals.sql
-- MES-5b-2(2026-10-09,MES-5b Step 0 Q22 · Q23 · Q32 · Q34,Tim):【一张电费单的撤回 —— 一张分摊最多一行】。
--   reverse_electricity_allocation 在【一笔事务、一个冲销日】里(Q22):
--     ① 冲掉那张费用单与它的分录(reverse_expense_internal —— reverse_expense 用的同一段;已付的那一张借回银行,未付的借回 2000);
--     ② 每一炉那条已结的实际电费行:先清掉结算戳(remitted_*),再软删 —— 软删照旧过一张 借 2200 / 贷 5110(fin_journal_cost_entry);
--     ③ 被它冲掉的每一条手敲估计:先清掉冲抵戳(relieved_at / relief_expense_id),再【取消软删】,再明写一张 借 5110 / 贷 2200 的
--        重新计提(取消软删不过账 —— fin_journal_cost_entry 只认"软删"与"改额"两种);
--     ④ 写这一行。
--   于是 2200 · 5110 · 6200 · 2000(或银行)回到分摊之前的余额,而那几炉回到分摊之前的样子 —— 可以再过一张改正过的账单(Q23)。
--   【一张分摊最多撤一次】allocation_id 唯一;撤回过的分摊不再算进"这一炉已经分过""时间段重叠"(electricity_allocation_compute)与
--     "一炉只在一张没撤回的分摊里"(guard_electricity_line_one_live_allocation)。分摊与它的行仍然只追加 —— 撤回是这里多一行,不是改那里。
--   【理由必填】reason(btrim 非空;reverse_freight_document 的先例)。没有审批(Q25:费用单没有,冲销费用单也没有)。
--   【金额遮蔽】bill_amount · actual_line_amount · restored_estimate_amount 只经 electricity_allocation_reversals_masked 读
--     (data.view_prices,与分摊那五列同一条规矩;Q32)。件数不遮。
--   【只追加】UPDATE / DELETE / TRUNCATE 语句级拒(guard_append_only_log)。只经 reverse_electricity_allocation 写。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes5b2-reversals.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.electricity_allocation_reversals (
    id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    allocation_id              uuid NOT NULL UNIQUE REFERENCES public.electricity_allocations (id),
    reversal_date              date NOT NULL,
    reason                     text NOT NULL CHECK (btrim(reason) <> ''),
    reversal_expense_id        uuid NOT NULL UNIQUE REFERENCES public.expenses (id),
    reversal_journal_entry_id  uuid NOT NULL REFERENCES public.journal_entries (id),
    payment_status             text NOT NULL CHECK (payment_status IN ('paid', 'unpaid')),
    bank_account_code          text,
    bill_amount                numeric NOT NULL CHECK (bill_amount > 0),
    actual_line_count          integer NOT NULL CHECK (actual_line_count >= 0),
    actual_line_amount         numeric NOT NULL CHECK (actual_line_amount >= 0),
    restored_estimate_count    integer NOT NULL CHECK (restored_estimate_count >= 0),
    restored_estimate_amount   numeric NOT NULL,
    created_at                 timestamptz NOT NULL DEFAULT now(),
    created_by                 uuid DEFAULT auth.uid(),
    CONSTRAINT electricity_allocation_reversals_payment_shape
        CHECK ((payment_status = 'paid' AND bank_account_code IS NOT NULL) OR (payment_status = 'unpaid' AND bank_account_code IS NULL))
);

COMMENT ON TABLE public.electricity_allocation_reversals IS
    'MES-5b-2:一张电费单的撤回(一张分摊最多一行,理由必填)。同一笔事务、同一个冲销日:冲掉费用单与分录(已付的借回银行)· 每一炉的实际电费行清戳后软删(借 2200 / 贷 5110)· 被冲掉的估计清戳、取消软删、明写重新计提(借 5110 / 贷 2200)。之后可以为同一段时间再过一张改正过的账单。金额只经 _masked 视图读(data.view_prices);只追加。';
COMMENT ON COLUMN public.electricity_allocation_reversals.reversal_expense_id IS
    '冲销那张费用单时生出的镜像费用单(reverse_expense_internal 的 mirror;它不是新的应付,ap_open_items 按 reversed_by_expense 排除它)。';
COMMENT ON COLUMN public.electricity_allocation_reversals.reversal_journal_entry_id IS
    '分摊那张分录的冲销件(借 2000 或银行 / 贷 2200 · 贷 6200)。实际电费行的软删分录与估计的重新计提各自另有一张(source_type = processing_cost)。';
COMMENT ON COLUMN public.electricity_allocation_reversals.restored_estimate_amount IS
    '取消软删、重新计提回 2200 的手敲估计之和(= 分摊行的 relieved_estimate_amount)。不设符号检查 —— 估计与 processing_cost_entries.amount_base 一样可以为负。';

CREATE INDEX electricity_allocation_reversals_reversal_journal_entry_id_rel ON public.electricity_allocation_reversals (reversal_journal_entry_id);

CREATE TRIGGER trg_electricity_allocation_reversals_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.electricity_allocation_reversals
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.electricity_allocation_reversals ENABLE ROW LEVEL SECURITY;
-- 读:与分摊同一句(财务或加工查看码)。金额走遮蔽视图。写只经函数。
CREATE POLICY "electricity_allocation_reversals select by permission" ON public.electricity_allocation_reversals
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.finance.view'::text, 'module.processing.view'::text]));

-- 字段级遮蔽:三列金额只经 electricity_allocation_reversals_masked 读。【加列必改这一行,并且同时改 _masked 视图】
REVOKE SELECT ON public.electricity_allocation_reversals FROM authenticated, anon;
GRANT SELECT (id, allocation_id, reversal_date, reason, reversal_expense_id, reversal_journal_entry_id, payment_status, bank_account_code,
              actual_line_count, restored_estimate_count, created_at, created_by)
    ON public.electricity_allocation_reversals TO authenticated;
REVOKE ALL ON public.electricity_allocation_reversals FROM anon;

-- ── 2 · 新视图(镜像原样):撤回的遮蔽伴生 ──────────────────────────────────────────────

-- db/views/electricity_allocation_reversals_masked.sql
-- MES-5b-2(2026-10-09,MES-5b Step 0 Q32,Tim):遮蔽伴生视图 —— electricity_allocation_reversals 的每一列都在,金额按 has_permission() 置空。
--   遮蔽的列:bill_amount · actual_line_amount · restored_estimate_amount → data.view_prices(分摊那五列同一条规矩,change_log_mask_rules 里同样三行)。
--   件数、理由、日期不遮。
-- 【属主权限】与 electricity_allocations_masked 同形同理由:把表的读策略(财务或加工查看码)原样写回视图体。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes5b2-reversals.sql.

CREATE VIEW public.electricity_allocation_reversals_masked WITH (security_invoker = off) AS
 SELECT id,
    allocation_id,
    reversal_date,
    reason,
    reversal_expense_id,
    reversal_journal_entry_id,
    payment_status,
    bank_account_code,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN bill_amount
            ELSE NULL::numeric
        END AS bill_amount,
    actual_line_count,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN actual_line_amount
            ELSE NULL::numeric
        END AS actual_line_amount,
    restored_estimate_count,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN restored_estimate_amount
            ELSE NULL::numeric
        END AS restored_estimate_amount,
    created_at,
    created_by
   FROM electricity_allocation_reversals
  WHERE has_any_permission(ARRAY['module.finance.view'::text, 'module.processing.view'::text]);

GRANT SELECT ON public.electricity_allocation_reversals_masked TO authenticated;
REVOKE ALL ON public.electricity_allocation_reversals_masked FROM anon;

-- ── 3 · 新函数(镜像原样):分摊行的守卫 · 冲一张费用单的那一段 · 撤回一张电费单 ─────────────────────────

-- db/functions/guard_electricity_line_one_live_allocation.sql
-- MES-5b-2(2026-10-09,MES-5b Step 0 Q23,Tim):【一炉最多在一张没撤回的分摊里】—— 取代 electricity_allocation_lines.run_id 的唯一约束。
--   唯一约束不认"撤回过":一炉的分摊撤回之后,它那一行仍在(分摊与行只追加),于是改正过的账单永远插不进同一炉。
--   这里只数【没撤回】的分摊(electricity_allocation_reversals 里没有它那一行)里的同一炉;有 → ELECTRICITY_RUN_ALREADY_ALLOCATED|PROC-…
--   (electricity_allocation_compute 在预览那一步就按同一句拒,这一道是落库时的最后一道 —— 两次过账之间由 post 的咨询锁串行)。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes5b2-reversals.sql.

CREATE OR REPLACE FUNCTION public.guard_electricity_line_one_live_allocation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF EXISTS (SELECT 1 FROM electricity_allocation_lines l
                WHERE l.run_id = NEW.run_id AND l.allocation_id <> NEW.allocation_id
                  AND NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals v WHERE v.allocation_id = l.allocation_id)) THEN
        RAISE EXCEPTION 'ELECTRICITY_RUN_ALREADY_ALLOCATED|%', (SELECT code FROM processing_runs WHERE id = NEW.run_id);
    END IF;
    IF EXISTS (SELECT 1 FROM electricity_allocation_lines l WHERE l.run_id = NEW.run_id AND l.allocation_id = NEW.allocation_id) THEN
        RAISE EXCEPTION 'ELECTRICITY_RUN_ALREADY_ALLOCATED|%', (SELECT code FROM processing_runs WHERE id = NEW.run_id);
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/reverse_expense_internal.sql
-- MES-5b-2(2026-10-09,MES-5b Step 0 Q22 · Q24,Tim):【冲销一张费用单的那一段 —— 两个调用方,一份实现】。
--   reverse_expense(冲一张费用单)与 reverse_electricity_allocation(撤回一张电费单)都经它冲费用单与分录:
--   原来写在 reverse_expense 里的那一整段(资本支出的两条规矩、冲分录、镜像费用单、成本退回并当场核对)原样搬到这里,
--   一个字的算术都没改 —— 只是不再问码(调用方问),也不再拒电费分摊的费用单(那一句留在 reverse_expense:分摊那一路正是从这里冲它)。
--   ★ 新加一道(Q24):经付款结过的费用单按名拒 EXPENSE_HAS_SETTLEMENT,冲抵过预付款的按名拒 EXPENSE_HAS_PREPAYMENT_APPLIED ——
--     放在这里而不是放在两个调用方里,于是【每一种】费用单、两条路都过同一道。
--   内层:不是 DEFINER,authenticated 调不到(zzz_function_grants.sql)。
--   reverse_expense 抬头那一段(FIN-22 / EQP-1b-iii / CAPEX-1 的两条规矩与它们的不对称)说的就是这里的算术,读那里。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes5b2-reversals.sql.

CREATE OR REPLACE FUNCTION public.reverse_expense_internal(p_expense_id uuid, p_memo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        expenses%ROWTYPE;
    v_mirror_id   uuid := gen_random_uuid();
    v_year        integer;
    v_seq         integer;
    v_mirror_code text;
    v_je          jsonb;
    -- EQP-1b-iii:追加模式那一笔的成本明细,以及它挂着的那张资产卡
    v_entry       record;
    v_asset       record;
    v_sum         numeric;   -- 未冲销明细之和(推导出来的那一侧)
    v_after       numeric;   -- 退回之后的表头(被维护的那一侧)
    v_settled     numeric;   -- MES-5b-2:经付款核销掉的(付款币种 = 单据币种)
    v_prepaid     numeric;   -- MES-5b-2:冲抵上去的预付款
BEGIN
    SELECT * INTO v_orig FROM expenses WHERE id = p_expense_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', p_expense_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_expense IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_ALREADY_REVERSED|%', v_orig.code;
    END IF;
    -- FIN-22:挂着固定资产台账行的资本性支出不许冲销 —— 冲掉它会留下无对价的
    -- 资产(或者说资产背后那笔应付蒸发)。先处置资产,或走人工分录改正。
    IF EXISTS (SELECT 1 FROM fixed_assets fa WHERE fa.expense_id = p_expense_id) THEN
        RAISE EXCEPTION 'EXPENSE_HAS_ASSET|%', v_orig.code;
    END IF;
    -- ★ MES-5b-2(2026-10-09,MES-5b Step 0 Q24,Tim):【经付款结过的费用单不许冲】—— 每一种费用单都一样(普通、报销、医疗、冲抵、电费分摊、资本)。
    --   冲掉它,应付清单上那一行消失,而指着它的核销行原样留着:2000 借方多出那笔钱、清单读 0,差额落进 list_ledger_reconciliation
    --   的 unexplained(Step 0 §1.4)。先经付款冲销申请把那笔付款冲掉,再冲这张单 —— reverse_freight_document 的 FREIGHT_HAS_SETTLEMENT 先例。
    --   ★ 预付款冲抵同一个形状(ap_open_items 把它算作已结):冲抵一经落下就不可改(prepayment_applications 不可变),没有撤回它的路,
    --   所以这里同样按名拒,并在 docs/known-issues.md 记下(MES5B2-PREPAYMENT-APPLIED-EXPENSE-NOT-REVERSIBLE)。
    SELECT COALESCE(sum(pa.allocated_ccy), 0) INTO v_settled
      FROM payment_allocations pa JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
     WHERE pa.expense_id = p_expense_id;
    IF v_settled > 0 THEN
        RAISE EXCEPTION 'EXPENSE_HAS_SETTLEMENT|%|%|%', v_orig.code, v_settled, v_orig.currency
          USING HINT = '这张费用单已经经付款结过 —— 先经付款冲销申请冲掉那笔付款,再冲销这张单';
    END IF;
    SELECT COALESCE(sum(ppa.amount_base), 0) INTO v_prepaid FROM prepayment_applications ppa WHERE ppa.expense_id = p_expense_id;
    IF v_prepaid > 0 THEN
        RAISE EXCEPTION 'EXPENSE_HAS_PREPAYMENT_APPLIED|%|%', v_orig.code, v_prepaid
          USING HINT = '这张费用单上冲抵过预付款,而冲抵撤不回 —— 冲销它会让应付清单与 2000 对不上';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- EQP-1b-iii:【追加模式】的资本支出 —— 冲销它必须把成本退回去。
    -- 上面那条 FIN-22 的守卫只认【建卡的那一笔】(fixed_assets.expense_id),
    -- 追加进来的每一笔(运费、关税、安装,以及设备发票本身)都不是任何一张卡的
    -- 出生证,所以一律冲得掉 —— 而分录冲掉了、cost_base 却原样不动。
    -- 实测(EQP-1b-ii 的回滚探针):100,000 → 100,000,明细 2 行 → 2 行。
    -- 总账从此与台账不一致,而【折旧读的是台账】。
    --
    -- 【为什么这里不加一列"这条明细已冲销"】那件事已经记在 expenses.status 上了,
    -- 而 fixed_asset_cost_entries 对 expense_id 是 UNIQUE —— 一条明细对一笔支出,
    -- 所以"这条明细还算不算数"= "它那笔支出冲了没有",一个事实一个地方。
    -- 本仓库对"已冲销"的既有写法正是这样一个 JOIN(ap_open_items 与
    -- apply_prepayment 都是),invoice_lines 那个冗余列是被【部分索引的 WHERE
    -- 引用不了另一张表】逼出来的,这里没有那个约束,也就不该抄那半代价。
    SELECT fce.id AS entry_id, fce.asset_id, fce.amount_base
      INTO v_entry
      FROM fixed_asset_cost_entries fce
     WHERE fce.expense_id = p_expense_id;

    IF FOUND THEN
        SELECT fa.code, fa.in_service_date, fa.status AS asset_status
          INTO v_asset
          FROM fixed_assets fa
         WHERE fa.id = v_entry.asset_id
           FOR UPDATE;

        -- 【与 record_expense 同一个铰链,方向相反】那边拒绝往已投用的资产上
        -- 【加】钱(ASSET_ALREADY_IN_SERVICE),理由是"已经提过的那几期会全错,
        -- 而它们已经过账、可能已经锁进期间"。【减】钱撞的是同一堵墙,所以判据
        -- 用同一句 in_service_date IS NOT NULL —— 一个铰链管两个方向。
        -- 【为什么不改成"提过折旧没有"】那是【第二个、更晚】的事实:一台已投用
        -- 但月结还没跑的资产会因此今天准冲、明天不准,而资产本身什么都没变;
        -- 而且加钱那边照旧拒,两个方向就不对称了。一个可判定的规则,不是两个。
        -- 【码另起一个,不复用 ASSET_ALREADY_IN_SERVICE】动作不同、话也不同:
        -- 那一句讲的是"投用后的追加是一次会计判断",对冲销是答非所问。
        IF v_asset.in_service_date IS NOT NULL THEN
            RAISE EXCEPTION 'ASSET_IN_SERVICE_COST_LOCKED|%|%|%',
                v_orig.code, v_asset.code, v_asset.in_service_date
              USING HINT = '这台资产已经投用,它的成本不能再被冲回 —— 这需要一次财务上的裁定';
        END IF;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    -- AP-RECON-1 Batch B:冲销日 = 今天与原分录日里较晚的那个(reversal_date_for;冲销不许早于原分录)
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, reversal_date_for(v_orig.journal_entry_id), 'Expense reversal ' || v_orig.code);

    -- 镜像开支单(同形状、status 'posted'、挂冲销分录、不带核销行)。
    -- 镜像行只是冲销的记录凭证,不是新的应付单据 —— ap_open_items 里按
    -- "被别的开支单指为 reversed_by_expense" 排除它。
    v_year := EXTRACT(YEAR FROM CURRENT_DATE)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE document_type_prefix('expense') || '-' || v_year::text || '-%';
    v_mirror_code := document_type_prefix('expense') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 【EQP-1b-iii · D3:employee_id 要抄,purchase_order_line_id 【不要】抄】
    -- 抄 employee_id:PAYEE-1a 加了这一列并放宽了 expenses_counterparty_shape
    -- (unpaid 必须【恰好】挂一个往来对象),但镜像 INSERT 没跟着改 —— 于是冲销
    -- 一张【欠员工】的报销单会撞出一条裸的 CHECK 违例。这是那一列缺席造成的,
    -- 不是别的。
    -- 不抄 purchase_order_line_id:镜像单是【记录凭证】,不是第二张账单。它一带上
    -- 那一列就会立刻重新占住那条采购单行,而"冲销之后行重新可计费"是 EQP-1b-ii
    -- 明文的行为(fixture 105 的 F3③ 钉着它)。那一列的列注释里点名交代过这件事,
    -- 交代的对象就是这一刀 —— 所以这里把两句话并排写下:一列抄,一列不抄。
    -- 【已逐列核对过一遍,不是只看这两列】expenses 共 20 列,镜像显式写 15 列;
    -- 另外 5 列:status(默认 posted,镜像是在册凭证)、reversed_by_expense(NULL,
    -- 镜像自己没被冲)、created_at(now())——三条都是有意的;employee_id 是唯一
    -- 的漏抄;purchase_order_line_id 是唯一有意不抄的。
    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id,
                          employee_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, CURRENT_DATE, v_orig.account_code,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_base,
            v_orig.payment_status, v_orig.bank_account_code, v_orig.supplier_id,
            v_orig.employee_id,
            v_orig.payee_name,
            'REVERSAL: ' || v_orig.code || COALESCE(' — ' || p_memo, ''),
            (v_je->>'reversal_id')::uuid, auth.uid());

    UPDATE expenses
    SET status = 'reversed', reversed_by_expense = v_mirror_id
    WHERE id = p_expense_id;

    -- ── EQP-1b-iii:把成本退回去,并【当场核对】──────────────────────────────
    -- 顺序要紧:上面那句 UPDATE 已经把原单置为 reversed,所以下面那个求和
    -- 【天然排除】了它 —— 判据读的是"未冲销明细之和",不是"减掉一笔之后应该是多少"。
    IF v_entry.entry_id IS NOT NULL THEN
        UPDATE fixed_assets
           SET cost_base = cost_base - v_entry.amount_base
         WHERE id = v_entry.asset_id
        RETURNING cost_base INTO v_after;

        -- 【两侧能不能分开动?能 —— 所以这是一条真检查,不是装饰】
        -- 左边是被 record_expense 逐笔累加维护的表头(一个缓存);
        -- 右边是从明细现算的和。两者由不同的代码路径产生,drift 是可能的,
        -- 而这正是 OPS-17 对 ties/balanced 那类自检提的那个问题:
        -- "要怎样它们才会不相等?" —— 这里答得出来。
        SELECT COALESCE(SUM(fce.amount_base), 0) INTO v_sum
          FROM fixed_asset_cost_entries fce
          JOIN expenses e ON e.id = fce.expense_id
         WHERE fce.asset_id = v_entry.asset_id
           AND e.status = 'posted';

        IF v_after <> v_sum THEN
            RAISE EXCEPTION 'ASSET_COST_LEDGER_DIVERGED|%|%|%',
                v_asset.code, v_after, v_sum;
        END IF;
    END IF;

    -- 【两条 CHECK 都不会被这次减法撞到,而这是可以证明的,不是碰巧】
    --   fixed_assets_cost_base_check      cost_base > 0
    --   fixed_assets_residual_below_cost  residual_base < cost_base
    -- 能被冲销的只有【追加】那些笔(建卡那一笔由 EXPENSE_HAS_ASSET 拦着),
    -- 而 residual_base 只在建卡时写入一次(全库只有 record_expense 写它),
    -- 当时就校验过 residual < 建卡金额。把追加全部冲光,表头也还剩建卡金额,
    -- 于是 cost_base ≥ 建卡金额 > residual_base ≥ 0,两条恒成立。
    RETURN jsonb_build_object(
        'reversal_expense_id', v_mirror_id,
        'code', v_mirror_code,
        'journal_code', v_je->>'code',
        'reversal_journal_id', v_je->>'reversal_id',
        'asset_id', v_entry.asset_id,
        'asset_cost_base_after', v_after
    );
END;
$function$;

-- db/functions/reverse_electricity_allocation.sql
-- MES-5b-2(2026-10-09,MES-5b Step 0 Q22 · Q23 · Q24 · Q25,Tim):【撤回一张电费单 —— 一笔事务、一个冲销日,带理由】(F1)。
--   门:module.finance.edit(过账、冲抵、冲销费用单用的同一个码;线上 admin · finance)。没有审批(Q25)。理由必填(reverse_freight_document 的先例)。
--   一笔事务里(Q22):
--     ① 冲掉费用单与分摊那张分录:reverse_expense_internal —— reverse_expense 用的同一段(未付的借回 2000,已付的借回银行;
--        冲销日 = reversal_date_for(分摊那张分录),期间锁在 post_journal_entry 里照判)。经付款结过的费用单在那里按名拒
--        EXPENSE_HAS_SETTLEMENT —— 先经付款冲销申请冲掉那笔付款(Q24)。
--     ② 每一炉那条已结的实际电费行:先清掉结算戳(remitted_*),再软删 —— 软删由 fin_journal_cost_entry 过 借 2200 / 贷 5110。
--        (守卫拒"一条结过的行被软删",所以两句分开;Step 0 §7。)
--     ③ 被它冲掉的每一条手敲估计:先清冲抵戳,再取消软删,再【明写】一张 借 5110 / 贷 2200 的重新计提(取消软删不过账 ——
--        fin_journal_cost_entry 只认软删与改额)。每一条一张,source_type = processing_cost,source_id = 那一条,与它自己的录入分录同形。
--     ④ 一行 electricity_allocation_reversals(金额遮蔽,同分摊)。
--   于是 2200 · 5110 · 6200 · 2000(或银行)回到过账之前的余额,那几炉回到过账之前的样子 —— 同一段时间可以再过一张改正过的账单(Q23:
--   compute 的"已分过""时间段重叠"与 guard_electricity_line_one_live_allocation 都不再认一张撤回过的分摊)。
--   【一个冲销日】分录冲销件落在 reversal_date_for(…),而 ② 的软删分录与 ③ 的重新计提由触发器 / 本函数落在 CURRENT_DATE ——
--     分摊那张分录的日期是账单日、账单日不许晚于今天,所以 reversal_date_for(…) = CURRENT_DATE;这里断言两者相等,不相等就拒(不会静悄悄地分在两天)。
--   结算戳只许经财务函数改(guard_cost_entry_settled 认事务级标记 evoltrya.cost_settlement_ctx,用毕即清)。
--   与 post 拿同一把咨询锁,所以"撤回"与"再过一张"不会交错。
--   拒:理由没给 ELECTRICITY_REVERSAL_REASON_REQUIRED;找不到 ELECTRICITY_ALLOCATION_NOT_FOUND;撤回过 ELECTRICITY_ALLOCATION_ALREADY_REVERSED;
--     那几条行或估计自过账以来被动过(本不可能 —— 戳只许经这几支函数改)ELECTRICITY_ALLOCATION_STATE_CHANGED。
--   返回 {reversal_id, allocation_id, reversal_expense_code, journal_code, actual_lines, restored_estimates, reversal_date}。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes5b2-reversals.sql.

CREATE OR REPLACE FUNCTION public.reverse_electricity_allocation(p_allocation_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_reason    text := NULLIF(btrim(COALESCE(p_reason, '')), '');
    v_a         electricity_allocations%ROWTYPE;
    v_code      text;
    v_date      date;
    v_x         jsonb;
    v_line_ids  uuid[];
    v_line_n    integer;
    v_line_amt  numeric;
    v_est_ids   uuid[];
    v_est_n     integer;
    v_est_amt   numeric;
    v_e         record;
    v_rev_id    uuid := gen_random_uuid();
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT code INTO v_code FROM expenses
     WHERE id = (SELECT expense_id FROM electricity_allocations WHERE id = p_allocation_id);
    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'ELECTRICITY_REVERSAL_REASON_REQUIRED|%', COALESCE(v_code, '?')
          USING HINT = '没有理由的撤回,事后没人答得出为什么';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('electricity_allocation')::bigint);
    SELECT * INTO v_a FROM electricity_allocations WHERE id = p_allocation_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ELECTRICITY_ALLOCATION_NOT_FOUND|%', COALESCE(p_allocation_id::text, '?');
    END IF;
    IF EXISTS (SELECT 1 FROM electricity_allocation_reversals v WHERE v.allocation_id = p_allocation_id) THEN
        RAISE EXCEPTION 'ELECTRICITY_ALLOCATION_ALREADY_REVERSED|%', v_code;
    END IF;

    v_date := reversal_date_for(v_a.journal_entry_id);
    IF v_date <> CURRENT_DATE THEN
        RAISE EXCEPTION 'ELECTRICITY_REVERSAL_DATE_SPLIT|%|%', v_date, CURRENT_DATE;
    END IF;

    -- 先锁住、再核对:各炉那条实际电费行仍是这张分摊结掉的样子;被它冲掉的估计仍是它冲掉的样子
    SELECT array_agg(c.id ORDER BY c.id), count(*), COALESCE(sum(c.amount_base), 0) INTO v_line_ids, v_line_n, v_line_amt
      FROM electricity_allocation_lines l JOIN processing_cost_entries c ON c.id = l.cost_entry_id
     WHERE l.allocation_id = p_allocation_id;
    PERFORM 1 FROM processing_cost_entries c WHERE c.id = ANY (v_line_ids) FOR UPDATE;
    IF EXISTS (SELECT 1 FROM processing_cost_entries c WHERE c.id = ANY (v_line_ids)
                 AND (c.deleted_at IS NOT NULL OR c.remitted_journal_entry_id IS DISTINCT FROM v_a.journal_entry_id)) THEN
        RAISE EXCEPTION 'ELECTRICITY_ALLOCATION_STATE_CHANGED|%|lines', v_code;
    END IF;
    SELECT array_agg(c.id ORDER BY c.id), count(*), COALESCE(sum(c.amount_base), 0) INTO v_est_ids, v_est_n, v_est_amt
      FROM processing_cost_entries c
     WHERE c.relief_expense_id = v_a.expense_id AND c.is_estimate AND c.deleted_at IS NOT NULL;
    PERFORM 1 FROM processing_cost_entries c WHERE c.id = ANY (v_est_ids) FOR UPDATE;
    IF v_est_n <> v_a.relieved_estimate_count OR v_est_amt <> v_a.relieved_estimate_amount THEN
        RAISE EXCEPTION 'ELECTRICITY_ALLOCATION_STATE_CHANGED|%|estimates', v_code;
    END IF;

    -- ① 费用单与分录(经付款结过的在里面按名拒)
    v_x := reverse_expense_internal(v_a.expense_id, 'Electricity bill reversed: ' || v_reason);

    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);
    -- ② 实际电费行:清戳,再软删(触发器过 借 2200 / 贷 5110)
    IF v_line_n > 0 THEN
        UPDATE processing_cost_entries SET remitted_at = NULL, remitted_journal_entry_id = NULL, updated_by = v_user
         WHERE id = ANY (v_line_ids);
        UPDATE processing_cost_entries SET deleted_at = now(), updated_by = v_user
         WHERE id = ANY (v_line_ids);
    END IF;
    -- ③ 估计:清戳,取消软删,明写重新计提(借 5110 / 贷 2200)
    IF v_est_n > 0 THEN
        UPDATE processing_cost_entries SET relieved_at = NULL, relief_expense_id = NULL, updated_by = v_user
         WHERE id = ANY (v_est_ids);
        UPDATE processing_cost_entries SET deleted_at = NULL, updated_by = v_user
         WHERE id = ANY (v_est_ids);
        FOR v_e IN SELECT c.id, c.cost_type, c.amount_base, r.code AS run_code
                     FROM processing_cost_entries c JOIN processing_runs r ON r.id = c.run_id
                    WHERE c.id = ANY (v_est_ids) ORDER BY r.code, c.id LOOP
            IF v_e.amount_base <> 0 THEN
                PERFORM post_journal_entry(v_date, 'Cost restored ' || v_e.run_code || ' (bill ' || v_code || ' reversed)',
                                           'processing_cost', v_e.id, fin_cost_lines(v_e.cost_type, v_e.amount_base, false));
            END IF;
        END LOOP;
    END IF;
    PERFORM set_config('evoltrya.cost_settlement_ctx', '', true);

    -- ④ 撤回的记录
    INSERT INTO electricity_allocation_reversals (id, allocation_id, reversal_date, reason, reversal_expense_id, reversal_journal_entry_id,
        payment_status, bank_account_code, bill_amount, actual_line_count, actual_line_amount, restored_estimate_count,
        restored_estimate_amount, created_by)
    VALUES (v_rev_id, p_allocation_id, v_date, v_reason, (v_x ->> 'reversal_expense_id')::uuid, (v_x ->> 'reversal_journal_id')::uuid,
        v_a.payment_status, v_a.bank_account_code, v_a.bill_amount, v_line_n, v_line_amt, v_est_n, v_est_amt, v_user);

    RETURN jsonb_build_object('reversal_id', v_rev_id, 'allocation_id', p_allocation_id, 'expense_code', v_code,
                              'reversal_expense_code', v_x ->> 'code', 'journal_code', v_x ->> 'journal_code',
                              'actual_lines', v_line_n, 'restored_estimates', v_est_n, 'reversal_date', v_date);
END;
$function$;

-- ── 4 · 分摊行:run_id 的唯一约束换成"一炉最多在一张没撤回的分摊里"(Q23)—— 索引与触发器与 db/tables/electricity_allocation_lines.sql 逐字同一份 ──
ALTER TABLE public.electricity_allocation_lines DROP CONSTRAINT electricity_allocation_lines_run_id_key;
CREATE INDEX electricity_allocation_lines_run_id_rel ON public.electricity_allocation_lines (run_id);
CREATE TRIGGER trg_electricity_allocation_lines_one_live
    BEFORE INSERT ON public.electricity_allocation_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_electricity_line_one_live_allocation();
COMMENT ON TABLE public.electricity_allocation_lines IS
    'MES-5a-2:一张电费单分给一炉的那一份(一行一炉;MES-5b-2 起一炉最多在一张没撤回的分摊里 —— guard_electricity_line_one_live_allocation)。依据印在每一行(Q22):recorded_energy = 这台机器这段时间每一炉都记了电量,按它分;run_time = 有一炉没记,整台机器按运行时长分。amount 只经 _masked 视图读(data.view_prices)。cost_entry_id = 为它写下的那条已结的实际电费成本行。只追加。';

-- ── 5 · 成本行:结算戳只许经财务函数改(Q26)—— 守卫函数与插入那一半的触发器,与 db/tables/processing_cost_entries.sql 逐字同一份 ──
CREATE OR REPLACE FUNCTION public.guard_cost_entry_settled()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_ctx boolean := current_setting('evoltrya.cost_settlement_ctx', true) IS NOT DISTINCT FROM '1';
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NOT v_ctx AND num_nonnulls(NEW.remitted_at, NEW.remitted_journal_entry_id, NEW.relieved_at, NEW.relief_expense_id) > 0 THEN
            RAISE EXCEPTION 'COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY|%',
                CASE WHEN NEW.remitted_at IS NOT NULL OR NEW.remitted_journal_entry_id IS NOT NULL THEN 'remitted' ELSE 'relieved' END;
        END IF;
        RETURN NEW;
    END IF;
    IF NOT v_ctx AND (NEW.remitted_at IS DISTINCT FROM OLD.remitted_at
                      OR NEW.remitted_journal_entry_id IS DISTINCT FROM OLD.remitted_journal_entry_id
                      OR NEW.relieved_at IS DISTINCT FROM OLD.relieved_at
                      OR NEW.relief_expense_id IS DISTINCT FROM OLD.relief_expense_id) THEN
        RAISE EXCEPTION 'COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY|%',
            CASE WHEN NEW.remitted_at IS DISTINCT FROM OLD.remitted_at
                      OR NEW.remitted_journal_entry_id IS DISTINCT FROM OLD.remitted_journal_entry_id THEN 'remitted' ELSE 'relieved' END;
    END IF;
    IF (OLD.remitted_at IS NOT NULL OR OLD.relieved_at IS NOT NULL)
       AND (NEW.amount_base IS DISTINCT FROM OLD.amount_base
            OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at
            OR NEW.cost_type IS DISTINCT FROM OLD.cost_type
            OR NEW.is_estimate IS DISTINCT FROM OLD.is_estimate) THEN
        RAISE EXCEPTION 'COST_ENTRY_SETTLED|%', OLD.cost_type;
    END IF;
    RETURN NEW;
END;
$fn$;


CREATE TRIGGER trg_processing_cost_entries_settlement_insert_guard
    BEFORE INSERT ON public.processing_cost_entries
    FOR EACH ROW EXECUTE FUNCTION public.guard_cost_entry_settled();

-- ── 6 · 换掉的函数(镜像原样,同签名)────────────────────────────────────────────────────

-- 冲销一笔开支单。【关于资本性支出,这里有两条规矩,不是一条】
-- * FIN-22(2026-08-06):生出资产卡的那一笔【永不】可冲(EXPENSE_HAS_ASSET)——
--   冲掉它会留下一台无对价的资产。先 dispose_fixed_asset,或走人工分录改正。
-- * EQP-1b-iii(2026-08-21):【追加】进来的那些笔(运费、关税、安装、设备发票)
--   可冲,而且冲销【必须把 cost_base 一起退回去】并当场核对不变量;
--   但资产一旦投用就按名拒(ASSET_IN_SERVICE_COST_LOCKED)。
--
-- ★★【CAPEX-1(2026-08-29)之后,这一条与 record_expense 那一条【不再是同一个铰链】,
--     而这句话原本就写在这里,现在必须改掉:两者不对称,不许合并】★★
--   原文写的是"与 record_expense 拒绝往已投用资产上追加用的是同一个铰链",
--   以及"投用之后,成本冻住"。**两句都不再成立**:
--   record_expense 那一侧已经改成【窄】拒 —— 经一条标了资本化的维修记录就加得上去
--   (政策 4.7),折旧从那个月起往后摊。
--   **而这一侧【一个字没动,而且应当一个字不动】**:
--     · 一次【追加】是一个新事件 —— 已经提过的折旧在当时是对的,往后走就行;
--     · 一次【冲销】断言那笔支出【本不该存在】—— 那是【回溯】的,
--       它要求已经提过的各期重新来过,而 4.7 没有授权任何回溯的东西。
--   所以两边看起来对称,理由完全不同。**把它们合并,或者"顺手也放开这一侧",
--   就是把一次估计变更与一次错误更正当成同一件事。**
--   (同一个不对称,月度例程用负差额封零表达过一次:向上的变化往前摊,
--    向下的变化仍是一次更正、仍走人工分录。)
-- 向下修正一台【已投用】资产的成本今天仍然没有任何路 —— docs/known-issues.md 有记录。
-- * MES-5a-2(2026-10-08):一次电费分摊的费用单【不许】单独冲(EXPENSE_IS_ELECTRICITY_ALLOCATION)—— 理由在那一句旁边。
-- * MES-5b-2(2026-10-09):① 冲销的那一段搬进 reverse_expense_internal(撤回电费单也用它);② 经付款结过 / 冲抵过预付款的按名拒
--   (在 internal 里,每一种费用单都过);③ 冲掉一张月结冲抵时把它冲抵掉的估计放回去(F2,Q21);④ 电费分摊的拒绝带上那张分摊的 id。

CREATE OR REPLACE FUNCTION public.reverse_expense(p_expense_id uuid, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig     expenses%ROWTYPE;
    v_alloc    uuid;
    v_hit      record;
    v_r        jsonb;
    v_restored integer := 0;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_orig FROM expenses WHERE id = p_expense_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', p_expense_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_expense IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_ALREADY_REVERSED|%', v_orig.code;
    END IF;
    -- MES-5a-2:一次电费分摊的费用单不许单独冲 —— 冲掉费用单而留着已结的电费行与被冲掉的估计,2200 就对不上了。
    -- ★ MES-5b-2(Q22):撤回走 reverse_electricity_allocation(那一页 /finance/electricity/<分摊>);拒绝里带着那张分摊的 id,页面据此指路。
    SELECT ea.id INTO v_alloc FROM electricity_allocations ea WHERE ea.expense_id = p_expense_id;
    IF FOUND THEN
        RAISE EXCEPTION 'EXPENSE_IS_ELECTRICITY_ALLOCATION|%|%', v_orig.code, v_alloc
          USING HINT = '电费单的费用单要在那张电费单的页面上整张撤回';
    END IF;
    -- ★ MES-5b-2(2026-10-09,MES-5b Step 0 Q21,Tim):【冲掉一张月结冲抵的费用单,把它冲抵掉的估计放回去】(F2)。
    --   月结冲抵只盖戳(relieved_at / relief_expense_id),不软删;它自己的分录清掉 2200。冲掉那张分录就把 2200 还回来了 ——
    --   所以这里【不过任何分录】,只在同一笔事务里清掉那几条估计上的戳:它们回到"未结",月结那一步与结算页又看得见它们,也能再冲抵一次。
    --   拒(先于任何写):一条电费估计所在的那一炉此后被一张【没撤回】的电费分摊覆盖了 —— 放回去会让那一炉同时带着估计与实际
    --   (MES-5a Q24)→ RELIEF_ESTIMATE_NOW_ALLOCATED|PROC-…|那张分摊的费用单号;走法:先撤回那张分摊。
    IF EXISTS (SELECT 1 FROM processing_cost_entries c WHERE c.relief_expense_id = p_expense_id) THEN
        -- 与 post / reverse_electricity_allocation 同一把咨询锁:判"那一炉有没有被一张没撤回的分摊覆盖"与它们串行
        PERFORM pg_advisory_xact_lock(hashtext('electricity_allocation')::bigint);
    END IF;
    SELECT r.code AS run_code, ae.code AS alloc_code INTO v_hit
      FROM processing_cost_entries c
      JOIN processing_runs r ON r.id = c.run_id
      JOIN electricity_allocation_lines l ON l.run_id = c.run_id
      JOIN electricity_allocations a ON a.id = l.allocation_id
      JOIN expenses ae ON ae.id = a.expense_id
     WHERE c.relief_expense_id = p_expense_id AND c.cost_type = 'electricity'
       AND NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals v WHERE v.allocation_id = a.id)
     ORDER BY r.code LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'RELIEF_ESTIMATE_NOW_ALLOCATED|%|%', v_hit.run_code, v_hit.alloc_code
          USING HINT = '那一炉此后过了一张电费单 —— 先撤回那张电费单,再冲销这张冲抵';
    END IF;

    -- 冲费用单与分录(资本支出的两条规矩、经付款结过的拒绝都在里面 —— 一份实现,两个调用方)
    v_r := reverse_expense_internal(p_expense_id, p_memo);

    -- F2:清掉冲抵戳(结算戳只许经财务函数改 —— guard_cost_entry_settled 认这个事务级标记,用毕即清)
    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);
    UPDATE processing_cost_entries
       SET relieved_at = NULL, relief_expense_id = NULL, updated_by = auth.uid()
     WHERE relief_expense_id = p_expense_id;
    GET DIAGNOSTICS v_restored = ROW_COUNT;
    PERFORM set_config('evoltrya.cost_settlement_ctx', '', true);

    RETURN v_r || jsonb_build_object('restored_estimates', v_restored);
END;
$function$;

-- db/functions/electricity_allocation_compute.sql
-- MES-5a-2(2026-10-08,MES-0 Q26 · Q27;MES-5a Step 0 Q21–Q28,Tim):【一张电费单怎么分 —— 分账的规则只住在这里】。
--   预览(preview_electricity_allocation)与过账(post_electricity_allocation)都调它、都原样用它算出来的数(AGENTS.md
--   「一个预览的屏幕问数据库」)。它什么都不写。内层:不是 DEFINER,authenticated 调不到。
--
--   ① 拒:时间段没给 / 倒着 / 结束在将来;账单金额或 kWh 不是正数;币种没给;【不是本位币】(currencies.is_base,Q28)→
--      ELECTRICITY_BILL_CURRENCY_NOT_BASE|币种|本位币;与一张已有的分摊时间段重叠 → ELECTRICITY_PERIOD_OVERLAPS|EXP-…|起|止。
--   ② 每一台电表这段时间量到多少:这段时间(period_from 00:00 到 period_to 24:00,新加坡时间)里它的【当前】读数(没被更正、
--      没被撤回),按 (read_at, id) 排,相邻两条之差的和;后一条是寄存器清零的那一对不计(跨过清零的量不出来)。
--      少于两条读数 → 这台表"量不出来"(measured = false),不是零。
--   ③ 每一台有电表的机器(电表的 equipment_id):它的电表都量得出来 → machine_kwh = 各表之和;有一台量不出来 → 整台机器
--      "量不出来",它这段时间的电不算"量到的"(落进不计量),它的炉一条都不分、它们的估计一条都不冲(Q26:只冲覆盖到的)。
--      共用池电表(equipment_id 为空)量到的 → shared_pool_kwh,留在 6200(Q25,V25 没给之前;给了也不在本刀里按它摊)。
--   ④ 每一台量得出来的机器,这段时间里(process_date 在段内)在它上面已提交、没回滚的每一炉:
--      【每一炉】都记了自己的 energy_kwh(更正链末端,有值)而且合计 > 0 → 按记下的电量的比例分(basis = recorded_energy);
--      否则整台机器【全部】按运行时长(ended_at − started_at,分钟)分(basis = run_time)(Q22,Tim)。运行时长缺 → 拒
--      ELECTRICITY_RUN_TIME_MISSING|PROC-…;合计为零 → 拒 ELECTRICITY_RUN_TIME_ZERO|机器。一炉已经分到过 → 拒 ELECTRICITY_RUN_ALREADY_ALLOCATED。
--      每一炉的 kWh = machine_kwh × 份额,到 0.001;最后一炉拿余数,于是各炉之和【恰好】等于 machine_kwh。
--      这台机器这段时间一炉都没有 → 它量到的电进 unallocated_metered_kwh(留在 6200)。
--   ⑤ 量到的合计(各机器 + 共用池)不许超过账单 kWh → ELECTRICITY_METERED_EXCEEDS_BILL|量到|账单(多出来的电从哪儿来,说不出来)。
--      unmetered_kwh = 账单 kWh − 量到的。单价 = 账单金额 ÷ 账单 kWh。
--   ⑥ 每一炉的金额 = kWh × 单价,到分;overhead_amount = 账单金额 − 各炉之和(6200)。分到分的尾差若让各炉之和比账单多(只可能是几分),
--      从最大的那一炉扣回 —— 于是 overhead 永不为负、两边恰好平。
--   ⑦ 要冲掉的估计:这些炉上手敲的、还没结过的电费估计(is_estimate,没软删,没冲抵,没汇出)。没被覆盖的炉上的一条都不列。
--   ⑧ 分录(过账那一张,预览里原样给出):借 2200 各炉之和 · 借 6200 余数 · 贷 应付 2000(未付)或银行(已付)账单全额。
--      各炉的成本行自己的录入分录(借 5110 / 贷 2200)与估计被冲掉时的冲销分录(借 2200 / 贷 5110)由 fin_journal_cost_entry 照旧过。
--   返回 jsonb(见末尾)。
--   ★ MES-5b-2(2026-10-09,MES-5b Step 0 Q23,Tim):"时间段重叠"与"这一炉已经分过"都【不认撤回过的分摊】
--     (electricity_allocation_reversals 里有它那一行)—— 撤回之后,同一段时间可以再过一张改正过的账单。
--     要冲掉的估计照旧只取"没软删、没冲抵、没汇出"的 —— 撤回把被冲掉的估计放回了这个样子,所以它们会被改正过的那一张再冲一次。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.

CREATE OR REPLACE FUNCTION public.electricity_allocation_compute(p_period_from date, p_period_to date, p_bill_amount numeric, p_bill_kwh numeric, p_currency text, p_payment_status text, p_bank_account text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base      text := base_currency_code();
    v_start     timestamptz;
    v_end       timestamptz;
    v_clash     record;
    v_mruns     jsonb;
    v_txt       text;
    v_meter     record;
    v_r         record;
    v_prev      numeric;
    v_kwh       numeric;
    v_n         int;
    v_reset     boolean;
    v_meters    jsonb := '[]'::jsonb;
    v_pool      jsonb := '[]'::jsonb;
    v_machines  jsonb := '[]'::jsonb;
    v_runs      jsonb := '[]'::jsonb;
    v_est       jsonb := '[]'::jsonb;
    v_mach      record;
    v_machine_kwh numeric;
    v_measured  boolean;
    v_all_own   boolean;
    v_sum_w     numeric;
    v_basis     text;
    v_cnt       int;
    v_i         int;
    v_run       record;
    v_w         numeric;
    v_run_kwh   numeric;
    v_given     numeric;
    v_metered   numeric := 0;
    v_pool_kwh  numeric := 0;
    v_unalloc   numeric := 0;
    v_alloc_kwh numeric := 0;
    v_price     numeric;
    v_alloc_amt numeric := 0;
    v_overhead  numeric;
    v_excess    numeric;
    v_big       int;
    v_est_amt   numeric := 0;
    v_est_n     int := 0;
    v_credit    text;
    v_journal   jsonb;
    v_k         int;
BEGIN
    -- ① 参数与本位币 ──────────────────────────────────────────────────────
    IF p_period_from IS NULL OR p_period_to IS NULL THEN
        RAISE EXCEPTION 'ELECTRICITY_PERIOD_REQUIRED';
    END IF;
    IF p_period_from > p_period_to THEN
        RAISE EXCEPTION 'ELECTRICITY_PERIOD_INVALID|%|%', p_period_from, p_period_to;
    END IF;
    IF p_period_to > CURRENT_DATE THEN
        RAISE EXCEPTION 'ELECTRICITY_PERIOD_IN_FUTURE|%', p_period_to;
    END IF;
    IF p_bill_amount IS NULL OR p_bill_amount <= 0 THEN
        RAISE EXCEPTION 'ELECTRICITY_BILL_AMOUNT_INVALID';
    END IF;
    IF p_bill_kwh IS NULL OR p_bill_kwh <= 0 THEN
        RAISE EXCEPTION 'ELECTRICITY_BILL_KWH_INVALID';
    END IF;
    IF p_currency IS NULL OR btrim(p_currency) = '' THEN
        RAISE EXCEPTION 'ELECTRICITY_BILL_CURRENCY_REQUIRED';
    END IF;
    IF v_base IS NULL THEN
        RAISE EXCEPTION 'BASE_CURRENCY_NOT_SET';
    END IF;
    IF upper(btrim(p_currency)) <> v_base THEN
        RAISE EXCEPTION 'ELECTRICITY_BILL_CURRENCY_NOT_BASE|%|%', upper(btrim(p_currency)), v_base;
    END IF;
    IF p_payment_status IS NULL OR p_payment_status NOT IN ('paid', 'unpaid') THEN
        RAISE EXCEPTION 'PAYMENT_STATUS_INVALID|%', COALESCE(p_payment_status, '?');
    END IF;
    IF p_payment_status = 'paid' THEN
        IF p_bank_account IS NULL OR bank_native_currency(p_bank_account) IS DISTINCT FROM v_base THEN
            RAISE EXCEPTION 'ELECTRICITY_BANK_NOT_BASE|%|%', COALESCE(p_bank_account, '?'), v_base;
        END IF;
        v_credit := p_bank_account;
    ELSE
        v_credit := '2000';
    END IF;
    SELECT a.period_from, a.period_to, e.code INTO v_clash
      FROM electricity_allocations a JOIN expenses e ON e.id = a.expense_id
     WHERE daterange(a.period_from, a.period_to, '[]') && daterange(p_period_from, p_period_to, '[]')
       AND NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals v WHERE v.allocation_id = a.id)
     ORDER BY a.period_from LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'ELECTRICITY_PERIOD_OVERLAPS|%|%|%', v_clash.code, v_clash.period_from, v_clash.period_to;
    END IF;

    v_start := (p_period_from::timestamp) AT TIME ZONE 'Asia/Singapore';
    v_end   := ((p_period_to + 1)::timestamp) AT TIME ZONE 'Asia/Singapore';

    -- ② 每一台电表这段时间量到多少(不建临时表:预览可能跑在只读事务里)───────────────
    FOR v_meter IN
        SELECT d.id, d.code, d.name, d.equipment_id FROM devices d
         WHERE d.kind = 'meter'
           AND (d.retired_at IS NULL
                OR EXISTS (SELECT 1 FROM meter_readings r WHERE r.device_id = d.id AND r.read_at >= v_start AND r.read_at < v_end))
         ORDER BY d.code
    LOOP
        v_prev := NULL; v_kwh := 0; v_n := 0; v_reset := false;
        FOR v_r IN
            SELECT r.register_kwh, r.is_register_reset FROM meter_readings r
             WHERE r.device_id = v_meter.id AND r.read_at >= v_start AND r.read_at < v_end AND NOT r.withdrawn
               AND NOT EXISTS (SELECT 1 FROM meter_readings x WHERE x.corrects_id = r.id)
             ORDER BY r.read_at, r.id
        LOOP
            v_n := v_n + 1;
            IF v_prev IS NOT NULL THEN
                IF v_r.is_register_reset THEN
                    v_reset := true;
                ELSE
                    v_kwh := v_kwh + (v_r.register_kwh - v_prev);
                END IF;
            END IF;
            v_prev := v_r.register_kwh;
        END LOOP;
        v_meters := v_meters || jsonb_build_object('device_id', v_meter.id, 'code', v_meter.code, 'name', v_meter.name,
                                                   'equipment_id', v_meter.equipment_id, 'kwh', CASE WHEN v_n >= 2 THEN v_kwh END,
                                                   'readings', v_n, 'has_reset', v_reset, 'measured', v_n >= 2);
    END LOOP;

    SELECT COALESCE(jsonb_agg(e - 'equipment_id' ORDER BY e ->> 'code'), '[]'::jsonb),
           COALESCE(sum((e ->> 'kwh')::numeric) FILTER (WHERE (e ->> 'measured')::boolean), 0)
      INTO v_pool, v_pool_kwh
      FROM jsonb_array_elements(v_meters) e WHERE e ->> 'equipment_id' IS NULL;

    -- ③ ④ 每一台有电表的机器 ────────────────────────────────────────────────
    FOR v_mach IN
        SELECT (e ->> 'equipment_id')::uuid AS equipment_id, fa.code AS equipment_code, fa.description,
               bool_and((e ->> 'measured')::boolean) AS measured, sum((e ->> 'kwh')::numeric) AS kwh,
               jsonb_agg(e - 'equipment_id' ORDER BY e ->> 'code') AS meters
          FROM jsonb_array_elements(v_meters) e JOIN fixed_assets fa ON fa.id = (e ->> 'equipment_id')::uuid
         WHERE e ->> 'equipment_id' IS NOT NULL
         GROUP BY (e ->> 'equipment_id')::uuid, fa.code, fa.description
         ORDER BY fa.code
    LOOP
        v_measured := v_mach.measured;
        v_machine_kwh := CASE WHEN v_measured THEN v_mach.kwh END;
        v_basis := NULL; v_cnt := 0;
        IF v_measured THEN
            v_metered := v_metered + v_machine_kwh;
            -- 这台机器这段时间里的每一炉(已提交、没回滚、process_date 在段内)
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'run_id', r.id, 'code', r.code,
                       'own_kwh', (SELECT v.value_number FROM processing_run_values v
                                    WHERE v.run_id = r.id AND v.field_code = 'energy_kwh' AND v.value_number IS NOT NULL
                                      AND NOT EXISTS (SELECT 1 FROM processing_run_values x WHERE x.corrects_id = v.id)
                                    ORDER BY v.id DESC LIMIT 1),
                       'minutes', CASE WHEN r.started_at IS NOT NULL AND r.ended_at IS NOT NULL
                                       THEN round(extract(epoch FROM (r.ended_at - r.started_at)) / 60.0, 2) END,
                       'allocated', EXISTS (SELECT 1 FROM electricity_allocation_lines l WHERE l.run_id = r.id
                                              AND NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals v
                                                               WHERE v.allocation_id = l.allocation_id)))
                     ORDER BY r.code), '[]'::jsonb)
              INTO v_mruns
              FROM processing_runs r
             WHERE r.equipment_id = v_mach.equipment_id AND r.status = 'committed' AND r.deleted_at IS NULL
               AND r.process_date BETWEEN p_period_from AND p_period_to;
            v_cnt := jsonb_array_length(v_mruns);
            IF v_cnt = 0 THEN
                v_unalloc := v_unalloc + v_machine_kwh;
            ELSE
                SELECT x ->> 'code' INTO v_txt FROM jsonb_array_elements(v_mruns) x WHERE (x ->> 'allocated')::boolean
                 ORDER BY x ->> 'code' LIMIT 1;
                IF v_txt IS NOT NULL THEN
                    RAISE EXCEPTION 'ELECTRICITY_RUN_ALREADY_ALLOCATED|%', v_txt;
                END IF;
                SELECT bool_and(x ->> 'own_kwh' IS NOT NULL), sum((x ->> 'own_kwh')::numeric) INTO v_all_own, v_sum_w
                  FROM jsonb_array_elements(v_mruns) x;
                IF v_all_own AND v_sum_w > 0 THEN
                    v_basis := 'recorded_energy';
                ELSE
                    v_basis := 'run_time';
                    SELECT x ->> 'code' INTO v_txt FROM jsonb_array_elements(v_mruns) x WHERE x ->> 'minutes' IS NULL
                     ORDER BY x ->> 'code' LIMIT 1;
                    IF v_txt IS NOT NULL THEN
                        RAISE EXCEPTION 'ELECTRICITY_RUN_TIME_MISSING|%', v_txt;
                    END IF;
                    SELECT sum((x ->> 'minutes')::numeric) INTO v_sum_w FROM jsonb_array_elements(v_mruns) x;
                    IF COALESCE(v_sum_w, 0) <= 0 THEN
                        RAISE EXCEPTION 'ELECTRICITY_RUN_TIME_ZERO|%', v_mach.equipment_code;
                    END IF;
                END IF;
                v_i := 0; v_given := 0;
                FOR v_run IN SELECT x FROM jsonb_array_elements(v_mruns) x LOOP
                    v_i := v_i + 1;
                    v_w := CASE WHEN v_basis = 'recorded_energy' THEN (v_run.x ->> 'own_kwh')::numeric ELSE (v_run.x ->> 'minutes')::numeric END;
                    IF v_i < v_cnt THEN
                        v_run_kwh := round(v_machine_kwh * v_w / v_sum_w, 3);
                    ELSE
                        v_run_kwh := v_machine_kwh - v_given;
                    END IF;
                    v_given := v_given + v_run_kwh;
                    v_runs := v_runs || jsonb_build_object(
                        'run_id', v_run.x ->> 'run_id', 'code', v_run.x ->> 'code', 'equipment_id', v_mach.equipment_id,
                        'equipment_code', v_mach.equipment_code, 'basis', v_basis, 'own_kwh', v_run.x -> 'own_kwh',
                        'minutes', v_run.x -> 'minutes', 'weight', v_w, 'share', round(v_w / v_sum_w, 6),
                        'machine_kwh', v_machine_kwh, 'kwh', v_run_kwh);
                END LOOP;
                v_alloc_kwh := v_alloc_kwh + v_machine_kwh;
            END IF;
        END IF;
        v_machines := v_machines || jsonb_build_object(
            'equipment_id', v_mach.equipment_id, 'equipment_code', v_mach.equipment_code, 'description', v_mach.description,
            'measured', v_measured, 'kwh', v_machine_kwh, 'basis', v_basis, 'runs', v_cnt, 'meters', v_mach.meters);
    END LOOP;

    -- ⑤ 量到的合计不许超过账单 ───────────────────────────────────────────────
    v_metered := v_metered + v_pool_kwh;
    IF v_metered > p_bill_kwh THEN
        RAISE EXCEPTION 'ELECTRICITY_METERED_EXCEEDS_BILL|%|%', v_metered, p_bill_kwh;
    END IF;
    v_price := p_bill_amount / p_bill_kwh;

    -- ⑥ 每一炉的金额;尾差 ──────────────────────────────────────────────────
    FOR v_k IN 0 .. jsonb_array_length(v_runs) - 1 LOOP
        v_runs := jsonb_set(v_runs, ARRAY[v_k::text, 'amount'],
                            to_jsonb(round((v_runs -> v_k ->> 'kwh')::numeric * p_bill_amount / p_bill_kwh, 2)));
        v_alloc_amt := v_alloc_amt + (v_runs -> v_k ->> 'amount')::numeric;
    END LOOP;
    v_excess := v_alloc_amt - p_bill_amount;
    IF v_excess > 0 THEN
        SELECT (o.ord - 1)::int INTO v_big FROM jsonb_array_elements(v_runs) WITH ORDINALITY AS o(e, ord)
         ORDER BY (o.e ->> 'amount')::numeric DESC, o.ord LIMIT 1;
        v_runs := jsonb_set(v_runs, ARRAY[v_big::text, 'amount'], to_jsonb((v_runs -> v_big ->> 'amount')::numeric - v_excess));
        v_alloc_amt := p_bill_amount;
    END IF;
    v_overhead := p_bill_amount - v_alloc_amt;

    -- ⑦ 要冲掉的估计(只在被覆盖的炉上)─────────────────────────────────────────
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', e.id, 'run_id', e.run_id, 'run_code', r.code, 'amount', e.amount_base)
                              ORDER BY r.code, e.created_at, e.id), '[]'::jsonb),
           COALESCE(sum(e.amount_base), 0), count(*)
      INTO v_est, v_est_amt, v_est_n
      FROM processing_cost_entries e JOIN processing_runs r ON r.id = e.run_id
     WHERE e.run_id IN (SELECT (x ->> 'run_id')::uuid FROM jsonb_array_elements(v_runs) x)
       AND e.cost_type = 'electricity' AND e.is_estimate AND e.deleted_at IS NULL
       AND e.remitted_at IS NULL AND e.relieved_at IS NULL;

    -- ⑧ 分录 ───────────────────────────────────────────────────────────────
    v_journal := '[]'::jsonb;
    IF v_alloc_amt > 0 THEN
        v_journal := v_journal || jsonb_build_object('account_code', '2200', 'side', 'debit', 'currency', v_base,
                                                     'amount_ccy', v_alloc_amt, 'line_memo', 'electricity shares of the runs covered');
    END IF;
    IF v_overhead > 0 THEN
        v_journal := v_journal || jsonb_build_object('account_code', '6200', 'side', 'debit', 'currency', v_base,
                                                     'amount_ccy', v_overhead, 'line_memo', 'unmetered, shared and unallocated electricity');
    END IF;
    v_journal := v_journal || jsonb_build_object('account_code', v_credit, 'side', 'credit', 'currency', v_base,
                                                 'amount_ccy', p_bill_amount, 'line_memo', 'electricity bill');

    RETURN jsonb_build_object(
        'period_from', p_period_from, 'period_to', p_period_to, 'currency', v_base,
        'bill_amount', p_bill_amount, 'bill_kwh', p_bill_kwh, 'price_per_kwh', round(v_price, 6),
        'metered_kwh', v_metered, 'allocated_kwh', v_alloc_kwh, 'shared_pool_kwh', v_pool_kwh,
        'unallocated_metered_kwh', v_unalloc, 'unmetered_kwh', p_bill_kwh - v_metered,
        'allocated_amount', v_alloc_amt, 'overhead_amount', v_overhead,
        'relieved_estimate_amount', v_est_amt, 'relieved_estimate_count', v_est_n,
        'shared_pool_rule', (SELECT s.shared_pool_rule FROM electricity_settings s WHERE s.id),
        'machines', v_machines, 'pool_meters', v_pool, 'runs', v_runs, 'estimates', v_est, 'journal', v_journal);
END;
$function$;

-- db/functions/post_electricity_allocation.sql
-- MES-5a-2(2026-10-08,MES-0 Q26;MES-5a Step 0 Q24 · Q27 · Q28,Tim):【一张电费单过账 —— 它就是这张账单【唯一】的一笔】。
--   门:module.finance.edit(分摊、汇出、冲抵加工成本用的同一个码;线上 admin · finance)。没有新的审批(Q29):这是一张账单的
--   入账,不是一张等人批的单据;未付的那一张之后走既有的付款申请(1,000 分级)。
--   一笔事务里(Q24):
--     ① 规则全部来自 electricity_allocation_compute(预览用的同一支;它拒的这里一样拒 —— 外币、时间段重叠、量到的超过账单……)。
--        之前先拿一把咨询锁,于是两次同时过账不会都看见"不重叠"。
--     ② 记一张费用单(EXP-YYYY-NNNN,编号与 record_expense / relieve_processing_accruals 同一套;科目 5110 —— 这张单的名义科目,
--        与冲抵加工成本那一路同一个;真正的借方在下面那张分录里);币种 = 本位币【从数据读】(currencies.is_base,不写字面量 —— Q35),本位币对自己的汇率是 1。
--     ③ 那张分录(日期 = 账单日):借 2200 各炉之和 · 借 6200 余数 · 贷 应付 2000(未付)或银行(已付)账单全额。
--     ④ 每一炉一条实际电费成本行(录入即照旧借 5110 / 贷 2200),落库时就标成已结(remitted_at = 账单日、remitted_journal_entry_id = ③)——
--        于是谁都改不了它的额、删不掉它(guard_cost_entry_settled);一行 electricity_allocation_lines 指着它。
--     ⑤ 这些炉上手敲的、还没结过的电费估计:标 relieved_at = 账单日、relief_expense_id = ② 并【软删】—— 一炉不再同时带着估计与实际
--        (软删照旧过冲销分录 借 2200 / 贷 5110)。被覆盖之外的炉上的估计一条都不碰(Q26)。
--   拒:账单日没给 / 在将来;账单号没给;未付却没有供应商(SUPPLIER_REQUIRED_FOR_UNPAID)。
--   返回 {allocation_id, expense_id, expense_code, journal_code, runs, relieved}。
--   ★ MES-5b-2(2026-10-09,MES-5b Step 0 Q28 · Q26 · Q23,Tim):① 过账也要 module.finance.view —— 它不再比自己的预览少问一个码
--     (MES-5a-2 close-out §2 f;线上持 edit 的都持 view,没有人因此失去这一步);② 结算戳只许经财务函数写:写已结的实际行与冲掉估计之前
--     设事务级标记 evoltrya.cost_settlement_ctx,用毕即清(guard_cost_entry_settled);③ "一炉只分一次"改成"一炉最多在一张没撤回的分摊里"
--     (compute 与 guard_electricity_line_one_live_allocation)。一张分摊的撤回:reverse_electricity_allocation。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.

CREATE OR REPLACE FUNCTION public.post_electricity_allocation(p_period_from date, p_period_to date, p_bill_date date, p_invoice_ref text, p_bill_amount numeric, p_bill_kwh numeric, p_currency text, p_payment_status text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v          jsonb;
    v_base     text := base_currency_code();
    v_ref      text := NULLIF(btrim(COALESCE(p_invoice_ref, '')), '');
    v_exp_id   uuid := gen_random_uuid();
    v_alloc_id uuid := gen_random_uuid();
    v_code     text;
    v_je       jsonb;
    v_je_id    uuid;
    v_run      jsonb;
    v_entry    uuid;
    v_ids      uuid[];
    v_n        int := 0;
BEGIN
    PERFORM require_permission('module.finance.edit');
    PERFORM require_permission('module.finance.view');
    IF p_bill_date IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_DATE_REQUIRED';
    END IF;
    IF p_bill_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|expense|%|%', p_bill_date, CURRENT_DATE;
    END IF;
    IF v_ref IS NULL THEN
        RAISE EXCEPTION 'ELECTRICITY_INVOICE_REF_REQUIRED';
    END IF;
    IF p_payment_status = 'unpaid' AND p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_REQUIRED_FOR_UNPAID';
    END IF;
    IF p_supplier_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM suppliers s WHERE s.id = p_supplier_id) THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', p_supplier_id;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('electricity_allocation')::bigint);
    v := electricity_allocation_compute(p_period_from, p_period_to, p_bill_amount, p_bill_kwh, p_currency, p_payment_status, p_bank_account);

    -- ② 费用单编号:与 record_expense / relieve_processing_accruals 同一套(按年咨询锁 + 年内递增)
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || EXTRACT(YEAR FROM p_bill_date)::integer::text)::bigint);
    SELECT document_type_prefix('expense') || '-' || EXTRACT(YEAR FROM p_bill_date)::integer::text || '-' ||
           LPAD((COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1)::text, 4, '0')
      INTO v_code
      FROM expenses
     WHERE code LIKE document_type_prefix('expense') || '-' || EXTRACT(YEAR FROM p_bill_date)::integer::text || '-%';

    -- ③ 那张分录(规则算出来的那几行,原样)
    v_je := post_journal_entry(p_bill_date, 'Electricity bill ' || v_code || ' ' || v_ref,
                               'expense', v_exp_id, v -> 'journal');
    v_je_id := (v_je ->> 'entry_id')::uuid;

    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate, amount_base, payment_status,
                          bank_account_code, supplier_id, payee_name, notes, journal_entry_id, created_by)
    VALUES (v_exp_id, v_code, p_bill_date, fin_cost_account('electricity'), p_bill_amount, v_base, 1, p_bill_amount, p_payment_status,
            CASE WHEN p_payment_status = 'paid' THEN p_bank_account END, p_supplier_id, NULLIF(btrim(COALESCE(p_payee_name, '')), ''),
            'Electricity bill ' || v_ref || ' · ' || p_period_from || ' – ' || p_period_to
              || CASE WHEN NULLIF(btrim(COALESCE(p_notes, '')), '') IS NOT NULL THEN ' · ' || btrim(p_notes) ELSE '' END,
            v_je_id, auth.uid());

    INSERT INTO electricity_allocations (id, period_from, period_to, bill_date, invoice_ref, supplier_id, payee_name, currency,
        bill_amount, bill_kwh, price_per_kwh, metered_kwh, allocated_kwh, shared_pool_kwh, unallocated_metered_kwh, unmetered_kwh,
        allocated_amount, overhead_amount, relieved_estimate_amount, relieved_estimate_count, payment_status, bank_account_code,
        expense_id, journal_entry_id, notes)
    VALUES (v_alloc_id, p_period_from, p_period_to, p_bill_date, v_ref, p_supplier_id, NULLIF(btrim(COALESCE(p_payee_name, '')), ''),
        v ->> 'currency', p_bill_amount, p_bill_kwh, (v ->> 'price_per_kwh')::numeric, (v ->> 'metered_kwh')::numeric,
        (v ->> 'allocated_kwh')::numeric, (v ->> 'shared_pool_kwh')::numeric, (v ->> 'unallocated_metered_kwh')::numeric,
        (v ->> 'unmetered_kwh')::numeric, (v ->> 'allocated_amount')::numeric, (v ->> 'overhead_amount')::numeric,
        (v ->> 'relieved_estimate_amount')::numeric, (v ->> 'relieved_estimate_count')::int, p_payment_status,
        CASE WHEN p_payment_status = 'paid' THEN p_bank_account END, v_exp_id, v_je_id, NULLIF(btrim(COALESCE(p_notes, '')), ''));

    -- ④ 每一炉一条已结的实际电费成本行 + 一行分摊(结算戳只许经财务函数写 —— 标记用毕即清,在 ⑤ 之后)
    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);
    FOR v_run IN SELECT x FROM jsonb_array_elements(v -> 'runs') x LOOP
        INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes, created_by, updated_by,
                                             remitted_at, remitted_journal_entry_id)
        VALUES ((v_run ->> 'run_id')::uuid, 'electricity', (v_run ->> 'amount')::numeric, false,
                'Electricity bill ' || v_ref || ' (' || v_code || ') · ' || (v_run ->> 'kwh') || ' kWh · '
                  || CASE v_run ->> 'basis' WHEN 'recorded_energy' THEN 'split by recorded run energy' ELSE 'split by run time' END,
                auth.uid(), auth.uid(), p_bill_date, v_je_id)
        RETURNING id INTO v_entry;
        INSERT INTO electricity_allocation_lines (allocation_id, run_id, equipment_id, basis, run_energy_kwh, run_minutes, weight, share,
                                                  machine_kwh, kwh, amount, cost_entry_id)
        VALUES (v_alloc_id, (v_run ->> 'run_id')::uuid, (v_run ->> 'equipment_id')::uuid, v_run ->> 'basis',
                (v_run ->> 'own_kwh')::numeric, (v_run ->> 'minutes')::numeric, (v_run ->> 'weight')::numeric,
                (v_run ->> 'share')::numeric, (v_run ->> 'machine_kwh')::numeric, (v_run ->> 'kwh')::numeric,
                (v_run ->> 'amount')::numeric, v_entry);
        v_n := v_n + 1;
    END LOOP;

    -- ⑤ 冲掉被覆盖的炉上那几条估计(锁住它们,确认它们仍然没结过 —— 与预览之间被别人结掉的,拒而不是悄悄少冲)
    SELECT array_agg((x ->> 'id')::uuid) INTO v_ids FROM jsonb_array_elements(v -> 'estimates') x;
    IF v_ids IS NOT NULL THEN
        PERFORM 1 FROM processing_cost_entries e WHERE e.id = ANY (v_ids) FOR UPDATE;
        IF EXISTS (SELECT 1 FROM processing_cost_entries e WHERE e.id = ANY (v_ids)
                     AND (e.deleted_at IS NOT NULL OR e.remitted_at IS NOT NULL OR e.relieved_at IS NOT NULL)) THEN
            RAISE EXCEPTION 'COST_ENTRY_ALREADY_SETTLED|electricity';
        END IF;
        UPDATE processing_cost_entries
           SET relieved_at = p_bill_date, relief_expense_id = v_exp_id, deleted_at = now(), updated_by = auth.uid()
         WHERE id = ANY (v_ids);
    END IF;
    PERFORM set_config('evoltrya.cost_settlement_ctx', '', true);

    RETURN jsonb_build_object('allocation_id', v_alloc_id, 'expense_id', v_exp_id, 'expense_code', v_code,
                              'journal_code', v_je ->> 'code', 'runs', v_n, 'relieved', COALESCE(array_length(v_ids, 1), 0));
END;
$function$;

-- db/functions/relieve_processing_accruals.sql
-- 真实发票冲抵【估算】应计(FIN-6 C)。一张水电/燃气账单盖住整月多个 run 的
-- 估算行 —— 【多对一,不要求一一对应】(C3)。分录:
--   借 2200 被清的应计合计;差额(实际 − 估算)借/贷该成本类型的 5xxx 行 ——
--   估算与实际的差落进【发票所在期间】的损益(既定);
--   贷 银行(已付)或 贷 2000 应付(挂账,须给供应商 —— 之后走正常收付款核销)。
-- 【差异不回摊到批次】(既定,写在迁移头):化验改的是批次自己的料价,回摊天经地义;
-- 水电是横跨多个 run 的公摊,它的差异不属于任何单一批次。本函数【一个字都不碰】
-- 批次成本、存货计价、COGS —— fixture 逐项断言。
-- 【结构性防重复】发票只从这里进账;record_expense 早已拒收 5xxx(ACCOUNT_NOT_EXPENSE,
-- 5xxx 是 cogs 型),被清过的应计行不能再清(COST_ENTRY_ALREADY_SETTLED)。
-- 一次冲抵限一个 cost_type(账单本来就是按类型来的;差异报表按类型分组)。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin6-relieve-processing-accruals.sql.
--
-- MES-5b-2(2026-10-09,MES-5a Step 0 Q35 · MES-5b Step 0 Q21 · Q26,Tim):① 费用单的币种不再写死成 SGD 字面量(汇率 1)—— 读 base_currency_code()
--   (currencies.is_base;本位币对自己的汇率是 1)。关掉 MES5A2-RELIEVE-SGD-LITERAL。② 盖冲抵戳之前设事务级标记
--   evoltrya.cost_settlement_ctx(结算戳只许经财务函数改 —— guard_cost_entry_settled),用毕即清。③ 冲销这张费用单(reverse_expense)
--   会把它冲抵掉的估计放回"未结",于是它们能再被冲抵一次(F2)。

CREATE OR REPLACE FUNCTION public.relieve_processing_accruals(p_entry_ids uuid[], p_actual_amount numeric, p_expense_date date, p_payment_status text DEFAULT 'paid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_accrued numeric := 0;
    v_type    text;
    v_n int := 0;
    v_e record;
    v_var numeric;
    v_bank text;
    v_lines jsonb;
    v_je jsonb;
    v_expense_id uuid := gen_random_uuid();
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_entry_ids IS NULL OR array_length(p_entry_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;
    IF p_actual_amount IS NULL OR p_actual_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'PAYMENT_STATUS_INVALID|%', COALESCE(p_payment_status, '?');
    END IF;
    IF p_payment_status = 'unpaid' AND p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_REQUIRED_FOR_UNPAID';
    END IF;
    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):这里直接写一张费用单(不经 record_expense),记的同样是【已经发生】的一张发票(Tim Batch B Q6),日期晚于今天按名拒。
    IF p_expense_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|expense|%|%', p_expense_date, CURRENT_DATE;
    END IF;

    FOR v_e IN SELECT * FROM processing_cost_entries WHERE id = ANY (p_entry_ids) FOR UPDATE
    LOOP
        IF v_e.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'COST_ENTRY_INVALID|%', v_e.id; END IF;
        IF NOT v_e.is_estimate THEN RAISE EXCEPTION 'COST_ENTRY_NOT_ESTIMATE|%', v_e.cost_type; END IF;
        IF v_e.remitted_at IS NOT NULL OR v_e.relieved_at IS NOT NULL THEN
            RAISE EXCEPTION 'COST_ENTRY_ALREADY_SETTLED|%', v_e.cost_type;
        END IF;
        IF v_type IS NULL THEN v_type := v_e.cost_type;
        ELSIF v_type <> v_e.cost_type THEN
            RAISE EXCEPTION 'RELIEF_MIXED_COST_TYPES|%|%', v_type, v_e.cost_type;
        END IF;
        v_accrued := round(v_accrued + v_e.amount_base, 2);
        v_n := v_n + 1;
    END LOOP;
    IF v_n = 0 OR v_accrued <= 0 THEN RAISE EXCEPTION 'NO_LINES'; END IF;

    IF p_payment_status = 'paid' THEN
        v_bank := COALESCE(p_bank_account, '1000');
        IF v_bank NOT IN ('1000','1010') THEN RAISE EXCEPTION 'BANK_INVALID|%', v_bank; END IF;
    END IF;

    -- 借 2200 清应计;差额进当期 5xxx;贷 银行/应付 记实际
    v_var := round(p_actual_amount - v_accrued, 2);
    v_lines := jsonb_build_array(jsonb_build_object(
        'account_code', '2200', 'side', 'debit', 'currency', base_currency_code(),
        'amount_ccy', v_accrued, 'line_memo', 'clear accrued ' || v_type));
    IF v_var > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', fin_cost_account(v_type),
            'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', v_var,
            'line_memo', 'estimate-to-actual variance');
    ELSIF v_var < 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', fin_cost_account(v_type),
            'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', -v_var,
            'line_memo', 'estimate-to-actual variance');
    END IF;
    v_lines := v_lines || jsonb_build_object(
        'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
        'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', p_actual_amount);

    -- 单据号:与 record_expense 同一套(advisory lock + 年内递增)
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || EXTRACT(YEAR FROM p_expense_date)::integer::text)::bigint);
    SELECT document_type_prefix('expense') || '-' || EXTRACT(YEAR FROM p_expense_date)::integer::text || '-' ||
           LPAD((COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1)::text, 4, '0')
    INTO v_code
    FROM expenses
    WHERE code LIKE document_type_prefix('expense') || '-' || EXTRACT(YEAR FROM p_expense_date)::integer::text || '-%';
    v_je := post_journal_entry(p_expense_date, 'Expense ' || v_code || ' ' || fin_cost_account(v_type),
                               'expense', v_expense_id, v_lines);

    -- 发票立成正常开支单据:挂账的走既有收付款核销;科目 = 该成本类型的 5xxx
    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_expense_id, v_code, p_expense_date, fin_cost_account(v_type), p_actual_amount, base_currency_code(), 1,
            p_actual_amount, p_payment_status, v_bank, p_supplier_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, auth.uid());

    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);
    UPDATE processing_cost_entries
    SET relieved_at = p_expense_date, relief_expense_id = v_expense_id
    WHERE id = ANY (p_entry_ids);
    PERFORM set_config('evoltrya.cost_settlement_ctx', '', true);

    RETURN jsonb_build_object('expense_id', v_expense_id, 'expense_code', v_code,
        'journal_code', v_je->>'code', 'cost_type', v_type,
        'accrued_cleared', v_accrued, 'actual', p_actual_amount, 'variance', v_var, 'entries', v_n);
END;
$function$;

-- db/functions/remit_processing_costs.sql
-- 汇付【实际额】(is_estimate = false)的加工成本(FIN-6 B)。FIN-5 的形状:
-- 一次汇款 = 对账单一行 = 分录一条银行行;借 2200 合计。照着对账单记。
-- 估算行不走这里(COST_ENTRY_IS_ESTIMATE)—— 估算由真实发票冲抵(relieve_processing_accruals)。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin6-relieve-processing-accruals.sql.
--
-- FIN-10(2026-08-05):日期不再有 CURRENT_DATE 默认值 —— 缺了就抛具名错误。
-- 默认成今天永远撞不上 PERIOD_LOCKED,于是留空反而比填对更容易过关,
-- 这条路径专门奖励留空。要求由函数自己声明,而不是靠调用方自觉。
-- 详见 db/migrations/2026-08-05-fin10-no-default-posting-dates.sql。
--
-- MES-5b-2(2026-10-09,MES-5b Step 0 Q26):盖汇出戳之前设事务级标记 evoltrya.cost_settlement_ctx(结算戳只许经财务函数改 ——
--   guard_cost_entry_settled),用毕即清。其余一个字不动。

CREATE OR REPLACE FUNCTION public.remit_processing_costs(p_entry_ids uuid[], p_payment_date date DEFAULT NULL::date, p_bank_account text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_total numeric := 0;
    v_n int := 0;
    v_e record;
    v_bank text;
    v_date date;
    v_je jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    IF p_entry_ids IS NULL OR array_length(p_entry_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN RAISE EXCEPTION 'BANK_INVALID|%', v_bank; END IF;
    v_date := p_payment_date;

    FOR v_e IN SELECT * FROM processing_cost_entries WHERE id = ANY (p_entry_ids) FOR UPDATE
    LOOP
        IF v_e.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'COST_ENTRY_INVALID|%', v_e.id; END IF;
        IF v_e.is_estimate THEN RAISE EXCEPTION 'COST_ENTRY_IS_ESTIMATE|%', v_e.cost_type; END IF;
        IF v_e.remitted_at IS NOT NULL OR v_e.relieved_at IS NOT NULL THEN
            RAISE EXCEPTION 'COST_ENTRY_ALREADY_SETTLED|%', v_e.cost_type;
        END IF;
        v_total := round(v_total + v_e.amount_base, 2);
        v_n := v_n + 1;
    END LOOP;
    IF v_n = 0 OR v_total <= 0 THEN RAISE EXCEPTION 'NO_LINES'; END IF;

    v_je := post_journal_entry(v_date, 'Processing cost remittance', 'processing_cost', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code', '2200', 'side', 'debit', 'currency', base_currency_code(),
                               'amount_ccy', v_total),
            jsonb_build_object('account_code', v_bank, 'side', 'credit', 'currency', base_currency_code(),
                               'amount_ccy', v_total)));

    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);
    UPDATE processing_cost_entries
    SET remitted_at = v_date, remitted_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = ANY (p_entry_ids);
    PERFORM set_config('evoltrya.cost_settlement_ctx', '', true);

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'entries', v_n, 'total', v_total);
END;
$function$;

-- db/functions/trail_subjects.sql
-- AUDIT-TRAIL-1a(Tim 的 Q5):审计记录的【主语登记表】。页面只说"哪一种记录、哪一条",从不说表名;
--   表名、根键、以及【这一页自己的查看权限码】只住在这里(服务端)。不在这里的主语 → TRAIL_SUBJECT_UNKNOWN。
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M1 · M3 · M6)多了三列:
--   view_codes   【任一】即可进(M1)—— 与页面守卫同一组码。一页只认一个码时就是一个元素的数组。
--                warehouse_request:/inventory 那一块(module.inventory.view)与财务(module.finance.view)都读它。
--   root_rule    (AUDIT-TRAIL-1d-1 多了两种:'collection' —— M11,一张表整张是一条记录;'gate:<名字>' —— M12,比表的规则更窄)
--                'table'(默认):根行还要过它自己那张表的读规则,过不了 → TRAIL_NOT_PERMITTED。
--                'page'(M3):页面的码就是门;根行自己的那几次改动照子行的规矩走 —— 读者过不了根表的读规则,
--                那几条就是 Restricted(Q4)。equipment 用它:根表 fixed_assets 只给财务读,而这一页给加工的人。
--   root_columns 非空(M6):根行只取这几列的改动(一块面板只管它自己编辑的那几个字段,Q25 的同一条规矩)。
--                NULL = 整行。1b-3 的三个阈值面板会用到它;本刀先建好,fixture 237 用一个临时主语证它。
-- view_codes 与页面守卫逐字同一组码:
--   purchase_order → /purchasing/orders/[id]        requireModule(MOD.purchasing) = module.purchasing.view
--   processing_run → /operation/processing/[id]     requireModule(MOD.processing) = module.processing.view
--   operation_type → /operation/operation-types/[code] requireModule(MOD.processing) = module.processing.view(MES-4a)
--   role           → /settings/roles/[id]           requireManagePermissions()     = action.manage_permissions
--   inbound_batch  → /inbound/[id]/edit             requireModule(MOD.inbound)     = module.inbound.view
--   output_batch   → /output/[id]/edit              requireModule(MOD.output)      = module.output.view
--   work_order     → /operation/orders/[id]         requireModule(MOD.processing)  = module.processing.view
--   stocktake      → /stocktakes/[id]               requireModule(MOD.stocktakes)  = module.stocktakes.view
--   equipment      → /operation/equipment/[id]      requireModule(MOD.processing)  = module.processing.view
--   shift_handover → /operation/handovers/[id]      requireModule(MOD.processing)  = module.processing.view
--   warehouse_request → /inventory 的申请一块        requireModule(MOD.inventory)   = module.inventory.view(+ 财务)
-- AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a 的商务那一半):
--   quote          → /sales/quotes/[id]              requireModule(MOD.sales)       = module.sales.view
--   sales_order    → /sales/orders/[id]              requireModule(MOD.sales)       = module.sales.view
--   shipment       → /sales/shipments/[id]           action.ship_goods,否则 requireModule(MOD.sales)(M1:任一)
--   customer       → /sales/customers/[id]           requireModule(MOD.customers)   = module.customers.view
--   commission_agreement → /sales/commissions/[id]/edit(只有这一页,Q2)requireModule(MOD.suppliers) = module.suppliers.view
--   supplier       → /suppliers/[id]/edit(只有这一页,Q2)requireModule(MOD.suppliers) = module.suppliers.view
--   container      → /logistics/containers/[id]      requireModule(MOD.logistics)   = module.logistics.view
--   forwarder      → /logistics/forwarders/[id]      requireModule(MOD.logistics)   = module.logistics.view
--                    根表是 suppliers(读规则 module.suppliers.view)—— M3:页面的码是门,根行自己的改动逐行判
--   lane · port    → /logistics/lanes(只有清单页,按条合起来,见 app/components/trail/ListTrail.tsx)module.logistics.view
--   company_licence → /purchasing/licences(只有清单页)门是 module.purchasing.view,而这张表的读规则是
--                    module.suppliers.view —— 这一块只画在持 suppliers.view 的那一支里(页面本来就那样分),所以登记后者
-- AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a 的主数据与工具):
--   material       → /materials/[id]/edit(只有这一页,Q2)requireModule(MOD.materials) = module.materials.view
--   storage_location → /inventory/locations/[id]/edit(只有这一页)requireModule(MOD.inventory) = module.inventory.view
--   metal_price    → /tools/pricing/metal-prices/[id]/edit(只有这一页)requireEditPermission('action.metal_prices')
--   pricing_formula → /tools/pricing/formulas/[id]/edit(只有这一页)requireModule(MOD.pricing) = module.pricing.view
--   task           → /tools/tasks/[id]                requireModule(MOD.tasks)       = module.tasks.view
--                    私人任务也读得到(Q3):根行要过 tasks 自己的读规则(团队任务 · 自己的 · 或持 module.tasks.view_all)——
--                    那正是"谁打得开这一页"的同一个判据,而遮蔽那一步本来就先问任务隐私
--   processing_settings → /operation/orders 的工单阈值面板          module.processing.view;M6:只取面板编辑的两列
--   pricing_settings    → /tools/pricing/metal-prices 的异常阈值面板  module.pricing.view;M6:只取那一列
--   receiving_settings  → /purchasing/discrepancies 的收货阈值面板   module.inbound.view(面板只画在这一支里);M6:三列
--                    三张都是单行表,主键 id boolean —— M5:页面传 'true',读法按根行自己的类型重建那个键
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第一刀:账上的单据):
--   journal_entry   → /finance/journal/[id]             requireModule(MOD.finance)     = module.finance.view
--   invoice         → /finance/invoices/[id]            requireModule(MOD.finance)     = module.finance.view
--   credit_note     → /finance/credit-notes/[id]        requireModule(MOD.finance)     = module.finance.view
--   payment         → /finance/payments/[id]            requireModule(MOD.finance)     = module.finance.view
--   payment_request → /finance/payment-requests/[id]    requireModule(MOD.finance)     = module.finance.view
--                    (行内转账、代扣税缴纳与它们的冲销也住在这一页 —— 它们没有自己的页,Q17)
--   expense         → /finance/expenses/[id]            requireModule(MOD.finance)     = module.finance.view
--   payable         → /finance/payables/[batchId]       requireModule(MOD.finance)     = module.finance.view
--                    根表是 inbound_batches(读规则 module.inbound.view)—— M3:页面的码是门(Q5,forwarder 的先例);
--                    M6:只取应付那几列(数量、单价、供应商、采购单、计价状态、到货日、注销三列)—— 批次的仓库那一面
--                    (化验、安全状态、库位……)住在 /inbound/[id]/edit 的 inbound_batch 上,不在应付页上再说一遍。
--                    注销那三列必须在里面:M6 丢掉 root_columns 之外的戳(record_trail),不在里面注销就看不见(Q5 的横幅)。
-- AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第二刀:其余的单据与合同):
--   sale            → /finance/receivables/[saleId]     requireModule(MOD.finance)     = module.finance.view
--   freight         → /finance/freight/[id]             requireModule(MOD.finance)     = module.finance.view
--                    (根表的读规则是 inbound.view OR finance.view,再加一条 finance.edit 的 ALL —— 页面的码过得了,不需要 M3)
--   fixed_asset     → /finance/assets/[id]              requireModule(MOD.finance)     = module.finance.view
--                    根表与 equipment 同一张 fixed_assets(supplier / forwarder 的先例:一张表两个主语,Q10)——
--                    equipment 的门是加工,这一页的门是财务;根表的读规则就是 finance.view,所以是 'table'
--   bank_statement  → /finance/bank/statements/[id]     requireModule(MOD.finance)     = module.finance.view
--                    删掉的对账单也读得到(Q6:持 data.view_deleted 的人只读打开;根表的读规则不过滤已删的行)
--   gst_period      → /finance/gst/[periodId]           requireModule(MOD.finance)     = module.finance.view
--   fx_rate         → /finance/fx/[id]/edit(只有这一页,Q2)requireModule(MOD.finance) = module.finance.view
--                    撤回了的汇率也读得到(Q7:页面对本来的读者只读打开)
--   management_pack → /finance/packs/[id]               requireModule(MOD.finance)     = module.finance.view
--   contract        → /contracts/[id]                   requireModule(MOD.suppliers)   = module.suppliers.view
--                    根表的读规则按方向:卖方合同要 customers.view、买方合同要 suppliers.view —— 页面在 RLS 下读、读不到就 404,
--                    所以 'table' 与页面同一个答案(看不见的合同对他而言不存在)
-- AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第三刀:期末、设置与清单页上的记录):
--   finance_lock    → /finance/settings 锁期面板之下 · /finance/close 关账史之下(Q25 · Q29)  module.finance.view
--                    根表 finance_settings(单行,id boolean —— M5,页面传 'true');M6:只取 locked_before 一列;
--                    月结 / 反结(period_closes)经 M7 整张表属于这一行(两张表之间一个键都没有,Q3)
--   finance_gst     → /finance/settings GST 面板之下                                       module.finance.view
--                    同一行(M5);M6:只取 gst_registered、gst_registration_no 两列 —— 两块面板各看各的(Q25);
--                    这一行上没有面板的六列(gst_rate_pct · system_start_date · 三个财年列 · default_allocation_basis)
--                    哪一块都不取,只在 /settings/change-history 上找得到(Q4);审批方针那四列归 AT-1d(Q2)
--   company_profile → /finance/company                                                     requireModule(MOD.finance)
--                    单行(M5),整行 —— 一块面板编辑整行;银行那五列按 HISTORY-1 的规则对不持 data.view_banking 的人遮
--   year_close      → /finance/close 年结那一块(清单块,ListTrail)                          module.finance.view
--   journal_request → /finance/journal 每一张申请卡片里(Q17,一张一块)                     module.finance.view
--   expense_claim   → /finance/claims 每一张报销单一块(Q20)                                module.finance.view
--   my_expense_claim → /me 报销人自己那几张(Q20 的另一半)—— ★ M8:没有页面码(view_codes 为空数组),
--                    根行自己那张表的读规则就是门(expense_claims:module.finance.view 或者【这张单说的就是你】);
--                    只许与 'table' 同用(record_trail 里拒绝 'page' —— 那会对每一个人敞开)。
--                    审批留痕那一支(approval_log 的 expense_claim)不给本人开口子,所以本人看到的是 Restricted(Q4)
--   bank_transfer   → /finance/bank 转账那一块(清单块)                                     module.finance.view
--   wht_remittance  → /finance/wht 缴纳那一块(清单块)                                      module.finance.view
--   cash_forecast · cash_forecast_line → /finance/cash-forecast(清单块,Q16:冻结 + 作废旧的一张是一次操作)
--   bank_import_profile → /finance/bank/import(清单块,删掉的也读)                         module.finance.view
--   (重估 / 折旧 / 工资付款 / 加工成本结算的批次与批量汇率【不】另立主语:它们各自的清单块读 journal_entry · expense ·
--    fx_rate 那几个现成主语,Q16 的 op_key 把一次操作并成一条 —— Q18 · Q19)
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第一刀:机制、设置与员工):
--   account         → /settings/accounts 每一行一块(Q24)        requireManagePermissions()     = action.manage_permissions
--                    ★ M9:根表 auth.users 不在 public 里 —— trail_log_only_tables() 给它一份安全投影与声明的读码;
--                    事件(建立 / 停用 / 恢复 / 失败 / 回滚)住在 change_log(record_account_event)
--   approval_policy → /settings/approvals(Q25,1c 的 Q2 挪过来)requireFunction(FN.approvals) = action.manage_permissions
--                    同一行 finance_settings(M5);M6:只取它编辑的四列;修改史 finance_settings_history 经 M7 整张属于这一行。
--                    根表的读规则是 module.finance.view —— 'table':读者两个码都要(线上唯一持 manage_permissions 的 admin 两个都有,Q23)
--   employee        → /hr/employees/[id]                        requireModule(MOD.hr)          = module.hr.view
--                    根表的读规则是 hr.view 或【这就是你】—— 与页面同一个答案
--   department      → /hr/departments/[id]/edit(只有这一页)   requireModule(MOD.hr)          = module.hr.view
--   training_record → /hr/training/[id]/edit(只有这一页,Q29) requireModule(MOD.hr)          = module.hr.view
--   import_batch    → /settings/import 的批次一块(清单块,Q24) can('action.bulk_import')      = action.bulk_import
--   dictionary_*    → /settings/dictionaries 每一段一块(Q4)    每一段自己的查看码(registry.ts 的 viewPermission)
--                    ★ M11:'collection' —— 没有根行,那张字典表的每一行、change_log 里它的每一行都属于这一块;根键照写那张表的主键
--                    (code),record_trail 不用它。
--   ☞ M12('gate:reviewer')本刀没有主语用它(它的第一个用户是 AT-1d-3 的 /my-reviews —— 1d-3 已接上,见下面 my_review);fixture 244 用一个临时主语证它。
-- AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第二刀:请假与考勤):
--   leave_request     → /hr/leave/[id]                  requireModule(MOD.hr)          = module.hr.view
--                    根表的读规则是 hr.view 或【这张单说的就是你】—— 与页面同一个答案
--   my_leave_request  → /me 本人那几张(Q14,M8:没有页面码 —— 根行自己的读规则就是门;审批与消耗那几行对本人是 Restricted)
--   leave_grant       → /hr/leave/grants 那一块(清单块,按年)         module.hr.view
--   leave_types       → /hr/leave/types(M11 集合,根键 code)         module.hr.view
--   public_holidays   → /hr/leave/holidays(M11 集合 —— 假期是【硬删】的,一行删掉之后只剩变更记录里那一份影像)
--   medical_claim     → /hr/claims/[id]                 requireModule(MOD.hr)          = module.hr.view
--   my_medical_claim  → /me 本人那几张(Q14,M8)
--   overtime_batch    → /hr/overtime/[id]               requireFunction(FN.overtime)   = M1:hr.view · overtime_enter · overtime_approve
--                    (与页面守卫、与 overtime_batches 的读规则逐字同一组码)
--   attendance_period → /hr/attendance/[id]             requireModule(MOD.hr)          = module.hr.view
-- AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第三刀:工资与评审):
--   payroll_period      → /hr/payroll/[id]              requireModule(MOD.hr)          = module.hr.view
--                      根表的读规则是 hr.view —— 与页面同一个答案;工资行的金额对不持 data.view_pay 的人照遮蔽规则说 Restricted
--   performance_review  → /hr/reviews/[id]              requireModule(MOD.hr)          = module.hr.view
--                      根表的读规则是 (hr.view 且 view_reviews) 或审核人 或【这是你的、已批】—— 页面读 performance_reviews_masked,
--                      同一个谓词,读不到就 notFound;所以 auditor / finance(hr.view,不持 view_reviews)两边都进不去
--   my_review           → /my-reviews/[id](审核人那一页,没有模块守卫)  M8 + M12:没有页面码,root_rule 'gate:reviewer' ——
--                      根行先过表的读规则,【再】过 trail_root_gate('reviewer'):只给这一份评审点名的审核人,
--                      不给被评审的本人(他在批准之后经"own approved"那一条读得到行,但这一段不是给他的,Q5)
--   review_cycle        → /hr/reviews/cycles 那一块(清单块,每一轮一条)   module.hr.view(Q6:没有成员 —— 开轮时铺下的那几份评审
--                      不挂进来,轮次那一块只说"开了 / 关了";每一份评审自己的那一段以"Annual review opened (cycle …)"开头)
--   review_rating_scale → /hr/reviews/scale(M11 集合,根键 code)      module.hr.view
--   kpi_entry           → /hr/kpi/score 那一块(清单块,选中那一个月的条目;只在 canSeeScores 那一支里画)  module.hr.view
--                      根表的读规则是 (hr.view 且 view_reviews) 或本人 —— 不持 view_reviews 的读者在页面那一支就进不来
-- 【后面几刀加主语】加一行这里、在 trail_subject_members 里登记它的子行与相关行、需要的话在
--   trail_prelog_sources 里登记"记录开始之前"的来源,然后在 lib/trail/ 里补它的措辞 —— 见 docs/change-log.md §9。
-- MES-1(2026-10-06,MES-1 Step 0 Q21 · Q22,Tim):
--   device          → /operation/devices/[id]           requireModule(MOD.processing) = module.processing.view
--                     成员 gateway_keys(钥匙的发放与撤销;哈希被 never 规则遮住)。收件箱、传输日志与中断不进变更记录(MES-0 Q14),
--                     所以不在这里 —— 设备页把中断单独列成一块(Q21)。
--   ingest_settings → /operation/devices 上的传输上限面板  module.processing.view;单行设置作根(M5),修改史就是变更记录(Q22)
-- MES-5a-2(2026-10-08,MES-5a Step 0 Q31,Tim):
--   electricity_allocation → /finance/electricity/[id]   requireModule(MOD.finance) = module.finance.view
--                     成员 electricity_allocation_lines(一炉一行;它在加工单上也出现,但家在这里)。金额由 change_log_mask_rules 遮(data.view_prices)。
--                     MES-5b-2:成员加 electricity_allocation_reversals(一张单最多一行;它在它覆盖过的每一炉上也出现,家在这里)。
--                     (MES-5b-2 也把 operation_type_output_forms 挂到 operation_type 下 —— V37 的改动从此在工序页自己的审计记录上。)
--   electricity_settings   → /finance/electricity 上的 V25 那一块  module.finance.view;单行设置作根(M5)
CREATE OR REPLACE FUNCTION public.trail_subjects()
 RETURNS TABLE(subject text, view_codes text[], root_table text, root_key text, root_rule text, root_columns text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('purchase_order',    ARRAY['module.purchasing.view'],    'purchase_orders',    'id', 'table', NULL::text[]),
        ('processing_run',    ARRAY['module.processing.view'],    'processing_runs',    'id', 'table', NULL),
        ('role',              ARRAY['action.manage_permissions'], 'roles',              'id', 'table', NULL),
        ('inbound_batch',     ARRAY['module.inbound.view'],       'inbound_batches',    'id', 'table', NULL),
        ('output_batch',      ARRAY['module.output.view'],        'output_batches',     'id', 'table', NULL),
        ('work_order',        ARRAY['module.processing.view'],    'work_orders',        'id', 'table', NULL),
        ('stocktake',         ARRAY['module.stocktakes.view'],    'stocktakes',         'id', 'table', NULL),
        ('equipment',         ARRAY['module.processing.view'],    'fixed_assets',       'id', 'page',  NULL),
        ('shift_handover',    ARRAY['module.processing.view'],    'shift_handovers',    'id', 'table', NULL),
        ('warehouse_request', ARRAY['module.inventory.view', 'module.finance.view'], 'warehouse_requests', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-2
        ('quote',             ARRAY['module.sales.view'],         'quotes',             'id', 'table', NULL),
        ('sales_order',       ARRAY['module.sales.view'],         'sales_orders',       'id', 'table', NULL),
        ('shipment',          ARRAY['module.sales.view', 'action.ship_goods'], 'shipments', 'id', 'table', NULL),
        ('customer',          ARRAY['module.customers.view'],     'customers',          'id', 'table', NULL),
        ('commission_agreement', ARRAY['module.suppliers.view'],  'commission_agreements', 'id', 'table', NULL),
        ('supplier',          ARRAY['module.suppliers.view'],     'suppliers',          'id', 'table', NULL),
        ('container',         ARRAY['module.logistics.view'],     'containers',         'id', 'table', NULL),
        ('forwarder',         ARRAY['module.logistics.view'],     'suppliers',          'id', 'page',  NULL),
        ('lane',              ARRAY['module.logistics.view'],     'lanes',              'id', 'table', NULL),
        ('port',              ARRAY['module.logistics.view'],     'ports',              'id', 'table', NULL),
        ('company_licence',   ARRAY['module.suppliers.view'],     'company_compliance', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-3
        ('material',          ARRAY['module.materials.view'],     'materials',          'id', 'table', NULL),
        ('storage_location',  ARRAY['module.inventory.view'],     'storage_locations',  'id', 'table', NULL),
        ('metal_price',       ARRAY['action.metal_prices'],       'metal_prices',       'id', 'table', NULL),
        ('pricing_formula',   ARRAY['module.pricing.view'],       'pricing_formulas',   'id', 'table', NULL),
        ('task',              ARRAY['module.tasks.view'],         'tasks',              'id', 'table', NULL),
        ('processing_settings', ARRAY['module.processing.view'],  'processing_settings', 'id', 'table',
            ARRAY['wo_input_overrun_pct', 'wo_output_shortfall_pct']),
        ('pricing_settings',  ARRAY['module.pricing.view'],       'pricing_settings',   'id', 'table',
            ARRAY['metal_price_change_warn_pct']),
        ('receiving_settings', ARRAY['module.inbound.view'],      'receiving_settings', 'id', 'table',
            ARRAY['grn_short_pct', 'grn_over_pct', 'grn_assay_tolerance_pct']),
        -- AUDIT-TRAIL-1c-1
        ('journal_entry',     ARRAY['module.finance.view'],       'journal_entries',    'id', 'table', NULL),
        ('invoice',           ARRAY['module.finance.view'],       'invoices',           'id', 'table', NULL),
        ('credit_note',       ARRAY['module.finance.view'],       'credit_notes',       'id', 'table', NULL),
        ('payment',           ARRAY['module.finance.view'],       'payments',           'id', 'table', NULL),
        ('payment_request',   ARRAY['module.finance.view'],       'payment_requests',   'id', 'table', NULL),
        ('expense',           ARRAY['module.finance.view'],       'expenses',           'id', 'table', NULL),
        ('payable',           ARRAY['module.finance.view'],       'inbound_batches',    'id', 'page',
            ARRAY['supplier_id', 'purchase_order_id', 'quantity', 'unit', 'unit_price', 'pricing_status', 'arrival_date',
                  'deleted_at', 'deleted_by', 'delete_reason']),
        -- AUDIT-TRAIL-1c-2
        ('sale',              ARRAY['module.finance.view'],       'sales_records',      'id', 'table', NULL),
        ('freight',           ARRAY['module.finance.view'],       'freight_documents',  'id', 'table', NULL),
        ('fixed_asset',       ARRAY['module.finance.view'],       'fixed_assets',       'id', 'table', NULL),
        ('bank_statement',    ARRAY['module.finance.view'],       'bank_statements',    'id', 'table', NULL),
        ('gst_period',        ARRAY['module.finance.view'],       'gst_periods',        'id', 'table', NULL),
        ('fx_rate',           ARRAY['module.finance.view'],       'fx_rates',           'id', 'table', NULL),
        ('management_pack',   ARRAY['module.finance.view'],       'management_packs',   'id', 'table', NULL),
        ('contract',          ARRAY['module.suppliers.view'],     'contracts',          'id', 'table', NULL),
        -- AUDIT-TRAIL-1c-3
        ('finance_lock',      ARRAY['module.finance.view'],       'finance_settings',   'id', 'table', ARRAY['locked_before']),
        ('finance_gst',       ARRAY['module.finance.view'],       'finance_settings',   'id', 'table',
            ARRAY['gst_registered', 'gst_registration_no']),
        ('company_profile',   ARRAY['module.finance.view'],       'company_profile',    'id', 'table', NULL),
        ('year_close',        ARRAY['module.finance.view'],       'year_closes',        'id', 'table', NULL),
        ('journal_request',   ARRAY['module.finance.view'],       'journal_requests',   'id', 'table', NULL),
        ('expense_claim',     ARRAY['module.finance.view'],       'expense_claims',     'id', 'table', NULL),
        ('my_expense_claim',  ARRAY[]::text[],                    'expense_claims',     'id', 'table', NULL),
        ('bank_transfer',     ARRAY['module.finance.view'],       'bank_transfers',     'id', 'table', NULL),
        ('wht_remittance',    ARRAY['module.finance.view'],       'wht_remittances',    'id', 'table', NULL),
        ('cash_forecast',     ARRAY['module.finance.view'],       'cash_forecasts',     'id', 'table', NULL),
        ('cash_forecast_line', ARRAY['module.finance.view'],      'cash_forecast_lines', 'id', 'table', NULL),
        ('bank_import_profile', ARRAY['module.finance.view'],     'bank_import_profiles', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1d-1
        ('account',           ARRAY['action.manage_permissions'], 'auth.users',         'id', 'table', NULL),
        ('approval_policy',   ARRAY['action.manage_permissions'], 'finance_settings',   'id', 'table',
            ARRAY['approvals_enabled', 'approval_threshold_base', 'approval_level1_role_code', 'approval_level2_role_code']),
        ('employee',          ARRAY['module.hr.view'],            'employees',          'id', 'table', NULL),
        ('department',        ARRAY['module.hr.view'],            'departments',        'id', 'table', NULL),
        ('training_record',   ARRAY['module.hr.view'],            'training_records',   'id', 'table', NULL),
        ('import_batch',      ARRAY['action.bulk_import'],        'import_batches',     'id', 'table', NULL),
        ('dictionary_substances',          ARRAY['module.materials.view'], 'substances',             'code', 'collection', NULL),
        ('dictionary_battery_chemistries', ARRAY['module.materials.view'], 'battery_chemistries',    'code', 'collection', NULL),
        ('dictionary_material_kinds',      ARRAY['module.materials.view'], 'material_kinds',         'code', 'collection', NULL),
        ('dictionary_inbound_safety_states', ARRAY['module.materials.view'], 'inbound_safety_states', 'code', 'collection', NULL),
        ('dictionary_laboratories',        ARRAY['module.inbound.view'],   'laboratories',           'code', 'collection', NULL),
        ('dictionary_inbound_source_reasons', ARRAY['module.inbound.view'], 'inbound_source_reasons', 'code', 'collection', NULL),
        -- MES-3a(2026-10-06,MES-3a Step 0 Q4 · Q12):NEA 废物类别字典 —— 与其余六本同一个形状(清单块,/settings/dictionaries)
        ('dictionary_nea_waste_categories', ARRAY['module.materials.view'], 'nea_waste_categories', 'code', 'collection', NULL),
        -- MES-3b(2026-10-07):危险品 UN 编号字典(module.materials.view)· 标签模板字典(module.inventory.view)
        ('dictionary_dangerous_goods_codes', ARRAY['module.materials.view'], 'dangerous_goods_codes', 'code', 'collection', NULL),
        ('dictionary_label_templates',      ARRAY['module.inventory.view'], 'label_templates',       'code', 'collection', NULL),
        -- MES-4a(2026-10-07,MES-4a Step 0 Q33):一道工序 —— 它的参数与指标、挂着的机器、配方与每一版、容差(根行自己那几列);
        --   页面 /operation/operation-types/[code],门 module.processing.view;根键 code(成员按 operation_type_code 挂在它下面)。
        --   异常事件种类字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries)。
        ('operation_type',    ARRAY['module.processing.view'],    'operation_types',    'code', 'table', NULL),
        ('dictionary_processing_event_types', ARRAY['module.processing.view'], 'processing_event_types', 'code', 'collection', NULL),
        --   班次字典 —— MES-4a 把它放进 /settings/dictionaries(新的"时刻"字段:V6 · V7 的去处),于是它也有一段清单块的记录。
        ('dictionary_shifts', ARRAY['module.processing.view'], 'shifts', 'code', 'collection', NULL),
        -- MES-4b(2026-10-07,MES-4b Step 0 Q3 · Q21):电芯结构字典与交叉污染流字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries)。
        ('dictionary_cell_constructions', ARRAY['module.processing.view'], 'cell_constructions', 'code', 'collection', NULL),
        ('dictionary_contamination_streams', ARRAY['module.processing.view'], 'contamination_streams', 'code', 'collection', NULL),
        -- AUDIT-TRAIL-1d-2
        ('leave_request',     ARRAY['module.hr.view'],            'leave_requests',     'id', 'table', NULL),
        ('my_leave_request',  ARRAY[]::text[],                    'leave_requests',     'id', 'table', NULL),
        ('leave_grant',       ARRAY['module.hr.view'],            'leave_grants',       'id', 'table', NULL),
        ('leave_types',       ARRAY['module.hr.view'],            'leave_types',        'code', 'collection', NULL),
        ('public_holidays',   ARRAY['module.hr.view'],            'public_holidays',    'id', 'collection', NULL),
        ('medical_claim',     ARRAY['module.hr.view'],            'medical_claims',     'id', 'table', NULL),
        ('my_medical_claim',  ARRAY[]::text[],                    'medical_claims',     'id', 'table', NULL),
        ('overtime_batch',    ARRAY['module.hr.view', 'action.overtime_enter', 'action.overtime_approve'], 'overtime_batches', 'id', 'table', NULL),
        ('attendance_period', ARRAY['module.hr.view'],            'attendance_periods', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1d-3
        ('payroll_period',      ARRAY['module.hr.view'],          'payroll_periods',     'id', 'table', NULL),
        ('performance_review',  ARRAY['module.hr.view'],          'performance_reviews', 'id', 'table', NULL),
        ('my_review',           ARRAY[]::text[],                  'performance_reviews', 'id', 'gate:reviewer', NULL),
        ('review_cycle',        ARRAY['module.hr.view'],          'review_cycles',       'id', 'table', NULL),
        ('review_rating_scale', ARRAY['module.hr.view'],          'review_rating_scale', 'code', 'collection', NULL),
        ('kpi_entry',           ARRAY['module.hr.view'],          'kpi_entries',         'id', 'table', NULL),
        -- MES-1
        ('device',              ARRAY['module.processing.view'],  'devices',             'id', 'table', NULL),
        ('ingest_settings',     ARRAY['module.processing.view'],  'ingest_settings',     'id', 'table', NULL),
        -- MES-2(2026-10-06,MES-2 Step 0 Q33):地磅单 —— 收货或物流查看码任一(与表的读策略逐字同一对,Q22)
        ('weighbridge_ticket',  ARRAY['module.inbound.view', 'module.logistics.view'], 'weighbridge_tickets', 'id', 'table', NULL),
        -- MES-5a-2(2026-10-08,MES-5a Step 0 Q31):一张电费单的分摊(/finance/electricity/[id],财务查看码)· 分摊的设定(V25,单行设置作根)
        ('electricity_allocation', ARRAY['module.finance.view'],  'electricity_allocations', 'id', 'table', NULL),
        ('electricity_settings',   ARRAY['module.finance.view'],  'electricity_settings',    'id', 'table', NULL)
    ) AS s(subject, view_codes, root_table, root_key, root_rule, root_columns);
$function$;

-- db/functions/trail_subject_members.sql
-- AUDIT-TRAIL-1a(Tim 的 Q3 · Q6):一个主语的审计记录【由哪些行组成】—— 根行之外的子行与相关行。
--   每一行说:这张表里 fk_column 等于 parent_table 某一行的 id 的那些行,属于这条记录;match 是额外的固定条件
--   (多态的 approval_log 靠 subject_type 认主)。parent_table 可以是另一张子表(孙行:付款保留金挂在明细行上)。
--   按 ord 依次展开,所以孙行排在它的父行之后。
-- 【子行是在读的时候找出来的】(Q6)—— 不在记录上写父键。找法见 record_trail:今天还在的行按外键查,
--   已经删掉或改过父键的行从 change_log 的影像里查(GIN 索引 idx_change_log_image / idx_change_log_update_old)。
-- 【每一行子行都要再过一次它自己那张表的读规则】(Q4)—— 由 record_trail 调 trail_row_visible 做,不在这里。
--
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M4 与 Q4)多了三列:
--   hop    'down'(默认):table.fk_column = parent 那一行的 id(往下走)。
--          'up'(M4):table.id = parent 那一行的 fk_column(往上走一跳 —— 批次 → 消耗它的加工单、它收货的采购单)。
--   shown  true:这张表的行是这条记录的一部分,它们的每一次改动都进审计记录。
--          false:【垫脚石】—— 只用来够到它下面的行,它自己的改动不进来(Q4:"只限碰到这个批次的那些事")。
--          批次的审计记录经由加工单够到那张单的成本修改、分录与工单的审批,但加工单本身的编辑不在批次上。
--   home   true:这张表的行【住在】这个主语下 —— /settings/change-history 的"Record"一栏沿 home 的那一条往上走
--          (trail_row_record)。同一张表挂在两个主语下时(加工投入既属于加工单、也出现在批次上),只有一处是家。
--   原来旧批次审计记录那 20 支(db/views/batch_audit_trail_all.sql)的每一支都在下面有它的来处 ——
--   fixture 238 逐行对照两边,少一行就红。
CREATE OR REPLACE FUNCTION public.trail_subject_members()
 RETURNS TABLE(subject text, ord integer, table_name text, parent_table text, fk_column text, match jsonb, hop text, shown boolean, home boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        -- 采购单:明细行 · 付款计划 · 保留金 · 条款承诺 · 签发 · 合同条款 · 审批 · 修改史(Tim 的 AT-1a 范围)
        ('purchase_order', 1, 'purchase_order_lines',           'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 2, 'purchase_order_payment_terms',   'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 3, 'purchase_order_line_retentions', 'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 4, 'pricing_term_commitments',       'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 5, 'po_issues',                      'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 6, 'contract_document_terms',        'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 7, 'approval_log',                   'purchase_orders',      'subject_id',             '{"subject_type": "purchase_order"}'::jsonb, 'down', true, true),
        ('purchase_order', 8, 'purchase_order_history',         'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        -- 加工单:投入 · 产出 · 成本条目及其修改史 · 成本分摊 · 损耗;1b-1 加:回滚申请及其审批(Q12)
        ('processing_run', 1, 'processing_inputs',                 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 2, 'processing_outputs',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 3, 'processing_cost_entries',           'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 4, 'processing_cost_entry_history',     'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 5, 'batch_processing_cost_allocations', 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 6, 'processing_run_losses',             'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 7, 'warehouse_requests',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, false),
        ('processing_run', 8, 'approval_log',                      'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        -- 角色:授权(加上 / 拿掉);AUDIT-TRAIL-1d-1 加:授给了谁(Q22 —— 家在账号那一边:授出去的是那个账号)
        ('role', 1, 'role_permissions', 'roles', 'role_id', '{}'::jsonb, 'down', true, true),
        ('role', 2, 'user_roles',       'roles', 'role_id', '{}'::jsonb, 'down', true, false),

        -- ── 进料批次(1b-1)────────────────────────────────────────────────────────────────────────────
        -- 批次自己的:金属含量 · 化验与化验的金属 · 安全状态 · 价格 · 收货定价申请与它的审批 · 预付款核销 · 条款承诺 ·
        --   库存流水 · 盘点行与盘点的每一次清点 · 加工投入 · 成本分摊 · 销毁证书与签发 · 仓库申请(注销、证书作废)与它的审批 ·
        --   运费分摊 · 付款核销 · 财务附件
        ('inbound_batch',  1, 'inbound_batch_metals',              'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  2, 'assay_results',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  3, 'assay_result_metals',               'assay_results',               'assay_result_id',  '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  4, 'inbound_batch_safety_states',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  5, 'price_history',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  6, 'receipt_price_requests',            'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  7, 'approval_log',                      'receipt_price_requests',      'subject_id',       '{"subject_type": "receipt_price_request"}'::jsonb, 'down', true, true),
        ('inbound_batch',  8, 'prepayment_applications',           'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  9, 'pricing_term_commitments',          'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 10, 'pricing_term_commitment_metals',    'pricing_term_commitments',    'commitment_id',    '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 11, 'inventory_movements',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 12, 'stocktake_lines',                   'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 13, 'stocktake_counts',                  'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 14, 'processing_inputs',                 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 15, 'batch_processing_cost_allocations', 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 16, 'certificates_of_destruction',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 17, 'cod_issues',                        'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 18, 'warehouse_requests',                'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 19, 'warehouse_requests',                'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 20, 'approval_log',                      'warehouse_requests',          'subject_id',       '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch', 21, 'freight_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 22, 'payment_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 23, 'finance_attachments',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4),只取碰到这个批次的那些事:
        --   它收货的采购单 → 那张单的审批与修改史(旧 approval / po_change 两支)
        ('inbound_batch', 24, 'purchase_orders',                   'inbound_batches',             'purchase_order_id', '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 25, 'approval_log',                      'purchase_orders',             'subject_id',        '{"subject_type": "purchase_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 26, 'purchase_order_history',            'purchase_orders',             'purchase_order_id', '{}'::jsonb, 'down', true,  false),
        --   消耗它的加工单 → 那张单的成本修改史、成本条目(垫脚石)、工单(垫脚石)→ 工单的审批与修改史
        ('inbound_batch', 27, 'processing_runs',                   'processing_inputs',           'run_id',            '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 28, 'processing_cost_entry_history',     'processing_runs',             'run_id',            '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 29, 'processing_cost_entries',           'processing_runs',             'run_id',            '{}'::jsonb, 'down', false, false),
        ('inbound_batch', 30, 'work_orders',                       'processing_runs',             'work_order_id',     '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 31, 'approval_log',                      'work_orders',                 'subject_id',        '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 32, 'work_order_history',                'work_orders',                 'work_order_id',     '{}'::jsonb, 'down', true,  false),
        --   盘点过它的那一次盘点(垫脚石)→ 那次盘点过账的分录
        ('inbound_batch', 33, 'stocktakes',                        'stocktake_lines',             'stocktake_id',      '{}'::jsonb, 'up',  false, false),
        --   分录:直接挂在批次上的(计价、注销)· 预付款核销的 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('inbound_batch', 34, 'journal_entries',                   'inbound_batches',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 35, 'journal_entries',                   'prepayment_applications',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 36, 'journal_entries',                   'processing_cost_entries',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 37, 'journal_entries',                   'processing_runs',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 38, 'journal_entries',                   'stocktakes',                  'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 39, 'journal_entries',                   'journal_entries',             'reversed_by',       '{}'::jsonb, 'up',  true,  false),

        -- ── 产出批次(1b-1)────────────────────────────────────────────────────────────────────────────
        ('output_batch',  1, 'output_batch_metals',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  2, 'assay_results',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  3, 'assay_result_metals',               'assay_results',      'assay_result_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  4, 'output_batch_safety_states',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  5, 'inventory_movements',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  6, 'processing_outputs',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  7, 'processing_inputs',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  8, 'stocktake_lines',                   'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  9, 'stocktake_counts',                  'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 10, 'warehouse_requests',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 11, 'approval_log',                      'warehouse_requests', 'subject_id',      '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch', 12, 'sales_records',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 13, 'sales_record_movements',            'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 14, 'sales_attribution_log',             'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 15, 'invoice_lines',                     'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 16, 'payment_allocations',               'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 17, 'sales_order_reservations',          'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 18, 'shipment_lines',                    'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 19, 'traceability_report_issues',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 20, 'sales_settlements',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4):产出它 / 消耗它的加工单 → 成本修改史、成本条目(垫脚石)、工单 → 审批与修改史;
        --   盘点过它的盘点(垫脚石);它的销售对应的订单行(垫脚石)→ 那一行的订单修改史(旧 so_change 一支)
        ('output_batch', 21, 'processing_runs',                   'processing_outputs', 'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 22, 'processing_runs',                   'processing_inputs',  'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 23, 'processing_cost_entry_history',     'processing_runs',    'run_id',              '{}'::jsonb, 'down', true,  false),
        ('output_batch', 24, 'processing_cost_entries',           'processing_runs',    'run_id',              '{}'::jsonb, 'down', false, false),
        ('output_batch', 25, 'work_orders',                       'processing_runs',    'work_order_id',       '{}'::jsonb, 'up',  false, false),
        ('output_batch', 26, 'approval_log',                      'work_orders',        'subject_id',          '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('output_batch', 27, 'work_order_history',                'work_orders',        'work_order_id',       '{}'::jsonb, 'down', true,  false),
        ('output_batch', 28, 'stocktakes',                        'stocktake_lines',    'stocktake_id',        '{}'::jsonb, 'up',  false, false),
        ('output_batch', 29, 'sales_order_lines',                 'sales_records',      'sales_order_line_id', '{}'::jsonb, 'up',  false, false),
        ('output_batch', 30, 'sales_order_history',               'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true,  false),
        --   分录:注销(直接挂在批次上)· 销售与发货的成本 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('output_batch', 31, 'journal_entries',                   'output_batches',     'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 32, 'journal_entries',                   'sales_records',      'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 33, 'journal_entries',                   'processing_cost_entries', 'source_id',      '{}'::jsonb, 'down', true,  false),
        ('output_batch', 34, 'journal_entries',                   'processing_runs',    'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 35, 'journal_entries',                   'stocktakes',         'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 36, 'journal_entries',                   'journal_entries',    'reversed_by',         '{}'::jsonb, 'up',  true,  false),

        -- ── 工单(1b-1):明细 · 预期产出 · 修改史 · 放行审批 ─────────────────────────────────────────────
        ('work_order', 1, 'work_order_lines',            'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 2, 'work_order_expected_outputs', 'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 3, 'work_order_history',          'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 4, 'approval_log',                'work_orders', 'subject_id',    '{"subject_type": "work_order"}'::jsonb, 'down', true, true),

        -- ── 盘点(1b-1):盘点行 · 每一次清点 · 过账审批 · 过账分录(财务读)─────────────────────────────────
        ('stocktake', 1, 'stocktake_lines',  'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 2, 'stocktake_counts', 'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 3, 'approval_log',     'stocktakes', 'subject_id',   '{"subject_type": "stocktake"}'::jsonb, 'down', true, true),
        ('stocktake', 4, 'journal_entries',  'stocktakes', 'source_id',    '{"source_type": "stocktake"}'::jsonb, 'down', true, false),

        -- ── 设备(1b-1,Q22):保养维修 · 停机 · 保养周期 · 交接班里提到的那次停机 ────────────────────────────
        ('equipment', 1, 'equipment_maintenance',         'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 2, 'equipment_downtime',            'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 3, 'equipment_service_intervals',   'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 4, 'shift_handover_equipment_refs', 'equipment_downtime', 'downtime_id',  '{}'::jsonb, 'down', true, false),

        -- ── 交接班(1b-1,Q23):交接事项 · 提到的停机 ───────────────────────────────────────────────────
        ('shift_handover', 1, 'shift_handover_items',          'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),
        ('shift_handover', 2, 'shift_handover_equipment_refs', 'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),

        -- ── 仓库申请(1b-1,Q12):/inventory 那一块 —— 申请本身与它的审批 ─────────────────────────────────
        ('warehouse_request', 1, 'approval_log', 'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a)· 商务:报价、订单、发货、客户、佣金、供应商、物流 ══
        -- ── 报价:明细(硬删的行从影像里找)· 签发档 · 事件史 ─────────────────────────────────────────
        ('quote', 1, 'quote_lines',  'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 2, 'qt_issues',    'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 3, 'quote_history', 'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        -- ── 销售订单:明细 · 明细的预留 · 发货放行与它的明细、审批 · 签发档 · 事件史 · 合同条款 ──────────────
        --   ★ 预留、发货单明细、订单事件史以前挂在产出批次下面(home = false);它们的【家】是这张订单 / 这张发货单,
        --     所以 /settings/change-history 的 Record 一栏从此指向订单 / 发货单(trail_row_record 只沿 home 走)。
        ('sales_order', 1, 'sales_order_lines',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 2, 'sales_order_reservations', 'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true, true),
        ('sales_order', 3, 'shipping_releases',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 4, 'shipping_release_lines',   'shipping_releases',  'release_id',          '{}'::jsonb, 'down', true, true),
        ('sales_order', 5, 'approval_log',             'shipping_releases',  'subject_id',          '{"subject_type": "shipping_release"}'::jsonb, 'down', true, true),
        ('sales_order', 6, 'so_issues',                'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 7, 'sales_order_history',      'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 8, 'contract_document_terms',  'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        -- ── 发货单(M1:销售或发货的人都读得到):明细 · 送货单签发档 ─────────────────────────────────────
        ('shipment', 1, 'shipment_lines',  'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        ('shipment', 2, 'shipment_issues', 'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        -- ── 客户:联系人 · 附件 · 信用史 · 对账单与它的签发档 · 催收与它挂的单据、承诺
        --   (后四张只给财务读 —— 读不了的人那几行是 Restricted,Q4)────────────────────────────────────
        ('customer', 1, 'counterparty_contacts',      'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 2, 'customer_attachments',       'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 3, 'customer_credit_history',    'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 4, 'customer_statements',        'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 5, 'statement_issues',           'customer_statements', 'statement_id', '{}'::jsonb, 'down', true, true),
        ('customer', 6, 'collection_chases',          'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 7, 'collection_chase_documents', 'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        ('customer', 8, 'collection_promises',        'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        -- ── 供应商:合规证书 · 附件 · 联系人 · 状态变动史 · 审批(送审、批准、驳回)────────────────────────
        ('supplier', 1, 'supplier_compliance',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 2, 'supplier_attachments',    'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 3, 'counterparty_contacts',   'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 4, 'supplier_status_history', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 5, 'approval_log',            'suppliers', 'subject_id',  '{"subject_type": "supplier"}'::jsonb, 'down', true, true),
        -- ── 集装箱:里程碑 · 单据清单 ────────────────────────────────────────────────────────────────
        ('container', 1, 'container_milestones', 'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        ('container', 2, 'container_documents',  'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        -- ── 货代(M3):物流属性(一家一行,主键就是 supplier_id)· 按航段的报价 ──────────────────────────────
        ('forwarder', 1, 'forwarder_details',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('forwarder', 2, 'forwarder_rate_quotes', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        -- ── 航段:它的单据清单;港口:从它出发、到它为止的航段(两个外键,两行)──────────────────────────────
        ('lane', 1, 'lane_document_requirements', 'lanes', 'lane_id',             '{}'::jsonb, 'down', true, true),
        ('port', 1, 'lanes',                      'ports', 'origin_port_id',      '{}'::jsonb, 'down', true, false),
        ('port', 2, 'lanes',                      'ports', 'destination_port_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a)· 主数据与工具:物料、库位、金属价格、公式、任务 ══
        -- ── 物料:附件 · 必须化验的金属(复合主键,叶子)───────────────────────────────────────────────
        ('material', 1, 'material_attachments',     'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        ('material', 2, 'material_required_metals', 'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        -- ── 库位:允许存放的废物分类(Q13:保存只改变动的那几条,一次调用 —— save_storage_location)──────────
        ('storage_location', 1, 'storage_location_allowed_classes', 'storage_locations', 'location_id', '{}'::jsonb, 'down', true, true),
        -- ── 公式:应付金属(叶子)· 修改史 · 条款申请(只给持价格码的人读,别人那一行是 Restricted,Q4)· 申请的审批 ────
        ('pricing_formula', 1, 'pricing_formula_metals',  'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 2, 'pricing_formula_history', 'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 3, 'terms_requests',          'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 4, 'approval_log',            'terms_requests',   'subject_id', '{"subject_type": "terms_request"}'::jsonb, 'down', true, true),
        -- ── 任务(Q3:私人任务也是):步骤 · 参与者 · 修改史(三张表的人都是员工 id,M2)─────────────────────
        ('task', 1, 'task_nodes',        'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 2, 'task_participants', 'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 3, 'task_history',      'tasks', 'task_id', '{}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a)· 账上的单据 ══════════════════════════════════
        -- 冲销分录的 source_id 指的是【原分录】(reverse_journal_entry_internal),不是原单据 —— 所以一张单据够到它的冲销,
        --   只走原分录的 reversed_by(往上一跳,M4;批次 ord 39 的同一个做法),绝不按 source_id = 单据 id 去找。
        -- 一张冲销分录的行【不】挂在原分录上(Q33):行(ord 1)排在冲销(ord 2)之前展开,所以只取到根分录自己的行。
        -- ── 分录:行 · 它的冲销(往上)· 它冲的那一张(往下,在冲销分录的页上)· 申请(人工分录 / 冲销)与申请的审批 ──
        ('journal_entry', 1, 'journal_lines',    'journal_entries',  'entry_id',                '{}'::jsonb, 'down', true, true),
        ('journal_entry', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('journal_entry', 3, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'down', true, false),
        ('journal_entry', 4, 'journal_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('journal_entry', 5, 'journal_requests', 'journal_entries',  'target_entry_id',         '{}'::jsonb, 'down', true, false),
        ('journal_entry', 6, 'approval_log',     'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, false),
        -- AUDIT-TRAIL-1c-3:一次折旧的分录带着它记到每一张资产卡上的那一行(/finance/assets 的折旧批次一块读这张分录;
        --   家仍是资产那一页 —— 每一张资产卡自己也有它那一行,Step 0 §a)
        ('journal_entry', 7, 'fixed_asset_depreciation', 'journal_entries', 'journal_entry_id', '{}'::jsonb, 'down', true, false),
        -- ── 发票:行 · 签发档 · 作废 / 贷项申请与它的审批 · 由它开出的贷项通知 · 核销它的收款 · 它的分录与冲销 ──────
        ('invoice', 1, 'invoice_lines',    'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 2, 'invoice_issues',   'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 3, 'invoice_requests', 'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 4, 'approval_log',     'invoice_requests', 'subject_id',              '{"subject_type": "invoice_request"}'::jsonb, 'down', true, true),
        ('invoice', 5, 'credit_notes',     'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 6, 'payment_allocations', 'invoices',      'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 7, 'journal_entries',  'invoices',         'entry_id',                '{}'::jsonb, 'up',   true, false),
        ('invoice', 8, 'journal_entries',  'invoice_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        ('invoice', 9, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        -- ── 贷项通知:行 · 签发档 · 开出它的那张申请与审批 · 它的分录 ──────────────────────────────────────────
        ('credit_note', 1, 'credit_note_lines', 'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 2, 'cn_issues',         'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 3, 'invoice_requests',  'credit_notes',     'result_credit_note_id', '{}'::jsonb, 'down', true, false),
        ('credit_note', 4, 'approval_log',      'invoice_requests', 'subject_id',            '{"subject_type": "invoice_request"}'::jsonb, 'down', true, false),
        ('credit_note', 5, 'journal_entries',   'credit_notes',     'entry_id',              '{}'::jsonb, 'up',   true, false),
        -- ── 收付款:核销行 · 附件 · 冲销它的那一笔(往上)/ 它冲的那一笔(往下,在镜像单上)· 付出它的申请 · 冲它的申请 ·
        --    申请的审批 · 它的分录与冲销 ────────────────────────────────────────────────────────────────────────
        ('payment', 1, 'payment_allocations', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, true),
        ('payment', 2, 'finance_attachments', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 3, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'up',   true, false),
        ('payment', 4, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'down', true, false),
        ('payment', 5, 'payment_requests',    'payments',         'result_payment_id',   '{}'::jsonb, 'down', true, false),
        ('payment', 6, 'payment_requests',    'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 7, 'approval_log',        'payment_requests', 'subject_id',          '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        ('payment', 8, 'journal_entries',     'payments',         'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('payment', 9, 'journal_entries',     'journal_entries',  'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 付款申请(六种:付款 · 付款冲销 · 行内转账 · 转账冲销 · 代扣税缴纳 · 缴纳冲销):审批 · 付出的那一笔 ·
        --    被冲的那一笔(垫脚石:它自己的事不是这张申请的)· 转账 · 缴纳 · 过账的分录与冲销 ──────────────────
        --    ★ 一张"代扣税缴纳"申请没有指向它造出的那一笔缴纳的外键(形状检查让 wht_remittance_id 在这一种上恒为空)——
        --      唯一的路是 申请 → result_journal_entry_id → wht_remittances.journal_entry_id(ord 8)。
        ('payment_request',  1, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, true),
        ('payment_request',  2, 'payments',         'payment_requests', 'result_payment_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  3, 'payments',         'payment_requests', 'payment_id',              '{}'::jsonb, 'up',   false, false),
        ('payment_request',  4, 'bank_transfers',   'payment_requests', 'result_transfer_id',      '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  5, 'bank_transfers',   'payment_requests', 'transfer_id',             '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  6, 'wht_remittances',  'payment_requests', 'wht_remittance_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  7, 'journal_entries',  'payment_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  8, 'wht_remittances',  'journal_entries',  'journal_entry_id',        '{}'::jsonb, 'down', true,  false),
        ('payment_request',  9, 'journal_entries',  'bank_transfers',   'reversal_entry_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request', 10, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true,  false),
        -- ── 费用 / 供应商账单:核销行 · 附件 · 定金冲抵 · 冲销它的那一张(往上)/ 它冲的那一张(往下)· 报销单与它的审批 ·
        --    资本化进资产的那一笔成本 · 它的分录 · 定金冲抵的分录 · 冲销 ────────────────────────────────────────
        ('expense',  1, 'payment_allocations',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  2, 'finance_attachments',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  3, 'prepayment_applications',  'expenses',                'expense_id',          '{}'::jsonb, 'down', true, true),
        ('expense',  4, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('expense',  5, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'down', true, false),
        ('expense',  6, 'expense_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  7, 'approval_log',             'expense_claims',          'subject_id',          '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('expense',  8, 'fixed_asset_cost_entries', 'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  9, 'journal_entries',          'expenses',                'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('expense', 10, 'journal_entries',          'prepayment_applications', 'source_id',           '{}'::jsonb, 'down', true, false),
        ('expense', 11, 'journal_entries',          'journal_entries',         'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- AUDIT-TRAIL-1d-2(Q37):医疗报销付款时建的那张费用单 —— 费用页够得到是哪一张报销单让它生出来的(家仍在报销单那一页)
        ('expense', 12, 'medical_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        -- ── 应付(Q5,M3 · M6):只有钱的那几样 —— 核销 · 运费分摊 · 定金冲抵 · 财务附件 · 价格 · 计价 / 注销 / 定金的分录与冲销 ──
        ('payable', 1, 'payment_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 2, 'freight_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 3, 'prepayment_applications', 'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 4, 'finance_attachments',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 5, 'price_history',           'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 6, 'journal_entries',         'inbound_batches',         'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 7, 'journal_entries',         'prepayment_applications', 'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 8, 'journal_entries',         'journal_entries',         'reversed_by',      '{}'::jsonb, 'up',   true, false),

        -- ══ AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a)· 其余的单据与合同 ══════════════════════════════════
        -- ── 销售(Q14):出库 · 归属客户 · 开票的那一行 · 收款核销 · 附件 · 收入 / 成本分录与它们的冲销 ─────────────────
        --    ★ 销售自己是一个主语的根了 —— /settings/change-history 的 Record 一栏把销售那一行与它的子行归到【这一笔销售】
        --      (以前归到产出批次:产出批次 ord 12 的 home 改成 false,于是从子行往上走到销售就停下)
        ('sale', 1, 'sales_record_movements', 'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 2, 'sales_attribution_log',  'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 3, 'invoice_lines',          'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 4, 'payment_allocations',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 5, 'finance_attachments',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, true),
        ('sale', 6, 'journal_entries',        'sales_records',   'source_id',       '{"source_type": "sale"}'::jsonb, 'down', true, false),
        ('sale', 7, 'journal_entries',        'sales_records',   'cogs_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('sale', 8, 'journal_entries',        'journal_entries', 'reversed_by',     '{}'::jsonb, 'up',   true, false),
        -- ── 运费单:分摊到的批次(家在这里 —— 它是这张单分出去的)· 付它的核销 · 过账分录 · 冲销分录 ───────────────────
        ('freight', 1, 'freight_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, true),
        ('freight', 2, 'payment_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, false),
        ('freight', 3, 'journal_entries',     'freight_documents', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('freight', 4, 'journal_entries',     'freight_documents', 'reversal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('freight', 5, 'journal_entries',     'journal_entries',   'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 资产(财务那一页,Q10):资产卡的修改史 · 成本 · 折旧与折旧基点 · 处置申请与它的审批 · 处置 / 折旧的分录 ·
        --    保养维修、停机、保养间隔(家仍是 equipment —— 加工那一页)─────────────────────────────────────────────
        ('fixed_asset',  1, 'fixed_asset_history',              'fixed_assets',             'fixed_asset_id',      '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  2, 'fixed_asset_cost_entries',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  3, 'fixed_asset_depreciation',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  4, 'fixed_asset_depreciation_anchors', 'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  5, 'asset_disposal_requests',          'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  6, 'approval_log',                     'asset_disposal_requests',  'subject_id',          '{"subject_type": "asset_disposal_request"}'::jsonb, 'down', true, true),
        ('fixed_asset',  7, 'equipment_maintenance',            'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  8, 'equipment_downtime',               'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  9, 'equipment_service_intervals',      'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 10, 'shift_handover_equipment_refs',    'equipment_downtime',       'downtime_id',         '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 11, 'journal_entries',                  'fixed_assets',             'disposal_journal_id', '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 12, 'journal_entries',                  'fixed_asset_depreciation', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 13, 'journal_entries',                  'journal_entries',          'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 对账单:行与每一行的匹配 · 对账记录与它写明的差额 ────────────────────────────────────────────────────
        ('bank_statement', 1, 'bank_statement_lines',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 2, 'bank_line_matches',                  'bank_statement_lines', 'statement_line_id', '{}'::jsonb, 'down', true, true),
        ('bank_statement', 3, 'bank_reconciliations',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 4, 'bank_reconciliation_variance_items', 'bank_reconciliations', 'reconciliation_id', '{}'::jsonb, 'down', true, true),
        -- ── GST 期间:申报那一刻抄下来的每一格 · 申报申请与它的审批。★ Q22:更正期间【不】挂在原期间上(那样更正件之后的
        --    每一次改动都会出现在原件上);更正件自己的记录以"为 GST-… 开的更正"开头,原件页上那一条链接照旧 ──────────────
        ('gst_period', 1, 'gst_return_boxes',    'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 2, 'gst_filing_requests', 'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 3, 'approval_log',        'gst_filing_requests', 'subject_id', '{"subject_type": "gst_filing_request"}'::jsonb, 'down', true, true),
        -- ── 汇率:它的修改史(录入 · 更正 · 撤回 —— 一件事两行:记录开始之后变更记录那一行说,之前修改史那一行说)──────
        ('fx_rate', 1, 'fx_rate_history', 'fx_rates', 'fx_rate_id', '{}'::jsonb, 'down', true, true),
        -- ── 管理包:没有成员(一份新包取代旧包时,旧包自己那几列说"被谁取代";不经 superseded_by 自连 —— 那会把前一份的
        --    整段历史拉到这一份上)
        -- ── 合同:七张条款表 · 它的申请(生效)与申请的审批(没有 pricing.view 的读者那几行是 Restricted,Q21)·
        --    把它挂到采购单 / 销售订单上的那一份快照(家仍在那张订单上)────────────────────────────────────────────
        ('contract',  1, 'contract_grade_specs',           'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  2, 'contract_insurance_obligations', 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  3, 'contract_volume_commitments',    'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  4, 'contract_pricing_terms',         'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  5, 'contract_settlement_terms',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  6, 'contract_refining_charges',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  7, 'contract_penalty_elements',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  8, 'terms_requests',                 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  9, 'approval_log',                   'terms_requests', 'subject_id',  '{"subject_type": "terms_request"}'::jsonb, 'down', true, false),
        ('contract', 10, 'contract_document_terms',        'contracts',      'contract_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a)· 期末、设置与清单页上的记录 ══════════════════════════
        -- ── 锁期(Q25 · Q3 · M7):月结 / 反结的 period_closes 与 finance_settings 之间一个键都没有 —— 整张表属于那一行。
        --    关账在同一笔里写 period_closes 一行、把锁往后挪;反结在同一笔里给那一行盖反结的戳、把锁往回挪 —— 各是一条
        ('finance_lock', 1, 'period_closes', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 年结:结转分录(往上)· 反结的冲销分录(往上)──────────────────────────────────────────────────
        ('year_close', 1, 'journal_entries', 'year_closes', 'closing_journal_id',  '{}'::jsonb, 'up', true, false),
        ('year_close', 2, 'journal_entries', 'year_closes', 'reversal_journal_id', '{}'::jsonb, 'up', true, false),
        -- ── 人工分录 / 冲销申请(Q17):它的审批(家在这里 —— 一张还没批的申请没有分录,它唯一的家是它自己)· 过账的那一张 ──
        ('journal_request', 1, 'approval_log',    'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, true),
        ('journal_request', 2, 'journal_entries', 'journal_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        -- ── 报销单(Q20):审批 · 收据(附件)· 批准时记下的那张费用单(往上)。/me 上报销人自己读同样的几张(M8)──────
        ('expense_claim',    1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, true),
        ('expense_claim',    2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, true),
        ('expense_claim',    3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        ('my_expense_claim', 1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('my_expense_claim', 2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, false),
        ('my_expense_claim', 3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        -- ── 行内转账:过账分录 · 冲销分录(往上)· 付出它 / 冲它的申请(往下,两把外键 —— 港口的先例)与申请的审批 ──
        ('bank_transfer', 1, 'journal_entries',  'bank_transfers',   'journal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 2, 'journal_entries',  'bank_transfers',   'reversal_entry_id',  '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 3, 'payment_requests', 'bank_transfers',   'result_transfer_id', '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 4, 'payment_requests', 'bank_transfers',   'transfer_id',        '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 5, 'approval_log',     'payment_requests', 'subject_id',         '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        -- ── 代扣税缴纳(Q30):它的分录 · 冲销那一张(经原分录的 reversed_by,往上)· 冲它的申请(wht_remittance_id)·
        --    付出它的申请(那种申请没有指向缴纳的外键 —— 只能经分录:payment_requests.result_journal_entry_id,往下)· 审批 ──
        ('wht_remittance', 1, 'journal_entries',  'wht_remittances',  'journal_entry_id',        '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 3, 'payment_requests', 'wht_remittances',  'wht_remittance_id',       '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 4, 'payment_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 5, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a · §d · §e)· 机制、设置与员工 ══════════════════════════════
        -- ── 账号(M9,Q24):授给它的角色(家在这里,Q22)· 它作为附加账号挂在谁身上 · 那张挂接史 · 它是谁的主账号
        --    (employees.user_id —— M10 只取那一列:那名员工别的每一次编辑不是账号的事)──────────────────────────────
        ('account', 1, 'user_roles',               'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 2, 'employee_accounts',        'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 3, 'employee_account_history', 'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 4, 'employees',                'auth.users', 'user_id', '{}'::jsonb, 'down', true, false),
        -- ── 审批方针(M7 · Q25):修改史整张属于那一行设置(两张表之间没有键 —— 锁期 / period_closes 的同一个做法)──────────
        ('approval_policy', 1, 'finance_settings_history', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 员工(Q28):任职履历 · 调薪申请与它的审批(只给 view_pay 的人读,别人那几行是 Restricted)· 培训(家在培训那一页,Q29)·
        --    附加账号与它的挂接史 · 账号的镜像(Q24 · Q21):主账号与附加账号(往上一跳到 auth.users,M9)与授给它们的角色 ——
        --    每一行照它自己的读规则:授权人人读得到,账号事件与挂接史只给 manage_permissions,别人是 Restricted ────────────────
        ('employee', 1, 'employment_history',       'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 2, 'salary_change_requests',   'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 3, 'approval_log',             'salary_change_requests', 'subject_id',  '{"subject_type": "salary_change_request"}'::jsonb, 'down', true, true),
        ('employee', 4, 'training_records',         'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 5, 'employee_accounts',        'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 6, 'employee_account_history', 'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 7, 'auth.users',               'employees',              'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 8, 'auth.users',               'employee_accounts',      'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 9, 'user_roles',               'auth.users',             'user_id',     '{}'::jsonb, 'down', true, false),
        -- ── 部门 · 培训记录 · 导入批次:没有成员。六本字典:M11 集合,没有成员 ──────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a)· 请假与考勤 ══════════════════════════════════════════
        -- ── 请假:消耗账(批准时扣、取消时还 —— 家在这里)· 审批 ─────────────────────────────────────────────
        --    /me 上本人读同样的两张(M8);两张的读规则都只给 hr.view,所以本人看到的是 Restricted(Q4 · Q14)
        ('leave_request',    1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, true),
        ('leave_request',    2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, true),
        ('my_leave_request', 1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, false),
        ('my_leave_request', 2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, false),
        -- ── 医疗报销:审批 · 付它的那张费用单(往上,M4)· 费用的分录 · 核销 · 冲销它的费用单与分录(只给财务,别人 Restricted)──
        ('medical_claim',    1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, true),
        ('medical_claim',    2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('medical_claim',    5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, false),
        ('my_medical_claim', 2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('my_medical_claim', 5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        -- ── 加班:行(删掉的行从 DELETE 的影像里找)· 审批(送审 · 批准 · 退回)──────────────────────────────────
        ('overtime_batch',   1, 'overtime_lines',      'overtime_batches', 'batch_id',          '{}'::jsonb, 'down', true, true),
        ('overtime_batch',   2, 'approval_log',        'overtime_batches', 'subject_id',        '{"subject_type": "overtime_batch"}'::jsonb, 'down', true, true),
        -- ── 考勤:每人一行(开月 · 补新人 · 记录 · 完成时冻住的那几列 —— 完成那一下的整批改动在界面上是一句)──────────
        ('attendance_period', 1, 'attendance_lines',   'attendance_periods', 'period_id',       '{}'::jsonb, 'down', true, true),
        -- ── 假期发放(清单块)· 假别 · 公共假期(M11 集合):没有成员 ──────────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a)· 工资与评审 ══════════════════════════════════════════
        -- ── 工资期:工资行(每次保存删了重插 —— 一次操作里按员工配对,Q11;家在这里)· 过账 / 撤销的申请与它们的审批 ·
        --    这一期的分录(过账 · 发薪 · CPF · 代扣款)按 source_id + source_type = 'payroll' 找 —— 【不】经 journal_entry_id
        --    往上走:撤销过账会把那一列置空(unpost_payroll_period_internal),往上一跳读的是今天的样子,过账与它的冲销会一起丢掉;
        --    source_id 撤不掉。冲销分录自己的 source_id 是原分录(1c-1),所以它经 reversed_by 往上一跳。分录只给财务(别人 Restricted)
        ('payroll_period',     1, 'payroll_lines',    'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     2, 'payroll_requests', 'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     3, 'approval_log',     'payroll_requests',    'subject_id',        '{"subject_type": "payroll_request"}'::jsonb, 'down', true, true),
        ('payroll_period',     4, 'journal_entries',  'payroll_periods',     'source_id',         '{"source_type": "payroll"}'::jsonb, 'down', true, false),
        ('payroll_period',     5, 'journal_entries',  'journal_entries',     'reversed_by',       '{}'::jsonb, 'up',   true, false),
        -- ── 评审:目标(删掉的目标从 DELETE 的影像里找)· 审批(送审 · 批准 · 本人确认;作废不写审批)──────────────────
        --    批准时改的员工那一行与任职履历【不】挂进来(Q7):它们没有指回评审的键,评审那一段按评审自己的几列说出结论
        --    /my-reviews 上审核人读同样的两张(M12);审批那几行的读规则是 hr.view,不持它的审核人看到的是 Restricted(Q5 · Q4)
        ('performance_review', 1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, true),
        ('performance_review', 2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, true),
        ('my_review',          1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, false),
        ('my_review',          2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, false),
        -- ── MES-1:设备 —— 网关钥匙(发放与撤销;哈希被 never 规则遮住)。收件箱 · 传输日志 · 中断不进变更记录(MES-0 Q14),不在这里 ──
        ('device',             1, 'gateway_keys',     'devices',             'gateway_id',        '{}'::jsonb, 'down', true, true),
        -- ── MES-2:设备 —— 校准记录(记 · 作废;Q33)。地磅单 —— 它的称重(毛重 · 皮重 · 更正)、分出去的份、照片(传 · 撤)。
        --    草稿与确认时改过的值不挂进来:它们的读码是加工(查看),不是地磅单的门;确认队列与地磅单页上直接列它们 ──
        ('device',             2, 'instrument_calibrations', 'devices',      'device_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 1, 'weighings',        'weighbridge_tickets', 'ticket_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 2, 'weighbridge_ticket_shares', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 3, 'weighbridge_ticket_photos', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        -- ── MES-3a(2026-10-06,MES-3a Step 0 Q12 · Q10):执照 —— 它每一类 NEA 废物的库存上限(给 · 改 · 拿掉)。
        --    进料批 / 产出批 —— 它进厂那一刻库存上限的判法(一批一行,只追加)。──
        ('company_licence',    1, 'licence_storage_limits', 'company_compliance', 'licence_id',  '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     40, 'receipt_ceiling_checks', 'inbound_batches',    'inbound_batch_id', '{}'::jsonb, 'down', true, true),
        ('output_batch',      37, 'receipt_ceiling_checks', 'output_batches',     'output_batch_id',  '{}'::jsonb, 'down', true, false),
        -- ── MES-3b(2026-10-07,MES-3b Step 0 Q7 · Q27):每一次印标签(印 · 补印与理由)—— 挂在它印的那样东西下面。
        --    一张表挂三个主语,只有一处是家(trail_row_record 沿 home 往上走):进料批那一支,与 receipt_ceiling_checks 同一个选法 ──
        ('inbound_batch',     41, 'label_prints',           'inbound_batches',    'inbound_batch_id',    '{}'::jsonb, 'down', true, true),
        ('output_batch',      38, 'label_prints',           'output_batches',     'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('storage_location',   2, 'label_prints',           'storage_locations',  'storage_location_id', '{}'::jsonb, 'down', true, false),
        -- ── MES-4a(2026-10-07,MES-4a Step 0 Q33):加工单 —— 记下的值、异常事件、结平、表头更正(都只追加,都按 run_id 挂)。
        --    一道工序 —— 它的字段、挂着的机器、配方(按 operation_type_code 挂在根行的 code 下)与配方的每一版(挂在配方下)。──
        ('processing_run',     9, 'processing_run_values',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    10, 'processing_run_events',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    11, 'processing_run_closures',    'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    12, 'processing_run_corrections', 'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('operation_type',     1, 'operation_type_fields',      'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     2, 'operation_type_equipment',   'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     3, 'process_recipes',            'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     4, 'process_recipe_versions',    'process_recipes',  'recipe_id',           '{}'::jsonb, 'down', true, true),
        -- ── MES-4b(2026-10-07,MES-4b Step 0 Q28):交叉污染抽检 —— 挂在它那一炉(家)与它抽的那一批极片下面(receipt_ceiling_checks 的先例:
        --    一张表挂两个主语,只有一处是家)。没抽的那一种没有批次,只出现在加工单上。──
        ('processing_run',    13, 'contamination_checks',       'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('output_batch',      39, 'contamination_checks',       'output_batches',   'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-1(2026-10-08,MES-5a Step 0 Q31):放电 —— 逐模组结果、通道分配、拆去隔离的模组。家在那一炉(结果与分配挂在放电那一炉,
        --    拆分挂在拆分那一炉);也出现在它们说的那一批上,结果还出现在记下它的放电柜上(device_id;今天手工录入不填它)。──
        ('processing_run',    14, 'discharge_module_results',      'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    15, 'discharge_channel_assignments', 'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    16, 'discharge_module_splits',       'processing_runs', 'split_run_id',     '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     42, 'discharge_module_results',      'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     43, 'discharge_module_splits',       'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('output_batch',      40, 'discharge_module_results',      'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('output_batch',      41, 'discharge_module_splits',       'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('device',             3, 'discharge_module_results',      'devices',         'device_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-2(2026-10-08,MES-5a Step 0 Q31):电表读数住在那台电表下;一张电费单分给一炉的那一份住在那张单下,也出现在那一炉上。──
        ('device',             4, 'meter_readings',                'devices',                 'device_id',     '{}'::jsonb, 'down', true, true),
        ('electricity_allocation', 1, 'electricity_allocation_lines', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    17, 'electricity_allocation_lines',  'processing_runs',         'run_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5b-2(2026-10-09,MES-5b Step 0 Q32 · Q34;MES5B1-V37-NOT-ON-OPERATION-TRAIL,Tim):一张电费单的撤回住在那张单下,
        --    也出现在它覆盖过的每一炉上(经那一炉的那一行往上一跳到那张分摊 —— 垫脚石,自己的改动不进来 —— 再往下到撤回)。
        --    一道工序每一种产出形态的预期得率(V37)住在那道工序下(按 operation_type_code 挂在根行的 code 下,与它的字段同形)。──
        ('electricity_allocation', 2, 'electricity_allocation_reversals', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    18, 'electricity_allocations',          'electricity_allocation_lines', 'allocation_id', '{}'::jsonb, 'up',   false, false),
        ('processing_run',    19, 'electricity_allocation_reversals', 'electricity_allocations',      'allocation_id', '{}'::jsonb, 'down', true, false),
        ('operation_type',     5, 'operation_type_output_forms',      'operation_types',              'operation_type_code', '{}'::jsonb, 'down', true, true)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- db/functions/change_log_mask_rules.sql
-- HISTORY-1(Tim 的 Q10 · Q7 · Q20):change_log_rows() 的遮蔽规则 —— 【一份】名单,一列一行。
--
-- 【来源】逐条抄自每一张 <表>_masked 视图里那句 CASE WHEN … THEN <列> ELSE NULL END(以 postgres
--   读 pg_get_viewdef,2026-09-28),外加本刀新建的 purchase_order_history_masked。
--   "源屏幕怎么遮,记录就怎么遮" —— 屏幕读的就是这些视图。
-- 【规则的写法】
--   code:<码>                    持这个码才看得见
--   code_or_self:<码>:<列>       持码,或那一行的 <列> 就是读者自己的员工 id(视图里的 OR id = current_user_employee())
--   pft:direction                pricing_formula_terms_visible(这一行的 direction)
--   pft:formula_id               pricing_formula_terms_visible(这一行所属公式的 direction)
--   pft3                         pricing_formula_history_masked 那三段:公式当前方向 ∧ old_direction ∧ new_direction
--   pay_journal:<码>             持码,或这一行所在分录不是工资分录(journal_lines_masked;U1-A,UNBLOCK-1 Q1)
--   apr_amount                   approval_log_amount_visible(subject_type, subject_id)(approval_log_masked;U1-A,Q8 · Q10)
--   apr_note                     approval_log_note_visible(subject_type, subject_id)(approval_log_masked;U1-B)
--   jr_amount                    journal_request_amount_visible(id)(journal_requests_masked;U1-B)
--   never                        谁都看不见(gateway_keys_masked 里 CASE WHEN false;MES-1 Q20:网关钥匙的哈希)
-- ★ MES-5a-2(2026-10-08)加了 6 行(105 → 111):电费分摊的五列金额与分给一炉的金额 —— 加工成本那条规矩(data.view_prices,Q30),
--   每一行抄自 electricity_allocations_masked / electricity_allocation_lines_masked 里那句 CASE。
--   MES-5b-2:+3 行(electricity_allocation_reversals 的三列金额),抄自 electricity_allocation_reversals_masked 里那句 CASE。111 → 114。
-- ★ MES-1(2026-10-06)加了 1 行(104 → 105):网关钥匙的哈希 —— never(Q20:任何读者、任何一份记录都不给)。
-- ★ U1-B(2026-10-05)加了 3 行(101 → 104):工资分录冲销申请的金额 · 医疗报销的批准 / 驳回理由(在报销单上与在审批留痕上)。
-- ★ U1-A(UNBLOCK-1,2026-10-05)加了 20 行(81 → 101):工资分录的金额(Q1)· 审批留痕上的金额(Q8 · Q10)· 人事备注(Q6)·
--   健康数据(Q8)· 工资期的合计与工资申请的快照和金额(Q9 · Q10)。每一行都抄自它那张 _masked 视图里的 CASE。
-- 【它会不会和视图漂开】会 —— 所以有一道闸:change_log_mask_gaps() 拿目录里【真的被遮的列】
--   (_masked 视图里 CASE … END AS <基表的列>)与本名单逐列对,缺一条或多一条都报;
--   gate 的 changemask 那一行在线上与重建两侧各问一次,fixture 234 里注入"删掉一条"必须变红。
CREATE OR REPLACE FUNCTION public.change_log_mask_rules()
 RETURNS TABLE(table_name text, column_name text, rule text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    VALUES
        ('approval_log'::text, 'amount_ccy'::text, 'apr_amount'::text),
        ('gateway_keys', 'key_hash', 'never'),
        ('approval_log', 'amount_base', 'apr_amount'),
        ('approval_log', 'note', 'apr_note'),
        ('company_profile', 'bank_name', 'code:data.view_banking'),
        ('company_profile', 'bank_account_name', 'code:data.view_banking'),
        ('company_profile', 'bank_account_no', 'code:data.view_banking'),
        ('company_profile', 'bank_swift', 'code:data.view_banking'),
        ('company_profile', 'bank_address', 'code:data.view_banking'),
        ('employees', 'work_email', 'code_or_self:data.view_identity:id'),
        ('employees', 'work_phone', 'code_or_self:data.view_identity:id'),
        ('employees', 'identity_no', 'code_or_self:data.view_identity:id'),
        ('employees', 'work_pass_no', 'code_or_self:data.view_identity:id'),
        ('employees', 'monthly_salary', 'code_or_self:data.view_pay:id'),
        ('employees', 'notes', 'code:module.hr.view'),
        ('employees', 'separation_notes', 'code:module.hr.view'),
        ('employment_history', 'old_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('employment_history', 'new_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('inbound_batches', 'unit_price', 'code:data.view_purchase_prices'),
        ('invoice_lines', 'unit_price', 'code:data.view_prices'),
        ('invoice_lines', 'amount_base', 'code:data.view_prices'),
        ('invoice_lines', 'amount_ccy', 'code:data.view_prices'),
        ('invoice_lines', 'tax_base', 'code:data.view_prices'),
        ('invoices', 'subtotal_base', 'code:data.view_prices'),
        ('invoices', 'tax_base', 'code:data.view_prices'),
        ('invoices', 'total_base', 'code:data.view_prices'),
        ('invoices', 'fx_rate', 'code:data.view_prices'),
        ('journal_lines', 'debit', 'pay_journal:data.view_pay'),
        ('journal_lines', 'credit', 'pay_journal:data.view_pay'),
        ('journal_lines', 'amount_ccy', 'pay_journal:data.view_pay'),
        ('journal_requests', 'amount_base', 'jr_amount'),
        ('leave_requests', 'reason', 'code_or_self:data.view_health:employee_id'),
        ('leave_requests', 'certificate_ref', 'code_or_self:data.view_health:employee_id'),
        ('leave_requests', 'exception_reason', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'amount_sgd', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'description', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'decision_notes', 'code_or_self:data.view_health:employee_id'),
        ('payment_term_template_lines', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('payroll_lines', 'gross_pay', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'employer_cpf', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'employee_cpf', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'other_deductions', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'net_pay', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_periods', 'gross_total', 'code:data.view_pay'),
        ('payroll_periods', 'employer_cpf_total', 'code:data.view_pay'),
        ('payroll_periods', 'employee_cpf_total', 'code:data.view_pay'),
        ('payroll_periods', 'other_deductions_total', 'code:data.view_pay'),
        ('payroll_periods', 'net_pay_total', 'code:data.view_pay'),
        ('payroll_requests', 'snapshot', 'code:data.view_pay'),
        ('payroll_requests', 'gross_total', 'code:data.view_pay'),
        ('payroll_requests', 'amount_base', 'code:data.view_pay'),
        ('performance_reviews', 'new_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('prepayment_applications', 'amount_base', 'code:data.view_purchase_prices'),
        ('prepayment_applications', 'amount_ccy', 'code:data.view_purchase_prices'),
        ('price_history', 'old_unit_price', 'code:data.view_purchase_prices'),
        ('price_history', 'new_unit_price', 'code:data.view_purchase_prices'),
        ('price_history', 'original_price', 'code:data.view_purchase_prices'),
        ('price_history', 'fx_rate', 'code:data.view_purchase_prices'),
        ('pricing_formula_history', 'old_payable_pct', 'pft3'),
        ('pricing_formula_history', 'new_payable_pct', 'pft3'),
        ('pricing_formula_history', 'old_treatment_charge_usd_per_tonne', 'pft3'),
        ('pricing_formula_history', 'new_treatment_charge_usd_per_tonne', 'pft3'),
        ('pricing_formula_history', 'old_flat_discount_pct', 'pft3'),
        ('pricing_formula_history', 'new_flat_discount_pct', 'pft3'),
        ('pricing_formula_metals', 'payable_pct', 'pft:formula_id'),
        ('pricing_formulas', 'treatment_charge_usd_per_tonne', 'pft:direction'),
        ('pricing_formulas', 'flat_discount_pct', 'pft:direction'),
        ('pricing_term_commitment_metals', 'payable_pct', 'code:data.view_purchase_prices'),
        ('pricing_term_commitments', 'treatment_charge_usd_per_tonne', 'code:data.view_purchase_prices'),
        ('pricing_term_commitments', 'flat_discount_pct', 'code:data.view_purchase_prices'),
        ('processing_cost_entries', 'amount_base', 'code:data.view_prices'),
        ('electricity_allocations', 'bill_amount', 'code:data.view_prices'),
        ('electricity_allocations', 'price_per_kwh', 'code:data.view_prices'),
        ('electricity_allocations', 'allocated_amount', 'code:data.view_prices'),
        ('electricity_allocations', 'overhead_amount', 'code:data.view_prices'),
        ('electricity_allocations', 'relieved_estimate_amount', 'code:data.view_prices'),
        ('electricity_allocation_lines', 'amount', 'code:data.view_prices'),
        ('electricity_allocation_reversals', 'bill_amount', 'code:data.view_prices'),
        ('electricity_allocation_reversals', 'actual_line_amount', 'code:data.view_prices'),
        ('electricity_allocation_reversals', 'restored_estimate_amount', 'code:data.view_prices'),
        ('processing_cost_entry_history', 'old_amount_base', 'code:data.view_prices'),
        ('processing_cost_entry_history', 'new_amount_base', 'code:data.view_prices'),
        ('processing_outputs', 'allocated_cost_base', 'code:data.view_prices'),
        ('processing_outputs', 'unit_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'material_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'process_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'total_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'capitalized_cost_base', 'code:data.view_prices'),
        ('warehouse_requests', 'amount_base', 'code:data.view_prices'),
        ('purchase_order_history', 'old_fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_payment_term', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_payment_term', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'released_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'withheld_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'price_provenance', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'tax_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_payment_terms', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'tax_total_ccy', 'code:data.view_purchase_prices'),
        ('sales_records', 'unit_price', 'code:data.view_prices'),
        ('sales_records', 'fx_rate', 'code:data.view_prices'),
        ('sales_records', 'amount_base', 'code:data.view_prices'),
        ('sales_records', 'price_provenance', 'code:data.view_prices');
$function$;

-- ── 7 · 换掉的视图(镜像原样):冲销过的冲抵不再算偏差 · 一炉的电只读没撤回的那一张 ──────────────────────

-- db/views/processing_cost_variance.sql
-- 估算 vs 实际,按成本类型 × 月(发票所在月)。目的不是看某一个月,而是让
-- 【系统性偏差】显形 —— 某类估算一直偏低,趋势会说话(FIN-6 D)。
-- cost_type 是表上的 CHECK 枚举(不是自由文本),分组可靠。
-- 只含估算冲抵(实际额行没有"估算 vs 实际"可言)。【属主权限】—— 见下。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin6-relieve-processing-accruals.sql.

--
-- OPS-12(2026-08-08):改为【属主权限】。原先是 security_invoker = on,而它读
-- processing_cost_entries.amount_base —— cut 2b 收回的敏感列。于是任何 authenticated
-- 调用者都撞 42501,这一页【从上线起就是空的】,被页面里的 `?? []` 盖成了干净的
-- HTTP 200。属主权限绕过列授权,所以把两道门原样写回视图体:
--   module.finance.view(这一页挂在财务子导航下)AND data.view_prices(它吐的是金额)。
-- 与 cut 2b 所有 _masked 视图同形、同理由。
--
-- MES-5a-2(2026-10-08):只算【留在炉上】的冲抵(deleted_at IS NULL)。一次电费分摊冲掉的估计被【软删】了(那一炉从此只带实际额,
-- Q24),而它们的 relief_expense_id 指着那张账单的费用单 —— 照旧算进来,就会拿几条估计去比【整张账单】(含 6200 的余数与别的炉的份),
-- 报出一个不存在的偏差。被冲抵过的估计不可能被别的路软删(guard_cost_entry_settled),所以这一句只排除分摊那一路。

-- MES-5b-2(2026-10-09,MES-5b Step 0 Q21,Tim):【冲销过的冲抵不再算】(ex.status = 'posted')。从本刀起冲销一张冲抵会把它冲抵掉的估计放回
-- "未结"(戳清掉),所以那几条本来就不会再进来;这一句管的是戳没清掉的那一种 —— 本刀之前就冲销了的冲抵(线上 0 条,开场读数),
-- 以及任何一条将来绕过 reverse_expense 的路。一张已冲销的单不是一个偏差。

CREATE OR REPLACE VIEW public.processing_cost_variance WITH (security_invoker = off) AS
 SELECT date_trunc('month'::text, e.expense_date::timestamp with time zone)::date AS month,
    x.cost_type,
    round(sum(x.accrued), 2) AS estimated_total,
    round(sum(x.actual), 2) AS actual_total,
    round(sum(x.actual) - sum(x.accrued), 2) AS variance,
        CASE
            WHEN sum(x.actual) > sum(x.accrued) THEN 'under_estimated'::text
            WHEN sum(x.actual) < sum(x.accrued) THEN 'over_estimated'::text
            ELSE 'exact'::text
        END AS direction
   FROM ( SELECT pce.relief_expense_id,
            pce.cost_type,
            sum(pce.amount_base) AS accrued,
            max(ex.amount_base) AS actual
           FROM processing_cost_entries pce
             JOIN expenses ex ON ex.id = pce.relief_expense_id
          WHERE pce.relieved_at IS NOT NULL AND pce.deleted_at IS NULL AND ex.status = 'posted'::text
          GROUP BY pce.relief_expense_id, pce.cost_type) x
     JOIN expenses e ON e.id = x.relief_expense_id
  WHERE has_permission('module.finance.view'::text) AND has_permission('data.view_prices'::text)
  GROUP BY (date_trunc('month'::text, e.expense_date::timestamp with time zone)::date), x.cost_type
  ORDER BY (date_trunc('month'::text, e.expense_date::timestamp with time zone)::date), x.cost_type;

GRANT SELECT ON public.processing_cost_variance TO authenticated;

-- db/views/processing_run_energy.sql
-- MES-5a-2(2026-10-08,规格 §9;MES-0 Q26;MES-5a Step 0 Q21 · Q23,Tim):【一炉用了多少电、每吨多少、放电回收了多少】—— 加工单页读它。
--   own_kwh       这一炉自己记下的 energy_kwh(参数与指标里那个字段的更正链末端;控制器或操作员记的,MES-4a)。没记为空。
--   allocated_kwh 一张电费单分给这一炉的 kWh(electricity_allocation_lines;一炉至多一行)与分的依据(allocation_basis)。没分过为空。
--   energy_kwh    = own_kwh,没记才用 allocated_kwh(Q21:一炉的电量是它自己的值,有就用它)。energy_source 说是哪一个('recorded' |
--                   'allocated');两个都没有为空 —— 不是零。
--   kwh_per_tonne = energy_kwh ÷ (total_input ÷ 1000)(Q23:每吨的分母是投入量,与 V1 容差、V10 份额、平衡同一个口径;total_input 是 kg)。
--   recovered_kwh 放电那一炉的模组结果里记下的回收能量之和(Wh ÷ 1000;当前的结果)。【另列,从不与耗电相抵】(Q21)。没记为空。
--   不含任何金额(金额在 electricity_allocation_lines_masked,data.view_prices)。属主权限 + 加工查看码。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.

-- MES-5b-2(2026-10-09,MES-5b Step 0 Q23,Tim):分到的 kWh 只取【没撤回】的那一张分摊的那一行 —— 一炉的分摊撤回之后可以再分一次,
-- 于是一炉可以有两行(撤回过的那一张一行、改正过的那一张一行);照旧 LEFT JOIN 会把那一炉读成两行,而撤回过的那一份不该再算。

CREATE OR REPLACE VIEW public.processing_run_energy WITH (security_invoker = off) AS
 SELECT r.id AS run_id,
    r.code,
    r.status,
    r.equipment_id,
    r.total_input,
    own.value_number AS own_kwh,
    l.kwh AS allocated_kwh,
    l.basis AS allocation_basis,
    l.allocation_id,
    COALESCE(own.value_number, l.kwh) AS energy_kwh,
        CASE
            WHEN own.value_number IS NOT NULL THEN 'recorded'::text
            WHEN l.kwh IS NOT NULL THEN 'allocated'::text
            ELSE NULL::text
        END AS energy_source,
        CASE
            WHEN COALESCE(own.value_number, l.kwh) IS NULL OR r.total_input IS NULL OR r.total_input <= 0::numeric THEN NULL::numeric
            ELSE round(COALESCE(own.value_number, l.kwh) / (r.total_input / 1000::numeric), 3)
        END AS kwh_per_tonne,
    rec.recovered_kwh
   FROM processing_runs r
     LEFT JOIN LATERAL ( SELECT v.value_number
           FROM processing_run_values v
          WHERE v.run_id = r.id AND v.field_code = 'energy_kwh'::text AND v.value_number IS NOT NULL
            AND NOT (EXISTS ( SELECT 1
                   FROM processing_run_values x
                  WHERE x.corrects_id = v.id))
          ORDER BY v.id DESC
         LIMIT 1) own ON true
     LEFT JOIN LATERAL ( SELECT ll.kwh,
            ll.basis,
            ll.allocation_id
           FROM electricity_allocation_lines ll
          WHERE ll.run_id = r.id AND NOT (EXISTS ( SELECT 1
                   FROM electricity_allocation_reversals v
                  WHERE v.allocation_id = ll.allocation_id))) l ON true
     LEFT JOIN LATERAL ( SELECT round(sum(d.energy_recovered_wh) / 1000::numeric, 3) AS recovered_kwh
           FROM discharge_module_results d
          WHERE d.run_id = r.id AND d.energy_recovered_wh IS NOT NULL
            AND NOT (EXISTS ( SELECT 1
                   FROM discharge_module_results y
                  WHERE y.corrects_id = d.id))) rec ON true
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_run_energy IS
    'MES-5a-2:一炉的电量(自己记的 energy_kwh,没记才用电费分摊分到的 kWh;来源在 energy_source)、每吨电耗(÷ 投入吨数)、放电回收的能量(另列,不相抵)。不含金额。门:module.processing.view。';

GRANT SELECT ON public.processing_run_energy TO authenticated;
REVOKE ALL ON public.processing_run_energy FROM anon;

-- db/views/processing_cost_entry_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

-- MES-5b-2(2026-10-09,Step 0 Q21):末尾加 relief_expense_id —— 费用单页要说出"冲掉这张月结冲抵会放回几条估计",而那一页的门是财务;
--   基表的读策略是加工查看码,财务读它是零行(一个权限拒绝读成"零条")。它是一个指向费用单的键,不是钱。

CREATE OR REPLACE VIEW public.processing_cost_entry_lookup WITH (security_invoker = off) AS
 SELECT id,
    run_id,
    cost_type,
    is_estimate,
    created_at,
    deleted_at,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    remitted_at,
    relieved_at,
    relief_expense_id
   FROM processing_cost_entries e
  WHERE has_permission('module.processing.view'::text) OR has_permission('module.finance.view'::text);

COMMENT ON VIEW public.processing_cost_entry_lookup IS
    'FIX-2a:加工成本条目的【查名】视图 —— id / 加工单 / 成本类型 / 是否估算 / 创建时间 / 汇缴与冲销时点,外加按 data.view_prices 遮的金额(与 processing_cost_entries_masked 同一条列谓词)。财务的分录、总账、月结与加工成本四处要把一条分录指回它的来源单据,并回答"还欠着哪些"。fu1 补了 remitted_at / relieved_at:它们是状态时点不是钱,而两页的 .is() 过滤链要它们 —— 主迁移只读了 select 列表、没读过滤链,于是两页 42703(冒烟抓到,类型系统看不见)。行谓词 processing.view OR finance.view。';

GRANT SELECT ON public.processing_cost_entry_lookup TO authenticated;

-- ── 8 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.electricity_allocation_reversals
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.electricity_allocation_reversals
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 9 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.reverse_electricity_allocation(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reverse_electricity_allocation(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.reverse_expense_internal(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reverse_expense_internal(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_electricity_line_one_live_allocation() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_electricity_line_one_live_allocation() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.reverse_expense_internal(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_electricity_line_one_live_allocation() FROM authenticated;

-- ── 10 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes5b2_pending_decider_check(p_after boolean DEFAULT true)
 RETURNS TABLE(k text, doc text, raiser text, subject text, deciders int, decider_names text)
 LANGUAGE sql STABLE
AS $f$
WITH fs AS (SELECT approval_level1_role_code AS l1, approval_level2_role_code AS l2 FROM public.finance_settings),
real_perm AS (
    SELECT DISTINCT rp.permission_code, rg.user_id
      FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     CROSS JOIN LATERAL public.real_role_grants(r.code) rg),
people AS (SELECT DISTINCT user_id FROM real_perm),
holds AS (SELECT user_id, array_agg(permission_code) AS codes FROM real_perm GROUP BY user_id),
items AS (
    -- 报销单:分档链,直接问 approval_deciders
    SELECT 'expense_claim'::text AS k, c.code::text AS doc, c.created_by AS raiser, c.employee_id AS subj,
           d.user_id AS u
      FROM public.expense_claims c CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim',
                 public.approval_level_for((SELECT b.amount_base FROM public.expense_claim_amount_base(c.id) b)),
                 c.created_by, c.employee_id, fs.l1, fs.l2) d ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- 采购单:分档链;金额档位按更严的二级问(一级的资格 ⊇ 二级,R1)
    SELECT 'purchase_order', p.code, p.created_by, NULL,
           d.user_id
      FROM public.purchase_orders p CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('purchase_order', 'approve_purchase_order', 2::smallint,
                 p.created_by, NULL, fs.l1, fs.l2) d ON true
     WHERE p.approval_status = 'pending' AND p.deleted_at IS NULL
    UNION ALL
    -- 请假:decide_leave_request 的门(之前 module.hr.edit,之后 action.decide_hr_requests)
    --       + 余额函数要 module.hr.view(或本人)+ 四眼(R2 之后覆盖请假)
    SELECT 'leave_request', l.code, l.created_by, l.employee_id, h.user_id
      FROM public.leave_requests l CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = l.employee_id)
                       AND (public.self_leg(l.created_by, l.employee_id, h.user_id) = 'none'
                            OR (p_after AND public.self_approval_exception('leave_request', l.employee_id, h.user_id, fs.l2)))
     WHERE l.status = 'pending' AND l.deleted_at IS NULL
    UNION ALL
    SELECT 'medical_claim_submitted', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = m.employee_id)
                       AND (public.self_leg(m.created_by, m.employee_id, h.user_id) = 'none'
                            OR public.self_approval_exception('medical_claim', m.employee_id, h.user_id, fs.l2))
     WHERE m.status = 'submitted' AND m.deleted_at IS NULL
    UNION ALL
    -- 已批未付的医疗申报:pay_medical_claim 只要 module.finance.edit,没有自付检查(量过,Tim 的矩阵允许)
    SELECT 'medical_claim_approved (pay)', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m
      LEFT JOIN holds h ON 'module.finance.edit' = ANY (h.codes)
     WHERE m.status = 'approved' AND m.deleted_at IS NULL
    UNION ALL
    SELECT 'performance_review', r.id::text, r.submitted_by, r.employee_id, h.user_id
      FROM public.performance_reviews r
      LEFT JOIN holds h ON (CASE WHEN p_after THEN public.review_approval_code(r.submitted_by, r.employee_id)
                                 ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND public.self_leg(r.submitted_by, r.employee_id, h.user_id) = 'none'
     WHERE r.status = 'submitted'
    UNION ALL
    SELECT 'work_order', w.code, w.created_by, NULL, h.user_id
      FROM public.work_orders w
      -- ROLE-1 Batch 3b:下达归 action.wo_release;建单人不算(按人认)
      LEFT JOIN holds h ON 'action.wo_release' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      -- ROLE-1 Batch 3a:过账归 action.stocktake_post;开单人与录过数的每一个人都不算(按人认)
      LEFT JOIN holds h ON 'action.stocktake_post' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.stocktake_counts c
                                        WHERE c.stocktake_id = s.id
                                          AND public.self_leg(c.counted_by, NULL, h.user_id) <> 'none')
     WHERE s.status = 'open' AND s.deleted_at IS NULL
    UNION ALL
    -- ★ APR-7(grilling Q9):每一条申请链 —— 付款、工资、收货定价、贷项 / 作废、发货放行、手工凭证、仓库申请。
    --   它们在 approval_pending_documents 里带 fixed_level;决定人按 approval_deciders 问(与提交时的
    --   assert_other_decider 同一份判据),门取 approval_chain_gates 里那一行。APR-5b / APR-6 的自证只问了
    --   "这条链此刻有没有人",没有逐张问 —— 这一支补上。
    SELECT pd.subject_type, pd.code, pd.raiser_user_id, pd.subject_employee_id, d.user_id
      FROM public.approval_pending_documents() pd
      JOIN public.approval_chain_gates() g ON g.subject_type = pd.subject_type AND g.level = pd.fixed_level
     CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders(pd.subject_type, g.action_function, pd.fixed_level,
                 pd.raiser_user_id, pd.subject_employee_id, fs.l1, fs.l2) d ON true
     WHERE pd.fixed_level IS NOT NULL AND pd.subject_type NOT IN ('expense_claim', 'purchase_order')
    UNION ALL
    -- ★ APR-9:调薪申请按人路由(pay_decision_code),不在 approval_chain_gates 里 —— 问 salary_change_deciders,
    --   与 submit_salary_change_request 的"别人批得动吗"同一份判据。
    SELECT 'salary_change_request', q.label, q.created_by, q.employee_id, d.user_id
      FROM public.salary_change_requests q
      LEFT JOIN LATERAL public.salary_change_deciders(q.created_by, q.employee_id) d ON true
     WHERE q.status = 'submitted'
)
SELECT i.k, i.doc,
       (SELECT email::text FROM auth.users WHERE id = i.raiser),
       (SELECT legal_name FROM public.employees WHERE id = i.subj),
       count(DISTINCT COALESCE(public.account_person(i.u)::text, i.u::text))::int,
       string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = i.u), ' ')
  FROM items i
 GROUP BY i.k, i.doc, i.raiser, i.subj
 ORDER BY 1, 2
$f$;

CREATE TEMP TABLE mes5b2_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权一行都没动(本刀不加码、不改授权)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes5b2_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes5b2_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B2_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES5B2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes5b2_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes5b2_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES5B2_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变
    IF EXISTS ((SELECT b.k, b.id FROM mes5b2_pending_before b EXCEPT SELECT a.k, a.id FROM mes5b2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes5b2_pending_after a EXCEPT SELECT b.k, b.id FROM mes5b2_pending_before b)) THEN
        RAISE EXCEPTION 'MES5B2_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_runs t) IS DISTINCT FROM (SELECT processing_runs FROM mes5b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_cost_entries t) IS DISTINCT FROM (SELECT processing_cost_entries FROM mes5b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_cost_entry_history t) IS DISTINCT FROM (SELECT processing_cost_entry_history FROM mes5b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM expenses t) IS DISTINCT FROM (SELECT expenses FROM mes5b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM journal_entries t) IS DISTINCT FROM (SELECT journal_entries FROM mes5b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM journal_lines t) IS DISTINCT FROM (SELECT journal_lines FROM mes5b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM payments t) IS DISTINCT FROM (SELECT payments FROM mes5b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM payment_allocations t) IS DISTINCT FROM (SELECT payment_allocations FROM mes5b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM prepayment_applications t) IS DISTINCT FROM (SELECT prepayment_applications FROM mes5b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM devices t) IS DISTINCT FROM (SELECT devices FROM mes5b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM fixed_assets t) IS DISTINCT FROM (SELECT fixed_assets FROM mes5b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM fixed_asset_cost_entries t) IS DISTINCT FROM (SELECT fixed_asset_cost_entries FROM mes5b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM electricity_allocations t) IS DISTINCT FROM (SELECT electricity_allocations FROM mes5b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM electricity_allocation_lines t) IS DISTINCT FROM (SELECT electricity_allocation_lines FROM mes5b2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM operation_type_output_forms t) IS DISTINCT FROM (SELECT operation_type_output_forms FROM mes5b2_rows_before) THEN
        RAISE EXCEPTION 'MES5B2_PROOF|a pre-existing run, cost line, expense, journal, payment, allocation, device, asset or output form changed';
    END IF;

    -- ④ 变更记录一行都没动(本刀不写任何数据);新表是空的,线上仍然一次分摊都没有
    IF (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes5b2_log_before), 0)) <> 0 THEN
        RAISE EXCEPTION 'MES5B2_PROOF|change_log moved (%)', (SELECT string_agg(DISTINCT c.table_name, ', ') FROM change_log c
                                                                WHERE c.seq > COALESCE((SELECT mx FROM mes5b2_log_before), 0));
    END IF;
    IF EXISTS (SELECT 1 FROM electricity_allocation_reversals) OR EXISTS (SELECT 1 FROM electricity_allocations) THEN
        RAISE EXCEPTION 'MES5B2_PROOF|reversals or allocations exist';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B2_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑤ 结构:run_id 不再唯一,守卫与索引在;成本行两支守卫触发器在;'SGD' 字面量不在了
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'electricity_allocation_lines_run_id_key')
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_electricity_allocation_lines_one_live')
       OR to_regclass('public.electricity_allocation_lines_run_id_rel') IS NULL THEN
        RAISE EXCEPTION 'MES5B2_PROOF|run_id should no longer be unique, with the one-live guard and the index in place';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_processing_cost_entries_settlement_insert_guard')
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_processing_cost_entries_settled_guard') THEN
        RAISE EXCEPTION 'MES5B2_PROOF|the cost-entry settlement guards are missing';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.relieve_processing_accruals(uuid[], numeric, date, text, text, uuid, text, text)'::regprocedure)
         LIKE '%''SGD'', 1%' THEN
        RAISE EXCEPTION 'MES5B2_PROOF|the SGD literal is still in relieve_processing_accruals';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;撤回那一支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES5B2_PROOF|anon executes: %', v_bad;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.reverse_electricity_allocation(uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.reverse_electricity_allocation(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.reverse_electricity_allocation(uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B2_PROOF|public.reverse_electricity_allocation(uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF has_function_privilege('authenticated', 'public.reverse_expense_internal(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.reverse_expense_internal(uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B2_PROOF|public.reverse_expense_internal(uuid, text) must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_electricity_line_one_live_allocation()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_electricity_line_one_live_allocation()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B2_PROOF|public.guard_electricity_line_one_live_allocation() must be a function nobody outside can call';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('electricity_allocation_reversals', 'electricity_allocation_reversals_masked')
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B2_PROOF|anon can read %', v_bad; END IF;
    IF has_column_privilege('authenticated', 'public.electricity_allocation_reversals'::regclass, 'bill_amount', 'SELECT')
       OR has_column_privilege('authenticated', 'public.electricity_allocation_reversals'::regclass, 'actual_line_amount', 'SELECT')
       OR has_column_privilege('authenticated', 'public.electricity_allocation_reversals'::regclass, 'restored_estimate_amount', 'SELECT')
       OR NOT has_column_privilege('authenticated', 'public.electricity_allocation_reversals'::regclass, 'reason', 'SELECT') THEN
        RAISE EXCEPTION 'MES5B2_PROOF|the reversal amounts must be out of the column grant and the reason in it';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条;新表上没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5B2_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND tablename IN ('electricity_allocation_reversals') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES5B2_PROOF|a write policy exists on the reversals table';
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(新表记,豁免仍是 8);遮蔽零缺口(111 → 114 条)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES5B2_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES5B2_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑨ 提醒臂 59、待补的值 20 不变
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 20 THEN
        RAISE EXCEPTION 'MES5B2_PROOF|reminder arms 59 / pending-value arms 20 changed';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes5b2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES5B2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes5b2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES5B2_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes5b2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
