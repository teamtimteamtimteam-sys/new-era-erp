// app/components/ui/date-filter-input.tsx
// HISTORY-1(2026-09-28):列表页筛选条上的【一个】日期框 —— GET 表单里的 from / to。
//
// 【为什么要有它】原生 <input type="date"> 这一维在 scripts/check-date-format.mjs 里【只许减少】
//   (选择器那一刀落地之前,每多一个原生控件就多一处将来要换掉的东西)。/settings/change-history
//   要一对日期筛选;与其再写两个,不如把 /settings/deleted 那一对也并过来 —— 与 TERMS-EDIT-1 的
//   ContractDateInput 同一个做法:一处原生控件,两页共用,将来换选择器只换这一处。
// 【它只做一件事】渲染一个受 name / defaultValue 驱动的非受控日期框,样式取 CONTROL_INPUT。
//   不做校验(服务端 isYmd 判)、不做默认值(空就是"不筛")。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'

export function DateFilterInput({
    name,
    defaultValue,
    ariaLabel,
}: {
    name: string
    defaultValue: string
    ariaLabel?: string
}) {
    return <input type="date" name={name} defaultValue={defaultValue} aria-label={ariaLabel} className={CONTROL_INPUT} />
}
