// node "C:\Entwicklung\interne Projekte\DevContainersTest\.devcontainer\proxy-relay.js"

const net = require('node:net');
const readline = require('node:readline');

const LISTEN_HOST = '127.0.0.1';
const LISTEN_PORT = 18080;
const TARGET_HOST = '0.0.0.0';
const TARGET_PORT = 8080;
const TEST_HOST = 'github.com';
const TEST_PORT = 443;
const TEST_TIMEOUT_MS = 10000;

const KEY_ENTER_LF = String.fromCharCode(0x0a);
const KEY_ENTER_CR = String.fromCharCode(0x0d);
const KEY_EOT = String.fromCharCode(0x04);
const KEY_CTRL_C = String.fromCharCode(0x03);
const KEY_BACKSPACE = String.fromCharCode(0x08);
const KEY_DEL = String.fromCharCode(0x7f);

function askVisible(question) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer);
    });
  });
}

function askHidden(question) {
  return new Promise((resolve, reject) => {
    const stdin = process.stdin;
    const stdout = process.stdout;
    if (!stdin.isTTY || typeof stdin.setRawMode !== 'function') {
      reject(new Error('Passwort-Eingabe benötigt ein interaktives Terminal (TTY).'));
      return;
    }
    stdout.write(question);
    stdin.setRawMode(true);
    stdin.resume();
    stdin.setEncoding('utf8');
    let pw = '';
    const onData = (ch) => {
      switch (ch) {
        case KEY_ENTER_LF:
        case KEY_ENTER_CR:
        case KEY_EOT:
          stdin.setRawMode(false);
          stdin.pause();
          stdin.removeListener('data', onData);
          stdout.write('\n');
          resolve(pw);
          break;
        case KEY_CTRL_C:
          stdout.write('\n');
          process.exit(130);
          break;
        case KEY_DEL:
        case KEY_BACKSPACE:
          if (pw.length > 0) pw = pw.slice(0, -1);
          break;
        default:
          pw += ch;
          break;
      }
    };
    stdin.on('data', onData);
  });
}

function makeAuthHeader(user, pass) {
  return 'Proxy-Authorization: Basic ' + Buffer.from(`${user}:${pass}`).toString('base64');
}

function injectAuth(headBuf, authHeader) {
  const text = headBuf.toString('latin1');
  const endIdx = text.indexOf('\r\n\r\n');
  if (endIdx < 0) return null;
  const headers = text.slice(0, endIdx).split('\r\n');
  const rest = text.slice(endIdx);
  const filtered = headers.filter((h) => !/^proxy-authorization:/i.test(h));
  filtered.splice(1, 0, authHeader);
  return Buffer.from(filtered.join('\r\n') + rest, 'latin1');
}

function startServer(authHeader) {
  const server = net.createServer((client) => {
    const upstream = net.createConnection({ host: TARGET_HOST, port: TARGET_PORT });
    let buf = Buffer.alloc(0);
    let injected = false;
    const done = (err) => { client.destroy(); upstream.destroy(); if (err) console.error('err:', err.message); };
    client.on('error', done);
    upstream.on('error', done);
    upstream.pipe(client);
    client.on('data', (chunk) => {
      if (injected) { upstream.write(chunk); return; }
      buf = Buffer.concat([buf, chunk]);
      const replaced = injectAuth(buf, authHeader);
      if (replaced) {
        upstream.write(replaced);
        injected = true;
        buf = Buffer.alloc(0);
      } else if (buf.length > 65536) {
        console.error('header too large, dropping');
        done();
      }
    });
    client.on('end', () => upstream.end());
    upstream.on('end', () => client.end());
  });
  return new Promise((resolve) => {
    server.listen(LISTEN_PORT, LISTEN_HOST, () => resolve(server));
  });
}

function runSelfTest() {
  return new Promise((resolve) => {
    const sock = net.createConnection({ host: '127.0.0.1', port: LISTEN_PORT });
    let response = '';
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      sock.destroy();
      resolve(result);
    };
    const timer = setTimeout(() => finish({ ok: false, detail: `TIMEOUT nach ${TEST_TIMEOUT_MS} ms` }), TEST_TIMEOUT_MS);
    sock.on('connect', () => {
      sock.write(`CONNECT ${TEST_HOST}:${TEST_PORT} HTTP/1.1\r\nHost: ${TEST_HOST}:${TEST_PORT}\r\n\r\n`);
    });
    sock.on('data', (chunk) => {
      response += chunk.toString('latin1');
      const endIdx = response.indexOf('\r\n\r\n');
      if (endIdx >= 0) {
        const statusLine = response.split('\r\n')[0];
        const ok = /^HTTP\/1\.[01] 200\b/.test(statusLine);
        finish({ ok, detail: statusLine });
      }
    });
    sock.on('error', (err) => finish({ ok: false, detail: err.message }));
    sock.on('end', () => {
      if (!settled) finish({ ok: false, detail: 'Verbindung vorzeitig beendet' });
    });
  });
}

async function readCredsFromPipe() {
  const rl = readline.createInterface({ input: process.stdin });
  const it = rl[Symbol.asyncIterator]();
  const u = (await it.next()).value;
  const p = (await it.next()).value;
  rl.close();
  // stdin-Handle aktiv freigeben, damit der Aufrufer (z.B. start-relay.ps1)
  // die per Redirect uebergebene Eingabedatei sofort loeschen kann.
  try { process.stdin.destroy(); } catch (_) {}
  return { user: u ?? '', pass: p ?? '' };
}

async function main() {
  let user, pass;
  if (process.stdin.isTTY) {
    user = (await askVisible('Benutzername (z.B. ph\\o.kihn): ')).trim();
    pass = await askHidden('Passwort: ');
  } else {
    const creds = await readCredsFromPipe();
    user = creds.user.trim();
    pass = creds.pass;
  }
  if (!user) {
    console.error('ERROR: Benutzername darf nicht leer sein.');
    process.exit(1);
  }
  if (!pass) {
    console.error('ERROR: Passwort darf nicht leer sein.');
    process.exit(1);
  }

  const authHeader = makeAuthHeader(user, pass);
  await startServer(authHeader);
  console.log(`relay listening on ${LISTEN_HOST}:${LISTEN_PORT} -> ${TARGET_HOST}:${TARGET_PORT} (Basic auth as ${user})`);

  console.log(`Selbsttest: CONNECT ${TEST_HOST}:${TEST_PORT} via 127.0.0.1:${LISTEN_PORT} ...`);
  const result = await runSelfTest();
  if (result.ok) {
    console.log(`Selbsttest: OK  [${result.detail}]`);
  } else {
    console.log(`Selbsttest: FEHLER  [${result.detail}]`);
    console.log('Hinweis: Prüfe Username/Passwort, Upstream-Proxy-Erreichbarkeit und Firewall.');
  }
}

main().catch((err) => {
  console.error('Fataler Fehler:', err.message);
  process.exit(1);
});
