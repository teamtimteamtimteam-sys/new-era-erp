-- 2026-08-24-import1-bulk-master-data-import.sql
-- IMPORT-1:主数据批量导入 —— 预览、全或全无的提交、序列推进、以及一本导入日志
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么需要一个 RPC —— 而【不是】因为直插会漏掉什么】
--
-- 本刀的简报最初写的理由是"直插会绕过 RPC 里的拒绝"。**实测之后那句话是假的**:
-- 这六张表【一个建行的 RPC 都没有】—— materials / suppliers / customers /
-- departments / storage_locations / employees 今天全部由 app 直接 `.insert()`
-- 写入(各自的 `new/actions.ts`)。也就是说守着它们的每一条规矩**本来就是
-- 触发器或 CHECK**,而那两样【任何路径都躲不掉】。直插漏不掉任何东西。
--
-- **真正需要 RPC 的理由是另一个,而它足够硬:**
-- 【N 行的全或全无】+【序列推进】+【写一条导入日志】必须是**同一笔事务**,
-- 而 PostgREST 一次只发一条语句,做不出多语句事务。
--
-- 这条区别写在这里而不是只写在文档里,是因为下一个读这支函数的人会先问
-- "为什么不直接插" —— 答案必须在他站的地方。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【预览怎么做到"跑真的规矩、却什么都不留下"】
--
-- 预览【不重新实现任何一条规则】—— 重新实现就是第二份定义,而本仓库为
-- "两份定义必然漂开"付过很多次账。它的做法是:**真的把每一行插进去**,
-- 用逐行的 savepoint 抓住每一次失败,把 SQLSTATE 与消息记进报告,
-- 最后**整支 RAISE EXCEPTION 把报告带出来** —— 于是事务回滚,一行都不留。
--
-- 这正是本仓库 `db/fixtures/` 用了一百多次的那个惯例(AGENTS.md:
-- 「一个 DO 块累积一个 jsonb 报告,最后 RAISE EXCEPTION 'FIXTURE_REPORT %'」)。
-- 它买到的东西是别的写法买不到的:**预览看见的拒绝,与提交会遇到的拒绝
-- 逐字是同一条** —— 因为它们是同一次插入。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本刀不做什么,写在这里免得被读成疏漏】
-- * 不给这六张表加 NOT NULL、不加新 CHECK —— 导入不是收紧既有数据的时机;
-- * `suppliers.tax_id` / `customers.tax_id` **只在导入这条路上必填**,
--   表上一个字没动(理由见 `import_master_rows` 里那一段);
-- * 不建合并路径。"录进来之后才发现重复"仍然没有答案(docs/known-issues.md)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 一、权限:批量导入是一个【单独的】权限 ────────────────────────────────
-- 【为什么不复用 action.manage_permissions】那会重演 DICT-ADMIN 的缺陷:
-- 一个物料编辑员永远够不到物料这张屏。而批量导入也**不等于**"能编辑一家供应商"
-- —— 它是本刀里唯一一个能一次放进 500 行错数据的动作,所以它自己一个码。
INSERT INTO permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order)
VALUES ('action.bulk_import', 'action',
        'Bulk import master data', '批量导入主数据',
        'Load materials, counterparties, employees, departments and storage locations from a CSV file. This is the only action that can insert hundreds of rows at once.',
        '从 CSV 文件批量装入物料、往来户、员工、部门与库位。这是唯一一个一次能插入数百行的动作。',
        910)
ON CONFLICT (code) DO NOTHING;

-- 只发给 admin。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, 'action.bulk_import' FROM roles r
WHERE r.code = 'admin'
ON CONFLICT DO NOTHING;

-- ── 二、导入日志 ──────────────────────────────────────────────────────────
CREATE TABLE import_batches (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    target_table  text        NOT NULL,
    file_name     text        NOT NULL,
    row_count     integer     NOT NULL CHECK (row_count > 0),
    code_first    text        NOT NULL,
    code_last     text        NOT NULL,
    imported_at   timestamptz NOT NULL DEFAULT now(),
    imported_by   uuid,
    CONSTRAINT import_batches_target_known
        CHECK (target_table IN ('materials','suppliers','customers',
                                'employees','departments','storage_locations'))
);

COMMENT ON TABLE import_batches IS
'一本【日志】,不是一套血缘。它回答的只有一个问题:「那个文件到底进去了没有」。

