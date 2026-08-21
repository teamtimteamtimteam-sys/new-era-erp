'use client'

// PROC-1:物料【种类】+【可不可以投料】。新增页与编辑页共用一个。
//
// ════════════════════════════════════════════════════════════════════════════
// 【两个字段,而它们不是同一种问题 —— 这块控件的全部要点】
//   * 种类(kind)是【这是什么】—— 从 material_kinds 现读,加一种是加一行;
//   * 可不可以投料是【我们要不要投它】—— 一次判断。
//
// 【D8:必须是明说出来的选择,不给默认】两个单选钮【都不预选】。
// 一个预设某一侧的勾选框,就是一个没人做过的决定【从表单进来】,
// 而不是从 NULL 进来 —— 那正是这两列 NOT-NULL 化想挡住的东西换了条路。
//
// 【但当那一类【不可能】被投料时,它就不是一个判断了】
// 耗材 / 包装 / 备件的 may_ever_be_processed = false,数据库那条守卫
// (guard_material_kind_processable)会拒掉任何"是"。
// **所以这时不画那两个钮** —— 给一个服务端保证会拒的选项画控件,是本仓库
// 明写过的反面(「页面与服务端不一致时先问谁错了」);而画一个禁用的、
// 预选在"否"上的钮,又变回了一个默认值。
// 这时改为:说出这一类不可能被投料,并提交一个隐藏的 'no'。
// **答案由字典给出,而屏幕把这件事说出来,不是替人做决定。**
// ════════════════════════════════════════════════════════════════════════════
import { useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { KIND_UNCHOSEN, type MaterialKind } from './materialKindOptions'

export default function MaterialKindPicker({
    kinds, defaultKind, defaultProcessable, locale,
}: {
    kinds: MaterialKind[]
    defaultKind: string | null
    // null = 还没有人决定过(既有物料就是这个状态,而它不是 false)
    defaultProcessable: boolean | null
    locale: string
}) {
    const t = useTranslations()
    const [kind, setKind] = useState<string>(defaultKind ?? KIND_UNCHOSEN)
    const chosen = kinds.find((k) => k.code === kind) ?? null
    const label = (k: MaterialKind) => (locale === 'zh' ? k.name_zh : k.name_en)

    return (
        <>
            <div>
                <label className="block text-sm font-medium mb-1">{t('materials.form.kind')}</label>
                <select name="kind_code" value={kind} onChange={(e) => setKind(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded">
                    {/* 【"还没选"是一个明写的选项,不是"留空就是它"】—— 与
                        WasteClassPicker 的「未分类」同一条:空串在 FormData 里
                        与"没提交"分不开,所以用哨兵值,由服务端按名拒。 */}
                    <option value={KIND_UNCHOSEN}>{t('materials.form.kindUnchosen')}</option>
                    {kinds.map((k) => (
                        <option key={k.code} value={k.code}>{label(k)}</option>
                    ))}
                </select>
                <p className="text-xs text-gray-600 mt-1">{t('materials.form.kindHint')}</p>
            </div>

            <div>
                <label className="block text-sm font-medium mb-1">{t('materials.form.processable')}</label>
                {chosen && !chosen.may_ever_be_processed ? (
                    /* 这一类【不可能】被投料 —— 说出来,并提交隐藏的 no。
                       见本文件抬头:这时它不是一个判断,答案由字典给出。 */
                    <>
                        <input type="hidden" name="may_be_processed" value="no" />
                        <p className="text-sm text-gray-700 border border-gray-200 rounded px-3 py-2 bg-gray-50">
                            {t('materials.form.processableImpossible', { kind: label(chosen) })}
                        </p>
                    </>
                ) : (
                    <>
                        {/* 【两个都不预选】—— defaultProcessable 为 null 时谁都不选中,
                            于是"还没有人决定过"在屏幕上看得出来,而不是长得像"否"。 */}
                        <div className="flex gap-4">
                            {(['yes', 'no'] as const).map((v) => (
                                <label key={v} className="flex items-center gap-1 text-sm">
                                    <input type="radio" name="may_be_processed" value={v}
                                           defaultChecked={defaultProcessable === (v === 'yes')} />
                                    {t(v === 'yes' ? 'materials.form.processableYes' : 'materials.form.processableNo')}
                                </label>
                            ))}
                        </div>
                        <p className="text-xs text-gray-600 mt-1">{t('materials.form.processableHint')}</p>
                        {defaultProcessable === null && defaultKind !== null && (
                            <p className="text-xs text-amber-700 mt-1">{t('materials.form.processableUndecided')}</p>
                        )}
                    </>
                )}
            </div>
        </>
    )
}
