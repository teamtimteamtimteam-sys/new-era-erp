// app/portal/layout.tsx
// MES-9a(2026-10-19,MES-0 Q88 · MES-9 Step 0 Q10,Tim):【供应商门户自己的外壳】—— 同一个应用,自己的布局。
//   没有员工的顶栏、模块栏、面包屑、通知铃 —— 那些都去问员工的码,而一个门户会话的数据库角色只够得着门户函数。
//   顶上一行:门户的名字与「登出」。空闲登出由根布局挂的空闲监视器管(与员工一样:30 分钟,一个值)。
//   【再问一次是不是门户会话】根布局在每一次硬导航时已经问过;软导航进这一段时它不重画,所以这里自己也问(员工会话 → 同一句拒绝)。
import { isPortalSession } from '@/lib/portalSession'
import { portalRouteRefusal } from '@/app/components/moduleGuard'
import { getTranslations } from '@/lib/i18n/server'
import { logout } from '@/app/logout/actions'
import { Button } from '@/app/components/ui/button'

export default async function PortalLayout({ children }: { children: React.ReactNode }) {
    if (!(await isPortalSession())) return portalRouteRefusal(false)
    const t = await getTranslations()
    return (
        <div className="min-h-full flex flex-col" data-portal-chrome="1">
            <header className="border-b border-gray-200 px-4 py-3 flex flex-wrap items-center justify-between gap-3">
                <span className="font-semibold">{t('portal.brand')}</span>
                <form action={logout}>
                    <Button variant="link" size="inline" type="submit" className="text-sm">{t('portal.signOut')}</Button>
                </form>
            </header>
            <main className="flex-1">{children}</main>
        </div>
    )
}
