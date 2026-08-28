-- db/migrations/2026-08-28-glexport1-general-ledger-export-and-the-monthly-pack.sql
-- ════════════════════════════════════════════════════════════════════════════
-- GLEXPORT-1:总账/日记账导出 + 月度管理报表包。**两件事合成一刀是刻意的** ——
-- 它们读的是同一本账,而报表包里必须装着导出产出的那些凭证明细;
-- 分开建就是把同一批数字推导两遍。
--
-- ★【这一刀里唯一一条【真】勾稽:控制科目 ↔ 明细账】★
--   `pnl_statement` 与 `balance_sheet` **都读 journal_activity_lines**,只差两个
--   开关。所以"损益对资产负债"是【一份推导的两个开关】,不是两份推导 ——
--   拿它当勾稽正是 OPS-17 抓到的那个病,而 AGENTS.md 自己那张表也已经把
--   `balance_sheet.balanced` 标成【结构性恒真】。
--   真正能分开的两边是:**总账 vs 单据**(1100/2000 对 ar/ap_aging_asof)。
--   见 db/functions/gl_control_reconciliation.sql 的文件头,含实测数字。
--
-- ★【存下来的包意味着一件事:产出时那个月已经关账】★
--   开放月份看得到实时预览、导得出 CSV,但【不落库】。理由(仓库为"什么时候该冻"
--   裁过三次,三次的触发点都是有东西离开了这栋楼)写在 management_packs 的表注释里,
--   并由表上的 CHECK 钉死,不是靠一个标签。
--
-- NOTE: 本文件是变更记录;安装路径完全走镜像。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;


-- db/tables/management_packs.sql
-- GLEXPORT-1:**冻下来的月度管理报表包。**
--
-- ★★【一份存下来的包意味着一件事,而这句话就是本表存在的全部理由】★★
--
--     **它被产出的那一刻,那个月已经关账了。**
--
--   所以本表【不存】开放月份的包。要看当月,屏幕上有实时预览、也导得出 CSV,
--   两者都盖着"本月尚未关账"的戳 —— 但它们【不落库】。
--
-- ★【为什么"冻结但注明是临时的"是两个念头穿一件衣服】★
--   仓库已经为"什么时候该冻"裁过三次,而三次的触发点是同一件事 ——
--   **有东西离开了这栋楼**,不是有人按了「计算」:
--     · gst_return_boxes  —— 冻在【申报】那一刻(草稿冻不下来);
--     · customer_statements —— 冻在【签发】那一刻(寄给客户了);
--     · bank_reconciliations —— 冻的是一次【发生过的对账事件】。
--   照这三条,一个开放月份的包还没有承诺任何事:它是一次计算,不是一次交付。
--   而"一份永久、不可改、且人人都知道当时是错的记录",是一样不值得造出来的东西。
--   于是 locked_before 在这里有了真活干,不再只是一个标签
--   (CHECK management_packs_month_was_locked 把它钉死在表上)。
--
-- ★【重出一份 = 新的一行 + 旧行 superseded + 必填理由】★
--   与 customer_statements / bank_reconciliations 逐字同一条:更正是一个
--   新事件,不是一次编辑。已关账的月份【仍然可能】重出一份(比如重开期间补了
--   一笔再关上),所以这条路必须留着,而它必须留下痕迹。
--
-- 【payload 是整包 jsonb,不是拆成几十张表】包的内容是【那一刻算出来的那些数】,
--   它的形状会随报表演进而变;拆成列意味着每次报表加一行就要改表结构,
--   而旧包还得按旧形状读。gst_return_boxes 拆了行是因为它有【固定的九格】;
--   这里没有固定的格。同一条理由,相反的结论。
--
-- 写入只走 freeze_management_pack(SECURITY DEFINER);这里只开 SELECT。
--
-- NOTE: introduced by db/migrations/2026-08-28-glexport1-general-ledger-export-and-the-monthly-pack.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.management_packs (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                        text NOT NULL UNIQUE,      -- 'PACK-2026-07';重出为 'PACK-2026-07-2'
    period_month                date NOT NULL,             -- 当月 1 号
    period_start                date NOT NULL,
    period_end                  date NOT NULL,
    -- ★ 证据,不是标签:产出那一刻的 locked_before。
    --   CHECK 要求它【严格大于】期末 —— 也就是"那个月的每一天都已经不能再过账"。
    locked_before_at_production date NOT NULL,
    base_currency               text NOT NULL REFERENCES public.currencies (code),
    -- 冻下来的整包(management_pack_data 的返回值,原样)。
    payload                     jsonb NOT NULL,
    notes                       text,
    produced_at                 timestamptz NOT NULL DEFAULT now(),
    produced_by                 uuid DEFAULT auth.uid(),
    superseded_at               timestamptz,
    superseded_by               uuid REFERENCES public.management_packs (id),
    superseded_reason           text,
    CONSTRAINT management_packs_month_is_first
        CHECK (period_month = date_trunc('month', period_month)::date),
    CONSTRAINT management_packs_window CHECK (period_end >= period_start),
    -- ★【本表的核心不变量】★ 存下来的包,那个月当时必定已经关账。
    CONSTRAINT management_packs_month_was_locked
        CHECK (locked_before_at_production > period_end),
    -- 【被取代的行必须说出为什么】—— 一次没有理由的重出,日后无从交代。
    CONSTRAINT management_packs_superseded_shape CHECK (
        (superseded_at IS NULL     AND superseded_reason IS NULL)
     OR (superseded_at IS NOT NULL AND superseded_reason IS NOT NULL))
);

