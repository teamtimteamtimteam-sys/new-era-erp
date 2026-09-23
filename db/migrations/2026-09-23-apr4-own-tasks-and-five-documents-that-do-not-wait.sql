-- db/migrations/2026-09-23-apr4-own-tasks-and-five-documents-that-do-not-wait.sql
-- ════════════════════════════════════════════════════════════════════════════
-- APR-4 · 自己的任务例外(Tim,2026-09-23 · Q4–Q8)
-- ════════════════════════════════════════════════════════════════════════════
--
-- ★★★ 审批是【开着】的,而本刀一刻也不碰审批:没有一条链、一行策略、一个开关。
-- 自证 ① 钉住开关;② 钉住"一行留痕都没写、每一条链的在途张数都没变"。
-- 委托书要接的五种单据(收货 · 发票 · 货运单据 · 固定资产处置 · 加工单提交)
-- 实测【没有一种有等人批的状态】—— 建单即是动作,与 APR-3 的付款同形。
-- Tim 的 Q1:全部移出,证据写在 docs/approvals.md §3e;approval_log 的枚举不动。
--
-- 本刀只做一件事:没有 module.tasks.edit 的人(今天是 Vince,gm 只读)可以建、改
-- 【自己的私人任务】;并且顺手堵上两个对【每一个编辑人】都开着的口子。
--
--   自己的任务 = task_type = 'personal' AND owner_id = current_user_employee()
--                (task_is_own,唯一一份定义;按手里这一行的两列判)
--   例外允许:建(被强制为自己的私人任务)· 改表头与状态 · 步骤的增改勾删 · 软删
--   例外不允许:升级为团队任务 · 加参与者 · 改归属人;仍然要 module.tasks.view
--   对每一个人:新建的任务归属人必须是自己(TASK_OWNER_NOT_SELF);
--               归属人不许改(TASK_OWNER_IMMUTABLE)
--
-- ★ 与 Q7 的字面措辞有一处不同,是一次测量逼出来的:
--   "把语句级的 enforce_write_permission 换成逐行触发器" 做不到 ——
--   ① 行级触发器在零行时根本不触发(enforce_write_permission 抬头记的实测),
--      于是一个被 USING 挡掉的写仍会是一次静默零行;
--   ② fixture 198 按【名字】要求每一张带写策略的表都有一支 enforce_write_permission。
--   所以:语句级那一支留下(多认 module.tasks.view),写策略的 USING 放宽到
--   "你看得见的行",由新的逐行守卫按名拒。效果就是 Q7 要的:例外走得通,
--   其余一律按名拒,没有一处变成静默零行。
--
-- 【本刀会让线上立刻发生的事】(破窗期间,旧代码 + 新库)
--   · Vince 可以建自己的私人任务了(旧的"新建"按钮本来就没有设闸,旧弹窗的类型下拉
--     若选了"团队",会被按名拒 PERMISSION_DENIED|module.tasks.edit)。
--   · 编辑人对一张【看得见却不在上面】的团队任务拖状态:以前是静默零行
--     (旧代码报"没有改动"),现在是 TASK_NOT_EDITABLE —— 旧映射器不认得它,
--     退到共用兜底(一句人话 + 可追查的短码)。
--   · 没有任何人失去此前有的写权:完整编辑人的每一条路判据不变(can_edit_task)。
--
-- NOTE: 镜像在同一个提交里更新(db/functions 五个 · db/tables 三张 · db/views 一张)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ⓪ 之前的读数
CREATE TEMP TABLE apr4_before ON COMMIT DROP AS
SELECT (SELECT approvals_enabled FROM finance_settings LIMIT 1)                        AS enabled,
       (SELECT count(*) FROM approval_log)                                             AS approval_log_rows,
       (SELECT count(*) FROM leave_requests      WHERE status='pending'   AND deleted_at IS NULL) AS leave_pending,
       (SELECT count(*) FROM medical_claims      WHERE status='submitted' AND deleted_at IS NULL) AS medical_pending,
       (SELECT count(*) FROM performance_reviews WHERE status='submitted')             AS reviews_pending,
       (SELECT count(*) FROM purchase_orders     WHERE approval_status='pending' AND deleted_at IS NULL) AS po_pending,
       (SELECT count(*) FROM work_orders         WHERE status='draft')                 AS wo_draft,
       (SELECT count(*) FROM expense_claims      WHERE status='submitted')             AS claim_pending,
       (SELECT count(*) FROM stocktakes          WHERE status='open' AND deleted_at IS NULL) AS stocktake_open,
       (SELECT count(*) FROM tasks)                                                    AS tasks_rows,
       (SELECT string_agg(rp.permission_code, ',' ORDER BY rp.permission_code)
          FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'cfo') AS cfo_codes;

