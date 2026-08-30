'use client'

// CMPL-1:公司自家执照的面板 —— 列出、新建、修改。
//
// ★★【这一屏最要紧的一件事:让【没录】看起来就是【没录】】★★
//   贮存上限留空**不表示"没有上限"**,表示**没有人录过上限**;而读到 NULL 的那道
//   判据会【拒绝作判断】(R2)。所以每一行都把"哪几格是空的"直接写出来,
//   而不是渲染成一个安静的空白 —— 一个空白与一个零在屏幕上长得一样,
//   而那正是本仓库反复付账的那种沉默。
//
// ★【样本值一个都没有】★ Tim 给的两张 NEA 执照属于另一家公司,只提供【字段】。
//   本文件没有默认值、示例值、占位符,也没有在注释里写「例如」。
//   Evoltrya 至今没有任何执照 —— **空登记簿就是正确状态**。

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { saveLicence, softDeleteLicence, type LicenceInput } from './licenceActions'

export type LicenceRow = {
    id: string
    cert_type_code: string
    cert_no: string | null
    issuing_body: string | null
    status: string | null
    issue_date: string | null
    valid_from: string | null
    valid_until: string | null
    approved_storage_limit_tonnes: number | null
    scope: string | null
    notes: string | null
}
export type CertType = { code: string; name_en: string; name_zh: string }

const STATUSES = ['active', 'suspended', 'revoked'] as const

const EMPTY: LicenceInput = {
    cert_type_code: '', cert_no: '', issuing_body: '', status: '',
    issue_date: '', valid_from: '', valid_until: '',
    approved_storage_limit_tonnes: '', scope: '', notes: '',
}

