#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <tf2>
#include <tf2_stocks>

// ============================================================================
// 常量定义
// ============================================================================

#define TEAM_SPEC 1   // 旁观者
#define TEAM_RED  2   // 红队
#define TEAM_BLU  3   // 蓝队

// ============================================================================
// 全局状态变量
// ============================================================================

// --- 选人流程状态 ---
bool g_DraftStarted  = false;   // 选人是否已开始
bool g_PicksLocked   = false;   // 选人是否已锁定（禁止选人）
int  g_TurnTeam      = 0;       // 当前轮到哪队选人 (TEAM_RED 或 TEAM_BLU)

// --- 比赛状态 ---
bool g_MatchStarted  = false;   // 比赛是否已开始

// --- 玩家就绪状态（true = 已打 !ready） ---
bool g_PlayerReady[MAXPLAYERS + 1];

// --- HUD 同步句柄（所有玩家 HUD 刷新步调一致） ---
Handle g_HudSync = INVALID_HANDLE;

// --- ConVar 缓存（避免每次都 FindConVar） ---
ConVar g_CvarTournamentReadyMode = null;
ConVar g_CvarRestartGame         = null;

// ============================================================================
// 插件元信息
// ============================================================================

public Plugin myinfo =
{
    name        = "PUG Pick",
    author      = "No name",
    description = "",
    version     = "1.1.0"
};

// ============================================================================
// 插件加载
// ============================================================================

public void OnPluginStart()
{
    // ——— 注册玩家命令 ———
    RegConsoleCmd("sm_pick",    Command_Pick);         // 队长选人
    RegConsoleCmd("sm_ready",   Command_Ready);        // 标记就绪
    RegConsoleCmd("sm_r",       Command_Ready);        // !r 快捷命令
    RegConsoleCmd("sm_unready", Command_Unready);      // 取消就绪
    RegConsoleCmd("sm_nr",      Command_Unready);      // !nr 快捷命令
    RegConsoleCmd("sm_status",  Command_Status);       // 查看状态面板
    // ——— HUD 同步器 ———
    g_HudSync = CreateHudSynchronizer();

    // ——— 定时器：每 3 秒刷新一次 HUD 状态面板 ———
    CreateTimer(3.0, Timer_ShowStatus, _, TIMER_REPEAT);

    // ——— ConVar 缓存 ———
    g_CvarTournamentReadyMode = FindConVar("mp_tournament_readymode");
    g_CvarRestartGame         = FindConVar("mp_restartgame");

    // 插件加载时立即关闭锦标赛准备模式
    if (g_CvarTournamentReadyMode != null)
    {
        g_CvarTournamentReadyMode.SetInt(0);
    }

    // ——— 挂钩游戏事件 ———
    HookEvent("teamplay_round_start", Event_RoundStart,  EventHookMode_PostNoCopy);
}

// ============================================================================
// 地图开始
// ============================================================================

public void OnMapStart()
{
    // 重置选人 / 比赛状态
    ResetPugState();

    // 确保锦标赛准备模式在新地图也是关闭的
    if (g_CvarTournamentReadyMode != null)
    {
        g_CvarTournamentReadyMode.SetInt(0);
    }
}

// ============================================================================
// 地图结束
// ============================================================================

public void OnMapEnd()
{
}

// ============================================================================
// 客户端进入服务器
// ============================================================================

public void OnClientPutInServer(int client)
{
    // 新玩家默认未就绪
    g_PlayerReady[client] = false;
}

// ============================================================================
// 客户端断开连接
// ============================================================================

public void OnClientDisconnect(int client)
{
    g_PlayerReady[client] = false;
}

// ============================================================================
// 命令：sm_ready / sm_r  —  玩家标记自己已准备
// ============================================================================

public Action Command_Ready(int client, int args)
{
    // 有效性校验
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    // 比赛开始后不能再准备
    if (g_MatchStarted)
    {
        return Plugin_Handled;
    }

    // 只有红队 / 蓝队玩家才能准备
    if (GetClientTeam(client) != TEAM_RED && GetClientTeam(client) != TEAM_BLU)
    {
        ReplyToCommand(client, "[Pick] You must be on RED or BLU to ready.");
        return Plugin_Handled;
    }

    g_PlayerReady[client] = true;

    PrintToChatAll("[Pick] %N is READY.", client);
    ShowStatusToAll();

    // 检查是否满足开赛条件
    CheckAllReadyAndStart();

    return Plugin_Handled;
}

// ============================================================================
// 命令：sm_unready / sm_nr  —  玩家取消准备
// ============================================================================

