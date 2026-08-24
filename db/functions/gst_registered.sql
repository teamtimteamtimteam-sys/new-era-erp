-- db/functions/gst_registered.sql
-- GST-1:注册与否。**未注册时行为与建 GST 之前一模一样**,而那不是一句断言:
-- post_journal_entry 在未注册时拒绝带税码的行(GST_NOT_REGISTERED),
-- 于是"没有任何一行带税码"是一件做不到的事,不是一件碰巧没发生的事。

CREATE OR REPLACE FUNCTION public.gst_registered()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE((SELECT gst_registered FROM finance_settings LIMIT 1), false);
$function$;