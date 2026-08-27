-- CASHFLOW-1:13 周现金预测,以及它读的那套【预计日期】机器
--
-- 合并成一刀是刻意的:预测的输入【今天不以日期的形式存在】,先建预测就会得到
-- 一张"带图表的录入屏"。所以日期机器先建,预测读它。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §0 · 实测,它们决定了这一刀的形状(勘察量过一次,这里逐条复核并纠正)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ★【一】今天【折不出】美元 —— 而现金横跨两个币种 ★
--   bank_book_balance_asof 按【各账户自己的币种】返回:1000 = SGD −128,816.00,
--   1010 = **USD** −29,753.70。而实测:
--       fx_rate_for('USD', 2026-08-28, 'mid') → FX_RATE_MISSING|USD|2026-08-28|mid
--   最近的 mid 是 2026-07-31,tt_buy/tt_sell 最近 2026-08-17 —— 都超出了
--   FIN-19 那个 4 天的回溯上限。**所以一个"本位币合计"今天要么按名拒、
--   要么编一个汇率**,而后者正是 THE FX RULE 明令禁止的。
--   → 于是预测【按币种分桶】(week, currency)。本位币合计只在【每一个】
--     涉及的币种都有汇率时才出现;否则那一格是【一个有名字的缺席】,不是 0。
--
-- ★【二】勘察那句"AP 与 AR 都没有到期日"对 AR 已经过时 ★
--   实测 ar_aging_asof:9 行里 **6 行有到期日、合计 34,680.00 本位币**,
--   而且全部落在未来 13 周之内(8-30 → 9-25);3 行 / 22,763.00 没有。
--   到期日来自【挂上去的发票】(invoices.due_date 6/6 已填)——
--   **开票才是那个给出日期的动作**,这也解释了为什么 AR 好转而 AP 没有。
--   AP 那侧 ap_open_items **压根没有 due_date 这一列**,13 行 429,537.62 全部无日期。
--
-- ★【三】工资那个"最可靠的日期"现在是【过去】★
--   payroll_periods 只有 1 行,payment_date = 2026-07-31。对一个从今天起算的
--   预测,它一分钱都贡献不了。勘察把它称作"这一组里最可靠的日期",
--   那句话当时是对的,今天它指向的是一个空集。
--
-- ★【四】销售订单 0 张未结(勘察说 6 张)★ 实测:3 cancelled / 2 draft / 1 shipped。
--
-- ★【五】经常性成本仍然【一张表都没有】★(recurring|schedule|subscription|opex → 无)
--
-- ★【六】12 条【活着的】分期,而它们背后是这门生意最大的一笔现金 ★
--   purchase_order_payment_terms 15 行,其中 3 行挂在已关闭的 PO 上;
--   活着的 12 行分属 4 张未结 PO,合计 **SGD 400,000 + USD 6,815**。
--   due_date 0/15,trigger_event 15/15。也就是说:**这门生意最大的一笔现金
--   支出(PO-2026-0007,SGD 400,000)对今天的预测【完全不可见】。**
--   这一刀真正买到的东西就是它。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §1 · 五种触发事件里,只有三种需要【估计】—— 这是被约束读出来的,不是选的
-- ═══════════════════════════════════════════════════════════════════════════
--   · fixed_date —— 表上【已经有】一条 CHECK:trigger_event <> 'fixed_date'
--        OR due_date IS NOT NULL。也就是说它【本来就带着一个真日期】。
--   · on_order  —— 事件就是"下单",而下单日是 purchase_orders.order_date,
--        一个【事实】。不需要估计,也不该估计。
--   · on_shipment / on_arrival / post_assay —— 这三种的日期【还没发生】,
--        只能是估计。而 Tim 恰好为这三种指定了 owner。三对三,不是巧合。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §2 · 估计【不是】事实,但也不是没有 —— 三件事把它们分开
-- ═══════════════════════════════════════════════════════════════════════════
--   ① 它存在【另一列】里:expected_date,永远不写进 due_date。
--      due_date 在这张表上的含义是"合同约定的日子"(fixed_date 那一种),
--      把估计写进去会让一个猜测长得和一条合同条款一模一样。
--   ② 它带着【谁设的、什么时候设的】(expected_date_set_by / _set_at)——
--      一个没有出处的估计,下一个人无从判断它是上周想的还是三个月前想的。
--   ③ 它有一个【按事件类型指定的保管人】(payment_event_owners)。
--      AGENTS.md 那条:一个没人拥有的估计会停止被维护,而预测会安静地变成虚构。
--   ④ 到了预测那一层,它的 confidence 是 'estimated',与 'committed' 【不同
--      的渲染】,不是同一个样子换个字。

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1 · 预计日期:三列,加在【遮蔽表】上 —— 所以是三件事,在同一支迁移里
-- ───────────────────────────────────────────────────────────────────────────
-- ★ AGENTS.md 那条,这一刀正撞上它 ★
-- purchase_order_payment_terms 有 _masked 伴生视图,而 authenticated 在它上面
-- **没有表级 SELECT**(relacl 里没有 r),走的是【列级】授权。
-- 列级 SELECT 授权【不会】自动延伸到后加的列 —— 于是新列会变成
-- "写得进、读不出",而任何 SELECT 或哪怕只是 WHERE 过滤都会 42501。
-- FIN-6 就是这么让 /finance/processing-costs 从上线那天起一直是空的。
-- 所以:ADD COLUMN + 列级 GRANT + _masked 视图,**三件,一支迁移**(WO-1a 把
-- 它们拆成三刀,每一步单看都像做完了,而 gate 的 colgrant 连着红了两轮)。
ALTER TABLE public.purchase_order_payment_terms
    ADD COLUMN expected_date        date,
    ADD COLUMN expected_date_set_by uuid,
    ADD COLUMN expected_date_set_at timestamptz;

