// proxy.ts
import { type NextRequest } from 'next/server'
import { updateSession } from '@/lib/supabase/middleware'

export default async function proxy(request: NextRequest) {
    return await updateSession(request)
}

export const config = {
    // ════════════════════════════════════════════════════════════════════════
    // 【静态图片必须排除在认证闸口之外 —— 少一个扩展名就是一个空白的登录页】
    // (LOGIN-1-fu1,2026-09-02)
    //
    // 这份清单原本没有 `avif`。于是 LOGIN-1-fu1 把底图换成 AVIF 之后:
    //     GET /brand/login-field-1280.avif
    //       → 中间件认为这是一条【受保护的路径】(它不在公开清单里)
    //       → 307 到 /login?next=%2Fbrand%2Flogin-field-1280.avif
    // **而请求这张图的人,恰恰是【还没登录】的那些人** —— 也就是登录页的全部观众。
    // <picture> 一旦按 type 选中了 AVIF 那一支就【不会再回退到 <img>】,
    // 所以屏幕上不是"退化成 WebP",是【整块底图空白】。
    //
    // 【它是怎么被抓到的,值得写下来】断言写的是 `r.ok`,而 fetch 默认跟随重定向 ——
    // 于是那条 307 被跟到 /login,拿回一份 200 的 HTML,断言【绿了】。
    // 真正戳破它的是【量字节】:两个不同尺寸的 AVIF 都回了 20 KB,
    // 而那正好是登录页 HTML 的大小。**一条只看状态码的断言,证明不了拿到的是一张图。**
    // ════════════════════════════════════════════════════════════════════════
    matcher: [
        '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|avif)$).*)',
    ],
}
