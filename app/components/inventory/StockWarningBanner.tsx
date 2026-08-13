import { localizeStockWarnings, warnCodesFromParam } from './stockErrorCodes'

// IOD-2:落地告警的横幅。
//
// 【为什么是琥珀而不是红】红色说的是"这一次失败了,请重做";而告警的语义恰恰
// 相反 —— 货【已经收进去了】,只是有一个决定还没有人做过(库位没配 / 物料没分类)。
// 用红色会让操作员去重收一遍,那是这条路径上最贵的误解。
//
// 【为什么一句一行】两个告警可以同时出现,而它们指向两件要分别去做的事(配库位、
// 分物料)。拼成一段会让人只去做其中一件。
export default async function StockWarningBanner({ warn }: { warn?: string }) {
    const sentences = await localizeStockWarnings(warnCodesFromParam(warn))
    if (sentences.length === 0) return null

    return (
        <div className="bg-amber-50 border border-amber-400 text-amber-900 px-4 py-3 rounded mb-4 space-y-1">
            {sentences.map((s, i) => (
                <p key={i} className="text-sm">
                    {s}
                </p>
            ))}
        </div>
    )
}
