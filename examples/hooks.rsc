# =====================================================================
#  Esempi di HOOK per wan-health.rsc
#  Copia/adatta questi blocchi nelle sezioni "HOOK" dello script
#  principale (on-stable / on-down).
# =====================================================================

# ---------------------------------------------------------------------
# Esempio 0 (CONSIGLIATO per WAN singola): GATE FORWARD
#
# Fa uscire il traffico della rete a valle ({rete_a_valle}) SOLO quando la
# WAN ({nomewan}) e' confermata stabile (UP). Durante DOWN/RISING il traffico
# e' bloccato: gli apparati a valle vedono uno stato pulito (giu' = giu') e
# NON rimbalzano su connettivita' instabile.
#
# Questo HOOK e' GIA' integrato in wan-health.rsc: basta impostare
#   gateBlock = true
# e creare la regola con commento "WAN-GATE" (qui sotto, una volta sola):
#
#   :if ([:len [/ip firewall filter find]] > 0) do={
#       /ip firewall filter add chain=forward src-address={rete_a_valle} out-interface={nomewan} action=drop comment="WAN-GATE" place-before=0
#   } else={
#       /ip firewall filter add chain=forward src-address={rete_a_valle} out-interface={nomewan} action=drop comment="WAN-GATE"
#   }
#
# NB: la regola va messa PRIMA delle eventuali regole di accept nel
#     chain=forward (place-before=0). ATTENZIONE: place-before=0 funziona
#     solo se esistono gia' regole filter; su firewall VUOTO da' errore,
#     quindi il blocco condizionale qui sopra. La gestione disabled=yes/no
#     la fa lo script. Il traffico originato dal router (output) NON e'
#     toccato, quindi ping di WANHealth e notifiche Telegram funzionano.
# ---------------------------------------------------------------------


# ---------------------------------------------------------------------
# Esempio 1: abilitare/disabilitare una rotta verso la rete a valle.
#
# Pre-requisito: marca la rotta con un commento, es:
#   /ip route set [find dst-address=203.0.113.0/29] comment="WAN-UP"
# ---------------------------------------------------------------------

# >>> nella sezione on-stable (WAN dichiarata UP):
#   /ip route enable [find comment="WAN-UP"];

# >>> nella sezione on-down (WAN caduta):
#   /ip route disable [find comment="WAN-UP"];


# ---------------------------------------------------------------------
# Esempio 2: address-list per segnalare lo stato a regole firewall.
# Utile se hai regole che cambiano comportamento quando la WAN è giù.
# ---------------------------------------------------------------------

# >>> on-stable:
#   /ip firewall address-list remove [find list=WAN_DOWN];

# >>> on-down:
#   :if ([:len [/ip firewall address-list find list=WAN_DOWN]] = 0) do={
#       /ip firewall address-list add list=WAN_DOWN address=0.0.0.0/0 comment="WAN giu";
#   }


# ---------------------------------------------------------------------
# Esempio 3: richiamare script esterni dedicati.
# ---------------------------------------------------------------------

# >>> on-stable:
#   /system script run azioni-wan-up;

# >>> on-down:
#   /system script run azioni-wan-down;


# ---------------------------------------------------------------------
# Esempio 4: notifica e-mail (alternativa/aggiunta a Telegram).
# Richiede /tool e-mail configurato (server SMTP).
# ---------------------------------------------------------------------

# >>> on-down:
#   /tool e-mail send to="noc@example.com" subject="WAN DOWN" \
#       body=("WAN giu sul router " . [/system identity get name]);
