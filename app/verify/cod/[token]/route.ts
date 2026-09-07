// app/verify/cod/[token]/route.ts
// ════════════════════════════════════════════════════════════════════════════
// COD-2:销毁证书的核验页 —— 本系统【第一条不需要会话】的路由
// ════════════════════════════════════════════════════════════════════════════
//
// 【地址不是这一刀挑的】COD-1 已经把它烧进了每一张证书的二维码里:
//     app/inbound/[id]/cod/pdf/route.tsx:34
//     verificationUrl = (origin, token) => `${origin}/verify/cod/${token}`
// 所以这一刀要么建出这条路径,要么那些纸指向一个 404。
//
// ★【网址里带的是【令牌】,不是证书号】★ 令牌是 122 位随机的 UUID,与
//   COD-YYYY-NNNN 毫无关系 —— **改一位数字得到的是一个不存在的值,
//   而不是别人的那一份文件**。这正是它不能由号码推出来的全部理由。
//
// 【放行是在中间件里做的,而那是一次刻意的改宽】lib/loginRoute.ts 的
//   PUBLIC_PATHS 从 ['/login'] 变成 ['/login', '/verify/cod'] —— 取最窄的前缀,
//   理由写在那个文件里。
//
// 【为什么是 route 而不是 page】三条,写在 verifyHtml.ts 抬头:状态码(200/404/
//   429/503,page 组件给不出来)、给整个互联网的那一页应该零客户端 JS 零 RSC
//   负载零应用外壳、以及仓库里已有的那条路(label/route.ts + labelHtml.ts)。
//
// 【取数走 anon,而这是【故意】的】这里【不】用 service_role 抄近路:
//   页面走的路必须和一个拿着公开 anon key 的人走的路【是同一条】,
//   否则"匿名够得着什么"这句话就取决于是谁在问,而那种保证是假的。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import {
    renderCertificate, renderNotFound, renderThrottled, renderUnavailable,
    type VerifyOk,
} from '@/app/verify/cod/verifyHtml'

// 【绝不缓存】一张证书可能在任何一刻被作废,而这一页是【原件】。
// 一份缓存下来的"有效"会比没有这一页更坏。
export const dynamic = 'force-dynamic'
export const revalidate = 0

function html(body: string, status: number, extra: Record<string, string> = {}) {
    return new Response(body, {
        status,
        headers: {
            'Content-Type': 'text/html; charset=utf-8',
            'Cache-Control': 'no-store, max-age=0',
            // 【搜索引擎不该收录任何一张证书】meta 标签也有一份 —— 两道都要,
            // 因为爬虫抓到 404/429 时根本不解析 body。
            'X-Robots-Tag': 'noindex, nofollow',
            'Referrer-Policy': 'no-referrer',
            ...extra,
        },
    })
}

export async function GET(
    _request: NextRequest,
    { params }: { params: Promise<{ token: string }> }
) {
    const { token } = await params

    // ★【格式判据【不在这里】】★ 这里不检查 token 长什么样,也不 try/catch 它的
    //   形状 —— 那个判据住在数据库函数里,因为"不认识"与"格式不对"必须回
    //   【同一句话】,而两处判据迟早会各说各话。这里原样递过去。
    let payload: unknown = null
    try {
        const supabase = await createClient()
        const { data, error } = await supabase.rpc('cod_verification', { p_token: token })
        if (error) {
            // ★【问不到答案 ≠ 这份证书不存在】★ 与 lib/supabase/middleware.ts
            //   抬头那条逐字同源。对着一份【有人正拿在手里】的法律文件,
            //   把一次瞬时故障说成"查无此证",是这一页能犯的最坏的错。
            //   所以它回 503,不回 404 —— 而冒烟断言 2xx,所以真坏了会红。
            return html(renderUnavailable(), 503, { 'Retry-After': '30' })
        }
        payload = data
    } catch {
        return html(renderUnavailable(), 503, { 'Retry-After': '30' })
    }

    const d = payload as { result?: string; retry_after_seconds?: number } | null

    // 【空答案也不许被读成"没有这张证书"】函数总是回一个 result;
    // 回了别的东西说明这一层与函数不同步,那是故障,不是答案。
    if (!d || typeof d.result !== 'string') {
        return html(renderUnavailable(), 503, { 'Retry-After': '30' })
    }

    if (d.result === 'throttled') {
        const secs = Number(d.retry_after_seconds) || 60
        return html(renderThrottled(secs), 429, { 'Retry-After': String(Math.ceil(secs)) })
    }
    if (d.result === 'ok') {
        return html(renderCertificate(payload as VerifyOk), 200)
    }
    // ★ not_found —— 令牌不认识,或者格式不对。**同一页,同一个状态码。** ★
    return html(renderNotFound(), 404)
}
