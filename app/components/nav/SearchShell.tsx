'use client'

// app/components/nav/SearchShell.tsx
// ════════════════════════════════════════════════════════════════════════════
// UI-1a ①:顶栏上那个小搜索框 —— 一个【外壳】,而它不许假装能用
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【它是 <details>/<summary>,【不是】 <input> —— 这是本刀最要紧的一处判断】★★
//
// 【为什么】搜索的行为属于 A 刀,这一刀只做形状。而一个长得像输入框的东西,
// 六个人上线第一天就会往里打字、按回车 —— 然后什么都不发生。
// **那正是 FIX-2a 花一整刀清掉的形状:一处缺席被渲染成一个答案。**
// 一个吞掉回车的输入框说的是"我搜过了,没有结果",而事实是"搜索还没建"。
//
// 【这不是新发明的做法 —— 首页早就这么做了】app/page.tsx 的搜索外壳用的正是
// <details>/<summary>,理由逐字相同,而且【本组件复用它那两句文案】:
//   home.searchPrompt      —— 点之前就说一次
//   home.searchNotYetBadge —— 徽标上那一句
//   home.searchNotYet      —— 点开之后完整的一句「还没建」,不是「出错了」
// **同一个意思的第二套说法,就是下一次漂移的种子** —— 所以一个新键都没铸。
//
// 【为什么样式不复用 home.module.css】那一份是给一张【近乎空白的落地页】画的:
// 大圆角、柔和投影、慢慢动的活性指示。顶栏这一格高 32px、宽 200px,
// 与两个圆按钮并排。**复用的是机制与文案,不是尺寸。**
//
// 【实测的宽度预算】UI-1a 探针,六个角色 × 1280/1440:七条模块条最宽 528.7px,
// 加上字标 115.5px 与右侧两个圆按钮,1280 上仍余 276px。
// **所以这一格【不需要】折叠成放大镜** —— Tim 的裁定:不要造一个没有触发条件的机制。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【UI-1c ③:它在【首页】上不画 —— 规矩一直是这样,UI-1a 无条件画了】★★
// ════════════════════════════════════════════════════════════════════════════
//
// 【症状,Tim 在生产上看到的】首页因此有【两个】搜索框:它存在的理由 —— 那个大的
// (app/page.tsx),和顶栏里这个小的。两个都点得开,两个说的是同一句「尚未启用」。
// 一页上同一件还没建的东西说两遍,读起来像它有两种不同的搜索。
//
// 【机制:x-pathname,而它【已经存在】—— 本刀不新造第二种问法】
//   服务端组件拿不到当前路径(没有那个 API),所以中间件把它放进请求头
//   (lib/supabase/middleware.ts:160),根布局据此决定画不画应用外壳
//   (app/layout.tsx:68)。**这里读的是同一个头。**
//   ★ 为什么这一条要紧 ★:同一个问题的第二种问法,正是 lib/loginRoute.ts 那两个
//     谓词、那两份写死的 /suppliers 的来路。这个仓库为它付过两次账。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【CONFIRM-1(2026-09-06):上面那套 x-pathname 的读法【坏了】,坏法值得读完】★★
// ════════════════════════════════════════════════════════════════════════════
//
// 【症状】Tim 在生产上看到的是「哪一页都不画」—— 桌面、满屏、每一个角色。
// 而上面写的规矩是「只有首页不画」。
//
// 【机制,一句话】**这个组件住在【根布局】里,而 App Router 在客户端软导航时
// 不重画根布局。** UI-1b 把登录落点从 /me 改成了 `/`(lib/loginRoute.ts:148),
// 于是每一个人进系统的第一跳都落在首页,根布局那一次求值得到 `null` ——
// 然后他点着 <Link> 走遍整个系统,而**那个 null 跟着他一整个会话**。
//
// ★【为什么没有任何检查抓到它】★ COPY-1 报过「/ → 0 · 别的页 → 1 each」,
//   而那是真的、是绿的:**一次脚本 fetch 是【硬导航】,根布局当场重画。**
//   两边都没有撒谎 —— 那条判据量的那个状态,【人从来不会到达】。
//   实测,同一个会话、同一个宽度、同一条路由,唯一的变量是【怎么到达】:
//       硬导航 /me → present=true  visible=true  box=200x32
//       软导航 /me → present=false visible=false "not in DOM at all"
//   判据现在钉在 scripts/probe-search-shell.mjs 上(S3b 就是那一格)。
//
// 【修的是【谁来问】,不是【问什么】】HOME_PATH 与那条规矩一个字都没改 ——
// 换掉的只是求值时机:`headers()` 一个会话求值一次,`usePathname()` 每次软导航
// 都重新求值。Tim 裁定不走"每一页自己排除首页"那条路:**一条要每一页记得
// 履行的义务会漂**,而那正是他拒绝两套确认习惯的同一条理由。
//
// 【这一步的代价,量过了才写在这里】'use client' 【不等于】不在服务端渲染 ——
// 客户端组件照样出现在首屏 HTML 里,`usePathname()` 在 SSR 期就返回对的路径。
// 所以首屏不闪、不跳版:probe 的 S5/S6 两格量的就是这件事(SSR 的 HTML 里
// 非首页有这一格、首页没有)。真正失去的只有"服务端组件"这个身份本身,
// 而它本来就不取任何数据 —— 读的只有路径,与两句已经在客户端可用的文案。
//
// ★【打包体积的增量:【刻意没有量】,而这不是疏忽】★(Tim 在 CONFIRM-1 裁定)
//   它现在会进客户端包,而进去的东西是:一个 <details>、一个行内 SVG、两句文案。
//   **这个数无论是多少,都改变不了任何一个决定** —— 而量它要花一次构建。
//   本仓库那条「写下来的成本必须是量过的成本」管的是【会被拿来做决定】的数;
//   一个不会进入任何决定的数,正确的处置是【说清楚没量,以及为什么】,
//   而不是量一个没人会用的数字,也不是假装它不存在。
// ════════════════════════════════════════════════════════════════════════════
//
// ★【HOME_PATH 与 lib/loginRoute.ts 的 LANDING_PATH 【今天是同一个字符串,
//   而它们不是同一件事】】★ 后者答的是「登录之后落在哪一页」,前者答的是
//   「哪一页自己有一个大搜索框,所以顶栏不必再放一个」。UI-1b 刚把落点从 /me
//   改成 /,那两个问题恰好撞在一起;把它们绑成一个常量,下一次改落点就会顺手
//   改掉一件与落点无关的事。**FIX-1 为 isPublicPath / isBareChromePath 立过
//   同一条:两个问题,两个名字。**
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

