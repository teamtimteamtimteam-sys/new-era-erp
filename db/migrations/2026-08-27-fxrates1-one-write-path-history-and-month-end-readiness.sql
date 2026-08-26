-- FX-RATES-1(2026-08-27):牌价录入收口 —— 一个写入口、一份变更史、一张月末就绪表。
-- NOTE: apply with ./db/apply_migration.sh
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【勘察把这一刀改了,照直记下来】原本的说法是"把录入从阶段 7 提前,因为库里
-- 有表却没有门"。**那个前提是错的:门一直都在。**
-- /finance/fx(列表 + 缺口块)、/finance/fx/new(单条录入)、
-- /finance/fx/[id]/edit(修改 + 软删),而且挂在 Subnav 上。
-- **所以这【不是】第六个"库建好了却没有门"的实例。** 真正缺的是另外三件:
--   ① 一周的 USD 要 3 个价种 × 5 天 = **15 次表单提交**;
--   ② 改一条牌价是【就地编辑,不留任何痕迹】—— 而库里有 10 张 *_history;
--   ③ **fx_rate_gaps 看不见月末**(见下面 ③,这是最要紧的一条)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- ① 牌价的变更史 —— append-only
--
-- 【为什么牌价【可改】而已申报的报表【不可改】,这两条不能合成一条】
--   已申报的 GST 报表、已签下的银行对账,是**我们发出去的单据** —— 它们冻结,
--   更正是一个新事件。
--   而一条牌价是**我们记录下来的世界事实**。手滑打错一个数字,不是世界上发生了
--   一件新事,是**我们对世界的记录错了** —— 那是一次更正,不是一个事件。
--   所以这里走 price_history 那个形状:当前值可改,改必须经函数,每次改留一行。
--
-- 【为什么不能"就地改、不留痕"(也就是今天的做法)】那是唯一一种
-- **一次表单提交就能销毁审计线索**的选项。已过账的凭证不受影响
-- (journal_lines.fx_rate 冻在行上),但"我们 8 月 6 日到底用的哪个数"
-- 会被静静改写,而那个问题日后一定有人问。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE public.fx_rate_history (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    fx_rate_id  uuid NOT NULL REFERENCES public.fx_rates (id) ON DELETE RESTRICT,
    action      text NOT NULL CHECK (action IN ('created', 'corrected', 'withdrawn')),
    -- 这一刻【之后】这条牌价是什么(withdrawn 记的是撤销前的值)
    currency    text NOT NULL,
    rate_date   date NOT NULL,
    rate_type   text NOT NULL,
    rate_sgd_per_unit numeric NOT NULL CHECK (rate_sgd_per_unit > 0),
    -- 改之前是什么(created 时为 NULL —— 之前什么都不是)
    prev_rate   numeric CHECK (prev_rate IS NULL OR prev_rate > 0),
    source      text,
    notes       text,
    -- 【更正与撤销必须给理由】新建不用:新建的理由就是"这天的牌价是这个数"。
    reason      text,
    CONSTRAINT fx_rate_history_reason_shape CHECK (
        (action = 'created'   AND prev_rate IS NULL AND reason IS NULL)
     OR (action = 'corrected' AND prev_rate IS NOT NULL AND btrim(COALESCE(reason,'')) <> '')
     OR (action = 'withdrawn' AND btrim(COALESCE(reason,'')) <> '')
    ),
    changed_at  timestamptz NOT NULL DEFAULT now(),
    changed_by  uuid DEFAULT auth.uid()
);

CREATE INDEX idx_fx_rate_history_rate ON public.fx_rate_history (fx_rate_id, changed_at);

CREATE OR REPLACE FUNCTION public.reject_fx_rate_history_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'FX_RATE_HISTORY_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_fx_rate_history_immutable
    BEFORE UPDATE OR DELETE ON public.fx_rate_history
    FOR EACH ROW EXECUTE FUNCTION public.reject_fx_rate_history_mutation();

ALTER TABLE public.fx_rate_history ENABLE ROW LEVEL SECURITY;
-- 写入只走 record_fx_rate / withdraw_fx_rate(SECURITY DEFINER),故只开 SELECT。
CREATE POLICY "fx_rate_history select by permission"
    ON public.fx_rate_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- ─────────────────────────────────────────────────────────────────────────────
