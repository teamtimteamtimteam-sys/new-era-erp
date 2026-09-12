'use client'

// GST-3:注册开关的控件。**打开是一次刻意的动作,不是一个 toggle。**
//
// 【为什么后果写在按钮【上面】,而不是按完之后】销售单那条信用额度提示立的先例:
// 把话说在【做决定的地方】。一个按下去才告诉你发生了什么的开关,
// 是在让人用一次真实的状态变更去阅读说明书。
//
// 【为什么不是 checkbox onChange】那会在人读完那三行字之前就把状态改掉。
//
// CONFIRM-1:两个方向各自换成 ConfirmButton。★ 主语是【那个注册号】—— 开的那一侧
//   是人刚敲进去的 regNo(它就要被写成公司的 GST 号),关的那一侧是【现在生效的
//   那一个】registrationNo。两者都已经在上面那条状态横幅里原样印着,没有遮蔽。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { setGstRegistration } from './gstActions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage, FieldMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export default function GstPanel({
    registered,
    registrationNo,
canEdit
}: {
    registered: boolean
    registrationNo: string | null

canEdit: boolean
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [regNo, setRegNo] = useState(registrationNo ?? '')

    // ★ ALERT-1:甲类那一条留在本组件里(它属于登记号那个框),
    //   其余走页级横幅。判据是服务端给的 result.field,不是在这里认字符串。
    const [fieldError, setFieldError] = useState<string | null>(null)

    function submit(on: boolean) {
        setFieldError(null)
        startTransition(async () => {
            const result = await setGstRegistration(on, regNo)
            if (!result?.error) return
            if (result.field === 'registrationNo') {
                setFieldError(result.error)
                return
            }
            showActionMessage({
                subject: on ? regNo : (registrationNo ?? regNo),
                headline: t('common.actionMessage.headline.notSwitched'),
                body: result.error,
                detail: result.detail,
            })
        })
    }

    const regNoBlank = regNo.trim() === ''

    return (
        <section className="border border-gray-300 rounded p-4 mb-6">
            <h2 className="mb-1">{t('finance.gstSwitch.title')}</h2>

            {/* 【状态是一句话,不是一个空白】与 /finance/gst 那条横幅同一个措辞族 */}
            <p className={'text-sm mb-3 inline-block px-3 py-2 rounded border ' +
                (registered ? 'bg-green-50 border-green-300 text-green-900'
                            : 'bg-amber-50 border-amber-300 text-amber-900')}>
                {registered
                    ? t('finance.gstSwitch.isOn', { no: registrationNo ?? '—' })
                    : t('finance.gstSwitch.isOff')}
            </p>

            {!registered ? (
                <>
                    {/* ★【后果写在动作【之前】】★ 三件事,都是开关一翻就立刻成立的 */}
                    <div className="text-sm bg-blue-50 border border-blue-200 rounded px-3 py-2 mb-3">
                        <p className="font-medium mb-1">{t('finance.gstSwitch.beforeYouTurnItOn')}</p>
                        <ul className="list-disc ml-5 space-y-1">
                            <li>{t('finance.gstSwitch.consequenceDocuments')}</li>
                            <li>{t('finance.gstSwitch.consequenceF5')}</li>
                            <li>{t('finance.gstSwitch.consequenceDefaults')}</li>
                        </ul>
                    </div>

                    <div className="flex flex-wrap items-end gap-3">
                        <div>
                            <label className="block mb-1">
                                {t('finance.gstSwitch.regNo')} <span className="text-red-600">*</span>
                            </label>
                            <input
                                type="text"
                                value={regNo}
                                onChange={(e) => setRegNo(e.target.value)}
                                placeholder={t('finance.gstSwitch.regNoPlaceholder')}
                                className={CONTROL_INPUT}
                                aria-invalid={fieldError ? true : undefined}
                            />
                            {/* ★ 甲类:话贴着那个框。页顶一条横幅会让人回头找是哪个框。 */}
                            <FieldMessage field="registrationNo">{fieldError}</FieldMessage>
                        </div>
                        <PermissionGate code="module.finance.edit" allowed={canEdit}>
                        <ConfirmButton
                            subject={regNo}
                            title={t('finance.gstSwitch.confirmOn')}
                            confirmLabel={t('finance.gstSwitch.turnOn')}
                            tier="destructive"
                            onConfirm={() => submit(true)}
                            disabled={isPending || regNoBlank}
                            className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                        >
                            {t('finance.gstSwitch.turnOn')}
                        </ConfirmButton>
                        </PermissionGate>
                    </div>
                    {/* 【禁用必须说出为什么】CMP-2:每个禁钮条件都有紧邻的一行字 */}
                    {regNoBlank && (
                        <p className="text-sm text-amber-700 mt-2">{t('finance.gstSwitch.regNoWhy')}</p>
                    )}
                </>
            ) : (
                <>
                    {/* 关的那一侧:先说清楚它【可能关不掉】,以及为什么 */}
                    <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('finance.gstSwitch.turningOffHint')}</p>
                    <PermissionGate code="module.finance.edit" allowed={canEdit}>
                    {/* ══════════════════════════════════════════════════════
                        ★ POLISH-1(2026-09-12,Tim 的裁定 R3)· 回到标准档 ★
                        ══════════════════════════════════════════════════════
                        改前这里**没有 `triggerVariant`**,于是 `confirm-dialog` 渲染的是
                        一个**裸 `<button>` + 手写 className**:`px-4 py-2` ≈ 38px 高
                        (标准 32px)、灰描边、`disabled:text-gray-400` = **2.54:1**。
                        ★ 而它的 `tier` 一直写着 `destructive` —— **语义是破坏档,
                        画法不是**:它连那条 3px 红竖条都没有。BTN-6 走查时看见的
                        「浅得几乎没有的那道线」正是这圈灰描边
                        (见 `docs/base-components.md` §F6)。
                        ☞ 补上 `triggerVariant="destructive"`,画法就与 `tier` 说的是同一件事了。
                        ⚠ **隔壁那颗「Turn GST on」不在这一刀里**(它是 R3 点名之外的
                        41 颗裸触发钮之一,归 `BTN-TRIGGER-1`)。两颗**不会同屏** ——
                        它们住在 `registered ? … : …` 的两支上,所以这中间不会有
                        「并排两颗长得不一样」的一屏。 */}
                    <ConfirmButton
                        subject={registrationNo ?? regNo}
                        title={t('finance.gstSwitch.confirmOff')}
                        body={t('finance.gstSwitch.consequenceOff')}
                        confirmLabel={t('finance.gstSwitch.turnOff')}
                        tier="destructive"
                        triggerVariant="destructive"
                        onConfirm={() => submit(false)}
                        disabled={isPending}
                    >
                        {t('finance.gstSwitch.turnOff')}
                    </ConfirmButton>
                    </PermissionGate>
                </>
            )}

            {/* 【那个死掉的标量列】—— 一个看起来像设置、实际什么都不做的东西,
                正是下一个人"把税率设成 9%"然后什么都没发生的地方 */}
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-4">{t('finance.gstSwitch.rateLivesElsewhere')}</p>
        </section>
    )
}
