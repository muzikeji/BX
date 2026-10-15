# TypeX

TypeX 是一款可自定义键盘快捷操作栏的 iOS 插件。在系统键盘的底部 dock 与键盘上方各提供一排可自由编辑的工具栏，内置 35 种键盘动作，支持六向手势、子动作链、可自由创建的键盘滑动面板与手势面板、桌面状态栏 / Dock 手势、自定义动作（文本 / URL / URL Scheme / 打开应用 / 快捷方式 / JavaScript / 系统动作）、AI 问答面板、剪贴板悬浮粘贴，以及与 ShellX、PullOver X、Kayoko、PixPin 等插件的联动。

## 功能总览

- **双工具栏**：顶部工具栏 + 底部工具栏，拖动排序，两套外观参数相互独立
- **35 种内置键盘动作**：按编辑、删除、选择、光标、工具五组分类展示
- **六向手势**：每个按钮可分别配置单击、长按、上滑、下滑、左滑、右滑；工具栏横向长滑可打开绑定的滑动面板
- **滑动面板**：可创建任意数量的命名面板，分键盘面板（覆盖在键盘上展示）与手势面板（桌面手势呼出）两类；面板顶部内置系统控件（勿扰 / Wi-Fi / 静音 / 蓝牙 / 方向锁 + 亮度 / 音量滑条）
- **桌面手势**：状态栏三分区 × 5 种手势共 15 个独立绑定（含灵动岛中区单击），Dock 上滑 / 左滑 / 右滑三向独立动作
- **子动作链**：每个按钮可挂一条有序子动作链，长按或点按触发
- **自定义动作**：文本、URL、URL Scheme、打开应用、快捷方式、JavaScript、系统动作七类；支持自定义分组、搜索与批量归类；URL Scheme 与打开应用默认由 TypeX 自有悬浮小窗托管打开
- **系统动作**：27 项固定动作（媒体控制、设备操作、控制中心开关与亮度音量）+ 7 项 PixPin 截图（检测到已安装才显示）
- **JavaScript 引擎**：基于 JavaScriptCore 的脚本动作，支持 `$http`、返回候选菜单等
- **AI 问答面板**：多引擎（OpenAI 兼容协议）、流式输出、人设系统、Markdown 渲染
- **剪贴板悬浮粘贴**：剪贴板出现新内容时在光标旁弹出 3 秒悬浮条，点按即粘贴
- **短信验证码提取**：默认关闭，可在设置中开启；从新收到的信息通知中识别明确的数字验证码并自动复制到剪贴板
- **第三方联动**：ShellX 截图、PullOver X「小把手」、Kayoko 剪贴板、PixPin 截图

## 详细功能

### 工具栏

- **顶部工具栏**：寄生于键盘上方（input accessory），固定按「每行个数」自动换行（最多两行），每行个数可调（1–8），最多同时启用 16 个按钮，超出部分自动停用（保留配置）
- **底部工具栏**：寄生于键盘 dock 区域，最多同时启用 8 个按钮，超出部分自动停用（保留配置）
- 按钮：可无限添加，拖动调整顺序，点按编辑 / 删除，开关控制是否显示
- 每工具栏独立的按钮设置：显示样式（图标 / 短文本）、按钮宽度、高度、圆角半径、间距、边框（开关 + 粗细）
- 设置页内置**测试输入框**与**顶部 / 底部工具栏实时预览**（按真实键盘布局渲染），改配置即刻可见

### 内置键盘动作（35 种）

- **编辑**：复制、粘贴、剪切、撤销、重做
- **删除**：向后删除、向前删除、删除单词、清空（删除单词遇标点 / 符号按单字符逐个删除）
- **选择**：全选、选择、选择整行、选择整段、选择整句
- **光标**：左 / 右 / 上 / 下移动、上一个词 / 下一个词、行首 / 行尾、段首 / 段尾、句首 / 句尾、文档开头 / 结尾
- **工具**：收起键盘、查词、ShellX 截图、PixPin 截图（区域截图，安装后可选）、AI 问答、剪贴板（唤起 Kayoko）、小把手（唤起 PullOver X）

### 手势与子动作

