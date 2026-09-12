'use client'

import { CONTROL_SELECT, CONTROL_INPUT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useActionState } from 'react'
import Link from 'next/link'
import { Button } from '@/app/components/ui/button'
import { createMetalPrice, type CreateMetalPriceState } from './actions'
import type { MetalOption } from '../options'
import { useTranslations } from '@/lib/i18n/client'
import AnomalyWarning from '../AnomalyWarning'
import SourcePicker from '../SourcePicker'
import type { MetalPriceIndex } from '../indexOptions'
import { ACK_FIELD, ackSignature } from '../anomaly'

const initialState: CreateMetalPriceState = {}

// 本地日期(YYYY-MM-DD),用作价格日期默认值(避免 UTC 偏移)。
function todayIsoLocal(): string {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
}

export default function NewMetalPriceForm({
    substanceOptions,
    indices,
    locale,
}: {
    // PROC-4:物质清单由页面从字典读好传进来(清单与顺序都由它定)。
    substanceOptions: MetalOption[]
    indices: MetalPriceIndex[]
    locale: string
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(
        createMetalPrice,
        initialState
    )

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/tools/pricing/metal-prices"
                    className="hover:underline text-sm app-link"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="mb-6">{t('metalPrices.newTitle')}</h1>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                {/* 金属(必填)*/}
                <div>
                    <label className="block mb-1">
                        {t('metalPrices.form.metal')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="metal"
                        required
                        defaultValue=""
                        className={`${CONTROL_SELECT} w-full`}
                    >
                        <option value="" disabled>{t('metalPrices.form.selectMetal')}</option>
                        {substanceOptions.filter((s) => s.isActive).map((o) => (
                            <option key={o.value} value={o.value}>
                                {t(o.labelKey)}
                            </option>
                        ))}
                    </select>
                    {state.fieldErrors?.metal && (
                        <p className="text-red-600 text-xs mt-1">{state.fieldErrors.metal}</p>
                    )}
                </div>

                {/* 价格(必填,> 0)*/}
                <div>
                    <label className="block mb-1">
                        {t('metalPrices.form.price')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="number"
                        name="price_usd_per_tonne"
                        required
                        step="0.01"
                        min="0"
                        className={`${CONTROL_INPUT} w-full`}
                    />
                    {state.fieldErrors?.price_usd_per_tonne && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.price_usd_per_tonne}
                        </p>
                    )}
                </div>

                {/* LME-1b:出处三件套。指数下拉在 SourcePicker 里,只有选了
                    "发布的指数"才启用 —— 镜像 1a 的配对 CHECK。 */}
                <SourcePicker indices={indices} locale={locale}
                              error={state.fieldErrors?.quote_source} />

                {/* 价格日期(必填,默认今天)*/}
                <div>
                    <label className="block mb-1">
                        {t('metalPrices.form.priceDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="price_date"
                        required
                        defaultValue={todayIsoLocal()}
                        className={`${CONTROL_INPUT} w-full`}
                    />
                    {state.fieldErrors?.price_date && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.price_date}
                        </p>
                    )}
                </div>

                {/* 备注 */}
                <div>
                    <label className="block mb-1">{t('metalPrices.form.notes')}</label>
                    <textarea
                        name="notes"
                        className={`${CONTROL_TEXTAREA} w-full`}
                    />
                </div>

                {/* METAL-1:异常提示 —— 出现时这一次【没有保存】,确认钮才保存 */}
                {state.warnings && state.warnings.length > 0 && (
                    <>
                        <AnomalyWarning items={state.warnings} />
                        {/* 第二次提交带上确认位。表单里的值原样保留,人不用重敲 */}
                        <input type="hidden" name={ACK_FIELD} value={ackSignature(state.warnings)} />
                    </>
                )}

                {/* ════════════════════════════════════════════════════════════
                    ★ POLISH-1(2026-09-12,Tim 的裁定 R3)· 这两颗回到标准档 ★
                    ════════════════════════════════════════════════════════════
                    改前:Save 是一个**手搓的 `<button>`**(`px-4 py-2` ≈ 38px 高,
                    而标准是 32px),底色 `bg-blue-600` = **Tailwind 通用蓝 #155DFC**,
                    不是品牌蓝;禁用态 `disabled:bg-gray-400` = **2.54:1**,
                    正是 BTN-1 存在的理由本身(库里的禁用态是 11.27:1)。
                    Cancel 是一个手搓边框的 `<Link>`,一样不是标准档。
                    ★ 琥珀那一支【不是】随手选的颜色,它是一个**状态**
                    ——「这一次提交带着异常确认」——所以它走库里的 `warning` 档
                    (`docs/base-components.md`:唯一「系统在告诉你一件正在发生的事」那一档),
                    而不是被抹成 default。**颜色的意思保住了,画法换成库的。**
                    ★ Cancel 照抄树上已有的房子写法(`NewWorkOrderForm.tsx:200`):
                    `<Button asChild variant="secondary">` 裹一个 `<Link>` ——
                    ⚠ 不要把它换成 `<Button onClick>`:那会让「离开这一页」变成一次
                    JS 跳转,而 `fieldset disabled` 挡不住 `<a>` 正是 DBLOCK-1 的那条边界。 */}
                <div className="flex gap-3 pt-4">
                    <Button
                        type="submit"
                        variant={state.warnings?.length ? 'warning' : 'default'}
                        disabled={isPending}
                    >
                        {isPending
                            ? t('common.saving')
                            : state.warnings?.length
                              ? t('metalPrices.anomaly.confirm')
                              : t('common.save')}
                    </Button>
                    <Button asChild variant="secondary">
                        <Link href="/tools/pricing/metal-prices">
                            {t('common.cancel')}
                        </Link>
                    </Button>
                </div>
            </form>
        </div>
    )
}
