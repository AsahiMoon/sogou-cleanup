# 搜狗输入法精简脚本（保留账号同步 + 皮肤）

你已经装好了**官方原版搜狗输入法**，这个仓库里的脚本帮你在它基础上做"后处理"：
去掉广告、推广、全家桶和自动更新，同时**完整保留**账号登录与词库同步、皮肤商城与皮肤、正常打字。

适用于 Windows 上的搜狗输入法 16.x（其它 15.x/14.x 版本大概率也能用，靠注册表自动定位安装目录）。

## 快速使用

下载本仓库的两个 `.ps1` 文件，放到同一文件夹，右键用 PowerShell 运行或执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\slim.ps1"
```

脚本会自己申请管理员权限（UAC 点“是”）。默认只是把文件改名为 `*.disabled`，**随时可以恢复**。
想真正删除、减少体积，加 `-Purge` 参数：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\slim.ps1" -Purge
```

撤销所有改动：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\unslim.ps1"
```

## `slim.ps1` 做了什么

### 绝对不动（白名单保护）

账号同步、皮肤、打字依赖的组件，任何情况下都不改名/不删除/不拦网：

- **账号同步**：`userNetSchedule.exe`、`SogouSvc` 服务（保持官方默认 Manual）、`SogouExe.exe`、`acc.dat`、`user.dat`、`usrZone.dat`
- **皮肤商城/皮肤**：`SGMyInput.exe`（CEF 宿主）、`SGWebRender.exe`（渲染）、`SGTool.exe`（换肤/装皮肤）、`SogouComMgr.exe`、`Components\SogouFlash`（动态皮肤控件）、`Components\Theme`、`skin_v3.dat`、`SkinRecent.ini`、`SkinLove.ini`、`SkinMakeSelf.ini`
- **打字核心**：`SogouTSF.ime`、`SogouPY.ime`、`Components\Data`
- **云输入宿主**：`SogouCloud.exe` 保留文件——它是输入法内核宿主，删除会导致皮肤商城/账户页面加载失败、且被输入法反复拉起报错；只通过注册表关闭云候选（随时可开回）。`SGDownload.exe` 保留（皮肤在线下载可能用到）
- **`Components\SGRender`**（约 132MB，含 libcef.dll）：**保留**。它是高级/收费皮肤的 CEF 渲染组件，历史上还与登录页关联，删除有破坏皮肤渲染和账号登录的风险，因此在保护名单内。

### 会精简的部分

- **禁用更新器/推广程序**（改名 + 防火墙拦联网）：
  `PinyinUp.exe`、`Install64.exe`、`SogouImeRepair.exe`、`SGBizLauncher.exe`、
  `SGSmartAssistant.exe`、`SGIGuideHelper.exe`、`sgfeedbackhelper.exe`、
  `crashrpt.exe`、`SogouToolkits.exe`
- **删除推广组件目录**：`biz_center`、`biz_pdf`、`game_center`、`AppBox`、`IChat`、
  `isgpet`、`PicFace`、`WriteSpirit`、`systembeautify`
- **清理 `Components\MobileInput`**（跨屏/跨设备输入，与账号同步和皮肤无关；
  代价是失去手机扫码投字、免登录跨设备复制粘贴）
- **清理全家桶 app**：`sogoupdf`、`fastpdf_sogou`、`kzip_sogou`、`kfastpic_sogou` 等
- **清理广告/更新缓存**：`ShiplyUpdate`、`SGSysToast`、`SGBizConfig`
  （**保留** `cache`、`SGCefCache`、`imepop`——皮肤缓存与 CEF 数据）
- **关闭云输入候选**（注册表，可随时开回），不影响账号词库同步
- **清理旧脚本残留的僵尸防火墙规则**
- **在 hosts 阻断 `dl.pinyin.sogou.com`**：这是组件包下载域名。因为
  `SogouCloud -daemon` / `SGTool -daemon` 常驻且皮肤/账号需要它们，不能靠杀进程阻止
  组件"复活"；改为只拦这个下载域名。皮肤/账户用的是完全不同的域名
  （`pcskin/h5api.sginput.qq.com`、`account.sogou.com`、`imedl.sogoucdn.com`、`res.sogou`），不受影响。

脚本可重复运行：若某推广组件被守护进程重新下载（出现 `X` 与 `X.disabled` 并存），
会先清掉旧副本再重新禁用，保持幂等。

动手前会先把账号/皮肤用户数据完整备份到
`C:\ProgramData\SogouHarden\backup`。

## 设计与安全说明

这个脚本采用**白名单驱动**：任何删除/改名操作前都会检查目标是否在保护名单里，
功能组件一律跳过。这是为了避免常见的精简误伤——

- 误删 `userNetSchedule.exe` / 禁用 `SogouSvc` 会破坏**账号词库同步**；
- 误删 `SogouCloud.exe`、清空 `cache`/`SGCefCache` 会让**“我的历史皮肤”加载不出**；
- 在 hosts 里屏蔽 `pinyin.sogou.com` 等域名会让**账户/皮肤页面连不上网**。

本脚本从不碰 hosts、不碰保护名单里的任何组件。安装目录通过注册表 `InstallLocation`
动态获取，不写死 C 盘（很多机器装在 D 盘或其它分区）。

## 日志与备份

- 精简日志：`C:\ProgramData\SogouHarden\slim-log.txt`
- 回退日志：`C:\ProgramData\SogouHarden\unslim-log.txt`
- 数据备份：`C:\ProgramData\SogouHarden\backup`

如果脚本结束时提示 `opFail > 0`，说明部分项目因权限不足没处理成功——
请确认是以管理员身份运行（UAC 点了“是”）。

## 许可

MIT。脚本按“原样”提供，请自行评估后使用；修改前建议先备份搜狗输入法用户数据。
