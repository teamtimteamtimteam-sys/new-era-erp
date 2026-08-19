-- TASK-1c-a:把 owner_id 搬进员工空间 —— 以及【同一支迁移里】跟着它走的四处判据
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本刀的排序点,一句话】
-- owner_id 这一列的【含义】变了(账号 uid → 员工 id)。含义变了而判据没跟着变,
-- 结果不是报错,是 can_view_task / can_edit_task 对每一张私人任务都返回 false ——
-- 【每一张任务对每一个人都消失,而且一声不响】。所以列的转换与四处判据
-- (两处触发器读点、两个谓词)必须在同一支迁移里,没有例外。
--
-- 【NOT NULL 被撤下了 —— 理由写在这里,因为它是一条设计判断】
-- 一条 NOT NULL 约束与下面 (c) 那个 BEFORE INSERT OR UPDATE 守卫,
-- 覆盖面【完全相同】:两者都拦住每一条写入路径上的每一个写入者。
-- 所以同时留着两个,不是"两层防护",是【一条规则说了两遍】——
-- 而本仓库对"一个事实两处陈述必然漂移"已经点过很多次名。
-- 留下的是守卫,因为它说得出一句人话;NOT NULL 只会抛 23502,
-- 那串码对录入的人完全不可读。
-- 【后果,顺带把一件事变简单了】:四行遗留的空 owner 因此不必被处置,
-- 于是这支迁移里【没有任何一处绕过守卫的写法】,(a) 走的是软删这条支持的路。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本刀发现的第三处 owner_id 读点 —— 计划里只写了两处】
-- 计划点名的是 trg_tasks_type_transition 里的两处。实际上还有第三处,
-- 而且它自己就带着 `← 1c 改这里` 的记号:
--     db/functions/trg_task_participants_guard.sql
--         JOIN public.tasks t ON t.owner_id = e.user_id
-- 不改它的后果【不是报错,是一条守卫静默失效】:转换之后这个 JOIN 永远匹配不上,
-- v_owner_emp 恒为 NULL,于是 TASK_OWNER_CANNOT_LEAVE 再也不会触发 ——
-- 归属人可以退出自己的任务,没有任何东西会说一句话。所以它在本刀里一并改。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【(d3) 与 (d4) 的"软移除"那一半没有做 —— 它与一条具名守卫直接冲突】
-- 计划要求:降级时把归属人的参与者行软移除;并把 personal 任务上残留的
-- 活跃参与者行一并软移除。**两者都做不到,而挡住它们的正是上面那条守卫:**
--     TASK_OWNER_CANNOT_LEAVE —— 归属人不能退出自己的任务。
-- 把归属人的行置 removed_at,正好命中它。要做成,只有两条路,而两条都是
-- 【改变一条具名规则的含义】,不是本刀能顺手决定的:
--   (i) 给守卫加一条豁免(例如"任务正在降级时不算退出");
--   (ii) 把移除挪到 tasks 的 AFTER UPDATE 触发器里,让守卫读得到新的 task_type。
-- 在裁定之前写任何一条,都是在一支迁移里悄悄改掉一条守卫的意思。
-- **不做的后果是有界的**:personal 任务上留着一行活跃参与者【不授予任何权限】——
-- can_edit_task 的私人分支看的是 owner_id,不是参与者。它是卫生问题,不是权限问题。
-- 而 (d2) 让升级可重入【不依赖】它:降级后那一行仍然活跃,再升级时
-- (d2) 的"已有活跃行 → 什么都不做"正好接住。promote→demote→promote 因此是通的。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【两处不对称:本刀【不动】,只把它们说出来,并点名哪一个是异类】
-- 其一,trg_tasks_type_transition 内部:
--     Site A(升级查归属人)  WHERE ... AND e.deleted_at IS NULL   ← 有
--     Site B(降级数其他人)  JOIN employees e ON e.id = p.employee_id  ← 无
--   **异类是 Site B**:同一个函数里对同一张 employees 表,一处滤软删一处不滤。
-- 其二,两个谓词之间:
--     can_edit_task  ... AND t.deleted_at IS NULL   ← 有
--     can_view_task  (整个函数里没有 deleted_at)     ← 无
--   **异类是 can_view_task**:同一对判据,一个看得见软删的任务,一个看不见。
-- 两处都【不在本刀改】—— 改判据的可见性是一次行为变更,要单独一刀、单独的断言。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【折叠进来的:创建门 (c2) 与 (d4 扩展)】—— 迁移尚未应用,所以并入本刀
-- TASK-2026-0007 生来就是 team,从未走过升级分支,于是【一行参与者都没有】,
-- 而 can_edit_task 的团队分支要求一个活跃参与者 —— 没有人改得动它。
-- 升级门保证"团队任务至少有归属人在场",创建门什么都不保证:同一个双门形状。
-- 【一个事实,一个写入者】:所以"把归属人置为活跃参与者"被抽成【一个函数】
-- ensure_task_owner_participant(),创建门与升级门都调它,没有第二份实现。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- (a) 四行无主任务:软删。断言先于写入。
-- ───────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_null_cnt   integer;
    v_owned_cnt  integer;
    v_codes      text;
    v_already    text;
