'use client'

// PROC-WIRE-1B-ii(R1 / M4):这一批【自产料】身上的安全状态。
//
// ★【"一条都没有"必须【说出来】,不能画成空白】★ 这是本面板最要紧的一行:
// 没有安全状态的意思是【没有人记过】,**不是"它安全"** —— 与那道闸、与
// inbound_batch_safety_states 的表注是同一个意思。一块空白的面板会让人以为
// "这里没什么要管的",而实际上这批料根本投不进去。
//
// 【它与"用途"是两条不同的轴】用途答"这批是干什么用的"(工序决定,
// processing.edit);本面板答"这批料是什么状态"(产出/收货的人看见的,output.edit)。
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { addOutputSafetyState, removeOutputSafetyState } from './safetyActions'

export type SafetyState = {
    code: string; name_en: string; name_zh: string; may_be_fed: boolean
}

export default function SafetyStatePanel({
    batchId, dictionary, current, canEdit, locale,
}: {
    batchId: string
    dictionary: SafetyState[]
    current: string[]
    canEdit: boolean
    locale: string
}) {
    const t = useTranslations()
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()

    const label = (s: SafetyState) => (locale === 'zh' ? s.name_zh : s.name_en)
    const held = new Set(current)

    function toggle(code: string, on: boolean) {
        setError(null)
        startTransition(async () => {
            const r = on
                ? await addOutputSafetyState(batchId, code)
                : await removeOutputSafetyState(batchId, code)
            if (r.error) setError(r.error)
        })
    }

    return (
        <div className="mt-8 border rounded p-4">
            <h2 className="font-semibold mb-1">{t('output.safety.title')}</h2>
            <p className="text-xs text-gray-500 mb-3">{t('output.safety.why')}</p>

            {/* ★ 一条都没有 → 按名说出来,不画空白 */}
            {current.length === 0 ? (
                <div className="mb-3 bg-amber-50 border border-amber-300 text-amber-800 px-3 py-2 rounded text-sm">
                    {t('output.safety.noneRecorded')}
                </div>
            ) : (
                <div className="mb-3 flex flex-wrap gap-2">
                    {dictionary.filter((s) => held.has(s.code)).map((s) => (
                        <span key={s.code}
                              className={
                                  'inline-block px-2 py-0.5 rounded text-xs border ' +
                                  (s.may_be_fed
                                      ? 'bg-green-100 text-green-800 border-green-300'
                                      : 'bg-red-100 text-red-800 border-red-300')
                              }>
                            {label(s)}
                            {!s.may_be_fed && ' · ' + t('output.safety.notFeedable')}
                        </span>
                    ))}
                </div>
            )}

            {canEdit ? (
                <div className="flex flex-wrap gap-2">
                    {dictionary.map((s) => (
                        <button key={s.code} type="button" disabled={isPending}
                                onClick={() => toggle(s.code, !held.has(s.code))}
                                className={
                                    'px-3 py-1.5 text-sm rounded border disabled:opacity-50 ' +
                                    (held.has(s.code)
                                        ? 'bg-gray-200 border-gray-300'
                                        : 'bg-white border-gray-300 hover:bg-gray-50')
                                }>
                            {held.has(s.code)
                                ? t('output.safety.remove', { name: label(s) })
                                : t('output.safety.add', { name: label(s) })}
                        </button>
                    ))}
                </div>
            ) : (
                <p className="text-xs text-gray-500">{t('output.safety.noPermission')}</p>
            )}

            {error && (
                <div className="mt-3 bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded text-sm">
                    {error}
                </div>
            )}
        </div>
    )
}
