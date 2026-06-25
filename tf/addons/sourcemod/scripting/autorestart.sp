/**
 * autorestart.sp
 * TF2 服务器定时重启插件
 *
 * 功能：
 *   - 每日定时重启服务器，可自定义时间和倒计时警告
 *   - 首次运行自动生成 cfg/sourcemod/autorestart.cfg 配置文件
 *   - 重启事件写入 addons/sourcemod/logs/autorestart.log 日志
 *   - 管理员 !start 手动重启
 *   - 所有玩家 !time 查看当前时间
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

public Plugin myinfo =
{
    name        = "Auto Restart",
    author      = "LC",
    description = "定时重启服务器，支持CFG配置和日志记录",
    version     = "1.0.1",
    url         = ""
};

// ============================================================================
// ConVar 句柄 —— 用于持有配置项的引用
// ============================================================================
ConVar g_Cvar_Enable;   // 是否启用定时重启
ConVar g_Cvar_Time;     // 预设的重启时间
ConVar g_Cvar_Warning;  // 重启前警告的分钟数
ConVar g_Cvar_Timezone; // UTC 时区偏移（小时），用于将 UTC 转为本地时间

// ============================================================================
// 运行状态 —— 全局变量，跨函数共享
// ============================================================================
Handle g_hCheckTimer          = null;     // 定时器句柄，用于取消/重建
bool   g_bRestartInProgress   = false;    // 是否正在执行重启流程（防重复触发）
char   g_sLastRestartDate[11] = "";       // 上次重启的日期 "YYYY-MM-DD"（防止同一天重复重启）
char   g_sRestartTime[6]      = "04:00";  // 解析后的目标时间 "HH:MM"
int    g_iWarningMinutes      = 5;        // 警告倒计时的总分钟数
int    g_iCountdown           = 0;        // 当前倒计时剩余分钟数
char   g_sLogFile[PLATFORM_MAX_PATH];     // 日志文件的完整路径

// ============================================================================
// OnPluginStart —— 插件加载时调用，初始化一切
// ============================================================================
public void OnPluginStart()
{
    // --- 构建日志文件路径：addons/sourcemod/logs/autorestart.log ---
    // Path_SM 是 SourceMod 定义的常量，指向 addons/sourcemod/ 目录
    BuildPath(Path_SM, g_sLogFile, sizeof(g_sLogFile), "logs/autorestart.log");

    // 确保 logs 目录存在，否则创建它
    char logsDir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, logsDir, sizeof(logsDir), "logs");
    if (!DirExists(logsDir))
    {
        CreateDirectory(logsDir, 0x1FF); // 0x1FF = 777 权限（Windows下等效）
    }

    // 写入插件加载日志
    LogToFile(g_sLogFile, "============================================");
    LogToFile(g_sLogFile, "AutoRestart 插件 v%s 已加载", "1.0.1");

    // --- 创建 ConVar —— 这些会出现在自动生成的 CFG 文件里 ---
    // CreateConVar(名称, 默认值, 描述, 标志, 是否有最小值, 最小值, 是否有最大值, 最大值)
    g_Cvar_Enable = CreateConVar(
        "sm_autorestart_enable", "1",
        "启用/禁用定时自动重启。0 = 禁用，1 = 启用。",
        _, true, 0.0, true, 1.0);

    g_Cvar_Time = CreateConVar(
        "sm_autorestart_time", "04:00",
        "每日定时重启的整点时间（HH:MM 格式，24小时制，使用服务器时区）。",
        _);

    g_Cvar_Warning = CreateConVar(
        "sm_autorestart_warning", "5",
        "重启前提前多少分钟开始倒计时警告。设为 0 则无警告直接重启。",
        _, true, 0.0, true, 30.0);

    g_Cvar_Timezone = CreateConVar(
        "sm_autorestart_timezone", "8",
        "服务器时区的 UTC 偏移（小时）。FormatTime 返回的是 UTC 时间，"
        ... "本插件通过此偏移量自动转换为本地时间。"
        ... "中国(UTC+8) = 8，日本(UTC+9) = 9，纽约(UTC-5) = -5。",
        _, true, -12.0, true, 14.0);

    // --- 自动生成 CFG 配置文件 ---
    // 首次运行：在 cfg/sourcemod/ 下自动创建 autorestart.cfg，写入以上四个 ConVar
    // 后续运行：自动执行已有的 CFG 文件，让玩家修改的值生效
    AutoExecConfig(true, "autorestart");

    // --- 注册命令 ---
    // RegAdminCmd：只有拥有 ADMFLAG_CHANGEMAP (flag "d") 权限的管理员才能使用
    RegAdminCmd("sm_start", Command_Start, ADMFLAG_CHANGEMAP,
        "手动重启服务器（通过 changelevel 重载当前地图）");
    // RegConsoleCmd：所有玩家都可以使用
    RegConsoleCmd("sm_time", Command_Time,
        "显示当前服务器时间和下次定时重启的时间");
}

// ============================================================================
// GetLocalTimestamp —— 获取当前本地时间的 Unix 时间戳
// GetTime() 返回的是 UTC 时间戳，FormatTime 也基于 UTC 格式化
// 通过加上时区偏移量（小时 × 3600）转换为本地时间
// ============================================================================
stock int GetLocalTimestamp()
{
    return GetTime() + (g_Cvar_Timezone.IntValue * 3600);
}

// ============================================================================
// OnConfigsExecuted —— 所有配置文件执行完毕后调用，此时 ConVar 值已最终确定
// 这里是启动定时器的最佳时机，因为 CFG 中的值已经覆盖了默认值
// ============================================================================
public void OnConfigsExecuted()
{
    // 先干掉旧的检查定时器，避免重复（OnConfigsExecuted 可能会被多次调用）
    if (g_hCheckTimer != null)
    {
        KillTimer(g_hCheckTimer);
        g_hCheckTimer = null;
    }

    // 重置执行标记（可能是配置热重载导致的）
    g_bRestartInProgress = false;

    // 如果禁用了定时重启，直接返回，不创建定时器
    if (!g_Cvar_Enable.BoolValue)
    {
        LogToFile(g_sLogFile, "定时重启已禁用");
        return;
    }

    // 读取并验证玩家配置的重启时间
    char timeBuf[6];
    g_Cvar_Time.GetString(timeBuf, sizeof(timeBuf));
    strcopy(g_sRestartTime, sizeof(g_sRestartTime), timeBuf);

    int targetHour, targetMin;
    if (!ParseRestartTime(g_sRestartTime, targetHour, targetMin))
    {
        // 格式错误时记录错误日志，并禁止自动重启（不创建定时器）
        LogError("sm_autorestart_time 格式无效，应为 HH:MM，实际值为 \"%s\"。"
                 ... "定时重启已禁用。", g_sRestartTime);
        return;
    }

    // 读取警告分钟数
    g_iWarningMinutes = g_Cvar_Warning.IntValue;

    // 读取时区偏移
    int timezone = g_Cvar_Timezone.IntValue;

    LogToFile(g_sLogFile, "定时重启已启用 —— 计划每日 %s 执行，提前 %d 分钟警告，"
              ... "时区 UTC%+d", g_sRestartTime, g_iWarningMinutes, timezone);

    // --- 启动核心轮询定时器：每 30 秒触发一次 ---
    // TIMER_REPEAT：重复执行，直到返回 Plugin_Stop
    // TIMER_FLAG_NO_MAPCHANGE：换图时自动销毁（换图后 OnConfigsExecuted 会重建）
    g_hCheckTimer = CreateTimer(30.0, Timer_CheckRestart, 0,
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// ============================================================================
// OnMapEnd —— 地图结束时调用，用于清理状态和记录日志
// ============================================================================
public void OnMapEnd()
{
    g_bRestartInProgress = false;
    LogToFile(g_sLogFile, "地图结束 —— 重启状态已重置");
}

// ============================================================================
// Timer_CheckRestart —— 核心轮询回调，每 30 秒执行一次
// 比对当前时间是否等于目标时间，匹配则触发重启流程
// ============================================================================
public Action Timer_CheckRestart(Handle timer)
{
    int localStamp = GetLocalTimestamp();

    // --- 跨日检测：进入新的一天时，重置"今日已重启"标记 ---
    char today[11];
    FormatTime(today, sizeof(today), "%Y-%m-%d", localStamp);
    if (strcmp(today, g_sLastRestartDate) != 0
        && g_sLastRestartDate[0] != '\0')
    {
        // 日期变了，清空上次重启日期（允许今天再次触发）
        g_sLastRestartDate[0] = '\0';
    }

    // 如果今天已经重启过，或者正在重启中，跳过
    if (g_bRestartInProgress || g_sLastRestartDate[0] != '\0')
        return Plugin_Continue;

    // --- 比对当前时间 ---
    char now[6];
    FormatTime(now, sizeof(now), "%H:%M", localStamp);

    // 时间不匹配，继续等待
    if (strcmp(now, g_sRestartTime) != 0)
        return Plugin_Continue;

    // --- 时间匹配！开始执行重启流程 ---
    g_bRestartInProgress = true;
    // 记录今天的日期，防止同一天内再次触发
    FormatTime(g_sLastRestartDate, sizeof(g_sLastRestartDate), "%Y-%m-%d", localStamp);

    LogToFile(g_sLogFile, "定时重启已触发，时间 %s（警告期 %d 分钟）",
              now, g_iWarningMinutes);

    if (g_iWarningMinutes > 0)
    {
        // 有警告期：立即广播第一条警告，然后启动倒计时定时器
        PrintToChatAll("\x04[AutoRestart]\x01 服务器将在 \x04%d\x01 分钟后重启。",
                       g_iWarningMinutes);

        // 启动 60 秒重复定时器，每 1 分钟递减并广播
        g_iCountdown = g_iWarningMinutes;
        CreateTimer(60.0, Timer_Countdown, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
    else
    {
        // 无警告期：直接重启（有短暂延迟以确保消息送达玩家）
        PrintToChatAll("\x04[AutoRestart]\x01 服务器正在重启...");
        LogToFile(g_sLogFile, "无警告期 —— 立即执行重启");
        PerformRestart();
    }

    return Plugin_Continue;
}

// ============================================================================
// Timer_Countdown —— 倒计时回调，每 60 秒触发一次
// 每次递减计数，归零时调用 PerformRestart()
// ============================================================================
public Action Timer_Countdown(Handle timer)
{
    g_iCountdown--;
    LogToFile(g_sLogFile, "倒计时: 剩余 %d 分钟", g_iCountdown);

    if (g_iCountdown > 0)
    {
        // 还有时间，继续广播倒计时
        PrintToChatAll("\x04[AutoRestart]\x01 服务器将在 \x04%d\x01 分钟后重启。",
                       g_iCountdown);
        return Plugin_Continue; // 定时器继续
    }

    // 倒计时结束 —— 执行重启
    PrintToChatAll("\x04[AutoRestart]\x01 服务器正在重启！");
    LogToFile(g_sLogFile, "倒计时结束 —— 执行重启");

    PerformRestart();
    return Plugin_Stop; // 停止重复定时器
}

// ============================================================================
// PerformRestart —— 真正的重启函数
// 获取当前地图名，3 秒延迟后调用 ForceChangeLevel 重载同一张地图
// ============================================================================
void PerformRestart()
{
    char currentMap[PLATFORM_MAX_PATH];
    GetCurrentMap(currentMap, sizeof(currentMap));

    LogToFile(g_sLogFile, "正在重启: changelevel 到 \"%s\"", currentMap);
    // 延迟 3 秒让聊天消息有时间发送到所有客户端
    CreateTimer(3.0, Timer_DoRestart);
}

public Action Timer_DoRestart(Handle timer)
{
    char currentMap[PLATFORM_MAX_PATH];
    GetCurrentMap(currentMap, sizeof(currentMap));
    // ForceChangeLevel 是 SourceMod 推荐的方式，比 ServerCommand("changelevel") 更规范
    // 第二个参数是该操作的描述，会出现在 maphistory 里
    ForceChangeLevel(currentMap, "Auto-Restart");
    return Plugin_Stop;
}

// ============================================================================
// 命令 "!start" / sm_start —— 管理员手动重启
// 需要 ADMFLAG_CHANGEMAP（flag "d"）权限
// ============================================================================
public Action Command_Start(int client, int args)
{
    char currentMap[PLATFORM_MAX_PATH];
    GetCurrentMap(currentMap, sizeof(currentMap));

    if (client > 0)
    {
        // 来自玩家（非服务器控制台）
        char clientName[MAX_NAME_LENGTH];
        GetClientName(client, clientName, sizeof(clientName));
        LogToFile(g_sLogFile, "手动重启: 由 \"%s\" 触发 (地图: %s)", clientName, currentMap);
        // LogAction 写入 SourceMod 主日志，用于管理员审计
        LogAction(client, -1, "\"%L\" 触发了手动服务器重启 (地图: %s)",
                  client, currentMap);
        // ShowActivity2 根据 sm_show_activity 设置向其他管理员显示
        ShowActivity2(client, "[SM] \x04", "触发了服务器重启。");
    }
    else
    {
        // 来自服务器控制台
        LogToFile(g_sLogFile, "手动重启: 由服务器控制台触发 (地图: %s)", currentMap);
    }

    PrintToChatAll("\x04[AutoRestart]\x01 管理员触发了服务器重启。"
                   ... "3 秒后执行...");

    // 标记今日已重启，防止自动定时在今天再次触发
    FormatTime(g_sLastRestartDate, sizeof(g_sLastRestartDate),
               "%Y-%m-%d", GetLocalTimestamp());

    CreateTimer(3.0, Timer_DoRestart);
    return Plugin_Handled;
}

// ============================================================================
// 命令 "!time" / sm_time —— 显示当前时间和下次定时重启
// 所有玩家均可使用
// ============================================================================
public Action Command_Time(int client, int args)
{
    char currentTime[6];
    FormatTime(currentTime, sizeof(currentTime), "%H:%M", GetLocalTimestamp());

    if (g_Cvar_Enable.BoolValue)
    {
        ReplyToCommand(client,
            "\x04[AutoRestart]\x01 当前时间: \x04%s\x01 | "
            ... "下次定时重启: \x04%s\x01 (警告期: %d 分钟)",
            currentTime, g_sRestartTime, g_iWarningMinutes);
    }
    else
    {
        ReplyToCommand(client,
            "\x04[AutoRestart]\x01 当前时间: \x04%s\x01 | "
            ... "定时重启已\x04禁用", currentTime);
    }

    return Plugin_Handled;
}

// ============================================================================
// ParseRestartTime —— 工具函数，验证并解析 "HH:MM" 格式的时间字符串
// 成功返回 true 并通过引用参数返回 hour 和 minute
// 失败返回 false
// ============================================================================
static bool ParseRestartTime(const char[] timeStr, int &hour, int &minute)
{
    // 必须是恰好 5 个字符且第 3 个字符是 ':'
    if (strlen(timeStr) != 5 || timeStr[2] != ':')
        return false;

    // 分割小时和分钟子串
    char hourStr[3], minStr[3];
    strcopy(hourStr, 3, timeStr);        // 取前两个字符 "HH"
    strcopy(minStr, 3, timeStr[3]);      // 取后两个字符 "MM"

    hour   = StringToInt(hourStr);
    minute = StringToInt(minStr);

    // 验证范围
    if (hour < 0 || hour > 23)
        return false;
    if (minute < 0 || minute > 59)
        return false;

    return true;
}