-- ② 只有一个写入口 —— 直写一律拦下(price_ctx 同一手法,GUC 是 evoltrya.fx_ctx)
--
-- 【这条规矩的全部力气在这一句】**一个函数意味着表格【不可能】比表单校验得松,
-- 因为没有第二个地方可以放松。** 循环调用同一个函数的批量包装是可以的;
-- 第二份实现不行。
--
-- 【DELETE 也拦】—— 这一条是新的:今天 RLS 的 delete 策略允许硬删,而硬删
-- **不留任何痕迹**。触发器对超级用户同样生效,所以这扇门从此关上;
-- 撤销走 withdraw_fx_rate(软删 + 留痕 + 必填理由)。
--
-- ★【为什么拦 UPDATE/DELETE 而【放行 INSERT】—— 照抄 price_ctx 的先例】★
--   `guard_inbound_price_change` 的抬头写着:「直改拦截(挂在 inbound_batches 上;
--   **INSERT 带价仍允许 —— 建单定价是正常路径**)」。同一条推理在这里成立:
--   **毁掉审计线索的是【改】与【删】,不是【建】** —— 一条新建的牌价,那一行
--   自己就是记录(带 created_at / created_by)。
--
--   **而且拦 INSERT 会当场拦错东西:** 26 份 fixture 直接 INSERT 播种牌价,
--   其中 `09-fx-reach-back-bounded` 播的是 **2026-09-04**(一个【未来】日期,
--   用来测有界回溯)—— 而 record_fx_rate 正确地拒绝未来日期。
--   逼 fixture 走函数,会让一份**测的是别的东西**的用例因为无关的理由红掉。
--
--   **硬删【已经关上】** —— DELETE 一律要 ctx,触发器对超级用户同样生效。
--   撤销走 withdraw_fx_rate(软删 + 留痕 + 必填理由)。
--
--   **残余风险,按名写在这里而不是假装没有:** 将来有人从应用侧【直接 INSERT】
--   一条新牌价,机制上拦不住(RLS 仍允许 insert,而放行 INSERT 是上面那条先例
--   要求的)。后果比"悄悄改一个数"轻得多 —— 新建的那一行自己就是记录 ——
--   但它会缺一条 'created' 史。今天两条应用路径都走 record_fx_rate,
--   而"不许出现第二条写入路径"目前**靠的是这段话,不是机制**。
--   真要机制化,形状是一条 scripts/check-* 棘轮(与 check-currency-literals 同族)。
--   已按名记进 docs/known-issues.md。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_fx_rate_write()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    -- 【硬删:一律经函数】硬删不留任何痕迹,是这张表上唯一真正不可追的操作。
    IF TG_OP = 'DELETE' THEN
        IF NULLIF(current_setting('evoltrya.fx_ctx', true), '') IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_VIA_FUNCTION|DELETE';
        END IF;
        RETURN OLD;
    END IF;
    -- 【UPDATE:只拦【金额被改】那一种】—— 与 guard_inbound_price_change 逐字同形
    -- (它也只在 unit_price 真的变了时才拦)。改 deleted_at(撤销)、改 notes、
    -- 改 source 都不是"把一个数悄悄换掉",不该被这条闸挡住。
    IF NEW.rate_sgd_per_unit IS DISTINCT FROM OLD.rate_sgd_per_unit
       AND NULLIF(current_setting('evoltrya.fx_ctx', true), '') IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_VIA_FUNCTION|UPDATE';
    END IF;
    RETURN NEW;
END;
$fn$;

-- INSERT 不在此列 —— 理由见上(price_ctx 先例:建是正常路径,改与删才毁线索)。
CREATE TRIGGER trg_fx_rates_write_guard
    BEFORE UPDATE OR DELETE ON public.fx_rates
    FOR EACH ROW EXECUTE FUNCTION public.guard_fx_rate_write();