public Action Command_Unready(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    if (g_MatchStarted)
    {
        return Plugin_Handled;
    }

    if (GetClientTeam(client) != TEAM_RED && GetClientTeam(client) != TEAM_BLU)
    {
        ReplyToCommand(client, "[Pick] You must be on RED or BLU to unready.");
        return Plugin_Handled;
    }

    g_PlayerReady[client] = false;

    PrintToChatAll("[Pick] %N is UNREADY.", client);
    ShowStatusToAll();

    return Plugin_Handled;
}

// ============================================================================
// 命令：sm_status  —  查看当前等待/就绪/未就绪玩家列表
// ============================================================================

public Action Command_Status(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    ShowStatusToClient(client);

    return Plugin_Handled;
}

// ============================================================================
// 命令：sm_pick  —  队长选人（核心命令）
//
// 流程：
//  1. 双方都需要一名 Medic 作为队长
//  2. 先发起 !pick 的一方获得首轮选人权
//  3. 队长从旁观者中选一人加入自己队伍
//  4. 选完后轮转到对方队长
//  5. 选人持续直到比赛开始或回合开始
// ============================================================================

public Action Command_Pick(int client, int args)
{
    // ——— 选人已锁定 ———
    if (g_PicksLocked)
    {
        ReplyToCommand(client, "[Pick] Picking is disabled.");
        return Plugin_Handled;
    }

    // ——— 权限检查：只有 Medic 才能当队长 ———
    if (!IsCaptain(client))
    {
        ReplyToCommand(client, "[Pick] Only RED/BLU Medics can pick.");
        return Plugin_Handled;
    }

    int team = GetClientTeam(client);

    // ——— 选人尚未开始：初始化 ———
    if (!g_DraftStarted)
    {
        int otherTeam = GetOtherTeam(team);

        // 检查对方队伍是否也有 Medic 队长
        if (FindCaptain(otherTeam) == 0)
        {
            ReplyToCommand(client, "[Pick] Other team needs a Medic captain first.");
            return Plugin_Handled;
        }

        // 双方队长就位，开始选人，发起命令的一方先选
        g_DraftStarted = true;
        g_TurnTeam     = team;

        PrintToChatAll("[Pick] Draft started. %N picks first.", client);
    }

    // ——— 回合检查：不是你的队伍在选 ———
    if (team != g_TurnTeam)
    {
        ReplyToCommand(client, "[Pick] It is not your turn.");
        return Plugin_Handled;
    }

    // ——— 打开选人菜单 ———
    ShowPickMenu(client);

    return Plugin_Handled;
}

// ============================================================================
// 选人菜单：列出所有旁观者
// 使用 UserId 作为选项值，比 client index 更稳定
// ============================================================================

void ShowPickMenu(int captain)
{
    Menu menu = new Menu(MenuHandler_Pick);

    // 标题显示当前队伍人数
    char title[128];
    Format(title, sizeof(title), "Pick a spectator | Team: %d",
           CountTeamPlayers(g_TurnTeam));
    menu.SetTitle(title);

    int count = 0;

    // 遍历所有在线玩家，筛选旁观者（排除 Bot）
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))  continue;
        if (IsFakeClient(i))     continue;              // 跳过 Bot
        if (GetClientTeam(i) != TEAM_SPEC) continue;    // 只显示旁观者

        char userid[16];
        char name[64];

        // 以 UserId 作为菜单值存储，避免 client index 复用问题
        IntToString(GetClientUserId(i), userid, sizeof(userid));
        Format(name, sizeof(name), "%N", i);

        menu.AddItem(userid, name);
        count++;
    }

    // 没有旁观者可选的边界情况
    if (count == 0)
    {
        delete menu;
        PrintToChat(captain, "[Pick] No spectators available.");
        return;
    }

    menu.ExitButton = true;
    menu.Display(captain, MENU_TIME_FOREVER);
}

// ============================================================================
// 选人菜单回调：队长选择了一名旁观者
//
// 这里做大量二次校验，因为菜单可能是很久之前打开的，
// 期间游戏状态可能已经改变（选人被锁、队长换职业、目标离开等）
// ============================================================================

