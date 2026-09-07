// app/inbound/[id]/cod/pdf/route.tsx
// COD-1:销毁证书的三个入口,形状逐字取自 AUD-2 的可追溯报告路由。
//   GET            内部存档 —— 按【当前】数据渲染,inline 打开,【不落档】
//                  ★ 永远不因缺执照被拒 ★(存档是内部的事,签发才是对外的)
//   GET ?cod=CODE  取【签发档】—— 从桶里流出当时存下的字节,并对着
//                  cod_issues.sha256 校验:对象被动过就拒绝
//   POST           签发 —— issue_cod() 铸号铸令牌冻快照 → 渲染 → 存桶 → 记档
//
// ════════════════════════════════════════════════════════════════════════════
// 【签发是两次调用,而这是知情的选择】
// ════════════════════════════════════════════════════════════════════════════
// 号与令牌【要印在纸上】,所以必须先有号才渲染得出 PDF —— 而渲染在数据库事务
// 之外。于是:issue_cod() 先落库(号、令牌、快照),再渲染、存桶、记字节。
//
// 中间崩掉会留下一张【已签发但没有字节档案】的证书。那是可恢复的,而且【正是
// 两样都冻的理由】:快照是权威,照它可以把同一份 PDF 再渲染一遍。反过来的
// 顺序不可恢复 —— 先渲染就得先有号,而一个没落库的号会在下一次取号时被重用,
// 于是两张证书拿到同一个号。发票也是这个顺序:create_invoice() 当场铸号,
// invoice_issues 的字节是后来的事。
import { NextResponse } from 'next/server'
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer'
import { createHash } from 'node:crypto'
import type { ReactElement } from 'react'
import QRCode from 'qrcode'
import { createClient } from '@/lib/supabase/server'
import { mustOne } from '@/lib/db-helpers'
import { loadDocumentCompany, COMPANY_MISSING_MESSAGE } from '@/app/components/pdf/company'
import { localizeCodError } from '@/app/inbound/codErrorCodes'
import CertificateDocument, { type CertificateData } from '@/app/inbound/CertificateDocument'

const BUCKET = 'cod-documents'

/** 核验网址 —— 令牌是 UUID,与证书号【毫无关系】。页面本身是后一刀的事。 */
export const verificationUrl = (origin: string, token: string) => `${origin}/verify/cod/${token}`