export default function LicencePanel({
    rows, certTypes, canEdit,
}: { rows: LicenceRow[]; certTypes: CertType[]; canEdit: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [form, setForm] = useState<LicenceInput | null>(null)
    const [error, setError] = useState<string | null>(null)
    const [saving, setSaving] = useState(false)

    const set = (k: keyof LicenceInput, v: string) =>
        setForm((f) => (f ? { ...f, [k]: v } : f))

    async function onSubmit(e: React.FormEvent) {
        e.preventDefault()
        if (!form) return
        setSaving(true); setError(null)
        const res = await saveLicence(form)
        setSaving(false)
        if (res.error) { setError(res.error); return }
        setForm(null); router.refresh()
    }

    async function onDelete(id: string) {
        setError(null)
        const res = await softDeleteLicence(id)
        if (res.error) { setError(res.error); return }
        router.refresh()
    }

    const field = 'border border-gray-300 rounded px-2 py-1 text-sm w-full'
    const label = 'block text-xs font-medium text-gray-600 mb-1'

    return (
        <div className="border border-gray-200 rounded p-4 mb-6">
            <div className="flex items-baseline justify-between mb-1">
                <h2 className="font-semibold">{t('company.licence.title')}</h2>
                {canEdit && form === null && (
                    <button type="button" onClick={() => { setForm({ ...EMPTY }); setError(null) }}
                            className="text-sm text-blue-600 hover:underline">
                        {t('company.licence.add')}
                    </button>
                )}
            </div>
            <p className="text-sm text-gray-700 max-w-3xl mb-3">{t('company.licence.what')}</p>

            {/* ★【空登记簿是正确状态,而且要说出来】★ 公司尚未获发任何执照。
                一句"还没有"与一片空白是两回事。 */}
            {rows.length === 0 && form === null ? (
                <p className="text-sm text-amber-800 bg-amber-50 border border-amber-200 rounded px-2 py-1 mb-3">
                    {t('company.licence.none')}
                </p>
            ) : null}

            {rows.length > 0 && (
                <table className="w-full border-collapse mb-3">
                    <thead>
                        <tr className="bg-gray-100">
                            <th className="border border-gray-300 px-2 py-1 text-left text-xs">{t('company.licence.colKind')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-left text-xs">{t('company.licence.colNo')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-left text-xs">{t('company.licence.colStatus')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-left text-xs">{t('company.licence.colValidity')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-right text-xs">{t('company.licence.colStorageLimit')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-left text-xs" />
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => {
                            const ct = certTypes.find((c) => c.code === r.cert_type_code)
                            return (
                                <tr key={r.id}>
                                    <td className="border border-gray-300 px-2 py-1 text-sm">{ct ? ct.name_en : r.cert_type_code}</td>
                                    <td className="border border-gray-300 px-2 py-1 text-sm font-mono">
                                        {r.cert_no ?? <span className="text-amber-800">{t('company.licence.notRecorded')}</span>}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1 text-sm">
                                        {r.status
                                            ? t('company.licence.status.' + r.status)
                                            : <span className="text-amber-800">{t('company.licence.notRecorded')}</span>}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1 text-sm">
                                        {r.valid_until ?? <span className="text-amber-800">{t('company.licence.notRecorded')}</span>}
                                    </td>
                                    {/* ★ 上限那一格:空 = 【没有人录过】,不是【没有上限】★ */}
                                    <td className="border border-gray-300 px-2 py-1 text-right text-sm">
                                        {r.approved_storage_limit_tonnes !== null
                                            ? r.approved_storage_limit_tonnes
                                            : <span className="text-red-800 font-medium">{t('company.licence.limitNotSet')}</span>}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1 text-sm">
                                        {canEdit && (
                                            <>
                                                <button type="button" className="text-blue-600 hover:underline mr-2"
                                                        onClick={() => setForm({
                                                            id: r.id,
                                                            cert_type_code: r.cert_type_code,
                                                            cert_no: r.cert_no ?? '',
                                                            issuing_body: r.issuing_body ?? '',
                                                            status: r.status ?? '',
                                                            issue_date: r.issue_date ?? '',
                                                            valid_from: r.valid_from ?? '',
                                                            valid_until: r.valid_until ?? '',
                                                            approved_storage_limit_tonnes:
                                                                r.approved_storage_limit_tonnes === null ? '' : String(r.approved_storage_limit_tonnes),
                                                            scope: r.scope ?? '',
                                                            notes: r.notes ?? '',
                                                        })}>
                                                    {t('company.licence.edit')}
                                                </button>
                                                <button type="button" className="text-red-700 hover:underline"
                                                        onClick={() => onDelete(r.id)}>
                                                    {t('company.licence.delete')}
                                                </button>
                                            </>
                                        )}
                                    </td>
                                </tr>
                            )
                        })}
                    </tbody>
                </table>
            )}

            {form !== null && (
                <form onSubmit={onSubmit} className="border-t border-gray-200 pt-3 space-y-3">
                    <div className="grid grid-cols-3 gap-3">
                        <div>
                            <label className={label} htmlFor="kind">{t('company.licence.fieldKind')}</label>
                            <select id="kind" className={field} value={form.cert_type_code}
                                    onChange={(e) => set('cert_type_code', e.target.value)}>
                                <option value="">{t('company.licence.selectPrompt')}</option>
                                {certTypes.map((c) => (
                                    <option key={c.code} value={c.code}>{c.name_en}</option>
                                ))}
                            </select>
                        </div>
                        <div>
                            <label className={label} htmlFor="no">{t('company.licence.fieldNo')}</label>
                            <input id="no" className={field} value={form.cert_no}
                                   onChange={(e) => set('cert_no', e.target.value)} />
                        </div>
                        <div>
                            <label className={label} htmlFor="body">{t('company.licence.fieldIssuer')}</label>
                            <input id="body" className={field} value={form.issuing_body}
                                   onChange={(e) => set('issuing_body', e.target.value)} />
                        </div>
                        <div>
                            <label className={label} htmlFor="st">{t('company.licence.fieldStatus')}</label>
                            <select id="st" className={field} value={form.status}
                                    onChange={(e) => set('status', e.target.value)}>
                                <option value="">{t('company.licence.selectPrompt')}</option>
                                {STATUSES.map((s) => (
                                    <option key={s} value={s}>{t('company.licence.status.' + s)}</option>
                                ))}
                            </select>
                        </div>
                        <div>
                            <label className={label} htmlFor="issued">{t('company.licence.fieldIssueDate')}</label>
                            <input id="issued" type="date" className={field} value={form.issue_date}
                                   onChange={(e) => set('issue_date', e.target.value)} />
                        </div>
                        <div>
                            <label className={label} htmlFor="from">{t('company.licence.fieldValidFrom')}</label>
                            <input id="from" type="date" className={field} value={form.valid_from}
                                   onChange={(e) => set('valid_from', e.target.value)} />
                        </div>
                        <div>
                            <label className={label} htmlFor="until">{t('company.licence.fieldValidUntil')}</label>
                            <input id="until" type="date" className={field} value={form.valid_until}
                                   onChange={(e) => set('valid_until', e.target.value)} />
                        </div>
                        <div>
                            <label className={label} htmlFor="lim">{t('company.licence.fieldStorageLimit')}</label>
                            <input id="lim" type="number" step="0.001" min="0" className={field}
                                   value={form.approved_storage_limit_tonnes}
                                   onChange={(e) => set('approved_storage_limit_tonnes', e.target.value)} />
                        </div>
                    </div>

                    {/* ★ 留空的后果要说在旁边,不是事后才知道 ★ */}
                    <p className="text-xs text-amber-800 bg-amber-50 border border-amber-200 rounded px-2 py-1">
                        {t('company.licence.limitWhy')}
                    </p>

                    <div>
                        <label className={label} htmlFor="scope">{t('company.licence.fieldScope')}</label>
                        <textarea id="scope" rows={3} className={field} value={form.scope}
                                  onChange={(e) => set('scope', e.target.value)} />
                        <p className="text-xs text-gray-600 mt-1">{t('company.licence.scopeWhy')}</p>
                    </div>

                    {error ? <p className="text-sm text-red-700">{error}</p> : null}
                    <div className="flex gap-2">
                        <button type="submit" disabled={saving || form.cert_type_code === ''}
                                className="rounded bg-gray-900 px-4 py-2 text-sm text-white disabled:bg-gray-400">
                            {t('company.licence.save')}
                        </button>
                        <button type="button" onClick={() => { setForm(null); setError(null) }}
                                className="rounded border border-gray-300 px-4 py-2 text-sm">
                            {t('company.licence.cancel')}
                        </button>
                    </div>
                </form>
            )}
        </div>
    )
}
