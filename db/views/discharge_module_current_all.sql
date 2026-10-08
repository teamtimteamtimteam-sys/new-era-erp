-- db/views/discharge_module_current_all.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23;MES-5a Step 0 Q6 · Q12,Tim):【每一批的每一个模组,此刻的放电结论】—— 一个模组一行。
--   当前 = 没被更正、所在的那一炉没回滚;最新 = 同一批同一个模组的当前行里判定时刻最晚的那一条(再按 id —— 同刻时记得晚的赢)。
--   attempts = 这个模组的当前结果条数(一炉一条;更正不算新的一次),redischarge_count = attempts − 1。
--   split_out = 这个模组被拆去隔离了(拆分那一炉没回滚),带出拆进的那一批。
--   属主视图、EXECUTE / SELECT 不给 authenticated:读者经 discharge_module_rows(带门);核实(discharge_verify_batch)与提醒臂读它。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE VIEW public.discharge_module_current_all WITH (security_invoker = off) AS
 WITH cur AS (
         SELECT r.id,
            r.run_id,
            r.inbound_batch_id,
            r.output_batch_id,
                CASE
                    WHEN r.inbound_batch_id IS NOT NULL THEN 'inbound'::text
                    ELSE 'output'::text
                END AS batch_kind,
            COALESCE(r.inbound_batch_id, r.output_batch_id) AS batch_id,
            r.module_ref,
            r.channel_no,
            r.outlet_voltage_v,
            r.verdict,
            r.verdict_at,
            r.disposition,
            r.pass_voltage_v_at,
            r.contradicts_pass_voltage,
            row_number() OVER (PARTITION BY (COALESCE(r.inbound_batch_id, r.output_batch_id)), r.module_ref ORDER BY r.verdict_at DESC, r.id DESC) AS rn,
            count(*) OVER (PARTITION BY (COALESCE(r.inbound_batch_id, r.output_batch_id)), r.module_ref) AS attempts
           FROM discharge_module_results r
             JOIN processing_runs pr ON pr.id = r.run_id
          WHERE pr.status = 'committed'::text AND pr.deleted_at IS NULL AND NOT (EXISTS ( SELECT 1
                   FROM discharge_module_results x
                  WHERE x.corrects_id = r.id))
        )
 SELECT c.batch_kind,
    c.batch_id,
    c.module_ref,
    c.id AS result_id,
    c.run_id,
    c.channel_no,
    c.outlet_voltage_v,
    c.verdict,
    c.verdict_at,
    c.disposition,
    c.pass_voltage_v_at,
    c.contradicts_pass_voltage,
    c.attempts,
    c.attempts - 1 AS redischarge_count,
    sp.split_run_id IS NOT NULL AS split_out,
    sp.split_run_id,
    sp.new_output_batch_id
   FROM cur c
     LEFT JOIN LATERAL ( SELECT s.split_run_id,
            s.new_output_batch_id
           FROM discharge_module_splits s
             JOIN processing_runs sr ON sr.id = s.split_run_id
          WHERE COALESCE(s.inbound_batch_id, s.output_batch_id) = c.batch_id AND s.module_ref = c.module_ref AND sr.status = 'committed'::text AND sr.deleted_at IS NULL
          ORDER BY s.id DESC
         LIMIT 1) sp ON true
  WHERE c.rn = 1;

REVOKE ALL ON public.discharge_module_current_all FROM PUBLIC, anon, authenticated;
