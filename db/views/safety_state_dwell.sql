-- db/views/safety_state_dwell.sql
-- MES-3a(2026-10-06,MES-0 Q35;MES-3a Step 0 Q14–Q16,Tim):【每一批身上每一条开着的安全状态,在厂里待了多久】。
--   一行 = 一条开着的状态(ended_at 为空),进料批与产出批两侧;注销的批不算。
--   days_recorded = 今天(新加坡日历)− 这条状态被记下的那一天(新加坡日历)—— 时钟从【记下的时刻】起算(Q35),
--   而那个时刻不因保存重来(set_*_safety_states 只加新勾上的、只结束拿掉的)。
--   dwell_status:not_set(这个状态的 dwell_warning_days 没给,V3)· past(到了或过了)· within。
--   on_site = 这一批此刻还有存量(流水之和 > 0)—— 提醒臂只看还在厂里的(Q15)。
--   读它的:两个批次页(每一条状态的那一行)· /inventory/storage-safety · operations_now 的 safety_state_dwell 臂。
--   【属主视图 + 逐行谓词】进料行要 module.inbound.view,产出行要 module.output.view(与两张状态表的读策略同一对)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE VIEW public.safety_state_dwell WITH (security_invoker = off) AS
 SELECT x.batch_kind,
    x.state_row_id,
    x.batch_id,
    x.batch_code,
    x.safety_state_code,
    d.name_en,
    d.name_zh,
    d.sort_order,
    x.recorded_at,
    x.recorded_by,
    (x.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date AS recorded_on,
    (now() AT TIME ZONE 'Asia/Singapore'::text)::date - (x.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date AS days_recorded,
    d.dwell_warning_days,
    d.requires_quarantine,
        CASE
            WHEN d.dwell_warning_days IS NULL THEN 'not_set'::text
            WHEN ((now() AT TIME ZONE 'Asia/Singapore'::text)::date - (x.recorded_at AT TIME ZONE 'Asia/Singapore'::text)::date) >= d.dwell_warning_days THEN 'past'::text
            ELSE 'within'::text
        END AS dwell_status,
    COALESCE(x.on_site_qty, 0::numeric) > 0::numeric AS on_site
   FROM ( SELECT 'inbound'::text AS batch_kind,
            s.id AS state_row_id,
            b.id AS batch_id,
            b.code AS batch_code,
            s.safety_state_code,
            s.created_at AS recorded_at,
            s.created_by AS recorded_by,
            ( SELECT sum(mv.qty_delta) AS sum
                   FROM inventory_movements mv
                  WHERE mv.inbound_batch_id = b.id) AS on_site_qty
           FROM inbound_batch_safety_states s
             JOIN inbound_batches b ON b.id = s.inbound_batch_id
          WHERE s.ended_at IS NULL AND b.deleted_at IS NULL AND has_permission('module.inbound.view'::text)
        UNION ALL
         SELECT 'output'::text AS batch_kind,
            s.id AS state_row_id,
            b.id AS batch_id,
            b.code AS batch_code,
            s.safety_state_code,
            s.created_at AS recorded_at,
            s.created_by AS recorded_by,
            ( SELECT sum(mv.qty_delta) AS sum
                   FROM inventory_movements mv
                  WHERE mv.output_batch_id = b.id) AS on_site_qty
           FROM output_batch_safety_states s
             JOIN output_batches b ON b.id = s.output_batch_id
          WHERE s.ended_at IS NULL AND b.deleted_at IS NULL AND has_permission('module.output.view'::text)) x
     JOIN inbound_safety_states d ON d.code = x.safety_state_code;

COMMENT ON VIEW public.safety_state_dwell IS
    'MES-3a:每一条开着的安全状态(进料批与产出批)被记下之后过了几个新加坡日历天,对着这个状态的 dwell_warning_days(V3):not_set · past · within;on_site = 这一批还有存量。只提醒,不拒。逐行谓词:进料行 module.inbound.view,产出行 module.output.view。';

GRANT SELECT ON public.safety_state_dwell TO authenticated;
REVOKE ALL ON public.safety_state_dwell FROM anon;
