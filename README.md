# MikroTik WAN Health Monitor

Monitor di salute della WAN per **MikroTik RouterOS 7.2.x** (testato) con
**isteresi (debounce)** e **backoff esponenziale**, per linee **PPPoE** che
soffrono di *flapping* (la connessione cade e risale di continuo).
Generico: funziona su **qualsiasi router/firewall MikroTik**.

> 🇬🇧 *WAN health monitor with hysteresis and exponential backoff for any
> MikroTik router/firewall on RouterOS 7.2.x. Generic, placeholder-based.*

📖 **Manuali / Manuals**: [Italiano](docs/MANUALE.md) · [English](docs/MANUAL.md)

L'obiettivo è **eliminare i falsi positivi**: la WAN è dichiarata `UP` solo
quando la **sessione PPP è stabile e raggiungibile per `reqStable` secondi
continui**, evitando che firewall, routing o monitoraggi reagiscano a ogni
rimbalzo. Se la linea continua a cadere, l'attesa **cresce esponenzialmente**.

## Placeholder

Sostituiscili prima dell'uso (in `wan-health.rsc` e `install.rsc`):

| Placeholder       | Significato                          | Esempio        |
|-------------------|--------------------------------------|----------------|
| `{nomewan}`       | Nome interfaccia PPPoE               | `pppoe-out1`   |
| `{rete_a_valle}`  | Rete a valle da gate-are (CIDR)      | `192.0.2.0/24` |
| `{token_telegram}`| Token bot Telegram                   | `123:ABC...`   |
| `{chat_id}`       | Chat ID Telegram                     | `12345678`     |
| `{ip_gateway}`    | IP gateway/uscita per i test         | `192.0.2.1`    |

## Caratteristiche

- **Debounce / isteresi**: `UP` solo quando la **sessione PPP è su da `reqStable` secondi continui** (più ping reale).
- **Backoff esponenziale**: l'attesa parte da `stableBase` e **raddoppia a ogni flap** (fino a `stableMax`); decade quando la linea si calma.
- **Cattura i flap tra un poll e l'altro**: usa l'**uptime della sessione PPPoE**; ogni riconnessione lo azzera.
- **Rilevamento flapping**: conta le cadute in una finestra e genera un allarme oltre la soglia.
- **Logging** di ogni transizione (`info` / `warning` / `error`).
- **Notifiche Telegram** opzionali.
- **Gate forward** deterministico: il traffico a valle esce solo a WAN stabile.

## Macchina a stati

```
DOWN ──linea su──> RISING ──sessione PPP su da ≥ reqStable──> UP
  ▲                  │                                         │
  └──── cade ────────┴──────── cade / riconnette ─────────────┘  (FLAP, riparte l'attesa)
```

- **RISING**: PPPoE risalita ma sessione ancora "giovane" → nessuna azione di "WAN buona". Qui si annulla il falso positivo.
- **UP**: solo quando l'**uptime della sessione PPP ≥ `reqStable`** e il ping passa.
- Una riconnessione conta come flap e **riporta in RISING**, riavviando l'attesa (che cresce col backoff).

## Installazione rapida

1. In `wan-health.rsc` sostituisci i placeholder (almeno `{nomewan}`).
2. Carica `wan-health.rsc` in **Files**.
3. In `install.rsc` imposta `{nomewan}`, `{rete_a_valle}`, `useGate`; caricalo in **Files**.
4. Esegui:
   ```
   /import file-name=install.rsc
   ```

Dettagli, gate, backoff, test e tuning nei manuali
([IT](docs/MANUALE.md) / [EN](docs/MANUAL.md)).

> `pollSec` nello script **deve** combaciare con `interval` dello scheduler (10s).

## Backoff esponenziale

`reqStable = min( stableBase × backoffFactor^(flap-1) , stableMax )`

Con i default (`600`, `2`, `7200`): 1 flap→10 min, 2→20 min, 3→40 min,
4→80 min, 5+→2h (tetto). Dopo una `flapWindow` senza flap la penalità decade.

## File del repository

```
wan-health.rsc            # script principale (placeholder)
install.rsc               # installer generico (gate + script + scheduler)
docs/MANUALE.md           # manuale IT
docs/MANUAL.md            # manuale EN
examples/hooks.rsc        # HOOK personalizzabili (gate, rotte, address-list, email)
examples/test-trace.rsc   # test percorso/uscita dal router (RouterOS)
examples/test-windows.ps1 # diagnostica da PC Windows
```

## Sicurezza

Non committare mai l'export completo del router (`/export`) in un repo pubblico:
contiene password PPPoE, community SNMP e ACL. Il [`.gitignore`](.gitignore)
esclude già `*.backup`, `*.rsc.bak`, `secrets.rsc`, `config.local.rsc`.

## Licenza

[MIT](LICENSE)
