// app/sales/quotes/[id]/pdf/QuotationDocument.tsx
// SO-4b:报价单 PDF。
//
// 【正文一律英文,与发票/销售订单/采购单/贷项凭证同一条既定政策】—— 这是一份
// 签发给外部的商业单据,收件人不是这套系统的用户,所以界面语言切成中文时开出来
// 的也必须是英文。文案硬编码,【不接 i18n】(InvoiceDocument 的抬头写过理由;
// RPT-1 的报表跟随界面语言是【另一件事】,那只给打开系统的这个人看)。
//
// 【这张纸上没有任何总账内容】报价不碰库存也不碰总账 —— 没有应收、没有分录、
// 没有税。它只说四件事:报给谁、什么货什么价、合计多少、有效到哪天。
//
// 【有效期要显眼】它是这张纸上唯一带【时限】的承诺,而过期之后这份报价就转不成
// 订单了(convert_quote 按名拒)。把它埋进小字里,等于让客户按一个已经作废的价格
// 来下单 —— 所以它单独一块,与合计并列。
//
// 【字体与 CJK 断词从发票文档继承】客户名与地址可能是中文,正文是英文。
import { Document, Page, Text, View, StyleSheet } from '@react-pdf/renderer'
import { INVOICE_FONT_FAMILY } from '@/app/finance/invoices/[id]/pdf/InvoiceDocument'

export type QuoteDocData = {
    code: string
    quote_date: string
    valid_until: string
    currency: string
    customer: { code: string; legal_name: string }
    lines: { line_no: number; material: string; quantity: number; unit: string; unit_price: number }[]
    total: number
    notes: string | null
    terms_text: string | null
}

const styles = StyleSheet.create({
    page: { fontFamily: INVOICE_FONT_FAMILY, fontSize: 9, padding: 36, color: '#111827' },
    title: { fontSize: 16, fontWeight: 'bold', marginBottom: 2 },
    code: { fontSize: 11, marginBottom: 14 },
    metaRow: { flexDirection: 'row', marginBottom: 1 },
    metaLabel: { width: 100, color: '#6b7280' },
    metaBlock: { marginBottom: 14, paddingBottom: 10, borderBottomWidth: 1, borderBottomColor: '#111827' },
    tableHeader: {
        flexDirection: 'row', borderBottomWidth: 1, borderBottomColor: '#111827',
        paddingBottom: 3, marginBottom: 2, fontWeight: 'bold',
    },
    row: { flexDirection: 'row', paddingVertical: 3, borderBottomWidth: 0.5, borderBottomColor: '#e5e7eb' },
    cell: { paddingRight: 6 },
    totalRow: { flexDirection: 'row', marginTop: 8, paddingTop: 6, borderTopWidth: 1, borderTopColor: '#111827' },
    validity: {
        marginTop: 14, padding: 8, borderWidth: 1, borderColor: '#111827',
    },
    validityLabel: { color: '#6b7280', marginBottom: 2 },
    validityValue: { fontSize: 12, fontWeight: 'bold' },
    block: { marginTop: 14 },
    label: { color: '#6b7280', marginBottom: 2 },
    footer: { position: 'absolute', bottom: 20, left: 36, right: 36, fontSize: 7, color: '#9ca3af' },
})

const COLS = [
    { header: '#', width: 26 },
    { header: 'Description', width: 240 },
    { header: 'Quantity', width: 90, align: 'right' as const },
    { header: 'Unit price', width: 80, align: 'right' as const },
    { header: 'Amount', width: 80, align: 'right' as const },
]

const money = (n: number) =>
    n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

export default function QuotationDocument({ data }: { data: QuoteDocData }) {
    return (
        <Document>
            <Page size="A4" style={styles.page}>
                <View fixed>
                    <Text style={styles.title}>Quotation</Text>
                    <Text style={styles.code}>{data.code}</Text>
                    <View style={styles.metaBlock}>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>Customer</Text>
                            <Text>{data.customer.code} — {data.customer.legal_name}</Text>
                        </View>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>Date</Text>
                            <Text>{data.quote_date}</Text>
                        </View>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>Currency</Text>
                            <Text>{data.currency}</Text>
                        </View>
                    </View>
                </View>

                <View style={styles.tableHeader}>
                    {COLS.map((c) => (
                        <Text key={c.header} style={[styles.cell, { width: c.width, textAlign: c.align ?? 'left' }]}>
                            {c.header}
                        </Text>
                    ))}
                </View>
                {data.lines.map((l) => (
                    <View key={l.line_no} style={styles.row} wrap={false}>
                        <Text style={[styles.cell, { width: COLS[0].width }]}>{l.line_no}</Text>
                        <Text style={[styles.cell, { width: COLS[1].width }]}>{l.material}</Text>
                        <Text style={[styles.cell, { width: COLS[2].width, textAlign: 'right' }]}>
                            {l.quantity} {l.unit}
                        </Text>
                        <Text style={[styles.cell, { width: COLS[3].width, textAlign: 'right' }]}>
                            {money(l.unit_price)}
                        </Text>
                        <Text style={[styles.cell, { width: COLS[4].width, textAlign: 'right' }]}>
                            {money(Math.round(l.quantity * l.unit_price * 100) / 100)}
                        </Text>
                    </View>
                ))}

                <View style={styles.totalRow}>
                    <Text style={[styles.cell, { width: 436, textAlign: 'right', fontWeight: 'bold' }]}>
                        Total
                    </Text>
                    <Text style={[styles.cell, { width: 80, textAlign: 'right', fontWeight: 'bold' }]}>
                        {money(data.total)} {data.currency}
                    </Text>
                </View>

                {/* 【有效期单独一块 —— 见文件抬头】它是这张纸上唯一带时限的承诺 */}
                <View style={styles.validity}>
                    <Text style={styles.validityLabel}>This quotation is valid until</Text>
                    <Text style={styles.validityValue}>{data.valid_until}</Text>
                </View>

                {data.terms_text ? (
                    <View style={styles.block}>
                        <Text style={styles.label}>Terms</Text>
                        <Text>{data.terms_text}</Text>
                    </View>
                ) : null}
                {data.notes ? (
                    <View style={styles.block}>
                        <Text style={styles.label}>Notes</Text>
                        <Text>{data.notes}</Text>
                    </View>
                ) : null}

                <Text style={styles.footer} fixed>
                    This quotation is an offer, not an invoice. Prices are held until the validity date above.
                </Text>
            </Page>
        </Document>
    )
}
