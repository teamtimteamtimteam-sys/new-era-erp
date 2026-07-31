// app/hr/training/new/page.tsx
// ?employee= 时预选并锁定该员工(从员工档案页的"+ 录入培训"进来),保存后回档案页。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import TrainingForm, { type EmployeeOption } from '../TrainingForm'

export default async function NewTrainingPage({
    searchParams,
}: {
    searchParams: Promise<{ employee?: string }>
}) {
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const { data } = await supabase
        .from('employees')
        .select('id, code, legal_name')
        .is('deleted_at', null)
        .neq('employment_status', 'separated')
        .order('code')

    const employees: EmployeeOption[] = (data ?? []).map((e) => ({
        id: e.id,
        label: `${e.code} — ${e.legal_name}`,
    }))
    const locked = sp.employee && employees.some((e) => e.id === sp.employee) ? sp.employee : undefined

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link
                    href={locked ? `/hr/employees/${locked}` : '/hr/training'}
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-4">{t('hr.newTraining')}</h1>
            <Subnav />
            <TrainingForm
                employees={employees}
                lockedEmployeeId={locked}
                returnTo={locked ? `/hr/employees/${locked}` : undefined}
            />
        </div>
    )
}
