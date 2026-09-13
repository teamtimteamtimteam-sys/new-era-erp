'use client'

// app/components/AppChrome.tsx
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-1 · S4 —— 修 `CONFIRM-1-ROOT-LAYOUT-HEADER`
// ════════════════════════════════════════════════════════════════════════════
//
// 【被修的那条缺陷,一句话】`app/layout.tsx` 从 `x-pathname` 这个请求头算出
//   `bare = isBareChromePath(pathname)`,而 **App Router 在客户端软导航时
//   不重画根布局**。于是那个布尔在【本次会话第一次硬导航】那一刻求值一次,
//   然后跟着这个人走遍整个系统。
//   登记在 `docs/known-issues.md` 的 `CONFIRM-1-ROOT-LAYOUT-HEADER`(CONFIRM-1
//   实测,Tim 裁定排队)。同一条结构此前在 `SearchShell` 上【真的坏在生产上】过。
//
// ── ★ 它今天为什么还没坏,以及这一刀怎么让它【不可能】坏 ────────────────────
//   实测(SEARCH-1 开工时,全树):指向 bare 路径(`/login` `/set-password`
//   `/verify/cod`)的 `<Link href>` **0 处**、`router.push` **0 处**。
//   人走到那几页靠的全是【硬导航】:中间件重定向、表单提交、登出 action。
//   ☞ 所以那个布尔今天每次都是在对的那一刻算的 ——
//     **它离坏只差一个 `<Link href="/login">`**(known-issues 的原话)。
//
//   本刀两道一起做,而它们治的不是同一半:
//     ① **这个组件** —— 把"现在这一页要不要外壳"的求值【搬到客户端】,
//        用 `usePathname()`。它每一次软导航都重新求值。
//        ☞ 治的是【走进 bare 路径时外壳还跟着】那一半。
//     ② **`scripts/check-nav-routes.mjs` 的判据 ⑤** —— 任何 `<Link>` /
//        `router.push` 指向 bare 路径都变红。
//        ☞ 治的是【从 bare 路径软导航出去时外壳回不来】那一半 ——
//          而这一半 ① 【治不了】:服务端那一刻没画外壳,客户端就没有外壳可显。
//
// ★★【说白:为什么不把外壳【无条件】交给服务端,让这个组件自己决定显不显】★★
//   那样两个方向一次治完,而代价是:`/login` 与 `/set-password` 上,
//   `<TopNav />` 会被服务端【照样渲染一遍】(它作为 children 传进来,
//   RSC 会先把它算出来),于是那两页要多跑一次权限查询、一次档案查询、
//   一次未读数查询,而渲染出来的那段导航会进 RSC 载荷 —— 只是不显示。
//   `/set-password` 上那个人【是登录着的】,所以那不是一段空载荷。
//   ☞ **LOGIN-1-fu1 要的是"结构性地排除",不是"画出来再藏起来"。**
//     所以服务端那一侧的判断留着,这个组件是它的第二道,而不是替代。
//
// ── ★ 那个 `data-app-chrome` 是给量具的,不是装饰 ──────────────────────────
//   它的值就是【这一次求值用的那条路径】。于是"这个判断有没有跟着人走"
//   从此是一件可以【读出来】的事:
//       改前:硬进 / 与点着走到 /me,两次都读不到这个属性 ——
//             根布局根本不记录它是按哪条路径判的,**因为它只判过一次**;
//       改后:硬进 / → "/";点着走到 /me → "/me"。**判断跟着人走了。**
//   判据钉在 `scripts/probe-nav-geometry.mjs` 的 N5/N6 两格上。
//
// ── `display: contents` 不是随手写的 ────────────────────────────────────────
//   `<body>` 是 `min-h-full flex flex-col`,而顶栏 / 面包屑 / 告知区
//   今天各自是它的一个 flex 子项。套一个普通的 `<div>` 会把三个合成【一个】子项
//   —— 那是一次实打实的版式改动,而它会落在每一页上。
//   `display: contents` 让这个盒子自己不生成框,三个子项仍然直接归 `<body>` 排 ——
//   ☞ 这条由 `scripts/probe-nav-geometry.mjs` 在两个视口上量过顶栏的盒子来兜底,
//     不靠"我认为它不会变"。
import { usePathname } from 'next/navigation'
import { isBareChromePath } from '@/lib/loginRoute'

export default function AppChrome({ children }: { children: React.ReactNode }) {
    // 判据【一个字没改】—— 仍然是 isBareChromePath,仍然是 lib/loginRoute.ts 那一份。
    // 改的是【谁来问】:`headers()` 一个会话求值一次,`usePathname()` 每次软导航都问。
    const pathname = usePathname() ?? ''
    if (isBareChromePath(pathname)) return null
    return (
        <div className="contents" data-app-chrome={pathname}>
            {children}
        </div>
    )
}
