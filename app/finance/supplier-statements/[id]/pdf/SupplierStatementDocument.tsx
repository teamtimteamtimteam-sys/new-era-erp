// app/finance/supplier-statements/[id]/pdf/SupplierStatementDocument.tsx
// MES-8a(2026-10-16,MES-0 Q79 · MES-8 Step 0 Q7–Q9,Tim):供应商对账单的版面。
//
// ★【它印的是【冻下来的那一行】,不是现算的】★ 数据全部来自 supplier_statements:期初 / 发生 / 贷记 / 付款 / 预付冲抵 / 期末、
//   每一笔明细(收货行标着当时是不是暂定价)、期末未结单据、挂账的付款、已收到尚未计价的收货(只有数量)、以及勾稽的两边 ——
//   都是签发那一刻抄下来的。几个月后重打这一版,纸上还是当时那些数(客户对账单的同一条)。
// ★【一律英文】(Q9)—— 与发票 / 采购单 / 销售订单 / 报价单 / 送货单 / 贷项凭证同一条:收件人不是这套系统的用户。
//   措辞只有一处来源:messages/en.ts 的 supplierStatements.doc.*(路由显式取英文那一份,见 route.ts),不在这里硬写。
//   语言的那一条裁定(客户对账单跟随界面语言,还在等 Tim)哪天做了,两份一起改。
// ★ 一条 fontFamily 都没有 —— 加粗一律 fontWeight:'bold'(PDF-1;scripts/check-pdf-font-stack.mjs 拦着)。
import { formatMoneyBare } from '@/lib/format'
import { Document, Page, Text, View, StyleSheet } from '@react-pdf/renderer'
import { docStyles, DocumentLetterhead, DocumentFooter, NoSignatureNote } from '@/app/components/pdf/DocumentChrome'
import { BRAND } from '@/app/components/pdf/theme'
import type { LetterheadCompany } from '@/app/components/CompanyLetterhead'

export type SstLine = {
    date: string; entry_code: string; kind: string; doc_code: string; amount_base: number; currency: string; amount_ccy: number
    provisional: boolean; reversal: boolean
}
export type SstOpenItem = {
    doc_kind: string; doc_code: string; doc_date: string; currency: string; doc_value_base: number; open_ccy: number; open_base: number
    days_outstanding: number; provisional: boolean
}
export type SstOnAccount = { code: string; payment_date: string; currency: string; unapplied_ccy: number; amount_base: number }
export type SstUnpriced = { doc_code: string; arrival_date: string; material_code: string | null; quantity: number; unit: string }

export type SupplierStatementDocData = {
    code: string
    supplier: { code: string; legal_name: string }
    period_start: string
    period_end: string
    base_currency: string
    opening_base: number
    charges_base: number
    credits_base: number
    payments_base: number
    prepayments_base: number
    closing_base: number
    list_base: number
    on_account_base: number
    residue_base: number
    lines: SstLine[]
    open_items: SstOpenItem[]
    on_account: SstOnAccount[]
    unpriced: SstUnpriced[]
    issued_at: string
    superseded: boolean
    company: LetterheadCompany
    noSignature: string
    t: Record<string, string>
}

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
    voidMark: { position: 'absolute', top: 260, left: 90, fontSize: 60, color: '#d33', opacity: 0.25 },
})

const qty = (n: number) => new Intl.NumberFormat('en-US', { maximumFractionDigits: 4 }).format(Number(n))
// 两位小数 + 千分位,不带币种 —— 币种写在每一列的列头 / 摘要的抬头上
const money = (n: number) => formatMoneyBare(Number(n), 'the column header / summary heading names the currency')
const signed = (n: number) => (n < 0 ? `(${money(-n)})` : money(n))

