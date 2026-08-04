// app/finance/invoices/[id]/pdf/InvoiceDocument.tsx
// 发票 PDF 的文档定义(A4 纵向)。
//
// 【本文件内的所有文案一律硬编码为英文,且【不接 i18n】】—— 发票是寄给客户的单据,
// 既定决策是一律英文开具;界面语言切成中文时开出来的 PDF 也必须是英文。
// 这里出现的 'INVOICE'、'Bill To'、'Subtotal' 等都是【单据正文】,不是界面标签。
//
// 只在服务端渲染(route handler 里 renderToBuffer),不进浏览器包。
import React from 'react'
import path from 'node:path'
import fs from 'node:fs'
import { Document, Page, Text, View, Image, StyleSheet, Font } from '@react-pdf/renderer'

// ─────────────────────────────────────────────────────────────────────────────
// 字体
// ─────────────────────────────────────────────────────────────────────────────
// 内置的 Helvetica 【没有中文字形】—— 客户名或地址里只要有一个汉字,印出来就是空白。
// 所以整份文档改用内嵌的 Noto Sans SC(它同时含完整拉丁字母,英文发票的观感不变)。
//
// 【从仓库文件系统读,绝不从远程 URL 读】:react-pdf 支持给 src 传 URL,但那意味着
// 渲染过程中要发一次网络请求 —— 一旦超时或对端挂了,拿到的就是一份字体缺失的 PDF,
// 而且失败是静默的。这跟本目录 route.ts 里 logo 先下载再内嵌是同一个理由。
//
// 字体文件是【裁剪过的】(assets/fonts/subset.py):21 MB → 4.4 MB,代价是裁剪范围外
// 的字画不出来。所以渲染前必须过一遍 lib/invoiceFontCoverage.ts 的守卫,见 route.ts。
export const INVOICE_FONT_FAMILY = 'Noto Sans SC'

const FONT_DIR = path.join(process.cwd(), 'assets', 'fonts')
const FONT_FILES = [
    { file: 'NotoSansSC-Regular.subset.ttf', fontWeight: 'normal' as const },
    { file: 'NotoSansSC-Bold.subset.ttf', fontWeight: 'bold' as const },
]

// 缺文件就在【模块加载时】炸掉,而不是等到渲染时抛一个含糊的 fontkit 错误 ——
// 字体没装好属于部署事故,应该一眼看出来。
for (const { file } of FONT_FILES) {
    const p = path.join(FONT_DIR, file)
    if (!fs.existsSync(p)) {
        throw new Error(
            `发票字体缺失:${p}\n` +
                `请在 assets/fonts/ 下放好完整字重后运行 python3 assets/fonts/subset.py 生成裁剪版。`
        )
    }
}

Font.register({
    family: INVOICE_FONT_FAMILY,
    fonts: FONT_FILES.map(({ file, fontWeight }) => ({
        src: path.join(FONT_DIR, file),
        fontStyle: 'normal' as const,
        fontWeight,
    })),
})

// 排版引擎【只按空格切词】(textkit 的 wrapWords:split(/([ ]+)/)),而中文不写空格 ——
// 一整段中文地址会被当成一个不可断开的"词"。实测 69 个汉字的地址(9pt ≈ 621pt)在
// 515pt 的正文宽里【直接冲出页面右边缘被截掉】,后面十几个字整段消失。
//
// 所以对含中日韩字符的词逐字切开,让断行点能落在任意两个汉字之间;纯拉丁的词保持
// 整体,避免把英文单词拆散。
//
// 【已知缺陷】textkit 在断词点一律插一个连字符(breakLines 里对 penalty 节点
// insertGlyph(HYPHEN)),中文断行处因此会多出一个 "-":"…大楼北翼-/办公室…"。
// 中文排版上这是错的。但两害相权:多一个连字符 = 难看但信息完整;不切词 = 地址后半
// 截直接从纸面上消失,而且没人会发现 —— 后者正是本次改动通篇在防的那类静默丢字。
// 要彻底修好得绕开 textkit 的 hyphenation 回调(它没有"无连字符断点"这种节点),
// 属于另一件事。
const CJK = /[　-〿㐀-䶿一-鿿豈-﫿＀-￯]/
Font.registerHyphenationCallback((word) => (CJK.test(word) ? Array.from(word) : [word]))

