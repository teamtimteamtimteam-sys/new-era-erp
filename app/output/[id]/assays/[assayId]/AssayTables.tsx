'use client'

// app/output/[id]/assays/[assayId]/AssayTables.tsx
// TABLE-CONVERT-4:这一页的两张手搓 <table> 换成 DataTable ——
//   ① 金属表(2 列,单据本身说了什么)
//   ② 应用前的对照表(4 列,当前 vs 应用后)
//
// 【为什么两张合一个文件】页面是 server component,两张表都要过 server→client
//   那道边界(Column.render 是函数)。两张表【同一页、同一次判断】,合成一个
//   client 文件是 TABLE-CONVERT-2 对同文件两张表已经用过的做法。
//
// 【★ ① 与 /inbound/[id]/assays/[assayId] 那张是【同一次判断】★】
//   两处标记逐字相同:同样两列、同样的 assay.colMetal / assay.colContent、
//   同样一处 hidden sm:table-cell 都没有。两处照同一个形状改。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

// ── ① 金属表(2 列)──────────────────────────────────────────────────────
export type AssayMetalRow = {
    metal: string
    /** 服务端译好的金属名 —— t() 不跨边界。 */
    metalLabel: string
    contentPct: string
}

export function AssayMetalsTable({ rows }: { rows: readonly AssayMetalRow[] }) {
    const t = useTranslations()
    const columns: Column<AssayMetalRow>[] = [
        {
            key: 'metal',
            header: t('assay.colMetal'),
            // ★ 两列都 priority —— 转换前一处 hidden sm:table-cell 都没有,
            //   390px 上两列本来就都看得见。搬的是那个事实。
            priority: true,
            render: (r) => (
                <>
                    {r.metalLabel}
                    <span className="text-gray-400 text-xs ml-2">{r.metal}</span>
                </>
            ),
        },
        {
            key: 'content',
            header: t('assay.colContent'),
            align: 'right',
            priority: true,
            // ⚠ 转换前是 `font-mono text-sm`;text-sm 没有搬过来(列定义不许钉字号),
            //   而组件表根就是 text-sm,不写字号继承到的是同一个 14px。
            render: (r) => r.contentPct,
        },
    ]
    // 没有给 empty:转换前空的时候画的是一张只有表头的表,页面没写过空态文案。
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.metal}
                   phone={{ mode: 'columns' }} className="max-w-md mb-6" />
    )
}

// ── ② 应用前对照表(4 列)────────────────────────────────────────────────
export type ApplyPreviewRow = {
    metal: string
    metalLabel: string
    /** 转换前:current 有就是 `${content_pct}%`,没有就是 '—'。原样送过来。 */
    currentText: string
    /** null = 这一行今天没有 current,那一格转换前画的是 '—'。 */
    sourceLabel: string | null
    sourceKind: 'assay' | 'manual' | 'other' | null
    /** null = 化验没报这一行 —— 应用是整体替换,这行会消失(画那枚红片)。 */
    afterText: string | null
}

export function ApplyPreviewTable({ rows }: { rows: readonly ApplyPreviewRow[] }) {
    const t = useTranslations()
    const columns: Column<ApplyPreviewRow>[] = [
        {
            key: 'metal',
            header: t('assay.colMetal'),
            priority: true,
            render: (r) => (
                <>
                    {r.metalLabel}
                    <span className="text-gray-400 text-xs ml-2">{r.metal}</span>
                </>
            ),
        },
        {
            key: 'current',
            header: t('assay.output.colCurrent'),
            align: 'right',
            priority: true,
            render: (r) => r.currentText,
        },
        {
            key: 'source',
            header: t('metalContent.colSource'),
            priority: true,
            render: (r) =>
                r.sourceKind === null ? (
                    '—'
                ) : (
                    <span
                        className={
                            'px-2 py-0.5 rounded text-xs ' +
                            (r.sourceKind === 'assay'
                                ? 'bg-blue-100 text-blue-800'
                                : r.sourceKind === 'manual'
                                    ? 'bg-gray-200 text-gray-600'
                                    : 'bg-amber-100 text-amber-800')
                        }
                    >
                        {r.sourceLabel}
                    </span>
                ),
        },
        {
            key: 'after',
            header: t('assay.output.colAfter'),
            align: 'right',
            priority: true,
            render: (r) =>
                r.afterText !== null ? (
                    r.afterText
                ) : (
                    // 化验没报这一行 —— 应用是整体替换,这行会消失。
                    // 被顶掉/移除的行必须看得见,不能被静默覆盖。
                    <span className="px-2 py-0.5 rounded text-xs bg-red-100 text-red-700">
                        {t('assay.output.willRemove')}
                    </span>
                ),
        },
    ]
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.metal}
            // ★★ 手机档【原样保留横向滚动】,而这是一次搬运不是新判断:
            //   转换前这张表一处 hidden sm:table-cell 都没有,四列在 390px 上全部
            //   看得见,外面本来就包着一层 overflow-x-auto。
            //   而这张表存在的理由就是【把当前与应用后并排看】—— 折走其中任何一列
            //   都得先点开一行才比得了,那正好是它唯一不可替代的能力。
            phone={{
                mode: 'scroll',
                why: '四列是一次并排比较(当前 · 来源 · 应用后),折走任何一列都要先点开一行才比得了;转换前这四列在 390px 上也全部看得见,外面本来就是 overflow-x-auto。',
            }}
            className="max-w-2xl mb-4"
        />
    )
}
