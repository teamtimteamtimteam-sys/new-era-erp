-- db/functions/soft_delete_counterparty_contact.sql
-- PARTY-1:把一个联系人从名单上拿下来 —— 【软删,不真删】。
--
-- 【为什么不真删】两件事要分得开:
--   ① "这个人已经不在那家公司了" —— 名单上不该再出现他;
--   ② "这个人从来不存在" —— 那不是真的,而且 collection_chases 上很可能
--      还留着"那天我们联系的是他"。那一列是【文本】,所以真删不会让它变错,
--      但会让"这个名字是谁"这个问题在系统里再也答不出来。
-- 所以留行、落 deleted_at。
--
-- 【它必须是一支函数,而不是一条 UPDATE 策略】本表没有 UPDATE 策略(见表注),
-- 而一条为了软删而开的 UPDATE 策略会顺带把【所有列】都开出去 ——
-- 包括 is_primary,于是"设主联系人"那条同一笔事务的保证被绕过去了。

CREATE OR REPLACE FUNCTION public.soft_delete_counterparty_contact(p_contact_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_row counterparty_contacts%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM counterparty_contacts WHERE id = p_contact_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTACT_NOT_FOUND|%', p_contact_id;
    END IF;
    -- 【SECURITY DEFINER 自己查权限,按归属那一侧查】
    IF v_row.customer_id IS NOT NULL THEN
        PERFORM require_permission('module.customers.edit');
    ELSE
        PERFORM require_permission('module.suppliers.edit');
    END IF;
    IF v_row.deleted_at IS NOT NULL THEN
        -- 【已经删过不是错误,但也不该假装刚删成功】幂等地返回,并说出来。
        RETURN jsonb_build_object('contact_id', p_contact_id, 'already_deleted', true);
    END IF;
    UPDATE counterparty_contacts
       SET deleted_at = now(), is_primary = false,
           updated_at = now(), updated_by = auth.uid()
     WHERE id = p_contact_id;
    -- 【主联系人被删掉之后,不自动挑一个顶上】谁是主联系人是一个【判断】,
    -- 而系统按 created_at 之类挑一个顶上,会让开票快照悄悄换人 ——
    -- 那是一次没有人做过的决定。屏幕上会显示"没有主联系人",人来指定。
    RETURN jsonb_build_object('contact_id', p_contact_id, 'already_deleted', false,
                              'was_primary', v_row.is_primary);
END;
$function$;

COMMENT ON FUNCTION public.soft_delete_counterparty_contact(uuid) IS
'PARTY-1:把联系人从名单上拿下来 —— 软删。「他不在那家公司了」与「他从来不存在」是两件事,而 collection_chases 上可能还留着"那天联系的是他"(那是文本,真删不会让它变错,但会让"这个名字是谁"再也答不出来)。**它必须是函数而不是一条 UPDATE 策略**:为软删开的 UPDATE 策略会连 is_primary 一起开出去,把"设主联系人要在同一笔事务里撤旧的"那条保证绕过去。**删掉主联系人之后不自动挑一个顶上** —— 那会让开票快照悄悄换人,而那是一次没有人做过的决定。';
