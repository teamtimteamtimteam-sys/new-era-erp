-- FIN-13:汇率"就近取上一个发布日",但要有界、要说清、要留痕。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【规则的精化,不是推翻】
-- ════════════════════════════════════════════════════════════════════════════
-- 周末发生的交易用周五的牌价 —— 这是对的。FIN-0 当初的毛病不在"往回找",
-- 而在【往回找得悄无声息】:没有界,也不说用了哪一天。
--
-- 现在的口径:
--   1. 先取当日。
--   2. 没有就往回找,但【中间跨过的每一天都必须是非发布日】(周六、周日、
--      public_holidays 里 country='SG' 的生效假日)。中间只要夹着一个工作日,
--      就说明那天该录没录 —— 拒绝,不替人圆场。
--   3. 再加一道【4 个自然日】的硬上限兜底。
--   4. 越界仍然拒绝,照旧点名日期、币种、哪一侧。
--   5. 【永远返回用的是哪一天的牌价】,由界面显示出来。周六用周五的价是对的,
--      但必须看得见;同一套机制悄悄用上三周前的价,才是当初删掉的那个错。
--
-- 【4 天这个数怎么来的】把 2026 全年逐日算过:需要往回找的最大距离是【3 天】
-- (受难节那个周末、圣诞那个周末,全年 6 天)。但新加坡的"顺延假"规则让 4 天
-- 在别的年份可达:农历新年初一落在周日时,周六+周日(初一)+周一(初二)+
-- 周二(顺延)连成 4 个非发布日,周二的交易要取周五的价。大选投票日紧邻周末
-- 也是同样的形状。再往上就属于罕见组合 —— 那时拒绝才是对的,录一条牌价只要几秒。
-- 上限只是兜底:真正干活的是"中间不许夹工作日"那一条。
--
-- 【伦敦 vs 新加坡日历:接受这个近似】金属行情跟的是伦敦,我们手上只有 SG 假日表。
-- 失败方向是【英国公共假日那天误判为工作日 → 拒绝】—— 偏保守、且会自己报出来,
-- 不会悄悄用错价。所以按 SG 日历近似,不为此再维护一张伦敦日历。
--
-- 【假日表本身是承重的】calculate_leave_days 也用它(经 submit_leave_request
-- 影响请假天数)。表里目前只有 2026 —— 到 2027 年 1 月,FX 会拒绝、请假天数会
-- 【静默】算错。故本迁移同时加一条待办提醒(见文末 hr_alerts)。

BEGIN;

-- ── 1. 工作日的定义,只留一份 ───────────────────────────────────────────────
-- 原先这条谓词内联在 calculate_leave_days 里。现在 FX 也要用同一套"哪天不发布",
-- 抽出来共用 —— 两处各写一遍就是下一个漂移点。
CREATE OR REPLACE FUNCTION public.is_business_day(p_date date, p_country text DEFAULT 'SG')
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT p_date IS NOT NULL
       AND EXTRACT(ISODOW FROM p_date) < 6
       AND NOT EXISTS (
           SELECT 1 FROM public_holidays h
           WHERE h.holiday_date = p_date AND h.country = p_country AND h.is_active);
$function$;

