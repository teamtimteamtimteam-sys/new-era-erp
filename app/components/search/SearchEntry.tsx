'use client'

// app/components/search/SearchEntry.tsx
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-1 · ★【一个面板,两个入口】★ —— Tim 的 S1
// SEARCH-3 · ★【那个面板变成一个【下拉】,而它仍然只有一个】★ —— Tim 的 U1
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么是一个组件,而不是"一个后端 + 两个结果面"】Tim 的原话:
//   **这个仓库反复为「同一件事建两遍」付账**,而两个结果面【措辞会漂】——
//   今天两边写着同一句「尚未启用」,三个月后一边说「没有结果」另一边说「找不到」。
//   ☞ 所以这里是【同一个组件】:顶栏画它一次(`nav/SearchShell.tsx`),
//     首页画它一次(`app/page.tsx`)。**两个入口,一个面板,一份措辞。**
//
// ════════════════════════════════════════════════════════════════════════════
// ★★★【SEARCH-3:一个读代码的人怎么在【三十秒内】确认它仍然只有一个】★★★
// ════════════════════════════════════════════════════════════════════════════
//   Tim 把这条列为整套搜索设计里他【最先说、也说得最多】的一条,理由是这个仓库
//   反复为「同一件事建两遍」付账,而两个结果面的**措辞会漂**。改成下拉最容易的
//   失败方式,就是"顶栏一个下拉、首页一个面板"。所以这里写下三条**可以跑**的验法:
//
//   ⚠ **先说一件,因为这三条【被自己咬过两次】:** 本仓库有一条明文教训 ——
//     「**一句注释可以污染将来对它自己的计数**」(AGENTS.md,已记到第六次)。
//     它在这一段上**连着咬了两次**,而两次都是实测撞出来的,不是想出来的:
//       · 第一版写「`grep -rln 'data-search-slot'` → 1 个文件」,实测 **3 个**
//         (`lib/search/types.ts:19` 与 `lib/search/records.ts:7` 各在注释里提过它);
//       · 第二版改用 `data-search-hit=`,写「→ 4 次」,实测 **7 次** ——
//         ★ **多出来的 3 次就是这一段话自己。**
//     ☞ 所以药不是"再换一个记号",是 **fixture 100 第 5/6 臂用过的那一味:
//       扫之前先把注释行剥掉**,只数【会被渲染的那些字节】。
//
//   ① **数【渲染结果的那个记号】,并且先剥注释。** 每一条画出来的结果都戴着
//      那个 hit 记号:
//        grep -rn 'data-search-hit="' app/ lib/ | grep -vE ':[0-9]+://' | wc -l
//      → **4**,而且四条**全部在本文件里**:recent · record · page · manual。
//      **没有第二组。**
//      ⚠ **不剥注释的那个数【不许写进这里】** —— 它会随着有没有人编辑这段话而变
//        (实测第二版 7、第三版 5),☞ **一个会被自己的文档改掉的读数不是读数。**
//   ② **数入口,用 import,不用文件名。** 文件名会出现在注释里:
//        `grep -rn "from '@/app/components/search/SearchEntry'" app/ lib/` → **2 处**
//        `app/page.tsx:121` 与 `app/components/nav/SearchShell.tsx:63`。
//      **两个入口,而它们都只是【传 class】。**
//   ③ **把两个入口能传的东西列出来。** 只有五样,全部是**外观**:
//      `triggerClassName` · `wrapperClassName` · `inputClassName` · `glyphClassName`
//      · `markers`。**一个都不能改变措辞、匹配、权限或结果的形状** ——
//      类型就是这么定的(见下面的 `SearchEntryProps`),所以"漂"这件事在
//      **类型这一层**就没有地方发生。
//   ☞ 三条都不需要读懂这个文件,数一数就行。**能数的东西才守得住。**
//
// 【两个入口从来不会同时在屏幕上】顶栏那个在首页上不画(SearchShell 读
//   `usePathname()`,理由整段写在那个文件里)。所以任何一页上恰好有一个实例 ——
//   快捷键因此也只有一个监听器,不需要任何协调。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★★【U1:你在【你点的那一格】里打字,结果贴着它往下展开】★★★
// ════════════════════════════════════════════════════════════════════════════
//   改前:点任一入口 → 弹出一个【居中的模态】,里面**另有一个输入框**,
//         而你刚点的那一格在遮罩底下待着。实测(probe-nav-geometry,改前):
//         1280 顶栏那一格 `200x32 @top=10 right=1176`,而面板 `576x315 @top=96
//         left=352 right=928` —— **顶边差 54px,右边缘差 248px**,它与触发它的
//         那一格【没有任何位置关系】。
//   改后:那一格**自己就是输入框**,下拉贴着它的下边缘、与它右对齐。
//         判据在 `scripts/probe-nav-geometry.mjs` 的 N13 / N13b 上,
//         而它们**改前是红的**(那正是这一刀要修的东西)。
//
// ── ★ 难的那一半:200px 的触发格,结果【不许】是 200px 宽 ────────────────────
//   顶栏那一格宽 200px。一个"跟着触发格一样宽"的下拉是最容易写出来的那个,
//   而它会把每一条结果压成三四行。所以宽度是**算出来的**,而算法只有三行:
//
//       宽 = clamp(触发格自己的宽, MIN_DROPDOWN, 视口 − 两侧边距)
//       左 = 触发格右边缘 − 宽          （右对齐;夹回视口内)
//       顶 = 触发格下边缘 + GAP
//
//   ☞ 于是:顶栏 200 → **448**(比触发格宽);首页桌面 544 → **544**
//     (触发格已经够宽,下拉就与它同宽,不去凭空多出一截);
//     首页 390px → **358**(被视口夹住,而那正是它不许越界的那一格)。
//   ★ 三个读数都由 N14 / N15a/b/c 逐个钉住,不靠"我认为它够宽"。
//
// ── ★★ 为什么是 `position: fixed` + 一次测量,而不是 `absolute` + 几个类 ────
//   `absolute` 的两个真麻烦,**都不是理论上的**:
//     ① **祖先的 `overflow` 会裁掉它。** 顶栏这一条今天没有 `overflow`,
//        而"今天没有"不是一条不变量 —— 下一个给顶栏加一句 `overflow-x-hidden`
//        的人,不会知道他顺手关掉了搜索结果。
//     ② **右对齐 + 视口夹取算不出来。** 触发格右边缘离视口右边只有约 100px,
//        一句 `right-0 max-w-[calc(100vw-2rem)]` 会把左边缘推到视口外面去
//        (实算:left ≈ 视口宽 − 100 − (视口宽 − 32) = **−68px**)。
//        夹回来需要知道触发格【在哪】,而那是一次测量,不是一个类。
//   ☞ 所以摆放由 `place()` 一次算完,直接写到 style 上。
//
//   ★★★ 而这里有一处**不推理、只测量**的兜底,值得读两遍:
//     `position: fixed` 的包含块【不一定是视口】—— 任何一个带 `transform` /
//     `filter` / `backdrop-filter` / `contain` 的祖先都会把它接管过去。
//     顶栏正好是这一族的常客(`app/components/TopNav.tsx` 抬头记着:
//     CHART-0 把 `.nav-glass` 从 `<header>` 挪走,正是因为 `backdrop-filter`
//     成了 fixed 后代的包含块,手机抽屉于是只有 94px 高)。
//     ☞ 所以 `place()` **摆完之后再量一次**,差多少补多少。
//       **它不需要知道哪个祖先干的,也不会在下一个人加回一层 filter 时失灵。**
//
// ── ★ 它【不再是一个模态】,所以这几样跟着走了 ──────────────────────────────
//   · 全屏遮罩(`data-search-overlay`)—— 没了。判据 N17 钉住它不许回来。
//   · `aria-modal` 与 Tab 关在里面 —— 没了:一个下拉不许劫持 Tab。
//     Tab 走出这个入口 = 关掉它(`onBlur` 里判 `relatedTarget` 在不在里面)。
//   · 面板里那个【第二个输入框】—— 没了,那正是 U1 要去掉的东西。
//   · 那颗「关闭」按钮 —— 没了。一个下拉的关法是 Esc / 点别处 / Tab 出去,
//     而那一格【自己】始终在屏幕上。`search.close` 两个文案文件里一并删掉 ——
//     **留一个没人用的键,下一个人会以为屏幕上还有那颗钮。**
//
// ── ★ U2:那一格的光标是【文字光标】,不是手型 ──────────────────────────────
//   它是一个输入框,不是一个链接。改前两个入口都画手型(实测 `cursor: pointer`),
//   而那是在说"点我会跳到别处去"。判据 N11/N12 读的是 computed `cursor`。
//
// ── 这个下拉【不继承打开它的那个控件的文字排版】───────────────────────────
//   `docs/base-components.md` 的那条规矩(ALERT-2d,Tim 在闸上裁定):
//   一个说话面是它自己的说话面。`position: fixed` **不打断继承** ——
//   它只把盒子搬出文档流,而继承走的是 DOM 树。所以下面那五个重置 class
//   是【承重】的,不是装饰,与 `ui/confirm-dialog.tsx` 上那一组逐字相同。
import * as React from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import type { SearchResults, WithheldCount } from '@/lib/search/types'
import { searchEverything } from './actions'

