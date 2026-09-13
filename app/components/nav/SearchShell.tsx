'use client'

// app/components/nav/SearchShell.tsx
// ════════════════════════════════════════════════════════════════════════════
// 顶栏那个搜索框 —— ★ SEARCH-1 之后它【真的能搜】,而这个文件只剩两件事 ★
// ════════════════════════════════════════════════════════════════════════════
//
// 【这个文件今天负责什么】
//   ① **在首页让位**(UI-1c ③)—— 首页自己有一个大框,一页上同一件事不说两遍;
//   ② **给共享面板一套顶栏尺寸的 class**。
//   面板本身、匹配、权限、措辞,全部住在 `app/components/search/SearchEntry.tsx`
//   —— **一个面板,两个入口**(Tim 的 S1)。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【它此前是一个 <details>,而那个判断在它那个年代【是对的】】★★
// ════════════════════════════════════════════════════════════════════════════
//   UI-1a 写下的理由逐字是:**一个长得像输入框的东西,六个人上线第一天就会往里
//   打字、按回车 —— 然后什么都不发生。那正是 FIX-2a 花一整刀清掉的形状:
//   一处缺席被渲染成一个答案。**
//   ☞ **那条推理没有被推翻,是它的前提没了**:搜索建起来了,所以一个接了字的框
//     不再是一句谎。`home.searchNotYetBadge` 与 `home.searchNotYet` 两个键
//     因此在这一刀里【删掉】—— 留着一句写着「搜索还没有建」的文案,
//     下一个读到它的人会据此断定这件事还没做。
//   ★ 而 `home.searchPrompt` 【留着,而且仍然是两个入口共用的那一句】 ——
//     「同一个意思的第二套说法,就是下一次漂移的种子」这句话没有过期,
//     这一刀只是把它兑现在了一个真的共享组件上。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【CONFIRM-1(2026-09-06)那条【仍然有效】,而且这一刀重量过它】★★
// ════════════════════════════════════════════════════════════════════════════
//   这个组件住在【根布局】里,而 App Router 在客户端软导航时不重画根布局。
//   CONFIRM-1 因此把「这是哪一页」的求值从 `headers()` 换成了 `usePathname()`
//   —— `headers()` 一个会话求值一次,`usePathname()` 每次软导航都重新求值。
//
//   ★【SEARCH-1 开工时重量了那一条,而读数与委托书写的【不一样】】★
//     委托书说「硬导航 present=true,软导航 not in DOM」(那是 CONFIRM-1 当天的
//     读数,也写在 AGENTS.md 里)。**实测:`scripts/probe-search-shell.mjs`
//     在 HEAD 上七格全绿,`PROBEBEFORE_EXIT=0`** ——
//     `S3b.soft-nav-visible` 报的是 `present=true visible=true box=200x32`。
//     ☞ 也就是说 **SearchShell 这一半在 CONFIRM-1 那一刀里就修好了**;
//       今天还开着的是它的【孪生】:根布局那个 `bare` 布尔
//       (`docs/known-issues.md` 的 `CONFIRM-1-ROOT-LAYOUT-HEADER`)。
//       那一条由 `app/components/AppChrome.tsx` + `check-nav-routes` 判据 ⑦ 治,
//       两者都是 SEARCH-1 的活。
//     ★ 这是 AGENTS.md「委托书里的【数】来自上一份报告,而不是来自一次测量」
//       那一条的又一例 —— **一个正确诞生的读数,安静地过期了。**
//
// ── ★ 顺手修掉的一处:两个 hook 的顺序 ──────────────────────────────────────
//   此前是 `usePathname()` → 首页提前 `return null` → `useTranslations()`。
//   而 `useTranslations()` 里有一句 `useContext` —— **它是一个 hook**,
//   于是从 `/` 软导航到 `/me` 时,同一个实例的 hook 数从 1 变成 2。
//   ☞ 探针今天是绿的,所以这**不是**一处观察到的故障;它是一处
//     **rules-of-hooks 违例**,而这一刀正好要重写这个组件。
//     现在两个 hook 都在任何提前返回之前调用。
import { usePathname } from 'next/navigation'
import SearchEntry from '@/app/components/search/SearchEntry'

/** 首页 —— 那一页自己有大搜索框(app/page.tsx),顶栏这一格因此让位。 */
const HOME_PATH = '/'

export default function SearchShell() {
    // ★ hook 一律在提前返回【之前】调用 —— 见抬头最后那一段。
    const pathname = usePathname() ?? ''
    if (pathname === HOME_PATH) return null

    return (
        <SearchEntry
            variant="nav"
            // ★★【`hidden md:block` 一个字都没动 —— Tim 的 S3 明说接受它】★★
            //   768px 以下顶栏这一格不画,于是**手机上进搜索只有首页那一条路**。
            //   这是一处**有名字的限制**,不是一处缺陷:
            //   `scripts/probe-search-shell.mjs` 的 S4 格与
            //   `scripts/probe-nav-geometry.mjs` 的 N8/N9/N10 三格一起钉着它。
            //   ☞ 下一次走查读到这里:**不要把它记成缺陷**,也不要顺手加一个手机入口
            //     —— 那是一件独立的活。
            // ★ 记号与改前【逐字相同】—— probe-search-shell.mjs 全靠它认这一格。
            markers={{ 'data-nav': 'search-shell' }}
            wrapperClassName="relative hidden md:block"
            // ★【尺寸由入口给,不由面板给】★ 这一串与改前那个 <summary> 上的
            //   **逐字相同**(只去掉了 `list-none` 与 `[&::-webkit-details-marker]:hidden`
            //   那两个只对 <summary> 有意义的类)。于是顶栏这一格的渲染几何不变,
            //   而版式普查那一边的差额只剩"真的变了的那几样"。
            triggerClassName="flex h-8 w-[200px] cursor-pointer items-center gap-2 rounded-full border border-[color:var(--brand-border)] px-3 text-sm text-[color:var(--brand-muted-glass)] hover:bg-[color:var(--brand-accent)]"
            glyphClassName="h-4 w-4 shrink-0"
            promptClassName="truncate"
        />
    )
}
