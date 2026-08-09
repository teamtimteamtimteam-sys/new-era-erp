// app/purchasing/orders/[id]/pdf/PurchaseOrderDocument.tsx
// 采购单 PDF(A4 纵向)。规格:docs/purchase-order-document.md。
//
// 【文案一律硬编码英文,不接 i18n】—— 与发票同一条既定决策:这是发给供应商的单据
// 正文,不是界面标签。界面语言切成中文时签发的 PDF 也必须是英文。
//
// 【字体、CJK 断词、样式基调全部来自发票文档】—— import 那个模块就完成了字体注册与
// 断词回调(模块级副作用,见 InvoiceDocument.tsx 抬头)。这里不重复注册。
//
// 【单据币种,只有单据币种】(§D)po_document_data 里根本没有 fx_rate 与本位币数字,
// 所以本组件想印也印不出来 —— 这是把约束放在数据层而不是靠组件自律。
import React from 'react'
import { Document, Page, Text, View, Image, StyleSheet } from '@react-pdf/renderer'
import { INVOICE_FONT_FAMILY, type CompanyProfile } from '@/app/finance/invoices/[id]/pdf/InvoiceDocument'

export type PoCommittedTerms = {
    source_formula_code: string
    source_formula_name: string | null
    price_basis: string
    average_days: number | null
    treatment_charge_usd_per_tonne: number
    flat_discount_pct: number
    metals: { metal: string; payable_pct: number }[]
}

export type PoDocLine = {
    line_no: number
    material_name: string
    quantity: number
    unit: string
    unit_price: number | null
    amount_ccy: number
    expected_assay: Record<string, unknown> | null
    notes: string | null
    price_is_manual_estimate: boolean
    pricing_status: 'provisional_committed' | 'provisional_uncommitted' | 'fixed' | 'not_priced'
    committed_terms: PoCommittedTerms | null
}

export type PoDocData = {
    code: string
    order_date: string
    expected_delivery_date: string | null
    currency: string
    incoterm: string | null
    terms_text: string | null
    notes: string | null
    estimated_total_ccy: number
    supplier: { legal_name: string; address: string | null; country: string | null; tax_id: string | null }
    lines: PoDocLine[]
    payment_terms: {
        seq: number
        label: string
        percentage: number | null
        fixed_amount_ccy: number | null
        trigger_event: string | null
        due_date: string | null
        notes: string | null
    }[]
}