- 每个按钮 6 个手势槽位：**单击、长按、上滑、下滑、左滑、右滑**，各自绑定任意动作
- 单击可完全替换按钮原有功能，长按则保留原有功能
- 工具栏横向长滑打开绑定的滑动面板（顶部 / 底部各自的左右长滑独立配置）
- **子动作链**：每个按钮可配置一条按顺序执行的子动作链（可添加多个，任意组合）
- 长按触发子动作：仅配置一个时直接执行，多个时弹出面板选择；「点按触发子动作」开关可让点按也直接触发子动作链
- 子动作面板大小独立设置（顶部 / 底部相互独立）

### 滑动面板

设置 → TypeX → 滑动面板，可创建任意数量的命名面板，分两类：

- **键盘面板**：绑定到顶部 / 底部工具栏的左 / 右长滑，覆盖在键盘上方展示，不打断输入
- **手势面板**：绑定到桌面 Dock 手势与状态栏手势，独立窗口展示

共同特性：

- 面板内容为圆形图标网格：可添加内置动作 / 自定义动作 / 面板跳转，长按拖动排序；列数、内容大小、深浅外观逐面板独立
- 面板顶部内置控制中心样式的系统控件：勿扰、无线网络、铃声静音、蓝牙、方向锁定五个开关与亮度、媒体音量两条滑条，可分别隐藏
- 键盘面板可使用全部动作；手势面板仅支持无需输入的动作（链接、URL Scheme、打开应用、快捷方式、系统动作）

### 桌面手势

- **状态栏手势**：状态栏左 / 中 / 右三分区，每区可独立配置单击、双击、长按、左滑、右滑五个手势，共 15 个绑定；提供总开关与横屏开关。灵动岛中区单击走「中间区域 → 单击」的绑定，未配置时保留系统操作
- **Dock 手势**：主屏幕 Dock 提供上滑、左滑、右滑三组独立开关与动作绑定；上滑默认开启
- 未配置或已关闭的手势保持系统原有行为

### 自定义动作（7 类）

在「自定义动作」页创建，创建后可绑定到任意工具栏按钮、手势槽位、子动作链或滑动面板：

| 类型 | 行为 |
| --- | --- |
| **文本** | 以记录列表管理纯文本，可添加、编辑、删除和排序；一条直接插入，多条显示悬浮列表，点选插入，原样保留空格与换行 |
| **URL** | 打开网址，可选 APP 内打开（内置浏览器）；支持 `@@@` 传入当前输入框内容，可选「剪切替换」 |
| **URL Scheme** | 默认悬浮打开目标应用并传递原始链接，无需 PullOver-X；支持 `@@@` 入参与「剪切替换」，可关闭悬浮开关使用普通跳转 |
| **打开应用** | 通过 Bundle ID 在 TypeX 小窗中打开应用，可操作、拖动，标题栏与应用画面内均可双指等比缩放；点击外部或「-」最小化挂后台，任务切换器保留可恢复卡片；关闭则终止目标进程。关闭悬浮开关可普通打开。小窗默认大小比例与停靠位置（居左 / 居中 / 居右）可在设置的「悬浮面板」页调整，大小比例设为 100% 时全屏打开 |
| **快捷方式** | 执行任意应用长按菜单中的静态 / 动态快捷项 |
| **JavaScript** | 见下节 |
| **系统动作** | 从固定目录选择一项保存（媒体控制、设备操作、控制中心、PixPin 截图等，见下节） |

- 图标支持 **SF Symbols 图标库**（见下节）或**应用 Bundle ID**（显示对应应用图标）
- **自定义分组**：动作可归入命名分组，未分组动作单列「未分组」；分组标题可展开 / 折叠（状态记忆），并提供全部折叠 / 展开；分组管理页可新建、重命名、删除分组（成员自动回落「未分组」）并拖动调整分组顺序
- 管理页：点按行直接编辑、右滑删除；按名称 / 链接 / 分组 / 类型搜索，可再叠加类型筛选；「选择」模式批量全选、移动到分组、取消分组与删除；编辑模式长按拖动排序（分区内）；分组标题行尾按钮以该分组为默认快速新建动作
- **批量添加应用**：一次勾选多个应用批量生成「打开应用」动作，可直接归入指定分组
- 工具栏 / 面板 / 子动作等所有「选择动作」页同样按分组展示并支持搜索

### 系统动作

