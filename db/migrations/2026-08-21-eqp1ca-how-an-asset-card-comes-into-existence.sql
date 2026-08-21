-- EQP-1c-a:一张资产卡怎么诞生 —— 把设备链的【起点】补上
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【问题】设备链今天【起不了步】。EQP-1a 立的规矩是"采购单行引用一张已存在的
-- 资产卡,行不创建资产";而资产卡此前【只有一扇门】—— record_expense 的
-- 新建模式,它同时要过一笔账。于是顺序被要求成"先有发票、再有订单",
-- 而现实是【订单在前、发票在后】。这是 EQP-1a 留下的设计缺口,本刀补它。
-- ════════════════════════════════════════════════════════════════════════════
--
-- ── STEP 1 的接地把设计改了四处,逐条记在这里 ────────────────────────────────
--
-- 【一】拦住"无成本的卡"的【不是】一条 CHECK,是【四条】规则,而最硬的那条
--       根本不是 CHECK:`fixed_assets.expense_id` 是 **NOT NULL**。
--       也就是说"一台资产必须由一笔支出生出来"这句话是【写在列上】的 ——
--       而那正是本刀要推翻的那条规矩。所以本刀 DROP 掉那个 NOT NULL。
--       它此前保证的是"每一台资产都追得到一笔过账";那条保证【被刻意退役】。
--       退役之后仍然成立、而且更有用的是另一句:**一台资产的【成本】永远等于
--       它未冲销成本明细之和** —— 由 fixture 77B 与 reverse_expense 内的
--       ASSET_COST_LEDGER_DIVERGED 两处守着。
--
-- 【二】三条 CHECK 要动,而 D2 只说了一条:
--         fixed_assets_cost_base_check    CHECK (cost_base > 0)      → >= 0
--         fixed_assets_cost_ccy_check     CHECK (cost_ccy  > 0)      → >= 0
--         fixed_assets_residual_below_cost CHECK (residual_base < cost_base)
--       第三条在 cost_base = 0 时【无解】:另一条 CHECK 要求 residual_base >= 0,
--       两者合起来要求 0 <= residual < 0。所以它必须改成带例外的形式,
--       而不是简单放宽。改完之后它仍然保证:
--         * 只要成本 > 0,残值就【严格小于】成本(原样);
--         * 成本为 0 的卡,残值【必须也是 0】—— 不许趁成本还是 0 时偷偷塞进
--           一个残值,等成本落下来时变成"残值高于成本"。
--       `fx_rate > 0` 【不动】:无成本的卡记 fx_rate = 1、币种 = 本位币,
--       那不是占位符,是实话 —— 它没有发生过任何换算。
--
-- 【三】D3 那条规矩必须【同时给处置**】,否则本刀会造出一条【裸的约束违例】:
--       dispose_fixed_asset 无条件地按 cost_base 贷一条 1500 分录行,而
--       journal_lines_amount_ccy_check 是 CHECK (amount_ccy > 0)。
--       于是"处置一张零成本卡"= 23514,而不是一句人话。
--       这是本刀【自己造出来的】那条路,所以本刀关掉它 —— 与 D3 给
--       set_asset_in_service 加的那道守卫【同一个形状、同一个码】。
--       它没有触发 brief 的停机条件:处置的【算术】一个字没改,加的是一道具名拒绝。
--
-- 【四】两扇门【不许各自取号】。FA-YYYY-NNNN 是无缝编号,靠
--       pg_advisory_xact_lock 串行化"取当年最大号 + 1"。两扇门抄两份同样的逻辑,
--       今天一致、明天就未必 —— 而本仓库为"一条规则两个实现"付过很多次账。
--       所以取号提成 next_fixed_asset_code(date),两扇门都调它(先例:
--       next_shipment_code / next_container_code / next_quote_code,
--       它们同样在 zzz_function_grants.sql 里对 authenticated 收权)。
--       record_expense 因此也在本支迁移里替换一次,【只把那四行换成一次调用,
--       行为逐字不变】。
--
-- ── 被否决的那条路,以及【接地给出的新理由】────────────────────────────────
-- brief 记了"让 create_purchase_order 替设备行建卡"这条被否的路,理由是它把
-- 主数据的创建耦合到一笔交易上。接地给出一条更硬的理由:**它根本躲不开
-- 零成本卡这个问题。** 采购单不是过账,所以由它建出来的卡同样没有任何
-- 总账支撑的成本 —— 要么 cost_base = 0(那就得做【一模一样】的三条放宽,
-- 什么也没省下),要么把行上的【估价】写进 cost_base,而那是一个总账从未见过的
-- 数字,却会去驱动 NBV、折旧、以及处置时那条 1500 贷方。后者严格更糟。
-- **所以否决成立,而且理由比原先更强;没有触发"若它更便宜就停下来报告"。**
--
-- ── 遮蔽检查(brief 要求逐次报告)────────────────────────────────────────────
-- 本刀碰的表只有 fixed_assets:relacl 里 authenticated 与 anon 都持【表级】
-- SELECT,attacl 全为 NULL,没有 fixed_assets_masked —— **不是遮蔽表**,
-- 因此没有列级 GRANT、也没有 _masked 视图要跟着改。
-- (顺带:它只有一条 SELECT 策略,没有 INSERT/UPDATE/DELETE 策略 ——
--  authenticated 写不进去,写入只能经 DEFINER 函数,本刀不改这一点。)
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-21-eqp1ca-how-an-asset-card-comes-into-existence.sql

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1 · 让一张【没有成本、也没有出生凭证】的卡成为可能
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.fixed_assets ALTER COLUMN expense_id DROP NOT NULL;

