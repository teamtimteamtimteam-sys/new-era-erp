// app/output/coa/CoaDocument.tsx
// MES-6b-2(2026-10-15,MES-0 Q67;MES-6b Step 0 Q10–Q14 · Q31,Tim):分析证书的版式 —— 交给买方的那张纸。
//
// 【只从快照渲染】(Q31)这个组件的入参只有 CoaSnapshot 与模式 —— 抬头(公司名、注册号、地址)也是快照里冻的那一份,不是此刻的公司资料;
//   字标是代码画的矢量(Wordmark),不是数据。于是签发件按构造与档案一致,而不是靠"渲染时读到的活数据碰巧还没变"
//   (销毁证书的 PDF 从活数据渲染,是这里要避开的先例 —— known-issues MES6B1-COD-PDF-RENDERS-LIVE)。
// 【语言:一律英文】(Q14)与发票、销毁证书同一条 —— 收件人不是这套系统的用户。所以这个文件里没有一次 t()。
// 【签发人】(Q13)「Issued by <名字>, <职位>」与签发时刻;没有签名图片。
// 【缺席是一个具名状态,不是空白格】没测的指标不印;没报的水分印 "Not reported";来料化学没人记过印 "Not recorded"。
// 【三副面孔】preview —— 斜跨整页的水印加页脚一句明话,没有号、没有签发人(它不是证书);issued;void —— 仍印全部内容,外加作废横幅。
import React from 'react'
import { Document, Page, Text, View, StyleSheet } from '@react-pdf/renderer'
import { docStyles, DocumentLetterhead, DocumentFooter } from '@/app/components/pdf/DocumentChrome'
import { BRAND } from '@/app/components/pdf/theme'
import { formatAuditStamp } from '@/lib/dates'
import type { CoaMode, CoaSnapshot } from './coaTypes'

// 每一节(s.block)都 wrap={false}:一节远小于一页,整节换页好过把小标题与表头留在上一页的页脚(实测:验收限的表头曾孤零零落在第 1 页底)
const s = StyleSheet.create({
    // 与 CertificateDocument 的水印同一套算术(盒子 = 页宽,字号小到转完还在页内)
    watermark: {
        position: 'absolute', top: 380, left: 0, width: 595,
        transform: 'rotate(-38deg)', transformOrigin: 'center',
        fontSize: 34, fontWeight: 'bold', letterSpacing: 2,
        color: BRAND.ocean, opacity: 0.11, textAlign: 'center',
    },
    sectionLabel: { fontSize: 8, letterSpacing: 1.2, color: BRAND.muted, marginBottom: 4, textTransform: 'uppercase' },
    block: { marginBottom: 6, paddingBottom: 4, borderBottomWidth: 1, borderBottomColor: BRAND.hairline },
    row: { flexDirection: 'row', marginBottom: 2 },
    label: { width: 150, color: BRAND.muted },
    value: { flex: 1 },
    absent: { flex: 1, color: BRAND.forest },
    th: { flexDirection: 'row', borderBottomWidth: 1, borderBottomColor: BRAND.hairline, paddingBottom: 3, marginBottom: 3 },
    tr: { flexDirection: 'row', marginBottom: 2 },
    cellName: { width: 140 },
    cellNum: { width: 70, textAlign: 'right' },
    cellWide: { flex: 1, paddingLeft: 12 },
    headText: { fontSize: 8, color: BRAND.muted },
    voidBanner: { marginBottom: 12, padding: 8, borderWidth: 1, borderColor: BRAND.text, fontSize: 10, fontWeight: 'bold' },
    statement: { fontSize: 9, lineHeight: 1.5, marginTop: 4, marginBottom: 10 },
    issuer: { fontSize: 10, marginTop: 8 },
})

