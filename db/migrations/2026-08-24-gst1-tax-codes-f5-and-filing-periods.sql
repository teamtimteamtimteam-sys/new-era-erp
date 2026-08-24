-- GST-1:税码字典、F5 申报表、申报期间
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么现在建,而不是等注册那天】(Tim 裁定,2026-08-24)
-- 规则是法定的、稳定的;F5 的形状是固定的。等到注册那天再建,就是在【最忙的
-- 那一刻】建它 —— 而那正是队列原本把它写成"只勘察"的理由。裁定推翻了那条范围。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【动手前的测量,以及它改变了什么(FIN4-1 第 3 步)】
--
-- ① **两个税科目今天【没有任何写入者】。** 1400 GST Input Tax 与 2100 GST Output
--    Tax 在册、余额为零 —— 但全库【没有一支函数】引用过这两个码(只有
--    master_import_apply 播过科目表)。它们不是"暂时为零",是【无路可达】。
-- ② **发票上的税是一个【只显示、不入账】的数字。** create_invoice 算
--    `tax = round(subtotal × gst_rate_pct / 100, 2)` 并写进 invoices.tax_base,
--    而 create_invoice **一张分录都不过**。也就是说今天把开关打开,发票上会出现
--    一笔【账上根本不存在】的税。这一条是本次测量最要紧的发现。
-- ③ **`finance_settings.gst_rate_pct` 这个形状【不能用】,必须被取代。**
--    它是一个【没有日期的标量】。而税率按法令变(新加坡 7% → 8% → 9%),
--    一张历史单据必须留住【当时】那个税率。一个标量表达不了这件事。
--    **本刀不删它**(还有代码读它),但引擎从此不读它 —— 权威变成 tax_rates。
-- ④ 七张在册发票 tax_rate_pct = 0、tax_base = 0,合计 0.00 —— 迁移不动它们,
--    它们说的是实话:那时公司没有注册。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【税率变更怎么处理 —— 这是 4.1 的核心】
-- 税率不挂在行上,也不挂在设置里,它挂在【税码 + 生效期间】上:
--   tax_rates(tax_code, rate_pct, effective_from, effective_to)
-- 一次法定调整 = 给旧行封口(effective_to)+ 插一行新的。历史单据不受影响,
-- 因为 ① 解析函数按【单据日期】取率,② 单据在成交时把税码与税率【抄在行上】
-- (与 FIN-27 的承诺条款同一条:承诺抄在承诺它的那一行上)。
-- **没有回退。** 某天没有生效的税率就按名拒 —— 与 FX 那条规矩逐字同源:
-- 编一个税率与编一个汇率是同一种谎。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【GST 期间与会计期间锁【不是同一件事】,但也不是无关(6.2)】
-- 会计锁(finance_settings.locked_before)是【按月】的,随月结推进;
-- GST 期间是【按季】的,随申报推进。把两者混同是错的。
-- **但一个"已申报"的 GST 期间,如果它底下的分录还能改,那这份申报就是一句假话。**
-- 所以规矩是一条【前置条件】,不是一次合并:
--     申报一个 GST 期间,要求 locked_before > period_end
--     —— 也就是那一季的每一个月都已经关账。
-- 拒绝有名字:GST_PERIOD_NOT_LOCKED。

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1 · 税码字典
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.tax_codes (
    code             text PRIMARY KEY,
    side             text NOT NULL CHECK (side IN ('output','input')),
    name_en          text NOT NULL,
    name_zh          text NOT NULL,
    description_en   text,
    description_zh   text,
    -- 【F5 的哪一格】这才是税码的意义所在:一个 0% 的行可能是零税率、可能是豁免、
    -- 也可能是不在范围内 —— 三者在 F5 上进【不同的格】。只有税率是分不开它们的。
    f5_supply_box    text,      -- 销项:box1 / box2 / box3(out-of-scope 不入格)
    f5_purchase_box  text,      -- 进项:box5
    f5_tax_box       text,      -- box6(销项税)/ box7(进项税)
    is_claimable     boolean NOT NULL DEFAULT false,   -- 进项:这笔税能不能抵
    is_active        boolean NOT NULL DEFAULT true,
    sort_order       integer NOT NULL DEFAULT 0
);
COMMENT ON TABLE public.tax_codes IS
    'GST-1:税码字典。**税率不在这里** —— 它在 tax_rates 上按生效期间挂着,因为税率按法令变而历史单据必须留住当时那一个。一个税码的意义是它进 F5 的哪一格:0% 的零税率、豁免与不在范围内是三件不同的事,而税率分不开它们。';