/**
 * 防抖。
 * ★【这个数是【挑】出来的,不是量出来的 —— 说白】★ SEARCH-0 §8 把「防抖多少毫秒」
 *   列在【下一轮】的问题里,因为它挂在「每次查询的代价」底下。
 *   ☞ SEARCH-2b 之后每次查询要打四次库(`actions.ts` 抬头列了),而那四次在
 *     319 行的体量上仍然是 Seq Scan —— **要重新推这个数,得先有数据。**
 */
const DEBOUNCE_MS = 200

// ── 摆放下拉用的三个常数,各自带着它的理由 ──────────────────────────────────
/** 下拉与视口两侧之间留的边距。与 `.stage` 的 1rem 内边距同一个量级。 */
const GUTTER = 16
/** 下拉与触发格之间的缝。★ 它必须 ≤ GUTTER —— N13 的判据就是 0 ≤ Δy ≤ 16。 */
const GAP = 8
/**
 * 下拉的**最小**宽度。
 * ★【它不是"挑的"那一类数 —— 它是改前那个模态的宽度的下取整】★
 *   改前的面板是 `max-w-xl` = 576px,而结果那一段 JSX 一个字都没换。
 *   448(28rem)比它窄一档,理由是下拉右对齐在顶栏上,而顶栏右边缘离视口只有
 *   约 100px:576 在 768px(`md` 断点,顶栏这一格开始画的那一刻)上仍然放得下,
 *   但余量只剩几十像素;448 留出一整段。**两个数都验过在视口里(N15a)。**
 */
