// app/metal-prices/new/page.tsx
// 新增金属价格:无需下拉数据(金属集合是常量),直接渲染客户端表单。
import NewMetalPriceForm from './NewMetalPriceForm'

export default function NewMetalPricePage() {
    // 【本页没有 requireModule,是有意的,不是漏了 —— 不要"补"回来】
    // metal_prices 的 SELECT 策略写的是 `USING (true)`(db/tables/metal_prices.sql):
    // 数据自己声明它是公开的。挂上 module.pricing.view 会让 UI 比数据库还严 ——
    // 对一个数据库愿意完整回答的人显示"你没有权限",而那道门数据库里根本不存在。
    // 【把关跟着数据自己的 RLS 走,不跟模块目录走】;完整理由在 lib/modules.ts
    // 的 /pricing 那一条(/pricing 本身仍然受管:公式与商务条款不是公开数据)。
    // 写入这一侧由 RLS 自己管:insert/update/delete 策略都是
    // `has_permission('module.pricing.edit')`,所以本页打得开、存不下 ——
    // 与 OPS-15 之前的行为一致(这四页在 OPS-15 之前本来就没有任何页面级把关)。

    return <NewMetalPriceForm />
}
