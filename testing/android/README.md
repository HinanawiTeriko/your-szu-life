# Android 真机记录与远程模拟器测试

适用测试主机：Ubuntu 22.04、Intel/AMD x86_64。测试分支为 `test/android-remote-runner`，包含 `38c2768` 初始化导航修复和 `e406806` 旧 WebView 登录兼容修复。上游 PR 使用 `fix/android-onboarding-navigation` 分支。

## 已保存的真机参数

[huawei-nam-al00.json](huawei-nam-al00.json) 保存了 2026-11-07 的真机基线：

| 参数                           | 实测值                                              |
| ------------------------------ | --------------------------------------------------- |
| 机型                           | 华为 NAM-AL00 / HWNAM                               |
| Android / ABI                  | Android 11、API 30、arm64-v8a                       |
| 截图分辨率 / Web 视口          | 1080×2340 / 360×747 CSS 像素                        |
| WebView                        | com.huawei.webview 12.1.2.322，Chrome 92.0.4515.105 |
| CSS `:has()` / GET_COOKIE_INFO | 均不支持                                            |
| Cookie 元数据                  | app_hws_webview/Default/Cookies，Chromium schema 14 |
| 修复后验收                     | 按钮可见可点击、真实账户登录通过、重启恢复认证通过  |

模拟器配置的 480 dpi 由截图与 CSS 宽度比例推算，尚未读取真机的 `wm density`。档案没有 ADB 序列号、IMEI、账户、密码、Cookie 或私钥。原始截图和详细会话诊断留在本地，未上传 GitHub。

Ubuntu 的 x86_64 模拟器使用 x86_64 APK。真机的 ARM64 APK 不直接用于这个 AVD。系统镜像的 Android API、分辨率相近，不代表它拥有华为 WebView；每次测试都要记录实际内核。

旧 WebView 兼容实现只接受已验证的 schema 14。现代系统镜像应验证新版 Cookie API；华为旧内核的认证兼容性仍以原真机验收为依据，不得声称普通 AVD 完整复现了华为环境。

## 拉取仓库

```bash
git clone --branch test/android-remote-runner --single-branch \
  https://github.com/HinanawiTeriko/your-szu-life.git
cd your-szu-life
git rev-parse HEAD
```

后续在这个目录运行 `git pull --ff-only`。主分支仍跟随上游，拉取测试工作请指定上述分支。SDK、NDK、Gradle、Rust 目标库、签名密钥和 APK 均不存入 Git，另一台主机需要安装工具。已有测试应用的 Debug 签名通常与新主机不同；脚本不会为此卸载或清除应用，模拟器建议使用独立测试环境。

## Ubuntu 主机准备

由管理员一次性安装基础工具和 OpenSSH/KVM。以下示例采用专用账户 `codex-test`：

```bash
sudo apt update
sudo apt install -y openssh-server qemu-kvm git curl unzip zip python3 ripgrep \
  build-essential pkg-config libssl-dev
sudo adduser --disabled-password --gecos '' codex-test
sudo usermod -aG kvm codex-test
sudo systemctl enable --now ssh
```

再安装 JDK 21（软件源提供时可运行 `sudo apt install openjdk-21-jdk`）。如果当前 Ubuntu 软件源没有 OpenJDK 21，先从受信任的软件源安装 JDK 21，或安装项目 CI 使用的 JDK 25，再设置 `JAVA_HOME`。项目 Gradle 版本为 9.1.0。Android 构建不需要安装桌面 GTK/WebKit；如果还要跑 Linux Rust 测试，另装桌面依赖与 aria2。

确认 BIOS/云主机已启用虚拟化、能看到 `/dev/kvm`。如果是虚拟机，还需宿主允许嵌套虚拟化。加入 `kvm` 组后重新登录，以新会话生效。账户只需自己的工作目录和 `/dev/kvm` 访问权，日常构建测试不需要 sudo。

在 `codex-test` 的会话里安装 Rust（官方 rustup）、Vite+（官方安装说明）和 Android SDK 命令行工具。然后：

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$HOME/.cargo/bin:$PATH"

