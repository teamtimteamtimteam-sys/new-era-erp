// app/sales/orders/[id]/pdf/SalesOrderDocument.tsx
// SO-1:销售订单 PDF。
//
// 【正文一律英文,与发票/采购单同一条政策】—— 这份文档是【签发给外部的商业
// 单据】,收件人不是这套系统的用户,所以界面语言切成中文时开出来的也必须是英文。
// 【与报表中心刻意不同】:RPT-1 的报表跟随请求方的界面语言,因为那只给打开
// 系统的这个人看;把一条对外单据的规矩套到内部报表上是错的,反过来也一样。
//
// 【字体与 CJK 断词从发票文档继承】import 它就完成了 Noto Sans SC 的注册与
// registerHyphenationCallback —— 客户名与地址可能是中文,而正文是英文。
import { Document, Page, Text, View, StyleSheet } from '@react-pdf/renderer'
import { INVOICE_FONT_FAMILY } from '@/app/finance/invoices/[id]/pdf/InvoiceDocument'

export type SoDocData = {
    code: string
    status: string
    order_date: string
    currency: string
    customer: { code: string; legal_name: string }
    lines: { line_no: number; material: string; quantity: number; unit_price: number }[]
    notes: string | null
    terms_text: string | null
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
    notes: { marginTop: 16 },
    footer: { position: 'absolute', bottom: 20, left: 36, right: 36, fontSize: 7, color: '#9ca3af' },
})

const COLS = [
    { header: '#', width: 26 },
    { header: 'Material', width: 250 },
    { header: 'Quantity', width: 90, align: 'right' as const },
    { header: 'Unit price', width: 90, align: 'right' as const },
]

export default function SalesOrderDocument({ data }: { data: SoDocData }) {
    return (
        <Document>
            <Page size="A4" style={styles.page}>
                <View fixed>
                    <Text style={styles.title}>Sales order</Text>
                    <Text style={styles.code}>{data.code}</Text>
                    <View style={styles.metaBlock}>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>Customer</Text>
                            <Text>{data.customer.code} — {data.customer.legal_name}</Text>
                        </View>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>Order date</Text>
                            <Text>{data.order_date}</Text>
                        </View>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>Currency</Text>
                            <Text>{data.currency}</Text>
                        </View>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>Status</Text>
                            <Text>{data.status}</Text>
                        </View>
                    </View>
                </View>

                <View style={styles.tableHeader} fixed>
                    {COLS.map((c, i) => (
                        <Text key={i} style={[styles.cell, { width: c.width, textAlign: c.align ?? 'left' }]}>{c.header}</Text>
                    ))}
                </View>
                {data.lines.map((l) => (
                    <View key={l.line_no} style={styles.row} wrap={false}>
                        <Text style={[styles.cell, { width: 26 }]}>{l.line_no}</Text>
                        <Text style={[styles.cell, { width: 250 }]}>{l.material}</Text>
                        <Text style={[styles.cell, { width: 90, textAlign: 'right' }]}>{l.quantity}</Text>
                        <Text style={[styles.cell, { width: 90, textAlign: 'right' }]}>{l.unit_price}</Text>
                    </View>
                ))}

                {data.terms_text && (
                    <View style={styles.notes}><Text>{data.terms_text}</Text></View>
                )}
                {data.notes && (
                    <View style={styles.notes}><Text>{data.notes}</Text></View>
                )}

                <Text style={styles.footer}
                      render={({ pageNumber, totalPages }) => `${data.code} · page ${pageNumber} / ${totalPages}`}
                      fixed />
            </Page>
        </Document>
    )
}
