// app/finance/statements/[id]/pdf/route.ts
// 客户对账单 PDF。三个入口,形状逐字取自贷项凭证那一份(它取自销售订单/采购单):
//   GET             渲染【冻下来的那一行】,inline 打开,不落档
//   GET ?version=N  取签发档 —— 从 statement-documents 桶里流出当时的字节,并对着
//                   statement_issues.sha256 校验:对象被动过就拒绝
//   POST            签发 —— 渲染、存桶、record_statement_issue() 记档
//
// ★【与前七个的唯一区别,也是这一族真正新的那一半】★
// 前七个的 GET 是【按当前数据渲染】—— 一张发票的内容本来就不会变。
// 对账单的正文是一个【区间的计算结果】,它每天都在变。所以这里的 GET
// **不重算**:它读 customer_statements 那一行冻下来的数字与明细。
// 重算的那一份在客户档案页上(签发之前的预览),两者是不同的问题,
// 而"日后有人问的一定是【当时寄出去的那一份】"——
// 与 gst_return_boxes、bank_reconciliations 同一条。
import { NextResponse } from 'next/server'
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer'
import { createHash } from 'node:crypto'
import type { ReactElement } from 'react'
import { createClient } from '@/lib/supabase/server'
import { mustOne } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import StatementDocument, { type StatementDocData, type StatementLine } from './StatementDocument'
import { findUnrenderableText, coverageErrorMessage, type PdfTextField } from '@/lib/pdfFontCoverage'
import { localizeStatementError } from '../../statementErrorCodes'

const BUCKET = 'statement-documents'

type Row = {
    id: string; code: string; customer_id: string
    period_start: string; period_end: string; base_currency: string
    opening_base: number; charges_base: number; credits_base: number
    receipts_base: number; closing_base: number
    lines: StatementLine[]
    by_currency: { currency: string; closing_ccy: number }[]
    buckets: Record<string, number>
    issued_at: string; superseded_at: string | null
}

async function loadDoc(id: string): Promise<StatementDocData | null> {
    const supabase = await createClient()
    const t = await getTranslations()

    const st = mustOne(
        await supabase.from('customer_statements')
            .select('id, code, customer_id, period_start, period_end, base_currency, '
                  + 'opening_base, charges_base, credits_base, receipts_base, closing_base, '
                  + 'lines, by_currency, buckets, issued_at, superseded_at')
            .eq('id', id).maybeSingle(),
        'customer_statements') as unknown as Row | null
    if (!st) return null

    const cust = mustOne(
        await supabase.from('customers').select('code, legal_name')
            .eq('id', st.customer_id).maybeSingle(),
        'customers') as { code: string; legal_name: string } | null
    if (!cust) return null

    const company = mustOne(
        // 【读遮蔽视图,不直连表】与采购单/发票那两份 PDF 同一条:被扣下的列在
        // 视图里按权限呈现为 null,而不是让整条查询 42501(见 lib/permissions.ts)。
        await supabase.from('company_profile_masked')
            .select('legal_name, address_lines, city, postal_code, country, registration_no, phone, email, website, logo_path')
            .limit(1).maybeSingle(),
        'company_profile_masked') as (StatementDocData['company'] & { logo_path: string | null }) | null
    // 【没有公司抬头就不出这份文书】一份没有我们名字的"要钱的纸"寄出去是真实事故 ——
    // 与 record_invoice_issue 的同一条,而且这里说的是【去哪儿补】。
    if (!company || !company.legal_name) {
        throw new Error(t('statements.errors.COMPANY_PROFILE_INCOMPLETE'))
    }

    // 【上传的 logo 不再下载】PDF-1:对外单据印的是矢量字标(见文档组件里的说明),
    // 不再印 company_profile.logo_path 那张位图 —— 于是这里那段"从私有桶下字节、
    // 转 data URI"就成了一次【没有人会看的存储下载】,每渲染一次白花一次往返。

    // 【冻下来的两个数在这里【算出来】,因为它们是那五个数的函数,不是新事实】
    const applied = Math.round(
        (st.opening_base + st.charges_base - st.credits_base - st.closing_base) * 100) / 100
    const onAccount = Math.round((st.receipts_base - applied) * 100) / 100

    return {
        code: st.code,
        customer: cust,
        period_start: st.period_start,
        period_end: st.period_end,
        base_currency: st.base_currency,
        opening_base: Number(st.opening_base),
        charges_base: Number(st.charges_base),
        credits_base: Number(st.credits_base),
        receipts_base: Number(st.receipts_base),
        applied_base: applied,
        on_account_base: onAccount,
        net_due_base: Math.round((Number(st.closing_base) - onAccount) * 100) / 100,
        closing_base: Number(st.closing_base),
        no_movement: Number(st.charges_base) === 0 && Number(st.credits_base) === 0
                     && Number(st.receipts_base) === 0,
        lines: (st.lines ?? []) as StatementLine[],
        by_currency: (st.by_currency ?? []) as { currency: string; closing_ccy: number }[],
        buckets: (st.buckets ?? {}) as Record<string, number>,
        issued_at: st.issued_at,
        superseded: st.superseded_at !== null,
        company,
        // 【按界面语言选一条,不拼接】—— check-bilingual-concat 拒绝把 zh 与 en 拼起来印
        t: {
            title: t('statements.doc.title'),
            summary: t('statements.doc.summary'),
            opening: t('statements.doc.opening'),
            charges: t('statements.doc.charges'),
            credits: t('statements.doc.credits'),
            applied: t('statements.doc.applied'),
            closing: t('statements.doc.closing'),
            onAccount: t('statements.doc.onAccount'),
            netDue: t('statements.doc.netDue'),
            noMovement: t('statements.doc.noMovement'),
            byCurrency: t('statements.doc.byCurrency'),
            baseIsConverted: t('statements.doc.baseIsConverted', { ccy: st.base_currency }),
            openItems: t('statements.doc.openItems'),
            nothingOutstanding: t('statements.doc.nothingOutstanding'),
            ageing: t('statements.doc.ageing'),
            frozenNote: t('statements.doc.frozenNote', { at: st.issued_at.slice(0, 10) }),
            noDueDate: t('statements.doc.noDueDate'),
            // CONV-0 ②f:无需签章那一句。本份单据【跟随界面语言】,
            // 所以它走 t() 而不是 noSignatureEn() —— 八份里只有它与可追溯报告如此。
            noSignature: t('pdf.noSignature.statement'),
            colDoc: t('statements.doc.colDoc'),
            colKind: t('statements.doc.colKind'),
            colDate: t('statements.doc.colDate'),
            colDue: t('statements.doc.colDue'),
            colCcy: t('statements.doc.colCcy'),
            colAmount: t('statements.doc.colAmount'),
            colOpen: t('statements.doc.colOpen'),
            colDays: t('statements.doc.colDays'),
            kind_sale: t('statements.doc.kind_sale'),
            kind_invoice: t('statements.doc.kind_invoice'),
            bucket_b0_30: t('finance.aging.b0_30'),
            bucket_b31_60: t('finance.aging.b31_60'),
            bucket_b61_90: t('finance.aging.b61_90'),
            bucket_b90_plus: t('finance.aging.b90_plus'),
        },
    }
}

