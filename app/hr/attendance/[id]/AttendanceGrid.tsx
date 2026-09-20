'use client'

// app/hr/attendance/[id]/AttendanceGrid.tsx
// ATTEND-1:一个月的每人一行。
//
// ★【这张表最重要的一列是"记了没有",而不是任何一个数字】★
// 三个 0 是一句真话("这个月他没有加班"),空白是另一句("没人看过这一行")。
// 界面必须让两者看起来【不一样】—— 否则库里分得清也没用。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★ DRAFT-1(2026-09-21)· 这张表搬到了 `<EditableTable>` 上 ★★
// ════════════════════════════════════════════════════════════════════════════
//   ★ 它是 `mode: 'all-rows'` **加 `onSave`** —— 也就是
//     【整格都在编辑态,而每一行有自己的保存钮】。
//     搬家前它就是这个形状(每一行一个 `LineRow`,各自握着四个 useState,
//     各自一颗「保存这一行」),而组件此前**做不到**这件事:
//     `showActions` 从前写着 `mode === 'one-row'`,于是整格模式下
//     整条动作列根本不存在。DRAFT-1 的 Q3 把那半行条件拿掉了。
//   ☞ **所以这次搬家【没有】把「一次只改一行」强加给它** ——
//     一个工资员照旧可以把二十行打完再逐行存。
//
//   ★ 搬家收下的三件:
//     ① 「没录入的行涂琥珀」从 `LineRow` 里那句三元,变成 `rowClassName`(能力 B);
//     ② 保存失败的错误从【页顶红框】变成【那一行下面,带 role="alert"】;
//     ③ ★★ **失败时不再 `router.refresh()`** ★★ —— 这是一处真的行为修正,
//        不只是换壳:搬家前 `run()` 无论成败都调 `router.refresh()`
//        (旧文件 :39-42),也就是说**一次失败的保存会把人刚打的字冲掉**。
//        组件的 Q6 明文禁止这件事,搬过来之后它就不可能发生了。
//   ★ 变体 A → variant C:此前是手搓的 `border-b` + `text-sm`,现在走组件自己的表体。
//
//   ⚠ **live 计数(DRAFT-1 · R11,2026-09-21):`attendance_lines` = 0 行,
//     `attendance_periods` = 0 行。** 也就是说这张表搬完之后
//     **在线上没有任何一个屏幕能看见它** —— 要看它得先建一个考勤期。
//     这一句写在这里,是因为一个绿的构建不是一次目视。
// ════════════════════════════════════════════════════════════════════════════
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { recordAttendance, completeAttendancePeriod, reopenAttendancePeriod, syncAttendancePeriod } from '../actions'
import { Button } from '@/app/components/ui/button'
import { Alert } from '@/app/components/ui/alert'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

type Row = {
    lineId: string; employeeCode: string; legalName: string
    normal: number; restDay: number; holiday: number
    note: string; recorded: boolean; unpaidDays: number | null
}

type Draft = { normal: string; restDay: string; holiday: string; note: string }

const num = (v: string) => (v.trim() === '' ? 0 : Number(v))
const cell = `${CONTROL_INPUT} w-20 text-right`

