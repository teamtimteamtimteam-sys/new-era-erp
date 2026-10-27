'use client'

// app/workbench/WorkbenchTable.tsx
// SYSTEM-MAP-2(Tim 2.4 (9) · C):待办一张表。手机上留【勾选】【是什么】【单号】【等了多久】—— 是什么与单号说清楚这一件,
//   等了多久说它有多急;谁提的、从哪天起在手机上收进展开那一格。
// 【批量】只有今天已经能批量决定的那几种画勾选框(lib/workbench.ts bulkMode);别的行那一格是空的、整行链出去。
//   每一项走它那一种自己的单项动作(与那张面板上的 BulkDecisionBar 是同一扇门):四眼、CFO 档位与拒绝按项由库判,
//   结果名单逐项说出理由。批准只在勾的每一项都能批准时才出现(一般报销与过磅草稿只能批量驳回)。
import * as React from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { BulkDecisionBar, BulkCheck } from '@/app/components/ui/bulk-decision-bar'
import { Refusal } from '@/app/components/ui/refusal'
import { xText, xDate, xInt } from '@/lib/export/cells'
import type { BulkItem } from '@/lib/bulkRun'
import type { TodoType } from '@/lib/workbench'
import { decideJournalRequest } from '@/app/finance/journal/requestActions'
import { decideWarehouseRequest } from '@/app/components/inventory/warehouseRequestActions'
import { decideTermsRequest } from '@/app/components/pricing/termsRequestActions'
import { decideDisposalRequest } from '@/app/finance/assets/disposalRequestActions'
import { decideClaim } from '@/app/finance/claims/actions'
import { rejectDraft } from '@/app/operation/capture/actions'

export type TodoRow = {
    key: string
    id: string
    /** null = 库里来了一种这一版不认识的种类:照列,不给链接、不给批量 */
    type: TodoType | null
    rawType: string
    parentId: string | null
    code: string
    subject: string
    href: string | null
    raisedBy: string
    raisedRestricted: boolean
    waited: number | null
    since: string | null
    sinceText: string
    due: string | null
    bulk: 'both' | 'reject' | null
}

type Act = { error?: string; detail?: string } | void | undefined

export default function WorkbenchTable({ rows }: { rows: TodoRow[] }) {
    const t = useTranslations()
    const [selected, setSelected] = React.useState<Set<string>>(new Set())
    const typeLabel = (r: TodoRow) => (r.type ? t(`workbench.type.${r.type}`) : r.rawType)

    const bulkRows = rows.filter((r) => r.bulk !== null)
    const byKey = new Map(rows.map((r) => [r.key, r]))
    const items: BulkItem[] = bulkRows.map((r) => ({ id: r.key, label: r.code }))
    const chosen = [...selected].map((k) => byKey.get(k)).filter((r): r is TodoRow => !!r)
    // 批准:只在勾的每一项都能批准时(没勾的时候,看有没有一项能批准)
    const canApprove = chosen.length > 0 ? chosen.every((r) => r.bulk === 'both') : bulkRows.some((r) => r.bulk === 'both')

    const decide = async (item: BulkItem, approve: boolean, reason: string): Promise<Act> => {
        const r = byKey.get(item.id)
        if (!r) return { error: t('bulk.thrown') }
        switch (r.type) {
            case 'journal_request': return decideJournalRequest(r.id, approve, reason, r.parentId)
            case 'warehouse_request': return decideWarehouseRequest(r.id, approve, reason)
            case 'terms_request': return decideTermsRequest(r.id, approve, reason)
            case 'asset_disposal_request': return decideDisposalRequest(r.id, approve, reason)
            case 'expense_claim':
                if (approve) return { error: t('workbench.bulkRejectOnly') }
                return decideClaim({ claimId: r.id, approve: false, notes: reason })
            case 'capture_draft':
                if (approve) return { error: t('workbench.bulkRejectOnly') }
                return rejectDraft(r.id, reason)
            default:
                return { error: t('workbench.bulkRejectOnly') }
        }
    }

    const columns: ExportableColumn<TodoRow>[] = [
        {
            key: 'pick', header: t('workbench.colPick'), priority: true, sortable: false, exportAs: false,
            render: (r) => r.bulk
                ? <BulkCheck label={t('workbench.pickRow', { code: r.code })} checked={selected.has(r.key)}
                    onChange={() => setSelected((prev) => { const n = new Set(prev); if (n.has(r.key)) n.delete(r.key); else n.add(r.key); return n })} />
                : null,
        },
        { key: 'type', header: t('workbench.colType'), priority: true, render: typeLabel, exportAs: (r) => xText(typeLabel(r)) },
        {
            key: 'code', header: t('workbench.colItem'), priority: true, exportAs: (r) => xText(r.subject ? `${r.code} — ${r.subject}` : r.code),
            render: (r) => (
                <span data-todo-type={r.rawType}>
                    {r.href
                        ? <Link href={r.href} className="hover:underline app-link" data-todo-link={r.rawType}>{r.code}</Link>
                        : <span>{r.code}</span>}
                    {r.subject && <span className="block text-xs text-[color:var(--brand-muted-text)]">{r.subject}</span>}
                </span>
            ),
        },
        {
            key: 'raisedBy', header: t('workbench.colRaisedBy'), exportAs: (r) => xText(r.raisedBy),
            render: (r) => (r.raisedRestricted ? <Refusal>{r.raisedBy}</Refusal> : r.raisedBy),
        },
        {
            key: 'waited', header: t('workbench.colWaited'), priority: true, align: 'right',
            exportAs: (r) => (r.waited === null ? xText('—') : xInt(r.waited)),
            render: (r) => (
                <span title={r.sinceText}>
                    {r.waited === null ? '—' : t('workbench.days', { n: r.waited })}
                    {r.due && <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('workbench.due', { date: r.due })}</span>}
                </span>
            ),
        },
        { key: 'since', header: t('workbench.colSince'), render: (r) => r.sinceText, exportAs: (r) => xDate(r.since) },
    ]

    return (
        <div className="space-y-3">
            {items.length > 0 && (
                <BulkDecisionBar
                    items={items}
                    selected={selected}
                    onSelectedChange={setSelected}
                    approve={canApprove ? { title: t('workbench.bulkApproveTitle'), act: (i) => decide(i, true, '') } : undefined}
                    reject={{ title: t('workbench.bulkRejectTitle'), placeholder: t('workbench.bulkRejectPlaceholder'),
                              act: (i, reason) => decide(i, false, reason) }}
                />
            )}
            <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} empty={t('workbench.empty')}
                exportSpec={{ name: 'workbench', title: t('workbench.title') }}
                // 一次读回全部(waiting_for_me 没有上限,它就是"在等你的那几件")—— 在浏览器里排
                sorting={{ mode: 'client', coverage: 'complete' }} />
        </div>
    )
}
