'use client'

// LOG-4b:运费单冲销控件。
// ★ BTN-4:AUDEL-2 的形状折进了 <ConfirmButton reason> —— 后果仍然写在按下
//   【之前】(body)、理由为空时确认钮不可按、服务端仍是权威。变的只是画它的
//   那一份实现从 ReasonPrompt 换成了对话框,而对话框【探针点得到】。
//   ☞ 主语是运费单号(code),由父组件传进来:原来这个控件只拿到 id。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { reverseFreight } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DatePicker } from '@/app/components/ui/date-picker'
import { formatDate } from '@/lib/dates'
import { useLocale } from '@/lib/i18n/client'

// ★ FIN-CHAIN-1(Tim 2026-10-20,Step 0 Q7 · APR4-FREIGHT-REVERSAL-DATED-TODAY):冲销日由人选 —— 必填、不默认、
//   不早于单据日(min);落在已关账的期间由库按名拒 PERIOD_LOCKED。框空着时冲销钮按不动,并且说出为什么。
export default function ReverseFreightControl({ id, code, docDate,
canEdit
}: { id: string; code: string; docDate: string
canEdit: boolean
}) {
    const t = useTranslations()
    const locale = useLocale()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [date, setDate] = useState('')
    const [dateBad, setDateBad] = useState(false)
    const dateMissing = date === '' || dateBad

    return (
        <div className="inline-flex flex-col items-end">
            <PermissionGate code="module.finance.edit" allowed={canEdit}>
            <label className="mb-1 flex flex-col items-end text-sm">
                <span>{t('finance.freight.reverseDate')}</span>
                <DatePicker value={date} required aria-invalid={date === ''} min={docDate}
                            onChange={setDate} onInvalidChange={setDateBad} className="flex" />
                <span className="mt-1 block max-w-xs text-right text-xs text-[color:var(--brand-muted-text)]">
                    {t('finance.freight.reverseDateHint', { date: formatDate(docDate, locale) })}
                </span>
            </label>
            <ConfirmButton
                subject={code}
                title={t('finance.freight.reverseTitle')}
                // 【三件后果都在按下之前说清】分录镜像回零、离开应付账龄、不可撤销;
                // 外加"已被付过款的冲不了"—— 那一条与其让人按下去撞
                // FREIGHT_HAS_SETTLEMENT,不如先说。
                body={`${t('finance.freight.reverseConsequence')} ${dateMissing ? '' : t('finance.freight.reverseOnDate', { date: formatDate(date, locale) })}`.trim()}
                confirmLabel={t('finance.freight.reverseButton')}
                tier="destructive"
                reason={{ placeholder: t('finance.freight.reverseReason') }}
                triggerVariant="destructive"
                disabled={isPending || dateMissing}
                onConfirm={(reason) => {
                    setError('')
                    startTransition(async () => {
                        const res = await reverseFreight(id, reason, date)
                        if (res && 'error' in res && res.error) setError(res.error)
                        else router.refresh()
                    })
                }}
            >
                {isPending ? t('common.saving') : t('finance.freight.reverseButton')}
            </ConfirmButton>
            </PermissionGate>
            {error && <p className="mt-1 max-w-md text-xs text-destructive-text">{error}</p>}
        </div>
    )
}
