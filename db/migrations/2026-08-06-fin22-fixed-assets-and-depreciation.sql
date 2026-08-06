-- db/migrations/2026-08-06-fin22-fixed-assets-and-depreciation.sql
--
-- FIN-22:固定资产台账 + 直线折旧 + 处置。
-- (walk 单里的编号是 FIN-21;FIN-21 已被前一切【计价留痕带牌价日期】用掉,顺延。)
--
-- 【入口只有一个】资本性支出走 record_expense,行上标记资本(p_asset 非空)时
-- 借 1500 而不是费用科目,并在同一事务里生成台账行 —— 资产不可能脱离其应付/付款
-- 存在。1500 要求 p_asset,p_asset 要求 1500,双向锁死;手工分录仍能碰 1500,
-- 但那是既有的通用口子,不是本切开的。
--
-- 【非货币,永不重估】资产按【购置日】汇率折入本位币并永远停在那里(FIN-3 把
-- 1500/1510 归为非货币正是此意)。重估扫的是 is_monetary 科目 —— 两个都不是,
-- fixture 16D 断言零movement,防的是将来有人"顺手"把它们加进重估。
--
-- 【折旧幂等靠算术,不靠闸】目标累计折旧 = f(在役日, 期末, 成本, 残值, 年限),
-- 应提 = 目标 − 已提(Σ fixed_asset_depreciation)。同期第二次跑差额为 0,
-- 什么都不过账 —— 与重估的幂等同一形状。
--
-- 【新科目】6700 折旧费用(默认落点;5130 是加工成本分摊的口子,直接过账会
-- 绕开分摊、与人工成本条目重复计提 —— 台账默认不碰它,逐资产可改指到
-- account_type in expense/cogs 的科目,注释里写明 5130 的双重计提风险)。
-- 7200 资产处置损益 —— 与 7100/7110 同形(expense 类型,两个方向都过)。
-- 两个都 is_system(函数写死引用它们):seed:accounts 25 → 27。

BEGIN;

-- ── 1. 新科目 ────────────────────────────────────────────────────────────
INSERT INTO public.accounts (code, name_en, name_zh, account_type, is_system, is_monetary) VALUES
    ('6700', 'Depreciation Expense', '折旧费用', 'expense', true, false),
    ('7200', 'Gain/Loss on Asset Disposal', '资产处置损益', 'expense', true, false);

-- ── 2. journal source_type 扩两个值 ──────────────────────────────────────
ALTER TABLE public.journal_entries DROP CONSTRAINT journal_entries_source_type_check;
ALTER TABLE public.journal_entries ADD CONSTRAINT journal_entries_source_type_check
    CHECK (source_type IN ('manual','purchase','sale','processing_cost','allocation','stocktake',
                           'writeoff','payment','fx','expense','prepayment','payroll','transfer',
                           'revaluation','depreciation','asset_disposal'));

