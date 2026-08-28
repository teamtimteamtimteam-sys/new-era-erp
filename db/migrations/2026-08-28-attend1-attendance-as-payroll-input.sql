-- ATTEND-1:考勤 —— 而它【喂】的不是一次计算,是一次交给外部服务商的申报
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §0 · 一条实测,它把这一刀的范围整个改掉了
-- ═══════════════════════════════════════════════════════════════════════════
-- 队列里那一条写着「考勤 —— 它喂工资」。而实测:**工资什么都不算。**
--   · `payroll_lines` 只有 gross_pay / employer_cpf / employee_cpf /
--     other_deductions / net_pay / notes;
--   · `upsert_payroll_period(..., p_lines jsonb)` 把这些数【原样收下】,
--     只校验结构(月份形状、付款日、币种、汇率、不重复员工、非空、未过账)。
--   · 而这是**刻意的、已经定案的**:会计政策 7.1 ——
--     「工资由外部服务商编制。系统记录并过账,它【不计算】薪酬或法定缴款。」
--
-- **所以"喂进一次计算"这件事没有对象。** 加班、无薪假、班次津贴、月中入离职 ——
-- 工资一样都不处理,也一样都没有"悄悄假设掉":它们全是服务商的算术。
--
-- 真正没有家的是另一侧:**我们每个月【告诉服务商】的那些数,今天不留任何痕迹。**
-- 于是没有人能重建"这张工资单为什么是这个数"。这一刀补的就是它。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §1 · 因此:建什么,以及【拒绝】建什么
-- ═══════════════════════════════════════════════════════════════════════════
-- **建**:一张【按月、按人】的工资申报底稿 —— 每月每人一行,记加班工时与一句备注,
--        其余全部【推导】,并在"标记完成"那一刻冻住。
-- **不建**(逐条给理由,因为不建也是一个决定):
--   · **每日打卡流水** —— 六个人全是 office / full_time 的受薪职员,实测
--     employment_type 与 work_category 各只有一个取值。给他们建一张每日流水,
--     正是「一份没人用的打卡记录比没有更坏」;而且"这个人今天在不在"会因此
--     有两个记录处(另一个是 leave_requests)。
--   · **排班 / 轮班表** —— 全库没有任何 shift/roster 结构,而加工那一族
--     实测也【没有开始/结束/班次/工时】(proc-reality.md:一次加工的唯一世界侧
--     日期是一个 date)。没有两班可排的时候排班表是一张空表。
--   · **设备打卡 / 手机端** —— 没有扫码枪、没有 App;条码与移动车间排在阶段 7。
--   · **加班【费】或倍率** —— 见 §3。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §2 · 请假与缺勤【不是一回事】,而这里靠"不重记"来保证
-- ═══════════════════════════════════════════════════════════════════════════
-- 请假模块是完整的:13 种假别(含 `unpaid`)、15 支函数、半天精度、
-- accrual / 结转 / 兑现 / 余额,`calculate_leave_days` 本身就懂工作日与公共假期。
-- **所以无薪假的天数【推导】自已批准的请假单,永远不在这里重打一遍。**
-- 重打一遍就会有两个答案,而它们会在"请假单事后被取消"那一刻分家。
-- 月中入离职同理:`employees.hire_date` 与 `separation_date` 已经在了。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §3 · 加班按【何时发生】记,不记倍率 —— 因为那是一个开着的法律问题
-- ═══════════════════════════════════════════════════════════════════════════
-- 工时落在平日、休息日还是公共假期,是一个**我们说得出的事实**;
-- 它乘以多少,是《雇佣法令》下的问题,而**本仓库里读得到的任何文档都没有
-- 记过这件事**(逐个搜过 docs/*.md;三份 PDF 在这台机器上读不了 —— 没装 poppler)。
-- 加上实测**在册的六个人全是 office/full_time**,一个"受涵盖的车间工人"都还没有。
-- 所以:**记事实,不答法律**。倍率与加班费归服务商;真要由系统说,那是另一刀,
-- 而它等的是一句裁定,不是工时。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §4 · 「没记」与「记了是零」必须长得不一样
-- ═══════════════════════════════════════════════════════════════════════════
-- 三列工时 NOT NULL DEFAULT 0,而【是否记过】由单独一列 `recorded_at` 说 ——
-- NULL = 没有人记过这一行,非空 = 有人记过(哪怕三个数都是 0)。
-- 把"没人看过"折叠成 0,正是本刀最要防的那件事:它会让一次工资过账
-- 悄悄把"缺勤未知"当成"全勤"。

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1 · attendance_periods —— 一个月一行
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE public.attendance_periods (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code           text NOT NULL UNIQUE,          -- ATT-YYYY-MM
    period_month   date NOT NULL UNIQUE,          -- 当月 1 号
    status         text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'complete')),
    opened_at      timestamptz NOT NULL DEFAULT now(),
    opened_by      uuid,
    completed_at   timestamptz,
    completed_by   uuid,
    reopened_at    timestamptz,
    reopened_by    uuid,
    reopen_reason  text,
    CONSTRAINT attendance_periods_month_shape
        CHECK (period_month = date_trunc('month', period_month)::date),
    CONSTRAINT attendance_periods_complete_shape
        CHECK ((status = 'complete') = (completed_at IS NOT NULL)),
    CONSTRAINT attendance_periods_reopen_shape
        CHECK ((reopened_at IS NULL) = (reopened_by IS NULL)),
    -- 重开必须给理由 —— 一次没有理由的重开,下一个人无从判断该不该信这份底稿
    CONSTRAINT attendance_periods_reopen_reason
        CHECK (reopened_at IS NULL OR btrim(COALESCE(reopen_reason, '')) <> '')
);

COMMENT ON TABLE public.attendance_periods IS
    'ATTEND-1:一个月一行的【工资申报底稿】期间。★【它喂的不是一次计算】★ —— 实测工资什么都不算(会计政策 7.1:由外部服务商编制,系统只记录与过账;upsert_payroll_period 把 gross/CPF/net 原样收下)。所以加班、无薪假、月中入离职都不是"喂进算式",它们是【我们每月告诉服务商的那些数】,而那些数今天不留任何痕迹 —— 没人能重建一张工资单为什么是这个数。【为什么"完成"是一次人的断言】系统无法知道考勤是否齐全,只能知道有没有人说过它齐全;与 finance_settings.system_start_date 是【声明】而不是【推断】同一条。而工资过账正是靠这句断言才敢拒绝。【重开的边界】那个月的工资一旦过账,这份底稿就不许再动 —— 一张已过账工资单的依据不能在它脚下改变;要改先 unpost(那支函数自己有 CPF/扣款已汇出的守卫)。';

CREATE INDEX idx_attendance_periods_month ON public.attendance_periods (period_month DESC);

ALTER TABLE public.attendance_periods ENABLE ROW LEVEL SECURITY;

CREATE POLICY "attendance_periods select by permission" ON public.attendance_periods
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));

-- ───────────────────────────────────────────────────────────────────────────
-- 2 · attendance_lines —— 每月每人一行
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE public.attendance_lines (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    period_id              uuid NOT NULL REFERENCES public.attendance_periods (id) ON DELETE CASCADE,
    employee_id            uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    -- ★【加班按【何时发生】分三列,而【没有】倍率那一列】★ 见抬头 §3:
    -- 何时发生是事实,乘以多少是《雇佣法令》下一个还开着的问题。
    ot_normal_hours        numeric NOT NULL DEFAULT 0 CHECK (ot_normal_hours >= 0),
    ot_rest_day_hours      numeric NOT NULL DEFAULT 0 CHECK (ot_rest_day_hours >= 0),
    ot_public_holiday_hours numeric NOT NULL DEFAULT 0 CHECK (ot_public_holiday_hours >= 0),
    note                   text,
    -- ★【「没记」与「记了是零」的分界就在这一列】★
    recorded_at            timestamptz,
    recorded_by            uuid,
    -- ══ 完成那一刻冻下来的【推导值】════════════════════════════════════════
    -- 冻它们,是为了「我们当时报给服务商的是什么」在请假单事后被取消之后
    -- 仍然读得出来。
    unpaid_days            numeric,
    active_from            date,
    active_to              date,
    frozen_at              timestamptz,
    UNIQUE (period_id, employee_id),
    CONSTRAINT attendance_lines_recorded_shape
        CHECK ((recorded_at IS NULL) = (recorded_by IS NULL))
);

COMMENT ON TABLE public.attendance_lines IS
    'ATTEND-1:每月每人一行的工资申报底稿。★【唯一【打字】进来的只有加班工时与一句备注】★ —— 无薪假天数【推导】自已批准的请假单(请假是一个完整的 15 支函数模块,含 unpaid 假别与半天精度,calculate_leave_days 本身就懂工作日与公共假期),月中入离职推导自 employees.hire_date / separation_date。重打一遍就会有两个答案,而它们会在请假单事后被取消那一刻分家。★【「没记」不是「零」】★ 三列工时 NOT NULL DEFAULT 0,而【有没有人记过】由 recorded_at 单独说:NULL = 没人记过,非空 = 记过(哪怕三个数都是 0)。把前者折叠成后者,就是让一次工资过账把「缺勤未知」当成「全勤」—— 这一刀最要防的正是这件事。【加班没有倍率列】何时发生是事实,乘以多少是《雇佣法令》下开着的问题,而本仓库读得到的文档里没有任何关于它的记录,在册六人也全是 office/full_time。';

CREATE INDEX idx_attendance_lines_period ON public.attendance_lines (period_id);
CREATE INDEX idx_attendance_lines_employee ON public.attendance_lines (employee_id);
CREATE INDEX idx_attendance_lines_unrecorded ON public.attendance_lines (period_id)
    WHERE recorded_at IS NULL;

ALTER TABLE public.attendance_lines ENABLE ROW LEVEL SECURITY;

-- 【读:HR 看得见全部,员工看得见自己那一行】—— 与 my_profile / 报销同一条思路。
-- 员工看得见【关于他自己被报了什么】,正是让错误被抓住的那一半。
CREATE POLICY "attendance_lines select by permission" ON public.attendance_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text)
        OR employee_id = current_user_employee());

-- ───────────────────────────────────────────────────────────────────────────
-- 3 · 推导:某个月里【已批准的无薪假】天数
-- ───────────────────────────────────────────────────────────────────────────
-- 【它不自己数日子】天数一律走 calculate_leave_days —— 那一支已经懂工作日与
-- 公共假期,而在这里再数一遍就是它的第二份实现(本仓库为这个形状付过四次账)。
-- 【半天只在【真正的那一端】才算】一张跨月的请假单被裁到本月时,
-- 裁出来的那一端不是原来的端点,所以那一端的半天标记【不适用】。
CREATE OR REPLACE FUNCTION public.attendance_unpaid_days(
    p_employee_id uuid,
    p_month       date
)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(round(sum(
        calculate_leave_days(
            GREATEST(lr.start_date, date_trunc('month', p_month)::date),
            LEAST(lr.end_date, (date_trunc('month', p_month) + interval '1 month - 1 day')::date),
            -- 只有裁剪之后仍然是原端点时,半天标记才成立
            lr.start_half_day AND lr.start_date >= date_trunc('month', p_month)::date,
            lr.end_half_day   AND lr.end_date   <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
        )), 2), 0)
      FROM leave_requests lr
     WHERE lr.employee_id = p_employee_id
       AND lr.leave_type_code = 'unpaid'
       AND lr.status = 'approved'
       AND lr.deleted_at IS NULL
       AND lr.start_date <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
       AND lr.end_date   >= date_trunc('month', p_month)::date;
$function$;

COMMENT ON FUNCTION public.attendance_unpaid_days(uuid, date) IS
    'ATTEND-1:某人在某个月里【已批准的无薪假】天数 —— 推导,不重记。天数一律走 calculate_leave_days(它已经懂工作日与公共假期);在这里再数一遍日子就是它的第二份实现。跨月的请假单按月裁剪,而【半天标记只在裁剪之后仍是原端点时才成立】—— 裁出来的那一端不是任何人请过的半天。';

-- ───────────────────────────────────────────────────────────────────────────
-- 4 · open_attendance_period —— 开一个月,并把【每一个在册的人】铺出来
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.open_attendance_period(p_period_month date)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_m date; v_id uuid; v_code text; v_n int;
BEGIN
    PERFORM require_permission('module.hr.edit');
    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'ATTENDANCE_MONTH_REQUIRED';
    END IF;
    v_m := date_trunc('month', p_period_month)::date;
    -- 【还没过完的月份不开】一个月的考勤在它结束之前不可能是完整的,
    -- 而这张底稿存在的意义就是"完整"这句断言。
    IF v_m > date_trunc('month', CURRENT_DATE)::date THEN
        RAISE EXCEPTION 'ATTENDANCE_MONTH_FUTURE|%|%', v_m::text, CURRENT_DATE::text;
    END IF;
    IF EXISTS (SELECT 1 FROM attendance_periods WHERE period_month = v_m) THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_EXISTS|%',
            (SELECT code FROM attendance_periods WHERE period_month = v_m);
    END IF;

    v_code := 'ATT-' || to_char(v_m, 'YYYY-MM');
    INSERT INTO attendance_periods (code, period_month, opened_by)
    VALUES (v_code, v_m, auth.uid()) RETURNING id INTO v_id;

    -- 【每一个在这个月里在册过的人都铺一行】—— 见抬头 §4:
    -- 只给"有加班的人"建行,会让"没建行"同时意味着"没有加班"和"忘了",
    -- 而那正是这一刀要拆开的两件事。
    INSERT INTO attendance_lines (period_id, employee_id)
    SELECT v_id, e.id FROM employees e
     WHERE e.deleted_at IS NULL
       AND e.hire_date <= (v_m + interval '1 month - 1 day')::date
       AND (e.separation_date IS NULL OR e.separation_date >= v_m);
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RETURN jsonb_build_object('period_id', v_id, 'code', v_code,
                              'period_month', v_m, 'lines', v_n);
END;
$function$;

COMMENT ON FUNCTION public.open_attendance_period(date) IS
    'ATTEND-1:开一个月的工资申报底稿,并把【每一个在这个月里在册过的人】铺成一行。【为什么铺全量而不是只铺有加班的人】只给有加班的人建行,"没建行"就同时意味着"没有加班"和"忘了这个人"—— 而拆开这两件事正是这一刀的要点(NULL 的 recorded_at = 没人记过,记过之后三个 0 = 记了、是零)。【未来的月份不开】一个月在它结束之前不可能完整,而这张底稿的意义就是"完整"这句断言。';

-- ───────────────────────────────────────────────────────────────────────────
-- 5 · record_attendance —— 记一行(而"记了是零"是一句真话)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_attendance(
    p_line_id   uuid,
    p_normal    numeric DEFAULT 0,
    p_rest_day  numeric DEFAULT 0,
    p_holiday   numeric DEFAULT 0,
    p_note      text DEFAULT NULL
)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_l attendance_lines%ROWTYPE; v_p attendance_periods%ROWTYPE;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_l FROM attendance_lines WHERE id = p_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_LINE_NOT_FOUND|%', COALESCE(p_line_id::text, '?');
    END IF;
    SELECT * INTO v_p FROM attendance_periods WHERE id = v_l.period_id;
    IF v_p.status <> 'open' THEN
        -- 完成之后不许再改:那份底稿【就是】我们报出去的东西
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_OPEN|%|%', v_p.code, v_p.status;
    END IF;
    IF COALESCE(p_normal,0) < 0 OR COALESCE(p_rest_day,0) < 0 OR COALESCE(p_holiday,0) < 0 THEN
        RAISE EXCEPTION 'ATTENDANCE_HOURS_INVALID|%|%|%',
            COALESCE(p_normal,0)::text, COALESCE(p_rest_day,0)::text, COALESCE(p_holiday,0)::text;
    END IF;

    UPDATE attendance_lines
       SET ot_normal_hours = COALESCE(p_normal, 0),
           ot_rest_day_hours = COALESCE(p_rest_day, 0),
           ot_public_holiday_hours = COALESCE(p_holiday, 0),
           note = NULLIF(btrim(COALESCE(p_note, '')), ''),
           recorded_at = now(), recorded_by = auth.uid()
     WHERE id = p_line_id;

    RETURN jsonb_build_object('line_id', p_line_id, 'recorded', true);
END;
$function$;

COMMENT ON FUNCTION public.record_attendance(uuid, numeric, numeric, numeric, text) IS
    'ATTEND-1:记一行考勤。★【三个 0 也是一次记录】★ —— 它盖上 recorded_at,而那正是"记了、是零"与"没人看过"的分界;后者会让工资过账把缺勤未知当成全勤。完成之后的期间不许再改(ATTENDANCE_PERIOD_NOT_OPEN):那份底稿【就是】我们报给服务商的东西。';

-- ───────────────────────────────────────────────────────────────────────────
-- 5b · sync_attendance_period —— 把期间开出去之后才入职的人补进名单
-- ───────────────────────────────────────────────────────────────────────────
-- ★【为什么这一步必须能【单独】调用,而不能只活在 complete 里】★
-- complete 里那句补名单是【安全网】:它保证"完成"这句断言不可能漏人。
-- 但补完之后如果还有没记的行,complete 会 RAISE —— 而 PostgreSQL 会把
-- 【同一条语句里】刚补出来的行一起回滚掉。于是那一行永远落不了地:
-- 屏幕上看不到它,操作员却被告知"还差 1 行"。一条无法被满足的拒绝
-- 不是守卫,是死锁。
-- 所以补名单还要有一条【自己提交的】路:页面每次打开时调它一次,
-- 新人就出现在名单里,可以被记录。安全网留在 complete 里不动 ——
-- 没人调过 sync 也漏不了人。
CREATE OR REPLACE FUNCTION public.sync_attendance_period(p_period_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_p attendance_periods%ROWTYPE; v_added int; v_end date;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM attendance_periods WHERE id = p_period_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_FOUND|%', COALESCE(p_period_id::text, '?');
    END IF;
    IF v_p.status <> 'open' THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_OPEN|%|%', v_p.code, v_p.status;
    END IF;
    v_end := (v_p.period_month + interval '1 month - 1 day')::date;

    INSERT INTO attendance_lines (period_id, employee_id)
    SELECT v_p.id, e.id FROM employees e
     WHERE e.deleted_at IS NULL
       AND e.hire_date <= v_end
       AND (e.separation_date IS NULL OR e.separation_date >= v_p.period_month)
       AND NOT EXISTS (SELECT 1 FROM attendance_lines al
                        WHERE al.period_id = v_p.id AND al.employee_id = e.id);
    GET DIAGNOSTICS v_added = ROW_COUNT;

    RETURN jsonb_build_object('period_id', p_period_id, 'code', v_p.code, 'lines_added', v_added);
END;
$function$;

COMMENT ON FUNCTION public.sync_attendance_period(uuid) IS
    'ATTEND-1:把期间开出去之后才入职的人补进名单 —— ★【为什么它必须能单独调用】★ complete_attendance_period 里也有同一句补名单,那是【安全网】(没人调过 sync 也漏不了人);但补完若仍有没记的行,complete 会 RAISE,而 PostgreSQL 会把同一条语句里刚补出来的行一起回滚掉 —— 那一行永远落不了地,屏幕上看不见,操作员却被告知"还差 1 行"。一条无法被满足的拒绝不是守卫,是死锁。页面每次打开调它一次,新人就出现在名单里,可以被记录。';

-- ───────────────────────────────────────────────────────────────────────────
-- 6 · complete_attendance_period —— 补齐名单 → 拒空 → 冻推导值
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.complete_attendance_period(p_period_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_p attendance_periods%ROWTYPE; v_added int; v_missing int; v_end date;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM attendance_periods WHERE id = p_period_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_FOUND|%', COALESCE(p_period_id::text, '?');
    END IF;
    IF v_p.status <> 'open' THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_OPEN|%|%', v_p.code, v_p.status;
    END IF;
    v_end := (v_p.period_month + interval '1 month - 1 day')::date;

    -- ① 【先补名单,再谈完整 —— 这是安全网,不是操作路径】月中入职的人在
    --    开期间时还不在册;不补就会出现"一份声称完整的底稿里少了一个人",
    --    而那句断言恰恰在这种时候才要紧。
    --    【但它到不了操作员手上】补完若仍有没记的行,下面那句 RAISE 会把
    --    同一条语句里刚补出来的行一起回滚掉 —— 所以能被【看见和记录】的
    --    那条路是 sync_attendance_period(页面每次打开调一次)。两者同一句
    --    SQL,故意重复:少了这里就漏得掉人,少了那里就补不进去。
    INSERT INTO attendance_lines (period_id, employee_id)
    SELECT v_p.id, e.id FROM employees e
     WHERE e.deleted_at IS NULL
       AND e.hire_date <= v_end
       AND (e.separation_date IS NULL OR e.separation_date >= v_p.period_month)
       AND NOT EXISTS (SELECT 1 FROM attendance_lines al
                        WHERE al.period_id = v_p.id AND al.employee_id = e.id);
    GET DIAGNOSTICS v_added = ROW_COUNT;

    -- ② 【还有没记的就拒,并说出还差几行】一个容得下空白的"完成"是一个勾选框,
    --    不是一句断言 —— 而工资过账那道拒绝【整个】压在这句断言上。
    SELECT count(*) INTO v_missing FROM attendance_lines
     WHERE period_id = v_p.id AND recorded_at IS NULL;
    IF v_missing > 0 THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_INCOMPLETE|%|%', v_p.code, v_missing::text;
    END IF;

    -- ③ 【冻推导值】此后请假单再被取消,这份底稿仍然说得出当时报了什么
    UPDATE attendance_lines al
       SET unpaid_days = attendance_unpaid_days(al.employee_id, v_p.period_month),
           active_from = GREATEST(e.hire_date, v_p.period_month),
           active_to   = LEAST(COALESCE(e.separation_date, v_end), v_end),
           frozen_at   = now()
      FROM employees e
     WHERE e.id = al.employee_id AND al.period_id = v_p.id;

    UPDATE attendance_periods
       SET status = 'complete', completed_at = now(), completed_by = auth.uid()
     WHERE id = p_period_id;

    RETURN jsonb_build_object('period_id', p_period_id, 'code', v_p.code,
                              'status', 'complete', 'lines_added', v_added);
END;
$function$;

COMMENT ON FUNCTION public.complete_attendance_period(uuid) IS
    'ATTEND-1:把一个月的底稿标记完成 —— 三步,顺序要紧。① 先【补名单】(月中入职的人在开期间时还不在册;不补就会有一份"声称完整"却少了人的底稿)—— 这里的补名单是【安全网】,能被看见和记录的那条路是 sync_attendance_period,因为补完若仍有空行,下面那句 RAISE 会把同一条语句里刚补出来的行一起回滚掉;两处故意重复,少了这里漏得掉人,少了那里补不进去;② 还有没记的就【按名拒并说出差几行】—— 一个容得下空白的"完成"是勾选框不是断言,而工资过账那道拒绝整个压在这句断言上;③ 【冻推导值】(无薪假天数、月中在册起止),此后请假单再被取消,这份底稿仍然说得出我们当时报了什么。';

-- ───────────────────────────────────────────────────────────────────────────
-- 7 · reopen_attendance_period —— 而已过账的那个月不许重开
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reopen_attendance_period(
    p_period_id uuid, p_reason text
)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_p attendance_periods%ROWTYPE; v_pay text;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM attendance_periods WHERE id = p_period_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_FOUND|%', COALESCE(p_period_id::text, '?');
    END IF;
    IF v_p.status <> 'complete' THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_COMPLETE|%|%', v_p.code, v_p.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'ATTENDANCE_REOPEN_REASON_REQUIRED|%', v_p.code;
    END IF;

    -- ★【那个月的工资已经过账,就不许再动它的依据】★
    -- 一张已过账工资单的依据不能在它脚下改变。改法是先 unpost ——
    -- 而 unpost_payroll_period 自己带着守卫(CPF/扣款已汇出就拒),
    -- 所以这条顺序是可执行的,不是一句劝告。
    SELECT code INTO v_pay FROM payroll_periods
     WHERE deleted_at IS NULL AND status = 'posted'
       AND date_trunc('month', period_month)::date = v_p.period_month LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL|%|%', v_p.code, v_pay;
    END IF;

    UPDATE attendance_periods
       SET status = 'open', completed_at = NULL, completed_by = NULL,
           reopened_at = now(), reopened_by = auth.uid(), reopen_reason = btrim(p_reason)
     WHERE id = p_period_id;

    RETURN jsonb_build_object('period_id', p_period_id, 'code', v_p.code, 'status', 'open');
END;
$function$;

COMMENT ON FUNCTION public.reopen_attendance_period(uuid, text) IS
    'ATTEND-1:重开一个已完成的月份 —— 必须给理由,而【那个月的工资一旦过账就拒】。一张已过账工资单的依据不能在它脚下改变;改法是先 unpost_payroll_period(它自己带着"CPF/扣款已汇出就拒"的守卫),所以这条顺序是可执行的,不是一句劝告。';

-- ───────────────────────────────────────────────────────────────────────────
-- 8 · post_payroll_period —— 加一道拒绝:那个月的底稿必须有人说过它齐全
-- ───────────────────────────────────────────────────────────────────────────
-- 【整支重放,只多了一段】签名一个字没动(uuid → jsonb),所以这是
-- CREATE OR REPLACE 而不是重载 —— preflight 拒的是签名不同的那一种。
-- 其余部分逐字取自线上定义。

CREATE OR REPLACE FUNCTION public.post_payroll_period(p_payroll_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_p     record;
    v_bank  text;
    v_lines jsonb := '[]'::jsonb;
    v_je    jsonb;
    v_cpf   numeric;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM payroll_periods
    WHERE id = p_payroll_period_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;
    IF v_p.status = 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_ALREADY_POSTED|%', v_p.code;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM payroll_lines WHERE payroll_period_id = p_payroll_period_id) THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- ══ ATTEND-1:★【过账要有依据,而依据是一句【人的断言】】★ ═════════════
    -- 【为什么拒在这里,而不是 upsert】记录服务商送回来的数字只是【捕获一个
    -- 已经发生的事实】,拦住它只会把那些数字推到系统外面去保管。
    -- 过账才是公司认下这些数字的那一刻,依据必须在这一刻存在。
    -- 【它并不检查"考勤对不对"】系统无从知道;它检查的是【有没有人说过
    -- 这个月的底稿齐全了】—— 与 finance_settings.system_start_date 是
    -- 【声明】而不是【推断】同一条。
    -- 【为什么必须是拒绝,而不是警告】一次静静地把"缺勤未知"当成"全勤"的
    -- 工资过账,是这里所有选项里最坏的一个;而一句没有牙齿的警告,
    -- 在一个月一次的收尾动作上会被直接点过去 —— 这个仓库为"学会忽略警报"
    -- 付过账。
    IF NOT EXISTS (
        SELECT 1 FROM attendance_periods ap
         WHERE ap.status = 'complete'
           AND ap.period_month = date_trunc('month', v_p.period_month)::date
    ) THEN
        RAISE EXCEPTION 'PAYROLL_ATTENDANCE_NOT_COMPLETE|%|%',
            v_p.code, to_char(v_p.period_month, 'YYYY-MM');
    END IF;

    -- FIN-4:过账【不碰银行】—— 钱还没出去。净额挂 2300 应付净薪,
    -- 逐人付款(pay_payroll_lines)时才贷银行,一人一条,各自对账。
    -- OPS-8:"支持哪些币种"就是 currencies 表本身,不是这里另抄一份码表
    IF NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = v_p.currency) THEN
        RAISE EXCEPTION 'PAYROLL_CURRENCY_UNSUPPORTED|%', v_p.currency;
    END IF;

    -- 借 6100 工资薪金(服务商口径的 gross)
    IF v_p.gross_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '6100', 'side', 'debit', 'currency', v_p.currency,
            'amount_ccy', v_p.gross_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 借 6110 公积金-雇主部分(公司成本,不从员工工资里出)
    IF v_p.employer_cpf_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '6110', 'side', 'debit', 'currency', v_p.currency,
            'amount_ccy', v_p.employer_cpf_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2400 公积金应付:雇主 + 员工两侧合计,汇给公积金局之前都欠着
    v_cpf := round(COALESCE(v_p.employer_cpf_total, 0) + COALESCE(v_p.employee_cpf_total, 0), 2);
    IF v_cpf > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2400', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_cpf, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2200 应计费用:服务商【代公司扣下】的其它款项,在汇出去之前挂在这里。
    -- 【注意区分】如果某项扣款本质上是"公司成本变少"(而不是替员工代扣代缴),
    -- 那它就不该出现在这里 —— 应该让服务商把它并进 gross 里去。
    IF v_p.other_deductions_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2200', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_p.other_deductions_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2300 应付净薪:实发净额,付给每个人之前都欠着
    IF v_p.net_pay_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2300', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_p.net_pay_total, 'fx_rate', v_p.fx_rate);
    END IF;

    -- 期间锁在 post_journal_entry 内生效(PERIOD_LOCKED 原样上抛)
    v_je := post_journal_entry(
        v_p.payment_date,
        'Payroll ' || v_p.code,
        'payroll',
        v_p.id,
        v_lines
    );

    UPDATE payroll_periods
    SET status = 'posted', journal_entry_id = (v_je->>'entry_id')::uuid, updated_by = v_user
    WHERE id = p_payroll_period_id;

    RETURN jsonb_build_object(
        'payroll_period_id', p_payroll_period_id,
        'code', v_p.code,
        'journal_code', v_je->>'code',
        'gross_total', v_p.gross_total,
        'employer_cpf_total', v_p.employer_cpf_total,
        'employee_cpf_total', v_p.employee_cpf_total,
        'net_pay_total', v_p.net_pay_total
    );
END;
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- 9 · attendance_period_status —— 屏幕读的那一份
-- ───────────────────────────────────────────────────────────────────────────
-- 属主权限(OPS-14 修法 (a)):它横跨 hr 与 finance(要说出那个月的工资过账了
-- 没有),invoker 会让读者无权的那一侧【静默丢掉行】,而行消失在这里意味着
-- "这个月没有工资" —— 一句会被信的假话。
CREATE OR REPLACE VIEW public.attendance_period_status
WITH (security_invoker = off) AS
SELECT ap.id                AS period_id,
       ap.code,
       ap.period_month,
       ap.status,
       ap.opened_at, ap.completed_at, ap.reopened_at, ap.reopen_reason,
       count(al.id)::int                                            AS line_count,
       count(al.id) FILTER (WHERE al.recorded_at IS NULL)::int       AS unrecorded_count,
       round(COALESCE(sum(al.ot_normal_hours), 0), 2)                AS ot_normal_hours,
       round(COALESCE(sum(al.ot_rest_day_hours), 0), 2)              AS ot_rest_day_hours,
       round(COALESCE(sum(al.ot_public_holiday_hours), 0), 2)        AS ot_public_holiday_hours,
       -- 【已完成的读【冻下来的】,还开着的读【此刻的】】两者是不同的问题:
       -- 前者是"我们当时报了什么",后者是"现在看是多少"。
       round(COALESCE(sum(CASE WHEN ap.status = 'complete' THEN al.unpaid_days
                               ELSE attendance_unpaid_days(al.employee_id, ap.period_month) END), 0), 2)
                                                                     AS unpaid_days,
       -- 那个月的工资过账了没有 —— 重开那道拒绝就压在它上面
       EXISTS (SELECT 1 FROM payroll_periods pp
                WHERE pp.deleted_at IS NULL AND pp.status = 'posted'
                  AND date_trunc('month', pp.period_month)::date = ap.period_month) AS payroll_posted
  FROM attendance_periods ap
  LEFT JOIN attendance_lines al ON al.period_id = ap.id
 GROUP BY ap.id;

COMMENT ON VIEW public.attendance_period_status IS
    'ATTEND-1:每个考勤月一行 —— 铺了几行、还有几行没人记、三类加班工时合计、无薪假天数,以及那个月的工资过账了没有。★【已完成的读冻下来的,还开着的读此刻的】★ 两者是不同的问题:前者是"我们当时报给服务商的是什么",后者是"现在看是多少"。属主权限(security_invoker = off):它横跨 hr 与 finance,invoker 会让读者无权的那一侧静默丢掉行,而行消失在这里意味着"这个月没有工资"—— 一句会被信的假话(OPS-14 修法 (a));调用方按 module.hr.view 把关。';

COMMIT;
