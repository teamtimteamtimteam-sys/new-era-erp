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
import { useEffect, useRef, useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { moduleIdsForPath } from '@/lib/navTrail'
import type { NavModule, NavEntry } from './types'

export default function ModuleBar({ modules }: { modules: NavModule[] }) {
    const pathname = usePathname()
    const t = useTranslations()
    const [open, setOpen] = useState<string | null>(null)
    const [sheet, setSheet] = useState(false)
    const [expanded, setExpanded] = useState<string | null>(null)
    const barRef = useRef<HTMLDivElement>(null)

    // 【一个功能可以同属几个模块,所以高亮的可以是【两个】】站在 /output 上,
    // 运营与库存都该亮 —— 挑一个就是撒谎(见 lib/navTrail.moduleIdsForPath)。
    const activeIds = new Set(moduleIdsForPath(pathname))

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

    /** 二级(或第三级里的)一条。进不去的画成「名字 · 受限」,不是省略。 */
    const EntryRow = ({ e, indent = false }: { e: NavEntry; indent?: boolean }) => {
        const pad = indent ? 'pl-6' : 'pl-3'
        if (!e.allowed) {
            return (
                <span
                    data-module-restricted="1"
                    title={HINT}
                    className={`block ${pad} pr-3 py-1.5 text-sm text-[color:var(--brand-muted-glass)] cursor-default`}
                >
                    {t(e.key)} · {RESTRICTED}
                </span>
            )
        }
        const active = pathname === e.href || pathname.startsWith(e.href + '/')
        return (
            <Link
                href={e.href}
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
    const ModuleBody = ({ m, indent }: { m: NavModule; indent: boolean }) => {
        const grouped = new Set(m.groups.flatMap((g) => g.entries.map((e) => e.href)))
        const ungrouped = m.entries.filter((e) => !grouped.has(e.href))
        return (
            <>
                {m.groups.map((g) => (
                    <div key={g.key} className="mb-1">
                        {/* 第三级的组名。它【不是链接】—— 组是一个标题,不是一个去处。 */}
                        <p className="px-3 pt-2 pb-1 text-[11px] font-semibold uppercase tracking-wide text-[color:var(--brand-muted-glass)]">
                            {t(g.key)}
                        </p>
                        {g.entries.map((e) => (
                            <EntryRow key={e.href} e={e} indent={indent} />
                        ))}
                    </div>
                ))}
                {ungrouped.map((e) => (
                    <EntryRow key={e.href} e={e} />
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
                                    (activeIds.has(m.id)
                                        ? 'bg-[color:var(--brand-ocean-fill)] text-white'
                                        : 'text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]')
                                }
                            >
                                {t(m.key)}
                            </button>
                            {isOpen && (
                                /* 【浮层才磨砂】—— R2:表格永远不磨砂,理由见 app/globals.css。 */
                                <div
                                    className="nav-glass absolute left-0 top-full z-50 mt-1 max-h-[70vh] w-64 overflow-y-auto rounded-md border border-[color:var(--brand-border)] p-1 shadow-lg"
                                    role="menu"
                                >
                                    <ModuleBody m={m} indent={m.groups.length > 0} />
                                </div>
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
                <div className="sm:hidden fixed inset-0 z-50 flex flex-col" data-nav="sheet">
                    {/* 背板:点它就关。它不磨砂 —— 它是遮挡,不是玻璃。 */}
                    <button
                        type="button"
                        aria-label={t('common.close')}
                        onClick={() => setSheet(false)}
                        className="absolute inset-0 bg-black/30"
                    />
                    <div className="nav-glass relative mt-14 flex-1 overflow-y-auto rounded-t-xl border-t border-[color:var(--brand-border)] p-2 pb-24">
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
                                            (activeIds.has(m.id)
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
                                            <ModuleBody m={m} indent={m.groups.length > 0} />
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
                                className="block rounded px-3 py-2 text-sm text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]"
                            >
                                {t('nav.me')}
                            </Link>
                            <Link
                                href="/my-reviews"
                                className="block rounded px-3 py-2 text-sm text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]"
                            >
                                {t('nav.myReviews')}
                            </Link>
                        </div>
                    </div>
                </div>
            )}
        </>
    )
}