const MIN_DROPDOWN = 448

type Variant = 'nav' | 'home'

export type SearchEntryProps = {
    variant: Variant
    /** 那一格自己的 class（外观）。**由入口给** —— 见下面那段。 */
    triggerClassName: string
    /** 包住那一格的那一层的 class（首页那个大框需要,顶栏用来挂 `hidden md:block`)。 */
    wrapperClassName?: string
    /** 输入框那一格的 class（首页用 CSS module 的 .prompt 控制截断与字号)。 */
    inputClassName?: string
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
     */
    markers?: Record<string, string>
}

// ★【为什么 class 由【入口】给,而不是这个组件自己按 variant 挑】★
//   两个入口今天的几何是【两套】:首页那个是 `home.module.css` 给一张近乎空白的
//   落地页画的(大圆角、柔和投影、随视口伸缩),顶栏那一格高 32px 宽 200px。
//   把两套尺寸搬进这个组件,就等于把 `home.module.css` 与顶栏的 Tailwind 串
//   各抄一份进来 —— **那正是"同一个意思的第二套说法"**。
//   ☞ 所以:**复用的是机制与措辞,不是尺寸。**
//   ☞ 顺带的好处正是停止条件 (f) 要的:**两个入口那一格的渲染几何与改前
//     【逐字相同】**(同样的 class 串,`<button>` 换成包着 `<input>` 的 `<label>`,
//     而 `<label>` 的行高由那个 `<input>` 决定,与改前那个 `<span>` 是同一个算式:
//     字号 × 继承下来的 `line-height` 比值)。判据 N1–N4 / N10 逐个量过。

