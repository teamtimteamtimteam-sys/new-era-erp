#!/usr/bin/env node
// scripts/check-pdf-routes.mjs
// ════════════════════════════════════════════════════════════════════════════
// MES-7a-1(2026-10-15,F11,Tim):两条证书 PDF 路由的行为 —— 一支可以反复跑的检查(MES-8a 加第三条:供应商对账单)
// ════════════════════════════════════════════════════════════════════════════
// 【为什么有它】MES-6b-2 close-out 记过一个弱处(W1):「PDF 照快照渲染」「存下的字节与记下的哈希对不上 → 409」是【路由】(TypeScript)的行为,
//   SQL fixture 够不着 —— 它们只被一次性的线上证明证过一次,而那次之后没有任何东西会再问一遍。Tim 的 F11:给它们一支可重复的检查,
//   销毁证书在 F10 之后同一套。
// 【怎么问】把两条路由的处理函数【原样】装进来(jiti,与线上证明读 renderCoa 同一个办法),只换掉两样够不着的东西:
//   '@/lib/supabase/server' → scripts/pdf-routes/fake-supabase.mjs(内存里的几行、记账的 rpc、一个 Map 当桶)·
//   '@/lib/i18n/server' → scripts/pdf-routes/i18n-server.mjs(拒绝说成"键 + 参数" —— 这里比的是码,措辞归 check-i18n)。
//   渲染、哈希、字体守卫、react-pdf 全是真的;产出的 PDF 用 pypdf 抽出纸上的字来比(两次渲染同一份快照字节不同 —— 字体子集的标签 ——
//   所以"从快照渲染"按【字】证,不按字节证:MES-6b-2 交回 §6 第 15 条)。【不连任何库、不碰网】,在任何地方都不留下东西。
// 【问什么】
//   分析证书  COA-SNAP   签发照 issue_coa 返回的那一份快照渲染(活数据里的客户名不上纸)
//             COA-ISSUER 签发人的名字里有一个画不出来的字 → 400,issue_coa 一次都没被调(什么都不铸)
//             COA-409    存下的字节与记下的哈希对得上 → 200 且逐字节相同;被改过 → 409
//             COA-SAVE   【存 PDF】:已签发、没有字节 → 照存下的快照渲染并记哈希;已有字节 → 拒、什么都不传
//   销毁证书  COD-SNAP   签发照 issue_cod 返回的快照渲染,抬头取快照里的公司(活的供应商名与公司名不上纸)
//             COD-STORED 不带 ?cod= 打开一张已签发的 → 流存下的字节(不重新渲染);作废的同样;被改过 → 409
//             COD-PENDING 还没签发的 → 内部存档,照活数据渲染、带水印
//             COD-FONT   活数据里有画不出来的字 → 签发之前就 400,issue_cod 一次都没被调;快照里有 → 渲染之内拒,什么都不传
//   供应商对账单(MES-8a,Q9)SST-FROZEN 只从冻下来的那一行渲染(收件人、抬头、暂定价标记、没计价的收货只有数量;英文;不读活表)
//             SST-409    ?version=N 流存下的字节;被改过 → 409
//             SST-ARCHIVE 存档:传一次、记下的是那串字节的 sha256、键在 <对账单 id>/ 之下;记被拒 → 刚传的对象删掉
//   合规包(MES-8b-1,Q16)CPK-FROZEN 只从冻下来的 payload 渲染(抬头取 payload 里冻下来的公司;事故一节没有受伤的细节;第 7、8 节照原样说 V26 / V27;
//                          英文;不读活表)
//             CPK-409    ?version=N 流存下的字节;被改过 → 409
//             CPK-ARCHIVE 存档:传一次、记下的是那串字节的 sha256、键在 <包 id>/ 之下;记被拒 → 刚传的对象删掉
// 【故障注入格,每一次都跑】(check_grants.py 的先例:一支从没见过自己红的检查只是安静,不是可靠)
//   把路由源码改坏一处(回读活数据 · 不校验哈希 · 不问签发人 · 抬头取活的 · 不流字节 · 不先问字体),写成一份临时副本,对着它再跑一遍 ——
//   每一格必须让【它点名的那一个样例】红;有一格没红,本检查自己就红(那一格瞎了)。`--no-faults` 只跑干净那一遍(给人调试用)。
// 【覆盖】样例数与声明的样例数对不上 → 红;pypdf 读不出字 → 红(读不出来不是"没有那个字")。
// 退出码:0 全绿 · 1 有样例红 · 3 量具自己坏了(装不进路由、没有 pypdf、故障格没有咬人)
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :两条路由文件的【源码】(app/output/[id]/coa/pdf/route.tsx · app/inbound/[id]/cod/pdf/route.tsx),装进来跑,
//                   对着一个【假的】数据库客户端与一个内存里的桶;以及它们产出的 PDF 上 pypdf 抽得出的字。
//   我声称管的是   :线上那两条路由的行为 —— 照快照渲染、流存下的字节、哈希对不上 409、先过字体再签发。
//   两者不同之处   :★ **我不问数据库。** 函数(issue_coa · issue_cod · coa_issuer · record_*_issue)返回什么、拒什么,是 fixture 195 / 264 的事;
//                   这里假设它们照约定回答,只问路由【拿到答案之后】做了什么。桶的读写策略也不在这里(那是线上证明的事,桶不在镜像里)。
//                   ★ 路由的 import 若多了一样够不着的东西(新的服务端模块),装不进来就红(退 3)—— 不会悄悄跳过。
// ════════════════════════════════════════════════════════════════════════════
import { createJiti } from 'jiti'
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const COA_ROUTE = join(ROOT, 'app/output/[id]/coa/pdf/route.tsx')
const COD_ROUTE = join(ROOT, 'app/inbound/[id]/cod/pdf/route.tsx')
const SST_ROUTE = join(ROOT, 'app/finance/supplier-statements/[id]/pdf/route.ts')
const CPK_ROUTE = join(ROOT, 'app/compliance/packs/[id]/pdf/route.ts')
const TMP = join(ROOT, 'scripts/pdf-routes', `.tmp-${process.pid}`)
const sha = (b) => createHash('sha256').update(b).digest('hex')

