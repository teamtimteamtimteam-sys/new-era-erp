'use client'

// GRN-1b:收货差异的三个阈值。人人看得见(阈值不是秘密 —— 屏幕上那几条提示
// 出不出现就取决于它),持写权限的人改得动。
//
// 【为什么摆在差异清单页上】改这三个数的人就是看这块屏的人 —— 与 EXEC-3b 把
// 工单阈值放在工单列表上、METAL-1 把行情阈值放在 /metal-prices 上同一条。
// 放进一个总设置页会让它归到另一批人名下,而他们不看这块屏。
//
// 【短交与超收是两个数,而屏幕上必须说得出它们为什么不同】
// 这是 GRN-1a 在数据库里做的决定,而一个只显示两个输入框的面板会把它抹平成
// "两个可调的数",于是下一个人自然会问"为什么不合成一个"。所以两句话各写一行:
//   短交:履约问题(货没到齐,该找供应商),【只在采购单关掉/取消之后才报】——
//         单还开着的时候"少"只是"还没收完";
//   超收:仓储与现金问题(占了地方、欠了钱),【任何状态都报,不等关单】。
// 时机的不对称正是"它们不是一个数"最硬的证据,所以它跟着标签走,不藏在别处。
//
// 【化验容差是【相对偏差】,不是百分点】锂常在 0.5% 量级、镍常在 30% 量级,
// 十个百分点对前者是二十倍、对后者是三分之一。这一句必须在框子旁边,否则
// 填这个数的人几乎一定会按百分点去想。
//
// 【这三个数是【判据】,不是【目标】】把它们调大,屏幕会安静,而【到货的东西
// 一克都没有变】。与 EXEC-3b 的 notATarget、output_unsold_aging 那条"改
// output_date 会让牌子安静"是同一个隐患,所以直说,不指望人自己想到。
import { useActionState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { updateGrnThresholds, type GrnThresholdState } from './thresholdActions'

const initialState: GrnThresholdState = {}

export default function ReceivingThresholdPanel({
    shortPct, overPct, assayPct, canEdit,
}: {
    shortPct: number; overPct: number; assayPct: number; canEdit: boolean
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(updateGrnThresholds, initialState)

    return (
        <div className="border border-gray-300 rounded-lg p-4 mb-6 max-w-4xl">
            <p className="font-medium mb-1">{t('grn.settings.title')}</p>
            <p className="text-sm text-gray-600 mb-1">{t('grn.settings.hint')}</p>
            {/* 【两个数,不是一个】—— 这块面板最容易被"简化"掉的一句 */}
            <p className="text-sm text-gray-600 mb-1">{t('grn.settings.twoNumbers')}</p>
            {/* 【判据不是目标】—— 这块面板最容易被需要的一句 */}
            <p className="text-xs text-amber-700 mb-3">{t('grn.settings.notATarget')}</p>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded mb-3 text-sm">
                    {state.error}
                </div>
            )}
            {state.saved && (
                <div className="bg-green-50 border border-green-300 text-green-800 px-3 py-2 rounded mb-3 text-sm">
                    {t('grn.settings.saved')}
                </div>
            )}

            {canEdit ? (
                <form action={formAction} className="space-y-3">
                    <div className="flex flex-wrap items-start gap-4">
                        <div className="max-w-xs">
                            <label className="block text-sm font-medium mb-1">
                                {t('grn.settings.shortLabel')}
                            </label>
                            <input type="number" name="grn_short_pct" step="0.1" min="0.1"
                                   required defaultValue={shortPct}
                                   className="w-32 border border-gray-300 px-3 py-2 rounded" />
                            <p className="text-xs text-gray-500 mt-1">{t('grn.settings.shortWhen')}</p>
                        </div>
                        <div className="max-w-xs">
                            <label className="block text-sm font-medium mb-1">
                                {t('grn.settings.overLabel')}
                            </label>
                            <input type="number" name="grn_over_pct" step="0.1" min="0.1"
                                   required defaultValue={overPct}
                                   className="w-32 border border-gray-300 px-3 py-2 rounded" />
                            <p className="text-xs text-gray-500 mt-1">{t('grn.settings.overWhen')}</p>
                        </div>
                        <div className="max-w-xs">
                            <label className="block text-sm font-medium mb-1">
                                {t('grn.settings.assayLabel')}
                            </label>
                            <input type="number" name="grn_assay_tolerance_pct" step="0.1" min="0.1"
                                   required defaultValue={assayPct}
                                   className="w-32 border border-gray-300 px-3 py-2 rounded" />
                            <p className="text-xs text-gray-500 mt-1">{t('grn.settings.assayWhen')}</p>
                        </div>
                    </div>
                    <button type="submit" disabled={isPending}
                            className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400">
                        {isPending ? t('common.saving') : t('common.save')}
                    </button>
                </form>
            ) : (
                <div className="text-sm space-y-1">
                    <p>{t('grn.settings.shortLabel')}:{' '}<span className="font-mono">{shortPct}</span>
                       <span className="text-xs text-gray-500 ml-2">{t('grn.settings.shortWhen')}</span></p>
                    <p>{t('grn.settings.overLabel')}:{' '}<span className="font-mono">{overPct}</span>
                       <span className="text-xs text-gray-500 ml-2">{t('grn.settings.overWhen')}</span></p>
                    <p>{t('grn.settings.assayLabel')}:{' '}<span className="font-mono">{assayPct}</span>
                       <span className="text-xs text-gray-500 ml-2">{t('grn.settings.assayWhen')}</span></p>
                    <p className="text-xs text-gray-500">{t('grn.settings.readOnly')}</p>
                </div>
            )}
        </div>
    )
}
