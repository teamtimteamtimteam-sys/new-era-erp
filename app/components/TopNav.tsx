// app/components/TopNav.tsx
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { logout } from '@/app/logout/actions'
import { getTranslations } from '@/lib/i18n/server'
import LanguageSwitcher from './LanguageSwitcher'
import NotificationBell from './NotificationBell'
import NavLinks from './NavLinks'
import { canManagePermissions } from '@/lib/permissions'
import { getVisibleModules } from '@/lib/moduleAccess'

export default async function TopNav() {
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    if (!user) {
        return null
    }

    const t = await getTranslations()
    const canManage = await canManagePermissions()
    // OPS-15:按权限过滤后的模块清单 —— 与首页卡片同一份 lib/modules.ts
    const modules = await getVisibleModules()

    return (
        <header className="border-b border-gray-200 bg-white">
            <div className="px-6 py-3 flex items-center justify-between">
                <Link href="/" className="font-bold text-lg">
                    Evoltrya OS
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
            <NavLinks modules={modules} canManagePermissions={canManage} />
        </header>
    )
}
