# proxyrelay

Lokales TCP-Relay (Node.js), das ankommende HTTP/HTTPS-Proxy-Requests an einen
Upstream-Proxy weiterleitet und dabei automatisch einen
`Proxy-Authorization: Basic …` Header injiziert. Damit lassen sich Tools, die
selbst keine Proxy-Authentifizierung beherrschen oder die Zugangsdaten nicht
lokal speichern sollen (z. B. Dev Containers, CLI-Tools), an einen
authentifizierten Unternehmens-Proxy anbinden.

Die AD-Zugangsdaten werden auf Windows per DPAPI (Scope `CurrentUser`)
verschlüsselt im Profil abgelegt und nur zur Laufzeit über eine
In-Memory-Pipe an den Node-Prozess übergeben — sie liegen zu keinem
Zeitpunkt im Klartext auf der Festplatte.

## Komponenten

- `proxy-relay.js` — Node.js-TCP-Relay. Lauscht auf `LISTEN_HOST:LISTEN_PORT`,
  verbindet zum Upstream `TARGET_HOST:TARGET_PORT`, ergänzt den
  Basic-Auth-Header in der ersten Request-Zeile und führt einen
  Selbsttest (`CONNECT github.com:443`) durch.
- `setup-relay-credentials.ps1` — einmalige Einrichtung. Fragt
  Benutzername und Passwort ab und speichert sie DPAPI-verschlüsselt
  unter `%APPDATA%\proxy-relay\` (`user.txt`, `pass.dpapi`). Härtet die
  ACL des Verzeichnisses auf den aktuellen Benutzer.
- `start-relay.ps1` — entschlüsselt die Zugangsdaten und startet
  `proxy-relay.js` versteckt im Hintergrund. Übergibt `user` und `pass`
  als zwei Zeilen über eine anonyme Windows-Pipe an den Node-Prozess.
- `install-autostart.ps1` — registriert einen Logon-Task im Windows
  Task Scheduler, der `start-relay.ps1` beim Anmelden automatisch ausführt.

## Voraussetzungen

- Windows mit Windows PowerShell 5.1+ (oder PowerShell 7+)
- Node.js (im `PATH` als `node`)
- Netzwerkzugriff auf den konfigurierten Upstream-Proxy

## Einrichtung

Einmalig im Projektverzeichnis ausführen:

```powershell
.\setup-relay-credentials.ps1
```

Es wird nach Benutzernamen (z. B. `domain\username`) und Passwort gefragt.
Das Passwort wird per DPAPI verschlüsselt — entschlüsselbar **nur** durch
denselben Windows-Benutzer auf demselben Rechner.

## Start

```powershell
.\start-relay.ps1
```

Das Relay läuft danach versteckt im Hintergrund. Der Start-Skript schreibt:

- die PID des Wrapper-Prozesses in `%APPDATA%\proxy-relay\relay.pid`
- stdout in `%APPDATA%\proxy-relay\relay.log`
- stderr in `%APPDATA%\proxy-relay\relay.err.log`

Beim Start wird ein `CONNECT github.com:443`-Selbsttest ausgeführt, dessen
Ergebnis in `relay.log` landet und so Authentifizierung und Erreichbarkeit
des Upstream-Proxys verifiziert.

Verwendung als HTTP-Proxy z. B.:

```powershell
$env:HTTP_PROXY  = 'http://127.0.0.1:18080'
$env:HTTPS_PROXY = 'http://127.0.0.1:18080'
```

### Stoppen

```powershell
taskkill /T /F /PID (Get-Content "$env:APPDATA\proxy-relay\relay.pid")
```

`/T` beendet auch den Node-Kindprozess, `/F` erzwingt das Beenden.

### Auto-Start nach Anmeldung

Einmalig:

```powershell
.\install-autostart.ps1
```

Registriert die Aufgabe `ProxyRelay-Autostart` im Task Scheduler des
aktuellen Benutzers. Trigger: At Logon. Lauft hidden, ohne UAC-Prompt
(`RunLevel = Limited`), kein Zeitlimit, doppelte Instanzen werden
verworfen. Sofort testen ohne neu anzumelden:

```powershell
Start-ScheduledTask -TaskName 'ProxyRelay-Autostart'
```

Wieder entfernen:

```powershell
.\install-autostart.ps1 -Uninstall
```

## Konfiguration

Host und Ports sind aktuell als Konstanten am Kopf von `proxy-relay.js`
hinterlegt und müssen dort angepasst werden:

| Konstante | Standardwert | Bedeutung |
|---|---|---|
| `LISTEN_HOST` | `0.0.0.0` | Bind-Adresse des Relays |
| `LISTEN_PORT` | `18080` | Lokaler Port |
| `TARGET_HOST` | `0.0.0.0` | Upstream-Proxy-Host (vor Inbetriebnahme setzen) |
| `TARGET_PORT` | `8080` | Upstream-Proxy-Port |
| `TEST_HOST` / `TEST_PORT` | `github.com:443` | Ziel des Selbsttests |

## Manueller Start ohne PowerShell-Wrapper

`proxy-relay.js` akzeptiert Zugangsdaten auch interaktiv (TTY) oder per
`stdin` (zwei Zeilen: Benutzer, Passwort):

```powershell
node .\proxy-relay.js
```

## Sicherheitskonzept

Das Tool ist als persönliches Werkzeug für eine Einzelmaschine konzipiert.
Schutzziel: AD-Zugangsdaten dürfen weder im Klartext auf der Platte
liegen noch ohne das aktive Zutun des Benutzers von anderen Konten oder
anderen Geräten verwendet werden können.

### Credential-Speicherung (Ruhezustand)

- **DPAPI, Scope `CurrentUser`.** `setup-relay-credentials.ps1` ruft
  `ConvertFrom-SecureString` auf und schreibt den resultierenden
  Base64-DPAPI-Blob nach `%APPDATA%\proxy-relay\pass.dpapi`. Der Blob
  ist mit einem Schlüssel verschlüsselt, der aus den Login-Credentials
  des Benutzers abgeleitet und an die Maschine gebunden ist.
  Konsequenz: ein Kopieren der Datei auf einen anderen Rechner oder zu
  einem anderen Benutzer ist nutzlos — `ConvertTo-SecureString` schlägt
  dort fehl.
- **Verzeichnis-ACL gehärtet.** Das Setup setzt
  `SetAccessRuleProtection($true, $false)` (Vererbung aus, vorhandene
  Regeln entfernt) und vergibt anschließend ausschließlich
  `FullControl` an den aktuellen Benutzer. Andere lokale Konten — auch
  Administratoren — sehen das Verzeichnis nicht ohne explizite
  Take-Ownership-Aktion.
- **Benutzername** liegt unverschlüsselt in `user.txt`. Der Account ist
  ohnehin in der Domäne bekannt und für sich genommen kein Geheimnis;
  geschützt wird das Passwort.

### Credential-Übergabe (Laufzeit)

`start-relay.ps1` vermeidet bewusst den naheliegenden Weg, Credentials
über eine Temp-Datei zu pipen, weil Windows `Start-Process
-RedirectStandardInput` die Datei ohne `FILE_SHARE_DELETE` öffnet und
der Klartext dann u. U. lange auf der Platte liegen bleibt.

Stattdessen:

1. `pass.dpapi` wird per `ConvertTo-SecureString` in einen
   `SecureString` entschlüsselt (Speicher verschlüsselt im Prozess).
2. Der `SecureString` wird per `SecureStringToBSTR` in einen kurzlebigen
   nativen Speicherbereich überführt.
3. Daraus wird ein UTF-8-Byte-Buffer erzeugt und direkt in die anonyme
   `stdin`-Pipe des cmd-Wrappers geschrieben (`BaseStream.Write`).
4. Die Pipe wird sofort geschlossen.
5. `proxy-relay.js` liest die zwei Zeilen via `readline` und ruft
   `process.stdin.destroy()` auf, um den Pipe-Handle freizugeben.
6. Im `finally`-Block: `ZeroFreeBSTR` löscht den BSTR-Speicher,
   `Remove-Variable plain` und `$secure.Dispose()` räumen nach.

Resultat: das Klartext-Passwort existiert nur als kurzzeitige
Byte-Buffer in zwei Prozessspeichern und wird **nie** in eine Datei,
Argumentliste, Umgebungsvariable oder Registry geschrieben. Es
erscheint auch nicht in `relay.log` / `relay.err.log` — geloggt werden
nur Statusmeldungen des Relays und der Selbsttest.

### Verwendung im Node-Prozess

Das Passwort wird unmittelbar nach dem Lesen in den Basic-Auth-Header
einkodiert (`Buffer.from(\`${user}:${pass}\`).toString('base64')`) und
nur dieser Header (in einer Buffer-Variable) wird im Speicher gehalten.
Der Klartext wird nicht zwischengespeichert.

