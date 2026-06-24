# Manuale — MikroTik WAN Health Monitor (IT)

> 🇬🇧 English version: [`MANUAL.md`](MANUAL.md)

Guida completa allo script `WANHealth` per **RouterOS 7.2.x** (testato),
generico per qualsiasi router/firewall MikroTik con WAN PPPoE.

**Placeholder usati in tutto il progetto** (sostituiscili prima dell'uso):

| Placeholder      | Significato                                   | Esempio          |
|------------------|-----------------------------------------------|------------------|
| `{nomewan}`      | Nome interfaccia PPPoE                         | `pppoe-out1`     |
| `{rete_a_valle}` | Rete a valle da gate-are (CIDR)                | `192.0.2.0/24`   |
| `{token_telegram}`| Token del bot Telegram                        | `123:ABC...`     |
| `{chat_id}`      | Chat ID destinatario Telegram                  | `12345678`       |
| `{ip_gateway}`   | IP del gateway/uscita per i test               | `192.0.2.1`      |

- [1. A cosa serve](#1-a-cosa-serve)
- [2. Requisiti](#2-requisiti)
- [3. Installazione](#3-installazione)
- [4. Parametri di configurazione](#4-parametri-di-configurazione)
- [5. Come funziona (stati)](#5-come-funziona-stati)
- [6. Backoff esponenziale dell'attesa](#6-backoff-esponenziale-dellattesa)
- [7. Il gate forward](#7-il-gate-forward)
- [8. Cosa aspettarsi (log e tempi)](#8-cosa-aspettarsi-log-e-tempi)
- [9. Notifiche Telegram](#9-notifiche-telegram)
- [10. Verifica e test di raggiungibilità](#10-verifica-e-test-di-raggiungibilità)
- [11. Tuning consigliato](#11-tuning-consigliato)
- [12. FAQ / Troubleshooting](#12-faq--troubleshooting)
- [13. Disinstallazione](#13-disinstallazione)

---

## 1. A cosa serve

Su linee PPPoE instabili (flapping) i sistemi a valle (firewall, monitoraggi)
reagiscono a ogni rimbalzo: la linea sale, viene considerata "buona", e subito
ricade → **falsi positivi**.

`WANHealth` introduce **isteresi**: dichiara la WAN realmente `UP` solo dopo
che la **sessione PPP è rimasta su, ininterrotta, per un tempo `reqStable`**.
Se la linea continua a flappare, quel tempo **cresce in modo esponenziale**
(backoff), così si smette di riaprire/chiudere di continuo il traffico a valle.

---

## 2. Requisiti

- MikroTik RouterOS **7.2.x** (testato; funziona anche su 7.0.x+).
- Una WAN PPPoE (`{nomewan}`).
- (Opzionale) un bot Telegram per le notifiche.
- (Opzionale, per il gate) una rete instradata verso apparati a valle.

---

## 3. Installazione

1. Modifica `wan-health.rsc` e sostituisci i placeholder (almeno `{nomewan}`;
   per Telegram `{token_telegram}` e `{chat_id}`, oppure `doNotify=false`).
2. Carica `wan-health.rsc` in **Files** (WinBox/WebFig).
3. Modifica `install.rsc` (in cima: `{nomewan}`, `{rete_a_valle}`, `useGate`)
   e caricalo in **Files**.
4. Esegui:
   ```
   /import file-name=install.rsc
   ```

`install.rsc` crea (se `useGate=true`) la regola gate, registra lo script
`WANHealth` e lo scheduler ogni 10s.

### Installazione manuale (senza install.rsc)

```rsc
/system script add name=WANHealth source=[/file get [find name="wan-health.rsc"] contents]
/system scheduler add name=WANHealth-sched interval=10s start-time=startup on-event="/system script run WANHealth"
```
Gate (solo se non vuoto il firewall serve `place-before=0`):
```rsc
:if ([:len [/ip firewall filter find]] > 0) do={
    /ip firewall filter add chain=forward src-address={rete_a_valle} out-interface={nomewan} action=drop comment="WAN-GATE" place-before=0
} else={
    /ip firewall filter add chain=forward src-address={rete_a_valle} out-interface={nomewan} action=drop comment="WAN-GATE"
}
```

> `pollSec` nello script **deve** essere uguale a `interval` dello scheduler.

---

## 4. Parametri di configurazione

Si modificano in cima a `wan-health.rsc` (o in **System → Scripts → WANHealth**).

| Parametro       | Default               | Cosa fa |
|-----------------|-----------------------|---------|
| `wanIf`         | `{nomewan}`           | Nome **esatto** dell'interfaccia PPPoE. |
| `pingTarget`    | `1.1.1.1`             | Host pubblico per verificare la reale raggiungibilità. |
| `pingCount`     | `3`                   | Ping per ciclo (basta 1 successo). |
| `stableBase`    | `600`                 | Attesa **base** (s) di sessione PPP continua per `UP`. |
| `backoffFactor` | `2`                   | Moltiplicatore dell'attesa a ogni flap nella finestra. |
| `stableMax`     | `7200`                | Tetto massimo (s) dell'attesa con backoff. |
| `pollSec`       | `10`                  | Intervallo di polling (= `interval` scheduler). |
| `flapWindow`    | `1800`                | Finestra (s) per contare i flap **e** far decadere la penalità. |
| `flapThreshold` | `3`                   | N. cadute nella finestra → allarme **FLAPPING**. |
| `gateBlock`     | `true`                | `true` = pilota il gate forward in base allo stato. |
| `gateComment`   | `WAN-GATE`            | Commento della regola `/ip firewall filter` usata come gate. |
| `doNotify`      | `true`                | `false` = solo log, niente Telegram. |
| `tgToken`       | `{token_telegram}`    | Token del bot Telegram. |
| `tgChat`        | `{chat_id}`           | Chat ID destinatario. |

---

## 5. Come funziona (stati)

Ogni `pollSec` secondi lo script:
1. legge **stato e uptime** della sessione PPPoE (`/interface pppoe-client monitor`);
2. verifica la **reale raggiungibilità** con un ping a `pingTarget`;
3. aggiorna la macchina a stati.

```
DOWN ──linea su──> RISING ──sessione su da ≥ reqStable──> UP
  ▲                  │                                     │
  └──── cade ────────┴──────── cade / riconnette ──────────┘   (FLAP)
```

- **DOWN**: PPPoE non utilizzabile (disconnessa o ping KO). Gate **chiuso**.
- **RISING**: PPPoE su ma sessione ancora "giovane" (uptime < `reqStable`).
  Gate **chiuso**: qui si annulla il falso positivo.
- **UP**: sessione su da ≥ `reqStable` **e** ping OK. Gate **aperto**.

La stabilità è ancorata all'**uptime della sessione PPP**: una riconnessione
azzera quell'uptime, quindi anche un flap avvenuto **tra due poll** (sotto i
10s) viene rilevato e fa ripartire l'attesa.

---

## 6. Backoff esponenziale dell'attesa

L'attesa richiesta `reqStable` non è fissa: parte da `stableBase` e
**raddoppia** (`backoffFactor`) a ogni flap conteggiato nella finestra
`flapWindow`, fino al tetto `stableMax`.

```
reqStable = min( stableBase × backoffFactor^(flap-1) , stableMax )
```

Con i default (`stableBase=600`, `backoffFactor=2`, `stableMax=7200`):

| Flap nella finestra | Attesa richiesta | In chiaro |
|---------------------|------------------|-----------|
| 1 (linea tranquilla)| 600 s            | 10 min    |
| 2                   | 1200 s           | 20 min    |
| 3                   | 2400 s           | 40 min    |
| 4                   | 4800 s           | 80 min    |
| 5 e oltre           | 7200 s (tetto)   | 2 ore     |

**Decadimento**: se la WAN è `UP` e per un'intera `flapWindow` non avvengono
flap, il contatore si azzera e l'attesa torna a `stableBase`. Più la linea è
ballerina, più a lungo il traffico a valle resta chiuso; quando si calma, si
torna rapidi.

---

## 7. Il gate forward

Con una WAN singola, l'azione più efficace è il **gate**: una regola
`/ip firewall filter` (chain `forward`, `action=drop`, commento `WAN-GATE`)
che blocca l'uscita della rete a valle.

Lo script la pilota in modo **deterministico** a ogni ciclo:
- `whState = UP` → regola **disabilitata** → traffico **ammesso**;
- ogni altro stato → regola **abilitata** → traffico **bloccato**.

Così gli apparati a valle vedono uno stato pulito (giù = giù) e non rimbalzano.
Il traffico **originato dal router** (chain `output`) non è toccato: ping di
WANHealth e notifiche Telegram funzionano anche a gate chiuso.

> **Firewall vuoto**: se non hai ancora regole nel chain filter, `place-before=0`
> dà errore *"failure: no such item"*. Usa il blocco condizionale di §3.

> Per disattivare il gate: `gateBlock=false` (resta solo log/notifica).

---

## 8. Cosa aspettarsi (log e tempi)

Esempio di sequenza in `/log print where message~"WANHealth"`
(con `{nomewan}` = `pppoe-out1`):

```
13:00:10 warning WANHealth: pppoe-out1 su da 8s, attendo stabilita' (600s, flap=1)
13:10:20 info    WANHealth: pppoe-out1 STABILE (sessione su da 10m12s, richiesti 600s) -> UP
13:25:40 warning WANHealth: pppoe-out1 DOWN (flap #2 nella finestra 1800s)
13:26:10 warning WANHealth: pppoe-out1 riconnessa (flap #2) - attesa stabilita' ora 1200s (backoff)
13:46:20 info    WANHealth: pppoe-out1 STABILE (sessione su da 20m05s, richiesti 1200s) -> UP
14:05:00 error   WANHealth: FLAPPING su pppoe-out1 - 3 cadute in 1800s
```

In sintesi:
- **Dopo l'installazione/riavvio** il traffico a valle resta chiuso finché la
  sessione PPP non è su da `stableBase` (default 10 min). È voluto.
- **A ogni flap** l'attesa per riaprire raddoppia (10→20→40 min…).
- **Quando la linea si calma**, dopo una finestra senza flap si torna ai 10 min.
- Lo stato `UP` significa: sessione PPP stabile da tempo **e** Internet OK.

---

## 9. Notifiche Telegram

1. Crea un bot con **@BotFather** → ottieni il `token` (`{token_telegram}`).
2. Scrivi un messaggio al bot, poi apri
   `https://api.telegram.org/bot<TOKEN>/getUpdates` e leggi il `chat.id`.
3. In `WANHealth` imposta `tgToken` e `tgChat`, lascia `doNotify=true`.

Vengono notificati: passaggio a `UP`, `DOWN` con conteggio flap, e l'allarme
**FLAPPING** oltre `flapThreshold`. Se non vuoi Telegram: `doNotify=false`.

---

## 10. Verifica e test di raggiungibilità

### 10.1 Dal ROUTER (SSH/terminale)

```
/log print where message~"WANHealth"
/system scheduler print
/ip firewall filter print where comment="WAN-GATE"
/interface pppoe-client monitor {nomewan} once
/ip route print where active
```

**Stato + gateway sessione**: `monitor` mostra `remote-address` (gateway P2P) e
`local-address` (tuo IP punto-punto).

**Ping del gateway P2P** (`<REMOTE>` = `remote-address` letto sopra):
```
/ping <REMOTE> interface={nomewan} count=5
```

**Ping Internet uscendo dalla WAN**:
```
/ping 1.1.1.1 interface={nomewan} count=5
```

**Quale uscita usa il traffico**:
```
/ip route check 1.1.1.1 once
```
Atteso: `nexthop` = gateway PPPoE, `interface` = `{nomewan}`.

**Traceroute/ping in uscita dal tuo gateway** (sorgente = `{ip_gateway}`):
comandi pronti in [`examples/test-trace.rsc`](../examples/test-trace.rsc):
```
/tool traceroute 1.1.1.1 src-address={ip_gateway} interface={nomewan} count=1
/ping 1.1.1.1 src-address={ip_gateway} interface={nomewan} count=5
```

### 10.2 Da un PC della rete (Windows)

Script pronto: [`examples/test-windows.ps1`](../examples/test-windows.ps1)
```
powershell -ExecutionPolicy Bypass -File .\test-windows.ps1 -RouterGw {ip_gateway}
powershell -ExecutionPolicy Bypass -File .\test-windows.ps1 -RouterGw {ip_gateway} -Continuous
```
Comandi manuali:
```
ipconfig                       :: leggi "Gateway predefinito"
ping {ip_gateway}              :: gateway/router upstream
ping 1.1.1.1                   :: Internet
tracert -d 1.1.1.1             :: percorso (1o hop = tuo gateway)
pathping -n 1.1.1.1            :: perdita per hop
ping -t 1.1.1.1                :: continuo (osserva i flap)
```
Sorgente forzata (solo se l'IP è assegnato al PC): `tracert -S <ip> 1.1.1.1`,
`ping -S <ip> 1.1.1.1`.

### 10.3 Da un PC della rete (Linux / macOS)

```
ip route | grep default        # gateway (Linux)
ping -c5 {ip_gateway}
ping -c5 1.1.1.1
traceroute -n 1.1.1.1
ip route get 1.1.1.1           # via quale gateway/uscita passa
mtr -n 1.1.1.1                 # ping+traceroute live (se installato)
```
Sorgente forzata: `traceroute -s <ip> -i <iface> 1.1.1.1`.

### 10.4 Interpretazione

| Gateway upstream | Internet (1.1.1.1) | Significato |
|------------------|--------------------|-------------|
| risponde         | risponde           | Tutto OK, WAN `UP` e gate aperto. |
| risponde         | **non** risponde   | Gateway ok ma WAN giù **o gate chiuso** (`DOWN`/`RISING`). |
| **non** risponde | —                  | Problema L2/L3 a valle (cavo/VLAN/IP), non la PPPoE. |

> Distinguere "gate chiuso" da "WAN giù": dal router fai `/ping 1.1.1.1 interface={nomewan}`.
> Se dal router funziona ma a valle no, è il **gate** che blocca (corretto:
> WAN non ancora stabile). Verifica con
> `/ip firewall filter print where comment="WAN-GATE"` (deve essere `disabled`
> solo quando lo stato è `UP`).

---

## 11. Tuning consigliato

- **Linea molto ballerina**: alza `stableBase` (es. `900`) e/o `stableMax`
  (es. `10800` = 3h).
- **Linea quasi stabile, recupero rapido**: abbassa `stableBase` (es. `120`).
- **Backoff più aggressivo**: `backoffFactor=3` (600→1800→5400→tetto).
- **Finestra flap**: tieni `flapWindow` ≥ a un paio di volte `stableBase`.
- Cambiando `pollSec`, aggiorna anche `interval` dello scheduler.

---

## 12. FAQ / Troubleshooting

**Il traffico a valle resta chiuso a lungo dopo l'installazione.**
Corretto: serve `stableBase` (10 min) di sessione continua prima di aprire.
Controlla il log: `attendo stabilita' (...)` poi `... -> UP`.

**Errore creando la regola gate (`failure: no such item` / `place-before`).**
La tabella `/ip firewall filter` è vuota: usa il blocco condizionale di §3/§7
oppure togli `place-before=0`.

**Log `regola gate 'WAN-GATE' non trovata`.**
Non hai creato la regola filter o il commento non combacia. Crea la regola
(vedi §7) o metti `gateBlock=false`.

**Non arrivano le notifiche Telegram.**
Verifica `tgToken`/`tgChat`, la raggiungibilità Internet del router, e cerca
`invio Telegram fallito` nel log.

**Il conteggio dei secondi sembra sbagliato.**
`pollSec` e `interval` dello scheduler devono coincidere.

**Voglio solo monitoraggio, niente blocco del traffico.**
`gateBlock=false` (e `useGate=false` in install.rsc).

---

## 13. Disinstallazione

```
/system scheduler remove [find name="WANHealth-sched"]
/system script remove [find name="WANHealth"]
/ip firewall filter remove [find comment="WAN-GATE"]
```

(I global `wh*` si azzerano da soli al riavvio.)
