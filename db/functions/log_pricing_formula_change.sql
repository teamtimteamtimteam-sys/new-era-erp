CREATE OR REPLACE FUNCTION public.log_pricing_formula_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_type text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO pricing_formula_history (
            formula_id, change_type,
            new_name, new_direction, new_price_basis, new_average_days,
            new_treatment_charge_usd_per_tonne, new_flat_discount_pct, new_is_active,
            changed_by)
        VALUES (NEW.id, 'create',
            NEW.name, NEW.direction, NEW.price_basis, NEW.average_days,
            NEW.treatment_charge_usd_per_tonne, NEW.flat_discount_pct, NEW.is_active,
            auth.uid());
        RETURN NULL;
    END IF;

    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        v_type := 'delete';
    ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
        v_type := 'restore';
    ELSIF (OLD.name, OLD.direction, OLD.price_basis, OLD.average_days,
           OLD.treatment_charge_usd_per_tonne, OLD.flat_discount_pct, OLD.is_active,
           OLD.supplier_id, OLD.customer_id, OLD.notes)
          IS DISTINCT FROM
          (NEW.name, NEW.direction, NEW.price_basis, NEW.average_days,
           NEW.treatment_charge_usd_per_tonne, NEW.flat_discount_pct, NEW.is_active,
           NEW.supplier_id, NEW.customer_id, NEW.notes) THEN
        v_type := 'update';
    ELSE
        -- 只碰了 updated_at/updated_by:不是一次编辑,不留行(否则历史会被噪音淹掉)
        RETURN NULL;
    END IF;

    INSERT INTO pricing_formula_history (
        formula_id, change_type,
        old_name, new_name, old_direction, new_direction,
        old_price_basis, new_price_basis, old_average_days, new_average_days,
        old_treatment_charge_usd_per_tonne, new_treatment_charge_usd_per_tonne,
        old_flat_discount_pct, new_flat_discount_pct,
        old_is_active, new_is_active, changed_by)
    VALUES (NEW.id, v_type,
        OLD.name, NEW.name, OLD.direction, NEW.direction,
        OLD.price_basis, NEW.price_basis, OLD.average_days, NEW.average_days,
        OLD.treatment_charge_usd_per_tonne, NEW.treatment_charge_usd_per_tonne,
        OLD.flat_discount_pct, NEW.flat_discount_pct,
        OLD.is_active, NEW.is_active, auth.uid());
    RETURN NULL;
END;
$function$;