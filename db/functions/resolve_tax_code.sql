CREATE OR REPLACE FUNCTION public.resolve_tax_code(p_override text, p_default text, p_side text, p_subject text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_code text; v_side text; v_active boolean;
BEGIN
    v_code := COALESCE(NULLIF(btrim(COALESCE(p_override, '')), ''), p_default);
    IF v_code IS NULL THEN
        -- 【这不是"没有税",是"没有人回答过"】两者在 F5 上完全不同:
        -- 一个 0 会安静地进表,一个拒绝会把问题交还给能回答它的人。
        RAISE EXCEPTION 'TAX_CODE_REQUIRED|%', p_subject
          USING HINT = '给这个往来对象设一个默认税码,或在这张单据上指定一个';
    END IF;
    SELECT side, is_active INTO v_side, v_active FROM tax_codes WHERE code = v_code;
    IF v_side IS NULL THEN
        RAISE EXCEPTION 'TAX_CODE_UNKNOWN|%', v_code;
    END IF;
    IF NOT v_active THEN
        RAISE EXCEPTION 'TAX_CODE_INACTIVE|%', v_code;
    END IF;
    IF v_side <> p_side THEN
        -- 挂反了的码照样算得出数,却会进一个它根本不该进的格。
        RAISE EXCEPTION 'TAX_CODE_WRONG_SIDE|%|%', v_code, p_side;
    END IF;
    RETURN v_code;
END;
$function$
;