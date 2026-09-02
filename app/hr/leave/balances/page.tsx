// app/hr/leave/balances/page.tsx
// 全员年假余额一览 —— HR 审批之前看的就是这一张。
// 【90 天内到期的天数高亮】:那是"再不休就烂掉"的部分,提前看见才来得及安排。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import LeaveSubnav from '../LeaveSubnav'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function BalancesPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    // 【批准人据此拍板,读不出来就必须报错】原本失败会渲染成 "0 天可用",
    // 那不是"没有数据",是一个凭空捏造的事实,而批准人会照着它做决定。
    const empsRes = await supabase
        .from('employees').select('id, code, legal_name, work_category')
        .is('deleted_at', null).neq('employment_status', 'separated').order('code')
    const emps = mustRows(empsRes, 'employees')

    const today = new Date()
    const horizon = new Date(today.getTime() + 90 * 86400000).toISOString().slice(0, 10)

    const rows = await Promise.all(
        emps.map(async (e) => {
            const balRes = await supabase.rpc('leave_balance', {
                p_employee_id: e.id, p_leave_type_code: 'annual',
            })
            const b = mustOne(balRes, `leave_balance ${e.code}`) as {
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
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{b?.granted ?? '—'}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{b?.consumed ?? '—'}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono font-medium">{b?.available ?? '—'}</td>
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
