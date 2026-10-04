// app/hr/departments/[id]/edit/page.tsx
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import DepartmentForm from '../../DepartmentForm'
import { parentOptionsFor, type DeptNode } from '../../tree'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { requireDeletedAccess } from '@/app/components/moduleGuard'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import { DeletedBanner, EndedFieldset } from '@/app/components/trail/EndedBanner'

export default async function EditDepartmentPage({
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

    const [deptRes, allRes] = await Promise.all([
        supabase
            .from('departments')
            .select('id, code, name_en, name_zh, parent_department_id, is_active, notes, deleted_at')
            .eq('id', id)
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
    // AUDIT-TRAIL-1d-1(Tim 的 Q26):删掉的部门以前在这里 404 —— 现在对持 data.view_deleted 的人只读打开,别人一句具名拒绝
    const deleted = !!deptRes.data.deleted_at
    if (deleted) {
        const refused = await requireDeletedAccess('hr.departmentsTitle')
        if (refused) return refused
    }

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/hr/departments" className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="mb-4">
                {t('hr.departmentsTitle')}
                <span className="ml-3 text-sm text-[color:var(--brand-muted-text)]">{deptRes.data.code}</span>
            </h1>
            {deleted && <DeletedBanner kind="department" id={id} at={deptRes.data.deleted_at as string} />}
            <EndedFieldset ended={deleted}>
            <DepartmentForm
                department={deptRes.data}
                parentOptions={parentOptionsFor((mustRows(allRes)) as DeptNode[], id)}
            />
            </EndedFieldset>
            {/* AUDIT-TRAIL-1d-1:这是部门唯一的一页(Q2 的先例:只有编辑页的记录,审计记录在编辑页底部) */}
            <AuditTrail subject="department" id={id} show={trailCount((await searchParams).trail)} />
        </div>
    )
}
