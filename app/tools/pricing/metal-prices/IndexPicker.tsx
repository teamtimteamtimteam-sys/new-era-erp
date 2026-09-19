'use client'

// METAL-2:指数选择器。三处录入页与公式表单共用一个,免得四份下拉各自漂移。
//
// 【"未声明指数"是一个明写的选项,不是留空】见 indexOptions.ts 的说明:
// 尚未标注的公式只看得见未标注的行情,所以在公式被标注之前,操作员必须还能
// 往那条序列里录价 —— 但那必须是一次【选择】,不是"没选就是它"。
import { useTranslations } from '@/lib/i18n/client'
import { CONTROL_SELECT } from '@/app/components/ui/control-style'
import { INDEX_UNSTATED, type MetalPriceIndex } from './indexOptions'

export default function IndexPicker({
    name,
    indices,
    defaultValue,
    locale,
    allowUnstated = true,
    onChange,
    // ★ BTN-TRIGGER-1(2026-09-20)· 队列「合并的小件 ④」的那颗下拉就是这一个。
    //   那一条把它记在 `FormulaForm` 名下,而 `FormulaForm` 只是【渲染】它 ——
    //   这串 class 一直住在这里,住在一个【解构默认值】里。照 `<select>` 标签去找
    //   找不到它:那一页上三颗 `<select>` 早就走 CONTROL_SELECT 了。
    //   ☞ 读类型块(`className?: string`)会说「没有默认值」—— 默认值在它上面三行。
    //   实测(改前→改后,两个视口相同):高 37→32px · 圆角 4→8px · 左内边距 12→10px ·
    //   ★ 宽度 320→320 逐字未变(`w-full` 两边都在,所以这一步【不】动版式宽度)。
    //   写法与同族的 `WasteClassPicker` 逐字相同 —— 它早就这么做了。
    className = `${CONTROL_SELECT} w-full`,
}: {
    name: string
    indices: MetalPriceIndex[]
    defaultValue: string | null
    locale: string
    allowUnstated?: boolean
    // 批量录入页要在换指数时重取参照价(拿 LME 的上一条比 SMM 的今天是错的)
    onChange?: (value: string) => void
    className?: string
}) {
    const t = useTranslations()
    return (
        <select
            name={name}
            defaultValue={defaultValue ?? INDEX_UNSTATED}
            onChange={onChange ? (e) => onChange(e.target.value) : undefined}
            className={className}
        >
            {indices.map((i) => (
                <option key={i.code} value={i.code}>
                    {locale === 'zh' ? i.name_zh : i.name_en}
                    {/* 报价币种没声明的指数【算不出钱】—— 选它之前就该看见这句,
                        而不是保存之后才被 INDEX_CURRENCY_NOT_STATED 拦下来。 */}
                    {i.quote_currency === null ? ` — ${t('metalPrices.index.currencyNotStated')}` : ''}
                </option>
            ))}
            {allowUnstated && (
                <option value={INDEX_UNSTATED}>{t('metalPrices.index.unstated')}</option>
            )}
        </select>
    )
}
