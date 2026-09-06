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
import { logout } from '@/app/logout/actions'
import SetPasswordForm from './SetPasswordForm'
import { Button } from '@/app/components/ui/button'

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
            {/* ══════════════════════════════════════════════════════════════
                ★【FIX-1 item 1:唯一的出口 —— 一条,不是一整条顶栏】★
                (Tim 的 Q3 裁定,2026-09-05)

                判据【从这一页做得了什么推出来】,不是口味:
                上面那一行 intro 把 user.email 念了出来 —— 这一页【主动告诉你
                你是谁】。那么当那个"谁"是错的人时(初始密码是当面交的,
                两个人共用一台平板并不稀奇),它就必须给得出一条出路。
                而中间件把【每一条】其他路由都弹回这一页:没有这一条,
                唯一的出口就是关掉浏览器,或者那整条顶栏 —— 后者正是本刀在修的缺陷。

                【为什么不是零个出口】"空分支里没有出口"这一族本仓库撞过七次。
                【为什么不是整条顶栏】通知、我的评估、模块清单、语言切换
                对一个还没设完密码的账号一件都不成立,而模块栏还会逐条泄露
                这个账号缺哪些模块。
                **中间那一档就是这一条:一个动作,一句话,没有导航。**

                【它复用 /logout 那支已有的 action】没有新造第二条登出路径 ——
                signOut + revalidatePath + redirect('/login') 一个字没改。
                ══════════════════════════════════════════════════════════════ */}
            <form action={logout} className="mt-8 border-t pt-4">
                <Button
                    variant="link"
                    size="inline"
                    type="submit"
                    className="text-sm"
                >
                    {t('setPassword.notYou')}
                </Button>
            </form>
        </div>
    )
}
