-- WO-1a:工单(生产计划)的单据层 —— 计划与实绩之间的那道缝,先立计划这一侧
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这一刀在回答什么】
-- Doc 3 的 Phase 1 写着"production plan / work order(what to process, how much,
-- when),with an actual-execution record against plan"。系统今天只有 actual:
-- 一张加工单一出生就是 committed(status CHECK 只有 committed/reversed),
-- 它记录【发生过什么】,而没有任何地方记录【本来打算做什么】。
--
-- 这一刀只立计划这一侧的单据:工单、计划投料行、预期产出行、变更留痕,
-- 外加 processing_runs 上一列【纯新增】的 work_order_id。
-- 【不动 commit_processing_run 的签名】—— 加工单与工单的接缝、差异视图、
-- 审批主体都在 WO-1b,界面在 WO-1c。
--
-- ── 三个决定,写在这里而不是留给下一个人从代码里猜 ────────────────────────
--
-- 【一 · "在做中"与"完成度"是【推导】出来的,不是存下来的状态】
-- status 只有 draft / released / closed / cancelled 四态,它们全都是【有人做了
-- 一个动作】的结果。而"这张工单开工了没有""做了几成"是从挂上来的加工单算出来的
-- 事实 —— 存一份就等于给同一件事留了第二处实现,而那两处会漂开(AGENTS.md
-- 那条"一处推导,N 个消费者";sales_order_fulfilment_status 是同一条的先例)。
-- 具体地说:一张 released 的工单,只要有一条挂上来的加工单,它就"在做中" ——
-- 没有任何人需要去点一个按钮把它翻成 in_progress,也就没有人会忘记点。
--
-- 【二 · scheduled_date 可以为空,而且【永不默认】】
-- 它与 process_date / issue_date 那一族【不是同一种日期】:那些决定汇率、决定
-- 期间,补一个今天进去会让"留空"比"填对"更容易通过(FIN-10)。这一个决定不了
-- 任何钱,它是一句【对外部世界的意向】—— 而一份计划完全可能诚实地"还不知道
-- 什么时候做"。所以它可空。但同样【绝不给默认值】:一个补出来的排产日期会让
-- "谁也没排过期"看起来像"排在今天",而那是凭空造出来的一句承诺。
-- 空就是空,它的意思是"没排"。
--
-- 【三 · 计划【不扣货】—— 这是一处刻意的缺席】
-- 「为一张计划中的工单扣住料」今天表达不出来:on_hold 只有一个自由文本的理由,
-- 没有归属列;committed 那个桶在结构上属于销售(sales_order_reservations
-- .sales_order_line_id 是 NOT NULL)。三条路(什么都不扣 / 给 on_hold 加归属 /
-- 第四个桶)各有代价,而【今天没有任何证据说哪一条对】:线上 on_hold 至今只有
-- 一对流水、净额为零。所以这一刀什么都不扣,并把这句话记进
-- docs/as-built-divergences.md —— 等有了"计划中的料被别人吃掉"的实例再回来。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 取号 ══════════════════════════════════════════════════════════════
-- 【走顾问锁那个房子形状,不走 PROC- 的序列】next_sales_order_code /
-- next_quote_code / next_credit_note_code 三份逐字同形,这是第四份。
-- 加工单的 PROC- 用的是 SEQUENCE(建库初期留下的例外,非无缝、不按年分段)——
-- 【这一刀不去动它】:改一个在用的取号器要迁移既有编号,与本刀无关。
CREATE OR REPLACE FUNCTION public.next_work_order_code(p_date date DEFAULT CURRENT_DATE)
RETURNS text
LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】WO 与 SO / QT / CN 各自连号 —— 共用一把会让一种单据
    -- 烧掉另一种的号,而无缝的意思正是"号码之间没有洞"。
    PERFORM pg_advisory_xact_lock(hashtext('work_order_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM work_orders
    WHERE code LIKE 'WO-' || v_year::text || '-%';
    RETURN 'WO-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ═══ 2 · 工单表头 ═══════════════════════════════════════════════════════════
CREATE TABLE public.work_orders (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code           text NOT NULL UNIQUE,
    -- 【四态,而且每一态都是"有人做了一个动作"】见文件头决定一:
    -- 在做中 / 完成度不在这里,它们从挂上来的加工单推导。
    status         text NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft','released','closed','cancelled')),
    -- 排产日:【可空,且永不默认】—— 见文件头决定二。
    scheduled_date date,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid,
    -- 关闭三件套:未关闭之前全为 NULL,由 close_work_order 一次写齐。
    closed_at      timestamptz,
    closed_by      uuid,
    close_reason   text,
    -- 取消两件套(理由必填,与关闭同一条理由)
    cancelled_at   timestamptz,
    cancelled_by   uuid,
    cancel_reason  text,
    -- 【状态与它的证据必须同时成立】—— 一个 closed 却没有理由的行,读起来像
    -- "关了但没人说为什么",而真相多半是某条路径忘了写。用 CHECK 而不是靠
    -- 函数自觉:函数是唯一写入口【今天】成立,而约束对任何写入者都成立。
    CONSTRAINT work_orders_closed_consistent CHECK (
        (status = 'closed') = (closed_at IS NOT NULL)
        AND (closed_at IS NULL OR btrim(COALESCE(close_reason,'')) <> '')
    ),
    CONSTRAINT work_orders_cancelled_consistent CHECK (
        (status = 'cancelled') = (cancelled_at IS NOT NULL)
        AND (cancelled_at IS NULL OR btrim(COALESCE(cancel_reason,'')) <> '')
    )
);

COMMENT ON TABLE public.work_orders IS
    'WO-1a:工单 = 一份【打算加工什么、多少、什么时候】的计划。实绩在 processing_runs 那一侧,两者由 processing_runs.work_order_id 相连(该列 WO-1a 建出、WO-1b 才由 commit_processing_run 写入)。';
COMMENT ON COLUMN public.work_orders.status IS
    '四态,每一态都是一个【动作】的结果:draft(新建即此态)→ released(放行,可以开工)→ closed(收工,理由必填,短交合法);draft/released 均可 cancelled(理由必填)。【"在做中"与"完成度"不在这里】—— 它们由挂上来的加工单推导(一处推导,N 个消费者),存下来只会与真相漂开,而且要求有人记得去点一个按钮。';
COMMENT ON COLUMN public.work_orders.scheduled_date IS
    '打算什么时候做。【可空,且永不给默认值】—— 它与 process_date / issue_date 不是同一种日期:那些决定汇率与期间,补一个今天会让"留空"比"填对"更容易通过(FIN-10);这一个决定不了任何钱,而一份计划可以诚实地还不知道什么时候做。空的意思就是"没排" —— 补一个今天会把"谁也没排过期"伪装成"排在今天"。';
COMMENT ON COLUMN public.work_orders.close_reason IS
    '收工理由,【必填】。短交(实际做的比计划少)是合法的、要记下来的事实,不是要拦住的错误 —— 拦住它只会让人把计划改小以求关单,而那会把差异从账上抹掉。';

-- ═══ 3 · 计划投料行 ═════════════════════════════════════════════════════════
CREATE TABLE public.work_order_lines (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    work_order_id uuid NOT NULL REFERENCES public.work_orders (id) ON DELETE RESTRICT,
    material_id   uuid NOT NULL REFERENCES public.materials (id),
    planned_qty   numeric NOT NULL CHECK (planned_qty > 0),
    created_at    timestamptz NOT NULL DEFAULT now(),
    -- 【一种物料一行 —— 这是那条写下来的映射规则】计划按【物料】写(计划的时候
    -- 那批货可能还没到,更没人挑过批次;挑批次是车间当天的事)。而实绩按【批次】
    -- 记。两者相比时,"计划 5 吨黑粉,实际吃了 A 批 3 吨、B 批 2.5 吨"要有唯一
    -- 读法 —— 允许同一物料两行,差异就再也说不清是哪一行超了。
    CONSTRAINT work_order_lines_one_per_material UNIQUE (work_order_id, material_id)
);

COMMENT ON TABLE public.work_order_lines IS
    'WO-1a:计划投料。【按物料,不按批次】—— 排计划的时候批次往往还不存在;挑批次是开工当天的决定。与实绩相比时的唯一读法由 (work_order_id, material_id) 的唯一约束保证。';

-- ═══ 4 · 预期产出(可选) ═══════════════════════════════════════════════════
CREATE TABLE public.work_order_expected_outputs (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    work_order_id uuid NOT NULL REFERENCES public.work_orders (id) ON DELETE RESTRICT,
    material_id   uuid NOT NULL REFERENCES public.materials (id),
    expected_qty  numeric NOT NULL CHECK (expected_qty > 0),
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT work_order_expected_one_per_material UNIQUE (work_order_id, material_id)
);

COMMENT ON TABLE public.work_order_expected_outputs IS
    'WO-1a:预期产出 —— 【这里的数是排计划那个人的估计,不是一条标准】。
【为什么这句话必须写在表上】WO-1 的调查量过:今天这个库里【没有】任何可以推出预期产出的东西 —— 没有配方/BOM(Doc 2 明写它留给多工序那一次升级),投料侧 19 条含量行的 content_source 全是 NULL(一条化验来源都没有,PROC-1 刻意不回填),而两侧都测过的 (加工单, 金属) 组合【只有 3 个】。三个观测不是一个回收率。所以这个数只能是手敲的,而手敲的数与标准值意义完全不同:它比出来的差异是【估计 vs 实际】,不是【标准 vs 实际】。把它当标准读,会让一次估得保守的计划看起来像一次超产。
【行是可选的】没有行 = 没人记录过预期,而不是预期为零 —— 差异视图(WO-1b)必须把这两件事分开说。一个 COALESCE(...,0) 会把"没估过"变成"估了零",于是任何产出都是超额完成。
【将来有了 BOM 怎么办】它作为【另一个带标签的来源】进来(新列 basis/source,或另一张表),【不覆盖这一张】。覆盖会把"人估的"与"标准算的"混成一个数,而那两个数错的时候要找的人不是同一个。';

-- ═══ 5 · 变更留痕(只增不改)═══════════════════════════════════════════════
-- 形状取自 sales_order_history(SO-1b):成对的 old_/new_ + 必填理由。
CREATE TABLE public.work_order_history (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    work_order_id uuid NOT NULL REFERENCES public.work_orders (id),
    change_type   text NOT NULL CHECK (change_type IN
                  ('created','released','closed','cancelled',
                   'header_update','line_add','line_update','line_remove',
                   'expected_add','expected_update','expected_remove')),
    detail        text,
    changed_at    timestamptz NOT NULL DEFAULT now(),
    changed_by    uuid DEFAULT auth.uid(),
    -- 【行的 id 不加外键 —— 这是 SO-1b 学到的】留痕要活得比它记录的那一行久:
    -- 一条被删掉的计划行,它"曾经存在过、被谁在什么时候删的"正是留痕的全部意义。
    -- 加了外键,删行要么被拦、要么把留痕一起带走,两种都是错的。
    work_order_line_id     uuid,
    work_order_expected_id uuid,
    -- 表头可改字段的成对值
    old_scheduled_date date,
    new_scheduled_date date,
    old_notes          text,
    new_notes          text,
    -- 行可改字段的成对值(计划量 / 预期量共用这一对 —— 两者都是"一个数",
    -- 而 change_type 已经说清了是哪一种行)
    old_qty            numeric,
    new_qty            numeric,
    -- 行归属的物料(行删掉之后,留痕仍要说得出"删的是哪一种料")
    material_id        uuid,
    amend_reason       text
);

COMMENT ON COLUMN public.work_order_history.work_order_line_id IS
    '哪一条计划行(行改动才有)。【故意没有外键】—— 留痕要活得比行久:一条被删掉的行"曾经存在、被谁删的"正是留痕的意义所在(与 sales_order_history 同一条)。';

-- ═══ 6 · 实绩那一侧的接缝列(纯新增 DDL)═══════════════════════════════════
-- 【这一列现在就建,但 WO-1a 不写它】commit_processing_run 的签名这一刀不动
-- (那是 WO-1b)。它现在存在,是为了让本刀的两道守卫 ——
-- amend_work_order 的地板、cancel_work_order 的 WO_HAS_RUNS ——
-- 读到一个【真的列】而不是一个桩:一条从没在真列上跑过的守卫,与一条不存在的
-- 守卫在测试里长得一模一样。今天它对每一行都是 NULL,那正是"还没有工单挂上
-- 加工单"这个事实的忠实表示。
ALTER TABLE public.processing_runs
    ADD COLUMN work_order_id uuid REFERENCES public.work_orders (id);

COMMENT ON COLUMN public.processing_runs.work_order_id IS
    'WO-1a 建列,WO-1b 由 commit_processing_run 写入。这一次加工是照哪一张工单做的;为空 = 临时起意的加工(那是合法的,而且差异报表必须把它显示成【计划外】,不是显示成零)。';

CREATE INDEX idx_processing_runs_work_order ON public.processing_runs (work_order_id)
    WHERE work_order_id IS NOT NULL;

-- ═══ 7 · RLS ═══════════════════════════════════════════════════════════════
-- 读:module.processing.view。写:【一条 INSERT/UPDATE/DELETE 策略都不给】——
-- 唯一写入口是下面那几个 SECURITY DEFINER 函数(与 so_issues / cn_issues /
-- approval_log 同一条:单据不该有第二个写法)。
ALTER TABLE public.work_orders                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.work_order_lines            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.work_order_expected_outputs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.work_order_history          ENABLE ROW LEVEL SECURITY;

CREATE POLICY "work_orders select by permission" ON public.work_orders
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
CREATE POLICY "work_order_lines select by permission" ON public.work_order_lines
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
CREATE POLICY "work_order_expected_outputs select by permission" ON public.work_order_expected_outputs
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
CREATE POLICY "work_order_history select by permission" ON public.work_order_history
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));

