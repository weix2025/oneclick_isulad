#!/bin/bash

# Kubernetes 安装脚本

# --- Global Variables ---
DISTRO=""
VERSION=""
# 可以修改为你需要的 Kubernetes 版本
KUBERNETES_VERSION="1.28"

# --- Function Definitions ---

# 函数：检测 Linux 发行版和版本
detect_linux_distro() {
    echo "正在检测 Linux 发行版..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$NAME
        VERSION=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        DISTRO=$(lsb_release -si)
        VERSION=$(lsb_release -sr)
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        DISTRO=$DISTRIB_ID
        VERSION=$DISTRIB_RELEASE
    elif [ -f /etc/debian_version ]; then
        DISTRO=Debian
        VERSION=$(cat /etc/debian_version)
    elif [ -f /etc/redhat-release ]; then
        # 处理 RHEL 系发行版的多种格式
        if grep -iq "centos" /etc/redhat-release; then
            DISTRO="CentOS"
        elif grep -iq "fedora" /etc/redhat-release; then
            DISTRO="Fedora"
        elif grep -iq "rocky" /etc/redhat-release; then
            DISTRO="Rocky"
        elif grep -iq "almalinux" /etc/redhat-release; then
            DISTRO="AlmaLinux"
        elif grep -iq "red hat enterprise linux" /etc/redhat-release; then
             DISTRO="RHEL"
        else
             DISTRO=$(cat /etc/redhat-release | awk '{print $1}') # Fallback
        fi
        VERSION=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release | head -n1)
    else
        DISTRO=$(uname -s)
        VERSION=$(uname -r)
    fi

    DISTRO=$(echo "$DISTRO" | tr '[:upper:]' '[:lower:]') # 标准化为小写

    echo "检测到的发行版: $DISTRO"
    echo "检测到的版本: $VERSION"

    # 可以在这里添加更严格的兼容性检查
    # if [[ "$DISTRO" == "ubuntu" && "$VERSION" < "20.04" ]]; then
    #     echo "错误：不支持 Ubuntu $VERSION。需要 Ubuntu 20.04 或更高版本。"
    #     exit 1
    # fi
    # if [[ ("$DISTRO" == "centos" || "$DISTRO" == "rhel") && "$VERSION" < "7" ]]; then
    #     echo "错误：不支持 $DISTRO $VERSION。需要 7 或更高版本。"
    #     exit 1
    # fi
}

# 函数：禁用 Swap
disable_swap() {
    echo "正在禁用 swap..."
    sudo swapoff -a
    # 检查 /etc/fstab 中是否存在活动的 swap 条目 (非注释行)
    if sudo grep -qE '^\s*[^#].*\s+swap\s+' /etc/fstab; then
        # 使用 sed 创建备份文件并在行首添加 # 来注释掉 swap 行
        sudo sed -i.bak -E 's|^([^#].*\s+swap\s+.*)$|#\1|' /etc/fstab
        echo "Swap 已在 /etc/fstab 中注释掉 (备份文件: /etc/fstab.bak)。"
    else
        echo "/etc/fstab 中未找到活动的 swap 条目或已被注释。"
    fi
}

# 函数：配置内核参数
configure_kernel_params() {
    echo "正在加载内核模块 (overlay, br_netfilter)..."
    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    sudo modprobe overlay
    sudo modprobe br_netfilter

    echo "正在配置 sysctl 参数 (允许 iptables 检查桥接流量, 启用 IP 转发)..."
    cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    # 应用 sysctl 参数而无需重启
    sudo sysctl --system
    echo "内核参数配置完成。"
}

