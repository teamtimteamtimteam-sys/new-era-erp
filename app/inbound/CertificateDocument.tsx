// app/inbound/CertificateDocument.tsx
// COD-1:销毁证书的版式。【第九份对外单据】。(2026-09-07)
//
// ════════════════════════════════════════════════════════════════════════════
// 【语言:一律英文,与发票、采购单同一条 —— 不跟界面语言】
// ════════════════════════════════════════════════════════════════════════════
// 可追溯报告跟界面语言,理由写在它的路由抬头:它是【应某个人的要求、在他面前
// 生成的一份说明】。销毁证书不是 —— 它是一份【签发给外部的法律文件】,收件人
// 不是这套系统的用户。Tim 的裁定:像发票一样,一律英文。
// 所以这个文件里【没有一次 t()】,而那是刻意的,不是漏了国际化。
//
// ════════════════════════════════════════════════════════════════════════════
// 【纸上没有什么 —— 这一段比"有什么"更要紧】
// ════════════════════════════════════════════════════════════════════════════
//   * 【没有任何产出批】—— 产出是 Evoltrya 的产品,不是送料方的事;
//   * 【没有化验含量】—— 要含量的供应商拿到的是另一份东西(可追溯报告);
//   * 【没有工序步骤】—— 证书不列这批料走过哪几道工;
//   * 【没有任何人名】—— "谁处理的"是【公司】,不是操作员。
//     processing_runs.created_by 一次都没有被解析过。
// 下一个想往这张纸上加一栏的人:先读这四条,它们各自都是一次裁定。
//
// ════════════════════════════════════════════════════════════════════════════
// 【三种纸,而它们的区别必须一眼看得出】
// ════════════════════════════════════════════════════════════════════════════
//   INTERNAL EXPORT —— 斜跨整页的水印【加】页脚一行明话。两样都要:水印在
//     黑白传真里可能糊掉,而页脚一行在缩略图里看不见。没有印章、没有号、
//     没有二维码。**它永远不会因为缺执照而被拒绝** —— 存档是内部的事。
//   ISSUED —— 号、签发日、印章、二维码、核验网址。
//   VOID —— 仍然印全部内容(供应商手里那张纸要对得上),另加一条作废横幅。
import React from 'react'
import { Document, Page, Text, View, Image, StyleSheet } from '@react-pdf/renderer'
import { docStyles, DocumentLetterhead, DocumentFooter, NoSignatureNote } from '@/app/components/pdf/DocumentChrome'
import { BRAND } from '@/app/components/pdf/theme'
import Stamp from '@/app/components/pdf/Stamp'
import type { LetterheadCompany } from '@/app/components/CompanyLetterhead'

export type CertificateData = {
    inbound_batch: {
        code: string
        material_code: string | null
        material_name: string | null
        quantity: number | string
        unit: string | null
        arrival_date: string | null
        purchase_order_code: string | null
    }
    supplier: { name: string | null; code: string | null }
    processing: { completed_on: string | null }
    company: {
        legal_name: string | null; registration_no: string | null
        address_lines: string | null; city: string | null
        postal_code: string | null; country: string | null
    }
    licence: { cert_no: string; issuing_body: string | null; valid_until: string | null } | null
    certificate: {
        code: string | null; status: string
        issued_at: string | null; verification_token: string | null
    } | null
}