export type CompanyProfile = {
    legal_name: string
    registration_no: string | null
    address_lines: string | null
    city: string | null
    postal_code: string | null
    country: string | null
    phone: string | null
    email: string | null
    website: string | null
    bank_name: string | null
    bank_account_name: string | null
    bank_account_no: string | null
    bank_swift: string | null
    bank_address: string | null
    invoice_footer_text: string | null
    // 路由用它去桶里取字节;文档组件本身只吃已内嵌的 data URI(logo 参数)
    logo_path: string | null
}

export type InvoiceData = {
    code: string
    issue_date: string
    due_date: string
    payment_terms_days: number
    currency: string
    subtotal_base: number
    tax_rate_pct: number
    tax_base: number
    total_base: number
    status: string
    notes: string | null
    terms_text: string | null
    // 快照:cut 2a 的发票里没有 contact_person/email/phone 三个键,渲染时按"有才画"处理
    bill_to: Record<string, string | null | undefined>
}

export type InvoiceLine = {
    line_no: number
    description: string
    quantity: number
    unit: string
    unit_price: number
    amount_base: number
}

const num = (n: number, dp = 2) =>
    new Intl.NumberFormat('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp }).format(n)

const styles = StyleSheet.create({
    // fontFamily 放在 page 上,页面内所有 Text 默认继承它 —— 任何一个文本节点都不该
    // 回落到没有中文字形的 Helvetica。下面凡是要加粗的地方一律用 fontWeight: 'bold'
    // (而不是 fontFamily: 'Helvetica-Bold'),否则等于把那个节点换回了拉丁字体。
    page: {
        paddingTop: 36,
        paddingBottom: 64,
        paddingHorizontal: 40,
        fontSize: 9,
        color: '#111827',
        fontFamily: INVOICE_FONT_FAMILY,
    },
    header: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 24 },
    logo: { height: 44, objectFit: 'contain' },
    companyBlock: { alignItems: 'flex-end', maxWidth: 240 },
    companyName: { fontSize: 11, fontWeight: 'bold', marginBottom: 2 },
    small: { fontSize: 8, color: '#4b5563', textAlign: 'right' },

    titleRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-end', marginBottom: 16 },
    title: { fontSize: 22, fontWeight: 'bold', letterSpacing: 2 },
    metaTable: { alignItems: 'flex-end' },
    metaRow: { flexDirection: 'row', marginBottom: 1 },
    metaLabel: { fontSize: 8, color: '#6b7280', width: 78, textAlign: 'right', marginRight: 8 },
    metaValue: { fontSize: 9, width: 90, textAlign: 'right' },

    billTo: { marginBottom: 18 },
    sectionHeading: { fontSize: 8, fontWeight: 'bold', color: '#6b7280', letterSpacing: 1, marginBottom: 4 },
    billName: { fontSize: 10, fontWeight: 'bold' },

    tableHeader: {
        flexDirection: 'row',
        borderBottomWidth: 1,
        borderBottomColor: '#111827',
        paddingBottom: 4,
        marginBottom: 2,
    },
    row: { flexDirection: 'row', paddingVertical: 4, borderBottomWidth: 0.5, borderBottomColor: '#e5e7eb' },
    thText: { fontSize: 8, fontWeight: 'bold', color: '#374151' },
    cNo: { width: 22 },
    cDesc: { flex: 1, paddingRight: 8 },
    cQty: { width: 82, textAlign: 'right' },
    cPrice: { width: 66, textAlign: 'right' },
    cAmt: { width: 74, textAlign: 'right' },

    totals: { marginTop: 12, alignItems: 'flex-end' },
    totalRow: { flexDirection: 'row', marginBottom: 2 },
    totalLabel: { fontSize: 9, color: '#4b5563', width: 110, textAlign: 'right', marginRight: 10 },
    totalValue: { fontSize: 9, width: 90, textAlign: 'right' },
    grandLabel: { fontSize: 10, fontWeight: 'bold', width: 110, textAlign: 'right', marginRight: 10 },
    grandValue: { fontSize: 10, fontWeight: 'bold', width: 90, textAlign: 'right' },
    grandRow: { flexDirection: 'row', marginTop: 3, paddingTop: 4, borderTopWidth: 1, borderTopColor: '#111827' },

    block: { marginTop: 20 },
    kvRow: { flexDirection: 'row', marginBottom: 1 },
    kvLabel: { fontSize: 8, color: '#6b7280', width: 92 },
    kvValue: { fontSize: 9 },

    footer: {
        position: 'absolute',
        bottom: 28,
        left: 40,
        right: 40,
        borderTopWidth: 0.5,
        borderTopColor: '#d1d5db',
        paddingTop: 6,
        flexDirection: 'row',
        justifyContent: 'space-between',
    },
    footerText: { fontSize: 7.5, color: '#6b7280', flex: 1, paddingRight: 12 },
    pageNo: { fontSize: 7.5, color: '#6b7280' },

    voidBanner: {
        position: 'absolute',
        top: 300,
        left: 60,
        right: 60,
        borderWidth: 3,
        borderColor: '#dc2626',
        paddingVertical: 14,
        alignItems: 'center',
        opacity: 0.55,
    },
    voidText: { fontSize: 40, fontWeight: 'bold', color: '#dc2626', letterSpacing: 8 },
})

