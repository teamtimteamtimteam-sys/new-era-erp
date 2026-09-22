'use client'

// ════════════════════════════════════════════════════════════════════════════
// APR-1(2026-09-22)· 审批策略的控件 —— 这块面板此前【只有读的那一半】
// ════════════════════════════════════════════════════════════════════════════
//
// 【四个值一起保存,这是跟着数据库走的】guard_approvals_switch 是把它们【放在
// 一起】判的:开之前策略必须齐、两级都必须有真持有人且看得见金额。一次只存一个
// 值的表单,会让操作员走进一个数据库已经保证【到不了】的中间状态 ——
// 然后在最后一步撞上一句他三步之前就该看到的话。
//
// 【能不能开、能不能关,在按之前就说出来】判据来自 approvals_readiness(),
// 也就是闸读的【同一份】。所以这里【不重算】任何东西:can_enable 为假时把开关
// 禁掉并把 blocking 原样印出来。★ 它仍然不是权威 —— 绕开界面直接调 RPC 照样会
// 撞上那九条具名拒绝。两层不是重复:这一层只是不让人白跑一趟。
//
// ★【admin / cco 【列】在下拉框里,而不是被悄悄拿掉】★(docs/approvals.md §0b)
//   §0b 的裁定是"两级都不许指向 admin",并且【有意不做成机器规则】——
//   理由写在那一节里:一条只禁一个角色码的规则,会成为"谁可以批"的第二份定义,
//   而且换个角色授一遍同样的码就绕过去了。
//   ☞ 一个悄悄把它们去掉的下拉框,在执行这条规矩的同时【不留下任何痕迹】——
//     下一个读代码的人会以为数据库拦着它。所以:列出来,把那句话印在旁边。
//
// 【CMP-2:每一个禁用条件都有紧邻的一行字】禁掉却不说为什么的控件,与坏掉的
// 控件在屏幕上长得一样。
import { useState, useTransition } from 'react'
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_CHECKBOX } from '@/app/components/ui/control-style'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage, FieldMessage } from '@/app/components/ui/action-message'
import { setApprovalsPolicy } from './actions'

export type RoleOption = { code: string; name_en: string; name_zh: string; sort_order: number }

