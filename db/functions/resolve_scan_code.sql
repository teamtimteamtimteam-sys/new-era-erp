-- db/functions/resolve_scan_code.sql
-- MES-3b(2026-10-07,MES-0 Q28 · Q29;MES-3b Step 0 Q9 · Q18–Q20,Tim):【扫到的这一串是什么】—— 每一个扫码框、每一条短链接都问它,
--   页面自己从不判断身份。
--   认得四种写法(Q18):
--     · 光秃秃的编号(两头的空白、制表符、回车换行先去掉 —— 扫码枪打完一串会补一个回车):IN-2026-0012 · OUT-2026-0381 · 一个库位号(先认批次,再认库位;批号不分大小写,库位号先精确、再不分大小写且唯一);
--     · 短链接:…/b/<批号>(只认批次)· …/loc/<库位号>(只认库位)—— 有没有域名都行,%xx 会被解开;
--     · 旧标签上的地址:…/inbound/<uuid>/edit · …/output/<uuid>/edit(Q9:已经印出去的标签照样能用)。
--   四种结果(Q19),【只返回、从不抛】—— 扫码日志那一行因此一定留得下(ingest_submit / cod_verification 同一个理由):
--     found       认出来了,而且你看得见 → 种类、编号、id(库位另带在不在用、是不是隔离库位);
--     restricted  认出来了,你看不见 → 种类、编号、要哪个码 ——【不给 id】(Q19);
--     unknown     没有这个编号(批次已删也算);
--     unreadable  一个字都没有、或者解析不了。
--   没登录(auth.uid() 为空)→ signed_out,不记日志(scanned_by 必填;没登录的人走不到这里 —— 中间件先把他送去登录)。
--   每一次(除 signed_out)写一行 scan_events:场合、方式、原文(截到 500 字)、解析出的编号、结果;id 只在 found 时记。
--   【门】谁都能问(结果本身按码分);看得见什么由那样东西自己的查看码定:进料 module.inbound.view · 产出 module.output.view ·
--   库位 module.inventory.view(与 label_print_context 同一张表)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.

