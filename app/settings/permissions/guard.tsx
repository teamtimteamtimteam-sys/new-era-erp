// app/settings/permissions/guard.ts
// 权限管理下所有页面共用的入口守卫。
//
// 【藏链接不算守卫】。导航条对没有 action.manage_permissions 的人不渲染入口,
// 但那只是体贴 —— 谁都可以直接敲 URL。所以每个页面自己再拒一次。
//
// 真正的安全边界仍然在数据库:user_directory 视图对没有这个码的人返回零行,
// set_user_roles / set_role_permissions 抛 PERMISSION_DENIED。就算这里漏了,
// 页面也只会是空的,改不动任何东西。
import { canManagePermissions } from '@/lib/permissions'
import { getTranslations } from '@/lib/i18n/server'

export async function requireManagePermissions() {
    if (await canManagePermissions()) return null

    const t = await getTranslations()
    return (
        // data-access-denied:给按角色的可达性检查用的【机器标记】。
        // 靠认文案字符串去分辨"拒绝页"漏过一次就是一次误报(REACH-1 首跑
        // 把 /settings/permissions 误当成"打得开"),所以标记跟着组件走。
        <div className="p-8 max-w-2xl" data-access-denied="1">
            <h1 className="text-2xl font-bold mb-4">{t('permissions.title')}</h1>
            <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded">
                <p className="font-medium">{t('permissions.denied')}</p>
                <p className="text-sm mt-1">{t('permissions.deniedHint')}</p>
            </div>
        </div>
    )
}
