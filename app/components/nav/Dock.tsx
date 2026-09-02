'use client'

// app/components/nav/Dock.tsx
// ════════════════════════════════════════════════════════════════════════════
// 【dock —— 每个人自己的那一条快捷方式】Tim 的 D1 后半:结构是共享且固定的,
// dock 是个人的;他的原话是"像 macOS 的 Dock"。
// ════════════════════════════════════════════════════════════════════════════
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
//
// ★【可见性在【渲染时】算,不在【存的时候】算】★
// 存下来的只有地址;每一次渲染都拿当前权限重新问一遍注册表(lib/dock.ts 的
// resolveDock)。所以权限被收走的第二天,那一项自己就变成「受限」——
// 不需要任何人去跑一次清理。
//
// ★【它不是第二套导航】★(4d)加项只能从顶栏已有的条目里加(服务端动作对着
// FUNCTIONS 核),所以 dock 里不可能出现顶栏到不了的功能。
//
// 【手机是底栏】桌面是顶栏底下一条细排。位置不同,内容与判据完全相同。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useOptimistic, useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { entryForPath } from '@/lib/navTrail'
import { addToDock, removeFromDock, resetDock } from './dockActions'
import type { DockEntry } from './types'

export default function Dock({ items: serverItems, isDefault }: { items: DockEntry[]; isDefault: boolean }) {
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
    // 而错误由下面那句 role="alert" 说出来。**存的是什么没有变,变的是等待期间
    // 屏幕说的是哪一句话。**
    const [items, applyOptimistic] = useOptimistic(
        serverItems,
        (current: DockEntry[], action: { kind: 'remove'; href: string } | { kind: 'reset' }) =>
            action.kind === 'remove' ? current.filter((i) => i.href !== action.href) : current,
    )

    // 【"把当前这一页加进来"】—— 当前路径落在哪条注册表条目下,加的就是它。
    // 加的是【条目的地址】而不是当前 URL:一个带 id 的详情页不该进 dock,
    // 那是同一层上的一行,不是一个去处(与面包屑跳过 [id] 是同一条理由)。
    const here = entryForPath(pathname)
    const alreadyHere = here ? items.some((i) => i.href === here.href) : true

    const run = (
        fn: () => Promise<void>,
        optimistic?: { kind: 'remove'; href: string } | { kind: 'reset' },
    ) => {
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

    return (
        <div
            data-dock="1"
            data-dock-default={isDefault ? '1' : '0'}
            className={
                'nav-glass z-40 flex items-center gap-1 overflow-x-auto border-[color:var(--brand-border)] px-4 py-1.5 ' +
                // 手机:钉在底部,一条底栏。桌面:跟在顶栏下面。
                //
                // ★【w-screen 不是装饰,它挡住一个实测过的缺陷】★
                // 只写 inset-x-0 时,在【本身就横向可滚动的页面】上(线上有 134 个
                // 含表页面没有横向滚动容器,FE-0 PART C/e 量过),这条 fixed 底栏
                // 被拉到了【文档宽度】而不是视口宽度 —— 实测 /finance/invoices
                // 在 390px 上:视口 390,dock 宽 898。于是右半条 dock 停在屏幕外,
                // 而它看起来只是"东西有点多"。
                // 100vw 把它钉回视口,与底下那张表宽不宽无关。
                'fixed bottom-0 left-0 w-screen border-t sm:static sm:w-auto sm:border-t-0 sm:border-b'
            }
        >
            <span className="hidden shrink-0 pr-1 text-[11px] uppercase tracking-wide text-[color:var(--brand-muted-glass)] sm:inline">
                {t('nav.dock')}
            </span>

            {items.length === 0 && (
                /* 【空 dock 要说话】—— 一条什么都不显示的空栏,与"外壳坏了"分不开。 */
                <span className="shrink-0 text-xs text-[color:var(--brand-muted-glass)]">{t('nav.dockEmpty')}</span>
            )}

            {items.map((it) => {
                if (it.state === 'open') {
                    const active = pathname === it.href || pathname.startsWith(it.href + '/')
                    return (
                        <span key={it.href} className="flex shrink-0 items-center">
                            <Link
                                href={it.href}
                                className={
                                    'whitespace-nowrap rounded px-2.5 py-1 text-xs ' +
                                    (active
                                        ? 'bg-[color:var(--brand-ocean-fill)] text-white'
                                        : 'text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]')
                                }
                            >
                                {t(it.key as string)}
                            </Link>
                            {editing && <RemoveButton href={it.href} run={run} pending={pending} label={t('nav.dockRemove')} />}
                        </span>
                    )
                }
                // 【受限 / 已下架:留在原地,画成一条具名的限制,不是一个消失】
                return (
                    <span key={it.href} className="flex shrink-0 items-center">
                        <span
                            data-dock-state={it.state}
                            data-module-restricted="1"
                            title={it.state === 'restricted' ? t('dashboard.restrictedHint') : t('nav.dockGoneHint')}
                            className="whitespace-nowrap rounded px-2.5 py-1 text-xs text-[color:var(--brand-muted-glass)] cursor-default"
                        >
                            {it.state === 'restricted'
                                ? `${t(it.key as string)} · ${t('common.restricted')}`
                                : `${it.href} · ${t('nav.dockGone')}`}
                        </span>
                        <RemoveButton href={it.href} run={run} pending={pending} label={t('nav.dockRemove')} />
                    </span>
                )
            })}

            <span className="ml-auto flex shrink-0 items-center gap-1 pl-2">
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

            {error && (
                <span role="alert" className="shrink-0 text-[11px] text-[color:var(--brand-destructive)]">
                    {error}
                </span>
            )}
        </div>
    )
}

function RemoveButton({
    href, run, pending, label,
}: {
    href: string
    run: (fn: () => Promise<void>, optimistic?: { kind: 'remove'; href: string } | { kind: 'reset' }) => void
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
