// app/sales/quotes/[id]/pdf/route.ts
// 报价单 PDF。三个入口,形状逐字取自销售订单那一份(它取自采购单):
//   GET             预览 —— 按【当前】数据渲染,inline 打开,不落档
//   GET ?version=N  取【签发档】—— 从 qt-documents 桶里流出当时存下的字节,并对着
//                   qt_issues.sha256 校验:对象被动过就拒绝,不给一份与记录对不上的档案
//   POST            签发 —— 渲染、存桶、record_qt_issue() 记档
//
// 【签发的是记录,不是视图 —— 而报价比别处更需要这一条】报价的 draft/issued 行
// 【不上冻结守卫】(改价改量就是它的用途),所以"当初报的是什么"这个问题的唯一
// 硬答案就是桶里那份字节。此后数据怎么改,那一版都原样在。
//
// 【POST 同时是 draft → issued 那次状态转换】record_qt_issue 自己做,而且
// 【签发那一行最后写】(SO-4a fu2:反过来会让每一张刚签发的报价都自称
// "签发之后又改过")。
import { NextResponse } from 'next/server'
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer'
import { createHash } from 'node:crypto'
import type { ReactElement } from 'react'
import { createClient } from '@/lib/supabase/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import QuotationDocument, { type QuoteDocData } from './QuotationDocument'
import { findUnrenderableText, coverageErrorMessage, type PdfTextField } from '@/lib/invoiceFontCoverage'
import { localizeQuoteError } from '../../quoteErrorCodes'

const BUCKET = 'qt-documents'

async function loadDoc(id: string): Promise<QuoteDocData | null> {
    const supabase = await createClient()
    const q = mustOne(
        await supabase.from('quote_status')
            .select('code, quote_date, valid_until, currency, customer_code, customer_name, notes, terms_text')
            .eq('quote_id', id).maybeSingle(),
        'quote_status') as {
            code: string; quote_date: string; valid_until: string; currency: string
            customer_code: string; customer_name: string
            notes: string | null; terms_text: string | null } | null
    if (!q) return null

    const lines = mustRows(
        await supabase.from('quote_lines')
            .select('line_no, quantity, unit_price, materials ( code, name, unit )')
            .eq('quote_id', id).order('line_no'),
        'quote_lines') as unknown as {
            line_no: number; quantity: number; unit_price: number
            materials: { code: string; name: string; unit: string } | null }[]

    return {
        code: q.code,
        quote_date: q.quote_date,
        valid_until: q.valid_until,
        currency: q.currency,
        customer: { code: q.customer_code, legal_name: q.customer_name },
        lines: lines.map((l) => ({
            line_no: l.line_no,
            material: l.materials ? `${l.materials.code} — ${l.materials.name}` : '—',
            quantity: Number(l.quantity),
            unit: l.materials?.unit ?? '',
            unit_price: Number(l.unit_price),
        })),
        total: Math.round(lines.reduce((s, l) => s + Number(l.quantity) * Number(l.unit_price), 0) * 100) / 100,
        notes: q.notes,
        terms_text: q.terms_text,
    }
}

// 【渲染前过一遍字体覆盖守卫】裁剪范围外的字会被静默画成空白,而发给客户的
// 单据上出现空白是真实事故(与发票/采购单/销售订单/贷项凭证同一条)。
function collectStrings(d: QuoteDocData): PdfTextField[] {
    return [
        { where: 'customer legal_name', text: d.customer.legal_name },
        { where: 'quote terms_text', text: d.terms_text },
        { where: 'quote notes', text: d.notes },
        ...d.lines.map((l) => ({ where: `line ${l.line_no} material`, text: l.material })),
    ]
}

async function render(d: QuoteDocData): Promise<Buffer> {
    const bad = findUnrenderableText(collectStrings(d))
    if (bad.length > 0) throw new Error(coverageErrorMessage(bad))
    const doc = QuotationDocument({ data: d }) as unknown as ReactElement<DocumentProps>
    return await renderToBuffer(doc)
}

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const version = new URL(request.url).searchParams.get('version')
    try {
        const supabase = await createClient()

        if (version) {
            const issue = mustOne(
                await supabase.from('qt_issues').select('file_path, sha256')
                    .eq('quote_id', id).eq('version', Number(version)).maybeSingle(),
                'qt_issues') as { file_path: string; sha256: string } | null
            if (!issue) return new NextResponse('Not found', { status: 404 })
            const dl = await supabase.storage.from(BUCKET).download(issue.file_path)
            if (dl.error || !dl.data) return new NextResponse('Stored document unavailable', { status: 404 })
            const bytes = Buffer.from(await dl.data.arrayBuffer())
            const sha = createHash('sha256').update(bytes).digest('hex')
            if (sha !== issue.sha256) {
                // 【对不上就拒绝】一份与记录不符的"档案"比没有档案更坏
                return new NextResponse('Stored document does not match its recorded digest', { status: 409 })
            }
            return new NextResponse(new Uint8Array(bytes), {
                headers: { 'Content-Type': 'application/pdf',
                           'Content-Disposition': `inline; filename="${id}-v${version}.pdf"` },
            })
        }

        const d = await loadDoc(id)
        if (!d) return new NextResponse('Not found', { status: 404 })
        const buf = await render(d)
        return new NextResponse(new Uint8Array(buf), {
            headers: { 'Content-Type': 'application/pdf',
                       'Content-Disposition': `inline; filename="${d.code}.pdf"` },
        })
    } catch (e) {
        return new NextResponse(`PDF failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}

export async function POST(_request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    try {
        const supabase = await createClient()
        const d = await loadDoc(id)
        if (!d) return new NextResponse('Not found', { status: 404 })
        const buf = await render(d)
        const sha = createHash('sha256').update(buf).digest('hex')
        // 对象键不含版本号 —— 版本由 record_qt_issue 在数据库里裁决(并发安全)
        const path = `${id}/${sha}.pdf`
        const up = await supabase.storage.from(BUCKET).upload(path, buf, {
            contentType: 'application/pdf', upsert: true,
        })
        if (up.error) return new NextResponse(`Upload failed: ${up.error.message}`, { status: 500 })

        const { data, error } = await supabase.rpc('record_qt_issue', {
            p_quote_id: id, p_file_path: path, p_sha256: sha,
        })
        if (error) return new NextResponse(await localizeQuoteError(error.message), { status: 400 })
        return NextResponse.json(data)
    } catch (e) {
        return new NextResponse(`Issue failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}
