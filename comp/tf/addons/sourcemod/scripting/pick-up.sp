#include <sourcemod>
#include <tf2>
#include <tf2_stocks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.1"

#define TEAM_SPEC 1
#define TEAM_RED  2
#define TEAM_BLU  3

// 选人阶段开关
bool g_bDraftActive = false;

// 队长索引
int g_iRedCaptain = -1;
int g_iBluCaptain = -1;

// 玩家准备状态
bool g_bReady[MAXPLAYERS + 1];

// 加入顺序：用于自动选出最后加入红/蓝队的玩家当队长
int g_iJoinSeq[MAXPLAYERS + 1];
int g_iSeqCounter = 0;

// 准备状态 HUD 定时器
Handle g_hReadyHUD = null;

// ConVar：触发选人的人数阈值
ConVar g_cvMinPlayers;

public Plugin myinfo =
{
    name        = "TF2 Auto Draft & Ready",
    author      = "Custom",
    description = "Auto trigger draft when enough players, pick with !pick, ready with !r.",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    // ---------- MGE 地图不加载 ----------
    char map[64];
    GetCurrentMap(map, sizeof(map));
    if (StrContains(map, "mge_", false) == 0)
    {
        LogMessage("[Draft] MGE map detected, plugin disabled.");
        return;
    }

    // ConVar
    g_cvMinPlayers = CreateConVar(
        "sm_draft_min_players",
        "12",
        "Minimum RED+BLU human players to auto-start a draft.",
        FCVAR_NOTIFY,
        true, 2.0, true, 32.0);

    // 注册聊天指令
    RegConsoleCmd("sm_pick", Cmd_Pick, "将旁观者拉入自己所在队伍");
    RegConsoleCmd("sm_r", Cmd_Ready, "切换准备/取消准备状态");
    RegConsoleCmd("sm_ready", Cmd_Ready, "切换准备/取消准备状态");

    // 事件钩子
    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);

    // 阻止选人期间手动换队
    AddCommandListener(BlockJoinTeam, "jointeam");
    AddCommandListener(BlockJoinTeam, "spectate");
}

