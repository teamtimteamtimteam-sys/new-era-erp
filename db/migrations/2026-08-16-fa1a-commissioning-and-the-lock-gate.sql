-- FA-1a:固定资产 —— 从"买来了"到"开始折旧"之间那个缺掉的动词,以及锁的那道闸
--
-- ═══════════════════════════════════════════════════════════════════════════
-- FA-0 的调查列了五件真实设备采购需要、而系统给不了的东西。这一刀做其中两件半:
--   ① 【追加成本】运费、关税、安装调试 —— 它们本来就属于机器的成本,而此前
--      record_expense 只能【一笔一台】:第二笔要么变成第二台资产,要么变成当期费用。
--   ② 【投用这个动词】in_service_date 此前只能在【购置那一刻】填。而现实是
--      机器先到、后调试、再投产 —— 中间那段时间它既不该折旧、也确实还没投用。
--      FA-0 量过:NULL 的行为是对的(不折旧),缺的是把它从 NULL 变成日期的那个动作。
--   ③ 【锁的那道闸】月结链条的注释写着"锁进去的月份都要包含它",而实测:
--      lock 只看重估,不看折旧 —— 一个月可以在折旧还欠着的时候被锁进去,
--      此后 PERIOD_LOCKED 让它补都补不回来(要先 reopen_period)。
--      **一句被叙述、而没有被执行的承诺,与没有那句承诺是两回事** —— 它会被信。
--
-- ── 三个决定 ──────────────────────────────────────────────────────────────
--
-- 【一 · 同一扇门,两种模式 —— 不开第二个函数】
-- 1500 ↔ p_asset 的互相要求是这条路上唯一的不变量。再开一个 add_cost_to_asset()
-- 就是第二扇门,而那个不变量只守得住第一扇。所以 p_asset 带 asset_id = 追加,
-- 不带 = 新建。同一个入口,同一套校验。
--
-- 【二 · 成本明细表,而不是只加一个数】
-- 每一笔追加带【自己的】汇率:进口机器按购置日的 tt_sell 折算,本地运费按运费日
-- 折算 —— 两笔的原币可以不同,汇率一定不同。表头那三列(cost_ccy / currency /
-- fx_rate)是【第一笔】的,cost_base 是合计。若只把 cost_base 加大而不留明细,
-- "这个数是怎么来的"就再也答不出来了,而资产是要被审计的东西。
--
-- 【三 · 投用即冻结】投用之后不许再追加成本。投用那一刻起折旧按当时的 cost_base
-- 算,已经提过的那几期都基于它;事后加钱会让那几期全错,而它们可能已经锁进期间。
-- 投用后的支出是一次【会计判断】(资本化改良 vs 当期费用),按名拒,交还给人。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 成本明细 ══════════════════════════════════════════════════════════
CREATE TABLE public.fixed_asset_cost_entries (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_id     uuid NOT NULL REFERENCES public.fixed_assets (id) ON DELETE RESTRICT,
    -- 每一笔都来自一张资本性支出单 —— 资产不脱离它的应付/付款存在(FIN-22 的规矩)
    expense_id   uuid NOT NULL REFERENCES public.expenses (id),
    -- 三件套:这一笔自己的原币、自己那天的汇率、折出来的本位币额
    amount_ccy   numeric NOT NULL CHECK (amount_ccy > 0),
    currency     text    NOT NULL REFERENCES public.currencies (code),
    fx_rate      numeric NOT NULL CHECK (fx_rate > 0),
    amount_base  numeric NOT NULL CHECK (amount_base > 0),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid,
    -- 一张支出单只能进一次(重复调用会被它挡住,而不是把成本加两遍)
    CONSTRAINT fixed_asset_cost_entries_one_per_expense UNIQUE (expense_id)
);

COMMENT ON TABLE public.fixed_asset_cost_entries IS
    'FA-1a:一台资产的成本【由哪几笔构成】。购置那一笔也在里面 —— 否则第一笔要查 expenses、后续几笔要查这里,两处读法迟早各说各话。每一笔带自己的汇率:进口机器按购置日折算、本地运费按运费日折算,两笔的原币可以不同、汇率一定不同。fixed_assets 表头那三列是【第一笔】的,cost_base 是这张表的合计。';

CREATE INDEX idx_fixed_asset_cost_entries_asset ON public.fixed_asset_cost_entries (asset_id);

ALTER TABLE public.fixed_asset_cost_entries ENABLE ROW LEVEL SECURITY;
-- 读 module.finance.view(与 fixed_assets 同一扇门);写只经 record_expense。
CREATE POLICY "fixed_asset_cost_entries select by permission" ON public.fixed_asset_cost_entries
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));

