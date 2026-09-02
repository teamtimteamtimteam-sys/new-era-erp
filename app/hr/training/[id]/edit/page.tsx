// app/hr/training/[id]/edit/page.tsx
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import TrainingForm, { type EmployeeOption } from '../../TrainingForm'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function EditTrainingPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const [recRes, empRes] = await Promise.all([
        supabase
            .from('training_records')
            .select('id, employee_id, training_name, category, completed_date, expiry_date, provider, certificate_ref, notes')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase
            .from('employees')
            .select('id, code, legal_name')
            .is('deleted_at', null)
            .order('code'),
    ])

    if (recRes.error || !recRes.data) {
        notFound()
    }

    const employees: EmployeeOption[] = (mustRows(empRes)).map((e) => ({
        id: e.id,
        label: `${e.code} — ${e.legal_name}`,
    }))

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/hr/training" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-4">{t('hr.trainingTitle')}</h1>
            <TrainingForm record={recRes.data} employees={employees} />
        </div>
    )
}
