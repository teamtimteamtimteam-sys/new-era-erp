'use client'

// app/inbound/InboundTable.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-1 · 进料台账那张表 —— 【全系统最宽的一张,13 列】,本刀的压力测试
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【手机上留哪三列 —— 批次号 · 物料 · 余量。理由写在这里,不在提交信息里】★★
//   BASE-1 的抬头里就点过这张表:「/inbound 的前两列是批次号和日期,
//   而人在手机上要找的是【物料和净重】」。本刀采纳它,并加上身份那一列:
//     · 批次号 —— 身份,而且是人嘴里说的那个东西(「IN-2026-0180 那一批」);
//     · 物料   —— 不知道是什么料,一行数字没有意义;
//     · 余量   —— 这张台账存在的理由。人来这一页最常问的是「还剩多少」,
//                 不是「当初收了多少」,所以留【余量】而不是【数量】。
//   其余 10 列(供应商 · 来源 · 数量 · 到货日 · 阶段 · 状态 · 定价 · 创建时间 ·
//   删除 · 标签)全部进展开区 —— 它们都是【认出这一行之后才问的】。
//
// ★【为什么【不】用 phone: 'scroll',尽管 13 列看起来正是它的场合】★
//   委托书提示这张表可能是横向滚动第一次诚实的用法。逐条想过,答案是不:
//   横向滚动在 13 列上要拖过大约十列,而 R3 的反对正好在这里最锋利 ——
//   **拖到第 8 列时批次号已经不在屏幕上了**,「这一行是谁」就没了。
//   而这一页的用法恰恰是【先认出一行,再看它的细节】—— 认不出行,后面十列都是废的。
//   scroll 适合的是「要横着比较很多列」的表;进料台账不是那种表。
//   **所以 13 列这个数字本身不构成理由,列之间的关系才构成理由。**
//
// ★【排序:server 模式 —— 行为一个字没变(Tim 的 Q7=A)】★
//   这一页的排序本来就在数据库里对【全体】做(URL 参数 → ORDER BY),那是对的。
//   DataTable 的 server 模式把表头渲染成【链接】,与它此前的 sortableTh 逐字同形。
//   换掉的只是外观。**客户端一行都不重排** —— 那会把已经正确的排序毁掉。
//   分页也留在页面上(服务端 .range),没有打开 DataTable 自己的客户端分页。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import DeleteButton from './DeleteButton'
import type { InboundSortCol } from './inboundQuery'

/**
 * 【服务端已经压平好的一行】—— 一个函数都没有,也没有 Map/Set。
 *
 * 【为什么在服务端压平,而不是把查找表传下来】来源那一列要三样东西:
 * 采购单号(躲在 module.purchasing.view 后面)、理由字典的本地化名字、
 * 以及"两样都没有 = 未说明"。那三样都是【服务端才知道的】。
 * 把 Map 传过边界能跑,但会让列描述符去懂这一页的取数形状。
 * **服务端算好「这一格该显示什么」,客户端只负责怎么画它。**
 * 这一条是模板的通则,不是这一页的特例。
 */
export type InboundTableRow = {
    id: string
    code: string
    materialName: string
    supplierName: string
    /** 三态:对着采购单 / 有理由 / 未说明。R4:未说明【永远不是空白格】。 */
    sourceKind: 'po' | 'reason' | 'unexplained'
    sourceLabel: string | null
    quantity: number
    remaining: number
    unit: string
    arrivalDate: string | null
    stageLabel: string
    status: string
    pricingStatus: string
    hasUnappliedAssay: boolean
    createdLabel: string
}

