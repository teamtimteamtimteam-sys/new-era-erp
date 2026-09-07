// app/verify/cod/verifyHtml.ts
// ════════════════════════════════════════════════════════════════════════════
// COD-2:核验页的那一页 HTML —— 【纯函数,不碰数据库,不碰会话】
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么是一页手写 HTML,而不是一个 React 页面】三条,都是量得出来的:
//   ① **状态码**。这一页要回 200 / 404 / 429 三种,而 Next 的 page 组件除了
//      notFound()(404)以外没有办法指定状态码 —— 一个把限流演成 200 的页面,
//      在报告里仍然写着"限流了"。而 429 + Retry-After 是委托书点名要的。
//   ② **给整个互联网的那一页,应该只有它自己**。route 回的是一段自包含的
//      HTML:零客户端 JS、零 RSC 负载、零应用外壳、零 import 到 app/ 里的组件。
//      一个匿名访客拿不到本系统的任何一行代码 —— 这不是洁癖,是攻击面。
//   ③ 它跟着仓库里已经有的一条路走:app/inbound/[id]/label/route.ts + 
//      app/components/labels/labelHtml.ts 就是"路由取数、纯函数出 HTML"这一对。
//
// ★【一律英文,不跟界面语言】★ 与证书本身同一条裁定(见 codErrorCodes.ts 抬头):
//   这一页的收件人是【送料方】,他不是这套系统的用户,也没有 NEXT_LOCALE。
//   它是一份法律文件的网上原件,不是应用的一页。
//
// ★【这一页上没有的东西,逐条点名】★ 价格、成本、化验、品位、产出批、
//   任何人名、任何内部 uuid、令牌回声、**以及作废原因**。最后那一条尤其要紧:
//   void_reason 是内部自由文本,操作员可能往里面打了任何东西。

function esc(s: string): string {
    return String(s)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
}

export type VerifyOk = {
    result: 'ok'
    status: string
    certificate: { code: string | null; issued_at: string | null }
    processing: { completed_on: string | null }
    inbound_batch: {
        code: string | null
        material_code: string | null
        material_name: string | null
        quantity: number | string | null
        unit: string | null
        arrival_date: string | null
        purchase_order_code: string | null
    }
    supplier: { name: string | null; code: string | null }
    company: {
        legal_name: string | null
        registration_no: string | null
        address_lines: string | null
        city: string | null
        postal_code: string | null
        country: string | null
    }
    licence: {
        cert_no: string | null
        issuing_body: string | null
        valid_from: string | null
        valid_until: string | null
    } | null
    void: { replaced_by_code: string | null } | null
}

const SHELL = `body{margin:0;background:#f6f7f9;color:#111827;font:16px/1.6 system-ui,-apple-system,'Segoe UI',sans-serif;padding:2rem 1rem}
main{max-width:44rem;margin:0 auto;background:#fff;border:1px solid #d8dde5;border-radius:.75rem;padding:2rem}
h1{font-size:1.4rem;margin:0 0 .25rem;letter-spacing:.01em}
.sub{color:#6b7280;font-size:.85rem;margin:0 0 1.5rem}
.badge{display:inline-block;padding:.3rem .7rem;border-radius:999px;font-size:.78rem;font-weight:700;letter-spacing:.04em;text-transform:uppercase}
.ok{background:#e7f6ec;color:#14532d;border:1px solid #a7d8b8}
.void{background:#fdecec;color:#7f1d1d;border:1px solid #f0b3b3}
.note{margin:1.25rem 0;padding:.9rem 1.1rem;border-radius:.5rem;font-size:.92rem}
.note.void{background:#fff5f5;border:1px solid #f0b3b3;color:#7f1d1d}
table{width:100%;border-collapse:collapse;margin:1.25rem 0 0}
th,td{text-align:left;padding:.55rem .25rem;border-bottom:1px solid #eef1f5;vertical-align:top;font-size:.94rem}
th{width:15rem;color:#6b7280;font-weight:500}
h2{font-size:.8rem;text-transform:uppercase;letter-spacing:.08em;color:#6b7280;margin:1.75rem 0 0}
footer{margin-top:2rem;padding-top:1rem;border-top:1px solid #eef1f5;color:#6b7280;font-size:.8rem}
code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.95em}`

