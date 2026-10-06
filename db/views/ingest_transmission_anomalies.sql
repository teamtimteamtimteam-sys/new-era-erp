-- db/views/ingest_transmission_anomalies.sql
-- MES-1(2026-10-06,规格 §7「Logged」;MES-1 Step 0 Q19,Tim):【传输上的异常】—— 规格要求"认得出"的那几种。
--   unknown_gateway · bad_key · revoked_key · retired_gateway  每一次被拒的调用(在预算之内一行一行记的那些)
--   too_large · too_many · malformed                           认证过、但传输形状不对的调用
--   overflow                                                   失败到预算之后的溢出桶(10 分钟一行,occurrences = 那一段的次数)
--   seq_reused                                                 收下的调用里,某一条序号带着一份不同的 payload 又来了(Q13)
--   clock_ahead                                                site_to 比服务器收到它的时刻晚 5 分钟以上的那几条(Q13)
--   ☞ "工作时间以外的数据调用"不在这里:工作时间是 V6(班次的起止时刻),还没给 —— /settings/pending-values 列着它。
--     不发明一个数(Q19)。也不设字节阈值。
-- 【属主视图】行谓词在这里再问一次(module.processing.view)。

CREATE VIEW public.ingest_transmission_anomalies WITH (security_invoker = off) AS
 SELECT a.occurred_at,
    a.anomaly,
    a.transmission_id,
    a.inbox_id,
    a.gateway_id,
    a.presented_gateway,
    a.seq,
    a.occurrences,
    a.client_address
   FROM ( SELECT t.received_at AS occurred_at,
            t.result AS anomaly,
            t.id AS transmission_id,
            NULL::bigint AS inbox_id,
            t.gateway_id,
            t.presented_gateway,
            NULL::bigint AS seq,
            1 AS occurrences,
            t.client_address
           FROM ingest_transmissions t
          WHERE t.kind = 'call'::text AND t.result <> 'accepted'::text
        UNION ALL
         SELECT t.bucket_last_at AS occurred_at,
            'overflow'::text AS anomaly,
            t.id AS transmission_id,
            NULL::bigint AS inbox_id,
            NULL::uuid AS gateway_id,
            NULL::text AS presented_gateway,
            NULL::bigint AS seq,
            t.bucket_count AS occurrences,
            NULL::text AS client_address
           FROM ingest_transmissions t
          WHERE t.kind = 'rejected_overflow'::text
        UNION ALL
         SELECT t.received_at AS occurred_at,
            'seq_reused'::text AS anomaly,
            t.id AS transmission_id,
            NULL::bigint AS inbox_id,
            t.gateway_id,
            t.presented_gateway,
            (e.value ->> 'seq'::text)::bigint AS seq,
            1 AS occurrences,
            t.client_address
           FROM ingest_transmissions t,
            LATERAL jsonb_array_elements(t.rejections) e(value)
          WHERE t.kind = 'call'::text AND t.rejections IS NOT NULL AND (e.value ->> 'code'::text) = 'SEQ_REUSED'::text
        UNION ALL
         SELECT b.received_at AS occurred_at,
            'clock_ahead'::text AS anomaly,
            b.transmission_id,
            b.id AS inbox_id,
            b.gateway_id,
            NULL::text AS presented_gateway,
            b.seq,
            1 AS occurrences,
            NULL::text AS client_address
           FROM ingest_inbox b
          WHERE b.clock_ahead) a
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.ingest_transmission_anomalies IS
    'MES-1:传输上的异常 —— 被拒的调用(按理由)、认证过但形状不对的调用、溢出桶、序号带着不同的 payload 又来(seq_reused)、时钟超前的消息。工作时间以外的调用要等 V6(班次时刻)给了才列。行谓词 module.processing.view。';

GRANT SELECT ON public.ingest_transmission_anomalies TO authenticated;
REVOKE ALL ON public.ingest_transmission_anomalies FROM anon;
