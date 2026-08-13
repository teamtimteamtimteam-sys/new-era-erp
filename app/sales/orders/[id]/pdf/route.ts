// app/sales/orders/[id]/pdf/route.ts
// 销售订单 PDF。三个入口,形状取自采购单那一份:
//   GET             预览 —— 按【当前】数据渲染,inline 打开,不落档
//   GET ?version=N  取【签发档】—— 从 so-documents 桶里流出当时存下的字节,并对着
//                   so_issues.sha256 校验:对象被动过就拒绝,不给一份与记录对不上的档案
//   POST            签发 —— 渲染、存桶、record_so_issue() 记档
//
// 【签发的是记录,不是视图】客户手里那份是某个具体版本;此后数据、渲染器、字体
// 子集怎么变,那份字节都原样在桶里。
import { NextResponse } from 'next/server'
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer'
import { createHash } from 'node:crypto'
import type { ReactElement } from 'react'
import { createClient } from '@/lib/supabase/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import SalesOrderDocument, { type SoDocData } from './SalesOrderDocument'
import { findUnrenderableText, coverageErrorMessage, type PdfTextField } from '@/lib/invoiceFontCoverage'
import { localizeSalesOrderError } from '../../salesOrderErrorCodes'

const BUCKET = 'so-documents'

async function loadDoc(id: string): Promise<SoDocData | null> {
    const supabase = await createClient()
    const o = mustOne(
        await supabase.from('sales_orders')
            .select('code, status, order_date, currency, notes, terms_text, customers ( code, legal_name )')
            .eq('id', id).is('deleted_at', null).maybeSingle(),
        'sales_orders')
    if (!o) return null
    const row = o as unknown as { code: string; status: string; order_date: string; currency: string
        notes: string | null; terms_text: string | null; customers: { code: string; legal_name: string } | null }
    const lines = mustRows(
        await supabase.from('sales_order_lines')
            .select('line_no, quantity, unit_price, materials ( code, name )')
            .eq('sales_order_id', id).order('line_no'),
        'sales_order_lines') as unknown as {
            line_no: number; quantity: number; unit_price: number
            materials: { code: string; name: string } | null }[]
    return {
        code: row.code, status: row.status, order_date: row.order_date, currency: row.currency,
        customer: row.customers ?? { code: '—', legal_name: '—' },
        lines: lines.map((l) => ({
            line_no: l.line_no, quantity: l.quantity, unit_price: l.unit_price,
            material: l.materials ? `${l.materials.code} — ${l.materials.name}` : '—',
        })),
        notes: row.notes, terms_text: row.terms_text,
    }
}

// 【渲染前过一遍字体覆盖守卫】裁剪范围外的字会被静默画成空白,而发给客户的
// 单据上出现空白是真实事故(与发票/采购单同一条)。
function collectStrings(d: SoDocData): PdfTextField[] {
    return [
        { where: 'customer legal_name', text: d.customer.legal_name },
        { where: 'order terms_text', text: d.terms_text },
        { where: 'order notes', text: d.notes },
        ...d.lines.map((l) => ({ where: `line ${l.line_no} material`, text: l.material })),
    ]
}

async function render(d: SoDocData): Promise<Buffer> {
    const bad = findUnrenderableText(collectStrings(d))
    if (bad.length > 0) throw new Error(coverageErrorMessage(bad))
    const doc = SalesOrderDocument({ data: d }) as unknown as ReactElement<DocumentProps>
    return await renderToBuffer(doc)
}

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const version = new URL(request.url).searchParams.get('version')
    try {
        const supabase = await createClient()

        if (version) {
            // 取签发档:桶里的字节 + 对着记录校验
            const issue = mustOne(
                await supabase.from('so_issues').select('file_path, sha256')
                    .eq('sales_order_id', id).eq('version', Number(version)).maybeSingle(),
                'so_issues') as { file_path: string; sha256: string } | null
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
        // 对象键不含版本号 —— 版本由 record_so_issue 在数据库里裁决(并发安全)
        const path = `${id}/${sha}.pdf`
        const up = await supabase.storage.from(BUCKET).upload(path, buf, {
            contentType: 'application/pdf', upsert: true,
        })
        if (up.error) return new NextResponse(`Upload failed: ${up.error.message}`, { status: 500 })

        const { data, error } = await supabase.rpc('record_so_issue', {
            p_order_id: id, p_file_path: path, p_sha256: sha,
        })
        if (error) return new NextResponse(await localizeSalesOrderError(error.message), { status: 400 })
        return NextResponse.json(data)
    } catch (e) {
        return new NextResponse(`Issue failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}