ALTER TABLE public.tax_codes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "tax_codes select by permission" ON public.tax_codes
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));

-- 【新加坡的税码,按 IRAS 的分类播下】
INSERT INTO public.tax_codes (code, side, name_en, name_zh, description_en, description_zh,
                              f5_supply_box, f5_purchase_box, f5_tax_box, is_claimable, sort_order) VALUES
    ('SR','output','Standard-rated supply','标准税率销项',
     'A taxable supply made in Singapore at the prevailing rate.','在新加坡作出的应税供应,按现行税率。',
     'box1', NULL, 'box6', false, 10),
    ('ZR','output','Zero-rated supply','零税率销项',
     'Exports and international services. Taxable at 0% — NOT the same as exempt.','出口与国际服务。按 0% 应税 —— 与豁免【不是】一回事。',
     'box2', NULL, NULL, false, 20),
    ('ES','output','Exempt supply','豁免销项',
     'Prescribed exempt supplies. No tax, and input tax attributable to them is generally not claimable.','法定豁免供应。不计税,且归属于它的进项税一般不可抵。',
     'box3', NULL, NULL, false, 30),
    ('OS','output','Out-of-scope supply','不在范围内',
     'Outside the scope of Singapore GST. Reported in no supply box.','不在新加坡 GST 范围内。不进任何一个销项格。',
     NULL, NULL, NULL, false, 40),
    ('TX','input','Standard-rated purchase','标准税率进项',
     'A taxable purchase on which input tax may be claimed.','可抵扣进项税的应税采购。',
     NULL, 'box5', 'box7', true, 50),
    ('ZP','input','Zero-rated purchase','零税率进项',
     'A purchase taxable at 0%.','按 0% 应税的采购。',
     NULL, 'box5', NULL, false, 60),
    ('EP','input','Exempt purchase','豁免进项',
     'A purchase that is an exempt supply in the supplier''s hands.','在供应商那一侧属于豁免供应的采购。',
     NULL, NULL, NULL, false, 70),
    ('BL','input','Blocked input tax','不可抵进项',
     'Expenses on which input tax is blocked by regulation (e.g. private motor cars, club subscriptions, medical). The purchase is reported; the tax is NOT claimed.','法规明令不可抵的开支(如私家车、俱乐部会籍、医疗)。采购要报,税【不抵】。',
     NULL, 'box5', NULL, false, 80),
    ('OP','input','Out-of-scope purchase','不在范围内的采购',
     'Outside the scope of Singapore GST.','不在新加坡 GST 范围内。',
     NULL, NULL, NULL, false, 90)
ON CONFLICT (code) DO NOTHING;

-- ───────────────────────────────────────────────────────────────────────────
-- 2 · 按生效期间挂的税率
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.tax_rates (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tax_code       text NOT NULL REFERENCES public.tax_codes(code),
    rate_pct       numeric(6,3) NOT NULL CHECK (rate_pct >= 0 AND rate_pct <= 100),
    effective_from date NOT NULL,
    effective_to   date,
    note           text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tax_rates_window CHECK (effective_to IS NULL OR effective_to >= effective_from),
    CONSTRAINT tax_rates_one_start UNIQUE (tax_code, effective_from)
);
COMMENT ON TABLE public.tax_rates IS
    'GST-1:税率按【生效期间】挂在税码上。一次法定调整 = 给旧行封口 + 插一行新的;历史单据不受影响。**没有回退** —— 某天没有生效税率就按名拒(TAX_RATE_NOT_FOUND),与 FX 那条「没有牌价就拒绝,绝不假设」逐字同源。';

ALTER TABLE public.tax_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "tax_rates select by permission" ON public.tax_rates
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));

