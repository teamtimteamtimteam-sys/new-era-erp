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
// ★【HOME_PATH 与 lib/loginRoute.ts 的 LANDING_PATH 【今天是同一个字符串,
//   而它们不是同一件事】】★ 后者答的是「登录之后落在哪一页」,前者答的是
//   「哪一页自己有一个大搜索框,所以顶栏不必再放一个」。UI-1b 刚把落点从 /me
//   改成 /,那两个问题恰好撞在一起;把它们绑成一个常量,下一次改落点就会顺手
//   改掉一件与落点无关的事。**FIX-1 为 isPublicPath / isBareChromePath 立过
//   同一条:两个问题,两个名字。**
import { headers } from 'next/headers'
import { getTranslations } from '@/lib/i18n/server'

/** 首页 —— 那一页自己有大搜索框(app/page.tsx),顶栏这一格因此让位。 */
const HOME_PATH = '/'

export default async function SearchShell() {
    // 【中间件没设这个头时按"不是首页"处理】—— 那时画出这一格,最坏的后果是
    // 首页上多一个诚实标着「尚未启用」的框,而漏画的后果是【每一页都没有搜索入口】。
    // 两种失败不对称,所以默认值倒向后者不会发生的那一侧。
    const pathname = (await headers()).get('x-pathname') ?? ''
    if (pathname === HOME_PATH) return null

    const t = await getTranslations()
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
