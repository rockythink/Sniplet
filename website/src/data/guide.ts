// Mirrors Sniplet/Onboarding/GuideContent.swift with the default shortcuts; keep both in sync.

export type Shortcut = { keys: string; meaning: string };
export type Block =
  | { kind: 'text'; text: string }
  | { kind: 'list'; items: string[] }
  | { kind: 'shortcuts'; title?: string; items: Shortcut[] }
  | { kind: 'question'; q: string; a: string };
export type Section = { id: string; title: string; blocks: Block[] };

const text = (value: string): Block => ({ kind: 'text', text: value });
const list = (...items: string[]): Block => ({ kind: 'list', items });
const shortcuts = (items: Shortcut[], title?: string): Block => ({ kind: 'shortcuts', title, items });
const question = (q: string, a: string): Block => ({ kind: 'question', q, a });

const global: Shortcut[] = [
  { keys: '⇧⌘A', meaning: '区域截图：拖动框选，单击截窗口，空白处单击截整屏' },
  { keys: '⌃⌥⌘5', meaning: '只选单个窗口，含标题栏、不带投影' },
  { keys: '⌃⌥⌘3', meaning: '截取鼠标所在的整块显示器' },
  { keys: '⌃⌥⌘4', meaning: '重复上次区域，不用重新框选' },
];
const output: Shortcut[] = [
  { keys: 'Return 或 ⌘C', meaning: '复制并关闭' },
  { keys: '⌘S', meaning: '存到选定的文件夹' },
  { keys: '⇧⌘S', meaning: '另存为' },
  { keys: '⌘Return', meaning: '只存入历史并关闭（需开启历史）' },
  { keys: 'Esc', meaning: '放弃这张截图；绘图工具下第一次 Esc 先回到选择' },
];
const tools: Shortcut[] = [
  { keys: 'V', meaning: '选择' }, { keys: 'A', meaning: '箭头' }, { keys: 'R', meaning: '矩形' },
  { keys: 'P', meaning: '画笔' }, { keys: 'T', meaning: '文字' }, { keys: 'N', meaning: '序号' },
  { keys: 'M', meaning: '马赛克' }, { keys: 'H', meaning: '高亮' },
];
const editing: Shortcut[] = [
  { keys: '⌘Z / ⇧⌘Z', meaning: '撤销 / 重做' },
  { keys: 'Delete', meaning: '删除选中的标注' },
  { keys: '方向键', meaning: '移动选中的标注，按住 ⇧ 每次 10 像素' },
  { keys: 'Tab', meaning: '依次选中标注' },
  { keys: '⌘B · ⌘= · ⌘-', meaning: '选中文字时：加粗 · 放大 · 缩小' },
];

