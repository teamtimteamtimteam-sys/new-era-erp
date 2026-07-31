// app/finance/invoices/[id]/pdf/route.ts
// 发票 PDF:GET 返回 application/pdf,inline 打开,文件名用发票编号。
// 【只在服务端渲染】(renderToBuffer),渲染器不进浏览器包。
//
// logo:在服务端把私有桶里的字节【下载下来内嵌成 data URI】,而不是给渲染器一个签名
// URL。原因是可靠性 —— 签名 URL 要求渲染过程中再发一次网络请求,一旦超时或签名过期,
// 拿到的就是一份缺图的 PDF(而且失败是静默的);先下载则要么拿到图,要么明确失败,
// 且整份文档的生成不依赖外部网络时序。
import { NextResponse } from 'next/server'
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer'
import { createClient } from '@/lib/supabase/server'
import InvoiceDocument, {
    type CompanyProfile,
    type InvoiceData,
    type InvoiceLine,
} from './InvoiceDocument'
import { checkInvoicePdfCoverage, coverageErrorMessage } from '@/lib/invoiceFontCoverage'
import React from 'react'

const LOGO_MIME: Record<string, string> = {
    png: 'image/png',
    jpg: 'image/jpeg',
    jpeg: 'image/jpeg',
}

export async function GET(
    _req: Request,
    { params }: { params: Promise<{ id: string }> }
) {
    const { id } = await params
    const supabase = await createClient()

    const [invRes, companyRes, settingsRes] = await Promise.all([
        supabase
            .from('invoices')
            .select('code, issue_date, due_date, payment_terms_days, currency, subtotal_usd, tax_rate_pct, tax_usd, total_usd, status, notes, terms_text, bill_to_snapshot')
            .eq('id', id)
            .single(),
        supabase.from('company_profile').select('*').limit(1).single(),
        supabase.from('finance_settings').select('gst_registration_no').limit(1).single(),
    ])

    if (invRes.error || !invRes.data) {
        return new NextResponse('Invoice not found', { status: 404 })
    }

    const company = companyRes.data as CompanyProfile | null

    // 守卫:公司抬头没填就不出这份 PDF —— 一张没有公司名的发票寄出去是真实事故。
    if (!company || !company.legal_name?.trim()) {
        return new NextResponse(
            `Company details are not set up yet.\n\n` +
                `An invoice cannot be issued without your company's legal name and address.\n` +
                `Please fill them in at:  /finance/company\n`,
            { status: 409, headers: { 'Content-Type': 'text/plain; charset=utf-8' } }
        )
    }

    const { data: lineRows } = await supabase
        .from('invoice_lines')
        .select('line_no, description, quantity, unit, unit_price, amount_usd')
        .eq('invoice_id', id)
        .order('line_no', { ascending: true })

    // logo:下载字节内嵌(见文件头注释)。SVG 渲染器不支持,故只接受 PNG/JPG;
    // 取不到或格式不认识就当作没有 logo,照常出 PDF。
    let logo: string | null = null
    if (company.logo_path) {
        const ext = company.logo_path.split('.').pop()?.toLowerCase() ?? ''
        const mime = LOGO_MIME[ext]
        if (mime) {
            const { data: blob } = await supabase.storage.from('company-assets').download(company.logo_path)
            if (blob) {
                const bytes = Buffer.from(await blob.arrayBuffer())
                logo = `data:${mime};base64,${bytes.toString('base64')}`
            }
        }
    }

    const inv = invRes.data
    const invoice: InvoiceData = {
        code: inv.code,
        issue_date: inv.issue_date,
        due_date: inv.due_date,
        payment_terms_days: inv.payment_terms_days,
        currency: inv.currency,
        subtotal_usd: Number(inv.subtotal_usd),
        tax_rate_pct: Number(inv.tax_rate_pct),
        tax_usd: Number(inv.tax_usd),
        total_usd: Number(inv.total_usd),
        status: inv.status,
        notes: inv.notes,
        terms_text: inv.terms_text,
        bill_to: (inv.bill_to_snapshot ?? {}) as Record<string, string | null | undefined>,
    }

    const lines: InvoiceLine[] = (lineRows ?? []).map((l) => ({
        line_no: l.line_no,
        description: l.description,
        quantity: Number(l.quantity),
        unit: l.unit,
        unit_price: Number(l.unit_price),
        amount_usd: Number(l.amount_usd),
    }))

    // 守卫:内嵌的是【裁剪过的】中文字体,范围外的字会被静默画成空白 —— 一份寄给
    // 客户的单据上出现空白是真实事故,而且没人会发现(PDF 生成"成功"了)。所以渲染前
    // 把这份文档要印的每一个字符串过一遍,有印不出来的字就【不出 PDF】,并明确指出是
    // 哪几个字、出现在哪。要放宽范围:改 assets/fonts/subset.py 的区间后重跑该脚本。
    const coverageProblems = checkInvoicePdfCoverage({
        invoice,
        lines,
        company: company as unknown as Record<string, unknown> & { legal_name: string },
        gstRegistrationNo: settingsRes.data?.gst_registration_no ?? null,
    })
    if (coverageProblems.length) {
        return new NextResponse(coverageErrorMessage(coverageProblems), {
            status: 409,
            headers: { 'Content-Type': 'text/plain; charset=utf-8' },
        })
    }

    // renderToBuffer 的签名要求顶层元素是 ReactElement<DocumentProps>;我们的组件
    // 返回的正是 <Document>,但它自身的 props 类型不是 DocumentProps,故在此断言。
    const element = React.createElement(InvoiceDocument, {
        invoice,
        lines,
        company,
        gstRegistrationNo: settingsRes.data?.gst_registration_no ?? null,
        logo,
    }) as React.ReactElement<DocumentProps>

    const buffer = await renderToBuffer(element)

    return new NextResponse(new Uint8Array(buffer), {
        headers: {
            'Content-Type': 'application/pdf',
            'Content-Disposition': `inline; filename="${invoice.code}.pdf"`,
            'Cache-Control': 'no-store',
        },
    })
}
