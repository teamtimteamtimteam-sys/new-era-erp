-- db/migrations/2026-09-02-iabuild1-the-dock-is-personal-so-it-must-follow-the-person.sql
-- IA-BUILD-1 · Tim 的 D1 后半:除了共享且固定的顶栏,每个人还有一条【自己的】dock。
--
-- ★【为什么是一张表,而不是 cookie / localStorage】★
-- 这一条是 Tim 在 grilling 里裁定的(A5)。系统里已有的唯一一项偏好是【语言】,
-- 它存在 cookie 里 —— 那是【每台设备一份】,不是每个人一份。而 Tim 在手机上
-- 和在桌面上用的是同一套 dock:一条不跟着人走的 dock,与他要的不是同一个功能。
--
-- ★【为什么是"一人一行 + 一个数组",而不是"一人多行"】★
-- 因为这张表必须分得开【三种】状态,而不是两种:
--     没有这一行        = 这个人【从来没有动过】dock  → 画按角色的默认(Tim 的 4c)
--     有这一行、数组为空 = 这个人【把它清空了】        → 就画空的,不要"好心"补回默认
--     有这一行、数组非空 = 就画这些
-- 一人多行的形状表达不了中间那一种:零行既是"没动过"也是"清空了"。
-- **而"缺席 ≠ 空"正是这个仓库反复付账的那条区别**(lib/permissions.ts 的
-- null 两义、moduleGuard 的"进不去的空 ≠ 真的空"),这里从模式层面就把它分开。
-- 顺序由数组下标给,不需要一列 position,也就不会有两行 position 相同这种状态。
--
-- ★【FK 指向 auth.users,ON DELETE CASCADE】★
-- 删掉一个人,他的 dock 跟着走。employees.user_id 已有同形的 FK(EXEC-2),
-- 所以这不是本仓库的新做法。**注意:据此建 dock 行的 fixture 必须先有 auth.users 行。**
--
-- ★【没有 _masked 伴生视图,而这是【判断】不是遗漏】★
-- 这张表里没有任何一列是被从 authenticated 手里收回的:它存的是一串路由地址,
-- 而那些地址在顶栏上人人都看得见(D5:进不去的模块照样显示,只是标着「受限」)。
-- 没有被收回的列,就没有 _masked 视图要建,列级授权也无从谈起。
--
-- ★【dock 里存的是地址,不是权限】★ 权限【每次渲染都重新问注册表】——
-- 见 app/components/nav/Dock.tsx 的抬头(Tim 的 4b)。一条今天可点的 dock 项
-- 明天可能变成「受限」,而那必须在渲染的时刻算,不能在存的时刻算。

BEGIN;

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

COMMIT;
