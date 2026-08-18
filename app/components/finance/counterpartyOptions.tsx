// app/components/finance/counterpartyOptions.tsx
// PAYEE-1b:一个往来对象选择器,两张表单共用(开支、付款)。
//
// 【为什么把"种类"编进 option 的 value 里,而不是另开一个字段】
// PAYEE-1a 在库里立的规矩是 supplier XOR employee —— 恰好一个。
// 如果表单送两个字段(kind 一个、id 一个),它们就有可能【互相矛盾】:
// 选了员工却留着上一次的 supplier_id,服务端只好去猜哪个是真的。
// 把种类写进 value(`supplier:<uuid>` / `employee:<uuid>`)之后,
// **一次选择就是一个不可分割的答案**,没有第二个字段可以和它不一致。
// 这与库里那条 XOR 是同一件事在表单上的样子。
//
// 【空名单要【说出来】,不能只是没有选项】
// 一个空的下拉配一个点不动的按钮,是 PAYEE-1a 在报销页上不得不删掉的那个形状:
// 屏幕看起来正常,人却永远走不通,而且没有任何一句话解释为什么。
// 所以员工名单为空时,这里放一个【禁用的、写着原因的】选项 ——
// 它占着位置、说得出话,而供应商那一组仍然选得动,按钮不会因此变死。
import { type ReactNode } from 'react'

export type PartyOption = { id: string; name: string }

/** `supplier:<uuid>` / `employee:<uuid>` → 拆成种类与 id。认不出就返回 null。 */
export type CounterpartyKind = 'customer' | 'supplier' | 'employee'

export function parseCounterparty(raw: string | null | undefined):
    { kind: CounterpartyKind; id: string } | null {
    if (!raw) return null
    const i = raw.indexOf(':')
    if (i <= 0) return null
    const kind = raw.slice(0, i)
    const id = raw.slice(i + 1)
    if ((kind !== 'supplier' && kind !== 'employee' && kind !== 'customer') || !id) return null
    return { kind, id }
}

/** 反过来:拼一个 option value。两处拼法只有这一份,免得前后端各写一遍。 */
export function counterpartyValue(kind: CounterpartyKind, id: string): string {
    return `${kind}:${id}`
}

export function CounterpartyOptions({
    suppliers, employees, supplierLabel, employeeLabel, employeesEmptyLabel,
}: {
    suppliers: PartyOption[]
    employees: PartyOption[]
    supplierLabel: string
    employeeLabel: string
    /** 员工名单为空时显示的【那句话】—— 必须说得出下一步去哪 */
    employeesEmptyLabel: string
}): ReactNode {
    return (
        <>
            <optgroup label={supplierLabel}>
                {suppliers.map((s) => (
                    <option key={`s-${s.id}`} value={counterpartyValue('supplier', s.id)}>
                        {s.name}
                    </option>
                ))}
            </optgroup>
            <optgroup label={employeeLabel}>
                {employees.length === 0 ? (
                    <option value="" disabled>
                        {employeesEmptyLabel}
                    </option>
                ) : (
                    employees.map((e) => (
                        <option key={`e-${e.id}`} value={counterpartyValue('employee', e.id)}>
                            {e.name}
                        </option>
                    ))
                )}
            </optgroup>
        </>
    )
}
