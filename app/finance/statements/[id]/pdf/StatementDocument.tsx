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
//
// ════════════════════════════════════════════════════════════════════════════
// ★★★ PDF-1(2026-09-02):这份文档此前【印不出中文】,而没有任何东西报错 ★★★
// ════════════════════════════════════════════════════════════════════════════
// 它的 page 样式写的是 `fontFamily: 'Helvetica'`,另有六处 `'Helvetica-Bold'`。
// Helvetica 是 PDF 内置字体,**一个汉字都没有**。而发票文档里【白纸黑字写着
// 不许这么做】:「凡是要加粗的地方一律用 fontWeight: 'bold'(而不是
// fontFamily: 'Helvetica-Bold'),否则等于把那个节点换回了拉丁字体。」
//
// 实测渲染复现:`上海金属回收有限公司` 印出来是 **`wÑ^Þ6 Plø`** ——
// **不是空白、不是豆腐块,是一串看起来像模像样的重音拉丁字母。**
// 一个扫一眼的人会以为那是某个奇怪的名字,不会以为是故障。
//
// ★ 而这一行【调了字体覆盖守卫】,守卫每一次都通过 ★
// 因为守卫查的是 **Noto Sans SC 的覆盖清单**,文档嵌的却是 **Helvetica**
// —— 标签与判据问的不是同一件事。
//
// 【范围,照直说】落地时 customer_statements 【0 行】,且线上没有任何客户 /
// 供应商 / 物料 / 备注含中文(实测 2026-09-02)。所以它【还没有】糟蹋过一份
// 真的对账单 —— 它是一个装好了的陷阱,不是一场已经发生的事故。
// 但对账单的全部用途就是寄给欠款人要钱,而第一个中文客户不会带着警告出现。
//
// 处置见 app/components/pdf/fonts.ts(字体栈)与
// scripts/check-pdf-font-stack.mjs(构建期拦住这个写法,让它写不进来)。
import { Document, Page, Text, View, StyleSheet } from '@react-pdf/renderer'
import { docStyles, DocumentLetterhead, DocumentFooter } from '@/app/components/pdf/DocumentChrome'
import { BRAND } from '@/app/components/pdf/theme'
import type { LetterheadCompany } from '@/app/components/CompanyLetterhead'

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
    /** 界面语言选出来的措辞 —— 版面不拼接双语,按语言选一条 */
    t: Record<string, string>
}

// 【只剩下对账单独有的几条】page / 抬头 / 页脚 / 表头全部来自共享层;
// 下面这些是这份单据自己的构造(结转式摘要、账龄分档、SUPERSEDED 水印)。
// ★ 一条 fontFamily 都没有 —— 加粗一律 fontWeight:'bold',见文件抬头 ★
const styles = StyleSheet.create({
    meta: { fontSize: 9, marginBottom: 12 },
    sectionTitle: { fontSize: 10, fontWeight: 'bold', marginTop: 12, marginBottom: 4, color: BRAND.text },
    row: { flexDirection: 'row' },
    th: { fontWeight: 'bold', backgroundColor: BRAND.accent, padding: 4 },
    td: { padding: 4, borderBottomWidth: 0.5, borderBottomColor: BRAND.hairline },
    right: { textAlign: 'right' },
    summaryRow: { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 2 },
    summaryStrong: { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 3,
                     borderTopWidth: 1, borderTopColor: BRAND.text, marginTop: 3 },
    bold: { fontWeight: 'bold' },
    note: { fontSize: 8, color: BRAND.muted, marginTop: 10 },
    // 【被取代的那一版要认得出】水印保留原样的警示红与透明度 —— 它不是品牌装饰,
    // 是一句"你手上这份不是最新的",与送货单的 CONTROLLED 同一类。
    voidMark: { position: 'absolute', top: 260, left: 90, fontSize: 60, color: '#d33', opacity: 0.25 },
})

const money = (n: number) =>
    n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

export default function StatementDocument({ data: d }: { data: StatementDocData }) {
    const w = { doc: '16%', kind: '14%', date: '12%', due: '12%', ccy: '8%', amt: '13%', open: '13%', age: '12%' }
    return (
        <Document title={d.code}>
            <Page size="A4" style={docStyles.page}>
                {/* 被取代的那一版仍然打得开,而且要认得出来 —— 与发票作废水印同一条:
                    让手里拿着旧件的人一眼看出它已经不是最新的那一份。 */}
                {d.superseded ? <Text style={styles.voidMark}>SUPERSEDED</Text> : null}

                {/* ★【上传的 logo 不再印在这张纸上 —— 它与字标是【同一个标记】】★
                    (PDF-1,2026-09-02。实测发现,不是推断:before 渲染里两个一起出现。)
                    company_profile.logo_path 今天存的就是 EVoltrya 字标的一张【单色
                    位图】。加上共享抬头的矢量字标之后,同一个标记在一张纸上印了两遍,
                    而位图那一份还更大、居中、把版面顶开了。
                    R1 点名字标是 public/brand/evoltrya-wordmark.svg —— 所以留矢量那一份:
                    它是品牌指南里的颜色(Ocean + Forest),放大不糊,且只有一处真源。
                    【logo_path 这个字段没有被删】/finance/company 仍然可以上传与显示它;
                    变的只是【对外单据不再印它】。哪天真要在单据上印一个与字标不同的
                    标记,那是一个新决定,应当带着它自己的理由回来。 */}
                <DocumentLetterhead company={d.company} />

                <Text style={docStyles.title}>{d.t.title}</Text>
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

                {/* PDF-1:页码。对账单是八份里【最容易多页】的那一份(明细行没有上限),
                    而它此前不印页码 —— 散在收件人桌上时,没有办法知道少了哪一页。 */}
                <DocumentFooter code={d.code} />
            </Page>
        </Document>
    )
}