const s = StyleSheet.create({
    // 【水印:斜跨整页,淡到不挡字,又浓到影印得出来】
    // 8% 不透明的 Ocean 在白纸上仍然看得见,而正文压在它上面照样读得清。
    // 【宽度要大到让它【不换行】】头一版给了 620pt,于是这行字折成两行、
    // 转 38 度之后左半截被裁在页外。斜对角有 1031pt 可用(A4 595×842),
    // 46pt 的这 28 个字符约占 710pt —— 一行放得下,所以容器给 900pt,
    // 再把它左移 (595−900)/2 居中。transformOrigin 显式写出来:默认值一变,
    // 水印就会从页面上滑走,而那是一个【看起来仍然成功】的失败。
    // 【容器必须【就是页宽】,字号必须小到转完还在页内】
    // 量出来的两次失败:620pt 宽让这行字折成两行,左半截转出页外被裁;
    // 改成 900pt 宽、左移居中之后仍然两头齐根切掉 —— 渲染器是【先按盒子裁,
    // 再转】的,盒子伸到页外的部分根本没画出来,转多少度都救不回来。
    // 所以盒子取 0..595(正好一页宽),字号取 34:28 个字符约 520pt,
    // 转 −38° 后横向占 520×cos38 ≈ 410pt,两边各留 90pt 余量。
    // ★ 改字号或改这行字之前先算一遍 ★ —— 裁掉的水印看起来仍然是一次成功的渲染。
    watermark: {
        position: 'absolute', top: 380, left: 0, width: 595,
        transform: 'rotate(-38deg)', transformOrigin: 'center',
        fontSize: 34, fontWeight: 'bold', letterSpacing: 2,
        color: BRAND.ocean, opacity: 0.11, textAlign: 'center',
    },
    statement: { fontSize: 10, lineHeight: 1.6, marginTop: 4, marginBottom: 16 },
    sectionLabel: {
        fontSize: 8, letterSpacing: 1.2, color: BRAND.muted,
        marginBottom: 6, textTransform: 'uppercase',
    },
    block: {
        marginBottom: 14, paddingBottom: 10,
        borderBottomWidth: 1, borderBottomColor: BRAND.hairline,
    },
    row: { flexDirection: 'row', marginBottom: 3 },
    label: { width: 150, color: BRAND.muted },
    value: { flex: 1 },
    // 【缺席是一个具名状态,不是空白格】—— 内部存档上那条"未记录"用这个样式。
    absent: { flex: 1, color: BRAND.forest },
    voidBanner: {
        marginBottom: 14, padding: 8,
        borderWidth: 1, borderColor: BRAND.text,
        fontSize: 10, fontWeight: 'bold',
    },
    attestFoot: { flexDirection: 'row', justifyContent: 'space-between', marginTop: 18 },
    verifyBox: { width: 250 },
    verifyUrl: { fontSize: 7, color: BRAND.muted, marginTop: 4 },
    qrRow: { flexDirection: 'row', alignItems: 'flex-start', marginTop: 6 },
    stampBox: { alignItems: 'center', width: 150 },
    stampCaption: { fontSize: 7, color: BRAND.muted, marginTop: 2 },
})

const dash = '—'
const show = (v: string | null | undefined) => (v && String(v).trim() !== '' ? String(v) : dash)

function Row({ label, value, absent }: { label: string; value: string; absent?: boolean }) {
    return (
        <View style={s.row}>
            <Text style={s.label}>{label}</Text>
            <Text style={absent ? s.absent : s.value}>{value}</Text>
        </View>
    )
}

