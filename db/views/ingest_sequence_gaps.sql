-- db/views/ingest_sequence_gaps.sql
-- MES-1(2026-10-06,MES-0 Q8;MES-1 Step 0 Q13,Tim):收件箱里【按流】缺了的序号段 —— 列出来,不挡任何东西。
--   一条流(网关每次启动生成一个)里,收下的序号排好之后相邻两个之间的空当,以及第一个之前的空当(一条流从 1 起)。
--   缺的号补上来(网关按序回填)之后那一段就自己消失。
-- 【属主视图】行谓词在这里再问一次(module.processing.view)。

CREATE VIEW public.ingest_sequence_gaps WITH (security_invoker = off) AS
 WITH s AS (
         SELECT b.gateway_id,
            b.stream,
            b.seq,
            lag(b.seq) OVER (PARTITION BY b.gateway_id, b.stream ORDER BY b.seq) AS prev_seq,
            max(b.received_at) OVER (PARTITION BY b.gateway_id, b.stream) AS last_received_at
           FROM ingest_inbox b
          WHERE b.source = 'device'::text
        )
 SELECT s.gateway_id,
    s.stream,
    COALESCE(s.prev_seq, 0::bigint) + 1 AS missing_from,
    s.seq - 1 AS missing_to,
    s.seq - COALESCE(s.prev_seq, 0::bigint) - 1 AS missing_count,
    s.last_received_at
   FROM s
  WHERE s.seq > (COALESCE(s.prev_seq, 0::bigint) + 1) AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.ingest_sequence_gaps IS
    'MES-1:收件箱里按 (网关, 流) 缺了的序号段(含第一个收下的号之前那一段)。只列出来,不挡(MES-0 Q8)。行谓词 module.processing.view。';

GRANT SELECT ON public.ingest_sequence_gaps TO authenticated;
REVOKE ALL ON public.ingest_sequence_gaps FROM anon;