-- ── 3. 台账 ──────────────────────────────────────────────────────────────
CREATE TABLE public.fixed_assets (
    id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                      text NOT NULL UNIQUE,
    description               text NOT NULL,
    category                  text NOT NULL DEFAULT 'equipment'
                              CHECK (category IN ('equipment','vehicle','office','other')),
    -- 购置日 ≠ 在役日,两个都要:折旧从【在役日】起算,不从购置日
    acquisition_date          date NOT NULL,
    in_service_date           date,
    CONSTRAINT fixed_assets_service_after_acquisition
        CHECK (in_service_date IS NULL OR in_service_date >= acquisition_date),
    -- 成本:原币 + 购置日汇率 + 本位币。粉线设备是进口的,cost 会是 USD ——
    -- 按【购置日】牌价折入,之后永远停在那里。
    cost_ccy                  numeric NOT NULL CHECK (cost_ccy > 0),
    currency                  text NOT NULL REFERENCES public.currencies (code),
    fx_rate                   numeric NOT NULL CHECK (fx_rate > 0),
    cost_base                 numeric NOT NULL CHECK (cost_base > 0),
    useful_life_months        integer NOT NULL CHECK (useful_life_months > 0),
    residual_base             numeric NOT NULL DEFAULT 0 CHECK (residual_base >= 0),
    CONSTRAINT fixed_assets_residual_below_cost CHECK (residual_base < cost_base),
    -- 折旧落点:默认 6700。【不要指 5130 除非想清楚了】—— 5130 由
    -- processing_cost_entries 的 depreciation 条目喂、经分摊进批次成本;台账直接
    -- 过账到 5130 会绕开分摊,且与人工条目【重复计提】。指过去的资产必须停掉
    -- 对应的人工月度条目。
    depreciation_account_code text NOT NULL DEFAULT '6700' REFERENCES public.accounts (code),
    status                    text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disposed')),
    disposal_date             date,
    disposal_proceeds_base    numeric,
    disposal_journal_id       uuid REFERENCES public.journal_entries (id),
    CONSTRAINT fixed_assets_disposal_fields CHECK (
        (status = 'active'   AND disposal_date IS NULL AND disposal_journal_id IS NULL)
     OR (status = 'disposed' AND disposal_date IS NOT NULL)
    ),
    -- 资本性支出单(创建入口;资产不脱离应付存在)
    expense_id                uuid NOT NULL REFERENCES public.expenses (id),
    notes                     text,
    created_at                timestamptz NOT NULL DEFAULT now(),
    created_by                uuid
);

COMMENT ON TABLE public.fixed_assets IS
    '固定资产台账(FIN-22)。【非货币】:按【购置日】汇率折入本位币并永远停在那里 —— 不重估、不重译。revalue_foreign_balances 扫 is_monetary 科目,1500/1510 都不是;【不要把 1500/1510 加进重估】,fixture 16D 断言这一条。折旧从 in_service_date 起算,不从 acquisition_date。';
COMMENT ON COLUMN public.fixed_assets.fx_rate IS
    '【购置日】的 tt_sell 牌价(record_expense 取的那一个)。资产是非货币项目:这个汇率定格成本,永不重译。';

CREATE INDEX idx_fixed_assets_expense ON public.fixed_assets (expense_id);
CREATE INDEX idx_fixed_assets_status ON public.fixed_assets (status);

