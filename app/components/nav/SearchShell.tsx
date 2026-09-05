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
import { getTranslations } from '@/lib/i18n/server'

export default async function SearchShell() {
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