COMMENT ON COLUMN public.fixed_assets.expense_id IS
'生出这张卡的那一笔支出(record_expense 的新建模式)。**可空 —— EQP-1c-a 起。**
【为什么可空】这一列此前是 NOT NULL,它把"一台资产必须由一笔过账生出来"写死在了
列上。而设备的现实顺序是【先下单、后开票】:采购单行要引用一张【已经存在】的
资产卡(EQP-1a),那张卡在发票到来之前就必须存在,那时它还没有任何成本。
create_fixed_asset 建出来的卡因此 expense_id 为 NULL —— 它不是缺数据,
是【这张卡不是由一笔支出生出来的】。
【那条 NOT NULL 此前保证什么、现在还剩什么】它保证"每台资产都追得到一笔过账"。
那条保证被刻意退役了。仍然成立、而且更有用的是另一句:**一台资产的【成本】
永远等于它未冲销成本明细之和**(fixed_asset_cost_entries JOIN expenses,
status = ''posted'')—— fixture 77B 与 reverse_expense 里的
ASSET_COST_LEDGER_DIVERGED 各守一头。成本的可追溯性没有变松,变松的只是
"卡本身从哪来"。
【读它的人要当心】它现在可能是 NULL。/finance/assets 把资产编号做成指向这笔
支出的链接,本刀因此改成:没有出生凭证的卡不画链接。';

-- ════════════════════════════════════════════════════════════════════════════
-- 2 · 三条 CHECK:放宽到【恰好够用】,并说清放宽之后还保证什么
-- ════════════════════════════════════════════════════════════════════════════
-- 成本:> 0 → >= 0。仍然禁止【负】成本 —— 那才是这条 CHECK 真正在拦的东西。
ALTER TABLE public.fixed_assets DROP CONSTRAINT fixed_assets_cost_base_check;
ALTER TABLE public.fixed_assets ADD CONSTRAINT fixed_assets_cost_base_check
    CHECK (cost_base >= 0);

-- 原币成本同上。零成本卡记 cost_ccy = 0 / currency = 本位币 / fx_rate = 1。
ALTER TABLE public.fixed_assets DROP CONSTRAINT fixed_assets_cost_ccy_check;
ALTER TABLE public.fixed_assets ADD CONSTRAINT fixed_assets_cost_ccy_check
    CHECK (cost_ccy >= 0);

