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
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
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
            <h2 className="mb-1">{t('output.safety.title')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">{t('output.safety.why')}</p>

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
                    {dictionary.map((s) => {
                        const on = held.has(s.code)
                        const cls =
                            'px-3 py-1.5 text-sm rounded border disabled:opacity-50 ' +
                            (on ? 'bg-gray-200 border-gray-300'
                                : 'bg-white border-gray-300 hover:bg-gray-50')
                        // ★★【只有【拆】那一边有门,【记】那一边没有】★★(ALERT-2c,Tim 裁定 R4)
                        //   记一条安全状态是【加】,而且再点一下就撤得掉;
                        //   拆掉一条是【硬删】—— output_batch_safety_states 直接 .delete(),
                        //   没有理由、没有墓碑、没有回头路。
                        //   两个方向都弹框,是在教人把对话框当成一道过场 ——
                        //   而那正是一个确认框失效的方式。
                        return on ? (
                            <ConfirmButton
                                key={s.code}
                                subject={label(s)}
                                title={t('output.safety.removeConfirmTitle')}
                                body={t('common.hardDeleteNote')}
                                /* ★ 后果那一段【走对话框自己的 token】,不新画一个琥珀盒子:
                                     本刀明令不碰 ALERT-2b 那 ~250 处行内色值,
                                     那就更不该往里【添】一处。 */
                                details={
                                    <p className="text-sm font-medium text-[color:var(--brand-text)]">
                                        {t('output.safety.removeConsequence')}
                                    </p>
                                }
                                confirmLabel={t('common.delete')}
                                disabled={isPending}
                                className={cls}
                                onConfirm={() => toggle(s.code, false)}
                            >
                                {t('output.safety.remove', { name: label(s) })}
                            </ConfirmButton>
                        ) : (
                            <button key={s.code} type="button" disabled={isPending}
                                    onClick={() => toggle(s.code, true)}
                                    className={cls}>
                                {t('output.safety.add', { name: label(s) })}
                            </button>
                        )
                    })}
                </div>
            ) : (
                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('output.safety.noPermission')}</p>
            )}

            {error && (
                <div className="mt-3 bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded text-sm">
                    {error}
                </div>
            )}
        </div>
    )
}
