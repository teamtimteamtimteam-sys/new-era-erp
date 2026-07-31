// app/hr/departments/[id]/edit/page.tsx
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../../Subnav'
import DepartmentForm from '../../DepartmentForm'
import { parentOptionsFor, type DeptNode } from '../../tree'

export default async function EditDepartmentPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const [deptRes, allRes] = await Promise.all([
        supabase
            .from('departments')
            .select('id, code, name_en, name_zh, parent_department_id, is_active, notes')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase
            .from('departments')
            .select('id, code, name_en, parent_department_id')
            .is('deleted_at', null)
            .order('code'),
    ])

    if (deptRes.error || !deptRes.data) {
        notFound()
    }

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/hr/departments" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-4">
                {t('hr.departmentsTitle')}
                <span className="ml-3 font-mono text-base text-gray-500">{deptRes.data.code}</span>
            </h1>
            <Subnav />
            <DepartmentForm
                department={deptRes.data}
                parentOptions={parentOptionsFor((allRes.data ?? []) as DeptNode[], id)}
            />
        </div>
    )
}
