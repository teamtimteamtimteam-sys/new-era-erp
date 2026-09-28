// lib/employeeNames.ts
// NAME-1(Tim 2026-09-28):员工的名字与姓氏。
//
// 【为什么单独一个文件、而且一个 import 都没有】「名字必填」这条规矩【只】住在应用这一层 ——
// 库里故意没有约束(Tim Q17:53 支 fixture 直接插员工;anonymise_employee 要能清空它;
// 工资、账号那些写员工的函数不该因为一行旧档案没填名字就失败)。
// 于是它唯一的证据只能是【把这段代码真的跑一遍】:scripts/check-employee-names.mjs 用 Node 的
// type-stripping 把本文件 import 进来执行,并核对 createEmployee / updateEmployee 两处都用了它。
// 本文件若 import 了别的东西(next、supabase),那支检查就跑不起来 —— 所以保持纯函数。

/** 表单上的一栏 → 存进库的值:去掉首尾空白,空白存 NULL(与 preferred_name 同一个写法)。 */
export function normaliseName(raw: FormDataEntryValue | null | undefined): string | null {
    const s = String(raw ?? '').trim()
    return s === '' ? null : s
}

/** 名字必填;姓氏可空 —— 这里【只】看名字。建档与保存两处各调一次。 */
export function firstNameMissing(f: { first_name: string | null }): boolean {
    return f.first_name === null
}