# 函数：安装 containerd
install_containerd() {
    echo "正在安装 containerd..."
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        echo "为 $DISTRO 安装 containerd.io..."
        sudo apt-get update
        sudo apt-get install -y containerd.io
    elif [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" || "$DISTRO" == "fedora" || "$DISTRO" == "rocky" || "$DISTRO" == "almalinux" ]]; then
        echo "为 $DISTRO 安装 containerd.io..."
        # 确保 yum-utils (提供 yum-config-manager) 或 dnf-plugins-core 已安装
        if command -v dnf &> /dev/null; then
             sudo dnf install -y dnf-plugins-core
        else
             sudo yum install -y yum-utils
        fi
        # 添加 Docker 仓库以获取 containerd.io (Kubernetes 官方文档推荐方式)
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

        if command -v dnf &> /dev/null; then
             sudo dnf install -y containerd.io
        else
             sudo yum install -y containerd.io
        fi
    else
         echo "错误：无法为 $DISTRO 自动安装 containerd。请手动安装。"
         exit 1
    fi

    echo "配置 containerd 使用 systemd cgroup driver..."
    sudo mkdir -p /etc/containerd
    # 生成默认配置 (如果不存在)
    if [ ! -f /etc/containerd/config.toml ]; then
        containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
    else
        echo "/etc/containerd/config.toml 已存在，跳过生成默认配置。"
    fi
    # 修改配置文件以使用 systemd cgroup driver
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

    echo "重启并启用 containerd 服务..."
    sudo systemctl restart containerd
    sudo systemctl enable containerd
    echo "containerd 安装和配置完成。"
}

# 函数：安装 cri-o
install_crio() {
    echo "正在安装 cri-o..."
    # 参考: https://github.com/cri-o/cri-o/blob/main/install.md#install-cri-o

    # 确定操作系统标识符，用于 openSUSE Build Service (OBS) 仓库
    local OBS_OS_IDENTIFIER=""
    if [[ "$DISTRO" == "ubuntu" ]]; then
        OBS_OS_IDENTIFIER="xUbuntu_$(echo $VERSION | sed 's/\..*//')" # e.g., xUbuntu_22.04 -> xUbuntu_22
    elif [[ "$DISTRO" == "debian" ]]; then
         OBS_OS_IDENTIFIER="Debian_$(echo $VERSION | sed 's/\..*//')" # e.g., Debian_11
    elif [[ "$DISTRO" == "centos" ]]; then
         OBS_OS_IDENTIFIER="CentOS_$(echo $VERSION | sed 's/\..*//')" # e.g., CentOS_8
    elif [[ "$DISTRO" == "fedora" ]]; then
         OBS_OS_IDENTIFIER="Fedora_$(echo $VERSION)" # e.g., Fedora_38
    elif [[ "$DISTRO" == "rhel" ]]; then
         OBS_OS_IDENTIFIER="CentOS_$(echo $VERSION | sed 's/\..*//')" # RHEL often uses CentOS compatible repos
    elif [[ "$DISTRO" == "rocky" || "$DISTRO" == "almalinux" ]]; then
         OBS_OS_IDENTIFIER="CentOS_$(echo $VERSION | sed 's/\..*//')" # Treat like CentOS
    else
        echo "警告：无法为 $DISTRO $VERSION 自动确定 CRI-O 源标识符。将尝试通用设置 (可能失败)。"
        # 可以选择退出或尝试一个最可能的默认值
        # exit 1
    fi

    local CRIO_K8S_MAJOR_MINOR=$(echo $KUBERNETES_VERSION | grep -oE '^[0-9]+\.[0-9]+') # e.g., 1.28

    echo "使用适用于 $OBS_OS_IDENTIFIER 的 CRI-O v${CRIO_K8S_MAJOR_MINOR} 源..."

    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        echo "为 $DISTRO 添加 CRI-O apt 源..."
        sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates curl gpg software-properties-common

        # OBS GPG Keys
        sudo curl -fsSL "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OBS_OS_IDENTIFIER/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/libcontainers-stable.gpg
        sudo curl -fsSL "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_K8S_MAJOR_MINOR/$OBS_OS_IDENTIFIER/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/libcontainers-crio-$CRIO_K8S_MAJOR_MINOR.gpg

        # Add Repos
        echo "deb [signed-by=/etc/apt/keyrings/libcontainers-stable.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OBS_OS_IDENTIFIER/ /" | sudo tee /etc/apt/sources.list.d/libcontainers-stable.list
        echo "deb [signed-by=/etc/apt/keyrings/libcontainers-crio-$CRIO_K8S_MAJOR_MINOR.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_K8S_MAJOR_MINOR/$OBS_OS_IDENTIFIER/ /" | sudo tee /etc/apt/sources.list.d/libcontainers-crio-$CRIO_K8S_MAJOR_MINOR.list

        sudo apt-get update
        echo "正在安装 cri-o, cri-o-runc, cri-tools..."
        sudo apt-get install -y cri-o cri-o-runc cri-tools

    elif [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" || "$DISTRO" == "fedora" || "$DISTRO" == "rocky" || "$DISTRO" == "almalinux" ]]; then
        echo "为 $DISTRO 添加 CRI-O yum/dnf 源..."
        local CRIO_REPO_BASE_URL="https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable"
        sudo curl -L "${CRIO_REPO_BASE_URL}/$OBS_OS_IDENTIFIER/devel:kubic:libcontainers:stable.repo" -o /etc/yum.repos.d/libcontainers-stable.repo
        sudo curl -L "${CRIO_REPO_BASE_URL}:/cri-o:/$CRIO_K8S_MAJOR_MINOR/$OBS_OS_IDENTIFIER/devel:kubic:libcontainers:stable:cri-o:$CRIO_K8S_MAJOR_MINOR.repo" -o /etc/yum.repos.d/libcontainers-crio-$CRIO_K8S_MAJOR_MINOR.repo

        echo "正在安装 cri-o, cri-tools..."
        if command -v dnf &> /dev/null; then
            sudo dnf install -y cri-o cri-tools
        else
            sudo yum install -y cri-o cri-tools
        fi
    else
        echo "错误：无法为 $DISTRO 自动安装 CRI-O。请手动安装。"
        exit 1
    fi

    echo "启用并启动 cri-o 服务..."
    sudo systemctl daemon-reload
    sudo systemctl enable crio --now
    echo "CRI-O 安装完成。"
}


# 函数：尝试通过添加低优先级源来安装 iSulad 包 (实验性)
install_isulad_experimental_package() {
install_isulad() {
    echo "正在安装 isulad..."
    echo "警告：在非 openEuler 系统上安装 iSulad 强烈建议使用官方提供的安装方式或容器化部署。"
    echo "直接添加 openEuler 源到其他发行版极易导致依赖冲突和系统不稳定。"
    echo "以下代码仅为示例，演示如何通过优先级尝试处理冲突，但【不推荐】在生产环境中使用。"
    echo "请优先参考 iSulad 官方文档针对您的发行版的安装指南！"
    read -p "您确定要继续尝试添加 openEuler 源并设置优先级吗? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "操作已取消。"
        exit 1
    fi

    # --- 配置和安装逻辑 (高度实验性) ---
    # !!! 再次警告：请替换为实际、经过验证的源信息，并充分测试 !!!
    # 查找正确的源：https://repo.openeuler.org/
    # 示例使用的是 openEuler 22.03 LTS 的 everything 源，通常不适合直接添加到其他系统
    ISULAD_REPO_URL="https://repo.openeuler.org/openEuler-22.03-LTS/everything/$(uname -m)/" # 使用架构变量
    ISULAD_GPG_KEY_URL="https://repo.openeuler.org/openEuler-22.03-LTS/everything/$(uname -m)/RPM-GPG-KEY-openEuler"
    ISULAD_REPO_NAME="openeuler-isulad-experimental"

    if [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" || "$DISTRO" == "fedora" || "$DISTRO" == "rocky" || "$DISTRO" == "almalinux" ]]; then
        echo "为 $DISTRO 添加 iSulad YUM/DNF 源 (设置【极低】优先级)..."
        cat <<EOF | sudo tee /etc/yum.repos.d/${ISULAD_REPO_NAME}.repo
[${ISULAD_REPO_NAME}]
name=openEuler iSulad Repository (Experimental - Low Priority)
baseurl=${ISULAD_REPO_URL}
enabled=1
gpgcheck=1
gpgkey=${ISULAD_GPG_KEY_URL}
# 设置极低的优先级 (cost 远大于默认源) 或 (priority 远低于默认源)
cost=2000
# priority=1 # 如果使用 yum-plugin-priorities，设置为最低
EOF
        if command -v dnf &> /dev/null; then
            sudo dnf makecache
            echo "正在使用 dnf 安装 isulad (优先使用系统源依赖)..."
            # 注意：这里可能依然会因为核心库版本冲突而失败
            sudo dnf install -y isulad
        else
            # yum 可能需要 yum-plugin-priorities
            # sudo yum install -y yum-plugin-priorities
            sudo yum makecache fast
            echo "正在使用 yum 安装 isulad (优先使用系统源依赖)..."
            sudo yum install -y isulad
        fi

    elif [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        echo "错误：当前不支持在 Debian/Ubuntu 上通过添加 openEuler RPM 源来安装 iSulad。"
        echo "请查找是否有官方或社区维护的适用于 APT 的 iSulad 仓库，或使用其他容器运行时。"
        exit 1
    else
        echo "错误：当前脚本不支持在 '$DISTRO' 上自动配置 iSulad 源优先级。"
        exit 1
    fi

    # --- 后续步骤 ---
    echo "尝试启用并启动 isulad 服务..."
    if sudo systemctl list-unit-files | grep -q isulad.service; then
        sudo systemctl daemon-reload
        sudo systemctl enable isulad --now
    else
         echo "警告：未找到 isulad.service。可能需要手动启动或服务名不同。"
    fi

    echo "【警告】iSulad 安装尝试完成 (实验性)。已通过设置极低的源优先级来尝试避免冲突。"
    echo "请仔细验证安装是否成功，并检查系统依赖关系是否损坏。"
    echo "强烈建议检查 'dnf repoquery --depends isulad' 或 'yum deplist isulad' 的输出，确认依赖来源。"
}
# --- iSulad 编译安装辅助函数 ---

# 函数：安装 iSulad 编译依赖
_install_isulad_build_deps() {
    echo "--> 正在安装 iSulad 构建依赖..."
    local build_deps_rhel=""
    local build_deps_debian=""

    # RHEL/CentOS/Fedora 等依赖列表 (基于 CentOS 7 和 Ubuntu 脚本推断，可能需调整)
    build_deps_rhel="patch automake autoconf libtool cmake make libcap-devel libselinux-devel libseccomp-devel yajl-devel git libcgroup tar python3 python3-pip device-mapper-devel libcurl-devel zlib-devel glibc-headers openssl-devel gcc gcc-c++ systemd-devel systemd-libs golang libtar-devel which meson ninja-build docbook2x protobuf-devel protobuf-compiler grpc-devel grpc-plugins ncurses-devel libarchive-devel libwebsockets-devel"

    # Debian/Ubuntu 依赖列表 (来自 Ubuntu 20.04 脚本)
    build_deps_debian="g++ systemd libprotobuf-dev protobuf-compiler protobuf-compiler-grpc libgrpc++-dev libgrpc-dev libtool automake autoconf cmake make pkg-config libyajl-dev zlib1g-dev libselinux1-dev libseccomp-dev libcap-dev libsystemd-dev git libarchive-dev libcurl4-gnutls-dev openssl libdevmapper-dev python3 libtar0 libtar-dev libwebsockets-dev runc docbook2x ninja-build meson libncurses-dev patch"

    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        sudo apt-get update && sudo apt-get install -y $build_deps_debian
        if [ $? -ne 0 ]; then echo "错误：安装 Debian/Ubuntu 构建依赖失败。"; return 1; fi
    elif [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" || "$DISTRO" == "fedora" || "$DISTRO" == "rocky" || "$DISTRO" == "almalinux" ]]; then
        if command -v dnf &> /dev/null; then
             sudo dnf install -y $build_deps_rhel
             if [ $? -ne 0 ]; then echo "错误：安装 RHEL/DNF 构建依赖失败。"; return 1; fi
        else
             # CentOS 7 可能需要启用 EPEL
             echo "警告：在 CentOS 7 上可能需要手动启用 EPEL 等附加仓库来满足所有编译依赖。"
             read -p "是否尝试继续安装依赖? (yes/no): " confirm_deps
             if [[ "$confirm_deps" != "yes" ]]; then echo "操作取消。"; return 1; fi
             sudo yum install -y $build_deps_rhel
             if [ $? -ne 0 ]; then echo "错误：安装 RHEL/YUM 构建依赖失败。请检查是否缺少仓库（如 EPEL）。"; return 1; fi
        fi
    else
        echo "错误：不支持的发行版 '$DISTRO' 进行自动编译依赖安装。"
        return 1
    fi
    echo "--> 构建依赖安装完成。"
    return 0
}

# 函数：编译安装 lxc (带优先级处理)
_compile_lxc() {
    local build_dir="$1"
    # repo_url 在函数内部决定
    echo "--> 开始编译 lxc ---"
    # 1. 检查是否已通过包管理器安装
    local pkg_name_deb="lxc-dev"
    local pkg_name_rpm="lxc-devel"
    echo "--> 检查 lxc 开发包是否已通过包管理器安装..."
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        if dpkg -s "$pkg_name_deb" > /dev/null 2>&1; then
            echo "--> $pkg_name_deb 已安装，跳过 lxc 编译。"
            return 0
        fi
    elif [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" || "$DISTRO" == "fedora" || "$DISTRO" == "rocky" || "$DISTRO" == "almalinux" ]]; then
        if rpm -q "$pkg_name_rpm" > /dev/null 2>&1; then
            echo "--> $pkg_name_rpm 已安装，跳过 lxc 编译。"
            return 0
        fi
    fi
    echo "--> 未找到通过包管理器安装的 lxc 开发包，将尝试从源码编译。"

    # 2. 准备克隆
    cd "$build_dir" || return 1
    echo "--> 准备克隆 lxc 源码..."
    local clone_success=false
    # 尝试 GitHub
    echo "尝试从 GitHub ($LXC_GITHUB_REPO) 克隆 lxc..."
    if git clone "$LXC_GITHUB_REPO" lxc; then
        echo "--> 从 GitHub 克隆 lxc 成功。"
        cd lxc || return 1
        clone_success=true
    else
        echo "--> 从 GitHub 克隆 lxc 失败，尝试 Gitee ($LXC_GITEE_REPO)..."
        rm -rf lxc # 清理失败的克隆
        if git clone "$LXC_GITEE_REPO" lxc; then
             echo "--> 从 Gitee 克隆 lxc 成功。"
             cd lxc || return 1
             clone_success=true
        else
             echo "错误：无法从 GitHub 和 Gitee 克隆 lxc 仓库。"
             return 1
        fi
    fi

    # 3. 编译安装 (如果克隆成功)
    if [[ "$clone_success" != true ]]; then return 1; fi # 双重保险
    git clone "$repo_url" || return 1
    cd lxc || return 1
    # 检查并应用补丁 (来自 CentOS 脚本)
    if [[ -f apply-patches ]]; then
        echo "应用 lxc 补丁..."
        # 尝试自动查找版本目录或使用已知版本
        local lxc_ver_dir=$(find . -maxdepth 1 -type d -name 'lxc-*' | head -n 1)
        if [[ -n "$lxc_ver_dir" ]]; then
             git config --global --add safe.directory "$build_dir/lxc/$lxc_ver_dir"
             ./apply-patches || echo "警告：应用 lxc 补丁失败，继续..."
             cd "$lxc_ver_dir" || return 1 # 进入版本目录
        else
             echo "警告：未找到 lxc 版本目录，无法执行 safe.directory 配置和进入目录。"
             ./apply-patches || echo "警告：应用 lxc 补丁失败，继续..."
        fi
    fi
    # 检查并应用 sed 修改 (来自 CentOS 脚本)
    if [[ -f src/lxc/isulad_utils.c ]]; then
         echo "修改 lxc isulad_utils.c (CentOS 7 兼容性)..."
         sudo sed -i 's/return open(rpath, (int)((unsigned int)flags | O_CLOEXEC));/return open(rpath, (int)((unsigned int)flags | O_CLOEXEC), 0);/g' src/lxc/isulad_utils.c
    fi
    echo "配置 lxc (meson)..."
    meson setup -Disulad=true -Dprefix=/usr build || return 1
    echo "编译 lxc..."
    meson compile -C build || return 1
    echo "安装 lxc..."
    sudo meson install -C build || return 1
    echo "--> lxc 编译完成 ---"
    return 0
}

# 函数：编译安装 lcr
_compile_lcr() {
    # lcr 似乎是 openEuler 维护，直接用 Gitee
    local build_dir="$1"
    local repo_url="$2"
    echo "--> 开始编译 lcr ---"
    cd "$build_dir" || return 1
    echo "--> 克隆 lcr 仓库: $repo_url"
    if ! git clone "$repo_url" lcr; then
        echo "错误：克隆 lcr 仓库失败。"
        return 1
    fi
    cd lcr || return 1
    mkdir build
    cd build || return 1
    echo "配置 lcr (cmake)..."
    cmake .. || return 1
    echo "编译 lcr..."
    make -j "$(nproc)" || return 1
    echo "安装 lcr..."
    sudo make install || return 1
    echo "--> lcr 编译完成 ---"
    return 0
}

# 函数：编译安装 clibcni
_compile_clibcni() {
    # clibcni 似乎是 openEuler 维护，直接用 Gitee
    local build_dir="$1"
    local repo_url="$2"
    echo "--> 开始编译 clibcni ---"
    cd "$build_dir" || return 1
    echo "--> 克隆 clibcni 仓库: $repo_url"
     if ! git clone "$repo_url" clibcni; then
        echo "错误：克隆 clibcni 仓库失败。"
        return 1
    fi
    cd clibcni || return 1
    mkdir build
    cd build || return 1
    echo "配置 clibcni (cmake)..."
    cmake .. || return 1
    echo "编译 clibcni..."
    make -j "$(nproc)" || return 1
    echo "安装 clibcni..."
    sudo make install || return 1
    echo "--> clibcni 编译完成 ---"
    return 0
}

# 函数：编译安装 iSulad 主程序
_compile_isulad_main() {
    local build_dir="$1"
    local repo_url="$2"
    echo "--> 开始编译 iSulad ---"
    cd "$build_dir" || return 1
    echo "克隆 iSulad 仓库: $repo_url"
    git clone "$repo_url" || return 1
    cd iSulad || return 1
    # 检查是否需要在 CentOS 上应用 sed 修改
    if [[ "$DISTRO" == "centos" ]]; then
        echo "应用 iSulad CMake 修改 (CentOS 7 兼容性)..."
        # 检查文件是否存在避免错误
        if [[ -f cmake/set_build_flags.cmake ]]; then
           sudo sed -i 's/-O2 -Wall -fPIE/-O2 -Wall -fPIE -std=gnu99/g' cmake/set_build_flags.cmake
        else
           echo "警告: 未找到 cmake/set_build_flags.cmake 文件，跳过 CentOS 7 的 sed 修改。"
        fi
    fi
    mkdir build
    cd build || return 1
    echo "配置 iSulad (cmake)..."
    local cmake_opts=""
    if [[ "$DISTRO" == "centos" ]]; then
        cmake_opts="-DDISABLE_WERROR=on"
    fi
    cmake $cmake_opts .. || return 1
    echo "编译 iSulad..."
    make -j "$(nproc)" || return 1
    echo "安装 iSulad..."
    sudo make install || return 1
    echo "--> iSulad 编译完成 ---"
    return 0
}

# 主编译函数：协调依赖安装和各个组件编译
compile_isulad_from_source() {
    echo "--- 开始从源码编译 iSulad ---"
    echo "警告：编译过程复杂且耗时，请确保网络稳定、磁盘空间和内存充足。"

    # 定义 Git 仓库 URL (集中管理)
    # lxc 优先尝试 GitHub，失败则用 Gitee
    local LXC_GITHUB_REPO="https://github.com/lxc/lxc.git"
    local LXC_GITEE_REPO="https://gitee.com/src-openeuler/lxc.git"
    # lcr 和 clibcni 似乎是 openEuler 维护的，直接用 Gitee
    local LCR_GITEE_REPO="https://gitee.com/openeuler/lcr.git"
    local CLIBCNI_GITEE_REPO="https://gitee.com/openeuler/clibcni.git"
    local ISULAD_REPO="https://gitee.com/openeuler/iSulad.git"

    # 创建临时构建目录
    local BUILD_DIR="/tmp/isulad_build_$$"
    echo "创建临时构建目录: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR" || { echo "错误：无法创建构建目录 $BUILD_DIR"; return 1; }

    # 捕获错误退出时的清理操作
    trap 'echo "编译过程中发生错误，清理构建目录..."; rm -rf "$BUILD_DIR"; return 1' ERR SIGINT SIGTERM

    # 配置环境
    echo "配置编译环境变量和链接库路径..."
    export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH
    export LD_LIBRARY_PATH=/usr/local/lib:/usr/lib:$LD_LIBRARY_PATH
    echo "/usr/local/lib" | sudo tee -a /etc/ld.so.conf > /dev/null
    sudo ldconfig

    # 按顺序执行
    _install_isulad_build_deps || return 1
    # _compile_lxc 现在内部处理 repo URL 优先级
    _compile_lxc "$BUILD_DIR" || return 1
    _compile_lcr "$BUILD_DIR" "$LCR_GITEE_REPO" || return 1
    _compile_clibcni "$BUILD_DIR" "$CLIBCNI_GITEE_REPO" || return 1
    _compile_isulad_main "$BUILD_DIR" "$ISULAD_REPO" || return 1

    # 清理 trap
    trap - ERR SIGINT SIGTERM

    # 清理构建目录 (可选，默认开启)
    local cleanup_build_dir=true
    if [[ "$cleanup_build_dir" = true ]]; then
        echo "清理构建目录 $BUILD_DIR..."
        rm -rf "$BUILD_DIR"
    else
        echo "保留构建目录: $BUILD_DIR"
    fi

    # 尝试启动服务
    echo "更新动态链接库缓存..."
    sudo ldconfig
    echo "尝试启用并启动 isulad 服务..."
    if sudo systemctl list-unit-files | grep -q isulad.service; then
        sudo systemctl daemon-reload
        sudo systemctl enable isulad --now || echo "警告：启动 isulad 服务失败，请检查日志。"
    else
         echo "警告：编译安装后未找到 isulad.service。可能需要手动配置 systemd 服务单元。"
    fi

    echo "--- iSulad 编译安装流程成功结束 ---"
    echo "请检查服务状态和日志确认是否成功。"
    return 0 # 表示成功
}




# 函数：选择并安装容器运行时
select_and_install_container_runtime() {
    echo
    echo "--- 第 4 步：选择并安装容器运行时 ---"
    echo "Kubernetes 需要一个容器运行时接口 (CRI) 实现。请选择一种："
    options=("containerd" "cri-o" "isulad (编译安装)" "isulad (实验性包安装)" "跳过")
    PS3="请选择 [1-${#options[@]}]: " # 设置提示符
    select opt in "${options[@]}"; do
        case $opt in
            "containerd")
                echo "您选择了 containerd。"
                install_containerd
                break
                ;;
            "cri-o")
                echo "您选择了 cri-o。"
                install_crio
                break
                ;;
            "isulad (编译安装)")
                echo "您选择了 从源码编译安装 isulad。"
                compile_isulad_from_source
                break
                ;;
            "isulad (实验性包安装)")
                echo "您选择了 实验性包安装 isulad (不推荐)。"
                install_isulad_experimental_package
                break
                ;;
            "跳过")
                echo "跳过容器运行时安装。您需要手动确保已安装并配置了兼容的 CRI 运行时。"
                break
                ;;
            *)
                echo "无效选项 '$REPLY'，请输入数字 1 到 ${#options[@]}"
                ;;
        esac
    done
}

# 函数：安装 Kubernetes 组件 (kubeadm, kubelet, kubectl)
install_kubernetes_components() {
    echo
    echo "--- 第 5 步：安装 Kubernetes 组件 (kubeadm, kubelet, kubectl) v$KUBERNETES_VERSION ---"
    K8S_APT_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
    K8S_APT_SOURCE="/etc/apt/sources.list.d/kubernetes.list"
    K8S_YUM_REPO="/etc/yum.repos.d/kubernetes.repo"

    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        echo "为 $DISTRO 添加 Kubernetes apt 源..."
        sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates curl gpg

        # 添加 Kubernetes GPG 密钥
        sudo curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/Release.key" | sudo gpg --dearmor -o "$K8S_APT_KEYRING"
        # 添加 Kubernetes apt 仓库
        echo "deb [signed-by=$K8S_APT_KEYRING] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/ /" | sudo tee "$K8S_APT_SOURCE"

        sudo apt-get update
        echo "正在安装 kubelet, kubeadm, kubectl..."
        sudo apt-get install -y kubelet kubeadm kubectl
        sudo apt-mark hold kubelet kubeadm kubectl # 防止自动更新

    elif [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" || "$DISTRO" == "fedora" || "$DISTRO" == "rocky" || "$DISTRO" == "almalinux" ]]; then
        echo "为 $DISTRO 添加 Kubernetes yum/dnf 源..."
        # 定义 Kubernetes YUM/DNF 仓库内容
        cat <<EOF | sudo tee "$K8S_YUM_REPO"
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/rpm/repodata/repomd.xml.key
# 排除 cri-tools 以免和 CRI-O 或 containerd 冲突, kubernetes-cni 通常单独安装
# exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
        # 旧版 Kubernetes (<1.24) 可能需要 exclude=kubernetes-cni

        # 确保 SELinux 处于 permissive 模式
        if sestatus | grep -q "Current mode.*enforcing"; then
            echo "临时设置 SELinux 为 permissive 模式..."
            sudo setenforce 0
            echo "永久设置 SELinux 为 permissive 模式 (需要重启生效)..."
            sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
        else
             echo "SELinux 已处于 non-enforcing 模式。"
        fi

        echo "正在安装 kubelet, kubeadm, kubectl..."
        if command -v dnf &> /dev/null; then
            sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
        else
            sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
        fi

        echo "启用并立即启动 kubelet 服务..."
        # Kubelet 在配置好 CRI 和加入集群前会循环重启，这是正常的
        sudo systemctl enable --now kubelet

    else
        echo "错误：不支持的 Linux 发行版 '$DISTRO' 用于自动安装 Kubernetes 组件。请手动安装。"
        exit 1
    fi

    echo "Kubernetes 组件安装完成。"
    echo "请确保之前选择并安装的容器运行时已正确配置并正在运行。"
    echo "接下来可以使用 'kubeadm init' (在控制平面节点) 或 'kubeadm join' (在工作节点) 来初始化/加入集群。"
}

# --- 主执行逻辑 ---
main() {
    # 检查是否以 root 用户运行
    if [ "$(id -u)" -ne 0 ]; then
       echo "此脚本需要以 root 或使用 sudo 权限运行。" >&2
       # exit 1 # 暂时不强制退出，因为内部命令都用了 sudo
    fi

    echo "--- 开始 Kubernetes 安装准备 ---"

    echo && echo "--- 第 1 步：检测操作系统 ---"
    detect_linux_distro

    echo && echo "--- 第 2 步：禁用 Swap ---"
    disable_swap

    echo && echo "--- 第 3 步：配置内核参数和模块 ---"
    configure_kernel_params

    # 步骤 4 和 5 在函数内部有自己的标题
    select_and_install_container_runtime
    install_kubernetes_components

    echo && echo "--- Kubernetes 安装准备脚本执行完毕 ---"
    echo "请检查上面的输出确认所有步骤是否成功。"
    echo "下一步通常是运行 'kubeadm init' 或 'kubeadm join'。"
}

# --- 脚本入口 ---
# 将所有脚本参数传递给 main 函数 (如果需要处理参数的话)
main "$@"