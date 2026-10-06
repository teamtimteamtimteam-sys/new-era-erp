-- db/functions/ingest_submit.sql
-- MES-1(2026-10-06,规格 §6 · §7;MES-0 Q4–Q9 · §3.3;MES-1 Step 0 Q4–Q11 · Q13 · Q15 · Q18,Tim):
-- ★★★ 网关唯一够得着的东西 —— 本库第二支、也是最后一支 anon 可执行的函数 ★★★
--
-- 【调法】POST https://<项目>.supabase.co/rest/v1/rpc/ingest_submit,body {p_gateway, p_key, p_body}。
--   给厂商的完整写法在 docs/integration/gateway-interface.md。VOLATILE,所以 PostgREST 只收 POST —— 钥匙永远不进网址。
-- 【它的"权限"是什么】持有那把钥匙:'ngk_' + 64 个十六进制字符(两个 gen_random_uuid,244 位随机)。这里只比哈希:
--   sha256(钥匙的 UTF-8 字节)= gateway_keys.key_hash,而且那把钥匙属于【报上来的那台网关】、没撤、网关没停用。
--   cod_verification 同一个道理:匿名的入口不问 has_permission,它的门就是那个随机值。
-- 【它碰得到什么 —— 白名单,不是减法】
--   读:ingest_settings(上限)· devices(报上来的网关与它带着的设备)· gateway_keys(哈希比对)· ingest_data_classes(类在不在)·
--       ingest_transmissions(失败预算的两次计数、最后一次听到)· ingest_inbox(同一个 (网关, 流, 序号) 来过没有)。
--   写:【只插入】ingest_transmissions · ingest_inbox · gateway_outages;唯一的 UPDATE 是两种桶上的四个计数列(Q8 · Q9,
--       守卫只认本函数设的事务级标记)。devices 一行都不改(Q7)。不跑任何转换代码(Q11)—— 收下的消息停在 received。
--   回:只回调用者自己的序号与固定的码 —— {ok, accepted, duplicates, rejected, code};一个字的表内容都不回。没有反向通道(规格 §7)。
-- 【拒绝只有一句话】(Q10)不认识的网关、错的钥匙、撤了的钥匙、停用的网关 —— 一律 {"ok": false, "code": "refused"};
--   确切理由只在传输日志里、设备页上。分得开就是让人试出哪些网关编号存在。
--   传输上的毛病(太大、太多、形状不对)是网关自己能改的事,所以照名回:too_large · too_many · malformed —— 但只回给【认证过】
--   的调用者;一个没认证的调用者不管送来什么,都只得到 refused。
-- 【失败预算】(Q9)每一次失败都记一行 —— 直到:报上来的同一个编号在滚动窗口(600 秒)里失败了 30 次,或全部失败调用到了 300 次;
--   之后的失败只在 10 分钟一行的溢出桶里计数。答案不变(仍是 refused)。持【有效钥匙】的调用永远不被它限:先认证,
--   认证过的就不看预算(与 cod_verification 有效令牌永不被限流同一条 —— 攻击者拿不出有效钥匙,所以他限不掉任何一台真网关)。
-- 【永不 RAISE 一次认证失败】那会把日志那一行一起回滚 —— 失败必须留下痕迹(规格 §7「Logged」)。
-- 【心跳】{"heartbeat": true}:只让这台网关这一小时的那一行桶往上长(Q8),不落收件箱。
-- 【中断】(MES-0 Q9)认证过、而且这一次会被收下的调用,若上一次听到它已经超过它的心跳间隔,先记一行 gateway_outages。
--   间隔没给(Not yet set)就不记。
-- 【一条消息】{seq, device, class, payload, site_from?, site_to?, dataset_ref?}。信封错(Q15)退回、不落行:
--   ENVELOPE_INVALID · DEVICE_NOT_ON_THIS_GATEWAY(设备不存在、停用了、或不是这台网关带着的 —— 一个码,Q6)· CLASS_UNKNOWN ·
--   SEQ_REUSED(同一个 (网关, 流, 序号) 已经收过一份【不同】的 payload,Q13)。同一份再来 = duplicates。
--   内容(payload 里面)对不对不在这里判 —— 那是转换的事,失败看得见(Q15)。
-- 【并发】同一台网关的调用按顾问锁排队,于是"这个序号来过没有"问的是一个不会在中途变的答案。
-- 【调用方地址】(Q18)PostgREST 把请求头放在 request.headers 里;X-Forwarded-For 原样存下(未经核实),拿不到就是 not available。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.ingest_submit(p_gateway text, p_key text, p_body jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    c_overflow_s constant integer := 600;
    s            ingest_settings%ROWTYPE;
    v_now        timestamptz := clock_timestamp();
    v_code       text := NULLIF(left(btrim(COALESCE(p_gateway, '')), 64), '');
    v_bytes      integer := COALESCE(octet_length(p_body::text), 0);
    v_prefix     text;
    v_addr       text;
    v_gw         devices%ROWTYPE;
    v_found      boolean := false;
    v_key_id     uuid;
    v_revoked    boolean;
    v_result     text;
    v_msgs       jsonb;
    v_stream     text;
    v_n_all      integer;
    v_n_code     integer;
    v_last       timestamptz;
    v_tid        bigint;
    v_i          integer;
    v_m          jsonb;
    v_seq        bigint;
    v_dev        uuid;
    v_from       timestamptz;
    v_to         timestamptz;
    v_ref        text;
    v_sha        bytea;
    v_prior      bytea;
    v_err        text;
    v_seen       jsonb := '{}'::jsonb;
    v_ok         jsonb := '[]'::jsonb;
    v_acc        jsonb := '[]'::jsonb;
    v_dup        jsonb := '[]'::jsonb;
    v_rej        jsonb := '[]'::jsonb;
BEGIN
    SELECT * INTO s FROM ingest_settings WHERE id;

    BEGIN
        v_addr := left(NULLIF(btrim(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for'), ''), 200);
    EXCEPTION WHEN OTHERS THEN
        v_addr := NULL;
    END;
    v_addr := COALESCE(v_addr, 'not available');
    IF p_key ~ '^ngk_[0-9a-f]{8}' THEN
        v_prefix := substr(p_key, 5, 8);
    END IF;

    -- ── ① 认证:先认证,认证过的不看失败预算 ─────────────────────────────────
    IF v_code IS NOT NULL THEN
        SELECT d.* INTO v_gw FROM devices d WHERE d.code = v_code AND d.kind = 'gateway';
        v_found := FOUND;
    END IF;
    IF NOT v_found THEN
        v_result := 'unknown_gateway';
    ELSE
        SELECT k.id, k.revoked_at IS NOT NULL INTO v_key_id, v_revoked
          FROM gateway_keys k
         WHERE k.gateway_id = v_gw.id AND k.key_hash = sha256(convert_to(COALESCE(p_key, ''), 'UTF8'));
        IF v_gw.retired_at IS NOT NULL THEN
            v_result := 'retired_gateway';
        ELSIF v_key_id IS NULL THEN
            v_result := 'bad_key';
        ELSIF v_revoked THEN
            v_result := 'revoked_key';
        END IF;
    END IF;

    -- ── ② 认证过的调用:形状与上限 ─────────────────────────────────────────
    IF v_result IS NULL THEN
        IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN
            v_result := 'malformed';
        ELSIF v_bytes > s.max_payload_bytes THEN
            v_result := 'too_large';
        ELSIF p_body ? 'heartbeat' THEN
            IF p_body -> 'heartbeat' IS DISTINCT FROM 'true'::jsonb OR p_body ? 'messages' THEN
                v_result := 'malformed';
            END IF;
        ELSE
            v_msgs := p_body -> 'messages';
            v_stream := p_body ->> 'stream';
            IF jsonb_typeof(v_msgs) IS DISTINCT FROM 'array' OR jsonb_array_length(v_msgs) = 0
               OR jsonb_typeof(p_body -> 'stream') IS DISTINCT FROM 'string'
               OR char_length(v_stream) NOT BETWEEN 1 AND 64 THEN
                v_result := 'malformed';
            ELSIF jsonb_array_length(v_msgs) > s.max_messages THEN
                v_result := 'too_many';
            END IF;
        END IF;
    END IF;

    -- ── ③ 失败:记下来(预算之内一行一行,超了就进溢出桶),回一句固定的话 ────────
    IF v_result IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtext('ingest_transmissions:failures')::bigint);
        SELECT count(*), count(*) FILTER (WHERE t.presented_gateway IS NOT DISTINCT FROM v_code)
          INTO v_n_all, v_n_code
          FROM ingest_transmissions t
         WHERE t.kind = 'call' AND t.result <> 'accepted'
           AND t.received_at >= v_now - make_interval(secs => s.fail_window_s);
        IF v_n_all >= s.global_reject_budget OR v_n_code >= s.fail_budget THEN
            PERFORM set_config('evoltrya.ingest_ctx', 'ingest_submit', true);
            INSERT INTO ingest_transmissions (kind, received_at, bucket_start, bucket_count, bucket_bytes, bucket_first_at, bucket_last_at)
            VALUES ('rejected_overflow', v_now,
                    to_timestamp(floor(EXTRACT(EPOCH FROM v_now) / c_overflow_s) * c_overflow_s), 1, v_bytes, v_now, v_now)
            ON CONFLICT (bucket_start) WHERE kind = 'rejected_overflow'
            DO UPDATE SET bucket_count   = ingest_transmissions.bucket_count + 1,
                          bucket_bytes   = ingest_transmissions.bucket_bytes + EXCLUDED.bucket_bytes,
                          bucket_last_at = GREATEST(ingest_transmissions.bucket_last_at, EXCLUDED.bucket_last_at);
            PERFORM set_config('evoltrya.ingest_ctx', '', true);
        ELSE
            INSERT INTO ingest_transmissions (kind, received_at, presented_gateway, gateway_id, presented_key_prefix, result,
                                              bytes, client_address)
            VALUES ('call', v_now, v_code, CASE WHEN v_found THEN v_gw.id END, v_prefix, v_result, v_bytes, v_addr);
        END IF;
        IF v_result IN ('malformed', 'too_large', 'too_many') THEN
            RETURN jsonb_build_object('ok', false, 'code', v_result);
        END IF;
        RETURN jsonb_build_object('ok', false, 'code', 'refused');
    END IF;

    -- ── ④ 认证过、形状对:同一台网关排队;回来之前沉默太久就记一段中断 ─────────
    PERFORM pg_advisory_xact_lock(hashtext('ingest:' || v_gw.id::text)::bigint);
    SELECT GREATEST(
               (SELECT max(t.received_at) FROM ingest_transmissions t
                 WHERE t.kind = 'call' AND t.result = 'accepted' AND t.gateway_id = v_gw.id),
               (SELECT max(t.bucket_last_at) FROM ingest_transmissions t
                 WHERE t.kind = 'heartbeat_hour' AND t.gateway_id = v_gw.id))
      INTO v_last;
    IF v_gw.heartbeat_interval_s IS NOT NULL AND v_last IS NOT NULL
       AND v_now - v_last > make_interval(secs => v_gw.heartbeat_interval_s) THEN
        INSERT INTO gateway_outages (gateway_id, silent_from, silent_to, interval_s)
        VALUES (v_gw.id, v_last, v_now, v_gw.heartbeat_interval_s);
    END IF;

    -- ── ⑤ 心跳:只让这一小时的桶往上长 ──────────────────────────────────────
    IF p_body ? 'heartbeat' THEN
        PERFORM set_config('evoltrya.ingest_ctx', 'ingest_submit', true);
        INSERT INTO ingest_transmissions (kind, received_at, gateway_id, bucket_start, bucket_count, bucket_bytes,
                                          bucket_first_at, bucket_last_at)
        VALUES ('heartbeat_hour', v_now, v_gw.id, date_trunc('hour', v_now), 1, v_bytes, v_now, v_now)
        ON CONFLICT (gateway_id, bucket_start) WHERE kind = 'heartbeat_hour'
        DO UPDATE SET bucket_count   = ingest_transmissions.bucket_count + 1,
                      bucket_bytes   = ingest_transmissions.bucket_bytes + EXCLUDED.bucket_bytes,
                      bucket_last_at = GREATEST(ingest_transmissions.bucket_last_at, EXCLUDED.bucket_last_at);
        PERFORM set_config('evoltrya.ingest_ctx', '', true);
        RETURN jsonb_build_object('ok', true);
    END IF;

    -- ── ⑥ 逐条看信封 ────────────────────────────────────────────────────────
    FOR v_i IN 0 .. jsonb_array_length(v_msgs) - 1 LOOP
        v_m := v_msgs -> v_i;
        v_seq := NULL; v_dev := NULL; v_from := NULL; v_to := NULL; v_ref := NULL; v_err := NULL;
        IF jsonb_typeof(v_m) IS DISTINCT FROM 'object' OR jsonb_typeof(v_m -> 'seq') IS DISTINCT FROM 'number'
           OR (v_m ->> 'seq') !~ '^[1-9][0-9]{0,17}$' THEN
            v_err := 'ENVELOPE_INVALID';
        ELSE
            v_seq := (v_m ->> 'seq')::bigint;
            IF NOT (v_m ? 'payload') OR jsonb_typeof(v_m -> 'device') IS DISTINCT FROM 'string'
               OR jsonb_typeof(v_m -> 'class') IS DISTINCT FROM 'string'
               OR (v_m ? 'dataset_ref' AND jsonb_typeof(v_m -> 'dataset_ref') IS DISTINCT FROM 'string')
               OR char_length(COALESCE(v_m ->> 'dataset_ref', '')) > 200 THEN
                v_err := 'ENVELOPE_INVALID';
            END IF;
        END IF;
        IF v_err IS NULL THEN
            BEGIN
                v_from := (v_m ->> 'site_from')::timestamptz;
                v_to := (v_m ->> 'site_to')::timestamptz;
            EXCEPTION WHEN OTHERS THEN
                v_err := 'ENVELOPE_INVALID';
            END;
            IF v_err IS NULL AND v_from > v_to THEN
                v_err := 'ENVELOPE_INVALID';
            END IF;
        END IF;
        IF v_err IS NULL THEN
            SELECT d.id INTO v_dev FROM devices d
             WHERE d.code = v_m ->> 'device' AND d.gateway_id = v_gw.id AND d.retired_at IS NULL;
            IF v_dev IS NULL THEN
                v_err := 'DEVICE_NOT_ON_THIS_GATEWAY';
            ELSIF NOT EXISTS (SELECT 1 FROM ingest_data_classes c WHERE c.code = v_m ->> 'class' AND c.is_active) THEN
                v_err := 'CLASS_UNKNOWN';
            END IF;
        END IF;
        IF v_err IS NULL THEN
            v_sha := sha256(convert_to((v_m -> 'payload')::text, 'UTF8'));
            v_prior := decode(v_seen ->> v_seq::text, 'hex');
            IF v_prior IS NULL THEN
                SELECT b.payload_sha256 INTO v_prior FROM ingest_inbox b
                 WHERE b.source = 'device' AND b.gateway_id = v_gw.id AND b.stream = v_stream AND b.seq = v_seq;
            END IF;
            IF v_prior IS NOT NULL THEN
                IF v_prior = v_sha THEN
                    v_dup := v_dup || to_jsonb(v_seq);
                    CONTINUE;
                END IF;
                v_err := 'SEQ_REUSED';
            END IF;
        END IF;
        IF v_err IS NOT NULL THEN
            v_rej := v_rej || jsonb_build_array(jsonb_build_object('index', v_i, 'seq', v_seq, 'code', v_err));
            CONTINUE;
        END IF;
        v_seen := v_seen || jsonb_build_object(v_seq::text, encode(v_sha, 'hex'));
        v_acc := v_acc || to_jsonb(v_seq);
        v_ok := v_ok || jsonb_build_array(jsonb_build_object(
            'seq', v_seq, 'device_id', v_dev, 'class', v_m ->> 'class', 'payload', v_m -> 'payload',
            'sha', encode(v_sha, 'hex'), 'from', v_from, 'to', v_to, 'ref', v_m ->> 'dataset_ref'));
    END LOOP;

    -- ── ⑦ 一次调用一行,然后收下的那几条各一行 ────────────────────────────────
    INSERT INTO ingest_transmissions (kind, received_at, presented_gateway, gateway_id, presented_key_prefix, result, bytes,
                                      message_count, accepted_count, duplicate_count, rejected_count, stream, first_seq, last_seq,
                                      rejections, client_address)
    VALUES ('call', v_now, v_code, v_gw.id, v_prefix, 'accepted', v_bytes, jsonb_array_length(v_msgs),
            jsonb_array_length(v_acc), jsonb_array_length(v_dup), jsonb_array_length(v_rej), v_stream,
            (SELECT min(x::bigint) FROM jsonb_array_elements_text(v_acc) x),
            (SELECT max(x::bigint) FROM jsonb_array_elements_text(v_acc) x),
            CASE WHEN jsonb_array_length(v_rej) > 0 THEN v_rej END, v_addr)
    RETURNING id INTO v_tid;

    INSERT INTO ingest_inbox (transmission_id, source, gateway_id, stream, seq, device_id, data_class, payload, payload_bytes,
                              payload_sha256, site_from, site_to, site_dataset_ref, clock_ahead, received_at)
    SELECT v_tid, 'device', v_gw.id, v_stream, (o ->> 'seq')::bigint, (o ->> 'device_id')::uuid, o ->> 'class', o -> 'payload',
           octet_length((o -> 'payload')::text), decode(o ->> 'sha', 'hex'),
           (o ->> 'from')::timestamptz, (o ->> 'to')::timestamptz, o ->> 'ref',
           COALESCE((o ->> 'to')::timestamptz > v_now + make_interval(secs => s.clock_ahead_s), false), v_now
      FROM jsonb_array_elements(v_ok) o;

    RETURN jsonb_build_object('ok', true, 'accepted', v_acc, 'duplicates', v_dup, 'rejected', v_rej);
END;
$function$;
