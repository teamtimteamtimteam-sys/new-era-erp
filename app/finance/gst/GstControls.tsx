'use client'

// app/finance/gst/GstControls.tsx
// 三个动作的控件。**禁用一律说出为什么**(CMP-2 的规矩);拒绝就地显示。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { openGstPeriod, fileGstReturn, correctGstReturn } from './actions'
import { Button } from '@/app/components/ui/button'

export function OpenPeriodControl() {
    const t = useTranslations(); const router = useRouter()
    const [start, setStart] = useState('')
    const [err, setErr] = useState(''); const [busy, start2] = useTransition()
    return (
        <div className="flex flex-wrap items-end gap-3">
            <div>
                <label className="block text-sm font-medium mb-1">{t('gst.periodStart')}</label>
                {/* 【不预填今天】期初是一个季度的第一天,今天几乎不会是答案 */}
                <input type="date" value={start} onChange={(e) => setStart(e.target.value)}
                       className="border border-gray-300 px-3 py-2 rounded" />
            </div>
            {!start && <p className="text-sm text-amber-700 self-center">{t('gst.blockedNeedStart')}</p>}
            <Button type="button" disabled={!start || busy}
                    onClick={() => start2(async () => {
                        const r = await openGstPeriod(start); if (r.error) setErr(r.error); else { setErr(''); router.refresh() }
                    })}>
                {busy ? t('common.saving') : t('gst.openPeriod')}
            </Button>
            {err && <p className="text-sm text-red-700 w-full">{err}</p>}
        </div>
    )
}

export function FileReturnControl({ periodId, blockedWhy }: { periodId: string; blockedWhy?: string }) {
    const t = useTranslations(); const router = useRouter()
    const [on, setOn] = useState(''); const [ref, setRef] = useState('')
    const [err, setErr] = useState(''); const [busy, start] = useTransition()
    if (blockedWhy) {
        // 【禁用要说出理由,而不是把控件藏起来】问题适用、只是被挡住了。
        return (
            <div className="inline-flex flex-col items-start">
                <Button size="sm" type="button" disabled>
                    {t('gst.recordFiling')}
                </Button>
                <span className="text-xs text-amber-700 mt-1">{blockedWhy}</span>
            </div>
        )
    }
    return (
        <div className="flex flex-wrap items-end gap-3">
            <div>
                <label className="block text-sm font-medium mb-1">{t('gst.filedOn')}</label>
                <input type="date" value={on} onChange={(e) => setOn(e.target.value)}
                       className="border border-gray-300 px-3 py-2 rounded" />
            </div>
            <div>
                <label className="block text-sm font-medium mb-1">{t('gst.filedReference')}</label>
                <input value={ref} onChange={(e) => setRef(e.target.value)}
                       placeholder={t('gst.filedReferenceHint')}
                       className="border border-gray-300 px-3 py-2 rounded" />
            </div>
            {!on && <p className="text-sm text-amber-700 self-center">{t('gst.blockedNeedFiledOn')}</p>}
            <Button type="button" disabled={!on || busy}
                    onClick={() => start(async () => {
                        const r = await fileGstReturn(periodId, on, ref); if (r.error) setErr(r.error); else { setErr(''); router.refresh() }
                    })}>
                {busy ? t('common.saving') : t('gst.recordFiling')}
            </Button>
            {err && <p className="text-sm text-red-700 w-full">{err}</p>}
        </div>
    )
}

export function CorrectControl({ periodId }: { periodId: string }) {
    const t = useTranslations(); const router = useRouter()
    const [reason, setReason] = useState(''); const [err, setErr] = useState('')
    const [busy, start] = useTransition()
    return (
        <div className="flex flex-wrap items-end gap-3">
            <div className="flex-1 min-w-[16rem]">
                <label className="block text-sm font-medium mb-1">{t('gst.correctionReason')}</label>
                <input value={reason} onChange={(e) => setReason(e.target.value)}
                       className="w-full border border-gray-300 px-3 py-2 rounded" />
            </div>
            {!reason.trim() && <p className="text-sm text-amber-700 self-center">{t('gst.blockedNeedReason')}</p>}
            <button type="button" disabled={!reason.trim() || busy}
                    onClick={() => start(async () => {
                        const r = await correctGstReturn(periodId, reason); if (r.error) setErr(r.error); else { setErr(''); router.refresh() }
                    })}
                    className="border border-amber-500 text-amber-800 px-4 py-2 rounded hover:bg-amber-50 disabled:opacity-50">
                {busy ? t('common.saving') : t('gst.raiseCorrection')}
            </button>
            {err && <p className="text-sm text-red-700 w-full">{err}</p>}
        </div>
    )
}
