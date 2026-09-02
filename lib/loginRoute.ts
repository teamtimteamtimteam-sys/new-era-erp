// lib/loginRoute.ts
// ════════════════════════════════════════════════════════════════════════════
// LOGIN-1-fu1(2026-09-02)· 关于 /login 的两件事,各自【只定义一次】
//
// 这个文件存在的理由是:这两个判据此前【各有两份拷贝】,而它们都是安全判据。
//   · 「哪些路径不需要会话」—— 原本只在 lib/supabase/middleware.ts 里;
//     现在根布局也要用它(决定画不画顶栏),再抄一份就会有两份漂移的真相。
//   · 「?next= 收不收」—— 原本在 app/login/page.tsx 与 app/login/actions.ts 里
//     各写了一遍(注释还特地说明「两处逐字相同」)。**逐字相同要靠人守,
//     而这正是它迟早会不同的原因。** 现在中间件也要用它(登录着的人被送去哪儿),
//     第三份拷贝不该存在。
//
// 【这个文件必须保持极小】它被 middleware import,而中间件的包在【每一个请求】
// 上都要付账 —— 同一个文件的抬头为「两句话不值得拉进整个语言包」记过一次。
// 这里只有两个纯函数、零依赖。
// ════════════════════════════════════════════════════════════════════════════

/** 不需要会话就能看的路径。中间件用它放行,根布局用它决定不画应用外壳。 */
export const PUBLIC_PATHS = ['/login'] as const

export function isPublicPath(pathname: string): boolean {
    return PUBLIC_PATHS.some((p) => pathname === p || pathname.startsWith(p + '/'))
}

/**
 * 【只接内部路径】—— 收下 `?next=`,或者干脆不要。
 *
 * 判据是【白名单式】的:必须以单个 `/` 开头,而且第二个字符不能把它变成
 * 一个跳出本站的地址。不合格的一律返回 null —— **不修补、不猜、不退而求其次**,
 * 因为一个"尽量修好的重定向目标"正是开放重定向的经典成因。
 *
 * ★【这次补上了一个洞:反斜杠】★
 * 原来的判据是 `startsWith('/') && !startsWith('//')`。它漏掉了 `/\evil.com`:
 * **浏览器在解析 URL 时会把反斜杠当成斜杠**,于是那个串等价于 `//evil.com`,
 * 也就是一个协议相对的外站地址 —— 判据放行,浏览器跳出去。
 * 这一刀把这个判据【搬到了中间件里】(登录着的人按 next 送进应用),
 * 洞因此变得更好够得着,所以顺手堵上,而不是照抄一份带洞的。
 */
export function safeInternalPath(raw: unknown): string | null {
    if (typeof raw !== 'string') return null
    if (!raw.startsWith('/')) return null
    // `//host` 与 `/\host` 都是「跳出本站」
    if (raw.startsWith('//') || raw.startsWith('/\\')) return null
    return raw
}
