-- db/migrations/2026-09-02-chart0-the-dock-can-be-put-away-and-that-choice-is-the-persons-own.sql
-- CHART-0 ④ · Tim:dock 在桌面上改成【左边一条竖栏】,手机上仍是底栏,两边都可以收起。
-- ★ 而收起这件事【必须跟着人走】★ ——「If someone collapses it, it must not reappear
--   at the next sign-in — the same reason the dock's contents follow the person rather
--   than the device.」所以它和 hrefs 存在同一行上,不进 cookie、不进 localStorage。
--
-- ══════════════════════════════════════════════════════════════════════════════
-- ★★【本迁移的重点【不是】那一列 boolean,而是它逼出来的一个二义】★★
-- ══════════════════════════════════════════════════════════════════════════════
-- user_dock 靠【行在不在】区分三种状态(见那张表的抬头):
--     没有这一行         = 从来没动过 dock  → 画默认
--     行在、hrefs 为空数组 = 本人清空了      → 就画空的
--     行在、hrefs 非空     = 画这些
-- 而 hrefs 此前是 `NOT NULL DEFAULT '{}'`。于是【只要为了记一个 collapsed 就得建行】,
-- 那一行的 hrefs 会拿到默认值 '{}' —— 也就是「本人清空了」。
--
--   一个人只是把 dock 收起来,系统就会在下一次渲染时认为他【把 dock 清空了】,
--   于是他展开之后看到的是一条空栏,而他自己排的那几项【再也回不来】。
--
-- 这不是理论上的:app/components/nav/dockActions.ts 的 readDock 写的是
-- `(data?.hrefs) ?? null`,拿到 '{}' 就是 [],resolveDock 对 [] 的答案正是"就画空的"。
-- **一个 boolean 列会静默地吃掉别人的 dock。**
--
-- 修法:把 hrefs 改成【可空】,并去掉它的默认值。于是
--     hrefs IS NULL  = 从来没动过（新的表达方式,不再依赖"行在不在"）
--     hrefs = '{}'   = 本人清空了
-- 三态从"行在不在 + 数组空不空"变成【只看 hrefs 一列】,而 collapsed 与它正交。
-- 已有的行不需要改:它们的 '{}' 本来就是"清空了",含义一个字没变。
--
-- 【连带的一处代码改动,写在这里免得两边对不上】resetDock 此前是 DELETE 整行;
-- 现在改成 `UPDATE ... SET hrefs = NULL`,否则"恢复默认 dock"会顺手把这个人
-- 收起/展开的选择也一并抹掉 —— 那是两件事,不该互相牵连。
-- ══════════════════════════════════════════════════════════════════════════════

BEGIN;

ALTER TABLE public.user_dock ALTER COLUMN hrefs DROP DEFAULT;
ALTER TABLE public.user_dock ALTER COLUMN hrefs DROP NOT NULL;

ALTER TABLE public.user_dock
    ADD COLUMN collapsed boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.user_dock.hrefs IS
    'dock 项的路由地址，按显示顺序。★ 三态全部落在这一列上（CHART-0 ④ 之后）★ NULL = 从来没动过（画按权限的默认）；空数组 = 本人刻意清空了（就画空的，不要补回默认）；非空 = 画这些。【为什么必须可空】collapsed 一列让"为了记一个偏好而建行"成为常态，而 hrefs 若仍是 NOT NULL DEFAULT ''{}''，那一行就会把"没动过"静默地变成"清空了"，吃掉这个人自己排的 dock。';

COMMENT ON COLUMN public.user_dock.collapsed IS
    'CHART-0 ④：这个人有没有把 dock 收起来。【跟着人走，不跟着设备走】——与 hrefs 同一条理由（Tim：收起来之后下次登录不该又冒出来）。桌面上"收起"= 一条图标宽的竖栏，不是消失；手机上 = 底栏只剩一条把手。与 hrefs 正交：收起来不改变里面有什么。';

COMMENT ON TABLE public.user_dock IS
    'IA-BUILD-1：每个人自己的 dock（顶栏之外的快捷层，Tim 的 D1）。一人一行；hrefs 的顺序就是 dock 上的顺序。【三种状态要分得开】CHART-0 ④ 起三态全在 hrefs 一列上：NULL = 从没动过（画角色默认）；空数组 = 本人清空了（就画空的）；非空 = 画这些。存的是地址不是权限——可见性每次渲染重新问注册表（lib/modules.ts），所以一条后来变得进不去的项会显示成「受限」而不是一个能点的谎。collapsed 与 hrefs 正交，记的是收起/展开，同样跟着人走。';

COMMIT;