CREATE OR REPLACE FUNCTION public.resolve_scan_code(p_value text, p_context text DEFAULT 'lookup'::text, p_method text DEFAULT 'keyboard'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_raw     text := left(COALESCE(p_value, ''), 500);
    v_ctx     text := CASE WHEN p_context IN ('lookup', 'receipt', 'transfer', 'feed', 'reserve', 'ship') THEN p_context ELSE 'lookup' END;
    v_method  text := CASE WHEN p_method IN ('keyboard', 'camera', 'link') THEN p_method ELSE 'keyboard' END;
    v         text := btrim(COALESCE(p_value, ''), E' \t\r\n');
    m         text[];
    v_hint    text;           -- 'b' · 'loc' · 'id_in' · 'id_out' · NULL(光秃秃的编号)
    v_code    text;
    v_kind    text;
    v_id      uuid;
    v_found   text;           -- 认出来的编号(库里的写法)
    v_need    text;
    v_outcome text;
    v_extra   jsonb := '{}'::jsonb;
    v_scan    bigint;
    r         record;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('outcome', 'signed_out');
    END IF;

    BEGIN
        -- ── 解析 ──
        m := regexp_match(v, '/(b|loc)/([^/?#[:space:]]+)/?([?#].*)?$');
        IF m IS NOT NULL THEN
            v_hint := m[1];
            SELECT convert_from(string_agg(CASE WHEN t.tok ~ '^%[0-9A-Fa-f]{2}$' THEN decode(substr(t.tok, 2), 'hex')
                                                ELSE convert_to(t.tok, 'UTF8') END, ''::bytea ORDER BY t.ord), 'UTF8')
              INTO v_code
              FROM regexp_matches(m[2], '%[0-9A-Fa-f]{2}|[^%]+|%', 'g') WITH ORDINALITY AS t0(mm, ord)
              CROSS JOIN LATERAL (SELECT t0.mm[1] AS tok, t0.ord) t;
        ELSE
            m := regexp_match(v, '/(inbound|output)/([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})(/[a-z]*)?/?([?#].*)?$');
            IF m IS NOT NULL THEN
                v_hint := CASE m[1] WHEN 'inbound' THEN 'id_in' ELSE 'id_out' END;
                v_id := lower(m[2])::uuid;
            ELSE
                v_code := v;
            END IF;
        END IF;
        v_code := NULLIF(btrim(v_code, E' \t\r\n'), '');

        IF v_code IS NULL AND v_id IS NULL THEN
            v_outcome := 'unreadable';
        ELSE
            -- ── 认 ──
            IF v_hint = 'id_in' THEN
                SELECT b.code INTO v_found FROM inbound_batches b WHERE b.id = v_id AND b.deleted_at IS NULL;
                IF FOUND THEN v_kind := 'inbound_batch'; ELSE v_id := NULL; END IF;
            ELSIF v_hint = 'id_out' THEN
                SELECT b.code INTO v_found FROM output_batches b WHERE b.id = v_id AND b.deleted_at IS NULL;
                IF FOUND THEN v_kind := 'output_batch'; ELSE v_id := NULL; END IF;
            END IF;
            IF v_kind IS NULL AND v_code IS NOT NULL AND v_hint IS DISTINCT FROM 'loc' THEN
                SELECT b.id, b.code INTO v_id, v_found FROM inbound_batches b
                 WHERE upper(b.code) = upper(v_code) AND b.deleted_at IS NULL LIMIT 1;
                IF FOUND THEN
                    v_kind := 'inbound_batch';
                ELSE
                    SELECT b.id, b.code INTO v_id, v_found FROM output_batches b
                     WHERE upper(b.code) = upper(v_code) AND b.deleted_at IS NULL LIMIT 1;
                    IF FOUND THEN v_kind := 'output_batch'; END IF;
                END IF;
            END IF;
            IF v_kind IS NULL AND v_code IS NOT NULL AND v_hint IS DISTINCT FROM 'b' THEN
                SELECT l.id, l.code, l.is_active, l.is_quarantine INTO r FROM storage_locations l WHERE l.code = v_code;
                IF NOT FOUND THEN
                    SELECT l.id, l.code, l.is_active, l.is_quarantine INTO r FROM storage_locations l
                     WHERE lower(l.code) = lower(v_code)
                       AND (SELECT count(*) FROM storage_locations l2 WHERE lower(l2.code) = lower(v_code)) = 1;
                END IF;
                IF FOUND THEN
                    v_kind := 'storage_location'; v_found := r.code; v_id := r.id;
                    v_extra := jsonb_build_object('is_active', r.is_active, 'is_quarantine', r.is_quarantine);
                END IF;
            END IF;

            IF v_kind IS NULL THEN
                v_outcome := 'unknown';
                v_extra := '{}'::jsonb;
            ELSE
                v_need := CASE v_kind WHEN 'inbound_batch' THEN 'module.inbound.view'
                                      WHEN 'output_batch' THEN 'module.output.view'
                                      ELSE 'module.inventory.view' END;
                IF has_permission(v_need) THEN
                    v_outcome := 'found';
                ELSE
                    v_outcome := 'restricted';
                    v_id := NULL;
                    v_extra := '{}'::jsonb;
                END IF;
            END IF;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_outcome := 'unreadable'; v_kind := NULL; v_id := NULL; v_found := NULL; v_need := NULL; v_extra := '{}'::jsonb;
    END;

    INSERT INTO scan_events (scanned_by, context, method, raw_value, parsed_code, resolved_kind, resolved_id, outcome)
    VALUES (auth.uid(), v_ctx, v_method, v_raw, COALESCE(v_found, v_code), v_kind,
            CASE WHEN v_outcome = 'found' THEN v_id END, v_outcome)
    RETURNING id INTO v_scan;

    RETURN jsonb_build_object(
        'outcome', v_outcome,
        'kind', v_kind,
        'code', COALESCE(v_found, v_code),
        'id', CASE WHEN v_outcome = 'found' THEN v_id END,
        'needs', CASE WHEN v_outcome = 'restricted' THEN v_need END,
        'scan_id', v_scan) || v_extra;
END;
$function$;
