CREATE OR REPLACE FUNCTION public.guard_template_fixed_needs_currency()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_ccy  text;
    v_name text;
    v_tid  uuid;
BEGIN
    IF TG_TABLE_NAME = 'payment_term_template_lines' THEN
        IF NEW.fixed_amount_ccy IS NULL THEN
            RETURN NEW;                      -- 比例腿,与币种无关
        END IF;
        v_tid := NEW.template_id;
    ELSE
        -- 模板头:只在【清空/改动币种】时检查,且只有存在定额腿才拦
        IF NEW.currency IS NOT NULL THEN
            RETURN NEW;
        END IF;
        v_tid := NEW.id;
        IF NOT EXISTS (SELECT 1 FROM payment_term_template_lines l
                        WHERE l.template_id = v_tid AND l.fixed_amount_ccy IS NOT NULL) THEN
            RETURN NEW;
        END IF;
    END IF;

    SELECT t.currency, t.name INTO v_ccy, v_name
    FROM payment_term_templates t WHERE t.id = v_tid;
    IF v_ccy IS NULL THEN
        RAISE EXCEPTION 'TEMPLATE_CURRENCY_REQUIRED|%', COALESCE(v_name, v_tid::text);
    END IF;
    RETURN NEW;
END;
$function$;