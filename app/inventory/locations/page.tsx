// app/inventory/locations/page.tsx
// LOC-1:库位主数据列表。
//
// CONV-5:套 CONV-1 的两文件模板。
// ★ 那句 recordsOnlyNotice 进 ListPage 的 notices 槽 —— 它是【无条件】的话
//   (「这一刀只记录,不设闸」),而 children 只在 state==='ok' 时才画。
//   CONV-1 §③ 那个槽正是为这一类话开的:一条只在有数据时才出现的警告,
//   等于没有警告。这里空态与非空态都要看见它。
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
import { ListPage } from '@/app/components/ui/list-page'
import LocationsTable, { type LocationRow } from './LocationsTable'

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

    const tableRows: LocationRow[] = rows.map((r) => ({
        id: r.id,
        code: r.code,
        name: r.name,
        zone: r.zone ?? '—',
        isActive: r.is_active,
        unconfigured: isUnconfigured(r),
        // 分类名的语言在服务端选好 —— classes/locale 都不过 RSC 边界
        allowedLabels: r.allowed_codes.map(classLabel),
    }))

    return (
        <ListPage
            title={t('locations.listTitle')}
            actions={
                <Link
                    href="/inventory/locations/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 text-sm"
                >
                    {t('locations.new')}
                </Link>
            }
            notices={
                <>
                    <div className="mb-6">
                        <Link href="/inventory" className="text-blue-600 hover:underline text-sm">
                            {t('common.back')}
                        </Link>
                    </div>
                    {/* 【这一刀只记录,不设闸】—— 一张写着"可存放分类"的表看起来就像已经
                        在拦了,所以第一句话就说清楚它还没有。 */}
                    <p className="text-sm text-gray-600 bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-6">
                        {t('locations.recordsOnlyNotice')}
                    </p>
                </>
            }
            state={{ kind: 'ok' }}
        >
            <LocationsTable rows={tableRows} empty={t('locations.empty')} />
        </ListPage>
    )
}
