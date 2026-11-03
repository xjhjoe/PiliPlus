# PiliPlus AutoNext 2.2.0.2 — 固定签名与覆盖安装

本项目为个人测试版。基于官方 PiliPlus 2.2.0.2，保留电视投屏自动连播和播放列表。

## 先说明历史版本

旧「PiliPlus Playlist v3」在 GitHub 临时 Runner 上使用自动生成的 Debug 证书。
其密钥未被保存，因此即使新版包名相同，也**无法用新的证书覆盖安装那个旧版**。
**不要**为了更新而尝试修改签名验证。旧版数据请先在应用内导出备份；
固定签名版首次安装可能需要先卸载旧 v3，然后导入备份。
从第一次固定签名版起，只要一直使用同一份 keystore，后续版本就能直接覆盖升级。

## 在你自己的电脑上生成密钥（只需一次）

需要安装 JDK（含 `keytool`），打开 Windows PowerShell：

```powershell
keytool -genkeypair -v -keystore PiliPlus-AutoNext.jks -storetype PKCS12 -alias autonext -keyalg RSA -keysize 3072 -validity 10000
```

按提示设置安全密码并确认。保存 `PiliPlus-AutoNext.jks`，备份至**私密**位置。
不要把 keystore 上传到 GitHub 公共代码库、Issue、Actions Artifact 或 Release。

复制 Base64 到剪贴板（仅复制到 GitHub Actions Secret，不发到聊天）：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path .\PiliPlus-AutoNext.jks))) | Set-Clipboard
```

## GitHub Actions Secrets

打开仓库：Settings → Secrets and variables → Actions → New repository secret。

| Secret 名称 | 值 |
|---|---|
| `SIGN_KEYSTORE_BASE64` | 刚刚复制的 keystore Base64 |
| `KEYSTORE_PASSWORD` | 创建 keystore 时设置的密码 |
| `KEY_ALIAS` | `autonext` |
| `KEY_PASSWORD` | `autonext` 的私钥密码；PKCS12 通常与 keystore 相同 |

**注意：** 四个 Secret 都要设置。密钥文件与密码要长期保管；密钥丢失后无法让未来版本与固定签名版互相覆盖安装。
千万不要把密码、密钥 Base64、或 JKS 发到公共聊天/Issue。

## 构建和安装

Actions → `AutoNext 2.2.0.2 stable-signature Android` → Run workflow，
选择 `feature/2.2.0.2-autonext-playlist` 分支。编译成功且 Secrets 齐全后，
工作流会把**固定签名**的 arm64 APK 发布到本仓库 GitHub Releases，
包名始终是 `com.example.piliplus.dev.autonextplaylist`。

只有配置固定密钥才会发布可安装更新包；缺少任意 Secret 时，工作流仅检查编译，不会发布临时签名安装包。

后续升级时，始终复用**相同 JKS + 密码 + alias + 包名**，并保持 versionCode 递增。