BEGIN
    SELECT count(*) INTO v_null_cnt  FROM public.tasks WHERE owner_id IS NULL;
    SELECT count(*) INTO v_owned_cnt FROM public.tasks WHERE owner_id IS NOT NULL;

    IF v_null_cnt <> 4 THEN
        RAISE EXCEPTION 'ABORT_A|期待 4 行无主任务,实际 %', v_null_cnt;
    END IF;
    IF v_owned_cnt <> 2 THEN
        RAISE EXCEPTION 'ABORT_A|期待 2 行有主任务,实际 %', v_owned_cnt;
    END IF;

    SELECT string_agg(code, ', ' ORDER BY code) INTO v_codes
      FROM public.tasks WHERE owner_id IS NULL;
    SELECT string_agg(code, ', ' ORDER BY code) INTO v_already
      FROM public.tasks WHERE owner_id IS NULL AND deleted_at IS NOT NULL;

    RAISE NOTICE '(a) 无主任务四条:%  |  其中【本来就已软删】:%', v_codes, COALESCE(v_already, '(无)');
END $$;

-- 已经软删的那一条【不重新盖时间戳】—— 它的 deleted_at 是一个事实,不是一个标记位。
UPDATE public.tasks
   SET deleted_at = now()
 WHERE owner_id IS NULL
   AND deleted_at IS NULL;

-- ───────────────────────────────────────────────────────────────────────────
-- (b) owner_id 搬进员工空间
-- ───────────────────────────────────────────────────────────────────────────
UPDATE public.tasks t
   SET owner_id = e.id
  FROM public.employees e
 WHERE t.owner_id IS NOT NULL
   AND e.user_id = t.owner_id
   AND e.deleted_at IS NULL;

DO $$
DECLARE
    v_unresolved integer;
    v_null_cnt   integer;
    v_wrong      integer;
BEGIN
    -- 没换成功的(还留着 auth uid)会在下面加外键时炸,所以先按名说清楚
    SELECT count(*) INTO v_unresolved
      FROM public.tasks t
     WHERE t.owner_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.employees e WHERE e.id = t.owner_id);
    IF v_unresolved <> 0 THEN
        RAISE EXCEPTION 'ABORT_B|% 行 owner_id 没能解析成员工 id', v_unresolved;
    END IF;

    SELECT count(*) INTO v_null_cnt FROM public.tasks WHERE owner_id IS NULL;
    IF v_null_cnt <> 4 THEN
        RAISE EXCEPTION 'ABORT_B|转换后应仍有 4 行 NULL,实际 %', v_null_cnt;
    END IF;

    SELECT count(*) INTO v_wrong
      FROM public.tasks t JOIN public.employees e ON e.id = t.owner_id
     WHERE t.owner_id IS NOT NULL AND e.code <> 'EMP-2026-0002';
    IF v_wrong <> 0 THEN
        RAISE EXCEPTION 'ABORT_B|% 行没有解析到 EMP-2026-0002', v_wrong;
    END IF;

    RAISE NOTICE '(b) 两行存活任务已解析到 EMP-2026-0002;仍为 NULL 的 4 行是已软删的遗留';
END $$;

-- NULL 不受外键约束 —— 这正是四行遗留不挡这一步的原因。
ALTER TABLE public.tasks
    ADD CONSTRAINT tasks_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.employees (id);

ALTER TABLE public.tasks ALTER COLUMN owner_id SET DEFAULT current_user_employee();

