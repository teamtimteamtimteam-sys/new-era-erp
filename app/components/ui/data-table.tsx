'use client'

// ════════════════════════════════════════════════════════════════════════════
// BASE-1(2026-09-02)· 表格 —— 【手机上仍然是一张账簿】
// ════════════════════════════════════════════════════════════════════════════
// 全站 201 张表、161 个文件、1,215 个 <td>、990 个 <th>,而库【一个都没有】:
// 0 处排序、0 处列显隐、0 处分页(FE-0 量的)。
//
// ★ 量出来的形状:它们【是同一种东西】★(BASE-1 量的,201 张逐张解析)
//   * 198 / 201 是【会重复的账簿】(块里有 .map);只有 3 张是静态的明细表。
//   * 列数 2–13,众数 5:2–4 列 58 张 · 5–6 列 88 张 · **≥7 列 52 张**。
//   * 最宽的几张:/inbound 13 列 · /finance/assets 12 列 · /materials 与 /output 各 11 列。
//   也就是说【一种答案可以覆盖全部】—— 它们不是"账簿/明细/摘要"三类,
//   它们是同一类,只在【宽度】上不同。真正的难题只有一个:52 张宽表怎么上手机。
//
// ★ R3 · 手机上的画法:【留下的列 + 一行展开】,不是卡片流 ★
//   【为什么不是卡片流】一张账簿存在的意义是【顺着一列往下比】——
//   60 行变成 60 张卡片之后,那一列就再也扫不了了。卡片流是最常见的响应式答案,
//   而它恰好毁掉这张表唯一不可替代的能力。
//   【为什么不是只给横向滚动】那是把桌面版缩小,R3 明确不要。
//   所以:手机上留下【声明过的那几列】(身份 + 那个要紧的数),其余的收进
//   点一下展开的一段带标签的列表。**它在 390px 上仍然是一张表,仍然能顺列扫。**
//
// ★ 列的优先级【每张表自己声明】,组件不猜 ★
//   「猜前 N 列」在有些表上一定会挑错 —— /inbound 的前两列是批次号和日期,
//   而人在手机上要找的是物料和净重。所以:
//   **一张表没有声明任何 priority 列时,本组件【当场按名拒绝】**
//   (`DATATABLE_NO_PHONE_COLUMNS`),而不是默默退回"前 N 列"或"横向滚动"。
//   本仓库对这个形状有一长串先例:不声明重量基准就拒、缺一个交易日就拒、
//   没录上限就拒绝作判断。**一次响亮的拒绝,好过一个悄悄挑错列的默认值。**
//   它拒得起,是因为本刀【没有转换任何页面】:今天没有一个页面会碰到这条路,
//   而每一次转换都会在第一次渲染时就撞上它。
//
// ★ R4 · 排序/筛选/分页/列显隐是【能力】,不是样式 —— 而且默认【全关】★
//   四个开关一律默认 false。把组件换上去【不会改变任何一页现在显示的东西】,
//   要多出一个控件必须是显式打开的。R4 要的就是这个。
//
// ★★ 它【永远不声称排了它没拿到的东西】★★(Tim 的裁定,A1)
//   失败模式是静默的:一页只取了一屏数据,却给出一个排序控件 ——
//   人按下去,以为自己看到了【全体里最大的那个】,其实只是这一屏里最大的。
//   处置放在【类型上】,不是放在注释里,而且比"提示一句"更硬:
//   **客户端排序只接受 coverage: 'complete'。拿到的是一部分,就打不开它 —— 编译期就打不开。**
//   一句提示要人去读;一个类型错误不需要任何人记得。
//
// ★★ 而 FE-0 那句「ZERO 排序、ZERO 分页」是【错的】—— 量出来的 ★★
//   BASE-1 逐页量过:
//     * 排序:**8 页已经有了**(/inbound /materials /output /customers /suppliers
//       /operation/processing /pricing/metal-prices /finance/fx),走的是 URL 参数 + 数据库 ORDER BY;
//     * 分页:**17 页已经有了**,走 .range();
//     * 列显隐:**0 页** —— 这一条 FE-0 说对了。
//   这件事直接改了本组件的形状:那 8 页的排序是【在数据库里对全体排的】,
//   而客户端排序只能对【取回来的那一页】排。把它们换成客户端排序**是一次降级**,
//   而且正好是上面那个静默失败。
//   所以本组件有两种排序模式,且【第二种是给那 17 页留的路】:
//     * mode: 'client' —— 自己排。**类型上只允许 coverage: 'complete'。**
//     * mode: 'server' —— 表头渲染成链接,由页面自己的 URL 参数去数据库排。
//       这时候排序看得见全体,所以【不需要】任何警告;只报"显示第几到第几行"。
//   换句话说:**转换刀不必为了用上这个组件而放弃已经正确的服务端排序。**
// ════════════════════════════════════════════════════════════════════════════

