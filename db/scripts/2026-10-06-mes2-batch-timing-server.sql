-- db/scripts/2026-10-06-mes2-batch-timing-server.sql
-- MES-2 · Q31 的服务端那一半:ingest_submit 处理一批 500 条要多久 —— 量的是【语句本身】,不含上传。
-- 【为什么另有这一支】db/scripts/2026-10-06-mes2-batch-timing.mjs 经 HTTPS 量了四次(三次小批、一次贴着 256 KB),
--   四次都被接受(HTTP 200,accepted 500)—— 所以每一次的服务端执行都【低于】anon 的 3 秒上限(超了会整支回滚、返回错误)。
--   但这台机器那天的出口很慢(一次 HTTPS 往返 ~1 s),贴着上限的那一批客户端墙钟 25 s,几乎全是上传;
--   第五次在网络上失败(fetch failed)。statement_timeout 只计【语句执行】,不计请求体上传,所以精确的数要在库里量。
-- 【怎么量】一笔【整支回滚】的事务:以 admin@ 的 JWT 给探针网关 DEV-2026-0003(MES-2 的 Q31 探针,线上那台)发一把临时钥匙,
--   然后 SET LOCAL ROLE anon,在一个 DO 块里把每一批【在库里】拼好,只把 ingest_submit 那一次调用夹在两次 clock_timestamp() 之间。
--   三批 500 条小消息、三批 500 条贴着上限(每条 pad 401 字符,与 HTTPS 那一批同形);每一批一条新的 stream。
--   ROLLBACK:钥匙、传输日志、收件箱的行一行都不留。
-- 【注意】SET ROLE 不会带上 anon 的 rolconfig(statement_timeout = 3s 只在以 anon 登录时生效),所以这里量的是【时长】,
--   不是"会不会被掐";判据是 Q31 的 1.5 s。
-- 用法:psql -X -v ON_ERROR_STOP=1 -f db/scripts/2026-10-06-mes2-batch-timing-server.sql
BEGIN;
SELECT set_config('request.jwt.claims',
       json_build_object('sub', (SELECT id FROM auth.users WHERE email = 'admin@swm-os.test'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
SELECT set_config('mes2.key', issue_gateway_key((SELECT id FROM devices WHERE code = 'DEV-2026-0003')) ->> 'secret', true) IS NOT NULL AS key_issued;
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
SET LOCAL ROLE anon;
DO $$
DECLARE
    v_body jsonb;
    v_r    jsonb;
    v_t0   timestamptz;
    v_ms   numeric;
    v_pad  int;
    v_kind text;
BEGIN
    FOR v_run IN 1..6 LOOP
        v_pad  := CASE WHEN v_run <= 3 THEN 0 ELSE 401 END;
        v_kind := CASE WHEN v_run <= 3 THEN 'small' ELSE 'near-cap' END;
        SELECT jsonb_build_object('stream', 'server-timing-' || v_run, 'messages', jsonb_agg(jsonb_build_object(
                   'seq', g, 'device', 'DEV-2026-0004', 'class', 'connection_test',
                   'payload', CASE WHEN v_pad = 0 THEN jsonb_build_object('text', 'timing ' || g)
                                   ELSE jsonb_build_object('text', 'timing ' || g, 'pad', repeat('x', v_pad)) END) ORDER BY g))
          INTO v_body FROM generate_series(1, 500) g;
        v_t0 := clock_timestamp();
        v_r  := ingest_submit('DEV-2026-0003', current_setting('mes2.key'), v_body);
        v_ms := round(extract(epoch FROM clock_timestamp() - v_t0) * 1000, 1);
        RAISE NOTICE 'TIMING % run % · % bytes · % ms · ok % · accepted % · rejected %', v_kind, v_run,
            octet_length(v_body::text), v_ms, v_r ->> 'ok', jsonb_array_length(COALESCE(v_r -> 'accepted', '[]')),
            jsonb_array_length(COALESCE(v_r -> 'rejected', '[]'));
    END LOOP;
END $$;
ROLLBACK;
