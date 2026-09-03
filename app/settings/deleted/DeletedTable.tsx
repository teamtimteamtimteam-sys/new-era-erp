'use client'

// app/settings/deleted/DeletedTable.tsx
// CONV-5 · 删除登记簿那张表。
//
// ★★【「谁」那一格是【服务端渲染好的元素】,不是一个字符串】★★
// `ActorName` 是一个 async 服务端组件,它把"谁做的"分成四种状态、其中两种要画
// CONV-0 的 <Refusal> 药丸,而第 ② 种【刻意不画】——那套判断是它存在的全部理由。
// 把它在客户端重写一遍,就是这个仓库已经付过三次账的"殖民地"错误。
// 所以这里让服务端渲染出那个元素、当成 ReactNode 传过来,客户端只负责摆位置。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type DeletedRow = {
    key: string
    kindLabel: string
    code: string
    detail: string | null
    href: string | null
    whenLabel: string
    /** 服务端渲染好的 <ActorName /> —— 见抬头。 */
    whoCell: React.ReactNode
    /** null = 没有记过理由,由表说那句话。 */
    reason: string | null
    ledgerHref: string | null
    /** processing_run 的冲销【就是那次加工本身】,不是一条流水。 */
    reversalIsTheRun: boolean
}

export default function DeletedTable({ rows, empty }: { rows: DeletedRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【编号】与【为什么】—— 编号是身份;而这一页存在的全部理由
    //   就是 AUDEL-1b/2 把"为什么删"问了出来(在此之前那些记录一处都不显示)。
    //   把理由挤进展开区,等于把这一页的目的藏起来。
    const columns: Column<DeletedRow>[] = [
        { key: 'kind', header: t('deleted.colKind'), render: (r) => r.kindLabel },
        {
            key: 'code', header: t('deleted.colCode'), priority: true, className: 'font-mono text-xs',
            render: (r) => (
                <>
                    {r.href ? (
                        <Link href={r.href} className="text-blue-600 hover:underline">{r.code}</Link>
                    ) : (
                        r.code
                    )}
                    {r.detail && <span className="ml-2 text-gray-500">{r.detail}</span>}
                </>
            ),
        },
        { key: 'when', header: t('deleted.colWhen'), className: 'whitespace-nowrap', render: (r) => r.whenLabel },
        // 【谁】—— 三种状态三句话,全在 ActorName 一处
        { key: 'who', header: t('deleted.colWho'), render: (r) => r.whoCell },
        {
            // 【为什么】—— 空也要说出来,不留白
            key: 'reason', header: t('deleted.colReason'), priority: true,
            render: (r) =>
                r.reason ?? <span className="text-gray-500">{t('deleted.reasonUnrecorded')}</span>,
        },
        {
            key: 'ledger', header: t('deleted.colLedger'), className: 'text-xs',
            render: (r) =>
                r.ledgerHref ? (
                    <Link href={r.ledgerHref} className="text-blue-600 hover:underline">
                        {t('deleted.ledgerLink')}
                    </Link>
                ) : r.reversalIsTheRun ? (
                    <span className="text-gray-500">{t('deleted.reversalIsTheRun')}</span>
                ) : (
                    <span className="text-gray-400">—</span>
                ),
        },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={empty} />
}
