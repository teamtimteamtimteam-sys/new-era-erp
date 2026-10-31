-- db/tables/grid_emission_factors.sql
-- ESG-2(Tim 2026-10-31 Q1 · Q2 · Q3 · Q9):【电网排放因子 —— 一年一个,带历史】。Scope 2(按地点法)= 电费单的 kWh × 那一年的因子。
--   【一年一个,按电费单的年份用】(Q2 (a)):一张单用它【账期结束那一天】的年份的因子;那一年没有就用【更早最近的一年】,页面照直说用的是哪一年;
--     比所有已填年份都早的单 → 「没设因子」,从不读成 0(Q1)。
--   【更正是新版本】(Q2):同一年再填一次 = 追加一行,要写理由;最后一行说了算(id 是 identity,排得出先后 —— AGING-1)。行写下就不改、不删。
--   【单位】EMA 公布的新加坡电网因子只含 CO2(不是 CO2e),所以单位写死 kg CO2/kWh,页面上的数读 tCO2(Q3)。
--   【引导不带值】(Q1):Tim 对着 EMA 的页面核过之后自己填(候选 0.402 / 2024,未核实,见 docs/known-issues.md § ESG2-GRID-FACTOR-UNVERIFIED)。
--   【写】只经 esg_set_grid_factor(action.manage_esg:admin · cco · cfo)。【读】每一个登录的人(一个公开的数;读不到它会把「没设」说成真的)。
--
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
-- First-run script (plain CREATEs).
CREATE TABLE public.grid_emission_factors (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    factor_year     integer NOT NULL CHECK (factor_year BETWEEN 2000 AND 2100),
    kg_co2_per_kwh  numeric NOT NULL CHECK (kg_co2_per_kwh > 0 AND kg_co2_per_kwh < 5),
    unit            text NOT NULL DEFAULT 'kg CO2/kWh' CHECK (unit = 'kg CO2/kWh'),
    source          text NOT NULL CHECK (btrim(source) <> ''),
    reason          text CHECK (reason IS NULL OR btrim(reason) <> ''),
    recorded_at     timestamptz NOT NULL DEFAULT now(),
    recorded_by     uuid DEFAULT auth.uid()
);
CREATE INDEX grid_emission_factors_year ON public.grid_emission_factors (factor_year, id);
COMMENT ON TABLE public.grid_emission_factors IS
    'ESG-2:电网排放因子(kg CO2/kWh),一年一个、带历史:同一年再填一次是带理由的新版本,最后一行说了算。电费单用它账期结束那一年的因子,没有就用更早最近的一年。只经 esg_set_grid_factor 写(action.manage_esg);写下就不改、不删。';
COMMENT ON COLUMN public.grid_emission_factors.reason IS
    '同一年的第二个及以后的版本必填(为什么改);第一个版本为空。';

-- 写下就不改、不删(语句级,所以 RLS 碰不到行时照样抛 —— ALERT-1)。authenticated 没有任何写授权,唯一的写入口是 esg_set_grid_factor;
--   这支守卫挡的是属主那一侧的路(一次迁移、一支 DEFINER 函数)。
CREATE OR REPLACE FUNCTION public.guard_grid_emission_factor_write()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'ESG_GRID_FACTOR_IMMUTABLE';
END;
$function$;
CREATE TRIGGER trg_grid_emission_factors_immutable
    BEFORE UPDATE OR DELETE ON public.grid_emission_factors
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_grid_emission_factor_write();
CREATE TRIGGER trg_grid_emission_factors_truncate
    BEFORE TRUNCATE ON public.grid_emission_factors
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.grid_emission_factors ENABLE ROW LEVEL SECURITY;
CREATE POLICY "grid_emission_factors select by any signed-in user" ON public.grid_emission_factors
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);
REVOKE ALL ON public.grid_emission_factors FROM authenticated, anon;
GRANT SELECT ON public.grid_emission_factors TO authenticated;