export default function ApprovalsForm({
    enabled,
    level1RoleCode,
    level2RoleCode,
    thresholdBase,
    roles,
    canEnable,
    canDisable,
    blocking,
    pendingPurchaseOrders,
}: {
    enabled: boolean
    level1RoleCode: string | null
    level2RoleCode: string | null
    thresholdBase: string | null
    roles: RoleOption[]
    canEnable: boolean
    canDisable: boolean
    blocking: string[]
    pendingPurchaseOrders: number
}) {
    const t = useTranslations()
    const locale = useLocale()
    const [isPending, startTransition] = useTransition()

    const [on, setOn] = useState(enabled)
    const [l1, setL1] = useState(level1RoleCode ?? '')
    const [l2, setL2] = useState(level2RoleCode ?? '')
    const [thr, setThr] = useState(thresholdBase ?? '')

    // ★ ALERT-1 甲类:说的是【某一个框】的那几条留在框旁边,其余走页级横幅。
    //   判据是服务端给的 result.field,不是在这里认字符串。
    const [fieldError, setFieldError] = useState<{ field: string; message: string } | null>(null)
    const [notice, setNotice] = useState<string | null>(null)

    const roleLabel = (r: RoleOption) =>
        `${locale === 'zh' ? r.name_zh : r.name_en} (${r.code})`

    // 【为什么禁用条件分两个方向写】会把在途单据搁死的是【关】那一边,
    // 而那一边的理由要点名还剩几张 —— 一堵没有出路的墙不是一次拒绝。
    const turningOn = on && !enabled
    const turningOff = !on && enabled
    const blockedOn = turningOn && !canEnable
    const blockedOff = turningOff && !canDisable
    const disabled = isPending || blockedOn || blockedOff

    function submit() {
        setFieldError(null)
        setNotice(null)
        startTransition(async () => {
            const result = await setApprovalsPolicy({
                enabled: on,
                level1RoleCode: l1 === '' ? null : l1,
                level2RoleCode: l2 === '' ? null : l2,
                thresholdBase: thr,
            })
            if (result?.error) {
                if (result.field) {
                    setFieldError({ field: result.field, message: result.error })
                    return
                }
                showActionMessage({
                    subject: t('finance.approvals.editTitle'),
                    headline: t('common.actionMessage.headline.notPolicySaved'),
                    body: result.error,
                    detail: result.detail,
                })
                return
            }
            // ★【"什么都没改"是第三种结果,不是一次成功】报成成功,操作员会以为
            //   自己刚刚改了什么;而库里既没有新值,也没有那一行史。
            setNotice(result.changed
                ? t('finance.approvals.saved')
                : t('finance.approvals.savedNothingChanged'))
        })
    }

    return (
        <section className="border border-gray-300 rounded p-4 mb-6">
            <h2 className="mb-1">{t('finance.approvals.editTitle')}</h2>

            {/* Q4:看得见这一页 = 改得动它。两个码是同一个,所以这里没有只读状态。 */}
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">
                {t('finance.approvals.seeingIsChanging')}
            </p>

            <div className="space-y-3 max-w-2xl">
                <div>
                    <label className="block mb-1" htmlFor="apr-l1">{t('finance.approvals.level1Pick')}</label>
                    <select
                        id="apr-l1"
                        value={l1}
                        onChange={(e) => setL1(e.target.value)}
                        className={CONTROL_SELECT}
                        aria-invalid={fieldError?.field === 'level1RoleCode' ? true : undefined}
                    >
                        <option value="">{t('finance.approvals.rolePickNone')}</option>
                        {roles.map((r) => (
                            <option key={r.code} value={r.code}>{roleLabel(r)}</option>
                        ))}
                    </select>
                    <FieldMessage field="level1RoleCode">
                        {fieldError?.field === 'level1RoleCode' ? fieldError.message : null}
                    </FieldMessage>
                </div>

                <div>
                    <label className="block mb-1" htmlFor="apr-thr">{t('finance.approvals.thresholdPick')}</label>
                    <input
                        id="apr-thr"
                        type="text"
                        inputMode="decimal"
                        value={thr}
                        onChange={(e) => setThr(e.target.value)}
                        className={CONTROL_INPUT}
                        aria-invalid={fieldError?.field === 'thresholdBase' ? true : undefined}
                    />
                    <FieldMessage field="thresholdBase">
                        {fieldError?.field === 'thresholdBase' ? fieldError.message : null}
                    </FieldMessage>
                </div>

                <div>
                    <label className="block mb-1" htmlFor="apr-l2">{t('finance.approvals.level2Pick')}</label>
                    <select
                        id="apr-l2"
                        value={l2}
                        onChange={(e) => setL2(e.target.value)}
                        className={CONTROL_SELECT}
                    >
                        <option value="">{t('finance.approvals.rolePickNone')}</option>
                        {roles.map((r) => (
                            <option key={r.code} value={r.code}>{roleLabel(r)}</option>
                        ))}
                    </select>
                </div>

                {/* ★ §0b:列出来,把裁定印在旁边 —— 不从下拉框里悄悄拿掉 */}
                <p className="text-xs text-amber-900 bg-amber-50 border border-amber-200 rounded px-2 py-1">
                    {t('finance.approvals.adminWarning')}
                </p>

                <label className="flex items-start gap-2" htmlFor="apr-on">
                    <input
                        id="apr-on"
                        type="checkbox"
                        checked={on}
                        onChange={(e) => setOn(e.target.checked)}
                        className={CONTROL_CHECKBOX}
                    />
                    <span className="text-sm">{t('finance.approvals.enabledLabel')}</span>
                </label>

                {/* Q5:开着的时候改策略【允许】,但先说清楚它对在途单据做了什么 */}
                {enabled && (
                    <p className="text-xs text-[color:var(--brand-text)] bg-blue-50 border border-blue-200 rounded px-2 py-1">
                        {t('finance.approvals.whileOnPending', { n: String(pendingPurchaseOrders) })}
                    </p>
                )}

                <ConfirmButton
                    subject={`${l1 || t('finance.approvals.rolePickNone')} / ${l2 || t('finance.approvals.rolePickNone')} / ${thr || t('finance.approvals.historyUnset')}`}
                    title={t('finance.approvals.confirmSaveTitle')}
                    body={on ? t('finance.approvals.flipOn') : t('finance.approvals.flipOff', { n: String(pendingPurchaseOrders) })}
                    confirmLabel={t('finance.approvals.save')}
                    tier="destructive"
                    triggerVariant="destructive"
                    onConfirm={submit}
                    disabled={disabled}
                >
                    {t('finance.approvals.save')}
                </ConfirmButton>

                {/* 【CMP-2】禁用必须说出为什么,而且两个方向各说各的 */}
                {blockedOn && (
                    <p className="text-sm text-amber-800">
                        {t('finance.approvals.enableBlockedWhy', { what: blocking.join(', ') })}
                    </p>
                )}
                {blockedOff && (
                    <p className="text-sm text-amber-800">
                        {t('finance.approvals.disableBlockedWhy', { n: String(pendingPurchaseOrders) })}
                    </p>
                )}

                {notice && (
                    <p className="text-sm text-green-800 bg-green-50 border border-green-200 rounded px-2 py-1">
                        {notice}
                    </p>
                )}
            </div>
        </section>
    )
}
