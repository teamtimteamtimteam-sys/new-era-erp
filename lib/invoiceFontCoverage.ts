// lib/invoiceFontCoverage.ts
// 发票 PDF 的字形覆盖守卫。
//
// 【为什么需要这个】发票 PDF 内嵌的是【裁剪过】的 Noto Sans SC(见 assets/fonts/subset.py):
// 拉丁字母 + GB2312 一级二级汉字 + 几段标点,一共 7276 个码位。裁剪把 21 MB 压到了
// 4.4 MB,代价是:【裁剪范围外的字会被静默地画成空白或豆腐块】。
//
// 一份寄给客户的单据上出现空白是真实事故 —— 客户名少了一个字、地址缺一块,没人会
// 发现,因为 PDF 生成"成功"了。所以渲染之前先把这份文档要印的【每一个字符串】过一遍,
// 有印不出来的字就【拒绝出 PDF】(409 + 明确指出是哪几个字、出现在哪),而不是出一份
// 有洞的 PDF。这跟 route 里"公司抬头没填就不出 PDF"是同一个思路。
//
// 【为什么查清单而不是在运行时读字体的 cmap】
// coverage.json 是 subset.py 在裁剪字体的【同一次运行】里、从裁剪结果的 cmap 反读出来
// 的,所以清单和 .subset.ttf 不可能对不上(不是两个各自维护的东西)。运行时查清单
// 的好处:不用在每次请求里解析 2 MB 字体、不依赖 fontkit 的内部 API、冷启动没有额外
// I/O —— JSON 在打包时就被内联进产物了。用 fontkit 在运行时读嵌入字体也能做到"反映
// 真实字节",但那要在每次校验时把字体解析一遍,而它换来的额外保证已经被"同一次运行
// 产出"这一点覆盖掉了。
//
// 【要扩大覆盖范围】改 assets/fonts/subset.py 里的 UNICODE_RANGES(或 GB2312 那段),
// 重跑该脚本 —— .subset.ttf 和 coverage.json 会一起更新,这里不用改任何代码。
import coverage from '@/assets/fonts/coverage.json'

// [起点, 终点] 闭区间,按起点升序 —— subset.py 保证有序,这里直接二分
const RANGES = coverage.ranges as [number, number][]

export const FONT_COVERAGE_SUMMARY = {
    family: coverage.family,
    codepointCount: coverage.codepointCount,
}

/** 该码位在内嵌字体里有没有字形。 */
export function isCovered(cp: number): boolean {
    // 空白和控制字符由排版引擎处理,本来就不在 cmap 里,不能当成"印不出来"
    if (cp <= 0x20 || cp === 0x7f) return true
    let lo = 0
    let hi = RANGES.length - 1
    while (lo <= hi) {
        const mid = (lo + hi) >> 1
        const [start, end] = RANGES[mid]
        if (cp < start) hi = mid - 1
        else if (cp > end) lo = mid + 1
        else return true
    }
    return false
}

/** 文档里的一段文字,连同它出现的位置(位置要能让人直接找到那个字段)。 */
export type PdfTextField = { where: string; text: string | null | undefined }

/** 某个位置上印不出来的字符(已去重、保持出现顺序)。 */
export type CoverageProblem = { where: string; chars: string[] }

// PDF 里【硬编码的英文文案】—— 表头、栏目标题、'VOID'、'Page N of M' 之类。
// 它们全是 ASCII,理论上必然覆盖,但还是照样过一遍:守卫的价值在于"没有未经检查
// 的字符串",而不在于"我们相信这些应该没问题"。
const STATIC_CHROME = [
    'INVOICE',
    'Invoice No.',
    'Issue date',
    'Due date',
    'Payment terms',
    'days',
    'BILL TO',
    'Tax ID:',
    'Attn:',
    'Co. Reg. No:',
    'GST Reg. No:',
    'Tel:',
    '#',
    'Description',
    'Quantity',
    'Unit price',
    'Amount',
    'Subtotal',
    'GST',
    'Total',
    'PAYMENT DETAILS',
    'Bank',
    'Account name',
    'Account no.',
    'SWIFT',
    'Bank address',
    'TERMS',
    'NOTES',
    'VOID',
    'Page 1 of 1',
    '—', // 空值占位符(U+2014)
].join(' ')

