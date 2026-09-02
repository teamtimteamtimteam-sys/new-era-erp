// app/tools/calendar/page.tsx — 跨模块日历(TOOLS-1 ②)。**只读。**
//
// ════════════════════════════════════════════════════════════════════════════
// 【它是一个【看】的地方,不是一个【改】的地方 —— 而那是一个设计决定,不是省事】
// 只读换来一件很值钱的事:**这一页不需要自己的权限模型**。
// 每一条查询都以读者自己的会话发出,于是一件事出现在日历上,当且仅当
// 他本来就能在它自己的模块里看见它。点一下,回到那件事自己的页面去改。
// 论证与逐来源的实测写在 ./sources.ts 的抬头。
//
// 【没有 requireModule】—— 刻意的。挡人的不是这一页,是每一个来源自己。
// 一个零权限的读者打开它,会看到一个【只有公共假期】的月历:那不是"受限",
// 那正是他能看见的全部,而公共假期本来就是人人可读的(RLS 是 USING(true))。
// ════════════════════════════════════════════════════════════════════════════
import { getTranslations, getLocale } from '@/lib/i18n/server'
import MonthGrid, { DOW_KEYS } from '@/app/components/calendar/MonthGrid'
import { loadMonth, CALENDAR_KINDS, KIND_COLOR } from './sources'

export default async function ToolsCalendarPage({
    searchParams,
}: { searchParams: Promise<{ month?: string; kind?: string }> }) {
    const sp = await searchParams
    const t = await getTranslations()
    const locale = await getLocale()

    // 【月份从 URL 来,缺省是【库的今天】的那个月】——
    // 这里用服务器的 now();系统的"今天"由数据库定义(fixture 钉过 SGT),
    // 而这一页只是选一个默认视图,不参与任何算术,所以够用。
    const now = new Date()
    const month = /^\d{4}-\d{2}$/.test(sp.month ?? '')
        ? sp.month! : `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`

    const { items, failures, ms } = await loadMonth(month, locale)
    const active: string | null = CALENDAR_KINDS.includes(sp.kind as never) ? sp.kind! : null
    const shown = active ? items.filter((i) => i.kind === active) : items

    const [y, m] = month.split('-').map(Number)
    const prev = new Date(y, m - 2, 1)
    const next = new Date(y, m, 1)
    const mk = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
    const link = (mo: string, k: string | null) =>
        `/tools/calendar?month=${mo}${k ? `&kind=${k}` : ''}`

    const kinds = CALENDAR_KINDS.map((k) => ({
        key: k, label: t('calendar.kind.' + k), color: KIND_COLOR[k],
    }))

    return (
        <div className="p-6 max-w-5xl">
            <h1 className="text-2xl font-semibold mb-1">{t('calendar.title')}</h1>
            <p className="text-sm mb-4" style={{ color: 'var(--brand-muted-text)' }}>{t('calendar.intro')}</p>

            <div className="mb-3 flex flex-wrap items-center gap-2 text-sm">
                <a className="rounded border px-2 py-1" href={link(mk(prev), active)}>←</a>
                <span className="font-mono font-semibold">{month}</span>
                <a className="rounded border px-2 py-1" href={link(mk(next), active)}>→</a>
                {/* 【按类型筛选】—— 每一类都在,包括今天是零行的那些:
                    一个"这个月没有请假"与"请假这一类不存在"必须分得开。 */}
                <span className="ml-3">{t('calendar.filter')}:</span>
                <a className="rounded border px-2 py-1" href={link(month, null)}
                   style={!active ? { background: 'var(--brand-accent)' } : undefined}>
                    {t('calendar.allKinds')}
                </a>
                {CALENDAR_KINDS.map((k) => (
                    <a key={k} className="rounded border px-2 py-1" href={link(month, k)}
                       style={active === k ? { background: 'var(--brand-accent)' } : undefined}>
                        {t('calendar.kind.' + k)}
                    </a>
                ))}
            </div>

            {/* ★【取数失败要说出来】★ 一次失败的查询与"这一类今天没有事"
                在日历上长得一模一样,而含义相反。 */}
            {failures.length > 0 && (
                <p className="mb-3 rounded px-3 py-2 text-sm" data-calendar-failures="1"
                   style={{ background: 'var(--brand-accent)', color: 'var(--brand-destructive)' }}>
                    {t('calendar.sourceFailed', { list: failures.join(' · ') })}
                </p>
            )}

            <MonthGrid
                month={month}
                items={shown}
                kinds={kinds}
                emptyText={active ? t('calendar.emptyKind') : t('calendar.empty')}
                dayNames={DOW_KEYS.map((d) => t('calendar.dow.' + d))}
            />

            {/* 【出处 + 代价】—— 七个来源、并发取数、这一次花了多少毫秒。
                CHART-1 量出过一页 24.9 秒,所以这个数字印在屏幕上,不藏在报告里。 */}
            <p className="mt-3 text-xs" style={{ color: 'var(--brand-muted-text)' }}>
                {t('calendar.basis', { n: String(items.length), ms: String(ms) })}
            </p>
        </div>
    )
}
