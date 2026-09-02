'use client'

// app/components/nav/Dock.tsx
// ════════════════════════════════════════════════════════════════════════════
// 【dock —— 每个人自己的那一条快捷方式】Tim 的 D1 后半:结构是共享且固定的,
// dock 是个人的;他的原话是"像 macOS 的 Dock"。
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【CHART-0 ④:桌面上它从顶栏底下搬到了【左边一条竖栏】】★★
// Tim 的话:坐在模块导航底下,它读起来像【第三层菜单】,而不是"我的快捷方式";
// 而且它吃掉整整一行横向空间。两种形态的分工是【明确的】:
//     桌面 ≥640px  左边一条竖栏 —— 与顶栏分开:一条管【结构】,一条管【个人】;
//     手机 <640px  仍然是钉在底部的一条底栏(IA-BUILD-1 建的那一条,原样留着)。
// **为什么手机不跟着改成左栏**:底栏是手机的惯用法,拇指够得着;而在桌面上
// 底栏是离光标最远的地方,还会盖住表格的最后一行。同一个功能,两种正确的形态。
//
// ★【两边都能收起,而"收起"不等于"消失"】★
// 桌面收起 = 一条【图标宽】的竖栏(48px),不是不见了 —— Tim:「the reader must
// be able to bring it back without hunting」。图标还在原地,鼠标悬停有全名,
// 顶上那个箭头就是展开。手机收起 = 底栏只剩一条把手(一个箭头 + 一句话)。
// ★ 收起与否【跟着人走】,存在 user_dock.collapsed 上,不在 cookie 里 ——
//   理由与 dock 的内容逐字相同,见那张表的迁移抬头。
//
// ★【一项进不去的时候会怎样 —— 这是 4b,也是本组件存在的主要理由】★
// 三态,而且三态在屏幕上长得【不一样】:
//   open       可点;
//   restricted 在注册表里,但这个人【现在】进不去 → 画成「名字 · 受限」,不可点,
//              **并且旁边留着那个移除按钮** —— 他得能自己把它清掉;
//   gone       这个地址【已经不在注册表里了】(某一刀删掉了那个功能)→ 画成
//              「已下架」+ 移除按钮。
// **三者都必须与"这一项根本不在 dock 上"分得开。**一条指向自己进不去的页面的
// 可点链接,与这个仓库反复修的那一类谎是同一个家族:点下去撞上一屏拒绝,
// 而屏幕在点之前对他说的是"这里有东西给你"。
// 【收起态也必须分得开】图标变灰 + title 里那句「· 受限」,不是把它藏掉。
//
// ★【可见性在【渲染时】算,不在【存的时候】算】★
// 存下来的只有地址;每一次渲染都拿当前权限重新问一遍注册表(lib/dock.ts 的
// resolveDock)。所以权限被收走的第二天,那一项自己就变成「受限」——
// 不需要任何人去跑一次清理。
//
// ★【它不是第二套导航】★(4d)加项只能从顶栏已有的条目里加(服务端动作对着
// FUNCTIONS 核),所以 dock 里不可能出现顶栏到不了的功能。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useOptimistic, useState, useTransition } from 'react'
import { PanelLeftClose, PanelLeftOpen, ChevronUp, ChevronDown } from 'lucide-react'
import { useTranslations } from '@/lib/i18n/client'
import { entryForPath } from '@/lib/navTrail'
import { addToDock, removeFromDock, resetDock, setDockCollapsed } from './dockActions'
import { dockIcon, DOCK_GONE_ICON } from './dockIcons'
import type { DockEntry } from './types'

/** 展开时竖栏的宽度。**实测的代价写在 docs/information-architecture.md** —— 
 *  桌面内容宽度少 192px(收起时少 48px)。 */
const RAIL_W = 'w-48'
const RAIL_W_COLLAPSED = 'w-12'

type OptimisticAction = { kind: 'remove'; href: string } | { kind: 'reset' }
type Run = (fn: () => Promise<void>, optimistic?: OptimisticAction) => void

