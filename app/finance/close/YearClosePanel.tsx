'use client'

// FIN-23:年结面板(客户端侧只有两个按钮;数字与前置状态全部来自服务端预览 ——
// preview_close_financial_year,与 close_financial_year 同一份算术)。
// 硬前置任一不满足则按钮禁用(服务端仍会点名拒 —— 界面不提供必然被拒的动作);
// 软警告(草稿薪资/未清应计)只亮黄,不拦。重开必须给理由,window.confirm 二次确认。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { closeFinancialYear, reopenFinancialYear } from './actions'
import { Button } from '@/app/components/ui/button'

export default function YearClosePanel({
    yearEnd,
    canClose,
    alreadyClosed,
}: {
    yearEnd: string
    canClose: boolean
    alreadyClosed: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [reason, setReason] = useState('')

    return (
        <div className="space-y-3">
            {error && (
                <div className="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            {!alreadyClosed ? (
                <Button
                    type="button"
                    disabled={pending || !canClose}
                    onClick={() => {
                        if (!window.confirm(t('finance.yearClose.confirm', { 0: yearEnd }))) return
                        setError(null)
                        start(async () => {
                            const r = await closeFinancialYear(yearEnd)
                            if (r?.error) setError(r.error)
                            else router.refresh()
                        })
                    }}
                >
                    {t('finance.yearClose.run', { 0: yearEnd })}
                </Button>
            ) : (
                <div className="flex items-center gap-2">
                    <input
                        type="text"
                        value={reason}
                        onChange={(e) => setReason(e.target.value)}
                        placeholder={t('finance.yearClose.reopenReason')}
                        className="border border-gray-300 rounded px-2 py-1 text-sm w-64"
                    />
                    <button
                        type="button"
                        disabled={pending || !reason.trim()}
                        onClick={() => {
                            if (!window.confirm(t('finance.yearClose.reopenConfirm', { 0: yearEnd }))) return
                            setError(null)
                            start(async () => {
                                const r = await reopenFinancialYear(yearEnd, reason)
                                if (r?.error) setError(r.error)
                                else { setReason(''); router.refresh() }
                            })
                        }}
                        className="border border-red-300 text-red-700 px-3 py-1 rounded text-sm disabled:opacity-50"
                    >
                        {t('finance.yearClose.reopen')}
                    </button>
                </div>
            )}
        </div>
    )
}
