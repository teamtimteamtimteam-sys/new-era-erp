'use client'

// app/quality/disputes/[id]/MetalsTable.tsx
// MES-6a-1 · 争议页上三份结果并排:我们的 · 对手方的 · 仲裁的,以及前两份的差与是否超出立案时在案的容差。数取自 assay_dispute_metals。
//
// ★ TABLE-EXPORT-3c(Tim 2026-10-25):一对导出,读 assay_dispute_metals 的原始数(*Raw),不读拼好的「12.3 %」。
//   三份结果的格子里写着「%」→ xNum(v, 'qty', '%');差那一列表头写着单位(点)→ 光秃秃的数。
//   ★【差那一格的「超出容差」】屏幕上它跟在数后面(琥珀色 + 「· 超出容差」)。导出写那个【数】(主值);
//     「超出」不另成一格 —— 与 docs/table-export.md「一个值旁边的标记不导出,导出它所概括的那个值」同一条。
//     代价是那个判断要能从文件里重算出来,所以 About 表上写明【立案时在案的容差】(与页面抬头同一个字):
//     差 > 容差 即超出。容差没设时那一行写「未设」,于是文件里也说得出"没有可比的线"。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xNum, xText } from '@/lib/export/cells'

export type MetalRow = {
    metal: string; ours: string; counterparty: string; umpire: string; diff: string; beyond: boolean
    /** TABLE-EXPORT-3c:assay_dispute_metals 的原始数(%,差是点数);null = 没有那一份 */
    oursRaw: number | null; counterpartyRaw: number | null; umpireRaw: number | null; diffRaw: number | null
}

export default function MetalsTable({ rows, batchCode, limitText }: {
    rows: MetalRow[]
    /** TABLE-EXPORT-3c:About 表 —— 哪一批的争议 */
    batchCode: string
    /** TABLE-EXPORT-3c:About 表 —— 立案时在案的容差(页面抬头那一格的字,已译好) */
    limitText: string
}) {
    const t = useTranslations()
    const columns: ExportableColumn<MetalRow>[] = [
        { key: 'metal', header: t('quality.dispute.colMetal'), priority: true, render: (r) => r.metal, exportAs: (r) => xText(r.metal) },
        { key: 'ours', header: t('quality.party.ours'), priority: true, render: (r) => r.ours, exportAs: (r) => xNum(r.oursRaw, 'qty', '%') },
        { key: 'counterparty', header: t('quality.party.counterparty'), priority: true, render: (r) => r.counterparty,
          exportAs: (r) => xNum(r.counterpartyRaw, 'qty', '%') },
        { key: 'umpire', header: t('quality.party.umpire'), render: (r) => r.umpire, exportAs: (r) => xNum(r.umpireRaw, 'qty', '%') },
        { key: 'diff', header: t('quality.dispute.colDiff'),
          render: (r) => <span className={r.beyond ? 'text-amber-700' : undefined}>{r.diff}{r.beyond ? ` · ${t('quality.dispute.beyond')}` : ''}</span>,
          exportAs: (r) => xNum(r.diffRaw, 'qty') },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.metal} phone={{ mode: 'columns' }} empty="—"
        exportSpec={{ name: 'quality-dispute-metals', title: t('quality.dispute.metalsTitle'),
                      aboutExtra: [[t('quality.disputes.colBatch'), batchCode], [t('quality.dispute.limit'), limitText]] }} />
}
