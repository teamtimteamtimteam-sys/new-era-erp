// app/finance/Subnav.tsx
// 财务子导航的【判断一半】(服务端)。渲染在 SubnavClient.tsx —— 那一半要
// usePathname,所以必须是 'use client';而"这个人进不进得去"要读库,客户端答不了。
//
// 【IA-BUILD-1:来源换成了整份注册表】此前这里只取【跨模块的那几条】,其余 30 条
// 手写在 SubnavClient 的两个数组里。现在整条子导航都来自 getFunctionAccess('finance')
// —— 与顶栏画财务那一栏读的是同一份,那两个必须"一起加"的数组因此不存在了。
//
// 【48 个财务页面一行都没有改】它们照旧写 <Subnav />。
import { getFunctionAccess } from '@/lib/moduleAccess'
import SubnavClient from './SubnavClient'

export default async function Subnav() {
    const items = (await getFunctionAccess('finance')).map(({ fn, allowed }) => ({
        href: fn.href,
        key: fn.navKey,
        allowed,
    }))
    return <SubnavClient items={items} />
}
