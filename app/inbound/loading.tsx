// app/inbound/loading.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-1 · 【本刀四页里,只有这一页拿到 loading.tsx —— 而那是判据,不是省事】
// ════════════════════════════════════════════════════════════════════════════
// Tim 的 Q5=B:只给【串行往返深度 ≥5】的 28 页建加载态,按量出来的深度选,
// 不按感觉。本刀四页逐个数过 page.tsx 里的 .from() 调用:
//     /inbound          10  ← 只有它够格
//     /finance/claims    3
//     /sales/commissions       1
//     /sales/quotes      1
// 【四页里只有一页有,这是对的结果,不是缺口】。在一个 1 次往返的页面上,
// 骨架屏一闪而过 —— 那不是反馈,那是闪烁。
//
// PAGE-0 §② 还给了一个独立的旁证:它数出的最深四页,正是冒烟量出的最慢五页里的四页
// ——【静态深度是一个站得住的代理指标】,所以后面几刀不必起服务器就能挑出该给谁加。
//
// 【骨架的版式来自 ListPageSkeleton,与真页面同一个文件】——
// 一个与真页面对不上的骨架,会在真页面出现的那一刻整页跳一下,比没有骨架更难受。
import { ListPageSkeleton } from '@/app/components/ui/list-page'

export default function Loading() {
    // 20 行 —— 与 INBOUND_PAGE_SIZE 同量级,让骨架的高度接近真页面的高度。
    return <ListPageSkeleton rows={12} />
}
