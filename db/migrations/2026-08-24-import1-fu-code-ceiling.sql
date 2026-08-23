-- 2026-08-24-import1-fu-code-ceiling.sql
-- IMPORT-1-fu:导入的编号不许把取号格式撑爆。
--
-- 【为什么有这一支 fu,而不是把它写进上一支】上一支已经原子地落地了,而这一条
-- 是**在写 fixture 124 的时候被实测撞出来的**,不是设计时想到的:
-- 序列推进(3.2)本身是对的,但它可以把序列推过 9999,而三支取号函数写的是
-- `LPAD(nextval::TEXT, 4, '0')` —— **PostgreSQL 的 LPAD 会截断**,于是
-- 10000 变成 '1000'、14002 变成 '1400'。第一次可能不撞,第二次必然撞,
-- 而屏幕上是一句 duplicate key,没有人会想到是格式截断。
--
-- 处置:**导入按名拒绝**,不去推一个会把取号弄坏的序列。
-- 放宽那三支取号函数的位数是另一刀 —— 它改变既有编号的形状,要有人拍板。

BEGIN;

CREATE OR REPLACE FUNCTION public.master_import_apply(p_table text, p_rows jsonb, p_file_name text DEFAULT NULL::text, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_allowed   text[];
    v_forbidden text[] := master_import_forbidden_columns();
    v_row       jsonb;
    v_keys      text[];
    v_cols      text;
    v_i         integer;
    v_n         integer;
    v_code      text;
    v_errors    jsonb := '[]'::jsonb;
    v_codes     text[] := '{}';
    v_dupes     text[];
    v_existing  text[];
    v_bad_key   text;
    v_ref       text;
    v_uuid      uuid;
    v_seq       text;
    v_maxnum    integer;
    v_batch     uuid;
BEGIN
    PERFORM require_permission('action.bulk_import');

    IF p_table NOT IN ('materials','suppliers','customers',
                       'employees','departments','storage_locations') THEN
        RAISE EXCEPTION 'IMPORT_TABLE_NOT_IMPORTABLE|%', p_table;
    END IF;
    IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
        RAISE EXCEPTION 'IMPORT_ROWS_NOT_AN_ARRAY';
    END IF;
    v_n := jsonb_array_length(p_rows);
    IF v_n = 0 THEN
        RAISE EXCEPTION 'IMPORT_FILE_EMPTY';
    END IF;

    -- 本表真实存在、且不在安全下限里的列 —— 【从目录读,不抄第二份清单】
    SELECT array_agg(column_name::text) INTO v_allowed
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = p_table
      AND NOT (column_name = ANY (v_forbidden));

    -- ── 编号:三条【整份文件】级别的拒绝,在插入任何一行之前 ───────────────
    -- 【为什么在这里而不是靠唯一索引】唯一索引会给出 duplicate key 的原文,
    -- 而且只报撞上的【第一条】。整份文件级别的拒绝要一次说完所有撞车的编号,
    -- 否则人改一条、重传、再撞第二条 —— 那是 D2 那条「一次点完」的同一课。
    FOR v_i IN 0 .. v_n - 1 LOOP
        v_code := p_rows -> v_i ->> 'code';
        IF v_code IS NULL OR btrim(v_code) = '' THEN
            v_errors := v_errors || jsonb_build_object(
                'row', v_i + 1, 'column', 'code', 'code', 'IMPORT_CODE_REQUIRED');
        ELSE
            v_codes := v_codes || btrim(v_code);
        END IF;
    END LOOP;

    -- 文件【自己】重复
    SELECT array_agg(c) INTO v_dupes
    FROM (SELECT unnest(v_codes) c GROUP BY 1 HAVING count(*) > 1) d;
    IF v_dupes IS NOT NULL THEN
        RAISE EXCEPTION 'IMPORT_CODE_DUPLICATED_IN_FILE|%', array_to_string(v_dupes, ',');
    END IF;

    -- 已经在库里 —— **拒整份文件,并把撞上的都点名**(3.4)
    EXECUTE format(
        'SELECT array_agg(code::text ORDER BY code) FROM public.%I WHERE code = ANY($1)', p_table)
        INTO v_existing USING v_codes;
    IF v_existing IS NOT NULL THEN
        RAISE EXCEPTION 'IMPORT_CODE_ALREADY_EXISTS|%', array_to_string(v_existing, ',');
    END IF;

    -- ── 编号的【上限】—— 由取号格式决定,不是由我们决定 ────────────────────────
    -- 【实测,而且是这一刀自己撞出来的】generate_material_code / _supplier_ / _customer_
    -- 取号写的是 `LPAD(nextval::TEXT, 4, '0')`,而 **PostgreSQL 的 LPAD 会截断**:
    --     lpad('10000',4,'0') = '1000'   lpad('14002',4,'0') = '1400'
    -- 也就是说这三张表的编号格式**只装得下 4 位**。序列一旦被推过 9999,
    -- 下一次自动取号就会吐出一个【被截短的】编号 —— 第一次可能侥幸不撞,
    -- 第二次必然撞,而报出来的是一句 duplicate key,没有人会想到是格式截断。
    --
    -- **所以这里【拒绝】,而不是推一个会把取号弄坏的序列。**
    -- 修那三支取号函数(把 4 位放宽)是另一刀:它会改变既有编号的形状,
    -- 而那是一次看得见的、需要有人拍板的改动。本刀只负责不把系统推进那个状态。
    IF p_table IN ('materials','suppliers','customers') THEN
        SELECT array_agg(c ORDER BY c) INTO v_existing
        FROM unnest(v_codes) c
        WHERE c ~ '^[A-Z]+-[0-9]{4}-[0-9]+$'
          AND split_part(c, '-', 3)::bigint > 9999;
        IF v_existing IS NOT NULL THEN
            RAISE EXCEPTION 'IMPORT_CODE_NUMBER_TOO_HIGH|%', array_to_string(v_existing, ',');
        END IF;
    END IF;

    -- 员工编号有一条【只对它成立】的形状要求:next_employee_code 会对
    -- 形如 EMP-<年>-* 的编号取 split_part(code,'-',3)::integer 求最大值 ——
    -- 一个 EMP-2026-ABC 会让【下一次自动取号】当场抛类型错。
    -- 与 code 的其它形状无关(LEGACY-1 之类不匹配那个 LIKE,安全)。
    IF p_table = 'employees' THEN
        FOR v_i IN 0 .. v_n - 1 LOOP
            v_code := btrim(coalesce(p_rows -> v_i ->> 'code', ''));
            IF v_code ~ '^EMP-[0-9]{4}-' AND NOT v_code ~ '^EMP-[0-9]{4}-[0-9]+$' THEN
                v_errors := v_errors || jsonb_build_object(
                    'row', v_i + 1, 'column', 'code', 'code', 'IMPORT_EMPLOYEE_CODE_SHAPE',
                    'detail', v_code);
            END IF;
        END LOOP;
    END IF;

    -- ── 逐行插入 ──────────────────────────────────────────────────────────
    FOR v_i IN 0 .. v_n - 1 LOOP
        v_row := p_rows -> v_i;

        -- 【引用列按【编号】给,不按 uuid】一个操作员不可能手打 uuid。
        -- 这里把 *_code 换成对应的 *_id;换不到就是这一行的一条具名拒绝。
        FOR v_ref, v_bad_key IN
            SELECT * FROM (VALUES
                ('department_code','department_id'),
                ('manager_code','manager_id'),
                ('manager_employee_code','manager_employee_id'),
                ('parent_department_code','parent_department_id')) t(a,b)
        LOOP
            IF v_row ? v_ref AND coalesce(btrim(v_row ->> v_ref), '') <> '' THEN
                IF v_bad_key IN ('department_id','parent_department_id') THEN
                    SELECT id INTO v_uuid FROM departments WHERE code = btrim(v_row ->> v_ref);
                ELSE
                    SELECT id INTO v_uuid FROM employees WHERE code = btrim(v_row ->> v_ref);
                END IF;
                IF v_uuid IS NULL THEN
                    v_errors := v_errors || jsonb_build_object(
                        'row', v_i + 1, 'column', v_ref, 'code', 'IMPORT_REFERENCE_NOT_FOUND',
                        'detail', v_row ->> v_ref);
                ELSE
                    v_row := v_row || jsonb_build_object(v_bad_key, v_uuid);
                END IF;
            END IF;
            v_row := v_row - v_ref;
        END LOOP;

        -- 往来户的登记号:**只在这条路上必填**(3.5)
        -- 【表上一个字都没动,而这不是折中】线上 7 家往来户里 6 家没有登记号,
        -- 一条 NOT NULL 会把那 6 行【就地冻住】—— PROC-1 的 materials_kind_stated
        -- 正是这么冻住了八行物料(至今开着,见 docs/known-issues.md)。
        -- 而一份【新导入的批次】是一次有人整理过的数据,那一刻登记号是知道得到的。
        IF p_table IN ('suppliers','customers')
           AND coalesce(btrim(v_row ->> 'tax_id'), '') = '' THEN
            v_errors := v_errors || jsonb_build_object(
                'row', v_i + 1, 'column', 'tax_id', 'code', 'IMPORT_TAX_ID_REQUIRED');
        END IF;

        -- 安全下限:文件里出现了永远不许导入的列
        FOREACH v_bad_key IN ARRAY v_forbidden LOOP
            IF v_row ? v_bad_key THEN
                v_errors := v_errors || jsonb_build_object(
                    'row', v_i + 1, 'column', v_bad_key, 'code', 'IMPORT_COLUMN_FORBIDDEN');
            END IF;
        END LOOP;

        -- 只取【本表真的有、而且允许】的键。多余的键按名报出来,不静默丢掉 ——
        -- 一个被静默忽略的列,与一个被写进去的列在屏幕上长得一模一样。
        SELECT array_agg(k) INTO v_keys
        FROM jsonb_object_keys(v_row) k
        WHERE k = ANY (v_allowed);

        FOR v_bad_key IN SELECT k FROM jsonb_object_keys(v_row) k
                         WHERE NOT (k = ANY (v_allowed)) AND NOT (k = ANY (v_forbidden))
        LOOP
            v_errors := v_errors || jsonb_build_object(
                'row', v_i + 1, 'column', v_bad_key, 'code', 'IMPORT_COLUMN_UNKNOWN');
        END LOOP;

        IF v_keys IS NULL THEN
            v_errors := v_errors || jsonb_build_object(
                'row', v_i + 1, 'column', NULL, 'code', 'IMPORT_ROW_EMPTY');
            CONTINUE;
        END IF;

        -- 【空字符串 = 没填,不是填了空】CSV 里没有 NULL 这个概念。
        -- 不折成 NULL 的话,一个空单元格会去撞 NOT NULL 或者落成一个空串值,
        -- 而两者都不是操作员的意思(GO-4 的 normalise 对 tax_id 做的是同一件事)。
        SELECT jsonb_object_agg(k, CASE WHEN jsonb_typeof(v_row -> k) = 'string'
                                         AND btrim(v_row ->> k) = '' THEN 'null'::jsonb
                                    ELSE v_row -> k END)
        INTO v_row FROM unnest(v_keys) k;

        SELECT string_agg(quote_ident(k), ', ') INTO v_cols FROM unnest(v_keys) k;

        -- 【真的插进去 —— 于是那 11 条 BEFORE INSERT 触发器与每一条 CHECK 都照常开火】
        -- 导入【继承】它们,不复制它们(4.1)。
        -- jsonb_populate_record 负责按列类型转换;只列出文件给了的列,
        -- 于是没给的列照常吃【表默认值】(unit='kg'、is_active=true …)——
        -- 用 NULL 铺满会把默认值挤掉,那是一种静默的数据损坏。
        BEGIN
            EXECUTE format(
                'INSERT INTO public.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::public.%I, $1)',
                p_table, v_cols, v_cols, p_table) USING v_row;
        EXCEPTION WHEN OTHERS THEN
            v_errors := v_errors || jsonb_build_object(
                'row', v_i + 1, 'column', NULL, 'code', 'IMPORT_ROW_REFUSED',
                'sqlstate', SQLSTATE, 'detail', SQLERRM);
        END;
    END LOOP;

    -- ── 判词 ──────────────────────────────────────────────────────────────
    IF p_dry_run THEN
        -- 【预览:整支回滚,一行都不留】RAISE 是这里唯一能保证回滚的手段 ——
        -- 一支函数没法回滚它自己所在的那笔事务。报告随异常消息带出去,
        -- 与 db/fixtures 用了一百多次的那个惯例逐字相同。
        RAISE EXCEPTION 'IMPORT_PREVIEW %', jsonb_build_object(
            'table', p_table, 'rows', v_n, 'errors', v_errors)::text;
    END IF;

    IF jsonb_array_length(v_errors) > 0 THEN
        -- 【全或全无】一行不合格,整份文件都不进。
        RAISE EXCEPTION 'IMPORT_FAILED %', jsonb_build_object(
            'table', p_table, 'rows', v_n, 'errors', v_errors)::text;
    END IF;

    -- ── 序列推进:**这不是家务,这是本刀最容易被跳过的一步** ────────────────
    -- 编号来自文件(3.1),所以那三条序列【一格都没动】。不推进的话,
    -- 下一次有人在界面上建供应商,取号会从旧的位置继续 —— 撞上刚导入的编号,
    -- 报一句 duplicate key,而那时没有人会想到是几周前的导入造成的。
    --
    -- 【只有三张表需要】materials / suppliers / customers 用序列取号;
    -- **employees 不需要** —— next_employee_code 是 MAX(...)+1,它天然看得见
    -- 导入进去的最大号;**departments / storage_locations 根本没有取号触发器**,
    -- 编号一律由人给。这三种情况写在这里,免得下一个人以为漏了三张表。
    v_seq := CASE p_table WHEN 'materials' THEN 'material_code_seq'
                          WHEN 'suppliers' THEN 'supplier_code_seq'
                          WHEN 'customers' THEN 'customer_code_seq' END;
    IF v_seq IS NOT NULL THEN
        SELECT max(split_part(c, '-', 3)::integer) INTO v_maxnum
        FROM unnest(v_codes) c
        WHERE c ~ '^[A-Z]+-[0-9]{4}-[0-9]+$';
        IF v_maxnum IS NOT NULL AND v_maxnum > (SELECT last_value FROM pg_sequences
                                                WHERE schemaname='public' AND sequencename = v_seq) THEN
            PERFORM setval(v_seq, v_maxnum, true);
        END IF;
    END IF;

    -- ── 日志 ──────────────────────────────────────────────────────────────
    INSERT INTO import_batches (target_table, file_name, row_count, code_first, code_last, imported_by)
    VALUES (p_table, coalesce(p_file_name, '(未命名)'), v_n,
            (SELECT min(c) FROM unnest(v_codes) c),
            (SELECT max(c) FROM unnest(v_codes) c),
            auth.uid())
    RETURNING id INTO v_batch;

    RETURN jsonb_build_object('table', p_table, 'rows', v_n, 'batch_id', v_batch,
                              'sequence_bumped_to', v_maxnum);
END;
$function$;

COMMIT;
