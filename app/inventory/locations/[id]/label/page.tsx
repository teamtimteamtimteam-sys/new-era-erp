// app/inventory/locations/[id]/label/page.tsx
// MES-3b(2026-10-07,MES-3b Step 0 Q4):库位标签的打印页 —— 扫一个库位(转移的目的地、收货的库位)要先有一张印着它的标签。
//   门:requireModule(MOD.inventory)(库位的查看码,与库位编辑页同一道)。版式与逻辑在 LabelPrintScreen。
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import LabelPrintScreen from '@/app/components/labels/LabelPrintScreen'

export default async function LocationLabelPage({ params, searchParams }: {
    params: Promise<{ id: string }>; searchParams: Promise<{ template?: string }>
}) {
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied
    const { id } = await params
    const { template } = await searchParams
    return <LabelPrintScreen kind="storage_location" id={id} template={template} />
}
