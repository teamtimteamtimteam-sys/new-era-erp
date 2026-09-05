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
import { usePathname } from 'next/navigation'
import { useCallback, useEffect, useRef, useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { activeModuleForPath, entryForPath } from '@/lib/navTrail'
import { BAR_MODULE_IDS, SETTINGS_MODULE_ID, TOOLS_MODULE_ID } from '@/lib/modules'
import {
    ScrollPanel, menuPanelClass, useMenuDismiss, MenuEntryRow, MenuSectionLabel,
} from './MenuPanel'
import type { NavModule } from './types'

// ★★【UI-1a:useMoreBelow / MoreBelow / ScrollPanel 搬去了 ./MenuPanel.tsx】★★
// 它们原样住在这里,连注释一起 —— 本刀把它们搬出去,因为工具下拉与头像下拉
// 要用的正是同一套画法,而它们够不到一个组件文件内部的局部定义。
// **搬家没有改任何行为**;改的只是"谁能用它"。理由整段写在 MenuPanel.tsx 抬头。

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
    // ★★【UI-1c ④:这条守卫【收窄】了 —— 它此前对着正确行为在喊】★★
    // ────────────────────────────────────────────────────────────────────────
    // 【它此前喊什么】`active.id === null` 就喊。而那个 null 有两种意思,
    //   activeModuleForPath 此前把它们塞进同一个形状(整段推理写在 lib/navTrail.ts):
    //     · 注册表里【没有条目认领这条路由】—— / 、/me 、/notifications……
    //       **这是合法的**,那些页本来就不属于九个模块中的任何一个;
    //     · 有属主、读者却一个都进不去 —— **这一个才是矛盾。**
    // 【为什么现在非改不可】UI-1b 把登录落点换成了 /,于是六个人【每天早上第一屏】
    //   都会收到这条警报。IA §21.1 ② 早就给这个形状写过名字:
    //   **「一条永远在喊的警报,等于没有警报。」**
    // ★【收窄,不是消音】★ reason === 'contradiction' 照喊,一个字没弱;
    //   变的只是它不再把"没有属主"当成"属主进不去"。
    //   实测:今天有 7 条会渲染顶栏的无属主路由(/ · /me · /my-reviews ·
    //   /my-reviews/[id] · /notifications · /welcome · /brand-sampler),
    //   本刀之前它们【每一条】都在喊。
    // 【谁负责发现"本该有条目却没有"】check-nav-routes 判据②,在【构建期】。
    //   构建期答过的问题,运行时不必再答一遍。
    useEffect(() => {
        if (active.id === null && active.reason === 'contradiction') {
            console.error(`[nav] 无法判定当前模块:${pathname} 的属主一个都进不去 —— 注册表与守卫不一致`)
        }
    }, [active, pathname])

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
    // 【UI-1a:这段实现搬去了 ./MenuPanel.tsx】工具与头像两个下拉要的是同一件事,
    // 而抄第二、第三遍最先漂走的就是 Esc 那一条 —— 漏掉它,菜单只能用鼠标关。
    const closeAll = useCallback(() => { setOpen(null); setSheet(false) }, [])
    useMenuDismiss(barRef, closeAll)

    const RESTRICTED = t('common.restricted')
    const HINT = t('dashboard.restrictedHint')

    // ★【UI-1a ③:桌面那一行只画七条;`modules` 仍然是【九条】】★
    // 过滤【只发生在这里】,而且只对桌面那一行。理由整段写在 lib/modules.ts 的
    // BAR_MODULE_IDS 抬头:MODULES 是"哪条路由归谁所有"的真源,改窄它会弄死
    // 8 条深路由的面包屑、在 /tools/* 与 /settings/* 上喊一场假警报,
    // 并且【把手机上工具与设置仅有的那扇门拆掉】。
    // ★★【UI-1c:手机抽屉现在遍历【同样这七条】,不再是九条】★★
    //   工具与设置没有从抽屉里消失 —— 它们变成了抽屉底下两个【具名的区】
    //   (见下面 sheet 那一段)。「顶栏挪走什么,抽屉就得接住什么」照旧成立,
    //   接住的方式从"混在模块里的第八、第九行"换成了"两个有标题的区"。
    // ★ canEnter 读的仍然是【九条】—— 活动模块判定不受任何一次过滤影响,
    //   /tools/* 与 /settings/* 的高亮与面包屑因此一个字没变。
    const barModules = modules.filter((m) => BAR_MODULE_IDS.includes(m.id))

    /**
     * 手机抽屉里那两个具名区(工具 / 设置)的条目。
     * **同一个 `modules` 数组,同一个 allowed** —— 不是第二份清单。
     * 桌面上这两份分别由 ToolsMenu 与头像下拉的设置子菜单画,而它们拿到的
     * 也是这同一个数组里的同两条(见 TopNav)。
     */
    const sectionEntries = (id: string) => modules.find((m) => m.id === id)?.entries ?? []

    // ★★【UI-1c:`EntryRow` 搬去了 MenuPanel.tsx,改名 MenuEntryRow】★★
    // 【搬家没有改任何行为】进不去画「名字 · 受限」、data-module-restricted 记号、
    //   title 提示、当前页高亮 —— 逐字不变,连同下面这两段理由一起搬了过去。
    // 【为什么搬】ToolsMenu 里有一份逐字相同的,而本刀还要在【三个新地方】用它
    //   (手机抽屉的工具区与设置区、头像下拉的设置子菜单)。**2 份变 1 份,
    //   而不是变成 4 份。**
    //
    // 【搬过去的那两段理由,在这里留一句索引,免得下一个人以为它们没了】
    //   ① CONV-6 ⑦:`indent` 那个 prop 删了 —— 组标题与条目在【同一条左边线】上,
    //      层级由字体表达,不由缩进表达(实测过三条互不相同的左边距 12/24/12px);
    //   ② D5:进不去的照画成一条【具名的限制】,不是一处缺席。

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
                    <MenuEntryRow key={e.href} entry={e} activeHref={activeEntryHref} />
                ))}
                {m.groups.map((g) => (
                    <div key={g.key} className="mb-1">
                        {/* 第三级的组名。它【不是链接】—— 组是一个标题,不是一个去处。 */}
                        <MenuSectionLabel>{t(g.key)}</MenuSectionLabel>
                        {g.entries.map((e) => (
                            <MenuEntryRow key={e.href} entry={e} activeHref={activeEntryHref} />
                        ))}
                    </div>
                ))}
            </>
        )
    }

    return (
        <>
            {/* ══ 桌面(≥640px):七个模块横排,点开二级 ══════════════════════ */}
            {/* ★【UI-1a:padding 没了 —— 这一行现在是顶栏那【一行】里的一段】★
                从前它是顶栏底下【第二行】,所以自带 px-4 pb-1.5。合成一行之后,
                左右内距由 TopNav 那个 px-4 sm:px-6 的容器统一给,这里再给一次
                就会把七个模块往右推 16px,并且让它与左边的字标对不齐。 */}
            <div ref={barRef} className="hidden sm:flex items-center gap-0.5 min-w-0" data-nav="modules">
                {barModules.map((m) => {
                    const isOpen = open === m.id
                    // ★★【UI-1a ⑦(b):进不去的模块【照画,不加后缀】】★★
                    // ────────────────────────────────────────────────────────
                    // 【从前是什么】`名字 · 受限`,而且渲染成一个点不动的 <span>。
                    // 【为什么改】实测(UI-1a 探针,六个角色 ×1280/1440):那个后缀
                    //   把每个人的模块条撑成【不同的长度】—— 七条时 528.7px 到
                    //   755.1px,差 226px。**而最长的那一条属于权限最少的人**
                    //   (warehouse / operations 各有三条「· 受限」)。
                    //   那个倒置本身就是论据:权限越少,顶栏越长。
                    //   去掉后缀之后,六个角色【全部】是 528.7px。
                    // 【Tim 的两条标准都指向这一版】
                    //   ·「没有全部权限不代表不能了解全部功能」—— 七条一条不少,
                    //     所以【不能】隐藏(那是被否掉的 (c));
                    //   · FIX-2a:「一次缺席不许被渲染成一个答案」—— 这里没有缺席。
                    // ★【点开之后【更具体】,不是更少】★ 委托书原话是"点击给出既有的
                    //   拒绝页"——**没有那个页,按 D2 也不该有**(模块不是地址,
                    //   「设置」根本没有 app/settings/page.tsx)。这一版做的是:
                    //   照常展开它的二级,而里面【每一行】本来就写着「名字 · 受限」。
                    //   于是他读到的不是"销售进不去",是**销售底下哪几件事进不去**。
                    //   一次点击换来更细的答案,而且【一行新代码都不需要】。
                    // ★【记号、提示与灰度都留着】★ data-module-restricted 是给可达性
                    //   检查用的【机器标记】—— 认文案去分辨受限项,漏一次就是一次误报;
                    //   丢掉它会让那些检查瞎掉。title 与灰字让人【点之前】就看得出来。
                    const restricted = !m.allowed
                    return (
                        <div key={m.id} className="relative">
                            <button
                                type="button"
                                aria-expanded={isOpen}
                                aria-haspopup="true"
                                {...(restricted ? { 'data-module-restricted': '1', title: HINT } : {})}
                                onClick={() => setOpen(isOpen ? null : m.id)}
                                className={
                                    'whitespace-nowrap rounded px-3 py-1.5 text-sm ' +
                                    (active.id === m.id
                                        ? 'bg-[color:var(--brand-ocean-fill)] text-white'
                                        : restricted
                                          ? 'text-[color:var(--brand-muted-glass)] hover:bg-[color:var(--brand-accent)]'
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
                                    className={menuPanelClass('left')}
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
            {/* ★【UI-1a:它现在是【那一行里】的一格,不再是底下整宽的一条】★
                从前顶栏是两行,这个按钮独占第二行,所以 w-full + px-4 pb-1.5。
                合成一行之后它与字标、头像并排 —— 整宽会把头像挤出视口。
                **形态一个字没改**(按钮 → 全高抽屉),UI-1b 才重做手机顶栏;
                这里改的只是它在新容器里的尺寸。390px 上的实测见报告。
                ★【UI-1c:重做的是抽屉【里面】,这个按钮一个字没动】★ */}
            <div className="sm:hidden">
                <button
                    type="button"
                    aria-expanded={sheet}
                    onClick={() => setSheet(!sheet)}
                    data-nav="menu-button"
                    className="whitespace-nowrap rounded border border-[color:var(--brand-border)] px-3 py-1.5 text-sm text-[color:var(--brand-text)]"
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
                        {/* ── ① 七个业务模块。**与桌面那一行是同一份 barModules。** ──
                            UI-1c 之前这里遍历的是【九条】,于是工具与设置在抽屉里
                            与采购、财务并排,读起来像第八、第九个业务模块。
                            它们不是:一个装小工具,一个装系统配置。 */}
                        {barModules.map((m) => {
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

                        {/* ── ②③ 工具 与 设置:两个【具名的区】,不是两个模块 ──────
                            ★【它们【不折叠】,而这是有意的】★ 七个模块各带一个 +/−;
                            给这两区也加一个 +/−,它们就又读成模块了 —— 而"它们不是
                            业务模块"正是本步骤要说的那件事。代价是高度:实测见报告,
                            两区展开着共 ~438px,抽屉因此要滚,而 ScrollPanel 会自己
                            说「↓ 下面还有 N 条」(CHART-0 ③)。**记下这笔取舍。**

                            ★【每一行的画法与桌面下拉【逐字相同】】★ MenuEntryRow,
                            包括「· 受限」后缀、title 提示与 data-module-restricted 记号。
                            ★【后缀在抽屉上【留着】】★ 它从桌面模块条上去掉的理由是
                            实测的宽度(UI-1a ⑦b:六个角色因此从 528.7–755.1px 齐平到
                            528.7px)。**一张竖排的清单没有宽度问题**,而在竖排里一行
                            灰字若不说自己为什么灰,它在"受限 / 禁用 / 还没加载完"之间
                            读不出区别。抽屉有地方把话说完,所以它说。

                            【一个空的区会【看得见】】下面两行取的是注册表里那两个模块
                            名下的条目;取不到就是一个只有标题、底下没有一行的区 ——
                            那在屏幕上是显眼的错,不是一处安静的缺席。
                            (真源不一致由 check-nav-routes 判据①④ 在构建期拦。) */}
                        <div className="mt-2 border-t border-[color:var(--brand-border)] pt-1">
                            <MenuSectionLabel>{t('nav.tools')}</MenuSectionLabel>
                            {sectionEntries(TOOLS_MODULE_ID).map((e) => (
                                <MenuEntryRow key={e.href} entry={e} activeHref={activeEntryHref} />
                            ))}
                        </div>
                        <div className="mt-2 border-t border-[color:var(--brand-border)] pt-1">
                            <MenuSectionLabel>{t('nav.settings')}</MenuSectionLabel>
                            {sectionEntries(SETTINGS_MODULE_ID).map((e) => (
                                <MenuEntryRow key={e.href} entry={e} activeHref={activeEntryHref} />
                            ))}
                        </div>

                        {/* ★★【UI-1c:「关于你」那一区【删了】—— 而这不是拿走了一扇门】★★
                            它此前放着写死的 /me 与 /my-reviews 两条链接。**同样这两页,
                            头像下拉里也各有一条**,而头像下拉【不按宽度藏东西】
                            (TopNav 里只有 ToolsMenu 带 hidden sm:block、SearchShell 带
                            hidden md:block;AvatarMenu 在每一个宽度上都画)——
                            那正是 AvatarMenu 抬头记下的那件事:收进一张下拉之后,
                            640–1024px 那个缺口【结构性地】没了。
                            所以这里删掉的是【第二份写死的地址】,不是唯一的入口:
                            两处各写一遍 /me,就是 lib/loginRoute.ts 那两个谓词、
                            那两份写死的 /suppliers 的同一个形状,本仓库付过两次账。
                            ★【那条「顶栏挪走什么,抽屉就得接住什么」在这里【没有】被触发】★
                            没有任何东西离开顶栏 —— 390px 上头像按钮就在顶栏里。 */}
                    </ScrollPanel>
                </div>
            )}
        </>
    )
}
