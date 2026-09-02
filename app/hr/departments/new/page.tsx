// app/hr/departments/new/page.tsx
import Link from 'next/link'
import { mustRows } from '@/lib/db-helpers'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import DepartmentForm from '../DepartmentForm'
import { parentOptionsFor, type DeptNode } from '../tree'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewDepartmentPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const res = await supabase
        .from('departments')
        .select('id, code, name_en, parent_department_id')
        .is('deleted_at', null)
        .order('code')

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/hr/departments" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-4">{t('hr.newDepartment')}</h1>
            {/* 新建时没有"自己",全部现有部门都可当上级 */}
            <DepartmentForm parentOptions={parentOptionsFor(mustRows(res) as DeptNode[])} />
        </div>
    )
}
