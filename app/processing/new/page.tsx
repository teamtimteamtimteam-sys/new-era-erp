// app/processing/new/page.tsx
// 服务端组件:抓取可选投料批次 + 物料列表,渲染客户端表单
import { createClient } from '@/lib/supabase/server'
import NewProcessingForm, { type InboundBatchOption } from './NewProcessingForm'
import { getTranslations } from '@/lib/i18n/server'

export default async function NewProcessingPage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const [batchesRes, materialsRes] = await Promise.all([
        supabase
            .from('inbound_batches')
            .select('id, code, remaining_qty, unit, materials ( name )')
            .is('deleted_at', null)
            .gt('remaining_qty', 0) // 只看还有库存的批次
            .order('code'),
        supabase
            .from('materials')
            .select('id, code, name')
            .is('deleted_at', null)
            .order('name'),
    ])

    if (batchesRes.error || materialsRes.error) {
        const err = batchesRes.error ?? materialsRes.error
        return (
            <div className="p-8 max-w-2xl">
                <h1 className="text-2xl font-bold mb-4">{t('processing.newTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('processing.dropdownLoadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <NewProcessingForm
            inboundBatches={(batchesRes.data as unknown as InboundBatchOption[] | null) ?? []}
            materials={materialsRes.data ?? []}
        />
    )
}
