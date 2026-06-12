#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <tf2>
#include <tf2_stocks>

#define TEAM_SPEC 1
#define TEAM_RED 2
#define TEAM_BLU 3

#define TEAM_SIZE 6

bool g_DraftStarted = false;
bool g_PicksLocked = false;

bool g_PlayerReady[MAXPLAYERS + 1];

int g_TurnTeam = 0;

bool g_MatchStarted = false;

ConVar g_CvarTournamentReadyMode = null;
ConVar g_CvarRestartGame = null;

Handle g_HudSync = INVALID_HANDLE;

ArrayList g_PriorityEligible = null;
ArrayList g_PriorityActive = null;

bool g_RecordPriority = false;
bool g_MapChanging = false;

public Plugin myinfo =
{
    name = "PUG Pick",
    author = "No name",
    description = "",
    version = "1.0.0"
};

public void OnPluginStart()
{
    RegConsoleCmd("sm_pick", Command_Pick);
    RegConsoleCmd("sm_ready", Command_Ready);
    RegConsoleCmd("sm_unready", Command_Unready);
    RegConsoleCmd("sm_r", Command_Ready);
    RegConsoleCmd("sm_nr", Command_Unready);
    RegConsoleCmd("sm_status", Command_Status);
    RegConsoleCmd("sm_+1", Command_Prioritize);

    g_PriorityEligible = new ArrayList(ByteCountToCells(64));
    g_PriorityActive = new ArrayList(ByteCountToCells(64));

    g_HudSync = CreateHudSynchronizer();

    CreateTimer(3.0, Timer_ShowStatus, _, TIMER_REPEAT);

    g_CvarTournamentReadyMode = FindConVar("mp_tournament_readymode");
    g_CvarRestartGame = FindConVar("mp_restartgame");

    if (g_CvarTournamentReadyMode != null)
    {
        g_CvarTournamentReadyMode.SetInt(0);
    }

    HookEvent("teamplay_round_start", Event_RoundStart, EventHookMode_PostNoCopy);
}

public void OnMapStart()
{
    g_MapChanging = false;
    g_RecordPriority = false;

    // New map: players must type !prioritize again.
    if (g_PriorityActive != null)
    {
        g_PriorityActive.Clear();
    }

    ResetPugState();

    if (g_CvarTournamentReadyMode != null)
    {
        g_CvarTournamentReadyMode.SetInt(0);
    }
}

public void OnMapEnd()
{
    g_MapChanging = true;
    g_RecordPriority = false;
}

public void OnClientPutInServer(int client)
{
    g_PlayerReady[client] = false;
}

//public void OnClientDisconnect(int client)
//{
//    g_PlayerReady[client] = false;
//
//    if (!g_MapChanging)
//    {
//        RemovePriorityClient(client);
//    }
//}

public Action Command_Ready(int client, int args)
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
        ReplyToCommand(client, "[Pick] You must be on RED or BLU to ready.");
        return Plugin_Handled;
    }

    g_PlayerReady[client] = true;

    PrintToChatAll("[Pick] %N is READY.", client);
    ShowStatusToAll();

    CheckAllReadyAndStart();

    return Plugin_Handled;
}

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

public Action Command_Status(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    ShowStatusToClient(client);

    return Plugin_Handled;
}

public Action Command_Prioritize(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    ShowStatusToClient(client);

    return Plugin_Handled;
}

public Action Command_Pick(int client, int args)
{
    if (g_PicksLocked)
    {
        ReplyToCommand(client, "[Pick] Picking is disabled.");
        return Plugin_Handled;
    }

    if (!IsCaptain(client))
    {
        ReplyToCommand(client, "[Pick] Only RED/BLU Medics can pick.");
        return Plugin_Handled;
    }

    int team = GetClientTeam(client);

    if (!g_DraftStarted)
    {
        int otherTeam = GetOtherTeam(team);

        if (FindCaptain(otherTeam) == 0)
        {
            ReplyToCommand(client, "[Pick] Other team needs a Medic captain first.");
            return Plugin_Handled;
        }

        g_DraftStarted = true;
        g_TurnTeam = team;

        PrintToChatAll("[Pick] Draft started. %N picks first.", client);
    }

    if (team != g_TurnTeam)
    {
        ReplyToCommand(client, "[Pick] It is not your turn.");
        return Plugin_Handled;
    }

    if (CountTeamPlayers(team) >= TEAM_SIZE)
    {
        ReplyToCommand(client, "[Pick] Your team is already full.");
        return Plugin_Handled;
    }

    ShowPickMenu(client);

    return Plugin_Handled;
}

