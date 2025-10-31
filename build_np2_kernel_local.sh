#!/bin/bash
set -e
START_TIME=$(date +%s)
echo "===== 编译开始于: $(date) ====="
echo

# ===== 获取脚本目录 =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ===== 设置自定义参数 =====
echo "===== Nothing Phone 2 (5.10) KernelSU 本地编译脚本 (LTS Toolchain) ====="
echo ">>> 读取用户配置..."

# 从 fastbuild_nothing_minimal.yml 衍生的默认值
DEFAULT_KERNEL_NAME="android12-9-00047-g4968e29b7f92-ab12786767"
ANDROID_VERSION="android12"
KERNEL_VERSION="5.10"

read -p "请输入自定义内核后缀（默认：${DEFAULT_KERNEL_NAME}）: " CUSTOM_SUFFIX
CUSTOM_SUFFIX=${CUSTOM_SUFFIX:-${DEFAULT_KERNEL_NAME}}
read -p "KSU分支版本 (y=SukiSU Ultra, n=KernelSU Next, 默认：y): " KSU_BRANCH
KSU_BRANCH=${KSU_BRANCH:-y}
read -p "应用钩子类型 (manual/syscall/kprobes, m/s/k, 默认m): " APPLY_HOOKS
APPLY_HOOKS=${APPLY_HOOKS:-m}
read -p "是否启用 KPM (仅对SukiSU生效)？(y/n，默认：n): " USE_PATCH_LINUX
USE_PATCH_LINUX=${USE_PATCH_LINUX:-n}


if [[ "$KSU_BRANCH" == "y" || "$KSU_BRANCH" == "Y" ]]; then
  KSU_TYPE="SukiSU Ultra"
  KSU_TYPENAME="SukiSU" # 用于zip命名
else
  KSU_TYPE="KernelSU Next"
  KSU_TYPENAME="KSUNext" # 用于zip命名
fi

if [[ "$USE_PATCH_LINUX" == "y" || "$USE_PATCH_LINUX" == "Y" ]] && [[ "$KSU_BRANCH" == "n" || "$KSU_BRANCH" == "N" ]]; then
  echo "警告：KPM 仅对 SukiSU 生效，已自动禁用。"
  USE_PATCH_LINUX="n"
fi

echo
echo "===== 配置信息 ====="
echo "机型: Nothing Phone 2"
echo "内核版本: $KERNEL_VERSION"
echo "自定义内核后缀: -$CUSTOM_SUFFIX"
echo "KSU分支版本: $KSU_TYPE"
echo "钩子类型: $APPLY_HOOKS"
echo "启用 KPM: $USE_PATCH_LINUX"
echo "===================="
echo

# ===== 创建工作目录 =====
WORKDIR="$SCRIPT_DIR"
# 清理旧的工作目录
if [[ -d ./kernel_workspace/common ]]; then
  cd kernel_workspace
  rm -rf AnyKernel3 KernelSU* SukiSU_patch build-tools kernel_patches susfs4ksu *.sh
else
  rm -rf kernel_workspace
  mkdir kernel_workspace
  cd kernel_workspace
fi
# ===== 安装构建依赖 (参考 builder_6.1.128.sh) =====
echo ">>> 安装构建依赖..."
echo "需要 sudo 权限来安装依赖包..."
sudo apt-get update
sudo apt-get install --no-install-recommends -y \
    curl bison flex binutils dwarves git lld pahole zip perl make gcc \
    python3 python-is-python3 bc libssl-dev libelf-dev aria2 unzip faketime

# ===== 安装 LLVM 20 (来自 builder_6.1.128.sh) =====
echo ">>> 正在安装 LLVM 20 工具链..."
sudo rm -rf ./llvm.sh && wget https://apt.llvm.org/llvm.sh && chmod +x llvm.sh
sudo ./llvm.sh 20 all
echo ">>> LLVM 20 安装完成"

# ===== 初始化内核源码及构建工具 =====
echo ">>> 初始化内核源码及构建工具..."

echo ">>> 正在克隆Nothing Phone内核源码..."
if [[ -d common ]]; then
  cd common
  git restore .
  git clean -fd
  git pull
  cd ..
