// app/inbound/[id]/cod/pdf/route.tsx
// COD-1:销毁证书的三个入口,形状逐字取自 AUD-2 的可追溯报告路由。
//   GET            ★ MES-7a-1(F10,MES-7a Step 0 Q9):已签发或已作废的证书 → 流出【签发那一刻存下的字节】(与 ?cod= 同一条路,
//                  重算哈希,对不上就 409);还没签发的(pending,或这票货还没有证书)→ 内部存档:按【当前】数据渲染、带水印、不落档
//                  ★ 永远不因缺执照被拒 ★(存档是内部的事,签发才是对外的)
//   GET ?cod=CODE  取【签发档】—— 从桶里流出当时存下的字节,并对着 cod_issues.sha256 校验:对象被动过就 409
//   POST           签发 —— 先过字体(画不出来就拒,什么都不签)→ issue_cod() 铸号铸令牌冻快照 →【照它返回的那一份快照】渲染 → 存桶 → 记档
//
// ════════════════════════════════════════════════════════════════════════════
// ★ MES-7a-1(F10):【纸只从快照来】—— 此前这里有三处读的是活数据(known-issues MES6B1-COD-PDF-RENDERS-LIVE):
//   ① POST 签发之后又调了一次 cod_certificate_data(活的),而它头上那句注释说的是"照冻下来的那一份渲染"—— 那句话是假的,已改;
//   ② 每一次渲染的抬头(公司名、地址、"Processed by"、那一句证明)都取自活的 company_profile_masked,不是快照;
//   ③ 不带 ?cod= 打开一张已签发的证书,会照活数据【以签发件的样子】重新渲染一份(那一份从来没有被签发过)。
//   现在:签发照 issue_cod 返回的快照渲染、抬头取快照里的公司那一块;已签发 / 作废的证书一律流存下的字节;只有【还没签发】的内部存档
//   读活数据(它本来就是"此刻会是什么样子",带水印)。核验页(cod_verification)本来就读快照,不受影响。
//   ★ 已签发的两张(COD-2026-0001 · -0002)不重新签发、字节一个都不动 —— 它们从此由不带 ?cod= 的打开也流出那同一份字节。
// 【核验网址的域名】仍是签发那一刻请求的来源(origin)—— 它已经在存下的字节里;生产域名是 PUR-1 ② 自己的那一条(Q9)。
// 【字体】签发之前与渲染之内各问一次(Q25):画不出来就拒,绝不印一片空白。字段清单在 app/inbound/codPdf.ts。
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
import { mustOne, mustRows } from '@/lib/db-helpers'
import { loadDocumentCompany, COMPANY_MISSING_MESSAGE } from '@/app/components/pdf/company'
import type { LetterheadCompany } from '@/app/components/CompanyLetterhead'
import { localizeCodError } from '@/app/inbound/codErrorCodes'
import CertificateDocument, { type CertificateData } from '@/app/inbound/CertificateDocument'
import { codUnrenderable } from '@/app/inbound/codPdf'

const BUCKET = 'cod-documents'

/** 核验网址 —— 令牌是 UUID,与证书号【毫无关系】。 */
export const verificationUrl = (origin: string, token: string) => `${origin}/verify/cod/${token}`

/** 画不出来的字 —— 一次拒绝,不是一次 500(渲染之内与签发之前问的是同一句)。 */
class Unrenderable extends Error {}

/** 快照里冻下来的那一块公司抬头(九格)。没有法定名 = 不能当抬头用(issue_cod 签发时已按名拒过这一格,这里是第二道)。 */
function companyFromSnapshot(snap: CertificateData): LetterheadCompany | null {
    const c = (snap as unknown as { company?: Record<string, string | null> }).company
    if (!c || !c.legal_name || !String(c.legal_name).trim()) return null
    return {
        legal_name: String(c.legal_name), address_lines: c.address_lines ?? null, city: c.city ?? null, postal_code: c.postal_code ?? null,
        country: c.country ?? null, registration_no: c.registration_no ?? null, phone: c.phone ?? null, email: c.email ?? null,
        website: c.website ?? null,
    }
}

async function render(
    data: CertificateData,
    mode: 'internal' | 'issued' | 'void',
    origin: string,
    company: LetterheadCompany
): Promise<Buffer> {
    // 【二维码只在签发件上】—— 没签发就没有令牌,也就没有可核验的东西。
    let qrDataUrl: string | null = null
    let url: string | null = null
    const token = data.certificate?.verification_token ?? null
    if (mode !== 'internal' && token) {
        url = verificationUrl(origin, token)
        // 与两条批次标签路由【同一个调用形状】(app/inbound/[id]/label/route.ts)。react-pdf 的 Image 收 PNG data URI。
        qrDataUrl = await QRCode.toDataURL(url, { width: 480, margin: 1 })
    }
    // ★ F10(Q25):纸上会印的每一个字先过字体覆盖守卫 —— 画不出来就拒,不印空白
    const bad = codUnrenderable(data, company, url)
    if (bad) throw new Unrenderable(bad)

    const doc = (
        <CertificateDocument
            data={data}
            company={company}
            mode={mode}
            verificationUrl={url}
            qrDataUrl={qrDataUrl}
        />
    )
    return renderToBuffer(doc as unknown as ReactElement<DocumentProps>)
}