-- 一个月只有一份【在册】的包;被取代的旧行不占这个位置。
CREATE UNIQUE INDEX idx_management_packs_live_month
    ON public.management_packs (period_month) WHERE superseded_at IS NULL;
CREATE INDEX idx_management_packs_month ON public.management_packs (period_month);

-- 只可追加:一个包是一件产出过的东西。放行的【只有】那一次 superseded 转移,
-- 其余列逐列锁死 —— 与 payments / collection_chases 的守卫同形。
CREATE OR REPLACE FUNCTION public.guard_management_pack_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'PACK_IMMUTABLE|%', OLD.code;
    END IF;
    IF NEW.id          IS DISTINCT FROM OLD.id
       OR NEW.code        IS DISTINCT FROM OLD.code
       OR NEW.period_month IS DISTINCT FROM OLD.period_month
       OR NEW.period_start IS DISTINCT FROM OLD.period_start
       OR NEW.period_end   IS DISTINCT FROM OLD.period_end
       OR NEW.locked_before_at_production IS DISTINCT FROM OLD.locked_before_at_production
       OR NEW.base_currency IS DISTINCT FROM OLD.base_currency
       OR NEW.payload     IS DISTINCT FROM OLD.payload
       OR NEW.notes       IS DISTINCT FROM OLD.notes
       OR NEW.produced_at IS DISTINCT FROM OLD.produced_at
       OR NEW.produced_by IS DISTINCT FROM OLD.produced_by
    THEN
        RAISE EXCEPTION 'PACK_IMMUTABLE|%', OLD.code;
    END IF;
    IF NOT (OLD.superseded_at IS NULL AND NEW.superseded_at IS NOT NULL) THEN
        RAISE EXCEPTION 'PACK_IMMUTABLE|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_management_packs_immutable
    BEFORE UPDATE OR DELETE ON public.management_packs
    FOR EACH ROW EXECUTE FUNCTION public.guard_management_pack_mutation();

ALTER TABLE public.management_packs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "management_packs select by permission"
    ON public.management_packs
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

COMMENT ON TABLE public.management_packs IS
    'GLEXPORT-1:冻下来的月度管理报表包。**一份存下来的包意味着一件事:它被产出的那一刻,那个月已经关账了**(CHECK management_packs_month_was_locked)。开放月份看得到实时预览、导得出 CSV,但【不落库】—— 仓库为"什么时候该冻"裁过三次,三次的触发点都是「有东西离开了这栋楼」,而不是有人按了计算。重出一份 = 新行 + 旧行 superseded + 必填理由。';

COMMENT ON COLUMN public.management_packs.locked_before_at_production IS
    '产出那一刻 finance_settings.locked_before 的值。**它是证据,不是标签** —— 表上的 CHECK 要求它严格大于 period_end,于是"这份包产出时那个月已经关账"是一件由数据库保证的事,不是一句写在别处的说明。';


