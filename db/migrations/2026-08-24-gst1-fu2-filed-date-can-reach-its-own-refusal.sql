-- 2026-08-24 GST-1 fu2:让 file_gst_return 的申报日与参考号【可以不传】。
--
-- 【为什么改的是数据库,不是页面】app/finance/gst/actions.ts 抬头写着这一句:
--   "校验【全部】在数据库里 —— 页面不重复判断一遍"。
--   而两个参数没有 DEFAULT,生成出来的类型是必填的 string,页面于是【没有办法】
--   把"没填"这件事送到数据库门口:
--     · 送 '' 会在 PostgREST 那一层 cast 成 date 时炸,得到一个 22007
--       (invalid input syntax for type date),那是一条【没有名字】的错;
--     · 在页面里先判一次空,就等于同一条规矩写了两处 —— 正是那句抬头禁止的形状,
--       也是本仓库付过四次账的形状。
--   给它们 DEFAULT NULL,页面就可以【干脆不传】,由函数体里已经有的那一条
--   具名拒绝答话:GST_FILED_DATE_REQUIRED|code。
--
-- 【函数体一个字没动】只加了两个默认值。参考号仍可为空(它本来就允许 NULL),
-- 申报日仍然必填 —— "必填"由函数体保证,不由参数签名保证。

BEGIN;

CREATE OR REPLACE FUNCTION public.file_gst_return(p_period_id uuid, p_filed_on date DEFAULT NULL, p_reference text DEFAULT NULL)
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

COMMIT;
