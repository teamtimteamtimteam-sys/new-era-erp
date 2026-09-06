// RPT-1:分类违规报表。三段,而【只有第一段是违规】。
//
// CONV-5:三段都是真正的行登记簿,三张表都换(违规段一张 + 未决定段那个
// 复用组件一张)。★ state 恒为 'ok' —— 计数与那句 countNote(「未决定的两段
// 永远不进这个数」)必须无条件出现,走 empty 分支会把这条判据一起吞掉;
// 而 CSV/PDF 两个出口住在 actions 里,画在状态分支之前。
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { fetchViolations, type UndecidedRow } from './violationsQuery'
import { ListPage } from '@/app/components/ui/list-page'
import { ViolationsTable, UndecidedTable, type ViolationRow, type UndecidedTableRow } from './ViolationsTables'
import { Button } from '@/app/components/ui/button'

function Undecided({ title, note, colA, colB, rows, qtyLabel }: {
    title: string; note: string; colA: string; colB: string; rows: UndecidedRow[]; qtyLabel: string
}) {
    // 一段没有行就整段不出现 —— 这不是"空态",是"这一段不适用"。
    if (rows.length === 0) return null
    const tableRows: UndecidedTableRow[] = rows.map((r, i) => ({
        key: String(i), code: r.code, name: r.name, other: r.other, qty: `${r.qty} ${r.unit}`,
    }))
    return (
        <section className="mb-8">
            <h2 className="font-medium mb-1">{title}</h2>
            <p className="text-xs text-gray-500 mb-2">{note}</p>
            <UndecidedTable rows={tableRows} colA={colA} colB={colB} qtyLabel={qtyLabel} />
        </section>
    )
}

export default async function ViolationsPage() {
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied
    const t = await getTranslations()
    const { violations, unconfigured, unclassified } = await fetchViolations()

    const violationRows: ViolationRow[] = violations.map((v, i) => ({
        key: String(i),
        locationCode: v.location_code,
        materialCode: v.material_code,
        classCode: v.class_code,
        qty: String(v.qty),
    }))

    return (
        <ListPage
            title={t('reports.violations.title')}
            intro={t('reports.violations.desc')}
            actions={
                <div className="flex gap-2 shrink-0">
                    <Button asChild variant="outline" size="sm">
                        <a href="/inventory/reports/violations/export">{t('reports.csv')}</a>
                    </Button>
                    <Button asChild variant="outline" size="sm">
                        <a href="/inventory/reports/violations/pdf" target="_blank" rel="noopener noreferrer">{t('reports.pdf')}</a>
                    </Button>
                </div>
            }
            state={{ kind: 'ok' }}
        >
            {/* 【计数只数违规】—— 未决定的两段永远不进这个数 */}
            <p className="text-sm mb-1">
                {t('reports.violations.count', { n: String(violations.length) })}
            </p>
            <p className="text-xs text-gray-500 mb-6">{t('reports.violations.countNote')}</p>

            <section className="mb-8">
                <h2 className="font-medium mb-2">{t('reports.violations.sectionViolations')}</h2>
                <ViolationsTable rows={violationRows} empty={t('reports.violations.none')} />
            </section>

            <Undecided title={t('reports.violations.sectionUnconfigured')}
                       note={t('reports.violations.unconfiguredNote')}
                       colA={t('reports.colLocation')} colB={t('reports.colMaterial')}
                       qtyLabel={t('reports.colQty')} rows={unconfigured} />
            <Undecided title={t('reports.violations.sectionUnclassified')}
                       note={t('reports.violations.unclassifiedNote')}
                       colA={t('reports.colMaterial')} colB={t('reports.colLocation')}
                       qtyLabel={t('reports.colQty')} rows={unclassified} />
        </ListPage>
    )
}
