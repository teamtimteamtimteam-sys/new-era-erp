// app/hr/leave/calendar/page.tsx
// 团队请假月历。公共假期也画上去 —— 看排期的时候那是同一件事。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import LeaveSubnav from '../LeaveSubnav'
import { mustRows } from '@/lib/db-helpers'

export default async function LeaveCalendarPage({
    searchParams,
}: { searchParams: Promise<{ month?: string }> }) {
    const sp = await searchParams
    const now = new Date()
    const month = sp.month ?? `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`
    const first = `${month}-01`
    const firstDate = new Date(first + 'T00:00:00')
    const lastDate = new Date(firstDate.getFullYear(), firstDate.getMonth() + 1, 0)
    const last = lastDate.toISOString().slice(0, 10)

    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const [leaveRes, holRes] = await Promise.all([
        supabase.from('leave_calendar').select('*')
            .lte('start_date', last).gte('end_date', first).order('start_date'),
        supabase.from('public_holidays').select('holiday_date, name_en, name_zh')
            .eq('is_active', true).gte('holiday_date', first).lte('holiday_date', last),
    ])

    const holidayByDate = new Map((mustRows(holRes)).map((h) => [h.holiday_date, h]))
    const days: string[] = []
    for (let d = 1; d <= lastDate.getDate(); d++) {
        days.push(`${month}-${String(d).padStart(2, '0')}`)
    }

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <Subnav />
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

            <div className="grid grid-cols-7 gap-px bg-gray-200 border border-gray-200 text-xs">
                {days.map((d) => {
                    const dow = new Date(d + 'T00:00:00').getDay()
                    const hol = holidayByDate.get(d)
                    const on = (mustRows(leaveRes)).filter(
                        (r) => (r.start_date ?? '') <= d && (r.end_date ?? '') >= d
                    )
                    return (
                        <div key={d} className={'min-h-20 bg-white p-1 ' + (dow === 0 || dow === 6 ? 'bg-gray-50' : '')}>
                            <div className="flex items-baseline justify-between">
                                <span className="font-mono text-gray-500">{d.slice(-2)}</span>
                                {hol && (
                                    <span className="rounded bg-red-100 px-1 text-[10px] text-red-800">
                                        {locale === 'zh' ? hol.name_zh : hol.name_en}
                                    </span>
                                )}
                            </div>
                            {on.map((r) => (
                                <div key={r.request_id} className="mt-0.5 truncate rounded bg-blue-100 px-1 text-[10px] text-blue-900"
                                     title={`${r.employee_code} ${locale === 'zh' ? r.leave_type_zh : r.leave_type_en}`}>
                                    {r.employee_code}
                                </div>
                            ))}
                        </div>
                    )
                })}
            </div>
        </div>
    )
}
