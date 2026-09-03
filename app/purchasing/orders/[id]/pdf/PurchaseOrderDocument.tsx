// app/purchasing/orders/[id]/pdf/PurchaseOrderDocument.tsx
// 采购单 PDF(A4 纵向)。规格:docs/purchase-order-document.md。
//
// 【文案一律硬编码英文,不接 i18n】—— 与发票同一条既定决策:这是发给供应商的单据
// 正文,不是界面标签。界面语言切成中文时签发的 PDF 也必须是英文。
//
// 【字体、CJK 断词、样式基调全部来自发票文档】—— import 那个模块就完成了字体注册与
// 断词回调(模块级副作用,见 InvoiceDocument.tsx 抬头)。这里不重复注册。
//
// 【单据币种,只有单据币种】(§D)po_document_data 里根本没有 fx_rate 与本位币数字,
// 所以本组件想印也印不出来 —— 这是把约束放在数据层而不是靠组件自律。
import React from 'react'
import { Document, Page, Text, View, StyleSheet } from '@react-pdf/renderer'
import { type CompanyProfile } from '@/app/finance/invoices/[id]/pdf/InvoiceDocument'
import { BRAND } from '@/app/components/pdf/theme'
import { docStyles, DocumentLetterhead, DocumentFooter, NoSignatureNote } from '@/app/components/pdf/DocumentChrome'
import { noSignatureEn } from '@/app/components/pdf/noSignature'

export type PoCommittedTerms = {
    source_formula_code: string
    source_formula_name: string | null
    price_basis: string
    average_days: number | null
    treatment_charge_usd_per_tonne: number
    flat_discount_pct: number
    metals: { metal: string; payable_pct: number }[]
}

export type PoDocLine = {
    line_no: number
    material_name: string
    quantity: number
    unit: string
    unit_price: number | null
    amount_ccy: number
    expected_assay: Record<string, unknown> | null
    notes: string | null
    // PO-GST-1:行上的税。tax_code 为 null = 这一行开在采购单携带税之前,
    // 或开在 GST 未注册的时候 —— **不是零税**。
    tax_code: string | null
    tax_rate_pct: number | null
    tax_amount_ccy: number | null
    price_is_manual_estimate: boolean
    pricing_status: 'provisional_committed' | 'provisional_uncommitted' | 'fixed' | 'not_priced'
    committed_terms: PoCommittedTerms | null
}

export type PoDocData = {
    code: string
    order_date: string
    expected_delivery_date: string | null
    currency: string
    incoterm: string | null
    terms_text: string | null
    notes: string | null
    estimated_total_ccy: number
    // PO-GST-1:净额 / 税 / 含税额 —— 三个数都来自 po_document_data,
    // 屏幕读的是同一支函数所依据的同两列。gross 由函数加一次,不另存。
    tax_total_ccy: number | null
    gross_total_ccy: number
    carries_tax: boolean
    has_out_of_scope_line: boolean
    supplier: { legal_name: string; address: string | null; country: string | null; tax_id: string | null }
    lines: PoDocLine[]
    payment_terms: {
        seq: number
        label: string
        percentage: number | null
        fixed_amount_ccy: number | null
        trigger_event: string | null
        trigger_phrase: string | null
        due_date: string | null
        notes: string | null
    }[]
}

// EQP-1c-b-fu2:付款触发条件印成一句【完整的英文】,而不是把枚举值原样铺开
// 再在前面补一个 "on"。
// 【走查看到的是 "on on shipment"】,而第三行印的是 "on post assay" —— 一个 on。
// 【错的只有模板这一半,数据那一半不存在】on_shipment 作为一个枚举键完全正确,
// 而屏幕那一侧【早就】把它映射成了 "On shipment"(当时走的是那族 i18n 标签键);
// 只有这份 PDF 从来没用过那份映射:它 replace('_',' ') 之后自己补了一个介词。
// 所以修的是这一处,一个地方,而且【不动任何已播下的触发值】。
// 【未知的值不补介词】—— 将来加一种触发条件时,最坏的结果是印出它的原文,
// 而不是再长出一个 "on on"。
// EQP-PAY-1:那张手写映射退役了 —— 介词短语来自字典(payment_trigger_events.phrase_en),
// 由 po_document_data 随每一期一起送过来。
//
// 【为什么它曾经在这里】这份 PDF 从来没用过屏幕那一侧的那族 i18n 标签映射:
// 它自己 replace('_',' ') 之后补一个 "on",于是印出过 "on on shipment"。
// 那次修复加了这张映射,而它成了同一份清单的第九个副本 —— 加一种里程碑要改九处。
//
// 【拿不到短语时印原文,不补介词】与那次修复的处置逐字相同:最坏的结果是印出
// 一个码,而不是再长出一个 "on on"。
function triggerPhrase(ev: string, phrase: string | null | undefined): string {
    return phrase ?? ev.replace(/_/g, ' ')
}

