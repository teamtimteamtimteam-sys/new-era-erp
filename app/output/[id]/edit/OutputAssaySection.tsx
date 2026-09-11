// app/output/[id]/edit/OutputAssaySection.tsx
// 产出批次页的化验区(服务端组件)。进料侧 AssaySection 是形状的出处;放在
// 金属含量面板旁边 —— 化验是含量的【出处】,不是另一件事。列表与徽标共用
// assay.* 的文案;链接指向产出侧的化验路由。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import OutputAssayRowsTable, { type OutputAssayRow } from './OutputAssayRowsTable'

// TABLE-CONVERT-5:表住进了 client 文件(Column.render 是函数,过不了那道边界)。
export type { OutputAssayRow } from './OutputAssayRowsTable'

export default async function OutputAssaySection({
    batchId,
    rows,
}: {
    batchId: string
    rows: OutputAssayRow[]
}) {
    const t = await getTranslations()

    // 已记录但未应用的化验:批次含量还停在此前的数上。这里没有价格问题
    // (产出批没有应付),但回收率与 metal_value 分摊读的都是批次含量 —— 要显眼。
    const unapplied = rows.filter((r) => r.applied_at === null)

    return (
        <section className="mt-8 pt-8 border-t">
            <div className="flex justify-between items-center mb-4">
                <h2 className="">{t('assay.title')}</h2>
                <Button asChild>
                    <Link href={`/output/${batchId}/assays/new`}>{t('assay.new')}</Link>
                </Button>
            </div>

            {unapplied.length > 0 && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm">
                    {t('assay.output.unappliedWarning', { code: unapplied.map((r) => r.code).join(', ') })}
                </div>
            )}

            {/* TABLE-CONVERT-5:空态搬进了 DataTable 的 empty prop(同一个 assay.empty)。
                旧那一支不留 —— 留着 prop 就永远到不了(TABLE-CONVERT-3 §6.1)。 */}
            <OutputAssayRowsTable batchId={batchId} rows={rows} />
        </section>
    )
}
