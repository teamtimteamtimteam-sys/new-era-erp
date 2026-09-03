// app/hr/leave/balances/page.tsx
// 全员年假余额一览 —— HR 审批之前看的就是这一张。
// 【90 天内到期的天数高亮】:那是"再不休就烂掉"的部分,提前看见才来得及安排。
//
// CONV-5:套 CONV-1 的两文件模板。
// ★ state 恒为 'ok' —— LeaveSubnav 是这一页与其余请假页面之间的唯一通路,
//   走 empty 分支会把它一起藏起来(见 docs/list-page-template.md §⑩-3)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import LeaveSubnav from '../LeaveSubnav'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import BalancesTable, { type BalanceRow } from './BalancesTable'

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

    const tableRows: BalanceRow[] = rows.map(({ e, b, expiringSoon }) => ({
        employeeId: e.id,
        employeeLabel: `${e.code} — ${e.legal_name}`,
        granted: String(b?.granted ?? '—'),
        consumed: String(b?.consumed ?? '—'),
        available: String(b?.available ?? '—'),
        expiringSoon,
    }))

    return (
        <ListPage
            title={t('hr.title')}
            intro={t('leave.balancesIntro')}
            maxWidth="max-w-5xl"
            state={{ kind: 'ok' }}
        >
            <LeaveSubnav />
            <BalancesTable rows={tableRows} empty={t('leave.noRequests')} />
        </ListPage>
    )
}
