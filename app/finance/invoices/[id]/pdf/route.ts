// app/finance/invoices/[id]/pdf/route.ts
// 发票 PDF。INV-2b 之后是三个入口,形状取自销售订单那一份(它取自采购单):
//   GET             预览 —— 按【当前】数据渲染,inline 打开,【不落档】
//   GET ?download=1 同上,只是存成文件(本刀之前就有的那两个入口)
//   GET ?version=N  取【签发档】—— 从 invoice-documents 桶里流出当时存下的字节,
//                   并对着 invoice_issues.sha256 校验:对象被动过就拒绝,
//                   不给一份与记录对不上的档案
//   POST            签发 —— 渲染、存桶、record_invoice_issue() 记档
//
// 【预览与签发是两件事,而这一句是这一刀的全部】预览按【此刻】的数据渲染,看完就没了;
// 签发把那一刻的字节存进桶里并记一版 —— 客户手里那份是某个具体版本,此后数据、
// 渲染器、字体子集怎么变,那份字节都原样在桶里。
//
// 【三份渲染必须是同一份】所以渲染那一段抽成 buildInvoicePdf(),GET 与 POST 共用:
// 两处实现会在写下来的那天一致,然后悄悄分叉(AGENTS.md 那条"一处实现,两个调用者")。
// 预览这一支的行为一个字没改。
// 发票 PDF:GET 返回 application/pdf,inline 打开,文件名用发票编号。
// 【只在服务端渲染】(renderToBuffer),渲染器不进浏览器包。
//
// logo:在服务端把私有桶里的字节【下载下来内嵌成 data URI】,而不是给渲染器一个签名
// URL。原因是可靠性 —— 签名 URL 要求渲染过程中再发一次网络请求,一旦超时或签名过期,
// 拿到的就是一份缺图的 PDF(而且失败是静默的);先下载则要么拿到图,要么明确失败,
// 且整份文档的生成不依赖外部网络时序。
import { NextResponse } from 'next/server'
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer'
import { createHash } from 'node:crypto'
import { createClient } from '@/lib/supabase/server'
import { mustOne } from '@/lib/db-helpers'
import { localizeInvoiceError } from '../../../invoiceErrorCodes'
import InvoiceDocument, {
    type CompanyProfile,
    type InvoiceData,
    type InvoiceLine,
} from './InvoiceDocument'
import { checkInvoicePdfCoverage, coverageErrorMessage } from '@/lib/invoiceFontCoverage'
import React from 'react'
import { unmasked } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { canViewBanking } from '@/lib/permissions'

const BUCKET = 'invoice-documents'

const LOGO_MIME: Record<string, string> = {
    png: 'image/png',
    jpg: 'image/jpeg',
    jpeg: 'image/jpeg',
}

