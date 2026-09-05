// app/settings/layout.tsx
// ════════════════════════════════════════════════════════════════════════════
// UI-1c ①:设置底下【每一页】都戴着那条同级导航 —— 而它是【一个】插入点
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么是 layout,不是往七个 page.tsx 里各插一行】
//   ① 一个插入点 vs 七个。七处手插就是第二份清单换了身衣服 —— 加第八张子页时
//      有人会忘掉其中一处,而那一处在屏幕上看不出来。
//   ② **它顺带盖住深页**:/settings/roles/new、/settings/roles/[id]、
//      /settings/import/template/*。七处手插【盖不到】它们,而那正是一个人
//      最容易迷路的地方(建角色建到一半,想去看权限速查)。
//   ★ 这是本仓库的【第一个】嵌套 layout(此前只有 app/layout.tsx 一个)。
//     记一句,免得下一个人以为这里本来就有一层。
//
// ★【它画在 RefusalPage 【上面】,而这是【对】的,不是一处副作用】★
//   七张子页各自的守卫在被拒时 return 一张 <RefusalPage>,而 layout 照画。
//   于是一个 Choo Er 直接敲 /settings/roles 的人看到的是:
//   **一条写着七件事的导航(六件标着「· 受限」)+ 一句具名的拒绝。**
//   这比一张孤零零的拒绝页多说了一件事:设置是一个真实的地方,它底下有七件事,
//   这一件不归你 —— 而不是"你撞上了一堵墙,里面有什么不知道"。
//
// 【判权限只发生一次】getModuleAccess() 是坐在 React cache 上的
//   (getMyPermissions 已经是 cache()),顶栏这一次渲染里已经调过它 ——
//   这里再调不会打第二次库。**所以这条导航与顶栏、与头像下拉那七行,
//   读的是同一次求值的结果,不可能各错一次。**
import { getModuleAccess } from '@/lib/moduleAccess'
import { SETTINGS_MODULE_ID } from '@/lib/modules'
import SettingsSubnav from './SettingsSubnav'
import type { NavEntry } from '@/app/components/nav/types'

export default async function SettingsLayout({
    children,
}: Readonly<{ children: React.ReactNode }>) {
    // 【从注册表派生,不重列一份码】七张子页由四个不同的判据把门,其中字典那个
    // 是 `{ all: [], any: ['module.materials.view', 'module.inbound.view'] }` ——
    // 一份手抄的码清单表达不了它,而两份清单必然漂开(lib/modules.ts 抬头 §一)。
    const entries: NavEntry[] =
        (await getModuleAccess())
            .find((a) => a.module.id === SETTINGS_MODULE_ID)
            ?.entries.map(({ fn, allowed }) => ({ href: fn.href, key: fn.navKey, allowed })) ?? []

    return (
        <>
            {/* px-8 与七张子页自己的 p-8 对齐(ListPage 的默认 padding 也是 p-8),
                所以这条导航与它们的 <h1> 在同一条左边线上。
                下方的间距由子页自己的 pt-8 给,这里不再补 —— 补了就是两处各给一半。 */}
            <div className="px-8 pt-6">
                <SettingsSubnav entries={entries} />
            </div>
            {children}
        </>
    )
}