// 与 InvoiceDocument 里的 num() 一致 —— 校验的必须是【真正会被印出去的那串字符】,
// 不是原始数字。千分位逗号和小数点都来自这里。
const num = (n: number, dp = 2) =>
    new Intl.NumberFormat('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp }).format(n)

/** 校验用的输入 —— 和 InvoiceDocument 的 props 同形,免得两边漂移。 */
export type InvoicePdfContent = {
    invoice: {
        code: string
        issue_date: string
        due_date: string
        payment_terms_days: number
        currency: string
        subtotal_base: number
        tax_rate_pct: number
        tax_base: number
        total_base: number
        notes: string | null
        terms_text: string | null
        bill_to: Record<string, string | null | undefined>
    }
    lines: {
        line_no: number
        description: string
        quantity: number
        unit: string
        unit_price: number
        amount_base: number
    }[]
    company: Record<string, unknown> & { legal_name: string }
    gstRegistrationNo: string | null
}

/**
 * 把这份文档【会印出去的每一个字符串】收集起来。
 *
 * 顺序和 InvoiceDocument 的渲染顺序一致,这样报错里的位置读起来就是"从上往下"的。
 * 新增任何会印到 PDF 上的字段时,记得同步加到这里 —— 漏掉的字段就是漏掉的守卫。
 */
export function collectInvoicePdfStrings(content: InvoicePdfContent): PdfTextField[] {
    const { invoice, lines, company, gstRegistrationNo } = content
    const b = invoice.bill_to ?? {}
    const str = (v: unknown) => (typeof v === 'string' ? v : v == null ? null : String(v))

    const fields: PdfTextField[] = [{ where: 'Invoice template text', text: STATIC_CHROME }]

    // 抬头 / 公司信息
    fields.push(
        { where: 'Company legal name', text: str(company.legal_name) },
        { where: 'Company address', text: str(company.address_lines) },
        { where: 'Company city', text: str(company.city) },
        { where: 'Company postal code', text: str(company.postal_code) },
        { where: 'Company country', text: str(company.country) },
        { where: 'Company registration no.', text: str(company.registration_no) },
        { where: 'GST registration no.', text: gstRegistrationNo },
        { where: 'Company phone', text: str(company.phone) },
        { where: 'Company email', text: str(company.email) },
        { where: 'Company website', text: str(company.website) },
    )

    // 单据信息
    fields.push(
        { where: 'Invoice code', text: invoice.code },
        { where: 'Issue date', text: invoice.issue_date },
        { where: 'Due date', text: invoice.due_date },
        { where: 'Payment terms', text: `${invoice.payment_terms_days} days` },
        { where: 'Currency', text: invoice.currency },
    )

    // 客户抬头快照
    fields.push(
        { where: 'Customer name', text: str(b.legal_name) },
        { where: 'Customer code', text: str(b.code) },
        { where: 'Customer address', text: str(b.address) },
        { where: 'Customer country', text: str(b.country) },
        { where: 'Customer tax ID', text: str(b.tax_id) },
        { where: 'Customer contact person', text: str(b.contact_person) },
        { where: 'Customer email', text: str(b.email) },
    )

    // 明细行
    for (const l of lines) {
        fields.push(
            { where: `Line ${l.line_no} description`, text: l.description },
            { where: `Line ${l.line_no} quantity`, text: `${num(l.quantity, 2)} ${l.unit}` },
            { where: `Line ${l.line_no} unit price`, text: num(l.unit_price) },
            { where: `Line ${l.line_no} amount`, text: num(l.amount_base) },
        )
    }

    // 合计
    fields.push(
        { where: 'Subtotal', text: num(invoice.subtotal_base) },
        { where: 'GST amount', text: num(invoice.tax_base) },
        { where: 'GST rate', text: num(invoice.tax_rate_pct, 0) },
        { where: 'Total', text: num(invoice.total_base) },
    )

    // 收款账户
    fields.push(
        { where: 'Bank name', text: str(company.bank_name) },
        { where: 'Bank account name', text: str(company.bank_account_name) },
        { where: 'Bank account no.', text: str(company.bank_account_no) },
        { where: 'Bank SWIFT', text: str(company.bank_swift) },
        { where: 'Bank address', text: str(company.bank_address) },
    )

    // 条款 / 备注 / 页脚
    fields.push(
        { where: 'Terms', text: invoice.terms_text },
        { where: 'Notes', text: invoice.notes },
        { where: 'Invoice footer text', text: str(company.invoice_footer_text) },
    )

    return fields
}

/** 逐字段找出内嵌字体印不出来的字符。没有问题就返回空数组。 */
export function findUnrenderableText(fields: PdfTextField[]): CoverageProblem[] {
    const problems: CoverageProblem[] = []
    for (const { where, text } of fields) {
        if (!text) continue
        const bad: string[] = []
        const seen = new Set<string>()
        // 按【码位】遍历(不是 UTF-16 码元)—— 扩展区的生僻字是代理对,
        // 按码元遍历会把一个字拆成两半、报出两个乱码
        for (const ch of text) {
            const cp = ch.codePointAt(0)!
            if (isCovered(cp) || seen.has(ch)) continue
            seen.add(ch)
            bad.push(ch)
        }
        if (bad.length) problems.push({ where, chars: bad })
    }
    return problems
}

/** 一步到位:内容 → 问题列表。 */
export function checkInvoicePdfCoverage(content: InvoicePdfContent): CoverageProblem[] {
    return findUnrenderableText(collectInvoicePdfStrings(content))
}

/** 每个问题一行,形如:Line 1 description contains characters the invoice font cannot render: 堃, 玥 */
export function describeCoverageProblems(problems: CoverageProblem[]): string[] {
    return problems.map(
        (p) => `${p.where} contains characters the invoice font cannot render: ${p.chars.join(', ')}`
    )
}

/** 409 响应体(纯文本)。面向的是要把这份单据寄出去的人,所以要说清楚"接下来怎么办"。 */
export function coverageErrorMessage(problems: CoverageProblem[]): string {
    return (
        `This invoice cannot be turned into a PDF.\n\n` +
        describeCoverageProblems(problems)
            .map((l) => `  ${l}`)
            .join('\n') +
        `\n\n` +
        `The embedded invoice font covers Latin text plus ${FONT_COVERAGE_SUMMARY.codepointCount} ` +
        `characters (GB2312 Simplified Chinese and common punctuation). Rendering anyway would ` +
        `print those characters as blanks on a document that goes to a customer, so no PDF was produced.\n\n` +
        `Either replace the characters above, or widen the font's coverage by editing the ranges in\n` +
        `assets/fonts/subset.py and re-running it.\n`
    )
}