COMMENT ON COLUMN public.purchase_order_payment_terms.expected_date IS
    'CASHFLOW-1:这一期【预计】什么时候付 —— 一个估计,不是一个事实。★【为什么不写进 due_date】★ due_date 在这张表上的含义是"合同约定的日子"(表上那条 CHECK 要求 fixed_date 那一种必须有它);把估计写进去,会让一个猜测长得和一条合同条款一模一样。三种事件才需要它:on_shipment / on_arrival / post_assay —— 另外两种不需要,因为 fixed_date 已经有真日期,而 on_order 的日子是 purchase_orders.order_date 这个事实。谁设的、何时设的在旁边两列;按事件类型的保管人在 payment_event_owners。到了预测那一层它的 confidence 是 estimated,与 committed 【不同的渲染】。';

-- ② 列级授权 —— 三列都不敏感,照直授
GRANT SELECT (expected_date, expected_date_set_by, expected_date_set_at)
    ON public.purchase_order_payment_terms TO authenticated;

-- ③ _masked 视图必须【每一列都在】—— colgrant 的谓词是
--    (NOT granted AND NOT in_view) OR (has_view AND NOT in_view):
--    一张表一旦有了 _masked 伴生视图,它的每一列都得在视图里,授不授权都一样。
CREATE OR REPLACE VIEW public.purchase_order_payment_terms_masked
WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_id,
    seq,
    label,
    percentage,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN fixed_amount_ccy
            ELSE NULL::numeric
        END AS fixed_amount_ccy,
    trigger_event,
    due_date,
    notes,
    created_at,
    expected_date,
    expected_date_set_by,
    expected_date_set_at
   FROM purchase_order_payment_terms
  WHERE has_permission('module.purchasing.view'::text);

-- ───────────────────────────────────────────────────────────────────────────
-- 2 · payment_event_owners —— 估计的保管人,按【事件类型】
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE public.payment_event_owners (
    trigger_event text PRIMARY KEY
        CHECK (trigger_event IN ('on_shipment', 'on_arrival', 'post_assay')),
    -- ★【为什么是文本而不是 employees 的外键】★ 实测:Sandra Yap 与
    -- Fu Sheng Wong **不在 employees 里**(21 名员工,一个都对不上)。
    -- 做成外键只有两条路:要么种子灌不进去(重建库当场失败),要么【替他们
    -- 编两行员工档案】—— 而后者是凭空造一个人事实。所以先记名字。
    -- 他们成为在册员工的那一天,加一列可空的 employee_id 是一次小改动;
    -- 而现在把它做成外键,是让一条真裁定去迁就一个还不存在的表。
    owner_name    text NOT NULL,
    note          text,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid
);

COMMENT ON TABLE public.payment_event_owners IS
    'CASHFLOW-1:每一种【需要估计的】付款触发事件,谁来保管那个估计。Tim 2026-08-24 裁定:on_shipment → Sandra Yap;on_arrival → Fu Sheng Wong;post_assay → Fu Sheng Wong。【为什么只有三种】另外两种不需要估计:fixed_date 由表上那条 CHECK 保证已经带着真日期,on_order 的日子是 purchase_orders.order_date 这个事实。【为什么 owner 是文本不是外键】实测那两位不在 employees 里(21 名员工,一个都对不上);做成外键要么让重建库灌不进种子,要么逼人替他们编两行员工档案。他们在册那天再加 employee_id 是小事;现在做成外键是让一条真裁定去迁就一个还不存在的行。【它为什么必须存在】一个没人拥有的估计会停止被维护,而一份读着停止维护的估计的预测,会安静地变成虚构 —— 这一刀的全部风险就在这里。';

