'use client'

// app/components/home/RememberGreeting.tsx
// ════════════════════════════════════════════════════════════════════════════
// UI-1b ① · 把刚刚显示的那一句记下来,好让下一次不重样
// ════════════════════════════════════════════════════════════════════════════
//
// 【它渲染 null。它存在的全部理由是一次 cookie 写入。】
//
// ★★【为什么这件事非得由客户端做 —— 而委托书说的是 httpOnly】★★
// **在 Next 16 里,一个服务端组件 set 不了 cookie。** 逐字出处:
// `node_modules/next/dist/docs/01-app/03-api-reference/04-functions/cookies.md:73`
// ——「HTTP does not allow setting cookies after streaming starts, so you must
//    use `.set` in a Server Function or Route Handler.」
// 首页是一次普通的 GET 渲染,既不是 Server Function 也不是 Route Handler。
//
// 剩下唯一能设 httpOnly 的地方是中间件,而那条路要中间件【自己挑这一句】——
// 它得知道这个时段有几句、上一句是哪一句,也就是**在全站每一个请求上多查一次库**。
// `lib/loginRoute.ts` 抬头为这件事记过账。为一行问候语付那笔钱,不划算。
//
// ★【httpOnly 在这里本来也买不到东西】★ cookie 里存的是一句问候语的 id ——
//   不是凭据、不是身份,也推不出别的任何东西。httpOnly 防的是 XSS 读取它,
//   而这里没有值得读的东西。**这是一处对委托书的偏离,写在这里,也写进报告。**
//
// 【cookie 不在会怎样】—— 下一次不排除任何句子,于是"可能重样一次"。
// **永远不会因此变成一片空白**:排除项是可选的(lib/homeGreeting.ts:pickGreeting)。
// 这正是 FIX-2a 那条规矩的正面写法 —— 一次缺席退化成一点点冗余,不退化成一个谎。
//
// 【为什么 12 小时】一个时段最长 8 小时(深夜 22:00–05:59),12 小时足以覆盖
// 「同一个时段里连着刷两次」这件它要防的事,又不至于让一句昨天的问候
// 影响明天早上的挑选。
import { useEffect } from 'react'
// ★【从【纯核】取,不从 lib/homeGreeting 取】★ 后者 import 了 next/headers 与
//   supabase 服务端客户端;一个 'use client' 文件 import 它,就是把服务端模块
//   拖进浏览器包 —— 构建会红,而红的位置离原因很远。纯核零 import,安全。
import { GREETING_COOKIE } from '@/lib/homeGreetingCore'

export default function RememberGreeting({ id }: { id: string }) {
    useEffect(() => {
        // SameSite=Lax:它只跟着本站导航走,没有任何跨站用途。
        // 不写 Secure —— 本地开发是 http,写了它在 dev 上就静默不生效,
        // 于是"排除上一句"这件事在开发机上永远测不出来。生产是 https,
        // 而这个值不是秘密(见抬头),所以这里选【测得出来】而不是【看起来更严】。
        document.cookie = `${GREETING_COOKIE}=${encodeURIComponent(id)}; path=/; max-age=43200; samesite=lax`
    }, [id])
    return null
}
