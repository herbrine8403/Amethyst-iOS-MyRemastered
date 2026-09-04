-- PCL Classic（v1 过渡形态）
-- 结构与旧壳 LauncherRootViewController 对齐：左侧竖向导航 + 中间内容区 + 右侧信息面板。
-- M4 将升级为全声明式面板（启动逻辑抽到 LauncherLaunchService 后补全 launch 等动作）。

function describe()
  return { name = "PCL Classic", author = "Pear", version = "1.0" }
end

function build(ui)
  return ui.row {
    id = "shell",
    children = {
      -- 左侧边栏：竖向图标导航（位置由树形结构决定，放最后即右侧）
      ui.column {
        id = "sidebar",
        width = ui.dimen({ phone = 56, pad = 70 }),
        background = "$color:sidebar",
        padding = 8,
        children = {
          ui.nav {
            id = "nav",
            spacing = 14,
            items = {
              { id = "nav.home",           icon = "sf:house.fill",                 action = "open:home" },
              { id = "nav.download",       icon = "sf:arrow.down.circle.fill",     action = "open:download" },
              { id = "nav.versionManager", icon = "sf:cube.transparent.fill",      action = "open:versionManager" },
              { id = "nav.mods",           icon = "sf:puzzlepiece.extension.fill", action = "open:mods" },
              { id = "nav.shaders",        icon = "sf:camera.filters",             action = "open:shaders" },
              { id = "nav.settings",       icon = "sf:gearshape.fill",             action = "open:settings" },
            },
          },
        },
      },
      -- 中间内容区（全树恰好一个）
      ui.content { id = "content", weight = 1, initialPage = "home" },
      -- 右侧信息面板
      ui.panel {
        id = "panel",
        width = ui.dimen({ phone = 168, pad = 220 }),
        background = "$color:surface",
        padding = 12,
        spacing = 10,
        children = {
          ui.text {
            id = "username",
            text = "$i18n:i18n_str_357",
            style = { font = 15, weight = "semibold", color = "$color:textPrimary" },
          },
          ui.text {
            id = "version",
            text = "$i18n:i18n_str_411",
            style = { font = 13, color = "$color:textSecondary" },
          },
          ui.button {
            id = "launch",
            label = "$i18n:i18n_str_412",
            action = "launch",
            corner = 8,
            style = { background = "$color:accent", tint = "#FFFFFF", font = 16, weight = "medium" },
          },
          ui.divider { id = "panel.divider" },
          ui.button {
            id = "panel.chooseVersion",
            label = "$i18n:i18n_str_38",
            action = "open:versionManager",
            style = { color = "$color:textPrimary", font = 14 },
          },
          ui.button {
            id = "panel.account",
            label = "$i18n:i18n_str_357",
            action = "open:accountManager",
            style = { color = "$color:textPrimary", font = 14 },
          },
          ui.button {
            id = "panel.gameDir",
            label = "$i18n:i18n_str_414",
            action = "open:gameDirectory",
            style = { color = "$color:textPrimary", font = 14 },
          },
        },
      },
    },
  }
end

-- 记录初始文案（$i18n 在原生侧解析，Lua 里拿到的是已解析文本）
local defaultUsernameText
local defaultVersionText

function onReady()
  local nameView = launcher.view("username")
  local versionView = launcher.view("version")
  if nameView then defaultUsernameText = nameView:getText() end
  if versionView then defaultVersionText = versionView:getText() end

  local state = launcher.state or {}
  local account = state.account
  if account and account.name and account.name ~= "" and nameView then
    nameView:setText(account.name)
  end
  local version = state.version
  if version and version.name and version.name ~= "" and versionView then
    versionView:setText(version.name)
  end
end

function onAccountChange(account)
  local nameView = launcher.view("username")
  if not nameView then return end
  if account and account.name and account.name ~= "" then
    nameView:setText(account.name)
  else
    nameView:setText(defaultUsernameText or "")
  end
end

function onClick(id)
  -- v1 预留：节点 action 之外需要自定义逻辑的按钮在此分发
end
