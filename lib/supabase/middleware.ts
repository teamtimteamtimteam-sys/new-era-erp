// lib/supabase/middleware.ts
// Supabase SSR session refresh + auth gate for Next.js middleware
//
// ════════════════════════════════════════════════════════════════════════════
// 【没有会话】与【判断不出有没有会话】是两件事,而这里曾经把它们当成一件(SESSION-1,2026-08-23)
//
// 本文件此前是这样写的:
//
//     const { data: { user } } = await supabase.auth.getUser()   // ← error 被丢掉
//     if (!user && !isPublic) return NextResponse.redirect('/login')
//
// `getUser()` 失败时也返回 `user = null`。于是【认证服务够不着】与【这个人真的
// 没登录】走同一条分支,而那条分支把人扔到登录页 —— **一个从来没有被登出的人,
// 被系统告知他没登录。** 判词说出了一个它根本没有确立的原因。
//
// **这条规矩本仓库已经写下过一次,就在下面这个文件里,只是从来没有被搬到认证这一层:**
//
//     lib/permissions.ts:37 —— 【查询失败 ≠ 这个人没有权限】
//     "原本 `if (error || !data) return []` 把 RPC 失败读成"零权限"……
//      一次瞬时故障和一次蓄意收权,在界面上长得一模一样。"
//
// 那一条讲权限,这一条讲会话,而它们是同一句话。**下一个人多半会先遇到那个兄弟,
// 所以这里点它的名。** 同族的还有 `restRows`(失败不是空集)、`! pgrep`(进程没了
// 不等于备份好了)、以及部署那条(下游登记的缺席不是事件的缺席)。
//
// ────────────────────────────────────────────────────────────────────────────
// 【实测:三类是分得开的】(SESSION-1,2026-08-23,一次性账号,已删)
//
//   情形                                          user   耗时      error
//   ─────────────────────────────────────────────────────────────────────────
//   A 没有 cookie,网络正常   → 真的没登录        null      5ms   AuthSessionMissingError 400
//   B 有效会话,网络正常      → 已登录            有     2302ms   (无)
//   C 有效会话,fetch 抛错    → 判断不出          null      3ms   AuthRetryableFetchError status=0
//   D 有效会话,认证返回 503  → 判断不出          null      0ms   AuthRetryableFetchError status=503
//   E 令牌已过期,fetch 抛错  → 判断不出          null  25412ms   AuthRetryableFetchError status=0
//   F 令牌已过期,认证 503    → 判断不出          null  25412ms   AuthRetryableFetchError status=503
//   G 刷新令牌无效,网络正常  → 真的被吊销了      null   2377ms   AuthApiError 400 validation_failed
//
// **七种情形,此前全部走 `!user` 那一条分支。** 而 `error` 把它们干净地分成三类:
//   * `AuthRetryableFetchError` → **判断不出**(C/D/E/F)
//   * `AuthApiError` / `AuthSessionMissingError` → **确立的否定**(A/G)
//   * 无 error 且有 user → 已登录(B)
//
// 【不要在这里加重试 —— 已经有一个 25 秒的了】E/F 那两行 25412ms 不是网络慢,是
// `@supabase/auth-js` 自己在内部重试。**在一个 25 秒的重试上面再加一层,不是谨慎,
// 是第二次挂起。** 而 C/D 那两行 0–3ms 说明另一半:令牌还没过期时它根本不重试。
// 两头都不需要我们再加。这句话写在这里,是因为这正是下一个人会想动手的地方。
//
// 【为什么是 fail closed(挡住),不是 fail open(放行)】
// 放行的论据是真的:中间件**不是**安全边界 —— JWT 由 Postgres 自己验签验期,
// 混过中间件的令牌到了库那一侧照样被拒。但那要先量一件今天没人量过的事:
// **有没有哪个页面直接拿令牌自己的 claim 去渲染(名字、角色、id)而不读库?**
// 有,那就是真正的风险面。**所以放行是单独一刀**,条目在 docs/known-issues.md。
// 本刀挡住,并且【说出来】。代价照直写:一次短暂的认证故障从此**更显眼**,
// 而不是更轻 —— 今天它是静默地把所有人扔到登录页并毁掉他们打的字。
//
// 【爆炸半径,写在这里因为它不直观】C/D 两行说明:认证一断,**每一个登录着的人
// 立刻同时掉线** —— 不只是那些恰好在刷新的人,连令牌还剩 59 分钟的人也一样,
// 0–3 毫秒,毫无预兆。完整记录见 docs/known-issues.md 的 AUTH-BLAST-RADIUS 条。
// ════════════════════════════════════════════════════════════════════════════
import { createServerClient } from '@supabase/ssr'
import type { Database } from '@/lib/database.types'
import { NextResponse, type NextRequest } from 'next/server'