const num = (n: number, dp = 2) =>
    new Intl.NumberFormat('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp }).format(n)

// 每一行"定价状态"要印的那句话 —— 与 po_document_data 的裁决一一对应(§B)。
// 【provisional_uncommitted 不印条款】:公式今天的条款不是当时的承诺,印上去是编造。
export function pricingStatusText(line: PoDocLine): string[] {
    switch (line.pricing_status) {
        case 'fixed':
            return ['Price: FIXED']
        case 'not_priced':
            return ['Price: NOT STATED']
        case 'provisional_uncommitted':
            return ['Price: PROVISIONAL — terms not committed; settlement to be agreed separately']
        case 'provisional_committed': {
            const t = line.committed_terms as PoCommittedTerms
            const basis =
                t.price_basis === 'average'
                    ? `${t.average_days}-day average market price`
                    : 'spot market price'
            const metals = t.metals
                .map((m) => `${m.metal.toUpperCase()} ${num(m.payable_pct, 1)}%`)
                .join(', ')
            const out = [
                'Price: PROVISIONAL — PENDING ASSAY',
            ]
            if (line.price_is_manual_estimate) {
                // FIN-26 的那次误读:数字是手填的估算,结算规则是公式 —— 两件事都要说
                out.push('Unit price shown is a manual estimate; settlement follows the committed terms below.')
            }
            out.push(
                `Settles on formula ${t.source_formula_code}${t.source_formula_name ? ` (${t.source_formula_name})` : ''}: ` +
                    `payable ${metals}; ${basis}; ` +
                    // USD/t 是金属市场报价惯例(AGENTS.md FX 规则),不是本位币假设
                    `treatment charge ${num(t.treatment_charge_usd_per_tonne)} USD/t` +
                    (t.flat_discount_pct > 0 ? `; discount ${num(t.flat_discount_pct, 1)}%` : '')
            )
            return out
        }
    }
}

// PDF-1:page / 抬头 / 表头 / 页脚来自共享层;下面只剩采购单【自己】的构造
// (承诺定价条款那一行、付款里程碑、设备单的列头切换)。颜色一律走品牌 token ——
// 见 app/components/pdf/theme.ts,那里写着 Ocean 与 Forest 为什么不许当正文色。
const styles = StyleSheet.create({
    muted: { color: BRAND.muted },
    // 标题:18pt 粗体属于"大号文字",Ocean 实测 3.75:1 过 3:1 门槛。
    title: { fontSize: 18, fontWeight: 'bold', letterSpacing: 1.5, color: BRAND.ocean, marginTop: 4 },
    // 抬头块与下面的 SUPPLIER 之间要留白 —— 实测两者原本挤在一起
    headBlock: { marginBottom: 14 },
    section: { marginBottom: 12 },
    sectionTitle: { fontSize: 8, fontWeight: 'bold', color: BRAND.muted, marginBottom: 3, textTransform: 'uppercase' },
    row: { flexDirection: 'row' },
    metaBox: { flexDirection: 'row', gap: 24, marginBottom: 12 },
    table: { borderTopWidth: 1, borderColor: BRAND.ocean },
    th: { fontWeight: 'bold', paddingVertical: 4, backgroundColor: BRAND.accent },
    tr: { flexDirection: 'row', borderBottomWidth: 0.5, borderColor: BRAND.hairline, paddingVertical: 4 },
    cNo: { width: '6%' },
    cDesc: { width: '46%', paddingRight: 6 },
    cQty: { width: '14%', textAlign: 'right' },
    cPrice: { width: '16%', textAlign: 'right' },
    cAmt: { width: '18%', textAlign: 'right' },
    statusLine: { color: BRAND.muted, fontSize: 8, marginTop: 2 },
    totalRow: { flexDirection: 'row', justifyContent: 'flex-end', marginTop: 8 },
    totalLabel: { fontWeight: 'bold', marginRight: 12 },
})

export default function PurchaseOrderDocument({
    data,
    company,
    isEquipment = false,
}: {
    data: PoDocData
    company: CompanyProfile
    // EQP-1c-b-fu2:这张单是不是设备单 —— 只用来决定明细的【列头】。
    // 【为什么不放进 po_document_data】那个函数回答的是"这张单印出来是什么内容",
    // 而"这张单是什么种类"是一个【新的】问题;把它塞进去等于让那份共用实现
    // 多回答一件它此前不回答的事,而调用方(路由)手上本来就有这个事实。
    // 值那一半仍然共用 po_document_data —— 机器的名字早就 COALESCE 过资产描述。
    isEquipment?: boolean
}) {
    // STATEMENT-1:抬头改用共用组件 CompanyLetterhead(variant='inline')。
    // 【版式一个像素没动】样式对象仍由本文件传进去(companyName / muted),
    // 组件只负责"由哪些部分组成、国家印不印" —— 那一份规则从此只有一处,
    // 而对账单是它的第三个调用方(见组件抬头与 known-issues 的 EQP-1c-b-fu2)。
    return (
        <Document title={`Purchase Order ${data.code}`}>
            <Page size="A4" style={docStyles.page}>
                {/* PDF-1:抬头改用共享层 —— 八份对外单据同一份实现。
                    【此前是 variant='inline'(地址一行逗号,标题在右)】现在与另外七份
                    一样是字标在左、公司资料在右,标题另起一行。电话与邮箱不再单独印:
                    stacked 变体本身就包含它们,留着会印两遍。
                    【标题与单据号一个字没改】'PURCHASE ORDER' / 单号 / 'Date:' 逐字保留。 */}
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
                <View fixed style={styles.headBlock}>
                    <DocumentLetterhead company={company} />
                    <Text style={styles.title}>PURCHASE ORDER</Text>
                    <Text>{data.code}</Text>
                    <Text>Date: {data.order_date}</Text>
                </View>

                <View style={styles.section}>
                    <Text style={styles.sectionTitle}>Supplier</Text>
                    <Text style={{ fontWeight: 'bold' }}>{data.supplier.legal_name}</Text>
                    {data.supplier.address ? <Text>{data.supplier.address}</Text> : null}
                    {data.supplier.country ? <Text>{data.supplier.country}</Text> : null}
                    {data.supplier.tax_id ? <Text>Tax ID: {data.supplier.tax_id}</Text> : null}
                </View>

                <View style={styles.metaBox}>
                    <View>
                        <Text style={styles.sectionTitle}>Expected delivery</Text>
                        <Text>{data.expected_delivery_date ?? '—'}</Text>
                    </View>
                    <View>
                        <Text style={styles.sectionTitle}>Incoterm</Text>
                        <Text>{data.incoterm ?? '—'}</Text>
                    </View>
                    <View>
                        <Text style={styles.sectionTitle}>Currency</Text>
                        <Text>{data.currency}</Text>
                    </View>
                </View>

                <View style={[styles.table, styles.section]}>
                    <View style={[styles.tr, styles.th]}>
                        <Text style={styles.cNo}>#</Text>
                        {/* EQP-1c-b-fu2:一台机器上面写着 "Material" 是一个【说错了的】
                            列头,不是一个空列。一张单只有一种(EQP-1a 的 N1),
                            所以整列跟着单据走。
                            【为什么这里是一个英文字面量,而屏幕那边走 i18n】
                            这份 PDF 是发给供应商的对外单据,全篇英文、没有翻译器 ——
                            两边【本来就】不是同一套文字机制,而【值】那一半仍然
                            共用 po_document_data(material_name 已经 COALESCE 过
                            资产描述)。所以屏幕与纸不会各说各话。 */}
                        <Text style={styles.cDesc}>{isEquipment ? 'Machine' : 'Material'}</Text>
                        <Text style={styles.cQty}>Quantity</Text>
                        <Text style={styles.cPrice}>Unit price</Text>
                        <Text style={styles.cAmt}>Amount ({data.currency})</Text>
                    </View>
                    {data.lines.map((l) => (
                        <View key={l.line_no} style={styles.tr} wrap={false}>
                            <Text style={styles.cNo}>{l.line_no}</Text>
                            <View style={styles.cDesc}>
                                <Text>{l.material_name}</Text>
                                {pricingStatusText(l).map((s, i) => (
                                    <Text key={i} style={styles.statusLine}>{s}</Text>
                                ))}
                                {l.notes ? <Text style={styles.statusLine}>{l.notes}</Text> : null}
                            </View>
                            <Text style={styles.cQty}>
                                {num(l.quantity, 0)} {l.unit}
                            </Text>
                            <Text style={styles.cPrice}>{l.unit_price === null ? '—' : num(l.unit_price)}</Text>
                            <Text style={styles.cAmt}>{num(l.amount_ccy)}</Text>
                        </View>
                    ))}
                    {/* ★★【PO-GST-1:这张纸上不再有一个孤零零的「Estimated total」】★★
                        供应商拿到的必须是他将要开票的那个数。净额 / GST / 含税额
                        三行分开印,含税额加粗 —— 那一行才是承诺出去的现金。
                        【不带税的历史单据仍然只印一行】carries_tax 为 false 时
                        (本刀之前开的单,或 GST 未注册时开的单)不印一个 0.00 的
                        GST 行 —— 那会是一句断言,而真相是"这张单没有算过税"。 */}
                    {data.carries_tax ? (
                        <>
                            <View style={styles.totalRow}>
                                <Text style={styles.totalLabel}>Subtotal (excl. GST) ({data.currency})</Text>
                                <Text>{num(data.estimated_total_ccy)}</Text>
                            </View>
                            <View style={styles.totalRow}>
                                <Text style={styles.totalLabel}>GST ({data.currency})</Text>
                                <Text>{num(data.tax_total_ccy ?? 0)}</Text>
                            </View>
                            <View style={styles.totalRow}>
                                <Text style={[styles.totalLabel, { fontWeight: 'bold' }]}>
                                    Total payable (incl. GST) ({data.currency})
                                </Text>
                                <Text style={{ fontWeight: 'bold' }}>{num(data.gross_total_ccy)}</Text>
                            </View>
                        </>
                    ) : (
                        <View style={styles.totalRow}>
                            <Text style={styles.totalLabel}>Estimated total ({data.currency})</Text>
                            <Text>{num(data.estimated_total_ccy)}</Text>
                        </View>
                    )}
                </View>

                {/* ★【①b:不在范围内的行,要在纸上说清 GST 付给谁】★
                    一条 OP 行的 GST 不是零 —— 是【不付给这家供应商】。
                    进口货物的 GST 在清关时付给新加坡海关。不说这一句,
                    一个读到「GST 0.00」的供应商会以为这批货完全不涉税。 */}
                {data.has_out_of_scope_line ? (
                    <View style={styles.section}>
                        <Text>
                            Lines marked out-of-scope (OP) carry no Singapore GST payable to you.
                            Import GST on these goods, if any, is paid by us to Singapore Customs
                            at the point of clearance.
                        </Text>
                    </View>
                ) : null}

                {data.payment_terms.length > 0 ? (
                    <View style={styles.section}>
                        <Text style={styles.sectionTitle}>Payment schedule</Text>
                        {data.payment_terms.map((t) => (
                            <Text key={t.seq}>
                                {t.seq}. {t.label} —{' '}
                                {t.percentage !== null
                                    ? `${num(t.percentage, 1)}%`
                                    : `${num(t.fixed_amount_ccy ?? 0)} ${data.currency}`}
                                {t.trigger_event ? ` — ${triggerPhrase(t.trigger_event, t.trigger_phrase)}` : ''}
                                {t.due_date ? ` — due ${t.due_date}` : ''}
                                {t.notes ? ` (${t.notes})` : ''}
                            </Text>
                        ))}
                    </View>
                ) : null}

                {data.terms_text ? (
                    <View style={styles.section}>
                        <Text style={styles.sectionTitle}>Terms</Text>
                        <Text>{data.terms_text}</Text>
                    </View>
                ) : null}
                {data.notes ? (
                    <View style={styles.section}>
                        <Text style={styles.sectionTitle}>Notes</Text>
                        <Text>{data.notes}</Text>
                    </View>
                ) : null}

                <NoSignatureNote text={noSignatureEn('purchaseOrder')} />

                {/* PDF-1:页脚改用共享层,并【加上页码】—— 采购单带承诺定价条款与
                    付款里程碑,常常多页,而它此前不印页码。文案一个字没改。 */}
                {/* 【不传 code】这句说明本身就以单号收尾,再传一次会把它印两遍 */}
                <DocumentFooter
                    note={`${company.legal_name} — Purchase Order ${data.code}. Provisional prices settle on the committed terms stated per line.`}
                />
            </Page>
        </Document>
    )
}
