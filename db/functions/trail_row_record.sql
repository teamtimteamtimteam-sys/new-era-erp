-- db/functions/trail_row_record.sql
-- AUDIT-TRAIL-1a(Tim 的 Q30):/settings/change-history 的"Record"一栏 —— 一行记录【属于哪一张单据 / 哪一条记录】。
--   先后:① 这张表本身是单据(document_types)→ 它自己;② 它是某个审计记录主语的子行 / 孙行 / 相关行
--   (trail_subject_members)→ 沿父键走到那条根记录;③ 它有一列指着某张单据 → 那张单据;④ 都不是 → 它自己。
--   返回 {"table", "id", "label", "gone", "doc_key", "route", "link_mode"}(后三项只在它是单据时有,界面据此造链接)。
--   外键值从这一次的影像取,取不到再取这一行今天的样子(一次编辑只记改了的那几列)。
-- AUDIT-TRAIL-1b-1:同一张表挂在几个主语下时(加工投入既在加工单上、也在批次上;approval_log 按 subject_type 分给
--   十来种单据),只沿【home】的那一条、并且【match 对得上这一行】、外键有值的那一条往上走 —— 否则汇总页的 Record 一栏
--   会随登记表的字母顺序变,一次加工投入突然"属于"一个批次。往上一跳的垫脚石(hop = 'up')从不参与。
-- 【属主身份】EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.trail_row_record(p_table text, p_key jsonb, p_old jsonb, p_new jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_img   jsonb;
    v_cur   record;
    v_table text := p_table;
    v_id    text;
    v_pk    text[];
    m       record;
    f       record;
    v_hops  integer := 0;
    v_lab   jsonb;
    v_dkey  text;
    v_route text;
    v_mode  text;
BEGIN
    IF p_key IS NULL OR to_regclass(format('public.%I', p_table)) IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_cur FROM trail_current_image(p_table, p_key);
    v_img := COALESCE(v_cur.image, '{}'::jsonb) || COALESCE(p_old, '{}'::jsonb) || COALESCE(p_new, '{}'::jsonb);
    v_pk := trail_pk_columns(p_table);
    v_id := CASE WHEN cardinality(v_pk) = 1 THEN p_key ->> v_pk[1] END;

    IF NOT EXISTS (SELECT 1 FROM document_types dt WHERE dt.table_name = p_table)
       AND NOT EXISTS (SELECT 1 FROM trail_subjects() ts WHERE ts.root_table = p_table) THEN
        -- ② 登记过的子行:沿父键往上走,最多三跳
        LOOP
            SELECT tm.* INTO m FROM trail_subject_members() tm
             WHERE tm.table_name = v_table AND tm.home AND tm.hop = 'down'
               AND v_img @> tm.match AND v_img ->> tm.fk_column IS NOT NULL
             ORDER BY tm.subject, tm.ord LIMIT 1;
            EXIT WHEN NOT FOUND OR v_hops >= 3;
            v_table := m.parent_table;
            v_id := v_img ->> m.fk_column;
            v_hops := v_hops + 1;
            SELECT * INTO v_cur FROM trail_current_image(v_table, jsonb_build_object('id', v_id));
            v_img := COALESCE(v_cur.image, '{}'::jsonb);
        END LOOP;
        -- ③ 没走动:找第一列指着单据的外键
        IF v_hops = 0 THEN
            FOR f IN SELECT ft.* FROM trail_fk_targets(p_table) ft
                      WHERE ft.target_table IN (SELECT dt.table_name FROM document_types dt)
                        AND ft.column_name NOT IN ('created_by', 'updated_by') LOOP
                IF v_img ->> f.column_name IS NOT NULL THEN
                    v_table := f.target_table;
                    v_id := v_img ->> f.column_name;
                    EXIT;
                END IF;
            END LOOP;
        END IF;
    END IF;
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('table', v_table, 'id', NULL, 'label', NULL, 'gone', false);
    END IF;
    v_lab := trail_ref_label(v_table, COALESCE((trail_pk_columns(v_table))[1], 'id'), v_id);
    SELECT dt.key, dt.route, dt.link_mode INTO v_dkey, v_route, v_mode FROM document_types dt WHERE dt.table_name = v_table ORDER BY dt.key LIMIT 1;
    RETURN jsonb_build_object('table', v_table, 'id', v_id,
        'label', v_lab ->> 'label', 'gone', COALESCE((v_lab ->> 'gone')::boolean, false),
        'doc_key', v_dkey, 'route', v_route, 'link_mode', v_mode);
END;
$function$;
