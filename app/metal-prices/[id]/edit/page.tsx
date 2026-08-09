import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditMetalPriceForm from './EditMetalPriceForm'
import DeleteButton from './DeleteButton'
import { getTranslations } from '@/lib/i18n/server'

export default async function EditMetalPricePage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // 【本页没有 requireModule,是有意的,不是漏了 —— 不要"补"回来】
    // metal_prices 的 SELECT 策略写的是 `USING (true)`(db/tables/metal_prices.sql):
    // 数据自己声明它是公开的。挂上 module.pricing.view 会让 UI 比数据库还严 ——
    // 对一个数据库愿意完整回答的人显示"你没有权限",而那道门数据库里根本不存在。
    // 【把关跟着数据自己的 RLS 走,不跟模块目录走】;完整理由在 lib/modules.ts
    // 的 /pricing 那一条(/pricing 本身仍然受管:公式与商务条款不是公开数据)。
    // 写入这一侧由 RLS 自己管:insert/update/delete 策略都是
    // `has_permission('module.pricing.edit')`,所以本页打得开、存不下 ——
    // 与 OPS-15 之前的行为一致(这四页在 OPS-15 之前本来就没有任何页面级把关)。

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: row, error } = await supabase
        .from('metal_prices')
        .select('id, metal, price_usd_per_tonne, price_date, notes')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !row) {
        notFound()
    }

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/metal-prices"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <div className="flex items-start justify-between mb-6">
                <h1 className="text-2xl font-bold">{t('metalPrices.editTitle')}</h1>
                <DeleteButton id={row.id} />
            </div>

            <EditMetalPriceForm row={row} />
        </div>
    )
}