export default function Dock({
    items: serverItems, isDefault, collapsed: serverCollapsed,
}: {
    items: DockEntry[]
    isDefault: boolean
    collapsed: boolean
}) {
    const pathname = usePathname()
    const t = useTranslations()
    const [editing, setEditing] = useState(false)
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)

    // ★【乐观更新,而这不是装饰 —— 它买的是一条实测出来的缺陷】★
    // 服务端动作写完之后要 revalidatePath('/', 'layout'),而外壳在【每一页】上,
    // 所以整棵树要重画一遍。实测(稳定别名,按下移除之后逐秒采样):
    //     1s 没变 · 2s 没变 · 4s 没变 · **8s 才变**。
    // 也就是说:人按了「×」,屏幕上【五秒钟什么都没发生】。
    // 一个按下去没反应的控件读起来就是坏的 —— 而它其实已经写进库里了。
    // useOptimistic 让这一格【立刻】变,真值到了再对齐;失败时 React 自己回滚,
    // 而错误由下面那句 role="alert" 说出来。
    const [items, applyOptimistic] = useOptimistic(
        serverItems,
        (current: DockEntry[], action: OptimisticAction) =>
            action.kind === 'remove' ? current.filter((i) => i.href !== action.href) : current,
    )
    // 【收起/展开走同一条理由】同样是一次 revalidatePath('/', 'layout'),
    // 所以不乐观更新的话,点了"收起"之后【五秒钟栏还在那儿】。
    const [collapsed, applyCollapsed] = useOptimistic(serverCollapsed, (_c: boolean, next: boolean) => next)

    // 【"把当前这一页加进来"】—— 当前路径落在哪条注册表条目下,加的就是它。
    // 加的是【条目的地址】而不是当前 URL:一个带 id 的详情页不该进 dock,
    // 那是同一层上的一行,不是一个去处(与面包屑跳过 [id] 是同一条理由)。
    const here = entryForPath(pathname)
    const alreadyHere = here ? items.some((i) => i.href === here.href) : true

    const run: Run = (fn, optimistic) => {
        setError(null)
        startTransition(async () => {
            // 【乐观更新必须在 transition【里面】发起】—— 在外面调用 React 会警告,
            // 而且它会立刻被丢掉。
            if (optimistic) applyOptimistic(optimistic)
            try {
                await fn()
            } catch (e) {
                // 【失败要说出来】—— 一个静默失败的"加入 dock"会让人以为加过了。
                // (乐观的那一格由 React 在 transition 结束时自己回滚。)
                setError((e as Error).message)
            }
        })
    }

    const toggleCollapsed = () => {
        const next = !collapsed
        setError(null)
        startTransition(async () => {
            applyCollapsed(next)
            try {
                await setDockCollapsed(next)
            } catch (e) {
                setError((e as Error).message)
            }
        })
    }

    /** 一项的标签。gone 那一态没有 navKey(注册表里已经没有它了),就画地址。 */
    const labelOf = (it: DockEntry) =>
        it.state === 'gone' ? `${it.href} · ${t('nav.dockGone')}`
            : it.state === 'restricted' ? `${t(it.key as string)} · ${t('common.restricted')}`
                : t(it.key as string)

    const titleOf = (it: DockEntry) =>
        it.state === 'restricted' ? t('dashboard.restrictedHint')
            : it.state === 'gone' ? t('nav.dockGoneHint') : labelOf(it)

    const isActive = (href: string) => pathname === href || pathname.startsWith(href + '/')

    // ══ 一项,展开态(有字) ═══════════════════════════════════════════════
    const ItemFull = ({ it, vertical }: { it: DockEntry; vertical: boolean }) => {
        const Icon = it.state === 'gone' ? DOCK_GONE_ICON : dockIcon(it.href)
        const shell = vertical ? 'flex items-center' : 'flex shrink-0 items-center'
        if (it.state === 'open') {
            return (
                <span className={shell}>
                    <Link
                        href={it.href}
                        title={titleOf(it)}
                        className={
                            (vertical ? 'flex min-w-0 flex-1 items-center gap-2 rounded px-2 py-1.5 text-xs '
                                      : 'flex items-center gap-1.5 whitespace-nowrap rounded px-2.5 py-1 text-xs ') +
                            (isActive(it.href)
                                ? 'bg-[color:var(--brand-ocean-fill)] text-white'
                                : 'text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]')
                        }
                    >
                        <Icon aria-hidden size={14} className="shrink-0" />
                        <span className={vertical ? 'truncate' : ''}>{labelOf(it)}</span>
                    </Link>
                    {editing && <RemoveButton href={it.href} run={run} pending={pending} label={t('nav.dockRemove')} />}
                </span>
            )
        }
        // 【受限 / 已下架:留在原地,画成一条具名的限制,不是一个消失】
        return (
            <span className={shell}>
                <span
                    data-dock-state={it.state}
                    data-module-restricted="1"
                    title={titleOf(it)}
                    className={
                        (vertical ? 'flex min-w-0 flex-1 items-center gap-2 rounded px-2 py-1.5 text-xs '
                                  : 'flex items-center gap-1.5 whitespace-nowrap rounded px-2.5 py-1 text-xs ') +
                        'text-[color:var(--brand-muted-glass)] cursor-default'
                    }
                >
                    <Icon aria-hidden size={14} className="shrink-0" />
                    <span className={vertical ? 'truncate' : ''}>{labelOf(it)}</span>
                </span>
                <RemoveButton href={it.href} run={run} pending={pending} label={t('nav.dockRemove')} />
            </span>
        )
    }

    // ══ 一项,收起态(只有图标 —— 但全名在 title / aria-label 上) ═════════
    const ItemIcon = ({ it }: { it: DockEntry }) => {
        const Icon = it.state === 'gone' ? DOCK_GONE_ICON : dockIcon(it.href)
        const common = 'flex h-8 w-8 items-center justify-center rounded '
        if (it.state === 'open') {
            return (
                <Link
                    href={it.href}
                    title={labelOf(it)}
                    aria-label={labelOf(it)}
                    className={common + (isActive(it.href)
                        ? 'bg-[color:var(--brand-ocean-fill)] text-white'
                        : 'text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]')}
                >
                    <Icon aria-hidden size={16} />
                </Link>
            )
        }
        // 【收起态也要分得开三种状态】灰掉 + title 里那句「· 受限」/「已下架」,
        // 不是把它从条上拿掉 —— 拿掉就与"我从来没加过它"分不开了(4b)。
        return (
            <span
                data-dock-state={it.state}
                data-module-restricted="1"
                title={`${labelOf(it)} — ${titleOf(it)}`}
                aria-label={labelOf(it)}
                className={common + 'text-[color:var(--brand-disabled-text)] cursor-default'}
            >
                <Icon aria-hidden size={16} />
            </span>
        )
    }

    const EmptyNote = () => (
        /* 【空 dock 要说话】—— 一条什么都不显示的空栏,与"外壳坏了"分不开。 */
        <span className="shrink-0 text-xs text-[color:var(--brand-muted-glass)]">{t('nav.dockEmpty')}</span>
    )

    const Controls = ({ vertical }: { vertical: boolean }) => (
        <span className={vertical ? 'mt-2 flex flex-wrap items-center gap-1 border-t border-[color:var(--brand-border)] pt-2'
                                  : 'ml-auto flex shrink-0 items-center gap-1 pl-2'}>
            {here && !alreadyHere && (
                <button
                    type="button"
                    disabled={pending}
                    onClick={() => run(() => addToDock(here.href))}
                    className="whitespace-nowrap rounded border border-[color:var(--brand-border)] px-2 py-0.5 text-[11px] text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)] disabled:opacity-50"
                >
                    {t('nav.dockAddHere')}
                </button>
            )}
            <button
                type="button"
                onClick={() => setEditing(!editing)}
                aria-pressed={editing}
                className="whitespace-nowrap rounded px-2 py-0.5 text-[11px] text-[color:var(--brand-muted-glass)] hover:bg-[color:var(--brand-accent)]"
            >
                {editing ? t('common.done') : t('nav.dockEdit')}
            </button>
            {editing && !isDefault && (
                <button
                    type="button"
                    disabled={pending}
                    onClick={() => run(resetDock)}
                    className="whitespace-nowrap rounded px-2 py-0.5 text-[11px] text-[color:var(--brand-muted-glass)] hover:bg-[color:var(--brand-accent)] disabled:opacity-50"
                >
                    {t('nav.dockReset')}
                </button>
            )}
        </span>
    )

    const Err = () =>
        error ? (
            <span role="alert" className="shrink-0 text-[11px] text-[color:var(--brand-destructive)]">
                {error}
            </span>
        ) : null

    return (
        <>
            {/* ══ 桌面(≥640px):左边一条竖栏 ═══════════════════════════════
                【它是 flex 行里的一个项,所以它的右边框自然贯穿整页高】——
                不需要给它一个高度,stretch 就是 flex 的默认。 */}
            <nav
                data-dock="1"
                data-dock-default={isDefault ? '1' : '0'}
                data-dock-collapsed={collapsed ? '1' : '0'}
                aria-label={t('nav.dock')}
                className={
                    'nav-glass hidden shrink-0 flex-col gap-0.5 border-r border-[color:var(--brand-border)] px-2 py-2 sm:flex ' +
                    (collapsed ? RAIL_W_COLLAPSED + ' items-center' : RAIL_W)
                }
            >
                <button
                    type="button"
                    onClick={toggleCollapsed}
                    aria-expanded={!collapsed}
                    title={collapsed ? t('nav.dockExpand') : t('nav.dockCollapse')}
                    aria-label={collapsed ? t('nav.dockExpand') : t('nav.dockCollapse')}
                    className={
                        'mb-1 flex items-center gap-1.5 rounded px-1.5 py-1 text-[11px] uppercase tracking-wide text-[color:var(--brand-muted-glass)] hover:bg-[color:var(--brand-accent)] ' +
                        (collapsed ? 'justify-center' : '')
                    }
                >
                    {collapsed ? <PanelLeftOpen aria-hidden size={16} /> : <PanelLeftClose aria-hidden size={16} />}
                    {!collapsed && <span>{t('nav.dock')}</span>}
                </button>

                {items.length === 0 && !collapsed && <EmptyNote />}
                {items.map((it) => (collapsed ? <ItemIcon key={it.href} it={it} /> : <ItemFull key={it.href} it={it} vertical />))}
                {!collapsed && <Controls vertical />}
                {!collapsed && <Err />}
            </nav>

            {/* ══ 手机(<640px):钉在底部的一条底栏 ═══════════════════════════
                ★【w-screen 不是装饰,它挡住一个实测过的缺陷】★
                只写 inset-x-0 时,在【本身就横向可滚动的页面】上(线上有 134 个
                含表页面没有横向滚动容器,FE-0 PART C/e 量过),这条 fixed 底栏
                被拉到了【文档宽度】而不是视口宽度 —— 实测 /finance/invoices
                在 390px 上:视口 390,dock 宽 898。于是右半条 dock 停在屏幕外,
                而它看起来只是"东西有点多"。100vw 把它钉回视口。 */}
            <div
                data-dock="1"
                data-dock-mobile="1"
                data-dock-default={isDefault ? '1' : '0'}
                data-dock-collapsed={collapsed ? '1' : '0'}
                className={
                    'nav-glass fixed bottom-0 left-0 z-40 flex w-screen items-center gap-1 overflow-x-auto border-t border-[color:var(--brand-border)] px-4 sm:hidden ' +
                    (collapsed ? 'py-0.5' : 'py-1.5')
                }
            >
                <button
                    type="button"
                    onClick={toggleCollapsed}
                    aria-expanded={!collapsed}
                    aria-label={collapsed ? t('nav.dockExpand') : t('nav.dockCollapse')}
                    className="flex shrink-0 items-center gap-1 rounded px-1.5 py-0.5 text-[11px] uppercase tracking-wide text-[color:var(--brand-muted-glass)] hover:bg-[color:var(--brand-accent)]"
                >
                    {collapsed ? <ChevronUp aria-hidden size={14} /> : <ChevronDown aria-hidden size={14} />}
                    <span>{t('nav.dock')}</span>
                </button>
                {/* 【收起时底栏只剩那条把手】—— 它【没有消失】,所以再点一下就回来。
                    手机上不留图标条:一条 48px 高的图标带在 844px 的屏幕上仍然是
                    一整条,而 Tim 要收起的正是"它占着一条"这件事。 */}
                {!collapsed && (
                    <>
                        {items.length === 0 && <EmptyNote />}
                        {items.map((it) => <ItemFull key={it.href} it={it} vertical={false} />)}
                        <Controls vertical={false} />
                        <Err />
                    </>
                )}
            </div>
        </>
    )
}

function RemoveButton({
    href, run, pending, label,
}: {
    href: string
    run: Run
    pending: boolean
    label: string
}) {
    return (
        <button
            type="button"
            aria-label={label}
            title={label}
            disabled={pending}
            onClick={() => run(() => removeFromDock(href), { kind: 'remove', href })}
            className="ml-0.5 rounded px-1 text-[11px] leading-none text-[color:var(--brand-muted-glass)] hover:text-[color:var(--brand-destructive)] disabled:opacity-50"
        >
            ×
        </button>
    )
}
