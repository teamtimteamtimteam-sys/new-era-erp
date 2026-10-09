-- db/views/processing_run_energy.sql
-- MES-5a-2(2026-10-08,规格 §9;MES-0 Q26;MES-5a Step 0 Q21 · Q23,Tim):【一炉用了多少电、每吨多少、放电回收了多少】—— 加工单页读它。
--   own_kwh       这一炉自己记下的 energy_kwh(参数与指标里那个字段的更正链末端;控制器或操作员记的,MES-4a)。没记为空。
--   allocated_kwh 一张电费单分给这一炉的 kWh(electricity_allocation_lines;一炉至多一行)与分的依据(allocation_basis)。没分过为空。
--   energy_kwh    = own_kwh,没记才用 allocated_kwh(Q21:一炉的电量是它自己的值,有就用它)。energy_source 说是哪一个('recorded' |
--                   'allocated');两个都没有为空 —— 不是零。
--   kwh_per_tonne = energy_kwh ÷ (total_input ÷ 1000)(Q23:每吨的分母是投入量,与 V1 容差、V10 份额、平衡同一个口径;total_input 是 kg)。
--   recovered_kwh 放电那一炉的模组结果里记下的回收能量之和(Wh ÷ 1000;当前的结果)。【另列,从不与耗电相抵】(Q21)。没记为空。
--   不含任何金额(金额在 electricity_allocation_lines_masked,data.view_prices)。属主权限 + 加工查看码。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.

-- MES-5b-2(2026-10-09,MES-5b Step 0 Q23,Tim):分到的 kWh 只取【没撤回】的那一张分摊的那一行 —— 一炉的分摊撤回之后可以再分一次,
-- 于是一炉可以有两行(撤回过的那一张一行、改正过的那一张一行);照旧 LEFT JOIN 会把那一炉读成两行,而撤回过的那一份不该再算。

CREATE VIEW public.processing_run_energy WITH (security_invoker = off) AS
 SELECT r.id AS run_id,
    r.code,
    r.status,
    r.equipment_id,
    r.total_input,
    own.value_number AS own_kwh,
    l.kwh AS allocated_kwh,
    l.basis AS allocation_basis,
    l.allocation_id,
    COALESCE(own.value_number, l.kwh) AS energy_kwh,
        CASE
            WHEN own.value_number IS NOT NULL THEN 'recorded'::text
            WHEN l.kwh IS NOT NULL THEN 'allocated'::text
            ELSE NULL::text
        END AS energy_source,
        CASE
            WHEN COALESCE(own.value_number, l.kwh) IS NULL OR r.total_input IS NULL OR r.total_input <= 0::numeric THEN NULL::numeric
            ELSE round(COALESCE(own.value_number, l.kwh) / (r.total_input / 1000::numeric), 3)
        END AS kwh_per_tonne,
    rec.recovered_kwh
   FROM processing_runs r
     LEFT JOIN LATERAL ( SELECT v.value_number
           FROM processing_run_values v
          WHERE v.run_id = r.id AND v.field_code = 'energy_kwh'::text AND v.value_number IS NOT NULL
            AND NOT (EXISTS ( SELECT 1
                   FROM processing_run_values x
                  WHERE x.corrects_id = v.id))
          ORDER BY v.id DESC
         LIMIT 1) own ON true
     LEFT JOIN LATERAL ( SELECT ll.kwh,
            ll.basis,
            ll.allocation_id
           FROM electricity_allocation_lines ll
          WHERE ll.run_id = r.id AND NOT (EXISTS ( SELECT 1
                   FROM electricity_allocation_reversals v
                  WHERE v.allocation_id = ll.allocation_id))) l ON true
     LEFT JOIN LATERAL ( SELECT round(sum(d.energy_recovered_wh) / 1000::numeric, 3) AS recovered_kwh
           FROM discharge_module_results d
          WHERE d.run_id = r.id AND d.energy_recovered_wh IS NOT NULL
            AND NOT (EXISTS ( SELECT 1
                   FROM discharge_module_results y
                  WHERE y.corrects_id = d.id))) rec ON true
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_run_energy IS
    'MES-5a-2:一炉的电量(自己记的 energy_kwh,没记才用电费分摊分到的 kWh;来源在 energy_source)、每吨电耗(÷ 投入吨数)、放电回收的能量(另列,不相抵)。不含金额。门:module.processing.view。';

GRANT SELECT ON public.processing_run_energy TO authenticated;
REVOKE ALL ON public.processing_run_energy FROM anon;
