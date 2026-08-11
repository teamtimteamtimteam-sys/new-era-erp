CREATE OR REPLACE FUNCTION public.trg_metal_price_anomaly()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【只在 metal / 价格 / 行情日真的变了时重算】判词是【写入那一刻】的记录:
    -- 改个备注、软删一行都不该覆盖它(后来的报价会让重算得出另一个答案)。
    IF TG_OP = 'UPDATE'
       AND NEW.metal = OLD.metal
       AND NEW.price_usd_per_tonne = OLD.price_usd_per_tonne
       AND NEW.price_date = OLD.price_date THEN
        NEW.anomaly_check := OLD.anomaly_check;
        RETURN NEW;
    END IF;

    -- 【永不拒】提醒不是拦截:3 倍的真实行情是可能的,而系统分不出哪一种是哪一种。
    NEW.anomaly_check := metal_price_anomaly(
        NEW.metal, NEW.price_usd_per_tonne, NEW.price_date, NEW.id);
    RETURN NEW;
END;
$function$;