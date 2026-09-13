'use client'

// app/components/search/SearchEntry.tsx
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-1 · ★【一个面板,两个入口】★ —— Tim 的 S1
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么是一个组件,而不是"一个后端 + 两个结果面"】Tim 的原话:
//   **这个仓库反复为「同一件事建两遍」付账**,而两个结果面【措辞会漂】——
//   今天两边写着同一句「尚未启用」,三个月后一边说「没有结果」另一边说「找不到」。
//   ☞ 所以这里是【同一个组件】:顶栏画它一次(`nav/SearchShell.tsx`),
//     首页画它一次(`app/page.tsx`)。**两个入口,一个面板,一份措辞。**
//
// 【两个入口从来不会同时在屏幕上】顶栏那个在首页上不画(SearchShell 读
//   `usePathname()`,理由整段写在那个文件里)。所以任何一页上恰好有一个实例 ——
//   快捷键因此也只有一个监听器,不需要任何协调。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【S3:手机上【没有】顶栏入口,而这是 Tim 裁定过的,不是一处缺陷】★★
// ════════════════════════════════════════════════════════════════════════════
//   顶栏那一格带着 `hidden md:block`(768px 以下不画),**本刀一个字都不动它**。
//   ☞ 于是在一部手机上:
//       · 首页那个大框【照画】—— 它没有宽度隐藏,手机上仍然是完整的入口;
//       · 顶栏那一格不画;
//       · 快捷键不存在(见下面 `fireShortcut` 的判据)。
//     **所以手机上进搜索的路恰好有一条:首页。**
//   ★ 这是 Tim 明说接受的取舍(S3:「它减轻这一刀的负担」)。
//     **写在这里,是为了让下一次走查不要把它记成缺陷。** 真要给手机加入口,
//     那是一件独立的活,而 `scripts/probe-search-shell.mjs` 的 S4 格钉着今天的现状。
//
// ── ★ 快捷键的判据:【这个入口自己现在看得见吗】,不是一个写死的断点 ────────
//   最容易的写法是 `matchMedia('(min-width: 768px)')` —— 而那会在 TS 里
//   【再写一遍】Tailwind 的 `md` 断点,于是 768 这个数在仓库里有两份。
//   本仓库为"同一条规则两份实现"付过账(lib/modules.ts 抬头 §一)。
//   ☞ 所以判据是:**触发钮此刻 `offsetParent !== null` 吗** ——
//     也就是直接问 CSS 本身。顶栏那一格在 390px 上 `display:none`,
//     于是 `offsetParent` 是 null,快捷键当场什么都不做。**一个源。**
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【S2:面板【按三件活定形】,其中一件今天返回空】★★
// ════════════════════════════════════════════════════════════════════════════
//   下面三节的顺序与标记是固定的,而 job ① 那一节【今天就在屏幕上】:
//       <section data-search-slot="records">   ← ★ SEARCH-2 填这一节
//       <section data-search-slot="pages">
//       <section data-search-slot="manual">
//   ☞ **一个读代码的人从 `data-search-slot="records"` 那一行就看得出 job ① 插在哪**,
//     而一个用的人从那一节的那句话就看得出"这一半还没建"——
//     **不是"没找到"**。两者在屏幕上必须分得开。
//   类型那一侧的对应物在 `lib/search/types.ts` 的 `records:` 字段上,
//   服务端那一侧在 `actions.ts` 的 `records:` 分支上。三处各有一段指名 SEARCH-2。
//
// ── 这个对话框【不继承打开它的那个控件的文字排版】───────────────────────────
//   `docs/base-components.md` 的那条规矩(ALERT-2d,Tim 在闸上裁定):
//   一个对话框是它自己的说话面。`position: fixed` **不打断继承** ——
//   它只把盒子搬出文档流,而继承走的是 DOM 树。所以下面那五个重置 class
//   是【承重】的,不是装饰,与 `ui/confirm-dialog.tsx` 上那一组逐字相同。
import * as React from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { searchEverything } from './actions'
import type { SearchResults, WithheldCount } from '@/lib/search/types'