-- 【新加坡法定税率史】播成一条真的历史,而不是"今天是 9%"。
INSERT INTO public.tax_rates (tax_code, rate_pct, effective_from, effective_to, note) VALUES
    ('SR', 7.000, DATE '2007-07-01', DATE '2022-12-31', 'Statutory 7% (2007-07-01 to 2022-12-31)'),
    ('SR', 8.000, DATE '2023-01-01', DATE '2023-12-31', 'Statutory 8% (Budget 2022 step 1)'),
    ('SR', 9.000, DATE '2024-01-01', NULL,              'Statutory 9% (Budget 2022 step 2)'),
    ('TX', 7.000, DATE '2007-07-01', DATE '2022-12-31', 'Input side mirrors the output rate'),
    ('TX', 8.000, DATE '2023-01-01', DATE '2023-12-31', 'Input side mirrors the output rate'),
    ('TX', 9.000, DATE '2024-01-01', NULL,              'Input side mirrors the output rate'),
    ('ZR', 0.000, DATE '2007-07-01', NULL,              'Zero-rated is 0% by definition'),
    ('ZP', 0.000, DATE '2007-07-01', NULL,              'Zero-rated is 0% by definition'),
    ('ES', 0.000, DATE '2007-07-01', NULL,              'Exempt carries no tax'),
    ('EP', 0.000, DATE '2007-07-01', NULL,              'Exempt carries no tax'),
    ('OS', 0.000, DATE '2007-07-01', NULL,              'Out of scope carries no tax'),
    ('OP', 0.000, DATE '2007-07-01', NULL,              'Out of scope carries no tax'),
    ('BL', 9.000, DATE '2024-01-01', NULL,              'Blocked: tax exists but is not claimable')
ON CONFLICT (tax_code, effective_from) DO NOTHING;

-- ───────────────────────────────────────────────────────────────────────────
-- 3 · 税率解析 —— 没有就拒,绝不回退
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tax_rate_for(p_code text, p_date date)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_rate numeric;
BEGIN
    IF p_code IS NULL THEN RAISE EXCEPTION 'TAX_CODE_REQUIRED'; END IF;
    IF p_date IS NULL THEN RAISE EXCEPTION 'TAX_DATE_REQUIRED|%', p_code; END IF;
    IF NOT EXISTS (SELECT 1 FROM tax_codes WHERE code = p_code) THEN
        RAISE EXCEPTION 'TAX_CODE_UNKNOWN|%', p_code;
    END IF;
    SELECT r.rate_pct INTO v_rate FROM tax_rates r
     WHERE r.tax_code = p_code
       AND p_date >= r.effective_from
       AND (r.effective_to IS NULL OR p_date <= r.effective_to);
    IF v_rate IS NULL THEN
        -- 【与 FX 同一条】没有那一天的税率就拒绝,不假设、不取最近的一条。
        RAISE EXCEPTION 'TAX_RATE_NOT_FOUND|%|%', p_code, p_date;
    END IF;
    RETURN v_rate;
END;
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- 4 · 开关 —— 未注册时,行为必须与今天【一模一样】
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.gst_registered()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE((SELECT gst_registered FROM finance_settings LIMIT 1), false);
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- 5 · 两个税科目:引擎从此点名它们,所以它们必须是 is_system
--     (本仓库的规矩:引擎写死的科目码必须 is_system,preflight 就查这一条)
-- ───────────────────────────────────────────────────────────────────────────
UPDATE public.accounts SET is_system = true WHERE code IN ('1400','2100');

