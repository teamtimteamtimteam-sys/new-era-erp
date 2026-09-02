// app/hr/leave/calendar/page.tsx — 团队请假月历。公共假期也画上去(看排期时那是同一件事)。
//
// ★★【TOOLS-1 ②:本页改用【共享的】月历组件】★★
// 从前它自己画一套 7 列网格。工具日历要的是同一样东西,而建第二个月历
// 正是这个仓库付过四次账的形状(AGENTS.md 的预览规则)。
// 现在:app/components/calendar/MonthGrid.tsx 一份实现,两个调用方。
//
// ★【搬上去顺手修好了一个【一直存在】的缺陷】★
//   旧写法把 1..N 号直接铺进 `grid-cols-7`,**没有前导空格**——
//   于是 1 号永远落在第一列,不管它其实是星期几。整张月历的列
//   与真实星期【从来没有对齐过】,而没有任何东西会说。
//   共享组件按当月 1 号的星期算前导空格(并且按周一开头),所以列对上了。
//   **这不是本刀新加的功能,是搬家时露出来的一处旧账。**
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import LeaveSubnav from '../LeaveSubnav'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import MonthGrid, { DOW_KEYS, type CalendarItem } from '@/app/components/calendar/MonthGrid'
import { expandRange } from '@/app/tools/calendar/sources'

export default async function LeaveCalendarPage({
    searchParams,
}: { searchParams: Promise<{ month?: string }> }) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const sp = await searchParams
    const now = new Date()
    const month = sp.month ?? `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`
    const first = `${month}-01`
    const [y, m] = month.split('-').map(Number)
    const last = `${month}-${String(new Date(y, m, 0).getDate()).padStart(2, '0')}`

    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const [leaveRes, holRes] = await Promise.all([
        supabase.from('leave_calendar').select('*')
            .lte('start_date', last).gte('end_date', first).order('start_date'),
        supabase.from('public_holidays').select('holiday_date, name_en, name_zh')
            .eq('is_active', true).gte('holiday_date', first).lte('holiday_date', last),
    ])

    const items: CalendarItem[] = []
    for (const h of mustRows(holRes)) {
        items.push({
            date: String(h.holiday_date), kind: 'holiday',
            label: String(locale === 'zh' ? h.name_zh : h.name_en),
        })
    }
    // 【请假是区间】—— 铺满它覆盖的每一天,并裁到本月之内。
    // 旧写法用 `start<=d && end>=d` 逐格过滤,效果相同;换成共享的 expandRange
    // 是为了让两个日历对"跨月的假算几天"这件事只有一个答案。
    for (const r of mustRows(leaveRes)) {
        for (const d of expandRange(String(r.start_date), String(r.end_date), first, last)) {
            items.push({
                date: d, kind: 'leave',
                label: String(r.employee_code ?? '—'),
                href: '/hr/leave',
            })
        }
    }

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <LeaveSubnav />

            <form method="get" className="mb-4 flex items-end gap-2">
                <label className="text-sm">
                    {t('leave.month')}
                    <input type="month" name="month" defaultValue={month}
                           className="mt-1 block border border-gray-300 rounded px-2 py-1 text-sm" />
                </label>
                <button type="submit" className="border border-gray-300 rounded px-3 py-1 text-sm">
                    {t('leave.filter')}
                </button>
            </form>

            <MonthGrid
                month={month}
                items={items}
                kinds={[
                    { key: 'holiday', label: t('calendar.kind.holiday'), color: 'var(--brand-accent)' },
                    { key: 'leave', label: t('calendar.kind.leave'), color: 'var(--brand-forest-fill)' },
                ]}
                emptyText={t('calendar.empty')}
                dayNames={DOW_KEYS.map((d) => t('calendar.dow.' + d))}
            />
        </div>
    )
}
