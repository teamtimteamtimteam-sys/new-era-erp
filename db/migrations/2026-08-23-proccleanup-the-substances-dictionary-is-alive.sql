-- PROC-CLEANUP:让 substances 那张字典【真的活着】—— 补上 PROC-4 漏掉的三支函数
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【A1:怎么查的,以及为什么之前会漏】
-- PROC-4 报"残留的写死清单 0"。**那句话对【约束】成立,而它被当成了全部答案** ——
-- 它的 S1 只查了 pg_constraint。PROC-6 顺手撞见函数体里还有,本刀把四处一起查:
--
--   查法:在【线上目录】里,把 substances 的每一个 code 拿去匹配四类对象的定义
--         (pg_get_functiondef / pg_get_viewdef / pg_get_constraintdef /
--          pg_get_triggerdef),命中 >= 4 个码的算嫌疑。
--   **而且先用 regexp_replace 剥掉 SQL 注释再匹配** —— 否则 record_assay_result
--   会是假阳性:PROC-6 在它的注释里【引用了】那份旧清单。
--   (不在仓库里 grep:db/migrations 全是历史,会把答案淹掉。)
--
--   结果:函数 3 支 · 视图 0 · 约束 0 · 触发器 0 · app 0。
--
-- 【三支都是同一个形状】
--     IF v_metal IS NULL OR v_metal NOT IN ('ni','co','li','mn','cu','al','fe') THEN
--   后果是具体的:往 substances 加一行(比如氟)之后,**外键会放行它,
--   而这三支函数按 METAL_INVALID 把它拒掉** —— 那张字典因此只活了一半。
--
-- 【本刀是【加法且可选】的】三支函数都是把判据从"写死七个"改成"读字典",
-- **接受的集合只会变大,不会变小**;没有新参数,旧调用方一个字都不用改。
-- 所以走标准顺序,不是 app-first(app-first 是给"旧调用方会被拒"的那一类的,
-- PROC-6 就是那一类,它让新化验单 22 分钟记不下来)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.calculate_metal_price_from_terms(p_terms jsonb, p_metals jsonb, p_quantity_kg numeric, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ref          date;
    v_index        text;
    v_index_ccy    text;
    v_index_known  boolean;
    v_legs         jsonb;
    v_basis        text;
    v_avg_days     integer;
    v_payables     jsonb;
    v_el           jsonb;
    v_metal        text;
    v_content      numeric;
    v_seen         text[] := ARRAY[]::text[];
    v_payable      numeric;
    v_stated       boolean;   -- ASY-2:本金属在条款里【有没有】被提到
    v_price        numeric;
    v_price_date   date;
    v_from         date;
    v_to           date;
    v_contained    numeric;
    v_payable_kg   numeric;
    v_value        numeric;
    v_lines        jsonb := '[]'::jsonb;
    v_skipped      text[] := ARRAY[]::text[];
    v_unpaid       text[] := ARRAY[]::text[];
    v_gross        numeric := 0;
    v_treatment    numeric;
    v_discount     numeric;
    v_net          numeric;
    v_unit         numeric;
BEGIN
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;
    v_ref := p_reference_date;
    IF p_terms IS NULL OR jsonb_typeof(p_terms) <> 'object' THEN
        RAISE EXCEPTION 'PRICING_TERMS_INVALID';
    END IF;
    -- METAL-2:条款声明的指数。NULL = 未声明,只看同样未标注指数的行情。
    v_index    := p_terms->>'price_index';
    -- METAL-2:【报价币种没声明就不许算钱】本函数是 USD 进 USD 出(FIN-15 记过:
    -- 换算属于路径,不属于本函数)。一个指数若没声明它按什么货币报价,把它的数字
    -- 当成 USD 就是替这个市场宣称了一件没人说过的事 —— 那与编造一个汇率是同一件事,
    -- 而 THE FX RULE 对编造汇率的答复是:拒绝,并说出缺的是什么。
    -- 未声明指数(v_index IS NULL)的老序列不走这道闸:它按 USD 记了一整年,
    -- 这一点由 metal_prices.price_usd_per_tonne 这个列名本身承担(见迁移抬头)。
    IF v_index IS NOT NULL THEN
        SELECT i.quote_currency, true INTO v_index_ccy, v_index_known
        FROM metal_price_indices i WHERE i.code = v_index AND i.is_active;
        IF NOT COALESCE(v_index_known, false) THEN
            RAISE EXCEPTION 'PRICE_INDEX_UNKNOWN|%', v_index;
        END IF;
        IF v_index_ccy IS NULL THEN
            RAISE EXCEPTION 'INDEX_CURRENCY_NOT_STATED|%', v_index;
        END IF;
    END IF;
    v_basis    := p_terms->>'price_basis';
    v_avg_days := (p_terms->>'average_days')::integer;
    v_payables := COALESCE(p_terms->'payables', '{}'::jsonb);

    -- 2. 数量
    IF p_quantity_kg IS NULL OR p_quantity_kg <= 0 THEN
        RAISE EXCEPTION 'QUANTITY_INVALID';
    END IF;

    -- 3. 金属清单
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        -- PROC-CLEANUP:【现读字典】。这里原本写死七个码 —— 那是 PROC-4 漏掉的三份之一。
        -- PROC-4 报的"残留 0"只对【约束】成立,它的 S1 没有查函数体。
        -- 后果是具体的:往 substances 加一行之后,外键放行,而这里按 METAL_INVALID 拒 ——
        -- 于是"加一种物质 = 加一行"这句承诺,在这条路上不成立。
        IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances WHERE code = v_metal) THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;

        v_content := (v_el->>'content_pct')::numeric;
        IF v_content IS NULL OR v_content < 0 OR v_content > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;

        -- 4. 商务条款:条款里没有这个金属 = 完全不计价(payable 0),记入 unpaid_metals。
        --    注意与 skipped 的区别:unpaid 是"没谈价",skipped 是"没行情"。
        -- ASY-2:【条款里没有这个金属】与【条款写明 0%】是两件事,不能都印成 0。
        -- v_stated 把这个区别一路带到输出行:未约定的行 payable/payable_kg/value
        -- 一律给 NULL(界面渲染成"—"),0 从此只属于真的谈成了零的条款。
        -- payable_pct 的 CHECK 是 >= 0,所以"明确 0%"是可表示的、正当的一种条款。
        v_stated := v_payables ? v_metal;
        IF v_stated THEN
            v_payable := (v_payables->>v_metal)::numeric;
        ELSE
            v_payable := 0;
            v_unpaid := v_unpaid || v_metal;
        END IF;

        -- 5. 行情:spot 取参考日之前最近一条;average 取窗口内均值(窗口内无行 → NULL)。
        v_price := NULL; v_price_date := NULL; v_from := NULL; v_to := NULL; v_legs := NULL;
        IF v_basis = 'spot' THEN
            -- METAL-3:【读的时候换算,按报价自己那一天】。报价按发布原样存
            -- (SMM 存 CNY),换成本函数的 USD 基准是 metal_quote_to_usd 的事 ——
            -- 一处实现,spot 与 average 共用;缺汇率它自己抛 FX_RATE_MISSING。
            SELECT c.usd, mp.price_date, jsonb_build_array(c.leg)
            INTO v_price, v_price_date, v_legs
            FROM metal_prices mp
            CROSS JOIN LATERAL metal_quote_to_usd(mp.price_usd_per_tonne,
                COALESCE(v_index_ccy, 'USD'), mp.price_date) c
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL AND mp.price_date <= v_ref
              -- METAL-2:只看本条款声明的那个指数。IS NOT DISTINCT FROM 让
              -- 【未声明】只匹配【未标注】,而不是匹配任何一条。
              AND mp.price_index IS NOT DISTINCT FROM v_index
            ORDER BY mp.price_date DESC
            LIMIT 1;
        ELSE
            -- price_from / price_to 报【实际参与均值的行】的日期范围,而不是名义窗口 ——
            -- 结算单据上要能看出这个均价到底由哪几天的行情撑起来。
            -- METAL-3:【每条各按自己那天换算,再取平均】,不是先平均再换 ——
            -- 先平均再换会让窗口内的一次汇率波动污染窗口里的每一天。
            -- v_legs 逐条记下出处,于是这个均价可以被重导出,而不是被相信。
            SELECT avg(c.usd), min(mp.price_date), max(mp.price_date),
                   COALESCE(jsonb_agg(c.leg ORDER BY mp.price_date), '[]'::jsonb)
            INTO v_price, v_from, v_to, v_legs
            FROM metal_prices mp
            CROSS JOIN LATERAL metal_quote_to_usd(mp.price_usd_per_tonne,
                COALESCE(v_index_ccy, 'USD'), mp.price_date) c
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL
              AND mp.price_index IS NOT DISTINCT FROM v_index   -- METAL-2:同上
              AND mp.price_date BETWEEN (v_ref - (v_avg_days - 1)) AND v_ref;
        END IF;

        -- 无可用行情 → 跳过(贡献 0),记入 skipped_metals;沿用 allocate_processing_costs
        -- 的先例:缺行情从来不是硬错误。
        IF v_price IS NULL THEN
            v_skipped := v_skipped || v_metal;
        END IF;

        -- 6. 逐行数量与金额
        v_contained  := round(p_quantity_kg * v_content / 100.0, 4);
        v_payable_kg := round(v_contained * v_payable / 100.0, 4);
        v_value      := CASE WHEN v_price IS NULL THEN 0
                             ELSE round(v_payable_kg / 1000.0 * v_price, 2) END;
        v_gross := v_gross + v_value;

        -- 缺行情/未计价的金属同样出现在 lines 里(金额 0、价格 NULL)——
        -- 结算单据要能逐项交代,不能让它们凭空消失。
        v_lines := v_lines || jsonb_build_object(
            'metal', v_metal,
            'content_pct', v_content,
            -- 未约定 → NULL("未列明"),而不是 0("谈定不付")。金额同理:
            -- 没有条款算不出金额,没有行情也算不出 —— 两种 NULL 都由界面渲染成"—",
            -- 上方的灰字/琥珀提示分别说明是哪一种。汇总仍按 0 累加(贡献确实为零)。
            'payable_pct', CASE WHEN v_stated THEN v_payable END,
            'contained_kg', v_contained,
            'payable_kg', CASE WHEN v_stated THEN v_payable_kg END,
            'price_index', v_index,
            -- METAL-3:换算出处。CNY 原始数、两条腿的汇率、各自实际取自哪一天、
            -- 以及价种(mid)—— 与 price_history 记 original_price / fx_rate /
            -- rate_as_of / rate_type 是同一套做法:数要能被重导出,而不是被相信。
            'fx_legs', COALESCE(v_legs, '[]'::jsonb),
            'quote_currency', COALESCE(v_index_ccy, 'USD'),
            'price_usd_per_tonne', v_price,
            'price_date', v_price_date,
            'price_from', v_from,
            'price_to', v_to,
            'metal_value_usd', CASE WHEN v_stated AND v_price IS NOT NULL THEN v_value END
        );
    END LOOP;

    -- 7. 汇总
    v_gross     := round(v_gross, 2);
    v_treatment := round(p_quantity_kg / 1000.0 * (p_terms->>'treatment_charge_usd_per_tonne')::numeric, 2);
    v_discount  := round(v_gross * (p_terms->>'flat_discount_pct')::numeric / 100.0, 2);
    v_net       := round(v_gross - v_treatment - v_discount, 2);
    v_unit      := round(v_net / p_quantity_kg, 4);

    RETURN jsonb_build_object(
        'formula_id', (p_terms->>'formula_id')::uuid,
        'formula_code', p_terms->>'formula_code',
        'formula_name', p_terms->>'formula_name',
        'price_index', v_index,
        'price_basis', v_basis,
        'average_days', v_avg_days,
        -- FIN-27:这个数按【哪一份条款】算出来的,以及那份条款的费率本身 ——
        -- 出处要能重导出,就不能只给导出后的金额(FIN-26 的同一条道理)。
        'terms_source', p_terms->>'terms_source',
        'commitment_id', p_terms->>'commitment_id',
        'treatment_charge_usd_per_tonne', (p_terms->>'treatment_charge_usd_per_tonne')::numeric,
        'flat_discount_pct', (p_terms->>'flat_discount_pct')::numeric,
        'reference_date', v_ref,
        'quantity_kg', p_quantity_kg,
        'lines', v_lines,
        'gross_value_usd', v_gross,
        'treatment_usd', v_treatment,
        'discount_usd', v_discount,
        'net_value_usd', v_net,
        'unit_price_usd_per_kg', v_unit,
        -- 低品位料确实可能"不值它的处理费";照实返回,由调用方决定接不接这单。
        'negative_value', (v_net < 0),
        'skipped_metals', to_jsonb(v_skipped),
        'unpaid_metals', to_jsonb(v_unpaid)
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_material_required_metals(p_material_id uuid, p_metals text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_metal text;
    v_clean text[];
BEGIN
    PERFORM require_permission('module.materials.edit');

    IF p_material_id IS NULL THEN
        RAISE EXCEPTION 'MATERIAL_REQUIRED';
    END IF;
    SELECT code INTO v_code FROM materials WHERE id = p_material_id AND deleted_at IS NULL;
    -- 【物料不存在 ≠ 物料没有要求】前者是问错了问题。合成一个"没有要求"就是把
    -- 打错的 id 显示成一个正当的答案(mustRows / restRows / ACCOUNT_NOT_FOUND 同一条)。
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'MATERIAL_NOT_FOUND|%', p_material_id;
    END IF;

    -- 【NULL 与空数组【都】是"清空要求",而它们必须走到同一个地方】
    -- 一个把 NULL 读成"什么都不做"的实现,会让"取消全部要求"这个动作静默失败。
    v_clean := COALESCE(p_metals, ARRAY[]::text[]);

    FOREACH v_metal IN ARRAY v_clean LOOP
        -- PROC-CLEANUP:【现读字典】。这里原本写死七个码 —— 那是 PROC-4 漏掉的三份之一。
        -- PROC-4 报的"残留 0"只对【约束】成立,它的 S1 没有查函数体。
        -- 后果是具体的:往 substances 加一行之后,外键放行,而这里按 METAL_INVALID 拒 ——
        -- 于是"加一种物质 = 加一行"这句承诺,在这条路上不成立。
        IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances WHERE code = v_metal) THEN
            RAISE EXCEPTION 'METAL_UNKNOWN|%', COALESCE(v_metal, '(null)');
        END IF;
    END LOOP;

    -- 【重复的金属按名拒,不是悄悄去重】传 ['cu','cu'] 的调用方对自己要什么是糊涂的,
    -- 而去重会让它以为自己说清楚了。
    IF (SELECT count(*) FROM unnest(v_clean)) <>
       (SELECT count(DISTINCT x) FROM unnest(v_clean) x) THEN
        RAISE EXCEPTION 'METAL_DUPLICATED|%', array_to_string(v_clean, ',');
    END IF;

    -- 整套替换:先删后插,同一个事务 —— 不存在"改了一半"的中间态。
    DELETE FROM material_required_metals WHERE material_id = p_material_id;
    INSERT INTO material_required_metals (material_id, metal)
    SELECT p_material_id, x FROM unnest(v_clean) x;

    RETURN jsonb_build_object(
        'material_id', p_material_id,
        'material_code', v_code,
        -- 【空集就报空集,并且说出来它是空的】调用方(ASY-P2 的界面)据此印
        -- 「无化验要求」那句话,而不是靠"数组长度是 0"自己去猜一句文案。
        'metals', COALESCE(to_jsonb(v_clean), '[]'::jsonb),
        'metal_count', COALESCE(array_length(v_clean, 1), 0),
        'has_requirement', COALESCE(array_length(v_clean, 1), 0) > 0
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_metal_prices(p_price_date date, p_prices jsonb, p_price_index text DEFAULT NULL::text, p_source text DEFAULT NULL::text, p_source_reference text DEFAULT NULL::text, p_quote_delayed boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_el       jsonb;
    v_metal    text;
    v_raw      text;
    v_price    numeric;
    v_inserted integer := 0;
    v_updated  integer := 0;
    v_skipped  integer := 0;
    v_was_ins  boolean;
BEGIN
    PERFORM require_permission('module.pricing.edit');
    -- METAL-2:录入的是【哪个指数】的行情。NULL = 未声明(老序列),它是一个
    -- 可表示的状态而不是默认值 —— 界面上是一个必须选的下拉,而不是留空就当某个值。
    IF p_price_index IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM metal_price_indices WHERE code = p_price_index AND is_active) THEN
        RAISE EXCEPTION 'PRICE_INDEX_UNKNOWN|%', p_price_index;
    END IF;
    IF p_price_date IS NULL THEN
        RAISE EXCEPTION 'PRICE_DATE_REQUIRED';
    END IF;

    -- LME-1a:【出处必填,而且按名拒】p_source 有 DEFAULT NULL 只是为了不打断
    -- 既有调用方的参数写法 —— 它【不是】一个可以省略的参数,漏了就在这里停下。
    -- 表上那条 NOT NULL(已拿掉 DEFAULT)是兜底:它挡得住绕过本函数的直插,
    -- 但抛出来的是约束原文;这一句是给人看的那一版。
    IF p_source IS NULL OR btrim(p_source) = '' THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_REQUIRED';
    END IF;
    IF p_source NOT IN ('published_index','broker_quote','internal_estimate','unknown') THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_INVALID|%', p_source;
    END IF;
    -- 【unknown 不许用在新录入上】它是给 LME-1a 之前那些无从考证的历史行的。
    -- 允许新录入选 unknown,等于把这一列变回一句空话 —— 只是换了个词。
    IF p_source = 'unknown' THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_UNKNOWN_NOT_ALLOWED_FOR_NEW';
    END IF;
    -- 【published_index 必须说得出是哪一个】表上有同样的 CHECK;这一句先说人话。
    IF p_source = 'published_index' AND p_price_index IS NULL THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_INDEX_REQUIRED';
    END IF;
    IF p_prices IS NULL OR jsonb_typeof(p_prices) <> 'array' THEN
        RAISE EXCEPTION 'NO_PRICES';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_prices)
    LOOP
        v_metal := v_el->>'metal';
        -- PROC-CLEANUP:【现读字典】。这里原本写死七个码 —— 那是 PROC-4 漏掉的三份之一。
        -- PROC-4 报的"残留 0"只对【约束】成立,它的 S1 没有查函数体。
        -- 后果是具体的:往 substances 加一行之后,外键放行,而这里按 METAL_INVALID 拒 ——
        -- 于是"加一种物质 = 加一行"这句承诺,在这条路上不成立。
        IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances WHERE code = v_metal) THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;

        -- 空值跳过而不是报错:UI 的每日录入表单常常只填了其中几个金属。
        v_raw := v_el->>'price_usd_per_tonne';
        IF v_raw IS NULL OR btrim(v_raw) = '' THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        v_price := v_raw::numeric;
        IF v_price IS NULL OR v_price <= 0 THEN
            RAISE EXCEPTION 'PRICE_INVALID|%|%', v_metal, v_raw;
        END IF;

        -- (metal, price_date) 唯一。软删的行也占着这个位置 —— 撞上就顺手复活它
        -- (deleted_at = NULL)并写入新价,这两种情形都算 updated。
        INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, price_index, source,
                                  source_reference, quote_delayed, created_by, updated_by)
        VALUES (v_metal, v_price, p_price_date, p_price_index, p_source,
                nullif(btrim(coalesce(p_source_reference,'')), ''), p_quote_delayed, v_user, v_user)
        ON CONFLICT (metal, price_date, price_index) DO UPDATE
        SET price_usd_per_tonne = EXCLUDED.price_usd_per_tonne,
            source              = EXCLUDED.source,
            source_reference    = EXCLUDED.source_reference,
            quote_delayed       = EXCLUDED.quote_delayed,
            deleted_at          = NULL,
            updated_by          = v_user
        RETURNING (xmax = 0) INTO v_was_ins;

        IF v_was_ins THEN
            v_inserted := v_inserted + 1;
        ELSE
            v_updated := v_updated + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'price_date', p_price_date,
        'price_index', p_price_index,
        'source', p_source,
        'inserted', v_inserted,
        'updated', v_updated,
        'skipped', v_skipped
    );
END;
$function$;

COMMIT;
