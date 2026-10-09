-- db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql
-- MES-6a-1 —— 样品与化验争议:一个新的「质量」区记样品(SMP-…)与它在谁手上直到处置;一份与对方对不上的化验可以立成一件争议,
--   挡住定价与结算直到结案;实验室可以指到它的供应商,于是仲裁费记成一张费用单;每一次费用冲销从此要一句理由
--   (MES 组的第十二刀,v1.4.48;发布那一行在 docs/handbacks/MES-6a-1.md 的抬头)。
-- 由 db/scripts/build_mes6a1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-09:MES-6a Step 0 —— Q1 拆两刀,本刀是 6a-1;Q2、Q5–Q45 中属于本刀的全部照推荐;Q12:仓库【不】加质量编辑码)
--   ① 四张新表:samples(SMP- 按年无洞 · 恰好一批 · 种类 · 留样日在建时抄下)· sample_events(保管记录,只追加)·
--      assay_disputes(open → resolved | withdrawn,只经函数)· quality_settings(单行:V16)。
--   ② 既有表加列:assay_results.sample_id(可空,样品必须同一批 —— 函数一道、表上守卫一道)· laboratories.supplier_id(可空)·
--      contract_settlement_terms.arbitration_fee_rule(可空 = V14)· expenses.reversal_reason / reversed_at / reversed_by(F3)+ 一条 CHECK。
--   ③ 挡:进料 apply_assay_result / preview_assay_price 与化验来源的定价过账(receipt_price_post_internal)、卖方 sale_settlement_compute,
--      在一件开着的争议上一律按名拒 ASSAY_DISPUTE_OPEN(Q18 · Q21);手工与按已承诺条款的改价照常。结案点名哪一份说了算,什么都不应用(Q19)。
--   ④ D4(Q20):应用一份结果只取代【同一出具方】的上一份 —— 进料与产出两支都改。
--   ⑤ F3(Q33–Q37):reverse_expense 与 reverse_electricity_allocation 都要理由(码之后第一件事),reverse_expense_internal 自己再拒空白;
--      理由写在被冲掉的那一张上,行守卫只在 posted → reversed 那一步放行这三列;镜像单的 notes 回到 'REVERSAL: <单号>'。签名不变。
--   ⑥ 码(Q11 · Q13 · Q90):module.quality.view(cco · cto · finance · cfo · admin · warehouse)/ module.quality.edit(cco · cto · admin);
--      action.apply_assay 声明的查看码多了 module.quality.view(结案在争议页上)。
--   ⑦ 提醒三支(sample_retention_due · assay_dispute_open · assay_results_disagree)· 待补的值两支(V16 · V14)· 审计主语三个(sample ·
--      assay_dispute · quality_settings)与两个批次主语的新成员 · 单据登记 SMP · 四张新表进变更记录(豁免仍是 8)· 没有新审批、没有新遮蔽列。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;除了上面九行质量码的授权,不加任何码、不改任何授权;不写、不改、不冲任何一张
--   既有单据、批次、化验、合同、费用单、付款、分录;不建任何样品、争议、实验室 → 供应商的指向,不填 V14、V16;require_calibrated_since 保持空。
--
-- 【破窗】见 docs/surveys/MES-6a/STEP0-HANDBACK.md §8:旧的费用页不送理由 → 每一次费用冲销都按名拒(EXPENSE_REVERSAL_REASON_REQUIRED,
--   旧应用印它的兜底句),直到部署;线上从没冲过一张费用单。旧的化验表单按具名参数调 record_assay_result,不带 p_sample_id → 默认值,照常。
--   争议的拒绝只在有争议时才咬,旧应用没有争议页。旧页面不读新表。窗口 ≈ 部署时长。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了那九行、别的一行没动,admin 持目录里每一个码;每一个角色仍满足
--   "动作码蕴含查看码";在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的化验、批次、含量、
--   定价申请、价格历史、分录、费用单、付款、合同与副本、实验室、销售单与结算、电费分摊与撤回、报销与医疗申报、供应商、库位、抽检逐字未变
--   (新加的列在比对时从两边减掉);变更记录只多了本刀种的那几行;四张新表空(设定表一行、天数为空);两支触发器在;record_assay_result
--   只剩新签名、reverse_expense 签名不变;anon 能执行的【恰好】两支;九支员工函数是 DEFINER、调得到,守卫函数调不到;那 44 条开着的读策略
--   还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 114);提醒臂 62、待补的值 22;单据登记 57 行。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES6A1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.samples') IS NOT NULL OR to_regclass('public.assay_disputes') IS NOT NULL
       OR to_regclass('public.sample_events') IS NOT NULL OR to_regclass('public.quality_settings') IS NOT NULL
       OR EXISTS (SELECT 1 FROM permissions WHERE code LIKE 'module.quality.%')
       OR EXISTS (SELECT 1 FROM document_types WHERE key = 'sample' OR prefix = 'SMP') THEN
        RAISE EXCEPTION 'MES6A1_PRE|MES-6a-1 objects already exist';
    END IF;
    IF to_regprocedure('public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text)') IS NULL THEN
        RAISE EXCEPTION 'MES6A1_PRE|record_assay_result does not have the signature this migration replaces';
    END IF;
    IF to_regprocedure('public.reverse_expense(uuid, text)') IS NULL THEN
        RAISE EXCEPTION 'MES6A1_PRE|reverse_expense(uuid, text) expected';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES6A1_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 75
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES6A1_PRE|expected a catalogue of 75 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 56 THEN
        RAISE EXCEPTION 'MES6A1_PRE|expected 56 document types';
    END IF;
    IF EXISTS (SELECT 1 FROM expenses WHERE status = 'reversed') THEN
        RAISE EXCEPTION 'MES6A1_PRE|a reversed expense exists — the reversal-shape CHECK was written for none';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES6A1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES6A1_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59 THEN
        RAISE EXCEPTION 'MES6A1_PRE|operations_now should have 59 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 20 THEN
        RAISE EXCEPTION 'MES6A1_PRE|pending_values should have 20 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6A1_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes6a1_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes6a1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes6a1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes6a1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes6a1_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'sample_id')::text, '|' ORDER BY (to_jsonb(t) - 'sample_id')::text), '')) FROM assay_results t) AS assay_results,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_result_metals t) AS assay_result_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t) AS inbound_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t) AS output_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batch_metals t) AS inbound_batch_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batch_metals t) AS output_batch_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM receipt_price_requests t) AS receipt_price_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM price_history t) AS price_history,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'reversal_reason' - 'reversed_at' - 'reversed_by')::text, '|' ORDER BY (to_jsonb(t) - 'reversal_reason' - 'reversed_at' - 'reversed_by')::text), '')) FROM expenses t) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_allocations t) AS payment_allocations,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_requests t) AS payment_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contracts t) AS contracts,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'arbitration_fee_rule')::text, '|' ORDER BY (to_jsonb(t) - 'arbitration_fee_rule')::text), '')) FROM contract_settlement_terms t) AS contract_settlement_terms,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_document_terms t) AS contract_document_terms,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'supplier_id')::text, '|' ORDER BY (to_jsonb(t) - 'supplier_id')::text), '')) FROM laboratories t) AS laboratories,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_orders t) AS sales_orders,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_settlements t) AS sales_settlements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM electricity_allocations t) AS electricity_allocations,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM electricity_allocation_reversals t) AS electricity_allocation_reversals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expense_claims t) AS expense_claims,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM medical_claims t) AS medical_claims,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t) AS suppliers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM storage_locations t) AS storage_locations,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contamination_checks t) AS contamination_checks;

-- ── 1 · 权限目录:两个质量码;action.apply_assay 的声明多一个 module.quality.view(与 db/tables/permissions.sql 逐字同一份)──────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('module.quality.view', 'module', 'Quality (view)', '质量(查看)', 'Samples and their custody, and assay disputes — read only. The samples and disputes panels on batch and assay pages also show to whoever may view that batch.', '样品与它的保管记录、化验争议 —— 只读。批次与化验页上的样品与争议面板,能看那一批的人也看得见。', 150),
    ('module.quality.edit', 'module', 'Quality (edit)', '质量(编辑)', 'Take a sample and record its custody (sent to a lab, received back, moved, disposed), set the internal sample retention, open or withdraw an assay dispute, record its umpire sample and result, and link the arbitration fee. Naming which result governs a dispute is "Apply and unapply assay results".', '取样并记它的保管(送实验室、拿回来、换库位、处置)、设内部留样天数、立或撤回一件化验争议、记它的仲裁样品与结果、挂上仲裁费。点名一件争议以哪一份结果为准是「应用与撤销应用化验结果」。', 151);
UPDATE public.permissions SET requires_view_any = ARRAY['module.inbound.view','module.output.view','module.quality.view']
 WHERE code = 'action.apply_assay';

-- ── 2 · 新表(镜像原样):质量的设定 · 样品 · 保管记录 · 化验争议 ─────────────────────────────────────────────

-- db/tables/quality_settings.sql
-- MES-6a-1(2026-10-09,MES-0 §5.1 V16;MES-6a Step 0 Q14,Tim):【质量的设定 —— 单行】。今天只有一样:V16。
--   internal_retention_days —— 一份【没有合同天数撑着】的样品留多少天(取样日 + 这个数 = 它的 retain_until)。为空 = "Not yet set":
--     那样的样品建出来 retain_until 为空(屏幕上 Not yet set),不进 sample_retention_due 的提醒。
--     为空、而且有一份还没处置、没有合同天数的样品时,/settings/pending-values 上 V16 那一行出现(module.quality.view)。
--   ★ 改它【不】回头改已有的样品 —— retain_until 在建的那一刻抄下(Q8)。
--   由 module.quality.edit 经 set_quality_settings 改;修改史在变更记录里(主语 quality_settings,画在 /quality/samples)。
--   RUNTIME CONFIG:引导一行、天数为空;Tim 填一次,线上就与本文件不同 —— 那是系统在正常工作(electricity_settings 的先例)。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.quality_settings (
    id                      boolean PRIMARY KEY DEFAULT true CHECK (id),
    internal_retention_days integer CHECK (internal_retention_days IS NULL OR internal_retention_days > 0),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    updated_by              uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.quality_settings IS
    'MES-6a-1:质量的设定(单行)。internal_retention_days = V16,没有合同天数的样品留多少天;为空时那样的样品 retain_until 为空(Not yet set)。改它不回头改已有的样品。module.quality.edit 经 set_quality_settings 改。';
COMMENT ON COLUMN public.quality_settings.internal_retention_days IS
    'V16(MES-0 §5.1):没有合同天数的样品留多少天。空 = Not yet set。由 Tim / 质量在第一份要留的样品时给。';

INSERT INTO public.quality_settings (id) VALUES (true);

CREATE TRIGGER trg_quality_settings_updated_at
    BEFORE UPDATE ON public.quality_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.quality_settings ENABLE ROW LEVEL SECURITY;
-- 读:质量查看码(样品页的设定面板与待补的值那一行)。写只经函数。
CREATE POLICY "quality_settings select by permission" ON public.quality_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.quality.view'::text));
GRANT SELECT ON public.quality_settings TO authenticated;
REVOKE ALL ON public.quality_settings FROM anon;

-- db/tables/samples.sql
-- MES-6a-1(2026-10-09,MES-0 功能 15 · Q53 · Q61;MES-6a Step 0 Q7–Q10 · Q14 · Q15,Tim):【一份实物样品】—— 从一批货上取下来的那一罐。
--   SETTLE-1 留下的那个"说出来的未满足前提"(仲裁要送第三方复检,而复检要有一个罐子)在这里落地:系统从此说得出一份样品
--   是谁的、哪一批的、在谁手上、在哪儿、还留多久、处置了没有。
--
--   【编号】SMP-YYYY-NNNN,按年、无洞(next_sample_code;document_types 里的 'sample',MES-0 Q53)。
--   【父】恰好一批 —— 进料批或产出批(num_nonnulls = 1,化验单 assay_results_one_parent 的同一个形状)。
--   【种类】ours · counterparty · umpire · retained · contamination(MES-0 Q61)。种类说的是这一罐【为谁、为什么】取的,
--     不说它现在在哪 —— 那是 sample_events 的事。contamination 那一种可以指一条交叉污染抽检(MES-4b 的表一字未改,Q10)。
--   【留到哪一天】retain_until 在建的那一刻【抄下来】,以后不改(Q8):
--     · 指了一张销售单、而那张单挂着的合同副本(contract_document_terms.settlement_terms)要求留样并写了天数 → 取样日 + 合同天数(contract);
--     · 否则 → 取样日 + V16(quality_settings.internal_retention_days,internal);
--     · V16 也是空的 → retain_until 为空,屏幕上是 "Not yet set"(not_set)—— 没有人说过留多久,系统不编一个。
--     V16 或合同以后改了,【不】回头改一份已有的样品(retain_until_source 与 retention_days_at 说清楚当时按的是什么)。
--   【写】只经 SECURITY DEFINER 函数 record_sample(module.quality.edit)—— 表上一条写策略都没有。保管与处置写在 sample_events(只追加)。
--   【读】module.quality.view,或那一批自己那一页的查看码(Q11:批次与化验页上的样品面板给两种码任一的人看)。
--   【没有金额】这里只有克数与日期,所以没有遮蔽的列(Q40)。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.samples (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                   text NOT NULL UNIQUE,
    inbound_batch_id       uuid REFERENCES public.inbound_batches (id),
    output_batch_id        uuid REFERENCES public.output_batches (id),
    kind                   text NOT NULL CHECK (kind IN ('ours', 'counterparty', 'umpire', 'retained', 'contamination')),
    taken_on               date NOT NULL,
    mass_g                 numeric CHECK (mass_g IS NULL OR mass_g > 0),
    -- 可选:这一罐是为哪一张销售单留的(只有产出批有销售单)—— 留样天数从那张单挂着的合同副本里读(Q8)
    sales_order_id         uuid REFERENCES public.sales_orders (id),
    -- 可选:kind = contamination 时指它那一条交叉污染抽检(Q10)
    contamination_check_id bigint REFERENCES public.contamination_checks (id),
    retain_until           date,
    retain_until_source    text NOT NULL CHECK (retain_until_source IN ('contract', 'internal', 'not_set')),
    retention_days_at      integer CHECK (retention_days_at IS NULL OR retention_days_at > 0),
    notes                  text,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid DEFAULT auth.uid(),
    CONSTRAINT samples_one_parent CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    CONSTRAINT samples_sales_order_on_output CHECK (sales_order_id IS NULL OR output_batch_id IS NOT NULL),
    CONSTRAINT samples_check_only_for_contamination CHECK (contamination_check_id IS NULL OR kind = 'contamination'),
    -- 【留到哪一天与它的出处必须同时成立】not_set ⇔ 没有日期、没有天数;其余两种 ⇔ 两样都有,而日期 = 取样日 + 天数
    CONSTRAINT samples_retention_consistent CHECK (
        (retain_until_source = 'not_set' AND retain_until IS NULL AND retention_days_at IS NULL)
        OR (retain_until_source IN ('contract', 'internal') AND retention_days_at IS NOT NULL
            AND retain_until = taken_on + retention_days_at))
);

CREATE INDEX samples_inbound_batch_id_rel ON public.samples (inbound_batch_id);
CREATE INDEX samples_output_batch_id_rel ON public.samples (output_batch_id);
CREATE INDEX samples_sales_order_id_rel ON public.samples (sales_order_id);
CREATE INDEX samples_contamination_check_id_rel ON public.samples (contamination_check_id);
-- 搜索:code 的后缀匹配(与 blending_plans 同一条)
CREATE INDEX samples_code_trgm ON public.samples USING gin (code extensions.gin_trgm_ops);

COMMENT ON TABLE public.samples IS
    'MES-6a-1:一份实物样品(SMP-YYYY-NNNN)—— 一批货(进料或产出,恰好一个)上取下来的一罐。种类 ours / counterparty / umpire / retained / contamination(MES-0 Q61)。留到哪一天在建的那一刻抄下(合同天数、否则 V16、否则 Not yet set),以后不改(Q8)。保管与处置是 sample_events(只追加);谁拿着、在哪、什么状态都从最近那一条读(sample_rows)。写只经 record_sample(module.quality.edit)。';
COMMENT ON COLUMN public.samples.retain_until IS
    '留到哪一天。建的那一刻 = 取样日 + 合同副本的留样天数(那张销售单的合同要求留样时)或 + V16;两样都没有时为空 —— 屏幕上是 Not yet set,不编日子,也不进 sample_retention_due 的提醒。以后改合同或 V16【不】回头改它。';
COMMENT ON COLUMN public.samples.retain_until_source IS
    'retain_until 按的是什么:contract(销售单挂着的合同副本)· internal(V16,quality_settings.internal_retention_days)· not_set(都没有)。';
COMMENT ON COLUMN public.samples.contamination_check_id IS
    'kind = contamination 时可以指它那一条交叉污染抽检(MES-4b,contamination_checks;那张表本刀一字未改)。那条抽检必须是同一批产出批上的、取过样的那一种。';

ALTER TABLE public.samples ENABLE ROW LEVEL SECURITY;
-- 读:质量查看码,或那一批自己那一页的查看码(Q11)。写:一条策略都不给 —— 只经 record_sample。
CREATE POLICY "samples select by permission" ON public.samples
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.quality.view'::text)
        OR (inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)));
GRANT SELECT ON public.samples TO authenticated;
REVOKE ALL ON public.samples FROM anon;

-- db/tables/sample_events.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q7 · Q15,Tim):【一份样品的保管记录 —— 只追加】。一行 = 一件发生过的事:
--   taken          取下来了(record_sample 自己写第一行;可以说放在哪个库位)
--   sent_to_lab    送去了哪一家实验室(laboratories,必填),带实验室那一侧的编号(可选)
--   received_back  从实验室拿回来了(可以说放在哪个库位)
--   moved          换了库位(库位必填)
--   disposed       处置掉了(理由必填)—— 之后这份样品不再有任何一行
--   【谁拿着、在哪、什么状态】都从【最近那一行】读(sample_rows),表上不另存一列状态 —— 一个事实一个地方(SETTLE-1 ② 那句
--   "还在不在"由一条记录回答,不由一个旗标回答)。
--   【先后】id 是 bigserial —— 同一笔事务里写的两行 created_at 相同,而 id 记得先后(AGENTS.md「取最新那一行」那一条);
--   occurred_at 不许早于上一行的 occurred_at(SAMPLE_EVENT_OUT_OF_ORDER),所以两种排法说的是同一个先后。
--   【顺序的规矩】拿在手上(taken / received_back / moved)才送得出去、挪得动、处置得了;在实验室时只能拿回来或处置(实验室毁样)。
--   【早于留样日的处置】允许,理由必填,并且被标出来(sample_rows.disposed_early,Q15)—— 一个没有合同天数撑着的日子不该挡人。
--   写只经 record_sample_event(与 record_sample 里的第一行)—— 表上一条写策略都没有;UPDATE / DELETE / TRUNCATE 一律语句级拒。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.sample_events (
    id                  bigserial PRIMARY KEY,
    sample_id           uuid NOT NULL REFERENCES public.samples (id),
    event_kind          text NOT NULL CHECK (event_kind IN ('taken', 'sent_to_lab', 'received_back', 'moved', 'disposed')),
    occurred_at         timestamptz NOT NULL,
    laboratory_code     text REFERENCES public.laboratories (code),
    lab_reference       text,
    storage_location_id uuid REFERENCES public.storage_locations (id),
    reason              text,
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    CONSTRAINT sample_events_lab_shape CHECK ((event_kind = 'sent_to_lab') = (laboratory_code IS NOT NULL)
                                              AND (lab_reference IS NULL OR event_kind = 'sent_to_lab')),
    CONSTRAINT sample_events_location_shape CHECK (
        (event_kind <> 'moved' OR storage_location_id IS NOT NULL)
        AND (storage_location_id IS NULL OR event_kind IN ('taken', 'received_back', 'moved'))),
    CONSTRAINT sample_events_disposal_reason CHECK (
        (event_kind = 'disposed') = (reason IS NOT NULL) AND (reason IS NULL OR btrim(reason) <> ''))
);

CREATE INDEX sample_events_sample_id_rel ON public.sample_events (sample_id, id);
CREATE INDEX sample_events_laboratory_code_rel ON public.sample_events (laboratory_code);
CREATE INDEX sample_events_storage_location_id_rel ON public.sample_events (storage_location_id);
-- 一份样品最多被处置一次
CREATE UNIQUE INDEX uq_sample_events_one_disposal ON public.sample_events (sample_id) WHERE event_kind = 'disposed';

COMMENT ON TABLE public.sample_events IS
    'MES-6a-1:一份样品的保管记录,只追加 —— taken · sent_to_lab(实验室必填)· received_back · moved(库位必填)· disposed(理由必填)。谁拿着、在哪、什么状态从最近一行读(sample_rows);id 记先后,occurred_at 不许倒退。写只经 record_sample / record_sample_event(module.quality.edit)。';
COMMENT ON COLUMN public.sample_events.occurred_at IS
    '这件事发生的时刻(人说的,可以早于记下来的时刻),不许早于这份样品上一行的时刻(SAMPLE_EVENT_OUT_OF_ORDER)—— 于是按 id 排与按它排是同一个先后。';

CREATE TRIGGER trg_sample_events_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.sample_events
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.sample_events ENABLE ROW LEVEL SECURITY;
-- 读:与它那份样品同一句(质量查看码,或那一批自己那一页的查看码)。子查询把条件写全 —— trail_row_visible 在 DEFINER 里求值,
--   那里子查询不再过 samples 的 RLS(trail_row_visible 抬头那条已知边界)。写:一条策略都不给。
CREATE POLICY "sample_events select by permission" ON public.sample_events
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM samples s WHERE s.id = sample_events.sample_id
                     AND (has_permission('module.quality.view'::text)
                          OR (s.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
                          OR (s.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)))));
GRANT SELECT ON public.sample_events TO authenticated;
REVOKE ALL ON public.sample_events FROM anon;

-- db/tables/assay_disputes.sql
-- MES-6a-1(2026-10-09,MES-0 功能 16 · Q62 · Q63;MES-6a Step 0 Q16–Q23,Tim):【一次化验争议】—— 我们的结果与对手方的结果对不上,
--   有人把它正式立起来,等一个仲裁(或撤回)。
--
--   【三态】open → resolved | withdrawn,只经函数(Q16):
--     open       open_assay_dispute(module.quality.edit)—— 同一批的一份 ours 与一份 counterparty,理由必填;一批同时最多一件开着的。
--     resolved   resolve_assay_dispute(action.apply_assay —— 今天应用化验的人;Q13)—— 点名【哪一份说了算】(同一批的任何一份:
--                我们的、对手方的、或仲裁的)并写一句说明。★ 它【什么都不应用】(Q19):说了算的那一份照常经 apply_assay_result
--                → CFO 批的定价申请(进料)或 apply_output_assay / 结算(产出)。没有自动的取平均、各让一半 —— 没有人给过那条规矩。
--     withdrawn  withdraw_assay_dispute(module.quality.edit),理由必填。
--   【开着的时候挡住什么】(Q18 · Q21)进料:apply_assay_result 与 preview_assay_price 按名拒 ASSAY_DISPUTE_OPEN,
--     receipt_price_post_internal 拒过账一张来源是化验的定价申请(一张在等的申请的指纹里没有争议这一项,所以批准那一刻再看一次);
--     手工定价与按已承诺条款改价照常(一个暂定价不是 Q62 说的"最终改价")。产出:sale_settlement_compute 按名拒。
--   【容差在案】limit_pct_at 在立案那一刻抄下:卖方 = 指了销售单时那张单的合同副本(splitting_limit_pct);买方 = 空 ——
--     买方合同今天不带结算口径(Q62:"limit not set")。fee_rule_at 同理抄 arbitration_fee_rule(V14,只卖方合同有)。
--   【逐元素的差】不存,由 assay_dispute_metals 现算(Q16)。
--   【仲裁】umpire_sample_id / umpire_assay_id 开着时经 record_dispute_umpire 记(可选)。
--   【仲裁费】是一张普通的未付费用单,付给那家实验室在供应商表里的那一户(laboratories.supplier_id,Q22 · Q23),
--     经 link_dispute_fee 挂在这里;对手方该担的那一份【只算出来给人看】(assay_dispute_rows),不收 —— 收它(应收或结算扣减)
--     等指数定价 §9 与第一件真争议。付那张费用单照常要那户供应商已批准(PAYMENT_REQUEST_SUPPLIER_BLOCKED)。
--   【没有单据编号】(MES-0 Q53 没给它前缀;Q41)—— 屏幕上按批号 + 立案时刻认。
--   写只经上面那几支 SECURITY DEFINER 函数 —— 表上一条写策略都没有。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.assay_disputes (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbound_batch_id      uuid REFERENCES public.inbound_batches (id),
    output_batch_id       uuid REFERENCES public.output_batches (id),
    our_assay_id          uuid NOT NULL REFERENCES public.assay_results (id),
    counterparty_assay_id uuid NOT NULL REFERENCES public.assay_results (id),
    -- 卖方可选:哪一张销售单的合同说了容差与仲裁费的分摊(只有产出批有销售单)
    sales_order_id        uuid REFERENCES public.sales_orders (id),
    status                text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'withdrawn')),
    opening_reason        text NOT NULL CHECK (btrim(opening_reason) <> ''),
    limit_pct_at          numeric CHECK (limit_pct_at IS NULL OR (limit_pct_at > 0 AND limit_pct_at <= 100)),
    fee_rule_at           text CHECK (fee_rule_at IS NULL OR fee_rule_at IN
                                      ('loser_pays', 'equal', 'further_from_umpire_pays', 'buyer', 'seller')),
    umpire_sample_id      uuid REFERENCES public.samples (id),
    umpire_assay_id       uuid REFERENCES public.assay_results (id),
    governing_assay_id    uuid REFERENCES public.assay_results (id),
    resolution_note       text,
    resolved_at           timestamptz,
    resolved_by           uuid,
    withdrawn_at          timestamptz,
    withdrawn_by          uuid,
    withdraw_reason       text,
    fee_expense_id        uuid REFERENCES public.expenses (id),
    created_at            timestamptz NOT NULL DEFAULT now(),
    created_by            uuid DEFAULT auth.uid(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    updated_by            uuid,
    CONSTRAINT assay_disputes_one_parent CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    CONSTRAINT assay_disputes_sales_order_on_output CHECK (sales_order_id IS NULL OR output_batch_id IS NOT NULL),
    CONSTRAINT assay_disputes_two_assays CHECK (our_assay_id <> counterparty_assay_id),
    -- 【状态与它的证据必须同时成立】(配料计划、工单那几条 CHECK 的同一个理由:约束对任何写入者都成立)
    CONSTRAINT assay_disputes_resolved_consistent CHECK (
        (status = 'resolved') = (resolved_at IS NOT NULL)
        AND (resolved_at IS NULL) = (governing_assay_id IS NULL)
        AND (resolved_at IS NULL OR btrim(COALESCE(resolution_note, '')) <> '')),
    CONSTRAINT assay_disputes_withdrawn_consistent CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL OR btrim(COALESCE(withdraw_reason, '')) <> ''))
);

