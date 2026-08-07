-- db/migrations/2026-08-07-fin29-template-currency.sql
-- FIN-29:付款条款模板的【定额】必须自带币种,套到别的币种的单上即拒。
--
-- 【问题】模板不属于任何单据,所以它上面的 fixed_amount_ccy 在被
-- apply_payment_term_template 抄到某张 PO 之前【没有币种】。同一个模板套到
-- USD 单和 SGD 单上,"定额 10,000" 是两笔差着一个汇率的钱,而没有任何地方拦。
-- 而且它比"换错汇率"更安静:copy 是【逐字照抄】,不换算、不查汇率 ——
-- 10,000 落到两张单上都写着 10,000,两边看起来都对。
--
-- 【为什么是"声明币种 + 不同币种即拒",不是"套用时换算"】
-- 付款条款是【谈定的承诺】,不是算出来的量。把 10,000 按今天的牌价折成 12,600,
-- 记下的就不再是双方谈的那个数 —— 与 FIN-27 抄条款而不是回头重算,是同一条道理。
-- 另一条候选("定额期一律改成按比例")是靠删功能来消灭缺陷:PO 侧仍然支持定额,
-- 模板反而比它模板化的东西更弱,而这种不对称迟早被人"修"回来,且不带币种。
--
-- 【为什么币种在模板【头】上,而且【可空】】
--   * 在头上:一份模板是一份谈定的计划,整份套到一张单上,而那张单只有一个币种;
--     逐行各带币种既无处可用,也无从校验。
--   * 可空:【只有比例的模板不需要币种】—— 百分比对任何币种都成立,强行要求一个
--     币种等于逼人瞎填一个,而瞎填的字段迟早被当真。所以规则是【有定额腿才必须
--     声明】:这条跨父子两张表,CHECK 写不出来(不许子查询),因此由守卫触发器
--     执行 —— 与本仓库其它跨行不变量同一个做法。
--
-- 【存量】今天全库 0 条定额腿(1 张模板 / 3 行 / 9 条 PO 期次,全是比例),
-- 所以这条不变量【当场就能成立】,不需要回填、也不需要豁免既有行。
-- 尽管如此,apply_payment_term_template 仍然保留"未声明即点名拒"那一支:
-- 守卫之前建出来的行(今天没有,将来也不该有)不能被【悄悄照抄】,
-- 只能被拒 —— 同 FIN-26 的灰色"出处未知"、FIN-27 的无副本引用。
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-07-fin29-template-currency.sql

BEGIN;

-- ── 1. 模板头上的币种(可空:只有比例的模板不需要)────────────────────────
ALTER TABLE public.payment_term_templates
    ADD COLUMN currency text REFERENCES public.currencies (code);

COMMENT ON COLUMN public.payment_term_templates.currency IS
    '本模板【定额腿】的币种(FIN-29)。可空:只有比例的模板不需要币种,百分比对任何币种都成立。一旦模板里出现定额腿,这一列必须有值(守卫 guard_template_fixed_needs_currency 强制),而 apply_payment_term_template 只接受币种与之相同的采购单 —— 付款条款是谈定的承诺,不按牌价折算。';

-- ── 2. 跨行不变量:有定额腿 ⇒ 头上必须有币种 ──────────────────────────────
-- CHECK 约束看不见另一张表(也不许子查询),所以这条只能由触发器执行。
-- 两侧都要挂:插/改行时看头,改头(清空币种)时看行 —— 只挡一侧的守卫等于没挡。
CREATE OR REPLACE FUNCTION public.guard_template_fixed_needs_currency()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_ccy  text;
    v_name text;
    v_tid  uuid;
BEGIN
    IF TG_TABLE_NAME = 'payment_term_template_lines' THEN
        IF NEW.fixed_amount_ccy IS NULL THEN
            RETURN NEW;                      -- 比例腿,与币种无关
        END IF;
        v_tid := NEW.template_id;
    ELSE
        -- 模板头:只在【清空/改动币种】时检查,且只有存在定额腿才拦
        IF NEW.currency IS NOT NULL THEN
            RETURN NEW;
        END IF;
        v_tid := NEW.id;
        IF NOT EXISTS (SELECT 1 FROM payment_term_template_lines l
                        WHERE l.template_id = v_tid AND l.fixed_amount_ccy IS NOT NULL) THEN
            RETURN NEW;
        END IF;
    END IF;

    SELECT t.currency, t.name INTO v_ccy, v_name
    FROM payment_term_templates t WHERE t.id = v_tid;
    IF v_ccy IS NULL THEN
        RAISE EXCEPTION 'TEMPLATE_CURRENCY_REQUIRED|%', COALESCE(v_name, v_tid::text);
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_ptt_lines_fixed_needs_currency
    BEFORE INSERT OR UPDATE ON public.payment_term_template_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_template_fixed_needs_currency();