/** 首页 —— 那一页自己有大搜索框(app/page.tsx),顶栏这一格因此让位。 */
const HOME_PATH = '/'

export default function SearchShell() {
    // ★ 判据【一个字没改】,改的是【谁来问】—— 见上面 CONFIRM-1 那一段。
    //   usePathname() 在每一次软导航上重新求值,而 headers() 一个会话只求值一次。
    const pathname = usePathname() ?? ''
    if (pathname === HOME_PATH) return null

    const t = useTranslations()
    return (
        <details className="relative hidden md:block" data-nav="search-shell">
            <summary
                className="flex h-8 w-[200px] cursor-pointer list-none items-center gap-2 rounded-full border border-[color:var(--brand-border)] px-3 text-sm text-[color:var(--brand-muted-glass)] hover:bg-[color:var(--brand-accent)] [&::-webkit-details-marker]:hidden"
                data-nav="search-summary"
            >
                {/* 放大镜是【这个控件自己的形状】,与"下拉里不要图标"那条无关 ——
                    那条说的是两张下拉菜单的行内容。这里没有它,这一格就只是一个空框。 */}
                <svg
                    viewBox="0 0 20 20"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="1.6"
                    aria-hidden="true"
                    className="h-4 w-4 shrink-0"
                >
                    <circle cx="8.75" cy="8.75" r="5.25" />
                    <path d="M12.6 12.6 L16.5 16.5" strokeLinecap="round" />
                </svg>
                <span className="truncate">{t('home.searchPrompt')}</span>
            </summary>
            {/* 【点之后说完整的一句】—— 说的是"还没建",不是"出错了"。 */}
            <p
                data-nav="search-note"
                className="nav-glass absolute right-0 top-full z-50 mt-1 w-64 rounded-md border border-[color:var(--brand-border)] p-3 text-xs text-[color:var(--brand-text)] shadow-lg"
            >
                {t('home.searchNotYet')}
            </p>
        </details>
    )
}