const React = (await import('react')).default
globalThis.React = React
const jiti = createJiti(import.meta.url, {
    jsx: true, interopDefault: true, moduleCache: false,
    alias: {
        '@/lib/supabase/server': join(ROOT, 'scripts/pdf-routes/fake-supabase.mjs'),
        '@/lib/i18n/server': join(ROOT, 'scripts/pdf-routes/i18n-server.mjs'),
        'server-only': join(ROOT, 'scripts/pdf-routes/empty.mjs'),
        '@': ROOT,
    },
})

function pdfText(buf) {
    const f = join(TMP, `t-${Math.random().toString(36).slice(2)}.pdf`)
    writeFileSync(f, buf)
    const r = spawnSync('python3', ['-c', 'import pypdf,sys\nr=pypdf.PdfReader(sys.argv[1])\nprint("\\n".join(p.extract_text() for p in r.pages))', f],
                        { encoding: 'utf8' })
    rmSync(f, { force: true })
    if (r.status !== 0) throw new Error(`MEASURE|pypdf could not read the bytes: ${(r.stderr || '').slice(0, 200)}`)
    return r.stdout
}

// ── 样例数据 ────────────────────────────────────────────────────────────────
const OB = '11111111-1111-4111-8111-111111111111', COA = '22222222-2222-4222-8222-222222222222', SO = '33333333-3333-4333-8333-333333333333'
const IB = '44444444-4444-4444-8444-444444444444', COD = '55555555-5555-4555-8555-555555555555', COD_V = '66666666-6666-4666-8666-666666666666'
const company = (name) => ({ legal_name: name, registration_no: '201912345K', address_lines: '1 Recovery Road', city: 'Singapore',
    postal_code: '628000', country: 'Singapore', phone: '+65 6000 0000', email: 'ops@example.test', website: 'example.test' })
const coaSnap = (customer, issuerName = 'Tan') => ({
    company: company('Frozen Recovery Pte. Ltd.'),
    batch: { id: OB, code: 'CPW-2026-0012', material_code: 'MAT-CPW', material_name: 'Cathode powder', quantity: 500, unit: 'kg', output_date: '2026-10-01' },
    assay: { id: 'a', code: 'ASY-2026-0140', assay_date: '2026-10-02', lab_code: null, lab_name: null, certificate_ref: 'CERT-1', sample_ref: null,
             result_party: 'ours', weight_basis: 'dry', moisture_pct: 6, is_final: true, basis: 'settling_party', dispute_id: null },
    composition: [{ substance: 'ni', name: 'Nickel', symbol: 'Ni', role: 'payable_metal', content_pct: 20 }],
    indicators: [],
    chemistry: { certainty: 'single_known', certainty_name: 'Single and known', inbound_leaves: 1, leaves_single_known: 1, leaves_mixed: 0,
                 leaves_not_recorded: 0, leaves_unknown_pending: 0 },
    sales_order: { id: SO, code: 'SO-2026-0031', customer_name: customer, contract_code: 'CON-2026-0004', contract_title: 'Offtake',
                   quality_limit_basis: 'none_agreed', limits: [], judgements: [] },
    certificate: { id: COA, code: 'COA-2026-0001', status: 'issued', issued_at: '2026-10-15T06:00:00Z' },
    issuer: { name: issuerName, position: 'Quality Manager' },
})
const codSnap = (supplier, co, status = 'issued') => ({
    inbound_batch: { id: IB, code: 'IN-2026-0201', material_code: 'MAT-EVB', material_name: 'EV battery modules', quantity: 1200, unit: 'kg',
                     arrival_date: '2026-09-01', purchase_order_code: 'PO-2026-0011' },
    supplier: { name: supplier, code: 'SUP-0007' },
    processing: { completed_on: '2026-09-05' },
    company: company(co),
    licence: { cert_no: 'WDL-21-2-5380', issuing_body: 'NEA', valid_until: '2027-01-01', valid_from: '2025-01-01', scope: 'battery' },
    certificate: status === 'pending' ? { id: COD, code: null, status: 'pending', issued_at: null, verification_token: null }
        : { id: COD, code: 'COD-2026-0003', status, issued_at: '2026-10-15T06:00:00Z', issued_by: 'u',
            verification_token: '77777777-7777-4777-8777-777777777777', completed_on: '2026-09-05' },
    provenance: { run_ids: [] },
})

const SST = '88888888-8888-4888-8888-888888888888'
const sstRow = (over = {}) => ({ id: SST, code: 'SST-2026-0001', supplier_id: 'sup-1', supplier_code: 'SUP-2026-0002', supplier_name: 'Frozen Supplier Pte Ltd',
    company: company('Frozen Recovery Pte. Ltd.'), period_start: '2026-09-01', period_end: '2026-09-30', base_currency: 'SGD',
    opening_base: 1000, charges_base: 500, credits_base: 0, payments_base: 300, prepayments_base: 0, closing_base: 1200,
    list_base: 1200, on_account_base: 0, residue_base: 0,
    lines: [{ date: '2026-09-03', entry_code: 'JE-2026-0101', kind: 'receipt', doc_code: 'IN-2026-0301', amount_base: 500, currency: 'SGD', amount_ccy: 500,
              provisional: true, reversal: false }],
    open_items: [{ doc_kind: 'inbound', doc_code: 'IN-2026-0301', doc_date: '2026-09-03', currency: 'SGD', doc_value_base: 500, open_ccy: 500, open_base: 500,
                   days_outstanding: 27, provisional: true }],
    on_account: [], unpriced: [{ doc_code: 'IN-2026-0302', arrival_date: '2026-09-20', material_code: 'MAT-EVB', quantity: 800, unit: 'kg' }],
    issued_at: '2026-10-01T02:00:00Z', superseded_at: null, ...over })

