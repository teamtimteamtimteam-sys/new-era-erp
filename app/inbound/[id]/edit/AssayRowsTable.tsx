'use client'

// app/inbound/[id]/edit/AssayRowsTable.tsx
// TABLE-CONVERT-5:AssaySection 的化验列表换成 DataTable。
//
// ★★【这张表此前【没有】手机档判断 —— 本刀是第一个做的】★★
//   TABLE-PHONE 家族从没把它收进工作清单:转换前一处 hidden sm:table-cell 都没有,
//   五列在 390px 上靠外面那层 overflow-x-auto 横着拖(TABLE-MEASURE-1 实测 +22px)。
//   ☞ 所以下面这两列【不是搬运,是新判断】。前四刀每一次都是把手机家族已经做过的
//     判断搬过来;这一次没有东西可搬。
//
// ★【留哪两列 —— 化验号 · 已应用】
//   · 化验号:身份。人嘴里说的就是它(「ASY-2026-0001 那一张」),而且它就是那条链接。
//   · 已应用:这一行的【结论】。没应用意味着批次含量还停在旧数上,价格因此也停在旧数上
//     —— AssaySection.tsx 自己那行注释写着「这是钱没算对,要显眼」。
//   ☞ 读数说 390px 上【露一半的正好就是「已应用」】(TM-1 §6:④ 只差 22px,
//     4/5 完整,第 5 列 Applied 露一半)。**本刀把被切掉的那一列提成 priority。**
//
// ★【化验日期 / 实验室 / 类型 为什么折】
//   日期与实验室是出处,认出这一行之后才问。类型(初验/终验)最接近该留 ——
//   但它不是身份也不是结论,它是给结论加限定的;而在 table-fixed 下多留一列
//   要吃掉整整三分之一的屏宽(见 §列宽登记)。三样都在展开区里带着自己的列头。
//
// 【与 output/[id]/edit/OutputAssayRowsTable.tsx 是【同一次判断】】
//   两处的列头签名逐字相同(TABLE-CONVERT-0 §6.1 认出的那一组),
//   TABLE-MEASURE-1 §5 也逐字比对过。差别只有链接前缀(/inbound vs /output)。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type AssayRow = {
    id: string
    code: string
    assay_date: string
    lab_name: string | null
    is_final: boolean
    applied_at: string | null
}

export default function AssayRowsTable({
    batchId,
    rows,
}: {
    batchId: string
    rows: readonly AssayRow[]
}) {
    const t = useTranslations()

    const columns: Column<AssayRow>[] = [
        {
            key: 'code',
            header: t('assay.colCode'),
            // ★ 身份 —— 手机上留下。
            priority: true,
            // ⚠ 转换前是 `font-mono`(没有钉字号);原样搬过来。
            className: 'font-mono',
            render: (r) => (
                <Link
                    href={`/inbound/${batchId}/assays/${r.id}`}
                    className="text-blue-600 hover:underline"
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
            // ★ 结论 —— 手机上留下。读数里被切掉一半的正是这一列。
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
            // 空态从 AssaySection 的 `rows.length === 0 ?` 那一支搬进来,【同一个 key】。
            // 旧那一支已经删掉 —— TABLE-CONVERT-3 §6.1 那处死代码不再犯第二次。
            empty={t('assay.empty')}
        />
    )
}
