// app/finance/credit-notes/[id]/pdf/CreditNoteDocument.tsx
// CN-1:贷项凭证 PDF。
//
// 【正文一律英文,与发票/销售订单/采购单同一条既定政策】—— 这是一份签发给
// 外部的商业单据,收件人不是这套系统的用户,所以界面语言切成中文时开出来的
// 也必须是英文。文案硬编码,【不接 i18n】。
//
// 【这张纸上必须能读出三件事,而它们决定了版面】
//   ① 它冲的是【哪一张发票】—— 一张不指向发票的贷记通知在客户那边无从入账;
//   ② 【为什么】—— 理由印在正文里,不是内部备注:客户拿到的这张纸要能自洽;
//   ③ 每一行是【哪一种】—— "货没发出去" 与 "发了但便宜了" 对客户是两件事
//      (前者他本来就没收到货,后者他收到了货只是少付),用大白话印出来,
//      不印 unshipped_cancel 这种内部枚举名。
//
// ── PDF-1(2026-09-02):版式改用共享层 ────────────────────────────────────
// 【此前不印公司抬头,也不印页码】—— 一张要进客户账的贷项凭证,没说是谁开的。
// 两者现在都由共享层给(字体栈一并来自 app/components/pdf/fonts.ts)。
// 【文字与数字一个都没有改】KIND_FACE 那两句、列头、'Total credited'、
// 'Reason'、以及页脚那句 "It is not a refund." 全部逐字保留(R3)。
import { Document, Page, Text, View } from '@react-pdf/renderer'
import {
    docStyles, DocumentLetterhead, DocumentFooter, TableHeader,
} from '@/app/components/pdf/DocumentChrome'
import { money } from '@/app/components/pdf/theme'
import type { DocumentCompany } from '@/app/components/pdf/company'

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

const COLS = [
    { header: '#', width: 26 },
    { header: 'Description', width: 200 },
    { header: 'Reason', width: 150 },
    { header: 'Quantity', width: 60, align: 'right' as const },
    { header: 'Amount', width: 80, align: 'right' as const },
]

export default function CreditNoteDocument({
    data,
    company,
}: {
    data: CnDocData
    company: DocumentCompany
}) {
    return (
        <Document title={data.code}>
            <Page size="A4" style={docStyles.page}>
                <View fixed>
                    <DocumentLetterhead company={company} />
                    <Text style={docStyles.title}>Credit note</Text>
                    <Text style={docStyles.code}>{data.code}</Text>
                    <View style={docStyles.metaBlock}>
                        <View style={docStyles.metaRow}>
                            <Text style={docStyles.metaLabel}>Customer</Text>
                            <Text>{data.customer.code} — {data.customer.legal_name}</Text>
                        </View>
                        <View style={docStyles.metaRow}>
                            <Text style={docStyles.metaLabel}>Date</Text>
                            <Text>{data.note_date}</Text>
                        </View>
                        {/* 【它冲的是哪一张发票】—— 少了这一行,客户无从入账 */}
                        <View style={docStyles.metaRow}>
                            <Text style={docStyles.metaLabel}>Against invoice</Text>
                            <Text>{data.invoice_code} ({data.invoice_issue_date})</Text>
                        </View>
                        <View style={docStyles.metaRow}>
                            <Text style={docStyles.metaLabel}>Currency</Text>
                            <Text>{data.currency}</Text>
                        </View>
                    </View>
                </View>

                <TableHeader columns={COLS} />
                {data.lines.map((l, i) => (
                    <View key={i} style={docStyles.row} wrap={false}>
                        <Text style={[docStyles.cell, { width: COLS[0].width }]}>{l.line_no}</Text>
                        <Text style={[docStyles.cell, { width: COLS[1].width }]}>{l.description}</Text>
                        <Text style={[docStyles.cell, { width: COLS[2].width }]}>{KIND_FACE[l.kind] ?? l.kind}</Text>
                        <Text style={[docStyles.cell, { width: COLS[3].width, textAlign: 'right' }]}>
                            {l.qty === null ? '' : l.qty}
                        </Text>
                        <Text style={[docStyles.cell, { width: COLS[4].width, textAlign: 'right' }]}>
                            {money(l.amount)}
                        </Text>
                    </View>
                ))}

                <View style={docStyles.totalRow}>
                    <Text style={[docStyles.cell, { width: 436, textAlign: 'right', fontWeight: 'bold' }]}>
                        Total credited
                    </Text>
                    <Text style={[docStyles.cell, { width: 80, textAlign: 'right', fontWeight: 'bold' }]}>
                        {money(data.total)} {data.currency}
                    </Text>
                </View>

                <View style={docStyles.block}>
                    <Text style={docStyles.label}>Reason</Text>
                    <Text>{data.reason}</Text>
                </View>

                <DocumentFooter
                    code={data.code}
                    note={`This credit note reduces the amount payable on invoice ${data.invoice_code}. It is not a refund.`}
                />
            </Page>
        </Document>
    )
}
