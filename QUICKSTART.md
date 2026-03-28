# Lisp-Claw 快速开始指南

## 前提条件

1. **Common Lisp 实现**
   - SBCL (推荐)
   - CCL (Clozure CL)
   - ECL

2. **Quicklisp** - Common Lisp 包管理器

## 安装步骤

### 1. 安装 Quicklisp (如果尚未安装)

```lisp
;; 在 Lisp REPL 中
(require 'sb-bsd-sockets) ; SBCL 示例

;; 下载安装脚本
$ curl -O https://beta.quicklisp.org/quicklisp.lsp

;; 加载并安装
$ sbcl --load quicklisp.lsp
* (quicklisp-quickstart:install)
* (ql:add-to-init-file)
* (quit)
```

### 2. 安装依赖

```lisp
;; 启动 Lisp
$ sbcl

;; 安装依赖
(ql:quickload '(alexandria serapeum bordeaux-threads
                    cl-ppcre split-sequence
                    log4cl uuid osicat))

;; 可选：Web 相关依赖
(ql:quickload '(clack hunchentoot dexador))

;; JSON 处理
(ql:quickload '(json-mop joni))

;; 加密
(ql:quickload '(ironclad cl+ssl))

;; 测试框架
(ql:quickload '(prove parachute))
```

### 3. 加载 Lisp-Claw

```lisp
;; 添加项目路径到 ASDF
(push #p"/path/to/LISP-Claw/" asdf:*central-registry*)

;; 加载系统
(asdf:load-system :lisp-claw)
```

## 基本使用

### 启动网关

```lisp
;; 基本启动
(lisp-claw:run)

;; 自定义端口和地址
(lisp-claw:run :port 18789 :bind "127.0.0.1")

;; 使用配置文件
(lisp-claw:run :config #p"/path/to/config.json")

;; 守护进程模式
(lisp-claw:start :port 18789)
```

### 配置文件

创建 `~/.lisp-claw/lisp-claw.json`:

```json
{
  "agent": {
    "model": "anthropic/claude-opus-4-6",
    "thinkingLevel": "medium"
  },
  "gateway": {
    "port": 18789,
    "bind": "127.0.0.1",
    "auth": {
      "mode": "token",
      "token": "your-secret-token-here"
    }
  },
  "logging": {
    "level": "info",
    "file": "/path/to/lisp-claw.log"
  }
}
```

### 设置 API Key

```bash
# 环境变量方式
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
```

或在配置文件中：

```json
{
  "agent": {
    "providers": {
      "anthropic": {
        "apiKey": "sk-ant-..."
      }
    }
  }
}
```

## WebSocket 连接示例

### JavaScript 客户端

```javascript
// 连接到网关
const ws = new WebSocket('ws://127.0.0.1:18789');

ws.onopen = () => {
  // 发送连接请求
  ws.send(JSON.stringify({
    type: 'req',
    id: '1',
    method: 'connect',
    params: {
      type: 'client',
      name: 'my-client'
    }
  }));
};

ws.onmessage = (event) => {
  const frame = JSON.parse(event.data);
  console.log('Received:', frame);
};

// 发送健康检查
ws.send(JSON.stringify({
  type: 'req',
  id: '2',
  method: 'health'
}));

// 发送消息
ws.send(JSON.stringify({
  type: 'req',
  id: '3',
  method: 'send',
  params: {
    to: '+1234567890',
    message: 'Hello from Lisp-Claw!'
  }
}));
```

### Python 客户端

```python
import websocket
import json

def on_message(ws, message):
    print("Received:", message)

def on_open(ws):
    # Connect
    ws.send(json.dumps({
        "type": "req",
        "id": "1",
        "method": "connect",
        "params": {"type": "client"}
    }))

    # Health check
    ws.send(json.dumps({
        "type": "req",
        "id": "2",
        "method": "health"
    }))

ws = websocket.WebSocketApp(
    "ws://127.0.0.1:18789",
    on_message=on_message,
    on_open=on_open
)

ws.run_forever()
```

## REPL 开发

### 交互式使用

```lisp
;; 启动 REPL 模式
(lisp-claw.main:repl)

;; 手动初始化
(lisp-claw.main:init-subsystems)

;; 创建网关
(defvar *gateway* (lisp-claw.gateway.server:make-gateway
                   :port 18789
                   :bind "127.0.0.1"))

;; 启动网关
(lisp-claw.gateway.server:start-gateway *gateway*)

;; 检查状态
(lisp-claw.gateway.health:health-check)

;; 停止网关
(lisp-claw.gateway.server:stop-gateway *gateway*)
```

### 测试

```lisp
;; 运行测试
(asdf:test-system :lisp-claw)

;; 或手动运行
(in-package #:lisp-claw-tests)
(run-all-tests)
(run-protocol-tests)
```

## 调试

### 启用调试日志

```lisp
;; 在配置文件中设置
{
  "logging": {
    "level": "debug",
    "file": "/path/to/debug.log"
  }
}

;; 或运行时设置
(lisp-claw.utils.logging:setup-logging :level :debug)
```

### 常见问题

**无法连接 WebSocket**
- 检查网关是否启动
- 确认端口和地址正确
- 检查防火墙设置

**API Key 错误**
- 确认环境变量已设置
- 检查 API Key 格式
- 验证账户状态

**内存使用过高**
- 调整会话 TTL
- 启用会话压缩
- 定期清理过期会话

## 下一步

1. **阅读文档**
   - [README.md](README.md) - 项目概述
   - [PROJECT_SUMMARY.md](PROJECT_SUMMARY.md) - 详细总结

2. **开发渠道集成**
   - 参考 `src/channels/base.lisp`
   - 实现特定渠道的连接和消息处理

3. **自定义工具**
   - 使用 `lisp-claw.agent.core:register-tool`
   - 实现自定义工具函数

4. **贡献代码**
   - 提交 Issue 和 PR
   - 添加新的渠道支持
   - 改进文档

## 获取帮助

- 查看项目文档
- 提交 GitHub Issue
- 加入社区讨论
