-- db/functions/requeue_supplier_on_identity_change.sql
-- GOLIVE-1 第 4 行(Tim 2026-10-20 d2 #14 · 2026-10-29 Q7):一家【已批准】的供应商改了法定名、税号或类型,它就回到待审,批准戳清空。
--   批的是"这一家";改完之后它可能已经不是那一家。不是拒绝那次改动 —— 改动照存,批准作废,要重新批。
--   「已批准」= approved · active · suspended(带着批准戳的三种状态,Tim Q7)。草稿、待审、驳回、拉黑、归档的改动不动状态。
--   回到待审之后,既有的守卫照常挡住付款与新采购单(guard_po_supplier_approved · payment_request_payee_check)。
-- 【每一条路径都适用】直连改(/suppliers/[id]/edit)、属主路径(批量导入、fixture)一样 —— 一家被换了身份的供应商,
--   不因为是哪一扇门改的就保住批准。
-- 【触发器顺序】挂在 trg_suppliers_zz_requeue_on_identity_change 上,名字排在 trg_suppliers_direct_write(直连写不许改状态 ——
--   它先看,看到的是没变的状态)、trg_suppliers_normalise_identity(先去空白、大写,所以只改大小写或空白不算改)与
--   trg_suppliers_status_transition(跳转图里没有 approved → pending_review 这一步;它先看,也看到没变的状态)之后。
--   状态历史(trg_suppliers_status_history)是 AFTER 触发器,本刀把它从 UPDATE OF status 改成 UPDATE … WHEN 状态变了,
--   所以这一次回待审照样记一行(OF status 只认 SET 列表里写了 status 的语句,而直连改从不写它)。
-- 【比较的是 IS DISTINCT FROM】NULL → 一个税号算改;同值重存不算。
CREATE OR REPLACE FUNCTION public.requeue_supplier_on_identity_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF OLD.status IN ('approved', 'active', 'suspended')
       AND NEW.status = OLD.status
       AND (NEW.legal_name IS DISTINCT FROM OLD.legal_name
            OR NEW.tax_id IS DISTINCT FROM OLD.tax_id
            OR NEW.counterparty_type IS DISTINCT FROM OLD.counterparty_type) THEN
        NEW.status      := 'pending_review';
        NEW.approved_by := NULL;
        NEW.approved_at := NULL;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.requeue_supplier_on_identity_change() IS
'GOLIVE-1 第 4 行(Tim d2 #14 · Q7):approved / active / suspended 的供应商改了 legal_name、tax_id 或 counterparty_type → 回到 pending_review,approved_by / approved_at 清空。每一条路径都适用;挂在 trg_suppliers_zz_requeue_on_identity_change(BEFORE UPDATE,排在直连守卫、身份规整与跳转校验之后)。';
