-- db/functions/set_role_permissions.sql
-- 整体替换一个角色的授权。要 action.manage_permissions。
--
-- 【edit 蕴含 view 的强制在这里,不只在界面】。2b 的 fixture 量过:只授 edit 不授 view 时
-- PostgREST 的 INSERT ... RETURNING 会 42501,整条写入路径断掉 —— 那是坏配置,不是审美问题。
-- 界面挡不住 RPC 直调,所以守卫必须在数据库里。
--
-- NOTE: introduced by db/migrations/2026-08-02-perm3-banking-and-directory.sql;
--       diff-aware since db/migrations/2026-09-28-history1-change-log.sql (HISTORY-1, Tim's Q16).

CREATE OR REPLACE FUNCTION public.set_role_permissions(p_role_id uuid, p_permission_codes text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_codes   text[] := COALESCE(p_permission_codes, ARRAY[]::text[]);
    v_role    record;
    v_missing text;
    v_bad     text;
    v_added   integer;
    v_removed integer;
BEGIN
    PERFORM require_permission('action.manage_permissions');

    SELECT id, code, is_system INTO v_role
    FROM roles WHERE id = p_role_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ROLE_NOT_FOUND';
    END IF;

    -- 未知权限码直接拒绝(目录是迁移级的,界面不该能凭空造码)
    SELECT c INTO v_bad
    FROM unnest(v_codes) c
    WHERE NOT EXISTS (SELECT 1 FROM permissions p WHERE p.code = c)
    LIMIT 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'PERMISSION_NOT_FOUND|%', v_bad;
    END IF;

    -- 【核心守卫】每一个 module.<m>.edit 都必须有对应的 module.<m>.view 同行
    SELECT split_part(c, '.', 2) INTO v_missing
    FROM unnest(v_codes) c
    WHERE c LIKE 'module.%.edit'
      AND NOT ('module.' || split_part(c, '.', 2) || '.view') = ANY (v_codes)
    LIMIT 1;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'EDIT_REQUIRES_VIEW|%', v_missing;
    END IF;

    -- 系统角色不可被摘掉管理权限 —— 否则一次保存就能把权限系统本身锁死
    IF v_role.is_system AND NOT ('action.manage_permissions' = ANY (v_codes)) THEN
        RAISE EXCEPTION 'SYSTEM_ROLE_PROTECTED';
    END IF;

    -- ★ HISTORY-1(Tim 的 Q16):只动【有差别】的码。此前整批删掉再整批插回,于是每一次保存
    --   都把一个角色的每一行重写一遍,旧的码单从库里读不回来,而通用变更记录会把一次保存
    --   记成 N 删 + N 插,埋掉真正变了的那一个。现在:删掉不再要的,插进新要的,留着的一行不碰
    --   (它的 created_at / created_by 仍是当初授它的那一次 —— 比每次重写更真)。
    --   入参里重复的码被 DISTINCT + ON CONFLICT 吸收(此前会撞主键)。
    DELETE FROM role_permissions
     WHERE role_id = p_role_id AND permission_code <> ALL (v_codes);
    GET DIAGNOSTICS v_removed = ROW_COUNT;
    INSERT INTO role_permissions (role_id, permission_code, created_by)
    SELECT DISTINCT p_role_id, c, auth.uid() FROM unnest(v_codes) c
    ON CONFLICT (role_id, permission_code) DO NOTHING;
    GET DIAGNOSTICS v_added = ROW_COUNT;

    RETURN jsonb_build_object(
        'role_id', v_role.id,
        'code', v_role.code,
        'permission_count', (SELECT count(DISTINCT c) FROM unnest(v_codes) c),
        'added', v_added,
        'removed', v_removed
    );
END;
$function$;
