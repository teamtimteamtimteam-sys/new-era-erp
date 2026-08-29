-- db/fixtures/125-a-file-filled-exactly-as-the-template-says-is-accepted.sql
-- IMPORT-2:**照着模板填的文件,导入必须收得下。** 走查证明它此前不收。
--
-- 【为什么这一条要单独一支 fixture】fixture 124 证明的是"编号不撞"、"重跑被拒"
-- 这一类【拒绝】。**它一次都没有证明过"一次正常的导入会成功"** ——
-- 而走查发现的正是这件事:六张表、九列,照着模板填就被拒。
-- 一套只断言拒绝的测试,在一个【什么都拒】的实现上全绿(fixture 122 的 F1 臂
-- 为同一条写过一句话)。**这支 fixture 是那个正方向。**
--
-- 【判据:空格子 = 没有填】模板里的可选列,操作员会留空;CSV 里留空就是空字符串。
-- 所以这里**把空字符串真的传进去**,断言它们被【省掉】而不是被写成 NULL ——
-- 那正是七处缺陷的根因,而只测"填满了的行"是看不见它的。

BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all  uuid;
    v_kind text;
    v_rep  jsonb;
    v_cols jsonb;
    v_n    int;
BEGIN
    INSERT INTO roles (code,name_en,name_zh,is_active)
      VALUES ('fixture-125','f','f',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id,permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id,role_id) VALUES (v_user,r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ A · 模板【不发】数据库拒收的列 ════════════════════════════════
    SELECT jsonb_agg(column_name) INTO v_cols
      FROM master_import_template_columns('suppliers');
    IF v_cols ? 'supplies_goods' THEN
        RAISE EXCEPTION 'FIXTURE 125A 失败:模板仍然发出了 supplies_goods —— 它是 GENERATED,数据库拒收供给的值';
    END IF;
    SELECT jsonb_agg(column_name) INTO v_cols
      FROM master_import_template_columns('employees');
    IF v_cols ? 'monthly_salary_set' THEN
        RAISE EXCEPTION 'FIXTURE 125A 失败:模板仍然发出了 monthly_salary_set(GENERATED)';
    END IF;

    -- ══════════ B · 取值受限的列【带着它的取值】════════════════════════════════
    -- 走查里 counterparty_type 那三个值是【口头】补上的。这一臂让它不再需要口头。
    IF NOT EXISTS (SELECT 1 FROM master_import_template_columns('suppliers')
                    WHERE column_name='counterparty_type'
                      AND accepted_values @> ARRAY['goods_supplier','forwarder','service_vendor']) THEN
        RAISE EXCEPTION 'FIXTURE 125B 失败:counterparty_type 没有带出它的三个取值';
    END IF;

    -- ══════════ C · **一次真的、会成功的导入**(本 fixture 的判词)══════════════
    -- 必填列填上;**可选列一律传空字符串** —— 那正是操作员留空时 CSV 给出的东西。
    -- 空格子必须被【省掉】,让 supplier_types 的 DEFAULT '{}' 生效。
    v_rep := master_import_apply(
        'suppliers',
        jsonb_build_array(jsonb_build_object(
            'code','ZZFIX125-SUP-1', 'legal_name','ZZFIX125 Import Works Pte Ltd',
            'country','SG', 'counterparty_type','goods_supplier', 'tax_id','ZZFIX125TAX1',
            -- 下面这些是模板里的可选列,操作员留空 → CSV 给空字符串
            'address','', 'short_name','', 'credit_rating','', 'incoterm','',
            'payment_terms','', 'notes','', 'supplier_types','')),
        'fixture-125.csv', false);

    IF NOT EXISTS (SELECT 1 FROM suppliers WHERE code='ZZFIX125-SUP-1') THEN
        RAISE EXCEPTION 'FIXTURE 125C 失败:一次照着模板填的导入【没有成功】(报告 %)', v_rep;
    END IF;

    -- 空格子走的是"省掉"这条路,所以默认值必须生效 —— 而不是落成 NULL。
    IF (SELECT supplier_types FROM suppliers WHERE code='ZZFIX125-SUP-1') IS DISTINCT FROM '{}'::text[] THEN
        RAISE EXCEPTION 'FIXTURE 125C 失败:supplier_types 不是默认值 {} —— 空格子被当成 NULL 写进去了';
    END IF;
    IF (SELECT status::text FROM suppliers WHERE code='ZZFIX125-SUP-1') <> 'draft' THEN
        RAISE EXCEPTION 'FIXTURE 125C 失败:status 不是默认值 draft';
    END IF;
    -- GENERATED 列由库自己算出来,而且算对了
    IF (SELECT supplies_goods FROM suppliers WHERE code='ZZFIX125-SUP-1') IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 125C 失败:supplies_goods 没有被数据库算成 true';
    END IF;

    -- ══════════ D · 同一条路在【每一张表】上都走得通 ═══════════════════════════
    -- 走查只碰到 suppliers,而实测六张表全中。一张一张地证明它们现在都收得下。
    SELECT code INTO v_kind FROM material_kinds
     WHERE may_ever_be_processed AND NOT has_condition_axes ORDER BY code LIMIT 1;

    PERFORM master_import_apply('materials', jsonb_build_array(jsonb_build_object(
        'code','ZZFIX125-MAT-1','name','ZZFIX125 material',
        'kind_code',v_kind,'may_be_processed',false,
        'unit','', 'spec','', 'notes','', 'chemistry','')), 'f125.csv', false);
    IF (SELECT unit FROM materials WHERE code='ZZFIX125-MAT-1') <> 'kg' THEN
        RAISE EXCEPTION 'FIXTURE 125D 失败:materials.unit 的默认值 kg 没有生效';
    END IF;

    PERFORM master_import_apply('customers', jsonb_build_array(jsonb_build_object(
        'code','ZZFIX125-CUS-1','legal_name','ZZFIX125 Buyer','country','SG',
        'tax_id','ZZFIX125TAX2','address','','notes','')), 'f125.csv', false);
    IF (SELECT credit_hold FROM customers WHERE code='ZZFIX125-CUS-1') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 125D 失败:customers.credit_hold 的默认值没有生效';
    END IF;

    PERFORM master_import_apply('departments', jsonb_build_array(jsonb_build_object(
        'code','ZZFIX125-DEP-1','name_en','ZZFIX125 Dept','name_zh','测试部','notes','')),
        'f125.csv', false);
    IF (SELECT is_active FROM departments WHERE code='ZZFIX125-DEP-1') IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 125D 失败:departments.is_active 的默认值没有生效';
    END IF;

    -- employees 顺带证明【引用按编号给】那一条:department_code 换成 department_id
    PERFORM master_import_apply('employees', jsonb_build_array(jsonb_build_object(
        'code','ZZFIX125-EMP-1','legal_name','ZZFIX125 Person',
        'employment_type','full_time','work_category','office','hire_date','2026-01-01',
        -- KPI-1:job_title 已从 employees 上删除。模板列是【从目录推导】的,
        -- 所以它自己变成了 position_id;而引用按【编号】给(position_code),
        -- 与 department_code 同一条 —— 操作员不可能手打 uuid。
        'department_code','ZZFIX125-DEP-1','position_code','CFO','notes','')), 'f125.csv', false);
    IF (SELECT employment_status FROM employees WHERE code='ZZFIX125-EMP-1') <> 'probation' THEN
        RAISE EXCEPTION 'FIXTURE 125D 失败:employees.employment_status 的默认值没有生效';
    END IF;
    IF (SELECT d.code FROM employees e JOIN departments d ON d.id=e.department_id
         WHERE e.code='ZZFIX125-EMP-1') <> 'ZZFIX125-DEP-1' THEN
        RAISE EXCEPTION 'FIXTURE 125D 失败:department_code 没有被换成 department_id';
    END IF;
    -- KPI-1:position_code → position_id 那条新映射也要被断言,
    -- 否则上面那一格只证明了"没报错",没证明它换对了。
    IF (SELECT p.code FROM employees e JOIN positions p ON p.id=e.position_id
         WHERE e.code='ZZFIX125-EMP-1') <> 'CFO' THEN
        RAISE EXCEPTION 'FIXTURE 125D 失败:position_code 没有被换成 position_id';
    END IF;

    PERFORM master_import_apply('storage_locations', jsonb_build_array(jsonb_build_object(
        'code','ZZFIX125-LOC-1','name','ZZFIX125 Bay','zone','','notes','')), 'f125.csv', false);
    IF (SELECT is_active FROM storage_locations WHERE code='ZZFIX125-LOC-1') IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 125D 失败:storage_locations.is_active 的默认值没有生效';
    END IF;

    SELECT count(*) INTO v_n FROM import_batches WHERE file_name IN ('fixture-125.csv','f125.csv');
    IF v_n <> 6 THEN
        RAISE EXCEPTION 'FIXTURE 125D 失败:六张表应当各留一条导入日志,实得 %', v_n;
    END IF;

    -- ══════════ E · 真正必填的列缺席,仍然【按名】失败 ═════════════════════════
    -- 【反方向】少了这一臂,一个"什么都省掉"的实现也能让 C/D 全绿。
    BEGIN
        PERFORM master_import_apply('storage_locations',
            jsonb_build_array(jsonb_build_object('code','ZZFIX125-LOC-2','name','')),
            'f125.csv', false);
        RAISE EXCEPTION 'FIXTURE 125E 失败:一个【必填且无默认值】的列留空,却被收下了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%IMPORT_ROW_NOT_NULL%' AND SQLERRM NOT LIKE '%IMPORT_FAILED%' THEN
            RAISE EXCEPTION 'FIXTURE 125E 失败:拒绝不是按名的 —— %', SQLERRM;
        END IF;
    END;

    -- ══════════ F · GENERATED 列若出现在文件里,按名拒,不吐原文 ════════════════
    BEGIN
        PERFORM master_import_apply('suppliers', jsonb_build_array(jsonb_build_object(
            'code','ZZFIX125-SUP-9','legal_name','ZZFIX125 Nine','country','SG',
            'counterparty_type','goods_supplier','tax_id','ZZFIX125TAX9',
            'supplies_goods','true')), 'f125.csv', false);
        RAISE EXCEPTION 'FIXTURE 125F 失败:文件里带着一个 GENERATED 列,却被收下了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%IMPORT_COLUMN_FORBIDDEN%' AND SQLERRM NOT LIKE '%IMPORT_FAILED%' THEN
            RAISE EXCEPTION 'FIXTURE 125F 失败:拒绝不是按名的 —— %', SQLERRM;
        END IF;
        IF SQLERRM LIKE '%non-DEFAULT%' THEN
            RAISE EXCEPTION 'FIXTURE 125F 失败:PostgreSQL 的原话漏了出来 —— %', SQLERRM;
        END IF;
    END;

END $$;
ROLLBACK;
