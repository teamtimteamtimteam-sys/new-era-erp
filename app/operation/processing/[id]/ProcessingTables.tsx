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
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { MaskedValue } from '@/app/components/MaskedValue'
import { useTranslations } from '@/lib/i18n/client'
import { xInt, xMasked, xMoney, xNum, xRestricted, xText } from '@/lib/export/cells'

// ★ TABLE-EXPORT-3c(Tim 2026-10-25):五张表各一对导出(TABLE-EXPORT-3 Q1),About 表都写这一炉的单号(runCode)。
//   页面压平的行里数多半已是排好的字(qtyText、allocatedCostText……)—— 导出不从那里抠,
//   行上另带【原始数】(页面 page.tsx 一并给),每一列的 exportAs 读那些。

// ── ① 工单差异(5 列)──────────────────────────────────────────────────────
// 【转换前它没有表头】—— 一张 5 列的无头表,靠读者自己数第几列是什么。
// DataTable 的契约要求每列都有 header,所以这一张**转换即修**:
// 与 CONV-9 给 MaintenancePanel 补那一个空 <th> 是同一类(§⑫-10 第 1 条),
// 只是那一次补的是空字符串,这一次补的是五个真的列名。
export type WoVarianceRow = {
    id: string
    sideLabel: string
    /** TABLE-EXPORT-3c:null = 没有物料码(屏幕画「—」,导出空格) */
    material: string | null
    /** 有计划就是数;没有就是一句说明(斜体灰字),两者不是同一种东西。 */
    plannedText: string
    plannedMuted: boolean
    actualText: string
    /** null = 无从相减(不是 0)。 */
    varianceText: string | null
    varianceNegative: boolean
    /** TABLE-EXPORT-3c:原始数。没有计划时 plannedQty 是 null(那一格是一句说明,不是数);varianceQty null = 无从相减。 */
    plannedQty: number | null
    actualQty: number
    varianceQty: number | null
}

export function WoVarianceTable({ rows, runCode, woCode }: { rows: readonly WoVarianceRow[]; runCode: string; woCode: string }) {
    const t = useTranslations()
    // TABLE-EXPORT-3c:计划一格没有计划时屏幕写一句说明(「计划外的料」/「没有预期」)—— 那是一个答案,导出照写;
    //   有计划就写那个数。差异无从相减时屏幕是灰横杠 → 空格,不是 0。
    const columns: ExportableColumn<WoVarianceRow>[] = [
        { key: 'side', header: t('processing.wo.colSide'), render: (r) => r.sideLabel, exportAs: (r) => xText(r.sideLabel) },
        {
            key: 'material',
            header: t('processing.wo.colMaterial'),
            // 身份列:差异是【某一种料】的差异。
            priority: true,
            render: (r) => r.material ?? '—',
            exportAs: (r) => xText(r.material),
        },
        {
            key: 'planned', header: t('processing.wo.colPlanned'), align: 'right',
            render: (r) => (r.plannedMuted ? <span className="text-gray-500 italic font-sans">{r.plannedText}</span> : r.plannedText),
            exportAs: (r) => (r.plannedMuted ? xText(r.plannedText) : xNum(r.plannedQty)),
        },
        { key: 'actual', header: t('processing.wo.colConsumed'), align: 'right', render: (r) => r.actualText, exportAs: (r) => xNum(r.actualQty) },
        {
            key: 'variance',
            header: t('processing.wo.colVariance'),
            align: 'right',
            // ★ 这张表存在的理由就是这一列 —— 计划与实际【差了多少】。
            //   把它赶进展开区,等于把这张表的主语拿掉。
            priority: true,
            render: (r) =>
                r.varianceText == null
                    ? <span className="text-gray-400">—</span>
                    : <span className={r.varianceNegative ? 'text-amber-700' : ''}>{r.varianceText}</span>,
            exportAs: (r) => xNum(r.varianceQty),
        },
    ]
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id}
                   phone={{ mode: 'columns' }} empty={t('processing.wo.noLines')}
                   exportSpec={{
                       name: 'processing-run-work-order-variance',
                       title: t('processing.detail.varianceTitle', { code: woCode }),
                       aboutExtra: [[t('processing.colCode'), runCode]],
                   }} />
    )
}