-- ═══ 8 · 新建 ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.create_work_order(
    p_lines jsonb,
    p_expected jsonb DEFAULT NULL,
    p_scheduled_date date DEFAULT NULL,
    p_notes text DEFAULT NULL)
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
    PERFORM require_permission('module.processing.edit');

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
        INSERT INTO work_order_expected_outputs (work_order_id, material_id, expected_qty)
        SELECT v_id, (elem->>'material_id')::uuid, (elem->>'expected_qty')::numeric
          FROM jsonb_array_elements(p_expected) elem;
    END IF;

    INSERT INTO work_order_history (work_order_id, change_type, detail, changed_by)
    VALUES (v_id, 'created', v_code, v_user);

    RETURN jsonb_build_object('work_order_id', v_id, 'code', v_code, 'status', 'draft');
END;
$function$;

-- ═══ 9 · 状态迁移 ═══════════════════════════════════════════════════════════
-- 【允许的迁移,一张表说完 —— 不要写成一处一个的单点守卫】
--
--   draft     --release--> released
--   draft     --cancel-->  cancelled
--   released  --close-->   closed      (理由必填;短交合法)
--   released  --cancel-->  cancelled   (仅当【没有任何加工单挂上来】)
--   closed    -->  终态,任何动作都拒
--   cancelled -->  终态,任何动作都拒
--
-- 拒绝的名字按【当前态】说话,而不是按"你不能这样做":
--   release:非 draft            → WO_NOT_DRAFT|code|status
--   close  :非 released         → WO_NOT_RELEASED|code|status
--   cancel :非 draft/released   → WO_NOT_CANCELLABLE|code|status
--   cancel :有挂上来的加工单     → WO_HAS_RUNS|code|n
--
-- 【为什么 close 只从 released 出发,而不从 draft】关一张从没放行过的计划,
-- 说的是"这件事我不做了" —— 那是 cancel。两个词分开,后面看历史的人才分得清
-- "做过、做完了"与"根本没开始"。

