// app/finance/packs/page.tsx
// GLEXPORT-1:月度管理报表包 —— 实时预览 + 已存档的那些。
//
// ★【一份存下来的包意味着一件事,而这句话印在读者遇到它的地方】★
//   它被产出的那一刻,那个月已经关账了。开放月份看得到预览、导得出 CSV,
//   但【不落库】。理由整段写在 db/tables/management_packs.sql 的表注释里。
//
// CONV-4:实时预览那份报告体(PackBody)是【透视/汇总】,不是逐行记录 ——
// 不套 DataTable,理由与 §⑧-3 的 ForecastGrid 同一条。已存档那张登记簿是
// 逐行记录,套 CONV-1 模板。state 恒为 'ok':这一页没有"整页无内容"这回事,
// 预览总是有得看,存档表的空态由 DataTable 自己说。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { mustRows } from '@/lib/db-helpers'
import PackBody, { type PackPayload } from './PackBody'
import { ProducePackControl, PackMonthPicker } from './PackControls'
import { ListPage } from '@/app/components/ui/list-page'
import PacksHistoryTable, { type PackRow } from './PacksHistoryTable'
import { Button } from '@/app/components/ui/button'

function monthOf(v: string | undefined): string {
    // 【只认 YYYY-MM;认不出就用上个月】上个月是"最可能已经关账"的那一个,
    // 而【本月】几乎必然还开着 —— 默认落在一个一按存档就被拒的月份上,
    // 是让人第一次用就撞墙。
    if (v && /^\d{4}-\d{2}$/.test(v)) return v
    const d = new Date()
    d.setDate(1); d.setMonth(d.getMonth() - 1)
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
}

export default async function PacksPage({
    searchParams,
}: { searchParams: Promise<{ month?: string }> }) {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const sp = await searchParams
    const month = monthOf(sp.month)
    const supabase = await createClient()
    const t = await getTranslations()

    const [packsRes, previewRes] = await Promise.all([
        supabase.from('management_packs')
            .select('id, code, period_month, produced_at, locked_before_at_production, superseded_at, superseded_by, superseded_reason')
            .order('period_month', { ascending: false }).order('produced_at', { ascending: false }),
        // 【预览与存档读的是同一支函数】—— 屏幕上看到的与冻下来的不可能是两个数。
        supabase.rpc('management_pack_data', { p_period_month: `${month}-01` }),
    ])
    const packs = mustRows(packsRes)
    // 【预览失败要说出来,不能读成一份空包】—— 一张空表与一张坏掉的页面
    // 在屏幕上是同一样东西(mustRows 的那条规矩,换个形状)。
    if (previewRes.error) {
        return (
            <div className="p-8 max-w-5xl">
                <h1 className="text-2xl font-bold mb-1">{t('pack.title')}</h1>
                <p className="text-sm text-gray-600 mb-4">{t('pack.subtitle')}</p>
                <p className="text-sm bg-red-50 border border-red-300 text-red-900 px-3 py-2 rounded">
                    {previewRes.error.message}
                </p>
            </div>
        )
    }
    const preview = previewRes.data as unknown as PackPayload
    const livePack = packs.find((p) => String(p.period_month).slice(0, 7) === month && !p.superseded_at)

    const packRows: PackRow[] = packs.map((p) => ({
        id: p.id as string,
        code: p.code as string,
        periodMonth: String(p.period_month).slice(0, 7),
        producedAt: String(p.produced_at).slice(0, 19).replace('T', ' '),
        lockedBeforeAt: String(p.locked_before_at_production),
        supersededAt: p.superseded_at as string | null,
        supersededReason: p.superseded_reason as string | null,
    }))

    return (
        <ListPage title={t('pack.title')} intro={t('pack.subtitle')} maxWidth="max-w-6xl" state={{ kind: 'ok' }}>
            {/* ── 实时预览 ────────────────────────────────────────────────── */}
            <div className="flex flex-wrap items-end gap-3 mb-4">
                <PackMonthPicker month={month} />
                <Button asChild variant="outline" size="sm" className="self-center">
                    <Link href={`/finance/journal/export?from=${preview.period_start}&to=${preview.period_end}`}>
                        {t('glExport.button')}
                    </Link>
                </Button>
            </div>
            <h2 className="font-semibold mb-2">
                {t('pack.previewFor', { month })}
                {!preview.month_locked && (
                    <span className="ml-2 text-xs font-normal bg-amber-100 text-amber-900 px-2 py-0.5 rounded">
                        {t('pack.cvMonthNotLocked')}
                    </span>
                )}
            </h2>
            <PackBody payload={preview} />

            <div className="mb-8">
                <ProducePackControl
                    month={month}
                    canProduce={preview.month_locked}
                    hasLive={Boolean(livePack)}
                />
            </div>

            {/* ── 已存档的包 ──────────────────────────────────────────────── */}
            <h2 className="font-semibold mb-1">{t('pack.storedHeading')}</h2>
            {/* ★ 这一句是这一整刀的裁定,印在读者遇到存档包的地方 ★ */}
            <p className="text-xs text-gray-600 mb-2 max-w-3xl">{t('pack.storedMeans')}</p>
            <PacksHistoryTable rows={packRows} empty={t('pack.noStored')} />
        </ListPage>
    )
}
