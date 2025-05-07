<p align="left">
  <a href="README.md">English</a> | 中文
</p>

<div align="center">
  <h1>动态域名地址同步程序: ddnss.sh</h1>
</div>

<p align="center">
  <a href="https://github.com/qingzi-zhang/ddnss.sh/blob/main/LICENSE">
    <img alt="Apache License Version 2.0" src="https://img.shields.io/github/license/qingzi-zhang/ddnss.sh">
  </a>
</p>

- 纯 Shell script 语言编写的动态域名客户端
- 兼容 POSIX 标准 ，已测试通过 bash, dropbear 和 sh
- 支持多种动态域名服务，易于扩展和维护
- 主程序的代码和配置一共不到 30 KB，对运行环境的要求非常低且易于使用

## 已支持的动态域名类型

名称|API 版本|状态
----|:--:|:--:|
腾讯云 DNSPod|v3|✅
华为云 Huaweicloud|v2|✅
No-IP Basic|Default|✅

# 安装
## 先安装运行工具： cURL(命令行数据传输工具) 和 OpenSSL(开源加密命令行工具)
- ***Debian系统***
```
sudo apt update
sudo apt install curl openssl
```
- ***OpenWrt系统***
```
opkg update
opkg install curl openssl-util
```

## 从 github 仓库安装
```
git clone https://github.com/qingzi-zhang/ddnss.sh.git
cd ./ddnss.sh
sh ddnss.sh --install
```

# 配置参数
默认配置在: **`$HOME/.ddnss.sh/ddnss.conf`**，根据需要进行调整
> [!NOTE]
> 可选项
>- DNS_Server: 设置用于查找DDNS记录的DNS服务器
>- Log_Path: 日志文件应放在目录 /var/log/ 或子目录中，并且至少对ddnss.log和ddnss.log.bak文件具有写入的权限

```
DNS_Server=8.8.8.8
Log_Path=/var/log/ddnss
```

> [!TIP]
> - 动态域名记录的格式: DDNS=完整的域名,IP版本,绑定的网卡名,更新记录script的名称,接口标识,接口密钥,eui64后缀(仅适用于IPv6)
>
```
DDNS=ddns.shell-script.net,IPv6,br-lan,update_dnspod_v3.sh,***Replace_API_SecretID_pair***,***Replace_API_SecretKey_pair***,07e2:00cb:0012:aaaa
```

# 使用方法为执行脚本：ddnss.sh
```
Usage:
  ddnss.sh [options]

Options:
  -h, --help           打印帮助信息
  --config=<file>      选项将指定特定的配置文件
  --force-update       选择此选项将对动态域名进行同步 (无论IP地址是否有变化)
  --install            安装 ddnss.sh 到当前的系统
  --log-level=<0|1>    提示等级 (0: 仅提示错误, 1: 提示更多的信息)
```

# 程序运行流程图
## 流程简图
![diagram](svg/Main.svg)
## 主流程图
![diagram](svg/parse_opt.svg)
## 记录处理流程图
![diagram](svg/proc_ddns_rec.svg)