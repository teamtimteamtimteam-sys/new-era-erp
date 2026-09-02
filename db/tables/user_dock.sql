-- db/tables/user_dock.sql
-- IA-BUILD-1:每个人自己的 dock —— 顶栏之外的那一层快捷方式(Tim 的 D1 后半)。
--
-- NOTE: introduced by db/migrations/2026-09-02-iabuild1-the-dock-is-personal-so-it-must-follow-the-person.sql.
-- First-run script (plain CREATEs).
--
-- ★【一人一行 + 一个数组,因为要分得开三种状态】★
--     hrefs IS NULL     = 这个人【从来没有动过】dock  → 画按角色的默认
--     hrefs = '{}'      = 这个人【把它清空了】        → 就画空的
--     hrefs 非空         = 画这些
-- 一人多行表达不了中间那一种:零行既是"没动过"也是"清空了"。
-- **"缺席 ≠ 空"是这个仓库反复付账的那条区别**,这里从模式层面就把它分开。
--
-- ★【CHART-0 ④:三态从"行在不在"挪到了 hrefs 这一列上,而那不是洁癖】★
-- collapsed 一列让"为了记一个偏好而建行"成为常态。hrefs 若仍是
-- NOT NULL DEFAULT '{}',那一行会把"没动过"静默地变成"清空了" ——
-- 一个人只是把 dock 收起来,他自己排的那几项就再也回不来。
-- 见 db/migrations/2026-09-02-chart0-the-dock-can-be-put-away-….sql。
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
    hrefs      text[],
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    collapsed  boolean NOT NULL DEFAULT false
);

COMMENT ON TABLE public.user_dock IS
    'IA-BUILD-1：每个人自己的 dock（顶栏之外的快捷层，Tim 的 D1）。一人一行；hrefs 的顺序就是 dock 上的顺序。【三种状态要分得开】CHART-0 ④ 起三态全在 hrefs 一列上：NULL = 从没动过（画角色默认）；空数组 = 本人清空了（就画空的）；非空 = 画这些。存的是地址不是权限——可见性每次渲染重新问注册表（lib/modules.ts），所以一条后来变得进不去的项会显示成「受限」而不是一个能点的谎。collapsed 与 hrefs 正交，记的是收起/展开，同样跟着人走。';

COMMENT ON COLUMN public.user_dock.hrefs IS
    'dock 项的路由地址，按显示顺序。★ 三态全部落在这一列上（CHART-0 ④ 之后）★ NULL = 从来没动过（画按权限的默认）；空数组 = 本人刻意清空了（就画空的，不要补回默认）；非空 = 画这些。【为什么必须可空】collapsed 一列让"为了记一个偏好而建行"成为常态，而 hrefs 若仍是 NOT NULL DEFAULT ''{}''，那一行就会把"没动过"静默地变成"清空了"，吃掉这个人自己排的 dock。';

COMMENT ON COLUMN public.user_dock.collapsed IS
    'CHART-0 ④：这个人有没有把 dock 收起来。【跟着人走，不跟着设备走】——与 hrefs 同一条理由（Tim：收起来之后下次登录不该又冒出来）。桌面上"收起"= 一条图标宽的竖栏，不是消失；手机上 = 底栏只剩一条把手。与 hrefs 正交：收起来不改变里面有什么。';

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
