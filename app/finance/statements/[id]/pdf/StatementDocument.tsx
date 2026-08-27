// app/finance/statements/[id]/pdf/StatementDocument.tsx
// STATEMENT-1:客户对账单的版面。
//
// ★【它印的是【冻下来的那一行】,不是现算的】★ 数据全部来自 customer_statements:
// 期初/发生/贷记/核销/期末、每币种分段、期末账龄、以及明细行,都是签发那一刻抄下来的。
// 几个月后重打这一版,纸上还是当时那些数 —— 这正是 gst_return_boxes 与
// bank_reconciliations 立下的那条规矩,对账单是它的第三次。
//
// 【抬头走共用组件】对账单是一份【要钱的文书】,必须印我们自己的地址;
// 而它本会成为第三份抬头副本 —— 所以 STATEMENT-1 把抬头抽成了
// app/components/CompanyLetterhead.tsx,采购单与发票一并改读它(版式一个像素没动)。
//
// 【多币种:每个币种一段,另给一个【明标为折算】的本位币总额】
// 实测线上每一个客户都是多币种(有客户是 SGD 的发票、USD 的收款)。
// 把两种币直接加成一个数而不说,正是币种字面量那条检查存在的毛病。
import { Document, Page, Text, View, Image, StyleSheet } from '@react-pdf/renderer'
import CompanyLetterhead, { type LetterheadCompany } from '@/app/components/CompanyLetterhead'

export type StatementLine = {
    doc_kind: string
    doc_code: string
    doc_date: string
    due_date: string | null
    currency: string
    amount_ccy: number
    open_ccy: number
    open_base: number
    days_outstanding: number
    bucket: string
}

export type StatementDocData = {
    code: string
    customer: { code: string; legal_name: string }
    period_start: string
    period_end: string
    base_currency: string
    opening_base: number
    charges_base: number
    credits_base: number
    receipts_base: number
    applied_base: number
    on_account_base: number
    net_due_base: number
    closing_base: number
    no_movement: boolean
    lines: StatementLine[]
    by_currency: { currency: string; closing_ccy: number }[]
    buckets: Record<string, number>
    issued_at: string
    superseded: boolean
    company: LetterheadCompany
    logo: string | null
    /** 界面语言选出来的措辞 —— 版面不拼接双语,按语言选一条 */
    t: Record<string, string>
}

const styles = StyleSheet.create({
    page: { padding: 36, fontSize: 9, fontFamily: 'Helvetica' },
    header: { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 18 },
    logo: { width: 110, height: 40, objectFit: 'contain' },
    companyBlock: { alignItems: 'flex-end', maxWidth: 260 },
    companyName: { fontSize: 12, fontFamily: 'Helvetica-Bold', marginBottom: 2 },
    small: { fontSize: 8, color: '#444' },
    title: { fontSize: 16, fontFamily: 'Helvetica-Bold', marginBottom: 2 },
    meta: { fontSize: 9, marginBottom: 12 },
    sectionTitle: { fontSize: 10, fontFamily: 'Helvetica-Bold', marginTop: 12, marginBottom: 4 },
    row: { flexDirection: 'row' },
    th: { fontFamily: 'Helvetica-Bold', backgroundColor: '#eee', padding: 4 },
    td: { padding: 4, borderBottomWidth: 0.5, borderBottomColor: '#ddd' },
    right: { textAlign: 'right' },
    summaryRow: { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 2 },
    summaryStrong: { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 3,
                     borderTopWidth: 1, borderTopColor: '#333', marginTop: 3 },
    bold: { fontFamily: 'Helvetica-Bold' },
    note: { fontSize: 8, color: '#666', marginTop: 10 },
    voidMark: { position: 'absolute', top: 260, left: 90, fontSize: 60, color: '#d33', opacity: 0.25 },
})

const money = (n: number) =>
    n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