COMMENT ON COLUMN public.tasks.owner_id IS
'归属人,【员工空间】(employees.id,外键)—— TASK-1c-a 之前它是账号空间(auth.uid())。
默认值是 current_user_employee():当前登录账号所关联的在册员工。
没有关联员工的账号建任务时,它会是 NULL —— 那一步由 trg_tasks_owner_required 按名拒绝
(TASK_CREATOR_NOT_AN_EMPLOYEE),不是由 NOT NULL 抛 23502:两者覆盖面相同,而只有前者说得出人话。
【仍为 NULL 的行只可能是 1c-a 之前的遗留,并且都已软删。】';

-- ───────────────────────────────────────────────────────────────────────────
-- (c) 具名拒绝:建/改任务时归属人解析不出在册员工
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_tasks_owner_required()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.owner_id IS NULL THEN
        RAISE EXCEPTION 'TASK_CREATOR_NOT_AN_EMPLOYEE|%', COALESCE(NEW.code, NEW.title)
          USING HINT = '你的登录账号还没有关联在册员工档案,所以这张任务没有归属人;请先在 HR 里关联账号';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.trg_tasks_owner_required() IS
'owner_id 不可为空这条规则【住在这里,不住在一条 NOT NULL 上】。
两者覆盖面完全相同(每条路径、每个写入者都拦),所以同时留着是【一条规则说了两遍】,必然漂移。
选守卫而不选约束,只为一件事:23502 不是一次可交付的拒绝。
它印出来是 "null value in column owner_id violates not-null constraint",
而撞上它的人真正需要知道的是【他的账号没有关联员工档案】——
一条只有读得懂 schema 的人才解得开的错误,等于没有拒绝(IOD-2 的那一课)。';

CREATE TRIGGER trg_tasks_owner_required
    BEFORE INSERT OR UPDATE ON public.tasks
    FOR EACH ROW EXECUTE FUNCTION public.trg_tasks_owner_required();

