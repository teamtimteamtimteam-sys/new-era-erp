-- LME-1a:一条行情说得出【它是从哪来的】
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这一刀不抓取任何东西,而且以后也不打算抓】LME-0 的勘察把话说死了:
--   * SMM 的条款逐字禁止复制【单个价格】("including, but not limited to,
--     single prices … in any form or for any purpose whatsoever");
--   * lme.com 对自动抓取一律 403(实测:政策 PDF、分发页、许可页,全部)。
-- 所以这里没有 scraper,也没有为 scraper 留的钩子。**本刀修的是【手工录入】那条
-- 路** —— 而那条路上的每一条行情都缺同样的东西,与将来是否有订阅无关。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【今天 source 这一列是一句空话】
-- text NOT NULL DEFAULT 'manual',没有 CHECK,而唯一的写入函数
-- upsert_metal_prices 把它【写死成 'manual'】。于是这一列看起来在回答
-- "这个数从哪来",实际只回答了"有人打字进来的" —— 而那是任何一条记录都成立的。
-- 线上 10 条行情,source 全是 'manual',price_index 全是 NULL。
--
-- 【约束落在【表】上,不只落在函数里 —— 这是量出来的】
-- 实测(回滚型探针,2026-08-18):以 authenticated + module.pricing.edit 直接
-- `INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date)`【成功】,
-- 而 source 悄悄落成默认值 'manual'。也就是说 upsert_metal_prices 【不是】
-- 唯一的门(该表有 INSERT 策略,PostgREST 直插走得通)。
-- 所以:**把 DEFAULT 拿掉**。NOT NULL 少了默认值之后,任何一扇门漏填 source
-- 都会当场失败 —— 函数那道具名拒绝是给人看的好消息,表这道是兜底。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【取值集合,四个】
--   published_index    发布的指数行情。**是哪一个由 price_index 回答** ——
--                      两列合起来才是完整的出处,所以下面有一条配对约束。
--   broker_quote       交易对手/经纪商的报价(邮件、单据、口头后补的书面)。
--   internal_estimate  我们自己的估计。它【不是】市场价,而把它标成市场价
--                      正是这一列存在要防的事。
--   unknown            没有记录过。**它是一个可表示的状态,不是默认值** ——
--                      新录入必须明说;只有历史行携带它。
--
-- 【为什么 published_index 必须配一个 price_index】
-- "它来自某个发布的指数,但我们不知道是哪一个"是一句自相矛盾的话:
-- LME 与 SMM 的报价币种不同(USD vs CNY)、换算路径不同,不知道是哪一个
-- 就等于不知道这个数是什么。**这一条是本刀的一个判断,不是 brief 要求的** ——
-- 写在这里是为了它可被反对:反对的话,删掉这条 CHECK 即可,别的都不用动。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【那 10 条历史行:给 unknown,绝不回填】
-- 它们是在没有人记录出处的年代录进来的。把它们标成 'published_index' 需要
-- 猜是哪一个指数、标成 'broker_quote' 需要猜是谁报的 —— 而 FIN-26 那一课
-- 说得很清楚:**一条伪造的出处比一片空白更坏**,因为空白会让人去查,
-- 伪造会让人停下来。
-- 'manual' → 'unknown' 【不是】一次改写含义:'manual' 说的是"有人打的字",
-- 它从来就没有回答过出处。换成 unknown 是把这件事**说出口**。
--
-- 镜像:db/tables/metal_prices.sql、db/functions/upsert_metal_prices.sql;
-- 行为断言:fixture 91。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ═══ 1 · 历史行先说实话,再上约束 ═══════════════════════════════════════════
-- 【顺序要紧】CHECK 会校验既有行;不先把 'manual' 换掉,ADD CONSTRAINT 会失败。
UPDATE public.metal_prices SET source = 'unknown' WHERE source = 'manual';

-- ═══ 2 · source 成为一个真的答案 ═══════════════════════════════════════════
-- 【拿掉默认值】这是本刀最要紧的一行:有默认值时,任何漏填都会被悄悄补上
-- 一个看起来像答案的值。没有默认值,漏填就是一次失败。
ALTER TABLE public.metal_prices ALTER COLUMN source DROP DEFAULT;

ALTER TABLE public.metal_prices
    ADD CONSTRAINT metal_prices_source_check
    CHECK (source = ANY (ARRAY['published_index'::text, 'broker_quote'::text,
                               'internal_estimate'::text, 'unknown'::text]));

-- 【配对】published_index 必须说得出是哪一个(理由见抬头)。
ALTER TABLE public.metal_prices
    ADD CONSTRAINT metal_prices_index_source_pairing
    CHECK (source <> 'published_index' OR price_index IS NOT NULL);

COMMENT ON COLUMN public.metal_prices.source IS
    'LME-1a:这个数【是哪一种来源】。四取一,没有默认值 —— 漏填就是一次失败,而不是悄悄补上一个看起来像答案的值。
published_index=发布的指数行情(【是哪一个由 price_index 回答】,两列合起来才是完整出处,并由 metal_prices_index_source_pairing 强制配对);broker_quote=交易对手/经纪商报价;internal_estimate=我们自己的估计(它不是市场价,把它当市场价正是本列要防的事);unknown=没有记录过。
【unknown 是可表示的状态,不是默认值】新录入必须明说是哪一种;只有 LME-1a 之前的历史行携带它。
【本列此前是一句空话】text NOT NULL DEFAULT ''manual'' 且无 CHECK,而唯一的写入函数把它写死成 ''manual'' —— 于是它看起来在回答"从哪来",实际只回答了"有人打字进来的",而那对任何一条记录都成立。
【约束在表上,不只在函数里】实测:以 authenticated + module.pricing.edit 直插本表【成功】,source 悄悄落成默认值 —— upsert_metal_prices 不是唯一的门。';

-- ═══ 3 · 争议时答得出来的两样东西 ══════════════════════════════════════════
-- 【都可空,而且空【就是】一个答案】"没有记录"与"记录了空"在这里是同一件事,
-- 所以不给默认值、不给 NOT NULL、也不推断。
ALTER TABLE public.metal_prices ADD COLUMN source_reference text;
ALTER TABLE public.metal_prices ADD COLUMN quote_delayed boolean;

COMMENT ON COLUMN public.metal_prices.source_reference IS
    'LME-1a:这条行情的【凭据】—— 一份单据号、一个截图文件名、一封经纪商邮件的主题行。**自由文本是刻意的:它是证据,不是数据**,没有人会按它做聚合或判断,而任何结构化都会逼着录入的人把手里真实的那一样东西塞进一个不合身的格子里。
【空 = 没有记录过凭据】不是"没有凭据"。不推断、不给默认值。';
COMMENT ON COLUMN public.metal_prices.quote_delayed IS
    'LME-1a:这个数是【当天的】还是【延迟/次日的】。true=延迟(例如 LME 免费的次日行情),false=当天,**NULL=没有记录过**——三种状态,不是两种。
【为什么要单独记】LME-0 勘察到:免费那一档是次日延迟的。一个次日的数用在当天成交的合同上,可能根本不合格;而"合不合格"这件事,事后只有这一列答得出来。
【不推断】不会从 source 或 price_date 猜它 —— 猜出来的合规判断比没有更坏。';

-- ═══ 4 · upsert_metal_prices 收下出处,并按名拒绝漏填 ══════════════════════
-- 【DROP + CREATE】加参数就是换签名;CREATE OR REPLACE 会留下两个同名函数
-- (FIN-21),而 preflight_migration.py 认得"同一支迁移里 DROP 在 CREATE 之前"。
-- 【p_source 的 DEFAULT NULL 不是"可省略"】它只是为了让既有调用点的写法不炸;
-- 真正的判据是函数体第一段那句 QUOTE_SOURCE_REQUIRED。
DROP FUNCTION public.upsert_metal_prices(date, jsonb, text);

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
        IF v_metal IS NULL OR v_metal NOT IN ('ni','co','li','mn','cu','al','fe') THEN
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
