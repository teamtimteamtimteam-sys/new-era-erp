// app/components/TopNav.tsx
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { logout } from '@/app/logout/actions'
import { getTranslations } from '@/lib/i18n/server'
import LanguageSwitcher from './LanguageSwitcher'
import NavLinks from './NavLinks'
import { canManagePermissions } from '@/lib/permissions'

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
            <NavLinks canManagePermissions={canManage} />
        </header>
    )
}
