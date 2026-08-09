// app/purchasing/page.tsx
// /purchasing 本身没有独立内容 —— 直接落到采购单列表(子导航里再去模板)。
import { redirect } from 'next/navigation'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function PurchasingPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.purchasing)
    if (denied) return denied

    redirect('/purchasing/orders')
}
