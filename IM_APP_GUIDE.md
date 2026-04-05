# Lisp-Claw IM 即时通信 App 使用指南

**版本**: 1.0.0
**日期**: 2026-04-05

---

## 概述

Lisp-Claw IM 是一个内置的即时通信应用，支持：

- ✅ WebSocket 实时通信
- ✅ 用户认证和管理
- ✅ 一对一聊天
- ✅ 群组聊天
- ✅ 消息加密
- ✅ 在线状态追踪
- ✅ 消息历史记录
- ✅ Web 界面

---

## 快速开始

### 1. 启动 IM 服务

```lisp
;; 启动 Lisp-Claw
(ql:quickload :lisp-claw)
(lisp-claw.main:run)
```

IM 服务将自动启动在：
- **WebSocket 端口**: 18790
- **Web 界面**: http://localhost:18791/im

### 2. 访问 Web 界面

打开浏览器访问：http://localhost:18791/im

默认管理员账户：
- **User ID**: admin
- **Password**: admin

### 3. 创建新用户 (API)

```bash
# 使用 curl 创建用户
curl -X POST http://localhost:18791/api/im/register \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "user1",
    "username": "Test User",
    "password": "password123",
    "email": "user@example.com"
  }'
```

---

## API 参考

### 用户管理

#### 登录
```http
POST /api/im/login
Content-Type: application/json

{
  "user_id": "user1",
  "password": "password123"
}

Response:
{
  "status": "success",
  "user": {
    "user_id": "user1",
    "username": "Test User",
    "token": "uuid-token-here"
  }
}
```

#### 获取在线用户
```http
GET /api/im/users

Response:
[
  {
    "user_id": "user1",
    "username": "Test User",
    "status": "online"
  }
]
```

### 消息管理

#### 发送消息
```http
POST /api/im/send
Content-Type: application/json

{
  "conversation_id": "conv-uuid",
  "content": "Hello!",
  "content_type": "text"
}
```

#### 获取消息历史
```http
GET /api/im/messages?conversation_id=conv-uuid&limit=50

Response:
{
  "status": "success",
  "messages": [
    {
      "message_id": "msg-uuid",
      "conversation_id": "conv-uuid",
      "sender_id": "user1",
      "content": "Hello!",
      "content_type": "text",
      "created_at": 1234567890,
      "status": "delivered"
    }
  ]
}
```

### 会话管理

#### 获取用户会话列表
```http
GET /api/im/conversations?user_id=user1

Response:
[
  {
    "conversation_id": "conv-uuid",
    "type": "direct",
    "participants": ["user1", "user2"],
    "updated_at": 1234567890
  }
]
```

### 群组管理

#### 创建群组
```lisp
;; Lisp 代码
(lisp-claw.instant-messaging:create-group
 "My Group"
 "user1"  ; owner-id
 :description "A test group"
 :members '("user2" "user3"))
```

#### 发送群组消息
```lisp
(lisp-claw.instant-messaging:send-group-message
 "group-uuid"
 "user1"
 "Hello everyone!")
```

---

## WebSocket 通信

### 连接 WebSocket

```javascript
const ws = new WebSocket('ws://localhost:18790/ws/im');

ws.onopen = function() {
  // 发送认证
  ws.send(JSON.stringify({
    type: 'auth',
    user_id: 'user1',
    token: 'your-token'
  }));
};

ws.onmessage = function(event) {
  const data = JSON.parse(event.data);
  console.log('Received:', data);
};
```

### 消息类型

#### 聊天消息
```json
{
  "type": "chat",
  "target_id": "user2",
  "content": "Hello!",
  "content_type": "text"
}
```

#### 已读确认
```json
{
  "type": "ack",
  "message_id": "msg-uuid",
  "status": "read"
}
```

#### 输入中指示
```json
{
  "type": "typing",
  "target_id": "user2"
}
```

---

## Lisp API 使用示例

### 创建用户

```lisp
(use-package :lisp-claw.instant-messaging)

;; 创建用户
(create-user "alice" "Alice"
             :email "alice@example.com"
             :password "secret123")

(create-user "bob" "Bob"
             :email "bob@example.com"
             :password "secret456")
```

