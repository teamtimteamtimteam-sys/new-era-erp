-- db/functions/label_print_context.sql
-- MES-3b(2026-10-07,MES-3b Step 0 Q5–Q9,Tim):【印一张标签之前要问的每一件事】—— 预览(label_print_preview)与打印(record_label_print)
--   问同一支,所以页面上看见的那张与记下来的那张不可能是两份算法。
--   ① 哪一种东西:inbound_batch · output_batch · storage_location,别的 → LABEL_KIND_INVALID|<种类>。
--   ② 谁印得了:那样东西自己的查看码(进料 module.inbound.view · 产出 module.output.view · 库位 module.inventory.view)——
--      Q28:能看就能印,没有新码;没有 → PERMISSION_DENIED|<码>(在找之前问:不告诉一个看不见的人那样东西在不在)。
--   ③ 找不到或已删 → LABEL_OBJECT_NOT_FOUND|<种类>。
--   ④ 模板:不给 → 那一种东西下启用着、sort_order 最小的一张(Q5 的默认);一张都没有 → LABEL_TEMPLATE_NONE|<种类>;
--      给了却不存在、停用了或不是这一种东西的 → LABEL_TEMPLATE_INVALID|<模板>。
--   ⑤ 二维码:短链接的【路径】/b/<批号> 或 /loc/<库位号>(Q9;域名由页面补上 —— 数据库不知道自己被哪个域名访问)。
--   ⑥ 之前印过几次、最后一次是谁什么时候、是不是补印 —— 页面据此决定要不要问理由。
--   【内层】不是 SECURITY DEFINER,EXECUTE 从 authenticated 收回;外面两支是 DEFINER,以属主身份调它。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.

CREATE OR REPLACE FUNCTION public.label_print_context(p_kind text, p_id uuid, p_template text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code  text;
    v_data  jsonb;
    v_tpl   record;
    v_n     integer;
    v_last  record;
BEGIN
    v_code := CASE p_kind WHEN 'inbound_batch' THEN 'module.inbound.view'
                          WHEN 'output_batch' THEN 'module.output.view'
                          WHEN 'storage_location' THEN 'module.inventory.view' END;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'LABEL_KIND_INVALID|%', COALESCE(p_kind, '?');
    END IF;
    IF NOT has_permission(v_code) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|%', v_code;
    END IF;

    v_data := label_object_data(p_kind, p_id);
    IF v_data IS NULL THEN
        RAISE EXCEPTION 'LABEL_OBJECT_NOT_FOUND|%', p_kind;
    END IF;

    IF NULLIF(btrim(p_template), '') IS NULL THEN
        SELECT t.code, t.name_en, t.name_zh, t.page_size, t.show_dg INTO v_tpl
          FROM label_templates t
         WHERE t.object_kind = p_kind AND t.is_active
         ORDER BY t.sort_order, t.code
         LIMIT 1;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'LABEL_TEMPLATE_NONE|%', p_kind;
        END IF;
    ELSE
        SELECT t.code, t.name_en, t.name_zh, t.page_size, t.show_dg INTO v_tpl
          FROM label_templates t
         WHERE t.code = btrim(p_template) AND t.object_kind = p_kind AND t.is_active;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'LABEL_TEMPLATE_INVALID|%', btrim(p_template);
        END IF;
    END IF;

    SELECT count(*) INTO v_n FROM label_prints lp
     WHERE (p_kind = 'inbound_batch' AND lp.inbound_batch_id = p_id)
        OR (p_kind = 'output_batch' AND lp.output_batch_id = p_id)
        OR (p_kind = 'storage_location' AND lp.storage_location_id = p_id);
    SELECT lp.printed_at, lp.printed_by, lp.is_reprint, lp.reprint_reason INTO v_last
      FROM label_prints lp
     WHERE (p_kind = 'inbound_batch' AND lp.inbound_batch_id = p_id)
        OR (p_kind = 'output_batch' AND lp.output_batch_id = p_id)
        OR (p_kind = 'storage_location' AND lp.storage_location_id = p_id)
     ORDER BY lp.printed_at DESC, lp.id
     LIMIT 1;

    RETURN jsonb_build_object(
        'data', v_data,
        'template', jsonb_build_object('code', v_tpl.code, 'name_en', v_tpl.name_en, 'name_zh', v_tpl.name_zh,
                                       'page_size', v_tpl.page_size, 'show_dg', v_tpl.show_dg),
        'qr_path', CASE WHEN p_kind = 'storage_location' THEN '/loc/' ELSE '/b/' END || (v_data ->> 'code'),
        'prints_so_far', v_n,
        'next_is_reprint', v_n > 0,
        'last_printed_at', v_last.printed_at,
        'last_printed_by', v_last.printed_by);
END;
$function$;