CREATE OR REPLACE FUNCTION public.release_work_order(p_work_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_wo   work_orders%ROWTYPE;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status <> 'draft' THEN
        RAISE EXCEPTION 'WO_NOT_DRAFT|%|%', v_wo.code, v_wo.status;
    END IF;

    UPDATE work_orders
       SET status = 'released', updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, changed_by)
    VALUES (p_work_order_id, 'released', v_user);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code, 'status', 'released');
END;
$function$;

CREATE OR REPLACE FUNCTION public.close_work_order(p_work_order_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_wo   work_orders%ROWTYPE;
    v_runs integer;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status <> 'released' THEN
        -- draft 的单子要"不做了",走 cancel —— 见上面那张迁移表的最后一段
        RAISE EXCEPTION 'WO_NOT_RELEASED|%|%', v_wo.code, v_wo.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_CLOSE_REASON_REQUIRED|%', v_wo.code;
    END IF;

    -- 【短交不拦 —— 这是一个决定,不是遗漏】实际做的比计划少,是一个要记下来的
    -- 事实。拦住它只会让人把计划改小以求关单,而那正好把差异从账上抹掉 ——
    -- 一条逼人去伪造数据的规则比没有规则更坏。收工时挂了几条加工单一并记进理由行,
    -- 让"关的时候是什么样"留在历史里,而不必事后重算。
    SELECT count(*) INTO v_runs FROM processing_runs
     WHERE work_order_id = p_work_order_id AND deleted_at IS NULL;

    UPDATE work_orders
       SET status = 'closed', closed_at = now(), closed_by = v_user,
           close_reason = btrim(p_reason), updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, detail, amend_reason, changed_by)
    VALUES (p_work_order_id, 'closed', 'runs=' || v_runs::text, btrim(p_reason), v_user);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'status', 'closed', 'runs', v_runs);
