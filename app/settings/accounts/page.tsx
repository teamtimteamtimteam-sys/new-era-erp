// app/settings/accounts/page.tsx
// 账号页:系统账号一行一个 —— 邮箱、关联员工、当前角色、最近登录、创建时间。
// 数据来自 user_directory 视图(cut 3 B2):它是属主权限视图,谓词写在视图体里,
// 没有 action.manage_permissions 的人拿到【零行而不是报错】。
import { createClient } from '@/lib/supabase/server'
import { formatTimestamp } from '@/lib/format'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireManagePermissions } from '../guard'
import UserRow, { type DirectoryRow, type RoleOption, type EmployeeOption } from './UserRow'
import CreateAccountPanel from './CreateAccountPanel'
import { mustRows } from '@/lib/db-helpers'
import { formatAuditStamp } from '@/lib/dates'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'

export default async function PermissionUsersPage({
    searchParams,
}: {
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireManagePermissions()
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const [dirRes, rolesRes, empRes] = await Promise.all([
        supabase.from('user_directory').select('*').order('created_at', { ascending: true }),
        supabase
            .from('roles')
            .select('id, code, name_en, name_zh, is_system')
            .is('deleted_at', null)
            .eq('is_active', true)
            .order('sort_order'),
        // ★ ROLE-1(Tim 的 Q8):账号↔员工关联归 action.manage_permissions,它要的只是名字 ——
        //   employee_lookup 对 action.manage_permissions 放行,只有 id / 工号 / 名字 / 账号,
        //   于是这一页不靠读者【碰巧】也持 module.hr.view(employees 的读策略要它;没有它会【安静地】只剩自己那一行)。
        //   AUDIT-TRAIL-1d-1(AT-1d Step 0 Q38):这里以前写着"系统管理员账号不再持 module.hr.view"—— 线上量过,admin 持着它;
        //   那句话不成立了,理由(不靠读者碰巧持 hr.view)仍然成立。
        supabase
            .from('employee_lookup')
            .select('id, code, legal_name, user_id')
            .is('deleted_at', null)
            .order('code'),
    ])

    const rows = (mustRows(dirRes)) as unknown as DirectoryRow[]
    const roles = (mustRows(rolesRes)) as RoleOption[]
    const employees = (mustRows(empRes)) as EmployeeOption[]

    const show = trailCount((await searchParams).trail)
    const fmt = (v: string | null) =>
        v ? formatTimestamp(v, dateLocale) : '—'

    return (
        <div className="p-8 max-w-6xl">
            <h1 className="mb-4">{t('permissions.title')}</h1>

            {/* C4:被锁在门外的人读不到这个界面 —— 所以恢复流程必须写在【别处】,
                这里只负责告诉还进得来的人:它存在,在哪儿。
                ★ COPY-1(2026-09-06):从前这里还印出一个迁移脚本的文件名,
                  而屏幕前的人是仓管与行政 —— 一个 .sql 的路径对他们不是线索,
                  是噪音。做法与那个文件名都搬进 docs/accounts-roles-and-permissions.md。 */}
            <div className="mb-6 rounded border border-gray-200 bg-gray-50 px-4 py-3 text-sm text-[color:var(--brand-muted-text)]">
                <span className="font-medium">{t('permissions.recoveryTitle')}</span>{' '}
                {t('permissions.recoveryBody')}
            </div>

            <CreateAccountPanel roles={roles} employees={employees} />

            {rows.length === 0 ? (
                <p className="text-[color:var(--brand-muted-text)]">{t('permissions.noUsers')}</p>
            ) : (
                <div className="space-y-3">
                    {rows.map((r) => (
                        <UserRow
                            key={r.user_id}
                            row={r}
                            roles={roles}
                            employees={employees}
                            lastSignInDisplay={fmt(r.last_sign_in_at)}
                            createdDisplay={fmt(formatAuditStamp(r.created_at))}
                            trail={
                                // AUDIT-TRAIL-1d-1(Q24):每一个账号一块,折起来 —— 建立 / 停用 / 恢复、授给它的角色、
                                //   它挂在谁身上(M9:根在 auth.users)
                                <AuditTrail subject="account" id={r.user_id} show={show} anchor={`account-trail-${r.user_id}`} compact />
                            }
                        />
                    ))}
                </div>
            )}
        </div>
    )
}
