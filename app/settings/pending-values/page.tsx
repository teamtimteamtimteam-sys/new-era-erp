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
import { READ_ROW_LIMIT } from '@/lib/listSort'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import { xText } from '@/lib/export/cells'

type Pending = { value_code: string; item_id: string | null; item_code: string; item_label: string; href: string }

export default async function PendingValuesPage() {
    const denied = await requireFunction(FN.pendingValues)
    if (denied) return denied

    const t = await getTranslations()
    const supabase = await createClient()
    const rows = mustRows(
        await supabase.from('pending_values').select('value_code, item_id, item_code, item_label, href').order('value_code').order('item_code'),
        'pending_values') as Pending[]

    // TABLE-FEATURES-1(Tim 2026-10-25 Q9):每一节在浏览器里排。一次读取被切成好几节,每一节都到不了 1,000 行,
    //   于是 DataTable 自己那道「读满 1,000 行就关掉排序」的闸在这里看不见 —— 由页面按【整次读取】的行数来关。
    //   READ_ROW_LIMIT 住在 lib/listSort.ts(与 data-table.tsx 同一个数)。
    const sortable = rows.length < READ_ROW_LIMIT

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
                    // TABLE-EXPORT-1:两格都是字 —— 记录号与它的名字,与屏幕同一份
                    exports: { item: xText(r.item_code), label: xText(r.item_label) },
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
                            sorting={sortable ? 'client' : undefined}
                            exportSpec={{
                                // 一支值一张表 —— 文件名按值码分开(小写、连字符)
                                name: `settings-pending-values-${code.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`,
                                title: `${code} · ${t('pendingValues.value.' + code)}`,
                            }}
                        />
                    </section>
                )
            })}
        </ListPage>
    )
}