-- ───────────────────────────────────────────────────────────────────────────
-- 6 · GST 申报期间
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.gst_periods (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code          text NOT NULL UNIQUE,
    period_start  date NOT NULL,
    period_end    date NOT NULL,
    status        text NOT NULL DEFAULT 'open' CHECK (status IN ('open','filed')),
    filed_at      timestamptz,
    filed_by      uuid,
    filed_on      date,
    filed_reference text,
    notes         text,
    -- 【更正不是编辑】一次更正是【新的一行】,指着被更正的那一期(6.3)
    corrects_period_id uuid REFERENCES public.gst_periods(id),
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid DEFAULT auth.uid(),
    CONSTRAINT gst_periods_window CHECK (period_end >= period_start),
    -- 已申报的期间必须带齐申报留痕;未申报的必须一个都没有
    CONSTRAINT gst_periods_filed_shape CHECK (
        (status = 'open'  AND filed_at IS NULL AND filed_on IS NULL AND filed_reference IS NULL)
     OR (status = 'filed' AND filed_at IS NOT NULL AND filed_on IS NOT NULL))
);
COMMENT ON TABLE public.gst_periods IS
    'GST-1:GST 申报期间(季度)。与会计期间锁【不是同一件事】—— 会计锁按月、随月结推进,GST 期间按季、随申报推进。但一个"已申报"而底下分录还能改的期间是一句假话,所以申报的前置条件是 locked_before > period_end(那一季每个月都已关账)。更正【不是编辑】:它是新的一行,corrects_period_id 指着被更正的那一期。';

ALTER TABLE public.gst_periods ENABLE ROW LEVEL SECURITY;
CREATE POLICY "gst_periods select by permission" ON public.gst_periods
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));

-- 【已申报的那一份是【当时报出去的东西】,不随底下的数据变】(6.3)
CREATE TABLE IF NOT EXISTS public.gst_return_boxes (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    period_id   uuid NOT NULL REFERENCES public.gst_periods(id),
    box         text NOT NULL,
    label_en    text NOT NULL,
    label_zh    text NOT NULL,
    value_base  numeric(18,2) NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT gst_return_boxes_one_per_period UNIQUE (period_id, box)
);
COMMENT ON TABLE public.gst_return_boxes IS
    'GST-1:**报出去的那一份的快照。** 申报那一刻把每一格的数字抄下来,此后底下的数据再动,这一份也不动 —— 与已签发单据同一条规矩。想知道"现在算出来是多少",调 f5_return();想知道"当时报了多少",读这张表。两者不一致本身就是一条要人看的信息。';

ALTER TABLE public.gst_return_boxes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "gst_return_boxes select by permission" ON public.gst_return_boxes
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));

-- 只增不改:一份报出去的申报不许被改写
CREATE OR REPLACE FUNCTION public.guard_gst_return_boxes_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'GST_RETURN_IMMUTABLE|%', COALESCE(OLD.box, NEW.box);
END;
$function$;

DROP TRIGGER IF EXISTS trg_gst_return_boxes_immutable ON public.gst_return_boxes;
CREATE TRIGGER trg_gst_return_boxes_immutable
    BEFORE UPDATE OR DELETE ON public.gst_return_boxes
    FOR EACH ROW EXECUTE FUNCTION public.guard_gst_return_boxes_immutable();

-- ───────────────────────────────────────────────────────────────────────────
-- 7 · 税码落在【分录行】上 —— 这是"从总账推导"与"能钻进去"两件事的同一个前提
--
-- 【为什么是分录行,不是单据】F5 要的是"标准税率供应的总额",而那个额必须
-- 与总账对得上;把它建在单据上,就等于建了第二套账,而两套账迟早分家
-- (本仓库对"一个事实两处陈述"付过账)。税码落在分录行上之后:
--   · 每一格【从总账推导】(5.1);
--   · 从一格能走回 journal_entries → source_type/source_id → 那张单据(5.2);
--   · 税额可以用两条【互相独立】的路各算一遍,于是勾稽是真的会动的(5.3)。
-- ───────────────────────────────────────────────────────────────────────────
ALTER TABLE public.journal_lines
    ADD COLUMN IF NOT EXISTS tax_code text REFERENCES public.tax_codes(code);
COMMENT ON COLUMN public.journal_lines.tax_code IS
    'GST-1:这一行在 GST 上算什么。**大多数行为 NULL,那是对的** —— 只有供应额/采购额那几行带码。税额本身不带码,它由科目(2100 销项 / 1400 进项)认出来。F5 的每一格据此从总账推导,并据此能钻回原始单据。';

