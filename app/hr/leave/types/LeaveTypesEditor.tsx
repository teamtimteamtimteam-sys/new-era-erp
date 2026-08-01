'use client'

// app/hr/leave/types/LeaveTypesEditor.tsx
// 就地编辑假别配置。code 只读 —— 它是稳定标识,改了就等于换了一个假别。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { saveLeaveType } from './actions'

export type LeaveTypeRow = {
    code: string
    name_en: string
    name_zh: string
    description_en: string | null
    description_zh: string | null
    is_paid: boolean
    is_accrued: boolean
    default_days_per_year: number | null
    requires_certificate_after_days: number | null
    allows_half_day: boolean
    is_active: boolean
    sort_order: number
    notes: string | null
}

export default function LeaveTypesEditor({ rows }: { rows: LeaveTypeRow[] }) {
    const t = useTranslations()
    const locale = useLocale()
    const router = useRouter()
    const [editing, setEditing] = useState<string | null>(null)
    const [draft, setDraft] = useState<LeaveTypeRow | null>(null)
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)

    function begin(r: LeaveTypeRow) { setEditing(r.code); setDraft({ ...r }); setError(null) }

    function save() {
        if (!draft) return
        setError(null)
        startTransition(async () => {
            const r = await saveLeaveType(draft.code, {
                name_en: draft.name_en, name_zh: draft.name_zh,
                default_days_per_year: draft.default_days_per_year,
                requires_certificate_after_days: draft.requires_certificate_after_days,
                allows_half_day: draft.allows_half_day,
                is_active: draft.is_active,
                sort_order: draft.sort_order,
            })
            if (r.error) setError(r.error)
            else { setEditing(null); setDraft(null); router.refresh() }
        })
    }

    const inp = 'w-full border border-gray-300 rounded px-1 py-0.5 text-xs'

    return (
        <div>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            <table className="w-full border-collapse text-sm">
                <thead>
                    <tr className="bg-gray-50 text-left text-xs">
                        <th className="border border-gray-300 px-2 py-1">{t('leave.typeCode')}</th>
                        <th className="border border-gray-300 px-2 py-1">{t('leave.typeName')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-right">{t('leave.standardDaysCol')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-right">{t('leave.certAfter')}</th>
                        <th className="border border-gray-300 px-2 py-1">{t('leave.paid')}</th>
                        <th className="border border-gray-300 px-2 py-1">{t('leave.accrued')}</th>
                        <th className="border border-gray-300 px-2 py-1">{t('leave.halfDay')}</th>
                        <th className="border border-gray-300 px-2 py-1">{t('permissions.active')}</th>
                        <th className="border border-gray-300 px-2 py-1"></th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => {
                        const on = editing === r.code && draft
                        return (
                            <tr key={r.code} className="text-xs align-top">
                                <td className="border border-gray-300 px-2 py-1 font-mono text-gray-500">{r.code}</td>
                                <td className="border border-gray-300 px-2 py-1">
                                    {on ? (
                                        <>
                                            <input value={draft!.name_en} className={inp}
                                                   onChange={(e) => setDraft({ ...draft!, name_en: e.target.value })} />
                                            <input value={draft!.name_zh} className={inp + ' mt-1'}
                                                   onChange={(e) => setDraft({ ...draft!, name_zh: e.target.value })} />
                                        </>
                                    ) : (
                                        <>
                                            <div>{locale === 'zh' ? r.name_zh : r.name_en}</div>
                                            {r.notes && <div className="text-[10px] text-gray-500 mt-0.5">{r.notes}</div>}
                                        </>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-2 py-1 text-right">
                                    {on ? (
                                        <input type="number" step="0.5" className={inp}
                                               value={draft!.default_days_per_year ?? ''}
                                               onChange={(e) => setDraft({ ...draft!, default_days_per_year: e.target.value === '' ? null : Number(e.target.value) })} />
                                    ) : (r.default_days_per_year ?? '—')}
                                </td>
                                <td className="border border-gray-300 px-2 py-1 text-right">
                                    {on ? (
                                        <input type="number" step="0.5" className={inp}
                                               value={draft!.requires_certificate_after_days ?? ''}
                                               onChange={(e) => setDraft({ ...draft!, requires_certificate_after_days: e.target.value === '' ? null : Number(e.target.value) })} />
                                    ) : (r.requires_certificate_after_days ?? '—')}
                                </td>
                                <td className="border border-gray-300 px-2 py-1">{r.is_paid ? t('permissions.yes') : t('permissions.no')}</td>
                                <td className="border border-gray-300 px-2 py-1">{r.is_accrued ? t('permissions.yes') : t('permissions.no')}</td>
                                <td className="border border-gray-300 px-2 py-1">
                                    {on ? (
                                        <input type="checkbox" checked={draft!.allows_half_day}
                                               onChange={(e) => setDraft({ ...draft!, allows_half_day: e.target.checked })} />
                                    ) : (r.allows_half_day ? t('permissions.yes') : t('permissions.no'))}
                                </td>
                                <td className="border border-gray-300 px-2 py-1">
                                    {on ? (
                                        <input type="checkbox" checked={draft!.is_active}
                                               onChange={(e) => setDraft({ ...draft!, is_active: e.target.checked })} />
                                    ) : (r.is_active ? t('permissions.yes') : t('permissions.no'))}
                                </td>
                                <td className="border border-gray-300 px-2 py-1 whitespace-nowrap">
                                    {on ? (
                                        <>
                                            <button type="button" onClick={save} disabled={pending}
                                                    className="text-blue-600 hover:underline mr-2">{t('common.save')}</button>
                                            <button type="button" onClick={() => { setEditing(null); setDraft(null) }}
                                                    className="text-gray-500 hover:underline">{t('common.cancel')}</button>
                                        </>
                                    ) : (
                                        <button type="button" onClick={() => begin(r)}
                                                className="text-blue-600 hover:underline">{t('permissions.editRole')}</button>
                                    )}
                                </td>
                            </tr>
                        )
                    })}
                </tbody>
            </table>
        </div>
    )
}
