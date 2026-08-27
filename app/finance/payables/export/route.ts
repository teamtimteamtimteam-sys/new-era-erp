// app/finance/payables/export/route.ts
// AP 账龄的 CSV 导出(Next 16 Route Handler)。端口自
// app/finance/gst/[periodId]/export —— 抬头块说明这一份【是什么】,理由见 agingCsv.ts。
//
// 【为什么是 CSV】账龄是 CFO 最想拿进电子表格的那一张:要排序、要透视、
// 要贴进邮件、要与银行对账单并排。PDF 好看而算不了,而这一份的用途是【算】。
//
// 【读的是与页面同一支函数】ap_aging_asof(as_of) —— 屏幕上那个数与附件里那个数
// 必须是同一个数,见 app/finance/agingAsOf.ts 抬头。
//
// 【失败必须失败】读不到就报错,绝不返回一份只有抬头的空文件 ——
// 那读起来是"这一天没有欠款",是一句假话(mustRows 同一条规矩)。
import type { NextRequest } from 'next/server'
import { readAging, parseAsOf, type AgingRowAp } from '../../agingAsOf'
import { agingCsvHeader, agingCsvFilename } from '../../agingCsv'
import { csvRow, csvResponse } from '@/lib/csv'
import { localizeFinanceError } from '../../financeErrorCodes'

// 明细列头用稳定的英文(仓库里十条导出路由同一惯例:机器可读、不随界面语言变)。
const HEADERS = [
    'Document',
    'Kind',
    'Counterparty',
    'Counterparty Type',
    'Document Date',
    'Due Date',
    'Days Outstanding',
    'Bucket',
    'Currency',
    'Open (document currency)',
    'Amount (base)',
    'Settled (base)',
    'Open (base)',
]

export async function GET(request: NextRequest) {
    const asOf = parseAsOf({ as_of: request.nextUrl.searchParams.get('as_of') ?? undefined })

    let report
    try {
        report = await readAging<AgingRowAp>('ap', asOf)
    } catch (e) {
        // 具名拒绝(AGING_AS_OF_FUTURE / 权限)按名译出来再送走 ——
        // 一串机器文本落在浏览器里,读的人无从判断是自己填错了还是系统坏了。
        const msg = await localizeFinanceError(e instanceof Error ? e.message : String(e))
        return new Response(msg, { status: 400 })
    }

    const lines = await agingCsvHeader(report, 'AP AGEING')
    lines.push(csvRow(HEADERS))
    for (const r of report.rows) {
        lines.push(
            csvRow([
                r.doc_code,
                r.doc_kind,
                r.counterparty_name,
                r.counterparty_kind,
                r.doc_date,
                r.due_date ?? '',
                r.days_outstanding,
                r.bucket,
                r.currency,
                r.open_ccy,
                r.doc_value_base,
                r.settled_base,
                r.open_base,
            ]),
        )
    }

    return csvResponse(lines, agingCsvFilename('ap', report.as_of))
}