// 只画有值的行
function KV({ label, value }: { label: string; value?: string | null }) {
    if (!value) return null
    return (
        <View style={styles.kvRow}>
            <Text style={styles.kvLabel}>{label}</Text>
            <Text style={styles.kvValue}>{value}</Text>
        </View>
    )
}

export default function InvoiceDocument({
    invoice,
    lines,
    company,
    gstRegistrationNo,
    logo,
}: {
    invoice: InvoiceData
    lines: InvoiceLine[]
    company: CompanyProfile
    // GST 登记号来自 finance_settings(不在 company_profile 里,见该表注释)
    gstRegistrationNo: string | null
    logo: string | null // data URI,服务端下载后内嵌
}) {
    const b = invoice.bill_to ?? {}
    const cityLine = [company.city, company.postal_code].filter(Boolean).join(' ')
    const isVoid = invoice.status === 'void'

    const hasBank =
        company.bank_name ||
        company.bank_account_name ||
        company.bank_account_no ||
        company.bank_swift ||
        company.bank_address

    return (
        <Document title={invoice.code}>
            <Page size="A4" style={styles.page}>
                {/* 抬头:左 logo,右公司信息 */}
                <View style={styles.header} fixed>
                    <View>{logo ? <Image src={logo} style={styles.logo} /> : null}</View>
                    <View style={styles.companyBlock}>
                        <Text style={styles.companyName}>{company.legal_name}</Text>
                        {company.address_lines
                            ? company.address_lines
                                  .split('\n')
                                  .filter((l) => l.trim())
                                  .map((l, i) => (
                                      <Text key={i} style={styles.small}>
                                          {l}
                                      </Text>
                                  ))
                            : null}
                        {cityLine ? <Text style={styles.small}>{cityLine}</Text> : null}
                        {company.country ? <Text style={styles.small}>{company.country}</Text> : null}
                        {company.registration_no ? (
                            <Text style={styles.small}>Co. Reg. No: {company.registration_no}</Text>
                        ) : null}
                        {gstRegistrationNo ? (
                            <Text style={styles.small}>GST Reg. No: {gstRegistrationNo}</Text>
                        ) : null}
                        {company.phone ? <Text style={styles.small}>Tel: {company.phone}</Text> : null}
                        {company.email ? <Text style={styles.small}>{company.email}</Text> : null}
                        {company.website ? <Text style={styles.small}>{company.website}</Text> : null}
                    </View>
                </View>

                {/* 标题 + 单据信息 */}
                <View style={styles.titleRow}>
                    <Text style={styles.title}>INVOICE</Text>
                    <View style={styles.metaTable}>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>Invoice No.</Text>
                            <Text style={styles.metaValue}>{invoice.code}</Text>
                        </View>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>Issue date</Text>
                            <Text style={styles.metaValue}>{invoice.issue_date}</Text>
                        </View>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>Due date</Text>
                            <Text style={styles.metaValue}>{invoice.due_date}</Text>
                        </View>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>Payment terms</Text>
                            <Text style={styles.metaValue}>{invoice.payment_terms_days} days</Text>
                        </View>
                    </View>
                </View>

                {/* 客户抬头(开票当刻的快照;老发票没有联系人字段,按有才画)*/}
                <View style={styles.billTo}>
                    <Text style={styles.sectionHeading}>BILL TO</Text>
                    <Text style={styles.billName}>{b.legal_name || '—'}</Text>
                    {b.code ? <Text style={styles.small}>{b.code}</Text> : null}
                    {b.address
                        ? String(b.address)
                              .split('\n')
                              .filter((l) => l.trim())
                              .map((l, i) => (
                                  <Text key={i} style={{ fontSize: 9 }}>
                                      {l}
                                  </Text>
                              ))
                        : null}
                    {b.country ? <Text style={{ fontSize: 9 }}>{b.country}</Text> : null}
                    {b.tax_id ? <Text style={{ fontSize: 9 }}>Tax ID: {b.tax_id}</Text> : null}
                    {b.contact_person ? <Text style={{ fontSize: 9 }}>Attn: {b.contact_person}</Text> : null}
                    {b.email ? <Text style={{ fontSize: 9 }}>{b.email}</Text> : null}
                </View>

                {/* 明细表(表头跨页重复)*/}
                <View style={styles.tableHeader} fixed>
                    <Text style={[styles.thText, styles.cNo]}>#</Text>
                    <Text style={[styles.thText, styles.cDesc]}>Description</Text>
                    <Text style={[styles.thText, styles.cQty]}>Quantity</Text>
                    <Text style={[styles.thText, styles.cPrice]}>Unit price</Text>
                    <Text style={[styles.thText, styles.cAmt]}>Amount</Text>
                </View>
                {lines.map((l) => (
                    <View key={l.line_no} style={styles.row} wrap={false}>
                        <Text style={styles.cNo}>{l.line_no}</Text>
                        <Text style={styles.cDesc}>{l.description}</Text>
                        <Text style={styles.cQty}>
                            {num(l.quantity, 2)} {l.unit}
                        </Text>
                        <Text style={styles.cPrice}>{num(l.unit_price)}</Text>
                        <Text style={styles.cAmt}>{num(l.amount_base)}</Text>
                    </View>
                ))}

                {/* 合计 */}
                <View style={styles.totals}>
                    <View style={styles.totalRow}>
                        <Text style={styles.totalLabel}>Subtotal</Text>
                        <Text style={styles.totalValue}>{num(invoice.subtotal_base)}</Text>
                    </View>
                    {/* 未做 GST 登记时【整行不出现】—— 不给一家没登记的公司打印 "GST 0.00" */}
                    {Number(invoice.tax_base) !== 0 ? (
                        <View style={styles.totalRow}>
                            <Text style={styles.totalLabel}>GST ({num(invoice.tax_rate_pct, 0)}%)</Text>
                            <Text style={styles.totalValue}>{num(invoice.tax_base)}</Text>
                        </View>
                    ) : null}
                    <View style={styles.grandRow}>
                        <Text style={styles.grandLabel}>Total ({invoice.currency})</Text>
                        <Text style={styles.grandValue}>{num(invoice.total_base)}</Text>
                    </View>
                </View>

                {/* 收款账户 */}
                {hasBank ? (
                    <View style={styles.block}>
                        <Text style={styles.sectionHeading}>PAYMENT DETAILS</Text>
                        <KV label="Bank" value={company.bank_name} />
                        <KV label="Account name" value={company.bank_account_name} />
                        <KV label="Account no." value={company.bank_account_no} />
                        <KV label="SWIFT" value={company.bank_swift} />
                        <KV label="Bank address" value={company.bank_address} />
                    </View>
                ) : null}

                {/* 条款 / 备注(单据数据,原样打印)*/}
                {invoice.terms_text ? (
                    <View style={styles.block}>
                        <Text style={styles.sectionHeading}>TERMS</Text>
                        <Text style={{ fontSize: 9 }}>{invoice.terms_text}</Text>
                    </View>
                ) : null}
                {invoice.notes ? (
                    <View style={{ marginTop: 10 }}>
                        <Text style={styles.sectionHeading}>NOTES</Text>
                        <Text style={{ fontSize: 9 }}>{invoice.notes}</Text>
                    </View>
                ) : null}

                {/* 作废横幅 */}
                {isVoid ? (
                    <View style={styles.voidBanner} fixed>
                        <Text style={styles.voidText}>VOID</Text>
                    </View>
                ) : null}

                {/* 页脚:每页都有 */}
                <View style={styles.footer} fixed>
                    <Text style={styles.footerText}>{company.invoice_footer_text ?? ''}</Text>
                    <Text
                        style={styles.pageNo}
                        render={({ pageNumber, totalPages }) => `Page ${pageNumber} of ${totalPages}`}
                    />
                </View>
            </Page>
        </Document>
    )
}
