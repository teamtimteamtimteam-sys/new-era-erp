'use client'

// app/components/nav/ModuleBar.tsx
// ════════════════════════════════════════════════════════════════════════════
// 【九个一级模块。桌面是一条顶栏,手机是一张全高的抽屉 —— 而这不是"响应式"】
// ════════════════════════════════════════════════════════════════════════════
// Tim 的 D1:九个一级横在顶上,二级从模块展开,**只有财务有第三级**。
//
// ★【手机为什么是另一种形态,而不是把桌面那条压窄】★(Tim 的 A3)
// IA-BUILD-1 在稳定别名上实测过【今天】那条顶栏在 390px 上的样子:
//     admin      21 项,内容宽 1834px,**不横向滚动就只够到 4 项**
//     warehouse  19 项,内容宽 2337px,**不横向滚动就只够到 2 项**
// 注意第二行:**权限最少的角色,顶栏反而最长** —— 因为「· 受限」把标签撑长了。
// 于是一个仓库工在手机上打开系统,最先看见的两样东西【都是他打不开的】。
// 那不是"待优化",那是今天的状态。九个模块加二级只会更长,所以手机拿到的是
// **一个菜单按钮 + 一张全高抽屉**:同一份注册表、同一份判据、同一句「受限」,
// 换一种画法,不是换一个尺寸。
//
// ★【进不去的模块照样画出来,画成一条具名的限制】★(Tim 的 D5 / NAV-REG-1 R4)
// 措辞沿用既有的那一套:common.restricted +（提示）dashboard.restrictedHint,
// 与首页牌子上那两行逐字相同。同一个意思的第二套说法,就是下一次漂移的种子。
// data-module-restricted 是给按角色可达性检查用的【机器标记】—— 认文案字符串
// 去分辨"受限项",漏过一次就是一次误报。
//
// ★【模块名是【展开二级的按钮】,不是链接】★(Tim 的 D2)
// 不做模块目录页 —— 顶栏本身就是目录。可导航的地址【全部】是二级条目,包括
// 模块自己的落地页(财务的试算平衡 = /finance)。这也顺手解决了「设置」根本
// 没有 app/settings/page.tsx 这件事:它不需要有。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useCallback, useEffect, useRef, useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { activeModuleForPath, entryForPath } from '@/lib/navTrail'
import type { NavModule, NavEntry } from './types'

/**
 * ★【CHART-0 ③:一条被截断的菜单必须【自己说】它还有下文】★
 * ────────────────────────────────────────────────────────────────────────────
 * Tim 以为财务没有应付账款那一段 —— 它在,只是在下面,而他不知道菜单能滚。
 * 实测(稳定别名,admin,1440×900):财务菜单 1227px 内容装在 628px 里,
 * **599px 在视野之外,而屏幕上没有任何东西说这件事。**
 *
 * ★【为什么不能只靠滚动条】★ 第一版就是只靠它,而实测证明那不够:
 * macOS 的滚动条是【覆盖式】的,不滚就不显示 —— 量到的宽度是 0px。
 * globals.css 里的 ::-webkit-scrollbar 把 Chrome/Safari 掰回常驻式,
 * 但 Firefox 掰不动。**一个只在某些浏览器上出现的信号,不是一个信号。**
 * 所以真正的判据是这一条:我们【自己画】一行字,它不看操作系统的脸色。
 *
 * 【它说的是条数,不是"往下滚"】"还有 4 条"与"下面还有内容"是两句话:
 * 前者可核对,后者只是一个手势。条数是数出来的 —— 数【完全在视野外】的那些,
 * 半露的那一条不算(它已经在说自己存在了)。
 * 【滚到底就消失】—— 一条永远挂着的"还有"会变成背景噪音,而它此刻是【假的】。
 */
