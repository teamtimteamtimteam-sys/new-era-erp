-- METAL-1(2026-08-11):金属行情录入时的异常提示 —— 提醒,不拦截
--
-- 【为什么值得做,以及"运气"这个词是认真的】线上 cu 在 2026-07-30 记着
-- 80,000 USD/t,前一条(06-25)是 24,000、后一条(08-10)是 20,000 —— 3.3 倍上去
-- 又下来,没有任何东西说过一句话。一个金属行情同时喂着采购定价、批次估值与销售
-- 定价,所以一个键错的数字会在三个地方同时错,而且每一处看起来都合理。
--
-- 【它这次没有造成损失,是运气,不是防护】全库扫过一遍存下来的出处记录
-- (sales_records.price_provenance / purchase_order_lines.price_provenance /
-- processing_runs.allocation_snapshot):80,000 一次都没有被用过。原因是
-- PF-2026-0001 只付 co/li/ni —— 铜压根不可付,所以它出现在明细行上、没有进钱。
-- 【但分摊那条路没有这层运气】allocate_processing_costs 按产出金属含量直接取价,
-- 【没有任何 payable 过滤】。PROC-2026-0164 在 08-10 17:38 按 metal_value 分摊,
-- 而修正的 20,000 是 17:32 录进来的 —— 差六分钟。早一小时跑,含铜产出会吞下
-- 大约四倍于实情的成本份额,并且被 allocation_snapshot 记成事实。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【判据:与该金属【上一条】报价相比】—— 而不是滚动均值,理由是数据本身
--
-- 线上 11 行、7 个金属、4 个行情日;al/fe/li/mn 各只有【一条】报价。
-- 30 天窗口里每个金属都只有一条 —— 于是"滚动均值"就是那一条自己,拿一个数和
-- 它自己比,永远不会响。那是 OPS-17 那种"自己跟自己比"的自检,只不过这次是
-- 数据把它变成那样的,不是代码。所以判据是【与上一条报价的变动幅度】。
--
-- 【三种判词,no_reference 不是 false】第一条报价没有可比的对象。今天 7 个金属里
-- 有 4 个正处在这个状态,而【键错的第一条报价一样是错的】—— 把"没法查"记成
-- "查过、没问题",正是这套检查存在的理由的反面。所以判词有三种,界面照三种画。
-- 【补上它需要什么】per-metal 的绝对区间(7 个金属 × 上下界),那是 Tim 的一个
-- 决定,不是一次实现 —— 在他给出那些数字之前,这里【明写缺口】,不假装覆盖。
--
-- 【按 price_date 取上一条,不按 created_at】录入是阵发的,而且补录发生过
-- (6-25 的行情 7-2 才录进来,ASY-3 报告实测)。按录入时间判断新旧,补录当天
-- 会显得"刚更新过"。没有更早的一条时,回落到【最近的更晚一条】并说明用的是
-- 哪一侧 —— 补录进历史中间的那一条因此照样被检查(与 fx_rate_asof 报出
-- "这个价来自哪一天"是同一个惯用法:反正要反查,就把反查的结果说出来)。
--
-- 【提醒,不拦截】3 倍的真实行情是可能的,拒收它是错的;而系统【无法分辨】
-- 哪一种是哪一种 —— 与证书处置按类型分(CMP-1)同一条理由。所以提示把两个数字
-- 都摆出来,由人确认。数据库这一侧【永远不拒】,它只把判词记在行上。
--
-- 【为什么判词要落在行上,而不是只在界面上说一句】三条写入路径:单条新增页、
-- 批量录入页(upsert_metal_prices)、编辑页 —— 只长在界面上的检查会被另外两条
-- 绕过,而且【它必须记在写入的那一刻】:随着后来的报价陆续进来,"上一条"是什么
-- 会变,事后重算给出的是另一个答案(FIN-26 对 price_source 的同一条论证:
-- 记录,而不是事后推断)。触发器在 BEFORE INSERT/UPDATE 上算一次,写进
-- anomaly_check;只有 metal / 价格 / 行情日真的变了才重算,改个备注不会覆盖记录。
--
-- 【阈值进可见配置,不写死】与 certificate_types.warn_lead_days、
-- finance_settings.default_allocation_basis 同一条(FIN-35/FIN-36:看得见的默认值
-- 不是假设)。列上【不给 schema 默认值】—— schema 默认值是看不见的那一种;
-- 值由引导种子一行明写地给出,重建时必须显式带着它。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1 · 可见配置 ────────────────────────────────────────────────────────────
CREATE TABLE public.pricing_settings (
    id boolean PRIMARY KEY DEFAULT true CHECK (id),
    -- 【故意没有 DEFAULT】看得见的默认值 = 引导里那一行;schema 默认值是看不见的
    metal_price_change_warn_pct numeric NOT NULL
        CHECK (metal_price_change_warn_pct > 0),
    notes text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid DEFAULT auth.uid()
);

