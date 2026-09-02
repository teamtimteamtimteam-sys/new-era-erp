// app/settings/roles/new/page.tsx
// 新建角色:先落字段,保存后跳到详情页配授权 —— 授权矩阵需要一个 role_id 才能保存。
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { requireManagePermissions } from '../../guard'
import RoleForm from '../RoleForm'

export default async function NewRolePage() {
    const denied = await requireManagePermissions()
    if (denied) return denied

    const t = await getTranslations()

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-4">{t('permissions.title')}</h1>

            <div className="mb-4">
                <Link
                    href="/settings/roles"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h2 className="text-xl font-bold mb-2">{t('permissions.addRole')}</h2>
            <p className="text-sm text-gray-500 mb-4">{t('permissions.addRoleHint')}</p>

            <RoleForm
                initial={{
                    code: '',
                    name_en: '',
                    name_zh: '',
                    description_en: '',
                    description_zh: '',
                    is_active: true,
                    sort_order: 100,
                }}
            />
        </div>
    )
}