const CPK = '99999999-9999-4999-8999-999999999999'
const cpkPayload = () => ({ month: '2026-09', period_start: '2026-09-01', period_end: '2026-09-30', locked_before: '2026-10-01', month_locked: true,
    system_start_date: '2026-08-01', company: company('Frozen Recovery Pte. Ltd.'),
    processing_balance: [{ scope: 'plant', operation_type_code: null, line: 'input', line_key: null, basis: null, qty_kg: 500, runs: 1 }],
    stock_rollforward: [{ unit: 'kg', opening: 0, received: 2000, produced: 450, consumed: -500, sold: 0, written_off: 0, adjusted: 0, voided: 0,
                          issued_to_maintenance: 0, moved: 0, closing: 1950 }],
    licence: { in_force: { cert_type_code: 'gwdf', cert_no: 'WDL-21-2-5380', issuing_body: 'NEA', scope: null, valid_from: '2026-07-01', valid_until: '2028-09-01',
                           approved_storage_limit_tonnes: 500 },
               on_hand_by_category: [], uncategorised_tonnes: 1.95, movements_without_business_date: 0, ceiling_checks: [] },
    incidents: [{ code: 'INC-2026-0007', kind_code: 'injury', kind_name_en: 'Injury', occurred_on: '2026-09-11', nea_reportable: true, notified_on: '2026-09-11',
                  report_submitted_on: null, report_deadline: '2026-09-15', deadline_state: 'computed', closed_on: null }],
    environmental: [], inspections: { done: [], findings_open_at_month_end: [] },
    nea_return: { state: 'not_set', value_code: 'V26' },
    eu_efficiency: { state: 'not_set', value_code: 'V27', masses: { input_kg: 500, outputs: [{ form: 'black_mass', qty_kg: 450 }] } } })
const cpkRow = (over = {}) => ({ id: CPK, code: 'CPK-2026-09', period_month: '2026-09-01', period_start: '2026-09-01', period_end: '2026-09-30',
    locked_before_at_freeze: '2026-10-01', payload: cpkPayload(), frozen_at: '2026-10-02T02:00:00Z', superseded_at: null, ...over })

function fake(over = {}) {
    globalThis.__PDF_FAKE__ = { tables: {}, rpc: {}, calls: [], reads: [], uploads: [], removed: [], store: new Map(), ...over }
    return globalThis.__PDF_FAKE__
}
const called = (n) => globalThis.__PDF_FAKE__.calls.filter((c) => c.name === n).length
const req = (url, init) => new Request(`https://erp.example.test${url}`, init)
const post = (url, body) => req(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body ?? {}) })
const ctx = (id) => ({ params: Promise.resolve({ id }) })

