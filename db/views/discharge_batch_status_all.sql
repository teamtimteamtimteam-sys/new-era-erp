-- db/views/discharge_batch_status_all.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23 · Q24;MES-5a Step 0 Q4–Q6 · Q18,Tim):【一批料的放电核实到哪儿了】—— 一批一行。
--   只列"放电跟它有关"的批:记了模组数,或有放电结果,或做过一炉 verifies_by_unit 的工序的投料。
--   计数(都只数【当前最新】的结论,discharge_module_current_all):
--     modules_recorded  有结论的模组数(含拆出去的)
--     passed            最新一条是通过、没被拆走
--     failed_redischarge 最新一条是失败、处置再放电、没被拆走
--     failed_quarantine  最新一条是失败、处置隔离、还没拆走(提醒臂 discharge_quarantine_pending 的那一类)
--     split_out          已拆去隔离
--     contradictions     最新一条与 V9 矛盾(只标出)
--   rule_verified = 记了模组数,并且 通过 + 拆走 = 模组数(Q6)—— 那是"这一批该是已放电并核实"的唯一一份判据;
--     discharge_verify_batch 照它改状态,提醒臂 discharge_unverified 照它列。部分放电(只放了几个模组)永远凑不满 —— P1 就此关掉。
--   currently_verified = 这一批此刻开着那道工序的结果状态(deep_discharge → discharged_verified)。
--   latest_run_* = 这一批做过的、没回滚的、最晚的那一炉 verifies_by_unit 工序(核实改状态时记的就是它)。
--   属主视图,不给 authenticated:读者经 discharge_batch_status(带门)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE VIEW public.discharge_batch_status_all WITH (security_invoker = off) AS
 WITH b AS (
         SELECT 'inbound'::text AS batch_kind,
            ib.id AS batch_id,
            ib.code AS batch_code,
            ib.material_id,
            ib.module_count
           FROM inbound_batches ib
          WHERE ib.deleted_at IS NULL
        UNION ALL
         SELECT 'output'::text AS batch_kind,
            ob.id AS batch_id,
            ob.code AS batch_code,
            ob.material_id,
            ob.module_count
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL
        ), runs AS (
         SELECT COALESCE(pi.inbound_batch_id, pi.output_batch_id) AS batch_id,
            pr.id AS run_id,
            pr.code AS run_code,
            pr.process_date,
            ot.resulting_safety_state_code AS result_state,
            row_number() OVER (PARTITION BY (COALESCE(pi.inbound_batch_id, pi.output_batch_id)) ORDER BY pr.process_date DESC, pr.started_at DESC NULLS LAST, pr.code DESC) AS rn
           FROM processing_inputs pi
             JOIN processing_runs pr ON pr.id = pi.run_id
             JOIN operation_types ot ON ot.code = pr.operation_type_code
          WHERE ot.verifies_by_unit AND pr.status = 'committed'::text AND pr.deleted_at IS NULL
        ), m AS (
         SELECT c.batch_id,
            count(*) AS modules_recorded,
            count(*) FILTER (WHERE NOT c.split_out AND c.verdict = 'pass'::text) AS passed,
            count(*) FILTER (WHERE NOT c.split_out AND c.verdict = 'fail'::text AND c.disposition = 're_discharge'::text) AS failed_redischarge,
            count(*) FILTER (WHERE NOT c.split_out AND c.verdict = 'fail'::text AND c.disposition = 'quarantine'::text) AS failed_quarantine,
            count(*) FILTER (WHERE c.split_out) AS split_out,
            count(*) FILTER (WHERE c.contradicts_pass_voltage) AS contradictions
           FROM discharge_module_current_all c
          GROUP BY c.batch_id
        )
 SELECT b.batch_kind,
    b.batch_id,
    b.batch_code,
    b.material_id,
    b.module_count,
    COALESCE(m.modules_recorded, 0::bigint) AS modules_recorded,
    COALESCE(m.passed, 0::bigint) AS passed,
    COALESCE(m.failed_redischarge, 0::bigint) AS failed_redischarge,
    COALESCE(m.failed_quarantine, 0::bigint) AS failed_quarantine,
    COALESCE(m.split_out, 0::bigint) AS split_out,
    COALESCE(m.contradictions, 0::bigint) AS contradictions,
    b.module_count IS NOT NULL AND (COALESCE(m.passed, 0::bigint) + COALESCE(m.split_out, 0::bigint)) = b.module_count AS rule_verified,
    r.run_id AS latest_run_id,
    r.run_code AS latest_run_code,
    r.process_date AS latest_run_date,
    COALESCE(r.result_state, ( SELECT ot.resulting_safety_state_code
           FROM operation_types ot
          WHERE ot.verifies_by_unit
          ORDER BY ot.code
         LIMIT 1)) AS result_state,
        CASE
            WHEN b.batch_kind = 'inbound'::text THEN (EXISTS ( SELECT 1
               FROM inbound_batch_safety_states s
              WHERE s.inbound_batch_id = b.batch_id AND s.ended_at IS NULL AND s.safety_state_code = COALESCE(r.result_state, ( SELECT ot.resulting_safety_state_code
                       FROM operation_types ot
                      WHERE ot.verifies_by_unit
                      ORDER BY ot.code
                     LIMIT 1))))
            ELSE (EXISTS ( SELECT 1
               FROM output_batch_safety_states s
              WHERE s.output_batch_id = b.batch_id AND s.ended_at IS NULL AND s.safety_state_code = COALESCE(r.result_state, ( SELECT ot.resulting_safety_state_code
                       FROM operation_types ot
                      WHERE ot.verifies_by_unit
                      ORDER BY ot.code
                     LIMIT 1))))
        END AS currently_verified
   FROM b
     LEFT JOIN m ON m.batch_id = b.batch_id
     LEFT JOIN runs r ON r.batch_id = b.batch_id AND r.rn = 1
  WHERE b.module_count IS NOT NULL OR m.batch_id IS NOT NULL OR r.run_id IS NOT NULL;

REVOKE ALL ON public.discharge_batch_status_all FROM PUBLIC, anon, authenticated;
