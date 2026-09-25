-- db/functions/withdraw_shipping_release.sql
-- APR-5b(2026-09-25,grilling Q4):撤回一张在等的发货放行。
-- 谁能撤:提单人本人(按人认 —— self_leg 说这个账号就是提单人那个人),或任何持 action.request_shipping_release
-- 的人。只撤 submitted。撤回记在本行上(谁、何时、为什么),【不】写 approval_log —— 撤回不是一次决定
-- (付款、工资、收货定价、贷项 / 作废申请同一条)。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.withdraw_shipping_release(p_release_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r shipping_releases%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM shipping_releases WHERE id = p_release_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_NOT_FOUND|%', COALESCE(p_release_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission('action.request_shipping_release');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE shipping_releases
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_release_id;
    RETURN jsonb_build_object('release_id', p_release_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$
;
