// app/compliance/packs/[id]/pdf/route.ts
// MES-8b-1(2026-10-17,MES-0 Q82 · MES-8 Step 0 Q16,Tim):合规包 PDF。三个入口,形状取自供应商对账单那一份:
//   GET             渲染【冻下来的 payload】(compliance_packs —— 八节与抬头都在这一行里),inline 打开,不落档;不重算、不读活的公司资料
//   GET ?version=N  取签发档:从私有桶 compliance-documents 流出当时的字节,并对着 compliance_pack_issues.sha256 重算校验 ——
//                   对不上就 409(一份与记录不符的"档案"比没有档案更坏)
//   POST            存档:从冻下来的 payload 渲染、存桶(键 <包 id>/<sha256>.pdf)、record_compliance_pack_issue() 记版本与哈希;
//                   记失败 → 把刚传的对象删掉(桶里不该留一份没有档案的字节;删除策略只放行【没被记下的】对象)
// ★【一律英文】—— 措辞取 messages/en.ts 的 compliancePacks.doc.*(在 renderPack.ts 里,MESSAGES.en 显式)。
// 门:读 module.compliance.view(compliance_packs 的读策略 + 桶的读策略);存档 action.compliance_pack(record_compliance_pack_issue + 桶的上传策略)。
import { NextResponse } from 'next/server'
import { createHash } from 'node:crypto'
import { createClient } from '@/lib/supabase/server'
import { mustOne } from '@/lib/db-helpers'
import { localizeComplianceError } from '../../complianceErrorCodes'
import { packDocFrom, renderCompliancePackPdf, type CompliancePackRow } from './renderPack'

const BUCKET = 'compliance-documents'

// 【只读冻下来的那一行】—— 渲染那一半在 renderPack.ts(入参只有这一行;线上证明调的也是它)
async function loadDoc(id: string) {
    const supabase = await createClient()
    const pk = mustOne(
        await supabase.from('compliance_packs')
            .select('id, code, period_month, period_start, period_end, locked_before_at_freeze, payload, frozen_at, superseded_at')
            .eq('id', id).maybeSingle(),
        'compliance_packs') as unknown as CompliancePackRow | null
    if (!pk) return null
    return packDocFrom(pk)
}

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const version = new URL(request.url).searchParams.get('version')
    try {
        const supabase = await createClient()
        if (version) {
            const issue = mustOne(
                await supabase.from('compliance_pack_issues').select('file_path, sha256')
                    .eq('pack_id', id).eq('version', Number(version)).maybeSingle(),
                'compliance_pack_issues') as { file_path: string; sha256: string } | null
            if (!issue) return new NextResponse('Not found', { status: 404 })
            const dl = await supabase.storage.from(BUCKET).download(issue.file_path)
            if (dl.error || !dl.data) return new NextResponse('Stored document unavailable', { status: 404 })
            const bytes = Buffer.from(await dl.data.arrayBuffer())
            const sha = createHash('sha256').update(bytes).digest('hex')
            if (sha !== issue.sha256) {
                return new NextResponse('Stored document does not match its recorded digest', { status: 409 })
            }
            return new NextResponse(new Uint8Array(bytes), {
                headers: { 'Content-Type': 'application/pdf', 'Content-Disposition': `inline; filename="${id}-v${version}.pdf"` },
            })
        }
        const d = await loadDoc(id)
        if (!d) return new NextResponse('Not found', { status: 404 })
        const buf = await renderCompliancePackPdf(d)
        return new NextResponse(new Uint8Array(buf), {
            headers: { 'Content-Type': 'application/pdf', 'Content-Disposition': `inline; filename="${d.code}.pdf"` },
        })
    } catch (e) {
        return new NextResponse(`PDF failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}

export async function POST(_request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    try {
        const supabase = await createClient()
        const d = await loadDoc(id)
        if (!d) return new NextResponse('Not found', { status: 404 })
        const buf = await renderCompliancePackPdf(d)
        const sha = createHash('sha256').update(buf).digest('hex')
        const path = `${id}/${sha}.pdf`
        // 同一串字节已经记过(同一份包渲染出逐字相同的 PDF)→ 不再传一次:库会按名拒,而桶里那一份正是它 —— 先问,免得传一个孤儿
        const had = mustOne(await supabase.from('compliance_pack_issues').select('version')
            .eq('pack_id', id).eq('sha256', sha).maybeSingle(), 'compliance_pack_issues') as { version: number } | null
        if (had) return new NextResponse(await localizeComplianceError(`COMPLIANCE_PACK_BYTES_ALREADY_RECORDED|${d.code}|${had.version}`), { status: 400 })
        const up = await supabase.storage.from(BUCKET).upload(path, buf, { contentType: 'application/pdf' })
        if (up.error) return new NextResponse(`Upload failed: ${up.error.message}`, { status: 500 })
        const { data, error } = await supabase.rpc('record_compliance_pack_issue', {
            p_pack_id: id, p_file_path: path, p_sha256: sha,
        })
        if (error) {
            await supabase.storage.from(BUCKET).remove([path])
            return new NextResponse(await localizeComplianceError(error.message), { status: 400 })
        }
        return NextResponse.json(data)
    } catch (e) {
        return new NextResponse(`Issue failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}
