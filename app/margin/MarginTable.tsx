'use client'

// app/margin/MarginTable.tsx
// CONV-5 · 批次毛利那张表。
//
// ★【"算不出来"与"零"必须分得开】★ margin_status !== 'ok' 的行,成本/毛利/
//   毛利率三格印「—」,而不是 0 —— 一个 0 会把"这一批的成本还没凑齐"说成
//   "这一批没有成本"。整行同时发灰(rowClassName),因为那不是一行普通数据。
// 【徽标在服务端算好成一个数组】四种旗标各自的条件是取数侧的知识,
// 列描述符只负责画它们。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type MarginFlag = { label: string; hint: string; tone: 'amber' | 'red' }

export type MarginRow = {
    outputBatchId: string
    /**
     * ★【产出批次入口的 href 由【注册表】给,不在这里手写】★
     * /output 是一条【跨模块】功能条目(operation + inventory 两个属主),
     * 而 check-permission-predicate 的第 ② 条不变量说:跨模块功能的入口必须
     * 由注册表派生(getFunctionAccess / FN),否则入口与权限之间没有任何东西
     * 保证同步。转换前这一页手写着 <Link href={`/output`}> —— 那道闸的正则
     * 只认引号形式(href="/output"),【认不出反引号模板串】,所以它一直没响。
     * 本刀把它改成由服务端从 FN.output.href 传进来:既满足不变量,
     * 也不改变这条链接今天指向的地方。那个正则的洞记在 §⑩-12。
     */
    outputHref: string
    batchCode: string
    materialName: string
    runCode: string
    qtySold: string
    revenue: string
    /** null = 算不出来(margin_status !== 'ok')—— 不是 0,也不是空白。 */
    cost: string | null
    margin: string | null
    marginPct: string | null
    ok: boolean
    flags: MarginFlag[]
}

function Flag({ label, hint, tone }: MarginFlag) {
    return (
        <span
            title={hint}
            className={
                'inline-block rounded px-1.5 py-0.5 text-xs whitespace-nowrap ' +
                (tone === 'red'
                    ? 'bg-red-100 text-red-800 border border-red-300'
                    : 'bg-amber-100 text-amber-900 border border-amber-300')
            }
        >
            {label}
        </span>
    )
}

export default function MarginTable({ rows, empty }: { rows: MarginRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【批次】与【毛利】—— 批次是身份,而毛利是这一页存在的全部理由
    //   (Doc 2 说"生意最需要、而 Xero 结构上做不出来"的那个数)。
    //   收入与成本是它的两个来源,进展开区。
    const columns: Column<MarginRow>[] = [
        {
            key: 'batch', header: t('margin.colBatch'), priority: true,
            render: (r) => (
                <>
                    <Link href={r.outputHref} className="font-mono text-sm text-blue-600 hover:underline">
                        {r.batchCode}
                    </Link>
                    <span className="block text-xs text-gray-500">{r.materialName}</span>
                </>
            ),
        },
        { key: 'run', header: t('margin.colRun'), className: 'font-mono text-sm', render: (r) => r.runCode },
        { key: 'qty', header: t('margin.colQty'), align: 'right', className: 'font-mono text-sm', render: (r) => r.qtySold },
        { key: 'revenue', header: t('margin.colRevenue'), align: 'right', className: 'font-mono text-sm', render: (r) => r.revenue },
        // 【算不出来就说算不出来】—— 不是 0,也不是空白
        { key: 'cost', header: t('margin.colCost'), align: 'right', className: 'font-mono text-sm', render: (r) => r.cost ?? '—' },
        {
            key: 'margin', header: t('margin.colMargin'), priority: true, align: 'right',
            className: 'font-mono text-sm', render: (r) => r.margin ?? '—',
        },
        { key: 'marginPct', header: t('margin.colMarginPct'), align: 'right', className: 'font-mono text-sm', render: (r) => r.marginPct ?? '—' },
        {
            key: 'flags', header: t('margin.colFlags'),
            render: (r) => (
                <div className="flex flex-wrap gap-1">
                    {r.flags.map((f, i) => (
                        <Flag key={i} {...f} />
                    ))}
                </div>
            ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.outputBatchId}
            phone={{ mode: 'columns' }}
            empty={empty}
            rowClassName={(r) => (r.ok ? undefined : 'bg-gray-50')}
        />
    )
}
