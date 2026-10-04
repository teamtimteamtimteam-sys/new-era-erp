// app/hr/leave/grants/page.tsx
// 年度操作:发放年假、年末结转。
// 【这两件事一年只做一两次,但整本假期账都靠它们】—— 所以给它们一个显眼的入口,
// 而不是埋在某个按钮后面。页面先把"将会发生什么"算给你看,再让你按。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import LeaveSubnav from '../LeaveSubnav'
import GrantRunner from './GrantRunner'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { Button } from '@/app/components/ui/button'
import ListTrail from '@/app/components/trail/ListTrail'
import { trailCount } from '@/app/components/trail/AuditTrail'

export default async function GrantsPage({
    searchParams,
}: { searchParams: Promise<{ year?: string; trail?: string | string[] }> }) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const sp = await searchParams
    const year = Number(sp.year ?? new Date().getFullYear())
    const supabase = await createClient()
    const t = await getTranslations()

    // 【只剩年末结转】年度发放随 HR-2c 删除:年假按月累积、读时派生。
    const grantRes = await supabase.from('leave_grants')
        .select('employee_id, grant_type, days, leave_year')
        .eq('leave_type_code', 'annual').is('deleted_at', null)

    const grants = mustRows(grantRes)
    // AUDIT-TRAIL-1d-2:这一个假期年的每一笔发放(删掉的也读 —— "被删"是那一笔的一部分)一条记录,清单块按操作合起来:
    //   一次结转是一条 "Unused leave carried forward · N people"(Q16 的 op_key)。员工按工号认(读 employees_masked —— 只要工号)
    const yearGrants = mustRows(
        await supabase.from('leave_grants').select('id, employee_id, leave_year').eq('leave_year', year)
            .order('created_at', { ascending: false }).limit(200),
        'leave_grants (trail)',
    )
    const grantEmpIds = [...new Set(yearGrants.map((g) => g.employee_id))]
    const grantEmps = grantEmpIds.length
        ? mustRows(await supabase.from('employees_masked').select('id, code').in('id', grantEmpIds), 'employees_masked (trail)')
        : []
    const codeOf = new Map(grantEmps.map((e) => [e.id, e.code]))
    const hasCarry = new Set(
        grants.filter((g) => g.leave_year === year && g.grant_type === 'carry_forward').map((g) => g.employee_id))

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="mb-4">{t('hr.title')}</h1>
            <LeaveSubnav />

            <form method="get" className="mb-6 flex items-end gap-2">
                <label className="">
                    {t('leave.leaveYear')}
                    <input type="number" name="year" defaultValue={year}
                           className={`${CONTROL_INPUT} mt-1 block w-28`} />
                </label>
                <Button variant="secondary" type="submit">
                    {t('leave.filter')}
                </Button>
            </form>

            <GrantRunner year={year} alreadyCarried={hasCarry.size} />

            <ListTrail intro="listTrail.intro.leaveGrants" show={trailCount(sp.trail)}
                records={yearGrants.map((g) => ({ subject: 'leave_grant' as const, id: g.id,
                    label: `${codeOf.get(g.employee_id) ?? '—'} · ${g.leave_year}` }))} />
        </div>
    )
}
