// app/portal/documents/file/route.ts
// MES-9b(2026-10-19,MES-9 Step 0 Q14 · Q22 · §3,Tim):【门户取一份签发档】GET ?kind=<purchase_order|supplier_statement|cod>&id=<签发记录 id>
//   ① 以这个请求【自己的会话】调 portal_document_open() —— 它先过 portal_require_link(角色 · 链接 · 撤销 · 会话),确认那一份属于调用者自己
//      那一家、没有作废,然后写一行下载记录(Q22),交出桶、路径与签发时记下的 sha256;
//   ② 以【同一个会话的令牌】从桶里取字节 —— 存储策略只放行两分钟内刚记过的那一个对象(portal_can_read_object),所以绕过这条路由直接去
//      Storage API 取是取不到的;【不用 service role】(lib/supabase/admin.ts:那把钥匙不读业务数据);
//   ③ 对着记下的 sha256 重算 —— 对不上就 409(与员工那三条 PDF 路由同一句:一份与记录不符的"档案"比没有档案更坏);对上了才交出字节。
//   【绝不按活数据渲染】这里没有渲染器:没有存档的、作废的、别家的,一律拒,不"临时画一份"。
//   一个员工会话打开它 → 403(门户函数只授 supplier_portal;smoke 以员工会话登记 [403])。
//   响应文字一律英文(与员工那三条 PDF 路由一致);错误码的人话走 portal.errors.*。
import { NextResponse } from 'next/server'
import { createHash } from 'node:crypto'
import { createClient } from '@/lib/supabase/server'
import { isPortalSession } from '@/lib/portalSession'
import { localizePortalError } from '../../portalErrorCodes'

const KINDS = new Set(['purchase_order', 'supplier_statement', 'cod'])
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

type Opened = { log_id: string; bucket: string; file_path: string; sha256: string; filename: string }

// 与 app/purchasing/orders/[id]/pdf/route.ts 同一套响应头转义(RFC 6266/5987)—— 文件名是拼进 HTTP 头的
function contentDispositionFilename(name: string): string {
    const ascii = name
        .replace(/[^\u0020-\u007e]/g, '_')
        .replace(/["\\]/g, '\\$&')
    return `filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(name)}`
}

function text(body: string, status: number) {
    return new NextResponse(body, { status, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' } })
}

export async function GET(request: Request) {
    if (!(await isPortalSession())) return text('This download is for supplier portal sessions.', 403)
    const url = new URL(request.url)
    const kind = url.searchParams.get('kind') ?? ''
    const id = url.searchParams.get('id') ?? ''
    if (!KINDS.has(kind) || !UUID_RE.test(id)) return text('Unknown document.', 400)

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('portal_document_open', { p_kind: kind, p_issue_id: id })
    if (error) {
        const { code, text: said } = await localizePortalError(error.message)
        const status = code === 'PORTAL_DOCUMENT_NOT_FOUND' || code === 'PORTAL_DOCUMENT_KIND_UNKNOWN' ? 404
            : code === 'PORTAL_DOCUMENT_VOID' ? 410
            : error.code === '42501' || (code ?? '').startsWith('PORTAL_') ? 403
            : 500
        return text(said, status)
    }
    const opened = data as unknown as Opened

    const dl = await supabase.storage.from(opened.bucket).download(opened.file_path)
    if (dl.error || !dl.data) return text('Stored document unavailable', 404)
    const bytes = Buffer.from(await dl.data.arrayBuffer())
    const sha = createHash('sha256').update(bytes).digest('hex')
    if (sha !== opened.sha256) {
        return text('Stored document does not match its recorded digest', 409)
    }
    return new NextResponse(new Uint8Array(bytes), {
        headers: {
            'Content-Type': 'application/pdf',
            'Content-Disposition': `attachment; ${contentDispositionFilename(opened.filename)}`,
            'Cache-Control': 'no-store',
        },
    })
}
