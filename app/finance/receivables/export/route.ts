// app/finance/receivables/export/route.ts
// AR 账龄的 CSV 导出。与 payables 侧逐条同源(抬头块与文件名共用 agingCsv.ts),
// 只有明细列不同 —— AR 多一列【已贷记】,那是"不用付了"而不是"付过了"。
//
// 【为什么已贷记要单独一列而不是并进已结】在客户那里它们是两件完全不同的事:
// 收过钱 vs 不用付了。CN-1 在视图里就把它们分了列,这里不许合回去,
// 否则这张表上 金额 − 已结 ≠ 未结,读的人会以为算错了。
import type { NextRequest } from 'next/server'
import { readAging, parseAsOf, type AgingRowAr } from '../../agingAsOf'
import { agingCsvHeader, agingCsvFilename } from '../../agingCsv'
import { csvRow, csvResponse } from '@/lib/csv'
import { localizeFinanceError } from '../../financeErrorCodes'

const HEADERS = [
    'Document',
    'Kind',
    'Invoice',
    'Customer',
    'Document Date',
    'Due Date',
    'Days Outstanding',
    'Bucket',
    'Currency',
    'Open (document currency)',
    'Amount (base)',
    'Settled (base)',
    'Credited (base)',
    'Open (base)',
]

export async function GET(request: NextRequest) {
    const asOf = parseAsOf({ as_of: request.nextUrl.searchParams.get('as_of') ?? undefined })

    let report
    try {
        report = await readAging<AgingRowAr>('ar', asOf)
    } catch (e) {
        const msg = await localizeFinanceError(e instanceof Error ? e.message : String(e))
        return new Response(msg, { status: 400 })
    }

    const lines = await agingCsvHeader(report, 'AR AGEING')
    lines.push(csvRow(HEADERS))
    for (const r of report.rows) {
        lines.push(
            csvRow([
                r.doc_code,
                r.doc_kind,
                r.invoice_code ?? '',
                r.customer_name ?? '',
                r.sale_date,
                r.due_date ?? '',
                r.days_outstanding,
                r.bucket,
                r.currency,
                r.open_ccy,
                r.amount_base,
                r.settled_base,
                r.credited_base,
                r.open_base,
            ]),
        )
    }

    return csvResponse(lines, agingCsvFilename('ar', report.as_of))
}