import * as React from 'react'
import { cn } from '@/lib/utils'

export type Column<T> = {
    /** 稳定的列键 —— 排序状态与列显隐都按它记。 */
    key: string
    header: React.ReactNode
    /** ★ 手机上留在表里的列。每张表自己声明,组件不猜。至少要有一列。 */
    priority?: boolean
    align?: 'left' | 'right'
    /**
     * 【客户端排序】的比较值。给了才可排;不给这一列就是不可排的
     * —— 而不是排出一个假的顺序。
     */
    sortValue?: (row: T) => string | number | null | undefined
    /**
     * 【服务端排序】用:这一列可以拿去排。
     *
     * 【为什么不复用 sortValue】服务端模式下排序是数据库做的,
     * 组件要的只是"这一列排不排"这个事实和它的 key ——
     * 逼调用方写一个【永远不会被调用】的比较器,是逼他写死代码。
     * 给了 sortValue 的列自动算可排,所以两种模式可以共用一份列定义。
     */
    sortable?: boolean
    render: (row: T) => React.ReactNode
    /** 手机展开区里的标签。不给就用 header —— 但 header 常常是缩写。 */
    phoneLabel?: React.ReactNode
    className?: string
}

/**
 * ★★【CONV-1:这张表在 390px 上【怎么办】—— 必填,而且没有默认值】★★
 *
 * 【为什么是必填的 prop,而不是一个可选项】Tim 的 Q3=C 裁定要求:一张什么都不声明的
 * 表要被【按名拒绝】,而一张选择横向滚动的表可以,只要那是一个【说出来的】决定。
 * 「说出来」如果只是注释,下一个人会漏读;如果只是一道闸,它得等到有人跑闸。
 * **写成必填的 prop,漏掉它就编译不过** —— 那是这三层里唯一一层不需要任何人记得的。
 *
 * 【为什么 scroll 那一支强制带 why】没有它,`mode: 'scroll'` 就是一个比
 * 「什么都不写」更方便的默认值 —— 而那正好把这条裁定倒过来。
 * 带上 why,选择横向滚动就必须当场写下这张表为什么值得让人横着拖,
 * 而这句话会跟着代码走,不会留在某次提交信息里。
 *
 * 【两支各自是什么】
 *   columns —— BASE-1 的做法:手机上只留声明过 priority 的那几列,其余进展开区。
 *              **一列 priority 都没有的表在这里还会撞上第二道网(见下面的按名拒绝)。**
 *   scroll  —— 全部列都留在手机上,靠外层那层 overflow-x 横着拖。
 *              R3 说过这是「把桌面版缩小」,所以它要理由;但对一张 13 列的进料台账,
 *              它可能确实是那个诚实的答案。
 */
export type PhoneTreatment =
    | { mode: 'columns' }
    | { mode: 'scroll'; why: string }

/** 【你拿到的是全部,还是一部分】—— 打开排序就必须回答。 */
export type Coverage = 'complete' | { shown: number; total: number }

/** 不排。 */
type SortingOff = { sorting?: undefined }
/** 自己排 —— ★ 类型上只接受"我拿到了全部"。这就是 A1 那条裁定。 */
type SortingClient = { sorting: { mode: 'client'; coverage: 'complete' } }
/** 交给页面已有的 URL 参数去数据库排 —— 排的是全体,所以 coverage 可以是一部分。 */
type SortingServer = {
    sorting: {
        mode: 'server'
        coverage: Coverage
        active: { key: string; dir: 'asc' | 'desc' } | null
        href: (key: string, dir: 'asc' | 'desc') => string
    }
}