export default function StatementDocument({ data: d }: { data: StatementDocData }) {
    const w = { doc: '16%', kind: '14%', date: '12%', due: '12%', ccy: '8%', amt: '13%', open: '13%', age: '12%' }
    return (
        <Document title={d.code}>
            <Page size="A4" style={styles.page}>
                {/* 被取代的那一版仍然打得开,而且要认得出来 —— 与发票作废水印同一条:
                    让手里拿着旧件的人一眼看出它已经不是最新的那一份。 */}
                {d.superseded ? <Text style={styles.voidMark}>SUPERSEDED</Text> : null}

                <View style={styles.header}>
                    <View>{d.logo ? <Image src={d.logo} style={styles.logo} /> : null}</View>
                    <View style={styles.companyBlock}>
                        <CompanyLetterhead
                            company={d.company}
                            styles={{ name: styles.companyName, line: styles.small }}
                            variant="stacked"
                        />
                    </View>
                </View>

                <Text style={styles.title}>{d.t.title}</Text>
                <Text style={styles.meta}>
                    {d.code} · {d.customer.code} {d.customer.legal_name} · {d.period_start} → {d.period_end}
                </Text>

                {/* ── 结转式摘要 ─────────────────────────────────────────────── */}
                <Text style={styles.sectionTitle}>{d.t.summary} ({d.base_currency})</Text>
                <View style={styles.summaryRow}>
                    <Text>{d.t.opening}</Text><Text>{money(d.opening_base)}</Text>
                </View>
                <View style={styles.summaryRow}>
                    <Text>{d.t.charges}</Text><Text>{money(d.charges_base)}</Text>
                </View>
                <View style={styles.summaryRow}>
                    <Text>{d.t.credits}</Text><Text>({money(d.credits_base)})</Text>
                </View>
                <View style={styles.summaryRow}>
                    <Text>{d.t.applied}</Text><Text>({money(d.applied_base)})</Text>
                </View>
                <View style={styles.summaryStrong}>
                    <Text style={styles.bold}>{d.t.closing}</Text>
                    <Text style={styles.bold}>{money(d.closing_base)}</Text>
                </View>
                {/* 【挂账的钱单独说】它不在期末余额里(那是各单据未结额之和),
                    但客户确实付了 —— 不说就是少了一笔他付过的钱。 */}
                {d.on_account_base !== 0 ? (
                    <>
                        <View style={styles.summaryRow}>
                            <Text>{d.t.onAccount}</Text><Text>({money(d.on_account_base)})</Text>
                        </View>
                        <View style={styles.summaryStrong}>
                            <Text style={styles.bold}>{d.t.netDue}</Text>
                            <Text style={styles.bold}>{money(d.net_due_base)}</Text>
                        </View>
                    </>
                ) : null}

                {/* ── 期间内没有发生额:【说出来】,不是留一张空表 ────────────── */}
                {d.no_movement ? <Text style={styles.note}>{d.t.noMovement}</Text> : null}

                {/* ── 每币种一段 ─────────────────────────────────────────────── */}
                {d.by_currency.length > 1 ? (
                    <>
                        <Text style={styles.sectionTitle}>{d.t.byCurrency}</Text>
                        {d.by_currency.map((c) => (
                            <View key={c.currency} style={styles.summaryRow}>
                                <Text>{c.currency}</Text><Text>{money(c.closing_ccy)}</Text>
                            </View>
                        ))}
                        <Text style={styles.note}>{d.t.baseIsConverted}</Text>
                    </>
                ) : null}

                {/* ── 期末未结明细 ───────────────────────────────────────────── */}
                <Text style={styles.sectionTitle}>{d.t.openItems}</Text>
                <View style={styles.row}>
                    <Text style={[styles.th, { width: w.doc }] as never}>{d.t.colDoc}</Text>
                    <Text style={[styles.th, { width: w.kind }] as never}>{d.t.colKind}</Text>
                    <Text style={[styles.th, { width: w.date }] as never}>{d.t.colDate}</Text>
                    <Text style={[styles.th, { width: w.due }] as never}>{d.t.colDue}</Text>
                    <Text style={[styles.th, { width: w.ccy }] as never}>{d.t.colCcy}</Text>
                    <Text style={[styles.th, styles.right, { width: w.amt }] as never}>{d.t.colAmount}</Text>
                    <Text style={[styles.th, styles.right, { width: w.open }] as never}>{d.t.colOpen}</Text>
                    <Text style={[styles.th, styles.right, { width: w.age }] as never}>{d.t.colDays}</Text>
                </View>
                {d.lines.length === 0 ? (
                    <Text style={styles.note}>{d.t.nothingOutstanding}</Text>
                ) : (
                    d.lines.map((l, i) => (
                        <View key={`${l.doc_code}-${i}`} style={styles.row}>
                            <Text style={[styles.td, { width: w.doc }] as never}>{l.doc_code}</Text>
                            {/* 【单据种类照直说】未开票的销售用产出批号标识,而客户手里
                                没有那个号 —— 不说明是什么,它会被当成一个发票号。 */}
                            <Text style={[styles.td, { width: w.kind }] as never}>
                                {d.t['kind_' + l.doc_kind] ?? l.doc_kind}
                            </Text>
                            <Text style={[styles.td, { width: w.date }] as never}>{l.doc_date}</Text>
                            <Text style={[styles.td, { width: w.due }] as never}>{l.due_date ?? d.t.noDueDate}</Text>
                            <Text style={[styles.td, { width: w.ccy }] as never}>{l.currency}</Text>
                            <Text style={[styles.td, styles.right, { width: w.amt }] as never}>{money(l.amount_ccy)}</Text>
                            <Text style={[styles.td, styles.right, { width: w.open }] as never}>{money(l.open_ccy)}</Text>
                            <Text style={[styles.td, styles.right, { width: w.age }] as never}>{l.days_outstanding}</Text>
                        </View>
                    ))
                )}

                {/* ── 期末账龄(读的是冻下来的那四档,不重新分档)──────────────── */}
                <Text style={styles.sectionTitle}>{d.t.ageing} ({d.base_currency})</Text>
                <View style={styles.row}>
                    {['b0_30', 'b31_60', 'b61_90', 'b90_plus'].map((b) => (
                        <Text key={b} style={[styles.th, styles.right, { width: '25%' }] as never}>
                            {d.t['bucket_' + b]}
                        </Text>
                    ))}
                </View>
                <View style={styles.row}>
                    {['b0_30', 'b31_60', 'b61_90', 'b90_plus'].map((b) => (
                        <Text key={b} style={[styles.td, styles.right, { width: '25%' }] as never}>
                            {money(d.buckets[b] ?? 0)}
                        </Text>
                    ))}
                </View>

                <Text style={styles.note}>{d.t.frozenNote}</Text>
            </Page>
        </Document>
    )
}