REVOKE EXECUTE ON FUNCTION public.is_business_day(date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_business_day(date, text) TO authenticated, service_role;

-- 请假天数改用共用定义(算法不变:周一至周五、且不是生效假日)
CREATE OR REPLACE FUNCTION public.calculate_leave_days(p_start date, p_end date, p_start_half boolean DEFAULT false, p_end_half boolean DEFAULT false)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT GREATEST(
        (SELECT count(*)
         FROM generate_series(p_start, p_end, interval '1 day') d
         WHERE is_business_day(d::date))::numeric
        - CASE WHEN p_start_half THEN 0.5 ELSE 0 END
        - CASE WHEN p_end_half THEN 0.5 ELSE 0 END,
        0);
$function$;

-- ── 2. 解析器:返回【汇率 + 实际取自哪一天】,不抛异常 ──────────────────────
-- 不抛,是为了让 fx_rate_gaps 这类只读用途能直接问它(视图里没法捕异常)。
-- 要"缺了就报错"的语义,用下面的 fx_rate_for 包一层。
CREATE OR REPLACE FUNCTION public.fx_rate_asof(p_currency text, p_date date, p_rate_type text)
 RETURNS TABLE(rate numeric, as_of date)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base text;
    v_cap  integer := 4;   -- 自然日上限,理由见文件头
    v_rate numeric;
    v_when date;
BEGIN
    IF p_rate_type IS NULL OR p_rate_type NOT IN ('tt_buy', 'tt_sell', 'mid') THEN
        RAISE EXCEPTION 'FX_RATE_TYPE_INVALID|%', COALESCE(p_rate_type, '?');
    END IF;

    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    -- 本位币没有汇率这回事:恒 1,不查牌价表(FIN-0)
    IF p_currency = v_base THEN
        RETURN QUERY SELECT 1::numeric, p_date;
        RETURN;
    END IF;
    IF p_date IS NULL THEN
        RETURN;   -- 没有日期就没有"当日牌价",交给调用方拒绝
    END IF;

    SELECT r.rate_sgd_per_unit, r.rate_date INTO v_rate, v_when
    FROM fx_rates r
    WHERE r.currency = p_currency AND r.rate_type = p_rate_type AND r.deleted_at IS NULL
      AND r.rate_date <= p_date AND r.rate_date >= p_date - v_cap
    ORDER BY r.rate_date DESC
    LIMIT 1;

    IF v_rate IS NULL THEN
        RETURN;   -- 上限之内一条都没有
    END IF;

    -- 【关键一条】牌价日与交易日之间的每一天都必须是非发布日。
    -- 夹着工作日 = 那天该录没录,不能拿更早的价蒙混过去。
    IF EXISTS (
        SELECT 1 FROM generate_series(v_when + 1, p_date - 1, interval '1 day') d
        WHERE is_business_day(d::date)
    ) THEN
        RETURN;
    END IF;

    RETURN QUERY SELECT v_rate, v_when;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.fx_rate_asof(text, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fx_rate_asof(text, date, text) TO authenticated, service_role;

-- ── 3. fx_rate_for:薄包装,缺了就抛(错误文案与参数一字未变)────────────────
CREATE OR REPLACE FUNCTION public.fx_rate_for(p_currency text, p_date date, p_rate_type text)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_rate numeric;
BEGIN
    SELECT a.rate INTO v_rate FROM fx_rate_asof(p_currency, p_date, p_rate_type) a;
    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_MISSING|%|%|%', p_currency, p_date, p_rate_type;
    END IF;
    RETURN v_rate;
END;
$function$;

-- ── 4. 分录行留痕:用的是哪一天的牌价 ───────────────────────────────────────
-- 只有金额和汇率,几个月后没人能解释"这笔为什么按 1.35 折" —— 尤其当它取自
-- 前一个发布日时。NULL 有明确含义:这个汇率【不是】来自牌价表
-- (本位币行,或跨币种结算里水单上的实际成交价)。
ALTER TABLE public.journal_lines ADD COLUMN fx_rate_date date;

COMMENT ON COLUMN public.journal_lines.fx_rate_date IS
    '该行汇率取自牌价表的哪一天(可能早于分录日:周末取上一个发布日)。NULL = 非牌价来源(本位币,或实际成交价)。';

CREATE OR REPLACE FUNCTION public.post_journal_entry(p_entry_date date, p_memo text, p_source_type text, p_source_id uuid, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_locked       date;
    v_line         jsonb;
    v_account      record;
    v_side         text;
    v_currency     text;
    v_amount       numeric;
    v_fx           numeric;
    v_usd          numeric;
    v_fx_date      date;
    v_base         text;
    v_total_debit  numeric := 0;
    v_total_credit numeric := 0;
    v_count        integer := 0;
    v_year         integer;
    v_seq          integer;
    v_code         text;
    v_entry_id     uuid;
BEGIN
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    IF p_entry_date IS NULL THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
    END IF;

    -- 期间锁:早于 locked_before 的日期拒绝
    SELECT locked_before INTO v_locked FROM finance_settings WHERE id;
    IF v_locked IS NOT NULL AND p_entry_date < v_locked THEN
        RAISE EXCEPTION 'PERIOD_LOCKED|%|%', p_entry_date, v_locked;
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|lines';
    END IF;

    -- 无缝编号:咨询锁串行化"取当年最大号+1";失败回滚会释放号码。
    PERFORM pg_advisory_xact_lock(hashtext('je_code')::bigint);
    v_year := EXTRACT(YEAR FROM p_entry_date)::integer;
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM journal_entries
    WHERE code LIKE 'JE-' || v_year::text || '-%';
    v_code := 'JE-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    INSERT INTO journal_entries (code, entry_date, memo, source_type, source_id)
    VALUES (v_code, p_entry_date, p_memo, p_source_type, p_source_id)
    RETURNING id INTO v_entry_id;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_count := v_count + 1;

        SELECT id, code, is_active INTO v_account
        FROM accounts WHERE code = v_line->>'account_code';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ACCOUNT_NOT_FOUND|%', COALESCE(v_line->>'account_code', '?');
        END IF;
        IF NOT v_account.is_active THEN
            RAISE EXCEPTION 'ACCOUNT_INACTIVE|%', v_account.code;
        END IF;

        v_side := v_line->>'side';
        IF v_side IS NULL OR v_side NOT IN ('debit', 'credit') THEN
            RAISE EXCEPTION 'JE_LINE_INVALID|side';
        END IF;

        v_amount := (v_line->>'amount_ccy')::numeric;
        IF v_amount IS NULL OR v_amount <= 0 THEN
            RAISE EXCEPTION 'JE_LINE_INVALID|amount_ccy';
        END IF;

        v_currency := v_line->>'currency';
        IF v_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = v_currency) THEN
            RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(v_currency, '?');
        END IF;

        v_fx_date := NULLIF(v_line->>'fx_rate_date', '')::date;
        IF v_currency = v_base THEN
            v_fx := 1;
            v_fx_date := NULL;  -- 本位币没有取自哪天这回事  -- 本位币(FIN-0 起为 SGD)强制 1,忽略传入值
        ELSE
            v_fx := (v_line->>'fx_rate')::numeric;
            IF v_fx IS NULL THEN
                RAISE EXCEPTION 'FX_RATE_REQUIRED|%', v_currency;
            END IF;
            IF v_fx <= 0 THEN
                RAISE EXCEPTION 'JE_LINE_INVALID|fx_rate';
            END IF;
        END IF;

        v_usd := round(v_amount * v_fx, 2);

        INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate, fx_rate_date, line_memo)
        VALUES (
            v_entry_id,
            v_account.id,
            CASE WHEN v_side = 'debit'  THEN v_usd ELSE 0 END,
            CASE WHEN v_side = 'credit' THEN v_usd ELSE 0 END,
            v_currency,
            v_amount,
            v_fx,
            v_fx_date,
            v_line->>'line_memo'
        );

        IF v_side = 'debit' THEN
            v_total_debit := v_total_debit + v_usd;
        ELSE
            v_total_credit := v_total_credit + v_usd;
        END IF;
    END LOOP;

    -- 空数组/单行:延迟触发器只在有行插入时排队,这里提前拦掉(否则空分录溜过)
    IF v_count < 2 THEN
        RAISE EXCEPTION 'JOURNAL_UNBALANCED|%|%|%', v_code, v_total_debit, v_total_credit;
    END IF;

    -- Σdebit = Σcredit 由 DEFERRED 触发器在提交时强制
    RETURN jsonb_build_object(
        'entry_id', v_entry_id,
        'code', v_code,
        'total_debit', v_total_debit,
        'total_credit', v_total_credit
    );
END;
$function$;

-- ── 5. 缺牌价告警:问解析器,不再自己判"当天有没有" ─────────────────────────
-- 周六被周五的牌价覆盖【不是缺口】。照旧口径报出来只会把操作员训练成无视告警。
CREATE OR REPLACE VIEW public.fx_rate_gaps WITH (security_invoker = on) AS
 SELECT d.rate_date,
    d.currency,
    m.missing_types,
    d.txn_count
   FROM ( SELECT e.entry_date AS rate_date,
            l.currency,
            count(DISTINCT l.entry_id) AS txn_count
           FROM journal_lines l
             JOIN journal_entries e ON e.id = l.entry_id
          WHERE l.currency <> (SELECT c.code FROM currencies c WHERE c.is_base)
            AND e.status = 'posted'::text
          GROUP BY e.entry_date, l.currency) d
     CROSS JOIN LATERAL ( SELECT array_agg(t.t) AS missing_types
           FROM unnest(ARRAY['tt_buy'::text, 'tt_sell'::text, 'mid'::text]) t(t)
          WHERE NOT EXISTS (SELECT 1 FROM fx_rate_asof(d.currency, d.rate_date, t.t))) m
  WHERE m.missing_types IS NOT NULL;

-- ── 6. 假日表覆盖提醒 ───────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.hr_alerts WITH (security_invoker = on) AS
 SELECT 'work_pass_expiry'::text AS alert_type,
        CASE
            WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    COALESCE(e.work_pass_type, 'Work pass'::text) AS subject,
    e.work_pass_expiry_date AS due_date,
    e.work_pass_expiry_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND e.work_pass_expiry_date IS NOT NULL AND (e.work_pass_expiry_date - CURRENT_DATE) <= 90 AND (e.work_pass_expiry_date - CURRENT_DATE) >= '-30'::integer
UNION ALL
 SELECT 'probation_ending'::text AS alert_type,
        CASE
            WHEN (e.probation_end_date - CURRENT_DATE) <= 14 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation'::text AS subject,
    e.probation_end_date AS due_date,
    e.probation_end_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND e.probation_end_date IS NOT NULL AND e.probation_end_date >= CURRENT_DATE AND (e.probation_end_date - CURRENT_DATE) <= 30 AND NOT (EXISTS ( SELECT 1
           FROM performance_reviews r
          WHERE r.employee_id = e.id AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome = 'confirm'::text))
UNION ALL
 SELECT 'probation_overdue'::text AS alert_type,
    'expired'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation ended without a decision'::text AS subject,
    e.probation_end_date AS due_date,
    e.probation_end_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND e.probation_end_date IS NOT NULL AND e.probation_end_date < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
           FROM performance_reviews r
          WHERE r.employee_id = e.id AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome IS NOT NULL))
