// app/sales/quotes/[id]/pdf/QuotationDocument.tsx
// SO-4b:报价单 PDF。
//
// 【正文一律英文,与发票/销售订单/采购单/贷项凭证同一条既定政策】—— 这是一份
// 签发给外部的商业单据,收件人不是这套系统的用户,所以界面语言切成中文时开出来
// 的也必须是英文。文案硬编码,【不接 i18n】(RPT-1 的报表跟随界面语言是【另一件
// 事】,那只给打开系统的这个人看)。
//
// 【这张纸上没有任何总账内容】报价不碰库存也不碰总账 —— 没有应收、没有分录、
// 没有税。它只说四件事:报给谁、什么货什么价、合计多少、有效到哪天。
//
// 【有效期要显眼】它是这张纸上唯一带【时限】的承诺,而过期之后这份报价就转不成
// 订单了(convert_quote 按名拒)。把它埋进小字里,等于让客户按一个已经作废的价格
// 来下单 —— 所以它单独一块,与合计并列。
//
// ── PDF-1(2026-09-02):版式改用共享层 ────────────────────────────────────
// 【这份单据此前【不印公司抬头】】—— 客户手里那张报价单上,没有任何东西说明它
// 是谁开的。现在字标与法定名称由 DocumentLetterhead 给,与另外七份同一份实现。
// 【文字与数字一个都没有改】标题、列头、合计、有效期那句话、页脚那句话、
// 金额格式(千分位两位小数)全部逐字保留 —— 这是一次版式改动(R3)。
import { Document, Page, Text, View, StyleSheet } from '@react-pdf/renderer'
import {
    docStyles, DocumentLetterhead, DocumentFooter, TableHeader, NoSignatureNote,
} from '@/app/components/pdf/DocumentChrome'
import { noSignatureEn } from '@/app/components/pdf/noSignature'
import { money, BRAND } from '@/app/components/pdf/theme'
import type { DocumentCompany } from '@/app/components/pdf/company'

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

// 【只有报价单有的两条样式】有效期那一块 —— 它是这份单据独有的构造,不进共享层:
// 共享层放的是八份单据都有的东西,把一份独有的块塞进去会让下一个人以为别的单据
// 也该有一个。边框用 Ocean:1pt 实色,黑白打印下也留得住。
const styles = StyleSheet.create({
    validity: { marginTop: 14, padding: 8, borderWidth: 1, borderColor: BRAND.ocean },
    validityValue: { fontSize: 12, fontWeight: 'bold' },
})

const COLS = [
    { header: '#', width: 26 },
    { header: 'Description', width: 240 },
    { header: 'Quantity', width: 90, align: 'right' as const },
    { header: 'Unit price', width: 80, align: 'right' as const },
    { header: 'Amount', width: 80, align: 'right' as const },
]

export default function QuotationDocument({
    data,
    company,
}: {
    data: QuoteDocData
    company: DocumentCompany
}) {
    return (
        <Document title={data.code}>
            <Page size="A4" style={docStyles.page}>
                <View fixed>
                    <DocumentLetterhead company={company} />
                    <Text style={docStyles.title}>Quotation</Text>
                    <Text style={docStyles.code}>{data.code}</Text>
                    <View style={docStyles.metaBlock}>
                        <View style={docStyles.metaRow}>
                            <Text style={docStyles.metaLabel}>Customer</Text>
                            <Text>{data.customer.code} — {data.customer.legal_name}</Text>
                        </View>
                        <View style={docStyles.metaRow}>
                            <Text style={docStyles.metaLabel}>Date</Text>
                            <Text>{data.quote_date}</Text>
                        </View>
                        <View style={docStyles.metaRow}>
                            <Text style={docStyles.metaLabel}>Currency</Text>
                            <Text>{data.currency}</Text>
                        </View>
                    </View>
                </View>

                <TableHeader columns={COLS} />
                {data.lines.map((l) => (
                    <View key={l.line_no} style={docStyles.row} wrap={false}>
                        <Text style={[docStyles.cell, { width: COLS[0].width }]}>{l.line_no}</Text>
                        <Text style={[docStyles.cell, { width: COLS[1].width }]}>{l.material}</Text>
                        <Text style={[docStyles.cell, { width: COLS[2].width, textAlign: 'right' }]}>
                            {l.quantity} {l.unit}
                        </Text>
                        <Text style={[docStyles.cell, { width: COLS[3].width, textAlign: 'right' }]}>
                            {money(l.unit_price)}
                        </Text>
                        <Text style={[docStyles.cell, { width: COLS[4].width, textAlign: 'right' }]}>
                            {money(Math.round(l.quantity * l.unit_price * 100) / 100)}
                        </Text>
                    </View>
                ))}

                <View style={docStyles.totalRow}>
                    <Text style={[docStyles.cell, { width: 436, textAlign: 'right', fontWeight: 'bold' }]}>
                        Total
                    </Text>
                    <Text style={[docStyles.cell, { width: 80, textAlign: 'right', fontWeight: 'bold' }]}>
                        {money(data.total)} {data.currency}
                    </Text>
                </View>

                {/* 【有效期单独一块 —— 见文件抬头】它是这张纸上唯一带时限的承诺 */}
                <View style={styles.validity}>
                    <Text style={docStyles.label}>This quotation is valid until</Text>
                    <Text style={styles.validityValue}>{data.valid_until}</Text>
                </View>

                {data.terms_text ? (
                    <View style={docStyles.block}>
                        <Text style={docStyles.label}>Terms</Text>
                        <Text>{data.terms_text}</Text>
                    </View>
                ) : null}
                {data.notes ? (
                    <View style={docStyles.block}>
                        <Text style={docStyles.label}>Notes</Text>
                        <Text>{data.notes}</Text>
                    </View>
                ) : null}

                <NoSignatureNote text={noSignatureEn('quotation')} />

                <DocumentFooter
                    code={data.code}
                    note="This quotation is an offer, not an invoice. Prices are held until the validity date above."
                />
            </Page>
        </Document>
    )
}