else
  git clone --depth=1 -b dev https://github.com/TWO666/helloboy017_kernel_pong.git common &
fi
# 注意：clang.zip 已被 llvm.sh 替代，但 build-tools.zip 仍被保留，因为它
# 是 fastbuild_nothing_minimal.yml 的特定依赖
echo ">>> 正在下载构建工具 (build-tools.zip)..."
aria2c -s16 -x16 -k1M https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang20-r547379/build-tools.zip -o build-tools.zip &

wait
echo ">>> 正在解压构建工具..."
unzip -q build-tools.zip
rm -rf build-tools.zip

echo ">>> Nothing Phone内核源码及构建工具初始化完成！"


# ===== 清除 abi 文件、去除 -dirty 后缀 =====
echo ">>> 正在清除 ABI 文件及去除 dirty 后缀..."
rm common/android/abi_gki_protected_exports_* || true

for f in common/scripts/setlocalversion; do
  sed -i 's/ -dirty//g' "$f"
  sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' "$f"
done

# ===== 替换版本后缀 =====
echo ">>> 替换内核版本后缀..."
for f in ./common/scripts/setlocalversion; do
  sed -i "\$s|echo \"\\\$res\"|echo \"-${CUSTOM_SUFFIX}\"|" "$f"
done

# ===== 克隆依赖项目 =====
echo ">>> 克隆依赖项目..."
# AnyKernel3
git clone https://github.com/WildKernels/AnyKernel3.git -b gki-2.0 --depth=1

if [[ "$KSU_BRANCH" == "y" || "$KSU_BRANCH" == "Y" ]]; then
  git clone https://github.com/ShirkNeko/SukiSU_patch.git --depth=1
  git clone https://github.com/ShirkNeko/susfs4ksu.git -b gki-${ANDROID_VERSION}-${KERNEL_VERSION} --depth=1
else
  git clone https://github.com/WildKernels/kernel_patches.git --depth=1
  git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-${ANDROID_VERSION}-${KERNEL_VERSION} --depth=1
fi


echo ">>> 依赖项目克隆完成"

# ===== 拉取 KSU 并设置版本号 =====
# 导出KSU_VERSION 以便zip打包步骤使用
export KSU_VERSION
if [[ "$KSU_BRANCH" == "y" || "$KSU_BRANCH" == "Y" ]]; then
  echo ">>> 拉取 SukiSU-Ultra 并设置版本..."
  curl -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/refs/heads/main/kernel/setup.sh" | bash -s susfs-main
  cd KernelSU
  if grep -qF "static inline void time64_to_tm" "kernel/sulog.c"; then
    wget https://raw.githubusercontent.com/TWO666/Pong_Kernel_Builder/refs/heads/main/patch/revert_rtc_time_compatibility.patch
    git apply revert_rtc_time_compatibility.patch
    rm -f revert_rtc_time_compatibility.patch
  fi

  # === SukiSU Ultra 版本号设置 (来自 GHA) ===
  GIT_COMMIT_HASH=$(git rev-parse --short=8 HEAD)
  echo "当前提交哈希: $GIT_COMMIT_HASH"
  KSU_API_VERSION=$(curl -s "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/susfs-main/kernel/Makefile" | grep -m1 "KSU_VERSION_API :=" | awk -F'= ' '{print $2}' | tr -d '[:space:]')
  [ -z "$KSU_API_VERSION" ] && KSU_API_VERSION="3.1.7"
  
  VERSION_DEFINITIONS=$'define get_ksu_version_full\nv\\$1-'"$GIT_COMMIT_HASH"$'@nothing\nendef\n\nKSU_VERSION_API := '"$KSU_API_VERSION"$'\nKSU_VERSION_FULL := v'"$KSU_API_VERSION"$'-'"$GIT_COMMIT_HASH"$'@nothing'
  
  sed -i '/define get_ksu_version_full/,/endef/d' kernel/Makefile
  sed -i '/KSU_VERSION_API :=/d' kernel/Makefile
  sed -i '/KSU_VERSION_FULL :=/d' kernel/Makefile
  
  awk -v def="$VERSION_DEFINITIONS" '
    /REPO_OWNER :=/ {print; print def; inserted=1; next}
    1
    END {if (!inserted) print def}
  ' kernel/Makefile > kernel/Makefile.tmp && mv kernel/Makefile.tmp kernel/Makefile
  
  KSU_VERSION=$(expr $(git rev-list --count main) + 10700 2>/dev/null || echo 114514)
  export KSU_VERSION
  
  echo "SukiSU版本号: v${KSU_API_VERSION}-${GIT_COMMIT_HASH}@nothing"
  echo "KSUVER (for zip): $KSU_VERSION"
  # === 结束 ===

  cd .. # 返回 kernel_workspace
