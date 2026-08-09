CREATE OR REPLACE FUNCTION public.log_customer_credit_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.credit_limit_base IS DISTINCT FROM OLD.credit_limit_base
       OR NEW.credit_hold IS DISTINCT FROM OLD.credit_hold THEN
        INSERT INTO customer_credit_history
            (customer_id, old_credit_limit_base, new_credit_limit_base,
             old_credit_hold, new_credit_hold, changed_by)
        VALUES (NEW.id, OLD.credit_limit_base, NEW.credit_limit_base,
                OLD.credit_hold, NEW.credit_hold, auth.uid());
    END IF;
    RETURN NEW;
END;
$function$;