// ── 样例 ────────────────────────────────────────────────────────────────────
const CASES = [
    ['COA-SNAP', async ({ coa }) => {
        const f = fake()
        f.rpc.coa_certificate_data = () => ({ ...coaSnap('Live Buyer Pte Ltd'), certificate: null, issuer: null, blockers: [] })
        f.rpc.coa_issuer = () => ({ employee_id: 'e', name: 'Tan', position: 'Quality Manager' })
        f.rpc.issue_coa = () => ({ coa_id: COA, code: 'COA-2026-0001', status: 'issued', snapshot: coaSnap('Frozen Buyer Pte Ltd') })
        f.rpc.record_coa_issue = (a) => ({ coa_id: a.p_coa_id, sha256: a.p_sha256 })
        const res = await coa.POST(post(`/output/${OB}/coa/pdf`, { salesOrderId: SO }), ctx(OB))
        if (res.status !== 200) return `issue returned ${res.status}: ${(await res.text()).slice(0, 160)}`
        if (f.uploads.length !== 1) return `expected one upload, got ${f.uploads.length}`
        const bytes = f.store.get(`coa-documents/${f.uploads[0].path}`)
        const rec = f.calls.find((c) => c.name === 'record_coa_issue')
        if (!rec || rec.args.p_sha256 !== sha(bytes)) return 'the recorded sha256 is not the sha of the uploaded bytes'
        const txt = pdfText(bytes)
        if (!txt.includes('Frozen Buyer Pte Ltd')) return 'the paper does not carry the snapshot\'s customer'
        if (txt.includes('Live Buyer')) return 'the paper carries the LIVE customer — it was rendered from live data, not the snapshot'
        if (!txt.includes('Issued by Tan, Quality Manager')) return 'the paper does not name the issuer from the snapshot'
        return null
    }],
    ['COA-ISSUER', async ({ coa }) => {
        const f = fake()
        f.rpc.coa_certificate_data = () => ({ ...coaSnap('Buyer'), certificate: null, issuer: null, blockers: [] })
        f.rpc.coa_issuer = () => ({ employee_id: 'e', name: 'Lim ≤', position: 'Quality Manager' })
        f.rpc.issue_coa = () => ({ coa_id: COA, code: 'COA-2026-0001', status: 'issued', snapshot: coaSnap('Buyer', 'Lim ≤') })
        f.rpc.record_coa_issue = () => ({})
        const res = await coa.POST(post(`/output/${OB}/coa/pdf`, {}), ctx(OB))
        if (res.status !== 400) return `an unprintable issuer name must refuse with 400, got ${res.status}`
        if (called('issue_coa') !== 0) return 'issue_coa was called — a number was minted for a certificate whose paper cannot be printed'
        if (f.uploads.length !== 0) return 'something was uploaded'
        return null
    }],
    ['COA-409', async ({ coa }) => {
        const good = Buffer.from('%PDF-1.4 fixture bytes')
        const f = fake({ tables: {
            certificates_of_analysis: [{ id: COA, code: 'COA-2026-0001', status: 'issued', output_batch_id: OB }],
            coa_issues: [{ coa_id: COA, file_path: `${COA}/a.pdf`, sha256: sha(good) }],
        } })
        f.store.set(`coa-documents/${COA}/a.pdf`, good)
        let res = await coa.GET(req(`/output/${OB}/coa/pdf?coa=COA-2026-0001`), ctx(OB))
        if (res.status !== 200) return `stored bytes that match must stream with 200, got ${res.status}`
        if (!Buffer.from(await res.arrayBuffer()).equals(good)) return 'the streamed bytes are not the stored bytes'
        f.store.set(`coa-documents/${COA}/a.pdf`, Buffer.from('%PDF-1.4 tampered'))
        res = await coa.GET(req(`/output/${OB}/coa/pdf?coa=COA-2026-0001`), ctx(OB))
        if (res.status !== 409) return `stored bytes that do not match their recorded sha256 must answer 409, got ${res.status}`
        return null
    }],
    ['COA-SAVE', async ({ coa }) => {
        const f = fake({ tables: {
            certificates_of_analysis: [{ id: COA, code: 'COA-2026-0001', status: 'issued', output_batch_id: OB, snapshot: coaSnap('Frozen Buyer Pte Ltd') }],
            coa_issues: [],
        } })
        f.rpc.coa_certificate_data = () => ({ ...coaSnap('Live Buyer Pte Ltd'), certificate: null, issuer: null, blockers: [] })
        f.rpc.record_coa_issue = (a) => ({ coa_id: a.p_coa_id, sha256: a.p_sha256 })
        let res = await coa.POST(post(`/output/${OB}/coa/pdf`, { storeFor: COA }), ctx(OB))
        if (res.status !== 200) return `save PDF returned ${res.status}: ${(await res.text()).slice(0, 160)}`
        if (f.uploads.length !== 1 || called('record_coa_issue') !== 1) return 'save PDF must upload once and record once'
        const txt = pdfText(f.store.get(`coa-documents/${f.uploads[0].path}`))
        if (!txt.includes('Frozen Buyer Pte Ltd') || txt.includes('Live Buyer')) return 'save PDF did not render the stored snapshot'
        // 已有字节 → 拒,什么都不传
        const g = fake({ tables: {
            certificates_of_analysis: [{ id: COA, code: 'COA-2026-0001', status: 'issued', output_batch_id: OB, snapshot: coaSnap('X') }],
            coa_issues: [{ coa_id: COA, file_path: `${COA}/a.pdf`, sha256: 'a'.repeat(64) }],
        } })
        res = await coa.POST(post(`/output/${OB}/coa/pdf`, { storeFor: COA }), ctx(OB))
        if (res.status !== 400 || g.uploads.length !== 0) return `save PDF on a certificate that has bytes must refuse and upload nothing, got ${res.status}`
        return null
    }],
    ['COD-SNAP', async ({ cod }) => {
        const f = fake({ tables: {
            certificates_of_destruction: [{ id: COD, code: null, status: 'pending', inbound_batch_id: IB, voided_at: null }],
            company_profile_masked: [{ ...company('Live Letterhead Pte. Ltd.'), logo_path: null }],
        } })
        f.rpc.cod_certificate_data = () => codSnap('Live Supplier Co', 'Live Letterhead Pte. Ltd.', 'pending')
        f.rpc.issue_cod = () => ({ cod_id: COD, code: 'COD-2026-0003', status: 'issued', snapshot: codSnap('Frozen Supplier Co', 'Frozen Recovery Pte. Ltd.') })
        f.rpc.record_cod_issue = (a) => ({ cod_id: a.p_cod_id })
        const res = await cod.POST(post(`/inbound/${IB}/cod/pdf`), ctx(IB))
        if (res.status !== 200) return `issue returned ${res.status}: ${(await res.text()).slice(0, 160)}`
        if (f.uploads.length !== 1) return `expected one upload, got ${f.uploads.length}`
        const bytes = f.store.get(`cod-documents/${f.uploads[0].path}`)
        const rec = f.calls.find((c) => c.name === 'record_cod_issue')
        if (!rec || rec.args.p_sha256 !== sha(bytes)) return 'the recorded sha256 is not the sha of the uploaded bytes'
        if (called('cod_certificate_data') !== 1) return `cod_certificate_data was called ${called('cod_certificate_data')} times — only the pre-issue font check may read live data`
        const txt = pdfText(bytes)
        if (!txt.includes('Frozen Supplier Co') || txt.includes('Live Supplier')) return 'the paper does not carry the snapshot\'s supplier'
        if (!txt.includes('Frozen Recovery Pte. Ltd.') || txt.includes('Live Letterhead')) return 'the letterhead is not the one frozen in the snapshot'
        return null
    }],
    ['COD-STORED', async ({ cod }) => {
        const good = Buffer.from('%PDF-1.4 stored COD bytes')
        const tables = () => ({
            certificates_of_destruction: [{ id: COD, code: 'COD-2026-0003', status: 'issued', inbound_batch_id: IB, voided_at: null }],
            cod_issues: [{ cod_id: COD, file_path: `${COD}/a.pdf`, sha256: sha(good) }],
            company_profile_masked: [{ ...company('Live Letterhead Pte. Ltd.'), logo_path: null }],
        })
        let f = fake({ tables: tables() })
        f.store.set(`cod-documents/${COD}/a.pdf`, good)
        f.rpc.cod_certificate_data = () => codSnap('Live Supplier Co', 'Live Letterhead Pte. Ltd.')
        let res = await cod.GET(req(`/inbound/${IB}/cod/pdf`), ctx(IB))
        if (res.status !== 200 || !Buffer.from(await res.arrayBuffer()).equals(good)) return `a bare GET of an issued certificate must stream the stored bytes (got ${res.status})`
        if (called('cod_certificate_data') !== 0) return 'a bare GET of an issued certificate re-assembled live data'
        res = await cod.GET(req(`/inbound/${IB}/cod/pdf?cod=COD-2026-0003`), ctx(IB))
        if (res.status !== 200 || !Buffer.from(await res.arrayBuffer()).equals(good)) return '?cod= must stream the stored bytes'
        f.store.set(`cod-documents/${COD}/a.pdf`, Buffer.from('%PDF-1.4 tampered'))
        res = await cod.GET(req(`/inbound/${IB}/cod/pdf`), ctx(IB))
        if (res.status !== 409) return `stored bytes that do not match must answer 409 on a bare GET, got ${res.status}`
        res = await cod.GET(req(`/inbound/${IB}/cod/pdf?cod=COD-2026-0003`), ctx(IB))
        if (res.status !== 409) return `stored bytes that do not match must answer 409 on ?cod=, got ${res.status}`
        // 作废的(这票货没有活着的证书):同样流存下的字节
        f = fake({ tables: { ...tables(), certificates_of_destruction: [{ id: COD_V, code: 'COD-2026-0002', status: 'void', inbound_batch_id: IB, voided_at: '2026-10-10T00:00:00Z' }],
                             cod_issues: [{ cod_id: COD_V, file_path: `${COD_V}/v.pdf`, sha256: sha(good) }] } })
        f.store.set(`cod-documents/${COD_V}/v.pdf`, good)
        f.rpc.cod_certificate_data = () => codSnap('Live Supplier Co', 'Live Letterhead Pte. Ltd.')
        res = await cod.GET(req(`/inbound/${IB}/cod/pdf`), ctx(IB))
        if (res.status !== 200 || !Buffer.from(await res.arrayBuffer()).equals(good)) return `a bare GET of a void certificate must stream its stored bytes (got ${res.status})`
        return null
    }],
    ['COD-PENDING', async ({ cod }) => {
        const f = fake({ tables: {
            certificates_of_destruction: [{ id: COD, code: null, status: 'pending', inbound_batch_id: IB, voided_at: null }],
            company_profile_masked: [{ ...company('Live Letterhead Pte. Ltd.'), logo_path: null }],
        } })
        f.rpc.cod_certificate_data = () => codSnap('Live Supplier Co', 'Live Letterhead Pte. Ltd.', 'pending')
        const res = await cod.GET(req(`/inbound/${IB}/cod/pdf`), ctx(IB))
        if (res.status !== 200) return `the internal preview returned ${res.status}: ${(await res.text()).slice(0, 160)}`
        const txt = pdfText(Buffer.from(await res.arrayBuffer()))
        if (!txt.includes('Live Supplier Co')) return 'the internal preview of a pending certificate must read live data'
        if (!/internal record/i.test(txt)) return 'the internal preview must say it is not an issued certificate'
        return null
    }],
    ['COD-FONT', async ({ cod }) => {
        let f = fake({ tables: {
            certificates_of_destruction: [{ id: COD, code: null, status: 'pending', inbound_batch_id: IB, voided_at: null }],
            company_profile_masked: [{ ...company('Live Letterhead Pte. Ltd.'), logo_path: null }],
        } })
        f.rpc.cod_certificate_data = () => codSnap('Acme ≤ Recycling', 'Live Letterhead Pte. Ltd.', 'pending')
        f.rpc.issue_cod = () => ({ cod_id: COD, code: 'COD-2026-0003', status: 'issued', snapshot: codSnap('Acme ≤ Recycling', 'Frozen') })
        f.rpc.record_cod_issue = () => ({})
        let res = await cod.POST(post(`/inbound/${IB}/cod/pdf`), ctx(IB))
        if (res.status !== 400 || called('issue_cod') !== 0) return `an unprintable supplier name must refuse before issue_cod (status ${res.status}, issue_cod called ${called('issue_cod')})`
        // 渲染之内的那一道:快照里有画不出来的字(签发之前的那一问没看见)→ 拒、什么都不传
        f = fake({ tables: {
            certificates_of_destruction: [{ id: COD, code: null, status: 'pending', inbound_batch_id: IB, voided_at: null }],
            company_profile_masked: [{ ...company('Live Letterhead Pte. Ltd.'), logo_path: null }],
        } })
        f.rpc.cod_certificate_data = () => codSnap('Clean Supplier', 'Live Letterhead Pte. Ltd.', 'pending')
        f.rpc.issue_cod = () => ({ cod_id: COD, code: 'COD-2026-0003', status: 'issued', snapshot: codSnap('Acme ≤ Recycling', 'Frozen') })
        f.rpc.record_cod_issue = () => ({})
        res = await cod.POST(post(`/inbound/${IB}/cod/pdf`), ctx(IB))
        if (res.status !== 400 || f.uploads.length !== 0) return `an unprintable snapshot must be refused inside render with nothing uploaded (status ${res.status}, uploads ${f.uploads.length})`
        return null
    }],
    ['SST-FROZEN', async ({ sst }) => {
        const f = fake({ tables: {
            supplier_statements: [sstRow()],
            supplier_lookup: [{ id: 'sup-1', code: 'SUP-2026-0002', legal_name: 'Live Supplier Renamed Ltd' }],
            company_profile_masked: [{ ...company('Live Letterhead Pte. Ltd.'), logo_path: null }],
        } })
        const res = await sst.GET(req(`/finance/supplier-statements/${SST}/pdf`), ctx(SST))
        if (res.status !== 200) return `the frozen render returned ${res.status}: ${(await res.text()).slice(0, 160)}`
        // 窄列里的字会折行(pypdf 读出来是 "Provisional\nprice")—— 空白归一再比,比的是字,不是排版
        const txt = pdfText(Buffer.from(await res.arrayBuffer())).replace(/\s+/g, ' ')
        if (!txt.includes('Frozen Supplier Pte Ltd') || txt.includes('Live Supplier Renamed')) return 'the paper does not carry the supplier frozen on the statement'
        if (!txt.includes('Frozen Recovery Pte. Ltd.') || txt.includes('Live Letterhead')) return 'the letterhead is not the one frozen on the statement'
        if (!txt.includes('Provisional price')) return 'a provisionally priced receipt is not marked provisional on the paper'
        if (!txt.includes('IN-2026-0302') || !txt.includes('800 kg')) return 'a receipt not yet priced is not listed with its quantity'
        if (/[一-鿿]/.test(txt)) return 'the supplier statement must be English'
        if (f.reads.includes('supplier_lookup') || f.reads.includes('company_profile_masked')) return `the render read live tables: ${f.reads.join(', ')}`
        return null
    }],
    ['SST-409', async ({ sst }) => {
        const good = Buffer.from('%PDF-1.4 stored supplier statement')
        const f = fake({ tables: { supplier_statement_issues: [{ statement_id: SST, version: 1, file_path: `${SST}/a.pdf`, sha256: sha(good) }] } })
        f.store.set(`supplier-statement-documents/${SST}/a.pdf`, good)
        let res = await sst.GET(req(`/finance/supplier-statements/${SST}/pdf?version=1`), ctx(SST))
        if (res.status !== 200 || !Buffer.from(await res.arrayBuffer()).equals(good)) return `stored bytes that match must stream with 200, got ${res.status}`
        f.store.set(`supplier-statement-documents/${SST}/a.pdf`, Buffer.from('%PDF-1.4 tampered'))
        res = await sst.GET(req(`/finance/supplier-statements/${SST}/pdf?version=1`), ctx(SST))
        if (res.status !== 409) return `stored bytes that do not match their recorded sha256 must answer 409, got ${res.status}`
        return null
    }],
    ['SST-ARCHIVE', async ({ sst }) => {
        let f = fake({ tables: { supplier_statements: [sstRow()], supplier_statement_issues: [] } })
        f.rpc.record_supplier_statement_issue = (a) => ({ statement_id: a.p_statement_id, version: 1, sha256: a.p_sha256 })
        let res = await sst.POST(post(`/finance/supplier-statements/${SST}/pdf`), ctx(SST))
        if (res.status !== 200) return `archive returned ${res.status}: ${(await res.text()).slice(0, 160)}`
        if (f.uploads.length !== 1) return `expected one upload, got ${f.uploads.length}`
        const bytes = f.store.get(`supplier-statement-documents/${f.uploads[0].path}`)
        const rec = f.calls.find((c) => c.name === 'record_supplier_statement_issue')
        if (!rec || rec.args.p_sha256 !== sha(bytes)) return 'the recorded sha256 is not the sha of the uploaded bytes'
        if (!f.uploads[0].path.startsWith(`${SST}/`)) return 'the object is not stored under the statement id'
        // 记哈希被拒 → 刚传的对象被删掉(桶里不留孤儿)
        f = fake({ tables: { supplier_statements: [sstRow()], supplier_statement_issues: [] } })
        f.rpc.record_supplier_statement_issue = () => { throw new Error('SUPPLIER_STATEMENT_SUPERSEDED|SST-2026-0001|x') }
        res = await sst.POST(post(`/finance/supplier-statements/${SST}/pdf`), ctx(SST))
        if (res.status !== 400) return `a refused record must answer 400, got ${res.status}`
        if (f.uploads.length !== 1 || f.removed.length !== 1 || f.store.size !== 0) return `a refused record must remove the uploaded object (uploads ${f.uploads.length}, removed ${f.removed.length}, left ${f.store.size})`
        return null
    }],
    ['CPK-FROZEN', async ({ cpk }) => {
        const f = fake({ tables: {
            compliance_packs: [cpkRow()],
            company_profile_masked: [{ ...company('Live Letterhead Pte. Ltd.'), logo_path: null }],
            incidents: [{ id: 'i', code: 'INC-2026-0007', injured_person_name: 'Live Injured Person', injury_nature: 'burn' }],
        } })
        const res = await cpk.GET(req(`/compliance/packs/${CPK}/pdf`), ctx(CPK))
        if (res.status !== 200) return `the frozen render returned ${res.status}: ${(await res.text()).slice(0, 160)}`
        const txt = pdfText(Buffer.from(await res.arrayBuffer())).replace(/\s+/g, ' ')
        if (!txt.includes('Frozen Recovery Pte. Ltd.') || txt.includes('Live Letterhead')) return 'the letterhead is not the one frozen in the pack'
        if (!txt.includes('CPK-2026-09') || !txt.includes('INC-2026-0007')) return 'the paper does not carry the frozen pack code and its incident'
        if (txt.includes('Live Injured Person') || /burn/i.test(txt)) return 'the paper carries an injury detail'
        if (!txt.includes('format not yet set (V26)') || !txt.includes('method not yet set (V27)')) return 'sections 7 and 8 do not say V26 / V27 are not set'
        if (/[一-鿿]/.test(txt)) return 'the compliance pack must be English'
        if (f.reads.includes('company_profile_masked') || f.reads.includes('incidents')) return `the render read live tables: ${f.reads.join(', ')}`
        return null
    }],
    ['CPK-409', async ({ cpk }) => {
        const good = Buffer.from('%PDF-1.4 stored compliance pack')
        const f = fake({ tables: { compliance_pack_issues: [{ pack_id: CPK, version: 1, file_path: `${CPK}/a.pdf`, sha256: sha(good) }] } })
        f.store.set(`compliance-documents/${CPK}/a.pdf`, good)
        let res = await cpk.GET(req(`/compliance/packs/${CPK}/pdf?version=1`), ctx(CPK))
        if (res.status !== 200 || !Buffer.from(await res.arrayBuffer()).equals(good)) return `stored bytes that match must stream with 200, got ${res.status}`
        f.store.set(`compliance-documents/${CPK}/a.pdf`, Buffer.from('%PDF-1.4 tampered'))
        res = await cpk.GET(req(`/compliance/packs/${CPK}/pdf?version=1`), ctx(CPK))
        if (res.status !== 409) return `stored bytes that do not match their recorded sha256 must answer 409, got ${res.status}`
        return null
    }],
    ['CPK-ARCHIVE', async ({ cpk }) => {
        let f = fake({ tables: { compliance_packs: [cpkRow()], compliance_pack_issues: [] } })
        f.rpc.record_compliance_pack_issue = (a) => ({ pack_id: a.p_pack_id, version: 1, sha256: a.p_sha256 })
        let res = await cpk.POST(post(`/compliance/packs/${CPK}/pdf`), ctx(CPK))
        if (res.status !== 200) return `archive returned ${res.status}: ${(await res.text()).slice(0, 160)}`
        if (f.uploads.length !== 1) return `expected one upload, got ${f.uploads.length}`
        const bytes = f.store.get(`compliance-documents/${f.uploads[0].path}`)
        const rec = f.calls.find((c) => c.name === 'record_compliance_pack_issue')
        if (!rec || rec.args.p_sha256 !== sha(bytes)) return 'the recorded sha256 is not the sha of the uploaded bytes'
        if (!f.uploads[0].path.startsWith(`${CPK}/`)) return 'the object is not stored under the pack id'
        f = fake({ tables: { compliance_packs: [cpkRow()], compliance_pack_issues: [] } })
        f.rpc.record_compliance_pack_issue = () => { throw new Error('COMPLIANCE_PACK_SUPERSEDED|CPK-2026-09|x') }
        res = await cpk.POST(post(`/compliance/packs/${CPK}/pdf`), ctx(CPK))
        if (res.status !== 400) return `a refused record must answer 400, got ${res.status}`
        if (f.uploads.length !== 1 || f.removed.length !== 1 || f.store.size !== 0) return `a refused record must remove the uploaded object (uploads ${f.uploads.length}, removed ${f.removed.length}, left ${f.store.size})`
        return null
    }],
]
const DECLARED = 14

