#!/usr/bin/env node
/*
 * Drives mvsMF's authentication service through the Zowe SDK and prints one
 * key=value line per step for tests/zowe-auth.sh to assert on.
 *
 * Why the SDK and not the CLI: Zowe CLI v8 has no `auth login zosmf` command
 * at all -- `zowe auth login` offers only `apiml`, and the SDK exposes only
 * apimlLogin/apimlLogout. So every flag the old suite passed came back
 * "Unknown argument", including the `zosmf` subcommand itself, and the suite
 * failed three of six assertions with nothing wrong on the server (#206).
 * ZosmfRestClient + Session are what the CLI itself runs on, so this still
 * exercises a real Zowe client stack against /zosmf/services/authenticate.
 *
 * Sessions are built explicitly rather than mutated after construction:
 * Session computes base64EncodedAuth in its constructor, so deleting
 * user/password from an existing session leaves Basic auth in place and every
 * request keeps authenticating with credentials. A probe written that way
 * reports login-with-a-wrong-password as 200 and a logged-out token as still
 * valid -- it is measuring Basic auth in every case and asserting nothing.
 *
 * Connection details come from the environment (the caller exports them from
 * .env), not from a Zowe profile, to match the explicit-connection model the
 * other suites use since #204.
 */

"use strict";

const { execSync } = require("child_process");
const path = require("path");

const RESOURCE = "/zosmf/services/authenticate";

function cliDir() {
	if (process.env.ZOWE_CLI_DIR) {
		return process.env.ZOWE_CLI_DIR;
	}
	const root = execSync("npm root -g", { encoding: "utf8" }).trim();
	return path.join(root, "@zowe", "cli");
}

function main() {
	const dir = cliDir();
	const load = (m) => require(require.resolve(m, { paths: [dir] }));
	const { Session } = load("@zowe/imperative");
	const { ZosmfRestClient } = load("@zowe/core-for-zowe-sdk");

	const base = {
		hostname: process.env.MVSMF_HOST,
		port: Number(process.env.MVSMF_PORT),
		protocol: process.env.MVSMF_PROTOCOL || "http",
		rejectUnauthorized: false,
	};

	const basic = (user, password) =>
		new Session({ ...base, type: "basic", user, password });
	const token = (tokenValue) =>
		new Session({ ...base, type: "token", tokenType: "LtpaToken2", tokenValue });

	/* The client throws on a 4xx, and the status is then only on the error --
	   client.response is not populated for a rejected request. */
	const statusOf = (client, err) =>
		(client.response && client.response.statusCode) ||
		(err && err.mDetails && err.mDetails.errorCode) ||
		0;

	const call = async (session, resource, request) => {
		const client = new ZosmfRestClient(session);
		try {
			await client.request({ resource, request });
			return { status: statusOf(client), headers: client.response.headers };
		} catch (err) {
			/* A 4xx is a result and carries a status. Anything with no status at
			   all -- refused connection, DNS, TLS -- is the driver failing to
			   reach the server, which the caller reports once instead of as one
			   confusing assertion failure per step. */
			const status = statusOf(client, err);
			if (!status) {
				throw new Error("cannot reach " + base.hostname + ":" + base.port +
					" -- " + (err && err.message ? err.message.split("\n")[0] : String(err)));
			}
			return { status, headers: {} };
		}
	};

	const listing =
		"/zosmf/restfiles/ds?dslevel=" + encodeURIComponent(process.env.MVSMF_USER) + ".*";

	return (async () => {
		const out = [];

		const login = await call(basic(process.env.MVSMF_USER, process.env.MVSMF_PASS),
			RESOURCE, "POST");
		out.push(["login_status", login.status]);

		const cookies = login.headers["set-cookie"] || [];
		const ltpa = cookies
			.map((c) => c.split(";")[0])
			.find((c) => c.startsWith("LtpaToken2="));
		const value = ltpa ? ltpa.slice("LtpaToken2=".length) : "";
		out.push(["login_token_type", ltpa ? "LtpaToken2" : ""]);
		out.push(["login_token_len", value.length]);
		out.push(["login_cookie_path", /Path=\//.test(cookies[0] || "") ? "/" : ""]);

		const bad = await call(basic(process.env.MVSMF_USER, "WRONGPW"), RESOURCE, "POST");
		out.push(["bad_login_status", bad.status]);

		const replay = await call(token(value), listing, "GET");
		out.push(["replay_status", replay.status]);

		const logout = await call(token(value), RESOURCE, "DELETE");
		out.push(["logout_status", logout.status]);

		const after = await call(token(value), listing, "GET");
		out.push(["replay_after_logout_status", after.status]);

		const bogus = await call(token("not-a-real-token"), RESOURCE, "DELETE");
		out.push(["logout_bogus_status", bogus.status]);

		out.forEach(([k, v]) => console.log(k + "=" + v));
	})();
}

Promise.resolve()
	.then(main)
	.catch((err) => {
		console.log("error=" + (err && err.message ? err.message : String(err)));
		process.exit(1);
	});
