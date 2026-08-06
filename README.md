[中文](README.md) [English]()



<div align="center">
    <h1>Linux Manager MCP</h1>

    [中文](https://github.com/1234567Yang/) [English](TODO)

    <br>
</div>


> [!CAUTION]
> 本项目属整活项目，请勿在生产环境中使用，请勿在任何有价值的机器上使用，否则后果自负。本项目安全性不做保证。<br>
>【合订本】收录论坛看到的AI删库事故：https://linux.do/t/topic/1585027
---

## 介绍：

让你的大语言模型接入并代理你的 Linux 服务器。和 OpenClaw 不同的是，这是一个 MCP 插件，不需要用 API，而且目前也没有记忆功能。


##  特色：

* 多 shell 窗口，支持后台运行。
  * 当你让 LLM 把某个依赖装上的时候，传统的 MCP 会一直运行直到指令结束或超时强制终止。
  * 本项目支持让 LLM 开多个 shell 窗口，自定义前台等待时间和强制终止时间，并且 LLM 可以随时获取目前的输出来判断状态。
* 每个 shell 窗口都有笔记区域。
  * 方便 LLM 随时获取回忆，这个窗口为什么创建，都干了什么。
* sudo 分离，默认无 sudo 权限。
  * 默认给 LLM 的 shell session 是非 sudo，LLM 需明确指示需要 sudo 时才会开启。
  * sudo 开启权限可在程序中关闭。

## TODO：
更精细的控制划分，log系统。

## 其它：
在此点名批评 A/ 的那个啥jb Cybersecurity filer，操控个 Linux 自动和网安扯上联系，用到一半给我停了要求我换 Sunnet 4.6，纯纯恶心人。