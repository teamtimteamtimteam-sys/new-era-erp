-- db/migrations/2026-08-01-perm1-permission-skeleton.sql
-- Permissions cut 1:骨架。【本切完全不生效】—— 迁移之后系统的行为与今天一模一样。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 统领性要求:权限模型还没定,而且要能【不改代码、不做迁移】地改。
-- 因此角色、权限、以及两者的映射【一律是数据】,不是枚举、不是代码常量、
-- 更不是写死在策略 SQL 里的条件。加一个角色、改一次授权,应当是界面上的
-- INSERT / DELETE,而不是一次发版。
--
-- 这套设计能成立的关键在 B6:未来所有 RLS 策略只调 has_permission('某个码'),
-- 【策略里出现的是权限码,不是角色名】。谁持有这个码由数据决定 —— 于是策略保持
-- 通用,授权保持可编辑。
--
-- 唯一诚实的例外见 B1(permissions 目录本身不开放增删),那里写明了理由。
-- ════════════════════════════════════════════════════════════════════════════
--
-- Pieces:
--   B1. permissions —— 可被控制的东西的目录(种子:13 个模块 + 3 个数据权限)
--   B2. roles —— 七个角色作为【起点】,is_system 保护管理员角色
--   B3. role_permissions —— 角色 × 权限,每条授权都附一句理由
--   B4. user_roles —— 人 × 角色,撤销是记录而不是删除
--   B5. 引导保证 —— 给现有用户授管理员 + "最后一个管理员"不可撤销
--   B6. 解析器 —— current_user_permissions / has_permission / current_user_employee
--   B7. 不动任何既有策略
--   附:preview_reprice_inbound_batch(只读试算)+ 与提交路径共用的拆分算术

BEGIN;

-- ============================================================================
-- B1. permissions:目录
-- ============================================================================
-- 【"一切皆数据"在这里有一个诚实的例外】:本表【不开放】INSERT/UPDATE/DELETE 策略。
-- 原因不是保守,而是新增一条权限【本身就不可能是纯数据】—— 一个新权限码只有在
-- 有代码去检查它的时候才有意义(某个策略、某个页面得先引用它)。所以扩充目录
-- 天然是"迁移级"的动作:代码与目录一起走。
-- 【可编辑的是角色与授权】(B2/B3),那才是 Tim 会反复调整的东西,它们是完全的数据。
CREATE TABLE public.permissions (
    code           text PRIMARY KEY,  -- 稳定标识,如 'module.finance' / 'data.view_prices'
    category       text NOT NULL CHECK (category IN ('module','data','action')),
    name_en        text NOT NULL,
    name_zh        text NOT NULL,
    description_en text,
    description_zh text,
    sort_order     integer NOT NULL DEFAULT 0
);

-- 无软删、无审计列:这是目录不是台账。
-- 删掉一条仍被角色引用的权限【应当是不可能的】—— role_permissions 的 FK
-- (ON DELETE RESTRICT)负责挡住。
ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on permissions"
    ON public.permissions FOR SELECT TO authenticated USING (true);

INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('module.suppliers',  'module', 'Suppliers',   '供应商',   'Supplier master data',                  '供应商主数据',           10),
    ('module.customers',  'module', 'Customers',   '客户',     'Customer master data',                  '客户主数据',             20),
    ('module.materials',  'module', 'Materials',   '物料',     'Material dictionary',                   '物料字典',               30),
    ('module.pricing',    'module', 'Pricing',     '定价',     'Pricing formulas, calculator, metal prices', '定价公式、计价器与金属行情', 40),
    ('module.purchasing', 'module', 'Purchasing',  '采购',     'Purchase orders and payment schedules', '采购单与付款计划',       50),
    ('module.inbound',    'module', 'Inbound',     '进料',     'Inbound batches and receiving',         '进料批次与收货',         60),
    ('module.output',     'module', 'Output',      '产出',     'Output batches and sales',              '产出批次与销售',         70),
    ('module.processing', 'module', 'Processing',  '加工',     'Processing runs and traceability',      '加工单与追溯',           80),
    ('module.inventory',  'module', 'Inventory',   '库存',     'Inventory and material balance',        '库存与物料平衡',         90),
    ('module.stocktakes', 'module', 'Stocktakes',  '盘点',     'Physical counts and adjustments',       '实物盘点与调整',        100),
    ('module.finance',    'module', 'Finance',     '财务',     'Ledger, receivables, payables, payments','总账、应收、应付与收付款', 110),
    ('module.hr',         'module', 'HR',          '人力资源', 'Employees, payroll and training',       '员工、薪资与培训',      120),
    ('module.tasks',      'module', 'Tasks',       '任务',     'Task board',                            '任务板',                130),
    -- 数据类权限:横切所有模块,控制"看得见哪一层数字"
    ('data.view_prices',  'data',   'View prices & costs', '查看价格与成本',
        'Unit prices, pricing formulas, costs and margins',   '单价、计价公式、成本与利润',            200),
    ('data.view_pay',     'data',   'View pay',            '查看薪酬',
        'Salary, CPF and payroll figures',                    '工资、公积金与薪资明细',                210),
    ('data.view_identity','data',   'View identity data',  '查看身份信息',
        'Identity numbers and work pass numbers',             '身份证件号与工作准证号',                220);

-- 【尚未播种 'action' 类】—— 过账分录、关闭期间、薪资过账这类"动作级"权限,
-- 日后【只是往本表加行】,不需要改表结构;等到有代码去检查它们时再加。

-- ============================================================================
-- B2. roles
-- ============================================================================
CREATE TABLE public.roles (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code           text NOT NULL UNIQUE,
    name_en        text NOT NULL,
    name_zh        text NOT NULL,
    description_en text,
    description_zh text,
    -- is_system:不可删除、不可停用、不可被摘掉这个标记的角色。只有管理员是。
    is_system      boolean NOT NULL DEFAULT false,
    is_active      boolean NOT NULL DEFAULT true,
    sort_order     integer NOT NULL DEFAULT 0,
    deleted_at     timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid DEFAULT auth.uid()
);

CREATE TRIGGER trg_roles_updated_at
    BEFORE UPDATE ON public.roles
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on roles"
    ON public.roles AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.guard_system_role()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.is_system THEN
            RAISE EXCEPTION 'SYSTEM_ROLE_PROTECTED|%', OLD.code;
        END IF;
        RETURN OLD;
    END IF;
    -- 停用、软删、或把 is_system 摘掉 —— 三条都是"让管理员角色失去意义",一并拒绝
    IF OLD.is_system AND (NOT NEW.is_active OR NEW.deleted_at IS NOT NULL OR NOT NEW.is_system) THEN
        RAISE EXCEPTION 'SYSTEM_ROLE_PROTECTED|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_roles_system_protected
    BEFORE UPDATE OR DELETE ON public.roles
    FOR EACH ROW EXECUTE FUNCTION public.guard_system_role();

-- 【这七个角色是起点,不是定论】。它们是数据:Tim 会按实际分工反复改名、增删、
-- 重新授权,那一切都该在界面上完成,不该再来一次迁移。
INSERT INTO public.roles (code, name_en, name_zh, description_en, description_zh, is_system, sort_order) VALUES
    ('admin',      'System Administrator', '系统管理员', 'Full access to everything',                  '拥有全部权限',               true,  10),
    ('finance',    'Finance',              '财务',       'Ledger, payables, receivables and costs',    '总账、应收应付与成本',       false, 20),
    ('operations', 'Operations',           '运营',       'Material flow without cost visibility',      '物料流转,不含成本可见性',   false, 30),
    ('warehouse',  'Warehouse & Field',    '仓储现场',   'Receiving, output, stock counts',            '收货、产出与盘点',           false, 40),
    ('hr',         'Human Resources',      '人力资源',   'Employee records, payroll and training',     '员工档案、薪资与培训',       false, 50),
    ('auditor',    'Read-only Auditor',    '只读审计',   'Sees everything, changes nothing',           '可查看一切,不能改动',       false, 60),
    ('employee',   'Employee Self-service','员工自助',   'Own records only',                           '仅限本人相关记录',           false, 70);

