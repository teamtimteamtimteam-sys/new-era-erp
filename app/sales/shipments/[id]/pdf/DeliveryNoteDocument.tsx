// SO-3b:送货单 PDF。
//
// 【正文一律英文,与发票/采购单/销售订单同一条政策】—— 这是一份【签发给外部的
// 商业单据】,收件人不是这套系统的用户,所以界面语言切成中文时开出来的也必须
// 是英文。(与 RPT-1 的报表刻意不同:那些只给打开系统的这个人看。)
//
// 【货物性质印在单据的脸上 —— Doc 1 的那条痛点】"mis-representation of nature
// of cargo"。每一行印出物料的【受控废物分类名】,并在受控时印一个明确的
// CONTROLLED 标记。这不是装饰:第一票真实发货就是受控物料,所以这一行【印出来
// 的是真话,而且是有分量的真话】。
// 【未分类不印"不受控"】—— 那是两件事(MAT-1 的三态:未分类 ≠ 非受控)。
// 没有分类就印 "not classified",让人去看,而不是替他下结论。
import { Document, Page, Text, View, StyleSheet } from '@react-pdf/renderer'
import { INVOICE_FONT_FAMILY } from '@/app/finance/invoices/[id]/pdf/InvoiceDocument'

export type DeliveryNoteData = {
    code: string
    ship_date: string
    order_code: string
    customer: { code: string; legal_name: string }
    lines: {
        line_no: number
        material: string
        batch_code: string
        quantity: number
        unit: string
        classification: string | null
        is_controlled: boolean | null
    }[]
}

const styles = StyleSheet.create({
    page: { fontFamily: INVOICE_FONT_FAMILY, fontSize: 9, padding: 36, color: '#111827' },
    title: { fontSize: 16, fontWeight: 'bold', marginBottom: 2 },
    code: { fontSize: 11, marginBottom: 14 },
    metaRow: { flexDirection: 'row', marginBottom: 1 },
    metaLabel: { width: 90, color: '#6b7280' },
    metaBlock: { marginBottom: 14, paddingBottom: 10, borderBottomWidth: 1, borderBottomColor: '#111827' },
    tableHeader: {
        flexDirection: 'row', borderBottomWidth: 1, borderBottomColor: '#111827',
        paddingBottom: 3, marginBottom: 2, fontWeight: 'bold',
    },
    row: { flexDirection: 'row', paddingVertical: 3, borderBottomWidth: 0.5, borderBottomColor: '#e5e7eb' },
    cell: { paddingRight: 6 },
    controlled: { color: '#991b1b', fontWeight: 'bold' },
    footer: { position: 'absolute', bottom: 20, left: 36, right: 36, fontSize: 7, color: '#9ca3af' },
})

const COLS = [
    { header: '#', width: 22 },
    { header: 'Material', width: 168 },
    { header: 'Batch', width: 92 },
    { header: 'Classification', width: 132 },
    { header: 'Quantity', width: 80, align: 'right' as const },
]

export default function DeliveryNoteDocument({ d }: { d: DeliveryNoteData }) {
    return (
        <Document>
            <Page size="A4" style={styles.page}>
                <Text style={styles.title}>Delivery Note</Text>
                <Text style={styles.code}>{d.code}</Text>

                <View style={styles.metaBlock}>
                    <View style={styles.metaRow}>
                        <Text style={styles.metaLabel}>Ship date</Text><Text>{d.ship_date}</Text>
                    </View>
                    <View style={styles.metaRow}>
                        <Text style={styles.metaLabel}>Sales order</Text><Text>{d.order_code}</Text>
                    </View>
                    <View style={styles.metaRow}>
                        <Text style={styles.metaLabel}>Deliver to</Text>
                        <Text>{d.customer.code} — {d.customer.legal_name}</Text>
                    </View>
                </View>

                <View style={styles.tableHeader}>
                    {COLS.map((c) => (
                        <Text key={c.header} style={[styles.cell, { width: c.width, textAlign: c.align ?? 'left' }]}>
                            {c.header}
                        </Text>
                    ))}
                </View>
                {d.lines.map((l) => (
                    <View key={l.line_no} style={styles.row}>
                        <Text style={[styles.cell, { width: COLS[0].width }]}>{l.line_no}</Text>
                        <Text style={[styles.cell, { width: COLS[1].width }]}>{l.material}</Text>
                        <Text style={[styles.cell, { width: COLS[2].width }]}>{l.batch_code}</Text>
                        <Text style={[styles.cell, { width: COLS[3].width },
                                      l.is_controlled ? styles.controlled : {}]}>
                            {l.classification
                                ? l.classification + (l.is_controlled ? ' — CONTROLLED' : '')
                                : 'not classified'}
                        </Text>
                        <Text style={[styles.cell, { width: COLS[4].width, textAlign: 'right' }]}>
                            {l.quantity} {l.unit}
                        </Text>
                    </View>
                ))}

                <Text style={styles.footer}>
                    Goods described above were released from stock on the ship date shown. Material
                    classification is stated as recorded in the material register; &quot;not classified&quot;
                    means no classification has been recorded, which is not the same as non-controlled.
                </Text>
            </Page>
        </Document>
    )
}
