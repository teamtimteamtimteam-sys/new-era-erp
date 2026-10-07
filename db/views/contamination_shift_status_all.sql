-- db/views/contamination_shift_status_all.sql
-- MES-4b(2026-10-07,规格 §3.4 "at least once per shift";MES-0 Q52;MES-4b Step 0 Q21–Q24,Tim):【每一个班、每一条流,抽过没有】—— 基视图,不给人读。
--   一行 = (加工日, 班次, 流):那一天那一班有一张 MES-4a 起记的、已提交没回滚的加工单产出了这条流的极片(contamination_streams.sheet_form_code)。
--   check_state:checked(有一条当前的 sampled)· not_sampled(只有当前的 not_sampled —— 没抽,有理由)· missing(一条当前的抽检都没有)。
--   抽检挂在哪一张单上都算(同一天同一班的任何一张);只算已提交没回滚的单上的、没被更正过的那一条。班次读自那一炉(不另存)。
--   first_run_id / first_run_code:这一格最早的那一炉(按开始时刻、再按单号)—— 提醒臂点进去的那一张(fixture 47 的行号规矩)。
--   max_rate_pct / any_above_warning:当前 sampled 里最高的污染率,以及有没有一条超过它记录时的警戒线(都判不了时 NULL)。
--   【一份算术两个读者】contamination_shift_status(带门的外壳,/operation/contamination 读)· operations_now 的 contamination_check_missing。
--   MES-4a 之前的单没有班次,永远不出现。与物料平衡无关。
--   【属主视图、不带谓词、SELECT 从 authenticated 收回】—— 只持产出码的人读不到 processing_runs,一张 invoker 视图会安静地丢行。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE VIEW public.contamination_shift_status_all WITH (security_invoker = off) AS
 WITH sheet_runs AS (
         SELECT DISTINCT r.id AS run_id,
            r.code AS run_code,
            r.process_date,
            r.shift_code,
            r.started_at,
            s.code AS stream_code
           FROM processing_runs r
             JOIN processing_outputs po ON po.run_id = r.id
             JOIN output_batches ob ON ob.id = po.output_batch_id
             JOIN materials m ON m.id = ob.material_id
             JOIN contamination_streams s ON s.sheet_form_code = m.form_code
          WHERE r.status = 'committed'::text AND r.deleted_at IS NULL AND r.started_at IS NOT NULL AND r.shift_code IS NOT NULL AND s.is_active
        ), current_checks AS (
         SELECT c.id,
            c.stream_code,
            c.kind,
            c.rate_pct,
            c.above_warning,
            r.process_date,
            r.shift_code
           FROM contamination_checks c
             JOIN processing_runs r ON r.id = c.run_id
          WHERE r.status = 'committed'::text AND r.deleted_at IS NULL AND NOT (EXISTS ( SELECT 1
                   FROM contamination_checks x
                  WHERE x.corrects_id = c.id))
        ), cells AS (
         SELECT sr.process_date,
            sr.shift_code,
            sr.stream_code,
            (array_agg(sr.run_id ORDER BY sr.started_at, sr.run_code))[1] AS first_run_id,
            (array_agg(sr.run_code ORDER BY sr.started_at, sr.run_code))[1] AS first_run_code,
            array_agg(sr.run_code ORDER BY sr.started_at, sr.run_code) AS run_codes
           FROM sheet_runs sr
          GROUP BY sr.process_date, sr.shift_code, sr.stream_code
        )
 SELECT cl.process_date,
    cl.shift_code,
    cl.stream_code,
    cl.first_run_id,
    cl.first_run_code,
    cl.run_codes,
    COALESCE(ck.sampled_count, 0::bigint) AS sampled_count,
    COALESCE(ck.not_sampled_count, 0::bigint) AS not_sampled_count,
    ck.max_rate_pct,
    ck.any_above_warning,
        CASE
            WHEN COALESCE(ck.sampled_count, 0::bigint) > 0 THEN 'checked'::text
            WHEN COALESCE(ck.not_sampled_count, 0::bigint) > 0 THEN 'not_sampled'::text
            ELSE 'missing'::text
        END AS check_state
   FROM cells cl
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE c.kind = 'sampled'::text) AS sampled_count,
            count(*) FILTER (WHERE c.kind = 'not_sampled'::text) AS not_sampled_count,
            max(c.rate_pct) AS max_rate_pct,
            bool_or(c.above_warning) AS any_above_warning
           FROM current_checks c
          WHERE c.process_date = cl.process_date AND c.shift_code = cl.shift_code AND c.stream_code = cl.stream_code) ck ON true;

COMMENT ON VIEW public.contamination_shift_status_all IS
    'MES-4b:每一个(加工日, 班次, 流)抽过没有 —— checked / not_sampled / missing。基视图,不给人读:读者经 contamination_shift_status;operations_now 的 contamination_check_missing 以属主身份读它。';

REVOKE ALL ON public.contamination_shift_status_all FROM authenticated, anon;