-- 折旧行:一行 = 一次月度计提对一个资产。累计折旧 = Σ 本表(recorded,不推导)。
CREATE TABLE public.fixed_asset_depreciation (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_id         uuid NOT NULL REFERENCES public.fixed_assets (id) ON DELETE RESTRICT,
    period_end       date NOT NULL,
    amount_base      numeric NOT NULL CHECK (amount_base > 0),
    journal_entry_id uuid NOT NULL REFERENCES public.journal_entries (id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid
);

COMMENT ON TABLE public.fixed_asset_depreciation IS
    '月度折旧计提行(FIN-22)。累计折旧 = Σ amount_base —— 消耗是【记录的】,不是推导的(AGENTS.md derived-vs-recorded)。幂等靠算术:目标累计 − Σ 已提 = 应提,同期第二次跑差额为 0。';

CREATE INDEX idx_fa_depreciation_asset ON public.fixed_asset_depreciation (asset_id);

ALTER TABLE public.fixed_assets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "fixed_assets select by permission" ON public.fixed_assets
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
ALTER TABLE public.fixed_asset_depreciation ENABLE ROW LEVEL SECURITY;
CREATE POLICY "fa_depreciation select by permission" ON public.fixed_asset_depreciation
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
-- 写入只经 SECURITY DEFINER 函数(属主绕过 RLS);不开 INSERT/UPDATE/DELETE 策略。

-- ── 4. record_expense:资本分支(科目 1500 ↔ p_asset 互相要求)──────────
CREATE OR REPLACE FUNCTION public.record_expense(p_expense_date date, p_account_code text, p_amount numeric, p_currency text DEFAULT 'SGD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_payment_status text DEFAULT 'paid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_asset jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user       uuid := auth.uid();
    v_account    record;
    v_fx         numeric;
    v_amount_base numeric;
    v_bank       text;
    v_expense_id uuid := gen_random_uuid();
    v_year       integer;
    v_seq        integer;
    v_code       text;
    v_je         jsonb;
    v_asset_id   uuid;
    v_asset_code text;
    v_asset_seq  integer;
    v_life       integer;
    v_residual   numeric;
    v_in_service date;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. 科目:必须存在、启用,且是 expense 类型(只有 6xxx 是合法开支落点)
    IF p_expense_date IS NULL THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
    END IF;
    SELECT code, is_active, account_type INTO v_account
    FROM accounts WHERE code = p_account_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_FOUND|%', COALESCE(p_account_code, '?');
    END IF;
    IF NOT v_account.is_active THEN
        RAISE EXCEPTION 'ACCOUNT_INACTIVE|%', v_account.code;
    END IF;
    -- FIN-22:资本性支出 —— 科目 1500 与 p_asset【互相要求】。
    --   * 1500 而无 p_asset:这条路上不许出现没有台账行的固定资产借方;
    --   * p_asset 而非 1500:资本标记只有一个落点,别的科目不接受;
    --   * 其余科目照旧只认 expense 类型("只有 6xxx 是合法开支落点"的原规矩)。
    IF p_account_code = '1500' THEN
        IF p_asset IS NULL THEN
            RAISE EXCEPTION 'CAPITAL_REQUIRES_ASSET|1500';
        END IF;
    ELSIF p_asset IS NOT NULL THEN
        RAISE EXCEPTION 'ASSET_REQUIRES_CAPITAL_ACCOUNT|%', v_account.code;
    ELSIF v_account.account_type <> 'expense' THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_EXPENSE|%', v_account.code;
    END IF;

    -- 2. 金额/币种/汇率(FIN-0:SGD 本位免换算,外币按费用日牌价估值)
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【费用日】的行方卖出价(tt_sell)估值 ——
    -- 应付与开销是我们将来要【向银行买】的外币。当日无牌价即拒(FX_RATE_MISSING)。
    -- 汇率不再由调用方递入:牌价属于 fx_rates,不属于表单。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, p_expense_date, 'tt_sell');

    -- 3. 支付状态
    IF p_payment_status IS NULL OR p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'PAYMENT_STATUS_INVALID|%', COALESCE(p_payment_status, '?');
    END IF;

    IF p_payment_status = 'paid' THEN
        -- paid:银行科目显式给了必须合法;不给按币种默认(SGD → 1000,USD → 1010)
        IF p_bank_account IS NOT NULL THEN
            IF p_bank_account NOT IN ('1000','1010') THEN
                RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
            END IF;
            v_bank := p_bank_account;
        ELSE
            v_bank := CASE WHEN p_currency = 'SGD' THEN '1000' ELSE '1010' END;
        END IF;
    ELSE
        -- unpaid:必须有在册供应商(它要成为 AP 单据);银行科目必须为空 ——
        -- 传了也直接忽略(挂账时根本没动银行,存下来只会误导)
        IF p_supplier_id IS NULL THEN
            RAISE EXCEPTION 'SUPPLIER_REQUIRED_FOR_UNPAID';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', p_supplier_id;
        END IF;
        v_bank := NULL;
    END IF;

    -- 4. USD 金额
    v_amount_base := round(p_amount * v_fx, 2);

    -- 5. 无缝编号:咨询锁串行化"取当年最大号+1"(同 JE/收付款编号手法);失败回滚会释放号码。
    v_year := EXTRACT(YEAR FROM p_expense_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE 'EXP-' || v_year::text || '-%';
    v_code := 'EXP-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 6. 先过分录(source_id = 预生成的 expense id,无需回填),期间锁在此生效。
    --    paid → 贷银行;unpaid → 贷 2000 应付。行走原币。
    v_je := post_journal_entry(
        p_expense_date,
        'Expense ' || v_code || ' ' || p_account_code,
        'expense', v_expense_id,
        jsonb_build_array(
            jsonb_build_object('account_code', p_account_code, 'side', 'debit',
                               'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
            jsonb_build_object('account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
                               'side', 'credit',
                               'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx))
    );

    -- 7. 插入开支单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_expense_id, v_code, p_expense_date, p_account_code, p_amount, p_currency, v_fx,
            v_amount_base, p_payment_status, v_bank, p_supplier_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, v_user);

    -- FIN-22:资本行 → 同一事务生成台账。成本 = 本单金额;汇率 = 上面按
    -- 【费用日 = 购置日】取的 tt_sell 牌价 —— 资产是非货币项目,这个汇率
    -- 定格成本,永不重译(表注有言,重估扫不到 1500/1510)。
    IF p_asset IS NOT NULL THEN
        IF COALESCE(p_asset->>'description', '') = '' THEN
            RAISE EXCEPTION 'ASSET_DESCRIPTION_REQUIRED';
        END IF;
        v_life := (p_asset->>'useful_life_months')::integer;
        IF v_life IS NULL OR v_life <= 0 THEN
            RAISE EXCEPTION 'ASSET_LIFE_INVALID|%', COALESCE(p_asset->>'useful_life_months', '?');
        END IF;
        v_residual := COALESCE((p_asset->>'residual_base')::numeric, 0);
        IF v_residual < 0 OR v_residual >= v_amount_base THEN
            RAISE EXCEPTION 'ASSET_RESIDUAL_INVALID|%|%', v_residual, v_amount_base;
        END IF;
        v_in_service := (p_asset->>'in_service_date')::date;
        IF v_in_service IS NOT NULL AND v_in_service < p_expense_date THEN
            RAISE EXCEPTION 'ASSET_IN_SERVICE_BEFORE_ACQUISITION|%|%', v_in_service, p_expense_date;
        END IF;

        v_asset_id := gen_random_uuid();
        PERFORM pg_advisory_xact_lock(hashtext('fixed_asset_code_' || v_year::text)::bigint);
        SELECT COALESCE(MAX(split_part(fa.code, '-', 3)::integer), 0) + 1
        INTO v_asset_seq
        FROM fixed_assets fa
        WHERE fa.code LIKE 'FA-' || v_year::text || '-%';
        v_asset_code := 'FA-' || v_year::text || '-' || LPAD(v_asset_seq::text, 4, '0');

        INSERT INTO fixed_assets (id, code, description, category, acquisition_date, in_service_date,
                                  cost_ccy, currency, fx_rate, cost_base, useful_life_months,
                                  residual_base, depreciation_account_code, expense_id, notes, created_by)
        VALUES (v_asset_id, v_asset_code, p_asset->>'description',
                COALESCE(p_asset->>'category', 'equipment'),
                p_expense_date, v_in_service,
                p_amount, p_currency, v_fx, v_amount_base, v_life,
                v_residual, COALESCE(p_asset->>'depreciation_account_code', '6700'),
                v_expense_id, p_asset->>'notes', v_user);
    END IF;

    RETURN jsonb_build_object(
        'expense_id', v_expense_id,
        'asset_id', v_asset_id, 'asset_code', v_asset_code,
        'code', v_code,
        'amount_base', v_amount_base,
        'journal_code', v_je->>'code',
        'payment_status', p_payment_status
    );
END;
$function$;

-- ── 5. 折旧:预览(算术唯一来源)+ 写入(问预览,过账差额)──────────────────
-- 幂等靠算术:目标累计 = LEAST(成本−残值, 月折旧 × 在役月数(含首月按天折)),
-- 应提 = 目标 − Σ 已提。同期第二次跑差额 0 → 不过账。守卫:
--   * 期末日期【必填】,不默认(FIN-10 的规矩:决定期间的日期没有默认值);
--   * 锁定期间【点名拒绝】—— 在算术之前查:差额为 0 的跑法也不许落在锁里;
--   * 从不早于在役日(目标为 0);从不超过成本−残值(LEAST 封顶)。
CREATE OR REPLACE FUNCTION public.preview_depreciate_fixed_assets(p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rows   jsonb := '[]'::jsonb;
    v_total  numeric := 0;
    v_a      record;
    v_months numeric;
    v_m0     date;
    v_mn     date;
    v_target numeric;
    v_posted numeric;
    v_delta  numeric;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;

    FOR v_a IN
        SELECT fa.id, fa.code, fa.description, fa.in_service_date, fa.cost_base,
               fa.residual_base, fa.useful_life_months, fa.depreciation_account_code
        FROM fixed_assets fa
        WHERE fa.status = 'active'
        ORDER BY fa.code
    LOOP
        -- 在役月数(含首月/末月按天折算)。未投用或期末早于在役日 → 0。
        IF v_a.in_service_date IS NULL OR p_period_end < v_a.in_service_date THEN
            v_months := 0;
        ELSE
            v_m0 := date_trunc('month', v_a.in_service_date)::date;
            v_mn := date_trunc('month', p_period_end)::date;
            IF v_m0 = v_mn THEN
                v_months := (p_period_end - v_a.in_service_date + 1)::numeric
                            / EXTRACT(day FROM (v_m0 + interval '1 month - 1 day'))::numeric;
            ELSE
                v_months :=
                    ((v_m0 + interval '1 month - 1 day')::date - v_a.in_service_date + 1)::numeric
                        / EXTRACT(day FROM (v_m0 + interval '1 month - 1 day'))::numeric
                    + (EXTRACT(year FROM age(v_mn, v_m0 + interval '1 month'))::numeric * 12
                       + EXTRACT(month FROM age(v_mn, v_m0 + interval '1 month'))::numeric)
                    + EXTRACT(day FROM p_period_end)::numeric
                        / EXTRACT(day FROM (v_mn + interval '1 month - 1 day'))::numeric;
            END IF;
        END IF;

        v_target := LEAST(round(v_a.cost_base - v_a.residual_base, 2),
                          round((v_a.cost_base - v_a.residual_base)
                                / v_a.useful_life_months * v_months, 2));
        SELECT COALESCE(SUM(d.amount_base), 0) INTO v_posted
        FROM fixed_asset_depreciation d WHERE d.asset_id = v_a.id;
        v_delta := round(v_target - v_posted, 2);
        -- 负差额不冲回:残值/年限被改动导致的目标下修是【更正】,走人工分录,
        -- 不由月度例程悄悄回冲。这里报 0。
        IF v_delta < 0 THEN v_delta := 0; END IF;
        v_total := v_total + v_delta;

        v_rows := v_rows || jsonb_build_object(
            'asset_id', v_a.id, 'code', v_a.code, 'description', v_a.description,
            'account', v_a.depreciation_account_code,
            'target_base', v_target, 'posted_base', v_posted, 'delta_base', v_delta);
    END LOOP;

    RETURN jsonb_build_object('period_end', p_period_end, 'rows', v_rows,
                              'total_delta', round(v_total, 2));
END;
$function$;

CREATE OR REPLACE FUNCTION public.depreciate_fixed_assets(p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_locked  date;
    v_preview jsonb;
    v_r       jsonb;
    v_lines   jsonb := '[]'::jsonb;
    v_grp     record;
    v_total   numeric;
    v_je      jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;
    -- 【先查锁,再算术】差额为 0 的跑法也不许落在锁定期间里 —— 拒绝要点名,
    -- 与 post_journal_entry 同一口径(它兜底,这里提前)。
    SELECT locked_before INTO v_locked FROM finance_settings WHERE id;
    IF v_locked IS NOT NULL AND p_period_end < v_locked THEN
        RAISE EXCEPTION 'PERIOD_LOCKED|%|%', p_period_end, v_locked;
    END IF;

    v_preview := preview_depreciate_fixed_assets(p_period_end);
    v_total := (v_preview->>'total_delta')::numeric;

    -- 幂等出口:没有应提额 → 不过账、不留行,原样说明
    IF v_total = 0 THEN
        RETURN jsonb_build_object('period_end', p_period_end, 'total_posted', 0,
                                  'journal_code', NULL, 'detail', v_preview->'rows');
    END IF;

    -- 分录:逐【折旧科目】借方归组,贷 1510 一条
    FOR v_grp IN
        SELECT r->>'account' AS account, round(SUM((r->>'delta_base')::numeric), 2) AS amt
        FROM jsonb_array_elements(v_preview->'rows') r
        WHERE (r->>'delta_base')::numeric > 0
        GROUP BY r->>'account' ORDER BY r->>'account'
    LOOP
        v_lines := v_lines || jsonb_build_object('account_code', v_grp.account, 'side', 'debit',
            'currency', 'SGD', 'amount_ccy', v_grp.amt, 'fx_rate', 1,
            'line_memo', 'straight-line depreciation');
    END LOOP;
    v_lines := v_lines || jsonb_build_object('account_code', '1510', 'side', 'credit',
        'currency', 'SGD', 'amount_ccy', v_total, 'fx_rate', 1);

    v_je := post_journal_entry(p_period_end,
        'Depreciation for period ending ' || p_period_end,
        'depreciation', NULL, v_lines);

    -- 计提行落库(recorded —— 累计折旧从此可加出来)
    FOR v_r IN SELECT * FROM jsonb_array_elements(v_preview->'rows')
    LOOP
        IF (v_r->>'delta_base')::numeric > 0 THEN
            INSERT INTO fixed_asset_depreciation (asset_id, period_end, amount_base, journal_entry_id, created_by)
            VALUES ((v_r->>'asset_id')::uuid, p_period_end, (v_r->>'delta_base')::numeric,
                    (v_je->>'entry_id')::uuid, v_user);
        END IF;
    END LOOP;

    RETURN jsonb_build_object('period_end', p_period_end, 'total_posted', v_total,
                              'journal_code', v_je->>'code', 'detail', v_preview->'rows');
END;
$function$;

-- ── 6. 处置:出售或报废 ──────────────────────────────────────────────────
-- 1500 按成本解除、1510 按累计折旧解除,差额对净收款进 7200(与 7100/7110 同形,
-- 两个方向都过)。【不自动补提】处置月折旧 —— 想提就先跑月度例程再处置;
-- 未提部分如实进损益,不藏进任何科目。
CREATE OR REPLACE FUNCTION public.dispose_fixed_asset(p_asset_id uuid, p_disposal_date date, p_proceeds numeric DEFAULT 0, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_a      record;
    v_accum  numeric;
    v_gain   numeric;
    v_bank   text;
    v_lines  jsonb := '[]'::jsonb;
    v_je     jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_disposal_date IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;
    SELECT * INTO v_a FROM fixed_assets WHERE id = p_asset_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_NOT_FOUND|%', p_asset_id;
    END IF;
    IF v_a.status <> 'active' THEN
        RAISE EXCEPTION 'ASSET_ALREADY_DISPOSED|%', v_a.code;
    END IF;
    IF p_disposal_date < v_a.acquisition_date THEN
        RAISE EXCEPTION 'DISPOSAL_BEFORE_ACQUISITION|%|%', p_disposal_date, v_a.acquisition_date;
    END IF;
    IF p_proceeds IS NULL OR p_proceeds < 0 THEN
        RAISE EXCEPTION 'PROCEEDS_INVALID';
    END IF;
    IF p_proceeds > 0 THEN
        IF p_bank_account IS NULL OR p_bank_account NOT IN ('1000','1010') THEN
            RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_bank_account, '?');
        END IF;
        v_bank := p_bank_account;
    END IF;

    SELECT COALESCE(SUM(amount_base), 0) INTO v_accum
    FROM fixed_asset_depreciation WHERE asset_id = p_asset_id;

    -- 损益 = 净收款 + 累计折旧 − 成本(>0 益,<0 损)
    v_gain := round(p_proceeds + v_accum - v_a.cost_base, 2);

    IF p_proceeds > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', v_bank, 'side', 'debit',
            'currency', 'SGD', 'amount_ccy', p_proceeds, 'fx_rate', 1, 'line_memo', 'disposal proceeds');
    END IF;
    IF v_accum > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '1510', 'side', 'debit',
            'currency', 'SGD', 'amount_ccy', v_accum, 'fx_rate', 1, 'line_memo', 'accumulated depreciation relieved');
    END IF;
    v_lines := v_lines || jsonb_build_object('account_code', '1500', 'side', 'credit',
        'currency', 'SGD', 'amount_ccy', v_a.cost_base, 'fx_rate', 1, 'line_memo', 'cost relieved');
    IF v_gain > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7200', 'side', 'credit',
            'currency', 'SGD', 'amount_ccy', v_gain, 'fx_rate', 1);
    ELSIF v_gain < 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7200', 'side', 'debit',
            'currency', 'SGD', 'amount_ccy', -v_gain, 'fx_rate', 1);
    END IF;

    v_je := post_journal_entry(p_disposal_date,
        'Disposal ' || v_a.code || COALESCE(' — ' || p_notes, ''),
        'asset_disposal', p_asset_id, v_lines);

    UPDATE fixed_assets
    SET status = 'disposed', disposal_date = p_disposal_date,
        disposal_proceeds_base = p_proceeds, disposal_journal_id = (v_je->>'entry_id')::uuid
    WHERE id = p_asset_id;

    RETURN jsonb_build_object('asset_id', p_asset_id, 'code', v_a.code,
        'cost_relieved', v_a.cost_base, 'accum_relieved', v_accum,
        'proceeds', p_proceeds, 'gain_loss', v_gain, 'journal_code', v_je->>'code');
END;
$function$;

-- ── 7. reverse_expense:挂着台账行的支出不许冲销(点名拒绝)────────────
CREATE OR REPLACE FUNCTION public.reverse_expense(p_expense_id uuid, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        expenses%ROWTYPE;
    v_mirror_id   uuid := gen_random_uuid();
    v_year        integer;
    v_seq         integer;
    v_mirror_code text;
    v_je          jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
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

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, CURRENT_DATE, 'Expense reversal ' || v_orig.code);

    -- 镜像开支单(同形状、status 'posted'、挂冲销分录、不带核销行)。
    -- 镜像行只是冲销的记录凭证,不是新的应付单据 —— ap_open_items 里按
    -- "被别的开支单指为 reversed_by_expense" 排除它。
    v_year := EXTRACT(YEAR FROM CURRENT_DATE)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE 'EXP-' || v_year::text || '-%';
    v_mirror_code := 'EXP-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, CURRENT_DATE, v_orig.account_code,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_base,
            v_orig.payment_status, v_orig.bank_account_code, v_orig.supplier_id,
            v_orig.payee_name,
            'REVERSAL: ' || v_orig.code || COALESCE(' — ' || p_memo, ''),
            (v_je->>'reversal_id')::uuid, auth.uid());

    UPDATE expenses
    SET status = 'reversed', reversed_by_expense = v_mirror_id
    WHERE id = p_expense_id;

    RETURN jsonb_build_object(
        'reversal_expense_id', v_mirror_id,
        'code', v_mirror_code,
        'journal_code', v_je->>'code'
    );
END;
$function$;

COMMIT;
