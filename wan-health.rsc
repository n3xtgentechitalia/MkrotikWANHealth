# =====================================================================
#  WAN Health Monitor con isteresi (debounce) - RouterOS 7.2.x (tested)
#  Generico: qualsiasi router/firewall MikroTik con WAN PPPoE.
#
#  Scopo:
#   - Dichiarare la WAN "UP" SOLO quando la SESSIONE PPP e' su da X
#     secondi continui (anti falso-positivo da flapping PPPoE).
#   - Intercettare anche i flap che avvengono TRA due poll, guardando
#     l'uptime della sessione (una riconnessione lo azzera).
#   - Loggare ogni transizione e rilevare il FLAPPING.
#   - Notificare via Telegram (opzionale) e/o solo log.
#   - Gate forward: traffico della rete a valle ammesso solo a WAN stabile.
#
#  PRIMA DELL'USO sostituisci i PLACEHOLDER tra { } qui sotto.
#  Installazione (vedi README/manuale): import + scheduler ogni 10s.
# =====================================================================

# ---------------------- CONFIGURAZIONE -------------------------------
:local wanIf        "{nomewan}";    # <-- nome ESATTO della tua interfaccia PPPoE
:local pingTarget   "1.1.1.1";      # host pubblico raggiungibile via WAN
:local pingCount    3;              # ping per ciclo

# --- Attesa di stabilita' con BACKOFF ESPONENZIALE ---
# La WAN diventa UP solo quando la SESSIONE PPP e' su da "reqStable" secondi.
# reqStable parte da stableBase e RADDOPPIA (backoffFactor) ad ogni flap nella
# finestra, fino al tetto stableMax. Piu' la linea flappa, piu' a lungo deve
# restare su prima di riaprire il traffico a valle.
:local stableBase   600;            # attesa BASE (s): 1o tentativo / linea tranquilla
:local backoffFactor 2;             # moltiplicatore per ogni flap nella finestra
:local stableMax    7200;           # tetto massimo attesa (s) (qui 2h)

:local pollSec      10;             # DEVE combaciare con l'intervallo dello scheduler
:local flapWindow   1800;           # finestra (s): conta i flap e fa decadere la penalita'
:local flapThreshold 3;             # n. cadute nella finestra = allarme "flapping"

# Gate forward: fa uscire il traffico dei FW a valle SOLO a WAN stabile (UP).
# Richiede una regola /ip firewall filter con commento = $gateComment
# (vedi examples/deploy-rb5009.rsc). Lascia false se non vuoi il gate.
:local gateBlock    true;           # true = abilita il cancello sul forward
:local gateComment  "WAN-GATE";     # commento della regola filter da pilotare

# Notifiche
:local doNotify     true;           # false = solo log
:local tgToken      "{token_telegram}";
:local tgChat       "{chat_id}";
:local rid          [/system identity get name];
# ---------------------------------------------------------------------

# ---------------------- STATO PERSISTENTE ----------------------------
:global whState;        # INIT / DOWN / RISING / UP
:global whFlapCount;    # cadute nella finestra corrente
:global whFlapStart;    # uptime di sistema all'inizio della finestra flap
:global whLastUptime;   # uptime sessione PPP visto al poll precedente

:if ([:typeof $whState] = "nothing") do={
    :set whState "INIT";
    :set whFlapCount 0;
    :set whFlapStart [/system resource get uptime];
    :set whLastUptime 0s;
}

# messaggio di notifica accumulato in questo ciclo
:local notifyMsg "";

# ---------------------- RILEVA STATO LINK ----------------------------
# Stato PPPoE + UPTIME della sessione corrente (fonte di verita' della
# stabilita'). Poi verifica di reale raggiungibilita' con ping.
:local ppStatus "";
:local ppUptime 0s;
:do {
    /interface pppoe-client monitor $wanIf once do={
        :set ppStatus $status;
        :set ppUptime $uptime;
    }
} on-error={ :set ppStatus "error"; }

:local linkUp false;
:if ($ppStatus = "connected") do={
    :local pr 0;
    :do { :set pr [/ping $pingTarget interface=$wanIf count=$pingCount]; } on-error={ :set pr 0; }
    :if ($pr > 0) do={ :set linkUp true; }
}

# Rileva un riavvio di sessione (flap) avvenuto anche TRA due poll:
# se l'uptime e' tornato indietro, la PPPoE si e' riconnessa.
:local sessionRestarted false;
:if ($linkUp = true) do={
    :if ($ppUptime < $whLastUptime) do={ :set sessionRestarted true; }
    :set whLastUptime $ppUptime;
} else={
    :set whLastUptime 0s;
}

# ---------------------- CLASSIFICA EVENTO DI CADUTA ------------------
# "down"      = link non utilizzabile ora (era su/in salita)
# "reconnect" = link su ma sessione ripartita da poco (flap tra poll)
:local event "";
:if ($linkUp = true) do={
    :if ($sessionRestarted = true) do={ :set event "reconnect"; }
} else={
    :if (($whState = "UP") || ($whState = "RISING")) do={ :set event "down"; }
}

