CREATE OR REPLACE FUNCTION public.cod_governing_licence(p_completed_on date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_any   integer;
    v_cover integer;
    v_lic   record;
    v_bad   record;
    v_txt   text;
BEGIN
    -- 【完成日期算不出来,不是执照的问题】—— cod_delivery_completion 已经按名拒过
    -- 一次(COMPLETION_DATE_UNKNOWN),这里只是不许自己拿今天顶上。
    IF p_completed_on IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'COD_COMPLETION_DATE_UNKNOWN', 'detail', '');
    END IF;

    -- 候选:非软删、号非空的 GWDF 行。status 与日期【都还没判】—— 判在下面,
    -- 因为"有一行但它不合格"与"压根没有行"是两句不同的话。
    SELECT count(*) INTO v_any
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> '';
    IF v_any = 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'COD_LICENCE_NOT_RECORDED',
                                  'detail', '/purchasing/licences');
    END IF;

    -- 在效且盖住这一天的 active 行有几张?
    SELECT count(*) INTO v_cover
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
       AND cc.status = 'active'
       AND cc.valid_from IS NOT NULL AND cc.valid_until IS NOT NULL
       AND p_completed_on BETWEEN cc.valid_from AND cc.valid_until;

    -- 6 · 两张都盖住 → 有一张录错了。【绝不挑一张】—— 挑就等于替录错的人做主。
    IF v_cover > 1 THEN
        SELECT string_agg(cc.cert_no || ' (' || cc.valid_from::text || ' … ' || cc.valid_until::text || ')',
                          ' / ' ORDER BY cc.valid_from)
          INTO v_txt
          FROM company_compliance cc
         WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
           AND cc.status = 'active'
           AND cc.valid_from IS NOT NULL AND cc.valid_until IS NOT NULL
           AND p_completed_on BETWEEN cc.valid_from AND cc.valid_until;
        RETURN jsonb_build_object('ok', false, 'reason', 'COD_LICENCE_PERIODS_OVERLAP',
                                  'detail', p_completed_on::text || '|' || v_txt);
    END IF;

    -- 【正常那一条】在完成日当天在效的那一行说了算 —— 不是最新的那一行。
    IF v_cover = 1 THEN
        SELECT cc.cert_no, cc.issuing_body, cc.valid_from, cc.valid_until, cc.scope
          INTO v_lic
          FROM company_compliance cc
         WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
           AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
           AND cc.status = 'active'
           AND cc.valid_from IS NOT NULL AND cc.valid_until IS NOT NULL
           AND p_completed_on BETWEEN cc.valid_from AND cc.valid_until;
        RETURN jsonb_build_object('ok', true, 'licence', jsonb_build_object(
            'cert_no', v_lic.cert_no, 'issuing_body', v_lic.issuing_body,
            'valid_from', v_lic.valid_from, 'valid_until', v_lic.valid_until,
            'scope', v_lic.scope));
    END IF;

    -- 一张都没盖住。下面四句把【为什么】说清楚,顺序即内容。
    -- 2 · 有效期缺一端 —— 排在最前,因为"判断不出"不许退化成任何一个答案。
    SELECT cc.cert_no INTO v_bad
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
       AND cc.status = 'active'
       AND (cc.valid_from IS NULL OR cc.valid_until IS NULL)
     LIMIT 1;
    IF FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'COD_LICENCE_DATES_NOT_RECORDED',
                                  'detail', v_bad.cert_no || '|/purchasing/licences');
    END IF;

    -- 3 · 有一行盖住了这一天,但它不是 active(含 status IS NULL:没有人说过)
    SELECT cc.cert_no, cc.status INTO v_bad
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
       AND cc.status IS DISTINCT FROM 'active'
       AND cc.valid_from IS NOT NULL AND cc.valid_until IS NOT NULL
       AND p_completed_on BETWEEN cc.valid_from AND cc.valid_until
     ORDER BY cc.valid_until DESC
     LIMIT 1;
    IF FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'COD_LICENCE_NOT_ACTIVE',
                                  'detail', v_bad.cert_no || '|' || COALESCE(v_bad.status, 'not recorded'));
    END IF;

    -- 4 · 过期了 —— 真正会发生的那一种。两个日期都点名。
    SELECT cc.cert_no, cc.valid_until INTO v_bad
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
       AND cc.status = 'active'
       AND cc.valid_until IS NOT NULL AND cc.valid_until < p_completed_on
     ORDER BY cc.valid_until DESC
     LIMIT 1;
    IF FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'COD_LICENCE_EXPIRED',
                                  'detail', p_completed_on::text || '|' || v_bad.valid_until::text
                                            || '|' || v_bad.cert_no);
    END IF;

    -- 5 · 还没生效 —— 措辞是【数据对不上】,不是业务规则。
    SELECT cc.cert_no, cc.valid_from INTO v_bad
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
       AND cc.status = 'active'
       AND cc.valid_from IS NOT NULL AND cc.valid_from > p_completed_on
     ORDER BY cc.valid_from ASC
     LIMIT 1;
    IF FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'COD_LICENCE_NOT_YET_IN_FORCE',
                                  'detail', p_completed_on::text || '|' || v_bad.valid_from::text
                                            || '|' || v_bad.cert_no);
    END IF;

    -- 兜底:有行,但没有一行是 active 且日期齐全的。等同于"没录"。
    RETURN jsonb_build_object('ok', false, 'reason', 'COD_LICENCE_NOT_RECORDED',
                              'detail', '/purchasing/licences');
END;
$function$;
