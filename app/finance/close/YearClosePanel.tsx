'use client'

// FIN-23:年结面板(客户端侧只有两个按钮;数字与前置状态全部来自服务端预览 ——
// preview_close_financial_year,与 close_financial_year 同一份算术)。
// 硬前置任一不满足则按钮禁用(服务端仍会点名拒 —— 界面不提供必然被拒的动作);
// 软警告(草稿薪资/未清应计)只亮黄,不拦。重开必须给理由,再由对话框二次确认。
//
// CONFIRM-1:两处确认都换成 ConfirmButton,主语都是 yearEnd —— 这一页上唯一
//   需要点名的东西就是【哪一个年度】,而它本来就印在按钮的字面上。
//   重开那一侧的理由输入框搬进了对话框(见 finance/close/ReopenForm.tsx 的说明:
//   同一个理由、同一个参数位,只是问的时机从"先填"变成"确认时填")。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { closeFinancialYear, reopenFinancialYear } from './actions'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

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

    return (
        <div className="space-y-3">
            {error && (
                <div className="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            {!alreadyClosed ? (
                <ConfirmButton
                    subject={yearEnd}
                    title={t('finance.yearClose.confirm', { 0: yearEnd })}
                    confirmLabel={t('finance.yearClose.run', { 0: yearEnd })}
                    tier="destructive"
                    triggerVariant="default"
                    disabled={pending || !canClose}
                    onConfirm={() => {
                        setError(null)
                        start(async () => {
                            const r = await closeFinancialYear(yearEnd)
                            if (r?.error) setError(r.error)
                            else router.refresh()
                        })
                    }}
                >
                    {t('finance.yearClose.run', { 0: yearEnd })}
                </ConfirmButton>
            ) : (
                <div className="flex items-center gap-2">
                    <ConfirmButton
                        subject={yearEnd}
                        title={t('finance.yearClose.reopenConfirm', { 0: yearEnd })}
                        confirmLabel={t('finance.yearClose.reopen')}
                        tier="reversal"
                        reason={{ placeholder: t('finance.yearClose.reopenReason') }}
                        disabled={pending}
                        onConfirm={(reason) => {
                            setError(null)
                            start(async () => {
                                const r = await reopenFinancialYear(yearEnd, reason)
                                if (r?.error) setError(r.error)
                                else router.refresh()
                            })
                        }}
                        className="border border-red-300 text-red-700 px-3 py-1 rounded text-sm disabled:opacity-50"
                    >
                        {t('finance.yearClose.reopen')}
                    </ConfirmButton>
                </div>
            )}
        </div>
    )
}
