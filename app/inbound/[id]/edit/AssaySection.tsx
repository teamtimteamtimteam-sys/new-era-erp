// app/inbound/[id]/edit/AssaySection.tsx
// 批次页的化验区(服务端组件 —— 只有列表与链接,不需要客户端状态)。
// 位置在"金属含量"与"计价"之间:含量从哪来 → 化验 → 价格往哪去,读下来是一条线。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { metalLabelKey } from '@/app/tools/pricing/metal-prices/options'
import AssayRowsTable, { type AssayRow } from './AssayRowsTable'

// TABLE-CONVERT-5:行的形状跟着表走了(Column.render 是函数,过不了 server→client
// 那道边界,所以表住在 client 文件里)。这里原样再导出,页面那侧的 import 不用动。
export type { AssayRow } from './AssayRowsTable'

export default async function AssaySection({
    batchId,
    rows,
    // ASY-P2:这个批次的物料【声明了】要验哪些金属、其中哪几种还没被覆盖。
    // null = 这个物料没有声明任何化验要求(那不是"缺 0 种",是根本没有这条政策);
    // [] = 声明了、而且全验齐了。三种状态各说各的话 —— 见下面。
    missingMetals,
    hasRequirement,
    sampleable,
}: {
    batchId: string
    rows: AssayRow[]
    missingMetals: string[]
    hasRequirement: boolean
    sampleable: boolean
}) {
    const t = await getTranslations()

    // 已记录但未应用的化验:价格还停在此前的含量上 —— 这是钱没算对,要显眼
    const unapplied = rows.filter((r) => r.applied_at === null)

    return (
        <section className="mt-8 pt-8 border-t">
            <div className="flex justify-between items-center mb-4">
                <h2 className="text-xl font-bold">{t('assay.title')}</h2>
                <Button asChild>
                    <Link href={`/inbound/${batchId}/assays/new`}>{t('assay.new')}</Link>
                </Button>
            </div>

            {/* ── ASY-P2:化验要求的现状,三种状态各说各的话 ────────────────────
                这一块【永远画出来】,包括"没有要求"那一种:一块什么都不显示的区域,
                与"这个物料不需要化验"在屏幕上长得一模一样,而后者是一个决定。
                这也是首页那一支点名的同一件事 —— 补救就发生在这张页面上,
                所以两处必须说同一句话。 */}
            {!hasRequirement ? (
                <p className="text-sm text-gray-500 mb-4">
                    {t('assay.policy.noRequirement')}
                </p>
            ) : missingMetals.length === 0 ? (
                <p className="text-sm text-green-700 mb-4">{t('assay.policy.allCovered')}</p>
            ) : (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm">
                    <p>
                        {t('assay.policy.missing', {
                            metals: missingMetals
                                .map((c) => (metalLabelKey(c) ? t('metals.' + c) : c))
                                .join(', '),
                        })}
                    </p>
                    {/* 【取不到样就说出来,而不是让人白跑一趟】料耗尽的批次按设计
                        不上首页那一支(灯灭不掉),但缺口仍然是事实 —— 这张页面
                        是唯一还会说出它的地方。 */}
                    {!sampleable && (
                        <p className="text-xs mt-1">{t('assay.policy.notSampleable')}</p>
                    )}
                </div>
            )}

            {unapplied.length > 0 && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm">
                    {t('assay.unappliedWarning', { code: unapplied.map((r) => r.code).join(', ') })}
                </div>
            )}

            {/* TABLE-CONVERT-5:空态搬进了 DataTable 的 empty prop(同一个 assay.empty),
                所以这里【没有】三元 —— 旧那一支不留,不然 prop 永远到不了。 */}
            <AssayRowsTable batchId={batchId} rows={rows} />
        </section>
    )
}
