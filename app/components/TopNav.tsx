// app/components/TopNav.tsx
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { logout } from '@/app/logout/actions'

export default async function TopNav() {
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    if (!user) {
        return null
    }

    return (
        <header className="border-b border-gray-200 bg-white px-6 py-3 flex items-center justify-between">
            <Link href="/" className="font-bold text-lg">
                SWM-OS
            </Link>
            <div className="flex items-center gap-4">
                <span className="text-sm text-gray-500">{user.email}</span>
                <form action={logout}>
                    <button
                        type="submit"
                        className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50"
                    >
                        登出
                    </button>
                </form>
            </div>
        </header>
    )
}