-- 残值:带例外,不是放宽。
-- 【为什么不能只写 residual_base <= cost_base】那会让"残值 = 成本"在成本 > 0 时
-- 也变成合法,而它意味着这台机器【永远提不出折旧】—— 原本被拦住的东西不该
-- 因为一个无关的新用例被放进来。放宽只放到这一个用例真正需要的宽度。
ALTER TABLE public.fixed_assets DROP CONSTRAINT fixed_assets_residual_below_cost;
ALTER TABLE public.fixed_assets ADD CONSTRAINT fixed_assets_residual_below_cost
    CHECK (residual_base < cost_base OR (cost_base = 0 AND residual_base = 0));

COMMENT ON CONSTRAINT fixed_assets_residual_below_cost ON public.fixed_assets IS
'EQP-1c-a:两句话,不是一句。
  * 成本 > 0 时,残值【严格小于】成本 —— 与本刀之前逐字相同(残值 = 成本
    意味着永远提不出折旧,那不是一台在用的机器);
  * 成本 = 0 时(create_fixed_asset 建出来、还没挂上成本的卡),残值【必须也是 0】。
【第二句为什么不能省】它拦的是"趁成本还是 0 的时候先塞一个残值进去,
等成本落下来时它已经高过成本了"。residual_base 全库只有 record_expense 的
新建支写过一次,而那一支会校验 residual < 建卡金额;create_fixed_asset 恒写 0。
两扇门合起来,残值高于成本这件事在任何时刻都不可能出现。';