function pdf(bytes: Uint8Array | Buffer, filename: string) {
    return new NextResponse(new Uint8Array(bytes), {
        headers: { 'Content-Type': 'application/pdf', 'Content-Disposition': `inline; filename="${filename}.pdf"` },
    })
}

/** 流出一张证书存下的字节,并对着 cod_issues.sha256 重算 —— 对不上就 409(一份与记录不符的"档案"比没有档案更坏)。 */
async function streamStored(supabase: Awaited<ReturnType<typeof createClient>>, cert: { id: string; code: string }): Promise<NextResponse> {
    const issue = mustOne(
        await supabase.from('cod_issues').select('file_path, sha256').eq('cod_id', cert.id).maybeSingle(),
        'cod_issues'
    ) as { file_path: string; sha256: string } | null
    if (!issue) return new NextResponse('No stored document for this certificate', { status: 404 })
    const dl = await supabase.storage.from(BUCKET).download(issue.file_path)
    if (dl.error || !dl.data) return new NextResponse('Stored document unavailable', { status: 404 })
    const bytes = Buffer.from(await dl.data.arrayBuffer())
    const sha = createHash('sha256').update(bytes).digest('hex')
    if (sha !== issue.sha256) {
        return new NextResponse('Stored document does not match its recorded digest', { status: 409 })
    }
    return pdf(bytes, cert.code)
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
            return await streamStored(supabase, cert)
        }

        // ── 不带 ?cod=:已签发 / 作废的 → 存下的字节;还没签发的 → 内部存档(活数据,水印)────────────
        // 这票货【活着的】那一张(最多一张非作废的);没有活的而有作废的 → 最近作废的那一张
        const certs = mustRows(
            await supabase.from('certificates_of_destruction').select('id, code, status, voided_at')
                .eq('inbound_batch_id', id).order('voided_at', { ascending: false, nullsFirst: true }),
            'certificates_of_destruction'
        ) as { id: string; code: string | null; status: string; voided_at: string | null }[]
        const live = certs.find((c) => c.status !== 'void') ?? null
        const stored = live?.status === 'issued' ? live : (!live ? certs.find((c) => c.status === 'void') ?? null : null)
        if (stored && stored.code) return await streamStored(supabase, { id: stored.id, code: stored.code })

        const { data, error } = await supabase.rpc('cod_certificate_data', { p_inbound_batch_id: id })
        if (error) return new NextResponse(await localizeCodError(error.message), { status: 400 })
        const loaded = await loadDocumentCompany()
        if (!loaded.ok) return new NextResponse(COMPANY_MISSING_MESSAGE, { status: 400 })
        const d = data as CertificateData
        const buf = await render(d, 'internal', url.origin, loaded.company)
        return pdf(buf, `${d.inbound_batch.code}-cod-internal`)
    } catch (e) {
        if (e instanceof Unrenderable) return new NextResponse(e.message, { status: 400 })
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

        // ⓪ 签发之前先问字体(F10 · Q25):照【同一支组装】(cod_certificate_data,签发时冻进快照的就是它)与此刻的抬头
        //   (签发时冻进快照的公司那一块就取自 company_profile)看纸上会印的字画不画得出来。画不出来就在这里拒 —— 什么都不签。
        //   否则号已铸、快照已冻,渲染才失败,留下一张没有字节的证书(分析证书那条路由在 MES-6b-2 线上证明里实测过同一个形状)。
        const pre = await supabase.rpc('cod_certificate_data', { p_inbound_batch_id: id })
        if (pre.error) return new NextResponse(await localizeCodError(pre.error.message), { status: 400 })
        const loaded = await loadDocumentCompany()
        if (!loaded.ok) return new NextResponse(COMPANY_MISSING_MESSAGE, { status: 400 })
        const preBad = codUnrenderable(pre.data as CertificateData, loaded.company)
        if (preBad) return new NextResponse(preBad, { status: 400 })

        // ① 落库:执照闸、铸号、铸令牌、冻快照 —— 全在一个事务里。
        const issued = await supabase.rpc('issue_cod', { p_cod_id: cert.id })
        if (issued.error) {
            return new NextResponse(await localizeCodError(issued.error.message), { status: 400 })
        }
        const r = issued.data as unknown as { snapshot: CertificateData } & Record<string, unknown>

        // ② 照【issue_cod 返回的那一份快照】渲染(与写进证书的同一份)—— 不再回读活数据;抬头取快照里的公司那一块。
        //    纸与档案因此按构造一致,而不是靠"渲染时读到的活数据碰巧还没变"。
        const company = companyFromSnapshot(r.snapshot)
        if (!company) return new NextResponse(COMPANY_MISSING_MESSAGE, { status: 400 })
        const buf = await render(r.snapshot, 'issued', new URL(request.url).origin, company)
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
        // 返回值与此前同形(快照不再往浏览器送 —— 它只是渲染的输入)
        const { snapshot: _snapshot, ...rest } = r
        void _snapshot
        return NextResponse.json(rest)
    } catch (e) {
        if (e instanceof Unrenderable) return new NextResponse(e.message, { status: 400 })
        return new NextResponse(`Issue failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}