-- db/functions/gl_control_reconciliation.sql
-- GLEXPORT-1:控制科目 ↔ 明细账的勾稽(AR = 1100,AP = 2000)。
--
-- ★【为什么这一条才是管理报表包里【唯一】一条真勾稽】★
--   `pnl_statement` 与 `balance_sheet` **都读 journal_activity_lines**,只差两个开关
--   (期间/累计、剔除/包含年结)。所以"损益对资产负债"是【一份推导的两个开关】,
--   不是两份推导 —— 拿它当勾稽,正是 OPS-17 抓到的那个病(两边一起错,旗子永远绿)。
--   AGENTS.md 自己那张表也已经把 `balance_sheet.balanced` 标成【结构性恒真】。
--
--   **这里的两边来自两套完全不同的表:**
--     · 账面侧 = 总账(journal_entries / journal_lines / accounts);
--     · 明细侧 = 单据(sales_records / invoices / inbound_batches / expenses /
--                payment_allocations / credit_notes),经 ar_aging_asof / ap_aging_asof。
--   它们【能够】分开,而且实测就是分开的 —— 见下面那段实测。
--
-- ★★【`unexplained_base` 不许被算术逼成零 —— 这是本函数最要紧的一行设计】★★
--   最容易写错的版本是给账面侧留一个"其他"兜底桶:那样各分项之和【恒等于】
--   账面余额,于是未解释差额永远是 0,而一个永远为 0 的判词是装饰,不是检查。
--   **所以分类是【穷举式声明】的,没有兜底:** 只有 origination / settlement /
--   revaluation 三类被扣掉,任何【没有被分类的来源】(manual、year_close、
--   writeoff、以及将来新增的任何 source_type)都会原样留在 unexplained 里。
--   于是它【动得开】,而且动的方向正是要紧的那个:
--   **一笔手工分录打进控制科目 —— 这恰恰是现实中把明细账与总账弄散的头号原因 ——
--   会让它当场不为零。** db/fixtures/143 的 D 臂就注入这一笔。
--
-- 【实测(2026-08-28),三个分项把差额【逐分钱】解释干净,余额 0.00】
--   AR:账面 1100 = 43,002.12,明细 = 57,443.00,差 14,440.88
--       = 起单差异 20,247.13 + 结算差异 250.00 − 重估 6,056.25
--       (起单差异里 20,350.00 是 OUT-2026-0007 —— 它在明细账里,而总账里
--        **一张分录都没有**;那是 docs/known-wrong-until-cutover.md 第 13 行
--        记着的 cutover 前测试数据。结算差异 250.00 是 RCPT-2026-0001 挂账未核销。)
--   AP:账面 2000 = 371,950.04,明细 = 429,537.62,差 57,587.58
--       = 起单差异 62,175.68 + 结算差异 0.96 − 重估 4,589.06
--       (起单差异主要是五张 cutover 前的进料批次 —— IN-2026-0001/0002/0003/0011/0012
--        在明细账里有价,而总账里没有【存活的】应付分录:0001 与 0003 的计价分录
--        被冲销后再没有按新价补过。)
--
-- 【符号约定,写出来因为它是最容易搞反的一处】
--   AR 是资产:账面余额 = Σ(借−贷);AP 是负债:账面余额 = Σ(贷−借)。
--   两侧统一成"正数 = 还欠着的钱",于是下面同一段算术两侧共用。