export const sections: Section[] = [
  { id: 'first-launch', title: '第一次打开', blocks: [
    list('打开下载的 DMG，把 Sniplet 拖进「应用程序」，再打开它。',
      '欢迎窗口会带你走三步：在菜单栏找到 Sniplet、允许屏幕录制、试截一张。',
      '授权后如果还截不了，点欢迎窗口里的「重新打开 Sniplet」：macOS 常常要重新打开 App 后权限才生效。'),
    text('Sniplet 待在菜单栏里，没有 Dock 图标。之后随时可以从菜单栏「使用指南…」打开这份说明；菜单栏图标被挡住时，再打开一次 Sniplet 也会打开它。'),
  ] },
  { id: 'capture', title: '截图', blocks: [
    shortcuts(global),
    text('选好后可以拖动四边和四角调整范围；切到选择工具（V）后，拖动画面空白处可以移动取景框。调整只在已经定格的画面里裁切，不会重新截屏。'),
    text('区域限制在开始框选的那块显示器，不跨屏拼接。选择时按 Esc 取消。'),
  ] },
  { id: 'annotate', title: '标注', blocks: [
    shortcuts(tools, '切换工具'),
    shortcuts(editing, '编辑'),
    text('工具条上的 ✨ 美化可以给截图加圆角、阴影、边框和背景，还能存为之后新截图的默认样式。截图时按 ? 可以随时查看编辑快捷键。'),
  ] },
  { id: 'output', title: '复制、保存与拖出', blocks: [
    shortcuts(output),
    text('按住右侧的保存按钮拖出，可以把图直接放进聊天窗口、Finder 或其他 App。'),
    text('⌘S 第一次会让你选一个文件夹，之后都直接存进去、同名自动加序号。设置 → 通用 → 存储里可以更换文件夹，或让每次完成截图时自动存一份。'),
  ] },
  { id: 'record-delay', title: '录屏与延迟截图', blocks: [
    text('先选好区域，再用右侧工具条：'),
    list('录制这块区域：放弃这张截图，改为把同一块区域录成 MP4（只有画面，不录声音）。点红框旁的「停止」、再按 ⇧⌘A，或从菜单栏停止。',
      '延迟截图：选 3、5 或 10 秒。选框留在原处、中间倒计时，这期间可以照常打开菜单和悬停提示，时间到先定格再截。再按 ⇧⌘A 或从菜单栏取消。'),
    text('录好的视频可以预览、保存或复制；视频不进截图历史。'),
  ] },
  { id: 'pin', title: '钉图', blocks: [
    text('钉图把最终成图留在屏幕最上层，适合一边对照一边做事。'),
    list('拖动移动位置，双指捏合缩放。', 'Esc 关闭当前钉图；菜单栏可以一次关闭所有钉图。'),
  ] },
  { id: 'history', title: '历史与文字识别', blocks: [
    text('完成的截图会存进本机历史，保留最近 500 张、合计不超过 1 GiB。菜单栏「截图历史…」里可以按图中识别出的文字搜索，再复制、保存、钉图或拖出。'),
    text('历史只保存最终图和识别文字，不保存可以再编辑的标注图层。设置 → 隐私与历史里可以关闭或清空。'),
  ] },
  { id: 'shortcuts', title: '快捷键一览', blocks: [
    shortcuts(global, '全局'),
    shortcuts(output, '输出'),
    shortcuts(tools, '切换工具'),
    shortcuts(editing, '编辑'),
    text('全局快捷键可以在设置 → 快捷键里修改或清除，菜单栏仍然可用。⇧⌘A 会覆盖 Finder 的「前往应用程序」，介意的话可以换一个。'),
  ] },
  { id: 'privacy', title: '权限与隐私', blocks: [
    text('截图需要 macOS 的「屏幕录制」权限。Sniplet 只在你截图或录屏时读取屏幕，录屏不录声音。'),
    text('图像、识别文字和历史都只在本机处理。联网只用于检查和下载更新，可以在设置 → 通用里关闭自动检查。'),
    text('复制的截图只放进本机剪贴板，不参与通用剪贴板同步。马赛克是视觉上的像素化，不保证无法还原。'),
  ] },
  { id: 'questions', title: '常见问题', blocks: [
    question('已经在系统设置里允许了，还是截不了？', 'macOS 常常要重新打开 App 后权限才生效：退出 Sniplet 再打开。仍然不行时，在系统设置 → 隐私与安全性 → 屏幕录制里把 Sniplet 关掉再打开。'),
    question('菜单栏里找不到 Sniplet 图标？', '菜单栏太满时，图标可能被其他图标或刘海挡住。再打开一次 Sniplet（启动台、聚焦搜索或「应用程序」文件夹）就会打开使用指南；截图快捷键也照常可用。'),
    question('按快捷键没有反应？', '这个组合可能被其他 App 占用了。到设置 → 快捷键里换一个，那里会提示冲突。'),
    question('开机后 Sniplet 没有自动打开？', '在设置 → 通用里打开「登录时打开 Sniplet」。'),
    question('怎么更新？', '菜单栏「检查更新…」；也可以在设置 → 通用里打开自动检查。'),
  ] },
];
