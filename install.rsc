# =====================================================================
#  install.rsc - Installer generico WANHealth - RouterOS 7.2.x (tested)
#  Funziona su qualsiasi router/firewall MikroTik.
#
#  COSA FA:
#   1) crea (opzionale) la regola "gate" forward per la rete a valle
#   2) registra lo script WANHealth dal file caricato wan-health.rsc
#   3) crea lo scheduler che lo esegue ogni 10s
#
#  PREREQUISITI:
#   - carica PRIMA il file wan-health.rsc in /file (Files) e sostituisci
#     al suo interno i placeholder { } (almeno {nomewan}).
#   - sostituisci i placeholder { } anche qui sotto.
#
#  USO:  /import file-name=install.rsc
# =====================================================================

# ---------------------- PARAMETRI (EDITA QUI) ------------------------
:local wanIf      "{nomewan}";        # interfaccia PPPoE (uguale a wan-health.rsc)
:local lanBlock   "{rete_a_valle}";   # rete a valle da gate-are, es. 192.0.2.0/24
:local useGate    true;               # false = non creare il gate (solo monitor)
# ---------------------------------------------------------------------

# 1) GATE forward: blocca l'uscita della rete a valle finche' la WAN non e'
#    stabile. place-before=0 solo se esistono gia' regole filter (altrimenti
#    su firewall vuoto darebbe "failure: no such item").
:if ($useGate = true) do={
    /ip firewall filter remove [find comment="WAN-GATE"]
    :if ([:len [/ip firewall filter find]] > 0) do={
        /ip firewall filter add chain=forward src-address=$lanBlock out-interface=$wanIf action=drop comment="WAN-GATE" place-before=0
    } else={
        /ip firewall filter add chain=forward src-address=$lanBlock out-interface=$wanIf action=drop comment="WAN-GATE"
    }
}

# 2) Registra lo script dal file caricato
/system script remove [find name="WANHealth"]
/system script add name=WANHealth dont-require-permissions=yes \
    policy=read,write,test,policy \
    source=[/file get [find name="wan-health.rsc"] contents]

# 3) Scheduler ogni 10s (deve combaciare con pollSec nello script)
/system scheduler remove [find name="WANHealth-sched"]
/system scheduler add name=WANHealth-sched interval=10s start-time=startup \
    on-event="/system script run WANHealth"

:log info "WANHealth: installazione completata";
# =====================================================================
