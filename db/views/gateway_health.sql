-- db/views/gateway_health.sql
-- MES-1(2026-10-06,规格 §6.2;MES-0 Q9 · §3.8;MES-1 Step 0 Q7 · Q16 · Q17,Tim):【网关此刻的状态 —— 读的时候算】。
--   没有调度器,所以"它是不是在沉默"不存在任何地方,每一次读都从传输日志现算:
--     last_call_at       最后一次被收下的数据调用(ingest_transmissions,kind = call,result = accepted)
--     last_heartbeat_at  最后一次心跳(这台网关的 heartbeat_hour 桶里最大的 last_at)
--     last_heard_at      两者里晚的那一个
--   status(按这个顺序判):
--     retired            停用了
--     not_yet_heard      一次都没听到过 —— "Not yet heard from",不上提醒(Q16:登记了、还没调试是正常状态)
--     interval_not_set   心跳间隔没给 —— "Not yet set — silence cannot be judged",不上提醒(Q17)
--     silent             now() − last_heard_at 超过了它的心跳间隔 —— 上提醒(gateway_silent)
--     ok                 其余
-- 【属主视图】读传输日志不过 RLS,所以行谓词在这里再问一次(module.processing.view)。

CREATE VIEW public.gateway_health WITH (security_invoker = off) AS
 SELECT d.id AS gateway_id,
    d.code,
    d.name,
    d.retired_at,
    d.heartbeat_interval_s,
    lc.last_call_at,
    hb.last_heartbeat_at,
    GREATEST(lc.last_call_at, hb.last_heartbeat_at) AS last_heard_at,
    ( SELECT count(*) AS count
           FROM gateway_keys k
          WHERE k.gateway_id = d.id AND k.revoked_at IS NULL) AS active_keys,
        CASE
            WHEN d.retired_at IS NOT NULL THEN 'retired'::text
            WHEN GREATEST(lc.last_call_at, hb.last_heartbeat_at) IS NULL THEN 'not_yet_heard'::text
            WHEN d.heartbeat_interval_s IS NULL THEN 'interval_not_set'::text
            WHEN (now() - GREATEST(lc.last_call_at, hb.last_heartbeat_at)) > make_interval(secs => d.heartbeat_interval_s::double precision) THEN 'silent'::text
            ELSE 'ok'::text
        END AS status
   FROM devices d
     LEFT JOIN LATERAL ( SELECT max(t.received_at) AS last_call_at
           FROM ingest_transmissions t
          WHERE t.kind = 'call'::text AND t.result = 'accepted'::text AND t.gateway_id = d.id) lc ON true
     LEFT JOIN LATERAL ( SELECT max(t.bucket_last_at) AS last_heartbeat_at
           FROM ingest_transmissions t
          WHERE t.kind = 'heartbeat_hour'::text AND t.gateway_id = d.id) hb ON true
  WHERE d.kind = 'gateway'::text AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.gateway_health IS
    'MES-1:网关此刻的状态,读的时候从传输日志算(没有调度器)。status:retired · not_yet_heard(不上提醒)· interval_not_set(Not yet set,不上提醒)· silent(超过心跳间隔,上提醒)· ok。行谓词 module.processing.view。';

GRANT SELECT ON public.gateway_health TO authenticated;
REVOKE ALL ON public.gateway_health FROM anon;
