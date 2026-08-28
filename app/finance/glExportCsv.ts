// app/finance/glExportCsv.ts
// GLEXPORT-1:总账 / 日记账导出的抬头块。
//
// ★【抬头是证据,文件名只是方便】★ 这句话是 agingCsv.ts 立下的,这里逐字继承:
// 文件名会被改、会在邮件转发里丢掉、在别人的下载目录里变成 "gl (3).csv"。
// 一份没有期间的分录明细,过两周就是一堆没有人说得清覆盖到哪天的行。
// 所以【这一份是什么、覆盖哪一段、什么时候出的、本位币是什么、它不含什么】
// 全部写在文件的第一屏,而不是留给读的人猜。
//
// ★【为什么要有"本文件不含"那一段】★ 一份报表最容易被误用的地方不是它写了什么,
// 是读的人以为它写了而其实没有。GL 导出最容易被误读的三条写在这里:
//   ① 它【含】被冲销的分录与它们的冲销件 —— 两边都在,净额才对。
//      一份只留 posted 的导出会丢原件留冲销件,净额刚好错成 −原件
//      (本仓库为这个病付过四次账,其中一次在线上错了几个月)。
//   ② 它【不含】年结结转分录,除非明确要;
//   ③ 金额是【本位币】与【原币】两列都给,而不是只给一个。
import { csvRow } from '@/lib/csv'
import { getTranslations } from '@/lib/i18n/server'

export type GlExportMeta = {
    from: string
    to: string
    today: string
    baseCurrency: string
    includeYearClose: boolean
    entryCount: number
    lineCount: number
}

export async function glCsvHeader(meta: GlExportMeta): Promise<string[]> {
    const t = await getTranslations()
    const lines: string[] = []

    lines.push(csvRow(['GENERAL LEDGER / 总账明细', t('glExport.csvTitle')]))
    lines.push(csvRow(['Period / 期间', `${meta.from} .. ${meta.to}`]))
    lines.push(csvRow(['Generated on / 出表日', meta.today]))
    lines.push(csvRow(['Base currency / 本位币', meta.baseCurrency]))
    lines.push(csvRow(['Entries / 分录数', meta.entryCount]))
    lines.push(csvRow(['Lines / 行数', meta.lineCount]))
    lines.push(csvRow(['Year-end close entries / 年结结转分录',
        meta.includeYearClose ? t('glExport.ycIncluded') : t('glExport.ycExcluded')]))

    lines.push('')
    // 缺席与口径,明写在第一屏
    lines.push(csvRow(['Note / 口径', t('glExport.csvReversalNote')]))
    lines.push(csvRow(['Not in this file / 本文件不含', t('glExport.csvOmitsSubtotals')]))
    lines.push(csvRow(['', t('glExport.csvOmitsOpeningBalances')]))
    lines.push('')

    return lines
}

/** 文件名也带上期间 —— 抬头里那一份是判据,这一份是方便。 */
export function glCsvFilename(from: string, to: string): string {
    return `general-ledger-${from}-to-${to}.csv`
}