public void OnMapStart()
{
    // 新地图重置状态
    ResetDraft();

    // 延迟检查，避免开局已有大量玩家但无 player_team 事件
    CreateTimer(3.0, Timer_MapStartCheck, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_MapStartCheck(Handle timer)
{
    if (!g_bDraftActive)
        CheckAutoDraft();
    return Plugin_Stop;
}

// ========================================================
// 自动检测是否应开始选人
// ========================================================
void CheckAutoDraft()
{
    if (g_bDraftActive)
        return;

    int total = CountRedBlueHumans();
    int min = g_cvMinPlayers.IntValue;

    if (total < min)
        return;

    // 选出红、蓝两队中最后加入的人类玩家作为队长
    int redCap = GetLatestHumanOnTeam(TEAM_RED);
    int bluCap = GetLatestHumanOnTeam(TEAM_BLU);

    if (!IsValidClient(redCap) || !IsValidClient(bluCap) || redCap == bluCap)
    {
        // 无法选出两队队长（例如有一队没有人类玩家）
        return;
    }

    // 开始选人
    StartDraft(redCap, bluCap);
}

// ========================================================
// 命令：!pick - 队伍成员将旁观者拉入自己队伍
// ========================================================
public Action Cmd_Pick(int client, int args)
{
    if (!g_bDraftActive)
    {
        ReplyToCommand(client, "[SM] 当前没有正在进行的选人。");
        return Plugin_Handled;
    }

    if (!IsValidClient(client))
        return Plugin_Handled;

    // 发起者必须在红队或蓝队
    int team = GetClientTeam(client);
    if (team != TEAM_RED && team != TEAM_BLU)
    {
        ReplyToCommand(client, "[SM] 只有红队或蓝队的成员才能使用 !pick。");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "[SM] 用法：!pick <玩家名>");
        return Plugin_Handled;
    }

    char targetName[64];
    GetCmdArg(1, targetName, sizeof(targetName));

    int target = FindTarget(client, targetName, true, false);
    if (target == -1)
        return Plugin_Handled; // FindTarget 已输出错误信息

    if (!IsValidClient(target))
    {
        ReplyToCommand(client, "[SM] 目标玩家无效。");
        return Plugin_Handled;
    }

    if (GetClientTeam(target) != TEAM_SPEC)
    {
        ReplyToCommand(client, "[SM] 该玩家不在旁观者阵营，无法被选择。");
        return Plugin_Handled;
    }

    // 将旁观者移入发起者所在队伍
    ChangeClientTeam(target, team);
    TF2_RespawnPlayer(target);

    // 新加入的队员默认未准备
    g_bReady[target] = false;

    PrintToChatAll("[Draft] %N 将 %N 选入了 %s 队伍！",
        client,
        target,
        team == TEAM_RED ? "红队" : "蓝队");

    ShowReadyStatusToAll();
    return Plugin_Handled;
}

// ========================================================
// 命令：!r / !ready - 切换准备状态
// ========================================================
public Action Cmd_Ready(int client, int args)
{
    if (!g_bDraftActive)
    {
        ReplyToCommand(client, "[SM] 当前没有正在进行的选人。");
        return Plugin_Handled;
    }

    if (!IsValidClient(client))
        return Plugin_Handled;

    int team = GetClientTeam(client);
    if (team != TEAM_RED && team != TEAM_BLU)
    {
        ReplyToCommand(client, "[SM] 只有红队或蓝队成员才能准备。");
        return Plugin_Handled;
    }

    g_bReady[client] = !g_bReady[client];

    if (g_bReady[client])
        PrintToChat(client, "[Draft] 你已准备就绪。");
    else
        PrintToChat(client, "[Draft] 你已取消准备。");

    ShowReadyStatusToAll();

    // 检查全员准备
    if (CheckAllReady())
    {
        BeginMatch();
    }

    return Plugin_Handled;
}

// ========================================================
// 事件：玩家更换队伍
// ========================================================
public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    int team = event.GetInt("team");

    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    // 记录加入红/蓝队的顺序（用于选出最后加入者）
    if (team == TEAM_RED || team == TEAM_BLU)
    {
        g_iSeqCounter++;
        g_iJoinSeq[client] = g_iSeqCounter;
    }

    // 选人期间，如果队长离开了原队伍，取消选人
    if (g_bDraftActive)
    {
        if (client == g_iRedCaptain && team != TEAM_RED)
        {
            PrintToChatAll("[Draft] 红队队长离开了队伍，选人取消。");
            ResetDraft();
        }
        else if (client == g_iBluCaptain && team != TEAM_BLU)
        {
            PrintToChatAll("[Draft] 蓝队队长离开了队伍，选人取消。");
            ResetDraft();
        }
        else
        {
            // 普通队员换队，清除准备状态
            g_bReady[client] = false;
            ShowReadyStatusToAll();
        }
    }

    // 自动检测触发（无人为介入）
    if (!g_bDraftActive)
        CheckAutoDraft();
}

// ========================================================
// 事件：玩家断开连接
// ========================================================
public void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bDraftActive)
        return;

    int client = GetClientOfUserId(event.GetInt("userid"));

    if (client == g_iRedCaptain || client == g_iBluCaptain)
    {
        PrintToChatAll("[Draft] 队长 %N 离开了游戏，选人取消。", client);
        ResetDraft();
        return;
    }

    // 普通队员离开，清除准备状态
    g_bReady[client] = false;
    ShowReadyStatusToAll();

    // 离开后可能恰好全员准备
    if (CheckAllReady())
    {
        BeginMatch();
    }
}

