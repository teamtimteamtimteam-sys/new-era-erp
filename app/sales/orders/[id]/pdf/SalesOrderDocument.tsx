// app/sales/orders/[id]/pdf/SalesOrderDocument.tsx
// SO-1:销售订单 PDF。
//
// 【正文一律英文,与发票/采购单同一条政策】—— 这份文档是【签发给外部的商业
// 单据】,收件人不是这套系统的用户,所以界面语言切成中文时开出来的也必须是英文。
// 【与报表中心刻意不同】:RPT-1 的报表跟随请求方的界面语言,因为那只给打开
// 系统的这个人看;把一条对外单据的规矩套到内部报表上是错的,反过来也一样。
//
// ── PDF-1(2026-09-02):版式改用共享层 ────────────────────────────────────
// 【此前不印公司抬头】现在字标与法定名称由 DocumentLetterhead 给。
// 【页码保留】这份单据此前就印页码(八份里只有两份印),现在由共享页脚给,
// 格式从 `SO-xxxx · page 1 / 3` 变成 `SO-xxxx · Page 1 of 3` —— 与另外七份一致。
// 【文字与数字一个都没有改】列头、状态、条款、备注全部逐字保留(R3)。
import { Document, Page, Text, View } from '@react-pdf/renderer'
import {
    docStyles, DocumentLetterhead, DocumentFooter, TableHeader,
} from '@/app/components/pdf/DocumentChrome'
import type { DocumentCompany } from '@/app/components/pdf/company'

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

const COLS = [
    { header: '#', width: 26 },
    { header: 'Material', width: 250 },
    { header: 'Quantity', width: 90, align: 'right' as const },
    { header: 'Unit price', width: 90, align: 'right' as const },
]

export default function SalesOrderDocument({
    data,
    company,
}: {
    data: SoDocData
    company: DocumentCompany
}) {
    return (
        <Document title={data.code}>
            <Page size="A4" style={docStyles.page}>
                <View fixed>
                    <DocumentLetterhead company={company} />
                    <Text style={docStyles.title}>Sales order</Text>
                    <Text style={docStyles.code}>{data.code}</Text>
                    <View style={docStyles.metaBlock}>
                        <View style={docStyles.metaRow}>
                            <Text style={docStyles.metaLabel}>Customer</Text>
                            <Text>{data.customer.code} — {data.customer.legal_name}</Text>
                        </View>
                        <View style={docStyles.metaRow}>
                            <Text style={docStyles.metaLabel}>Order date</Text>
                            <Text>{data.order_date}</Text>
                        </View>
                        <View style={docStyles.metaRow}>
                            <Text style={docStyles.metaLabel}>Currency</Text>
                            <Text>{data.currency}</Text>
                        </View>
                        <View style={docStyles.metaRow}>
                            <Text style={docStyles.metaLabel}>Status</Text>
                            <Text>{data.status}</Text>
                        </View>
                    </View>
                </View>

                <TableHeader columns={COLS} />
                {data.lines.map((l) => (
                    <View key={l.line_no} style={docStyles.row} wrap={false}>
                        <Text style={[docStyles.cell, { width: 26 }]}>{l.line_no}</Text>
                        <Text style={[docStyles.cell, { width: 250 }]}>{l.material}</Text>
                        <Text style={[docStyles.cell, { width: 90, textAlign: 'right' }]}>{l.quantity}</Text>
                        <Text style={[docStyles.cell, { width: 90, textAlign: 'right' }]}>{l.unit_price}</Text>
                    </View>
                ))}

                {data.terms_text && (
                    <View style={docStyles.block}><Text>{data.terms_text}</Text></View>
                )}
                {data.notes && (
                    <View style={docStyles.block}><Text>{data.notes}</Text></View>
                )}

                <DocumentFooter code={data.code} />
            </Page>
        </Document>
    )
}
