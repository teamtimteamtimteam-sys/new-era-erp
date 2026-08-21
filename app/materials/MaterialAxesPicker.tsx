'use client'

// PROC-1 + PROC-2b:一种物料的【分类那一整块】—— 种类、能不能投料,以及三条状态轴。
//
// 【为什么是一个组件而不是两个】三条状态轴【适不适用】由种类决定,而种类的
// 当前选择只有这里知道(它是本组件的 state)。拆成两个组件,第二个就得把
// 种类再传一遍、或者自己再查一次 —— 而那就是同一个事实的第二个来源。
// (本文件 PROC-1 时叫 MaterialKindPicker;它现在渲染五个控件,那个名字已经
//  名不副实,所以 PROC-2b 改名 —— 一个说谎的名字比一个长名字贵。)
//
// ════════════════════════════════════════════════════════════════════════════
// 【D2:适用性必须【看得见】,不能只是【被拦住】—— 这是本刀最难的一块】
//
// 三条轴只对某些种类成立。**不适用的时候不要画一个空控件** ——
// 一个没有解释就消失的控件,与一个【加载失败】的控件长得一模一样,
// 而这个仓库已经撞见过那种困惑。
//
// 【而"不适用"不是一种状态,是【四种】—— 这是 grill 挖出来的那一处】
// 规格尺寸那一个控件有五种情形,写一句话会有一半时候是错的:
//   ① 种类还没选     → 还【不知道】适不适用(不是"不适用")
//   ② 种类没有状态轴 → 不适用,**理由是种类**
//   ③ 形态还没选     → 还不知道(适用条件的第二半没定)
//   ④ 形态不需要拆解 → 不适用,**理由是形态**
//   ⑤ 适用           → 画控件
// 形态与来源只有 ①②⑤ 三种。**每一种说自己的话。**
//
// 【"用字典的原话"这句要求做了一处调整,写下来】brief 说不适用那句话要
// "用字典使用的同一批词"。字典的原话住在 notes 与表注里 —— 长段中文,
// 不是 UI 文案,而且不是双语。**照抄做不到,而且照抄会造出两份必然漂开的文本。**
// 改成:**那句话的【可变部分】从字典现读**(种类名/形态名,双语都从行上取),
// 不变的那半是一条 i18n 句子。于是屏幕上说的理由与字典里那一列说的是同一件事,
// 而两者只有一处定义。
// ════════════════════════════════════════════════════════════════════════════
//
// 【P4:哪里都不给默认】所有下拉都以【还没选】这个哨兵开局;两个单选钮都不预选。
// 而当答案【由字典给出】时(那一类不可能被投料),不画控件 —— PROC-1 立的先例。
import { useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { KIND_UNCHOSEN, type MaterialKind } from './materialKindOptions'
import { AXIS_UNCHOSEN, type MaterialForm, type MaterialSource, type MaterialSizeFormat } from './materialAxesOptions'

// 不适用/未知时画的那一行 —— 灰底、成句,而不是一个消失了的控件。
function NotApplicable({ label, why }: { label: string; why: string }) {
    return (
        <div>
            <label className="block text-sm font-medium mb-1 text-gray-500">{label}</label>
            <p className="text-sm text-gray-600 border border-gray-200 rounded px-3 py-2 bg-gray-50">{why}</p>
        </div>
    )
}

export default function MaterialAxesPicker({
    kinds, forms, sources, sizeFormats,
    defaultKind, defaultProcessable, defaultForm, defaultSource, defaultSizeFormat, locale,
}: {
    kinds: MaterialKind[]; forms: MaterialForm[]; sources: MaterialSource[]; sizeFormats: MaterialSizeFormat[]
    defaultKind: string | null; defaultProcessable: boolean | null
    defaultForm: string | null; defaultSource: string | null; defaultSizeFormat: string | null
    locale: string
}) {
    const t = useTranslations()
    const [kind, setKind] = useState<string>(defaultKind ?? KIND_UNCHOSEN)
    const [form, setForm] = useState<string>(defaultForm ?? AXIS_UNCHOSEN)
    const label = (r: { name_en: string; name_zh: string }) => (locale === 'zh' ? r.name_zh : r.name_en)

    const chosenKind = kinds.find((k) => k.code === kind) ?? null
    const chosenForm = forms.find((f) => f.code === form) ?? null
    const kindChosen = kind !== KIND_UNCHOSEN
    // 【适用条件全部现读字典】不写死任何 code —— 那正是 PROC-1 把 CHECK 换成
    // 字典换来的东西,而在屏幕这一侧同样要兑现。
    const axesApply = chosenKind?.has_condition_axes === true

    const dropdown = (name: string, value: string, onChange: ((v: string) => void) | null,
                      rows: { code: string; name_en: string; name_zh: string }[], unchosenKey: string) => (
        <select name={name} defaultValue={onChange ? undefined : value} value={onChange ? value : undefined}
                onChange={onChange ? (e) => onChange(e.target.value) : undefined}
                className="w-full border border-gray-300 px-3 py-2 rounded">
            <option value={AXIS_UNCHOSEN}>{t(unchosenKey)}</option>
            {rows.map((r) => <option key={r.code} value={r.code}>{label(r)}</option>)}
        </select>
    )

    return (
        <>
            {/* ── 种类 ─────────────────────────────────────────────────────── */}
            <div>
                <label className="block text-sm font-medium mb-1">{t('materials.form.kind')}</label>
                <select name="kind_code" value={kind} onChange={(e) => setKind(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded">
                    <option value={KIND_UNCHOSEN}>{t('materials.form.kindUnchosen')}</option>
                    {kinds.map((k) => <option key={k.code} value={k.code}>{label(k)}</option>)}
                </select>
                <p className="text-xs text-gray-600 mt-1">{t('materials.form.kindHint')}</p>
            </div>

            {/* ── 能不能投料(PROC-1)──────────────────────────────────────── */}
            <div>
                <label className="block text-sm font-medium mb-1">{t('materials.form.processable')}</label>
                {chosenKind && !chosenKind.may_ever_be_processed ? (
                    <>
                        <input type="hidden" name="may_be_processed" value="no" />
                        <p className="text-sm text-gray-700 border border-gray-200 rounded px-3 py-2 bg-gray-50">
                            {t('materials.form.processableImpossible', { kind: label(chosenKind) })}
                        </p>
                    </>
                ) : (
                    <>
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

            {/* ── 形态(PROC-2b)──────────────────────────────────────────── */}
            {!kindChosen ? (
                <NotApplicable label={t('materials.form.formAxis')} why={t('materials.form.axisNeedsKind')} />
            ) : !axesApply ? (
                <NotApplicable label={t('materials.form.formAxis')}
                    why={t('materials.form.axisNotForKind', { kind: label(chosenKind!) })} />
            ) : (
                <div>
                    <label className="block text-sm font-medium mb-1">{t('materials.form.formAxis')}</label>
                    {dropdown('form_code', form, setForm, forms, 'materials.form.formUnchosen')}
                    <p className="text-xs text-gray-600 mt-1">{t('materials.form.formHint')}</p>
                </div>
            )}

            {/* ── 来源 ─────────────────────────────────────────────────────── */}
            {!kindChosen ? (
                <NotApplicable label={t('materials.form.sourceAxis')} why={t('materials.form.axisNeedsKind')} />
            ) : !axesApply ? (
                <NotApplicable label={t('materials.form.sourceAxis')}
                    why={t('materials.form.axisNotForKind', { kind: label(chosenKind!) })} />
            ) : (
                <div>
                    <label className="block text-sm font-medium mb-1">{t('materials.form.sourceAxis')}</label>
                    {dropdown('source_code', defaultSource ?? AXIS_UNCHOSEN, null, sources, 'materials.form.sourceUnchosen')}
                    <p className="text-xs text-gray-600 mt-1">{t('materials.form.sourceHint')}</p>
                </div>
            )}

            {/* ── 规格尺寸:五种情形,每一种说自己的话(见本文件抬头)────────── */}
            {!kindChosen ? (
                <NotApplicable label={t('materials.form.sizeAxis')} why={t('materials.form.axisNeedsKind')} />
            ) : !axesApply ? (
                <NotApplicable label={t('materials.form.sizeAxis')}
                    why={t('materials.form.axisNotForKind', { kind: label(chosenKind!) })} />
            ) : form === AXIS_UNCHOSEN ? (
                <NotApplicable label={t('materials.form.sizeAxis')} why={t('materials.form.sizeNeedsForm')} />
            ) : chosenForm && !chosenForm.implies_dismantling ? (
                <NotApplicable label={t('materials.form.sizeAxis')}
                    why={t('materials.form.sizeNotForForm', { form: label(chosenForm) })} />
            ) : (
                <div>
                    <label className="block text-sm font-medium mb-1">{t('materials.form.sizeAxis')}</label>
                    {dropdown('size_format_code', defaultSizeFormat ?? AXIS_UNCHOSEN, null, sizeFormats, 'materials.form.sizeUnchosen')}
                    <p className="text-xs text-gray-600 mt-1">{t('materials.form.sizeHint')}</p>
                </div>
            )}
        </>
    )
}
