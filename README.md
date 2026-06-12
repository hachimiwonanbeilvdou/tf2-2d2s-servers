# TF2-2B2S Servers

我个人架设的TF2竞技服务器配置。基于 [melkortf/tf2-servers](https://github.com/melkortf/tf2-servers) 修改

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

### 个人修改内容

- `pug_start.cfg` — PUG/Pickup 启动脚本
- `mge_start.cfg` — MGE 模式启动脚本
- `addons/sourcemod/configs/customvotes.cfg` — 自定义投票内容
- `2b2sPUG-PICK.smx` — PUG投票插件

## 服务器内置功能

默认情况开启MGE模式
输入!votemenu选择投票切换游戏,模式包含6s模式和MGE模式
自定义趣味投票

## 插件列表

- SourceMod + Metamod:Source
- demos.tf 
- logs.tf 
- Supplemental Stats 2
- Medic Stats
- RestoreScore
- tf2rue
- Improved Match Timer
- FixStvSlot
- MGE Mod
- 2B2S PUG Pick 插件
