-- db/views/sample_rows.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q7 · Q8 · Q15,Tim):【一份样品与它此刻的保管状态】—— 样品页、样品清单、批次与化验页上的样品面板读它。
--   谁拿着、在哪、什么状态【全部从最近那一条保管记录读】(sample_events,按 id —— id 记先后):
--     state            held(taken / received_back / moved)· at_lab(sent_to_lab)· disposed
--     laboratory_code  在实验室时是哪一家(与它那一侧的编号)
--     storage_location 最近那一条说了库位时是那个库位;没说就是空(屏幕上"没记库位"),不往前翻一条旧的 —— 一个拿回来却没说放哪儿的罐子,
--                      它的库位就是没人记过,不是上一次那个
--   disposed_early   在留样日之前处置的(Q15:允许、理由必填、标出来)。retention_due:没处置、而留样日已经过了(sample_retention_due 那一支)。
--   【门】质量查看码,或那一批自己那一页的查看码(与 samples 的读策略同一句)。属主视图:读 sample_events / storage_locations / 批次
--   不再过各自的 RLS,所以条件写在末尾的 WHERE 里一次。没有金额,不遮。
--   【state 那一列写在所有分支列的最前面】check-i18n 的 quality.state.* 后缀集合现读它(sqlCaseAs 从文件里的第一段分支读起)。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.

CREATE VIEW public.sample_rows WITH (security_invoker = off) AS
 SELECT s.id,
    s.code,
    s.kind,
        CASE e.event_kind
            WHEN 'sent_to_lab'::text THEN 'at_lab'::text
            WHEN 'disposed'::text THEN 'disposed'::text
            ELSE 'held'::text
        END AS state,
    s.inbound_batch_id,
    s.output_batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
        CASE
            WHEN s.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    s.taken_on,
    s.mass_g,
    s.sales_order_id,
    so.code AS sales_order_code,
    s.contamination_check_id,
    s.retain_until,
    s.retain_until_source,
    s.retention_days_at,
    s.notes,
    s.created_at,
    s.created_by,
    e.event_kind AS last_event_kind,
    e.occurred_at AS last_event_at,
        CASE
            WHEN e.event_kind = 'sent_to_lab'::text THEN e.laboratory_code
            ELSE NULL::text
        END AS laboratory_code,
        CASE
            WHEN e.event_kind = 'sent_to_lab'::text THEN e.lab_reference
            ELSE NULL::text
        END AS lab_reference,
    e.storage_location_id,
    loc.code AS storage_location_code,
        CASE
            WHEN e.event_kind = 'disposed'::text THEN e.occurred_at
            ELSE NULL::timestamp with time zone
        END AS disposed_at,
        CASE
            WHEN e.event_kind = 'disposed'::text THEN e.reason
            ELSE NULL::text
        END AS disposal_reason,
    e.event_kind = 'disposed'::text AND s.retain_until IS NOT NULL
        AND (e.occurred_at AT TIME ZONE 'Asia/Singapore'::text)::date < s.retain_until AS disposed_early,
    e.event_kind <> 'disposed'::text AND s.retain_until IS NOT NULL AND s.retain_until < CURRENT_DATE AS retention_due,
    ( SELECT count(*) AS count
           FROM sample_events x
          WHERE x.sample_id = s.id) AS event_count
   FROM samples s
     LEFT JOIN inbound_batches ib ON ib.id = s.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = s.output_batch_id
     LEFT JOIN sales_orders so ON so.id = s.sales_order_id
     LEFT JOIN LATERAL ( SELECT x.event_kind,
            x.occurred_at,
            x.laboratory_code,
            x.lab_reference,
            x.storage_location_id,
            x.reason
           FROM sample_events x
          WHERE x.sample_id = s.id
          ORDER BY x.id DESC
         LIMIT 1) e ON true
     LEFT JOIN storage_locations loc ON loc.id = e.storage_location_id
  WHERE has_permission('module.quality.view'::text) OR s.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text) OR s.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text);

COMMENT ON VIEW public.sample_rows IS
    'MES-6a-1:一份样品与它此刻的保管状态 —— state / 实验室 / 库位都从最近那一条保管记录读(按 id);disposed_early = 留样日之前处置的(Q15);retention_due = 没处置而留样日已过。门:质量查看码或那一批自己的查看码(与 samples 的读策略同一句)。';

GRANT SELECT ON public.sample_rows TO authenticated;
REVOKE ALL ON public.sample_rows FROM anon;
