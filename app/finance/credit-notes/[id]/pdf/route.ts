// app/finance/credit-notes/[id]/pdf/route.ts
// 贷项凭证 PDF。三个入口,形状逐字取自销售订单那一份(它取自采购单):
//   GET             预览 —— 按【当前】数据渲染,inline 打开,不落档
//   GET ?version=N  取【签发档】—— 从 cn-documents 桶里流出当时存下的字节,并对着
//                   cn_issues.sha256 校验:对象被动过就拒绝,不给一份与记录对不上的档案
//   POST            签发 —— 渲染、存桶、record_cn_issue() 记档
//
// 【签发的是记录,不是视图】客户手里那份是某个具体版本;此后数据、渲染器、字体
// 子集怎么变,那份字节都原样在桶里。凭证本身只增不改,所以"当前数据"其实不会
// 变 —— 但版本机制照旧保留:重新签发(比如换了公司抬头)仍然要留下新的一版。
import { NextResponse } from 'next/server'
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer'
import { createHash } from 'node:crypto'
import type { ReactElement } from 'react'
import { createClient } from '@/lib/supabase/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import CreditNoteDocument, { type CnDocData } from './CreditNoteDocument'
import { findUnrenderableText, coverageErrorMessage, type PdfTextField } from '@/lib/invoiceFontCoverage'
import { localizeCreditNoteError } from '../../../creditNoteErrorCodes'

const BUCKET = 'cn-documents'

async function loadDoc(id: string): Promise<CnDocData | null> {
    const supabase = await createClient()
    const cn = mustOne(
        await supabase.from('credit_notes')
            .select('id, code, note_date, reason, currency, invoice_id')
            .eq('id', id).maybeSingle(),
        'credit_notes') as {
            id: string; code: string; note_date: string; reason: string
            currency: string; invoice_id: string } | null
    if (!cn) return null

    const inv = mustOne(
        await supabase.from('invoices_masked')
            .select('code, issue_date, customer_id, bill_to_snapshot')
            .eq('id', cn.invoice_id).maybeSingle(),
        'invoices') as {
            code: string; issue_date: string; customer_id: string
            bill_to_snapshot: Record<string, string | null> | null } | null
    if (!inv) return null

    const lines = mustRows(
        await supabase.from('credit_note_lines')
            .select('invoice_line_id, kind, qty, amount')
            .eq('credit_note_id', id).order('created_at'),
        'credit_note_lines') as unknown as {
            invoice_line_id: string; kind: string; qty: number | null; amount: number }[]

    const ilIds = [...new Set(lines.map((l) => l.invoice_line_id))]
    const il = ilIds.length === 0 ? [] : (mustRows(
        await supabase.from('invoice_lines_masked')
            .select('id, line_no, description').in('id', ilIds),
        'invoice_lines') as unknown as { id: string; line_no: number; description: string }[])
    const byId = new Map(il.map((r) => [r.id, r]))

    // 【抬头取发票存下来的那一份 bill_to_snapshot】—— 几年后重打要看到当时寄出
    // 的内容,而不是现在的客户资料(发票详情页的同一条理由)。
    const bill = inv.bill_to_snapshot ?? {}
    return {
        code: cn.code,
        note_date: cn.note_date,
        reason: cn.reason,
        currency: cn.currency,
        invoice_code: inv.code,
        invoice_issue_date: inv.issue_date,
        customer: {
            code: bill.code ?? '—',
            legal_name: bill.legal_name ?? '—',
        },
        lines: lines.map((l) => ({
            line_no: byId.get(l.invoice_line_id)?.line_no ?? 0,
            description: byId.get(l.invoice_line_id)?.description ?? '—',
            kind: l.kind,
            qty: l.qty === null ? null : Number(l.qty),
            amount: Number(l.amount),
        })),
        total: Math.round(lines.reduce((s, l) => s + Number(l.amount), 0) * 100) / 100,
    }
}

// 【渲染前过一遍字体覆盖守卫】裁剪范围外的字会被静默画成空白,而发给客户的
// 单据上出现空白是真实事故(与发票/采购单/销售订单同一条)。
function collectStrings(d: CnDocData): PdfTextField[] {
    return [
        { where: 'customer legal_name', text: d.customer.legal_name },
        { where: 'credit note reason', text: d.reason },
        ...d.lines.map((l) => ({ where: `line ${l.line_no} description`, text: l.description })),
    ]
}

async function render(d: CnDocData): Promise<Buffer> {
    const bad = findUnrenderableText(collectStrings(d))
    if (bad.length > 0) throw new Error(coverageErrorMessage(bad))
    const doc = CreditNoteDocument({ data: d }) as unknown as ReactElement<DocumentProps>
    return await renderToBuffer(doc)
}

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const version = new URL(request.url).searchParams.get('version')
    try {
        const supabase = await createClient()

        if (version) {
            const issue = mustOne(
                await supabase.from('cn_issues').select('file_path, sha256')
                    .eq('credit_note_id', id).eq('version', Number(version)).maybeSingle(),
                'cn_issues') as { file_path: string; sha256: string } | null
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
        // 对象键不含版本号 —— 版本由 record_cn_issue 在数据库里裁决(并发安全)
        const path = `${id}/${sha}.pdf`
        const up = await supabase.storage.from(BUCKET).upload(path, buf, {
            contentType: 'application/pdf', upsert: true,
        })
        if (up.error) return new NextResponse(`Upload failed: ${up.error.message}`, { status: 500 })

        const { data, error } = await supabase.rpc('record_cn_issue', {
            p_credit_note_id: id, p_file_path: path, p_sha256: sha,
        })
        if (error) return new NextResponse(await localizeCreditNoteError(error.message), { status: 400 })
        return NextResponse.json(data)
    } catch (e) {
        return new NextResponse(`Issue failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}
