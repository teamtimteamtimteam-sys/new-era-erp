// app/quality/ncr/page.tsx
// MES-6b-1(2026-10-15,MES-0 Q65 · Q66;MES-6b Step 0 Q2 · Q7 · Q9,Tim):不合格报告清单 —— 开着的那几张(以及拒收而货还在的那几张)扣着它们那一批。
//   【门】requireFunction(FN.qualityNcr) = module.quality.view。开一张要 module.quality.edit —— 缺码时画真的 <Button disabled>,
//   由 PermissionGate 点名那个码(DBLOCK-1)。扣没扣着、处置、来源全部读 ncr_rows(holding 由库里的 ncr_holds 判),这里不判。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { ListPage } from '@/app/components/ui/list-page'
import { formatDate } from '@/lib/dates'
import { ncrStatusKey, ncrSourceKey, ncrDispositionKey, batchHref } from '../qualityTypes'
import NcrTable, { type NcrRow } from './NcrTable'

type Row = {
    id: string; code: string; status: string; source: string; batch_kind: string; inbound_batch_id: string | null
    output_batch_id: string | null; batch_code: string; description: string; disposition: string | null; opened_at: string; holding: boolean
}

export default async function NcrListPage() {
    const denied = await requireFunction(FN.qualityNcr)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const [res, canEdit] = await Promise.all([
        supabase.from('ncr_rows')
            .select('id, code, status, source, batch_kind, inbound_batch_id, output_batch_id, batch_code, description, disposition, opened_at, holding')
            .order('opened_at', { ascending: false }),
        can('module.quality.edit'),
    ])
    const ncrs = mustRows(res, 'ncr_rows') as Row[]
    // 开着的在前(扣着货的先看),其余按开单时刻倒序
    const sorted = [...ncrs].sort((a, b) => Number(b.status === 'open') - Number(a.status === 'open'))
    const rows: NcrRow[] = sorted.map((n) => ({
        id: n.id,
        code: n.code,
        statusLabel: n.status === 'open' ? t(ncrStatusKey('open')) : t(ncrDispositionKey(n.disposition ?? '')),
        open: n.status === 'open',
        holding: n.holding,
        sourceLabel: t(ncrSourceKey(n.source)),
        batchCode: n.batch_code,
        batchHref: batchHref(n.batch_kind, (n.inbound_batch_id ?? n.output_batch_id)!),
        opened: formatDate(n.opened_at, locale),
        description: n.description,
    }))

    return (
        <ListPage
            title={t('quality.ncr.title')}
            intro={t('quality.ncr.intro')}
            actions={
                canEdit ? (
                    <Button asChild><Link href="/quality/ncr/new">{t('quality.ncr.add')}</Link></Button>
                ) : (
                    <PermissionGate code="module.quality.edit" allowed={false} inline>
                        <Button disabled>{t('quality.ncr.add')}</Button>
                    </PermissionGate>
                )
            }
            state={{ kind: 'ok' }}
        >
            <NcrTable rows={rows} empty={t('quality.ncr.empty')} />
        </ListPage>
    )
}
