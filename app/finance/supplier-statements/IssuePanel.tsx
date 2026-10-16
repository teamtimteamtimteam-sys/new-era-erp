'use client'

// MES-8a(2026-10-16,MES-0 Q79 · MES-8 Step 0 Q7 · Q8,Tim):签发一份供应商对账单 —— 选供应商与期间(必填,不给默认),先预览、后签发。
//   预览与签发读的是同一支 supplier_statement_data。【对不上就不给签发钮】,并说出差额(服务端也会按名拒 SUPPLIER_STATEMENT_DOES_NOT_TIE)。
//   同一段期间已经出过的,要写取代的理由(服务端按名拒)。缺 module.finance.edit 时签发那一块在 PermissionGate 里(看得见、按不动、说出码)。
import { formatMoneyBare } from '@/lib/format'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DatePicker } from '@/app/components/ui/date-picker'
import { previewSupplierStatement, issueSupplierStatement } from './actions'

type Preview = {
    supplier_code: string; base_currency: string
    opening_base: number; charges_base: number; credits_base: number; payments_base: number; prepayments_base: number; closing_base: number
    list_base: number; on_account_base: number; residue_base: number; tie_difference: number; ties: boolean; no_movement: boolean
    lines: unknown[]; unpriced: unknown[]
}
// 两位小数 + 千分位,不带币种 —— 币种写在每一列的列头 / 摘要的抬头上
const money = (n: number) => formatMoneyBare(Number(n), 'the column header / summary heading names the currency')

export default function IssuePanel({ suppliers, canIssue }: { suppliers: { id: string; label: string }[]; canIssue: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [supplierId, setSupplierId] = useState('')
    const [from, setFrom] = useState('')
    const [to, setTo] = useState('')
    const [fromBad, setFromBad] = useState(false)
    const [toBad, setToBad] = useState(false)
    const [reason, setReason] = useState('')
    const [preview, setPreview] = useState<Preview | null>(null)
    const [error, setError] = useState('')
    const [issuedId, setIssuedId] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()
    const ready = !!supplierId && !!from && !!to && !fromBad && !toBad
    const reset = () => { setPreview(null); setIssuedId(null) }

    const row = (label: string, value: number, paren = false) => (
        <div className="flex justify-between gap-4 py-0.5">
            <span className="text-[color:var(--brand-muted-text)]">{label}</span>
            <span>{paren ? `(${money(value)})` : money(value)}</span>
        </div>
    )

    return (
        <section className="mb-8" data-section="issue-supplier-statement">
            <h2 className="mb-1">{t('supplierStatements.issueTitle')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-3 max-w-3xl">{t('supplierStatements.issueHint')}</p>
            {error && <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800" data-error="supplier-statement">{error}</div>}
            {issuedId && (
                <p className="mb-3 text-sm text-green-700" data-saved="supplier-statement">
                    {t('supplierStatements.issued')}{' '}
                    <Link href={`/finance/supplier-statements/${issuedId}`} className="app-link hover:underline">{t('supplierStatements.openIssued')}</Link>
                </p>
            )}
            <div className="flex flex-wrap items-end gap-3 mb-3">
                <label className="block text-sm min-w-0 basis-full sm:basis-auto">
                    <span className="block mb-1">{t('supplierStatements.supplier')} <span className="text-red-600">*</span></span>
                    <select value={supplierId} onChange={(e) => { setSupplierId(e.target.value); reset() }} className={`${CONTROL_SELECT} w-full sm:w-72`} data-field="supplier_id">
                        <option value="" disabled>{t('supplierStatements.pickSupplier')}</option>
                        {suppliers.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
                    </select>
                </label>
                <div className="block text-sm min-w-0">
                    <span className="block mb-1">{t('supplierStatements.from')} <span className="text-red-600">*</span></span>
                    <DatePicker kind="date" value={from} onChange={(v) => { setFrom(v); reset() }} onInvalidChange={setFromBad} />
                </div>
                <div className="block text-sm min-w-0">
                    <span className="block mb-1">{t('supplierStatements.to')} <span className="text-red-600">*</span></span>
                    <DatePicker kind="date" value={to} onChange={(v) => { setTo(v); reset() }} onInvalidChange={setToBad} />
                </div>
                <Button variant="secondary" type="button" disabled={pending || !ready}
                    onClick={() => { setError(''); startTransition(async () => {
                        const r = await previewSupplierStatement(supplierId, from, to)
                        if (r.error) { setError(r.error); setPreview(null); return }
                        setPreview(r.data as Preview)
                    }) }}>
                    {t('supplierStatements.preview')}
                </Button>
            </div>
            {preview && (
                <div className="mb-4 rounded border border-gray-300 p-3 text-sm max-w-md" data-section="supplier-statement-preview">
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('supplierStatements.previewIsLive')}</p>
                    {row(t('supplierStatements.doc.opening'), preview.opening_base)}
                    {row(t('supplierStatements.doc.charges'), preview.charges_base)}
                    {row(t('supplierStatements.doc.credits'), preview.credits_base, true)}
                    {row(t('supplierStatements.doc.payments'), preview.payments_base, true)}
                    {row(t('supplierStatements.doc.prepayments'), preview.prepayments_base, true)}
                    <div className="flex justify-between border-t border-gray-400 mt-1 pt-1 font-medium">
                        <span>{t('supplierStatements.doc.closing')}</span><span data-value="closing">{money(preview.closing_base)}</span>
                    </div>
                    <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]">
                        {t('supplierStatements.tieLine', { list: money(preview.list_base), onAccount: money(preview.on_account_base), residue: money(preview.residue_base) })}
                    </p>
                    {preview.no_movement && <p className="mt-2 text-xs text-amber-800">{t('supplierStatements.doc.noMovement')}</p>}
                    {preview.unpriced.length > 0 && <p className="mt-2 text-xs">{t('supplierStatements.unpricedCount', { n: preview.unpriced.length })}</p>}
                    {!preview.ties && (
                        <p className="mt-2 text-xs text-red-700" data-flag="does-not-tie">{t('supplierStatements.doesNotTie', { diff: money(preview.tie_difference) })}</p>
                    )}
                </div>
            )}
            {preview?.ties && (
                <PermissionGate code="module.finance.edit" allowed={canIssue}>
                    <div className="flex flex-wrap items-end gap-3 mb-4">
                        <label className="block text-sm min-w-0 basis-full sm:basis-auto">
                            <span className="block mb-1">{t('supplierStatements.supersedeReason')}</span>
                            <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder={t('supplierStatements.supersedeReasonHint')}
                                className={`${CONTROL_INPUT} w-full sm:w-72`} data-field="supersede_reason" />
                        </label>
                        <Button type="button" disabled={pending || !ready}
                            onClick={() => { setError(''); startTransition(async () => {
                                const r = await issueSupplierStatement(supplierId, from, to, reason)
                                if (r.error) { setError(r.error); return }
                                setIssuedId(r.statementId ?? null); setPreview(null); setReason('')
                                router.refresh()
                            }) }}>
                            {t('supplierStatements.issue')}
                        </Button>
                    </div>
                </PermissionGate>
            )}
        </section>
    )
}