-- ───────────────────────────────────────────────────────────────────────────
-- 【一个事实,一个写入者】:把"归属人成为活跃参与者"抽成一个函数。
-- 创建门 (c2) 与升级门 (d2) 都调它 —— 不是各写一份。
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ensure_task_owner_participant(
    p_task_id uuid, p_owner_emp uuid, p_actor uuid DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id      uuid;
    v_removed timestamptz;
BEGIN
    SELECT id, removed_at INTO v_id, v_removed
      FROM public.task_participants
     WHERE task_id = p_task_id AND employee_id = p_owner_emp
     ORDER BY removed_at NULLS FIRST
     LIMIT 1;

    -- ① 已经在场 → 什么都不做。**这一支是升级可重入的全部要点**:
    --    降级不动参与者行,所以再升级时它仍然活跃;当年那条无条件 INSERT
    --    会在这里撞上 uq_task_participants_active,把一串重复键印到屏幕上。
    IF v_id IS NOT NULL AND v_removed IS NULL THEN
        RETURN 'already_active';
    END IF;

    -- ② 曾经在、已退出 → 复活成一次【重新加入】,并且【自己写那一行历史】:
    --    trg_task_participants_history 只认"在场→离场"那一次,复活它看不见。
    --    【不能只用 ON CONFLICT DO NOTHING】:那会让一行 removed_at 非空的
    --    归属人行原样留着,而 can_edit_task 的团队分支要求【活跃】行 ——
    --    归属人于是改不动自己的团队任务,并且没有任何错误说明为什么。
    IF v_id IS NOT NULL THEN
        UPDATE public.task_participants
           SET removed_at = NULL, removed_by = NULL
         WHERE id = v_id;
        INSERT INTO public.task_history (task_id, change_type, employee_id, changed_by)
        VALUES (p_task_id, 'participant_added', p_owner_emp, COALESCE(p_actor, p_owner_emp));
        RETURN 'rejoined';
    END IF;

    -- ③ 从来没有过 → 照旧插入。
    --    历史【故意不写】:trg_task_participants_history 的规矩是
    --    "变更记录记的是改动,不是初始状态",而归属人的头一行正是初始状态。
    INSERT INTO public.task_participants (task_id, employee_id, added_by)
    VALUES (p_task_id, p_owner_emp, COALESCE(p_actor, p_owner_emp));
    RETURN 'inserted';
END;
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- (c2) 创建门:生来就是 team 的任务,归属人当场成为活跃参与者。
-- AFTER INSERT —— BEFORE 里父行还不存在,子行会撞外键。
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_tasks_team_owner_participant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.task_type = 'team' AND NEW.owner_id IS NOT NULL THEN
        PERFORM public.ensure_task_owner_participant(NEW.id, NEW.owner_id, NEW.owner_id);
    END IF;
    RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.trg_tasks_team_owner_participant() IS
'创建门。【升级门保证"团队任务至少有归属人在场",创建门此前什么都不保证】——
TASK-2026-0007 生来是 team、一行参与者都没有,而 can_edit_task 的团队分支要求活跃参与者:
它从上线那天起就【没有任何人改得动】,而且不报错,只是每一次写 task_nodes 都被 RLS 拒掉。
两扇门写同一个不变式,所以它们调【同一个函数】。';

CREATE TRIGGER trg_tasks_team_owner_participant
    AFTER INSERT ON public.tasks
    FOR EACH ROW EXECUTE FUNCTION public.trg_tasks_team_owner_participant();

-- ───────────────────────────────────────────────────────────────────────────
-- (d) 排序点:两处触发器读点 + 第三处守卫读点 + 两个谓词,全部搬进员工空间。
--     (d2) 同时把升级分支做成【可重入】。
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_tasks_type_transition()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_owner_emp uuid;
    v_others    integer;
    v_what      text;
BEGIN
    IF NEW.task_type IS NOT DISTINCT FROM OLD.task_type THEN
        RETURN NEW;
    END IF;

    -- ── 升级:私人 → 团队。总是允许。
    IF OLD.task_type = 'personal' AND NEW.task_type = 'team' THEN
        -- 【Site A,已搬】owner_id 现在【就是】员工 id,不再需要经 user_id 绕一圈。
        SELECT e.id INTO v_owner_emp FROM public.employees e
         WHERE e.id = NEW.owner_id AND e.deleted_at IS NULL LIMIT 1;

        IF v_owner_emp IS NULL THEN
            RAISE EXCEPTION 'TASK_OWNER_NOT_AN_EMPLOYEE|%', NEW.code
              USING HINT = '这张任务的归属人没有对应的在册员工;升级之后将没有任何人改得动它';
        END IF;

        -- 【(d2) 可重入】。原来这里是一条无条件 INSERT —— 只在【第一次】升级时对。
        -- 降级不动参与者行(见抬头 (d3) 那一段),所以再升级时那一行仍然活跃,
        -- 无条件 INSERT 会撞 uq_task_participants_active,把一串重复键印上屏幕。
        -- 三种情形由 ensure_task_owner_participant 一处判定,创建门调的是同一个。
        v_what := public.ensure_task_owner_participant(NEW.id, v_owner_emp, current_user_employee());

        -- 出身那一行历史只在【真的发生了一次升级】时写。复活的那一行由
        -- ensure_task_owner_participant 自己写 participant_added,两者不重复。
        INSERT INTO public.task_history (task_id, change_type, employee_id, changed_by)
        VALUES (NEW.id, 'promoted_from_personal', v_owner_emp, current_user_employee());

        RETURN NEW;
    END IF;

    -- ── 降级:团队 → 私人。只在【可证明无损】的窗口内允许。
    IF OLD.task_type = 'team' AND NEW.task_type = 'personal' THEN
        -- 【Site B,已搬】owner_id 是员工 id,于是这里不再需要 JOIN employees ——
        -- 参与者行上的 employee_id 可以直接比。**这不是一次"顺手整理"**:
        -- 抬头里点名的 Site A/Site B 的 deleted_at 不对称,是被这次空间变更
        -- 【消解】掉的(Site B 从此根本不碰 employees),不是被我改掉的。
        -- 【removed_at 仍然【故意】不过滤】——(计划明写:不要动它)。
        -- 后果照实说:一个真实的第二个人加入后又退出,会让这张任务【永远】降不回私人。
        SELECT count(*) INTO v_others
          FROM public.task_participants p
         WHERE p.task_id = NEW.id
           AND p.employee_id IS DISTINCT FROM NEW.owner_id;

        IF v_others > 0 THEN
            RAISE EXCEPTION 'TASK_TYPE_LOCKED_PARTICIPANTS|%|%', NEW.code, v_others
              USING HINT = '这张任务上有别人参与过;改成私人会让他们读不到自己参与过的东西';
        END IF;
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'TASK_TYPE_TRANSITION_UNKNOWN|%|%', OLD.task_type, NEW.task_type;
END;
$function$;

-- 【第三处读点】计划里没有点名,而它自己带着记号。不改它,TASK_OWNER_CANNOT_LEAVE
-- 会【静默失效】:JOIN 永远匹配不上 → v_owner_emp 恒 NULL → 归属人可以退出自己的任务。
CREATE OR REPLACE FUNCTION public.trg_task_participants_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_me        uuid := current_user_employee();
    v_user_id   uuid;
    v_owner_emp uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT e.user_id INTO v_user_id FROM public.employees e WHERE e.id = NEW.employee_id;
        IF v_user_id IS NULL THEN
            RAISE EXCEPTION 'TASK_PARTICIPANT_NO_LOGIN|%', NEW.employee_id
              USING HINT = '这名员工还没有登录账号;先在 HR 里关联账号,再把他加进来';
        END IF;
        RETURN NEW;
    END IF;

    IF OLD.removed_at IS NULL AND NEW.removed_at IS NOT NULL THEN
        -- 【已搬】owner_id 就是员工 id,直接读,不再绕 employees.user_id。
        SELECT t.owner_id INTO v_owner_emp FROM public.tasks t WHERE t.id = NEW.task_id;

        IF NEW.employee_id = v_owner_emp THEN
            RAISE EXCEPTION 'TASK_OWNER_CANNOT_LEAVE|%', NEW.task_id
              USING HINT = '归属人不能退出自己的任务 —— 那是一次【转移归属】';
        END IF;

        IF NEW.employee_id IS DISTINCT FROM v_me THEN
            IF v_me IS DISTINCT FROM v_owner_emp AND v_me IS DISTINCT FROM OLD.added_by THEN
                RAISE EXCEPTION 'TASK_PARTICIPANT_REMOVE_DENIED|%', NEW.task_id
                  USING HINT = '只有归属人、或者当初加他进来的那个人,才能把他移出';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM public.task_participants p
                            WHERE p.task_id = NEW.task_id AND p.employee_id = v_me
                              AND p.removed_at IS NULL) THEN
                RAISE EXCEPTION 'TASK_PARTICIPANT_REMOVER_NOT_ON_TASK|%', NEW.task_id
                  USING HINT = '已经退出这张任务的人,不能再把别人移出';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

