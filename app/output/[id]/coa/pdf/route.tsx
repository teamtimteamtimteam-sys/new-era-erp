// app/output/[id]/coa/pdf/route.tsx
// MES-6b-2(2026-10-15,MES-0 Q67;MES-6b Step 0 Q10 · Q14 · Q31,Tim):分析证书的三个入口(形状取自销毁证书的那一条路由)。
//   GET ?so=<销售单>   预览 —— 照【此刻的】数据组装(coa_certificate_data,与签发时冻进快照的同一支组装)、水印"PREVIEW — NOT A CERTIFICATE",
//                      不落任何档。门 = 那一批的查看码(库里问 module.output.view)。
//   GET ?coa=<证书号>  取【签发档】—— 从私有桶 coa-documents 流出签发那一刻存下的字节,并对着 coa_issues.sha256 重算校验:
//                      对不上就 409(一份与记录不符的"档案"比没有档案更坏)。作废的证书照样取得到(作废不动字节)。
//   POST {salesOrderId?} 签发 —— issue_coa 铸号、组装、冻快照(一笔事务,拒绝清单的第一句原样拒)→ 【照它返回的那一份快照】渲染 →
//                      存桶(键 <证书 id>/<随机 id>.pdf)→ record_coa_issue 记哈希。
//   POST {storeFor}    ★ MES-7a-1(MES-7a Step 0 Q24)【存 PDF】—— 一张已签发、却没有存下字节的证书(签发时上传或记哈希失败留下的那一种):
//                      照它【存下的那一份快照】再渲染一遍、存桶、record_coa_issue 记哈希。不铸号、不改快照;作废的、已有字节的按名拒
//                      (record_coa_issue 里同一句)。关掉 known-issues MES6B2-ISSUED-WITHOUT-BYTES 剩下的那一半。
// ★ MES-7a-1(F9,Q8):签发之前的字体检查【连签发人一起】问 —— 名字与职位由 coa_issuer()(issue_coa 用的同一支)解析,填进同一份组装再过
//   字体覆盖守卫;画不出来就 400、什么都不铸。此前签发人要到铸号那一刻才进快照,于是一个画不出来的名字会留下一张没有字节的证书。
//
// 【PDF 只从快照渲染】(Q31)签发之后不再回读 —— renderCoaPdf 的入参只有快照与模式。与销毁证书那一条路由的不同正在这里:
//   那一条签发后又调了一次 cod_certificate_data(活数据),是 known-issues MES6B1-COD-PDF-RENDERS-LIVE 登记的那一处。
// 【签发是两次落库,中间夹着渲染,而这是知情的选择】号要印在纸上,所以先落库(号、快照)再渲染存桶。中间崩掉会留下一张已签发而没有字节的
//   证书 —— 可恢复(快照是权威,照它再渲染一遍);反过来的顺序不可恢复(一个没落库的号会被重用)。记哈希失败时把孤儿对象删掉
//   (桶的删除策略只放行【还没被记下】的对象 —— 记下了的字节谁都删不掉)。
import { NextResponse } from 'next/server'
import { createHash } from 'node:crypto'
import { createClient } from '@/lib/supabase/server'
import { mustOne } from '@/lib/db-helpers'
import { renderCoaPdf, coaUnrenderable } from '@/app/output/coa/renderCoa'
import { localizeCoaError } from '@/app/output/coa/coaErrorCodes'
import { COA_BUCKET, type CoaSnapshot } from '@/app/output/coa/coaTypes'

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

