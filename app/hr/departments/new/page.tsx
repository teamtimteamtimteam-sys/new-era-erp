// app/hr/departments/new/page.tsx
import Link from 'next/link'
import { mustRows } from '@/lib/db-helpers'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import DepartmentForm from '../DepartmentForm'
import { parentOptionsFor, type DeptNode } from '../tree'

export default async function NewDepartmentPage() {
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
            <Subnav />
            {/* 新建时没有"自己",全部现有部门都可当上级 */}
            <DepartmentForm parentOptions={parentOptionsFor(mustRows(res) as DeptNode[])} />
        </div>
    )
}
