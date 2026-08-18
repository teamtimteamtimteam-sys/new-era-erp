-- db/tables/tasks.sql
-- Tasks module — table + code trigger + updated_at trigger + RLS.
-- Conventions match existing tables (suppliers/customers/processing_runs/...):
--   * code auto-generated 'TASK-YYYY-NNNN' by BEFORE INSERT trigger (dynamic year, 4-digit LPAD)
--   * soft delete via deleted_at
--   * audit fields created_by/updated_by default auth.uid(), created_at/updated_at default now()
--   * updated_at auto-bumped by the shared update_updated_at() function
--   * RLS: authenticated-only full access (Week-2 hardening)
--
-- NOTE: This is a first-run script (plain CREATEs). Re-running requires dropping
-- the objects first. Run in the Supabase SQL Editor.

-- 1. Code sequence (plain, no per-year reset — matches supplier_code_seq etc.)
CREATE SEQUENCE public.task_code_seq;

-- 2. Table
CREATE TABLE public.tasks (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code          text NOT NULL,
    title         text NOT NULL,
    description   text,
    status        text NOT NULL DEFAULT 'todo'
                      CHECK (status IN ('todo', 'in_progress', 'done')),
    priority      text NOT NULL DEFAULT 'medium'
                      CHECK (priority IN ('high', 'medium', 'low')),
    due_date      date,
    reminder_at   timestamptz,
    tags          text[] DEFAULT '{}',
    task_type     text NOT NULL DEFAULT 'personal'
                      CHECK (task_type IN ('personal', 'team')),
    visibility    text NOT NULL DEFAULT 'private'
                      CHECK (visibility IN ('private', 'shared', 'team')),
    shared_with   uuid[] DEFAULT '{}',
    editors       uuid[] DEFAULT '{}',
    owner_id      uuid DEFAULT auth.uid(),
    assigned_to   uuid,
    entity        text,
    created_by    uuid DEFAULT auth.uid(),
    updated_by    uuid DEFAULT auth.uid(),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz
);

-- 3. Code-generation function (same shape as generate_supplier_code; TASK- prefix,
--    task_code_seq; LANGUAGE plpgsql, NOT security definer; only fills a null/empty code)
CREATE OR REPLACE FUNCTION public.generate_task_code()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := 'TASK-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('task_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

-- 4. BEFORE INSERT trigger -> code generation
CREATE TRIGGER trg_generate_task_code
    BEFORE INSERT ON public.tasks
    FOR EACH ROW
    EXECUTE FUNCTION generate_task_code();

-- 5. BEFORE UPDATE trigger -> reuse the existing shared update_updated_at() (do NOT redefine it)
CREATE TRIGGER trg_tasks_updated_at
    BEFORE UPDATE ON public.tasks
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- 6. RLS: authenticated-only full access (matches suppliers' policy)
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tasks select by permission"
    ON public.tasks
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.tasks.view'::text));

CREATE POLICY "tasks insert by permission"
    ON public.tasks
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.tasks.edit'::text));

CREATE POLICY "tasks update by permission"
    ON public.tasks
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.tasks.edit'::text)) WITH CHECK (has_permission('module.tasks.edit'::text));

CREATE POLICY "tasks delete by permission"
    ON public.tasks
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.tasks.edit'::text));

-- 7. Deferred-enforcement note.
-- The visibility / shared_with / editors columns are structural placeholders for a
-- future multi-user permission model. They are NOT enforced yet: the RLS policy above
-- grants any authenticated user full access. Tightening to per-user / visibility-based
-- access (e.g. created_by = auth.uid() OR auth.uid() = ANY(shared_with) OR ...) is
-- DEFERRED until the user system exists.
COMMENT ON COLUMN public.tasks.visibility IS
    'Reserved for future multi-user model; NOT enforced yet (RLS currently allows all authenticated users).';
COMMENT ON COLUMN public.tasks.shared_with IS
    'Reserved: users who may view. NOT enforced until the user system exists.';
COMMENT ON COLUMN public.tasks.editors IS
    'Reserved: users granted edit permission by the creator. NOT enforced until the user system exists.';
COMMENT ON COLUMN public.tasks.owner_id IS
    'Ownership (transferable), distinct from created_by (audit, immutable). Defaults to creator; reserved for the future permission model.';

-- ═══ TASK-1a ═══════════════════════════════════════════════════════════════
-- 硬删按名拒绝。【DELETE 策略保留】(与 inbound_batches / purchase_orders 同处理,
-- 不同于 AUDEL-1a 对盘点两张表的做法):策略一旦拿掉,RLS 会先把行过滤掉,
-- 触发器根本轮不到,普通用户看到的是【0 行】而不是那句具名拒绝 ——
-- 而任务是一块人天天点的屏幕,静默的 0 行会被读成"删掉了"。
CREATE TRIGGER trg_tasks_no_hard_delete
    BEFORE DELETE ON public.tasks
    FOR EACH ROW EXECUTE FUNCTION trg_tasks_no_hard_delete();

-- 表头改动进 task_history —— 【只给团队任务】。私人任务不留痕:
-- 一个人不需要一份关于自己的审计。
CREATE TRIGGER trg_tasks_history
    AFTER UPDATE ON public.tasks
    FOR EACH ROW EXECUTE FUNCTION trg_tasks_history();

-- ═══ TASK-1b ═══════════════════════════════════════════════════════════════
-- 类型迁移的守卫。【它在触发器上而不是在两扇门里】,所以任何调用路径
-- (包括 PostgREST 直接 UPDATE)都绕不过去 —— 而"出身由 task_type 自己承载"
-- 这条不变式,靠的正是这一点。
CREATE TRIGGER trg_tasks_type_transition
    BEFORE UPDATE OF task_type ON public.tasks
    FOR EACH ROW EXECUTE FUNCTION trg_tasks_type_transition();

COMMENT ON COLUMN public.tasks.task_type IS
'personal / team。**它同时承载【出身】** —— task_type = ''personal'' 蕴含"这张任务从来不曾真正是团队任务",而这一点【只因为】唯一的降级路径被 trg_tasks_type_transition 做成了可证明无损的(除归属人外从来没有别人留过参与者行)。
【谁加了第二条降级路径,谁就悄悄毁掉了隐私规则】,而且什么都不会报错:一张有过五个人的团队任务会变成一张私人任务,那五个人从此读不到自己参与过的记录。所以这里没有 was_ever_team 列 —— 一个事实两处陈述必然漂移 —— 代价是这条不变式是隐式的,只有这段注释和触发器抬头说得出它。
参与者【离开】永远不会产生私人任务:判据取自 task_participants(退出是软的,行还在),不取自 task_history(它可能被修剪)。';
