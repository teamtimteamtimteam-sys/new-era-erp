CREATE OR REPLACE FUNCTION public.create_work_order(p_lines jsonb, p_expected jsonb DEFAULT NULL::jsonb, p_scheduled_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_code text;
    v_elem jsonb;
    v_mat  uuid;
    v_qty  numeric;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25):建工单归仓库 —— action.wo_create(warehouse · admin);
    --   下达归财务(action.wo_release),建单人永远不能下达(release_work_order 里的 forbid_self_approval,按人认)。
    PERFORM require_permission('action.wo_create');
    -- ★ Batch 3b grilling Q3:建单人之外没有人下达得了,就不让它生下来 —— 否则它是一张永远的草稿。
    --   "有人" = 一个真持有人(real_role_grants:未撤销 / 已确认 / 未封禁 / 未删除)持 action.wo_release,
    --   而且不是同一个人(self_leg 按人认,跨账号)。与下达那一侧的四眼一样,不看审批开关。
    IF NOT EXISTS (SELECT 1
                     FROM role_permissions rp
                     JOIN roles r ON r.id = rp.role_id
                    CROSS JOIN LATERAL real_role_grants(r.code) g
                    WHERE rp.permission_code = 'action.wo_release'
                      AND self_leg(v_user, NULL::uuid, g.user_id) = 'none') THEN
        RAISE EXCEPTION 'WO_NO_OTHER_RELEASER';
    END IF;

    -- 【拒绝的顺序就是"人下一步该改什么"的顺序】两条同时不成立时,先说哪一条
    -- 决定了他打开哪个输入框(与 record_invoice_issue 的四条同一条道理)。
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'WO_NO_LINES';
    END IF;

    -- 投料行:先把每一行自己看一遍,再看行与行之间
    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_qty := (v_elem->>'planned_qty')::numeric;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'WO_LINE_QTY_INVALID';
        END IF;
        v_mat := (v_elem->>'material_id')::uuid;
        IF v_mat IS NULL OR NOT EXISTS (
            SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'WO_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
        END IF;
    END LOOP;
    -- 【重复物料按名拒,而不是靠唯一约束抛 23505】约束是兜底,不是文案:
    -- 一条 duplicate key value violates unique constraint 到不了人眼里就是机器串。
    SELECT (elem->>'material_id')::uuid INTO v_mat
      FROM jsonb_array_elements(p_lines) elem
     GROUP BY 1 HAVING count(*) > 1 LIMIT 1;
    IF v_mat IS NOT NULL THEN
        RAISE EXCEPTION 'WO_DUPLICATE_MATERIAL|%', v_mat;
    END IF;

    -- 预期产出:【可以整个不给】—— 没有预期是一种诚实的状态,不是缺失。
    IF p_expected IS NOT NULL AND jsonb_typeof(p_expected) = 'array'
       AND jsonb_array_length(p_expected) > 0 THEN
        FOR v_elem IN SELECT * FROM jsonb_array_elements(p_expected)
        LOOP
            v_qty := (v_elem->>'expected_qty')::numeric;
            IF v_qty IS NULL OR v_qty <= 0 THEN
                RAISE EXCEPTION 'WO_EXPECTED_QTY_INVALID';
            END IF;
            v_mat := (v_elem->>'material_id')::uuid;
            IF v_mat IS NULL OR NOT EXISTS (
                SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'WO_EXPECTED_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
            END IF;
        END LOOP;
        SELECT (elem->>'material_id')::uuid INTO v_mat
          FROM jsonb_array_elements(p_expected) elem
         GROUP BY 1 HAVING count(*) > 1 LIMIT 1;
        IF v_mat IS NOT NULL THEN
            RAISE EXCEPTION 'WO_DUPLICATE_EXPECTED|%', v_mat;
        END IF;
    END IF;

    v_code := next_work_order_code(COALESCE(p_scheduled_date, CURRENT_DATE));
    -- 【注意这个 COALESCE 是给【年份】用的,不是给 scheduled_date 用的】
    -- 存进表里的仍然是 p_scheduled_date 本身(可以是 NULL)。取号要一个年份,
    -- 而"没排期"的单子只能落在今年 —— 这与"永不给日期默认值"不冲突:
    -- 被默认的是号码的年段,不是那句对外的承诺。
    INSERT INTO work_orders (code, status, scheduled_date, notes, created_by, updated_by)
    VALUES (v_code, 'draft', p_scheduled_date, NULLIF(btrim(COALESCE(p_notes,'')), ''), v_user, v_user)
    RETURNING id INTO v_id;

    INSERT INTO work_order_lines (work_order_id, material_id, planned_qty)
    SELECT v_id, (elem->>'material_id')::uuid, (elem->>'planned_qty')::numeric
      FROM jsonb_array_elements(p_lines) elem;

    IF p_expected IS NOT NULL AND jsonb_typeof(p_expected) = 'array'
       AND jsonb_array_length(p_expected) > 0 THEN
        -- ════════════════════════════════════════════════════════════════
        -- PROC-SUPPORT-1(R3):每一条预期产出必须说出它的【出处】。
        -- 【自己一条码,不与 WO_EXPECTED_QTY_INVALID 合并】下一步动作不同:
        --   · 数量非法 → 回去改那个数;
        --   · 出处没说 → 回去说这个数【是怎么来的】。
        -- 后者不是一次数据校验,是这一列存在的全部理由 —— 六个月后要分得出
        -- "被真实生产验证过的"与"当初那个猜测"。
        -- 【空字符串与缺席一样被拒】—— 一个空串在数据库里不是 NULL,却和
        -- "没人说过"是同一件事,而它会绕过 NOT NULL 类的检查。
        -- ════════════════════════════════════════════════════════════════
        -- 【一条谓词同时管住"没说"与"说错了"】btrim 之后的空串落不进那三个
        -- 取值里,所以缺席、空串、错值走的是同一条拒绝 —— 它们对操作员是同一件事:
        -- 【这一栏还没有一个正当的答案】。
        IF EXISTS (
            SELECT 1 FROM jsonb_array_elements(p_expected) elem
             WHERE btrim(COALESCE(elem->>'basis',''))
                   NOT IN ('planner_estimate','seeded_industry','calibrated')
        ) THEN
            RAISE EXCEPTION 'WO_EXPECTED_BASIS_REQUIRED'
              USING HINT = '每一条预期产出都要说出它是怎么来的:排计划的人估的、照行业经验播的、还是对着真实生产校准过的。没有默认值 —— 漏填是一次失败,不是悄悄补上一个看起来像答案的值。';
        END IF;

        INSERT INTO work_order_expected_outputs (work_order_id, material_id, expected_qty, basis, basis_reference)
        SELECT v_id, (elem->>'material_id')::uuid, (elem->>'expected_qty')::numeric,
               btrim(elem->>'basis'),
               NULLIF(btrim(COALESCE(elem->>'basis_reference','')), '')
          FROM jsonb_array_elements(p_expected) elem;
    END IF;

    INSERT INTO work_order_history (work_order_id, change_type, detail, changed_by)
    VALUES (v_id, 'created', v_code, v_user);

    RETURN jsonb_build_object('work_order_id', v_id, 'code', v_code, 'status', 'draft');
END;
$function$