export default function InboundTable({
    rows, sort, dir, filterQuery, shown, total,
}: {
    rows: InboundTableRow[]
    sort: InboundSortCol
    dir: 'asc' | 'desc'
    /** 当前的筛选参数(不含 sort/dir/page)—— 排序链接要原样带上它们。 */
    filterQuery: string
    shown: number
    total: number
}) {
    const t = useTranslations()

    // 排序链接:保留所有筛选,只改 sort/dir;【不带 page】—— 改排序回到第 1 页。
    // (与本页此前那个 sortHref 逐字同义。)
    const href = (key: string, nextDir: 'asc' | 'desc') => {
        const params = new URLSearchParams(filterQuery)
        params.set('sort', key)
        params.set('dir', nextDir)
        return `/inbound?${params.toString()}`
    }

    const pill = 'px-2 py-1 rounded text-xs'
    const columns: Column<InboundTableRow>[] = [
        {
            key: 'code', header: t('inbound.colCode'), priority: true, sortable: true,
            className: 'font-mono text-sm',
            render: (b) => (
                <Link href={`/inbound/${b.id}/edit`} className="text-blue-600 hover:underline">{b.code}</Link>
            ),
        },
        { key: 'material', header: t('inbound.colMaterial'), priority: true, render: (b) => b.materialName },
        {
            key: 'remaining_qty', header: t('inbound.colRemaining'), priority: true, sortable: true, align: 'right',
            render: (b) => `${b.remaining} ${b.unit}`,
        },
        { key: 'supplier', header: t('inbound.colSupplier'), render: (b) => b.supplierName },
        {
            key: 'source', header: t('inbound.colSource'), className: 'whitespace-nowrap',
            render: (b) =>
                b.sourceKind === 'po' ? (
                    <span className={pill + ' bg-blue-100 text-blue-800'}>{b.sourceLabel}</span>
                ) : b.sourceKind === 'reason' ? (
                    <span className={pill + ' bg-gray-200'}>{b.sourceLabel}</span>
                ) : (
                    /* R4:未说明 —— 永远不是空白格,不是默认理由 */
                    <span className={pill + ' bg-amber-100 text-amber-900 border border-amber-300'}>
                        {t('inbound.source.unexplained')}
                    </span>
                ),
        },
        {
            key: 'quantity', header: t('inbound.colQuantity'), sortable: true, align: 'right',
            render: (b) => `${b.quantity} ${b.unit}`,
        },
        {
            key: 'arrival_date', header: t('inbound.colArrivalDate'), sortable: true,
            render: (b) => b.arrivalDate ?? '—',
        },
        { key: 'stage', header: t('inbound.colStage'), render: (b) => <span className={pill + ' bg-gray-200'}>{b.stageLabel}</span> },
        { key: 'status', header: t('inbound.colStatus'), render: (b) => <span className={pill + ' bg-gray-200'}>{b.status}</span> },
        {
            key: 'pricing', header: t('assay.colPricingStatus'), className: 'whitespace-nowrap',
            render: (b) => (
                <>
                    <span className={pill + ' ' + (
                        b.pricingStatus === 'final' ? 'bg-green-100 text-green-800'
                            : b.pricingStatus === 'provisional' ? 'bg-amber-100 text-amber-800'
                                : 'bg-gray-200 text-gray-600')}>
                        {t('assay.pricingStatus.' + b.pricingStatus)}
                    </span>
                    {/* 已记录未应用的化验:价格还停在旧含量上 */}
                    {b.hasUnappliedAssay && (
                        <span title={t('assay.hasUnappliedMarker')} className="ml-1 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800">⚠</span>
                    )}
                </>
            ),
        },
        {
            key: 'created_at', header: t('inbound.colCreated'), sortable: true,
            className: 'text-sm text-gray-600',
            render: (b) => b.createdLabel,
        },
        { key: 'actions', header: t('inbound.colActions'), render: (b) => <DeleteButton id={b.id} code={b.code} /> },
        {
            key: 'label', header: t('batchLabel.col'),
            render: (b) => (
                <a href={`/inbound/${b.id}/label`} target="_blank" rel="noopener noreferrer"
                   className="text-blue-600 hover:underline text-sm">{t('batchLabel.col')}</a>
            ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(b) => b.id}
            phone={{ mode: 'columns' }}
            sorting={{
                mode: 'server',
                coverage: { shown, total },
                active: { key: sort, dir },
                href,
            }}
        />
    )
}
