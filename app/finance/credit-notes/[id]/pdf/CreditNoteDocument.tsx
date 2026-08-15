// app/finance/credit-notes/[id]/pdf/CreditNoteDocument.tsx
// CN-1:贷项凭证 PDF。
//
// 【正文一律英文,与发票/销售订单/采购单同一条既定政策】—— 这是一份签发给
// 外部的商业单据,收件人不是这套系统的用户,所以界面语言切成中文时开出来的
// 也必须是英文。文案硬编码,【不接 i18n】(InvoiceDocument 的抬头写过理由)。
//
// 【这张纸上必须能读出三件事,而它们决定了版面】
//   ① 它冲的是【哪一张发票】—— 一张不指向发票的贷记通知在客户那边无从入账;
//   ② 【为什么】—— 理由印在正文里,不是内部备注:客户拿到的这张纸要能自洽;
//   ③ 每一行是【哪一种】—— "货没发出去" 与 "发了但便宜了" 对客户是两件事
//      (前者他本来就没收到货,后者他收到了货只是少付),用大白话印出来,
//      不印 unshipped_cancel 这种内部枚举名。
//
// 【字体与 CJK 断词从发票文档继承】客户名与地址可能是中文,正文是英文。
import { Document, Page, Text, View, StyleSheet } from '@react-pdf/renderer'
import { INVOICE_FONT_FAMILY } from '@/app/finance/invoices/[id]/pdf/InvoiceDocument'

export type CnDocData = {
    code: string
    note_date: string
    reason: string
    currency: string
    invoice_code: string
    invoice_issue_date: string
    customer: { code: string; legal_name: string }
    lines: { line_no: number; description: string; kind: string; qty: number | null; amount: number }[]
    total: number
}

// 【内部枚举 → 客户读得懂的一句话】客户手里那张纸上不该出现
// 'unshipped_cancel'。这两句是【单据正文】,所以与界面语言无关。
const KIND_FACE: Record<string, string> = {
    unshipped_cancel: 'Goods not delivered — cancelled',
    revenue_reduction: 'Price / quality adjustment',
}

const styles = StyleSheet.create({
    page: { fontFamily: INVOICE_FONT_FAMILY, fontSize: 9, padding: 36, color: '#111827' },
    title: { fontSize: 16, fontWeight: 'bold', marginBottom: 2 },
    code: { fontSize: 11, marginBottom: 14 },
    metaRow: { flexDirection: 'row', marginBottom: 1 },
    metaLabel: { width: 110, color: '#6b7280' },
    metaBlock: { marginBottom: 14, paddingBottom: 10, borderBottomWidth: 1, borderBottomColor: '#111827' },
    tableHeader: {
        flexDirection: 'row', borderBottomWidth: 1, borderBottomColor: '#111827',
        paddingBottom: 3, marginBottom: 2, fontWeight: 'bold',
    },
    row: { flexDirection: 'row', paddingVertical: 3, borderBottomWidth: 0.5, borderBottomColor: '#e5e7eb' },
    cell: { paddingRight: 6 },
    totalRow: { flexDirection: 'row', marginTop: 8, paddingTop: 6, borderTopWidth: 1, borderTopColor: '#111827' },
    reason: { marginTop: 16 },
    label: { color: '#6b7280', marginBottom: 2 },
    footer: { position: 'absolute', bottom: 20, left: 36, right: 36, fontSize: 7, color: '#9ca3af' },
})

const COLS = [
    { header: '#', width: 26 },
    { header: 'Description', width: 200 },
    { header: 'Reason', width: 150 },
    { header: 'Quantity', width: 60, align: 'right' as const },
    { header: 'Amount', width: 80, align: 'right' as const },
]

const money = (n: number) =>
    n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

export default function CreditNoteDocument({ data }: { data: CnDocData }) {
    return (
        <Document>
            <Page size="A4" style={styles.page}>
                <View fixed>
                    <Text style={styles.title}>Credit note</Text>
                    <Text style={styles.code}>{data.code}</Text>
                    <View style={styles.metaBlock}>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>Customer</Text>
                            <Text>{data.customer.code} — {data.customer.legal_name}</Text>
                        </View>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>Date</Text>
                            <Text>{data.note_date}</Text>
                        </View>
                        {/* 【它冲的是哪一张发票】—— 少了这一行,客户无从入账 */}
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>Against invoice</Text>
                            <Text>{data.invoice_code} ({data.invoice_issue_date})</Text>
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
                {data.lines.map((l, i) => (
                    <View key={i} style={styles.row} wrap={false}>
                        <Text style={[styles.cell, { width: COLS[0].width }]}>{l.line_no}</Text>
                        <Text style={[styles.cell, { width: COLS[1].width }]}>{l.description}</Text>
                        <Text style={[styles.cell, { width: COLS[2].width }]}>{KIND_FACE[l.kind] ?? l.kind}</Text>
                        <Text style={[styles.cell, { width: COLS[3].width, textAlign: 'right' }]}>
                            {l.qty === null ? '' : l.qty}
                        </Text>
                        <Text style={[styles.cell, { width: COLS[4].width, textAlign: 'right' }]}>
                            {money(l.amount)}
                        </Text>
                    </View>
                ))}

                <View style={styles.totalRow}>
                    <Text style={[styles.cell, { width: 436, textAlign: 'right', fontWeight: 'bold' }]}>
                        Total credited
                    </Text>
                    <Text style={[styles.cell, { width: 80, textAlign: 'right', fontWeight: 'bold' }]}>
                        {money(data.total)} {data.currency}
                    </Text>
                </View>

                <View style={styles.reason}>
                    <Text style={styles.label}>Reason</Text>
                    <Text>{data.reason}</Text>
                </View>

                <Text style={styles.footer} fixed>
                    This credit note reduces the amount payable on invoice {data.invoice_code}. It is not a refund.
                </Text>
            </Page>
        </Document>
    )
}
