CREATE OR REPLACE FUNCTION public.bank_native_currency(p_account_code text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE p_account_code
        WHEN '1000' THEN 'SGD'
        WHEN '1010' THEN 'USD'
    END;
$function$