ALTER TABLE public.payment_event_owners ENABLE ROW LEVEL SECURITY;

CREATE POLICY "payment_event_owners select by permission" ON public.payment_event_owners
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text)
        OR has_permission('module.finance.view'::text));

-- 种子:Tim 的裁定,逐字
INSERT INTO public.payment_event_owners (trigger_event, owner_name, note) VALUES
    ('on_shipment', 'Sandra Yap',    '装运日的预计由商务侧保管 —— 她在跟船期'),
    ('on_arrival',  'Fu Sheng Wong', '到港日的预计由运营侧保管'),
    ('post_assay',  'Fu Sheng Wong', '化验完成日的预计由运营侧保管 —— 实验室周转是他在盯')
ON CONFLICT (trigger_event) DO NOTHING;

-- ───────────────────────────────────────────────────────────────────────────
-- 3 · cash_forecast_lines —— 手工那一半:经常性成本 + 一次性
-- ───────────────────────────────────────────────────────────────────────────
-- 【一张表,两个用途】cadence 里带一个 'once':
--   · cadence <> 'once' 的行 = 【固定 OPEX 集合】,KPI T2 的「≥3 个月固定 OPEX
--     现金储备」量的就是它;
--   · cadence = 'once' 的行 = 已知的一次性(一笔设备尾款、一次年检)。
-- 分成两张表要维护两处"我们预计还要付什么";多加一个 is_fixed_opex 标志则要
-- 与 cadence 保持一致,而两个必须保持一致的字段最后总会不一致。
CREATE TABLE public.cash_forecast_lines (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    label       text NOT NULL,
    direction   text NOT NULL CHECK (direction IN ('in', 'out')),
    amount_ccy  numeric NOT NULL CHECK (amount_ccy > 0),
    currency    text NOT NULL REFERENCES public.currencies (code),
    cadence     text NOT NULL CHECK (cadence IN ('once','weekly','monthly','quarterly','annual')),
    -- 【第一次发生的日子:必填,绝不默认】AGENTS.md 那条 —— 一个决定这笔钱
    -- 落在哪一周的日期,给它 CURRENT_DATE 默认值就是奖励留空。
    start_date  date NOT NULL,
    end_date    date,
    notes       text,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid,
    CONSTRAINT cash_forecast_lines_window CHECK (end_date IS NULL OR end_date >= start_date)
);

COMMENT ON TABLE public.cash_forecast_lines IS
    'CASHFLOW-1:预测里【手工录入】的那一半 —— 租金、保险、一笔已知的一次性支出。给定实测(AP 一个日期都没有、经常性成本一张表都没有),这一半不是补充,它是预测能不能用的前提。【一张表,两个用途】cadence 带一个 once:非 once 的行就是【固定 OPEX 集合】,KPI T2 的「≥3 个月固定 OPEX」量的正是它;once 的行是已知的一次性。分两张表要维护两处"我们还要付什么";加一个 is_fixed_opex 标志要与 cadence 保持一致,而两个必须保持一致的字段最后总会不一致。【它在预测里的 confidence 永远是 manual】—— 既不是合同约定的日子,也不是有主的估计,而屏幕上必须看得出这个区别。start_date 必填、不默认。';

CREATE INDEX idx_cash_forecast_lines_active ON public.cash_forecast_lines (is_active, start_date);

ALTER TABLE public.cash_forecast_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "cash_forecast_lines select by permission" ON public.cash_forecast_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
CREATE POLICY "cash_forecast_lines write by permission" ON public.cash_forecast_lines
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.finance.edit'::text))
    WITH CHECK (has_permission('module.finance.edit'::text));

-- ───────────────────────────────────────────────────────────────────────────
-- 4 · cash_forecasts —— 每周冻下来的那一份
-- ───────────────────────────────────────────────────────────────────────────
-- 【为什么要冻】KPI T1 要的是「未来 4 周的预测偏差在 ±10% 以内」——
-- 偏差是拿【过去某一份预测】与后来真的发生的事去比。只在内存里算的预测,
-- 那个指标【无从度量】。冻结的形状是这个仓库的第四次:gst_return_boxes(申报值)、
-- bank_reconciliations(不可变事件行)、customer_statements(寄出去的那一份)。
-- 【冻什么】数字、分周分币种的桶,【以及明细行】—— 与 STATEMENT-1 同一条:
-- 偏差分析问的是"哪一行动了",而只有冻下来的明细答得出。
CREATE TABLE public.cash_forecasts (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code              text NOT NULL UNIQUE,
    week_start        date NOT NULL,
    horizon_weeks     integer NOT NULL DEFAULT 13 CHECK (horizon_weeks > 0),
    opening           jsonb NOT NULL,   -- 每个现金账户一项,各按【自己的币种】
    buckets           jsonb NOT NULL,   -- (币种 × 周) 的进/出/净/期末
    lines             jsonb NOT NULL,   -- 明细,每行带 source 与 confidence
    undated           jsonb NOT NULL,   -- 有钱、没有日期的那些(预测看不见的部分)
    promises_memo     jsonb NOT NULL,   -- 客户承诺:【备查,不计入合计】
    buffer            jsonb NOT NULL,   -- 每币种的固定 OPEX 与覆盖月数
    base_currency     text NOT NULL REFERENCES public.currencies (code),
    frozen_at         timestamptz NOT NULL DEFAULT now(),
    frozen_by         uuid,
    superseded_at     timestamptz,
    superseded_by     uuid REFERENCES public.cash_forecasts (id),
    superseded_reason text,
    CONSTRAINT cash_forecasts_supersede_shape
        CHECK ((superseded_at IS NULL) = (superseded_by IS NULL))
);

