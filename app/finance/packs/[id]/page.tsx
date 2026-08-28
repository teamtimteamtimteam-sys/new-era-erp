// app/finance/packs/[id]/page.tsx
// GLEXPORT-1:读一份【已存档】的包。正文与实时预览共用 PackBody ——
// 一份渲染两个调用方,于是同一份 payload 不会在两块屏幕上说出两句话。
//
// 【它读的是冻下来的 payload,不是现算】这正是存档的全部意义:
// 底下的账再动,这一份也不动(与 gst_return_boxes / customer_statements 同一条)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import Subnav from '../../Subnav'
import PackBody, { type PackPayload } from '../PackBody'

export default async function PackDetailPage({
    params,
}: { params: Promise<{ id: string }> }) {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data, error } = await supabase.from('management_packs')
        .select('id, code, period_month, period_end, produced_at, locked_before_at_production, payload, notes, superseded_at, superseded_reason')
        .eq('id', id).single()
    // 【读不到就是 404,而读【失败】要报错】RLS 挡下来时是后者 ——
    // 把它读成"没有这一份"会把一个权限答案说成一个不存在的答案。
    if (error && error.code !== 'PGRST116') {
        return (
            <div className="p-8 max-w-5xl">
                <Subnav />
                <p className="text-sm bg-red-50 border border-red-300 text-red-900 px-3 py-2 rounded">{error.message}</p>
            </div>
        )
    }
    if (!data) notFound()

    const payload = data.payload as unknown as PackPayload

    return (
        <div className="p-8 max-w-6xl">
            <h1 className="text-2xl font-bold mb-1">
                <span className="font-mono">{data.code}</span>
            </h1>
            <p className="text-sm text-gray-600 mb-4">{t('pack.subtitle')}</p>
            <Subnav />

            {/* ★ 一份存档的包意味着什么 —— 印在读者拿着它的这一屏上 ★ */}
            <p className="text-sm mb-4 bg-green-50 border border-green-300 text-green-900 px-3 py-2 rounded max-w-3xl">
                {t('pack.storedMeans')}
                <br />
                <span className="font-mono text-xs">
                    {t('pack.colLockedBefore')}: {String(data.locked_before_at_production)} ·{' '}
                    {t('pack.colProduced')}: {String(data.produced_at).slice(0, 19).replace('T', ' ')}
                </span>
            </p>
            {data.superseded_at && (
                <p className="text-sm mb-4 bg-amber-50 border border-amber-300 text-amber-900 px-3 py-2 rounded">
                    {t('pack.statusSuperseded')} — {data.superseded_reason as string}
                </p>
            )}

            <div className="mb-4 flex gap-4">
                <Link href={`/finance/packs/${data.id}/export`} className="text-sm text-blue-600 hover:underline">
                    {t('pack.exportCsv')}
                </Link>
                <Link href={`/finance/journal/export?from=${payload.period_start}&to=${payload.period_end}`}
                      className="text-sm text-blue-600 hover:underline">
                    {t('glExport.button')}
                </Link>
            </div>

            <PackBody payload={payload} />
        </div>
    )
}
