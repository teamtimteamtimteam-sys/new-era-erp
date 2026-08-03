'use client'

// 评级档位编辑器 —— 与 LeaveTypesEditor 同一套路:行内编辑 + 底部新增卡。
// 停用而不删除(is_active);is_probation_pass 是【提示,不是规则】,
// 转正与否由评估单据上的 probation_outcome 明说。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useLocale, useTranslations } from '@/lib/i18n/client'
import { saveRatingScale } from './actions'

export type ScaleRow = {
    code: string
    name_en: string
    name_zh: string
    description_en: string | null
    description_zh: string | null
    sort_order: number
    is_active: boolean
    is_probation_pass: boolean
}

const inp = 'w-full border border-gray-300 rounded px-1 py-0.5 text-xs'

export default function ScaleEditor({ rows }: { rows: ScaleRow[] }) {
    const t = useTranslations()
    const locale = useLocale()
    const router = useRouter()
    const [editing, setEditing] = useState<string | null>(null)
    const [draft, setDraft] = useState<ScaleRow | null>(null)
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)

    const [nCode, setNCode] = useState('')
    const [nEn, setNEn] = useState('')
    const [nZh, setNZh] = useState('')
    const [nSort, setNSort] = useState('')

    function begin(r: ScaleRow) {
        setEditing(r.code)
        setDraft({ ...r })
        setError(null)
    }

    function save() {
        if (!draft) return
        setError(null)
        startTransition(async () => {
            const r = await saveRatingScale(
                draft.code,
                {
                    name_en: draft.name_en,
                    name_zh: draft.name_zh,
                    description_en: draft.description_en,
                    description_zh: draft.description_zh,
                    sort_order: draft.sort_order,
                    is_active: draft.is_active,
                    is_probation_pass: draft.is_probation_pass,
                },
                false
            )
            if (r.error) setError(r.error)
            else {
                setEditing(null)
                setDraft(null)
                router.refresh()
            }
        })
    }

    function add() {
        setError(null)
        startTransition(async () => {
            const r = await saveRatingScale(
                nCode.trim().toUpperCase(),
                {
                    name_en: nEn.trim(),
                    name_zh: nZh.trim(),
                    description_en: null,
                    description_zh: null,
                    sort_order: nSort.trim() === '' ? 0 : Number(nSort),
                    is_active: true,
                    is_probation_pass: false,
                },
                true
            )
            if (r.error) setError(r.error)
            else {
                setNCode(''); setNEn(''); setNZh(''); setNSort('')
                router.refresh()
            }
        })
    }

    return (
        <div>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            <table className="w-full border-collapse text-sm mb-6">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('reviews.scaleCode')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('reviews.scaleName')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('reviews.scaleDescription')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-right">{t('reviews.scaleSort')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('reviews.scaleActive')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('reviews.scaleProbationPass')}</th>
                        <th className="border border-gray-300 px-2 py-1 w-28"></th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => {
                        const on = editing === r.code
                        return (
                            <tr key={r.code} className="align-top">
                                <td className="border border-gray-300 px-2 py-1 font-mono text-gray-500">{r.code}</td>
                                <td className="border border-gray-300 px-2 py-1">
                                    {on ? (
                                        <>
                                            <input
                                                value={draft!.name_en}
                                                onChange={(e) => setDraft({ ...draft!, name_en: e.target.value })}
                                                className={`${inp} mb-1`}
                                            />
                                            <input
                                                value={draft!.name_zh}
                                                onChange={(e) => setDraft({ ...draft!, name_zh: e.target.value })}
                                                className={inp}
                                            />
                                        </>
                                    ) : locale === 'zh' ? r.name_zh : r.name_en}
                                </td>
                                <td className="border border-gray-300 px-2 py-1 text-xs text-gray-600">
                                    {on ? (
                                        <>
                                            <input
                                                value={draft!.description_en ?? ''}
                                                onChange={(e) => setDraft({ ...draft!, description_en: e.target.value || null })}
                                                className={`${inp} mb-1`}
                                            />
                                            <input
                                                value={draft!.description_zh ?? ''}
                                                onChange={(e) => setDraft({ ...draft!, description_zh: e.target.value || null })}
                                                className={inp}
                                            />
                                        </>
                                    ) : (locale === 'zh' ? r.description_zh : r.description_en) ?? '—'}
                                </td>
                                <td className="border border-gray-300 px-2 py-1 text-right font-mono">
                                    {on ? (
                                        <input
                                            type="number"
                                            value={draft!.sort_order}
                                            onChange={(e) => setDraft({ ...draft!, sort_order: Number(e.target.value) })}
                                            className={`${inp} w-16 text-right`}
                                        />
                                    ) : r.sort_order}
                                </td>
                                <td className="border border-gray-300 px-2 py-1">
                                    {on ? (
                                        <input
                                            type="checkbox"
                                            checked={draft!.is_active}
                                            onChange={(e) => setDraft({ ...draft!, is_active: e.target.checked })}
                                        />
                                    ) : r.is_active ? t('permissions.yes') : t('permissions.no')}
                                </td>
                                <td className="border border-gray-300 px-2 py-1">
                                    {on ? (
                                        <input
                                            type="checkbox"
                                            checked={draft!.is_probation_pass}
                                            onChange={(e) => setDraft({ ...draft!, is_probation_pass: e.target.checked })}
                                        />
                                    ) : r.is_probation_pass ? t('permissions.yes') : t('permissions.no')}
                                </td>
                                <td className="border border-gray-300 px-2 py-1 whitespace-nowrap">
                                    {on ? (
                                        <>
                                            <button
                                                type="button"
                                                onClick={save}
                                                disabled={pending}
                                                className="text-blue-600 hover:underline mr-2"
                                            >
                                                {t('common.save')}
                                            </button>
                                            <button
                                                type="button"
                                                onClick={() => { setEditing(null); setDraft(null) }}
                                                className="text-gray-500 hover:underline"
                                            >
                                                {t('common.cancel')}
                                            </button>
                                        </>
                                    ) : (
                                        <button
                                            type="button"
                                            onClick={() => begin(r)}
                                            className="text-blue-600 hover:underline"
                                        >
                                            {t('reviews.edit')}
                                        </button>
                                    )}
                                </td>
                            </tr>
                        )
                    })}
                </tbody>
            </table>

            <div className="rounded border border-gray-200 p-4">
                <h3 className="font-bold mb-3 text-sm">{t('reviews.addScale')}</h3>
                <div className="flex gap-2 flex-wrap items-end">
                    <label className="text-xs">
                        {t('reviews.scaleCode')}
                        <input
                            value={nCode}
                            onChange={(e) => setNCode(e.target.value)}
                            className={`block ${inp} w-32 font-mono`}
                        />
                    </label>
                    <label className="text-xs">
                        {t('permissions.nameEn')}
                        <input value={nEn} onChange={(e) => setNEn(e.target.value)} className={`block ${inp} w-40`} />
                    </label>
                    <label className="text-xs">
                        {t('permissions.nameZh')}
                        <input value={nZh} onChange={(e) => setNZh(e.target.value)} className={`block ${inp} w-40`} />
                    </label>
                    <label className="text-xs">
                        {t('reviews.scaleSort')}
                        <input
                            type="number"
                            value={nSort}
                            onChange={(e) => setNSort(e.target.value)}
                            className={`block ${inp} w-20 text-right`}
                        />
                    </label>
                    <button
                        type="button"
                        onClick={add}
                        disabled={pending || !nCode.trim() || !nEn.trim() || !nZh.trim()}
                        className="bg-gray-900 text-white px-3 py-1.5 rounded text-sm disabled:opacity-50"
                    >
                        {t('common.save')}
                    </button>
                </div>
            </div>
        </div>
    )
}
