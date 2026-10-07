// app/components/scan/ShortLinkScreen.tsx
// MES-3b(2026-10-07,MES-0 Q29;MES-3b Step 0 Q9,Tim):标签二维码里的短链接 —— /b/<批号> 与 /loc/<库位号> 共用的服务端壳。
//   四种结果(Q9):
//     没登录     → 中间件先把人送去 /login?next=/b/<批号>,登录之后回到这里(这两条路由【不在】PUBLIC_PATHS 里 —— 不是公开页);
//     看得见     → 直接跳到那一批 / 那个库位的页面;
//     看不见     → 一页拒绝:说出这个编号是什么、要哪个码、由管理员给 —— 别的一个字都不说(没有物料、没有数量、没有 id);
//     没这个编号 → 说"没有一批 / 一个库位叫这个"。
//   认身份只问 resolve_scan_code(方式记 link —— 有人打开了一张标签上的链接),页面自己不判断。
//   已经印出去的旧标签(二维码是 /inbound/<id>/edit)不经过这里,照旧直接打开那一页。
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { RefusalPage } from '@/app/components/ui/refusal'
import type { ScanResult } from './actions'

// 路由参数可能已经解码过,也可能没有;一个带着孤零零 % 的编号解码会抛 —— 那时原样用
function safeDecode(s: string): string {
    try { return decodeURIComponent(s) } catch { return s }
}

export default async function ShortLinkScreen({ prefix, code: raw }: { prefix: 'b' | 'loc'; code: string }) {
    const code = safeDecode(raw)
    const t = await getTranslations()
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('resolve_scan_code', {
        p_value: `/${prefix}/${encodeURIComponent(code)}`, p_context: 'lookup', p_method: 'link',
    })
    if (error) throw new Error(`resolve_scan_code: ${error.message}`)
    const r = data as unknown as ScanResult
    if (r.outcome === 'signed_out') redirect(`/login?next=${encodeURIComponent(`/${prefix}/${code}`)}`)
    if (r.outcome === 'found' && r.id) {
        redirect(r.kind === 'inbound_batch' ? `/inbound/${r.id}/edit`
            : r.kind === 'output_batch' ? `/output/${r.id}/edit` : `/inventory/locations/${r.id}/edit`)
    }
    const kind = r.kind === 'inbound_batch' ? t('scan.kind.inboundBatch') : r.kind === 'output_batch' ? t('scan.kind.outputBatch')
        : t('scan.kind.location')
    if (r.outcome === 'restricted') {
        return (
            <div data-short-link="restricted">
                <RefusalPage title={r.code ?? code}
                             statement={t('scan.link.restricted', { code: r.code ?? code, kind, needs: r.needs ?? '' })}
                             hint={t('scan.link.restrictedHint')} backHomeLabel={t('common.backHome')} />
            </div>
        )
    }
    return (
        <div data-short-link="unknown">
            <RefusalPage title={code}
                         statement={prefix === 'b' ? t('scan.link.unknownBatch', { code }) : t('scan.link.unknownLocation', { code })}
                         hint={t('scan.link.unknownHint')} backHomeLabel={t('common.backHome')} />
        </div>
    )
}
