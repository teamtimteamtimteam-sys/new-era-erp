// app/hr/training/[id]/edit/page.tsx
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import TrainingForm, { type EmployeeOption } from '../../TrainingForm'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { requireDeletedAccess } from '@/app/components/moduleGuard'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import { DeletedBanner, EndedFieldset } from '@/app/components/trail/EndedBanner'

export default async function EditTrainingPage({
    params,
    searchParams,
}: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
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
            .select('id, employee_id, training_name, category, completed_date, expiry_date, provider, certificate_ref, notes, deleted_at')
            .eq('id', id)
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
    // AUDIT-TRAIL-1d-1(Tim 的 Q26):删掉的培训记录以前在这里 404 —— 现在对持 data.view_deleted 的人只读打开,别人一句具名拒绝
    const deleted = !!recRes.data.deleted_at
    if (deleted) {
        const refused = await requireDeletedAccess('hr.trainingTitle')
        if (refused) return refused
    }

    const employees: EmployeeOption[] = (mustRows(empRes)).map((e) => ({
        id: e.id,
        label: `${e.code} — ${e.legal_name}`,
    }))

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/hr/training" className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="mb-4">{t('hr.trainingTitle')}</h1>
            {deleted && <DeletedBanner kind="training_record" id={id} at={recRes.data.deleted_at as string} />}
            <EndedFieldset ended={deleted}>
            <TrainingForm record={recRes.data} employees={employees} />
            </EndedFieldset>
            {/* AUDIT-TRAIL-1d-1(Q29):培训记录唯一的一页;它同时是员工审计记录里的一个成员(家在这里) */}
            <AuditTrail subject="training_record" id={id} show={trailCount((await searchParams).trail)} />
        </div>
    )
}
