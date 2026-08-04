// app/hr/page.tsx
// 人力资源概览 = 待处理事项看板。这块看板就是本模块值得占一个导航位的理由:
// 工作准证到期、试用期届满、培训证书到期,漏掉任何一件都是真实的麻烦
// (准证过期意味着不能合法上班)。
// 下面再给一小块在职人数摘要,读自 employee_directory。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from './Subnav'

type AlertRow = {
    alert_type: string
    severity: string
    employee_id: string | null
    employee_code: string
    employee_name: string
    subject: string
    due_date: string | null
    days_remaining: number | null
}

type DirectoryRow = {
    employment_status: string
    work_category: string
}

const SEVERITY_ORDER = ['expired', 'critical', 'warning'] as const

export default async function HrOverviewPage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const [alertsRes, dirRes] = await Promise.all([
        supabase
            .from('hr_alerts')
            .select('alert_type, severity, employee_id, employee_code, employee_name, subject, due_date, days_remaining')
            .order('due_date', { ascending: true }),
        supabase.from('employee_directory').select('employment_status, work_category'),
    ])

    const alerts = (alertsRes.data as unknown as AlertRow[] | null) ?? []
    const directory = (dirRes.data as unknown as DirectoryRow[] | null) ?? []

    // 在职人数:离职的不计入(他们仍在目录里,但不是"在职")
    const live = directory.filter((d) => d.employment_status !== 'separated')
    const byStatus = new Map<string, number>()
    for (const d of directory) byStatus.set(d.employment_status, (byStatus.get(d.employment_status) ?? 0) + 1)
    const byCategory = new Map<string, number>()
    for (const d of live) byCategory.set(d.work_category, (byCategory.get(d.work_category) ?? 0) + 1)

    const severityCls: Record<string, string> = {
        expired: 'bg-red-100 text-red-800 border-red-300',
        critical: 'bg-amber-100 text-amber-900 border-amber-300',
        warning: 'bg-gray-100 text-gray-700 border-gray-300',
    }
    const rowCls: Record<string, string> = {
        expired: 'text-red-700',
        critical: 'text-amber-800',
        warning: 'text-gray-600',
    }

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.overviewTitle')}</h1>

            <Subnav />

            <h2 className="text-xl font-bold mb-3">{t('hr.alertsTitle')}</h2>

            {alerts.length === 0 ? (
                <p className="text-sm text-gray-500 mb-8">{t('hr.noAlerts')}</p>
            ) : (
                <div className="space-y-4 mb-8">
                    {SEVERITY_ORDER.map((sev) => {
                        const rows = alerts.filter((a) => a.severity === sev)
                        if (rows.length === 0) return null
                        return (
                            <section key={sev} className={'border rounded p-4 ' + severityCls[sev]}>
                                <h3 className="font-bold mb-2">
                                    {t('hr.severity.' + sev)}
                                    <span className="ml-2 font-normal">({rows.length})</span>
                                </h3>
                                <table className="w-full border-collapse text-sm">
                                    <tbody>
                                        {rows.map((a) => (
                                            <tr key={a.alert_type + a.employee_id + a.subject + a.due_date}>
                                                <td className="py-1 pr-4 font-mono whitespace-nowrap">
                                                    {a.employee_id ? (
                                                        <Link
                                                            href={`/hr/employees/${a.employee_id}`}
                                                            className="text-blue-700 hover:underline"
                                                        >
                                                            {a.employee_code}
                                                        </Link>
                                                    ) : (
                                                        a.employee_code
                                                    )}
                                                </td>
                                                <td className="py-1 pr-4">{a.employee_name}</td>
                                                <td className="py-1 pr-4">{t('hr.alertType.' + a.alert_type)}</td>
                                                <td className="py-1 pr-4">{a.subject}</td>
                                                <td className="py-1 pr-4 whitespace-nowrap">{a.due_date}</td>
                                                <td className={'py-1 whitespace-nowrap ' + rowCls[sev]}>
                                                    {/* salary_not_set 没有期限:due_date 与 days_remaining 皆 NULL */}
                                                    {a.days_remaining === null
                                                        ? null
                                                        : a.days_remaining < 0
                                                          ? t('hr.overdueDays', { n: -a.days_remaining })
                                                          : t('hr.daysRemaining', { n: a.days_remaining })}
                                                </td>
                                            </tr>
                                        ))}
                                    </tbody>
                                </table>
                            </section>
                        )
                    })}
                </div>
            )}

            {/* 在职人数摘要 */}
            <h2 className="text-xl font-bold mb-3">{t('hr.headcount')}</h2>
            <div className="bg-gray-50 rounded p-4 flex flex-wrap gap-x-8 gap-y-2 text-sm">
                <div>
                    <span className="text-gray-600 mr-1">{t('hr.headcountTotal')}:</span>
                    <span className="font-mono font-medium">{live.length}</span>
                </div>
                {['probation', 'active', 'notice', 'separated'].map((s) =>
                    (byStatus.get(s) ?? 0) > 0 ? (
                        <div key={s}>
                            <span className="text-gray-600 mr-1">{t('hr.employmentStatus.' + s)}:</span>
                            <span className="font-mono">{byStatus.get(s)}</span>
                        </div>
                    ) : null
                )}
                {['office', 'shopfloor'].map((c) =>
                    (byCategory.get(c) ?? 0) > 0 ? (
                        <div key={c}>
                            <span className="text-gray-600 mr-1">{t('hr.workCategory.' + c)}:</span>
                            <span className="font-mono">{byCategory.get(c)}</span>
                        </div>
                    ) : null
                )}
            </div>
        </div>
    )
}
