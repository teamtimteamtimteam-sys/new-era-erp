-- db/functions/label_object_data.sql
-- MES-3b(2026-10-07,MES-3b Step 0 Q2 · Q10 · Q13,Tim):【一张标签上印什么】—— 一份,预览与打印问同一支(AGENTS.md「一份实现,两个调用方」)。
--   进料批:批号 · 物料(编号与名称)· 数量与单位 · 供应商的法定名称 · 危险品那一行。
--   产出批:批号 · 物料 · 数量与单位 · 纯度 · 危险品那一行。
--   库位:库位号 · 名称 · 区 · 是不是隔离库位。
--   【物料名与供应商名是这张单据的展示标签】(常设决定 3;MES-3b Q2 并入):此前标签以读者身份内嵌读 materials / suppliers,
--     仓库不持 module.materials.view,于是仓库印出来的标签物料那一格是"—"(MES-3b Step 0 §1.3,实测)。这里以属主身份读,
--     能看这一批的人就看得到它是什么料、谁送来的 —— 【只有名字】,不带价格、不带供应商的任何别的属性。
--   【危险品】物料选了 UN 编号 → 编号、类别、正式运输名称、标记文字(V30,可能为空);电池料(material_kinds.has_condition_axes)
--     没选 → dg_missing = true(Q15:只提示,不拒)。
--   找不到、或批次已删 → NULL(调用方说"找不到")。
--   【内层】不是 SECURITY DEFINER、没有调用者检查,EXECUTE 从 authenticated 收回;调用方 label_print_preview / record_label_print
--   各自先按那样东西的查看码把关,再以属主身份调它。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.

CREATE OR REPLACE FUNCTION public.label_object_data(p_kind text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r record;
BEGIN
    IF p_kind = 'inbound_batch' THEN
        SELECT b.id, b.code, b.quantity, b.unit, m.code AS m_code, m.name AS m_name, s.legal_name AS detail,
               m.dg_code, g.dg_class, g.name_en AS dg_name_en, g.name_zh AS dg_name_zh, g.marking_text,
               COALESCE(mk.has_condition_axes, false) AS battery
          INTO r
          FROM inbound_batches b
          LEFT JOIN materials m ON m.id = b.material_id
          LEFT JOIN material_kinds mk ON mk.code = m.kind_code
          LEFT JOIN suppliers s ON s.id = b.supplier_id
          LEFT JOIN dangerous_goods_codes g ON g.code = m.dg_code
         WHERE b.id = p_id AND b.deleted_at IS NULL;
    ELSIF p_kind = 'output_batch' THEN
        SELECT b.id, b.code, b.quantity, b.unit, m.code AS m_code, m.name AS m_name, b.purity::text AS detail,
               m.dg_code, g.dg_class, g.name_en AS dg_name_en, g.name_zh AS dg_name_zh, g.marking_text,
               COALESCE(mk.has_condition_axes, false) AS battery
          INTO r
          FROM output_batches b
          LEFT JOIN materials m ON m.id = b.material_id
          LEFT JOIN material_kinds mk ON mk.code = m.kind_code
          LEFT JOIN dangerous_goods_codes g ON g.code = m.dg_code
         WHERE b.id = p_id AND b.deleted_at IS NULL;
    ELSIF p_kind = 'storage_location' THEN
        SELECT l.id, l.code, l.name, l.zone, l.is_quarantine, l.is_active INTO r
          FROM storage_locations l WHERE l.id = p_id;
        IF NOT FOUND THEN
            RETURN NULL;
        END IF;
        RETURN jsonb_build_object('kind', p_kind, 'id', r.id, 'code', r.code, 'name', r.name, 'zone', r.zone,
                                  'is_quarantine', r.is_quarantine, 'is_active', r.is_active);
    ELSE
        RETURN NULL;
    END IF;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    RETURN jsonb_build_object(
        'kind', p_kind, 'id', r.id, 'code', r.code,
        'material_code', r.m_code, 'material_name', r.m_name,
        'quantity', r.quantity, 'unit', r.unit,
        'detail_kind', CASE p_kind WHEN 'inbound_batch' THEN 'supplier' ELSE 'purity' END,
        'detail_value', r.detail,
        'dg', CASE WHEN r.dg_code IS NULL THEN NULL
                   ELSE jsonb_build_object('code', r.dg_code, 'class', r.dg_class, 'name_en', r.dg_name_en,
                                           'name_zh', r.dg_name_zh, 'marking_text', r.marking_text) END,
        'dg_missing', r.battery AND r.dg_code IS NULL);
END;
$function$;
