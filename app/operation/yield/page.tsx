// app/operation/yield/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-4(Tim 2026-10-29 第 9 条 · 2026-10-30 Q4 (a))· 得率并进了物料平衡页
// ════════════════════════════════════════════════════════════════════════════
// 这一页的内容搬到了 /operation/balance 的第二段(app/operation/balance/YieldSection.tsx)。地址留着(注册表里是平衡页的孩子,
// 搜索与旧链接照旧找得到它),带着它的两个筛选(month · group)跳过去,落在 #yield。
// 先过门再跳:一个进不去的人在这里拿到的是具名的拒绝,不是一次跳到另一张拒绝页的转向。
import { redirect } from 'next/navigation'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'

export default async function YieldPage({ searchParams }: { searchParams: Promise<{ month?: string; group?: string }> }) {
    const denied = await requireFunction(FN.yield)
    if (denied) return denied
    const sp = await searchParams
    const qs = new URLSearchParams()
    if (sp.month) qs.set('month', sp.month)
    if (sp.group) qs.set('group', sp.group)
    const q = qs.toString()
    redirect(`/operation/balance${q ? `?${q}` : ''}#yield`)
}
