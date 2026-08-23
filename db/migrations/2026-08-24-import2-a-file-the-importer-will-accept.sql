-- 2026-08-24-import2-a-file-the-importer-will-accept.sql
-- IMPORT-2:模板生成出来的文件,导入必须收得下 —— 今天它不收。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【走查发现:照着模板填的文件被拒了】而报出来的是 PostgreSQL 的原话
-- (`cannot insert a non-DEFAULT value into column …`)。走查只碰到两列,
-- **实测是九列、六张表全中**:
--
--   ✗ 模板发出了【数据库拒收】的列(GENERATED ALWAYS):
--       suppliers.supplies_goods · employees.monthly_salary_set     ← 2 列
--   ⚠ NOT NULL 但【有默认值】的列,空格子被我转成了 NULL,于是撞 NOT NULL:
--       materials.unit · suppliers.supplier_types · customers.credit_hold ·
--       departments.is_active · employees.employment_status ·
--       employees.review_exempt · storage_locations.is_active      ← 7 列
--
-- 【第二类的根因是【一行】代码,而它是我上一刀写的】
-- 上一刀把"空字符串折成 NULL"当成了体贴 —— 理由写着「CSV 里没有 NULL 这个概念」。
-- **那句话是对的,而由它推出的做法是反的**:CSV 里既然写不出 NULL,
-- 一个空格子的意思就只能是【没有填】,而不是【填了 NULL】。
-- 正确的做法是**把那个键整个拿掉**,让列的默认值生效。
--
-- **一次错误的转换制造了九处里的七处。** 而按最初的诊断("把 supplier_types 标成必填")
-- 去修,会让操作员在每一行里手打一个 `{}` 来绕过一个 bug。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么模板的来源要换 —— 不是它解析得不好,是那些事实【不在那里】】
-- 模板此前从 `lib/database.types.ts` 的 Insert 块推列。实测那份类型里:
--     supplies_goods?: boolean | null      ← 一个 GENERATED 列,与任何普通可选列【一模一样】
--     counterparty_type: string            ← 一个 CHECK 闭集,只是 string
-- **它表达不了「数据库会拒收这一列」,也表达不了「只接受这几个值」。**
-- 所以模板改从**线上目录**取(本文件新建的那支函数):那是唯一同时拥有三件事实的地方。
-- 这【不是】推翻"不要在构建时查库"那条裁定 —— 那条的理由是"库够不着时构建会失败",
-- 而这是**请求时**,而且模板路由本来就为权限判断打了一次往返。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 一、模板的唯一来源 ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION master_import_template_columns(p_table text)
RETURNS TABLE (column_name text, is_required boolean, accepted_values text[])
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
    PERFORM require_permission('action.bulk_import');
    IF p_table NOT IN ('materials','suppliers','customers',
                       'employees','departments','storage_locations') THEN
        RAISE EXCEPTION 'IMPORT_TABLE_NOT_IMPORTABLE|%', p_table;
    END IF;

    RETURN QUERY
    WITH cols AS (
        SELECT a.attname::text AS nm,
               a.attnotnull     AS notnull,
               (ad.adbin IS NOT NULL) AS has_default,
               (a.attgenerated <> '') AS generated
          FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
         WHERE n.nspname = 'public' AND c.relname = p_table
           AND a.attnum > 0 AND NOT a.attisdropped
    ),
    -- 单列 CHECK 里的闭集,以及真正的 enum 类型 —— 两种都要
    sets AS (
        SELECT a.attname::text AS nm,
               array_agg(DISTINCT m[1] ORDER BY m[1]) AS vals
          FROM pg_constraint con
          JOIN pg_class rel ON rel.oid = con.conrelid
          JOIN pg_namespace n ON n.oid = rel.relnamespace
          JOIN unnest(con.conkey) k(num) ON true
          JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.num,
               LATERAL regexp_matches(pg_get_constraintdef(con.oid), '''([^'']+)''::text', 'g') m
         WHERE con.contype = 'c' AND n.nspname='public' AND rel.relname = p_table
           AND array_length(con.conkey,1) = 1
         GROUP BY a.attname
    )
    SELECT cols.nm,
           -- 【必填 = NOT NULL 且【没有】默认值】。有默认值的 NOT NULL 列**不是**必填:
           -- 留空是合法的,导入会把那个键整个省掉,让默认值生效。
           (cols.notnull AND NOT cols.has_default),
           sets.vals
      FROM cols LEFT JOIN sets ON sets.nm = cols.nm
     WHERE NOT (cols.nm = ANY (master_import_forbidden_columns()))
       -- 【GENERATED 列【根本不出现在模板里】】数据库会拒收一个供给的值,
       -- 而一个"发出来又被拒"的列正是本刀要消灭的东西。
       AND NOT cols.generated
     ORDER BY cols.nm;
END;
$fn$;

COMMENT ON FUNCTION master_import_template_columns(text) IS
'模板的【唯一来源】。它同时给出三件事实,而这三件只有线上目录同时拥有:
① 这一列接不接受供给的值(GENERATED 的【不出现】);
② 它必不必填(NOT NULL 且无默认值 —— 有默认值的 NOT NULL【不是】必填,留空即用默认);
③ 它接不接受任意值(单列 CHECK 的闭集)。

`lib/database.types.ts` 表达不了 ① 和 ③:一个 GENERATED 列在那里长得与任何可选列
一模一样(`supplies_goods?: boolean | null`),而一个 CHECK 闭集只是 `string`。
所以模板不再从那份类型推 —— 不是它解析得不好,是那些事实不在那里。';


-- ── 二、导入引擎:空格子 = 没填 · GENERATED 进禁列 · 拒绝按 SQLSTATE 分族 ──

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
    v_diag_col  text;
    v_diag_con  text;
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
    -- 【禁列 = 静态清单 ∪ 这张表的 GENERATED 列】(IMPORT-2)
    -- GENERATED 列不是"我们选择不导入",是**数据库会拒收一个供给的值**。
    -- 它必须与静态禁列走同一条路,否则模板不发它、而文件里若有它仍会撞一句原文。
    SELECT v_forbidden || COALESCE(array_agg(a.attname::text), '{}')
      INTO v_forbidden
      FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname='public' AND c.relname = p_table
       AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated <> '';

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

        -- ══════ 【空格子 = 没有填,不是填了 NULL】(IMPORT-2 改的就是这一句)══════
        -- 上一刀在这里把空字符串**折成了 NULL**,理由写着「CSV 里没有 NULL 这个概念」。
        -- **那句话是对的,而由它推出的做法是反的。** CSV 里既然写不出 NULL,
        -- 一个空格子的意思就只能是【这一格我没有填】—— 而不是【我要把它设成 NULL】。
        --
        -- 折成 NULL 的后果是具体的:`materials.unit`、`suppliers.supplier_types`、
        -- `customers.credit_hold`、`departments.is_active`、`employees.employment_status`
        -- 与 `.review_exempt`、`storage_locations.is_active` —— **七列**都是
        -- 「NOT NULL 但有默认值」,于是一个照着模板留空的格子撞上 NOT NULL,
        -- 报一句 PostgreSQL 原文。**六张表全中,而根因是这一行。**
        --
        -- 正确的做法:**把这个键整个拿掉**,于是列的默认值生效。
        -- 真正必填(NOT NULL 且【无】默认值)的列仍然会按名失败 —— 那是对的。
        SELECT array_agg(k) INTO v_keys FROM unnest(v_keys) k
         WHERE NOT (jsonb_typeof(v_row -> k) = 'string' AND btrim(v_row ->> k) = '');
        IF v_keys IS NULL THEN
            v_errors := v_errors || jsonb_build_object(
                'row', v_i + 1, 'column', NULL, 'code', 'IMPORT_ROW_EMPTY');
            CONTINUE;
        END IF;
        SELECT jsonb_object_agg(k, v_row -> k) INTO v_row FROM unnest(v_keys) k;

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
            -- 【按 SQLSTATE 分族,不按消息文本】(IMPORT-2)
            -- 消息文本会随版本与语言变;SQLSTATE 是稳定的,而且它覆盖的是【一族】,
            -- 不是走查恰好撞到的那两条。列名/约束名从诊断里取 —— 那是给人看的关键。
            GET STACKED DIAGNOSTICS v_diag_col = COLUMN_NAME, v_diag_con = CONSTRAINT_NAME;
            v_errors := v_errors || jsonb_build_object(
                'row', v_i + 1,
                'column', COALESCE(NULLIF(v_diag_col,''), NULLIF(v_diag_con,'')),
                'code', CASE SQLSTATE
                    WHEN '23502' THEN 'IMPORT_ROW_NOT_NULL'
                    WHEN '23514' THEN 'IMPORT_ROW_CHECK'
                    WHEN '23503' THEN 'IMPORT_ROW_FK'
                    WHEN '23505' THEN 'IMPORT_ROW_UNIQUE'
                    WHEN '22P02' THEN 'IMPORT_ROW_BAD_SYNTAX'
                    WHEN '428C9' THEN 'IMPORT_ROW_GENERATED'
                    WHEN '22001' THEN 'IMPORT_ROW_TOO_LONG'
                    WHEN '22003' THEN 'IMPORT_ROW_NUMERIC_RANGE'
                    ELSE 'IMPORT_ROW_REFUSED' END,
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
        -- 【COALESCE 不是防御性写法,它是这里唯一正确的写法 —— 由 fixture 124 抓出来】
        -- `pg_sequences.last_value` 在一条**从来没有被取过号**的序列上是 **NULL**,
        -- 而**一个全新重建的库正是这种状态** —— 也就是生产。
        -- 少了 COALESCE,这个比较是 `14001 > NULL` = NULL,IF 永不成立,
        -- **序列推进就被静默跳过了**;而在线上(序列早就用过)它工作得好好的。
        -- 也就是说:这个缺陷【只在真正要紧的那种库上出现】,而且不报任何错。
        IF v_maxnum IS NOT NULL AND v_maxnum > COALESCE(
               (SELECT last_value FROM pg_sequences
                 WHERE schemaname='public' AND sequencename = v_seq), 0) THEN
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
$function$
;

COMMIT;