void ShowPickMenu(int captain)
{
    Menu menu = new Menu(MenuHandler_Pick);

    char title[128];
    Format(title, sizeof(title), "Pick a spectator | Team: %d/%d", CountTeamPlayers(g_TurnTeam), TEAM_SIZE);
    menu.SetTitle(title);

    int count = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        if (IsFakeClient(i))
        {
            continue;
        }

        if (GetClientTeam(i) != TEAM_SPEC)
        {
            continue;
        }

        char userid[16];
        char name[64];

        IntToString(GetClientUserId(i), userid, sizeof(userid));
        Format(name, sizeof(name), "%N", i);

        menu.AddItem(userid, name);
        count++;
    }

    if (count == 0)
    {
        delete menu;
        PrintToChat(captain, "[Pick] No spectators available.");
        return;
    }

    menu.ExitButton = true;
    menu.Display(captain, MENU_TIME_FOREVER);
}

public int MenuHandler_Pick(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action != MenuAction_Select)
    {
        return 0;
    }

    if (g_PicksLocked || !g_DraftStarted)
    {
        PrintToChat(client, "[Pick] Picking is disabled.");
        return 0;
    }

    if (!IsCaptain(client))
    {
        PrintToChat(client, "[Pick] Only Medic captains can pick.");
        return 0;
    }

    if (GetClientTeam(client) != g_TurnTeam)
    {
        PrintToChat(client, "[Pick] It is not your turn.");
        return 0;
    }

    char info[16];
    menu.GetItem(item, info, sizeof(info));

    int target = GetClientOfUserId(StringToInt(info));

    if (target == 0 || !IsClientInGame(target) || GetClientTeam(target) != TEAM_SPEC)
    {
        PrintToChat(client, "[Pick] That player is no longer available.");
        ShowPickMenu(client);
        return 0;
    }

    if (CountTeamPlayers(g_TurnTeam) >= TEAM_SIZE)
    {
        PrintToChat(client, "[Pick] Your team is full.");
        return 0;
    }

    g_PlayerReady[target] = false;

    ChangeClientTeam(target, g_TurnTeam);
    TF2_RespawnPlayer(target);

    PrintToChatAll("[Pick] %N picked %N.", client, target);

    ShowStatusToAll();

    if (CountTeamPlayers(TEAM_RED) >= TEAM_SIZE && CountTeamPlayers(TEAM_BLU) >= TEAM_SIZE)
    {
        g_PicksLocked = true;
        g_DraftStarted = false;

        PrintToChatAll("[Pick] Teams are full. Picking is disabled.");
        ShowStatusToAll();
        return 0;
    }

    g_TurnTeam = GetOtherTeam(g_TurnTeam);

    int nextCaptain = FindCaptain(g_TurnTeam);

    if (nextCaptain != 0)
    {
        PrintToChatAll("[Pick] It is now %N's turn.", nextCaptain);
        ShowPickMenu(nextCaptain);
    }
    else
    {
        PrintToChatAll("[Pick] Waiting for a Medic captain on the other team.");
    }

    return 0;
}

public Action Timer_ShowStatus(Handle timer)
{
    if (!g_DraftStarted && !HasSpectators())
    {
        return Plugin_Continue;
    }

    ShowStatusToAll();

    return Plugin_Continue;
}

void ShowStatusToAll()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        if (IsFakeClient(i))
        {
            continue;
        }

        ShowStatusToClient(i);
    }
}

void ClearStatusDisplay()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        if (IsFakeClient(i))
        {
            continue;
        }

        SetHudTextParams(
            0.72,
            0.15,
            0.1,
            255, 255, 255, 0
        );

        ShowSyncHudText(i, g_HudSync, "");
    }
}

void ShowStatusToClient(int client)
{
    char text[1024];
    BuildStatusText(text, sizeof(text));

    SetHudTextParams(
        0.72,   // x position: right side, about 1/4 from the right
        0.15,   // y position
        1.2,    // hold time, refreshed every 1 second
        255, 255, 255, 255
    );

    ShowSyncHudText(client, g_HudSync, "%s", text);
}

