// app/settings/pending-values/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-1(2026-10-06,MES-0 §5 · Q92;MES-1 Step 0 Q1 · Q2,Tim)· 还没给的标准值
// ════════════════════════════════════════════════════════════════════════════
// 【这一页是什么】工厂还欠这套系统的每一个数:心跳间隔、班次时刻……一行是一件具体还空着的事 —— 哪一个值、空在哪一条记录上、
//   谁来给、去哪儿填。给了,那一行就自己消失(pending_values 是一张视图,不存东西)。
// 【一支一个值,每一支带它自己的码】读者只看得到他持码的那几支。MES-1 播两支(V5 网关心跳间隔 · V6 班次时刻),
//   之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行(Q2)。
// 【门】requireFunction(FN.pendingValues)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'

type Pending = { value_code: string; item_id: string | null; item_code: string; item_label: string; href: string }

export default async function PendingValuesPage() {
    const denied = await requireFunction(FN.pendingValues)
    if (denied) return denied

    const t = await getTranslations()
    const supabase = await createClient()
    const rows = mustRows(
        await supabase.from('pending_values').select('value_code, item_id, item_code, item_label, href').order('value_code').order('item_code'),
        'pending_values') as Pending[]

    const groups = new Map<string, Pending[]>()
    for (const r of rows) groups.set(r.value_code, [...(groups.get(r.value_code) ?? []), r])

    return (
        <ListPage
            title={t('pendingValues.title')}
            intro={t('pendingValues.intro')}
            maxWidth="max-w-5xl"
            state={rows.length ? { kind: 'ok' } : { kind: 'empty', noRows: t('pendingValues.none') }}
        >
            {[...groups.entries()].map(([code, items]) => {
                const tableRows: CellRow[] = items.map((r, i) => ({
                    id: `${code}-${r.item_code}-${i}`,
                    cells: {
                        item: <Link href={r.href} className="app-link hover:underline">{r.item_code}</Link>,
                        label: r.item_label,
                    },
                }))
                return (
                    <section key={code} className="mb-8" data-pending-value={code}>
                        <h2 className="mb-1">{`${code} · ${t('pendingValues.value.' + code)}`}</h2>
                        <p className="mb-2 text-sm text-[color:var(--brand-muted-text)]">{t('pendingValues.supplier.' + code)}</p>
                        <CellsTable
                            columns={[{ key: 'item', header: t('pendingValues.colWhere'), priority: true },
                                      { key: 'label', header: t('pendingValues.colName'), priority: true }]}
                            rows={tableRows}
                            empty="—"
                        />
                    </section>
                )
            })}
        </ListPage>
    )
}
