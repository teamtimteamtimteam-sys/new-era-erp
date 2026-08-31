-- db/tables/purchase_order_line_retentions.sql
-- EQP-PAY-1:设备质保金(retention)。**一台机器一行,而"没有质保金"= 没有这一行。**
--
-- ★【为什么不塞进 purchase_order_payment_terms】★ 两个理由,任何一个都够:
--   ① 那张表【存不下"某事之后 N 个月"】。它只有 due_date(一个字面日期,而且
--      fixed_date 那一种【必须】有它)与 expected_date(一个明说了是估计的值)。
--      把算好的到期日写进 due_date,会让一个推导值长得和一条合同条款一模一样,
--      并在验收日改变的那一刻【悄悄地错】;
--   ② 那张表的抬头【自己声明】它不是账:"计划不是债权……也没有已付/未付状态列",
--      并且不参与任何结算。而质保金的放款确认(谁、何时、放了多少、扣了多少、
--      为什么)恰恰是一本账。把结算列螺到一张写着"我不做结算"的表上,是让它自相矛盾。
--
-- ★【为什么挂在【行】上而不是单上】★ 逐台。四台机器是四条行(EQP-1a-TAIL),
-- 各有各的资产卡与验收日。挂在表头上就说不出"这台有质保金、那台没有" ——
-- 而那是 Tim 强调了两次的要求。
--
-- ★【到期日不在这张表里】★ 它是【推导】的,活在 purchase_order_retention_status
-- 视图里:acceptance_date + retention_months。存一个字面量,等于在验收日期改变时
-- 悄悄地错(db/fixtures/177 的 C 臂断言这一条)。
--
-- NOTE: introduced by db/migrations/2026-09-01-eqppay1-b-equipment-milestones-and-retention.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.purchase_order_line_retentions (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 【挂在行上,不是挂在单上】—— 逐台。四台机器是四条行(EQP-1a-TAIL),
    -- 各有各的资产卡、各有各的验收日,于是各有各的质保期。挂在表头上就说不出
    -- "这台有、那台没有"这句话,而那正是 Tim 强调了两次的要求。
    purchase_order_line_id uuid NOT NULL UNIQUE
                           REFERENCES public.purchase_order_lines (id) ON DELETE CASCADE,
    -- ★【percentage 的下界是 > 0,这不是抄来的,是本条要求的实现】★
    -- 一行 0% 的质保金【存不进去】。所以"没有质保金"唯一的表达方式就是【没有这一行】——
    -- "0% 质保金"与"没有质保金"从此不可能长得一样,因为前者根本不存在。
    percentage             numeric CHECK (percentage IS NULL OR (percentage > 0 AND percentage <= 100)),
    fixed_amount_ccy       numeric CHECK (fixed_amount_ccy IS NULL OR fixed_amount_ccy > 0),
    CONSTRAINT po_line_retentions_pct_xor_fixed CHECK (num_nonnulls(percentage, fixed_amount_ccy) = 1),
    -- 默认 12 个月,逐台可改(Tim 裁定)。默认值在这里是【一个起点】,不是一条规则。
    retention_months       integer NOT NULL DEFAULT 12 CHECK (retention_months > 0),
    -- 锚事件。只能指向 can_anchor_retention 的那些(guard_retention_row 强制)。
    anchor_event           text NOT NULL DEFAULT 'acceptance_complete'
                           REFERENCES public.payment_trigger_events (code),
    notes                  text,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid DEFAULT auth.uid(),
    -- ── 放款确认(R6:到期【提示】,不自动付)────────────────────────────────
    -- released_at IS NULL = 还没有人确认过。到期只让它进入 awaiting_confirmation,
    -- 应付【不因为到期而成立】。
    released_at            timestamptz,
    released_by            uuid,
    released_amount_ccy    numeric CHECK (released_amount_ccy IS NULL OR released_amount_ccy >= 0),
    withheld_amount_ccy    numeric CHECK (withheld_amount_ccy IS NULL OR withheld_amount_ccy >= 0),
    withholding_reason     text,
    -- 放款是一件【整件事】:要么一个字段都没有,要么四个一起有。
    CONSTRAINT po_line_retentions_release_atomic CHECK (
        (released_at IS NULL AND released_by IS NULL AND released_amount_ccy IS NULL
            AND withheld_amount_ccy IS NULL AND withholding_reason IS NULL)
        OR
        (released_at IS NOT NULL AND released_by IS NOT NULL
            AND released_amount_ccy IS NOT NULL AND withheld_amount_ccy IS NOT NULL)
    ),
    -- 扣了钱就要说为什么。【扣 0 不需要理由】—— 那是"全额放行",不是一次扣留。
    CONSTRAINT po_line_retentions_withholding_needs_reason CHECK (
        withheld_amount_ccy IS NULL OR withheld_amount_ccy = 0 OR withholding_reason IS NOT NULL
    )
);

