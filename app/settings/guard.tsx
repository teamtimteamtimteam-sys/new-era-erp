// app/settings/accounts/guard.ts
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
import { RefusalPage } from '@/app/components/ui/refusal'

// ★【CONV-0 ①:这里【曾经是那块屏的第二份逐字副本】】★
//   三份(本文件 · app/components/moduleGuard.tsx · app/settings/import/page.tsx)
//   已经合并成 <RefusalPage> 一份。
//   【本页可见的变化只有一处】它现在也有「回首页」了 —— 那条链接此前只在
//   moduleGuard 那一份上,而漂开的原因不是有人决定这里不要,是抄的时候少抄了一行。
export async function requireManagePermissions() {
    if (await canManagePermissions()) return null

    const t = await getTranslations()
    return (
        <RefusalPage
            title={t('permissions.title')}
            statement={t('permissions.denied')}
            hint={t('permissions.deniedHint')}
            backHomeLabel={t('common.backHome')}
        />
    )
}
