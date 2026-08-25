-- ════════════════════════════════════════════════════════════════════════════
-- GST-3:注册开关有了一扇门 —— 以及它两个方向各自的闸
--
-- 【为什么这一刀存在】GST-1 建了机器,GST-2 接了单据,而两刀的成果
-- **从来没有被一个人碰到过** —— 因为 `finance_settings.gst_registered`
-- 在 app 里【没有任何写入路径】,只由 SQL 翻。手走清单 §17 整节因此
-- 100% 走不了,而这件事不是任何一道检查发现的,是 Tim 发现的。
--
-- 【与审批开关的区别 —— 写在这里,免得下一个人把这次的修法照搬过去】
-- 审批开关【故意】没有门,而那个决定是对的:打开审批要三个策略值同时到位,
-- 一个孤零零的按钮按下去只会被拒,那是多一次失败而不是多一个功能。
-- **gst_registered 没有那样的同伴**:税率史已经播好、税码字典已经在册、
-- 登记号是一段自由文本。它是一个【自足的】开关,所以它得到一个控件 ——
-- 而审批开关【仍然不该】按这个样子去修。两者的形状看起来一样,理由不一样。
--
-- ★【打开的那一侧:登记号是硬前置】★
--   IRAS 要求税务发票上印 GST 登记号。实测:发票 PDF 里那一行是
--   `{gstRegistrationNo ? ... : null}` —— 号码为空时那一行【整条消失】,
--   而不是留一个空位或者拒绝出票。也就是说,今天若把开关打开而登记号留空,
--   系统会开出一张【带 9% 税、却没有登记号】的发票并寄给客户。
--   把这一条挡在【开关】这一步,是因为这是它最便宜、也最早的落点:
--   登记号是一段自由文本,打开的那一刻填它毫无代价;
--   而挡在出票那一步,是在最忙的时刻挡人,并且在此之前已经允许了一段
--   "已注册但没有号"的窗口。
--
-- ★【关闭的那一侧:它会搁死东西,而这一半是实测出来的】★
--   在一次【回滚掉的】探针里量到:今天关开关【完全没有闸】,而关掉之后
--   一张带税码的分录【再也冲销不了】(GST_NOT_REGISTERED|TX)。
--   **这一条搁死是 GST-2 今天早上自己引入的**:那一刀让冲销把 tax_code
--   一起翻过去(不翻的话,一笔已冲销的进货会永远留在 box5)。那个修复是对的,
--   而它的副作用就是:冲销从此依赖开关。
--   【两个方向的拒绝写成两条,理由不同,不合并】
--     · 带税码的【费用单】—— 机械事实:关掉之后它们冲销不了;
--     · 在册的【带税发票】—— 判断:它们冲销得了(税腿不带税码),
--       但留下的账面状态自相矛盾 —— 账上报着某一季的供应,而公司声称
--       那一季没有注册。把两个理由合成一句,会让机械的那一半被判断的那一半稀释。
--
-- 【闸放在数据库上,不是放在 server action 上】开关今天就是由 SQL 翻的,
-- 而 module.finance.edit 经 RLS 直接授予 UPDATE —— 一个只住在 action 里的闸,
-- 恰好挡不住【会用它的那批人】。与 trg_approvals_switch 同一个落点、同一个理由。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.guard_gst_switch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n      integer;
    v_codes  text;
