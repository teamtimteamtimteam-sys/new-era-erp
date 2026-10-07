-- db/functions/label_print_preview.sql
-- MES-3b(2026-10-07,MES-3b Step 0 Q6,Tim):打印页上的【预览】—— 与 record_label_print 问同一支 label_print_context,只读、什么都不写
--   (一次打开页面不该写:MES-2 §7 决定 10)。拒绝与 label_print_context 一字不差。
--   【调用者检查,两层】外面这一句:三个查看码一个都没有 → 拒(没有人能拿它当一扇随便问的门);
--   里面那一句(label_print_context 第 ②)才是精确的:那样东西【自己的】查看码。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.

CREATE OR REPLACE FUNCTION public.label_print_preview(p_kind text, p_id uuid, p_template text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT (has_permission('module.inbound.view') OR has_permission('module.output.view')
            OR has_permission('module.inventory.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.inventory.view';
    END IF;
    RETURN label_print_context(p_kind, p_id, p_template);
END;
$function$;
