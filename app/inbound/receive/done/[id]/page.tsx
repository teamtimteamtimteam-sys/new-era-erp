// app/inbound/receive/done/[id]/page.tsx
// 收货成功确认页(移动端):批次编号大字 + 打印标签 / 继续收货。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★ CONV-9(2026-09-04):**这一页【刻意】没有套 ListPage 外壳** ★★
// ════════════════════════════════════════════════════════════════════════════
// 【它不是一张详情页,它是一屏回执】37 张 `[param]` 路由里,它和
// /hr/claims/[id] 是仅有的两张【一张表都没有】的;而这一张更进一步 ——
// 它连"一条记录 + 它的子表"这个形状都不是:
//
//   * 版式是 `p-4 max-w-md mx-auto text-center` —— **居中、窄栏、专为手机**;
//     而 ListPage 的容器是左对齐的,它的 <h1> 住在一个
//     `flex items-baseline justify-between` 里(标题在左、动作在右)。
//   * 这一屏的"标题"是一个绿色的 ✓ 加一句成功,而【记录的身份】是它下面那个
//     `text-3xl font-extrabold` 的批次号 —— 那是给仓库里的人隔着一臂读的。
//     把它塞进 ListPage 的 title 槽会把这两样东西的主次颠倒过来。
//   * 两个动作是 `min-h-[48px]` 的整宽按钮(拇指够得着),不是标题右边的小链接。
//
// **也就是说:全仓 37 张详情页里,唯一一张【本来就是照 390px 设计的】,
//   正是套上这套外壳会被弄坏的那一张。** 硬套会在这一刀里制造出这一刀要修的病。
//
// 【这不是"漏转",是同一条判据的又一次应用】CONV-3 §⑧-3 拒绝把透视表塞进
// DataTable、CONV-4 §⑨-1 让 7 张页面只套外壳、CONV-5 让 /hr/reviews/cycles
// 只套外壳 —— **没有形状匹配就不硬套**。这里被拒绝的是【外壳】那一半,
// 而不是表那一半,所以它是这条判据的一个新形状,记在这里。
//
// ☞ 后来的人:要改这个决定,先回答一句 —— **改完之后,它在 390px 上还读得成
//   一屏回执吗?** 那才是这一页存在的理由,不是"和别的页长得一样"。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import StockWarningBanner from '@/app/components/inventory/StockWarningBanner'

type Batch = {
    id: string
    code: string
    quantity: number
    unit: string
    materials: { name: string } | null
}

export default async function ReceiveDonePage({
    params,
    searchParams,
}: {
    params: Promise<{ id: string }>
    // 本版本 Next 里 searchParams 是 Promise,需要 await
    searchParams: Promise<{ warn?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.inbound)
    if (denied) return denied

    const { id } = await params
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const { data, error } = await supabase
        .from('inbound_batches')
        .select('id, code, quantity, unit, materials ( name )')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !data) {
        notFound()
    }

    const batch = data as unknown as Batch

    return (
        <div className="p-4 max-w-md mx-auto text-center">
            <div className="mt-6 mb-4 text-5xl text-green-600">✓</div>
            <h1 className="text-2xl font-bold text-green-700 mb-6">{t('receive.doneTitle')}</h1>

            <div className="font-mono text-3xl font-extrabold break-all mb-3">{batch.code}</div>
            <p className="text-gray-600 mb-8">
                {batch.materials?.name ?? '—'} · {batch.quantity} {batch.unit}
            </p>

            {/* IOD-2:落地告警。【放在成功之后、按钮之前】—— 收货确实成功了(绿勾
                不撤),但如果有决定没人做过,这是操作员唯一会看见它的一屏。
                靠左读:告警是句子,不是标题。 */}
            <div className="text-left">
                <StockWarningBanner warn={sp.warn} />
            </div>

            <div className="space-y-3">
                <Button asChild variant="default" size="lg" className="w-full min-h-[48px] text-base">
                    <a href={`/inbound/${batch.id}/label`} target="_blank" rel="noopener noreferrer">{t('batchLabel.print')}</a>
                </Button>
                <Button asChild variant="secondary" size="lg" className="w-full min-h-[48px] text-base">
                    <Link href="/inbound/receive">{t('receive.next')}</Link>
                </Button>
            </div>

            <div className="mt-6">
                <Link href={`/inbound/${batch.id}/edit`} className="text-blue-600 hover:underline text-sm">
                    {t('receive.viewBatch')}
                </Link>
            </div>
        </div>
    )
}
