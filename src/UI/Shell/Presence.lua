--[[ UI/Shell/Presence.lua
  Presence + readiness toasts (ns.UI.Presence) — the proactive layer over the passive
  panel. The dashboard's refresh runs ~every 2s and computes a verdict; Presence.Notify
  watches for *transitions* and surfaces a toast + a ping on the title-bar dot. Seeded
  silently on first sight so a login / reload doesn't fire, and readiness toasts only
  fire between two "real" verdicts (never to/from the wait/offline placeholders), so
  flicker stays quiet.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Presence = {}
ns.UI.Presence = Presence

local Theme = ns.UI.Theme
local L = ns.L

local function classIcon(cls)
  local atlas = (cls and cls ~= "") and ("classicon-" .. strlower(cls)) or nil
  if atlas and Theme.AtlasExists(atlas) then return atlas end
  return "Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend"   -- friendly fallback
end

local toastSeeded, lastLinked, lastVerdict
local REAL_VERDICT = { ready = true, amber = true, red = true }

--- Watch for presence/readiness transitions and surface a toast + title-dot ping.
function Presence.Notify(snap, verdict)
  local Toast = ns.UI and ns.UI.Toast
  local linked = ns.state.linked == true
  local name = ns.state.partnerName or L["Partner"]
  if not toastSeeded then   -- first observation this session: record, don't announce
    toastSeeded, lastLinked, lastVerdict = true, linked, verdict
    return
  end
  local pal, snd = Theme.VERDICT_RGB, SOUNDKIT
  if Toast then
    if linked ~= lastLinked then
      if linked then
        Toast.Show({ title = string.format(L["%s is online"], name), subtitle = L["Linked up — syncing now."],
          icon = classIcon(snap.cls), color = pal.ready, sound = snd and snd.UI_BNET_TOAST })
      else
        Toast.Show({ title = string.format(L["%s went offline"], name), subtitle = L["You'll reconnect automatically."],
          icon = classIcon(snap.cls), color = pal.offline, sound = snd and snd.UI_BNET_TOAST })
      end
    elseif linked and verdict ~= lastVerdict and REAL_VERDICT[verdict] and REAL_VERDICT[lastVerdict] then
      if verdict == "ready" then
        Toast.Show({ title = string.format(L["%s is ready"], name), subtitle = L["All checks passed — good to pull."],
          icon = classIcon(snap.cls), color = pal.ready, sound = snd and snd.READY_CHECK })
      elseif verdict == "red" and lastVerdict == "ready" then
        Toast.Show({ title = string.format(L["%s is no longer ready"], name), subtitle = L["Hold up — a check needs attention."],
          icon = classIcon(snap.cls), color = pal.red, sound = snd and snd.UI_BNET_TOAST })
      end
    end
  end
  if verdict ~= lastVerdict then
    ns.UI.Header.Ping(pal[verdict] or pal.wait)   -- visual cue even when toasts are off
  end
  lastLinked, lastVerdict = linked, verdict
end

return Presence