CREATE TRIGGER trg_ptt_fixed_needs_currency
    BEFORE UPDATE ON public.payment_term_templates
    FOR EACH ROW EXECUTE FUNCTION public.guard_template_fixed_needs_currency();

-- 【授权不动】payment_term_templates 是【表级】SELECT 授权(不是列清单),
-- 而表级授权【会自动延伸到新加的列】—— AGENTS.md 里那条"加列必改授权"针对的是
-- 被遮蔽表的列清单授权,这张表不在其列(它也没有 _masked 视图,因为它没有敏感列)。
-- 在这里顺手改成列清单授权会做两件坏事:悄悄改了权限形状,以及把这张表拖进
-- gate 的 colgrant 判据(每列要么授权要么在遮蔽视图里),而它根本没有遮蔽视图。

-- ── 3. 套用时把关:未声明即拒,币种不同即拒(不换算)────────────────────────
CREATE OR REPLACE FUNCTION public.apply_payment_term_template(p_purchase_order_id uuid, p_template_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po    record;
    v_tpl   record;
    v_count integer := 0;
    v_fixed integer := 0;   -- FIN-29:本模板有几条定额腿
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT id, code, order_date, status, currency INTO v_po
    FROM purchase_orders WHERE id = p_purchase_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    SELECT id, name, currency INTO v_tpl
    FROM payment_term_templates
    WHERE id = p_template_id AND deleted_at IS NULL AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TEMPLATE_NOT_FOUND|%', COALESCE(p_template_id::text, '?');
    END IF;

    -- ── FIN-29:定额腿的币种必须与本单相同,否则点名拒 ──────────────────────
    -- 【全部校验都在 DELETE 之前】拒绝必须是真的什么都没做:这个函数的语义是
    -- "替换整份计划",若先删后拒,靠的就只是事务回滚。把判断提到前面,
    -- 于是"被拒时原计划一行未动"是【结构上】成立的,不是靠回滚兜的。
    SELECT count(*) INTO v_fixed
    FROM payment_term_template_lines l
    WHERE l.template_id = p_template_id AND l.fixed_amount_ccy IS NOT NULL;

    IF v_fixed > 0 THEN
        IF v_tpl.currency IS NULL THEN
            -- 守卫(guard_template_fixed_needs_currency)之前建出来的行。不猜、不照抄:
            -- 照抄等于替双方认下一个没人谈过的币种(同 FIN-26 / FIN-27 的规矩)。
            RAISE EXCEPTION 'TEMPLATE_CURRENCY_UNDECLARED|%', v_tpl.name;
        END IF;
        IF v_tpl.currency <> v_po.currency THEN
            -- 【不换算】付款条款是谈定的承诺,不是算出来的量。按牌价折过去,
            -- 记下的就不再是双方谈的那个数。
            RAISE EXCEPTION 'TEMPLATE_CURRENCY_MISMATCH|%|%|%',
                v_tpl.name, v_tpl.currency, v_po.currency;
        END IF;
    END IF;

    -- 【替换】而不是追加:套模板的语义是"这张 PO 的计划就是模板说的那样"
    DELETE FROM purchase_order_payment_terms WHERE purchase_order_id = p_purchase_order_id;

    INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                              fixed_amount_ccy, trigger_event, due_date, notes)
    SELECT p_purchase_order_id, l.seq, l.label, l.percentage, l.fixed_amount_ccy, l.trigger_event,
           -- 模板存的是相对下单日的天数偏移(模板不可能知道具体日期)
           CASE WHEN l.trigger_event = 'fixed_date'
                THEN v_po.order_date + COALESCE(l.days_offset, 0)
                ELSE NULL END,
           l.notes
    FROM payment_term_template_lines l
    WHERE l.template_id = p_template_id
    ORDER BY l.seq;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RETURN jsonb_build_object('purchase_order_id', p_purchase_order_id, 'term_count', v_count,
                              'currency', v_po.currency, 'fixed_leg_count', v_fixed);
END;
$function$
;

COMMIT;