CREATE OR REPLACE FUNCTION public.gl_control_reconciliation(p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base      text;
    v_sides     jsonb := '[]'::jsonb;
    v_side      text;
    v_acct      text;
    v_orig_src  text[];
    v_settle_src text[];
    v_ledger    numeric;
    v_orig_led  numeric;
    v_settle_led numeric;
    v_reval_led numeric;
    v_sub       jsonb;
    v_sub_total numeric;
    v_sub_value numeric;
    v_sub_reduce numeric;
    v_diff      numeric;
    v_ov        numeric;
    v_sv        numeric;
    v_unexp     numeric;
BEGIN
    -- 【SECURITY DEFINER 必须自己问调用者是谁】一支不问的 definer 函数就是一条
    -- 绕过 RLS 的路;这个形状在本仓库上线过两次、两次都由闸抓住。
    PERFORM require_permission('module.finance.view');
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'AS_OF_REQUIRED';
    END IF;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    FOREACH v_side IN ARRAY ARRAY['ar', 'ap'] LOOP
        IF v_side = 'ar' THEN
            v_acct := '1100';
            -- 起单:销售与订单流发票把应收记上去。
            v_orig_src   := ARRAY['sale', 'invoice'];
            -- 结算:收款把它冲掉;贷项凭证也把它冲掉(「不用付了」,不是「付过了」)。
            v_settle_src := ARRAY['payment', 'credit_note'];
        ELSE
            v_acct := '2000';
            -- 起单:进料计价、费用单、运费单把应付记上去。
            v_orig_src   := ARRAY['purchase', 'expense', 'freight'];
            -- 结算:付款冲掉它;预付冲抵把 1300 挪过来抵掉它。
            v_settle_src := ARRAY['payment', 'prepayment'];
        END IF;

        -- ── 账面侧:一次权威取数,外加按来源的三类分项 ────────────────────
        -- 【经 journal_activity_lines,所以【不】按 status 过滤】冲销的做法是
        -- 原分录标 reversed + 过一张等额反向的 posted 分录;只留 posted 会丢原件
        -- 留冲销件,净额错成 −原件。这个病在本仓库现身过四次,其中一次
        -- (bank_reconciliation_status)在线上错了几个月,差 USD 1,585.00。
        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN l.debit - l.credit
                                 ELSE l.credit - l.debit END), 0)
          INTO v_ledger
          FROM journal_activity_lines(NULL, p_as_of, true) l
         WHERE l.account_code = v_acct;

        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN l.debit - l.credit
                                 ELSE l.credit - l.debit END), 0)
          INTO v_orig_led
          FROM journal_activity_lines(NULL, p_as_of, true) l
         WHERE l.account_code = v_acct AND l.source_type = ANY(v_orig_src);

        -- 结算取正:它是【把控制科目减下去】的那一侧。
        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN l.credit - l.debit
                                 ELSE l.debit - l.credit END), 0)
          INTO v_settle_led
          FROM journal_activity_lines(NULL, p_as_of, true) l
         WHERE l.account_code = v_acct AND l.source_type = ANY(v_settle_src);

        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN l.debit - l.credit
                                 ELSE l.credit - l.debit END), 0)
          INTO v_reval_led
          FROM journal_activity_lines(NULL, p_as_of, true) l
         WHERE l.account_code = v_acct AND l.source_type = 'revaluation';

        -- ── 明细侧:单据。**另一套表,这就是"两边能分开"的全部依据** ────────
        v_sub := CASE WHEN v_side = 'ar' THEN ar_aging_asof(p_as_of)
                                         ELSE ap_aging_asof(p_as_of) END;
        v_sub_total := (v_sub->>'total_open_base')::numeric;

        -- 单据面值与单据上被冲掉的部分,【从行里加出来】——
        -- 与 total_open_base 是两个数,而"行加起来等于那个数"本身就是一条断言
        -- (fixture 80 的形状)。两者不等时差额会落进 unexplained,不会被抹平。
        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN (r->>'amount_base')::numeric
                                 ELSE (r->>'doc_value_base')::numeric END), 0),
               COALESCE(SUM(CASE WHEN v_side = 'ar'
                                 THEN (r->>'settled_base')::numeric + COALESCE((r->>'credited_base')::numeric, 0)
                                 ELSE (r->>'settled_base')::numeric END), 0)
          INTO v_sub_value, v_sub_reduce
          FROM jsonb_array_elements(v_sub->'rows') r;

        -- ── 三个分项 ──────────────────────────────────────────────────────
        v_diff := round(v_sub_total - v_ledger, 2);
        --   起单差异:单据说欠了多少,总账认了多少。正 = 有单据没进总账。
        v_ov   := round(v_sub_value - v_orig_led, 2);
        --   结算差异:总账冲掉了多少,单据上被冲掉了多少。正 = 钱冲了总账没冲单据
        --   (挂账未核销的收付款正是这一种)。
        v_sv   := round(v_settle_led - v_sub_reduce, 2);
        --   ★【没有兜底桶】★ 只扣这三项;任何没有被分类的来源原样留在余额里。
        v_unexp := round(v_diff - (v_ov + v_sv - v_reval_led), 2);

        v_sides := v_sides || jsonb_build_object(
            'side',                     v_side,
            'control_account',          v_acct,
            'ledger_base',              round(v_ledger, 2),
            'subledger_base',           round(v_sub_total, 2),
            'difference_base',          v_diff,
            'origination_variance_base', v_ov,
            'settlement_variance_base',  v_sv,
            'revaluation_base',          round(v_reval_led, 2),
            'unexplained_base',          v_unexp,
            -- 【勾稽上不上,判据是【余额】,不是差额】差额不为零是正常的、
            -- 而且是有意义的(重估、挂账、cutover 前的单据都会让它不为零);
            -- 【余额】不为零才是一件没有人解释过的事。
            'reconciled',                (v_unexp = 0));
    END LOOP;

    RETURN jsonb_build_object(
        'as_of',         p_as_of,
        'base_currency', v_base,
        'sides',         v_sides);
