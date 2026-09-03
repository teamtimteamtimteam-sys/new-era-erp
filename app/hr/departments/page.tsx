// app/hr/departments/page.tsx
// 部门列表:编号、中英名称、上级、启用状态、在册员工数、编辑/删除。
//
// CONV-5:套 CONV-1 的两文件模板。
// ★ state 恒为 'ok' —— 抬头的「新建部门」是这一页唯一的出口,而它住在
//   ListPage 的 actions 里(状态分支之外),空集由 DataTable 自己的 empty 说。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import DepartmentsTable, { type DepartmentRow } from './DepartmentsTable'

export default async function DepartmentsPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const [deptRes, empRes] = await Promise.all([
        supabase
            .from('departments')
            .select('id, code, name_en, name_zh, parent_department_id, is_active, notes')
            .is('deleted_at', null)
            .order('code'),
        // 在册员工数按部门统计(数据量小,取回来在内存里数;省一次分组查询的复杂度)
        supabase.from('employees').select('department_id').is('deleted_at', null),
    ])

    const departments = mustRows(deptRes)
    const nameById = new Map(departments.map((d) => [d.id, `${d.code} — ${d.name_en}`]))
    const countByDept = new Map<string, number>()
    for (const e of mustRows(empRes)) {
        if (e.department_id) countByDept.set(e.department_id, (countByDept.get(e.department_id) ?? 0) + 1)
    }

    // 服务端把每一格算成纯数据:上级部门的显示名在这里查好,Map 不过 RSC 边界。
    const tableRows: DepartmentRow[] = departments.map((d) => ({
        id: d.id,
        code: d.code,
        nameEn: d.name_en,
        nameZh: d.name_zh,
        parentLabel: d.parent_department_id ? (nameById.get(d.parent_department_id) ?? '—') : '—',
        employeeCount: countByDept.get(d.id) ?? 0,
        isActive: Boolean(d.is_active),
    }))

    return (
        <ListPage
            title={t('hr.departmentsTitle')}
            maxWidth="max-w-5xl"
            actions={
                <Link href="/hr/departments/new" className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700">
                    {t('hr.newDepartment')}
                </Link>
            }
            state={{ kind: 'ok' }}
        >
            <p className="text-sm text-gray-600 mb-4">
                {t('finance.recordCount', { count: departments.length })}
            </p>
            <DepartmentsTable rows={tableRows} empty={t('hr.departmentsEmpty')} />
        </ListPage>
    )
}
