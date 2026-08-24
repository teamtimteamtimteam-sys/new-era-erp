-- db/functions/file_gst_return.sql
-- GST-1:记录一次申报。**申报本身在 IRAS 网站上做,这里只记录**报了什么、
-- 什么时候报的、谁报的。
-- ★【与会计期间锁的关系,就是这一支里的那一句】★ 两者不是同一件事(会计锁按月,
-- GST 期间按季),但一份"已申报"而底下分录还能改的申报是一句假话 ——
-- 所以申报的前置条件是 locked_before > period_end,拒绝有名字:GST_PERIOD_NOT_LOCKED。
-- 申报的同时把每一格【抄下来】进 gst_return_boxes:此后底下的数据再动,那一份也不动。

-- 【p_filed_on / p_reference 有 DEFAULT NULL,不是因为它们可选】(GST-1-fu2)
-- 申报日仍然必填 —— 但"必填"由函数体那一条具名拒绝保证,不由参数签名保证。
-- 没有默认值时,生成出来的 TS 类型是必填的 string,页面【没有办法】把"没填"
-- 送到这里:送 '' 会在 cast 成 date 时炸出一个没有名字的 22007,
-- 而在页面里先判一次空就成了同一条规矩的第二处实现。


CREATE OR REPLACE FUNCTION public.file_gst_return(p_period_id uuid, p_filed_on date DEFAULT NULL::date, p_reference text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p gst_periods%ROWTYPE;
    v_locked date;
    v_return jsonb;
    v_box jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_p FROM gst_periods WHERE id = p_period_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'GST_PERIOD_NOT_FOUND|%', p_period_id; END IF;
    IF v_p.status <> 'open' THEN
        RAISE EXCEPTION 'GST_PERIOD_ALREADY_FILED|%|%', v_p.code, v_p.filed_on;
    END IF;
    IF p_filed_on IS NULL THEN RAISE EXCEPTION 'GST_FILED_DATE_REQUIRED|%', v_p.code; END IF;

    -- ★【GST 期间与会计锁的关系,就是这一句】★
    -- 两者不是同一件事,但一份"已申报"而底下分录还能改的申报是一句假话。
    -- 所以申报要求那一季的每一个月都已经关账。
    SELECT locked_before INTO v_locked FROM finance_settings LIMIT 1;
    IF v_locked IS NULL OR v_locked <= v_p.period_end THEN
        RAISE EXCEPTION 'GST_PERIOD_NOT_LOCKED|%|%|%',
            v_p.code, v_p.period_end, COALESCE(v_locked::text,'(未设)');
    END IF;

    -- 【把当时算出来的每一格抄下来】此后底下的数据再动,这一份也不动。
    v_return := f5_return(v_p.period_start, v_p.period_end);
    FOR v_box IN SELECT * FROM jsonb_array_elements(v_return->'boxes') LOOP
        INSERT INTO gst_return_boxes (period_id, box, label_en, label_zh, value_base)
        VALUES (p_period_id, v_box->>'box', v_box->>'label_en', v_box->>'label_zh',
                (v_box->>'value')::numeric);
    END LOOP;

    UPDATE gst_periods
       SET status='filed', filed_at=now(), filed_by=auth.uid(),
           filed_on=p_filed_on, filed_reference=p_reference
     WHERE id = p_period_id;

    RETURN jsonb_build_object('gst_period_id', p_period_id, 'code', v_p.code,
                              'filed_on', p_filed_on, 'reference', p_reference,
                              'boxes', v_return->'boxes');
END;
$function$;