function pdf(bytes: Uint8Array | Buffer, filename: string) {
    return new NextResponse(new Uint8Array(bytes), {
        headers: { 'Content-Type': 'application/pdf', 'Content-Disposition': `inline; filename="${filename}.pdf"` },
    })
}

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const url = new URL(request.url)
    const wanted = url.searchParams.get('coa')
    try {
        if (!UUID_RE.test(id)) return new NextResponse('Not found', { status: 404 })
        const supabase = await createClient()

        // ── 取签发档:流字节,并对着哈希校验 ──────────────────────────────
        if (wanted) {
            const cert = mustOne(
                await supabase.from('certificates_of_analysis').select('id, code, status')
                    .eq('output_batch_id', id).eq('code', wanted).maybeSingle(),
                'certificates_of_analysis'
            ) as { id: string; code: string; status: string } | null
            if (!cert) return new NextResponse('Not found', { status: 404 })
            const issue = mustOne(
                await supabase.from('coa_issues').select('file_path, sha256').eq('coa_id', cert.id).maybeSingle(),
                'coa_issues'
            ) as { file_path: string; sha256: string } | null
            if (!issue) return new NextResponse('No stored document for this certificate', { status: 404 })
            const dl = await supabase.storage.from(COA_BUCKET).download(issue.file_path)
            if (dl.error || !dl.data) return new NextResponse('Stored document unavailable', { status: 404 })
            const bytes = Buffer.from(await dl.data.arrayBuffer())
            const sha = createHash('sha256').update(bytes).digest('hex')
            if (sha !== issue.sha256) {
                return new NextResponse('Stored document does not match its recorded digest', { status: 409 })
            }
            return pdf(bytes, cert.code)
        }

        // ── 预览:照此刻的数据组装,不落档 ──────────────────────────────────
        const so = url.searchParams.get('so')
        if (so && !UUID_RE.test(so)) return new NextResponse('Not found', { status: 404 })
        const { data, error } = await supabase.rpc('coa_certificate_data', { p_output_batch_id: id, p_sales_order_id: so ?? undefined })
        if (error) return new NextResponse(await localizeCoaError(error.message), { status: 400 })
        const snap = data as unknown as CoaSnapshot
        return pdf(await renderCoaPdf(snap, 'preview'), `${snap.batch.code}-coa-preview`)
    } catch (e) {
        return new NextResponse(`PDF failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}

export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    try {
        if (!UUID_RE.test(id)) return new NextResponse('Not found', { status: 404 })
        // 空身体 = 不点名销售单;读不懂的身体是一次 400,不是"不点名"
        const text = await request.text()
        let body: { salesOrderId?: string | null; storeFor?: string | null } = {}
        if (text.trim() !== '') {
            try { body = JSON.parse(text) as { salesOrderId?: string | null; storeFor?: string | null } } catch { return new NextResponse('Bad request', { status: 400 }) }
        }
        if (body.storeFor) return await storeMissingBytes(id, body.storeFor)
        const so = body.salesOrderId && body.salesOrderId.trim() !== '' ? body.salesOrderId : null
        if (so && !UUID_RE.test(so)) return new NextResponse('Not found', { status: 404 })
        const supabase = await createClient()

        // ⓪ 签发之前先问字体:照【同一支组装】(coa_certificate_data)看纸上会印的字画不画得出来。画不出来就在这里拒 ——
        //   否则号已铸、快照已冻,渲染才失败,留下一张没有字节的证书(MES-6b-2 线上证明实测:合同标题里的「≤」)。
        //   ★ MES-7a-1(F9):签发人的名字与职位也在这一问里 —— coa_issuer() 与 issue_coa 冻进快照的是同一支解析;它解析不出来
        //   (不是员工 / 没有职位 / 没有码)就是那一句拒绝,同样什么都不铸。
        const pre = await supabase.rpc('coa_certificate_data', { p_output_batch_id: id, p_sales_order_id: so ?? undefined })
        if (pre.error) return new NextResponse(await localizeCoaError(pre.error.message), { status: 400 })
        const who = await supabase.rpc('coa_issuer')
        if (who.error) return new NextResponse(await localizeCoaError(who.error.message), { status: 400 })
        const issuer = who.data as unknown as { name: string; position: string }
        const unrenderable = coaUnrenderable({ ...(pre.data as unknown as CoaSnapshot), issuer: { name: issuer.name, position: issuer.position } })
        if (unrenderable) return new NextResponse(unrenderable, { status: 400 })

        // ① 落库:拒绝清单、铸号、冻快照 —— 全在一个事务里
        const issued = await supabase.rpc('issue_coa', { p_output_batch_id: id, p_sales_order_id: so ?? undefined })
        if (issued.error) return new NextResponse(await localizeCoaError(issued.error.message), { status: 400 })
        const r = issued.data as unknown as { coa_id: string; code: string; snapshot: CoaSnapshot }

        // ② 照【它返回的那一份快照】渲染 —— 不回读
        const buf = await renderCoaPdf(r.snapshot, 'issued')
        const sha = createHash('sha256').update(buf).digest('hex')
        // 【键不含哈希】两张证书的字节可能逐字相同;用 sha 当键会让后一份覆盖前一份
        const path = `${r.coa_id}/${crypto.randomUUID()}.pdf`
        const up = await supabase.storage.from(COA_BUCKET).upload(path, buf, { contentType: 'application/pdf' })
        if (up.error) return new NextResponse(`Upload failed: ${up.error.message}`, { status: 500 })

        const rec = await supabase.rpc('record_coa_issue', { p_coa_id: r.coa_id, p_file_path: path, p_sha256: sha })
        if (rec.error) {
            // 记录失败 → 把孤儿对象清掉。证书本身仍然是已签发的(号已铸、快照在),照快照补一次字节即可。
            const rm = await supabase.storage.from(COA_BUCKET).remove([path])
            const why = await localizeCoaError(rec.error.message)
            return new NextResponse(rm.error ? `${why}\n(The uploaded file could not be removed: ${rm.error.message})` : why, { status: 400 })
        }
        return NextResponse.json({ coa_id: r.coa_id, code: r.code })
    } catch (e) {
        return new NextResponse(`Issue failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}

// ── 存 PDF(Q24):一张已签发、没有字节的证书 —— 照存下的快照再渲染一遍,存桶,记哈希 ─────────────────────────────
//   读证书走 certificates_of_analysis 的读策略(module.output.view);上传要 action.issue_coa(桶的上传策略),记哈希要它(record_coa_issue)。
//   作废的、已经有字节的,record_coa_issue 按名拒(COA_NOT_ISSUED · COA_BYTES_ALREADY_RECORDED);这里先问一次"已有字节",免得传一个孤儿。
async function storeMissingBytes(batchId: string, coaId: string): Promise<NextResponse> {
    if (!UUID_RE.test(coaId)) return new NextResponse('Not found', { status: 404 })
    const supabase = await createClient()
    const cert = mustOne(
        await supabase.from('certificates_of_analysis').select('id, code, status, snapshot').eq('id', coaId).eq('output_batch_id', batchId).maybeSingle(),
        'certificates_of_analysis'
    ) as { id: string; code: string; status: string; snapshot: CoaSnapshot | null } | null
    if (!cert || !cert.snapshot) return new NextResponse('Not found', { status: 404 })
    const had = mustOne(await supabase.from('coa_issues').select('coa_id').eq('coa_id', cert.id).maybeSingle(), 'coa_issues')
    if (had) return new NextResponse(await localizeCoaError(`COA_BYTES_ALREADY_RECORDED|${cert.code}`), { status: 400 })
    if (cert.status !== 'issued') return new NextResponse(await localizeCoaError(`COA_NOT_ISSUED|${cert.code}|${cert.status}`), { status: 400 })
    // 照【存下的那一份】渲染 —— 不回读、不重组;字体检查在 renderCoaPdf 里(画不出来就抛,什么都不传)
    const buf = await renderCoaPdf(cert.snapshot, 'issued')
    const sha = createHash('sha256').update(buf).digest('hex')
    const path = `${cert.id}/${crypto.randomUUID()}.pdf`
    const up = await supabase.storage.from(COA_BUCKET).upload(path, buf, { contentType: 'application/pdf' })
    if (up.error) return new NextResponse(`Upload failed: ${up.error.message}`, { status: 500 })
    const rec = await supabase.rpc('record_coa_issue', { p_coa_id: cert.id, p_file_path: path, p_sha256: sha })
    if (rec.error) {
        const rm = await supabase.storage.from(COA_BUCKET).remove([path])
        const why = await localizeCoaError(rec.error.message)
        return new NextResponse(rm.error ? `${why}\n(The uploaded file could not be removed: ${rm.error.message})` : why, { status: 400 })
    }
    return NextResponse.json({ coa_id: cert.id, code: cert.code, stored: true })
}