else
  echo ">>> 拉取 KernelSU Next 并设置版本..."
  curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/next-susfs/kernel/setup.sh" | bash -s next-susfs
  cd KernelSU-Next
  KSU_VERSION=$(expr $(curl -sI "https://api.github.com/repos/pershoot/KernelSU-Next/commits?sha=next&per_page=1" | grep -i "link:" | sed -n 's/.*page=\([0-9]*\)>; rel="last".*/\1/p') "+" 10200)
  export KSU_VERSION
  sed -i "s/DKSU_VERSION=11998/DKSU_VERSION=${KSU_VERSION}/" kernel/Makefile
  echo "KernelSU Next 版本设置为: $KSU_VERSION"
  cd .. # 返回 kernel_workspace
fi


# ===== 应用 KernelSU & SUSFS 补丁 =====
echo ">>> 应用 SUSFS&hook 补丁..."
# 复制SUSFS文件
cp ./susfs4ksu/kernel_patches/50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch ./common/
cp ./susfs4ksu/kernel_patches/fs/* ./common/fs/
cp ./susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/

if [[ "$KSU_BRANCH" == "y" || "$KSU_BRANCH" == "Y" ]]; then
  echo ">>> 正在添加SukiSU Ultra补丁..."
  if [[ "$APPLY_HOOKS" == "m" || "$APPLY_HOOKS" == "M" ]]; then
    cp ./SukiSU_patch/hooks/scope_min_manual_hooks_v1.5.patch ./common/
  fi
  if [[ "$APPLY_HOOKS" == "s" || "$APPLY_HOOKS" == "S" ]]; then
    cp ./SukiSU_patch/hooks/syscall_hooks.patch ./common/
  fi
  cp ./SukiSU_patch/69_hide_stuff.patch ./common/
else
  echo ">>> 正在添加KernelSU Next补丁..."
  if [[ "$APPLY_HOOKS" == "m" || "$APPLY_HOOKS" == "M" ]]; then
    cp ./kernel_patches/next/scope_min_manual_hooks_v1.5.patch ./common/
  fi
  if [[ "$APPLY_HOOKS" == "s" || "$APPLY_HOOKS" == "S" ]]; then
    cp ./kernel_patches/next/syscall_hooks.patch ./common/
  fi
  cp ./kernel_patches/69_hide_stuff.patch ./common/
fi

cd ./common
patch -p1 < 50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch || true

if [[ "$APPLY_HOOKS" == "m" || "$APPLY_HOOKS" == "M" ]]; then
  if [[ "$KSU_BRANCH" == "y" || "$KSU_BRANCH" == "Y" ]]; then
    patch -p1 < scope_min_manual_hooks_v1.5.patch || true
  else
    patch -p1 -N -F 3 < scope_min_manual_hooks_v1.5.patch || true
  fi
fi

if [[ "$APPLY_HOOKS" == "s" || "$APPLY_HOOKS" == "S" ]]; then
  patch -p1 < syscall_hooks.patch || true
fi

patch -p1 < 69_hide_stuff.patch || true

# 为KernelSU Next添加WildKSU管理器支持
if [[ "$KSU_BRANCH" == "n" || "$KSU_BRANCH" == "N" ]]; then
  cd ./drivers/kernelsu
  wget https://github.com/WildKernels/kernel_patches/raw/refs/heads/main/next/susfs_fix_patches/v1.5.12/fix_apk_sign.c.patch
  patch -p2 -N -F 3 < fix_apk_sign.c.patch || true
  cd ../../
fi
cd ../ # 返回 kernel_workspace

# ===== 添加 defconfig 配置项 =====
echo ">>> 添加 defconfig 配置项..."
DEFCONFIG_FILE=./common/arch/arm64/configs/vendor/meteoric_defconfig

# 写入通用 SUSFS/KSU 配置
cat >> "$DEFCONFIG_FILE" <<EOF
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
#添加对 Mountify (backslashxx/mountify) 模块的支持
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
EOF
# (以上所有配置项)
# KPM 配置
if [[ "$USE_PATCH_LINUX" == "y" || "$USE_PATCH_LINUX" == "Y" ]]; then
  echo "CONFIG_KPM=y" >> "$DEFCONFIG_FILE"
fi

# Hook 配置
if [[ "$APPLY_HOOKS" == "k" || "$APPLY_HOOKS" == "K" ]]; then
  echo ">>> 启用 kprobes 钩子..."
  echo "CONFIG_KSU_SUSFS_SUS_SU=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_MANUAL_HOOK=n" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_KPROBES_HOOK=y" >> "$DEFCONFIG_FILE"
else
  echo ">>> 启用 manual/syscall 钩子..."
  echo "CONFIG_KSU_MANUAL_HOOK=y" >> "$DEFCONFIG_FILE"
  echo "CONFIG_KSU_SUSFS_SUS_SU=n" >>  "$DEFCONFIG_FILE"
fi

# 编译优化配置 (来自 GHA)
cat >> "$DEFCONFIG_FILE" <<EOF
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3=n
CONFIG_LTO_CLANG_THIN=y
CONFIG_LTO_CLANG=y
CONFIG_OPTIMIZE_INLINING=y
CONFIG_HEADERS_INSTALL=n
EOF
# (以上所有配置项)
# ===== 禁用 defconfig 检查 =====
echo ">>> 禁用 defconfig 检查..."
sed -i 's/check_defconfig//' ./common/build.config.gki

# ===== 编译内核 =====
echo ">>> 开始编译内核..."

# 设置工具链路径 (仅保留 build-tools)
export PATH="$WORKDIR/kernel_workspace/build-tools/bin:$PATH"

cd common

# === 确定性构建 (来自 GHA) ===
BUILD_START=$(date +"%s")
BUILD_TIMESTAMP="2024-12-11 21:50:47"
export SOURCE_DATE_EPOCH=$(date -d "$BUILD_TIMESTAMP" +%s)
export KBUILD_BUILD_TIMESTAMP="$BUILD_TIMESTAMP"

echo ">>> 正在修改内核源码中的时间戳..."
# 1. 修改 scripts/mkcompile_h 脚本
if [ -f scripts/mkcompile_h ]; then
  cp scripts/mkcompile_h scripts/mkcompile_h.bak
  sed -i 's/`date`/echo "Wed Dec 11 21:50:47 UTC 2024"/' scripts/mkcompile_h
  sed -i 's/`LC_ALL=C date`/echo "Wed Dec 11 21:50:47 UTC 2024"/' scripts/mkcompile_h
  sed -i 's/$(date)/echo "Wed Dec 11 21:50:47 UTC 2024"/' scripts/mkcompile_h
  sed -i 's/\$DATE/echo "Wed Dec 11 21:50:47 UTC 2024"/' scripts/mkcompile_h
fi

# 2. 创建固定的编译时间头文件
mkdir -p include/generated
cat > include/generated/compile.h << 'EOF'
/* This file is auto generated, version 1 */
/* SMP PREEMPT */
#define UTS_MACHINE "aarch64"
#define UTS_VERSION "#1 Wed Dec 11 21:50:47 UTC 2024"
#define LINUX_COMPILE_BY "root"
#define LINUX_COMPILE_HOST "localhost"  
#define LINUX_COMPILE_DOMAIN "(none)"
#define LINUX_COMPILE_TIME "21:50:47"
#define LINUX_COMPILE_DATE "Dec 11 2024"
#define LINUX_COMPILER "clang version 20.0.0git"
EOF
# (以上 'cat' 内容)
echo ">>> 确定性构建时间戳设置完成"
echo ">>> 正在生成 Defconfig..."
# *** 修改点：使用 LLVM=-20 和 HOSTCC=clang (参考 builder_6.1.128.sh) ***
make -j$(nproc --all) LLVM=-20 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC="clang" LD="ld.lld" HOSTCC="clang" HOSTLD="ld.lld" O=out \
  KCFLAGS+=-O2 KCFLAGS+=-Wno-error vendor/meteoric_defconfig

