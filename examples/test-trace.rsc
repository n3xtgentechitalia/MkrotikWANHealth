# =====================================================================
#  test-trace.rsc - Verifica percorso/uscita dalla WAN - RouterOS 7.2.x
#  Generico per qualsiasi MikroTik.
#
#  USO: incolla i comandi in terminale (SSH/WinBox), uno alla volta.
#  Forzano la SORGENTE all'IP del tuo gateway/uscita e l'USCITA dalla
#  WAN PPPoE, cosi' verifichi che il traffico esce dalla rotta giusta.
#
#  Sostituisci i placeholder:
#    {nomewan}    = nome interfaccia PPPoE (es. pppoe-out1)
#    {ip_gateway} = IP sorgente da usare (es. il tuo IP pubblico/gateway)
# =====================================================================

:global gwSrc  "{ip_gateway}";   # IP sorgente per i test
:global wanIf  "{nomewan}";      # interfaccia WAN

# ---------------------------------------------------------------------
# 0) Leggi il gateway P2P dell'ISP (remote-address della sessione)
# ---------------------------------------------------------------------
/interface pppoe-client monitor $wanIf once
# annota "remote-address" (= primo hop ISP) e "local-address" (tuo IP P2P)

# ---------------------------------------------------------------------
# 1) PING sorgente = tuo gateway, uscita = WAN
# ---------------------------------------------------------------------
/ping 1.1.1.1 src-address=$gwSrc interface=$wanIf count=5
/ping 8.8.8.8 src-address=$gwSrc interface=$wanIf count=5

# ---------------------------------------------------------------------
# 2) TRACEROUTE sorgente = tuo gateway, uscita = WAN
#    Il 1o hop deve essere il remote-address PPPoE (gateway ISP).
# ---------------------------------------------------------------------
/tool traceroute 1.1.1.1 src-address=$gwSrc interface=$wanIf count=1
/tool traceroute 8.8.8.8 src-address=$gwSrc interface=$wanIf count=1
/tool traceroute google.com src-address=$gwSrc interface=$wanIf count=1

# ---------------------------------------------------------------------
# 3) Conferma QUALE uscita sceglie la tabella di routing
#    Atteso: nexthop = gateway PPPoE, interface = {nomewan}
# ---------------------------------------------------------------------
/ip route check 1.1.1.1 once

# ---------------------------------------------------------------------
# 4) (opzionale) traceroute SENZA forzare src/interface:
#    deve comunque uscire dalla WAN se la default route e' quella.
# ---------------------------------------------------------------------
/tool traceroute 1.1.1.1 count=1

# ---------------------------------------------------------------------
# 5) (opzionale) test continuo del gateway ISP per vedere i flap
#    (sostituisci <REMOTE> col remote-address letto al punto 0)
# ---------------------------------------------------------------------
# /ping <REMOTE> src-address={ip_gateway} interface={nomewan} interval=1
# =====================================================================
