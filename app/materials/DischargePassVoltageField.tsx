'use client'

// MES-5a-1(2026-10-08,规格 §3.1;MES-5a Step 0 Q8,Tim):V9 —— 这种物料的模组放电到多少伏以下算"放完了"(按物料,因为模组的终止电压取决于串数)。
//   它【不判】,只把与之矛盾的结论标出来:判通过而出口电压高于它、或判失败而不高于它。空 = 判不了(不是"都对")。
//   字段名 discharge_pass_voltage_v(新建与编辑两支动作读它;空 = NULL)。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useTranslations } from '@/lib/i18n/client'

export const FIELD_DISCHARGE_PASS_V = 'discharge_pass_voltage_v'

export default function DischargePassVoltageField({ defaultValue, error }: { defaultValue: number | null; error?: string }) {
    const t = useTranslations()
    return (
        <div>
            <label className="block mb-1" htmlFor={FIELD_DISCHARGE_PASS_V}>{t('materials.form.dischargePassV')}</label>
            <input id={FIELD_DISCHARGE_PASS_V} name={FIELD_DISCHARGE_PASS_V} type="number" step="any" min="0"
                   defaultValue={defaultValue ?? ''} className={`${CONTROL_INPUT} w-full`} />
            {error && <p className="text-red-600 text-xs mt-1">{error}</p>}
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('materials.form.dischargePassVHint')}</p>
        </div>
    )
}