echo ">>> GKI正在使用 faketime 进行编译 (Image)..."
# *** 修改点：使用 LLVM=-20 和 HOSTCC=clang (参考 builder_6.1.128.sh) ***
faketime '2024-12-11 21:50:47' \
make -j$(nproc --all) LLVM=-20 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC="clang" LD="ld.lld" HOSTCC="clang" HOSTLD="ld.lld" O=out \
  KCFLAGS+=-O2 KCFLAGS+=-Wno-error \
  KBUILD_BUILD_TIMESTAMP="Wed Dec 11 21:50:47 UTC 2024" \
  Image
# === 编译结束 ===

BUILD_END=$(date +"%s")
BUILD_TIME=$((BUILD_END - BUILD_START))
echo ">>> 内核编译成功！耗时: ${BUILD_TIME} 秒"

# ===== 选择使用 patch_linux (KPM补丁)=====
OUT_DIR="$WORKDIR/kernel_workspace/common/out/arch/arm64/boot"
if [[ "$USE_PATCH_LINUX" == "y" || "$USE_PATCH_LINUX" == "Y" ]] && [[ "$KSU_BRANCH" == "y" || "$KSU_BRANCH" == "Y" ]]; then
  echo ">>> 使用 patch_linux 工具处理输出..."
  cd "$OUT_DIR"
  wget https://github.com/ShirkNeko/SukiSU_KernelPatch_patch/releases/download/0.12.0/patch_linux
  chmod +x patch_linux
  ./patch_linux
  rm -f Image
  mv oImage Image
  echo ">>> 已成功打上KPM补丁"
