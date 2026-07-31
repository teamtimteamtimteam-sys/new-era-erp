#!/usr/bin/env python3
# assets/fonts/subset.py
#
# 把 Noto Sans SC 的完整字体裁成发票 PDF 真正用得到的那一小块,并顺带产出
# coverage.json(字符覆盖清单)。仓库里【只提交裁剪后的 .subset.ttf 和
# coverage.json】—— 完整字重每个 10 MB,两个就是 20 MB,进了 git history 就是
# 每次 clone 都要拖、每次冷启动都要解析,不可接受。
#
# ─────────────────────────────────────────────────────────────────────────────
# 为什么发票 PDF 需要中文字体
# ─────────────────────────────────────────────────────────────────────────────
# 物料名已经改成英文、条款正文也是英文,所以【明细行描述】通常不需要中文。
# 但是:
#   - bill_to_snapshot 里的客户名称和地址可能是中文(国内交易对手);
#   - notes 备注字段里用户想写什么就写什么。
# 所以中文字体是【保险】,不是必然要用到的东西 —— 这恰恰是"裁剪 + 守卫"这套
# 做法成立的原因:体积小,而且遇到裁剪范围外的字会【大声报错】,不会在一份要
# 寄给客户的单据上默默印出空白。
#
# ─────────────────────────────────────────────────────────────────────────────
# 覆盖范围(要扩就改这里的 UNICODE_RANGES / 下面的 GB2312 部分,然后重跑本脚本)
# ─────────────────────────────────────────────────────────────────────────────
#   U+0020–007E   Basic Latin(可打印部分)—— 英文正文、数字、$ 、发票编号
#   U+00A0–00FF   Latin-1 Supplement —— é/ü 之类的人名地名,以及 £ ¢ ¥
#   U+2000–206F   General Punctuation —— 破折号 —(U+2014,PDF 里的空值占位符)、
#                                        中英文引号、省略号
#   U+3000–303F   CJK Symbols and Punctuation —— 中文全角句号、顿号、书名号
#   U+FF00–FFEF   Halfwidth and Fullwidth Forms —— 全角逗号/冒号/括号/数字
#   GB2312 一级+二级汉字(6763 字)—— 简体常用字全集
#
# 【刻意不含】U+20A0–20CF Currency Symbols(€ 在这里)。发票金额只印币种代码
# ("1,234.56 USD"),不印符号;真要支持备注里手打的 €,把 (0x20A0, 0x20CF)
# 加进 UNICODE_RANGES 重跑即可。
#
# 【刻意不含】繁体字。新加坡和大陆的交易对手都用简体。哪天真出现繁体交易对手,
# 换成 Noto Sans HK 或 Noto Sans TC —— 是【换源文件 + 重跑本脚本】,不是改代码:
# 把 SOURCES 里的文件名换掉,并把下面 GB2312 那段换成 Big5 或直接放宽成整个
# CJK 统一表意文字区。字体家族名和注册逻辑都不用动。
#
# ─────────────────────────────────────────────────────────────────────────────
# 怎么重跑
# ─────────────────────────────────────────────────────────────────────────────
#   1) 拿到完整字重(仓库里没有,故意的):
#        https://fonts.google.com/noto/specimen/Noto+Sans+SC  → 下载后取
#        NotoSansSC-Regular.ttf 与 NotoSansSC-Bold.ttf
#        (本次裁剪用的是 Version 2.004-H2,30890 个码位 / 30796 个字形)
#   2) 放到本目录(assets/fonts/),或用 --src-dir 指到别处
#   3) pip install fonttools
#   4) python3 assets/fonts/subset.py
#
# 产出(这三个才是提交进仓库的东西):
#   NotoSansSC-Regular.subset.ttf
#   NotoSansSC-Bold.subset.ttf
#   coverage.json
#
# coverage.json 是【从裁剪结果的 cmap 反读出来的】,不是从上面的意图清单生成的
# —— 源字体里没有的码位不会被算进覆盖范围,免得清单比字体本身还乐观。运行时的
# 守卫读这份清单来判断"这个字能不能印",所以它必须和 .subset.ttf 同一次生成。

import argparse
import json
import sys
from pathlib import Path

try:
    from fontTools.subset import Subsetter, Options
    from fontTools.ttLib import TTFont
except ImportError:
    sys.exit("需要 fonttools:  pip install fonttools")

HERE = Path(__file__).resolve().parent

SOURCES = [
    ("NotoSansSC-Regular.ttf", "NotoSansSC-Regular.subset.ttf"),
    ("NotoSansSC-Bold.ttf", "NotoSansSC-Bold.subset.ttf"),
]

# 见上方"覆盖范围"注释。改这里 = 扩大/缩小覆盖,改完重跑本脚本。
UNICODE_RANGES = [
    (0x0020, 0x007E),  # Basic Latin(可打印)
    (0x00A0, 0x00FF),  # Latin-1 Supplement
    (0x2000, 0x206F),  # General Punctuation
    (0x3000, 0x303F),  # CJK Symbols and Punctuation
    (0xFF00, 0xFFEF),  # Halfwidth and Fullwidth Forms
]