END;
$function$;

COMMENT ON FUNCTION public.gl_control_reconciliation(date) IS
'GLEXPORT-1:控制科目(1100 / 2000)与它的明细账(ar/ap_aging_asof)的勾稽。
**这是管理报表包里唯一一条两边真正独立的勾稽** —— 账面侧读总账,明细侧读单据,
两套表。损益对资产负债【不是】:那两支都读 journal_activity_lines,只差两个开关。

差额被三个分项解释:起单差异、结算差异、重估。**剩下的是 unexplained_base,
而它【没有兜底桶】** —— 任何未分类来源(manual / year_close / writeoff / 将来新增的)
都会原样留在里面,所以它动得开。一笔打进控制科目的手工分录会让它当场不为零,
而那正是现实中把明细账与总账弄散的头号原因。
**未解释余额是一条发现,不是一个装饰。**';


-- db/functions/management_pack_data.sql
-- GLEXPORT-1:一个月的管理报表包 —— **它自己一个数都不算。**
--
-- ★【本函数的全部工作是【调用】,而那不是偷懒,是这一刀的要求】★
--   包里的每一个数字都已经有一支函数在算它,而屏幕上也已经印着同一个数。
--   在这里再算一遍 = 第二份实现,两份会在写下来那天一致、之后悄悄分开 ——
--   这个仓库为这个形状付过四次账(AGENTS.md 的预览规则)。
--   所以下面每一段都是一次调用,并在旁边写明【调的是谁】:
--     · 损益      → pnl_statement(start, end)
--     · 资产负债  → balance_sheet(end)
--     · 现金流量  → cash_flow_statement(start, end)
--     · 应收/应付账龄 → ar_aging_asof / ap_aging_asof
--     · 控制科目勾稽 → gl_control_reconciliation
--     · 月末外币就绪 → fx_month_end_readiness(视图)
--     · 银行对账     → bank_reconciliations(已冻结的那些行)
--     · 现金预测     → cash_forecasts(已冻结的那一份,不是现算)
--
-- ★【一份实现,两个调用方】★ 屏幕读它,冻结(freeze_management_pack)也读它。
--   于是"屏幕上看到的"与"冻下来的"不可能是两个数 —— 这正是 reprice_split /
--   preview_revalue_foreign_balances 立下的那个形状。
--
-- ★★【账龄的截止日可能【不是】月末,而这必须说出来】★★
--   ar/ap_aging_asof 对未来的截止日按名拒(AGING_AS_OF_FUTURE)。
--   于是【当月】的实时预览取不到月末账龄 —— 取到今天为止的。
--   本函数因此把 aging_as_of 单独返回,并在 caveats 里点名
--   `aging_capped_at_today`。**冻结的包不会遇到这一条**:只有已关账的月份
--   才冻得下来,而已关账的月份月末必在过去。
--
-- 【为什么 balance_sheet 用 end 而账龄用 LEAST(end, today)】资产负债表是纯总账
--   推导,对未来日期没有意见;账龄要读单据的"那一天是什么状态",而未来那一天
--   还没有发生。两者不同,所以两个日期,而不是把其中一个悄悄改成另一个。

