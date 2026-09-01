// app/finance/Subnav.tsx
// 财务子导航的【判断一半】(服务端)。渲染在 SubnavClient.tsx —— 那一半要
// usePathname,所以必须是 'use client';而"这个人进不进得去"要读库,客户端答不了。
//
// 【NAV-REG-1:为什么多了这一层】/margin 从前是子导航里一行手写的常量,它与
// 「谁能看见毛利」之间没有任何东西保证同步 —— 而那正是 OPS-15 立下的规矩要杀掉的
// 漂移。现在这一项来自 lib/modules.ts 的 FUNCTIONS:/margin 在那里声明自己
// 【同属 /finance 与 /processing】,判据只有一份,加工那侧的入口读的是同一条。
//
// 【48 个财务页面一行都没有改】它们照旧写 <Subnav />;本文件是 async 服务端组件,
// 换掉的是它内部的来源,不是它的用法。
import { getFunctionAccess } from '@/lib/moduleAccess'
import SubnavClient from './SubnavClient'

export default async function Subnav() {
    const functionItems = (await getFunctionAccess('/finance')).map(({ fn, allowed }) => ({
        href: fn.href,
        key: fn.navKey,
        allowed,
    }))
    return <SubnavClient functionItems={functionItems} />
}
