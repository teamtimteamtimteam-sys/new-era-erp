-- db/views/contamination_shift_status.sql
-- MES-4b(2026-10-07,MES-4b Step 0 Q25,Tim):【每一个班、每一条流,抽过没有 —— 带门的外壳】。/operation/contamination 读它。
--   门:加工或产出查看码任一(极片批的买方关心的质量事实,Q25)。算术全在 contamination_shift_status_all,这里一个字都不重算。
--   属主权限:基视图从 authenticated 收回了;视图读视图走属主替换。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE VIEW public.contamination_shift_status WITH (security_invoker = off) AS
 SELECT process_date,
    shift_code,
    stream_code,
    first_run_id,
    first_run_code,
    run_codes,
    sampled_count,
    not_sampled_count,
    max_rate_pct,
    any_above_warning,
    check_state
   FROM contamination_shift_status_all
  WHERE has_any_permission(ARRAY['module.processing.view'::text, 'module.output.view'::text]);

COMMENT ON VIEW public.contamination_shift_status IS
    'MES-4b:每一个(加工日, 班次, 流)抽过没有,带门(加工或产出查看码)。算术全在 contamination_shift_status_all。';

GRANT SELECT ON public.contamination_shift_status TO authenticated;
REVOKE ALL ON public.contamination_shift_status FROM anon;