-- ─────────────────────────────────────────────────────────────────────────────
-- 唯一的写入函数。表单与表格都调它,一格一次。
--
-- 【日期不许是未来】牌价是【已经发生的世界事实】。给一个还没到的日子录牌价,
-- 就是发明一个牌价 —— 与发明一个税率是同一句谎(AGENTS.md 的 FX 总则)。
-- 【绝不默认今天】p_rate_date 必填,没有 COALESCE(…, CURRENT_DATE) 这种东西。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_fx_rate(
    p_currency text, p_rate_date date, p_rate_type text,
    p_rate numeric, p_source text DEFAULT 'DBS',
    p_notes text DEFAULT NULL, p_reason text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base text;
    v_existing record;
    v_id uuid;
    v_action text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;

    IF p_rate_date IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_DATE_REQUIRED';
    END IF;
    -- 【未来日期即拒】—— 见函数头。这一条今天的界面没有,是本刀补的。
    IF p_rate_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FX_RATE_DATE_IN_FUTURE|%', p_rate_date;
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'FX_CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_currency = v_base THEN
        RAISE EXCEPTION 'FX_CURRENCY_IS_BASE|%', p_currency;
    END IF;
    IF p_rate_type IS NULL OR p_rate_type NOT IN ('tt_buy', 'tt_sell', 'mid') THEN
        RAISE EXCEPTION 'FX_RATE_TYPE_INVALID|%', COALESCE(p_rate_type, '?');
    END IF;
    IF p_rate IS NULL OR p_rate <= 0 THEN
        RAISE EXCEPTION 'FX_RATE_INVALID|%', COALESCE(p_rate::text, 'null');
    END IF;

    SELECT * INTO v_existing FROM fx_rates
     WHERE currency = p_currency AND rate_date = p_rate_date
       AND rate_type = p_rate_type AND deleted_at IS NULL
     FOR UPDATE;

    PERFORM set_config('evoltrya.fx_ctx', 'record_fx_rate', true);

    IF FOUND THEN
        -- 【已经有一条了】没给理由就拒 —— 批量表格走的正是这一支:它只填空,
        -- 不覆盖。要改一条已在册的牌价,得说为什么。
        IF btrim(COALESCE(p_reason, '')) = '' THEN
            RAISE EXCEPTION 'FX_RATE_EXISTS|%|%|%|%',
                p_currency, p_rate_date, p_rate_type, v_existing.rate_sgd_per_unit;
        END IF;
        UPDATE fx_rates
           SET rate_sgd_per_unit = p_rate,
               source = COALESCE(p_source, source),
               notes  = p_notes,
               updated_by = auth.uid()
         WHERE id = v_existing.id;
        v_id := v_existing.id; v_action := 'corrected';
        INSERT INTO fx_rate_history (fx_rate_id, action, currency, rate_date, rate_type,
                                     rate_sgd_per_unit, prev_rate, source, notes, reason)
        VALUES (v_id, 'corrected', p_currency, p_rate_date, p_rate_type,
                p_rate, v_existing.rate_sgd_per_unit, p_source, p_notes, btrim(p_reason));
    ELSE
        INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit, source, notes)
        VALUES (p_currency, p_rate_date, p_rate_type, p_rate, COALESCE(p_source, 'DBS'), p_notes)
        RETURNING id INTO v_id;
        v_action := 'created';
        INSERT INTO fx_rate_history (fx_rate_id, action, currency, rate_date, rate_type,
                                     rate_sgd_per_unit, prev_rate, source, notes, reason)
        VALUES (v_id, 'created', p_currency, p_rate_date, p_rate_type,
                p_rate, NULL, COALESCE(p_source, 'DBS'), p_notes, NULL);
    END IF;

    PERFORM set_config('evoltrya.fx_ctx', '', true);
    RETURN jsonb_build_object('id', v_id, 'action', v_action,
                              'currency', p_currency, 'rate_date', p_rate_date,
                              'rate_type', p_rate_type, 'rate', p_rate);
END;
$function$;

