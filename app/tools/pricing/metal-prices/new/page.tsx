// app/tools/pricing/metal-prices/new/page.tsx
// 新增金属价格。
// 【PROC-4 之前这里写着「金属集合是常量」 —— 那句话不再成立】
// 物质清单现在是 substances 那张字典的内容,和指数一样从表里现读。
import NewMetalPriceForm from './NewMetalPriceForm'
import { requireEditPermission } from '@/app/components/moduleGuard'
import { getMetalPriceIndices } from '../indexQuery'
import { getLocale } from '@/lib/i18n/server'
import { createClient } from '@/lib/supabase/server'
import { loadSubstances, toOptions } from '../substanceQuery'

export default async function NewMetalPricePage() {
    // 【本页把关用 module.pricing.edit,不是 module.pricing.view。这是那条规矩的「写」那一半】
    // 规矩只有一条:【守卫跟着数据自己的 RLS 走,不跟模块目录走】。
    // 而一张表的 RLS 本来就有读、写两个答案,metal_prices 的这两个答案【不一样】——
    // 所以 app/tools/pricing/metal-prices/ 底下四页带着两种守卫,那是【同一条规则的两半,不是例外】:
    //
    //   读(列表页 /tools/pricing/metal-prices)  SELECT ... USING (true)
    //                             → 不设守卫
    //   写(new / bulk / [id]/edit) INSERT|UPDATE|DELETE ... has_permission('module.pricing.edit')
    //                             → requireEditPermission('module.pricing.edit', ...)
    //
    // (策略原文见 db/tables/metal_prices.sql;完整理由见 lib/modules.ts 的 /tools/pricing 那一条。)
    //
    // 改行情不是人人可以,而本页【只做】这件事。用 module.pricing.view 把关会同时错两头:
    // 挡下有 edit 而无 view 的人,又放进有 view 而无 edit 的人 —— 让后者填完整张表单,
    // 再被数据库以 42501 拒收。不设守卫则只错后一头。边界仍然是那几条 WITH CHECK 策略;
    // 这里只是不要把一张注定被拒收的表单摆到人面前。

    const denied = await requireEditPermission('module.pricing.edit', 'nav.metalPrices')
    if (denied) return denied

    // METAL-2:指数选项从表里现读(加一个指数是加一行,不是改代码)
    const indices = await getMetalPriceIndices()
    const locale = await getLocale()
    // PROC-4:物质清单从字典读 —— 加一种物质是加一行,这一页不必改。
    const substanceOptions = toOptions(await loadSubstances(await createClient()))

    return <NewMetalPriceForm substanceOptions={substanceOptions} indices={indices} locale={locale} />
}
