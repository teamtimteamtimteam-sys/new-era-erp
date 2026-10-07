'use client'

// MES-4b(2026-10-07,规格 §3.4;MES-4b Step 0 Q4,Tim):收货表单里的电芯结构 —— 可选,空 = 没记(之后在批次页上补)。
//   只对装着电芯的形态摆出来(判据与库里的守卫同一个:implies_dismantling;没有形态照常摆 —— 见 cellConstructionQuery.ts)。
//   提交的字段名是 cell_construction(两支收货动作读它;空就整个参数不传)。
import { CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useTranslations } from '@/lib/i18n/client'
import type { CellConstructionData } from './cellConstructionQuery'

export const FIELD_CELL_CONSTRUCTION = 'cell_construction'

export default function CellConstructionField({ data, materialId, locale }: {
    data: CellConstructionData
    materialId: string
    locale: string
}) {
    const t = useTranslations()
    if (!materialId || data.carries[materialId] === false) return null
    return (
        <div>
            <label className="block mb-1" htmlFor={FIELD_CELL_CONSTRUCTION}>{t('cellConstruction.label')}</label>
            <select id={FIELD_CELL_CONSTRUCTION} name={FIELD_CELL_CONSTRUCTION} defaultValue="" className={`${CONTROL_SELECT} w-full`}>
                <option value="">{t('cellConstruction.notRecorded')}</option>
                {data.options.map((o) => (
                    <option key={o.code} value={o.code}>{locale === 'zh' ? o.name_zh : o.name_en}</option>
                ))}
            </select>
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('cellConstruction.receiptHint')}</p>
        </div>
    )
}