固定目录共 27 项，另加 7 项 PixPin 截图动作（检测到已安装才显示），均由 SpringBoard 代执行：

- **媒体**：上一首、下一首、播放 / 暂停
- **设备**：返回桌面、打开后台、系统截图、注销（两种）、安全模式、关机、重启设备、重启用户空间
- **控制中心**：打开控制中心、录屏、开麦录屏、手电筒、Wi-Fi、蓝牙、飞行模式、蜂窝数据、方向锁定、勿扰模式、深色模式、亮度增减、音量增减
- **PixPin**：全屏截图、区域截图、冻结截图、即时区域、全屏标记、滚动截图、取消当前任务
- 注销、关机、重启等退出类动作先弹确认框，确认后才执行
- PixPin 与 ShellX 截图直接触发，TypeX 不主动隐藏键盘

### SF 图标库

自定义动作编辑器内置 SF Symbols 图标库：

- 按分类浏览全部符号，支持单列 / 双列 / 三列 / 四列切换
- 支持按符号名全库搜索

### JavaScript 自定义动作

入口为 `async function main(str)`，每次触发创建独立 JavaScriptCore 上下文（无 DOM / Node 环境）：

- **输入**：选区优先（无选区读全文）、全文、剪贴板三种模式
- **输出**：替换 / 插入 / 复制，或返回值驱动：
  - 字符串 → 文本写入
  - `{type, content, title?, args?}` → `txt` / `url` / `urlInApp` / `app` / `function`
  - 数组 → 弹出候选菜单（多项时不抢键盘焦点）
  - `function` → 调用脚本内全局函数，支持异步与后续调用
- **接口**：`$http.get/post/put/patch/delete({url, headers?, body?})`、`$url.open()`、`$url.openInApp()`、`$app.open()`、`console.log`
- 内置**测试脚本页**：网络请求真实发送，文本与跳转动作只预览，日志仅保留在页面内
- 密码框、未完成的输入法组合文本不会执行脚本

#### 脚本示例

以下 10 个示例均可直接粘贴到设置内的「测试脚本页」运行（下述网络示例的请求会真实发送；限定：无 DOM / `fetch` / `setTimeout`，`$http` 返回 UTF-8 字符串需自行 `JSON.parse`，候选菜单最多 100 项，单次 CPU 约 0.5 秒）。

**1. 文本清洗**——去掉每行首尾空白、压缩行内连续空白、删除空行（输入：选区优先；输出：替换）

```js
async function main(str) {
  return str.split('\n')
    .map(line => line.replace(/\s+/g, ' ').trim())
    .filter(Boolean)
    .join('\n');
}
```

**2. 字数统计**——中英混排统计字符 / 英文单词 / 行数（输出：替换或复制）

```js
async function main(str) {
  const chars = Array.from(str.replace(/\s/g, '')).length;
  const words = (str.match(/[A-Za-z0-9'_-]+/g) || []).length;
  const lines = str ? str.split('\n').length : 0;
  return `共 ${chars} 个字符、${words} 个英文单词、${lines} 行`;
}
```

**3. JSON 美化 / 压缩**——弹出候选菜单二选一；解析失败时返回错误说明而不是中断（输出：替换）

```js
async function main(str) {
  try {
    const value = JSON.parse(str);
    return [
      { type: 'txt', title: '格式化（2 空格缩进）', content: JSON.stringify(value, null, 2) },
      { type: 'txt', title: '压缩为单行', content: JSON.stringify(value) },
    ];
  } catch (error) {
    return 'JSON 解析失败：' + error.message;
  }
}
```

**4. 时间戳 ↔ 日期互转**——选中 10 / 13 位时间戳转为本地时间，空输入则给出当前时间与时间戳（输出：替换）

