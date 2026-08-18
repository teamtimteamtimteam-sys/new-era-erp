import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditMetalPriceForm from './EditMetalPriceForm'
import DeleteButton from './DeleteButton'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireEditPermission } from '@/app/components/moduleGuard'
import { getMetalPriceIndices } from '../../indexQuery'

export default async function EditMetalPricePage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // 【本页把关用 module.pricing.edit,不是 module.pricing.view。这是那条规矩的「写」那一半】
    // 规矩只有一条:【守卫跟着数据自己的 RLS 走,不跟模块目录走】。
    // 而一张表的 RLS 本来就有读、写两个答案,metal_prices 的这两个答案【不一样】——
    // 所以 app/metal-prices/ 底下四页带着两种守卫,那是【同一条规则的两半,不是例外】:
    //
    //   读(列表页 /metal-prices)  SELECT ... USING (true)
    //                             → 不设守卫
    //   写(new / bulk / [id]/edit) INSERT|UPDATE|DELETE ... has_permission('module.pricing.edit')
    //                             → requireEditPermission('module.pricing.edit', ...)
    //
    // (策略原文见 db/tables/metal_prices.sql;完整理由见 lib/modules.ts 的 /pricing 那一条。)
    //
    // 改行情不是人人可以,而本页【只做】这件事。用 module.pricing.view 把关会同时错两头:
    // 挡下有 edit 而无 view 的人,又放进有 view 而无 edit 的人 —— 让后者填完整张表单,
    // 再被数据库以 42501 拒收。不设守卫则只错后一头。边界仍然是那几条 WITH CHECK 策略;
    // 这里只是不要把一张注定被拒收的表单摆到人面前。

    const denied = await requireEditPermission('module.pricing.edit', 'nav.metalPrices')
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    // METAL-2:指数选项从表里现读;locale 决定下拉里显示中文名还是英文名
    const indices = await getMetalPriceIndices()
    const locale = await getLocale()

    const { data: row, error } = await supabase
        .from('metal_prices')
        .select('id, metal, price_usd_per_tonne, price_date, price_index, notes, source')
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

            <EditMetalPriceForm indices={indices} locale={locale} row={row} />
        </div>
    )
}