CREATE INDEX assay_disputes_inbound_batch_id_rel ON public.assay_disputes (inbound_batch_id);
CREATE INDEX assay_disputes_output_batch_id_rel ON public.assay_disputes (output_batch_id);
CREATE INDEX assay_disputes_our_assay_id_rel ON public.assay_disputes (our_assay_id);
CREATE INDEX assay_disputes_counterparty_assay_id_rel ON public.assay_disputes (counterparty_assay_id);
CREATE INDEX assay_disputes_sales_order_id_rel ON public.assay_disputes (sales_order_id);
CREATE INDEX assay_disputes_umpire_sample_id_rel ON public.assay_disputes (umpire_sample_id);
CREATE INDEX assay_disputes_umpire_assay_id_rel ON public.assay_disputes (umpire_assay_id);
CREATE INDEX assay_disputes_governing_assay_id_rel ON public.assay_disputes (governing_assay_id);
CREATE INDEX assay_disputes_fee_expense_id_rel ON public.assay_disputes (fee_expense_id);
-- 一批同时最多一件开着的争议(函数里先按名拒 ASSAY_DISPUTE_ALREADY_OPEN,唯一索引是第二道)
CREATE UNIQUE INDEX uq_assay_disputes_one_open_inbound ON public.assay_disputes (inbound_batch_id)
    WHERE status = 'open' AND inbound_batch_id IS NOT NULL;
CREATE UNIQUE INDEX uq_assay_disputes_one_open_output ON public.assay_disputes (output_batch_id)
    WHERE status = 'open' AND output_batch_id IS NOT NULL;

COMMENT ON TABLE public.assay_disputes IS
    'MES-6a-1:一次化验争议 —— 同一批的一份我们的结果与一份对手方的结果。open → resolved(点名哪一份说了算,action.apply_assay;什么都不应用)| withdrawn(理由必填)。开着时进料那一侧的应用化验、试算与化验来源的定价申请过账按名拒 ASSAY_DISPUTE_OPEN,卖方结算同样;手工与按已承诺条款的改价照常。容差与仲裁费分摊在立案时从销售单的合同副本抄下(买方为空 = limit not set)。逐元素的差由 assay_dispute_metals 现算。仲裁费是一张普通的未付费用单,付给实验室在供应商表里那一户。';
COMMENT ON COLUMN public.assay_disputes.limit_pct_at IS
    '立案那一刻在案的分歧容差(百分点):卖方 = 指了销售单时那张单的合同副本里的 splitting_limit_pct;买方或没指销售单 = 空,屏幕上是 limit not set(MES-0 Q62)。合同以后改了不回头改它。';
COMMENT ON COLUMN public.assay_disputes.fee_rule_at IS
    '立案那一刻在案的仲裁费分摊规则(V14,contract_settlement_terms.arbitration_fee_rule 的副本):loser_pays · equal · further_from_umpire_pays · buyer · seller;空 = Not yet set。';
COMMENT ON COLUMN public.assay_disputes.governing_assay_id IS
    '结案时点名说了算的那一份(同一批的任何一份:我们的、对手方的或仲裁的)。点名【不应用】它 —— 它照常经应用化验与定价申请(进料)或结算(产出)。';
COMMENT ON COLUMN public.assay_disputes.fee_expense_id IS
    '仲裁费那一张费用单(普通、未付;付给实验室在供应商表里那一户 —— laboratories.supplier_id)。付它照常要那户供应商已批准。';

ALTER TABLE public.assay_disputes ENABLE ROW LEVEL SECURITY;
-- 读:质量查看码,或那一批自己那一页的查看码(Q11 —— 批次与化验页上的争议横幅;卖方结算以 module.output.view 读它,
--   所以 sale_settlement_compute 的那一道拒绝对一个过得了它第二道闸的读者【不会】因为读不到而放过去)。写:一条策略都不给。
CREATE POLICY "assay_disputes select by permission" ON public.assay_disputes
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.quality.view'::text)
        OR (inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)));
GRANT SELECT ON public.assay_disputes TO authenticated;
REVOKE ALL ON public.assay_disputes FROM anon;

-- ── 3 · 既有表加列(与各自的表镜像逐字同一份:列定义、索引、注释)──────────────────────────────────────────
ALTER TABLE public.assay_results ADD COLUMN sample_id uuid REFERENCES public.samples (id);
CREATE INDEX assay_results_sample_id_rel ON public.assay_results (sample_id);
COMMENT ON COLUMN public.assay_results.sample_id IS
'MES-6a-1(Step 0 Q9):这份结果化验的是哪一份实物样品(samples)。可空 —— 今天的记录路径照旧走得通,sample_ref 那段自由文本照旧留着。
样品必须挂在同一批上(SAMPLE_NOT_FOR_BATCH:记录函数与 trg_assay_results_sample_batch 各一道)。';

COMMENT ON COLUMN public.assay_results.superseded_by IS
'指向【取代了本份结果的那一份】。含义是:"我们重新化验了,以那一份为准。"

★ MES-6a-1(Step 0 Q20):这一条从此由 apply_assay_result / apply_output_assay 执行 —— 应用一份结果时,只把【同一出具方】
上一份已应用、未被取代的结果指向它;应用对手方或仲裁的结果不碰我们的那一份(fixture 118 F5)。

【D4:对手方的结果【不是】对我们结果的取代 —— 不要用这一列去记它】
这个诱惑很明显:对手方报来一个不同的数字,顺手把我们的那份标成 superseded。
**那会静静地把我们自己测到的东西盖掉**,而两份结果本该【并存】:
一份是我们的,一份是对手方的,分歧本身就是要拿去谈的东西。
要记对手方的结果,就【新记一份化验单】并把 result_party 设成 ''counterparty'';
两份都留着、都读得出来。
**谁说了算是一个合同条款(PROC-0b 的 U12),不是一次 UPDATE。**';

ALTER TABLE public.laboratories ADD COLUMN supplier_id uuid REFERENCES public.suppliers (id);
COMMENT ON COLUMN public.laboratories.supplier_id IS
'MES-6a-1(MES-0 Q64 · MES-6a Step 0 Q23):给这家实验室付钱(仲裁费)时,付给供应商表里的哪一户 —— 上面那条 Tim 的裁定
("那一行字典指向一个 supplier")在这里兑现。可空:今天没有任何一家实验室有已知的付款户(引导的 FRL 为空,那仍然是对的)。
在字典编辑器里设(module.materials.edit,与这张表的写策略同一个码)。指着一户【不等于】付得出去:付款照常要那户供应商已批准
(PAYMENT_REQUEST_SUPPLIER_BLOCKED)。';

ALTER TABLE public.contract_settlement_terms ADD COLUMN
    arbitration_fee_rule text
        CHECK (arbitration_fee_rule IS NULL OR arbitration_fee_rule IN
               ('loser_pays', 'equal', 'further_from_umpire_pays', 'buyer', 'seller'));
COMMENT ON COLUMN public.contract_settlement_terms.arbitration_fee_rule IS
    'MES-6a-1(MES-0 Q63 · V14):仲裁费怎么分 —— loser_pays · equal · further_from_umpire_pays · buyer · seller。**可空 = Not yet set,不给默认值**(一份没写的分摊规则不是"各半")。只有卖方合同有结算口径,所以买方的争议永远是 Not yet set。随结算口径一起在挂接那一刻抄进单据的合同副本(link_document_to_contract 的 to_jsonb),立案时再抄进 assay_disputes.fee_rule_at。仲裁费本身是一张费用单;对手方的那一份只算出来给人看,不收(收它等指数定价 §9)。';

ALTER TABLE public.expenses
    ADD COLUMN reversal_reason text,
    ADD COLUMN reversed_at     timestamptz,
    ADD COLUMN reversed_by     uuid;

-- 【三列与状态是一件事】posted 的行三列都空;reversed 的行理由不空、时刻在(人可以是空的 —— 一次没有登录身份的系统冲销,
--   今天不存在,但不为它编一个人)。线上 0 张冲销过的费用单,所以这条约束不碰任何历史行。
ALTER TABLE public.expenses
    ADD CONSTRAINT expenses_reversal_shape CHECK (
        (status = 'posted' AND reversal_reason IS NULL AND reversed_at IS NULL AND reversed_by IS NULL)
     OR (status = 'reversed' AND btrim(COALESCE(reversal_reason, '')) <> '' AND reversed_at IS NOT NULL));

COMMENT ON COLUMN public.expenses.reversal_reason IS
'MES-6a-1(F3,Step 0 Q33–Q37):这一张为什么被冲销 —— 冲销的人写的一句话,必填(reverse_expense 与 reverse_electricity_allocation
两条路都在问码之后第一件事就查它,EXPENSE_REVERSAL_REASON_REQUIRED;reverse_expense_internal 自己再拒一次空的)。写在【被冲掉的这一张】上,
只在 posted → reversed 那一步写(guard_expense_mutation)。费用页的横幅、费用与报销单的审计记录都读它。
【不遮】(Q35):费用单不遮是常设裁定 1(持 module.finance.view 就看得见钱);理由框提示不要写健康细节。';
COMMENT ON COLUMN public.expenses.reversed_at IS 'MES-6a-1(F3):冲销的时刻(与 reversal_reason 同一步写)。';
COMMENT ON COLUMN public.expenses.reversed_by IS 'MES-6a-1(F3):谁冲销的(auth.uid(),与 reversal_reason 同一步写)。';

-- ── 4 · 新函数(镜像原样):取号 · 取样 · 保管 · V16 · 立 / 记仲裁 / 撤回 / 结案 / 挂仲裁费 · 样品守卫(表先在,%ROWTYPE 才解析得了)────────

-- db/functions/next_sample_code.sql
-- MES-6a-1(2026-10-09,MES-0 Q53 · MES-6a Step 0 Q7 · Q41):样品的编号 SMP-YYYY-NNNN —— 按年、无洞,与 next_blending_plan_code 逐行同形
--   (自己的一把 advisory lock;MAX(split_part)+1 带 LIKE 过滤;前缀从 document_types 读)。
--   宽度沿用兄弟们的 4 位(CODE-WIDTH-4 仍是它自己那一条,Q41)。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.next_sample_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】SMP 与 BLD / WO 各自连号 —— 共用一把会让一种单据烧掉另一种的号。
    PERFORM pg_advisory_xact_lock(hashtext('sample_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM samples
    WHERE code LIKE document_type_prefix('sample') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('sample') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- db/functions/record_sample.sql
-- MES-6a-1(2026-10-09,MES-0 Q61;MES-6a Step 0 Q7–Q10,Tim):【取一份样品】—— module.quality.edit。
--   恰好一批(进料或产出);种类 ours · counterparty · umpire · retained · contamination;取样日必填、不许晚于今天(新加坡日历),
--   没有默认值(AGENTS.md:决定一件事的日期必填);可选:克数、库位(第一行保管记录 taken 带着它)、销售单(只对产出批)、
--   交叉污染抽检(只对 contamination,同一批产出批上取过样的那一条)。
--   【留到哪一天】在这里抄下,以后不改(Q8):指了销售单、而那张单的合同副本要求留样并写了天数 → 取样日 + 合同天数(contract);
--   否则 → 取样日 + V16(quality_settings.internal_retention_days,internal);V16 也是空的 → 不写日子(not_set,屏幕上 Not yet set)。
--   第一行保管记录 taken 发生在取样日的新加坡零点(之后每一行都不许早于它)。返回 {sample_id, code, retain_until, retain_until_source}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.record_sample(p_kind text, p_taken_on date, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_mass_g numeric DEFAULT NULL::numeric, p_sales_order_id uuid DEFAULT NULL::uuid, p_contamination_check_id bigint DEFAULT NULL::bigint, p_storage_location_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_id      uuid := gen_random_uuid();
    v_code    text;
    v_st      jsonb;
    v_days    integer;
    v_source  text := 'not_set';
    v_until   date;
    v_check   record;
BEGIN
    PERFORM require_permission('module.quality.edit');
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'SAMPLE_ONE_PARENT';
    END IF;
    IF p_inbound_batch_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;
    IF p_output_batch_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF p_kind IS NULL OR p_kind NOT IN ('ours', 'counterparty', 'umpire', 'retained', 'contamination') THEN
        RAISE EXCEPTION 'SAMPLE_KIND_INVALID|%', COALESCE(p_kind, '?');
    END IF;
    IF p_taken_on IS NULL THEN
        RAISE EXCEPTION 'SAMPLE_DATE_REQUIRED';
    END IF;
    IF p_taken_on > (now() AT TIME ZONE 'Asia/Singapore')::date THEN
        RAISE EXCEPTION 'SAMPLE_DATE_IN_FUTURE|%', p_taken_on;
    END IF;
    IF p_mass_g IS NOT NULL AND p_mass_g <= 0 THEN
        RAISE EXCEPTION 'SAMPLE_MASS_INVALID|%', p_mass_g;
    END IF;
    IF p_storage_location_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = p_storage_location_id AND is_active) THEN
        RAISE EXCEPTION 'LOCATION_NOT_FOUND|%', p_storage_location_id;
    END IF;

    -- 交叉污染抽检(Q10):只对 contamination;同一批产出批上、取过样的那一条
    IF p_contamination_check_id IS NOT NULL THEN
        IF p_kind <> 'contamination' THEN
            RAISE EXCEPTION 'SAMPLE_CHECK_ONLY_FOR_CONTAMINATION|%', p_kind;
        END IF;
        SELECT c.id, c.kind, c.output_batch_id INTO v_check FROM contamination_checks c WHERE c.id = p_contamination_check_id;
        IF NOT FOUND OR v_check.kind <> 'sampled' OR v_check.output_batch_id IS DISTINCT FROM p_output_batch_id THEN
            RAISE EXCEPTION 'SAMPLE_CHECK_NOT_FOR_BATCH|%', p_contamination_check_id;
        END IF;
    END IF;

    -- 留到哪一天(Q8):合同天数 → V16 → Not yet set。抄下来,以后不改。
    IF p_sales_order_id IS NOT NULL THEN
        IF p_output_batch_id IS NULL THEN
            RAISE EXCEPTION 'SAMPLE_SALES_ORDER_NEEDS_OUTPUT_BATCH';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM sales_orders WHERE id = p_sales_order_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SO_NOT_FOUND|%', p_sales_order_id;
        END IF;
        SELECT t.settlement_terms INTO v_st FROM contract_document_terms t WHERE t.sales_order_id = p_sales_order_id;
        IF COALESCE((v_st ->> 'sample_retention_required')::boolean, false)
           AND (v_st ->> 'sample_retention_days') IS NOT NULL THEN
            v_days := (v_st ->> 'sample_retention_days')::integer;
            v_source := 'contract';
        END IF;
    END IF;
    IF v_days IS NULL THEN
        SELECT q.internal_retention_days INTO v_days FROM quality_settings q WHERE q.id;
        IF v_days IS NOT NULL THEN
            v_source := 'internal';
        END IF;
    END IF;
    IF v_days IS NOT NULL THEN
        v_until := p_taken_on + v_days;
    END IF;

    v_code := next_sample_code(p_taken_on);
    INSERT INTO samples (id, code, inbound_batch_id, output_batch_id, kind, taken_on, mass_g, sales_order_id,
                         contamination_check_id, retain_until, retain_until_source, retention_days_at, notes, created_by)
    VALUES (v_id, v_code, p_inbound_batch_id, p_output_batch_id, p_kind, p_taken_on, p_mass_g, p_sales_order_id,
            p_contamination_check_id, v_until, v_source, v_days, NULLIF(btrim(COALESCE(p_notes, '')), ''), v_user);
    INSERT INTO sample_events (sample_id, event_kind, occurred_at, storage_location_id, created_by)
    VALUES (v_id, 'taken', (p_taken_on::timestamp) AT TIME ZONE 'Asia/Singapore', p_storage_location_id, v_user);

    RETURN jsonb_build_object('sample_id', v_id, 'code', v_code, 'retain_until', v_until, 'retain_until_source', v_source);
END;
$function$;

-- db/functions/record_sample_event.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q7 · Q15,Tim):【记一件保管上的事】—— module.quality.edit,只追加。
--   sent_to_lab(实验室必填、要启用的;实验室那一侧的编号可选)· received_back(库位可选)· moved(库位必填)· disposed(理由必填)。
--   taken 只由 record_sample 写。时刻必填、不许晚于此刻、不许早于这份样品上一行的时刻(SAMPLE_EVENT_OUT_OF_ORDER)。
--   顺序:拿在手上(taken / received_back / moved)→ 送得出去、挪得动、处置得了;在实验室 → 只能拿回来或处置;处置之后什么都不能记。
--   早于留样日的处置照收(Q15),由 sample_rows.disposed_early 标出来。返回 {event_id, state}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.record_sample_event(p_sample_id uuid, p_event_kind text, p_occurred_at timestamp with time zone, p_laboratory_code text DEFAULT NULL::text, p_lab_reference text DEFAULT NULL::text, p_storage_location_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_sample samples%ROWTYPE;
    v_last   sample_events%ROWTYPE;
    v_state  text;
    v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
    v_id     bigint;
BEGIN
    PERFORM require_permission('module.quality.edit');
    SELECT * INTO v_sample FROM samples WHERE id = p_sample_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SAMPLE_NOT_FOUND|%', COALESCE(p_sample_id::text, '?');
    END IF;
    IF p_event_kind IS NULL OR p_event_kind NOT IN ('sent_to_lab', 'received_back', 'moved', 'disposed') THEN
        RAISE EXCEPTION 'SAMPLE_EVENT_KIND_INVALID|%', COALESCE(p_event_kind, '?');
    END IF;
    IF p_occurred_at IS NULL THEN
        RAISE EXCEPTION 'SAMPLE_EVENT_TIME_REQUIRED';
    END IF;
    IF p_occurred_at > now() THEN
        RAISE EXCEPTION 'SAMPLE_EVENT_IN_FUTURE|%', v_sample.code;
    END IF;

    -- 最近那一行决定现在的状态(id 记先后)
    SELECT * INTO v_last FROM sample_events WHERE sample_id = p_sample_id ORDER BY id DESC LIMIT 1;
    v_state := CASE v_last.event_kind WHEN 'sent_to_lab' THEN 'at_lab' WHEN 'disposed' THEN 'disposed' ELSE 'held' END;
    IF v_state = 'disposed' THEN
        RAISE EXCEPTION 'SAMPLE_DISPOSED|%', v_sample.code;
    END IF;
    IF NOT ((v_state = 'held' AND p_event_kind IN ('sent_to_lab', 'moved', 'disposed'))
            OR (v_state = 'at_lab' AND p_event_kind IN ('received_back', 'disposed'))) THEN
        RAISE EXCEPTION 'SAMPLE_EVENT_NOT_ALLOWED|%|%|%', v_sample.code, v_state, p_event_kind;
    END IF;
    IF p_occurred_at < v_last.occurred_at THEN
        RAISE EXCEPTION 'SAMPLE_EVENT_OUT_OF_ORDER|%|%', v_sample.code, v_last.occurred_at;
    END IF;

    IF p_event_kind = 'sent_to_lab' THEN
        IF p_laboratory_code IS NULL THEN
            RAISE EXCEPTION 'SAMPLE_LAB_REQUIRED|%', v_sample.code;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM laboratories WHERE code = p_laboratory_code AND is_active) THEN
            RAISE EXCEPTION 'LAB_NOT_FOUND|%', p_laboratory_code;
        END IF;
    ELSIF p_laboratory_code IS NOT NULL OR NULLIF(btrim(COALESCE(p_lab_reference, '')), '') IS NOT NULL THEN
        RAISE EXCEPTION 'SAMPLE_LAB_ONLY_WHEN_SENT|%', v_sample.code;
    END IF;
    IF p_event_kind = 'moved' AND p_storage_location_id IS NULL THEN
        RAISE EXCEPTION 'SAMPLE_LOCATION_REQUIRED|%', v_sample.code;
    END IF;
    IF p_storage_location_id IS NOT NULL THEN
        IF p_event_kind NOT IN ('received_back', 'moved') THEN
            RAISE EXCEPTION 'SAMPLE_LOCATION_NOT_FOR_EVENT|%|%', v_sample.code, p_event_kind;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = p_storage_location_id AND is_active) THEN
            RAISE EXCEPTION 'LOCATION_NOT_FOUND|%', p_storage_location_id;
        END IF;
    END IF;
    IF p_event_kind = 'disposed' AND v_reason IS NULL THEN
        RAISE EXCEPTION 'SAMPLE_DISPOSAL_REASON_REQUIRED|%', v_sample.code;
    END IF;
    IF p_event_kind <> 'disposed' AND v_reason IS NOT NULL THEN
        RAISE EXCEPTION 'SAMPLE_REASON_ONLY_WHEN_DISPOSED|%', v_sample.code;
    END IF;

    INSERT INTO sample_events (sample_id, event_kind, occurred_at, laboratory_code, lab_reference, storage_location_id,
                               reason, notes, created_by)
    VALUES (p_sample_id, p_event_kind, p_occurred_at, p_laboratory_code, NULLIF(btrim(COALESCE(p_lab_reference, '')), ''),
            p_storage_location_id, v_reason, NULLIF(btrim(COALESCE(p_notes, '')), ''), v_user)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('event_id', v_id, 'code', v_sample.code,
        'state', CASE p_event_kind WHEN 'sent_to_lab' THEN 'at_lab' WHEN 'disposed' THEN 'disposed' ELSE 'held' END);
END;
$function$;

-- db/functions/set_quality_settings.sql
-- MES-6a-1(2026-10-09,MES-0 §5.1 V16;MES-6a Step 0 Q14,Tim):【写下(或清空)V16 —— 没有合同天数的样品留多少天】。
--   module.quality.edit。NULL = 清空(回到 Not yet set);给了就必须 > 0(QUALITY_RETENTION_DAYS_INVALID)。
--   ★ 不回头改已有的样品(retain_until 在建的那一刻抄下,Q8)。改动进变更记录(主语 quality_settings,画在 /quality/samples)。
--   返回 {internal_retention_days}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.set_quality_settings(p_internal_retention_days integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.quality.edit');
    IF p_internal_retention_days IS NOT NULL AND p_internal_retention_days <= 0 THEN
        RAISE EXCEPTION 'QUALITY_RETENTION_DAYS_INVALID|%', p_internal_retention_days;
    END IF;
    UPDATE quality_settings SET internal_retention_days = p_internal_retention_days, updated_by = auth.uid() WHERE id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'QUALITY_SETTINGS_MISSING';
    END IF;
    RETURN jsonb_build_object('internal_retention_days', p_internal_retention_days);
END;
$function$;

-- db/functions/open_assay_dispute.sql
-- MES-6a-1(2026-10-09,MES-0 Q62;MES-6a Step 0 Q16 · Q17 · Q22,Tim):【立一件化验争议】—— module.quality.edit。
--   同一批(进料或产出)的一份 ours 与一份 counterparty(出具方按名核对:ASSAY_DISPUTE_PARTY_MISMATCH);理由必填;
--   一批同时最多一件开着的(ASSAY_DISPUTE_ALREADY_OPEN —— 唯一索引是第二道)。不判两份差多少:立不立是人的决定(Q17 —— 买方没有提示,
--   一个人自己立;卖方的提示是 assay_results_disagree 那一支)。
--   【容差与仲裁费分摊在案】卖方可以指一张销售单(只对产出批):那张单挂着的合同副本里的 splitting_limit_pct 与 arbitration_fee_rule
--   抄进 limit_pct_at / fee_rule_at;买方或没指销售单 → 两样都空(limit not set · Not yet set,Q62 · Q22)。
--   开着之后进料那一侧的应用、试算与化验来源的定价过账按名拒,卖方结算按名拒(ASSAY_DISPUTE_OPEN)。
--   返回 {dispute_id, batch_code, limit_pct_at, fee_rule_at}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.open_assay_dispute(p_our_assay_id uuid, p_counterparty_assay_id uuid, p_reason text, p_sales_order_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
    v_ours   assay_results%ROWTYPE;
    v_cp     assay_results%ROWTYPE;
    v_bcode  text;
    v_st     jsonb;
    v_limit  numeric;
    v_rule   text;
    v_id     uuid := gen_random_uuid();
BEGIN
    PERFORM require_permission('module.quality.edit');
    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_ours FROM assay_results WHERE id = p_our_assay_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_our_assay_id::text, '?');
    END IF;
    SELECT * INTO v_cp FROM assay_results WHERE id = p_counterparty_assay_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_counterparty_assay_id::text, '?');
    END IF;
    IF v_ours.result_party <> 'ours' THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_PARTY_MISMATCH|%|%|ours', v_ours.code, v_ours.result_party;
    END IF;
    IF v_cp.result_party <> 'counterparty' THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_PARTY_MISMATCH|%|%|counterparty', v_cp.code, v_cp.result_party;
    END IF;
    IF v_ours.inbound_batch_id IS DISTINCT FROM v_cp.inbound_batch_id
       OR v_ours.output_batch_id IS DISTINCT FROM v_cp.output_batch_id THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_SAME_BATCH|%|%', v_ours.code, v_cp.code;
    END IF;

    -- 锁住那一批:判"有没有开着的"与立案串行
    IF v_ours.inbound_batch_id IS NOT NULL THEN
        SELECT code INTO v_bcode FROM inbound_batches WHERE id = v_ours.inbound_batch_id AND deleted_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_ours.inbound_batch_id; END IF;
        IF EXISTS (SELECT 1 FROM assay_disputes d WHERE d.inbound_batch_id = v_ours.inbound_batch_id AND d.status = 'open') THEN
            RAISE EXCEPTION 'ASSAY_DISPUTE_ALREADY_OPEN|%', v_bcode;
        END IF;
    ELSE
        SELECT code INTO v_bcode FROM output_batches WHERE id = v_ours.output_batch_id AND deleted_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_ours.output_batch_id; END IF;
        IF EXISTS (SELECT 1 FROM assay_disputes d WHERE d.output_batch_id = v_ours.output_batch_id AND d.status = 'open') THEN
            RAISE EXCEPTION 'ASSAY_DISPUTE_ALREADY_OPEN|%', v_bcode;
        END IF;
    END IF;

    IF p_sales_order_id IS NOT NULL THEN
        IF v_ours.output_batch_id IS NULL THEN
            RAISE EXCEPTION 'ASSAY_DISPUTE_SALES_ORDER_NEEDS_OUTPUT_BATCH';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM sales_orders WHERE id = p_sales_order_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SO_NOT_FOUND|%', p_sales_order_id;
        END IF;
        SELECT t.settlement_terms INTO v_st FROM contract_document_terms t WHERE t.sales_order_id = p_sales_order_id;
        v_limit := (v_st ->> 'splitting_limit_pct')::numeric;
        v_rule := v_st ->> 'arbitration_fee_rule';
    END IF;

    INSERT INTO assay_disputes (id, inbound_batch_id, output_batch_id, our_assay_id, counterparty_assay_id, sales_order_id,
                                status, opening_reason, limit_pct_at, fee_rule_at, created_by, updated_by)
    VALUES (v_id, v_ours.inbound_batch_id, v_ours.output_batch_id, p_our_assay_id, p_counterparty_assay_id, p_sales_order_id,
            'open', v_reason, v_limit, v_rule, v_user, v_user);

    RETURN jsonb_build_object('dispute_id', v_id, 'batch_code', v_bcode, 'limit_pct_at', v_limit, 'fee_rule_at', v_rule);
END;
$function$;

