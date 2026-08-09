// app/hr/departments/[id]/edit/page.tsx
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../../Subnav'
import DepartmentForm from '../../DepartmentForm'
import { parentOptionsFor, type DeptNode } from '../../tree'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function EditDepartmentPage({
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
                parentOptions={parentOptionsFor((mustRows(allRes)) as DeptNode[], id)}
            />
        </div>
    )
}
