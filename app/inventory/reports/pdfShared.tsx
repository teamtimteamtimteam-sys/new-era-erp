// RPT-1:四条 PDF 路由共用的落地零件。
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import ReportDocument, { type ReportColumn } from './ReportDocument'
import { todayStamp } from './reportShared'
import type { ReactElement } from 'react'

// 【生成时刻按请求方的语言格式化】—— 报表是给打开它的人看的(见 ReportDocument 抬头)
export async function renderReport(opts: {
    name: string
    titleKey: string
    filters: string
    columns: ReportColumn[]
    rows: string[][]
}): Promise<Response> {
    const t = await getTranslations()
    const locale = await getLocale()
    const doc = (
        <ReportDocument
            title={t(opts.titleKey)}
            generatedAtLabel={t('reports.pdfGeneratedAt')}
            generatedAt={new Date().toLocaleString(locale === 'zh' ? 'zh-CN' : 'en-US')}
            filtersLabel={t('reports.pdfFilters')}
            filters={opts.filters || t('reports.pdfNoFilters')}
            localeLabel={t('reports.pdfLocale')}
            locale={locale}
            columns={opts.columns}
            rows={opts.rows}
            emptyText={t('reports.pdfEmpty')}
            pageLabel={t('reports.pdfPage')}
        />
    )
    const buf = await renderToBuffer(doc as unknown as ReactElement<DocumentProps>)
    return new Response(new Uint8Array(buf), {
        headers: {
            'Content-Type': 'application/pdf',
            'Content-Disposition': `inline; filename="${opts.name}-${todayStamp()}.pdf"`,
        },
    })
}

// 【失败要说得出原因】字体覆盖守卫会在遇到裁剪范围外的字时抛错 —— 那时给一句
// 能行动的话(改用 CSV),而不是一个 500 白屏。同 exportFailed 的判断:
// 一份空白/损坏的 PDF 与"没有数据"长得一样,而前者是错误。
export function pdfFailed(e: unknown): Response {
    const msg = (e as { message?: string })?.message ?? String(e)
    return new Response(`PDF failed: ${msg}`, { status: 500 })
}
