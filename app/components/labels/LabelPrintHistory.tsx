// app/components/labels/LabelPrintHistory.tsx
// MES-3b(2026-10-07,MES-3b Step 0 Q7,Tim):一样东西(进料批 · 产出批 · 库位)的标签印过几次 —— 画在它自己的页面上,
//   "印了 n 次 · 第一次 <日期> · 最近一次补印 <日期>:<理由>",旁边一个打印链接。
//   【谁印的】不在这一行里:页面最下面的审计记录里有(label_prints 挂在这一样东西的审计记录下,印 · 补印与理由)——
//   与 MES-3a 的滞留那一行同一个选法(MES-3a 交回 §6 决定 7),这里不另造一份人名解析。
//   服务端组件。读 label_prints 本身(读策略:那样东西自己的查看码)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { formatDate } from '@/lib/dates'

type PrintRow = { printed_at: string; is_reprint: boolean; reprint_reason: string | null; page_size: string; copies: number }

export default async function LabelPrintHistory({ kind, id, locale }: {
    kind: 'inbound_batch' | 'output_batch' | 'storage_location'
    id: string
    locale: string
}) {
    const t = await getTranslations()
    const supabase = await createClient()
    const col = kind === 'inbound_batch' ? 'inbound_batch_id' : kind === 'output_batch' ? 'output_batch_id' : 'storage_location_id'
    const href = kind === 'inbound_batch' ? `/inbound/${id}/label` : kind === 'output_batch' ? `/output/${id}/label` : `/inventory/locations/${id}/label`
    const rows = mustRows(await supabase.from('label_prints').select('printed_at, is_reprint, reprint_reason, page_size, copies')
        .eq(col, id).order('printed_at'), 'label_prints') as PrintRow[]
    const lastReprint = [...rows].reverse().find((r) => r.is_reprint)
    return (
        <p className="text-sm mb-4" data-label-prints={rows.length}>
            <span className="font-medium">{t('labels.history.title')}</span>{' · '}
            {rows.length === 0
                ? t('labels.history.never')
                : t('labels.history.printed', { n: String(rows.length), first: formatDate(rows[0].printed_at, locale) })}
            {lastReprint && (
                <>{' · '}{t('labels.history.lastReprint', { date: formatDate(lastReprint.printed_at, locale), reason: lastReprint.reprint_reason ?? '' })}</>
            )}
            {' · '}
            <a href={href} target="_blank" rel="noopener noreferrer" className="app-link hover:underline">
                {rows.length === 0 ? t('batchLabel.print') : t('labels.history.reprint')}
            </a>
        </p>
    )
}