function useMoreBelow(ref: React.RefObject<HTMLDivElement | null>, deps: unknown[]) {
    const [more, setMore] = useState(0)
    const measure = useCallback(() => {
        const el = ref.current
        if (!el) return
        // 【数的是完全落在视野外的条目】—— 逐个量,不按平均行高估算:
        // 分组标题、缩进项与普通项的高度并不相同,估算会给出一个对不上的数字。
        const bottom = el.scrollTop + el.clientHeight
        let n = 0
        for (const row of el.querySelectorAll<HTMLElement>('[data-menu-row]')) {
            if (row.offsetTop >= bottom) n++
        }
        setMore(n)
    }, [ref])
    useEffect(() => {
        measure()
        const el = ref.current
        if (!el) return
        el.addEventListener('scroll', measure, { passive: true })
        const ro = new ResizeObserver(measure)
        ro.observe(el)
        return () => { el.removeEventListener('scroll', measure); ro.disconnect() }
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [measure, ...deps])
    return more
}

/** 菜单底下那条【贴着底边】的提示。它在滚动容器【之内】,所以它跟着菜单走。 */
function MoreBelow({ n, label }: { n: number; label: string }) {
    if (n <= 0) return null
    return (
        <p
            data-menu-more={n}
            aria-hidden
            className="sticky bottom-0 -mx-1 -mb-1 mt-1 border-t border-[color:var(--brand-border)] bg-[color:var(--brand-accent)] px-3 py-1 text-[11px] font-medium text-[color:var(--brand-text)]"
        >
            {label}
        </p>
    )
}

/**
 * 一个【会滚动的菜单面板】+ 它自己那条「还有 N 条」。
 * 桌面的下拉与手机的抽屉共用它 —— 两处是同一个缺陷,不该有两份修法。
 */
function ScrollPanel({
    className, role, moreLabel, children,
}: {
    className: string
    role?: string
    moreLabel: (n: number) => string
    children: React.ReactNode
}) {
    const ref = useRef<HTMLDivElement>(null)
    const more = useMoreBelow(ref, [children])
    return (
        <div ref={ref} className={className} role={role}>
            {children}
            <MoreBelow n={more} label={moreLabel(more)} />
        </div>
    )
}

export default function ModuleBar({ modules }: { modules: NavModule[] }) {
    const pathname = usePathname()
    const t = useTranslations()
    const [open, setOpen] = useState<string | null>(null)
    const [sheet, setSheet] = useState(false)
    const [expanded, setExpanded] = useState<string | null>(null)
    const barRef = useRef<HTMLDivElement>(null)

    // ★★【NAV-CLEANUP-1 ⑤:一级高亮只有【一个】答案,而它必须是【进得去】的那个】★★
    // 判据整条住在 lib/navTrail.activeModuleForPath —— 面包屑调的是同一支。
    // 这里从前是 `new Set(moduleIdsForPath(pathname))`(全部属主一起亮)。
    const canEnter = (id: string) => modules.find((m) => m.id === id)?.allowed ?? false
    const active = activeModuleForPath(pathname, canEnter)
    // 【矛盾要报出来,不能静默地不亮】—— 打开了这一页却一个属主模块都进不去,
    // 说明注册表与守卫对不上。data 属性让冒烟/走查抓得到,console 让开发看得到。
    useEffect(() => {
        if (active.id === null) {
            console.error(`[nav] 无法判定当前模块:${pathname} 的属主一个都进不去 —— 注册表与守卫不一致`)
        }
    }, [active.id, pathname])

    // ★【二级高亮:最长前缀,所以也只有一个答案】★
    // 此前每一行各自算 `pathname === href || startsWith(href + '/')`,于是站在
    // /inventory/locations 上,「现况」(/inventory)与「库位」同时亮。
    // entryForPath 本来就是【最长前缀】的实现(面包屑一直在用它)——
    // 这里改成问它要那【一条】,而不是让每一行自己判断。
    // ★ 顺带记一件事:被本刀删掉的 app/inventory/Subnav.tsx 【做对了】这件事
    //   (它显式地把 /inventory 排到最后判)。正确的实现一直在树里,
    //   只是没有长在菜单上。 ★
    const activeEntryHref = entryForPath(pathname)?.href ?? null

    // 路由一变就把菜单收起来 —— 否则点完一项,菜单还挂在新页面上。
    useEffect(() => {
        setOpen(null)
        setSheet(false)
    }, [pathname])

    // Esc 关闭 + 点外面关闭。【键盘要能出得来】,不然打开的菜单是一个陷阱。
    useEffect(() => {
        const onKey = (e: KeyboardEvent) => {
            if (e.key === 'Escape') {
                setOpen(null)
                setSheet(false)
            }
        }
        const onDown = (e: MouseEvent) => {
            if (barRef.current && !barRef.current.contains(e.target as Node)) setOpen(null)
        }
        document.addEventListener('keydown', onKey)
        document.addEventListener('mousedown', onDown)
        return () => {
            document.removeEventListener('keydown', onKey)
            document.removeEventListener('mousedown', onDown)
        }
    }, [])

    const RESTRICTED = t('common.restricted')
    const HINT = t('dashboard.restrictedHint')

    /**
     * 二级(或第三级里的)一条。进不去的画成「名字 · 受限」,不是省略。
     *
     * ★★【CONV-6 ⑦:`indent` 这个 prop 删了 —— 每一行都在同一条左边线上】★★
     * 【症状(Tim 的走查,2026-09-04)】财务下拉里,组标题(报表 / 分录 / 应收…)
     *   看上去比它底下的条目【更靠左】,于是条目读起来像"被推右了",
     *   而不是像那个标题的孩子。
     * 【实测的三个左边距,这才是症结】组标题 `px-3` = 12px;组内条目
     *   `pl-6` = 24px;而**没有落进任何一组的条目** `pl-3` = 12px。
     *   也就是说【同一张菜单里条目有两条左边线】—— 财务的 Overview 在 12px,
     *   「试算平衡」在 24px。缩进本来是要表达层级的,可它表达出来的是不齐。
     * 【为什么现在才看得见】NAV-CLEANUP-1 ③ 把无组条目挪到了分组【前面】,
     *   于是那条 12px 的线排在最上面,与 24px 的差直接对上了眼。
     *   ★ 委托书猜的是"CONV-0 改的分组渲染" —— 查过了,**不是**:
     *     `git log -S indent -- app/components/nav/ModuleBar.tsx` 只有一处,
     *     IA-BUILD-1(c500045)。CONV-0 一行没碰它。★
     * 【修法:层级由【字体】表达,不由缩进表达】组标题本来就是 11px、大写、
     *   加粗、灰的 —— 那已经足够把它读成标题。再加一层缩进是用两种手段说同一件事,
     *   而两种手段一旦不一致(这里就是),读到的是矛盾而不是层级。
     *   这也是下拉菜单的通行画法(组标题与条目同一条左边线)。
     */
    const EntryRow = ({ e }: { e: NavEntry }) => {
        const pad = 'pl-3'
        if (!e.allowed) {
            return (
                <span
                    data-menu-row=""
                    data-module-restricted="1"
                    title={HINT}
                    className={`block ${pad} pr-3 py-1.5 text-sm text-[color:var(--brand-muted-glass)] cursor-default`}
                >
                    {t(e.key)} · {RESTRICTED}
                </span>
            )
        }
        const active = e.href === activeEntryHref
        return (
            <Link
                href={e.href}
                data-menu-row=""
                className={
                    `block ${pad} pr-3 py-1.5 text-sm rounded ` +
                    (active
                        ? 'bg-[color:var(--brand-ocean-fill)] text-white'
                        : 'text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]')
                }
            >
                {t(e.key)}
            </Link>
        )
    }

    /**
     * 一个模块名下的全部内容。**只有财务的 groups 非空,那就是第三级。**
     *
     * ★【兜底:分了组也不许有条目消失】★ 分组渲染之后,把【没有落进任何一组的】
     * 条目照样画在后面。这条兜底是为一个实测过的缺陷加的:此前分组分支
     * 【只画分组里的】,于是物流因为名下有一条带 group 的跨属主条目(运费)
     * 就走了分组分支,它自己那三条(货代/航线/货柜)整批不见了 ——
     * 一处缺席,而没有任何东西说出来。真正的修法在 lib/moduleAccess.ts
     * (只给财务算分组);这一条是第二道网,因为同一个形状不该只有一道防线。
     */
    const ModuleBody = ({ m }: { m: NavModule }) => {
        const grouped = new Set(m.groups.flatMap((g) => g.entries.map((e) => e.href)))
        const ungrouped = m.entries.filter((e) => !grouped.has(e.href))
        return (
            <>
                {/* ★【NAV-CLEANUP-1 ③:没落进任何一组的条目现在画在分组【前面】】★
                    从前它们画在后面(那时它只是一张兜底的网,顺序无所谓)。
                    本刀给财务加了一条【没有 group 的落地页】—— 一个 Overview 属于
                    菜单的最上面,不是六个组之后的角落。把它塞进「报表」组是另一种
                    错:它不是一张报表。**兜底的作用一个字没变**,只是位置对了。 */}
                {ungrouped.map((e) => (
                    <EntryRow key={e.href} e={e} />
                ))}
                {m.groups.map((g) => (
                    <div key={g.key} className="mb-1">
                        {/* 第三级的组名。它【不是链接】—— 组是一个标题,不是一个去处。 */}
                        <p className="px-3 pt-2 pb-1 text-[11px] font-semibold uppercase tracking-wide text-[color:var(--brand-muted-glass)]">
                            {t(g.key)}
                        </p>
                        {g.entries.map((e) => (
                            <EntryRow key={e.href} e={e} />
                        ))}
                    </div>
                ))}
            </>
        )
    }

    return (
        <>
            {/* ══ 桌面(≥640px):九个模块横排,点开二级 ══════════════════════ */}
            <div ref={barRef} className="hidden sm:flex items-center gap-0.5 px-4 pb-1.5" data-nav="modules">
                {modules.map((m) => {
                    if (!m.allowed) {
                        return (
                            <span
                                key={m.id}
                                data-module-restricted="1"
                                title={HINT}
                                className="whitespace-nowrap rounded px-3 py-1.5 text-sm text-[color:var(--brand-muted-glass)] cursor-default"
                            >
                                {t(m.key)} · {RESTRICTED}
                            </span>
                        )
                    }
                    const isOpen = open === m.id
                    return (
                        <div key={m.id} className="relative">
                            <button
                                type="button"
                                aria-expanded={isOpen}
                                aria-haspopup="true"
                                onClick={() => setOpen(isOpen ? null : m.id)}
                                className={
                                    'whitespace-nowrap rounded px-3 py-1.5 text-sm ' +
                                    (active.id === m.id
                                        ? 'bg-[color:var(--brand-ocean-fill)] text-white'
                                        : 'text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]')
                                }
                            >
                                {t(m.key)}
                            </button>
                            {isOpen && (
                                /* 【浮层才磨砂】—— R2:表格永远不磨砂,理由见 app/globals.css。 */
                                /* 【menu-scroll:一条【一直画着的】滚动条】(CHART-0 ③)
                                   财务这一条实测 scrollHeight 1227px / 可视 628px ——
                                   599px 在视野外,而 macOS 的覆盖式滚动条不滚就不显示,
                                   于是一条被截断的菜单读起来是一份完整的清单。
                                   理由与另外两个候选(渐隐、"还有 N 条"文字)的取舍
                                   写在 app/globals.css 的 .menu-scroll 抬头。 */
                                <ScrollPanel
                                    className="nav-glass menu-scroll absolute left-0 top-full z-50 mt-1 max-h-[70vh] w-64 overflow-y-auto rounded-md border border-[color:var(--brand-border)] p-1 shadow-lg"
                                    role="menu"
                                    moreLabel={(n) => t('nav.menuMoreBelow', { n })}
                                >
                                    <ModuleBody m={m} />
                                </ScrollPanel>
                            )}
                        </div>
                    )
                })}
            </div>

            {/* ══ 手机(<640px):一个按钮 + 一张全高抽屉 ═════════════════════ */}
            <div className="sm:hidden px-4 pb-1.5">
                <button
                    type="button"
                    aria-expanded={sheet}
                    onClick={() => setSheet(!sheet)}
                    data-nav="menu-button"
                    className="w-full rounded border border-[color:var(--brand-border)] px-3 py-2 text-left text-sm text-[color:var(--brand-text)]"
                >
                    {t('nav.menu')}
                </button>
            </div>
            {sheet && (
                /* ★【`fixed inset-0` 现在真的对着视口了】★(CHART-0 ①)
                   在 CHART-0 之前顶栏自己带着 backdrop-filter,而带 backdrop-filter
                   的元素是 fixed 后代的【包含块】—— 抽屉是顶栏的后代,于是它对齐的
                   是顶栏。实测(稳定别名,390×844):**抽屉 94px 高、面板 105px 高,
                   里面 583px 内容** —— 九个模块挤在一条缝里,而 IA-BUILD-1 的抬头
                   写的是"一张全高的抽屉"。玻璃挪到 .nav-glass-underlay 之后,
                   顶栏不再是包含块,这一行才开始表达它一直在说的意思。 */
                <div className="sm:hidden fixed inset-0 z-50 flex flex-col" data-nav="sheet">
                    {/* 背板:点它就关。它不磨砂 —— 它是遮挡,不是玻璃。 */}
                    <button
                        type="button"
                        aria-label={t('common.close')}
                        onClick={() => setSheet(false)}
                        className="absolute inset-0 bg-black/30"
                    />
                    <ScrollPanel
                        className="nav-glass menu-scroll relative mt-14 flex-1 overflow-y-auto rounded-t-xl border-t border-[color:var(--brand-border)] p-2 pb-24"
                        moreLabel={(n) => t('nav.menuMoreBelow', { n })}
                    >
                        {modules.map((m) => {
                            if (!m.allowed) {
                                return (
                                    <div
                                        key={m.id}
                                        data-module-restricted="1"
                                        title={HINT}
                                        className="px-3 py-2.5 text-sm text-[color:var(--brand-muted-glass)]"
                                    >
                                        {t(m.key)} · {RESTRICTED}
                                    </div>
                                )
                            }
                            const isOpen = expanded === m.id
                            return (
                                <div key={m.id} className="border-b border-[color:var(--brand-border)] last:border-0">
                                    <button
                                        type="button"
                                        aria-expanded={isOpen}
                                        onClick={() => setExpanded(isOpen ? null : m.id)}
                                        className={
                                            'flex w-full items-center justify-between px-3 py-2.5 text-left text-sm ' +
                                            (active.id === m.id
                                                ? 'font-semibold text-[color:var(--brand-text)] underline underline-offset-4'
                                                : 'text-[color:var(--brand-text)]')
                                        }
                                    >
                                        {t(m.key)}
                                        <span aria-hidden className="text-[color:var(--brand-muted-glass)]">
                                            {isOpen ? '−' : '+'}
                                        </span>
                                    </button>
                                    {isOpen && (
                                        <div className="pb-2">
                                            <ModuleBody m={m} />
                                        </div>
                                    )}
                                </div>
                            )
                        })}

                        {/* ★【关于你】—— 手机上顶栏放不下,所以它们在这里 ★
                            /me 与 /my-reviews 【刻意不属于九个模块】(勘察 U4:
                            挂进 /hr 等于对非 HR 的部门经理隐身)。但"不属于模块"
                            不等于"手机上就没有" —— 它们只是换了地方。
                            这一段存在的理由与 4d 是同一条,只是方向相反:
                            **顶栏挪走什么,抽屉就得接住什么。** */}
                        <div className="mt-2 border-t border-[color:var(--brand-border)] pt-2">
                            <p className="px-3 pb-1 text-[11px] font-semibold uppercase tracking-wide text-[color:var(--brand-muted-glass)]">
                                {t('nav.aboutYou')}
                            </p>
                            <Link
                                href="/me"
                                data-menu-row=""
                                className="block rounded px-3 py-2 text-sm text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]"
                            >
                                {t('nav.me')}
                            </Link>
                            <Link
                                href="/my-reviews"
                                data-menu-row=""
                                className="block rounded px-3 py-2 text-sm text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]"
                            >
                                {t('nav.myReviews')}
                            </Link>
                        </div>
                    </ScrollPanel>
                </div>
            )}
        </>
    )
}