COMMENT ON TABLE public.cash_forecasts IS
    'CASHFLOW-1:某一周冻下来的那一份 13 周现金预测。【为什么要冻】KPI T1 量的是「未来 4 周的预测偏差 ±10% 以内」—— 偏差要拿【过去那一份】去比,只在内存里算的预测那个指标无从度量。这是这个仓库冻结形状的第四次(gst_return_boxes / bank_reconciliations / customer_statements)。【冻到明细】与 STATEMENT-1 同一条:偏差分析问的是"哪一行动了",冻合计答不出。【重出是新的一行】同一周再冻一次 = 新行 + 旧行落 superseded_at 与必填理由,旧的不删 —— 它正是偏差要比的那个基准,覆盖掉就把度量本身毁了。【为什么没有本位币合计这一列】实测今天 USD 折不出 SGD(FX_RATE_MISSING),所以合计【按币种】存在 buckets 里;一个跨币种的合计只在每个币种都有汇率时才谈得上,而那件事由读的人在页面上看到"有没有"。';

CREATE INDEX idx_cash_forecasts_week ON public.cash_forecasts (week_start DESC);

ALTER TABLE public.cash_forecasts ENABLE ROW LEVEL SECURITY;

-- 没有 INSERT/UPDATE/DELETE 策略:唯一写入口是 freeze_cash_forecast(属主权限)
CREATE POLICY "cash_forecasts select by permission" ON public.cash_forecasts
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- ───────────────────────────────────────────────────────────────────────────
-- 5 · 取号器 + 预计日期的写入口
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_forecast_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text LANGUAGE plpgsql SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_year integer := EXTRACT(YEAR FROM p_date)::integer; v_seq integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('forecast_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
      FROM cash_forecasts WHERE code LIKE 'FCST-' || v_year::text || '-%';
    RETURN 'FCST-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_payment_term_expected_date(
    p_term_id       uuid,
    p_expected_date date
)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_t purchase_order_payment_terms%ROWTYPE; v_owner text;
BEGIN
    PERFORM require_permission('module.purchasing.edit');

    SELECT * INTO v_t FROM purchase_order_payment_terms WHERE id = p_term_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_TERM_NOT_FOUND|%', COALESCE(p_term_id::text, '?');
    END IF;
    -- 【只有需要估计的那三种才谈得上"预计日期"】另外两种已经有真日期:
    -- fixed_date 由表上那条 CHECK 保证,on_order 的日子是 PO 的下单日。
    -- 给它们再加一个估计,就是在一个事实旁边放一个猜测,让人去挑。
    SELECT owner_name INTO v_owner FROM payment_event_owners WHERE trigger_event = v_t.trigger_event;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPECTED_DATE_NOT_APPLICABLE|%', v_t.trigger_event;
    END IF;
    IF p_expected_date IS NULL THEN
        -- 清空是允许的(估计可以被撤回),但要走同一支函数,留下痕迹
        UPDATE purchase_order_payment_terms
           SET expected_date = NULL, expected_date_set_by = auth.uid(), expected_date_set_at = now()
         WHERE id = p_term_id;
        RETURN jsonb_build_object('term_id', p_term_id, 'expected_date', NULL, 'owner', v_owner);
    END IF;
    -- 【一个"预计在过去"的日期不是预计,是没人维护的痕迹】按名拒,并说出保管人是谁。
    IF p_expected_date < CURRENT_DATE THEN
        RAISE EXCEPTION 'EXPECTED_DATE_IN_PAST|%|%|%',
            p_expected_date::text, CURRENT_DATE::text, v_owner;
    END IF;

    UPDATE purchase_order_payment_terms
       SET expected_date = p_expected_date,
           expected_date_set_by = auth.uid(),
           expected_date_set_at = now()
     WHERE id = p_term_id;

    RETURN jsonb_build_object('term_id', p_term_id, 'expected_date', p_expected_date,
                              'trigger_event', v_t.trigger_event, 'owner', v_owner);