const num = (n: number, dp = 2) =>
    new Intl.NumberFormat('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp }).format(n)

// 每一行"定价状态"要印的那句话 —— 与 po_document_data 的裁决一一对应(§B)。
// 【provisional_uncommitted 不印条款】:公式今天的条款不是当时的承诺,印上去是编造。
export function pricingStatusText(line: PoDocLine): string[] {
    switch (line.pricing_status) {
        case 'fixed':
            return ['Price: FIXED']
        case 'not_priced':
            return ['Price: NOT STATED']
        case 'provisional_uncommitted':
            return ['Price: PROVISIONAL — terms not committed; settlement to be agreed separately']
        case 'provisional_committed': {
            const t = line.committed_terms as PoCommittedTerms
            const basis =
                t.price_basis === 'average'
                    ? `${t.average_days}-day average market price`
                    : 'spot market price'
            const metals = t.metals
                .map((m) => `${m.metal.toUpperCase()} ${num(m.payable_pct, 1)}%`)
                .join(', ')
            const out = [
                'Price: PROVISIONAL — PENDING ASSAY',
            ]
            if (line.price_is_manual_estimate) {
                // FIN-26 的那次误读:数字是手填的估算,结算规则是公式 —— 两件事都要说
                out.push('Unit price shown is a manual estimate; settlement follows the committed terms below.')
            }
            out.push(
                `Settles on formula ${t.source_formula_code}${t.source_formula_name ? ` (${t.source_formula_name})` : ''}: ` +
                    `payable ${metals}; ${basis}; ` +
                    // USD/t 是金属市场报价惯例(AGENTS.md FX 规则),不是本位币假设
                    `treatment charge ${num(t.treatment_charge_usd_per_tonne)} USD/t` +
                    (t.flat_discount_pct > 0 ? `; discount ${num(t.flat_discount_pct, 1)}%` : '')
            )
            return out
        }
    }
}

const styles = StyleSheet.create({
    page: {
        paddingTop: 36,
        paddingBottom: 56,
        paddingHorizontal: 40,
        fontSize: 9,
        color: '#111827',
        fontFamily: INVOICE_FONT_FAMILY,
    },
    headerRow: { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 18 },
    logo: { maxWidth: 140, maxHeight: 48, objectFit: 'contain' },
    companyName: { fontSize: 12, fontWeight: 'bold' },
    muted: { color: '#6b7280' },
    title: { fontSize: 18, fontWeight: 'bold', textAlign: 'right' },
    section: { marginBottom: 12 },
    sectionTitle: { fontSize: 8, fontWeight: 'bold', color: '#6b7280', marginBottom: 3, textTransform: 'uppercase' },
    row: { flexDirection: 'row' },
    metaBox: { flexDirection: 'row', gap: 24, marginBottom: 12 },
    table: { borderTopWidth: 1, borderColor: '#d1d5db' },
    th: { fontWeight: 'bold', paddingVertical: 4 },
    tr: { flexDirection: 'row', borderBottomWidth: 0.5, borderColor: '#e5e7eb', paddingVertical: 4 },
    cNo: { width: '6%' },
    cDesc: { width: '46%', paddingRight: 6 },
    cQty: { width: '14%', textAlign: 'right' },
    cPrice: { width: '16%', textAlign: 'right' },
    cAmt: { width: '18%', textAlign: 'right' },
    statusLine: { color: '#374151', fontSize: 8, marginTop: 2 },
    totalRow: { flexDirection: 'row', justifyContent: 'flex-end', marginTop: 8 },
    totalLabel: { fontWeight: 'bold', marginRight: 12 },
    footer: {
        position: 'absolute', bottom: 28, left: 40, right: 40,
        fontSize: 7.5, color: '#9ca3af', textAlign: 'center',
        borderTopWidth: 0.5, borderColor: '#e5e7eb', paddingTop: 6,
    },
})

export default function PurchaseOrderDocument({
    data,
    company,
    logo,
}: {
    data: PoDocData
    company: CompanyProfile
    logo: string | null
}) {
    const addr = [company.address_lines, company.city, company.postal_code, company.country]
        .filter(Boolean)
        .join(', ')
    return (
        <Document title={`Purchase Order ${data.code}`}>
            <Page size="A4" style={styles.page}>
                <View style={styles.headerRow}>
                    <View>
                        {logo ? <Image src={logo} style={styles.logo} /> : null}
                        <Text style={styles.companyName}>{company.legal_name}</Text>
                        {company.registration_no ? (
                            <Text style={styles.muted}>Reg. No. {company.registration_no}</Text>
                        ) : null}
                        {addr ? <Text style={styles.muted}>{addr}</Text> : null}
                        {company.phone ? <Text style={styles.muted}>{company.phone}</Text> : null}
                        {company.email ? <Text style={styles.muted}>{company.email}</Text> : null}
                    </View>
                    <View>
                        <Text style={styles.title}>PURCHASE ORDER</Text>
                        <Text style={{ textAlign: 'right' }}>{data.code}</Text>
                        <Text style={{ textAlign: 'right' }}>Date: {data.order_date}</Text>
                    </View>
                </View>

                <View style={styles.section}>
                    <Text style={styles.sectionTitle}>Supplier</Text>
                    <Text style={{ fontWeight: 'bold' }}>{data.supplier.legal_name}</Text>
                    {data.supplier.address ? <Text>{data.supplier.address}</Text> : null}
                    {data.supplier.country ? <Text>{data.supplier.country}</Text> : null}
                    {data.supplier.tax_id ? <Text>Tax ID: {data.supplier.tax_id}</Text> : null}
                </View>

                <View style={styles.metaBox}>
                    <View>
                        <Text style={styles.sectionTitle}>Expected delivery</Text>
                        <Text>{data.expected_delivery_date ?? '—'}</Text>
                    </View>
                    <View>
                        <Text style={styles.sectionTitle}>Incoterm</Text>
                        <Text>{data.incoterm ?? '—'}</Text>
                    </View>
                    <View>
                        <Text style={styles.sectionTitle}>Currency</Text>
                        <Text>{data.currency}</Text>
                    </View>
                </View>

                <View style={[styles.table, styles.section]}>
                    <View style={[styles.tr, styles.th]}>
                        <Text style={styles.cNo}>#</Text>
                        <Text style={styles.cDesc}>Material</Text>
                        <Text style={styles.cQty}>Quantity</Text>
                        <Text style={styles.cPrice}>Unit price</Text>
                        <Text style={styles.cAmt}>Amount ({data.currency})</Text>
                    </View>
                    {data.lines.map((l) => (
                        <View key={l.line_no} style={styles.tr} wrap={false}>
                            <Text style={styles.cNo}>{l.line_no}</Text>
                            <View style={styles.cDesc}>
                                <Text>{l.material_name}</Text>
                                {pricingStatusText(l).map((s, i) => (
                                    <Text key={i} style={styles.statusLine}>{s}</Text>
                                ))}
                                {l.notes ? <Text style={styles.statusLine}>{l.notes}</Text> : null}
                            </View>
                            <Text style={styles.cQty}>
                                {num(l.quantity, 0)} {l.unit}
                            </Text>
                            <Text style={styles.cPrice}>{l.unit_price === null ? '—' : num(l.unit_price)}</Text>
                            <Text style={styles.cAmt}>{num(l.amount_ccy)}</Text>
                        </View>
                    ))}
                    <View style={styles.totalRow}>
                        <Text style={styles.totalLabel}>Estimated total ({data.currency})</Text>
                        <Text>{num(data.estimated_total_ccy)}</Text>
                    </View>
                </View>

                {data.payment_terms.length > 0 ? (
                    <View style={styles.section}>
                        <Text style={styles.sectionTitle}>Payment schedule</Text>
                        {data.payment_terms.map((t) => (
                            <Text key={t.seq}>
                                {t.seq}. {t.label} —{' '}
                                {t.percentage !== null
                                    ? `${num(t.percentage, 1)}%`
                                    : `${num(t.fixed_amount_ccy ?? 0)} ${data.currency}`}
                                {t.trigger_event ? ` — on ${t.trigger_event.replace(/_/g, ' ')}` : ''}
                                {t.due_date ? ` — due ${t.due_date}` : ''}
                                {t.notes ? ` (${t.notes})` : ''}
                            </Text>
                        ))}
                    </View>
                ) : null}

                {data.terms_text ? (
                    <View style={styles.section}>
                        <Text style={styles.sectionTitle}>Terms</Text>
                        <Text>{data.terms_text}</Text>
                    </View>
                ) : null}
                {data.notes ? (
                    <View style={styles.section}>
                        <Text style={styles.sectionTitle}>Notes</Text>
                        <Text>{data.notes}</Text>
                    </View>
                ) : null}

                <Text style={styles.footer} fixed>
                    {`${company.legal_name} — Purchase Order ${data.code}. Provisional prices settle on the committed terms stated per line.`}
                </Text>
            </Page>
        </Document>
    )
}
