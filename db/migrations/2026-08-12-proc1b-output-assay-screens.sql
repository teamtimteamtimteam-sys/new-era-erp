-- PROC-1b(2026-08-12):产出化验的【试算】—— 屏幕问库"应用会怎样",不自己算
--
-- PROC-1 只造了机制,没有造屏幕 —— 于是它建的一切都没人用得上。这是同一形状
-- 第三次落在这里(几张财务切完没屏幕、月结跑不了;再加工没有输入选择器、
-- 两段加工建不出来),屏幕这一刀因此按【同一切的精神】补上,不算新功能。
--
-- 屏幕要在按下"应用"之前说清两件事,而按本仓库自己的规矩
-- (AGENTS.md §"A screen that previews a posting ASKS the database"),
-- 它得【问库】而不是在 TypeScript 里重算:
--   1. 含量会怎么换 —— 应用是【整体替换】(删后重插),化验没报的金属行会消失,
--      被顶掉的手工行要看得见,不能被静默覆盖;
--   2. 过期后果 —— 产出它的加工单若按 metal_value 已分摊,应用会让拆分过期。
--      这个谓词(allocated_at 非空 AND 基准是 metal_value)与过期视图第六源
--      同一条判断;fixture 54 把两者钉在一起:试算说"会过期"的地方,D1 断言
--      视图真的过期;说"不会"的地方(weight),D2 断言它真的不动。
--
-- p_assay_result_id 可空:录入页(化验还没落库,含量在表单里)只问"这个批次
-- 应用任何化验会有什么后果"—— 当前含量与产出加工单;详情页带 assay id,
-- 连"换成什么"一并回答。拒绝与 apply_output_assay 同构(fixture 40 的纪律:
-- 试算在应用会拒的地方同样拒)—— 挂错父、已应用、批次已删,逐条同码。
--
-- 【顺手把记录器的签名摆正】PROC-1 让 inbound 父可空,却把它留在无默认值的
-- 首位 —— 于是"记录一份产出化验"必须显式递一个 NULL 进去,而生成的 TS 类型
-- 把它标成必填 string,调用方要么撒谎要么强转。两个父在语义上【都是可选的】
-- (二选一,XOR 由库把门),签名就该这么说:两个父都挪进默认值区,谁记谁给。
-- 全部调用方(进料/产出动作、fixture)都按名传参,参数顺序不是接口。
--
-- 【产出它的加工单取 LIMIT 1,为什么这不是"随便挑一条"】processing_outputs
-- 上没有 output_batch_id 的唯一索引,所以这一句读起来像在多行里蒙一行。它不是:
-- 全库唯一写这张表的是 commit_processing_run,而它【每一条产出腿都新建一个
-- output_batches 行】再挂上去 —— 一个产出批因此只可能有一个产出方。线上实测
-- 过(2026-08-12):按 output_batch_id 分组,没有一个批次的产出腿多于一条。
-- 记在这里而不是加进函数体,是因为多产出方一旦真的出现,该做的不是给这句
-- 加 ORDER BY —— 挑哪一条都可能漏报另一条的过期 —— 而是让试算把它们【全部】
-- 报出来。写下判据,免得下一个人以为 LIMIT 1 是随手写的。
--
-- 镜像:db/functions/{preview_apply_output_assay,record_assay_result}.sql;
-- 行为断言:fixture 54 的 I 臂。

BEGIN;

-- ─── 0 · record_assay_result:两个父都进默认值区 ────────────────────────────
DROP FUNCTION public.record_assay_result(uuid, date, jsonb, text, text, text, boolean, text, uuid);

