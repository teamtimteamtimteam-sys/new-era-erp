// app/hr/departments/page.tsx
// 部门列表:编号、中英名称、上级、启用状态、在册员工数、编辑/删除。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import DeleteDepartmentButton from './DeleteDepartmentButton'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

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

    return (
        <div className="p-8 max-w-5xl">
            <div className="flex justify-between items-center mb-4">
                <h1 className="text-2xl font-bold">{t('hr.departmentsTitle')}</h1>
                <Link
                    href="/hr/departments/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('hr.newDepartment')}
                </Link>
            </div>

            <p className="text-sm text-gray-600 mb-4">
                {t('finance.recordCount', { count: departments.length })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colNameEn')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colNameZh')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colParent')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('hr.colEmployeeCount')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colActive')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('metalPrices.colActions')}</th>
                    </tr>
                </thead>
                <tbody>
                    {departments.map((d) => (
                        <tr key={d.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">{d.code}</td>
                            <td className="border border-gray-300 px-4 py-2">{d.name_en}</td>
                            <td className="border border-gray-300 px-4 py-2">{d.name_zh}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">
                                {d.parent_department_id ? (nameById.get(d.parent_department_id) ?? '—') : '—'}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {countByDept.get(d.id) ?? 0}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span
                                    className={
                                        'px-2 py-1 rounded text-xs ' +
                                        (d.is_active ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-600')
                                    }
                                >
                                    {d.is_active ? t('pricing.form.active') : t('finance.inactive')}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm whitespace-nowrap">
                                <Link
                                    href={`/hr/departments/${d.id}/edit`}
                                    className="text-blue-600 hover:underline mr-3"
                                >
                                    {t('purchasing.editLink')}
                                </Link>
                                <DeleteDepartmentButton id={d.id} name={d.name_en} />
                            </td>
                        </tr>
                    ))}
                    {departments.length === 0 && (
                        <tr>
                            <td colSpan={7} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('hr.departmentsEmpty')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