else
  echo ">>> 跳过 patch_linux (KPM) 操作"
fi

# ===== 打包 AnyKernel3 =====
cd "$WORKDIR/kernel_workspace"
echo ">>> 清理 AnyKernel3 Git 信息..."
rm -rf ./AnyKernel3/.git

echo ">>> 拷贝内核镜像到 AnyKernel3 目录..."
if [ ! -f "$OUT_DIR/Image" ]; then
    echo "错误：编译产物 $OUT_DIR/Image 未找到！"
    exit 1
fi
cp "$OUT_DIR/Image" ./AnyKernel3/

echo ">>> 进入 AnyKernel3 目录并打包 zip..."
cd "$WORKDIR/kernel_workspace/AnyKernel3"

# ===== 生成 ZIP 文件名 (来自 GHA) =====
# KSU_TYPENAME 和 KSU_VERSION 已在前面步骤中设置
# KERNEL_VERSION 和 CUSTOM_SUFFIX 来自脚本开头的输入
CURRENT_TIME=$(date +'%y%m%d-%H%M%S')
ZIP_NAME="AnyKernel3_${KSU_TYPENAME}_${KSU_VERSION}_${KERNEL_VERSION}_NothingPhone2_${CUSTOM_SUFFIX}_${CURRENT_TIME}.zip"

# ===== 打包 ZIP 文件 =====
echo ">>> 打包文件: $ZIP_NAME"
zip -r9 "../$ZIP_NAME" ./*

ZIP_PATH="$(realpath "../$ZIP_NAME")"
echo ">>> 打包完成 文件所在目录: $ZIP_PATH"


# ===== 计算并显示总耗时 =====
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
MINUTES=$((TOTAL_TIME / 60))
SECONDS=$((TOTAL_TIME % 60))
echo
echo "======================================"
echo ">>> 脚本执行完毕"
echo ">>> 总耗时: ${MINUTES} 分 ${SECONDS} 秒"
echo "======================================"
