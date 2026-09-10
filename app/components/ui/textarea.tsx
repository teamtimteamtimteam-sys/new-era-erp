import * as React from "react"

import { cn } from "@/lib/utils"
// ★ INPUT-2(2026-09-10):样式的【来处】搬到了 control-style.ts。
//   **本组件发出去的 class 串逐字节没有变。**
import { TEXTAREA_COMPONENT_CLASS } from "@/app/components/ui/control-style"

function Textarea({ className, ...props }: React.ComponentProps<"textarea">) {
  return (
    <textarea
      data-slot="textarea"
      className={cn(
        TEXTAREA_COMPONENT_CLASS,
        className
      )}
      {...props}
    />
  )
}

export { Textarea }
