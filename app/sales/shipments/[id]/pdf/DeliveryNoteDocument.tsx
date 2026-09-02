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
//
// ── PDF-1(2026-09-02):版式改用共享层 ────────────────────────────────────
// 【此前不印公司抬头,也不印页码】—— 一份多页送货单散在收货台上,没有办法知道
// 少了哪一页,而少的那一页上可能正是那行 CONTROLLED。两者现在都由共享层给。
// 【CONTROLLED 那一栏的颜色保留原样】#991b1b 是一个刻意的警示红,不属于品牌调色板,
// 也【不该】被换成品牌色:它要的就是"和这张纸上别的东西都不一样"。
// 【文字与数字一个都没有改】列头、'not classified'、页脚那段话逐字保留(R3)。
import { Document, Page, Text, View, StyleSheet } from '@react-pdf/renderer'
import {
    docStyles, DocumentLetterhead, DocumentFooter, TableHeader,
} from '@/app/components/pdf/DocumentChrome'
import type { DocumentCompany } from '@/app/components/pdf/company'

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

// 【只有送货单有的一条】受控标记的警示红 —— 见抬头,刻意不用品牌色。
const styles = StyleSheet.create({
    controlled: { color: '#991b1b', fontWeight: 'bold' },
})

const COLS = [
    { header: '#', width: 22 },
    { header: 'Material', width: 168 },
    { header: 'Batch', width: 92 },
    { header: 'Classification', width: 132 },
    { header: 'Quantity', width: 80, align: 'right' as const },
]

export default function DeliveryNoteDocument({
    d,
    company,
}: {
    d: DeliveryNoteData
    company: DocumentCompany
}) {
    return (
        <Document title={d.code}>
            <Page size="A4" style={docStyles.page}>
                <View fixed>
                    <DocumentLetterhead company={company} />
                    <Text style={docStyles.title}>Delivery Note</Text>
                    <Text style={docStyles.code}>{d.code}</Text>

                    <View style={docStyles.metaBlock}>
                        <View style={docStyles.metaRow}>
                            <Text style={docStyles.metaLabel}>Ship date</Text><Text>{d.ship_date}</Text>
                        </View>
                        <View style={docStyles.metaRow}>
                            <Text style={docStyles.metaLabel}>Sales order</Text><Text>{d.order_code}</Text>
                        </View>
                        <View style={docStyles.metaRow}>
                            <Text style={docStyles.metaLabel}>Deliver to</Text>
                            <Text>{d.customer.code} — {d.customer.legal_name}</Text>
                        </View>
                    </View>
                </View>

                <TableHeader columns={COLS} />
                {d.lines.map((l) => (
                    <View key={l.line_no} style={docStyles.row}>
                        <Text style={[docStyles.cell, { width: COLS[0].width }]}>{l.line_no}</Text>
                        <Text style={[docStyles.cell, { width: COLS[1].width }]}>{l.material}</Text>
                        <Text style={[docStyles.cell, { width: COLS[2].width }]}>{l.batch_code}</Text>
                        <Text style={[docStyles.cell, { width: COLS[3].width },
                                      l.is_controlled ? styles.controlled : {}]}>
                            {l.classification
                                ? l.classification + (l.is_controlled ? ' — CONTROLLED' : '')
                                : 'not classified'}
                        </Text>
                        <Text style={[docStyles.cell, { width: COLS[4].width, textAlign: 'right' }]}>
                            {l.quantity} {l.unit}
                        </Text>
                    </View>
                ))}

                <DocumentFooter
                    code={d.code}
                    note={
                        'Goods described above were released from stock on the ship date shown. Material ' +
                        'classification is stated as recorded in the material register; "not classified" ' +
                        'means no classification has been recorded, which is not the same as non-controlled.'
                    }
                />
            </Page>
        </Document>
    )
}
