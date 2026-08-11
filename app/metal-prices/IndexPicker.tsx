'use client'

// METAL-2:指数选择器。三处录入页与公式表单共用一个,免得四份下拉各自漂移。
//
// 【"未声明指数"是一个明写的选项,不是留空】见 indexOptions.ts 的说明:
// 尚未标注的公式只看得见未标注的行情,所以在公式被标注之前,操作员必须还能
// 往那条序列里录价 —— 但那必须是一次【选择】,不是"没选就是它"。
import { useTranslations } from '@/lib/i18n/client'
import { INDEX_UNSTATED, type MetalPriceIndex } from './indexOptions'

export default function IndexPicker({
    name,
    indices,
    defaultValue,
    locale,
    allowUnstated = true,
    onChange,
    className = 'w-full border border-gray-300 px-3 py-2 rounded',
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