-- 【两个谓词 —— 这一对就是排序点本身】
-- 抬头说过:can_view_task 没有 deleted_at 过滤而 can_edit_task 有,异类是前者。
-- 本刀【不动】那一点,只把 owner 比较搬进员工空间。
CREATE OR REPLACE FUNCTION public.can_view_task(p_task_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT has_permission('module.tasks.view')
       AND EXISTS (
           SELECT 1 FROM public.tasks t
            WHERE t.id = p_task_id
              AND (
                    t.task_type = 'team'
                 OR t.owner_id = current_user_employee()   -- ← 1c-a:已在员工空间
                 OR has_permission('module.tasks.view_all')
              )
       );
$function$;

CREATE OR REPLACE FUNCTION public.can_edit_task(p_task_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT has_permission('module.tasks.edit')
       AND EXISTS (
           SELECT 1 FROM public.tasks t
            WHERE t.id = p_task_id
              AND t.deleted_at IS NULL
              AND CASE
                    WHEN t.task_type = 'team' THEN EXISTS (
                        SELECT 1 FROM public.task_participants p
                         WHERE p.task_id = t.id
                           AND p.employee_id = current_user_employee()
                           AND p.removed_at IS NULL)
                    ELSE t.owner_id = current_user_employee()   -- ← 1c-a:已在员工空间
                  END
       );
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- (d4 扩展) 一次性对账:团队任务、归属人可解析、却【零个活跃参与者】。
-- 顺序是承重的:它必须在 (a) 之后 —— 0002 与 0005 已被软删,只剩 0007。
-- ───────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_cnt   integer;
    v_codes text;
    r       record;
BEGIN
    SELECT count(*), string_agg(code, ', ' ORDER BY code) INTO v_cnt, v_codes
      FROM public.tasks t
     WHERE t.task_type = 'team'
       AND t.deleted_at IS NULL
       AND t.owner_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.task_participants p
                        WHERE p.task_id = t.id AND p.removed_at IS NULL);

    RAISE NOTICE '(d4 扩展) 团队任务但零活跃参与者:% 条 —— %', v_cnt, COALESCE(v_codes, '(无)');

    IF v_cnt <> 1 THEN
        RAISE EXCEPTION 'ABORT_D4|期待恰好 1 条(TASK-2026-0007),实际 % 条:%', v_cnt, COALESCE(v_codes, '(无)');
    END IF;

    FOR r IN SELECT t.id, t.code, t.owner_id FROM public.tasks t
              WHERE t.task_type = 'team' AND t.deleted_at IS NULL AND t.owner_id IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM public.task_participants p
                                 WHERE p.task_id = t.id AND p.removed_at IS NULL)
    LOOP
        PERFORM public.ensure_task_owner_participant(r.id, r.owner_id, r.owner_id);
        RAISE NOTICE '(d4 扩展) 已补:% 的归属人成为活跃参与者', r.code;
    END LOOP;
