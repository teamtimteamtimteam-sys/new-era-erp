// app/set-password/page.tsx
// 【第一次登录时换掉那个当面交出去的密码】的那一页。
//
// ★ C-1(2026-09-04):它从前是【邀请邮件的落地页】。本系统没有邮件服务,
//   账号改由 /settings/accounts 直接建出来 + Tim 当面交初始密码,
//   而中间件按 user_metadata.must_change_password 把人扣在这一页,
//   直到他自己设一个新密码为止(见 lib/supabase/middleware.ts)。
//   进到这里的路因此变了,而这一页要做的事一个字没变:**只设密码**。
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

    // 走到这里的人必然已经登录(中间件只对有会话的人做这次重定向)。
    // 没有会话就回登录页 —— 那是直接敲这条 URL 的人。
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