/**
 * 防抖。
 * ★【这个数是【挑】出来的,不是量出来的 —— 说白】★ SEARCH-0 §8 把「防抖多少毫秒」
 *   列在【下一轮】的问题里,因为它挂在「每次查询的代价」底下,而那一条要等
 *   Q4/Q5(索引)。**今天 job ② 与 job ③ 一行数据库都不读**,所以每次查询的代价
 *   是一次权限查询;200ms 是为了不让一次连打变成十次往返而挑的。
 *   ☞ job ① 进来那天,这个数要从一次实测重新推一遍。
 */
const DEBOUNCE_MS = 200

type Variant = 'nav' | 'home'

export type SearchEntryProps = {
    variant: Variant
    /** 触发钮的 class。**由入口给** —— 见下面那段。 */
    triggerClassName: string
    /** 包住触发钮的那一层的 class(首页那个大框需要,顶栏不需要)。 */
    wrapperClassName?: string
    /** 提示语那一格的 class(首页用 CSS module 的 .prompt 控制截断)。 */
    promptClassName?: string
    /** 放大镜的 class。 */
    glyphClassName?: string
    /**
     * ★★【记号由【入口】给,而这是被一支在册的探针逼出来的】★★
     *
     * 第一版把 `data-nav="search-shell"` 写死在这个共享组件上,于是**首页那个入口
     * 也戴上了它** —— `scripts/probe-search-shell.mjs` 的 S1 与 S6 当场变红:
     * 它们断言的是「**顶栏**那一格在首页上不画」,而那条断言仍然成立,
     * 只是判据再也分不出「顶栏那一格」与「首页那一格」。
     * ☞ **一个记号被两个不同的东西戴着,就不再是一个记号。**
     *
     * 所以两个入口各戴各的,而且戴的就是它们改前戴的那一个:
     *   顶栏 `data-nav="search-shell"` · 首页 `data-home-search="shell"`。
     * **于是两支在册的探针一个字都不用改。**
     */
    markers?: Record<string, string>
}

// ★【为什么 class 由【入口】给,而不是这个组件自己按 variant 挑】★
//   两个入口今天的几何是【两套】:首页那个是 `home.module.css` 给一张近乎空白的
//   落地页画的(大圆角、柔和投影、随视口伸缩),顶栏那一格高 32px 宽 200px。
//   把两套尺寸搬进这个组件,就等于把 `home.module.css` 与顶栏的 Tailwind 串
//   各抄一份进来 —— **那正是"同一个意思的第二套说法"**。
//   ☞ 所以:**复用的是机制与措辞,不是尺寸** —— 这句话逐字来自
//     `SearchShell.tsx` 原来的抬头,本刀只是把它兑现在了一个真的共享组件上。
//   ☞ 顺带的好处正是这一刀要的:**两个触发钮的渲染几何与改前【逐字相同】**
//     (同样的 class 串,`<summary>`/`<details>` 换成 `<button>`),
//     于是版式普查那一边的差额只剩"真的变了的那几样"。

