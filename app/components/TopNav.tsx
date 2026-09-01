// app/components/TopNav.tsx
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { logout } from '@/app/logout/actions'
import { getTranslations } from '@/lib/i18n/server'
import LanguageSwitcher from './LanguageSwitcher'
import NotificationBell from './NotificationBell'
import NavLinks from './NavLinks'
import { canManagePermissions, can } from '@/lib/permissions'
import { DICT_PERMISSIONS } from '@/app/settings/dictionaries/registry'
import { getVisibleModules } from '@/lib/moduleAccess'

export default async function TopNav() {
    const supabase = await createClient()
    // 【error 必须接住 —— 一条空着的导航条是同一句谎的另一件衣服】(SESSION-1,2026-08-23)
    //
    // 此前这里是 `const { data: { user } } = await getUser()` 然后 `if (!user) return null`。
    // `getUser()` 失败时 user 也是 null,于是**认证够不着的那一刻,整条导航条凭空消失**,
    // 而页面主体照常渲染 —— 屏幕上"这个系统没有你能用的东西"与"刚才没问到答案"
    // 长得一模一样。同一条规矩的两处先例都在仓库里:lib/permissions.ts(查询失败
    // ≠ 没有权限)与 moduleGuard.tsx(进不去的空 ≠ 真的空)。
    //
    // 判据与 lib/supabase/middleware.ts 逐字同源(那里有实测的七情形表):
    // `AuthRetryableFetchError` = 判断不出;其余 = 确立的否定。
    let user = null
    let authError: unknown = null
    try {
        const res = await supabase.auth.getUser()
        user = res.data.user
        authError = res.error
    } catch (e) {
        authError = e
    }

    const t = await getTranslations()

    // 【判断不出】—— 画一条【说话的】导航条,不是不画。
    // 正常情况下走不到这里(中间件在更前面就用 503 挡住了),它接的是那个窄缝:
    // 中间件那一次问到了答案,而这一次没问到。缝窄不等于不存在,而它一旦发生,
    // 消失的导航条是这一页上唯一的线索。
    if (!user && (authError as { name?: string } | null)?.name === 'AuthRetryableFetchError') {
        return (
            <header className="border-b border-gray-200 bg-white" data-auth-indeterminate="1">
                <div className="px-6 py-3 flex items-center gap-4">
                    <Link href="/" className="font-bold text-lg">
                        EVoltrya OS
                    </Link>
                    <span className="text-sm bg-amber-50 border border-amber-300 text-amber-900 px-2 py-1 rounded">
                        <span className="font-medium">{t('common.navUnavailable')}</span>{' '}
                        <span className="hidden sm:inline">{t('common.navUnavailableHint')}</span>
                    </span>
                </div>
            </header>
        )
    }

    // 【确立的否定】—— 不画导航条。这一支是对的:登录页本来就没有导航,
    // 而其余路径中间件早就重定向掉了。
    if (!user) {
        return null
    }

    const canManage = await canManagePermissions()
    const canBulkImport = await can('action.bulk_import')
    // DICT-ADMIN:能编辑【任一张】字典的人都要看得见那一项。
    // 判据取自 registry 的 DICT_PERMISSIONS —— 不在这里抄第二份权限清单
    // (加一张新字典时,这里自动跟着变)。
    const canEditDictionaries = (
        await Promise.all(DICT_PERMISSIONS.map((code) => can(code)))
    ).some(Boolean)
    // OPS-15:按权限过滤后的模块清单 —— 与首页卡片同一份 lib/modules.ts
    const modules = await getVisibleModules()

    return (
        <header className="border-b border-gray-200 bg-white">
            <div className="px-6 py-3 flex items-center justify-between">
                <Link href="/" className="font-bold text-lg">
                    EVoltrya OS
                </Link>
                <div className="flex items-center gap-4">
                    <span className="text-sm text-gray-500 hidden sm:inline">
                        {user.email}
                    </span>
                    {/* NTF-1:铃铛在【关于你】这一区(语言、退出),不在 NavLinks 里 ——
                        收件箱不是一个模块,它是这个人自己的东西。 */}
                    <NotificationBell />
                    <LanguageSwitcher />
                    <form action={logout}>
                        <button
                            type="submit"
                            className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50"
                        >
                            {t('nav.logout')}
                        </button>
                    </form>
                </div>
            </div>
            <NavLinks modules={modules} canManagePermissions={canManage} canBulkImport={canBulkImport}
                canEditDictionaries={canEditDictionaries} />
        </header>
    )
}
