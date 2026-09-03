'use client'

// app/hr/kpi/KpiMatrixTable.tsx
// CONV-5 · KPI 联动矩阵(职位级)那一张表。
//
// 【这一页只有这一张表换了】组织记分卡是一叠卡片、在册/出缺是一份名单 ——
// 两者都不是登记簿,套 DataTable 只会把它们压成不是它们的形状。
// 按 Tim 在 CONV-5 Q2 的裁定:真正的行登记簿才换,报告体保持原样。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type KpiMatrixRow = {
    positionCode: string
    positionTitle: string
    o1: number
    o2: number
    o3: number
    o4: number
    o5: number
    kpiCount: number
    weightTotal: number
}

export default function KpiMatrixTable({ rows, empty }: { rows: KpiMatrixRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【职位】与【KPI 条数】—— 职位是身份;而这张矩阵回答的是
    //   "这个职位到底挂了几条 KPI",O1–O5 那五列是拆开看时才要问的东西。
    //   ★ 权重合计【不】进手机列:页顶那句 matrixNotWeights 明说这张矩阵
    //     不是权重表,把它单独留在小屏上会正好造成那句话要防的误读。
    const columns: Column<KpiMatrixRow>[] = [
        {
            key: 'position', header: t('kpi.colPosition'), priority: true, className: 'text-sm',
            render: (r) => (
                <>
                    <span className="font-mono text-xs text-gray-500">{r.positionCode}</span> · {r.positionTitle}
                </>
            ),
        },
        { key: 'o1', header: 'O1', align: 'right', className: 'text-sm', render: (r) => r.o1 },
        { key: 'o2', header: 'O2', align: 'right', className: 'text-sm', render: (r) => r.o2 },
        { key: 'o3', header: 'O3', align: 'right', className: 'text-sm', render: (r) => r.o3 },
        { key: 'o4', header: 'O4', align: 'right', className: 'text-sm', render: (r) => r.o4 },
        { key: 'o5', header: 'O5', align: 'right', className: 'text-sm', render: (r) => r.o5 },
        {
            key: 'kpiCount', header: t('kpi.colKpiCount'), priority: true, align: 'right', className: 'text-sm',
            render: (r) => r.kpiCount,
        },
        { key: 'weightTotal', header: t('kpi.colWeightTotal'), align: 'right', className: 'text-sm', render: (r) => r.weightTotal },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.positionCode}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
