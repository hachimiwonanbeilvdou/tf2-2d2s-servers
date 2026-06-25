#!/bin/bash
# TF2 竞技服每日重启脚本 - 每天 5:30 AM 执行

set -e

# 停止并删除旧容器（如果存在）
docker stop tf2-comp 2>/dev/null || true
docker rm tf2-comp 2>/dev/null || true

# 启动新容器
docker run -d \
  --name tf2-comp \
  --network host \
  --restart unless-stopped \
  -e SERVER_HOSTNAME="2D2S竞技服|新增!cha指令" \
  -e RCON_PASSWORD="114514114514" \
  -e SERVER_TOKEN="9D5D99893C6DFCC15B92715939CA1E58" \
  -e LOGS_TF_APIKEY="76561198345921517#ad9a306b1aab0084" \
  -e PORT=27015 \
  -v /home/ubuntu/tf2-comp/tf:/home/tf2/server/tf \
  ghcr.io/melkortf/tf2-competitive:latest \
  +sv_pure 1 +map mge_training_v8_beta4b +maxplayers 24 +exec mge_start

echo "$(date): TF2 竞技服已重启"
