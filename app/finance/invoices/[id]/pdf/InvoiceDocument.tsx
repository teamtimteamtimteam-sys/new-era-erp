// app/finance/invoices/[id]/pdf/InvoiceDocument.tsx
// 发票 PDF 的文档定义(A4 纵向)。
//
// 【本文件内的所有文案一律硬编码为英文,且【不接 i18n】】—— 发票是寄给客户的单据,
// 既定决策是一律英文开具;界面语言切成中文时开出来的 PDF 也必须是英文。
// 这里出现的 'INVOICE'、'Bill To'、'Subtotal' 等都是【单据正文】,不是界面标签。
//
// 只在服务端渲染(route handler 里 renderToBuffer),不进浏览器包。
import React from 'react'
import { Document, Page, Text, View, StyleSheet } from '@react-pdf/renderer'

// ── 字体 ─────────────────────────────────────────────────────────────────────
// PDF-1:注册搬到 app/components/pdf/fonts.ts —— 【八份对外单据一处注册,一个字体栈】。
//
// ★【为什么搬走】★ 它此前住在这个文件里,靠"import 发票文档就完成注册"这个
// 模块副作用传播给另外五份文档。那让"这份文档嵌了哪些字体"变成一件要靠读 import
// 才知道的事 —— 而对账单正是在这件事上写成了 Helvetica,把中文印成了乱码,
// 并且【骗过了字体覆盖守卫】。详见 fonts.ts 与 StatementDocument.tsx 的抬头。
//
// 现在:拉丁与数字用 Google Sans,中文用 Noto Sans SC,**按字符选**(R2)。
// 加粗一律 fontWeight:'bold' —— 两个家族都注册了 400 与 700。
import { DOC_FONT_STACK } from '@/app/components/pdf/fonts'
import { BRAND } from '@/app/components/pdf/theme'
import { DocumentLetterhead, DocumentFooter, NoSignatureNote } from '@/app/components/pdf/DocumentChrome'
import { noSignatureEn } from '@/app/components/pdf/noSignature'

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
    // PDF-1 起对外单据不再印它(见下面渲染处那段 ★);字段仍在,/finance/company 用得到
    logo_path: string | null
}

export type InvoiceData = {
    code: string
    issue_date: string
    due_date: string
    payment_terms_days: number
    currency: string
    tax_rate_pct: number
    // INV-1:客户账单印的是【单据币种】的数(invoice_document_totals)。
    // *_base 是本位币,给账用的 —— 这份文档【一个都不印】,免得再有人拿
    // currency 去标它们(已发出的两张就是这么各多报了 1,440 / 336 USD)。
    subtotal_ccy: number
    tax_ccy: number
    total_ccy: number
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
    // 单据币种的行金额 = quantity × unit_price(不经汇率)——
    // 与 unit_price 同币种,所以这一行自己对得上账
    amount_ccy: number
}

