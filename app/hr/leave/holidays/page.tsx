// app/hr/leave/holidays/page.tsx
// 公共假期维护。【Tim 每年自己补】—— 农历与回历日期要等官方公布,不去算。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import LeaveSubnav from '../LeaveSubnav'
import HolidaysEditor, { type HolidayRow } from './HolidaysEditor'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function HolidaysPage({
    searchParams,
}: { searchParams: Promise<{ year?: string }> }) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const sp = await searchParams
    const year = Number(sp.year ?? new Date().getFullYear())
    const supabase = await createClient()
    const t = await getTranslations()
    const res = await supabase.from('public_holidays').select('*')
        .gte('holiday_date', `${year}-01-01`).lte('holiday_date', `${year}-12-31`)
        .order('holiday_date')
    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <LeaveSubnav />
            <form method="get" className="mb-4 flex items-end gap-2">
                <label className="text-sm">
                    {t('leave.leaveYear')}
                    <input type="number" name="year" defaultValue={year}
                           className="mt-1 block border border-gray-300 rounded px-2 py-1 text-sm w-28" />
                </label>
                <button type="submit" className="border border-gray-300 rounded px-3 py-1 text-sm">
                    {t('leave.filter')}
                </button>
            </form>
            <p className="text-sm text-gray-600 mb-4">{t('leave.holidaysIntro')}</p>
            <HolidaysEditor rows={mustRows(res) as HolidayRow[]} year={year} />
        </div>
    )
}
