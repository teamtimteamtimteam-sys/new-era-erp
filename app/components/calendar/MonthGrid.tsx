// app/components/calendar/MonthGrid.tsx — 月历的【那一份】实现。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【一份实现,两个调用方】★★(TOOLS-1 ②,Tim 的裁定)
//   · /hr/leave/calendar   —— 团队请假 + 公共假期(它先有,本刀把它搬上来)
//   · /tools/calendar      —— 跨模块的只读日历
// 建第二个月历是这个仓库付过【四次】账的那个形状(AGENTS.md 的预览规则:
// 两份实现在写下来那天一致,之后悄悄分开)。日历尤其如此 ——
// "这个月有几天""周几开头""跨月的条目算不算" 每一条都能各自答错。
//
// ★【手机:窄屏列表,宽屏网格 —— 组织架构图的先例】★
// 390px 装不下 7 列 × 6 行的网格:要么字小到看不清,要么要人左右拖。
// 所以窄屏渲染成【按日期分组的列表,只列有事的那几天】——
// 一个月历在手机上本来就该是"这个月有什么事",不是"把方格缩小"。
// **两块都在 DOM 里**,靠 CSS 显隐 —— 与组织架构图同一条:
// 内容断言因此一次请求就验得到两种渲染,而不需要一个会改视口的浏览器。
//
// 【它不取数、不判权限】它只画传进来的东西。取数与"谁看得见什么"住在调用方,
// 而那正是 ② 的设计:**日历没有自己的权限模型** —— 每一项按它自己家那个模块
// 的可见性出现或不出现,所以过滤发生在取数那一层,不在这里。
// ════════════════════════════════════════════════════════════════════════════

/**
 * 星期名的键 —— 【也是 check-i18n 的真源】。
 * 从周日(0)开始,与 JS 的 Date#getDay() 一致;组件按 weekStartsMonday 自己转。
 */
export const DOW_KEYS = ['0', '1', '2', '3', '4', '5', '6'] as const

export type CalendarItem = {
    /** YYYY-MM-DD */
    date: string
    /** 来源键 —— 用来筛选与配色;文案由调用方给 */
    kind: string
    label: string
    /** 点它去哪 —— ② 的裁定:日历是【看】的地方,点一下回到那件事自己的页面 */
    href?: string
}

/** 一种来源在屏幕上长什么样。调用方给,组件不认识业务。 */
export type CalendarKind = { key: string; label: string; color: string }

function daysInMonth(year: number, month1: number): number {
    return new Date(year, month1, 0).getDate()
}

/**
 * @param month  'YYYY-MM'
 * @param weekStartsMonday 周一开头(新加坡与中国的习惯)。**显式传,不猜。**
 */
export default function MonthGrid({
    month, items, kinds, emptyText, weekStartsMonday = true, dayNames,
}: {
    month: string
    items: CalendarItem[]
    kinds: CalendarKind[]
    /** 整个月一件事都没有时说什么 —— D5:空要说出来,不是留白 */
    emptyText: string
    weekStartsMonday?: boolean
    /** 七个星期名,从周日开始给(组件按 weekStartsMonday 自己转) */
    dayNames: readonly string[]
}) {
    const [y, m] = month.split('-').map(Number)
    const total = daysInMonth(y, m)
    const firstDow = new Date(y, m - 1, 1).getDay() // 0=周日
    const lead = weekStartsMonday ? (firstDow + 6) % 7 : firstDow
    const heads = weekStartsMonday
        ? [...dayNames.slice(1), dayNames[0]]
        : dayNames

    const byDate = new Map<string, CalendarItem[]>()
    for (const it of items) {
        const arr = byDate.get(it.date)
        if (arr) arr.push(it)
        else byDate.set(it.date, [it])
    }
    const colorOf = new Map(kinds.map((k) => [k.key, k.color]))
    const dateStr = (d: number) => `${month}-${String(d).padStart(2, '0')}`

    const Pill = ({ it }: { it: CalendarItem }) => {
        const style = { background: colorOf.get(it.kind) ?? 'var(--brand-muted)', color: 'var(--brand-text)' }
        const cls = 'block truncate rounded px-1 py-0.5 text-[11px] leading-tight'
        return it.href
            ? <a href={it.href} className={cls + ' hover:underline'} style={style} title={it.label}>{it.label}</a>
            : <span className={cls} style={style} title={it.label}>{it.label}</span>
    }

    // 有事的日子,升序 —— 窄屏用
    const busyDays = [...byDate.keys()].sort()

    return (
        <div data-month-grid={month}>
            {/* ══ 图例:哪种颜色是什么 ══════════════════════════════════════ */}
            <div className="mb-3 flex flex-wrap gap-x-4 gap-y-1 text-xs">
                {kinds.map((k) => (
                    <span key={k.key} className="inline-flex items-center gap-1">
                        <span className="inline-block h-3 w-3 rounded" style={{ background: k.color }} />
                        {k.label}
                    </span>
                ))}
            </div>

            {items.length === 0 && (
                <p className="rounded px-3 py-2 text-sm" data-calendar-empty="1"
                   style={{ background: 'var(--brand-muted)', color: 'var(--brand-muted-text)' }}>
                    {emptyText}
                </p>
            )}

            {items.length > 0 && (
                <>
                    {/* ══ 宽屏:七列网格 ═══════════════════════════════════ */}
                    <div className="hidden md:block" data-calendar-view="grid">
                        <div className="grid grid-cols-7 gap-px rounded overflow-hidden"
                             style={{ background: 'var(--brand-border)' }}>
                            {heads.map((d) => (
                                <div key={d} className="px-2 py-1 text-center text-[11px] font-semibold"
                                     style={{ background: 'var(--brand-muted)', color: 'var(--brand-muted-text)' }}>
                                    {d}
                                </div>
                            ))}
                            {Array.from({ length: lead }, (_, i) => (
                                <div key={`lead-${i}`} style={{ background: 'var(--brand-bg)' }} />
                            ))}
                            {Array.from({ length: total }, (_, i) => {
                                const day = i + 1
                                const ds = dateStr(day)
                                const its = byDate.get(ds) ?? []
                                return (
                                    <div key={ds} className="min-h-20 p-1 align-top"
                                         style={{ background: 'var(--brand-surface)' }}>
                                        <div className="mb-0.5 text-[11px]" style={{ color: 'var(--brand-muted-text)' }}>{day}</div>
                                        <div className="flex flex-col gap-0.5">
                                            {its.map((it, n) => <Pill key={`${ds}-${n}`} it={it} />)}
                                        </div>
                                    </div>
                                )
                            })}
                        </div>
                    </div>

                    {/* ══ 窄屏(390px):只列【有事的那几天】 ═══════════════ */}
                    {/* 把空方格搬到手机上没有任何价值 —— 手机要回答的是
                        「这个月有什么事」,而不是「这个月长什么样」。 */}
                    <ul className="md:hidden" data-calendar-view="list">
                        {busyDays.map((ds) => (
                            <li key={ds} className="border-b py-2" style={{ borderColor: 'var(--brand-border)' }}>
                                <div className="mb-1 font-mono text-xs" style={{ color: 'var(--brand-muted-text)' }}>{ds}</div>
                                <div className="flex flex-col gap-1">
                                    {(byDate.get(ds) ?? []).map((it, n) => <Pill key={`${ds}-l-${n}`} it={it} />)}
                                </div>
                            </li>
                        ))}
                    </ul>
                </>
            )}
        </div>
    )
}
