'use client'

// app/operation/processing/[id]/ProcessingTables.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-10(2026-09-04)· 一次加工的五张子表
// ════════════════════════════════════════════════════════════════════════════
//
// ★【全仓子表最多的一页 —— 7 张(这里 5 张,另 2 张在 CostPanel / LossPanel)】★
// CONV-8 §① 量出的「一页 7 张表」就是这一页,而它是 37 张详情页里的最大值
// (中位数是 1)。**它被两刀留在后面,不是因为难,是因为 CONV-9 拿到的排序键是
// 「模块里详情页最多」而 operation 只有 2 张页** —— 见 §⑬-0b。
//
// ★【这一页转换【前】就是 0 溢出 / 0 裁切】★
// 所以这次转换**不是为了修一个已知的病**,是为了让它和另外 34 张说同一种话:
// 空态由表自己说、手机列由每张表自己声明、展开区由组件管。
// **一次不修任何东西的转换要说清楚它不修任何东西** —— 否则下一刀会以为它修过。
//
// 【为什么是一个文件五个导出,而不是五个文件】它们共享的是【这一页】的语境
// (同一次加工的投入/产出/血缘/差异/回收率),而不是一个可复用的形状。
// CONV-9 的 SettlementHistoryTable 收进 app/components/ 是因为**三页共用**;
// 这五张一页专用,收在页面旁边才对。见 CONV-5 §⑩-5「闸数的是调用点」。
import * as React from 'react'
import Link from 'next/link'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { MaskedValue } from '@/app/components/MaskedValue'
import { useTranslations } from '@/lib/i18n/client'

// ── ① 工单差异(5 列)──────────────────────────────────────────────────────
// 【转换前它没有表头】—— 一张 5 列的无头表,靠读者自己数第几列是什么。
// DataTable 的契约要求每列都有 header,所以这一张**转换即修**:
// 与 CONV-9 给 MaintenancePanel 补那一个空 <th> 是同一类(§⑫-10 第 1 条),
// 只是那一次补的是空字符串,这一次补的是五个真的列名。
export type WoVarianceRow = {
    id: string
    sideLabel: string
    material: string
    /** 有计划就是数;没有就是一句说明(斜体灰字),两者不是同一种东西。 */
    plannedText: string
    plannedMuted: boolean
    actualText: string
    /** null = 无从相减(不是 0)。 */
    varianceText: string | null
    varianceNegative: boolean
}

export function WoVarianceTable({ rows }: { rows: readonly WoVarianceRow[] }) {
    const t = useTranslations()
    const columns: Column<WoVarianceRow>[] = [
        { key: 'side', header: t('processing.wo.colSide'), render: (r) => r.sideLabel },
        {
            key: 'material',
            header: t('processing.wo.colMaterial'),
            // 身份列:差异是【某一种料】的差异。
            priority: true,
            render: (r) => r.material,
        },
        {
            key: 'planned', header: t('processing.wo.colPlanned'), align: 'right', className: 'font-mono',
            render: (r) => (r.plannedMuted ? <span className="text-gray-500 italic font-sans">{r.plannedText}</span> : r.plannedText),
        },
        { key: 'actual', header: t('processing.wo.colConsumed'), align: 'right', className: 'font-mono', render: (r) => r.actualText },
        {
            key: 'variance',
            header: t('processing.wo.colVariance'),
            align: 'right',
            // ★ 这张表存在的理由就是这一列 —— 计划与实际【差了多少】。
            //   把它赶进展开区,等于把这张表的主语拿掉。
            priority: true,
            className: 'font-mono',
            render: (r) =>
                r.varianceText == null
                    ? <span className="text-gray-400">—</span>
                    : <span className={r.varianceNegative ? 'text-amber-700' : ''}>{r.varianceText}</span>,
        },
    ]
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id}
                   phone={{ mode: 'columns' }} empty={t('processing.wo.noLines')} />
    )
}

// ── ② 血缘(4 列)──────────────────────────────────────────────────────────
export type LineageRow = {
    id: string
    depth: number
    viaRunCode: string
    parentCode: string
    parentHref: string
    parentKindLabel: string
    qty: string
}

