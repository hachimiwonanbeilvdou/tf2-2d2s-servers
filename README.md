# TF2 Competitive Server Configs (MGE + 6s PUG)

基于 Docker 部署的 TF2 竞技服务器配置，包含：
- 🎯 **MGE 训练模式**（1v1 竞技场练枪）
- ⚔️ **6v6 PUG 模式**（竞技比赛）

使用镜像：[melkortf/tf2-competitive](https://github.com/melkortf/tf2-servers)

## 服务器信息

- **服务器名**: 2D2S竞技服 | MGE Winner
- **默认地图**: mge_training_v8_beta4b
- **最大玩家**: 24
- **SourceTV**: 已启用

## 快速部署

### 前置要求

- Docker
- 至少 4GB 可用磁盘空间
- TF2 游戏服务器 Token（[在此获取](https://steamcommunity.com/dev/managegameservers)）

### 一键启动

```bash
# 1. 克隆仓库
git clone https://github.com/hachimiwonanbeilvdou/tf2-servers.git
cd tf2-servers

# 2. 下载地图
bash scripts/download_maps.sh

# 3. 编辑敏感配置
# 修改 tf/cfg/server.cfg:
#   - rcon_password → 改掉
#   - logstf_apikey → 填入你的 API Key（可选）
# 修改 tf/cfg/pug_start.cfg:
#   - sv_password → 改掉

# 4. 启动 MGE 服务器
docker run -d \
  --name tf2-comp \
  --network host \
  --restart unless-stopped \
  -e SERVER_HOSTNAME="2D2S竞技服|MGE Winner" \
  -e RCON_PASSWORD="你的RCON密码" \
  -e SERVER_TOKEN="你的SteamToken" \
  -v $(pwd)/tf:/home/tf2/server/tf \
  ghcr.io/melkortf/tf2-competitive:latest \
  +sv_pure 1 +map mge_training_v8_beta4b +maxplayers 24 +exec mge_start
```

### 切换到 PUG 模式

```bash
# 停止 MGE 容器
docker stop tf2-comp && docker rm tf2-comp

# 启动 PUG 模式
docker run -d \
  --name tf2-comp \
  --network host \
  --restart unless-stopped \
  -e SERVER_HOSTNAME="2D2S竞技服|6s PUG" \
  -e RCON_PASSWORD="你的RCON密码" \
  -e SERVER_TOKEN="你的SteamToken" \
  -v $(pwd)/tf:/home/tf2/server/tf \
  ghcr.io/melkortf/tf2-competitive:latest \
  +sv_pure 1 +map cp_process_final +maxplayers 12 +exec pug_start
```

## 目录结构

```
tf2-servers/
├── tf/
│   ├── addons/          # SourceMod + MetaMod + 插件
│   │   ├── metamod/     # MetaMod:Source
│   │   └── sourcemod/   # SourceMod + 插件 + 配置
│   ├── cfg/             # 服务器配置文件
│   │   ├── mge_start.cfg    # MGE 启动配置
│   │   ├── pug_start.cfg    # PUG 启动配置
│   │   ├── server.cfg       # 基础服务器配置
│   │   └── *.cfg            # RGL/ETF2L 比赛配置
│   ├── maps/            # MGE 自定义地图
│   └── materials/       # 自定义素材
├── scripts/
│   └── download_maps.sh # 地图下载脚本
└── README.md
```

## 插件列表

| 插件 | 用途 |
|---|---|
| **MGEMod** | MGE 1v1 训练模式 |
| **Soap DM** | 死斗模式热身 |
| **tf2-comp-fixes** | 竞技模式修复（暂停、halftime 等） |
| **RGL QoL** | RGL 联赛生活质量改进 |
| **Pause** | 比赛暂停插件 |
| **Custom Votes** | 自定义投票 |
| **Auto Restart** | 每日自动重启 |
| **Medic Stats** | 医疗数据统计 |
| **SupStats2** | 伤害/击杀统计 |
| **DemosTF** | 自动录制 Demo |
| **LogsTF** | 上传日志到 logs.tf |
| **MGE Stats Browser** | MGE 统计面板 |
| **Improved Match Timer** | 改进比赛计时器 |
| **Fix STV Slot** | 修复 SourceTV 槽位 |
| **Wait For STV** | 等待 STV 连接 |
| **Record STV** | 录制 STV Demo |
| **AFK Manager** | 挂机管理 |
| **Remove Weapons** | 武器移除 |
| **Restore Score** | 比分恢复 |

## 维护

```bash
# 查看日志
docker logs -f tf2-comp

# 进入控制台
docker exec -it tf2-comp bash

# 重启服务器
docker restart tf2-comp

# 更新插件配置后重新加载
docker exec tf2-comp sm plugins reload mge
```

## 注意事项

- ⚠️ **不要将敏感信息推送到公开仓库**（RCON 密码、Steam Token、API Key）
- 🗺️ `mge_chillypunch_final4_fix2.bsp`（137MB）因超过 GitHub 文件大小限制未包含在仓库中，需单独下载
- 📝 所有配置均基于 [RGL.gg](https://rgl.gg) 和 [ETF2L](https://etf2l.org) 比赛标准
- 🐳 服务器依赖 Docker 镜像 `ghcr.io/melkortf/tf2-competitive`，上游更新时 `docker pull` 即可
