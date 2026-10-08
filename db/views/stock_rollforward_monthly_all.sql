-- db/views/stock_rollforward_monthly_all.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q8,Tim):【库存的月度滚动】—— 基视图,不给人读。从 inventory_movements(库存的唯一真源)按
--   business_date 的月、按单位:期初 · 收货 · 加工产出 · 加工消耗(消耗与回滚还原的净额)· 销售 · 注销 · 盘点调整 · 回滚作废 ·
--   搬动(转移与状态变更,两条腿相抵,净额恒为 0)· 期末。每一个流向都取那一行流水的 qty_delta 原样(出为负、进为正)。
--   【没有"对得上"的旗标 —— 刻意的】期末 = 期初 + 本月各行之和,按构造成立;一个两边动不开的旗标是装饰(AGENTS.md
--   「两边只有在能分开的时候才是一个检查」)。所以这里只给数,不给判断。
--   【没有业务日期的流水】(FIN-32 之前写下的行,business_date 为空 —— 表的注释:不回填,界面读作"未知")不进任何一个月:
--     它们在 month 为空的那一行(每个单位一行),期初 / 期末为空。于是"某个月的期末"只是【有日期的】流水之和 —— 页面照直说。
--   月份从最早一条有日期的流水所在的月,连续到今天(新加坡日历)所在的月;没有流水的月也有一行(期初 = 期末)。
--   一个流水类型若不在下面的清单里,它不进任何一列 —— 期末于是对不上库存,看得见(不设"其他"兜底,AGENTS.md「兜底桶」)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.stock_rollforward_monthly_all WITH (security_invoker = off) AS
 WITH mv AS (
         SELECT (date_trunc('month'::text, m.business_date::timestamp without time zone))::date AS month,
            COALESCE(ib.unit, ob.unit) AS unit,
            m.movement_type,
            m.qty_delta
           FROM inventory_movements m
             LEFT JOIN inbound_batches ib ON ib.id = m.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = m.output_batch_id
        ), months AS (
         SELECT u.unit,
            (g.g)::date AS month
           FROM ( SELECT DISTINCT mv.unit
                   FROM mv) u
             CROSS JOIN LATERAL generate_series((( SELECT min(mv.month) AS min
                   FROM mv
                  WHERE mv.month IS NOT NULL))::timestamp without time zone, (date_trunc('month'::text, (now() AT TIME ZONE 'Asia/Singapore'::text)))::timestamp without time zone, '1 mon'::interval) g(g)
        ), flows AS (
         SELECT mv.month,
            mv.unit,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'receipt'::text), 0::numeric) AS received,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'processing_produce'::text), 0::numeric) AS produced,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = ANY (ARRAY['processing_consume'::text, 'reversal_restore'::text])), 0::numeric) AS consumed,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'sale'::text), 0::numeric) AS sold,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'writeoff'::text), 0::numeric) AS written_off,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'adjustment'::text), 0::numeric) AS adjusted,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'reversal_void'::text), 0::numeric) AS voided,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = ANY (ARRAY['transfer_out'::text, 'transfer_in'::text, 'status_change_out'::text, 'status_change_in'::text])), 0::numeric) AS moved
           FROM mv
          GROUP BY mv.month, mv.unit
        ), dated AS (
         SELECT ms.month,
            ms.unit,
            COALESCE(f.received, 0::numeric) AS received,
            COALESCE(f.produced, 0::numeric) AS produced,
            COALESCE(f.consumed, 0::numeric) AS consumed,
            COALESCE(f.sold, 0::numeric) AS sold,
            COALESCE(f.written_off, 0::numeric) AS written_off,
            COALESCE(f.adjusted, 0::numeric) AS adjusted,
            COALESCE(f.voided, 0::numeric) AS voided,
            COALESCE(f.moved, 0::numeric) AS moved
           FROM months ms
             LEFT JOIN flows f ON f.month = ms.month AND f.unit = ms.unit
        ), step AS (
         SELECT d.month,
            d.unit,
            d.received,
            d.produced,
            d.consumed,
            d.sold,
            d.written_off,
            d.adjusted,
            d.voided,
            d.moved,
            d.received + d.produced + d.consumed + d.sold + d.written_off + d.adjusted + d.voided + d.moved AS net
           FROM dated d
        )
 SELECT s.month,
    s.unit,
    COALESCE(sum(s.net) OVER (PARTITION BY s.unit ORDER BY s.month ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0::numeric) AS opening,
    s.received,
    s.produced,
    s.consumed,
    s.sold,
    s.written_off,
    s.adjusted,
    s.voided,
    s.moved,
    sum(s.net) OVER (PARTITION BY s.unit ORDER BY s.month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS closing
   FROM step s
UNION ALL
 SELECT NULL::date AS month,
    f.unit,
    NULL::numeric AS opening,
    f.received,
    f.produced,
    f.consumed,
    f.sold,
    f.written_off,
    f.adjusted,
    f.voided,
    f.moved,
    NULL::numeric AS closing
   FROM flows f
  WHERE f.month IS NULL;

COMMENT ON VIEW public.stock_rollforward_monthly_all IS
    'MES-5b-1:库存的月度滚动(inventory_movements 按 business_date 的月、按单位):期初 · 收货 · 加工产出 · 加工消耗 · 销售 · 注销 · 调整 · 回滚作废 · 搬动 · 期末。没有"对得上"的旗标(期末按构造 = 期初 + 本月之和)。没有业务日期的流水在 month 为空的那一行。基视图,不给人读。';

REVOKE ALL ON public.stock_rollforward_monthly_all FROM authenticated, anon;
