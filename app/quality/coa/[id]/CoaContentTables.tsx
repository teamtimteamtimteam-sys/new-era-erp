'use client'

// app/quality/coa/[id]/CoaContentTables.tsx
// MES-6b-2 · 证书页上"证书说了什么"的两张表 —— 成分(惩罚元素旁边是 ppm)与点了单时合同的验收限和判定。全部读快照(签发那一刻冻住的),
//   不读活数据。手机上留物质与含量、参数与判定。
//
// ★ TABLE-EXPORT-3c(Tim 2026-10-25):两张表各一对导出。导出读的也是【快照里的原始值】(*Raw),
//   不读屏幕上拼好的字(「12.5%」「— 」「120 ppm」)—— 页面把快照里的数原样递过来。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xNum, xText } from '@/lib/export/cells'

export type CompositionRow = {
    substance: string; label: string; content: string; ppm: string
    /** TABLE-EXPORT-3c:快照里的 content_pct 本身 */
    contentRaw: number | string
    /** TABLE-EXPORT-3c:惩罚元素的 ppm(与屏幕同一个换算、同一个取整);别的物质 null(屏幕上那一格是空的) */
    ppmRaw: number | null
}
export type LimitRow = {
    parameter: string; label: string; min: string; max: string; measured: string; judgement: string
    /** TABLE-EXPORT-3c:快照里的原始限值 / 实测值(null = 合同没写 / 没有判定 —— 屏幕上的「—」) */
    minRaw: number | string | null; maxRaw: number | string | null; measuredRaw: number | string | null
    /** TABLE-EXPORT-3c:判定那一格的主值 —— 结果(或「未判定」),不带后面那个化验单号 */
    judgementResult: string
}

export function CoaCompositionTable({ rows, coaCode }: { rows: CompositionRow[]; coaCode: string }) {
    const t = useTranslations()
    // 含量的表头已经写着 %,所以那一格是一个光秃秃的数。
    //   ★ 档位用 'qty'(#,##0.####)而不是 'pct'(0.00):惩罚元素恰恰是那些 0.0012% 的,0.00 的格式会把它们在 Excel 里显示成 0.00。
    //   值本身两种档位都一样,不改。ppm 那一列同理:表头就是单位,格子是数;不是惩罚元素的那几行屏幕上是空的 → 导出空。
    const columns: ExportableColumn<CompositionRow>[] = [
        { key: 'substance', header: t('coa.detail.substance'), priority: true, render: (r) => r.label, exportAs: (r) => xText(r.label) },
        { key: 'content', header: t('coa.detail.contentPct'), priority: true, align: 'right', render: (r) => r.content,
          exportAs: (r) => xNum(r.contentRaw, 'qty') },
        { key: 'ppm', header: 'ppm', render: (r) => r.ppm, exportAs: (r) => xNum(r.ppmRaw, 'qty') },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.substance} phone={{ mode: 'columns' }} empty="—"
        exportSpec={{ name: 'quality-coa-composition', title: t('coa.detail.content'), aboutExtra: [[t('coa.col.code'), coaCode]] }} />
}

export function CoaLimitsTable({ rows, coaCode }: { rows: LimitRow[]; coaCode: string }) {
    const t = useTranslations()
    // 限值与实测值:格子里是数,单位在参数那一格的括号里(与屏幕一样)—— 导出照样:数是数,单位跟着参数名走。
    // 判定那一格屏幕上叠着「结果 · 化验单号」→ 导出写结果(主值);化验单号是哪一张单子判的,不是判定本身。
    const columns: ExportableColumn<LimitRow>[] = [
        { key: 'parameter', header: t('coa.detail.parameter'), priority: true, render: (r) => r.label, exportAs: (r) => xText(r.label) },
        { key: 'min', header: t('coa.detail.min'), render: (r) => r.min, exportAs: (r) => xNum(r.minRaw, 'qty') },
        { key: 'max', header: t('coa.detail.max'), render: (r) => r.max, exportAs: (r) => xNum(r.maxRaw, 'qty') },
        { key: 'measured', header: t('coa.detail.measured'), render: (r) => r.measured, exportAs: (r) => xNum(r.measuredRaw, 'qty') },
        { key: 'judgement', header: t('coa.detail.judgement'), priority: true, render: (r) => r.judgement, exportAs: (r) => xText(r.judgementResult) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.parameter} phone={{ mode: 'columns' }} empty="—"
        exportSpec={{ name: 'quality-coa-limits', title: t('coa.detail.limits'), aboutExtra: [[t('coa.col.code'), coaCode]] }} />
}