export function LineageTable({ rows }: { rows: readonly LineageRow[] }) {
    const t = useTranslations()
    const columns: Column<LineageRow>[] = [
        { key: 'depth', header: t('processing.lineage.colDepth'), className: 'font-mono text-sm', render: (r) => r.depth },
        { key: 'via', header: t('processing.lineage.colViaRun'), className: 'font-mono text-sm', render: (r) => r.viaRunCode },
        {
            key: 'parent',
            header: t('processing.lineage.colParent'),
            // 身份列:这一行说的是【哪一批上游料】。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => (
                <>
                    <Link href={r.parentHref} className="text-blue-600 hover:underline">{r.parentCode}</Link>
                    <span className="ml-2 text-xs text-gray-500 font-sans">{r.parentKindLabel}</span>
                </>
            ),
        },
        {
            key: 'qty',
            header: t('processing.lineage.colQty'),
            align: 'right',
            // 血缘表被打开的理由:那一批【进来了多少】。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => r.qty,
        },
    ]
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id}
                   phone={{ mode: 'columns' }} empty={t('processing.lineage.empty')} />
    )
}

// ── ③ 投入(3 列)──────────────────────────────────────────────────────────
export type InputLegRow = {
    id: string
    parentCode: string | null
    parentHref: string | null
    parentDeleted: boolean
    deletedMarker: string
    reprocessed: boolean
    material: string
    qtyText: string
}

export function InputsTable({ rows }: { rows: readonly InputLegRow[] }) {
    const t = useTranslations()
    const columns: Column<InputLegRow>[] = [
        {
            key: 'batch',
            header: t('processing.detail.colInboundBatch'),
            // 身份列。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) => (
                <>
                    {r.parentCode == null ? '—'
                        : r.parentDeleted ? <span className="text-gray-500">{r.parentCode}{r.deletedMarker}</span>
                        : r.parentHref ? <Link href={r.parentHref} className="text-blue-600 hover:underline">{r.parentCode}</Link>
                        : r.parentCode}
                    {/* ★ CONV-9 §⑫-5a:一枚徽章可以【既是】徽章【又在】表里。
                        这一枚不是 priority 列的一部分 —— 它跟着「投入批」这一格
                        留在手机上,因为「这一批是再加工来的」改变的是这一行的读法。 */}
                    {r.reprocessed && (
                        <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-blue-50 text-blue-700 font-sans">
                            {t('processing.detail.reprocessedTag')}
                        </span>
                    )}
                </>
            ),
        },
        { key: 'material', header: t('processing.detail.colMaterial'), render: (r) => r.material },
        {
            key: 'qty',
            header: t('processing.detail.colConsumedQty'),
            // 投入表被打开的理由:【吃掉了多少】。
            priority: true,
            render: (r) => r.qtyText,
        },
    ]
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id}
                   phone={{ mode: 'columns' }} empty={t('processing.detail.noInputRecords')} />
    )
}

// ── ④ 产出(6 列)──────────────────────────────────────────────────────────
export type OutputLegRow = {
    id: string
    batchCode: string | null
    batchHref: string | null
    batchDeleted: boolean
    deletedMarker: string
    material: string
    qtyText: string
    purity: string
    /** 已遮蔽时是 null —— 与「尚未分摊」不是一回事,交给 MaskedValue 分。 */
    allocatedCostText: string | null
    unitCostText: string | null
    costIncomplete: boolean
}