# Contabilizza il flap (finestra scorrevole) per qualunque caduta
:if ($event != "") do={
    :local now [/system resource get uptime];
    :if (($now - $whFlapStart) > [:totime $flapWindow]) do={
        :set whFlapStart $now;
        :set whFlapCount 1;
    } else={
        :set whFlapCount ($whFlapCount + 1);
    }
}

# Decadimento penalita': se siamo gia' UP e da una intera finestra non
# avvengono flap, azzera il contatore (la linea ha dimostrato stabilita').
:if (($whState = "UP") && (([/system resource get uptime] - $whFlapStart) > [:totime $flapWindow])) do={
    :set whFlapCount 0;
}

# ---------------------- ATTESA RICHIESTA (BACKOFF) -------------------
# reqStable = stableBase * backoffFactor^(flap-1), con tetto stableMax.
:local reqStable $stableBase;
:if ($whFlapCount > 1) do={
    :local expn ($whFlapCount - 1);
    :if ($expn > 16) do={ :set expn 16; }
    :local mult 1;
    :for i from=1 to=$expn do={ :set mult ($mult * $backoffFactor); }
    :set reqStable ($stableBase * $mult);
    :if ($reqStable > $stableMax) do={ :set reqStable $stableMax; }
}

# ---------------------- MACCHINA A STATI -----------------------------
:if ($linkUp = true) do={
    # ----- la linea risponde -----
    :if ($event = "reconnect") do={
        # riconnessa tra due poll: AZZERA l'attesa, torna in RISING
        :set whState "RISING";
        :log warning ("WANHealth: " . $wanIf . " riconnessa (flap #" . $whFlapCount . ") - attesa stabilita' ora " . $reqStable . "s (backoff)");
    }

    :if ($ppUptime >= [:totime $reqStable]) do={
        # sessione su da abbastanza tempo: STABILE
        :if ($whState != "UP") do={
            :set whState "UP";
            :log info ("WANHealth: " . $wanIf . " STABILE (sessione su da " . $ppUptime . ", richiesti " . $reqStable . "s) -> UP");
            :set notifyMsg ("[" . $rid . "] WAN " . $wanIf . " STABILE (UP, sessione su da " . $ppUptime . ")");

            # ======= HOOK: azioni quando la WAN e' DAVVERO stabile =======
            #   /ip route enable [find comment="WAN-UP"];
            #   /system script run azioni-wan-up;
            # (il gate forward e' gestito piu' sotto in automatico)
            # =============================================================
        }
    } else={
        # sessione ancora giovane: in attesa di stabilita'
        :if ($whState != "RISING") do={
            :set whState "RISING";
            :log warning ("WANHealth: " . $wanIf . " su da " . $ppUptime . ", attendo stabilita' (" . $reqStable . "s, flap=" . $whFlapCount . ")");
        }
    }
} else={
    # ----- la linea NON risponde -----
    :if ($event = "down") do={
        :log warning ("WANHealth: " . $wanIf . " DOWN (flap #" . $whFlapCount . " nella finestra " . $flapWindow . "s)");
        :set notifyMsg ("[" . $rid . "] WAN " . $wanIf . " DOWN (flap " . $whFlapCount . "/" . $flapThreshold . ")");
    }
    :set whState "DOWN";
}

# ---------------------- ALLARME FLAPPING -----------------------------
:if (($event != "") && ($whFlapCount >= $flapThreshold)) do={
    :log error ("WANHealth: FLAPPING su " . $wanIf . " - " . $whFlapCount . " cadute in " . $flapWindow . "s");
    :set notifyMsg ("[" . $rid . "] ALLARME FLAPPING WAN " . $wanIf . ": " . $whFlapCount . " cadute in " . ($flapWindow / 60) . " min");
}

# ---------------------- GATE FORWARD (deterministico) ----------------
# Applica lo stato del cancello a OGNI ciclo in base a $whState:
#   WAN UP  -> regola WAN-GATE disabilitata (traffico AMMESSO)
#   altro   -> regola WAN-GATE abilitata    (traffico BLOCCATO)
# Idempotente e a prova di reboot (nessuna dipendenza dalle sole transizioni).
:if ($gateBlock = true) do={
    :do {
        :local gid [/ip firewall filter find comment=$gateComment];
        :if ([:len $gid] > 0) do={
            :if ($whState = "UP") do={
                /ip firewall filter set $gid disabled=yes;
            } else={
                /ip firewall filter set $gid disabled=no;
            }
        } else={
            :log warning ("WANHealth: regola gate '" . $gateComment . "' non trovata");
        }
    } on-error={ :log warning "WANHealth: errore gestione gate forward"; }
}

# ---------------------- INVIO NOTIFICA --------------------------------
:if (($doNotify = true) && ([:len $notifyMsg] > 0)) do={
    :do {
        /tool fetch url=("https://api.telegram.org/bot" . $tgToken . "/sendMessage") http-method=post http-header-field="Content-Type: application/x-www-form-urlencoded" http-data=("chat_id=" . $tgChat . "&text=" . $notifyMsg) output=none as-value;
    } on-error={ :log warning "WANHealth: invio Telegram fallito"; }
}