BEGIN
    -- ── 开:登记号必须先在册 ────────────────────────────────────────────────
    -- 【为什么是 btrim + NULLIF,不是 IS NOT NULL】一段空白字符串在数据库里
    -- 是"有值"的,而在发票上它与 NULL 一样什么都不印。判据要与【印出来的结果】
    -- 一致,不是与列的可空性一致。
    IF NEW.gst_registered AND NOT OLD.gst_registered THEN
        IF NULLIF(btrim(COALESCE(NEW.gst_registration_no, '')), '') IS NULL THEN
            RAISE EXCEPTION 'GST_REGISTRATION_NO_REQUIRED';
        END IF;
    END IF;

    -- ── 关:两条拒绝,两个【不同】的理由 ────────────────────────────────────
    IF OLD.gst_registered AND NOT NEW.gst_registered THEN

        -- 【① 机械】带税码的费用单:关掉之后它们【冲销不了】。
        -- 判据取自那件真正会坏的事 —— 分录行上带着税码、分录还没有被冲销。
        -- reverse_expense 会把这张分录整个翻边,而翻边【会把 tax_code 一起抄过去】
        -- (GST-2 修的那一条);未注册时 post_journal_entry 拒收带税码的行,
        -- 于是那一笔永远冲不掉。
        SELECT count(*), string_agg(e.code, ', ' ORDER BY e.code)
          INTO v_n, v_codes
          FROM expenses e
          JOIN journal_entries je ON je.id = e.journal_entry_id
         WHERE e.tax_code IS NOT NULL
           AND e.status = 'posted'
           AND je.status = 'posted'
           AND EXISTS (SELECT 1 FROM journal_lines jl
                        WHERE jl.entry_id = je.id AND jl.tax_code IS NOT NULL);
        IF COALESCE(v_n, 0) > 0 THEN
            RAISE EXCEPTION 'GST_CANNOT_DISABLE_WITH_CODED_EXPENSES|%|%', v_n, v_codes
              USING HINT = '先把这些费用单冲销掉(冲销要在开关【还开着】的时候做),再关开关';
        END IF;

        -- 【② 判断】在册的带税发票:它们【冲销得了】(税腿不带税码),
        -- 但留下的状态自相矛盾 —— F5 报着那一季的供应额,而公司声称未注册。
        -- 这一条是判断,不是机械事实,所以它另起一个码、另说一句话。
        SELECT count(*), string_agg(DISTINCT i.code, ', ')
          INTO v_n, v_codes
          FROM invoices i
         WHERE i.status <> 'void'
           AND EXISTS (SELECT 1 FROM invoice_lines il
                        WHERE il.invoice_id = i.id AND il.tax_code IS NOT NULL);
        IF COALESCE(v_n, 0) > 0 THEN
            RAISE EXCEPTION 'GST_CANNOT_DISABLE_WITH_TAXED_INVOICES|%|%', v_n, v_codes
              USING HINT = '这些发票作废之后才谈得上"未注册" —— 否则账上报着供应额,而公司说那一季没注册';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_gst_switch() IS
    'GST-3:注册开关两个方向的闸。开 → 登记号必须在册(IRAS 要求税务发票印它,而发票 PDF 在号码为空时【整行消失】,不是拒绝出票)。关 → 两条拒绝、两个不同的理由:带税码的费用单关掉之后【冲销不了】(机械事实,GST-2 让冲销抄 tax_code 之后成立),在册的带税发票冲销得了但会留下"账上报着供应、公司说未注册"的矛盾状态(判断)。闸在数据库上而不是在 server action 上,理由与 trg_approvals_switch 相同:开关由 SQL 翻,而 module.finance.edit 经 RLS 直接授予 UPDATE。';

CREATE TRIGGER trg_gst_switch
    BEFORE UPDATE OF gst_registered, gst_registration_no ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION public.guard_gst_switch();

-- ── 顺带:把那个【死掉的】标量列标出来 ──────────────────────────────────────
-- GST-2 之后没有任何东西再读 gst_rate_pct(db/ 与 app/ 各 0 处)。
-- 它正是 GST-1 点名为"原始错误"的那个标量。**不删它是刻意的**(删它要动
-- 表镜像、类型、以及一圈 fixture,而这一刀只有一个目的);但一个【看起来像
-- 设置、实际什么都不做】的列,正是下一个人"把 GST 税率设成 9%"然后
-- 什么都没发生的地方。所以给它一句话。
COMMENT ON COLUMN public.finance_settings.gst_rate_pct IS
    'GST-2 起【已死】,GST-3 标注:**没有任何代码再读这一列**(db/ 与 app/ 各 0 处引用)。税率不再是一个标量 —— 它按生效期间挂在 tax_rates 上,由 tax_rate_for(code, date) 按【单据自己那一天】解析,因为一张 2022 年的发票永远是 7%,而一个标量表达不了这件事(那正是 GST-1 点名的原始错误)。**改这一列不会改变任何一张单据的税。** 留着它而不 DROP,是因为删它要动表镜像、生成类型与一圈 fixture,而那属于另一刀;这句注释是替代品,不是借口。';

COMMIT;
