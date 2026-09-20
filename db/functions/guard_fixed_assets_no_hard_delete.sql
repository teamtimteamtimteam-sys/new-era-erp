CREATE OR REPLACE FUNCTION public.guard_fixed_assets_no_hard_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 【自己报名】—— 同 guard_purchase_order_no_hard_delete。靠 fixed_asset_history
    -- 的外键顺带挡下来的那句报错,既不说是哪张卡、也不说规矩;而一张【还没有过
    -- 任何改动】的卡它根本不拦(那时影子表里一行都没有)。
    -- 处置一台机器走 dispose_fixed_asset,它留下 status/disposal_date 与一笔分录。
    RAISE EXCEPTION 'FIXED_ASSET_NO_HARD_DELETE|%', OLD.code;
END;
$function$