async function render(
    data: CertificateData,
    mode: 'internal' | 'issued' | 'void',
    origin: string
): Promise<Buffer> {
    const loaded = await loadDocumentCompany()
    if (!loaded.ok) throw new Error(COMPANY_MISSING_MESSAGE)

    // 【二维码只在签发件上】—— 没签发就没有令牌,也就没有可核验的东西。
    let qrDataUrl: string | null = null
    let url: string | null = null
    const token = data.certificate?.verification_token ?? null
    if (mode !== 'internal' && token) {
        url = verificationUrl(origin, token)
        // 与两条批次标签路由【同一个调用形状】(app/inbound/[id]/label/route.ts)。
        // 那两条把它交给 HTML;这里交给 PDF —— react-pdf 的 Image 收 PNG data URI
        // (它拒的是 SVG),所以中间不需要任何转换。
        qrDataUrl = await QRCode.toDataURL(url, { width: 480, margin: 1 })
    }

    const doc = (
        <CertificateDocument
            data={data}
            company={loaded.company}
            mode={mode}
            verificationUrl={url}
            qrDataUrl={qrDataUrl}
        />
    )
    return renderToBuffer(doc as unknown as ReactElement<DocumentProps>)
}

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const url = new URL(request.url)
    const wanted = url.searchParams.get('cod')
    try {
        const supabase = await createClient()

        // ── 取签发档:流字节,并对着哈希校验 ──────────────────────────────
        if (wanted) {
            const cert = mustOne(
                await supabase.from('certificates_of_destruction')
                    .select('id, code, status').eq('inbound_batch_id', id).eq('code', wanted).maybeSingle(),
                'certificates_of_destruction'
            ) as { id: string; code: string; status: string } | null
            if (!cert) return new NextResponse('Not found', { status: 404 })

            const issue = mustOne(
                await supabase.from('cod_issues').select('file_path, sha256')
                    .eq('cod_id', cert.id).maybeSingle(),
                'cod_issues'
            ) as { file_path: string; sha256: string } | null
            if (!issue) return new NextResponse('No stored document for this certificate', { status: 404 })

            const dl = await supabase.storage.from(BUCKET).download(issue.file_path)
            if (dl.error || !dl.data) return new NextResponse('Stored document unavailable', { status: 404 })
            const bytes = Buffer.from(await dl.data.arrayBuffer())
            const sha = createHash('sha256').update(bytes).digest('hex')
            if (sha !== issue.sha256) {
                // 【对不上就拒绝】一份与记录不符的"档案"比没有档案更坏。
                return new NextResponse('Stored document does not match its recorded digest', { status: 409 })
            }
            return new NextResponse(new Uint8Array(bytes), {
                headers: {
                    'Content-Type': 'application/pdf',
                    'Content-Disposition': `inline; filename="${cert.code}.pdf"`,
                },
            })
        }

        // ── 内部存档:按当前数据渲染,不落任何档 ───────────────────────────
        const { data, error } = await supabase.rpc('cod_certificate_data', { p_inbound_batch_id: id })
        if (error) return new NextResponse(await localizeCodError(error.message), { status: 400 })

        const cert = (data as CertificateData).certificate
        // 【已签发的证书,内部再打开也照签发件的样子渲染】—— 否则同一张证书会有
        // 两副面孔,而其中一副带着"未签发"的水印。
        const mode = cert?.status === 'issued' ? 'issued' : cert?.status === 'void' ? 'void' : 'internal'
        const buf = await render(data as CertificateData, mode, new URL(request.url).origin)
        return new NextResponse(new Uint8Array(buf), {
            headers: {
                'Content-Type': 'application/pdf',
                'Content-Disposition': `inline; filename="${cert?.code ?? (data as CertificateData).inbound_batch.code + '-cod-internal'}.pdf"`,
            },
        })
    } catch (e) {
        return new NextResponse(`PDF failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}

export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    try {
        const supabase = await createClient()

        // 找到这票货【活着的】那张证书(它由 refresh_cod_for_batch 自动成立)。
        const cert = mustOne(
            await supabase.from('certificates_of_destruction').select('id, status')
                .eq('inbound_batch_id', id).neq('status', 'void').maybeSingle(),
            'certificates_of_destruction'
        ) as { id: string; status: string } | null
        if (!cert) {
            return new NextResponse(
                await localizeCodError(`CANNOT_CERTIFY|${id}|NOTHING_PROCESSED`), { status: 400 })
        }

        // ① 落库:执照闸、铸号、铸令牌、冻快照 —— 全在一个事务里。
        const issued = await supabase.rpc('issue_cod', { p_cod_id: cert.id })
        if (issued.error) {
            return new NextResponse(await localizeCodError(issued.error.message), { status: 400 })
        }

        // ② 照【冻下来的那一份】渲染 —— 纸与档案因此按构造一致,
        //    而不是靠"渲染时读到的活数据碰巧还没变"。
        const { data, error } = await supabase.rpc('cod_certificate_data', { p_inbound_batch_id: id })
        if (error) return new NextResponse(await localizeCodError(error.message), { status: 400 })

        const buf = await render(data as CertificateData, 'issued', new URL(request.url).origin)
        const sha = createHash('sha256').update(buf).digest('hex')
        // 【键不含哈希】两张证书的字节可能逐字相同,用 sha 当键会让后一份覆盖前一份 ——
        // 于是两行档案指向同一份字节,而"那一张当时是什么"就没有答案了。
        const path = `${cert.id}/${crypto.randomUUID()}.pdf`
        const up = await supabase.storage.from(BUCKET).upload(path, buf, { contentType: 'application/pdf' })
        if (up.error) return new NextResponse(`Upload failed: ${up.error.message}`, { status: 500 })

        const rec = await supabase.rpc('record_cod_issue', {
            p_cod_id: cert.id, p_file_path: path, p_sha256: sha,
        })
        if (rec.error) {
            // 记录失败 → 把孤儿对象清掉:桶里不该留一份没有档案的"签发件"。
            // 【证书本身仍然是已签发的】—— 号已经铸出去了,而快照在,补一次字节即可。
            await supabase.storage.from(BUCKET).remove([path])
            return new NextResponse(await localizeCodError(rec.error.message), { status: 400 })
        }
        return NextResponse.json(issued.data)
    } catch (e) {
        return new NextResponse(`Issue failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}