CREATE OR REPLACE FUNCTION public.management_pack_data(p_period_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_start   date;
    v_end     date;
    v_aging   date;
    v_base    text;
    v_locked  date;
    v_is_locked boolean;
    v_pnl     jsonb; v_bs jsonb; v_cf jsonb;
    v_ar      jsonb; v_ap jsonb; v_recon jsonb;
    v_fx      jsonb; v_bank jsonb; v_forecast jsonb;
    v_split   jsonb;
    v_unexp   numeric;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'PACK_PERIOD_REQUIRED';
    END IF;
    v_start := date_trunc('month', p_period_month)::date;
    v_end   := (v_start + INTERVAL '1 month - 1 day')::date;
    -- 【封顶,而不是拒绝】实时预览要能看当月;拒绝会让当月完全看不见,
    -- 而那比"看到截至今天的账龄并被告知它被封顶了"坏。
    v_aging := LEAST(v_end, CURRENT_DATE);

    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT locked_before INTO v_locked FROM finance_settings;
    -- 【已关账 = 这个月的每一天都不能再过账】locked_before 是"早于它的都锁了",
    -- 所以判据是 locked_before > period_end,与 file_gst_return 逐字同源。
    v_is_locked := (v_locked IS NOT NULL AND v_locked > v_end);

    -- ── 三张报表:全部是调用 ────────────────────────────────────────────────
    v_pnl := pnl_statement(v_start, v_end);
    v_bs  := balance_sheet(v_end);
    v_cf  := cash_flow_statement(v_start, v_end);

    -- ── 账龄与控制科目勾稽 ──────────────────────────────────────────────────
    v_ar    := ar_aging_asof(v_aging);
    v_ap    := ap_aging_asof(v_aging);
    v_recon := gl_control_reconciliation(v_aging);

    -- ── 月末外币就绪:【读那张视图,不自己判】 ───────────────────────────────
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'currency', f.currency, 'has_mid', f.has_mid,
               'mid_rate', f.mid_rate, 'mid_rate_as_of', f.mid_rate_as_of,
               'revalued', f.revalued, 'blocks_close', f.blocks_close) ORDER BY f.currency), '[]'::jsonb)
      INTO v_fx
      FROM fx_month_end_readiness f
     WHERE f.month_end = v_end;

    -- ── 银行对账:这个月有没有对过 ─────────────────────────────────────────
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'account_code', bs.bank_account_code, 'statement_code', bs.code,
               'currency', br.currency, 'as_of', br.as_of,
               'bank_closing_balance', br.bank_closing_balance,
               'book_balance', br.book_balance, 'difference', br.difference,
               'reconciled_at', br.reconciled_at) ORDER BY bs.bank_account_code), '[]'::jsonb)
      INTO v_bank
      FROM bank_reconciliations br
      JOIN bank_statements bs ON bs.id = br.statement_id
     WHERE br.as_of BETWEEN v_start AND v_end
       AND br.superseded_at IS NULL;

    -- ── 现金预测:读【冻下来的那一份】,不现算 ──────────────────────────────
    -- 现算会让"这个包里的预测"与"当时那一份"是两个数,而 CASHFLOW-1 冻结它
    -- 的全部理由就是偏差要拿【过去那一份】比。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'code', cfz.code, 'week_start', cfz.week_start,
               'frozen_at', cfz.frozen_at) ORDER BY cfz.week_start), '[]'::jsonb)
      INTO v_forecast
      FROM cash_forecasts cfz
     WHERE cfz.week_start BETWEEN v_start AND v_end
       AND cfz.superseded_at IS NULL;

    -- ── ★【拆散在两个月的冲销对】★ ─────────────────────────────────────────
    -- 一张分录落在本月、而它的冲销件(或它冲销的那一张)落在【别的月】,
    -- 本月的数字就带着一条没有对手的腿。这【不是错】—— 跨期冲销完全合法,
    -- 年结时尤其常见 —— 但它是「这个月怎么看着不对」最可能的答案,
    -- 而对手件的日期只有一个 join 之遥,所以说出来比让人去猜便宜得多。
    -- 【实测:线上就有三对】JE-2027-0001/2/3(2027-09-05)由
    -- JE-2026-0058/59/60(2026-08-20)冲销 —— 于是 2026-08 带着三条没有原件的
    -- 冲销腿,合计对 2000 影响 −3,703.68,而全时段净额恰好是 0。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'entry_code', x.code, 'entry_date', x.entry_date,
               'counterpart_code', x.cp_code, 'counterpart_date', x.cp_date,
               'amount_base', x.amt) ORDER BY x.entry_date, x.code), '[]'::jsonb)
      INTO v_split
      FROM (
        -- 本月的原件,冲销件在别的月
        SELECT o.code, o.entry_date, r.code AS cp_code, r.entry_date AS cp_date,
               (SELECT COALESCE(SUM(jl.debit), 0) FROM journal_lines jl WHERE jl.entry_id = o.id) AS amt
          FROM journal_entries o JOIN journal_entries r ON r.id = o.reversed_by
         WHERE o.entry_date BETWEEN v_start AND v_end
           AND r.entry_date NOT BETWEEN v_start AND v_end
        UNION ALL
        -- 本月的冲销件,原件在别的月
        SELECT r.code, r.entry_date, o.code, o.entry_date,
               (SELECT COALESCE(SUM(jl.debit), 0) FROM journal_lines jl WHERE jl.entry_id = r.id)
          FROM journal_entries o JOIN journal_entries r ON r.id = o.reversed_by
         WHERE r.entry_date BETWEEN v_start AND v_end
           AND o.entry_date NOT BETWEEN v_start AND v_end
      ) x;

    SELECT COALESCE(SUM((s->>'unexplained_base')::numeric), 0) INTO v_unexp
      FROM jsonb_array_elements(v_recon->'sides') s;

    RETURN jsonb_build_object(
        'period_month',  v_start,
        'period_start',  v_start,
        'period_end',    v_end,
        'aging_as_of',   v_aging,
        'generated_on',  CURRENT_DATE,
        'base_currency', v_base,
        'locked_before', v_locked,
        'month_locked',  v_is_locked,
        'pnl',           v_pnl,
        'balance_sheet', v_bs,
        'cash_flow',     v_cf,
        'ar_aging',      v_ar,
        'ap_aging',      v_ap,
        'control_reconciliation', v_recon,
        'fx_month_end',  v_fx,
        'bank_reconciliations', v_bank,
        'cash_forecasts', v_forecast,
        'split_reversal_pairs', v_split,
        -- ★【这个包看不见什么 —— 逐条,而不是留给读的人猜】★
        -- 预测那一刀立的规矩:一份悄悄漏掉一整类东西的报表,是一个会被人当真
        -- 的数字。所以缺席是【具名的】,而且带着它自己的判据。
        'caveats', jsonb_build_object(
            'month_not_locked',        NOT v_is_locked,
            'aging_capped_at_today',   (v_aging < v_end),
            'fx_missing_mid',          EXISTS (SELECT 1 FROM jsonb_array_elements(v_fx) f
                                                WHERE (f->>'has_mid')::boolean IS NOT TRUE),
            'fx_not_revalued',         EXISTS (SELECT 1 FROM jsonb_array_elements(v_fx) f
                                                WHERE (f->>'revalued')::boolean IS NOT TRUE),
            'control_unexplained',     (v_unexp <> 0),
            'control_unexplained_base', v_unexp,
            'split_reversal_pairs_n',  jsonb_array_length(v_split),
            'no_bank_reconciliation',  (jsonb_array_length(v_bank) = 0),
            'no_cash_forecast',        (jsonb_array_length(v_forecast) = 0)));
