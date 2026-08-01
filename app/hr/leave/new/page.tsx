// app/hr/leave/new/page.tsx
// HR 代录请假(有人递了纸质单子)。带例外开关 —— 例外是 HR 的口子。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import LeaveSubnav from '../LeaveSubnav'
import LeaveForm, { type LeaveTypeOption, type EmployeeOption } from '../LeaveForm'

export default async function NewLeavePage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const [typeRes, empRes] = await Promise.all([
        supabase.from('leave_types')
            .select('code, name_en, name_zh, is_accrued, allows_half_day, requires_certificate_after_days, default_days_per_year')
            .eq('is_active', true).order('sort_order'),
        supabase.from('employees').select('id, code, legal_name')
            .is('deleted_at', null).neq('employment_status', 'separated').order('code'),
    ])

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <Subnav />
            <LeaveSubnav />
            <div className="mb-4">
                <Link href="/hr/leave" className="text-blue-600 hover:underline text-sm">{t('common.back')}</Link>
            </div>
            <h2 className="text-xl font-bold mb-4">{t('leave.recordLeave')}</h2>
            <LeaveForm
                types={(typeRes.data ?? []) as LeaveTypeOption[]}
                employees={(empRes.data ?? []) as EmployeeOption[]}
                allowException
                redirectTo="/hr/leave"
            />
        </div>
    )
}
