'use client'

// app/components/quality/SamplePickerField.tsx
// MES-6a-1(MES-6a Step 0 Q9):化验表单上"这份结果化验的是哪份样品"—— 可空;选单只列这一批的样品(sample_rows,页面读好传进来)。
//   样品必须是同一批的:服务端按名拒(SAMPLE_NOT_FOR_BATCH),这里只是不把别的批的样品放进选单。sample_ref(实验室那一侧的编号)照旧。
import { CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useTranslations } from '@/lib/i18n/client'

export type SampleOption = { id: string; label: string }

export default function SamplePickerField({ options, defaultSampleId }: { options: SampleOption[]; defaultSampleId?: string | null }) {
    const t = useTranslations()
    return (
        <div className="flex-1 min-w-[12rem]">
            <label className="block mb-1">{t('quality.assaySample.label')}</label>
            <select name="sample_id" defaultValue={defaultSampleId && options.some((o) => o.id === defaultSampleId) ? defaultSampleId : ''}
                    className={`${CONTROL_SELECT} w-full`} data-field="sample_id">
                <option value="">{t('quality.assaySample.none')}</option>
                {options.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
            </select>
        </div>
    )
}
