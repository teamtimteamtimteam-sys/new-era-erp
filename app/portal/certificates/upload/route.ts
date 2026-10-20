// app/portal/certificates/upload/route.ts
// MES-9c(2026-10-20,MES-9 Step 0 §5 · V39 · Q27,Tim):【门户交一份证书】POST multipart(cert_type · cert_no · valid_from · valid_until · file)。
//   ★ 超过上限的、类型不对的,在【任何一个字节存下之前】按名拒 —— 判据只有一份,在库里(portal_submission_begin 读 V39):
//   ① 门户会话才进得来(员工会话 → 403;门户函数本来就只授 supplier_portal);
//   ② 先问库要 V39(portal_certificates 的 limits);请求体的 Content-Length 明显超过上限 → 不读请求体,直接按名拒(PORTAL_UPLOAD_TOO_LARGE);
//   ③ 读出文件,【按文件头认类型】(%PDF · FF D8 FF · 89 PNG),不信浏览器报的类型与扩展名;认不出 → 交给库的是 application/octet-stream
//      (库按名拒)—— 【绝不】退回浏览器报的那一个:一个改名成 .pdf、报成 application/pdf 的 GIF 就是这样溜进来的(本地证明抓到的);
//   ④ portal_submission_begin(类型 · 大小 · 证书字段)—— 库按 V39 判,拒了就带着码回 /portal/certificates,一个字节都没存;
//      过了,它登记一行 uploading,给出 portal-uploads 里的路径;
//   ⑤ 以【这个会话自己的令牌】把字节传进那条路径(不用 service role;存储策略只放行这一行登记过的路径)—— 桶自己再拦一道(10 MB · PDF / JPEG / PNG);
//   ⑥ portal_submission_finish 确认字节到了 → 一份等审核的申请;⑤ 或 ⑥ 失败 → portal_submission_abandon,带着码回去。
//   一份上传只是一份申请:没有证书行、没有库存 / 价钱 / 总账的改动(委托书);员工接受之前,什么都不改。
//   回 303 到 /portal/certificates?submitted=1 或 ?error=<码>[&p=<参数>](页面把码说成人话,portal.errors.*)。
import { NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { isPortalSession } from '@/lib/portalSession'

const BACK = '/portal/certificates'
const BODY_OVERHEAD = 64 * 1024   // multipart 的边界与几个文本字段;只用来决定"明显超过上限、不必读请求体"

type Limits = { set: boolean; max_bytes: number | null; types: string[] | null }

function back(request: Request, params: Record<string, string>) {
    const url = new URL(BACK, request.url)
    for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v)
    return NextResponse.redirect(url, 303)
}

function codeOf(message: string): { code: string; p?: string } {
    const m = (message ?? '').trim().match(/([A-Z_]+)(?:\|(.*))?$/)
    return m ? { code: m[1], p: m[2] } : { code: 'UPLOAD_FAILED' }
}

/** 按文件头认类型 —— 不信浏览器报的。认不出回 null。 */
function sniffType(bytes: Uint8Array): string | null {
    if (bytes.length >= 5 && bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46 && bytes[4] === 0x2d) return 'application/pdf'
    if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg'
    if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47
        && bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a) return 'image/png'
    return null
}

const dateOrNull = (v: FormDataEntryValue | null) => (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null)
const textOrNull = (v: FormDataEntryValue | null) => (typeof v === 'string' && v.trim() ? v.trim() : null)

export async function POST(request: Request) {
    if (!(await isPortalSession())) {
        return new NextResponse('Certificate upload is for supplier portal sessions.', { status: 403, headers: { 'Content-Type': 'text/plain; charset=utf-8' } })
    }
    const supabase = await createClient()

    // ② V39 —— 从库里来,不在这里另写一份
    const lim = await supabase.rpc('portal_certificates')
    if (lim.error) return back(request, { error: codeOf(lim.error.message).code })
    const limits = (lim.data as unknown as { limits: Limits }).limits
    if (!limits.set || limits.max_bytes == null) return back(request, { error: 'PORTAL_UPLOAD_LIMITS_NOT_SET' })
    const declared = Number(request.headers.get('content-length') ?? '0')
    if (Number.isFinite(declared) && declared > limits.max_bytes + BODY_OVERHEAD) {
        return back(request, { error: 'PORTAL_UPLOAD_TOO_LARGE', p: String(limits.max_bytes) })
    }

    // ③ 读出文件,按文件头认类型
    let form: FormData
    try {
        form = await request.formData()
    } catch {
        return back(request, { error: 'NO_FILE' })
    }
    const file = form.get('file')
    if (!(file instanceof File) || file.size === 0) return back(request, { error: 'NO_FILE' })
    const bytes = new Uint8Array(await file.arrayBuffer())
    const type = sniffType(bytes) ?? 'application/octet-stream'

    // ④ 库按 V39 判 —— 拒了就回去,一个字节都没存
    const begun = await supabase.rpc('portal_submission_begin', {
        p_cert_type: textOrNull(form.get('cert_type')) ?? '',
        p_cert_no: textOrNull(form.get('cert_no')) ?? undefined,
        p_valid_from: dateOrNull(form.get('valid_from')) ?? undefined,
        p_valid_until: dateOrNull(form.get('valid_until')) ?? undefined,
        p_file_name: file.name || 'certificate',
        p_file_type: type,
        p_file_size: bytes.length,
    })
    if (begun.error) {
        const c = codeOf(begun.error.message)
        return back(request, c.p ? { error: c.code, p: c.p } : { error: c.code })
    }
    const slot = begun.data as unknown as { id: string; bucket: string; path: string }

    // ⑤ 以这个会话自己的令牌传字节;⑥ 确认到了。任一失败 → 收回那一行
    const up = await supabase.storage.from(slot.bucket).upload(slot.path, bytes, { contentType: type, upsert: false })
    // 收回失败不另报:那一行停在 uploading,十分钟后存储策略就不再放行它的路径,员工那一侧也看不见它 —— 访客要知道的只是"没交成"
    if (up.error) {
        await supabase.rpc('portal_submission_abandon', { p_submission_id: slot.id })
        return back(request, { error: 'UPLOAD_FAILED' })
    }
    const done = await supabase.rpc('portal_submission_finish', { p_submission_id: slot.id })
    if (done.error) {
        await supabase.rpc('portal_submission_abandon', { p_submission_id: slot.id })
        return back(request, { error: codeOf(done.error.message).code })
    }
    return back(request, { submitted: '1' })
}
