'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { safeInternalPath } from '@/lib/loginRoute'

export async function login(formData: FormData) {
    const email = formData.get('email') as string
    const password = formData.get('password') as string
    // SESSION-1:中间件把人踢出来时保住了原路径(`?next=`),登录页把它带了回来。
    // 保住一条路径却不用它,等于没保住 —— 人还是得自己走回去。
    // 【只接内部路径】判据只有一处定义(lib/loginRoute.ts)。
    // 此前这里与 app/login/page.tsx 各有一份"逐字相同"的拷贝 —— 现在是同一个函数,
    // 而且那一份还漏掉了 `/\evil.com`(浏览器把反斜杠当斜杠),一并堵上了。
    const next = safeInternalPath(formData.get('next'))

    const supabase = await createClient()

    const { error } = await supabase.auth.signInWithPassword({ email, password })

    if (error) {
        // ════════════════════════════════════════════════════════════════════
        // 【这里此前把所有失败读成同一件事,而它们不是】(LOGIN-1,2026-09-02)
        //
        // 原文是 `const qs = new URLSearchParams({ error: 'invalid' })` —— 一条分支,
        // 一句判词:「邮箱或密码错误」。于是【一个密码完全正确的人】被告知密码错了。
        //
        // 这不是假设。Choo Er TEH 的账号【尚未确认邮箱】,而她是审批链的第一级 ——
        // 今天这一屏对她说的是「邮箱或密码错误」。她的密码没有问题,是账号差最后一步。
        // 一句说错原因的判词,会让人【一直去改那个本来就对的东西】。
        //
        // 这条规矩本仓库已经写过两遍,都在别的层:
        //   * lib/permissions.ts:37 —— 【查询失败 ≠ 这个人没有权限】
        //   * lib/supabase/middleware.ts —— 【判断不出 ≠ 没有会话】
        // 这是同一句话的第三处落点:**【认证被拒】不是一件事,是好几件。**
        //
        // 【判据用 code,不用 message】auth-js 的 ErrorCode 是一个约定好的闭集
        // (node_modules/@supabase/auth-js/.../error-codes.d.ts),而 message 是给人读的
        // 英文散文,随时会被上游改掉 —— 拿它做分支等于把判断挂在一句文案上。
        //
        // ★【认不出来的一律走 invalid,不许现编一个原因】★
        // 这是上面两处的同一条纪律:**没有确立的东西不许说出口。** 万一哪天上游不再
        // 送 code,这里会【退回那句最弱、但仍然为真的话】,而不是编一个理由。
        // 代价照直写:那时 Choo Er 那一类人会重新看到一句没用的话 —— 但不会看到一句谎话。
        // ════════════════════════════════════════════════════════════════════
        const code = (error as { code?: string }).code
        const status = (error as { status?: number }).status
        const reason =
            code === 'email_not_confirmed' ? 'unconfirmed'
            // 429 与 over_request_rate_limit 说的是同一件事,两个都认:
            // 限流可能由 auth 自己给(带 code),也可能由它前面的网关给(只有状态码)。
            : code === 'over_request_rate_limit' || status === 429 ? 'throttled'
            : 'invalid'

        // 失败时把 next 一起带回去,否则第一次打错密码就把"回到哪儿"弄丢了。
        const qs = new URLSearchParams({ error: reason })
        if (next) qs.set('next', next)
        redirect(`/login?${qs.toString()}`)
    }

    revalidatePath('/', 'layout')
    redirect(next ?? '/suppliers')
}