export default function CertificateDocument({
    data, company, mode, verificationUrl, qrDataUrl,
}: {
    data: CertificateData
    company: LetterheadCompany
    /** internal = 内部存档(水印 + 页脚明话);issued = 签发件;void = 已作废的签发件 */
    mode: 'internal' | 'issued' | 'void'
    verificationUrl?: string | null
    qrDataUrl?: string | null
}) {
    const b = data.inbound_batch
    const issued = mode !== 'internal'
    const code = data.certificate?.code ?? null
    const addr = [company.address_lines, company.city, company.postal_code, company.country]
        .filter((x) => x && String(x).trim() !== '').join(', ')

    return (
        <Document
            title={`Certificate of Destruction ${code ?? b.code}`}
            author={company.legal_name ?? 'Evoltrya'}
        >
            <Page size="A4" style={docStyles.page}>
                {/* 【水印在最底下,而且只在内部存档上】 */}
                {mode === 'internal' && (
                    <Text style={s.watermark} fixed>
                        INTERNAL RECORD — NOT ISSUED
                    </Text>
                )}

                <DocumentLetterhead company={company} />

                <Text style={docStyles.title}>CERTIFICATE OF DESTRUCTION</Text>
                <Text style={docStyles.code}>
                    {code ? code : 'Not issued — internal record'}
                </Text>

                {mode === 'void' && (
                    <Text style={s.voidBanner}>
                        THIS CERTIFICATE HAS BEEN VOIDED. It no longer attests to the processing
                        of the material described below.
                    </Text>
                )}

                {/* ── 送料方 ───────────────────────────────────────────────── */}
                <View style={s.block}>
                    <Text style={s.sectionLabel}>Issued to</Text>
                    <Row label="Party delivering the waste" value={show(data.supplier.name)} />
                    <Row label="Their reference with us" value={show(data.supplier.code)} />
                </View>

                {/* ── 这票货 ───────────────────────────────────────────────── */}
                <View style={s.block}>
                    <Text style={s.sectionLabel}>Material received</Text>
                    {/* 【物料名原样印,不翻译】它是一条被记下来的事实,不是界面文字。 */}
                    <Row label="Material" value={
                        [b.material_code, b.material_name].filter(Boolean).join(' · ') || dash} />
                    {/* 【数量是过磅的那个数】—— inbound_batches.quantity,不是消耗量、
                        也不是供应商申报量。带壳过磅,拆壳后计量,两者本就不同。 */}
                    <Row label="Quantity received" value={`${b.quantity} ${b.unit ?? ''}`.trim()} />
                    <Row label="Date received" value={show(b.arrival_date)} />
                    <Row label="Delivery reference" value={show(b.code)} />
                    {/* 【采购单号只在有的时候才印一行】—— 没有采购单的现场收货照常工作,
                        而印一行 "—" 会让人以为丢了什么。 */}
                    {b.purchase_order_code && (
                        <Row label="Purchase order" value={b.purchase_order_code} />
                    )}
                </View>

                {/* ── 处理 ─────────────────────────────────────────────────── */}
                <View style={s.block}>
                    <Text style={s.sectionLabel}>Processing</Text>
                    <Row label="Date processing completed" value={show(data.processing.completed_on)} />
                    <Row label="Processed by" value={show(company.legal_name)} />
                    <Row label="Registered address" value={show(addr) } />
                    {/* ★【执照缺席印成一句明话,绝不是空白】★ 少一行会读成"不需要执照",
                        而那是更安静、也更坏的错。签发那一侧由 issue_cod() 按名拒,
                        所以这一行只可能出现在内部存档上。 */}
                    <Row
                        label="Licence"
                        value={data.licence
                            ? [data.licence.cert_no, data.licence.issuing_body].filter(Boolean).join(' · ')
                            : 'Not recorded — record it at /purchasing/licences'}
                        absent={!data.licence}
                    />
                </View>

                <Text style={s.statement}>
                    {company.legal_name ?? 'This company'} certifies that the material described
                    above was received from the party named above and has been processed in full
                    at the facility stated, in accordance with the licence stated.
                </Text>

                {/* ── 印章、核验网址与二维码 —— 只在签发件上 ─────────────────── */}
                {issued && (
                    <View style={s.attestFoot}>
                        <View style={s.verifyBox}>
                            <Text style={s.sectionLabel}>Verify this certificate</Text>
                            <View style={s.qrRow}>
                                {qrDataUrl ? <Image src={qrDataUrl} style={{ width: 78, height: 78 }} /> : null}
                                <View style={{ marginLeft: 10, flex: 1 }}>
                                    <Text>{code}</Text>
                                    <Text style={s.verifyUrl}>{verificationUrl ?? ''}</Text>
                                    <Text style={s.verifyUrl}>
                                        Issued {data.certificate?.issued_at?.slice(0, 10) ?? dash}
                                    </Text>
                                </View>
                            </View>
                        </View>
                        <View style={s.stampBox}>
                            <Stamp size={112} />
                        </View>
                    </View>
                )}

                <NoSignatureNote text="This document is generated by the system; no signature is required." />

                {/* 【页脚一行明话 —— 水印的另一半】水印在黑白影印下可能糊掉,
                    而这一行不会;缩略图里看不见这一行,而水印看得见。两样都要。 */}
                <DocumentFooter
                    note={
                        mode === 'internal'
                            ? 'INTERNAL RECORD — this is not an issued certificate of destruction and has not been sent to the party named above.'
                            : mode === 'void'
                              ? 'This certificate has been voided.'
                              : 'Certificate of destruction.'
                    }
                    code={code ?? b.code}
                />
            </Page>
        </Document>
    )
}