export default function AttendanceGrid({
    periodId, status, rows,
}: { periodId: string; status: string; rows: Row[] }) {
    const t = useTranslations()
    const router = useRouter()
    const [error, setError] = useState<string | null>(null)
    const [notice, setNotice] = useState<string | null>(null)
    const [reason, setReason] = useState('')
    const [pending, startTransition] = useTransition()
    const open = status === 'open'
    const unrecorded = rows.filter((r) => !r.recorded).length

    // ★ 这一支现在只装【整期】那三个动作(完成 / 同步花名册 / 重开)——
    //   逐行保存的失败由组件画在那一行下面,不再挤进同一个页顶红框。
    const run = (fn: () => Promise<{ error?: string; note?: string }>) =>
        startTransition(async () => {
            setError(null); setNotice(null)
            const res = await fn()
            if (res.error) setError(res.error)
            // 拒绝顺手把缺口补出来了 —— 说出来,否则刷新出来的新行像是凭空冒出来的
            if (res.note) setNotice(t('attendance.rosterSynced', { count: res.note }))
            router.refresh()
        })

    // ★ priority 的那四列 = 搬家前 390px 上留着的那四列
    //   (员工 · 平日加班 · 休息日加班 · 记了没有)。
    //   节假日加班 / 备注 / 无薪天数下到展开区:前两个少见或是长文本,第三个是只读的。
    const columns: EditableColumn<Row, Draft>[] = [
        {
            key: 'employee',
            header: t('attendance.colEmployee'),
            priority: true,
            render: (r) => (
                <>
                    <div>{r.legalName}</div>
                    <div className="text-xs text-gray-500">{r.employeeCode}</div>
                </>
            ),
        },
        {
            key: 'normal',
            header: t('attendance.colOtNormal'),
            priority: true,
            align: 'right',
            render: (r) => r.normal,
            edit: (d, set) => (
                <input className={cell} value={d.normal} aria-label={t('attendance.colOtNormal')}
                       onChange={(e) => set({ normal: e.target.value })} />
            ),
        },
        {
            key: 'restDay',
            header: t('attendance.colOtRestDay'),
            priority: true,
            align: 'right',
            render: (r) => r.restDay,
            edit: (d, set) => (
                <input className={cell} value={d.restDay} aria-label={t('attendance.colOtRestDay')}
                       onChange={(e) => set({ restDay: e.target.value })} />
            ),
        },
        {
            key: 'holiday',
            header: t('attendance.colOtHoliday'),
            align: 'right',
            render: (r) => r.holiday,
            edit: (d, set) => (
                <input className={cell} value={d.holiday} aria-label={t('attendance.colOtHoliday')}
                       onChange={(e) => set({ holiday: e.target.value })} />
            ),
        },
        {
            key: 'note',
            header: t('attendance.colNote'),
            render: (r) => <span className="text-gray-600">{r.note || '—'}</span>,
            edit: (d, set) => (
                <input className={`${CONTROL_INPUT} w-full`} value={d.note} aria-label={t('attendance.colNote')}
                       onChange={(e) => set({ note: e.target.value })} />
            ),
        },
        {
            // 无薪天数是算出来的,谁也改不动它 —— 所以没有 edit。
            key: 'unpaidDays',
            header: t('attendance.colUnpaidDays'),
            align: 'right',
            className: 'text-gray-600',
            render: (r) => (r.unpaidDays === null ? '—' : r.unpaidDays),
        },
        {
            // ★ 空白与三个 0 必须看起来不一样 ★
            // 搬家前这一格里还挤着那颗「保存这一行」;现在钮归动作列,
            // 这一格只剩它本来该说的那一件事。
            key: 'recorded',
            header: t('attendance.colRecorded'),
            priority: true,
            render: (r) =>
                r.recorded ? (
                    <span className="text-xs text-green-700">{t('attendance.recordedYes')}</span>
                ) : (
                    <span className="text-xs text-amber-700 font-medium">{t('attendance.recordedNo')}</span>
                ),
        },
    ]

    return (
        <>
            {error && <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}
            {/* ★★ POLISH-1(2026-09-12,Tim 的裁定 R12)· info 横幅走库里的 <Alert> ★★
                   R12 的原话:「**只裁那 ~8 条真正的 info 横幅**,而且要在 R8 的横幅
                   形状落地【之后】—— 因为一条白底 + 1px 描边的横幅,可能**根本不需要
                   一个 info 蓝**。」☞ 量下来:**不需要。**
                   `<Alert>` 的 default 档是 `bg-card`(白)+ `text-card-foreground`
                   (`--brand-text #182B4B`,白底 **14.13:1 ✓**),描边取 `currentColor`
                   于是与字同色 —— **「这是一条通知」由那个带描边的盒子说,不由颜色说**。
                   ☞ 所以这一刀**没有**给 `alert.tsx` 新开一个 `info` 档:
                     它今天仍然只有 `default` 与 `destructive` 两档。
                     ★ 少一个没人裁过的状态色,就少一处将来会漂的定义。 */}
            {notice && <Alert className="mb-3">{notice}</Alert>}

            <EditableTable<Row, Draft>
                rows={rows}
                columns={columns}
                rowKey={(r) => r.lineId}
                phone={{ mode: 'columns' }}
                mode="all-rows"
                canEdit={open}
                className="mb-4"
                empty={t('attendance.noLines')}
                // ★ 能力 B:没录入的行整行涂琥珀 —— 搬家前是 LineRow 里的一句三元。
                rowClassName={(r) => (r.recorded ? undefined : 'bg-amber-50')}
                toDraft={(r) => ({
                    normal: String(r.normal),
                    restDay: String(r.restDay),
                    holiday: String(r.holiday),
                    note: r.note,
                })}
                labels={{
                    edit: t('common.edit'), save: t('attendance.saveLine'), saving: t('common.saving'),
                    cancel: t('common.cancel'), unsaved: t('common.unsavedRow'), expand: t('common.expandRow'),
                }}
                // ★★ 失败【不刷新】—— 字留住,行留在编辑态。见抬头 ③。 ★★
                onSave={async (d, row) => {
                    const res = await recordAttendance(
                        row.lineId, num(d.normal), num(d.restDay), num(d.holiday), d.note.trim() || null,
                    )
                    if (res.error) return { error: res.error }
                    router.refresh()
                }}
            />

            {open ? (
                <div className="flex items-center gap-3">
                    <Button variant="default" className="text-sm"
                        type="button"
                        disabled={pending}
                        onClick={() => run(() => completeAttendancePeriod(periodId))}
                    >
                        {t('attendance.completeBtn')}
                    </Button>
                    <Button variant="secondary" className="text-sm"
                        type="button"
                        disabled={pending}
                        onClick={() => run(async () => {
                            const res = await syncAttendancePeriod(periodId)
                            return res.added ? { note: String(res.added) } : {}
                        })}
                    >
                        {t('attendance.syncBtn')}
                    </Button>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">
                        {unrecorded > 0
                            ? t('attendance.completeBlocked', { count: String(unrecorded) })
                            : t('attendance.completeHint')}
                    </p>
                </div>
            ) : (
                <div className="flex items-end gap-3">
                    <label className="flex-1 max-w-md">
                        <span className="block text-[color:var(--brand-muted-text)] mb-1">{t('attendance.reopenReason')}</span>
                        <input
                            value={reason}
                            onChange={(e) => setReason(e.target.value)}
                            className={`${CONTROL_INPUT} w-full`}
                        />
                    </label>
                    <Button
                        variant="destructive"
                        type="button"
                        disabled={pending || reason.trim() === ''}
                        onClick={() => run(() => reopenAttendancePeriod(periodId, reason))}
                    >
                        {t('attendance.reopenBtn')}
                    </Button>
                </div>
            )}
        </>
    )
}
