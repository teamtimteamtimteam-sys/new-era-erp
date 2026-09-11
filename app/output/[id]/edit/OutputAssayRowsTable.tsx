'use client'

// app/output/[id]/edit/OutputAssayRowsTable.tsx
// TABLE-CONVERT-5:OutputAssaySection 的化验列表换成 DataTable。
//
// ★★【这一张的判断【靠的是它的孪生兄弟,不是它自己的读数】—— 照直说】★★
//   TABLE-MEASURE-1 量不到它:线上【一条产出批次化验都没有】,所以
//   `rows.length === 0` 那一支成立,表根本不渲染(TM-1 §5,本刀开工时又独立查过一次,
//   仍然是 0 行)。量具没有替它编一份读数,那是对的。
//   ☞ 于是这里的列选【完全建立在 inbound 那张 AssaySection 的读数上】:
//     两处的列头签名逐字相同(assay.colCode / colDate / colLab / colKind / colApplied),
//     行的字段也逐字相同。**但相同的标记不等于相同的读数** ——
//     产出侧的化验号、实验室名可能比进料侧长,而列宽由最宽的那一格定。
//     ☞ **这一条要等线上第一张产出化验落地那天才有真读数。**
//
// 【列选与理由,与 inbound/[id]/edit/AssayRowsTable.tsx 逐字同一份】
//   留:化验号(身份、也是链接)· 已应用(结论 —— 没应用意味着批次含量还停在旧数上,
//       而回收率与 metal_value 分摊读的都是批次含量)。
//   折:化验日期 · 实验室 · 类型 —— 都是认出这一行之后才问的。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type OutputAssayRow = {
    id: string
    code: string
    assay_date: string
    lab_name: string | null
    is_final: boolean
    applied_at: string | null
}

export default function OutputAssayRowsTable({
    batchId,
    rows,
}: {
    batchId: string
    rows: readonly OutputAssayRow[]
}) {
    const t = useTranslations()

    const columns: Column<OutputAssayRow>[] = [
        {
            key: 'code',
            header: t('assay.colCode'),
            // ★ 身份 —— 手机上留下。
            priority: true,
            className: 'font-mono',
            render: (r) => (
                <Link
                    href={`/output/${batchId}/assays/${r.id}`}
                    className="hover:underline app-link"
                >
                    {r.code}
                </Link>
            ),
        },
        {
            key: 'date',
            header: t('assay.colDate'),
            render: (r) => r.assay_date,
        },
        {
            key: 'lab',
            header: t('assay.colLab'),
            render: (r) => r.lab_name ?? '—',
        },
        {
            key: 'kind',
            header: t('assay.colKind'),
            render: (r) => (
                <span
                    className={
                        'px-2 py-0.5 rounded text-xs ' +
                        (r.is_final ? 'bg-gray-200 text-gray-700' : 'bg-amber-100 text-amber-800')
                    }
                >
                    {r.is_final ? t('assay.kindFinal') : t('assay.kindPreliminary')}
                </span>
            ),
        },
        {
            key: 'applied',
            header: t('assay.colApplied'),
            // ★ 结论 —— 手机上留下。
            priority: true,
            render: (r) => (
                <span
                    className={
                        'px-2 py-0.5 rounded text-xs ' +
                        (r.applied_at ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-600')
                    }
                >
                    {r.applied_at ? t('assay.applied') : t('assay.notApplied')}
                </span>
            ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            // 空态从 OutputAssaySection 的 `rows.length === 0 ?` 那一支搬进来,【同一个 key】。
            // ★ 而线上今天【每一次】走的都是这一支 —— 它不是边角情形,它是现状。
            empty={t('assay.empty')}
        />
    )
}
