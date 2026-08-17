// app/output/[id]/traceability/pdf/route.ts
// AUD-2:客户审计报告(可追溯报告)的三个入口,形状逐字取自 so_issues 那一族:
//   GET             预览 —— 按【当前】数据渲染,inline 打开,不落档
//   GET ?version=N  取【签发档】—— 从桶里流出当时存下的字节,并对着
//                   traceability_report_issues.sha256 校验:对象被动过就拒绝
//   POST            签发 —— 渲染、存桶、record_traceability_report_issue() 记档
//
// 【语言:跟随界面语言(RPT-1 的报表政策),不是发票那条"一律英文"】
// 理由与 ReportDocument 抬头写的是同一条,但这一份多一层:发票与采购单是
// 【签发给外部的商业单据】,收件人不是这套系统的用户,所以一律英文;
// 而可追溯报告是【应某个人的要求、在他面前生成的一份说明】—— 中文客户要的是
// 中文的那一份,英文客户要的是英文的那一份,而决定这件事的正是生成它的人此刻
// 选的界面语言。ReportDocument 的表头块【印出它是用哪种语言渲染的】,
// 所以一份中文的档案不会被误认成"发错了语言的英文件"。
// 【签发档因此是"那一刻、那种语言"的字节】—— 换一种语言重发就是新的一版,
// 而那正是版本存在的意义。
//
// 【数据一律来自 traceability_report_data】本路由不做任何推导:血缘、回收率、
// 出处三列全部原样搬过来(AUD-1 的全部要点在那个函数里)。
import { NextResponse } from 'next/server'
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer'
import { createHash } from 'node:crypto'
import type { ReactElement } from 'react'
import { createClient } from '@/lib/supabase/server'
import { mustOne } from '@/lib/db-helpers'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import ReportDocument from '@/app/inventory/reports/ReportDocument'
import { localizeTraceabilityError } from '@/app/output/traceabilityErrorCodes'
import {
    fetchTraceability,
    chainRows,
    recoveryRows,
    type TraceabilityReport,
} from '@/app/output/traceabilityShared'

const BUCKET = 'traceability-documents'

