const shell = require("shelljs");

const files = [
  "dashboard/index.html",
  "dashboard/reset.css",
  "dashboard/web-ui-config.json",
];

shell.mkdir("-p", "dist");
shell.cp(files, "dist/");

// Also update core/web-ui/ so that `go build` (go:embed) picks up UI changes
// without re-entering the devshell.  In the sandbox of the regular
// `nix build -L .#internal.x86_64-linux.ui.dist`, `../core/` doesn't exist.
if (shell.test("-d", "../core")) {
  shell.mkdir("-p", "../core/web-ui");
  shell.cp(files, "../core/web-ui/");
}