// ── 故障注入格:改坏路由的一处,点名的那一个样例必须红 ───────────────────────────────
const FAULTS = [
    { name: 'coa-render-live', route: 'coa', expect: 'COA-SNAP',
      from: "renderCoaPdf(r.snapshot, 'issued')", to: "renderCoaPdf(pre.data as unknown as CoaSnapshot, 'issued')" },
    { name: 'coa-issuer-unchecked', route: 'coa', expect: 'COA-ISSUER',
      from: 'coaUnrenderable({ ...(pre.data as unknown as CoaSnapshot), issuer: { name: issuer.name, position: issuer.position } })',
      to: 'coaUnrenderable(pre.data as unknown as CoaSnapshot)' },
    { name: 'coa-no-409', route: 'coa', expect: 'COA-409', from: 'if (sha !== issue.sha256) {', to: 'if (sha === "never") {' },
    { name: 'coa-save-live', route: 'coa', expect: 'COA-SAVE', from: "const buf = await renderCoaPdf(cert.snapshot, 'issued')",
      to: "const buf = await renderCoaPdf((await supabase.rpc('coa_certificate_data', { p_output_batch_id: batchId })).data as unknown as CoaSnapshot, 'issued')" },
    { name: 'cod-render-live', route: 'cod', expect: 'COD-SNAP', from: "render(r.snapshot, 'issued', new URL(request.url).origin, company)",
      to: "render((await supabase.rpc('cod_certificate_data', { p_inbound_batch_id: id })).data as CertificateData, 'issued', new URL(request.url).origin, company)" },
    { name: 'cod-letterhead-live', route: 'cod', expect: 'COD-SNAP', from: 'const company = companyFromSnapshot(r.snapshot)',
      to: 'const company: LetterheadCompany | null = loaded.company' },
    { name: 'cod-bare-get-rerender', route: 'cod', expect: 'COD-STORED',
      from: 'if (stored && stored.code) return await streamStored(supabase, { id: stored.id, code: stored.code })', to: 'void stored' },
    { name: 'cod-no-409', route: 'cod', expect: 'COD-STORED', from: 'if (sha !== issue.sha256) {', to: 'if (sha === "never") {' },
    { name: 'cod-no-font-precheck', route: 'cod', expect: 'COD-FONT', from: 'if (preBad) return new NextResponse(preBad, { status: 400 })', to: 'void preBad' },
    { name: 'sst-render-live', route: 'sst', expect: 'SST-FROZEN', from: 'return statementDocFrom(st)',
      to: "return statementDocFrom({ ...st, supplier_name: ((await supabase.from('supplier_lookup').select('legal_name').eq('id', st.supplier_id).maybeSingle()).data as { legal_name: string }).legal_name })" },
    { name: 'sst-no-409', route: 'sst', expect: 'SST-409', from: 'if (sha !== issue.sha256) {', to: 'if (sha === "never") {' },
    { name: 'sst-orphan-left', route: 'sst', expect: 'SST-ARCHIVE', from: 'await supabase.storage.from(BUCKET).remove([path])', to: 'void path' },
    { name: 'cpk-render-live', route: 'cpk', expect: 'CPK-FROZEN', from: 'return packDocFrom(pk)',
      to: "return packDocFrom({ ...pk, payload: { ...pk.payload, company: (await supabase.from('company_profile_masked').select('*').maybeSingle()).data as never } })" },
    { name: 'cpk-no-409', route: 'cpk', expect: 'CPK-409', from: 'if (sha !== issue.sha256) {', to: 'if (sha === "never") {' },
    { name: 'cpk-orphan-left', route: 'cpk', expect: 'CPK-ARCHIVE', from: 'await supabase.storage.from(BUCKET).remove([path])', to: 'void path' },
]