sdkmanager --sdk_root="$ANDROID_HOME" --licenses
sdkmanager --sdk_root="$ANDROID_HOME" \
  'platform-tools' 'platforms;android-36' 'build-tools;35.0.0' \
  'ndk;27.0.12077973' 'emulator' 'system-images;android-30;google_apis;x86_64'

rustup toolchain install 1.99.1 --profile minimal
rustup override set 1.99.1
rustup target add x86_64-linux-android aarch64-linux-android
vp install --frozen-lockfile
```

将非敏感的环境变量保存到用户自己的 shell 配置或 `~/szu-test-env.sh`，SSH 执行时显式 `source ~/szu-test-env.sh`；非交互 SSH 不一定读取 `.bashrc`。

可以从仓库的模板复制：`cp testing/android/szu-test-env.example.sh ~/szu-test-env.sh`，核对路径后 `source ~/szu-test-env.sh`。

官方资料：Android [模拟器加速](https://developer.android.com/studio/run/emulator-acceleration)、[命令行参数](https://developer.android.com/studio/run/emulator-commandline)、[SDK 命令行工具](https://developer.android.com/studio)。Rust [安装](https://www.rust-lang.org/tools/install)和 [Vite+ 安装](https://viteplus.dev/guide/)。

## 一次完整测试

脚本默认将运行数据保存在仓库的 `.android-test/`，该目录已被 Git 忽略。默认 Rust/Gradle 并行度为 2；高性能主机可设置 `CARGO_BUILD_JOBS=4 ANDROID_TEST_WORKERS=4`。

```bash
bash scripts/android-test.sh doctor --target x86_64
bash scripts/android-test.sh build --target x86_64
bash scripts/android-test.sh emulator-create
bash scripts/android-test.sh emulator-start
bash scripts/android-test.sh native-test --target x86_64 --serial emulator-5556
```

创建的 AVD 为 `szu-api30-x86_64`，API 30 Google APIs x86_64 镜像，屏幕 1080×2340、480 dpi、4 个虚拟 CPU、4 GiB RAM；无窗口启动，CPU 采用 KVM，图形采用软件渲染。启动等待有时限，失败时日志保存在 `.android-test/emulators/`；超时不会自动清除 AVD 数据。

`build --target x86_64` 是用户为 x86_64 模拟器明确指定的测试构建，不是发布架构变更。默认构建依然是 ARM64，始终只生成一个 ABI 的 APK。当前项目没有官方 x86_64 Android aria2 二进制，模拟器包可能不包含 aria2；下载器相关测试需要另外准备对应目标的二进制，本流程不覆盖它。

`native-test` 只安装 `in.rinne.your_szu_life.onboarding_test` 及其 instrumentation 测试包，指定序列号并核对 ABI、包名、测试目标和两个 APK 的签名；不会卸载应用、重置设置或填写账号。默认运行 `OnboardingNavigationTest`：要求空测试应用的初始化第一步，移除 CSS `:has()` 规则后检查按钮未被覆盖，用触摸事件触发空表单校验。它不会调用真实凭据登录。非空应用会明确失败，而非清除用户数据。

Android 的 `am instrument` 可能在测试失败时也返回进程状态 0，脚本会同时检查 `OK (N tests)`，保证失败不会被误报通过。报告包含设备参数及 instrumentation 结果，保存在 `.android-test/reports/`。

报告的 `build.json` 记录执行测试时的 Git 提交、工作区是否有未提交修改、目标架构及应用/测试 APK 的 SHA-256。提交字段表示当前 checkout，实际安装产物以 SHA-256 标识；切换提交后需重新构建，才能把 APK 与当前代码对应。导航测试还会在 runner 输出中记录 `WEBVIEW_BASELINE`，包含实际 User-Agent、CSS 视口与旧 API 支持情况。仓库新增的 instrumentation 用例已在本机编译通过，Android 单元测试 51 项通过；本机尚未启动这个 AVD。模拟器运行和新测试机的 KVM 能力须在 SSH 接通后实测。

测试结束：

```bash
bash scripts/android-test.sh emulator-stop
```

脚本核对 AVD 名称后只关闭自己选定的模拟器。持续运行的模拟器可以用于后续排查。

## 华为旧内核单独回归

连接支持的 schema-14 真机，先构建 ARM64 包，再明确指定设备序列号和测试类：

```bash
bash scripts/android-test.sh build --target aarch64
adb devices -l
bash scripts/android-test.sh capture --serial YOUR_DEVICE_SERIAL
bash scripts/android-test.sh native-test --target aarch64 --serial YOUR_DEVICE_SERIAL \
  --native-class in.rinne.your_szu_life.LegacyAuthCookieStoreTest