END;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_work_order(p_work_order_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_wo   work_orders%ROWTYPE;
    v_runs integer;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status NOT IN ('draft','released') THEN
        RAISE EXCEPTION 'WO_NOT_CANCELLABLE|%|%', v_wo.code, v_wo.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_CANCEL_REASON_REQUIRED|%', v_wo.code;
    END IF;

    -- 【已经开过工的单子不能取消 —— 它只能收工】取消的意思是"这件事没有发生过";
    -- 而挂着一条加工单,就意味着料真的下去了、产出真的进了库。把它标成 cancelled
    -- 会让那几次加工失去它们的出处,而出处是这套系统存在的理由。
    SELECT count(*) INTO v_runs FROM processing_runs
     WHERE work_order_id = p_work_order_id AND deleted_at IS NULL;
    IF v_runs > 0 THEN
        RAISE EXCEPTION 'WO_HAS_RUNS|%|%', v_wo.code, v_runs;
    END IF;

    UPDATE work_orders
       SET status = 'cancelled', cancelled_at = now(), cancelled_by = v_user,
           cancel_reason = btrim(p_reason), updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, amend_reason, changed_by)
    VALUES (p_work_order_id, 'cancelled', btrim(p_reason), v_user);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code, 'status', 'cancelled');
END;
$function$;

