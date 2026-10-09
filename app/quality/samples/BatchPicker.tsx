// app/quality/samples/BatchPicker.tsx
// MES-6a-1:新建样品 / 新建争议的第一步 —— 选一批。普通的 GET 表单(?batch=inbound:<id> / output:<id>),
//   选定之后页面按那一批取它自己的清单(库位、销售单、抽检、化验单)。读不到某一侧批次的读者,那一侧说「受限」,不说"没有批次"。
import { CONTROL_SELECT } from '@/app/components/ui/control-style'
import { getTranslations } from '@/lib/i18n/server'
import { Button } from '@/app/components/ui/button'

export type BatchOption = { value: string; label: string }

export default async function BatchPicker({ action, inbound, output, inboundVisible, outputVisible }: {
    action: string
    inbound: BatchOption[]
    output: BatchOption[]
    inboundVisible: boolean
    outputVisible: boolean
}) {
    const t = await getTranslations()
    return (
        <form method="get" action={action} className="space-y-3 max-w-xl" data-form="batch-picker">
            <label className="block text-sm">
                <span className="block mb-1">{t('quality.form.batch')} <span className="text-red-600">*</span></span>
                <select name="batch" required defaultValue="" className={`${CONTROL_SELECT} w-full`}>
                    <option value="" disabled>{t('quality.form.pickBatch')}</option>
                    <optgroup label={t('quality.form.inboundBatches')}>
                        {inbound.map((b) => <option key={b.value} value={b.value}>{b.label}</option>)}
                    </optgroup>
                    <optgroup label={t('quality.form.outputBatches')}>
                        {output.map((b) => <option key={b.value} value={b.value}>{b.label}</option>)}
                    </optgroup>
                </select>
            </label>
            {(!inboundVisible || !outputVisible) && (
                <p className="text-xs text-amber-700">
                    {!inboundVisible && !outputVisible ? t('quality.form.batchesRestricted')
                        : !inboundVisible ? t('quality.form.inboundRestricted') : t('quality.form.outputRestricted')}
                </p>
            )}
            <Button type="submit">{t('quality.form.continue')}</Button>
        </form>
    )
}