-- ════════════════════════════════════════════════════════════════════════════
-- 3 · 取号提成一个函数 —— 【两扇门,一个号段】
-- ════════════════════════════════════════════════════════════════════════════
-- FA-YYYY-NNNN 是无缝编号:靠 pg_advisory_xact_lock 把"取当年最大号 + 1"串行化,
-- 事务失败回滚即释放号码。**两扇门各抄一份这段逻辑,今天一致、明天未必** ——
-- 而"一条规则两个实现"是本仓库付过最多次账的那个形状。所以提出来,两边都调它。
-- 先例:next_shipment_code / next_container_code / next_quote_code —— 同样是
-- 内层取号器,同样【没有调用者检查】,靠的就是"调不到":
-- db/views/zzz_function_grants.sql 里对 authenticated 收权。给了它,任何登录用户
-- 都能凭空烧掉一个号,而"无缝"的意思正是号码之间没有洞。
CREATE OR REPLACE FUNCTION public.next_fixed_asset_code(p_on date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_on)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('fixed_asset_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(fa.code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM fixed_assets fa
    WHERE fa.code LIKE 'FA-' || v_year::text || '-%';
    RETURN 'FA-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 4 · 第二扇门:一张【主数据】的资产卡
-- ════════════════════════════════════════════════════════════════════════════
-- 【它是什么】一台我们已经决定要买、但钱还没过账的机器。卡是【关于那台机器的
-- 主数据】,不是一笔过账 —— 所以它不碰总账,一分钱也不动。
-- 【成本怎么来】照旧走既有那扇追加门(record_expense 的 p_asset.asset_id),
-- 一分不差地与今天相同。本刀没有给成本发明第二条路。
-- 【为什么保留另一扇门】见 record_expense 里那段注释:一台【没有采购单、
-- 当场买断】的机器,卡与成本同时诞生才是那件事的真实形状。两扇门对应两种
-- 真实的取得方式,不是一新一旧。
CREATE OR REPLACE FUNCTION public.create_fixed_asset(
    p_description text,
    p_useful_life_months integer,
    p_acquisition_date date,
    p_category text DEFAULT 'equipment',
    p_depreciation_account_code text DEFAULT '6700',
    p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_id    uuid := gen_random_uuid();
    v_code  text;
    v_base  text := base_currency_code();
BEGIN
    PERFORM require_permission('module.finance.edit');

    IF COALESCE(btrim(p_description), '') = '' THEN
        RAISE EXCEPTION 'ASSET_DESCRIPTION_REQUIRED';
    END IF;
    IF p_useful_life_months IS NULL OR p_useful_life_months <= 0 THEN
        RAISE EXCEPTION 'ASSET_LIFE_INVALID|%', COALESCE(p_useful_life_months::text, '?');
    END IF;
    -- 【取得日必填,不给默认】它不决定期间、也不决定汇率(这扇门不过账),
    -- 但它是 in_service_date 的下界(fixed_assets_service_after_acquisition),
    -- 于是一个悄悄填成"今天"的取得日会把投用日的合法范围一起挪掉。
    -- 与 AGENTS.md 那条"决定期间/汇率/金额的日期必填,永不默认"同源:
    -- 会被别的规则读的日期,不该由函数替人猜。
    IF p_acquisition_date IS NULL THEN
        RAISE EXCEPTION 'ASSET_ACQUISITION_DATE_REQUIRED';
    END IF;
    -- 分类:表上那条 CHECK 也拦得住,但它只给得出约束名。按名拒,并且【把可选
    -- 值报出来】—— 一条不告诉你有哪些选项的拒绝,会让人去翻建表脚本。
    IF p_category IS NULL OR p_category NOT IN ('equipment', 'vehicle', 'office', 'other') THEN
        RAISE EXCEPTION 'ASSET_CATEGORY_INVALID|%|%', COALESCE(p_category, '?'),
            'equipment,vehicle,office,other';
    END IF;

    v_code := next_fixed_asset_code(p_acquisition_date);

    -- 【零成本卡的三个金额列,逐个说清它们为什么是这些值】
    --   cost_base = 0 / cost_ccy = 0  —— 还没有任何成本落在这台机器上;
    --   currency  = 本位币             —— 不是占位符:没有发生过换算,
    --   fx_rate   = 1                     所以本位币 + 1 是这件事的实话,
    --                                     而它让 fx_rate > 0 那条 CHECK 保持原样。
    --   residual_base = 0             —— 见 fixed_assets_residual_below_cost 的注释。
    -- 【expense_id 留空】这张卡不是由一笔支出生出来的,那一列的注释写清了这件事。
    INSERT INTO fixed_assets (id, code, description, category, acquisition_date, in_service_date,
                              cost_ccy, currency, fx_rate, cost_base, useful_life_months,
                              residual_base, depreciation_account_code, expense_id, notes, created_by)
    VALUES (v_id, v_code, btrim(p_description), p_category, p_acquisition_date, NULL,
            0, v_base, 1, 0, p_useful_life_months,
            0, COALESCE(p_depreciation_account_code, '6700'), NULL, p_notes, v_user);

    RETURN jsonb_build_object(
        'asset_id', v_id, 'code', v_code,
        'cost_base', 0, 'in_service_date', NULL,
        'acquisition_date', p_acquisition_date);
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 5 · record_expense —— 只把取号换成一次调用,并写下【两扇门都不是遗留】
-- ════════════════════════════════════════════════════════════════════════════
-- 签名不变(CREATE OR REPLACE,不是重载);行为逐字不变。
CREATE OR REPLACE FUNCTION public.record_expense(p_expense_date date, p_account_code text, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_payment_status text DEFAULT 'paid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_asset jsonb DEFAULT NULL::jsonb, p_employee_id uuid DEFAULT NULL::uuid, p_purchase_order_line uuid DEFAULT NULL::uuid)
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
    v_life       integer;
    v_residual   numeric;
    v_in_service date;
    v_poline     record;   -- EQP-1b-ii:这笔支出付的那一条采购单行
    v_poline_po  record;   -- 那一行所属的采购单
    v_billed     text;     -- 该行上已有的、【未冲销的】支出编号
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

    -- ════════════════════════════════════════════════════════════════════════
    -- EQP-1b-ii:这笔支出付的是【哪一条采购单行】。
    -- 整块只在 p_purchase_order_line 非空时生效 —— 绝大多数支出根本没有采购单
    -- (D1 那个可空就是为它们留的);而运保关税、安装、调试按 D5 挂在【资产】上
    -- 走追加模式,【不带】采购单行。列注释把这两句话写在了数据库里。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_purchase_order_line IS NOT NULL THEN
        SELECT l.id, l.line_no, l.asset_id, l.purchase_order_id
        INTO v_poline
        FROM purchase_order_lines l
        WHERE l.id = p_purchase_order_line;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', p_purchase_order_line;
        END IF;

        -- ── D2:与 apply_prepayment 同形的三条单据守卫 ────────────────────────
        -- 【"存在"= 没有被软删】apply_prepayment 的那句 WHERE 也带着 deleted_at,
        -- 照抄它是刻意的:少了这一句,一张已被软删的采购单照样收得下账单。
        SELECT po.id, po.code, po.supplier_id, po.status, po.approval_status
        INTO v_poline_po
        FROM purchase_orders po
        WHERE po.id = v_poline.purchase_order_id AND po.deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PO_NOT_FOUND|%', v_poline.purchase_order_id;
        END IF;
        IF v_poline_po.status = 'cancelled' THEN
            RAISE EXCEPTION 'PO_CANCELLED|%', v_poline_po.code;
        END IF;
        IF v_poline_po.approval_status <> 'approved' THEN
            RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_poline_po.code, v_poline_po.approval_status;
        END IF;

        -- ── D3 上半:这条链接只在【设备行】上成立 ────────────────────────────
        -- 材料行经【收货】计价形成应付(reprice_inbound_batch),而收货量就是
        -- 它的计费上限。让费用单也挂得上去,等于给材料开【第二条计费路】,
        -- 而没有任何东西把这两条对得起来。同一条规矩也在表上(见下面那个触发器)。
        IF v_poline.asset_id IS NULL THEN
            RAISE EXCEPTION 'PO_LINE_NOT_EQUIPMENT|%', v_poline.line_no
              USING HINT = '材料行经收货计价形成应付,不经费用单';
        END IF;

        -- ── D3 下半:支出的资产必须【就是】行上那一台 ────────────────────────
        -- 拆成三种情形分别点名,因为它们的【修法互不相同】。合成一句"资产对不上"
        -- 会把两种根本不是"对不上"的情形也说成对不上 —— 尤其是新建那一支:
        -- 那里的资产是这一刻才生出来的,报一个"你填的 id 与行上的不符"
        -- 会打发人去核对一个一毫秒之前还不存在的 id。
        IF p_asset IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_NOT_CAPITAL|%|%', v_poline.line_no, p_account_code
              USING HINT = '挂在设备行上的支出必须是资本支出:科目 1500 + p_asset';
        END IF;
        IF (p_asset->>'asset_id') IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_CREATES_ASSET|%', v_poline.line_no
              USING HINT = '设备行引用的资产卡【已经存在】(行不创建资产),这笔支出要以追加模式挂上去:p_asset.asset_id';
        END IF;
        IF (p_asset->>'asset_id')::uuid <> v_poline.asset_id THEN
            RAISE EXCEPTION 'EXPENSE_ASSET_MISMATCH|%|%', p_asset->>'asset_id', v_poline.asset_id
              USING HINT = 'B 机器的发票不能记到 A 机器的订单行上';
        END IF;

        -- ── D2 第四条:供应商一致 —— 但先问【有没有供应商】────────────────────
        -- 【这条规矩的主体可以缺席】expenses_counterparty_shape 只对 unpaid 强制
        -- 往来对象;paid 的费用单 supplier_id 合法地为空(线上那 2 笔就是)。
        -- 于是"供应商一致"若直接写成比较,对一半的单据是拿 NULL 去比 ——
        -- 那不是"不一致",是"没人说过"。两件事两个名字。
        IF p_supplier_id IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_SUPPLIER_NOT_STATED|%', v_poline_po.code
              USING HINT = '挂在采购单行上的支出必须说出开这张票的供应商';
        END IF;
        IF p_supplier_id <> v_poline_po.supplier_id THEN
            RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_poline_po.code, p_supplier_id;
        END IF;

        -- ── D4:覆盖推导 —— 一条设备行只报销一次 ─────────────────────────────
        -- 【必须排除已冲销的】一笔冲销掉的支出【没有发生过】,它的行因此重新
        -- 可计费。判据只有一句:status = 'posted'。它站得住,是因为
        -- guard_expense_mutation 只放行 posted→reversed 且同时首挂
        -- reversed_by_expense,并且拒绝一切 DELETE —— 两列永远同步,
        -- 所以 status='reversed' 与 reversed_by_expense IS NOT NULL 是同一件事。
        -- 【这段话原本说"冲销了再记一笔"会把成本记成 170,000 —— EQP-1b-iii 之后
        --   它不再成立,所以就地退休,而不是留在这里骗下一个读它的人。】
        -- 当时(EQP-1b-ii)的实测是:冲销一笔追加模式的资本支出【允许】、分录冲掉、
        -- 而 cost_base 与成本明细原样不动,于是"冲销再记"= 100,000 的机器记成 170,000。
        -- EQP-1b-iii 修好了那一条:冲销现在会把成本退回去,并当场核对
        -- 表头 = 未冲销明细之和。所以【未投用】的机器,"冲销那笔支出再记一笔"
        -- 现在是一条安全的路,消息里也就照直说了。
        -- 【但它只在未投用时安全】资产一旦投用,冲销按名拒
        -- (ASSET_IN_SERVICE_COST_LOCKED),而向下修正一台已投用资产的成本
        -- 今天【没有任何路】—— 记在 docs/known-issues.md,带返回条件。
        -- 消息因此仍然把【改订单】放在前面:发票与估价对不上时,那才是要改的东西。
        -- 【第二层是索引】uq_expenses_live_po_line,谓词与这里逐字相同。
        -- 这里负责【可读】(带上占着这条行的那张单的编号),索引负责【正确】
        -- (并发下两笔同时通过本判据时,只有一笔落得下去)—— invoice_lines 的原话。
        SELECT e.code INTO v_billed
        FROM expenses e
        WHERE e.purchase_order_line_id = p_purchase_order_line
          AND e.status = 'posted'
        LIMIT 1;
        IF v_billed IS NOT NULL THEN
            RAISE EXCEPTION 'PO_LINE_ALREADY_EXPENSED|%|%', v_poline.line_no, v_billed
              USING HINT = '一条设备行只报销一次。若是【订单上的估价】与发票对不上,要改的是订单(改行,不是删行),不是再记一笔';
        END IF;
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
        -- PAYEE-1a:往来对象【二选一】—— 供应商 或 员工,恰好一个。
        -- 【两个都给是矛盾,不是"取其一"】一笔钱不可能同时欠着两个人;
        -- 悄悄挑一个会让另一个人的账凭空消失,所以按名拒绝。
        IF num_nonnulls(p_supplier_id, p_employee_id) = 0 THEN
            RAISE EXCEPTION 'COUNTERPARTY_REQUIRED_FOR_UNPAID';
        END IF;
        IF num_nonnulls(p_supplier_id, p_employee_id) > 1 THEN
            RAISE EXCEPTION 'COUNTERPARTY_AMBIGUOUS';
        END IF;
        IF p_supplier_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', p_supplier_id;
        END IF;
        IF p_employee_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM employees WHERE id = p_employee_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', p_employee_id;
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
                          amount_base, payment_status, bank_account_code, supplier_id, employee_id,
                          payee_name, notes, journal_entry_id, created_by,
                          purchase_order_line_id)
    VALUES (v_expense_id, v_code, p_expense_date, p_account_code, p_amount, p_currency, v_fx,
            v_amount_base, p_payment_status, v_bank, p_supplier_id, p_employee_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, v_user,
            p_purchase_order_line);

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
        -- 【两扇建卡的门,而【两扇都不是遗留】—— EQP-1c-a 记在这里,免得下一个
        --   读到 create_fixed_asset 的人以为这一支该被删掉。】
        --   * 这一支(卡与成本【同时】诞生):一台【没有采购单、当场买断】的机器。
        --     那件事的真实形状就是"一张发票同时带来这台机器和它的成本",
        --     硬要拆成两步反而是编造一个不存在的中间状态。
        --   * create_fixed_asset(卡先诞生、成本后到):设备采购的常态 ——
        --     先下单(而采购单行必须引用一张【已存在】的卡,EQP-1a),
        --     后开票。发票经【追加】模式落到那张卡上。
        --   判据一句话:**这台机器在拿到它的成本之前,需不需要先被别的单据引用?**
        --   需要 → create_fixed_asset;不需要 → 这一支。
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
        -- EQP-1c-a:取号提成 next_fixed_asset_code(),两扇门共用一个号段。
        -- 【行为逐字不变】它就是原来这四行:同一把咨询锁(键也是按年拼的
        -- 'fixed_asset_code_'||year)、同一个"当年最大号 + 1"。提出来是因为
        -- 现在有【两扇】建卡的门,而两份同样的取号逻辑迟早会漂开。
        v_asset_code := next_fixed_asset_code(p_expense_date);

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

-- ════════════════════════════════════════════════════════════════════════════
-- 6 · set_asset_in_service —— 零成本的卡投用不了(D3)
-- ════════════════════════════════════════════════════════════════════════════
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
    -- EQP-1c-a:【没有成本的卡投用不了】。create_fixed_asset 建出来的卡成本是 0,
    -- 它代表"我们已经决定买这台机器",而不是"这台机器已经可以开始折旧"。
    -- 【为什么必须按名拒,而不是让它过去】投用一张零成本卡不会报错 ——
    -- 折旧目标是 LEAST(0 - 0, ...) = 0,于是它会【安静地】每期提 0 元,
    -- 看起来像一台在役资产,实际上永远不进损益。**一个静默的空转比一条拒绝坏得多**,
    -- 而且投用是【一次性】的(改投用日要走人工分录),所以错过这一刻就很贵。
    IF v_a.cost_base = 0 THEN
        RAISE EXCEPTION 'ASSET_HAS_NO_COST|%', v_a.code
          USING HINT = '这张卡还没有任何成本 —— 先把发票经追加模式记到它上面,再投用';
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

-- ════════════════════════════════════════════════════════════════════════════
-- 7 · dispose_fixed_asset —— 同一条规矩的另一半(grill 加的)
-- ════════════════════════════════════════════════════════════════════════════
-- db/functions/dispose_fixed_asset.sql
-- 处置:出售或报废(FIN-22)。1500 按成本解除、1510 按累计折旧解除,差额对净收款
-- 进 7200(与 7100/7110 同形,两个方向都过)。收款 > 0 必须给银行科目;报废收款 0。
-- 【不自动补提】处置月折旧 —— 想提就先跑月度例程再处置;未提部分如实进损益。

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
    -- EQP-1c-a:【零成本的卡处置不了 —— 而这一条是本刀自己造出来的路,所以本刀关它】
    -- 下面那条 1500 贷方是【无条件】发出的,金额就是 cost_base;而
    -- journal_lines_amount_ccy_check 是 CHECK (amount_ccy > 0)。于是处置一张
    -- 零成本卡会撞出一条【裸的 23514】,而不是一句人话。
    -- 【为什么不改成"金额为 0 就不发那条行"】那会让处置【悄悄成功】,
    -- 把一张"还没买成的机器"变成一张"已处置"的资产 —— 而这两件事在账上
    -- 完全不是一回事。一张还没有成本的卡要退场,那是【取消一次采购承诺】,
    -- 不是【处置一台资产】,而那条路今天不存在(docs/known-issues.md 有记录)。
    -- 与 set_asset_in_service 用同一个码:同一句话 —— 这张卡还不是一台资产。
    IF v_a.cost_base = 0 THEN
        RAISE EXCEPTION 'ASSET_HAS_NO_COST|%', v_a.code
          USING HINT = '这张卡还没有任何成本,不构成一次处置 —— 它要退场是另一件事,今天没有那条路';
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
            'currency', base_currency_code(), 'amount_ccy', p_proceeds, 'line_memo', 'disposal proceeds');
    END IF;
    IF v_accum > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '1510', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', v_accum, 'line_memo', 'accumulated depreciation relieved');
    END IF;
    v_lines := v_lines || jsonb_build_object('account_code', '1500', 'side', 'credit',
        'currency', base_currency_code(), 'amount_ccy', v_a.cost_base, 'line_memo', 'cost relieved');
    IF v_gain > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7200', 'side', 'credit',
            'currency', base_currency_code(), 'amount_ccy', v_gain);
    ELSIF v_gain < 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7200', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', -v_gain);
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

COMMIT;
