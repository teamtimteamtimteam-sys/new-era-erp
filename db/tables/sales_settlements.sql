-- db/tables/sales_settlements.sql
-- SETTLE-1:一次销售最终结算的**记录** —— 它记下决定,**它不过账**。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【这一行【能】做什么、【不能】做什么 —— 免得"结算上线了"被读成"结算会过账"】★★
--   **能**:记下这一次结算**用了谁的化验、按哪种重量基准、依据哪一份冻结的条款**,
--         并把金额与逐项拆解算出来存下。
--   **不能**:**它一分钱都不进总账。** 没有暂定价发票、没有最终结算单据、
--         没有差额分录。
--   两个各自独立的理由:
--     ① 会计政策 **5.7 自己标着 NOT BUILT** —— 差额的科目已裁定(计入原收入科目),
--        而**没有过账路径**;在它之前落一条过账路,就是越过那个标记。
--     ② PRICE-1 **声明过它的断点**(停在规格 §7 第 2 步之后),
--        两阶段开票还不存在 —— 而**没有开票,就没有东西可以喂给一条过账路**。
--
-- ★★【为什么"哪一份化验说了算"必须【记】,不能【推】】★★
--   诱惑是从 `assay_results.applied_at` 推:那一份被 apply 过,那就是它。
--   **那是错的,而且是本仓库已经点名过的那种错**:`applied_at` 说的是
--   **"这份化验被应用到批次的成分上"** —— 那是一个**成分事实**,
--   不是一次**结算决定**。拿前者冒充后者,正是 F6 警告的那种 supersession 滥用,
--   而 F6 明说那会**销毁我们自己的数**。所以这里有一列 assay_result_id,
--   它是**被写下来的选择**。
--
-- ★【与 F6 的边界,写在这里免得两段读起来互相矛盾】★
--   F6 警告的是:拿 supersession 去表示**另一方的**结果(把对手方的化验
--   记成"我们复验了")。`result_party` 轴(PROC-6 建的)让那件事**不再必要**。
--   本表的 superseded_by 纠正的是**我们自己的那一句陈述**(算错了、选错了结果),
--   **它不夹带别人的结果** —— 两者主语不同,不冲突。
--
-- 【不可改】写下来之后就是一次**要过钱的陈述**;就地改它会毁掉"当初要的是什么"
--   这个记录。改正的办法是**再写一行并把旧的标成被取代** —— 与
--   guard_pricing_commitment_immutable 同一条先例(全库已有 27 道同族守卫)。
--
-- NOTE: introduced by db/migrations/2026-08-30-settle1-the-settlement-basis.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.sales_settlements (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 三样都记,理由见抬头:条款在销售单上、金属与水分在产出批次的化验上
    sales_order_id   uuid NOT NULL REFERENCES public.sales_orders (id) ON DELETE RESTRICT,
    output_batch_id  uuid NOT NULL REFERENCES public.output_batches (id) ON DELETE RESTRICT,
    -- ★ 被写下来的那个选择 ★
    assay_result_id  uuid NOT NULL REFERENCES public.assay_results (id) ON DELETE RESTRICT,

    -- ── 用了什么(抄下来的值,不是回查得到的指针)─────────────────────────
    settling_party_used  text NOT NULL
        CHECK (settling_party_used IN ('ours', 'counterparty', 'umpire')),
    weight_basis_used    text NOT NULL
        CHECK (weight_basis_used IN ('as_received', 'dry')),
    gross_weight_kg      numeric NOT NULL CHECK (gross_weight_kg > 0),
    -- 只在需要换算时才有值;换算需要它而它为空时,结算按名拒
    moisture_pct         numeric CHECK (moisture_pct IS NULL OR (moisture_pct >= 0 AND moisture_pct < 100)),
    settlement_weight_kg numeric NOT NULL CHECK (settlement_weight_kg > 0),

    -- ── 算出来的钱 ──────────────────────────────────────────────────────
    metal_value_usd      numeric NOT NULL,
    refining_charge_usd  numeric NOT NULL CHECK (refining_charge_usd >= 0),
    penalty_usd          numeric NOT NULL CHECK (penalty_usd >= 0),
    amount_usd           numeric NOT NULL,
    -- 逐项拆解:每种金属的含量/应付量/单价/金额,以及每一条惩罚是怎么来的。
    -- 【它让这个金额可以被【重导出】,而不是被相信】—— 与 PRICE-1 的 legs 同一条。
    breakdown            jsonb NOT NULL,
    -- 算它时依据的那一份【冻结的条款副本】,原样存下
    terms_snapshot       jsonb NOT NULL,

    -- 改正 = 新写一行 + 把旧的标成被取代(见抬头与 F6 的边界)
    superseded_by        uuid REFERENCES public.sales_settlements (id),

    computed_at      timestamptz NOT NULL DEFAULT now(),
    computed_by      uuid DEFAULT auth.uid(),
    CONSTRAINT sales_settlements_breakdown_is_object CHECK (jsonb_typeof(breakdown) = 'object'),
    CONSTRAINT sales_settlements_terms_is_object     CHECK (jsonb_typeof(terms_snapshot) = 'object'),
    -- 水分要么没有,要么与结算重量自洽 —— 见 sale_settlement_compute
    CONSTRAINT sales_settlements_no_self_supersede   CHECK (superseded_by IS NULL OR superseded_by <> id)
);

