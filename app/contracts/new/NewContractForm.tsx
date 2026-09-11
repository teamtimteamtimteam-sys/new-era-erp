'use client'

// MANUAL-FIX-2:新建合同的表单。结构取自 suppliers/new(server shell + client form)。
import { useActionState, useRef, useState } from 'react'
import Link from 'next/link'
import { useFormDraft } from '@/lib/useFormDraft'
import DraftBanner from '@/app/components/DraftBanner'
import { useTranslations } from '@/lib/i18n/client'
import { createContract, type CreateContractState } from './actions'
import { Button } from '@/app/components/ui/button'
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'

const initialState: CreateContractState = {}

export type PartyOption = { id: string; label: string }

const KINDS = ['supply', 'offtake', 'framework', 'service', 'other'] as const

export default function NewContractForm({
    suppliers,
    customers,
    canSeeSuppliers,
    canSeeCustomers,
    currencies,
}: {
    suppliers: PartyOption[]
    customers: PartyOption[]
    /** ★ 看不看得见【不等于】列表是空的 —— 见下面那两句具名的缺席。 */
    canSeeSuppliers: boolean
    canSeeCustomers: boolean
    currencies: string[]
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createContract, initialState)
    const formRef = useRef<HTMLFormElement>(null)
    const draft = useFormDraft({ formKey: 'contracts/new', table: 'contracts', subject: null, formRef })

    // 状态那一段的说明跟着选择走 —— 两个选项的后果差得很远,而其中一个不可逆。
    const [status, setStatus] = useState('active')

    const field = `${CONTROL_INPUT} w-full`
    const fieldSelect = `${CONTROL_SELECT} w-full`
    const fieldTextarea = `${CONTROL_TEXTAREA} w-full`
    const err = (k: string) =>
        state.fieldErrors?.[k] ? <p className="text-red-600 text-xs mt-1">{state.fieldErrors[k]}</p> : null

    return (
        <>
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form ref={formRef} action={formAction} className="space-y-4">
                <DraftBanner draft={draft} />

                {/* ── 对手方 ───────────────────────────────────────────────
                    【一个字段,不是两个】「恰好属于一边」是数据库上的一条 CHECK,
                    而一个下拉框让它在屏幕上也成为结构性的:选不出"两个都是"。 */}
                <div>
                    <label className="block mb-1">
                        {t('contracts.form.counterparty')} <span className="text-red-600">*</span>
                    </label>
                    <select name="counterparty" defaultValue="" className={fieldSelect}>
                        <option value="">{t('contracts.form.counterpartyPlaceholder')}</option>
                        {suppliers.length > 0 && (
                            <optgroup label={t('contracts.form.groupSuppliers')}>
                                {suppliers.map((s) => (
                                    <option key={s.id} value={`supplier:${s.id}`}>{s.label}</option>
                                ))}
                            </optgroup>
                        )}
                        {customers.length > 0 && (
                            <optgroup label={t('contracts.form.groupCustomers')}>
                                {customers.map((c) => (
                                    <option key={c.id} value={`customer:${c.id}`}>{c.label}</option>
                                ))}
                            </optgroup>
                        )}
                    </select>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1 max-w-2xl">{t('contracts.form.counterpartyHint')}</p>
                    {/* ★★【具名的缺席 —— 一张空下拉不许冒充"没有对手方"】★★
                        客户名单在 module.customers.view 那道门后面,而本页的门是
                        供应商查看权。看不见的人此前会拿到一个【空的】客户分组,
                        与"一个客户都还没建"长得一模一样(OPS-14 那条跨模块无声消失)。 */}
                    {!canSeeCustomers && (
                        <p className="text-xs text-amber-800 mt-1 max-w-2xl">{t('contracts.form.customersRestricted')}</p>
                    )}
                    {!canSeeSuppliers && (
                        <p className="text-xs text-amber-800 mt-1 max-w-2xl">{t('contracts.form.suppliersRestricted')}</p>
                    )}
                    {canSeeCustomers && customers.length === 0 && (
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1 max-w-2xl">{t('contracts.form.customersNone')}</p>
                    )}
                    {canSeeSuppliers && suppliers.length === 0 && (
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1 max-w-2xl">{t('contracts.form.suppliersNone')}</p>
                    )}
                    {err('counterparty')}
                </div>

                {/* ── 种类 ─────────────────────────────────────────────── */}
                <div>
                    <label className="block mb-1">
                        {t('contracts.form.kind')} <span className="text-red-600">*</span>
                    </label>
                    <select name="kind" defaultValue="supply" className={fieldSelect}>
                        {KINDS.map((k) => (
                            <option key={k} value={k}>{t(`contracts.kind.${k}`)}</option>
                        ))}
                    </select>
                    {err('kind')}
                </div>

                {/* ── 标题 ─────────────────────────────────────────────── */}
                <div>
                    <label className="block mb-1">
                        {t('contracts.form.title')} <span className="text-red-600">*</span>
                    </label>
                    <input type="text" name="title" required className={field}
                           placeholder={t('contracts.form.titlePlaceholder')} />
                    {err('title')}
                </div>

                {/* ── 期限 ─────────────────────────────────────────────── */}
                <div className="grid gap-4 sm:grid-cols-2">
                    <div>
                        <label className="block mb-1">
                            {t('contracts.form.effectiveFrom')} <span className="text-red-600">*</span>
                        </label>
                        <input type="date" name="effective_from" required className={field} />
                        {err('effective_from')}
                    </div>
                    <div>
                        <label className="block mb-1">{t('contracts.form.effectiveTo')}</label>
                        <input type="date" name="effective_to" className={field} />
                        {/* 【空 = 没有固定期限,不是"忘了填"】—— 表上那条列注就是这么写的,
                            而表单必须说同一句话,否则它自己在暗示相反的意思。 */}
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('contracts.form.effectiveToHint')}</p>
                        {err('effective_to')}
                    </div>
                </div>

                {/* ── 状态:创建时选,而【之后改不了】 ───────────────────── */}
                <div>
                    <label className="block mb-1">
                        {t('contracts.form.status')} <span className="text-red-600">*</span>
                    </label>
                    <select name="status" value={status} onChange={(e) => setStatus(e.target.value)} className={fieldSelect}>
                        <option value="active">{t('contracts.status.active')}</option>
                        <option value="draft">{t('contracts.status.draft')}</option>
                    </select>
                    <p className="text-sm text-[color:var(--brand-text)] mt-1 max-w-2xl">
                        {status === 'active' ? t('contracts.form.statusActiveMeans') : t('contracts.form.statusDraftMeans')}
                    </p>
                    {/* ★★ 这一句【必须】在屏幕上,不能只在手册里 ★★
                        这个系统里没有任何一处改得动合同状态 —— 建成什么就是什么。
                        一个人若以为"先存成草稿,谈定了再启用",他会建出一份
                        永远用不了的合同,而且是在事后才发现。 */}
                    <p className="text-sm text-amber-900 mt-1 max-w-2xl font-medium">
                        {t('contracts.form.statusIsFinal')}
                    </p>
                    {err('status')}
                </div>

                {/* ── 商务条款(全部可空:框架协议可以不定币种、不定贸易术语)── */}
                <div className="grid gap-4 sm:grid-cols-2">
                    <div>
                        <label className="block mb-1">{t('contracts.form.signedOn')}</label>
                        <input type="date" name="signed_on" className={field} />
                    </div>
                    <div>
                        <label className="block mb-1">{t('contracts.form.currency')}</label>
                        <select name="currency" defaultValue="" className={fieldSelect}>
                            <option value="">{t('contracts.form.currencyNone')}</option>
                            {currencies.map((c) => <option key={c} value={c}>{c}</option>)}
                        </select>
                    </div>
                    <div>
                        <label className="block mb-1">{t('contracts.form.incoterm')}</label>
                        <input type="text" name="incoterm" className={field}
                               placeholder={t('contracts.form.incotermPlaceholder')} />
                    </div>
                    <div>
                        <label className="block mb-1">{t('contracts.form.paymentTermsDays')}</label>
                        <input type="number" name="payment_terms_days" min={0} max={365} className={field} />
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('contracts.form.paymentTermsDaysHint')}</p>
                        {err('payment_terms_days')}
                    </div>
                </div>

                <div>
                    <label className="block mb-1">{t('contracts.form.documentRef')}</label>
                    <input type="text" name="document_ref" className={field}
                           placeholder={t('contracts.form.documentRefPlaceholder')} />
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1 max-w-2xl">{t('contracts.form.documentRefHint')}</p>
                </div>

                <div>
                    <label className="block mb-1">{t('contracts.form.notes')}</label>
                    <textarea name="notes" className={fieldTextarea} />
                </div>

                {/* ★ 建完之后能做什么、不能做什么 —— 说在【建之前】 */}
                <div className="border border-amber-300 bg-amber-50 rounded p-4 max-w-2xl">
                    <h2 className="mb-1">{t('contracts.form.afterTitle')}</h2>
                    <p className="text-sm text-[color:var(--brand-text)]">{t('contracts.form.afterCanDo')}</p>
                    <p className="text-sm text-amber-900 mt-2 font-medium">{t('contracts.form.afterCannotDo')}</p>
                </div>

                <div className="flex gap-3 pt-4">
                    <Button type="submit" disabled={isPending}>
                        {isPending ? t('common.saving') : t('common.save')}
                    </Button>
                    <Button asChild variant="secondary">
                        <Link href="/contracts">{t('common.cancel')}</Link>
                    </Button>
                </div>
            </form>
        </>
    )
}