export type DataTableProps<T> = {
    rows: readonly T[]
    columns: ReadonlyArray<Column<T>>
    rowKey: (row: T) => string
    /** ★ 390px 上怎么办。**必填** —— 见 PhoneTreatment 抬头。 */
    phone: PhoneTreatment
    caption?: React.ReactNode
    /** 空集不是失败,但它要【说出自己是空的】。 */
    empty?: React.ReactNode
    /** 一个文字筛选框;不给就没有筛选。 */
    filter?: { label: string; match: (row: T, q: string) => boolean }
    /** 每页行数;不给就不分页(今天 201 张表全部不分页,默认保持原样)。 */
    pageSize?: number
    /** 列显隐。 */
    columnToggle?: boolean
    /** 手机上展开/收起的无障碍名字。 */
    phoneExpandLabel?: string
    className?: string
} & (SortingOff | SortingClient | SortingServer)

const DIR_NEXT = { none: 'asc', asc: 'desc', desc: 'none' } as const
type Dir = keyof typeof DIR_NEXT

export function DataTable<T>(props: DataTableProps<T>) {
    const {
        rows, columns, rowKey, caption, empty, filter, pageSize, phone,
        columnToggle = false, phoneExpandLabel = '展开这一行的其余各列', className,
    } = props
    // ★【CONV-1:scroll 那一支 —— 手机上【每一列都留着】,靠外层横向滚动】★
    //   实现上它就是"把所有列都当成 priority",于是下面那些 `!c.priority` 的
    //   隐藏规则一条都不生效,展开钮那一格也不画(没有东西可展开)。
    //   **注意它不是"关掉手机适配",是【另一种】手机适配** —— 而它必须带 why。
    const phoneScroll = phone.mode === 'scroll'
    const isPhoneCol = (c: Column<T>) => phoneScroll || !!c.priority
    const sorting = props.sorting
    const clientSort = sorting?.mode === 'client'
    const serverSort = sorting?.mode === 'server' ? sorting : null

    // ★ 按名拒绝 —— 见抬头。没有声明手机列,就不要把这张表放到手机上。
    //
    // ★★【CONV-1:这是【第三道网】,不再是唯一的一道】★★
    //   它是一个【渲染期】的 throw —— 也就是说它只在有人真的打开这一页时才响。
    //   对一张少有人访问的列表页,那可能是几个月之后。所以 CONV-1 在它前面加了两道:
    //     ① 类型:phone 是必填的 prop —— 漏掉它【编译不过】(上面那个联合类型);
    //     ② 闸:scripts/check-datatable-phone.mjs 逐个调用点检查
    //        「columns 模式的表至少有一列 priority」,点名 file:line,进 npm run build。
    //   三道网各自看得见对方看不见的东西:类型管"有没有声明",闸管"声明得对不对",
    //   而这个 throw 管【运行期才拼出来的列】(闸是静态解析,它读不出动态生成的列)。
    //   **留着它,理由就是最后这一句。**
    //
    //   scroll 模式【不走这条路】:它已经回答过手机这个问题了,答案是"全部列都留着"。
    const priorityCols = columns.filter((c) => c.priority)
    if (!phoneScroll && priorityCols.length === 0) {
        throw new Error(
            'DATATABLE_NO_PHONE_COLUMNS:这张表没有任何一列声明 priority。' +
            '手机上要留下哪几列是【这张表自己的判断】,组件不替它猜 —— ' +
            '猜「前 N 列」在有些表上一定挑错。给身份列与那个要紧的数字列加 priority: true,' +
            '或者显式声明 phone={{ mode: \'scroll\', why: \'…\' }} 并写下理由。'
        )
    }

    // ★ 又一条按名拒绝:客户端模式下声称可排、却没给比较器,是一个【按下去没反应】的表头。
    //   静默忽略它,人会以为自己排过了 —— 与"排了它没拿到的东西"是同一种谎。
    if (props.sorting?.mode === 'client') {
        const liar = columns.find((c) => c.sortable === true && !c.sortValue)
        if (liar) {
            throw new Error(
                `DATATABLE_SORTABLE_WITHOUT_COMPARATOR:列「${liar.key}」声明了 sortable,` +
                '却没有给 sortValue。客户端排序是本组件自己做的,没有比较器它就排不了 —— ' +
                '而一个按下去没反应的表头,比一个不可点的表头更坏。'
            )
        }
    }

    const [sort, setSort] = React.useState<{ key: string; dir: Dir }>({ key: '', dir: 'none' })
    const [q, setQ] = React.useState('')
    const [page, setPage] = React.useState(0)
    const [hidden, setHidden] = React.useState<ReadonlySet<string>>(() => new Set())
    const [open, setOpen] = React.useState<ReadonlySet<string>>(() => new Set())

    const shownCols = columns.filter((c) => !hidden.has(c.key))

    // ── 筛选 → 排序 → 分页,顺序是固定的 ────────────────────────────────────
    const filtered = React.useMemo(() => {
        if (!filter || !q.trim()) return rows
        return rows.filter((r) => filter.match(r, q.trim()))
    }, [rows, filter, q])

    const sorted = React.useMemo(() => {
        // 服务端模式下【本组件一行都不重排】—— 顺序是数据库给的,重排会把它毁掉。
        if (!clientSort || sort.dir === 'none') return filtered
        const col = columns.find((c) => c.key === sort.key)
        if (!col?.sortValue) return filtered
        const get = col.sortValue
        const sign = sort.dir === 'asc' ? 1 : -1
        return [...filtered].sort((a, b) => {
            const va = get(a), vb = get(b)
            // 【空值永远排在最后,与方向无关】—— 一个空格子不是"最小的数",
            // 让它随方向在两头跳,会让人以为那里有一个真的极值。
            if (va == null && vb == null) return 0
            if (va == null) return 1
            if (vb == null) return -1
            if (typeof va === 'number' && typeof vb === 'number') return (va - vb) * sign
            return String(va).localeCompare(String(vb), 'zh-Hans-CN', { numeric: true }) * sign
        })
    }, [filtered, clientSort, sort, columns])

    const pageCount = pageSize ? Math.max(1, Math.ceil(sorted.length / pageSize)) : 1
    const safePage = Math.min(page, pageCount - 1)
    const visible = pageSize ? sorted.slice(safePage * pageSize, safePage * pageSize + pageSize) : sorted

    // 【客户端模式永远不会走到这里】类型不允许它拿部分数据,所以没有"排了一半"这回事。
    // 服务端模式下这一行只是【报量】,不是警告:排序看得见全体。
    const cov = sorting?.coverage
    const partial = cov && cov !== 'complete' ? cov : null
    const noticeId = React.useId()

    const toggleSort = (key: string) => {
        setSort((s) => (s.key === key ? { key, dir: DIR_NEXT[s.dir] } : { key, dir: 'asc' }))
        setPage(0)
    }
    const toggleRow = (k: string) =>
        setOpen((s) => { const n = new Set(s); n.has(k) ? n.delete(k) : n.add(k); return n })

    return (
        <div className={cn('w-full', className)}>
            {/* ── 表上方的控件区 ──────────────────────────────────────────── */}
            {(filter || columnToggle || partial) && (
                <div className="mb-2 flex flex-wrap items-center gap-2">
                    {filter && (
                        <input
                            type="search"
                            value={q}
                            onChange={(e) => { setQ(e.target.value); setPage(0) }}
                            aria-label={filter.label}
                            placeholder={filter.label}
                            className="base-pressable min-w-0 flex-1 rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-2.5 py-1.5 text-sm text-[color:var(--brand-text)] outline-none focus-visible:border-[color:var(--brand-ring)]"
                        />
                    )}
                    {columnToggle && (
                        <details className="relative">
                            <summary className="base-pressable cursor-pointer list-none rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-2.5 py-1.5 text-sm text-[color:var(--brand-text)]">
                                列 {shownCols.length}/{columns.length}
                            </summary>
                            <div className="nav-glass absolute right-0 z-20 mt-1 min-w-44 rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] p-2 shadow-md">
                                {columns.map((c) => (
                                    <label key={c.key} className="flex items-center gap-2 px-1 py-1 text-sm text-[color:var(--brand-text)]">
                                        <input
                                            type="checkbox"
                                            checked={!hidden.has(c.key)}
                                            onChange={() => setHidden((s) => {
                                                const n = new Set(s); n.has(c.key) ? n.delete(c.key) : n.add(c.key); return n
                                            })}
                                        />
                                        {c.header}
                                    </label>
                                ))}
                            </div>
                        </details>
                    )}
                    {/* ★ 只在服务端模式下出现,而且它【报量,不报警】—— 排序看得见全体。 */}
                    {partial && (
                        <p id={noticeId} className="w-full text-xs text-[color:var(--brand-muted-text)]">
                            这一屏 {partial.shown} 行,全体 {partial.total} 行 ——
                            排序在数据库里对【全体】做,所以第一页就是全体的前 {partial.shown} 名。
                        </p>
                    )}
                </div>
            )}

            <div className="w-full overflow-x-auto">
                <table
                    data-slot="data-table"
                    // ★【手机上用 table-fixed,桌面上恢复 auto】390px 实测逼出来的一条 ★
                    //   auto 布局下,任何一个格子都能把整列撑宽 —— 实测一枚
                    //   「无库存 · out of stock」的小片就把第三列撑到 260px,
                    //   把物料那一列挤成【每行一个字】。在只剩三列的宽度里,
                    //   一个格子有权决定整列宽度是不行的。
                    //   fixed 之下列宽由表宽平分(或由列自己声明),没有哪个格子说了算。
                    //   桌面上列多、内容短,auto 排得更好,所以 sm 以上换回去。
                    className="w-full caption-bottom border-collapse text-sm table-fixed sm:table-auto"
                    aria-describedby={partial ? noticeId : undefined}
                >
                    {caption && <caption className="mt-2 text-sm text-[color:var(--brand-muted-text)]">{caption}</caption>}
                    <thead>
                        <tr className="border-b-2 border-[color:var(--brand-ocean)]">
                            {/* 手机上多一格放展开钮;桌面上它不存在。 */}
                            {/* scroll 模式下没有展开钮,所以也不留这一格。 */}
                            {!phoneScroll && <th className="w-8 px-1 sm:hidden" />}
                            {shownCols.map((c) => {
                                const activeClient = clientSort && sort.key === c.key && sort.dir !== 'none'
                                const activeServer = serverSort?.active?.key === c.key
                                const active = activeClient || activeServer
                                const dir = activeServer ? serverSort!.active!.dir
                                    : activeClient ? (sort.dir as 'asc' | 'desc') : null
                                // 客户端模式要比较器;服务端模式只要一句"这一列可以排"。
                                const canSort = clientSort ? !!c.sortValue
                                    : !!serverSort && (c.sortable === true || !!c.sortValue)
                                return (
                                    <th
                                        key={c.key}
                                        scope="col"
                                        aria-sort={active ? (dir === 'asc' ? 'ascending' : 'descending') : undefined}
                                        className={cn(
                                            'px-3 py-2.5 align-middle font-medium text-[color:var(--brand-text)]',
                                            // 表头【桌面上不折行】—— 实测 1280px 下「库存状态」被折成
                                            // 每行一个字。手机上不加这一条:那里是 table-fixed,
                                            // 列宽是平分的,nowrap 会让表头顶出格子。
                                            'sm:whitespace-nowrap',
                                            c.align === 'right' ? 'text-right' : 'text-left',
                                            // ★ 非 priority 的列在手机上不出现在表里 —— 它们在展开区。
                                            !isPhoneCol(c) && 'hidden sm:table-cell',
                                            c.className
                                        )}
                                    >
                                        {canSort && serverSort ? (
                                            // 服务端模式:表头是一条【链接】—— 与那 8 页今天的做法逐字同形,
                                            // 于是转换刀换掉的只是外观,不是那条已经正确的排序。
                                            <a
                                                href={serverSort.href(c.key, activeServer && dir === 'asc' ? 'desc' : 'asc')}
                                                className="base-pressable inline-flex items-center gap-1 rounded px-1 -mx-1 hover:bg-[color:var(--brand-muted)]"
                                            >
                                                {c.header}
                                                <span aria-hidden className="text-[color:var(--brand-muted-text)]">
                                                    {active ? (dir === 'asc' ? '▲' : '▼') : '↕'}
                                                </span>
                                            </a>
                                        ) : canSort ? (
                                            <button
                                                type="button"
                                                onClick={() => toggleSort(c.key)}
                                                className="base-pressable inline-flex items-center gap-1 rounded px-1 -mx-1 hover:bg-[color:var(--brand-muted)]"
                                            >
                                                {c.header}
                                                <span aria-hidden className="text-[color:var(--brand-muted-text)]">
                                                    {active ? (dir === 'asc' ? '▲' : '▼') : '↕'}
                                                </span>
                                            </button>
                                        ) : c.header}
                                    </th>
                                )
                            })}
                        </tr>
                    </thead>
                    <tbody>
                        {visible.length === 0 && (
                            <tr>
                                <td colSpan={shownCols.length + (phoneScroll ? 0 : 1)} className="px-3 py-8 text-center text-[color:var(--brand-muted-text)]">
                                    {empty ?? '没有符合的行'}
                                </td>
                            </tr>
                        )}
                        {visible.map((row) => {
                            const k = rowKey(row)
                            const isOpen = open.has(k)
                            const restCols = phoneScroll ? [] : shownCols.filter((c) => !c.priority)
                            return (
                                <React.Fragment key={k}>
                                    <tr className="border-b border-[color:var(--brand-border)]">
                                        {!phoneScroll && <td className="px-1 align-middle sm:hidden">
                                            {restCols.length > 0 && (
                                                <button
                                                    type="button"
                                                    onClick={() => toggleRow(k)}
                                                    aria-expanded={isOpen}
                                                    aria-label={phoneExpandLabel}
                                                    className="base-pressable flex h-7 w-7 items-center justify-center rounded text-[color:var(--brand-muted-text)] hover:bg-[color:var(--brand-muted)]"
                                                >
                                                    <span aria-hidden className={cn('transition-transform', isOpen && 'rotate-90')}>›</span>
                                                </button>
                                            )}
                                        </td>}
                                        {shownCols.map((c) => (
                                            <td
                                                key={c.key}
                                                className={cn(
                                                    'px-3 py-2.5 align-middle text-[color:var(--brand-text)] break-words',
                                                    c.align === 'right' ? 'text-right tabular-nums' : 'text-left',
                                                    !isPhoneCol(c) && 'hidden sm:table-cell',
                                                    c.className
                                                )}
                                            >
                                                {c.render(row)}
                                            </td>
                                        ))}
                                    </tr>
                                    {/* ── 展开区:其余各列,带标签。只在手机上存在。 ────────── */}
                                    {isOpen && restCols.length > 0 && (
                                        <tr className="border-b border-[color:var(--brand-border)] sm:hidden">
                                            {/* colSpan 跟着【看得见的】priority 列走 ——
                                                用 priorityCols.length 是错的:列显隐关掉一个
                                                priority 列之后,展开区就会比表宽出一格。 */}
                                            <td colSpan={shownCols.filter((c) => c.priority).length + 1}
                                                className="bg-[color:var(--brand-muted)] px-3 py-2">
                                                <dl className="base-reveal grid grid-cols-[minmax(6rem,auto)_1fr] gap-x-3 gap-y-1.5 text-sm">
                                                    {restCols.map((c) => (
                                                        <React.Fragment key={c.key}>
                                                            <dt className="text-[color:var(--brand-muted-text)]">{c.phoneLabel ?? c.header}</dt>
                                                            <dd className="text-[color:var(--brand-text)]">{c.render(row)}</dd>
                                                        </React.Fragment>
                                                    ))}
                                                </dl>
                                            </td>
                                        </tr>
                                    )}
                                </React.Fragment>
                            )
                        })}
                    </tbody>
                </table>
            </div>

            {pageSize && sorted.length > pageSize && (
                <div className="mt-2 flex items-center justify-between gap-2 text-sm text-[color:var(--brand-muted-text)]">
                    <span>
                        第 {safePage * pageSize + 1}–{Math.min((safePage + 1) * pageSize, sorted.length)} 行,
                        共 {sorted.length} 行
                    </span>
                    <span className="flex gap-1">
                        <button
                            type="button" disabled={safePage === 0} onClick={() => setPage(safePage - 1)}
                            className="base-pressable rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-2.5 py-1 disabled:cursor-not-allowed disabled:bg-[color:var(--brand-disabled-bg)] disabled:text-[color:var(--brand-disabled-text)]"
                        >上一页</button>
                        <button
                            type="button" disabled={safePage >= pageCount - 1} onClick={() => setPage(safePage + 1)}
                            className="base-pressable rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-2.5 py-1 disabled:cursor-not-allowed disabled:bg-[color:var(--brand-disabled-bg)] disabled:text-[color:var(--brand-disabled-text)]"
                        >下一页</button>
                    </span>
                </div>
            )}
        </div>
    )
}
