// TERMS-EDIT-1:合同表单上的日期格(新建页与详情页的表头共用)。
// ★ 原生日期控件在本仓库【只许减少】(scripts/check-date-format.mjs 维度③,DATE-0 的债):
//   详情页的表头要三个日期格,而新建页已经有三个 —— 与其再加三个,不如两处共用这一个,
//   于是将来换掉原生日期控件时,合同这里只有一处要换。
import * as React from 'react'

export function ContractDateInput(props: Omit<React.ComponentProps<'input'>, 'type'>) {
    return <input {...props} type="date" />
}