【它【不是】关于那些行的第二个事实来源】——「这一行是导入来的吗」不许从这里推导,
也不许有任何东西按它去 JOIN 业务表。它只记:谁、什么时候、哪张表、哪个文件、
多少行、编号从哪到哪。多一列都会让它开始被当成血缘用。

【上线前的清库:这张表【跟着一起清】,这是一个决定,不是遗漏】(IMPORT-1,2026-08-24)
一条写着「2026-09-02 装进 500 家供应商」的日志,如果活过了那 500 家供应商被删掉的
那一刻,它就变成了一条【比它的对象活得更久】的记录 —— 本仓库对这个形状点过很多次名。
它的价值在清库【之前】(那个文件落了没有),而那份价值不会因为一起清掉而损失。
**写清库脚本的人在这里就会读到这句话,不必先去翻文档。**';

COMMENT ON COLUMN import_batches.code_first IS '本批次里【字典序最小】的编号 —— 与 code_last 一起给人一个"这一批大概是哪一段"的把手,不用于任何推导。';
COMMENT ON COLUMN import_batches.code_last  IS '本批次里【字典序最大】的编号。同上。';

ALTER TABLE import_batches ENABLE ROW LEVEL SECURITY;

CREATE POLICY "import_batches select by permission" ON import_batches
    FOR SELECT TO authenticated USING (has_permission('action.bulk_import'));
-- 写入只走 SECURITY DEFINER 的那支函数,所以这里【故意】没有 INSERT 策略。

REVOKE ALL ON import_batches FROM authenticated;
GRANT SELECT ON import_batches TO authenticated;

-- ── 三、哪些列可以被导入 ──────────────────────────────────────────────────
-- 【安全下限,不是模板】模板由 app 从 lib/database.types.ts 生成(A1 的裁定)。
-- 这里挡的是另一件事:**无论模板说什么,这几列都不许从文件里进来。**
CREATE OR REPLACE FUNCTION master_import_forbidden_columns()
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
    SELECT ARRAY[
        'id',                       -- 主键由库生成
        'created_at','updated_at','created_by','updated_by',   -- 审计,由库盖章
        'deleted_at','deleted_by','deletion_reason','owner_id',
        'user_id',                  -- 员工 ↔ 登录账号的关联走 set_user_employee_link
                                    -- (LINK-1 那条"两扇门两套规矩"还没裁,不在这里开第三扇)
        'status',                   -- suppliers.status 由 validate_supplier_status_transition 管
                                    -- 跳转规则;导入直接落一个状态会绕过那条规矩
        'default_payment_term_template_id'  -- 指向 payment_term_templates,本刀范围外
    ];
$$;
COMMENT ON FUNCTION master_import_forbidden_columns() IS
'导入【永远】不接受的列。这是安全下限,与模板是两件事:模板决定「摆出哪些列给人填」,
本函数决定「无论摆没摆,这几列都不许进」。两者不一致时,预览会按名报出来 ——
那是一次【看得见】的分歧,而不是一次静默接受。';

-- ════════════════════════════════════════════════════════════════════════════
-- 四、导入引擎:一支函数,两个调用者(预览 / 提交)
--
-- 【一份实现,两个调用者】—— AGENTS.md 那条「预览要问库,不要在 TS 里重算一遍」。
-- 预览与提交走的是**同一段插入**,区别只有一个布尔:预览在最后 RAISE,
-- 于是整支回滚、一行不留;提交在全绿时才落地。
-- **预览看见的拒绝,与提交会遇到的拒绝逐字是同一条,因为它们是同一次插入。**
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION master_import_apply(
    p_table     text,
    p_rows      jsonb,
    p_file_name text    DEFAULT NULL,
    p_dry_run   boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
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
$fn$;

COMMENT ON FUNCTION master_import_apply(text, jsonb, text, boolean) IS
'主数据批量导入 —— 预览与提交【同一段插入】,靠 p_dry_run 分开。

【为什么是 RPC 而不是直插】不是因为直插会漏掉规矩 —— 实测这六张表【一个建行的
RPC 都没有】,守着它们的全是触发器与 CHECK,那两样任何路径都躲不掉。
真正的理由是:N 行的全或全无 + 序列推进 + 写日志必须是同一笔事务,
而 PostgREST 一次只发一条语句。

【预览为什么真的插】不重新实现任何一条规则 —— 重新实现就是第二份定义。
它真插、逐行抓错、最后 RAISE 把报告带出去,于是整支回滚。';

COMMIT;