async function load(coaSrc, codSrc, sstSrc, cpkSrc, tag) {
    mkdirSync(TMP, { recursive: true })
    const coaPath = join(TMP, `coa-${tag}.tsx`), codPath = join(TMP, `cod-${tag}.tsx`)
    writeFileSync(coaPath, coaSrc); writeFileSync(codPath, codSrc)
    // MES-8a:供应商对账单的路由 import 它同目录的文档与上两级的错误码 —— 副本放在【原目录】里(相对 import 才找得到),跑完删掉
    const sstPath = join(ROOT, 'app/finance/supplier-statements/[id]/pdf', `.route-${tag}-${process.pid}.ts`)
    writeFileSync(sstPath, sstSrc)
    // MES-8b-1:合规包的路由同一个办法(同目录的文档、上两级的错误码)
    const cpkPath = join(ROOT, 'app/compliance/packs/[id]/pdf', `.route-${tag}-${process.pid}.ts`)
    writeFileSync(cpkPath, cpkSrc)
    try { return { coa: await jiti.import(coaPath), cod: await jiti.import(codPath), sst: await jiti.import(sstPath), cpk: await jiti.import(cpkPath) } }
    finally { rmSync(sstPath, { force: true }); rmSync(cpkPath, { force: true }) }
}

async function runAll(routes) {
    const red = {}
    for (const [name, fn] of CASES) {
        try { const why = await fn(routes); if (why) red[name] = why } catch (e) {
            if (String(e.message).startsWith('MEASURE|')) throw e
            red[name] = `threw: ${e.message}`
        }
    }
    return red
}