-- db/functions/record_dispute_umpire.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q16,Tim):【记下一件开着的争议的仲裁样品与仲裁结果】—— module.quality.edit。
--   两样都可选、至少给一样(ASSAY_DISPUTE_UMPIRE_EMPTY);给了的那一样必须是同一批的(SAMPLE_NOT_FOR_BATCH / ASSAY_NOT_FOR_BATCH),
--   仲裁结果的出具方必须是 umpire(ASSAY_DISPUTE_PARTY_MISMATCH)。只对开着的争议(ASSAY_DISPUTE_NOT_OPEN);开着时可以改记。
--   记下它【不】结案、不应用任何东西 —— 结案是 resolve_assay_dispute。返回 {dispute_id}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.record_dispute_umpire(p_dispute_id uuid, p_umpire_sample_id uuid, p_umpire_assay_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_d  assay_disputes%ROWTYPE;
    v_s  samples%ROWTYPE;
    v_a  assay_results%ROWTYPE;
BEGIN
    PERFORM require_permission('module.quality.edit');
    SELECT * INTO v_d FROM assay_disputes WHERE id = p_dispute_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_FOUND|%', COALESCE(p_dispute_id::text, '?');
    END IF;
    IF v_d.status <> 'open' THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_OPEN|%', v_d.status;
    END IF;
    IF p_umpire_sample_id IS NULL AND p_umpire_assay_id IS NULL THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_UMPIRE_EMPTY';
    END IF;
    IF p_umpire_sample_id IS NOT NULL THEN
        SELECT * INTO v_s FROM samples WHERE id = p_umpire_sample_id;
        IF NOT FOUND OR v_s.inbound_batch_id IS DISTINCT FROM v_d.inbound_batch_id
           OR v_s.output_batch_id IS DISTINCT FROM v_d.output_batch_id THEN
            RAISE EXCEPTION 'SAMPLE_NOT_FOR_BATCH|%', COALESCE(v_s.code, p_umpire_sample_id::text);
        END IF;
    END IF;
    IF p_umpire_assay_id IS NOT NULL THEN
        SELECT * INTO v_a FROM assay_results WHERE id = p_umpire_assay_id AND deleted_at IS NULL;
        IF NOT FOUND OR v_a.inbound_batch_id IS DISTINCT FROM v_d.inbound_batch_id
           OR v_a.output_batch_id IS DISTINCT FROM v_d.output_batch_id THEN
            RAISE EXCEPTION 'ASSAY_NOT_FOR_BATCH|%', COALESCE(v_a.code, p_umpire_assay_id::text);
        END IF;
        IF v_a.result_party <> 'umpire' THEN
            RAISE EXCEPTION 'ASSAY_DISPUTE_PARTY_MISMATCH|%|%|umpire', v_a.code, v_a.result_party;
        END IF;
    END IF;

    UPDATE assay_disputes
       SET umpire_sample_id = COALESCE(p_umpire_sample_id, umpire_sample_id),
           umpire_assay_id = COALESCE(p_umpire_assay_id, umpire_assay_id),
           updated_at = now(), updated_by = auth.uid()
     WHERE id = p_dispute_id;
    RETURN jsonb_build_object('dispute_id', p_dispute_id);
END;
$function$;

-- db/functions/withdraw_assay_dispute.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q13 · Q16,Tim):【撤回一件开着的化验争议】—— module.quality.edit,理由必填。
--   撤回之后挡着的那几处(应用、试算、化验来源的定价过账、卖方结算)放开;什么都不应用。返回 {dispute_id, status}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.withdraw_assay_dispute(p_dispute_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
    v_d      assay_disputes%ROWTYPE;
BEGIN
    PERFORM require_permission('module.quality.edit');
    SELECT * INTO v_d FROM assay_disputes WHERE id = p_dispute_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_FOUND|%', COALESCE(p_dispute_id::text, '?');
    END IF;
    IF v_d.status <> 'open' THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_OPEN|%', v_d.status;
    END IF;
    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_REASON_REQUIRED';
    END IF;
    UPDATE assay_disputes
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(), withdraw_reason = v_reason,
           updated_at = now(), updated_by = auth.uid()
     WHERE id = p_dispute_id;
    RETURN jsonb_build_object('dispute_id', p_dispute_id, 'status', 'withdrawn');
END;
$function$;

-- db/functions/resolve_assay_dispute.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q13 · Q19,Tim):【结案:点名哪一份说了算】—— action.apply_assay(今天应用化验的人;
--   结案预先替他做了那个选择,所以是他的码,不是质量的编辑码)。说明必填。说了算的那一份:同一批的任何一份没删的结果
--   (我们的、对手方的、或仲裁的;ASSAY_NOT_FOR_BATCH)。
--   ★ 它【什么都不应用】(Q19):挡着的那几处放开,说了算的那一份照常经 apply_assay_result → CFO 批的定价申请(进料),
--   或 apply_output_assay / 结算(产出)。没有自动的取平均、各让一半 —— 没有人给过那条规矩。返回 {dispute_id, status, governing_assay_code}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.resolve_assay_dispute(p_dispute_id uuid, p_governing_assay_id uuid, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_note text := NULLIF(btrim(COALESCE(p_note, '')), '');
    v_d    assay_disputes%ROWTYPE;
    v_a    assay_results%ROWTYPE;
BEGIN
    PERFORM require_permission('action.apply_assay');
    SELECT * INTO v_d FROM assay_disputes WHERE id = p_dispute_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_FOUND|%', COALESCE(p_dispute_id::text, '?');
    END IF;
    IF v_d.status <> 'open' THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_OPEN|%', v_d.status;
    END IF;
    IF v_note IS NULL THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOTE_REQUIRED';
    END IF;
    SELECT * INTO v_a FROM assay_results WHERE id = p_governing_assay_id AND deleted_at IS NULL;
    IF NOT FOUND OR v_a.inbound_batch_id IS DISTINCT FROM v_d.inbound_batch_id
       OR v_a.output_batch_id IS DISTINCT FROM v_d.output_batch_id THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOR_BATCH|%', COALESCE(v_a.code, COALESCE(p_governing_assay_id::text, '?'));
    END IF;
    UPDATE assay_disputes
       SET status = 'resolved', governing_assay_id = p_governing_assay_id, resolution_note = v_note,
           resolved_at = now(), resolved_by = auth.uid(), updated_at = now(), updated_by = auth.uid()
     WHERE id = p_dispute_id;
    RETURN jsonb_build_object('dispute_id', p_dispute_id, 'status', 'resolved', 'governing_assay_code', v_a.code);
END;
$function$;

-- db/functions/link_dispute_fee.sql
-- MES-6a-1(2026-10-09,MES-0 Q63 · Q64;MES-6a Step 0 Q22 · Q23,Tim):【把仲裁费那一张费用单挂到争议上】—— module.quality.edit。
--   仲裁费是一张【普通】费用单(财务照常经 record_expense 记,未付),付给出仲裁结果的那家实验室在供应商表里的那一户:
--   争议必须已记下仲裁结果(ASSAY_DISPUTE_FEE_NO_UMPIRE_ASSAY),那份结果的实验室必须指着一户供应商
--   (ASSAY_DISPUTE_FEE_LAB_HAS_NO_SUPPLIER —— 在字典编辑器里指,module.materials.edit),费用单的供应商必须就是那一户
--   (ASSAY_DISPUTE_FEE_SUPPLIER_MISMATCH),费用单必须在册(EXPENSE_NOT_POSTED)。一件争议只挂一张(ASSAY_DISPUTE_FEE_ALREADY_LINKED);
--   撤回的争议不挂(ASSAY_DISPUTE_WITHDRAWN)。
--   挂上不付钱:付那张费用单照常走付款申请,而那户供应商没批准时付款申请按名拒(PAYMENT_REQUEST_SUPPLIER_BLOCKED)。
--   对手方该担的那一份只算出来给人看(assay_dispute_rows),不收。返回 {dispute_id, fee_expense_code}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.link_dispute_fee(p_dispute_id uuid, p_expense_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_d    assay_disputes%ROWTYPE;
    v_lab  text;
    v_sup  uuid;
    v_exp  expenses%ROWTYPE;
BEGIN
    PERFORM require_permission('module.quality.edit');
    SELECT * INTO v_d FROM assay_disputes WHERE id = p_dispute_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_FOUND|%', COALESCE(p_dispute_id::text, '?');
    END IF;
    IF v_d.status = 'withdrawn' THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_WITHDRAWN';
    END IF;
    IF v_d.fee_expense_id IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_FEE_ALREADY_LINKED|%', (SELECT code FROM expenses WHERE id = v_d.fee_expense_id);
    END IF;
    IF v_d.umpire_assay_id IS NULL THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_FEE_NO_UMPIRE_ASSAY';
    END IF;
    SELECT a.lab_name INTO v_lab FROM assay_results a WHERE a.id = v_d.umpire_assay_id;
    SELECT l.supplier_id INTO v_sup FROM laboratories l WHERE l.code = v_lab;
    IF v_sup IS NULL THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_FEE_LAB_HAS_NO_SUPPLIER|%', COALESCE(v_lab, '?');
    END IF;
    SELECT * INTO v_exp FROM expenses WHERE id = p_expense_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', COALESCE(p_expense_id::text, '?');
    END IF;
    IF v_exp.status <> 'posted' OR v_exp.reversed_by_expense IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_NOT_POSTED|%', v_exp.code;
    END IF;
    IF v_exp.supplier_id IS DISTINCT FROM v_sup THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_FEE_SUPPLIER_MISMATCH|%|%', v_exp.code, v_lab;
    END IF;
    UPDATE assay_disputes SET fee_expense_id = p_expense_id, updated_at = now(), updated_by = auth.uid() WHERE id = p_dispute_id;
    RETURN jsonb_build_object('dispute_id', p_dispute_id, 'fee_expense_code', v_exp.code);
END;
$function$;

-- db/functions/guard_assay_sample_batch.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q9,Tim):一份化验指着的样品必须挂在同一批上 —— SAMPLE_NOT_FOR_BATCH。
--   record_assay_result 先按名拒;这一道守着 assay_results 上的直连写(进料 / 产出编辑码持有人有写策略)。
--   DEFINER:按属主身份读 samples —— 一个看不见那份样品的写入者不该把"不是这一批的"读成"不存在"(OPS-14)。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.guard_assay_sample_batch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s record;
BEGIN
    IF NEW.sample_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT s.code, s.inbound_batch_id, s.output_batch_id INTO v_s FROM samples s WHERE s.id = NEW.sample_id;
    IF NOT FOUND OR v_s.inbound_batch_id IS DISTINCT FROM NEW.inbound_batch_id
       OR v_s.output_batch_id IS DISTINCT FROM NEW.output_batch_id THEN
        RAISE EXCEPTION 'SAMPLE_NOT_FOR_BATCH|%', COALESCE(v_s.code, NEW.sample_id::text);
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 5 · 换掉的函数 ──────────────────────────────────────────────────────────────
-- 5a · 费用单的行守卫(与 db/tables/expenses.sql 里那一份逐字同一份):posted → reversed 那一步要理由
CREATE OR REPLACE FUNCTION public.guard_expense_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    IF NEW.id                  IS DISTINCT FROM OLD.id
       OR NEW.code                IS DISTINCT FROM OLD.code
       OR NEW.expense_date        IS DISTINCT FROM OLD.expense_date
       OR NEW.account_code        IS DISTINCT FROM OLD.account_code
       OR NEW.amount_ccy          IS DISTINCT FROM OLD.amount_ccy
       OR NEW.currency            IS DISTINCT FROM OLD.currency
       OR NEW.fx_rate             IS DISTINCT FROM OLD.fx_rate
       OR NEW.amount_base          IS DISTINCT FROM OLD.amount_base
       OR NEW.payment_status      IS DISTINCT FROM OLD.payment_status
       OR NEW.bank_account_code   IS DISTINCT FROM OLD.bank_account_code
       OR NEW.supplier_id         IS DISTINCT FROM OLD.supplier_id
       -- PAYEE-1a fu1:往来对象的另一半,补进这份清单是为了【让清单完整】。
       -- 注意:即使少了这一行,下面那句"只放行 过账→冲销"的兜底也会拒掉
       -- 任何别的 UPDATE(实测过)—— 所以这不是在补洞,是在让这份
       -- 声称完整的枚举名副其实。两道闸各自独立,兜底放宽时清单就是唯一那道。
       OR NEW.employee_id         IS DISTINCT FROM OLD.employee_id
       OR NEW.payee_name          IS DISTINCT FROM OLD.payee_name
       OR NEW.notes               IS DISTINCT FROM OLD.notes
       OR NEW.journal_entry_id    IS DISTINCT FROM OLD.journal_entry_id
       OR NEW.created_at          IS DISTINCT FROM OLD.created_at
       OR NEW.created_by          IS DISTINCT FROM OLD.created_by
    THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    IF NOT (OLD.status = 'posted' AND NEW.status = 'reversed'
            AND OLD.reversed_by_expense IS NULL AND NEW.reversed_by_expense IS NOT NULL) THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    -- ★ MES-6a-1(2026-10-09,F3 · MES-6a Step 0 Q33 · Q34,Tim):冲销的理由、时刻与人只在 posted → reversed 这一步写,
    --   理由不许是空的 —— 这一步之外它们改不了(上面那句已经拒掉了任何别的 UPDATE),而这一步里少了理由按名拒。
    --   表上的 expenses_reversal_shape 是第二道:posted 的行三列都空,reversed 的行理由与时刻都在。
    IF OLD.reversal_reason IS NOT NULL OR OLD.reversed_at IS NOT NULL OR OLD.reversed_by IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    IF NEW.reversal_reason IS NULL OR btrim(NEW.reversal_reason) = '' OR NEW.reversed_at IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_REVERSAL_REASON_REQUIRED|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

-- 5b · record_assay_result 尾部多一个 p_sample_id(带默认)—— 签名变了,先 DROP 旧的再建(PROC-6 的先例);旧的具名调用照旧走得通
DROP FUNCTION public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text);

CREATE OR REPLACE FUNCTION public.record_assay_result(
    p_assay_date date,
    p_metals jsonb,
    p_lab_name text DEFAULT NULL::text,
    p_certificate_ref text DEFAULT NULL::text,
    p_sample_ref text DEFAULT NULL::text,
    p_is_final boolean DEFAULT true,
    p_notes text DEFAULT NULL::text,
    p_inbound_batch_id uuid DEFAULT NULL::uuid,
    p_output_batch_id uuid DEFAULT NULL::uuid,
    -- ── PROC-6 追加(尾部,带默认,与 PROC-2c 的做法一致)────────────────────
    -- 【两个都默认 NULL,而"必填"由别处执行】
    --   weight_basis  → 触发器(旧行补不出来,所以只管新行)
    --   result_party  → 本函数里具名拒绝 + 列上 NOT NULL 兜底
    -- 这里【不】给业务默认值:默认会让"忘了填"静静变成一个可以拿去算钱的答案。
    p_weight_basis text DEFAULT NULL::text,
    p_moisture_pct numeric DEFAULT NULL::numeric,
    p_result_party text DEFAULT NULL::text,
    -- ── MES-6a-1 追加(2026-10-09,Step 0 Q9):这份结果化验的是哪一份实物样品 —— 尾部、带默认,今天的调用照旧走得通 ──
    --   样品必须挂在同一批上(SAMPLE_NOT_FOR_BATCH);可空,sample_ref 那段自由文本照旧。
    p_sample_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_id    uuid := gen_random_uuid();
    v_code  text;
    v_el    jsonb;
    v_metal text;
    v_pct   numeric;
    v_seen  text[] := ARRAY[]::text[];
    v_count integer := 0;
BEGIN
    -- PROC-1:两个父【二选一】。记录、编号、取代共享一张表一条序列;
    -- 权限跟着父走 —— 进料化验挂 inbound 模块,产出化验挂 output 模块。
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'ASSAY_ONE_PARENT';
    END IF;
    IF p_inbound_batch_id IS NOT NULL THEN
        PERFORM require_permission('module.inbound.edit');
        IF NOT EXISTS (
            SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
        END IF;
    ELSE
        PERFORM require_permission('module.output.edit');
        IF NOT EXISTS (
            SELECT 1 FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
        END IF;
    END IF;
    IF p_assay_date IS NULL OR p_assay_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ASSAY_DATE_INVALID|%', COALESCE(p_assay_date::text, '?');
    END IF;
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    -- PROC-6:出具方必须明说。**在这里具名拒绝,而不是等列上的 NOT NULL 抛机器话** ——
    -- 一个具名码翻得成人话,一个 null-value violation 翻不成。
    IF p_result_party IS NULL THEN
        RAISE EXCEPTION 'ASSAY_RESULT_PARTY_REQUIRED'
          USING HINT = '这一份结果是我们出的、对手方出的、还是仲裁实验室出的?没有默认值 —— 默认会让"忘了改"变成"这是我们测的"。';
    END IF;

    -- MES-6a-1(Q9):样品必须是同一批的 —— 在这里按名拒,而不是等表上的守卫抛(两道,同一句话)
    IF p_sample_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM samples s WHERE s.id = p_sample_id
           AND s.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
           AND s.output_batch_id IS NOT DISTINCT FROM p_output_batch_id) THEN
        RAISE EXCEPTION 'SAMPLE_NOT_FOR_BATCH|%', COALESCE((SELECT code FROM samples WHERE id = p_sample_id), p_sample_id::text);
    END IF;

    v_code := next_assay_code(p_assay_date);
    INSERT INTO assay_results (id, code, inbound_batch_id, output_batch_id, assay_date, lab_name,
                               certificate_ref, sample_ref, is_final, notes,
                               weight_basis, moisture_pct, result_party, sample_id,
                               created_by, updated_by)
    VALUES (v_id, v_code, p_inbound_batch_id, p_output_batch_id, p_assay_date, p_lab_name,
            p_certificate_ref, p_sample_ref, p_is_final, p_notes,
            p_weight_basis, p_moisture_pct, p_result_party, p_sample_id,
            v_user, v_user);

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        -- 【PROC-6 顺手修的一处 PROC-4 漏网】这里原本写着
        --     v_metal NOT IN ('ni','co','li','mn','cu','al','fe')
        -- —— **那是那份金属清单的第九个副本**,而 PROC-4 声称已经清干净了。
        -- 它没有:PROC-4 的 S1 只查了 pg_constraint,【没有查函数体】。
        -- 线上实测函数体里还有四份(见 docs/known-issues.md),本刀只修它正在
        -- 重建的这一支 —— 另外三支按名排期,不在这一刀里顺手动。
        -- 现在它读字典,于是"加一种物质"真的只要一行。
        IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances WHERE code = v_metal) THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;
        v_pct := (v_el->>'content_pct')::numeric;
        IF v_pct IS NULL OR v_pct < 0 OR v_pct > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;
        INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
        VALUES (v_id, v_metal, v_pct);
        v_count := v_count + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'assay_result_id', v_id,
        'code', v_code,
        'metal_count', v_count
    );
END;
$function$

;

-- 5c · 同签名替换(镜像原样):争议的挡 · D4 · 结算的拒 · F3 的两条路与内层 · 审计主语登记