END;
$function$;

COMMENT ON FUNCTION public.set_payment_term_expected_date(uuid, date) IS
    'CASHFLOW-1:给一期分期设【预计付款日】—— 一个估计,不是一个事实。三件事写在这里:① 只有 on_shipment / on_arrival / post_assay 三种事件谈得上预计,另外两种按名拒(EXPECTED_DATE_NOT_APPLICABLE)—— fixed_date 已经有真日期(表上那条 CHECK),on_order 的日子是 PO 的下单日;在一个事实旁边放一个猜测,只会让人去挑。② 预计日期【不能在过去】(EXPECTED_DATE_IN_PAST),而拒绝的话里带上保管人的名字 —— 一个"预计在上周"的日期不是预计,是没人维护的痕迹。③ 每次写入都记下【谁设的、什么时候】,因为一个没有出处的估计,下一个人无从判断它是上周想的还是三个月前想的。清空是允许的(估计可以撤回),但走同一支函数,同样留痕。';

-- ───────────────────────────────────────────────────────────────────────────
-- 6 · cash_forecast_data —— 活的那一份(预览),冻结那一支也读它
-- ───────────────────────────────────────────────────────────────────────────
-- ★【周界:周一】★ date_trunc('week') 在 PostgreSQL 里就是 ISO 周一。
-- 理由不是习惯:KPI 的节奏是"每周更新",而新加坡的银行与工资周是周一到周五 ——
-- 把周界放在周一,一个工作周不会被切成两半,而"这一周还要付什么"是个完整的问题。
--
-- ★【一处实现,两个调用方】★ 预览与冻结读【同一支】函数(AGENTS.md 那条,
-- 这个仓库为"屏幕自己把规则重写一遍"付过四次账)。
--
-- ★【复用,不重算】★ 期初走 bank_book_balance_asof(BANK-REC 建的那一支,
-- 它把行的取舍整个委托给 journal_activity_lines —— 而在它之前,
-- bank_reconciliation_status.ledger_balance 过滤 status='posted',线上 1010
-- 实测差 USD 1,585.00)。AR 走 ar_aging_asof,AP 走 ap_aging_asof ——
-- 与对账单、账龄表、催收屏幕【同源】。一份自己算 AR 合计的预测,
-- 是对账单印的那个数的第二份实现。
CREATE OR REPLACE FUNCTION public.cash_forecast_data(p_week_start date DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ws        date;
    v_end       date;
    v_asof      date;
    v_base      text;
    v_raw       jsonb;
    v_opening   jsonb;
    v_lines     jsonb;
    v_undated   jsonb;
    v_promises  jsonb;
    v_buckets   jsonb;
    v_buffer    jsonb;
    v_ccys      text[];
    v_missing   text[] := '{}';
    c           text;
    v_dummy     numeric;
BEGIN
    PERFORM require_permission('module.finance.view');

    v_ws := COALESCE(p_week_start, date_trunc('week', CURRENT_DATE)::date);
    IF v_ws <> date_trunc('week', v_ws)::date THEN
        RAISE EXCEPTION 'FORECAST_WEEK_START_NOT_MONDAY|%', v_ws::text;
    END IF;
    v_end  := v_ws + 91;                      -- 13 周,右开
    -- 【仓位读到哪一天】期初与 AR/AP 的仓位取【预测开始的前一天】;
    -- 而 ar/ap_aging_asof 拒绝未来的截至日(AGING_AS_OF_FUTURE),
    -- 所以往前推的那一份最多读到今天 —— 一份"从下周起"的预测,
    -- 它的期初就是今天的期初,而这是诚实的:未来的仓位没人知道。
    v_asof := LEAST(v_ws - 1, CURRENT_DATE);
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ══ 期初:每个现金账户按【它自己的币种】════════════════════════════════
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'account_code', a.code,
               'account_name', a.name_en,
               'currency',     bank_native_currency(a.code),
               'amount',       bank_book_balance_asof(a.code, v_asof)
           ) ORDER BY a.code), '[]'::jsonb)
      INTO v_opening
      FROM accounts a WHERE a.is_cash;

    -- ══ 所有候选行(日期可能是 NULL —— 那正是要说出来的那一半)═══════════
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.due NULLS LAST, r.source, r.label), '[]'::jsonb)
      INTO v_raw
      FROM (
        -- AR:开了票的才有到期日,而到期日来自发票(实测 6/9 有)
        SELECT 'ar'::text AS source, 'committed'::text AS confidence, 'in'::text AS direction,
               e->>'currency' AS currency, (e->>'open_ccy')::numeric AS amount,
               NULLIF(e->>'due_date','')::date AS due,
               COALESCE(e->>'customer_name','?') AS label,
               COALESCE(e->>'invoice_code', e->>'doc_code') AS ref,
               NULL::text AS owner_name
          FROM jsonb_array_elements((ar_aging_asof(v_asof))->'rows') e
        UNION ALL
        -- AP:实测 0/13 有到期日 —— 整块落进"无日期"
        SELECT 'ap', 'committed', 'out',
               e->>'currency', (e->>'open_ccy')::numeric,
               NULLIF(e->>'due_date','')::date,
               COALESCE(e->>'supplier_name','?'), e->>'doc_code', NULL
          FROM jsonb_array_elements((ap_aging_asof(v_asof))->'rows') e
        UNION ALL
        -- PO 分期:五种事件,三种是估计、两种是事实
        SELECT 'po_instalment',
               CASE WHEN t.trigger_event IN ('fixed_date','on_order') THEN 'committed'
                    ELSE 'estimated' END,
               'out', po.currency,
               COALESCE(t.fixed_amount_ccy,
                        round(COALESCE(po.estimated_total_ccy,0) * COALESCE(t.percentage,0) / 100.0, 2)),
               CASE t.trigger_event WHEN 'fixed_date' THEN t.due_date
                                    WHEN 'on_order'   THEN po.order_date
                                    ELSE t.expected_date END,
               po.code || ' · ' || COALESCE(NULLIF(t.label,''), t.trigger_event),
               po.code, o.owner_name
          FROM purchase_order_payment_terms t
          JOIN purchase_orders po ON po.id = t.purchase_order_id
          LEFT JOIN payment_event_owners o ON o.trigger_event = t.trigger_event
         WHERE po.deleted_at IS NULL AND po.status IN ('confirmed','receiving')
        UNION ALL
        -- 工资:payment_date 是一个承诺
        SELECT 'payroll', 'committed', 'out', pp.currency,
               COALESCE(pp.net_pay_total,0) + COALESCE(pp.employer_cpf_total,0),
               pp.payment_date, 'Payroll ' || pp.code, pp.code, NULL
          FROM payroll_periods pp WHERE pp.deleted_at IS NULL
        UNION ALL
        -- 手工行,按 cadence 展开成一次次发生
        SELECT 'manual', 'manual', l.direction, l.currency, l.amount_ccy,
               occ.d::date, l.label, NULL, NULL
          FROM cash_forecast_lines l
          CROSS JOIN LATERAL generate_series(
                 l.start_date::timestamp,
                 LEAST(COALESCE(l.end_date, v_end), v_end)::timestamp,
                 CASE l.cadence WHEN 'weekly'    THEN interval '7 days'
                                WHEN 'monthly'   THEN interval '1 month'
                                WHEN 'quarterly' THEN interval '3 months'
                                WHEN 'annual'    THEN interval '1 year'
                                ELSE interval '1000 years' END) occ(d)
         WHERE l.is_active
      ) r;

    -- ══ 落得进 13 周的行 ═══════════════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(e || jsonb_build_object(
               'week_no', ((e->>'due')::date - v_ws) / 7 + 1)
           ORDER BY (e->>'due')::date, e->>'source'), '[]'::jsonb)
      INTO v_lines
      FROM jsonb_array_elements(v_raw) e
     WHERE e->>'due' IS NOT NULL
       AND (e->>'due')::date >= v_ws AND (e->>'due')::date < v_end
       AND (e->>'amount')::numeric <> 0;

    -- ══ ★【有钱、但落不进任何一周的那些】★ ════════════════════════════════
    -- 这是 4.5 那一条做成【结构】而不是脚注:一份悄悄漏掉大半应付的预测,
    -- 是一个会被人当真的数字。所以它们【出现在预测上】,只是拒绝被放进某一周。
    SELECT COALESCE(jsonb_agg(x ORDER BY x.source, x.currency), '[]'::jsonb)
      INTO v_undated
      FROM (
        SELECT e->>'source' AS source, e->>'direction' AS direction,
               e->>'currency' AS currency,
               count(*)::int AS row_count,
               round(sum((e->>'amount')::numeric), 2) AS amount,
               CASE WHEN e->>'due' IS NULL THEN 'no_date' ELSE 'before_window' END AS why,
               max(e->>'owner_name') AS owner_name
          FROM jsonb_array_elements(v_raw) e
         WHERE (e->>'amount')::numeric <> 0
           AND (e->>'due' IS NULL OR (e->>'due')::date < v_ws)
         GROUP BY 1,2,3,6
      ) x;

    -- ══ 客户承诺:【备查,不计入合计】═══════════════════════════════════════
    -- 一个承诺与它指向的那几张 AR 是【同一笔钱】,而 CHASE-1 实测过:
    -- 9 行未结 AR 里 8 行是未开票的销售,连一个客户认得的单号都没有 ——
    -- 系统【说不出】一个承诺覆盖的是哪几行。加进合计就是重复计算,
    -- 不放又丢掉了全系统唯一"客户自己答应过"的日期。所以:列出来,不求和。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'promise_id', ps.promise_id, 'chase_code', ps.chase_code,
               'customer_name', ps.customer_name,
               'currency', ps.currency, 'amount', ps.promised_amount_ccy,
               'promised_date', ps.promised_date,
               'week_no', (ps.promised_date - v_ws) / 7 + 1,
               'is_overdue', ps.is_overdue) ORDER BY ps.promised_date), '[]'::jsonb)
      INTO v_promises
      FROM collection_promise_status ps
     WHERE ps.is_open AND ps.promised_date >= v_ws AND ps.promised_date < v_end;

    -- ══ 币种集合:期初里出现的 ∪ 明细里出现的 ═════════════════════════════
    SELECT array_agg(DISTINCT c2 ORDER BY c2) INTO v_ccys FROM (
        SELECT e->>'currency' AS c2 FROM jsonb_array_elements(v_opening) e
        UNION SELECT e->>'currency' FROM jsonb_array_elements(v_lines) e
    ) q WHERE c2 IS NOT NULL;

    -- ══ 分周分币种的桶,带滚动期末 ═════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'currency', b.currency, 'week_no', b.week_no,
               'week_start', b.wstart, 'week_end', b.wstart + 6,
               'inflow', b.inflow, 'outflow', b.outflow, 'net', b.net,
               'closing', b.closing) ORDER BY b.currency, b.week_no), '[]'::jsonb)
      INTO v_buckets
      FROM (
        SELECT cc.currency, w.week_no, v_ws + (w.week_no - 1) * 7 AS wstart,
               COALESCE(agg.inflow, 0)  AS inflow,
               COALESCE(agg.outflow, 0) AS outflow,
               COALESCE(agg.inflow, 0) - COALESCE(agg.outflow, 0) AS net,
               op.open0 + sum(COALESCE(agg.inflow,0) - COALESCE(agg.outflow,0))
                   OVER (PARTITION BY cc.currency ORDER BY w.week_no) AS closing
          FROM unnest(COALESCE(v_ccys, '{}')) AS cc(currency)
          CROSS JOIN generate_series(1, 13) AS w(week_no)
          LEFT JOIN LATERAL (
                SELECT COALESCE(round(sum(CASE WHEN e->>'direction'='in'  THEN (e->>'amount')::numeric END),2),0) AS inflow,
                       COALESCE(round(sum(CASE WHEN e->>'direction'='out' THEN (e->>'amount')::numeric END),2),0) AS outflow
                  FROM jsonb_array_elements(v_lines) e
                 WHERE e->>'currency' = cc.currency AND (e->>'week_no')::int = w.week_no
          ) agg ON true
          LEFT JOIN LATERAL (
                SELECT COALESCE(round(sum((e->>'amount')::numeric),2),0) AS open0
                  FROM jsonb_array_elements(v_opening) e WHERE e->>'currency' = cc.currency
          ) op ON true
      ) b;

    -- ══ 固定 OPEX 与覆盖月数(KPI T2)═══════════════════════════════════════
    -- 【固定 OPEX = 经常性的那些,不含 once】一笔一次性的设备尾款不是 OPEX,
    -- 把它算进去会让覆盖月数随便一条一次性录入就跳一下。
    -- 【覆盖月数按【预测低点】,并把今天的一起列出】T2 的原话是"最低现金储备"
    -- 与"任何【预计】的突破",指的是谷底而不是今天 —— 只量今天,会在预测说
    -- 你第 9 周就见底的那一周,报告一个宽裕的缓冲。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'currency', z.currency,
               'monthly_fixed_opex', z.opex,
               'opening', z.open0,
               'projected_min', z.pmin,
               'months_cover_today', CASE WHEN z.opex > 0 THEN round(z.open0 / z.opex, 1) END,
               'months_cover_min',   CASE WHEN z.opex > 0 THEN round(z.pmin  / z.opex, 1) END
           ) ORDER BY z.currency), '[]'::jsonb)
      INTO v_buffer
      FROM (
        SELECT cc.currency,
               COALESCE((SELECT round(sum(
                     CASE l.cadence WHEN 'weekly'    THEN l.amount_ccy * 52.0 / 12.0
                                    WHEN 'monthly'   THEN l.amount_ccy
                                    WHEN 'quarterly' THEN l.amount_ccy / 3.0
                                    WHEN 'annual'    THEN l.amount_ccy / 12.0 END), 2)
                   FROM cash_forecast_lines l
                  WHERE l.is_active AND l.direction = 'out' AND l.cadence <> 'once'
                    AND l.currency = cc.currency), 0) AS opex,
               COALESCE((SELECT round(sum((e->>'amount')::numeric),2) FROM jsonb_array_elements(v_opening) e
                          WHERE e->>'currency' = cc.currency), 0) AS open0,
               COALESCE((SELECT min((e->>'closing')::numeric) FROM jsonb_array_elements(v_buckets) e
                          WHERE e->>'currency' = cc.currency), 0) AS pmin
          FROM unnest(COALESCE(v_ccys, '{}')) AS cc(currency)
      ) z;

    -- ══ 有没有一个【跨币种的合计】可谈 ═════════════════════════════════════
    -- 实测:今天 USD 折不出 SGD。所以这里【逐个币种去问那支函数】,
    -- 问不出来的记下来 —— 屏幕上那一格因此是"一个有名字的缺席",不是 0。
    FOREACH c IN ARRAY COALESCE(v_ccys, '{}') LOOP
        IF c <> v_base THEN
            BEGIN
                v_dummy := fx_rate_for(c, v_asof, 'mid');
            EXCEPTION WHEN OTHERS THEN
                v_missing := v_missing || c;
            END;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'week_start',    v_ws,
        'week_end',      v_end - 1,
        'horizon_weeks', 13,
        'as_of',         v_asof,
        'base_currency', v_base,
        'currencies',    COALESCE(to_jsonb(v_ccys), '[]'::jsonb),
        'opening',       v_opening,
        'lines',         v_lines,
        'buckets',       v_buckets,
        'undated',       v_undated,
        'promises_memo', v_promises,
        'buffer',        v_buffer,
        -- 【能不能给一个跨币种合计】以及【为什么不能】
        'base_total_available',  (array_length(v_missing, 1) IS NULL),
        'base_total_missing_fx', COALESCE(to_jsonb(v_missing), '[]'::jsonb)
    );