export default function SearchEntry({
    variant,
    triggerClassName,
    wrapperClassName,
    promptClassName,
    glyphClassName,
    markers,
}: SearchEntryProps) {
    const t = useTranslations()
    const [open, setOpen] = React.useState(false)
    const [query, setQuery] = React.useState('')
    // ════════════════════════════════════════════════════════════════════════
    // ★★【结果与失败都【绑着它们回答的那个问题】,而不是各存一个布尔】★★
    // ════════════════════════════════════════════════════════════════════════
    //   最直觉的写法是三个状态(results / busy / failed)外加一个
    //   「query 变了就把它们清掉」的 effect。**那个 effect 是一处缺陷,不是样板:**
    //   它在一次渲染之后【同步地】再改状态(eslint 的 `react-hooks/set-state-in-effect`
    //   当场报红),而且它把「这份结果是回答哪个问题的」这件事丢掉了 ——
    //   清干净之前那一瞬间,屏幕上是【上一个问题的答案配着新问题的输入框】。
    //
    // ☞ 所以这里存的是【答案 + 它回答的那个问题】,而"现在该不该显示它"是
    //   **算出来的**:`results.query === q`。于是:
    //     · 不需要一个清理 effect;
    //     · 不需要 busy 这个状态 —— "还没有对得上的答案,也没有失败" **就是**在查;
    //     · 一份旧答案【按构造】不可能挂在新问题底下。
    //   这与本仓库那条「一处缺席不许被渲染成一个答案」是同一个方向:
    //   **一份【回答别的问题的】答案,也不许被渲染成这个问题的答案。**
    const [results, setResults] = React.useState<SearchResults | null>(null)
    // ★【一次失败【不许】画成"没找到"】★ 两者在屏幕上必须分得开。
    //   存的是【哪一个问题失败了】,不是一个布尔 —— 理由同上。
    const [failedFor, setFailedFor] = React.useState<string | null>(null)
    const triggerRef = React.useRef<HTMLButtonElement | null>(null)
    const inputRef = React.useRef<HTMLInputElement | null>(null)
    const panelRef = React.useRef<HTMLDivElement | null>(null)
    const titleId = React.useId()
    // 打到第几次了 —— 回包比打字慢时,旧回包不许覆盖新的。
    const seq = React.useRef(0)

    // ── 快捷键。判据见抬头:问【触发钮此刻看不看得见】,不问一个写死的断点。 ──
    React.useEffect(() => {
        function onKey(e: KeyboardEvent) {
            if (e.key !== 'k' && e.key !== 'K') return
            if (!e.metaKey && !e.ctrlKey) return
            if (triggerRef.current?.offsetParent == null) return
            e.preventDefault()
            setOpen(true)
        }
        window.addEventListener('keydown', onKey)
        return () => window.removeEventListener('keydown', onKey)
    }, [])

    // ── 开着的时候:Escape 关,Tab 关在里面,焦点先落在输入框上。 ────────────
    React.useEffect(() => {
        if (!open) return
        inputRef.current?.focus()
        function onKeyDown(e: KeyboardEvent) {
            if (e.key === 'Escape') {
                e.preventDefault()
                setOpen(false)
                return
            }
            if (e.key !== 'Tab') return
            const panel = panelRef.current
            if (!panel) return
            const focusable = panel.querySelectorAll<HTMLElement>(
                'button:not([disabled]), [href], input:not([disabled]), [tabindex]:not([tabindex="-1"])'
            )
            if (focusable.length === 0) return
            const first = focusable[0]
            const last = focusable[focusable.length - 1]
            const active = document.activeElement
            if (!panel.contains(active)) {
                e.preventDefault()
                first.focus()
                return
            }
            if (e.shiftKey && active === first) {
                e.preventDefault()
                last.focus()
            } else if (!e.shiftKey && active === last) {
                e.preventDefault()
                first.focus()
            }
        }
        document.addEventListener('keydown', onKeyDown, true)
        return () => document.removeEventListener('keydown', onKeyDown, true)
    }, [open])

    // 关上之后把焦点还给触发钮 —— 与 <ConfirmButton> 同一条规矩。
    const wasOpen = React.useRef(false)
    React.useEffect(() => {
        if (wasOpen.current && !open) triggerRef.current?.focus()
        wasOpen.current = open
    }, [open])

    // ── 查。防抖,而且【旧回包不许覆盖新的】。 ────────────────────────────────
    //   ★ effect 体里【不改任何状态】—— 改状态一律发生在定时器回调与 promise 回调里,
    //     也就是"外部系统回话了"那一刻。见上面那段关于 set-state-in-effect 的注释。
    React.useEffect(() => {
        if (!open) return
        const q = query.trim()
        if (q === '') return
        const mine = ++seq.current
        const timer = setTimeout(() => {
            searchEverything(q)
                .then((r) => {
                    // 打字比回包快时回包会乱序 —— 只认最新那一次的。
                    if (mine !== seq.current) return
                    setResults(r)
                })
                .catch((e: unknown) => {
                    if (mine !== seq.current) return
                    // ★★【失败【不许】画成"没找到"】★★ 一次查询失败与"这里没有东西"
                    //   在屏幕上必须分得开 —— 那是本仓库反复付账的那一条
                    //   (lib/permissions.ts 抬头:一次瞬时故障与一次蓄意收权
                    //   在屏幕上长得一模一样)。所以清掉结果,让 `search.failed` 出来。
                    //
                    // ★【而那个异常【不许】被丢掉】★ 屏幕上不画它(一串数据库原文
                    //   不是给操作员读的 —— BUGFIX-1b 那一整刀就是在收这件事),
                    //   但它要进控制台,否则"搜不出来"这件事在任何地方都没有线索。
                    //   `check-error-swallowing` 的判据正是"空手接住";这里接住了,
                    //   而且用上了。
                    console.error('[search] searchEverything failed', e)
                    setFailedFor(q)
                })
        }, DEBOUNCE_MS)
        return () => clearTimeout(timer)
    }, [query, open])


    // ── 被扣下的那几行(S9)────────────────────────────────────────────────
    // 【内容不给,存在说出来】,而模块名【一定是九个之一】—— 薪资不是模块,
    // 它住在 hr 底下,所以那句话写作「HR」。Tim 的 Q6 裁定,SEARCH-0 §7 存了档。
    const withheldLines = (rows: WithheldCount[]) =>
        rows.map((w) => (
            <p
                key={w.moduleId}
                data-search-withheld={w.moduleId}
                className="mt-1 text-xs text-[color:var(--brand-muted-text)]"
            >
                {w.count === 1
                    ? t('search.withheldOne', { module: t(w.moduleNavKey) })
                    : t('search.withheldMany', { count: w.count, module: t(w.moduleNavKey) })}
            </p>
        ))

    // ── ★ 三个【算出来的】读数,而不是三个状态 —— 见上面那一段 ──────────────
    const q = query.trim()
    /** 这份结果回答的是【现在这个】问题吗。不是,它就不该出现在屏幕上。 */
    const showing = results && results.query === q ? results : null
    /** 失败的是【现在这个】问题吗。 */
    const failed = failedFor !== null && failedFor === q
    /** 还在查 = 有问题、没有对得上的答案、也没有失败。**它不需要一个状态。** */
    const busy = q !== '' && showing === null && !failed

    const sectionH = 'text-xs font-semibold uppercase tracking-wide text-[color:var(--brand-muted-text)]'
    const noneLine = 'mt-1 text-sm text-[color:var(--brand-muted-text)]'

    // ════════════════════════════════════════════════════════════════════════
    // ★★【触发钮是一颗【手写的】 <button>,而这是一处量过之后的判断】★★
    // ════════════════════════════════════════════════════════════════════════
    //   `check-component-library` 的规矩是「新页面不许手搓按钮」,而这一颗
    //   登记在它的基线里,与顶栏另外三处同族(`AvatarMenu` 3 · `ModuleBar` 4 ·
    //   `ToolsMenu` 1)—— 逐条理由写在 `docs/base-components.md` §十六。
    //
    // 【为什么它不能走 <Button>】这一颗的 class 由【入口】给,而那两串 class
    //   是**这一刀必须保住不变的东西**:顶栏那一格是 `h-8 w-[200px] rounded-full`
    //   (改前那个 `<summary>` 上逐字相同的一串),首页那一格是 `home.module.css`
    //   的 `.box`(大圆角、柔和投影、随视口伸缩)。
    //   ★ `<Button>` 自带 `rounded-lg` + 它自己的高度档位,套上去这两格的几何
    //     **当场就变了** —— 而顶栏在每一页上,首页那一格是手机上唯一的入口。
    //   ☞ 换句话说:走库会把一次"接上搜索"的改动变成一次**全树版式改动**,
    //     而那正是本刀的停止条件 (f) 盯着的东西。
    //   ⚠ 它仍然是一颗真按钮:`type="button"`、`aria-haspopup="dialog"`、
    //     `aria-expanded`、键盘天然可达 —— 手写的是外观,不是行为。
    const trigger = (
        <button
            ref={triggerRef}
            type="button"
            className={triggerClassName}
            data-nav="search-trigger"
            data-search-variant={variant}
            aria-haspopup="dialog"
            aria-expanded={open}
            onClick={() => setOpen(true)}
        >
            <svg
                viewBox="0 0 20 20"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.6"
                aria-hidden="true"
                className={glyphClassName}
            >
                <circle cx="8.75" cy="8.75" r="5.25" />
                <path d="M12.6 12.6 L16.5 16.5" strokeLinecap="round" />
            </svg>
            <span className={promptClassName}>{t('home.searchPrompt')}</span>
        </button>
    )

    return (
        // ★【顶栏那一格的宽度隐藏 `hidden md:block` 挂在【入口】给的 wrapper 上】★
        //   本组件不认识 768 这个数 —— 见抬头那段快捷键的判据。
        <div className={wrapperClassName} {...markers}>
            {trigger}

            {open && (
                <div
                    data-search-overlay="1"
                    className="fixed inset-0 z-[150] flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:pt-24"
                    // 【点外面关】判据是"这一下落在遮罩自己身上",不是冒泡上来的那些。
                    onMouseDown={(e) => {
                        if (e.target === e.currentTarget) setOpen(false)
                    }}
                >
                    <div
                        ref={panelRef}
                        role="dialog"
                        aria-modal="true"
                        aria-labelledby={titleId}
                        data-search-panel="1"
                        // ★ 那五个重置是【承重】的 —— 见抬头。与 confirm-dialog 逐字相同。
                        className="w-full max-w-xl rounded-lg border border-[color:var(--brand-border)] bg-background p-4 shadow-xl whitespace-normal text-left normal-case not-italic tracking-normal"
                    >
                        <h2 id={titleId} className="sr-only">
                            {t('search.title')}
                        </h2>

                        <div className="flex items-center gap-2">
                            <svg
                                viewBox="0 0 20 20"
                                fill="none"
                                stroke="currentColor"
                                strokeWidth="1.6"
                                aria-hidden="true"
                                className="h-4 w-4 shrink-0 text-[color:var(--brand-muted-text)]"
                            >
                                <circle cx="8.75" cy="8.75" r="5.25" />
                                <path d="M12.6 12.6 L16.5 16.5" strokeLinecap="round" />
                            </svg>
                            <input
                                ref={inputRef}
                                type="search"
                                value={query}
                                onChange={(e) => setQuery(e.target.value)}
                                placeholder={t('search.placeholder')}
                                aria-label={t('search.placeholder')}
                                data-search-input="1"
                                className="min-w-0 flex-1 border-0 bg-transparent p-0 text-base outline-none placeholder:text-[color:var(--brand-muted-glass)] focus:ring-0"
                            />
                            {/* ★【这一颗走组件库】★ Tim 的规矩 (a):新页面用库里的东西。
                                它是一颗普通的按钮,没有任何理由自己拼一套外观 ——
                                而下面那颗触发钮【不能】走库,理由写在它旁边。 */}
                            <Button
                                type="button"
                                variant="ghost"
                                size="sm"
                                className="shrink-0"
                                onClick={() => setOpen(false)}
                            >
                                {t('search.close')}
                            </Button>
                        </div>

                        <div
                            className="mt-3 border-t border-[color:var(--brand-border)] pt-3"
                            aria-live="polite"
                            // ★【这一格回答的是【哪一个】问题 —— 给量具的,不是装饰】★
                            //   一支探针打完字之后要等"答案到了",而它唯一诚实的判据
                            //   是【这份答案回答的问题 === 我刚打的那个】。
                            //   等一个固定的毫秒数会把"还没回来"读成"没找到" ——
                            //   本刀的 probe-search-results 第一版就是这么红了一格。
                            data-search-answered={showing ? showing.query : ''}
                        >
                            {/* ── 空状态(S10)★ 不留白,把"现在有什么"说出来 ── */}
                            {q === '' && (
                                <div data-search-empty="1" className="mb-4">
                                    <p className="text-sm text-[color:var(--brand-text)]">
                                        {t('search.emptyWhatYouCanFind')}
                                    </p>
                                    {/* ★★【SEARCH-2b:这一格【建起来了】,而空的时候要说出【为什么空】】★★
                                        SEARCH-1 在这里画的是「还没建」;迁移 C 的 22 条
                                        (updated_by, updated_at DESC) 索引与迁移 D 的
                                        search_recents() 下去之后,它画的是真的最近编辑过。
                                        ☞ 而它【今天对大多数人仍然是空的】,那不是坏了:
                                          实测 updated_by 填了 135/196 行,但只有 3 个操作者
                                          还在 auth.users 里(21 个里 18 个是探针残骸)。
                                          所以空的那一句说的是【你还没编辑过任何东西】(裁定),
                                          不是"没有结果"。两句话在屏幕上必须分得开。 */}
                                    {showing && showing.recents.hits.length > 0 ? (
                                        <section data-search-slot="recents" className="mt-3">
                                            <h3 className={sectionH}>{t('search.sectionRecents')}</h3>
                                            <ul className="mt-1 flex flex-col">
                                                {showing.recents.hits.map((h) => (
                                                    <li key={h.href}>
                                                        <Link
                                                            href={h.href}
                                                            onClick={() => setOpen(false)}
                                                            data-search-hit="recent"
                                                            className="flex flex-wrap items-baseline gap-x-2 rounded px-2 py-1.5 text-sm hover:bg-[color:var(--brand-accent)]"
                                                        >
                                                            <span className="text-[color:var(--brand-text)]">{h.code}</span>
                                                            {h.label !== '' && (
                                                                <span className="text-[color:var(--brand-text)]">{h.label}</span>
                                                            )}
                                                            <span className="text-xs text-[color:var(--brand-muted-text)]">
                                                                {t(h.moduleNavKey)}
                                                            </span>
                                                        </Link>
                                                    </li>
                                                ))}
                                            </ul>
                                        </section>
                                    ) : (
                                        <p className={noneLine} data-search-empty-recents="1">
                                            {t('search.emptyNoRecentsYet')}
                                        </p>
                                    )}
                                    {/* ★ 未覆盖的那些表【在屏幕上点名】(T3)—— 而那个数
                                        由数据库现算,不写在这里。裁定当时说 10,分母是
                                        「31 张有行的表」;按 39 张单据表算是 17。 */}
                                    {showing && showing.recents.uncovered > 0 && (
                                        <p className={noneLine} data-search-recents-uncovered={showing.recents.uncovered}>
                                            {t('search.recentsUncovered', { count: String(showing.recents.uncovered) })}
                                        </p>
                                    )}
                                </div>
                            )}

                            {failed && (
                                <p className="text-sm text-[color:var(--brand-text)]" data-search-failed="1">
                                    {t('search.failed')}
                                </p>
                            )}

                            {busy && (
                                <p className={noneLine}>{t('search.searching')}</p>
                            )}

                            {/* ════════════════════════════════════════════════════
                                ★★【S2:这三节【只要面板开着就在】,不是等有结果才长出来】★★
                                ════════════════════════════════════════════════════
                                【为什么这一条要紧,而它差点就做错了】第一版把三节包在
                                「有结果时才渲染」里面,于是 `scripts/probe-nav-geometry.mjs`
                                的 N7 格实测读到 `slots = []` —— **面板开着,而三节一个都不在。**
                                ☞ 那样 job ① 的槽就只活在【代码里】,不活在【屏幕上】。
                                  而 Tim 批准分两刀时点名的风险正是「SEARCH-2 会再开一个面板」,
                                  能挡住它的是**一个看得见的空位**,不是一段注释。
                                ☞ 顺带它也把空状态做对了(S10):每一节各自说出
                                  「这里能找到什么」与「这里今天还找不到什么」,而不是一块白。 */}
                            {!failed && (
                                <div className="flex flex-col gap-4">
                                    {/* ════════════════════════════════════════════
                                        ① 找单据 —— ★ SEARCH-2 填这一节 ★
                                        ════════════════════════════════════════════
                                        【它为什么今天就在屏幕上】Tim 批准分两刀时点名的
                                        风险是"SEARCH-2 会再开一个面板"。**槽在这里、
                                        标记在这里、措辞在这里**,于是那一刀是【填】。
                                        ⚠ 它画的是「这一半还没建」,**不是**「没找到」——
                                        一处缺席不许被渲染成一个答案。 */}
                                    <section data-search-slot="records">
                                        <h3 className={sectionH}>{t('search.sectionRecords')}</h3>
                                        {!showing ? (
                                            /* 空查询:说出【这里能找到什么】,而不是留白。 */
                                            <p className={noneLine}>{t('search.emptyWhatYouCanFindRecords')}</p>
                                        ) : !showing.records.built ? (
                                            /* ★ 这一支【留着】:它区分的是"这一半还没建"与"没找到",
                                               而那条区别本身没有过期。今天 built 恒为 true。 */
                                            <p className={noneLine} data-search-records-state="not-built">
                                                {t('search.recordsNotBuiltYet')}
                                            </p>
                                        ) : showing.records.hits.length === 0 ? (
                                            <p className={noneLine}>{t('search.noneRecords')}</p>
                                        ) : (
                                            <ul className="mt-1 flex flex-col">
                                                {showing.records.hits.map((h) => (
                                                    <li key={h.href}>
                                                        <Link
                                                            href={h.href}
                                                            onClick={() => setOpen(false)}
                                                            data-search-hit="record"
                                                            className="flex flex-wrap items-baseline gap-x-2 rounded px-2 py-1.5 text-sm hover:bg-[color:var(--brand-accent)]"
                                                        >
                                                            <span className="text-[color:var(--brand-text)]">{h.code}</span>
                                                            {/* ★ 有标签才给标签(裁定)—— 没有就不拿别的东西顶上。 */}
                                                            {h.label !== '' && (
                                                                <span className="text-[color:var(--brand-text)]">{h.label}</span>
                                                            )}
                                                            <span className="text-xs text-[color:var(--brand-muted-text)]">
                                                                {t(h.moduleNavKey)}
                                                            </span>
                                                        </Link>
                                                    </li>
                                                ))}
                                            </ul>
                                        )}
                                        {/* ★ 不许静默截断 —— more 是【截断之前】的真条数算出来的。 */}
                                        {showing && showing.records.more > 0 && (
                                            <p className={noneLine}>
                                                {t('search.moreNotShown', { count: String(showing.records.more) })}
                                            </p>
                                        )}
                                        {showing && withheldLines(showing.records.withheld)}
                                    </section>

                                    {/* ── ② 找页面与动作 ───────────────────────── */}
                                    <section data-search-slot="pages">
                                        <h3 className={sectionH}>{t('search.sectionPages')}</h3>
                                        {!showing ? (
                                            /* 空查询:说出【这里能找到什么】,而不是留白。 */
                                            <p className={noneLine}>{t('search.emptyWhatYouCanFind')}</p>
                                        ) : showing.pages.hits.length === 0 ? (
                                            <p className={noneLine}>{t('search.nonePages')}</p>
                                        ) : (
                                            <ul className="mt-1 flex flex-col">
                                                {showing.pages.hits.map((h) => (
                                                    <li key={h.href}>
                                                        <Link
                                                            href={h.href}
                                                            onClick={() => setOpen(false)}
                                                            data-search-hit="page"
                                                            className="flex flex-wrap items-baseline gap-x-2 rounded px-2 py-1.5 text-sm hover:bg-[color:var(--brand-accent)]"
                                                        >
                                                            <span className="text-[color:var(--brand-text)]">{h.label}</span>
                                                            <span className="text-xs text-[color:var(--brand-muted-text)]">
                                                                {t(h.moduleNavKey)}
                                                            </span>
                                                            <span className="text-xs text-[color:var(--brand-muted-glass)]">
                                                                {h.href}
                                                            </span>
                                                        </Link>
                                                    </li>
                                                ))}
                                            </ul>
                                        )}
                                        {showing && showing.pages.more > 0 && (
                                            <p className={noneLine}>
                                                {t('search.moreNotShown', { count: showing.pages.more })}
                                            </p>
                                        )}
                                        {showing && withheldLines(showing.pages.withheld)}
                                    </section>

                                    {/* ── ③ 找解释(上半:拿词搜手册)──────────── */}
                                    <section data-search-slot="manual">
                                        <h3 className={sectionH}>{t('search.sectionManual')}</h3>
                                        {/* ★★【S7:这一句常年在,不管有没有命中】★★
                                            Tim 裁定两种语言都搜英文手册(Q8)。他没说、
                                            而这里必须处理的后果是:**一个用中文搜的人
                                            在这一节里什么都匹配不到**,那读起来是"搜索坏了"。
                                            ☞ 所以先说清这一节是英文的,再给结果。
                                            两个文案文件里都有这一句。 */}
                                        <p
                                            data-search-manual-language="en"
                                            className="mt-1 text-xs text-[color:var(--brand-muted-text)]"
                                        >
                                            {t('search.manualEnglishOnly')}
                                        </p>
                                        {!showing ? null : showing.manual.hits.length === 0 ? (
                                            <p className={noneLine}>{t('search.noneManual')}</p>
                                        ) : (
                                            <ul className="mt-1 flex flex-col gap-2">
                                                {showing.manual.hits.map((h) => (
                                                    <li
                                                        key={h.id}
                                                        data-search-hit="manual"
                                                        className="rounded px-2 py-1.5"
                                                    >
                                                        <p className="text-sm text-[color:var(--brand-text)]">
                                                            {h.number ? h.number + ' ' : ''}
                                                            {h.title}
                                                        </p>
                                                        <p className="mt-0.5 text-sm text-[color:var(--brand-muted-text)]">
                                                            {h.snippet}
                                                        </p>
                                                        {/* ★【每一条都说出它来自哪一版手册】★ Tim 的裁定 ③。
                                                            ⚠ 它【不是】一个链接:那本手册是一份 PDF,住在
                                                            `docs/` 底下,**没有被服务出去**(public/ 底下没有它)。
                                                            所以这里给的是"这段话在书的哪一处"——
                                                            一个指向 404 的链接比没有链接坏得多。 */}
                                                        <p className="mt-0.5 text-xs text-[color:var(--brand-muted-glass)]">
                                                            {/* ★【这一段原样印手册自己的 PART 标题,【不】过 t()】★
                                                                它是手册里那一行英文,而手册只有英文(S7,Tim 的 Q8)——
                                                                给它铸一个文案键,等于把一句手册原文抄进文案文件,
                                                                而它下一版改了标题,这里就开始说假话。
                                                                这一节抬头那句 `search.manualEnglishOnly` 已经说清了
                                                                这一节是英文的。 */}
                                                            {h.part}
                                                            {' · '}
                                                            {t('search.manualVersion', {
                                                                version: showing.manual.version,
                                                                issued: showing.manual.issued,
                                                            })}
                                                        </p>
                                                    </li>
                                                ))}
                                            </ul>
                                        )}
                                        {showing && showing.manual.more > 0 && (
                                            <p className={noneLine}>
                                                {t('search.moreNotShown', { count: showing.manual.more })}
                                            </p>
                                        )}
                                    </section>
                                </div>
                            )}
                        </div>
                    </div>
                </div>
            )}
        </div>
    )
}