// 渲染前过字体覆盖守卫 —— 裁剪范围外的字会被静默画成空白,而发给客户的纸上
// 出现空白是真实事故(与发票/采购单/贷项凭证同一条)。
function collectStrings(d: StatementDocData): PdfTextField[] {
    return [
        { where: 'customer legal_name', text: d.customer.legal_name },
        { where: 'company legal_name', text: d.company.legal_name },
        ...d.lines.map((l, i) => ({ where: `line ${i + 1} doc_code`, text: l.doc_code })),
    ]
}

async function render(d: StatementDocData): Promise<Buffer> {
    const bad = findUnrenderableText(collectStrings(d))
    if (bad.length > 0) throw new Error(coverageErrorMessage(bad))
    const doc = StatementDocument({ data: d }) as unknown as ReactElement<DocumentProps>
    return await renderToBuffer(doc)
}

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const version = new URL(request.url).searchParams.get('version')
    try {
        const supabase = await createClient()

        if (version) {
            const issue = mustOne(
                await supabase.from('statement_issues').select('file_path, sha256')
                    .eq('statement_id', id).eq('version', Number(version)).maybeSingle(),
                'statement_issues') as { file_path: string; sha256: string } | null
            if (!issue) return new NextResponse('Not found', { status: 404 })
            const dl = await supabase.storage.from(BUCKET).download(issue.file_path)
            if (dl.error || !dl.data) return new NextResponse('Stored document unavailable', { status: 404 })
            const bytes = Buffer.from(await dl.data.arrayBuffer())
            const sha = createHash('sha256').update(bytes).digest('hex')
            if (sha !== issue.sha256) {
                // 对不上就拒绝 —— 一份与记录不符的"档案"比没有档案更坏
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
        // 对象键不含版本号 —— 版本由 record_statement_issue 在数据库里裁决(并发安全)
        const path = `${id}/${sha}.pdf`
        const up = await supabase.storage.from(BUCKET).upload(path, buf, {
            contentType: 'application/pdf', upsert: true,
        })
        if (up.error) return new NextResponse(`Upload failed: ${up.error.message}`, { status: 500 })

        const { data, error } = await supabase.rpc('record_statement_issue', {
            p_statement_id: id, p_file_path: path, p_sha256: sha,
        })
        if (error) return new NextResponse(await localizeStatementError(error.message), { status: 400 })
        return NextResponse.json(data)
    } catch (e) {
        return new NextResponse(`Issue failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}