function page(title: string, body: string): string {
    // lang="en" 写死 —— 这一页不跟界面语言(见抬头)。
    return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>${esc(title)}</title><style>${SHELL}</style></head>
<body>${body}</body></html>`
}

function row(label: string, value: unknown): string {
    // 【一格缺席就画一条短横,绝不画一片空白】—— 空白读起来像"这里本来就没有东西",
    // 而实际是"这一格没有值"。与证书 PDF 上的 show() 同一条。
    const v = value === null || value === undefined || value === '' ? '—' : String(value)
    return `<tr><th>${esc(label)}</th><td>${esc(v)}</td></tr>`
}

/** 一份【已签发】或【已作废】的证书。作废的那一份内容照印 —— 纸还在人手里。 */
export function renderCertificate(d: VerifyOk): string {
    const isVoid = d.status === 'void'
    const code = d.certificate.code ?? '—'
    const replaced = d.void?.replaced_by_code ?? null

    // ★【作废的两种收场,措辞不一样,因为持有人要做的事不一样】★
    //   有替代品 → 告诉他新的号是多少,他去要那一份;
    //   没有替代品(加工被冲销了)→ 照直说,并让他联系 Evoltrya。
    //   ★ 两种都【不说】为什么作废 ★ —— 那是内部字段。
    const voidNote = !isVoid ? '' : replaced
        ? `<div class="note void"><strong>This certificate has been voided.</strong>
           It has been replaced by certificate <code>${esc(replaced)}</code>.
           The replacement carries the current record of this delivery.</div>`
        // ★【不许说【为什么】—— 因为这一页【不知道】为什么】★
        //   没有替代品的作废有不止一种来路(加工被冲销、或者操作员手工作废),
        //   而这一页手里【只有】replaced_by_cod_id 这一格是空的。写"那次加工被冲销了"
        //   读起来更有信息量,但它是一句这一页立不住的话 —— 而作废原因本身
        //   是内部自由文本,更不能印。所以它只说【它确实知道】的那一件事,
        //   再把人指向唯一说得清的地方。
        : `<div class="note void"><strong>This certificate has been withdrawn, and no replacement
           has been issued for it.</strong> Please contact ${esc(d.company.legal_name ?? 'the issuer')}
           before relying on this document.</div>`

    const addr = [d.company.address_lines, d.company.city, d.company.postal_code, d.company.country]
        .filter(Boolean).join(', ')

    const body = `<main>
<span class="badge ${isVoid ? 'void' : 'ok'}">${isVoid ? 'Voided' : 'Valid'}</span>
<h1>Certificate of Destruction ${esc(code)}</h1>
<p class="sub">Original record, held by ${esc(d.company.legal_name ?? 'the issuer')} — the printed
certificate is a copy of it.</p>
${voidNote}
<h2>The delivery</h2>
<table>
${row('Delivery reference', d.inbound_batch.code)}
${row('Purchase order', d.inbound_batch.purchase_order_code)}
${row('Material', [d.inbound_batch.material_code, d.inbound_batch.material_name].filter(Boolean).join(' — '))}
${row('Quantity received', d.inbound_batch.quantity === null ? null
    : `${d.inbound_batch.quantity} ${d.inbound_batch.unit ?? ''}`.trim())}
${row('Arrival date', d.inbound_batch.arrival_date)}
${row('Processing completed', d.processing.completed_on)}
</table>
<h2>Delivered by</h2>
<table>
${row('Name', d.supplier.name)}
${row('Reference', d.supplier.code)}
</table>
<h2>Processed by</h2>
<table>
${row('Company', d.company.legal_name)}
${row('Registration number', d.company.registration_no)}
${row('Address', addr)}
${row('Licence number', d.licence?.cert_no ?? null)}
${row('Issued by', d.licence?.issuing_body ?? null)}
${row('Licence valid', d.licence
    ? [d.licence.valid_from, d.licence.valid_until].filter(Boolean).join(' to ')
    : null)}
</table>
<h2>This certificate</h2>
<table>
${row('Certificate number', d.certificate.code)}
${row('Issued on', d.certificate.issued_at ? d.certificate.issued_at.slice(0, 10) : null)}
${row('Status', isVoid ? 'Voided' : 'Valid')}
</table>
<footer>Checked against the issuer's own record at the moment this page was loaded.
Altering a printed copy does not change what is shown here.</footer>
</main>`
    return page(`Certificate of Destruction ${code}`, body)
}

/**
 * ★【不认识的令牌与格式不对的令牌 —— 同一页,一个字都不差】★
 * 两者的区别是探测工具的神谕:能分辨"这个号不存在"与"这个号写错了"的人,
 * 就有了一台可以问的机器。所以这一页【不接受任何参数】—— 它连令牌都不回显,
 * 因为回显本身就能泄漏"我们看懂了你给的东西"。
 */
export function renderNotFound(): string {
    return page('Certificate not found', `<main>
<h1>Certificate not found</h1>
<p class="sub">&nbsp;</p>
<p>No certificate matches this verification link.</p>
<p>Please check the link against the QR code or the address printed on your
certificate. If it still does not resolve, contact the company that issued the
document before relying on it.</p>
</main>`)
}

/** 限流。【不说是什么触发的】—— 那本身就是一个可以问出答案的区别。 */
export function renderThrottled(retryAfterSeconds: number): string {
    const mins = Math.max(1, Math.ceil(retryAfterSeconds / 60))
    return page('Please try again shortly', `<main>
<h1>Please try again shortly</h1>
<p class="sub">&nbsp;</p>
<p>This service is temporarily limiting verification requests.
Please try again in about ${esc(String(mins))} minute${mins === 1 ? '' : 's'}.</p>
</main>`)
}

/**
 * 【问不到答案,不等于这份证书不存在】—— 与 lib/supabase/middleware.ts 抬头
 * 那条逐字同源:一次瞬时故障与一次"查无此证"在屏幕上长得一模一样,而它们
 * 完全不是一回事。对着一份【有人正拿在手里】的法律文件,把"我这会儿够不着
 * 数据库"说成"没有这份证书",是这一页能犯的最坏的错。所以它自己有一页,
 * 而且回的是 503,不是 404。
 */
export function renderUnavailable(): string {
    return page('Verification is temporarily unavailable', `<main>
<h1>Verification is temporarily unavailable</h1>
<p class="sub">&nbsp;</p>
<p>This service could not reach its records just now, so it cannot confirm or
deny this certificate. <strong>This does not mean the certificate is invalid.</strong></p>
<p>Please try again in a few minutes.</p>
</main>`)
}
