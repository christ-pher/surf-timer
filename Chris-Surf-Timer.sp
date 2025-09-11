#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <ripext>

// ───────────────────────────────────────────
// ConVars
// ───────────────────────────────────────────
ConVar gCvarDrawInterval;        // sm_speedtext_interval
ConVar gCvarApiUrl;              // sm_speedtext_api (prefilled)
ConVar gCvarZonePad;             // sm_zones_pad
ConVar gCvarRestartZBoost;       // sm_restart_zboost
ConVar gCvarEnable;              // sm_speedtext_enable
ConVar gCvarApplySettings;       // sm_speedtext_applysettings
ConVar gCvarRecordAnnounce;      // sm_surf_announce_interval

Handle g_DrawTimer = INVALID_HANDLE;
Handle g_AnnounceTimer = INVALID_HANDLE;

// Per-client state
float g_Speed2D[MAXPLAYERS + 1];
int   g_ZoneState[MAXPLAYERS + 1]; // 0=None, 1=Start, 2=End, 3=Both

// Timer state per client
int   g_RunState[MAXPLAYERS + 1];
bool  g_WasInStart[MAXPLAYERS + 1];
float g_RunStartTime[MAXPLAYERS + 1];
float g_RunLastTime[MAXPLAYERS + 1];

// Zones (axis-aligned boxes) + centers
bool  g_HaveZones = false;
float g_StartMin[3], g_StartMax[3], g_StartCenter[3];
float g_EndMin[3],   g_EndMax[3],   g_EndCenter[3];

// ───────────────────────────────────────────
// Records System
// ───────────────────────────────────────────
char g_CurrentMap[64];
char g_RecordsPath[PLATFORM_MAX_PATH];

// Server record
float g_ServerRecord = 0.0;
char  g_ServerRecordHolder[MAX_NAME_LENGTH];
char  g_ServerRecordSteamId[32];

// Personal bests (cache for connected players)
float g_PersonalBest[MAXPLAYERS + 1];
char  g_PlayerSteamId[MAXPLAYERS + 1][32];
bool  g_HasPersonalBest[MAXPLAYERS + 1];

// ───────────────────────────────────────────
// Plugin Info
// ───────────────────────────────────────────
public Plugin myinfo =
{
    name        = "Chris Surf Timer BETA",
    author      = "christ-pher",
    description = "Surf timer with records for CS:Source",
    version     = "2.0.1"
};

// ───────────────────────────────────────────
// Lifecycle
// ───────────────────────────────────────────
public void OnPluginStart()
{
    // Smooth UI: 0.01s
    gCvarDrawInterval = CreateConVar("sm_speedtext_interval", "0.01",
        "UI update interval (seconds).", 0, true, 0.005, true, 1.00);

    // Your hosted API template
    gCvarApiUrl = CreateConVar(
        "sm_speedtext_api",
        "https://christ-pher.github.io/surf-zones/maps/{map}.json",
        "API template with {map}. Must provide start_zone/end_zone with A/B points (x/y/z). Optional 'settings' object."
    );

    gCvarZonePad        = CreateConVar("sm_zones_pad", "16.0", "Padding (units) for zone checks.", 0, true, 0.0, true, 128.0);
    gCvarRestartZBoost  = CreateConVar("sm_restart_zboost", "8.0",  "Extra Z on !r teleport.", 0, true, 0.0, true, 64.0);
    gCvarEnable         = CreateConVar("sm_speedtext_enable", "1",   "Enable UI drawing (1/0)");
    gCvarApplySettings  = CreateConVar("sm_speedtext_applysettings", "1",
        "Apply allowed CVARs from API.settings and optional exec_cfg (1/0)");
    gCvarRecordAnnounce = CreateConVar("sm_surf_announce_interval", "180.0",
        "Interval (seconds) between server record announcements. 0 = disabled", 0, true, 0.0);

    RegConsoleCmd("sm_r",              Cmd_RestartToStartCenter, "Teleport to center of start zone (resets run).");
    RegConsoleCmd("sm_top",            Cmd_ShowTopTimes,         "Show top 10 times for this map.");
    RegConsoleCmd("sm_pb",             Cmd_ShowPersonalBest,     "Show your personal best time.");
    RegConsoleCmd("sm_sr",             Cmd_ShowServerRecord,     "Show the server record.");
    RegAdminCmd ("sm_zones_refresh",   Cmd_ZonesRefresh,         ADMFLAG_GENERIC, "Fetch zones/settings from API now.");
    RegAdminCmd ("sm_zones_debug",     Cmd_ZonesDebug,           ADMFLAG_GENERIC, "Print current boxes/centers to console.");
    RegAdminCmd ("sm_records_reset",   Cmd_ResetRecords,         ADMFLAG_ROOT, "Reset all records for current map.");
    RegConsoleCmd("sm_speedtext_ping", Cmd_PingUI,               "Print a one-shot CenterText line.");

    HookConVarChange(gCvarDrawInterval, OnIntervalChanged);
    HookConVarChange(gCvarRecordAnnounce, OnAnnounceIntervalChanged);
    
    StartDrawTimer();
}

