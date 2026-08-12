// lib/supabase/server.ts
// Server Component / Server Action / Route Handler 使用的 Supabase 客户端
//
// ════════════════════════════════════════════════════════════════════════════
// 【别再试 autoRefreshToken: false 了 —— 实测过,它管不到这里】(SESSION-1b,2026-08-12)
//
// SESSION-1 结束时排了一条待办:"让中间件成为唯一的刷新者",做法是给这个客户端加
// `auth: { autoRefreshToken: false, persistSession: false }`。**做了,而且量过,它没用。**
// 写在这里,是为了让下一个人不必再花一轮去发现同一件事。
//
// 实测(把中间件拿开,单看这个客户端,数它自己发出的 /auth/v1/token 调用):
//
//     会话未过期 + 默认选项                   /token = 0
//     会话未过期 + autoRefreshToken:false     /token = 0
//     会话已过期 + 默认选项                   /token = 1
//     会话已过期 + autoRefreshToken:false     /token = 1   ← 没有变
//     会话已过期 + 显式 Authorization 头       /token = 1   ← 也没有变
//
// 那次刷新是【按过期时间、按需】发生的,而 `autoRefreshToken` 关掉的是**后台定时
// 刷新**。请求级的客户端根本活不到定时器响,所以这个开关对本问题完全无效 ——
// 加上它只会留下一句"已经修好了"的错觉,而错觉比缺口更贵(同 AGENTS.md 那条:
// 一条不会响的检查比没有检查更坏)。
//
// **所以并发刷新那一类【仍然存在】,没有被这一刀去掉。** 真正动得了它的只剩配置层:
// `security_refresh_token_reuse_interval`(现为 10 秒),或关掉轮换 —— 那是一次安全
// 取舍,归 Tim 决定,不是这个文件修得了的。详见 docs/known-issues.md 的 SESSION-1 条目。
// ════════════════════════════════════════════════════════════════════════════
import { createServerClient } from '@supabase/ssr'
import type { Database } from '@/lib/database.types'
import { cookies } from 'next/headers'

export async function createClient() {
    const cookieStore = await cookies()

    return createServerClient<Database>(
        process.env.NEXT_PUBLIC_SUPABASE_URL!,
        process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
        {
            cookies: {
                getAll() {
                    return cookieStore.getAll()
                },
                setAll(cookiesToSet) {
                    try {
                        cookiesToSet.forEach(({ name, value, options }) =>
                            cookieStore.set(name, value, options)
                        )
                    } catch {
                        // Server Component 里写 cookie 会抛,这是预期行为,照旧安静。
                        //
                        // 【但"写不进去"与"写不进去的是一次会话清除"不是一回事】——
                        // 这句 catch 正是 SESSION-1 查了一整轮的原因:它把两者一起吞了,
                        // 于是"会话刚刚被清掉"在所有 GET 上完全无声,最后是靠在这里
                        // 打一次调用栈才看见的。空值 = 删除,那一种必须出声。
                        //
                        // 【只出声,不改行为】这里不能把清除写进去(Server Component
                        // 本来就写不了),也不该改成抛错 —— 那会把一次读页面变成一次崩溃。
                        // 它买的只有一样东西:下一次发生时,日志里有一行。
                        const removals = cookiesToSet.filter((c) => c.value === '')
                        if (removals.length > 0) {
                            console.warn(
                                '[supabase] SESSION REMOVAL swallowed in a Server Component — ' +
                                    'the auth client just cleared the session (almost always a failed token refresh). ' +
                                    'Cookies: ' + removals.map((c) => c.name).join(', ') + '. ' +
                                    'It cannot be written from here, so this GET looks normal; the next write path ' +
                                    '(server action / route handler) will persist it and the user lands on /login. ' +
                                    'See docs/known-issues.md — SESSION-1.'
                            )
                        }
                    }
                },
            },
        }
    )
}