export default function SearchEntry({
    variant,
    triggerClassName,
    wrapperClassName,
    inputClassName,
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
    const [results, setResults] = React.useState<SearchResults | null>(null)
    // ★【一次失败【不许】画成"没找到"】★ 两者在屏幕上必须分得开。
    const [failedFor, setFailedFor] = React.useState<string | null>(null)
    const wrapRef = React.useRef<HTMLDivElement | null>(null)
    /** ★ 触发【格】—— 200x32 的那个盒子本身,不是它里面的输入框。 */
    const fieldRef = React.useRef<HTMLLabelElement | null>(null)
    const inputRef = React.useRef<HTMLInputElement | null>(null)
    const panelRef = React.useRef<HTMLDivElement | null>(null)
    const titleId = React.useId()
    const panelId = React.useId()
    // 打到第几次了 —— 回包比打字慢时,旧回包不许覆盖新的。
    const seq = React.useRef(0)

    // ════════════════════════════════════════════════════════════════════════
    // ★★【摆放:算一次,写到 style 上,然后【再量一次】】★★
    // ════════════════════════════════════════════════════════════════════════
    //   ☞ 它**不用 state**:一个 `setState` 放在 layout effect 里正是这个文件
    //     上面那段注释点名的 `react-hooks/set-state-in-effect`。位置是一个
    //     **渲染之后才知道的事实**,不是渲染的输入 —— 所以它写给 DOM,不写给 React。
    const place = React.useCallback(() => {
        const field = fieldRef.current
        const panel = panelRef.current
        if (!field || !panel) return
        const r = field.getBoundingClientRect()
        const vw = document.documentElement.clientWidth
        const vh = document.documentElement.clientHeight
        const room = Math.max(1, vw - GUTTER * 2)
        // 宽 = clamp(触发格自己的宽, MIN_DROPDOWN, 视口 − 两侧边距)
        const width = Math.min(Math.max(r.width, Math.min(MIN_DROPDOWN, room)), room)
        // 右对齐到触发格的右边缘,再夹回视口里。
        let left = r.right - width
        if (left + width > vw - GUTTER) left = vw - GUTTER - width
        if (left < GUTTER) left = GUTTER
        const top = r.bottom + GAP
        panel.style.width = `${width}px`
        panel.style.left = `${left}px`
        panel.style.top = `${top}px`
        // 够不到底就自己滚 —— 一个顶出视口的下拉,底下那几条永远读不到。
        panel.style.maxHeight = `${Math.max(120, vh - top - GUTTER)}px`

        // ★★ 摆完【再量一次】—— 见抬头。祖先里任何一个 transform / filter /
        //   backdrop-filter / contain 都会把 `fixed` 的包含块从视口接管过去,
        //   而这几样正是顶栏的常客。**不推理哪一个祖先干的,差多少补多少。**
        const got = panel.getBoundingClientRect()
        const dx = left - got.left
        const dy = top - got.top
        if (Math.abs(dx) > 0.5 || Math.abs(dy) > 0.5) {
            panel.style.left = `${left + dx}px`
            panel.style.top = `${top + dy}px`
        }
    }, [])

    React.useLayoutEffect(() => {
        if (!open) return
        place()
        // 触发格会动:换视口、滚动(首页那一格在文档流里)、顶栏里的东西换宽度。
        window.addEventListener('resize', place)
        window.addEventListener('scroll', place, true)
        return () => {
            window.removeEventListener('resize', place)
            window.removeEventListener('scroll', place, true)
        }
    }, [open, place])

    // ── 快捷键。★ 判据:【这一格此刻看得见吗】,不是一个写死的断点。 ──────────
    //   最容易的写法是 `matchMedia('(min-width: 768px)')` —— 而那会在 TS 里
    //   【再写一遍】Tailwind 的 `md` 断点,于是 768 这个数在仓库里有两份。
    //   ☞ 所以问的是 `offsetParent`,也就是直接问 CSS 本身。**一个源。**
    React.useEffect(() => {
        function onKey(e: KeyboardEvent) {
            if (e.key !== 'k' && e.key !== 'K') return
            if (!e.metaKey && !e.ctrlKey) return
            if (fieldRef.current?.offsetParent == null) return
            e.preventDefault()
            // ★ 它现在【聚焦那一格】,而不是弹一个模态 —— 那正是 U1 的全部内容。
            inputRef.current?.focus()
            setOpen(true)
        }
        window.addEventListener('keydown', onKey)
        return () => window.removeEventListener('keydown', onKey)
    }, [])

    // ── 开着的时候:Esc 关(焦点留在那一格里)· 点别处关 ────────────────────
    //   ⚠ **没有 Tab 陷阱** —— 它不是模态。Tab 走出去由下面 wrapper 的 onBlur 关。
    React.useEffect(() => {
        if (!open) return
        function onPointerDown(e: Event) {
            const w = wrapRef.current
            if (w && e.target instanceof Node && !w.contains(e.target)) setOpen(false)
        }
        function onKeyDown(e: KeyboardEvent) {
            if (e.key !== 'Escape') return
            e.preventDefault()
            setOpen(false)
        }
        document.addEventListener('pointerdown', onPointerDown, true)
        document.addEventListener('keydown', onKeyDown, true)
        return () => {
            document.removeEventListener('pointerdown', onPointerDown, true)
            document.removeEventListener('keydown', onKeyDown, true)
        }
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
    // ★★【那一格是一个包着 <input> 的 <label> —— 而这是一处量过之后的判断】★★
    // ════════════════════════════════════════════════════════════════════════
    //   【为什么是 <label>】点标签 = 聚焦它包着的那个控件,**这是 HTML 自带的**,
    //     不需要一个 onClick 去 focus()。于是"点那一格就能打字"这件事
    //     没有任何 JS 参与 —— 键盘、读屏、触摸三条路一致。
    //   【为什么 class 仍然由入口给】那两串 class 是**这一刀必须保住不变的东西**:
    //     顶栏 `h-8 w-[200px] rounded-full`,首页 `home.module.css` 的 `.box`。
    //     ★ 停止条件 (f) 盯的就是它们,而顶栏在【每一页】上。
    //   【它为什么不算一颗手搓按钮】它现在根本不是按钮:`check-component-library`
    //     数的是 `<button` 与 `<table`,而这里一个都没有了 —— 基线因此**缩短**
    //     (那道棘轮的规矩:基线只会缩短)。
    const field = (
        <label
            ref={fieldRef}
            className={triggerClassName}
            data-nav="search-trigger"
            data-search-variant={variant}
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
            <input
                ref={inputRef}
                type="search"
                value={query}
                onChange={(e) => {
                    setQuery(e.target.value)
                    // 打字永远把它打开 —— Esc 关掉之后再打一个字,它该回来。
                    setOpen(true)
                }}
                onFocus={() => setOpen(true)}
                placeholder={t('home.searchPrompt')}
                // ★【可访问名走完整那一句,不走占位符那一句】★ 占位符要短
                //   (那一格 200px 宽),而读屏用户该听见的是"这里能找到什么"。
                aria-label={t('search.placeholder')}
                role="combobox"
                aria-expanded={open}
                aria-controls={panelId}
                // ⚠ 弹出来的是一组【分了节的链接】,不是一个 listbox ——
                //   写 `listbox` 会是一句假话,而假的 ARIA 比没有 ARIA 更坏。
                aria-haspopup="dialog"
                data-search-input="1"
                className={`min-w-0 flex-1 border-0 bg-transparent p-0 outline-none focus:ring-0 ${inputClassName ?? ''}`}
            />
        </label>
    )

    return (
        // ★【顶栏那一格的宽度隐藏 `hidden md:block` 挂在【入口】给的 wrapper 上】★
        //   本组件不认识 768 这个数 —— 见抬头那段快捷键的判据。
        <div
            className={wrapperClassName}
            ref={wrapRef}
            {...markers}
            // ★ Tab 走出这个入口 = 关掉它。**判据是"新焦点还在不在里面"**,
            //   而不是"焦点离开了输入框" —— 后者会在点一条结果时把面板关掉,
            //   于是那次点击落到空气上。
            // ★★【`relatedTarget === null` 时【不关】,而这一条是承重的】★★
            //   点面板里一段【没法聚焦】的文字(小节标题、「还有 N 条没画出来」)、
            //   或者切到别的窗口,浏览器给的 relatedTarget 都是 `null`,
            //   而 `contains(null)` 是 `false` —— 照字面判就会在**面板内部**
            //   点一下把它关掉。☞ 真正的"点到外面去了"由 document 上那个
            //   pointerdown 接住,两条路各管各的,不重叠。
            onBlur={(e) => {
                const next = e.relatedTarget as Node | null
                if (next && !e.currentTarget.contains(next)) setOpen(false)
            }}
        >
            {field}

            {open && (
                <div
                    ref={panelRef}
                    role="dialog"
                    aria-labelledby={titleId}
                    id={panelId}
                    data-search-panel="1"
                    // ★ 那五个重置是【承重】的 —— 见抬头。与 confirm-dialog 逐字相同。
                    // ⚠ `left/top/width/maxHeight` 由 place() 写在 style 上,
                    //   **不在这里写类** —— 它们是量出来的,不是选出来的。
                    className="fixed z-[150] overflow-y-auto rounded-lg border border-[color:var(--brand-border)] bg-background p-4 shadow-xl whitespace-normal text-left normal-case not-italic tracking-normal"
                >
                    <h2 id={titleId} className="sr-only">
                        {t('search.title')}
                    </h2>

                    <div
                        aria-live="polite"
                        // ★【这一格回答的是【哪一个】问题 —— 给量具的,不是装饰】★
                        //   一支探针打完字之后要等"答案到了",而它唯一诚实的判据
                        //   是【这份答案回答的问题 === 我刚打的那个】。
                        //   等一个固定的毫秒数会把"还没回来"读成"没找到"。
                        data-search-answered={showing ? showing.query : ''}
                    >
                        {/* ── 空状态(S10)★ 不留白,把"现在有什么"说出来 ── */}
                        {q === '' && (
                            <div data-search-empty="1" className="mb-4">
                                <p className="text-sm text-[color:var(--brand-text)]">
                                    {t('search.emptyWhatYouCanFind')}
                                </p>
                                {/* ★★【SEARCH-2b:这一格【建起来了】,而空的时候要说出【为什么空】】★★
                                    ☞ 实测 updated_by 填了 135/196 行,但只有 3 个操作者
                                      还在 auth.users 里(21 个里 18 个是探针残骸)。
                                      所以空的那一句说的是【你还没编辑过任何东西】,
                                      不是"没有结果",★ 也不再是「这一半还没建」——
                                      SEARCH-3 把那句过期的话换掉了(U4)。 */}
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
                                    由数据库现算,不写在这里。 */}
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

                        {busy && <p className={noneLine}>{t('search.searching')}</p>}

                        {/* ════════════════════════════════════════════════════
                            ★★【S2:这三节【只要下拉开着就在】,不是等有结果才长出来】★★
                            ════════════════════════════════════════════════════
                            【为什么这一条要紧,而它差点就做错了】第一版把三节包在
                            「有结果时才渲染」里面,于是 `scripts/probe-nav-geometry.mjs`
                            的 N7 格实测读到 `slots = []` —— **面板开着,而三节一个都不在。**
                            ☞ 顺带它也把空状态做对了(S10):每一节各自说出
                              「这里能找到什么」与「这里今天还找不到什么」,而不是一块白。 */}
                        {!failed && (
                            <div className="flex flex-col gap-4">
                                {/* ════════════════════════════════════════════
                                    ① 找单据 —— SEARCH-1 留的槽,SEARCH-2b 填上了
                                    ════════════════════════════════════════════ */}
                                <section data-search-slot="records">
                                    <h3 className={sectionH}>{t('search.sectionRecords')}</h3>
                                    {!showing ? (
                                        /* 空查询:说出【这里能找到什么】,而不是留白。 */
                                        <p className={noneLine}>{t('search.emptyWhatYouCanFindRecords')}</p>
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
                                                    {/* ════════════════════════════════════════════
                                                        ★★ SEARCH-4:这一条命中的【关联记录】★★
                                                        ════════════════════════════════════════════
                                                        【形状,连同它的理由】按目标单据种类分组,
                                                        **每组一行一个计数,不展开行**。Tim 的裁定
                                                        (Q7),逐字:「一个分组行答得出『这个供应商
                                                        现在什么情况』,而 11 行批号答不出。」

                                                        ★【为什么这些行【不是链接】—— 这是一次刻意的
                                                          取舍,写在这里免得下一个人以为是漏了】
                                                          一条「进料批 11」要链去哪?目标列表页按
                                                          `?q=` 过滤的是**单据号**,没有一条"这个
                                                          供应商的进料批"的地址;链到未过滤的列表
                                                          就是 records.ts 抬头点名拒绝过的那种
                                                          「差不多的地方」。而在下拉里就地展开是
                                                          另一个面板的活,这一刀明写不开第二个面板。
                                                          ☞ 所以它们是**读数**,不是去处;去处仍然
                                                            是上面那一条命中。

                                                        ★ flex-wrap:实测一条命中最多 7 组,而停止
                                                          条件 (a) 只允许 flex-wrap 这一种修法。 */}
                                                    {h.related.length > 0 ? (
                                                        <ul
                                                            data-search-related={h.code}
                                                            data-search-related-groups={h.related.length}
                                                            className="mb-1 ml-2 flex flex-wrap items-baseline gap-x-3 gap-y-0.5 px-2"
                                                        >
                                                            {h.related.map((g) => (
                                                                <li
                                                                    key={g.typeKey}
                                                                    data-search-related-group={g.typeKey}
                                                                    data-search-related-count={g.count}
                                                                    className="text-xs text-[color:var(--brand-muted-text)]"
                                                                >
                                                                    {t(`search.docType.${g.typeKey}`)}
                                                                    {' '}
                                                                    <span className="text-[color:var(--brand-text)]">{g.count}</span>
                                                                </li>
                                                            ))}
                                                        </ul>
                                                    ) : (
                                                        /* ★★【空 = 「这张单据没有关联记录」,不是「还没建」】★★
                                                            SEARCH-3 刚刚为了同一条理由删掉 records.built
                                                            与 search.recordsNotBuiltYet。一处缺席不许被
                                                            渲染成"这一半还没做"。 */
                                                        <p
                                                            data-search-related={h.code}
                                                            data-search-related-groups="0"
                                                            className="mb-1 ml-2 px-2 text-xs text-[color:var(--brand-muted-text)]"
                                                        >
                                                            {t('search.noRelated')}
                                                        </p>
                                                    )}
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
                                    {/* ════════════════════════════════════════════════
                                        ★★ Q8:一个不提"还有你看不到的"的计数,会被当成全部 ★★
                                        ════════════════════════════════════════════════
                                        `search_related()` 是 INVOKER —— 它数的是**你看得见
                                        的那些**,而被行级规则挡下的那几条它一声不吭。
                                        ☞ 裁定:说,而且**不带数**(T4 不许数它 —— 数它要逐行
                                          读内容)。理由与 SEARCH-2b §7.2 那条逐字同族:
                                          **一个说了个小数的截断提示,与一个不提截断的结果,
                                          读起来一样错。**
                                        ★ 而这一句挂在【整节】上,不挂在某一行上 —— departure,
                                          理由整段写在 docs/handbacks/SEARCH-4.md §6:
                                          要按行说,就得先判定某一类的策略是在闸【之内】收窄
                                          还是在闸【之外】放宽(实测 8 张表命中这个形状,而其中
                                          4 张是 OR 放宽、并不扣任何行)。一个会在【沉默那一侧】
                                          判错的标记,正好把 Q8 要防的那个缺陷原样再发一次。 */}
                                    {showing && showing.records.hits.some((h) => h.related.length > 0) && (
                                        <p className={noneLine} data-search-related-partial="1">
                                            {t('search.relatedOnlyWhatYouCanSee')}
                                        </p>
                                    )}
                                </section>

                                {/* ── ② 找页面与动作 ───────────────────────── */}
                                <section data-search-slot="pages">
                                    <h3 className={sectionH}>{t('search.sectionPages')}</h3>
                                    {!showing ? (
                                        /* 空查询:说出【这里能找到什么】,而不是留白。 */
                                        <p className={noneLine}>{t('search.emptyWhatYouCanFindPages')}</p>
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
                                        ⚠ **SEARCH-3 的 U4 明说不许动这一句** —— 它是一条
                                        常设裁定,而且今天仍然是真的。 */}
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
                                                        `docs/` 底下,**没有被服务出去**。
                                                        一个指向 404 的链接比没有链接坏得多。 */}
                                                    <p className="mt-0.5 text-xs text-[color:var(--brand-muted-glass)]">
                                                        {/* ★【这一段原样印手册自己的 PART 标题,【不】过 t()】★
                                                            它是手册里那一行英文,而手册只有英文(S7,Tim 的 Q8)。 */}
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
            )}
        </div>
    )
}