public int MenuHandler_Pick(Menu menu, MenuAction action, int client, int item)
{
    // 菜单生命周期结束，释放资源
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    // 非选择操作（如按取消键），忽略
    if (action != MenuAction_Select)
    {
        return 0;
    }

    // ========== 二次校验：防止菜单打开期间状态变化 ==========

    // 选人已被锁定
    if (g_PicksLocked || !g_DraftStarted)
    {
        PrintToChat(client, "[Pick] Picking is disabled.");
        return 0;
    }

    // 操作者已不是 Medic
    if (!IsCaptain(client))
    {
        PrintToChat(client, "[Pick] Only Medic captains can pick.");
        return 0;
    }

    // 已经不是你的回合
    if (GetClientTeam(client) != g_TurnTeam)
    {
        PrintToChat(client, "[Pick] It is not your turn.");
        return 0;
    }

    // ========== 解析目标玩家 ==========

    char info[16];
    menu.GetItem(item, info, sizeof(info));

    int target = GetClientOfUserId(StringToInt(info));

    // 目标无效：已离开服务器或已不在旁观
    if (target == 0 || !IsClientInGame(target) || GetClientTeam(target) != TEAM_SPEC)
    {
        PrintToChat(client, "[Pick] That player is no longer available.");
        ShowPickMenu(client);   // 重新打开菜单，刷新可用列表
        return 0;
    }

    // ========== 执行选人 ==========

    g_PlayerReady[target] = false;                      // 清除被选玩家的就绪状态
    ChangeClientTeam(target, g_TurnTeam);               // 换到队长所在队伍
    TF2_RespawnPlayer(target);                          // 重生到新队伍

    PrintToChatAll("[Pick] %N picked %N.", client, target);
    ShowStatusToAll();

    // ========== 轮转到对方队长 ==========

    g_TurnTeam = GetOtherTeam(g_TurnTeam);

    int nextCaptain = FindCaptain(g_TurnTeam);

    if (nextCaptain != 0)
    {
        PrintToChatAll("[Pick] It is now %N's turn.", nextCaptain);
        ShowPickMenu(nextCaptain);   // 自动为下一位队长弹出菜单
    }
    else
    {
        PrintToChatAll("[Pick] Waiting for a Medic captain on the other team.");
    }

    return 0;
}

// ============================================================================
// 事件：回合开始
//
// 回合开始时如果选人还在进行，强制终止。
// 防止选人选到一半回合开始导致人数不对。
// ============================================================================

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    if (g_DraftStarted)
    {
        g_PicksLocked  = true;
        g_DraftStarted = false;

        ShowStatusToAll();
    }
}

// ============================================================================
// 定时器：每 3 秒刷新 HUD 状态面板
//
// 优化：选人进行中或有旁观者时才刷新，空闲时跳过
// ============================================================================

public Action Timer_ShowStatus(Handle timer)
{
    // 比赛进行中不显示 HUD 状态面板
    if (g_MatchStarted)
    {
        return Plugin_Continue;
    }

    if (!g_DraftStarted && !HasSpectators())
    {
        return Plugin_Continue;
    }

    ShowStatusToAll();

    return Plugin_Continue;
}

// ============================================================================
// HUD 状态面板 — 向所有玩家广播
// ============================================================================

void ShowStatusToAll()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i))    continue;

        ShowStatusToClient(i);
    }
}

// ============================================================================
// HUD 状态面板 — 向单个玩家显示
// ============================================================================

void ShowStatusToClient(int client)
{
    char text[1024];
    BuildStatusText(text, sizeof(text));

    // HUD 定位在屏幕右侧，约 1/4 处
    SetHudTextParams(
        0.72,   // x 坐标
        0.15,   // y 坐标
        1.2,    // 持续时间（秒），配合 3 秒定时器刷新
        255, 255, 255, 255
    );

    ShowSyncHudText(client, g_HudSync, "%s", text);
}

// ============================================================================
// 构建状态文本：分组列出 等待中 / 已准备 / 未准备 的玩家
// ============================================================================

void BuildStatusText(char[] text, int maxlen)
{
    char waiting[256];    // 旁观者名字列表
    char ready[256];      // 已准备玩家名字列表
    char unready[256];    // 未准备玩家名字列表

    int waitingCount = 0;
    int readyCount   = 0;
    int unreadyCount = 0;

    // 初始化为空字符串
    waiting[0]  = '\0';
    ready[0]    = '\0';
    unready[0]  = '\0';

    // 遍历所有在线玩家，按状态分类
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i))    continue;

        int team = GetClientTeam(i);

        if (team == TEAM_SPEC)
        {
            // 旁观者 → 等待被选
            AddNameToList(waiting, sizeof(waiting), i);
            waitingCount++;
        }
        else if (team == TEAM_RED || team == TEAM_BLU)
        {
            if (g_PlayerReady[i])
            {
                AddNameToList(ready, sizeof(ready), i);
                readyCount++;
            }
            else
            {
                AddNameToList(unready, sizeof(unready), i);
                unreadyCount++;
            }
        }
    }

    // 空列表显示 "None"
    if (waitingCount == 0)  Format(waiting,  sizeof(waiting),  "None");
    if (readyCount   == 0)  Format(ready,    sizeof(ready),    "None");
    if (unreadyCount == 0)  Format(unready,  sizeof(unready),  "None");

    // 组装最终输出
    Format(
        text,
        maxlen,
        "Waiting Players: %d\n%s\nReady Players: %d\n%s\nUnready Players: %d\n%s",
        waitingCount,  waiting,
        readyCount,    ready,
        unreadyCount,  unready
    );
}

