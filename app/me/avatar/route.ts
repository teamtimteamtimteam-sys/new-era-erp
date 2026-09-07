// app/me/avatar/route.ts
// ════════════════════════════════════════════════════════════════════════════
// COD-2 ③:头像的字节从这里出去 —— UI-1d 自己写下的那条替代方案 (b)
// ════════════════════════════════════════════════════════════════════════════
//
// 【这不是一个新设计,是一条被预约好的改动】
//   db/migrations/2026-09-05-ui1d-avatar-bucket.sql 在收下那个公开桶时,把后果
//   与【重开这个决定的条件】一起写了下来,原文:
//     「**任何人猜中一个 user_id,就能不登录取到那个人的脸。**……
//       **地址本身把 auth uid 说了出去。**」
//     「(b) 私有桶 + 一个 Next 路由把字节代理出来(自带缓存头,地址里不出现 uid)
//       —— **这是人变多之后该走的那条路**……
//       人一多、或者哪天有了对外的门户,就重开这一条,并照 (b) 改。」
//   ★ 销毁证书的核验页就是那扇对外的门。★ 所以照 (b) 改,而不是另设计一套。
//
// ★★【(b) 落地得比它自己写的还干净:地址里【连一个标识符都没有】】★★
//   实测(2026-09-08)全仓库只有两处画头像,而两处画的都是【当前登录者自己】:
//       app/components/TopNav.tsx     app/me/page.tsx
//   **没有任何一页画别人的头像。** 于是这条路由不需要参数:它服务谁,
//   由会话说了算。uid 不是"换了个地方",是从地址里【消失了】。
//   (UI-1d 当初否掉"挂到 employees 上"的理由因此也不受影响:对象名仍然是
//    <auth uid>.webp,没有员工档案的账号照样有头像。)
//
// 【读用的是【调用者自己】的会话,不是 service_role】
//   storage.objects 上 UI-1d 建的四条策略一个字没改,其中
//       "own avatar read": bucket_id = 'avatars' AND name = auth.uid()||'.webp'
//   本来就允许本人读自己那一行 —— 桶公开的时候这条策略几乎没有读者
//   (/object/public/… 那条路【不过 RLS】),从今天起它才真的开始干活。
//   ★ 用 service_role 代读会把"只能拿到自己的"这句话从策略手里拿走,
//     交给这个文件的写法 —— 而 UI-1d 明写着它要的正是【由策略回答】。★
//
// 【两个既有对象:一个字节都没动】桶从 public 翻成 private,对象名不变,
//   策略不变。它们照常画得出来,只是从今天起要有会话。
import { createClient } from '@/lib/supabase/server'
import { AVATAR_BUCKET, AVATAR_CACHE_SECONDS, avatarObjectName } from '@/lib/avatar'

export const dynamic = 'force-dynamic'

export async function GET() {
    const supabase = await createClient()

    // ★【「判断不出」与「这个人没登录」是两件事】★ 丢掉 error,两者就走同一条分支。
    //   判据与那张七情形实测表在 lib/supabase/middleware.ts 的抬头 ——
    //   本仓库这条规矩的参考实现就在那里,这里照它分三类:
    //     AuthRetryableFetchError → 判断不出 → 503(【不】说"你没登录")
    //     其余 error / 没有 user  → 确立的否定 → 401
    //     有 user                 → 发字节
    //   【为什么一张头像也值得分这一次】两种都会被 AvatarImage 接住、都回落成首字母,
    //   所以【屏幕上看不出区别】—— 而那正是这条规矩存在的理由:一个看不出区别的
    //   地方,是谎话最便宜的地方。代价是三行。
    let user = null
    let authError: unknown = null
    try {
        const res = await supabase.auth.getUser()
        user = res.data.user
        authError = res.error
    } catch (e) {
        authError = e
    }
    if ((authError as { name?: string } | null)?.name === 'AuthRetryableFetchError') {
        return new Response(null, { status: 503, headers: { 'Retry-After': '10' } })
    }
    // 【没有会话就没有头像可给】中间件本来就挡在前面(/me 不在 PUBLIC_PATHS 里),
    // 这一句是第二道:一条直接被敲的路由不该指望上游替它把关。
    if (!user) return new Response(null, { status: 401 })

    const { data, error } = await supabase.storage
        .from(AVATAR_BUCKET)
        .download(avatarObjectName(user.id))

    // ★【对象不在 = 404,而 404 是【预期内】的答案】★ AvatarImage 的 onError
    //   会回落成首字母 —— 那正是 UI-1d 立下的判据:「a missing, corrupt or
    //   unreachable avatar object degrades to the initials that are there today」。
    //   所以这里【不】把它包成 500,也不返回一张占位图。
    if (error || !data) return new Response(null, { status: 404 })

    return new Response(await data.arrayBuffer(), {
        headers: {
            'Content-Type': 'image/webp',
            // 【private,不是 public】地址如今是"当前这个人的头像",而不是
            // 一个人人相同的对象地址 —— 一个共享缓存把它存下来就会串脸。
            // 秒数与公开桶时代【同一个数】(lib/avatar.ts 的 AVATAR_CACHE_SECONDS),
            // 理由也没变:没有版本列,陈旧期靠 max-age 自己封顶。
            'Cache-Control': `private, max-age=${AVATAR_CACHE_SECONDS}`,
        },
    })
}
