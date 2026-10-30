'use server'

// app/portal/certificates/actions.ts
// GOLIVE-2 第 9 行(Tim 2026-10-21 CLAIM-RECEIPTS-1 Q14 · 2026-10-30):门户交一份证书 —— 服务端那几步,【字节不经过这里】。
//   原来的 /portal/certificates/upload 路由把整份文件读进函数(request.formData()),而 Vercel 在应用之前就拒 4.5 MB 以上的请求体
//   (HTTP 413 FUNCTION_PAYLOAD_TOO_LARGE,docs/known-issues.md § PORTAL-UPLOAD-CAPPED-BY-VERCEL-4-5-MB)—— 门户页上写的 10 MB 是假的。
//   现在照报销收据(CLAIM-RECEIPTS-1)的形状:浏览器把字节直传私有桶 portal-uploads(UploadForm.tsx),这里只做三件事:
//   begin   —— portal_submission_begin:库按 V39 判类型与大小、登记一行 uploading、给出路径(判据只有库里那一份,这里不另判);
//   finish  —— 从存储里读回那份文件的【文件头】(Range 16 字节,60 秒的签名链接,不把整份文件拉进函数),按文件头认类型,
//              对得上才让库确认(portal_submission_finish 再比一次存下来的大小与类型);对不上 / 读不到 → abandon;
//   abandon —— 没传成:那一行标成 abandoned(员工那一侧与门户的清单都看不见它;字节留着,Tim 2026-10-20 d2 #3)。
//   每一步先问一次:这是门户会话吗(员工会话 → 拒;门户函数本来就只授 supplier_portal)。
//   ★ 门户会话读不到 portal_certificate_submissions(那张表只给持 suppliers.view 的员工),所以 finish 不能像收据那样回表里取路径 ——
//     它要求浏览器交回的路径【就是 begin 给的那一种】:<供应商>/<这一行的 id>.<扩展名>;而存储的读策略只放行这个账号自己那一行
//     uploading 的路径,所以拿别人的路径来也读不到。库那一侧 finish 按这一行【登记的】路径核对对象,不按这里传的。
import { createClient } from '@/lib/supabase/server'
import { isPortalSession } from '@/lib/portalSession'
import { sniffFileType, EXT_OF_TYPE } from '@/lib/sniffFileType'

const BUCKET = 'portal-uploads'
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export type PortalUploadResult = { error?: string; p?: string; id?: string; path?: string; success?: boolean }

function codeOf(message: string): { error: string; p?: string } {
    const m = (message ?? '').trim().match(/([A-Z_]+)(?:\|(.*))?$/)
    return m ? (m[2] ? { error: m[1], p: m[2] } : { error: m[1] }) : { error: 'UPLOAD_FAILED' }
}
const dateOrNull = (v: string | null | undefined) => (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null)
const textOrNull = (v: string | null | undefined) => (typeof v === 'string' && v.trim() ? v.trim() : null)

export async function beginSubmission(input: {
    certType: string; certNo?: string | null; validFrom?: string | null; validUntil?: string | null
    fileName: string; fileType: string; fileSize: number
}): Promise<PortalUploadResult> {
    if (!(await isPortalSession())) return { error: 'UPLOAD_FAILED' }
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('portal_submission_begin', {
        p_cert_type: input.certType ?? '',
        p_cert_no: textOrNull(input.certNo) ?? undefined,
        p_valid_from: dateOrNull(input.validFrom) ?? undefined,
        p_valid_until: dateOrNull(input.validUntil) ?? undefined,
        p_file_name: input.fileName || 'certificate',
        // 浏览器已经按文件头认过;认不出时它交的是 application/octet-stream,库按名拒(PORTAL_UPLOAD_TYPE_NOT_ACCEPTED)
        p_file_type: input.fileType,
        p_file_size: input.fileSize,
    })
    if (error) return codeOf(error.message)
    const slot = data as unknown as { id: string; bucket: string; path: string }
    return { id: slot.id, path: slot.path }
}

export async function finishSubmission(input: { id: string; path: string; fileType: string }): Promise<PortalUploadResult> {
    if (!(await isPortalSession())) return { error: 'UPLOAD_FAILED' }
    const supabase = await createClient()
    const abandon = async (code: { error: string; p?: string }) => {
        await supabase.rpc('portal_submission_abandon', { p_submission_id: input.id })
        return code
    }
    const ext = EXT_OF_TYPE[input.fileType]
    if (!UUID.test(input.id) || !ext || !new RegExp(`^[0-9a-f-]{36}/${input.id}\\.${ext}$`, 'i').test(input.path)) {
        return abandon({ error: 'PORTAL_UPLOAD_MISMATCH' })
    }
    // 只取文件头那几个字节(Range),不把整份文件拉进函数里
    const signed = await supabase.storage.from(BUCKET).createSignedUrl(input.path, 60)
    if (signed.error || !signed.data?.signedUrl) return abandon({ error: 'PORTAL_UPLOAD_NOT_STORED' })
    let head: Uint8Array
    try {
        const r = await fetch(signed.data.signedUrl, { headers: { Range: 'bytes=0-15' } })
        if (!r.ok) throw new Error(`HTTP ${r.status}`)
        head = new Uint8Array(await r.arrayBuffer()).slice(0, 16)
    } catch {
        return abandon({ error: 'PORTAL_UPLOAD_NOT_STORED' })
    }
    const sniffed = sniffFileType(head)
    if (sniffed !== input.fileType) return abandon({ error: 'PORTAL_UPLOAD_TYPE_NOT_ACCEPTED', p: sniffed ?? 'application/octet-stream' })
    const { error } = await supabase.rpc('portal_submission_finish', { p_submission_id: input.id })
    if (error) return abandon(codeOf(error.message))
    return { success: true }
}

export async function abandonSubmission(id: string): Promise<PortalUploadResult> {
    if (!(await isPortalSession())) return { error: 'UPLOAD_FAILED' }
    if (!UUID.test(id)) return { error: 'UPLOAD_FAILED' }
    const supabase = await createClient()
    const { error } = await supabase.rpc('portal_submission_abandon', { p_submission_id: id })
    return error ? codeOf(error.message) : { success: true }
}