-- 【既有资产的那一笔要补进去】线上今天 0 台,所以这一句是给重建路径与将来
-- 可能存在的行准备的 —— 让"第一笔也在明细里"这句话对每一行都成立,而不是
-- 只对本刀之后建的资产成立。
INSERT INTO fixed_asset_cost_entries (asset_id, expense_id, amount_ccy, currency, fx_rate, amount_base, created_by)
SELECT fa.id, fa.expense_id, fa.cost_ccy, fa.currency, fa.fx_rate, fa.cost_base, fa.created_by
  FROM fixed_assets fa
 WHERE NOT EXISTS (SELECT 1 FROM fixed_asset_cost_entries c WHERE c.expense_id = fa.expense_id);

-- ═══ 2 · 追加模式(同一扇门)════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.record_expense(p_expense_date date, p_account_code text, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_payment_status text DEFAULT 'paid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_asset jsonb DEFAULT NULL::jsonb)
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
    v_append_id  uuid;   -- FA-1a:追加模式的目标资产
    v_target     fixed_assets%ROWTYPE;
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
        -- paid:银行科目显式给了必须合法;不给按币种默认 —— 映射只有一份
        -- (bank_account_for_currency,bank_native_currency 的逆)
        IF p_bank_account IS NOT NULL THEN
            IF p_bank_account NOT IN ('1000','1010') THEN
                RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
            END IF;
            v_bank := p_bank_account;
        ELSE
            v_bank := bank_account_for_currency(p_currency);
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
        -- ── FA-1a:同一扇门,两种模式 ────────────────────────────────────────
        -- 【为什么不开第二个函数】1500 ↔ p_asset 的互相要求是这条路上唯一的
        -- 不变量:没有台账行的 1500 借方进不来,资本标记也落不到别的科目上。
        -- 再开一个 add_cost_to_asset() 等于开第二扇门,而那个不变量只守得住
        -- 第一扇 —— 与"单据不该有第二个写法"同一条(so_issues / approval_log)。
        -- 所以追加走【同一个函数】:p_asset 带 asset_id 就是追加,不带就是新建。
        v_append_id := (p_asset->>'asset_id')::uuid;

        IF v_append_id IS NOT NULL THEN
            -- ── 追加成本(运费、关税、安装调试)──────────────────────────
            SELECT * INTO v_target FROM fixed_assets WHERE id = v_append_id FOR UPDATE;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ASSET_NOT_FOUND|%', v_append_id;
            END IF;
            -- 【投用之后成本就冻住了】投用那一刻起折旧按它算;再往上加钱,
            -- 已经提过的那几期就全错了 —— 而它们已经过账,可能已经锁进期间。
            -- 投用后的追加是一次【会计判断】(资本化改良 vs 当期费用),
            -- 不是这条路顺手做得了的事,所以按名拒,把那个判断交还给人。
            IF v_target.in_service_date IS NOT NULL THEN
                RAISE EXCEPTION 'ASSET_ALREADY_IN_SERVICE|%|%', v_target.code, v_target.in_service_date;
            END IF;
            IF v_target.status <> 'active' THEN
                RAISE EXCEPTION 'ASSET_DISPOSED|%', v_target.code;
            END IF;

            -- 每一笔追加带【自己的】三件套:原币金额、它自己那天的汇率、本位币额。
            -- 表头那三列是【第一笔】的(购置那一笔),不是合计 —— 合计只有
            -- cost_base 一个数,而各笔的原币可以不同(进口机器 USD、本地运费 SGD)。
            INSERT INTO fixed_asset_cost_entries
                (asset_id, expense_id, amount_ccy, currency, fx_rate, amount_base, created_by)
            VALUES (v_append_id, v_expense_id, p_amount, p_currency, v_fx, v_amount_base, v_user);

            UPDATE fixed_assets
               SET cost_base = cost_base + v_amount_base
             WHERE id = v_append_id;

            RETURN jsonb_build_object(
                'expense_id', v_expense_id,
                'asset_id', v_append_id, 'asset_code', v_target.code,
                'asset_mode', 'append',
                'journal_entry_id', (v_je->>'entry_id')::uuid,
                'journal_code', v_je->>'code',
                'code', v_code);
        END IF;

        -- ── 新建(FIN-22 起的原样路径)──────────────────────────────────────
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

        -- 【第一笔也进明细表】否则"这台机器的成本由哪几笔构成"对第一笔要查
        -- expenses、对后续几笔要查明细表 —— 两处读法,迟早各说各话。
        INSERT INTO fixed_asset_cost_entries
            (asset_id, expense_id, amount_ccy, currency, fx_rate, amount_base, created_by)
        VALUES (v_asset_id, v_expense_id, p_amount, p_currency, v_fx, v_amount_base, v_user);
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

-- ═══ 3 · 投用这个动词 ══════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.set_asset_in_service(p_asset_id uuid, p_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_a    fixed_assets%ROWTYPE;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;

    SELECT * INTO v_a FROM fixed_assets WHERE id = p_asset_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_NOT_FOUND|%', COALESCE(p_asset_id::text, '?');
    END IF;
    -- 【投用只发生一次】改投用日等于把已经提过的折旧全部推翻 —— 那是一次更正,
    -- 走人工分录,与改年限/残值同一条(见 preview_depreciate_fixed_assets 的头)。
    IF v_a.in_service_date IS NOT NULL THEN
        RAISE EXCEPTION 'ASSET_ALREADY_IN_SERVICE|%|%', v_a.code, v_a.in_service_date;
    END IF;
    IF v_a.status <> 'active' THEN
        RAISE EXCEPTION 'ASSET_DISPOSED|%', v_a.code;
    END IF;
    -- 表上那条 CHECK 也拦得住,但它给的是约束名;这里按名拒,人才知道该改哪个日期。
    IF p_date < v_a.acquisition_date THEN
        RAISE EXCEPTION 'IN_SERVICE_BEFORE_ACQUISITION|%|%', p_date, v_a.acquisition_date;
    END IF;

    UPDATE fixed_assets SET in_service_date = p_date WHERE id = p_asset_id;

    -- 折旧从这一天起算(首月按天折算,见 preview_depreciate_fixed_assets),
    -- 而成本从这一刻起冻住 —— 再往上追加会被 record_expense 按名拒。
    RETURN jsonb_build_object('asset_id', p_asset_id, 'code', v_a.code,
                              'in_service_date', p_date, 'cost_base', v_a.cost_base);
END;
$function$;

-- ═══ 4 · 锁的那道闸 ════════════════════════════════════════════════════════
-- 【被叙述的承诺变成被执行的】月结链条的注释写着"折旧排在重估与锁之前 ——
-- 锁进去的月份都要包含它",而 lock 此前只看重估。实测:折旧还欠着也锁得进去,
-- 而锁上之后 depreciate_fixed_assets 的 PERIOD_LOCKED 让它补都补不回来
-- (要先 reopen_period)。**一句被叙述、没有被执行的承诺会被信,那正是它的代价。**
--
-- 【判据从【同一份算术】来】preview_depreciate_fixed_assets —— 页面问它、
-- 过账问它,现在锁也问它。第三份实现就是第三个会漂开的答案(AGENTS.md:
-- 一处推导,N 个消费者;这个仓库为这条形状付过四次账)。
--
-- 【两种"没有欠账"照旧放行】没有资产(preview 返回空)与差额为 0(提完了),
-- 两者在这里都不拦 —— 与月结中枢那三态口径一致(na / done)。
CREATE OR REPLACE FUNCTION public.close_period(p_period_end date, p_notes text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_locked   date;
    v_count    integer;
    v_debits   numeric;
    v_credits  numeric;
    v_new_lock date;
    v_dep      numeric;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 必须是月末日
    IF p_period_end IS NULL
       OR p_period_end <> (date_trunc('month', p_period_end) + interval '1 month - 1 day')::date THEN
        RAISE EXCEPTION 'NOT_MONTH_END|%', COALESCE(p_period_end::text, '?');
    END IF;

    -- 串行化 + 不可重关已锁期间
    SELECT locked_before INTO v_locked FROM finance_settings WHERE id FOR UPDATE;
    IF v_locked IS NOT NULL AND p_period_end < v_locked THEN
        RAISE EXCEPTION 'ALREADY_CLOSED|%', v_locked;
    END IF;

    -- FA-1a:折旧还欠着就不许锁 —— 判据取自 preview,不另算一份。
    v_dep := (preview_depreciate_fixed_assets(p_period_end)->>'total_delta')::numeric;
    IF COALESCE(v_dep, 0) > 0 THEN
        RAISE EXCEPTION 'DEPRECIATION_OUTSTANDING|%|%', p_period_end, v_dep;
    END IF;

    -- 截至 period_end 的全部分录:张数 + Σ借/Σ贷(关账即校验点)
    SELECT COUNT(DISTINCT jl.entry_id),
           round(COALESCE(SUM(jl.debit), 0), 2),
           round(COALESCE(SUM(jl.credit), 0), 2)
    INTO v_count, v_debits, v_credits
    FROM journal_lines jl
    JOIN journal_entries je ON je.id = jl.entry_id
    WHERE je.entry_date <= p_period_end;

    IF v_debits <> v_credits THEN
        RAISE EXCEPTION 'TRIAL_BALANCE_UNBALANCED|%|%', v_debits, v_credits;
    END IF;

    v_new_lock := p_period_end + 1;

    INSERT INTO period_closes (period_end, notes, entries_count, total_debits, total_credits)
    VALUES (p_period_end, p_notes, v_count, v_debits, v_credits);

    UPDATE finance_settings
    SET locked_before = v_new_lock, updated_by = auth.uid()
    WHERE id;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'locked_before', v_new_lock,
        'entries_count', v_count,
        'total_debits', v_debits,
        'total_credits', v_credits
    );
END;
$function$;

COMMIT;