async function render(rep: TraceabilityReport): Promise<Buffer> {
    const t = await getTranslations()
    const locale = await getLocale()
    const b = rep.output_batch
    const doc = (
        <ReportDocument
            title={t('traceability.pdfTitle', { code: b.code })}
            generatedAtLabel={t('reports.pdfGeneratedAt')}
            generatedAt={new Date().toLocaleString(locale === 'zh' ? 'zh-CN' : 'en-US')}
            // 【表头块要说清这份东西是关于哪一批料的】—— 客户手里只有这张纸。
            filtersLabel={t('traceability.pdfBatchLabel')}
            filters={`${b.code} · ${b.material_code ?? '—'} ${b.material_name ?? ''} · ${b.quantity} ${b.unit ?? ''}`}
            localeLabel={t('reports.pdfLocale')}
            locale={locale}
            columns={[
                { header: t('traceability.colStep'), width: 44, align: 'right' },
                { header: t('traceability.colRun'), width: 110 },
                { header: t('traceability.colParent'), width: 150 },
                { header: t('traceability.colQtyConsumed'), width: 90, align: 'right' },
                { header: t('traceability.colSupplier'), width: 190 },
                { header: t('traceability.colArrival'), width: 90 },
            ]}
            rows={chainRows(rep, t)}
            sections={[
                {
                    heading: t('traceability.recoveryHeading'),
                    columns: [
                        { header: t('traceability.colRun'), width: 110 },
                        { header: t('traceability.colMetal'), width: 80 },
                        { header: t('traceability.colInputKg'), width: 80, align: 'right' },
                        { header: t('traceability.colOutputKg'), width: 80, align: 'right' },
                        { header: t('traceability.colRecovery'), width: 150, align: 'right' },
                        // 【出处跟着数字走 —— PDF 里也是】一个只拿到这张纸的客户,
                        // 必须看得见这个百分比是拿哪一种数除出来的。
                        { header: t('traceability.colInputSource'), width: 90 },
                        { header: t('traceability.colOutputSource'), width: 90 },
                    ],
                    rows: recoveryRows(rep, t),
                },
            ]}
            // 【绝不让客户只看见一个光秃秃的百分比】
            note={t('traceability.estimateNote')}
            emptyText={t('reports.pdfEmpty')}
            pageLabel={t('reports.pdfPage')}
        />
    )
    return renderToBuffer(doc as unknown as ReactElement<DocumentProps>)
}

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const version = new URL(request.url).searchParams.get('version')
    try {
        const supabase = await createClient()

        if (version) {
            const issue = mustOne(
                await supabase.from('traceability_report_issues').select('file_path, sha256, code')
                    .eq('output_batch_id', id).eq('version', Number(version)).maybeSingle(),
                'traceability_report_issues') as { file_path: string; sha256: string; code: string } | null
            if (!issue) return new NextResponse('Not found', { status: 404 })
            const dl = await supabase.storage.from(BUCKET).download(issue.file_path)
            if (dl.error || !dl.data) return new NextResponse('Stored document unavailable', { status: 404 })
            const bytes = Buffer.from(await dl.data.arrayBuffer())
            const sha = createHash('sha256').update(bytes).digest('hex')
            if (sha !== issue.sha256) {
                // 【对不上就拒绝】一份与记录不符的"档案"比没有档案更坏
                return new NextResponse('Stored document does not match its recorded digest', { status: 409 })
            }
            return new NextResponse(new Uint8Array(bytes), {
                headers: { 'Content-Type': 'application/pdf',
                           'Content-Disposition': `inline; filename="${issue.code}-v${version}.pdf"` },
            })
        }

        const rep = await fetchTraceability(supabase, id)
        // 【服务端的具名拒绝原样翻成人话】NOTHING_TO_REPORT 不是 500。
        if ('error' in rep) {
            return new NextResponse(await localizeTraceabilityError(rep.error), { status: 400 })
        }
        const buf = await render(rep)
        return new NextResponse(new Uint8Array(buf), {
            headers: { 'Content-Type': 'application/pdf',
                       'Content-Disposition': `inline; filename="${rep.output_batch.code}-traceability.pdf"` },
        })
    } catch (e) {
        return new NextResponse(`PDF failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}

export async function POST(_request: Request, { params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    try {
        const supabase = await createClient()
        const rep = await fetchTraceability(supabase, id)
        if ('error' in rep) {
            return new NextResponse(await localizeTraceabilityError(rep.error), { status: 400 })
        }
        const buf = await render(rep)
        const sha = createHash('sha256').update(buf).digest('hex')
        // 对象键不含版本号 —— 版本由 record_traceability_report_issue 在数据库里裁决
        // (并发安全)。【键必须唯一】:同一批料重发一版,字节可能与上一版逐字相同
        // (数据没变、语言没变),用 sha 当键会让第二版覆盖第一版的对象 ——
        // 于是两行档案指向同一份字节,而"第 1 版当时是什么"就没有答案了。
        const path = `${id}/${crypto.randomUUID()}.pdf`
        const up = await supabase.storage.from(BUCKET).upload(path, buf, {
            contentType: 'application/pdf',
        })
        if (up.error) return new NextResponse(`Upload failed: ${up.error.message}`, { status: 500 })

        const { data, error } = await supabase.rpc('record_traceability_report_issue', {
            p_output_batch_id: id, p_file_path: path, p_sha256: sha,
        })
        if (error) {
            // 记录失败 → 把孤儿对象清掉再报错:桶里不该留一份没有档案的"签发件"
            await supabase.storage.from(BUCKET).remove([path])
            return new NextResponse(await localizeTraceabilityError(error.message), { status: 400 })
        }
        return NextResponse.json(data)
    } catch (e) {
        return new NextResponse(`Issue failed: ${(e as { message?: string })?.message ?? String(e)}`, { status: 500 })
    }
}
