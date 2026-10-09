-- db/tables/electricity_allocation_lines.sql
-- MES-5a-2(2026-10-08,MES-5a Step 0 Q21 · Q22 · Q24,Tim):【一张电费单分给一炉的那一份】—— 一行一炉。
--   kwh  = 这一炉分到的、它那台机器在这段时间里量到的电(machine_kwh)的份:
--          basis = 'recorded_energy':这台机器这段时间里【每一炉】都记了自己的 energy_kwh → 按记下的电量的比例分(weight = 那一炉记下的 kWh);
--          basis = 'run_time'       :只要有一炉没记 → 整台机器这一段【全部】按运行时长分(weight = ended_at − started_at,分钟)(Q22,Tim)。
--          依据印在每一行上(Q22)。share = weight ÷ 这台机器这一段的 weight 之和。
--   amount = kwh × 账单单价(账单金额 ÷ 账单 kWh),到分;尾差留在 6200(electricity_allocations.overhead_amount)。
--   cost_entry_id = 为这一份写下的那一条实际电费成本行(已结)。~~run_id 唯一~~ ★ MES-5b-2(Step 0 Q23):一炉【最多在一张没撤回的分摊里】——
--          唯一约束拿掉(一炉撤回之后要能再分一次),换成 guard_electricity_line_one_live_allocation(插入前拒 ELECTRICITY_RUN_ALREADY_ALLOCATED)。
--   run_energy_kwh = 那一炉自己记的 energy_kwh(没记为空)—— 一炉的【电量】就是它(Q21);分到的 kwh 是钱怎么分的依据,两者可以不等。
--   【金额遮蔽】amount 只经 electricity_allocation_lines_masked 读(data.view_prices,Q30)。只追加。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.electricity_allocation_lines (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    allocation_id   uuid NOT NULL REFERENCES public.electricity_allocations (id),
    run_id          uuid NOT NULL REFERENCES public.processing_runs (id),
    equipment_id    uuid NOT NULL REFERENCES public.fixed_assets (id),
    basis           text NOT NULL CHECK (basis IN ('recorded_energy', 'run_time')),
    run_energy_kwh  numeric CHECK (run_energy_kwh IS NULL OR run_energy_kwh >= 0),
    run_minutes     numeric CHECK (run_minutes IS NULL OR run_minutes >= 0),
    weight          numeric NOT NULL CHECK (weight >= 0),
    share           numeric NOT NULL CHECK (share >= 0 AND share <= 1),
    machine_kwh     numeric NOT NULL CHECK (machine_kwh >= 0),
    kwh             numeric NOT NULL CHECK (kwh >= 0),
    amount          numeric NOT NULL CHECK (amount >= 0),
    cost_entry_id   uuid NOT NULL UNIQUE REFERENCES public.processing_cost_entries (id),
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT electricity_allocation_lines_basis_shape
        CHECK ((basis = 'recorded_energy' AND run_energy_kwh IS NOT NULL) OR (basis = 'run_time' AND run_minutes IS NOT NULL))
);

COMMENT ON TABLE public.electricity_allocation_lines IS
    'MES-5a-2:一张电费单分给一炉的那一份(一行一炉;MES-5b-2 起一炉最多在一张没撤回的分摊里 —— guard_electricity_line_one_live_allocation)。依据印在每一行(Q22):recorded_energy = 这台机器这段时间每一炉都记了电量,按它分;run_time = 有一炉没记,整台机器按运行时长分。amount 只经 _masked 视图读(data.view_prices)。cost_entry_id = 为它写下的那条已结的实际电费成本行。只追加。';

CREATE INDEX electricity_allocation_lines_allocation ON public.electricity_allocation_lines (allocation_id);
CREATE INDEX electricity_allocation_lines_run_id_rel ON public.electricity_allocation_lines (run_id);
CREATE INDEX electricity_allocation_lines_equipment_id_rel ON public.electricity_allocation_lines (equipment_id);

CREATE TRIGGER trg_electricity_allocation_lines_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.electricity_allocation_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

-- MES-5b-2(Step 0 Q23):一炉最多在一张【没撤回】的分摊里(取代原来的 run_id 唯一)。
CREATE TRIGGER trg_electricity_allocation_lines_one_live
    BEFORE INSERT ON public.electricity_allocation_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_electricity_line_one_live_allocation();

ALTER TABLE public.electricity_allocation_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "electricity_allocation_lines select by permission" ON public.electricity_allocation_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.finance.view'::text, 'module.processing.view'::text]));

-- 字段级遮蔽:amount 只经 electricity_allocation_lines_masked 读。【加列必改这一行与 _masked 视图】
REVOKE SELECT ON public.electricity_allocation_lines FROM authenticated, anon;
GRANT SELECT (id, allocation_id, run_id, equipment_id, basis, run_energy_kwh, run_minutes, weight, share, machine_kwh, kwh,
              cost_entry_id, created_at)
    ON public.electricity_allocation_lines TO authenticated;
REVOKE ALL ON public.electricity_allocation_lines FROM anon;
