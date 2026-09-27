'use client'

// TERMS-EDIT-1(Tim 2026-09-27,grilling Q5):合同表头 —— 条款改得了的时候它也改得了;对手方与买卖方向建好之后定死,
// 画出来、按不动、说「另建一份」。状态不在这里:进 active 只经 CFO,暂停在"让合同生效"那一块。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ContractDateInput } from '../ContractDateInput'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { Refusal } from '@/app/components/ui/refusal'
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { saveContractHeader, type EditResult } from './actions'
import { HEADER_KINDS } from './termSpecs'

export type HeaderValues = {
    counterpartyLabel: string
    sideLabel: string
    kind: string
    title: string
    effective_from: string
    effective_to: string
    signed_on: string
    currency: string
    incoterm: string
    payment_terms_days: string
    document_ref: string
    notes: string
}

export default function HeaderForm({
    contractId, values, currencies, canWrite, blockedReason,
}: {
    contractId: string
    values: HeaderValues
    currencies: string[]
    canWrite: boolean
    blockedReason: string | null
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [result, setResult] = useState<EditResult | null>(null)
    const [saved, setSaved] = useState(false)
    const disabled = blockedReason !== null || !canWrite
    const field = `${CONTROL_INPUT} w-full`
    const err = (k: string) =>
        result?.fieldErrors?.[k] ? <p className="text-red-600 text-xs mt-1">{result.fieldErrors[k]}</p> : null

    function submit(form: HTMLFormElement) {
        const fd = new FormData(form)
        start(async () => {
            const r = await saveContractHeader(contractId, fd)
            setResult(r.error || r.fieldErrors ? r : null)
            setSaved(!(r.error || r.fieldErrors))
            if (!(r.error || r.fieldErrors)) router.refresh()
        })
    }

    return (
        <section className="space-y-3" aria-label={t('contractDetail.headerTitle')} data-contract-section="header">
            <h2 className="mb-1">{t('contractDetail.headerTitle')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] max-w-4xl">{t('contractDetail.headerHint')}</p>
            {blockedReason && (
                <p className="text-sm"><Refusal className="whitespace-normal text-left">{blockedReason}</Refusal></p>
            )}
            {result?.error && (
                <div className="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800" role="alert">{result.error}</div>
            )}
            {saved && <p className="text-sm text-[color:var(--brand-text)]" role="status">{t('contractDetail.headerSaved')}</p>}
            <form className="space-y-4 max-w-3xl" onSubmit={(e) => { e.preventDefault(); submit(e.currentTarget) }}>
                {/* 对手方与方向:定死(Q5) */}
                <div>
                    <label className="block mb-1" htmlFor="hdr-counterparty">{t('contracts.form.counterparty')}</label>
                    <input id="hdr-counterparty" className={field} value={`${values.counterpartyLabel} · ${values.sideLabel}`} disabled readOnly />
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('contractDetail.counterpartyFixed')}</p>
                </div>
                <div className="grid gap-4 sm:grid-cols-2">
                    <div>
                        <label className="block mb-1" htmlFor="hdr-kind">{t('contracts.form.kind')} <span className="text-red-600">*</span></label>
                        <select id="hdr-kind" name="kind" defaultValue={values.kind} disabled={disabled} className={`${CONTROL_SELECT} w-full`}>
                            {HEADER_KINDS.map((k) => <option key={k} value={k}>{t(`contracts.kind.${k}`)}</option>)}
                        </select>
                        {err('kind')}
                    </div>
                    <div>
                        <label className="block mb-1" htmlFor="hdr-title">{t('contracts.form.title')} <span className="text-red-600">*</span></label>
                        <input id="hdr-title" name="title" defaultValue={values.title} disabled={disabled} className={field} />
                        {err('title')}
                    </div>
                    <div>
                        <label className="block mb-1" htmlFor="hdr-from">{t('contracts.form.effectiveFrom')} <span className="text-red-600">*</span></label>
                        <ContractDateInput id="hdr-from" name="effective_from" defaultValue={values.effective_from} disabled={disabled} className={field} />
                        {err('effective_from')}
                    </div>
                    <div>
                        <label className="block mb-1" htmlFor="hdr-to">{t('contracts.form.effectiveTo')}</label>
                        <ContractDateInput id="hdr-to" name="effective_to" defaultValue={values.effective_to} disabled={disabled} className={field} />
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('contracts.form.effectiveToHint')}</p>
                        {err('effective_to')}
                    </div>
                    <div>
                        <label className="block mb-1" htmlFor="hdr-signed">{t('contracts.form.signedOn')}</label>
                        <ContractDateInput id="hdr-signed" name="signed_on" defaultValue={values.signed_on} disabled={disabled} className={field} />
                    </div>
                    <div>
                        <label className="block mb-1" htmlFor="hdr-ccy">{t('contracts.form.currency')}</label>
                        <select id="hdr-ccy" name="currency" defaultValue={values.currency} disabled={disabled} className={`${CONTROL_SELECT} w-full`}>
                            <option value="">{t('contracts.form.currencyNone')}</option>
                            {currencies.map((c) => <option key={c} value={c}>{c}</option>)}
                        </select>
                    </div>
                    <div>
                        <label className="block mb-1" htmlFor="hdr-incoterm">{t('contracts.form.incoterm')}</label>
                        <input id="hdr-incoterm" name="incoterm" defaultValue={values.incoterm} disabled={disabled} className={field}
                               placeholder={t('contracts.form.incotermPlaceholder')} />
                    </div>
                    <div>
                        <label className="block mb-1" htmlFor="hdr-ptd">{t('contracts.form.paymentTermsDays')}</label>
                        <input id="hdr-ptd" type="number" min={0} max={365} name="payment_terms_days" defaultValue={values.payment_terms_days}
                               disabled={disabled} className={field} />
                        {err('payment_terms_days')}
                    </div>
                </div>
                <div>
                    <label className="block mb-1" htmlFor="hdr-docref">{t('contracts.form.documentRef')}</label>
                    <input id="hdr-docref" name="document_ref" defaultValue={values.document_ref} disabled={disabled} className={field} />
                </div>
                <div>
                    <label className="block mb-1" htmlFor="hdr-notes">{t('contracts.form.notes')}</label>
                    <textarea id="hdr-notes" name="notes" defaultValue={values.notes} disabled={disabled} className={`${CONTROL_TEXTAREA} w-full`} />
                </div>
                <PermissionGate code="action.contract_terms" allowed={canWrite}>
                    <Button type="submit" disabled={pending || blockedReason !== null}>
                        {pending ? t('common.saving') : t('contractDetail.saveHeader')}
                    </Button>
                </PermissionGate>
            </form>
        </section>
    )
}
