// app/set-password/page.tsx
// 邀请邮件的落地页。
//
// 【必须对"一个角色都没有"的人成立】。被邀请的人到这里时,管理员可能还没配完权限,
// 甚至一个角色都没授 —— 这个页面因此【不能】依赖任何模块权限,也不能因为
// current_user_permissions() 是空数组就崩。它只做一件事:设密码。
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import SetPasswordForm from './SetPasswordForm'

export default async function SetPasswordPage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const {
        data: { user },
    } = await supabase.auth.getUser()

    // 邀请链接会先带着 token 走一遍回调,此时应当已经有会话。没有就回登录页。
    if (!user) {
        redirect('/login')
    }

    return (
        <div className="p-8 max-w-md mx-auto">
            <h1 className="text-2xl font-bold mb-2">{t('setPassword.title')}</h1>
            <p className="text-sm text-gray-600 mb-6">
                {t('setPassword.intro', { 0: user.email ?? '' })}
            </p>
            <SetPasswordForm />
        </div>
    )
}
