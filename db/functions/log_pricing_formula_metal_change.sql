CREATE OR REPLACE FUNCTION public.log_pricing_formula_metal_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO pricing_formula_history (formula_id, change_type, metal,
                                             old_payable_pct, changed_by)
        VALUES (OLD.formula_id, 'metal_clear', OLD.metal, OLD.payable_pct, auth.uid());
        RETURN NULL;
    ELSIF TG_OP = 'INSERT' THEN
        INSERT INTO pricing_formula_history (formula_id, change_type, metal,
                                             new_payable_pct, changed_by)
        VALUES (NEW.formula_id, 'metal_set', NEW.metal, NEW.payable_pct, auth.uid());
        RETURN NULL;
    END IF;
    IF NEW.payable_pct IS NOT DISTINCT FROM OLD.payable_pct THEN
        RETURN NULL;
    END IF;
    INSERT INTO pricing_formula_history (formula_id, change_type, metal,
                                         old_payable_pct, new_payable_pct, changed_by)
    VALUES (NEW.formula_id, 'metal_set', NEW.metal, OLD.payable_pct, NEW.payable_pct, auth.uid());
    RETURN NULL;
END;
$function$;