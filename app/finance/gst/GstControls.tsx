'use client'

// app/finance/gst/GstControls.tsx
// 开期间与开更正件的控件(APR-10 起,申报那一整圈在 [periodId]/GstFilingPanel.tsx)。**禁用一律说出为什么**(CMP-2 的规矩);拒绝就地显示。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { DatePicker } from '@/app/components/ui/date-picker'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { openGstPeriod, correctGstReturn } from './actions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export function OpenPeriodControl({ canEdit }: { canEdit: boolean }) {
    const t = useTranslations(); const router = useRouter()
    const [start, setStart] = useState('')
    // 期初框里敲了一个不存在 / 格式不对的日子:按钮是 onClick,不走原生表单,得自己关上
    const [startBad, setStartBad] = useState(false)
    const [err, setErr] = useState(''); const [busy, start2] = useTransition()
    return (
        <div className="flex flex-wrap items-end gap-3">
            <div>
                <label className="block mb-1">{t('gst.periodStart')}</label>
                {/* 【不预填今天】期初是一个季度的第一天,今天几乎不会是答案 */}
                <DatePicker value={start} onChange={setStart} onInvalidChange={setStartBad} />
            </div>
            {!start && <p className="text-sm text-amber-700 self-center">{t('gst.blockedNeedStart')}</p>}
            <PermissionGate code="module.finance.edit" allowed={canEdit}>
            <Button type="button" disabled={!start || busy || startBad}
                    onClick={() => start2(async () => {
                        const r = await openGstPeriod(start); if (r.error) setErr(r.error); else { setErr(''); router.refresh() }
                    })}>
                {busy ? t('common.saving') : t('gst.openPeriod')}
            </Button>
            </PermissionGate>
            {err && <p className="text-sm text-red-700 w-full">{err}</p>}
        </div>
    )
}

export function CorrectControl({ periodId, canEdit }: { periodId: string; canEdit: boolean }) {
    const t = useTranslations(); const router = useRouter()
    const [reason, setReason] = useState(''); const [err, setErr] = useState('')
    const [busy, start] = useTransition()
    return (
        <div className="flex flex-wrap items-end gap-3">
            <div className="flex-1 min-w-[16rem]">
                <label className="block mb-1">{t('gst.correctionReason')}</label>
                <input value={reason} onChange={(e) => setReason(e.target.value)}
                       className={`${CONTROL_INPUT} w-full`} />
            </div>
            {!reason.trim() && <p className="text-sm text-amber-700 self-center">{t('gst.blockedNeedReason')}</p>}
            <PermissionGate code="module.finance.edit" allowed={canEdit}>
            <Button variant="secondary" type="button" disabled={!reason.trim() || busy}
                    onClick={() => start(async () => {
                        const r = await correctGstReturn(periodId, reason); if (r.error) setErr(r.error); else { setErr(''); router.refresh() }
                    })}>
                {busy ? t('common.saving') : t('gst.raiseCorrection')}
            </Button>
            </PermissionGate>
            {err && <p className="text-sm text-red-700 w-full">{err}</p>}
        </div>
    )
}
