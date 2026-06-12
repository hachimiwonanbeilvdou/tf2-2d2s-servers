# TF2-2B2S Servers

TF2 竞技服务器配置。基于 [melkortf/tf2-servers](https://github.com/melkortf/tf2-servers) 的模板系统。

## 目录结构

```
├── comp/                  # 竞技服配置 (6v6/HL/Ultiduo)
│   └── tf/
│       ├── addons/        # SourceMod + Metamod 插件
│       ├── cfg/           # 比赛配置 (ETF2L / RGL / fbtf)
│       └── maps/          # MGE / 比赛地图
└── .gitignore
```

## 使用方式

### Docker 部署 (推荐)

参考 `melkortf/tf2-servers` 使用 Docker 运行：

```bash
docker run \
  -v "$(pwd)/comp/tf/maps:/home/tf2/server/tf/maps" \
  -v "$(pwd)/comp/tf/cfg:/home/tf2/server/tf/cfg" \
  -v "$(pwd)/comp/tf/addons:/home/tf2/server/tf/addons" \
  -e "RCON_PASSWORD=你的密码" \
  -e "SERVER_HOSTNAME=2D2S竞技服" \
  --network=host \
  ghcr.io/melkortf/tf2-competitive
```

### 配置文件

- `server.cfg` — 基础服务器设置（已脱敏，使用时填入实际值）
- `server.cfg.template` — Docker 环境变量模板（`${RCON_PASSWORD}` 等）
- `pug_start.cfg` — PUG/Pickup 启动脚本
- `mge_start.cfg` — MGE 模式启动脚本
- `cfg/etf2l*.cfg` — ETF2L 联赛配置
- `cfg/rgl*.cfg` — RGL 联赛配置
- `cfg/fbtf_cfg/` — fbtf.tf 配置

## 比赛配置

- ETF2L: 6v6, 9v9, Ultiduo, Ultitrio, Bball, Pass Time
- RGL: 6s, 7s, HL, MM, Prolander, Ultiduo
- 自定义: MGE, PUG/Pickup, SOAP DM

## 插件列表

- SourceMod + Metamod:Source
- demos.tf 自动上传
- logs.tf 自动上传
- Supplemental Stats 2
- Medic Stats
- RestoreScore
- tf2rue
- Improved Match Timer
- FixStvSlot
- MGE Mod
- 2B2S PUG Pick 插件

## 许可证

MIT