void BuildStatusText(char[] text, int maxlen)
{
    char waiting[256];
    char ready[256];
    char unready[256];

    int waitingCount = 0;
    int readyCount = 0;
    int unreadyCount = 0;

    waiting[0] = '\0';
    ready[0] = '\0';
    unready[0] = '\0';

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        if (IsFakeClient(i))
        {
            continue;
        }

        int team = GetClientTeam(i);

        if (team == TEAM_SPEC)
        {
            AddNameToList(waiting, sizeof(waiting), i, waitingCount);
            waitingCount++;
        }
        else if (team == TEAM_RED || team == TEAM_BLU)
        {
            if (g_PlayerReady[i])
            {
                AddNameToList(ready, sizeof(ready), i, readyCount);
                readyCount++;
            }
            else
            {
                AddNameToList(unready, sizeof(unready), i, unreadyCount);
                unreadyCount++;
            }
        }
    }

    if (waitingCount == 0)
    {
        Format(waiting, sizeof(waiting), "None");
    }

    if (readyCount == 0)
    {
        Format(ready, sizeof(ready), "None");
    }

    if (unreadyCount == 0)
    {
        Format(unready, sizeof(unready), "None");
    }

    Format(
        text,
        maxlen,
        "Waiting Players: %d\n%s\nReady Players: %d\n%s\nUnready Players: %d\n%s",
        waitingCount,
        waiting,
        readyCount,
        ready,
        unreadyCount,
        unready
    );
}

void AddNameToList(char[] list, int maxlen, int client, int currentCount)
{
    char name[80];

    Format(name, sizeof(name), "%N\n", client);

    StrCat(list, maxlen, name);
}

bool HasSpectators()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        if (IsFakeClient(i))
        {
            continue;
        }

        if (GetClientTeam(i) == TEAM_SPEC)
        {
            return true;
        }
    }

    return false;
}

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

int FindCaptain(int team)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        if (GetClientTeam(i) != team)
        {
            continue;
        }

        if (TF2_GetPlayerClass(i) == TFClass_Medic)
        {
            return i;
        }
    }

    return 0;
}

int CountTeamPlayers(int team)
{
    int count = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        if (GetClientTeam(i) == team)
        {
            count++;
        }
    }

    return count;
}

int GetOtherTeam(int team)
{
    if (team == TEAM_RED)
    {
        return TEAM_BLU;
    }

    return TEAM_RED;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    if (g_DraftStarted)
    {
        g_PicksLocked = true;
        g_DraftStarted = false;

        ShowStatusToAll();
    }
}

void CheckAllReadyAndStart()
{
    if (g_MatchStarted)
    {
        return;
    }

    if (CountTeamPlayers(TEAM_RED) != TEAM_SIZE || CountTeamPlayers(TEAM_BLU) != TEAM_SIZE)
    {
        return;
    }

    if (CountReadyPlayers() < 12)
    {
        return;
    }

    StartGame();
}

int CountReadyPlayers()
{
    int count = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        if (IsFakeClient(i))
        {
            continue;
        }

        int team = GetClientTeam(i);

        if (team != TEAM_RED && team != TEAM_BLU)
        {
            continue;
        }

        if (g_PlayerReady[i])
        {
            count++;
        }
    }

    return count;
}

void StartGame()
{
    g_MatchStarted = true;
    g_PicksLocked = true;
    g_DraftStarted = false;

    ClearStatusDisplay();

    ServerCommand("exec sourcemod/soap_live.cfg");

    if (g_CvarTournamentReadyMode != null)
    {
        g_CvarTournamentReadyMode.SetInt(0);
    }

    if (g_CvarRestartGame != null)
    {
        g_CvarRestartGame.SetInt(5);
    }
    else
    {
        ServerCommand("mp_restartgame 5");
    }
}

void ResetPugState()
{
    g_DraftStarted = false;
    g_PicksLocked = false;
    g_TurnTeam = 0;
    g_MatchStarted = false;

    for (int i = 1; i <= MaxClients; i++)
    {
        g_PlayerReady[i] = false;
    }
    ShowStatusToAll();
}