```

`LegacyAuthCookieStoreTest` 使用虚拟 Cookie 验证读取、清除和恢复。真实账户验收需要用户在设备内输入凭据并确认结果，不通过 shell 参数、Git 配置或日志传递密码。

## 给远程测试账户授权 SSH

采用专用账户和专用 Ed25519 公钥，不提供 root 密码、不授予免密码 sudo、不复制 GitHub 私钥或真实账户数据。客户端私钥仅留在运行 Codex 的本机，远程 `authorized_keys` 只放公钥。普通命令行构建、运行模拟器和取回报告只需要 SSH shell 与 SFTP。

管理员把公钥放到 `/home/codex-test/.ssh/authorized_keys`，默认前缀为 `restrict`：

```text
restrict ssh-ed25519 YOUR_PUBLIC_KEY codex-szu-remote-tests
```

目录应由 `codex-test` 拥有，`.ssh` 权限 700、`authorized_keys` 权限 600。`restrict` 禁止 agent/X11/端口转发、PTY 和用户 rc，但保留非交互命令与 SFTP。普通构建无需 PTY；初次软件安装由管理员完成。

如果后续需要转发 WebView 调试端口，把公钥行改为：

```text
restrict,port-forwarding,permitopen="127.0.0.1:18432" ssh-ed25519 YOUR_PUBLIC_KEY codex-szu-remote-tests
```

再由管理员增加 `/etc/ssh/sshd_config.d/codex-test.conf`，限制该账户只允许本地转发到指定端口，关闭远端监听和其他转发：

```text
Match User codex-test
    PasswordAuthentication no
    PermitTTY no
    AllowAgentForwarding no
    X11Forwarding no
    AllowTcpForwarding local
    PermitOpen 127.0.0.1:18432
    PermitTunnel no
Match all
```

运行 `sudo sshd -t` 验证后 `sudo systemctl reload ssh`。如果不需要调试隧道，保持公钥的 `restrict` 即可。这些限制并不把 shell 关在项目目录里；同账户能访问的文件仍可被读取，所以专用账户必须保持独立。需要更强隔离时使用专用虚拟机，不给测试账户访问个人文件或 Docker 管理权限。

本机 SSH 配置示例（私钥文件地址填本机实际路径）：

```text
Host szu-test
    HostName SERVER_IP_OR_NAME
    User codex-test
    Port 22
    IdentityFile /absolute/path/to/szu-test-ed25519
    IdentitiesOnly yes
    ForwardAgent no
    ServerAliveInterval 30
```

通过远程主机终端核对主机公钥指纹，再在本机建立首次 SSH 连接；不要关闭 StrictHostKeyChecking。验证：

```bash
ssh szu-test 'id; test -r /dev/kvm && test -w /dev/kvm && echo KVM-ready'
ssh szu-test 'source ~/szu-test-env.sh; cd ~/your-szu-life; bash scripts/android-test.sh doctor --target x86_64'
```

之后在聊天里提供 SSH 别名或主机、用户名、端口、仓库绝对路径和允许操作范围，例如：“使用 szu-test，在 /home/codex-test/your-szu-life 拉取测试分支、构建、运行模拟器、读取报告；不要操作其他目录或 sudo。”本机工具可能仍需要按 Codex 的当前权限策略审批 SSH 命令；远端公钥授权不会自动改变本机审批策略。

要撤销授权，在远端删除这条专用公钥即可。官方限制说明见 [OpenSSH sshd 手册](https://man.openbsd.org/sshd#AUTHORIZED_KEYS_FILE_FORMAT)。
