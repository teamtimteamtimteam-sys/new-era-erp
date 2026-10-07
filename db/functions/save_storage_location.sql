-- db/functions/save_storage_location.sql
-- AUDIT-TRAIL-1b-3(Tim 的 Q13,AT-1b Step 0,2026-09-29):保存一个库位 —— 新建或修改,连同它允许存放的废物分类,
--   【一次调用、一笔事务、只写变了的】。
--
-- 【为什么要它】此前 app/inventory/locations/actions.ts 分三次写:改库位那一行 · 删掉它全部的允许分类 · 再把勾上的
--   全部插回去 —— 三笔事务。于是审计记录里每保存一次,没动过的分类也读成"拿掉了"又"加上了",而且是三条记录
--   (Step 0 §f)。现在:库位那一行只有真的变了才写;分类只删【不再勾着】的、只插【新勾上】的;全在这一笔里。
-- 【空集合是合法的,它的意思是"未配置"】与原来的动作同一条:不拦空。
-- 【违规提醒照旧】trg_slac_notify_written 只接 INSERT(清空到零行 = 未配置,不是违规)。原来"整体删了再插"每次都
--   让它响;现在只拿掉、不加的那一次没有 INSERT,它不会响 —— 而拿掉一个分类恰恰可能让已有存量变成违规。
--   所以这一支在那种情形下自己按同一个判据叫一次 notify_class_violations(剩下的集合非空时,与原来一字不差)。
--   集合一条都没变的保存不再叫 —— 原来那一次是"整体重写"的副作用,不是一个新的配置。
-- 【SECURITY DEFINER 的理由】notify_class_violations 对 authenticated 收回了执行权;门在函数第一行
--   (require_permission('module.inventory.edit'),与两张表的写策略同一个码)。change_log 的"谁"取自登录,不受影响。
-- ★ MES-3a(2026-10-06,MES-0 Q34;MES-3a Step 0 Q17,Tim):末尾多一个 p_is_quarantine(隔离库位)。NULL = 不改(修改时)/
--   否(新建时)—— 已部署的旧页面不传它,照样解析,也不会把一个已标的隔离库位悄悄改回去。签名变了:迁移是 DROP + CREATE。
CREATE OR REPLACE FUNCTION public.save_storage_location(p_code text, p_name text, p_classes text[], p_id uuid DEFAULT NULL::uuid, p_zone text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_is_quarantine boolean DEFAULT NULL::boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id      uuid := p_id;
    v_classes text[] := ARRAY(SELECT DISTINCT c FROM unnest(COALESCE(p_classes, ARRAY[]::text[])) c WHERE c IS NOT NULL AND c <> '');
    v_removed integer := 0;
    v_added   integer := 0;
BEGIN
    PERFORM require_permission('module.inventory.edit');
    IF v_id IS NULL THEN
        INSERT INTO storage_locations (code, name, zone, notes, is_quarantine)
        VALUES (p_code, p_name, p_zone, p_notes, COALESCE(p_is_quarantine, false))
        RETURNING id INTO v_id;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = v_id) THEN
            RAISE EXCEPTION 'LOCATION_NOT_FOUND|%', v_id;
        END IF;
        UPDATE storage_locations
           SET code = p_code, name = p_name, zone = p_zone, notes = p_notes,
               is_quarantine = COALESCE(p_is_quarantine, is_quarantine)
         WHERE id = v_id
           AND (code, name, zone, notes, is_quarantine)
               IS DISTINCT FROM (p_code, p_name, p_zone, p_notes, COALESCE(p_is_quarantine, is_quarantine));
    END IF;

    DELETE FROM storage_location_allowed_classes
     WHERE location_id = v_id AND NOT (classification_code = ANY (v_classes));
    GET DIAGNOSTICS v_removed = ROW_COUNT;

    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    SELECT v_id, c FROM unnest(v_classes) c
     WHERE NOT EXISTS (SELECT 1 FROM storage_location_allowed_classes a
                        WHERE a.location_id = v_id AND a.classification_code = c);
    GET DIAGNOSTICS v_added = ROW_COUNT;

    IF v_removed > 0 AND v_added = 0 AND cardinality(v_classes) > 0 THEN
        PERFORM notify_class_violations('location_configured', NULL, ARRAY[v_id]);
    END IF;
    RETURN v_id;
END;
$function$;