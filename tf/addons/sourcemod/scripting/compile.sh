#!/bin/bash
# SourceMod 插件快速编译脚本
# 用法: ./compile.sh <文件名>  或直接 ./compile.sh 交互输入

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../plugins"

if [ -f "$SCRIPT_DIR/spcomp64" ]; then
    SPCOMP="$SCRIPT_DIR/spcomp64"
else
    SPCOMP="$SCRIPT_DIR/spcomp"
fi

compile() {
    local sp_file="$1"
    local basename=$(basename "$sp_file")

    if [[ "$basename" != *.sp ]]; then
        basename="${basename}.sp"
    fi

    local src="$SCRIPT_DIR/$basename"
    local smx_name="${basename%.sp}.smx"
    local dest="$OUT_DIR/$smx_name"

    if [ ! -f "$src" ]; then
        echo "❌ 找不到文件: $src"
        return 1
    fi

    echo "🔨 编译: $basename → $smx_name"
    "$SPCOMP" "$src" -o "$dest" -i"$SCRIPT_DIR/include"

    if [ $? -eq 0 ]; then
        echo "✅ 完成: $dest"
    else
        echo "❌ 编译失败，检查上面的报错"
        return 1
    fi
}

mkdir -p "$OUT_DIR"

if [ -n "$1" ]; then
    compile "$1"
else
    read -p "输入 .sp 文件名（可省略后缀）: " filename
    compile "$filename"
fi