let exit = 0
try {
    const coaSrc = readFileSync(COA_ROUTE, 'utf8'), codSrc = readFileSync(COD_ROUTE, 'utf8'), sstSrc = readFileSync(SST_ROUTE, 'utf8'), cpkSrc = readFileSync(CPK_ROUTE, 'utf8')
    if (CASES.length !== DECLARED) { console.error(`✗ check-pdf-routes:声明 ${DECLARED} 个样例,实有 ${CASES.length} 个`); process.exit(3) }
    const clean = await runAll(await load(coaSrc, codSrc, sstSrc, cpkSrc, 'clean'))
    for (const [name] of CASES) console.log(`${clean[name] ? '✗' : '✓'} ${name}${clean[name] ? ' —— ' + clean[name] : ''}`)
    if (Object.keys(clean).length) exit = 1
    let faultsRun = 0
    if (!process.argv.includes('--no-faults')) {
        for (const f of FAULTS) {
            const src = f.route === 'coa' ? coaSrc : f.route === 'cod' ? codSrc : f.route === 'sst' ? sstSrc : cpkSrc
            if (!src.includes(f.from)) { console.error(`✗ 故障格 ${f.name}:路由里找不到要改的那一句 —— 这一格瞎了(路由改过,格子没跟上)`); exit = 3; continue }
            const bad = src.replace(f.from, f.to)
            const red = await runAll(await load(f.route === 'coa' ? bad : coaSrc, f.route === 'cod' ? bad : codSrc, f.route === 'sst' ? bad : sstSrc,
                                                f.route === 'cpk' ? bad : cpkSrc, f.name))
            faultsRun++
            if (!red[f.expect]) { console.error(`✗ 故障格 ${f.name}:注入之后 ${f.expect} 仍然是绿的 —— 这一格没有咬人`); exit = 3 }
            else console.log(`✓ 故障格 ${f.name} → ${f.expect} 红(${red[f.expect].slice(0, 90)})`)
        }
    }
    console.log(`check-pdf-routes:${CASES.length} 个样例${Object.keys(clean).length ? `,${Object.keys(clean).length} 个红` : ' 全绿'} · ${faultsRun} 个故障格各自咬人${exit === 3 ? '(有一格没有)' : ''}`)
} catch (e) {
    console.error(`✗ check-pdf-routes:量具自己坏了 —— ${e.message}`)
    exit = 3
} finally {
    rmSync(TMP, { recursive: true, force: true })
}
process.exit(exit)
