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

// Apply per-map settings from API
ConVar gCvarApplySettings;       // sm_speedtext_applysettings

Handle g_DrawTimer = INVALID_HANDLE;

// Per-client state
float g_Speed2D[MAXPLAYERS + 1];
int   g_ZoneState[MAXPLAYERS + 1]; // 0=None, 1=Start, 2=End, 3=Both

// Timer state per client
// 0 = Ready (in start, timer 0 & idle)
// 1 = Running
// 2 = Finished (frozen until back in start or !r)
int   g_RunState[MAXPLAYERS + 1];
bool  g_WasInStart[MAXPLAYERS + 1];
float g_RunStartTime[MAXPLAYERS + 1];
float g_RunLastTime[MAXPLAYERS + 1];

// Zones (axis-aligned boxes) + centers
bool  g_HaveZones = false;
float g_StartMin[3], g_StartMax[3], g_StartCenter[3];
float g_EndMin[3],   g_EndMax[3],   g_EndCenter[3];

// ───────────────────────────────────────────
// Plugin Info
// ───────────────────────────────────────────
public Plugin myinfo =
{
    name        = "Chris Surf Timer",
    author      = "christopher",
    description = "Surf timer for CS:Source",
    version     = "1.0.0"
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

    RegConsoleCmd("sm_r",              Cmd_RestartToStartCenter, "Teleport to center of start zone (resets run).");
    RegAdminCmd ("sm_zones_refresh",   Cmd_ZonesRefresh,         ADMFLAG_GENERIC, "Fetch zones/settings from API now.");
    RegAdminCmd ("sm_zones_debug",     Cmd_ZonesDebug,           ADMFLAG_GENERIC, "Print current boxes/centers to console.");
    RegConsoleCmd("sm_speedtext_ping", Cmd_PingUI,               "Print a one-shot CenterText line.");

    HookConVarChange(gCvarDrawInterval, OnIntervalChanged);
    StartDrawTimer();
}

public void OnMapStart()
{
    g_HaveZones = false;
    ResetAllRuns();
    StartDrawTimer();
    FetchZonesFromApi_RIPExt(0);
}

public void OnMapEnd()
{
    if (g_DrawTimer != INVALID_HANDLE)
    {
        CloseHandle(g_DrawTimer);
        g_DrawTimer = INVALID_HANDLE;
    }
}

public void OnClientPutInServer(int client) { ResetRun(client); }
public void OnClientDisconnect(int client)  { ResetRun(client); }

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

            char n[MAX_NAME_LENGTH];
            GetClientName(client, n, sizeof(n));

            char ts[32];
            FormatDurationCenti(t, ts, sizeof(ts)); // two decimals

            PrintToChatAll("\x04[SURF]\x01 %s completed in \x03%s\x01.", n, ts);
        }
    }
}

bool PointInBox(const float p[3], const float bmin[3], const float bmax[3])
{
    return (p[0] >= bmin[0] && p[0] <= bmax[0] &&
            p[1] >= bmin[1] && p[1] <= bmax[1] &&
            p[2] >= bmin[2] && p[2] <= bmax[2]);
}

// ───────────────────────────────────────────
// UI draw — Center text (top-middle, engine fixed)
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
        strcopy(out, len, "0.00");
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

// Format seconds into two decimals: "M:SS.xx" (minutes if needed) or "S.xx"
void FormatDurationCenti(float seconds, char[] out, int len)
{
    int centi = (seconds <= 0.0) ? 0 : RoundToNearest(seconds * 100.0);
    int minutes = centi / 6000;
    int secs    = (centi % 6000) / 100;
    int cs      = centi % 100;

    if (minutes > 0)
        Format(out, len, "%d:%02d.%02d", minutes, secs, cs);
    else
        Format(out, len, "%d.%02d", secs, cs);
}

// ───────────────────────────────────────────
// Commands
// ───────────────────────────────────────────
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
    // dst[2] = g_StartCenter[2] + gCvarRestartZBoost.FloatValue;

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
// JSON helpers — settings (allow-list & exec)
// ───────────────────────────────────────────
void ApplySettingsFromRoot(JSONObject root, int invoker)
{
    JSONObject s = view_as<JSONObject>(root.Get("settings"));
    if (s == null)
    {
        PrintToServer("[SURF] No 'settings' object in API; skipping settings.");
        return;
    }

    // Helper lambdas
    ApplyFloatCvarIfPresent(s, "mp_roundtime");
    ApplyIntCvarIfPresent  (s, "mp_timelimit");
    ApplyIntCvarIfPresent  (s, "mp_maxrounds");
    ApplyIntCvarIfPresent  (s, "mp_freezetime");
    ApplyIntCvarIfPresent  (s, "sv_gravity");
    ApplyIntCvarIfPresent  (s, "sv_airaccelerate");
    ApplyIntCvarIfPresent  (s, "bot_quota");

    // Optional: exec one cfg file from the API
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

// Safely apply float CVAR if provided & allowed
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

// Safely apply int CVAR if provided & allowed
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

// Key presence helpers (for RIPExt JSON)
// If your RIPExt build does not support HasKey(), you can remove these
// checks and instead add booleans next to each setting in your JSON.
bool HasKeyNumber(JSONObject o, const char[] key)
{
    // Prefer HasKey if available; fall back to a sentinel approach if needed.
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