const dash = '—'
const show = (v: string | number | null | undefined) => (v !== null && v !== undefined && String(v).trim() !== '' ? String(v) : dash)
/** 百分数照原样印(库里存几位就印几位,不四舍五入 —— 与 lib/substances 的 ppm 显示同一条:一个读数不被纸改掉) */
const pct = (v: number | string | null | undefined) => (v === null || v === undefined || String(v).trim() === '' ? dash : `${v}%`)
/** 惩罚元素旁边印 ppm(% × 10,000);整数照印,小数去掉尾零 */
function ppm(v: number | string): string {
    const n = Number(v) * 10000
    const r = Math.round(n * 1000) / 1000
    return `${r} ppm`
}
const PARTY: Record<string, string> = { ours: 'Our laboratory', counterparty: 'The buyer’s laboratory', umpire: 'Umpire laboratory' }
const BASIS: Record<string, string> = { dry: 'Dry basis', as_received: 'As received (wet)' }
const GOVERNED: Record<string, string> = {
    dispute: 'The result named when the assay dispute was resolved',
    settling_party: 'The latest final result of the party the contract settles on',
    ours: 'Our latest final result',
}
const RESULT: Record<string, string> = { within: 'Within limits', below_min: 'Below minimum', above_max: 'Above maximum', not_measured: 'Not measured' }

function Row({ label, value, absent }: { label: string; value: string; absent?: boolean }) {
    return (
        <View style={s.row}>
            <Text style={s.label}>{label}</Text>
            <Text style={absent ? s.absent : s.value}>{value}</Text>
        </View>
    )
}

/** 纸上【会印出来的每一个字符串】—— 交给字体覆盖守卫(app/output/coa/renderCoa.tsx)。漏掉一格就是给那一格开了一个洞。 */
export function coaPdfStrings(d: CoaSnapshot): { where: string; text: string | null | undefined }[] {
    const out: { where: string; text: string | null | undefined }[] = [
        { where: 'company name', text: d.company?.legal_name }, { where: 'company registration', text: d.company?.registration_no },
        { where: 'company address', text: d.company?.address_lines }, { where: 'company city', text: d.company?.city },
        { where: 'company country', text: d.company?.country }, { where: 'company postal code', text: d.company?.postal_code },
        { where: 'batch', text: d.batch.code }, { where: 'material code', text: d.batch.material_code }, { where: 'material', text: d.batch.material_name },
        { where: 'assay', text: d.assay?.code }, { where: 'laboratory', text: d.assay?.lab_name }, { where: 'certificate reference', text: d.assay?.certificate_ref },
        { where: 'sample reference', text: d.assay?.sample_ref }, { where: 'feed chemistry', text: d.chemistry?.certainty_name },
        { where: 'certificate number', text: d.certificate?.code }, { where: 'issued by', text: d.issuer?.name }, { where: 'position', text: d.issuer?.position },
    ]
    for (const c of d.composition) out.push({ where: `substance ${c.substance}`, text: c.name })
    for (const i of d.indicators) out.push({ where: `indicator ${i.code}`, text: `${i.name} ${i.unit ?? ''}` })
    if (d.sales_order) {
        out.push({ where: 'customer', text: d.sales_order.customer_name }, { where: 'sales order', text: d.sales_order.code },
                  { where: 'contract', text: d.sales_order.contract_code }, { where: 'contract title', text: d.sales_order.contract_title })
        for (const l of d.sales_order.limits) out.push({ where: `limit ${l.parameter}`, text: `${l.name} ${l.unit ?? ''}` })
    }
    return out
}

