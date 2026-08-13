// app/inventory/locations/page.tsx
// LOC-1:库位主数据列表。
//
// 【为什么在 /inventory 底下而不是 /warehouse】守卫跟着数据自己的 RLS 走
// (lib/modules.ts 的那条规矩):storage_locations 的四条策略读的是
// module.inventory.view / .edit —— 而全库根本没有 module.warehouse.* 这个码
// (warehouse 是一个【角色】,不是模块)。URL 说 warehouse 而权限说 inventory,
// 是给下一个人准备的一个矛盾。moduleForPath 按最长前缀匹配,所以本页自动
// 落在 /inventory 那条模块条目下,不需要(也不应该)新加一条 —— 新加一条
// 会让首页为同一个模块画出第二张卡片。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { getWasteClassifications } from '@/app/materials/wasteClassQuery'
import { isUnconfigured } from './locationTypes'
import LocationActiveToggle from './LocationActiveToggle'
import Subnav from '../Subnav'

type FetchRow = {
    id: string
    code: string
    name: string
    zone: string | null
    is_active: boolean
    storage_location_allowed_classes: { classification_code: string }[] | null
}

export default async function LocationsPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const [rowsRes, classes] = await Promise.all([
        supabase
            .from('storage_locations')
            .select('id, code, name, zone, is_active, storage_location_allowed_classes ( classification_code )')
            .order('code'),
        getWasteClassifications(),
    ])

    const rows = (mustRows(rowsRes, 'storage_locations') as unknown as FetchRow[]).map((r) => ({
        id: r.id,
        code: r.code,
        name: r.name,
        zone: r.zone,
        is_active: r.is_active,
        allowed_codes: (r.storage_location_allowed_classes ?? []).map((c) => c.classification_code),
    }))

    const classLabel = (code: string) => {
        const c = classes.find((x) => x.code === code)
        if (!c) return code
        return locale === 'zh' ? c.name_zh : c.name_en
    }

    return (
        <>
            <Subnav />
        <div className="p-4 sm:p-8">
            <div className="mb-6">
                <Link href="/inventory" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <div className="flex justify-between items-center mb-2">
                <h1 className="text-2xl font-bold">{t('locations.listTitle')}</h1>
                <Link
                    href="/inventory/locations/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 text-sm"
                >
                    {t('locations.new')}
                </Link>
            </div>

            {/* 【这一刀只记录,不设闸】—— 一张写着"可存放分类"的表看起来就像已经
                在拦了,所以第一句话就说清楚它还没有。 */}
            <p className="text-sm text-gray-600 bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-6">
                {t('locations.recordsOnlyNotice')}
            </p>

            {rows.length === 0 ? (
                <p className="text-sm text-gray-500">{t('locations.empty')}</p>
            ) : (
                <div className="overflow-x-auto">
                    <table className="w-full border-collapse border border-gray-300 text-sm">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('locations.colCode')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('locations.colName')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('locations.colZone')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('locations.colAllowed')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('locations.colStatus')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('locations.colActions')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {rows.map((r) => (
                                <tr key={r.id} className={r.is_active ? '' : 'bg-gray-50 text-gray-500'}>
                                    <td className="border border-gray-300 px-3 py-2 font-mono">
                                        <Link
                                            href={`/inventory/locations/${r.id}/edit`}
                                            className="text-blue-600 hover:underline"
                                        >
                                            {r.code}
                                        </Link>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">{r.name}</td>
                                    {/* zone 只是显示分组;没填就是没填 */}
                                    <td className="border border-gray-300 px-3 py-2">{r.zone ?? '—'}</td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {isUnconfigured(r) ? (
                                            // 【未配置,不是"无"、也不是空白】零行的意思是还没有人
                                            // 决定过 —— 将来的检查对它告警而绝不拒绝。把它画成空白
                                            // 或者「无」,就是把"没人想过"演成"想过、结论是没有"。
                                            <span
                                                className="px-2 py-0.5 rounded text-xs bg-amber-100 text-amber-800"
                                                title={t('locations.notConfiguredTitle')}
                                            >
                                                {t('locations.notConfigured')}
                                            </span>
                                        ) : (
                                            <span className="flex flex-wrap gap-1">
                                                {r.allowed_codes.map((c) => (
                                                    <span
                                                        key={c}
                                                        className="px-2 py-0.5 rounded text-xs bg-gray-200 text-gray-700"
                                                    >
                                                        {classLabel(c)}
                                                    </span>
                                                ))}
                                            </span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        <span
                                            className={
                                                'px-2 py-0.5 rounded text-xs ' +
                                                (r.is_active
                                                    ? 'bg-green-100 text-green-800'
                                                    : 'bg-gray-200 text-gray-600')
                                            }
                                        >
                                            {r.is_active ? t('locations.active') : t('locations.inactive')}
                                        </span>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        <LocationActiveToggle id={r.id} isActive={r.is_active} />
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>
            )}
        </div>
        </>
    )
}
