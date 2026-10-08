-- db/views/meter_readings_current.sql
-- MES-5a-2(2026-10-08,MES-5a Step 0 Q20,Tim):【一台电表当前的读数,与每一条比前一条多用了多少】—— 设备页读它。
--   当前 = 更正链的末端(没有别的行指着它)而且没被撤回。按 (read_at, id) 排 —— id 是一个只增的序号,同一刻两条也排得出先后
--   (AGENTS.md「取最新那一行要先问排得出先后吗」;同一台表同一刻的两条当前读数,record 函数本来就拒)。
--   delta_kwh = 这一条 − 前一条当前读数;第一条、或者这一条是寄存器清零 → 空(跨过清零的那一段量不出来,不是零)。
--   分摊用的是同一个算法(electricity_allocation_compute 里那一段)—— 这张视图给人看,那一段给钱用;两边都由 fixture 256 READ 钉住。
--   属主权限 + 表的读策略原样写回(加工或财务查看码)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.

CREATE VIEW public.meter_readings_current WITH (security_invoker = off) AS
 SELECT c.id,
    c.device_id,
    c.read_at,
    c.register_kwh,
    c.is_register_reset,
    c.reset_reason,
    c.source,
    c.notes,
    c.recorded_at,
    c.recorded_by,
    (c.corrects_id IS NOT NULL) AS corrected,
    c.correction_reason,
    c.previous_kwh,
        CASE
            WHEN c.previous_kwh IS NULL OR c.is_register_reset THEN NULL::numeric
            ELSE c.register_kwh - c.previous_kwh
        END AS delta_kwh
   FROM ( SELECT r.id,
            r.device_id,
            r.read_at,
            r.register_kwh,
            r.is_register_reset,
            r.reset_reason,
            r.source,
            r.notes,
            r.recorded_at,
            r.recorded_by,
            r.corrects_id,
            r.correction_reason,
            lag(r.register_kwh) OVER (PARTITION BY r.device_id ORDER BY r.read_at, r.id) AS previous_kwh
           FROM meter_readings r
          WHERE NOT r.withdrawn AND NOT (EXISTS ( SELECT 1
                   FROM meter_readings x
                  WHERE x.corrects_id = r.id))) c
  WHERE has_any_permission(ARRAY['module.processing.view'::text, 'module.finance.view'::text]);

COMMENT ON VIEW public.meter_readings_current IS
    'MES-5a-2:电表当前的读数(更正链末端、没撤回),按 (read_at, id) 排,delta_kwh = 与前一条当前读数之差(第一条或寄存器清零为空)。门:module.processing.view 或 module.finance.view。';

GRANT SELECT ON public.meter_readings_current TO authenticated;
REVOKE ALL ON public.meter_readings_current FROM anon;
