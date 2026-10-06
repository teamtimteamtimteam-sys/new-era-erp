-- db/functions/assert_receipt_reading_calibrated.sql
-- MES-2(2026-10-06,规格 §8.2;MES-0 Q30;MES-2 Step 0 Q26 · Q27,Tim 的 MES-2 委托书):【校准闸】—— 一张收货单的读数可不可以拿去定价、拿去签证书。
--   调用方:reprice_inbound_batch(每一条收货定价路径都落进来的那一支引擎)· preview_reprice_inbound_batch(与它同一份算术的试算)·
--   issue_cod(销毁证书证的就是这张收货单的数量)。三处问的是同一支函数 —— 一份判据。
--   【开关】ingest_settings.require_calibrated_since:空 = 关 —— 什么都不拒(Tim 的 MES-2 委托书:"nothing refuses when it is NULL";
--     校准状态在页面上照样处处看得见)。开着时,只管【这一天及以后建的】收货单(新加坡日历),更早的照旧。
--   开着、而且管到这一张时,对它挂着的每一张地磅单的【最新】两磅(更正读最新的):
--     · 没有记录仪器        → READING_INSTRUMENT_NOT_RECORDED|<地磅单>|<角色>
--     · 仪器在读数那一天不在校准期内(过期 · 没通过 · 从来没校过)→ READING_INSTRUMENT_NOT_CALIBRATED|<仪器编号>|<读数日期>
--   一张地磅单都没挂 → RECEIPT_READING_NOT_RECORDED|<收货单>。
--   读数那一天的状态来自 weighing_calibration_all(那张基视图里的挑法 + calibration_status_from 那一句判据)。
--   【内层】不是 SECURITY DEFINER、没有调用者检查,EXECUTE 从 authenticated 收回;调用方都是 DEFINER,以属主身份读。STABLE:试算也调它。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.assert_receipt_reading_calibrated(p_inbound_batch_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_since   date;
    v_code    text;
    v_created timestamptz;
    v_n       integer := 0;
    r         record;
BEGIN
    SELECT s.require_calibrated_since INTO v_since FROM ingest_settings s WHERE s.id;
    IF v_since IS NULL THEN
        RETURN;
    END IF;
    SELECT b.code, b.created_at INTO v_code, v_created FROM inbound_batches b WHERE b.id = p_inbound_batch_id;
    IF NOT FOUND OR (v_created AT TIME ZONE 'Asia/Singapore')::date < v_since THEN
        RETURN;
    END IF;
    FOR r IN SELECT t.code AS ticket_code, wc.role, wc.device_code, wc.captured_on, wc.status
               FROM weighbridge_ticket_shares s
               JOIN weighbridge_tickets t ON t.id = s.ticket_id
               JOIN weighing_calibration_all wc ON wc.ticket_id = s.ticket_id AND wc.is_current
              WHERE s.inbound_batch_id = p_inbound_batch_id
              ORDER BY t.code, wc.role LOOP
        v_n := v_n + 1;
        IF r.status = 'not_recorded' THEN
            RAISE EXCEPTION 'READING_INSTRUMENT_NOT_RECORDED|%|%', r.ticket_code, r.role;
        ELSIF r.status <> 'in_calibration' THEN
            RAISE EXCEPTION 'READING_INSTRUMENT_NOT_CALIBRATED|%|%', r.device_code, to_char(r.captured_on, 'YYYY-MM-DD');
        END IF;
    END LOOP;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'RECEIPT_READING_NOT_RECORDED|%', v_code;
    END IF;
END;
$function$;