CREATE OR REPLACE FUNCTION public.apply_assay_result(p_assay_result_id uuid, p_pricing_formula_id uuid DEFAULT NULL::uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_assay    record;
    v_batch    record;
    v_commit   uuid;
    v_csrc     uuid;
    v_ccode    text;
    v_live     uuid;
    v_formula  uuid;
    v_fcode    text;
    v_metals   jsonb;
    v_calc     jsonb;
    v_unit     numeric;
    v_rep      jsonb := NULL;
    v_priced   boolean := false;
    v_status   text;
    v_prior    uuid;
    v_note     text := NULL;
    v_open     receipt_price_requests%ROWTYPE;
    v_disp     uuid;
BEGIN
    PERFORM require_permission('action.apply_assay');
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    -- PROC-1:产出化验不走这条路 —— 这里的第 2-5 步全是围着应付转的,
    -- 而产出批没有应付。拆函数,不在函数里藏 IF。
    IF v_assay.output_batch_id IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_IS_OUTPUT|%', v_assay.code;
    END IF;
    IF v_assay.applied_at IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
    END IF;

    SELECT * INTO v_batch FROM inbound_batches
    WHERE id = v_assay.inbound_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_assay.inbound_batch_id;
    END IF;

    -- 0a. ★ MES-6a-1(MES-0 Q62 · MES-6a Step 0 Q18,Tim):这一批挂着一件【开着的】化验争议时,应用任何一份化验都按名拒 ——
    --     争议没结,"哪一份说了算"就还没定,而应用正是在替人做那个选择。放在批次锁之后、任何改动之前;
    --     preview_assay_price 用同一句拒(fixture 40 的那条规矩:试算拒的地方提交也拒)。结案或撤回之后放开。
    SELECT d.id INTO v_disp FROM assay_disputes d WHERE d.inbound_batch_id = v_batch.id AND d.status = 'open';
    IF FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_OPEN|%|%', v_batch.code, v_disp
          USING HINT = '这一批有一件开着的化验争议 —— 先在争议页上结案(点名哪一份说了算)或撤回,再应用';
    END IF;

    -- 0. ★ ROLE-1 Batch 4b(Tim 的 Q3 · Q5 · Q6):这张收货挂着一张在等 CFO 的定价申请时 ——
    --    · 来源不是化验(手工 / 按承诺条款 / 收货台):应用按名拒 RECEIPT_PRICE_REQUEST_OPEN,
    --      一个等着批的手工价不许被一份化验从脚下换掉含量;
    --    · 来源是化验:本次取代它 —— 先撤回那一张(理由写明被哪一份取代),本次再提自己的。
    --    放在改含量【之前】:含量守卫(guard_inbound_batch_metals_price_request)在有在等的申请时拒一切写。
    SELECT * INTO v_open FROM receipt_price_requests
     WHERE inbound_batch_id = v_batch.id AND status = 'submitted';
    IF FOUND THEN
        IF v_open.source <> 'assay' THEN
            RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_OPEN|%|%', v_batch.code, v_open.label;
        END IF;
        PERFORM receipt_price_withdraw_internal(v_open.id,
            'Superseded by assay ' || v_assay.code || ' applied');
    END IF;

    -- 1. 批次含量 = 本化验的含量(删后重插)。分摊、估值、回收率读的都是
    --    inbound_batch_metals —— 它必须始终是"当前最可信的真相";化验行本身留作历史。
    --    PROC-1:抄进的行带出处 —— content_source='assay',指回这份单据。
    DELETE FROM inbound_batch_metals WHERE inbound_batch_id = v_batch.id;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct,
                                      content_source, source_assay_id, created_by, updated_by)
    SELECT v_batch.id, arm.metal, arm.content_pct, 'assay', p_assay_result_id, v_user, v_user
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    SELECT jsonb_agg(jsonb_build_object('metal', arm.metal, 'content_pct', arm.content_pct))
    INTO v_metals
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    -- 2. 【结算条款 = 承诺时抄下的副本】(FIN-27)。解析次序与从前解析公式同构:
    --    批次自己的承诺 → 它那条采购行的承诺。活公式在这里【一次都不读】。
    v_commit := resolve_pricing_commitment(v_batch.id);

    IF p_pricing_formula_id IS NOT NULL THEN
        -- 结算时才指名公式(无采购单的现场收货):那一刻【就是】承诺时刻,现在抄。
        -- 已经有副本了就不许被顶掉 —— 副本一旦落下,它就是记录。
        IF v_commit IS NULL THEN
            v_commit := commit_pricing_terms(p_pricing_formula_id, NULL, v_batch.id);
        ELSE
            SELECT c.source_formula_id, c.source_formula_code INTO v_csrc, v_ccode
            FROM pricing_term_commitments c WHERE c.id = v_commit;
            IF v_csrc IS DISTINCT FROM p_pricing_formula_id THEN
                RAISE EXCEPTION 'PRICING_TERMS_ALREADY_COMMITTED|%|%', v_batch.code, v_ccode;
            END IF;
        END IF;
    END IF;

    IF v_commit IS NOT NULL THEN
        -- 3. 与计价器同一份算术(calculate_metal_price_from_terms),条款来自副本;
        --    再走与手工计价【同一条】重计价路径(reprice_inbound_batch)—— 价差分录、
        --    price_history、1200/5000 拆账三件事只存在一份实现。
        --    参考日默认化验日:结算价随行情,行情看化验那天。
        SELECT c.source_formula_id, c.source_formula_code INTO v_formula, v_fcode
        FROM pricing_term_commitments c WHERE c.id = v_commit;

        v_calc := calculate_metal_price_from_terms(
            pricing_terms_of_commitment(v_commit), v_metals, v_batch.quantity,
            COALESCE(p_reference_date, v_assay.assay_date));
        v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;

        IF v_unit > 0 THEN
            -- ★ ROLE-1 Batch 4b:算出来的价不再当场过账 —— 在第 7 步提一张申请(来源 assay),
            --   等本次的含量、取代链与 applied_at 都落定之后(指纹要看见"它就是最近一份已应用的化验")。
            v_priced := true;
        ELSE
            -- 低品位料可能"不值它的处理费"(净值 ≤ 0)。负价不入价格机器 ——
            -- 含量照常落地,价格留给人决断。
            v_note := 'computed price not positive: ' || COALESCE(v_unit::text, '?');
        END IF;
    ELSE
        -- 4. 没有副本。有活公式引用【却没有副本】= FIN-27 之前留下的承诺,当时没记
        --    条款 —— 点名拒。悄悄退回去读活公式正是本切要拆掉的行为,而把今天的
        --    公式当成当时谈定的条款,是编造一份承诺(D:不回填)。
        --    完全没有公式引用的批次照旧:手工定价的采购本来就由人定价,不是错误。
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        IF v_live IS NOT NULL THEN
            RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
                COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
        END IF;
        v_note := 'no pricing formula resolved';
    END IF;

    -- 5. 批次挂上这张公式。★ ROLE-1 Batch 4b(Tim 的 Q3):pricing_status 【不在这里】升 final ——
    --    只在 CFO 批准本次提的那张申请时(receipt_price_post_internal),而且只当这份化验 is_final。
    UPDATE inbound_batches
    SET pricing_formula_id = COALESCE(v_formula, pricing_formula_id),
        updated_by = v_user
    WHERE id = v_batch.id;

    -- 6. 取代链:此前已执行且未被取代的化验,superseded_by 指向本次
    -- code 作平局裁决:applied_at 在同一事务里可能相同(now() 冻结),
    -- 而编号无缝且单调 —— 排序必须确定
    -- ★ MES-6a-1(D4 · Step 0 Q20):只取代【同一出具方】的上一份 —— 应用一份对手方或仲裁的结果【不】把我们的那一份标成
    --   superseded(assay_results.superseded_by 的列注释:"对手方的结果不是对我们结果的取代")。此前这里不看出具方,
    --   一旦有人应用对手方的结果就会静静地盖掉我们自己测到的东西(今天线上从没应用过一份非 ours 的进料化验,所以它从没开过火)。
    SELECT id INTO v_prior FROM assay_results
    WHERE inbound_batch_id = v_batch.id AND id <> p_assay_result_id
      AND result_party = v_assay.result_party
      AND applied_at IS NOT NULL AND superseded_by IS NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_prior IS NOT NULL THEN
        UPDATE assay_results SET superseded_by = p_assay_result_id, updated_by = v_user
        WHERE id = v_prior;
    END IF;

    UPDATE assay_results
    SET applied_at = now(), applied_by = v_user, updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 7. ★ ROLE-1 Batch 4b(Tim 的 Q3):同一事务里提一张定价申请,来源 assay,提单人 = 按应用的这个人。
    --    提交时照批准那一刻的同一支过账试跑;二级除了提单人再没有别人批得动 → 整次应用按名拒
    --    (RECEIPT_PRICE_NO_OTHER_DECIDER,Tim 的 Q1)。审批关着时当场过账,is_final 时同时升 final。
    IF v_priced THEN
        v_rep := receipt_price_submit_internal(v_batch.id, v_unit, 'USD', 'assay', p_assay_result_id,
                                               v_commit, 'Assay ' || v_assay.code || ' applied');
    END IF;
    SELECT pricing_status INTO v_status FROM inbound_batches WHERE id = v_batch.id;

    -- 完整分解:界面展示的、向供应商/审计师解释调整的,就是这一份 —— 每个数都留
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        -- ★ ROLE-1 Batch 4b:priced = 这一次【已经过了账】(只在审批关着时);
        --   price_requested = 提了一张定价申请,它的编号与状态在 price_request 里。
        'priced', COALESCE(v_rep->>'status' = 'approved', false),
        'price_requested', v_priced,
        'price_request', v_rep,
        'superseded_request_id', v_open.id,
        'formula_code', v_fcode,
        -- FIN-27:结算按【哪一份承诺】算的 —— 供应商问起来要指得出那份副本
        'commitment_id', v_commit,
        'old_unit_price', v_rep->'old_unit_price',
        'new_unit_price', v_rep->'new_unit_price',
        'price_delta_usd', v_rep->'price_delta_usd',
        'in_stock_ratio', v_rep->'in_stock_ratio',
        'inventory_share_usd', v_rep->'inventory_share_usd',
        'cost_share_usd', v_rep->'cost_share_usd',
        'journal_code', v_rep->'journal_code',
        'pricing_status', v_status,
        'note', v_note
    );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.apply_output_assay(p_assay_result_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_assay record;
    v_batch record;
    v_prior uuid;
    v_count integer;
    v_run   record;
BEGIN
    PERFORM require_permission('action.apply_assay');
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    -- 进料化验不走这条路:它的应用【就是】重算应付,少了那一半不叫应用。
    IF v_assay.output_batch_id IS NULL THEN
        RAISE EXCEPTION 'ASSAY_IS_INBOUND|%', v_assay.code;
    END IF;
    IF v_assay.applied_at IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
    END IF;

    SELECT * INTO v_batch FROM output_batches
    WHERE id = v_assay.output_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_assay.output_batch_id;
    END IF;

    -- 批次含量 = 本化验的含量(删后重插,同进料侧)。行带出处;updated_at/created_at
    -- 因此更新 —— 过期视图的第六个来源读的就是它,这一写【就是】举旗动作本身。
    DELETE FROM output_batch_metals WHERE output_batch_id = v_batch.id;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct,
                                     content_source, source_assay_id, created_by, updated_by)
    SELECT v_batch.id, arm.metal, arm.content_pct, 'assay', p_assay_result_id, v_user, v_user
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    -- 取代链:与进料侧同一条规则,按【产出批】成链(进料链与产出链互不相扰)
    -- ★ MES-6a-1(D4 · Step 0 Q20):与进料侧同一条修正 —— 只取代【同一出具方】的上一份;应用对手方或仲裁的结果不盖掉我们的。
    SELECT id INTO v_prior FROM assay_results
    WHERE output_batch_id = v_batch.id AND id <> p_assay_result_id
      AND result_party = v_assay.result_party
      AND applied_at IS NOT NULL AND superseded_by IS NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_prior IS NOT NULL THEN
        UPDATE assay_results SET superseded_by = p_assay_result_id, updated_by = v_user
        WHERE id = v_prior;
    END IF;

    UPDATE assay_results
    SET applied_at = now(), applied_by = v_user, updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 产出它的那张加工单:若已分摊,这次应用让 metal_value 拆分过期(过期视图
    -- 自己会说;这里把"哪张单、有没有分摊过"报出来,界面不用再拼)。
    SELECT r.id, r.code, r.allocated_at INTO v_run
    FROM processing_outputs po
    JOIN processing_runs r ON r.id = po.run_id AND r.deleted_at IS NULL
    WHERE po.output_batch_id = v_batch.id
    LIMIT 1;

    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'output_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'metal_count', v_count,
        'superseded_prior', v_prior IS NOT NULL,
        'producing_run_code', v_run.code,
        'producing_run_allocated_at', v_run.allocated_at,
        'allocation_now_stale', v_run.allocated_at IS NOT NULL
    );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.preview_assay_price(p_inbound_batch_id uuid, p_metals jsonb, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch  record;
    v_commit uuid;
    v_live   uuid;
    v_calc   jsonb;
    v_unit   numeric;
    v_impact jsonb := NULL;
    v_disp   uuid;
BEGIN
    PERFORM require_permission('action.apply_assay');
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;

    SELECT id, code, quantity, pricing_formula_id, purchase_order_line_id
    INTO v_batch FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    -- ★ MES-6a-1(MES-6a Step 0 Q18):与 apply_assay_result 同一句拒 —— 这一批挂着一件开着的化验争议(fixture 40 F 臂:两侧同一个码)
    SELECT d.id INTO v_disp FROM assay_disputes d WHERE d.inbound_batch_id = v_batch.id AND d.status = 'open';
    IF FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_OPEN|%|%', v_batch.code, v_disp
          USING HINT = '这一批有一件开着的化验争议 —— 先在争议页上结案(点名哪一份说了算)或撤回,再应用';
    END IF;

    v_commit := resolve_pricing_commitment(v_batch.id);
    IF v_commit IS NULL THEN
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        IF v_live IS NOT NULL THEN
            RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
                COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
        END IF;
        RETURN jsonb_build_object('calc', NULL, 'impact', NULL);
    END IF;

    v_calc := calculate_metal_price_from_terms(
        pricing_terms_of_commitment(v_commit), p_metals, v_batch.quantity, p_reference_date);
    v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;
    -- 净值 ≤ 0 时不试算:apply_assay_result 那时也不定价(落含量、记 note),
    -- 【这是警告不是拒绝】—— 页面的琥珀提示照旧,按钮保持可用。
    IF v_unit > 0 THEN
        -- 计价口径是 USD/kg(行情与处理费都按 USD/吨),提交也是按 USD 递给
        -- reprice_inbound_batch 的 —— 币种在这里说出来,两边才对得上。
        v_impact := preview_reprice_inbound_batch(p_inbound_batch_id, v_unit, 'USD');
    END IF;
    RETURN jsonb_build_object('calc', v_calc, 'impact', v_impact);
END;
$function$;

-- db/functions/receipt_price_post_internal.sql
-- ROLE-1 Batch 4b(2026-09-25):把一张定价申请【过账】—— 批准那一刻(或审批关着时提交那一刻)跑的
-- 那一支,也是试跑(receipt_price_request_dry_run)跑的同一支。
--
--   1. 引擎 reprice_inbound_batch:原币单价 × 【今天】的 tt_sell(Tim 的 Q2:过账记在批准日、按那天的
--      牌价)→ unit_price、price_history、purchase 分录(1200 / 5000 / Cr 2000)。引擎自己再问一次
--      data.view_purchase_prices —— 问的是按下去的那个人(批准时是 CFO)。
--   2. 化验来源、而且那份化验是 is_final → 收货的 pricing_status 升为 final(Tim 的 Q3:只在批准时)。
--      pricing_status 的直连写由 guard_inbound_batch_price_request 拒;本支是属主路径。
--   0. ★ MES-6a-1:来源是化验、而那一批挂着一件开着的化验争议 → 按名拒 ASSAY_DISPUTE_OPEN(Q18;手工与按条款的照常)。
--   3. 按已承诺条款改价 → 收货还没挂公式时,记下承诺副本的来源公式(原 reprice_from_committed_terms
--      落账后做的那一步,挪到真正落账的这一刻)。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_price_post_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r       receipt_price_requests%ROWTYPE;
    v_rep     jsonb;
    v_formula uuid;
    v_disp    uuid;
BEGIN
    SELECT * INTO v_r FROM receipt_price_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;

    -- ★ MES-6a-1(MES-0 Q62 · MES-6a Step 0 Q18,Tim):一张【来源是化验】的申请,在那一批挂着一件开着的化验争议时不过账 ——
    --   申请的指纹(receipt_price_fingerprint)里没有争议这一项,所以一张在争议立起来之前就在等的化验申请,
    --   批准那一刻要在这里再看一次。手工、按已承诺条款、收货台带价的申请照常(一个暂定价不是 Q62 说的"最终改价")。
    --   试跑(receipt_price_request_dry_run)跑的是同一支,所以它在同一处拒。
    IF v_r.source = 'assay' THEN
        SELECT d.id INTO v_disp FROM assay_disputes d WHERE d.inbound_batch_id = v_r.inbound_batch_id AND d.status = 'open';
        IF FOUND THEN
            RAISE EXCEPTION 'ASSAY_DISPUTE_OPEN|%|%', (SELECT code FROM inbound_batches WHERE id = v_r.inbound_batch_id), v_disp
              USING HINT = '这一批有一件开着的化验争议 —— 来源是化验的定价申请要等争议结案或撤回才过得了账';
        END IF;
    END IF;

    v_rep := reprice_inbound_batch(v_r.inbound_batch_id, v_r.unit_price_ccy, v_r.currency, NULL,
                                   concat_ws(' · ', 'Price request ' || v_r.label, v_r.notes));

    IF v_r.source = 'assay'
       AND (SELECT a.is_final FROM assay_results a WHERE a.id = v_r.assay_result_id) THEN
        UPDATE inbound_batches SET pricing_status = 'final', updated_by = auth.uid()
         WHERE id = v_r.inbound_batch_id AND pricing_status <> 'final';
    END IF;

    IF v_r.source = 'committed_terms' AND v_r.commitment_id IS NOT NULL THEN
        SELECT c.source_formula_id INTO v_formula
          FROM pricing_term_commitments c WHERE c.id = v_r.commitment_id;
        IF v_formula IS NOT NULL THEN
            UPDATE inbound_batches SET pricing_formula_id = v_formula, updated_by = auth.uid()
             WHERE id = v_r.inbound_batch_id AND pricing_formula_id IS NULL;
        END IF;
    END IF;

    RETURN v_rep;
END;
$function$
;

-- db/functions/sale_settlement_compute.sql
-- SETTLE-1:一次销售最终结算的算法。CLEANUP-A 加了第二道闸(module.output.view)——
-- 闸问的和身体读的从前不是同一条权限。它【今天拦不到任何人】,而那正是它的理由:
-- 角色改一次就会无声地重新打开它。
--
-- ★【TOOLS-1 ④(2026-09-03):两处基准换算搬进 convert_weight_basis /
--   convert_grade_basis】★ 函数体其余部分【一个字节没动】——
--   `pg_get_functiondef` 的 diff 就是那两行。理由与证据见那两支函数的抬头、
--   db/fixtures/187(新旧逐点比对)与 db/fixtures/149(结算那条路,提取后重跑通过)。

CREATE OR REPLACE FUNCTION public.sale_settlement_compute(p_sales_order_id uuid, p_output_batch_id uuid, p_assay_result_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- SETTLE-1:一次销售最终结算的**算法** —— 四条条款是**同一条公式**里的四项。
--
-- ★★【一处实现,两个调用者】★★ 本支只**算**,不写;record_sale_settlement 调它
--   再落一行。本仓库为"两份实现在写下来那天一致、之后悄悄分开"付过**四次**账
--   (AGENTS.md 那条预览规则),所以预览与落库读的是同一段算术。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【公式(index-pricing-spec §3),四条条款各占一项】
--     (结算重量 × 含量 × 计价系数) × 计价期均价      ← 重量基准 / PRICE-1 的条款
--   − 精炼费(按【含金属】吨数)                       ← contract_refining_charges
--   − 惩罚(按【结算重量】吨数,超阈值部分)           ← contract_penalty_elements
--   而"用谁的化验"决定了上面的**含量**从哪一行来       ← result_party / settling_party
--
-- ★★【为什么湿基与干基结算出【不同的钱】】★★
--   含金属是**不变量**(换算对了的话,湿基算与干基算得到同一个含量),
--   所以**金属价值与精炼费不随基准变**。变的是**惩罚** ——
--   它按**结算重量**收,而水是随货一起进来的。
--   于是同一批货按湿基结算比按干基**多罚**,而那是对的。
--   **这也正是 GO-3 那个"钱的错误"之所以是钱的错误。**
--
-- 拒绝(全部按名,全部双语):
--   SETTLEMENT_PERMISSION_DENIED|<code>        没有权限(而不是让 RLS 报成"数据缺了")
--   SO_NOT_FOUND / OUTPUT_BATCH_NOT_FOUND / ASSAY_NOT_FOUND
--   SETTLEMENT_NO_CONTRACT_TERMS|<so>          这张单没挂合同,没有可依据的冻结条款
--   SETTLEMENT_TERMS_NOT_SET|<contract>        挂了合同,但那份合同没有结算口径
--   ASSAY_NOT_FOR_BATCH|<assay>|<batch>        选的化验不是这个批次的
--   ★ ASSAY_DISPUTE_OPEN|<batch>|<争议>        这一批挂着一件开着的化验争议(MES-6a-1,Q21)
--   ★ ASSAY_WEIGHT_BASIS_NOT_STATED|<assay>    化验没说按哪种重量报 ← 本刀最要紧的那条
--   ASSAY_PARTY_NOT_THE_SETTLING_PARTY|…       选的化验不是合同约定的那一方(仲裁除外)
--   RESULTS_IN_DISPUTE|…                       两方结果不一致,而没有声明容差
--   RESULTS_EXCEED_SPLITTING_LIMIT|…           不一致超过了声明的容差 → 该走仲裁
--   SETTLEMENT_MOISTURE_NOT_STATED|<assay>     要换算基准却没有水分
--   SETTLEMENT_PAYABLE_NOT_STATED|<metal>      没有计价系数(PRICE-1 的条款)
--   SETTLEMENT_BASE_EVENT_DATE_UNKNOWN|<event> 基准事件的日期在卖方向还记不下来
--   REFINING_CHARGE_NOT_FILED|<contract>|<metal>   声明了按金属收,却没填那一行
--   PENALTY_ELEMENTS_NOT_FILED|<contract>          声明了按元素罚,却一行都没填
DECLARE
    v_st        jsonb;     -- 冻结的结算口径
    v_pricing   jsonb;     -- 冻结的计价条款(PRICE-1)
    v_terms     record;
    v_batch     record;
    v_assay     record;
    v_basis     text;
    v_gross     numeric;
    v_moist     numeric;
    v_swt       numeric;   -- 结算重量
    v_other     record;
    v_lim       numeric;
    v_maxdiff   numeric;
    v_el        jsonb;
    v_ccode     text;
    v_pt_event  text;
    v_pt_months integer;
    v_pt_index  text;
    v_metal     text;
    v_content   numeric;
    v_content_s numeric;
    v_contained numeric;
    v_payable   numeric;
    v_pay_kg    numeric;
    v_price     numeric;
    v_qp        record;
    v_rc        numeric;
    v_base_date date;
    v_lines     jsonb := '[]'::jsonb;
    v_pens      jsonb := '[]'::jsonb;
    v_mv        numeric := 0;
    v_rcs       numeric := 0;
    v_pen       numeric := 0;
    v_thr       numeric;
    v_rate      numeric;
    v_over      numeric;
    v_amt       numeric;
    v_disp      uuid;
BEGIN
    IF p_sales_order_id IS NULL OR p_output_batch_id IS NULL OR p_assay_result_id IS NULL THEN
        RAISE EXCEPTION 'SETTLEMENT_ARGUMENTS_REQUIRED';
    END IF;
    -- 【权限按名拒,不让 RLS 把行藏起来报成"数据缺了"】PRICE-1 的 fu1 是这一课,
    -- 这里一开始就写上,而不是等 fixture 再抓一次。
    IF NOT has_permission('module.customers.view'::text) THEN
        RAISE EXCEPTION 'SETTLEMENT_PERMISSION_DENIED|%', 'module.customers.view'
          USING HINT = '看得见销售结算要有客户模块的查看权限 —— 这不是数据缺失,是权限';
    END IF;
    -- ★【第二道闸(CLEANUP-A)—— 它今天【拦不到任何人】,而那正是它的理由】★
    -- 上面那道闸问的是 module.customers.view,而本支接下来要读的是
    -- output_batches / assay_results / assay_result_metals —— 这三张的 RLS
    -- 策略问的都是 module.output.view。**闸问的和身体读的不是同一条权限。**
    -- 本支是 SECURITY INVOKER,所以一个只有 customers.view 的读者会走过第一道闸,
    -- 然后【读到零行化验金属】,而金属循环一次都不执行 → metal_value = 0、
    -- refining_charge = 0 → **amount_usd 结算成 0.00,附一张空的 breakdown**。
    -- 那是一个不报错的、可以被当成"这批货不值钱"的数字。
    --
    -- 【实测:今天线上没有任何角色能走到那一步,而这不是不修的理由】
    -- 持 customers.view 的五个角色(admin/auditor/finance/gm/sales)【全部】
    -- 也持 output.view,所以今天这条路复现不了;线上 contract_document_terms
    -- 还是零行,4 张化验单全在进料侧,函数在金属循环之前就按名拒了。
    -- **但这道闸关的不是"现在错着",是"角色改一次就会无声地重新打开它"** ——
    -- 而重新打开的那一天,没有任何东西会响。所以它现在就该在这里。
    -- 【fixture 会构造一个只有 customers.view 的读者来钉住它;那不是线上缺陷的证据。】
    IF NOT has_permission('module.output.view'::text) THEN
        RAISE EXCEPTION 'SETTLEMENT_PERMISSION_DENIED|%', 'module.output.view'
          USING HINT = '结算要读产出批次与它的化验结果 —— 那要产出模块的查看权限。'
                       '没有它,化验金属会读成零行,而结算金额会算成 0.00:'
                       '一个不报错、看起来像"这批货不值钱"的数字。';
    END IF;

    -- ── 冻结的条款副本(【抄】,不回查合同现在怎么写)────────────────────────
    SELECT * INTO v_terms FROM contract_document_terms WHERE sales_order_id = p_sales_order_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SETTLEMENT_NO_CONTRACT_TERMS|%', p_sales_order_id
          USING HINT = '这张销售单没有挂在任何合同之下 —— 结算口径是合同条款,没有合同就没有口径';
    END IF;
    v_st := v_terms.settlement_terms;
    v_pricing := v_terms.pricing_terms;
    v_ccode := v_terms.contract_code;
    IF v_st IS NULL OR jsonb_typeof(v_st) <> 'object' OR v_st = '{}'::jsonb THEN
        RAISE EXCEPTION 'SETTLEMENT_TERMS_NOT_SET|%', v_ccode
          USING HINT = '这份合同没有结算口径(重量基准 / 谁的化验说了算 / 精炼费与惩罚的口径)—— 先在合同上写明,再重新挂接';
    END IF;

    SELECT * INTO v_batch FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'OUTPUT_BATCH_NOT_FOUND|%', p_output_batch_id; END IF;
    SELECT * INTO v_assay FROM assay_results WHERE id = p_assay_result_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', p_assay_result_id; END IF;
    IF v_assay.output_batch_id IS DISTINCT FROM p_output_batch_id THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOR_BATCH|%|%', v_assay.code, v_batch.code;
    END IF;

    -- ── ★ MES-6a-1(MES-6a Step 0 Q21,Tim):这一批挂着一件【开着的】化验争议时,结算按名拒 ───────────────
    -- 下面那两道推出来的拒绝(RESULTS_IN_DISPUTE / RESULTS_EXCEED_SPLITTING_LIMIT)一字未改:它们看的是两份数字,
    -- 这一道看的是一件被人立起来的争议 —— 立了就等它结案或撤回。本支是 INVOKER:assay_disputes 的读策略给
    -- module.output.view(上面第二道闸刚问过它),所以一个走得到这里的读者不会因为读不到而把它放过去(INVOKER-JOIN-5 那一族)。
    SELECT d.id INTO v_disp FROM assay_disputes d WHERE d.output_batch_id = p_output_batch_id AND d.status = 'open';
    IF FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_OPEN|%|%', v_batch.code, v_disp
          USING HINT = '这一批有一件开着的化验争议 —— 先结案(点名哪一份说了算)或撤回,再结算';
    END IF;

    -- ── ★ 化验必须说出它按哪种重量报 ★ ─────────────────────────────────────
    -- GO-3:一张按干基出的化验单被乘在湿重上,含金属被**高估**,而没有任何东西会响。
    -- **留空 = 没有人说过**,而不是"按惯例是干基" —— 所以这里拒,不猜。
    IF v_assay.weight_basis IS NULL THEN
        RAISE EXCEPTION 'ASSAY_WEIGHT_BASIS_NOT_STATED|%', v_assay.code
          USING HINT = '这份化验没有说明它按湿基还是干基报 —— 而两者会结算出不同的金额,所以不能猜';
    END IF;

    -- ── 谁的化验说了算 ────────────────────────────────────────────────────
    -- 仲裁结果【总是】可以结算:它是那条升级路径的终点。
    IF v_assay.result_party <> 'umpire'
       AND v_assay.result_party IS DISTINCT FROM (v_st->>'settling_party') THEN
        RAISE EXCEPTION 'ASSAY_PARTY_NOT_THE_SETTLING_PARTY|%|%|%',
            v_assay.code, v_assay.result_party, (v_st->>'settling_party');
    END IF;

    -- ── 两方结果不一致时,【系统不自己选】────────────────────────────────
    -- ★ 让系统按容差自动选,等于让系统**决定谁的数字是钱**;而容差为空时,
    --   它还得**编一个默认值**才做得到那件事。所以:指出,不选。
    IF v_assay.result_party <> 'umpire' THEN
        SELECT a.code, a.id INTO v_other
          FROM assay_results a
         WHERE a.output_batch_id = p_output_batch_id AND a.deleted_at IS NULL
           AND a.id <> p_assay_result_id
           AND a.result_party IN ('ours', 'counterparty')
           AND a.result_party <> v_assay.result_party
         ORDER BY a.assay_date DESC LIMIT 1;
        IF FOUND THEN
            v_lim := (v_st->>'splitting_limit_pct')::numeric;
            -- 逐元素比,取最大差
            SELECT max(abs(x.content_pct - y.content_pct)) INTO v_maxdiff
              FROM assay_result_metals x JOIN assay_result_metals y
                ON y.metal = x.metal AND y.assay_result_id = v_other.id
             WHERE x.assay_result_id = p_assay_result_id;
            IF v_maxdiff IS NOT NULL AND v_maxdiff > 0 THEN
                IF v_lim IS NULL THEN
                    RAISE EXCEPTION 'RESULTS_IN_DISPUTE|%|%|%', v_assay.code, v_other.code, v_maxdiff
                      USING HINT = '两方的化验结果不一致,而这份合同没有声明容差 —— 要么在合同里写明容差,要么记录一份仲裁结果并按它结算;系统不会替你选哪一方的数字是钱';
                ELSIF v_maxdiff > v_lim THEN
                    RAISE EXCEPTION 'RESULTS_EXCEED_SPLITTING_LIMIT|%|%|%|%', v_assay.code, v_other.code, v_maxdiff, v_lim
                      USING HINT = '两方结果的差距超过了合同声明的容差 —— 按合同该送第三方复检,并用仲裁结果结算';
                END IF;
            END IF;
        END IF;
    END IF;

    -- ── 重量基准:换算,或按名拒 ──────────────────────────────────────────
    v_basis := v_st->>'sale_weight_basis';
    v_gross := v_batch.quantity;
    v_moist := v_assay.moisture_pct;
    IF v_assay.weight_basis <> v_basis AND v_moist IS NULL THEN
        RAISE EXCEPTION 'SETTLEMENT_MOISTURE_NOT_STATED|%', v_assay.code
          USING HINT = '化验按一种基准报、合同按另一种结算,换算要用水分 —— 而这份化验没有水分,所以算不了';
    END IF;
    -- TOOLS-1 ④:换算搬进 convert_weight_basis(表达式逐字未改)。一份实现,两个调用方。
    v_swt := convert_weight_basis(v_gross, 'as_received', v_basis, v_moist);

    -- ── 逐金属:含量 → 应付量 → 计价期均价 → 金额;并扣精炼费 ────────────
    FOR v_metal, v_content IN
        SELECT m.metal, m.content_pct FROM assay_result_metals m
         WHERE m.assay_result_id = p_assay_result_id ORDER BY m.metal
    LOOP
        -- 把含量换算到【结算基准】上。含金属因此是不变量 —— 见抬头。
        -- TOOLS-1 ④:换算搬进 convert_grade_basis(表达式逐字未改)。
        v_content_s := convert_grade_basis(v_content, v_assay.weight_basis, v_basis, v_moist);
        v_contained := round(v_swt * v_content_s / 100.0, 4);

        SELECT (e->>'payable_pct')::numeric INTO v_payable
          FROM jsonb_array_elements(COALESCE(v_pricing, '[]'::jsonb)) e
         WHERE e->>'metal' = v_metal;
        IF v_payable IS NULL THEN
            RAISE EXCEPTION 'SETTLEMENT_PAYABLE_NOT_STATED|%', v_metal
              USING HINT = '计价系数是一条合同条款(PRICE-1 的 contract_pricing_terms)—— 没有它就不知道买方按含量的多大比例付钱';
        END IF;
        v_pay_kg := round(v_contained * v_payable / 100.0, 4);

        -- 计价期均价 —— **调 PRICE-1 那一支,不另写一份**(两份实现会悄悄分开)
        SELECT e->>'base_event', (e->>'qp_months')::int, e->>'index_code'
          INTO v_pt_event, v_pt_months, v_pt_index
          FROM jsonb_array_elements(v_pricing) e WHERE e->>'metal' = v_metal;
        -- 【卖方向今天只记得下"化验完成"这一个事件日期】发货日与到货日在这一侧
        -- 还没有落点,所以按它们定基准月的合同**按名拒**,而不是拿一个别的日期顶替。
        v_base_date := CASE WHEN v_pt_event = 'assay_complete' THEN v_assay.assay_date END;
        IF v_base_date IS NULL THEN
            RAISE EXCEPTION 'SETTLEMENT_BASE_EVENT_DATE_UNKNOWN|%', COALESCE(v_pt_event, '(none)')
              USING HINT = '卖方向今天记得下来的事件日期只有【化验完成】—— 发货日与到货日还没有落点,所以按它们定基准月的合同结算不了';
        END IF;
        SELECT qp.qp_from, qp.qp_to INTO v_qp FROM quotational_period(v_base_date, v_pt_months) qp;
        v_price := (index_period_average(v_pt_index, v_metal, v_qp.qp_from, v_qp.qp_to)
                    ->>'avg_usd_per_tonne')::numeric;
        v_mv := v_mv + round(v_pay_kg / 1000.0 * v_price, 2);

        -- 精炼费:按【含金属】吨数 —— 所以它**不随基准变**
        v_rc := 0;
        IF v_st->>'refining_charge_basis' = 'per_metal' THEN
            SELECT (e->>'usd_per_tonne_of_metal')::numeric INTO v_rc
              FROM jsonb_array_elements(COALESCE(v_st->'refining_charges', '[]'::jsonb)) e
             WHERE e->>'metal' = v_metal;
            IF v_rc IS NULL THEN
                RAISE EXCEPTION 'REFINING_CHARGE_NOT_FILED|%|%', v_ccode, v_metal
                  USING HINT = '这份合同声明了按金属收精炼费,却没有填这一种金属的费率 —— 【声明了有】与【填了多少】是两件事,而只有后者算得出钱';
            END IF;
            v_rcs := v_rcs + round(v_contained / 1000.0 * v_rc, 2);
        END IF;

        v_lines := v_lines || jsonb_build_object(
            'metal', v_metal, 'content_pct_assay', v_content,
            'content_pct_settlement', round(v_content_s, 6),
            'contained_kg', v_contained, 'payable_pct', v_payable,
            'payable_kg', v_pay_kg, 'price_usd_per_tonne', v_price,
            'qp_from', v_qp.qp_from, 'qp_to', v_qp.qp_to,
            'refining_charge_usd_per_tonne_of_metal', v_rc);
    END LOOP;

    -- ── 惩罚:按【结算重量】吨数 —— 所以它**随基准变** ────────────────────
    IF v_st->>'penalty_basis' = 'per_element' THEN
        IF COALESCE(jsonb_array_length(v_st->'penalty_elements'), 0) = 0 THEN
            RAISE EXCEPTION 'PENALTY_ELEMENTS_NOT_FILED|%', v_ccode
              USING HINT = '这份合同声明了按元素罚,却一条惩罚条款都没有填 —— 【声明了有】与【填了哪些】是两件事';
        END IF;
        FOR v_el IN SELECT e FROM jsonb_array_elements(v_st->'penalty_elements') e LOOP
            v_thr  := (v_el->>'threshold_pct')::numeric;
            v_rate := (v_el->>'usd_per_tonne_per_pct_over')::numeric;
            SELECT m.content_pct INTO v_content FROM assay_result_metals m
             WHERE m.assay_result_id = p_assay_result_id AND m.metal = v_el->>'substance';
            IF v_content IS NULL THEN CONTINUE; END IF;   -- 这份化验没测这个元素
            v_content_s := CASE
                WHEN v_assay.weight_basis = v_basis THEN v_content
                WHEN v_assay.weight_basis = 'dry' AND v_basis = 'as_received'
                    THEN v_content * (1 - v_moist / 100.0)
                ELSE v_content / (1 - v_moist / 100.0) END;
            v_over := v_content_s - v_thr;
            IF v_over > 0 THEN
                v_pen := v_pen + round(v_swt / 1000.0 * v_over * v_rate, 2);
                v_pens := v_pens || jsonb_build_object(
                    'substance', v_el->>'substance', 'threshold_pct', v_thr,
                    'content_pct_settlement', round(v_content_s, 6),
                    'pct_over', round(v_over, 6), 'rate', v_rate);
            END IF;
        END LOOP;
    END IF;

    v_amt := round(v_mv - v_rcs - v_pen, 2);
    RETURN jsonb_build_object(
        'sales_order_id', p_sales_order_id, 'output_batch_id', p_output_batch_id,
        'assay_result_id', p_assay_result_id, 'assay_code', v_assay.code,
        'settling_party_used', v_assay.result_party,
        'weight_basis_used', v_basis,
        'assay_weight_basis', v_assay.weight_basis,
        'gross_weight_kg', v_gross, 'moisture_pct', v_moist,
        'settlement_weight_kg', v_swt,
        'metal_value_usd', v_mv, 'refining_charge_usd', v_rcs,
        'penalty_usd', v_pen, 'amount_usd', v_amt,
        'breakdown', jsonb_build_object('metals', v_lines, 'penalties', v_pens),
        'terms_snapshot', v_st);
END
$function$;

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
-- * ★ MES-6a-1(2026-10-09,F3 · MES-6a Step 0 Q33 · Q34 · Q36,Tim):【每一次冲销都要一句理由】。签名不变(p_memo 仍是第二个参数、
--   仍带默认 —— CREATE OR REPLACE 改不了参数名,fixture 214 钉着这个签名);它从此就是理由:问码之后【第一件事】查它,
--   NULL 或空白按名拒 EXPENSE_REVERSAL_REASON_REQUIRED|<单号>(电费单与运费单的同一个次序)。理由写在被冲掉的那一张上
--   (reversal_reason / reversed_at / reversed_by,在 reverse_expense_internal 里),不再拼进镜像单的 notes。

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
    -- ★ MES-6a-1(F3,Q33):理由在码之后第一件事查(电费单与运费单的同一个次序)。单号只用来让拒绝说出是哪一张。
    IF NULLIF(btrim(COALESCE(p_memo, '')), '') IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_REVERSAL_REASON_REQUIRED|%', COALESCE((SELECT code FROM expenses WHERE id = p_expense_id), '?')
          USING HINT = '没有理由的冲销,事后没人答得出为什么';
    END IF;
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
    v_r := reverse_expense_internal(p_expense_id, btrim(p_memo));

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

-- db/functions/reverse_expense_internal.sql
-- MES-5b-2(2026-10-09,MES-5b Step 0 Q22 · Q24,Tim):【冲销一张费用单的那一段 —— 两个调用方,一份实现】。
--   reverse_expense(冲一张费用单)与 reverse_electricity_allocation(撤回一张电费单)都经它冲费用单与分录:
--   原来写在 reverse_expense 里的那一整段(资本支出的两条规矩、冲分录、镜像费用单、成本退回并当场核对)原样搬到这里,
--   一个字的算术都没改 —— 只是不再问码(调用方问),也不再拒电费分摊的费用单(那一句留在 reverse_expense:分摊那一路正是从这里冲它)。
--   ★ 新加一道(Q24):经付款结过的费用单按名拒 EXPENSE_HAS_SETTLEMENT,冲抵过预付款的按名拒 EXPENSE_HAS_PREPAYMENT_APPLIED ——
--     放在这里而不是放在两个调用方里,于是【每一种】费用单、两条路都过同一道。
--   内层:不是 DEFINER,authenticated 调不到(zzz_function_grants.sql)。
--   reverse_expense 抬头那一段(FIN-22 / EQP-1b-iii / CAPEX-1 的两条规矩与它们的不对称)说的就是这里的算术,读那里。
-- ★ MES-6a-1(2026-10-09,F3 · MES-6a Step 0 Q33 · Q34,Tim):第二个参数从此是【冲销的理由】—— 空白按名拒
--   EXPENSE_REVERSAL_REASON_REQUIRED|<单号>(两个调用方先各自拒过一次;这一道让将来任何一条新路都绕不过它)。
--   理由、时刻与人写在【被冲掉的那一张】上(reversal_reason / reversed_at / reversed_by,与 status 同一句 UPDATE);
--   镜像单的 notes 回到只有 'REVERSAL: <原单号>' 一句机器字 —— 人写的话不再和机器字挤在一列里(AT1D1 那一族)。
--   电费单的撤回传它自己的理由,不加前缀(Q34;分摊那一侧另在 electricity_allocation_reversals.reason 上留一份)。
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
    v_reason      text := NULLIF(btrim(COALESCE(p_memo, '')), '');   -- MES-6a-1(F3):冲销的理由
BEGIN
    SELECT * INTO v_orig FROM expenses WHERE id = p_expense_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', p_expense_id;
    END IF;
    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_REVERSAL_REASON_REQUIRED|%', v_orig.code
          USING HINT = '没有理由的冲销,事后没人答得出为什么';
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
            'REVERSAL: ' || v_orig.code,
            (v_je->>'reversal_id')::uuid, auth.uid());

    UPDATE expenses
    SET status = 'reversed', reversed_by_expense = v_mirror_id,
        reversal_reason = v_reason, reversed_at = now(), reversed_by = auth.uid()
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
        'asset_cost_base_after', v_after,
        'reversal_reason', v_reason
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
--   ★ MES-6a-1(2026-10-09,F3 · Q33 · Q34):理由照旧在码之后第一件事查;它从此【原样】传给 reverse_expense_internal(不再加
--     "Electricity bill reversed: " 前缀),写在被冲掉的那张费用单的 reversal_reason 上 —— 分摊这一侧在 electricity_allocation_reversals.reason 另留一份。
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
    -- ★ MES-6a-1(F3,Q34):理由原样传过去(不加前缀)—— 它写在被冲掉的那张费用单的 reversal_reason 上;分摊这一侧另留一份。
    v_x := reverse_expense_internal(v_a.expense_id, v_reason);

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
-- MES-5b-3(2026-10-09):
--   blending_plan   → /operation/blending/[id]         requireModule(MOD.processing)  = module.processing.view
--                     成员 blending_plan_targets(目标品位)与 blending_plan_lines(候选批次),都住在这里。没有金额,不遮。
--                     (MES-5b-2 也把 operation_type_output_forms 挂到 operation_type 下 —— V37 的改动从此在工序页自己的审计记录上。)
--   electricity_settings   → /finance/electricity 上的 V25 那一块  module.finance.view;单行设置作根(M5)
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q39):
--   sample          → /quality/samples/[id]          requireFunction(FN.qualitySamples) = module.quality.view
--                     成员 sample_events(保管记录,住在这里)。样品与它的保管记录也出现在它那一批的记录上(进料 / 产出主语,家不在那里)。
--   assay_dispute   → /quality/disputes/[id]         requireFunction(FN.qualityDisputes) = module.quality.view。没有成员;也出现在它那一批的记录上。
--   quality_settings → /quality/samples 上的 V16 那一块   module.quality.view;单行设置作根(electricity_settings 的先例)
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
        ('electricity_settings',   ARRAY['module.finance.view'],  'electricity_settings',    'id', 'table', NULL),
        -- MES-5b-3(2026-10-09,MES-5b Step 0 Q32 · Q35):一份配料计划(/operation/blending/[id],加工查看码 —— 与表的读策略同一个)
        ('blending_plan',          ARRAY['module.processing.view'], 'blending_plans',        'id', 'table', NULL),
        -- MES-6a-1(2026-10-09,MES-6a Step 0 Q39):一份样品 · 一件化验争议(质量查看码 —— 页面的门;行再过一次它自己那张表的读规则)·
        --   质量的设定(V16,单行设置作根)
        ('sample',                 ARRAY['module.quality.view'],   'samples',               'id', 'table', NULL),
        ('assay_dispute',          ARRAY['module.quality.view'],   'assay_disputes',        'id', 'table', NULL),
        ('quality_settings',       ARRAY['module.quality.view'],   'quality_settings',      'id', 'table', NULL)
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
        ('operation_type',     5, 'operation_type_output_forms',      'operation_types',              'operation_type_code', '{}'::jsonb, 'down', true, true),
        -- ── MES-5b-3(2026-10-09,MES-5b Step 0 Q32 · Q35):一份配料计划的目标品位与候选批次都住在那份计划下。──
        ('blending_plan',      1, 'blending_plan_targets',            'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        ('blending_plan',      2, 'blending_plan_lines',              'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        -- ── MES-6a-1(2026-10-09,MES-6a Step 0 Q39):一份样品的保管记录住在那份样品下;样品、它的保管记录与化验争议也出现在它们那一批上
        --    (家在样品 / 争议自己那里)。──
        ('sample',             1, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     44, 'samples',                          'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     45, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     46, 'assay_disputes',                   'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      42, 'samples',                          'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      43, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('output_batch',      44, 'assay_disputes',                   'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- ── 6 · 化验的样品守卫上表(与 db/tables/assay_results.sql 逐字同一份)──────────────────────
CREATE TRIGGER trg_assay_results_sample_batch
    BEFORE INSERT OR UPDATE OF sample_id ON public.assay_results
    FOR EACH ROW EXECUTE FUNCTION public.guard_assay_sample_batch();

-- ── 7 · 单据登记:SMP(与 db/tables/document_types.sql 那一行逐字同一份)──────────────────────────────
INSERT INTO public.document_types (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission) VALUES
    ('sample', 'SMP', 'samples', 'gapless', NULL, '/quality/samples', 'detail', 'notes', ARRAY['notes']::text[], ARRAY['module.quality.view']::text[]);

-- ── 8 · 新视图(镜像原样):样品此刻的状态 · 争议逐元素的差 · 争议一行 · 卖方的分歧底表 ───────────────────────

-- db/views/sample_rows.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q7 · Q8 · Q15,Tim):【一份样品与它此刻的保管状态】—— 样品页、样品清单、批次与化验页上的样品面板读它。
--   谁拿着、在哪、什么状态【全部从最近那一条保管记录读】(sample_events,按 id —— id 记先后):
--     state            held(taken / received_back / moved)· at_lab(sent_to_lab)· disposed
--     laboratory_code  在实验室时是哪一家(与它那一侧的编号)
--     storage_location 最近那一条说了库位时是那个库位;没说就是空(屏幕上"没记库位"),不往前翻一条旧的 —— 一个拿回来却没说放哪儿的罐子,
--                      它的库位就是没人记过,不是上一次那个
--   disposed_early   在留样日之前处置的(Q15:允许、理由必填、标出来)。retention_due:没处置、而留样日已经过了(sample_retention_due 那一支)。
--   【门】质量查看码,或那一批自己那一页的查看码(与 samples 的读策略同一句)。属主视图:读 sample_events / storage_locations / 批次
--   不再过各自的 RLS,所以条件写在末尾的 WHERE 里一次。没有金额,不遮。
--   【state 那一列写在所有分支列的最前面】check-i18n 的 quality.state.* 后缀集合现读它(sqlCaseAs 从文件里的第一段分支读起)。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.

CREATE VIEW public.sample_rows WITH (security_invoker = off) AS
 SELECT s.id,
    s.code,
    s.kind,
        CASE e.event_kind
            WHEN 'sent_to_lab'::text THEN 'at_lab'::text
            WHEN 'disposed'::text THEN 'disposed'::text
            ELSE 'held'::text
        END AS state,
    s.inbound_batch_id,
    s.output_batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
        CASE
            WHEN s.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    s.taken_on,
    s.mass_g,
    s.sales_order_id,
    so.code AS sales_order_code,
    s.contamination_check_id,
    s.retain_until,
    s.retain_until_source,
    s.retention_days_at,
    s.notes,
    s.created_at,
    s.created_by,
    e.event_kind AS last_event_kind,
    e.occurred_at AS last_event_at,
        CASE
            WHEN e.event_kind = 'sent_to_lab'::text THEN e.laboratory_code
            ELSE NULL::text
        END AS laboratory_code,
        CASE
            WHEN e.event_kind = 'sent_to_lab'::text THEN e.lab_reference
            ELSE NULL::text
        END AS lab_reference,
    e.storage_location_id,
    loc.code AS storage_location_code,
        CASE
            WHEN e.event_kind = 'disposed'::text THEN e.occurred_at
            ELSE NULL::timestamp with time zone
        END AS disposed_at,
        CASE
            WHEN e.event_kind = 'disposed'::text THEN e.reason
            ELSE NULL::text
        END AS disposal_reason,
    e.event_kind = 'disposed'::text AND s.retain_until IS NOT NULL
        AND (e.occurred_at AT TIME ZONE 'Asia/Singapore'::text)::date < s.retain_until AS disposed_early,
    e.event_kind <> 'disposed'::text AND s.retain_until IS NOT NULL AND s.retain_until < CURRENT_DATE AS retention_due,
    ( SELECT count(*) AS count
           FROM sample_events x
          WHERE x.sample_id = s.id) AS event_count
   FROM samples s
     LEFT JOIN inbound_batches ib ON ib.id = s.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = s.output_batch_id
     LEFT JOIN sales_orders so ON so.id = s.sales_order_id
     LEFT JOIN LATERAL ( SELECT x.event_kind,
            x.occurred_at,
            x.laboratory_code,
            x.lab_reference,
            x.storage_location_id,
            x.reason
           FROM sample_events x
          WHERE x.sample_id = s.id
          ORDER BY x.id DESC
         LIMIT 1) e ON true
     LEFT JOIN storage_locations loc ON loc.id = e.storage_location_id
  WHERE has_permission('module.quality.view'::text) OR s.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text) OR s.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text);