CREATE TRIGGER trg_pricing_settings_updated_at
    BEFORE UPDATE ON public.pricing_settings
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.pricing_settings ENABLE ROW LEVEL SECURITY;
-- 读:人人可读 —— 阈值不是秘密,而且提示要在录入页上显示它(与 metal_prices
-- 自己的 USING (true) 同一条:行情是市场事实,不是谈定的条款,见 OPS-15)
CREATE POLICY "pricing_settings select"
    ON public.pricing_settings AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- 写:改阈值与录行情是同一件工作,同一个码
CREATE POLICY "pricing_settings update by permission"
    ON public.pricing_settings AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.pricing.edit'))
    WITH CHECK (has_permission('module.pricing.edit'));

-- 【50 是默认值,不是决定】证据(线上实测,2026-08-11):真实的相邻报价变动是
-- co 32,000→30,000(−6.25%)、ni 16,000→15,000(−6.25%);那次异常是
-- 24,000→80,000(+233%)与 80,000→20,000(−75%)。50 把两类分得很开,
-- 但金属市场的真实波动幅度是 Tim 的判断,不是这一行的。
INSERT INTO public.pricing_settings (id, metal_price_change_warn_pct, notes)
VALUES (true, 50,
    '默认值,不是决定:线上真实相邻变动 ≤6.25%,而 2026-07-30 那次异常是 +233% / −75%。改这一行不需要改代码。');

-- ── 2 · 判词记在行上 ────────────────────────────────────────────────────────
ALTER TABLE public.metal_prices ADD COLUMN anomaly_check jsonb;
COMMENT ON COLUMN public.metal_prices.anomaly_check IS
    'METAL-1:录入那一刻与【上一条报价】比出来的判词(outside / inside / no_reference)。记录,不事后推断 —— 后来的报价会改变"上一条"是什么。';

