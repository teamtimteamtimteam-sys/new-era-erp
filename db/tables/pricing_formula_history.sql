-- db/tables/pricing_formula_history.sql
-- 计价公式的【只增不改】编辑史(FIN-27,employment_history 的形状)。
--
-- 【为什么在副本之后还需要它】FIN-27 把结算条款抄到了承诺记录上,所以改公式对
-- 【既有】交易在构造上已经无害 —— 不需要不可变守卫。但一次编辑仍然改变此后
-- 【每一次报价】算出来的数,而"这张公式什么时候从 70% 改成 60% 的"至今没有任何
-- 地方答得上来。可变的行 + 只增不改的历史,是这套系统里带钱记录的第二种成规
-- (employees / employment_history、processing_cost_entries / …_history)。
--
-- 【为什么是触发器写,不是应用写】编辑路径是普通的 PostgREST UPDATE
-- (app/pricing/formulas/actions.ts),没有 RPC 可以挂;应用侧留痕会是"想写才写"的。
-- 触发器接得住每一条路径,包括直接连库改的那次。
--
-- 【金属子表也要】pricing_formula_metals 的编辑同样进本表(change_type
-- metal_set / metal_clear)。可付比是结算数字上最大的一根杠杆,而界面表达
-- "这个金属不再计价"的方式是【DELETE 掉那一行】(actions.ts 的 clears),
-- 那张表又没有软删 —— 只记表头的历史,对最激烈的一种编辑一言不发,
-- 而沉默读起来正好等于"什么都没改"。
--
-- 【触发器之前的编辑没有行】空白好过编造 —— 同 processing_cost_entry_history。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【受限访问列】old/new_payable_pct、old/new_treatment_charge_usd_per_tonne、
-- old/new_flat_discount_pct —— 与它们的源列同口径,归 data.view_prices,
-- 只经 pricing_formula_history_masked 读取。
-- 【加列必改两处】列清单 SELECT 授权与 _masked 视图。
-- ════════════════════════════════════════════════════════════════════════════
--
-- NOTE: introduced by db/migrations/2026-08-07-fin27-pricing-terms-commitment.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.pricing_formula_history (
    id                                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    formula_id                         uuid NOT NULL REFERENCES public.pricing_formulas (id),
    change_type                        text NOT NULL CHECK (change_type IN
                                       ('create','update','delete','restore','metal_set','metal_clear')),
    metal                              text CHECK (metal IS NULL OR metal IN ('ni','co','li','mn','cu','al','fe')),
    old_payable_pct                    numeric,   -- RESTRICTED
    new_payable_pct                    numeric,   -- RESTRICTED
    old_name                           text,
    new_name                           text,
    old_direction                      text,
    new_direction                      text,
    old_price_basis                    text,
    new_price_basis                    text,
    old_average_days                   integer,
    new_average_days                   integer,
    old_treatment_charge_usd_per_tonne numeric,   -- RESTRICTED
    new_treatment_charge_usd_per_tonne numeric,   -- RESTRICTED
    old_flat_discount_pct              numeric,   -- RESTRICTED
    new_flat_discount_pct              numeric,   -- RESTRICTED
    old_is_active                      boolean,
    new_is_active                      boolean,
    changed_at                         timestamptz NOT NULL DEFAULT now(),
    changed_by                         uuid,
    CONSTRAINT pricing_formula_history_metal_shape CHECK (
        (change_type IN ('metal_set','metal_clear')) = (metal IS NOT NULL)
    )
);

CREATE INDEX idx_pricing_formula_history_formula
    ON public.pricing_formula_history (formula_id, changed_at DESC);

COMMENT ON TABLE public.pricing_formula_history IS
    '计价公式的只增不改编辑史(FIN-27,employment_history 的形状)。谁、什么时候、从什么改到什么。触发器写入 —— 编辑路径是普通 UPDATE,没有 RPC 可以挂,应用侧留痕会是可跳过的。触发器之前的编辑没有行:空白好过编造。';

-- 历史本身不许被改写 —— 否则"留痕"只是摆设
-- (函数体在 db/functions/guard_pricing_formula_history_append_only.sql)
CREATE TRIGGER trg_pricing_formula_history_append_only
    BEFORE UPDATE OR DELETE ON public.pricing_formula_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_pricing_formula_history_append_only();

ALTER TABLE public.pricing_formula_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pricing_formula_history select by permission"
    ON public.pricing_formula_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.pricing.view'::text));

-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
-- 【加列必改这一行】列清单 SELECT 授权不会自动延伸到 ALTER 加的新列。
REVOKE SELECT ON public.pricing_formula_history FROM authenticated, anon;
GRANT SELECT (id, formula_id, change_type, metal, old_name, new_name,
              old_direction, new_direction, old_price_basis, new_price_basis,
              old_average_days, new_average_days, old_is_active, new_is_active,
              changed_at, changed_by)
    ON public.pricing_formula_history TO authenticated;
