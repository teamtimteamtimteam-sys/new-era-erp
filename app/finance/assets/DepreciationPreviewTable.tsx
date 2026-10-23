'use client'

// app/finance/assets/DepreciationPreviewTable.tsx
// CONV-4 · 月度折旧预览那张表(只读、无勾选、无行内控件 —— 与它挂在同一页的
// 资产台账主表不同,主表因 AssetActions 的行内表单不属于这一套模板的人口,
// 见 page.tsx 顶注)。
//
// ★ 合计行走【行数据 + rowClassName 加粗】,不是组件另开一个"表尾"槽位 ★
//   DataTable 的契约是"一行 = 一条记录",没有表尾的概念。把合计塞成最后一条
//   【记录】、用 CONV-4 新建的 rowClassName 加粗它,复用的是刚建好的那个口子,
//   不必再给组件添一个新概念去处理"这张表恰好有一行不是记录"这件事。

import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xMoney, xText } from '@/lib/export/cells'

export type DepreciationPreviewRow = {
    assetId: string
    code: string | null
    account: string | null
    deltaBase: number
    isTotal?: boolean
}

export default function DepreciationPreviewTable({
    rows, empty, baseCurrency, periodEnd,
}: { rows: DepreciationPreviewRow[]; empty: React.ReactNode; baseCurrency: string; periodEnd: string }) {
    const t = useTranslations()

    // TABLE-EXPORT-3a(Tim 2026-10-23 Q5 · Q3):照屏幕导出,合计那一行是预览自己算的(preview_depreciate_fixed_assets 的 total_delta),照导出;
    //   About 表写明「截至 <日期> 的预览,尚未过账」。
    const columns: ExportableColumn<DepreciationPreviewRow>[] = [
        {
            key: 'code', header: t('finance.colCode'), priority: true, className: 'text-sm',
            render: (r) => (r.isTotal ? t('finance.totalsLabel') : r.code),
            exportAs: (r) => xText(r.isTotal ? t('finance.totalsLabel') : r.code),
        },
        { key: 'account', header: t('assets.colAccount'), className: 'text-sm', render: (r) => r.isTotal ? '' : r.account, exportAs: (r) => xText(r.isTotal ? null : r.account) },
        {
            key: 'delta', header: t('assets.colDelta', { ccy: baseCurrency }), priority: true, align: 'right', className: 'text-sm',
            render: (r) => formatMoneyBare(r.deltaBase, '列头 应提(ccy)'),
            exportAs: (r) => xMoney(r.deltaBase),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.assetId}
            phone={{ mode: 'columns' }}
            empty={empty}
            rowClassName={(r) => (r.isTotal ? 'bg-gray-50 font-medium' : undefined)}
            exportSpec={{
                name: 'finance-depreciation-preview',
                title: t('assets.depTitle'),
                aboutExtra: [[t('table.export.aboutPreview'), t('table.export.aboutPreviewValue', { date: periodEnd })]],
            }}
        />
    )
}