SELECT 'BEFORE' AS at, * FROM apr4_before;

-- ① 函数
CREATE OR REPLACE FUNCTION public.task_is_own(p_task_type text, p_owner_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(p_task_type = 'personal' AND p_owner_id = current_user_employee(), false);
$function$;

COMMENT ON FUNCTION public.task_is_own(text, uuid) IS
'APR-4(Tim 的 Q4):「自己的任务」的【唯一】定义 —— 私人任务,且归属人就是调用者这个人(current_user_employee(),按人认,一个人的几个账号算同一个人)。
按【这一行自己的两列】判,不回表查 —— 所以插入与更新的判据可以直接把手里这一行交给它。
★ 它不看 module.tasks.view:那一半由调用方(can_write_task、trg_tasks_guard_write、插入策略)各自要求 —— 这里只回答"这是不是你的",不回答"你能不能进任务模块"。
★ 为什么不是 created_by = 我:created_by 是账号空间、客户端写得动,伪造得出来;读的那一边(select 策略)也从来不看它。
★ 为什么不是"我是参与者":那会让一个只读的人改动别人的团队任务。团队任务一律要 module.tasks.edit。';

CREATE OR REPLACE FUNCTION public.can_write_task(p_task_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT public.can_edit_task(p_task_id)
        OR (has_permission('module.tasks.view')
            AND EXISTS (
                SELECT 1 FROM public.tasks t
                 WHERE t.id = p_task_id
                   AND t.deleted_at IS NULL
                   AND public.task_is_own(t.task_type, t.owner_id)));
$function$;

COMMENT ON FUNCTION public.can_write_task(uuid) IS
'APR-4(Tim 的 Q4/Q5):这个人能不能改这张任务的【内容】—— 表头、状态、步骤、软删。
= can_edit_task(持 module.tasks.edit 的完整编辑人:团队任务要是活跃参与者,私人任务要是归属人)
  OR 自己的任务例外(持 module.tasks.view,且 task_is_own)。
★ 它【不】管升级为团队任务、加参与者、改归属人 —— 那些仍然只有 can_edit_task 开得了(升级与参与者),或者谁都开不了(归属人,trg_tasks_guard_write 按名拒)。
★ 读它的:tasks 的 WITH CHECK、task_nodes 的写策略与守卫、task_board_rows.may_write(屏幕上那一个"能不能改"的判据就是它,lib/taskAccess.ts 只是把它读出来)。';

CREATE OR REPLACE FUNCTION public.trg_tasks_guard_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 属主 / SECURITY DEFINER / 迁移 / fixture 的 postgres:RLS 不生效,放行 ——
    -- 与 enforce_write_permission 同一格,理由见它的抬头。
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        -- 归属人解析不出(没有关联员工的账号):让 trg_tasks_owner_required 说那句话。
        IF NEW.owner_id IS NULL THEN
            RETURN NEW;
        END IF;
        -- Q6(i):对【每一个人】—— 新建的任务只能归自己。
        IF NEW.owner_id IS DISTINCT FROM current_user_employee() THEN
            RAISE EXCEPTION 'TASK_OWNER_NOT_SELF';
        END IF;
        IF public.has_permission('module.tasks.edit') THEN
            RETURN NEW;
        END IF;
        IF public.has_permission('module.tasks.view')
           AND public.task_is_own(NEW.task_type, NEW.owner_id) THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'PERMISSION_DENIED|module.tasks.edit';
    END IF;

    -- UPDATE
    -- Q6(ii):对【每一个人】—— 归属人不许改。没有任何功能转移归属。
    IF NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
        RAISE EXCEPTION 'TASK_OWNER_IMMUTABLE|%', OLD.code;
    END IF;
    IF public.can_edit_task(OLD.id) THEN
        RETURN NEW;
    END IF;
    -- 自己的任务例外:内容可以改,类型不许改(升级为团队任务要 module.tasks.edit)。
    IF public.has_permission('module.tasks.view')
       AND public.task_is_own(OLD.task_type, OLD.owner_id)
       AND NEW.task_type IS NOT DISTINCT FROM OLD.task_type THEN
        RETURN NEW;
    END IF;
    -- 持码却不在这张任务上:那不是一个管理员勾得出来的码,说成缺码就是说错原因。
    IF public.has_permission('module.tasks.edit') THEN
        RAISE EXCEPTION 'TASK_NOT_EDITABLE|%', OLD.code;
    END IF;
    RAISE EXCEPTION 'PERMISSION_DENIED|module.tasks.edit';
END;
$function$;

COMMENT ON FUNCTION public.trg_tasks_guard_write() IS
'APR-4(Tim 的 Q6/Q7):tasks 的逐行写闸。插入:归属人必须是自己(对每一个人);没有 module.tasks.edit 的人只能建自己的私人任务。更新:归属人冻结(对每一个人,TASK_OWNER_IMMUTABLE);完整编辑人(can_edit_task)放行;自己的任务例外放行但类型不许变;其余按名拒 —— 持码而不在任务上抛 TASK_NOT_EDITABLE,不持码抛 PERMISSION_DENIED|module.tasks.edit。
★ 它【不能】单独替掉语句级的 enforce_write_permission:行级触发器在零行时根本不触发。所以 tasks 的 UPDATE 策略的 USING 放宽到"你看得见的行",让被拒的那一行真的进到这里、被按名拒;语句级那一支仍在(fixture 198 按名字要求每张带写策略的表都有它),只是多认一个 module.tasks.view。
★ 名字以 trg_tasks_guard 开头是【承重】的:同一时点的 BEFORE 触发器按名字字母序触发,它必须排在 trg_tasks_owner_required 与 trg_tasks_type_transition 之前 —— 否则一次被拒的升级会先让类型迁移那一支跑起来。';

CREATE OR REPLACE FUNCTION public.trg_task_nodes_guard_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;

    IF (TG_OP IN ('UPDATE', 'DELETE') AND NOT public.can_write_task(OLD.task_id))
       OR (TG_OP IN ('INSERT', 'UPDATE') AND NOT public.can_write_task(NEW.task_id)) THEN
        IF public.has_permission('module.tasks.edit') THEN
            RAISE EXCEPTION 'TASK_NOT_EDITABLE|';
        END IF;
        RAISE EXCEPTION 'PERMISSION_DENIED|module.tasks.edit';
    END IF;

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

COMMENT ON FUNCTION public.trg_task_nodes_guard_write() IS
'APR-4(Tim 的 Q5/Q7):task_nodes 的逐行写闸 —— 步骤跟着它那张任务走,判据就是 can_write_task(任务)。自己的私人任务上的步骤,没有 module.tasks.edit 也加得、改得、勾得、删得。
★ 同 trg_tasks_guard_write:写策略的 USING 放宽到 can_view_task,让被拒的行进到这里按名拒;语句级 enforce_write_permission 仍在,多认一个 module.tasks.view。名字排在 trg_task_nodes_no_orphan / _touch 之前。';

CREATE OR REPLACE FUNCTION public.trg_task_participants_guard_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;

    IF NOT public.can_edit_task(NEW.task_id) THEN
        IF public.has_permission('module.tasks.edit') THEN
            RAISE EXCEPTION 'TASK_NOT_EDITABLE|';
        END IF;
        RAISE EXCEPTION 'PERMISSION_DENIED|module.tasks.edit';
    END IF;

    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.trg_task_participants_guard_write() IS
'APR-4(Tim 的 Q5/Q7):参与者【不在】自己的任务例外里 —— 加人、移人一律要 can_edit_task(module.tasks.edit + 在任务上)。此前一个没有码的人插参与者撞的是一句无名的 "new row violates row-level security policy";现在按名拒。
写策略与语句级 enforce_write_permission 一字未改:对一个不持码的人,更新本来就被语句级那一支按名拒了。
★ 属主路径(升级时 ensure_task_owner_participant 以 SECURITY DEFINER 插归属人那一行)由 row_security_active 放行。';

-- ② tasks:写策略
DROP POLICY "tasks insert by permission" ON public.tasks;
DROP POLICY "tasks update by predicate" ON public.tasks;
DROP POLICY "tasks delete by predicate" ON public.tasks;
CREATE POLICY "tasks insert by permission"
    ON public.tasks
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (
        owner_id = current_user_employee()
        AND (
            has_permission('module.tasks.edit'::text)
            OR (has_permission('module.tasks.view'::text) AND task_is_own(task_type, owner_id))
        )
    );
CREATE POLICY "tasks update by predicate"
    ON public.tasks
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (deleted_at IS NULL AND (can_edit_task(id) OR can_view_task(id)))
    WITH CHECK (can_write_task(id));
CREATE POLICY "tasks delete by predicate"
    ON public.tasks
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (can_edit_task(id) OR can_view_task(id));

-- ③ task_nodes:写策略
DROP POLICY "task_nodes insert" ON public.task_nodes;
DROP POLICY "task_nodes update" ON public.task_nodes;
DROP POLICY "task_nodes delete" ON public.task_nodes;
CREATE POLICY "task_nodes insert" ON public.task_nodes
    FOR INSERT TO authenticated WITH CHECK (can_write_task(task_id));
CREATE POLICY "task_nodes update" ON public.task_nodes
    FOR UPDATE TO authenticated USING (can_view_task(task_id)) WITH CHECK (can_write_task(task_id));
CREATE POLICY "task_nodes delete" ON public.task_nodes
    FOR DELETE TO authenticated USING (can_view_task(task_id));

-- ④ 语句级写闸多认 module.tasks.view;逐行守卫
DROP TRIGGER enforce_write_permission ON public.tasks;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.tasks
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.tasks.edit', 'module.tasks.view');
DROP TRIGGER enforce_write_permission ON public.task_nodes;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.task_nodes
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.tasks.edit', 'module.tasks.view');

CREATE TRIGGER trg_tasks_guard_write
    BEFORE INSERT OR UPDATE ON public.tasks
    FOR EACH ROW EXECUTE FUNCTION trg_tasks_guard_write();
CREATE TRIGGER trg_task_nodes_guard_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.task_nodes
    FOR EACH ROW EXECUTE FUNCTION trg_task_nodes_guard_write();
CREATE TRIGGER trg_task_participants_guard_write
    BEFORE INSERT OR UPDATE ON public.task_participants
    FOR EACH ROW EXECUTE FUNCTION trg_task_participants_guard_write();

-- ⑤ 看板视图:may_write / may_manage
CREATE OR REPLACE VIEW public.task_board_rows
WITH (security_invoker = on) AS
SELECT
    t.id, t.code, t.title, t.status, t.priority, t.task_type,
    t.due_date, t.reminder_at, t.tags, t.owner_id,
    n.node_count,
    n.done_count,
    -- 【步骤排到了截止日之后】—— 是一句陈述,不是一个警告色。
    -- 没有截止日、或者没有带日期的步骤时,它是 NULL(什么都不说),
    -- 不是 false(那会读成"一切正常")。
    CASE WHEN t.due_date IS NULL OR n.max_node_date IS NULL THEN NULL
         ELSE n.max_node_date > t.due_date END AS steps_overrun_due_date,
    -- APR-4:屏幕上"能不能改这张任务"的判据【就是】数据库那一个 ——
    -- may_write = can_write_task(内容:表头 / 状态 / 步骤 / 软删,含自己的任务例外);
    -- may_manage = can_edit_task(升级为团队任务 / 参与者,只有完整编辑人)。
    -- lib/taskAccess.ts 只读这两列,不自己比权限码。
    can_write_task(t.id) AS may_write,
    can_edit_task(t.id) AS may_manage
FROM public.tasks t
LEFT JOIN LATERAL (
    SELECT count(*)::int AS node_count,
           count(*) FILTER (WHERE d.done)::int AS done_count,
           max(d.target_date) FILTER (WHERE NOT d.done) AS max_node_date
      FROM public.task_nodes d WHERE d.task_id = t.id) n ON true
WHERE t.deleted_at IS NULL;

COMMENT ON VIEW public.task_board_rows IS
'看板与详情页共用的派生值:步骤数、已完成数、以及【步骤是否排到了截止日之后】。
【一处实现,两个调用者】—— 把 3/5 算在 TaskBoard.tsx 里,详情页就会算第二遍,然后两份实现从写下的第二天开始漂移(这个仓库为这件事付过四次学费:化验预览、GrantRunner、重估预览、/finance/payments)。
【security_invoker = on 是【有意】的,而它的 61 个邻居都是 off】:这张视图的行过滤【就是】RLS 本身。把它改成 off,视图对读者依旧工作得完美无缺 —— 只是每一张任务对每一个持 module.tasks.view 的人都可见了,而且不报任何错。绿的,却对某一类读者是错的:这正是 OPS-14 那五处 xmodule 缺陷的签名。要改它之前,先想清楚谁来做行过滤。
【owner_id 自 TASK-1c-a 起是员工空间(employees.id)】,不再是 auth.uid();这里只投影它,不比较它。
APR-4:末尾两列 may_write / may_manage 是屏幕上"能不能改"的唯一来源(can_write_task / can_edit_task),页面不自己比权限码。
注意 reloptions 里 security_invoker 可能写成 on 也可能写成 true —— 任何用 grep 找它的检查两种都要认(processing_metal_recovery 是本仓库唯一的 true)。';

-- ⑥ 自证
DO $selfcheck$
DECLARE
    b   apr4_before%ROWTYPE;
    v_n integer;
    v_s text;
BEGIN
    SELECT * INTO b FROM apr4_before;

    -- ① 审批开关没被碰
    IF (SELECT approvals_enabled FROM finance_settings LIMIT 1) IS DISTINCT FROM b.enabled OR NOT b.enabled THEN
        RAISE EXCEPTION 'APR4 自证①:approvals_enabled 变了或本来就不是 true';
    END IF;
    -- ② 一行留痕都没写、在途张数一张没变、任务行数没变、cfo 的码没变
    IF (SELECT count(*) FROM approval_log) <> b.approval_log_rows
       OR (SELECT count(*) FROM leave_requests WHERE status='pending' AND deleted_at IS NULL) <> b.leave_pending
       OR (SELECT count(*) FROM medical_claims WHERE status='submitted' AND deleted_at IS NULL) <> b.medical_pending
       OR (SELECT count(*) FROM performance_reviews WHERE status='submitted') <> b.reviews_pending
       OR (SELECT count(*) FROM purchase_orders WHERE approval_status='pending' AND deleted_at IS NULL) <> b.po_pending
       OR (SELECT count(*) FROM work_orders WHERE status='draft') <> b.wo_draft
       OR (SELECT count(*) FROM expense_claims WHERE status='submitted') <> b.claim_pending
       OR (SELECT count(*) FROM stocktakes WHERE status='open' AND deleted_at IS NULL) <> b.stocktake_open
       OR (SELECT count(*) FROM tasks) <> b.tasks_rows THEN
        RAISE EXCEPTION 'APR4 自证②:某个读数变了';
    END IF;
    SELECT string_agg(rp.permission_code, ',' ORDER BY rp.permission_code) INTO v_s
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'cfo';
    IF v_s IS DISTINCT FROM b.cfo_codes OR position('module.purchasing.view' IN v_s) = 0 THEN
        RAISE EXCEPTION 'APR4 自证③:cfo 的码 = %', v_s;
    END IF;
    -- ④ 三张表各有一支 enforce_write_permission(fixture 198 按名字要),两张多认了 view
    SELECT count(*) INTO v_n FROM pg_trigger tg
     WHERE tg.tgname = 'enforce_write_permission'
       AND tg.tgrelid IN ('public.tasks'::regclass, 'public.task_nodes'::regclass, 'public.task_participants'::regclass);
    IF v_n <> 3 THEN RAISE EXCEPTION 'APR4 自证④:enforce_write_permission 在三张任务表上有 % 支', v_n; END IF;
    -- ⑤ 三支守卫都在,并且 tasks 那一支按字母序排在类型迁移之前
    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE tgname IN ('trg_tasks_guard_write','trg_task_nodes_guard_write','trg_task_participants_guard_write');
    IF v_n <> 3 THEN RAISE EXCEPTION 'APR4 自证⑤:守卫 % 支', v_n; END IF;
    IF NOT ('trg_tasks_guard_write' < 'trg_tasks_owner_required' AND 'trg_tasks_guard_write' < 'trg_tasks_type_transition') THEN
        RAISE EXCEPTION 'APR4 自证⑤:守卫的名字排序不在类型迁移之前';
    END IF;
    -- ⑥ task_is_own 是唯一定义:插入策略与 can_write_task 都调它
    IF position('task_is_own' IN (SELECT with_check FROM pg_policies WHERE tablename='tasks' AND policyname='tasks insert by permission')) = 0
       OR position('task_is_own' IN (SELECT prosrc FROM pg_proc WHERE proname='can_write_task')) = 0 THEN
        RAISE EXCEPTION 'APR4 自证⑥:task_is_own 不是唯一定义';
    END IF;
    -- ⑦ 以 postgres 读视图:两列在,而且每张任务都有值(不是 NULL)
    SELECT count(*) INTO v_n FROM task_board_rows WHERE may_write IS NULL OR may_manage IS NULL;
    IF v_n <> 0 THEN RAISE EXCEPTION 'APR4 自证⑦:% 行 may_* 为 NULL', v_n; END IF;

    RAISE NOTICE 'APR4 自证七条全过';
END $selfcheck$;

SELECT 'AFTER' AS at,
       (SELECT approvals_enabled FROM finance_settings LIMIT 1) AS enabled,
       (SELECT count(*) FROM approval_log) AS approval_log_rows,
       (SELECT count(*) FROM tasks) AS tasks_rows,
       (SELECT string_agg(rp.permission_code, ',' ORDER BY rp.permission_code)
          FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'cfo') AS cfo_codes;

COMMIT;