-- 撤销 = 软删 + 留痕 + 必填理由。硬删已被 guard 关掉。
CREATE OR REPLACE FUNCTION public.withdraw_fx_rate(p_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_r record;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF btrim(COALESCE(p_reason, '')) = '' THEN
        RAISE EXCEPTION 'FX_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_r FROM fx_rates WHERE id = p_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FX_RATE_NOT_FOUND|%', p_id;
    END IF;

    PERFORM set_config('evoltrya.fx_ctx', 'withdraw_fx_rate', true);
    UPDATE fx_rates SET deleted_at = now(), updated_by = auth.uid() WHERE id = p_id;
    INSERT INTO fx_rate_history (fx_rate_id, action, currency, rate_date, rate_type,
                                 rate_sgd_per_unit, prev_rate, source, notes, reason)
    VALUES (p_id, 'withdrawn', v_r.currency, v_r.rate_date, v_r.rate_type,
            v_r.rate_sgd_per_unit, v_r.rate_sgd_per_unit, v_r.source, v_r.notes, btrim(p_reason));
    PERFORM set_config('evoltrya.fx_ctx', '', true);
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- ③ 月末就绪 —— **fx_rate_gaps 结构上看不见月末,这张视图就是为那个盲区建的**
--
-- ★【为什么是【另一张】视图,而不是给 fx_rate_gaps 加第三个 gap_source】★
--   **两张视图断言的是两件不同的事,而其中一件的可信度全靠它【不】做另一件:**
--     · `fx_rate_gaps`:「**发生过事情**的那一天缺牌价」——
--       它的每一行都有证据撑着(那天有过账,或那天有报价)。
--     · 本视图:「**可能什么都还没发生**的那一天【仍然】需要牌价」——
--       月末就是这样一个日子:2026-08-31 上没有一笔过账、没有一条报价,
--       而月末重估**非要它的中间价不可**。
--   把"发明出来的日期"塞进 fx_rate_gaps,会毁掉它每一行都有证据这个性质,
--   而那个性质正是它值得被相信的全部理由。**所以:两张视图,两个意思。**
--   (这段话同时抄在 fx_rate_gaps 的文件头 —— 免得日后有人"顺手合并"它们。)
--
-- 【问的是 fx_rate_asof,不是精确匹配】因为重估问的就是它:月末落在周六时,
-- 用周五的中间价是对的(FIN-19 的有界回溯),那种日子【就绪】,不该报成缺。
--
-- 【revalued 那一列用 status='posted',而这是【对的】那一类用法】
-- 它问的是"这一期已经重估过了吗"——【单张分录还活着没有】,不是求和。
-- (AGENTS.md「求和 vs 判活」那一节;/finance/month-end 问的是同一条。)
--
-- 【范围是数据定的,不是拍的】从**第一笔外币货币性分录所在的月份**起,
-- 到**当月**止。没有外币分录就一行都没有 —— 空集在这里是正确答案,不是失败。
-- SECURITY INVOKER。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.fx_month_end_readiness
WITH (security_invoker = on) AS
 WITH b AS (SELECT c.code FROM currencies c WHERE c.is_base),
 fx_lines AS (
     SELECT jl.currency, e.entry_date
     FROM journal_lines jl
     JOIN accounts a ON a.id = jl.account_id
     JOIN journal_entries e ON e.id = jl.entry_id
     WHERE a.is_monetary AND jl.currency <> (SELECT code FROM b)
 ),
 ccy AS (SELECT DISTINCT currency FROM fx_lines),
 span AS (SELECT date_trunc('month', min(entry_date))::date AS first_month FROM fx_lines),
 months AS (
     SELECT (date_trunc('month', gs)::date + INTERVAL '1 month' - INTERVAL '1 day')::date AS month_end
     FROM span, generate_series(span.first_month,
                                date_trunc('month', CURRENT_DATE)::date,
                                INTERVAL '1 month') gs
     WHERE span.first_month IS NOT NULL
 )
 SELECT m.month_end,
    c.currency,
    (SELECT x.rate FROM fx_rate_asof(c.currency, m.month_end, 'mid') x) AS mid_rate,
    (SELECT x.as_of FROM fx_rate_asof(c.currency, m.month_end, 'mid') x) AS mid_rate_as_of,
    ((SELECT x.rate FROM fx_rate_asof(c.currency, m.month_end, 'mid') x) IS NOT NULL) AS has_mid,
    EXISTS (SELECT 1 FROM journal_entries e2
             WHERE e2.source_type = 'revaluation'
               AND e2.entry_date = m.month_end
               AND e2.status = 'posted') AS revalued,
    -- 【挡住月结的就是这一列】没有中间价、又还没重估过
    ((SELECT x.rate FROM fx_rate_asof(c.currency, m.month_end, 'mid') x) IS NULL
      AND NOT EXISTS (SELECT 1 FROM journal_entries e3
                       WHERE e3.source_type = 'revaluation'
                         AND e3.entry_date = m.month_end
                         AND e3.status = 'posted')) AS blocks_close
   FROM months m CROSS JOIN ccy c;

COMMIT;
