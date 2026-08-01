// app/hr/leave/balances/page.tsx
// 全员年假余额一览 —— HR 审批之前看的就是这一张。
// 【90 天内到期的天数高亮】:那是"再不休就烂掉"的部分,提前看见才来得及安排。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import LeaveSubnav from '../LeaveSubnav'

export default async function BalancesPage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: emps } = await supabase
        .from('employees').select('id, code, legal_name, work_category')
        .is('deleted_at', null).neq('employment_status', 'separated').order('code')

    const today = new Date()
    const horizon = new Date(today.getTime() + 90 * 86400000).toISOString().slice(0, 10)

    const rows = await Promise.all(
        (emps ?? []).map(async (e) => {
            const { data } = await supabase.rpc('leave_balance', {
                p_employee_id: e.id, p_leave_type_code: 'annual',
            })
            const b = data as {
                granted: number; consumed: number; expired: number; available: number
                breakdown: { remaining: number; expires_on: string | null; status: string }[]
            } | null
            const expiringSoon = (b?.breakdown ?? [])
                .filter((x) => x.status === 'active' && x.expires_on && x.expires_on <= horizon)
                .reduce((s, x) => s + Number(x.remaining), 0)
            return { e, b, expiringSoon }
        })
    )

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <Subnav />
            <LeaveSubnav />
            <p className="text-sm text-gray-600 mb-4">{t('leave.balancesIntro')}</p>
            <table className="w-full border-collapse text-sm">
                <thead>
                    <tr className="bg-gray-50 text-left">
                        <th className="border border-gray-300 px-3 py-2">{t('leave.employee')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('leave.granted')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('leave.taken')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('leave.available')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('leave.expiringSoon')}</th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map(({ e, b, expiringSoon }) => (
                        <tr key={e.id}>
                            <td className="border border-gray-300 px-3 py-2">{e.code} — {e.legal_name}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{b?.granted ?? 0}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{b?.consumed ?? 0}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono font-medium">{b?.available ?? 0}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                {expiringSoon > 0 ? (
                                    <span className="rounded bg-amber-100 px-2 py-0.5 text-amber-800">{expiringSoon}</span>
                                ) : '—'}
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>
        </div>
    )
}
