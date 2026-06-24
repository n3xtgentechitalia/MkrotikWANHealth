# Manual — MikroTik WAN Health Monitor (EN)

> 🇮🇹 Versione italiana: [`MANUALE.md`](MANUALE.md)

Complete guide to the `WANHealth` script for **RouterOS 7.2.x** (tested),
generic for any MikroTik router/firewall with a PPPoE WAN.

**Placeholders used across the project** (replace them before use):

| Placeholder       | Meaning                                  | Example          |
|-------------------|------------------------------------------|------------------|
| `{nomewan}`       | PPPoE interface name                     | `pppoe-out1`     |
| `{rete_a_valle}`  | Downstream network to gate (CIDR)        | `192.0.2.0/24`   |
| `{token_telegram}`| Telegram bot token                       | `123:ABC...`     |
| `{chat_id}`       | Telegram recipient chat ID               | `12345678`       |
| `{ip_gateway}`    | Gateway/egress IP used for tests         | `192.0.2.1`      |

- [1. Purpose](#1-purpose)
- [2. Requirements](#2-requirements)
- [3. Installation](#3-installation)
- [4. Configuration parameters](#4-configuration-parameters)
- [5. How it works (states)](#5-how-it-works-states)
- [6. Exponential backoff](#6-exponential-backoff)
- [7. The forward gate](#7-the-forward-gate)
- [8. What to expect (logs and timing)](#8-what-to-expect-logs-and-timing)
- [9. Telegram notifications](#9-telegram-notifications)
- [10. Verification and reachability tests](#10-verification-and-reachability-tests)
- [11. Recommended tuning](#11-recommended-tuning)
- [12. FAQ / Troubleshooting](#12-faq--troubleshooting)
- [13. Uninstall](#13-uninstall)

---

## 1. Purpose

On unstable PPPoE links (flapping), downstream systems (firewalls, monitors)
react to every bounce: the link comes up, is considered "good", then drops
again → **false positives**.

`WANHealth` adds **hysteresis**: it declares the WAN truly `UP` only after the
**PPP session has stayed up, uninterrupted, for `reqStable` seconds**. If the
link keeps flapping, that time **grows exponentially** (backoff), so you stop
opening/closing downstream traffic over and over.

---

## 2. Requirements

- MikroTik RouterOS **7.2.x** (tested; also works on 7.0.x+).
- A PPPoE WAN (`{nomewan}`).
- (Optional) a Telegram bot for notifications.
- (Optional, for the gate) a network routed toward downstream devices.

---

## 3. Installation

1. Edit `wan-health.rsc` and replace the placeholders (at least `{nomewan}`;
   for Telegram `{token_telegram}` and `{chat_id}`, or set `doNotify=false`).
2. Upload `wan-health.rsc` to **Files** (WinBox/WebFig).
3. Edit `install.rsc` (top: `{nomewan}`, `{rete_a_valle}`, `useGate`) and
   upload it to **Files**.
4. Run:
   ```
   /import file-name=install.rsc
   ```

`install.rsc` creates the gate rule (if `useGate=true`), registers the
`WANHealth` script and the 10s scheduler.

### Manual install (without install.rsc)

```rsc
/system script add name=WANHealth source=[/file get [find name="wan-health.rsc"] contents]
/system scheduler add name=WANHealth-sched interval=10s start-time=startup on-event="/system script run WANHealth"
```
Gate (`place-before=0` only if the filter table is not empty):
```rsc
:if ([:len [/ip firewall filter find]] > 0) do={
    /ip firewall filter add chain=forward src-address={rete_a_valle} out-interface={nomewan} action=drop comment="WAN-GATE" place-before=0
} else={
    /ip firewall filter add chain=forward src-address={rete_a_valle} out-interface={nomewan} action=drop comment="WAN-GATE"
}
```

> `pollSec` in the script **must** equal the scheduler `interval`.

---

## 4. Configuration parameters

Edit them at the top of `wan-health.rsc` (or in **System → Scripts → WANHealth**).

| Parameter       | Default               | What it does |
|-----------------|-----------------------|--------------|
| `wanIf`         | `{nomewan}`           | **Exact** name of the PPPoE interface. |
| `pingTarget`    | `1.1.1.1`             | Public host used to verify real reachability. |
| `pingCount`     | `3`                   | Pings per cycle (1 success is enough). |
| `stableBase`    | `600`                 | **Base** wait (s) of continuous PPP session for `UP`. |
| `backoffFactor` | `2`                   | Wait multiplier per flap in the window. |
| `stableMax`     | `7200`                | Maximum wait cap (s) with backoff. |
| `pollSec`       | `10`                  | Polling interval (= scheduler `interval`). |
| `flapWindow`    | `1800`                | Window (s) to count flaps **and** decay the penalty. |
| `flapThreshold` | `3`                   | Drops in the window → **FLAPPING** alarm. |
| `gateBlock`     | `true`                | `true` = drive the forward gate based on state. |
| `gateComment`   | `WAN-GATE`            | Comment of the `/ip firewall filter` rule used as gate. |
| `doNotify`      | `true`                | `false` = log only, no Telegram. |
| `tgToken`       | `{token_telegram}`    | Telegram bot token. |
| `tgChat`        | `{chat_id}`           | Recipient chat ID. |

---

## 5. How it works (states)

Every `pollSec` seconds the script:
1. reads PPPoE session **status and uptime** (`/interface pppoe-client monitor`);
2. verifies **real reachability** with a ping to `pingTarget`;
3. updates the state machine.

```
DOWN ──link up──> RISING ──session up for ≥ reqStable──> UP
  ▲                 │                                      │
  └──── drop ───────┴──────── drop / reconnect ────────────┘   (FLAP)
```

- **DOWN**: PPPoE unusable (disconnected or ping fails). Gate **closed**.
- **RISING**: PPPoE up but session still "young" (uptime < `reqStable`).
  Gate **closed**: this is where false positives are cancelled.
- **UP**: session up for ≥ `reqStable` **and** ping OK. Gate **open**.

Stability is anchored to the **PPP session uptime**: a reconnect resets that
uptime, so even a flap occurring **between two polls** (under 10s) is detected
and restarts the wait.

---

## 6. Exponential backoff

The required wait `reqStable` is not fixed: it starts at `stableBase` and
**doubles** (`backoffFactor`) on each flap counted within `flapWindow`, up to
the `stableMax` cap.

```
reqStable = min( stableBase × backoffFactor^(flap-1) , stableMax )
```

With defaults (`stableBase=600`, `backoffFactor=2`, `stableMax=7200`):

| Flaps in window | Required wait | Plain   |
|-----------------|---------------|---------|
| 1 (quiet line)  | 600 s         | 10 min  |
| 2               | 1200 s        | 20 min  |
| 3               | 2400 s        | 40 min  |
| 4               | 4800 s        | 80 min  |
| 5 and beyond    | 7200 s (cap)  | 2 hours |

**Decay**: if the WAN is `UP` and no flaps occur for a whole `flapWindow`, the
counter resets and the wait returns to `stableBase`. The flappier the line, the
longer downstream traffic stays closed; once it calms down, recovery is quick.

---

## 7. The forward gate

With a single WAN, the most effective action is the **gate**: an
`/ip firewall filter` rule (chain `forward`, `action=drop`, comment `WAN-GATE`)
that blocks the downstream network's egress.

The script drives it **deterministically** every cycle:
- `whState = UP` → rule **disabled** → traffic **allowed**;
- any other state → rule **enabled** → traffic **blocked**.

This way downstream devices see a clean state (down = down) and don't bounce.
Router-originated traffic (chain `output`) is untouched: WANHealth pings and
Telegram notifications work even with the gate closed.

> **Empty firewall**: if you have no rules in the filter chain yet,
> `place-before=0` errors with *"failure: no such item"*. Use the conditional
> block from §3.

> To disable the gate: `gateBlock=false` (log/notify only).

---

## 8. What to expect (logs and timing)

Example sequence in `/log print where message~"WANHealth"`
(with `{nomewan}` = `pppoe-out1`):

```
13:00:10 warning WANHealth: pppoe-out1 su da 8s, attendo stabilita' (600s, flap=1)
13:10:20 info    WANHealth: pppoe-out1 STABILE (sessione su da 10m12s, richiesti 600s) -> UP
13:25:40 warning WANHealth: pppoe-out1 DOWN (flap #2 nella finestra 1800s)
13:26:10 warning WANHealth: pppoe-out1 riconnessa (flap #2) - attesa stabilita' ora 1200s (backoff)
13:46:20 info    WANHealth: pppoe-out1 STABILE (sessione su da 20m05s, richiesti 1200s) -> UP
14:05:00 error   WANHealth: FLAPPING su pppoe-out1 - 3 cadute in 1800s
```

In short:
- **After install/reboot** downstream traffic stays closed until the PPP
  session has been up for `stableBase` (default 10 min). This is intended.
- **On each flap** the reopen wait doubles (10→20→40 min…).
- **When the line calms down**, after a flap-free window it returns to 10 min.
- `UP` means: PPP session stable for a while **and** Internet reachable.

---

## 9. Telegram notifications

1. Create a bot with **@BotFather** → get the `token` (`{token_telegram}`).
2. Send a message to the bot, then open
   `https://api.telegram.org/bot<TOKEN>/getUpdates` and read the `chat.id`.
3. Set `tgToken` and `tgChat` in `WANHealth`, keep `doNotify=true`.

Notified events: transition to `UP`, `DOWN` with flap count, and the
**FLAPPING** alarm beyond `flapThreshold`. To disable Telegram: `doNotify=false`.

---

## 10. Verification and reachability tests

### 10.1 From the ROUTER (SSH/terminal)

```
/log print where message~"WANHealth"
/system scheduler print
/ip firewall filter print where comment="WAN-GATE"
/interface pppoe-client monitor {nomewan} once
/ip route print where active
```

**Status + session gateway**: `monitor` shows `remote-address` (P2P gateway)
and `local-address` (your point-to-point IP).

**Ping the P2P gateway** (`<REMOTE>` = `remote-address` above):
```
/ping <REMOTE> interface={nomewan} count=5
```

**Ping the Internet via the WAN**:
```
/ping 1.1.1.1 interface={nomewan} count=5
```

**Which egress traffic uses**:
```
/ip route check 1.1.1.1 once
```
Expected: `nexthop` = PPPoE gateway, `interface` = `{nomewan}`.

**Traceroute/ping egressing from your gateway** (source = `{ip_gateway}`):
ready commands in [`examples/test-trace.rsc`](../examples/test-trace.rsc):
```
/tool traceroute 1.1.1.1 src-address={ip_gateway} interface={nomewan} count=1
/ping 1.1.1.1 src-address={ip_gateway} interface={nomewan} count=5
```

### 10.2 From a network PC (Windows)

Ready script: [`examples/test-windows.ps1`](../examples/test-windows.ps1)
```
powershell -ExecutionPolicy Bypass -File .\test-windows.ps1 -RouterGw {ip_gateway}
powershell -ExecutionPolicy Bypass -File .\test-windows.ps1 -RouterGw {ip_gateway} -Continuous
```
Manual commands:
```
ipconfig                       :: read "Default Gateway"
ping {ip_gateway}              :: upstream gateway/router
ping 1.1.1.1                   :: Internet
tracert -d 1.1.1.1             :: path (1st hop = your gateway)
pathping -n 1.1.1.1            :: per-hop loss
ping -t 1.1.1.1                :: continuous (watch the flaps)
```
Forced source (only if the IP is assigned to the PC): `tracert -S <ip> 1.1.1.1`,
`ping -S <ip> 1.1.1.1`.

### 10.3 From a network PC (Linux / macOS)

```
ip route | grep default        # gateway (Linux)
ping -c5 {ip_gateway}
ping -c5 1.1.1.1
traceroute -n 1.1.1.1
ip route get 1.1.1.1           # which gateway/egress it uses
mtr -n 1.1.1.1                 # live ping+traceroute (if installed)
```
Forced source: `traceroute -s <ip> -i <iface> 1.1.1.1`.

### 10.4 Interpretation

| Upstream gateway | Internet (1.1.1.1) | Meaning |
|------------------|--------------------|---------|
| replies          | replies            | All good, WAN `UP` and gate open. |
| replies          | does **not** reply | Gateway ok but WAN down **or gate closed** (`DOWN`/`RISING`). |
| does **not** reply | —                | L2/L3 problem downstream (cable/VLAN/IP), not PPPoE. |

> Distinguish "gate closed" from "WAN down": from the router run
> `/ping 1.1.1.1 interface={nomewan}`. If it works from the router but not
> downstream, the **gate** is blocking (correct: WAN not yet stable). Check
> with `/ip firewall filter print where comment="WAN-GATE"` (must be `disabled`
> only when state is `UP`).

---

## 11. Recommended tuning

- **Very flappy line**: raise `stableBase` (e.g. `900`) and/or `stableMax`
  (e.g. `10800` = 3h).
- **Almost stable line, fast recovery**: lower `stableBase` (e.g. `120`).
- **More aggressive backoff**: `backoffFactor=3` (600→1800→5400→cap).
- **Flap window**: keep `flapWindow` ≥ a couple of times `stableBase`.
- If you change `pollSec`, update the scheduler `interval` too.

---

## 12. FAQ / Troubleshooting

**Downstream traffic stays closed for a long time after install.**
Correct: it needs `stableBase` (10 min) of continuous session before opening.
Check the log: `attendo stabilita' (...)` then `... -> UP`.

**Error creating the gate rule (`failure: no such item` / `place-before`).**
The `/ip firewall filter` table is empty: use the conditional block from §3/§7
or drop `place-before=0`.

**Log `regola gate 'WAN-GATE' non trovata` (rule not found).**
You didn't create the filter rule or the comment doesn't match. Create the rule
(see §7) or set `gateBlock=false`.

**No Telegram notifications.**
Check `tgToken`/`tgChat`, router Internet reachability, and look for
`invio Telegram fallito` in the log.

**Seconds count looks wrong.**
`pollSec` and the scheduler `interval` must match.

**I only want monitoring, no traffic blocking.**
`gateBlock=false` (and `useGate=false` in install.rsc).

---

## 13. Uninstall

```
/system scheduler remove [find name="WANHealth-sched"]
/system script remove [find name="WANHealth"]
/ip firewall filter remove [find comment="WAN-GATE"]
```

(The `wh*` globals reset by themselves on reboot.)