const num = (n: number, dp = 2) =>
    new Intl.NumberFormat('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp }).format(n)

const styles = StyleSheet.create({
    // fontFamily 放在 page 上,页内所有 Text 默认继承整个【字体栈】—— 任何一个文本
    // 节点都不该自己写 fontFamily。加粗一律 fontWeight:'bold';写 'Helvetica-Bold'
    // 等于把那个节点换回一个没有中文字形的拉丁字体(对账单栽过,现在构建期就会红)。
    page: {
        paddingTop: 36,
        paddingBottom: 64,
        paddingHorizontal: 40,
        fontSize: 9,
        color: BRAND.text,
        fontFamily: DOC_FONT_STACK,
    },
    header: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 24 },
    companyBlock: { alignItems: 'flex-end', maxWidth: 240 },
    companyName: { fontSize: 11, fontWeight: 'bold', marginBottom: 2 },
    small: { fontSize: 8, color: BRAND.muted, textAlign: 'right' },

    titleRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-end', marginBottom: 16 },
    title: { fontSize: 22, fontWeight: 'bold', letterSpacing: 2 },
    metaTable: { alignItems: 'flex-end' },
    metaRow: { flexDirection: 'row', marginBottom: 1 },
    metaLabel: { fontSize: 8, color: BRAND.muted, width: 78, textAlign: 'right', marginRight: 8 },
    metaValue: { fontSize: 9, width: 90, textAlign: 'right' },

    billTo: { marginBottom: 18 },
    sectionHeading: { fontSize: 8, fontWeight: 'bold', color: BRAND.muted, letterSpacing: 1, marginBottom: 4 },
    billName: { fontSize: 10, fontWeight: 'bold' },

    // 表头与另外七份同一个样子:accent 底 + Ocean 分隔线(见 DocumentChrome.docStyles)
    tableHeader: {
        flexDirection: 'row',
        backgroundColor: BRAND.accent,
        borderBottomWidth: 1,
        borderBottomColor: BRAND.ocean,
        paddingVertical: 4,
        paddingHorizontal: 2,
        marginBottom: 2,
    },
    row: { flexDirection: 'row', paddingVertical: 4, borderBottomWidth: 0.5, borderBottomColor: BRAND.hairline },
    thText: { fontSize: 8, fontWeight: 'bold', color: BRAND.muted },
    cNo: { width: 22 },
    cDesc: { flex: 1, paddingRight: 8 },
    cQty: { width: 82, textAlign: 'right' },
    cPrice: { width: 66, textAlign: 'right' },
    cAmt: { width: 74, textAlign: 'right' },

    totals: { marginTop: 12, alignItems: 'flex-end' },
    totalRow: { flexDirection: 'row', marginBottom: 2 },
    totalLabel: { fontSize: 9, color: BRAND.muted, width: 110, textAlign: 'right', marginRight: 10 },
    totalValue: { fontSize: 9, width: 90, textAlign: 'right' },
    grandLabel: { fontSize: 10, fontWeight: 'bold', width: 110, textAlign: 'right', marginRight: 10 },
    grandValue: { fontSize: 10, fontWeight: 'bold', width: 90, textAlign: 'right' },
    grandRow: { flexDirection: 'row', marginTop: 3, paddingTop: 4, borderTopWidth: 1, borderTopColor: BRAND.text },

    block: { marginTop: 20 },
    kvRow: { flexDirection: 'row', marginBottom: 1 },
    kvLabel: { fontSize: 8, color: BRAND.muted, width: 92 },
    kvValue: { fontSize: 9 },

    footer: {
        position: 'absolute',
        bottom: 28,
        left: 40,
        right: 40,
        borderTopWidth: 0.5,
        borderTopColor: BRAND.hairline,
        paddingTop: 6,
        flexDirection: 'row',
        justifyContent: 'space-between',
    },
    footerText: { fontSize: 7.5, color: BRAND.muted, flex: 1, paddingRight: 12 },
    pageNo: { fontSize: 7.5, color: BRAND.muted },

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
}: {
    invoice: InvoiceData
    lines: InvoiceLine[]
    company: CompanyProfile
    // GST 登记号来自 finance_settings(不在 company_profile 里,见该表注释)
    gstRegistrationNo: string | null
}) {
    const b = invoice.bill_to ?? {}
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
                {/* 抬头:左字标,右公司信息 —— PDF-1 起由共享层给,八份单据同一份实现。 */}
                <View fixed>
                    <DocumentLetterhead company={company} gstRegistrationNo={gstRegistrationNo} />
                </View>
                {/* ★【上传的 logo 不再印在这张纸上 —— 它与字标是【同一个标记】】★
                    (PDF-1,2026-09-02。实测发现,不是推断:before 渲染里两个一起出现。)
                    company_profile.logo_path 今天存的就是 EVoltrya 字标的一张【单色
                    位图】。加上共享抬头的矢量字标之后,同一个标记在一张纸上印了两遍,
                    而位图那一份还更大、居中、把版面顶开了。
                    R1 点名字标是 public/brand/evoltrya-wordmark.svg —— 所以留矢量那一份:
                    它是品牌指南里的颜色(Ocean + Forest),放大不糊,且只有一处真源。
                    【logo_path 这个字段没有被删】/finance/company 仍然可以上传与显示它;
                    变的只是【对外单据不再印它】。哪天真要在单据上印一个与字标不同的
                    标记,那是一个新决定,应当带着它自己的理由回来。 */}

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
                    <Text style={[styles.thText, styles.cPrice]}>Unit price ({invoice.currency})</Text>
                    <Text style={[styles.thText, styles.cAmt]}>Amount ({invoice.currency})</Text>
                </View>
                {lines.map((l) => (
                    <View key={l.line_no} style={styles.row} wrap={false}>
                        <Text style={styles.cNo}>{l.line_no}</Text>
                        <Text style={styles.cDesc}>{l.description}</Text>
                        <Text style={styles.cQty}>
                            {num(l.quantity, 2)} {l.unit}
                        </Text>
                        <Text style={styles.cPrice}>{num(l.unit_price)}</Text>
                        <Text style={styles.cAmt}>{num(l.amount_ccy)}</Text>
                    </View>
                ))}

                {/* 合计 */}
                <View style={styles.totals}>
                    <View style={styles.totalRow}>
                        <Text style={styles.totalLabel}>Subtotal</Text>
                        <Text style={styles.totalValue}>{num(invoice.subtotal_ccy)}</Text>
                    </View>
                    {/* 未做 GST 登记时【整行不出现】—— 不给一家没登记的公司打印 "GST 0.00" */}
                    {Number(invoice.tax_ccy) !== 0 ? (
                        <View style={styles.totalRow}>
                            <Text style={styles.totalLabel}>GST ({num(invoice.tax_rate_pct, 0)}%)</Text>
                            <Text style={styles.totalValue}>{num(invoice.tax_ccy)}</Text>
                        </View>
                    ) : null}
                    <View style={styles.grandRow}>
                        <Text style={styles.grandLabel}>Total ({invoice.currency})</Text>
                        <Text style={styles.grandValue}>{num(invoice.total_ccy)}</Text>
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

                <NoSignatureNote text={noSignatureEn('invoice')} />

                {/* 页脚:每页都有 —— PDF-1 起由共享层给。措辞与页码格式
                    (`Page N of M`)与此前逐字相同。 */}
                <DocumentFooter note={company.invoice_footer_text ?? ''} />
            </Page>
        </Document>
    )
}