// Content-Disposition 的文件名部分(RFC 6266)。发票编号目前都是 INV-2026-0001 这种
// 纯 ASCII,但文件名是【拼进 HTTP 头】的:里面只要混进一个引号或换行就能把这个头
// 截断。所以 filename= 走转义后的 quoted-string,并额外给一个 filename*(RFC 5987)
// 以防编号哪天带上非 ASCII 字符 —— 浏览器优先认 filename*。
function contentDispositionFilename(name: string): string {
    const ascii = name
        // eslint-disable-next-line no-control-regex
        .replace(/[^\u0020-\u007e]/g, '_') // 非 ASCII 可打印字符一律换掉:响应头只能放
        // ByteString,留一个汉字进去 Headers 就直接抛异常(→ 500)。真正的中文名靠
        // 下面的 filename* 传,这里只是给老浏览器的退路。
        .replace(/["\\]/g, '\\$&') // 引号和反斜杠:quoted-string 里要转义
    return `filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(name)}`
}

// 【渲染这一段:GET 预览与 POST 签发共用】返回渲染好的字节与发票编号,
// 或者一个【已经成形的拒绝响应】—— 三道守卫(公司抬头、单据币种金额、字体覆盖)
// 一个字没动,只是从 GET 的身体里搬进来。签发不该比预览宽松:一份印不出字的
// PDF 记进档案,比当场不出这份 PDF 坏得多。
async function buildInvoicePdf(id: string): Promise<
    { ok: true; buffer: Buffer; code: string } | { ok: false; response: NextResponse }
> {
    const supabase = await createClient()

    const [invRes, companyRes, settingsRes, totalsRes] = await Promise.all([
        supabase
            .from('invoices_masked')
            .select('code, issue_date, due_date, payment_terms_days, currency, subtotal_base, tax_rate_pct, tax_base, total_base, status, notes, terms_text, bill_to_snapshot')
            .eq('id', id)
            .single(),
        supabase.from('company_profile_masked').select('*').limit(1).single(),
        supabase.from('finance_settings').select('gst_registration_no').limit(1).single(),
        // INV-1:客户账单上的数是【单据币种】的 —— *_base 是本位币,给账用的。
        // 此前 PDF 拿 currency 标 total_base,已发出的两张各多报 1,440 / 336 USD。
        supabase
            .from('invoice_document_totals')
            .select('subtotal_ccy, tax_ccy, total_ccy')
            .eq('invoice_id', id)
            .single(),
    ])

    if (invRes.error || !invRes.data) {
        return { ok: false, response: new NextResponse('Invoice not found', { status: 404 }) }
    }

    const company = companyRes.data as CompanyProfile | null

    // 守卫:公司抬头没填就不出这份 PDF —— 一张没有公司名的发票寄出去是真实事故。
    if (!company || !company.legal_name?.trim()) {
        return { ok: false, response: new NextResponse(
            `Company details are not set up yet.\n\n` +
                `An invoice cannot be issued without your company's legal name and address.\n` +
                `Please fill them in at:  /finance/company\n`,
            { status: 409, headers: { 'Content-Type': 'text/plain; charset=utf-8' } }
        ) }
    }

    const { data: lineRows } = await supabase
        .from('invoice_lines_masked')
        .select('line_no, description, quantity, unit, unit_price, amount_ccy')
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

    // cut 2b:改读遮蔽视图(基表原始敏感列已收回)。断言回基表行类型 —— 能取到发票 PDF 的
    // 角色全都持有 data.view_prices,列不会被遮蔽。见 lib/maskedRows.ts。
    const inv = unmasked<Tables<'invoices'>>(invRes.data)
    // INV-1:金额三项来自 invoice_document_totals(单据币种),在下面与这份抬头合并。
    const invoice: Omit<InvoiceData, 'subtotal_ccy' | 'tax_ccy' | 'total_ccy'> = {
        code: inv.code,
        issue_date: inv.issue_date,
        due_date: inv.due_date,
        payment_terms_days: inv.payment_terms_days,
        currency: inv.currency,
        tax_rate_pct: Number(inv.tax_rate_pct),
        status: inv.status,
        notes: inv.notes,
        terms_text: inv.terms_text,
        bill_to: (inv.bill_to_snapshot ?? {}) as Record<string, string | null | undefined>,
    }

    const lines: InvoiceLine[] = unmasked<Tables<'invoice_lines'>[]>(lineRows ?? []).map((l) => ({
        line_no: l.line_no,
        description: l.description,
        quantity: Number(l.quantity),
        unit: l.unit,
        unit_price: Number(l.unit_price),
        amount_ccy: Number(l.amount_ccy),
    }))

    // 守卫:内嵌的是【裁剪过的】中文字体,范围外的字会被静默画成空白 —— 一份寄给
    // 客户的单据上出现空白是真实事故,而且没人会发现(PDF 生成"成功"了)。所以渲染前
    // 把这份文档要印的每一个字符串过一遍,有印不出来的字就【不出 PDF】,并明确指出是
    // 哪几个字、出现在哪。要放宽范围:改 assets/fonts/subset.py 的区间后重跑该脚本。
    // INV-1:单据币种的金额取不到就【不出这张 PDF】—— 缺数的发票与错数的发票
    // 一样会寄到客户手上;而这几个数正是他要照着付款的那几个。
    if (totalsRes.error || !totalsRes.data) {
        return { ok: false, response: new NextResponse(
            `Invoice amounts in the document currency are unavailable.\n\n` +
                `This usually means the invoice has no lines, or you lack permission to view amounts.\n`,
            { status: 409, headers: { 'Content-Type': 'text/plain; charset=utf-8' } }
        ) }
    }

    const invoiceForDoc = {
        ...invoice,
        subtotal_ccy: Number(totalsRes.data.subtotal_ccy),
        tax_ccy: Number(totalsRes.data.tax_ccy),
        total_ccy: Number(totalsRes.data.total_ccy),
    }
    const coverageProblems = checkInvoicePdfCoverage({
        invoice: invoiceForDoc,
        lines,
        company: company as unknown as Record<string, unknown> & { legal_name: string },
        gstRegistrationNo: settingsRes.data?.gst_registration_no ?? null,
    })
    if (coverageProblems.length) {
        return { ok: false, response: new NextResponse(coverageErrorMessage(coverageProblems), {
            status: 409,
            headers: { 'Content-Type': 'text/plain; charset=utf-8' },
        }) }
    }

    // renderToBuffer 的签名要求顶层元素是 ReactElement<DocumentProps>;我们的组件
    // 返回的正是 <Document>,但它自身的 props 类型不是 DocumentProps,故在此断言。
    const element = React.createElement(InvoiceDocument, {
        invoice: invoiceForDoc,
        lines,
        company,
        gstRegistrationNo: settingsRes.data?.gst_registration_no ?? null,
        logo,
    }) as React.ReactElement<DocumentProps>

    const buffer = await renderToBuffer(element)
    return { ok: true, buffer, code: invoice.code }
}

// 【两道门都要过,而它们问的不是同一件事】渲染这条路要 data.view_banking(这份
// 文件上印着公司收款账号);签发那个动作还要 module.finance.edit,由
// record_invoice_issue 自己判。INV-2a 的迁移抬头把这个合取写下来了:
// 谁都不是从谁那里顺带继承来的。取签发档同样要 view_banking —— 桶里那份字节
// 与现渲染的那份印着同样的账号,按权限说它们是同一样东西。
async function requireBanking(): Promise<NextResponse | null> {
    // cut 3:发票 PDF 上印着公司收款账号,因此整份文件要 data.view_banking。
    // 【为什么整份拒绝,而不是把银行区块留空】:发票是要寄出去的对外单据。银行区块
    // 空着,客户就没法付款,而经手人多半不会察觉自己发出去的是一张残缺的单子 ——
    // "看起来正常但付不了款"比"这份 PDF 你没有权限生成"糟糕得多。
    // 代价:auditor 有 module.finance.view 但没有 data.view_banking,因此下载不了 PDF;
    // 它仍然可以在详情页上读到发票的全部内容,也读得到签发档那几行。这是有意的取舍。
    if (!(await canViewBanking())) {
        return new NextResponse('Forbidden: requires data.view_banking', { status: 403 })
    }
    return null
}

export async function GET(
    req: Request,
    { params }: { params: Promise<{ id: string }> }
) {
    const { id } = await params
    // ?download=1 → 存成文件(attachment);不带则在浏览器里直接打开(inline)。
    // 两个入口对应两个不同的时刻:详情页要先看一眼版式,列表页/要往邮件里附时要拿文件。
    const asDownload = new URL(req.url).searchParams.get('download') === '1'
    const version = new URL(req.url).searchParams.get('version')
    const denied = await requireBanking()
    if (denied) return denied

    if (version) {
        // 【取签发档:桶里的字节 + 对着记录校验】这一支【不渲染】—— 它的全部意义
        // 就是"当时发出去的到底是哪一份字节",重新渲染一次就把这个问题答没了。
        const supabase = await createClient()
        const issue = mustOne(
            await supabase.from('invoice_issues').select('file_path, sha256')
                .eq('invoice_id', id).eq('version', Number(version)).maybeSingle(),
            'invoice_issues') as { file_path: string; sha256: string } | null
        if (!issue) return new NextResponse('Not found', { status: 404 })
        const dl = await supabase.storage.from(BUCKET).download(issue.file_path)
        if (dl.error || !dl.data) return new NextResponse('Stored document unavailable', { status: 404 })
        const bytes = Buffer.from(await dl.data.arrayBuffer())
        const sha = createHash('sha256').update(bytes).digest('hex')
        if (sha !== issue.sha256) {
            // 【对不上就拒绝】一份与记录不符的"档案"比没有档案更坏 —— 它会被当成
            // "当时发出去的那份"读,而它不是。
            return new NextResponse('Stored document does not match its recorded digest', { status: 409 })
        }
        return new NextResponse(new Uint8Array(bytes), {
            headers: {
                'Content-Type': 'application/pdf',
                'Content-Disposition': `${asDownload ? 'attachment' : 'inline'}; ${contentDispositionFilename(
                    `${id}-v${version}.pdf`
                )}`,
                'Cache-Control': 'no-store',
            },
        })
    }

    const built = await buildInvoicePdf(id)
    if (!built.ok) return built.response

    return new NextResponse(new Uint8Array(built.buffer), {
        headers: {
            'Content-Type': 'application/pdf',
            'Content-Disposition': `${asDownload ? 'attachment' : 'inline'}; ${contentDispositionFilename(
                `${built.code}.pdf`
            )}`,
            'Cache-Control': 'no-store',
        },
    })
}

// 【POST = 签发】渲染 → 存桶 → 记档。四条按名拒(INVOICE_NOT_FOUND /
// INV_VOIDED_NOT_ISSUABLE / INV_NO_LINES / INV_PROFILE_INCOMPLETE)由
// record_invoice_issue 抛出,在这里【按名】翻译后原样交给客户端 —— 界面上不出现
// 机器串(AGENTS.md 那条 i18n 规矩:解析器把键当文案吐出来是三次事故的来源)。
export async function POST(_request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const denied = await requireBanking()
    if (denied) return denied
    try {
        const supabase = await createClient()
        const built = await buildInvoicePdf(id)
        if (!built.ok) return built.response
        const sha = createHash('sha256').update(built.buffer).digest('hex')
        // 对象键不含版本号 —— 版本由 record_invoice_issue 在数据库里裁决(并发安全,
        // 那把每单据一把的咨询锁)。同样的字节重发一次就落回同一个对象上。
        const path = `${id}/${sha}.pdf`
        const up = await supabase.storage.from(BUCKET).upload(path, built.buffer, {
            contentType: 'application/pdf', upsert: true,
        })
        if (up.error) return new NextResponse(`Upload failed: ${up.error.message}`, { status: 500 })

        const { data, error } = await supabase.rpc('record_invoice_issue', {
            p_invoice_id: id, p_file_path: path, p_sha256: sha,
        })
        if (error) return new NextResponse(await localizeInvoiceError(error.message), { status: 400 })
        return NextResponse.json(data)
    } catch (e) {
        return new NextResponse(`Issue failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}
