-- db/functions/guard_inspection_template_write.sql
-- MES-7b-2(2026-10-16,MES-7b Step 0 Q13,Tim):inspection_templates 与 inspection_template_items 的守卫(语句级,一支函数两张表)——
--   会话里直连的写(row_security_active = 真)按名拒 INSPECTION_TEMPLATE_THROUGH_FUNCTION_ONLY:一张清单与它的检查项只经
--   save_inspection_template 一次存下、按顺序重排(属主路径放行)。
--   删一张清单对谁都按名拒 INSPECTION_TEMPLATE_NOT_DELETABLE —— 巡检指着它;不再用就停用。检查项可以删(经那支函数):巡检抄走了字,不指着它。
--   【语句级】所以 RLS 让一句直连的 UPDATE 一行都碰不到时它照样抛(ALERT-1:被拒的写不许是一次成功的空操作)。
--   【INVOKER】row_security_active 要反映调用者的视角(guard_part_issue_write 同一个理由)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
CREATE OR REPLACE FUNCTION public.guard_inspection_template_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'INSPECTION_TEMPLATE_THROUGH_FUNCTION_ONLY'
          USING HINT = '一张巡检清单与它的检查项在清单页上一次存下。';
    END IF;
    IF TG_OP = 'DELETE' AND TG_TABLE_NAME = 'inspection_templates' THEN
        RAISE EXCEPTION 'INSPECTION_TEMPLATE_NOT_DELETABLE'
          USING HINT = '巡检指着这张清单 —— 不再用就停用它。';
    END IF;
    RETURN NULL;
END;
$function$;