CREATE OR REPLACE FUNCTION public.record_assay_result(p_assay_date date, p_metals jsonb, p_lab_name text DEFAULT NULL::text, p_certificate_ref text DEFAULT NULL::text, p_sample_ref text DEFAULT NULL::text, p_is_final boolean DEFAULT true, p_notes text DEFAULT NULL::text, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_id    uuid := gen_random_uuid();
    v_code  text;
    v_el    jsonb;
    v_metal text;
    v_pct   numeric;
    v_seen  text[] := ARRAY[]::text[];
    v_count integer := 0;
BEGIN
    -- PROC-1:两个父【二选一】。记录、编号、取代共享一张表一条序列;
    -- 权限跟着父走 —— 进料化验挂 inbound 模块,产出化验挂 output 模块。
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'ASSAY_ONE_PARENT';
    END IF;
    IF p_inbound_batch_id IS NOT NULL THEN
        PERFORM require_permission('module.inbound.edit');
        IF NOT EXISTS (
            SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
        END IF;
    ELSE
        PERFORM require_permission('module.output.edit');
        IF NOT EXISTS (
            SELECT 1 FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
        END IF;
    END IF;
    IF p_assay_date IS NULL OR p_assay_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ASSAY_DATE_INVALID|%', COALESCE(p_assay_date::text, '?');
    END IF;
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    v_code := next_assay_code(p_assay_date);
    INSERT INTO assay_results (id, code, inbound_batch_id, output_batch_id, assay_date, lab_name,
                               certificate_ref, sample_ref, is_final, notes, created_by, updated_by)
    VALUES (v_id, v_code, p_inbound_batch_id, p_output_batch_id, p_assay_date, p_lab_name,
            p_certificate_ref, p_sample_ref, p_is_final, p_notes, v_user, v_user);

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        IF v_metal IS NULL OR v_metal NOT IN ('ni','co','li','mn','cu','al','fe') THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;
        v_pct := (v_el->>'content_pct')::numeric;
        IF v_pct IS NULL OR v_pct < 0 OR v_pct > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;
        INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
        VALUES (v_id, v_metal, v_pct);
        v_count := v_count + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'assay_result_id', v_id,
        'code', v_code,
        'metal_count', v_count
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.preview_apply_output_assay(p_output_batch_id uuid, p_assay_result_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_assay   record;
    v_batch   record;
    v_run     record;
    v_current jsonb;
    v_next    jsonb := NULL;
BEGIN
    -- 试算给要按"应用"的人看 —— 权限同 apply_output_assay
    PERFORM require_permission('module.output.edit');

    SELECT * INTO v_batch FROM output_batches
    WHERE id = p_output_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    IF p_assay_result_id IS NOT NULL THEN
        SELECT * INTO v_assay FROM assay_results
        WHERE id = p_assay_result_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
        END IF;
        -- 与 apply_output_assay 同一串拒绝,同一串码(试算在应用会拒的地方同样拒)
        IF v_assay.output_batch_id IS NULL THEN
            RAISE EXCEPTION 'ASSAY_IS_INBOUND|%', v_assay.code;
        END IF;
        IF v_assay.output_batch_id <> p_output_batch_id THEN
            -- 挂在别的产出批上:对这个批次而言它不存在
            RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', v_assay.code;
        END IF;
        IF v_assay.applied_at IS NOT NULL THEN
            RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
        END IF;

        SELECT jsonb_agg(jsonb_build_object('metal', arm.metal, 'content_pct', arm.content_pct)
                         ORDER BY arm.metal)
        INTO v_next
        FROM assay_result_metals arm
        WHERE arm.assay_result_id = p_assay_result_id;
    END IF;

    -- 当前含量,带出处 —— "被顶掉的是谁说的数"是这个预览存在的一半理由
    SELECT jsonb_agg(jsonb_build_object(
               'metal', obm.metal,
               'content_pct', obm.content_pct,
               'content_source', obm.content_source,
               'source_assay_code', src.code)
           ORDER BY obm.metal)
    INTO v_current
    FROM output_batch_metals obm
    LEFT JOIN assay_results src ON src.id = obm.source_assay_id
    WHERE obm.output_batch_id = p_output_batch_id;

    -- 产出它的加工单与过期后果。谓词与过期视图第六源同一条判断
    -- (metal_value 限定);fixture 54 的 I/D 臂把两者钉在一起。
    SELECT r.id, r.code, r.allocated_at, r.allocation_basis INTO v_run
    FROM processing_outputs po
    JOIN processing_runs r ON r.id = po.run_id AND r.deleted_at IS NULL
    WHERE po.output_batch_id = p_output_batch_id
    LIMIT 1;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'batch_code', v_batch.code,
        'current_metals', COALESCE(v_current, '[]'::jsonb),
        'assay_metals', v_next,
        'producing_run_id', v_run.id,
        'producing_run_code', v_run.code,
        'producing_run_allocated_at', v_run.allocated_at,
        'producing_run_basis', v_run.allocation_basis,
        'will_flag_stale', v_run.allocated_at IS NOT NULL
                           AND v_run.allocation_basis = 'metal_value'
    );
END;
$function$;

COMMIT;
