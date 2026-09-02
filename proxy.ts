// proxy.ts
import { type NextRequest } from 'next/server'
import { updateSession } from '@/lib/supabase/middleware'

export default async function proxy(request: NextRequest) {
    return await updateSession(request)
}

export const config = {
    // ════════════════════════════════════════════════════════════════════════
    // 【静态图片必须排除在认证闸口之外 —— 少一个扩展名就是一个空白的登录页】
    //
    // 这份清单原本没有 `avif`。LOGIN-1-fu1 把底图换成 AVIF 之后:
    //     GET /brand/login-field-1280.avif
    //       → 中间件认为这是【受保护的路径】(它不在公开清单里)
    //       → 307 到 /login?next=…
    // **而请求这张图的人,恰恰是【还没登录】的那些人** —— 登录页的全部观众。
    // <picture> 一旦按 type 选中 AVIF 那一支就【不会再回退到 <img>】,
    // 所以屏幕上不是「退化成 WebP」,是【整块底图空白】。
    //
    // 【它是怎么被抓到的】断言写的是 `r.ok`,而 fetch 默认跟随重定向 ——
    // 那条 307 被跟到 /login,拿回一份 200 的 HTML,断言【绿了】。
    // 真正戳破它的是【量字节】:两个不同尺寸的 AVIF 都回了 20 KB,
    // 正好是登录页 HTML 的大小。**一条只看状态码的断言,证明不了拿到的是一张图。**
    //
    // ★【fu2:照片撤了,而这一条【留着】—— 这是刻意的,不是漏删】★
    // 今天 public/ 下【一个 .avif 都没有】,所以它此刻没有消费者。
    // 但这份清单表达的不是「我们现在有哪些图」,而是
    // **「哪些静态图片类型【永远】不该被认证闸口拦下」** ——
    // avif 属于这一类,与 svg/png/jpg/webp 并列,与今天有没有用它无关。
    // 把它删掉是那种「看起来是清理、实际是把陷阱重新装上」的改动:
    // 下一个往 public/ 放 .avif 的人(favicon、图标、任何图)会原样再踩一遍,
    // 而这个 bug 的表现是【空白】加上【状态码断言仍然绿着】,极难看出来。
    // ════════════════════════════════════════════════════════════════════════
    matcher: [
        '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|avif)$).*)',
    ],
}
