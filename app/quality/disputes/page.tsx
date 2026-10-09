// app/quality/disputes/page.tsx
// MES-6a-1(2026-10-09,MES-6a Step 0 Q16–Q23,Tim):化验争议清单 —— 开着的那几件挡着那一批的定价(进料)或结算(卖方)。
//   【门】requireFunction(FN.qualityDisputes) = module.quality.view。立争议要 module.quality.edit —— 缺码时画真的 <Button disabled>,
//   由 PermissionGate 点名那个码(DBLOCK-1)。最大差、容差、是否超出全部读 assay_dispute_rows,这里不算。
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
import { disputeStatusKey, resultPartyKey } from '../qualityTypes'
import DisputesTable, { type DisputeRow } from './DisputesTable'

type Row = {
    id: string; status: string; batch_code: string; our_assay_code: string; counterparty_assay_code: string; umpire_assay_code: string | null
    max_diff_pct: number | null; limit_pct_at: number | null; beyond_limit: boolean | null; governing_assay_code: string | null
    governing_party: string | null; created_at: string
}

export default async function DisputesPage() {
    const denied = await requireFunction(FN.qualityDisputes)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const [res, canEdit] = await Promise.all([
        supabase.from('assay_dispute_rows')
            .select('id, status, batch_code, our_assay_code, counterparty_assay_code, umpire_assay_code, max_diff_pct, limit_pct_at, beyond_limit, governing_assay_code, governing_party, created_at')
            .order('created_at', { ascending: false }),
        can('module.quality.edit'),
    ])
    const disputes = mustRows(res, 'assay_dispute_rows') as Row[]
    const rows: DisputeRow[] = disputes.map((d) => ({
        id: d.id,
        batchCode: d.batch_code,
        statusLabel: t(disputeStatusKey(d.status)),
        open: d.status === 'open',
        assays: [d.our_assay_code, d.counterparty_assay_code, d.umpire_assay_code].filter(Boolean).join(' · '),
        diff: d.max_diff_pct == null ? '—'
            : `${Number(d.max_diff_pct).toFixed(3)} · ${d.limit_pct_at == null ? t('quality.limitNotSet') : t('quality.disputes.limitOf', { limit: String(Number(d.limit_pct_at)) })}`,
        beyond: d.beyond_limit === true,
        governing: d.governing_assay_code ? `${d.governing_assay_code} · ${t(resultPartyKey(d.governing_party ?? ''))}` : '—',
        opened: formatDate(d.created_at, locale),
    }))

    return (
        <ListPage
            title={t('quality.disputes.title')}
            intro={t('quality.disputes.intro')}
            actions={
                canEdit ? (
                    <Button asChild><Link href="/quality/disputes/new">{t('quality.disputes.add')}</Link></Button>
                ) : (
                    <PermissionGate code="module.quality.edit" allowed={false} inline>
                        <Button disabled>{t('quality.disputes.add')}</Button>
                    </PermissionGate>
                )
            }
            state={{ kind: 'ok' }}
        >
            <DisputesTable rows={rows} empty={t('quality.disputes.empty')} />
        </ListPage>
    )
}