COMMENT ON VIEW public.sample_rows IS
    'MES-6a-1:一份样品与它此刻的保管状态 —— state / 实验室 / 库位都从最近那一条保管记录读(按 id);disposed_early = 留样日之前处置的(Q15);retention_due = 没处置而留样日已过。门:质量查看码或那一批自己的查看码(与 samples 的读策略同一句)。';

GRANT SELECT ON public.sample_rows TO authenticated;
REVOKE ALL ON public.sample_rows FROM anon;

-- db/views/assay_dispute_metals.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q16,Tim):【一件争议逐元素的差 —— 现算,不存】。争议页的"两份结果并排"那一段读它。
--   一行一种元素:我们的 % · 对手方的 % · 仲裁的 %(记了仲裁结果时)· |我们 − 对手方| · 是否超过立案时在案的容差
--   (容差为空 = limit not set → beyond_limit 为 NULL,"判不了",不是"没超")。一种元素只在一份结果里有 → 另一侧为 NULL、差为 NULL。
--   【门】质量查看码,或那一批自己那一页的查看码(与 assay_disputes 的读策略同一句)。属主视图:化验的金属不再过各自那一批的 RLS,
--   所以条件写在末尾的 WHERE 里一次。含量是技术数据(perm2b 有意不遮 content_pct),不遮。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.

CREATE VIEW public.assay_dispute_metals WITH (security_invoker = off) AS
 SELECT d.id AS dispute_id,
    m.metal,
    o.content_pct AS ours_pct,
    c.content_pct AS counterparty_pct,
    u.content_pct AS umpire_pct,
    abs(o.content_pct - c.content_pct) AS diff_pct,
        CASE
            WHEN d.limit_pct_at IS NULL OR o.content_pct IS NULL OR c.content_pct IS NULL THEN NULL::boolean
            ELSE abs(o.content_pct - c.content_pct) > d.limit_pct_at
        END AS beyond_limit
   FROM assay_disputes d
     CROSS JOIN LATERAL ( SELECT x.metal
           FROM assay_result_metals x
          WHERE x.assay_result_id = ANY (ARRAY[d.our_assay_id, d.counterparty_assay_id, d.umpire_assay_id])
          GROUP BY x.metal) m
     LEFT JOIN assay_result_metals o ON o.assay_result_id = d.our_assay_id AND o.metal = m.metal
     LEFT JOIN assay_result_metals c ON c.assay_result_id = d.counterparty_assay_id AND c.metal = m.metal
     LEFT JOIN assay_result_metals u ON u.assay_result_id = d.umpire_assay_id AND u.metal = m.metal
  WHERE has_permission('module.quality.view'::text) OR d.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text) OR d.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text);

COMMENT ON VIEW public.assay_dispute_metals IS
    'MES-6a-1:一件化验争议逐元素的差(现算,不存 —— Q16):我们的 / 对手方的 / 仲裁的 %,|我们 − 对手方|,是否超过立案时在案的容差(容差为空 → NULL,判不了)。门:质量查看码或那一批自己的查看码。';

GRANT SELECT ON public.assay_dispute_metals TO authenticated;
REVOKE ALL ON public.assay_dispute_metals FROM anon;

-- db/views/assay_dispute_rows.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q16 · Q19 · Q22,Tim):【一件化验争议,连同它的两份(三份)结果、容差、结案与仲裁费】——
--   争议清单、争议页、批次与化验页上的争议横幅读它。
--   max_diff_pct = 我们与对手方在【两份都有】的元素上的最大差(与 sale_settlement_compute 那一道推出来的拒绝同一个算法);
--   beyond_limit = 它是否超过立案时在案的容差(容差为空 → NULL,判不了 —— limit not set)。
--   【仲裁费】fee_amount_base 是挂上的那张费用单的本位币净额;counterparty_share_pct 是按立案时在案的规则(V14)算出来的对手方那一份
--   (只算给人看,不收 —— Q22):equal 50 · buyer / seller 看这一批是卖出去的(产出批:对手方是买方)还是买进来的(进料批:我们是买方)·
--   loser_pays 看结案时点名的那一份是谁的(说了算的是我们 → 对手方付;是对手方 → 我们付;是仲裁的 → 照 further_from_umpire_pays)·
--   further_from_umpire_pays 看两份各自离仲裁结果多远(在三份都有的元素上取最大差;一样远或缺一样 → NULL)。规则为空或算不了 → NULL。
--   ★ 钱的那两列(费用额、对手方那一份的额)只给持 module.finance.view 的读者(常设决定 1:持财务查看就看得见钱);其余读到 NULL,
--   fee_restricted 为真 —— 屏幕上是「受限」,不是 0。规则、比例与费用单号不遮。
--   【门】质量查看码,或那一批自己那一页的查看码(与 assay_disputes 的读策略同一句)。属主视图,条件在末尾的 WHERE 里。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.

CREATE VIEW public.assay_dispute_rows WITH (security_invoker = off) AS
 SELECT d.id,
    d.status,
    d.inbound_batch_id,
    d.output_batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
        CASE
            WHEN d.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    d.our_assay_id,
    ao.code AS our_assay_code,
    d.counterparty_assay_id,
    ac.code AS counterparty_assay_code,
    d.umpire_sample_id,
    us.code AS umpire_sample_code,
    d.umpire_assay_id,
    au.code AS umpire_assay_code,
    au.lab_name AS umpire_lab_code,
    d.governing_assay_id,
    ag.code AS governing_assay_code,
    ag.result_party AS governing_party,
    d.sales_order_id,
    so.code AS sales_order_code,
    d.opening_reason,
    d.limit_pct_at,
    x.max_diff_pct,
        CASE
            WHEN d.limit_pct_at IS NULL OR x.max_diff_pct IS NULL THEN NULL::boolean
            ELSE x.max_diff_pct > d.limit_pct_at
        END AS beyond_limit,
    d.fee_rule_at,
    d.fee_expense_id,
    fe.code AS fee_expense_code,
        CASE
            WHEN has_permission('module.finance.view'::text) THEN fe.amount_base
            ELSE NULL::numeric
        END AS fee_amount_base,
    sh.share_pct AS counterparty_share_pct,
        CASE
            WHEN has_permission('module.finance.view'::text) THEN round(fe.amount_base * sh.share_pct / 100::numeric, 2)
            ELSE NULL::numeric
        END AS counterparty_share_base,
    d.fee_expense_id IS NOT NULL AND NOT has_permission('module.finance.view'::text) AS fee_restricted,
    d.resolution_note,
    d.resolved_at,
    d.resolved_by,
    d.withdrawn_at,
    d.withdrawn_by,
    d.withdraw_reason,
    d.created_at,
    d.created_by
   FROM assay_disputes d
     LEFT JOIN inbound_batches ib ON ib.id = d.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = d.output_batch_id
     JOIN assay_results ao ON ao.id = d.our_assay_id
     JOIN assay_results ac ON ac.id = d.counterparty_assay_id
     LEFT JOIN assay_results au ON au.id = d.umpire_assay_id
     LEFT JOIN assay_results ag ON ag.id = d.governing_assay_id
     LEFT JOIN samples us ON us.id = d.umpire_sample_id
     LEFT JOIN sales_orders so ON so.id = d.sales_order_id
     LEFT JOIN expenses fe ON fe.id = d.fee_expense_id
     CROSS JOIN LATERAL ( SELECT max(abs(o.content_pct - c.content_pct)) AS max_diff_pct
           FROM assay_result_metals o
             JOIN assay_result_metals c ON c.metal = o.metal AND c.assay_result_id = d.counterparty_assay_id
          WHERE o.assay_result_id = d.our_assay_id) x
     CROSS JOIN LATERAL ( SELECT max(abs(o.content_pct - u.content_pct)) AS ours_from_umpire,
            max(abs(c.content_pct - u.content_pct)) AS cp_from_umpire
           FROM assay_result_metals u
             JOIN assay_result_metals o ON o.metal = u.metal AND o.assay_result_id = d.our_assay_id
             JOIN assay_result_metals c ON c.metal = u.metal AND c.assay_result_id = d.counterparty_assay_id
          WHERE u.assay_result_id = d.umpire_assay_id) dist
     CROSS JOIN LATERAL ( SELECT
                CASE d.fee_rule_at
                    WHEN 'equal'::text THEN 50::numeric
                    WHEN 'buyer'::text THEN
                    CASE
                        WHEN d.output_batch_id IS NOT NULL THEN 100::numeric
                        ELSE 0::numeric
                    END
                    WHEN 'seller'::text THEN
                    CASE
                        WHEN d.output_batch_id IS NOT NULL THEN 0::numeric
                        ELSE 100::numeric
                    END
                    WHEN 'loser_pays'::text THEN
                    CASE ag.result_party
                        WHEN 'ours'::text THEN 100::numeric
                        WHEN 'counterparty'::text THEN 0::numeric
                        WHEN 'umpire'::text THEN
                        CASE
                            WHEN dist.cp_from_umpire > dist.ours_from_umpire THEN 100::numeric
                            WHEN dist.ours_from_umpire > dist.cp_from_umpire THEN 0::numeric
                            ELSE NULL::numeric
                        END
                        ELSE NULL::numeric
                    END
                    WHEN 'further_from_umpire_pays'::text THEN
                    CASE
                        WHEN dist.cp_from_umpire > dist.ours_from_umpire THEN 100::numeric
                        WHEN dist.ours_from_umpire > dist.cp_from_umpire THEN 0::numeric
                        ELSE NULL::numeric
                    END
                    ELSE NULL::numeric
                END AS share_pct) sh
  WHERE has_permission('module.quality.view'::text) OR d.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text) OR d.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text);

COMMENT ON VIEW public.assay_dispute_rows IS
    'MES-6a-1:一件化验争议,连同它的结果、最大差、容差(立案时在案;空 = limit not set)、结案、仲裁费与对手方那一份(按立案时的 V14 规则算,只给人看,不收)。钱的两列只给 module.finance.view(常设决定 1),其余 NULL + fee_restricted。门:质量查看码或那一批自己的查看码。';

GRANT SELECT ON public.assay_dispute_rows TO authenticated;
REVOKE ALL ON public.assay_dispute_rows FROM anon;

-- db/views/assay_disagreements_all.sql
-- MES-6a-1(2026-10-09,MES-0 Q62 · MES-6a Step 0 Q17,Tim):【卖方:两方结果差得超过了合同的容差,而没有人立过争议】—— 底表,只给属主读。
--   operations_now 的 assay_results_disagree 那一支读它(Q62:"只在有容差的地方提示")。
--   一行 = 一批产出批 × 一张与它有关的销售单(经预留、发货行或结算记录挂上的),那张单的合同副本里有容差(splitting_limit_pct 不空),
--   这一批最近一份没删的 ours 与最近一份没删的 counterparty 在两份都有的元素上的最大差超过了它(与 sale_settlement_compute 那一道推出来的
--   拒绝同一个算法),而这一批没有一件开着或已结案的争议(撤回过的不算 —— 两份数仍然对不上,提示回来)。
--   【买方没有这一支】买方合同今天不带结算口径,所以买方没有容差可比(Q17 —— 买方的争议由人自己立)。
--   【底表】authenticated 读不到(zzz_function_grants 一侧的同一个理由:提醒外壳按每一支的码把门)。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.