UNION ALL
 SELECT 'probation_not_confirmed'::text AS alert_type,
    'expired'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation not confirmed — separation is a manual decision'::text AS subject,
    COALESCE(e.probation_end_date, r.approved_at::date) AS due_date,
    COALESCE(e.probation_end_date, r.approved_at::date) - CURRENT_DATE AS days_remaining
   FROM employees e
     JOIN performance_reviews r ON r.employee_id = e.id
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome = 'not_confirm'::text
UNION ALL
 SELECT 'salary_not_set'::text AS alert_type,
        CASE
            WHEN e.employment_status = 'notice'::text THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Monthly fixed gross not set — leave encashment cannot be computed'::text AS subject,
    NULL::date AS due_date,
    NULL::integer AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND (e.employment_status = ANY (ARRAY['probation'::text, 'active'::text, 'notice'::text])) AND NOT e.monthly_salary_set
UNION ALL
 SELECT 'review_no_reviewer'::text AS alert_type,
    'critical'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    COALESCE(c.name, 'Probation review'::text) || ' — no reviewer assigned'::text AS subject,
    c.due_date,
    c.due_date - CURRENT_DATE AS days_remaining
   FROM performance_reviews r
     JOIN employees e ON e.id = r.employee_id
     LEFT JOIN review_cycles c ON c.id = r.cycle_id
  WHERE r.reviewer_employee_id IS NULL AND (r.status <> ALL (ARRAY['approved'::text, 'acknowledged'::text, 'void'::text])) AND e.deleted_at IS NULL