export default function CoaDocument({ data, mode }: { data: CoaSnapshot; mode: CoaMode }) {
    const b = data.batch
    const a = data.assay
    const so = data.sales_order
    const code = data.certificate?.code ?? null
    const company = {
        legal_name: data.company?.legal_name ?? '', registration_no: data.company?.registration_no ?? null,
        address_lines: data.company?.address_lines ?? null, city: data.company?.city ?? null,
        postal_code: data.company?.postal_code ?? null, country: data.company?.country ?? null,
    }
    const issuedAt = data.certificate?.issued_at ?? null
    return (
        <Document
            title={`Certificate of Analysis ${code ?? b.code}`}
            author={company.legal_name || 'Evoltrya'}
            creationDate={issuedAt ? new Date(issuedAt) : undefined}
        >
            <Page size="A4" style={docStyles.page}>
                {mode === 'preview' && (
                    <Text style={s.watermark} fixed>PREVIEW — NOT A CERTIFICATE</Text>
                )}
                <DocumentLetterhead company={company} />
                <Text style={docStyles.title}>CERTIFICATE OF ANALYSIS</Text>
                <Text style={docStyles.code}>{code ?? 'Preview — not issued'}</Text>

                {mode === 'void' && (
                    <Text style={s.voidBanner}>
                        THIS CERTIFICATE HAS BEEN VOIDED. It no longer states the analysis of the batch described below.
                    </Text>
                )}

                {so && (
                    <View style={s.block} wrap={false}>
                        <Text style={s.sectionLabel}>Issued to</Text>
                        <Row label="Customer" value={show(so.customer_name)} />
                        <Row label="Sales order" value={show(so.code)} />
                        {so.contract_code ? (
                            <Row label="Contract" value={[so.contract_code, so.contract_title].filter(Boolean).join(' · ')} />
                        ) : (
                            <Row label="Contract" value="No contract linked to this order" absent />
                        )}
                    </View>
                )}

                <View style={s.block} wrap={false}>
                    <Text style={s.sectionLabel}>Product</Text>
                    <Row label="Batch" value={b.code} />
                    <Row label="Material" value={[b.material_code, b.material_name].filter(Boolean).join(' · ') || dash} />
                    <Row label="Quantity" value={`${b.quantity} ${b.unit ?? ''}`.trim()} />
                    <Row label="Production date" value={show(b.output_date)} />
                    {/* N38:来料的化学有多确定 —— 照直说,没人记过就说没人记过 */}
                    <Row label="Feed chemistry" value={data.chemistry
                        ? `${data.chemistry.certainty_name}${data.chemistry.inbound_leaves === 0 ? ' (no recorded feed batches)' : ` (${data.chemistry.inbound_leaves} feed batch${data.chemistry.inbound_leaves === 1 ? '' : 'es'})`}`
                        : 'Not recorded'}
                        absent={!data.chemistry || data.chemistry.certainty === 'not_recorded'} />
                </View>

                <View style={s.block} wrap={false}>
                    <Text style={s.sectionLabel}>Analysis</Text>
                    {a ? (
                        <>
                            <Row label="Assay" value={a.code} />
                            <Row label="Assay date" value={show(a.assay_date)} />
                            <Row label="Laboratory" value={show(a.lab_name)} absent={!a.lab_name} />
                            <Row label="Laboratory certificate" value={show(a.certificate_ref)} />
                            {a.sample_ref ? <Row label="Sample" value={a.sample_ref} /> : null}
                            <Row label="Reported by" value={PARTY[a.result_party ?? ''] ?? show(a.result_party)} />
                            <Row label="Weight basis" value={a.weight_basis ? (BASIS[a.weight_basis] ?? a.weight_basis) : 'Not stated'} absent={!a.weight_basis} />
                            <Row label="Moisture" value={a.moisture_pct === null || a.moisture_pct === undefined ? 'Not reported' : `${a.moisture_pct}%`}
                                 absent={a.moisture_pct === null || a.moisture_pct === undefined} />
                            <Row label="Result stated" value={GOVERNED[a.basis] ?? a.basis} />
                        </>
                    ) : (
                        <Row label="Assay" value="No final assay" absent />
                    )}
                </View>

                <View style={s.block} wrap={false}>
                    <Text style={s.sectionLabel}>Composition</Text>
                    <View style={s.th}>
                        <Text style={[s.cellName, s.headText]}>Substance</Text>
                        <Text style={[s.cellNum, s.headText]}>Content</Text>
                        <Text style={[s.cellWide, s.headText]}> </Text>
                    </View>
                    {data.composition.map((c) => (
                        <View style={s.tr} key={c.substance} wrap={false}>
                            <Text style={s.cellName}>{c.symbol ? `${c.name} (${c.symbol})` : c.name}</Text>
                            <Text style={s.cellNum}>{pct(c.content_pct)}</Text>
                            <Text style={s.cellWide}>{c.role === 'penalty_element' ? ppm(c.content_pct) : ''}</Text>
                        </View>
                    ))}
                </View>

                {data.indicators.length > 0 && (
                    <View style={s.block} wrap={false}>
                        <Text style={s.sectionLabel}>Quality indicators</Text>
                        {data.indicators.map((i) => (
                            <Row key={i.code} label={i.name} value={`${i.value}${i.unit ? ' ' + i.unit : ''}`} />
                        ))}
                    </View>
                )}

                {so && so.quality_limit_basis === 'per_parameter' && (
                    <View style={s.block} wrap={false}>
                        <Text style={s.sectionLabel}>Contract quality limits</Text>
                        <View style={s.th}>
                            <Text style={[s.cellName, s.headText]}>Parameter</Text>
                            <Text style={[s.cellNum, s.headText]}>Minimum</Text>
                            <Text style={[s.cellNum, s.headText]}>Maximum</Text>
                            <Text style={[s.cellNum, s.headText]}>Measured</Text>
                            <Text style={[s.cellWide, s.headText]}>Judgement</Text>
                        </View>
                        {so.limits.map((l) => {
                            const j = so.judgements.find((x) => x.parameter === l.parameter)
                            const u = l.unit ? ` ${l.unit}` : ''
                            return (
                                // 一行不跨页 —— 一条验收限被页尾劈成两半,读起来像两条
                                <View style={s.tr} key={l.parameter} wrap={false}>
                                    <Text style={s.cellName}>{l.name}</Text>
                                    <Text style={s.cellNum}>{l.min_value === null ? dash : `${l.min_value}${u}`}</Text>
                                    <Text style={s.cellNum}>{l.max_value === null ? dash : `${l.max_value}${u}`}</Text>
                                    <Text style={s.cellNum}>{j && j.value !== null ? `${j.value}${u}` : dash}</Text>
                                    <Text style={s.cellWide}>{j ? `${RESULT[j.result] ?? j.result} (${j.assay_code})` : 'Not judged'}</Text>
                                </View>
                            )
                        })}
                    </View>
                )}
                {so && so.quality_limit_basis === 'none_agreed' && (
                    <Text style={s.statement}>The contract for this order states no quality limits.</Text>
                )}

                {/* 证明那一句与签发人是一块,不跨页 —— 只剩"Issued by"一行落到下一页时,那一页读起来像一张没有内容的证书 */}
                <View wrap={false}>
                    <Text style={s.statement}>
                        {company.legal_name || 'This company'} certifies that the analysis stated above is that of the batch described,
                        as reported in the laboratory result named.
                    </Text>

                    {mode !== 'preview' && data.issuer && (
                        <View>
                            <Text style={s.issuer}>Issued by {data.issuer.name}, {data.issuer.position}</Text>
                            <Text style={s.headText}>Issued {formatAuditStamp(issuedAt) ?? dash} (Singapore time)</Text>
                        </View>
                    )}
                </View>

                <DocumentFooter
                    note={mode === 'preview'
                        ? 'PREVIEW — this is not a certificate of analysis and has not been issued.'
                        : mode === 'void' ? 'This certificate of analysis has been voided.' : 'Certificate of analysis.'}
                    code={code ?? b.code}
                />
            </Page>
        </Document>
    )
}
