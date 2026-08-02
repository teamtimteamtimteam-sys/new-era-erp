-- db/migrations/2026-08-06-hr2c-monthly-accrual.sql
-- HR cut 2c:年假从"转正时整年解锁"改为【按月累积】。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【累积是派生的,不是定时写出来的】
-- 当年度的年假余额【读的时候算】,没有 cron、没有定时函数、没有任何按月的写入。
-- 理由很具体:本项目的 Supabase 在免费档会【自动暂停】,定时器会静悄悄地跳过某个月,
-- 而且没有任何人会发现 —— 直到某个员工的余额少了两天,而账上看不出少在哪。
-- 派生出来的数永远自洽:同一份 employment_history + 同一张费率表,算多少次都一样。
--
-- 【累积从入职日起算,不是从转正起算】法定口径:满三个月才产生权利,但权利【回溯到
-- 入职日】累积。试用期照常累积、照常不能请 —— submit_leave_request 的
-- PROBATION_NO_ANNUAL_LEAVE 一个字都没改。
--
-- 【最容易做错的一条:按"那个月当时的类别"算,不是按"现在的类别"乘月数】
-- 一个人 7 月从车间转到办公室,前 6 个月按 1.5、后 6 个月按 2.0 = 21 天,【不是 24】。
-- 所以必须走 employment_history,而不是拿当前类别乘 12。费率表也因此必须是
-- 【生效日期式】的:费率本身改了,改之前的月份保留旧费率。
--
-- 【费率有三个层级,一个解析器】
--   员工专属 override(生效日期式)→ 类别费率(生效日期式)→ 0。
--   override 的 days_per_month 允许为 NULL,含义是"从这天起回到类别费率" ——
--   没有这条,一个当年谈了 1.5 的人后来转到办公室就永远比同事少,回不去。
--   解析逻辑【只有一处实现】:leave_accrual_rate()。任何地方要用都调它。
--
-- 【annual_leave_days 这一列没了】一个事实两个家,就是 monthly_salary / gross_pay
-- 那个 bug 再来一次。全库 6 处、界面 7 处引用它(其中 2 处会写),本切一次性搬完:
-- 屏幕上的年度数字改为【派生的年度费率】(月费率 × 12),再也不可能与累积用的数打架。
--
-- 【超支变成不可能】submit_leave_request 按【休假开始日】那天的累积量校验,不是按
-- 提交日。一月里订十二月的假没问题 —— 到十二月那些天已经挣到了;订"到那天也挣不到"
-- 的天数则被拒。于是"请了却没挣到"这个状态不存在,不需要任何扣款规则或合同条款。
--
-- 【结转仍然是实体行】上一年结转来的天数照旧是 leave_grants 里的行,带自己的失效日。
-- 只有【当年度的累积】是派生的。两个来源在同一条"先用旧的"顺序里消耗:
-- 结转行(有失效日)排在前,当年累积(永不失效)排在后。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. 费率表 —— 生效日期式,类别费率与员工 override 同住一张表
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.leave_accrual_rates (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 【二选一】类别行 或 员工行。两个都填 / 都不填都不成立。
    work_category   text CHECK (work_category IN ('office','shopfloor')),
    employee_id     uuid REFERENCES public.employees (id),
    -- 每月累积天数。【员工行允许为 NULL】= 从 effective_from 起回到类别费率。
    days_per_month  numeric CHECK (days_per_month IS NULL OR days_per_month >= 0),
    -- 【没有 effective_to】"生效日 <= 该月 的最后一条胜出",于是不存在空档,也不存在重叠。
    effective_from  date NOT NULL,
    -- 【override 必须说明是谁、为什么谈的】—— 一份谈定的年假是合同条款,要有痕迹。
    reason          text,
    notes           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid DEFAULT auth.uid(),

    CONSTRAINT leave_accrual_rates_target_shape CHECK (
        (work_category IS NOT NULL AND employee_id IS NULL)
        OR (work_category IS NULL AND employee_id IS NOT NULL)),
    -- 类别行必须有费率(它是兜底,兜底不能是空的);员工行可以是 NULL(= 回到类别)
    CONSTRAINT leave_accrual_rates_category_rate_required CHECK (
        employee_id IS NOT NULL OR days_per_month IS NOT NULL),
    CONSTRAINT leave_accrual_rates_override_reason CHECK (
        employee_id IS NULL OR (reason IS NOT NULL AND btrim(reason) <> ''))
);

CREATE UNIQUE INDEX idx_leave_accrual_rates_category
    ON public.leave_accrual_rates (work_category, effective_from) WHERE work_category IS NOT NULL;
CREATE UNIQUE INDEX idx_leave_accrual_rates_employee
    ON public.leave_accrual_rates (employee_id, effective_from) WHERE employee_id IS NOT NULL;

CREATE TRIGGER trg_leave_accrual_rates_updated_at
    BEFORE UPDATE ON public.leave_accrual_rates
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

COMMENT ON COLUMN public.leave_accrual_rates.days_per_month IS
    '每月累积天数。员工行为 NULL 表示"从 effective_from 起回到类别费率" —— 没有这条,'
    '一个谈过低费率的人就再也回不到同事的水平。类别行不许为 NULL。';
COMMENT ON COLUMN public.leave_accrual_rates.effective_from IS
    '生效日。【没有 effective_to】:某个月适用的是"生效日 <= 该月首日"里最新的那一条。'
    '于是不存在空档与重叠,也让"费率改了,改之前的月份保留旧费率"成为自动的结果。';

ALTER TABLE public.leave_accrual_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "leave_accrual_rates select by permission"
    ON public.leave_accrual_rates AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "leave_accrual_rates select own rows"
    ON public.leave_accrual_rates AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());
