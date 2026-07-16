# vhttpd 文档

vhttpd 是一个基于 V 语言与 veb 构建的独立运行时，定位从"传统 PHP 应用服务器"演进为"多协议执行主机"。

<div class="warning">
注意：本文档站点正在建设中，部分内容可能还在整理中。
</div>

## 快速开始

- [快速开始](快速开始.md) - 快速上手 vhttpd
- [项目介绍](项目概述/项目介绍.md) - 了解 vhttpd 的核心概念

## 项目特点

- **多协议支持**：HTTP、WebSocket、SSE、MCP、WebSocket upstream
- **双执行器模型**：PHP Worker（外部进程）+ VJSX（嵌入式）
- **轻量设计**：基于 veb 构建，避免重复造轮子
- **可观测性**：结构化事件日志 + Admin 管理平面

## 相关资源

- [GitHub 仓库](https://github.com/vhttpd/vhttpd)
- [设计文档](../design-docs/)
