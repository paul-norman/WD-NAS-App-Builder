// Runs Uptime Kuma's own password reset tool (extra/reset-password.js) with the new password read from standard input,
// answering its two prompts as they appear: piping both answers at once doesn't work (its input closes before the second
// question), and its --new-password option would show the password in the process list. Run from Uptime Kuma's folder
const { spawn } = require("child_process");

let password = "";

process.stdin.on("data", (data) => {
    password += data;
});

process.stdin.on("end", () => {
	password = password.replace(/\r?\n$/, "");

	if (password === "") {
		console.error("No password given");
		process.exit(1);
	}

	const tool = spawn(process.execPath, ["extra/reset-password.js"], { stdio: ["pipe", "pipe", "inherit"] });

	let output = "";

	tool.stdout.on("data", (data) => {
		const text = data.toString();

		output += text;

		process.stdout.write(text.replace(/(Confirm )?New Password: /g, ""));

		// Each prompt once: "Confirm New Password: " also contains "New Password: "
		for (const match of text.matchAll(/(Confirm )?New Password: /g)) {
			tool.stdin.write(password + "\n");
		}
	});

	tool.on("close", () => process.exit(output.includes("Password reset successfully") ? 0 : 1));
});
