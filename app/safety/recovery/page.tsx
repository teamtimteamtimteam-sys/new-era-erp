// app/safety/recovery/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-4(Tim 2026-10-30 Q1,候选 2)· ESG › 回收(循环)—— 回收了多少、损在哪里
// ════════════════════════════════════════════════════════════════════════════
// 【全部从物料平衡来】processing_balance_monthly 的全厂那一份(scope = 'plant'),与 /operation/balance 读的是同一份,
//   一个字的算术都不在这里另写:每月的投入、按形态的产出(回收出来的东西)、按类别 × 来由的有名字损耗、余数。
//   回收率 = 产出 ÷ 投入,与平衡页恒等式里的那几条线同一组数(穿过去的质量 · 回滚的单 · 不是 kg 的单不在投入里,所以也不在这里)。
// 【三张表】① 每月一行:投入 · 回收的产出 · 回收率 · 有名字的损耗 · 余数 ② 回收的产出按形态 ③ 损耗按类别(损耗的去向)。
//   都在浏览器里排(一次读全体),都能导出。
// 【没有含金属量】Tim Q1 说的是"从物料平衡来";产出批的含金属量在别的表上、有自己的门,这一页不去拼它。
// 【门】注册表 /safety/recovery = 加工 · 财务 · 库存查看码任一 —— 平衡视图自己的门,一个字不多不少。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { fmtKg, fmtPct, num } from '@/lib/massFormat'
import { ListPage } from '@/app/components/ui/list-page'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import { labelMaps } from '@/app/operation/balance/labels'
import { xText, xNum } from '@/lib/export/cells'

type Line = { month: string; line: string; line_key: string | null; basis: string | null; qty: number | string | null }

export default async function RecoveryPage() {
    const denied = await requireFunction(FN.esgRecovery)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const [linesRes, labels] = await Promise.all([
        supabase.from('processing_balance_monthly').select('month, line, line_key, basis, qty')
            .eq('scope', 'plant').in('line', ['input', 'output', 'loss', 'remainder'])
            .order('month', { ascending: false }),
        labelMaps(supabase, locale, t),
    ])
    const lines = mustRows(linesRes, 'processing_balance_monthly') as unknown as Line[]
    const monthOf = (l: Line) => String(l.month).slice(0, 7)
    const months = [...new Set(lines.map(monthOf))]
    const sum = (m: string, line: string) => lines.filter((l) => monthOf(l) === m && l.line === line).reduce((s, l) => s + (num(l.qty) ?? 0), 0)
    const pct = (part: number, whole: number) => (whole > 0 ? (part / whole) * 100 : null)
    const pctCell = (v: number | null) => (v === null ? '—' : fmtPct(v))

    // ① 每月一行
    const monthRows: CellRow[] = months.map((m) => {
        const input = sum(m, 'input'), output = sum(m, 'output'), loss = sum(m, 'loss'), rem = sum(m, 'remainder')
        const rate = pct(output, input)
        return {
            id: m,
            cells: { month: m, input: fmtKg(input), output: fmtKg(output), rate: pctCell(rate), loss: fmtKg(loss), remainder: fmtKg(rem) },
            exports: { month: xText(m), input: xNum(input, 'qty'), output: xNum(output, 'qty'), rate: xNum(rate, 'pct'), loss: xNum(loss, 'qty'), remainder: xNum(rem, 'qty') },
        }
    })

    // ② 回收的产出按形态 ③ 损耗按类别 × 来由 —— 每一行另带"占当月投入的百分比"
    const shareRows = (line: 'output' | 'loss'): CellRow[] => lines.filter((l) => l.line === line).map((l) => {
        const m = monthOf(l)
        const qty = num(l.qty) ?? 0
        const share = pct(qty, sum(m, 'input'))
        const what = line === 'output' ? labels.form(l.line_key) : `${labels.loss(l.line_key)} · ${labels.basis(l.basis)}`
        return {
            id: `${m}|${l.line_key ?? ''}|${l.basis ?? ''}`,
            cells: { month: m, what, qty: fmtKg(qty), share: pctCell(share) },
            exports: { month: xText(m), what: xText(what), qty: xNum(qty, 'qty'), share: xNum(share, 'pct') },
        }
    })

    return (
        <ListPage title={t('esg.recovery.title')} intro={t('esg.recovery.intro')} maxWidth="max-w-6xl" state={{ kind: 'ok' }}>
            <p className="text-sm text-amber-800 mb-3">{t('massBalance.liveNote')}</p>
            <h2 className="mb-2">{t('esg.recovery.monthsTitle')}</h2>
            <CellsTable
                columns={[
                    { key: 'month', header: t('massBalance.month'), priority: true },
                    { key: 'input', header: t('massBalance.colInput'), align: 'right' },
                    { key: 'output', header: t('esg.recovery.colRecovered'), align: 'right' },
                    { key: 'rate', header: t('esg.recovery.colRate'), align: 'right', priority: true },
                    { key: 'loss', header: t('massBalance.colNamedLoss'), align: 'right' },
                    { key: 'remainder', header: t('massBalance.colRemainder'), align: 'right' },
                ]}
                rows={monthRows}
                empty={t('massBalance.noData')}
                sorting="client"
                exportSpec={{ name: 'esg-recovery-months', title: t('esg.recovery.monthsTitle') }}
            />

            <h2 className="mt-8 mb-2">{t('esg.recovery.formsTitle')}</h2>
            <CellsTable
                columns={[
                    { key: 'month', header: t('massBalance.month'), priority: true },
                    { key: 'what', header: t('esg.recovery.colForm'), priority: true },
                    { key: 'qty', header: t('massBalance.colQty'), align: 'right' },
                    { key: 'share', header: t('esg.recovery.colShare'), align: 'right', priority: true },
                ]}
                rows={shareRows('output')}
                empty={t('massBalance.noData')}
                sorting="client"
                exportSpec={{ name: 'esg-recovery-forms', title: t('esg.recovery.formsTitle') }}
            />

            <h2 className="mt-8 mb-2">{t('esg.recovery.lossTitle')}</h2>
            <CellsTable
                columns={[
                    { key: 'month', header: t('massBalance.month'), priority: true },
                    { key: 'what', header: t('esg.recovery.colLoss'), priority: true },
                    { key: 'qty', header: t('massBalance.colQty'), align: 'right' },
                    { key: 'share', header: t('esg.recovery.colShare'), align: 'right', priority: true },
                ]}
                rows={shareRows('loss')}
                empty={t('esg.recovery.noLoss')}
                sorting="client"
                exportSpec={{ name: 'esg-recovery-losses', title: t('esg.recovery.lossTitle') }}
            />
            <p className="text-sm text-[color:var(--brand-muted-text)] mt-4">{t('esg.recovery.basis')}</p>
        </ListPage>
    )
}