CREATE VIEW public.assay_disagreements_all WITH (security_invoker = off) AS
 SELECT ob.id AS output_batch_id,
    ob.code AS batch_code,
    so.id AS sales_order_id,
    so.code AS sales_order_code,
    o.id AS our_assay_id,
    o.code AS our_assay_code,
    c.id AS counterparty_assay_id,
    c.code AS counterparty_assay_code,
    (t.settlement_terms ->> 'splitting_limit_pct'::text)::numeric AS limit_pct,
    x.max_diff_pct,
    GREATEST(o.assay_date, c.assay_date) AS latest_assay_date
   FROM output_batches ob
     CROSS JOIN LATERAL ( SELECT a.id, a.code, a.assay_date
           FROM assay_results a
          WHERE a.output_batch_id = ob.id AND a.deleted_at IS NULL AND a.result_party = 'ours'::text
          ORDER BY a.assay_date DESC, a.code DESC
         LIMIT 1) o
     CROSS JOIN LATERAL ( SELECT a.id, a.code, a.assay_date
           FROM assay_results a
          WHERE a.output_batch_id = ob.id AND a.deleted_at IS NULL AND a.result_party = 'counterparty'::text
          ORDER BY a.assay_date DESC, a.code DESC
         LIMIT 1) c
     CROSS JOIN LATERAL ( SELECT max(abs(om.content_pct - cm.content_pct)) AS max_diff_pct
           FROM assay_result_metals om
             JOIN assay_result_metals cm ON cm.metal = om.metal AND cm.assay_result_id = c.id
          WHERE om.assay_result_id = o.id) x
     JOIN ( SELECT r.output_batch_id, l.sales_order_id
           FROM sales_order_reservations r
             JOIN sales_order_lines l ON l.id = r.sales_order_line_id
        UNION
         SELECT sl.output_batch_id, l.sales_order_id
           FROM shipment_lines sl
             JOIN sales_order_lines l ON l.id = sl.sales_order_line_id
        UNION
         SELECT st.output_batch_id, st.sales_order_id
           FROM sales_settlements st) link ON link.output_batch_id = ob.id
     JOIN sales_orders so ON so.id = link.sales_order_id AND so.deleted_at IS NULL
     JOIN contract_document_terms t ON t.sales_order_id = so.id
  WHERE ob.deleted_at IS NULL AND (t.settlement_terms ->> 'splitting_limit_pct'::text) IS NOT NULL
    AND x.max_diff_pct > (t.settlement_terms ->> 'splitting_limit_pct'::text)::numeric
    AND NOT (EXISTS ( SELECT 1
           FROM assay_disputes d
          WHERE d.output_batch_id = ob.id AND (d.status = ANY (ARRAY['open'::text, 'resolved'::text]))));

COMMENT ON VIEW public.assay_disagreements_all IS
    'MES-6a-1:卖方 —— 一批产出批最近一份 ours 与最近一份 counterparty 的最大差超过了一张与它有关的销售单的合同容差,而没有开着或已结案的争议(MES-0 Q62 的提示)。底表,只给属主读;operations_now 的 assay_results_disagree 读它。';

REVOKE ALL ON public.assay_disagreements_all FROM authenticated, anon;

-- ── 9 · 换掉的视图(镜像原样,同列):待补的值 +V16 +V14 · 提醒 +3 支 ─────────────────────────────────────

-- db/views/pending_values.sql
-- MES-1(2026-10-06,MES-0 §5 · Q92 · Q93;MES-1 Step 0 Q1 · Q2,Tim):【还没给的标准值】—— /settings/pending-values 读它。
--   一支一个值(像 operations_now 那样),每一支带着它自己的权限码;读者只看得到他持码的那几支(末尾的 WHERE)。
--   每一行是一件具体还空着的事:哪一个值(value_code,对应 docs/mes-pending-values.md 里那一行)、空在哪一条记录上、去哪儿填。
--   给了值,那一行就自己消失(这张视图不存任何东西)。
-- 【MES-1 播两支】
--   V5  网关的心跳间隔 —— 每一台没停用、间隔为空的网关一行。由集成商在网关调试时给(MES-0 §5.1 V5)。
--   V6  传输异常的工作时间 —— 读班次的起止时刻(shifts.starts_at / ends_at,为空是设计如此:没人说过几点到几点)。
--       每一个启用、而起止为空的班次一行。由 Tim 给(V6)。
-- 【MES-2 加两支】(2026-10-06,MES-2 Step 0 Q12 · Q30,Tim)
--   V8   校准到期前多少天开始提醒 —— 一个值,ingest_settings.calibration_lead_days 为空时一行(去处:/operation/calibration)。
--        由校准机构 / 仪器厂商给,仪器安装时(MES-0 §5.1)。没给:到期前的提醒不上牌,过期照样上牌。
--   V33  每一台【在用的】仪器(秤 · 地磅 · 电表 · 在线仪表,interface_status 不是 reserved,没停用)的量程 —— 量程为空的每台一行
--        (去处:它的设备页)。由仪器厂商给(规格 §8.2)。没给:确认读数时不判量程(WEIGHING_ABOVE_CAPACITY 只在给了时拒)。
-- 【MES-3a 加五支】(2026-10-06,MES-0 §5.1 V2 · V3 · V4 · V29;MES-3a Step 0 Q21 · Q31,Tim)
--   V2   一张执照对一类 NEA 废物的库存上限 —— 今天在效的那张执照 × 每一个启用的类别,没有 licence_storage_limits 行的一行
--        (去处:/purchasing/licences;门 module.suppliers.view)。由 NEA 执照条件给。类别列表是空的时它也是空的(V29 先来)。
--   V29  NEA 废物类别 —— 类别列表里一个启用的都没有时一行;有了之后,每一种没删、种类吃得下状态轴(电池料)而没有类别的物料一行
--        (去处:/settings/dictionaries 或那个物料;门 module.materials.view)。由 NEA 执照给。
--   V3   每一个启用的安全状态的滞留提醒天数 —— dwell_warning_days 为空的每个一行(去处:/settings/dictionaries;门 module.materials.view)。
--        由 Tim 与 WSH 负责人给,或执照的贮存条件。
--   V4   每一个启用的安全状态要不要隔离 —— requires_quarantine 为空的每个一行(同上)。引导只定了两个(鼓包或漏液 = 要,已放电 = 不要)。
--   V34  隔离库位 —— 有任何一个状态要隔离,而一个在用的隔离库位都没有时一行(去处:/inventory/locations;门 module.inventory.view)。
--        没有它,鼓包或漏液的料收不进来(QUARANTINE_LOCATION_REQUIRED)。由 Tim / 仓库在第一批这样的料到之前给。
-- 【MES-3b 加三支】(2026-10-07,MES-0 §5.1 V30 · V31;MES-3b Step 0 Q29 · V35,Tim)
--   V30  每一个启用的危险品 UN 编号的包装标记文字、包装说明、标签尺寸 —— 三样里有任何一样为空的每个编号一行
--        (去处:/settings/dictionaries;门 module.materials.view)。由有 DG 资质的货代在第一次出口之前给。
--   V31  每一种没删的电池料(种类吃得下状态轴)的 HS 编码 —— 为空的每种一行(去处:那个物料;门 module.materials.view)。
--        由报关行在第一次出口之前给。
--   V35  每一种没删的电池料的危险品 UN 编号 —— 没选的每种一行(同上)。由货代与 Tim 在第一次出口或第一次危险品发货之前给。
--        没给:标签与发货单上提示"没给",不拒(Q15)。
-- 【MES-4a 加两支、改一支】(2026-10-07,MES-0 §5.1 V1 · V7;MES-4a Step 0 Q35,Tim)
--   V1   每一道启用的【转化型】工序的物料平衡容差(投入的百分比)—— balance_tolerance_pct 为空的每道一行(去处:那道工序的页面;
--        门 module.processing.view)。由 Tim 与 cto 在每一段调试结束时给。没给:任何不为零的余数都要书面说明才能结平(Q46)。
--        状态改变型(放电)不列 —— 它投入恒等于产出,没有容差可言。
--   V36  每一个启用的、声明了【有范围】(has_range)而上下限都空着的参数 —— 一个字段一行(去处:那道工序的页面)。由设备厂商或
--        工艺工程师在那一段调试时给。没给:那个字段的值照记,不判越界。引导的字段一个都没声明有范围,所以今天是零行。
--   V6   【改了去处,一支答两个值】班次的起止时刻 —— MES-1 的 V6(传输异常的工作时间)与 MES-0 的 V7(加工单的班次时刻)读的是
--        同一组列(shifts.starts_at / ends_at),一支一行就够,两行说的会是同一件事。去处从 /operation/handovers(那一页只读班次,
--        改不了时刻)搬到 /settings/dictionaries(MES-4a 给班次加了一种"时刻"字段)。
-- 【MES-4b 加两支】(2026-10-07,MES-0 §5.1 V10 · V11;MES-4b Step 0 Q29,Tim)
--   V10  每一道启用的、勾了「Electrolyte evaporates in this step」而电解液份额为空的工序 —— 一道一行(去处:那道工序的页面;
--        门 module.processing.view)。由电芯供应商的规格书 / 工艺工程师在第一批极片分离之前给。引导一道都没勾,所以今天是零行。
--        没给:那一段的电解液挥发只能量出来,算不出来(ELECTROLYTE_SHARE_NOT_SET)。
--   V11  每一条启用的交叉污染流的警戒线(contamination_streams.warning_pct)—— 为空的每条一行(去处:/settings/dictionaries;
--        门 module.processing.view)。由 Tim / 第一份黑粉承购合同的规格在第一份承购合同之前给。没给:抽检照记,判不了超没超(NULL)。
-- 【MES-5a-1 加一支】(2026-10-08,MES-0 §5.1 V9;MES-5a Step 0 Q8 · Q32,Tim)
--   V9   放电通过电压(materials.discharge_pass_voltage_v,按物料 —— 模组的终止电压取决于串联节数)。【只在这种物料的一批已经有了
--        放电结果之后才列】,免得页面一下子被每一种装电芯的物料填满(去处:物料编辑页;门 module.materials.view)。由 Bosch 文档 /
--        模组规格书在放电调试时给。没给:结果照记,判定照收,那一格是"判不了"(contradicts_pass_voltage 为 NULL)。
-- 【MES-5a-2 加一支】(2026-10-08,MES-0 §5.1 V25;MES-5a Step 0 Q25 · Q32,Tim)
--   V25  共用池的电怎么摊(electricity_settings.shared_pool_rule)—— 有一台没停用、没挂机器的电表(共用池),而规则为空时一行
--        (去处:/finance/electricity;门 module.finance.view)。由 Tim 在电表接上之后的第一张电费单时给。没给:不计量的电与
--        共用池量到的电在每一次分摊里都留在间接费用 6200。今天线上一台电表都没有,所以是零行。
-- 【MES-6a-1 加两支】(2026-10-09,MES-0 §5.1 V14 · V16;MES-6a Step 0 Q14 · Q22 · Q42,Tim)
--   V16  没有合同天数的样品留多少天(quality_settings.internal_retention_days)—— 为空、而且有一份没处置、留样日 Not yet set 的样品时一行
--        (去处:/quality/samples 的设定;门 module.quality.view)。由 Tim / 质量在第一份要留的样品时给。没给:那样的样品没有留样日,不进提醒。
--        只有一份没处置的 not_set 样品时才列 —— V9 的先例:没人能动手的行不列。
--   V14  仲裁费怎么分(contract_settlement_terms.arbitration_fee_rule,只卖方合同有)—— 每一份【有过一件开着或已结案的争议】(经那件争议的
--        销售单的合同副本认合同)、而它的结算口径里规则为空的合同一行(去处:那份合同;门 module.customers.view —— 条款自己的读码)。
--        由对手方合同在签约时给。没给:争议照立,仲裁费照记,对手方那一份算不出来(NULL)。
--   (V15 没有支:F / Cl 的惩罚阈值是逐份合同的条款,声明了 per_element 却没填时结算按名拒 PENALTY_ELEMENTS_NOT_FILED;V17 归 MES-6b。)
-- 【规矩】之后每一刀加它自己的那几支,并在【同一个提交里】往 docs/mes-pending-values.md 加它们的行(Tim,Q2)。
-- 【属主视图】读 devices / shifts 不过 RLS,所以每一支的码在末尾的 WHERE 里问一次。

CREATE OR REPLACE VIEW public.pending_values WITH (security_invoker = off) AS
 SELECT p.value_code,
    p.permission,
    p.item_id,
    p.item_code,
    p.item_label,
    p.href
   FROM ( SELECT 'V5'::text AS value_code,
            'module.processing.view'::text AS permission,
            d.id AS item_id,
            d.code AS item_code,
            d.name AS item_label,
            '/operation/devices/'::text || d.id::text AS href
           FROM devices d
          WHERE d.kind = 'gateway'::text AND d.retired_at IS NULL AND d.heartbeat_interval_s IS NULL
        UNION ALL
         SELECT 'V6'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            sh.code AS item_code,
            sh.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM shifts sh
          WHERE sh.is_active AND sh.starts_at IS NULL AND sh.ends_at IS NULL
        UNION ALL
         SELECT 'V8'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            'calibration_lead_days'::text AS item_code,
            'Calibration reminder lead days'::text AS item_label,
            '/operation/calibration'::text AS href
           FROM ingest_settings st
          WHERE st.id AND st.calibration_lead_days IS NULL
        UNION ALL
         SELECT 'V33'::text AS value_code,
            'module.processing.view'::text AS permission,
            d.id AS item_id,
            d.code AS item_code,
            d.name AS item_label,
            '/operation/devices/'::text || d.id::text AS href
           FROM devices d
          WHERE d.kind = ANY (ARRAY['scale'::text, 'weighbridge'::text, 'meter'::text, 'inline_instrument'::text])
            AND d.retired_at IS NULL AND d.interface_status <> 'reserved'::text AND d.capacity IS NULL
        UNION ALL
         SELECT 'V2'::text AS value_code,
            'module.suppliers.view'::text AS permission,
            cc.id AS item_id,
            c.code AS item_code,
            (cc.cert_no || ' · '::text) || c.name_en AS item_label,
            '/purchasing/licences'::text AS href
           FROM company_compliance cc
             CROSS JOIN nea_waste_categories c
          WHERE cc.id = storage_licence_in_force((now() AT TIME ZONE 'Asia/Singapore'::text)::date) AND c.is_active
            AND NOT (EXISTS ( SELECT 1
                   FROM licence_storage_limits l
                  WHERE l.licence_id = cc.id AND l.category_code = c.code))
        UNION ALL
         SELECT 'V29'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            'nea_waste_categories'::text AS item_code,
            'NEA waste categories'::text AS item_label,
            '/settings/dictionaries'::text AS href
          WHERE NOT (EXISTS ( SELECT 1
                   FROM nea_waste_categories c
                  WHERE c.is_active))
        UNION ALL
         SELECT 'V29'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.nea_waste_category_code IS NULL
            AND (EXISTS ( SELECT 1
                   FROM nea_waste_categories c
                  WHERE c.is_active))
        UNION ALL
         SELECT 'V3'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            st.code AS item_code,
            st.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM inbound_safety_states st
          WHERE st.is_active AND st.dwell_warning_days IS NULL
        UNION ALL
         SELECT 'V4'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            st.code AS item_code,
            st.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM inbound_safety_states st
          WHERE st.is_active AND st.requires_quarantine IS NULL
        UNION ALL
         SELECT 'V34'::text AS value_code,
            'module.inventory.view'::text AS permission,
            NULL::uuid AS item_id,
            'quarantine_location'::text AS item_code,
            'Quarantine location'::text AS item_label,
            '/inventory/locations'::text AS href
          WHERE (EXISTS ( SELECT 1
                   FROM inbound_safety_states st
                  WHERE st.is_active AND st.requires_quarantine IS TRUE))
            AND NOT (EXISTS ( SELECT 1
                   FROM storage_locations l
                  WHERE l.is_active AND l.is_quarantine))
        UNION ALL
         SELECT 'V30'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            g.code AS item_code,
            g.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM dangerous_goods_codes g
          WHERE g.is_active AND (g.marking_text IS NULL OR g.packing_instruction IS NULL OR g.label_size IS NULL)
        UNION ALL
         SELECT 'V31'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.hs_code IS NULL
        UNION ALL
         SELECT 'V35'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.dg_code IS NULL
        UNION ALL
         SELECT 'V1'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            ot.code AS item_code,
            ot.name_en AS item_label,
            '/operation/operation-types/'::text || ot.code AS href
           FROM operation_types ot
             JOIN operation_kinds k ON k.code = ot.kind_code
          WHERE ot.is_active AND k.produces_outputs AND ot.balance_tolerance_pct IS NULL
        UNION ALL
         SELECT 'V36'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            (f.operation_type_code || '/'::text) || f.field_code AS item_code,
            f.name_en AS item_label,
            '/operation/operation-types/'::text || f.operation_type_code AS href
           FROM operation_type_fields f
             JOIN operation_types ot ON ot.code = f.operation_type_code
          WHERE f.is_active AND ot.is_active AND f.has_range AND f.range_min IS NULL AND f.range_max IS NULL
        UNION ALL
         SELECT 'V10'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            ot.code AS item_code,
            ot.name_en AS item_label,
            '/operation/operation-types/'::text || ot.code AS href
           FROM operation_types ot
          WHERE ot.is_active AND ot.electrolyte_loss_applies AND ot.electrolyte_share_pct IS NULL
        UNION ALL
         SELECT 'V11'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            cs.code AS item_code,
            cs.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM contamination_streams cs
          WHERE cs.is_active AND cs.warning_pct IS NULL
        UNION ALL
         SELECT 'V9'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
          WHERE m.deleted_at IS NULL AND m.discharge_pass_voltage_v IS NULL AND (EXISTS ( SELECT 1
                   FROM discharge_module_results r
                     LEFT JOIN inbound_batches ib ON ib.id = r.inbound_batch_id
                     LEFT JOIN output_batches ob ON ob.id = r.output_batch_id
                  WHERE COALESCE(ib.material_id, ob.material_id) = m.id))
        UNION ALL
         SELECT 'V25'::text AS value_code,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            'shared_pool_rule'::text AS item_code,
            'Shared-pool electricity rule'::text AS item_label,
            '/finance/electricity'::text AS href
           FROM electricity_settings es
          WHERE es.id AND es.shared_pool_rule IS NULL AND (EXISTS ( SELECT 1
                   FROM devices d
                  WHERE d.kind = 'meter'::text AND d.equipment_id IS NULL AND d.retired_at IS NULL))
        UNION ALL
         SELECT 'V37'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            (tf.operation_type_code || '/'::text) || tf.form_code AS item_code,
            (ot.name_en || ' · '::text) || COALESCE(mf.name_en, tf.form_code) AS item_label,
            '/operation/operation-types/'::text || tf.operation_type_code AS href
           FROM operation_type_output_forms tf
             JOIN operation_types ot ON ot.code = tf.operation_type_code
             LEFT JOIN material_forms mf ON mf.code = tf.form_code
          WHERE ot.is_active AND tf.expected_yield_pct IS NULL AND (EXISTS ( SELECT 1
                   FROM processing_run_flow_all f
                  WHERE f.operation_type_code = tf.operation_type_code AND f.flow = 'consumption'::text AND f.era_mes4a))
        UNION ALL
         SELECT 'V16'::text AS value_code,
            'module.quality.view'::text AS permission,
            NULL::uuid AS item_id,
            'internal_retention_days'::text AS item_code,
            'Internal sample retention (days)'::text AS item_label,
            '/quality/samples'::text AS href
           FROM quality_settings qs
          WHERE qs.id AND qs.internal_retention_days IS NULL AND (EXISTS ( SELECT 1
                   FROM samples s
                  WHERE s.retain_until_source = 'not_set'::text AND NOT (EXISTS ( SELECT 1
                           FROM sample_events e
                          WHERE e.sample_id = s.id AND e.event_kind = 'disposed'::text))))
        UNION ALL
         SELECT 'V14'::text AS value_code,
            'module.customers.view'::text AS permission,
            c.id AS item_id,
            c.code AS item_code,
            c.title AS item_label,
            '/contracts/'::text || c.id::text AS href
           FROM contracts c
          WHERE c.deleted_at IS NULL AND (EXISTS ( SELECT 1
                   FROM assay_disputes d
                     JOIN contract_document_terms t ON t.sales_order_id = d.sales_order_id
                  WHERE t.contract_id = c.id AND (d.status = ANY (ARRAY['open'::text, 'resolved'::text])))) AND NOT (EXISTS ( SELECT 1
                   FROM contract_settlement_terms cst
                  WHERE cst.contract_id = c.id AND cst.arbitration_fee_rule IS NOT NULL))) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程);MES-3a 加 V2(执照 × 类别的库存上限)、V29(NEA 类别与物料的类别)、V3(每个安全状态的滞留提醒天数)、V4(每个安全状态要不要隔离)与 V34(隔离库位);MES-3b 加 V30(危险品编号的标记 · 包装说明 · 标签尺寸)、V31(电池料的 HS 编码)与 V35(电池料的危险品编号);MES-4a 加 V1(转化型工序的物料平衡容差)与 V36(声明了有范围的参数的上下限),并把 V6 的去处搬到班次字典(V6 同时答 V7);MES-4b 加 V10(勾了电解液挥发的工序的电解液份额)与 V11(交叉污染流的警戒线)。MES-5a-1 加 V9(物料的放电通过电压,只在那种物料有了放电结果之后才列);MES-5a-2 加 V25(共用池的电怎么摊,有共用池电表而规则为空时一行)。MES-5b-1 加 V37(每道工序 × 每种产出形态的预期质量得率;只在那道工序有了至少一张 MES-4a 之后的消耗炉次时才列 —— V9 的先例:没人能动手的行不列)。MES-6a-1 加 V16(没有合同天数的样品留多少天;只在有一份没处置、留样日 Not yet set 的样品时才列)与 V14(仲裁费怎么分;每一份有过一件开着或已结案的争议而规则为空的合同一行)。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行
