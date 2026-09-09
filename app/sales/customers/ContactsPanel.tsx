'use client'

// PARTY-1:一个对手方的联系人【们】。同一个面板服务客户与供应商 ——
// 归属由 props 决定,而服务端函数按归属那一侧查权限。
//
// ★【它不是一方两身那个结构】★ 这个面板画的是【一边】的联系人。
//   它不把某个客户与某个供应商连起来 —— 那个问题的今天只有一份报告
//   (/sales/customers/overlap),没有结构上的答案。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { saveContact, removeContact } from './contactActions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type ContactRow = {
    id: string
    name: string
    name_inferred: boolean
    role: string | null
    email: string | null
    phone: string | null
    is_primary: boolean
    notes: string | null
}

const EMPTY = { name: '', role: '', email: '', phone: '', notes: '', isPrimary: false }

export default function ContactsPanel({ customerId, supplierId, rows, canEdit, permissionCode }: {
    customerId?: string
    supplierId?: string
    rows: ContactRow[]
    canEdit: boolean
    /** 【这个码随宿主页面变】供应商页是 module.suppliers.edit,客户页是
     *  module.customers.edit —— 同一个面板,两个属主,所以码不能写死在这里。 */
    permissionCode: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [editing, setEditing] = useState<string | null>(null)   // contact id or 'new'
    const [f, setF] = useState(EMPTY)

    // 【按不下去就把理由摆在旁边】—— 一个按不下去又不说为什么的按钮读起来像是坏了。
    const why = !f.name.trim() ? t('contacts.needName')
              : (!f.email.trim() && !f.phone.trim()) ? t('contacts.needReach')
              : ''

    /* ★ TABLE-PHONE-3:同一组控件要在两个断点各画一次(桌面档在自己那一列,
       手机档叠在「姓名」格里),所以在这里定义一次 —— 免得两处日后走散。
       闸与动作一个字没改:同一个 PermissionGate、同一个 open / drop。 */
    const rowControls = (r: ContactRow) => (
        <PermissionGate code={permissionCode} allowed={canEdit}>
            <Button variant="secondary" size="xs" type="button" onClick={() => open(r)} disabled={pending}>
                {t('common.edit')}
            </Button>
            <Button variant="reversal" size="xs" className="ml-2" type="button" onClick={() => drop(r.id)} disabled={pending}>
                {t('contacts.remove')}
            </Button>
        </PermissionGate>
    )

    function open(r?: ContactRow) {
        setError(null)
        setEditing(r?.id ?? 'new')
        setF(r ? { name: r.name, role: r.role ?? '', email: r.email ?? '',
                   phone: r.phone ?? '', notes: r.notes ?? '', isPrimary: r.is_primary }
               : EMPTY)
    }

    function submit() {
        setError(null)
        start(async () => {
            const res = await saveContact({
                customerId, supplierId,
                contactId: editing && editing !== 'new' ? editing : undefined,
                name: f.name, role: f.role, email: f.email, phone: f.phone,
                notes: f.notes, isPrimary: f.isPrimary,
            })
            if (res.error) { setError(res.error); return }
            setEditing(null); router.refresh()
        })
    }

    function drop(id: string) {
        setError(null)
        start(async () => {
            const res = await removeContact({ contactId: id, customerId, supplierId })
            if (res.error) { setError(res.error); return }
            router.refresh()
        })
    }

    // ★ TABLE-CONVERT-3:手搓表格 → 组件。
    //   【手机上留哪几列】TABLE-PHONE-3 留的是 姓名 · 电话 · 主联系人
    //   ——「这张表没有数,留在列上的是【手机上打得通的那一条】」,原样成立。
    //   折起来的是 职务 · 邮箱。
    //
    // ★★【动作那一列从"折起来 + 另画一份在身份格里"变成 priority —— R1】★★
    //   转换之前它带着 hidden sm:table-cell,而两颗钮【另外画了一份在姓名格里】
    //   (源码原注释:那一条没有标签,因为两个钮自己带着字)。也就是说它在手机上
    //   本来就【不用点开任何东西就够得着】。组件里没有"叠在身份格里画出来"这一档:
    //   要么 priority,要么进点一下才展开的那一段 —— 折进去就要先点开一行才够得着,
    //   那正是 R1 判过的事(够不着的动作等于不存在)。
    //   ☞ 所以它 priority:true。列头保持【空的】,与转换之前逐字相同,
    //     所以【没有】新增任何 i18n key。
    //   ☞ 与 TABLE-CONVERT-2 对 assets / close 的处置同一条,同样当成
    //     【手机可见列多了一列】报出来,不藏在"同一组"里面。
    const columns: Column<ContactRow>[] = [
        {
            key: 'name', header: t('contacts.colName'), priority: true,
            render: (r) => (
                <>
                    {r.name}
                    {r.name_inferred && (
                        <span className="ml-1 text-xs text-amber-700" title={t('contacts.inferredWhy')}>
                            {t('contacts.inferredTag')}
                        </span>
                    )}
                </>
            ),
        },
        { key: 'role', header: t('contacts.colRole'), render: (r) => r.role ?? '—' },
        { key: 'email', header: t('contacts.colEmail'), className: 'break-all', render: (r) => r.email ?? '—' },
        { key: 'phone', header: t('contacts.colPhone'), priority: true, render: (r) => r.phone ?? '—' },
        {
            key: 'primary', header: t('contacts.colPrimary'), priority: true,
            render: (r) => (r.is_primary
                ? <span className="text-xs bg-gray-800 text-white px-2 py-1 rounded">{t('contacts.primaryTag')}</span>
                : <span className="text-xs text-gray-400">—</span>),
        },
        // 空列头 —— 与转换之前逐字相同(那一列本来就没有列头,两颗钮自己带着字)。
        { key: 'actions', header: '', priority: true, className: 'whitespace-nowrap', render: rowControls },
    ]

    return (
        <div>
            {error && <p className="text-sm text-red-700 mb-2">{error}</p>}
            <div className="mb-3">
                <DataTable
                    rows={rows}
                    columns={columns}
                    rowKey={(r) => r.id}
                    phone={{ mode: 'columns' }}
                    empty={t('contacts.noneYet')}
                />
            </div>

            {/* ★★ ALERT-2d ④(a):`canEdit && !<开合位>` —— 一个权限答复与
                       【这一次会话里面板开没开】挤在同一个 &&。为假的两个原因
                       后果完全不同,而屏幕上的表现是同一个:**钮不见了**。
                       DBLOCK-1 裁定:注定被拒的控件要【看得见、按不动、说出为什么】。
                       ☞ 改法是**闸归闸、开合归开合** —— 权限的闸装在这个钮上,
                         `open` 照旧只管面板开不开。
                       ☞ 面板【自己不再套闸】:它里面有【取消】,而 `fieldset disabled`
                         会把取消一起禁掉,人就被关在一个既提交不了也关不掉的表单里
                         (DBLOCK-1 量出来的第一条边界)。而它也不需要 ——
                         没有权限的人翻不开这个开合位。 */}
                    {editing === null && (
                <PermissionGate code={permissionCode} allowed={canEdit} inline>
                    <Button variant="secondary" size="xs" type="button" onClick={() => open()} disabled={pending}>
                        {t('contacts.add')}
                    </Button>
                </PermissionGate>
            )}

            {editing !== null && (
                <div className="border border-gray-400 rounded p-3 bg-gray-50 max-w-2xl">
                    <div className="grid grid-cols-2 gap-2">
                        <label className="text-xs">{t('contacts.colName')}
                            <input type="text" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })}
                                   className="block w-full border border-gray-300 rounded px-2 py-1 text-xs" />
                        </label>
                        <label className="text-xs">{t('contacts.colRole')}
                            <input type="text" value={f.role} onChange={(e) => setF({ ...f, role: e.target.value })}
                                   className="block w-full border border-gray-300 rounded px-2 py-1 text-xs" />
                        </label>
                        <label className="text-xs">{t('contacts.colEmail')}
                            <input type="text" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })}
                                   className="block w-full border border-gray-300 rounded px-2 py-1 text-xs" />
                        </label>
                        <label className="text-xs">{t('contacts.colPhone')}
                            <input type="text" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })}
                                   className="block w-full border border-gray-300 rounded px-2 py-1 text-xs" />
                        </label>
                        <label className="text-xs col-span-2">{t('contacts.colNotes')}
                            <input type="text" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })}
                                   className="block w-full border border-gray-300 rounded px-2 py-1 text-xs" />
                        </label>
                    </div>
                    <label className="flex items-center gap-2 mt-2 text-xs">
                        <input type="checkbox" checked={f.isPrimary}
                               onChange={(e) => setF({ ...f, isPrimary: e.target.checked })} />
                        {t('contacts.makePrimary')}
                    </label>
                    {/* 【主联系人会被开票快照读到 —— 按之前说出来】 */}
                    <p className="text-xs text-gray-600 mt-1">{t('contacts.primaryWhat')}</p>
                    <div className="flex gap-2 items-center mt-2">
                        <Button size="xs" type="button" disabled={pending || why !== ''} onClick={submit}>
                            {t('common.save')}
                        </Button>
                        <Button variant="secondary" size="xs" type="button" disabled={pending} onClick={() => { setEditing(null); setError(null) }}>
                            {t('common.cancel')}
                        </Button>
                        {why && <span className="text-xs text-gray-600">{why}</span>}
                    </div>
                </div>
            )}
        </div>
    )
}