-- ============================================================================
-- B3. role_permissions
-- ============================================================================
CREATE TABLE public.role_permissions (
    role_id         uuid NOT NULL REFERENCES public.roles (id) ON DELETE CASCADE,
    permission_code text NOT NULL REFERENCES public.permissions (code) ON DELETE RESTRICT,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    PRIMARY KEY (role_id, permission_code)
);

ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on role_permissions"
    ON public.role_permissions AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- admin:全部 —— 定义上如此,不然它就不是管理员
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p WHERE r.code = 'admin';

-- finance:所有模块 + 看价格成本 —— 财务要对账就得穿透到每个模块的数字
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'finance' AND (p.category = 'module' OR p.code = 'data.view_prices');

-- operations:物料流转的各模块,【但不给 data.view_prices】——
-- 调度与加工不需要知道这批料多少钱,少一个人看得见成本就少一处泄露
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'operations' AND p.code IN (
    'module.suppliers','module.materials','module.purchasing','module.inbound',
    'module.output','module.processing','module.inventory','module.stocktakes');

-- warehouse:只有现场真正会碰的四个模块,不给任何数据类权限 ——
-- 过磅收货的人不需要看见价格,也不需要看见别人的身份信息
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'warehouse' AND p.code IN (
    'module.inbound','module.output','module.inventory','module.stocktakes');

-- hr:人力资源模块 + 薪酬 + 身份信息 —— 这两类数据正是 HR 的工作对象,
-- 也正是别人不该看见的东西
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'hr' AND p.code IN ('module.hr','data.view_pay','data.view_identity');

-- auditor:所有模块 + 看价格成本 —— 审计看不见成本就没法审;
-- 【只读由执行切次实现】(策略只放行 SELECT),不靠少给权限来假装只读
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
WHERE r.code = 'auditor' AND (p.category = 'module' OR p.code = 'data.view_prices');

-- employee:【一个模块权限都不给】—— 员工自助不是"给他半个模块",
-- 而是"只看得见与本人相关的行",那要靠 current_user_employee() 做行级限定,
-- 到执行切次单独处理。给模块权限反而会把整张表打开。

-- ============================================================================
-- B4. user_roles
-- ============================================================================
CREATE TABLE public.user_roles (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- auth.users 的 id;【不建到 auth 架构的外键】(与既有表一致,只存 uuid)
    user_id       uuid NOT NULL,
    role_id       uuid NOT NULL REFERENCES public.roles (id) ON DELETE RESTRICT,
    granted_at    timestamptz NOT NULL DEFAULT now(),
    granted_by    uuid,
    -- 撤销是【记录】不是删除:谁在什么时候因为什么收回了权限,这段历史要留着
    revoked_at    timestamptz,
    revoked_by    uuid,
    revoke_reason text
);

-- 同一个人对同一角色,同时只能有一条【未撤销】的授权(撤销后可再授)
CREATE UNIQUE INDEX idx_user_roles_active
    ON public.user_roles (user_id, role_id) WHERE revoked_at IS NULL;
CREATE INDEX idx_user_roles_user ON public.user_roles (user_id) WHERE revoked_at IS NULL;

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on user_roles"
    ON public.user_roles AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- 一个人可以持有多个角色;【有效权限是并集】(见 current_user_permissions)。

