'use client'

// EXEC-3b:工单差异的两个阈值。人人看得见(阈值不是秘密 —— 看板上那盏灯亮不亮
// 就取决于它),持 module.processing.edit 的人改得动。
//
// 【为什么摆在工单列表页上】改这两个数的人就是看工单的人。放进一个总设置页
// 会让它归到另一批人名下,而他们不看这块屏(与 METAL-1 把行情阈值放在
// /tools/pricing/metal-prices 上同一条)。
//
// 【两个数,不是一个 —— 而屏幕上必须说得出它们为什么不同】
// 投入超耗是【成本】问题,产出短交是【收率】问题;合成一个数等于说它们一样严重。
// 触发时机也不同,而那一句最容易被漏读,所以各写一行:
//   超耗:任何时候都报(料已经下去了,那一刻就可处理);
//   短交:只在收工之后报(收工之前,"少"只是"还没做完")。
//
// 【这两个数是【判据】,不是【目标】】把它们调大,看板会安静,而车间一克料
// 都没有省下来 —— 与 output_unsold_aging 那条"改 output_date 会让牌子安静"
// 同一个隐患。所以面板上把这句话直说出来,而不是指望人自己想到。
import { useActionState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { updateWoThresholds, type WoThresholdState } from './thresholdActions'

const initialState: WoThresholdState = {}

export default function WoThresholdPanel({
    inputPct, outputPct, canEdit,
}: {
    inputPct: number; outputPct: number; canEdit: boolean
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(updateWoThresholds, initialState)

    return (
        <div className="border border-gray-300 rounded-lg p-4 mb-6 max-w-3xl">
            <p className="font-medium mb-1">{t('processing.wo.settings.title')}</p>
            <p className="text-sm text-gray-600 mb-1">{t('processing.wo.settings.hint')}</p>
            {/* 【判据不是目标】—— 这一句是这块面板最容易被需要的一句 */}
            <p className="text-xs text-amber-700 mb-3">{t('processing.wo.settings.notATarget')}</p>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded mb-3 text-sm">
                    {state.error}
                </div>
            )}
            {state.saved && (
                <div className="bg-green-50 border border-green-300 text-green-800 px-3 py-2 rounded mb-3 text-sm">
                    {t('processing.wo.settings.saved')}
                </div>
            )}

            {canEdit ? (
                <form action={formAction} className="space-y-3">
                    <div className="flex flex-wrap items-end gap-3">
                        <div>
                            <label className="block text-sm font-medium mb-1">
                                {t('processing.wo.settings.inputLabel')}
                            </label>
                            <input type="number" name="wo_input_overrun_pct" step="0.1" min="0.1"
                                   required defaultValue={inputPct}
                                   className="w-32 border border-gray-300 px-3 py-2 rounded" />
                            <p className="text-xs text-gray-500 mt-1">{t('processing.wo.settings.inputWhen')}</p>
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">
                                {t('processing.wo.settings.outputLabel')}
                            </label>
                            <input type="number" name="wo_output_shortfall_pct" step="0.1" min="0.1"
                                   required defaultValue={outputPct}
                                   className="w-32 border border-gray-300 px-3 py-2 rounded" />
                            <p className="text-xs text-gray-500 mt-1">{t('processing.wo.settings.outputWhen')}</p>
                        </div>
                        <button type="submit" disabled={isPending}
                                className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400">
                            {isPending ? t('common.saving') : t('common.save')}
                        </button>
                    </div>
                </form>
            ) : (
                <div className="text-sm space-y-1">
                    <p>{t('processing.wo.settings.inputLabel')}:{' '}
                       <span className="font-mono">{inputPct}</span>
                       <span className="text-xs text-gray-500 ml-2">{t('processing.wo.settings.inputWhen')}</span></p>
                    <p>{t('processing.wo.settings.outputLabel')}:{' '}
                       <span className="font-mono">{outputPct}</span>
                       <span className="text-xs text-gray-500 ml-2">{t('processing.wo.settings.outputWhen')}</span></p>
                    <p className="text-xs text-gray-500">{t('processing.wo.settings.readOnly')}</p>
                </div>
            )}
        </div>
    )
}
