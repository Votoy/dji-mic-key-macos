# 第三方声明

本仓库 MIT 许可证仅覆盖原创代码，不对第三方代码或依赖重新授权，也不授予 DJI 等商标权。状态栏 DJI 字样是系统字体文本，并非官方 logo；项目没有官方背书。

## usokawa/dji-mic-mo

- 项目：<https://github.com/usokawa/dji-mic-mo>
- 使用文件：`dji-mic-mo.py`（USB 版本，不是 BLE 版本）。仓库不内置该脚本，`scripts/mic-battery.sh` 首次运行时下载到 `~/Library/Application Support/DJIMicKey/dji-mic-mo.py`。
- 固定提交：`7c2dd5b0262f35b475193224fca2681d75987e9c`。
- SHA-256：`df29abdf2344a880863f1f55ec61cbb8ca59302cecbdc4724258833d99a601d4`。执行前验证摘要；不匹配时保留缓存并退出。
- 核实日期：2026-10-28。已读取本机下载脚本全文，并比对固定提交的摘要；脚本本身没有许可证头。上游实际许可来自 [LICENSE.md](https://github.com/usokawa/dji-mic-mo/blob/7c2dd5b0262f35b475193224fca2681d75987e9c/LICENSE.md)，为 **BSD-2-Clause**，全文附后。

### 设备写入与配置行为

上游不只是被动状态解析器：

- `poll()` 从 stdin 接收 JSON，进入配置队列；`apply()`、`Node.__setattr__()` 和 `send()` 可写入增益、降噪、低切、自动关机、LED、录音相关参数等，具体取决于设备型号。
- 队列非空时 `apply()` 还会调用 `send_time()` 发送时间同步命令。
- `main()` 在无法取得活动 USB 配置时可能调用 `set_configuration()`，还会尝试分离内核驱动、声明接口；对于非 `0x4011` 型号会切换接口 alternate setting。
- USB 传输队列通过 `usb_dev.write()` 发送命令。

本项目包装脚本将 stdin 重定向为 `/dev/null`，不提供设备参数 JSON，因而不主动触发上述参数写入和时间同步路径。但 USB 初始化和接口管理行为仍存在，不能称为绝对只读，也不能保证对音频没有影响。不要与其他读取器同时争用接口。

### 上游许可原文

```text
Copyright (c) 2026 usokawa_.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## 其他运行依赖

- **PyUSB**：首次运行通过 pip 安装，使用 BSD-3-Clause，许可随安装的发行包提供。不由本项目 MIT 许可证覆盖。
- **libusb**：USB 后端，使用 LGPL-2.1-or-later；由用户的环境提供，本仓库不打包该库。
- **Python、Apple 系统框架及命令行工具**：由各自发行方提供并适用各自条款。
- **Karabiner-Elements**：仅提供可选规则 JSON，不打包其程序；需用户另行安装并遵循其许可证。

重新分发第三方脚本、Python 环境或应用依赖包时，应按对应版本保留许可证和版权声明。
