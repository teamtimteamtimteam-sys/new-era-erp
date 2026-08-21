// app/purchasing/orders/[id]/pdf/route.ts
// 采购单 PDF。三个入口(规格:docs/purchase-order-document.md):
//   GET             预览 —— 按【当前】数据渲染,inline 打开,不落档
//   GET ?version=N  取【签发档】—— 从 po-documents 桶里流出当时存下的字节,
//                   并对着 po_issues.sha256 校验:对象被动过就拒绝,不给一份
//                   与记录对不上的"档案"
//   POST            签发 —— 渲染、存桶、record_po_issue() 记档,回附件
//
// 【签发的是记录,不是视图】(§C)。供应商手里那份是某个具体版本;此后数据、渲染器、
// 字体子集怎么变,那份字节都原样在桶里。
import { NextResponse } from 'next/server'
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer'
import { createHash } from 'node:crypto'
import React from 'react'
import { createClient } from '@/lib/supabase/server'
import PurchaseOrderDocument, { type PoDocData, pricingStatusText } from './PurchaseOrderDocument'
import type { CompanyProfile } from '@/app/finance/invoices/[id]/pdf/InvoiceDocument'
import { findUnrenderableText, coverageErrorMessage, type PdfTextField } from '@/lib/invoiceFontCoverage'

const LOGO_MIME: Record<string, string> = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg' }

