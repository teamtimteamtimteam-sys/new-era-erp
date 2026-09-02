-- db/tables/user_dock.sql
-- IA-BUILD-1:每个人自己的 dock —— 顶栏之外的那一层快捷方式(Tim 的 D1 后半)。
--
-- NOTE: introduced by db/migrations/2026-09-02-iabuild1-the-dock-is-personal-so-it-must-follow-the-person.sql.
-- First-run script (plain CREATEs).
--
-- ★【一人一行 + 一个数组,因为要分得开三种状态】★
--     没有这一行        = 这个人【从来没有动过】dock  → 画按角色的默认
--     有这一行、数组为空 = 这个人【把它清空了】        → 就画空的
--     有这一行、数组非空 = 画这些
-- 一人多行表达不了中间那一种:零行既是"没动过"也是"清空了"。
-- **"缺席 ≠ 空"是这个仓库反复付账的那条区别**,这里从模式层面就把它分开。
--
-- 【FK 指向 auth.users】删掉一个人,他的 dock 跟着走(与 employees.user_id 同形)。
-- 据此建行的 fixture 必须先有 auth.users 行。
--
-- 【没有 _masked 伴生视图,这是判断不是遗漏】这张表没有任何一列被从 authenticated
-- 手里收回 —— 它存的是路由地址,而地址在顶栏上人人看得见(D5)。
--
-- 【存地址,不存权限】可见性每次渲染重新问注册表 —— 见 app/components/nav/Dock.tsx。

CREATE TABLE public.user_dock (
    user_id    uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
    hrefs      text[] NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.user_dock IS
    'IA-BUILD-1:每个人自己的 dock（顶栏之外的快捷层，Tim 的 D1）。一人一行；hrefs 的顺序就是 dock 上的顺序。【三种状态要分得开】没有行 = 从没动过（画角色默认）；行在而数组为空 = 本人清空了（就画空的）；非空 = 画这些。存的是地址不是权限——可见性每次渲染重新问注册表（lib/modules.ts），所以一条后来变得进不去的项会显示成「受限」而不是一个能点的谎。';

COMMENT ON COLUMN public.user_dock.hrefs IS
    'dock 项的路由地址，按显示顺序。空数组 = 本人刻意清空，与「没有这一行」不是一回事。';

ALTER TABLE public.user_dock ENABLE ROW LEVEL SECURITY;

-- 【四条策略都锁在 user_id = auth.uid()】—— 一条 dock 是这个人自己的东西,
-- 别人读它没有任何正当理由,管理员也一样。这与 notification_reads 同形。
CREATE POLICY "user_dock select own"
    ON public.user_dock
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (user_id = auth.uid());

CREATE POLICY "user_dock insert own"
    ON public.user_dock
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "user_dock update own"
    ON public.user_dock
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "user_dock delete own"
    ON public.user_dock
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (user_id = auth.uid());