const PUBLIC_PATHS = ['/login']

/**
 * 【判断不出】的判据,只有一处定义。
 *
 * `AuthRetryableFetchError` 是 auth-js 对"这次没能问到答案"的名字 —— 网络抛错
 * (status 0)与上游 5xx 都归它。其余一切(`AuthApiError`、
 * `AuthSessionMissingError`、以及干脆没有 error)都是**确立的**答案。
 *
 * 【为什么按 name 认,而不是按 status】status 在 C 是 0、在 D 是 503,而
 * `AuthApiError` 也可以是 400 —— 数字分不开这两类,类名分得开。auth-js 给这个类
 * 起这个名字,要表达的正是"可以再试",也就是"这一次我没有答案"。
 */
function cannotDetermine(err: unknown): boolean {
    return !!err && typeof err === 'object' && (err as { name?: string }).name === 'AuthRetryableFetchError'
}

// 【这两句话为什么不在 messages/ 里】中间件在每一个请求上跑,而 `MESSAGES` 是
// 两套完整的语言包 —— 把它整个拉进中间件的包里,是为了两句话付全站每一次请求的账。
// 所以就近放两句,并且两种语言都直接写在这里。**这是一次刻意的例外,不是漏做**:
// check-i18n 只认翻译函数的调用点,它对本文件本来就无话可说,不会有人以为这里
// 被检查过。(这一行原本举了一个那种调用的例子,而 check-i18n 当场把例子当成了
// 真的调用并报缺键 —— 一个按文本找调用的检测器分不出代码与注释,PROC-CLEANUP
// 为同一件事记过一笔。例子因此删掉,而不是给检查加一条例外。)
const COPY = {
    zh: {
        title: '暂时确认不了你的登录状态',
        lead: '系统联系不上认证服务,所以它【不知道】你是不是还登录着 —— 这【不是】说你被登出了。',
        keep: '你的会话很可能好好的。这一页什么都没有保存,也什么都没有丢。',
        retry: '重试',
        path: '你要去的是',
    },
    en: {
        title: 'Cannot confirm your sign-in right now',
        lead: 'The system could not reach the authentication service, so it does not KNOW whether you are still signed in — this does NOT mean you were signed out.',
        keep: 'Your session is most likely fine. Nothing was saved on this page, and nothing was lost.',
        retry: 'Retry',
        path: 'You were going to',
    },
} as const

/**
 * 【判断不出】时的应答 —— 503,而且它永远说同一句话。
 *
 * * **503 + Retry-After**,不是 200。一个 200 等于断言"这次请求成功了",而这次
 *   请求根本没能被判断 —— 那与本文件顶上那条谎是同一句,只是换了一层。
 *   冒烟断言 2xx,所以认证真的不通时冒烟会红 —— **那是对的**,那时确实有东西坏了。
 * * **绝不退化成 /login。** 故障持续下去,它就一直这么说:系统确实不知道,
 *   它就应当一直这么讲。把它熬成一次登出,是把"不知道"改写成"你没登录"。
 * * **保住原路径**,重试就回到人本来要去的地方。
 * * `data-auth-indeterminate` 是给冒烟/走查用的机器标记 —— 靠认文案去分辨会漏,
 *   与 moduleGuard 的 `data-access-denied` 同一条理由。
 */