-- ★ MES-6a-1(2026-10-09,MES-6a Step 0 Q15 · Q17,Tim):加三支,门都是 module.quality.view。
--   sample_retention_due —— 一份样品的留样日已经过了、还没处置(Q15)。item_id = 那份样品;subject = 批号;item_date = 留样日。
--     留样日 Not yet set 的样品不进来(没有日子可过)。
--   assay_dispute_open —— 一件开着的化验争议(它挡着进料的应用 / 定价过账与卖方结算)。item_id = 那件争议;item_code = 批号;
--     subject = 两份结果的单号。
--   assay_results_disagree —— 卖方:两方结果差得超过了合同的容差,而没有人立过争议(MES-0 Q62;assay_disagreements_all)。
--     item_id = 那一批产出批;subject = 销售单号。买方没有这一支(买方合同不带容差 —— Q17)。
-- ★ MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23;MES-5a Step 0 Q18,Tim):加两支,都读 discharge_batch_status_all,门 module.processing.view。
--   discharge_unverified —— 一批做过一炉没回滚的深度放电(verifies_by_unit 的工序),却还没有开着"已放电并核实"
--   (逐模组的结论还没凑满:没记模组数、结果没记完、有模组要再放电)。item_id = 那一批最晚的那一炉;subject = 批号。
--   discharge_quarantine_pending —— 一批里有模组最新一条结论是"失败、处置为隔离",还没拆走。item_id = 那一批最晚的那一炉(拆分从那一页上起);
--   subject = 批号。拆走、或更正了那一条,它就消失。
-- ★ MES-4b(2026-10-07,规格 §3.4;MES-0 Q52;MES-4b Step 0 Q24,Tim):加一支 contamination_check_missing —— 一个班、一条流没有抽检
--   (那一天那一班有一张 MES-4a 起记的、已提交没回滚的单产出了这条流的极片,而同一天同一班任何一张单上都没有一条当前的抽检,
--   两种都算 —— contamination_shift_status_all 的 check_state = 'missing')。门 module.processing.view;item_id = 那一格最早的那一炉
--   (fixture 47:一行提醒要指着一条真实的行),subject = 流。记一条"没抽"(带理由)也关掉它。
-- ★ MES-4a(2026-10-07,MES-0 Q48;MES-4a Step 0 Q22,Tim):加一支 processing_balance_unclosed —— 物料平衡还没结的加工单
--   (MES-4a 起记的、转化型的、已提交没回滚的、最新结平不当前的;processing_run_balance_all 的 balance_state = 'open')。
--   门 module.processing.view;点进去是那张加工单(平衡面板在上面)。只是提醒:月末那一行也只警告,不挡关账。
-- ★ ROLE-1 Batch 2a(2026-09-24,Q9):加一支 supplier_pending_approval —— 等 CFO 批的供应商
--   (action.supplier_approve;只有持这个码的人看得见,点进去由 set_supplier_status 裁)。
--   等了多久从【最后一次送审】起算(supplier_status_history),没有那一行时退回 updated_at。
-- ★ PAY-REQ-1(2026-09-23):加一支 payment_request_pending —— 等 CFO 批的付款申请
--   (module.finance.view;finance 与 cfo 都看得见,点进去由 decide_payment_request 裁谁能批)。
-- ★ PAYROLL-APR-1(2026-09-24):加一支 payroll_request_pending —— 等 CFO 批的工资过账 / 撤销申请
--   (data.view_pay:看得见工资数的人才看得见这一格;点进去由 decide_payroll_request 裁谁能批)。
--   item_id 是【工资期】的 id,不是申请的 —— 申请没有自己的页面,它住在工资期页上。
-- ★ ROLE-1 Batch 4b(2026-09-25):加一支 receipt_price_request_pending —— 等 CFO 批的收货定价申请
--   (data.view_purchase_prices,Tim 的 Q10:看得见采购价的人都看得见这一格;点进去由
--   decide_receipt_price_request 裁谁能批)。item_id 是【收货】的 id —— 申请住在收货页上。
-- ★ APR-5b(2026-09-25):加两支。shipping_release_pending —— 等 CFO 批的发货放行(module.sales.view:
--   读得到放行的人都看得见这一格;点进去由 decide_shipping_release 裁谁能批);item_id 是【订单】的 id ——
--   放行住在订单页上。shipping_release_ready —— 放行过、还有没发完的订单(action.ship_goods:仓库的信号;
--   剩余与发货队列读同一张 sales_order_line_releasable_all;点进去是 /logistics/shipping)。
-- ★ APR-6(2026-09-25):加一支 journal_request_pending —— 等 CFO 批的手工凭证 / 冲销申请
--   (module.finance.view:读得到凭证的人都看得见这一格;点进去由 decide_journal_request 裁谁能批)。
--   item_id 是【申请】的 id —— 一张手工凭证在批准之前还没有分录,申请住在凭证列表页上(/finance/journal)。
--   subject 是摘要 / 冲销理由(申请没有对手方)。
-- ★ APR-7(2026-09-25):加一支 warehouse_request_pending —— 等 CFO 批的注销 / 回滚 / 证书作废申请
--   (module.finance.view:与 decide_warehouse_request 的门同一个码;点进去由它裁谁能批)。item_id 是【申请】的 id ——
--   申请住在库存页上(/inventory#wr-<id>);subject 是提单人的理由。
-- ★ APR-8(2026-09-26):加一支 terms_request_pending —— 等 CFO 批的定价公式 / 合同生效申请
--   (module.pricing.view:公式页的门,cfo 持;点进去由 decide_terms_request 裁谁能批)。item_id 是【申请】的 id;
--   doc_kind 分开两处住址:formula → 公式列表页(/tools/pricing/formulas#tr-<id>),contract → 合同页(/contracts#tr-<id>)。
--   subject 是提单人的理由。
-- ★ APR-9(2026-09-27):加两支。asset_disposal_pending —— 等 CFO 批的固定资产处置申请(module.finance.view:与
--   decide_asset_disposal_request 的门同一个码;item_id 是【申请】的 id,住在资产页 /finance/assets#adr-<id>)。
--   salary_change_pending —— 等批的调薪申请(data.view_pay:看得见工资的人 —— 财务、CFO、cco;谁能批由
--   decide_salary_change_request 按人裁)。★ item_id 是【员工】的 id:申请住在那个人的档案页
--   (/hr/employees/<id>#salary-requests);item_code 是 label,subject 是提单人的理由。月薪数不进这张视图。
-- ★ APR-10(2026-09-27):加一支 gst_filing_pending —— 等 CFO 批的 GST 申报申请(module.finance.view:与
--   decide_gst_filing_request 的门同一个码)。★ item_id 是【期间】的 id:申请住在那一期的页面上
--   (/finance/gst/<id>#gst-filing);item_code 是 label,subject 是提单人的附言(可空)。
--
-- 【为什么是一张视图而不是九个页面各查各的】仪表盘的每一块牌子背后都是"有多少件
-- 事在等"这一类问题;九个问题九处写,就是九份会各自漂移的实现。hr_alerts 已经证明
-- 过这个形状:一个 UNION,每一种等待状态一支,页面只负责画。
--
-- 【属主权限 + 每支自带 permission 列,外层一次性把关】(OPS-14 修法 (a))。
-- 本视图横跨六个模块,invoker 会让 RLS 把读者无权模块的行【静默丢掉】—— 行消失
-- 在这里意味着"那个数少算了",而不是报错。属主权限读全量,外层
-- WHERE has_permission(a.permission) 按【调用者】逐支裁决:无权的支【整支缺席】,
-- 不是零。谓词写一次而不是九遍 —— hr_alerts 的注释说过,复述 N 遍只会给下一个
-- 加支的人留一个漏写的机会;这里每支【声明】自己的权限码,外层【执行】它。
--
-- 【缺席 ≠ 零,页面必须自己分辨】视图对无权读者不发一行,于是"没有行"有两种
-- 含义:真的零,或者你看不见。app/page.tsx 先查权限再渲染每块牌子 —— 无权显示
-- 「受限」(common.restricted),绝不显示 0。这是仪表盘最容易犯、且任何 gate 都
-- 查不出的那个错(0 与"你看不见"在屏幕上一模一样 —— moduleGuard 的老病换了件衣服)。
--
-- 【item_type 写成 'x'::text 字面量】check-i18n 的 sqlLiteralAs 解析器现读本文件,
-- dashboard.item.* 的后缀集合就是这里的支列表 —— 加一支,键检查自动跟着变宽。
--
-- 【两笔贵的读数,按界所限】(OPS-16 报告点名的两处):
--   * fx_rate_gaps 按 (日期,币种) 对每组跑 fx_rate_asof,本身不受期间约束 ——
--     这里限 rate_date >= CURRENT_DATE - 45:仪表盘答"最近有没有漏",完整历史
--     归 /finance/month-end 按月翻。谓词落在分组键上,能下推进聚合。
--   * 银行对账这支【只数报表侧的未匹配行】(bank_statement_lines,行数 = 导入量,
--     天然有界)。bank_reconciliation_status 的账簿侧 LATERAL 要扫 journal_lines
--     全表 —— 那是对账页的活,不上人人都开的首页。
--
-- 【不在此列的】批次毛利 —— 有未决的设计问题(哪些限定词随数字走、已过账 COGS
-- 还是当前成本),自成一切,谓词已录在 AGENTS.md 常设决定 2。月结的七个信号 ——
-- /finance/month-end 是它们的枢纽,首页放一个入口,不复制信号。
--
-- NOTE: introduced by db/migrations/2026-08-09-ops18-operations-now-and-the-dashboard.sql.
-- EXEC-3a(2026-08-16):再【两】支 —— work_order_overdue 与
-- work_order_variance_beyond(WO-1c 记下的两个候选)。差异那一支的两个阈值
-- 现读 processing_settings,【两个数不是一个】(投入超耗是成本问题、
-- 产出短交是收率问题,合成一个数等于说它们一样严重)。
-- 【本刀一度加了资质那两支,而它们 CMP-2 就已经在了】—— 清单文件里那行
-- "Candidate, not built" 是过时的,重复分支由 fixture 37C 与 30A 当场抓住,
-- fu1 撤掉。见 db/migrations/2026-08-16-exec3a-fu1-*.sql。
-- 【batch_margin 撤了】:一个卖出去的批次毛利偏低是一个【状态】,没有清除动作 ——
-- 看板装的是待办,毛利的家是 /margin;可处理的那一半已经是 arm 15。
--
-- EXEC-1a(2026-08-16):两支高管臂 —— metal_quote_stale(行情陈旧,阈值现读
-- pricing_settings.metal_quote_stale_days,按 price_date 不按 created_at)与
-- orders_unfulfilled(confirmed / partially_shipped 的订单)。规格见
-- docs/dashboard-arm-inventory.md;【谁要看哪一支】见 docs/exec-views-plan.md。
--
-- OPS-19(2026-08-09):补上原始定稿漏掉的四支(awaiting_assay / batch_unpriced /
-- invoice_overdue / ar_over_90 + ap_over_90),并新增 output_unsold_aging —— sales
-- 这一行唯一够得着的支(它没有 module.finance.view,当初猜的 AR 支对它同样是「受限」)。
-- assay_unapplied 的粒度同时从"一份未执行化验一行"改成"一个批次一行",与
-- awaiting_assay 同源同粒度、互斥;live 该支当时为 0,故不改变任何现有数字。
--
-- ── SUP-TYPE-1a(2026-08-18):qualification_missing 收窄到【供货的】供应商 ──
-- EXEC-3a 在 2026-08-16-exec3a-four-executive-arms.sql:349 写着:判据是"一张都没有"
-- 而不是"缺某一类",因为没有一张"谁必须持哪张证"的要求矩阵;并且明写着
-- **"有了'这家需要合规文件'的标记之后,这一支应当收窄到它"**。
-- **那个标记现在有了(suppliers.supplies_goods),这一支已经收窄,那句话到此退休。**
-- 提交信息改不了历史文件,所以退休记录写在这里 —— 沿着引用走过来的人在这里落地。
--
-- 【为什么必须收窄:实测过的永久亮灯】SUP-TYPE-0 把它走了一遍:把一个只收钱、
-- 不供货的往来户沿合法路径推到 status='active',这一支当场亮起、days_waiting 一路
-- 长下去,而它永远不会灭 —— 房东不会去办危废证。收窄之后同样的走法【不再亮】,
-- 而一个没有证书的【真供应商】仍然照亮(fixture 89 两边都钉)。
--
-- CMP-1(2026-08-09):两支资质臂。qualification_expiring 到【类型自己的 lead days】就上牌,
-- 过期后【不落牌、无 -30 天下限】—— 工作证过期 30 天人已走,证书过期两年而进场仍可能,
-- 它就还站在那儿(live 那张 2024 年就过期的 Article 18 正是证据)。续期(valid_until
-- 前移)即安静。qualification_missing 是"一张证都没有"的缺席臂(与 awaiting_assay /
-- assay_unapplied 的分立同理)。disposition='ignore' 的类型不上牌。
-- 【规格在 docs/dashboard-arm-inventory.md】每一支是什么意思、挂哪个权限码、界在
-- 哪里、以及【哪些支被考虑过又被排除、为什么】都在那里。
-- 定稿只存在于一次对话里,代价是四支 —— 所以规矩是:
-- 【加一支 = 在同一个提交里往那份清单加一行】。
--
-- MAR-1(2026-08-10):支的权限从【一个码】放宽到【一个谓词】—— permission(必须有)
-- + permission_any(任意其一,由 arm_permission_any 一处声明,SELECT 与 WHERE 共用)。
-- 起因是批次毛利跨两个模块(prices AND (finance OR processing)),而没有任何 live 角色
-- 同时持有后两者。合成一个新权限码那条路被否掉:那会是谁能看毛利的第二份定义,
-- 与 batch_margin 自己的谓词必然漂开。fixture 45 三种读者各钉一次。
-- ASY-P1(2026-08-17):awaiting_assay 那一支【换了问题】。原来问的是"这个批次一份
-- 化验都没有"(batch_assay_status.assay_count = 0),它看不见"化验做了一半",
-- 也灭不掉料已耗尽那两盏灯(线上 IN-2026-0011 / IN-2026-0153,remaining_qty = 0)。
-- 现在读 batch_required_assay_gaps:物料声明了要验哪些金属、其中至少一种还没有被
-- 一份【已应用的】化验覆盖、并且【还取得到样】。subject 从供应商名换成【缺哪几种
-- 金属】—— subject 这一列在每一支里放的都是那一支最该让人看见的事实,而能让人
-- 下一步动起来的是缺哪几种。判据与理由住在那张视图里,不在这里。
-- LINKS-1(2026-08-11):每支多带一个 item_id —— 支从"指向一张列表"变成"指向那一件事"。
-- 【item_id 指的是谁】承载【补救动作】的那张页面所对应的行。十七支里它就是等待中的
-- 那一行;两支里是它的父:bank_unmatched(行没有页面,匹配动作在对账工作台上 →
-- 对账单)与 margin_cost_not_allocated(补救是给加工单分摊成本 → 加工单)。
-- 于是同一支的几行可以共用一个 item_id,那是对的,不是重复 —— fixture 47 因此断言
-- 的是"item_id 落在这一支该落的那张表里",不是"一行一个 id",也不是互不相同。
-- 【SO-3a:应收也成了两种单据】ar_over_90 的 doc_kind 从此非空('sale' 销售记录 /
-- 'invoice' 订单流发票),item_id 相应二选一 —— 门牌各是应收单据页与发票页,
-- app/page.tsx 按 doc_kind 分支,认不出的种类不给链接(与 ap 同一条)。
-- 【doc_kind 是披露】应付账款本来就是两种单据(ap_open_items 自己就按它分支,
-- 应付列表页也一直照它画链接),这张视图先前只是没说出口。其余十八支主体只有一种,
-- 该列为 NULL。【fx_rate_gap 没有 item_id】它的主体是一条不存在的牌价行,缺的东西
-- 没有 id —— 它指向按币种过滤的列表,那是"诚实过滤的列表"那类答案,不是按码搜索。
-- 每支的门牌与"补救是否在那张页面上"这条判据,写在 docs/dashboard-arm-inventory.md。
-- NOTE: item_id / doc_kind added by
-- db/migrations/2026-08-11-links1-operations-now-item-id.sql(列集变了 → DROP + CREATE)。
-- SS-1(2026-08-13):第二十支 safety_stock_below —— 物料的可用量低于它自己的
-- 安全库存阈值。【阈值 NULL 的物料一次都不响】:NULL 是"还没有人决定要盯它",
-- 不是"阈值为零",而把不响读成"查过了没问题"正是 METAL-1 的那一课。
-- 可用量来自 material_stock_available(一处求和,暂扣不算 —— 阈值问的是"还有多少
-- 能用的货",一次暂扣若能掩盖缺货,这个告警就在最该说话的时刻哑掉)。
-- item_date 用【最后一次库存移动】退回今天:阈值告警是持续状态,没有发生日;
-- 去算"哪天跌破的"要在首页翻整段流水史,那条界不允许(credit_over_limit 同形)。

-- LOG-5a(2026-08-20):第 23–26 支 —— 物流的四支告警。全部是【臂】(算出来、
-- 会自愈),不是 notifications 的事件。末尾的 WHERE 多了一个【放宽】算子
-- arm_permission_widen():它与收窄用的 arm_permission_any() 方向相反,
-- 对除 free_time_expiring 以外的每一支都返回 NULL(fixture 102G 逐支断言)。
-- LOG-5d(2026-08-20):同一种里程碑之内,算数的是【最后被录入】的那一条
-- (recorded_at DESC, id DESC)。此前按 event_date DESC 排,于是一条把日期
-- 改【早】的更正永远排不到前面、一次都不会生效(线上 CTR-2026-0009)。
-- EQP-2c(2026-08-21):第 27–28 支 —— 保养【到期】与【将到期】,两支不是一支。
-- 列契约一字未动。规格见 docs/dashboard-arm-inventory.md;推导与它的基线
-- (那两条"低读数有两种意思"的事实)整段写在 equipment_service_status 的视图注释里。
-- 【放宽】两支都走 arm_permission_widen(processing OR finance)—— 机器卡在财务、
-- 干活的人在加工,而它们底下每一张表/视图的读者都是这两个码的 OR。
-- CMPL-1(2026-08-30)追加两支:
--   · company_licence_expiring —— **形状逐字取自 qualification_expiring**,只是把
--     supplier_compliance 换成 company_compliance(少一跳供应商)。它读的仍是
--     certificate_types 自带的 warn_lead_days 与 disposition,所以 gwc 加进字典那天
--     它的到期提醒【自动就有】。**没有另起一套到期机制。**
--   · import_permit_unverified —— 是进口货、而那张进口准证还没有人核过。
--     **它不拦任何东西**:拦的那一半由 nea_import 的 block 处置在收货上做
--     (supplier_receiving_blocked → trg_inbound_batches_po_receivable),
--     这一支说的是"这一票还欠一次人工核对"。理由见 db/tables/inbound_batches.sql 的列注。
-- MES-1(2026-10-06,MES-1 Step 0 Q16 · Q17 · Q23,Tim):第 48–49 支 ——
--   · gateway_silent:一台网关此刻在沉默 —— 它的心跳间隔给了,而最后一次听到它已经超过那个间隔(gateway_health.status = silent)。
--     一次都没听到过的("Not yet heard from")与间隔没给的("Not yet set")【不上牌】:前者是还没调试的正常状态(Q16),
--     后者是沉默无从判断(Q17)。item_id = 那台网关(/operation/devices/[id])。
--   · capture_inbox_failed:收件箱里有转换失败的行 —— 按设备合成一块(item_id = 设备,subject = 设备名 · 失败行数,
--     item_date = 最早的那一行)。不为 awaiting_transform 上牌:那是每一个还没接上转换器的类的正常状态(Q23)。
--   两支都只要 module.processing.view;规格在 docs/dashboard-arm-inventory.md。
-- MES-2(2026-10-06,MES-0 Q13;MES-2 Step 0 Q29 · Q32,Tim):第 50–52 支 ——
--   · capture_draft_pending:一张网关送来的草稿还没人确认 —— 一张一行,item_date = 落草稿那一天,所以 days_waiting 就是它的年龄
--     (草稿永不过期,MES-0 Q13)。门是 action.confirm_capture(能确认它的人才需要被催)。手工录入的草稿生下来就确认了,不上牌。
--   · instrument_calibration_due:一台【在用的】仪器(interface_status 不是 reserved,没停用)今天不在校准期内 —— 过期、没通过、
--     或从来没校过。item_date = 有效期(从来没校过的取它登记那一天)。
--   · instrument_calibration_approaching:在期内、有效期落在 V8 给的提前天数里。V8(calibration_lead_days)没给 → 这一支恒为空,
--     过期本身照样由上一支上牌(每一条记录自己的有效期是必填的)。
--   后两支读 instrument_calibration_now(属主视图,一份挑法、一句判据),门是 module.processing.view。
-- MES-3a(2026-10-06,MES-0 Q13 · Q35 · Q34;MES-3a Step 0 Q13 · Q16 · Q20,Tim):第 53–55 支 —— 三支都【只提醒,不拒】——
--   · storage_ceiling_exceeded:今天在效的执照下,一类 NEA 废物(或总量)的存量超过了给了的上限(storage_ceiling_status.status = exceeded)。
--     收货在超之前就被拒了,所以走到这里的是别的路:加工把料变成了另一类、回滚还回了料、上限被调低了。item_id = 执照,
--     item_code = 类别(总量是 *),门 module.inventory.view。
--   · safety_state_dwell:一批还在厂里的货,身上一条开着的状态待满了它的 dwell_warning_days(V3;没给的不上牌)。
--     一批 × 一条状态一行;item_date = 那条状态被记下的那一天,所以 days_waiting 就是它待了多久。doc_kind = inbound / output,
--     门逐行:进料 module.inbound.view,产出 module.output.view。
--   · quarantine_required:一批身上开着一条要隔离的状态(鼓包或漏液),却还有货放在非隔离库位(quarantine_exposure)。
--     一批 × 一个库位桶一行;doc_kind 与门同上;item_date = 那条状态被记下的那一天。
CREATE OR REPLACE VIEW public.operations_now AS
 SELECT item_type,
    permission,
    arm_permission_any(item_type) AS permission_any,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM ( SELECT 'awaiting_assay'::text AS item_type,
            'module.inbound.view'::text AS permission,
            g.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            g.batch_code AS item_code,
            array_to_string(g.missing_metals, ', '::text) AS subject,
            g.arrival_date AS item_date
           FROM batch_required_assay_gaps g
          WHERE g.sampleable
        UNION ALL
         SELECT 'assay_unapplied'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.latest_assay_code AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.has_unapplied_assay
        UNION ALL
         SELECT 'batch_unpriced'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.pricing_status = 'unpriced'::text
        UNION ALL
         SELECT 'allocation_stale'::text AS item_type,
            'module.processing.view'::text AS permission,
            s.run_id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            NULL::text AS subject,
            s.last_cost_change::date AS item_date
           FROM processing_run_allocation_status s
          WHERE s.is_stale OR s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL
        UNION ALL
         SELECT 'po_awaiting_receipt'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.id AS item_id,
            NULL::text AS doc_kind,
            po.code AS item_code,
            po.status AS subject,
            po.order_date AS item_date
           FROM purchase_orders po
          WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
        UNION ALL
         SELECT 'stocktake_open'::text AS item_type,
            'module.stocktakes.view'::text AS permission,
            st.id AS item_id,
            NULL::text AS doc_kind,
            st.code AS item_code,
            NULL::text AS subject,
            st.started_at::date AS item_date
           FROM stocktakes st
          WHERE st.deleted_at IS NULL AND st.status = 'open'::text
        UNION ALL
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_1.id AS item_id,
            NULL::text AS doc_kind,
            s_1.code AS item_code,
            (ct.name_en || ' — '::text) || s_1.legal_name AS subject,
            sc.valid_until AS item_date
           FROM supplier_compliance sc
             JOIN certificate_types ct ON ct.code = sc.cert_type_code
             JOIN suppliers s_1 ON s_1.id = sc.supplier_id
          WHERE sc.deleted_at IS NULL AND s_1.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND sc.valid_until IS NOT NULL AND sc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'qualification_missing'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_2.id AS item_id,
            NULL::text AS doc_kind,
            s_2.code AS item_code,
            s_2.legal_name AS subject,
            s_2.created_at::date AS item_date
           FROM suppliers s_2
          WHERE s_2.deleted_at IS NULL AND s_2.supplies_goods AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
                   FROM supplier_compliance sc2
                  WHERE sc2.supplier_id = s_2.id AND sc2.deleted_at IS NULL))
        UNION ALL
         SELECT 'credit_over_limit'::text AS item_type,
            'module.customers.view'::text AS permission,
            c_1.id AS item_id,
            NULL::text AS doc_kind,
            c_1.code AS item_code,
            c_1.legal_name AS subject,
            COALESCE(( SELECT min(sr.sale_date) AS min
                   FROM sales_records sr
                  WHERE sr.customer_id = c_1.id), CURRENT_DATE) AS item_date
           FROM customers c_1
          WHERE c_1.deleted_at IS NULL AND c_1.credit_limit_base IS NOT NULL AND customer_ar_exposure_visible(c_1.id) >= c_1.credit_limit_base
        UNION ALL
         SELECT 'output_unsold_aging'::text AS item_type,
            'module.output.view'::text AS permission,
            ob.id AS item_id,
            NULL::text AS doc_kind,
            ob.code AS item_code,
            ob.state AS subject,
            COALESCE(ob.output_date, ob.created_at::date) AS item_date
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0::numeric AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
        UNION ALL
         SELECT 'safety_stock_below'::text AS item_type,
            'module.inventory.view'::text AS permission,
            msa.material_id AS item_id,
            NULL::text AS doc_kind,
            msa.code AS item_code,
            (((((trim_scale(msa.available_qty)::text || ' / '::text) || trim_scale(msa.safety_stock_qty)::text) || ' '::text) || COALESCE(msa.unit, ''::text)) || ' — short '::text) || trim_scale(msa.safety_stock_qty - msa.available_qty)::text AS subject,
            COALESCE(msa.last_movement_date, CURRENT_DATE) AS item_date
           FROM material_stock_available msa
          WHERE msa.safety_stock_qty IS NOT NULL AND msa.available_qty < msa.safety_stock_qty
        UNION ALL
         SELECT 'leave_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            lr.id AS item_id,
            NULL::text AS doc_kind,
            lr.code AS item_code,
            e.legal_name AS subject,
            lr.created_at::date AS item_date
           FROM leave_requests lr
             JOIN employees e ON e.id = lr.employee_id
          WHERE lr.status = 'pending'::text AND lr.deleted_at IS NULL
        UNION ALL
         SELECT 'claim_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            mc.id AS item_id,
            NULL::text AS doc_kind,
            mc.code AS item_code,
            e.legal_name AS subject,
            mc.created_at::date AS item_date
           FROM medical_claims mc
             JOIN employees e ON e.id = mc.employee_id
          WHERE mc.status = 'submitted'::text AND mc.deleted_at IS NULL
        UNION ALL
         SELECT 'review_submitted'::text AS item_type,
            'module.hr.view'::text AS permission,
            r.id AS item_id,
            NULL::text AS doc_kind,
            e.code AS item_code,
            e.legal_name AS subject,
            COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
          WHERE r.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            i.invoice_id AS item_id,
            NULL::text AS doc_kind,
            i.code AS item_code,
            i.customer_name AS subject,
            i.due_date AS item_date
           FROM invoice_status i
          WHERE i.overdue
        UNION ALL
         SELECT 'ar_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            COALESCE(ar.sales_record_id, ar.invoice_id) AS item_id,
            ar.doc_kind,
            ar.doc_code AS item_code,
            ar.customer_name AS subject,
            ar.sale_date AS item_date
           FROM ar_open_items ar
          WHERE ar.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'ap_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ap.doc_id AS item_id,
            ap.doc_kind,
            ap.doc_code AS item_code,
            ap.supplier_name AS subject,
            ap.doc_date AS item_date
           FROM ap_open_items ap
          WHERE ap.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'fx_rate_gap'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            g.currency AS item_code,
            array_to_string(g.missing_types, ', '::text) AS subject,
            g.rate_date AS item_date
           FROM fx_rate_gaps g
          WHERE g.rate_date >= (CURRENT_DATE - 45)
        UNION ALL
         SELECT 'bank_unmatched'::text AS item_type,
            'module.finance.view'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.bank_account_code AS item_code,
            s.code AS subject,
            l.line_date AS item_date
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE l.match_status = 'unmatched'::text AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'margin_cost_not_allocated'::text AS item_type,
            'data.view_prices'::text AS permission,
            bm.run_id AS item_id,
            NULL::text AS doc_kind,
            bm.batch_code AS item_code,
            bm.material_name AS subject,
            ob.output_date AS item_date
           FROM batch_margin bm
             JOIN output_batches ob ON ob.id = bm.output_batch_id
          WHERE bm.margin_status = 'no_unit_cost'::text
        UNION ALL
         SELECT 'metal_quote_stale'::text AS item_type,
            'module.pricing.view'::text AS permission,
            mp.latest_id AS item_id,
            NULL::text AS doc_kind,
            mp.metal AS item_code,
            mp.latest_price::text AS subject,
            mp.max_date AS item_date
           FROM ( SELECT p.metal,
                    max(p.price_date) AS max_date,
                    (array_agg(p.id ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_id,
                    (array_agg(p.price_usd_per_tonne ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_price
                   FROM metal_prices p
                  WHERE p.deleted_at IS NULL
                  GROUP BY p.metal) mp
          WHERE (CURRENT_DATE - mp.max_date) > (( SELECT ps.metal_quote_stale_days
                   FROM pricing_settings ps
                 LIMIT 1))
        UNION ALL
         SELECT 'orders_unfulfilled'::text AS item_type,
            'module.sales.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            so.status AS subject,
            so.order_date AS item_date
           FROM sales_orders so
          WHERE so.deleted_at IS NULL AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
        UNION ALL
         SELECT 'work_order_overdue'::text AS item_type,
            'module.processing.view'::text AS permission,
            w.id AS item_id,
            NULL::text AS doc_kind,
            w.code AS item_code,
            w.scheduled_date::text AS subject,
            w.scheduled_date AS item_date
           FROM work_orders w
          WHERE w.status = 'released'::text AND w.scheduled_date IS NOT NULL AND w.scheduled_date < CURRENT_DATE
        UNION ALL
         SELECT 'work_order_variance_beyond'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.work_order_id AS item_id,
            NULL::text AS doc_kind,
            f.work_order_code AS item_code,
                CASE
                    WHEN f.side = 'input'::text THEN (((('input overrun · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                    ELSE (((('output shortfall · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                END AS subject,
            COALESCE(w2.scheduled_date, w2.created_at::date) AS item_date
           FROM work_order_fulfilment f
             JOIN work_orders w2 ON w2.id = f.work_order_id
          WHERE f.has_plan AND f.planned_or_expected_qty > 0::numeric AND (f.side = 'input'::text AND (w2.status = ANY (ARRAY['released'::text, 'closed'::text])) AND f.actual_qty > (f.planned_or_expected_qty * (1::numeric + (( SELECT ps.wo_input_overrun_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)) OR f.side = 'output'::text AND w2.status = 'closed'::text AND f.actual_qty < (f.planned_or_expected_qty * (1::numeric - (( SELECT ps.wo_output_shortfall_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)))
        UNION ALL
         SELECT 'free_time_expiring'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            ((((q.free_days - (CURRENT_DATE - arr.event_date))::text) || ' left of '::text) || q.free_days::text) || COALESCE(' — '::text || f.legal_name, ''::text) AS subject,
            arr.event_date AS item_date
           FROM containers c
             LEFT JOIN suppliers f ON f.id = c.forwarder_id
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'arrived'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) arr ON true
             JOIN forwarder_rate_quotes q ON q.supplier_id = c.forwarder_id AND q.lane_id = c.lane_id AND q.deleted_at IS NULL AND c.departure_date >= q.valid_from AND c.departure_date <= q.valid_to
          WHERE c.deleted_at IS NULL AND q.free_days IS NOT NULL AND (q.free_days - (CURRENT_DATE - arr.event_date)) <= 2
        UNION ALL
         SELECT 'container_no_arrival'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            dep.event_date::text AS subject,
            dep.event_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'departed'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) dep ON true
          WHERE c.deleted_at IS NULL AND (CURRENT_DATE - dep.event_date) >= 14 AND NOT (EXISTS ( SELECT 1
                   FROM container_milestones m2
                  WHERE m2.container_id = c.id AND m2.milestone = 'arrived'::text))
        UNION ALL
         SELECT 'container_eta_overdue'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            c.expected_arrival_date::text AS subject,
            c.expected_arrival_date AS item_date
           FROM containers c
          WHERE c.deleted_at IS NULL AND c.expected_arrival_date IS NOT NULL AND c.expected_arrival_date < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
                   FROM container_milestones m3
                  WHERE m3.container_id = c.id AND m3.milestone = 'arrived'::text))
        UNION ALL
         SELECT 'container_documents_late'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            p.n::text || ' pending'::text AS subject,
            c.departure_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT count(*) AS n
                   FROM container_documents d
                  WHERE d.container_id = c.id AND d.status = 'pending'::text) p ON true
          WHERE c.deleted_at IS NULL AND p.n > 0 AND (CURRENT_DATE - c.departure_date) >= 7
        UNION ALL
         SELECT 'equipment_service_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess.equipment_code AS item_code,
            (ess.service_kind || ' — '::text) || ess.equipment_description AS subject,
            ess.baseline_date AS item_date
           FROM equipment_service_status ess
          WHERE ess.monitored AND ess.disposition = 'warn'::text AND ess.equipment_status <> 'disposed'::text AND ess.is_due
        UNION ALL
         SELECT 'equipment_service_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess_1.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess_1.equipment_code AS item_code,
            (ess_1.service_kind || ' — '::text) || ess_1.equipment_description AS subject,
            ess_1.baseline_date AS item_date
           FROM equipment_service_status ess_1
          WHERE ess_1.monitored AND ess_1.disposition = 'warn'::text AND ess_1.equipment_status <> 'disposed'::text AND ess_1.is_approaching
        UNION ALL
         SELECT 'gateway_silent'::text AS item_type,
            'module.processing.view'::text AS permission,
            gh.gateway_id AS item_id,
            NULL::text AS doc_kind,
            gh.code AS item_code,
            gh.name AS subject,
            gh.last_heard_at::date AS item_date
           FROM gateway_health gh
          WHERE gh.status = 'silent'::text
        UNION ALL
         SELECT 'capture_inbox_failed'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.device_id AS item_id,
            NULL::text AS doc_kind,
            f.device_code AS item_code,
            (f.device_name || ' · '::text) || f.failed_rows::text AS subject,
            f.first_failed AS item_date
           FROM ( SELECT b.device_id,
                    d.code AS device_code,
                    d.name AS device_name,
                    count(*) AS failed_rows,
                    min(b.received_at)::date AS first_failed
                   FROM ingest_inbox b
                     JOIN devices d ON d.id = b.device_id
                  WHERE b.status = 'failed'::text
                  GROUP BY b.device_id, d.code, d.name) f
        UNION ALL
         SELECT 'capture_draft_pending'::text AS item_type,
            'action.confirm_capture'::text AS permission,
            cd.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(dv.code, cd.data_class) AS item_code,
            (COALESCE(dv.name, cd.data_class) || ' · '::text) || COALESCE((cd.proposed ->> 'weight_kg'::text) || ' kg'::text, cd.data_class) AS subject,
            cd.created_at::date AS item_date
           FROM capture_drafts cd
             LEFT JOIN devices dv ON dv.id = cd.device_id
          WHERE cd.status = 'pending'::text
        UNION ALL
         SELECT 'instrument_calibration_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ic.device_id AS item_id,
            NULL::text AS doc_kind,
            ic.code AS item_code,
            (ic.name || ' · '::text) || ic.status AS subject,
            COALESCE(ic.valid_until, ic.registered_at::date) AS item_date
           FROM instrument_calibration_now ic
          WHERE ic.in_use AND ic.status <> 'in_calibration'::text
        UNION ALL
         SELECT 'instrument_calibration_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ic.device_id AS item_id,
            NULL::text AS doc_kind,
            ic.code AS item_code,
            ic.name AS subject,
            ic.valid_until AS item_date
           FROM instrument_calibration_now ic
          WHERE ic.in_use AND ic.approaching
        UNION ALL
         SELECT 'storage_ceiling_exceeded'::text AS item_type,
            'module.inventory.view'::text AS permission,
            sc.licence_id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(sc.category_code, '*'::text) AS item_code,
            (((sc.cert_no || ' · '::text) || sc.name_en) || ' · '::text) || round(sc.on_hand_t, 3)::text || ' / '::text || sc.limit_tonnes::text || ' t'::text AS subject,
            (now() AT TIME ZONE 'Asia/Singapore'::text)::date AS item_date
           FROM storage_ceiling_status sc
          WHERE sc.status = 'exceeded'::text
        UNION ALL
         SELECT 'safety_state_dwell'::text AS item_type,
                CASE dw.batch_kind
                    WHEN 'inbound'::text THEN 'module.inbound.view'::text
                    ELSE 'module.output.view'::text
                END AS permission,
            dw.batch_id AS item_id,
            dw.batch_kind AS doc_kind,
            dw.batch_code AS item_code,
            dw.name_en AS subject,
            dw.recorded_on AS item_date
           FROM safety_state_dwell dw
          WHERE dw.dwell_status = 'past'::text AND dw.on_site
        UNION ALL
         SELECT 'quarantine_required'::text AS item_type,
                CASE qe.batch_kind
                    WHEN 'inbound'::text THEN 'module.inbound.view'::text
                    ELSE 'module.output.view'::text
                END AS permission,
            qe.batch_id AS item_id,
            qe.batch_kind AS doc_kind,
            qe.batch_code AS item_code,
            (qe.name_en || ' · '::text) || COALESCE(qe.location_code, 'unspecified'::text) AS subject,
            qe.recorded_on AS item_date
           FROM quarantine_exposure qe
        UNION ALL
         SELECT 'promise_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            ps.promise_id AS item_id,
            NULL::text AS doc_kind,
            ps.chase_code AS item_code,
            ps.customer_name AS subject,
            ps.promised_date AS item_date
           FROM collection_promise_status ps
          WHERE ps.is_overdue
        UNION ALL
         SELECT 'wht_due'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            to_char(w.period_month::timestamp without time zone, 'YYYY-MM'::text) AS item_code,
            (to_char(w.unremitted_base, 'FM999G999G990D00'::text) || ' '::text) || (( SELECT c.code
                   FROM currencies c
                  WHERE c.is_base)) AS subject,
            w.due_date AS item_date
           FROM wht_liability_by_month w
          WHERE w.unremitted_base > 0::numeric AND (w.due_date - CURRENT_DATE) <= 7
        UNION ALL
         SELECT 'company_licence_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            cc.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(cc.cert_no, ct.code) AS item_code,
            ct.name_en AS subject,
            cc.valid_until AS item_date
           FROM company_compliance cc
             JOIN certificate_types ct ON ct.code = cc.cert_type_code
          WHERE cc.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND cc.valid_until IS NOT NULL AND cc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'import_permit_unverified'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            ib.code AS item_code,
            s.legal_name AS subject,
            ib.arrival_date AS item_date
           FROM inbound_batches ib
             JOIN suppliers s ON s.id = ib.supplier_id
          WHERE ib.deleted_at IS NULL AND ib.imported IS TRUE AND ib.import_permit_verified_at IS NULL
        UNION ALL
         SELECT 'payment_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            pr.id AS item_id,
            NULL::text AS doc_kind,
            pr.code AS item_code,
            COALESCE(s.legal_name, e.legal_name, c.legal_name) AS subject,
            pr.created_at::date AS item_date
           FROM payment_requests pr
             LEFT JOIN suppliers s ON s.id = pr.supplier_id
             LEFT JOIN employees e ON e.id = pr.employee_id
             LEFT JOIN customers c ON c.id = pr.customer_id
          WHERE pr.status = 'submitted'::text
        UNION ALL
         SELECT 'supplier_pending_approval'::text AS item_type,
            'action.supplier_approve'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            s.legal_name AS subject,
            COALESCE(( SELECT max(h.changed_at) AS max
                   FROM supplier_status_history h
                  WHERE h.supplier_id = s.id AND h.to_status = 'pending_review'::text), s.updated_at)::date AS item_date
           FROM suppliers s
          WHERE s.status = 'pending_review'::supplier_status AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'payroll_request_pending'::text AS item_type,
            'data.view_pay'::text AS permission,
            q.payroll_period_id AS item_id,
            NULL::text AS doc_kind,
            q.label AS item_code,
            pp.code AS subject,
            q.created_at::date AS item_date
           FROM payroll_requests q
             JOIN payroll_periods pp ON pp.id = q.payroll_period_id
          WHERE q.status = 'submitted'::text
        UNION ALL
         SELECT 'receipt_price_request_pending'::text AS item_type,
            'data.view_purchase_prices'::text AS permission,
            rq.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            rq.label AS item_code,
            ib.code AS subject,
            rq.created_at::date AS item_date
           FROM receipt_price_requests rq
             JOIN inbound_batches ib ON ib.id = rq.inbound_batch_id
          WHERE rq.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            iq.invoice_id AS item_id,
            NULL::text AS doc_kind,
            iq.label AS item_code,
            c.legal_name AS subject,
            iq.created_at::date AS item_date
           FROM invoice_requests iq
             JOIN invoices i ON i.id = iq.invoice_id
             JOIN customers c ON c.id = i.customer_id
          WHERE iq.status = 'submitted'::text
        UNION ALL
         SELECT 'shipping_release_pending'::text AS item_type,
            'module.sales.view'::text AS permission,
            sr.sales_order_id AS item_id,
            NULL::text AS doc_kind,
            sr.label AS item_code,
            c.legal_name AS subject,
            sr.created_at::date AS item_date
           FROM shipping_releases sr
             JOIN sales_orders so ON so.id = sr.sales_order_id
             JOIN customers c ON c.id = so.customer_id
          WHERE sr.status = 'submitted'::text
        UNION ALL
         SELECT 'journal_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            jq.id AS item_id,
            NULL::text AS doc_kind,
            jq.label AS item_code,
            jq.memo AS subject,
            jq.created_at::date AS item_date
           FROM journal_requests jq
          WHERE jq.status = 'submitted'::text
        UNION ALL
         SELECT 'warehouse_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            wq.id AS item_id,
            NULL::text AS doc_kind,
            wq.label AS item_code,
            wq.reason AS subject,
            wq.created_at::date AS item_date
           FROM warehouse_requests wq
          WHERE wq.status = 'submitted'::text
        UNION ALL
         SELECT 'terms_request_pending'::text AS item_type,
            'module.pricing.view'::text AS permission,
            tq.id AS item_id,
                CASE
                    WHEN tq.contract_id IS NOT NULL THEN 'contract'::text
                    ELSE 'formula'::text
                END AS doc_kind,
            tq.label AS item_code,
            tq.reason AS subject,
            tq.created_at::date AS item_date
           FROM terms_requests tq
          WHERE tq.status = 'submitted'::text
        UNION ALL
         SELECT 'asset_disposal_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            dq.id AS item_id,
            NULL::text AS doc_kind,
            dq.label AS item_code,
            dq.reason AS subject,
            dq.created_at::date AS item_date
           FROM asset_disposal_requests dq
          WHERE dq.status = 'submitted'::text
        UNION ALL
         SELECT 'salary_change_pending'::text AS item_type,
            'data.view_pay'::text AS permission,
            sq.employee_id AS item_id,
            NULL::text AS doc_kind,
            sq.label AS item_code,
            sq.reason AS subject,
            sq.created_at::date AS item_date
           FROM salary_change_requests sq
          WHERE sq.status = 'submitted'::text
        UNION ALL
         SELECT 'gst_filing_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            gq.period_id AS item_id,
            NULL::text AS doc_kind,
            gq.label AS item_code,
            gq.note AS subject,
            gq.created_at::date AS item_date
           FROM gst_filing_requests gq
          WHERE gq.status = 'submitted'::text
        UNION ALL
         SELECT 'processing_balance_unclosed'::text AS item_type,
            'module.processing.view'::text AS permission,
            b.run_id AS item_id,
            NULL::text AS doc_kind,
            b.run_code AS item_code,
            b.operation_type_code AS subject,
            b.process_date AS item_date
           FROM processing_run_balance_all b
          WHERE b.balance_state = 'open'::text
        UNION ALL
         SELECT 'contamination_check_missing'::text AS item_type,
            'module.processing.view'::text AS permission,
            cs.first_run_id AS item_id,
            NULL::text AS doc_kind,
            cs.first_run_code AS item_code,
            cs.stream_code AS subject,
            cs.process_date AS item_date
           FROM contamination_shift_status_all cs
          WHERE cs.check_state = 'missing'::text
        UNION ALL
         SELECT 'discharge_unverified'::text AS item_type,
            'module.processing.view'::text AS permission,
            ds.latest_run_id AS item_id,
            NULL::text AS doc_kind,
            ds.latest_run_code AS item_code,
            ds.batch_code AS subject,
            ds.latest_run_date AS item_date
           FROM discharge_batch_status_all ds
          WHERE ds.latest_run_id IS NOT NULL AND NOT ds.currently_verified
        UNION ALL
         SELECT 'discharge_quarantine_pending'::text AS item_type,
            'module.processing.view'::text AS permission,
            ds.latest_run_id AS item_id,
            NULL::text AS doc_kind,
            ds.latest_run_code AS item_code,
            ds.batch_code AS subject,
            ds.latest_run_date AS item_date
           FROM discharge_batch_status_all ds
          WHERE ds.failed_quarantine > 0 AND ds.latest_run_id IS NOT NULL
        UNION ALL
         SELECT 'shipping_release_ready'::text AS item_type,
            'action.ship_goods'::text AS permission,
            q.sales_order_id AS item_id,
            NULL::text AS doc_kind,
            q.order_code AS item_code,
            q.customer_name AS subject,
            q.released_on AS item_date
           FROM ( SELECT so.id AS sales_order_id,
                    so.code AS order_code,
                    c.legal_name AS customer_name,
                    max(r.decided_at)::date AS released_on
                   FROM shipping_releases r
                     JOIN shipping_release_lines rl ON rl.release_id = r.id
                     JOIN invoice_lines il ON il.id = rl.invoice_line_id
                     JOIN sales_orders so ON so.id = r.sales_order_id
                     JOIN customers c ON c.id = so.customer_id
                  WHERE r.status = 'approved'::text AND NOT il.invoice_voided
                    AND so.deleted_at IS NULL
                    AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
                    AND (( SELECT ra.releasable_qty
                           FROM sales_order_line_releasable_all ra
                          WHERE ra.invoice_line_id = il.id)) > COALESCE(( SELECT sum(sl.qty) AS sum
                           FROM shipment_lines sl
                          WHERE sl.sales_order_line_id = rl.sales_order_line_id), 0::numeric)
                  GROUP BY so.id, so.code, c.legal_name) q
        UNION ALL
         SELECT 'sample_retention_due'::text AS item_type,
            'module.quality.view'::text AS permission,
            sr.id AS item_id,
            NULL::text AS doc_kind,
            sr.code AS item_code,
            sr.batch_code AS subject,
            sr.retain_until AS item_date
           FROM ( SELECT s.id,
                    s.code,
                    COALESCE(ib.code, ob.code) AS batch_code,
                    s.retain_until
                   FROM samples s
                     LEFT JOIN inbound_batches ib ON ib.id = s.inbound_batch_id
                     LEFT JOIN output_batches ob ON ob.id = s.output_batch_id
                  WHERE s.retain_until IS NOT NULL AND s.retain_until < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
                           FROM sample_events e
                          WHERE e.sample_id = s.id AND e.event_kind = 'disposed'::text))) sr
        UNION ALL
         SELECT 'assay_dispute_open'::text AS item_type,
            'module.quality.view'::text AS permission,
            d.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(ib.code, ob.code) AS item_code,
            (ao.code || ' / '::text) || ac.code AS subject,
            d.created_at::date AS item_date
           FROM assay_disputes d
             LEFT JOIN inbound_batches ib ON ib.id = d.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = d.output_batch_id
             JOIN assay_results ao ON ao.id = d.our_assay_id
             JOIN assay_results ac ON ac.id = d.counterparty_assay_id
          WHERE d.status = 'open'::text
        UNION ALL
         SELECT 'assay_results_disagree'::text AS item_type,
            'module.quality.view'::text AS permission,
            ad.output_batch_id AS item_id,
            NULL::text AS doc_kind,
            ad.batch_code AS item_code,
            ad.sales_order_code AS subject,
            ad.latest_assay_date AS item_date
           FROM assay_disagreements_all ad) a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type))) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));;

GRANT SELECT ON public.operations_now TO authenticated;

-- ── 10 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.quality_settings
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.quality_settings
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.samples
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.samples
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.sample_events
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.sample_events
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.assay_disputes
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.assay_disputes
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 11 · 授权(MES-0 Q90 · MES-6a Step 0 Q11 · Q12):查看 → admin · cco · cfo · cto · finance · warehouse;编辑 → admin · cco · cto —— 本刀唯一的授权改动 ──
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'module.quality.view' FROM roles r WHERE r.code IN ('admin', 'cco', 'cfo', 'cto', 'finance', 'warehouse')
ON CONFLICT (role_id, permission_code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'module.quality.edit' FROM roles r WHERE r.code IN ('admin', 'cco', 'cto')
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 12 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.record_sample(text, date, uuid, uuid, numeric, uuid, bigint, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_sample(text, date, uuid, uuid, numeric, uuid, bigint, uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_sample_event(uuid, text, timestamp with time zone, text, text, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_sample_event(uuid, text, timestamp with time zone, text, text, uuid, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.set_quality_settings(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_quality_settings(integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.open_assay_dispute(uuid, uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.open_assay_dispute(uuid, uuid, text, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_dispute_umpire(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_dispute_umpire(uuid, uuid, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.withdraw_assay_dispute(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.withdraw_assay_dispute(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.resolve_assay_dispute(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_assay_dispute(uuid, uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.link_dispute_fee(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.link_dispute_fee(uuid, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.next_sample_code(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.next_sample_code(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_assay_sample_batch() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_assay_sample_batch() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_assay_sample_batch() FROM authenticated;

-- ── 13 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes6a1_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes6a1_pending_after ON COMMIT DROP AS
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
    -- ① 授权:恰好多了那九行质量码,别的一行没动;admin 持目录里每一个码;每一个角色仍满足"动作码蕴含查看码"
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes6a1_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM mes6a1_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS DISTINCT FROM 'admin:module.quality.edit, admin:module.quality.view, cco:module.quality.edit, cco:module.quality.view, cfo:module.quality.view, cto:module.quality.edit, cto:module.quality.view, finance:module.quality.view, warehouse:module.quality.view' THEN
        RAISE EXCEPTION 'MES6A1_PROOF|grant change is not exactly the nine quality grants: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM permissions) <> 77
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES6A1_PROOF|admin does not hold every one of the 77 codes';
    END IF;
    IF NOT (SELECT 'module.quality.view' = ANY (requires_view_any) FROM permissions WHERE code = 'action.apply_assay') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|action.apply_assay must declare module.quality.view';
    END IF;
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6A1_PROOF|action-implies-view violated: %', v_bad; END IF;
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code LIKE '%.edit'
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = replace(rp.permission_code, '.edit', '.view'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6A1_PROOF|edit-implies-view violated: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES6A1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes6a1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes6a1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES6A1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变(新加的列在比对时从两边减掉)
    IF EXISTS ((SELECT b.k, b.id FROM mes6a1_pending_before b EXCEPT SELECT a.k, a.id FROM mes6a1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes6a1_pending_after a EXCEPT SELECT b.k, b.id FROM mes6a1_pending_before b)) THEN
        RAISE EXCEPTION 'MES6A1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'sample_id')::text, '|' ORDER BY (to_jsonb(t) - 'sample_id')::text), '')) FROM assay_results t) IS DISTINCT FROM (SELECT assay_results FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_result_metals t) IS DISTINCT FROM (SELECT assay_result_metals FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t) IS DISTINCT FROM (SELECT inbound_batches FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t) IS DISTINCT FROM (SELECT output_batches FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batch_metals t) IS DISTINCT FROM (SELECT inbound_batch_metals FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batch_metals t) IS DISTINCT FROM (SELECT output_batch_metals FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM receipt_price_requests t) IS DISTINCT FROM (SELECT receipt_price_requests FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM price_history t) IS DISTINCT FROM (SELECT price_history FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t) IS DISTINCT FROM (SELECT journal_entries FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t) IS DISTINCT FROM (SELECT journal_lines FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'reversal_reason' - 'reversed_at' - 'reversed_by')::text, '|' ORDER BY (to_jsonb(t) - 'reversal_reason' - 'reversed_at' - 'reversed_by')::text), '')) FROM expenses t) IS DISTINCT FROM (SELECT expenses FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t) IS DISTINCT FROM (SELECT payments FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_allocations t) IS DISTINCT FROM (SELECT payment_allocations FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_requests t) IS DISTINCT FROM (SELECT payment_requests FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contracts t) IS DISTINCT FROM (SELECT contracts FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'arbitration_fee_rule')::text, '|' ORDER BY (to_jsonb(t) - 'arbitration_fee_rule')::text), '')) FROM contract_settlement_terms t) IS DISTINCT FROM (SELECT contract_settlement_terms FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_document_terms t) IS DISTINCT FROM (SELECT contract_document_terms FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'supplier_id')::text, '|' ORDER BY (to_jsonb(t) - 'supplier_id')::text), '')) FROM laboratories t) IS DISTINCT FROM (SELECT laboratories FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_orders t) IS DISTINCT FROM (SELECT sales_orders FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_settlements t) IS DISTINCT FROM (SELECT sales_settlements FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM electricity_allocations t) IS DISTINCT FROM (SELECT electricity_allocations FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM electricity_allocation_reversals t) IS DISTINCT FROM (SELECT electricity_allocation_reversals FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expense_claims t) IS DISTINCT FROM (SELECT expense_claims FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM medical_claims t) IS DISTINCT FROM (SELECT medical_claims FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t) IS DISTINCT FROM (SELECT suppliers FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM storage_locations t) IS DISTINCT FROM (SELECT storage_locations FROM mes6a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contamination_checks t) IS DISTINCT FROM (SELECT contamination_checks FROM mes6a1_rows_before) THEN
        RAISE EXCEPTION 'MES6A1_PROOF|a pre-existing assay, batch, content, request, price, journal, expense, payment, contract, laboratory, sales order, settlement, allocation, claim, supplier, location or check changed';
    END IF;
    IF EXISTS (SELECT 1 FROM laboratories WHERE supplier_id IS NOT NULL) OR EXISTS (SELECT 1 FROM contract_settlement_terms WHERE arbitration_fee_rule IS NOT NULL)
       OR EXISTS (SELECT 1 FROM assay_results WHERE sample_id IS NOT NULL)
       OR EXISTS (SELECT 1 FROM expenses WHERE reversal_reason IS NOT NULL OR reversed_at IS NOT NULL OR reversed_by IS NOT NULL) THEN
        RAISE EXCEPTION 'MES6A1_PROOF|a new column was filled on an existing row (no lab link, fee rule, sample link or reversal reason is set by this cut)';
    END IF;

    -- ④ 变更记录只多了本刀种的那几行(权限目录 2 插 + 1 改 · 授权 9 插 · 单据登记 ≤ 1 插);四张新表空(设定表恰好一行、天数为空)
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes6a1_log_before), 0)
       AND NOT ((c.op = 'INSERT' AND c.table_name IN ('permissions', 'role_permissions', 'document_types'))
                OR (c.op = 'UPDATE' AND c.table_name = 'permissions'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6A1_PROOF|unexpected change_log rows: %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes6a1_log_before), 0);
    IF v_n NOT IN (12, 13) THEN RAISE EXCEPTION 'MES6A1_PROOF|change_log moved by % (expected 12, or 13 if document_types is logged)', v_n; END IF;
    IF EXISTS (SELECT 1 FROM samples) OR EXISTS (SELECT 1 FROM sample_events) OR EXISTS (SELECT 1 FROM assay_disputes)
       OR (SELECT count(*) FROM quality_settings) <> 1 OR (SELECT internal_retention_days FROM quality_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6A1_PROOF|the new tables must be empty (quality_settings: one row, V16 empty)';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6A1_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑤ 结构:两支守卫在、CHECK 在;record_assay_result 只剩新签名、最后一个参数带默认;reverse_expense 签名不变;单据登记 57 行,SMP 一行
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_assay_results_sample_batch')
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_sample_events_append_only')
       OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'expenses_reversal_shape')
       OR position('EXPENSE_REVERSAL_REASON_REQUIRED' IN pg_get_functiondef('public.guard_expense_mutation()'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'MES6A1_PROOF|the sample guard, the append-only guard, the reversal CHECK or the extended row guard is missing';
    END IF;
    IF to_regprocedure('public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text)') IS NOT NULL OR to_regprocedure('public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid)') IS NULL
       OR (SELECT count(*) FROM pg_proc WHERE proname = 'record_assay_result' AND pronamespace = 'public'::regnamespace) <> 1
       OR pg_get_function_arguments('public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid)'::regprocedure) NOT LIKE '%p_sample_id uuid DEFAULT NULL::uuid' THEN
        RAISE EXCEPTION 'MES6A1_PROOF|record_assay_result must exist once, with p_sample_id last and defaulted';
    END IF;
    IF pg_get_function_arguments('public.reverse_expense(uuid, text)'::regprocedure) <> 'p_expense_id uuid, p_memo text DEFAULT NULL::text' THEN
        RAISE EXCEPTION 'MES6A1_PROOF|reverse_expense must keep its signature';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 57 OR document_type_prefix('sample') <> 'SMP' THEN
        RAISE EXCEPTION 'MES6A1_PROOF|document_types should be 57 with SMP';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;员工函数 DEFINER、调得到;守卫调不到;新表与视图 anon 读不到;底视图 authenticated 也读不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES6A1_PROOF|anon executes: %', v_bad;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_sample(text, date, uuid, uuid, numeric, uuid, bigint, uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_sample(text, date, uuid, uuid, numeric, uuid, bigint, uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_sample(text, date, uuid, uuid, numeric, uuid, bigint, uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|public.record_sample(text, date, uuid, uuid, numeric, uuid, bigint, uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_sample_event(uuid, text, timestamp with time zone, text, text, uuid, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_sample_event(uuid, text, timestamp with time zone, text, text, uuid, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_sample_event(uuid, text, timestamp with time zone, text, text, uuid, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|public.record_sample_event(uuid, text, timestamp with time zone, text, text, uuid, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.set_quality_settings(integer)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.set_quality_settings(integer)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.set_quality_settings(integer)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|public.set_quality_settings(integer): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.open_assay_dispute(uuid, uuid, text, uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.open_assay_dispute(uuid, uuid, text, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.open_assay_dispute(uuid, uuid, text, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|public.open_assay_dispute(uuid, uuid, text, uuid): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_dispute_umpire(uuid, uuid, uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_dispute_umpire(uuid, uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_dispute_umpire(uuid, uuid, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|public.record_dispute_umpire(uuid, uuid, uuid): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.withdraw_assay_dispute(uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.withdraw_assay_dispute(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.withdraw_assay_dispute(uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|public.withdraw_assay_dispute(uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.resolve_assay_dispute(uuid, uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.resolve_assay_dispute(uuid, uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.resolve_assay_dispute(uuid, uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|public.resolve_assay_dispute(uuid, uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.link_dispute_fee(uuid, uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.link_dispute_fee(uuid, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.link_dispute_fee(uuid, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|public.link_dispute_fee(uuid, uuid): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_assay_sample_batch()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_assay_sample_batch()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|public.guard_assay_sample_batch() must be a function nobody outside can call';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('quality_settings', 'samples', 'sample_events', 'assay_disputes', 'sample_rows', 'assay_dispute_metals', 'assay_dispute_rows', 'assay_disagreements_all')
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6A1_PROOF|anon can read %', v_bad; END IF;
    IF has_table_privilege('authenticated', 'public.assay_disagreements_all'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|the base view must not be readable by authenticated';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条;新表上没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES6A1_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND tablename IN ('quality_settings', 'samples', 'sample_events', 'assay_disputes') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES6A1_PROOF|a write policy exists on a new quality table';
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(四张新表记,豁免仍是 8);遮蔽零缺口(规则仍是 114 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES6A1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES6A1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑨ 提醒臂 62、待补的值 22
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 62
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 22 THEN
        RAISE EXCEPTION 'MES6A1_PROOF|reminder arms 62 / pending-value arms 22 expected';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes6a1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES6A1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes6a1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES6A1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes6a1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
