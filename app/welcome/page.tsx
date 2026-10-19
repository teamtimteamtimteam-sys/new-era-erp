// app/welcome/page.tsx
// 账号已就绪、但还没关联员工档案(或还没授权)时的落点。
// 【不查任何权限】—— 这个页面存在的意义就是给"什么都还没有"的人一个不报错的地方。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireNotFloorDisplay } from '@/app/components/moduleGuard'

export default async function WelcomePage() {
    // MES-8b-2:这一页不要任何码,所以一块车间大屏的会话(软导航不重画根布局)要在这里被拒、指回 /display。
    const floorRefusal = await requireNotFloorDisplay()
    if (floorRefusal) return floorRefusal
    const supabase = await createClient()
    const t = await getTranslations()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    return (
        <div className="p-8 max-w-lg mx-auto">
            <h1 className="mb-3">{t('welcome.title')}</h1>
            <p className="text-[color:var(--brand-text)] mb-2">{t('welcome.body')}</p>
            {user?.email && (
                <p className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('welcome.signedInAs', { 0: user.email })}
                </p>
            )}
        </div>
    )
}
