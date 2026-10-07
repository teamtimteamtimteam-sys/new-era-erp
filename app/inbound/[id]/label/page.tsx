// app/inbound/[id]/label/page.tsx
// MES-3b(2026-10-07,MES-3b Step 0 Q4 · Q6):进料批的打印页 —— 此前是一支一打开就打印、什么都不记的 GET 路由处理器。
//   门:requireModule(MOD.inbound);精确的那一道(这一批自己的查看码)在 label_print_context 里。版式与逻辑在 LabelPrintScreen。
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import LabelPrintScreen from '@/app/components/labels/LabelPrintScreen'

export default async function InboundLabelPage({ params, searchParams }: {
    params: Promise<{ id: string }>; searchParams: Promise<{ template?: string }>
}) {
    const denied = await requireModule(MOD.inbound)
    if (denied) return denied
    const { id } = await params
    const { template } = await searchParams
    return <LabelPrintScreen kind="inbound_batch" id={id} template={template} />
}