export default function SupplierStatementDocument({ data: d }: { data: SupplierStatementDocData }) {
    const w = { date: '12%', kind: '13%', doc: '16%', entry: '16%', ccy: '11%', ccyAmt: '16%', base: '16%' }
    const o = { doc: '17%', kind: '14%', date: '13%', ccy: '11%', value: '16%', open: '15%', days: '14%' }
    return (
        <Document title={d.code}>
            <Page size="A4" style={docStyles.page}>
                {d.superseded ? <Text style={styles.voidMark}>SUPERSEDED</Text> : null}
                <DocumentLetterhead company={d.company} />
                <Text style={docStyles.title}>{d.t.title}</Text>
                <Text style={styles.meta}>
                    {d.code} · {d.supplier.code} {d.supplier.legal_name} · {d.period_start} {d.t.periodSeparator} {d.period_end}
                </Text>

                <Text style={styles.sectionTitle}>{d.t.summary} ({d.base_currency})</Text>
                <View style={styles.summaryRow}><Text>{d.t.opening}</Text><Text>{money(d.opening_base)}</Text></View>
                <View style={styles.summaryRow}><Text>{d.t.charges}</Text><Text>{money(d.charges_base)}</Text></View>
                <View style={styles.summaryRow}><Text>{d.t.credits}</Text><Text>({money(d.credits_base)})</Text></View>
                <View style={styles.summaryRow}><Text>{d.t.payments}</Text><Text>({money(d.payments_base)})</Text></View>
                <View style={styles.summaryRow}><Text>{d.t.prepayments}</Text><Text>({money(d.prepayments_base)})</Text></View>
                <View style={styles.summaryStrong}>
                    <Text style={styles.bold}>{d.t.closing}</Text><Text style={styles.bold}>{money(d.closing_base)}</Text>
                </View>
                <Text style={styles.note}>{d.t.tieNote}</Text>

                <Text style={styles.sectionTitle}>{d.t.lines}</Text>
                <View style={styles.row}>
                    <Text style={[styles.th, { width: w.date }] as never}>{d.t.colDate}</Text>
                    <Text style={[styles.th, { width: w.kind }] as never}>{d.t.colKind}</Text>
                    <Text style={[styles.th, { width: w.doc }] as never}>{d.t.colDoc}</Text>
                    <Text style={[styles.th, { width: w.entry }] as never}>{d.t.colEntry}</Text>
                    <Text style={[styles.th, { width: w.ccy }] as never}>{d.t.colCcy}</Text>
                    <Text style={[styles.th, styles.right, { width: w.ccyAmt }] as never}>{d.t.colAmountCcy}</Text>
                    <Text style={[styles.th, styles.right, { width: w.base }] as never}>{d.t.colAmountBase}</Text>
                </View>
                {d.lines.length === 0 ? <Text style={styles.note}>{d.t.noMovement}</Text> : d.lines.map((l, i) => (
                    <View key={`${l.entry_code}-${i}`} style={styles.row}>
                        <Text style={[styles.td, { width: w.date }] as never}>{l.date}</Text>
                        <Text style={[styles.td, { width: w.kind }] as never}>
                            {(d.t['kind_' + l.kind] ?? l.kind) + (l.reversal ? ` · ${d.t.reversal}` : '') + (l.provisional ? ` · ${d.t.provisional}` : '')}
                        </Text>
                        <Text style={[styles.td, { width: w.doc }] as never}>{l.doc_code}</Text>
                        <Text style={[styles.td, { width: w.entry }] as never}>{l.entry_code}</Text>
                        <Text style={[styles.td, { width: w.ccy }] as never}>{l.currency}</Text>
                        <Text style={[styles.td, styles.right, { width: w.ccyAmt }] as never}>{signed(l.amount_ccy)}</Text>
                        <Text style={[styles.td, styles.right, { width: w.base }] as never}>{signed(l.amount_base)}</Text>
                    </View>
                ))}

                <Text style={styles.sectionTitle}>{d.t.openItems}</Text>
                <View style={styles.row}>
                    <Text style={[styles.th, { width: o.doc }] as never}>{d.t.colDoc}</Text>
                    <Text style={[styles.th, { width: o.kind }] as never}>{d.t.colKind}</Text>
                    <Text style={[styles.th, { width: o.date }] as never}>{d.t.colDate}</Text>
                    <Text style={[styles.th, { width: o.ccy }] as never}>{d.t.colCcy}</Text>
                    <Text style={[styles.th, styles.right, { width: o.value }] as never}>{d.t.colValue}</Text>
                    <Text style={[styles.th, styles.right, { width: o.open }] as never}>{d.t.colOpen}</Text>
                    <Text style={[styles.th, styles.right, { width: o.days }] as never}>{d.t.colDays}</Text>
                </View>
                {d.open_items.length === 0 ? <Text style={styles.note}>{d.t.nothingOutstanding}</Text> : d.open_items.map((x, i) => (
                    <View key={`${x.doc_code}-${i}`} style={styles.row}>
                        <Text style={[styles.td, { width: o.doc }] as never}>{x.doc_code}</Text>
                        <Text style={[styles.td, { width: o.kind }] as never}>{(d.t['open_' + x.doc_kind] ?? x.doc_kind) + (x.provisional ? ` · ${d.t.provisional}` : '')}</Text>
                        <Text style={[styles.td, { width: o.date }] as never}>{x.doc_date}</Text>
                        <Text style={[styles.td, { width: o.ccy }] as never}>{x.currency}</Text>
                        <Text style={[styles.td, styles.right, { width: o.value }] as never}>{money(x.doc_value_base)}</Text>
                        <Text style={[styles.td, styles.right, { width: o.open }] as never}>{money(x.open_ccy)}</Text>
                        <Text style={[styles.td, styles.right, { width: o.days }] as never}>{x.days_outstanding}</Text>
                    </View>
                ))}
                <View style={styles.summaryRow}><Text>{d.t.openTotal}</Text><Text>{money(d.list_base)}</Text></View>
                {d.on_account.length > 0 ? (
                    <>
                        <Text style={styles.sectionTitle}>{d.t.onAccount}</Text>
                        {d.on_account.map((p) => (
                            <View key={p.code} style={styles.summaryRow}>
                                <Text>{p.code} · {p.payment_date} · {p.currency} {money(p.unapplied_ccy)}</Text><Text>({money(p.amount_base)})</Text>
                            </View>
                        ))}
                    </>
                ) : null}
                {d.residue_base !== 0 ? (
                    <View style={styles.summaryRow}><Text>{d.t.residue}</Text><Text>({money(d.residue_base)})</Text></View>
                ) : null}

                <Text style={styles.sectionTitle}>{d.t.unpriced}</Text>
                {d.unpriced.length === 0 ? <Text style={styles.note}>{d.t.noUnpriced}</Text> : d.unpriced.map((u) => (
                    <View key={u.doc_code} style={styles.summaryRow}>
                        <Text>{u.doc_code} · {u.arrival_date}{u.material_code ? ` · ${u.material_code}` : ''}</Text>
                        <Text>{qty(u.quantity)} {u.unit}</Text>
                    </View>
                ))}
                <Text style={styles.note}>{d.t.unpricedNote}</Text>

                <Text style={styles.note}>{d.t.frozenNote}</Text>
                <NoSignatureNote text={d.noSignature} />
                <DocumentFooter code={d.code} />
            </Page>
        </Document>
    )
}