END;
$function$;

COMMENT ON FUNCTION public.management_pack_data(date) IS
'GLEXPORT-1:一个月的管理报表包。**它一个数都不算** —— 每一段都是对已有那支
函数的调用(损益/资产负债/现金流量/两侧账龄/控制科目勾稽/月末外币就绪/银行对账/
冻结的现金预测),因为在这里再算一遍就是第二份实现。
【一份实现两个调用方】屏幕与 freeze_management_pack 读的是同一支,所以看到的与
冻下来的不可能是两个数。
【账龄截止日可能不是月末】ar/ap_aging_asof 对未来日期按名拒,所以当月预览封顶到
今天,并在 caveats 里点名 aging_capped_at_today;冻结的包遇不到这一条,因为只有
已关账的月份才冻得下来。';


-- db/functions/freeze_management_pack.sql
-- GLEXPORT-1:把一个【已关账】月份的管理报表包冻下来。
--
-- ★【它自己不算任何东西 —— payload 就是 management_pack_data 的返回值】★
--   一份实现,两个调用方(屏幕预览与本函数)。于是"屏幕上看到的"与"冻下来的"
--   **不可能**是两个数;在这里重算一遍就是第二份实现,而那正是本仓库付过四次账
--   的形状。
--
-- ★【只有关账的月份冻得下来,而这条拒绝是本刀的裁定】★
--   `PACK_MONTH_NOT_LOCKED`。理由整段写在 db/tables/management_packs.sql 的表注释里:
--   仓库为"什么时候该冻"裁过三次,三次的触发点都是**有东西离开了这栋楼**,
--   而不是有人按了「计算」。一个开放月份的包还没有承诺任何事。
--   判据 `locked_before > period_end` 与 file_gst_return 的 GST_PERIOD_NOT_LOCKED
--   逐字同源:那一期的每一天都已经不能再过账。
--
-- 【重出一份要说出理由】旧行落 superseded,新行是【另一份包】,不是同一份的 v2。

