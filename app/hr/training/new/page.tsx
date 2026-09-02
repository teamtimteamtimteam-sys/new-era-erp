// app/hr/training/new/page.tsx
// ?employee= 时预选并锁定该员工(从员工档案页的"+ 录入培训"进来),保存后回档案页。
import Link from 'next/link'
import { mustRows } from '@/lib/db-helpers'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import TrainingForm, { type EmployeeOption } from '../TrainingForm'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewTrainingPage({
    searchParams,
}: {
    searchParams: Promise<{ employee?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const res = await supabase
        .from('employees')
        .select('id, code, legal_name')
        .is('deleted_at', null)
        .neq('employment_status', 'separated')
        .order('code')

    const employees: EmployeeOption[] = mustRows(res).map((e) => ({
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
            <TrainingForm
                employees={employees}
                lockedEmployeeId={locked}
                returnTo={locked ? `/hr/employees/${locked}` : undefined}
            />
        </div>
    )
}