def gb2312_hanzi() -> set:
    """GB2312 一级(区 16–55)+ 二级(区 56–87)汉字,共 6763 字。

    用 Python 自带的 gb2312 编解码器【算】出来,而不是硬编码一份 6763 字的表 ——
    表会抄错、会腐烂,而这段代码任何人都能一眼验证。区 55(高位 0xD7)末尾有 5 个
    空位,解码失败直接跳过,所以是 6763 而不是 40*94 + 32*94 = 6768。
    """
    out = set()
    for hi in range(0xB0, 0xF8):  # 区 16–87
        for lo in range(0xA1, 0xFF):  # 位 1–94
            try:
                ch = bytes([hi, lo]).decode("gb2312")
            except UnicodeDecodeError:
                continue  # 空位
            out.add(ord(ch))
    return out


def wanted_codepoints() -> set:
    cps = set()
    for lo, hi in UNICODE_RANGES:
        cps.update(range(lo, hi + 1))
    cps |= gb2312_hanzi()
    return cps


def to_ranges(codepoints) -> list:
    """把码位集合压成 [[start, end], ...],让 coverage.json 小一点、也好读一点。"""
    ranges = []
    for cp in sorted(codepoints):
        if ranges and cp == ranges[-1][1] + 1:
            ranges[-1][1] = cp
        else:
            ranges.append([cp, cp])
    return ranges


def main() -> int:
    ap = argparse.ArgumentParser(description="裁剪发票 PDF 用的 Noto Sans SC 字重")
    ap.add_argument(
        "--src-dir",
        type=Path,
        default=HERE,
        help="完整字重所在目录(默认:本脚本所在目录)",
    )
    ap.add_argument("--out-dir", type=Path, default=HERE, help="输出目录(默认:同上)")
    args = ap.parse_args()

    wanted = wanted_codepoints()
    hanzi_count = len(gb2312_hanzi())
    print(f"目标覆盖:{len(wanted)} 个码位(其中 GB2312 一级+二级汉字 {hanzi_count} 字)")

    missing = [s for s, _ in SOURCES if not (args.src_dir / s).is_file()]
    if missing:
        print(f"\n找不到源字体:{', '.join(missing)}", file=sys.stderr)
        print(f"在目录:{args.src_dir}", file=sys.stderr)
        print("下载方式见本文件头部注释。", file=sys.stderr)
        return 1

    args.out_dir.mkdir(parents=True, exist_ok=True)
    per_font_cmaps = []

    for src_name, out_name in SOURCES:
        src = args.src_dir / src_name
        out = args.out_dir / out_name

        opts = Options()
        opts.drop_tables += ["DSIG"]
        # 保留 .notdef 的方框轮廓:万一守卫哪天被绕过去了,印出"豆腐块"也好过
        # 印出一片空白 —— 至少人眼能看见出事了。
        opts.notdef_outline = True
        # PDF 是矢量输出、由阅读器自己栅格化,hinting 数据用不上,白占体积。
        opts.hinting = False
        opts.desubroutinize = False
        opts.recalc_bounds = True
        opts.name_IDs = ["*"]  # 留住字体名,PDF 里的字体标识才是可读的
        opts.name_legacy = True
        opts.legacy_kern = False

        font = TTFont(src)
        before = src.stat().st_size

        subsetter = Subsetter(options=opts)
        subsetter.populate(unicodes=wanted)
        subsetter.subset(font)
        font.save(out)
        font.close()

        after = out.stat().st_size
        with TTFont(out, lazy=True) as check:
            cmap = set(check.getBestCmap().keys())
            glyphs = check["maxp"].numGlyphs
        per_font_cmaps.append(cmap)

        pct = 100.0 * after / before
        print(
            f"  {src_name:26s} {before / 1e6:6.2f} MB  →  "
            f"{out_name:33s} {after / 1e6:5.2f} MB  ({pct:.1f}%)  "
            f"{glyphs} 字形 / {len(cmap)} 码位"
        )

    # 覆盖清单取【两个字重的交集】—— 只有正常体和粗体都画得出来的字,才算这份
    # 文档能印。任何一个字重缺字,那个字就该被守卫拦下来。
    covered = set.intersection(*per_font_cmaps)
    only_one = set.union(*per_font_cmaps) - covered
    if only_one:
        print(f"  注意:{len(only_one)} 个码位只有单个字重有,已排除在覆盖清单外")

    manifest = {
        "_comment": (
            "自动生成,请勿手改。由 assets/fonts/subset.py 在裁剪字体的同一次运行中"
            "从裁剪结果的 cmap 反读产出。要扩大覆盖:改脚本里的 UNICODE_RANGES 后重跑。"
        ),
        "family": "Noto Sans SC",
        "source": "Noto Sans SC Version 2.004-H2",
        "files": [out for _, out in SOURCES],
        "codepointCount": len(covered),
        # [start, end] 闭区间,按起点升序 —— 运行时用二分查找
        "ranges": to_ranges(covered),
    }
    manifest_path = args.out_dir / "coverage.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    print(
        f"  coverage.json                                  "
        f"{manifest_path.stat().st_size / 1024:5.1f} KB  "
        f"({len(covered)} 码位 / {len(manifest['ranges'])} 个区间)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
