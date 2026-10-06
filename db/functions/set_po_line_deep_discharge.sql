-- db/functions/set_po_line_deep_discharge.sql
-- U1-B(2026-10-05,UNBLOCK-1 Q20 · AT0-DEEP-DISCHARGE-DIRECT-UPDATE):给采购单的一行写下【买的时候】的深度放电判断。
--
-- 【为什么要一支函数】APR-10 起 purchase_order_lines 只经函数写(guard_po_direct_write 对每一个带 RLS 的调用者
--   按名拒 PO_THROUGH_FUNCTION_ONLY),而这个控件一直是直连 UPDATE —— 于是它从 APR-10 那天起一次都没存进去过。
-- 【谁】持 module.purchasing.edit 的人(Tim 的 Q20:它是一行上的【质量判断】,不是一项商业条款 —— 不要改单理由,
--   不问开单人 / 品类码那一道 assert_po_manager)。变更记录记下每一次。
-- 【什么时候】这张单没有被取消(PO_CANCELLED|单号);已删的单找不到(PO_LINE_NOT_FOUND)。关了的单可以 —— 判断常常是
--   收完货之后才有人回头补的。
-- 【不许回到空】NULL 的意思是"这一行早于这一条轴"(列注释),不是"不知道";不知道是 not_assessed。
--   所以空值按名拒(DEEP_DISCHARGE_JUDGEMENT_REQUIRED),字典里没有的码按名拒(DEEP_DISCHARGE_JUDGEMENT_UNKNOWN|码)。
-- 【不写 purchase_order_history】那张表只记商业字段的改动(trg_po_history_line 的五列);这一列从来不在里面 ——
--   它的历史在变更记录里,审计记录读那里。
--
-- NOTE: introduced by db/migrations/2026-10-05-u1b-workflow-fixes.sql.

CREATE OR REPLACE FUNCTION public.set_po_line_deep_discharge(p_line_id uuid, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_l record;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT l.id, l.deep_discharge_judgement_code AS old_code, po.id AS po_id, po.code, po.status
      INTO v_l
      FROM purchase_order_lines l
      JOIN purchase_orders po ON po.id = l.purchase_order_id AND po.deleted_at IS NULL
     WHERE l.id = p_line_id
       FOR UPDATE OF l;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', COALESCE(p_line_id::text, '?');
    END IF;
    IF v_l.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_l.code;
    END IF;
    IF p_code IS NULL OR btrim(p_code) = '' THEN
        RAISE EXCEPTION 'DEEP_DISCHARGE_JUDGEMENT_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM deep_discharge_judgements WHERE code = p_code AND is_active) THEN
        RAISE EXCEPTION 'DEEP_DISCHARGE_JUDGEMENT_UNKNOWN|%', p_code;
    END IF;
    UPDATE purchase_order_lines SET deep_discharge_judgement_code = p_code WHERE id = p_line_id;
    RETURN jsonb_build_object('line_id', p_line_id, 'purchase_order_id', v_l.po_id,
                              'code', p_code, 'previous', v_l.old_code);
END;
$function$;

COMMENT ON FUNCTION public.set_po_line_deep_discharge(uuid, text) IS
'U1-B(UNBLOCK-1 Q20):写一行采购明细的深度放电判断。module.purchasing.edit;单子没被取消;码必须在字典里且启用;不许回到空(NULL = 早于这一条轴)。变更记录记下每一次。';
