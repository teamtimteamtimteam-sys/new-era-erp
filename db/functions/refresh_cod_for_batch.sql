CREATE OR REPLACE FUNCTION public.refresh_cod_for_batch(p_inbound_batch_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_done jsonb;
    v_cod  record;
BEGIN
    IF p_inbound_batch_id IS NULL THEN RETURN; END IF;

    v_done := cod_delivery_completion(p_inbound_batch_id);

    SELECT c.id, c.status, c.code INTO v_cod
      FROM certificates_of_destruction c
     WHERE c.inbound_batch_id = p_inbound_batch_id AND c.status <> 'void'
     FOR UPDATE;

    IF (v_done->>'complete')::boolean THEN
        IF v_cod.id IS NULL THEN
            INSERT INTO certificates_of_destruction (inbound_batch_id, completed_on)
            VALUES (p_inbound_batch_id, (v_done->>'completed_on')::date);
        END IF;
        RETURN;
    END IF;

    -- 不再成立了。两种收场,而它们【不是同一件事】:
    IF v_cod.id IS NULL THEN
        RETURN;
    ELSIF v_cod.status = 'pending' THEN
        -- 【从未签发的证书删掉,什么都不消耗】它没有号、没有令牌、没出过这栋楼。
        -- 留着一条"曾经成立过"的空记录,只会让页面上出现一张不能签发的证书。
        DELETE FROM certificates_of_destruction WHERE id = v_cod.id;
    ELSE
        -- 【已签发 → 作废,且【没有替代品】】冲销说的是"这次加工没发生",
        -- 于是这一票货不再是加工完的。将来重新加工到完,那时会成立一张【新的】证书。
        PERFORM void_cod_internal(v_cod.id, 'PROCESSING_REVERSED|' || COALESCE(v_done->>'reason', '?'), NULL);
    END IF;
END;
$function$;