// ── ② 血缘(4 列)──────────────────────────────────────────────────────────
export type LineageRow = {
    id: string
    depth: number
    viaRunCode: string
    /** TABLE-EXPORT-3c:null = 视图没给批号(屏幕画「—」,导出空格) */
    parentCode: string | null
    parentHref: string
    parentKindLabel: string
    qty: string
    /** TABLE-EXPORT-3c:原始数(qty 是排好的字) */
    quantity: number
}

export function LineageTable({ rows, runCode }: { rows: readonly LineageRow[]; runCode: string }) {
    const t = useTranslations()
    // TABLE-EXPORT-3c:上游批一格叠着批号与一个小字的种类(进料批 / 产出批)—— 导出写主值:批号(批号前缀本身已分得出两种)。
    const columns: ExportableColumn<LineageRow>[] = [
        { key: 'depth', header: t('processing.lineage.colDepth'), className: 'text-sm', render: (r) => r.depth, exportAs: (r) => xInt(r.depth) },
        { key: 'via', header: t('processing.lineage.colViaRun'), className: 'text-sm', render: (r) => r.viaRunCode, exportAs: (r) => xText(r.viaRunCode) },
        {
            key: 'parent',
            header: t('processing.lineage.colParent'),
            // 身份列:这一行说的是【哪一批上游料】。
            priority: true,
            className: 'text-sm',
            render: (r) => (
                <>
                    <Link href={r.parentHref} className="hover:underline app-link">{r.parentCode ?? '—'}</Link>
                    <span className="ml-2 text-xs text-gray-500 font-sans">{r.parentKindLabel}</span>
                </>
            ),
            exportAs: (r) => xText(r.parentCode),
        },
        {
            key: 'qty',
            header: t('processing.lineage.colQty'),
            align: 'right',
            // 血缘表被打开的理由:那一批【进来了多少】。
            priority: true,
            className: 'text-sm',
            render: (r) => r.qty,
            exportAs: (r) => xNum(r.quantity),
        },
    ]
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id}
                   phone={{ mode: 'columns' }} empty={t('processing.lineage.empty')}
                   exportSpec={{
                       name: 'processing-run-lineage',
                       title: t('processing.lineage.title'),
                       aboutExtra: [[t('processing.colCode'), runCode]],
                   }} />
    )
}

// ── ③ 投入(3 列)──────────────────────────────────────────────────────────
export type InputLegRow = {
    id: string
    parentCode: string | null
    /** TABLE-EXPORT-3c:读者看不见那一批(RLS)—— 批号 / 物料 / 电芯结构三格画「受限」、导出写 Restricted */
    parentRestricted: boolean
    parentHref: string | null
    parentDeleted: boolean
    deletedMarker: string
    reprocessed: boolean
    /** TABLE-EXPORT-3c:null = 物料名取不到(屏幕画「—」,导出空格) */
    material: string | null
    qtyText: string
    /** TABLE-EXPORT-3c:原始数与单位(qtyText 是两者拼好的字) */
    qty: number
    unit: string | null
    /** MES-4b(Q4):这一批的电芯结构(名字或"没记");null = 这一种形态不装电芯,不说 */
    construction: string | null
}

/** 批号一格的导出:屏幕上那个「(已删除)」紧跟在批号后面,导出照样(它改变这一行的意思)。 */
const batchCell = (code: string | null, deleted: boolean, marker: string): string | null =>
    code == null ? null : deleted ? `${code}${marker}` : code