-- ============================================================================
-- B5. 引导保证 —— 本切最要紧的失效模式
-- ============================================================================
-- 【锁死场景】下一切打开强制执行的那一刻,如果系统里没有任何一个在册的管理员授权,
-- 那么没有人能再改权限、也没有人能给自己补上管理员 —— 包括 Tim 本人。
-- 那不是"配置错了",那是永久性地把所有人关在门外,只能靠直连数据库救回来。
-- 所以本切必须保证:迁移完成的那一刻起,至少有一个活着的管理员授权。

-- (1) 给【今天已存在的每一个】auth 用户授予管理员角色。
--     一个没有管理员的权限系统不是"空状态",是陷阱 —— 所以零用户直接报错。
DO $bootstrap$
DECLARE
    v_admin uuid;
    v_count integer;
BEGIN
    SELECT id INTO v_admin FROM roles WHERE code = 'admin';
    INSERT INTO user_roles (user_id, role_id)
    SELECT u.id, v_admin FROM auth.users u;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    IF v_count = 0 THEN
        RAISE EXCEPTION 'BOOTSTRAP_NO_USERS|no auth users exist; a permission system with no administrator would lock everyone out';
    END IF;
    RAISE NOTICE 'permission bootstrap: granted admin to % user(s)', v_count;
END
$bootstrap$;