function cannotDetermineResponse(request: NextRequest) {
    const locale = request.cookies.get('NEXT_LOCALE')?.value === 'en' ? 'en' : 'zh'
    const c = COPY[locale]
    const target = request.nextUrl.pathname + request.nextUrl.search
    const esc = (s: string) => s.replace(/[&<>"]/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[ch]!))
    const html = `<!doctype html><html lang="${locale}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(c.title)}</title></head>
<body data-auth-indeterminate="1" style="font-family:system-ui,-apple-system,'Segoe UI',sans-serif;background:#f9fafb;margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:1rem">
<main style="max-width:34rem;background:#fff;border:1px solid #d1d5db;border-radius:.5rem;padding:2rem">
<h1 style="font-size:1.25rem;font-weight:700;margin:0 0 1rem">${esc(c.title)}</h1>
<div style="background:#fffbeb;border:1px solid #fcd34d;color:#78350f;padding:.75rem 1rem;border-radius:.375rem;font-size:.875rem;line-height:1.6">
<p style="margin:0 0 .5rem">${esc(c.lead)}</p><p style="margin:0">${esc(c.keep)}</p></div>
<p style="font-size:.75rem;color:#6b7280;margin:1rem 0 0">${esc(c.path)} <code>${esc(target)}</code></p>
<p style="margin:1rem 0 0"><a href="${esc(target)}" style="display:inline-block;background:#2563eb;color:#fff;padding:.5rem 1rem;border-radius:.375rem;text-decoration:none;font-size:.875rem">${esc(c.retry)}</a></p>
</main></body></html>`
    return new NextResponse(html, {
        status: 503,
        headers: {
            'Content-Type': 'text/html; charset=utf-8',
            'Retry-After': '10',
            'Cache-Control': 'no-store',
        },
    })
}

export async function updateSession(request: NextRequest) {
    let supabaseResponse = NextResponse.next({ request })

    const supabase = createServerClient<Database>(
        process.env.NEXT_PUBLIC_SUPABASE_URL!,
        process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
        {
            cookies: {
                getAll() {
                    return request.cookies.getAll()
                },
                setAll(cookiesToSet) {
                    cookiesToSet.forEach(({ name, value }) =>
                        request.cookies.set(name, value)
                    )
                    supabaseResponse = NextResponse.next({ request })
                    cookiesToSet.forEach(({ name, value, options }) =>
                        supabaseResponse.cookies.set(name, value, options)
                    )
                },
            },
        }
    )

    // IMPORTANT: do not put any code between createServerClient and getUser()
    // 【error 必须接住】—— 丢掉它,下面那个 `!user` 就同时代表七种情形(抬头那张表)。
    // getUser() 除了返回 error,也可能直接抛(实测过);抛出来的同样是"判断不出",
    // 不是"没登录",所以 catch 走同一条路。
    let user = null
    let authError: unknown = null
    try {
        const res = await supabase.auth.getUser()
        user = res.data.user
        authError = res.error
    } catch (e) {
        authError = e
    }

    const pathname = request.nextUrl.pathname
    const isPublic = PUBLIC_PATHS.some(
        (p) => pathname === p || pathname.startsWith(p + '/')
    )

    // 【判断不出】—— 挡住,并说出来。放在 `!user` 之前,因为这两种情形的 user 都是 null。
    // 公开路径放行:登录页本来就不需要会话,而认证不通时登录本身会各自报它的错。
    if (cannotDetermine(authError) && !isPublic) {
        return cannotDetermineResponse(request)
    }

    if (!user && !isPublic) {
        const url = request.nextUrl.clone()
        url.pathname = '/login'
        // 【说出【为什么】在这里】—— 走到这一步的否定是【确立的】(A/G),
        // 所以登录页可以照直说"你的登录已经结束",而不是摆一张没有任何说明的表单。
        // 一张沉默的登录表单,与一次崩溃在屏幕上长得一模一样。
        //
        // 【但"结束了"也必须是一句立得住的话 —— 它要求先有过一个会话】
        // 一个**从来没登录过**的人直接敲一条受保护的 URL,同样落到这里。对他说
        // "你的登录已经结束"是同一族的小谎:又一次说出一个没有确立的原因,
        // 只是这次方向反了。判据取【请求里带没带认证 cookie】—— 带了就是真的有过
        // 一个会话(如今它无效了);没带就是从来没有,那时什么都不说才是对的。
        const hadSession = request.cookies
            .getAll()
            .some((c) => /^sb-.+-auth-token(\.\d+)?$/.test(c.name))
        if (hadSession) url.searchParams.set('reason', 'ended')
        url.searchParams.set('next', pathname + request.nextUrl.search)
        return NextResponse.redirect(url)
    }

    // IMPORTANT: must return supabaseResponse as-is so cookies flow through
    return supabaseResponse
}
