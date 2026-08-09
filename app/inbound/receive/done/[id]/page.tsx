// app/inbound/receive/done/[id]/page.tsx
// 收货成功确认页(移动端):批次编号大字 + 打印标签 / 继续收货。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type Batch = {
    id: string
    code: string
    quantity: number
    unit: string
    materials: { name: string } | null
}

export default async function ReceiveDonePage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.inbound)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data, error } = await supabase
        .from('inbound_batches')
        .select('id, code, quantity, unit, materials ( name )')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !data) {
        notFound()
    }

    const batch = data as unknown as Batch

    return (
        <div className="p-4 max-w-md mx-auto text-center">
            <div className="mt-6 mb-4 text-5xl text-green-600">✓</div>
            <h1 className="text-2xl font-bold text-green-700 mb-6">{t('receive.doneTitle')}</h1>

            <div className="font-mono text-3xl font-extrabold break-all mb-3">{batch.code}</div>
            <p className="text-gray-600 mb-8">
                {batch.materials?.name ?? '—'} · {batch.quantity} {batch.unit}
            </p>

            <div className="space-y-3">
                <a
                    href={`/inbound/${batch.id}/label`}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="block w-full bg-blue-600 text-white text-base font-medium rounded px-4 py-3 min-h-[48px] hover:bg-blue-700"
                >
                    {t('batchLabel.print')}
                </a>
                <Link
                    href="/inbound/receive"
                    className="block w-full border border-gray-300 text-base font-medium rounded px-4 py-3 min-h-[48px] hover:bg-gray-50"
                >
                    {t('receive.next')}
                </Link>
            </div>

            <div className="mt-6">
                <Link href={`/inbound/${batch.id}/edit`} className="text-blue-600 hover:underline text-sm">
                    {t('receive.viewBatch')}
                </Link>
            </div>
        </div>
    )
}
