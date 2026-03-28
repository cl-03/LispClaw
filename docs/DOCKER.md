# Lisp-Claw Docker 部署指南

## 快速开始

### 1. 使用安装脚本 (推荐)

```bash
# 进入项目目录
cd LISP-Claw

# 运行安装脚本
./scripts/docker-setup.sh
```

安装脚本会自动：
- 构建 Docker 镜像
- 生成网关 Token
- 创建配置文件
- 启动网关服务

### 2. 手动部署

#### 构建镜像

```bash
docker build -t lisp-claw:local .
```

#### 运行网关

```bash
# 创建配置目录
mkdir -p ~/.lisp-claw

# 启动网关
docker run -d \
  --name lisp-claw \
  -p 18789:18789 \
  -v ~/.lisp-claw:/home/lisp-claw/.lisp-claw \
  -e LISP_CLAW_GATEWAY_TOKEN="your-secret-token" \
  -e ANTHROPIC_API_KEY="sk-ant-..." \
  lisp-claw:local
```

#### 使用 Docker Compose

```bash
# 设置环境变量
export LISP_CLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
export ANTHROPIC_API_KEY="sk-ant-..."

# 启动服务
docker compose up -d
```

## 配置选项

### 环境变量

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `LISP_CLAW_CONFIG_DIR` | 配置目录 | `~/.lisp-claw` |
| `LISP_CLAW_WORKSPACE_DIR` | 工作目录 | `~/.lisp-claw/workspace` |
| `LISP_CLAW_GATEWAY_PORT` | 网关端口 | `18789` |
| `LISP_CLAW_GATEWAY_BIND` | 绑定地址 | `0.0.0.0` |
| `LISP_CLAW_GATEWAY_TOKEN` | 网关认证 Token | (自动生成) |
| `LISP_CLAW_TZ` | 时区 | `UTC` |
| `ANTHROPIC_API_KEY` | Anthropic API 密钥 | - |
| `OPENAI_API_KEY` | OpenAI API 密钥 | - |

### 配置文件

位置：`~/.lisp-claw/lisp-claw.json`

```json
{
  "agent": {
    "model": "anthropic/claude-opus-4-6",
    "thinkingLevel": "medium"
  },
  "gateway": {
    "port": 18789,
    "bind": "0.0.0.0",
    "auth": {
      "mode": "token",
      "token": "your-secret-token"
    }
  },
  "logging": {
    "level": "info",
    "file": "/home/lisp-claw/.lisp-claw/lisp-claw.log"
  }
}
```

## 使用 CLI

```bash
# 查看帮助
./lisp-claw.sh help

# 启动网关
./lisp-claw.sh gateway --port 18789 --bind 0.0.0.0

# 启动 REPL
./lisp-claw.sh repl

# 健康检查
./lisp-claw.sh health --token your-token

# 查看版本
./lisp-claw.sh version
```

## Docker Compose 命令

```bash
# 查看日志
docker compose logs -f lisp-claw-gateway

# 进入 REPL
docker compose run --rm lisp-claw-repl

# 重启网关
docker compose restart lisp-claw-gateway

# 停止服务
docker compose down

# 查看状态
docker compose ps
```

## 健康检查

```bash
# Liveness probe
curl http://127.0.0.1:18789/healthz

# 使用 Docker
docker compose exec lisp-claw-gateway curl -fsS http://127.0.0.1:18789/healthz
```

## WebSocket 连接

### JavaScript

```javascript
const ws = new WebSocket('ws://127.0.0.1:18789');

ws.onopen = () => {
  ws.send(JSON.stringify({
    type: 'req',
    id: '1',
    method: 'connect',
    params: { type: 'client', name: 'my-client' }
  }));
};

ws.onmessage = (event) => {
  console.log('Received:', JSON.parse(event.data));
};
```

### Python

```python
import websocket
import json

ws = websocket.WebSocket("ws://127.0.0.1:18789")
ws.send(json.dumps({
    "type": "req",
    "id": "1",
    "method": "connect",
    "params": {"type": "client"}
}))
print(ws.recv())
```

## 故障排除

### 网关无法启动

```bash
# 查看日志
docker compose logs lisp-claw-gateway

# 检查端口占用
netstat -tlnp | grep 18789

# 重新构建镜像
docker compose build --no-cache
```

### Token 认证失败

```bash
# 检查 Token 是否正确
echo $LISP_CLAW_GATEWAY_TOKEN

# 重新生成 Token
export LISP_CLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
docker compose restart
```

### 内存使用过高

```bash
# 限制容器内存
docker compose up -d --memory=1g lisp-claw-gateway
```

## 安全建议

1. **生产环境必须设置 Token 认证**
2. **不要将 0.0.0.0 绑定暴露在公网**
3. **使用 HTTPS/WSS 加密传输**
4. **定期更新 API Keys**
5. **限制容器权限**

```yaml
# docker-compose.prod.yml
services:
  lisp-claw-gateway:
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp
```

## 性能优化

### SBCL 优化选项

```bash
# 设置动态空间大小
docker run -e SBCL_CORE_SPACE_SIZE=512 ...

# 启用多线程
docker run -e SBCL_THREAD_STACK_SIZE=8 ...
```

### 日志轮转

```yaml
# docker-compose.yml
services:
  lisp-claw-gateway:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

## 扩展渠道

添加新的渠道支持：

1. 在 `src/channels/` 创建新的渠道实现
2. 在 `registry.lisp` 注册渠道类型
3. 重新构建镜像

```bash
docker compose build
docker compose up -d
```

## 备份和迁移

```bash
# 备份配置
tar czf lisp-claw-backup.tar.gz ~/.lisp-claw

# 恢复配置
tar xzf lisp-claw-backup.tar.gz -C /

# 迁移到新机器
scp lisp-claw-backup.tar.gz user@newhost:
```

## 监控

### Prometheus Metrics (待实现)

```bash
# 启用 metrics 端点
curl http://127.0.0.1:18789/metrics
```

### 日志收集

```yaml
# docker-compose.yml
services:
  lisp-claw-gateway:
    logging:
      driver: "syslog"
      options:
        syslog-address: "udp://localhost:514"
```

## 参考链接

- [README.md](README.md) - 项目概述
- [QUICKSTART.md](QUICKSTART.md) - 快速开始指南
- [OpenClaw 文档](https://docs.openclaw.ai)
