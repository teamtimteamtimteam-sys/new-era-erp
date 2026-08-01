// app/welcome/page.tsx
// 账号已就绪、但还没关联员工档案(或还没授权)时的落点。
// 【不查任何权限】—— 这个页面存在的意义就是给"什么都还没有"的人一个不报错的地方。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'

export default async function WelcomePage() {
    const supabase = await createClient()
    const t = await getTranslations()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    return (
        <div className="p-8 max-w-lg mx-auto">
            <h1 className="text-2xl font-bold mb-3">{t('welcome.title')}</h1>
            <p className="text-gray-700 mb-2">{t('welcome.body')}</p>
            {user?.email && (
                <p className="text-sm text-gray-500">
                    {t('welcome.signedInAs', { 0: user.email })}
                </p>
            )}
        </div>
    )
}