// ============================================================================
// 工具：向名字列表追加一个玩家名
// ============================================================================

void AddNameToList(char[] list, int maxlen, int client)
{
    char name[80];
    Format(name, sizeof(name), "%N\n", client);
    StrCat(list, maxlen, name);
}

// ============================================================================
// 清除 HUD 状态面板（比赛开始后调用）
// 通过设置 alpha = 0 实现完全透明
// ============================================================================

void ClearStatusDisplay()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i))    continue;

        SetHudTextParams(0.72, 0.15, 0.1, 255, 255, 255, 0);  // alpha = 0
        ShowSyncHudText(i, g_HudSync, "");
    }
}

// ============================================================================
// 判断是否有旁观者
// ============================================================================

bool HasSpectators()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i))    continue;

        if (GetClientTeam(i) == TEAM_SPEC)
        {
            return true;
        }
    }

    return false;
}

// ============================================================================
// 判断玩家是否为合法队长：必须是红队或蓝队的 Medic
// ============================================================================

bool IsCaptain(int client)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return false;
    }

    int team = GetClientTeam(client);

    if (team != TEAM_RED && team != TEAM_BLU)
    {
        return false;
    }

    return TF2_GetPlayerClass(client) == TFClass_Medic;
}

// ============================================================================
// 在指定队伍中查找 Medic 队长
// 返回第一个找到的 Medic 的 client index，没有则返回 0
// ============================================================================

int FindCaptain(int team)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))       continue;
        if (GetClientTeam(i) != team) continue;

        if (TF2_GetPlayerClass(i) == TFClass_Medic)
        {
            return i;
        }
    }

    return 0;
}

// ============================================================================
// 统计指定队伍的玩家数量
// ============================================================================

int CountTeamPlayers(int team)
{
    int count = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i))    continue;

        if (GetClientTeam(i) == team)
        {
            count++;
        }
    }

    return count;
}

// ============================================================================
// 获取对方的队伍 ID
// ============================================================================

int GetOtherTeam(int team)
{
    if (team == TEAM_RED)
    {
        return TEAM_BLU;
    }

    return TEAM_RED;
}

// ============================================================================
// 检查开赛条件并启动比赛
//
// 条件 1：双方队伍总人数相等
// 条件 2：双方所有玩家都已准备（全员就绪）
// 条件 3：总准备人数 ≥ 4
// ============================================================================

void CheckAllReadyAndStart()
{
    if (g_MatchStarted)
    {
        return;
    }

    int redPlayers = CountTeamPlayers(TEAM_RED);
    int bluPlayers = CountTeamPlayers(TEAM_BLU);

    // 双方总人数必须相等且非零
    if (redPlayers != bluPlayers || redPlayers == 0)
    {
        return;
    }

    int redReady   = CountReadyPlayersOnTeam(TEAM_RED);
    int bluReady   = CountReadyPlayersOnTeam(TEAM_BLU);
    int totalReady = redReady + bluReady;

    // 双方所有玩家都必须准备，且总准备人数 ≥ 4
    if (redReady != redPlayers || bluReady != bluPlayers || totalReady < 4)
    {
        return;
    }

    StartGame();
}

// ============================================================================
// 统计指定队伍已就绪的玩家数量（排除 Bot）
// ============================================================================

int CountReadyPlayersOnTeam(int team)
{
    int count = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i))    continue;

        if (GetClientTeam(i) != team) continue;

        if (g_PlayerReady[i])
        {
            count++;
        }
    }

    return count;
}

// ============================================================================
// 启动比赛：锁定选人、执行配置、重启回合
// ============================================================================

void StartGame()
{
    g_MatchStarted = true;
    g_PicksLocked  = true;
    g_DraftStarted = false;

    // 清除状态面板
    ClearStatusDisplay();

    // 执行比赛配置
    ServerCommand("exec sourcemod/soap_live.cfg");

    // 关闭锦标赛准备模式
    if (g_CvarTournamentReadyMode != null)
    {
        g_CvarTournamentReadyMode.SetInt(0);
    }

    // 5 秒后重启回合
    if (g_CvarRestartGame != null)
    {
        g_CvarRestartGame.SetInt(5);
    }
    else
    {
        ServerCommand("mp_restartgame 5");
    }
}

// ============================================================================
// 重置所有选人 / 比赛状态（换图或插件重载时调用）
// ============================================================================

void ResetPugState()
{
    g_DraftStarted = false;
    g_PicksLocked  = false;
    g_TurnTeam     = 0;
    g_MatchStarted = false;

    // 清空所有玩家的就绪标记
    for (int i = 1; i <= MaxClients; i++)
    {
        g_PlayerReady[i] = false;
    }

    ShowStatusToAll();
}
