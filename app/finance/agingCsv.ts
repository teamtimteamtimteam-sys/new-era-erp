// app/finance/agingCsv.ts
// 两侧账龄导出【共用】的抬头块。AP 与 AR 的明细列不同,而抬头是同一件事:
// **这份文件是什么、截至哪一天、口径是什么、它【不含】什么。**
//
// ★【为什么抬头里必须有截至日,而不是只在文件名里】★
// 文件名会被改、会在邮件转发里丢掉、在别人的下载目录里变成 "aging (3).csv"。
// 一个没有截至日的账龄数字,过两周就是一个大家各执一词的数 ——
// 而这一刀的全部意义就是让"截至哪一天"变成那个数字自身的一部分。
// 端口自 app/finance/gst/[periodId]/export:那份 CSV 的抬头三行同样在说
// 「这一份是哪一种」,理由逐字相同。
//
// ★【它【不含】什么,也写在抬头里,而不是留给读的人猜】★
// 一份报表最容易被误用的地方不是它写了什么,是读的人以为它写了而其实没有。
// 所以三条缺席明写在文件第一屏:没有分组小计、没有结算明细、金额口径是什么。
import type { AgingReport } from './agingAsOf'
import { csvRow } from '@/lib/csv'
import { getTranslations } from '@/lib/i18n/server'

const BUCKETS = ['b0_30', 'b31_60', 'b61_90', 'b90_plus'] as const

export async function agingCsvHeader<R>(
    report: AgingReport<R>,
    titleEn: string,
): Promise<string[]> {
    const t = await getTranslations()
    const lines: string[] = []

    // 第一屏:这一份是什么、截至哪一天、是不是一个过去的时点
    lines.push(csvRow([titleEn, t('finance.agingAsOf.csvTitle')]))
    lines.push(csvRow(['As at / 截至', report.as_of]))
    lines.push(csvRow(['Generated on / 出表日', report.today]))
    lines.push(
        csvRow([
            'Position / 时点',
            report.is_past
                ? t('finance.agingAsOf.pastBanner', { date: report.as_of, today: report.today })
                : t('finance.agingAsOf.csvCurrent'),
        ]),
    )
    lines.push(csvRow(['Base currency / 本位币', report.base_currency]))
    lines.push(csvRow(['Amount basis / 金额口径', t('finance.agingAsOf.basis.' + report.amount_basis)]))

    if (report.unpriced_excluded !== null && report.unpriced_excluded > 0) {
        lines.push(
            csvRow([
                'Excluded / 缺席',
                t('finance.agingAsOf.unpricedExcluded', { n: String(report.unpriced_excluded) }),
            ]),
        )
    }
    if (report.before_system_start && report.system_start_date) {
        lines.push(
            csvRow([
                'Warning / 提醒',
                t('finance.agingAsOf.beforeSystemStart', { date: report.system_start_date }),
            ]),
        )
    }

    lines.push('')
    // 档位合计:屏幕上汇总条读的是【同一个 buckets 对象】,所以两处必然相等
    lines.push(csvRow(['Bucket / 档位', `Open (${report.base_currency}) / 未结`]))
    for (const b of BUCKETS) {
        lines.push(csvRow([t('finance.aging.' + b), report.buckets[b] ?? 0]))
    }
    lines.push(csvRow([t('finance.totalOpen'), report.total_open_base]))

    lines.push('')
    // 缺席三条,明写
    lines.push(csvRow(['Not in this file / 本文件不含', t('finance.agingAsOf.csvOmitsSubtotals')]))
    lines.push(csvRow(['', t('finance.agingAsOf.csvOmitsSettlementDetail')]))
    lines.push(csvRow(['', t('finance.agingAsOf.csvOmitsDueDates')]))
    lines.push('')

    return lines
}

/** 文件名也带上截至日 —— 抬头里那一份是判据,这一份是方便。 */
export function agingCsvFilename(side: 'ap' | 'ar', asOf: string): string {
    return `${side === 'ap' ? 'AP' : 'AR'}-aging-as-at-${asOf}.csv`
}
