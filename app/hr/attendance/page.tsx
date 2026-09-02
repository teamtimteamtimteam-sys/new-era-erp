// app/hr/attendance/page.tsx
// ATTEND-1:考勤底稿列表 —— 一个月一行。
//
// 【这一页的读者要一眼看出的两件事】
//   ① 这个月【记满了没有】(未记行数,而不是"加班工时是不是 0");
//   ② 这个月的工资【过账了没有】—— 过了就不能再重开它的依据。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import OpenPeriodForm from './OpenPeriodForm'

const STATUS_CLS: Record<string, string> = {
    open: 'bg-amber-100 text-amber-800',
    complete: 'bg-green-100 text-green-800',
}

export default async function AttendancePeriodsPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const rows = mustRows(
        await supabase
            .from('attendance_period_status')
            .select('period_id, code, period_month, status, line_count, unrecorded_count, ot_normal_hours, ot_rest_day_hours, ot_public_holiday_hours, unpaid_days, payroll_posted')
            .order('period_month', { ascending: false }),
    )

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-1">{t('attendance.title')}</h1>
            {/* 【这张底稿不算工资】—— 政策 7.1:计算在服务商那边。
                把这句话摆在页面顶上,是为了让读者一开始就不去找一个不存在的数字。 */}
            <p className="text-sm text-gray-500 mb-6">{t('attendance.subtitle')}</p>

            <OpenPeriodForm />

            {rows.length === 0 ? (
                <p className="text-sm text-gray-500">{t('attendance.empty')}</p>
            ) : (
                <table className="w-full text-sm border-collapse">
                    <thead>
                        <tr className="border-b text-left text-gray-600">
                            <th className="py-2 pr-3">{t('attendance.colCode')}</th>
                            <th className="py-2 pr-3">{t('attendance.colStatus')}</th>
                            <th className="py-2 pr-3 text-right">{t('attendance.colLines')}</th>
                            <th className="py-2 pr-3 text-right">{t('attendance.colUnrecorded')}</th>
                            <th className="py-2 pr-3 text-right">{t('attendance.colOtNormal')}</th>
                            <th className="py-2 pr-3 text-right">{t('attendance.colOtRestDay')}</th>
                            <th className="py-2 pr-3 text-right">{t('attendance.colOtHoliday')}</th>
                            <th className="py-2 pr-3 text-right">{t('attendance.colUnpaidDays')}</th>
                            <th className="py-2 pr-3">{t('attendance.colPayroll')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.period_id} className="border-b hover:bg-gray-50">
                                <td className="py-2 pr-3">
                                    <Link className="text-blue-600 hover:underline" href={`/hr/attendance/${r.period_id}`}>
                                        {r.code}
                                    </Link>
                                </td>
                                <td className="py-2 pr-3">
                                    <span className={'rounded px-2 py-0.5 text-xs ' + (STATUS_CLS[r.status ?? ''] ?? 'bg-gray-100 text-gray-600')}>
                                        {t('attendance.status.' + r.status)}
                                    </span>
                                </td>
                                <td className="py-2 pr-3 text-right">{r.line_count}</td>
                                {/* 【未记行数】而不是"工时之和"—— 后者把"记了、是零"与"没人记过"混成一件事 */}
                                <td className={'py-2 pr-3 text-right ' + ((r.unrecorded_count ?? 0) > 0 ? 'text-amber-700 font-medium' : 'text-gray-400')}>
                                    {r.unrecorded_count}
                                </td>
                                <td className="py-2 pr-3 text-right">{r.ot_normal_hours}</td>
                                <td className="py-2 pr-3 text-right">{r.ot_rest_day_hours}</td>
                                <td className="py-2 pr-3 text-right">{r.ot_public_holiday_hours}</td>
                                <td className="py-2 pr-3 text-right">{r.unpaid_days}</td>
                                <td className="py-2 pr-3 text-xs text-gray-600">
                                    {r.payroll_posted ? t('attendance.payrollPosted') : '—'}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </div>
    )
}