CREATE OR REPLACE FUNCTION public.freeze_management_pack(p_period_month date, p_notes text DEFAULT NULL::text, p_supersede_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_start   date;
    v_end     date;
    v_locked  date;
    v_base    text;
    v_prev    management_packs%ROWTYPE;
    v_reason  text;
    v_payload jsonb;
    v_seq     integer;
    v_code    text;
    v_id      uuid := gen_random_uuid();
BEGIN
    -- 【SECURITY DEFINER 必须自己问调用者是谁】一支不问的 definer 函数就是一条
    -- 绕过 RLS 的路;这个形状在本仓库上线过两次、两次都由闸抓住。
    -- 产出是一次写,所以要 edit;而 payload 来自只要 view 的那支函数。
    PERFORM require_permission('module.finance.edit');
    PERFORM require_permission('module.finance.view');

    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'PACK_PERIOD_REQUIRED';
    END IF;
    v_start := date_trunc('month', p_period_month)::date;
    v_end   := (v_start + INTERVAL '1 month - 1 day')::date;

    SELECT locked_before INTO v_locked FROM finance_settings;
    -- ★ 本刀的裁定,按名拒并把两个日期都说出来 —— 一条只说"不行"的拒绝
    --   会让人去猜是哪一天挡着。
    IF v_locked IS NULL OR v_locked <= v_end THEN
        RAISE EXCEPTION 'PACK_MONTH_NOT_LOCKED|%|%', to_char(v_start, 'YYYY-MM'),
            COALESCE(v_locked::text, '—')
          USING HINT = '只有已关账的月份才冻得下来 —— 开放月份看得到实时预览、也导得出 CSV,但那不是一份可以存档的包;先在月结那一步关账';
    END IF;

    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 已有在册的一份?那就要说出为什么再出一份。
    SELECT * INTO v_prev FROM management_packs
     WHERE period_month = v_start AND superseded_at IS NULL;
    IF FOUND THEN
        v_reason := NULLIF(btrim(COALESCE(p_supersede_reason, '')), '');
        IF v_reason IS NULL THEN
            RAISE EXCEPTION 'PACK_SUPERSEDE_REASON_REQUIRED|%', v_prev.code
              USING HINT = '这个月已经有一份在册的包 —— 再出一份要说明为什么(重开期间补记了什么?哪个数变了?)';
        END IF;
    END IF;

    -- 【payload 是调用来的,不是算来的】
    v_payload := management_pack_data(v_start);

    -- 编号:同一个月可以有多份(重出),第二份起带序号。
    -- 咨询锁串行化,与 EXP/JE/收付款/汇缴的取号手法一致。
    PERFORM pg_advisory_xact_lock(hashtext('mgmt_pack_' || to_char(v_start, 'YYYY-MM'))::bigint);
    SELECT COUNT(*) + 1 INTO v_seq FROM management_packs WHERE period_month = v_start;
    v_code := 'PACK-' || to_char(v_start, 'YYYY-MM') ||
              CASE WHEN v_seq > 1 THEN '-' || v_seq::text ELSE '' END;

    INSERT INTO management_packs (id, code, period_month, period_start, period_end,
                                  locked_before_at_production, base_currency, payload,
                                  notes, produced_by)
    VALUES (v_id, v_code, v_start, v_start, v_end,
            v_locked, v_base, v_payload, p_notes, auth.uid());

    -- 旧的那一份【在新的那一份写下来之后】才落 superseded,并指向它。
    IF v_prev.id IS NOT NULL THEN
        UPDATE management_packs
           SET superseded_at = now(), superseded_by = v_id, superseded_reason = v_reason
         WHERE id = v_prev.id;
    END IF;

    RETURN jsonb_build_object(
        'pack_id',      v_id,
        'code',         v_code,
        'period_month', v_start,
        'period_end',   v_end,
        'locked_before_at_production', v_locked,
        'superseded',   v_prev.code);
END;
$function$;

COMMENT ON FUNCTION public.freeze_management_pack(date, text, text) IS
'GLEXPORT-1:把一个【已关账】月份的管理报表包冻下来。payload 是
management_pack_data 的返回值原样 —— 一份实现两个调用方,屏幕与存档不可能是两个数。
**开放月份按名拒(PACK_MONTH_NOT_LOCKED)**,理由写在 management_packs 的表注释里:
仓库为"什么时候该冻"裁过三次,三次的触发点都是有东西离开了这栋楼。
重出一份 = 新行 + 旧行 superseded + 必填理由。';


COMMIT;