UNION ALL
 SELECT 'review_cycle_overdue'::text AS alert_type,
    'critical'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    c.name AS subject,
    c.due_date,
    c.due_date - CURRENT_DATE AS days_remaining
   FROM performance_reviews r
     JOIN review_cycles c ON c.id = r.cycle_id
     JOIN employees e ON e.id = r.employee_id
  WHERE c.deleted_at IS NULL AND c.status = 'open'::text AND c.due_date < CURRENT_DATE AND (r.status = ANY (ARRAY['draft'::text, 'self_review'::text]))
UNION ALL
 SELECT 'cpf_due'::text AS alert_type,
        CASE
            WHEN (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date < CURRENT_DATE THEN 'expired'::text
            WHEN ((date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE) <= 3 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    NULL::uuid AS employee_id,
    p.code AS employee_code,
    'CPF'::text AS employee_name,
    'CPF contribution unpaid — due 14th of the following month, late payment attracts interest'::text AS subject,
    (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date AS due_date,
    (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE AS days_remaining
   FROM payroll_periods p
  WHERE p.deleted_at IS NULL AND p.status = 'posted'::text AND p.cpf_paid_at IS NULL AND (COALESCE(p.employer_cpf_total, 0::numeric) + COALESCE(p.employee_cpf_total, 0::numeric)) > 0::numeric AND ((date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE) <= 7
UNION ALL
 SELECT 'training_expiry'::text AS alert_type,
        CASE
            WHEN t.expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (t.expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    t.training_name AS subject,
    t.expiry_date AS due_date,
    t.expiry_date - CURRENT_DATE AS days_remaining
   FROM training_records t
     JOIN employees e ON e.id = t.employee_id
  WHERE t.deleted_at IS NULL AND e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND t.expiry_date IS NOT NULL AND (t.expiry_date - CURRENT_DATE) <= 90 AND (t.expiry_date - CURRENT_DATE) >= '-30'::integer
UNION ALL
-- 【假日表快没数据了】public_holidays 是承重的:calculate_leave_days 用它算请假
-- 天数(经 submit_leave_request),fx_rate_asof 用它判断哪天不发布牌价。
-- 表里只到 2026 —— 跨年那天,FX 会开始拒绝(吵,但看得见),而【请假天数会静默
-- 算错】(把假日算成工作日)。两个模块同时出问题,却没有任何东西会提醒。
-- 所以每年第四季度起,如果下一年一条都没有,就摆到待办上。
 SELECT 'holiday_calendar_missing'::text AS alert_type,
    CASE WHEN EXTRACT(MONTH FROM CURRENT_DATE) = 12 THEN 'critical'::text
         ELSE 'warning'::text END AS severity,
    NULL::uuid AS employee_id,
    ''::text AS employee_code,
    ''::text AS employee_name,
    (EXTRACT(YEAR FROM CURRENT_DATE) + 1)::text AS subject,
    make_date((EXTRACT(YEAR FROM CURRENT_DATE) + 1)::integer, 1, 1) AS due_date,
    make_date((EXTRACT(YEAR FROM CURRENT_DATE) + 1)::integer, 1, 1) - CURRENT_DATE AS days_remaining
  WHERE EXTRACT(MONTH FROM CURRENT_DATE) >= 10
    AND NOT EXISTS (
        SELECT 1 FROM public_holidays h
        WHERE h.is_active AND h.country = 'SG'
          AND EXTRACT(YEAR FROM h.holiday_date) = EXTRACT(YEAR FROM CURRENT_DATE) + 1);

COMMIT;
