// app/components/nav/EntryButton.tsx
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-4(Tim 2026-10-29 · Q2 2026-10-30)· 一颗通向【一条注册表条目】的入口钮
// ════════════════════════════════════════════════════════════════════════════
//
// 【它是什么】十四条二级条目离开了菜单,改由别的页面右上角的一颗钮通向它们(付款条件、收货差异、COD、
//   库位 · 盘点 · 扫码 · 报表、配料计划、供应商证书)。它们在注册表里是那一页的孩子(parent),搜索与面包屑照旧。
//
// ★【进不去的【照画】,与菜单行同一套记号】★(Tim Q2)
//   读者进不去目标页时,这颗钮画成禁用,名字后面缀「· 受限」,悬停提示是 dashboard.restrictedHint,
//   并带 data-module-restricted 这个机器标记 —— 与 MenuPanel.tsx 的 MenuEntryRow 逐字同一套。
//   **一颗钮与它通向的那一页永远不会各说各话**:判据取自那条注册表条目自己的 permission,经全站唯一的求值器 allows()。
//
// 【为什么提示挂在外面那个 span 上】禁用的 <button> 在多数浏览器里不触发悬停,title 挂在它身上等于没有。
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { getMyPermissions } from '@/lib/permissions'
import { allows, type FunctionEntry } from '@/lib/modules'
import { Button } from '@/app/components/ui/button'

export default async function EntryButton({
    entry,
    label,
}: {
    /** 目标页的注册表条目(FN.xxx)—— 地址与判据都从它来 */
    entry: FunctionEntry
    /** 钮上的字;不给就用条目自己的菜单标签 */
    label?: string
}) {
    const t = await getTranslations()
    const text = label ?? t(entry.navKey)
    if (!allows(entry.permission, await getMyPermissions())) {
        return (
            <span title={t('dashboard.restrictedHint')} data-entry-button={entry.href} data-module-restricted="1" className="inline-flex">
                <Button variant="outline" disabled>
                    {text} · {t('common.restricted')}
                </Button>
            </span>
        )
    }
    return (
        <Button asChild variant="outline">
            <Link href={entry.href} data-entry-button={entry.href}>
                {text}
            </Link>
        </Button>
    )
}