public void OnMapStart()
{
    GetCurrentMap(g_CurrentMap, sizeof(g_CurrentMap));
    
    // Build records file path
    BuildPath(Path_SM, g_RecordsPath, sizeof(g_RecordsPath), "data/surf_records");
    if (!DirExists(g_RecordsPath))
        CreateDirectory(g_RecordsPath, 511);
    
    Format(g_RecordsPath, sizeof(g_RecordsPath), "%s/%s.json", g_RecordsPath, g_CurrentMap);
    
    g_HaveZones = false;
    ResetAllRuns();
    LoadRecords();
    StartDrawTimer();
    StartAnnounceTimer();
    FetchZonesFromApi_RIPExt(0);
}

public void OnMapEnd()
{
    if (g_DrawTimer != INVALID_HANDLE)
    {
        CloseHandle(g_DrawTimer);
        g_DrawTimer = INVALID_HANDLE;
    }
    
    if (g_AnnounceTimer != INVALID_HANDLE)
    {
        CloseHandle(g_AnnounceTimer);
        g_AnnounceTimer = INVALID_HANDLE;
    }
}

public void OnClientPutInServer(int client)
{
    ResetRun(client);
    
    if (!IsFakeClient(client))
    {
        GetClientAuthId(client, AuthId_Steam2, g_PlayerSteamId[client], 32);
        LoadPlayerRecord(client);
        CreateTimer(3.0, Timer_WelcomeMessage, GetClientUserId(client));
    }
}

public void OnClientDisconnect(int client)
{
    ResetRun(client);
    g_PersonalBest[client] = 0.0;
    g_HasPersonalBest[client] = false;
    g_PlayerSteamId[client][0] = '\0';
}

public Action Timer_WelcomeMessage(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "\x04[SURF]\x01 Welcome to \x03%s\x01!", g_CurrentMap);
        
        if (g_ServerRecord > 0.0)
        {
            char timeStr[32];
            FormatDurationCenti(g_ServerRecord, timeStr, sizeof(timeStr));
            PrintToChat(client, "\x04[SURF]\x01 Server Record: \x03%s\x01 by \x03%s", timeStr, g_ServerRecordHolder);
        }
        else
        {
            PrintToChat(client, "\x04[SURF]\x01 No server record set yet!");
        }
        
        if (g_HasPersonalBest[client])
        {
            char pbStr[32];
            FormatDurationCenti(g_PersonalBest[client], pbStr, sizeof(pbStr));
            PrintToChat(client, "\x04[SURF]\x01 Your Personal Best: \x03%s", pbStr);
        }
        else
        {
            PrintToChat(client, "\x04[SURF]\x01 You haven't set a time on this map yet.");
        }
    }
    return Plugin_Handled;
}

void ResetAllRuns()
{
    for (int i = 1; i <= MaxClients; i++)
        ResetRun(i);
}

void ResetRun(int client)
{
    g_RunState[client]     = 0;
    g_WasInStart[client]   = false;
    g_RunStartTime[client] = 0.0;
    g_RunLastTime[client]  = 0.0;
}

// ───────────────────────────────────────────
// Timer control
// ───────────────────────────────────────────
public void OnIntervalChanged(ConVar cvar, const char[] ov, const char[] nv)
{
    StartDrawTimer();
}

public void OnAnnounceIntervalChanged(ConVar cvar, const char[] ov, const char[] nv)
{
    StartAnnounceTimer();
}