export function OutputsTable({ rows, canViewPrices }: { rows: readonly OutputLegRow[]; canViewPrices: boolean }) {
    const t = useTranslations()
    const columns: Column<OutputLegRow>[] = [
        {
            key: 'batch',
            header: t('processing.detail.colOutputBatch'),
            // 身份列。
            priority: true,
            className: 'font-mono text-sm',
            render: (r) =>
                r.batchCode == null ? '—'
                    : r.batchDeleted ? <span className="text-gray-500">{r.batchCode}{r.deletedMarker}</span>
                    : r.batchHref ? <Link href={r.batchHref} className="text-blue-600 hover:underline">{r.batchCode}</Link>
                    : r.batchCode,
        },
        { key: 'material', header: t('processing.detail.colMaterial'), render: (r) => r.material },
        {
            key: 'qty',
            header: t('processing.detail.colProducedQty'),
            // ★ 产出表被打开的理由:【出来了多少】。
            //   钱那三列全部进展开区 —— 与 CONV-9 给 /inventory/output/[materialId]
            //   的裁定同一条(manual-walk-list §30.3):挑一列钱等于替读者
            //   决定他关心成本还是单价,而这一张的主语是【量】。
            priority: true,
            render: (r) => r.qtyText,
        },
        { key: 'purity', header: t('processing.detail.colPurity'), render: (r) => r.purity },
        {
            key: 'allocatedCost', header: t('processing.detail.colAllocatedCost'), align: 'right', className: 'font-mono text-sm',
            render: (r) => <MaskedValue value={r.allocatedCostText} canView={canViewPrices} fallback="—" />,
        },
        {
            key: 'unitCost', header: t('processing.detail.colUnitCost'), align: 'right', className: 'font-mono text-sm',
            render: (r) => (
                <>
                    <MaskedValue value={r.unitCostText} canView={canViewPrices} fallback="—" />
                    {r.costIncomplete && (
                        <span className="ml-1 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800 font-sans">
                            {t('processing.detail.costIncomplete')}
                        </span>
                    )}
                </>
            ),
        },
    ]
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id}
                   phone={{ mode: 'columns' }} empty={t('processing.detail.noOutputRecords')} />
    )
}

// ── ⑤ 金属回收率(4 列)────────────────────────────────────────────────────
export type RecoveryRow = {
    id: string
    metalLabel: string
    /** 【未测】与【测出来是 0】是两样东西 —— REC-1。measured=false 时 text 无意义。 */
    inputMeasured: boolean
    inputText: string
    inputSource: string
    outputMeasured: boolean
    outputText: string
    outputSource: string
    /** null = 算不出;此时 blockedReason 说【为什么】。 */
    recoveryPctText: string | null
    blockedReason: string
}

export function RecoveryTable({ rows }: { rows: readonly RecoveryRow[] }) {
    const t = useTranslations()
    const notMeasured = (
        <span className="text-gray-400" title={t('processing.recovery.notMeasuredTitle')}>
            {t('processing.recovery.notMeasured')}
        </span>
    )
    const columns: Column<RecoveryRow>[] = [
        {
            key: 'metal',
            header: t('processing.recovery.colMetal'),
            // 身份列:一行回收率的主语是那一种金属。
            priority: true,
            render: (r) => r.metalLabel,
        },
        {
            key: 'input', header: t('processing.recovery.colInput'), align: 'right', className: 'text-sm',
            render: (r) => r.inputMeasured ? (
                <>
                    <span className="font-mono">{r.inputText}</span>
                    <span className="block text-xs text-gray-500">{r.inputSource}</span>
                </>
            ) : notMeasured,
        },
        {
            key: 'output', header: t('processing.recovery.colOutput'), align: 'right', className: 'text-sm',
            render: (r) => r.outputMeasured ? (
                <>
                    <span className="font-mono">{r.outputText}</span>
                    <span className="block text-xs text-gray-500">{r.outputSource}</span>
                </>
            ) : notMeasured,
        },
        {
            key: 'recovery',
            header: t('processing.recovery.colRecovery'),
            // ★ 这张表【就叫】回收率 —— 留的是它自己。
            //   算不出的时候这一格说的是【为什么算不出】,那同样是答案,不是空白。
            priority: true,
            className: 'text-sm',
            render: (r) => r.recoveryPctText != null
                ? <span className="font-mono">{r.recoveryPctText}</span>
                : <span className="text-gray-500 text-xs">{r.blockedReason}</span>,
        },
    ]
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id}
                   phone={{ mode: 'columns' }} empty={t('processing.recovery.empty')} />
    )
}
