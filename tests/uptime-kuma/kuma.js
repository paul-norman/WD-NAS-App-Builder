// Talks to Uptime Kuma as its web page does (socket.io, with the client in its own node_modules - NODE_PATH):
//   node kuma.js setup <user> <password>          - creates the admin account (first start)
//   node kuma.js login <user> <password>          - prints "ok", or the error
//   node kuma.js ping <user> <password> <host>    - adds a ping monitor and prints its first heartbeat: "<status> <time or message>"
const { io } = require("socket.io-client");
const [command, user, password, host] = process.argv.slice(2);
const socket = io("http://127.0.0.1:3001", { transports: ["websocket"], reconnection: false });
const done = (text) => { console.log(text); socket.close(); process.exit(0); };
setTimeout(() => done("timed out"), 60000);

socket.on("connect_error", (error) => done("no connection: " + error.message));
// Once it has said what it needs - "setup" or "loginRequired": its handlers aren't all there as soon as it connects
let started = false;
const start = () => {
	if (started) {
		return;
	}
	started = true;
	if (command === "setup") {
		socket.emit("setup", user, password, (r) => done(r.ok ? "ok" : r.msg));
		return;
	}
	socket.emit("login", { username: user, password, token: "" }, (r) => {
		if (!r.ok || command === "login") {
			done(r.ok ? "ok" : r.msg);
			return;
		}
		let id = null;
		socket.on("heartbeat", (beat) => {
			if (id !== null && beat.monitorID === id) {
				done(beat.status + " " + (beat.ping !== null ? beat.ping + " ms" : beat.msg));
			}
		});
		socket.emit("add", {
			type: "ping", name: "the NAS", hostname: host, interval: 20, retryInterval: 20, maxretries: 0, active: true,
			accepted_statuscodes: ["200-299"], notificationIDList: {}, kafkaProducerBrokers: [], kafkaProducerSaslOptions: {},
			conditions: [], rabbitmqNodes: [], ping_count: 1, ping_numeric: true, ping_per_request_timeout: 2,
		}, (r) => {
			if (!r.ok) {
				done("not added: " + r.msg);
			}
			id = r.monitorID;
		});
	});
};
socket.on("setup", start);
socket.on("loginRequired", start);
