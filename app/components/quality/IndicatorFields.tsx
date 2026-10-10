'use client'

// MES-6a-2(2026-10-10,MES-6a Step 0 Q3 · Q4,Tim):化验表单上的指标 —— 残粉、箔纯度、粒径 D10 / D50 / D90。
//   两张化验表单(进料 / 产出)共用这一份。一个指标一格,可空(空 = 这一份没报);值 ≥ 0、没有上限(Q3:没有限)。
//   名字与单位是字典自己的(页面按读者语言翻好传进来);只给还能新选的(停用的不在表单上,D5)。
//   每一格的 name 是 indicator:<码> —— 服务端(indicatorPayload.ts)按这个前缀收,record_assay_result 再按名拒一次。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useTranslations } from '@/lib/i18n/client'

export type IndicatorOption = { code: string; label: string; unit: string }

export default function IndicatorFields({ options }: { options: IndicatorOption[] }) {
    const t = useTranslations()
    if (options.length === 0) return null
    return (
        <fieldset className="min-w-0" data-panel="indicator-fields">
            <legend className="mb-1">{t('assay.indicators.title')}</legend>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('assay.indicators.formHint')}</p>
            <div className="flex flex-wrap gap-4">
                {options.map((o) => (
                    <label key={o.code} className="block w-40 max-w-full">
                        <span className="block mb-1 text-sm">{o.label} ({o.unit})</span>
                        <input type="number" name={`indicator:${o.code}`} step="any" min="0" inputMode="decimal"
                               className={`${CONTROL_INPUT} w-full`} />
                    </label>
                ))}
            </div>
        </fieldset>
    )
}