### 发送消息

```lisp
;; 获取或创建会话
(let ((conv (get-or-create-conversation "alice" "bob")))
  ;; 发送消息
  (make-im-message (conversation-id conv)
                   "alice"
                   "Hi Bob!"
                   :content-type :text
                   :encrypted t))  ; 加密消息
```

### 获取消息历史

```lisp
;; 获取最近 50 条消息
(get-conversation-history (conversation-id conv) :limit 50)
```

### 创建群组

```lisp
;; 创建群组
(let ((group (create-group "Project Team"
                           "alice"
                           :description "Project discussion"
                           :members '("bob" "charlie"))))
  ;; 发送群组消息
  (send-group-message (im-group-id group)
                      "alice"
                      "Welcome to the team!"))
```

### 用户状态管理

```lisp
;; 获取在线用户
(list-online-users)

;; 更新用户状态
(update-user "alice" :status :away)

;; 认证用户
(authenticate-user "alice" "secret123")
```

---

## 数据库存储

### 内存存储

当前实现使用内存哈希表存储：

- `*im-users*` - 用户数据
- `*im-connections*` - WebSocket 连接
- `*im-messages*` - 消息数据
- `*im-conversations*` - 会话数据
- `*im-groups*` - 群组数据

### 持久化 (待实现)

```lisp
;; 未来将支持数据库持久化
;; - SQLite (cl-dbi)
;; - PostgreSQL
;; - Redis
```

---

## 安全特性

### 消息加密

```lisp
;; 发送加密消息
(make-im-message conv-id sender-id content :encrypted t)

;; 消息使用 AES 加密
;; 密钥管理由系统处理
```

### 用户认证

```lisp
;; 密码使用 ironclad 哈希
(hash-password "plain-password")

;; 认证时验证哈希
(verify-password "plain" "hashed-password")
```

### WebSocket 认证

```javascript
// 连接时需要发送认证令牌
ws.send(JSON.stringify({
  type: 'auth',
  user_id: 'user1',
  token: 'valid-token'
}));
```

---

## 配置选项

### 服务器配置

```json
{
  "im": {
    "port": 18790,
    "web-port": 18791,
    "host": "0.0.0.0",
    "max-message-size": 65536,
    "message-retention-days": 30
  }
}
```

---

## 性能优化

### 消息分页

```lisp
;; 获取消息时指定限制
(get-conversation-history conv-id :limit 100)

;; 支持前后翻页
(get-conversation-history conv-id :before "msg-id" :limit 50)
(get-conversation-history conv-id :after "msg-id" :limit 50)
```

### 连接管理

- 自动重连机制
- 心跳检测
- 空闲连接清理

---

## 故障排除

### 常见问题

**问题**: WebSocket 连接失败
```
解决：检查端口 18790 是否被占用，防火墙设置
```

**问题**: 用户认证失败
```
解决：确认密码哈希正确，用户已创建
```

**问题**: 消息无法发送
```
解决：检查会话是否存在，连接是否活跃
```

### 日志查看

```lisp
;; IM 日志输出到 lisp-claw 日志系统
;; 日志级别：debug, info, warn, error
```

---

## 扩展开发

### 添加自定义消息处理器

```lisp
(defun handle-custom-message (user-id data)
  ;; 自定义消息处理逻辑
  )
```

### 添加通知插件

```lisp
;; 监听 IM 事件
(lisp-claw.automation.event-bus:subscribe
 bus "im.message"
 (lambda (event)
   ;; 发送通知
   ))
```

---

## 路线图

### P0 (已完成)
- ✅ 基础用户管理
- ✅ 一对一聊天
- ✅ WebSocket 通信
- ✅ Web 界面

### P1 (进行中)
- [ ] 群组聊天完整支持
- [ ] 文件传输
- [ ] 消息搜索
- [ ] 数据库持久化

### P2 (计划)
- [ ] 消息推送通知
- [ ] 已读回执
- [ ] 消息撤回
- [ ] 表情/贴纸支持

---

**Lisp-Claw IM** - 纯 Common Lisp 实现的即时通信应用
