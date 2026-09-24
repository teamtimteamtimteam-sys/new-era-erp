-- db/functions/log_supplier_status_change.sql
-- ROLE-1 · Batch 2a(Batch 2a grilling Q3):供应商状态的【每一步】都进 supplier_status_history ——
-- 拉黑与恢复也在内。approval_log 只记送审 / 批准 / 驳回(那三步是一次审批);拉黑是 CFO 的
-- 决定却不是一次审批,此前它唯一的痕迹是 updated_by,而下一次随便一个编辑就把它盖掉了。
--
-- 【为什么挂在触发器上,而不是写在 set_supplier_status 里】状态还有属主路径能改
-- (fixture、将来的迁移)。一条"每一步都记"的规矩,只挂在一扇门上就不是每一步。
-- 附注由 set_supplier_status 经事务内设置项 evoltrya.supplier_status_note 交过来;
-- 别的路径没有附注,留 NULL。
--
-- SECURITY DEFINER:变动史没有 INSERT 策略(留痕不该有第二个写法),触发器以属主身份写;
-- changed_by = auth.uid() 仍是按下去的那个人。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.log_supplier_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    INSERT INTO supplier_status_history (supplier_id, from_status, to_status, changed_by, note)
    VALUES (NEW.id, OLD.status::text, NEW.status::text, auth.uid(),
            NULLIF(current_setting('evoltrya.supplier_status_note', true), ''));
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.log_supplier_status_change() IS
'ROLE-1 Batch 2a:供应商状态每变一次,往 supplier_status_history 写一行(从、到、谁、何时、附注)。挂在 AFTER UPDATE OF status 上,所以每一条路径都记。';
