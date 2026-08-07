-- db/tables/pricing_term_commitment_metals.sql
-- 承诺副本的逐金属可付比(FIN-27)。pricing_formula_metals 的抄本。
--
-- 【不在本表里的金属 = 承诺时就不计价(payable 0)】—— 与 pricing_formula_metals
-- 同义,calculate_metal_price_from_terms 把这类金属列进 unpaid_metals,与
-- skipped_metals(有条款但当天没有行情)区分开:一个是没谈价,一个是没行情。
--
-- 【为什么抄成行而不是塞进一个 jsonb】结算算术本来就在按金属逐条查可付比;抄成行
-- 之后那句查询只是换了张表,别的什么都不用改。jsonb 适合"把一次算完的数留档"
-- (FIN-26 的 price_provenance),不适合"照着执行的条款"。
--
-- 随承诺【不】级联删除、且不可改:副本一旦落下,它就是记录
-- (守卫函数 db/functions/guard_pricing_commitment_immutable.sql)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【受限访问列】payable_pct —— 归 data.view_prices,只经
-- pricing_term_commitment_metals_masked 读取。加列必改列清单授权与遮蔽视图两处。
-- ════════════════════════════════════════════════════════════════════════════
--
-- NOTE: introduced by db/migrations/2026-08-07-fin27-pricing-terms-commitment.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.pricing_term_commitment_metals (
    commitment_id uuid NOT NULL REFERENCES public.pricing_term_commitments (id),
    metal         text NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    payable_pct   numeric NOT NULL CHECK (payable_pct >= 0 AND payable_pct <= 100),  -- RESTRICTED
    PRIMARY KEY (commitment_id, metal)
);

COMMENT ON TABLE public.pricing_term_commitment_metals IS
    '承诺副本的逐金属可付比(FIN-27)。不在本表里的金属 = 承诺时就不计价(payable 0),与 pricing_formula_metals 同义。';

CREATE TRIGGER trg_pricing_term_commitment_metals_immutable
    BEFORE UPDATE OR DELETE ON public.pricing_term_commitment_metals
    FOR EACH ROW EXECUTE FUNCTION public.guard_pricing_commitment_immutable();

ALTER TABLE public.pricing_term_commitment_metals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pricing_term_commitment_metals select by permission"
    ON public.pricing_term_commitment_metals
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text)
        OR has_permission('module.inbound.view'::text));

-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.pricing_term_commitment_metals FROM authenticated, anon;
GRANT SELECT (commitment_id, metal)
    ON public.pricing_term_commitment_metals TO authenticated;