-- 遮蔽表加列的三件事(AGENTS.md):journal_lines 没有 _masked 伴生视图,
-- 也没有列清单授权(GL 不做列级遮蔽,那是一条【已裁定接受】的边界),
-- 所以这里只有 ADD COLUMN 一件。写下来是为了让读的人知道那三条被想过。

-- ───────────────────────────────────────────────────────────────────────────
-- 8 · F5 —— 按 IRAS 自己的格号与措辞
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.f5_return(p_period_start date, p_period_end date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_box1 numeric := 0; v_box2 numeric := 0; v_box3 numeric := 0;
    v_box5 numeric := 0; v_box6 numeric := 0; v_box7 numeric := 0;
    v_box13 numeric := 0;
    v_box6_recomputed numeric := 0;
    v_base text;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_start IS NULL OR p_period_end IS NULL THEN
        RAISE EXCEPTION 'GST_PERIOD_DATES_REQUIRED';
    END IF;
    IF p_period_end < p_period_start THEN
        RAISE EXCEPTION 'GST_PERIOD_WINDOW_INVALID|%|%', p_period_start, p_period_end;
    END IF;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 【供应额】按税码分格。销项是贷方净额(收入在贷方),所以取 credit - debit。
    SELECT
      COALESCE(SUM(jl.credit - jl.debit) FILTER (WHERE jl.tax_code = 'SR'), 0),
      COALESCE(SUM(jl.credit - jl.debit) FILTER (WHERE jl.tax_code = 'ZR'), 0),
      COALESCE(SUM(jl.credit - jl.debit) FILTER (WHERE jl.tax_code = 'ES'), 0)
      INTO v_box1, v_box2, v_box3
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
     WHERE je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted';

    -- 【采购额】进项侧是借方净额。BL(不可抵)【也要报采购额】,只是税不抵 ——
    -- 那正是税码存在的理由:税率分不开"可抵"与"不可抵"。
    SELECT COALESCE(SUM(jl.debit - jl.credit) FILTER (WHERE jl.tax_code IN ('TX','ZP','BL')), 0)
      INTO v_box5
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
     WHERE je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted';

    -- 【税额】从税科目本身取 —— 这是第一条路。
    SELECT COALESCE(SUM(jl.credit - jl.debit), 0) INTO v_box6
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
      JOIN accounts a ON a.id = jl.account_id
     WHERE a.code = '2100' AND je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted';
    SELECT COALESCE(SUM(jl.debit - jl.credit), 0) INTO v_box7
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
      JOIN accounts a ON a.id = jl.account_id
     WHERE a.code = '1400' AND je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted';

    -- 【第二条路,与上面那条【互相独立】】从供应额 × 当期法定税率重算销项税。
    -- 一条读【税科目】,一条读【供应额与法令】。过账算错了税,两者就会分开 ——
    -- 这正是 OPS-17 那条"两边必须能分开才算勾稽"的要求。
    SELECT COALESCE(SUM(round((jl.credit - jl.debit) * tax_rate_for(jl.tax_code, je.entry_date) / 100.0, 2)), 0)
      INTO v_box6_recomputed
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
     WHERE je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted' AND jl.tax_code = 'SR';

    -- 【Box 13 收入】总收入,从收入类科目取。
    SELECT COALESCE(SUM(jl.credit - jl.debit), 0) INTO v_box13
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
      JOIN accounts a ON a.id = jl.account_id
     WHERE a.account_type = 'revenue' AND je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted';

    RETURN jsonb_build_object(
      'period_start', p_period_start, 'period_end', p_period_end, 'currency', v_base,
      'boxes', jsonb_build_array(
        jsonb_build_object('box','box1','label_en','Total value of standard-rated supplies','label_zh','标准税率供应总额','value', round(v_box1,2),'derived',true),
        jsonb_build_object('box','box2','label_en','Total value of zero-rated supplies','label_zh','零税率供应总额','value', round(v_box2,2),'derived',true),
        jsonb_build_object('box','box3','label_en','Total value of exempt supplies','label_zh','豁免供应总额','value', round(v_box3,2),'derived',true),
        jsonb_build_object('box','box4','label_en','Total value of (1) + (2) + (3)','label_zh','(1)+(2)+(3) 合计','value', round(v_box1+v_box2+v_box3,2),'derived',true),
        jsonb_build_object('box','box5','label_en','Total value of taxable purchases','label_zh','应税采购总额','value', round(v_box5,2),'derived',true),
        jsonb_build_object('box','box6','label_en','Output tax due','label_zh','应缴销项税','value', round(v_box6,2),'derived',true),
        jsonb_build_object('box','box7','label_en','Input tax and refunds claimed','label_zh','已抵进项税与退税','value', round(v_box7,2),'derived',true),
        jsonb_build_object('box','box8','label_en','Net GST to be paid to / claimed from IRAS','label_zh','应缴/应退 GST 净额','value', round(v_box6 - v_box7,2),'derived',true),
        -- 【Box 9 结构性为零,而这不是"算出来是零"】我们不在 MES / A3PL 之类的
        -- 计划里。说"没有参加"与说"算出来是零"不是一回事,所以它标 derived=false。
        jsonb_build_object('box','box9','label_en','Total value of goods imported under approved schemes','label_zh','按核准计划进口的货物总额','value', 0,'derived',false,
                           'note_en','Structurally zero: this company is not on MES or any approved import scheme.','note_zh','结构性为零:本公司不在 MES 或任何核准进口计划内。'),
        jsonb_build_object('box','box13','label_en','Revenue','label_zh','营业收入','value', round(v_box13,2),'derived',true)
      ),
      -- 【勾稽:两条独立的路】
      'ties', jsonb_build_object(
        'box6_from_tax_account', round(v_box6,2),
        'box6_recomputed_from_supplies', round(v_box6_recomputed,2),
        'agrees', round(v_box6,2) = round(v_box6_recomputed,2),
        'how_en','Box 6 is read from account 2100. It is independently recomputed as standard-rated supply value times the statutory rate for each entry''s own date. A posting error moves one and not the other.',
        'how_zh','Box 6 从 2100 科目读出;另一条路用标准税率供应额乘以每张分录【自己那一天】的法定税率重算。过账算错税,两者就会分开。'
      ),
      -- 【本次未接线的单据族,照直说出来】
      'coverage', jsonb_build_object(
        'wired_en','Journal lines carrying a tax_code. Documents post through post_journal_entry, so any document family whose posting stamps a tax code is included automatically.',
        'wired_zh','带 tax_code 的分录行。单据都经 post_journal_entry 过账,所以任何在过账时盖上税码的单据族都自动被纳入。'
      ));
END;
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- 9 · 一格【钻得进去】—— 从一个数字走回构成它的那些单据(5.2)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.f5_box_detail(p_period_start date, p_period_end date, p_box text)
RETURNS TABLE (
    entry_id uuid, entry_code text, entry_date date, memo text,
    source_type text, source_id uuid, tax_code text, amount_base numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_box IS NULL THEN RAISE EXCEPTION 'GST_BOX_REQUIRED'; END IF;
    IF p_box NOT IN ('box1','box2','box3','box5','box6','box7') THEN
        -- 【合计格与结构性零格【钻不进去】,而这要说出来,不能返回空集】
        -- box4 与 box8 是别的格加出来的,box9 是"我们不参加",box13 是收入总额。
        RAISE EXCEPTION 'GST_BOX_NOT_DRILLABLE|%', p_box;
    END IF;
    RETURN QUERY
    SELECT je.id, je.code, je.entry_date, je.memo, je.source_type, je.source_id,
           jl.tax_code,
           CASE
             WHEN p_box IN ('box1','box2','box3') THEN round(jl.credit - jl.debit, 2)
             WHEN p_box = 'box5' THEN round(jl.debit - jl.credit, 2)
             WHEN p_box = 'box6' THEN round(jl.credit - jl.debit, 2)
             ELSE round(jl.debit - jl.credit, 2)
           END
      FROM journal_lines jl
      JOIN journal_entries je ON je.id = jl.entry_id
      LEFT JOIN accounts a ON a.id = jl.account_id
     WHERE je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted'
       AND (
            (p_box = 'box1' AND jl.tax_code = 'SR')
         OR (p_box = 'box2' AND jl.tax_code = 'ZR')
         OR (p_box = 'box3' AND jl.tax_code = 'ES')
         OR (p_box = 'box5' AND jl.tax_code IN ('TX','ZP','BL'))
         OR (p_box = 'box6' AND a.code = '2100')
         OR (p_box = 'box7' AND a.code = '1400')
       )
     ORDER BY je.entry_date, je.code;
END;
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- 10 · 开期间 / 申报
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.open_gst_period(p_period_start date, p_period_end date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_code text; v_id uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_period_start IS NULL OR p_period_end IS NULL THEN
        RAISE EXCEPTION 'GST_PERIOD_DATES_REQUIRED';
    END IF;
    -- 【季度的形状】新加坡的标准申报周期是一个季;要按月/按半年是另一回事,
    -- 到时候由 IRAS 的批准决定,不由这里猜。
    IF p_period_start <> date_trunc('quarter', p_period_start)::date
       OR p_period_end <> (date_trunc('quarter', p_period_start) + interval '3 months - 1 day')::date THEN
        RAISE EXCEPTION 'GST_PERIOD_NOT_A_QUARTER|%|%', p_period_start, p_period_end;
    END IF;
    IF EXISTS (SELECT 1 FROM gst_periods WHERE period_start = p_period_start AND corrects_period_id IS NULL) THEN
        RAISE EXCEPTION 'GST_PERIOD_EXISTS|%', p_period_start;
    END IF;
    v_code := 'GST-' || to_char(p_period_start,'YYYY') || '-Q'
              || EXTRACT(quarter FROM p_period_start)::text;
    INSERT INTO gst_periods (code, period_start, period_end, status)
    VALUES (v_code, p_period_start, p_period_end, 'open') RETURNING id INTO v_id;
    RETURN jsonb_build_object('gst_period_id', v_id, 'code', v_code,
                              'period_start', p_period_start, 'period_end', p_period_end);
END;
$function$;

CREATE OR REPLACE FUNCTION public.file_gst_return(p_period_id uuid, p_filed_on date, p_reference text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p gst_periods%ROWTYPE;
    v_locked date;
    v_return jsonb;
    v_box jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_p FROM gst_periods WHERE id = p_period_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'GST_PERIOD_NOT_FOUND|%', p_period_id; END IF;
    IF v_p.status <> 'open' THEN
        RAISE EXCEPTION 'GST_PERIOD_ALREADY_FILED|%|%', v_p.code, v_p.filed_on;
    END IF;
    IF p_filed_on IS NULL THEN RAISE EXCEPTION 'GST_FILED_DATE_REQUIRED|%', v_p.code; END IF;

    -- ★【GST 期间与会计锁的关系,就是这一句】★
    -- 两者不是同一件事,但一份"已申报"而底下分录还能改的申报是一句假话。
    -- 所以申报要求那一季的每一个月都已经关账。
    SELECT locked_before INTO v_locked FROM finance_settings LIMIT 1;
    IF v_locked IS NULL OR v_locked <= v_p.period_end THEN
        RAISE EXCEPTION 'GST_PERIOD_NOT_LOCKED|%|%|%',
            v_p.code, v_p.period_end, COALESCE(v_locked::text,'(未设)');
    END IF;

    -- 【把当时算出来的每一格抄下来】此后底下的数据再动,这一份也不动。
    v_return := f5_return(v_p.period_start, v_p.period_end);
    FOR v_box IN SELECT * FROM jsonb_array_elements(v_return->'boxes') LOOP
        INSERT INTO gst_return_boxes (period_id, box, label_en, label_zh, value_base)
        VALUES (p_period_id, v_box->>'box', v_box->>'label_en', v_box->>'label_zh',
                (v_box->>'value')::numeric);
    END LOOP;

    UPDATE gst_periods
       SET status='filed', filed_at=now(), filed_by=auth.uid(),
           filed_on=p_filed_on, filed_reference=p_reference
     WHERE id = p_period_id;

    RETURN jsonb_build_object('gst_period_id', p_period_id, 'code', v_p.code,
                              'filed_on', p_filed_on, 'reference', p_reference,
                              'boxes', v_return->'boxes');
END;
$function$;

-- 【更正是一个新事件,不是一次编辑】(6.3)
CREATE OR REPLACE FUNCTION public.correct_gst_return(p_original_period_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_o gst_periods%ROWTYPE; v_id uuid; v_code text; v_n int;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'GST_CORRECTION_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_o FROM gst_periods WHERE id = p_original_period_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'GST_PERIOD_NOT_FOUND|%', p_original_period_id; END IF;
    IF v_o.status <> 'filed' THEN
        RAISE EXCEPTION 'GST_CANNOT_CORRECT_UNFILED|%', v_o.code;
    END IF;
    SELECT count(*) INTO v_n FROM gst_periods WHERE corrects_period_id = p_original_period_id;
    v_code := v_o.code || '-F7-' || (v_n + 1)::text;
    INSERT INTO gst_periods (code, period_start, period_end, status, notes, corrects_period_id)
    VALUES (v_code, v_o.period_start, v_o.period_end, 'open', p_reason, p_original_period_id)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('gst_period_id', v_id, 'code', v_code,
                              'corrects', v_o.code, 'reason', p_reason);
END;
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- 11 · 让【唯一那个写入者】把税码带下去
--
-- 【为什么接在这里,而不是接在每一个单据上】fixture 122 已经钉死了一件事:
-- 32 个写日记账的函数里,**只有 post_journal_entry 真的 INSERT journal_lines**,
-- 另外 31 个都调它。所以把税码接在这一支上,等于让【每一个单据族】
-- 只要在自己的行上多传一个 tax_code 就自动被 F5 纳入 —— 而不是十三个族各接一遍。
--
-- 【它同时把 4.3 那条"开关关着 = 与今天一模一样"变成一条写不进去的规矩】
-- 未注册时传税码直接按名拒(GST_NOT_REGISTERED),于是"没有任何一行带税码"
-- 不再是一句需要断言的话,而是一件做不到的事。
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.post_journal_entry(p_entry_date date, p_memo text, p_source_type text, p_source_id uuid, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
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
    v_tax_code     text;
BEGIN
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    IF p_entry_date IS NULL THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 过账许可:年结闸与期间锁 —— ASY-1 起【搬进 assert_posting_allowed】,
    -- 与只读试算共用一份,预览因此不会放行一笔提交会拒的分录。闸的文字、次序、
    -- close_ctx 例外原样搬走,这里只剩调用。
    PERFORM assert_posting_allowed(p_entry_date, p_source_type);

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
        -- GST-1:这一行在 GST 上算什么。**绝大多数行没有税码,那是对的。**
        v_tax_code := NULLIF(v_line->>'tax_code', '');
        IF v_tax_code IS NOT NULL THEN
            -- 【没注册就不许盖税码】这一句把"开关关着 = 与今天一模一样"从一句
            -- 断言变成一条【写不进去】的规矩:未注册时根本产生不了带税码的行。
            IF NOT gst_registered() THEN
                RAISE EXCEPTION 'GST_NOT_REGISTERED|%', v_tax_code;
            END IF;
            IF NOT EXISTS (SELECT 1 FROM tax_codes WHERE code = v_tax_code AND is_active) THEN
                RAISE EXCEPTION 'TAX_CODE_UNKNOWN|%', v_tax_code;
            END IF;
            -- 【解析一次税率,只为了让"那一天没有税率"当场被拒】
            -- 不存下来:税额本身由分录行自己表达,存第二份就是两处陈述同一件事。
            PERFORM tax_rate_for(v_tax_code, p_entry_date);
        END IF;
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

        INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate, fx_rate_date, line_memo, tax_code)
        VALUES (
            v_entry_id,
            v_account.id,
            CASE WHEN v_side = 'debit'  THEN v_usd ELSE 0 END,
            CASE WHEN v_side = 'credit' THEN v_usd ELSE 0 END,
            v_currency,
            v_amount,
            v_fx,
            v_fx_date,
            v_line->>'line_memo',
            v_tax_code
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

COMMIT;
