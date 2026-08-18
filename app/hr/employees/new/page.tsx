// app/hr/employees/new/page.tsx
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import EmployeeForm, { type PickOption } from '../EmployeeForm'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { canManagePermissions } from '@/lib/permissions'
import { MOD } from '@/lib/modules'

export default async function NewEmployeePage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const [deptRes, empRes] = await Promise.all([
        supabase.from('departments').select('id, code, name_en, name_zh').is('deleted_at', null).eq('is_active', true).order('code'),
        supabase
            .from('employees')
            .select('id, code, legal_name')
            .is('deleted_at', null)
            .neq('employment_status', 'separated')
            .order('code'),
    ])

    // 【先问权限,再决定要不要查】。user_directory 对没有 action.manage_permissions
    // 的人返回【零行而不是报错】,所以"查出来是空的"同时是"没有可选账号"和
    // "你不被允许看"两件事 —— 空集不能当答案用(lib/permissions.ts 的立身之本)。
    // 权限自己回答这个问题,列表只负责列。
    const canLinkAccount = await canManagePermissions()
    const accounts: PickOption[] = canLinkAccount
        ? (mustRows(
              await supabase
                  .from('user_directory')
                  .select('user_id, email')
                  .is('employee_id', null)
                  .order('email')
          )).map((u) => ({ id: u.user_id as string, label: (u.email as string | null) ?? (u.user_id as string) }))
        : []

    const departments: PickOption[] = (mustRows(deptRes)).map((d) => ({
        id: d.id,
        label: `${d.code} — ${locale === 'zh' ? d.name_zh : d.name_en}`,
    }))
    // 新建时还没有"自己",在职的人都可以是上级
    const managers: PickOption[] = (mustRows(empRes)).map((e) => ({
        id: e.id,
        label: `${e.code} — ${e.legal_name}`,
    }))

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/hr/employees" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-4">{t('hr.newEmployee')}</h1>
            <Subnav />
            <EmployeeForm
                departments={departments}
                managers={managers}
                accounts={accounts}
                canLinkAccount={canLinkAccount}
                linkedAccountLabel={null}
            />
        </div>
    )
}
