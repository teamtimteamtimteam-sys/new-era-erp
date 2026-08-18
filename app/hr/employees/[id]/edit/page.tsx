// app/hr/employees/[id]/edit/page.tsx
// 上级候选里剔掉【自己与自己的所有下属】—— 与部门那边同一个道理:
// 让人选不到会成环的项,DB 的 MANAGER_CYCLE 是后墙。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import Subnav from '../../../Subnav'
import EmployeeForm, { type PickOption, type EmployeeRecord } from '../../EmployeeForm'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { canManagePermissions } from '@/lib/permissions'
import { MOD } from '@/lib/modules'

// 下属闭包:从自己出发,沿 manager_id 往下收集
function reportIds(all: { id: string; manager_id: string | null }[], rootId: string): Set<string> {
    const childrenOf = new Map<string, string[]>()
    for (const e of all) {
        if (!e.manager_id) continue
        const arr = childrenOf.get(e.manager_id) ?? []
        arr.push(e.id)
        childrenOf.set(e.manager_id, arr)
    }
    const out = new Set<string>()
    const stack = [rootId]
    while (stack.length) {
        const cur = stack.pop()!
        for (const child of childrenOf.get(cur) ?? []) {
            if (out.has(child)) continue
            out.add(child)
            stack.push(child)
        }
    }
    return out
}

export default async function EditEmployeePage({
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
    const locale = await getLocale()

    const [empRes, deptRes, allRes] = await Promise.all([
        supabase.from('employees_masked').select('*').eq('id', id).is('deleted_at', null).single(),
        supabase.from('departments').select('id, code, name_en, name_zh').is('deleted_at', null).eq('is_active', true).order('code'),
        supabase
            .from('employees')
            .select('id, code, legal_name, manager_id, employment_status')
            .is('deleted_at', null)
            .order('code'),
    ])

    if (empRes.error || !empRes.data) {
        notFound()
    }

    const all = (mustRows(allRes)).map((e) => ({ id: e.id, manager_id: e.manager_id }))
    const excluded = reportIds(all, id)
    excluded.add(id)

    // 见 new/page.tsx 的同一段:权限回答"能不能看",列表只负责列。
    // 可选项 = 【还没关联任何员工的账号】+ 这名员工当前关联的那一个
    //(否则一进编辑页,当前值就不在选项里,浏览器会把它显示成第一项 ——
    // 一次纯粹的显示错位就会在保存时变成一次真的改绑)。
    const canLinkAccount = await canManagePermissions()
    const accountRows = canLinkAccount
        ? mustRows(
              await supabase
                  .from('user_directory')
                  .select('user_id, email, employee_id')
                  .or(`employee_id.is.null,employee_id.eq.${id}`)
                  .order('email')
          )
        : []
    const accounts: PickOption[] = accountRows.map((u) => ({
        id: u.user_id as string,
        label: (u.email as string | null) ?? (u.user_id as string),
    }))
    const linkedAccountLabel =
        accounts.find((a) => a.id === (empRes.data as { user_id: string | null }).user_id)?.label ?? null

    const departments: PickOption[] = (mustRows(deptRes)).map((d) => ({
        id: d.id,
        label: `${d.code} — ${locale === 'zh' ? d.name_zh : d.name_en}`,
    }))
    const managers: PickOption[] = (mustRows(allRes))
        .filter((e) => !excluded.has(e.id) && e.employment_status !== 'separated')
        .map((e) => ({ id: e.id, label: `${e.code} — ${e.legal_name}` }))

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href={`/hr/employees/${id}`} className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-4">
                {t('hr.employeeDetailTitle')}
                <span className="ml-3 font-mono text-base text-gray-500">{empRes.data.code}</span>
            </h1>
            <Subnav />
            <EmployeeForm
                employee={empRes.data as EmployeeRecord}
                departments={departments}
                managers={managers}
                accounts={accounts}
                canLinkAccount={canLinkAccount}
                linkedAccountLabel={linkedAccountLabel}
            />
        </div>
    )
}