### Netzwerk-Angriffsfläche

- **`LISTEN_HOST = 0.0.0.0`** macht das Relay im LAN erreichbar.
  Jeder im gleichen Netz, der den Port erreicht, kann den Upstream-Proxy
  unter den eingebrannten Credentials nutzen. Für rein persönlichen
  Gebrauch unbedingt auf `127.0.0.1` umstellen oder per Firewall-Regel
  einschränken.
- **Kein TLS, keine Client-Auth.** Das Relay vertraut jedem
  Verbindungspartner und injiziert die Auth-Header. Es ist als
  loopback-/sicheres-LAN-Tool gedacht, nicht als öffentlich
  erreichbarer Dienst.
- **Header-Injection** ist auf den initialen Request beschränkt und auf
  64 KiB Header-Größe begrenzt; größere Header werden verworfen, um
  unbegrenztes Pufferwachstum zu verhindern.

### Persistenz / Auto-Start

`install-autostart.ps1` registriert den Logon-Task ausschließlich im
Kontext des aktuellen Benutzers (`Principal -UserId $env:USERNAME`,
`-LogonType Interactive`, `-RunLevel Limited`). Konsequenzen:

- Keine Admin-Rechte zur Registrierung erforderlich.
- Der Task läuft nur bei der Anmeldung dieses einen Benutzers — auch
  technisch nötig, weil nur dieser Benutzer den DPAPI-Blob entschlüsseln
  kann.
- Andere Konten auf derselben Maschine starten kein Relay und können
  die Credentials nicht nutzen.

### Bedrohungen, die *nicht* abgedeckt sind

- **Kompromittiertes Benutzerkonto.** Wer als der hinterlegte Benutzer
  Code ausführen kann, kann den DPAPI-Blob entschlüsseln. DPAPI schützt
  vor Offline-Diebstahl, nicht vor laufendem Schadcode im selben
  Account.
- **Memory-Dump.** Während der Node-Prozess läuft, steckt das
  Klartext-Passwort als Teil des Basic-Auth-Headers im Heap. Vollzugriff
  auf den Prozessspeicher (Debugger, lsass-style Dumps mit
  Admin-Rechten) liest das aus.
- **Kein Schutz gegen einen bösartigen Upstream-Proxy** — der bekommt
  per Definition den Auth-Header.
