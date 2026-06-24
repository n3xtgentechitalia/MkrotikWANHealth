# Changelog

Tutte le modifiche rilevanti a questo progetto sono documentate in questo file.

Il formato è basato su [Keep a Changelog](https://keepachangelog.com/it/1.1.0/)
e il progetto aderisce al [Semantic Versioning](https://semver.org/lang/it/).

## [2.0.0] - 2026-06-24

### Modificato (BREAKING)
- Progetto reso **generico** per qualsiasi router/firewall MikroTik
  (RouterOS 7.2.x testato): rimosso ogni riferimento a hardware/IP/interfacce
  specifici, introdotti **placeholder** `{nomewan}`, `{rete_a_valle}`,
  `{token_telegram}`, `{chat_id}`, `{ip_gateway}`.
- Nuovo installer generico `install.rsc` (gate + script + scheduler) che legge
  lo script dal file caricato; rimossi `install-rb5009.rsc`,
  `examples/deploy-rb5009.rsc` e il generatore `tools/gen-install.ps1`.

### Aggiunto
- **Manuale bilingue**: `docs/MANUALE.md` (IT) e `docs/MANUAL.md` (EN).
- `examples/test-trace.rsc` e `examples/test-windows.ps1` resi generici.

## [1.2.0]

- Backoff esponenziale dell'attesa: `reqStable = min(stableBase × backoffFactor^(flap-1), stableMax)`.
- Decadimento della penalità dopo una finestra senza flap.

## [1.1.0]

- Stabilità basata sull'uptime reale della sessione PPP: intercetta i flap
  avvenuti tra due poll e fa ripartire l'attesa.

## [1.0.0]

- Monitor WAN con macchina a stati e isteresi (DOWN / RISING / UP).
- Rilevamento flapping con finestra temporale e soglia.
- Logging delle transizioni e notifiche Telegram opzionali.
- Gate forward deterministico per la rete a valle.