END;
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- 7 · freeze_cash_forecast —— 把这一周那一份冻下来
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.freeze_cash_forecast(
    p_week_start       date DEFAULT NULL,
    p_supersede_reason text DEFAULT NULL
)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ws   date;
    v_d    jsonb;
    v_prev cash_forecasts%ROWTYPE;
    v_code text;
    v_id   uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');

    v_ws := COALESCE(p_week_start, date_trunc('week', CURRENT_DATE)::date);
    IF v_ws <> date_trunc('week', v_ws)::date THEN
        RAISE EXCEPTION 'FORECAST_WEEK_START_NOT_MONDAY|%', v_ws::text;
    END IF;

    -- 同一周已经冻过 → 这是【重出】,要理由;旧的那一份【不删】,
    -- 因为 T1 的偏差正是拿它去比的,覆盖掉就把那个度量本身毁了。
    SELECT * INTO v_prev FROM cash_forecasts
     WHERE week_start = v_ws AND superseded_at IS NULL LIMIT 1;
    IF FOUND AND (p_supersede_reason IS NULL OR btrim(p_supersede_reason) = '') THEN
        RAISE EXCEPTION 'FORECAST_SUPERSEDE_REASON_REQUIRED|%|%', v_prev.code, v_ws::text;
    END IF;

    v_d := cash_forecast_data(v_ws);
    v_code := next_forecast_code(v_ws);

    INSERT INTO cash_forecasts (code, week_start, horizon_weeks, opening, buckets, lines,
                                undated, promises_memo, buffer, base_currency, frozen_by)
    VALUES (v_code, v_ws, 13, v_d->'opening', v_d->'buckets', v_d->'lines',
            v_d->'undated', v_d->'promises_memo', v_d->'buffer', v_d->>'base_currency', auth.uid())
    RETURNING id INTO v_id;

    IF v_prev.id IS NOT NULL THEN
        UPDATE cash_forecasts
           SET superseded_at = now(), superseded_by = v_id,
               superseded_reason = btrim(p_supersede_reason)
         WHERE id = v_prev.id;
    END IF;

    RETURN jsonb_build_object('forecast_id', v_id, 'code', v_code, 'week_start', v_ws,
                              'superseded', v_prev.code);
END;
$function$;

COMMENT ON FUNCTION public.freeze_cash_forecast(date, text) IS
    'CASHFLOW-1:把某一周的 13 周预测冻下来。【为什么要冻】KPI T1 量的是「未来 4 周的预测偏差 ±10%」—— 偏差要拿【过去那一份】去比,只在内存里算的预测那个指标无从度量。【它不自己算】走 cash_forecast_data,与页面上那份预览【同一支函数】。【同一周重冻 = 新的一行 + 旧行标 superseded + 必填理由】旧的不删:它正是偏差要比的那个基准。写入口只有这一支(表上没有 INSERT 策略)。';

COMMIT;
