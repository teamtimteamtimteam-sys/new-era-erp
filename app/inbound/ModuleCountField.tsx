'use client'

// MES-5a-1(2026-10-08,规格 §3.1;MES-5a Step 0 Q4,Tim):收货表单里的模组数 —— 可选,空 = 没记(之后在批次页上补;放电结果记下第一条之前必须有)。
//   只对装着电芯的形态摆出来(与电芯结构同一个判据,见 cellConstructionQuery.ts)。提交的字段名是 module_count(两支收货动作读它;空就整个参数不传)。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useTranslations } from '@/lib/i18n/client'
import type { CellConstructionData } from './cellConstructionQuery'

export const FIELD_MODULE_COUNT = 'module_count'

export default function ModuleCountField({ data, materialId }: { data: CellConstructionData; materialId: string }) {
    const t = useTranslations()
    if (!materialId || data.carries[materialId] === false) return null
    return (
        <div>
            <label className="block mb-1" htmlFor={FIELD_MODULE_COUNT}>{t('discharge.moduleCount')}</label>
            <input id={FIELD_MODULE_COUNT} name={FIELD_MODULE_COUNT} type="number" min="1" step="1" defaultValue="" className={`${CONTROL_INPUT} w-32`} />
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('discharge.receiptHint')}</p>
        </div>
    )
}