// 与发票同一套响应头转义(RFC 6266/5987)—— 文件名是拼进 HTTP 头的
function contentDispositionFilename(name: string): string {
    const ascii = name
        // eslint-disable-next-line no-control-regex
        .replace(/[^\u0020-\u007e]/g, '_')
        .replace(/["\\]/g, '\\$&')
    return `filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(name)}`
}

// 本文档要印的每一个字符串 —— 渲染前过一遍字体覆盖守卫(与发票同一条理由:
// 裁剪范围外的字被静默画成空白,而发给供应商的单据上出现空白是真实事故)
function collectPoPdfStrings(data: PoDocData, company: CompanyProfile): PdfTextField[] {
    const fields: PdfTextField[] = [
        { where: 'company profile legal_name', text: company.legal_name },
        { where: 'company profile address', text: [company.address_lines, company.city, company.postal_code, company.country].filter(Boolean).join(', ') },
        { where: 'supplier legal_name', text: data.supplier.legal_name },
        { where: 'supplier address', text: data.supplier.address },
        { where: 'po terms_text', text: data.terms_text },
        { where: 'po notes', text: data.notes },
        { where: 'po incoterm', text: data.incoterm },
    ]
    for (const l of data.lines) {
        fields.push({ where: `line ${l.line_no} material`, text: l.material_name })
        fields.push({ where: `line ${l.line_no} notes`, text: l.notes })
        for (const s of pricingStatusText(l)) fields.push({ where: `line ${l.line_no} pricing`, text: s })
    }
    for (const t of data.payment_terms) {
        fields.push({ where: `payment term ${t.seq}`, text: `${t.label} ${t.notes ?? ''}` })
    }
    return fields
}

async function renderPo(supabase: Awaited<ReturnType<typeof createClient>>, poId: string) {
    // 单据数据【问数据库】—— 逐行定价状态的裁决在 po_document_data 里,
    // PDF 与 fixture 36 读的是同一份实现
    const { data: doc, error } = await supabase.rpc('po_document_data', { p_po_id: poId })
    if (error) return { error: new NextResponse(error.message, { status: 404 }) }
    const data = doc as unknown as PoDocData

    const { data: companyRow } = await supabase
        .from('company_profile_masked').select('*').limit(1).single()
    const company = companyRow as CompanyProfile | null
    if (!company || !company.legal_name?.trim()) {
        return {
            error: new NextResponse(
                'Company details are not set up yet — a purchase order cannot be issued without your legal name.\nFill them in at /finance/company\n',
                { status: 409, headers: { 'Content-Type': 'text/plain; charset=utf-8' } }
            ),
        }
    }

    const problems = findUnrenderableText(collectPoPdfStrings(data, company))
    if (problems.length) {
        return {
            error: new NextResponse(coverageErrorMessage(problems), {
                status: 409, headers: { 'Content-Type': 'text/plain; charset=utf-8' },
            }),
        }
    }

    let logo: string | null = null
    if (company.logo_path) {
        const mime = LOGO_MIME[company.logo_path.split('.').pop()?.toLowerCase() ?? '']
        if (mime) {
            const { data: blob } = await supabase.storage.from('company-assets').download(company.logo_path)
            if (blob) logo = `data:${mime};base64,${Buffer.from(await blob.arrayBuffer()).toString('base64')}`
        }
    }

    // EQP-1c-b-fu2:这张单是不是设备单 —— 只决定明细的列头(Machine vs Material)。
    // 【一张单只有一种】EQP-1a 的 N1 由延迟约束触发器保证不混装,所以任意一行
    // 带 asset_id 就是整单的种类。这里读的是【种类】,而行的名字仍然来自
    // po_document_data(它已经 COALESCE 过资产描述)—— 屏幕与纸不会各说各话。
    const { data: kindRows } = await supabase
        .from('purchase_order_lines').select('asset_id').eq('purchase_order_id', poId).limit(1)
    const isEquipment = (kindRows ?? []).some((r) => r.asset_id !== null)

    const element = React.createElement(PurchaseOrderDocument, { data, company, logo, isEquipment }) as React.ReactElement<DocumentProps>
    const buffer = await renderToBuffer(element)
    return { buffer, code: data.code }
}

export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const supabase = await createClient()
    const version = new URL(req.url).searchParams.get('version')

    if (version) {
        // ── 签发档:流出当时的字节,并对着记录校验 ──────────────────────────
        const { data: issue, error } = await supabase
            .from('po_issues')
            .select('file_path, sha256, version, purchase_order_id')
            .eq('purchase_order_id', id).eq('version', Number(version)).single()
        if (error || !issue) return new NextResponse('Issue not found', { status: 404 })

        const { data: blob, error: dlErr } = await supabase.storage.from('po-documents').download(issue.file_path)
        if (dlErr || !blob) return new NextResponse('Stored document missing from bucket', { status: 500 })
        const bytes = Buffer.from(await blob.arrayBuffer())
        const sha = createHash('sha256').update(bytes).digest('hex')
        if (sha !== issue.sha256) {
            // 对象与签发记录对不上 —— 宁可拒绝,不给一份来历不明的"档案"
            return new NextResponse(
                `Stored document does not match the issue record (sha256 mismatch).\nExpected ${issue.sha256}\nGot      ${sha}\n`,
                { status: 409, headers: { 'Content-Type': 'text/plain; charset=utf-8' } }
            )
        }
        const { data: po } = await supabase.from('purchase_orders_masked').select('code').eq('id', id).single()
        return new NextResponse(new Uint8Array(bytes), {
            headers: {
                'Content-Type': 'application/pdf',
                'Content-Disposition': `attachment; ${contentDispositionFilename(`${po?.code ?? 'PO'}-v${issue.version}.pdf`)}`,
                'Cache-Control': 'no-store',
            },
        })
    }

    // ── 预览:按当前数据渲染,不落档 ────────────────────────────────────────
    const r = await renderPo(supabase, id)
    if ('error' in r && r.error) return r.error
    return new NextResponse(new Uint8Array(r.buffer!), {
        headers: {
            'Content-Type': 'application/pdf',
            'Content-Disposition': `inline; ${contentDispositionFilename(`${r.code}-preview.pdf`)}`,
            'Cache-Control': 'no-store',
        },
    })
}

export async function POST(_req: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const supabase = await createClient()

    const r = await renderPo(supabase, id)
    if ('error' in r && r.error) return r.error
    const bytes = r.buffer!
    const sha = createHash('sha256').update(bytes).digest('hex')

    // 对象键不含版本号 —— 版本由 record_po_issue 在数据库里裁决(并发安全),
    // 键只要唯一即可;行与对象靠 file_path + sha256 互指。
    const filePath = `${id}/${crypto.randomUUID()}.pdf`
    const { error: upErr } = await supabase.storage.from('po-documents')
        .upload(filePath, new Uint8Array(bytes), { contentType: 'application/pdf' })
    if (upErr) return new NextResponse(`Upload failed: ${upErr.message}`, { status: 500 })

    const { data: rec, error: recErr } = await supabase.rpc('record_po_issue', {
        p_po_id: id, p_file_path: filePath, p_sha256: sha,
    })
    if (recErr) {
        // 记录失败 → 把孤儿对象清掉再报错:桶里不该留一份没有档案的"签发件"
        await supabase.storage.from('po-documents').remove([filePath])
        return new NextResponse(recErr.message, { status: 409 })
    }
    const issued = rec as unknown as { version: number; code: string }

    return new NextResponse(new Uint8Array(bytes), {
        headers: {
            'Content-Type': 'application/pdf',
            'Content-Disposition': `attachment; ${contentDispositionFilename(`${issued.code}-v${issued.version}.pdf`)}`,
            'Cache-Control': 'no-store',
        },
    })
}
