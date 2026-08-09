// app/customers/new/page.tsx
// 服务端壳:只做模块把关,表单本体在同目录的客户端组件里。
// 【为什么要拆】NewCustomerForm 是 'use client',守卫是服务端的 —— 见该文件顶部。
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import NewCustomerForm from './NewCustomerForm'

export default async function NewCustomerPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.customers)
    if (denied) return denied

    return <NewCustomerForm />
}
