#!/usr/bin/env node
// scripts/check-employee-names.mjs —— NAME-1(v1.4.31,2026-09-28)
//
// 【瞄准 · AIM】
//   我读的是      :lib/employeeNames.ts(用 Node 的 type-stripping import 进来【真的跑】)·
//                  app/hr/employees/actions.ts 与 app/hr/employees/EmployeeForm.tsx 的 **TypeScript AST**
//   我声称管的是   :员工的「名字必填、姓氏可空、空白存 NULL」—— 在建档与保存【两条】路上都成立
//
// 【为什么这条规矩要一支量具】Tim Q17:名字必填【故意不做成库约束】(53 支 fixture 直接插员工;
// anonymise_employee 要能清空它;写员工的那些函数不该因为旧档案没填名字就失败)。
// 于是它只住在应用层 —— 而应用层的一条规矩,没有 fixture 看得见。这支脚本就是它的 fixture:
//   ① 行为:normaliseName / firstNameMissing 真的跑一遍;
//   ② 接线:createEmployee 与 updateEmployee【各自】在写库【之前】问一次 firstNameMissing,
//           拒绝说的是 hr.errFirstNameRequired;readForm 的两栏都经 normaliseName;
//   ③ 表单:first_name 那一栏带 required,last_name 那一栏不带。
// 覆盖断言:两支动作都要找得到(assertPopulation / assertPinned),断言条数钉死(assertAssertionsRan)。
// 退出码:0 干净 · 1 违规 · 2 量具坏了(selfproof 的约定)。

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import ts from 'typescript'
import { assertPinned, assertAssertionsRan } from './lib/selfproof.mjs'
import { normaliseName, firstNameMissing } from '../lib/employeeNames.ts'

const SCRIPT = 'check-employee-names'
const ROOT = process.cwd()
const failures = []
let ran = 0
function check(ok, msg) { ran++; if (!ok) failures.push(msg) }

// ── ① 行为 ────────────────────────────────────────────────────────────────
check(normaliseName('  Ann  ') === 'Ann', "normaliseName('  Ann  ') 应当是 'Ann'(去首尾空白)")
check(normaliseName('   ') === null, "normaliseName('   ') 应当是 null(空白存 NULL)")
check(normaliseName('') === null, "normaliseName('') 应当是 null")
check(normaliseName(null) === null, 'normaliseName(null) 应当是 null(表单里没有这一栏)')
check(firstNameMissing({ first_name: null }) === true, '没有名字时 firstNameMissing 应当为 true(名字必填)')
check(firstNameMissing({ first_name: normaliseName('   ') }) === true, '只填空白的名字也应当算没填')
check(firstNameMissing({ first_name: 'Ann', last_name: null }) === false,
    '有名字、没有姓氏时 firstNameMissing 应当为 false(姓氏可空)')

// ── ② 接线:actions.ts ────────────────────────────────────────────────────
const actionsPath = 'app/hr/employees/actions.ts'
const actionsSrc = readFileSync(join(ROOT, actionsPath), 'utf8')
const actions = ts.createSourceFile(actionsPath, actionsSrc, ts.ScriptTarget.Latest, true)

function walk(node, fn) { fn(node); ts.forEachChild(node, (c) => walk(c, fn)) }
function fnDecl(sf, name) {
    let hit = null
    walk(sf, (n) => { if (ts.isFunctionDeclaration(n) && n.name?.text === name) hit = n })
    return hit
}

const ACTIONS = ['createEmployee', 'updateEmployee']
let found = 0
for (const name of ACTIONS) {
    const f = fnDecl(actions, name)
    if (!f) { failures.push(`${actionsPath}:找不到 ${name}`); continue }
    found++
    // 那一句 if:条件是 firstNameMissing(…),分支里说的是 hr.errFirstNameRequired
    let guardPos = -1
    walk(f, (n) => {
        if (ts.isIfStatement(n) && ts.isCallExpression(n.expression)
            && n.expression.expression.getText(actions) === 'firstNameMissing'
            && n.thenStatement.getText(actions).includes("'hr.errFirstNameRequired'")) guardPos = n.getStart(actions)
    })
    check(guardPos >= 0, `${name}:没有「if (firstNameMissing(f)) return … hr.errFirstNameRequired」那一句`)
    // 它必须在写库之前:第一次 .insert( / .update( 调用的位置
    let writePos = -1
    walk(f, (n) => {
        if (writePos < 0 && ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
            && ['insert', 'update'].includes(n.expression.name.text)) writePos = n.getStart(actions)
    })
    check(writePos >= 0 && guardPos >= 0 && guardPos < writePos,
        `${name}:名字检查必须在写库(.insert / .update)【之前】(检查在 ${guardPos},写在 ${writePos})`)
}
assertPinned(SCRIPT, '找得到的员工动作 ↔ 应当有的员工动作', found, ACTIONS.length,
    '一支动作改了名字,这里就不再看它 —— 那条路上的名字必填就没有人守着。')

// readForm 的两栏都经 normaliseName(formData.get('<同名>'))
const readForm = fnDecl(actions, 'readForm')
for (const col of ['first_name', 'last_name']) {
    let init = null
    if (readForm) walk(readForm, (n) => {
        if (ts.isPropertyAssignment(n) && n.name.getText(actions) === col) init = n.initializer.getText(actions)
    })
    check(init === `normaliseName(formData.get('${col}'))`,
        `readForm 的 ${col} 应当是 normaliseName(formData.get('${col}')),实为 ${init ?? '(没有这一栏)'}`)
}

// ── ③ 表单:first_name 带 required,last_name 不带 ──────────────────────────
const formPath = 'app/hr/employees/EmployeeForm.tsx'
const formSrc = readFileSync(join(ROOT, formPath), 'utf8')
const form = ts.createSourceFile(formPath, formSrc, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
const inputs = {}
walk(form, (n) => {
    if ((ts.isJsxSelfClosingElement(n) || ts.isJsxOpeningElement(n)) && n.tagName.getText(form) === 'input') {
        const attrs = n.attributes.properties.filter(ts.isJsxAttribute)
        const nameAttr = attrs.find((a) => a.name.getText(form) === 'name')
        const nm = nameAttr?.initializer && ts.isStringLiteral(nameAttr.initializer) ? nameAttr.initializer.text : null
        if (nm) inputs[nm] = attrs.some((a) => a.name.getText(form) === 'required')
    }
})
check(inputs.first_name === true, `${formPath}:first_name 那一栏应当带 required(实为 ${inputs.first_name})`)
check(inputs.last_name === false, `${formPath}:last_name 那一栏不应当带 required(实为 ${inputs.last_name})`)

assertAssertionsRan(SCRIPT, ran, 7 + 2 * ACTIONS.length + 2 + 2)

if (failures.length) {
    console.error(`✗ ${SCRIPT}:${failures.length} 条不成立`)
    for (const f of failures) console.error('  · ' + f)
    process.exit(1)
}
console.log(`✓ ${SCRIPT}:名字必填 / 姓氏可空 / 空白存 NULL 成立;两支动作都在写库之前问过(${ran} 条断言)`)
