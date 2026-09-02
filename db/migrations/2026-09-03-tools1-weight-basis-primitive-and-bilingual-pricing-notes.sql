-- TOOLS-1(2026-09-03)· 一支迁移,两件事,一次备份
--
-- ④ 把【湿基/干基换算】从 sale_settlement_compute 里【提出来】成两支基元函数,
--    结算与新的单位换算器【都调用它】—— 一份实现,两个调用方(reprice_split 那个先例)。
-- ⑤a pricing_settings.notes 拆成 notes_en / notes_zh —— 那句中文正在英文界面上渲染,
--    而它住在【数据】里,不是代码里。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【④ 为什么是提取,不是"再写一遍"】
-- 那段算术今天【只存在于 sale_settlement_compute 里】,而那支函数同时还在计价、
-- 套用应付系数、扣精炼费。换算器要用它,只有三条路:
--   (a) 提成一支小函数,两边都调 —— 本迁移做的;
--   (b) 在 TypeScript 里照抄一遍 —— **AGENTS.md 明令禁止**(预览规则:四次事故);
--   (c) 换算器不做湿转干 —— 那就丢掉了这个工具最有价值的一格。
--
-- ★★【本迁移【不改变】结算的任何输出 —— 这是一次纯粹的搬家】★★
-- 两支基元的表达式与原处【逐字符相同】,连 round 的位数、COALESCE 的位置、
-- 除零会抛(而不是被 COALESCE 掩盖)都保持原样:
--   · 重量:目标是 as_received → 原值不动(**不 round**);目标是 dry → round(w*(1-m/100), 4)
--   · 含量:同基准 → 原值不动;dry→as_received 乘 (1-m/100);否则除 (1-m/100)
-- 【为什么连"除零会抛"都要留着】把它换成一句具名拒绝【会改变失败模式】,
-- 而本刀的承诺是"输出不变"。水分=100% 的守卫加在【换算器那一侧】
-- (app/tools/converter),不加在基元里 —— 结算路径一个字节都不该因为
-- 一个新页面而改变行为。
--
-- 【SECURITY / 权限】两支都是 IMMUTABLE 的纯算术,不读任何表,所以:
--   · 不需要 SECURITY DEFINER(没有表可读,也就没有 RLS 要绕);
--   · zzz_function_grants.sql 会在本迁移的同一笔事务里重放,把 PUBLIC 的
--     EXECUTE 收掉(apply_migration.sh 的 OPS-7 机制),不必在这里手写 REVOKE。
--
-- 【⑤a 为什么给列配对,而不是搬进文案文件】
-- 那句话住在数据里【是有理由的】:它是运营者可以自己改的一句注解
-- (「50% 是默认值,不是决定」)。搬进 messages/*.ts 会把它变成只有开发者能改的东西。
-- 配 _en/_zh 与 leave_types / tax_codes / battery_chemistries / public_holidays
-- 逐字同形 —— 这是本仓库既有的做法,不是一个新发明。
--
-- 【pricing_settings 不是遮蔽表】(实测:lib/database.types.ts 里没有
-- pricing_settings_masked)——所以本迁移没有列授权与 _masked 视图要改。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── ④-1 重量基准换算 ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.convert_weight_basis(
    p_weight       numeric,
    p_from_basis   text,
    p_to_basis     text,
    p_moisture_pct numeric
) RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $fn$
    -- 【与 sale_settlement_compute 原处逐字相同】
    --   目标是 as_received:原值不动(原式是 CASE 的 THEN 分支,不 round)
    --   目标是 dry        :round(w * (1 - COALESCE(m,0)/100.0), 4)
    -- COALESCE 留在原处:结算那一侧在基准相同时允许 moisture 为 NULL,
    -- 而基准不同时上游已经按名拒过(SETTLEMENT_MOISTURE_NOT_STATED)。
    SELECT CASE
        WHEN p_to_basis = p_from_basis THEN p_weight
        WHEN p_to_basis = 'as_received'
            THEN round(p_weight / (1 - p_moisture_pct / 100.0), 4)
        ELSE round(p_weight * (1 - COALESCE(p_moisture_pct, 0) / 100.0), 4)
    END
$fn$;

COMMENT ON FUNCTION public.convert_weight_basis(numeric, text, text, numeric) IS
'湿基/干基之间换算一个重量。TOOLS-1 从 sale_settlement_compute 提取,表达式逐字未改。
两个调用方:结算(db/functions/sale_settlement_compute.sql)与单位换算器(app/tools/converter)。
【水分 = 100% 会抛除零,这是刻意保留的原行为】—— 守卫加在换算器那一侧,不加在这里,
因为结算路径不该因为一个新页面而改变失败模式。';

-- ── ④-2 品位(含量%)基准换算 ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.convert_grade_basis(
    p_content_pct  numeric,
    p_from_basis   text,
    p_to_basis     text,
    p_moisture_pct numeric
) RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $fn$
    -- 【与 sale_settlement_compute 原处逐字相同】
    --   同基准        → 原值不动
    --   dry → as_received → content * (1 - m/100)
    --   否则(as_received → dry) → content / (1 - m/100)
    -- 【这里没有 COALESCE,原处也没有】:基准不同而 moisture 为 NULL 时,
    -- 结果是 NULL —— 而上游已经按名拒过那种输入。原样保留。
    SELECT CASE
        WHEN p_from_basis = p_to_basis THEN p_content_pct
        WHEN p_from_basis = 'dry' AND p_to_basis = 'as_received'
            THEN p_content_pct * (1 - p_moisture_pct / 100.0)
        ELSE p_content_pct / (1 - p_moisture_pct / 100.0)
    END
$fn$;

COMMENT ON FUNCTION public.convert_grade_basis(numeric, text, text, numeric) IS
'湿基/干基之间换算一个含量百分比。TOOLS-1 从 sale_settlement_compute 提取,表达式逐字未改。
含金属量是不变量:重量与含量必须换到【同一个基准】上,两者相乘才守恒。';

-- ── ⑤a pricing_settings.notes → notes_en / notes_zh ────────────────────────
-- 【新列排在末尾】—— 与本表既有的 ALTER 加列(default_metal_index、
-- metal_quote_stale_days)同一条规矩,attnum 顺序与镜像一致。
ALTER TABLE public.pricing_settings ADD COLUMN notes_en text;
ALTER TABLE public.pricing_settings ADD COLUMN notes_zh text;

-- 【中文原样搬过去,英文按它的意思写】—— 不是机翻,是把它说的三件事说全:
--   ① 50% 是默认值,不是一次裁定;② 线上真实相邻变动 ≤6.25%;
--   ③ 2026-07-30 那次异常是 +233% / −75%;④ 改它不需要改代码。
UPDATE public.pricing_settings SET
    notes_zh = notes,
    notes_en = 'A default, not a ruling: real adjacent moves on this system are ' ||
               '6.25% or less, while the 2026-07-30 anomaly was +233% / -75%. ' ||
               'Changing this line does not need a code change.'
WHERE id;

-- 【旧列留着,不删】—— 删它要同时改镜像、类型、读它的页面,而那属于另一次改动。
-- 它从此不再被任何界面读;下一刀确认无读者之后再删。记在 docs/forward-queue.md。
COMMENT ON COLUMN public.pricing_settings.notes IS
'【已由 notes_en / notes_zh 取代(TOOLS-1,2026-09-03)】界面不再读它。
留着是为了不在同一刀里既改结构又改读者;确认无读者后由一次单独的迁移删除。';
COMMENT ON COLUMN public.pricing_settings.notes_en IS '阈值说明(英文)。运营者可改 —— 它是数据,不是文案文件里的键。';
COMMENT ON COLUMN public.pricing_settings.notes_zh IS '阈值说明(中文)。与 notes_en 成对,界面按 locale 选一句。';

-- ── ④-3 结算改调那两支基元 ────────────────────────────────────────────────
-- 【这才是"一份实现,两个调用方"真正落地的地方】只提取不接线,就成了三份实现。
-- 函数体其余部分【一个字节没动】—— 本迁移之后 `pg_get_functiondef` 与提取前
-- 只差这两行,而 db/fixtures/187 会在真实结算行上断言输出不变。
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

COMMIT;
