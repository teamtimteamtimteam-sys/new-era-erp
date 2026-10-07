// app/inventory/scan/page.tsx
// MES-3b(2026-10-07,MES-0 §8.2 MES-3b 行 · Q28;MES-3b Step 0 Q20 · Q22,Tim):【扫码】—— 扫一批,看它在哪,把它搬去扫到的库位。
//   门:module.inventory.view(与库存一族同一道);搬要 module.inventory.edit(create_stock_transfer 自己查)。
//   扫码枪、手敲,以及(Android 上的 Chrome)摄像头 —— 都是 ScanField。
//   页面最下面:【你最近的扫码】(scan_events 里你自己的最近 20 行;Q20:扫码日志只画在这里)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { formatDateTime } from '@/lib/dates'
import ScanTransfer from './ScanTransfer'

type ScanRow = { id: number; scanned_at: string; context: string; method: string; raw_value: string; parsed_code: string | null;
    resolved_kind: string | null; outcome: string }

export default async function ScanPage() {
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    // 认证够不着与没登录不是一回事:够不着就抛(中间件已经保证走到这里的人登录过)
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError) throw new Error(`auth.getUser: ${authError.message}`)
    const [canMove, recent] = await Promise.all([
        can('module.inventory.edit'),
        user
            ? supabase.from('scan_events').select('id, scanned_at, context, method, raw_value, parsed_code, resolved_kind, outcome')
                .eq('scanned_by', user.id).order('id', { ascending: false }).limit(20)
            : Promise.resolve({ data: [], error: null }),
    ])
    const rows = mustRows(recent, 'scan_events') as ScanRow[]
    const outcomeText = (o: string) => o === 'found' ? t('scanPage.outcome.found') : o === 'restricted' ? t('scanPage.outcome.restricted')
        : o === 'unknown' ? t('scanPage.outcome.unknown') : t('scanPage.outcome.unreadable')

    return (
        <div className="p-4 sm:p-8">
            <div className="mb-6">
                <Link href="/inventory" className="hover:underline text-sm app-link">{t('common.back')}</Link>
            </div>
            <h1 className="mb-1">{t('scanPage.title')}</h1>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-6 max-w-2xl">{t('scanPage.intro')}</p>
            <ScanTransfer canMove={canMove} />
            <section className="mt-10 max-w-2xl" data-recent-scans={rows.length}>
                <h2 className="mb-2">{t('scanPage.recentTitle')}</h2>
                {rows.length === 0 ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">{t('scanPage.recentNone')}</p>
                ) : (
                    <ul className="text-sm space-y-1">
                        {rows.map((r) => (
                            <li key={r.id} className="break-words">
                                <span className="text-[color:var(--brand-muted-text)]">{formatDateTime(r.scanned_at, locale)}</span>{' · '}
                                <span className="font-mono">{r.parsed_code ?? r.raw_value}</span>{' · '}{outcomeText(r.outcome)}
                            </li>
                        ))}
                    </ul>
                )}
            </section>
        </div>
    )
}
