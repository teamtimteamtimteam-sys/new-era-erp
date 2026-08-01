// app/hr/leave/grants/page.tsx
// 年度操作:发放年假、年末结转。
// 【这两件事一年只做一两次,但整本假期账都靠它们】—— 所以给它们一个显眼的入口,
// 而不是埋在某个按钮后面。页面先把"将会发生什么"算给你看,再让你按。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import LeaveSubnav from '../LeaveSubnav'
import GrantRunner from './GrantRunner'

export default async function GrantsPage({
    searchParams,
}: { searchParams: Promise<{ year?: string }> }) {
    const sp = await searchParams
    const year = Number(sp.year ?? new Date().getFullYear())
    const supabase = await createClient()
    const t = await getTranslations()

    const [empRes, grantRes] = await Promise.all([
        supabase.from('employees').select('id, code, legal_name, hire_date, annual_leave_days')
            .is('deleted_at', null).neq('employment_status', 'separated').order('code'),
        supabase.from('leave_grants').select('employee_id, grant_type, days, leave_year')
            .eq('leave_type_code', 'annual').is('deleted_at', null),
    ])

    const grants = grantRes.data ?? []
    const hasEntitlement = new Set(
        grants.filter((g) => g.leave_year === year && (g.grant_type === 'entitlement' || g.grant_type === 'pro_rata'))
              .map((g) => g.employee_id))
    const hasCarry = new Set(
        grants.filter((g) => g.leave_year === year && g.grant_type === 'carry_forward').map((g) => g.employee_id))

    const missing = (empRes.data ?? []).filter((e) => !hasEntitlement.has(e.id))

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <Subnav />
            <LeaveSubnav />

            <form method="get" className="mb-6 flex items-end gap-2">
                <label className="text-sm">
                    {t('leave.leaveYear')}
                    <input type="number" name="year" defaultValue={year}
                           className="mt-1 block border border-gray-300 rounded px-2 py-1 text-sm w-28" />
                </label>
                <button type="submit" className="border border-gray-300 rounded px-3 py-1 text-sm">
                    {t('leave.filter')}
                </button>
            </form>

            <GrantRunner
                year={year}
                missing={missing.map((e) => ({ id: e.id, code: e.code, legal_name: e.legal_name,
                                               hire_date: e.hire_date, annual_leave_days: e.annual_leave_days }))}
                alreadyGranted={hasEntitlement.size}
                alreadyCarried={hasCarry.size}
            />
        </div>
    )
}