```js
async function main(str) {
  const input = str.trim();
  const pad = n => String(n).padStart(2, '0');
  const fmt = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
                   ` ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  if (/^\d{10}$/.test(input)) return fmt(new Date(Number(input) * 1000));
  if (/^\d{13}$/.test(input)) return fmt(new Date(Number(input)));
  return [
    { type: 'txt', title: '当前时间', content: fmt(new Date()) },
    { type: 'txt', title: '秒级时间戳', content: String(Math.floor(Date.now() / 1000)) },
    { type: 'txt', title: '毫秒级时间戳', content: String(Date.now()) },
  ];
}
```

**5. 编码工具箱**——URL 编解码、HTML 转义、Unicode 码点；解码失败安全兜底（输出：替换）

```js
async function main(str) {
  const safe = fn => { try { return fn(); } catch (e) { return `（解码失败：${e.message}）`; } };
  const html = str.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const points = Array.from(str).map(ch => '\\u' + ch.codePointAt(0).toString(16).padStart(4, '0'));
  return [
    { type: 'txt', title: 'URL 编码', content: encodeURIComponent(str) },
    { type: 'txt', title: 'URL 解码', content: safe(() => decodeURIComponent(str)) },
    { type: 'txt', title: 'HTML 转义', content: html },
    { type: 'txt', title: 'Unicode 码点', content: points.join(' ') },
  ];
}
```

**6. 搜索跳转与快捷面板**——有输入直接跳转搜索（`return null` 表示不写回文本），空输入弹出三类打开方式的候选面板

```js
async function main(str) {
  const q = str.trim();
  if (q) {
    $url.open('https://www.bing.com/search?q=' + encodeURIComponent(q));
    return null; // 已跳转，本次不再写回文本
  }
  return [
    { type: 'url', title: '打开 Bing', content: 'https://www.bing.com' },
    { type: 'urlInApp', title: '应用内打开 Bing', content: 'https://www.bing.com' },
    { type: 'app', title: '打开系统设置', content: 'com.apple.Preferences' },
  ];
}
```

**7. GitHub 用户查询**——`$http.get` + 候选菜单（文本 / 浏览器打开 / 应用内打开）+ `console.log`

```js
async function main(str) {
  const name = str.trim() || 'apple';
  const raw = await $http.get({ url: 'https://api.github.com/users/' + encodeURIComponent(name) });
  const info = JSON.parse(raw);
  console.log('已获取 GitHub 用户：' + info.login);
  return [
    { type: 'txt', title: '昵称', content: String(info.name || info.login) },
    { type: 'txt', title: '粉丝数', content: String(info.followers) },
    { type: 'url', title: '浏览器打开主页', content: info.html_url },
    { type: 'urlInApp', title: '应用内打开主页', content: info.html_url },
  ];
}
```

**8. POST 提交 JSON**——自定义请求头 + `JSON.stringify` 请求体（请求会被真实发送到演示服务）

```js
async function main(str) {
  const raw = await $http.post({
    url: 'https://jsonplaceholder.typicode.com/posts',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title: '来自 TypeX', body: str || '（空输入）', userId: 1 }),
  });
  const created = JSON.parse(raw);
  return '演示帖子已创建，服务端分配 ID：' + created.id;
}
```

**9. 实时天气（免密钥 API）**——输入「纬度，经度」查实时气温风速，留空默认上海

```js
async function main(str) {
  const [lat, lon] = (str.trim() || '31.23,121.47').split(',').map(s => s.trim());
  const url = 'https://api.open-meteo.com/v1/forecast?latitude=' + encodeURIComponent(lat) +
              '&longitude=' + encodeURIComponent(lon) + '&current=temperature_2m,wind_speed_10m';
  const now = JSON.parse(await $http.get({ url })).current;
  return `当前气温 ${now.temperature_2m}°C，风速 ${now.wind_speed_10m} km/h`;
}
```

**10. 掷骰子（函数链）**——候选菜单里点「再掷一次」会继续调用脚本内 `roll` 并再次弹菜单（`function` 类型后续调用上限 16 次，模块级状态在整个会话内保留）

```js
let sides = 6;
async function main(str) {
  sides = Math.min(100, Math.max(2, parseInt(str, 10) || 6));
  return roll();
}
async function roll() {
  const value = Math.floor(Math.random() * sides) + 1;
  return [
    { type: 'txt', title: `🎲 ${value}（${sides} 面骰）`, content: String(value) },
    { type: 'function', title: '再掷一次', content: 'roll', args: [] },
  ];
}
```

更多接口细节与限制、引擎级回归脚本保留在本地开发资料中，不随仓库发布。

### AI 问答

- **引擎**：内置 OpenAI、DeepSeek、Gemini、智谱、通义、豆包、硅基流动，也可添加任意 OpenAI 兼容的自定义引擎；统一 OpenAI 兼容协议（Gemini 走其兼容端点）
- **模型抓取**：按厂商自适应端点拉取模型列表，模型可手动填写
- **人设系统**：自定义人设列表，可设文字问答 / 图片问答 / AI 问答默认；人设即按钮，显示在框选菜单中
- **面板**：流式输出、Markdown 渲染、深色 / 浅色 / 跟随系统主题、相机 / 相册 / 文件附件、复制回复
- 从工具栏「AI问答」动作或文本框选菜单唤起

### 短信验证码提取

- 设置首页「短信验证码 → 自动复制验证码」，默认关闭，同时受 TypeX 总开关控制，开关实时生效。
- 在 SpringBoard 接收新的信息通知正文，识别验证码、校验码、动态码、OTP 等关键词附近的 4–8 位数字，保留前导零；没有明确验证码或存在多个不同候选时跳过。
- 自动复制会替换当前剪贴板；验证码仅在本机可用，3 分钟后过期，不保存短信正文或验证码，不改变短信、已读状态和系统通知展示。
- 同一消息的重复发布只处理一次；启动或重新开启前的旧通知、晚到的旧验证码不会覆盖新验证码。
- 覆盖范围取决于信息通知是否到达且携带正文。关闭通知、隐藏正文、正在查看会话等场景可能无法提取；信息 App 的 iMessage 验证码通知也可能被识别。iOS 16/17 的真实接收路径及锁屏行为仍需设备验收。

### 悬浮 App 底部停靠栏

在「应用悬浮」或底部工具栏设置中开启「底部工具栏显示悬浮 App」，键盘底栏会替代原动作栏显示恢复入口：一行 4 个，最多 8 个，左右滑动查看两页。点击图标再次悬浮打开；点击「−」或小窗外空白处缩小后，该 App 移到第一位，列表回到第一页。同一个 App 不重复占位，关闭小窗会移除对应入口。

超过 8 个时新 App 照常打开，最老的恢复入口退出列表，TypeX 不关闭其进程，后台状态继续由系统管理。只在小窗内容就绪后登记，失败或取消不会挤掉已有入口；恢复按 Bundle ID 打开，不重复执行最初的 URL Scheme。当前悬浮或正常前台使用的 App 暂时不可重复激活。

开关默认关闭；关闭后恢复原动作按钮与手势配置，不关闭 App。停靠记录只在 SpringBoard 内存中维护，重启后清空；锁屏时隐藏。系统回收后台进程后可再次启动，但是否恢复原页面由 App 决定。底栏仅随键盘显示，沿用现有横屏、听写和系统底栏的隐藏条件，不影响上方工具栏、其他面板或地球/听写按钮。iOS 16/17 的真实托管、跨进程触摸、分页与恢复仍须设备验收，编译及主机测试不能代替。

### 剪贴板悬浮粘贴

- 剪贴板出现**新**图片或文本时，在键盘上方、与输入光标等高的屏幕右缘悬浮 3 秒
- 图片显示缩略图，文本显示预览；点按即粘贴到当前输入框
- 开启期间自动放行系统「允许粘贴」询问弹窗
- 按「生效应用」逐应用开关（默认全关），应用选择页支持多选与搜索

### 外观与其他

- 按钮颜色、按钮背景颜色、顶部工具栏背景颜色：跟随系统（自动适配深浅色）或自定义颜色
- 触感反馈开关
- 设置首页下拉**搜索设置**，按名称过滤条目
- **配置备份 / 恢复**：一键导出、导入全部插件配置
- 中英双语界面

## 系统要求

- iOS 15 及以上，arm64 / arm64e
- RootHide 根隐藏环境下的 rootless 越狱（deb 以 roothide 方案打包）
- 与 ActionBar（com.restiveconch.actionbar）、DockX（com.udevs.dockx / com.lindo.dockx）冲突

## 构建

依赖 [Theos](https://github.com/theos/theos)。执行：

```bash
./build.sh
```

脚本会依次构建 `ios16`、`ios17` 两个变体，产物输出到 `packages/ios16/`、`packages/ios17/`，并自动推进 `control` 中的版本号。

## 致谢

特别感谢 **udevs**、**lclrc乌贼**、**Aransh**。

## 许可证

[AGPL-3.0](LICENSE)