-- ═══ 10 · 改单 ══════════════════════════════════════════════════════════════
-- 【draft 与 released 都改得动,而这与销售订单刻意不同】销售订单一确认就冻,
-- 因为确认之后有钱和货站在那些数字上;一张放行了的工单只是"可以开工了",
-- 计划本来就会随现实调整。所以这里不冻,而是【留痕 + 地板】:
--   * 每一次改动都写一条 history,理由必填;
--   * 计划量不能低于【已经吃掉的量】—— 那个量是发生过的事实,改计划改不掉它。
CREATE OR REPLACE FUNCTION public.amend_work_order(
    p_work_order_id uuid,
    p_reason text,
    p_scheduled_date date DEFAULT NULL,
    p_set_scheduled boolean DEFAULT false,
    p_notes text DEFAULT NULL,
    p_set_notes boolean DEFAULT false,
    p_lines jsonb DEFAULT NULL,
    p_expected jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_wo       work_orders%ROWTYPE;
    v_elem     jsonb;
    v_line     work_order_lines%ROWTYPE;
    v_exp      work_order_expected_outputs%ROWTYPE;
    v_mat      uuid;
    v_qty      numeric;
    v_consumed numeric;
    v_changes  integer := 0;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status NOT IN ('draft','released') THEN
        RAISE EXCEPTION 'WO_NOT_AMENDABLE|%|%', v_wo.code, v_wo.status;
    END IF;
    -- 【理由必填,而且在动手之前就问】—— 一次没有理由的计划改动,过两天没人
    -- 说得清当时是为了什么(与 hold_stock 的 STK_REASON_REQUIRED 同一条)。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_AMEND_REASON_REQUIRED|%', v_wo.code;
    END IF;

    -- ── 表头 ────────────────────────────────────────────────────────────────
    -- 【为什么要 p_set_* 这个布尔】NULL 在这里有两个意思:"不改这一项"与
    -- "把它清空"。少了这个开关,"取消排期"就表达不出来 —— 而取消排期是一件
    -- 真实的事(计划推迟到不知道什么时候)。
    IF p_set_scheduled AND p_scheduled_date IS DISTINCT FROM v_wo.scheduled_date THEN
        INSERT INTO work_order_history (work_order_id, change_type,
                    old_scheduled_date, new_scheduled_date, amend_reason, changed_by)
        VALUES (p_work_order_id, 'header_update', v_wo.scheduled_date, p_scheduled_date,
                btrim(p_reason), v_user);
        UPDATE work_orders SET scheduled_date = p_scheduled_date WHERE id = p_work_order_id;
        v_changes := v_changes + 1;
    END IF;
    IF p_set_notes AND NULLIF(btrim(COALESCE(p_notes,'')),'') IS DISTINCT FROM v_wo.notes THEN
        INSERT INTO work_order_history (work_order_id, change_type,
                    old_notes, new_notes, amend_reason, changed_by)
        VALUES (p_work_order_id, 'header_update', v_wo.notes,
                NULLIF(btrim(COALESCE(p_notes,'')),''), btrim(p_reason), v_user);
        UPDATE work_orders SET notes = NULLIF(btrim(COALESCE(p_notes,'')),'')
         WHERE id = p_work_order_id;
        v_changes := v_changes + 1;
    END IF;

    -- ── 计划投料行 ──────────────────────────────────────────────────────────
    -- 每个元素:{material_id, planned_qty}。planned_qty 省略或为 null = 删这一行。
    IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
        FOR v_elem IN SELECT * FROM jsonb_array_elements(p_lines)
        LOOP
            v_mat := (v_elem->>'material_id')::uuid;
            IF v_mat IS NULL OR NOT EXISTS (
                SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'WO_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
            END IF;
            v_qty := (v_elem->>'planned_qty')::numeric;

            -- 【地板:已经吃掉的量】—— 挂在这张工单上的加工单,吃掉了多少这种料。
            -- 投料腿指向批次,批次才有物料,所以两侧都要 join 过去(进料批与
            -- 再加工的产出批各一条腿,FIN-25 的 XOR)。
            SELECT COALESCE(sum(pi.quantity_consumed), 0) INTO v_consumed
              FROM processing_runs r
              JOIN processing_inputs pi ON pi.run_id = r.id
              LEFT JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
              LEFT JOIN output_batches  ob ON ob.id = pi.output_batch_id
             WHERE r.work_order_id = p_work_order_id
               AND r.deleted_at IS NULL
               AND r.status = 'committed'
               AND COALESCE(ib.material_id, ob.material_id) = v_mat;

            SELECT * INTO v_line FROM work_order_lines
             WHERE work_order_id = p_work_order_id AND material_id = v_mat;

            IF v_qty IS NULL THEN
                -- 删行
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'WO_LINE_NOT_FOUND|%', v_mat;
                END IF;
                -- 【删掉一条已经吃过料的行,与把它改成 0 是同一件事】所以同一道地板
                IF v_consumed > 0 THEN
                    RAISE EXCEPTION 'WO_LINE_BELOW_CONSUMED|%|%|%', v_mat, 0, v_consumed;
                END IF;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_line_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'line_remove', v_line.id, v_mat,
                        v_line.planned_qty, NULL, btrim(p_reason), v_user);
                DELETE FROM work_order_lines WHERE id = v_line.id;
                v_changes := v_changes + 1;
            ELSIF v_qty <= 0 THEN
                RAISE EXCEPTION 'WO_LINE_QTY_INVALID';
            ELSIF NOT FOUND THEN
                -- 加行
                INSERT INTO work_order_lines (work_order_id, material_id, planned_qty)
                VALUES (p_work_order_id, v_mat, v_qty) RETURNING * INTO v_line;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_line_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'line_add', v_line.id, v_mat, NULL, v_qty,
                        btrim(p_reason), v_user);
                v_changes := v_changes + 1;
            ELSIF v_qty IS DISTINCT FROM v_line.planned_qty THEN
                -- 改量 —— 地板在这里
                IF v_qty < v_consumed THEN
                    RAISE EXCEPTION 'WO_LINE_BELOW_CONSUMED|%|%|%', v_mat, v_qty, v_consumed;
                END IF;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_line_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'line_update', v_line.id, v_mat,
                        v_line.planned_qty, v_qty, btrim(p_reason), v_user);
                UPDATE work_order_lines SET planned_qty = v_qty WHERE id = v_line.id;
                v_changes := v_changes + 1;
            END IF;
        END LOOP;
    END IF;

    -- ── 预期产出行 ──────────────────────────────────────────────────────────
    -- 【预期产出没有地板】它是一句估计,不是一个已经发生的事实 —— 改小它不会
    -- 与任何已经发生的事情矛盾。这与计划投料行刻意不同,而不同的理由值得写下来:
    -- 地板护的是"实绩不可否认",预期产出这一侧没有实绩可否认。
    IF p_expected IS NOT NULL AND jsonb_typeof(p_expected) = 'array' THEN
        FOR v_elem IN SELECT * FROM jsonb_array_elements(p_expected)
        LOOP
            v_mat := (v_elem->>'material_id')::uuid;
            IF v_mat IS NULL OR NOT EXISTS (
                SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'WO_EXPECTED_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
            END IF;
            v_qty := (v_elem->>'expected_qty')::numeric;
            SELECT * INTO v_exp FROM work_order_expected_outputs
             WHERE work_order_id = p_work_order_id AND material_id = v_mat;

            IF v_qty IS NULL THEN
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'WO_EXPECTED_NOT_FOUND|%', v_mat;
                END IF;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_expected_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'expected_remove', v_exp.id, v_mat,
                        v_exp.expected_qty, NULL, btrim(p_reason), v_user);
                DELETE FROM work_order_expected_outputs WHERE id = v_exp.id;
                v_changes := v_changes + 1;
            ELSIF v_qty <= 0 THEN
                RAISE EXCEPTION 'WO_EXPECTED_QTY_INVALID';
            ELSIF NOT FOUND THEN
                INSERT INTO work_order_expected_outputs (work_order_id, material_id, expected_qty)
                VALUES (p_work_order_id, v_mat, v_qty) RETURNING * INTO v_exp;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_expected_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'expected_add', v_exp.id, v_mat, NULL, v_qty,
                        btrim(p_reason), v_user);
                v_changes := v_changes + 1;
            ELSIF v_qty IS DISTINCT FROM v_exp.expected_qty THEN
                INSERT INTO work_order_history (work_order_id, change_type, work_order_expected_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'expected_update', v_exp.id, v_mat,
                        v_exp.expected_qty, v_qty, btrim(p_reason), v_user);
                UPDATE work_order_expected_outputs SET expected_qty = v_qty WHERE id = v_exp.id;
                v_changes := v_changes + 1;
            END IF;
        END LOOP;
    END IF;

    IF v_changes = 0 THEN
        RAISE EXCEPTION 'WO_AMEND_NO_CHANGES|%', v_wo.code;
    END IF;

    UPDATE work_orders SET updated_at = now(), updated_by = v_user WHERE id = p_work_order_id;
    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'changes', v_changes);
END;
$function$;

COMMIT;