CREATE INDEX idx_sales_settlements_order  ON public.sales_settlements (sales_order_id);
CREATE INDEX idx_sales_settlements_batch  ON public.sales_settlements (output_batch_id);
CREATE INDEX idx_sales_settlements_assay  ON public.sales_settlements (assay_result_id);
-- 一张销售单 + 一个产出批次,**只有一行没有被取代的结算**
CREATE UNIQUE INDEX sales_settlements_one_live_per_order_batch
    ON public.sales_settlements (sales_order_id, output_batch_id)
    WHERE superseded_by IS NULL;

CREATE TRIGGER trg_sales_settlements_immutable
    BEFORE UPDATE OR DELETE ON public.sales_settlements
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_settlement_immutable();

ALTER TABLE public.sales_settlements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sales settlements select by customer permission"
    ON public.sales_settlements AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.customers.view'::text));
-- 【没有 INSERT/UPDATE 策略,而那是刻意的】写入只走 record_sale_settlement:
-- 检查与写入必须在同一笔事务里,否则分两步之间那道缝足够让一份不合口径的
-- 结算先被写下来(与 contract_document_terms 同一条理由)。

COMMENT ON TABLE public.sales_settlements IS
    'SETTLE-1:一次销售最终结算的**记录** —— **它记下决定,它不过账**。★**能/不能**★:能记下这次结算**用了谁的化验、按哪种重量基准、依据哪一份冻结条款**,并存下金额与逐项拆解;**不能**——**一分钱都不进总账**,没有暂定价发票、没有结算单据、没有差额分录。两个独立的理由:① 会计政策 **5.7 自己标着 NOT BUILT**(差额科目已裁定、过账路径没有),在它之前落过账路就是越过那个标记;② PRICE-1 **声明过断点**,两阶段开票还不存在,**没有开票就没有东西喂给过账路**。★★**为什么"哪一份化验说了算"必须记、不能推**★★:诱惑是从 assay_results.applied_at 推,而 **applied_at 说的是「这份化验被应用到批次成分上」——那是一个【成分事实】,不是一次【结算决定】**;拿前者冒充后者正是 F6 警告的 supersession 滥用,F6 明说那会**销毁我们自己的数**。★**与 F6 的边界**★:F6 警告的是拿 supersession 表示**另一方的**结果,而 result_party 轴让那件事不再必要;本表的 superseded_by 纠正的是**我们自己的那一句陈述**,**不夹带别人的结果** —— 主语不同,不冲突。★**不可改**★:写下来就是一次要过钱的陈述,就地改会毁掉「当初要的是什么」;改正 = 再写一行并把旧的标成被取代(全库已有 27 道同族守卫)。';