CREATE POLICY "leave_accrual_rates insert by permission"
    ON public.leave_accrual_rates AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "leave_accrual_rates update by permission"
    ON public.leave_accrual_rates AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "leave_accrual_rates delete by permission"
    ON public.leave_accrual_rates AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- 【运行期配置 / RUNTIME CONFIG(OPS-1 分类)】HR 会在界面上加 override 行,
-- 所以线上与镜像不一致是正常的;镜像里那两行是全新安装的默认值,不与线上比对。
-- 生效日取一个远早于任何入职日的日期,好让"一直如此"有个落点。
INSERT INTO public.leave_accrual_rates (work_category, days_per_month, effective_from, notes) VALUES
    ('office',    2.0, '2000-01-01', 'Handbook: 24 days per year for office staff.'),
    ('shopfloor', 1.5, '2000-01-01', 'Handbook: 18 days per year for shopfloor staff.');

-- ════════════════════════════════════════════════════════════════════════════
-- 2. employment_history 记录工种类别 —— 没有它,B3 那条根本无从走起
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.employment_history
    ADD COLUMN work_category text CHECK (work_category IN ('office','shopfloor'));

COMMENT ON COLUMN public.employment_history.work_category IS
    '这次变动之后的工种类别(office/shopfloor)。按月累积要按【那个月当时的类别】取费率,'
    '所以类别的变更必须留痕。历史行没填时,解析器回落到最早一条有值的记录,再回落到 employees 当前值。';

ALTER TABLE public.employment_history
    DROP CONSTRAINT employment_history_change_type_check;
ALTER TABLE public.employment_history
    ADD CONSTRAINT employment_history_change_type_check CHECK (
        change_type = ANY (ARRAY['hired','confirmed','promotion','transfer','type_change',
                                 'status_change','separated','salary_change','category_change'])
    );

ALTER TABLE public.employment_history
    ADD CONSTRAINT employment_history_category_shape CHECK (
        change_type <> 'category_change' OR work_category IS NOT NULL
    );

GRANT SELECT (work_category) ON public.employment_history TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- 3. 消耗要能记在【派生的当年累积】上,而不只是记在授予行上
-- ════════════════════════════════════════════════════════════════════════════
-- 当年度累积没有 leave_grants 行可挂,所以外键放开为可空,另加 accrual_year 作判别。
-- 【二选一】:挂在授予行上,或挂在某一年的累积池上。
ALTER TABLE public.leave_consumption
    ALTER COLUMN leave_grant_id DROP NOT NULL;
ALTER TABLE public.leave_consumption
    ADD COLUMN accrual_year integer;
ALTER TABLE public.leave_consumption
    ADD CONSTRAINT leave_consumption_source_shape CHECK (
        (leave_grant_id IS NOT NULL AND accrual_year IS NULL)
        OR (leave_grant_id IS NULL AND accrual_year IS NOT NULL)
    );

CREATE INDEX idx_leave_consumption_accrual_year
    ON public.leave_consumption (accrual_year) WHERE accrual_year IS NOT NULL;

COMMENT ON COLUMN public.leave_consumption.accrual_year IS
    '这笔消耗扣的是哪一年的【派生累积】。leave_grant_id 为空时必填,反之必空 —— '
    '一笔消耗只能有一个来源,否则同一天会被算两次。';