void StartDrawTimer()
{
    if (g_DrawTimer != INVALID_HANDLE)
    {
        CloseHandle(g_DrawTimer);
        g_DrawTimer = INVALID_HANDLE;
    }

    float interval = gCvarDrawInterval.FloatValue;
    if (interval < 0.005) interval = 0.005;
    g_DrawTimer = CreateTimer(interval, Timer_DrawUI, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StartAnnounceTimer()
{
    if (g_AnnounceTimer != INVALID_HANDLE)
    {
        CloseHandle(g_AnnounceTimer);
        g_AnnounceTimer = INVALID_HANDLE;
    }
    
    float interval = gCvarRecordAnnounce.FloatValue;
    if (interval > 0.0)
    {
        g_AnnounceTimer = CreateTimer(interval, Timer_AnnounceRecord, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_AnnounceRecord(Handle timer)
{
    if (g_ServerRecord > 0.0)
    {
        char timeStr[32];
        FormatDurationCenti(g_ServerRecord, timeStr, sizeof(timeStr));
        PrintToChatAll("\x04[SURF]\x01 Server Record on \x03%s\x01: \x03%s\x01 by \x03%s", 
            g_CurrentMap, timeStr, g_ServerRecordHolder);
    }
    return Plugin_Continue;
}

// ───────────────────────────────────────────
// Per-frame compute (+ run-timer transitions)
// ───────────────────────────────────────────
public void OnGameFrame()
{
    float vel[3], pos[3];

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsPlayerAlive(client))
        {
            g_Speed2D[client]   = 0.0;
            g_ZoneState[client] = 0;
            continue;
        }

        GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
        g_Speed2D[client] = SquareRoot(vel[0] * vel[0] + vel[1] * vel[1]);

        if (!g_HaveZones)
        {
            g_ZoneState[client] = 0;
            continue;
        }

        GetClientAbsOrigin(client, pos);

        bool inStart = PointInBox(pos, g_StartMin, g_StartMax);
        bool inEnd   = PointInBox(pos, g_EndMin,   g_EndMax);

        if (inStart && inEnd) g_ZoneState[client] = 3;
        else if (inStart)     g_ZoneState[client] = 1;
        else if (inEnd)       g_ZoneState[client] = 2;
        else                  g_ZoneState[client] = 0;

        // Run state machine
        if (inStart)
        {
            if (g_RunState[client] != 0)
            {
                g_RunState[client]     = 0;
                g_RunStartTime[client] = 0.0;
                g_RunLastTime[client]  = 0.0;
            }
            g_WasInStart[client] = true;
        }
        else
        {
            if (g_WasInStart[client] && g_RunState[client] == 0)
            {
                g_RunState[client]     = 1; // Running
                g_RunStartTime[client] = GetGameTime();
                g_RunLastTime[client]  = 0.0;
            }
            g_WasInStart[client] = false;
        }

        if (inEnd && g_RunState[client] == 1)
        {
            float t = GetGameTime() - g_RunStartTime[client];
            if (t < 0.0) t = 0.0;

            g_RunLastTime[client]  = t;
            g_RunState[client]     = 2;

            OnPlayerFinished(client, t);
        }
    }
}

void OnPlayerFinished(int client, float time)
{
    if (IsFakeClient(client))
        return;
    
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    
    char timeStr[32];
    FormatDurationCenti(time, timeStr, sizeof(timeStr));
    
    // Compare to personal best
    bool newPB = false;
    char pbDiffStr[32] = "";
    bool pbImproved = false;
    
    if (g_HasPersonalBest[client])
    {
        float pbDiff = time - g_PersonalBest[client];
        
        if (time < g_PersonalBest[client])
        {
            newPB = true;
            pbImproved = true;
            FormatDurationCenti(g_PersonalBest[client] - time, pbDiffStr, sizeof(pbDiffStr));
            Format(pbDiffStr, sizeof(pbDiffStr), "PB -%s", pbDiffStr);
        }
        else
        {
            FormatDurationCenti(pbDiff, pbDiffStr, sizeof(pbDiffStr));
            Format(pbDiffStr, sizeof(pbDiffStr), "PB +%s", pbDiffStr);
        }
    }
    else
    {
        newPB = true;
        pbImproved = true;
        strcopy(pbDiffStr, sizeof(pbDiffStr), "First Time");
    }
    
    // Compare to server record
    bool newSR = false;
    char srDiffStr[32] = "";
    bool srImproved = false;
    
    if (g_ServerRecord > 0.0)
    {
        float srDiff = time - g_ServerRecord;
        
        if (time < g_ServerRecord)
        {
            newSR = true;
            srImproved = true;
            FormatDurationCenti(g_ServerRecord - time, srDiffStr, sizeof(srDiffStr));
            Format(srDiffStr, sizeof(srDiffStr), "SR -%s", srDiffStr);
        }
        else
        {
            FormatDurationCenti(srDiff, srDiffStr, sizeof(srDiffStr));
            Format(srDiffStr, sizeof(srDiffStr), "SR +%s", srDiffStr);
        }
    }
    else
    {
        newSR = true;
        srImproved = true;
        strcopy(srDiffStr, sizeof(srDiffStr), "NEW SR");
    }
    
    // Announce completion with both comparisons
    if (newSR)
    {
        PrintToChatAll("\x04[SURF] \x03★ NEW SERVER RECORD! ★");
    }
    
    // Build the final message with proper colors
    // Using if statements to add color codes to each part
    char finalMessage[256];
    char pbColoredText[64];
    char srColoredText[64];
    
    if (pbImproved)
    {
        Format(pbColoredText, sizeof(pbColoredText), "\x04%s", pbDiffStr);  // Green for PB improvement
    }
    else
    {
        Format(pbColoredText, sizeof(pbColoredText), "\x01%s", pbDiffStr);  // White for slower PB
    }
    
    if (srImproved)
    {
        Format(srColoredText, sizeof(srColoredText), "\x04%s", srDiffStr);  // Green for SR improvement
    }
    else
    {
        Format(srColoredText, sizeof(srColoredText), "\x01%s", srDiffStr);  // White for slower than SR
    }
    
    // Print the final message - time is already \x03 (green/team color)
    PrintToChatAll("\x04[SURF]\x01 %s completed in \x03%s\x01 | %s\x01 | %s", 
        name, timeStr, pbColoredText, srColoredText);
    
    // Update records
    if (newPB || !g_HasPersonalBest[client])
    {
        g_PersonalBest[client] = time;
        g_HasPersonalBest[client] = true;
        SavePlayerRecord(client, time);
    }
    
    if (newSR || g_ServerRecord == 0.0)
    {
        g_ServerRecord = time;
        strcopy(g_ServerRecordHolder, sizeof(g_ServerRecordHolder), name);
        strcopy(g_ServerRecordSteamId, sizeof(g_ServerRecordSteamId), g_PlayerSteamId[client]);
        SaveRecords();
    }
}

bool PointInBox(const float p[3], const float bmin[3], const float bmax[3])
{
    return (p[0] >= bmin[0] && p[0] <= bmax[0] &&
            p[1] >= bmin[1] && p[1] <= bmax[1] &&
            p[2] >= bmin[2] && p[2] <= bmax[2]);
}

// ───────────────────────────────────────────
// Records Management
// ───────────────────────────────────────────
void LoadRecords()
{
    g_ServerRecord = 0.0;
    g_ServerRecordHolder[0] = '\0';
    g_ServerRecordSteamId[0] = '\0';
    
    if (!FileExists(g_RecordsPath))
    {
        PrintToServer("[SURF] No records file found for %s", g_CurrentMap);
        return;
    }
    
    File file = OpenFile(g_RecordsPath, "r");
    if (file == null)
    {
        PrintToServer("[SURF] Failed to open records file");
        return;
    }
    
    char buffer[8192];
    file.ReadString(buffer, sizeof(buffer));
    delete file;
    
    JSONObject root = JSONObject.FromString(buffer);
    if (root == null)
    {
        PrintToServer("[SURF] Failed to parse records JSON");
        return;
    }
    
    // Load server record
    if (root.HasKey("server_record"))
    {
        JSONObject sr = view_as<JSONObject>(root.Get("server_record"));
        g_ServerRecord = sr.GetFloat("time");
        sr.GetString("name", g_ServerRecordHolder, sizeof(g_ServerRecordHolder));
        sr.GetString("steamid", g_ServerRecordSteamId, sizeof(g_ServerRecordSteamId));
        delete sr;
    }
    
    delete root;
    
    PrintToServer("[SURF] Loaded records for %s. SR: %.2f by %s", 
        g_CurrentMap, g_ServerRecord, g_ServerRecordHolder);
}

void LoadPlayerRecord(int client)
{
    g_PersonalBest[client] = 0.0;
    g_HasPersonalBest[client] = false;
    
    if (!FileExists(g_RecordsPath))
        return;
    
    File file = OpenFile(g_RecordsPath, "r");
    if (file == null)
        return;
    
    char buffer[8192];
    file.ReadString(buffer, sizeof(buffer));
    delete file;
    
    JSONObject root = JSONObject.FromString(buffer);
    if (root == null)
        return;
    
    if (root.HasKey("players"))
    {
        JSONObject players = view_as<JSONObject>(root.Get("players"));
        if (players.HasKey(g_PlayerSteamId[client]))
        {
            JSONObject player = view_as<JSONObject>(players.Get(g_PlayerSteamId[client]));
            g_PersonalBest[client] = player.GetFloat("time");
            g_HasPersonalBest[client] = true;
            delete player;
        }
        delete players;
    }
    
    delete root;
}

void SavePlayerRecord(int client, float time)
{
    JSONObject root;
    
    if (FileExists(g_RecordsPath))
    {
        File file = OpenFile(g_RecordsPath, "r");
        if (file != null)
        {
            char buffer[8192];
            file.ReadString(buffer, sizeof(buffer));
            delete file;
            root = JSONObject.FromString(buffer);
        }
    }
    
    if (root == null)
        root = new JSONObject();
    
    JSONObject players;
    if (root.HasKey("players"))
    {
        players = view_as<JSONObject>(root.Get("players"));
    }
    else
    {
        players = new JSONObject();
    }
    
    JSONObject player = new JSONObject();
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    player.SetFloat("time", time);
    player.SetString("name", name);
    player.SetInt("date", GetTime());
    
    players.Set(g_PlayerSteamId[client], player);
    root.Set("players", players);
    
    char output[8192];
    root.ToString(output, sizeof(output), JSON_INDENT(2));
    
    File file = OpenFile(g_RecordsPath, "w");
    if (file != null)
    {
        file.WriteString(output, false);
        delete file;
    }
    
    delete player;
    delete players;
    delete root;
}

void SaveRecords()
{
    JSONObject root;
    
    if (FileExists(g_RecordsPath))
    {
        File file = OpenFile(g_RecordsPath, "r");
        if (file != null)
        {
            char buffer[8192];
            file.ReadString(buffer, sizeof(buffer));
            delete file;
            root = JSONObject.FromString(buffer);
        }
    }
    
    if (root == null)
        root = new JSONObject();
    
    // Save server record
    JSONObject sr = new JSONObject();
    sr.SetFloat("time", g_ServerRecord);
    sr.SetString("name", g_ServerRecordHolder);
    sr.SetString("steamid", g_ServerRecordSteamId);
    sr.SetInt("date", GetTime());
    root.Set("server_record", sr);
    
    char output[8192];
    root.ToString(output, sizeof(output), JSON_INDENT(2));
    
    File file = OpenFile(g_RecordsPath, "w");
    if (file != null)
    {
        file.WriteString(output, false);
        delete file;
    }
    
    delete sr;
    delete root;
}

// ───────────────────────────────────────────
// UI draw — Center text
// ───────────────────────────────────────────
public Action Timer_DrawUI(Handle timer)
{
    if (!gCvarEnable.BoolValue)
        return Plugin_Continue;

    float now = GetGameTime();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsPlayerAlive(client))
            continue;

        int speedInt = RoundToNearest(g_Speed2D[client]);
        char timeText[32];
        BuildTimeText(client, now, timeText, sizeof(timeText));

        char line[64];
        Format(line, sizeof(line), "%d | %s", speedInt, timeText);

        PrintCenterText(client, "%s", line);
    }

    return Plugin_Continue;
}

void BuildTimeText(int client, float now, char[] out, int len)
{
    if (!g_HaveZones)
    {
        strcopy(out, len, "N/A");
        return;
    }

    if (g_RunState[client] == 0)
    {
        strcopy(out, len, "00:00.00");
    }
    else if (g_RunState[client] == 1)
    {
        float t = now - g_RunStartTime[client];
        if (t < 0.0) t = 0.0;
        FormatDurationCenti(t, out, len);
    }
    else
    {
        FormatDurationCenti(g_RunLastTime[client], out, len);
    }
}

void FormatDurationCenti(float seconds, char[] out, int len)
{
    int centi = (seconds <= 0.0) ? 0 : RoundToNearest(seconds * 100.0);
    int minutes = centi / 6000;
    int secs    = (centi % 6000) / 100;
    int cs      = centi % 100;

    // Always format as MM:SS.MS
    Format(out, len, "%02d:%02d.%02d", minutes, secs, cs);
}

// ───────────────────────────────────────────
// Commands
// ───────────────────────────────────────────
public Action Cmd_ShowTopTimes(int client, int args)
{
    if (!FileExists(g_RecordsPath))
    {
        ReplyToCommand(client, "[SURF] No records found for this map.");
        return Plugin_Handled;
    }
    
    File file = OpenFile(g_RecordsPath, "r");
    if (file == null)
    {
        ReplyToCommand(client, "[SURF] Failed to read records.");
        return Plugin_Handled;
    }
    
    char buffer[8192];
    file.ReadString(buffer, sizeof(buffer));
    delete file;
    
    JSONObject root = JSONObject.FromString(buffer);
    if (root == null)
    {
        ReplyToCommand(client, "[SURF] Failed to parse records.");
        return Plugin_Handled;
    }
    
    PrintToChat(client, "\x04[SURF]\x01 Top Times for \x03%s\x01:", g_CurrentMap);
    
    if (root.HasKey("server_record") && g_ServerRecord > 0.0)
    {
        char timeStr[32];
        FormatDurationCenti(g_ServerRecord, timeStr, sizeof(timeStr));
        PrintToChat(client, "\x04[SR]\x01 %s - \x03%s", g_ServerRecordHolder, timeStr);
    }
    else
    {
        PrintToChat(client, "\x04[SURF]\x01 No times set yet!");
    }
    
    delete root;
    return Plugin_Handled;
}

public Action Cmd_ShowPersonalBest(int client, int args)
{
    if (g_HasPersonalBest[client])
    {
        char timeStr[32];
        FormatDurationCenti(g_PersonalBest[client], timeStr, sizeof(timeStr));
        PrintToChat(client, "\x04[SURF]\x01 Your Personal Best: \x03%s", timeStr);
    }
    else
    {
        PrintToChat(client, "\x04[SURF]\x01 You haven't set a time on this map yet.");
    }
    return Plugin_Handled;
}

public Action Cmd_ShowServerRecord(int client, int args)
{
    if (g_ServerRecord > 0.0)
    {
        char timeStr[32];
        FormatDurationCenti(g_ServerRecord, timeStr, sizeof(timeStr));
        PrintToChat(client, "\x04[SURF]\x01 Server Record: \x03%s\x01 by \x03%s", timeStr, g_ServerRecordHolder);
    }
    else
    {
        PrintToChat(client, "\x04[SURF]\x01 No server record set yet!");
    }
    return Plugin_Handled;
}

public Action Cmd_ResetRecords(int client, int args)
{
    if (FileExists(g_RecordsPath))
        DeleteFile(g_RecordsPath);
    
    g_ServerRecord = 0.0;
    g_ServerRecordHolder[0] = '\0';
    g_ServerRecordSteamId[0] = '\0';
    
    for (int i = 1; i <= MaxClients; i++)
    {
        g_PersonalBest[i] = 0.0;
        g_HasPersonalBest[i] = false;
    }
    
    ReplyToCommand(client, "[SURF] All records for %s have been reset.", g_CurrentMap);
    PrintToChatAll("\x04[SURF]\x01 All records for this map have been reset!");
    return Plugin_Handled;
}

public Action Cmd_PingUI(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;

    int speedInt = RoundToNearest(g_Speed2D[client]);
    char timeText[32];
    BuildTimeText(client, GetGameTime(), timeText, sizeof(timeText));

    char line[64];
    Format(line, sizeof(line), "PING • %d | %s", speedInt, timeText);

    PrintCenterText(client, "%s", line);
    ReplyToCommand(client, "[SURF] Center text sent.");
    return Plugin_Handled;
}

public Action Cmd_RestartToStartCenter(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;

    if (!IsPlayerAlive(client))
    {
        PrintToChat(client, "\x04[SURF]\x01 You must be alive to restart.");
        return Plugin_Handled;
    }

    if (!g_HaveZones)
    {
        PrintToChat(client, "\x04[SURF]\x01 No start zone available.");
        return Plugin_Handled;
    }

    float ang[3];
    GetClientEyeAngles(client, ang);

    float zeroVel[3] = {0.0, 0.0, 0.0};

    float dst[3];
    dst[0] = g_StartCenter[0];
    dst[1] = g_StartCenter[1];
    dst[2] = g_StartCenter[2];

    TeleportEntity(client, dst, ang, zeroVel);

    // Reset run to Ready in Start
    g_RunState[client]     = 0;
    g_WasInStart[client]   = true;
    g_RunStartTime[client] = 0.0;
    g_RunLastTime[client]  = 0.0;

    PrintToChat(client, "\x04[SURF]\x01 Teleported to Start.");
    return Plugin_Handled;
}

public Action Cmd_ZonesDebug(int client, int args)
{
    if (!g_HaveZones)
    {
        ReplyToCommand(client, "[SURF] No zones loaded.");
        return Plugin_Handled;
    }

    PrintToServer("[SURF] START box: min(%.2f, %.2f, %.2f)  max(%.2f, %.2f, %.2f)  center(%.2f, %.2f, %.2f)",
                  g_StartMin[0], g_StartMin[1], g_StartMin[2],
                  g_StartMax[0], g_StartMax[1], g_StartMax[2],
                  g_StartCenter[0], g_StartCenter[1], g_StartCenter[2]);
    PrintToServer("[SURF] END   box: min(%.2f, %.2f, %.2f)  max(%.2f, %.2f, %.2f)  center(%.2f, %.2f, %.2f)",
                  g_EndMin[0], g_EndMin[1], g_EndMin[2],
                  g_EndMax[0], g_EndMax[1], g_EndMax[2],
                  g_EndCenter[0], g_EndCenter[1], g_EndCenter[2]);

    ReplyToCommand(client,
        "[SURF] START min(%.1f,%.1f,%.1f) max(%.1f,%.1f,%.1f) center(%.1f,%.1f,%.1f)",
        g_StartMin[0], g_StartMin[1], g_StartMin[2],
        g_StartMax[0], g_StartMax[1], g_StartMax[2],
        g_StartCenter[0], g_StartCenter[1], g_StartCenter[2]);

    ReplyToCommand(client,
        "[SURF] END   min(%.1f,%.1f,%.1f) max(%.1f,%.1f,%.1f) center(%.1f,%.1f,%.1f)",
        g_EndMin[0], g_EndMin[1], g_EndMin[2],
        g_EndMax[0], g_EndMax[1], g_EndMax[2],
        g_EndCenter[0], g_EndCenter[1], g_EndCenter[2]);

    return Plugin_Handled;
}

public Action Cmd_ZonesRefresh(int client, int args)
{
    FetchZonesFromApi_RIPExt(client);
    ReplyToCommand(client, "[SURF] Fetching zones/settings… check server console.");
    return Plugin_Handled;
}

// ───────────────────────────────────────────
// RIPExt HTTP fetch + JSON parsing
// ───────────────────────────────────────────
void FetchZonesFromApi_RIPExt(int invoker)
{
    char map[64];
    GetCurrentMap(map, sizeof(map));

    char templ[256];
    GetConVarString(gCvarApiUrl, templ, sizeof(templ));

    char url[512];
    BuildUrlFromTemplate(templ, map, url, sizeof(url));

    PrintToServer("[SURF] Fetching zones/settings for '%s' -> %s", map, url);
    if (invoker > 0 && IsClientInGame(invoker))
        ReplyToCommand(invoker, "[SURF] GET %s", url);

    HTTPRequest request = new HTTPRequest(url);
    request.SetHeader("Accept", "application/json");
    request.Get(OnZonesHttpResponse, invoker);
}

void OnZonesHttpResponse(HTTPResponse response, any value)
{
    int invoker = view_as<int>(value);

    if (response.Status != HTTPStatus_OK)
    {
        PrintToServer("[SURF] RIPExt HTTP failed. Status=%d", response.Status);
        if (invoker > 0 && IsClientInGame(invoker))
            ReplyToCommand(invoker, "[SURF] RIPExt HTTP failed. Status=%d", response.Status);
        return;
    }

    JSONObject root = view_as<JSONObject>(response.Data);
    if (root == null)
    {
        PrintToServer("[SURF] RIPExt: response JSON root is null.");
        if (invoker > 0 && IsClientInGame(invoker))
            ReplyToCommand(invoker, "[SURF] Parse error: JSON root is null.");
        return;
    }

    bool zonesOk = ParseZonesFromRoot(root);
    if (!zonesOk)
    {
        PrintToServer("[SURF] Failed to parse zones JSON.");
        if (invoker > 0 && IsClientInGame(invoker))
            ReplyToCommand(invoker, "[SURF] Failed to parse zones JSON. See server console.");
        return;
    }

    g_HaveZones = true;

    PrintToServer("[SURF] Zones loaded. START min(%.1f,%.1f,%.1f) max(%.1f,%.1f,%.1f) center(%.1f,%.1f,%.1f)",
        g_StartMin[0], g_StartMin[1], g_StartMin[2],
        g_StartMax[0], g_StartMax[1], g_StartMax[2],
        g_StartCenter[0], g_StartCenter[1], g_StartCenter[2]);

    PrintToServer("[SURF] Zones loaded. END   min(%.1f,%.1f,%.1f) max(%.1f,%.1f,%.1f) center(%.1f,%.1f,%.1f)",
        g_EndMin[0], g_EndMin[1], g_EndMin[2],
        g_EndMax[0], g_EndMax[1], g_EndMax[2],
        g_EndCenter[0], g_EndCenter[1], g_EndCenter[2]);

    if (gCvarApplySettings.BoolValue)
        ApplySettingsFromRoot(root, invoker);

    if (invoker > 0 && IsClientInGame(invoker))
    {
        ReplyToCommand(invoker, "[SURF] Zones loaded%s.",
            gCvarApplySettings.BoolValue ? " & settings applied (if provided)" : "");
    }
}

// ───────────────────────────────────────────
// JSON helpers (RIPExt) — zones
// ───────────────────────────────────────────
bool ParseZonesFromRoot(JSONObject root)
{
    JSONObject start = view_as<JSONObject>(root.Get("start_zone"));
    if (start == null) return false;
    bool okStart = ParseBox(start, g_StartMin, g_StartMax);
    delete start;

    JSONObject end = view_as<JSONObject>(root.Get("end_zone"));
    if (end == null) return false;
    bool okEnd = ParseBox(end, g_EndMin, g_EndMax);
    delete end;

    if (!okStart || !okEnd) return false;

    float pad = gCvarZonePad.FloatValue;
    ApplyPadding(g_StartMin, g_StartMax, pad);
    ApplyPadding(g_EndMin,   g_EndMax,   pad);

    ComputeCenter(g_StartMin, g_StartMax, g_StartCenter);
    ComputeCenter(g_EndMin,   g_EndMax,   g_EndCenter);
    return true;
}

bool ParseBox(JSONObject boxObj, float outMin[3], float outMax[3])
{
    JSONObject A = view_as<JSONObject>(boxObj.Get("a"));
    JSONObject B = view_as<JSONObject>(boxObj.Get("b"));
    if (A == null || B == null)
    {
        if (A != null) delete A;
        if (B != null) delete B;
        return false;
    }

    float ax = A.GetFloat("x"), ay = A.GetFloat("y"), az = A.GetFloat("z");
    float bx = B.GetFloat("x"), by = B.GetFloat("y"), bz = B.GetFloat("z");

    delete A;
    delete B;

    outMin[0] = (ax < bx) ? ax : bx;
    outMin[1] = (ay < by) ? ay : by;
    outMin[2] = (az < bz) ? az : bz;

    outMax[0] = (ax > bx) ? ax : bx;
    outMax[1] = (ay > by) ? ay : by;
    outMax[2] = (az > bz) ? az : bz;
    return true;
}

void ApplyPadding(float bmin[3], float bmax[3], float pad)
{
    if (pad <= 0.0) return;
    bmin[0] -= pad; bmin[1] -= pad; bmin[2] -= pad;
    bmax[0] += pad; bmax[1] += pad; bmax[2] += pad;
}

void ComputeCenter(const float bmin[3], const float bmax[3], float outCenter[3])
{
    outCenter[0] = (bmin[0] + bmax[0]) * 0.5;
    outCenter[1] = (bmin[1] + bmax[1]) * 0.5;
    outCenter[2] = (bmin[2] + bmax[2]) * 0.5;
}

// ───────────────────────────────────────────
// JSON helpers — settings
// ───────────────────────────────────────────
void ApplySettingsFromRoot(JSONObject root, int invoker)
{
    JSONObject s = view_as<JSONObject>(root.Get("settings"));
    if (s == null)
    {
        PrintToServer("[SURF] No 'settings' object in API; skipping settings.");
        return;
    }

    ApplyFloatCvarIfPresent(s, "mp_roundtime");
    ApplyIntCvarIfPresent  (s, "mp_timelimit");
    ApplyIntCvarIfPresent  (s, "mp_maxrounds");
    ApplyIntCvarIfPresent  (s, "mp_freezetime");
    ApplyIntCvarIfPresent  (s, "sv_gravity");
    ApplyIntCvarIfPresent  (s, "sv_airaccelerate");
    ApplyIntCvarIfPresent  (s, "bot_quota");

    if (HasKeyString(s, "exec_cfg"))
    {
        char cfg[128];
        s.GetString("exec_cfg", cfg, sizeof(cfg));
        if (cfg[0] != '\0')
        {
            PrintToServer("[SURF] Executing cfg from API: %s", cfg);
            ServerCommand("exec \"%s\"", cfg);
        }
    }

    if (invoker > 0 && IsClientInGame(invoker))
        ReplyToCommand(invoker, "[SURF] Applied settings from API (if present).");

    delete s;
}

void ApplyFloatCvarIfPresent(JSONObject s, const char[] name)
{
    if (!HasKeyNumber(s, name)) return;

    ConVar cv = FindConVar(name);
    if (cv == null)
    {
        PrintToServer("[SURF] settings: cvar '%s' not found; skipping.", name);
        return;
    }

    float v = s.GetFloat(name);
    SetConVarFloat(cv, v);
    PrintToServer("[SURF] settings: %s = %.3f", name, v);
}

void ApplyIntCvarIfPresent(JSONObject s, const char[] name)
{
    if (!HasKeyNumber(s, name)) return;

    ConVar cv = FindConVar(name);
    if (cv == null)
    {
        PrintToServer("[SURF] settings: cvar '%s' not found; skipping.", name);
        return;
    }

    int v = s.GetInt(name);
    SetConVarInt(cv, v);
    PrintToServer("[SURF] settings: %s = %d", name, v);
}

bool HasKeyNumber(JSONObject o, const char[] key)
{
    return o.HasKey(key);
}

bool HasKeyString(JSONObject o, const char[] key)
{
    return o.HasKey(key);
}

// ───────────────────────────────────────────
// Helpers
// ───────────────────────────────────────────
void BuildUrlFromTemplate(const char[] templ, const char[] map, char[] outUrl, int outlen)
{
    strcopy(outUrl, outlen, templ);

    int pos = StrContains(outUrl, "{map}", false);
    if (pos != -1)
    {
        char pre[512], suf[512];
        strcopy(pre, sizeof(pre), outUrl);
        pre[pos] = '\0';
        strcopy(suf, sizeof(suf), outUrl[pos + 5]);
        Format(outUrl, outlen, "%s%s%s", pre, map, suf);
    }
}