export function InputsTable({ rows, runCode }: { rows: readonly InputLegRow[]; runCode: string }) {
    const t = useTranslations()
    // TABLE-EXPORT-3c:投入批一格 —— 批号,删了的带「(已删除)」;「再加工」那枚徽章改变这一行的读法(注释见下),照屏幕附在后面。
    //   数量是数,带屏幕上跟着它的单位(一列里可以有 kg 也有 pcs)。
    const columns: ExportableColumn<InputLegRow>[] = [
        {
            key: 'batch',
            header: t('processing.detail.colInboundBatch'),
            // 身份列。
            priority: true,
            className: 'text-sm',
            render: (r) => (
                <>
                    {r.parentRestricted ? <MaskedValue value={null} canView={false} />
                        : r.parentCode == null ? '—'
                        : r.parentDeleted ? <span className="text-gray-500">{r.parentCode}{r.deletedMarker}</span>
                        : r.parentHref ? <Link href={r.parentHref} className="hover:underline app-link">{r.parentCode}</Link>
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
            exportAs: (r) => {
                if (r.parentRestricted) return xRestricted
                const code = batchCell(r.parentCode, r.parentDeleted, r.deletedMarker)
                return xText(code != null && r.reprocessed ? `${code} (${t('processing.detail.reprocessedTag')})` : code)
            },
        },
        { key: 'material', header: t('processing.detail.colMaterial'),
          render: (r) => (r.parentRestricted ? <MaskedValue value={null} canView={false} /> : r.material ?? '—'),
          exportAs: (r) => (r.parentRestricted ? xRestricted : xText(r.material)) },
        { key: 'construction', header: t('cellConstruction.label'),
          render: (r) => (r.parentRestricted ? <MaskedValue value={null} canView={false} /> : r.construction ?? '—'),
          exportAs: (r) => (r.parentRestricted ? xRestricted : xText(r.construction)) },
        {
            key: 'qty',
            header: t('processing.detail.colConsumedQty'),
            // 投入表被打开的理由:【吃掉了多少】。
            priority: true,
            render: (r) => r.qtyText,
            exportAs: (r) => xNum(r.qty, 'qty', r.unit),
        },
    ]
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id}
                   phone={{ mode: 'columns' }} empty={t('processing.detail.noInputRecords')}
                   exportSpec={{
                       name: 'processing-run-inputs',
                       title: t('processing.detail.inputsSectionHeader'),
                       aboutExtra: [[t('processing.colCode'), runCode]],
                   }} />
    )
}

// ── ④ 产出(6 列)──────────────────────────────────────────────────────────
export type OutputLegRow = {
    id: string
    batchCode: string | null
    batchHref: string | null
    batchDeleted: boolean
    deletedMarker: string
    /** TABLE-EXPORT-3c:null = 物料名取不到(屏幕画「—」,导出空格) */
    material: string | null
    qtyText: string
    /** TABLE-EXPORT-3c:原始数与单位(qtyText 是两者拼好的字) */
    qty: number
    unit: string | null
    /** TABLE-EXPORT-3c:null = 没记纯度(屏幕画「—」) */
    purity: string | null
    /** 已遮蔽时是 null —— 与「尚未分摊」不是一回事,交给 MaskedValue 分。 */
    allocatedCostText: string | null
    unitCostText: string | null
    /** TABLE-EXPORT-3c:同上两格的原始数(processing_outputs_masked 的 *_base;遮蔽 / 尚未分摊时是 null) */
    allocatedCost: number | null
    unitCost: number | null
    costIncomplete: boolean
}

