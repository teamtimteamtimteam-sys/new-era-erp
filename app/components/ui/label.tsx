"use client"

import * as React from "react"
import { Label as LabelPrimitive } from "radix-ui"

import { cn } from "@/lib/utils"

function Label({
  className,
  ...props
}: React.ComponentProps<typeof LabelPrimitive.Root>) {
  return (
    <LabelPrimitive.Root
      data-slot="label"
      className={cn(
        // ★★ FONT-1(2026-09-11):`text-sm leading-none font-medium` 三个都拿掉了 ★★
        //   字号 / 字重 / 行高从今天起由 app/globals.css 的 `label` 元素规则一处给
        //   (14 / 500 / **20px**)。这里再写一遍就是**第二份定义**,而工具类压得过
        //   元素规则 —— 于是 `leading-none` 会把那条裁定顶掉。
        //   ★ Tim 2026-09-11 明写:「label.tsx must not override it (for example with leading-none)」。
        //   ☞ 代价照直说:`<Label>` 的行高从 **14px 变成 20px**,而 `/brand-sampler`
        //     那三个 label **一个 class 都没写**,所以取样页上那一档也跟着动 ——
        //     那是这条裁定的直接后果(它自己就是一条记录在案的例外),见 spec §4.6。
        "flex items-center gap-2 select-none group-data-[disabled=true]:pointer-events-none group-data-[disabled=true]:opacity-50 peer-disabled:cursor-not-allowed peer-disabled:opacity-50",
        className
      )}
      {...props}
    />
  )
}

export { Label }