-- (2) 不许撤到零个管理员。同样是为了上面那个锁死场景 ——
--     【请不要因为"看起来多余"而删掉这个守卫】:它防的是一次点击造成的不可逆状态。
CREATE OR REPLACE FUNCTION public.guard_last_admin()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    -- 只在"撤销"或"删除"时检查;新授权与其它字段更新一概放行
    IF TG_OP = 'DELETE' OR (OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL) THEN
        -- 除本行之外,是否还剩至少一条【未撤销】且指向【在册启用的 is_system 角色】的授权
        IF NOT EXISTS (
            SELECT 1
            FROM user_roles ur
            JOIN roles r ON r.id = ur.role_id
            WHERE ur.id <> OLD.id
              AND ur.revoked_at IS NULL
              AND r.is_system
              AND r.is_active
              AND r.deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'LAST_ADMIN_PROTECTED';
        END IF;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$fn$;

CREATE TRIGGER trg_user_roles_last_admin
    BEFORE UPDATE OR DELETE ON public.user_roles
    FOR EACH ROW EXECUTE FUNCTION public.guard_last_admin();

-- ============================================================================
-- B6. 解析器 —— 执行切次要站在这三个函数上
-- ============================================================================
-- 三个都是 SECURITY DEFINER:它们【必须】能读 roles / role_permissions / user_roles,
-- 而调用者对这几张表可能一点权限都没有(执行切次会收紧)。定义者身份执行时
-- search_path 必须显式钉死 —— 否则调用方可以把一个同名的假表放进自己的 schema 里,
-- 让函数去读它。这是 SECURITY DEFINER 的标准防线,不是可选项。

-- 有效权限 = 该用户【所有未撤销授权】所指向的【在册启用角色】的权限并集。
-- 未登录或未授任何角色 → 空数组(而不是 NULL,调用方就不必到处判空)。
CREATE OR REPLACE FUNCTION public.current_user_permissions()
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
    SELECT COALESCE(array_agg(DISTINCT rp.permission_code), ARRAY[]::text[])
    FROM user_roles ur
    JOIN roles r ON r.id = ur.role_id
    JOIN role_permissions rp ON rp.role_id = r.id
    WHERE ur.user_id = auth.uid()
      AND ur.revoked_at IS NULL
      AND r.is_active
      AND r.deleted_at IS NULL;
$function$;

-- 【未来每一条 RLS 策略都调这个函数】。策略里写的是权限码,不是角色名 ——
-- 于是"谁有这个权限"永远是数据问题,改授权不用改策略。
CREATE OR REPLACE FUNCTION public.has_permission(p_code text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
    SELECT p_code = ANY (current_user_permissions());
$function$;

-- 当前登录者对应的员工行(没有则 NULL)。员工自助的行级限定要靠它。
CREATE OR REPLACE FUNCTION public.current_user_employee()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
    SELECT e.id FROM employees e
    WHERE e.user_id = auth.uid() AND e.deleted_at IS NULL
    LIMIT 1;
$function$;

-- ============================================================================
-- B7. 本切【不改动任何既有 RLS 策略】。
-- 上面新建的四张表各自带自己的策略,除此之外一行既有策略都没碰 ——
-- 强制执行是下一切的事,本切之后系统行为与今天完全一致。
-- ============================================================================

-- ============================================================================
-- 附:preview_reprice_inbound_batch —— 化验影响预览要的只读试算
-- ============================================================================
-- 【为什么要它】cut 5b 的预览面板在 TypeScript 里把 1200/5000 的拆分算术又写了
-- 一遍(assayImpact.ts),因为 DB 只在提交那一刻算这些数、没有试算入口。
-- 两份实现迟早会分叉,所以把算术抽成一个纯函数,预览与提交【共用同一份】:
--   reprice_split(quantity, remaining, old_price, new_price) —— 纯算术,IMMUTABLE;
--   reprice_inbound_batch  → 调它拿到拆分,再去写库、过账;
--   preview_reprice_inbound_batch → 调它拿到同样的拆分,什么都不写。
-- 于是"预览说会怎样"与"提交实际怎样"不可能不一致 —— 与当初把
-- set_inbound_unit_price 和 apply_assay_result 统一到 reprice_inbound_batch
-- 是同一套做法。
CREATE OR REPLACE FUNCTION public.reprice_split(
    p_quantity numeric,
    p_remaining numeric,
    p_old_price numeric,
    p_new_price numeric
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $function$
    -- ratio 用未取整的值参与乘法(与历来的入账口径一致),仅在输出时取到 4 位
    SELECT jsonb_build_object(
        'delta_usd', d.delta,
        'in_stock_ratio', round(d.ratio, 4),
        'inventory_share_usd', d.inv,
        'cost_share_usd', round(d.delta - d.inv, 2)
    )
    FROM (
        SELECT delta, ratio, round(delta * ratio, 2) AS inv
        FROM (
            SELECT round(p_quantity * (p_new_price - COALESCE(p_old_price, 0)), 2) AS delta,
                   CASE WHEN p_quantity = 0 THEN 1
                        ELSE LEAST(1, GREATEST(0, p_remaining / p_quantity)) END AS ratio
        ) x
    ) d;
$function$;

-- 提交路径改为调用共享算术(其余逻辑逐字不变)
CREATE OR REPLACE FUNCTION public.reprice_inbound_batch(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text DEFAULT 'USD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_old       numeric;
    v_deleted   timestamptz;
    v_qty       numeric;
    v_remaining numeric;
    v_code      text;
    v_fx        numeric;
    v_usd       numeric;
    v_split     jsonb;
    v_delta     numeric;
    v_ratio     numeric;
    v_inv       numeric := 0;
    v_cost      numeric := 0;
    v_lines     jsonb;
    v_je        jsonb := NULL;
BEGIN
    SELECT unit_price, deleted_at, quantity, remaining_qty, code
    INTO v_old, v_deleted, v_qty, v_remaining, v_code
    FROM inbound_batches WHERE id = p_inbound_batch_id FOR UPDATE;
    IF NOT FOUND OR v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;
    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_currency = 'USD' THEN
        v_fx := 1;
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;

    v_usd := round(p_unit_price * v_fx, 4);  -- 单价 4 位小数,与 unit_cost_usd 精度一致

    -- GUC 放行本函数内的 unit_price 更新(guard_inbound_price_change),用毕即清,
    -- 免得同事务内后续的直改被误放行(同 movement_ctx 模式)。
    PERFORM set_config('evoltrya.price_ctx', 'set_inbound_unit_price', true);
    UPDATE inbound_batches
    SET unit_price = v_usd, updated_by = v_user, updated_at = now()
    WHERE id = p_inbound_batch_id;
    PERFORM set_config('evoltrya.price_ctx', '', true);

    INSERT INTO price_history (inbound_batch_id, old_unit_price, new_unit_price, currency, original_price, fx_rate, notes, created_by)
    VALUES (p_inbound_batch_id, v_old, v_usd, p_currency, p_unit_price, v_fx, p_notes, v_user);

    -- cut 2a:计价即入账 —— 整批数量 × 价差(负债在收货整批上成立,非剩余量)。
    -- 记于定价日 CURRENT_DATE(到货日尚无金额,刻意如此);USD 口径(原币在 price_history)。
    -- 拆分算术来自 reprice_split —— 与 preview_reprice_inbound_batch 共用同一份。
    v_split := reprice_split(v_qty, v_remaining, v_old, v_usd);
    v_delta := (v_split->>'delta_usd')::numeric;
    v_ratio := (v_split->>'in_stock_ratio')::numeric;

    IF v_delta <> 0 THEN
        -- 拆账:在库份额进 1200,已消耗份额进 5000;贷方(负差时借方)恒 2000
        v_inv  := (v_split->>'inventory_share_usd')::numeric;
        v_cost := (v_split->>'cost_share_usd')::numeric;

        v_lines := '[]'::jsonb;
        IF abs(v_inv) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '1200',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', 'USD', 'amount_ccy', abs(v_inv),
                'line_memo', 'in-stock share');
        END IF;
        IF abs(v_cost) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '5000',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', 'USD', 'amount_ccy', abs(v_cost),
                'line_memo', 'consumed share');
        END IF;
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2000',
            'side', CASE WHEN v_delta > 0 THEN 'credit' ELSE 'debit' END,
            'currency', 'USD', 'amount_ccy', abs(v_delta));

        v_je := post_journal_entry(
            CURRENT_DATE,
            'Pricing ' || v_code,
            'purchase',
            p_inbound_batch_id,
            v_lines
        );
    END IF;

    RETURN jsonb_build_object(
        -- 旧返回键原样保留(既有调用方靠它们)
        'batch_id', p_inbound_batch_id,
        'unit_price_usd', v_usd,
        -- cut 5a 起的完整分解(界面与对账都要能逐项交代)
        'batch_code', v_code,
        'old_unit_price', v_old,
        'new_unit_price', v_usd,
        'price_delta_usd', v_delta,
        'in_stock_ratio', v_ratio,
        'inventory_share_usd', v_inv,
        'cost_share_usd', v_cost,
        'journal_code', v_je->>'code'
    );
END;
$function$;

-- 只读试算:算出【提交会得到什么】,但一个字都不写。
-- p_new_unit_price 按 USD 口径给(与 apply_assay_result 传给提交路径的一致)。
CREATE OR REPLACE FUNCTION public.preview_reprice_inbound_batch(
    p_inbound_batch_id uuid,
    p_new_unit_price numeric
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $function$
DECLARE
    v_old       numeric;
    v_qty       numeric;
    v_remaining numeric;
    v_usd       numeric;
    v_split     jsonb;
BEGIN
    SELECT unit_price, quantity, remaining_qty
    INTO v_old, v_qty, v_remaining
    FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    IF p_new_unit_price IS NULL OR p_new_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;

    -- 与提交路径同一舍入(USD 时 fx = 1)
    v_usd := round(p_new_unit_price, 4);
    v_split := reprice_split(v_qty, v_remaining, v_old, v_usd);

    RETURN jsonb_build_object(
        'old_unit_price', v_old,
        'new_unit_price', v_usd,
        'delta_usd', (v_split->>'delta_usd')::numeric,
        'in_stock_ratio', (v_split->>'in_stock_ratio')::numeric,
        'inventory_share_usd', (v_split->>'inventory_share_usd')::numeric,
        'cost_share_usd', (v_split->>'cost_share_usd')::numeric
    );
END;
$function$;

COMMIT;