export function OutputsTable({ rows, canViewPrices, runCode }: { rows: readonly OutputLegRow[]; canViewPrices: boolean; runCode: string }) {
    const t = useTranslations()
    // TABLE-EXPORT-3c:两格成本与 <MaskedValue> 同一条判据(xMasked):没权限且是 null → 「受限」;
    //   有权限而 null(尚未分摊,屏幕「—」)→ 空格。币种写在列头「分摊成本 (SGD)」「单位成本 (SGD/kg)」里,格子是光秃秃的数。
    //   单位成本旁边那枚「成本不全」徽章改变这一行的意思(成本被低估),而一个数的格子挂不下字 ——
    //   照 BatchDetail 的先例挂到身份那一格:批号后面附「(成本不全)」。
    const columns: ExportableColumn<OutputLegRow>[] = [
        {
            key: 'batch',
            header: t('processing.detail.colOutputBatch'),
            // 身份列。
            priority: true,
            className: 'text-sm',
            render: (r) =>
                r.batchCode == null ? '—'
                    : r.batchDeleted ? <span className="text-gray-500">{r.batchCode}{r.deletedMarker}</span>
                    : r.batchHref ? <Link href={r.batchHref} className="hover:underline app-link">{r.batchCode}</Link>
                    : r.batchCode,
            exportAs: (r) => {
                const code = batchCell(r.batchCode, r.batchDeleted, r.deletedMarker)
                return xText(code != null && r.costIncomplete ? `${code} (${t('processing.detail.costIncomplete')})` : code)
            },
        },
        { key: 'material', header: t('processing.detail.colMaterial'), render: (r) => r.material ?? '—', exportAs: (r) => xText(r.material) },
        {
            key: 'qty',
            header: t('processing.detail.colProducedQty'),
            // ★ 产出表被打开的理由:【出来了多少】。
            //   钱那三列全部进展开区 —— 与 CONV-9 给 /inventory/output/[materialId]
            //   的裁定同一条(manual-walk-list §30.3):挑一列钱等于替读者
            //   决定他关心成本还是单价,而这一张的主语是【量】。
            priority: true,
            render: (r) => r.qtyText,
            exportAs: (r) => xNum(r.qty, 'qty', r.unit),
        },
        { key: 'purity', header: t('processing.detail.colPurity'), render: (r) => r.purity ?? '—', exportAs: (r) => xText(r.purity) },
        {
            key: 'allocatedCost', header: t('processing.detail.colAllocatedCost'), align: 'right', className: 'text-sm',
            render: (r) => <MaskedValue value={r.allocatedCostText} canView={canViewPrices} fallback="—" />,
            exportAs: (r) => xMasked(r.allocatedCost, canViewPrices, (v) => xMoney(v)),
        },
        {
            key: 'unitCost', header: t('processing.detail.colUnitCost'), align: 'right', className: 'text-sm',
            exportAs: (r) => xMasked(r.unitCost, canViewPrices, (v) => xNum(v, 'rate')),
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
                   phone={{ mode: 'columns' }} empty={t('processing.detail.noOutputRecords')}
                   exportSpec={{
                       name: 'processing-run-outputs',
                       title: t('processing.detail.outputsSectionHeader'),
                       aboutExtra: [[t('processing.colCode'), runCode]],
                   }} />
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
    /** TABLE-EXPORT-3c:原始数(上面三串是排好的字)。没测的那一侧 / 算不出的回收率是 null。 */
    inputKg: number | null
    outputKg: number | null
    recoveryPct: number | null
}

export function RecoveryTable({ rows, runCode }: { rows: readonly RecoveryRow[]; runCode: string }) {
    const t = useTranslations()
    const notMeasured = (
        <span className="text-gray-400" title={t('processing.recovery.notMeasuredTitle')}>
            {t('processing.recovery.notMeasured')}
        </span>
    )
    // TABLE-EXPORT-3c:投入 / 产出两格叠着金属量与一行小字的出处(化验 / 手填)—— 导出写主值:金属量(列头已写 kg)。
    //   【未测】屏幕说「未测」,导出是空格,绝不是 0(REC-1:未测与测出来是 0 是两样东西)。
    //   回收率算不出时屏幕那一格说【为什么】—— 那同样是答案,导出照写那句话;算得出就是那个百分数。
    const columns: ExportableColumn<RecoveryRow>[] = [
        {
            key: 'metal',
            header: t('processing.recovery.colMetal'),
            // 身份列:一行回收率的主语是那一种金属。
            priority: true,
            render: (r) => r.metalLabel,
            exportAs: (r) => xText(r.metalLabel),
        },
        {
            key: 'input', header: t('processing.recovery.colInput'), align: 'right', className: 'text-sm',
            render: (r) => r.inputMeasured ? (
                <>
                    <span>{r.inputText}</span>
                    <span className="block text-xs text-gray-500">{r.inputSource}</span>
                </>
            ) : notMeasured,
            exportAs: (r) => xNum(r.inputMeasured ? r.inputKg : null),
        },
        {
            key: 'output', header: t('processing.recovery.colOutput'), align: 'right', className: 'text-sm',
            render: (r) => r.outputMeasured ? (
                <>
                    <span>{r.outputText}</span>
                    <span className="block text-xs text-gray-500">{r.outputSource}</span>
                </>
            ) : notMeasured,
            exportAs: (r) => xNum(r.outputMeasured ? r.outputKg : null),
        },
        {
            key: 'recovery',
            header: t('processing.recovery.colRecovery'),
            // ★ 这张表【就叫】回收率 —— 留的是它自己。
            //   算不出的时候这一格说的是【为什么算不出】,那同样是答案,不是空白。
            priority: true,
            className: 'text-sm',
            render: (r) => r.recoveryPctText != null
                ? <span>{r.recoveryPctText}</span>
                : <span className="text-gray-500 text-xs">{r.blockedReason}</span>,
            exportAs: (r) => (r.recoveryPctText != null ? xNum(r.recoveryPct, 'pct') : xText(r.blockedReason)),
        },
    ]
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id}
                   phone={{ mode: 'columns' }} empty={t('processing.recovery.empty')}
                   exportSpec={{
                       name: 'processing-run-metal-recovery',
                       title: t('processing.recovery.title'),
                       aboutExtra: [[t('processing.colCode'), runCode]],
                   }} />
    )
}
