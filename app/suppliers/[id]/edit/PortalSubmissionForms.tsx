'use client'

// MES-9c(2026-10-20,MES-9 Step 0 Q19):供应商页「门户交上来的证书」那一块,每一份等审核的申请底下的三个动作 ——
//   看文件(60 秒的签名链接)、接受(核对号 · 发证机构 · 有效期;接受 = 建证书行、文件抄进这家供应商的附件)、驳回(理由必填,供应商看得见)。
//   看文件对每一个读得到这一块的人(module.suppliers.view)都开着;接受与驳回缺 module.suppliers.edit 时在 PermissionGate 里
//   (看得见、按不动、说出码)。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { acceptPortalSubmission, getSubmissionFileUrl, rejectPortalSubmission } from './portalSubmissionActions'

const CODE = 'module.suppliers.edit'

export default function PortalSubmissionForms(props: {
    supplierId: string
    submissionId: string
    canReview: boolean
    waiting: boolean
    certNo: string | null
    validFrom: string | null
    validUntil: string | null
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [done, setDone] = useState('')
    const [mode, setMode] = useState<'idle' | 'accept' | 'reject'>('idle')
    const [certNo, setCertNo] = useState(props.certNo ?? '')
    const [issuingBody, setIssuingBody] = useState('')
    const [validFrom, setValidFrom] = useState(props.validFrom ?? '')
    const [validUntil, setValidUntil] = useState(props.validUntil ?? '')
    const [reason, setReason] = useState('')

    function openFile() {
        setError('')
        startTransition(async () => {
            const res = await getSubmissionFileUrl({ submissionId: props.submissionId })
            if (res.error || !res.url) { setError(res.error ?? ''); return }
            window.location.href = res.url
        })
    }

    function run(fn: () => Promise<{ error?: string; success?: boolean }>, okText: string) {
        setError(''); setDone('')
        startTransition(async () => {
            const res = await fn()
            if (res.error) { setError(res.error); router.refresh(); return }
            setDone(okText); setMode('idle'); setReason('')
            router.refresh()
        })
    }

    return (
        <div className="mt-2 space-y-2" data-form="portal-submission" data-submission-id={props.submissionId}>
            {error && <p className="text-sm text-red-600" data-error="portal-submission">{error}</p>}
            {done && <p className="text-sm text-green-700" data-saved="portal-submission">{done}</p>}
            <div className="flex flex-wrap gap-2">
                <Button type="button" variant="secondary" disabled={isPending} onClick={openFile} data-action="submission-file">
                    {t('portal.review.openFile')}
                </Button>
            </div>
            {props.waiting && (
                <PermissionGate code={CODE} allowed={props.canReview}>
                    {mode === 'idle' && (
                        <div className="flex flex-wrap gap-2">
                            <Button type="button" onClick={() => setMode('accept')} data-action="submission-accept">{t('portal.review.accept')}</Button>
                            <Button type="button" variant="secondary" onClick={() => setMode('reject')} data-action="submission-reject">{t('portal.review.reject')}</Button>
                        </div>
                    )}
                    {mode === 'accept' && (
                        <div className="space-y-2 max-w-3xl" data-form="submission-accept">
                            <p className="text-xs text-[color:var(--brand-muted-text)]">{t('portal.review.acceptWhat')}</p>
                            <div className="flex flex-wrap gap-3">
                                <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                                    <span className="block mb-1">{t('portal.review.certNo')}</span>
                                    <input value={certNo} onChange={(e) => setCertNo(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="cert_no" />
                                </label>
                                <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                                    <span className="block mb-1">{t('portal.review.issuingBody')}</span>
                                    <input value={issuingBody} onChange={(e) => setIssuingBody(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="issuing_body" />
                                </label>
                            </div>
                            <div className="flex flex-wrap gap-3">
                                <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                                    <span className="block mb-1">{t('portal.review.validFrom')}</span>
                                    <DatePicker value={validFrom} onChange={setValidFrom} />
                                </label>
                                <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                                    <span className="block mb-1">{t('portal.review.validUntil')}</span>
                                    <DatePicker value={validUntil} onChange={setValidUntil} />
                                </label>
                            </div>
                            <div className="flex flex-wrap gap-2">
                                <Button type="button" disabled={isPending} data-action="submission-accept-confirm"
                                    onClick={() => run(() => acceptPortalSubmission({ supplierId: props.supplierId, submissionId: props.submissionId,
                                                                                       certNo, issuingBody, validFrom, validUntil }),
                                                       t('portal.review.accepted'))}>
                                    {isPending ? t('common.saving') : t('portal.review.acceptConfirm')}
                                </Button>
                                <Button type="button" variant="secondary" disabled={isPending} onClick={() => setMode('idle')}>{t('common.cancel')}</Button>
                            </div>
                        </div>
                    )}
                    {mode === 'reject' && (
                        <div className="flex flex-wrap gap-2 items-end" data-form="submission-reject">
                            <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                                <span className="block mb-1">{t('portal.review.rejectReason')} <span className="text-red-600">*</span></span>
                                <input value={reason} onChange={(e) => setReason(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="reject_reason" />
                            </label>
                            <Button type="button" variant="destructive" disabled={!reason.trim() || isPending} data-action="submission-reject-confirm"
                                onClick={() => run(() => rejectPortalSubmission({ supplierId: props.supplierId, submissionId: props.submissionId, reason }),
                                                   t('portal.review.rejected'))}>
                                {isPending ? t('common.saving') : t('portal.review.rejectConfirm')}
                            </Button>
                            <Button type="button" variant="secondary" disabled={isPending} onClick={() => setMode('idle')}>{t('common.cancel')}</Button>
                        </div>
                    )}
                </PermissionGate>
            )}
        </div>
    )
}
