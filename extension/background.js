// 点击工具栏图标：已有照片页就切过去，没有就新开一个标签页
chrome.action.onClicked.addListener(async () => {
  const url = chrome.runtime.getURL('wall.html');
  try {
    const contexts = await chrome.runtime.getContexts({ contextTypes: ['TAB'], documentUrls: [url] });
    const ctx = contexts.find(c => c.tabId >= 0);
    if (ctx) {
      await chrome.tabs.update(ctx.tabId, { active: true });
      await chrome.windows.update(ctx.windowId, { focused: true });
      return;
    }
  } catch (e) { /* 旧版本 Chrome 没有 getContexts，直接新开 */ }
  chrome.tabs.create({ url });
});
