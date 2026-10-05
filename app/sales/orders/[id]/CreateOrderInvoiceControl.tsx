'use client'

// SO-3a:订单流开票控件。
//
// 【开票日必填,永不默认】它决定分录期间与账期起点(AGENTS.md 的日期规矩):
// 提交钮在日期空着时禁用【且】服务端按名独立拒(INVOICE_DATE_REQUIRED)——
// UI 的 required 只是第三层,不是保护。
//
// 【后果写在按钮旁边】开票会过账(借 1100 应收 / 贷 2500 合同负债,按订单抄来的
// 汇率),而且订单流【先开票后发货】—— 那句话必须在按下之前就在屏幕上。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { createOrderInvoice } from '../actions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DatePicker } from '@/app/components/ui/date-picker'
import { businessToday } from '@/lib/format'

export default function CreateOrderInvoiceControl({
    orderId,
    unbilledCount,
canEdit
}: {
    orderId: string
    unbilledCount: number

canEdit: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [issueDate, setIssueDate] = useState('')
    // 日期框里敲着一个不合法的日子:issueDate 还是上一个合法值,开票钮靠这一位关上
    const [dateBad, setDateBad] = useState(false)

    function go() {
        setError('')
        startTransition(async () => {
            const res = await createOrderInvoice(orderId, issueDate)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="border border-gray-300 rounded px-4 py-3">
            {error && <p className="text-sm text-red-600 mb-2">{error}</p>}
            <div className="flex flex-wrap items-end gap-3">
                <div>
                    <label className="block mb-1">{t('sales.invoice.issueDate')}</label>
                    <DatePicker
                        max={businessToday()}
                        value={issueDate}
                        onChange={setIssueDate}
                        onInvalidChange={setDateBad}
                    />
                </div>
                <PermissionGate code="module.finance.edit" allowed={canEdit}>
                <Button variant="secondary"
                    type="button"
                    onClick={go}
                    disabled={isPending || issueDate.trim() === '' || dateBad}
                >
                    {isPending ? t('common.saving') : t('sales.invoice.create', { n: String(unbilledCount) })}
                </Button>
                </PermissionGate>
            </div>
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
                {issueDate.trim() === '' ? t('sales.invoice.dateRequired') : t('sales.invoice.consequence')}
            </p>
        </div>
    )
}