END $$;

-- ───────────────────────────────────────────────────────────────────────────
-- (e) 退役五列。COMMENT ON COLUMN 随列一起消失,不必单独 DROP。
--     【只有五列】:owner_id 不在其中 —— 它是被 (b)(c)(d) 转换、守卫、重接的那一列。
-- ───────────────────────────────────────────────────────────────────────────
ALTER TABLE public.tasks
    DROP COLUMN visibility,
    DROP COLUMN shared_with,
    DROP COLUMN editors,
    DROP COLUMN assigned_to,
    DROP COLUMN entity;

-- ───────────────────────────────────────────────────────────────────────────
-- (f) tasks 自己的四条策略,搬到两个谓词上。
--
-- 【INSERT 那一条【不能】用 can_edit_task —— 这是一处会静默炸掉建单的陷阱】
-- can_edit_task(p_task_id) 的问法是"你能不能改【这一行已经存在的】任务",
-- 它的函数体要 SELECT 那一行。而 INSERT 的 WITH CHECK 求值时,新行还没有对
-- 该命令的快照可见 —— 子查询取不到它,谓词恒假,**每一次建任务都会被拒**,
-- 而且拒得毫无道理可讲。所以 INSERT 保持 has_permission 这一问,原样不动:
-- "这一行归谁"由 owner_id 的默认值 current_user_employee() 回答,
-- 归属人解析不出来时由 (c) 的守卫按名拒绝 —— 两者都不需要读回自己。
-- ───────────────────────────────────────────────────────────────────────────
DROP POLICY "tasks select by permission" ON public.tasks;
DROP POLICY "tasks update by permission" ON public.tasks;
DROP POLICY "tasks delete by permission" ON public.tasks;

CREATE POLICY "tasks select by predicate" ON public.tasks
    FOR SELECT USING (public.can_view_task(id));

CREATE POLICY "tasks update by predicate" ON public.tasks
    FOR UPDATE USING (public.can_edit_task(id))
             WITH CHECK (public.can_edit_task(id));

CREATE POLICY "tasks delete by predicate" ON public.tasks
    FOR DELETE USING (public.can_edit_task(id));

-- ───────────────────────────────────────────────────────────────────────────
-- (g) 重建 task_board_rows。
-- 【security_invoker = on 必须原样保留】—— 这张视图的行过滤【就是】RLS 本身。
-- 丢掉它,视图对读者依旧工作得完美无缺,只是每一张任务对每一个持
-- module.tasks.view 的人都可见了,而且不报任何错(镜像文件抬头写着这一条)。
-- ───────────────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS public.task_board_rows;

CREATE VIEW public.task_board_rows
WITH (security_invoker = on) AS
SELECT
    t.id, t.code, t.title, t.status, t.priority, t.task_type,
    t.due_date, t.reminder_at, t.tags, t.owner_id,
    n.node_count,
    n.done_count,
    CASE WHEN t.due_date IS NULL OR n.max_node_date IS NULL THEN NULL
         ELSE n.max_node_date > t.due_date END AS steps_overrun_due_date
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
【security_invoker = on 是【有意】的,而它的 61 个邻居都是 off】:这张视图的行过滤【就是】RLS 本身。把它改成 off,视图对读者依旧工作得完美无缺 —— 只是每一张任务对每一个持 module.tasks.view 的人都可见了,而且不报任何错:这正是 OPS-14 那五处 xmodule 缺陷的签名。要改它之前,先想清楚谁来做行过滤。
【owner_id 自 TASK-1c-a 起是员工空间(employees.id)】,不再是 auth.uid();这里只投影它,不比较它。
注意 reloptions 里 security_invoker 可能写成 on 也可能写成 true —— 任何用 grep 找它的检查两种都要认(processing_metal_recovery 是本仓库唯一的 true)。';

COMMIT;