-- ── 3 · 判据,一份实现 ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.metal_price_anomaly(
    p_metal text, p_price numeric, p_price_date date, p_exclude_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ref_price numeric;
    v_ref_date  date;
    v_side      text;
    v_threshold numeric;
    v_change    numeric;
BEGIN
    IF p_metal IS NULL OR p_price IS NULL OR p_price <= 0 OR p_price_date IS NULL THEN
        RAISE EXCEPTION 'METAL_PRICE_ANOMALY_INPUT|%|%|%', p_metal, p_price, p_price_date;
    END IF;

    SELECT metal_price_change_warn_pct INTO v_threshold FROM pricing_settings WHERE id;
    IF v_threshold IS NULL THEN
        -- 引导必须给出这一行(见 db/tables/pricing_settings.sql)。没有配置就
        -- 【说出来】,不要悄悄按某个数字判 —— 那正是本切要拆掉的东西。
        RAISE EXCEPTION 'PRICING_SETTINGS_MISSING';
    END IF;

    -- 上一条:按 price_date,不按 created_at(补录会让 created_at 说谎)
    SELECT price_usd_per_tonne, price_date INTO v_ref_price, v_ref_date
      FROM metal_prices
     WHERE metal = p_metal AND deleted_at IS NULL
       AND price_date < p_price_date
       AND (p_exclude_id IS NULL OR id <> p_exclude_id)
     ORDER BY price_date DESC LIMIT 1;
    v_side := 'previous';

    IF v_ref_price IS NULL THEN
        -- 没有更早的一条:回落到最近的更晚一条,并说明用的是哪一侧。
        -- 补录进序列【最前面】的那一条因此照样被检查。
        SELECT price_usd_per_tonne, price_date INTO v_ref_price, v_ref_date
          FROM metal_prices
         WHERE metal = p_metal AND deleted_at IS NULL
           AND price_date > p_price_date
           AND (p_exclude_id IS NULL OR id <> p_exclude_id)
         ORDER BY price_date ASC LIMIT 1;
        v_side := 'later';
    END IF;

    IF v_ref_price IS NULL THEN
        -- 【第三种判词,不是 false】这个金属还没有任何别的报价可比。
        -- 线上 7 个金属里有 4 个正是这样,而键错的第一条报价一样是错的 ——
        -- "没法查"必须与"查过、没问题"在数据上就分得开,界面才可能分得开。
        -- 【补上它需要什么】per-metal 的绝对区间(7 个金属 × 上下界):
        -- 那是一个决定(谁来给这 14 个数字),不是一次实现。缺口明写在这里。
        RETURN jsonb_build_object(
            'verdict', 'no_reference',
            'metal', p_metal,
            'price_usd_per_tonne', p_price,
            'price_date', p_price_date,
            'threshold_pct', v_threshold,
            'reference_price', NULL,
            'reference_date', NULL,
            'reference_side', NULL,
            'change_pct', NULL,
            'checked_at', now()
        );
    END IF;

    v_change := round(abs(p_price - v_ref_price) / v_ref_price * 100, 2);

    RETURN jsonb_build_object(
        'verdict', CASE WHEN v_change > v_threshold THEN 'outside' ELSE 'inside' END,
        'metal', p_metal,
        'price_usd_per_tonne', p_price,
        'price_date', p_price_date,
        'threshold_pct', v_threshold,
        'reference_price', v_ref_price,
        'reference_date', v_ref_date,
        'reference_side', v_side,
        'change_pct', v_change,
        'checked_at', now()
    );
END;
$function$;

-- ── 4 · 三条写入路径都盖得到:触发器 ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_metal_price_anomaly()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【只在 metal / 价格 / 行情日真的变了时重算】判词是【写入那一刻】的记录:
    -- 改个备注、软删一行都不该覆盖它(后来的报价会让重算得出另一个答案)。
    IF TG_OP = 'UPDATE'
       AND NEW.metal = OLD.metal
       AND NEW.price_usd_per_tonne = OLD.price_usd_per_tonne
       AND NEW.price_date = OLD.price_date THEN
        NEW.anomaly_check := OLD.anomaly_check;
        RETURN NEW;
    END IF;

    -- 【永不拒】提醒不是拦截:3 倍的真实行情是可能的,而系统分不出哪一种是哪一种。
    NEW.anomaly_check := metal_price_anomaly(
        NEW.metal, NEW.price_usd_per_tonne, NEW.price_date, NEW.id);
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_metal_prices_anomaly
    BEFORE INSERT OR UPDATE ON public.metal_prices
    FOR EACH ROW EXECUTE FUNCTION trg_metal_price_anomaly();

-- ── 5 · 批量录入页的预览:同一份判据,一次问一整天 ──────────────────────────
-- 【页面不自己算】与 preview_revalue_foreign_balances / reprice_split 同一条规矩:
-- 预览与写入共用一份实现,否则两份算术会在写下的那天一致、此后各自漂移。
CREATE OR REPLACE FUNCTION public.preview_metal_price_anomalies(
    p_price_date date, p_prices jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_el     jsonb;
    v_metal  text;
    v_raw    text;
    v_price  numeric;
    v_out    jsonb := '[]'::jsonb;
    v_exists uuid;
BEGIN
    IF p_price_date IS NULL THEN
        RAISE EXCEPTION 'PRICE_DATE_REQUIRED';
    END IF;
    IF p_prices IS NULL OR jsonb_typeof(p_prices) <> 'array' THEN
        RAISE EXCEPTION 'NO_PRICES';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_prices)
    LOOP
        v_metal := v_el->>'metal';
        v_raw   := v_el->>'price_usd_per_tonne';
        -- 空格子跳过 —— 与 upsert_metal_prices 同一条:每日表单常常只填几个金属
        CONTINUE WHEN v_raw IS NULL OR btrim(v_raw) = '';
        v_price := v_raw::numeric;
        CONTINUE WHEN v_price IS NULL OR v_price <= 0;

        -- 覆盖已有的同日行时,那一行自己不能当参照
        SELECT id INTO v_exists FROM metal_prices
         WHERE metal = v_metal AND price_date = p_price_date AND deleted_at IS NULL;

        v_out := v_out || jsonb_build_array(
            metal_price_anomaly(v_metal, v_price, p_price_date, v_exists));
    END LOOP;

    RETURN v_out;
END;
$function$;

COMMIT;
