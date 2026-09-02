// app/sales/shipments/[id]/pdf/route.ts
// SO-3b:送货单 PDF。三个入口,形状逐字取自销售订单那一份:
//   GET             预览 —— 按【当前】数据渲染,inline 打开,不落档
//   GET ?version=N  取【签发档】—— 从 shipment-documents 桶里流出当时存下的字节,
//                   并对着 shipment_issues.sha256 校验:对象被动过就拒绝
//   POST            签发 —— 渲染、存桶、record_shipment_issue() 记档
//
// 【签发的是记录,不是视图】客户手里那份是某个具体版本;此后数据、渲染器、
// 字体子集怎么变,那份字节都原样在桶里。
import { NextResponse } from 'next/server'
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer'
import { createHash } from 'node:crypto'
import type { ReactElement } from 'react'
import { createClient } from '@/lib/supabase/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import DeliveryNoteDocument, { type DeliveryNoteData } from './DeliveryNoteDocument'
import { findUnrenderableText, coverageErrorMessage, type PdfTextField } from '@/lib/pdfFontCoverage'
import { loadDocumentCompany, companyPdfStrings, COMPANY_MISSING_MESSAGE } from '@/app/components/pdf/company'
import { localizeSalesOrderError } from '@/app/sales/orders/salesOrderErrorCodes'

const BUCKET = 'shipment-documents'

async function loadDoc(id: string): Promise<DeliveryNoteData | null> {
    const supabase = await createClient()
    const s = mustOne(
        await supabase.from('shipments')
            .select('code, ship_date, sales_orders ( code, customers ( code, legal_name ) )')
            .eq('id', id).maybeSingle(),
        'shipments')
    if (!s) return null
    const row = s as unknown as {
        code: string; ship_date: string
        sales_orders: { code: string; customers: { code: string; legal_name: string } | null } | null }

    const lines = mustRows(
        await supabase.from('shipment_lines')
            .select('qty, output_batches ( code, unit, materials ( code, name, waste_classification_code ) )')
            .eq('shipment_id', id).order('created_at'),
        'shipment_lines') as unknown as {
            qty: number
            output_batches: {
                code: string; unit: string
                materials: { code: string; name: string; waste_classification_code: string | null } | null
            } | null }[]

    // 【分类的名字与"受不受控"都取自字典 —— 不从 code 猜】
    // waste_classifications.is_controlled 才是合规逻辑该读的那一列(MAT-1 表头)。
    const codes = [...new Set(lines.map((l) => l.output_batches?.materials?.waste_classification_code).filter(Boolean))] as string[]
    const cls = codes.length
        ? (mustRows(
              await supabase.from('waste_classifications').select('code, name_en, is_controlled').in('code', codes),
              'waste_classifications') as unknown as { code: string; name_en: string; is_controlled: boolean }[])
        : []
    const clsBy = new Map(cls.map((c) => [c.code, c]))

    return {
        code: row.code,
        ship_date: row.ship_date,
        order_code: row.sales_orders?.code ?? '—',
        customer: row.sales_orders?.customers ?? { code: '—', legal_name: '—' },
        lines: lines.map((l, i) => {
            const m = l.output_batches?.materials
            const c = m?.waste_classification_code ? clsBy.get(m.waste_classification_code) : undefined
            return {
                line_no: i + 1,
                material: m ? `${m.code} — ${m.name}` : '—',
                batch_code: l.output_batches?.code ?? '—',
                quantity: Number(l.qty),
                unit: l.output_batches?.unit ?? '',
                classification: c?.name_en ?? null,
                is_controlled: c?.is_controlled ?? null,
            }
        }),
    }
}

// 【渲染前过一遍字体覆盖守卫】裁剪范围外的字会被静默画成空白,而发给客户的
// 单据上出现空白是真实事故(与发票/采购单/销售订单同一条)。
function collectStrings(d: DeliveryNoteData): PdfTextField[] {
    return [
        { where: 'customer legal_name', text: d.customer.legal_name },
        ...d.lines.map((l) => ({ where: `line ${l.line_no} material`, text: l.material })),
        ...d.lines.map((l) => ({ where: `line ${l.line_no} classification`, text: l.classification })),
    ]
}

async function render(d: DeliveryNoteData): Promise<Buffer> {
    // PDF-1:抬头(字标 + 法定名称 + 公司资料)。没有法定名称就不出这张纸 ——
    // 一份不说明是谁开的对外单据,客户无从入账、审计师无从溯源。与发票同一条规矩。
    const loaded = await loadDocumentCompany()
    if (!loaded.ok) throw new Error(COMPANY_MISSING_MESSAGE)
    // 【抬头的字段也要过守卫】它们从 PDF-1 起才印在这张纸上,见 companyPdfStrings。
    const bad = findUnrenderableText([...collectStrings(d), ...companyPdfStrings(loaded.company)])
    if (bad.length > 0) throw new Error(coverageErrorMessage(bad))
    const doc = DeliveryNoteDocument({ d, company: loaded.company }) as unknown as ReactElement<DocumentProps>
    return await renderToBuffer(doc)
}

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const version = new URL(request.url).searchParams.get('version')
    try {
        const supabase = await createClient()

        if (version) {
            const issue = mustOne(
                await supabase.from('shipment_issues').select('file_path, sha256')
                    .eq('shipment_id', id).eq('version', Number(version)).maybeSingle(),
                'shipment_issues') as { file_path: string; sha256: string } | null
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
        // 对象键不含版本号 —— 版本由 record_shipment_issue 在数据库里裁决(并发安全)
        const path = `${id}/${sha}.pdf`
        const up = await supabase.storage.from(BUCKET).upload(path, buf, {
            contentType: 'application/pdf', upsert: true,
        })
        if (up.error) return new NextResponse(`Upload failed: ${up.error.message}`, { status: 500 })

        const { data, error } = await supabase.rpc('record_shipment_issue', {
            p_shipment_id: id, p_file_path: path, p_sha256: sha,
        })
        if (error) return new NextResponse(await localizeSalesOrderError(error.message), { status: 400 })
        return NextResponse.json(data)
    } catch (e) {
        return new NextResponse(`Issue failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}
