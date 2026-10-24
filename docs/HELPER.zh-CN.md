# iPhone 照片 v0.2（Swift 读取助手）

这个包里有两样东西：

- `extension/`：Chrome 插件（照片墙、预览、导出）。
- 读取助手：装在 Mac 上的小程序，插件通过它读手机。

读取助手用的是苹果系统自带的 ImageCaptureCore（“图像捕捉”App 用的就是它），
**这台 Mac 上什么都不用另装**：不需要 Python、不需要 Homebrew、不需要管理员密码，安装时也不联网。

## 安装读取助手

1. 双击解压下载的 zip。
2. 打开“终端”，输入 `bash `（bash 后面有一个空格），把解压出来的文件夹里的 `install.sh` 拖进终端窗口，按回车。
3. 看到“完成！”就装好了。

装过 0.1 版（Python）的话，旧文件还在，但已经不用了。想腾出空间：`bash install.sh --remove-python`。

## 安装或更新插件

Chrome 直接从文件夹加载插件，**这个文件夹以后不能删、不能挪**，否则插件会失效。
所以先把 `extension` 文件夹放到一个固定的地方，比如“文稿”里新建的 `iPhone 照片` 文件夹。

**第一次装：**

1. Chrome 打开 `chrome://extensions`，打开右上角的“开发者模式”。
2. 点“加载已解压的扩展程序”，选刚才放好的 `extension` 文件夹。
3. 确认插件 ID 是 `endldjnpicempoibdmlndkiinmmekggn`，版本是 0.2.2。
4. 点工具栏的拼图图标，把“iPhone 照片”固定到工具栏。

**已经装过旧版：** 用新的 `extension` 文件夹里的文件替换掉 Chrome 正在用的那个文件夹里的文件
（路径在 `chrome://extensions` 插件卡片的“详细信息”里能看到），再点卡片上的刷新按钮。不要移除插件。

装好后，下载的 zip 和解压出来的其他文件可以删掉，放好的 `extension` 文件夹要留着。

## 先不开 Chrome 测一下

插上 iPhone 并解锁，在终端运行（同样可以把 `selftest.sh` 拖进去）：

```bash
bash selftest.sh
```

它会打印：读取照片目录用时、按格式统计的数量、20 张缩略图用时、放大一张预览的用时，
以及前 5 张照片的机型、镜头、软件、尺寸、有没有 GPS（用来判断以后能做哪些分类）。
第一次连接时手机会问“要信任此电脑吗”，点“信任”。

## 出问题时

- 日志：`~/Library/Logs/iPhonePhotosHelper.log`，第一行写着读取助手的版本。
- 插件显示“还差一步：安装读取助手”：重新运行 `bash install.sh`，然后关掉照片页再打开。
- 一直显示“请解锁 iPhone”：解锁手机，看是否弹出“信任此电脑”。
- 公司电脑如果禁止运行未经认证的程序，或 Chrome 被管理员禁止开发者模式、禁止本机助手，这个插件就用不了，需要找 IT。

## 卸载

```bash
bash uninstall.sh
```

然后在 `chrome://extensions` 里移除插件。已经导出到“下载”的照片不会被删除。
