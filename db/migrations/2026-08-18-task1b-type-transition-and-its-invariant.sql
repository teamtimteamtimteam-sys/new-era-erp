-- TASK-1b:类型迁移的两个具名转换 —— 以及它们守着的那条【隐式】不变式
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么这三样东西现在才来】
-- 它们本来在 1a 里,被拿掉了,理由记在 1a 的抬头:旧的 TaskModal 每次保存都把
-- task_type 一起发过来,一旦有人在【部署中的旧界面】上把私人改成团队,就会撞上
-- 新规则并把一串机器码印到屏幕上(IOD-2 的签名)。1a 因此保持纯加法。
-- 本刀同时上界面,所以触发器与看得懂它的那个界面是一起到的。
--
-- 【tasks.task_type 的列注释也在这一刀,不在 1a】
-- 那条注释说的是"出身由 task_type 自己承载,因为降级被做成了不可达" ——
-- 而在触发器落地之前,那句话是【假的】。一条描述"由触发器保证"的注释,
-- 在触发器还不存在时,与一条描述已经不存在的隐患一样坏:读的人照单全收。
--
-- 【判据取自 task_participants,不取自 task_history】
-- 退出是软的(置 removed_at,那一行留着),所以被【排空】的团队任务永远
-- 满足不了"除归属人外从来没有别人"。若判据写成"历史为零":
--   * 建表时那一条 participant_added 就让窗口【永远打不开】;
--   * 将来有人修剪了历史,窗口又会【重新打开】。
-- 一条建立在【某一行不存在】上的规则,两个方向都会坏。
--
-- 【SECURITY DEFINER,与 fu3 同一条理由】
-- 它要写 task_participants 与 task_history,而 task_history 只有 SELECT 策略
-- (留痕由触发器写,不由任何调用者写)。不是 definer 的话,升级这一步会以
-- "new row violates row-level security policy" 失败 —— fu3 就是这么被 fixture 抓到的。
--
-- 【owner_id 此刻仍是账号空间】。TASK-1c 搬它的时候,这个函数体里的两处
-- (v_owner_emp 的查法、以及降级判据里的 e.user_id)必须同刀改。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.trg_tasks_type_transition()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_owner_emp uuid;
    v_others    integer;
BEGIN
    IF NEW.task_type IS NOT DISTINCT FROM OLD.task_type THEN
        RETURN NEW;
    END IF;

    -- ── 升级:私人 → 团队。总是允许。
    IF OLD.task_type = 'personal' AND NEW.task_type = 'team' THEN
        SELECT e.id INTO v_owner_emp FROM public.employees e
         WHERE e.user_id = NEW.owner_id AND e.deleted_at IS NULL LIMIT 1;   -- ← 1c 改这里

        IF v_owner_emp IS NULL THEN
            RAISE EXCEPTION 'TASK_OWNER_NOT_AN_EMPLOYEE|%', NEW.code
              USING HINT = '这张任务的归属人没有对应的在册员工(或者没有登录账号);升级之后将没有任何人改得动它';
        END IF;

        -- 【同一个事务里】把归属人写成参与者。少了这一步,刚升级的任务参与者为零,
        -- 按 can_edit_task 那就是一张【谁都改不了】的行 —— 空集那个老毛病。
        INSERT INTO public.task_participants (task_id, employee_id, added_by)
        VALUES (NEW.id, v_owner_emp, v_owner_emp);

        -- 历史从升级这一刻开一条,让【之前的沉默】读得懂:
        -- 不是"没记",是"那时还不需要记"。
        INSERT INTO public.task_history (task_id, change_type, employee_id, changed_by)
        VALUES (NEW.id, 'promoted_from_personal', v_owner_emp, current_user_employee());

        RETURN NEW;
    END IF;

    -- ── 降级:团队 → 私人。只在【可证明无损】的窗口内允许。
    IF OLD.task_type = 'team' AND NEW.task_type = 'personal' THEN
        SELECT count(*) INTO v_others
          FROM public.task_participants p
          JOIN public.employees e ON e.id = p.employee_id
         WHERE p.task_id = NEW.id
           AND e.user_id IS DISTINCT FROM NEW.owner_id;                     -- ← 1c 改这里

        IF v_others > 0 THEN
            -- 【说的是不一致,不是政策】:不说"不许改类型",说的是
            -- "还有 N 个人在这件事上,他们的记录会被孤立"。
            RAISE EXCEPTION 'TASK_TYPE_LOCKED_PARTICIPANTS|%|%', NEW.code, v_others
              USING HINT = '这张任务上有别人参与过;改成私人会让他们读不到自己参与过的东西';
        END IF;
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'TASK_TYPE_TRANSITION_UNKNOWN|%|%', OLD.task_type, NEW.task_type;
END;
$$;

CREATE TRIGGER trg_tasks_type_transition
    BEFORE UPDATE OF task_type ON public.tasks
    FOR EACH ROW EXECUTE FUNCTION trg_tasks_type_transition();

-- 两扇门。守卫在【触发器】上,所以这两个函数只是把意图说清楚,
-- 不是安全边界 —— 任何调用路径(包括 PostgREST 直接 UPDATE)都要过同一道守卫。
CREATE OR REPLACE FUNCTION public.promote_task_to_team(p_task_id uuid)
RETURNS void
LANGUAGE sql
AS $$
    UPDATE public.tasks SET task_type = 'team' WHERE id = p_task_id;
$$;

CREATE OR REPLACE FUNCTION public.correct_task_type(p_task_id uuid)
RETURNS void
LANGUAGE sql
AS $$
    UPDATE public.tasks SET task_type = 'personal' WHERE id = p_task_id;
$$;

COMMENT ON FUNCTION public.promote_task_to_team(uuid) IS
'私人 → 团队。归属人在同一个事务里成为参与者,并写下一条 promoted_from_personal —— 那一条的用处是让【升级之前的沉默】读得懂:不是没记,是那时还不需要记。升级之前的编辑没有历史,也不会被补写(编出来的记录比没有记录更坏)。';

COMMENT ON FUNCTION public.correct_task_type(uuid) IS
'把【建的时候选错了类型】的团队任务改回私人。它不是"降级"——参与者【离开】永远不会产生一张私人任务:判据取自 task_participants,而退出是软的,那一行留着。两个转换分开命名,是为了拒绝的时候说得出撞的是哪一条;合成一个的话,那句拒绝只能含混地说"不许改类型",而那是一句政策,不是一处不一致。';

COMMENT ON COLUMN public.tasks.task_type IS
'personal / team。**它同时承载【出身】** —— task_type = ''personal'' 蕴含"这张任务从来不曾真正是团队任务",而这一点【只因为】唯一的降级路径被 trg_tasks_type_transition 做成了可证明无损的(除归属人外从来没有别人留过参与者行)。
【谁加了第二条降级路径,谁就悄悄毁掉了隐私规则】,而且什么都不会报错:一张有过五个人的团队任务会变成一张私人任务,那五个人从此读不到自己参与过的记录。所以这里没有 was_ever_team 列 —— 一个事实两处陈述必然漂移 —— 代价是这条不变式是隐式的,只有这段注释和触发器抬头说得出它。
参与者【离开】永远不会产生私人任务:判据取自 task_participants(退出是软的,行还在),不取自 task_history(它可能被修剪)。';

COMMIT;
