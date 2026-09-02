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
import { ACTIVITY_COOKIE, isIdleExpired } from '@/lib/session'
// 【一处定义】公开路径与 ?next= 的判据都在这里 —— 根布局与登录页读的是同一份。
import { isPublicPath, safeInternalPath } from '@/lib/loginRoute'

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
    // ════════════════════════════════════════════════════════════════════════
    // 【把 pathname 放进请求头,给根布局用】(LOGIN-1-fu1,2026-09-02)
    //
    // 服务端组件【拿不到当前路径】—— React Server Component 里没有这个 API。
    // 而根布局必须知道自己在哪一页,才能决定【不画】顶栏与空闲监视器:
    // /login 是「人还没进系统」的那一屏,它不该有导航、通知、登出、模块清单。
    //
    // 【为什么不用路由组(route group)】那才是 Next 的标准做法,但它要求把
    // 200 多个路由目录整个搬进 `(chrome)/` 里 —— 一次巨大的、与本刀无关的改动,
    // 而收益完全一样。这里用一个请求头,四行,作用域清清楚楚。
    // 【为什么不在客户端判】客户端组件返回 null 只是不挂载,TopNav 的服务端
    // 取数(getUser、权限查询)照样会跑,导航数据照样进 RSC 负载 —— 那不叫「没有外壳」。
    // ════════════════════════════════════════════════════════════════════════
    const requestHeaders = new Headers(request.headers)
    requestHeaders.set('x-pathname', request.nextUrl.pathname)

    let supabaseResponse = NextResponse.next({ request: { headers: requestHeaders } })

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
                    supabaseResponse = NextResponse.next({ request: { headers: requestHeaders } })
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
    const isPublic = isPublicPath(pathname)

    // ════════════════════════════════════════════════════════════════════════
    // 【空闲超时:这里【只读】那个 cookie,永远不写它】(IDLE-DRAFT,2026-08-24)
    //
    // ★ 这一段是整个空闲超时的承重墙,而它承重的方式是【一件没有做的事】。★
    //
    // 中间件跑在【每一个请求】上 —— 包括 Next.js 的 RSC 预取、后台重新校验、
    // 以及任何轮询。**如果这里顺手把 last-activity 刷新一下**(那看起来非常自然,
    // "既然有请求进来,人当然还在"),那么一台无人看管的平板只要开着这一页,
    // 它自己的预取就会把会话永远续下去 —— **超时从此永远不会触发,而屏幕上
    // 一切正常。** 那不是一个失效的功能,那是一个演出来的功能。
    //
    // 所以分工是死的:
    //   · **浏览器决定什么算活动**(真的按键、真的指针、真的换页),它写这个 cookie;
    //   · **中间件只负责执行**,它读,并且只读。
    //
    // 【下一个人最可能"顺手修好"的就是这里】如果你看到这一段觉得"少写了一句
    // 刷新",请先读上面这三段。加上那一句,这套东西会安静地全部失效。
    //
    // 【cookie 不在 = 不算过期,这也是刻意的】刚上线时没有人带着这个 cookie;
    // 把"没有标记"读成"已经空闲很久",会在部署的那一刻把所有人踢下线 ——
    // 那正是本仓库反复说的「空集不是一个答案」。第一次真实活动会把它种上。
    // ════════════════════════════════════════════════════════════════════════
    const rawActivity = request.cookies.get(ACTIVITY_COOKIE)?.value
    const lastActivity = rawActivity ? Number(rawActivity) : null
    const idleExpired = isIdleExpired(lastActivity)

    // 【判断不出】—— 挡住,并说出来。放在 `!user` 之前,因为这两种情形的 user 都是 null。
    // 公开路径放行:登录页本来就不需要会话,而认证不通时登录本身会各自报它的错。
    if (cannotDetermine(authError) && !isPublic) {
        return cannotDetermineResponse(request)
    }

    // ════════════════════════════════════════════════════════════════════════
    // 【已经登录的人,不该被再问一次「请登录」】(LOGIN-1-fu1,2026-09-02)
    //
    // 实测的缺陷:带着有效会话打开 /login,顶栏画着 admin@swm-os.test 和一个
    // 「登出」按钮,而页面正中要【同一个人】登录。屏幕上两句话互相矛盾,
    // 而其中一句必然是假的。
    //
    // 【为什么判据放在中间件,而不是登录页里】
    //   ① 中间件【已经】问过 auth 了(上面那个 getUser)。放在页面里就是同一个
    //      请求里问【第二次】—— 而实测有效会话那一次要 2.3 秒(见抬头七情形表)。
    //      为了一句判断把每一次登录页访问都加上一趟往返,不划算。
    //   ② 「登录着 / 确立地没登录 / 判断不出」这个三分【只在这里成立过一次】。
    //      在页面里重做一遍,就是把那张七情形表重新实现一遍 —— 而它一旦实现得
    //      不一样(比如把 AuthRetryableFetchError 当成「没登录」),
    //      一次瞬时的认证故障就会变成「把人送进应用」或「把人挡在门外」。
    //   ③ 重定向发生在渲染之前:登录页的 HTML 一个字节都不会被生成,
    //      顶栏那半个缺陷也就【顺带】没有了 —— 但那不是本条的主要修法,
    //      外壳由根布局按 x-pathname 结构性地排除(见本文件抬头)。两道都要有。
    //
    // 【条件为什么带 !idleExpired】空闲超时的人 user 仍然非空(cookie 还在)。
    // 把他送进应用,下一跳又会被判过期弹回 /login —— 两跳之后才停,而且中间
    // 那一跳毫无意义。让他留在登录页重新登录,才是他真正要做的事。
    //
    // 【SESSION-1 那条刻意的沉默原样保住】没有登录的人干净地打开 /login,
    // 走不到这里(user 为 null),页面照旧【什么都不说】。
    if (user && !idleExpired && pathname === '/login') {
        // ?next= 的判据【不在这里重写】—— 与登录页、登录动作用的是同一个函数。
        const target = safeInternalPath(request.nextUrl.searchParams.get('next')) ?? '/suppliers'
        const dest = new URL(target, request.nextUrl.origin)
        const redirect = NextResponse.redirect(dest)
        // 【把刷新过的会话 cookie 带上】getUser() 可能刚刚续了令牌;
        // 丢掉它们等于把这次刷新白做一遍,下一跳还得再刷一次。
        for (const c of supabaseResponse.cookies.getAll()) redirect.cookies.set(c)
        return redirect
    }

    // 【走【同一条】分支,不另起一条】(IDLE-DRAFT 3.3)
    // SESSION-1c 已经在这里建好了那个区别:只有【请求里真的带着认证 cookie】时
    // 才说"你的登录已经结束"。空闲超时必须借这条路走,而不是自己再造一条 ——
    // 造第二条就等于把那个已经修好的谎重新实现一遍。
    // 空闲超时发生时,认证 cookie 必然还在(会话本来是好的,是我们让它结束的),
    // 所以下面那个 hadSession 判据自然为真,人会看到"你的登录已经结束"。
    // 而一个【从来没登录过】的人不可能触发 idleExpired 之外的这条路:他没有
    // 认证 cookie,hadSession 为假,于是什么都不说 —— 那个区别原样保住。
    if ((!user || idleExpired) && !isPublic) {
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
        const redirect = NextResponse.redirect(url)
        // 【空闲超时要真的把会话结束掉】否则人一刷新就又进来了 —— 那就不是超时,
        // 是一次跳转。清掉认证 cookie 与活动标记本身(留着它,下一次请求会
        // 再判一次过期,人会被反复弹回登录页)。
        if (idleExpired) {
            for (const c of request.cookies.getAll()) {
                if (/^sb-.+-auth-token(\.\d+)?$/.test(c.name)) redirect.cookies.delete(c.name)
            }
            redirect.cookies.delete(ACTIVITY_COOKIE)
        }
        return redirect
    }

    // IMPORTANT: must return supabaseResponse as-is so cookies flow through
    return supabaseResponse
}
