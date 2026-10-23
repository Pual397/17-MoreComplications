# 在 macOS 上出包（必需：arm64e ABI 只能由 Apple 的 clang 生成）

## 为什么必须换机器

这台机器（Ubuntu 24.04 + clang 18 + cctools ld64）能产出 arm64e **切片**，但 clang 18 不支持 Apple 的 arm64e ABI v1：产物是 `cpusubtype=0x2, caps=0`（ABI v0），而 iOS 17 系统的 arm64e 进程用 `0x80000002`（ABI v1）。这就是：

- Sileo 判「假 arm64e」——它看的就是 caps 位；
- 转隐根后安全模式——ABI 不匹配，注入 SpringBoard/PosterBoard 后崩溃。

clang 18 连 `-fptrauth-*` 这组选项都没有（已实测：`clang --help | grep ptrauth` 无输出），所以**在这个环境里无法生成合规 arm64e**，再改参数也没用。必须用 Apple 的 clang，也就是 macOS + Xcode。

## 路线 A：有 Mac（最快）

```bash
# 1) 装依赖
brew install ldid make

# 2) Theos + SDK
export THEOS=$HOME/theos
git clone --recursive https://github.com/theos/theos.git "$THEOS"
git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git /tmp/sdks
(cd /tmp/sdks && git sparse-checkout set iPhoneOS16.5.sdk && mkdir -p "$THEOS/sdks" && cp -r iPhoneOS16.5.sdk "$THEOS/sdks/")

# 3) 编译（本目录就是 port/）
cd MoreComplications-port
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

产物在 `packages/`。**校验**（这一步决定 Sileo 会不会说是假的）：

```bash
lipo -info .theos/_/var/jb/Library/MobileSubstrate/DynamicLibraries/MoreComplications.dylib
# 期望：arm64 arm64e
otool -hv .theos/_/var/jb/Library/MobileSubstrate/DynamicLibraries/MoreComplications.dylib
# 期望：ARM64E 那一行的 caps 是 0x80（即 cpusubtype 0x80000002），不是 0x0
```

`caps=0x80` 才是 Sileo 认的真 arm64e。

## 路线 B：没有 Mac，用 GitHub Actions

仓库里已经带好 `.github/workflows/build.yml`（runner 是 `macos-14`，自带 Apple clang，构建完会打印 `lipo -info` 和 `otool -hv` 供核对）。

1. 在 GitHub 建一个空仓库（私有也可以）；
2. 把 `MoreComplications-src.zip` 解压后的内容（`control`、`Makefile`、`tweak/`、`prefs/`、`.github/` 等，直接在 zip 根目录）全部上传/推送；
3. 打开仓库的 **Actions** → “Build” → 等 3–5 分钟；
4. 在该次运行的 **Artifacts** 里下载 `MoreComplications_xxxx.zip`，里面的 deb 就是真 arm64e。

推送方式（任选）：

```bash
# 命令行
git init && git add -A && git commit -m "iOS 17 port + prefs"
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

或者网页端 “Add file → Upload files” 直接拖进去。

## 拿到真包之后

1. 直接装（不需要再做“假 arm64e 转换”）：`dpkg -i xyz.skitty.morecomplications_1.3_iphoneos-arm64.deb`
2. 隐根环境仍需要把 `/var/jb` 路径改写到实际 `JBROOT`（tweak、`PreferenceBundles`、`PreferenceLoader` 三处都要），但**架构部分不要再动**。
3. respring → 设置里先设 Rows → 再编辑锁屏。

## 如果还是安全模式

那说明问题不在架构而在排版逻辑，把安全模式留下的崩溃日志发我（`/var/mobile/Library/Logs/CrashReporter/` 下 `SpringBoard-*.ips` 或 `PosterBoard-*.ips`，以及 `[MoreComplications]` 的 Console 输出），我据此定位是哪个 hook 崩的。