// ========================================================
// 阻止选人期间手动换队（加入红/蓝队）
// ========================================================
public Action BlockJoinTeam(int client, const char[] command, int argc)
{
    if (!g_bDraftActive)
        return Plugin_Continue;

    if (!IsValidClient(client))
        return Plugin_Continue;

    // 如果是队长，禁止任何主动换队（包括去旁观）
    if (client == g_iRedCaptain || client == g_iBluCaptain)
    {
        PrintToChat(client, "[Draft] 队长不能主动换队。");
        return Plugin_Handled;
    }

    // 允许进入旁观者
    if (StrEqual(command, "spectate", false))
        return Plugin_Continue;

    if (StrEqual(command, "jointeam", false))
    {
        char arg[16];
        if (argc >= 1)
            GetCmdArg(1, arg, sizeof(arg));

        // 允许切换到旁观
        if (StrEqual(arg, "spectate", false) || StrEqual(arg, "spectator", false) || StrEqual(arg, "spec", false))
            return Plugin_Continue;

        // 禁止手动加入红/蓝队
        PrintToChat(client, "[Draft] 选人期间不能手动加入队伍，请等待队员使用 !pick 将你选入。");
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

// ========================================================
// 核心：开始选人（不移动任何玩家）
// ========================================================
void StartDraft(int redCap, int bluCap)
{
    g_bDraftActive = true;
    g_iRedCaptain = redCap;
    g_iBluCaptain = bluCap;

    // 重置所有准备状态
    for (int i = 1; i <= MaxClients; i++)
        g_bReady[i] = false;

    // 启动准备状态 HUD
    delete g_hReadyHUD;
    g_hReadyHUD = CreateTimer(2.0, Timer_ShowReadyHUD, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    // 全局公告
    PrintToChatAll("[Draft] 玩家已满，请剩余玩家进入观察者。");
    PrintToChatAll("[Draft] 红队队长：%N，蓝队队长：%N。", redCap, bluCap);
    PrintToChatAll("[Draft] 使用 !pick <玩家> 将旁观者拉入己方队伍，全员准备 (!r) 后比赛自动开始。");

    ShowReadyStatusToAll();
}

// ========================================================
// 检查是否所有红蓝玩家都已准备
// ========================================================
bool CheckAllReady()
{
    int total = 0;
    int ready = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || IsFakeClient(i))
            continue;

        int team = GetClientTeam(i);
        if (team == TEAM_RED || team == TEAM_BLU)
        {
            total++;
            if (g_bReady[i])
                ready++;
        }
    }

    if (total == 0)
        return false;

    return (ready == total);
}

// ========================================================
// 正式开始比赛
// ========================================================
void BeginMatch()
{
    PrintToChatAll("[Draft] 所有玩家已准备，比赛将在 5 秒后重启回合！");

    delete g_hReadyHUD;

    g_bDraftActive = false;
    g_iRedCaptain = -1;
    g_iBluCaptain = -1;

    ServerCommand("mp_restartgame 5");
}

// ========================================================
// 重置所有状态
// ========================================================
void ResetDraft()
{
    g_bDraftActive = false;
    g_iRedCaptain = -1;
    g_iBluCaptain = -1;

    delete g_hReadyHUD;

    for (int i = 1; i <= MaxClients; i++)
        g_bReady[i] = false;
}

// ========================================================
// 工具函数
// ========================================================

int CountRedBlueHumans()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || IsFakeClient(i))
            continue;

        int team = GetClientTeam(i);
        if (team == TEAM_RED || team == TEAM_BLU)
            count++;
    }
    return count;
}

int GetLatestHumanOnTeam(int team)
{
    int best = -1;
    int bestSeq = -1;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || IsFakeClient(i))
            continue;

        if (GetClientTeam(i) != team)
            continue;

        if (g_iJoinSeq[i] > bestSeq)
        {
            bestSeq = g_iJoinSeq[i];
            best = i;
        }
    }

    return best;
}

bool IsValidClient(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}

// ========================================================
// 准备状态 HUD（显示已准备人数和未准备名单）
// ========================================================
void ShowReadyStatusToAll()
{
    int total = 0;
    int ready = 0;
    char notReadyNames[512];
    notReadyNames[0] = '\0';

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || IsFakeClient(i))
            continue;

        int team = GetClientTeam(i);
        if (team == TEAM_RED || team == TEAM_BLU)
        {
            total++;
            if (g_bReady[i])
            {
                ready++;
            }
            else
            {
                char name[MAX_NAME_LENGTH];
                GetClientName(i, name, sizeof(name));
                if (notReadyNames[0] != '\0')
                    StrCat(notReadyNames, sizeof(notReadyNames), ", ");
                StrCat(notReadyNames, sizeof(notReadyNames), name);
            }
        }
    }

    char msg[256];
    if (total == 0)
    {
        Format(msg, sizeof(msg), "当前队伍无人");
    }
    else
    {
        Format(msg, sizeof(msg), "准备情况：%d/%d 人已就绪", ready, total);
        if (ready < total)
            Format(msg, sizeof(msg), "%s\n未准备：%s", msg, notReadyNames);
    }

    PrintHintTextToAll(msg);
}

public Action Timer_ShowReadyHUD(Handle timer)
{
    if (!g_bDraftActive)
    {
        g_hReadyHUD = null;
        return Plugin_Stop;
    }

    ShowReadyStatusToAll();
    return Plugin_Continue;
}