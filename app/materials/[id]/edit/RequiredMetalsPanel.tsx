'use client'

// app/materials/[id]/edit/RequiredMetalsPanel.tsx
// ASY-P2:「这种物料要化验哪些金属」的编辑器。
//
// 【每一个物料都要把自己的状态说出来 —— 包括"没有要求"那一个】
// ASY-P1 的模型是「没有行 = 没有要求」,而那是一个【假设】:它读作"这种物料不需要
// 化验",同时也是"还没有人为这种物料想过这件事"的样子 —— 两者在数据库里长得一模一样。
// 数据库分不开它们,所以【屏幕必须把当前状态按名说出来】,不能让一排没打勾的方框
// 自己去说话:一排空方框读起来像"还没加载出来",不像一个决定。
// 这就是 currentLabel 那一行存在的全部理由。
//
// 【一句人话,写在编辑器旁边】这些勾决定的是首页那一支会不会点亮;一个空集合的
// 意思是"这种物料永远不出现在那里"。不说这句话,勾选框就只是七个没有后果的方框。
import { useActionState, useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import type { MetalOption } from '@/app/pricing/metal-prices/options'
import { saveRequiredMetals, type RequiredMetalsState } from './requiredMetalsActions'

export default function RequiredMetalsPanel({
    substanceOptions,
    materialId,
    initial,
    canEdit,
}: {
    // PROC-4:物质清单由页面从 substances 那张字典读好传进来。
    // 【表单不再自己拿着一份清单】那份清单曾经是这份名单的第五个副本,
    // 而它与库里的顺序【实测已经对不上】(它按重要性,库里的视图按字母序)。
    substanceOptions: MetalOption[]
    materialId: string
    /** 当前已声明的金属 code(可能是空数组 —— 那【是】一个状态,不是缺数据) */
    initial: string[]
    /** 没有 module.materials.edit 时只读:控件禁用,状态照样说出来 */
    canEdit: boolean
}) {
    const t = useTranslations()
    const [picked, setPicked] = useState<string[]>(initial)
    const [state, formAction, isPending] = useActionState<RequiredMetalsState, FormData>(
        saveRequiredMetals.bind(null, materialId),
        {}
    )

    const metalName = (code: string) => t('metals.' + code)

    // 【当前状态,按名说出来】—— 勾选框反映的是"我正在编辑什么",这一行反映的是
    // "现在是什么"。两者在有未保存改动时会不同,而那正是应该看得见的。
    const currentLabel =
        initial.length === 0
            ? t('materials.assayPolicy.noRequirement')
            : t('materials.assayPolicy.currentSet', {
                  metals: initial.map(metalName).join(', '),
              })

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-lg font-semibold mb-1">{t('materials.assayPolicy.title')}</h2>

            {/* 【一句人话:这些勾有什么后果】 */}
            <p className="text-sm text-gray-600 mb-3">{t('materials.assayPolicy.note')}</p>

            {/* 【当前状态永远说出来】—— 包括"无化验要求" */}
            <p className="text-sm mb-3">
                <span className="text-gray-500">{t('materials.assayPolicy.currentLabel')}</span>{' '}
                <span className={initial.length === 0 ? 'text-gray-600 italic' : 'font-medium'}>
                    {currentLabel}
                </span>
            </p>

            <form action={formAction}>
                <div className="flex flex-wrap gap-x-5 gap-y-2 mb-3">
                    {substanceOptions.filter((s) => s.isActive).map((o) => (
                        <label
                            key={o.value}
                            className={
                                'inline-flex items-center gap-2 text-sm ' +
                                (canEdit ? 'cursor-pointer' : 'cursor-not-allowed opacity-60')
                            }
                        >
                            <input
                                type="checkbox"
                                name="metal"
                                value={o.value}
                                disabled={!canEdit || isPending}
                                checked={picked.includes(o.value)}
                                onChange={(e) =>
                                    setPicked((prev) =>
                                        e.target.checked
                                            ? [...prev, o.value]
                                            : prev.filter((m) => m !== o.value)
                                    )
                                }
                            />
                            <span>
                                {t(o.labelKey)}{' '}
                                <span className="font-mono text-xs text-gray-500">{o.value}</span>
                            </span>
                        </label>
                    ))}
                </div>

                {/* 【取消所有勾也是一次提交】按钮文案不随选择变化 —— "保存"就是保存,
                    包括保存成一个空集合。写成"清空要求"会让人以为那是另一个按钮。 */}
                {canEdit ? (
                    <button
                        type="submit"
                        disabled={isPending}
                        className="text-sm border border-gray-400 px-3 py-1 rounded hover:bg-gray-50 disabled:opacity-50"
                    >
                        {isPending ? t('common.saving') : t('common.save')}
                    </button>
                ) : (
                    // 【永远不要为服务端必然拒绝的动作渲染提交控件】(AGENTS.md)
                    <p className="text-xs text-amber-700">{t('materials.assayPolicy.needsEdit')}</p>
                )}

                {/* 保存成空集合时,把那句话再说一遍 —— 一个"已保存"配一排空方框,
                    看起来像什么都没发生。 */}
                {picked.length === 0 && canEdit && (
                    <p className="text-xs text-gray-500 mt-2">
                        {t('materials.assayPolicy.emptyMeans')}
                    </p>
                )}

                {state.error && <p className="text-sm text-red-600 mt-2">{state.error}</p>}
                {state.ok && !state.error && (
                    <p className="text-sm text-green-700 mt-2">{t('common.saved')}</p>
                )}
            </form>
        </section>
    )
}
