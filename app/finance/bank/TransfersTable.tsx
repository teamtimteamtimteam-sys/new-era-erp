'use client'

// app/finance/bank/TransfersTable.tsx
// ★ PAY-REQ-1 · Batch B(Tim 2026-09-23 的 Q4):已记账的行内转账,每行一个「申请冲销」。
//   此前 reverse_bank_transfer 没有任何屏幕调它,而分录页又不许冲转账的分录 ——
//   一笔记错的转账在屏幕上没有任何更正的路。冲销走一张冲销申请(理由必填),CFO 批准后
//   由财务在申请页上执行并给出冲销日。已有未了结的冲销申请时,钮换成指向那张申请的链接。
import Link from 'next/link'
import { useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { requestTransferReversal } from './transferActions'

export type TransferRow = {
    id: string
    dateText: string
    fromAccount: string
    toAccount: string
    fromCurrency: string
    toCurrency: string
    amountOut: number
    amountIn: number
    reference: string | null
    reversed: boolean
    openRequestId: string | null
    openRequestCode: string | null
}

function ReverseTransferButton({ row, canEdit }: { row: TransferRow; canEdit: boolean }) {
    const t = useTranslations()
    const [pending, start] = useTransition()
    const subject = `${row.dateText} · ${row.fromAccount} → ${row.toAccount}`
    return (
        <PermissionGate code="module.finance.edit" allowed={canEdit}>
            <ConfirmButton
                subject={subject}
                title={t('finance.transfer.requestReversalConfirm')}
                body={t('finance.transfer.requestReversalBody')}
                confirmLabel={t('finance.requestReversal')}
                tier="reversal"
                reason={{ placeholder: t('finance.requestReversalPlaceholder') }}
                triggerVariant="reversal"
                disabled={pending}
                onConfirm={(reason) => start(async () => {
                    const r = await requestTransferReversal(row.id, reason)
                    if (r?.error) {
                        showActionMessage({
                            subject,
                            headline: t('common.actionMessage.headline.notReversalRequested'),
                            body: r.error,
                            detail: r.detail,
                        })
                    }
                })}
            >
                {pending ? t('common.saving') : t('finance.requestReversal')}
            </ConfirmButton>
        </PermissionGate>
    )
}

export default function TransfersTable({ rows, canEdit }: { rows: TransferRow[]; canEdit: boolean }) {
    const t = useTranslations()
    const columns: Column<TransferRow>[] = [
        { key: 'date', header: t('finance.transfer.colDate'), priority: true, render: (r) => r.dateText },
        {
            key: 'accounts', header: t('finance.transfer.colAccounts'),
            render: (r) => <>{t('finance.bank.' + r.fromAccount)} → {t('finance.bank.' + r.toAccount)}</>,
        },
        {
            key: 'out', header: t('finance.transfer.amountOut'), align: 'right', priority: true,
            render: (r) => <>{r.fromCurrency} {formatMoneyBare(r.amountOut, '同格内紧邻的 r.fromCurrency 前缀')}</>,
        },
        {
            key: 'in', header: t('finance.transfer.amountIn'), align: 'right',
            render: (r) => <>{r.toCurrency} {formatMoneyBare(r.amountIn, '同格内紧邻的 r.toCurrency 前缀')}</>,
        },
        { key: 'ref', header: t('finance.transfer.reference'), render: (r) => r.reference ?? '—' },
        {
            key: 'action', header: t('finance.colStatus'),
            render: (r) => r.reversed ? (
                <span className="px-2 py-1 rounded text-xs bg-gray-200 text-gray-700">{t('finance.transfer.reversed')}</span>
            ) : r.openRequestId ? (
                <Link href={`/finance/payment-requests/${r.openRequestId}`} className="hover:underline app-link app-link-inline">
                    {t('finance.transfer.reversalRequested', { code: r.openRequestCode ?? '' })}
                </Link>
            ) : (
                <ReverseTransferButton row={r} canEdit={canEdit} />
            ),
        },
    ]
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('finance.transfer.empty')}
        />
    )
}