GRANT SELECT (accrual_year) ON public.leave_consumption TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- 4. 解析器 —— 【全库只有这一处】实现"某人某月适用哪个费率"
-- ════════════════════════════════════════════════════════════════════════════
-- 顺序:该月及以前生效的、最新的员工 override(days_per_month 非空)→ 同样口径的类别费率 → 0。
-- override 写着 NULL 就是"回到类别",所以下面是"取到了但值为空 ⇒ 继续往下找"。
CREATE OR REPLACE FUNCTION public.leave_accrual_rate(p_employee_id uuid, p_work_category text, p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_days numeric;
    v_from date;
BEGIN
    SELECT r.days_per_month, r.effective_from INTO v_days, v_from
    FROM leave_accrual_rates r
    WHERE r.employee_id = p_employee_id AND r.effective_from <= p_month
    ORDER BY r.effective_from DESC
    LIMIT 1;

    IF v_days IS NOT NULL THEN
        RETURN jsonb_build_object('days_per_month', v_days, 'source', 'override',
                                  'effective_from', v_from);
    END IF;

    SELECT r.days_per_month, r.effective_from INTO v_days, v_from
    FROM leave_accrual_rates r
    WHERE r.work_category = p_work_category AND r.effective_from <= p_month
    ORDER BY r.effective_from DESC
    LIMIT 1;

    IF v_days IS NULL THEN
        RETURN jsonb_build_object('days_per_month', 0, 'source', 'none', 'effective_from', NULL);
    END IF;
    RETURN jsonb_build_object('days_per_month', v_days, 'source', 'category',
                              'effective_from', v_from);
END;
$function$;

-- 某人某月当时的工种类别。回落两层,好让没有历史记录的既有数据照样算得对。
CREATE OR REPLACE FUNCTION public.employee_work_category_at(p_employee_id uuid, p_month date)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_cat text;
BEGIN
    SELECT h.work_category INTO v_cat
    FROM employment_history h
    WHERE h.employee_id = p_employee_id AND h.work_category IS NOT NULL
      AND h.effective_date <= p_month
    ORDER BY h.effective_date DESC, h.created_at DESC
    LIMIT 1;
    IF v_cat IS NOT NULL THEN RETURN v_cat; END IF;

    -- 该月之前没有记录:用【最早一条】有记录的类别(入职时那条),
    -- 再不行才用档案上的当前值 —— 那是既有数据的情形,当时没有变更过。
    SELECT h.work_category INTO v_cat
    FROM employment_history h
    WHERE h.employee_id = p_employee_id AND h.work_category IS NOT NULL
    ORDER BY h.effective_date, h.created_at
    LIMIT 1;
    IF v_cat IS NOT NULL THEN RETURN v_cat; END IF;

    SELECT e.work_category INTO v_cat FROM employees e WHERE e.id = p_employee_id;
    RETURN v_cat;
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 5. 累积 —— 逐月走,每个月各取各的费率
-- ════════════════════════════════════════════════════════════════════════════
-- 【入职当月算整月】沿用 grant_annual_leave 原来的折算口径,不另立第二套。
-- 【某个月要满了才计入】累积是阶梯函数,永远不会跑到服务年限前面去(B4)。
-- 【离职后冻结】算到最后在职日为止,不算到今天(Part F)。
CREATE OR REPLACE FUNCTION public.accrued_annual_leave_detail(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp      record;
    v_year     integer := EXTRACT(YEAR FROM p_as_of)::integer;
    v_asof     date;
    v_first    date;
    v_last     date;
    v_m        date;
    v_cat      text;
    v_rate     jsonb;
    v_raw      numeric := 0;
    v_months   jsonb := '[]'::jsonb;
BEGIN
    SELECT id, code, hire_date, work_category, employment_status, separation_date
    INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    -- 【离职冻结】最后在职日之后不再累积
    v_asof := p_as_of;
    IF v_emp.separation_date IS NOT NULL AND v_emp.separation_date < v_asof THEN
        v_asof := v_emp.separation_date;
    END IF;

    -- 当年度的第一个月:入职当月与年初,取靠后的那个
    v_first := GREATEST(date_trunc('month', v_emp.hire_date)::date, make_date(v_year, 1, 1));
    -- 最后一个【已满】的月:as_of 次日所在月的上一个月;再按年底截断
    v_last  := LEAST((date_trunc('month', v_asof + 1) - interval '1 month')::date,
                     make_date(v_year, 12, 1));

    IF v_asof < make_date(v_year, 1, 1) OR v_last < v_first THEN
        RETURN jsonb_build_object(
            'employee_id', p_employee_id, 'employee_code', v_emp.code,
            'leave_year', v_year, 'as_of', p_as_of, 'effective_as_of', v_asof,
            'months', '[]'::jsonb, 'raw_days', 0, 'accrued_days', 0,
            'frozen_at_separation', v_emp.separation_date IS NOT NULL AND v_emp.separation_date < p_as_of);
    END IF;

    v_m := v_first;
    WHILE v_m <= v_last LOOP
        v_cat  := employee_work_category_at(p_employee_id, v_m);
        v_rate := leave_accrual_rate(p_employee_id, v_cat, v_m);
        v_raw  := v_raw + (v_rate->>'days_per_month')::numeric;
        v_months := v_months || jsonb_build_object(
            'month', to_char(v_m, 'YYYY-MM'),
            'work_category', v_cat,
            'days_per_month', (v_rate->>'days_per_month')::numeric,
            'rate_source', v_rate->>'source',
            'rate_effective_from', v_rate->>'effective_from');
        v_m := (v_m + interval '1 month')::date;
    END LOOP;

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code,
        'leave_year', v_year, 'as_of', p_as_of, 'effective_as_of', v_asof,
        'first_month', to_char(v_first, 'YYYY-MM'), 'last_complete_month', to_char(v_last, 'YYYY-MM'),
        'months', v_months,
        'raw_days', v_raw,
        -- 【可请的余额向下取到 0.5 天】(B5);补偿用【同一个】数字,
        -- 于是员工一整年看到的那个数,就是最后拿到钱的那个数。
        'accrued_days', trim_scale(floor(v_raw * 2) / 2),
        'frozen_at_separation', v_emp.separation_date IS NOT NULL AND v_emp.separation_date < p_as_of);
END;
$function$;

CREATE OR REPLACE FUNCTION public.accrued_annual_leave(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT (accrued_annual_leave_detail(p_employee_id, p_as_of)->>'accrued_days')::numeric;
$function$;

-- 当年度累积里已经用掉的部分(draw − release)
CREATE OR REPLACE FUNCTION public.consumed_from_accrual(p_employee_id uuid, p_leave_year integer)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(SUM(CASE WHEN c.entry_type = 'draw' THEN c.days ELSE -c.days END), 0)
    FROM leave_consumption c
    JOIN leave_requests r ON r.id = c.leave_request_id
    WHERE c.accrual_year = p_leave_year AND r.employee_id = p_employee_id;
$function$;

-- 可请的当年度累积余额(不含结转)。【不做权限检查】—— 它是个算式,
-- 谁看得见哪一行由调用方(视图的谓词 / leave_balance 的检查)决定。
CREATE OR REPLACE FUNCTION public.available_annual_accrual(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT accrued_annual_leave(p_employee_id, p_as_of)
         - consumed_from_accrual(p_employee_id, EXTRACT(YEAR FROM p_as_of)::integer);
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 6. leave_balance —— 结转授予行 + 派生的当年累积,两个来源一份余额
-- ════════════════════════════════════════════════════════════════════════════
-- 【HR-2a 那个重复计数的坑就在这一段】。原来的 carried_out 扣减照旧保留:结转是把
-- 剩余【搬走】,不是复制一份。现在多了第二个来源,于是多一条纪律:
-- 当年度的累积【只以派生形式出现一次】,不再有对应的授予行(见本文件末尾的 E1)。
-- 【算式与权限分开】视图是属主权限的,它按自己的谓词决定谁看得见哪一行,不能被
-- leave_balance 的权限检查挡住;而算式只该有一份。于是内层只算,外层只查权限。
CREATE OR REPLACE FUNCTION public.leave_balance_internal(p_employee_id uuid, p_leave_type_code text DEFAULT 'annual'::text, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_break   jsonb := '[]'::jsonb;
    v_granted numeric := 0;
    v_used    numeric := 0;
    v_expired numeric := 0;
    v_avail   numeric := 0;
    v_accrued numeric := 0;
    v_acc_used numeric := 0;
    v_year    integer := EXTRACT(YEAR FROM p_as_of)::integer;
    r         record;
BEGIN
    FOR r IN
        SELECT g.id, g.leave_year, g.days, g.granted_on, g.expires_on, g.grant_type,
               COALESCE((SELECT SUM(CASE WHEN c.entry_type='draw' THEN c.days ELSE -c.days END)
                         FROM leave_consumption c WHERE c.leave_grant_id = g.id), 0) AS consumed,
               -- 【已被结转走的部分】。结转是把剩余【搬到】下一年的一笔新授予里,
               -- 不是复制一份 —— 若不在这里扣掉,同样的天数会在来源授予和结转授予里
               -- 【各算一次】,余额凭空翻倍。这一条是本切最容易做错的地方之一。
               COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                         WHERE cf.source_grant_id = g.id AND cf.grant_type = 'carry_forward'
                           AND cf.deleted_at IS NULL), 0) AS carried_out
        FROM leave_grants g
        WHERE g.employee_id = p_employee_id AND g.leave_type_code = p_leave_type_code
          AND g.deleted_at IS NULL AND g.granted_on <= p_as_of
        ORDER BY g.expires_on NULLS LAST, g.granted_on
    LOOP
        v_granted := v_granted + r.days;
        v_used := v_used + r.consumed;
        IF r.carried_out > 0 AND (r.days - r.consumed - r.carried_out) <= 0 THEN
            NULL;
        ELSIF r.expires_on IS NOT NULL AND r.expires_on < p_as_of THEN
            v_expired := v_expired + (r.days - r.consumed - r.carried_out);
        ELSE
            v_avail := v_avail + (r.days - r.consumed - r.carried_out);
        END IF;
        v_break := v_break || jsonb_build_object(
            'source', 'grant',
            'grant_id', r.id, 'leave_year', r.leave_year, 'grant_type', r.grant_type,
            'days', r.days, 'consumed', r.consumed, 'carried_forward_out', r.carried_out,
            'remaining', r.days - r.consumed - r.carried_out,
            'expires_on', r.expires_on,
            'status', CASE WHEN r.carried_out > 0 AND (r.days - r.consumed - r.carried_out) <= 0
                                THEN 'carried_forward'
                           WHEN r.expires_on IS NOT NULL AND r.expires_on < p_as_of
                                THEN 'expired' ELSE 'active' END);
    END LOOP;

    -- ── 第二个来源:当年度的派生累积(只有年假) ─────────────────────────────
    -- 【它没有 expires_on】—— 于是"先用旧的"天然把它排在结转行之后,
    -- 也于是失效逻辑【碰不到它】:没有可比的日期,当年挣的天数无从作废(D4)。
    IF p_leave_type_code = 'annual' THEN
        v_accrued  := accrued_annual_leave(p_employee_id, p_as_of);
        v_acc_used := consumed_from_accrual(p_employee_id, v_year);
        v_granted := v_granted + v_accrued;
        v_used    := v_used + v_acc_used;
        v_avail   := v_avail + (v_accrued - v_acc_used);
        v_break := v_break || jsonb_build_object(
            'source', 'accrual',
            'grant_id', NULL, 'leave_year', v_year, 'grant_type', 'monthly_accrual',
            'days', v_accrued, 'consumed', v_acc_used, 'carried_forward_out', 0,
            'remaining', v_accrued - v_acc_used,
            'expires_on', NULL, 'status', 'active');
    END IF;

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'leave_type_code', p_leave_type_code, 'as_of', p_as_of,
        'granted', v_granted, 'consumed', v_used, 'expired', v_expired,
        'accrued_this_year', v_accrued, 'consumed_from_accrual', v_acc_used,
        -- 【向下取到 0.5】—— 结转与消耗本就是 0.5 的整数倍,这里是防御性的一层
        'available', trim_scale(floor(v_avail * 2) / 2),
        'breakdown', v_break);
END;
$function$;

-- 对外的那一个:只多做一件事 —— 查权限。
CREATE OR REPLACE FUNCTION public.leave_balance(p_employee_id uuid, p_leave_type_code text DEFAULT 'annual'::text, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    RETURN leave_balance_internal(p_employee_id, p_leave_type_code, p_as_of);
END;
$function$;

-- 屏幕上的"年度天数"从此是【派生的年度费率】= 当月适用的月费率 × 12。
-- 它是一个【费率】,不是余额 —— 界面必须这样标它,否则一个上个月入职的人
-- 看到 24 会以为自己能请 24 天,而他只能请 2 天。
CREATE OR REPLACE FUNCTION public.annual_leave_rate_per_month(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT (leave_accrual_rate(
                p_employee_id,
                employee_work_category_at(p_employee_id, date_trunc('month', p_as_of)::date),
                date_trunc('month', p_as_of)::date
            )->>'days_per_month')::numeric;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 7. 提交:按【休假开始日】校验累积,不是按提交日
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.submit_leave_request(p_employee_id uuid, p_leave_type_code text, p_start date, p_end date, p_start_half boolean DEFAULT false, p_end_half boolean DEFAULT false, p_reason text DEFAULT NULL::text, p_certificate_ref text DEFAULT NULL::text, p_is_exception boolean DEFAULT false, p_exception_days numeric DEFAULT NULL::numeric, p_exception_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    record;
    v_type   record;
    v_days   numeric;
    v_taken  numeric;
    v_bal    jsonb;
    v_avail  numeric;
    v_code   text;
    v_req    record;
    v_clash  text;
BEGIN
    IF NOT (has_permission('module.hr.edit') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    IF p_is_exception AND NOT has_permission('module.hr.edit') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    SELECT id, code, employment_status INTO v_emp
    FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    SELECT * INTO v_type FROM leave_types WHERE code = p_leave_type_code;
    IF NOT FOUND THEN RAISE EXCEPTION 'LEAVE_TYPE_NOT_FOUND|%', p_leave_type_code; END IF;
    IF NOT v_type.is_active THEN RAISE EXCEPTION 'LEAVE_TYPE_INACTIVE|%', p_leave_type_code; END IF;

    -- 【一个字都没改】试用期照常累积,照常不能请。
    IF v_type.is_accrued AND v_emp.employment_status = 'probation' THEN
        RAISE EXCEPTION 'PROBATION_NO_ANNUAL_LEAVE';
    END IF;

    IF p_is_exception THEN
        IF p_exception_reason IS NULL OR btrim(p_exception_reason) = '' THEN
            RAISE EXCEPTION 'EXCEPTION_REASON_REQUIRED';
        END IF;
        IF p_exception_days IS NULL OR p_exception_days <= 0 THEN
            RAISE EXCEPTION 'EXCEPTION_DAYS_INVALID';
        END IF;
        v_days := p_exception_days;
    ELSE
        v_days := calculate_leave_days(p_start, p_end, p_start_half, p_end_half);
        IF v_days <= 0 THEN RAISE EXCEPTION 'NO_WORKING_DAYS|%|%', p_start, p_end; END IF;
    END IF;

    SELECT code INTO v_clash FROM leave_requests
    WHERE employee_id = p_employee_id AND deleted_at IS NULL
      AND status IN ('pending','approved')
      AND daterange(start_date, end_date, '[]') && daterange(p_start, p_end, '[]')
    LIMIT 1;
    IF v_clash IS NOT NULL THEN RAISE EXCEPTION 'OVERLAPPING_REQUEST|%', v_clash; END IF;

    IF v_type.requires_certificate_after_days IS NOT NULL
       AND (p_certificate_ref IS NULL OR btrim(p_certificate_ref) = '') THEN
        SELECT COALESCE(SUM(r.days), 0) INTO v_taken
        FROM leave_requests r
        WHERE r.employee_id = p_employee_id AND r.leave_type_code = p_leave_type_code
          AND r.deleted_at IS NULL AND r.status IN ('pending','approved')
          AND EXTRACT(YEAR FROM r.start_date) = EXTRACT(YEAR FROM p_start);
        IF v_taken + v_days > v_type.requires_certificate_after_days THEN
            RAISE EXCEPTION 'CERTIFICATE_REQUIRED|%|%', v_taken, v_type.requires_certificate_after_days;
        END IF;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- 【按休假开始日那天的累积量校验】,不是按提交日。
    -- 一月里订十二月的假是可以的 —— 到十二月那些天已经挣到了;
    -- 订"到那天也挣不到"的天数则当场被拒。于是"请了却没挣到"这个状态不存在,
    -- 不需要任何扣款规则,也不需要合同里加一条(C3,fixture 6 证明)。
    -- ══════════════════════════════════════════════════════════════════════
    IF v_type.is_accrued THEN
        v_bal := leave_balance(p_employee_id, p_leave_type_code, p_start);
        v_avail := (v_bal->>'available')::numeric;
        IF v_avail < v_days THEN
            RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE|%|%',
                trim_scale(v_avail), trim_scale(v_days);
        END IF;
    END IF;

    v_code := next_leave_request_code(p_start);
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date,
                                start_half_day, end_half_day, days, reason, certificate_ref,
                                is_exception, exception_reason)
    VALUES (v_code, p_employee_id, p_leave_type_code, p_start, p_end,
            p_start_half, p_end_half, v_days, p_reason, p_certificate_ref,
            p_is_exception, CASE WHEN p_is_exception THEN p_exception_reason ELSE NULL END)
    RETURNING * INTO v_req;

    RETURN jsonb_build_object('request_id', v_req.id, 'code', v_req.code,
                              'employee_code', v_emp.code, 'leave_type_code', p_leave_type_code,
                              'days', v_days, 'status', v_req.status,
                              'is_exception', v_req.is_exception);
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 8. 审批:先吃结转行(有失效日),再吃当年累积(永不失效)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.decide_leave_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_req    record;
    v_type   record;
    v_need   numeric;
    v_take   numeric;
    v_bal    jsonb;
    v_avail  numeric;
    v_accrual numeric;
    g        record;
    v_used   jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_req FROM leave_requests WHERE id = p_request_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'REQUEST_NOT_FOUND'; END IF;
    IF v_req.status <> 'pending' THEN RAISE EXCEPTION 'REQUEST_NOT_PENDING|%', v_req.status; END IF;

    SELECT * INTO v_type FROM leave_types WHERE code = v_req.leave_type_code;

    IF NOT p_approve THEN
        UPDATE leave_requests SET status='rejected', decided_at=now(), decided_by=auth.uid(),
               decision_notes=p_notes, updated_by=auth.uid()
        WHERE id = p_request_id;
        RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','rejected');
    END IF;

    IF v_type.is_accrued THEN
        v_bal := leave_balance(v_req.employee_id, v_req.leave_type_code, v_req.start_date);
        v_avail := (v_bal->>'available')::numeric;
        IF v_avail < v_req.days THEN
            RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE|%|%',
                trim_scale(v_avail), trim_scale(v_req.days);
        END IF;

        v_need := v_req.days;
        -- ══════════════════════════════════════════════════════════════════
        -- 【先用旧的】:按 expires_on 从早到晚扣。
        -- 结转来的行有失效日,当年累积没有 —— 所以结转天数天然排在前面被先吃掉,
        -- 反过来的话它们会先烂掉,对员工是净损失。
        -- ══════════════════════════════════════════════════════════════════
        FOR g IN
            SELECT gr.id, gr.days, gr.expires_on, gr.leave_year, gr.grant_type,
                   gr.days
                   - COALESCE((SELECT SUM(CASE WHEN c.entry_type='draw' THEN c.days ELSE -c.days END)
                               FROM leave_consumption c WHERE c.leave_grant_id = gr.id), 0)
                   - COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                               WHERE cf.source_grant_id = gr.id AND cf.grant_type = 'carry_forward'
                                 AND cf.deleted_at IS NULL), 0) AS remaining
            FROM leave_grants gr
            WHERE gr.employee_id = v_req.employee_id AND gr.leave_type_code = v_req.leave_type_code
              AND gr.deleted_at IS NULL AND gr.granted_on <= v_req.start_date
              AND (gr.expires_on IS NULL OR gr.expires_on >= v_req.start_date)
            ORDER BY gr.expires_on NULLS LAST, gr.granted_on
        LOOP
            EXIT WHEN v_need <= 0;
            IF g.remaining <= 0 THEN CONTINUE; END IF;
            v_take := LEAST(g.remaining, v_need);
            INSERT INTO leave_consumption (leave_request_id, leave_grant_id, entry_type, days)
            VALUES (p_request_id, g.id, 'draw', v_take);
            v_need := v_need - v_take;
            v_used := v_used || jsonb_build_object('source', 'grant', 'grant_id', g.id,
                                                   'leave_year', g.leave_year,
                                                   'grant_type', g.grant_type,
                                                   'expires_on', g.expires_on, 'days', v_take);
        END LOOP;

        -- 结转吃完了还不够 → 从当年度的派生累积里扣(记 accrual_year,不挂授予行)
        IF v_need > 0 AND v_type.is_accrued THEN
            v_accrual := available_annual_accrual(v_req.employee_id, v_req.start_date);
            v_take := LEAST(v_accrual, v_need);
            IF v_take > 0 THEN
                INSERT INTO leave_consumption (leave_request_id, leave_grant_id, entry_type, days, accrual_year)
                VALUES (p_request_id, NULL, 'draw', v_take,
                        EXTRACT(YEAR FROM v_req.start_date)::integer);
                v_need := v_need - v_take;
                v_used := v_used || jsonb_build_object('source', 'accrual',
                                                       'leave_year', EXTRACT(YEAR FROM v_req.start_date)::integer,
                                                       'grant_type', 'monthly_accrual',
                                                       'expires_on', NULL, 'days', v_take);
            END IF;
        END IF;

        IF v_need > 0 THEN
            RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE|%|%',
                trim_scale(v_req.days - v_need), trim_scale(v_req.days);
        END IF;
    END IF;

    UPDATE leave_requests SET status='approved', decided_at=now(), decided_by=auth.uid(),
           decision_notes=p_notes, updated_by=auth.uid()
    WHERE id = p_request_id;

    RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','approved',
                              'days', v_req.days, 'consumed_from', v_used);
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 9. 年末结转:读【派生的当年累积】,不再读授予行(D3)
-- ════════════════════════════════════════════════════════════════════════════
-- 【只结转当年挣到、没用掉的部分】。上一年结转来的、今年仍没用掉的天数【就地作废】——
-- 那正是"结转后 12 个月失效"的规则(D4:用进废退只适用于上一年的结转,
-- 不适用于当年挣到的天数)。
CREATE OR REPLACE FUNCTION public.carry_forward_annual_leave(p_leave_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp     record;
    v_year_end date := make_date(p_leave_year, 12, 31);
    v_accrued numeric;
    v_used    numeric;
    v_balance numeric;
    v_rows    jsonb := '[]'::jsonb;
    v_count   integer := 0;
    v_total   numeric := 0;
BEGIN
    PERFORM require_permission('module.hr.edit');

    FOR v_emp IN
        SELECT e.id, e.code FROM employees e
        WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'
        ORDER BY e.code
    LOOP
        IF EXISTS (SELECT 1 FROM leave_grants g
                   WHERE g.employee_id = v_emp.id AND g.leave_type_code = 'annual'
                     AND g.grant_type = 'carry_forward' AND g.leave_year = p_leave_year + 1
                     AND g.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'CARRY_FORWARD_EXISTS|%|%', v_emp.code, p_leave_year;
        END IF;

        v_accrued := accrued_annual_leave(v_emp.id, v_year_end);
        v_used    := consumed_from_accrual(v_emp.id, p_leave_year);
        v_balance := v_accrued - v_used;

        IF v_balance IS NULL OR v_balance <= 0 THEN CONTINUE; END IF;

        INSERT INTO leave_grants (employee_id, leave_type_code, leave_year, days, granted_on,
                                  expires_on, grant_type, source_grant_id, notes)
        VALUES (v_emp.id, 'annual', p_leave_year + 1, v_balance,
                make_date(p_leave_year + 1, 1, 1),
                make_date(p_leave_year + 1, 12, 31),
                'carry_forward',
                -- 【没有来源授予行了】当年度是派生的,所以 source_grant_id 为空。
                -- leave_balance 的 carried_out 扣减因此对它无事可做,也就无从重复计数。
                NULL,
                format('Carried forward from %s monthly accrual (%s accrued, %s taken)',
                       p_leave_year, trim_scale(v_accrued), trim_scale(v_used)));

        v_count := v_count + 1;
        v_total := v_total + v_balance;
        v_rows := v_rows || jsonb_build_object('employee_code', v_emp.code, 'days', v_balance,
                                               'accrued', v_accrued, 'taken', v_used);
    END LOOP;

    RETURN jsonb_build_object('from_year', p_leave_year, 'into_year', p_leave_year + 1,
                              'employees', v_count, 'total_days', v_total,
                              'source', 'derived monthly accrual', 'detail', v_rows);
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 10. 补偿:累积【停在最后在职日】,不跑到今天(Part F)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.compute_leave_encashment(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp   record;
    v_bal   jsonb;
    v_days  numeric;
    v_basis numeric;
    v_dpw   numeric;
    v_daily numeric;
    v_asof  date;
BEGIN
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    SELECT id, code, legal_name, monthly_salary, separation_date INTO v_emp
    FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    IF v_emp.monthly_salary IS NULL THEN
        RAISE EXCEPTION 'SALARY_NOT_SET|%', v_emp.code;
    END IF;

    -- 【离职的人算到最后在职日为止】。跑到今天会把离职之后的月份也算进去 ——
    -- 那些月他并没有在职,那些天不是他挣的。
    v_asof := p_as_of;
    IF v_emp.separation_date IS NOT NULL AND v_emp.separation_date < v_asof THEN
        v_asof := v_emp.separation_date;
    END IF;

    v_bal := leave_balance(p_employee_id, 'annual', v_asof);
    -- 【与员工一整年看到的是同一个数】leave_balance 已经向下取到 0.5 天(B5)
    v_days := (v_bal->>'available')::numeric;
    v_basis := v_emp.monthly_salary;

    SELECT working_days_per_week INTO v_dpw FROM hr_settings WHERE id;

    v_daily := round((12.0 * v_basis) / (52.0 * v_dpw), 2);

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code,
        'as_of', p_as_of, 'effective_as_of', v_asof,
        'frozen_at_separation', v_emp.separation_date IS NOT NULL AND v_emp.separation_date < p_as_of,
        'unused_days', v_days,
        'monthly_fixed_gross_basis', v_basis,
        'basis_source', 'employees.monthly_salary (contracted fixed gross; excludes overtime, bonus, AWS, commission)',
        'daily_rate', v_daily,
        'daily_rate_formula', format('12 x monthly fixed gross / (52 x %s working days per week)', v_dpw),
        'rounding', 'accrual floored to 0.5 day; daily rate rounded to 2 dp, then multiplied by days and rounded to 2 dp',
        'indicative_amount', round(v_daily * v_days, 2),
        'journal_posted', false,
        'note', 'Indicative only. Payment is made by the outsourced payroll provider; no journal entry is created by this system.',
        'balance_detail', v_bal);
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 11. E1:旧的【当年度】年假授予行必须消失 —— 一个数只能有一个来源
-- ════════════════════════════════════════════════════════════════════════════
-- 结转行(grant_type = 'carry_forward')【一行都不动】,它们是另一个来源(E2)。
DO $e1$
DECLARE v_n integer; v_c integer;
BEGIN
    SELECT count(*) INTO v_n FROM leave_grants
    WHERE leave_type_code = 'annual' AND grant_type IN ('entitlement','pro_rata')
      AND deleted_at IS NULL;

    SELECT count(*) INTO v_c FROM leave_consumption c
    JOIN leave_grants g ON g.id = c.leave_grant_id
    WHERE g.leave_type_code = 'annual' AND g.grant_type IN ('entitlement','pro_rata');

    RAISE NOTICE 'E1: % current-year annual grant row(s) to remove, % consumption row(s) attached', v_n, v_c;
    IF v_c > 0 THEN
        RAISE EXCEPTION 'E1_CONSUMPTION_ATTACHED|%|consumption rows reference current-year grants; migrate them before deleting', v_c;
    END IF;

    DELETE FROM leave_grants
    WHERE leave_type_code = 'annual' AND grant_type IN ('entitlement','pro_rata');
END;
$e1$;

-- ════════════════════════════════════════════════════════════════════════════
-- 12. 拆掉旧模型:整年授予函数、24/18 的触发器字面量、employees.annual_leave_days
-- ════════════════════════════════════════════════════════════════════════════
-- 【grant_annual_leave 必须消失,不是留着不用】留着就是一把上了膛的枪:
-- 谁按一下,E1 刚删掉的那种"第二个来源"就原样回来了。它的折算口径已经搬进
-- accrued_annual_leave_detail(入职当月算整月),没有丢。
DROP FUNCTION IF EXISTS public.grant_annual_leave(uuid, integer);

DROP TRIGGER IF EXISTS trg_employees_leave_default ON public.employees;
DROP FUNCTION IF EXISTS public.default_employee_leave_days();

-- 视图按依赖顺序拆掉再重建(它们引用了要删的列)
DROP VIEW IF EXISTS public.employee_directory;
DROP VIEW IF EXISTS public.my_profile;
DROP VIEW IF EXISTS public.employees_masked;

ALTER TABLE public.employees DROP COLUMN annual_leave_days;

-- ════════════════════════════════════════════════════════════════════════════
-- 13. 三个视图重建:年度数字改为【派生的费率】,并补上"已累积"与"可请"
-- ════════════════════════════════════════════════════════════════════════════
-- 【只给一个年度数字是误导】屏幕上写"年假(天):24"给一个上个月入职的人看,
-- 他会以为能请 24 天,其实能请 2 天。所以三列一起给:
--   annual_leave_rate_days       年度【费率】(月费率 × 12)—— 界面必须按费率来标
--   annual_leave_accrued_days    到今天已经挣到的天数
--   annual_leave_available_days  扣掉已请、加上结转之后,现在真正能请的天数
-- 软删的行不算(那些函数对已删除的员工会报错),所以用 deleted_at 做守卫。
CREATE VIEW public.employees_masked WITH (security_invoker = off) AS
 SELECT id, code, legal_name, preferred_name, department_id, job_title, manager_id,
    employment_type, work_category, hire_date, probation_end_date, employment_status,
    separation_date, separation_type, separation_notes,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_email
            ELSE NULL::text
        END AS work_email,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_phone
            ELSE NULL::text
        END AS work_phone,
    residency_status,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN identity_no
            ELSE NULL::text
        END AS identity_no,
    work_pass_type,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_pass_no
            ELSE NULL::text
        END AS work_pass_no,
    work_pass_issue_date, work_pass_expiry_date, user_id, notes, deleted_at,
    created_at, created_by, updated_at, updated_by, confirmation_date,
        CASE
            WHEN has_permission('data.view_pay'::text) OR id = current_user_employee() THEN monthly_salary
            ELSE NULL::numeric
        END AS monthly_salary,
    monthly_salary_set, review_exempt,
    CASE WHEN deleted_at IS NULL THEN annual_leave_rate_per_month(id) END AS annual_leave_rate_days_per_month,
    CASE WHEN deleted_at IS NULL THEN annual_leave_rate_per_month(id) * 12 END AS annual_leave_rate_days,
    CASE WHEN deleted_at IS NULL THEN accrued_annual_leave(id) END AS annual_leave_accrued_days,
    CASE WHEN deleted_at IS NULL
         THEN (leave_balance_internal(id, 'annual'::text)->>'available')::numeric END AS annual_leave_available_days
   FROM employees
  WHERE has_permission('module.hr.view'::text) OR id = current_user_employee();

CREATE VIEW public.my_profile WITH (security_invoker = off) AS
 SELECT e.id AS employee_id, e.code, e.legal_name, e.preferred_name, e.job_title,
    e.employment_type, e.work_category, e.employment_status, e.hire_date, e.probation_end_date,
    annual_leave_rate_per_month(e.id) AS annual_leave_rate_days_per_month,
    annual_leave_rate_per_month(e.id) * 12 AS annual_leave_rate_days,
    accrued_annual_leave(e.id) AS annual_leave_accrued_days,
    (leave_balance_internal(e.id, 'annual'::text)->>'available')::numeric AS annual_leave_available_days,
    e.residency_status, e.work_pass_type, e.work_pass_no, e.work_pass_issue_date,
    e.work_pass_expiry_date, e.identity_no, e.work_email, e.work_phone,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    mgr.legal_name AS manager_name,
    mgr.code AS manager_code,
    COALESCE(tr.cnt, 0::bigint) AS training_count,
    pp.code AS latest_payroll_code,
    pp.period_month AS latest_payroll_month
   FROM employees e
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN employees mgr ON mgr.id = e.manager_id
     LEFT JOIN LATERAL ( SELECT count(*) AS cnt
           FROM training_records t
          WHERE t.employee_id = e.id AND t.deleted_at IS NULL) tr ON true
     LEFT JOIN LATERAL ( SELECT p.code,
            p.period_month
           FROM payroll_lines pl
             JOIN payroll_periods p ON p.id = pl.payroll_period_id
          WHERE pl.employee_id = e.id AND p.status = 'posted'::text AND p.deleted_at IS NULL
          ORDER BY p.period_month DESC
         LIMIT 1) pp ON true
  WHERE e.id = current_user_employee() AND e.deleted_at IS NULL;

CREATE VIEW public.employee_directory WITH (security_invoker = on) AS
 SELECT e.id AS employee_id, e.code, e.legal_name, e.preferred_name, e.department_id,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    e.job_title, e.manager_id,
    mgr.code AS manager_code,
    mgr.legal_name AS manager_name,
    e.employment_type, e.work_category, e.employment_status, e.hire_date, e.probation_end_date,
    e.annual_leave_rate_days,
    e.annual_leave_accrued_days,
    e.annual_leave_available_days,
    e.residency_status, e.work_pass_type, e.work_pass_expiry_date,
        CASE
            WHEN e.work_pass_expiry_date IS NULL THEN NULL::integer
            ELSE e.work_pass_expiry_date - CURRENT_DATE
        END AS days_to_work_pass_expiry,
        CASE
            WHEN e.work_pass_expiry_date IS NULL THEN NULL::text
            WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 90 THEN 'warning'::text
            ELSE NULL::text
        END AS work_pass_alert,
    pay.gross_pay AS current_gross_pay,
    pay.period_month AS current_pay_period,
    COALESCE(tr.training_count, 0::bigint) AS training_count
   FROM employees_masked e
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN employees_masked mgr ON mgr.id = e.manager_id
     LEFT JOIN LATERAL ( SELECT pl.gross_pay,
            pp.period_month
           FROM payroll_lines_masked pl
             JOIN payroll_periods pp ON pp.id = pl.payroll_period_id
          WHERE pl.employee_id = e.id AND pp.status = 'posted'::text AND pp.deleted_at IS NULL
          ORDER BY pp.period_month DESC
         LIMIT 1) pay ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS training_count
           FROM training_records t
          WHERE t.employee_id = e.id AND t.deleted_at IS NULL) tr ON true
  WHERE e.deleted_at IS NULL;

COMMIT;

