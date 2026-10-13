// Global entry: owns the WebSocket server (one per IINA process, so several
// player windows don't fight over the port) and routes messages between
// Neovim clients and the active player window.
const { ws, global, console: log, preferences } = iina;
const P = require("./protocol.js");

const port = Number(preferences.get("port")) || P.DEFAULT_PORT;
const clients = new Map(); // conn id -> { ready, local, path }
const players = new Map(); // player label -> latest snapshot
let active = null;
let config = { type: "config", hide_subs: true };

function sendTo(conn, msg) {
  ws.sendText(conn, JSON.stringify(msg)).catch((e) => log.warn(`send failed: ${JSON.stringify(e)}`));
}

function readyClients() {
  return [...clients.entries()].filter(([, c]) => c.ready && c.local);
}

function broadcast(msg) {
  const text = JSON.stringify(msg);
  for (const [conn] of readyClients()) {
    ws.sendText(conn, text).catch(() => {});
  }
}

// Always deferred: posting to a player synchronously from inside its own
// postMessage (e.g. while its main entry is still loading) crashes IINA,
// because the player's plugin instance isn't registered yet and IINA
// force-unwraps the lookup.
function toPlayer(label, name, data) {
  setTimeout(() => {
    if (players.has(label)) {
      global.postMessage(label, name, data);
    }
  }, 0);
}

function notifyPlayers() {
  const n = readyClients().length;
  for (const label of players.keys()) {
    toPlayer(label, "cueline:clients", n);
  }
}

function snapshot(label) {
  return label && players.has(label) ? players.get(label) : null;
}

function fileMsg() {
  return Object.assign({ type: "file" }, snapshot(active) || { file: null });
}

function setActive(label) {
  if (active === label) {
    return;
  }
  if (active && players.has(active)) {
    toPlayer(active, "cueline:cmd", { type: "clear" });
  }
  active = label;
  log.log(`active player: ${label}`);
  broadcast(fileMsg());
}

function update(label, msg) {
  const snap = Object.assign(players.get(label) || {}, msg);
  delete snap.type;
  players.set(label, snap);
  return snap;
}

// Events from player windows (main entries).
const playerEvents = {
  "hello-child": (msg, label) => {
    update(label, msg);
    toPlayer(label, "cueline:clients", readyClients().length);
    toPlayer(label, "cueline:cmd", config);
    if (!active) {
      setActive(label);
    }
  },
  time: (msg, label) => {
    update(label, msg);
    if (label !== active) {
      if (msg.paused) {
        return;
      }
      setActive(label);
    }
    broadcast({ type: "time", pos: msg.pos, paused: msg.paused, speed: msg.speed });
  },
  state: (msg, label) => {
    update(label, msg);
    if (!msg.paused) {
      setActive(label);
    }
    if (label === active) {
      broadcast({ type: "state", pos: msg.pos, paused: msg.paused, speed: msg.speed });
    }
  },
  file: (msg, label) => {
    update(label, msg);
    if (active === label) {
      broadcast(fileMsg());
    } else {
      setActive(label);
    }
  },
  shown: (msg, label) => {
    if (label === active) {
      broadcast({ type: "shown", text: msg.text, rendered: msg.rendered, subs_hidden: msg.subs_hidden });
    }
  },
  track: (msg, label) => {
    if (label === active) {
      broadcast(Object.assign({}, msg, { type: "track" }));
    }
  },
  notice: (msg, label) => {
    if (label === active) {
      broadcast({ type: "notice", message: msg.message });
    }
  },
  closed: (msg, label) => {
    players.delete(label);
    if (active === label) {
      active = null;
      setActive(players.keys().next().value || null);
    }
  },
};

global.onMessage("cueline:evt", (msg, label) => P.dispatch(playerEvents, msg, label));

// Messages from Neovim clients.
const clientMessages = {
  hello: (msg, conn) => {
    log.log(`client ${conn}: ${msg.client || "?"} ${msg.version || ""}`);
    sendTo(conn, P.hello(snapshot(active)));
  },
  ping: (msg, conn) => sendTo(conn, { type: "pong", id: msg.id }),
  config: (msg) => {
    config = Object.assign({}, msg);
    for (const label of players.keys()) {
      toPlayer(label, "cueline:cmd", config);
    }
  },
};

function handleClient(conn, text) {
  const client = clients.get(conn);
  const msg = P.parse(text);
  if (!client || !client.local || !msg) {
    return;
  }
  if (P.dispatch(clientMessages, msg, conn)) {
    return;
  }
  if (!P.PLAYER_COMMANDS.has(msg.type)) {
    sendTo(conn, { type: "error", message: `unknown message type: ${msg.type}` });
  } else if (!active) {
    sendTo(conn, { type: "error", message: "no player window is open" });
  } else {
    toPlayer(active, "cueline:cmd", msg);
  }
}

const connectionStates = {
  ready: (_msg, conn) => {
    const c = clients.get(conn) || {};
    c.ready = true;
    clients.set(conn, c);
    notifyPlayers();
  },
  failed: (msg, conn) => connectionStates.cancelled(msg, conn),
  cancelled: (_msg, conn) => {
    clients.delete(conn);
    notifyPlayers();
  },
};

function startServer() {
  try {
    ws.createServer({ port });
  } catch (e) {
    log.error(`createServer failed: ${e}`);
    return;
  }
  ws.onStateUpdate((state, err) => {
    log.log(`server ${state} on port ${port}${err ? ` (${err.description || err.message})` : ""}`);
    if (state === "failed") {
      setTimeout(startServer, 3000);
    }
  });
  ws.onNewConnection((conn, info) => {
    const path = info && info.path;
    const local = P.isLoopback(path);
    log.log(`connection ${conn} from ${path || "?"}${local ? "" : " (rejected: not loopback)"}`);
    clients.set(conn, { ready: false, local, path });
  });
  ws.onConnectionStateUpdate((conn, state) => {
    setTimeout(() => P.dispatch(connectionStates, { type: state }, conn), 0);
  });
  ws.onMessage((conn, message) => {
    const text = message.text();
    // ws callbacks arrive on the server's own queue; hop to the main thread
    setTimeout(() => handleClient(conn, text), 0);
  });
  ws.startServer();
}

startServer();