COMMENT ON TABLE public.purchase_order_line_retentions IS
'EQP-PAY-1:设备质保金(retention)。**一台机器一行,而"没有质保金"= 没有这一行。**

★【为什么不塞进 purchase_order_payment_terms】★ 两个理由,任何一个都够:
  ① 那张表【存不下"某事之后 N 个月"】。它只有 due_date(一个字面日期,而且
     fixed_date 那一种【必须】有它)与 expected_date(一个明说了是估计的值)。
     把算好的到期日写进 due_date,会让一个推导值长得和一条合同条款一模一样,
     并在验收日改变的那一刻【悄悄地错】;
  ② 那张表的抬头【自己声明】它不是账:"计划不是债权……也没有已付/未付状态列",
     并且不参与任何结算。而质保金的放款确认(谁、何时、放了多少、扣了多少、为什么)
     恰恰是一本账。把结算列螺到一张写着"我不做结算"的表上,是让它自相矛盾。

★【为什么挂在【行】上而不是单上】★ 逐台。四台机器是四条行,各有各的资产卡与验收日。
挂在表头上就说不出"这台有质保金、那台没有" —— 而那是 Tim 强调了两次的要求。

★【0% 与"没有"永远不会长得一样】★ percentage 的 CHECK 是 `> 0`,一行 0% 【存不进去】。
所以"没有质保金"唯一的表达方式就是【结构性的缺席】,不是一个零值。

★【到期日不在这张表里】★ 它是【推导】的,活在 purchase_order_retention_status 视图里:
acceptance_date + retention_months。存一个字面量,等于在验收日期改变时悄悄地错。

★【到期不自动付】★ released_at 为 NULL 就是"还没有人确认过"。到期只让状态变成
awaiting_confirmation,应付【不因为到期而成立】。质保金的意义就在于它扣得下来,
自动放款等于把它废掉。放款只经 release_purchase_order_retention。';

COMMENT ON COLUMN public.purchase_order_line_retentions.retention_months IS
'质保期月数。默认 12(Tim 裁定),**逐台可改** —— 默认值是一个起点,不是一条规则。
到期日 = fixed_assets.acceptance_date + 本列个月,【现算,不存】。';

COMMENT ON COLUMN public.purchase_order_line_retentions.percentage IS
'质保金比例,对该采购行的 estimated_amount_ccy 而言。与 fixed_amount_ccy 二选一。
★ 下界是 **> 0**,这一条是刻意的:一行 0% 存不进去,于是"没有质保金"唯一的写法
就是【没有这一行】。"0% 质保金"与"没有质保金"是两个不同的事实,永远不许渲染成同一个样子。';

CREATE INDEX idx_po_line_retentions_line ON public.purchase_order_line_retentions (purchase_order_line_id);

-- 质保金只能挂在【设备行】上,而且锚只能是一个【记得住日期】的事件。
-- 函数体在 db/functions/guard_retention_row.sql。
CREATE TRIGGER trg_po_line_retentions_guard
    BEFORE INSERT OR UPDATE ON public.purchase_order_line_retentions
    FOR EACH ROW EXECUTE FUNCTION public.guard_retention_row();

ALTER TABLE public.purchase_order_line_retentions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "purchase_order_line_retentions select by permission"
    ON public.purchase_order_line_retentions
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text));
CREATE POLICY "purchase_order_line_retentions insert by permission"
    ON public.purchase_order_line_retentions
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.purchasing.edit'::text));
CREATE POLICY "purchase_order_line_retentions update by permission"
    ON public.purchase_order_line_retentions
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.purchasing.edit'::text)) WITH CHECK (has_permission('module.purchasing.edit'::text));
CREATE POLICY "purchase_order_line_retentions delete by permission"
    ON public.purchase_order_line_retentions
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.purchasing.edit'::text));

-- 字段级遮蔽:金额是价格类数据,与 purchase_order_payment_terms.fixed_amount_ccy
-- 同一个判据(data.view_prices)。percentage 不遮 —— 那张表也没有遮它。
-- 【三件事一支迁移】:REVOKE/GRANT 在这里,_masked 视图在下面。
REVOKE SELECT ON public.purchase_order_line_retentions FROM authenticated, anon;
GRANT SELECT (id, purchase_order_line_id, percentage, retention_months, anchor_event,
              notes, created_at, created_by, released_at, released_by, withholding_reason)
    ON public.purchase_order_line_retentions TO authenticated;
