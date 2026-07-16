# vhttpd 文档

vhttpd 是一个基于 V 语言与 veb 构建的独立运行时，定位从"传统 PHP 应用服务器"演进为"多协议执行主机"。

## 快速开始

- [快速开始](快速开始.md) - 快速上手 vhttpd

## 项目特点

- **多协议支持**: HTTP、WebSocket、SSE、MCP、WebSocket upstream
- **双执行器模型**: PHP Worker（外部进程）+ VJSX（嵌入式）
- **轻量设计**: 基于 veb 构建，避免重复造轮子
- **可观测性**: 结构化事件日志 + Admin 管理平面
