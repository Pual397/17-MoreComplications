# MoreComplications — iOS 17 支持补丁

> 结论：**能修，但不是改个版本号就行。** iOS 17 把锁屏小组件的排版接口换掉了，原插件挂的那几个方法在 17 上根本不存在，所以「不生效」。

## 1. 原来是靠什么工作的（iOS 16）

原插件（`xyz.skitty.morecomplications` 1.0，作者 Skitty，2024-02-21 发布，商店描述只写 *Supports iOS 16*）注入到加载了 `CoverSheetKit.framework` 的进程里，`%hook` 了 `CSGraphicComplicationLayoutProvider` 的三个类方法：

| 方法 | 作用 |
| --- | --- |
| `+canAddElement:toElements:` | 放开「一行最多 2 个小组件」的数量限制 |
| `+complicationContainerHeight` | 把小组件容器高度按行数放大 |
| `+_framesForLayoutElements:containerSize:` | 关键：拿到 元素→`NSValue(CGRect)` 的字典，把原有单行排版成多行 |

前两个在 iOS 17 上还在，第三个**没了**——于是「能加元素、容器也变高了，但没有行间排布」，或者干脆看不到效果。

## 2. iOS 17 到底改了什么（有据可查）

对照 iOS 17 的运行时头文件（[MTACS/iOS-17-Runtime-Headers](https://github.com/MTACS/iOS-17-Runtime-Headers)，`PrivateFrameworks/CoverSheetKit.framework/`）：

```objc
// iOS 17 CSGraphicComplicationLayoutProvider.h（节选）
+ (id)_framesForLayoutElements:(id)elements layoutStyle:(long long)style containerSize:(CGSize)size;
+ (id)_rowFramesForLayoutElements:(id)elements containerSize:(CGSize)size;
+ (id)_sidebarFramesForLayoutElements:(id)elements containerSize:(CGSize)size;
+ (bool)canAddElement:(id)element toElements:(id)elements;
+ (bool)canAddElement:(id)element toElements:(id)elements layoutStyle:(long long)style;
+ (id)complicationLayoutForElements:(id)elements containerSize:(CGSize)size;
+ (id)complicationLayoutForElements:(id)elements layoutStyle:(long long)style containerSize:(CGSize)size;
+ (id)complicationLayoutForElements:(id)elements layoutStyle:(long long)style containerSize:(CGSize)size
                    draggedElement:(id)element draggedElementPosition:(CGPoint)pos;
```

三点变化：

1. **`_framesForLayoutElements:containerSize:` 被删掉**，换成了带 `layoutStyle` 的版本，并且拆出 `_rowFrames…` / `_sidebarFrames…`（17 开始锁屏排版区分「行」和「侧栏」）。
2. **调用方不再收字典**，而是收一个 `CSComplicationLayout` 对象：
   ```objc
   @interface CSComplicationLayout : NSObject
   @property (nonatomic, readonly) long long draggedItemInsertionIndex;
   @property (nonatomic, readonly) NSDictionary *framesByElement;   // 还是 元素→NSValue(CGRect)
   - (instancetype)_initWithFramesByElement:(NSDictionary *)frames draggedItemInsertionIndex:(long long)idx;
   @end
   ```
3. `canAddElement:` 增加了 `layoutStyle:` 版本，编辑器 17 上大概率走新签名。

## 3. 补丁做了什么

`tweak/Tweak.x` / `tweak/Tweak.h` 重写为「一次编译，16/17 都能跑」：

- **保留 iOS 16 路径**：`_framesForLayoutElements:containerSize:` 逻辑不变。
- **新增 iOS 17 路径**：
  - `_framesForLayoutElements:layoutStyle:containerSize:`
  - `complicationLayoutForElements:{containerSize | layoutStyle:containerSize | …draggedElement:…}` 四个变体 —— 用原来的实现按行重算帧，再用 `_initWithFramesByElement:draggedItemInsertionIndex:` 重新包成 `CSComplicationLayout` 返回。
  - `canAddElement:toElements:layoutStyle:` 也放开上限。
- **幂等 + 安全**：只对「所有帧在同一水平线」的单行排版生效；已经是多行、或侧栏（sidebar，纵向排列）的调用一律原样返回。因此多层钩子不会重复偏移，也不会把侧栏排坏。
- **只放宽、不收紧**：`canAddElement:` 只在算得出「放得下」时返回 YES，否则回落到 `%orig`，不会比系统更严格。
- **日志**：装上后在 Console 里搜 `[MoreComplications]`，能看到加载时的系统版本，以及哪条排版路径真的被命中了（`iOS 16 frames path hooked` / `iOS 17 complicationLayout path hooked` 等）——这是判断 17 上是否生效最直接的办法。

## 4. 构建

需要 macOS（或 Linux + Theos + iOS SDK）；Windows 下可用 WSL。

```bash
export THEOS=/path/to/theos
export THEOS_PACKAGE_SCHEME=rootless     # 无根越狱必需；有根环境去掉这行

make clean package                        # 产物在 packages/
```

前置：`prefs/SkittyPrefs` 是 git 子模块（设置面板用到的 `SP*` 控件）。**本目录已经把它 vendor 进来了（13 个文件）**，直接 `make package` 就能连设置面板一起出包；如果你重新 clone 上游，则要 `git submodule update --init --recursive`。

安装：`dpkg -i` / Sileo 装 deb，然后注销一次（设置里也有 Respring 按钮）。放进多行后如果锁屏没反应，先看 Console 日志再判断。

> 1.2 起设置面板已包含在 deb 里：`var/jb/Library/PreferenceBundles/MoreComplications.bundle` + `var/jb/Library/PreferenceLoader/Preferences/MoreComplications.plist`。若用手机端工具转 roothide，这两条路径要一起被改写，否则「设置里不出现」。

## 4.1 本目录已实际编译验证过

在 Ubuntu 24.04 + Theos + iPhoneOS16.5.sdk + clang 18 环境下真实编译并打包成功（不是「理论上能编译」）：

```
==> Compiling Tweak.x (arm64)…
==> Linking tweak MoreComplications (arm64)…
==> Signing MoreComplications…
==> Compiling SkittyPrefs/SPSettingsController.m (arm64)…
==> Linking bundle MoreComplications (arm64)…
dm.pl: building package `xyz.skitty.morecomplications:iphoneos-arm64' in `packages/xyz.skitty.morecomplications_1.2_iphoneos-arm64.deb'
```

产物：`dist/xyz.skitty.morecomplications_1.2_iphoneos-arm64.deb`（rootless 布局 `var/jb/…`，tweak 与设置面板都已 ldid 签名，`minos 16.0`）。

打包时踩到并修掉的两个问题：

1. tweak 里 `[CSComplicationLayout class]` 会强引用类符号，而 tweak 不链接 CoverSheetKit → `undefined symbol: OBJC_CLASS_$_CSComplicationLayout`。已改为 `objc_getClass("CSComplicationLayout")`。
2. 设置面板原 `TARGET` 是 12.0，`@available()` 会生成 `__isPlatformVersionAtLeast` 调用，rootless 链接解析不了 → 已把 `prefs/Makefile` 的部署目标改为 16.0（与 `Depends: firmware (>= 16.0)` 一致），并对 SkittyPrefs 的废弃 API 警告加 `-Wno-error=deprecated-declarations`。

另一个验证：`llvm-strings` 检查最终 dylib，9 个 hook 选择器全部在内——包括 17 专有的
`complicationLayoutForElements:layoutStyle:containerSize:draggedElement:draggedElementPosition:`，
说明 Logos 确实为 17 的入口生成了钩子。

（本次构建只出了 arm64 切片：Linux 上的 lld 18 会把 arm64e 切片也标成 arm64，导致 lipo 合并失败。）


## 4.2 arm64e 这一段踩过的坑（1.2 → 1.3）

### 1.2：只有 arm64，设备直接拒绝

真机报：

```
dlopen_preflight(...MoreComplications.bundle/MoreComplications) => false
  (mach-o file, but is an incompatible architecture (have 'arm64', need 'arm64e'))
```

Settings.app 本体是 arm64e，dyld 不会把 arm64 镜像载入 arm64e 进程。而 Ubuntu 的 `ld64.lld 18` **不认 arm64e**：用 `-target arm64e` 链接出来仍是 `cpusubtype=0`，lipo 还因为「两个切片都是 arm64」拒绝合并。所以 1.2 的 tweak 和设置面板都只有 arm64。

### 1.2.1：手动打 arm64e 标签，仍然不行

`tools/mark-arm64e.py` 把 `cpusubtype` 改成 `0x2` 再 `ldid -S` 重签，arch 检查确实过了，但真机报：

```
dlopen(...): bad bind opcode 0x00
```

原因：arm64e 的 dyld 走 **chained fixups / threaded binds** 这条路，而 lld 18 是按 arm64 的老式 bind opcode 流写的。只改头字段，dyld 仍然按 arm64e 去解析 bind 表，读到全 0 就报 `bad bind opcode`。Sileo 判定「假 arm64e」是对的，这条路走不通。

### 1.3：在 Linux 上编出真正的 arm64e

用 cctools 的 Apple `ld64`（ld64-956.6，configure 里支持 `arm64e`）替换 lld：

```bash
# 1) cctools 依赖 libdispatch 和 libblocksruntime
git clone https://github.com/swiftlang/swift-corelibs-libdispatch && cmake -G Ninja -DCMAKE_INSTALL_PREFIX=/opt/libdispatch ..
ninja && ninja install

# 2) SDK 里只有 .tbd 文本桩，ld64 需要 libtapi 才能读
git clone https://github.com/tpoechtrager/apple-libtapi
INSTALLPREFIX=/opt/libtapi ./build.sh && ./install.sh

# 3) 编 cctools 的 ld64
git clone --recursive https://github.com/tpoechtrager/cctools-port
cd cctools-port/cctools
./configure --prefix=/opt/cctools --target=x86_64-linux-gnu \
  --with-llvm-config=/usr/lib/llvm-18/bin/llvm-config \
  --with-libdispatch=/opt/libdispatch --with-libblocksruntime=/opt/libdispatch \
  --with-libtapi=/opt/libtapi
make -j && make install

# 4) 让 Theos 用这个 ld（clang 通过 -B 找到 /opt/cctools/bin/ld）
cat > $THEOS/toolchain/linux/iphone/bin/clang <<'EOF'
#!/usr/bin/env bash
export LD_LIBRARY_PATH="/opt/libdispatch/lib:/opt/libtapi/lib:${LD_LIBRARY_PATH:-}"
exec /usr/bin/clang -B/opt/cctools/bin "$@"
EOF
chmod +x $THEOS/toolchain/linux/iphone/bin/clang
```

然后 `make ARCHS="arm64 arm64e" FINALPACKAGE=1 package`。1.3 的校验结果（直接从 deb 里解出来逐切片读的）：

```
tweak  -> 167856 bytes
   slice arm64  cpusubtype=0x00000000 chained_fixups=True signature=True
   slice arm64  cpusubtype=0x00000002 chained_fixups=True signature=True
bundle -> 237328 bytes
   slice arm64  cpusubtype=0x00000000 chained_fixups=True signature=True
   slice arm64  cpusubtype=0x00000002 chained_fixups=True signature=True
```

`0x2` 是 CPU_SUBTYPE_ARM64E；两个切片都带 chained fixups、都已 ldid 签名。

一条残留警告：`ld: warning: object file built with an incompatible arm64e ABI`——因为 clang 18 编出的 arm64e 对象是 ABI v0（`caps=0`），而 ld64 956 期望更新的 ABI。它只是警告，产物结构（arch、fixups、签名）都是对的；如果真机上还出现异常，下一步应换 Apple 的 clang（macOS + Xcode 或官方 Theos 工具链），而不是继续在这里打补丁。

`tools/mark-arm64e.py` 是 1.2.1 的临时手段，1.3 起不再需要，留作记录。



## 4.3 行布局（1.6）

真机（iOS 17）确认：多行、容器高度都正常。设置面板从 1.5 起是**中文**；1.6 把行布局收进「高级选项」子页面，主页只留三个常用项。

### 主页

```
总开关     启用插件
行数       行数：2  [- +]
           高级选项 ›          ← 点进去才是行布局
           注销生效（Respring）
鸣谢
```

### 高级选项（子页面 `Advanced.plist`）

一个文本框，语法是「一行一个组合：数量 + 对齐」：

```
2C 1J     第 1 行 2 个居中；第 2 行 1 个两端对齐
1L 2C     第 1 行（单个组件）靠左；第 2 行 2 个居中
2C 2C 1R  三行
(空)      系统自动分行 + 全部居中（= 1.3 的行为）
```

| 字母 | 含义 |
| --- | --- |
| `C` | 居中（默认） |
| `J` | 两端对齐：第一个贴左、最后一个贴右，空隙均分（**该行需 ≥2 个组件**） |
| `L` | 靠左 |
| `R` | 靠右 |

规则：

- 数量是「这一行最多放几个」：组件不够时，后面的行不出现；
- 超出总数的组件继续按系统容量往下排（不会丢）；
- 组件顺序 = 编辑界面里的顺序，所以「谁在第几行」由顺序 + 断行点决定；
- `J` 遇到单组件行自动退化为 `C`，不会把组件拉宽；
- 组件**尺寸不变，只改位置**；
- 最终行数 = max(`行数` 设置, token 个数)，容器高度随之增加；
- 留空 = 自动填充（4 格一行、居中），行为与 1.3 完全一致。

## 5. 需要你在设备上确认的地方（诚实说明）

补丁是基于 iOS 17 的头文件写的。1.3 起已在 iOS 17 真机验证「多行 + 容器变高」可用，1.5 的断行/对齐属于纯几何计算（组件尺寸取自系统返回的帧，只改 x/y）：

1. 每行数量填 `2,1` → 第 1 行 2 个、第 2 行 1 个；
2. 对齐填 `C R` → 第 2 行那个组件贴右边；
3. 对齐填 `J C` → 第 1 行两个组件分贴左右两边；
4. 两个都清空 → 回到自动填充；
5. `J` 看起来没变化，通常是那行只有 1 个组件（按约定退化为居中）；

## 6. 文件变更

```
tweak/Tweak.h             重写：补全 16/17 接口（含 CSComplicationLayout）
tweak/Tweak.x             重写：双路径排布 + 幂等单行检测 + 日志
                          1.4：行布局串解析（2C 1J）+ 行内对齐（C/J/L/R）
control                   Version 1.4；Author/Maintainer 标注 DeepSeek (AI-generated)；
                          去掉指向上游仓库的 Depiction（那个页面还是 1.0 的说明）
tools/mark-arm64e.py      1.2.1 的临时打标签脚本（1.3 起不再使用，留作记录）
prefs/Makefile            部署目标 12.0 → 16.0；加 -Wno-error=deprecated-declarations；
                          SDK 固定 16.5（17 SDK 删了 Preferences.framework）
prefs/Resources/Root.plist  Credits 脚注注明 iOS 17 移植/打包由 DeepSeek 生成；
                          1.4 新增 Row layout 文本框（PSTextFieldSpecifier）
prefs/SkittyPrefs/        vendor 进来（上游 git 子模块，13 个文件），保证可直接打包
Makefile                  TARGET 固定 iphone:clang:16.5:16.0（同上，SDK 原因）
README.md                 增加 iOS 17 说明
README-ios17.md           本文
morecomplications-ios17.patch   相对上游的 unified diff
test_layout_logic.py      分行/幂等逻辑的等价 Python 实现 + 用例（8/8 通过）
```

原作者署名保留在设置面板的 Credits 里（`© Skitty 2024`），只是额外标注了这次 iOS 17 移植与打包由 DeepSeek 生成——没有把上游的作者信息抹掉。

`test_layout_logic.py` 不是替代真机测试，只是把「贪心分行 + 只对单行生效」这套判断单独跑一遍，确认：
2 个 2 格元素保持单行、3 个 2 格元素折成两行、两个满宽元素各占一行、4 个 1 格元素仍单行、
3 行时 4 个元素排成 2+2、`rows=1` 不动、已是多行不动、侧栏（纵向）不动。
